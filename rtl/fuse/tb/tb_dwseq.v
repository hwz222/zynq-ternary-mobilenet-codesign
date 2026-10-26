// tb_dwseq.v -- twn_dwseq: the depthwise walk, for all 17 blocks.
//
// Inputs: tb_uop_cases.vh (UC_* per block, written by gen_uop_cases.py in this
//   directory). Block 0's width is halved (UC_STEM), as twn_fuse_top does (w_mid_t).
// Walk order reference is run_d in tb_p4_block.v: lane group outer, column inner,
//   x = 0..w_in-1 with in_valid high, then one cycle low.
// Checks per block, over two grants of d_req (pass 0 holds it high far longer than
//   the row needs, pass 1 drops it for one cycle, as twn_blockseq does):
//   ORDER     (in_tag, in_x) sequence and in_first / in_last flags
//   COVERAGE  every (g, x) is hit exactly twice over the two grants
//   HOLD      taps_addr constant over a lane group and equal to mb_dw + g
//   WINDOW    rqd_addr names the group of the column presented RQ_ADDR_HOLD cycles earlier
//   ADDRESS   rd_word / rd_half equal x*c_mid + g*8 (computed here), delayed by RD_LEAD
// ifdef arms: DWSEQ_TB_NEG_RQ_LAG5 (testbench only) puts one register in front of the
//   window check, equal to RQ_LAG = 5, and must fail; DWSEQ_NEG_NO_SPENT (in twn_dwseq.v)
//   lets a held d_req restart the walk and must fail the pass-0 count.
`timescale 1ns/1ps
`default_nettype none

module tb_dwseq;
    `include "tb_uop_cases.vh"

    localparam integer DW_LANES = 8;
    // The address is driven RD_LEAD cycles before the column it fetches; the
    // ADDRESS check compares against a copy delayed by the same amount.
    localparam integer RD_LEAD = 1;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    reg [9:0]  c_mid;
    reg [8:0]  w_in;
    reg [9:0]  mb_dw;
    reg [12:0] mb_rqd;
    reg        d_req;

    wire [9:0]  taps_addr;
    wire [12:0] rqd_addr;
    wire [15:0] rd_word;
    wire        rd_half;
    wire        in_valid, in_first, in_last;
    wire [7:0]  in_x, in_tag;

    twn_dwseq #(.DW_LANES(DW_LANES), .RD_LEAD(RD_LEAD)) DUT (
        .clk(clk), .rst(rst),
        .c_mid(c_mid), .w_in(w_in), .mb_dw(mb_dw), .mb_rqd(mb_rqd),
        .d_req(d_req),
        .taps_addr(taps_addr), .rqd_addr(rqd_addr),
        .rd_word(rd_word), .rd_half(rd_half),
        .in_valid(in_valid), .in_x(in_x),
        .in_first(in_first), .in_last(in_last), .in_tag(in_tag));

    // coverage: one counter per (g, x) of the widest block
    localparam integer MAXG = 120;          // c_mid 960 / 8
    localparam integer MAXX = 256;
    integer hit [0:MAXG*MAXX-1];

    integer errors = 0, i, b, g, x, k, pass;
    integer c_m, wi, n_lg, seen, exp_g, exp_x, tot;
    integer hold_err, order_err, addr_err;
    reg [9:0]  last_taps;
    // the read address, delayed by RD_LEAD, so it can be checked against the
    // column it actually fetched
    reg [15:0] rdw_h [0:RD_LEAD];
    reg        rdh_h [0:RD_LEAD];
    integer    rdi;
    reg [19:0] exp_off;
    reg [12:0] last_rqd;

    // ---- requant address window ----
    // The requant constants are read after the column has passed through the
    // array, so rqd_addr lags the walk: at cycle j it must name the group of the
    // column presented at j - RQ_ADDR_HOLD. Moving too early corrupts the tail of
    // the ending group, too late the head of the next. The value is the array's
    // depth written down here (twn_dwseq alone is instantiated, so a change in
    // twn_dw_array is not seen by this bench).
    localparam integer RQ_ADDR_HOLD  = 3;
    integer ghist [0:RQ_ADDR_HOLD];
    integer cur_g, gi2, tail_err;

    // The address the window check reads. DWSEQ_TB_NEG_RQ_LAG5 adds one register
    // in front of it, which is the same as twn_dwseq with RQ_LAG = 5.
`ifdef DWSEQ_TB_NEG_RQ_LAG5
    reg [12:0] rqd_chk;
    always @(posedge clk) rqd_chk <= rqd_addr;
`else
    wire [12:0] rqd_chk = rqd_addr;
`endif

    initial begin
        $display("=== tb_dwseq: the depthwise walk, %0d blocks ===", NCASE);
        d_req = 0; c_mid = 0; w_in = 0; mb_dw = 0; mb_rqd = 0;
        repeat (3) @(negedge clk); rst = 0;
        tot = 0;

        for (i = 0; i < NCASE; i = i + 1) begin
            b    = UC_BLK [i*8  +: 8];
            c_m  = UC_CMID[i*16 +: 16];
            // The depthwise walks the expand's output row: w_in / 2 for the stem
            // (twn_fuse_top: w_mid_t).
            wi   = UC_STEM[i] ? (UC_WIN[i*16 +: 16] / 2) : UC_WIN[i*16 +: 16];
            n_lg = (c_m + DW_LANES - 1) / DW_LANES;

            rst = 1; @(negedge clk); @(negedge clk); rst = 0;
            c_mid  = c_m[9:0];
            w_in   = wi[8:0];
            mb_dw  = 10'd37 + b[9:0];        // arbitrary, non-zero, per block
            mb_rqd = 13'd91 + b[12:0];

            for (k = 0; k < MAXG*MAXX; k = k + 1) hit[k] = 0;
            seen = 0; exp_g = 0; exp_x = 0;
            hold_err = 0; order_err = 0; addr_err = 0;
            tail_err = 0;
            for (gi2 = 0; gi2 <= RQ_ADDR_HOLD; gi2 = gi2 + 1) ghist[gi2] = -1;
            last_taps = 10'h3FF; last_rqd = 13'h1FFF;

            @(negedge clk); d_req = 1;

            // ---- two grants, with one cycle of d_req low between them ----
            // twn_dwseq re-arms on d_req falling. Pass 0 holds d_req high for far
            // longer than the row needs (the walk must not restart); pass 1 gives
            // the single low cycle twn_blockseq provides (d_req_r & ~d_done) and
            // requires the same walk again, so every (g, x) is hit twice.
            for (pass = 0; pass < 2; pass = pass + 1) begin
            if (pass == 1) begin
                exp_g = 0; exp_x = 0;
                // Driven on negedges: exactly one posedge sees d_req low.
                @(negedge clk); d_req = 0;
                @(negedge clk); d_req = 1;
            end
            for (k = 0; k < n_lg*(wi+1) + 40; k = k + 1) begin
                @(posedge clk); #1;
                // the group of the column being presented on THIS cycle, taken
                // before exp_g advances below
                cur_g = in_valid ? exp_g : -1;
                // Shift first, then read: ghist[k] is the column presented k
                // cycles ago, ghist[RQ_ADDR_HOLD] is the one at j - RQ_ADDR_HOLD.
                for (gi2 = RQ_ADDR_HOLD; gi2 > 0; gi2 = gi2 - 1)
                    ghist[gi2] = ghist[gi2-1];
                ghist[0] = cur_g;
                // ---- the requant address's window contract ----
                if (ghist[RQ_ADDR_HOLD] >= 0 &&
                    rqd_chk !== (13'd91 + b[12:0]) + ghist[RQ_ADDR_HOLD][12:0]) begin
                    tail_err = tail_err + 1;
                    if (tail_err <= 3)
                        $display("  blk %2d: rqd_addr is %0d (group %0d) on the cycle the requant needs group %0d's constants -- twn_dw_array reads m0/bias/sh FOUR posedges after the column was presented and twn_wmem's read is registered, so the address must name that group %0d cycles later",
                                 b, rqd_chk, rqd_chk - (13'd91 + b[12:0]),
                                 ghist[RQ_ADDR_HOLD], RQ_ADDR_HOLD);
                end
                for (rdi = RD_LEAD; rdi > 0; rdi = rdi - 1) begin
                    rdw_h[rdi] = rdw_h[rdi-1];
                    rdh_h[rdi] = rdh_h[rdi-1];
                end
                rdw_h[0] = rd_word;
                rdh_h[0] = rd_half;
                if (in_valid) begin
                    // ---- order ----
                    if (in_tag !== exp_g[7:0] || in_x !== exp_x[7:0]) begin
                        order_err = order_err + 1;
                        if (order_err <= 3)
                            $display("  blk %2d: got (g %0d, x %0d) want (g %0d, x %0d)",
                                     b, in_tag, in_x, exp_g, exp_x);
                    end
                    // ---- first / last ----
                    if (in_first !== (exp_x == 0) || in_last !== (exp_x == wi-1)) begin
                        order_err = order_err + 1;
                        if (order_err <= 3)
                            $display("  blk %2d: (g %0d, x %0d) first %0b last %0b",
                                     b, exp_g, exp_x, in_first, in_last);
                    end
                    // ---- coverage ----
                    if (exp_g < MAXG && exp_x < MAXX) begin
                        hit[exp_g*MAXX + exp_x] = hit[exp_g*MAXX + exp_x] + 1;
                        seen = seen + 1;
                    end
                    // ---- the row-buffer READ ADDRESS ----
                    // ---- the row-buffer read address ----
                    // Derived from the geometry, compared with the address delayed
                    // by RD_LEAD.
                    exp_off = exp_x * c_mid + exp_g * DW_LANES;
                    if (rdw_h[RD_LEAD] !== exp_off[19:4] ||
                        rdh_h[RD_LEAD] !== exp_off[3]) begin
                        addr_err = addr_err + 1;
                        if (addr_err <= 3)
                            $display("  blk %2d g %0d x %0d: read address is word %0d half %0b, want word %0d half %0b (byte %0d = x*c_mid + g*%0d)",
                                     b, exp_g, exp_x, rdw_h[RD_LEAD], rdh_h[RD_LEAD],
                                     exp_off[19:4], exp_off[3], exp_off, DW_LANES);
                    end
                    // ---- the tap address: constant over a lane group ----
                    // (rqd_addr is not held; it is checked by the window above)
                    if (exp_x == 0) begin
                        last_taps = taps_addr;
                        if (taps_addr !== (10'd37 + b[9:0]) + exp_g[9:0]) begin
                            hold_err = hold_err + 1;
                            if (hold_err <= 3)
                                $display("  blk %2d g %0d: taps %0d, want %0d",
                                         b, exp_g, taps_addr, (37 + b) + exp_g);
                        end
                    end else if (taps_addr !== last_taps) begin
                        hold_err = hold_err + 1;
                        if (hold_err <= 3)
                            $display("  blk %2d g %0d x %0d: the tap weights MOVED mid-group",
                                     b, exp_g, exp_x);
                    end

                    exp_x = exp_x + 1;
                    if (exp_x == wi) begin exp_x = 0; exp_g = exp_g + 1; end
                end
            end
            // After pass 0 the walk must have stopped: `spent` is latched and
            // d_req never fell, so the extra 40 cycles produced nothing. If it
            // restarted here, `seen` is already past one walk and the count
            // below catches it.
            if (pass == 0 && seen != n_lg*wi) begin
                errors = errors + 1;
                $display("  blk %2d: pass 0 saw %0d valid cycles, one walk is %0d x %0d = %0d",
                         b, seen, n_lg, wi, n_lg*wi);
                $display("         d_req was held HIGH throughout, so the walk restarted -- the");
                $display("         `spent` latch is not holding and the row would be issued twice");
            end
            end
            d_req = 0; @(negedge clk); @(negedge clk);

            // ---- the verdict for this block ----
            // TWO walks, so twice the columns.
            if (seen != 2*n_lg*wi) begin
                errors = errors + 1;
                $display("  blk %2d: %0d valid cycles over two grants, two walks are 2 x %0d x %0d = %0d",
                         b, seen, n_lg, wi, 2*n_lg*wi);
                if (seen == n_lg*wi)
                    $display("         exactly ONE walk: the second grant produced nothing, so the");
                    $display("         module did not re-arm on the single cycle of d_req low");
            end
            g = 0;                              // columns walked the wrong number of times
            x = 0;                              // never walked
            for (k = 0; k < n_lg*wi; k = k + 1) begin
                if (hit[(k/wi)*MAXX + (k%wi)] == 0)      x = x + 1;
                else if (hit[(k/wi)*MAXX + (k%wi)] != 2) g = g + 1;
            end
            if (g != 0 || x != 0) begin
                errors = errors + 1;
                $display("  blk %2d COVERAGE: %0d columns not walked exactly twice, %0d never", b, g, x);
            end
            if (order_err != 0 || hold_err != 0) begin
                errors = errors + 1;
                $display("  blk %2d: %0d order/flag errors, %0d weight-hold errors",
                         b, order_err, hold_err);
            end
            if (tail_err != 0) begin
                errors = errors + 1;
                $display("  blk %2d: %0d cycles where rqd_addr did not name the group whose constants the requant was about to consume",
                         b, tail_err);
            end
            // addr_err is part of the verdict
            if (addr_err != 0) begin
                errors = errors + 1;
                $display("  blk %2d: %0d columns fetched from the wrong row-buffer address",
                         b, addr_err);
            end
            if (errors == 0 || (order_err == 0 && hold_err == 0 && tail_err == 0 &&
                                addr_err == 0 && g == 0 && x == 0))
                $display("  blk %2d  c_mid %4d  w_in %3d  %2d groups x %3d columns = %5d, in order",
                         b, c_m, wi, n_lg, wi, seen);
            tot = tot + seen;
        end

        $display("=== tb_dwseq: %0d blocks, %0d walked columns, %0d errors, %s ===",
                 NCASE, tot, errors,
                 (errors == 0 && tot > 0) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
`default_nettype wire
