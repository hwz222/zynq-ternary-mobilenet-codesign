// ============================================================================
//  tb_p4_block.v -- one MobileNetV2 body block, end to end, through the real
//  twn_blockseq, twn_fuse_array (one instance serving both ternary
//  convolutions), twn_dw_array and twn_res_add; compared bit-exactly with the
//  block's golden vectors.
//
//  This file is the block-1 template. tb/gen_p4_block.py --block N substitutes
//  geometry, pack codes, stride, residual constants and array sizes (text
//  replacement of the lines marked "per block, substituted" and of the
//  localparams above them; do not reformat those lines) and writes
//  tb_p4_block_bNN.v plus tb_p4_block_*.hex, read from the current directory,
//  from golden/p1_golden/vec/bNN_*.bin. Block 1's testbench is this file itself.
//  Run: sim/run_p5.ps1 (all blocks; -Break FUSE_NEG_ACT_NOWAIT or
//  FUSE_NEG_ACT_NOREADY compiles the corresponding defect arm of
//  twn_fuse_array.v, which each block must then fail).
//  Prints "=== tb_p4_block: ALL PASS ===" or "N FAIL".
//
//  Modelled here: the row buffers (arrays; twn_rowbuf is tested separately),
//  the AXI masters, and the activation producer (LFSR-varied latency, a ready
//  line, X data unless valid).
//
//  The ternary array emits PIX x OCMAX = 4 pixels x 4 channels per beat and the
//  depthwise consumes DW_LANES = 8 channels x 1 pixel, so the expand output
//  buffer is written channel-group-major and read pixel-major; this
//  integration is what checks that transpose.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_p4_block;

    localparam integer C_IN = 16, C_MID = 96, C_OUT = 24;
    localparam integer IH = 128, IW = 128, OH = 64, OW = 64;
    localparam integer PIX = 4, LANES = 128, OCMAX = 4, DW_LANES = 8;
    localparam integer PACK_E = 4, PACK_P = 1;
    // The depthwise window rows are d_row*S_DW - 1, d_row*S_DW, d_row*S_DW + 1,
    // with S_DW the block's stride.
    localparam integer S_DW = 2;                  // per block, substituted
    // ---- the residual, for the blocks that have one ----
    // out = clamp((p*mp + x*mq + round) >>> sh, lo, hi), p the project output
    // and x the block's own input. The residual is computed here in the
    // testbench (this is what produces got[]); the twn_res_add instance below is
    // compared against it on every element.
    localparam integer HAS_RES = 0;
    localparam integer STEM = 0;                  // per block, substituted
    localparam integer RES_MP = 0, RES_MQ = 0, RES_SH = 0;
    localparam integer RES_LO = -127, RES_HI = 127;
    // The uop pack field is a code (0..3 for pack 1, 2, 4, 8), matching the
    // sequencer's pack_e / pack_p ports, which the generator substitutes.
    localparam [1:0] PC_E = (PACK_E == 8) ? 2'd3 : (PACK_E == 4) ? 2'd2
                          : (PACK_E == 2) ? 2'd1 : 2'd0;
    localparam [1:0] PC_P = (PACK_P == 8) ? 2'd3 : (PACK_P == 4) ? 2'd2
                          : (PACK_P == 2) ? 2'd1 : 2'd0;
    localparam integer N_XG_E = IW / PIX;              // 32
    localparam integer N_XG_P = OW / PIX;              // 16
    localparam integer N_OCG_E = C_MID / PACK_E;       // 24
    localparam integer N_OCG_P = C_OUT / PACK_P;       // 24
    localparam integer N_LG = (C_MID + DW_LANES - 1) / DW_LANES;   // 12
    // n_seg per stage: N_EFF > LANES needs several segments.
    localparam integer N_EFF_E = 24;
    localparam integer N_EFF_P = 96;
    // Passes multiply into n_seg: block 0's stem reduces one kernel row per
    // pass, three passes per output row.
    localparam integer N_PASS_E = 1;              // per block, substituted
    // Mixed segment (uop[90], blocks 11-13's expand): n_seg counts 32-channel
    // chunks of one activation word and comes from the manifest, not from n_eff.
    localparam integer MSG_E = 0, N_SEG_MSG_E = 1;  // per block, substituted
    localparam integer N_SEG_E = MSG_E ? N_SEG_MSG_E : N_PASS_E * ((N_EFF_E + LANES - 1) / LANES);
    localparam integer N_SEG_P = (N_EFF_P + LANES - 1) / LANES;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1, start = 0;

    // ================= memories =================
    // Sized for all segments: one word per (row, seg, xg), indexed as
    // e_row*(N_SEG_E*N_XG_E) + act_addr.
    reg [4095:0] act_in  [0:IH*N_SEG_E*N_XG_E-1];      // block input, array-shaped
    localparam integer N_WTE = 64, N_WTP = 64;   // per block, substituted
    reg [255:0]  wte     [0:N_WTE-1];
    reg [255:0]  wtp     [0:N_WTP-1];
    reg [OCMAX*18-1:0] rqe_m0 [0:N_OCG_E-1];
    reg [OCMAX*40-1:0] rqe_bs [0:N_OCG_E-1];
    reg [OCMAX*6-1:0]  rqe_sh [0:N_OCG_E-1];
    reg [OCMAX*18-1:0] rqp_m0 [0:N_OCG_P-1];
    reg [OCMAX*40-1:0] rqp_bs [0:N_OCG_P-1];
    reg [OCMAX*6-1:0]  rqp_sh [0:N_OCG_P-1];
    reg [DW_LANES*9*8-1:0] wdw   [0:N_LG-1];
    reg [DW_LANES*18-1:0]  rqd_m0[0:N_LG-1];
    reg [DW_LANES*32-1:0]  rqd_bs[0:N_LG-1];
    reg [DW_LANES*6-1:0]   rqd_sh[0:N_LG-1];
    reg [7:0] gold [0:C_OUT*OH*OW-1];
    // The two intermediate goldens, so a failure names its stage.
    reg [7:0] golde [0:C_MID*IH*IW-1];      // expand output
    reg [7:0] goldd [0:C_MID*OH*OW-1];      // depthwise output
    reg [7:0] resrc [0:C_OUT*OH*OW-1];      // residual source = the block input
    reg [7:0] goldp [0:C_OUT*OH*OW-1];      // project output, BEFORE the add
    integer err_e, err_d, chk_e, chk_d, err_p, chk_p;
    integer nx_d = 0;                  // depthwise locations nothing ever wrote

    // row buffers, as byte arrays indexed [row][channel][pixel]
    reg signed [7:0] t1buf [0:4*C_MID*IW-1];           // 4 rows of expand output
    reg signed [7:0] dwbuf [0:2*C_MID*OW-1];           // 2 rows of depthwise output
    reg signed [7:0] outbuf[0:2*C_OUT*OW-1];           // 2 rows of block output
    reg signed [7:0] got   [0:C_OUT*OH*OW-1];          // what the block actually produced

    initial begin
        if (HAS_RES) begin
            $readmemh("tb_p4_block_res.hex",   resrc);
            $readmemh("tb_p4_block_goldp.hex", goldp);
        end
        $readmemh("tb_p4_block_golde.hex", golde);
        $readmemh("tb_p4_block_goldd.hex", goldd);
        $readmemh("tb_p4_block_actin.hex", act_in);
        $readmemh("tb_p4_block_wte.hex",   wte);
        $readmemh("tb_p4_block_wtp.hex",   wtp);
        $readmemh("tb_p4_block_rqem0.hex", rqe_m0);
        $readmemh("tb_p4_block_rqebs.hex", rqe_bs);
        $readmemh("tb_p4_block_rqesh.hex", rqe_sh);
        $readmemh("tb_p4_block_rqpm0.hex", rqp_m0);
        $readmemh("tb_p4_block_rqpbs.hex", rqp_bs);
        $readmemh("tb_p4_block_rqpsh.hex", rqp_sh);
        $readmemh("tb_p4_block_wdw.hex",   wdw);
        $readmemh("tb_p4_block_rqdm0.hex", rqd_m0);
        $readmemh("tb_p4_block_rqdbs.hex", rqd_bs);
        $readmemh("tb_p4_block_rqdsh.hex", rqd_sh);
        $readmemh("tb_p4_block_gold.hex",  gold);
    end

    // ================= the sequencer =================
    wire ld_req, e_req, d_req, p_req, st_req;
    // Initialised: these are inputs to the DUT, and an uninitialised reg is X
    // until first assigned, which would propagate through the request gating.
    // After reset a done line is low.
    reg  ld_done = 1'b0, e_done = 1'b0, d_done = 1'b0,
         p_done  = 1'b0, st_done = 1'b0;
    wire [7:0] e_row, d_row, p_row, ld_row, st_row;
    wire [9:0] t1_rptr;
    wire seq_busy, seq_done;
    wire [31:0] cyc_total, cyc_array, cyc_dw, cyc_stall;

    reg [9:0] in_wptr, t1_wptr, dw_wptr, out_cnt;
    localparam integer D_IN = 4, D_T1 = 4, D_DW = 2, D_OUT = 2;
    wire [9:0] in_free  = D_IN  - (in_wptr - {2'b0, e_row});
    wire [9:0] t1_free  = D_T1  - (t1_wptr - t1_rptr);
    wire [9:0] dw_free  = D_DW  - (dw_wptr - {2'b0, p_row});
    wire [9:0] out_free = D_OUT - (out_cnt - {2'b0, st_row});

    twn_blockseq #(.PIX(PIX), .LANES(LANES), .DW_LANES(DW_LANES)) SEQ (
        .clk(clk), .rst(rst), .start(start),
        .c_in(C_IN[9:0]), .c_mid(C_MID[9:0]), .c_out(C_OUT[9:0]),
        .h_in(IH[8:0]), .w_in(IW[8:0]), .s_dw(1'b1), .stem(STEM[0]),
        .pack_e(3'd2), .pack_p(3'd0),
        .ld_req(ld_req), .ld_done(ld_done), .e_req(e_req), .e_done(e_done),
        .d_req(d_req), .d_done(d_done), .p_req(p_req), .p_done(p_done),
        .st_req(st_req), .st_done(st_done),
        .e_row(e_row), .d_row(d_row), .p_row(p_row), .ld_row(ld_row), .st_row(st_row),
        .in_wptr(in_wptr), .in_free(in_free),
        .t1_wptr(t1_wptr), .t1_free(t1_free), .t1_rptr(t1_rptr),
        .dw_wptr(dw_wptr), .dw_free(dw_free), .out_free(out_free),
        // No twn_res_buf here, so no residual capacity to enforce. Tied rather
        // than left unconnected (Z would make the grant X).
        .has_res(1'b0),
        .busy(seq_busy), .done(seq_done),
        .cyc_total(cyc_total), .cyc_array(cyc_array), .cyc_dw(cyc_dw), .cyc_stall_mem(cyc_stall));

    // ================= the ternary array, shared by E and P =================
    reg  [94:0] uop; reg uop_valid;
    wire arr_busy, arr_done;
    wire [16:0] act_addr, arr_out_addr; wire act_re;
    wire [17:0] w_addr; wire w_re;
    wire [12:0] rq_addr;
    reg  [255:0]  w_data;
    reg  [OCMAX*18-1:0] a_m0; reg [OCMAX*40-1:0] a_bs; reg [OCMAX*6-1:0] a_sh;
    wire [PIX*OCMAX*8-1:0] arr_out; wire arr_out_valid, arr_out_dst;

    reg role;                                   // 0 = E, 1 = P

    // The activation producer's state is declared here because it feeds ports of
    // the instance and `default_nettype none` needs declarations before use.
    reg  [4095:0] act_word;
    reg           act_ready = 1'b1, act_valid = 1'b0;
    wire [4095:0] act_data = act_valid ? act_word : {4096{1'bx}};

    twn_fuse_array #(.LANES(LANES), .PIX(PIX), .OCMAX(OCMAX)) ARR (
        .clk(clk), .rst(rst), .uop(uop), .uop_valid(uop_valid),
        .busy(arr_busy), .done(arr_done),
        .act_addr(act_addr), .act_re(act_re), .act_data(act_data),
        .act_ready(act_ready), .act_valid(act_valid),
        .w_addr(w_addr), .w_re(w_re), .w_data(w_data),
        .rq_addr(rq_addr), .rq_m0(a_m0), .rq_bias(a_bs), .rq_sh(a_sh),
        .out_data(arr_out), .out_valid(arr_out_valid), .out_addr(arr_out_addr),
        .out_dst(arr_out_dst));

    // ---- the array's two synchronous memories, muxed by role: the choice is in
    // the address and the source. Activations have a handshake and are modelled
    // below.
    always @(posedge clk) begin
        if (!role) begin
            w_data   <= wte[w_addr[$clog2(N_WTE)-1:0]];
            a_m0 <= rqe_m0[rq_addr]; a_bs <= rqe_bs[rq_addr]; a_sh <= rqe_sh[rq_addr];
        end else begin
            w_data   <= wtp[w_addr[$clog2(N_WTP)-1:0]];
            a_m0 <= rqp_m0[rq_addr]; a_bs <= rqp_bs[rq_addr]; a_sh <= rqp_sh[rq_addr];
        end
    end

    // ================= the activation producer =================
    // The activation producer model. The array's request is answered after a
    // variable latency (1..ACT_LAT_SPAN cycles from an LFSR: reproducible, but
    // the array cannot tune to it). act_data is X unless act_valid is high.
    // act_ready drops the cycle after a request and stays low for up to
    // ACT_RDY_HOLD further cycles after the answer, so requests have to be
    // retried. A request made while not ready is counted (act_drop) and fails
    // the run: like twn_act_gather, the model has no queue.
    localparam integer ACT_LAT_MIN  = 1;
    localparam integer ACT_LAT_SPAN = 48;
    // The array's earliest next request is four cycles after a delivery, so a
    // hold of 3 or less is always over before it asks again and the refusal
    // would never be exercised.
    localparam integer ACT_RDY_HOLD = 8;

    reg           m_busy = 1'b0, m_role = 1'b0;
    reg  [8:0]    m_lat = 0, m_hold = 0, m_row = 0;
    reg  [16:0]   m_addr = 0;
    reg  [31:0]   m_lfsr = 32'h1357_9BDF;
    integer       act_drop = 0, act_srv = 0, act_wait = 0;
    integer       q, qp;
    reg  [11:0]   p_seg, p_xg, p_ch;

    always @(posedge clk) begin
        if (rst) begin
            act_ready <= 1'b1; act_valid <= 1'b0; m_busy <= 1'b0;
            m_lat <= 0; m_hold <= 0;
        end else begin
            act_valid <= 1'b0;
            m_lfsr <= {m_lfsr[30:0], m_lfsr[31] ^ m_lfsr[21] ^ m_lfsr[1] ^ m_lfsr[0]};
            // ready is a contract: a request made while it is low is counted
            // and ignored, as twn_act_gather does for a request while busy.
            if (act_re && !act_ready) begin
                act_drop = act_drop + 1;
                $display("  *** ACT-DROP: a request arrived while the producer was not ready -- there is no queue ***");
            end
            if (act_re && act_ready) begin
                m_busy    <= 1'b1;
                act_ready <= 1'b0;
                m_addr    <= act_addr;
                m_role    <= role;
                m_row     <= role ? p_row : e_row;
                m_lat     <= ACT_LAT_MIN + (m_lfsr[15:0] % ACT_LAT_SPAN);
                m_hold    <= m_lfsr[19:16] % (ACT_RDY_HOLD + 1);
            end else if (m_busy) begin
                act_wait = act_wait + 1;
                if (m_lat == 0) begin
                    m_busy    <= 1'b0;
                    act_valid <= 1'b1;
                    act_srv   = act_srv + 1;
                    if (!m_role) begin
                        // act_in is (row, seg, xg)-major, so one row is
                        // N_SEG_E*N_XG_E words and act_addr = seg*N_XG_E + xg
                        // indexes within it directly.
                        act_word <= act_in[m_row * (N_SEG_E * N_XG_E) + m_addr];
                    end else begin
                        // P reads the depthwise output row, gathered into 128
                        // lanes x 4 pixels. The segment comes from the address:
                        // channel = seg*LANES + lane, zero beyond C_MID.
                        for (q = 0; q < PIX; q = q + 1)
                            for (qp = 0; qp < LANES; qp = qp + 1) begin
                                p_seg = m_addr / N_XG_P;
                                p_xg  = m_addr % N_XG_P;
                                p_ch  = p_seg * LANES + qp;
                                act_word[(q*LANES + qp)*8 +: 8] <=
                                    (p_ch < C_MID) ? dwbuf[((m_row % D_DW) * C_MID + p_ch) * OW
                                                           + p_xg * PIX + q] : 8'sd0;
                            end
                    end
                end else m_lat <= m_lat - 9'd1;
            end else if (!act_ready) begin
                if (m_hold == 0) act_ready <= 1'b1;
                else m_hold <= m_hold - 9'd1;
            end
        end
    end

    // ================= the depthwise array =================
    reg  dw_v, dw_first, dw_last;
    reg  [7:0] dw_x; reg [7:0] dw_tag;
    reg  [DW_LANES*8-1:0] dw_rt, dw_rm, dw_rb;
    reg  [DW_LANES*9*8-1:0] dw_w;
    reg  [DW_LANES*18-1:0] dw_m0; reg [DW_LANES*32-1:0] dw_bs; reg [DW_LANES*6-1:0] dw_sh;
    wire dw_ov; wire [DW_LANES*8-1:0] dw_od; wire [7:0] dw_ox, dw_otag;

    twn_dw_array #(.DW_LANES(DW_LANES), .ROW_BITS(LANES*8)) DW (
        .clk(clk), .rst(rst),
        // The array's stride input must follow the same per-block value as the
        // sequencer's s_dw.
        .n_ch(C_MID[9:0]), .w_out(OW[7:0]), .stride(S_DW == 2),
        .clamp_lo(16'sd0), .clamp_hi(16'sd127),
        .in_valid(dw_v), .row_t(dw_rt), .row_m(dw_rm), .row_b(dw_rb),
        .in_x(dw_x), .in_first(dw_first), .in_last(dw_last), .in_tag(dw_tag),
        .w_taps(dw_w), .m0(dw_m0), .bias(dw_bs), .sh(dw_sh),
        .out_valid(dw_ov), .out_data(dw_od), .out_x(dw_ox), .out_tag(dw_otag));

    // ================= stage drivers =================
    // Each stage is a task the sequencer's request starts; the request is held
    // for the whole row (twn_blockseq latches ownership), so a task runs to
    // completion and pulses done.
    integer i, r, c, x, g, lg, errors, checked;
    integer t_row, t_slot;
    reg signed [7:0] gv, wv;

    // ---- LD: nothing to move, the input memory is already array-shaped ----
    always @(posedge clk) begin
        if (rst) begin ld_done <= 0; in_wptr <= 0; end
        else begin
            ld_done <= 0;
            if (ld_req && !ld_done && in_wptr == {2'b0, ld_row}) begin
                ld_done <= 1; in_wptr <= in_wptr + 1;
            end
        end
    end

    // ---- ST: the output ring drains; the block's result is captured on the way ----
    always @(posedge clk) begin
        if (rst) st_done <= 0;
        else begin
            st_done <= 0;
            if (st_req && !st_done) st_done <= 1;
        end
    end

    task run_e;
        begin
            role = 0;
            @(negedge clk);
            uop = build_uop(0, N_XG_E*PIX, N_SEG_E[2:0], N_OCG_E, PC_E, 1'b1, 2'd0);
            uop_valid = 1; @(negedge clk); uop_valid = 0;
            while (!arr_done) @(negedge clk);
            @(negedge clk);
        end
    endtask

    task run_p;
        begin
            role = 1;
            @(negedge clk);
            uop = build_uop(1, N_XG_P*PIX, N_SEG_P[2:0], N_OCG_P, PC_P, 1'b0, 2'd1);
            uop_valid = 1; @(negedge clk); uop_valid = 0;
            while (!arr_done) @(negedge clk);
            @(negedge clk);
        end
    endtask

    function [94:0] build_uop;
        input        f_role;
        input [8:0]  f_npix;
        input [2:0]  f_nseg;
        input [9:0]  f_nocg;
        input [1:0]  f_pack;
        input        f_relu;
        input [1:0]  f_otype;
        begin
            build_uop = 95'd0;
            build_uop[0]     = f_role;
            build_uop[18:10] = f_npix;
            // n_seg is MINUS-ONE encoded (see twn_fuse_array.v): the network
            // needs up to 8 segments and 8 does not fit in three bits.
            build_uop[21:19] = f_nseg - 3'd1;
            build_uop[31:22] = f_nocg;
            build_uop[33:32] = f_pack;
            build_uop[82]    = f_relu;
            build_uop[84:83] = f_otype;
            build_uop[85]    = f_role;
            build_uop[86]    = 1'b1;
            build_uop[87]    = 1'b1;
            build_uop[90]    = f_role ? 1'b0 : (MSG_E != 0);   // expand only
        end
    endfunction

    // ---- capture the array's output into the right row buffer ----
    integer cp, cc, cbase;
    always @(posedge clk) if (!rst && arr_out_valid) begin
        // out_addr is channel-group major: ocg * n_xg + xg.
        if (!role) begin
            cbase = (arr_out_addr / N_XG_E) * PACK_E;
            for (cp = 0; cp < PIX; cp = cp + 1)
                for (cc = 0; cc < PACK_E; cc = cc + 1)
                    t1buf[(((e_row % D_T1) * C_MID) + cbase + cc) * IW
                          + (arr_out_addr % N_XG_E) * PIX + cp]
                        <= arr_out[(cp*OCMAX + cc)*8 +: 8];
        end else begin
            // PACK_P channels per beat per pixel slot (pack_p is 4 for blocks
            // whose project n_eff <= 32).
            cbase = (arr_out_addr / N_XG_P) * PACK_P;
            for (cp = 0; cp < PIX; cp = cp + 1)
                for (cc = 0; cc < PACK_P; cc = cc + 1)
                    outbuf[(((p_row % D_OUT) * C_OUT) + cbase + cc) * OW
                           + (arr_out_addr % N_XG_P) * PIX + cp]
                        <= arr_out[(cp*OCMAX + cc)*8 +: 8];
        end
    end

    // ---- E / P stage control ----
    reg e_run, p_run;
    always @(posedge clk) begin
        if (rst) begin e_done <= 0; p_done <= 0; t1_wptr <= 0; out_cnt <= 0; e_run <= 0; p_run <= 0; end
        else begin e_done <= 0; p_done <= 0; end
    end

    // ---- D: walk the row, lane group by lane group ----
    task run_d;
        integer dr, dg, dx, dj, base_t, base_m, base_b, iy;
        begin
            for (dg = 0; dg < N_LG; dg = dg + 1) begin
                dw_w  = wdw[dg]; dw_m0 = rqd_m0[dg]; dw_bs = rqd_bs[dg]; dw_sh = rqd_sh[dg];
                dw_tag = dg[7:0];
                for (dx = 0; dx <= IW; dx = dx + 1) begin
                    @(negedge clk);
                    dw_v = (dx < IW);
                    dw_x = dx[7:0];
                    dw_first = (dx == 0);
                    dw_last  = (dx == IW-1);
                    for (dj = 0; dj < DW_LANES; dj = dj + 1) begin
                        iy = d_row*S_DW - 1;
                        dw_rt[dj*8 +: 8] = (iy < 0) ? 8'sd0 :
                            t1buf[(((iy % D_T1) * C_MID) + dg*DW_LANES + dj) * IW + (dx < IW ? dx : 0)];
                        iy = d_row*S_DW;
                        dw_rm[dj*8 +: 8] =
                            t1buf[(((iy % D_T1) * C_MID) + dg*DW_LANES + dj) * IW + (dx < IW ? dx : 0)];
                        iy = d_row*S_DW + 1;
                        dw_rb[dj*8 +: 8] = (iy >= IH) ? 8'sd0 :
                            t1buf[(((iy % D_T1) * C_MID) + dg*DW_LANES + dj) * IW + (dx < IW ? dx : 0)];
                    end
                end
                @(negedge clk); dw_v = 0;
                // Short drain. The depthwise stage is checked just before the
                // project stage reads dwbuf, not here, because the last column
                // may still be in twn_dw_array's pipeline when run_d returns.
                repeat (6) @(negedge clk);
            end
        end
    endtask

    always @(posedge clk) if (!rst && dw_ov && dw_ox < OW)
        for (cc = 0; cc < DW_LANES; cc = cc + 1)
            if (dw_otag*DW_LANES + cc < C_MID)
                dwbuf[(((d_row % D_DW) * C_MID) + dw_otag*DW_LANES + cc) * OW + dw_ox]
                    <= dw_od[cc*8 +: 8];

    // ================= the block =================
    integer guard;
    real busy_pct;
    initial begin
        uop = 0; uop_valid = 0; role = 0;
        dw_v = 0; dw_first = 0; dw_last = 0; dw_x = 0; dw_tag = 0;
        t1_wptr = 0; dw_wptr = 0; out_cnt = 0;
        errors = 0; checked = 0; err_e = 0; err_d = 0; chk_e = 0; chk_d = 0;
        err_p = 0; chk_p = 0;
        $display("=== P4 block 1: %0d -> %0d -> %0d, %0dx%0d -> %0dx%0d ===",
                 C_IN, C_MID, C_OUT, IH, IW, OH, OW);
        repeat (4) @(negedge clk); rst = 0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        $display("  (driven by the sequencer's requests; see tb_p4_block_run below)");
        #1;
    end

    // ---- three processes, one per independent resource ----
    // The array (E or P) and the depthwise run concurrently; E and P are
    // mutually exclusive because twn_blockseq latches ownership for a row. This
    // process relies on that, so a sequencer granting both would show up as a
    // corrupted row.
    reg e_run_tb, p_run_tb, d_run_tb;

    initial begin
        e_run_tb = 0; p_run_tb = 0;
        @(negedge rst);
        forever begin
            @(negedge clk);
            if (e_req && !e_run_tb && !p_run_tb) begin
                e_run_tb = 1;
                run_e;
                // check this expand row against the golden before anything
                // downstream uses it
                for (c = 0; c < C_MID; c = c + 1)
                    for (x = 0; x < IW; x = x + 1) begin
                        chk_e = chk_e + 1;
                        if ($signed(t1buf[((e_row % D_T1) * C_MID + c) * IW + x])
                            !== $signed(golde[(c * IH + e_row) * IW + x])) begin
                            err_e = err_e + 1;
                            if (err_e <= 6)
                                $display("  E-MISMATCH row=%0d c=%0d x=%0d  got %0d want %0d",
                                    e_row, c, x,
                                    $signed(t1buf[((e_row % D_T1) * C_MID + c) * IW + x]),
                                    $signed(golde[(c * IH + e_row) * IW + x]));
                        end
                    end
                e_done = 1; t1_wptr = t1_wptr + 1;
                @(negedge clk); e_done = 0; e_run_tb = 0;
            end else if (p_req && !e_run_tb && !p_run_tb) begin
                p_run_tb = 1;
                // The depthwise stage check lives here, right before the
                // project stage consumes the row, where the data is guaranteed
                // to be present.
                for (c = 0; c < C_MID; c = c + 1)
                    for (x = 0; x < OW; x = x + 1) begin
                        chk_d = chk_d + 1;
                        // An X (location never written) is counted apart from a
                        // wrong value.
                        if (^dwbuf[((p_row % D_DW) * C_MID + c) * OW + x] === 1'bx)
                            nx_d = nx_d + 1;
                        if ($signed(dwbuf[((p_row % D_DW) * C_MID + c) * OW + x])
                            !== $signed(goldd[(c * OH + p_row) * OW + x])) begin
                            err_d = err_d + 1;
                            if (err_d <= 6)
                                $display("  D-MISMATCH row=%0d c=%0d x=%0d  got %0d want %0d",
                                    p_row, c, x,
                                    $signed(dwbuf[((p_row % D_DW) * C_MID + c) * OW + x]),
                                    $signed(goldd[(c * OH + p_row) * OW + x]));
                        end
                    end
                run_p;
                // capture this output row before the ring reuses its slot
                for (c = 0; c < C_OUT; c = c + 1)
                    for (x = 0; x < OW; x = x + 1) begin : CAP
                        reg signed [7:0]  pv;
                        reg signed [63:0] rt, rr;
                        pv = outbuf[((p_row % D_OUT) * C_OUT + c) * OW + x];
                        if (!HAS_RES) begin
                            got[(c * OH + p_row) * OW + x] = pv;
                        end else begin
                            // check the project output on its own first, so a
                            // residual block that fails says which half did it
                            chk_p = chk_p + 1;
                            if (pv !== $signed(goldp[(c * OH + p_row) * OW + x])) begin
                                err_p = err_p + 1;
                                if (err_p <= 6)
                                    $display("  P-MISMATCH row=%0d c=%0d x=%0d  got %0d want %0d",
                                        p_row, c, x, pv,
                                        $signed(goldp[(c * OH + p_row) * OW + x]));
                            end
                            rt = $signed({{56{pv[7]}}, pv}) * RES_MP
                               + $signed({{56{resrc[(c*OH + p_row)*OW + x][7]}},
                                          resrc[(c*OH + p_row)*OW + x]}) * RES_MQ;
                            rr = (RES_SH == 0) ? rt
                               : ((rt + (64'sd1 <<< (RES_SH - 1))) >>> RES_SH);
                            if (rr < RES_LO) rr = RES_LO;
                            if (rr > RES_HI) rr = RES_HI;
                            got[(c * OH + p_row) * OW + x] = rr[7:0];
                        end
                    end
                p_done = 1; out_cnt = out_cnt + 1;
                @(negedge clk); p_done = 0; p_run_tb = 0;
            end
        end
    end

    // ================= the residual, through twn_res_add =================
    // The loop above computes the residual in the testbench and produces got[].
    // Here goldp and the block input drive twn_res_add and its output is
    // compared with got[] on every element.
    // p_in is sign-extended int8: every block's project clamp is [-127, 127].
    reg               ra_valid = 1'b0;
    reg  [4*16-1:0]   ra_p, ra_x;
    wire [4*8-1:0]    ra_out;
    wire              ra_out_valid;
    integer chk_r, err_r;

    twn_res_add #(.LANES(4)) RA (
        .clk(clk), .rst(rst),
        .mp(RES_MP[17:0]), .mq(RES_MQ[17:0]), .sh(RES_SH[5:0]),
        .lo(RES_LO[15:0]), .hi(RES_HI[15:0]),
        .in_valid(ra_valid), .p_in(ra_p), .x_in(ra_x), .in_tag(8'd0),
        .out_valid(ra_out_valid), .out_data(ra_out), .out_tag());

    task res_sweep;
        integer i, j, nval;
        reg signed [7:0] pv8, xv8, want8;
        begin
            chk_r = 0; err_r = 0;
            nval = C_OUT * OH * OW;
            for (i = 0; i < nval; i = i + 4) begin
                for (j = 0; j < 4; j = j + 1) begin
                    if (i + j < nval) begin
                        pv8 = goldp[i + j];
                        xv8 = resrc[i + j];
                    end else begin
                        pv8 = 8'sd0; xv8 = 8'sd0;
                    end
                    ra_p[j*16 +: 16] = {{8{pv8[7]}}, pv8};
                    ra_x[j*16 +: 16] = {{8{xv8[7]}}, xv8};
                end
                ra_valid = 1'b1;
                @(negedge clk);
                ra_valid = 1'b0;
                repeat (3) @(negedge clk);
                for (j = 0; j < 4; j = j + 1)
                    if (i + j < nval) begin
                        chk_r = chk_r + 1;
                        want8 = got[i + j];
                        if (ra_out[j*8 +: 8] !== want8) begin
                            err_r = err_r + 1;
                            if (err_r <= 6)
                                $display("  R-MISMATCH idx=%0d  module %0d  model %0d",
                                         i + j, $signed(ra_out[j*8 +: 8]), want8);
                        end
                    end
            end
        end
    endtask

    initial begin
        d_run_tb = 0;
        @(negedge rst);
        forever begin
            @(negedge clk);
            if (d_req && !d_run_tb) begin
                d_run_tb = 1;
                run_d;
                for (c = 0; c < 0; c = c + 1)     // moved to the project stage
                    for (x = 0; x < OW; x = x + 1) begin
                        chk_d = chk_d + 1;
                        if (^dwbuf[((d_row % D_DW) * C_MID + c) * OW + x] === 1'bx)
                            nx_d = nx_d + 1;
                        if ($signed(dwbuf[((d_row % D_DW) * C_MID + c) * OW + x])
                            !== $signed(goldd[(c * OH + d_row) * OW + x])) begin
                            err_d = err_d + 1;
                            if (err_d <= 6)
                                $display("  D-MISMATCH row=%0d c=%0d x=%0d  got %0d want %0d",
                                    d_row, c, x,
                                    $signed(dwbuf[((d_row % D_DW) * C_MID + c) * OW + x]),
                                    $signed(goldd[(c * OH + d_row) * OW + x]));
                        end
                    end
                d_done = 1; dw_wptr = dw_wptr + 1;
                @(negedge clk); d_done = 0; d_run_tb = 0;
            end
        end
    end

    // ---- completion and the check ----
    initial begin
        guard = 0;
        @(negedge rst);
        while (!seq_done && guard < 6000000) begin @(negedge clk); guard = guard + 1; end
        if (guard >= 6000000) begin
            $display("  *** stuck: e %0d d %0d p %0d st %0d  (t1_wptr %0d rptr %0d dw_wptr %0d)",
                     e_row, d_row, p_row, st_row, t1_wptr, t1_rptr, dw_wptr);
            $display("=== tb_p4_block: FAIL (no completion) ===");
            $finish;
        end
        for (c = 0; c < C_OUT; c = c + 1)
            for (r = 0; r < OH; r = r + 1)
                for (x = 0; x < OW; x = x + 1) begin
                    checked = checked + 1;
                    gv = gold[(c * OH + r) * OW + x];
                    if (got[(c * OH + r) * OW + x] !== gv) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("  MISMATCH c=%0d r=%0d x=%0d  got %0d  want %0d",
                                     c, r, x, got[(c*OH+r)*OW+x], gv);
                    end
                end
        if (HAS_RES) res_sweep;
        busy_pct = 100.0 * cyc_array / cyc_total;
        $display("");
        $display("  cycles %0d   array busy %0d = %.2f%%   dw %0d   stalled %0d",
                 cyc_total, cyc_array, busy_pct, cyc_dw, cyc_stall);
        // The stage error counts feed the verdict.
        errors = errors + err_e + err_d + err_p;
        $display("  expand   %0d checked, %0d errors", chk_e, err_e);
        if (HAS_RES) begin
            $display("  project  %0d checked, %0d errors  (before the residual)", chk_p, err_p);
            $display("  residual %0d checked, %0d errors  (twn_res_add vs the model)",
                     chk_r, err_r);
            errors = errors + err_r;
        end
        $display("  depthwise %0d checked, %0d errors%s", chk_d, err_d,
                 (nx_d != 0) ? $sformatf("  (%0d never written)", nx_d) : "");
        // An X is a failure of this testbench.
        errors = errors + nx_d;
        // A drop is counted here because this is the only side that sees it:
        // twn_act_gather has no queue, so a request made while busy is lost.
        $display("  activations: %0d served, %0d cycles waited, %0d dropped",
                 act_srv, act_wait, act_drop);
        errors = errors + act_drop;
        $display("  %0d values checked, %0d errors", checked, errors);
        if (errors == 0) $display("=== tb_p4_block: ALL PASS ===");
        else             $display("=== tb_p4_block: %0d FAIL ===", errors);
        $finish;
    end

endmodule
`default_nettype wire
