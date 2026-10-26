// ============================================================================
//  twn_wfetch.v -- weight prefetcher: copies one block's weights from DDR into
//  twn_wmem.
//
//  A block has four contiguous regions in the weight file, fetched in this
//  order: ternary weights (R_TERN), depthwise taps (R_DW), the ternary array's
//  requant groups (R_RQA) and the depthwise engine's requant groups (R_RQD).
//  Each region is read with one AXI burst request (twn_axi_rd splits it as
//  needed), cut into words of the destination memory's width, and written to
//  consecutive addresses starting at that region's on-chip base (mb_*).
//  The file is already in the memory's word layout, so no reordering is done
//  here; every word occupies a whole number of 128-bit beats (see BPW_*).
//
//  Protocol: pulse `start` while idle with the region descriptors stable;
//  `busy` is high until `done` pulses for one cycle after the last region.
//  A region with a word count of zero is skipped. The caller may fetch the next
//  block while the current one computes, because the on-chip bases decide where
//  the words land.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_wfetch #(
    parameter integer ADDR_W = 40,
    parameter integer RQ_W   = 256     // width of one array requant word, bits
)(
    input  wire clk,
    input  wire rstn,

    // ---- one block's four regions, from twn_desctab ----
    input  wire              start,
    input  wire [ADDR_W-1:0] w_base,       // the weight file's base in DDR
    input  wire [31:0]       off_tern,     // byte offsets within the file
    input  wire [31:0]       off_dw,
    input  wire [31:0]       off_rqa,
    input  wire [31:0]       off_rqd,
    input  wire [15:0]       n_tern,       // words, in each memory's own width
    input  wire [15:0]       n_dw,
    input  wire [15:0]       n_rqa,
    input  wire [15:0]       n_rqd,
    input  wire [13:0]       mb_tern,      // first on-chip word address per memory
    input  wire [9:0]        mb_dw,
    input  wire [12:0]       mb_rqa,
    input  wire [12:0]       mb_rqd,
    output reg               busy,
    output reg               done,         // 1-cycle pulse

    // ---- AXI4 read master (driven by twn_axi_rd) ----
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

    // ---- write ports into twn_wmem, one per memory (enable is a 1-cycle pulse) ----
    output reg               wr_tern_en,
    output reg  [13:0]       wr_tern_addr,
    output reg  [255:0]      wr_tern_data,
    output reg               wr_dw_en,
    output reg  [9:0]        wr_dw_addr,
    output reg  [575:0]      wr_dw_data,
    output reg               wr_rqa_en,
    output reg  [12:0]       wr_rqa_addr,
    output reg  [RQ_W-1:0]   wr_rqa_data,
    output reg               wr_rqd_en,
    output reg  [12:0]       wr_rqd_addr,
    output reg  [447:0]      wr_rqd_data
);
    // BPW_* is the number of 128-bit AXI beats per on-chip word of each region.
    // File words are the memory widths rounded up to whole beats: ternary 256 bit
    // = 2 beats, depthwise 576 bit stored as 640 = 5 beats, array requant RQ_W/128
    // beats, depthwise requant 448 bit stored as 512 = 4 beats. The shift
    // register below is 640 bits, so words of up to 5 beats fit.
    localparam [2:0] BPW_TERN = 3'd2, BPW_DW = 3'd5,
                     BPW_RQA = (RQ_W / 128) & 3'd7, BPW_RQD = 3'd4;

    localparam [1:0] R_TERN = 2'd0, R_DW = 2'd1, R_RQA = 2'd2, R_RQD = 2'd3;
    localparam [1:0] S_IDLE = 2'd0, S_ISSUE = 2'd1, S_RUN = 2'd2, S_NEXT = 2'd3;

    reg [1:0] state, reg_i;     // reg_i: the region being fetched

    // ---- the burst master ----
    reg                rd_start;
    reg  [ADDR_W-1:0]  rd_base;
    reg  [23:0]        rd_nbeats;
    wire               rd_busy, rd_done, s_valid;
    wire [127:0]       s_data;

    // s_ready is tied high: every beat is consumed in the cycle it is valid.
    twn_axi_rd #(.ADDR_W(ADDR_W), .DATA_W(128)) RD (
        .clk(clk), .rstn(rstn),
        .start(rd_start), .base(rd_base), .nbeats(rd_nbeats),
        .busy(rd_busy), .done(rd_done),
        .s_valid(s_valid), .s_ready(1'b1), .s_data(s_data),
        .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready));

    // ---- per-region selects (offset, word count, beats per word, on-chip base) ----
    reg [31:0] sel_off;  reg [15:0] sel_n;  reg [2:0] sel_bpw;  reg [13:0] sel_mb;
    always @* begin
        case (reg_i)
            R_TERN: begin sel_off = off_tern; sel_n = n_tern; sel_bpw = BPW_TERN;
                          sel_mb = mb_tern; end
            R_DW:   begin sel_off = off_dw;   sel_n = n_dw;   sel_bpw = BPW_DW;
                          sel_mb = {4'd0, mb_dw}; end
            R_RQA:  begin sel_off = off_rqa;  sel_n = n_rqa;  sel_bpw = BPW_RQA;
                          sel_mb = {1'b0, mb_rqa}; end
            default:begin sel_off = off_rqd;  sel_n = n_rqd;  sel_bpw = BPW_RQD;
                          sel_mb = {1'b0, mb_rqd}; end
        endcase
    end

    // nbeats = words x beats per word, by shift/add: x2, x4, or (default) x5 = 4w + w.
    wire [23:0] w24 = {8'd0, sel_n};
    reg  [23:0] nbeats_c;
    always @* begin
        case (sel_bpw)
            3'd2:    nbeats_c = w24 << 1;
            3'd4:    nbeats_c = w24 << 2;
            default: nbeats_c = (w24 << 2) + w24;   // 5
        endcase
    end

    // ---- beat assembler ----
    // sh collects beats of the current word, bi is the beat index. The word is
    // complete on the beat with index bpw-1, which is not in `sh` yet, so the
    // write uses `shn` (sh with the current beat merged in), not `sh`.
    reg  [639:0] sh;
    reg  [2:0]   bi;
    reg  [13:0]  wa;            // next on-chip word address of the current region
    reg  [639:0] shn;
    always @* begin
        shn = sh;
        shn[{bi, 7'd0} +: 128] = s_data;        // bi*128
    end
    wire beat = s_valid;
    wire last = beat && (bi == sel_bpw - 3'd1);

    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; reg_i <= R_TERN; busy <= 1'b0; done <= 1'b0;
            rd_start <= 1'b0; bi <= 3'd0; wa <= 14'd0;
            wr_tern_en <= 1'b0; wr_dw_en <= 1'b0; wr_rqa_en <= 1'b0; wr_rqd_en <= 1'b0;
        end else begin
            done       <= 1'b0;
            rd_start   <= 1'b0;
            wr_tern_en <= 1'b0; wr_dw_en <= 1'b0; wr_rqa_en <= 1'b0; wr_rqd_en <= 1'b0;

            case (state)
                S_IDLE: if (start) begin
                    reg_i <= R_TERN; busy <= 1'b1; state <= S_ISSUE;
                end

                // start one burst for region reg_i
                S_ISSUE: begin
                    bi <= 3'd0;
                    wa <= sel_mb;
                    if (sel_n == 16'd0) begin
                        state <= S_NEXT;            // an empty region is legal
                    end else begin
                        rd_base   <= w_base + {{(ADDR_W-32){1'b0}}, sel_off};
                        rd_nbeats <= nbeats_c;
                        rd_start  <= 1'b1;
                        state     <= S_RUN;
                    end
                end

                // assemble beats into words and write each finished word
                S_RUN: begin
                    if (beat) begin
                        sh <= shn;
                        if (last) begin
                            bi <= 3'd0;
                            wa <= wa + 14'd1;
                            case (reg_i)
                                R_TERN: begin wr_tern_en <= 1'b1; wr_tern_addr <= wa;
                                              wr_tern_data <= shn[255:0]; end
                                R_DW:   begin wr_dw_en <= 1'b1;   wr_dw_addr <= wa[9:0];
                                              wr_dw_data <= shn[575:0]; end
                                R_RQA:  begin wr_rqa_en <= 1'b1;  wr_rqa_addr <= wa[12:0];
                                              wr_rqa_data <= shn[255:0]; end
                                default:begin wr_rqd_en <= 1'b1;  wr_rqd_addr <= wa[12:0];
                                              wr_rqd_data <= shn[447:0]; end
                            endcase
                        end else begin
                            bi <= bi + 3'd1;
                        end
                    end
                    // rd_done is a one-cycle pulse from the burst master after
                    // its last beat.
                    if (rd_done) state <= S_NEXT;
                end

                default: begin                      // S_NEXT
                    if (reg_i == R_RQD) begin
                        busy <= 1'b0; done <= 1'b1; state <= S_IDLE;
                    end else begin
                        reg_i <= reg_i + 2'd1;
                        state <= S_ISSUE;
                    end
                end
            endcase
        end
    end

endmodule
`default_nettype wire
