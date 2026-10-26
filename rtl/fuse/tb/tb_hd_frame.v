`timescale 1ns/1ps
// ============================================================================
//  tb_hd_frame.v -- bit-exact test of twn_hd_compute (rtl/src) on the four head
//  operators op61..op64 (three 4x4 stride-2 transposed convs and the final 1x1).
//
//  Golden data: hd_op<61..64>_in.hex / _w.hex / _out.hex and hd_rq.hex, written
//  by tools/hd_ref_export.py into rtl/fuse/tb/hd_vec. The exporter writes them
//  only if its reference reproduces the fixture's per-operator checksums, all
//  acc_ref elements and kp_ref. Operator N's output file is operator N+1's
//  input. Every output element is compared; per operator it prints elements
//  compared, elements wrong, max|diff|, and the first bad element as (oy, ox, oc).
//  op64 is run with OC padded 14 -> 16; the pad lanes are compared too and the
//  report also gives the count for the real channels (oc < 14).
//
//  Not covered: AXI, DDR and the movers. The streams are fed and drained here,
//  so this checks arithmetic and stream order only.
//
//  twn_hd_seq runs alongside as an oracle: the four descriptors are written into
//  it and the configuration it derives (ic, oc, h, w, mode_a, type4, relu) is
//  compared with the one these vectors assume. The count of its m_in_start
//  pulses per operator is printed, not asserted. m_in_done is not connected
//  here, so the sequencer's mode-A input re-issue never fires and the count is
//  1 per operator; mode A itself is fed here by replaying the input P_PASS times.
//
//  Defines: HD_FRAME_STALL  varying out_sr (output must not change)
//           HD_FRAME_NOSEQ  drop the oracle
//
//  Vector files are read by relative path from the current directory.
//  sim/run_hd_frame.ps1 copies them into each arm's scratch directory, runs
//  from there, and has a second arm that flips one golden nibble of
//  hd_op63_out.hex (expected: exactly 1 wrong element, max|diff| 1).
//  Prints "tb_hd_frame: PASS" or "tb_hd_frame: N FAILURES".
// ============================================================================
`default_nettype none
module tb_hd_frame;

    // ---- vector sizes. run_hd_frame.ps1 checks the .hex line counts against
    // these before it runs.
    localparam XMAX = 8192;      // op64 input  = 64*64*32 / 16
    localparam WMAX = 10240;     // op61 slice weights = 320*32*16 / 16
    localparam OMAX = 16384;     // op64 output = 64*64*16 int32 / 4

    reg clk = 1'b0;  always #5 clk = ~clk;
    reg rst;

    // ---------------- engine interface ----------------
    reg          start;
    wire         done;
    reg  [8:0]   IC_i;
    reg  [5:0]   OC_i;
    reg  [6:0]   H_i, W_i;
    reg          mode_a, type4, relu_i;
    reg  signed [15:0] lo_i, hi_i;
    reg          in_sv;  wire in_sr;  reg [127:0] in_sd;
    reg          w_sv;   wire w_sr;   reg [127:0] w_sd;
    wire         out_sv; reg  out_sr; wire [127:0] out_sd;
    reg          m0_we, bias_we, sh_we;
    reg  [9:0]   rq_wa;
    reg  signed [31:0] m0_wd;
    reg  signed [63:0] bias_wd;
    reg  [5:0]   sh_wd;

    twn_hd_compute u_hd (
        .clk(clk), .rst(rst), .start(start), .done(done),
        .IC_i(IC_i), .OC_i(OC_i), .H_i(H_i), .W_i(W_i),
        .mode_a(mode_a), .type4(type4), .relu_i(relu_i),
        .lo_i(lo_i), .hi_i(hi_i),
        .in_sv(in_sv), .in_sr(in_sr), .in_sd(in_sd),
        .w_sv(w_sv),   .w_sr(w_sr),   .w_sd(w_sd),
        .m0_we(m0_we), .rq_wa(rq_wa), .m0_wd(m0_wd),
        .bias_we(bias_we), .bias_wd(bias_wd),
        .sh_we(sh_we), .sh_wd(sh_wd),
        .out_sv(out_sv), .out_sr(out_sr), .out_sd(out_sd));

    // ---------------- vector storage ----------------
    reg [127:0] xrom [0:XMAX-1];
    reg [127:0] wrom [0:WMAX-1];
    reg [127:0] orom [0:OMAX-1];
    reg [127:0] cap  [0:OMAX-1];
    reg [127:0] rqrom[0:127];              // 4 ops x 32 oc: {m0[31:0], bias[63:0], sh[31:0]}

    // ---------------- the four operators ----------------
    // Shapes of op61..op64; beat counts match the .hex files written by
    // tools/hd_ref_export.py (see hd_vec_manifest.json).
    integer P_IC   [0:3]; integer P_OC   [0:3];   // OC as the ENGINE sees it (op64: 16, padded)
    integer P_H    [0:3]; integer P_W    [0:3];
    integer P_OH   [0:3]; integer P_OW   [0:3];
    integer P_MA   [0:3]; integer P_T4   [0:3]; integer P_SLICE[0:3];
    integer P_RELU [0:3]; integer P_LO   [0:3]; integer P_HI  [0:3];
    integer P_INB  [0:3]; integer P_PASS [0:3];   // input beats per pass, and passes
    integer P_WB   [0:3]; integer P_OUTB [0:3];
    integer P_RQN  [0:3];                         // rq entries to program (0 for type 4)

    initial begin
        //        op61     op62     op63     op64
        P_IC[0]=320;  P_IC[1]=32;   P_IC[2]=32;   P_IC[3]=32;
        P_OC[0]=32;   P_OC[1]=32;   P_OC[2]=32;   P_OC[3]=16;
        P_H [0]=8;    P_H [1]=16;   P_H [2]=32;   P_H [3]=64;
        P_W [0]=8;    P_W [1]=16;   P_W [2]=32;   P_W [3]=64;
        P_OH[0]=16;   P_OH[1]=32;   P_OH[2]=64;   P_OH[3]=64;
        P_OW[0]=16;   P_OW[1]=32;   P_OW[2]=64;   P_OW[3]=64;
        P_MA[0]=1;    P_MA[1]=0;    P_MA[2]=0;    P_MA[3]=0;
        P_T4[0]=0;    P_T4[1]=0;    P_T4[2]=0;    P_T4[3]=1;
        P_SLICE[0]=1; P_SLICE[1]=0; P_SLICE[2]=0; P_SLICE[3]=0;
        P_RELU[0]=1;  P_RELU[1]=1;  P_RELU[2]=1;  P_RELU[3]=0;
        P_LO[0]=0;    P_LO[1]=0;    P_LO[2]=0;    P_LO[3]=0;
        P_HI[0]=127;  P_HI[1]=127;  P_HI[2]=127;  P_HI[3]=0;
        P_INB [0]=1280; P_INB [1]=512;  P_INB [2]=2048; P_INB [3]=8192;
        // Mode A re-reads the whole input once per (phase, ocg) slice:
        // 4 phases x OC/8 groups = 16 for op61.
        P_PASS[0]=16;   P_PASS[1]=1;    P_PASS[2]=1;    P_PASS[3]=1;
        P_WB  [0]=10240; P_WB [1]=1024; P_WB [2]=1024;  P_WB [3]=32;
        P_OUTB[0]=512;  P_OUTB[1]=2048; P_OUTB[2]=8192; P_OUTB[3]=16384;
        P_RQN [0]=32;   P_RQN [1]=32;   P_RQN [2]=32;   P_RQN [3]=0;
    end

    // ---------------- stream feeders ----------------
    // valid is combinational on the accept counters, not registered, so that
    // no beat past the end can be accepted: "the engine consumed exactly the
    // beats expected" is one of the checks.
    //
    // A few extra beats (OVER_IN, OVER_W) are let through so an engine that
    // wants more than the tensor holds is reported as xi != expected rather than
    // as a hang.
    localparam OVER_IN = 64, OVER_W = 16;
    reg         feed_en, cap_clr;
    reg  [17:0] x_tot;            // total input beats this operator should take
    reg  [13:0] x_pass;           // beats in ONE pass (the wrap point)
    reg  [17:0] xi;               // input beats accepted
    reg  [13:0] xa;               // address within the current pass
    reg  [13:0] w_tot, wi;
    reg  [15:0] optr;             // output beats captured
    reg  [15:0] ovf;              // output beats past the expected count

    always @(*) in_sv = feed_en && (xi < x_tot + OVER_IN);
    always @(*) w_sv  = feed_en && (wi < w_tot + OVER_W);
    always @(*) in_sd = xrom[xa];
    always @(*) w_sd  = wrom[(wi < WMAX) ? wi : 14'd0];

    always @(posedge clk) begin
        if (!feed_en) begin
            xi <= 18'd0; xa <= 14'd0; wi <= 14'd0;
        end else begin
            if (in_sv && in_sr) begin
                xi <= xi + 18'd1;
                xa <= (xa == x_pass - 14'd1) ? 14'd0 : xa + 14'd1;
            end
            if (w_sv && w_sr) wi <= wi + 14'd1;
        end
    end

    // ---- output sink ------------------------------------------------------
`ifdef HD_FRAME_STALL
    // Varying ready (LFSR): the drain is exercised with gaps; output bytes must
    // not change.
    reg [7:0] lf = 8'd0;
    always @(posedge clk) lf <= {lf[6:0], lf[7] ~^ lf[5]};
    always @(posedge clk) out_sr <= (lf[2:0] > 3'd2);
    initial begin out_sr = 1'b1; $display("[tb_hd_frame] HD_FRAME_STALL is ON"); end
`else
    initial out_sr = 1'b1;
`endif
    always @(posedge clk) begin
        if (cap_clr) begin optr <= 16'd0; ovf <= 16'd0; end
        else if (out_sv && out_sr) begin
            if (optr < OMAX) begin cap[optr] <= out_sd; optr <= optr + 16'd1; end
            else ovf <= ovf + 16'd1;
        end
    end

    // ---------------- stall detector ----------------
    // On a stall print the handshake state; rerunning with +HD_STUCK makes the
    // engine print its own wait state.
    reg [31:0] cyc, idle_cnt, op_t0;
    integer cur_k;
    initial begin cyc = 0; idle_cnt = 0; cur_k = 0; op_t0 = 0; end
    always @(posedge clk) begin
        cyc <= cyc + 32'd1;
        if (rst || start || done || (in_sv && in_sr) || (w_sv && w_sr) ||
            (out_sv && out_sr) || m0_we)
            idle_cnt <= 32'd0;
        else
            idle_cnt <= idle_cnt + 32'd1;
        if (idle_cnt == 32'd200000) begin
            $display("FAIL tb_hd_frame: STALLED on op%0d after %0d idle cycles",
                     61 + cur_k, idle_cnt);
            $display("   in  %0d / %0d beats accepted (in_sv=%b in_sr=%b)",
                     xi, x_tot, in_sv, in_sr);
            $display("   w   %0d / %0d beats accepted (w_sv=%b w_sr=%b)",
                     wi, w_tot, w_sv, w_sr);
            $display("   out %0d / %0d beats captured (out_sv=%b out_sr=%b)",
                     optr, P_OUTB[cur_k], out_sv, out_sr);
            $display("   rerun with +HD_STUCK to have the engine name its own wait state");
            $finish;
        end
    end

    // ============================================================
    //  twn_hd_seq as an ORACLE (see the header).
    // ============================================================
    reg          hs_start, hs_e_done, hs_out_done;
    reg          hs_d_we; reg [1:0] hs_d_wa;
    reg  [39:0]  hs_d_in_base, hs_d_w_base, hs_d_out_base;
    reg  [23:0]  hs_d_in_beats, hs_d_w_beats, hs_d_out_beats;
    reg  [8:0]   hs_d_ic; reg [5:0] hs_d_oc; reg [6:0] hs_d_h, hs_d_w;
    reg          hs_d_type4, hs_d_slice, hs_d_relu;
    reg  [15:0]  hs_d_lo, hs_d_hi;
    wire         hs_busy, hs_done; wire [1:0] hs_cur_op;
    wire [39:0]  hs_m_in_base, hs_m_w_base, hs_m_out_base;
    wire [23:0]  hs_m_in_beats, hs_m_w_beats, hs_m_out_beats;
    wire         hs_m_in_start, hs_m_w_start, hs_m_out_start, hs_es;
    wire [8:0]   hs_e_ic; wire [5:0] hs_e_oc; wire [6:0] hs_e_h, hs_e_w;
    wire         hs_e_mode_a, hs_e_type4, hs_e_relu;
    wire signed [15:0] hs_e_lo, hs_e_hi;
    integer      seq_err, seq_in_pulses [0:3];
    integer      si;

    task seqbad(input [64*8:1] nm, input integer got, input integer want);
        begin
            seq_err = seq_err + 1;
            $display("FAIL hd_seq oracle: op%0d field %0s derived %0d, vectors assume %0d",
                     61 + hs_cur_op, nm, got, want);
        end
    endtask

`ifndef HD_FRAME_NOSEQ
    twn_hd_seq #(.NOPS(4)) u_seq (
        .clk(clk), .rst(rst), .start(hs_start),
        .busy(hs_busy), .done(hs_done), .cur_op(hs_cur_op),
        .d_we(hs_d_we), .d_wa(hs_d_wa),
        .d_in_base(hs_d_in_base), .d_w_base(hs_d_w_base), .d_out_base(hs_d_out_base),
        .d_in_beats(hs_d_in_beats), .d_w_beats(hs_d_w_beats), .d_out_beats(hs_d_out_beats),
        .d_ic(hs_d_ic), .d_oc(hs_d_oc), .d_h(hs_d_h), .d_w(hs_d_w),
        .d_type4(hs_d_type4), .d_slice(hs_d_slice), .d_relu(hs_d_relu),
        .d_lo(hs_d_lo), .d_hi(hs_d_hi),
        // Requantisation write port tied off: this file loads the engine's
        // requant entries directly (wrq), so the oracle has no table to replay.
        .rq_we(1'b0), .rq_wa(8'd0), .rq_wd(32'd0),
        .slot_off(40'd0),
        .m_in_base(hs_m_in_base), .m_in_beats(hs_m_in_beats),
        .m_w_base(hs_m_w_base), .m_w_beats(hs_m_w_beats),
        .m_out_base(hs_m_out_base), .m_out_beats(hs_m_out_beats),
        .m_in_start(hs_m_in_start), .m_w_start(hs_m_w_start),
        .m_out_start(hs_m_out_start), .m_out_done(hs_out_done),
        .e_start(hs_es), .e_done(hs_e_done),
        .e_ic(hs_e_ic), .e_oc(hs_e_oc), .e_h(hs_e_h), .e_w(hs_e_w),
        .e_mode_a(hs_e_mode_a), .e_type4(hs_e_type4), .e_relu(hs_e_relu),
        .e_lo(hs_e_lo), .e_hi(hs_e_hi));

    // Count the sequencer's input-mover starts per operator. Mode A needs 16
    // passes over op61's input; anything less and the engine starves in the
    // real shell no matter how exact its arithmetic is.
    always @(posedge clk)
        if (!rst && hs_m_in_start)
            seq_in_pulses[hs_cur_op] = seq_in_pulses[hs_cur_op] + 1;

    // The oracle's whole point: does the DERIVED configuration match the one
    // these vectors were generated for? Checked on the sequencer's own e_start.
    always @(posedge clk) if (!rst && hs_es) begin
        if (hs_e_ic     !== P_IC[hs_cur_op][8:0])  seqbad("ic",   hs_e_ic,     P_IC[hs_cur_op]);
        if (hs_e_oc     !== P_OC[hs_cur_op][5:0])  seqbad("oc",   hs_e_oc,     P_OC[hs_cur_op]);
        if (hs_e_h      !== P_H [hs_cur_op][6:0])  seqbad("h",    hs_e_h,      P_H [hs_cur_op]);
        if (hs_e_w      !== P_W [hs_cur_op][6:0])  seqbad("w",    hs_e_w,      P_W [hs_cur_op]);
        if (hs_e_mode_a !== P_MA[hs_cur_op][0])    seqbad("mode_a", hs_e_mode_a, P_MA[hs_cur_op]);
        if (hs_e_type4  !== P_T4[hs_cur_op][0])    seqbad("type4", hs_e_type4, P_T4[hs_cur_op]);
        if (hs_e_relu   !== P_RELU[hs_cur_op][0])  seqbad("relu", hs_e_relu,   P_RELU[hs_cur_op]);
    end
`endif

    // ============================================================
    //  the run
    // ============================================================
    integer k, i, j, idx, e_cnt, e_bad, e_first, e_real, e_realbad, xbeats;
    integer f_oy, f_ox, f_oc;
    integer errors, tot_cnt, tot_bad, op_cyc;
    reg signed [63:0] dmax, dv;
    reg signed [63:0] got_v, want_v;
    reg [127:0] cw, ow;

    task wrq(input [9:0] a, input [127:0] word);
        begin
            @(negedge clk);
            m0_we = 1; bias_we = 1; sh_we = 1; rq_wa = a;
            m0_wd = word[127:96]; bias_wd = word[95:32]; sh_wd = word[5:0];
            @(negedge clk);
            m0_we = 0; bias_we = 0; sh_we = 0;
        end
    endtask

    // Wipe before every $readmemh. xsim does NOT stop when a memory file is
    // missing -- it warns and leaves the array untouched -- so without the wipe
    // a second operator would silently compare against the first one's data.
    // With it a missing file shows up as X and is reported by name.
    task wipe;
        integer q;
        begin
            for (q = 0; q < XMAX; q = q + 1) xrom[q] = {128{1'bx}};
            for (q = 0; q < WMAX; q = q + 1) wrom[q] = {128{1'bx}};
            for (q = 0; q < OMAX; q = q + 1) begin orom[q] = {128{1'bx}};
                                                   cap [q] = {128{1'bx}}; end
        end
    endtask

    task loaded_or_die(input [64*8:1] nm, input [127:0] first, input [127:0] last);
        begin
            if ((^first === 1'bx) || (^last === 1'bx)) begin
                $display("FAIL tb_hd_frame: %0s did not load (first=%032x last=%032x).",
                         nm, first, last);
                $display("   run tools/hd_ref_export.py, and run this gate from the directory holding the .hex files");
                $finish;
            end
        end
    endtask

    initial begin
        errors = 0; seq_err = 0; tot_cnt = 0; tot_bad = 0;
        for (si = 0; si < 4; si = si + 1) seq_in_pulses[si] = 0;
        rst = 1; start = 0; feed_en = 0; cap_clr = 1;
        m0_we = 0; bias_we = 0; sh_we = 0; rq_wa = 0; m0_wd = 0; bias_wd = 0; sh_wd = 0;
        IC_i = 0; OC_i = 0; H_i = 0; W_i = 0;
        mode_a = 0; type4 = 0; relu_i = 0; lo_i = 0; hi_i = 0;
        x_tot = 0; x_pass = 1; w_tot = 0;
        hs_start = 0; hs_e_done = 0; hs_out_done = 0; hs_d_we = 0; hs_d_wa = 0;
        hs_d_in_base = 0; hs_d_w_base = 0; hs_d_out_base = 0;
        hs_d_in_beats = 0; hs_d_w_beats = 0; hs_d_out_beats = 0;
        hs_d_ic = 0; hs_d_oc = 0; hs_d_h = 0; hs_d_w = 0;
        hs_d_type4 = 0; hs_d_slice = 0; hs_d_relu = 0; hs_d_lo = 0; hs_d_hi = 0;

        $readmemh("hd_rq.hex", rqrom);
        if (^rqrom[0] === 1'bx) begin
            $display("FAIL tb_hd_frame: hd_rq.hex did not load"); $finish;
        end

        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ---- descriptors into the oracle, then release its walk -------------
        // Bases are unused here (no movers) but made distinct per operator.
        for (k = 0; k < 4; k = k + 1) begin
            @(negedge clk);
            hs_d_wa        = k[1:0];
            hs_d_in_base   = 40'h20_0000_0000 + (k << 20);
            hs_d_w_base    = 40'h30_0000_0000 + (k << 21);
            hs_d_out_base  = 40'h40_0000_0000 + (k << 22);
            hs_d_in_beats  = P_INB[k] * P_PASS[k];
            hs_d_w_beats   = P_WB[k];
            hs_d_out_beats = P_OUTB[k];
            hs_d_ic        = P_IC[k][8:0];
            hs_d_oc        = P_OC[k][5:0];
            hs_d_h         = P_H[k][6:0];
            hs_d_w         = P_W[k][6:0];
            hs_d_type4     = P_T4[k][0];
            hs_d_slice     = P_SLICE[k][0];
            hs_d_relu      = P_RELU[k][0];
            hs_d_lo        = P_LO[k][15:0];
            hs_d_hi        = P_HI[k][15:0];
            hs_d_we        = 1'b1;
            @(negedge clk);
            hs_d_we        = 1'b0;
        end
        @(negedge clk); hs_start = 1'b1; @(negedge clk); hs_start = 1'b0;

        $display("=== tb_hd_frame: four head operators, every output element ===");

        for (k = 0; k < 4; k = k + 1) begin
            cur_k = k;
            wipe;
            case (k)
              0: begin $readmemh("hd_op61_in.hex",  xrom);
                       $readmemh("hd_op61_w.hex",   wrom);
                       $readmemh("hd_op61_out.hex", orom); end
              1: begin $readmemh("hd_op62_in.hex",  xrom);
                       $readmemh("hd_op62_w.hex",   wrom);
                       $readmemh("hd_op62_out.hex", orom); end
              2: begin $readmemh("hd_op63_in.hex",  xrom);
                       $readmemh("hd_op63_w.hex",   wrom);
                       $readmemh("hd_op63_out.hex", orom); end
              3: begin $readmemh("hd_op64_in.hex",  xrom);
                       $readmemh("hd_op64_w.hex",   wrom);
                       $readmemh("hd_op64_out.hex", orom); end
            endcase
            loaded_or_die("input vector",  xrom[0], xrom[P_INB[k] - 1]);
            loaded_or_die("weight vector", wrom[0], wrom[P_WB[k] - 1]);
            loaded_or_die("golden output", orom[0], orom[P_OUTB[k] - 1]);

            IC_i   = P_IC[k][8:0];
            OC_i   = P_OC[k][5:0];
            H_i    = P_H[k][6:0];
            W_i    = P_W[k][6:0];
            mode_a = P_MA[k][0];
            type4  = P_T4[k][0];
            relu_i = P_RELU[k][0];
            lo_i   = P_LO[k][15:0];
            hi_i   = P_HI[k][15:0];
            x_pass = P_INB[k][13:0];
            x_tot  = P_INB[k] * P_PASS[k];
            w_tot  = P_WB[k][13:0];

            for (i = 0; i < P_RQN[k]; i = i + 1) wrq(i[9:0], rqrom[k * 32 + i]);

            @(negedge clk); cap_clr = 0; feed_en = 1;
            @(negedge clk); op_t0 = cyc; start = 1;
            @(negedge clk); start = 0;
            @(negedge clk);
            while (!done) @(negedge clk);
            op_cyc = cyc - op_t0;
            repeat (8) @(negedge clk);
            feed_en = 0;

            // ---- stream bookkeeping -------------------------------------
            if (xi !== x_tot) begin
                $display("FAIL op%0d: engine took %0d input beats, the vectors hold %0d (%0d passes of %0d)",
                         61 + k, xi, x_tot, P_PASS[k], P_INB[k]);
                errors = errors + 1;
            end
            if (wi !== w_tot) begin
                $display("FAIL op%0d: engine took %0d weight beats, expected %0d",
                         61 + k, wi, w_tot);
                errors = errors + 1;
            end
            if ((optr !== P_OUTB[k]) || (ovf != 0)) begin
                $display("FAIL op%0d: %0d output beats captured (+%0d past the end), expected %0d",
                         61 + k, optr, ovf, P_OUTB[k]);
                errors = errors + 1;
            end

            // ---- element comparison -------------------------------------
            e_cnt = 0; e_bad = 0; e_first = -1; dmax = 0; xbeats = 0;
            e_real = 0; e_realbad = 0;
            for (i = 0; i < P_OUTB[k]; i = i + 1) begin
                cw = cap[i]; ow = orom[i];
                if (^cw === 1'bx) xbeats = xbeats + 1;
                if (P_T4[k]) begin
                    for (j = 0; j < 4; j = j + 1) begin
                        idx    = i * 4 + j;
                        got_v  = $signed(cw[32*j +: 32]);
                        want_v = $signed(ow[32*j +: 32]);
                        e_cnt  = e_cnt + 1;
                        // op64 runs with OC padded 14 -> 16; lanes 14/15 are
                        // compared against the golden too.
                        if ((idx % 16) < 14) e_real = e_real + 1;
                        if (cw[32*j +: 32] !== ow[32*j +: 32]) begin
                            e_bad = e_bad + 1;
                            if ((idx % 16) < 14) e_realbad = e_realbad + 1;
                            if (e_first < 0) e_first = idx;
                            dv = got_v - want_v; if (dv < 0) dv = -dv;
                            if (dv > dmax) dmax = dv;
                        end
                    end
                end else begin
                    for (j = 0; j < 16; j = j + 1) begin
                        idx    = i * 16 + j;
                        got_v  = $signed(cw[8*j +: 8]);
                        want_v = $signed(ow[8*j +: 8]);
                        e_cnt  = e_cnt + 1; e_real = e_real + 1;
                        if (cw[8*j +: 8] !== ow[8*j +: 8]) begin
                            e_bad = e_bad + 1; e_realbad = e_realbad + 1;
                            if (e_first < 0) e_first = idx;
                            dv = got_v - want_v; if (dv < 0) dv = -dv;
                            if (dv > dmax) dmax = dv;
                        end
                    end
                end
            end
            tot_cnt = tot_cnt + e_cnt; tot_bad = tot_bad + e_bad;
            if (e_bad != 0) errors = errors + 1;

            $display("op%0d  %s  %0dx%0d IC=%0d -> %0dx%0d OC=%0d   %0d cycles",
                     61 + k,
                     P_T4[k] ? "type4" : (P_MA[k] ? "modeA" : "modeB"),
                     P_H[k], P_W[k], P_IC[k], P_OH[k], P_OW[k], P_OC[k], op_cyc);
            $display("      elements %0d   wrong %0d   max|diff| %0d   X beats %0d",
                     e_cnt, e_bad, dmax, xbeats);
            if (P_T4[k])
                $display("      of which real channels (oc < 14): %0d compared, %0d wrong",
                         e_real, e_realbad);
            if (e_first >= 0) begin
                f_oc = P_T4[k] ? (e_first % 16) : (e_first % P_OC[k]);
                f_ox = P_T4[k] ? ((e_first / 16) % P_OW[k])
                               : ((e_first / P_OC[k]) % P_OW[k]);
                f_oy = P_T4[k] ? (e_first / (16 * P_OW[k]))
                               : (e_first / (P_OC[k] * P_OW[k]));
                i = e_first / (P_T4[k] ? 4 : 16);
                j = e_first % (P_T4[k] ? 4 : 16);
                got_v  = P_T4[k] ? $signed(cap [i][32*j +: 32]) : $signed(cap [i][8*j +: 8]);
                want_v = P_T4[k] ? $signed(orom[i][32*j +: 32]) : $signed(orom[i][8*j +: 8]);
                $display("      FIRST BAD element %0d  (oy=%0d ox=%0d oc=%0d)  got %0d  want %0d",
                         e_first, f_oy, f_ox, f_oc, got_v, want_v);
                $display("      beat %0d  got=%032x", i, cap[i]);
                $display("               want=%032x", orom[i]);
            end

            // step the oracle's walk in lockstep with the operator just finished
            @(negedge clk); hs_e_done = 1'b1; @(negedge clk); hs_e_done = 1'b0;
            @(negedge clk); hs_out_done = 1'b1; @(negedge clk); hs_out_done = 1'b0;
            repeat (4) @(negedge clk);
            cap_clr = 1; @(negedge clk); cap_clr = 0;
        end

`ifndef HD_FRAME_NOSEQ
        $display("--- twn_hd_seq oracle ---");
        $display("      derived-descriptor mismatches: %0d", seq_err);
        errors = errors + seq_err;
        // Reported, not asserted; see the header.
        $display("      m_in_start pulses per operator: op61=%0d (mode A needs %0d passes)  op62=%0d  op63=%0d  op64=%0d",
                 seq_in_pulses[0], P_PASS[0], seq_in_pulses[1],
                 seq_in_pulses[2], seq_in_pulses[3]);
`endif

        $display("--- totals: %0d elements compared, %0d wrong ---", tot_cnt, tot_bad);
        if (errors == 0) $display("tb_hd_frame: PASS");
        else             $display("tb_hd_frame: %0d FAILURES", errors);
        $finish;
    end

    // Backstop only. The stall detector above should always fire first and say
    // why; if this one ever fires, something is making progress without making
    // sense.
    initial begin
        #900_000_000;
        $display("FAIL tb_hd_frame: GLOBAL TIMEOUT on op%0d at cycle %0d", 61 + cur_k, cyc);
        $display("tb_hd_frame: 1 FAILURES");
        $finish;
    end

endmodule
`default_nettype wire
