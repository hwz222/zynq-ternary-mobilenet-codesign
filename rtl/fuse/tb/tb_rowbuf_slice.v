// ============================================================================
//  tb_rowbuf_slice.v -- twn_rowbuf with MEM_SLICE=512 behaves like MEM_SLICE=0.
//
//  Two instances, identical except MEM_SLICE, get one stimulus and every output
//  is compared every cycle. Geometry is RB_T1's in twn_fuse_top: ROW_BITS 128,
//  ROW_WORDS 768, DEPTH 5, BANKS 3, WINDOW 3. With 768-word rows and 512-word
//  slices a row does not start on a slice boundary, so reads cross slices.
//  A coverage counter requires at least 8 slice crossings on the read path and
//  all three slices of a bank to be touched, so a stimulus that stops crossing
//  fails instead of passing. No golden files. Self-checking, ALL PASS or FAIL.
//  Break arm (see sim/run_units.ps1): -DRB_NEG_SLICE_COMB (an RTL ifdef in
//  twn_rowbuf) selects the slice with the current read address instead of the
//  registered one; the compare must then fail at slice boundaries.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rowbuf_slice;

    localparam integer ROW_BITS  = 128;      // RB_T1's, exactly
    localparam integer ROW_WORDS = 768;
    localparam integer DEPTH     = 5;
    localparam integer BANKS     = 3;
    localparam integer WINDOW    = 3;
    localparam integer SLICE     = 512;
    localparam integer WAW       = 10;       // $clog2(768)

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    reg [9:0] h_in;
    reg       stride, blk_start;
    reg       wr_en, wr_row_last, rd_en, row_done;
    reg [ROW_BITS-1:0]  wr_data;
    reg [9:0]           rd_row;
    reg [WAW-1:0]       rd_word;

    wire [BANKS*ROW_BITS-1:0] a_bank, b_bank;
    wire [1:0]  a_mid,  b_mid;
    wire [BANKS-1:0] a_pad, b_pad;
    wire a_ptop, b_ptop, a_pbot, b_pbot, a_wrdy, b_wrdy, a_winrdy, b_winrdy;
    wire [9:0] a_wptr, b_wptr, a_rptr, b_rptr, a_free, b_free;

`define RB_PORTS(pfx) \
        .clk(clk), .rst(rst), .blk_start(blk_start), \
        .xm_we(), .xm_wa(), .xm_wd(), .xm_lane(), .xm_ra(), \
        .xm_rd({ROW_BITS{1'b0}}), \
        .wr_word_i({WAW{1'b0}}), .wr_lane(16'd0), .wr_row_done(1'b0), \
        .h_in(h_in), .stride(stride), \
        .wr_en(wr_en), .wr_data(wr_data), .wr_row_last(wr_row_last), \
        .wr_ready(pfx``_wrdy), \
        .rd_en(rd_en), .rd_row(rd_row), .rd_word(rd_word), \
        .rd_bank(pfx``_bank), .rd_mid_bank(pfx``_mid), .rd_bank_pad(pfx``_pad), \
        .rd_pad_top(pfx``_ptop), .rd_pad_bot(pfx``_pbot), \
        .row_done(row_done), .win_ready(pfx``_winrdy), \
        .wptr(pfx``_wptr), .rptr(pfx``_rptr), .free(pfx``_free)

    // ---- the flat reference ----
    twn_rowbuf #(.ROW_BITS(ROW_BITS), .ROW_WORDS(ROW_WORDS), .DEPTH(DEPTH),
                 .BANKS(BANKS), .WINDOW(WINDOW), .MEM_SLICE(0)) REF (`RB_PORTS(a));

    // ---- the sliced instance: three 512-word arrays per bank ----
    twn_rowbuf #(.ROW_BITS(ROW_BITS), .ROW_WORDS(ROW_WORDS), .DEPTH(DEPTH),
                 .BANKS(BANKS), .WINDOW(WINDOW), .MEM_SLICE(SLICE)) SLC (`RB_PORTS(b));

    // ---- every output, every cycle ----
    integer errors = 0, checked = 0, xings = 0;
    reg [WAW-1:0] rd_word_q;

    always @(posedge clk) if (!rst) begin
        checked = checked + 1;
        if (a_bank !== b_bank || a_mid !== b_mid || a_pad !== b_pad ||
            a_ptop !== b_ptop || a_pbot !== b_pbot || a_wrdy !== b_wrdy ||
            a_winrdy !== b_winrdy || a_wptr !== b_wptr || a_rptr !== b_rptr ||
            a_free !== b_free) begin
            errors = errors + 1;
            if (errors <= 8)
                $display("  cycle %0d rd_row %0d rd_word %0d: bank %096h / %096h  wptr %0d/%0d rptr %0d/%0d free %0d/%0d",
                         checked, rd_row, rd_word, a_bank, b_bank,
                         a_wptr, b_wptr, a_rptr, b_rptr, a_free, b_free);
        end
    end

    // Coverage: the sliced path can only be wrong where a read steps across a
    // slice boundary. The physical address is slot*ROW_WORDS + rd_word, so the
    // boundary is not at a fixed rd_word; the slice select is modelled here from
    // that rule, independently of the RTL, and both the crossings and the set of
    // slices touched are checked at the end.
    localparam integer BD  = (DEPTH + BANKS - 1) / BANKS;   // 2
    localparam integer NSL = (BD * ROW_WORDS) / SLICE;      // 3
    reg [NSL-1:0] used = {NSL{1'b0}};
    integer sel_now, sel_q;

    function integer sel_of;
        input integer row; input integer word;
        integer slot;
        begin
            slot   = (row / BANKS) % BD;
            sel_of = (slot * ROW_WORDS + word) / SLICE;
        end
    endfunction

    initial begin sel_q = -1; sel_now = -1; end
    always @(posedge clk) if (!rst && rd_en) begin
        rd_word_q <= rd_word;
        // the window's MIDDLE row -- the one row that is never a pad
        sel_now = sel_of(stride ? (2*rd_row) : rd_row, rd_word);
        used[sel_now] = 1'b1;
        if (sel_q >= 0 && sel_now != sel_q) xings = xings + 1;
        sel_q = sel_now;
    end

    integer r, w;
    initial begin
        $display("=== tb_rowbuf_slice: MEM_SLICE 0 against MEM_SLICE %0d, %0dx%0d x%0d, %0d banks ===",
                 SLICE, ROW_BITS, ROW_WORDS, DEPTH, BANKS);
        // Neither instance's storage is initialised: both start as X and must
        // agree on the X.
        h_in = 10'd12; stride = 1'b0; blk_start = 1'b0;
        wr_en = 0; wr_data = 0; wr_row_last = 0;
        rd_en = 0; rd_row = 0; rd_word = 0; row_done = 0;
        repeat (3) @(negedge clk); rst = 0;
        @(negedge clk); blk_start = 1; @(negedge clk); blk_start = 0;

        // Twelve rows through a five-row ring, so the pointers wrap.
        for (r = 0; r < 12; r = r + 1) begin
            for (w = 0; w < ROW_WORDS; w = w + 1) begin
                @(negedge clk);
                wr_en = 1;
                wr_data = {r[7:0], w[15:0], {(ROW_BITS-24){1'b0}}} ^ {ROW_BITS{w[0]}};
                wr_row_last = (w == ROW_WORDS-1);
                // read a window centred on an earlier row while writing
                rd_en  = (r > 2);
                rd_row = (r > 2) ? (r - 2) : 0;
                rd_word = w[WAW-1:0];
            end
            @(negedge clk);
            wr_en = 0; wr_row_last = 0;
            row_done = (r > 2); @(negedge clk); row_done = 0;
            if (r == 5) stride = 1'b1;          // exercise the other release rule
            if (r == 8) stride = 1'b0;
        end
        repeat (8) @(negedge clk);

        if (xings < 8 || used !== {NSL{1'b1}}) begin
            errors = errors + 1;
            $display("  coverage: %0d boundary crossings, slices touched %b of %0d -- this run cannot see the defect it exists for",
                     xings, used, NSL);
        end

        $display("=== tb_rowbuf_slice: %0d cycles compared, %0d boundary crossings, slices %b, %0d errors, %s ===",
                 checked, xings, used, errors,
                 (errors == 0 && checked > 1000) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
`default_nettype wire
