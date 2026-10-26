// ============================================================================
//  tb_rowptr_rule.v -- the 3x3 depthwise row-pointer rules, checked
//  exhaustively against the window definition. Self-contained (no RTL, no
//  input files); the rules are the two functions in this file.
//
//  (1) fire threshold for output row r: min(r*s + 2, H_in).
//  (2) read pointer after output row r: max(0, s*(r+1) - 1).
//  Window of output row r (stride s, pad 1): input rows r*s-1 .. r*s+1.
//  For H_in 2..130, s = 1, 2 (stride 2 only for even H_in) and every r, it
//  checks that the rules never admit a row not yet written, never release a row
//  the next window needs, never lag behind it, are monotone, and that every
//  threshold is reachable. A few named boundary cases follow.
//  `ifdef BAD_NO_CAP drops the min in (1); `ifdef BAD_NAIVE_RPTR uses s*r for
//  (2); each must make the run fail.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rowptr_rule;

    integer errors = 0;
    integer checks = 0;

    // ---- the rules under test ----
    function integer fire_threshold;              // rule (1)
        input integer r, s, h_in;
        begin
            fire_threshold = r*s + 2;
`ifndef BAD_NO_CAP
            if (fire_threshold > h_in) fire_threshold = h_in;   // the correction
`endif
        end
    endfunction

    function integer rptr_after;                  // rule (2)
        input integer r, s;
        begin
`ifdef BAD_NAIVE_RPTR
            rptr_after = s*r;                      // the naive "rptr += s" form
`else
            rptr_after = s*(r+1) - 1;
`endif
            if (rptr_after < 0) rptr_after = 0;
        end
    endfunction

    // ---- the definition the rules must agree with ----
    // Output row r of a 3x3 depthwise with stride s and padding 1 reads input
    // rows r*s-1, r*s, r*s+1. Rows outside [0, h_in) are the zero pad.
    function integer win_lo; input integer r, s; begin win_lo = r*s - 1; end endfunction
    function integer win_hi; input integer r, s; begin win_hi = r*s + 1; end endfunction

    task check;
        input cond; input [255:0] what; input integer h_in, s, r;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("  FAIL %0s  H_in=%0d stride=%0d r=%0d  (fire>=%0d, rptr=%0d, window %0d..%0d)",
                             what, h_in, s, r, fire_threshold(r,s,h_in), rptr_after(r,s),
                             win_lo(r,s), win_hi(r,s));
            end
        end
    endtask

    integer s, h_in, r, h_out, need_hi, thr, rp, rp_prev, live_lo;
    integer fired_all;

    initial begin
        $display("=== row-pointer rules, exhaustive ===");

        for (s = 1; s <= 2; s = s + 1) begin
            // heights 2..130, odd ones included to catch last-row off-by-ones
            for (h_in = 2; h_in <= 130; h_in = h_in + 1) begin
                if (!(s == 2 && (h_in % 2 != 0))) begin      // stride 2 needs an even height
                    h_out = (s == 1) ? h_in : h_in / 2;
                    fired_all = 1;
                    rp_prev = 0;

                    for (r = 0; r < h_out; r = r + 1) begin
                        thr = fire_threshold(r, s, h_in);
                        rp  = rptr_after(r, s);

                        // (a) when the threshold is met, every REAL row of the window is present.
                        //     "present" = index < wptr, and wptr is at least thr at fire time.
                        need_hi = win_hi(r, s);
                        if (need_hi > h_in - 1) need_hi = h_in - 1;   // the rest is bottom pad
                        check(need_hi < thr || need_hi < 0, "window row not yet written", h_in, s, r);

                        // (c) the threshold must be reachable: wptr tops out at h_in.
                        check(thr <= h_in, "threshold unreachable", h_in, s, r);
                        if (thr > h_in) fired_all = 0;

                        // (b) the pointer must not release a row that a LATER window still needs.
                        //     After row r the oldest row still needed is win_lo(r+1, s), clipped at 0.
                        if (r + 1 < h_out) begin
                            live_lo = win_lo(r + 1, s);
                            if (live_lo < 0) live_lo = 0;
                            check(rp <= live_lo, "released a row the next window needs", h_in, s, r);
                            // and it must not lag either, or the ring fills and the producer stalls
                            check(rp >= live_lo, "failed to release a dead row", h_in, s, r);
                        end

                        // (d) monotone, and never past what has been written
                        check(rp >= rp_prev, "pointer went backwards", h_in, s, r);
                        check(rp <= h_in,    "pointer past the last row", h_in, s, r);
                        rp_prev = rp;
                    end

                    check(fired_all == 1, "some output row could never fire", h_in, s, 0);
                end
            end
        end

        // ---- named boundary cases ----
        // stride 1, last row: without the min the threshold would be h_in+1
        check(fire_threshold(63, 1, 64) == 64, "stride-1 last row must cap at H_in", 64, 1, 63);
        check(63*1 + 2 == 65,                  "and the uncapped form really is 65", 64, 1, 63);
        // stride 2, first row: the naive rptr += s would give 2, releasing row 1
        check(rptr_after(0, 2) == 1, "stride-2 first row advances by s-1, not s", 128, 2, 0);
        check(rptr_after(1, 2) == 3, "stride-2 second row advances by s",         128, 2, 1);
        check(rptr_after(0, 1) == 0, "stride-1 first row advances by 0",          64, 1, 0);

        $display("  %0d checks", checks);
        if (errors == 0) $display("=== tb_rowptr_rule: ALL PASS ===");
        else             $display("=== tb_rowptr_rule: %0d FAIL ===", errors);
        $finish;
    end
endmodule
`default_nettype wire
