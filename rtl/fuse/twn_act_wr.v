// ============================================================================
//  twn_act_wr.v -- activation write master: writes one tensor row to DDR.
//
//  The counterpart of twn_act_rd. A request (start) names a slot and a row;
//  the module reads that row's words from the output row buffer and writes
//  them through twn_axi_wr as 128-bit beats to
//      byte address = act_base + (slot << SLOT_LOG2) + row * row_bytes
//  (no special slot code here; unlike twn_act_rd there is no in_ptr).
//
//  Protocol: pulse start while busy is low; done pulses when the burst master
//  reports completion. Each ROW_BITS word from the buffer is split into BPW
//  128-bit beats. row_bytes must be a multiple of ROW_BITS/8: the word count
//  rounds down while the beat count rounds up, so otherwise the burst master
//  would wait for beats that are never supplied.
//
//  The row buffer's read port has no valid/ready: rb_re plus rb_word is a
//  request and rb_data is valid one cycle after rb_re. A single word of
//  storage (hold) absorbs the answer while the write master may be stalled,
//  and only one request is outstanding at a time.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_act_wr #(
    parameter integer ADDR_W    = 40,
    parameter integer ROW_BITS  = 128,           // the output row buffer's word
    parameter integer SLOT_LOG2 = 18             // slot stride = 1 << SLOT_LOG2 bytes
)(
    input  wire clk,
    input  wire rstn,

    // ---- one row request ----
    input  wire              start,
    input  wire [ADDR_W-1:0] act_base,
    input  wire [3:0]        slot,
    input  wire [8:0]        row,
    input  wire [15:0]       row_bytes,
    output reg               busy,
    output reg               done,

    // ---- from the output row buffer's read port ----
    output reg  [15:0]          rb_word,         // word index within the row
    output reg                  rb_re,
    input  wire [ROW_BITS-1:0]  rb_data,         // valid one cycle after rb_re

    // ---- AXI4 write ----
    output wire [ADDR_W-1:0]   awaddr,
    output wire [7:0]          awlen,
    output wire [2:0]          awsize,
    output wire [1:0]          awburst,
    output wire [3:0]          awcache,
    output wire [2:0]          awprot,
    output wire                awvalid,
    input  wire                awready,
    output wire [127:0]        wdata,
    output wire [15:0]         wstrb,
    output wire                wlast,
    output wire                wvalid,
    input  wire                wready,
    input  wire [1:0]          bresp,
    input  wire                bvalid,
    output wire                bready
);
    localparam integer BPW = ROW_BITS / 128;     // beats per row-buffer word

    reg               wr_start;
    reg [ADDR_W-1:0]  wr_base;
    reg [23:0]        wr_nbeats;
    wire              wr_done;

    // ---- the stream into the burst master, with one word held ----
    reg          w_valid;
    reg [127:0]  w_data;
    wire         w_ready;
    reg  [ROW_BITS-1:0] hold;                    // the word read from the buffer
    reg                 hold_full;
    reg  [3:0]          hb;                      // next beat of `hold` to send
    reg                 rb_re_d;                 // rb_re delayed: rb_data is valid

    twn_axi_wr #(.ADDR_W(ADDR_W), .DATA_W(128)) WR (
        .clk(clk), .rstn(rstn),
        .start(wr_start), .base(wr_base), .nbeats(wr_nbeats),
        .busy(), .done(wr_done),
        .w_valid(w_valid), .w_ready(w_ready), .w_data(w_data),
        .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awcache(awcache), .awprot(awprot), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready));

    // ---- address generation ----
    wire [24:0]       row_off  = row * row_bytes;
    wire [ADDR_W-1:0] slot_off = {{(ADDR_W-4){1'b0}}, slot} << SLOT_LOG2;

    reg [15:0] rq, n_words;                      // next word to request; words per row
    reg        run, pend;                        // pend: a read is in flight

    always @(posedge clk) begin
        if (!rstn) begin
            busy <= 1'b0; done <= 1'b0; run <= 1'b0; wr_start <= 1'b0;
            w_valid <= 1'b0; rb_re <= 1'b0; rb_re_d <= 1'b0;
            hold_full <= 1'b0; pend <= 1'b0; hb <= 4'd0; rb_word <= 16'd0;
        end else begin
            done <= 1'b0; wr_start <= 1'b0; rb_re <= 1'b0;
            rb_re_d <= rb_re;

            if (!busy && start) begin
                wr_base   <= act_base + slot_off + {{(ADDR_W-25){1'b0}}, row_off};
                wr_nbeats <= ({8'd0, row_bytes} + 24'd15) >> 4;
                wr_start  <= 1'b1; busy <= 1'b1; run <= 1'b1;
                rb_word   <= 16'd0; hb <= 4'd0; rq <= 16'd0;
                n_words   <= (({8'd0, row_bytes} + 24'd15) >> 4) / BPW;
                w_valid   <= 1'b0; hold_full <= 1'b0; pend <= 1'b0;
            end

            if (run) begin
                // rb_data is valid in the cycle rb_re_d is high (rb_re is a
                // register and the buffer's read is registered); capture it then.
                if (rb_re_d) begin
                    hold <= rb_data; hold_full <= 1'b1; hb <= 4'd0; pend <= 1'b0;
                end

                if (w_valid && w_ready) w_valid <= 1'b0;

                // Send the next 128-bit beat of the held word.
                if ((!w_valid || w_ready) && hold_full) begin
                    w_data  <= hold[hb*128 +: 128];
                    w_valid <= 1'b1;
                    if (hb == BPW[3:0] - 4'd1) begin
                        hold_full <= 1'b0; hb <= 4'd0;
                    end else begin
                        hb <= hb + 4'd1;
                    end
                end

                // Request the next word only when there is room for the answer.
                // rb_word and rb_re are set together, so the buffer sees `rq`
                // (the pre-increment value).
                if (!pend && !hold_full && !rb_re_d && (rq != n_words)) begin
                    rb_re   <= 1'b1;
                    rb_word <= rq;
                    rq      <= rq + 16'd1;
                    pend    <= 1'b1;
                end
            end

            if (run && wr_done) begin
                run <= 1'b0; busy <= 1'b0; done <= 1'b1; w_valid <= 1'b0;
            end
        end
    end

endmodule
`default_nettype wire
