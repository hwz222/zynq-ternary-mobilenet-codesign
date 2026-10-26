// ============================================================================
//  tb_res_add.v -- twn_res_add against expected values computed in Python.
//
//  Inputs: tb_res_add_vec.hex and tb_res_add_n.vh, both written by
//  gen_res_add.py in this directory (python rtl/fuse/tb/gen_res_add.py), which
//  computes each expected byte from p0_fused.c's add_requant_row. The vectors
//  cover the block constants from p1_manifest.json, the rounding threshold
//  +-2 for each clamp edge, operand extremes at +-32768 and a deterministic
//  spread. Two DUTs run on the same vectors: LANES=4 (as tb_p4_block drives
//  it) and LANES=16 (as twn_fuse_top instantiates it; each group's four vectors
//  are replicated across the lane quads). The run fails if the hex file does
//  not load. Pass line: "=== tb_res_add: ... ALL PASS ===".
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_res_add;
    localparam integer LANES = 4;
    `include "tb_res_add_n.vh"

    reg clk = 1'b0, rst = 1'b1;
    always #2 clk = ~clk;

    reg [127:0] vec [0:NVEC-1];
    initial begin
        $readmemh("tb_res_add_vec.hex", vec);
        // With the file missing vec stays X and X !== X is false, which would
        // pass vacuously; so the file is checked to have loaded.
        if (^vec[0] === 1'bx || ^vec[NVEC-1] === 1'bx) begin
            $display("=== tb_res_add: FAIL -- tb_res_add_vec.hex did not load ===");
            $finish;
        end
    end

    reg signed [17:0] mp, mq;
    reg [5:0]         sh;
    reg signed [15:0] lo, hi;
    reg               in_valid;
    reg [LANES*16-1:0] p_in, x_in;
    reg [7:0]          in_tag;
    wire               out_valid;
    wire [LANES*8-1:0] out_data;
    wire [7:0]         out_tag;

    twn_res_add #(.LANES(LANES)) DUT (
        .clk(clk), .rst(rst),
        .mp(mp), .mq(mq), .sh(sh), .lo(lo), .hi(hi),
        .in_valid(in_valid), .p_in(p_in), .x_in(x_in), .in_tag(in_tag),
        .out_valid(out_valid), .out_data(out_data), .out_tag(out_tag));

    // ---- the width twn_fuse_top actually instantiates ----
    localparam integer LANESW = 16;
    reg  [LANESW*16-1:0] p_inw, x_inw;
    wire                 out_validw;
    wire [LANESW*8-1:0]  out_dataw;
    wire [7:0]           out_tagw;

    twn_res_add #(.LANES(LANESW)) DUTW (
        .clk(clk), .rst(rst),
        .mp(mp), .mq(mq), .sh(sh), .lo(lo), .hi(hi),
        .in_valid(in_valid), .p_in(p_inw), .x_in(x_inw), .in_tag(in_tag),
        .out_valid(out_validw), .out_data(out_dataw), .out_tag(out_tagw));

    integer errors = 0, checked = 0;
    integer errorsw = 0, checkedw = 0;
    integer g, l, i;
    reg signed [7:0] want, got;
    reg signed [7:0] wantw, gotw;

    // the expected byte of vector v
    function signed [7:0] exp_of; input integer v;
        begin exp_of = vec[v][39:32]; end
    endfunction

    initial begin
        in_valid = 1'b0; p_in = 0; x_in = 0; in_tag = 0;
        mp = 0; mq = 0; sh = 0; lo = 0; hi = 0;
        repeat (8) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        for (g = 0; g < NGRP; g = g + 1) begin
            // the constants are the same for all four lanes of a group because
            // gen_res_add.py pads each block's vectors to a multiple of LANES
            mp = vec[g*LANES][57:40];
            mq = vec[g*LANES][75:58];
            sh = vec[g*LANES][81:76];
            lo = vec[g*LANES][97:82];
            hi = vec[g*LANES][113:98];
            for (l = 0; l < LANES; l = l + 1) begin
                p_in[l*16 +: 16] = vec[g*LANES + l][15:0];
                x_in[l*16 +: 16] = vec[g*LANES + l][31:16];
            end
            // the same four vectors across all sixteen lanes, so every lane of
            // the deployed width carries a real operand and is checked
            for (l = 0; l < LANESW; l = l + 1) begin
                p_inw[l*16 +: 16] = vec[g*LANES + (l % LANES)][15:0];
                x_inw[l*16 +: 16] = vec[g*LANES + (l % LANES)][31:16];
            end
            in_valid = 1'b1;
            // Driven on the negedge to avoid a race with the design's sampling edge.
            @(negedge clk);
            in_valid = 1'b0;
            // The output appears 4 cycles after in_valid; drain fully before the
            // next group so the constants never change under a value in flight.
            repeat (3) @(negedge clk);

            if (!out_valid) begin
                errors = errors + 1;
                if (errors < 6) $display("  group %0d produced no output", g);
            end else begin
                for (l = 0; l < LANES; l = l + 1) begin
                    checked = checked + 1;
                    want = exp_of(g*LANES + l);
                    got  = out_data[l*8 +: 8];
                    if (got !== want) begin
                        errors = errors + 1;
                        if (errors < 8)
                            $display("  vec %0d (p %0d x %0d mp %0d mq %0d sh %0d): got %0d want %0d",
                                     g*LANES + l,
                                     $signed(vec[g*LANES+l][15:0]),
                                     $signed(vec[g*LANES+l][31:16]),
                                     $signed(vec[g*LANES+l][57:40]),
                                     $signed(vec[g*LANES+l][75:58]),
                                     vec[g*LANES+l][81:76], got, want);
                    end
                end
            end

            // ---- the same group through the width that ships ----
            if (!out_validw) begin
                errorsw = errorsw + 1;
                if (errorsw < 6) $display("  group %0d produced no output at LANES=%0d", g, LANESW);
            end else begin
                for (l = 0; l < LANESW; l = l + 1) begin
                    checkedw = checkedw + 1;
                    wantw = exp_of(g*LANES + (l % LANES));
                    gotw  = out_dataw[l*8 +: 8];
                    if (gotw !== wantw) begin
                        errorsw = errorsw + 1;
                        if (errorsw < 8)
                            $display("  LANES=%0d lane %0d, vec %0d: got %0d want %0d",
                                     LANESW, l, g*LANES + (l % LANES), gotw, wantw);
                    end
                end
            end
        end

        $display("=== tb_res_add: %0d values checked, %0d errors (LANES=%0d, as tb_p4_block drives it) ===",
                 checked, errors, LANES);
        $display("=== tb_res_add: %0d values checked, %0d errors (LANES=%0d, as twn_fuse_top instantiates it) ===",
                 checkedw, errorsw, LANESW);
        $display("=== tb_res_add: %0d values checked, %0d errors, %s ===",
                 checked + checkedw, errors + errorsw,
                 ((errors + errorsw) == 0 && checked > 0 && checkedw > 0)
                     ? "ALL PASS" : "FAIL");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("=== tb_res_add: TIMEOUT after %0d values, %0d errors ===",
                 checked + checkedw, errors + errorsw);
        $finish;
    end
endmodule
`default_nettype wire
