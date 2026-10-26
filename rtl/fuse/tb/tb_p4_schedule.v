// ============================================================================
//  tb_p4_schedule.v -- twn_blockseq's schedule for block 1 (16 -> 96 -> 24,
//  128x128, depthwise stride 2) with every stage modelled as a counter that
//  consumes its row-time in cycles. No datapath, no input files.
//
//  Row times (the localparams below): E_ROW = 768, D_ROW = 1536, P_ROW = 384
//  cycles; the array owes S_DW*E_ROW + P_ROW = 1920 per output row, 122,880
//  for 64 output rows. The test prints the measured cycles against that ideal,
//  array and depthwise busy rates, and the idle cycles split into startup,
//  mid-block and drain.
//  Verdict by array busy rate: >= 88% PASS, 60-88% DECIDE, below 60% STOP;
//  a run that does not finish within the guard prints FAIL.
//  `ifdef D_T1_5 / D_T1_6 / D_T1_8 / D_T1_12 set the tern1 row-buffer depth
//  (default 4). Defines are valueless because xvlog on Windows splits
//  -d NAME=VALUE on the '='.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_p4_schedule;

    // ---- block 1 ----
    localparam integer C_IN = 16, C_MID = 96, C_OUT = 24;
    localparam integer H_IN = 128, W_IN = 128;
    localparam integer S_DW = 2;
    localparam integer STEM = 0;                  // per block, substituted
    localparam integer H_OUT = H_IN / S_DW, W_OUT = W_IN / S_DW;
    localparam integer PIX = 4, LANES = 128, DW_LANES = 8;
    localparam integer PACK_E = 4, PACK_P = 1;

    localparam integer E_ROW = (W_IN/PIX) * ((C_MID + PACK_E - 1)/PACK_E) * ((C_IN + LANES - 1)/LANES);
    // The depthwise reads every input column: ceil(Cmid/DW_LANES) x W_IN.
    localparam integer D_ROW = ((C_MID + DW_LANES - 1)/DW_LANES) * W_IN;
    localparam integer P_ROW = (W_OUT/PIX) * ((C_OUT + PACK_P - 1)/PACK_P) * ((C_MID + LANES - 1)/LANES);
    localparam integer LD_ROW = (C_IN  * W_IN  + 15) / 16;    // 16 bytes/cycle on HP0
    localparam integer ST_ROW = (C_OUT * W_OUT + 15) / 16;

    localparam integer IDEAL_ARRAY = S_DW * E_ROW + P_ROW;              // 1,920
    localparam integer IDEAL_TOTAL = H_OUT * IDEAL_ARRAY;               // 122,880

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1, start = 0;

    wire ld_req, e_req, d_req, p_req, st_req;
    reg  ld_done, e_done, d_done, p_done, st_done;
    wire [7:0] e_row, d_row, p_row, ld_row, st_row;
    wire [9:0] t1_rptr;
    wire busy, done;
    wire [31:0] cyc_total, cyc_array, cyc_dw, cyc_stall;
    wire [31:0] cyc_pre, cyc_post;
    wire [31:0] w_e_ld, w_e_t1, w_p_dw, w_p_out;

    // ---- row buffer levels, modelled ----
    reg [9:0] in_wptr, t1_wptr, dw_wptr;
    reg [9:0] out_cnt;
    // D_T1 selects the tern1 row-buffer depth (see the header).
`ifdef D_T1_5
    localparam integer D_T1 = 5;
`elsif D_T1_6
    localparam integer D_T1 = 6;
`elsif D_T1_8
    localparam integer D_T1 = 8;
`elsif D_T1_12
    localparam integer D_T1 = 12;
`else
    localparam integer D_T1 = 4;
`endif
    localparam integer D_IN = 4, D_DW = 2, D_OUT = 2;
    wire [9:0] in_free  = D_IN  - (in_wptr - {2'b0, e_row});
    wire [9:0] t1_free  = D_T1  - (t1_wptr - t1_rptr);
    wire [9:0] dw_free  = D_DW  - (dw_wptr - {2'b0, p_row});
    wire [9:0] out_free = D_OUT - (out_cnt - {2'b0, st_row});

    twn_blockseq #(.PIX(PIX), .LANES(LANES), .DW_LANES(DW_LANES)) DUT (
        .clk(clk), .rst(rst), .start(start),
        .c_in(C_IN[9:0]), .c_mid(C_MID[9:0]), .c_out(C_OUT[9:0]),
        .h_in(H_IN[8:0]), .w_in(W_IN[8:0]), .s_dw(S_DW == 2), .stem(STEM[0]),
        .pack_e(3'd2), .pack_p(3'd0),
        .ld_req(ld_req), .ld_done(ld_done), .e_req(e_req), .e_done(e_done),
        .d_req(d_req),  .d_done(d_done),   .p_req(p_req), .p_done(p_done),
        .st_req(st_req), .st_done(st_done),
        .e_row(e_row), .d_row(d_row), .p_row(p_row), .ld_row(ld_row), .st_row(st_row),
        .in_wptr(in_wptr), .in_free(in_free),
        .t1_wptr(t1_wptr), .t1_free(t1_free), .t1_rptr(t1_rptr),
        .dw_wptr(dw_wptr), .dw_free(dw_free), .out_free(out_free),
        // has_res tied low: no residual buffer here (an unconnected input would
        // be Z and make grant_ld X).
        .has_res(1'b0),
        .busy(busy), .done(done),
        .cyc_total(cyc_total), .cyc_array(cyc_array), .cyc_dw(cyc_dw), .cyc_stall_mem(cyc_stall),
        .cyc_idle_pre(cyc_pre), .cyc_idle_post(cyc_post),
        .why_e_ld(w_e_ld), .why_e_t1full(w_e_t1),
        .why_p_dw(w_p_dw), .why_p_outfull(w_p_out));

    // ---- each stage: a counter that consumes exactly the modelled cycles ----
    integer ld_c, e_c, d_c, p_c, st_c;
    always @(posedge clk) begin
        if (rst) begin
            ld_c <= 0; e_c <= 0; d_c <= 0; p_c <= 0; st_c <= 0;
            ld_done <= 0; e_done <= 0; d_done <= 0; p_done <= 0; st_done <= 0;
            in_wptr <= 0; t1_wptr <= 0; dw_wptr <= 0; out_cnt <= 0;
        end else begin
            ld_done <= 0; e_done <= 0; d_done <= 0; p_done <= 0; st_done <= 0;

            if (ld_req) begin
                if (ld_c >= LD_ROW-1) begin ld_c <= 0; ld_done <= 1; in_wptr <= in_wptr + 1; end
                else ld_c <= ld_c + 1;
            end
            if (e_req) begin
                if (e_c >= E_ROW-1) begin e_c <= 0; e_done <= 1; t1_wptr <= t1_wptr + 1; end
                else e_c <= e_c + 1;
            end
            if (d_req) begin
                if (d_c >= D_ROW-1) begin d_c <= 0; d_done <= 1; dw_wptr <= dw_wptr + 1; end
                else d_c <= d_c + 1;
            end
            if (p_req) begin
                if (p_c >= P_ROW-1) begin p_c <= 0; p_done <= 1; out_cnt <= out_cnt + 1; end
                else p_c <= p_c + 1;
            end
            if (st_req) begin
                if (st_c >= ST_ROW-1) begin st_c <= 0; st_done <= 1; end
                else st_c <= st_c + 1;
            end
        end
    end

    real busy_pct;
    integer guard;
    initial begin
        $display("=== P4 schedule, block 1 (16 -> 96 -> 24, 128x128, dw stride 2) ===");
        $display("  rowbuf_tern1 depth %0d", D_T1);
        $display("  from the model:  E_row %0d   D_row %0d   P_row %0d", E_ROW, D_ROW, P_ROW);
        $display("  ideal: array owes %0d cycles per output row, block = %0d cycles",
                 IDEAL_ARRAY, IDEAL_TOTAL);
        repeat (4) @(negedge clk); rst = 0;
        @(negedge clk); start = 1; @(negedge clk); start = 0;

        guard = 0;
        while (!done && guard < 4000000) begin @(negedge clk); guard = guard + 1; end

        if (guard >= 4000000) begin
            $display("  *** DID NOT FINISH -- e_row %0d d_row %0d p_row %0d st_row %0d",
                     e_row, d_row, p_row, st_row);
            $display("=== tb_p4_schedule: FAIL (no completion) ===");
        end else begin
            busy_pct = 100.0 * cyc_array / cyc_total;
            $display("  rows done: ld %0d  e %0d  d %0d  p %0d  st %0d   (want ld/e %0d, d/p/st %0d)",
                     ld_row, e_row, d_row, p_row, st_row, H_IN, H_OUT);
            $display("  implied:   E %0d rows x %0d + P %0d rows x %0d = %0d (cyc_array %0d)",
                     e_row, E_ROW, p_row, P_ROW, e_row*E_ROW + p_row*P_ROW, cyc_array);
            $display("");
            $display("  total cycles        %0d   (ideal %0d, overhead %0d = %.2f%%)",
                     cyc_total, IDEAL_TOTAL, cyc_total - IDEAL_TOTAL,
                     100.0 * (cyc_total - IDEAL_TOTAL) / IDEAL_TOTAL);
            $display("  array busy          %0d cycles = %.2f%%", cyc_array, busy_pct);
            $display("  depthwise busy      %0d cycles = %.2f%%", cyc_dw, 100.0 * cyc_dw / cyc_total);
            $display("  nothing could move  %0d cycles = %.2f%%", cyc_stall, 100.0 * cyc_stall / cyc_total);
        // The array's idle cycles split by where they fall; only PRE could be hidden.
            $display("");
            $display("  array idle PRE      %0d cycles   (startup: load, then E filling rows -- what a handover buffer could hide)", cyc_pre);
            $display("  array idle MID      %0d cycles   (arbitration and backpressure -- a handover buffer cannot touch this)",
                     cyc_total - cyc_array - cyc_pre - cyc_post);
            $display("  array idle POST     %0d cycles   (tail draining through D, P and the store)", cyc_post);
            // Which condition blocked, on the mid-block idle cycles. They
            // overlap: the array idles only when E and P are both blocked.
            $display("    of the MID cycles:  E waiting on loader %0d   E blocked by tern1 full %0d", w_e_ld, w_e_t1);
            $display("                        P waiting on dw     %0d   P blocked by out full   %0d", w_p_dw, w_p_out);
            $display("");
            // verdict bands: see the header
            if (busy_pct >= 88.0)
                $display("=== tb_p4_schedule: PASS -- %.2f%% >= 88%%, the projection holds ===", busy_pct);
            else if (busy_pct >= 60.0)
                $display("=== tb_p4_schedule: DECIDE -- %.2f%% is in the 60-88%% band. The design works; the frame-rate projection does NOT. ===", busy_pct);
            else
                $display("=== tb_p4_schedule: STOP -- %.2f%% < 60%%, go back to the dataflow ===", busy_pct);
        end
        $finish;
    end
endmodule
`default_nettype wire
