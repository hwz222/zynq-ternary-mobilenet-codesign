// ============================================================================
//  tb_fuse_dut.vh -- twn_fuse_top (DUT) and its two DDR windows (DDR_A on HP0
//  for activations, DDR_W on HP1 for weights, read only), with every wire
//  between them. Included by tb_fuse_frame.v so the testbench drives
//  the same instantiation.
//
//  Requires from the including file, before this line:
//      `include "tb_fuse_map.vh"     arena and per-block geometry (FM_*)
//      `include "tb_fuse_env.vh"     AXI-Lite driver and s_* signals
//      reg clk, rst
//  Provides DUT, DDR_A, DDR_W and the AXI wires. It checks nothing.
// ============================================================================
    // =====================================================================
    //  the DUT
    // =====================================================================
    wire        busy, done, wf_busy, wf_done;

    // HP0, activations: read and write
    wire [39:0]  a_araddr;  wire [7:0] a_arlen;  wire [2:0] a_arsize;
    wire [1:0]   a_arburst; wire [3:0] a_arcache; wire [2:0] a_arprot;
    wire         a_arvalid, a_arready;
    wire [127:0] a_rdata;   wire [1:0] a_rresp;  wire a_rlast, a_rvalid, a_rready;
    wire [39:0]  a_awaddr;  wire [7:0] a_awlen;  wire [2:0] a_awsize;
    wire [1:0]   a_awburst; wire [3:0] a_awcache; wire [2:0] a_awprot;
    wire         a_awvalid, a_awready;
    wire [127:0] a_wdata;   wire [15:0] a_wstrb; wire a_wlast, a_wvalid, a_wready;
    wire [1:0]   a_bresp;   wire a_bvalid, a_bready;

    // HP1, weights: read only
    wire [39:0]  w_araddr;  wire [7:0] w_arlen;  wire [2:0] w_arsize;
    wire [1:0]   w_arburst; wire [3:0] w_arcache; wire [2:0] w_arprot;
    wire         w_arvalid, w_arready;
    wire [127:0] w_rdata;   wire [1:0] w_rresp;  wire w_rlast, w_rvalid, w_rready;

    wire         o_arr_busy, o_act_re, o_w_re;
    wire [8:0]   o_ld_row;
    wire [31:0]  cyc_total, cyc_array, cyc_dw, cyc_stall_mem, cyc_idle_pre, cyc_idle_post;

    twn_fuse_top DUT (
        .clk(clk), .rst(rst),
        .busy(busy), .done(done),

        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid), .s_rready(s_rready),

        .a_araddr(a_araddr), .a_arlen(a_arlen), .a_arsize(a_arsize),
        .a_arburst(a_arburst), .a_arcache(a_arcache), .a_arprot(a_arprot),
        .a_arvalid(a_arvalid), .a_arready(a_arready),
        .a_rdata(a_rdata), .a_rresp(a_rresp), .a_rlast(a_rlast),
        .a_rvalid(a_rvalid), .a_rready(a_rready),
        .a_awaddr(a_awaddr), .a_awlen(a_awlen), .a_awsize(a_awsize),
        .a_awburst(a_awburst), .a_awcache(a_awcache), .a_awprot(a_awprot),
        .a_awvalid(a_awvalid), .a_awready(a_awready),
        .a_wdata(a_wdata), .a_wstrb(a_wstrb), .a_wlast(a_wlast),
        .a_wvalid(a_wvalid), .a_wready(a_wready),
        .a_bresp(a_bresp), .a_bvalid(a_bvalid), .a_bready(a_bready),

        .wf_busy(wf_busy), .wf_done(wf_done),
        .w_araddr(w_araddr), .w_arlen(w_arlen), .w_arsize(w_arsize),
        .w_arburst(w_arburst), .w_arcache(w_arcache), .w_arprot(w_arprot),
        .w_arvalid(w_arvalid), .w_arready(w_arready),
        .w_rdata(w_rdata), .w_rresp(w_rresp), .w_rlast(w_rlast),
        .w_rvalid(w_rvalid), .w_rready(w_rready),

        // observability outputs, mostly left unconnected
        .o_ac_rd(), .o_dw_data(), .o_dw_valid(), .o_dw_x(), .o_dw_tag(),
        .o_act_addr(), .o_act_re(o_act_re), .o_w_addr(), .o_w_re(o_w_re),
        .o_arr_busy(o_arr_busy), .o_ld_row(o_ld_row), .o_t1_pad(), .o_desc_rest(),

        // the depthwise address/clamp/first/last/tag inputs are produced by twn_dwseq inside the top

        .cyc_total(cyc_total), .cyc_array(cyc_array), .cyc_dw(cyc_dw),
        .cyc_stall_mem(cyc_stall_mem),
        .cyc_idle_pre(cyc_idle_pre), .cyc_idle_post(cyc_idle_post));

    // =====================================================================
    //  the DDR, as two windows at the board's addresses
    //
    //  Each window is sized exactly (the weight file; the two activation slots
    //  plus block 0's input tensor), so an access outside it is a reported
    //  error in tb_ddr_model.
    // =====================================================================
    tb_ddr_model #(.ADDR_W(40), .DATA_W(128),
                   .BASE(FM_ACT_BASE), .DEPTH(FM_ACT_WORDS), .NAME("act")) DDR_A (
        .clk(clk), .rstn(~rst),
        .araddr(a_araddr), .arlen(a_arlen), .arsize(a_arsize), .arburst(a_arburst),
        .arvalid(a_arvalid), .arready(a_arready),
        .rdata(a_rdata), .rresp(a_rresp), .rlast(a_rlast),
        .rvalid(a_rvalid), .rready(a_rready),
        .awaddr(a_awaddr), .awlen(a_awlen), .awsize(a_awsize), .awburst(a_awburst),
        .awvalid(a_awvalid), .awready(a_awready),
        .wdata(a_wdata), .wstrb(a_wstrb), .wlast(a_wlast),
        .wvalid(a_wvalid), .wready(a_wready),
        .bresp(a_bresp), .bvalid(a_bvalid), .bready(a_bready));

    tb_ddr_model #(.ADDR_W(40), .DATA_W(128),
                   .BASE(FM_W_BASE), .DEPTH(FM_W_WORDS), .NAME("weight")) DDR_W (
        .clk(clk), .rstn(~rst),
        .araddr(w_araddr), .arlen(w_arlen), .arsize(w_arsize), .arburst(w_arburst),
        .arvalid(w_arvalid), .arready(w_arready),
        .rdata(w_rdata), .rresp(w_rresp), .rlast(w_rlast),
        .rvalid(w_rvalid), .rready(w_rready),
        // HP1 is read-only in this design; the write channel is parked.
        .awaddr(40'd0), .awlen(8'd0), .awsize(3'd4), .awburst(2'b01),
        .awvalid(1'b0), .awready(),
        .wdata(128'd0), .wstrb(16'd0), .wlast(1'b0), .wvalid(1'b0), .wready(),
        .bresp(), .bvalid(), .bready(1'b0));
