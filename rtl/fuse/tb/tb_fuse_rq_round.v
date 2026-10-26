// ============================================================================
//  tb_fuse_rq_round.v -- directed test of twn_fuse_requant at the edges of its
//  11-bit rounding window and at the clamp's edges.
//
//  Golden data: none read from files; the expected value is computed here in
//  64-bit arithmetic (round half up, arithmetic shift, optional ReLU, clamp).
//  t is driven through `bias` with acc*m0 = 0.
//  Inputs: q = t >>> sh swept over {1022, 1023, 1024, -1023, -1024, -1025} (window
//  edges) and {-129 .. 128} around the clamp, crossed with round bit 0/1,
//  sh = 1..25 and the two (relu, otype) pairs (1, 0) and (0, 1).
//  q = 1023 with the round bit set is what an 11-bit rounding adder wraps.
//
//  Break arms (defines in twn_fuse_requant.v; see sim/run_units.ps1):
//    RQ_NEG_WINDOW11   rounds inside the 11-bit window; fails at q = 1023, rbit = 1.
//    RQ_NO_ROUND       truncates instead of rounding; fails on in-range values.
//  Prints "ALL PASS" or "N FAIL".
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_fuse_rq_round;

    reg clk = 0; always #5 clk = ~clk;

    reg signed [19:0] acc;
    reg signed [17:0] m0;
    reg signed [39:0] bias;
    reg [5:0]  sh;
    reg        relu;
    reg [1:0]  otype;
    wire signed [7:0] out;

    twn_fuse_requant #(.SPLIT(1)) DUT (
        .clk(clk), .ce(1'b1), .acc(acc), .m0(m0), .bias(bias),
        .sh(sh), .relu(relu), .otype(otype), .out(out));

    integer errors, checked;

    // the contract, in plain arithmetic: t = acc*m0 + bias, rounded half up by
    // an arithmetic shift, then clamped. Computed here on 64 bits so the model
    // has no window of its own to fall out of.
    function signed [7:0] want;
        input signed [63:0] t; input [5:0] s; input rl; input [1:0] ot;
        reg signed [63:0] y; reg signed [63:0] lo, hi;
        begin
            y  = (s == 0) ? t : ((t + (64'sd1 <<< (s-1))) >>> s);
            lo = (ot == 2'd0) ? 64'sd0 : -64'sd127;
            hi = 64'sd127;
            if (rl && y < 0) y = 0;
            if      (y < lo) want = lo[7:0];
            else if (y > hi) want = hi[7:0];
            else             want = y[7:0];
        end
    endfunction

    task check;
        input signed [63:0] t; input [5:0] s; input rl; input [1:0] ot;
        reg signed [7:0] exp;
        begin
            // drive t through bias with acc*m0 = 0, so this test isolates the
            // rounding window and does not depend on the multiplier at all
            acc = 20'sd0; m0 = 18'sd0; bias = t[39:0];
            sh = s; relu = rl; otype = ot;
            @(negedge clk); @(negedge clk); @(negedge clk); @(negedge clk);
            @(negedge clk);
            exp = want(t, s, rl, ot);
            checked = checked + 1;
            if (out !== exp) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("  MISMATCH  t=%0d sh=%0d relu=%0d otype=%0d : got %0d want %0d",
                             t, s, rl, ot, out, exp);
            end
        end
    endtask

    integer si, qi, ri, oi;
    localparam integer NQ = 19;
    integer q_edge [0:NQ-1];
    reg signed [63:0] t;

    initial begin
        errors = 0; checked = 0;
        q_edge[0] = 1022;  q_edge[1] = 1023;  q_edge[2] = 1024;
        q_edge[3] = -1023; q_edge[4] = -1024; q_edge[5] = -1025;
        // the clamp's edges and the zero crossing, where rounding is visible
        q_edge[6]  = -129; q_edge[7]  = -128; q_edge[8]  = -127;
        q_edge[9]  = -2;   q_edge[10] = -1;   q_edge[11] = 0;
        q_edge[12] = 1;    q_edge[13] = 2;    q_edge[14] = 63;
        q_edge[15] = 125;  q_edge[16] = 126;  q_edge[17] = 127;
        q_edge[18] = 128;
        acc = 0; m0 = 0; bias = 0; sh = 0; relu = 1; otype = 0;
        repeat (4) @(negedge clk);

        $display("=== tb_fuse_rq_round: the top and bottom of the 11-bit round window, and the clamp's edges ===");
        for (si = 1; si <= 25; si = si + 1)          // every shift the model uses
          for (qi = 0; qi < NQ; qi = qi + 1)
            for (ri = 0; ri < 2; ri = ri + 1)        // round bit clear / set
              for (oi = 0; oi < 2; oi = oi + 1) begin
                  // t such that t >>> si == q_edge[qi], with bit si-1 = ri
                  t = ($signed(q_edge[qi]) <<< si) + (ri ? (64'sd1 <<< (si-1)) : 64'sd0);
                  // The two (relu, otype) pairings swept: (1, 0) and (0, 1).
                  check(t, si[5:0], (oi == 0) ? 1'b1 : 1'b0, oi[1:0]);
              end

        $display("  %0d values checked, %0d errors", checked, errors);
        if (errors == 0) $display("=== tb_fuse_rq_round: ALL PASS ===");
        else             $display("=== tb_fuse_rq_round: %0d FAIL ===", errors);
        $finish;
    end

endmodule
`default_nettype wire
