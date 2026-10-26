`timescale 1ns/1ps
// ============================================================================
//  tb_hd_int.v -- the head as an integrated path: CSR head window ->
//  twn_hd_seq -> three AXI movers -> DDR model -> back, through twn_fuse_top.
//
//  twn_fuse_top is instantiated with HD_PROBE=1. The four head descriptors and
//  the 256 requantisation words are written through twn_csr (head window
//  0x0100.., requant window 0x0400..), the head is started with HD_CTRL[0], and
//  after done every byte op61..op64 wrote into the HP2 DDR model (DDR_HA) is
//  compared with the golden vectors from tools/hd_ref_export.py.
//  The three intermediate tensors and all outputs are X before the run, so
//  "never written" is counted apart from "written wrong".
//
//  Inputs (read by name from the work directory; sim/run_hd_int.ps1 copies them
//  from rtl/fuse/tb/hd_vec): hd_op61_in.hex, hd_op6[1-4]_w.hex,
//  hd_op6[1-4]_out.hex, hd_rq.hex, plus tb_fuse_map.vh (tools/gen_fuse_ddr.py).
//  Run: powershell -File rtl/fuse/sim/run_hd_int.ps1 [-Quick] [-Defines "BFM_RLAT=40,BFM_STALL=3"]
//  BFM_RLAT / BFM_STALL set the DDR model's read latency and back-pressure;
//  the model's values are printed on the BUS MODEL line.
//
//  Checks, each reported on its own line:
//    * stream wiring: the readers' s_ready and the engine's in_sr / w_sr are
//      driven (one net each), the writer's w_ready and the requant write enables
//      are driven
//    * HD_COMMIT[7:4] == 0xF and HD_RQ_STAT == 0x0000100F after programming
//    * the block descriptor window (16 writes) and the requant window (256 writes)
//      give 16 d_wr_en and 256 hd_rq_we pulses, i.e. no shared write port
//    * the table held in the engine at each operator's e_start equals that
//      operator's 32 golden entries (rq_m0 / rq_bias / rq_sh)
//    * all 434,176 output bytes of the four operators, and the writer's beat
//      count per operator against the descriptor
//    * DRAINRACE: measured residual write drain after e_done against the gap to
//      the next e_start (informational; see the line it prints)
//  Mode A re-issues op61's input 16 times; in_beats in the descriptor is one pass.
//
//  Break arms (see sim/run_hd_int.ps1):
//    -DHD_SEQ_BREAK_DRAIN  (RTL, twn_hd_seq) skip the wait for the write drain
//    -DHD_SEQ_BREAK_PASS   (RTL, twn_hd_seq) drop the mode-A input re-issue
//    -DHD_INT_SKIP_RQ      (testbench) do not program the requant window
//    -DHD_INT_BB2HD        (testbench) set A_BB2HD[0]=1 before start: op61 must
//                          read input slot 1 and op64 must write heatmap box B
// ============================================================================
// global timeout, in cycles (the clock period is 4 time units)
`ifndef HD_INT_CYCLES
`define HD_INT_CYCLES 6000000
`endif
// cycles without any AXI activity on HP2 before the run is called stalled
`ifndef HD_INT_IDLE
`define HD_INT_IDLE 200000
`endif
`default_nettype none
module tb_hd_int;

    `include "tb_fuse_map.vh"

    reg clk = 1'b0, rst = 1'b1;
    always #2 clk = ~clk;

    `include "tb_fuse_env.vh"

    // ---- the head's CSR window, 0x0100..0x013c, as in twn_csr.v ----
    localparam [15:0] H_CTRL      = 16'h0100,
                      H_COMMIT    = 16'h0104,
                      H_IN_LO     = 16'h0110, H_IN_HI  = 16'h0114,
                      H_W_LO      = 16'h0118, H_W_HI   = 16'h011c,
                      H_OUT_LO    = 16'h0120, H_OUT_HI = 16'h0124,
                      H_IN_BEATS  = 16'h0128,
                      H_W_BEATS   = 16'h012c,
                      H_OUT_BEATS = 16'h0130,
                      H_SHAPE     = 16'h0134,
                      H_FLAGS     = 16'h0138,
                      H_CLAMP     = 16'h013c;
    // HD_CTRL: write bit 0 = start, bit 2 = clear done; read bit 0 start,
    // bit 1 busy, bit 2 done
    localparam [31:0] HC_START = 32'h1, HC_CLR_DONE = 32'h4;
    localparam [31:0] HC_R_START = 32'h1, HC_R_BUSY = 32'h2, HC_R_DONE = 32'h4;

    // ---- the head's DDR map: two windows on HP2 ----
    // ha_* carries the boundary tensor in and the head's output out; hwt_* is
    // the read-only weight port. Windows are sized exactly so an access outside
    // a tensor is a reported region error. op61's input is loaded at +0x00000
    // (slot 0) and +0x10000 (slot 1): twn_hd_seq adds slot_off to op61's input
    // base only and hd_slot flips on every hdseq_done.
    localparam [39:0] HA_BASE = 40'h00_7000_0000;
    localparam [39:0] HW_BASE = 40'h00_7800_0000;

    localparam integer HA_IN61_W  = 32'h00000 / 16;   //  1280 beats  op61 in, slot 0
    localparam integer HA_IN61S1_W= 32'h10000 / 16;   //  1280 beats  op61 in, slot 1
    localparam integer HA_OUT61_W = 32'h20000 / 16;   //   512 beats  = op62 in
    localparam integer HA_OUT62_W = 32'h30000 / 16;   //  2048 beats  = op63 in
    localparam integer HA_OUT63_W = 32'h40000 / 16;   //  8192 beats  = op64 in
    localparam integer HA_OUT64_W = 32'h80000 / 16;   // 16384 beats  the heatmap
`ifdef HD_INT_BB2HD
    // HD_INT_BB2HD: with A_BB2HD[0] = 1 and bb_par = 0 out of reset the head
    // takes hd_sel = 1, so op61 reads input slot 1 and op64 writes heatmap box B
    // at +0x40000 past its committed base. Slot 0 is left X and the window is
    // one box larger.
    localparam integer HA_WORDS   = 32'h100000 / 16;  // 65536 words = 1 MB
    localparam integer HA_OUT64B_W= 32'hC0000 / 16;   // heatmap box B
`else
    localparam integer HA_WORDS   = 32'hC0000 / 16;   // 49152 words = 768 KB
`endif

    localparam integer HW_W61_W = 32'h00000 / 16;     // 10240 beats
    localparam integer HW_W62_W = 32'h28000 / 16;     //  1024 beats
    localparam integer HW_W63_W = 32'h30000 / 16;     //  1024 beats
    localparam integer HW_W64_W = 32'h38000 / 16;     //    32 beats
    localparam integer HW_WORDS = 32'h40000 / 16;     // 16384 words = 256 KB

    // ---- the four operators, from hd_vec_manifest.json ----
    // op64 declares OC=16 (the manifest's oc_engine), not the model's 14: type 4
    // emits OC/4 beats per pixel, so OC=14 would drop two channels silently.
    integer P_IC[0:3], P_OC[0:3], P_H[0:3], P_W[0:3], P_OH[0:3], P_OW[0:3];
    integer P_T4[0:3], P_SLICE[0:3], P_RELU[0:3], P_LO[0:3], P_HI[0:3];
    integer P_INB[0:3], P_PASS[0:3], P_WB[0:3], P_OUTB[0:3], P_RQN[0:3];
    integer P_INW[0:3], P_WW[0:3], P_OUTW[0:3];       // word offsets in the models
    reg [39:0] P_INBASE[0:3], P_WBASE[0:3], P_OUTBASE[0:3];

    initial begin
        //          op61      op62      op63      op64
        P_IC[0]=320;   P_IC[1]=32;   P_IC[2]=32;   P_IC[3]=32;
        P_OC[0]=32;    P_OC[1]=32;   P_OC[2]=32;   P_OC[3]=16;
        P_H [0]=8;     P_H [1]=16;   P_H [2]=32;   P_H [3]=64;
        P_W [0]=8;     P_W [1]=16;   P_W [2]=32;   P_W [3]=64;
        P_OH[0]=16;    P_OH[1]=32;   P_OH[2]=64;   P_OH[3]=64;
        P_OW[0]=16;    P_OW[1]=32;   P_OW[2]=64;   P_OW[3]=64;
        P_T4[0]=0;     P_T4[1]=0;    P_T4[2]=0;    P_T4[3]=1;
        P_SLICE[0]=1;  P_SLICE[1]=0; P_SLICE[2]=0; P_SLICE[3]=0;
        P_RELU[0]=1;   P_RELU[1]=1;  P_RELU[2]=1;  P_RELU[3]=0;
        P_LO[0]=0;     P_LO[1]=0;    P_LO[2]=0;    P_LO[3]=0;
        P_HI[0]=127;   P_HI[1]=127;  P_HI[2]=127;  P_HI[3]=0;
        // in_beats is one pass; the sequencer restarts the input reader per slice
        P_INB [0]=1280;  P_INB [1]=512;  P_INB [2]=2048; P_INB [3]=8192;
        P_PASS[0]=16;    P_PASS[1]=1;    P_PASS[2]=1;    P_PASS[3]=1;
        P_WB  [0]=10240; P_WB [1]=1024;  P_WB [2]=1024;  P_WB [3]=32;
        P_OUTB[0]=512;   P_OUTB[1]=2048; P_OUTB[2]=8192; P_OUTB[3]=16384;
        P_RQN [0]=32;    P_RQN[1]=32;    P_RQN[2]=32;    P_RQN[3]=0;

        P_INW [0]=HA_IN61_W;  P_INW [1]=HA_OUT61_W; P_INW [2]=HA_OUT62_W; P_INW [3]=HA_OUT63_W;
        P_WW  [0]=HW_W61_W;   P_WW  [1]=HW_W62_W;   P_WW  [2]=HW_W63_W;   P_WW  [3]=HW_W64_W;
        P_OUTW[0]=HA_OUT61_W; P_OUTW[1]=HA_OUT62_W; P_OUTW[2]=HA_OUT63_W; P_OUTW[3]=HA_OUT64_W;
`ifdef HD_INT_BB2HD
        P_OUTW[3]=HA_OUT64B_W;          // the descriptor still says box A
`endif

        P_INBASE [0]=HA_BASE+40'h00000; P_INBASE [1]=HA_BASE+40'h20000;
        P_INBASE [2]=HA_BASE+40'h30000; P_INBASE [3]=HA_BASE+40'h40000;
        P_WBASE  [0]=HW_BASE+40'h00000; P_WBASE  [1]=HW_BASE+40'h28000;
        P_WBASE  [2]=HW_BASE+40'h30000; P_WBASE  [3]=HW_BASE+40'h38000;
        P_OUTBASE[0]=HA_BASE+40'h20000; P_OUTBASE[1]=HA_BASE+40'h30000;
        P_OUTBASE[2]=HA_BASE+40'h40000; P_OUTBASE[3]=HA_BASE+40'h80000;
    end

    // =====================================================================
    //  the DUT -- the whole fused top, with the head built
    // =====================================================================
    wire        busy, done, wf_busy, wf_done;

    wire [39:0]  a_araddr;  wire [7:0] a_arlen;  wire [2:0] a_arsize;
    wire [1:0]   a_arburst; wire [3:0] a_arcache; wire [2:0] a_arprot;
    wire         a_arvalid, a_arready;
    wire [127:0] a_rdata;   wire [1:0] a_rresp;  wire a_rlast, a_rvalid, a_rready;
    wire [39:0]  a_awaddr;  wire [7:0] a_awlen;  wire [2:0] a_awsize;
    wire [1:0]   a_awburst; wire [3:0] a_awcache; wire [2:0] a_awprot;
    wire         a_awvalid, a_awready;
    wire [127:0] a_wdata;   wire [15:0] a_wstrb; wire a_wlast, a_wvalid, a_wready;
    wire [1:0]   a_bresp;   wire a_bvalid, a_bready;

    wire [39:0]  w_araddr;  wire [7:0] w_arlen;  wire [2:0] w_arsize;
    wire [1:0]   w_arburst; wire [3:0] w_arcache; wire [2:0] w_arprot;
    wire         w_arvalid, w_arready;
    wire [127:0] w_rdata;   wire [1:0] w_rresp;  wire w_rlast, w_rvalid, w_rready;

    // HP2 group A -- the head's boundary-tensor reader and its output writer
    wire [39:0]  ha_araddr;  wire [7:0] ha_arlen;  wire [2:0] ha_arsize;
    wire [1:0]   ha_arburst; wire [3:0] ha_arcache; wire [2:0] ha_arprot;
    wire         ha_arvalid, ha_arready;
    wire [127:0] ha_rdata;   wire [1:0] ha_rresp;  wire ha_rlast, ha_rvalid, ha_rready;
    wire [39:0]  ha_awaddr;  wire [7:0] ha_awlen;  wire [2:0] ha_awsize;
    wire [1:0]   ha_awburst; wire [3:0] ha_awcache; wire [2:0] ha_awprot;
    wire         ha_awvalid, ha_awready;
    wire [127:0] ha_wdata;   wire [15:0] ha_wstrb; wire ha_wlast, ha_wvalid, ha_wready;
    wire [1:0]   ha_bresp;   wire ha_bvalid, ha_bready;

    // HP2 group B -- the head's weight reader
    wire [39:0]  hwt_araddr;  wire [7:0] hwt_arlen;  wire [2:0] hwt_arsize;
    wire [1:0]   hwt_arburst; wire [3:0] hwt_arcache; wire [2:0] hwt_arprot;
    wire         hwt_arvalid, hwt_arready;
    wire [127:0] hwt_rdata;   wire [1:0] hwt_rresp;  wire hwt_rlast, hwt_rvalid, hwt_rready;

    wire         o_arr_busy, o_act_re, o_w_re;
    wire [8:0]   o_ld_row;
    wire [31:0]  o_hd_probe;
    wire [31:0]  cyc_total, cyc_array, cyc_dw, cyc_stall_mem, cyc_idle_pre, cyc_idle_post;

    // HD_PROBE is set here, not by a command-line define, so this test cannot
    // run against a design without a head.
    twn_fuse_top #(.HD_PROBE(1)) DUT (
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

        .ha_araddr(ha_araddr), .ha_arlen(ha_arlen), .ha_arsize(ha_arsize),
        .ha_arburst(ha_arburst), .ha_arcache(ha_arcache), .ha_arprot(ha_arprot),
        .ha_arvalid(ha_arvalid), .ha_arready(ha_arready),
        .ha_rdata(ha_rdata), .ha_rresp(ha_rresp), .ha_rlast(ha_rlast),
        .ha_rvalid(ha_rvalid), .ha_rready(ha_rready),
        .ha_awaddr(ha_awaddr), .ha_awlen(ha_awlen), .ha_awsize(ha_awsize),
        .ha_awburst(ha_awburst), .ha_awcache(ha_awcache), .ha_awprot(ha_awprot),
        .ha_awvalid(ha_awvalid), .ha_awready(ha_awready),
        .ha_wdata(ha_wdata), .ha_wstrb(ha_wstrb), .ha_wlast(ha_wlast),
        .ha_wvalid(ha_wvalid), .ha_wready(ha_wready),
        .ha_bresp(ha_bresp), .ha_bvalid(ha_bvalid), .ha_bready(ha_bready),

        .hwt_araddr(hwt_araddr), .hwt_arlen(hwt_arlen), .hwt_arsize(hwt_arsize),
        .hwt_arburst(hwt_arburst), .hwt_arcache(hwt_arcache), .hwt_arprot(hwt_arprot),
        .hwt_arvalid(hwt_arvalid), .hwt_arready(hwt_arready),
        .hwt_rdata(hwt_rdata), .hwt_rresp(hwt_rresp), .hwt_rlast(hwt_rlast),
        .hwt_rvalid(hwt_rvalid), .hwt_rready(hwt_rready),

        .o_ac_rd(), .o_dw_data(), .o_dw_valid(), .o_dw_x(), .o_dw_tag(),
        .o_act_addr(), .o_act_re(o_act_re), .o_w_addr(), .o_w_re(o_w_re),
        .o_arr_busy(o_arr_busy), .o_ld_row(o_ld_row), .o_t1_pad(), .o_desc_rest(),
        .o_hd_probe(o_hd_probe),

        .cyc_total(cyc_total), .cyc_array(cyc_array), .cyc_dw(cyc_dw),
        .cyc_stall_mem(cyc_stall_mem),
        .cyc_idle_pre(cyc_idle_pre), .cyc_idle_post(cyc_idle_post));

    // ---- the backbone's two windows: the backbone is never started here, so
    // they must see no traffic ----
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
        .awaddr(40'd0), .awlen(8'd0), .awsize(3'd4), .awburst(2'b01),
        .awvalid(1'b0), .awready(),
        .wdata(128'd0), .wstrb(16'd0), .wlast(1'b0), .wvalid(1'b0), .wready(),
        .bresp(), .bvalid(), .bready(1'b0));

    // ---- HP2: the two windows the head uses ----
    tb_ddr_model #(.ADDR_W(40), .DATA_W(128),
                   .BASE(HA_BASE), .DEPTH(HA_WORDS), .NAME("hd_act")) DDR_HA (
        .clk(clk), .rstn(~rst),
        .araddr(ha_araddr), .arlen(ha_arlen), .arsize(ha_arsize), .arburst(ha_arburst),
        .arvalid(ha_arvalid), .arready(ha_arready),
        .rdata(ha_rdata), .rresp(ha_rresp), .rlast(ha_rlast),
        .rvalid(ha_rvalid), .rready(ha_rready),
        .awaddr(ha_awaddr), .awlen(ha_awlen), .awsize(ha_awsize), .awburst(ha_awburst),
        .awvalid(ha_awvalid), .awready(ha_awready),
        .wdata(ha_wdata), .wstrb(ha_wstrb), .wlast(ha_wlast),
        .wvalid(ha_wvalid), .wready(ha_wready),
        .bresp(ha_bresp), .bvalid(ha_bvalid), .bready(ha_bready));

    tb_ddr_model #(.ADDR_W(40), .DATA_W(128),
                   .BASE(HW_BASE), .DEPTH(HW_WORDS), .NAME("hd_w")) DDR_HW (
        .clk(clk), .rstn(~rst),
        .araddr(hwt_araddr), .arlen(hwt_arlen), .arsize(hwt_arsize), .arburst(hwt_arburst),
        .arvalid(hwt_arvalid), .arready(hwt_arready),
        .rdata(hwt_rdata), .rresp(hwt_rresp), .rlast(hwt_rlast),
        .rvalid(hwt_rvalid), .rready(hwt_rready),
        .awaddr(40'd0), .awlen(8'd0), .awsize(3'd4), .awburst(2'b01),
        .awvalid(1'b0), .awready(),
        .wdata(128'd0), .wstrb(16'd0), .wlast(1'b0), .wvalid(1'b0), .wready(),
        .bresp(), .bvalid(), .bready(1'b0));

    // =====================================================================
    //  storage for the golden vectors
    // =====================================================================
    localparam OMAX = 16384;
    reg [127:0] gold [0:OMAX-1];
    reg [127:0] rqrom[0:127];              // 4 ops x 32 oc, from hd_rq.hex

    integer errors, structural;
    integer i, j, k, q;

    // =====================================================================
    //  AXI activity monitors
    // =====================================================================
    integer n_ha_r, n_ha_w, n_hw_r, n_ha_ar, n_ha_aw, n_hw_ar;
    integer op_wbeats[0:3];
    reg [1:0] mon_op;
    always @(posedge clk) if (!rst) begin
        if (ha_arvalid  && ha_arready)  n_ha_ar <= n_ha_ar + 1;
        if (ha_awvalid  && ha_awready)  n_ha_aw <= n_ha_aw + 1;
        if (hwt_arvalid && hwt_arready) n_hw_ar <= n_hw_ar + 1;
        if (ha_rvalid   && ha_rready)   n_ha_r  <= n_ha_r + 1;
        if (hwt_rvalid  && hwt_rready)  n_hw_r  <= n_hw_r + 1;
        if (ha_wvalid   && ha_wready) begin
            n_ha_w <= n_ha_w + 1;
            op_wbeats[mon_op] <= op_wbeats[mon_op] + 1;
        end
    end
    // the operator the sequencer is on
    always @(posedge clk) mon_op <= DUT.g_hd_probe.HSEQ.op;

    // =====================================================================
    //  stall detector: no AXI activity for HD_INT_IDLE cycles prints the
    //  movers' and the sequencer's state (dump_state)
    // =====================================================================
    reg [31:0] cyc, idle_cnt;
    reg        running, stalled;
    initial begin cyc = 0; idle_cnt = 0; running = 0; stalled = 0; end

    // =====================================================================
    //  requantisation table held in the engine at each operator's e_start,
    //  compared with that operator's 32 golden entries from hd_rq.hex
    //  ({m0[31:0], bias[63:0], sh[31:0]} per entry)
    // =====================================================================
    integer rq_seen [0:3];
    integer rq_bad_m0 [0:3], rq_bad_bias [0:3], rq_bad_sh [0:3];
    integer rqi, rqbase, rqop;
    reg signed [31:0] wm0; reg signed [63:0] wbias; reg [5:0] wsh;
    always @(posedge clk) if (!rst && DUT.g_hd_probe.hs_e_start) begin
        rqop   = DUT.g_hd_probe.HSEQ.op;
        rqbase = rqop * 32;
        rq_seen[rqop] = rq_seen[rqop] + 1;
        for (rqi = 0; rqi < 32; rqi = rqi + 1) begin
            wm0   = $signed(rqrom[rqbase + rqi][127:96]);
            wbias = $signed(rqrom[rqbase + rqi][95:32]);
            wsh   = rqrom[rqbase + rqi][5:0];
            // compared at the widths of twn_hd_compute's write port
            // (m0_wd[17:0], bias_wd[39:0], sh_wd[5:0])
            if (DUT.g_hd_probe.HDP.rq_m0  [rqi] !== wm0[17:0])
                rq_bad_m0[rqop] = rq_bad_m0[rqop] + 1;
            if (DUT.g_hd_probe.HDP.rq_bias[rqi] !== wbias[39:0])
                rq_bad_bias[rqop] = rq_bad_bias[rqop] + 1;
            if (DUT.g_hd_probe.HDP.rq_sh  [rqi] !== wsh)
                rq_bad_sh[rqop] = rq_bad_sh[rqop] + 1;
        end
    end

    // =====================================================================
    //  strobe counts for the block descriptor window (d_wr_en) and the head's
    //  requantisation window (hd_rq_we); compared in program_rq
    // =====================================================================
    integer n_dwr = 0, n_rqwe = 0;
    always @(posedge clk) if (!rst) begin
        if (DUT.CSR.d_wr_en)  n_dwr  = n_dwr + 1;
        if (DUT.CSR.hd_rq_we) n_rqwe = n_rqwe + 1;
    end

    // =====================================================================
    //  write-drain race: twn_hd_seq's S_DRAIN waits for the writer because
    //  e_done means the engine emitted its last beat, not that it reached DDR.
    //    drain_cyc  hdp_done -> hwr_done, per operator
    //    gap_cyc    hdp_done -> next operator's e_start
    //  The race can only matter when drain exceeds gap; the DRAINRACE line in the
    //  report says which regime this run was in. The directed test of the drain
    //  is in tb_hd_seq.v.
    // =====================================================================
    integer drain_cyc [0:3];
    integer gap_cyc   [0:3];
    integer ed_t, ed_op;
    reg     ed_valid = 1'b0, dr_pend = 1'b0;
    always @(posedge clk) if (!rst) begin
        if (DUT.g_hd_probe.hdp_done) begin
            ed_t = cyc; ed_op = DUT.g_hd_probe.HSEQ.op;
            ed_valid <= 1'b1; dr_pend <= 1'b1;
        end else begin
            if (dr_pend && DUT.g_hd_probe.hwr_done) begin
                drain_cyc[ed_op] = cyc - ed_t; dr_pend <= 1'b0;
            end
            if (ed_valid && DUT.g_hd_probe.hs_e_start) begin
                gap_cyc[DUT.g_hd_probe.HSEQ.op] = cyc - ed_t; ed_valid <= 1'b0;
            end
        end
    end

    task dump_state;
        begin
            $display("   sequencer  st=%0d op=%0d busy=%b done=%b  hd_slot=%b",
                     DUT.g_hd_probe.HSEQ.st, DUT.g_hd_probe.HSEQ.op,
                     DUT.hdseq_busy, DUT.hdseq_done,
                     DUT.g_hd_probe.hd_slot);
            $display("   pass_left  %0d   (mode A re-issues the input reader)",
                     DUT.g_hd_probe.HSEQ.pass_left);
            $display("   in  mover  busy=%b done=%b   AR %0d bursts, %0d R beats",
                     DUT.g_hd_probe.hrd_busy, DUT.g_hd_probe.hrd_done, n_ha_ar, n_ha_r);
            $display("   w   mover  busy=%b done=%b   AR %0d bursts, %0d R beats",
                     DUT.g_hd_probe.hwf_busy, DUT.g_hd_probe.hwf_done, n_hw_ar, n_hw_r);
            $display("   out mover  busy=%b done=%b   AW %0d bursts, %0d W beats",
                     DUT.g_hd_probe.hwr_busy, DUT.g_hd_probe.hwr_done, n_ha_aw, n_ha_w);
            // twn_axi_rd's s_ready is an input and twn_hd_compute's in_sr an
            // output: they must be one net
            $display("   in stream  mover drives sv=%b, engine's in_sr (== reader s_ready)=%b",
                     DUT.g_hd_probe.hin_sv, DUT.g_hd_probe.hdp_in_sr);
            $display("   w  stream  mover drives sv=%b, engine's w_sr  (== reader s_ready)=%b",
                     DUT.g_hd_probe.hw_sv, DUT.g_hd_probe.hdp_w_sr);
            $display("   out stream engine drives sv=%b, writer drives ready=%b",
                     DUT.g_hd_probe.hdp_out_sv, DUT.g_hd_probe.hdp_out_sr_w);
            $display("   requant    S_RQ replay: m0_we=%b bias_we=%b sh_we=%b wa=%0d",
                     DUT.g_hd_probe.hs_m0_we, DUT.g_hd_probe.hs_bias_we,
                     DUT.g_hd_probe.hs_sh_we, DUT.g_hd_probe.hs_rq_wa);
        end
    endtask

    always @(posedge clk) begin
        cyc <= cyc + 32'd1;
        if (!running) idle_cnt <= 32'd0;
        else if (rst || (ha_rvalid && ha_rready) || (hwt_rvalid && hwt_rready) ||
                 (ha_wvalid && ha_wready) || ha_arvalid || ha_awvalid || hwt_arvalid ||
                 DUT.hdseq_done)
            idle_cnt <= 32'd0;
        else
            idle_cnt <= idle_cnt + 32'd1;
        // a stall raises a flag; the poll loop gives up and the comparison still
        // runs over whatever reached DDR (unwritten bytes are counted as such)
        if (idle_cnt == `HD_INT_IDLE && !stalled) begin
            stalled <= 1'b1;
            $display("");
            $display("FAIL tb_hd_int: STALLED -- %0d cycles with no AXI activity on HP2",
                     idle_cnt);
            dump_state;
        end
    end

    // =====================================================================
    //  loading
    // =====================================================================
    task wipe_gold;
        begin for (q = 0; q < OMAX; q = q + 1) gold[q] = {128{1'bx}}; end
    endtask

    task load_or_die(input [64*8:1] nm, input [127:0] first, input [127:0] last);
        begin
            if ((^first === 1'bx) || (^last === 1'bx)) begin
                $display("FAIL tb_hd_int: %0s did not load (first=%032x last=%032x)", nm, first, last);
                $display("   run tools/hd_ref_export.py, and run this gate from the directory holding the .hex files");
                $finish;
            end
        end
    endtask

    // The head's DDR image: op61's input and the four weight tensors. The three
    // intermediate tensors are left X: the head has to produce them.
    task load_head_ddr;
        begin
            for (q = 0; q < HA_WORDS; q = q + 1) DDR_HA.mem[q] = {128{1'bx}};
            for (q = 0; q < HW_WORDS; q = q + 1) DDR_HW.mem[q] = {128{1'bx}};

`ifndef HD_INT_BB2HD
            $readmemh("hd_op61_in.hex", DDR_HA.mem, HA_IN61_W);
`endif
            $readmemh("hd_op61_in.hex", DDR_HA.mem, HA_IN61S1_W);
            $readmemh("hd_op61_w.hex",  DDR_HW.mem, HW_W61_W);
            $readmemh("hd_op62_w.hex",  DDR_HW.mem, HW_W62_W);
            $readmemh("hd_op63_w.hex",  DDR_HW.mem, HW_W63_W);
            $readmemh("hd_op64_w.hex",  DDR_HW.mem, HW_W64_W);

            load_or_die("op61 input", DDR_HA.mem[HA_IN61S1_W], DDR_HA.mem[HA_IN61S1_W + 1279]);
            load_or_die("op61 weights", DDR_HW.mem[HW_W61_W], DDR_HW.mem[HW_W61_W + 10239]);
            load_or_die("op62 weights", DDR_HW.mem[HW_W62_W], DDR_HW.mem[HW_W62_W + 1023]);
            load_or_die("op63 weights", DDR_HW.mem[HW_W63_W], DDR_HW.mem[HW_W63_W + 1023]);
            load_or_die("op64 weights", DDR_HW.mem[HW_W64_W], DDR_HW.mem[HW_W64_W + 31]);
            $display("  head DDR loaded: op61 input + four weight tensors");
            $display("    the three intermediate tensors are left X ON PURPOSE -- they are");
            $display("    what the head must produce, and X propagates if it does not.");
        end
    endtask

    // =====================================================================
    //  the descriptor window
    // =====================================================================
    task hd_desc(input integer idx);
        begin
            lite_wr(H_IN_LO,     P_INBASE[idx][31:0]);
            lite_wr(H_IN_HI,     {24'd0, P_INBASE[idx][39:32]});
            lite_wr(H_W_LO,      P_WBASE[idx][31:0]);
            lite_wr(H_W_HI,      {24'd0, P_WBASE[idx][39:32]});
            lite_wr(H_OUT_LO,    P_OUTBASE[idx][31:0]);
            lite_wr(H_OUT_HI,    {24'd0, P_OUTBASE[idx][39:32]});
            lite_wr(H_IN_BEATS,  P_INB[idx][31:0]);
            lite_wr(H_W_BEATS,   P_WB[idx][31:0]);
            lite_wr(H_OUT_BEATS, P_OUTB[idx][31:0]);
            lite_wr(H_SHAPE,     {3'd0, P_W[idx][6:0], P_H[idx][6:0],
                                        P_OC[idx][5:0], P_IC[idx][8:0]});
            lite_wr(H_FLAGS,     {29'd0, P_RELU[idx][0], P_SLICE[idx][0], P_T4[idx][0]});
            lite_wr(H_CLAMP,     {P_HI[idx][15:0], P_LO[idx][15:0]});
            // the commit is the only pulse in the window and names the operator;
            // fields not rewritten carry over to the next operator
            lite_wr(H_COMMIT,    {30'd0, idx[1:0]});
        end
    endtask

    // Read back through the staging registers (not the committed entry: twn_hd_seq
    // has no read port on its file), so this checks the AXI-Lite write path only.
    task check_stage(input integer idx);
        reg [31:0] v;
        begin
            lite_rd(H_SHAPE, v);
            if (v !== {3'd0, P_W[idx][6:0], P_H[idx][6:0], P_OC[idx][5:0], P_IC[idx][8:0]}) begin
                $display("FAIL op%0d: HD_SHAPE reads back %08h, wrote %08h", 61+idx, v,
                         {3'd0, P_W[idx][6:0], P_H[idx][6:0], P_OC[idx][5:0], P_IC[idx][8:0]});
                errors = errors + 1;
            end
            lite_rd(H_OUT_BEATS, v);
            if (v[23:0] !== P_OUTB[idx][23:0]) begin
                $display("FAIL op%0d: HD_OUT_BEATS reads back %0d, wrote %0d",
                         61+idx, v[23:0], P_OUTB[idx]);
                errors = errors + 1;
            end
        end
    endtask

    // =====================================================================
    //  requantisation tables, programmed through twn_csr's window at 0x0400:
    //  4 operators x 32 entries, two 32-bit words per entry at {op, oc, half}.
    //  The 16 block-descriptor writes before them are there to show the two
    //  windows do not disturb each other.
    // =====================================================================
    localparam [15:0] H_RQ_BASE = 16'h0400;    // twn_csr A_HD_RQ_BASE
    localparam [15:0] H_RQ_STAT = 16'h0108;    // twn_csr A_HD_RQ_STAT

    task program_rq;
        reg signed [31:0] gm0;
        reg signed [63:0] gbias;
        reg [5:0]         gsh;
        reg [31:0]        v;
        integer p, c, oob;
        begin
            $readmemh("hd_rq.hex", rqrom);
            if (^rqrom[0] === 1'bx) begin
                $display("FAIL tb_hd_int: hd_rq.hex did not load"); $finish;
            end

            // ---- the block table's window first ----
            for (i = 0; i < 16; i = i + 1)
                lite_wr(F_DESC_BASE + i * 4, 32'hA5A50000 + i);
            repeat (4) @(posedge clk);
            if (n_rqwe != 0) begin
                $display("  FAIL structural: %0d BLOCK descriptor writes reached the head's",
                         n_rqwe);
                $display("    requantisation table. The two windows share a port -- which is the");
                $display("    defect this window was added to remove, in the direction where");
                $display("    BOOTING THE BLOCK TABLE scribbles the head's.");
                structural = structural + 1;
            end

            // ---- the four requantisation tables ----
            oob = 0;
            for (p = 0; p < 4; p = p + 1)
                for (c = 0; c < 32; c = c + 1) begin
                    gm0   = $signed(rqrom[p*32 + c][127:96]);
                    gbias = $signed(rqrom[p*32 + c][95:32]);
                    gsh   = rqrom[p*32 + c][5:0];
                    // the engine's store is 18 / 40 / 6 bits wide; a golden value
                    // that does not fit is counted here
                    if (gm0   !== $signed({{14{gm0[17]}},   gm0[17:0]}))   oob = oob + 1;
                    if (gbias !== $signed({{24{gbias[39]}}, gbias[39:0]})) oob = oob + 1;
                    if (rqrom[p*32 + c][31:6] != 26'd0)                    oob = oob + 1;
                    lite_wr(H_RQ_BASE + (p*64 + c*2 + 0) * 4, gbias[31:0]);
                    lite_wr(H_RQ_BASE + (p*64 + c*2 + 1) * 4,
                            {gsh, gm0[17:0], gbias[39:32]});
                end
            repeat (4) @(posedge clk);
            if (oob != 0) begin
                $display("  FAIL: %0d golden requant fields do not fit the engine's widths", oob);
                errors = errors + 1;
            end

            // ---- the two strobes, counted ----
            $display("  window isolation: %0d block-table writes -> %0d d_wr_en pulses;",
                     16, n_dwr);
            $display("                    %0d requant writes    -> %0d hd_rq_we pulses",
                     256, n_rqwe);
            if (n_dwr != 16 || n_rqwe != 256) begin
                $display("  FAIL structural: the block descriptor window and the requant window");
                $display("    share a write port. 16 and 256 writes must produce 16 and 256");
                $display("    pulses; anything else means one window's writes reach the other's");
                $display("    table, which is how booting the block table used to overwrite the");
                $display("    head's requantisation entries.");
                structural = structural + 1;
            end

            // ---- evidence readable over AXI-Lite ----
            lite_rd(H_RQ_STAT, v);
            $display("  HD_RQ_STAT reads %08h -- %0d words written, per-operator mask %0h",
                     v, v[12:4], v[3:0]);
            if (v !== 32'h0000_100F) begin
                $display("  FAIL: HD_RQ_STAT must read 0x0000100F after a full boot (256 words,");
                $display("    all four operators). It is the ONLY evidence the board has that");
                $display("    the table the head is about to use is not partly somebody else's.");
                errors = errors + 1;
            end
        end
    endtask

    // =====================================================================
    //  stream wiring, checked as values at reset (an undriven wire reads Z):
    //  twn_axi_rd's s_ready (input) and twn_hd_compute's in_sr / w_sr (outputs)
    //  must be one net, else rready never reflects the engine.
    // =====================================================================
    task check_stream_wiring;
        begin
            if (DUT.g_hd_probe.hdp_in_sr === 1'bz || DUT.g_hd_probe.hdp_in_sr === 1'bx) begin
                $display("  FAIL structural: the input reader's s_ready is UNDRIVEN (reads %b).",
                         DUT.g_hd_probe.hdp_in_sr);
                $display("    HRD's .s_ready and the engine's .in_sr must be ONE net. Two nets");
                $display("    leaves the reader's s_ready with no driver, so its rready is never");
                $display("    asserted and the head moves zero bytes.");
                structural = structural + 1;
            end
            if (DUT.g_hd_probe.hdp_w_sr === 1'bz || DUT.g_hd_probe.hdp_w_sr === 1'bx) begin
                $display("  FAIL structural: the weight reader's s_ready is UNDRIVEN (reads %b).",
                         DUT.g_hd_probe.hdp_w_sr);
                $display("    Same defect on the weight path: HWF .s_ready and the engine .w_sr.");
                structural = structural + 1;
            end
            if (DUT.g_hd_probe.hdp_out_sr_w === 1'bz) begin
                $display("  FAIL structural: the writer's w_ready is UNDRIVEN.");
                structural = structural + 1;
            end else
                $display("  output stream: engine out_sv -> writer w_valid, writer w_ready -> engine out_sr  OK");
            // the requant replay's write enables must be driven
            if (DUT.g_hd_probe.hs_m0_we === 1'bz || DUT.g_hd_probe.hs_m0_we === 1'bx) begin
                $display("  FAIL structural: the requant replay's m0_we is UNDRIVEN (reads %b).",
                         DUT.g_hd_probe.hs_m0_we);
                structural = structural + 1;
            end else
                $display("  requant path: twn_hd_seq S_RQ -> engine m0_we / bias_we / sh_we  driven");
        end
    endtask

    // =====================================================================
    //  the comparison
    // =====================================================================
    integer e_cnt, e_bad, e_x, b_cnt, b_bad, b_x;
    integer tot_cnt = 0, tot_bad = 0, tot_x = 0;
    integer first_bad_beat, first_bad_lane;
    reg signed [63:0] dmax, dv, got_v, want_v;
    reg [127:0] cw, ow;
    reg [39:0]  first_bad_addr;
    integer f_oy, f_ox, f_oc;

    task cmp_op(input integer idx);
        integer nb, lanes, lw;
        begin
            wipe_gold;
            case (idx)
              0: $readmemh("hd_op61_out.hex", gold);
              1: $readmemh("hd_op62_out.hex", gold);
              2: $readmemh("hd_op63_out.hex", gold);
              3: $readmemh("hd_op64_out.hex", gold);
            endcase
            load_or_die("golden output", gold[0], gold[P_OUTB[idx]-1]);

            nb    = P_OUTB[idx];
            lanes = P_T4[idx] ? 4  : 16;      // elements per 128-bit beat
            lw    = P_T4[idx] ? 32 : 8;       // bits per element

            e_cnt = 0; e_bad = 0; e_x = 0; dmax = 0;
            b_cnt = 0; b_bad = 0; b_x = 0;
            first_bad_beat = -1; first_bad_lane = -1; first_bad_addr = 40'd0;

            for (i = 0; i < nb; i = i + 1) begin
                cw = DDR_HA.mem[P_OUTW[idx] + i];
                ow = gold[i];
                for (j = 0; j < lanes; j = j + 1) begin
                    e_cnt = e_cnt + 1;
                    b_cnt = b_cnt + (lw / 8);
                    if (P_T4[idx]) begin
                        got_v  = $signed(cw[32*j +: 32]);
                        want_v = $signed(ow[32*j +: 32]);
                    end else begin
                        got_v  = $signed(cw[8*j +: 8]);
                        want_v = $signed(ow[8*j +: 8]);
                    end
                    if (P_T4[idx] ? (^cw[32*j +: 32] === 1'bx) : (^cw[8*j +: 8] === 1'bx)) begin
                        e_x = e_x + 1; b_x = b_x + (lw / 8);
                    end
                    if (P_T4[idx] ? (cw[32*j +: 32] !== ow[32*j +: 32])
                                  : (cw[8*j +: 8]   !== ow[8*j +: 8])) begin
                        e_bad = e_bad + 1;
                        b_bad = b_bad + (lw / 8);
                        if (first_bad_beat < 0) begin
                            first_bad_beat = i; first_bad_lane = j;
                            first_bad_addr = P_OUTBASE[idx] + i * 16 + j * (lw / 8);
                        end
                        // X is not a distance; only real values move dmax.
                        if (!(P_T4[idx] ? (^cw[32*j +: 32] === 1'bx)
                                        : (^cw[8*j +: 8] === 1'bx))) begin
                            dv = got_v - want_v; if (dv < 0) dv = -dv;
                            if (dv > dmax) dmax = dv;
                        end
                    end
                end
            end

            $display("op%0d  %s  %0dx%0d IC=%0d -> %0dx%0d OC=%0d",
                     61 + idx, P_T4[idx] ? "type4" : (P_SLICE[idx] ? "modeA" : "modeB"),
                     P_H[idx], P_W[idx], P_IC[idx], P_OH[idx], P_OW[idx], P_OC[idx]);
            $display("      bytes compared %0d   bytes wrong %0d   max|diff| %0d",
                     b_cnt, b_bad, dmax);
            $display("      of the wrong bytes, %0d were NEVER WRITTEN (still X)", b_x);
            $display("      W beats seen on ha_ during this operator: %0d   (expected %0d)",
                     op_wbeats[idx], P_OUTB[idx]);
            if (first_bad_beat >= 0) begin
                q = first_bad_beat * (P_T4[idx] ? 4 : 16) + first_bad_lane;
                f_oc = P_T4[idx] ? (q % 16) : (q % P_OC[idx]);
                f_ox = P_T4[idx] ? ((q / 16) % P_OW[idx]) : ((q / P_OC[idx]) % P_OW[idx]);
                f_oy = P_T4[idx] ? (q / (16 * P_OW[idx])) : (q / (P_OC[idx] * P_OW[idx]));
                cw = DDR_HA.mem[P_OUTW[idx] + first_bad_beat];
                ow = gold[first_bad_beat];
                $display("      FIRST BAD ADDRESS 0x%010h  (beat %0d lane %0d = oy %0d ox %0d oc %0d)",
                         first_bad_addr, first_bad_beat, first_bad_lane, f_oy, f_ox, f_oc);
                $display("        got  %032x", cw);
                $display("        want %032x", ow);
            end else
                $display("      BIT-EXACT");
            tot_cnt = tot_cnt + b_cnt; tot_bad = tot_bad + b_bad; tot_x = tot_x + b_x;
            if (e_bad != 0) errors = errors + 1;
            if (op_wbeats[idx] != P_OUTB[idx]) begin
                $display("      FAIL op%0d: the writer moved %0d beats, the descriptor asked for %0d",
                         61 + idx, op_wbeats[idx], P_OUTB[idx]);
                errors = errors + 1;
            end
        end
    endtask

    // =====================================================================
    //  the run
    // =====================================================================
    reg [31:0] v;
    integer spin;
    reg ok;
    integer reach, maxdrain, maxgap;

    initial begin
        errors = 0; structural = 0;
        n_ha_r = 0; n_ha_w = 0; n_hw_r = 0; n_ha_ar = 0; n_ha_aw = 0; n_hw_ar = 0;
        for (q = 0; q < 4; q = q + 1) begin
            op_wbeats[q] = 0; rq_seen[q] = 0;
            rq_bad_m0[q] = 0; rq_bad_bias[q] = 0; rq_bad_sh[q] = 0;
            drain_cyc[q] = -1; gap_cyc[q] = -1;
        end
        env_init;
        rst = 1'b1;
        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        $display("=== tb_hd_int: the head as an integrated path ===");
        $display("  CSR head window 0x0100..0x013c, requant window 0x0400..0x07fc,");
        $display("  hd_start, three movers, HP2, DDR");
        // print the DDR model's actual parameters: a valued define that did not
        // arrive leaves a zero-latency model under the requested label
        $display("[tb_hd_int] BUS MODEL RLAT=%0d STALL=%0d", DDR_HA.RLAT, DDR_HA.STALL);
        $display("");

        // ---- 1. is the datapath even connected? -----------------------------
        $display("--- structural checks, before anything runs ---");
        check_stream_wiring;

        // ---- 2. the DDR image ----------------------------------------------
        load_head_ddr;

        // ---- 3. the four descriptors ---------------------------------------
        $display("");
        $display("--- the four head descriptors, through the CSR window ---");
        for (k = 0; k < 4; k = k + 1) begin
            hd_desc(k);
            check_stage(k);
        end
        lite_rd(H_COMMIT, v);
        $display("  HD_COMMIT reads %08h -- sticky mask [7:4] = %0h, last operator [1:0] = %0d",
                 v, v[7:4], v[1:0]);
        if (v[7:4] !== 4'hF) begin
            $display("  FAIL: the commit mask is not 0xF; not all four descriptors landed.");
            $display("    This is the ONLY board-side evidence the writes took (twn_csr.v:237-244).");
            errors = errors + 1;
        end else
            $display("  all four operators committed at least once");

        // ---- 4. the requantisation tables ----------------------------------
        $display("");
        $display("--- the requantisation tables ---");
`ifdef HD_INT_SKIP_RQ
        // destructive arm: the requant window is left unwritten, so the four
        // operators must stop being bit-exact
        $readmemh("hd_rq.hex", rqrom);          // the per-operator report needs it
        $display("  HD_INT_SKIP_RQ: the requant window is NOT programmed (destructive arm)");
`else
        program_rq;
`endif

        // ---- 5. run --------------------------------------------------------
        $display("");
        $display("--- starting the head (HD_CTRL[0]) ---");
        running = 1'b1;
`ifdef HD_INT_BB2HD
        lite_wr(16'h0060, 32'h1);
        $display("  BB2HD: A_BB2HD = 1 -- op61 must read slot 1, op64 must write box B");
`endif
        lite_wr(H_CTRL, HC_START);

        // hd_start is a level cleared when the sequencer takes it, and a start
        // written while the head is busy is dropped; start then poll done.
        // The poll limit is only a bound; the stall detector ends a hung run.
        spin = 0; ok = 1'b0;
        while (!ok && !stalled && spin < 400000) begin
            lite_rd(H_CTRL, v);
            if (v & HC_R_DONE) ok = 1'b1;
            spin = spin + 1;
        end
        running = 1'b0;
        if (stalled) begin
            $display("  the run was ABANDONED after the stall above; the table below reports");
            $display("  how far the head got, and every byte it never wrote is counted as such.");
            errors = errors + 1;
        end else if (!ok) begin
            $display("FAIL tb_hd_int: the head never reported done after %0d polls", spin);
            dump_state;
            errors = errors + 1;
        end else
            $display("  head reported DONE (HD_CTRL = %08h) after %0d polls, %0d cycles",
                     v, spin, cyc);

        repeat (200) @(posedge clk);

        // ---- 6. the numbers -------------------------------------------------
        $display("");
        $display("--- HP2 traffic ---");
        DDR_HA.report;
        DDR_HW.report;
        $display("--- HP0/HP1 traffic (the backbone was never started; both must be 0 AR / 0 AW) ---");
        DDR_A.report;
        DDR_W.report;

        // table held in the engine at each operator's e_start (rq_* counters)
        $display("");
        $display("--- the requantisation table standing in the engine when each operator started ---");
        for (k = 0; k < 4; k = k + 1) begin
            if (rq_seen[k] == 0) begin
                $display("  op%0d  NEVER STARTED -- no table to report", 61 + k);
                errors = errors + 1;
            end else begin
                $display("  op%0d  m0 %0d/32 wrong   bias %0d/32 wrong   shift %0d/32 wrong",
                         61 + k, rq_bad_m0[k], rq_bad_bias[k], rq_bad_sh[k]);
                if (rq_bad_m0[k] + rq_bad_bias[k] + rq_bad_sh[k] != 0) begin
                    $display("      FAIL: op%0d started with a requantisation table that is not its own.",
                             61 + k);
                    errors = errors + 1;
                end
            end
        end

        $display("");
        $display("--- inter-operator timing: residual write drain vs the gap that hides it ---");
        reach = 0; maxdrain = 0; maxgap = 0;
        for (k = 0; k < 4; k = k + 1) begin
            $display("  op%0d  residual drain after e_done %0d cycles   gap e_done(prev)->e_start %0d cycles",
                     61 + k, drain_cyc[k], gap_cyc[k]);
            if (drain_cyc[k] > maxdrain) maxdrain = drain_cyc[k];
            if (gap_cyc[k]   > maxgap)   maxgap   = gap_cyc[k];
            // operator 0 has no predecessor
            if (k > 0 && drain_cyc[k-1] > gap_cyc[k]) reach = 1;
        end
        $display("  DRAINRACE reachable=%0d maxdrain=%0d maxgap=%0d", reach, maxdrain, maxgap);
        if (reach == 0)
            $display("    -> skipping S_DRAIN cannot change a byte in THIS environment: the");
            $display("       requant reload alone outlasts the residual drain. twn_axi_wr has");
            $display("       no write FIFO and tb_ddr_model answers B on wlast. The directed");
            $display("       test for the race is tb_hd_seq.v's check 3.");

        $display("");
        $display("--- per operator, every byte the head wrote into DDR ---");
        for (k = 0; k < 4; k = k + 1) cmp_op(k);
`ifdef HD_INT_BB2HD
        begin : bb2hd_verdict
            integer nA;
            nA = 0;
            for (q = 0; q < 32'h40000 / 16; q = q + 1)
                if (^DDR_HA.mem[HA_OUT64_W + q] !== 1'bx) nA = nA + 1;
            lite_rd(16'h0060, v);
            $display("  BB2HD: A_BB2HD = %08h (en %0d bb_par %0d hd_sel %0d coll %0d hd_en %0d); box A words written %0d",
                     v, v[0], v[1], v[2], v[3], v[4], nA);
            if (nA != 0) begin
                $display("  FAIL: op64 wrote %0d words into box A; with hd_sel = 1 it must write box B only", nA);
                errors = errors + 1;
            end
            if (v[4:0] !== 5'b10101) begin
                $display("  FAIL: A_BB2HD reads %02h; want en 1, bb_par 0, hd_sel 1, no collision, hd_en 1", v[4:0]);
                errors = errors + 1;
            end
        end
`endif

        $display("");
        $display("--- verdict ---");
        // 434,176 = 512 + 2048 + 8192 + 16384 beats of 16 bytes
        $display("  TOTAL  bytes compared %0d   bytes wrong %0d   never written %0d",
                 tot_cnt, tot_bad, tot_x);
        if (tot_cnt != 434176) begin
            $display("  FAIL: the comparison walked %0d bytes, not the head's 434,176.", tot_cnt);
            errors = errors + 1;
        end
        $display("  structural failures : %0d", structural);
        $display("  data / control failures : %0d", errors);
        if (errors == 0 && structural == 0) $display("tb_hd_int: PASS");
        else $display("tb_hd_int: %0d FAILURES", errors + structural);
        $finish;
    end

    // backstop; the stall detector normally fires first
    initial begin
        #(`HD_INT_CYCLES * 4);
        $display("FAIL tb_hd_int: GLOBAL TIMEOUT at cycle %0d", cyc);
        dump_state;
        $display("tb_hd_int: 1 FAILURES");
        $finish;
    end

endmodule
`default_nettype wire
