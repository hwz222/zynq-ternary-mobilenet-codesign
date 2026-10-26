// ============================================================================
//  tb_ddr_model.v -- AXI4 slave memory model standing in for DDR (AR/R and
//  AW/W/B channels, INCR bursts of DATA_W-bit beats, one burst at a time).
//
//  Parameters: BASE / DEPTH place a DEPTH-word window at an absolute address, so
//  testbenches can use the real descriptor addresses. STALL and RLAT default
//  from `BFM_STALL / `BFM_RLAT (xvlog -d BFM_RLAT=40 -d BFM_STALL=3 overrides):
//  STALL is pseudo-random backpressure on R and W, RLAT the cycles from AR
//  accepted to the first R beat (0..7 cycles of jitter are added).
//  Checks (counted in n_err, first MAXMSG printed): arburst/awburst INCR,
//  size equals the beat width, no burst across a 4 KB boundary, access inside
//  the window, wlast exactly on the awlen-th beat. wstrb is honoured per byte.
//  n_ar, n_aw, n_rbeat, n_wbeat are readable; `report` prints one summary line.
//
//  rvalid is raised only after arready has fallen, so the first beat cannot
//  arrive while twn_axi_rd (rready = DATA state && s_ready) is still in ADDR.
//  Limit: one outstanding transaction per channel is assumed (twn_axi_rd and
//  twn_axi_wr issue one at a time); a second outstanding one is not detected.
// ============================================================================
`timescale 1ns/1ps
`ifndef BFM_STALL
`define BFM_STALL 0
`endif
`ifndef BFM_RLAT
`define BFM_RLAT 0
`endif
`default_nettype none
module tb_ddr_model #(
    parameter ADDR_W = 40,
    parameter DATA_W = 128,
    parameter [ADDR_W-1:0] BASE = {ADDR_W{1'b0}},
    parameter DEPTH  = 4096,                 // words of DATA_W bits
    parameter STALL  = `BFM_STALL,
    parameter RLAT   = `BFM_RLAT,
    parameter [8*8-1:0] NAME = "ddr",
    parameter MAXMSG = 12                    // stop printing after this many
)(
    input  wire clk, rstn,
    // AR / R
    input  wire [ADDR_W-1:0] araddr, input wire [7:0] arlen, input wire [2:0] arsize,
    input  wire [1:0] arburst, input wire arvalid, output wire arready,
    output wire [DATA_W-1:0] rdata, output wire [1:0] rresp, output wire rlast,
    output wire rvalid, input wire rready,
    // AW / W / B
    input  wire [ADDR_W-1:0] awaddr, input wire [7:0] awlen, input wire [2:0] awsize,
    input  wire [1:0] awburst, input wire awvalid, output wire awready,
    input  wire [DATA_W-1:0] wdata, input wire [DATA_W/8-1:0] wstrb, input wire wlast,
    input  wire wvalid, output wire wready,
    output wire [1:0] bresp, output wire bvalid, input wire bready
);
    localparam SZ = (DATA_W==128)?4:(DATA_W==64)?3:2;
    localparam integer NB = DATA_W/8;
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ---- the window, in 64 bits so the arithmetic cannot wrap in 40 ----
    localparam [63:0] BASE64  = {{(64-ADDR_W){1'b0}}, BASE};
    localparam [63:0] LIMIT64 = BASE64 + 64'd16 * DEPTH;

    integer n_ar = 0, n_aw = 0, n_rbeat = 0, n_wbeat = 0, n_err = 0, n_msg = 0;

    task oops;
        input [8*40-1:0] what;
        input [63:0]     detail;
        begin
            n_err = n_err + 1;
            if (n_msg < MAXMSG) begin
                n_msg = n_msg + 1;
                $display("  [%0s] AXI ERROR: %0s (0x%0h) at %0t", NAME, what, detail, $time);
            end
        end
    endtask

    function [63:0] addr64;
        input [ADDR_W-1:0] a;
        begin addr64 = {{(64-ADDR_W){1'b0}}, a}; end
    endfunction

    // [a, a + (len+1)*16) must sit inside the window
    function region_bad;
        input [ADDR_W-1:0] a;
        input [7:0]        len;
        reg [63:0] lo, hi;
        begin
            lo = addr64(a);
            hi = lo + ((({56'd0, len} + 64'd1) << SZ));
            region_bad = (lo < BASE64) || (hi > LIMIT64);
        end
    endfunction

    // AXI: a burst may not cross a 4 KB boundary
    function cross4k;
        input [ADDR_W-1:0] a;
        input [7:0]        len;
        begin
            cross4k = (({4'd0, a[11:0]} + (({8'd0, len} + 16'd1) << SZ)) > 16'd4096);
        end
    endfunction

    function [31:0] widx;                     // word index, or 0 if out of window
        input [ADDR_W-1:0] a;
        reg [63:0] d;
        begin
            d = addr64(a);
            widx = (d < BASE64 || d >= LIMIT64) ? 32'd0 : (d - BASE64) >> SZ;
        end
    endfunction

    // ---- read ----
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
    wire stall_w = (STALL != 0) && (lfsr[2:0] < STALL[2:0]);
    wire stall_r = (STALL != 0) && (lfsr[6:4] < STALL[2:0]);

    localparam R_IDLE=2'd0, R_LAT=2'd1, R_RUN=2'd2;
    reg [1:0] r_st; reg [31:0] r_word; reg [8:0] r_cnt; reg arready_r;
    reg [7:0] r_wait;
    wire [31:0] r_safe = (r_word < DEPTH) ? r_word : 32'd0;
    assign arready = arready_r;
    assign rvalid  = (r_st==R_RUN) && !stall_r;
    assign rlast   = (r_st==R_RUN) && (r_cnt==9'd1);
    assign rdata   = mem[r_safe];
    assign rresp   = 2'b00;
    always @(posedge clk) begin
        if (!rstn) begin r_st<=R_IDLE; arready_r<=0; r_wait<=0; end
        else case (r_st)
            R_IDLE: begin
                if (arvalid && !arready_r) begin
                    arready_r<=1; r_word<=widx(araddr); r_cnt<=arlen+9'd1;
                    n_ar = n_ar + 1;
                    if (arburst !== 2'b01)      oops("arburst is not INCR",      {62'd0, arburst});
                    if (arsize  !== SZ[2:0])    oops("arsize is not 16 bytes",   {61'd0, arsize});
                    if (region_bad(araddr, arlen)) oops("AR outside the window", addr64(araddr));
                    if (cross4k(araddr, arlen)) oops("AR burst crosses 4 KB",    addr64(araddr));
                end
                else if (arready_r) begin
                    arready_r<=0;
                    r_wait <= (RLAT == 0) ? 8'd0 : (RLAT[7:0] + {5'b0, lfsr[9:7]});
                    r_st <= (RLAT == 0) ? R_RUN : R_LAT;
                end
            end
            R_LAT: if (r_wait == 8'd0) r_st <= R_RUN; else r_wait <= r_wait - 8'd1;
            R_RUN: if (rvalid && rready) begin
                n_rbeat = n_rbeat + 1;
                if (r_cnt==9'd1) r_st<=R_IDLE;
                else begin r_word<=r_word+1'b1; r_cnt<=r_cnt-9'd1; end
            end
        endcase
    end

    // ---- write ----
    localparam W_IDLE=2'd0, W_RUN=2'd1, W_RESP=2'd2;
    reg [1:0] w_st; reg [31:0] w_word; reg awready_r, wready_r, bvalid_r;
    reg [7:0] awlen_q; reg [8:0] w_beat;
    wire [31:0] w_safe = (w_word < DEPTH) ? w_word : 32'd0;
    assign awready = awready_r;
    assign wready  = wready_r && !stall_w;
    assign bvalid  = bvalid_r;
    assign bresp   = 2'b00;
    integer bj;
    always @(posedge clk) begin
        if (!rstn) begin w_st<=W_IDLE; awready_r<=0; wready_r<=0; bvalid_r<=0; w_beat<=0; end
        else case (w_st)
            W_IDLE: begin bvalid_r<=0;
                if (awvalid && !awready_r) begin
                    awready_r<=1; w_word<=widx(awaddr); awlen_q<=awlen; w_beat<=9'd0;
                    n_aw = n_aw + 1;
                    if (awburst !== 2'b01)      oops("awburst is not INCR",      {62'd0, awburst});
                    if (awsize  !== SZ[2:0])    oops("awsize is not 16 bytes",   {61'd0, awsize});
                    if (region_bad(awaddr, awlen)) oops("AW outside the window", addr64(awaddr));
                    if (cross4k(awaddr, awlen)) oops("AW burst crosses 4 KB",    addr64(awaddr));
                end
                else if (awready_r) begin awready_r<=0; wready_r<=1; w_st<=W_RUN; end
            end
            W_RUN: if (wvalid && wready_r && !stall_w) begin
                n_wbeat = n_wbeat + 1;
                // wlast must land on the awlen-th beat and on no other. Both
                // directions: an early wlast truncates the burst, a late one
                // runs past it, and the memory contents look plausible either
                // way because the bytes that DID arrive are correct.
                if (wlast !== (w_beat == {1'b0, awlen_q}))
                    oops("wlast is not on the awlen-th beat", {55'd0, w_beat});
                for (bj = 0; bj < NB; bj = bj + 1)
                    if (wstrb[bj]) mem[w_safe][bj*8 +: 8] <= wdata[bj*8 +: 8];
                w_word<=w_word+1'b1; w_beat<=w_beat+9'd1;
                if (wlast) begin wready_r<=0; bvalid_r<=1; w_st<=W_RESP; end
            end
            W_RESP: if (bvalid_r && bready) begin bvalid_r<=0; w_st<=W_IDLE; end
        endcase
    end

    task report;                              // one line, for the testbench's log
        begin
            $display("  [%0s] window 0x%0h + %0d words:  %0d AR, %0d R beats, %0d AW, %0d W beats, %0d protocol/region errors",
                     NAME, BASE64, DEPTH, n_ar, n_rbeat, n_aw, n_wbeat, n_err);
        end
    endtask
endmodule
`default_nettype wire
