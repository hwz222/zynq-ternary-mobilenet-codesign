"""gen_hd_op.py -- generate a testbench for one head op through twn_hd_compute.

The testbench drives the engine's streams directly and compares the output beats
against the expected values from hd_ref.py (deconv_ref / final_ref).

Stream layouts (16 bytes per 128-bit beat, first byte in the low byte):
  input   NHWC bytes [iy][ix][ic]; IC a multiple of 16. In mode A the input is
          re-streamed once per (phase, ocg) slice.
  weights mode B (resident fill): linear bytes of w[ky][kx][ic][oc], oc fastest,
          OC a multiple of 8.
          mode A (slice stream): for phase (py,px) in (0,0),(0,1),(1,0),(1,1):
          for ocg: for ic: 4 taps t = {ty,tx}, 8 oc bytes each (2 beats per
          (ic, ocg)); tap t reads kernel position kpos(ty, py), kpos(tx, px).
          type 4: linear w[oc][ic] bytes (IC must be 32), output raw int32
          NHWC, 4 per beat.
  output  type 2: int8 NHWC row-major, 16 per beat; type 4: int32 NHWC, 4 per beat.
  requant per oc written through the m0/bias/sh write ports (m0 < 2^17,
          |bias| < 2^39).

usage:  python gen_hd_op.py IC OC H W MODE RELU [TBOUT] [SEED] [BIAS40]
  MODE: b = type 2 mode B, a = type 2 mode A, f = type 4 final
  TBOUT (default tb_hd_op.v) is written next to this script; BIAS40 = 1 draws biases
  over the full signed 40-bit range. Needs rtl/tb/hd_ref.py. `ifdef BFM_STALL=n in
  the generated testbench throttles the output ready.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hd_ref import deconv_ref, final_ref, phase_taps

TBOUT = sys.argv[7] if len(sys.argv) > 7 else "tb_hd_op.v"
MODNAME = os.path.splitext(os.path.basename(TBOUT))[0]
SEED = int(sys.argv[8]) if len(sys.argv) > 8 else 11
BIAS40 = int(sys.argv[9]) if len(sys.argv) > 9 else 0
random.seed(SEED)

IC = int(sys.argv[1]) if len(sys.argv) > 1 else 16
OC = int(sys.argv[2]) if len(sys.argv) > 2 else 8
H = int(sys.argv[3]) if len(sys.argv) > 3 else 4
W = int(sys.argv[4]) if len(sys.argv) > 4 else 4
MODE = sys.argv[5] if len(sys.argv) > 5 else "b"
RELU = int(sys.argv[6]) if len(sys.argv) > 6 else 1
assert IC % 16 == 0 and OC % 8 == 0 and MODE in "baf"
assert MODE != "f" or IC == 32, "type-4 rotating weight regs assume IC==32"
T4 = MODE == "f"

# strict-int8 domain activations; int8 weights
x = [[[random.randint(-127, 127) for _ in range(IC)] for _ in range(W)] for _ in range(H)]
BMAX = (1 << 39) - 1 if BIAS40 else 2000
m0 = [random.randint(1 << 16, (1 << 17) - 1) for _ in range(OC)]
bs = [random.randint(-BMAX, BMAX) for _ in range(OC)]
sh = [random.randint(18, 24) for _ in range(OC)]
LO, HI = (0 if RELU else -127), 127          # strict-int8 clamps

if T4:
    wf = [[random.randint(-128, 127) for _ in range(IC)] for _ in range(OC)]
    out = final_ref(x, wf, H, W, IC, OC)
    OH, OW = H, W
    wbytes = [wf[oc][ic] for oc in range(OC) for ic in range(IC)]
else:
    w = [[[[random.randint(-128, 127) for _ in range(4)] for _ in range(4)]
          for _ in range(OC)] for _ in range(IC)]
    out = deconv_ref(x, w, H, W, IC, OC, (m0, bs, sh), RELU, LO, HI)
    OH, OW = H * 2, W * 2
    if MODE == "b":
        wbytes = [w[ic][oc][ky][kx] for ky in range(4) for kx in range(4)
                  for ic in range(IC) for oc in range(OC)]
    else:
        # mode A slice order (matches the engine's S_ASLICE loader): slices are
        # (phase {py,px}, ocg) with ocg inner; within a slice, for ic: taps
        # t = {ty,tx} 0..3 as 8-byte oc groups. Tap t's kernel position is
        # kpos(hi, parity), with hi the tap's ty (or tx) bit and parity py (or px).
        def kpos(hi, parity):
            return (0 if parity else 1) if hi else (2 if parity else 3)
        wbytes = []
        for (py, px) in ((0, 0), (0, 1), (1, 0), (1, 1)):
            for g in range(OC // 8):
                for ic in range(IC):
                    for t in range(4):
                        ky = kpos(t >> 1, py)
                        kx = kpos(t & 1, px)
                        for l in range(8):
                            wbytes.append(w[ic][g * 8 + l][ky][kx])

xbytes = [x[iy][ix][ic] for iy in range(H) for ix in range(W) for ic in range(IC)]
if MODE == "a":
    # the engine re-streams the input once per (phase, ocg) slice
    xbytes = xbytes * (4 * (OC // 8))

def beats(byts):
    assert len(byts) % 16 == 0
    r = []
    for i in range(0, len(byts), 16):
        v = 0
        for j in range(16):
            v |= (byts[i + j] & 0xFF) << (8 * j)
        r.append(v)
    return r

xb, wb = beats(xbytes), beats(wbytes)

if T4:
    obeats = []
    flat = [out[oy][ox][oc] for oy in range(OH) for ox in range(OW) for oc in range(OC)]
    for i in range(0, len(flat), 4):
        v = 0
        for j in range(4):
            v |= (flat[i + j] & 0xFFFFFFFF) << (32 * j)
        obeats.append(v)
else:
    obeats = beats([out[oy][ox][oc] for oy in range(OH) for ox in range(OW)
                    for oc in range(OC)])

L = []
A = L.append
A("`timescale 1ns/1ps")
A("`default_nettype none")
A("// generated by gen_hd_op.py -- args: IC=%d OC=%d H=%d W=%d MODE=%s RELU=%d SEED=%d BIAS40=%d"
  % (IC, OC, H, W, MODE, RELU, SEED, BIAS40))
A("module %s;" % MODNAME)
A("  reg clk=0, rst, start; always #5 clk=~clk;")
A("  wire done; integer errors=0;")
A("  reg  in_sv; wire in_sr; reg [127:0] in_sd;")
A("  reg  w_sv;  wire w_sr;  reg [127:0] w_sd;")
A("  wire out_sv; reg out_sr; wire [127:0] out_sd;")
A("  reg m0_we, bias_we, sh_we; reg [9:0] rq_wa;")
A("  reg signed [31:0] m0_wd; reg signed [63:0] bias_wd; reg [5:0] sh_wd;")
A("  twn_hd_compute u(.clk(clk),.rst(rst),.start(start),.done(done),")
A("    .IC_i(9'd%d),.OC_i(6'd%d),.H_i(7'd%d),.W_i(7'd%d)," % (IC, OC, H, W))
A("    .mode_a(1'b%d),.type4(1'b%d),.relu_i(1'b%d)," % (MODE == "a", T4, RELU))
A("    .lo_i(%s16'sd%d),.hi_i(%s16'sd%d)," % ("-" if LO < 0 else "", abs(LO), "-" if HI < 0 else "", abs(HI)))
A("    .in_sv(in_sv),.in_sr(in_sr),.in_sd(in_sd),")
A("    .w_sv(w_sv),.w_sr(w_sr),.w_sd(w_sd),")
A("    .m0_we(m0_we),.rq_wa(rq_wa),.m0_wd(m0_wd),.bias_we(bias_we),.bias_wd(bias_wd),")
A("    .sh_we(sh_we),.sh_wd(sh_wd),")
A("    .out_sv(out_sv),.out_sr(out_sr),.out_sd(out_sd));")
A("  // stimulus ROMs")
A("  reg [127:0] xrom [0:%d];" % (len(xb) - 1))
A("  reg [127:0] wrom [0:%d];" % (len(wb) - 1))
A("  reg [127:0] orom [0:%d];" % (len(obeats) - 1))
A("  integer i;")
A("  initial begin")
for i, v in enumerate(xb):
    A("    xrom[%d]=128'h%032x;" % (i, v))
for i, v in enumerate(wb):
    A("    wrom[%d]=128'h%032x;" % (i, v))
for i, v in enumerate(obeats):
    A("    orom[%d]=128'h%032x;" % (i, v))
A("  end")
A("  // output capture")
A("  reg [127:0] cap [0:%d]; integer optr;" % (len(obeats) - 1))
A("`ifdef BFM_STALL")
A("  reg [7:0] lf=0; always @(posedge clk) lf <= lf + 8'd1;")
A("  always @(posedge clk) out_sr <= (lf[2:0] > 3'd`BFM_STALL);")
A("`else")
A("  initial out_sr = 1'b1;")
A("`endif")
A("  always @(posedge clk) if (!rst && out_sv && out_sr) begin")
A("    cap[optr] <= out_sd; optr <= optr + 1;")
A("  end")
A("  // feeders: hold each beat until accepted")
A("  integer xi, wi;")
A("  always @(posedge clk) begin")
A("    if (rst) begin xi<=0; wi<=0; in_sv<=0; w_sv<=0; end")
A("    else begin")
A("      if (in_sv && in_sr) xi <= xi + 1;")
A("      if (w_sv  && w_sr)  wi <= wi + 1;")
A("      in_sv <= (xi < %d) || (in_sv && !in_sr);" % len(xb))
A("      w_sv  <= (wi < %d) || (w_sv  && !w_sr);" % len(wb))
A("    end")
A("  end")
A("  always @(*) in_sd = xrom[(xi < %d) ? xi : 0];" % len(xb))
A("  always @(*) w_sd  = wrom[(wi < %d) ? wi : 0];" % len(wb))
A("  task wrq(input [9:0] a, input signed [31:0] mm, input signed [63:0] b, input [5:0] s);")
A("    begin @(negedge clk); m0_we=1; bias_we=1; sh_we=1; rq_wa=a; m0_wd=mm; bias_wd=b; sh_wd=s;")
A("    @(negedge clk); m0_we=0; bias_we=0; sh_we=0; end endtask")
A("  // watchdog: a deadlocked engine must FAIL loudly, not hang the suite")
A("  initial begin #50_000_000; $display(\"FAIL %s: TIMEOUT\"); $finish; end" % MODNAME)
A("  initial begin")
A("    rst=1; start=0; m0_we=0; bias_we=0; sh_we=0; optr=0;")
A("    repeat(4) @(negedge clk); rst=0; @(negedge clk);")
for i in range(OC):
    A("    wrq(%d, 32'sd%d, %s64'sd%d, 6'd%d);"
      % (i, m0[i], "-" if bs[i] < 0 else "", abs(bs[i]), sh[i]))
A("    @(negedge clk); start=1; @(negedge clk); start=0;")
A("    wait(done); repeat(4) @(negedge clk);")
A("    if (optr != %d) begin" % len(obeats))
A("      $display(\"FAIL %s: %%0d output beats, expected %d\" , optr);" % (MODNAME, len(obeats)))
A("      errors = errors + 1;")
A("    end")
A("    for (i=0; i<%d; i=i+1) if (cap[i] !== orom[i]) begin" % len(obeats))
A("      errors=errors+1;")
A("      if (errors<=20) $display(\"FAIL beat %0d got=%032x exp=%032x\", i, cap[i], orom[i]);")
A("    end")
A("    if (errors==0) $display(\"=== twn_hd_compute: ALL PASS (%d beats, mode %s) ===\");"
  % (len(obeats), MODE))
A("    else $display(\"=== twn_hd_compute: %0d FAIL ===\", errors);")
A("    $finish;")
A("  end")
A("endmodule")
A("`default_nettype wire")

open(os.path.join(os.path.dirname(os.path.abspath(__file__)), TBOUT), "w",
     encoding="utf-8", newline="\n").write("\n".join(L) + "\n")
print("wrote %s (IC=%d OC=%d H=%d W=%d mode=%s -> %d out beats)"
      % (TBOUT, IC, OC, H, W, MODE, len(obeats)))
