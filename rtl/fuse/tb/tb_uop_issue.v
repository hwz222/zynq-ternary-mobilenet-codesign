// ============================================================================
//  tb_uop_issue.v -- twn_uop_issue against the real twn_blockseq, all 17 blocks.
//
//  The array, loader, depthwise and store stages are modelled as row-time
//  counters; the scatter is modelled as a drain that outlasts the array.
//  Checks per block: no instruction while the array is busy, never two for one
//  row, a done only with an instruction outstanding, expand/project counts equal
//  the block geometry, no ring occupancy above its depth, and no instruction
//  issued while the modelled scatter is draining.
//  Inputs: tb_uop_cases.vh (written by gen_uop_cases.py in this directory), one case per
//  block. Pass line: "=== tb_uop_issue: ... ALL PASS ===".
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_uop_issue;
    `include "tb_uop_cases.vh"

    localparam integer PIX = 4, LANES = 128, DW_LANES = 8;
    localparam integer D_IN = 4, D_T1 = 4, D_DW = 2, D_OUT = 2;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1, start = 0;

    // ---- the block under test, driven from the case table ----
    reg [9:0] c_in, c_mid, c_out;
    reg [8:0] h_in, w_in;
    reg       s_dw;
    reg stem;
    reg [2:0] pack_e, pack_p;

    integer E_ROW, D_ROW, P_ROW, LD_ROW, ST_ROW, H_MID, H_OUT, W_OUT;

    wire ld_req, e_req, d_req, p_req, st_req;
    reg  ld_done, st_done;
    wire uop_valid, role_q;
    reg  arr_busy_r, arr_done;
    wire arr_busy = arr_busy_r;
    wire e_done = arr_done & ~role_q;          // exactly how twn_fuse_top splits it
    wire p_done = arr_done &  role_q;
    reg  d_done;
    wire [8:0] e_row, d_row, p_row, ld_row, st_row;
    wire [9:0] t1_rptr;
    wire seq_busy, seq_done;

    // Free space saturates at 0 like twn_rowbuf's does (an unsigned DEPTH-occ
    // would wrap to a large value after an overrun and release the brake).
    reg [9:0] in_wptr, t1_wptr, dw_wptr, out_cnt;
    // RingA read pointer: on the stem the consumer names the input row
    // (2*e_row-1), not e_row. For the other blocks it is modelled as e_row.
    wire [9:0] ra_rptr = !stem        ? {1'b0, e_row}
                       : (e_row == 0) ? 10'd0
                                      : ({e_row, 1'b0} - 10'd1);   // 2r - 1
    wire [9:0] in_occ  = in_wptr - ra_rptr;
    wire [9:0] t1_occ  = t1_wptr - t1_rptr;
    wire [9:0] dw_occ  = dw_wptr - {1'b0, p_row};
    wire [9:0] out_occ = out_cnt - {1'b0, st_row};
    wire [9:0] in_free  = (in_occ  >= D_IN ) ? 10'd0 : (D_IN  - in_occ);
    wire [9:0] t1_free  = (t1_occ  >= D_T1 ) ? 10'd0 : (D_T1  - t1_occ);
    wire [9:0] dw_free  = (dw_occ  >= D_DW ) ? 10'd0 : (D_DW  - dw_occ);
    wire [9:0] out_free = (out_occ >= D_OUT) ? 10'd0 : (D_OUT - out_occ);

    twn_blockseq #(.PIX(PIX), .LANES(LANES), .DW_LANES(DW_LANES)) SEQ (
        .clk(clk), .rst(rst), .start(start),
        .c_in(c_in), .c_mid(c_mid), .c_out(c_out),
        .h_in(h_in), .w_in(w_in), .s_dw(s_dw), .stem(stem),
        .pack_e(pack_e), .pack_p(pack_p),
        .ld_req(ld_req), .ld_done(ld_done), .e_req(e_req), .e_done(e_done),
        .d_req(d_req),  .d_done(d_done),   .p_req(p_req), .p_done(p_done),
        .st_req(st_req), .st_done(st_done),
        .e_row(e_row), .d_row(d_row), .p_row(p_row), .ld_row(ld_row), .st_row(st_row),
        .in_wptr(in_wptr), .in_free(in_free),
        .t1_wptr(t1_wptr), .t1_free(t1_free), .t1_rptr(t1_rptr),
        .dw_wptr(dw_wptr), .dw_free(dw_free), .out_free(out_free),
        // No twn_res_buf here: has_res tied low disables the residual loader
        // brake (an unconnected input would be Z and make grant_ld X).
        .has_res(1'b0),
        .busy(seq_busy), .done(seq_done),
        .cyc_total(), .cyc_array(), .cyc_dw(), .cyc_stall_mem(),
        .cyc_idle_pre(), .cyc_idle_post(),
        .why_e_ld(), .why_e_t1full(), .why_p_dw(), .why_p_outfull());

    // ---- the unit under test ----
    twn_uop_issue ISS (
        .clk(clk), .rst(rst),
        .e_req(e_req), .p_req(p_req),
        .arr_busy(arr_busy), .arr_done(arr_done),
        .scat_busy(scat_busy),
        .uop_valid(uop_valid), .role_q(role_q));

    // ---- the array, modelled: starts on uop_valid, runs the row, pulses done ----
    // ---- the scatter, modelled: a drain that outlasts the array ----
    // twn_act_scatter finishes a row's last bank words after the array reports
    // done. FLUSH_LEN is deliberately longer than that gap so the model can fail.
    localparam integer FLUSH_LEN = 20;
    reg        scat_busy;
    integer    fl_c;
    always @(posedge clk) begin
        if (rst) begin scat_busy <= 1'b0; fl_c <= 0; end
        else if (arr_done) begin scat_busy <= 1'b1; fl_c <= 0; end
        else if (scat_busy) begin
            if (fl_c >= FLUSH_LEN - 1) scat_busy <= 1'b0;
            else fl_c <= fl_c + 1;
        end
    end

    // Count of instructions issued while the scatter is still draining.
    integer fire_in_flush = 0;
    always @(posedge clk) if (!rst && uop_valid && scat_busy)
        fire_in_flush = fire_in_flush + 1;

    integer arr_c, arr_n;
    always @(posedge clk) begin
        if (rst) begin
            arr_busy_r <= 1'b0; arr_done <= 1'b0; arr_c <= 0; arr_n <= 0;
        end else begin
            arr_done <= 1'b0;
            if (uop_valid) begin
                arr_busy_r <= 1'b1;
                arr_c <= 0;
                arr_n <= role_q ? P_ROW : E_ROW;
            end else if (arr_busy_r) begin
                if (arr_c >= arr_n - 1) begin arr_busy_r <= 1'b0; arr_done <= 1'b1; end
                else arr_c <= arr_c + 1;
            end
        end
    end

    // ---- the other three stages ----
    // The loader and store models latch their request and run the burst to
    // completion, like twn_act_rd / twn_act_wr (start taken only when not busy).
    // The depthwise takes d_req as a level (in_valid), so it is a plain counter.
    integer ld_c, d_c, st_c;
    reg     ld_busy, st_busy;
    always @(posedge clk) begin
        if (rst) begin
            ld_c <= 0; d_c <= 0; st_c <= 0;
            ld_busy <= 0; st_busy <= 0;
            ld_done <= 0; d_done <= 0; st_done <= 0;
            in_wptr <= 0; t1_wptr <= 0; dw_wptr <= 0; out_cnt <= 0;
        end else begin
            ld_done <= 0; d_done <= 0; st_done <= 0;

            if (!ld_busy) begin
                if (ld_req) begin ld_busy <= 1'b1; ld_c <= 0; end
            end else if (ld_c >= LD_ROW-1) begin
                ld_busy <= 1'b0; ld_done <= 1; in_wptr <= in_wptr + 1;
            end else ld_c <= ld_c + 1;

            if (d_req) begin
                if (d_c >= D_ROW-1) begin d_c <= 0; d_done <= 1; dw_wptr <= dw_wptr + 1; end
                else d_c <= d_c + 1;
            end

            if (!st_busy) begin
                if (st_req) begin st_busy <= 1'b1; st_c <= 0; end
            end else if (st_c >= ST_ROW-1) begin
                st_busy <= 1'b0; st_done <= 1;
            end else st_c <= st_c + 1;
            // the expand's row buffer is credited by the array, not by a stage model
            if (e_done) t1_wptr <= t1_wptr + 1;
            if (p_done) out_cnt <= out_cnt + 1;
        end
    end

    // ---- the ring occupancy invariant ----
    // Occupancy above a ring's depth means a row was overwritten before it was read.
    integer max_in_occ = 0, max_t1_occ = 0, max_dw_occ = 0, max_ou_occ = 0;
    integer occ_err = 0;
    integer b;          // the block index, shared with the case loop below

    task occ_chk;
        input [8*8-1:0] name;
        input integer   occ;
        input integer   depth;
        begin
            if (occ > depth) begin
                occ_err = occ_err + 1;
                if (occ_err <= 6)
                    $display("  blk %0d: %0s ring holds %0d rows, depth is %0d -- a row was overwritten before it was read", b, name, occ, depth);
            end
        end
    endtask

    // Peak occupancy per block, taken from the same _occ wires the brake uses.
    always @(posedge clk) if (!rst && seq_busy) begin
        if (in_occ  > max_in_occ) max_in_occ = in_occ;
        if (t1_occ  > max_t1_occ) max_t1_occ = t1_occ;
        if (dw_occ  > max_dw_occ) max_dw_occ = dw_occ;
        if (out_occ > max_ou_occ) max_ou_occ = out_occ;
    end

    // ---- the checks ----
    integer errors = 0, n_uop = 0, n_e = 0, n_p = 0, i;
    integer tot_uop = 0, tot_e = 0, tot_p = 0;
    reg pend;                       // an instruction is outstanding
    reg pend_role;

    always @(posedge clk) if (!rst) begin
        // (a) never an instruction while the array is busy, and never two for one row
        if (uop_valid && arr_busy) begin
            errors = errors + 1;
            if (errors <= 8) $display("  blk %0d: instruction while the array is busy", b);
        end
        if (uop_valid && pend) begin
            errors = errors + 1;
            if (errors <= 8) $display("  blk %0d: a second instruction for one row", b);
        end
        if (uop_valid) begin
            pend = 1'b1; pend_role = role_q; n_uop = n_uop + 1;
        end
        // (b) the role that finishes is the stage the sequencer had asked for
        if (arr_done) begin
            if (!pend) begin
                errors = errors + 1;
                if (errors <= 8) $display("  blk %0d: done with no instruction outstanding", b);
            end
            pend = 1'b0;
            if (pend_role) n_p = n_p + 1; else n_e = n_e + 1;
        end
    end

    integer guard;
    initial begin
        pend = 0; pend_role = 0;
        $display("=== tb_uop_issue: the real sequencer, %0d blocks ===", NCASE);
        repeat (4) @(negedge clk); rst = 0;

        for (i = 0; i < NCASE; i = i + 1) begin
            b      = UC_BLK [i*8  +: 8];
            c_in   = UC_CIN [i*16 +: 16];
            c_mid  = UC_CMID[i*16 +: 16];
            c_out  = UC_COUT[i*16 +: 16];
            h_in   = UC_HIN [i*16 +: 16];
            w_in   = UC_WIN [i*16 +: 16];
            s_dw   = UC_SDW [i];
            stem = UC_STEM[i];
            pack_e = UC_PKE [i*4  +: 4];
            pack_p = UC_PKP [i*4  +: 4];
            // Loader issues h_in rows; expand produces H_MID (h_in/2 for the
            // stem, which strides by two); project produces H_OUT (halved again
            // when the depthwise strides).
            H_MID  = stem ? (h_in / 2) : h_in;
            H_OUT  = s_dw ? (H_MID / 2) : H_MID;
            W_OUT  = s_dw ? (w_in / 2) : w_in;

            E_ROW  = (w_in/PIX) * ((c_mid + (1<<pack_e) - 1) / (1<<pack_e))
                                * ((c_in + LANES - 1) / LANES);
            D_ROW  = ((c_mid + DW_LANES - 1)/DW_LANES) * w_in;
            P_ROW  = (W_OUT/PIX) * ((c_out + (1<<pack_p) - 1) / (1<<pack_p))
                                 * ((c_mid + LANES - 1) / LANES);
            LD_ROW = (c_in  * w_in  + 15) / 16;
            ST_ROW = (c_out * W_OUT + 15) / 16;

            rst = 1; @(negedge clk); @(negedge clk); rst = 0;
            n_uop = 0; n_e = 0; n_p = 0; pend = 0;
            max_in_occ = 0; max_t1_occ = 0; max_dw_occ = 0; max_ou_occ = 0;
            @(negedge clk); start = 1; @(negedge clk); start = 0;

            guard = 0;
            while (!seq_done && guard < 8000000) begin @(negedge clk); guard = guard + 1; end

            if (guard >= 8000000) begin
                errors = errors + 1;
                $display("  blk %2d: DID NOT FINISH -- e_row %0d p_row %0d, %0d instructions",
                         b, e_row, p_row, n_uop);
            end else begin
                // (c) one instruction per granted row, and the counts are the geometry
                if (n_e != H_MID) begin
                    errors = errors + 1;
                    $display("  blk %2d: %0d expand rows, geometry says %0d", b, n_e, H_MID);
                end
                if (n_p != H_OUT) begin
                    errors = errors + 1;
                    $display("  blk %2d: %0d project rows, geometry says %0d", b, n_p, H_OUT);
                end
                if (n_uop != n_e + n_p) begin
                    errors = errors + 1;
                    $display("  blk %2d: %0d instructions for %0d rows", b, n_uop, n_e + n_p);
                end
                occ_chk("in", max_in_occ, D_IN);
                occ_chk("t1", max_t1_occ, D_T1);
                occ_chk("dw", max_dw_occ, D_DW);
                occ_chk("out", max_ou_occ, D_OUT);
                $display("  blk %2d  %4d expand + %4d project = %5d instructions, %8d cycles   peak rings  in %0d/%0d  t1 %0d/%0d  dw %0d/%0d  out %0d/%0d",
                         b, n_e, n_p, n_uop, guard,
                         max_in_occ, D_IN, max_t1_occ, D_T1,
                         max_dw_occ, D_DW, max_ou_occ, D_OUT);
            end
            tot_uop = tot_uop + n_uop; tot_e = tot_e + n_e; tot_p = tot_p + n_p;
        end

        // Instructions issued during a scatter flush are errors.
        if (fire_in_flush != 0) begin
            errors = errors + fire_in_flush;
            $display("  %0d instructions issued while the scatter was still draining -- the finished row's destination can change under its own flush", fire_in_flush);
        end else
            $display("  no instruction issued during a flush: a row's destination cannot change under it");

        $display("=== tb_uop_issue: %0d blocks, %0d instructions (%0d expand, %0d project), %0d issue errors, %0d ring overruns, %s ===",
                 NCASE, tot_uop, tot_e, tot_p, errors, occ_err,
                 (errors == 0 && occ_err == 0 && tot_uop > 0) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
`default_nettype wire
