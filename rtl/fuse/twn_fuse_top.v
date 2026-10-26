// ============================================================================
//  twn_fuse_top.v -- the fused backbone datapath plus the head engine, wired
//  together. Wrapped by rtl/ip/twn_fuse_layer.v for the board.
//
//  What a block does: expand 1x1 (ternary array) -> depthwise 3x3 -> project
//  1x1 (ternary array, the same array instance) -> optional residual add ->
//  write the output rows to DDR. All of it runs row by row.
//
//  Buffers (twn_rowbuf unless noted):
//    RB_A   RingA, the block's input rows as loaded from DDR (1024-bit words)
//    RB_T1  the expand's output rows, read as a 3-row window by the depthwise
//    RB_C   RingC, the depthwise output rows (1024-bit words)
//    RESB   twn_res_buf, the block's own input rows kept for the residual add
//    RB_OU  the project's output rows, staged for the DDR write
//  RB_A and RB_C are two twn_rowbuf instances over ONE memory array (acmem),
//  arbitrated on the write side by twn_ring_warb.
//
//  Interface: s_* is the AXI4-Lite control port (twn_csr). a_* is the
//  activation master (HP0), w_* the backbone weight master (HP1). ha_*/hwt_*
//  are the head engine's activation and weight masters; with HD_PROBE = 0
//  there is no head and they are tied to zero. busy/done mark one frame.
//  o_* ports and cyc_* counters exist so synthesis keeps the logic behind
//  them; o_* have no other consumer.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

// RB_T1's storage slice depth; overridable from the command line.
//   xvlog ... -d "T1_SLICE_DEFAULT=0"    the flat bank
`ifndef T1_SLICE_DEFAULT
 `define T1_SLICE_DEFAULT 512
`endif

// Valueless selector so `-d HD_PROBE_ON` works where `-d NAME=VALUE` does not.
`ifdef HD_PROBE_ON
 `define HD_PROBE_DEFAULT 1
`else
 `define HD_PROBE_DEFAULT 0
`endif

module twn_fuse_top #(
    parameter integer PIX      = 4,
    parameter integer LANES    = 128,
    parameter integer OCMAX    = 4,
    parameter integer DW_LANES = 8,
    // Row strides in words, one per ring, because twn_rowbuf addresses a word
    // as slot*ROW_WORDS + w.
    //   A_WORDS  RingA, 1024-bit words
    //   C_WORDS  RingC, 1024-bit words
    // Each stride holds the worst block's row plus one spare word: the
    // activation gather reads a two-word sliding window, so it can fetch one
    // word past the row's last word. The spare keeps that read inside the
    // row's own slot.
    parameter integer A_WORDS = 17,
    parameter integer C_WORDS = 73,
    // Depth (rows) of RESB, the residual buffer. Declared here because
    // twn_blockseq uses it for the loader brake and is instantiated before
    // RESB. (The instance named RB_OU is a different buffer, depth 2.)
    parameter integer RES_DEPTH = 10,
    parameter integer T1_WORDS = 768,   // RB_T1 row stride, 128-bit words
    parameter integer OU_WORDS = 160,   // RB_OU row stride, 128-bit words
    // RB_T1's memory slice depth (see twn_rowbuf MEM_SLICE); 0 = flat bank.
    parameter integer T1_SLICE = `T1_SLICE_DEFAULT,
    // 1 builds the head engine (twn_hd_seq, movers, twn_hd_compute) in
    // g_hd_probe; 0 builds no head and parks the ha_*/hwt_* masters.
    // Selected by block design CONFIG.HD_PROBE or, for simulation, -d HD_PROBE_ON.
    parameter integer HD_PROBE = `HD_PROBE_DEFAULT
)(
    input  wire clk,
    input  wire rst,

    // ---- frame status ----
    output wire        busy,
    output wire        done,

    // AXI4-Lite, the control port
    input  wire [15:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [15:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rvalid,
    input  wire        s_rready,

    // HP0, activations: read and write are independent AXI channels
    output wire [39:0]  a_araddr,
    output wire [7:0]   a_arlen,
    output wire [2:0]   a_arsize,
    output wire [1:0]   a_arburst,
    output wire [3:0]   a_arcache,
    output wire [2:0]   a_arprot,
    output wire         a_arvalid,
    input  wire         a_arready,
    input  wire [127:0] a_rdata,
    input  wire [1:0]   a_rresp,
    input  wire         a_rlast,
    input  wire         a_rvalid,
    output wire         a_rready,

    output wire [39:0]  a_awaddr,
    output wire [7:0]   a_awlen,
    output wire [2:0]   a_awsize,
    output wire [1:0]   a_awburst,
    output wire [3:0]   a_awcache,
    output wire [2:0]   a_awprot,
    output wire         a_awvalid,
    input  wire         a_awready,
    output wire [127:0] a_wdata,
    output wire [15:0]  a_wstrb,
    output wire         a_wlast,
    output wire         a_wvalid,
    input  wire         a_wready,
    input  wire [1:0]   a_bresp,
    input  wire         a_bvalid,
    output wire         a_bready,

    // weight prefetcher status
    output wire         wf_busy,
    output wire         wf_done,

    // HP1, the backbone weight port (read only)
    output wire [39:0]  w_araddr,
    output wire [7:0]   w_arlen,
    output wire [2:0]   w_arsize,
    output wire [1:0]   w_arburst,
    output wire [3:0]   w_arcache,
    output wire [2:0]   w_arprot,
    output wire         w_arvalid,
    input  wire         w_arready,
    input  wire [127:0] w_rdata,
    input  wire [1:0]   w_rresp,
    input  wire         w_rlast,
    input  wire         w_rvalid,
    output wire         w_rready,

    // ---- the head engine's masters ----
    // The head runs three movers at once (input reader, weight reader, output
    // writer), so it needs two independent read streams. ha_* carries the
    // head's activations (read and write); hwt_* carries its weights (read
    // only). Both are outputs in both arms of HD_PROBE; with no head they are
    // driven to zero at the foot of this file.
    output wire [39:0]  ha_araddr,
    output wire [7:0]   ha_arlen,
    output wire [2:0]   ha_arsize,
    output wire [1:0]   ha_arburst,
    output wire [3:0]   ha_arcache,
    output wire [2:0]   ha_arprot,
    output wire         ha_arvalid,
    input  wire         ha_arready,
    input  wire [127:0] ha_rdata,
    input  wire [1:0]   ha_rresp,
    input  wire         ha_rlast,
    input  wire         ha_rvalid,
    output wire         ha_rready,

    output wire [39:0]  ha_awaddr,
    output wire [7:0]   ha_awlen,
    output wire [2:0]   ha_awsize,
    output wire [1:0]   ha_awburst,
    output wire [3:0]   ha_awcache,
    output wire [2:0]   ha_awprot,
    output wire         ha_awvalid,
    input  wire         ha_awready,
    output wire [127:0] ha_wdata,
    output wire [15:0]  ha_wstrb,
    output wire         ha_wlast,
    output wire         ha_wvalid,
    input  wire         ha_wready,
    input  wire [1:0]   ha_bresp,
    input  wire         ha_bvalid,
    output wire         ha_bready,

    // head weight reader, read only
    output wire [39:0]  hwt_araddr,
    output wire [7:0]   hwt_arlen,
    output wire [2:0]   hwt_arsize,
    output wire [1:0]   hwt_arburst,
    output wire [3:0]   hwt_arcache,
    output wire [2:0]   hwt_arprot,
    output wire         hwt_arvalid,
    input  wire         hwt_arready,
    input  wire [127:0] hwt_rdata,
    input  wire [1:0]   hwt_rresp,
    input  wire         hwt_rlast,
    input  wire         hwt_rvalid,
    output wire         hwt_rready,

    // ---- observation outputs ----
    // Pure outputs with no consumer: a port is a load synthesis may not
    // optimise away, so the logic feeding them is kept.
    output wire [1023:0]          o_ac_rd,
    output wire [DW_LANES*8-1:0]  o_dw_data,
    output wire                   o_dw_valid,
    output wire [7:0]             o_dw_x,
    output wire [7:0]             o_dw_tag,
    output wire [16:0]            o_act_addr,
    output wire                   o_act_re,
    output wire [17:0]            o_w_addr,
    output wire                   o_w_re,
    output wire                   o_arr_busy,
    output wire [8:0]             o_ld_row,
    output wire [2:0]             o_t1_pad,
    output wire [26:0]            o_desc_rest,
    // XOR fold of the head engine's signals; zero when HD_PROBE = 0.
    output wire [31:0]            o_hd_probe,

    // ---- performance counters (from twn_blockseq, read through the CSR) ----
    output wire [31:0]  cyc_total,
    output wire [31:0]  cyc_array,
    output wire [31:0]  cyc_dw,
    output wire [31:0]  cyc_stall_mem,
    output wire [31:0]  cyc_idle_pre,
    output wire [31:0]  cyc_idle_post
);
    // Current block's descriptor fields (driven by DT, the descriptor table).
    // All wires used before their driver are declared up front: with
    // `default_nettype none a forward reference is an error in xelab.
    wire [9:0]  c_in, c_mid, c_out;
    wire [8:0]  h_in, w_in;
    wire        s_dw, has_res;
    // read by ring_overrun, driven further down
    wire        res_out_valid, res_stale;
    wire        ring_a_dropped;
    wire        ring_b_dropped, dwp_we;
    wire [2:0]  pack_e, pack_p;      // output packing of expand / project
    wire [1:0]  pack0_e, pack0_p;   // segment 0's pack; 0 = same as pack
    wire        msg_e, msg_p;       // mixed-segment rotation flag
    wire [3:0]  nseg_e, nseg_p;
    wire        stem;               // block 0: 3x3 stride-2 first convolution
    // The expand's output width and height: the stem halves both. RB_A does
    // not use these; it holds the rows the loader issues (the stem loads twice
    // as many rows as it produces).
    wire [8:0] w_mid_t = stem ? {1'b0, w_in[8:1]} : w_in;
    wire [9:0] h_mid_t = stem ? {2'b0, h_in[8:1]} : {1'b0, h_in};

    // ================= the sequencer =================
    wire        e_req, d_req, p_req;
    wire [8:0]  e_row, d_row, p_row, ld_row, st_row;
    // t1_rptr (from RB_T1) and seq_t1_rptr (twn_blockseq's own copy) are
    // separate nets: tying two module outputs to one net resolves in
    // simulation but not in synthesis. RB_T1's `free` is what the sequencer
    // brakes on; seq_t1_rptr is not read.
    wire [9:0]  t1_rptr;
    wire [9:0]  seq_t1_rptr;
    wire [9:0]  in_wptr, t1_wptr, dw_wptr, in_free, t1_free, dw_free, out_free;
    wire        e_done, d_done, p_done;

    // RES_DEPTH is RESB's DEPTH (set at its instantiation below).
    twn_blockseq #(.PIX(PIX), .LANES(LANES), .DW_LANES(DW_LANES),
                   .RES_DEPTH(RES_DEPTH)) SEQ (
        // cyc_clr is ap_start (once per frame), not blk_start (once per block).
        .clk(clk), .rst(rst), .start(blk_start), .cyc_clr(ap_start),
        .c_in(c_in), .c_mid(c_mid), .c_out(c_out),
        .h_in(h_in), .w_in(w_in), .s_dw(s_dw), .stem(stem),
        .pack_e(pack_e), .pack_p(pack_p),
        .ld_req(ld_req), .ld_done(ld_done),
        .e_req(e_req), .e_done(e_done),
        .d_req(d_req), .d_done(d_done),
        .p_req(p_req), .p_done(p_done),
        .st_req(st_req), .st_done(st_done),
        .in_wptr(in_wptr), .in_free(in_free),
        .t1_wptr(t1_wptr), .t1_free(t1_free), .t1_rptr(seq_t1_rptr),
        .dw_wptr(dw_wptr), .dw_free(dw_free), .out_free(out_free),
        .has_res(has_res),
        .e_row(e_row), .d_row(d_row), .p_row(p_row),
        .ld_row(ld_row), .st_row(st_row),
        .busy(seq_busy), .done(seq_done),
        .cyc_total(cyc_total), .cyc_array(cyc_array), .cyc_dw(cyc_dw),
        .cyc_stall_mem(cyc_stall_mem),
        .cyc_idle_pre(cyc_idle_pre), .cyc_idle_post(cyc_idle_post),
        .why_e_ld(), .why_e_t1full(), .why_p_dw(), .why_p_outfull());

    // ================= the shared ternary array =================
    // One instance serves both the expand and the project, one at a time under
    // the sequencer. The choice between their activations, weights and requant
    // tables is made in the address, so the wide buses have no multiplexer.
    wire         arr_busy, arr_done;
    wire [16:0]  act_addr;
    wire         act_re;
    // The array's group counter is 9 bits, the gather's xg port is 10; the
    // extension is explicit so that no bit of the port is left unconnected.
    wire [8:0]   arr_act_xg;
    wire [9:0]   act_xg = {1'b0, arr_act_xg};
    wire [8:0]   out_xg;
    wire [2:0]   act_seg;
    wire [9:0]   out_ocg;
    wire [17:0]  w_addr;
    wire         w_re;
    wire [255:0] w_data;
    wire [12:0]  rq_addr;
    wire [OCMAX*64-1:0] rq_word;   // one 64-bit requant field per lane
    wire [PIX*OCMAX*8-1:0] arr_out;
    wire         arr_out_valid, arr_out_dst;   // dst: 0 = expand output, 1 = project output
    wire [16:0]  arr_out_addr;

    // The 95-bit micro-op for the array, built from the descriptor by ENC and
    // issued by ISS.
    wire uop_valid, role_q;   // role_q: 0 = expand, 1 = project (held for the whole row)
    wire [94:0] uop;

    // High from the array's done pulse until the scatter's flush completes.
    reg scat_busy_r;
    twn_uop_issue ISS (
        .clk(clk), .rst(rst),
        .e_req(e_req), .p_req(p_req),
        .arr_busy(arr_busy), .arr_done(arr_done),
        .scat_busy(scat_busy_r),
        .uop_valid(uop_valid), .role_q(role_q));

    twn_uop_enc ENC (
        .c_mid(c_mid), .c_out(c_out), .w_in(w_in), .s_dw(s_dw), .stem(stem),
        .pack_e(pack_e), .pack_p(pack_p),
        .pack0_e(pack0_e), .pack0_p(pack0_p),
        .msg_e(msg_e), .msg_p(msg_p),
        .nseg_e(nseg_e), .nseg_p(nseg_p),
        // on-chip region bases of the computing block
        .mb_tern(mb_tern), .mb_rqa(mb_rqa),
        .role(role_q), .uop(uop));

    // Channel count of the tensor the array is reading: the expand reads the
    // block input, the project reads the depthwise output.
    wire [9:0] act_c = role_q ? c_mid : c_in;

    // ---- block 0's stem: which input row each pass reads ----
    // The stem is 3x3 stride 2 pad 1 and `act_seg` is the kernel row, so output
    // row e_row, pass seg reads input row 2*e_row - 1 + seg. For e_row = 0 and
    // seg = 0 that is row -1, the top pad: the gather zeroes the pass
    // (stem_pad_row) and the read row is clamped to 0. There is no bottom-pad
    // case because the last pass of the last row reads row h_in - 1, which
    // holds only for a stride-2 stem with even input height.
    // Only the expand is a stem, so this affects RB_A and not RB_C.
    wire        e_stem   = stem && !role_q;
    wire [9:0]  e_row_x2 = {e_row[8:0], 1'b0};        // 2*e_row (sliced: a
                                                      // concatenation operand
                                                      // is self-determined)
    wire        e_pad_c  = e_stem && (e_row == 9'd0) && (act_seg == 3'd0);
    wire [9:0]  e_row_c  = !e_stem  ? {1'b0, e_row}
                         : e_pad_c  ? 10'd0
                                    : (e_row_x2 + {7'd0, act_seg} - 10'd1);
    // The row and pad flag are latched on the array's request (act_re), the
    // same cycle act_seg names that request. Two consumers read them one cycle
    // apart: the gather's stem_pad_row in S_CALC (the cycle after the request)
    // and RB_A's rd_row in S_FETCH (the cycle after that). Latching one cycle
    // later would give S_CALC the previous pass's pad flag.
    // Non-stem blocks use the combinational {1'b0, e_row}.
    reg  [9:0]  e_row_q;
    reg         e_pad_q;
    reg         act_re_d;
    // Negative test only: latch one cycle late.
`ifdef FUSE_NEG_STEM_PADLAG
    wire        e_lat = act_re_d;
`else
    wire        e_lat = act_re;
`endif
    always @(posedge clk) begin
        if (rst) begin
            act_re_d <= 1'b0; e_row_q <= 10'd0; e_pad_q <= 1'b0;
        end else begin
            act_re_d <= act_re;
            if (e_lat) begin
                e_row_q <= e_row_c;
                e_pad_q <= e_pad_c;
            end
        end
    end
    wire [9:0]  e_rd_row  = e_stem ? e_row_q : {1'b0, e_row};
    wire        e_top_pad = e_stem ? e_pad_q : 1'b0;

    twn_fuse_array #(.LANES(LANES), .PIX(PIX), .OCMAX(OCMAX)) ARR (
        .clk(clk), .rst(rst),
        .uop(uop), .uop_valid(uop_valid), .busy(arr_busy), .done(arr_done),
        .act_addr(act_addr), .act_re(act_re), .act_data(act_data),
        // The gather takes many cycles per request and drops a request that
        // arrives while it is busy, so the array waits on ready/valid.
        .act_ready(!gath_busy), .act_valid(gath_done),
        .act_xg(arr_act_xg), .act_seg(act_seg),
        .out_xg(out_xg), .out_ocg(out_ocg),
        .w_addr(w_addr), .w_re(w_re), .w_data(w_data),
        .rq_addr(rq_addr),
        .rq_m0(arr_rq_m0), .rq_bias(arr_rq_bias), .rq_sh(arr_rq_sh),
        .out_data(arr_out), .out_valid(arr_out_valid),
`ifdef FUSE_EARLY_PRIME
        .out_addr(arr_out_addr), .out_dst(arr_out_dst),
        .scat_hold(scat_busy_r));
`else
        .out_addr(arr_out_addr), .out_dst(arr_out_dst));
`endif

    // ---- requant groups split into per-consumer fields ----
    // A requant memory word holds entries side by side (m0, bias, sh per
    // lane); each consumer's port is field-major. This is wiring only.
    wire [OCMAX*18-1:0]    arr_rq_m0;
    wire [OCMAX*40-1:0]    arr_rq_bias;
    wire [OCMAX*6-1:0]     arr_rq_sh;
    wire [DW_LANES*18-1:0] dw_rq_m0;
    wire [DW_LANES*32-1:0] dw_rq_bias;
    wire [DW_LANES*6-1:0]  dw_rq_sh;

    // ================= the control registers and the table =================
    wire [39:0] act_base, w_base, in_ptr, out_ptr;
    wire [4:0]  n_blocks;
    wire        d_wr_en, d_check, d_valid, d_check_done, d_check_busy;
    wire [12:0] d_wr_addr;
    wire [31:0] d_wr_data;
    wire [3:0]  d_err_code;
    wire [4:0]  d_err_block;
    wire        ap_start, desc_ready;
    // The head's control path, independent of ap_start/busy/done so that the
    // head can run frame k-1 while the array runs frame k.
    wire        hd_start, hd_d_we;
    wire [1:0]  hd_d_wa;
    wire [39:0] hd_d_in_base, hd_d_w_base, hd_d_out_base;
    wire [23:0] hd_d_in_beats, hd_d_w_beats, hd_d_out_beats;
    wire [8:0]  hd_d_ic;   wire [5:0] hd_d_oc;
    wire [6:0]  hd_d_h,  hd_d_w;
    wire        hd_d_type4, hd_d_slice, hd_d_relu;
    wire [15:0] hd_d_lo, hd_d_hi;
    // Write port of the head's requantisation table (CSR window at 0x0400).
    wire        hd_rq_we;
    wire [7:0]  hd_rq_wa;
    wire [31:0] hd_rq_wd;
    wire        hdseq_busy, hdseq_done;
    // BB2HD: the last backbone block writes straight into the head's input
    // slots. The enable is register A_BB2HD in twn_csr.
    wire        bb2hd_en, bb_par_clr, bb2hd_coll;
    reg         bb2hd_f, bb_par;           // backbone side: outside the head generate
    wire        hd_sel, hd_en_l;           // head side: driven by both generate arms

    wire [3:0]  in_slot, out_slot, res_slot;
    wire signed [17:0] mp_res, mq_res;
    wire [5:0]         sh_res;
    wire signed [15:0] lo_res, hi_res;
    wire [15:0] row_bytes_in, row_bytes_out;
    wire [31:0] off_tern, off_dw, off_rqa, off_rqd;
    wire [15:0] n_tern, n_dw, n_rqa, n_rqd;
    wire [13:0] mb_tern, fb_tern;
    wire [9:0]  mb_dw, fb_dw;
    wire [12:0] mb_rqa, mb_rqd, fb_rqa, fb_rqd;
    wire        seq_busy, seq_done;

    // ================= the frame sequencer =================
    // Loops over the blocks and overlaps block b's compute with the weight
    // fetch of block b+1 (blk_f is the block being fetched).
    wire [4:0] blk, blk_f;
    wire       blk_start, wf_start, descf_ready;

    twn_frameseq FS (
        .clk(clk), .rst(rst),
        .ap_start(ap_start), .n_blocks(n_blocks), .busy(busy), .done(done),
        .blk(blk), .blk_f(blk_f),
        .desc_ready(desc_ready), .descf_ready(descf_ready),
        .blk_start(blk_start), .blk_busy(seq_busy), .blk_done(seq_done),
        .wf_start(wf_start), .wf_busy(wf_busy), .wf_done(wf_done));

    twn_csr CSR (
        .clk(clk), .rstn(~rst),
        .awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wvalid(s_wvalid), .wready(s_wready),
        .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
        .araddr(s_araddr), .arvalid(s_arvalid), .arready(s_arready),
        .rdata(s_rdata), .rresp(s_rresp), .rvalid(s_rvalid), .rready(s_rready),
        .ap_start(ap_start), .core_busy(busy), .core_done(done),
        .act_base(act_base), .w_base(w_base), .in_ptr(in_ptr), .out_ptr(out_ptr),
        .n_blocks(n_blocks),
        .d_wr_en(d_wr_en), .d_wr_addr(d_wr_addr), .d_wr_data(d_wr_data),
        .d_check(d_check), .d_valid(d_valid), .d_check_done(d_check_done),
        .d_err_code(d_err_code), .d_err_block(d_err_block),
        .cur_block(blk), .ring_overrun(ring_overrun),
        .cyc_total(cyc_total), .cyc_array(cyc_array), .cyc_dw(cyc_dw),
        .cyc_stall_mem(cyc_stall_mem),
        .cyc_idle_pre(cyc_idle_pre), .cyc_idle_post(cyc_idle_post),
        .pix_nz(pix_nz_sticky), .arr_cap(arr_cap),
        // ---- the head engine's control and descriptor window ----
        // Names match twn_hd_seq's d_* ports. hd_start/hd_busy/hd_done are
        // separate from ap_start/core_busy/ap_done: the processor drives the
        // two start/done pairs independently.
        .hd_start(hd_start), .hd_busy(hdseq_busy), .hd_done(hdseq_done),
        .hd_d_we(hd_d_we), .hd_d_wa(hd_d_wa),
        .hd_d_in_base(hd_d_in_base), .hd_d_w_base(hd_d_w_base),
        .hd_d_out_base(hd_d_out_base),
        .hd_d_in_beats(hd_d_in_beats), .hd_d_w_beats(hd_d_w_beats),
        .hd_d_out_beats(hd_d_out_beats),
        .hd_d_ic(hd_d_ic), .hd_d_oc(hd_d_oc), .hd_d_h(hd_d_h), .hd_d_w(hd_d_w),
        .hd_d_type4(hd_d_type4), .hd_d_slice(hd_d_slice), .hd_d_relu(hd_d_relu),
        .hd_d_lo(hd_d_lo), .hd_d_hi(hd_d_hi),
        .hd_rq_we(hd_rq_we), .hd_rq_wa(hd_rq_wa), .hd_rq_wd(hd_rq_wd),
        .bb2hd_en(bb2hd_en), .bb_par_clr(bb_par_clr),
        .bb_par(bb_par), .hd_sel(hd_sel), .hd_en_l(hd_en_l),
        .bb2hd_coll(bb2hd_coll));

    twn_desctab DT (
        .clk(clk), .rstn(~rst),
        .wr_en(d_wr_en), .wr_addr(d_wr_addr), .wr_data(d_wr_data),
        .n_blocks(n_blocks),
        .check(d_check), .check_busy(d_check_busy), .check_done(d_check_done),
        .valid(d_valid), .err_code(d_err_code), .err_block(d_err_block),
        .blk(blk), .desc_ready(desc_ready),
        .blk_f(blk_f), .descf_ready(descf_ready),
        .c_in(c_in), .c_mid(c_mid), .c_out(c_out),
        .h_in(h_in), .w_in(w_in), .s_dw(s_dw),
        .pack_e(pack_e), .pack_p(pack_p),
        .pack0_e(pack0_e), .pack0_p(pack0_p),
        .msg_e(msg_e), .msg_p(msg_p),
        .nseg_e(nseg_e), .nseg_p(nseg_p), .stem(stem),
        .in_slot(in_slot), .out_slot(out_slot), .res_slot(res_slot),
        .has_res(has_res),
        .mp_res(mp_res), .mq_res(mq_res), .sh_res(sh_res),
        .lo_res(lo_res), .hi_res(hi_res),
        .row_bytes_in(row_bytes_in), .row_bytes_out(row_bytes_out),
        .off_tern(off_tern), .off_dw(off_dw), .off_rqa(off_rqa), .off_rqd(off_rqd),
        .n_tern(n_tern), .n_dw(n_dw), .n_rqa(n_rqa), .n_rqd(n_rqd),
        .mb_tern(mb_tern), .mb_dw(mb_dw), .mb_rqa(mb_rqa), .mb_rqd(mb_rqd),
        .fb_tern(fb_tern), .fb_dw(fb_dw), .fb_rqa(fb_rqa), .fb_rqd(fb_rqd));

    // ================= the activation gather and scatter =================
    // One instance each: the expand and the project use the array a whole row
    // at a time, so their streams never interleave, and the scatter is flushed
    // at each row end.
    wire [PIX*LANES*8-1:0] act_data;
    wire        gath_busy, gath_done;
    wire [15:0] gath_word;
    wire        gath_re;

    // Tag for the gather's two cached row words: which buffer and row they came
    // from (stem passes ask for the same word index at different input rows).
    wire [10:0] gath_src = {role_q, role_q ? {1'b0, p_row} : e_rd_row};

    twn_act_gather #(.ROW_BITS(1024), .LANES(LANES), .PIX(PIX)) GATH (
        .clk(clk), .rst(rst),
        .req(act_re), .xg(act_xg), .seg(act_seg), .c_chan(act_c),
        .stem(e_stem), .stem_pad_row(e_top_pad), .src(gath_src),
        .busy(gath_busy), .done(gath_done),
        .rb_word(gath_word), .rb_re(gath_re), .rb_data(ac_rd),
        .act_data(act_data));

    // The scatter's shape follows the destination: the expand writes RB_T1
    // (c_mid channels, pack_e), the project writes the block output (c_out,
    // pack_p).
    wire [9:0] scat_c    = arr_out_dst ? c_out : c_mid;
    wire [2:0] scat_pack = arr_out_dst ? (3'd1 << pack_p) : (3'd1 << pack_e);
    wire         scat_en;
    wire [15:0]  scat_word;
    wire [127:0]  scat_data;
    // Row end for the row buffers' write pointers. It is the scatter's flush,
    // not a marked last write, because the final word of a row may come out of
    // the flush path.
    wire          scat_flush_done;

    // ROW_BITS 128 matches the 128-bit row buffers it feeds (RB_T1, RB_OU);
    // the scatter writes one 16-byte word per wr_en.
    twn_act_scatter #(.ROW_BITS(128), .PIX(PIX), .OCMAX(OCMAX)) SCAT (
        .clk(clk), .rst(rst),
        .c_chan(scat_c), .pack(scat_pack),
        .in_valid(arr_out_valid), .ocg(out_ocg), .in_data(arr_out),
        .wr_word(scat_word), .wr_en(scat_en), .wr_data(scat_data),
        .flush(arr_done), .flush_done(scat_flush_done),
        .o_bank_wnz(scat_bank_wnz), .o_bank_rnz(scat_bank_rnz));

    // ================= pixel-phase observation, for the CSR =================
    // Three groups of PIX sticky bits, cleared on ap_start, counting only the
    // project stage (arr_out_dst = 1):
    //   [PIX-1:0]        array output for this pixel was ever non-zero
    //   [2*PIX-1:PIX]    scatter bank write data was ever non-zero
    //   [3*PIX-1:2*PIX]  scatter bank read data was ever non-zero
    wire [PIX-1:0] scat_bank_wnz, scat_bank_rnz;

    // Only the consumers are guarded by FUSE_OBS. Without it nothing loads the
    // scatter's o_bank_* ports and synthesis trims their reduction logic; the
    // CSR addresses stay and read zero.
`ifdef FUSE_OBS
    wire [PIX-1:0] arr_pix_nz;
    genvar pxi;
    generate for (pxi = 0; pxi < PIX; pxi = pxi + 1) begin : g_pixnz
        assign arr_pix_nz[pxi] = arr_out_valid && arr_out_dst &&
                                 (|arr_out[pxi*OCMAX*8 +: OCMAX*8]);
    end endgenerate

    reg [3*PIX-1:0] pix_nz_sticky;
    always @(posedge clk) begin
        if (rst || ap_start) pix_nz_sticky <= {(3*PIX){1'b0}};
        else pix_nz_sticky <= pix_nz_sticky |
                              {scat_bank_rnz,
                               {PIX{arr_out_dst}} & scat_bank_wnz,
                               arr_pix_nz};
    end
`else
    wire [3*PIX-1:0] pix_nz_sticky = {(3*PIX){1'b0}};
    wire _unused_obs = &{1'b0, scat_bank_wnz, scat_bank_rnz, 1'b0};
`endif

    // Raw capture of the first project beat of the frame (128 bits), published
    // in four CSR words at 0x0050..0x005c. Pixel p occupies bits
    // [p*OCMAX*8 +: OCMAX*8].
`ifdef FUSE_OBS
    reg [127:0] arr_cap;
    reg         arr_cap_done;
    always @(posedge clk) begin
        if (rst || ap_start) begin
            arr_cap      <= 128'd0;
            arr_cap_done <= 1'b0;
        end else if (!arr_cap_done && arr_out_valid && arr_out_dst) begin
            arr_cap      <= arr_out[127:0];
            arr_cap_done <= 1'b1;
        end
    end
`else
    wire [127:0] arr_cap = 128'd0;
`endif

    // The next row must not be issued between the array's done and the end of
    // that row's scatter flush: arr_out_dst lags the current micro-op's
    // destination, so a new issue in that window would credit the finished
    // row's end to the wrong ring. Set on arr_done, cleared on flush_done
    // (flush_done wins if they coincide). Fed to ISS as scat_busy.
    always @(posedge clk) begin
        if (rst)                   scat_busy_r <= 1'b0;
        else if (scat_flush_done)  scat_busy_r <= 1'b0;
        else if (arr_done)         scat_busy_r <= 1'b1;
    end

    // ================= the activation masters =================
    wire         ld_req, ld_done, st_req, st_done;
    wire [1023:0] ld_data;
    wire          ld_wr_en, ld_row_last;
    wire [15:0]   ou_word;
    wire          ou_re;

    wire         ld_beat_valid;
    wire [127:0] ld_beat_data;

    twn_act_rd #(.ADDR_W(40), .ROW_BITS(1024), .SLOT_LOG2(18)) ARD (
        .clk(clk), .rstn(~rst), .start(ld_req), .act_base(act_base),
        .slot(in_slot), .in_ptr(in_ptr), .row(ld_row), .row_bytes(row_bytes_in),
        .busy(), .done(ld_done),
        .beat_valid(ld_beat_valid), .beat_data(ld_beat_data),
        .araddr(a_araddr), .arlen(a_arlen), .arsize(a_arsize), .arburst(a_arburst),
        .arcache(a_arcache), .arprot(a_arprot), .arvalid(a_arvalid), .arready(a_arready),
        .rdata(a_rdata), .rresp(a_rresp), .rlast(a_rlast), .rvalid(a_rvalid),
        .rready(a_rready),
        // ld_can_write is the arbiter's a_can: a promise that a write
        // presented in the NEXT cycle will be accepted, which is what the
        // loader's registered wr_en needs.
        .wr_can(ld_can_write),
        .wr_en(ld_wr_en), .wr_data(ld_data), .wr_row_last(ld_row_last));

    // ---- BB2HD: where the last block's rows go ----
    // twn_act_wr writes to base + slot * 2^18 + row * row_bytes. For the last
    // block of a frame started with A_BB2HD[0] = 1, base becomes
    // OUT_PTR + bb_par * 0x10000 and slot 0, so the rows land in the head's
    // input slot bb_par; in every other case it is act_base and the
    // descriptor's slot. The select and the base are registered from
    // quasi-static inputs (blk changes once per block, OUT_PTR and bb_par once
    // per frame), so twn_act_wr's start-to-address adder sees a flip-flop.
    //  bb2hd_f   A_BB2HD[0] sampled when ap_start arrives while idle, so a
    //            frame is entirely one mode.
    //  bb_par    the head input slot the next bb2hd frame's last block writes;
    //            flips on the done of every bb2hd frame.
    always @(posedge clk) begin
        if (rst) begin
            bb2hd_f <= 1'b0;
            // Simulation only: start at parity 1 to exercise the +0x10000 slot.
`ifdef FUSE_BB2HD_PAR1_INIT
            bb_par  <= 1'b1;
`else
            bb_par  <= 1'b0;
`endif
        end else begin
            if (ap_start && !busy) bb2hd_f <= bb2hd_en;
            if (done && bb2hd_f)          bb_par <= ~bb_par;
            else if (bb_par_clr && !busy) bb_par <= 1'b0;
        end
    end

    reg         awr_use_ptr;
    reg  [39:0] awr_base;
    // FUSE_NEG_BB2HD_NOPTR (break test): the last block keeps its descriptor's
    // slot, i.e. the enable reaches nothing on the backbone side.
`ifdef FUSE_NEG_BB2HD_NOPTR
    wire        awr_last = 1'b0;
`else
    wire        awr_last = bb2hd_f && (blk == n_blocks - 5'd1);
`endif
    always @(posedge clk) begin
        if (rst) begin
            awr_use_ptr <= 1'b0;
            awr_base    <= 40'd0;
        end else begin
            awr_use_ptr <= awr_last;
            awr_base    <= awr_last ? (out_ptr + {23'd0, bb_par, 16'd0}) : act_base;
        end
    end
    wire [3:0] awr_slot = awr_use_ptr ? 4'd0 : out_slot;

    twn_act_wr #(.ADDR_W(40), .ROW_BITS(128), .SLOT_LOG2(18)) AWR (
        .clk(clk), .rstn(~rst), .start(st_req), .act_base(awr_base),
        .slot(awr_slot), .row(st_row), .row_bytes(row_bytes_out),
        .busy(), .done(st_done),
        .rb_word(ou_word), .rb_re(ou_re), .rb_data(ou_rd),
        .awaddr(a_awaddr), .awlen(a_awlen), .awsize(a_awsize), .awburst(a_awburst),
        .awcache(a_awcache), .awprot(a_awprot), .awvalid(a_awvalid), .awready(a_awready),
        .wdata(a_wdata), .wstrb(a_wstrb), .wlast(a_wlast), .wvalid(a_wvalid),
        .wready(a_wready), .bresp(a_bresp), .bvalid(a_bvalid), .bready(a_bready));

    // ================= the weight prefetcher =================
    wire         wr_tern_en, wr_dw_en, wr_rqa_en, wr_rqd_en;
    wire [13:0]  wr_tern_addr;
    wire [9:0]   wr_dw_addr;
    wire [12:0]  wr_rqa_addr, wr_rqd_addr;
    wire [255:0] wr_tern_data;
    wire [OCMAX*64-1:0] wr_rqa_data;
    wire [575:0] wr_dw_data;
    wire [447:0] wr_rqd_data;

    twn_wfetch #(.ADDR_W(40), .RQ_W(OCMAX*64)) WF (
        .clk(clk), .rstn(~rst), .start(wf_start), .w_base(w_base),
        .off_tern(off_tern), .off_dw(off_dw), .off_rqa(off_rqa), .off_rqd(off_rqd),
        .n_tern(n_tern), .n_dw(n_dw), .n_rqa(n_rqa), .n_rqd(n_rqd),
        .mb_tern(fb_tern), .mb_dw(fb_dw), .mb_rqa(fb_rqa), .mb_rqd(fb_rqd),
        .busy(wf_busy), .done(wf_done),
        .araddr(w_araddr), .arlen(w_arlen), .arsize(w_arsize), .arburst(w_arburst),
        .arcache(w_arcache), .arprot(w_arprot), .arvalid(w_arvalid), .arready(w_arready),
        .rdata(w_rdata), .rresp(w_rresp), .rlast(w_rlast), .rvalid(w_rvalid),
        .rready(w_rready),
        .wr_tern_en(wr_tern_en), .wr_tern_addr(wr_tern_addr), .wr_tern_data(wr_tern_data),
        .wr_dw_en(wr_dw_en),     .wr_dw_addr(wr_dw_addr),     .wr_dw_data(wr_dw_data),
        .wr_rqa_en(wr_rqa_en),   .wr_rqa_addr(wr_rqa_addr),   .wr_rqa_data(wr_rqa_data),
        .wr_rqd_en(wr_rqd_en),   .wr_rqd_addr(wr_rqd_addr),   .wr_rqd_data(wr_rqd_data));

    // ================= the weight and constant memory =================
    wire [447:0] rqd_word;
    wire [575:0] dw_taps;

    // RQA_WORDS is one word per output-channel group: 600 at OCMAX 4.
    twn_wmem #(.RQ_W(OCMAX*64), .RQA_WORDS(600*4/OCMAX)) WMEM (
        .clk(clk),
        .wr_tern_en(wr_tern_en), .wr_tern_addr(wr_tern_addr), .wr_tern_data(wr_tern_data),
        .wr_dw_en(wr_dw_en),     .wr_dw_addr(wr_dw_addr),     .wr_dw_data(wr_dw_data),
        .wr_rqa_en(wr_rqa_en),   .wr_rqa_addr(wr_rqa_addr),   .wr_rqa_data(wr_rqa_data),
        .wr_rqd_en(wr_rqd_en),   .wr_rqd_addr(wr_rqd_addr),   .wr_rqd_data(wr_rqd_data),
        .rd_tern_addr(w_addr[13:0]), .rd_tern_data(w_data),
        .rd_dw_addr(dws_taps_addr),      .rd_dw_data(dw_taps),
        .rd_rq_addr(rq_addr),        .rd_rq_data(rq_word),
        .rd_rqd_addr(dws_rqd_addr),      .rd_rqd_data(rqd_word));

    // ---- ring overrun detector ----
    // Sticky-at-the-CSR flag raised when a producer writes into a full buffer
    // or a consumer reads a buffer that no longer holds its row. It records
    // only; it does not stall.
    //   ld_wr_en with RB_A full; scat_en (expand) with RB_T1 full;
    //   res_out_valid with RB_OU full; dwp_we with RB_C full;
    //   res_stale (RESB too shallow for the row asked);
    //   ring_a_dropped / ring_b_dropped (the array arbiter refused a write).
    wire ac_wr_ready, t1_wr_ready, ou_wr_ready, dwp_wr_ready;
    wire ring_overrun = (ld_wr_en                & ~ac_wr_ready)
                      | (scat_en & ~arr_out_dst  & ~t1_wr_ready)
                      | (res_out_valid           & ~ou_wr_ready)
                      | (dwp_we                   & ~dwp_wr_ready)
                      | res_stale
                      | ring_a_dropped
                      | ring_b_dropped;
`ifdef FUSE_SIM_OVRDBG
    // simulation only: print which term first raised ring_overrun
    reg ovrdbg_seen = 1'b0;
    always @(posedge clk) if (ring_overrun && !ovrdbg_seen) begin
        ovrdbg_seen <= 1'b1;
        $display("[ovrdbg] RB_OU wptr=%0d rptr=%0d blk=%0d st_row=%0d", RB_OU.wptr_r, RB_OU.rptr_r, blk, st_row);
        $display("[ovrdbg] t=%0t ring_overrun first: ld_full=%b scat_full=%b res_full=%b dwp_full=%b res_stale=%b a_dropped=%b b_dropped=%b",
                 $time, (ld_wr_en & ~ac_wr_ready), (scat_en & ~arr_out_dst & ~t1_wr_ready),
                 (res_out_valid & ~ou_wr_ready), (dwp_we & ~dwp_wr_ready), res_stale, ring_a_dropped, ring_b_dropped);
    end
`endif

    // ================= RingA and RingC: one array, two rings =================
    // The block input (RingA) and the depthwise output (RingC) share one
    // memory array. The read side needs no multiplexer beyond the address
    // (the array arbiter grants the expand or the project, one at a time);
    // the write side is arbitrated by twn_ring_warb. They remain two
    // twn_rowbuf instances so each keeps its own pointers (one producer, one
    // consumer each). Writes are lane-enabled because the depthwise writes
    // 8 bytes at a time.
    //
    // Depths. A deeper RingA lets the loader run further ahead of the expand.
    // The residual buffer RESB has no brake, and the loader's only brake is
    // RingA's credit (in_free), so deepening RingA also lengthens the
    // distance RESB must cover. Keep the row counts powers of two (or 3 for
    // RingC): twn_rowbuf's slot decode is a bit select for those.
`ifdef FUSE_ARING_D4
    localparam integer AC_ROWS = 4;                    // RingA
`elsif FUSE_ARING_D8
    localparam integer AC_ROWS = 8;                    // RingA
`else
    localparam integer AC_ROWS = 16;                   // RingA
`endif
    // RingC rows: 2 by default, 3 with -d FUSE_CC_ROWS3. Depth 3 uses
    // twn_rowbuf's carry-free mod-3 slot decode.
`ifdef FUSE_CC_ROWS3
    localparam integer CC_ROWS = 3;                    // RingC
`else
    localparam integer CC_ROWS = 2;                    // RingC
`endif
    // RB_T1 rows: 5. Negative test only: 6 gives the expand more credit than
    // the depthwise's 3-row window allows.
`ifdef FUSE_NEG_T1_DEPTH6
    localparam integer T1_ROWS = 6;
`else
    localparam integer T1_ROWS = 5;
`endif
    // Each stride already includes its spare word (see A_WORDS), so the total
    // is just the sum.
    localparam integer AC_TOT  = AC_ROWS * A_WORDS + CC_ROWS * C_WORDS;
    localparam integer ACAW    = $clog2(AC_TOT);

    wire [1023:0] ac_rd;
    wire [1:0]    ac_mid_bank;
    wire [0:0]    ac_pad, cc_pad;

    wire            a_xwe, c_xwe;
    wire [ACAW-1:0] a_xwa, c_xwa, a_xra, c_xra;
    wire [1023:0]   a_xwd, c_xwd;
    wire [15:0]     a_xlane, c_xlane;

    wire            m_we;
    wire [ACAW-1:0] m_wa, m_ra;
    wire [1023:0]   m_wd;
    wire [15:0]     m_lane;
    wire            ld_can_write;

    // the read address is the only 2:1 multiplexer, and it is ACAW bits wide
    assign m_ra = role_q ? c_xra : a_xra;

    // ---- the storage: 16 lanes of 64 bits, one-cycle read ----
    reg [1023:0] acmem [0:AC_TOT-1];
    reg [1023:0] acmem_q;
    integer aci;
    always @(posedge clk) begin
        if (m_we)
            for (aci = 0; aci < 16; aci = aci + 1)
                if (m_lane[aci]) acmem[m_wa][aci*64 +: 64] <= m_wd[aci*64 +: 64];
        acmem_q <= acmem[m_ra];
    end
    assign ac_rd = acmem_q;

    twn_ring_warb #(.WIDTH(1024), .AW(ACAW), .LANES(16)) WARB (
        .clk(clk), .rst(rst),
        .a_we(a_xwe), .a_wa(a_xwa), .a_wd(a_xwd), .a_lane(a_xlane),
        // a_ready (accept a write presented this cycle) is left open; the
        // loader uses a_can, the promise for the next cycle.
        .a_ready(), .a_can(ld_can_write),
        .b_we(c_xwe), .b_wa(c_xwa), .b_wd(c_xwd), .b_lane(c_xlane),
        .m_we(m_we), .m_wa(m_wa), .m_wd(m_wd), .m_lane(m_lane),
        .b_dropped(ring_b_dropped), .a_dropped(ring_a_dropped));

    // ---- RingA: the block input, whole words from the load stage ----
    // `stride` on twn_rowbuf belongs to a WINDOW = 3 consumer (the depthwise
    // reading RB_T1). RingA is WINDOW = 1: its consumer names the exact row it
    // wants, so the stride input is tied to 0.
`ifdef FUSE_NEG_RINGA_STRIDE
    // Negative test only: the depthwise's stride on a ring that has no window.
    wire ringa_stride = s_dw;
`else
    wire ringa_stride = 1'b0;
`endif
    twn_rowbuf #(.ROW_BITS(1024), .ROW_WORDS(A_WORDS), .DEPTH(AC_ROWS),
                 .BANKS(1), .WINDOW(1),
                 .EXT_MEM(1), .MEM_BASE(0), .XAW(ACAW), .LANE_WR(0)) RB_A (
        .xm_we(a_xwe), .xm_wa(a_xwa), .xm_wd(a_xwd), .xm_lane(a_xlane),
        .xm_ra(a_xra), .xm_rd(ac_rd),
        .wr_word_i({$clog2(A_WORDS){1'b0}}), .wr_lane(16'd0), .wr_row_done(1'b0),
        // The stem's stride-2 walk is carried by e_rd_row (the input row
        // 2*e_row - 1 + seg), so the release rule frees rows up to the oldest
        // input row the next output row still needs.
        .clk(clk), .rst(rst), .blk_start(blk_start), .h_in({1'b0, h_in}), .stride(ringa_stride),
        .wr_en(ld_wr_en), .wr_data(ld_data), .wr_row_last(ld_row_last),
        .wr_ready(ac_wr_ready),
        .rd_en(gath_re & ~role_q), .rd_row(e_rd_row),
        .rd_word(gath_word[$clog2(A_WORDS)-1:0]),
        .rd_bank(), .rd_mid_bank(ac_mid_bank), .rd_bank_pad(ac_pad),
        .rd_pad_top(), .rd_pad_bot(),
        .row_done(e_done), .win_ready(), .wptr(in_wptr), .rptr(), .free(in_free));

    // ---- RingC: the depthwise output, eight bytes at a time ----
    // twn_rowbuf takes its write address from an internal counter that steps
    // on wr_en and rewinds on wr_row_done, so the row end must arrive in the
    // order the writes were made. twn_dw_pack registers its write, so the
    // write for a beat lands one cycle after the beat; d_done is undelayed.
    // dwp_row_done delays the row end by that one cycle. blk_start clears it.
    reg dwp_row_done;
    always @(posedge clk) begin
        if (rst || blk_start) dwp_row_done <= 1'b0;
        else                  dwp_row_done <= d_done;
    end

    twn_rowbuf #(.ROW_BITS(1024), .ROW_WORDS(C_WORDS), .DEPTH(CC_ROWS),
                 .BANKS(1), .WINDOW(1),
                 .EXT_MEM(1), .MEM_BASE(AC_ROWS * A_WORDS), .XAW(ACAW),
                 .LANE_WR(1)) RB_C (
        .xm_we(c_xwe), .xm_wa(c_xwa), .xm_wd(c_xwd), .xm_lane(c_xlane),
        .xm_ra(c_xra), .xm_rd(ac_rd),
        .wr_word_i(dwp_word[$clog2(C_WORDS)-1:0]), .wr_lane(dwp_lane),
`ifdef FUSE_NEG_RINGC_EARLY_ROWEND
        // Negative test only: the row end undelayed, ahead of the write it ends.
        .wr_row_done(d_done),
`else
        .wr_row_done(dwp_row_done),
`endif
        .clk(clk), .rst(rst), .blk_start(blk_start), .h_in({1'b0, h_out_w}), .stride(1'b0),
        .wr_en(dwp_we), .wr_data(dwp_data), .wr_row_last(1'b0), .wr_ready(dwp_wr_ready),
        .rd_en(gath_re & role_q), .rd_row({1'b0, p_row}),
        .rd_word(gath_word[$clog2(C_WORDS)-1:0]),
        .rd_bank(), .rd_mid_bank(), .rd_bank_pad(cc_pad),
        .rd_pad_top(), .rd_pad_bot(),
        .row_done(p_done), .win_ready(), .wptr(dw_wptr), .rptr(), .free(dw_free));

    // ---- where a depthwise output lands in RingC ----
    wire [15:0]     dwp_word, dwp_lane;
    wire [1023:0]   dwp_data;
    twn_dw_pack #(.DW_LANES(DW_LANES), .ROW_BYTES(128), .WORD_BITS(16)) DWP (
        .clk(clk), .rst(rst),
        .c_mid(c_mid), .in_valid(dw_out_valid),
        .in_x(dw_out_x), .in_tag(dw_out_tag), .in_data(dw_out),
        .wr_en(dwp_we), .wr_word(dwp_word), .wr_lane(dwp_lane), .wr_data(dwp_data));

    // ---- RB_T1: the expand's output, read as a 3-row window ----
    wire [3*128-1:0] t1_rd;
    wire [1:0]       t1_mid_bank;
    wire [2:0]       t1_pad;
    wire             t1_pad_top, t1_pad_bot;
    // MEM_SLICE (T1_SLICE) is set only on this instance; it limits the depth
    // of each physical array in the bank (see twn_rowbuf).
    twn_rowbuf #(.ROW_BITS(128), .ROW_WORDS(T1_WORDS), .DEPTH(T1_ROWS),
                 .BANKS(3), .WINDOW(3), .MEM_SLICE(T1_SLICE)) RB_T1 (
        .xm_we(), .xm_wa(), .xm_wd(), .xm_lane(), .xm_ra(),
        .xm_rd({128{1'b0}}),
        .wr_word_i({$clog2(T1_WORDS){1'b0}}), .wr_lane(16'd0),
        .wr_row_done(scat_flush_done & ~arr_out_dst),
        // h_in here is h_mid_t (the expand's output height), not h_in: for the
        // stem it is half the loader's row count. twn_rowbuf uses the height
        // for its window threshold and for the bottom-pad flag, so both must
        // see the rows this buffer actually receives.
        .clk(clk), .rst(rst), .blk_start(blk_start), .h_in(h_mid_t), .stride(s_dw),
        // wr_data is ROW_BITS (128) wide whatever BANKS is; only the owning
        // bank is enabled.
        .wr_en(scat_en & ~arr_out_dst), .wr_data(scat_data),
        .wr_row_last(1'b0), .wr_ready(t1_wr_ready),
        .rd_en(1'b1), .rd_row({1'b0, d_row}),
        .rd_word(dws_rd_word[$clog2(T1_WORDS)-1:0]),
        .rd_bank(t1_rd), .rd_mid_bank(t1_mid_bank), .rd_bank_pad(t1_pad),
        .rd_pad_top(t1_pad_top), .rd_pad_bot(t1_pad_bot),
        .row_done(d_done), .win_ready(), .wptr(t1_wptr), .rptr(t1_rptr), .free(t1_free));

    // Row rotation and padding happen here at the consumer's width (64 bits),
    // not in the 128-bit buffer.
    wire [DW_LANES*8-1:0] dw_rt, dw_rm, dw_rb;
    // ---- the depthwise's walk ----
    // twn_dwseq produces the tap-word address, the requant address, the
    // row-buffer word index and the output column with its flags.
    wire [9:0]  dws_taps_addr;
    wire [12:0] dws_rqd_addr;
    wire [15:0] dws_rd_word;
    wire        dws_rd_half;
    wire        dws_valid, dws_first, dws_last;
    wire [7:0]  dws_x, dws_tag;

    twn_dwseq #(.DW_LANES(DW_LANES), .RD_LEAD(1)) DWS (
        .clk(clk), .rst(rst),
        .c_mid(c_mid), .w_in(w_mid_t), .mb_dw(mb_dw), .mb_rqd(mb_rqd),
        .d_req(d_req),
        .taps_addr(dws_taps_addr), .rqd_addr(dws_rqd_addr),
        .rd_word(dws_rd_word), .rd_half(dws_rd_half),
        .in_valid(dws_valid), .in_x(dws_x),
        .in_first(dws_first), .in_last(dws_last), .in_tag(dws_tag));

    // the half belongs to the word that has arrived, so it is delayed with it
    reg dws_rd_half_q;
    always @(posedge clk) dws_rd_half_q <= dws_rd_half;

    // RB_T1's word is 16 bytes and the depthwise takes 8; which half depends
    // on the block's channel count.
    wire [DW_LANES*8-1:0] t1_h0 = dws_rd_half_q ? t1_rd[0*128 + 64 +: 64]
                                                : t1_rd[0*128 +: 64];
    wire [DW_LANES*8-1:0] t1_h1 = dws_rd_half_q ? t1_rd[1*128 + 64 +: 64]
                                                : t1_rd[1*128 +: 64];
    wire [DW_LANES*8-1:0] t1_h2 = dws_rd_half_q ? t1_rd[2*128 + 64 +: 64]
                                                : t1_rd[2*128 +: 64];
    twn_rowbuf_rot #(.WIDTH(DW_LANES*8), .BANKS(3)) ROT (
        .bank({t1_h2, t1_h1, t1_h0}),
        .bank_pad(t1_pad), .mid_bank(t1_mid_bank),
        .row_t(dw_rt), .row_m(dw_rm), .row_b(dw_rb));

    // The depthwise output is clamped to [0, 127] (relu) for every block.
    wire signed [15:0] dw_clamp_lo = 16'sd0;
    wire signed [15:0] dw_clamp_hi = 16'sd127;

    // ================= the depthwise =================
    wire [DW_LANES*8-1:0] dw_out;
    wire                  dw_out_valid;
    wire [7:0]            dw_out_x, dw_out_tag;
    twn_dw_array #(.DW_LANES(DW_LANES), .ROW_BITS(1024)) DW (
        .clk(clk), .rst(rst),
        .n_ch(c_mid), .w_out(w_in[7:0]), .stride(s_dw),
        .clamp_lo(dw_clamp_lo), .clamp_hi(dw_clamp_hi),
        .in_valid(dws_valid), .row_t(dw_rt), .row_m(dw_rm), .row_b(dw_rb),
        .in_x(dws_x), .in_first(dws_first), .in_last(dws_last), .in_tag(dws_tag),
        .w_taps(dw_taps),
        .m0(dw_rq_m0), .bias(dw_rq_bias), .sh(dw_rq_sh),
        .out_valid(dw_out_valid), .out_data(dw_out),
        .out_x(dw_out_x), .out_tag(dw_out_tag));

    // ================= residual add (RS stage) =================
    // Placed after the scatter, on 16 contiguous bytes of the output row. A
    // residual block has c_out == c_in and w_out == w_in, so its output row
    // has its input row's byte layout and both operands are the same 16 bytes
    // at the same word index. Blocks without a residual go through the same
    // stage with the descriptor's identity parameters (mp = 1, mq = 0, sh = 0);
    // there is no bypass path.
    //
    // The word index is counted here (res_rw), not taken from the scatter's
    // wr_word, which does not restart at row boundaries. It steps on a
    // project-stage write and rewinds on that row's end; the row end wins if
    // both coincide.
    reg [15:0] res_rw;
    always @(posedge clk) begin
        if (rst || blk_start)                    res_rw <= 16'd0;
        else if (scat_flush_done & arr_out_dst)  res_rw <= 16'd0;
        else if (scat_en & arr_out_dst)          res_rw <= res_rw + 16'd1;
    end

    wire [127:0] res_x;
    twn_res_buf #(.ROW_BITS(128), .ROW_WORDS(96), .DEPTH(RES_DEPTH)) RESB (
        .clk(clk), .rst(rst), .blk_start(blk_start),
        // written from the loader's beats as they stream past
        .wr_en(ld_beat_valid), .wr_data(ld_beat_data), .wr_row_done(ld_done),
        // has_res is part of the read enable: rd_en arms the stale detector,
        // and blocks with no residual never use the data.
        .rd_en(scat_en & arr_out_dst & has_res), .rd_word(res_rw),
        // the same row boundary as RB_OU's write pointer, undelayed
        .rd_row_done(scat_flush_done & arr_out_dst),
        .rd_data(res_x), .stale(res_stale));

    // One cycle for the buffer to answer, then four through twn_res_add. The
    // row end must stay in order with the writes it ends, so rs_fl delays it
    // by the same five cycles as the data. blk_start clears the pipeline so
    // that nothing from one block reaches the next.
    reg          rs_v1;
    reg  [127:0] rs_p1;
    reg  [4:0]   rs_fl;
    always @(posedge clk) begin
        if (rst || blk_start) begin rs_v1 <= 1'b0; rs_fl <= 5'd0; end
        else begin
            rs_v1 <= scat_en & arr_out_dst;
            rs_fl <= {rs_fl[3:0], scat_flush_done & arr_out_dst};
        end
        rs_p1 <= scat_data;
    end

    // Sixteen bytes in, sixteen out; both operands are signed 8-bit and are
    // sign-extended. x is forced to zero when the block has no residual, since
    // X * 0 is X in simulation and that block reads a word nothing wrote.
    wire [16*16-1:0] res_p_in, res_x_in;
    wire [16*8-1:0]  res_out;
    genvar gr;
    generate
        for (gr = 0; gr < 16; gr = gr + 1) begin : g_res
            assign res_p_in[gr*16 +: 16] = {{8{rs_p1[gr*8+7]}}, rs_p1[gr*8 +: 8]};
            assign res_x_in[gr*16 +: 16] = has_res
                                         ? {{8{res_x[gr*8+7]}}, res_x[gr*8 +: 8]}
                                         : 16'sd0;
        end
    endgenerate

    twn_res_add #(.LANES(16)) RES (
        .clk(clk), .rst(rst),
        .mp(mp_res), .mq(mq_res), .sh(sh_res), .lo(lo_res), .hi(hi_res),
        .in_valid(rs_v1), .p_in(res_p_in), .x_in(res_x_in), .in_tag(8'd0),
        .out_valid(res_out_valid), .out_data(res_out), .out_tag());

    // ---- RB_OU: the project's output rows, staged for the DDR write ----
    wire [127:0] ou_rd;
    twn_rowbuf #(.ROW_BITS(128), .ROW_WORDS(OU_WORDS), .DEPTH(2),
                 .BANKS(1), .WINDOW(1)) RB_OU (
        .xm_we(), .xm_wa(), .xm_wd(), .xm_lane(), .xm_ra(),
        .xm_rd({128{1'b0}}),
        .wr_word_i({$clog2(OU_WORDS){1'b0}}), .wr_lane(16'd0),
        .wr_row_done(rs_fl[4]),
        .clk(clk), .rst(rst), .blk_start(blk_start), .h_in({1'b0, h_in}), .stride(1'b0),
        .wr_en(res_out_valid), .wr_data(res_out),
        .wr_row_last(1'b0), .wr_ready(ou_wr_ready),
        .rd_en(ou_re), .rd_row({1'b0, st_row}),
        .rd_word(ou_word[$clog2(OU_WORDS)-1:0]),
        .rd_bank(ou_rd), .rd_mid_bank(), .rd_bank_pad(),
        .rd_pad_top(), .rd_pad_bot(),
        .row_done(st_done), .win_ready(), .wptr(), .rptr(), .free(out_free));


    genvar gj;
    generate
        for (gj = 0; gj < OCMAX; gj = gj + 1) begin : g_rqa
            assign arr_rq_m0  [gj*18 +: 18] = rq_word[gj*64      +: 18];
            assign arr_rq_bias[gj*40 +: 40] = rq_word[gj*64 + 18  +: 40];
            assign arr_rq_sh  [gj*6  +:  6] = rq_word[gj*64 + 58  +: 6];
        end
        for (gj = 0; gj < DW_LANES; gj = gj + 1) begin : g_rqd
            assign dw_rq_m0  [gj*18 +: 18] = rqd_word[gj*56      +: 18];
            assign dw_rq_bias[gj*32 +: 32] = rqd_word[gj*56 + 18 +: 32];
            assign dw_rq_sh  [gj*6  +:  6] = rqd_word[gj*56 + 50 +:  6];
        end
    endgenerate

    // ---- stage completion ----
    assign e_done     = arr_done & ~arr_out_dst;
    assign p_done     = arr_done &  arr_out_dst;

    // d_done marks a depthwise ROW: the last lane group of the last output
    // column. The depthwise's row is the expand's output, which the stem
    // halves, so the last column index comes from w_mid_t (and from the
    // stride for s_dw). This must agree with the column count twn_dwseq walks.
    wire [7:0] dw_n_lg_m1  = (((c_mid + DW_LANES[9:0] - 10'd1) / DW_LANES[9:0])
                              - 10'd1);
    wire [7:0] dw_w_out_m1 = ((s_dw ? {1'b0, w_mid_t[8:1]} : w_mid_t) - 9'd1);
    assign d_done = dw_out_valid && (dw_out_tag == dw_n_lg_m1)
                                 && (dw_out_x   == dw_w_out_m1);

    // RB_C's height: the depthwise output rows (halved by stride 2).
    wire [8:0] h_out_w = s_dw ? {1'b0, h_in[8:1]} : h_in;

    assign o_ac_rd    = ac_rd;
    assign o_dw_data  = dw_out;
    assign o_dw_valid = dw_out_valid;
    assign o_dw_x     = dw_out_x;
    assign o_dw_tag   = dw_out_tag;
    assign o_act_addr = act_addr;
    assign o_act_re   = act_re;
    assign o_w_addr   = w_addr;
    assign o_w_re     = w_re;
    assign o_arr_busy = arr_busy;
    assign o_ld_row   = ld_row;
    assign o_t1_pad   = {t1_pad_top, t1_pad_bot, ac_mid_bank[0] ^ ac_pad[0]};
    // Descriptor fields the datapath does not otherwise read. res_slot is read
    // only here: RESB is written from the loader's own beats, so the residual
    // row arrives through in_slot and res_slot is not used.
    assign o_desc_rest = {res_slot, has_res, out_ptr[7:0], n_blocks,
                          d_err_code, d_err_block, d_check_busy};

    // ================= the head engine =================
    // Built when HD_PROBE != 0: operator sequencer, three AXI movers and the
    // compute engine, running concurrently with the backbone. o_hd_probe is an
    // XOR fold of their signals so that every one has a load.
generate if (HD_PROBE != 0) begin : g_hd_probe
    wire        hdp_done;
    wire        hdp_out_sv;
    wire [127:0] hdp_out_sd;
    // twn_hd_compute.in_sr/w_sr are outputs and are the readers' s_ready
    // inputs: one net each (hdp_in_sr, hdp_w_sr), not two.
    // hdp_lfsr gives the output sink a varying ready pattern so synthesis
    // cannot simplify the output handshake away.
    reg [7:0] hdp_lfsr;
    always @(posedge clk) if (rst) hdp_lfsr <= 8'h5a;
                          else     hdp_lfsr <= {hdp_lfsr[6:0],
                                                hdp_lfsr[7] ^ hdp_lfsr[5] ^ hdp_lfsr[4] ^ hdp_lfsr[3]};
    wire        hin_sv, hw_sv, hdp_out_sr_w;
    wire        hdp_in_sr, hdp_w_sr;   // engine ready == reader s_ready
    wire [127:0] hin_sd, hw_sd;
    wire        hrd_busy, hrd_done, hwf_busy, hwf_done, hwr_busy, hwr_done;
    wire [39:0] hrd_ar, hwf_ar, hwr_aw;
    wire [7:0]  hrd_len, hwf_len, hwr_len;
    wire        hrd_arv, hwf_arv, hwr_awv, hwr_wv, hwr_wl;
    wire [127:0] hwr_wd;
    wire [15:0]  hwr_ws;
    wire [2:0]  hrd_sz, hwf_sz, hwr_sz;  wire [1:0] hrd_bu, hwf_bu, hwr_bu;
    wire [3:0]  hrd_ca, hwf_ca, hwr_ca;  wire [2:0] hrd_pr, hwf_pr, hwr_pr;
    wire        hrd_rr, hwf_rr, hwr_br;

    // Double-buffer bit: the head works on one boundary slot while the array
    // fills the other. Flips on the sequencer's done (all four operators).
    reg  hd_slot;
    wire [1:0] hdseq_op;
    always @(posedge clk) begin
        if (rst)             hd_slot <= 1'b0;
        else if (hdseq_done) hd_slot <= ~hd_slot;
    end

    // ---- BB2HD: the head's latched slot (bb2hd_f and bb_par are at AWR) ----
    //  hd_sel    latched when the sequencer takes hd_start: ~bb_par, i.e. the
    //            slot the backbone that finished most recently wrote. It stays
    //            fixed for the whole head walk. hd_slot cannot serve here: it
    //            counts head dones and drifts from the backbone's count when a
    //            head run is skipped.
    //  hd_en_l   A_BB2HD[0] sampled at the same moment; selects which offsets
    //            the head uses below.
    reg hd_sel_r, hd_en_r;
    always @(posedge clk) begin
        if (rst) begin
            hd_sel_r <= 1'b0; hd_en_r <= 1'b0;
        end else if (hd_start && !hdseq_busy) begin
            // FUSE_NEG_BB2HD_HDSEL (break test): the head takes the slot the
            // next backbone will write instead of the last one written.
`ifdef FUSE_NEG_BB2HD_HDSEL
            hd_sel_r <=  bb_par;
`else
            hd_sel_r <= ~bb_par;
`endif
            hd_en_r  <= bb2hd_en;
        end
    end
    assign hd_sel  = hd_sel_r;
    assign hd_en_l = hd_en_r;
    // Collision pulse: the last block starts a row into the slot a running
    // bb2hd head was given (reported sticky in A_BB2HD[3]).
    assign bb2hd_coll = st_req && awr_use_ptr && hdseq_busy && hd_en_l
                        && (hd_sel == bb_par);

    // op61's input slot offset and op64's output offset. Enable off: hd_slot
    // selects the input slot and the output offset is 0. Enable on: both follow
    // hd_sel, and op64's output moves by 0x40000 when hd_sel is 1.
    wire [39:0] hd_in_off  = hd_en_l ? {23'd0, hd_sel, 16'd0} : {23'd0, hd_slot, 16'd0};
    wire [39:0] hd_out_off = (hd_en_l && hd_sel && (hdseq_op == 2'd3)) ? 40'h4_0000 : 40'd0;
    wire [39:0] hs_out_base_seq;

    // Operator walk: descriptors arrive through the CSR descriptor-write port.
    wire [39:0] hs_in_base, hs_w_base, hs_out_base;
    assign hs_out_base = hs_out_base_seq + hd_out_off;   // BB2HD: op64's box
    wire [23:0] hs_in_beats, hs_w_beats, hs_out_beats;
    wire        hs_in_start, hs_w_start, hs_out_start, hs_e_start;
    wire [8:0]  hs_ic;  wire [5:0] hs_oc;  wire [6:0] hs_h, hs_w;
    wire        hs_mode_a, hs_type4, hs_relu;
    wire signed [15:0] hs_lo, hs_hi;
    // The sequencer's replay of the requantisation table into the engine.
    wire        hs_m0_we, hs_bias_we, hs_sh_we;
    wire [9:0]  hs_rq_wa;
    wire signed [31:0] hs_m0_wd;
    wire signed [63:0] hs_bias_wd;
    wire [5:0]  hs_sh_wd;
    twn_hd_seq #(.NOPS(4)) HSEQ (
        // hd_start, not ap_start: the head runs on its own start so it can
        // overlap the backbone.
        .clk(clk), .rst(rst), .start(hd_start),
        .busy(hdseq_busy), .done(hdseq_done), .cur_op(hdseq_op),
        .d_we(hd_d_we), .d_wa(hd_d_wa),
        .d_in_base(hd_d_in_base), .d_w_base(hd_d_w_base),
        .d_out_base(hd_d_out_base),
        .d_in_beats(hd_d_in_beats), .d_w_beats(hd_d_w_beats),
        .d_out_beats(hd_d_out_beats),
        .d_ic(hd_d_ic), .d_oc(hd_d_oc), .d_h(hd_d_h), .d_w(hd_d_w),
        .d_type4(hd_d_type4), .d_slice(hd_d_slice), .d_relu(hd_d_relu),
        .d_lo(hd_d_lo), .d_hi(hd_d_hi),
        // requantisation table write port: its own CSR window, separate from
        // the block descriptor table's
        .rq_we(hd_rq_we), .rq_wa(hd_rq_wa), .rq_wd(hd_rq_wd),
        .slot_off(hd_in_off),
        .m_in_base(hs_in_base), .m_in_beats(hs_in_beats),
        .m_w_base(hs_w_base), .m_w_beats(hs_w_beats),
        .m_out_base(hs_out_base_seq), .m_out_beats(hs_out_beats),
        .m_in_start(hs_in_start), .m_w_start(hs_w_start), .m_out_start(hs_out_start),
        .m_in_done(hrd_done), .m_out_done(hwr_done),
        .e_start(hs_e_start), .e_done(hdp_done),
        .e_ic(hs_ic), .e_oc(hs_oc), .e_h(hs_h), .e_w(hs_w),
        .e_mode_a(hs_mode_a), .e_type4(hs_type4), .e_relu(hs_relu),
        .e_lo(hs_lo), .e_hi(hs_hi),
        .e_m0_we(hs_m0_we), .e_rq_wa(hs_rq_wa), .e_m0_wd(hs_m0_wd),
        .e_bias_we(hs_bias_we), .e_bias_wd(hs_bias_wd),
        .e_sh_we(hs_sh_we), .e_sh_wd(hs_sh_wd));

    // The three movers: HRD reads the head's input, HWF reads its weights,
    // HWR writes its output. Each is connected to its own master channel.
    twn_axi_rd #(.ADDR_W(40), .DATA_W(128)) HRD (
        .clk(clk), .rstn(~rst), .start(hs_in_start), .base(hs_in_base),
        .nbeats(hs_in_beats), .busy(hrd_busy), .done(hrd_done),
        .s_valid(hin_sv), .s_ready(hdp_in_sr), .s_data(hin_sd),
        .araddr(hrd_ar), .arlen(hrd_len), .arsize(hrd_sz), .arburst(hrd_bu),
        .arcache(hrd_ca), .arprot(hrd_pr), .arvalid(hrd_arv), .arready(ha_arready),
        .rdata(ha_rdata), .rresp(ha_rresp), .rlast(ha_rlast), .rvalid(ha_rvalid),
        .rready(hrd_rr));
    twn_axi_rd #(.ADDR_W(40), .DATA_W(128)) HWF (
        .clk(clk), .rstn(~rst), .start(hs_w_start), .base(hs_w_base),
        .nbeats(hs_w_beats), .busy(hwf_busy), .done(hwf_done),
        .s_valid(hw_sv), .s_ready(hdp_w_sr), .s_data(hw_sd),
        .araddr(hwf_ar), .arlen(hwf_len), .arsize(hwf_sz), .arburst(hwf_bu),
        .arcache(hwf_ca), .arprot(hwf_pr), .arvalid(hwf_arv), .arready(hwt_arready),
        .rdata(hwt_rdata), .rresp(hwt_rresp), .rlast(hwt_rlast), .rvalid(hwt_rvalid),
        .rready(hwf_rr));
    twn_axi_wr #(.ADDR_W(40), .DATA_W(128)) HWR (
        .clk(clk), .rstn(~rst), .start(hs_out_start), .base(hs_out_base),
        .nbeats(hs_out_beats), .busy(hwr_busy), .done(hwr_done),
        .w_valid(hdp_out_sv), .w_ready(hdp_out_sr_w), .w_data(hdp_out_sd),
        .awaddr(hwr_aw), .awlen(hwr_len), .awsize(hwr_sz), .awburst(hwr_bu),
        .awcache(hwr_ca), .awprot(hwr_pr), .awvalid(hwr_awv), .awready(ha_awready),
        .wdata(hwr_wd), .wstrb(hwr_ws), .wlast(hwr_wl), .wvalid(hwr_wv),
        .wready(ha_wready), .bresp(ha_bresp), .bvalid(ha_bvalid), .bready(hwr_br));

    // ---- the head's masters, driven from the movers ----
    // The reader and the writer share the ha_* group (independent AXI channels).
    assign ha_araddr  = hrd_ar;
    assign ha_arlen   = hrd_len;
    assign ha_arsize  = hrd_sz;
    assign ha_arburst = hrd_bu;
    assign ha_arcache = hrd_ca;
    assign ha_arprot  = hrd_pr;
    assign ha_arvalid = hrd_arv;
    assign ha_rready  = hrd_rr;

    assign ha_awaddr  = hwr_aw;
    assign ha_awlen   = hwr_len;
    assign ha_awsize  = hwr_sz;
    assign ha_awburst = hwr_bu;
    assign ha_awcache = hwr_ca;
    assign ha_awprot  = hwr_pr;
    assign ha_awvalid = hwr_awv;
    assign ha_wdata   = hwr_wd;
    assign ha_wstrb   = hwr_ws;
    assign ha_wlast   = hwr_wl;
    assign ha_wvalid  = hwr_wv;
    assign ha_bready  = hwr_br;

    assign hwt_araddr  = hwf_ar;
    assign hwt_arlen   = hwf_len;
    assign hwt_arsize  = hwf_sz;
    assign hwt_arburst = hwf_bu;
    assign hwt_arcache = hwf_ca;
    assign hwt_arprot  = hwf_pr;
    assign hwt_arvalid = hwf_arv;
    assign hwt_rready  = hwf_rr;

    twn_hd_compute HDP (
        .clk(clk), .rst(rst),
        .start   (hs_e_start),
        .done    (hdp_done),
        // operator configuration from the sequencer's descriptors
        .IC_i    (hs_ic),
        .OC_i    (hs_oc),
        .H_i     (hs_h),
        .W_i     (hs_w),
        .mode_a  (hs_mode_a),
        .type4   (hs_type4),
        .relu_i  (hs_relu),
        .lo_i    (hs_lo),
        .hi_i    (hs_hi),
        // input and weight streams from the movers
        .in_sv   (hin_sv), .in_sr(hdp_in_sr), .in_sd(hin_sd),
        .w_sv    (hw_sv),  .w_sr(hdp_w_sr),   .w_sd(hw_sd),
        // Requantisation tables, replayed per operator by the sequencer (its
        // S_RQ state streams the current operator's entries in before the
        // operator starts). The three write enables and data buses are
        // independent.
        .m0_we   (hs_m0_we),   .rq_wa(hs_rq_wa),
        .m0_wd   (hs_m0_wd),
        .bias_we (hs_bias_we), .bias_wd(hs_bias_wd),
        .sh_we   (hs_sh_we),   .sh_wd(hs_sh_wd),
        // back-pressure comes from the writer
        .out_sv  (hdp_out_sv), .out_sr(hdp_out_sr_w), .out_sd(hdp_out_sd)
    );
    // Registered XOR fold of the head's signals: the movers' AXI outputs, the
    // operator walk and both ends of the requantisation write path. It exists
    // so each of them has a load; it is registered so that it is never the
    // critical path.
    reg [31:0] hdp_fold;
    always @(posedge clk) begin
        if (rst) hdp_fold <= 32'd0;
        else hdp_fold <= {hdp_fold[30:0], 1'b0} ^
                         {24'd0, hdp_done, hdp_out_sv, hdp_in_sr, hdp_w_sr, 4'd0} ^
                         hdp_out_sd[31:0] ^ hdp_out_sd[63:32] ^
                         hdp_out_sd[95:64] ^ hdp_out_sd[127:96] ^
                         hrd_ar[31:0] ^ hwf_ar[31:0] ^ hwr_aw[31:0] ^
                         hwr_wd[31:0] ^ hwr_wd[127:96] ^
                         {8'd0, hrd_len} ^ {8'd0, hwf_len} ^ {8'd0, hwr_len} ^
                         {16'd0, hwr_ws} ^
                         {24'd0, hrd_arv, hwf_arv, hwr_awv, hwr_wv, hwr_wl,
                                 hrd_rr, hwf_rr, hwr_br} ^
                         {24'd0, hrd_busy, hrd_done, hwf_busy, hwf_done,
                                 hwr_busy, hwr_done, hd_slot, hdseq_busy} ^
                         {8'd0, hrd_ar[39:32], hwf_ar[39:32], hwr_aw[39:32]} ^
                         {20'd0, hrd_sz, hrd_bu, hrd_ca[3:1]} ^
                         {20'd0, hwf_sz, hwf_bu, hwf_ca[3:1]} ^
                         {20'd0, hwr_sz, hwr_bu, hwr_ca[3:1]} ^
                         {26'd0, hrd_pr, hwf_pr} ^ {29'd0, hwr_pr} ^
                         {31'd0, hdp_lfsr[0]} ^
                         {24'd0, hdseq_busy, hdseq_done, hdseq_op, hd_slot,
                                 hs_in_start, hs_w_start, hs_out_start} ^
                         hs_in_base[31:0] ^ hs_out_base[31:0] ^
                         {8'd0, hs_in_beats} ^ {8'd0, hs_out_beats} ^
                         {17'd0, hs_ic, hs_mode_a, hs_type4, hs_relu, hs_e_start} ^
                         {13'd0, hs_oc, hs_h, hs_w, 6'd0} ^
                         // the requantisation write path (the memory's write
                         // side needs a load as well as its read side)
                         {23'd0, hs_m0_we, hs_bias_we, hs_sh_we, hd_rq_we, 5'd0} ^
                         hs_m0_wd[31:0] ^ hs_bias_wd[39:8] ^ hd_rq_wd ^
                         {8'd0, hs_rq_wa, hd_rq_wa, hs_sh_wd};
    end
    assign o_hd_probe = hdp_fold;
end else begin : g_no_hd_probe
    assign o_hd_probe = 32'd0;
    // no head: no head slot and no guard
    assign hd_sel = 1'b0;  assign hd_en_l = 1'b0;  assign bb2hd_coll = 1'b0;
    // No head, so the HP2 masters have no requester; drive them quiet rather
    // than leave outputs undriven.
    assign ha_araddr  = 40'd0;  assign ha_arlen  = 8'd0;
    assign ha_arsize  = 3'd0;   assign ha_arburst= 2'd0;
    assign ha_arcache = 4'd0;   assign ha_arprot = 3'd0;
    assign ha_arvalid = 1'b0;   assign ha_rready = 1'b0;
    assign ha_awaddr  = 40'd0;  assign ha_awlen  = 8'd0;
    assign ha_awsize  = 3'd0;   assign ha_awburst= 2'd0;
    assign ha_awcache = 4'd0;   assign ha_awprot = 3'd0;
    assign ha_awvalid = 1'b0;
    assign ha_wdata   = 128'd0; assign ha_wstrb  = 16'd0;
    assign ha_wlast   = 1'b0;   assign ha_wvalid = 1'b0;
    assign ha_bready  = 1'b0;
    assign hwt_araddr  = 40'd0; assign hwt_arlen  = 8'd0;
    assign hwt_arsize  = 3'd0;  assign hwt_arburst= 2'd0;
    assign hwt_arcache = 4'd0;  assign hwt_arprot = 3'd0;
    assign hwt_arvalid = 1'b0;  assign hwt_rready = 1'b0;
end endgenerate

endmodule
`default_nettype wire
