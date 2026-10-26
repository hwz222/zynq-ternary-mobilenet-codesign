// ============================================================================
//  twn_fuse_layer.v -- IP-package wrapper around twn_fuse_top.
//
//  Vivado's IP packager infers AXI bus interfaces from port names. twn_fuse_top
//  names its ports s_*, a_*, w_*, ha_*, hwt_*, so this wrapper renames them to
//  the standard AXI interface names. It adds no state and changes no behaviour,
//  except the observation fold described below.
//
//    s_axi_control  AXI4-Lite slave, 16-bit addr, 32-bit data   <- s_*
//    m_axi_gmem0    AXI4 master, read+write, 128-bit, 40b addr  <- a_*    activations
//    m_axi_gmem1    AXI4 master, read-only,  128-bit, 40b addr  <- w_*    backbone weights
//    m_axi_gmem2    AXI4 master, read+write, 128-bit, 40b addr  <- ha_*   head activations
//    m_axi_gmem3    AXI4 master, read-only,  128-bit, 40b addr  <- hwt_*  head weights
//    ap_clk / ap_rst_n                                          <- clk / ~rst
//
//  Which Zynq HP port each master reaches is decided in vivado/build_bd_fuse.tcl:
//  gmem0 -> HP0, gmem1 -> HP1, gmem2 -> HP2, and gmem3 -> HP3 when FUSE_HP3_SPLIT=1
//  (otherwise gmem3 is merged with gmem2 onto HP2).
//
//  The head has two masters because its input reader and its weight reader run
//  at the same time and one AXI master interface has one read channel. Both
//  exist for either value of HD_PROBE; with HD_PROBE=0 twn_fuse_top drives them
//  idle.
//
//  Observation fold: twn_fuse_top exposes o_* outputs for signals that would
//  otherwise have no load. Inside a block design those would be dangling, the
//  tool would delete the logic feeding them, and utilization numbers would come
//  out too small. Every o_* output is therefore XOR-folded into obs[31:0], which the
//  block design takes to an external port. The fold is logic that is not part of
//  the accelerator; it lives in this module's own hierarchy, so
//  report_utilization -hierarchical shows it separately.
//  OBS_WIDE=0 leaves o_ac_rd (1024 bits) out of the fold.
// ============================================================================
`timescale 1ns/1ps
// Same HD_PROBE default as twn_fuse_top.v. Each file is its own compilation
// unit, so the macro must be defined here too; otherwise the parameter below
// would default to 0 and override the top's own default.
`ifdef HD_PROBE_ON
 `define HD_PROBE_DEFAULT 1
`else
 `define HD_PROBE_DEFAULT 0
`endif
`default_nettype none
module twn_fuse_layer #(
    // twn_fuse_top's AXI address ports are a fixed 40 bits wide.
    parameter integer C_M_AXI_ADDR_WIDTH = 40,
    // Must match twn_fuse_top's DW_LANES: it sizes o_dw_data.
    parameter integer DW_LANES  = 8,
    parameter integer OBS_WIDE  = 1,
    // 1: the head engine is built (twn_fuse_top's g_hd_probe); 0: no head.
    parameter integer HD_PROBE  = `HD_PROBE_DEFAULT
)(
    input  wire ap_clk,
    input  wire ap_rst_n,

    // ---------------- s_axi_control (AXI4-Lite) ----------------
    // 16-bit address, matching twn_fuse_top.
    input  wire [15:0]  s_axi_control_awaddr,
    input  wire         s_axi_control_awvalid,
    output wire         s_axi_control_awready,
    input  wire [31:0]  s_axi_control_wdata,
    input  wire [3:0]   s_axi_control_wstrb,
    input  wire         s_axi_control_wvalid,
    output wire         s_axi_control_wready,
    output wire [1:0]   s_axi_control_bresp,
    output wire         s_axi_control_bvalid,
    input  wire         s_axi_control_bready,
    input  wire [15:0]  s_axi_control_araddr,
    input  wire         s_axi_control_arvalid,
    output wire         s_axi_control_arready,
    output wire [31:0]  s_axi_control_rdata,
    output wire [1:0]   s_axi_control_rresp,
    output wire         s_axi_control_rvalid,
    input  wire         s_axi_control_rready,

    // ---------------- m_axi_gmem0 -- activations, read and write ----------------
    output wire [C_M_AXI_ADDR_WIDTH-1:0] m_axi_gmem0_araddr,
    output wire [7:0]   m_axi_gmem0_arlen,
    output wire [2:0]   m_axi_gmem0_arsize,
    output wire [1:0]   m_axi_gmem0_arburst,
    output wire [3:0]   m_axi_gmem0_arcache,
    output wire [2:0]   m_axi_gmem0_arprot,
    output wire         m_axi_gmem0_arvalid,
    input  wire         m_axi_gmem0_arready,
    input  wire [127:0] m_axi_gmem0_rdata,
    input  wire [1:0]   m_axi_gmem0_rresp,
    input  wire         m_axi_gmem0_rlast,
    input  wire         m_axi_gmem0_rvalid,
    output wire         m_axi_gmem0_rready,
    output wire [C_M_AXI_ADDR_WIDTH-1:0] m_axi_gmem0_awaddr,
    output wire [7:0]   m_axi_gmem0_awlen,
    output wire [2:0]   m_axi_gmem0_awsize,
    output wire [1:0]   m_axi_gmem0_awburst,
    output wire [3:0]   m_axi_gmem0_awcache,
    output wire [2:0]   m_axi_gmem0_awprot,
    output wire         m_axi_gmem0_awvalid,
    input  wire         m_axi_gmem0_awready,
    output wire [127:0] m_axi_gmem0_wdata,
    output wire [15:0]  m_axi_gmem0_wstrb,
    output wire         m_axi_gmem0_wlast,
    output wire         m_axi_gmem0_wvalid,
    input  wire         m_axi_gmem0_wready,
    input  wire [1:0]   m_axi_gmem0_bresp,
    input  wire         m_axi_gmem0_bvalid,
    output wire         m_axi_gmem0_bready,

    // ---------------- m_axi_gmem1 -- backbone weights, read-only ----------------
    output wire [C_M_AXI_ADDR_WIDTH-1:0] m_axi_gmem1_araddr,
    output wire [7:0]   m_axi_gmem1_arlen,
    output wire [2:0]   m_axi_gmem1_arsize,
    output wire [1:0]   m_axi_gmem1_arburst,
    output wire [3:0]   m_axi_gmem1_arcache,
    output wire [2:0]   m_axi_gmem1_arprot,
    output wire         m_axi_gmem1_arvalid,
    input  wire         m_axi_gmem1_arready,
    input  wire [127:0] m_axi_gmem1_rdata,
    input  wire [1:0]   m_axi_gmem1_rresp,
    input  wire         m_axi_gmem1_rlast,
    input  wire         m_axi_gmem1_rvalid,
    output wire         m_axi_gmem1_rready,

    // ------- m_axi_gmem2 -- head activations, read and write -------
    // Read: the backbone's final output tensor. Write: the head's output.
    output wire [C_M_AXI_ADDR_WIDTH-1:0] m_axi_gmem2_araddr,
    output wire [7:0]   m_axi_gmem2_arlen,
    output wire [2:0]   m_axi_gmem2_arsize,
    output wire [1:0]   m_axi_gmem2_arburst,
    output wire [3:0]   m_axi_gmem2_arcache,
    output wire [2:0]   m_axi_gmem2_arprot,
    output wire         m_axi_gmem2_arvalid,
    input  wire         m_axi_gmem2_arready,
    input  wire [127:0] m_axi_gmem2_rdata,
    input  wire [1:0]   m_axi_gmem2_rresp,
    input  wire         m_axi_gmem2_rlast,
    input  wire         m_axi_gmem2_rvalid,
    output wire         m_axi_gmem2_rready,
    output wire [C_M_AXI_ADDR_WIDTH-1:0] m_axi_gmem2_awaddr,
    output wire [7:0]   m_axi_gmem2_awlen,
    output wire [2:0]   m_axi_gmem2_awsize,
    output wire [1:0]   m_axi_gmem2_awburst,
    output wire [3:0]   m_axi_gmem2_awcache,
    output wire [2:0]   m_axi_gmem2_awprot,
    output wire         m_axi_gmem2_awvalid,
    input  wire         m_axi_gmem2_awready,
    output wire [127:0] m_axi_gmem2_wdata,
    output wire [15:0]  m_axi_gmem2_wstrb,
    output wire         m_axi_gmem2_wlast,
    output wire         m_axi_gmem2_wvalid,
    input  wire         m_axi_gmem2_wready,
    input  wire [1:0]   m_axi_gmem2_bresp,
    input  wire         m_axi_gmem2_bvalid,
    output wire         m_axi_gmem2_bready,

    // ---------------- m_axi_gmem3 -- head weights, read-only ----------------
    output wire [C_M_AXI_ADDR_WIDTH-1:0] m_axi_gmem3_araddr,
    output wire [7:0]   m_axi_gmem3_arlen,
    output wire [2:0]   m_axi_gmem3_arsize,
    output wire [1:0]   m_axi_gmem3_arburst,
    output wire [3:0]   m_axi_gmem3_arcache,
    output wire [2:0]   m_axi_gmem3_arprot,
    output wire         m_axi_gmem3_arvalid,
    input  wire         m_axi_gmem3_arready,
    input  wire [127:0] m_axi_gmem3_rdata,
    input  wire [1:0]   m_axi_gmem3_rresp,
    input  wire         m_axi_gmem3_rlast,
    input  wire         m_axi_gmem3_rvalid,
    output wire         m_axi_gmem3_rready,

    // ---------------- interrupt (level high) ----------------
    // Named "interrupt" so that package_fuse_ip.tcl declares it as the IP's
    // interrupt interface; the block design wires it to the PS's pl_ps_irq0.
    output wire         interrupt,

    // ---------------- observation ----------------
    output wire [31:0]  obs
);
    // ---- the accelerator ----
    wire         w_busy, w_done, w_wf_busy, w_wf_done;
    wire [1023:0]         o_ac_rd;
    wire [DW_LANES*8-1:0] o_dw_data;
    wire                  o_dw_valid;
    wire [7:0]            o_dw_x, o_dw_tag;
    wire [16:0]           o_act_addr;
    wire                  o_act_re;
    wire [17:0]           o_w_addr;
    wire                  o_w_re;
    wire                  o_arr_busy;
    wire [8:0]            o_ld_row;
    wire [2:0]            o_t1_pad;
    wire [26:0]           o_desc_rest;
    wire [31:0]           o_hd_probe;
    wire [31:0]  cyc_total, cyc_array, cyc_dw, cyc_stall_mem, cyc_idle_pre, cyc_idle_post;

    twn_fuse_top #(.DW_LANES(DW_LANES), .HD_PROBE(HD_PROBE)) U_TOP (
        .clk  (ap_clk),
        .rst  (~ap_rst_n),          // twn_fuse_top's reset is active high
        .busy (w_busy),
        .done (w_done),
        .irq  (interrupt),

        // AXI4-Lite control
        .s_awaddr (s_axi_control_awaddr),  .s_awvalid(s_axi_control_awvalid), .s_awready(s_axi_control_awready),
        .s_wdata  (s_axi_control_wdata),   .s_wstrb  (s_axi_control_wstrb),
        .s_wvalid (s_axi_control_wvalid),  .s_wready (s_axi_control_wready),
        .s_bresp  (s_axi_control_bresp),   .s_bvalid (s_axi_control_bvalid),  .s_bready (s_axi_control_bready),
        .s_araddr (s_axi_control_araddr),  .s_arvalid(s_axi_control_arvalid), .s_arready(s_axi_control_arready),
        .s_rdata  (s_axi_control_rdata),   .s_rresp  (s_axi_control_rresp),
        .s_rvalid (s_axi_control_rvalid),  .s_rready (s_axi_control_rready),

        // gmem0 read
        .a_araddr (m_axi_gmem0_araddr), .a_arlen  (m_axi_gmem0_arlen),  .a_arsize (m_axi_gmem0_arsize),
        .a_arburst(m_axi_gmem0_arburst),.a_arcache(m_axi_gmem0_arcache),.a_arprot (m_axi_gmem0_arprot),
        .a_arvalid(m_axi_gmem0_arvalid),.a_arready(m_axi_gmem0_arready),
        .a_rdata  (m_axi_gmem0_rdata),  .a_rresp  (m_axi_gmem0_rresp),  .a_rlast  (m_axi_gmem0_rlast),
        .a_rvalid (m_axi_gmem0_rvalid), .a_rready (m_axi_gmem0_rready),
        // gmem0 write
        .a_awaddr (m_axi_gmem0_awaddr), .a_awlen  (m_axi_gmem0_awlen),  .a_awsize (m_axi_gmem0_awsize),
        .a_awburst(m_axi_gmem0_awburst),.a_awcache(m_axi_gmem0_awcache),.a_awprot (m_axi_gmem0_awprot),
        .a_awvalid(m_axi_gmem0_awvalid),.a_awready(m_axi_gmem0_awready),
        .a_wdata  (m_axi_gmem0_wdata),  .a_wstrb  (m_axi_gmem0_wstrb),  .a_wlast  (m_axi_gmem0_wlast),
        .a_wvalid (m_axi_gmem0_wvalid), .a_wready (m_axi_gmem0_wready),
        .a_bresp  (m_axi_gmem0_bresp),  .a_bvalid (m_axi_gmem0_bvalid), .a_bready (m_axi_gmem0_bready),

        .wf_busy(w_wf_busy), .wf_done(w_wf_done),

        // gmem1 read (backbone weights)
        .w_araddr (m_axi_gmem1_araddr), .w_arlen  (m_axi_gmem1_arlen),  .w_arsize (m_axi_gmem1_arsize),
        .w_arburst(m_axi_gmem1_arburst),.w_arcache(m_axi_gmem1_arcache),.w_arprot (m_axi_gmem1_arprot),
        .w_arvalid(m_axi_gmem1_arvalid),.w_arready(m_axi_gmem1_arready),
        .w_rdata  (m_axi_gmem1_rdata),  .w_rresp  (m_axi_gmem1_rresp),  .w_rlast  (m_axi_gmem1_rlast),
        .w_rvalid (m_axi_gmem1_rvalid), .w_rready (m_axi_gmem1_rready),

        // gmem2 read (the head's input tensor)
        .ha_araddr (m_axi_gmem2_araddr), .ha_arlen  (m_axi_gmem2_arlen),  .ha_arsize (m_axi_gmem2_arsize),
        .ha_arburst(m_axi_gmem2_arburst),.ha_arcache(m_axi_gmem2_arcache),.ha_arprot (m_axi_gmem2_arprot),
        .ha_arvalid(m_axi_gmem2_arvalid),.ha_arready(m_axi_gmem2_arready),
        .ha_rdata  (m_axi_gmem2_rdata),  .ha_rresp  (m_axi_gmem2_rresp),  .ha_rlast  (m_axi_gmem2_rlast),
        .ha_rvalid (m_axi_gmem2_rvalid), .ha_rready (m_axi_gmem2_rready),
        // gmem2 write (the head's output tensor)
        .ha_awaddr (m_axi_gmem2_awaddr), .ha_awlen  (m_axi_gmem2_awlen),  .ha_awsize (m_axi_gmem2_awsize),
        .ha_awburst(m_axi_gmem2_awburst),.ha_awcache(m_axi_gmem2_awcache),.ha_awprot (m_axi_gmem2_awprot),
        .ha_awvalid(m_axi_gmem2_awvalid),.ha_awready(m_axi_gmem2_awready),
        .ha_wdata  (m_axi_gmem2_wdata),  .ha_wstrb  (m_axi_gmem2_wstrb),  .ha_wlast  (m_axi_gmem2_wlast),
        .ha_wvalid (m_axi_gmem2_wvalid), .ha_wready (m_axi_gmem2_wready),
        .ha_bresp  (m_axi_gmem2_bresp),  .ha_bvalid (m_axi_gmem2_bvalid), .ha_bready (m_axi_gmem2_bready),

        // gmem3 read (the head's weights)
        .hwt_araddr (m_axi_gmem3_araddr), .hwt_arlen  (m_axi_gmem3_arlen),  .hwt_arsize (m_axi_gmem3_arsize),
        .hwt_arburst(m_axi_gmem3_arburst),.hwt_arcache(m_axi_gmem3_arcache),.hwt_arprot (m_axi_gmem3_arprot),
        .hwt_arvalid(m_axi_gmem3_arvalid),.hwt_arready(m_axi_gmem3_arready),
        .hwt_rdata  (m_axi_gmem3_rdata),  .hwt_rresp  (m_axi_gmem3_rresp),  .hwt_rlast  (m_axi_gmem3_rlast),
        .hwt_rvalid (m_axi_gmem3_rvalid), .hwt_rready (m_axi_gmem3_rready),

        // observation taps
        .o_ac_rd(o_ac_rd), .o_dw_data(o_dw_data), .o_dw_valid(o_dw_valid),
        .o_dw_x(o_dw_x), .o_dw_tag(o_dw_tag),
        .o_act_addr(o_act_addr), .o_act_re(o_act_re),
        .o_w_addr(o_w_addr), .o_w_re(o_w_re),
        .o_arr_busy(o_arr_busy), .o_ld_row(o_ld_row), .o_t1_pad(o_t1_pad),
        .o_desc_rest(o_desc_rest), .o_hd_probe(o_hd_probe),

        // performance counters (also readable through the control registers)
        .cyc_total(cyc_total), .cyc_array(cyc_array), .cyc_dw(cyc_dw),
        .cyc_stall_mem(cyc_stall_mem),
        .cyc_idle_pre(cyc_idle_pre), .cyc_idle_post(cyc_idle_post)
    );

    // ---- observation fold: not part of the accelerator ----
    // Total width of obs_bus below: 1024 (o_ac_rd) + DW_LANES*8 (o_dw_data) +
    // 322 (all other taps, counters and status bits).
    localparam integer OBS_BITS = 1346 + DW_LANES*8;
    localparam integer LANE_W   = (OBS_BITS + 31) / 32;   // bits folded into each obs bit
    localparam integer OBS_PAD  = LANE_W * 32;

    wire [1023:0] ac_obs = (OBS_WIDE != 0) ? o_ac_rd : 1024'b0;

    wire [OBS_PAD-1:0] obs_bus = { {(OBS_PAD-OBS_BITS){1'b0}},
        ac_obs, o_dw_data, o_dw_valid, o_dw_x, o_dw_tag,
        o_act_addr, o_act_re, o_w_addr, o_w_re,
        o_arr_busy, o_ld_row, o_t1_pad, o_desc_rest, o_hd_probe,
        w_busy, w_done, w_wf_busy, w_wf_done,
        cyc_total, cyc_array, cyc_dw, cyc_stall_mem, cyc_idle_pre, cyc_idle_post };

    wire [31:0] obs_x;
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : g_fold
            assign obs_x[g] = ^obs_bus[g*LANE_W +: LANE_W];
        end
    endgenerate

    // Registered so the fold is not a timing path of its own.
    reg [31:0] obs_r;
    always @(posedge ap_clk) begin
        if (!ap_rst_n) obs_r <= 32'b0;
        else           obs_r <= obs_x;
    end
    assign obs = obs_r;
endmodule
`default_nettype wire
