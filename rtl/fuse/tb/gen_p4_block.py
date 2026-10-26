# -*- coding: utf-8 -*-
"""gen_p4_block.py -- bit-exact block test: one block through the real sequencer,
the real ternary array and the real depthwise array.

Real:    twn_blockseq (credit handshake, window threshold, pointer rule, counters),
         twn_fuse_array (one instance serves expand and project), twn_dw_array.
Modelled in the testbench: the four row buffers (arrays; twn_rowbuf is tested
         separately) and the AXI masters.

The ternary array emits PIX x OCMAX = 4 pixels x 4 channels per beat (128 bit); the
depthwise consumes DW_LANES = 8 channels x 1 pixel per beat (64 bit). The tern1 row
buffer is written channel-group-major and read pixel-major, so a wrong transpose
between the two arrays shows up here.

Reads:   golden/p1_golden/vec/p1_manifest.json and, for block N, b<NN>_in, _out, _wte, _wtp,
         _wdw, _rqe, _rqd, _rqp, _e, _d (and _res, _p when the block has a residual)
         .bin (from golden/p1_golden/run_p1.sh); template tb_p4_block.v (block != 1)
Writes:  next to the output name: <name>_actin, _wte, _wtp, _rqe{m0,bs,sh}, _rqp{m0,bs,sh},
         _wdw, _rqd{m0,bs,sh}, _gold, _golde, _goldd (and _res, _goldp) .hex.
         Block 1 (default) writes only these hex files, for the checked-in
         tb_p4_block.v; other blocks also write tb_p4_block_b<NN>.v from that template.

  python gen_p4_block.py [--block N] [-o tb_p4_block.v]
"""
import io, json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
VEC = os.path.abspath(os.path.join(HERE, "..", "..", "..", "golden", "p1_golden", "vec"))
MAN = os.path.join(VEC, "p1_manifest.json")
LANES, PIX, OCMAX, DW_LANES = 128, 4, 4, 8
# block to generate (default 1); --block N selects another
BI = int(sys.argv[sys.argv.index('--block') + 1]) if '--block' in sys.argv else 1


def i8(b):
    return [x - 256 if x > 127 else x for x in b]


def rq_table(name, oc):
    d = open(os.path.join(VEC, name + ".bin"), "rb").read()
    m0 = list(struct.unpack("<%di" % oc, d[:4 * oc]))
    bs = list(struct.unpack("<%dq" % oc, d[4 * oc:12 * oc]))
    sh = list(d[12 * oc:])
    return m0, bs, sh


def bits(vals, w):
    m = (1 << w) - 1
    return sum((v & m) << (w * i) for i, v in enumerate(vals))


def hexf(path, vals, nbits):
    d = nbits // 4
    with io.open(path, "w") as f:
        for v in vals:
            f.write(("%0" + str(d) + "x") % (v & ((1 << nbits) - 1)) + "\n")


def main(out):
    man = json.load(io.open(MAN, encoding="utf-8"))
    b = man["blocks"][BI]
    C_IN, C_MID, C_OUT = b["in"]["c"], b["mid"]["c"], b["out"]["c"]
    # n_eff for the stem is Cin x 3: one kernel row per pass, so a pass sees three
    # colour channels x three kernel columns = 9 taps; the kernel rows are the passes.
    n_eff_e = C_IN * 3 if b["stem"] else C_IN
    # The expand's output geometry (the mid tensor), not the block input; they
    # differ where expand_stride is 2 (block 0).
    IH, IW = b["mid"]["h"], b["mid"]["w"]
    OH, OW = b["out"]["h"], b["out"]["w"]
    s_dw = b["dw_stride"]
    pack_e, pack_p = b["pack_e"]["pack"], b["pack_p"]["pack"]
    # the packing factors come from the manifest; only 1, 2 and 4 are supported
    assert pack_e in (1, 2, 4) and pack_p in (1, 2, 4), (pack_e, pack_p)

    X = i8(open(os.path.join(VEC, "b%02d_in" % BI + ".bin"), "rb").read())
    GOLD = i8(open(os.path.join(VEC, "b%02d_out" % BI + ".bin"), "rb").read())
    WE = open(os.path.join(VEC, "b%02d_wte" % BI + ".bin"), "rb").read()
    WP = open(os.path.join(VEC, "b%02d_wtp" % BI + ".bin"), "rb").read()
    WD = i8(open(os.path.join(VEC, "b%02d_wdw" % BI + ".bin"), "rb").read())
    m0e, bse, she = rq_table("b%02d_rqe" % BI, C_MID)
    m0d, bsd, shd = rq_table("b%02d_rqd" % BI, C_MID)
    m0p, bsp, shp = rq_table("b%02d_rqp" % BI, C_OUT)

    d = os.path.dirname(out) or "."
    base = os.path.splitext(os.path.basename(out))[0]

    # ---- block input, as the ternary array wants it: 4096-bit word per (row, seg, xg) ----
    # lane k of pixel p = input channel seg*128 + k; unused lanes are zero.
    # A segmented expand addresses activations as act_base + seg * n_xg + xg,
    # so the loop over segments is needed.
    n_xg_e = (IW + PIX - 1) // PIX
    n_segch = (n_eff_e + LANES - 1) // LANES
    npass   = b["pack_e"]["passes"]
    n_seg_e = npass * n_segch                 # the passes multiply in
    # Mixed segment (msg): the manifest's n_seg counts 32-channel chunks of one
    # activation word, so the weights come n_seg words per group while every
    # segment reads the same activation word.
    msg_e = b.get("msg_e", 0)
    if msg_e:
        n_seg_e = b["n_seg_e"]
    e_str   = b["expand_stride"]
    pad     = 1 if b["stem"] else 0
    IHi, IWi = b["in"]["h"], b["in"]["w"]     # the input geometry (differs from the
                                              # mid's at expand_stride 2)
    amem_in = []
    for row in range(IH):
        for seg in range(n_seg_e):
            for xg in range(n_xg_e):
                wrd = []
                for pp in range(PIX):
                    ox = xg * PIX + pp
                    lane = [0] * LANES
                    if ox < IW:
                        if b["stem"]:
                            # One kernel row per pass: seg is ky. A pass gathers
                            # three colour channels x three kernel columns into
                            # nine lanes, channel-major (lane = c*3 + kx). Rows and
                            # columns outside the image are the zero pad.
                            iy = row * e_str - pad + seg
                            for c in range(C_IN):
                                for kx in range(3):
                                    ix = ox * e_str - pad + kx
                                    if 0 <= iy < IHi and 0 <= ix < IWi:
                                        lane[c * 3 + kx] = X[(c * IHi + iy) * IWi + ix]
                        else:
                            for k in range(LANES):
                                c = k if msg_e else seg * LANES + k
                                if c < C_IN:
                                    lane[k] = X[(c * IH + row) * IW + ox]
                    wrd.append(bits(lane, 8))
                amem_in.append(sum(w << (1024 * i) for i, w in enumerate(wrd)))
    hexf(os.path.join(d, base + "_actin.hex"), amem_in, 4096)

    # ---- weights, 128 lanes x 2 bit per word ----
    hexf(os.path.join(d, base + "_wte.hex"),
         [int.from_bytes(WE[i * 32:(i + 1) * 32], "little") for i in range(len(WE) // 32)], 256)
    hexf(os.path.join(d, base + "_wtp.hex"),
         [int.from_bytes(WP[i * 32:(i + 1) * 32], "little") for i in range(len(WP) // 32)], 256)

    # ---- requant, dense: OCMAX channels per group, ceil(oc/OCMAX) groups ----
    # Same layout as tools/pack_fuse_weights.py (four channels per 256-bit group,
    # every lane live); the array reads rq_base + ch0/4 with the lanes rotated down
    # by ch0%4.
    def rq_pack(m0, bs, sh, oc, pack, name):
        n_dense = (oc + OCMAX - 1) // OCMAX
        mm, bb, ss = [], [], []
        for g in range(n_dense):
            a1, a2, a3 = [], [], []
            for j in range(OCMAX):
                c = g * OCMAX + j
                live = c < oc
                a1.append(m0[c] if live else 0)
                a2.append(bs[c] if live else 0)
                a3.append(sh[c] if live else 0)
            mm.append(bits(a1, 18)); bb.append(bits(a2, 40)); ss.append(bits(a3, 6))
        hexf(os.path.join(d, base + "_" + name + "m0.hex"), mm, OCMAX * 18)
        hexf(os.path.join(d, base + "_" + name + "bs.hex"), bb, OCMAX * 40)
        hexf(os.path.join(d, base + "_" + name + "sh.hex"), ss, OCMAX * 6)
        # n_ocg is ceil(oc/pack), the uop's loop count, not the table depth. The
        # testbench sizes its requant memories at C/PACK, which is >= the dense
        # count, so the tail stays X and an array walking per-ocg addresses would
        # read X and mismatch.
        return (oc + pack - 1) // pack, n_dense
    n_ocg_e, n_rqw_e = rq_pack(m0e, bse, she, C_MID, pack_e, "rqe")
    n_ocg_p, n_rqw_p = rq_pack(m0p, bsp, shp, C_OUT, pack_p, "rqp")

    # ---- depthwise: weights and requant, one lane group of 8 per entry ----
    n_lg = (C_MID + DW_LANES - 1) // DW_LANES
    wd, dm, db, ds = [], [], [], []
    for g in range(n_lg):
        tw, a1, a2, a3 = [], [], [], []
        for j in range(DW_LANES):
            c = g * DW_LANES + j
            live = c < C_MID
            for k in range(9):
                tw.append(WD[c * 9 + k] if live else 0)
            a1.append(m0d[c] if live else 0)
            a2.append(bsd[c] if live else 0)
            a3.append(shd[c] if live else 0)
        wd.append(bits(tw, 8)); dm.append(bits(a1, 18)); db.append(bits(a2, 32)); ds.append(bits(a3, 6))
    hexf(os.path.join(d, base + "_wdw.hex"), wd, DW_LANES * 9 * 8)
    hexf(os.path.join(d, base + "_rqdm0.hex"), dm, DW_LANES * 18)
    hexf(os.path.join(d, base + "_rqdbs.hex"), db, DW_LANES * 32)
    hexf(os.path.join(d, base + "_rqdsh.hex"), ds, DW_LANES * 6)

    # ---- golden block output, byte per (channel, row, pixel) ----
    hexf(os.path.join(d, base + "_gold.hex"), [v & 0xFF for v in GOLD], 8)

    # ---- the two intermediate goldens, so a failure can be localised ----
    GE = i8(open(os.path.join(VEC, "b%02d_e" % BI + ".bin"), "rb").read())
    GD = i8(open(os.path.join(VEC, "b%02d_d" % BI + ".bin"), "rb").read())
    hexf(os.path.join(d, base + "_golde.hex"), [v & 0xFF for v in GE], 8)
    hexf(os.path.join(d, base + "_goldd.hex"), [v & 0xFF for v in GD], 8)

    # ---- the residual source, for blocks that have one ----
    # An inverted-residual block adds its own input back, so the source has the
    # output's shape; b*_res.bin is that source as the reference wrote it.
    if b["has_residual"]:
        RS = i8(open(os.path.join(VEC, "b%02d_res" % BI + ".bin"), "rb").read())
        GP = i8(open(os.path.join(VEC, "b%02d_p" % BI + ".bin"), "rb").read())
        hexf(os.path.join(d, base + "_res.hex"),   [v & 0xFF for v in RS], 8)
        hexf(os.path.join(d, base + "_goldp.hex"), [v & 0xFF for v in GP], 8)

    print("block %d: C %d -> %d -> %d, %dx%d -> %dx%d, dw stride %d" %
          (BI, C_IN, C_MID, C_OUT, IH, IW, OH, OW, s_dw))
    print("  pack_e %d (n_ocg %d, %d dense rq words)   pack_p %d (n_ocg %d, %d dense "
          "rq words)   dw lane groups %d" %
          (pack_e, n_ocg_e, n_rqw_e, pack_p, n_ocg_p, n_rqw_p, n_lg))
    print("  act words %d   golden bytes %d" % (len(amem_in), len(GOLD)))
    print("  hex written next to %s" % out)
    return dict(C_IN=C_IN, C_MID=C_MID, C_OUT=C_OUT, IH=IH, IW=IW, OH=OH, OW=OW,
                n_wte=len(WE) // 32, n_wtp=len(WP) // 32,
                n_eff_e=n_eff_e, n_eff_p=C_MID, npass=b["pack_e"]["passes"],
                msg_e=msg_e, n_seg_e=n_seg_e,
                n_xg_e=n_xg_e, n_ocg_e=n_ocg_e, n_ocg_p=n_ocg_p, n_lg=n_lg,
                n_act=len(amem_in), n_gold=len(GOLD),
                n_golde=len(GE), n_goldd=len(GD),
                has_res=b["has_residual"], stem=b["stem"],
                res=b.get("residual", {"mp": 0, "mq": 0, "sh": 0,
                                       "clamp": [-127, 127]}))


def emit_tb(info, out, s_dw, pack_e, pack_p):
    """Write the testbench for this block, using tb_p4_block.v (block 1's) as the
    template: the geometry, hex names, pack codes and stride are substituted.
    """
    base = os.path.splitext(os.path.basename(out))[0]
    t = io.open(os.path.join(HERE, "tb_p4_block.v"), encoding="utf-8").read()
    PC = {1: 0, 2: 1, 4: 2, 8: 3}
    subs = [
        ("module tb_p4_block;", "module %s;" % base),
        ('"tb_p4_block_', '"%s_' % base),
        ("localparam integer C_IN = 16, C_MID = 96, C_OUT = 24;",
         "localparam integer C_IN = %d, C_MID = %d, C_OUT = %d;"
         % (info["C_IN"], info["C_MID"], info["C_OUT"])),
        ("localparam integer IH = 128, IW = 128, OH = 64, OW = 64;",
         "localparam integer IH = %d, IW = %d, OH = %d, OW = %d;"
         % (info["IH"], info["IW"], info["OH"], info["OW"])),
        ("localparam integer N_EFF_E = 24;",
         "localparam integer N_EFF_E = %d;" % info["n_eff_e"]),
        ("localparam integer N_PASS_E = 1;              // per block, substituted",
         "localparam integer N_PASS_E = %d;" % info["npass"]),
        ("localparam integer MSG_E = 0, N_SEG_MSG_E = 1;  // per block, substituted",
         "localparam integer MSG_E = %d, N_SEG_MSG_E = %d;" % (info["msg_e"], info["n_seg_e"])),
        ("localparam integer N_EFF_P = 96;",
         "localparam integer N_EFF_P = %d;" % info["n_eff_p"]),
        ("localparam integer PACK_E = 4, PACK_P = 1;",
         "localparam integer PACK_E = %d, PACK_P = %d;" % (pack_e, pack_p)),
        (".s_dw(1'b1),", ".s_dw(1'b%d)," % (1 if s_dw == 2 else 0)),
        ("localparam integer S_DW = 2;                  // per block, substituted",
         "localparam integer S_DW = %d;" % s_dw),
        ("localparam integer HAS_RES = 0;", "localparam integer HAS_RES = %d;"
         % (1 if info["has_res"] else 0)),
        # Zero even for block 0. twn_blockseq's `stem` input halves h_in and w_in
        # to get the expand's output size; this testbench's IH/IW already are the
        # mid geometry, so STEM = 1 would halve a second time. The sequencer's stem
        # arithmetic is exercised by tb_uop_issue (true input height with stem = 1).
        ("localparam integer STEM = 0;                  // per block, substituted",
         "localparam integer STEM = 0;   // see gen_p4_block.py: IH is already the mid height"),
        ("localparam integer RES_MP = 0, RES_MQ = 0, RES_SH = 0;",
         "localparam integer RES_MP = %d, RES_MQ = %d, RES_SH = %d;"
         % (info["res"]["mp"], info["res"]["mq"], info["res"]["sh"])),
        ("localparam integer RES_LO = -127, RES_HI = 127;",
         "localparam integer RES_LO = %d, RES_HI = %d;"
         % (info["res"]["clamp"][0], info["res"]["clamp"][1])),
        (".pack_e(3'd2), .pack_p(3'd0),",
         ".pack_e(3'd%d), .pack_p(3'd%d)," % (PC[pack_e], PC[pack_p])),
        # the sequencer's row ports are nine bits (block 0 needs 128+ rows)
        ("wire [7:0] e_row, d_row, p_row, ld_row, st_row;",
         "wire [8:0] e_row, d_row, p_row, ld_row, st_row;"),
        ("in_wptr - {2'b0, e_row}", "in_wptr - {1'b0, e_row}"),
        ("dw_wptr - {2'b0, p_row}", "dw_wptr - {1'b0, p_row}"),
        ("out_cnt - {2'b0, st_row}", "out_cnt - {1'b0, st_row}"),
        # take the real ternary weight memory sizes
        ("localparam integer N_WTE = 64, N_WTP = 64;   // per block, substituted",
         "localparam integer N_WTE = %d, N_WTP = %d;"
         % (info["n_wte"], info["n_wtp"])),
        # rowbuf_tern1 is five rows deep
        ("reg signed [7:0] t1buf [0:4*C_MID*IW-1];           // 4 rows of expand output",
         "reg signed [7:0] t1buf [0:5*C_MID*IW-1];           // 5 rows of expand output"),
        ("localparam integer D_IN = 4, D_T1 = 4, D_DW = 2, D_OUT = 2;",
         "localparam integer D_IN = 4, D_T1 = 5, D_DW = 2, D_OUT = 2;"),
    ]
    for a, b in subs:
        if a not in t:
            raise SystemExit("template no longer contains: %s" % a[:60])
        t = t.replace(a, b)
    io.open(out, "w", encoding="utf-8", newline=chr(10)).write(t)
    print("  wrote %s" % os.path.basename(out))


if __name__ == "__main__":
    o = "tb_p4_block.v" if BI == 1 else "tb_p4_block_b%02d.v" % BI
    if "-o" in sys.argv:
        o = sys.argv[sys.argv.index("-o") + 1]
    op = os.path.join(HERE, o) if not os.path.dirname(o) else o
    info = main(op)
    if BI != 1:
        man = json.load(io.open(MAN, encoding="utf-8"))
        b = man["blocks"][BI]
        emit_tb(info, op, b["dw_stride"], b["pack_e"]["pack"], b["pack_p"]["pack"])
