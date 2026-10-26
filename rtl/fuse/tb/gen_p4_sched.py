# -*- coding: utf-8 -*-
"""gen_p4_sched.py -- generate a schedule testbench for every block, from the manifest.

Substitutes each block's geometry, packs and row costs (E_ROW, D_ROW, P_ROW) into
the template tb_p4_schedule.v and writes one tb_p4_sched_b<NN>.v per block, next
to this file.

Reads:   golden/p1_golden/vec/p1_manifest.json, rtl/fuse/tb/tb_p4_schedule.v

  python gen_p4_sched.py [--depth N]     (--depth is parsed but not used)
"""
import io, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
VEC = os.path.abspath(os.path.join(HERE, "..", "..", "..", "golden", "p1_golden", "vec"))
MAN = os.path.join(VEC, "p1_manifest.json")
TPL = os.path.join(HERE, "tb_p4_schedule.v")


def main(depth):
    man = json.load(io.open(MAN, encoding="utf-8"))
    src = io.open(TPL, encoding="utf-8").read()
    made = []
    for bi, b in enumerate(man["blocks"]):
        cin, cmid, cout = b["in"]["c"], b["mid"]["c"], b["out"]["c"]
        ih, iw = b["mid"]["h"], b["mid"]["w"]          # the expand output's geometry
        oh, ow = b["out"]["h"], b["out"]["w"]
        s = b["dw_stride"]
        pe, pp = b["pack_e"]["pack"], b["pack_p"]["pack"]
        npe = b["pack_e"]["passes"]
        nseg_e = ((cin * (3 if b["stem"] else 1)) + 127) // 128
        # E_row includes the stem's kernel-row passes: the array is issued npe
        # times per input row.
        e_row = (iw // 4) * ((cmid + pe - 1) // pe) * nseg_e * npe
        p_row = (ow // 4) * ((cout + pp - 1) // pp) * ((cmid + 127) // 128)
        d_row = ((cmid + 7) // 8) * iw
        mod = "tb_p4_sched_b%02d" % bi
        t = src
        t = t.replace("module tb_p4_schedule;", "module %s;" % mod)
        t = t.replace("localparam integer C_IN = 16, C_MID = 96, C_OUT = 24;",
                      "localparam integer C_IN = %d, C_MID = %d, C_OUT = %d;" % (cin, cmid, cout))
        t = t.replace("localparam integer H_IN = 128, W_IN = 128;",
                      "localparam integer H_IN = %d, W_IN = %d;" % (ih, iw))
        t = t.replace("localparam integer S_DW = 2;", "localparam integer S_DW = %d;" % s)
        # The stem halves the width in the expand; only block 0 has it.
        t = t.replace("localparam integer STEM = 0;                  // per block, substituted",
                      "localparam integer STEM = %d;" % (1 if b["stem"] else 0))
        t = t.replace("localparam integer PACK_E = 4, PACK_P = 1;",
                      "localparam integer PACK_E = %d, PACK_P = %d;" % (pe, pp))
        # row costs come from the manifest, not from the template's defaults
        t = t.replace("localparam integer E_ROW = (W_IN/PIX) * ((C_MID + PACK_E - 1)/PACK_E) * ((C_IN + LANES - 1)/LANES);",
                      "localparam integer E_ROW = %d;" % e_row)
        t = t.replace("localparam integer P_ROW = (W_OUT/PIX) * ((C_OUT + PACK_P - 1)/PACK_P) * ((C_MID + LANES - 1)/LANES);",
                      "localparam integer P_ROW = %d;" % p_row)
        i = t.index("localparam integer D_ROW")
        j = t.index(";", i) + 1
        t = t[:i] + "localparam integer D_ROW = %d;" % d_row + t[j:]
        t = t.replace('$display("=== P4 schedule, block 1',
                      '$display("=== P4 schedule, block %d' % bi)
        t = t.replace("twn_blockseq #(.PIX(PIX)", "twn_blockseq #(.PIX(PIX)")
        io.open(os.path.join(HERE, mod + ".v"), "w", encoding="utf-8", newline="\n").write(t)
        made.append((bi, mod, e_row, d_row, p_row, oh, s))
    print("generated %d schedule testbenches" % len(made))
    for bi, mod, e, d, p, oh, s in made:
        print("  b%02d  s%d  E %6d  D %6d  P %6d  H_out %3d" % (bi, s, e, d, p, oh))


if __name__ == "__main__":
    dep = 5
    if "--depth" in sys.argv:
        dep = int(sys.argv[sys.argv.index("--depth") + 1])
    main(dep)
