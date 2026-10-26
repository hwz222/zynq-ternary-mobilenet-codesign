// tb_rowbuf_mod3.v -- twn_rowbuf's mod3 and q3_2 functions, exhaustively.
//
// For every 11-bit row index (0..2047) the functions are called hierarchically
// on a twn_rowbuf instance (RB.mod3, RB.q3_2) and compared with r % 3 and
// (r / 3) % 2. The instance is never clocked or driven; it only owns the
// functions, so what is checked is the RTL's own code. No golden files.
// Self-checking, prints ALL PASS or FAIL. Top module is tb_mod3.
//
// Break arm (see sim/run_units.ps1): -DMOD3_TB_NEG_NO_S3 replaces the function
// under test with a local copy whose last fold lacks the >= 3 correction; the
// sweep must fail. It is testbench-only and does not touch twn_rowbuf.v.
`timescale 1ns/1ps
module tb_mod3;
    twn_rowbuf RB ();          // owns the functions under test; nothing else

`ifdef MOD3_TB_NEG_NO_S3
    function [1:0] mod3_bad; input [10:0] r;
        reg [5:0] s1; reg [3:0] s2; reg [2:0] s3;
        begin
            s1 = {4'd0, r[1:0]} + {4'd0, r[3:2]} + {4'd0, r[5:4]}
               + {4'd0, r[7:6]} + {4'd0, r[9:8]} + {5'd0, r[10]};
            s2 = {2'd0, s1[1:0]} + {2'd0, s1[3:2]} + {2'd0, s1[5:4]};
            s3 = {1'd0, s2[1:0]} + {1'd0, s2[3:2]};
            mod3_bad = s3[1:0];                      // the >= 3 correction removed
        end
    endfunction
`endif

    integer r, bad; reg [1:0] m; reg q;
    initial begin
        bad = 0;
        for (r = 0; r < 2048; r = r + 1) begin
`ifdef MOD3_TB_NEG_NO_S3
            m = mod3_bad(r[10:0]);
`else
            m = RB.mod3(r[10:0]);
`endif
            q = RB.q3_2(m, r[0]);
            if (m !== (r % 3)) begin
                bad = bad + 1;
                if (bad < 6) $display("  mod3(%0d) = %0d, want %0d", r, m, r % 3);
            end
            if (q !== ((r / 3) % 2)) begin
                bad = bad + 1;
                if (bad < 6) $display("  q3_2(%0d) = %0d, want %0d", r, q, (r/3)%2);
            end
        end
        $display("=== tb_mod3: 2048 rows of twn_rowbuf's mod3/q3_2, %0d errors, %s ===", bad,
                 (bad == 0) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
