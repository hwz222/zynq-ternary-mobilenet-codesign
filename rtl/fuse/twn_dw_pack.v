// ============================================================================
//  twn_dw_pack.v -- converts a depthwise output beat into a write to the row
//  buffer that holds the depthwise output (RingC, instance RB_C in twn_fuse_top).
//
//  Input: DW_LANES channels of one pixel per cycle (in_data), with the pixel
//  column in_x and the lane group in_tag. RingC stores a row as [x][c], so the
//  destination byte offset within the row is
//
//      byte offset = x * c_mid + lane_group * DW_LANES
//
//  Output (registered, one cycle after the input): a write enable, a word index
//  within the row, and a one-hot enable of the DW_LANES-byte piece inside the
//  word. wr_data is the 8 bytes replicated into every piece; only the enabled
//  piece is written, so no barrel shifter is needed.
//
//  Requirement: c_mid must be a multiple of DW_LANES, so the offset is always
//  piece-aligned. The low bits of the offset below LSH are dropped.
//  LSH and WSH are log2(DW_LANES) and log2(ROW_BYTES) written as constants;
//  they are correct only for DW_LANES = 8 and ROW_BYTES = 128 (lane_i is 4 bits).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_dw_pack #(
    parameter integer DW_LANES = 8,      // channels emitted per cycle
    parameter integer ROW_BYTES = 128,   // the memory's word, in bytes
    parameter integer WORD_BITS = 16     // width of the word index
)(
    input  wire                     clk,
    input  wire                     rst,

    input  wire [9:0]               c_mid,      // the row's channel count
    input  wire                     in_valid,
    input  wire [7:0]               in_x,       // OUTPUT column
    input  wire [7:0]               in_tag,     // lane group
    input  wire [DW_LANES*8-1:0]    in_data,

    output reg                      wr_en,
    output reg  [WORD_BITS-1:0]     wr_word,    // word index within the row
    output reg  [ROW_BYTES/DW_LANES-1:0] wr_lane, // one-hot, DW_LANES-byte granularity
    output wire [ROW_BYTES*8-1:0]   wr_data     // in_data replicated into every piece
);
    localparam integer NLANE = ROW_BYTES / DW_LANES;    // pieces per word
    localparam integer LSH   = 3;                       // log2(DW_LANES)
    localparam integer WSH   = 7;                       // log2(ROW_BYTES)

    // ---- destination address ----
    // operands widened to the 18-bit result
    wire [17:0] x_w   = {10'd0, in_x};
    wire [17:0] c_w   = {8'd0,  c_mid};
    wire [17:0] g_w   = {10'd0, in_tag} << LSH;
    wire [17:0] b_off = x_w * c_w + g_w;

    wire [WORD_BITS-1:0] word_i = b_off[17:WSH];
    wire [3:0]           lane_i = b_off[WSH-1:LSH];

    always @(posedge clk) begin
        if (rst) begin
            wr_en <= 1'b0; wr_word <= {WORD_BITS{1'b0}}; wr_lane <= {NLANE{1'b0}};
        end else begin
            wr_en   <= in_valid;
            wr_word <= word_i;
            wr_lane <= in_valid ? ({{(NLANE-1){1'b0}}, 1'b1} << lane_i)
                                : {NLANE{1'b0}};
        end
    end

    // ---- data: registered once to line up with wr_en, then replicated ----
    reg [DW_LANES*8-1:0] in_data_q;
    always @(posedge clk) in_data_q <= in_data;

    genvar L;
    generate
        for (L = 0; L < NLANE; L = L + 1) begin : g_rep
            assign wr_data[L*DW_LANES*8 +: DW_LANES*8] = in_data_q;
        end
    endgenerate

endmodule
`default_nettype wire
