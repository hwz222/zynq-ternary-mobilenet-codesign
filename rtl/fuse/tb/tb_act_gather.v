// tb_act_gather.v -- twn_act_gather: lane-group gather from a row buffer word array.
//
// Part 1: for every distinct (C, W) of the manifest's blocks (tb_act_gather_cases.vh,
//   written by gen_gather_cases.py in this directory) a row is built whose byte (x, c)
//   is fill(x, c), and every request (seg, xg) is compared byte by byte with the same
//   formula (zero beyond C or W). Also counts row buffer reads and cycles per request.
// Part 2: block 0's 3x3 stride-2 stem; row words (tb_act_gather_stem_row.hex) and
//   expected 4096-bit activation words (tb_act_gather_stem_act.hex) come from
//   golden/p1_golden/vec/b00_in.bin via gen_gather_cases.py, which writes them only after
//   reproducing b00_e.bin with b00_wte.bin / b00_rqe.bin. Run from this directory ($readmemh).
// No `ifdef break arms. Prints ALL PASS or FAIL; 500 ms timeout.
`timescale 1ns/1ps
`default_nettype none

module tb_act_gather;
    localparam integer ROW_BITS = 1024;
    localparam integer LANES    = 128;
    localparam integer PIX      = 4;
    localparam integer WB       = ROW_BITS / 8;
    `include "tb_act_gather_cases.vh"

    reg clk = 1'b0, rst = 1'b1;
    always #2 clk = ~clk;

    // the row, as bytes and as words
    localparam integer MAXROW = 256 * 960;              // worst W x C
    reg [7:0]          rowb [0:MAXROW-1];
    reg [ROW_BITS-1:0] mem  [0:MAXROW/WB];

    // The chunk term keeps fill from repeating with period 128 in c: without
    // it (17c mod 256 has period 256) a gather returning segment 0's bytes for
    // an even-numbered segment would still match. 101*(c>>7) makes the offsets
    // of chunks 1..7 all nonzero mod 256.
    function [7:0] fill;
        input integer x;
        input integer c;
        begin fill = (x * 31 + c * 17 + 101 * (c >> 7) + 5) & 8'hFF; end
    endfunction

    reg         req;
    reg  [9:0]  xg;
    reg  [2:0]  seg;
    reg  [9:0]  c_chan;
    reg         stem, stem_pad_row;
    // Tag of the row `mem` holds; bumped whenever `mem` is rewritten, as the
    // row buffer's source tag (gath_src in twn_fuse_top) changes with the row.
    reg  [10:0] src = 11'd0;
    wire        busy, gdone;
    wire [15:0] rb_word;
    wire        rb_re;
    reg  [ROW_BITS-1:0] rb_data;
    always @(posedge clk) rb_data <= mem[rb_word];
    wire [PIX*LANES*8-1:0] act_data;

    twn_act_gather #(.ROW_BITS(ROW_BITS), .LANES(LANES), .PIX(PIX)) DUT (
        .clk(clk), .rst(rst),
        .req(req), .xg(xg), .seg(seg), .c_chan(c_chan),
        .stem(stem), .stem_pad_row(stem_pad_row), .src(src),
        .busy(busy), .done(gdone),
        .rb_word(rb_word), .rb_re(rb_re), .rb_data(rb_data),
        .act_data(act_data));

    // ---- block 0's stem: vectors from gen_gather_cases.py ------------------
    reg [ROW_BITS-1:0]     srow [0:NSTEM*STEM_ROWW-1];
    reg [PIX*LANES*8-1:0]  sact [0:NSTEM*STEM_NXG-1];
    initial begin
        $readmemh("tb_act_gather_stem_row.hex", srow);
        $readmemh("tb_act_gather_stem_act.hex", sact);
    end

    // Row buffer model: rb_data is registered from mem[rb_word], so data is
    // valid one cycle after the address.

    integer errors = 0, checked = 0, nreq = 0, nread = 0, max_read = 0;
    integer this_read;
    always @(posedge clk) if (!rst && rb_re) begin
        nread = nread + 1; this_read = this_read + 1;
    end

    // ---- cycles per request (reported, not a verdict) ------------------
    // argument in a comment.
    integer this_cyc, max_cyc = 0, max_cyc_stem = 0;
    always @(posedge clk) if (!rst && busy) this_cyc = this_cyc + 1;

    integer ci, C, W, nseg, nxg, s, g, x, p, k, byi;
    reg [7:0] want, got;
    integer si, sw, serr, schk, sr, sp;

    task build_row;
        input integer C_;
        input integer W_;
        integer xx, cc, i, j;
        reg [ROW_BITS-1:0] acc;
        begin
            for (xx = 0; xx < W_; xx = xx + 1)
                for (cc = 0; cc < C_; cc = cc + 1)
                    rowb[xx * C_ + cc] = fill(xx, cc);
            // one word past the end is read on purpose by the last pixel, so it
            // must hold something defined rather than X
            for (i = W_ * C_; i < W_ * C_ + 2 * WB; i = i + 1) rowb[i] = 8'hA5;
            for (i = 0; i <= (W_ * C_ + 2 * WB) / WB; i = i + 1) begin
                acc = {ROW_BITS{1'b0}};
                for (j = 0; j < WB; j = j + 1)
                    acc[j*8 +: 8] = rowb[i * WB + j];
                mem[i] = acc;
            end
            src = src + 11'd1;      // `mem` is now a different row
        end
    endtask

    initial begin
        req = 1'b0; xg = 0; seg = 0; c_chan = 0; this_read = 0;
        stem = 1'b0; stem_pad_row = 1'b0;
        serr = 0; schk = 0;
        repeat (8) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        for (ci = 0; ci < NCASE; ci = ci + 1) begin
            C = GC_C[ci*16 +: 16];
            W = GC_W[ci*16 +: 16];
            build_row(C, W);
            nseg = (C + LANES - 1) / LANES;
            nxg  = W / PIX;
            if (nxg == 0) nxg = 1;
            c_chan = C[9:0];

            for (s = 0; s < nseg; s = s + 1)
                for (g = 0; g < nxg; g = g + 1) begin
                    seg = s[2:0]; xg = g[9:0];
                    this_read = 0; this_cyc = 0;
                    @(negedge clk); req = 1'b1;
                    @(negedge clk); req = 1'b0;
                    while (!gdone) @(negedge clk);
                    @(negedge clk);
                    nreq = nreq + 1;
                    if (this_read > max_read) max_read = this_read;
                    if (this_cyc > max_cyc) max_cyc = this_cyc;

                    for (p = 0; p < PIX; p = p + 1) begin
                        x = g * PIX + p;
                        for (k = 0; k < LANES; k = k + 1) begin
                            checked = checked + 1;
                            byi = s * LANES + k;
                            want = (byi < C && x < W) ? fill(x, byi) : 8'h00;
                            got  = act_data[(p*LANES + k)*8 +: 8];
                            if (got !== want) begin
                                errors = errors + 1;
                                if (errors <= 8)
                                    $display("  C=%0d W=%0d seg=%0d xg=%0d p=%0d lane=%0d: got %02h want %02h",
                                             C, W, s, g, p, k, got, want);
                            end
                        end
                    end
                end
        end

        // ---- block 0's stem ----
        // Whole 4096-bit words are compared, including the zero lanes beyond the
        // nine live ones, so bytes leaked from a previous request are caught.
        // Request order is the array's: xg outer, kernel row (seg) inner. In this
        // order the three passes of one pixel group ask for the same word index at
        // different input rows, which is what exercises the gather's source tag; the
        // row is therefore reloaded per request.
        stem   = 1'b1;
        c_chan = 10'd3;                          // as the descriptor gives it
        for (sr = 0; sr < NSTEM/3; sr = sr + 1)
          for (g = 0; g < STEM_NXG; g = g + 1)
            for (sp = 0; sp < 3; sp = sp + 1) begin
                si = sr * 3 + sp;
                for (k = 0; k < STEM_ROWW; k = k + 1)
                    mem[k] = srow[si * STEM_ROWW + k];
                src          = 11'd100 + si;     // a new row under the read port
                seg          = ST_SEG[si*16 +: 16];
                stem_pad_row = (ST_PAD[si*16 +: 16] != 16'd0);
                xg = g[9:0]; this_cyc = 0;
                @(negedge clk); req = 1'b1;
                @(negedge clk); req = 1'b0;
                while (!gdone) @(negedge clk);
                @(negedge clk);
                nreq = nreq + 1;
                if (this_cyc > max_cyc_stem) max_cyc_stem = this_cyc;
                for (sw = 0; sw < PIX*LANES; sw = sw + 1) begin
                    schk = schk + 1;
                    got  = act_data[sw*8 +: 8];
                    want = sact[si * STEM_NXG + g][sw*8 +: 8];
                    if (got !== want) begin
                        serr = serr + 1;
                        if (serr <= 8)
                            $display("  stem e_row=%0d pass=%0d xg=%0d pix=%0d lane=%0d: got %02h want %02h",
                                     ST_ROW[si*16 +: 16], ST_SEG[si*16 +: 16], g,
                                     sw / LANES, sw % LANES, got, want);
                    end
                end
            end
        stem = 1'b0;

        // Reported only: cycles per request are not checked against a limit here.
        $display("  worst request: %0d cycles (1x1) / %0d cycles (stem); the array re-reads every n_ocg cycles",
                 max_cyc, max_cyc_stem);
        $display("=== tb_act_gather: %0d cases, %0d words, %0d values, %0d errors, %0d reads (worst %0d); stem %0d cases, %0d values, %0d errors; %s ===",
                 NCASE, nreq, checked, errors, nread, max_read,
                 NSTEM, schk, serr,
                 (errors == 0 && checked > 0 && serr == 0 && schk > 0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    initial begin
        #500_000_000;
        $display("=== tb_act_gather: TIMEOUT after %0d values, %0d errors (stem %0d, %0d) ===",
                 checked, errors, schk, serr);
        $finish;
    end
endmodule
`default_nettype wire
