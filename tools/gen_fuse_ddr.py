# -*- coding: utf-8 -*-
"""gen_fuse_ddr.py -- the DDR image the top-level AXI testbenches run against.

The goldens in golden/p1_golden/vec are CHW; twn_act_gather reads HWC, byte (c, y, x)
at ((y*W) + x)*C + c. This tool transposes once on the host and emits hex images
in 128-bit beats.

Reads (golden/p1_golden/vec):  p1_manifest.json, fuse_weights_index.json,
                        fuse_weights.bin (from pack_fuse_weights.py),
                        b??_in.bin and b??_out.bin (int8 CHW; from golden/p1_golden/run_p1.sh).
    Every .bin is checked against the manifest's sha256 and size; a missing
    file is an error, never zeros.
Writes (default rtl/fuse/tb):
    ddr_w.hex        fuse_weights.bin as 128-bit beats
    ddr_in_b??.hex   each block's input, CHW -> HWC at the padded row stride
    gold_out.hex     all block outputs, CHW -> HWC, concatenated
    gold_index.vh    start word and size of each block's output in gold_out.hex
    tb_fuse_map.vh   arena map, per-block geometry, weight regions, three probe
                     bytes per block (each at a different CHW and HWC offset)
Verification is on by default: every hex file is read back and inverse-transposed
and must equal the .bin; the probe bytes are checked in the emitted image.

usage:  python tools/gen_fuse_ddr.py [--out DIR] [--no-verify]
"""
import hashlib, io, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VEC  = os.path.join(ROOT, "golden", "p1_golden", "vec")
MAN  = os.path.join(VEC, "p1_manifest.json")
IDX  = os.path.join(VEC, "fuse_weights_index.json")
BLOB = os.path.join(VEC, "fuse_weights.bin")
DEF_OUT = os.path.join(ROOT, "rtl", "fuse", "tb")

# ---- the arena: must equal sw/app/mbv2_fuse_ps.c (OFF_WEIGHTS, OFF_ACT, SLOT_LOG2) ----
# SLOT_LOG2 is fixed in the bitstream (twn_act_rd / twn_act_wr).
ARENA       = 0x60000000        # FUSE_ARENA_PA_DEFAULT
OFF_WEIGHTS = 0x00000000
OFF_ACT     = 0x00100000
SLOT_LOG2   = 18
SLOT_STRIDE = 1 << SLOT_LOG2    # 262,144
N_SLOTS     = 2
OFF_IN      = OFF_ACT + N_SLOTS * SLOT_STRIDE
BEAT        = 16                # HP port width, bytes

NOSLOT = 0xF                    # in_slot code of block 0 (no input slot)

ROW_ALIGN = 128

def pad_row(v):
    """Round a row's byte count up to a whole 128-byte row-buffer word.

    Must agree with gen_desctab.py's pad_row. The stride is padded, not the
    tensor: the pad bytes are transferred and never read.
    """
    return (v + ROW_ALIGN - 1) // ROW_ALIGN * ROW_ALIGN

def pad_image(hwc, C, H, W):
    """An HWC image re-laid at the padded row stride, pad bytes zero."""
    r, rp = C * W, pad_row(C * W)
    if r == rp:
        return hwc
    out = bytearray(rp * H)
    for y in range(H):
        out[y*rp:y*rp + r] = hwc[y*r:(y+1)*r]
    return bytes(out)



# ---- reading, with the manifest's hashes enforced ----
def rd(name, want_sha=None, want_bytes=None):
    p = os.path.join(VEC, name)
    if not os.path.exists(p):
        raise SystemExit(
            "gen_fuse_ddr: %s is missing.\n"
            "  golden/p1_golden/vec/*.bin are NOT in version control (10 MB, exactly\n"
            "  regenerable). Run  bash golden/p1_golden/run_p1.sh  and try again.\n"
            "  Refusing to emit an image with zeros in it." % p)
    with io.open(p, "rb") as f:
        d = f.read()
    if want_bytes is not None and len(d) != want_bytes:
        raise SystemExit("gen_fuse_ddr: %s is %d bytes, the manifest says %d"
                         % (name, len(d), want_bytes))
    if want_sha is not None:
        got = hashlib.sha256(d).hexdigest()
        if got != want_sha:
            raise SystemExit(
                "gen_fuse_ddr: %s does not match the manifest's sha256.\n"
                "  got  %s\n  want %s\n"
                "  vec/ is stale or half-regenerated; re-run golden/p1_golden/run_p1.sh."
                % (name, got, want_sha))
    return d


def file_entry(blk, name):
    for f in blk["files"]:
        if f["file"] == name:
            return f
    raise SystemExit("gen_fuse_ddr: block %d has no file %s in the manifest"
                     % (blk["block"], name))


# ---- the transpose ----
def chw_to_hwc(src, C, H, W):
    """CHW -> HWC.  out[((y*W)+x)*C + c] = src[(c*H + y)*W + x]."""
    n = C * H * W
    if len(src) != n:
        raise SystemExit("gen_fuse_ddr: tensor is %d bytes, geometry says %d "
                         "(C=%d H=%d W=%d)" % (len(src), n, C, H, W))
    out = bytearray(n)
    for c in range(C):
        out[c::C] = src[c * H * W:(c + 1) * H * W]
    return bytes(out)


def hwc_to_chw(src, C, H, W):
    """The inverse, used only by the self-check."""
    n = C * H * W
    if len(src) != n:
        raise SystemExit("gen_fuse_ddr: HWC tensor is %d bytes, want %d" % (len(src), n))
    out = bytearray(n)
    for c in range(C):
        out[c * H * W:(c + 1) * H * W] = src[c::C]
    return bytes(out)


# ---- hex, in the beat order the AXI model serves ----
def write_hex(path, data):
    """128-bit beats, 32 hex digits, little-endian within the beat (as in
    pack_fuse_weights.py and gen_wfetch_tb.py); zero-padded to a whole beat."""
    pad = (-len(data)) % BEAT
    if pad:
        data = data + bytes(pad)
    with io.open(path, "w", newline="\n") as f:
        for i in range(0, len(data), BEAT):
            f.write("%032x\n" % int.from_bytes(data[i:i + BEAT], "little"))
    return len(data) // BEAT


def read_hex(path):
    """Read a hex file back the way the simulator's $readmemh will."""
    out = bytearray()
    with io.open(path) as f:
        for ln, line in enumerate(f):
            s = line.strip()
            if not s:
                continue
            if len(s) != 32:
                raise SystemExit("gen_fuse_ddr: %s line %d is %d digits, want 32"
                                 % (path, ln + 1, len(s)))
            out += int(s, 16).to_bytes(BEAT, "little")
    return bytes(out)


# ---- Verilog emission helpers ----
def vec(name, width, vals, count_name):
    """A concatenation with block 0 last (concatenations are MSB-first)."""
    for v in vals:
        if v < 0 or v >= (1 << width):
            raise SystemExit("gen_fuse_ddr: %s value %d does not fit %d bits"
                             % (name, v, width))
    return ("localparam [%d*%s-1:0] %s = {%s};"
            % (width, count_name, name,
               ", ".join("%d'd%d" % (width, v) for v in reversed(vals))))


def main(argv):
    out_dir = DEF_OUT
    verify = True
    i = 1
    while i < len(argv):
        if argv[i] == "--out":
            out_dir = argv[i + 1]; i += 2
        elif argv[i] == "--no-verify":
            verify = False; i += 1
        else:
            raise SystemExit("gen_fuse_ddr: unknown argument %r" % argv[i])
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)

    for p in (MAN, IDX, BLOB):
        if not os.path.exists(p):
            raise SystemExit(
                "gen_fuse_ddr: %s is missing.\n"
                "  fuse_weights.bin / its index come from\n"
                "    python tools/pack_fuse_weights.py --verify\n"
                "  and the goldens it packs come from  bash golden/p1_golden/run_p1.sh." % p)

    man = json.load(io.open(MAN, encoding="utf-8"))
    idx = json.load(io.open(IDX, encoding="utf-8"))
    B, I = man["blocks"], idx["blocks"]
    if len(B) != len(I):
        raise SystemExit("gen_fuse_ddr: manifest has %d blocks, weight index %d"
                         % (len(B), len(I)))
    N = len(B)

    # ---- 1. the weight file, byte for byte ----
    blob = io.open(BLOB, "rb").read()
    w_words = write_hex(os.path.join(out_dir, "ddr_w.hex"), blob)

    # ---- 2. each block's input, transposed ----
    in_words, in_bytes = [], []
    for b in B:
        bi = b["block"]
        fe = file_entry(b, "b%02d_in.bin" % bi)
        src = rd(fe["file"], fe["sha256"], fe["bytes"])
        C, H, W = b["in"]["c"], b["in"]["h"], b["in"]["w"]
        img = pad_image(chw_to_hwc(src, C, H, W), C, H, W)
        nb = write_hex(os.path.join(out_dir, "ddr_in_b%02d.hex" % bi), img)
        in_words.append(nb)
        in_bytes.append(len(img))

    # ---- 3. every block's output, transposed and concatenated ----
    gold, g_base, g_words = bytearray(), [], []
    for b in B:
        bi = b["block"]
        fe = file_entry(b, "b%02d_out.bin" % bi)
        src = rd(fe["file"], fe["sha256"], fe["bytes"])
        C, H, W = b["out"]["c"], b["out"]["h"], b["out"]["w"]
        if len(gold) % BEAT:
            raise SystemExit("gen_fuse_ddr: block %d's output would start "
                             "mid-beat at %d" % (bi, len(gold)))
        g_base.append(len(gold) // BEAT)
        g_words.append(len(src) // BEAT)
        if len(src) % BEAT:
            raise SystemExit("gen_fuse_ddr: block %d's output is %d bytes, not a "
                             "whole number of %d-byte beats" % (bi, len(src), BEAT))
        gold += chw_to_hwc(src, C, H, W)
    gold_words = write_hex(os.path.join(out_dir, "gold_out.hex"), bytes(gold))

    # ---- 4. the probes: three per block, each at a different offset in CHW and HWC ----
    def probes_of(C, H, W, src):
        """Three deterministic probes whose CHW and HWC offsets differ.

        A candidate list is scanned because no single rule avoids every
        coincidence across the block shapes.
        """
        cand = [(C - 1,                   0,     1 % W),
                (C // 3 + 1 if C > 3 else C - 1, H // 2, (W // 4 + 3) % W),
                (1 % C,                   H - 1, W - 1),
                (C // 2,                  H // 3, W - 2),
                (0,                       H // 2, 1 % W),
                (C - 2 if C > 1 else 0,   H - 2, W // 2)]
        out, seen = [], set()
        for (c, y, x) in cand:
            if len(out) == 3:
                break
            if not (0 <= c < C and 0 <= y < H and 0 <= x < W):
                continue
            o_hwc = ((y * W) + x) * C + c
            o_chw = (c * H + y) * W + x
            if o_hwc == o_chw or o_hwc in seen:
                continue          # proves nothing about the transpose, or is a repeat
            seen.add(o_hwc)
            out.append((c, y, x, o_hwc, src[o_chw]))
        if len(out) != 3:
            raise SystemExit("gen_fuse_ddr: could not find three distinct probes "
                             "for C=%d H=%d W=%d" % (C, H, W))
        return out

    in_prb, out_prb = [], []
    for b in B:
        bi = b["block"]
        s_in = rd("b%02d_in.bin" % bi)
        s_ou = rd("b%02d_out.bin" % bi)
        ci, wi = b["in"]["c"], b["in"]["w"]
        rr, rp = ci * wi, pad_row(ci * wi)
        in_prb += [(c, y, x, (o // rr) * rp + (o % rr), v)
                   for (c, y, x, o, v) in probes_of(ci, b["in"]["h"], wi, s_in)]
        out_prb += probes_of(b["out"]["c"], b["out"]["h"], b["out"]["w"], s_ou)

    # ---- 5. tb_fuse_map.vh ----
    act_span = (OFF_IN - OFF_ACT) + in_bytes[0]        # slots, then block 0's input
    L = ["// generated by tools/gen_fuse_ddr.py -- do not edit",
         "// The arena map is sw/app/mbv2_fuse_ps.c's and sw/app/pl_hal_fuse.h's; the",
         "// geometry is p1_manifest.json's; the weight regions are",
         "// fuse_weights_index.json's. Nothing here is chosen by this file.",
         "localparam integer FM_NBLK       = %d;" % N,
         "localparam [39:0]  FM_ARENA      = 40'h%010x;" % ARENA,
         "localparam [39:0]  FM_W_BASE     = 40'h%010x;" % (ARENA + OFF_WEIGHTS),
         "localparam [39:0]  FM_ACT_BASE   = 40'h%010x;" % (ARENA + OFF_ACT),
         "localparam [39:0]  FM_IN_PTR     = 40'h%010x;" % (ARENA + OFF_IN),
         "localparam integer FM_SLOT_LOG2  = %d;" % SLOT_LOG2,
         "localparam [39:0]  FM_SLOT_STRIDE= 40'd%d;" % SLOT_STRIDE,
         "localparam integer FM_N_SLOTS    = %d;" % N_SLOTS,
         "localparam integer FM_NOSLOT     = %d;" % NOSLOT,
         "// the two DDR windows, in 16-byte words. Sized EXACTLY, so an access",
         "// one beat past either region is a reported error and not a read of",
         "// somebody else's data that happens to look plausible.",
         "localparam integer FM_W_BYTES    = %d;" % len(blob),
         "localparam integer FM_W_WORDS    = %d;" % w_words,
         "localparam integer FM_ACT_WORDS  = %d;" % (act_span // BEAT),
         "localparam integer FM_IN_WORD0   = %d;" % ((OFF_IN - OFF_ACT) // BEAT),
         "// the on-chip weight memory depths twn_wmem is built with",
         "localparam integer FM_TERN_WORDS = %d;" % idx["mem_words"]["tern"],
         "localparam integer FM_DW_WORDS   = %d;" % idx["mem_words"]["dw"],
         "localparam integer FM_RQA_WORDS  = %d;" % idx["mem_words"]["rqa"],
         "localparam integer FM_RQD_WORDS  = %d;" % idx["mem_words"]["rqd"],
         ""]

    L.append(vec("FM_C_IN",   10, [b["in"]["c"] for b in B], "FM_NBLK"))
    L.append(vec("FM_H_IN",    9, [b["in"]["h"] for b in B], "FM_NBLK"))
    L.append(vec("FM_W_IN",    9, [b["in"]["w"] for b in B], "FM_NBLK"))
    L.append(vec("FM_C_MID",  10, [b["mid"]["c"] for b in B], "FM_NBLK"))
    L.append(vec("FM_C_OUT",  10, [b["out"]["c"] for b in B], "FM_NBLK"))
    L.append(vec("FM_H_OUT",   9, [b["out"]["h"] for b in B], "FM_NBLK"))
    L.append(vec("FM_W_OUT",   9, [b["out"]["w"] for b in B], "FM_NBLK"))
    L.append(vec("FM_S_DW",    1, [1 if b["dw_stride"] == 2 else 0 for b in B], "FM_NBLK"))
    L.append(vec("FM_HAS_RES", 1, [1 if b["has_residual"] else 0 for b in B], "FM_NBLK"))
    L.append(vec("FM_IN_SLOT", 4, [NOSLOT if b["block"] == 0 else ((b["block"] - 1) % N_SLOTS)
                                   for b in B], "FM_NBLK"))
    L.append(vec("FM_OUT_SLOT", 4, [b["block"] % N_SLOTS for b in B], "FM_NBLK"))
    # padded stride (what the design addresses) beside the real row width (what
    # the golden is laid out at)
    L.append(vec("FM_ROW_BYTES_IN",  16, [pad_row(b["in"]["c"] * b["in"]["w"]) for b in B], "FM_NBLK"))
    L.append(vec("FM_ROW_BYTES_OUT", 16, [pad_row(b["out"]["c"] * b["out"]["w"]) for b in B], "FM_NBLK"))
    L.append(vec("FM_ROW_REAL_IN",   16, [b["in"]["c"] * b["in"]["w"] for b in B], "FM_NBLK"))
    L.append(vec("FM_ROW_REAL_OUT",  16, [b["out"]["c"] * b["out"]["w"] for b in B], "FM_NBLK"))
    L.append(vec("FM_IN_BYTES",  32, in_bytes, "FM_NBLK"))
    L.append(vec("FM_IN_WORDS",  32, in_words, "FM_NBLK"))
    L.append("")
    L.append("// the four weight regions, straight out of fuse_weights_index.json.")
    L.append("// A testbench that has these can check the FETCH -- the strongest")
    L.append("// thing available with no compute at all -- against the same DDR")
    L.append("// image the model serves.")
    for nm, key, fld, w in (("FM_OFF_TERN", "tern", "off", 32),
                            ("FM_OFF_DW",   "dw",   "off", 32),
                            ("FM_OFF_RQA",  "rqa",  "off", 32),
                            ("FM_OFF_RQD",  "rqd",  "off", 32),
                            ("FM_N_TERN",   "tern", "words", 16),
                            ("FM_N_DW",     "dw",   "words", 16),
                            ("FM_N_RQA",    "rqa",  "words", 16),
                            ("FM_N_RQD",    "rqd",  "words", 16),
                            ("FM_MB_TERN",  "tern", "mem_base", 14),
                            ("FM_MB_DW",    "dw",   "mem_base", 10),
                            ("FM_MB_RQA",   "rqa",  "mem_base", 13),
                            ("FM_MB_RQD",   "rqd",  "mem_base", 13),
                            ("FM_WB_TERN",  "tern", "word_bytes", 8),
                            ("FM_WB_DW",    "dw",   "word_bytes", 8),
                            ("FM_WB_RQA",   "rqa",  "word_bytes", 8),
                            ("FM_WB_RQD",   "rqd",  "word_bytes", 8)):
        L.append(vec(nm, w, [e[key][fld] for e in I], "FM_NBLK"))

    L += ["",
          "// ---- three baked bytes per block, for the testbench to prove its OWN",
          "// loader before it blames the DUT. Probe p of block b is at index",
          "// (b*3 + p). FM_PRB_OFF is the byte's offset in the HWC image, which",
          "// is DIFFERENT from its CHW offset for every one of these -- asserted",
          "// in the generator, so a no-op transpose cannot pass them.",
          "localparam integer FM_NPRB = 3;"]
    L.append(vec("FM_PRB_C",   10, [p[0] for p in in_prb], "(FM_NBLK*FM_NPRB)"))
    L.append(vec("FM_PRB_Y",    9, [p[1] for p in in_prb], "(FM_NBLK*FM_NPRB)"))
    L.append(vec("FM_PRB_X",    9, [p[2] for p in in_prb], "(FM_NBLK*FM_NPRB)"))
    L.append(vec("FM_PRB_OFF", 32, [p[3] for p in in_prb], "(FM_NBLK*FM_NPRB)"))
    L.append(vec("FM_PRB_V",    8, [p[4] for p in in_prb], "(FM_NBLK*FM_NPRB)"))
    io.open(os.path.join(out_dir, "tb_fuse_map.vh"), "w",
            newline="\n").write("\n".join(L) + "\n")

    # ---- 6. gold_index.vh ----
    G = ["// generated by tools/gen_fuse_ddr.py -- do not edit",
         "// gold_out.hex is every block's OUTPUT tensor, CHW->HWC, concatenated.",
         "// Word GI_WORD_BASE[b] .. +GI_WORDS[b] is block b, in the same byte",
         "// order the design writes to DDR, so a frame gate compares the slot it",
         "// wrote against this with no transpose of its own.",
         "localparam integer GI_NBLK  = %d;" % N,
         "localparam integer GI_WORDS_TOTAL = %d;" % gold_words,
         "localparam integer GI_NPRB  = 3;"]
    G.append(vec("GI_WORD_BASE", 32, g_base, "GI_NBLK"))
    G.append(vec("GI_WORDS",     32, g_words, "GI_NBLK"))
    G.append(vec("GI_H_OUT",      9, [b["out"]["h"] for b in B], "GI_NBLK"))
    G.append(vec("GI_W_OUT",      9, [b["out"]["w"] for b in B], "GI_NBLK"))
    G.append(vec("GI_C_OUT",     10, [b["out"]["c"] for b in B], "GI_NBLK"))
    G.append(vec("GI_OUT_SLOT",   4, [b["block"] % N_SLOTS for b in B], "GI_NBLK"))
    G.append("// the same kind of probe, for the gold loader")
    G.append(vec("GI_PRB_C",   10, [p[0] for p in out_prb], "(GI_NBLK*GI_NPRB)"))
    G.append(vec("GI_PRB_Y",    9, [p[1] for p in out_prb], "(GI_NBLK*GI_NPRB)"))
    G.append(vec("GI_PRB_X",    9, [p[2] for p in out_prb], "(GI_NBLK*GI_NPRB)"))
    G.append(vec("GI_PRB_OFF", 32, [p[3] for p in out_prb], "(GI_NBLK*GI_NPRB)"))
    G.append(vec("GI_PRB_V",    8, [p[4] for p in out_prb], "(GI_NBLK*GI_NPRB)"))
    io.open(os.path.join(out_dir, "gold_index.vh"), "w",
            newline="\n").write("\n".join(G) + "\n")

    # ---- report ----
    print("gen_fuse_ddr -> %s" % out_dir)
    print("  ddr_w.hex        %8d beats  (%d bytes)" % (w_words, len(blob)))
    print("  ddr_in_b??.hex   %8d beats over %d blocks" % (sum(in_words), N))
    print("  gold_out.hex     %8d beats  (%d bytes)" % (gold_words, len(gold)))
    print("  arena  %010x   W %010x   ACT %010x   IN %010x"
          % (ARENA, ARENA + OFF_WEIGHTS, ARENA + OFF_ACT, ARENA + OFF_IN))
    print("  windows: weight %d words, activation %d words (slots %d + block 0 input %d)"
          % (w_words, act_span // BEAT, (OFF_IN - OFF_ACT) // BEAT, in_words[0]))

    if not verify:
        print("  *** --no-verify: NOTHING WAS CHECKED ***")
        return 0
    return 0 if check(out_dir, man, blob, in_prb, out_prb, g_base) else 1


def check(out_dir, man, blob, in_prb, out_prb, g_base):
    """Read every emitted hex back and undo the transpose; compare with the .bin files."""
    bad, nchk = 0, 0
    B = man["blocks"]

    got = read_hex(os.path.join(out_dir, "ddr_w.hex"))
    if got[:len(blob)] != blob:
        bad += 1; print("  ddr_w.hex does not read back as fuse_weights.bin")
    if any(got[len(blob):]):
        bad += 1; print("  ddr_w.hex has a non-zero tail past the weight file")
    nchk += len(blob)

    gold_hex = read_hex(os.path.join(out_dir, "gold_out.hex"))
    for b in B:
        bi = b["block"]

        C, H, W = b["in"]["c"], b["in"]["h"], b["in"]["w"]
        src = rd("b%02d_in.bin" % bi)
        got = read_hex(os.path.join(out_dir, "ddr_in_b%02d.hex" % bi))
        rr, rp = C * W, pad_row(C * W)
        dense = b"".join(bytes(got[y*rp:y*rp + rr]) for y in range(H))
        if any(got[rp * H:]):
            bad += 1; print("  b%02d input hex has a non-zero pad" % bi)
        if rr != rp and any(x for y in range(H) for x in got[y*rp + rr:(y+1)*rp]):
            bad += 1; print("  b%02d row padding is not zero" % bi)
        back = hwc_to_chw(dense, C, H, W)
        if back != src:
            bad += 1
            d = next(i for i in range(len(src)) if back[i] != src[i])
            print("  b%02d input differs from byte %d (c=%d y=%d x=%d): %d vs %d"
                  % (bi, d, d // (H * W), (d % (H * W)) // W, d % W, back[d], src[d]))
        nchk += len(src)

        C, H, W = b["out"]["c"], b["out"]["h"], b["out"]["w"]
        src = rd("b%02d_out.bin" % bi)
        o = g_base[bi] * BEAT
        back = hwc_to_chw(gold_hex[o:o + C * H * W], C, H, W)
        if back != src:
            bad += 1
            d = next(i for i in range(len(src)) if back[i] != src[i])
            print("  b%02d output differs from byte %d (c=%d y=%d x=%d): %d vs %d"
                  % (bi, d, d // (H * W), (d % (H * W)) // W, d % W, back[d], src[d]))
        nchk += len(src)

    # the probes, read out of the emitted image the way the testbench will
    for k, (c, y, x, off, v) in enumerate(in_prb):
        bi = k // 3
        b = B[bi]
        got = read_hex(os.path.join(out_dir, "ddr_in_b%02d.hex" % bi))
        if got[off] != v:
            bad += 1
            print("  b%02d input probe %d (c=%d y=%d x=%d) at HWC offset %d: "
                  "image has %d, the .bin says %d" % (bi, k % 3, c, y, x, off, got[off], v))
        nchk += 1
    for k, (c, y, x, off, v) in enumerate(out_prb):
        bi = k // 3
        if gold_hex[g_base[bi] * BEAT + off] != v:
            bad += 1
            print("  b%02d output probe %d (c=%d y=%d x=%d) at HWC offset %d: "
                  "image has %d, the .bin says %d"
                  % (bi, k % 3, c, y, x, off, gold_hex[g_base[bi] * BEAT + off], v))
        nchk += 1

    print("  %d values checked, %d errors" % (nchk, bad))
    print("=== gen_fuse_ddr verify: %s ===" % ("ALL PASS" if bad == 0 else "FAIL"))
    return bad == 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
