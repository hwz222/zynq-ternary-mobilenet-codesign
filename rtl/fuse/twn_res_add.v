// ============================================================================
//  twn_res_add.v -- residual add and requantisation, LANES values per cycle.
//
//  Per lane:
//      t   = p * mp + x * mq               (mp, mq: signed 18 bit)
//      r   = (t + (1 << (sh-1))) >>> sh    (sh = 0: no rounding term, no shift)
//      out = clamp(r, lo, hi), low 8 bits kept
//  p is the project stage's requantised output and x is the block's own input
//  (the residual source). Both ports are signed 16 bit per lane; twn_fuse_top
//  drives them with sign-extended int8 values.
//
//  Interface: streaming, no back-pressure. A group presented with in_valid
//  appears on out_valid/out_data exactly 4 cycles later, with in_tag delayed
//  by the same 4 cycles on out_tag. Only the valid and tag registers are
//  cleared by rst. mp, mq, sh, lo and hi are used directly by the pipeline
//  stages (not registered per group) and must stay constant while any group
//  is in flight.
//
//  Widths: p*mp and x*mq are 34 bit, their sum t is 35 bit, and t plus the
//  rounding term is computed in 37 bit so the carry cannot wrap.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_res_add #(
    parameter integer LANES = 4          // values processed per cycle
)(
    input  wire clk,
    input  wire rst,

    // ---- the block's residual constants, from the descriptor ----
    input  wire signed [17:0] mp,
    input  wire signed [17:0] mq,
    input  wire [5:0]         sh,
    input  wire signed [15:0] lo,
    input  wire signed [15:0] hi,

    // ---- the two operands, LANES at a time ----
    input  wire                    in_valid,
    input  wire [LANES*16-1:0]     p_in,      // project output, after its requantisation
    input  wire [LANES*16-1:0]     x_in,      // the block's own input row
    input  wire [7:0]              in_tag,

    output reg                     out_valid,
    output wire [LANES*8-1:0]      out_data,
    output reg  [7:0]              out_tag
);
    // Valid and tag shift registers, one stage per data register below. out_data
    // is the last data register read out directly; adding another register would
    // put the data one cycle behind out_valid.
    reg v0, v1, v2;
    reg [7:0] t0, t1, t2;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_lane
            wire signed [15:0] p = p_in[g*16 +: 16];
            wire signed [15:0] x = x_in[g*16 +: 16];

            // Operands are sign-extended to 34 bit first: a Verilog product takes
            // the width of its wider operand, not the sum of the widths.
            wire signed [33:0] pp = $signed({{18{p[15]}}, p}) * mp;
            wire signed [33:0] qq = $signed({{18{x[15]}}, x}) * mq;
            reg  signed [33:0] pp_r, qq_r;   // stage 1: products
            reg  signed [34:0] t_r;          // stage 2: sum

            wire signed [36:0] t_ext = $signed({{2{t_r[34]}}, t_r});
`ifdef RES_NEG_UPPER_LANES
            // Negative-test build only: the rounding term is dropped on lanes 4
            // and up, so a gate that exercises only 4 lanes cannot see it.
            wire signed [36:0] half   = (g >= 4) ? 37'sd0
                                      : ((sh == 6'd0) ? 37'sd0
                                                      : ($signed(37'sd1) <<< (sh - 6'd1)));
`else
            wire signed [36:0] half   = (sh == 6'd0) ? 37'sd0
                                                     : ($signed(37'sd1) <<< (sh - 6'd1));
`endif
            reg  signed [36:0] rr;           // stage 3: round and shift
            reg  signed [15:0] cl;           // stage 4: clamp

            always @(posedge clk) begin
                pp_r <= pp;
                qq_r <= qq;
                t_r  <= $signed({pp_r[33], pp_r}) + $signed({qq_r[33], qq_r});
                rr   <= (t_ext + half) >>> sh;
                cl   <= (rr < $signed({{21{lo[15]}}, lo})) ? lo
                      : (rr > $signed({{21{hi[15]}}, hi})) ? hi
                      : rr[15:0];
            end
            assign out_data[g*8 +: 8] = cl[7:0];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; out_valid <= 1'b0;
        end else begin
            v0 <= in_valid; v1 <= v0; v2 <= v1; out_valid <= v2;
            t0 <= in_tag;   t1 <= t0;  t2 <= t1;  out_tag <= t2;
        end
    end

endmodule
`default_nettype wire
