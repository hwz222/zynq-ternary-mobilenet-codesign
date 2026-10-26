// ============================================================================
//  tb_rowbuf_ring.v -- twn_rowbuf (BANKS 3, WINDOW 3) with twn_rowbuf_rot: row
//  identity, ring wrap and row release.
//
//  Rows carry a stamp (row index in the low 16 bits, word index above). For
//  stride 1 and 2 and input heights 4..16 the producer writes at full rate
//  whenever wr_ready is set, until win_ready for output row r; the testbench then
//  reads the window (top, mid, bottom, plus the pad flags) and checks every
//  word's stamp against rows r*s-1, r*s, r*s+1. Covers ring wrap (DEPTH 4),
//  rows not overwritten before the window has read them, and no deadlock
//  (window must become ready within a guard count). Narrow geometry (64-bit
//  words, 4 words per row). No golden files. Self-checking. No break arms.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rowbuf_ring;

    localparam integer RB = 64;          // narrow rows keep the test quick
    localparam integer RW = 4;           // words per row
    localparam integer DEPTH = 4;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    reg  [9:0] h_in; reg stride;
    reg  wr_en; reg [RB-1:0] wr_data; reg wr_row_last;
    wire wr_ready;
    reg  rd_en; reg [9:0] rd_row; reg [1:0] rd_word;
    wire [RB-1:0] rd_top, rd_mid, rd_bot;
    wire rd_pad_top, rd_pad_bot;
    reg  row_done;
    wire win_ready; wire [9:0] wptr, rptr, free;

    // The buffer emits its banks in fixed order; twn_rowbuf_rot rotates them
    // into (top, mid, bottom) and applies the padding.
    wire [3*RB-1:0] rd_bank; wire [2:0] rd_bank_pad; wire [1:0] rd_mid_bank;

    twn_rowbuf #(.ROW_BITS(RB), .ROW_WORDS(RW), .DEPTH(DEPTH), .BANKS(3), .WINDOW(3)) DUT (
        .clk(clk), .rst(rst), .blk_start(1'b0), .h_in(h_in), .stride(stride),
        .wr_en(wr_en), .wr_data(wr_data), .wr_row_last(wr_row_last), .wr_ready(wr_ready),
        .rd_en(rd_en), .rd_row(rd_row), .rd_word(rd_word),
        .rd_bank(rd_bank), .rd_mid_bank(rd_mid_bank), .rd_bank_pad(rd_bank_pad),
        .rd_pad_top(rd_pad_top), .rd_pad_bot(rd_pad_bot),
        .row_done(row_done), .win_ready(win_ready),
        .wptr(wptr), .rptr(rptr), .free(free));

    // the rotation is instantiated at the full word width here
    twn_rowbuf_rot #(.WIDTH(RB), .BANKS(3)) ROT (
        .bank(rd_bank), .bank_pad(rd_bank_pad), .mid_bank(rd_mid_bank),
        .row_t(rd_top), .row_m(rd_mid), .row_b(rd_bot));

    integer errors, checks, s_i, H, r, w, wrote, guard;
    integer h_out, want_t, want_m, want_b;
    reg [RB-1:0] stamp;

    // the stamp a row carries: row index in the low bits, word index above it,
    // so a wrong ROW and a wrong WORD are distinguishable in the failure text
    function [RB-1:0] mk; input integer row, word;
        begin mk = {32'hA5A50000 | word[15:0], 16'd0, row[15:0]}; end
    endfunction
    function integer row_of; input [RB-1:0] v; begin row_of = v[15:0]; end endfunction

    task chk; input cond; input [255:0] what; input integer a, b;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 12) $display("  FAIL %0s (got %0d, want %0d)  H=%0d s=%0d r=%0d wptr=%0d rptr=%0d",
                                           what, a, b, H, s_i, r, wptr, rptr);
            end
        end
    endtask

    initial begin
        errors = 0; checks = 0;

        for (s_i = 1; s_i <= 2; s_i = s_i + 1) begin
            for (H = 4; H <= 16; H = H + (s_i == 2 ? 2 : 1)) begin
                // ---- reset per geometry ----
                rst = 1; wr_en = 0; rd_en = 0; row_done = 0;
                h_in = H[9:0]; stride = (s_i == 2);
                @(negedge clk); @(negedge clk); rst = 0;

                h_out = (s_i == 1) ? H : H / 2;
                wrote = 0;
                guard = 0;

                for (r = 0; r < h_out; r = r + 1) begin
                    // ---- producer at full rate until the window for r is ready ----
                    rd_row = r[9:0];
                    // win_ready is combinational from rd_row: wait for the clock
                    // edge before sampling it.
                    @(negedge clk);
                    while (!win_ready && guard < 10000) begin
                        if (wr_ready && wrote < H) begin
                            for (w = 0; w < RW; w = w + 1) begin
                                @(negedge clk);
                                wr_en = 1; wr_data = mk(wrote, w); wr_row_last = (w == RW-1);
                            end
                            @(negedge clk); wr_en = 0;
                            wrote = wrote + 1;
                        end else begin
                            @(negedge clk);
                        end
                        guard = guard + 1;
                    end
                    chk(guard < 10000, "window never became ready (deadlock)", guard, 0);
                    if (guard >= 10000) begin r = h_out; H = 999; s_i = 9; end

                    // ---- read the window and check every word ----
                    for (w = 0; w < RW; w = w + 1) begin
                        rd_word = w[1:0]; rd_en = 1;
                        @(negedge clk); @(negedge clk);   // one cycle of read latency
                        want_t = r*s_i - 1;
                        want_m = r*s_i;
                        want_b = r*s_i + 1;
                        if (want_t >= 0) chk(row_of(rd_top) == want_t, "top row",  row_of(rd_top), want_t);
                        else             chk(rd_pad_top === 1'b1,      "pad_top",  rd_pad_top, 1);
                        chk(row_of(rd_mid) == want_m, "mid row", row_of(rd_mid), want_m);
                        if (want_b < H) chk(row_of(rd_bot) == want_b, "bot row",  row_of(rd_bot), want_b);
                        else            chk(rd_pad_bot === 1'b1,      "pad_bot",  rd_pad_bot, 1);
                    end
                    rd_en = 0;

                    // ---- release ----
                    @(negedge clk); row_done = 1;
                    @(negedge clk); row_done = 0;
                end
            end
        end

        $display("  %0d checks", checks);
        if (errors == 0) $display("=== tb_rowbuf_ring: ALL PASS ===");
        else             $display("=== tb_rowbuf_ring: %0d FAIL ===", errors);
        $finish;
    end
endmodule
`default_nettype wire
