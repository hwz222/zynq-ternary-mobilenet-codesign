# -*- coding: utf-8 -*-
"""gen_desctab.py -- the seventeen 16-word block descriptors twn_desctab.v decodes.

Reads:   golden/p1_golden/vec/p1_manifest.json       (the model's shape)
         golden/p1_golden/vec/fuse_weights_index.json (weight-file offsets, on-chip placement;
                                                written by pack_fuse_weights.py)
         tools/gather_cost.json                (through tailpack.gather_cost())
Writes:  rtl/fuse/tb/tb_desctab_words.vh   the words, for the testbench
         tools/fuse_desctab.h              the same words as C, for the PS driver
Slot assignment and capacity limits are asserted here, as twn_desctab checks them
at boot.

usage:  python tools/gen_desctab.py        (no arguments; run from any directory)
"""
import io, json, math, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tailpack as _tp     # shared with pack_fuse_weights.py: both must agree on which stages tail-pack

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VEC  = os.path.join(ROOT, "golden", "p1_golden", "vec")
TB   = os.path.join(ROOT, "rtl", "fuse", "tb")

man = json.load(io.open(os.path.join(VEC, "p1_manifest.json"), encoding="utf-8"))
idx = json.load(io.open(os.path.join(VEC, "fuse_weights_index.json"), encoding="utf-8"))
B, I = man["blocks"], idx["blocks"]
assert len(B) == len(I), (len(B), len(I))
N = len(B)

NOSLOT = 0xF                                   # in_slot code of block 0 (no input slot)

ROW_ALIGN = 128

def pad_row(v):
    """Round a row's byte count up to a whole row-buffer word (128 B).

    twn_act_rd commits a 1024-bit word only after eight 16-byte beats and
    computes its word count with an integer division, so a trailing partial
    word of a row would never be written. The stride is padded, not the
    tensor: the gather stops at the real row width.
    """
    return (v + ROW_ALIGN - 1) // ROW_ALIGN * ROW_ALIGN



def log2(v):
    assert v in (1, 2, 4, 8), v
    return {1: 0, 2: 1, 4: 2, 8: 3}[v]


def fit(v, bits, what):
    assert 0 <= v < (1 << bits), "%s = %d does not fit %d bits" % (what, v, bits)
    return v


words = []
for b, e in zip(B, I):
    bi = b["block"]
    c_in, c_mid, c_out = b["in"]["c"], b["mid"]["c"], b["out"]["c"]
    h_in, w_in = b["in"]["h"], b["in"]["w"]
    in_slot  = NOSLOT if bi == 0 else ((bi - 1) % 2)
    out_slot = bi % 2
    res_slot = in_slot
    w = [0] * 16
    w[0] = (fit(c_in, 10, "c_in") | (fit(c_mid, 10, "c_mid") << 10)
            | (fit(c_out, 10, "c_out") << 20)
            | ((1 if b["dw_stride"] == 2 else 0) << 30)
            | ((1 if b["has_residual"] else 0) << 31))
    w[1] = (fit(h_in, 9, "h_in") | (fit(w_in, 9, "w_in") << 9)
            | (log2(b["pack_e"]["pack"]) << 18) | (log2(b["pack_p"]["pack"]) << 21)
            | (in_slot << 24) | (out_slot << 28))
    w[2] = (fit(pad_row(c_in * w_in), 16, "row_bytes_in")
            | (fit(pad_row(c_out * b["out"]["w"]), 16, "row_bytes_out") << 16))
    w[3], w[4] = e["tern"]["off"], e["dw"]["off"]
    w[5], w[6] = e["rqa"]["off"],  e["rqd"]["off"]
    w[7] = fit(e["tern"]["words"], 16, "n_tern") | (fit(e["dw"]["words"], 16, "n_dw") << 16)
    w[8] = fit(e["rqa"]["words"], 16, "n_rqa")  | (fit(e["rqd"]["words"], 16, "n_rqd") << 16)
    w[9] = (fit(e["tern"]["mem_base"], 14, "mb_tern")
            | (fit(e["dw"]["mem_base"], 10, "mb_dw") << 14))
    w[10] = (fit(e["rqa"]["mem_base"], 13, "mb_rqa")
             | (fit(e["rqd"]["mem_base"], 13, "mb_rqd") << 13))
    w[11] = res_slot
    # n_seg: the manifest's n_seg_* is ceil(n_eff/128) alone; the stem runs
    # `passes` kernel-row passes per output row, so the hardware count is
    # n_seg * passes. ONE-BASED here; twn_uop_enc subtracts one.
    # bit 8 (stem) is a descriptor field, not derived from c_in == 3 or block 0.
    # bits 10:9 / 12:11 are segment 0's pack per stage; 0 means "same as pack"
    # (twn_fuse_array r_pack0 substitutes u_pack for 0).
    # pack0_for needs the measured t_gather of this block (tailpack.gather_cost())
    # and raises when it is missing.
    _tg = _tp.gather_cost()["blocks"][str(bi)]["t_gather"]
    _p0e = _tp.pack0_for(b["pack_e"]["n_eff"], c_mid,
                         int(math.log2(b["pack_e"]["pack"])), t_gather=_tg)
    _p0p = _tp.pack0_for(b["pack_p"]["n_eff"], c_out,
                         int(math.log2(b["pack_p"]["pack"])), t_gather=_tg)
    # Segment-outer walk (pack > 1 and n_seg > 1, the stem): twn_fuse_array keeps
    # a whole output row of partial sums, so the accumulator needs
    # n_xg << ceil_log2(n_ocg) entries. Overflow would alias pixel groups
    # silently, so it is asserted here. n_seg is the descriptor's own field
    # (n_seg_x * passes), not tailpack.n_seg(n_eff).
    for _tag, _key, _c, _res, _nsk in (("expand", "pack_e", c_mid, "mid", "n_seg_e"),
                                       ("project", "pack_p", c_out, "out", "n_seg_p")):
        _cfg = b[_key]
        _pk = int(math.log2(_cfg["pack"]))
        _nseg_hw = b[_nsk] * _cfg["passes"]
        _msg = b.get("msg_e" if _tag == "expand" else "msg_p", 0)
        if _msg:
            # An msg stage matches the signature but is not the stem.
            # twn_fuse_array forces seg_outer low when the micro-op carries
            # msg, because an msg stage segments a single activation word into
            # 32-channel chunks. Its walk is seg-INNER, so it needs n_ocg
            # entries rather than n_xg << ceil_log2(n_ocg) -- and it brings two
            # rules of its own, which are asserted here rather than assumed.
            _need_msg = _c >> _pk
            assert _need_msg <= _tp.accw_d(), (
                "block %d %s is mixed-segment packed, so it needs n_ocg %d "
                "accumulator entries and u_acc_w is %d deep"
                % (bi, _tag, _need_msg, _tp.accw_d()))
            assert _c % 16 == 0 and 4 * ((_c + 15) // 16) <= _c // 4, (
                "block %d %s is mixed-segment packed at pack 4 with C = %d, "
                "which twn_act_scatter cannot drain: it needs "
                "4*ceil(C/16) <= C/4" % (bi, _tag, _c))
            continue
        if _pk == 0 or _nseg_hw < 2:
            continue                                  # not the seg-outer shape
        _nxg = -(-b[_res]["w"] // 4)                  # ceil(w / PIX)
        _nocg = _c >> _pk
        _sh = max(0, (_nocg - 1).bit_length())        # ceil(log2(n_ocg))
        _need = _nxg << _sh
        assert _need <= _tp.accw_d(), (
            "block %d's %s walks the segment outside the pixel group (pack %d, "
            "n_seg %d), so it needs n_xg %d << %d = %d accumulator entries and "
            "u_acc_w is %d deep. Raise the depth or the walk will alias two "
            "pixel groups onto one entry with no error bit."
            % (bi, _tag, _cfg["pack"], _nseg_hw,
               _nxg, _sh, _need, _tp.accw_d()))

    assert _p0e == 0 or _tp.encoder_counts_appendix(), (
        "block %d's EXPAND wants tail packing, but twn_uop_enc's we_words does not "
        "add the appendix -- every project micro-op in this block would read 240 "
        "words too low, inside the expand's own weights, with no error bit." % bi)
    w[12] = (fit(b["n_seg_e"] * b["pack_e"]["passes"], 4, "n_seg_e")
             | (fit(b["n_seg_p"] * b["pack_p"]["passes"], 4, "n_seg_p") << 4)
             | ((1 if b.get("stem") else 0) << 8)
             | (fit(_p0e, 2, "pack0_e") << 9)
             | (fit(_p0p, 2, "pack0_p") << 11)
             # mixed-segment rotation, bits 13 and 14. The manifest
             # carries it because gen_p1.c decided it when it laid the
             # weights out; deriving it again here would be a second
             # copy of the rule, and the two would drift.
             | ((1 if b.get("msg_e") else 0) << 13)
             | ((1 if b.get("msg_p") else 0) << 14))
    # ---- words 13-15: the residual add's constants -------------------------
    # Blocks without a residual carry the identity (mp = 1, mq = 0, sh = 0, the
    # project clamp): twn_fuse_top runs every block through the same adder.
    # This is exact only while the project output is already int8, which the
    # assertions on clamp.p / relu.p below enforce.
    if b["has_residual"]:
        r = b["residual"]
        mp, mq, sh = r["mp"], r["mq"], r["sh"]
        lo, hi = r["clamp"]
    else:
        mp, mq, sh = 1, 0, 0
        lo, hi = b["clamp"]["p"]
    # NB_M0 = 18 signed and NB_SH = 6 in p0_fused.c; the asserts check 18 bits signed.
    assert -(1 << 17) <= mp < (1 << 17), "block %d mp %d does not fit 18 bits signed" % (bi, mp)
    assert -(1 << 17) <= mq < (1 << 17), "block %d mq %d does not fit 18 bits signed" % (bi, mq)
    w[13] = (mp & 0x3FFFF) | (fit(sh, 6, "sh_res") << 18)
    w[14] = (mq & 0x3FFFF)
    w[15] = (lo & 0xFFFF) | ((hi & 0xFFFF) << 16)
    words.append(w)

# The depthwise clamp and relu are constants in twn_fuse_top ([0,127], relu on):
# a model that differs fails here, at generation.
for b in B:
    assert b["clamp"]["d"] == [0, 127], (
        "block %d's depthwise clamp is %s, but twn_fuse_top ties it to [0,127]"
        % (b["block"], b["clamp"]["d"]))
    assert b["relu"]["d"] == 1, (
        "block %d's depthwise relu is %s, but twn_fuse_top assumes 1"
        % (b["block"], b["relu"]["d"]))
    # The residual identity needs the project output inside [lo, hi] = int8.
    assert b["clamp"]["p"] == [-127, 127] and b["relu"]["p"] == 0, (
        "block %d's project clamp is %s relu %s; the residual stage's identity "
        "for a block with no residual assumes an int8 project output"
        % (b["block"], b["clamp"]["p"], b["relu"]["p"]))

# twn_res_buf: 96 words of 16 B per row (RESB in twn_fuse_top). Only blocks that
# have a residual need to fit.
RES_BUF_ROW_BYTES = 96 * 16
for b in B:
    if b["has_residual"]:
        rb = pad_row(b["in"]["c"] * b["in"]["w"])
        assert rb <= RES_BUF_ROW_BYTES, (
            "block %d has a residual and an input row of %d bytes, but "
            "twn_res_buf holds %d" % (b["block"], rb, RES_BUF_ROW_BYTES))

# Padded strides must fit the row buffers (twn_fuse_top): RingA rows are
# A_WORDS = 17 words of 128 B, the last a guard word, so 16 usable; RB_OU rows
# are OU_WORDS = 160 words of 16 B.
RING_A_ROW_BYTES = 16 * 128
RB_OU_ROW_BYTES = 160 * 16
for b in B:
    r_in = pad_row(b["in"]["c"] * b["in"]["w"])
    r_out = pad_row(b["out"]["c"] * b["out"]["w"])
    assert r_in <= RING_A_ROW_BYTES, (
        "block %d input row stride %d bytes (padded from %d) exceeds RingA's %d"
        % (b["block"], r_in, b["in"]["c"] * b["in"]["w"], RING_A_ROW_BYTES))
    assert r_out <= RB_OU_ROW_BYTES, (
        "block %d output row stride %d bytes (padded from %d) exceeds RB_OU's %d"
        % (b["block"], r_out, b["out"]["c"] * b["out"]["w"], RB_OU_ROW_BYTES))

# slot rules checked here as well as at boot
for bi in range(N):
    i_s = NOSLOT if bi == 0 else ((bi - 1) % 2)
    o_s = bi % 2
    assert i_s != o_s, "block %d writes over the input it is still reading" % bi
    nxt = (bi + 1) % N
    n_i = NOSLOT if nxt == 0 else ((nxt - 1) % 2)
    assert n_i == NOSLOT or o_s == n_i, \
        "block %d writes slot %d, block %d reads slot %d" % (bi, o_s, nxt, n_i)

# the range check the hardware performs, so a failure is a build error
caps = idx["mem_words"]
for bi, (e, w) in enumerate(zip(I, words)):
    for k, cap in (("tern", caps["tern"]), ("dw", caps["dw"]),
                   ("rqa", caps["rqa"]), ("rqd", caps["rqd"])):
        assert e[k]["mem_base"] + e[k]["words"] <= cap, \
            "block %d's %s runs past the memory: %d + %d > %d" % (
                bi, k, e[k]["mem_base"], e[k]["words"], cap)

L = ["// generated by gen_desctab.py -- do not edit",
     "localparam integer DT_NBLK = %d;" % N,
     "localparam [32*16*%d-1:0] DT_WORDS = {" % N]
flat = []
for w in words:
    flat += w
L.append("    " + ",\n    ".join("32'h%08x" % v for v in reversed(flat)))
L.append("};")
io.open(os.path.join(TB, "tb_desctab_words.vh"), "w", newline="\n").write("\n".join(L) + "\n")

C = ["/* generated by gen_desctab.py -- do not edit */",
     "#ifndef FUSE_DESCTAB_H", "#define FUSE_DESCTAB_H",
     "#define FUSE_NBLK %d" % N,
     "#define FUSE_DESC_WORDS 16",
     "static const unsigned int fuse_desctab[%d * 16] = {" % N]
for bi, w in enumerate(words):
    C.append("    /* block %2d */ %s," % (bi, ", ".join("0x%08xu" % v for v in w)))
C += ["};", "#endif"]
io.open(os.path.join(ROOT, "tools", "fuse_desctab.h"), "w", newline="\n").write("\n".join(C) + "\n")

print("%d descriptors, %d words each" % (N, 16))
print("  block  c_in c_mid c_out  h    w   s pk_e pk_p in out  row_in row_out")
for b, w in zip(B, words):
    print("   %2d   %5d %5d %5d %4d %4d  %d   %d    %d   %2s  %2d  %6d %6d" % (
        b["block"], w[0] & 0x3FF, (w[0] >> 10) & 0x3FF, (w[0] >> 20) & 0x3FF,
        w[1] & 0x1FF, (w[1] >> 9) & 0x1FF, (w[0] >> 30) & 1,
        1 << ((w[1] >> 18) & 7), 1 << ((w[1] >> 21) & 7),
        "-" if ((w[1] >> 24) & 0xF) == NOSLOT else ((w[1] >> 24) & 0xF),
        (w[1] >> 28) & 0xF, w[2] & 0xFFFF, (w[2] >> 16) & 0xFFFF))
