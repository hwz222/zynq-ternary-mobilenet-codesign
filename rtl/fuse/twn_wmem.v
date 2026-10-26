// ============================================================================
//  twn_wmem.v -- on-chip weight and constant memories (four block-RAM arrays).
//
//    mem_tern  ternary weights        256 bit/word   read by the ternary array
//    mem_dw    depthwise taps         576 bit/word   DW_LANES x 9 taps x 8 bit
//    mem_rq    array requant groups   RQ_W bit/word  OCMAX entries of 64 bit
//    mem_rqd   depthwise requant      448 bit/word   8 entries of 56 bit
//
//  Each memory has one write port (driven by twn_wfetch) and one registered
//  read port: the data appears one cycle after the address. Where a block's
//  words sit is decided by the base addresses in the block descriptor; this
//  module has no bank select, so the caller must keep the block being read and
//  the block being fetched at non-overlapping addresses.
//
//  Requant entry, array (64 bit per output channel; a word holds OCMAX of them,
//  channel k at bits [64k +: 64]):
//      [17:0] M0 (signed)   [57:18] BIAS (signed)   [63:58] SH (shift)
//  Requant entry, depthwise (56 bit per channel, channel k at bits [56k +: 56]):
//      [17:0] M0            [49:18] BIAS (32 bit)   [55:50] SH
//  (field split as unpacked in twn_fuse_top.)
//
//  The two requant memories are separate because the ternary array and the
//  depthwise engine requantise in the same cycles and each needs its own
//  read port.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_wmem #(
    // Depths are in words of each memory's own width.
    parameter integer TERN_WORDS = 8160,   // 256 bit
    parameter integer DW_WORDS   = 240,    //  576 bit
    // RQ_W = OCMAX * 64: one 64-bit requant entry per output channel in a group.
    // RQA_WORDS counts groups (not channels).
    parameter integer RQ_W       = 256,
    parameter integer RQA_WORDS  = 600,    //  RQ_W bit
    parameter integer RQD_WORDS  = 240     //  448 bit = 8 x 56
)(
    input  wire clk,

    // ---- write side: from twn_wfetch, one port per memory ----
    input  wire         wr_tern_en,
    input  wire [13:0]  wr_tern_addr,
    input  wire [255:0] wr_tern_data,

    input  wire         wr_dw_en,
    input  wire [9:0]   wr_dw_addr,
    input  wire [575:0] wr_dw_data,

    input  wire         wr_rqa_en,
    input  wire [12:0]  wr_rqa_addr,
    input  wire [RQ_W-1:0] wr_rqa_data,

    input  wire         wr_rqd_en,
    input  wire [12:0]  wr_rqd_addr,
    input  wire [447:0] wr_rqd_data,

    // ---- read side: one port per consumer, registered ----
    input  wire [13:0]  rd_tern_addr,      // from twn_fuse_array's w_addr
    output reg  [255:0] rd_tern_data,

    input  wire [9:0]   rd_dw_addr,
    output reg  [575:0] rd_dw_data,

    // one group of OCMAX entries, 64 bit each
    input  wire [12:0]  rd_rq_addr,        // from twn_fuse_array's rq_addr
    output reg  [RQ_W-1:0] rd_rq_data,

    // one group of DW_LANES = 8 entries, 56 bit each (bias is 32 bit here, 40 bit
    // in the array's entry)
    input  wire [12:0]  rd_rqd_addr,
    output reg  [447:0] rd_rqd_data
);
    // ---- ternary weights ----
    // cascade_height limits how deep a chain of block RAMs the mapper may build
    // for this array, which keeps the read path short. The value was chosen for
    // a particular TERN_WORDS; re-evaluate it if the depth changes.
    (* cascade_height = 2 *) reg [255:0] mem_tern [0:TERN_WORDS-1];
    always @(posedge clk) begin
        if (wr_tern_en) mem_tern[wr_tern_addr] <= wr_tern_data;
        rd_tern_data <= mem_tern[rd_tern_addr];
    end

    // ---- depthwise taps ----
    reg [575:0] mem_dw [0:DW_WORDS-1];
    always @(posedge clk) begin
        if (wr_dw_en) mem_dw[wr_dw_addr] <= wr_dw_data;
        rd_dw_data <= mem_dw[rd_dw_addr];
    end

    // ---- requant tables: the array reads mem_rq, the depthwise engine mem_rqd ----
    reg [RQ_W-1:0] mem_rq  [0:RQA_WORDS-1];
    reg [447:0] mem_rqd [0:RQD_WORDS-1];
    always @(posedge clk) begin
        if (wr_rqa_en) mem_rq [wr_rqa_addr] <= wr_rqa_data;
        if (wr_rqd_en) mem_rqd[wr_rqd_addr] <= wr_rqd_data;
        rd_rq_data  <= mem_rq [rd_rq_addr];
        rd_rqd_data <= mem_rqd[rd_rqd_addr];
    end

endmodule
`default_nettype wire
