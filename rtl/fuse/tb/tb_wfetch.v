// tb_wfetch.v -- twn_wfetch (with the twn_axi_rd burst master inside it) against the packed weight file.
//
// Modelled: an AXI read slave serving tb_wfetch_ddr.hex (gaps from an LFSR) and the
//   capture of twn_wmem's write ports. Inputs tb_wfetch_ddr.hex and tb_wfetch_desc.vh
//   (17 descriptors) are written by gen_wfetch_tb.py in this directory; run from here.
// Checks, for every block: each word written to the ternary, depthwise, requant-A and
//   requant-D memories equals the word at the descriptor's file offset in the same DDR
//   image, at the on-chip address mb_* + index, in order; the word counts equal n_*.
//   Packing against the goldens is not re-checked here.
// Every accepted AR is checked: INCR, 16-byte beats, 16-byte aligned, at most 256 beats,
//   no 4 KB crossing, stable while waiting for arready. Not covered: twn_wmem itself
//   and double buffering (blocks are fetched one after another).
// ifdef arms: WFETCH_TB_NEG_BASE16 gives the fetcher a DDR base one beat off, so only
//   the data compare can fail; AXIRD_NEG_NO_4K (in rtl/src/twn_axi_rd.v) removes the 4 KB
//   split, so only the AR check fails. 40 ms timeout.
`timescale 1ns/1ps
`default_nettype none

module tb_wfetch;
    localparam integer ADDR_W = 40;
    `include "tb_wfetch_desc.vh"

    reg clk = 1'b0, rstn = 1'b0;
    always #2 clk = ~clk;

    // ---- the DDR image ----
    reg [127:0] ddr [0:NBEAT-1];
    initial begin
        $readmemh("tb_wfetch_ddr.hex", ddr);
        // with the file missing every compare is X !== X, which is false
        if (^ddr[0] === 1'bx || ^ddr[NBEAT-1] === 1'bx) begin
            $display("=== tb_wfetch: FAIL -- tb_wfetch_ddr.hex did not load ===");
            $finish;
        end
    end

    // ---- the fetcher ----
    reg          start = 1'b0;
    reg  [31:0]  off_tern, off_dw, off_rqa, off_rqd;
    reg  [15:0]  n_tern, n_dw, n_rqa, n_rqd;
    reg  [13:0]  mb_tern;
    reg  [9:0]   mb_dw;
    reg  [12:0]  mb_rqa, mb_rqd;
    wire         busy, done;

    wire [ADDR_W-1:0] araddr;  wire [7:0] arlen;  wire [2:0] arsize;
    wire [1:0] arburst;  wire [3:0] arcache;  wire [2:0] arprot;
    wire arvalid;  reg arready;
    reg  [127:0] rdata;  reg rlast, rvalid;  wire rready;

    wire         wr_tern_en, wr_dw_en, wr_rqa_en, wr_rqd_en;
    wire [13:0]  wr_tern_addr;
    wire [9:0]   wr_dw_addr;
    wire [12:0]  wr_rqa_addr, wr_rqd_addr;
    wire [255:0] wr_tern_data, wr_rqa_data;
    wire [575:0] wr_dw_data;
    wire [447:0] wr_rqd_data;

    // WFETCH_TB_NEG_BASE16 (testbench only): DDR base one beat off, so every
    // word comes from the wrong file bytes while addresses and counts stay right.
`ifdef WFETCH_TB_NEG_BASE16
    wire [ADDR_W-1:0] w_base_tb = 40'd16;
`else
    wire [ADDR_W-1:0] w_base_tb = {ADDR_W{1'b0}};
`endif
    twn_wfetch #(.ADDR_W(ADDR_W)) DUT (
        .clk(clk), .rstn(rstn), .start(start), .w_base(w_base_tb),
        .off_tern(off_tern), .off_dw(off_dw), .off_rqa(off_rqa), .off_rqd(off_rqd),
        .n_tern(n_tern), .n_dw(n_dw), .n_rqa(n_rqa), .n_rqd(n_rqd),
        .mb_tern(mb_tern), .mb_dw(mb_dw), .mb_rqa(mb_rqa), .mb_rqd(mb_rqd),
        .busy(busy), .done(done),
        .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(2'b00), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .wr_tern_en(wr_tern_en), .wr_tern_addr(wr_tern_addr), .wr_tern_data(wr_tern_data),
        .wr_dw_en(wr_dw_en),     .wr_dw_addr(wr_dw_addr),     .wr_dw_data(wr_dw_data),
        .wr_rqa_en(wr_rqa_en),   .wr_rqa_addr(wr_rqa_addr),   .wr_rqa_data(wr_rqa_data),
        .wr_rqd_en(wr_rqd_en),   .wr_rqd_addr(wr_rqd_addr),   .wr_rqd_data(wr_rqd_data));

    // ================= the AXI slave =================
    reg [ADDR_W-1:0] s_addr;
    reg [8:0]        s_left;
    reg              s_run = 1'b0;
    reg [15:0]       lfsr  = 16'hACE1;
    reg [31:0]       n_ar  = 0, n_beat = 0, n_stall = 0;
    // ---- AXI4 read-address rules, checked on every accepted AR ----
    integer          axi_err = 0, max_beats = 0, n_split4k = 0;
    reg [ADDR_W-1:0] ar_hold_addr;
    reg [7:0]        ar_hold_len;
    reg              ar_waiting = 1'b0;
    always @(posedge clk) if (rstn) begin
        if (arvalid && arready) begin
            if (arburst !== 2'b01 || arsize !== 3'd4 || araddr[3:0] !== 4'd0) begin
                axi_err = axi_err + 1;
                if (axi_err <= 4)
                    $display("  AXI: AR at %0h burst %0d size %0d -- want INCR, 16-byte beats, aligned",
                             araddr, arburst, arsize);
            end
            if ({1'b0, arlen} + 9'd1 > 9'd256) begin      // cannot happen in 8 bits; stated anyway
                axi_err = axi_err + 1;
                $display("  AXI: AR at %0h is %0d beats, the limit is 256", araddr, arlen + 1);
            end
            // 4 KB: the last byte of the burst must be in the first byte's page
            if ({1'b0, araddr[11:4]} + {1'b0, arlen} > 9'd255) begin
                axi_err = axi_err + 1;
                if (axi_err <= 4)
                    $display("  AXI: AR at %0h, %0d beats, ends at %0h -- it CROSSES a 4 KB boundary",
                             araddr, arlen + 1, araddr + ({32'd0, arlen} + 40'd1) * 16 - 1);
            end
            if ({1'b0, araddr[11:4]} + {1'b0, arlen} == 9'd255 && arlen != 8'd255)
                n_split4k = n_split4k + 1;               // a burst cut short BY the boundary
            if (arlen + 1 > max_beats) max_beats = arlen + 1;
        end
        // AR must not change while it waits for arready
        if (ar_waiting && arvalid && (araddr !== ar_hold_addr || arlen !== ar_hold_len)) begin
            axi_err = axi_err + 1;
            if (axi_err <= 4) $display("  AXI: AR changed while waiting for arready");
        end
        ar_waiting   <= arvalid && !arready;
        ar_hold_addr <= araddr;
        ar_hold_len  <= arlen;
    end

    always @(posedge clk) begin
        if (!rstn) begin
            arready <= 1'b0; rvalid <= 1'b0; rlast <= 1'b0; s_run <= 1'b0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            arready <= !s_run && !arready;              // accept, but not instantly
            if (arvalid && arready) begin
                s_addr <= araddr; s_left <= {1'b0, arlen} + 9'd1;
                s_run <= 1'b1; arready <= 1'b0; n_ar <= n_ar + 1;
            end
            if (s_run && (!rvalid || rready)) begin
                if (lfsr[3:0] == 4'h5) begin            // a gap, on purpose
                    rvalid <= 1'b0; n_stall <= n_stall + 1;
                end else begin
                    rdata  <= ddr[s_addr[ADDR_W-1:4]];
                    rlast  <= (s_left == 9'd1);
                    rvalid <= 1'b1;
                    s_addr <= s_addr + 40'd16;
                    s_left <= s_left - 9'd1;
                    n_beat <= n_beat + 1;
                    if (s_left == 9'd1) s_run <= 1'b0;
                end
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    // ================= the check =================
    // The expected word is read out of the same DDR image, at the offset the
    // descriptor says, with the region's own FILE stride and MEMORY width.
    integer errors = 0, checked = 0;
    reg [639:0] fw;                 // a function result cannot be part-selected
    integer exp_tern, exp_dw, exp_rqa, exp_rqd;      // next word index per region
    reg [31:0] c_off_tern, c_off_dw, c_off_rqa, c_off_rqd;
    reg [7:0]  c_wb_tern, c_wb_dw, c_wb_rqa, c_wb_rqd;
    reg [13:0] c_mb_tern; reg [9:0] c_mb_dw; reg [12:0] c_mb_rqa, c_mb_rqd;
    integer    c_blk;

    function [639:0] fileword;                      // 5 beats from a byte offset
        input [31:0] byteoff;
        integer q;
        begin
            fileword = 640'd0;
            for (q = 0; q < 5; q = q + 1)
                fileword[q*128 +: 128] = ddr[(byteoff >> 4) + q];
        end
    endfunction

    task chk;
        input [255:0] got; input [255:0] want; input [31:0] addr;
        input [8*8-1:0] what;
        begin
            checked = checked + 1;
            if (got !== want) begin
                errors = errors + 1;
                if (errors < 8)
                    $display("  b%0d %0s word at addr %0d differs", c_blk, what, addr);
            end
        end
    endtask

    always @(posedge clk) if (rstn) begin
        if (wr_tern_en) begin
            fw = fileword(c_off_tern + exp_tern * c_wb_tern);
            chk(wr_tern_data, fw[255:0], {18'd0, wr_tern_addr}, "tern");
            if (wr_tern_addr !== c_mb_tern + exp_tern[13:0]) begin
                errors = errors + 1; $display("  b%0d tern address %0d, want %0d",
                    c_blk, wr_tern_addr, c_mb_tern + exp_tern[13:0]); end
            exp_tern = exp_tern + 1;
        end
        if (wr_dw_en) begin
            checked = checked + 1;
            fw = fileword(c_off_dw + exp_dw * c_wb_dw);
            if (wr_dw_data !== fw[575:0]) begin
                errors = errors + 1;
                if (errors < 8) $display("  b%0d dw word at addr %0d differs", c_blk, wr_dw_addr);
            end
            if (wr_dw_addr !== c_mb_dw + exp_dw[9:0]) begin
                errors = errors + 1; $display("  b%0d dw address %0d, want %0d",
                    c_blk, wr_dw_addr, c_mb_dw + exp_dw[9:0]); end
            exp_dw = exp_dw + 1;
        end
        if (wr_rqa_en) begin
            fw = fileword(c_off_rqa + exp_rqa * c_wb_rqa);
            chk(wr_rqa_data, fw[255:0], {19'd0, wr_rqa_addr}, "rqa");
            if (wr_rqa_addr !== c_mb_rqa + exp_rqa[12:0]) begin
                errors = errors + 1; $display("  b%0d rqa address %0d, want %0d",
                    c_blk, wr_rqa_addr, c_mb_rqa + exp_rqa[12:0]); end
            exp_rqa = exp_rqa + 1;
        end
        if (wr_rqd_en) begin
            checked = checked + 1;
            fw = fileword(c_off_rqd + exp_rqd * c_wb_rqd);
            if (wr_rqd_data !== fw[447:0]) begin
                errors = errors + 1;
                if (errors < 8) $display("  b%0d rqd word at addr %0d differs", c_blk, wr_rqd_addr);
            end
            if (wr_rqd_addr !== c_mb_rqd + exp_rqd[12:0]) begin
                errors = errors + 1; $display("  b%0d rqd address %0d, want %0d",
                    c_blk, wr_rqd_addr, c_mb_rqd + exp_rqd[12:0]); end
            exp_rqd = exp_rqd + 1;
        end
    end

    integer b;
    initial begin
        rstn = 1'b0;
        repeat (8) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk);

        for (b = 0; b < NBLK; b = b + 1) begin
            c_blk = b;
            off_tern = OFF_TERN[b*32 +: 32];  off_dw  = OFF_DW [b*32 +: 32];
            off_rqa  = OFF_RQA [b*32 +: 32];  off_rqd = OFF_RQD[b*32 +: 32];
            n_tern   = N_TERN  [b*16 +: 16];  n_dw    = N_DW   [b*16 +: 16];
            n_rqa    = N_RQA   [b*16 +: 16];  n_rqd   = N_RQD  [b*16 +: 16];
            mb_tern  = MB_TERN [b*14 +: 14];  mb_dw   = MB_DW  [b*10 +: 10];
            mb_rqa   = MB_RQA  [b*13 +: 13];  mb_rqd  = MB_RQD [b*13 +: 13];
            c_off_tern = off_tern; c_off_dw = off_dw;
            c_off_rqa  = off_rqa;  c_off_rqd = off_rqd;
            c_mb_tern  = mb_tern;  c_mb_dw  = mb_dw;
            c_mb_rqa   = mb_rqa;   c_mb_rqd = mb_rqd;
            c_wb_tern  = WB_TERN[b*8 +: 8];   c_wb_dw  = WB_DW [b*8 +: 8];
            c_wb_rqa   = WB_RQA [b*8 +: 8];   c_wb_rqd = WB_RQD[b*8 +: 8];
            exp_tern = 0; exp_dw = 0; exp_rqa = 0; exp_rqd = 0;

            @(posedge clk); start = 1'b1; @(posedge clk); start = 1'b0;
            wait (done);
            @(posedge clk);

            // a block that wrote FEWER words than the descriptor asked for looks
            // identical to a pass if only the words that appeared are checked.
            if (exp_tern !== n_tern || exp_dw !== n_dw ||
                exp_rqa !== n_rqa  || exp_rqd !== n_rqd) begin
                errors = errors + 1;
                $display("  b%0d wrote %0d/%0d/%0d/%0d words, descriptor says %0d/%0d/%0d/%0d",
                         b, exp_tern, exp_dw, exp_rqa, exp_rqd,
                         n_tern, n_dw, n_rqa, n_rqd);
            end
        end

        $display("  AXI AR checks: %0d bursts, longest %0d beats, %0d cut short by a 4 KB boundary, %0d violations",
                 n_ar, max_beats, n_split4k, axi_err);
        errors = errors + axi_err;
        $display("=== tb_wfetch: %0d blocks, %0d words checked, %0d errors, %0d AR, %0d beats, %0d stalls, %s ===",
                 NBLK, checked, errors, n_ar, n_beat, n_stall,
                 (errors == 0 && checked > 0 && n_ar > 0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("=== tb_wfetch: TIMEOUT, %0d words checked, %0d errors ===", checked, errors);
        $finish;
    end
endmodule
`default_nettype wire
