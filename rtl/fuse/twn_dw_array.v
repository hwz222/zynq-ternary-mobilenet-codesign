// ============================================================================
//  twn_dw_array.v -- depthwise 3x3 convolution on int8 activations, DW_LANES
//  channels in parallel, one output pixel per cycle (initiation interval 1).
//
//  Interface
//    - The caller presents one column of the window per cycle: three rows
//      (row_t, row_m, row_b), each DW_LANES bytes wide, for ONE lane group
//      (a group of DW_LANES consecutive channels). Row selection and lane-group
//      selection happen before this module, in the row-buffer read address.
//    - in_x is the pixel index of the column presented. The left tap column is
//      the previously presented column, the right tap column is the current
//      input. The window for column c is therefore complete one cycle AFTER c
//      is presented, so the caller sends columns 0..W-1 and then one more cycle.
//    - Horizontal padding is applied here (in_first zeroes the left column,
//      in_last zeroes the right column). Vertical padding is already applied
//      by twn_rowbuf_rot (it zeroes row_t / row_b on a pad row).
//    - in_tag is carried unchanged through the same registers as the data and
//      comes back on out_tag; the caller puts the lane group in it.
//    - Latency, default build: out_valid is high 8 cycles after the in_valid
//      cycle of the same column (window 1, products 1, partial sums 1, final
//      sum 1, twn_fuse_requant 4). With the stride port = 1 (stride 2), odd in_x beats are dropped.
//
//  Weight-hold contract: w_taps is read in the cycle after the column is
//  presented; m0, bias and sh are read in the 4th cycle after it (when the
//  accumulator feeds twn_fuse_requant). The caller must keep a lane group's
//  constants stable until then, or its last columns use the next group's.
//
//  Arithmetic: 9 products of int8 x int8 per lane, summed in ACCW = 21 bits,
//  then twn_fuse_requant: t = acc*m0 + bias, round-shift by sh, clamp.
//  The clamp is fixed at relu with bounds (0,127); clamp_lo/clamp_hi are only
//  checked against that in simulation.
//
//  Debug ablation defines (each removes one mechanism so a testbench can see
//  it fail): DW_NO_HPAD, DW_ALIGN2, DW_NARROW_ACC, DW_ACC10/12/14, DW_FLAT_ADD,
//  DW_RQ_INLINE, RQ_NO_ROUND.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

// use_dsp is set on the module because the attribute on the `prod` array alone
// is not applied element-wise to unpacked arrays.
(* use_dsp = "yes" *)
module twn_dw_array #(
    parameter integer DW_LANES = 8,
    parameter integer ROW_BITS = 1024      // not used in the body
)(
    input  wire clk,
    input  wire rst,

    // ---- per-op constants (n_ch and w_out are not used; the clamp is only checked) ----
    input  wire [9:0]  n_ch,
    input  wire [7:0]  w_out,
    input  wire        stride,             // 0 = 1, 1 = 2
    input  wire signed [15:0] clamp_lo,
    input  wire signed [15:0] clamp_hi,

    // ---- window column, from twn_rowbuf_rot (this lane group only) ----
    input  wire                 in_valid,
    input  wire [DW_LANES*8-1:0] row_t,    // top row, zero if pad
    input  wire [DW_LANES*8-1:0] row_m,    // middle row
    input  wire [DW_LANES*8-1:0] row_b,    // bottom row, zero if pad
    input  wire [7:0]           in_x,      // pixel index of this column
    input  wire                 in_first,  // x == 0        -> left column is pad
    input  wire                 in_last,   // x == W_in-1   -> right column is pad
    input  wire [7:0]           in_tag,    // opaque; returned on out_tag

    // ---- weights: 9 int8 taps for each of DW_LANES channels ----
    input  wire [DW_LANES*9*8-1:0] w_taps,
    // ---- requant constants, per lane ----
    input  wire [DW_LANES*18-1:0]  m0,
    input  wire [DW_LANES*32-1:0]  bias,
    input  wire [DW_LANES*6-1:0]   sh,

    // ---- result: DW_LANES int8 values of one output pixel ----
    output reg                     out_valid,
    output reg  [DW_LANES*8-1:0]   out_data,
    output reg  [7:0]              out_x,      // output column (in_x/2 when the stride port is 1)
    output reg  [7:0]              out_tag
);
// Accumulator width. 21 covers 9*127*127 = 145,161; the narrower values exist
// only for the DW_ACC* / DW_NARROW_ACC ablations.
`ifdef DW_ACC10
    localparam integer ACCW = 10;
`elsif DW_ACC12
    localparam integer ACCW = 12;
`elsif DW_ACC14
    localparam integer ACCW = 14;
`elsif DW_NARROW_ACC
    localparam integer ACCW = 16;
`else
    localparam integer ACCW = 21;
`endif

    // ---- S0: window columns ----
    // col_c is the previous input, col_l the one before it.
    reg [DW_LANES*8-1:0] col_l_t, col_l_m, col_l_b;
    reg [DW_LANES*8-1:0] col_c_t, col_c_m, col_c_b;
    reg [7:0] x_d; reg [7:0] tag_d;
`ifdef DW_ALIGN2
    reg [7:0] x_dd; reg v_dd, first_dd, last_dd;
`endif
    reg v_d, first_d, last_d;

    always @(posedge clk) begin
        if (rst) v_d <= 1'b0;
        else begin
            col_l_t <= col_c_t; col_l_m <= col_c_m; col_l_b <= col_c_b;
            col_c_t <= row_t;   col_c_m <= row_m;   col_c_b <= row_b;
            x_d <= in_x; first_d <= in_first; last_d <= in_last; v_d <= in_valid;
            tag_d <= in_tag;
`ifdef DW_ALIGN2
            x_dd <= x_d; v_dd <= v_d; first_dd <= first_d; last_dd <= last_d;
`endif
        end
    end

    // One cycle after column c is presented: col_c holds c, col_l holds c-1 and
    // the input port holds c+1. So the taps are (col_l, col_c, row_*) and the
    // pad masks are the one-cycle-delayed flags (first_d / last_d).
    // The right column is masked on the activation, not on the weight.
`ifdef DW_NO_HPAD
    wire [DW_LANES*8-1:0] tap_l_t = col_l_t, tap_l_m = col_l_m, tap_l_b = col_l_b;
    wire [DW_LANES*8-1:0] tap_r_t = row_t,   tap_r_m = row_m,   tap_r_b = row_b;
`else
`ifdef DW_ALIGN2
    wire first_m = first_dd, last_m = last_dd;
`else
    wire first_m = first_d,  last_m = last_d;
`endif
    wire [DW_LANES*8-1:0] tap_l_t = first_m ? {(DW_LANES*8){1'b0}} : col_l_t;
    wire [DW_LANES*8-1:0] tap_l_m = first_m ? {(DW_LANES*8){1'b0}} : col_l_m;
    wire [DW_LANES*8-1:0] tap_l_b = first_m ? {(DW_LANES*8){1'b0}} : col_l_b;
    wire [DW_LANES*8-1:0] tap_r_t = last_m  ? {(DW_LANES*8){1'b0}} : row_t;
    wire [DW_LANES*8-1:0] tap_r_m = last_m  ? {(DW_LANES*8){1'b0}} : row_m;
    wire [DW_LANES*8-1:0] tap_r_b = last_m  ? {(DW_LANES*8){1'b0}} : row_b;
`endif

    // ---- S1a: nine products per lane, registered ----
    // Activations are int8 in [-127,127] (low byte is the value). win[k] is tap
    // k = (row k/3, column k%3), columns (c-1, c, c+1).
    wire [DW_LANES*8-1:0] win [0:8];
    assign win[0] = tap_l_t;  assign win[1] = col_c_t;  assign win[2] = tap_r_t;
    assign win[3] = tap_l_m;  assign win[4] = col_c_m;  assign win[5] = tap_r_m;
    assign win[6] = tap_l_b;  assign win[7] = col_c_b;  assign win[8] = tap_r_b;

    // The register lets each multiply map onto a DSP's internal product register.
    (* use_dsp = "yes" *)
    reg signed [17:0] prod [0:DW_LANES*9-1];
    reg [7:0] x_s1a; reg [7:0] tag_s1a; reg v_s1a;

    integer L, K;
    reg signed [7:0] a_b, w_b;
    always @(posedge clk) begin
        if (rst) v_s1a <= 1'b0;
        else begin
            for (L = 0; L < DW_LANES; L = L + 1)
                for (K = 0; K < 9; K = K + 1) begin
                    a_b = win[K][L*8 +: 8];
                    w_b = w_taps[(L*9 + K)*8 +: 8];
                    // Operands are widened first: a product is only as wide as
                    // its wider operand in a self-determined context.
                    prod[L*9 + K] <= $signed({{10{a_b[7]}}, a_b})
                                   * $signed({{10{w_b[7]}}, w_b});
                end
            // Stride 2 keeps only even input columns.
            v_s1a   <= v_d & (stride ? ~x_d[0] : 1'b1);
            x_s1a   <= stride ? {1'b0, x_d[7:1]} : x_d;
            tag_s1a <= tag_d;
        end
    end

    // ---- S1b / S1c: sum the nine products per lane ----
    // Default: three partial sums of three products (S1b), then added (S1c).
    // DW_FLAT_ADD sums all nine in one stage into acc.
    reg  signed [ACCW-1:0] acc [0:DW_LANES-1];
    reg  [7:0] x_s1; reg [7:0] tag_s1; reg v_s1;

    integer L2a, K3;
    reg signed [ACCW-1:0] sum;
    reg signed [20:0]     pe;      // one product, sign-extended to a fixed 21 bits
`ifndef DW_FLAT_ADD
    reg signed [ACCW-1:0] part [0:DW_LANES*3-1];
    reg [7:0] x_s1b; reg [7:0] tag_s1b; reg v_s1b;
`endif
    always @(posedge clk) begin
        if (rst) v_s1 <= 1'b0;
        else begin
            for (L2a = 0; L2a < DW_LANES; L2a = L2a + 1) begin
`ifndef DW_FLAT_ADD
                for (K3 = 0; K3 < 3; K3 = K3 + 1) begin
                    sum = {ACCW{1'b0}};
                    for (K = 0; K < 3; K = K + 1) begin
                        // Fixed 21-bit extension, narrowed by the assignment to
                        // sum. The extension must not depend on ACCW (ACCW < 18
                        // would give a negative replication count).
                        pe = $signed({{3{prod[L2a*9 + K3*3 + K][17]}},
                                      prod[L2a*9 + K3*3 + K]});
                        sum = sum + pe;
                    end
                    part[L2a*3 + K3] <= sum;
                end
`else
                sum = {ACCW{1'b0}};
                for (K = 0; K < 9; K = K + 1) begin
                    pe = $signed({{3{prod[L2a*9 + K][17]}}, prod[L2a*9 + K]});
                    sum = sum + pe;
                end
                acc[L2a] <= sum;
`endif
            end
            v_s1 <= v_s1a; x_s1 <= x_s1a; tag_s1 <= tag_s1a;
        end
    end

`ifndef DW_FLAT_ADD
    // S1c: add the three partial sums.
    integer L2b;
    always @(posedge clk) begin
        if (rst) v_s1b <= 1'b0;
        else begin
            for (L2b = 0; L2b < DW_LANES; L2b = L2b + 1)
                acc[L2b] <= part[L2b*3] + part[L2b*3 + 1] + part[L2b*3 + 2];
            v_s1b <= v_s1; x_s1b <= x_s1; tag_s1b <= tag_s1;
        end
    end
`endif

    // ---- requant (twn_fuse_requant), tag delay and output ----
    // twn_fuse_requant takes relu / otype rather than clamp bounds; relu with
    // otype 0 is the (0,127) clamp, so clamp_lo / clamp_hi are checked in
    // simulation instead of being applied.
`ifndef DW_RQ_INLINE
    // RQ_SPLIT is passed to twn_fuse_requant, whose latency is 3 + SPLIT.
    // The tag delay below is derived from the same constant.
    localparam integer RQ_SPLIT = 1;
    localparam integer RQ_LAT   = 3 + RQ_SPLIT;

`ifndef DW_FLAT_ADD
    wire        rq_v0   = v_s1b;
    wire [7:0]  rq_x0   = x_s1b;
    wire [7:0]  rq_tag0 = tag_s1b;
`else
    wire        rq_v0   = v_s1;
    wire [7:0]  rq_x0   = x_s1;
    wire [7:0]  rq_tag0 = tag_s1;
`endif

    // twn_fuse_requant carries no valid/x/tag, so they are delayed here by
    // RQ_LAT-1 stages; the output register below is the last one. acc and rq_v0
    // change on the same edge, and the requant output appears RQ_LAT edges later.
    localparam integer TAGD = RQ_LAT - 1;
    reg        rq_v   [0:TAGD-1];
    reg [7:0]  rq_x   [0:TAGD-1];
    reg [7:0]  rq_tag [0:TAGD-1];
    integer RD;
    always @(posedge clk) begin
        if (rst) begin
            for (RD = 0; RD < TAGD; RD = RD + 1) rq_v[RD] <= 1'b0;
        end else begin
            rq_v[0] <= rq_v0;  rq_x[0] <= rq_x0;  rq_tag[0] <= rq_tag0;
            for (RD = 1; RD < TAGD; RD = RD + 1) begin
                rq_v[RD]   <= rq_v[RD-1];
                rq_x[RD]   <= rq_x[RD-1];
                rq_tag[RD] <= rq_tag[RD-1];
            end
        end
    end

    // acc_fits is gathered into a vector so the simulation check below can index
    // it with an integer (a hierarchical reference into a generate array needs
    // a constant index).
    wire [DW_LANES-1:0] acc_fits;
    genvar g;
    generate
        for (g = 0; g < DW_LANES; g = g + 1) begin : g_rq
            // The requant's acc port is 20 bits. Assigning between two signed
            // vectors sign-extends or truncates as ACCW requires (a part-select
            // would be out of range for ACCW < 20).
            wire signed [19:0] acc20 = acc[g];
            // 1 when the 20-bit copy equals the accumulator. Cannot be 0 with the
            // default widths; it guards against a future change that truncates.
            assign acc_fits[g] = ($signed(acc[g]) == $signed(acc20));
            twn_fuse_requant #(.SPLIT(RQ_SPLIT)) RQ (
                .clk(clk), .ce(1'b1),
                .acc(acc20),
                .m0($signed(m0[g*18 +: 18])),
                .bias($signed({{8{bias[g*32+31]}}, bias[g*32 +: 32]})),
                .sh(sh[g*6 +: 6]),
                .relu(1'b1), .otype(2'd0),
                .out(out_data[g*8 +: 8]));
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) out_valid <= 1'b0;
        else begin
            out_valid <= rq_v[TAGD-1];
            out_x     <= rq_x[TAGD-1];
            out_tag   <= rq_tag[TAGD-1];
        end
    end

`ifndef SYNTHESIS
    // Simulation checks: the clamp inputs must be (0,127), and the accumulator
    // must fit the requant's 20-bit port.
    integer AS;
    always @(posedge clk) if (!rst) begin
        // Skip while the clamp inputs are still X (before the caller drives them).
        if ((^clamp_lo === 1'bx) || (^clamp_hi === 1'bx)) ;
        else if (clamp_lo !== 16'sd0 || clamp_hi !== 16'sd127) begin
            $display("*** twn_dw_array: clamp (%0d,%0d) is not the (0,127) that otype 0 applies ***",
                     clamp_lo, clamp_hi);
            $fatal(1);
        end
        for (AS = 0; AS < DW_LANES; AS = AS + 1)
            if (acc_fits[AS] === 1'b0) begin
                $display("*** twn_dw_array: lane %0d accumulator %0d does not fit the requant's 20-bit port ***",
                         AS, acc[AS]);
                $fatal(1);
            end
    end
`endif

`else
    // ---- DW_RQ_INLINE ablation: requant written out here instead of using
    // ---- twn_fuse_requant ----
    reg signed [47:0] t_s2 [0:DW_LANES-1];
    reg [5:0] sh_s2 [0:DW_LANES-1];
    reg [7:0] x_s2; reg [7:0] tag_s2; reg v_s2;

    integer M;
    always @(posedge clk) begin
        if (rst) v_s2 <= 1'b0;
        else begin
            for (M = 0; M < DW_LANES; M = M + 1) begin
                t_s2[M] <= $signed(acc[M]) * $signed(m0[M*18 +: 18])
                         + $signed({{16{bias[M*32+31]}}, bias[M*32 +: 32]});
                sh_s2[M] <= sh[M*6 +: 6];
            end
`ifndef DW_FLAT_ADD
            v_s2 <= v_s1b; x_s2 <= x_s1b; tag_s2 <= tag_s1b;
`else
            v_s2 <= v_s1; x_s2 <= x_s1; tag_s2 <= tag_s1;
`endif
        end
    end

    // (t + 2^(sh-1)) >>> sh  ==  (t >>> sh) + t[sh-1]
    function signed [47:0] rq; input signed [47:0] t; input [5:0] s6;
        reg signed [47:0] q;
        begin
            q = t >>> s6;
`ifdef RQ_NO_ROUND
            rq = q;                              // ablation: truncate, do not round
`else
            rq = (s6 == 6'd0) ? t : (q + $signed({47'd0, t[s6-1]}));
`endif
        end
    endfunction

    integer N;
    always @(posedge clk) begin
        if (rst) out_valid <= 1'b0;
        else begin
            for (N = 0; N < DW_LANES; N = N + 1) begin : RQ
                reg signed [47:0] y;
                y = rq(t_s2[N], sh_s2[N]);
                // Clamp bounds are sign-extended explicitly: a concatenation is
                // unsigned, which would break the signed compare.
                if (y < $signed({{32{clamp_lo[15]}}, clamp_lo}))
                    out_data[N*8 +: 8] <= clamp_lo[7:0];
                else if (y > $signed({{32{clamp_hi[15]}}, clamp_hi}))
                    out_data[N*8 +: 8] <= clamp_hi[7:0];
                else
                    out_data[N*8 +: 8] <= y[7:0];
            end
            out_valid <= v_s2;
            out_x     <= x_s2;
            out_tag <= tag_s2;
        end
    end
`endif

    wire _unused_ok = &{1'b0, n_ch, w_out, 1'b0};

endmodule
`default_nettype wire
