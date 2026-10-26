`timescale 1ns/1ps
// ============================================================================
//  tb_csr_axil_b2b.v -- AXI4-Lite handshake test for twn_csr.
//
//  The master presents each next address/data right after the previous
//  handshake, without waiting for the write response. Checks: (1) two
//  back-to-back writes (A_ACT_LO, A_W_LO) land in their own registers and give
//  exactly two B responses; (2) two back-to-back reads return their own data
//  with exactly two R responses; (3) a write to 0x3000 (outside the 0x1000..0x17ff
//  descriptor window) does not pulse d_wr_en, while 0x1004 does.
//  No golden files; the expected values are in this file. Self-checking, prints
//  ALL PASS or FAIL.
//  Break arm (see sim/run_units.ps1): -DCSR_NEG_READY_LATE builds twn_csr with
//  ready still high one cycle after its handshake, so the second back-to-back
//  transaction is lost and this test must fail.
// ============================================================================
`default_nettype none
module tb_csr_axil_b2b;
    reg clk = 0, rstn = 0; always #2 clk = ~clk;
    reg [15:0] awaddr = 0; reg awvalid = 0; wire awready;
    reg [31:0] wdata = 0;  reg wvalid = 0;  wire wready;
    wire [1:0] bresp; wire bvalid; reg bready = 1;
    reg [15:0] araddr = 0; reg arvalid = 0; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready = 1;
    wire ap_start; wire [39:0] act_base, w_base, in_ptr, out_ptr; wire [4:0] n_blocks;
    wire d_wr_en; wire [12:0] d_wr_addr; wire [31:0] d_wr_data; wire d_check;
    wire hd_start, hd_d_we; wire [1:0] hd_d_wa;
    wire [39:0] hd_d_in_base, hd_d_w_base, hd_d_out_base; wire [23:0] hd_d_in_beats, hd_d_w_beats, hd_d_out_beats;
    wire [8:0] hd_d_ic; wire [5:0] hd_d_oc; wire [6:0] hd_d_h, hd_d_w; wire hd_d_type4, hd_d_slice, hd_d_relu;
    wire [15:0] hd_d_lo, hd_d_hi; wire hd_rq_we; wire [7:0] hd_rq_wa; wire [31:0] hd_rq_wd;

    twn_csr dut (.clk(clk), .rstn(rstn),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(4'hf),
        .wvalid(wvalid), .wready(wready), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready), .rdata(rdata), .rresp(rresp),
        .rvalid(rvalid), .rready(rready),
        .ap_start(ap_start), .core_busy(1'b0), .core_done(1'b0),
        .act_base(act_base), .w_base(w_base), .in_ptr(in_ptr), .out_ptr(out_ptr), .n_blocks(n_blocks),
        .d_wr_en(d_wr_en), .d_wr_addr(d_wr_addr), .d_wr_data(d_wr_data), .d_check(d_check),
        .d_valid(1'b1), .d_check_done(1'b0), .d_err_code(4'd0), .d_err_block(5'd0), .cur_block(5'd0),
        .ring_overrun(1'b0), .cyc_total(32'd0), .cyc_array(32'd0), .cyc_dw(32'd0), .cyc_stall_mem(32'd0),
        .cyc_idle_pre(32'd0), .cyc_idle_post(32'd0), .pix_nz(12'd0), .arr_cap(128'd0),
        .hd_start(hd_start), .hd_busy(1'b0), .hd_done(1'b0),
        .hd_d_we(hd_d_we), .hd_d_wa(hd_d_wa), .hd_d_in_base(hd_d_in_base), .hd_d_w_base(hd_d_w_base),
        .hd_d_out_base(hd_d_out_base), .hd_d_in_beats(hd_d_in_beats), .hd_d_w_beats(hd_d_w_beats),
        .hd_d_out_beats(hd_d_out_beats), .hd_d_ic(hd_d_ic), .hd_d_oc(hd_d_oc), .hd_d_h(hd_d_h),
        .hd_d_w(hd_d_w), .hd_d_type4(hd_d_type4), .hd_d_slice(hd_d_slice), .hd_d_relu(hd_d_relu),
        .hd_d_lo(hd_d_lo), .hd_d_hi(hd_d_hi), .hd_rq_we(hd_rq_we), .hd_rq_wa(hd_rq_wa), .hd_rq_wd(hd_rq_wd));

    integer errors = 0, nb = 0, nr = 0, alias_hits = 0;
    always @(posedge clk) begin
        if (bvalid && bready) nb <= nb + 1;
        if (rvalid && rready) nr <= nr + 1;
        if (d_wr_en) alias_hits <= alias_hits + 1;
    end

    // one write, held until BOTH channels have handshaken; returns the cycle after
    task wr(input [15:0] a, input [31:0] d);
        reg a_done, w_done;
        begin
            awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1; a_done = 0; w_done = 0;
            while (!(a_done && w_done)) begin
                @(posedge clk);
                if (awvalid && awready) begin a_done = 1; awvalid <= 0; end
                if (wvalid  && wready ) begin w_done = 1; wvalid  <= 0; end
            end
        end
    endtask
    reg [31:0] r0, r1;
    task rd(input [15:0] a);
        reg done;
        begin
            araddr <= a; arvalid <= 1; done = 0;
            while (!done) begin @(posedge clk); if (arvalid && arready) begin done = 1; arvalid <= 0; end end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rstn = 1; repeat (4) @(posedge clk);
        // (1) two writes with nothing between them
        wr(16'h000c, 32'h1111_1111);        // A_ACT_LO
        wr(16'h0014, 32'h2222_2222);        // A_W_LO
        repeat (12) @(posedge clk);
        if (act_base[31:0] !== 32'h1111_1111) begin errors = errors + 1; $display("FAIL b2b write 1 lost: act_base=%h", act_base[31:0]); end
        if (w_base[31:0]   !== 32'h2222_2222) begin errors = errors + 1; $display("FAIL b2b write 2 lost: w_base=%h",   w_base[31:0]); end
        if (nb !== 2) begin errors = errors + 1; $display("FAIL expected 2 B responses, got %0d", nb); end
        // (2) two reads with nothing between them
        fork
            begin rd(16'h000c); rd(16'h0014); end
            begin : cap
                integer k; k = 0;
                while (k < 2) begin @(posedge clk); if (rvalid && rready) begin if (k==0) r0 = rdata; else r1 = rdata; k = k + 1; end end
            end
        join
        repeat (4) @(posedge clk);
        if (r0 !== 32'h1111_1111 || r1 !== 32'h2222_2222) begin errors = errors + 1; $display("FAIL b2b reads: %h %h", r0, r1); end
        if (nr !== 2) begin errors = errors + 1; $display("FAIL expected 2 R responses, got %0d", nr); end
        // (3) a[12]=1 outside the descriptor window must not reach the table
        wr(16'h3000, 32'hdead_beef); repeat (8) @(posedge clk);
        if (alias_hits !== 0) begin errors = errors + 1; $display("FAIL write to 0x3000 reached the descriptor table (%0d pulses)", alias_hits); end
        // and the real window still works
        wr(16'h1004, 32'h0000_0042); repeat (8) @(posedge clk);
        if (alias_hits !== 1) begin errors = errors + 1; $display("FAIL write to 0x1004 did not reach the descriptor table (%0d pulses)", alias_hits); end
        if (errors == 0) $display("=== tb_csr_axil_b2b: 0 errors, ALL PASS ==="); else $display("=== tb_csr_axil_b2b: %0d errors, FAIL ===", errors);
        $finish;
    end
    initial begin #20000; $display("=== tb_csr_axil_b2b: FAIL (timeout, a transaction never completed) ==="); $finish; end
endmodule
