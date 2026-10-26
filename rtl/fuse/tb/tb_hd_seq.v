`timescale 1ns/1ps
// tb_hd_seq.v -- twn_hd_seq (head operator sequencer, NOPS = 4) unit test.
//
// Driven: four operator descriptors (op61 mode A, op62 / op63 mode B, op64 type 4),
//   four per-operator requant tables written through the store port, slot_off, start;
//   the testbench plays the engine and the memory masters (e_done, m_in_done, m_out_done).
// Checks:
//   1 ORDER     op0..op3 issued once each, in order; done pulses once.
//   2 DERIVE    e_mode_a = !type4 && slice; the presented fields are the current operator's.
//   3 RACE      with m_out_done held off for DRAIN_HOLD cycles after e_done, no
//               operator starts (sticky race_seen).
//   4 SLOT      op61's input base carries slot_off; the other three do not.
//   5 PASSES    op61 issues m_in_start 16 times (OC/2) and the others once, although
//               20 input acknowledgements are offered.
//   6 REQUANT   each operator's own 32 entries reach the engine before its e_start;
//               the batch index counts e_start pulses, so a late entry scores as the
//               next operator's.
// ifdef arms in twn_hd_seq.v exercised by this bench: HD_SEQ_BREAK_DRAIN (skips the
//   write drain), HD_SEQ_BREAK_PASS (drops the mode-A re-issue), HD_SEQ_BREAK_RQOP
//   (replays operator 0's table for all). The mode-A capacity and type-4 OC
//   assertions inside the module are not exercised here (they call $finish).
// No input files. Prints PASS or a FAILURES count; 200 us timeout.
`default_nettype none
module tb_hd_seq;
    reg clk = 1'b0, rst = 1'b1;
    always #2 clk = ~clk;

    reg         start = 1'b0;
    wire        busy, done;
    wire [1:0]  cur_op;
    reg         d_we = 1'b0;
    reg  [1:0]  d_wa = 2'd0;
    reg  [39:0] d_in_base = 40'd0, d_w_base = 40'd0, d_out_base = 40'd0;
    reg  [23:0] d_in_beats= 24'd0, d_w_beats= 24'd0, d_out_beats= 24'd0;
    reg  [8:0]  d_ic = 9'd0;   reg [5:0] d_oc = 6'd0;
    reg  [6:0]  d_h  = 7'd0;   reg [6:0] d_w  = 7'd0;
    reg         d_type4 = 1'b0, d_slice = 1'b0, d_relu = 1'b0;
    reg  [15:0] d_lo = 16'd0,  d_hi = 16'd0;
    reg  [39:0] slot_off = 40'd0;

    wire [39:0] m_in_base, m_w_base, m_out_base;
    wire [23:0] m_in_beats, m_w_beats, m_out_beats;
    wire        m_in_start, m_w_start, m_out_start;
    reg         m_in_done = 1'b0;
    reg         m_out_done = 1'b0;
    wire        e_start;
    reg         e_done = 1'b0;
    wire [8:0]  e_ic;  wire [5:0] e_oc;  wire [6:0] e_h, e_w;
    wire        e_mode_a, e_type4, e_relu;
    wire signed [15:0] e_lo, e_hi;

    // ---- the requantisation store's write port and its replay ----
    reg         rq_we = 1'b0;
    reg  [7:0]  rq_wa = 8'd0;
    reg  [31:0] rq_wd = 32'd0;
    wire        e_m0_we, e_bias_we, e_sh_we;
    wire [9:0]  e_rq_wa;
    wire signed [31:0] e_m0_wd;
    wire signed [63:0] e_bias_wd;
    wire [5:0]  e_sh_wd;

    twn_hd_seq #(.NOPS(4)) DUT (
        .clk(clk), .rst(rst), .start(start), .busy(busy), .done(done), .cur_op(cur_op),
        .d_we(d_we), .d_wa(d_wa), .d_in_base(d_in_base), .d_w_base(d_w_base),
        .d_out_base(d_out_base), .d_in_beats(d_in_beats), .d_w_beats(d_w_beats),
        .d_out_beats(d_out_beats), .d_ic(d_ic), .d_oc(d_oc), .d_h(d_h), .d_w(d_w),
        .d_type4(d_type4), .d_slice(d_slice), .d_relu(d_relu), .d_lo(d_lo), .d_hi(d_hi),
        .rq_we(rq_we), .rq_wa(rq_wa), .rq_wd(rq_wd),
        .slot_off(slot_off),
        .m_in_base(m_in_base), .m_in_beats(m_in_beats),
        .m_w_base(m_w_base), .m_w_beats(m_w_beats),
        .m_out_base(m_out_base), .m_out_beats(m_out_beats),
        .m_in_start(m_in_start), .m_w_start(m_w_start), .m_out_start(m_out_start),
        .m_in_done(m_in_done), .m_out_done(m_out_done),
        .e_start(e_start), .e_done(e_done),
        .e_ic(e_ic), .e_oc(e_oc), .e_h(e_h), .e_w(e_w),
        .e_mode_a(e_mode_a), .e_type4(e_type4), .e_relu(e_relu), .e_lo(e_lo), .e_hi(e_hi),
        .e_m0_we(e_m0_we), .e_rq_wa(e_rq_wa), .e_m0_wd(e_m0_wd),
        .e_bias_we(e_bias_we), .e_bias_wd(e_bias_wd),
        .e_sh_we(e_sh_we), .e_sh_wd(e_sh_wd));

    // ---- check 6 model: four different tables, one per operator ----
    // Values are functions of (operator, oc); m0 stays inside signed 18 bits and
    // bias inside signed 40 (twn_hd_compute's widths).
    function signed [17:0] want_m0(input integer p, input integer c);
        want_m0 = (c % 2) ? ( 18'sd131000 - (p * 32 + c) * 7)
                          : (-18'sd131000 + (p * 32 + c) * 7);
    endfunction
    function signed [39:0] want_bias(input integer p, input integer c);
        reg signed [39:0] mag;
        begin
            mag = (p * 977 + c * 31 + 1) * 40'sd1000003;
            want_bias = (c % 2) ? -mag : mag;
        end
    endfunction
    function [5:0] want_sh(input integer p, input integer c);
        want_sh = (p * 13 + c) % 64;
    endfunction

    task rq_wr(input integer p, input integer c);
        reg signed [17:0] m0; reg signed [39:0] bs; reg [5:0] sh;
        begin
            m0 = want_m0(p, c); bs = want_bias(p, c); sh = want_sh(p, c);
            @(posedge clk);
            rq_we <= 1'b1; rq_wa <= {p[1:0], c[4:0], 1'b0}; rq_wd <= bs[31:0];
            @(posedge clk);
            rq_we <= 1'b1; rq_wa <= {p[1:0], c[4:0], 1'b1};
            rq_wd <= {sh, m0, bs[39:32]};      // 6 + 18 + 8 = 32, no padding
            @(posedge clk);
            rq_we <= 1'b0;
        end
    endtask

    // The batch index comes from e_start, not from the DUT's op register, so a
    // table that lands after its operator started is scored against the next.
    integer rq_batch = 0;
    integer rq_n   [0:3];
    integer rq_bad [0:3];
    integer rq_late = 0;      // entries replayed after all four had started
    integer rq_partial = 0;   // m0 written without bias or shift
    always @(posedge clk) if (!rst) begin
        if (e_m0_we) begin
            if (!(e_bias_we && e_sh_we)) rq_partial = rq_partial + 1;
            if (rq_batch > 3) rq_late = rq_late + 1;
            else begin
                rq_n[rq_batch] = rq_n[rq_batch] + 1;
                if (e_m0_wd   !== $signed(want_m0  (rq_batch, e_rq_wa[4:0])) ||
                    e_bias_wd !== $signed(want_bias(rq_batch, e_rq_wa[4:0])) ||
                    e_sh_wd   !==         want_sh  (rq_batch, e_rq_wa[4:0]))
                    rq_bad[rq_batch] = rq_bad[rq_batch] + 1;
            end
        end
        if (e_start) rq_batch = rq_batch + 1;
    end

    integer errors = 0;
    // [1023:0]: a shorter message would silently lose its front.
    task chk(input cond, input [1023:0] what);
        begin if (!cond) begin errors = errors + 1;
            $display("FAIL: %0s (t=%0t)", what, $time); end end
    endtask

    // Check 3 holds m_out_done off past e_done and requires that no operator
    // starts. The hold must outlast the sequencer's own e_done-to-e_start latency
    // (S_RQ's 64 reads, two cycles of pipeline, S_ISSUE: about 68 cycles), else
    // the check cannot observe the race.
    localparam integer DRAIN_HOLD = 200;
    // synthesis translate_off
    initial if (DRAIN_HOLD <= 68)
        $display("FAIL tb_hd_seq: DRAIN_HOLD=%0d is not longer than the sequencer's own e_done-to-e_start latency; check 3 cannot observe the race", DRAIN_HOLD);
    // synthesis translate_on

    task wr(input [1:0] a, input [39:0] ib, input [8:0] ic, input [5:0] oc,
            input [6:0] h, input [6:0] w, input t4, input sl);
        begin
            @(posedge clk);
            d_we <= 1'b1; d_wa <= a;
            d_in_base <= ib; d_w_base <= 40'h1000 + a; d_out_base <= 40'h2000 + a;
            d_in_beats <= 24'd10 + a; d_w_beats <= 24'd20 + a; d_out_beats <= 24'd30 + a;
            d_ic <= ic; d_oc <= oc; d_h <= h; d_w <= w;
            d_type4 <= t4; d_slice <= sl; d_relu <= 1'b1;
            d_lo <= -16'sd128; d_hi <= 16'sd127;
            @(posedge clk); d_we <= 1'b0;
        end
    endtask

    // Count what happened, per operator. Mode A re-reads the whole input once
    // per (phase, ocg) slice, so op61 sees OC/2 = 16 input starts, the others one.
    integer n_estart = 0, n_done = 0;
    integer n_instart [0:3];
    integer seen_op [0:3];
    integer i;
    always @(posedge clk) if (!rst) begin
        if (e_start) begin n_estart = n_estart + 1; seen_op[cur_op] = seen_op[cur_op] + 1; end
        if (m_in_start) n_instart[cur_op] = n_instart[cur_op] + 1;
        if (done)    n_done = n_done + 1;
    end

    // ---- check 3's instrument: sticky flag, set if any operator starts while a
    // write drain is outstanding ----
    reg drain_pending = 1'b0;
    reg race_seen = 1'b0;
    always @(posedge clk) if (!rst) begin
        if (e_done)                 drain_pending <= 1'b1;
        if (m_out_done)             drain_pending <= 1'b0;
        if (e_start && drain_pending) race_seen <= 1'b1;
    end

    integer p, c;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            seen_op[i] = 0; n_instart[i] = 0; rq_n[i] = 0; rq_bad[i] = 0;
        end
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // The four requantisation tables, written the way the processor will:
        // through the store's own port, once, before the first frame.
        for (p = 0; p < 4; p = p + 1)
            for (c = 0; c < 32; c = c + 1) rq_wr(p, c);

        // The four real operators. op61 is the only mode-A one; 8x8x32 is
        // exactly the 8192-byte capacity the module asserts on.
        wr(2'd0, 40'h4000, 9'd320, 6'd32, 7'd8,  7'd8,  1'b0, 1'b1);  // op61 mode A
        wr(2'd1, 40'h5000, 9'd32,  6'd32, 7'd16, 7'd16, 1'b0, 1'b0);  // op62 mode B
        wr(2'd2, 40'h6000, 9'd32,  6'd32, 7'd32, 7'd32, 1'b0, 1'b0);  // op63 mode B
        // OC = 16, not 14: twn_hd_compute emits OC[5:2] beats, so 14 would drop
        // two channels; twn_hd_seq asserts OC is a multiple of 4.
        wr(2'd3, 40'h7000, 9'd32,  6'd16, 7'd64, 7'd64, 1'b1, 1'b0);  // op64 type 4

        slot_off <= 40'h40000;
        @(posedge clk);
        start <= 1'b1; @(posedge clk); start <= 1'b0;

        // Walk all four, holding the drain off well past e_done every time.
        for (i = 0; i < 4; i = i + 1) begin
            wait (e_start);
            @(posedge clk);
            // check 2 and 4 while this operator is presented
            case (i)
            0: begin
                 chk(e_mode_a === 1'b1, "op61 must be mode A");
                 chk(e_type4  === 1'b0, "op61 must not be type 4");
                 chk(e_ic === 9'd320,   "op61 IC");
                 chk(m_in_base === 40'h4000 + 40'h40000,
                     "op61 input base must carry the slot offset");
               end
            1: begin
                 chk(e_mode_a === 1'b0, "op62 must be mode B");
                 chk(m_in_base === 40'h5000,
                     "op62 reads an intermediate: no slot offset");
               end
            2: chk(e_mode_a === 1'b0, "op63 must be mode B");
            3: begin
                 chk(e_type4  === 1'b1, "op64 must be type 4");
                 chk(e_mode_a === 1'b0, "type 4 must force mode A off");
                 chk(e_oc === 6'd16,    "op64 OC must be padded to 16");
                 chk(m_in_base === 40'h7000,
                     "op64 reads an intermediate: no slot offset");
               end
            endcase
            // Acknowledge input passes: twenty pulses, though mode A needs sixteen;
            // the sequencer must stop at its own count.
            repeat (20) begin
                @(posedge clk);
                m_in_done <= 1'b1; @(posedge clk); m_in_done <= 1'b0;
            end
            repeat (5) @(posedge clk);
            e_done <= 1'b1; @(posedge clk); e_done <= 1'b0;
            // the drain is held off for DRAIN_HOLD cycles, longer than the
            // sequencer's e_done-to-e_start latency
            repeat (DRAIN_HOLD) @(posedge clk);
            chk(!e_start, "sequencer advanced before the write drain completed");
            m_out_done <= 1'b1; @(posedge clk); m_out_done <= 1'b0;
        end

        wait (done);
        @(posedge clk);

        chk(n_estart == 4, "exactly four operators must be issued");
        chk(n_done   == 1, "done must pulse exactly once per frame");
        chk(!race_seen,    "an operator started while a write drain was outstanding");
        // op61 is OC=32 -> OC/2 = 16 passes. The others stream their input once.
        chk(n_instart[0] == 16, "op61 (mode A) must re-issue its input 16 times");
        chk(n_instart[1] == 1,  "op62 (mode B) must issue its input exactly once");
        chk(n_instart[2] == 1,  "op63 (mode B) must issue its input exactly once");
        chk(n_instart[3] == 1,  "op64 (type 4) must issue its input exactly once");
        $display("tb_hd_seq: input starts per operator = %0d %0d %0d %0d (want 16 1 1 1)",
                 n_instart[0], n_instart[1], n_instart[2], n_instart[3]);
        for (i = 0; i < 4; i = i + 1)
            chk(seen_op[i] == 1, "each operator must run exactly once");
        chk(!busy, "busy must drop with done");

        // ---- check 6: the per-operator requantisation replay ----
        $display("tb_hd_seq: requant entries replayed per operator = %0d %0d %0d %0d (want 32 32 32 32)",
                 rq_n[0], rq_n[1], rq_n[2], rq_n[3]);
        $display("tb_hd_seq: requant entries WRONG per operator     = %0d %0d %0d %0d (want 0 0 0 0)",
                 rq_bad[0], rq_bad[1], rq_bad[2], rq_bad[3]);
        chk(rq_n[0] == 32, "op61 must have all 32 requant entries loaded before it starts");
        chk(rq_n[1] == 32, "op62 must have all 32 requant entries loaded before it starts");
        chk(rq_n[2] == 32, "op63 must have all 32 requant entries loaded before it starts");
        chk(rq_n[3] == 32, "op64 must have all 32 requant entries loaded before it starts");
        chk(rq_bad[0] == 0, "op61 got requant entries that are not op61's");
        chk(rq_bad[1] == 0, "op62 got requant entries that are not op62's");
        chk(rq_bad[2] == 0, "op63 got requant entries that are not op63's");
        chk(rq_bad[3] == 0, "op64 got requant entries that are not op64's");
        chk(rq_late == 0,    "requant entries were replayed after the last operator started");
        chk(rq_partial == 0, "m0 was written without its bias and shift -- the entry is one write");

        if (errors == 0) $display("tb_hd_seq: PASS (4 operators, order, derive, race, slot, mode-A passes, per-operator requant)");
        else             $display("tb_hd_seq: %0d FAILURES", errors);
        $finish;
    end

    // A timeout names its cause: the sticky race_seen flag shows whether the
    // write drain was skipped (the inline chk(!e_start) samples after the
    // one-cycle e_start pulse and cannot see it).
    initial begin
        #200000;
        $display("tb_hd_seq: TIMEOUT -- the walk never completed");
        if (race_seen)
            $display("tb_hd_seq: CAUSE = an operator started while a write drain was still outstanding -- the S_DRAIN wait is missing or skipped");
        else
            $display("tb_hd_seq: CAUSE = not the write-drain race; %0d of 4 operators issued, stuck elsewhere", n_estart);
        $display("tb_hd_seq: %0d FAILURES", (errors == 0) ? 1 : errors);
        $finish;
    end
endmodule
`default_nettype wire
