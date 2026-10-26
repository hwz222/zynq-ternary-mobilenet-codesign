// ============================================================================
//  twn_dwseq.v -- sequencer for twn_dw_array: walks one output row of the
//  depthwise stage and produces the array inputs and the memory addresses.
//
//  Walk order: lane group (DW_LANES channels) outer, column inner. For each
//  lane group, x = 0 .. w_in-1 is presented with in_valid high, followed by one
//  cycle with in_valid low (the array's window for the last column completes one
//  cycle after it is presented). twn_dw_array holds a lane group's weights for
//  the whole group, which is why the group is the outer loop.
//
//  Protocol: d_req is a level held for the whole row. The walk starts when
//  d_req is seen while idle, and does not restart until d_req has fallen
//  (`spent`); d_req falls only after the array's output has finished, which is
//  later than the last input.
//
//  The walk runs one cycle ahead of the array inputs: x_a / g_a are the
//  address-stage column and lane group, and in_x / in_tag are those registered.
//  The row buffer read (RB_T1, one cycle) is requested with x_a, so its data
//  arrives together with the matching in_x.
//
//  Names: RB_T1 is the row buffer holding the expand stage's output rows; its
//  word is 16 bytes, the array takes DW_LANES = 8 bytes (half a word). twn_wmem
//  is the weight memory (registered reads).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_dwseq #(
    parameter integer DW_LANES = 8,
    parameter integer RD_LEAD  = 1        // not used in the body
)(
    input  wire clk,
    input  wire rst,

    // ---- the block, from twn_desctab ----
    input  wire [9:0]  c_mid,             // depthwise channels
    input  wire [8:0]  w_in,              // columns per row
    input  wire [9:0]  mb_dw,             // this block's depthwise weight base
    input  wire [12:0] mb_rqd,            // and its depthwise requant base

    // ---- the sequencer's grant: high for the whole of one output row ----
    input  wire        d_req,

    // ---- to twn_wmem ----
    output wire [9:0]  taps_addr,         // tap word of lane group g_a
    output wire [12:0] rqd_addr,          // requant constants, lagged (see below)

    // ---- to RB_T1: the word holding (x, lane group), one cycle early ----
    output wire [15:0] rd_word,
    output wire        rd_half,           // which 8 bytes of the 16-byte word

    // ---- to twn_dw_array ----
    output reg         in_valid,
    output reg  [7:0]  in_x,
    output reg         in_first,
    output reg         in_last,
    output reg  [7:0]  in_tag             // lane group
);
    // ---- walk limits ----
    // last lane group index, and last column of a row
    wire [7:0] n_lg_m1 = (((c_mid + DW_LANES[9:0] - 10'd1) / DW_LANES[9:0])
                          - 10'd1);
    wire [8:0] x_last  = w_in - 9'd1;

    // ---- the walk ----
    reg [8:0] x_a;                        // address-stage column
    reg [7:0] g_a;                        // address-stage lane group
    reg       run;
    reg       spent;                      // walk finished; wait for d_req to fall

    wire      x_end = (x_a == {1'b0, x_last} + 9'd1);   // the extra cycle
    wire      g_end = (g_a == n_lg_m1);

    always @(posedge clk) begin
        if (rst) begin
            x_a <= 9'd0; g_a <= 8'd0; run <= 1'b0; spent <= 1'b0;
            in_valid <= 1'b0; in_x <= 8'd0;
            in_first <= 1'b0; in_last <= 1'b0; in_tag <= 8'd0;
        end else begin
`ifdef DWSEQ_NEG_NO_SPENT
            // negative test: no re-arm latch, so a held d_req restarts the walk
            spent <= 1'b0;
`else
            if (!d_req) spent <= 1'b0;
`endif
            // array inputs: the address stage, registered
            in_valid <= run && (x_a <= {1'b0, x_last});
            in_x     <= x_a[7:0];
            in_first <= run && (x_a == 9'd0);
            in_last  <= run && (x_a == {1'b0, x_last});
            in_tag   <= g_a;

            if (!run) begin
                if (d_req && !spent) begin
                    run <= 1'b1; x_a <= 9'd0; g_a <= 8'd0;
                end
            end else if (x_end) begin
                x_a <= 9'd0;
                if (g_end) begin
                    run <= 1'b0; spent <= 1'b1;
                end else begin
                    g_a <= g_a + 8'd1;
                end
            end else begin
                x_a <= x_a + 9'd1;
            end
        end
    end

    // ---- weight addresses ----
    // Taps are per lane group. The array reads w_taps one cycle after a column
    // is presented and twn_wmem's read is registered, so g_a addresses them in
    // time; g_a keeps the old group during the extra cycle, so the last column
    // of a group still sees its own taps.
    assign taps_addr = mb_dw  + {2'd0, g_a};

    // The requant constants (m0, bias, sh) are read by the array 4 cycles after
    // the column is presented, i.e. 3 cycles later than the taps. The column
    // presented in cycle P carries g_a from cycle P-1, and the registered
    // memory read adds one more cycle, so the address is g_a delayed by 4
    // (RQ_LAG). If the array's pipeline depth changes, RQ_LAG must change.
    localparam integer RQ_LAG = 4;
    reg [7:0] g_rq [0:RQ_LAG-1];
    integer gq;
    always @(posedge clk) begin
        if (rst)
            for (gq = 0; gq < RQ_LAG; gq = gq + 1) g_rq[gq] <= 8'd0;
        else begin
            g_rq[0] <= g_a;
            for (gq = 1; gq < RQ_LAG; gq = gq + 1) g_rq[gq] <= g_rq[gq-1];
        end
    end
`ifdef DWSEQ_NEG_RQ_NOLAG
    // negative test: requant address taken straight off the walk
    assign rqd_addr  = mb_rqd + {5'd0, g_a};
`else
    assign rqd_addr  = mb_rqd + {5'd0, g_rq[RQ_LAG-1]};
`endif

    // ---- row buffer read address ----
    // The expand's output row is stored [x][c], so the 8 bytes for (x, g) start
    // at byte x*c_mid + g*DW_LANES. RB_T1's word is 16 bytes: the word index is
    // that offset / 16 and the half is bit 3.
    //
    // boff_r holds that offset without a multiplier, as a running sum that has
    // the same value as the product expression in every cycle:
    //   request accepted      -> 0
    //   column step           -> += c_mid
    //   x_end (row of columns done) -> next group * DW_LANES (g_a if last group)
    reg [17:0] boff_r;
    always @(posedge clk) begin
        if (rst)              boff_r <= 18'd0;
        else if (!run) begin
            if (d_req && !spent) boff_r <= 18'd0;
`ifdef DWSEQ_NEG_BOFF_SHIFT16
        // negative test: group scaled by 16 instead of DW_LANES
        end else if (x_end)   boff_r <= ({10'd0, (g_end ? g_a : (g_a + 8'd1))} << 4);
`else
        // the shift is DW_LANES, not the 16-byte word size
        end else if (x_end)   boff_r <= ({10'd0, (g_end ? g_a : (g_a + 8'd1))}
                                         << $clog2(DW_LANES));
`endif
        else                  boff_r <= boff_r + {8'd0, c_mid};
    end

`ifdef FUSE_NEG_BOFF_MUL
    // reference arm: the multiply form of the same address
    wire [17:0] byte_off = ({9'd0, x_a} * {8'd0, c_mid})
                         + ({10'd0, g_a} << $clog2(DW_LANES));
    assign rd_word = byte_off[17:4];
    assign rd_half = byte_off[3];
`else
    assign rd_word = boff_r[17:4];
    assign rd_half = boff_r[3];
`endif

    // Simulation only: recompute the product form every cycle and count
    // mismatches against boff_r (cycles where c_mid is still X are skipped).
    // synthesis translate_off
    integer boff_bad;
    wire [17:0] boff_ref = ({9'd0, x_a} * {8'd0, c_mid})
                         + ({10'd0, g_a} << $clog2(DW_LANES));
    initial boff_bad = 0;
    always @(posedge clk) if (!rst && (^boff_ref !== 1'bx) && (^boff_r !== 1'bx)) begin
        if (boff_r !== boff_ref) begin
            boff_bad = boff_bad + 1;
            if (boff_bad <= 8)
                $display("twn_dwseq BOFF MISMATCH t=%0t acc=%0d mul=%0d x_a=%0d g_a=%0d c_mid=%0d",
                         $time, boff_r, boff_ref, x_a, g_a, c_mid);
        end
    end
    final $display("twn_dwseq BOFF EQUIVALENCE: %0d mismatch cycles (0 = the accumulator carried the product's value on every comparable cycle)", boff_bad);
    // synthesis translate_on

endmodule
`default_nettype wire
