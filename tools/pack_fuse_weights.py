# -*- coding: utf-8 -*-
"""pack_fuse_weights.py -- the fused design's weight file and the index into it.

Gathers each block's constants into contiguous regions, so the fetcher reads one
contiguous run per on-chip memory per block and does no arithmetic. The export's
requant tables are struct-of-arrays (int32 M0, int64 bias, uint8 shift per channel);
they are packed here into one entry per channel.

Reads (golden/p1_golden/vec):   p1_manifest.json, b??_wte.bin, b??_wtp.bin, b??_wdw.bin,
                         b??_rqe.bin, b??_rqp.bin, b??_rqd.bin  (from golden/p1_golden/run_p1.sh)
                         tools/gather_cost.json, rtl/fuse/twn_fuse_array.v,
                         rtl/fuse/twn_uop_enc.v   (through tailpack.py)
Writes (golden/p1_golden/vec):  fuse_weights.bin, fuse_weights_index.json
                         (index fields: off, words, word_bytes, mem_base, mem_words)

Four regions per block, each starting on a 64-byte boundary, in this order:
  TERN  ternary weights, expand then project (each followed by its tail-packed
        words, if tailpack.py says so): 256-bit words, 128 lanes x 2 bits,
        00 = 0, 01 = +1, 11 = -1.
  DW    depthwise taps, 576-bit words: DW_LANES = 8 channels x 9 taps, tap
        (L*9 + K) at byte L*9 + K.
  RQA   ternary-array requant, 256-bit groups of OCMAX = 4 entries.
        Entry: [17:0] M0, [57:18] BIAS, [63:58] SH. Expand's groups first, then
        project's, each starting at a group boundary.
  RQD   depthwise requant, 448-bit groups of DW_LANES = 8 entries.
        Entry: [17:0] M0, [49:18] BIAS, [55:50] SH (32-bit bias lane).
In the file every word is padded to a whole 16-byte beat (DW 72 -> 80, RQD 56 -> 64);
the on-chip memory words keep their natural width.

--verify reads the blob back using only the index and compares the ternary and
depthwise bytes and every requant field against the golden files.

usage:  python tools/pack_fuse_weights.py [--verify]
"""
import io, json, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VEC  = os.path.join(ROOT, "golden", "p1_golden", "vec")
MAN  = os.path.join(VEC, "p1_manifest.json")
OUT  = os.path.join(VEC, "fuse_weights.bin")
IDX  = os.path.join(VEC, "fuse_weights_index.json")

OCMAX    = 4       # requant entries the ternary array takes per cycle
DW_LANES = 8       # requant entries and taps the depthwise takes per cycle
ALIGN    = 64      # region alignment, in bytes
BEAT     = 16      # HP port width, bytes; every file word is a whole number of beats

NB_M0, NB_BIA, NB_SH = 18, 40, 6        # the ternary array's entry
NB_BIA_DW            = 32               # the depthwise's bias lane


def rd(name):
    with io.open(os.path.join(VEC, name), "rb") as f:
        return f.read()


def rq_table(name, oc):
    """The export's struct-of-arrays: oc int32 M0, oc int64 bias, oc uint8 shift."""
    d = rd(name)
    exp = oc * 13
    if len(d) != exp:
        raise SystemExit("%s is %d bytes, expected %d (= %d x 13)" % (name, len(d), exp, oc))
    m0 = list(struct.unpack("<%di" % oc, d[:4 * oc]))
    bs = list(struct.unpack("<%dq" % oc, d[4 * oc:12 * oc]))
    sh = list(d[12 * oc:])
    return m0, bs, sh


def fit(v, bits, name, ch):
    """Two's complement in `bits` bits, and a hard failure if it does not fit."""
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if not (lo <= v <= hi):
        raise SystemExit("%s channel %d = %d does not fit %d bits [%d, %d]"
                         % (name, ch, v, bits, lo, hi))
    return v & ((1 << bits) - 1)


def beat_pad(data, w_nat):
    """Re-lay words of w_nat bytes as words padded up to a whole beat."""
    w_file = ((w_nat + BEAT - 1) // BEAT) * BEAT
    if w_file == w_nat:
        return data, w_nat
    out = bytearray()
    for i in range(0, len(data), w_nat):
        out += data[i:i + w_nat] + bytes(w_file - w_nat)
    return bytes(out), w_file


def pack_groups(m0, bs, sh, per_group, nb_bias, entry_bits, what):
    """Entries into groups, LSB-first, zero-padded to a whole number of groups."""
    n = len(m0)
    pad = (-n) % per_group
    words = []
    for g in range((n + pad) // per_group):
        w = 0
        for j in range(per_group):
            c = g * per_group + j
            if c < n:
                e = (fit(m0[c], NB_M0, what + " M0", c)
                     | (fit(bs[c], nb_bias, what + " bias", c) << NB_M0)
                     | (fit(sh[c], NB_SH + 1, what + " shift", c) << (NB_M0 + nb_bias)))
                if sh[c] < 0 or sh[c] >= (1 << NB_SH):
                    raise SystemExit("%s shift channel %d = %d is not a %d-bit unsigned"
                                     % (what, c, sh[c], NB_SH))
                w |= e << (j * entry_bits)
        words.append(w.to_bytes((entry_bits * per_group) // 8, "little"))
    return b"".join(words), pad


def _fits(n, base, cap):
    """The residency rule: every block inside [0,cap) and every cyclically
    adjacent pair disjoint (blocks b and b+2 may overlap)."""
    for i in range(len(n)):
        if base[i] < 0 or base[i] + n[i] > cap:
            return False
    for i in range(len(n)):
        j = (i + 1) % len(n)
        if base[i] < base[j] + n[j] and base[j] < base[i] + n[i]:
            return False
    return True


def _first_fit(n, cap):
    """Lay blocks in increasing address order, wrapping to 0 when the next does
    not fit. Returns None unless the walk settles to the same placement every frame."""
    p, prev = 0, None
    for _ in range(4):
        base = []
        for w in n:
            if p + w > cap:
                p = 0
            base.append(p)
            p += w
        if prev is not None and base != prev:
            prev = base
            continue
        prev = base
    p2, b2 = p, []
    for w in n:
        if p2 + w > cap:
            p2 = 0
        b2.append(p2)
        p2 += w
    return prev if b2 == prev else None


def _alternating(n, cap):
    """Even blocks at the bottom, odd blocks at the top, so adjacent blocks are
    disjoint whenever n[i] + n[i+1] <= cap. With an odd block count one adjacency
    is bottom-to-bottom (last -> 0); block 0 is stacked directly above the last.
    """
    m = len(n)
    base = [0 if i % 2 == 0 else cap - n[i] for i in range(m)]
    if m % 2:
        base[0] = n[m - 1]
    return base


def allocate(n, name):
    """Where each block's words live in its memory, and how deep that memory is.

    Blocks b and b+1 are resident at once (b+1 is fetched while b computes), cyclic:
    block 0 is fetched while the last block computes. The floor is
    max(n[b] + n[b+1]); both strategies are tried at every capacity from the floor
    up and the first placement that satisfies _fits is returned.

    Returns (base per block, capacity). Raises if no placement exists.
    """
    lo = max(n[i] + n[(i + 1) % len(n)] for i in range(len(n)))
    for cap in range(lo, lo + 8193):
        for build in (_alternating, _first_fit):
            base = build(n, cap)
            if base is not None and _fits(n, base, cap):
                return base, cap
    raise SystemExit("%s: no circular placement found" % name)



# ---- the packed tail words, appended after a tail-packed stage's own words ----
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math as _math
import tailpack as _tp


def _lane_get(word, k):
    """The two-bit ternary code at lane k of a 32-byte, 128-lane word."""
    return (word[k // 4] >> (2 * (k % 4))) & 3


def _lane_set(buf, k, v):
    buf[k // 4] = (buf[k // 4] & ~(3 << (2 * (k % 4)))) | ((v & 3) << (2 * (k % 4)))


def packed_tail(golden, n_seg, n_ocg, pack0_log2, tail, what):
    """The appended words for one tail-packed stage. Returns bytes, or b'' if none."""
    if not pack0_log2:
        return b""
    W, Pk = 32, 1 << pack0_log2
    assert len(golden) == n_ocg * n_seg * W, (what, len(golden), n_ocg, n_seg)
    assert n_ocg % Pk == 0, (what, n_ocg, Pk)
    lanes_per = 128 // Pk
    assert tail <= lanes_per, (what, tail, lanes_per)
    out = []
    for g in range(n_ocg // Pk):
        dst = bytearray(W)
        for j in range(Pk):
            src = golden[((g * Pk + j) * n_seg + (n_seg - 1)) * W:
                         ((g * Pk + j) * n_seg + (n_seg - 1)) * W + W]
            # every lane of the run is copied, zeros included: tern_tail_zero
            # checks that the unused lanes are code 00
            for k in range(lanes_per):
                _lane_set(dst, j * lanes_per + k, _lane_get(src, k) if k < tail else 0)
        out.append(bytes(dst))
    return b"".join(out)


def _tern_bytes(bi, b):
    """One block's ternary region: expand, its packed tail, project, its packed tail.

    Each stage's appended words follow that stage's own words, so the project
    stage's base is expand's words plus expand's appended words (twn_uop_enc's
    we_words adds the appendix; see tailpack.encoder_counts_appendix).
    """
    out, notes = [], []
    for tag, key, c_out in (("wte", "pack_e", b["mid"]["c"]),
                            ("wtp", "pack_p", b["out"]["c"])):
        cfg = b[key]
        pk_log2 = int(_math.log2(cfg["pack"]))
        data = rd("b%02d_%s.bin" % (bi, tag))
        out.append(data)
        # same decision as gen_desctab.py: both call tailpack.pack0_for with the
        # measured T_gather from tools/gather_cost.json
        p0 = _tp.pack0_for(cfg["n_eff"], c_out, pk_log2,
                           t_gather=_tp.gather_cost()["blocks"][str(bi)]["t_gather"])
        if p0:
            ext = packed_tail(data, _tp.n_seg(cfg["n_eff"]), c_out >> pk_log2,
                              p0, _tp.tail_of(cfg["n_eff"]), "b%02d %s" % (bi, tag))
            out.append(ext)
            notes.append("%s tail x%d, %d words appended" % (tag, 1 << p0, len(ext) // 32))
    if notes:
        print("  block %-2d: %s" % (bi, "; ".join(notes)))
    return b"".join(out)


def main(verify):
    man = json.load(io.open(MAN, encoding="utf-8"))
    blob, index = bytearray(), []

    for b in man["blocks"]:
        bi = b["block"]
        c_mid, c_out = b["mid"]["c"], b["out"]["c"]
        ent = {"block": bi, "c_mid": c_mid, "c_out": c_out}

        for tag, data, wbytes in (
            # tern is not a plain concatenation: tail-packed stages get appended
            # words (tailpack.py decides; gen_desctab.py reads the same module)
            ("tern", _tern_bytes(bi, b), 32),
            ("dw",   rd("b%02d_wdw.bin" % bi), 72),
        ):
            while len(blob) % ALIGN:
                blob.append(0)
            if len(data) % wbytes:
                data = data + b"\0" * (wbytes - len(data) % wbytes)
            n = len(data) // wbytes
            data, wfile = beat_pad(data, wbytes)
            ent[tag] = {"off": len(blob), "words": n, "word_bytes": wfile,
                        "word_bits": wbytes * 8, "beats_per_word": wfile // BEAT}
            blob += data

        # the ternary array's table: expand's entries, then project's, each
        # starting at a group boundary so rq_base can point straight at either.
        m0e, bse, she = rq_table("b%02d_rqe.bin" % bi, c_mid)
        m0p, bsp, shp = rq_table("b%02d_rqp.bin" % bi, c_out)
        we, pe = pack_groups(m0e, bse, she, OCMAX, NB_BIA, 64, "block %d expand" % bi)
        wp, pp = pack_groups(m0p, bsp, shp, OCMAX, NB_BIA, 64, "block %d project" % bi)
        while len(blob) % ALIGN:
            blob.append(0)
        ent["rqa"] = {"off": len(blob), "words": (len(we) + len(wp)) // 32, "word_bytes": 32,
                      "word_bits": 256, "beats_per_word": 2,
                      "expand_group": 0, "project_group": len(we) // 32,
                      "pad_entries": pe + pp}
        blob += we + wp

        # the depthwise's table
        m0d, bsd, shd = rq_table("b%02d_rqd.bin" % bi, c_mid)
        wd, pd = pack_groups(m0d, bsd, shd, DW_LANES, NB_BIA_DW, 56, "block %d dw" % bi)
        nd = len(wd) // 56
        wd, wfd = beat_pad(wd, 56)
        while len(blob) % ALIGN:
            blob.append(0)
        ent["rqd"] = {"off": len(blob), "words": nd, "word_bytes": wfd,
                      "word_bits": 448, "beats_per_word": wfd // BEAT,
                      "pad_entries": pd}
        blob += wd
        index.append(ent)

    # the placement must be in the index before it is written
    caps = {}
    for k in ("tern", "dw", "rqa", "rqd"):
        base, cap = allocate([e[k]["words"] for e in index], k)
        caps[k] = cap
        for e, b in zip(index, base):
            e[k]["mem_base"] = b

    io.open(OUT, "wb").write(bytes(blob))
    json.dump({"_README": "index into fuse_weights.bin; offsets are bytes from the "
                          "start of the file, words are of that region's own width, "
                          "mem_base is the word address in that region's on-chip memory",
               "align": ALIGN, "ocmax": OCMAX, "dw_lanes": DW_LANES, "beat": BEAT,
               "entry_bits": {"array": 64, "dw": 56},
               "mem_words": caps,
               "blocks": index},
              io.open(IDX, "w", encoding="utf-8"), indent=1)

    print("fuse_weights.bin  %d bytes (%.1f KB)" % (len(blob), len(blob) / 1024.0))
    for k in ("tern", "dw", "rqa", "rqd"):
        tot = sum(e[k]["words"] * e[k]["word_bytes"] for e in index)
        print("  %-5s %8d bytes  %5d words  worst block %d, %d words"
              % (k, tot, sum(e[k]["words"] for e in index),
                 max(index, key=lambda e: e[k]["words"])["block"],
                 max(e[k]["words"] for e in index)))
    # where each block lives in its memory, and therefore how deep each memory is
    print("  on-chip placement (blocks b and b+1 resident; cap should EQUAL worst pair):")
    for k in ("tern", "dw", "rqa", "rqd"):
        n = [e[k]["words"] for e in index]
        cap = caps[k]
        pair = max(n[i] + n[(i + 1) % len(n)] for i in range(len(n)))
        print("    %-5s cap %5d words   worst block %5d   worst pair %5d   2x worst %5d  %s"
              % (k, cap, max(n), pair, 2 * max(n),
                 "at the floor" if cap == pair else "ABOVE the floor by %d" % (cap - pair)))
    print("  -> twn_wmem depths: TERN %d  DW %d  RQA %d  RQD %d"
          % (caps["tern"], caps["dw"], caps["rqa"], caps["rqd"]))

    if verify:
        ok = check(man, index, bytes(blob))
        print("\n=== pack_fuse_weights verify: %s ===" % ("ALL PASS" if ok else "FAIL"))
        return 0 if ok else 1
    return 0


def tern_lane_geom(pk, n_eff, msg=0):
    """(L, words) for one ternary stage, as golden/p1_golden/gen_p1.c computes them.

    L is 128/pack, not n_eff. (The `ternary_word` text in p1_manifest.json says
    channel j owns [j*n_eff, j*n_eff+n_eff); derive from here, not from there.)
    """
    # An msg stage (manifest msg_e/msg_p) is pack 4 with ceil(n_eff/32) words per
    # group: the words are 32-channel chunks of one activation word.
    if msg:
        return 32, (n_eff + 31) // 32
    L = (128 // pk) if pk > 1 else ((n_eff + 127) // 128) * 128
    return L, (L * pk + 127) // 128


def tern_tail_zero(img, oc, n_eff, pk, npass, lane0, msg=0):
    """Non-zero lanes outside the live set of one ternary stage. -> (nz, dead)

    `lane0` is a lane index into `img` (two bits per lane), so the project stage
    starts at len(wte)*4. The gather may leave stale bytes in lanes past the run;
    the array annihilates them only because the weights in those lanes are code
    00 (twn_fuse_select: en & (x ^ inv), en = code[0]). At pack 1 that is the only
    safeguard, because the replication mask is 7'd127 there.
    """
    L, words = tern_lane_geom(pk, n_eff, msg)
    if msg:
        # msg stage: every lane carries a real weight, so there is nothing
        # outside the live set to count; contributes no checks
        return 0, 0
    ngrp, nz, dead = (oc + pk - 1) // pk, 0, 0
    for g in range(ngrp):
        for ps in range(npass):
            row = lane0 + (g * npass + ps) * words * 128
            for j in range(pk):
                # a group's tail slot has no output channel: dead whole
                lo = n_eff if (g * pk + j) < oc else 0
                for k in range(lo, L):
                    dead += 1
                    bit = (row + j * L + k) * 2
                    if (img[bit >> 3] >> (bit & 7)) & 3:
                        nz += 1
    return nz, dead


def check(man, index, blob):
    """Read the blob back with the index alone and compare to the golden vectors."""
    bad, nchk = 0, 0
    for b, ent in zip(man["blocks"], index):
        bi = b["block"]
        c_mid, c_out = b["mid"]["c"], b["out"]["c"]

        wte = rd("b%02d_wte.bin" % bi)
        src = wte + rd("b%02d_wtp.bin" % bi)
        got = blob[ent["tern"]["off"]:ent["tern"]["off"] + len(src)]
        if got != src:
            bad += 1; print("  b%02d ternary bytes differ" % bi)
        nchk += len(src)

        # tern is wte and wtp concatenated with no recorded split point, so the
        # boundary is recomputed from the expand file's length.
        for what, oc, pinfo, lane0, msg in (
            ("expand",  c_mid, b["pack_e"], 0, b.get("msg_e", 0)),
            ("project", c_out, b["pack_p"], len(wte) * 4, b.get("msg_p", 0)),
        ):
            L, words = tern_lane_geom(pinfo["pack"], pinfo["n_eff"], msg)
            if words != pinfo["words_per_group"]:
                bad += 1
                print("  b%02d %s lane geometry disagrees with the manifest: "
                      "words %d vs words_per_group %d"
                      % (bi, what, words, pinfo["words_per_group"]))
                continue
            nz, dead = tern_tail_zero(got, oc, pinfo["n_eff"], pinfo["pack"],
                                      pinfo["passes"], lane0, msg)
            if nz:
                bad += 1
                print("  b%02d %s: %d of %d ternary lanes outside "
                      "[j*%d, j*%d+%d) are NOT code 00 -- the gather's early "
                      "chunk termination would leak stale activations through them"
                      % (bi, what, nz, dead, L, L, pinfo["n_eff"]))
            nchk += dead

        # read at the file stride, keep the natural width, and require the pad
        # bytes to be zero
        src = rd("b%02d_wdw.bin" % bi)
        got = bytearray()
        for g in range(ent["dw"]["words"]):
            o = ent["dw"]["off"] + g * ent["dw"]["word_bytes"]
            got += blob[o:o + ent["dw"]["word_bits"] // 8]
            if any(blob[o + ent["dw"]["word_bits"] // 8:o + ent["dw"]["word_bytes"]]):
                bad += 1; print("  b%02d depthwise word %d has a non-zero pad" % (bi, g))
        if bytes(got[:len(src)]) != src or any(got[len(src):]):
            bad += 1; print("  b%02d depthwise taps differ" % bi)
        nchk += len(src)

        # requant: unpack every field back out of the groups
        for what, oc, name, per, nb_bias, ebits, base_words in (
            ("expand",  c_mid, "b%02d_rqe.bin" % bi, OCMAX, NB_BIA, 64, ent["rqa"]["expand_group"]),
            ("project", c_out, "b%02d_rqp.bin" % bi, OCMAX, NB_BIA, 64, ent["rqa"]["project_group"]),
            ("dw",      c_mid, "b%02d_rqd.bin" % bi, DW_LANES, NB_BIA_DW, 56, 0),
        ):
            reg = ent["rqd"] if what == "dw" else ent["rqa"]
            m0, bs, sh = rq_table(name, oc)
            gb = reg["word_bytes"]
            for c in range(oc):
                g, j = base_words + c // per, c % per
                w = int.from_bytes(blob[reg["off"] + g * gb:reg["off"] + (g + 1) * gb], "little")
                e = (w >> (j * ebits)) & ((1 << ebits) - 1)
                gm = e & ((1 << NB_M0) - 1)
                gv = (e >> NB_M0) & ((1 << nb_bias) - 1)
                gs = (e >> (NB_M0 + nb_bias)) & ((1 << NB_SH) - 1)
                if gm >= (1 << (NB_M0 - 1)):     gm -= (1 << NB_M0)
                if gv >= (1 << (nb_bias - 1)):   gv -= (1 << nb_bias)
                if (gm, gv, gs) != (m0[c], bs[c], sh[c]):
                    bad += 1
                    if bad < 8:
                        print("  b%02d %s ch %d: got (%d, %d, %d) want (%d, %d, %d)"
                              % (bi, what, c, gm, gv, gs, m0[c], bs[c], sh[c]))
                nchk += 3
    print("  %d values checked, %d errors" % (nchk, bad))
    return bad == 0


if __name__ == "__main__":
    sys.exit(main("--verify" in sys.argv))
