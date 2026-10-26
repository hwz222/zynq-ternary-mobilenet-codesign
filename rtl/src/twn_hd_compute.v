`timescale 1ns/1ps
// ============================================================================
//  twn_hd_compute.v -- head compute engine, int8 NHWC. One operator per start:
//    type 2 : transposed convolution 4x4, stride 2, pad 1 (OH = 2H, OW = 2W), with
//             per-output-channel requantisation (m0, bias, shift), optional ReLU and
//             clamp to [lo, hi]. Two weight modes:
//               mode B (mode_a = 0): all 16 kernel taps are loaded into four weight banks
//                       first; the output is then produced and drained row by row.
//               mode A (mode_a = 1): weights arrive as one slice per (phase, oc-group); the
//                       input is streamed again for every slice and the whole output tensor
//                       is assembled in the row output buffer, then drained once.
//    type 4 : final 1x1 convolution, raw int32 outputs, no requantisation.
//  Terms: oc-group (OCG) = 8 output channels. Phase (py,px) = (oy&1, ox&1) of an output
//  pixel. Tap = one of the 4 kernel positions a phase uses. Window = 8 input channels of
//  a 2-row x 3-column input patch. Batch = 2 adjacent output pixels x 8 output channels.
//  Interface: a one-cycle `start` in idle latches the descriptor inputs (IC_i .. hi_i);
//  `done` is a one-cycle pulse and the engine returns to idle. A start in any other
//  state is a simulation error. in/w/out are valid/ready streams of 128-bit beats.
// ============================================================================
`default_nettype none
module twn_hd_compute #(
    parameter LBD = 512                 // line-buffer slot depth (64b words)
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    output reg          done,
    // ---- descriptor, sampled on start ----
    input  wire [8:0]   IC_i,           // input channels, multiple of 16 (type 4: 32)
    input  wire [5:0]   OC_i,           // output channels, multiple of 8 (type 4: at most 16)
    input  wire [6:0]   H_i,            // input rows (type 2: OH = 2H; type 4: full H)
    input  wire [6:0]   W_i,            // input cols (type 2: OW = 2W; type 4: full W)
    input  wire         mode_a,         // type 2 weight mode: 1 = mode A (slice stream)
    input  wire         type4,          // final 1x1: [OC][IC] weights, raw int32 out
    input  wire         relu_i,
    input  wire signed [15:0] lo_i,     // output clamp
    input  wire signed [15:0] hi_i,
    // ---- streams ----
    // in : NHWC bytes [iy][ix][ic], 16 per beat.
    // w  : mode B = bytes w[ky][kx][ic][oc], oc fastest. mode A = per slice, for each ic,
    //      4 taps x 8 bytes (8 oc). type 4 = bytes w[oc][ic].
    // out: type 2 = int8 NHWC row-major, 16 per beat; type 4 = 4 int32 channels per beat.
    input  wire         in_sv,
    output wire         in_sr,
    input  wire [127:0] in_sd,
    input  wire         w_sv,
    output wire         w_sr,
    input  wire [127:0] w_sd,
    // ---- requantisation table write port (entry rq_wa[4:0]) ----
    // m0 is stored as signed 18 bits, bias as signed 40 bits; sim checks that they fit.
    input  wire         m0_we,
    input  wire [9:0]   rq_wa,
    input  wire signed [31:0] m0_wd,
    input  wire         bias_we,
    input  wire signed [63:0] bias_wd,
    input  wire         sh_we,
    input  wire [5:0]   sh_wd,
    output reg          out_sv,
    input  wire         out_sr,
    output reg  [127:0] out_sd
);
    // ---------------- requantisation tables (one entry per output channel) ----------------
    reg signed [17:0] rq_m0  [0:31];
    reg signed [39:0] rq_bias[0:31];
    reg        [5:0]  rq_sh  [0:31];
    always @(posedge clk) begin
        if (m0_we)   rq_m0  [rq_wa[4:0]] <= m0_wd[17:0];
        if (bias_we) rq_bias[rq_wa[4:0]] <= bias_wd[39:0];
        if (sh_we)   rq_sh  [rq_wa[4:0]] <= sh_wd;
    end
    // synthesis translate_off
    always @(posedge clk) if (m0_we && !(&m0_wd[31:17] || ~|m0_wd[31:17])) begin
        $display("FAIL hd rq contract: m0=%0d does not fit signed 18 bits", m0_wd); $finish;
    end
    always @(posedge clk) if (bias_we && !(&bias_wd[63:39] || ~|bias_wd[63:39])) begin
        $display("FAIL hd rq contract: bias=%0d does not fit signed 40 bits", bias_wd); $finish;
    end
    // synthesis translate_on

    // ---------------- latched descriptor ----------------
    reg [8:0] IC; reg [5:0] OC; reg [6:0] H; reg [6:0] W;
`ifdef HD_PRECOMP
    // Experiment define: registers H*W-1 once per operator for the type-4 pixel-count compare.
    reg [13:0] hw_last;
    initial $display("%m: HD_PRECOMP is ON");
`endif
`ifdef HD_MAXFO
    initial $display("%m: HD_MAXFO is ON");
`endif
    reg relu; reg signed [15:0] lo, hi;
    reg [5:0] ICW;                       // IC/8
    reg [2:0] OCG;                       // OC/8
    reg is_t4;                           // latched type4 (stream-mux select)
    // is_ma is latched once per operator and gates many signals; the HD_MAXFO experiment
    // define asks synthesis to replicate it.
`ifdef HD_MAXFO
    (* max_fanout = 16 *)
`endif
    reg is_ma;                           // latched mode A
    wire t4_w_sr, t4_in_sr;              // type-4 stream readies (driven below)
    wire [7:0] OH = {H, 1'b0};
    wire [7:0] OW = {W, 1'b0};

    // ---------------- top state machine ----------------
    // S_ASLICE (mode A): per (phase, oc-group) slice, refill the four weight banks from the
    // weight stream (bank address = ic) and restart the input pass. The R_* compute
    // machine below is shared by both modes.
    localparam S_IDLE = 3'd0, S_PREP = 3'd1, S_ROW = 3'd2, S_RUN = 3'd3,
               S_T4 = 3'd4, S_DRAIN = 3'd5, S_FIN = 3'd6, S_ASLICE = 3'd7;
    reg [2:0] st;
    reg want_drain;   // last batch handed to the requant chain; enter S_DRAIN once the chain is empty
    reg [6:0] oy;                        // output row (mode B)
    reg [1:0] a_ph;                      // mode A phase {py,px}
    reg [5:0] a_oyh;                     // mode A phase-grid row
    wire       py  = is_ma ? a_ph[1] : oy[0];
    wire [5:0] oyh = is_ma ? a_oyh : oy[6:1];

    // ================= input row line buffer (4 slots, LBD words each) =================
    // slot = row & 3. The loader runs in parallel with compute; row L may load only when
    // L <= oyh + 2, because the slot of row L-4 is then no longer needed.
    // lb_loaded = number of complete rows loaded.
    reg  [8:0]  lb_loaded;
    reg         in_bv;                   // captured beat present
    reg  [127:0] in_beat;
    reg         in_half;                 // which 64b half is being written
    reg  [9:0]  ld_off;                  // word offset within the row
    wire [9:0]  row_words = W * ICW;     // 64b words per row
`ifdef HD_LDALLOW_COMB
    wire [8:0]  ld_allow = {3'b0, oyh} + 9'd2;
    initial $display("%m: ld_allow = combinational (HD_LDALLOW_COMB is ON)");
`else
    // Registered copy of oyh + 2, updated at every place oyh changes (idle start, slice
    // start, mode A next row, mode B next row), so it equals the combinational expression
    // in every cycle while keeping the mux and adder off the in_sr path.
    reg  [8:0]  ld_allow_r;
    wire [8:0]  ld_allow = ld_allow_r;
    initial $display("%m: ld_allow = shadow register");
`endif
    wire        a_lrst;                  // mode A: restart the input pass (slice start)
    // in_sr must drop during the slice-start pulse: the loader's reset branch discards
    // any beat accepted in that cycle.
    wire        ld_ok = (lb_loaded < {2'b0, H}) && (st != S_IDLE) && !is_t4 && !a_lrst &&
                        ((st == S_PREP || st == S_ASLICE) ? (lb_loaded < 9'd3)
                                                         : (lb_loaded <= ld_allow));
    assign in_sr = is_t4 ? t4_in_sr : (ld_ok && !in_bv);
    wire        lb_we = in_bv;
    wire [63:0] lb_wd = in_half ? in_beat[127:64] : in_beat[63:0];
    wire [10:0] lb_wa = {lb_loaded[1:0], 9'b0} + {1'b0, ld_off};
    always @(posedge clk) begin
        if (rst || st == S_IDLE || a_lrst) begin
            in_bv <= 0; in_half <= 0; ld_off <= 0; lb_loaded <= 0;
        end else begin
            if (in_sv && in_sr) begin in_beat <= in_sd; in_bv <= 1; in_half <= 0; end
            else if (in_bv && !in_half) in_half <= 1;
            else if (in_bv &&  in_half) begin in_bv <= 0; in_half <= 0; end
            if (in_bv) begin                       // one 64b word lands per cycle
                if (ld_off == row_words - 1) begin ld_off <= 0; lb_loaded <= lb_loaded + 1; end
                else ld_off <= ld_off + 1;
            end
        end
    end
    // row_words is even (IC % 16 == 0), so a beat never straddles rows and the row wrap
    // always lands on a beat's high half.
    // ---- line buffer split by row parity ----
    // A window's two source rows iyA and iyB = iyA-1 have opposite parity, so they sit in
    // different halves and can be read in the same cycle. Address bit 9 of lb_wa is the
    // row parity (which half); {bit 10, bits 8:0} is the address inside the half.
    reg  [10:0] lb_ra0;
    wire [63:0] lb_rd0, lb_rd0_o;
    wire [9:0]  lb_wa_h = {lb_wa[10], lb_wa[8:0]};
    wire        lb_we_e = lb_we && !lb_wa[9];
    wire        lb_we_o = lb_we &&  lb_wa[9];
    reg  [9:0]  lb_ra_e, lb_ra_o;                 // one read per half, same cycle
    wire [63:0] lb_rd_e, lb_rd_o;
    bram_tdp #(64, 2*LBD, 10) lbmem_e (.clk(clk),
        .ena(1'b1), .wea(lb_we_e), .aa(lb_we_e ? lb_wa_h : lb_ra0[9:0]), .wd(lb_wd), .rda(lb_rd0),
        .enb(1'b1), .ab(lb_ra_e), .rdb(lb_rd_e));
    bram_tdp #(64, 2*LBD, 10) lbmem_o (.clk(clk),
        .ena(1'b1), .wea(lb_we_o), .aa(lb_we_o ? lb_wa_h : lb_ra0[9:0]), .wd(lb_wd), .rda(lb_rd0_o),
        .enb(1'b1), .ab(lb_ra_o), .rdb(lb_rd_o));

    // ================= weight banks =================
    // Tap t = {ty,tx} (1 = the higher input offset) reads bank {!ty,!tx}, which is bank
    // {ky[1],kx[1]} of the kernel. Mode B in-bank address =
    // ((tidx * IC + ic) * OCG + ocg), tidx = {ky[0],kx[0]}; it is the same for all 4 banks.
    reg         w_bv; reg [127:0] w_beat; reg w_half;
    reg  [2:0]  wl_ocg; reg [8:0] wl_ic; reg [4:0] wl_tap;   // tap 0..15
    reg         w_loaded;
    // Mode A slice fill: the stream order per slice is, for each ic, taps t = 0..3 as
    // 8-byte groups; tap t lands in bank ~t, address = ic.
    reg  [1:0] a_wt; reg [8:0] a_wic; reg a_bv, a_half; reg [127:0] a_beat;
    reg        a_wdone;
    wire       a_w_sr = (st == S_ASLICE) && !a_wdone && !a_bv;
    assign w_sr = is_t4 ? t4_w_sr :
                  is_ma ? a_w_sr : ((st == S_PREP) && !w_loaded && !w_bv);
    wire [1:0]  wl_bank = {wl_tap[3], wl_tap[1]};
    wire [1:0]  wl_tidx = {wl_tap[2], wl_tap[0]};
    // tidx*IC with tidx 2b: (tidx[1] ? IC<<1 : 0) + (tidx[0] ? IC : 0)
    wire [10:0] wl_base = (wl_tidx[1] ? {1'b0, IC, 1'b0} : 11'd0) + (wl_tidx[0] ? {2'b0, IC} : 11'd0);
    wire [10:0] wl_row  = wl_base + {2'b0, wl_ic};
    wire [13:0] wl_addr = wl_row * OCG + {11'b0, wl_ocg};
    wire [63:0] wb_wd   = is_ma ? (a_half ? a_beat[127:64] : a_beat[63:0])
                                : (w_half ? w_beat[127:64] : w_beat[63:0]);
    wire [3:0]  wb_we   = is_ma ? (a_bv ? (4'b0001 << (~a_wt)) : 4'b0000)
                                : (w_bv ? (4'b0001 << wl_bank) : 4'b0000);
    wire [8:0]  wb_wa   = is_ma ? a_wic : wl_addr[8:0];
    reg  [8:0]  wb_ra;                   // shared read addr (all four banks)
    wire [63:0] wb_rd [0:3];
    bram_sdp #(64, 512, 9) wbank0 (.clk(clk),.we(wb_we[0]),.wa(wb_wa),.wd(wb_wd),.ra(wb_ra),.rd(wb_rd[0]));
    bram_sdp #(64, 512, 9) wbank1 (.clk(clk),.we(wb_we[1]),.wa(wb_wa),.wd(wb_wd),.ra(wb_ra),.rd(wb_rd[1]));
    bram_sdp #(64, 512, 9) wbank2 (.clk(clk),.we(wb_we[2]),.wa(wb_wa),.wd(wb_wd),.ra(wb_ra),.rd(wb_rd[2]));
    bram_sdp #(64, 512, 9) wbank3 (.clk(clk),.we(wb_we[3]),.wa(wb_wa),.wd(wb_wd),.ra(wb_ra),.rd(wb_rd[3]));
    // Mode B weight load: one 8-byte group lands per cycle; order is ocg fastest, then ic,
    // then tap.
    always @(posedge clk) begin
        if (rst || st == S_IDLE) begin
            w_bv <= 0; w_half <= 0; wl_ocg <= 0; wl_ic <= 0; wl_tap <= 0; w_loaded <= 0;
        end else begin
            if (w_sv && w_sr && !is_ma && !is_t4) begin w_beat <= w_sd; w_bv <= 1; w_half <= 0; end
            else if (w_bv && !w_half) w_half <= 1;
            else if (w_bv && w_half) begin w_bv <= 0; w_half <= 0; end
            if (w_bv) begin
                if (wl_ocg == OCG - 1) begin
                    wl_ocg <= 0;
                    if (wl_ic == IC - 1) begin
                        wl_ic <= 0;
                        if (wl_tap == 5'd15) w_loaded <= 1;
                        wl_tap <= wl_tap + 1;
                    end else wl_ic <= wl_ic + 1;
                end else wl_ocg <= wl_ocg + 1;
            end
        end
    end
    // Mode A slice fill: two 8-byte groups per beat; the tap counter walks 0..3 (bank = ~tap),
    // ic advances every 4 groups, and the slice is complete when ic wraps.
    always @(posedge clk) begin
        if (rst || st == S_IDLE || st != S_ASLICE) begin
            a_bv <= 0; a_half <= 0; a_wt <= 0; a_wic <= 0;
        end else begin
            if (w_sv && a_w_sr) begin a_beat <= w_sd; a_bv <= 1; a_half <= 0; end
            else if (a_bv && !a_half) a_half <= 1;
            else if (a_bv && a_half) begin a_bv <= 0; a_half <= 0; end
            if (a_bv) begin
                if (a_wt == 2'd3) begin
                    a_wt <= 0;
                    if (a_wic == IC - 1) begin a_wic <= 0; a_wdone <= 1; a_bv <= 0; end
                    else a_wic <= a_wic + 1;
                end else a_wt <= a_wt + 1;
            end
        end
        // This clear must come after the set above so that it wins: a_lrst pulses at each
        // slice start, and a stale a_wdone would skip the slice's weight refill.
        if (rst || st == S_IDLE || a_lrst) a_wdone <= 0;
    end

    // ================= row output buffer =================
    reg         ob_we; reg [9:0] ob_wa; reg [63:0] ob_wd;
    reg  [9:0]  ob_ra;
    wire [63:0] ob_rd;
    bram_sdp #(64, 1024, 10) obuf (.clk(clk),.we(ob_we),.wa(ob_wa),.wd(ob_wd),.ra(ob_ra),.rd(ob_rd));

    // ================= compute sequencer (type 2) =================
    // Loop order, innermost first: ic window (icw8), then oc-group, then output-pixel pair
    // (oxh), then px (mode B) / row and slice (mode A). R_FETCH reads the first window's
    // 2x3 patch, R_COMP issues the multiplies (and prefetches the next window); R_FLUSH
    // waits for the accumulator to settle, hands the batch to the requant chain and
    // starts the next batch.
    localparam R_FETCH = 2'd0, R_COMP = 2'd1, R_FLUSH = 2'd2;
    reg [1:0]  rs;
`ifdef PROBE_STATES
    // Simulation-only: cycles spent per top state and per compute sub-state, printed at S_FIN.
    integer hp_st[0:7]; integer hp_rs[0:3]; integer hp_i;
    initial begin
        for (hp_i = 0; hp_i < 8; hp_i = hp_i + 1) hp_st[hp_i] = 0;
        for (hp_i = 0; hp_i < 4; hp_i = hp_i + 1) hp_rs[hp_i] = 0;
    end
    always @(posedge clk) if (!rst) begin
        hp_st[st] <= hp_st[st] + 1;
        if (st == 3'd3) hp_rs[rs] <= hp_rs[rs] + 1;   // S_RUN
    end
`endif
    reg        px;
    wire       pxw = is_ma ? a_ph[0] : px;   // phase-x: slice-driven in mode A
    reg [5:0]  oxh;                      // pair base on the phase grid (steps by 2)
    reg [2:0]  ocg;
    reg [5:0]  icw8;                     // ic window index (0..ICW-1)
    reg [3:0]  cnt;                      // sub-counter inside R_* states
    // input row indices for this output row
    wire signed [7:0] iyA = py ? {2'b0, oyh} + 8'sd1 : {2'b0, oyh};
    wire signed [7:0] iyB = py ? {2'b0, oyh} : {2'b0, oyh} - 8'sd1;
    wire iyA_ok = (iyA >= 0) && (iyA < $signed({2'b0, H}));
    wire iyB_ok = (iyB >= 0) && (iyB < $signed({2'b0, H}));
    // first input column of the 3-column patch: oxh - 1 for px = 0, oxh for px = 1
    wire signed [7:0] c0 = pxw ? {2'b0, oxh} : {2'b0, oxh} - 8'sd1;
    // weight in-bank row base for this phase: tidx = {!py, !px} (mode B packing)
    wire [10:0] wq_base = (!py ? {1'b0, IC, 1'b0} : 11'd0) + (!pxw ? {2'b0, IC} : 11'd0);
    // v * OCG for OCG in 1,2,4
    function [13:0] mOCG; input [10:0] v; begin
        mOCG = (OCG == 3'd4) ? {1'b0, v, 2'b0} : (OCG == 3'd2) ? {2'b0, v, 1'b0} : {3'b0, v};
    end endfunction
    // synthesis translate_off
    always @(posedge clk) if (start && !(OC_i[5:3] == 3'd1 || OC_i[5:3] == 3'd2 || OC_i[5:3] == 3'd4)) begin
        $display("FAIL hd v0: OC/8 must be 1, 2 or 4 (got OC=%0d)", OC_i); $finish;
    end
    // Mode B tap-bank address reaches 4*IC*OCG - 1; the banks are 512 deep with a 9-bit
    // address, so a larger value would alias silently.
    always @(posedge clk) if (start && !type4 && !mode_a &&
        (({4'b0, IC_i} * {8'b0, OC_i[5:3]}) > 13'd128)) begin      // 4*IC*OCG > 512
        $display("FAIL hd: resident mode needs 4*IC*OCG <= 512 tap-bank words, got IC=%0d OCG=%0d -> %0d. The address would wrap.",
                 IC_i, OC_i[5:3], 4 * IC_i * OC_i[5:3]); $finish;
    end
    // synthesis translate_on

    // Window activation registers: xw[row r][col ci], r: 0 = iyB (lower input row),
    // 1 = iyA (higher input row), ci: 0..2. Each word is 8 channels (8 bytes).
    reg [63:0] xw [0:1][0:2];
    // Shadow copy filled by the prefetch while the current window computes (only icw8
    // changes between consecutive windows, so the next patch is known early). It is copied
    // into xw in one cycle at the window boundary, which keeps the compute read path free
    // of an extra mux.
    reg [63:0] xw_n [0:1][0:2];
    function [7:0] wnz;                  // per-channel OR of one 64-bit window word
        input [63:0] w; integer i;
        begin for (i = 0; i < 8; i = i + 1) wnz[i] = |w[i*8 +: 8]; end
    endfunction
    reg [7:0] nzw   [0:1][0:2];          // non-zero mask of xw   [r][ci]
    reg [7:0] nzw_n [0:1][0:2];          // non-zero mask of xw_n [r][ci]
    wire pf_ok_w = (icw8 + 6'd1) < ICW[5:0];         // a next window exists in this batch
    // R_FETCH: cnt (0..2) selects the column ci. Both rows are read in the same cycle, iyA
    // from one half and iyB from the other. Data arrives one cycle later and is captured
    // with the same decode delayed by one cycle; out-of-range positions capture zero.
    // R_COMP uses the same decode, one window ahead, to fill the shadow set.
    wire [1:0] f_ci = cnt[1:0];
    wire signed [7:0] f_ix = c0 + {6'b0, f_ci};
    wire       f_ix_ok = (f_ix >= 0) && (f_ix < $signed({1'b0, W}));
    wire       f_okA = iyA_ok && f_ix_ok;             // row 1 of xw
    wire       f_okB = iyB_ok && f_ix_ok;             // row 0 of xw
    wire       pf_win = (st == S_RUN) && (rs == R_COMP) && (cnt <= 4'd2) && pf_ok_w;
    reg        fc_v; reg [1:0] fc_ci; reg fc_okA, fc_okB, fc_selA, fc_nx;  // capture stage
    // Window length with zero-channel skipping: only channels that are non-zero in the
    // window issue a multiply, so a window takes nnz cycles.
    reg  [3:0] nnz;                      // number of non-zero channels in the window
    // An all-zero window still issues one beat: the first/last markers travel with issues,
    // and a window that never issued would leave the accumulator unloaded.
    wire [3:0] nnz_eff  = (nnz == 4'd0) ? 4'd1 : nnz;
    // A window with a successor must also last until its three prefetch reads have landed.
    wire [3:0] win_last = (pf_ok_w && (nnz_eff < 4'd4)) ? 4'd3 : (nnz_eff - 4'd1);
    wire       win_end  = (cnt == win_last + 4'd1);   // the shadow-promote cycle
    // xw is written only in the block below (promote and capture share it); no capture is in
    // flight on the promote cycle because the prefetch's last beat lands at cnt == 3.
    wire xw_promote = (st == S_RUN) && (rs == R_COMP) && win_end;
    // iyB = iyA-1 always sits in the other half from iyA.
    wire       f_selA = ~iyA[0];                      // 1 = iyA is in the even half
    wire [63:0] rdA = fc_selA ? lb_rd_e : lb_rd_o;
    wire [63:0] rdB = fc_selA ? lb_rd_o : lb_rd_e;
    integer cp_r, cp_c;
    always @(posedge clk) begin
        fc_v  <= ((st == S_RUN) && (rs == R_FETCH) && (cnt <= 4'd2)) || pf_win;
        fc_nx <= pf_win;                             // 1 = this beat belongs to the shadow set
        fc_ci <= f_ci; fc_okA <= f_okA; fc_okB <= f_okB; fc_selA <= f_selA;
        if (xw_promote) begin
            for (cp_r = 0; cp_r < 2; cp_r = cp_r + 1)
                for (cp_c = 0; cp_c < 3; cp_c = cp_c + 1) begin
                    xw [cp_r][cp_c] <= xw_n [cp_r][cp_c];
                    nzw[cp_r][cp_c] <= nzw_n[cp_r][cp_c];   // the mask moves with its word
                end
        end else if (fc_v) begin
            if (fc_nx) begin
                xw_n [1][fc_ci] <= fc_okA ? rdA : 64'd0;
                xw_n [0][fc_ci] <= fc_okB ? rdB : 64'd0;
                nzw_n[1][fc_ci] <= fc_okA ? wnz(rdA) : 8'd0;
                nzw_n[0][fc_ci] <= fc_okB ? wnz(rdB) : 8'd0;
            end else begin
                xw   [1][fc_ci] <= fc_okA ? rdA : 64'd0;
                xw   [0][fc_ci] <= fc_okB ? rdB : 64'd0;
                nzw  [1][fc_ci] <= fc_okA ? wnz(rdA) : 8'd0;
                nzw  [0][fc_ci] <= fc_okB ? wnz(rdB) : 8'd0;
            end
        end
    end
    wire [5:0] f_icw = (rs == R_COMP) ? (icw8 + 6'd1) : icw8;   // prefetch reads one window ahead
    wire [8:0] f_row_off = {3'b0, f_ix[5:0]} * {3'b0, ICW[5:0]};
    wire [9:0] f_aA = {iyA[1], 9'b0} + {1'b0, f_row_off} + {4'b0, f_icw};
    wire [9:0] f_aB = {iyB[1], 9'b0} + {1'b0, f_row_off} + {4'b0, f_icw};
    always @(*) lb_ra_e = f_selA ? f_aA : f_aB;       // even half
    always @(*) lb_ra_o = f_selA ? f_aB : f_aA;       // odd half
    always @(*) lb_ra0  = 11'd0;         // port A is used for writes (loader)

    // ---- zero-channel skip ----
    // A zero activation contributes nothing to any accumulator, so skipping it is exact.
    // The non-zero mask of each captured word is kept beside the word. At a window
    // boundary the six masks are ORed, turned into a list of the non-zero channel indices
    // (seq) and a count (nnz), and registered, so the per-cycle path is a small mux.
    wire [7:0] nz_cur = nzw  [0][0] | nzw  [0][1] | nzw  [0][2] |
                        nzw  [1][0] | nzw  [1][1] | nzw  [1][2];
    wire [7:0] nz_nxt = nzw_n[0][0] | nzw_n[0][1] | nzw_n[0][2] |
                        nzw_n[1][0] | nzw_n[1][1] | nzw_n[1][2];
    reg  [2:0] seq [0:7];                // registered: seq[k] = index of the k-th non-zero channel
    reg  [2:0] sq_v [0:7];               // combinational build of seq
    reg  [3:0] sq_n;
    reg  [3:0] pc  [0:8];                // prefix popcount of the mask
    reg  [7:0] nz_ld;                    // the mask being latched this cycle
    integer sq_i, sq_k;
    always @(*) begin
        pc[0] = 4'd0;
        for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1)
            pc[sq_i+1] = pc[sq_i] + {3'b0, nz_ld[sq_i]};
        // slot k takes the channel whose prefix count equals k
        for (sq_k = 0; sq_k < 8; sq_k = sq_k + 1) begin
            sq_v[sq_k] = 3'd0;
            for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1)
                if (nz_ld[sq_i] && (pc[sq_i] == sq_k[3:0])) sq_v[sq_k] = sq_i[2:0];
        end
        sq_n = pc[8];
    end
    // The list is latched when a window's activations become stable: at the end of R_FETCH
    // (xw filled directly) and at the shadow promote (xw <= xw_n).
    wire ld_seq = ((st == S_RUN) && (rs == R_FETCH) && (cnt == 4'd4)) || xw_promote;
    always @(*) nz_ld = xw_promote ? nz_nxt : nz_cur;
    integer sq_r;
    always @(posedge clk) begin
        if (rst || st == S_IDLE) begin
            nnz <= 4'd1;
            for (sq_r = 0; sq_r < 8; sq_r = sq_r + 1) seq[sq_r] <= 3'd0;
        end else if (ld_seq) begin
            nnz <= sq_n;
            for (sq_r = 0; sq_r < 8; sq_r = sq_r + 1) seq[sq_r] <= sq_v[sq_r];
        end
    end
    wire [2:0] bidx     = seq[cnt[2:0]];

    // weight read address (all four banks share it): (wq_base + ic) * OCG + ocg
    wire [8:0]  q_ic   = {icw8, bidx};       // ic = icw8*8 + the selected channel
    wire [13:0] wb_ra_w = mOCG(wq_base + {2'b0, q_ic}) + {11'b0, ocg};
    // mode A: the resident slice is already specific to (phase, ocg), so the address is ic
    always @(*) wb_ra = is_ma ? q_ic : wb_ra_w[8:0];

    // compute-issue control; v/fst/lst flags travel beside the data through the stages below
    reg v1, v2, v3, v4, v5, v6;
    reg fst1, fst2, fst3, fst4, fst5, fst6;      // first beat of the ic sweep
    reg lst1, lst2, lst3, lst4, lst5, lst6;      // last beat of the ic sweep
    reg [2:0] bidx1;                             // byte index into xw words
    wire issue  = (st == S_RUN) && (rs == R_COMP) && (cnt < nnz_eff);
    wire is_fst = (icw8 == 0) && (cnt == 0);
    wire is_lst = (icw8 == ICW[5:0] - 6'd1) && (cnt == nnz_eff - 4'd1);
    // ================= datapath: 32 DSPs = 4 taps x 8 oc, two pixels per DSP =================
    // Stage 1: weight words arrive (wb_rd[t]); select the activation bytes from xw.
    //     tap t = {ty,tx}: pixel A byte = xw[ty][tx], pixel B byte = xw[ty][tx+1].
    reg  [63:0] w64_1 [0:3];
    reg  [7:0]  a8A_1 [0:3], a8B_1 [0:3];
    integer t1;
    always @(posedge clk) begin
        v1 <= issue; fst1 <= is_fst; lst1 <= is_lst; bidx1 <= bidx;
        if (issue) begin end
    end
    reg [2:0] bidx2;
    always @(posedge clk) begin
        if (v1) begin
            w64_1[0] <= wb_rd[3]; w64_1[1] <= wb_rd[2];   // t={ty,tx}: bank {!ty,!tx}
            w64_1[2] <= wb_rd[1]; w64_1[3] <= wb_rd[0];
            for (t1 = 0; t1 < 4; t1 = t1 + 1) begin
                a8A_1[t1] <= xw[t1 >> 1][t1 & 1]       [{bidx1, 3'b0} +: 8];
                a8B_1[t1] <= xw[t1 >> 1][(t1 & 1) + 1] [{bidx1, 3'b0} +: 8];
            end
        end
        bidx2 <= bidx1;
    end
    // Stage 2: build the DSP operand and split the weight word into 8 weights.
    //     operand = (pixB signed << 18) + pixA unsigned (27 bits).
    reg signed [26:0] op_2 [0:3];
    reg  [7:0]  w8_2 [0:3][0:7];
    reg         asgn_2 [0:3];                     // pixA sign bit (for the stage-5 correction)
    integer t2, l2;
    always @(posedge clk) begin
        v2 <= v1; fst2 <= fst1; lst2 <= lst1;
        if (v1) begin end
    end
    always @(posedge clk) begin
        if (v2) begin end
        for (t2 = 0; t2 < 4; t2 = t2 + 1) begin
            op_2[t2]   <= {a8B_1[t2][7], a8B_1[t2], 10'b0, a8A_1[t2]};
            asgn_2[t2] <= a8A_1[t2][7];
            for (l2 = 0; l2 < 8; l2 = l2 + 1)
                w8_2[t2][l2] <= w64_1[t2][{l2[2:0], 3'b0} +: 8];
        end
    end
    // Stages 3 and 4: 32 packed multiplies P = operand * w (35-bit product), then a
    // pipeline register for the DSP output.
    (* use_dsp = "yes" *) reg signed [34:0] prod_3 [0:3][0:7];
    reg signed [34:0] prod_4 [0:3][0:7];
    reg asgn_3 [0:3]; reg [7:0] w8_3 [0:3][0:7];
    reg asgn_4 [0:3]; reg [7:0] w8_4 [0:3][0:7];
    integer t3, l3;
    always @(posedge clk) begin
        v3 <= v2; fst3 <= fst2; lst3 <= lst2;
        v4 <= v3; fst4 <= fst3; lst4 <= lst3;
        for (t3 = 0; t3 < 4; t3 = t3 + 1) begin
            asgn_3[t3] <= asgn_2[t3]; asgn_4[t3] <= asgn_3[t3];
            for (l3 = 0; l3 < 8; l3 = l3 + 1) begin
                prod_3[t3][l3] <= op_2[t3] * $signed(w8_2[t3][l3]);
                prod_4[t3][l3] <= prod_3[t3][l3];
                w8_3[t3][l3] <= w8_2[t3][l3]; w8_4[t3][l3] <= w8_3[t3][l3];
            end
        end
    end
    // Stage 5: split the product into the two pixel lanes and sum the 4 taps.
    //     laneA = signed(P[17:0]) - (pixA < 0 ? w<<8 : 0);  laneB = P[34:18] + P[17].
    reg signed [19:0] sumA_5 [0:7], sumB_5 [0:7];
    integer l5, t5;
    reg signed [17:0] lA [0:3]; reg signed [17:0] lB [0:3];
    always @(posedge clk) begin
        v5 <= v4; fst5 <= fst4; lst5 <= lst4;
        for (l5 = 0; l5 < 8; l5 = l5 + 1) begin
            for (t5 = 0; t5 < 4; t5 = t5 + 1) begin
                lA[t5] = $signed(prod_4[t5][l5][17:0])
                       - (asgn_4[t5] ? $signed({w8_4[t5][l5], 8'b0}) : 18'sd0);
                // both addends must be signed, or the sum becomes unsigned and the
                // 17-bit high field is zero-extended
                lB[t5] = $signed(prod_4[t5][l5][34:18]) + $signed({17'd0, prod_4[t5][l5][17]});
            end
            sumA_5[l5] <= lA[0] + lA[1] + lA[2] + lA[3];
            sumB_5[l5] <= lB[0] + lB[1] + lB[2] + lB[3];
        end
    end
    // Stage 6: accumulate over the ic sweep into int32 accumulators accA / accB
    // (pixel A / pixel B), indexed {abk, lane}. Two banks: the next batch accumulates into
    // one while the requant chain drains the other.
    reg signed [31:0] accA [0:15], accB [0:15];
    reg abk;                                      // accumulator bank being written
    reg acc_done;                                 // asserts the cycle after the last add
    integer l6;
    always @(posedge clk) begin
        v6 <= v5; fst6 <= fst5; lst6 <= lst5;
        acc_done <= 1'b0;
        // sumA_5 / sumB_5 were written on the v5 cycle, so they are read one cycle later (v6)
        if (v6) begin
            for (l6 = 0; l6 < 8; l6 = l6 + 1) begin
                accA[{abk, l6[2:0]}] <= (fst6 ? 32'sd0 : accA[{abk, l6[2:0]}])
                                      + {{12{sumA_5[l6][19]}}, sumA_5[l6]};
                accB[{abk, l6[2:0]}] <= (fst6 ? 32'sd0 : accB[{abk, l6[2:0]}])
                                      + {{12{sumB_5[l6][19]}}, sumB_5[l6]};
            end
        end
        if (v6 && lst6) acc_done <= 1'b1;
    end
    // ================= requant chain (one job per cycle) =================
    // 16 jobs per finished batch: q_i = {pixel, lane}; order is pixel A lanes 0..7, then
    // pixel B lanes 0..7, so each pixel's 8 oc bytes assemble one 64b row-buffer word.
    // The chain runs on its own once started by acc_done. It reads a snapshot of the loop
    // context (rq_*) taken at hand-over, because the live counters move on meanwhile.
    reg  [4:0]  q_i;                      // 0..15 issue; bit 4 set = all issued
    reg         rq_busy;                  // a batch's requant is in flight
    // acc_done is a one-cycle pulse; acc_pend holds it while the chain is busy, and acc_go is
    // the single "take the finished batch now" condition used by the FSM and the chain.
    reg         acc_pend;
    wire        acc_go = (acc_done | acc_pend) & ~rq_busy;
    reg         rq_bk;                    // which accumulator bank it drains
    reg  [2:0]  rq_ocg;
    reg  [5:0]  rq_oxh;
    reg         rq_px;
    reg  [14:0] rq_rowbase;
    wire        q_issue = rq_busy && !q_i[4];
    wire [4:0]  q_oc    = {rq_ocg[1:0], q_i[2:0]};
    // Q1: fetch the accumulator and the channel's m0, bias, shift
    reg qv1, qp1; reg [2:0] ql1;
    reg signed [31:0] q_acc1; reg signed [17:0] q_m01; reg signed [39:0] q_b1; reg [5:0] q_sh1;
    always @(posedge clk) begin
        qv1 <= q_issue; qp1 <= q_i[3]; ql1 <= q_i[2:0];
        q_acc1 <= q_i[3] ? accB[{rq_bk, q_i[2:0]}] : accA[{rq_bk, q_i[2:0]}];
        q_m01  <= rq_m0[q_oc]; q_b1 <= rq_bias[q_oc]; q_sh1 <= rq_sh[q_oc];
    end
    // Q2: multiply acc * m0
    reg qv2, qp2; reg [2:0] ql2;
    (* use_dsp = "yes" *) reg signed [49:0] q_mul2;
    reg signed [39:0] q_b2; reg [5:0] q_sh2;
    always @(posedge clk) begin
        qv2 <= qv1; qp2 <= qp1; ql2 <= ql1;
        q_mul2 <= q_acc1 * q_m01; q_b2 <= q_b1; q_sh2 <= q_sh1;
    end
    // Q3: add bias and the rounding half (1 << (shift-1), or 0 for shift 0)
    reg qv3, qp3; reg [2:0] ql3;
    reg signed [51:0] q_t3; reg [5:0] q_sh3;
    wire signed [51:0] q_half = (q_sh2 == 0) ? 52'sd0 : (52'sd1 <<< (q_sh2 - 1));
    always @(posedge clk) begin
        qv3 <= qv2; qp3 <= qp2; ql3 <= ql2;
        q_t3 <= {{2{q_mul2[49]}}, q_mul2} + {{12{q_b2[39]}}, q_b2} + q_half;
        q_sh3 <= q_sh2;
    end
    // Q4a: arithmetic shift right, registered alone. Q4b (below): clamps and byte assembly.
    reg qv4, qp4; reg [2:0] ql4;
    reg signed [51:0] q_shf4;
    always @(posedge clk) begin
        qv4 <= qv3; qp4 <= qp3; ql4 <= ql3;
        q_shf4 <= q_t3 >>> q_sh3;
    end
    // Row-buffer word address. Output column ox = 2*(oxh + pixel) + px.
    // mode B: wa = ox*OCG + ocg (row-local).
    // mode A: wa = ((2*a_oyh + py)*OW + ox)*OCG + ocg (whole-tensor assembly).
    wire [7:0]  q_ox   = {rq_oxh + {5'b0, qp4}, rq_px};
    // The row base is a multiply that changes only at row/phase boundaries, so it is
    // registered; the chain uses the snapshot rq_rowbase taken at hand-over.
    wire [6:0]  a_oyf  = {a_oyh, py};
    reg  [14:0] a_rowbase_r;
    always @(posedge clk) a_rowbase_r <= a_oyf * OW;
    wire [14:0] a_pix  = rq_rowbase + {8'b0, q_ox};
    wire [13:0] q_wa_w = mOCG(is_ma ? a_pix[10:0] : {3'b0, q_ox}) + {11'b0, rq_ocg};
    wire [9:0]  ob_wa_q = q_wa_w[9:0];
    wire signed [15:0] q_r0  = (q_shf4 > 52'sd32767) ? 16'sd32767 :
                               (q_shf4 < -52'sd32768) ? -16'sd32768 : q_shf4[15:0];
    wire signed [15:0] q_r1  = (relu && q_r0 < 0) ? 16'sd0 : q_r0;
    wire signed [15:0] q_r   = (q_r1 < lo) ? lo : (q_r1 > hi) ? hi : q_r1;
    reg  [63:0] q_word;
    always @(posedge clk) begin
        ob_we <= 1'b0;
        if (qv4) begin
            q_word[{ql4, 3'b0} +: 8] <= q_r[7:0];
            if (ql4 == 3'd7) begin
                ob_we <= 1'b1;
                ob_wa <= ob_wa_q;
            end
        end
        // lane 7 is written to q_word on this same edge, so it is merged in here
        if (qv4 && ql4 == 3'd7) ob_wd <= {q_r[7:0], q_word[55:0]};
    end
    // synthesis translate_off
    always @(posedge clk) if (is_ma && st == S_ASLICE && a_wdone && $test$plusargs("HD_DBG6"))
        $display("hd slice ph=%0d bank0[0]=%016x bank1[0]=%016x bank2[0]=%016x bank3[0]=%016x",
                 a_ph, wbank0.mem[0], wbank1.mem[0], wbank2.mem[0], wbank3.mem[0]);
    always @(posedge clk) if (v2 && fst2 && $test$plusargs("HD_DBG5"))
        $display("hd beat0 a8A=%02x,%02x,%02x,%02x a8B=%02x,%02x,%02x,%02x op3=%07x w3l0=%02x",
                 a8A_1[0], a8A_1[1], a8A_1[2], a8A_1[3],
                 a8B_1[0], a8B_1[1], a8B_1[2], a8B_1[3], op_2[3], w8_2[3][0]);
    always @(posedge clk) if (st == S_RUN && rs == R_FETCH && $test$plusargs("HD_DBG4"))
        $display("hd f oy=%0d px=%0d oxh=%0d cnt=%0d c0=%0d f_ci=%0d f_ix=%0d okA=%0d okB=%0d aA=%0d aB=%0d nnz=%0d",
                 oy, px, oxh, cnt, c0, f_ci, f_ix, f_okA, f_okB, f_aA, f_aB, nnz);
    always @(posedge clk) if (acc_done && $test$plusargs("HD_DBG3"))
        $display("hd acc oy=%0d px=%0d oxh=%0d ocg=%0d A=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d B=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                 oy, px, oxh, ocg,
                 accA[0],accA[1],accA[2],accA[3],accA[4],accA[5],accA[6],accA[7],
                 accB[0],accB[1],accB[2],accB[3],accB[4],accB[5],accB[6],accB[7]);
    always @(posedge clk) if (st == S_RUN && rs == R_COMP && cnt == 0 && $test$plusargs("HD_DBG2"))
        $display("hd win oy=%0d px=%0d oxh=%0d ocg=%0d icw8=%0d xw0=%016x/%016x/%016x xw1=%016x/%016x/%016x",
                 oy, px, oxh, ocg, icw8, xw[0][0], xw[0][1], xw[0][2], xw[1][0], xw[1][1], xw[1][2]);
    always @(posedge clk) if (qv4 && ql4 == 3'd7 && $test$plusargs("HD_DBG"))
        $display("hd obw ph=%0d aoyh=%0d py=%0d pxw=%0d oxh=%0d ocg=%0d p=%0d ox=%0d wa=%0d d=%016x",
                 a_ph, a_oyh, py, pxw, oxh, ocg, qp4, q_ox, ob_wa_q, {q_r[7:0], q_word[55:0]});
    // synthesis translate_on

    // ================= type 4 (final 1x1): pure streaming =================
    // Weights [OC][IC] bytes fill 16 per-lane rotating shift registers in stream order.
    // Input beats are consumed two ic per cycle against 16 oc lanes; the raw int32
    // accumulators are handed to the top FSM through t4_rdy / t4_ack, which emits OC/4
    // beats per pixel. Rotating registers avoid a 512:1 byte mux per lane: the per-lane
    // read is always the low byte, and each consumed ic pair is one fixed 16-bit rotate.
    // Requires IC == 32 (asserted below).
    reg [255:0] t4wr [0:15];             // lane l: b[0] exits first (low byte)
    reg [3:0]   t4w_lane;                // lane being filled during load
    reg [4:0]   t4w_pos;                 // bytes pushed into that lane
    reg         t4_wdone;
    reg  [127:0] t4_beat; reg [3:0] t4_bn; reg t4_bv;
    reg  [8:0]  t4_ic;
    reg  [13:0] t4_px;
    reg         t4_rdy;                  // pixel accs valid, waiting for emit
    reg         t4_ack;                  // pulse from the main FSM: all beats of the pixel emitted
    // Two input channels per cycle go to two separate accumulators (t4accA: even ic,
    // t4accB: odd ic), so each is a plain multiply-accumulate on one DSP. They are summed
    // once per emitted beat, outside the accumulate loop.
    (* use_dsp = "yes" *) reg signed [31:0] t4accA [0:15];   // ic even
    (* use_dsp = "yes" *) reg signed [31:0] t4accB [0:15];   // ic odd
    assign t4_w_sr  = (st == S_T4) && !t4_wdone && !t4_bv;
    assign t4_in_sr = (st == S_T4) && t4_wdone && !t4_bv && !t4_rdy;
    wire signed [7:0] t4_xa = t4_beat[7:0];    // ic 2k
    wire signed [7:0] t4_xb = t4_beat[15:8];   // ic 2k+1
    integer t4l;
    always @(posedge clk) begin
        if (rst || st == S_IDLE) begin
            t4w_lane <= 0; t4w_pos <= 0; t4_wdone <= 0; t4_bv <= 0; t4_bn <= 0;
            t4_ic <= 0; t4_px <= 0; t4_rdy <= 0;
        end else if (st == S_T4) begin
            if (!t4_wdone) begin
                if (w_sv && t4_w_sr) begin t4_beat <= w_sd; t4_bv <= 1; t4_bn <= 0; end
                else if (t4_bv) begin
                    // push into the top of the lane register; after 32 pushes b[0] is at the
                    // low byte, where the compute reads it first
                    t4wr[t4w_lane] <= {t4_beat[7:0], t4wr[t4w_lane][255:8]};
                    t4_beat <= {8'b0, t4_beat[127:8]};
                    if (t4w_pos == 5'd31) begin
                        t4w_pos <= 0;
                        if ({2'b0, t4w_lane} == OC[5:0] - 6'd1) begin t4_wdone <= 1; t4_bv <= 0; end
                        t4w_lane <= t4w_lane + 1;
                    end else t4w_pos <= t4w_pos + 1;
                    if (t4_bn == 4'd15) t4_bv <= 0;
                    t4_bn <= t4_bn + 1;
                end
            end else begin
                if (in_sv && t4_in_sr) begin t4_beat <= in_sd; t4_bv <= 1; t4_bn <= 0; end
                else if (t4_bv && !t4_rdy) begin
                    for (t4l = 0; t4l < 16; t4l = t4l + 1) begin
                        if (t4l < {2'b0, OC}) begin
                            t4accA[t4l] <= (t4_ic == 0 ? 32'sd0 : t4accA[t4l])
                                         + t4_xa * $signed(t4wr[t4l][7:0]);
                            t4accB[t4l] <= (t4_ic == 0 ? 32'sd0 : t4accB[t4l])
                                         + t4_xb * $signed(t4wr[t4l][15:8]);
                        end else begin t4accA[t4l] <= 32'sd0; t4accB[t4l] <= 32'sd0; end
                        t4wr[t4l] <= {t4wr[t4l][15:0], t4wr[t4l][255:16]};  // rotate: next TWO ic
                    end
                    t4_beat <= {16'b0, t4_beat[127:16]};
                    // IC is asserted == 32, so it is even and t4_ic steps 0,2,...,30.
                    if (t4_ic >= IC - 2) begin t4_ic <= 0; t4_rdy <= 1; t4_bv <= 0; end
                    else begin
                        t4_ic <= t4_ic + 2;
                        if (t4_bn == 4'd7) t4_bv <= 0;    // 128-bit beat = 16 bytes = 8 pairs
                        t4_bn <= t4_bn + 1;
                    end
                end
                if (t4_rdy && t4_ack) begin t4_rdy <= 0; t4_px <= t4_px + 1; end
            end
        end
    end
    // synthesis translate_off
    // Mode A assembles the whole output tensor in obuf, so OH*OW*(OC/8) must not exceed the
    // obuf depth (1024 words).
    always @(posedge clk) if (start && mode_a && !type4 &&
        (({1'b0,H_i,1'b0} * {1'b0,W_i,1'b0} * {6'b0,OC_i[5:3]}) > 17'd1024)) begin
        $display("FAIL hd mode A: whole-tensor assembly needs %0d words > 1024 (H=%0d W=%0d OC=%0d) -- this op must run the resident-weight mode",
                 ({1'b0,H_i,1'b0} * {1'b0,W_i,1'b0} * {6'b0,OC_i[5:3]}), H_i, W_i, OC_i);
        $finish;
    end
    always @(posedge clk) if (start && type4 && (OC_i > 6'd16)) begin
        $display("FAIL hd type4: OC must be <= 16 (got %0d)", OC_i); $finish;
    end
    always @(posedge clk) if (start && type4 && (IC_i != 9'd32)) begin
        $display("FAIL hd type4: the rotating weight registers assume IC==32 (got %0d)", IC_i);
        $finish;
    end
    // synthesis translate_on

    // ================= top FSM =================
    // d_widx is 11 bits because the whole-tensor drain counts up to 1024; a 10-bit counter
    // would wrap and `d_widx >= drain_words` would never become true.
    reg [10:0] d_widx;                    // drain word index
    reg [1:0] d_ph;                       // drain phase: 0,1 issue reads, 2 capture low word, 3 emit
    reg [63:0] d_lo;
    reg [1:0] t4e;                        // type-4 emit beat index
    reg       a_lrst_r;                   // mode A: slice-start pulse (input restart)
    reg [2:0] a_ocg;                      // mode A: slice oc-group
    assign a_lrst = a_lrst_r;
    // Drain length in 64b words, from the latched descriptor, computed through registers so
    // the multiply is not in the S_DRAIN exit path. It settles a few cycles after start,
    // long before the first drain. Mode B drains one row (OW*OCG); mode A drains OH*OW*OCG.
    reg [13:0] row_ow_r;
    reg [14:0] a_all_r;
    reg [10:0] drain_words;
    always @(posedge clk) begin
        row_ow_r     <= mOCG({3'b0, OW});
        a_all_r      <= {7'b0, OH} * row_ow_r[10:0];
        drain_words  <= is_ma ? a_all_r[10:0] : {1'b0, row_ow_r[9:0]};
    end
    // input rows that must be loaded before this output row can start
    wire [8:0] need_rows = (iyA >= $signed({2'b0, H})) ? {2'b0, H} : {1'b0, iyA[7:0]} + 9'd1;
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; done <= 1'b0; out_sv <= 1'b0; out_sd <= 0;
            rs <= R_FETCH; cnt <= 0;
            // q_i is not reset here: the rq_busy block below owns it. Driving it from two
            // always blocks lets synthesis tie it to a constant and delete the datapath.
            oy <= 0; px <= 0; oxh <= 0; ocg <= 0; icw8 <= 0;
            d_widx <= 0; d_ph <= 0; t4e <= 0; t4_ack <= 0; is_t4 <= 0; is_ma <= 0;
`ifndef HD_LDALLOW_COMB
            ld_allow_r <= 9'd2;                       // oyh = 0
`endif
            a_ph <= 0; a_oyh <= 0; a_lrst_r <= 0; a_ocg <= 0;
            IC <= 0; OC <= 0; H <= 0; W <= 0; ICW <= 0; OCG <= 0;
            relu <= 0; lo <= 0; hi <= 0;
        end else begin
            done <= 1'b0; t4_ack <= 1'b0;
            case (st)
            S_IDLE: if (start) begin
                IC <= IC_i; OC <= OC_i; H <= H_i; W <= W_i;
`ifdef HD_PRECOMP
                hw_last <= {2'b0, H_i} * {5'b0, W_i} - 14'd1;
`endif
                ICW <= IC_i[8:3]; OCG <= OC_i[5:3];
                relu <= relu_i; lo <= lo_i; hi <= hi_i; is_t4 <= type4; is_ma <= mode_a;
                oy <= 0; t4e <= 0; a_ph <= 0; a_oyh <= 0;
`ifndef HD_LDALLOW_COMB
                ld_allow_r <= 9'd2;                   // oy and a_oyh both -> 0
`endif
                // Pulse only for mode A: S_ASLICE is the only state that clears it, so a
                // pulse in mode B would hold ld_ok low and deadlock the loader.
                a_lrst_r <= mode_a;
                st <= type4 ? S_T4 : mode_a ? S_ASLICE : S_PREP;
            end
            S_PREP: if (w_loaded) st <= S_ROW;
            S_ASLICE: begin
                a_lrst_r <= 1'b0;
                if (a_wdone && !a_lrst_r) begin
                    a_oyh <= 0; oxh <= 0; ocg <= a_ocg; icw8 <= 0; cnt <= 0;
`ifndef HD_LDALLOW_COMB
                    ld_allow_r <= {3'b0, (is_ma ? 6'd0 : oy[6:1])} + 9'd2;
`endif
                    st <= S_ROW;
                end
            end
            S_T4: begin
                if (out_sv) begin
                    if (out_sr) begin
                        out_sv <= 1'b0;
                        if ({1'b0, t4e} == OC[5:2] - 3'd1) begin   // OC/4 beats per pixel
                            t4e <= 0; t4_ack <= 1'b1;
`ifdef HD_PRECOMP
                            if (t4_px == hw_last) st <= S_FIN;
`else
                            if (t4_px == {2'b0, H} * {5'b0, W} - 14'd1) st <= S_FIN;
`endif
                        end else t4e <= t4e + 1;
                    end
                end else if (t4_rdy && !t4_ack) begin
                    // sum the even-ic and odd-ic accumulators here, once per emitted beat
                    out_sd <= {t4accA[{t4e, 2'd3}] + t4accB[{t4e, 2'd3}],
                               t4accA[{t4e, 2'd2}] + t4accB[{t4e, 2'd2}],
                               t4accA[{t4e, 2'd1}] + t4accB[{t4e, 2'd1}],
                               t4accA[{t4e, 2'd0}] + t4accB[{t4e, 2'd0}]};
                    out_sv <= 1'b1;
                end
            end
            S_ROW: if (lb_loaded >= need_rows) begin
                if (!is_ma) begin px <= 0; ocg <= 0; end
                oxh <= 0; icw8 <= 0; cnt <= 0; want_drain <= 1'b0;
                rs <= R_FETCH; st <= S_RUN;
            end
            S_RUN: begin
              // The output is complete only once the last batch has left the requant chain,
              // because S_DRAIN reads the buffer the chain writes. Every other transition
              // (next pair, row, slice) may be taken while the chain is still busy.
              if (want_drain && !rq_busy && !acc_done && !acc_pend) begin
                  want_drain <= 1'b0; d_widx <= 0; d_ph <= 0; st <= S_DRAIN;
              end else
              case (rs)
                // Three reads (cnt 0..2); the last lands at cnt == 3, and cnt == 4 is where
                // the channel list for the first window is latched (xw is complete then).
                R_FETCH: begin
                    if (cnt == 4'd4) begin cnt <= 0; rs <= R_COMP; end
                    else cnt <= cnt + 1;
                end
                // The window lasts until win_last (see above); win_last + 1 is the shadow
                // promote cycle, which also latches the next window's channel list.
                R_COMP: begin
                    if (cnt == win_last) begin
                        if (icw8 == ICW[5:0] - 6'd1) begin cnt <= 0; rs <= R_FLUSH; end
                        else cnt <= win_last + 4'd1;
                    end else if (win_end) begin
                        cnt <= 0; icw8 <= icw8 + 1;
                    end else cnt <= cnt + 1;
                end
                // Wait for the accumulator to settle, hand the batch to the requant chain
                // (acc_go) and advance the loop counters in the same cycle.
                R_FLUSH: if (acc_go) begin
                        icw8 <= 0; cnt <= 0;
                        if (is_ma) begin
                            // mode A: pairs sweep the whole phase grid; ocg is fixed per
                            // slice. Order: next pair, next row, next slice.
                            if (oxh == W[5:0] - 6'd2) begin
                                oxh <= 0;
                                if (a_oyh == H[5:0] - 6'd1) begin
                                    if (a_ocg == OCG - 1) begin
                                        a_ocg <= 0;
                                        if (a_ph == 2'd3) begin
                                            want_drain <= 1'b1;
                                        end else begin
                                            a_ph <= a_ph + 1; a_lrst_r <= 1; st <= S_ASLICE;
                                        end
                                    end else begin
                                        a_ocg <= a_ocg + 1; a_lrst_r <= 1; st <= S_ASLICE;
                                    end
                                end else begin a_oyh <= a_oyh + 1; st <= S_ROW;
`ifndef HD_LDALLOW_COMB
                                    ld_allow_r <= {3'b0, (is_ma ? (a_oyh + 6'd1) : oy[6:1])} + 9'd2;
`endif
                                end
                            end else begin oxh <= oxh + 2; rs <= R_FETCH; end
                        end else if (ocg == OCG - 1) begin
                            ocg <= 0;
                            if (oxh == W[5:0] - 6'd2) begin
                                oxh <= 0;
                                if (px) begin want_drain <= 1'b1; end
                                else begin px <= 1; rs <= R_FETCH; end
                            end else begin oxh <= oxh + 2; rs <= R_FETCH; end
                        end else begin ocg <= ocg + 1; rs <= R_FETCH; end
                end
              endcase
            end
            S_DRAIN: begin
                if (out_sv) begin
                    if (out_sr) begin
                        out_sv <= 1'b0;
                        if (d_widx >= drain_words) begin
                            if (is_ma) st <= S_FIN;
                            else if (oy == OH[6:0] - 7'd1) st <= S_FIN;
                            else begin oy <= oy + 1; st <= S_ROW;
`ifndef HD_LDALLOW_COMB
                                // next oyh = (oy+1)>>1, written as oy[6:1] + oy[0] so the
                                // expression stays 6 bits wide
                                ld_allow_r <= {3'b0, (is_ma ? a_oyh : (oy[6:1] + {5'd0, oy[0]}))} + 9'd2;
`endif
                            end
                        end
                    end
                end else case (d_ph)
                    // read two consecutive words, then emit them as one 128-bit beat
                    2'd0: begin ob_ra <= d_widx[9:0]; d_ph <= 2'd1; end
                    2'd1: begin ob_ra <= d_widx[9:0] + 10'd1; d_ph <= 2'd2; end
                    2'd2: begin d_lo <= ob_rd; d_ph <= 2'd3; end
                    2'd3: begin
                        out_sd <= {ob_rd, d_lo}; out_sv <= 1'b1;
                        d_widx <= d_widx + 11'd2; d_ph <= 2'd0;
                    end
                endcase
            end
            S_FIN: begin done <= 1'b1; st <= S_IDLE;
`ifdef PROBE_STATES
                $display("[hdprobe] prep=%0d row=%0d slice=%0d run=%0d t4=%0d drain=%0d | in S_RUN: fetch=%0d comp=%0d flush=%0d rq=%0d",
                         hp_st[1], hp_st[2], hp_st[7], hp_st[3], hp_st[4], hp_st[5],
                         hp_rs[0], hp_rs[1], hp_rs[2], hp_rs[3]);
`endif
            end
            default: st <= S_IDLE;
            endcase
        end
    end
    // ================= requant chain control (independent of the compute FSM) =================
    // Started by acc_go; issues 16 jobs, then waits for the pipeline stages to empty.
    // Meanwhile the compute machine fills the other accumulator bank.
    always @(posedge clk) begin
        if (rst || st == S_IDLE) acc_pend <= 1'b0;
        else acc_pend <= (acc_done | acc_pend) & rq_busy;
    end
    always @(posedge clk) begin
        if (rst || st == S_IDLE) begin
            rq_busy <= 1'b0; q_i <= 5'd16; abk <= 1'b0;
        end else if (acc_go) begin
            rq_busy <= 1'b1; q_i <= 5'd0;
            rq_bk   <= abk;  abk <= ~abk;              // hand this bank over, fill the other
            rq_ocg  <= ocg;  rq_oxh <= oxh; rq_px <= pxw;
            rq_rowbase <= a_rowbase_r;
        end else if (rq_busy) begin
            if (!q_i[4]) q_i <= q_i + 5'd1;
            else if (!qv1 && !qv2 && !qv3 && !qv4) rq_busy <= 1'b0;       // chain drained
        end
    end

    // synthesis translate_off
    // The engine must be idle when the next operator's start arrives; an engine stuck in
    // S_DRAIN would swallow the start silently.
    always @(posedge clk) if (!rst && start && st != S_IDLE) begin
        $display("FAIL hd: start arrived while the engine is still in state %0d -- the previous op never returned to idle", st);
        $finish;
    end
    // With +HD_STUCK, print the engine's wait state periodically while it is not idle.
    integer stk;
    initial stk = 0;
    always @(posedge clk) if (!rst && $test$plusargs("HD_STUCK")) begin
        stk = stk + 1;
        if (stk % 20000 == 0 && st != S_IDLE)
            $display("[hd stuck] t=%0t st=%0d ma=%0d t4=%0d w_loaded=%0d a_wdone=%0d lb_loaded=%0d need=%0d ld_ok=%0d in_sr=%0d w_sr=%0d rs=%0d cnt=%0d oy=%0d oxh=%0d ocg=%0d icw8=%0d q_i=%0d d_widx=%0d drain=%0d out_sv=%0d out_sr=%0d",
                     $time, st, is_ma, is_t4, w_loaded, a_wdone, lb_loaded, need_rows,
                     ld_ok, in_sr, w_sr, rs, cnt, oy, oxh, ocg, icw8, q_i, d_widx,
                     drain_words, out_sv, out_sr);
    end
    // synthesis translate_on

endmodule
`default_nettype wire
