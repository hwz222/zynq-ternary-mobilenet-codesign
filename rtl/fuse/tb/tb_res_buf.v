// ============================================================================
//  tb_res_buf.v -- twn_res_buf against a flat model indexed by row*ROW_WORDS+word
//  (no ring, slot or modulo in the model).
//
//  Runs at the deployed parameters: ROW_WORDS 96, DEPTH 10 (not a power of two),
//  128-bit words. Self-contained: patterns are generated from (row, word).
//  Phase 1: 32 rows through the ring with the writer LEAD rows ahead; every
//  word is read back and compared, and stale must stay low.
//  Phase 2: stale must fire when a row is read before the writer has finished
//  it (2a) and when the writer has lapped the reader by more than DEPTH (2b).
//  Reads drive rd_row_done on the same cycle as the row's last read.
//  Pass line: "=== tb_res_buf: ... ALL PASS".
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_res_buf;

    localparam integer RB = 128;
    localparam integer RW = 96;      // words per row, as deployed
    localparam integer DP = 10;      // ring depth, as deployed
    localparam integer NROW = 32;    // three laps and a bit
    localparam integer LEAD = 8;     // rows the writer runs ahead of the reader

    reg clk = 1'b0, rst = 1'b1;
    always #2 clk = ~clk;

    reg          blk_start = 1'b0;
    reg          wr_en = 1'b0, wr_row_done = 1'b0;
    reg  [127:0] wr_data = 128'd0;
    reg          rd_en = 1'b0, rd_row_done = 1'b0;
    reg  [15:0]  rd_word = 16'd0;
    wire [127:0] rd_data;
    wire         stale;

    twn_res_buf #(.ROW_BITS(RB), .ROW_WORDS(RW), .DEPTH(DP)) DUT (
        .clk(clk), .rst(rst), .blk_start(blk_start),
        .wr_en(wr_en), .wr_data(wr_data), .wr_row_done(wr_row_done),
        .rd_en(rd_en), .rd_word(rd_word), .rd_row_done(rd_row_done),
        .rd_data(rd_data), .stale(stale));

    // the model: every (row, word) ever written, in a flat array
    reg [127:0] model [0:NROW*RW-1];

    integer errors = 0, checks = 0, nrep = 0;
    integer stale_seen = 0, stale_want = 0;

    // A value that cannot be produced by reading the neighbouring row or the
    // neighbouring word: both indices appear, twice, at both ends.
    function [127:0] pat;
        input integer r;
        input integer w;
        begin
            pat = {16'hA5A5, r[15:0], w[15:0], ~r[15:0],
                   ~w[15:0], r[15:0] ^ w[15:0], 16'h5A5A, w[15:0]};
        end
    endfunction

    task wr_row;
        input integer r;
        integer w;
        begin
            for (w = 0; w < RW; w = w + 1) begin
                @(negedge clk);
                wr_en   = 1'b1;
                wr_data = pat(r, w);
                model[r*RW + w] = pat(r, w);
            end
            @(negedge clk);
            wr_en = 1'b0;
            wr_row_done = 1'b1;
            @(negedge clk);
            wr_row_done = 1'b0;
        end
    endtask

    // Reads a whole row and compares it. The address is presented DURING a
    // cycle and the memory registers it at that cycle's edge, so the answer is
    // there immediately after -- the same one-cycle contract twn_rowbuf's read
    // side has, and the one twn_fuse_top relies on to line this operand up with
    // the scatter's word one register later.
    //
    // rd_row_done is driven on the same cycle as the last read; the last read
    // must still see the row that is ending.
    task rd_row_check;
        input integer r;
        input integer expect_stale;
        integer w;
        begin
            for (w = 0; w < RW; w = w + 1) begin
                @(negedge clk);
                rd_en       = 1'b1;
                rd_word     = w[15:0];
                rd_row_done = (w == RW - 1);
                @(posedge clk);
                #1;
                if (stale) stale_seen = stale_seen + 1;
                checks = checks + 1;
                if (!expect_stale && rd_data !== model[r*RW + w]) begin
                    errors = errors + 1;
                    if (nrep < 12) begin
                        nrep = nrep + 1;
                        $display("  FAIL row %0d word %0d: got %032h want %032h",
                                 r, w, rd_data, model[r*RW + w]);
                    end
                end
            end
            @(negedge clk);
            rd_en = 1'b0; rd_row_done = 1'b0;
        end
    endtask

    integer r;
    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        blk_start = 1'b1; @(negedge clk); blk_start = 1'b0;

        // ---- phase 1: the writer LEAD rows ahead, three laps of the ring ----
        // Depth 10 must survive a lead of 8 with `stale` low throughout.
        for (r = 0; r < NROW; r = r + 1) begin
            wr_row(r);
            if (r >= LEAD) rd_row_check(r - LEAD, 0);
        end
        for (r = NROW - LEAD; r < NROW; r = r + 1) rd_row_check(r, 0);

        if (stale_seen != 0) begin
            errors = errors + 1;
            $display("  FAIL: stale asserted %0d times in normal traffic at lead %0d, depth %0d",
                     stale_seen, LEAD, DP);
        end
        checks = checks + 1;

        // ---- phase 2: the writer laps the reader, and stale must SAY SO ----
        // A too-shallow ring is silent (it returns the row DEPTH earlier), so
        // the depth is watched through `stale`.
        rst = 1'b1; @(negedge clk); @(negedge clk); rst = 1'b0;
        @(negedge clk);
        blk_start = 1'b1; @(negedge clk); blk_start = 1'b0;

        // 2a: read ahead of the writer; row 0 has not been written. An unsigned
        // `w_abs - r_abs >= DEPTH` test would pass this for the wrong reason.
        stale_seen = 0;
        rd_row_check(0, 1);
        checks = checks + 1;
        if (stale_seen == 0) begin
            errors = errors + 1;
            $display("  FAIL: row 0 was read before the loader finished it and stale never fired");
        end

        // 2b: the writer laps the reader
        rst = 1'b1; @(negedge clk); @(negedge clk); rst = 1'b0;
        @(negedge clk);
        blk_start = 1'b1; @(negedge clk); blk_start = 1'b0;
        stale_seen = 0;
        for (r = 0; r < DP + 2; r = r + 1) wr_row(r);   // reader still on row 0
        rd_row_check(0, 1);                             // row 0 is long gone
        stale_want = 1;
        checks = checks + 1;
        if (stale_seen == 0) begin
            errors = errors + 1;
            $display("  FAIL: the writer ran %0d rows past the reader in a %0d-row ring and stale never fired",
                     DP + 2, DP);
        end

        $display("");
        $display("=== tb_res_buf: %0d rows, %0d values checked, %0d errors, stale %0d/%0d, %0s ===",
                 NROW, checks, errors, stale_seen, stale_want,
                 (errors == 0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    initial begin
        #20000000;
        $display("=== tb_res_buf: WATCHDOG -- the run did not reach its own report ===");
        $finish;
    end

endmodule
`default_nettype wire
