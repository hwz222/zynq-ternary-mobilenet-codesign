// ============================================================================
//  tb_rowbuf_extmem.v -- twn_rowbuf with EXT_MEM=1 behaves like EXT_MEM=0.
//
//  Two twn_rowbuf instances, identical except EXT_MEM, get one stimulus and
//  every output is compared every cycle. The external instance gets a plain
//  registered-read memory model outside it; the reference infers its own.
//  MEM_BASE is non-zero so a dropped or misplaced offset shows up; the test also
//  counts writes that land outside this ring's MEM_BASE.. range.
//  No golden files. Self-checking, prints ALL PASS or FAIL. No break arms.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rowbuf_extmem;

    localparam integer ROW_BITS  = 128;      // narrow: this is about addressing
    localparam integer ROW_WORDS = 16;
    localparam integer DEPTH     = 4;
    localparam integer XAW       = 12;
    localparam integer MEM_BASE  = 5 * ROW_WORDS;   // deliberately not 0
    localparam integer MEM_WORDS = 1 << XAW;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    reg [9:0] h_in;
    reg       stride;
    reg       wr_en, wr_row_last, rd_en, row_done;
    reg [ROW_BITS-1:0] wr_data;
    reg [9:0]          rd_row;
    reg [$clog2(ROW_WORDS)-1:0] rd_word;

    // ---- the internal-storage reference ----
    wire [ROW_BITS-1:0] a_bank;  wire [1:0] a_mid;  wire a_pad;
    wire a_ptop, a_pbot, a_wrdy, a_wrdy_dummy, a_winrdy;
    wire [9:0] a_wptr, a_rptr, a_free;

    twn_rowbuf #(.ROW_BITS(ROW_BITS), .ROW_WORDS(ROW_WORDS), .DEPTH(DEPTH),
                 .BANKS(1), .WINDOW(1), .EXT_MEM(0), .MEM_BASE(0), .XAW(XAW)) REF (
        .clk(clk), .rst(rst), .blk_start(1'b0),
        .xm_we(), .xm_wa(), .xm_wd(), .xm_lane(), .xm_ra(), .xm_rd({ROW_BITS{1'b0}}),
        .h_in(h_in), .stride(stride),
        .wr_en(wr_en), .wr_data(wr_data), .wr_row_last(wr_row_last),
        .wr_ready(a_wrdy),
        .rd_en(rd_en), .rd_row(rd_row), .rd_word(rd_word),
        .rd_bank(a_bank), .rd_mid_bank(a_mid), .rd_bank_pad(a_pad),
        .rd_pad_top(a_ptop), .rd_pad_bot(a_pbot),
        .row_done(row_done), .win_ready(a_winrdy),
        .wptr(a_wptr), .rptr(a_rptr), .free(a_free));

    // ---- the external-storage instance, plus the array it was handed ----
    wire               x_we;
    wire [XAW-1:0]     x_wa, x_ra;
    wire [15:0]        x_lane;   // all-ones at LANE_WR = 0
    wire [ROW_BITS-1:0] x_wd;
    reg  [ROW_BITS-1:0] x_rd;

    wire [ROW_BITS-1:0] b_bank;  wire [1:0] b_mid;  wire b_pad;
    wire b_ptop, b_pbot, b_wrdy, b_winrdy;
    wire [9:0] b_wptr, b_rptr, b_free;

    twn_rowbuf #(.ROW_BITS(ROW_BITS), .ROW_WORDS(ROW_WORDS), .DEPTH(DEPTH),
                 .BANKS(1), .WINDOW(1), .EXT_MEM(1), .MEM_BASE(MEM_BASE), .XAW(XAW)) EXT (
        .clk(clk), .rst(rst), .blk_start(1'b0),
        .xm_we(x_we), .xm_wa(x_wa), .xm_wd(x_wd), .xm_lane(x_lane), .xm_ra(x_ra), .xm_rd(x_rd),
        .h_in(h_in), .stride(stride),
        .wr_en(wr_en), .wr_data(wr_data), .wr_row_last(wr_row_last),
        .wr_ready(b_wrdy),
        .rd_en(rd_en), .rd_row(rd_row), .rd_word(rd_word),
        .rd_bank(b_bank), .rd_mid_bank(b_mid), .rd_bank_pad(b_pad),
        .rd_pad_top(b_ptop), .rd_pad_bot(b_pbot),
        .row_done(row_done), .win_ready(b_winrdy),
        .wptr(b_wptr), .rptr(b_rptr), .free(b_free));

    // the shared array, one write port and one read port, registered read --
    // exactly what the internal path infers
    reg [ROW_BITS-1:0] xmem [0:MEM_WORDS-1];
    always @(posedge clk) begin
        if (x_we) xmem[x_wa] <= x_wd;
        x_rd <= xmem[x_ra];
    end

    // ---- every output, every cycle ----
    integer errors = 0, checked = 0;
    integer base_lo = 0, base_hi = 0;         // did MEM_BASE actually reach the array?

    always @(posedge clk) if (!rst) begin
        checked = checked + 1;
        if (a_bank !== b_bank || a_mid !== b_mid || a_pad !== b_pad ||
            a_ptop !== b_ptop || a_pbot !== b_pbot || a_wrdy !== b_wrdy ||
            a_winrdy !== b_winrdy || a_wptr !== b_wptr || a_rptr !== b_rptr ||
            a_free !== b_free) begin
            errors = errors + 1;
            if (errors <= 8)
                $display("  cycle %0d: bank %032h/%032h wptr %0d/%0d rptr %0d/%0d free %0d/%0d ready %0b/%0b",
                         checked, a_bank, b_bank, a_wptr, b_wptr,
                         a_rptr, b_rptr, a_free, b_free, a_wrdy, b_wrdy);
        end
        // and the offset must be real: every access lands at or above MEM_BASE
        if (x_we) begin
            if (x_wa <  MEM_BASE) base_lo = base_lo + 1;
            if (x_wa >= MEM_BASE + DEPTH*ROW_WORDS) base_hi = base_hi + 1;
        end
    end

    integer r, w;
    initial begin
        $display("=== tb_rowbuf_extmem: EXT_MEM = 0 against EXT_MEM = 1, MEM_BASE %0d ===",
                 MEM_BASE);
        // xmem is deliberately not initialised: the inferred array in the
        // reference starts as X, and zeroing this one would differ on reads of
        // locations nobody has written.
        h_in = 10'd16; stride = 1'b0;
        wr_en = 0; wr_data = 0; wr_row_last = 0;
        rd_en = 0; rd_row = 0; rd_word = 0; row_done = 0;
        repeat (3) @(negedge clk); rst = 0;

        // fill and drain twice, at both strides, reading while writing
        for (r = 0; r < 16; r = r + 1) begin
            for (w = 0; w < ROW_WORDS; w = w + 1) begin
                @(negedge clk);
                wr_en = 1;
                wr_data = {r[7:0], w[7:0], {(ROW_BITS-16){1'b0}}} ^ {ROW_BITS{r[0]}};
                wr_row_last = (w == ROW_WORDS-1);
                // read a previously written row at the same time
                rd_en = (r > 0);
                rd_row = (r > 0) ? (r - 1) : 0;
                rd_word = w[$clog2(ROW_WORDS)-1:0];
            end
            @(negedge clk);
            wr_en = 0; wr_row_last = 0;
            row_done = (r > 0); @(negedge clk); row_done = 0;
            if (r == 7) begin stride = 1'b1; h_in = 10'd16; end
        end
        repeat (6) @(negedge clk);

        if (base_lo != 0 || base_hi != 0) begin
            errors = errors + 1;
            $display("  MEM_BASE not applied: %0d writes below it, %0d past this ring's rows",
                     base_lo, base_hi);
        end

        $display("=== tb_rowbuf_extmem: %0d cycles compared, %0d errors, %s ===",
                 checked, errors,
                 (errors == 0 && checked > 100) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
`default_nettype wire
