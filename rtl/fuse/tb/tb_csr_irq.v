`timescale 1ns/1ps
// ============================================================================
//  tb_csr_irq.v -- unit test of the interrupt output of twn_csr (v1.1): register
//  IRQ (0x0064) and the level-high irq port. Stimulus goes in only through AXI4-Lite
//  transactions plus the core_done / hd_done pulses the engines would give.
//  No golden files: all expected values are constants in this file.
//
//  Checks:
//   1. reset        irq is 0, IRQ reads 0.
//   2. masked       a backbone done with both enables off leaves irq at 0.
//   3. enable       enabling the backbone source while its done is set raises irq.
//   4. clear        writing CTRL[1] (clear done) drops irq.
//   5. survives     CTRL writes (start, clear done) do not touch the enables: a later
//                   backbone done still raises irq. (CTRL[2] is not the enable.)
//   6. head         with only the head source enabled, a backbone done stays silent
//                   and a head done raises irq; HD_CTRL[2] clears it; a head start
//                   (HD_CTRL[0]) also clears it.
//   7. readback     IRQ reads {irq, hd_done, ap_done, hd_irq_en, bb_irq_en}.
//
//  Run: sim/run_csr_irq.ps1 (intact arm plus CSR_IRQ_BREAK_MASK and CSR_IRQ_BREAK_CTRL;
//  those defines are in twn_csr.v, not here).
// ============================================================================
`default_nettype none

module tb_csr_irq;
    // Addresses are repeated here, not shared with the RTL, so a renumbered map fails.
    localparam [15:0] A_CTRL    = 16'h0000,
                      A_IRQ     = 16'h0064,
                      A_HD_CTRL = 16'h0100;

    reg clk = 1'b0, rst = 1'b1;
    always #2 clk = ~clk;

    reg  [15:0] awaddr = 0;  reg awvalid = 0;  wire awready;
    reg  [31:0] wdata  = 0;  reg wvalid  = 0;  wire wready;
    wire [1:0]  bresp;       wire bvalid;      reg bready = 0;
    reg  [15:0] araddr = 0;  reg arvalid = 0;  wire arready;
    wire [31:0] rdata;       wire [1:0] rresp; wire rvalid; reg rready = 0;
    reg  [31:0] rcap;

    reg  core_done = 1'b0, hd_done = 1'b0;
    wire irq;

    twn_csr CSR (
        .clk(clk), .rstn(~rst),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(4'hF), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .ap_start(), .core_busy(1'b0), .core_done(core_done),
        .act_base(), .w_base(), .in_ptr(), .out_ptr(), .n_blocks(),
        .d_wr_en(), .d_wr_addr(), .d_wr_data(),
        .d_check(), .d_valid(1'b0), .d_check_done(1'b0),
        .d_err_code(4'd0), .d_err_block(5'd0),
        .cur_block(5'd0), .ring_overrun(1'b0),
        .cyc_total(32'd0), .cyc_array(32'd0), .cyc_dw(32'd0),
        .cyc_stall_mem(32'd0), .cyc_idle_pre(32'd0), .cyc_idle_post(32'd0),
        .pix_nz(12'd0), .arr_cap(128'd0),
        .hd_start(), .hd_busy(1'b0), .hd_done(hd_done),
        .hd_d_we(), .hd_d_wa(),
        .hd_d_in_base(), .hd_d_w_base(), .hd_d_out_base(),
        .hd_d_in_beats(), .hd_d_w_beats(), .hd_d_out_beats(),
        .hd_d_ic(), .hd_d_oc(), .hd_d_h(), .hd_d_w(),
        .hd_d_type4(), .hd_d_slice(), .hd_d_relu(), .hd_d_lo(), .hd_d_hi(),
        .hd_rq_we(), .hd_rq_wa(), .hd_rq_wd(),
        .bb2hd_en(), .bb_par_clr(), .bb_par(1'b0), .hd_sel(1'b0), .hd_en_l(1'b0),
        .bb2hd_coll(1'b0),
        .irq(irq));

    integer fails = 0, checks = 0;

    // the same AXI4-Lite tasks as tb_csr_hd.v
    task axi_write(input [15:0] a, input [31:0] d);
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

    task axi_read(input [15:0] a);
        begin
            @(posedge clk);
            araddr <= a; arvalid <= 1'b1; rready <= 1'b1;
            @(posedge clk);
            while (!(arready && arvalid)) @(posedge clk);
            arvalid <= 1'b0;
            while (!(rvalid && rready)) @(posedge clk);
            rcap = rdata;
            @(posedge clk); rready <= 1'b0;
        end
    endtask

    task pulse_core_done; begin @(posedge clk); core_done <= 1'b1; @(posedge clk); core_done <= 1'b0; end endtask
    task pulse_hd_done;   begin @(posedge clk); hd_done   <= 1'b1; @(posedge clk); hd_done   <= 1'b0; end endtask
    task settle;          begin repeat (4) @(posedge clk); end endtask

    task expect_irq(input exp, input [8*48-1:0] what);
        begin
            checks = checks + 1;
            if (irq !== exp) begin
                $display("FAIL: %0s: irq = %b, expected %b", what, irq, exp);
                fails = fails + 1;
            end
        end
    endtask

    task expect_reg(input [31:0] exp, input [8*48-1:0] what);
        begin
            axi_read(A_IRQ);
            checks = checks + 1;
            if (rcap !== exp) begin
                $display("FAIL: %0s: IRQ reads %08h, expected %08h", what, rcap, exp);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        settle;

        // 1. reset
        expect_irq(1'b0, "1 reset");
        expect_reg(32'h0, "1 reset");

        // 2. masked: backbone done, enables off
        pulse_core_done; settle;
        expect_irq(1'b0, "2 backbone done while masked");
        expect_reg(32'h4, "2 ap_done set, no irq");

        // 3. enable the backbone source while its done is set
        axi_write(A_IRQ, 32'h1); settle;
        expect_irq(1'b1, "3 enable with done pending");
        expect_reg(32'h15, "3 irq, ap_done, bb_irq_en");

        // 4. clear done drops irq
        axi_write(A_CTRL, 32'h2); settle;
        expect_irq(1'b0, "4 CTRL clear done");

        // 5. CTRL writes keep the enable: start (refused, table unchecked), clear, then a done
        axi_write(A_CTRL, 32'h1); axi_write(A_CTRL, 32'h2); settle;
        pulse_core_done; settle;
        expect_irq(1'b1, "5 enable survives CTRL writes");
        axi_write(A_CTRL, 32'h2); settle;
        expect_irq(1'b0, "5 cleared again");

        // 6. head only
        axi_write(A_IRQ, 32'h2); settle;
        pulse_core_done; settle;
        expect_irq(1'b0, "6 backbone done, backbone source off");
        axi_write(A_CTRL, 32'h2);
        pulse_hd_done; settle;
        expect_irq(1'b1, "6 head done");
        expect_reg(32'h1A, "6 irq, hd_done, hd_irq_en");
        axi_write(A_HD_CTRL, 32'h4); settle;
        expect_irq(1'b0, "6 HD_CTRL clear done");
        pulse_hd_done; settle;
        expect_irq(1'b1, "6 head done again");
        axi_write(A_HD_CTRL, 32'h1); settle;
        expect_irq(1'b0, "6 head start clears done");

        // 7. both enables, both dones
        axi_write(A_IRQ, 32'h3);
        pulse_core_done; pulse_hd_done; settle;
        expect_reg(32'h1F, "7 everything set");
        axi_write(A_CTRL, 32'h2); settle;
        expect_irq(1'b1, "7 head done still holds irq");
        axi_write(A_HD_CTRL, 32'h4); settle;
        expect_irq(1'b0, "7 both cleared");

        if (fails == 0) $display("tb_csr_irq: PASS (%0d checks)", checks);
        else            $display("tb_csr_irq: %0d FAILURES of %0d checks", fails, checks);
        $finish;
    end

    initial begin
        #200000;
        $display("tb_csr_irq: TIMEOUT");
        $finish;
    end
endmodule
`default_nettype wire
