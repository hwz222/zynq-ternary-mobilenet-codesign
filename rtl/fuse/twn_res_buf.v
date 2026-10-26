// ============================================================================
//  twn_res_buf.v -- on-chip store for the residual source rows.
//
//  A block's residual source is its own input rows, which the activation read
//  master (twn_act_rd) already fetches. This module captures those beats as they
//  stream past (write side) and hands them back, one row later or more, when the
//  project stage emits the matching output row (read side). It is a circular
//  buffer of DEPTH rows; each row occupies ROW_WORDS words of ROW_BITS bits.
//
//  Both sides walk rows in order (row 0, 1, 2, ...), so each keeps its own slot
//  counter that wraps at DEPTH. DEPTH need not be a power of two.
//
//  Interface:
//    - blk_start rewinds both sides to row 0 of a new block.
//    - Write: wr_en with one word per cycle; wr_row_done closes the row.
//    - Read: rd_word selects the word within the row being emitted; rd_data is
//      registered, valid one cycle after rd_word. rd_row_done moves the read
//      side to the next row (counters update at the clock edge, so reads in the
//      cycle rd_row_done is high still use the old row).
//    - stale flags a read (rd_en) of a row that is not complete yet, or that
//      the writer has already overwritten because DEPTH was too small.
//
//  ROW_WORDS must cover the longest input row of any block that has a residual.
//  A longer row written here (blocks with no residual) is truncated: the word
//  counter saturates and the extra words overwrite the last word of the slot.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_res_buf #(
    parameter integer ROW_BITS  = 128,      // one AXI beat, one scatter word
    parameter integer ROW_WORDS = 96,       // words per row slot
    parameter integer DEPTH     = 10        // rows held
)(
    input  wire clk,
    input  wire rst,
    input  wire blk_start,                  // rewind: a new block's row 0

    // ---- write: the activation read master's beats, in row order ----
    input  wire                 wr_en,
    input  wire [ROW_BITS-1:0]  wr_data,
    input  wire                 wr_row_done,   // the row being written is complete

    // ---- read: word `rd_word` of the row the project is emitting ----
    input  wire                 rd_en,
    input  wire [15:0]          rd_word,
    input  wire                 rd_row_done,
    output wire [ROW_BITS-1:0]  rd_data,

    // ---- detector ----
    // A buffer that is too shallow does not fail visibly: it returns an older
    // row. This flag (registered, not sticky) marks such reads.
    output reg                  stale
);
    localparam integer WORDS = DEPTH * ROW_WORDS;
    localparam integer AW    = $clog2(WORDS);
    localparam integer SW    = $clog2(DEPTH);

    // ---- the two walks: absolute row number (age test) and slot (address) ----
    reg [8:0]    w_abs, r_abs;
    reg [SW-1:0] w_slot, r_slot;
    reg [15:0]   w_word;

    always @(posedge clk) begin
        if (rst || blk_start) begin
            w_abs <= 9'd0; w_slot <= {SW{1'b0}}; w_word <= 16'd0;
            r_abs <= 9'd0; r_slot <= {SW{1'b0}};
        end else begin
            // Saturate at the last word of the slot instead of running into
            // the next slot.
            if (wr_en && (w_word != ROW_WORDS[15:0] - 16'd1)) w_word <= w_word + 16'd1;
            if (wr_row_done) begin
                w_word <= 16'd0;
                w_abs  <= w_abs + 9'd1;
`ifdef RESBUF_NEG_NO_WRAP
                // Negative-test build only: the slot wraps on its own bit width
                // instead of at DEPTH, which differs whenever DEPTH is not a
                // power of two.
                w_slot <= w_slot + 1'b1;
`else
                w_slot <= (w_slot == DEPTH[SW-1:0] - 1'b1) ? {SW{1'b0}} : w_slot + 1'b1;
`endif
            end
            if (rd_row_done) begin
                r_abs  <= r_abs + 9'd1;
`ifdef RESBUF_NEG_NO_WRAP
                r_slot <= r_slot + 1'b1;
`else
                r_slot <= (r_slot == DEPTH[SW-1:0] - 1'b1) ? {SW{1'b0}} : r_slot + 1'b1;
`endif
            end
        end
    end

    // ---- memory ----
    // Addresses are truncated to AW bits. rd_word past the end of a row is not
    // range-checked; the instantiating module masks the operand for blocks that
    // have no residual.
    wire [AW-1:0] wa = w_slot * ROW_WORDS + w_word;
    wire [AW-1:0] ra = r_slot * ROW_WORDS + rd_word;

    reg [ROW_BITS-1:0] mem [0:WORDS-1];
    reg [ROW_BITS-1:0] q;
    always @(posedge clk) begin
        if (wr_en) mem[wa] <= wr_data;
        q <= mem[ra];
    end
    assign rd_data = q;

    // ---- stale detector ----
    // age = rows the writer has completed minus rows the reader has completed.
    // The row being read is valid only if the writer has finished it (age > 0)
    // and has not yet reused its slot (age < DEPTH). The subtraction is signed
    // and 11 bits wide so a reader ahead of the writer gives a negative age
    // rather than a large unsigned value.
    wire signed [10:0] age = $signed({2'b00, w_abs}) - $signed({2'b00, r_abs});
    always @(posedge clk) begin
        if (rst) stale <= 1'b0;
`ifdef RESBUF_NEG_NO_STALE
        // Negative-test build only: detector disabled.
        else     stale <= 1'b0;
`else
        else     stale <= rd_en && ((age <= 11'sd0) || (age >= DEPTH));
`endif
    end

endmodule
`default_nettype wire
