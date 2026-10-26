// tb_desctab.v -- twn_csr + twn_desctab: boot check of the descriptor table and the start gate.
//
// Inputs: tb_desctab_words.vh (17 descriptors of 16 words, written by tools/gen_desctab.py
//   from golden/p1_golden/vec/p1_manifest.json and fuse_weights_index.json).
// Checks: (1) the real table loads through the AXI-Lite window and passes; (2) five
//   single-field faults are each caught with the expected error code and block, each
//   restored afterwards; (3) a start is refused (ap_start stays low) while the table
//   has not passed and accepted after. A final run proves the restore.
// No `ifdef break arms. Prints ALL PASS or FAIL; 10 ms timeout.
`timescale 1ns/1ps
`default_nettype none

module tb_desctab;
    `include "tb_desctab_words.vh"

    localparam [3:0] E_NONE = 4'd0, E_SLOT_RANGE = 4'd1, E_SLOT_SAME = 4'd2,
                     E_SLOT_CHAIN = 4'd3, E_TERN_OVF = 4'd4, E_DW_OVF = 4'd5,
                     E_RQA_OVF = 4'd6, E_RQD_OVF = 4'd7, E_GEOM = 4'd8;

    reg clk = 1'b0, rstn = 1'b0;
    always #2 clk = ~clk;

    // ---- AXI-Lite driver ----
    reg  [15:0] awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg wvalid;   wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [15:0] araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    wire        ap_start;
    // ap_start is a level held until the core takes it; core_busy_tb is raised
    // briefly to take it, as the core does.
    reg         core_busy_tb = 1'b0;
    wire [39:0] act_base, w_base, in_ptr, out_ptr;
    wire [4:0]  n_blocks;
    wire        d_wr_en, d_check;
    wire [12:0] d_wr_addr;
    wire [31:0] d_wr_data;
    wire        d_valid, d_check_done, d_check_busy;
    wire [3:0]  d_err_code;
    wire [4:0]  d_err_block;

    twn_csr CSR (
        .clk(clk), .rstn(rstn),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(4'hF), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .ap_start(ap_start), .core_busy(core_busy_tb), .core_done(1'b0),
        .act_base(act_base), .w_base(w_base), .in_ptr(in_ptr), .out_ptr(out_ptr),
        .n_blocks(n_blocks),
        .d_wr_en(d_wr_en), .d_wr_addr(d_wr_addr), .d_wr_data(d_wr_data),
        .d_check(d_check), .d_valid(d_valid), .d_check_done(d_check_done),
        .d_err_code(d_err_code), .d_err_block(d_err_block),
        .cur_block(5'd0), .ring_overrun(1'b0),
        .cyc_total(32'd0), .cyc_array(32'd0), .cyc_dw(32'd0),
        .cyc_stall_mem(32'd0), .cyc_idle_pre(32'd0), .cyc_idle_post(32'd0),
        // tied off so no input is X
        .pix_nz(12'd0), .arr_cap(128'd0));

    // The four depths equal twn_wmem's defaults and are repeated here so the
    // fault below stays tied to them.
    twn_desctab #(.NBLK_MAX(20), .NSLOT(2),
                  .TERN_WORDS(8160), .DW_WORDS(240),
                  .RQA_WORDS(600), .RQD_WORDS(240)) DT (
        .clk(clk), .rstn(rstn),
        .wr_en(d_wr_en), .wr_addr(d_wr_addr), .wr_data(d_wr_data),
        .n_blocks(n_blocks),
        .check(d_check), .check_busy(d_check_busy), .check_done(d_check_done),
        .valid(d_valid), .err_code(d_err_code), .err_block(d_err_block),
        .blk(5'd0), .desc_ready(),
        .blk_f(5'd0), .descf_ready(),
        .c_in(), .c_mid(), .c_out(), .h_in(), .w_in(), .s_dw(),
        .pack_e(), .pack_p(), .in_slot(), .out_slot(), .res_slot(), .has_res(),
        .row_bytes_in(), .row_bytes_out(),
        .off_tern(), .off_dw(), .off_rqa(), .off_rqd(),
        .n_tern(), .n_dw(), .n_rqa(), .n_rqd(),
        .mb_tern(), .mb_dw(), .mb_rqa(), .mb_rqd(),
        .fb_tern(), .fb_dw(), .fb_rqa(), .fb_rqd());

    integer errors = 0, checks = 0;

    task wr;
        input [15:0] a; input [31:0] d;
        begin
            @(posedge clk);
            awaddr <= a; awvalid <= 1'b1; wdata <= d; wvalid <= 1'b1; bready <= 1'b1;
            @(posedge clk);
            while (!(awready && awvalid)) @(posedge clk);
            awvalid <= 1'b0;
            while (!(wready && wvalid)) @(posedge clk);
            wvalid <= 1'b0;
            while (!bvalid) @(posedge clk);
            @(posedge clk); bready <= 1'b0;
        end
    endtask

    task load_word;
        input integer b; input integer w; input [31:0] d;
        begin wr(16'h1000 + (b * 16 + w) * 4, d); end
    endtask

    task load_all;
        integer b, w;
        begin
            for (b = 0; b < DT_NBLK; b = b + 1)
                for (w = 0; w < 16; w = w + 1)
                    load_word(b, w, DT_WORDS[(b * 16 + w) * 32 +: 32]);
        end
    endtask

    task run_check;
        begin
            wr(16'h0030, 32'd1);
            while (!d_check_done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task chk_state;
        input [8*24-1:0] name;
        input            want_valid;
        input [3:0]      want_code;
        input [4:0]      want_block;
        begin
            checks = checks + 1;
            if (d_valid !== want_valid ||
                (!want_valid && (d_err_code !== want_code || d_err_block !== want_block))) begin
                errors = errors + 1;
                $display("  %0s: valid %0d code %0d block %0d, want valid %0d code %0d block %0d",
                         name, d_valid, d_err_code, d_err_block,
                         want_valid, want_code, want_block);
            end
        end
    endtask

    // a start must be refused unless the table passed
    task expect_start;
        input [8*24-1:0] name;
        input            want;
        begin
            checks = checks + 1;
            wr(16'h0000, 32'd1);
            @(posedge clk);
            if (ap_start !== want) begin
                errors = errors + 1;
                $display("  %0s: ap_start %0d, want %0d", name, ap_start, want);
            end
            core_busy_tb = 1'b1; @(posedge clk); @(posedge clk);
            core_busy_tb = 1'b0; @(posedge clk);
            wr(16'h0000, 32'd2);          // clear done, leave start alone
        end
    endtask

    // inject one field of one real descriptor, check, then restore it
    task fault;
        input [8*24-1:0] name;
        input integer    b;
        input integer    w;
        input [31:0]     bad;
        input [3:0]      want_code;
        input [4:0]      want_block;
        begin
            load_word(b, w, bad);
            run_check();
            chk_state(name, 1'b0, want_code, want_block);
            expect_start(name, 1'b0);
            load_word(b, w, DT_WORDS[(b * 16 + w) * 32 +: 32]);
        end
    endtask

    reg [31:0] t;
    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 1;
        rstn = 1'b0;
        repeat (8) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk);

        wr(16'h0008, DT_NBLK);            // N_BLOCKS

        // ---- 1. the real table ----
        load_all();
        run_check();
        chk_state("real table", 1'b1, E_NONE, 5'd0);
        expect_start("real table", 1'b1);

        // ---- 2. each failure mode, one field at a time ----
        // block 5: in_slot 0, out_slot 1 (word 1 bits [27:24] and [31:28])
        t = DT_WORDS[(5 * 16 + 1) * 32 +: 32];
        fault("slot out of range", 5, 1, (t & 32'h0FFF_FFFF) | (32'd3 << 28),
              E_SLOT_RANGE, 5'd5);
        fault("in_slot == out_slot", 5, 1, (t & 32'h0FFF_FFFF) | (32'd0 << 28),
              E_SLOT_SAME, 5'd5);
        // break block 6's in_slot so block 5's chain rule fires first
        t = DT_WORDS[(6 * 16 + 1) * 32 +: 32];
        fault("broken slot chain", 6, 1, (t & 32'hF0FF_FFFF) | (32'd0 << 24),
              E_SLOT_CHAIN, 5'd5);
        // word 9 [13:0] is the ternary base. Block 5 holds 112 ternary words, so
        // base 8049 ends at 8161, one past TERN_WORDS = 8160 (8048 ends flush, legal).
        t = DT_WORDS[(5 * 16 + 9) * 32 +: 32];
        fault("ternary base overflows", 5, 9, (t & 32'hFFFF_C000) | 32'd8049,
              E_TERN_OVF, 5'd5);
        // word 0: zero c_mid
        t = DT_WORDS[(5 * 16 + 0) * 32 +: 32];
        fault("zero geometry", 5, 0, t & 32'hFFF0_03FF, E_GEOM, 5'd5);

        // ---- 3. the real table again, to prove the faults were restored ----
        run_check();
        chk_state("restored table", 1'b1, E_NONE, 5'd0);
        expect_start("restored table", 1'b1);

        $display("=== tb_desctab: %0d blocks, %0d assertions, %0d errors, %s ===",
                 DT_NBLK, checks, errors,
                 (errors == 0 && checks > 0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("=== tb_desctab: TIMEOUT after %0d assertions, %0d errors ===",
                 checks, errors);
        $finish;
    end
endmodule
`default_nettype wire
