// ============================================================================
//  tb_rowbuf_lanewr.v -- twn_rowbuf with LANE_WR=1 against LANE_WR=0.
//
//  Two instances differing only in LANE_WR. The reference row is written word by
//  word, left to right. The unit under test is written one 64-bit piece at a
//  time in the depthwise's order (lane group outer, pixel inner, so consecutive
//  writes are C_MID bytes apart), through wr_word_i / wr_lane / wr_row_done.
//  Both rows are then read back word by word and compared; the reference is also
//  compared with a model of the expected content. Geometry: C_MID 96, W_OUT 64,
//  ROW_BITS 1024, 48 words, 12 lane groups. No golden files.
//  Break arm (see sim/run_units.ps1): -DRBLW_TB_NEG_NO_LANEWR instantiates the
//  unit under test with LANE_WR=0, so it ignores wr_word_i / wr_lane; the word
//  compare must fail.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rowbuf_lanewr;

    localparam integer ROW_BITS  = 1024;
    localparam integer LANES     = 16;                 // 8 bytes each
    localparam integer PIECE     = ROW_BITS / LANES;   // 64 bits
    localparam integer C_MID     = 96;
    localparam integer W_OUT     = 64;
    localparam integer ROW_BYTES = C_MID * W_OUT;      // 6,144
    localparam integer ROW_WORDS = ROW_BYTES / 128;    // 48
    localparam integer N_LG      = C_MID / 8;          // 12
    localparam integer DEPTH     = 2;
    localparam integer WAW       = $clog2(ROW_WORDS);

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    // ---- the reference: word by word ----
    reg                a_we, a_last;
    reg [ROW_BITS-1:0] a_wd;
    reg [WAW-1:0]      a_rw;
    reg [9:0]          a_rr;
    wire [ROW_BITS-1:0] a_bank;

    twn_rowbuf #(.ROW_BITS(ROW_BITS), .ROW_WORDS(ROW_WORDS), .DEPTH(DEPTH),
                 .BANKS(1), .WINDOW(1), .LANE_WR(0), .LANES(LANES)) REF (
        .clk(clk), .rst(rst), .blk_start(1'b0),
        .xm_we(), .xm_wa(), .xm_wd(), .xm_lane(), .xm_ra(),
        .xm_rd({ROW_BITS{1'b0}}),
        .wr_word_i({WAW{1'b0}}), .wr_lane({LANES{1'b0}}), .wr_row_done(1'b0),
        .h_in(10'd8), .stride(1'b0),
        .wr_en(a_we), .wr_data(a_wd), .wr_row_last(a_last), .wr_ready(),
        .rd_en(1'b1), .rd_row(a_rr), .rd_word(a_rw),
        .rd_bank(a_bank), .rd_mid_bank(), .rd_bank_pad(),
        .rd_pad_top(), .rd_pad_bot(),
        .row_done(1'b0), .win_ready(), .wptr(), .rptr(), .free());

    // ---- the unit under test: one lane at a time, in the depthwise's order ----
    reg                b_we, b_done;
    reg [ROW_BITS-1:0] b_wd;
    reg [WAW-1:0]      b_wi, b_rw;
    reg [LANES-1:0]    b_lane;
    reg [9:0]          b_rr;
    wire [ROW_BITS-1:0] b_bank;

`ifdef RBLW_TB_NEG_NO_LANEWR
    localparam integer DUT_LANE_WR = 0;
`else
    localparam integer DUT_LANE_WR = 1;
`endif
    twn_rowbuf #(.ROW_BITS(ROW_BITS), .ROW_WORDS(ROW_WORDS), .DEPTH(DEPTH),
                 .BANKS(1), .WINDOW(1), .LANE_WR(DUT_LANE_WR), .LANES(LANES)) DUT (
        .clk(clk), .rst(rst), .blk_start(1'b0),
        .xm_we(), .xm_wa(), .xm_wd(), .xm_lane(), .xm_ra(),
        .xm_rd({ROW_BITS{1'b0}}),
        .wr_word_i(b_wi), .wr_lane(b_lane), .wr_row_done(b_done),
        .h_in(10'd8), .stride(1'b0),
        .wr_en(b_we), .wr_data(b_wd), .wr_row_last(1'b0), .wr_ready(),
        .rd_en(1'b1), .rd_row(b_rr), .rd_word(b_rw),
        .rd_bank(b_bank), .rd_mid_bank(), .rd_bank_pad(),
        .rd_pad_top(), .rd_pad_bot(),
        .row_done(1'b0), .win_ready(), .wptr(), .rptr(), .free());

    // the value at pixel x, channel group g -- 64 bits, distinguishable
    function [PIECE-1:0] val;
        input integer x;
        input integer g;
        begin
            val = {x[15:0], g[7:0], 8'hC3, x[7:0], g[7:0], 16'hBEEF};
        end
    endfunction

    integer errors = 0, checked = 0;
    integer x, g, w, l, off;
    reg [ROW_BITS-1:0] want_word;

    initial begin
        $display("=== tb_rowbuf_lanewr: C_mid %0d, w_out %0d, %0d words, %0d lane groups ===",
                 C_MID, W_OUT, ROW_WORDS, N_LG);
        a_we = 0; a_wd = 0; a_last = 0; a_rw = 0; a_rr = 0;
        b_we = 0; b_wd = 0; b_wi = 0; b_lane = 0; b_done = 0; b_rw = 0; b_rr = 0;
        repeat (3) @(negedge clk); rst = 0;

        // ---- reference: whole words, left to right ----
        for (w = 0; w < ROW_WORDS; w = w + 1) begin
            @(negedge clk);
            a_we = 1;
            for (l = 0; l < LANES; l = l + 1) begin
                // byte offset of this piece -> which (x, g) it holds
                off = (w * 128 + l * 8);
                a_wd[l*PIECE +: PIECE] = val(off / C_MID, (off % C_MID) / 8);
            end
            a_last = (w == ROW_WORDS-1);
        end
        @(negedge clk); a_we = 0; a_last = 0;

        // ---- unit under test: the depthwise's order, lane group OUTER ----
        for (g = 0; g < N_LG; g = g + 1)
            for (x = 0; x < W_OUT; x = x + 1) begin
                @(negedge clk);
                off    = x * C_MID + g * 8;
                b_we   = 1;
                b_wi   = off[WAW+6:7];                  // off / 128
                b_lane = {{(LANES-1){1'b0}}, 1'b1} << off[6:3];   // (off / 8) % 16
                // the producer replicates its 64 bits across every lane
                for (l = 0; l < LANES; l = l + 1)
                    b_wd[l*PIECE +: PIECE] = val(x, g);
            end
        @(negedge clk); b_we = 0;
        b_done = 1; @(negedge clk); b_done = 0;
        repeat (2) @(negedge clk);

        // ---- read both rows back, word for word ----
        for (w = 0; w < ROW_WORDS; w = w + 1) begin
            a_rr = 0; a_rw = w[WAW-1:0];
            b_rr = 0; b_rw = w[WAW-1:0];
            @(negedge clk); @(negedge clk);          // the read register
            checked = checked + 1;
            if (a_bank !== b_bank) begin
                errors = errors + 1;
                if (errors <= 6)
                    $display("  word %0d: ref %064h  dut %064h",
                             w, a_bank[255:0], b_bank[255:0]);
            end
            // and the reference itself must be what the model says, so a gate
            // that agrees on garbage is not possible
            for (l = 0; l < LANES; l = l + 1) begin
                off = (w * 128 + l * 8);
                want_word[l*PIECE +: PIECE] = val(off / C_MID, (off % C_MID) / 8);
            end
            if (a_bank !== want_word) begin
                errors = errors + 1;
                if (errors <= 6)
                    $display("  word %0d: the REFERENCE is wrong -- %064h want %064h",
                             w, a_bank[255:0], want_word[255:0]);
            end
        end

        $display("=== tb_rowbuf_lanewr: %0d words compared, %0d errors, %s ===",
                 checked, errors,
                 (errors == 0 && checked == ROW_WORDS) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
`default_nettype wire
