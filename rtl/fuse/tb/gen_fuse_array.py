# -*- coding: utf-8 -*-
"""gen_fuse_array.py -- emit a full-array testbench: twn_fuse_array driving its
three memories, checked element for element against the P1 golden output row.

The golden row is what the block boundary sees: after cross-segment accumulation,
requant, ReLU and clamp. The generated case exercises the segment-outer/pixel-group
loop order, the narrow and wide accumulators (the stem uses the wide one) and the
pack-wide requant table.

Reads:   golden/p1_golden/vec/p1_manifest.json and, per case, b??_in / b??_d, b??_e / b??_p /
         b??_out, b??_wte / b??_wtp, b??_rqe / b??_rqp (.bin; from golden/p1_golden/run_p1.sh)
Writes:  the testbench .v (-o, default tb_fuse_ar_b<NN><e|p>.v in the current directory)

  python gen_fuse_array.py <block> <e|p> [--row N] [-o out.v] [--split N] [--asplit N]
  python gen_fuse_array.py --sweep     one case per (pack, stem, multi-segment) class
--split / --asplit set the RQ_SPLIT / ACC_SPLIT parameters baked into the testbench.
"""
import io, json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
VEC  = os.path.abspath(os.path.join(HERE, "..", "..", "..", "golden", "p1_golden", "vec"))
MAN  = os.path.join(VEC, "p1_manifest.json")
LANES, PIX, OCMAX = 128, 4, 4
SPLIT = 0          # RQ_SPLIT parameter baked into the case; set by --split
ASPLIT = 0         # ACC_SPLIT parameter baked into the case; set by --asplit


def load():
    if not os.path.exists(MAN):
        sys.exit("no P1 manifest at %s -- run golden/p1_golden/run_p1.sh first" % MAN)
    return json.load(io.open(MAN, encoding="utf-8"))


def i8(b):
    return [x - 256 if x > 127 else x for x in b]


def rq_table(name, oc):
    d = open(os.path.join(VEC, name + ".bin"), "rb").read()
    m0 = list(struct.unpack("<%di" % oc, d[:4 * oc]))
    bs = list(struct.unpack("<%dq" % oc, d[4 * oc:12 * oc]))
    sh = list(d[12 * oc:])
    return m0, bs, sh


def bits(vals, w):
    v = 0
    for k, a in enumerate(vals):
        v |= (a & ((1 << w) - 1)) << (w * k)
    return v


def emit(man, bi, stage, row, out):
    global SPLIT, ASPLIT
    b = man["blocks"][bi]
    pk = b["pack_e"] if stage == "e" else b["pack_p"]
    n_eff, npass, pack = pk["n_eff"], pk["passes"], pk["pack"]
    L = 128 // pack if pack > 1 else ((n_eff + 127) // 128) * 128
    n_segch = (n_eff + 127) // 128          # segments from the channel count
    n_seg = npass * n_segch                 # passes multiply in
    stem = b["stem"] and stage == "e"
    # A mixed-segment (msg) stage splits one activation word into 32-channel
    # chunks: the manifest's n_seg is the number of weight words per group and
    # every segment reads the same activation word (p_off is 0 when r_msg).
    msg = b.get("msg_e" if stage == "e" else "msg_p", 0)
    if msg:
        n_seg = b["n_seg_e" if stage == "e" else "n_seg_p"]

    if stage == "e":
        src, dst = "b%02d_in" % bi, "b%02d_e" % bi
        ic, ih, iw = b["in"]["c"], b["in"]["h"], b["in"]["w"]
        oc, oh, ow = b["mid"]["c"], b["mid"]["h"], b["mid"]["w"]
        stride, pad = b["expand_stride"], (1 if stem else 0)
        wt, rq = "b%02d_wte" % bi, "b%02d_rqe" % bi
        clamp, relu = b["clamp"]["e"], b["relu"]["e"]
    else:
        src, dst = "b%02d_d" % bi, ("b%02d_p" % bi if b["has_residual"] else "b%02d_out" % bi)
        ic, ih, iw = b["mid"]["c"], b["out"]["h"], b["out"]["w"]
        oc, oh, ow = b["out"]["c"], b["out"]["h"], b["out"]["w"]
        stride, pad = 1, 0
        wt, rq = "b%02d_wtp" % bi, "b%02d_rqp" % bi
        clamp, relu = b["clamp"]["p"], b["relu"]["p"]

    # Do not skip cases the hardware cannot represent: a generator that does so
    # reports the design's own limit back as a pass.
    if n_seg > 8:
        raise SystemExit('n_seg %d exceeds the uop field even minus-one encoded '
                         '(max 8); widen the field rather than skipping the case'
                         % n_seg)
    X = i8(open(os.path.join(VEC, src + ".bin"), "rb").read())
    Y = i8(open(os.path.join(VEC, dst + ".bin"), "rb").read())
    W = open(os.path.join(VEC, wt + ".bin"), "rb").read()
    m0, bs, sh = rq_table(rq, oc)
    n_xg = (ow + PIX - 1) // PIX
    n_ocg = (oc + pack - 1) // pack
    if n_ocg > 1023 or n_ocg < 2:
        return None                          # n_ocg is a 10-bit field; prefetch needs n_ocg >= 2

    # ---- activation memory: one 4096-bit word per (segment, pixel group) ----
    # Lane k of pixel p holds, for a 1x1, input channel seg*128+k at pixel
    # xg*PIX+p; for the stem, tap ic*3+kx of kernel row `seg`.
    amem = []
    for seg in range(1 if msg else n_seg):   # msg: one word serves every segment
        for xg in range(n_xg):
            wrd = []
            for p in range(PIX):
                ox = xg * PIX + p
                lane = [0] * LANES
                if ox < ow:
                    if stem:
                        ky = seg
                        iy = row * stride - pad + ky
                        for c in range(ic):
                            for kx in range(3):
                                ix = ox * stride - pad + kx
                                if 0 <= iy < ih and 0 <= ix < iw:
                                    lane[c * 3 + kx] = X[(c * ih + iy) * iw + ix]
                    else:
                        iy, ix = row * stride, ox * stride
                        for k in range(LANES):
                            c = seg * 128 + k
                            if c < ic and iy < ih and ix < iw:
                                lane[k] = X[(c * ih + iy) * iw + ix]
                wrd.append(bits(lane, 8))
            amem.append(sum(w << (1024 * i) for i, w in enumerate(wrd)))

    # ---- weight memory: address = group * n_seg + seg ----
    nw = len(W) // 32
    wmem = [int.from_bytes(W[i * 32:(i + 1) * 32], "little") for i in range(nw)]

    # ---- requant memory: dense, OCMAX channels per group ----
    # Same grouping as tools/pack_fuse_weights.py (four channels per 256-bit word
    # regardless of pack). The memory is still declared n_ocg deep so an array
    # walking the wrong addresses reads X rather than a plausible neighbour.
    n_rqw = (oc + OCMAX - 1) // OCMAX
    rmem_m0, rmem_bs, rmem_sh = [], [], []
    for g in range(n_rqw):
        mm, bb, ss = [], [], []
        for j in range(OCMAX):
            c = g * OCMAX + j
            live = c < oc
            mm.append(m0[c] if live else 0)
            bb.append(bs[c] if live else 0)
            ss.append(sh[c] if live else 0)
        rmem_m0.append(bits(mm, 18)); rmem_bs.append(bits(bb, 40)); rmem_sh.append(bits(ss, 6))

    otype = 0 if clamp[0] == 0 else 1
    # uop fields: row at [9:1], n_pix [18:10], n_seg-1 [21:19], n_ocg [31:22],
    # pack [33:32], relu [82], otype [84:83], dst [85], msg [90] (mixed-segment
    # rotation, as twn_uop_enc takes it from the descriptor). pack0 [89:88] stays 0:
    # the P1 weight words are not tail-packed. Base fields are 0.
    uop = (0 | (row << 1) | (ow << 10) | ((n_seg - 1) << 19) | (n_ocg << 22) |
           ({1: 0, 2: 1, 4: 2, 8: 3}[pack] << 32) | (0 << 34) | (0 << 51) | (0 << 69) |
           (relu << 82) | (otype << 83) | (0 << 85) | (1 << 86) | (1 << 87) | (msg << 90))

    mod = os.path.splitext(os.path.basename(out))[0]
    A = []
    a = A.append
    a("// AUTO-GENERATED by rtl/fuse/tb/gen_fuse_array.py from the P1 golden vectors -- do not edit.")
    a("// block %d, %s stage, output row %d.  n_eff=%d pack=%d n_seg=%d (%d pass x %d chan-seg)"
      % (bi, stage, row, n_eff, pack, n_seg, npass, n_segch))
    a("// n_ocg=%d  n_xg=%d  out %dx%d  clamp [%d,%d] relu %d"
      % (n_ocg, n_xg, oc, ow, clamp[0], clamp[1], relu))
    a("// Expected values are P1's golden output row -- the model's own numbers, through")
    a("// the path that passed P0. A mismatch here is the array disagreeing with the network.")
    a("`timescale 1ns/1ps")
    a("module %s;" % mod)
    a("  localparam integer PIX = %d, OCMAX = %d, LANES = %d;" % (PIX, OCMAX, LANES))
    a("  localparam integer N_XG = %d, N_OCG = %d, N_SEG = %d, PACK = %d, OC = %d, OW = %d;"
      % (n_xg, n_ocg, n_seg, pack, oc, ow))
    a("  localparam integer RQ_SPLIT  = %d;  // baked in, per this repo's testbench convention" % SPLIT)
    a("  localparam integer ACC_SPLIT = %d;" % ASPLIT)
    a("  reg clk = 0; always #2 clk = ~clk;")
    a("  reg rst = 1;")
    a("")
    a("  // ---- memories, preloaded ----")
    a("  reg [PIX*LANES*8-1:0] amem [0:%d];" % (len(amem) - 1))
    a("  reg [LANES*2-1:0]     wmem [0:%d];" % (nw - 1))
    a("  reg [OCMAX*18-1:0]    rm0  [0:%d];" % (n_ocg - 1))
    a("  reg [OCMAX*40-1:0]    rbs  [0:%d];" % (n_ocg - 1))
    a("  reg [OCMAX*6-1:0]     rsh  [0:%d];" % (n_ocg - 1))
    a("  initial begin")
    for i, v in enumerate(amem):
        a("    amem[%d] = %d'h%01024x;" % (i, PIX * LANES * 8, v))
    for i, v in enumerate(wmem):
        a("    wmem[%d] = %d'h%064x;" % (i, LANES * 2, v))
    for i in range(n_rqw):
        a("    rm0[%d] = %d'h%036x; rbs[%d] = %d'h%080x; rsh[%d] = %d'h%012x;"
          % (i, OCMAX * 18, rmem_m0[i], i, OCMAX * 40, rmem_bs[i], i, OCMAX * 6, rmem_sh[i]))
    a("  end")
    a("")
    a("  wire [16:0] act_addr, out_addr; wire [17:0] w_addr; wire [12:0] rq_addr;")
    a("  wire act_re, w_re, busy, done, out_valid, out_dst;")
    a("  reg  [PIX*LANES*8-1:0] act_data;")
    a("  reg  [LANES*2-1:0]     w_data;")
    a("  reg  [OCMAX*18-1:0]    rq_m0;")
    a("  reg  [OCMAX*40-1:0]    rq_bias;")
    a("  reg  [OCMAX*6-1:0]     rq_sh;")
    a("  wire [PIX*OCMAX*8-1:0] out_data;")
    a("  // The activation handshake, at the fixed latency this sweep has always")
    a("  // used: the memory answers in one cycle and `valid` follows the request")
    a("  // by two, which is what the array used to ASSUME rather than check.")
    a("  // That is the right model HERE -- this file measures the datapath's")
    a("  // pipeline depth and its arithmetic, not the producer's timing -- and")
    a("  // exactly the wrong model for a gate about the producer. The one that")
    a("  // varies the latency is rtl/fuse/tb/tb_p4_block.v; see its producer.")
    a("  reg  act_re_d1 = 0, act_valid = 0;")
    a("  wire act_ready = 1'b1;")
    a("  always @(posedge clk) begin")
    a("    act_data <= amem[act_addr];")
    a("    w_data   <= wmem[w_addr];")
    a("    rq_m0    <= rm0[rq_addr]; rq_bias <= rbs[rq_addr]; rq_sh <= rsh[rq_addr];")
    a("    act_re_d1 <= act_re; act_valid <= act_re_d1;")
    a("  end")
    a("")
    a("  reg  [94:0] uop = 95'h%024x;" % uop)
    a("  reg  uop_valid = 0;")
    a("  // RQ_SPLIT is the pipeline-depth knob under test; the testbench does not")
    a("  // care what it is set to, because it waits on  rather than on a count.")
    a("  twn_fuse_array #(.LANES(LANES), .PIX(PIX), .OCMAX(OCMAX),")
    a("                   .RQ_SPLIT(RQ_SPLIT), .ACC_SPLIT(ACC_SPLIT)) dut (")
    a("    .clk(clk), .rst(rst), .uop(uop), .uop_valid(uop_valid), .busy(busy), .done(done),")
    a("    .act_addr(act_addr), .act_re(act_re), .act_data(act_data),")
    a("    .act_ready(act_ready), .act_valid(act_valid),")
    a("    .w_addr(w_addr), .w_re(w_re), .w_data(w_data),")
    a("    .rq_addr(rq_addr), .rq_m0(rq_m0), .rq_bias(rq_bias), .rq_sh(rq_sh),")
    a("    .out_data(out_data), .out_valid(out_valid), .out_addr(out_addr), .out_dst(out_dst));")
    a("")
    a("  // ---- golden output row ----")
    a("  reg signed [7:0] gold [0:%d];" % (oc * ow - 1))
    a("  initial begin")
    for c in range(oc):
        for x in range(ow):
            v = Y[(c * oh + row) * ow + x]
            a("    gold[%d] = %s8'sd%d;" % (c * ow + x, "-" if v < 0 else " ", abs(v)))
    a("  end")
    a("")
    a("  integer errs = 0, seen = 0, k, pp, jj, cc, xx;")
    a("  integer cyc = 0;")
    a("  always @(posedge clk) if (busy) cyc = cyc + 1;")
    a("  always @(posedge clk) if (out_valid) begin")
    a("    for (pp = 0; pp < PIX; pp = pp + 1)")
    a("      for (jj = 0; jj < PACK; jj = jj + 1) begin")
    a("        cc = (out_addr / N_XG) * PACK + jj;")
    a("        xx = (out_addr % N_XG) * PIX + pp;")
    a("        if (cc < OC && xx < OW) begin")
    a("          seen = seen + 1;")
    a("          if ($signed(out_data[(pp*OCMAX + jj)*8 +: 8]) !== gold[cc*OW + xx]) begin")
    a("            if (errs < 8) $display(\"FAIL ch %0d px %0d: got %0d expected %0d\",")
    a("                                  cc, xx, $signed(out_data[(pp*OCMAX + jj)*8 +: 8]),")
    a("                                  gold[cc*OW + xx]);")
    a("            errs = errs + 1;")
    a("          end")
    a("        end")
    a("      end")
    a("  end")
    a("")
    a("  initial begin")
    a("    // Drive off the clock edge, not on it: a blocking assignment made AT the")
    a("    // edge races the DUT's sampling of the same signal, and uop_valid gets")
    a("    // missed entirely -- which shows up as `0 elements seen`, not as a hang.")
    a("    repeat (4) @(posedge clk); #1; rst = 0;")
    a("    @(posedge clk); #1; uop_valid = 1;")
    a("    @(posedge clk); #1; uop_valid = 0;")
    a("    @(posedge done);")
    a("    repeat (4) @(posedge clk);")
    a("    if (errs == 0 && seen == OC*OW)")
    a("      $display(\"%m PASS -- %0d of %0d elements, %0d cycles busy (ideal %0d, %0d%% efficiency)\",")
    a("               seen, OC*OW, cyc, N_XG*N_SEG*N_OCG, (100*N_XG*N_SEG*N_OCG)/cyc);")
    a("    else")
    a("      $display(\"%m FAIL -- %0d mismatches, %0d of %0d elements seen\", errs, seen, OC*OW);")
    a("    $finish;")
    a("  end")
    a("endmodule")
    io.open(out, "w", encoding="utf-8", newline="\n").write("\n".join(A) + "\n")
    return out, pack, n_seg, n_ocg


if __name__ == "__main__":
    man = load()
    arg = sys.argv[1:]
    if "--split" in arg:
        globals()["SPLIT"] = int(arg[arg.index("--split") + 1])
    if "--asplit" in arg:
        globals()["ASPLIT"] = int(arg[arg.index("--asplit") + 1])
    if arg and arg[0] == "--sweep":
        want, made = {}, 0
        for i, bb in enumerate(man["blocks"]):
            for st in ("e", "p"):
                p = (bb["pack_e"] if st == "e" else bb["pack_p"])["pack"]
                key = (p, (bb["stem"] and st == "e"),
                       ((bb["pack_e"] if st == "e" else bb["pack_p"])["n_eff"] + 127) // 128 > 1)
                if key in want:
                    continue
                r = emit(man, i, st, 0, "tb_fuse_ar_b%02d%s.v" % (i, st))
                if r is None:
                    continue
                want[key] = True
                made += 1
                print("wrote %-24s block %2d %s  pack %d  n_seg %d  n_ocg %d"
                      % (r[0], i, st, r[1], r[2], r[3]))
        print("\n%d cases" % made)
    else:
        bi, st = int(arg[0]), arg[1]
        row = int(arg[arg.index("--row") + 1]) if "--row" in arg else 0
        o = arg[arg.index("-o") + 1] if "-o" in arg else "tb_fuse_ar_b%02d%s.v" % (bi, st)
        r = emit(man, bi, st, row, o)
        print("wrote %s" % (r[0] if r else "(skipped)"))
