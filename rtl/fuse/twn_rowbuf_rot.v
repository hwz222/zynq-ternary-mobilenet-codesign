// ============================================================================
//  twn_rowbuf_rot.v -- turns twn_rowbuf's banks into the window rows
//  (top, middle, bottom) and zeroes the rows that are vertical padding.
//
//  Purely combinational. twn_rowbuf outputs its BANKS banks in fixed bank order
//  plus mid_bank (the bank holding the middle row). The three window rows are
//  consecutive, so the other two banks follow from mid_bank. This module picks
//  them and ANDs the top and bottom row with ~bank_pad of their bank.
//
//  WIDTH is the consumer's width, not the buffer's: twn_fuse_top instantiates
//  it at DW_LANES*8 bits, after narrowing each bank to the lane bytes needed.
//  Only BANKS = 3 is meaningful (mid_bank and the selects are 2 bits).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_rowbuf_rot #(
    parameter integer WIDTH = 64,     // bits per bank, after narrowing
    parameter integer BANKS = 3
)(
    input  wire [BANKS*WIDTH-1:0] bank,       // bank k in bits [k*WIDTH +: WIDTH]
    input  wire [BANKS-1:0]       bank_pad,   // per bank: that bank's row is padding
    input  wire [1:0]             mid_bank,   // bank holding the middle row

    output wire [WIDTH-1:0] row_t,    // row above the middle, zero if pad
    output wire [WIDTH-1:0] row_m,    // middle row (never a pad)
    output wire [WIDTH-1:0] row_b     // row below the middle, zero if pad
);
    // bank indices: top = mid-1, bot = mid+1, modulo BANKS
    wire [1:0] b_mid = mid_bank;
    wire [1:0] b_top = (b_mid == 2'd0) ? (BANKS[1:0] - 2'd1) : (b_mid - 2'd1);
    wire [1:0] b_bot = (b_mid == BANKS[1:0] - 2'd1) ? 2'd0 : (b_mid + 2'd1);

    function [WIDTH-1:0] pick;
        input [BANKS*WIDTH-1:0] b; input [1:0] sel;
        begin pick = b[sel*WIDTH +: WIDTH]; end
    endfunction

    assign row_t = pick(bank, b_top) & {WIDTH{~bank_pad[b_top]}};
    assign row_m = pick(bank, b_mid);
    assign row_b = pick(bank, b_bot) & {WIDTH{~bank_pad[b_bot]}};

endmodule
`default_nettype wire
