// ============================================================================
//  twn_act_rd.v -- activation read master: fetches one tensor row from DDR.
//
//  A request (start) names a buffer slot and a row. The module computes
//      byte address = act_base + (slot << SLOT_LOG2) + row * row_bytes
//  (slot 4'hF means "the network input": the base is in_ptr and there is no
//  slot offset), reads ceil(row_bytes/16) 128-bit beats through twn_axi_rd, packs
//  every BPW beats into one ROW_BITS-wide word and writes the words to the row
//  buffer, one wr_en pulse per word. wr_row_last marks the last word of the row.
//
//  Protocol: pulse start while busy is low; done pulses once the burst master
//  reports completion. This module does not decide which row to fetch or when.
//  row_bytes is supplied by the caller rather than computed from channels and
//  width. It should be a multiple of ROW_BITS/8, otherwise a final partial word
//  is never written.
//
//  Back-pressure: wr_can is a promise from the sink (twn_ring_warb's a_can) that
//  a word presented in the next cycle will be accepted. wr_en is registered, so
//  the beat that completes a word (the last of its BPW) is accepted from the
//  AXI R channel only while wr_can is high; until then rready stays low and AXI
//  holds the beat. The other beats only fill the partial word and are always
//  accepted.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_act_rd #(
    parameter integer ADDR_W    = 40,
    parameter integer ROW_BITS  = 1024,          // the row buffer's word
    parameter integer SLOT_LOG2 = 18             // slot stride = 1 << SLOT_LOG2 bytes
)(
    input  wire clk,
    input  wire rstn,

    // ---- one row request ----
    input  wire              start,
    input  wire [ADDR_W-1:0] act_base,
    input  wire [3:0]        slot,               // 4'hF: read from in_ptr instead
    input  wire [ADDR_W-1:0] in_ptr,             // base address of the network input
    input  wire [8:0]        row,
    input  wire [15:0]       row_bytes,          // bytes in one row
    output reg               busy,
    output reg               done,

    // ---- AXI4 read ----
    output wire [ADDR_W-1:0] araddr,
    output wire [7:0]        arlen,
    output wire [2:0]        arsize,
    output wire [1:0]        arburst,
    output wire [3:0]        arcache,
    output wire [2:0]        arprot,
    output wire              arvalid,
    input  wire              arready,
    input  wire [127:0]      rdata,
    input  wire [1:0]        rresp,
    input  wire              rlast,
    input  wire              rvalid,
    output wire              rready,

    // ---- into the row buffer ----
    // Tie wr_can high only for a sink that can never refuse a word.
    input  wire                 wr_can,
    output reg                  wr_en,
    output reg  [ROW_BITS-1:0]  wr_data,
    output reg                  wr_row_last,

    // ---- the accepted AXI beats, unpacked ----
    // beat_valid is high in the cycle a beat is accepted (not merely offered), so
    // a consumer sees each 16-byte beat exactly once. twn_res_buf stores the
    // residual row from here.
    output wire                 beat_valid,
    output wire [127:0]         beat_data
);
    localparam integer BPW = ROW_BITS / 128;     // beats per row-buffer word

    reg                rd_start;
    reg  [ADDR_W-1:0]  rd_base;
    reg  [23:0]        rd_nbeats;
    wire               rd_done, s_valid;
    wire [127:0]       s_data;

    // ---- beat acceptance ----
    // s_ready is combinational from registers (bi, wr_can) only; twn_axi_rd's
    // s_valid does not depend on s_ready, so there is no combinational loop.
    reg  [3:0] bi;                               // beat index within the word
    wire word_end = (bi == BPW[3:0] - 4'd1);
    // ACTRD_NEG_NO_BP is a negative-test build: always ready, so words are lost
    // when the sink refuses.
`ifdef ACTRD_NEG_NO_BP
    wire s_ready  = 1'b1;
`else
    wire s_ready  = !word_end || wr_can;
`endif

    twn_axi_rd #(.ADDR_W(ADDR_W), .DATA_W(128)) RD (
        .clk(clk), .rstn(rstn),
        .start(rd_start), .base(rd_base), .nbeats(rd_nbeats),
        .busy(), .done(rd_done),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));

    // ---- address generation ----
    // row (9 bit) * row_bytes (16 bit) = 25 bit; computed once per request.
    wire [24:0] row_off = row * row_bytes;
    wire [ADDR_W-1:0] slot_off = (slot == 4'hF) ? {ADDR_W{1'b0}}
                                                : ({{(ADDR_W-4){1'b0}}, slot} << SLOT_LOG2);
    wire [ADDR_W-1:0] tensor   = (slot == 4'hF) ? in_ptr : (act_base + slot_off);

    reg [ROW_BITS-1:0] sh;                       // partial word being assembled
    reg [23:0]         left;                     // words still to be emitted
    reg                run;

    // An offered beat (run && s_valid) stays on the R channel and is offered
    // again if not accepted; every consumer must use the accepted beat.
    wire beat_acc = run && s_valid && s_ready;

    assign beat_valid = beat_acc;
    assign beat_data  = s_data;

    // sh with the incoming beat inserted at slot bi
    reg [ROW_BITS-1:0] shn;
    always @* begin
        shn = sh;
        shn[{bi, 7'd0} +: 128] = s_data;         // bi*128
    end

    always @(posedge clk) begin
        if (!rstn) begin
            busy <= 1'b0; done <= 1'b0; run <= 1'b0; rd_start <= 1'b0;
            wr_en <= 1'b0; wr_row_last <= 1'b0; bi <= 4'd0;
        end else begin
            done <= 1'b0; rd_start <= 1'b0; wr_en <= 1'b0; wr_row_last <= 1'b0;

            if (!busy && start) begin
                rd_base   <= tensor + {{(ADDR_W-25){1'b0}}, row_off};
                // Round up to whole 16-byte beats.
                rd_nbeats <= ({8'd0, row_bytes} + 24'd15) >> 4;
                left      <= (({8'd0, row_bytes} + 24'd15) >> 4) / BPW;
                rd_start  <= 1'b1; busy <= 1'b1; run <= 1'b1; bi <= 4'd0;
            end

            if (beat_acc) begin
                sh <= shn;
                if (word_end) begin
                    bi          <= 4'd0;
                    wr_en       <= 1'b1;
                    wr_data     <= shn;
                    left        <= left - 24'd1;
                    wr_row_last <= (left == 24'd1);
                end else begin
                    bi <= bi + 4'd1;
                end
            end

            if (run && rd_done) begin
                run <= 1'b0; busy <= 1'b0; done <= 1'b1;
            end
        end
    end

endmodule
`default_nettype wire
