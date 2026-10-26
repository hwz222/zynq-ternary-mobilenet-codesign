# -*- coding: utf-8 -*-
r"""tailpack.py -- decides which stages pack their short last segment (tail packing).

A stage whose n_eff is not a multiple of 128 has a short last segment; tail
packing lets that segment hold several output channels (twn_fuse_array u_pack0).
Imported by gen_desctab.py (writes pack0 into the descriptor) and
pack_fuse_weights.py (rearranges the weight words to match): the two must use
the same decision or the array walks the right number of groups over the wrong
bytes.

Reads:  rtl/fuse/twn_fuse_array.v   u_acc_w depth (accw_d)
        rtl/fuse/twn_uop_enc.v      we_apx check (encoder_counts_appendix)
        tools/gather_cost.json      measured T_gather per block (gather_cost)
No command line; this is a library module.

Rule (pack0_for):
  n_seg == 2                 the tail is segment 0 and the full segment is last, so
                             no beat updates one lane of an accumulator entry
                             (the wide accumulator has no lane enable)
  tail not in {0, 128}       a full last segment already uses every lane
  pack0 = largest power of two with pack0 * tail <= 128 and pack0 <= OCMAX
  pack0 > pack               the array subtracts them in two unsigned bits
  n_ocg / pack0 <= ACCW_D    ACCW_D is read from the RTL
  n_ocg / pack0 >= MARGIN * T_gather
                             packing removes beats, not activation words; it
                             pays only where beats bound the layer
"""
import io
import json
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

OCMAX = 4      # twn_fuse_top.v parameter OCMAX: also the emit width, channels per beat
LANES = 128    # twn_fuse_top.v parameter LANES

# Safety factor on the t_gather clause: the max(beats, T_gather) model is optimistic
# and T_gather is a per-block average applied to both stages.
MARGIN = 2.0

_ARRAY_V = os.path.join(ROOT, "rtl", "fuse", "twn_fuse_array.v")
_GATHER_JSON = os.path.join(HERE, "gather_cost.json")
_ACCW_RE = re.compile(r"bram_sdp\s*#\([^;]*?\.D\((\d+)\)[^;]*?u_acc_w", re.S)


def accw_d(path=None):
    """u_acc_w's depth, read out of the RTL rather than restated here."""
    src = io.open(path or _ARRAY_V, encoding="utf-8", errors="replace").read()
    m = _ACCW_RE.search(src)
    if not m:
        raise RuntimeError("could not find u_acc_w's .D() in %s -- the depth must be "
                           "read from the RTL, not assumed" % (path or _ARRAY_V))
    return int(m.group(1))


def gather_cost(path=None):
    """Measured T_gather per block. Raises if the file is absent (see pack0_for)."""
    p = path or _GATHER_JSON
    if not os.path.exists(p):
        raise RuntimeError(
            "%s is missing. Tail packing may not be decided without measured gather "
            "cost: blocks 2 and 3 were packed on geometry alone and cost 206 cycles. "
            "Regenerate with:\n"
            "    python tools/gather_cost.py <attrib log with FUSE_BLK_CYC>" % p)
    return json.load(io.open(p, encoding="utf-8"))


def n_seg(n_eff):
    return max(1, int(math.ceil(n_eff / float(LANES))))


def tail_of(n_eff):
    """How many input channels the LAST segment carries."""
    return n_eff - (n_seg(n_eff) - 1) * LANES


def pack0_for(n_eff, c_out, pack, accw_depth=None, t_gather=None, margin=MARGIN):
    """log2 of segment 0's packing factor, or 0 for "same as pack" (no tail packing).

    `pack` is the stage's own log2 packing factor and n_ocg = c_out >> pack, as in
    twn_uop_enc. t_gather is required: None raises instead of returning 0.
    """
    if t_gather is None:
        raise ValueError(
            "pack0_for needs the measured T_gather for this block. Packing on "
            "geometry alone is what commit fd94311 measured as a 206-cycle loss.")
    if accw_depth is None:
        accw_depth = accw_d()
    ns = n_seg(n_eff)
    if ns < 2:
        return 0
    tail = tail_of(n_eff)
    if tail == 0 or tail == LANES:
        return 0
    p = 1
    while p * 2 * tail <= LANES and p * 2 <= OCMAX:
        p *= 2
    if p == 1:
        return 0
    if p <= (1 << pack):
        # The array computes pack0_dx = r_pack0 - r_pack in two unsigned bits; a
        # pack0 not strictly greater than pack would underflow to 3.
        return 0
    if ns != 2:
        # The wide accumulator has no lane enable, so a tail-packed stage may not
        # have an intermediate segment: only n_seg == 2 is allowed.
        return 0
    n_ocg = c_out >> pack
    if (n_ocg // p) > accw_depth:
        return 0                      # the wide accumulator is not deep enough
    if n_ocg % p:
        return 0                      # the groups would not divide evenly
    # ---- the gather clause: see this file's header ----
    beats_after = float(n_ocg) / p     # beats per activation word once packed
    if beats_after < margin * t_gather:
        return 0
    return int(math.log2(p))


def encoder_counts_appendix(path=None):
    """Does twn_uop_enc add a tail-packed expand's appendix (we_apx) to we_words?

    The project stage's weight base must clear the expand's appended words;
    this is asked of the RTL source rather than declared here.
    """
    p = path or os.path.join(ROOT, "rtl", "fuse", "twn_uop_enc.v")
    src = io.open(p, encoding="utf-8", errors="replace").read()
    return "we_apx" in src and "+ {4'd0, we_apx}" in src


def stages(manifest, accw_depth=None, gather=None, margin=MARGIN, explain=False):
    """Every (block, role, pack0) the manifest implies. role 0 = expand, 1 = project."""
    g = gather or gather_cost()
    if accw_depth is None:
        accw_depth = accw_d()
    out = []
    for b in manifest["blocks"]:
        blk = b["block"]
        tg = g["blocks"][str(blk)]["t_gather"]
        for role, key, c_out in ((0, "pack_e", b["mid"]["c"]), (1, "pack_p", b["out"]["c"])):
            cfg = b[key]
            pk = int(math.log2(cfg["pack"]))
            p0 = pack0_for(cfg["n_eff"], c_out, pk, accw_depth, tg, margin)
            rec = [blk, role, cfg["n_eff"], c_out, pk, p0]
            if explain:
                n_ocg = c_out >> pk
                rec.append({"t_gather": tg, "beats_now": n_ocg,
                            "beats_after": (n_ocg / (1 << p0)) if p0 else n_ocg,
                            "ratio_after": (n_ocg / float(1 << p0) / tg) if p0 else None})
            out.append(tuple(rec))
    return out
