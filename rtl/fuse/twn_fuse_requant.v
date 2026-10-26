// ============================================================================
//  twn_fuse_requant.v -- one requantisation lane.
//
//      t = acc * m0 + bias
//      r = (t + (1 << (sh-1))) >>> sh            (round-half-up, arithmetic)
//      if relu:  r = max(r, 0)
//      r = clamp(r, lo, hi)                      lo = 0 (otype 0) or -127 (otype 1), hi = 127
//
//  Interface: all inputs are sampled together; `out` is valid 3 + SPLIT cycles
//  later (ce is a clock enable for every register). Widths: acc 20 bits (large
//  enough for the ternary and depthwise accumulators), m0 18 bits (DSP48E2 B
//  port), bias 40 bits, sh 6 bits.
//
//  Implementation notes:
//   - The multiply and the bias add are separate register stages so they map
//     onto the DSP's multiplier register and P adder.
//   - Rounding uses (t + 2^(s-1)) >>> s == (t >>> s) + t[s-1] (t[-1] taken as 0
//     for s = 0), so there is a variable bit select and a small increment
//     instead of a wide adder and decoder.
//   - Round and clamp work on a window of the low 11 bits of t >>> sh plus a
//     saturation flag. The flag is set when the bits above the window disagree
//     with the sign, i.e. the shifted value does not fit in 11 signed bits.
//   - SPLIT = 1 adds a register between the shift/round and the relu/clamp.
//
//  otype: 0 = unsigned output range 0..127, 1 = signed range -127..127.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module twn_fuse_requant #(
    parameter integer SPLIT = 1        // 0: shift+round+clamp in one stage (latency 3)
                                       // 1: shift+round and relu+clamp in separate stages (latency 4)
)(
    input  wire                clk,
    input  wire                ce,
    input  wire signed [19:0]  acc,
    input  wire signed [17:0]  m0,
    input  wire signed [39:0]  bias,
    input  wire [5:0]          sh,
    input  wire                relu,
    input  wire [1:0]          otype,     // 0 = 0..127, 1 = -127..127
    output reg  signed [7:0]   out        // valid 3 + SPLIT cycles later
);
    // ---- stage 1: the multiply ----------------------------------------------
    // Operands are widened to the product width first; otherwise Verilog sizes
    // the multiply to the wider operand and truncates the product.
    wire signed [37:0] acc_w = {{18{acc[19]}}, acc};
    wire signed [37:0] m0_w  = {{20{m0[17]}},  m0};

    (* use_dsp = "yes" *) reg signed [37:0] m_r;
    reg signed [39:0] bias_1;
    reg [5:0]         sh_1, sh_2;
    reg               relu_1, relu_2;
    reg [1:0]         ot_1, ot_2;
    always @(posedge clk) if (ce) begin
        m_r    <= acc_w * m0_w;
        bias_1 <= bias;
        sh_1   <= sh;   relu_1 <= relu;  ot_1 <= otype;
    end

    // ---- stage 2: add bias ---------------------------------------------------
    reg signed [40:0] t_2;
    always @(posedge clk) if (ce) begin
        t_2  <= {{3{m_r[37]}}, m_r} + {bias_1[39], bias_1};
        sh_2 <= sh_1;  relu_2 <= relu_1;  ot_2 <= ot_1;
    end

    // ---- stage 3 (and optionally 4): shift, round, then relu and clamp -------
    wire signed [40:0] q_sh = t_2 >>> sh_2;

    // round bit: bit sh-1 of t (0 when sh == 0)
    wire [5:0] sm1  = sh_2 - 6'd1;
`ifdef RQ_NO_ROUND
    // ablation arm: truncate instead of rounding
    wire       rbit = 1'b0;
`else
    wire       rbit = (sh_2 == 6'd0) ? 1'b0 : t_2[sm1];
`endif

    // The rounded window value is carried in 12 bits: an 11-bit window value
    // of +1023 plus the round bit would wrap to -1024 in 11 bits.
`ifdef RQ_NEG_WINDOW11
    // negative-test arm: round inside the 11-bit window (wraps at 1023 + 1)
    wire signed [10:0] low11 = $signed(q_sh[10:0]) + {10'd0, rbit};
    wire signed [11:0] low_c = {low11[10], low11};
`else
    wire signed [11:0] low_c = $signed({q_sh[10], q_sh[10:0]}) + {11'd0, rbit};
`endif
    // saturated iff the bits above the 11-bit window are not all equal to the sign
    wire sat_c = ~((&q_sh[40:10]) | ~(|q_sh[40:10]));
    wire neg_c = q_sh[40];

    reg signed [11:0] low_3;
    reg               sat_3, neg_3, relu_3;
    reg [1:0]         ot_3;
    always @(posedge clk) if (ce) begin
        low_3 <= low_c; sat_3 <= sat_c; neg_3 <= neg_c;
        relu_3 <= relu_2; ot_3 <= ot_2;
    end

    wire signed [11:0] low  = SPLIT ? low_3  : low_c;
    wire               sat  = SPLIT ? sat_3  : sat_c;
    wire               neg  = SPLIT ? neg_3  : neg_c;
    wire               relu_x = SPLIT ? relu_3 : relu_2;
    wire [1:0]         ot_x   = SPLIT ? ot_3   : ot_2;

    wire signed [8:0]  lo = (ot_x == 2'd0) ? 9'sd0 : -9'sd127;
    wire signed [8:0]  hi = 9'sd127;
    // $signed is needed: a concatenation is unsigned, and the compare below
    // would otherwise treat negative bounds as large positive values.
    wire signed [11:0] lo_ext = $signed({{3{lo[8]}}, lo});
    wire signed [11:0] hi_ext = $signed({{3{hi[8]}}, hi});
    wire signed [11:0] rel    = (relu_x && (sat ? neg : (low < 0))) ? 12'sd0 : low;

    always @(posedge clk) if (ce) begin
        // a saturated negative value lands on lo (0 with relu/otype 0, else -127)
        if (sat)                     out <= neg ? lo[7:0] : hi[7:0];
        else if (rel < lo_ext)       out <= lo[7:0];
        else if (rel > hi_ext)       out <= hi[7:0];
        else                         out <= rel[7:0];
    end
endmodule
`default_nettype wire
