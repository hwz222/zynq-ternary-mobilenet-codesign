`timescale 1ns/1ps
// ============================================================================
//  tb_csr_hd.v -- unit test of the head's register interface: twn_csr and
//  twn_hd_seq wired together. Stimulus goes in only through AXI4-Lite
//  transactions. The head's movers and engine are modelled as two counters.
//  No golden files: all expected values are constants in this file.
//
//  Checks:
//   1. commit       12 field words + HD_COMMIT give exactly one hd_d_we pulse
//                   carrying every field.
//   2. independence operator k's walk presents operator k's bases, beats, shape
//                   and limits (the four expectations are first checked distinct).
//   3. readback     staging registers, HD_COMMIT sticky mask, HD_RQ_STAT.
//   4. done/busy    software polls HD_CTRL bit 2 (done) over AXI; the poll must
//                   not end before twn_hd_seq has raised done.
//   5. clearing     a start clears a stale done, writing bit 2 clears it,
//                   writing bit 1 (busy, read only) does not.
//   6. write ports  the BLOCK descriptor window (0x1000..) and the requant window
//                   (0x0400..) strobe different ports.
//   7. requant      the 256 words written through AXI arrive at the engine port
//                   for the right operator before that operator starts.
//
//  The mover model is its own process, not part of the poll loop, so an
//  early-ending poll cannot make the walk finish.
//
//  Run: sim/run_csr_hd.ps1 (intact arm plus the CSR_HD_BREAK_ASYM,
//  CSR_HD_BREAK_STREAM and CSR_HD_BREAK_RQWIN arms; those defines are in
//  twn_csr.v, not here).
`default_nettype none

module tb_csr_hd;
    // Addresses are repeated here, not shared with the RTL, so a renumbered
    // twn_csr.v map fails this test instead of being followed silently.
    localparam [15:0] A_HD_CTRL     = 16'h0100,
                      A_HD_COMMIT   = 16'h0104,
                      A_HD_RQ_STAT  = 16'h0108,
                      A_HD_IN_LO    = 16'h0110, A_HD_IN_HI  = 16'h0114,
                      A_HD_W_LO     = 16'h0118, A_HD_W_HI   = 16'h011c,
                      A_HD_OUT_LO   = 16'h0120, A_HD_OUT_HI = 16'h0124,
                      A_HD_IN_BEATS = 16'h0128,
                      A_HD_W_BEATS  = 16'h012c,
                      A_HD_OUT_BEATS= 16'h0130,
                      A_HD_SHAPE    = 16'h0134,
                      A_HD_FLAGS    = 16'h0138,
                      A_HD_CLAMP    = 16'h013c,
    // Head requantisation window and the block descriptor window it must not
    // touch (0x0400 vs 0x1000; 0x1400 would fall inside the block window).
                      A_HD_RQ_BASE  = 16'h0400,
                      A_DESC_BASE   = 16'h1000;

    // Bit numbers of HD_CTRL.
    localparam [31:0] HD_START   = 32'h1,   // write: start   read: start pending
                      HD_BUSY    = 32'h2,   // read only
                      HD_DONE    = 32'h4;   // write: clear   read: done is set

    reg clk = 1'b0, rst = 1'b1;
    always #2 clk = ~clk;

    // ---- AXI4-Lite ----
    reg  [15:0] awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg wvalid;   wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [15:0] araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;
    reg  [31:0] rcap;

    // ---- CSR -> head ----
    wire        hd_start, hd_d_we;
    wire [1:0]  hd_d_wa;
    wire [39:0] hd_d_in_base, hd_d_w_base, hd_d_out_base;
    wire [23:0] hd_d_in_beats, hd_d_w_beats, hd_d_out_beats;
    wire [8:0]  hd_d_ic;   wire [5:0] hd_d_oc;
    wire [6:0]  hd_d_h,    hd_d_w;
    wire        hd_d_type4, hd_d_slice, hd_d_relu;
    wire [15:0] hd_d_lo,   hd_d_hi;

    // ---- head -> CSR ----
    wire        hd_busy, hd_seq_done;
    wire [1:0]  cur_op;

    // d_wr_en is observed: it is the block table's write strobe, which the
    // head's requant writes must not pulse.
    wire        d_wr_en_o;
    wire [12:0] d_wr_addr_o;
    wire [31:0] d_wr_data_o;
    wire        hd_rq_we;
    wire [7:0]  hd_rq_wa;
    wire [31:0] hd_rq_wd;

    twn_csr CSR (
        .clk(clk), .rstn(~rst),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(4'hF), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        // Frame-side inputs are tied rather than left unconnected (X would
        // reach read registers).
        .ap_start(), .core_busy(1'b0), .core_done(1'b0),
        .act_base(), .w_base(), .in_ptr(), .out_ptr(), .n_blocks(),
        .d_wr_en(d_wr_en_o), .d_wr_addr(d_wr_addr_o), .d_wr_data(d_wr_data_o),
        .d_check(), .d_valid(1'b1), .d_check_done(1'b0),
        .d_err_code(4'd0), .d_err_block(5'd0),
        .cur_block(5'd0), .ring_overrun(1'b0),
        .cyc_total(32'd0), .cyc_array(32'd0), .cyc_dw(32'd0),
        .cyc_stall_mem(32'd0), .cyc_idle_pre(32'd0), .cyc_idle_post(32'd0),
        .pix_nz(12'd0), .arr_cap(128'd0),
        // ---- the head ----
        .hd_start(hd_start), .hd_busy(hd_busy), .hd_done(hd_seq_done),
        .hd_d_we(hd_d_we), .hd_d_wa(hd_d_wa),
        .hd_d_in_base(hd_d_in_base), .hd_d_w_base(hd_d_w_base),
        .hd_d_out_base(hd_d_out_base),
        .hd_d_in_beats(hd_d_in_beats), .hd_d_w_beats(hd_d_w_beats),
        .hd_d_out_beats(hd_d_out_beats),
        .hd_d_ic(hd_d_ic), .hd_d_oc(hd_d_oc), .hd_d_h(hd_d_h), .hd_d_w(hd_d_w),
        .hd_d_type4(hd_d_type4), .hd_d_slice(hd_d_slice), .hd_d_relu(hd_d_relu),
        .hd_d_lo(hd_d_lo), .hd_d_hi(hd_d_hi),
        .hd_rq_we(hd_rq_we), .hd_rq_wa(hd_rq_wa), .hd_rq_wd(hd_rq_wd));

    wire [39:0] m_in_base, m_w_base, m_out_base;
    wire [23:0] m_in_beats, m_w_beats, m_out_beats;
    wire        m_in_start, m_w_start, m_out_start;
    reg         m_out_done = 1'b0;
    wire        e_start;
    reg         e_done = 1'b0;
    wire [8:0]  e_ic;  wire [5:0] e_oc;  wire [6:0] e_h, e_w;
    wire        e_mode_a, e_type4, e_relu;
    wire signed [15:0] e_lo, e_hi;
    wire        e_m0_we, e_bias_we, e_sh_we;
    wire [9:0]  e_rq_wa;
    wire signed [31:0] e_m0_wd;
    wire signed [63:0] e_bias_wd;
    wire [5:0]  e_sh_wd;

    // slot_off is zero: the offset on op61's input base is not under test, so
    // the walk presents exactly what was written through AXI.
    twn_hd_seq #(.NOPS(4)) HSEQ (
        .clk(clk), .rst(rst), .start(hd_start),
        .busy(hd_busy), .done(hd_seq_done), .cur_op(cur_op),
        .d_we(hd_d_we), .d_wa(hd_d_wa),
        .d_in_base(hd_d_in_base), .d_w_base(hd_d_w_base),
        .d_out_base(hd_d_out_base),
        .d_in_beats(hd_d_in_beats), .d_w_beats(hd_d_w_beats),
        .d_out_beats(hd_d_out_beats),
        .d_ic(hd_d_ic), .d_oc(hd_d_oc), .d_h(hd_d_h), .d_w(hd_d_w),
        .d_type4(hd_d_type4), .d_slice(hd_d_slice), .d_relu(hd_d_relu),
        .d_lo(hd_d_lo), .d_hi(hd_d_hi),
        // Straight from the CSR's requant window.
        .rq_we(hd_rq_we), .rq_wa(hd_rq_wa), .rq_wd(hd_rq_wd),
        .slot_off(40'd0),
        .m_in_base(m_in_base), .m_in_beats(m_in_beats),
        .m_w_base(m_w_base), .m_w_beats(m_w_beats),
        .m_out_base(m_out_base), .m_out_beats(m_out_beats),
        .m_in_start(m_in_start), .m_w_start(m_w_start), .m_out_start(m_out_start),
        .m_out_done(m_out_done),
        .e_start(e_start), .e_done(e_done),
        .e_ic(e_ic), .e_oc(e_oc), .e_h(e_h), .e_w(e_w),
        .e_mode_a(e_mode_a), .e_type4(e_type4), .e_relu(e_relu),
        .e_lo(e_lo), .e_hi(e_hi),
        .e_m0_we(e_m0_we), .e_rq_wa(e_rq_wa), .e_m0_wd(e_m0_wd),
        .e_bias_we(e_bias_we), .e_bias_wd(e_bias_wd),
        .e_sh_we(e_sh_we), .e_sh_wd(e_sh_wd));

    // Model of the engine and the write mover. The writer finishes after the
    // engine so twn_hd_seq's drain state has something to wait for.
    reg [7:0] e_ctr, o_ctr;
    reg       e_pend, o_pend;
    always @(posedge clk) begin
        if (rst) begin
            e_pend <= 1'b0; o_pend <= 1'b0; e_ctr <= 8'd0; o_ctr <= 8'd0;
            e_done <= 1'b0; m_out_done <= 1'b0;
        end else begin
            e_done <= 1'b0; m_out_done <= 1'b0;
            if (e_start) begin e_pend <= 1'b1; e_ctr <= 8'd6; end
            else if (e_pend) begin
                if (e_ctr != 8'd0) e_ctr <= e_ctr - 8'd1;
                else begin e_pend <= 1'b0; e_done <= 1'b1; end
            end
            if (m_out_start) begin o_pend <= 1'b1; o_ctr <= 8'd12; end
            else if (o_pend) begin
                if (o_ctr != 8'd0) o_ctr <= o_ctr - 8'd1;
                else begin o_pend <= 1'b0; m_out_done <= 1'b1; end
            end
        end
    end

    // ---- the four expected descriptors ----
    reg [39:0] E_IN  [0:3];  reg [39:0] E_WB  [0:3];  reg [39:0] E_OB [0:3];
    reg [23:0] E_IBT [0:3];  reg [23:0] E_WBT [0:3];  reg [23:0] E_OBT[0:3];
    reg [8:0]  E_IC  [0:3];  reg [5:0]  E_OC  [0:3];
    reg [6:0]  E_H   [0:3];  reg [6:0]  E_W   [0:3];
    reg        E_T4  [0:3];  reg        E_SL  [0:3];  reg        E_RL [0:3];
    reg [15:0] E_LO  [0:3];  reg [15:0] E_HI  [0:3];

    integer errors = 0, checks = 0;
    task chk;
        input cond;
        input [1023:0] what;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s (t=%0t)", what, $time);
            end
        end
    endtask

    // ---- AXI4-Lite driver. Same shape as tb_desctab.v's. ----
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

    task rd;
        input [15:0] a;
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

    task chk_rd;
        input [15:0] a; input [31:0] want; input [1023:0] what;
        begin
            rd(a);
            checks = checks + 1;
            if (rcap !== want) begin
                errors = errors + 1;
                $display("FAIL: %0s -- read 0x%04x = %08x, want %08x (t=%0t)",
                         what, a, rcap, want, $time);
            end
        end
    endtask

    // twelve field words then the commit; every operator writes all twelve
    task wr_desc;
        input integer k;
        begin
            wr(A_HD_IN_LO,      E_IN[k][31:0]);
            wr(A_HD_IN_HI,      {24'd0, E_IN[k][39:32]});
            wr(A_HD_W_LO,       E_WB[k][31:0]);
            wr(A_HD_W_HI,       {24'd0, E_WB[k][39:32]});
            wr(A_HD_OUT_LO,     E_OB[k][31:0]);
            wr(A_HD_OUT_HI,     {24'd0, E_OB[k][39:32]});
            wr(A_HD_IN_BEATS,   {8'd0, E_IBT[k]});
            wr(A_HD_W_BEATS,    {8'd0, E_WBT[k]});
            wr(A_HD_OUT_BEATS,  {8'd0, E_OBT[k]});
            wr(A_HD_SHAPE,      {3'd0, E_W[k], E_H[k], E_OC[k], E_IC[k]});
            wr(A_HD_FLAGS,      {29'd0, E_RL[k], E_SL[k], E_T4[k]});
            wr(A_HD_CLAMP,      {E_HI[k], E_LO[k]});
            wr(A_HD_COMMIT,     {30'd0, k[1:0]});
        end
    endtask

    // One requantisation entry as two words, low then high, at
    // {operator, oc, half}. High word: {sh[5:0], m0[17:0], bias[39:32]}.
    task wr_rq;
        input integer p; input integer c;
        reg signed [17:0] m0; reg signed [39:0] bs; reg [5:0] sh;
        begin
            m0 = want_m0(p, c); bs = want_bias(p, c); sh = want_sh(p, c);
            wr(A_HD_RQ_BASE + (p * 64 + c * 2 + 0) * 4, bs[31:0]);
            wr(A_HD_RQ_BASE + (p * 64 + c * 2 + 1) * 4, {sh, m0, bs[39:32]});
        end
    endtask

    // ---- check 1: count the commit pulses and check the fields ON the pulse ----
    integer n_we = 0;
    integer we_op [0:3];
    always @(posedge clk) if (!rst && hd_d_we) begin
        n_we = n_we + 1;
        we_op[hd_d_wa] = we_op[hd_d_wa] + 1;
        chk(hd_d_in_base   === E_IN [hd_d_wa], "commit carries this operator's in_base");
        chk(hd_d_w_base    === E_WB [hd_d_wa], "commit carries this operator's w_base");
        chk(hd_d_out_base  === E_OB [hd_d_wa], "commit carries this operator's out_base");
        chk(hd_d_in_beats  === E_IBT[hd_d_wa], "commit carries this operator's in_beats");
        chk(hd_d_w_beats   === E_WBT[hd_d_wa], "commit carries this operator's w_beats");
        chk(hd_d_out_beats === E_OBT[hd_d_wa], "commit carries this operator's out_beats");
        chk(hd_d_ic        === E_IC [hd_d_wa], "commit carries this operator's ic");
        chk(hd_d_oc        === E_OC [hd_d_wa], "commit carries this operator's oc");
        chk(hd_d_h         === E_H  [hd_d_wa], "commit carries this operator's h");
        chk(hd_d_w         === E_W  [hd_d_wa], "commit carries this operator's w");
        chk(hd_d_type4     === E_T4 [hd_d_wa], "commit carries this operator's type4");
        chk(hd_d_slice     === E_SL [hd_d_wa], "commit carries this operator's slice");
        chk(hd_d_relu      === E_RL [hd_d_wa], "commit carries this operator's relu");
        chk(hd_d_lo        === E_LO [hd_d_wa], "commit carries this operator's lo");
        chk(hd_d_hi        === E_HI [hd_d_wa], "commit carries this operator's hi");
    end

    // ---- check 6: the head's requant port and the block table's port ----
    // Counted over the whole run: n_rq_we pulses of hd_rq_we, n_dwr pulses of
    // d_wr_en. Each window's writes must show up only on its own strobe.
    integer n_rq_we = 0, n_dwr = 0;
    always @(posedge clk) if (!rst) begin
        if (hd_rq_we) n_rq_we = n_rq_we + 1;
        if (d_wr_en_o) n_dwr  = n_dwr + 1;
    end

    // ---- check 7: requant entries replayed at the engine's port, for the right
    // operator, counted per e_start batch (same model as tb_hd_seq.v). ----
    function signed [17:0] want_m0(input integer p, input integer c);
        want_m0 = (c % 2) ? ( 18'sd130000 - (p * 32 + c) * 11)
                          : (-18'sd130000 + (p * 32 + c) * 11);
    endfunction
    function signed [39:0] want_bias(input integer p, input integer c);
        reg signed [39:0] mag;
        begin
            mag = (p * 811 + c * 29 + 1) * 40'sd1000033;
            want_bias = (c % 2) ? -mag : mag;
        end
    endfunction
    function [5:0] want_sh(input integer p, input integer c);
        want_sh = (p * 17 + c + 3) % 64;
    endfunction

    integer rq_batch = 0;
    integer rq_n [0:3];
    integer rq_bad [0:3];
    integer rq_partial = 0;
    // Counted rather than chk'd inline (256 events per frame).
    always @(posedge clk) if (!rst) begin
        if (e_m0_we) begin
            if (!(e_bias_we && e_sh_we)) rq_partial = rq_partial + 1;
            // Two frames run here, so score modulo four.
            rq_n  [rq_batch % 4] = rq_n[rq_batch % 4] + 1;
            if (e_m0_wd   !== $signed(want_m0  (rq_batch % 4, e_rq_wa[4:0])) ||
                e_bias_wd !== $signed(want_bias(rq_batch % 4, e_rq_wa[4:0])) ||
                e_sh_wd   !==         want_sh  (rq_batch % 4, e_rq_wa[4:0]))
                rq_bad[rq_batch % 4] = rq_bad[rq_batch % 4] + 1;
        end
        if (e_start) rq_batch = rq_batch + 1;
    end

    // ---- check 2: watch the walk. Operator k must present operator k. ----
    integer n_estart = 0, seq_done_n = 0;
    integer ran_op [0:3];
    always @(posedge clk) if (!rst) begin
        if (hd_seq_done) seq_done_n = seq_done_n + 1;
        if (e_start) begin
            n_estart = n_estart + 1;
            ran_op[cur_op] = ran_op[cur_op] + 1;
            chk(m_in_base   === E_IN [cur_op], "walk: in_base is this operator's");
            chk(m_w_base    === E_WB [cur_op], "walk: w_base is this operator's");
            chk(m_out_base  === E_OB [cur_op], "walk: out_base is this operator's");
            chk(m_in_beats  === E_IBT[cur_op], "walk: in_beats is this operator's");
            chk(m_w_beats   === E_WBT[cur_op], "walk: w_beats is this operator's");
            chk(m_out_beats === E_OBT[cur_op], "walk: out_beats is this operator's");
            chk(e_ic        === E_IC [cur_op], "walk: ic is this operator's");
            chk(e_oc        === E_OC [cur_op], "walk: oc is this operator's");
            chk(e_h         === E_H  [cur_op], "walk: h is this operator's");
            chk(e_w         === E_W  [cur_op], "walk: w is this operator's");
            chk(e_type4     === E_T4 [cur_op], "walk: type4 is this operator's");
            chk(e_relu      === E_RL [cur_op], "walk: relu is this operator's");
            chk(e_lo        === E_LO [cur_op], "walk: lo is this operator's");
            chk(e_hi        === E_HI [cur_op], "walk: hi is this operator's");
            chk(e_mode_a    === (~E_T4[cur_op] & E_SL[cur_op]),
                "walk: mode_a is derived from this operator's type4 and slice");
        end
    end

    integer i, j;
    integer spins;
    reg     poll_done, saw_busy, poll_early;

    // Poll HD_CTRL for the done bit, as software does, and record whether busy
    // was seen on the way. Bounded, so a missing done is a named failure.
    task poll_head_done;
        begin
            poll_done = 1'b0; saw_busy = 1'b0; spins = 0;
            while (!poll_done && spins < 4000) begin
                rd(A_HD_CTRL);
                if (rcap & HD_BUSY) saw_busy = 1'b1;
                if (rcap & HD_DONE) poll_done = 1'b1;
                spins = spins + 1;
            end
        end
    endtask

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; wdata = 0; araddr = 0; rcap = 0;
        poll_early = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            we_op[i] = 0; ran_op[i] = 0; rq_n[i] = 0; rq_bad[i] = 0;
        end

        // Shapes follow the four head operators. op61 is the only mode-A one;
        // 8x8x32 is the largest mode-A output twn_hd_seq accepts (8192 bytes).
        E_IN [0]=40'h12_3456_7000; E_WB [0]=40'h20_0000_1000; E_OB [0]=40'h30_0000_2000;
        E_IBT[0]=24'h000640;       E_WBT[0]=24'h001234;       E_OBT[0]=24'h000200;
        E_IC [0]=9'd320; E_OC[0]=6'd32; E_H[0]=7'd8;  E_W[0]=7'd8;
        E_T4 [0]=1'b0;   E_SL[0]=1'b1;  E_RL[0]=1'b1;
        E_LO [0]=16'hFF80; E_HI[0]=16'h007F;

        E_IN [1]=40'h44_1111_1100; E_WB [1]=40'h55_2222_2200; E_OB [1]=40'h66_3333_3300;
        E_IBT[1]=24'h000201;       E_WBT[1]=24'h000041;       E_OBT[1]=24'h000801;
        E_IC [1]=9'd32;  E_OC[1]=6'd32; E_H[1]=7'd16; E_W[1]=7'd16;
        E_T4 [1]=1'b0;   E_SL[1]=1'b0;  E_RL[1]=1'b1;
        E_LO [1]=16'hFF9C; E_HI[1]=16'h0064;

        E_IN [2]=40'h77_AAAA_AA00; E_WB [2]=40'h88_BBBB_BB00; E_OB [2]=40'h99_CCCC_CC00;
        E_IBT[2]=24'h000802;       E_WBT[2]=24'h000042;       E_OBT[2]=24'h002002;
        E_IC [2]=9'd32;  E_OC[2]=6'd32; E_H[2]=7'd32; E_W[2]=7'd32;
        E_T4 [2]=1'b0;   E_SL[2]=1'b0;  E_RL[2]=1'b1;
        E_LO [2]=16'hFFC0; E_HI[2]=16'h003F;

        // op64 declares OC=16 (14 padded): twn_hd_compute emits OC/4 beats per
        // pixel and twn_hd_seq refuses a type-4 operator with OC not a multiple
        // of 4.
        E_IN [3]=40'hAB_DEAD_BE00; E_WB [3]=40'hCD_F00D_4400; E_OB [3]=40'hEF_5A5A_5A00;
        E_IBT[3]=24'h002003;       E_WBT[3]=24'h000073;       E_OBT[3]=24'h00E003;
        E_IC [3]=9'd32;  E_OC[3]=6'd16; E_H[3]=7'd64; E_W[3]=7'd64;
        E_T4 [3]=1'b1;   E_SL[3]=1'b0;  E_RL[3]=1'b0;
        E_LO [3]=16'h8000; E_HI[3]=16'h7FFF;

        // Guard against vacuity: four identical descriptors would pass every
        // per-operator check, so the expectations must differ pairwise. ic and
        // oc repeat across operators, so the shape is compared as one word.
        for (i = 0; i < 4; i = i + 1)
            for (j = i + 1; j < 4; j = j + 1) begin
                chk(E_IN [i] !== E_IN [j], "expected in_base values must differ");
                chk(E_WB [i] !== E_WB [j], "expected w_base values must differ");
                chk(E_OB [i] !== E_OB [j], "expected out_base values must differ");
                chk(E_IBT[i] !== E_IBT[j], "expected in_beats must differ");
                chk(E_WBT[i] !== E_WBT[j], "expected w_beats must differ");
                chk(E_OBT[i] !== E_OBT[j], "expected out_beats must differ");
                chk(E_LO [i] !== E_LO [j], "expected lo limits must differ");
                chk(E_HI [i] !== E_HI [j], "expected hi limits must differ");
                chk({E_W[i], E_H[i], E_OC[i], E_IC[i]} !==
                    {E_W[j], E_H[j], E_OC[j], E_IC[j]},
                    "expected shapes must differ");
            end

        repeat (8) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // Nothing may have been committed before a commit is written.
        chk_rd(A_HD_COMMIT, 32'h0000_0000, "no operator is committed after reset");
        chk(n_we == 0, "no hd_d_we before any commit is written");

        chk_rd(A_HD_RQ_STAT, 32'h0000_0000, "no requant word is recorded after reset");

        // ---- 1 + 2: the four descriptors ----
        for (i = 0; i < 4; i = i + 1) wr_desc(i);
        @(posedge clk);

        chk(n_we == 4, "exactly four hd_d_we pulses for four commits");
        for (i = 0; i < 4; i = i + 1)
            chk(we_op[i] == 1, "each operator must be committed exactly once");

        // ---- 6: the two write ports ----
        // Sixteen words into the block descriptor window first; they must pulse
        // d_wr_en and nothing on the requant port.
        for (i = 0; i < 16; i = i + 1) wr(A_DESC_BASE + i * 4, 32'hA5A50000 + i);
        @(posedge clk); @(posedge clk);
        chk(n_dwr   == 16, "sixteen block descriptor writes must pulse d_wr_en sixteen times");
        chk(n_rq_we == 0,
            "a BLOCK descriptor write must not touch the head's requantisation table");
        chk_rd(A_HD_RQ_STAT, 32'h0000_0000,
               "a BLOCK descriptor write must not be counted as a requant word");

        // Now the four requantisation tables: 4 x 32 x two words = 256 writes.
        for (i = 0; i < 4; i = i + 1)
            for (j = 0; j < 32; j = j + 1) wr_rq(i, j);
        @(posedge clk); @(posedge clk);
        chk(n_rq_we == 256, "256 requant window writes must pulse hd_rq_we 256 times");
        chk(n_dwr   == 16,
            "a requant write must not touch the BLOCK descriptor table's port");
        chk(n_we    == 4,
            "a requant write must not commit a head descriptor");
        // words = 256, per-operator sticky = 0xF  ->  (256 << 4) | 0xF
        chk_rd(A_HD_RQ_STAT, 32'h0000_100F,
               "HD_RQ_STAT: 256 words written, all four operators touched");

        // ---- 3: readback ----
        // The staging set holds the LAST descriptor written, which is op64's.
        chk_rd(A_HD_IN_LO,     E_IN [3][31:0],          "HD_IN_LO reads back");
        chk_rd(A_HD_IN_HI,     {24'd0, E_IN[3][39:32]}, "HD_IN_HI reads back");
        chk_rd(A_HD_W_LO,      E_WB [3][31:0],          "HD_W_LO reads back");
        chk_rd(A_HD_W_HI,      {24'd0, E_WB[3][39:32]}, "HD_W_HI reads back");
        chk_rd(A_HD_OUT_LO,    E_OB [3][31:0],          "HD_OUT_LO reads back");
        chk_rd(A_HD_OUT_HI,    {24'd0, E_OB[3][39:32]}, "HD_OUT_HI reads back");
        chk_rd(A_HD_IN_BEATS,  {8'd0, E_IBT[3]},        "HD_IN_BEATS reads back");
        chk_rd(A_HD_W_BEATS,   {8'd0, E_WBT[3]},        "HD_W_BEATS reads back");
        chk_rd(A_HD_OUT_BEATS, {8'd0, E_OBT[3]},        "HD_OUT_BEATS reads back");
        chk_rd(A_HD_SHAPE, {3'd0, E_W[3], E_H[3], E_OC[3], E_IC[3]},
               "HD_SHAPE reads back packed as documented");
        chk_rd(A_HD_FLAGS, {29'd0, E_RL[3], E_SL[3], E_T4[3]},
               "HD_FLAGS reads back as {relu,slice,type4}");
        chk_rd(A_HD_CLAMP, {E_HI[3], E_LO[3]}, "HD_CLAMP reads back {hi,lo}");
        // [7:4] is the sticky per-operator commit mask, [1:0] the last index.
        chk_rd(A_HD_COMMIT, 32'h0000_00F3,
               "HD_COMMIT: all four operators committed, last was 3");

        // ---- 4 + 5: control ----
        chk_rd(A_HD_CTRL, 32'h0000_0000, "HD_CTRL is idle before the first start");

        wr(A_HD_CTRL, HD_START);
        chk(hd_start === 1'b1, "hd_start must be asserted by the CTRL write");

        poll_head_done();

        // Directed done/busy test: the poll above waited on bit 2. If bit 2
        // carried busy (CSR_HD_BREAK_ASYM), the loop would leave when the walk
        // starts, before seq_done_n is non-zero.
        if (poll_done && seq_done_n == 0) poll_early = 1'b1;
        chk(!poll_early,
            "HD_CTRL[2] read back set BEFORE the head finished -- bit 2 carries busy, not done");
        chk(poll_done, "HD_CTRL[2] never read back set -- done is invisible to software");
        chk(saw_busy,
            "HD_CTRL[1] never read back set during the walk -- busy is not on bit 1");
        chk(seq_done_n == 1, "the head must have completed exactly one walk");
        chk(hd_busy === 1'b0, "busy must be low once done reads back set");

        // A stale done must not satisfy the next frame's poll: the start write
        // clears it.
        wr(A_HD_CTRL, HD_START);
        rd(A_HD_CTRL);
        chk((rcap & HD_DONE) == 0,
            "a start must clear the previous frame's done, or frame k+1's poll ends immediately");
        // Bit 0 reads "a start is pending"; the sequencer has long since taken
        // it, so it must read clear.
        chk((rcap & HD_START) == 0,
            "bit 0 must read clear once the sequencer has taken the start");

        poll_head_done();
        chk(poll_done && seq_done_n == 2, "the second start must run a second walk");

        // On this register bit 1 is read-only busy, so writing it must not
        // clear done.
        wr(A_HD_CTRL, HD_BUSY);
        rd(A_HD_CTRL);
        chk((rcap & HD_DONE) != 0,
            "writing bit 1 must NOT clear done -- bit 1 is read-only busy on this register");

        wr(A_HD_CTRL, HD_DONE);
        chk_rd(A_HD_CTRL, 32'h0000_0000, "writing bit 2 clears done");

        // Two frames, four operators each. This also shows hd_start does not
        // retrigger.
        chk(n_estart == 8, "two frames must issue eight operators in total");
        for (i = 0; i < 4; i = i + 1)
            chk(ran_op[i] == 2, "each operator must run once per frame");
        chk(n_we == 4, "no further hd_d_we pulses after the four commits");

        // ---- 7: the requantisation replay, end to end ----
        // Two frames, so 64 entries per operator.
        $display("tb_csr_hd: requant entries replayed per operator = %0d %0d %0d %0d (want 64 64 64 64)",
                 rq_n[0], rq_n[1], rq_n[2], rq_n[3]);
        $display("tb_csr_hd: requant entries WRONG per operator     = %0d %0d %0d %0d (want 0 0 0 0)",
                 rq_bad[0], rq_bad[1], rq_bad[2], rq_bad[3]);
        for (i = 0; i < 4; i = i + 1) begin
            chk(rq_n[i] == 64,
                "each operator must get 32 requant entries per frame, twice over two frames");
            chk(rq_bad[i] == 0,
                "the entries an operator gets must be the ones written to ITS window slot");
        end
        chk(rq_partial == 0,
            "m0 reached the engine without its bias and shift -- an entry is one write");
        chk(n_rq_we == 256, "no further requant writes were generated by the two walks");

        if (errors == 0)
            $display("tb_csr_hd: PASS (%0d assertions: commit, independence, readback, asymmetry, clearing, requant window)",
                     checks);
        else
            $display("tb_csr_hd: %0d FAILURES of %0d assertions", errors, checks);
        $finish;
    end

    // Timeout: name the cause (same block as tb_hd_seq.v).
    initial begin
        #400000;
        $display("tb_csr_hd: TIMEOUT -- the sequence never completed");
        if (poll_early)
            $display("tb_csr_hd: CAUSE = the done poll ended before the head finished; HD_CTRL's read side does not put done on bit 2");
        else
            $display("tb_csr_hd: CAUSE = not the done/busy swap; %0d commits, %0d operators issued, %0d walks finished",
                     n_we, n_estart, seq_done_n);
        $display("tb_csr_hd: %0d FAILURES of %0d assertions", (errors == 0) ? 1 : errors, checks);
        $finish;
    end
endmodule
`default_nettype wire
