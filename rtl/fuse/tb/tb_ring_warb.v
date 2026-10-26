// tb_ring_warb.v -- twn_ring_warb: conservation of both producers and zero latency for B.
//
// Inputs: none; the stimulus is generated here (WIDTH 64, 600 B writes).
// Properties:
//   CONSERVATION  every write PRESENTED by A or B reaches the memory in order, none lost,
//                 duplicated or invented. The ledger records presented writes whatever
//                 a_ready said, and A's producer is registered (it samples a_can at the
//                 clock edge and presents on the next cycle), as the real loader is.
//   LATENCY B     a B write appears at the memory exactly one cycle after it is presented
//                 (equality, not a bound): twn_dw_array has no ready input.
//   PROMISE       a_can high in one cycle implies a_ready high in the next (checked
//                 every cycle).
// Phases: 1 B every cycle; 2 B pseudo-random at about 7/8 duty; 3 B alternating,
//   50%; 5 A presents without asking (a_deaf) and a_dropped must set.
// ifdef arms: WARB_NEG_LOSSY (in twn_ring_warb.v) must fail; WARB_TB_USE_READY drives A
//   from a_ready instead of a_can, to show the two signals differ (not a design break).
// No input files. Prints ALL PASS or FAIL.
`timescale 1ns/1ps
`default_nettype none

module tb_ring_warb;

    localparam integer WIDTH = 64;      // narrow: this is about control
    localparam integer AW    = 12;
    localparam integer LANES = 16;
    localparam integer N     = 600;     // B writes; A takes what is left

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    reg              a_we, b_we;
    reg  [AW-1:0]    a_wa, b_wa;
    reg  [WIDTH-1:0] a_wd, b_wd;
    reg  [LANES-1:0] a_lane, b_lane;
    wire             a_ready, a_can;

    wire             m_we, b_dropped, a_dropped;
    wire [AW-1:0]    m_wa;
    wire [WIDTH-1:0] m_wd;
    wire [LANES-1:0] m_lane;

    twn_ring_warb #(.WIDTH(WIDTH), .AW(AW), .LANES(LANES)) DUT (
        .clk(clk), .rst(rst),
        .a_we(a_we), .a_wa(a_wa), .a_wd(a_wd), .a_lane(a_lane),
        .a_ready(a_ready), .a_can(a_can),
        .b_we(b_we), .b_wa(b_wa), .b_wd(b_wd), .b_lane(b_lane),
        .m_we(m_we), .m_wa(m_wa), .m_wd(m_wd), .m_lane(m_lane),
        .b_dropped(b_dropped), .a_dropped(a_dropped));

    reg [WIDTH-1:0] a_sent [0:N*4-1];
    reg [WIDTH-1:0] b_sent [0:N*4-1];
    integer a_at [0:N*4-1];
    integer b_at [0:N*4-1];
    integer cyc = 0;
    integer a_ns = 0, b_ns = 0, a_nr = 0, b_nr = 0;
    integer errors = 0, a_worst = 0, b_worst = 0, b_late = 0;
    integer a_refused = 0;              // presented while a_ready was low
    integer a_promise_broken = 0;       // a_can said yes and a_ready then said no
    integer a_ns_hon = 0, a_nr_hon = 0, b_nr_hon = 0; // the ledger at the end of phase 4

    // ---- A's producer: registered; presents on the cycle after a_can was seen.
    reg  a_offer;                       // this phase wants A to write at all
    reg  a_deaf;                        // phase 5: present without asking
    reg  ph5;                           // phase 5 is running; the ledger stops scoring A
    integer ai;
    // WARB_TB_USE_READY drives the producer from a_ready instead of a_can.
`ifdef WARB_TB_USE_READY
    wire a_grant = a_ready;
`else
    wire a_grant = a_can;
`endif
    always @(posedge clk) begin
        if (rst) begin
            a_we <= 1'b0; a_wd <= {WIDTH{1'b0}}; a_wa <= {AW{1'b0}}; ai <= 0;
        end else if (a_offer && (a_deaf || a_grant)) begin
            a_we <= 1'b1;
            // zero-extended from 32, not {1'b0, ai[WIDTH-2:0]}: `ai` is an
            // integer, so the bits above 31 of that slice are X and every
            // display of a lost word came out as Xxxxxxxx.
            a_wd <= {{(WIDTH-32){1'b0}}, ai[31:0]};
            a_wa <= ai[AW-1:0];
            ai   <= ai + 1;
        end else begin
            a_we <= 1'b0;
        end
    end

    // The promise, checked every cycle: a_can high must mean a_ready high in
    // the next cycle. Separate block from the ledger's blocking counters.
    reg a_can_q, seen;
    always @(posedge clk) begin
        if (rst) begin a_can_q <= 1'b0; seen <= 1'b0; end
        else begin
            a_can_q <= a_can;
            seen    <= 1'b1;
            if (seen && a_can_q && !a_ready) a_promise_broken <= a_promise_broken + 1;
        end
    end

    // ---- the ledger. Every write PRESENTED is entered, whatever a_ready said.
    // the data word carries its own identity: top bit = producer, rest = sequence
    always @(posedge clk) if (!rst) begin
        cyc = cyc + 1;
        if (a_we) begin
            if (!a_ready) a_refused = a_refused + 1;
            // In phase 5 A breaks the contract on purpose; the ledger stops
            // scoring A there and only a_refused and a_dropped are read.
            if (!ph5) begin a_sent[a_ns] = a_wd; a_at[a_ns] = cyc; a_ns = a_ns + 1; end
        end
        if (b_we) begin b_sent[b_ns] = b_wd; b_at[b_ns] = cyc; b_ns = b_ns + 1; end

        if (m_we) begin
            if (m_wd[WIDTH-1] == 1'b0) begin
                if (!ph5) begin
                    if (a_nr >= a_ns) begin
                        errors = errors + 1;
                        if (errors <= 8) $display("  memory saw an A write never presented: %016h", m_wd);
                    end else if (m_wd !== a_sent[a_nr]) begin
                        errors = errors + 1;
                        if (errors <= 8)
                            $display("  A out of order at %0d: got %016h want %016h", a_nr, m_wd, a_sent[a_nr]);
                    end else if (cyc - a_at[a_nr] > a_worst) a_worst = cyc - a_at[a_nr];
                    a_nr = a_nr + 1;
                end
            end else begin
                if (b_nr >= b_ns) begin
                    errors = errors + 1;
                    if (errors <= 8) $display("  memory saw a B write never presented: %016h", m_wd);
                end else begin
                    if (m_wd !== b_sent[b_nr]) begin
                        errors = errors + 1;
                        if (errors <= 8)
                            $display("  B out of order at %0d: got %016h want %016h", b_nr, m_wd, b_sent[b_nr]);
                    end
                    // equality: B is a pass-through
                    if (cyc - b_at[b_nr] != 1) begin
                        b_late = b_late + 1;
                        if (b_late <= 6)
                            $display("  B DELAYED: write %0d presented at %0d, delivered at %0d (+%0d)",
                                     b_nr, b_at[b_nr], cyc, cyc - b_at[b_nr]);
                    end
                    if (cyc - b_at[b_nr] > b_worst) b_worst = cyc - b_at[b_nr];
                end
                b_nr = b_nr + 1;
            end
        end
    end

    integer bi, lfsr;
    initial begin
        $display("=== tb_ring_warb: B at 100%%, 86%% and 50%%, %0d B writes, A on a REGISTERED grant ===", N);
        b_we = 0; b_wa = 0; b_wd = 0;
        a_lane = {LANES{1'b1}}; b_lane = 16'h0001;
        a_offer = 0; a_deaf = 0; ph5 = 0;
        bi = 0; lfsr = 32'hACE1;
        repeat (3) @(negedge clk); rst = 0;
        a_offer = 1;

        // Phase 1: B every cycle, A offering whenever it is granted.
        while (bi < N/3) begin
            @(negedge clk);
            b_we = 1; b_wd = {1'b1, {(WIDTH-33){1'b0}}, bi[31:0]}; b_wa = bi[AW-1:0]; bi = bi + 1;
        end

        // Phase 2: B at about 7/8 duty, A still offering; B must never be delayed.
        while (bi < (2*N)/3) begin
            @(negedge clk);
            lfsr = (lfsr << 1) ^ (lfsr[15] ? 32'h002D : 32'd0);
            b_we = (lfsr[2] || lfsr[3] || lfsr[5]);          // about 86%
            if (b_we) begin b_wd = {1'b1, {(WIDTH-33){1'b0}}, bi[31:0]}; b_wa = bi[AW-1:0]; bi = bi + 1; end
        end

        // Phase 3: B alternating, 50%. A's permission rises and falls on
        // adjacent cycles, which refuses a producer that acts one cycle late.
        while (bi < N) begin
            @(negedge clk); b_we = 1; b_wd = {1'b1, {(WIDTH-33){1'b0}}, bi[31:0]}; b_wa = bi[AW-1:0];
            bi = bi + 1;
            @(negedge clk); b_we = 0;
        end
        @(negedge clk); b_we = 0;
        repeat (8) @(negedge clk);
        a_offer = 0;
        repeat (8) @(negedge clk);

        // the ledger before phase 5 breaks the contract on purpose
        a_ns_hon = a_ns; a_nr_hon = a_nr; b_nr_hon = b_nr;

        if (a_nr != a_ns) begin
            errors = errors + 1;
            $display("  A: %0d PRESENTED but %0d delivered -- %0d LOST", a_ns, a_nr, a_ns - a_nr);
            $display("     %0d of them were presented while a_ready was low.", a_refused);
            $display("     The producer obeyed the arbiter's own answer and STILL lost writes:");
            $display("     that answer is about the cycle it was given in, and a registered");
            $display("     producer can only ever act on the next one.");
        end
        // the promise stands alone: a_can high before a_ready low is a violation
        // whether or not a write was presented into it
        if (a_promise_broken != 0) begin
            errors = errors + 1;
            $display("  a_can was high on %0d cycles whose NEXT cycle had a_ready low.",
                     a_promise_broken);
            $display("     a_can is a promise about the next cycle; a producer that registers");
            $display("     it and then presents cannot be refused. It was a status, not a promise.");
        end
        if (a_dropped) begin
            errors = errors + 1;
            $display("  a_dropped is SET while A obeyed the grant -- a write was thrown away");
        end
        if (b_nr != b_ns) begin
            errors = errors + 1;
            $display("  B: %0d presented but %0d delivered -- %0d LOST", b_ns, b_nr, b_ns - b_nr);
        end
        if (b_late != 0) begin
            errors = errors + 1;
            $display("  B was delayed on %0d of %0d writes (worst +%0d). B cannot be stalled.",
                     b_late, b_ns, b_worst);
        end
        if (b_dropped) begin
            errors = errors + 1;
            $display("  b_dropped is SET -- the arbiter refused a write B had presented");
        end
        if (a_ns == 0) begin
            errors = errors + 1;
            $display("  A was never offered at all -- the stimulus, not the design");
        end
        if (a_nr < N/8) begin
            errors = errors + 1;
            $display("  A delivered only %0d writes against B's %0d -- starved, not merely slowed.",
                     a_nr, b_nr);
        end

        $display("  A %0d presented / %0d delivered, worst wait %0d, %0d refused",
                 a_ns, a_nr, a_worst, a_refused);
        $display("  B %0d presented / %0d delivered, worst wait %0d (must be 1)", b_ns, b_nr, b_worst);

        // ============ phase 5: the detector must be able to fire ============
        // A producer that ignores the grant is a defect, but the arbiter must
        // flag it (a_dropped) rather than discard silently.
        $display("  ---- phase 5: A presents WITHOUT asking (the pre-fix loader) ----");
        ph5 = 1; a_deaf = 1; a_offer = 1;
        bi = 0;
        while (bi < 64) begin
            @(negedge clk);
            b_we = 1; b_wd = {1'b1, {(WIDTH-33){1'b0}}, (32'd9000 + bi)}; b_wa = bi[AW-1:0];
            bi = bi + 1;
        end
        @(negedge clk); b_we = 0; a_offer = 0; a_deaf = 0;
        repeat (8) @(negedge clk);
        if (!a_dropped) begin
            errors = errors + 1;
            $display("  🔴 a_dropped is CLEAR after A presented into a full arbiter for 64");
            $display("     cycles. Those writes are gone and NOTHING in the design says so.");
        end else begin
            $display("  a_dropped fired, as it must (%0d of A's %0d writes refused overall)",
                     a_refused, a_ns);
        end

        $display("=== tb_ring_warb: %0d errors, %s ===", errors,
                 (errors == 0 && b_nr_hon == N && a_ns_hon > 0 && a_nr_hon > 0)
                 ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
`default_nettype wire
