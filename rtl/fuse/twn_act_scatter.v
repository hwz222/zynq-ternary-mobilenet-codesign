// ============================================================================
//  twn_act_scatter.v -- array output beats -> row buffer words.
//
//  Each beat from the array carries PIX pixels x `pack` channels (in_data byte
//  (bk*OCMAX + ja) = pixel bk, channel ch0 + ja, ch0 = pack*ocg). Beats arrive
//  in (pixel group, ocg) order. The row buffer wants x-major, channel-innermost
//  bytes: byte (cp, ch) of pixel group xg goes at row byte
//  (xg*PIX + cp)*C + ch, C = c_chan.
//
//  Structure:
//    banks      one block-RAM bank per pixel (cp), 16-byte words, byte-write
//               enabled. A beat writes `pack` consecutive channel bytes into
//               each bank at byte offset ch0. Two halves (double buffer): one
//               group fills while the previous group drains.
//    drain      once a group's last beat arrives (ch0 + pack >= C), read bank 0's
//               words, then bank 1's, ... one 16-byte bank word per cycle. This
//               is the row's byte order for the group.
//    repacker   a pixel's last bank word holds only C mod 16 valid bytes when C
//               is not a multiple of 16; the repacker (hold/hcnt) closes the gap
//               so the output is a continuous byte stream cut into 16-byte pieces.
//               For C a multiple of 16 it passes every read through unchanged.
//    assembler  NCH (= ROW_BITS/8/16) 16-byte pieces are collected into one row
//               buffer word, written with wr_en.
//
//  Protocol: in_valid beats may arrive every cycle; there is no back-pressure.
//  The drain of a group takes PIX*ceil(C/16) cycles and must not be slower than
//  the C/pack beats that fill the next group (checked in simulation below).
//  `flush` requests the end-of-row write of a partial word; flush_done pulses
//  when it has been served.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_act_scatter #(
    parameter integer ROW_BITS = 1024,          // row buffer word, 128 bytes
    parameter integer PIX      = 4,             // pixels per beat
    parameter integer OCMAX    = 4,             // channels per beat per pixel, maximum
    parameter integer CMAX     = 960            // largest channel count C
)(
    input  wire clk,
    input  wire rst,

    // ---- block shape ----
    input  wire [9:0]  c_chan,                  // C
    input  wire [2:0]  pack,                    // channels per beat: 1, 2 or 4

    // ---- beats from the array, in (xg, ocg) order ----
    input  wire                    in_valid,
    input  wire [9:0]              ocg,         // output channel group within the pixel group
    input  wire [PIX*OCMAX*8-1:0]  in_data,

    // ---- row buffer write port ----
    output reg  [15:0]          wr_word,        // word index (counts up, cleared only by rst)
    output reg                  wr_en,
    output reg  [ROW_BITS-1:0]  wr_data,

    // ---- end of row ----
    // `flush` is a request and may be a single cycle. It is remembered in
    // flush_pend until the drain and repacker are empty, then the partial word
    // (if any) is written and flush_done pulses.
    input  wire        flush,
    output reg         flush_done,

    // ---- observation only: which pixel banks carry data ----
    // o_bank_wnz[b]: the data being written into bank b is non-zero this cycle.
    // o_bank_rnz[b]: the word the drain takes from bank b this cycle is non-zero.
    // Combinational, nothing in this module reads them.
    output wire [PIX-1:0] o_bank_wnz,
    output wire [PIX-1:0] o_bank_rnz
);
    localparam integer BW  = 16;                        // bank word, bytes
    localparam integer BD  = (CMAX + BW - 1) / BW;      // bank words per half
    localparam integer NCH = (ROW_BITS/8) / BW;         // 16-byte pieces per row word

    // ---- banks: one per pixel, byte-enabled, double buffered ----
    reg  fill_half;                                     // half being filled
    wire [9:0]  ch0  = {7'd0, pack} * ocg[9:0];         // first channel this beat
    wire [9:0]  wa   = (fill_half ? BD[9:0] : 10'd0) + (ch0 >> 4);   // bank word address
    wire [3:0]  wo   = ch0[3:0];                        // byte offset within the bank word

    // Byte enables are shared by all banks: a beat writes the same channel
    // positions in each, only the data differs. pack divides 16, so a write
    // never straddles a bank word.
    reg  [BW-1:0] wben;
    integer cc;
    always @* begin
        wben = {BW{1'b0}};
        for (cc = 0; cc < OCMAX; cc = cc + 1)
            if (cc[2:0] < pack) wben[wo + cc[3:0]] = 1'b1;
    end

    reg  [9:0]      ra;                                 // bank read address (all banks)

    // The four bank outputs as one packed vector, so the drain selects a bank
    // with a part-select.
    wire [PIX*BW*8-1:0] rdat_flat;

    genvar bk;
    generate
        for (bk = 0; bk < PIX; bk = bk + 1) begin : g_bank
            wire [BW*8-1:0] q;
            reg  [BW*8-1:0] d;
            integer ja;
            // write data for this bank: pixel bk's `pack` bytes at offset wo
            always @* begin
                d = {(BW*8){1'b0}};
                for (ja = 0; ja < OCMAX; ja = ja + 1)
                    if (ja[2:0] < pack)
                        d[(wo + ja[3:0])*8 +: 8] = in_data[(bk*OCMAX + ja)*8 +: 8];
            end

            // Byte-write simple dual-port RAM, one-cycle read latency. Each bank
            // is an instantiated memory (bram_sdp_bw) rather than an inferred
            // array.
            localparam integer MAW = $clog2(2*BD);
            bram_sdp_bw #(.W(BW*8), .D(2*BD), .AW(MAW), .BW(8)) u_m (
                .clk (clk),
                .wea ({BW{in_valid}} & wben),
                .wa  (wa[MAW-1:0]),
                .wd  (d),
                .ra  (ra[MAW-1:0]),
                .en  (1'b1),
                .rd  (q)
            );

            assign rdat_flat[bk*BW*8 +: BW*8] = q;

            assign o_bank_wnz[bk] = in_valid && (|d);
        end
    endgenerate

    // ---- drain: bank 0's words, then bank 1's, ... ----
    wire [9:0] nbw = (c_chan + 10'd15) >> 4;            // bank words per pixel
    reg  [1:0] d_cp;                                    // bank being read
    reg  [9:0] d_w;                                     // word within the pixel
    reg        d_run, d_half;                           // draining; which half
    // The bank output arrives one cycle after ra, so the drain state is delayed
    // one cycle (_q) to line up with the data.
    reg  [1:0] d_cp_q;
    reg        d_v_q;
    reg  [9:0] d_w_q;

    // o_bank_rnz is qualified by the drain (d_v_q, d_cp_q): the bank output
    // register reloads every cycle, so an unqualified |q would say nothing.
    genvar rbk;
    generate for (rbk = 0; rbk < PIX; rbk = rbk + 1) begin : g_rnz
        assign o_bank_rnz[rbk] = d_v_q && (d_cp_q == rbk[1:0]) &&
                                 (|rdat_flat[rbk*BW*8 +: BW*8]);
    end endgenerate

    // bytes this read carries: 16, or C mod 16 on a pixel's last word
    wire [4:0] d_len_q = ((d_w_q + 10'd1) == nbw && (c_chan[3:0] != 4'd0))
                         ? {1'b0, c_chan[3:0]} : 5'd16;

    // ---- repacker: variable-length in, 16 bytes out ----
    // hold: bytes waiting; hcnt: how many of them are valid (stays below 32).
    reg  [2*BW*8-1:0] hold;
    reg  [5:0]        hcnt;
    // Only the first d_len_q bytes of a read belong to the pixel; the rest are
    // other data in the same bank word and must not be inserted, since nothing
    // clears bytes above hcnt before the next insert ORs on top.
    reg [BW*8-1:0] rmask;
    integer mi;
    always @* begin
        rmask = {(BW*8){1'b0}};
        for (mi = 0; mi < BW; mi = mi + 1)
            if (mi[4:0] < d_len_q) rmask[mi*8 +: 8] = 8'hFF;
    end
    wire [BW*8-1:0]   rd_sel = rdat_flat[d_cp_q*BW*8 +: BW*8];
    wire [2*BW*8-1:0] ins = {{(BW*8){1'b0}}, (rd_sel & rmask)} << {hcnt, 3'b000};
    wire              pop = (hcnt >= 6'd16);

    // ---- assembler: NCH 16-byte pieces per row buffer word ----
    reg [BW*8-1:0] acc [0:NCH-1];
    reg [2:0]      acc_i;                // next piece to fill
    reg [15:0]     out_w;                // index of the next word written
    reg            flush_pend;           // a row end asked for while the drain was busy

    integer ai;
    always @* begin
        wr_data = {ROW_BITS{1'b0}};
        for (ai = 0; ai < NCH; ai = ai + 1)
            wr_data[ai*BW*8 +: BW*8] = acc[ai];
    end

    always @(posedge clk) begin
        if (rst) begin
            fill_half <= 1'b0; d_run <= 1'b0; d_half <= 1'b0;
            d_cp <= 2'd0; d_w <= 10'd0; ra <= 10'd0;
            d_v_q <= 1'b0; d_cp_q <= 2'd0; d_w_q <= 10'd0;
            hold <= {(2*BW*8){1'b0}}; hcnt <= 6'd0;
            acc_i <= 3'd0; out_w <= 16'd0; flush_pend <= 1'b0;
            wr_en <= 1'b0; flush_done <= 1'b0;
        end else begin
            wr_en      <= 1'b0;
            flush_done <= 1'b0;
            d_v_q      <= 1'b0;

`ifdef SCAT_NEG_DRAIN_WINS
            // Negative-test arm: the group restart comes before the drain, so
            // the drain's terminal `d_run <= 0` overrides the restart.
            if (in_valid && (ch0 + {7'd0, pack} >= c_chan)) begin
                fill_half <= ~fill_half;
                d_half    <= fill_half;
                d_run     <= 1'b1;
                d_cp      <= 2'd0;
                d_w       <= 10'd0;
                ra        <= (fill_half ? BD[9:0] : 10'd0);
            end
`endif

            // ---- one bank word per cycle ----
            // The drain block comes first and the group restart below second, on
            // purpose: if a group's completing beat lands in the cycle the drain
            // reads its last bank word, both blocks write d_run, and the later
            // write (the restart, 1) must win over the drain's terminal 0.
            // The drain's outputs (d_v_q, d_cp_q, d_w_q) and `ra` use the
            // pre-edge counters either way, so the ending group still issues its
            // last read. This relies on the drain never being slower than the
            // fill (see the simulation check at the end).
            if (d_run) begin
                d_v_q  <= 1'b1;
                d_cp_q <= d_cp;
                d_w_q  <= d_w;
                if ((d_w + 10'd1) == nbw) begin
                    d_w <= 10'd0;
                    ra  <= (d_half ? BD[9:0] : 10'd0);
                    if (d_cp == PIX[1:0] - 2'd1) begin
                        d_run <= 1'b0; d_cp <= 2'd0;
                    end else begin
                        d_cp <= d_cp + 2'd1;
                    end
                end else begin
                    d_w <= d_w + 10'd1;
                    ra  <= ra + 10'd1;
                end
            end

            // ---- a group is full on the beat carrying its last channels ----
            // swap halves and start draining the half just filled
`ifndef SCAT_NEG_DRAIN_WINS
            if (in_valid && (ch0 + {7'd0, pack} >= c_chan)) begin
                fill_half <= ~fill_half;
                d_half    <= fill_half;
                d_run     <= 1'b1;
                d_cp      <= 2'd0;
                d_w       <= 10'd0;
                ra        <= (fill_half ? BD[9:0] : 10'd0);
            end
`endif

            // ---- repack, then append ----
            // insert the masked read at byte hcnt, and/or pop 16 bytes into the
            // assembler
            if (d_v_q || pop) begin
                if (d_v_q && !pop) begin
                    hold <= hold | ins;
                    hcnt <= hcnt + {1'b0, d_len_q};
                end else if (!d_v_q && pop) begin
                    hold <= hold >> (BW*8);
                    hcnt <= hcnt - 6'd16;
                end else begin
                    hold <= (hold | ins) >> (BW*8);
                    hcnt <= hcnt + {1'b0, d_len_q} - 6'd16;
                end

                if (pop) begin
                    acc[acc_i] <= hold[BW*8-1:0];
                    if (acc_i == NCH[2:0] - 3'd1) begin
                        acc_i   <= 3'd0;
                        wr_word <= out_w;
                        wr_en   <= 1'b1;
                        out_w   <= out_w + 16'd1;
                    end else begin
                        acc_i <= acc_i + 3'd1;
                    end
                end
            end

            // ---- the row end, held until it can be served ----
            // Served once the drain is idle and the repacker is empty (hcnt == 0),
            // which assumes the row is a whole number of 16-byte pieces. A partial
            // word is written as is: pieces at and above acc_i keep whatever they
            // held before.
`ifdef SCAT_NEG_FLUSH_PULSE
            // Negative-test arm: serve the request only if everything is idle in
            // the cycle it arrives.
            if (flush && !d_run && !d_v_q && (hcnt == 6'd0)) begin
`else
            if (flush) flush_pend <= 1'b1;
            if ((flush || flush_pend) && !d_run && !d_v_q && (hcnt == 6'd0)) begin
                flush_pend <= 1'b0;
`endif
                if (acc_i != 3'd0) begin
                    wr_word <= out_w; wr_en <= 1'b1;
                    out_w   <= out_w + 16'd1; acc_i <= 3'd0;
                end
                flush_done <= 1'b1;
            end
        end
    end

    // ---- simulation check: the drain must keep up with the fill ----
    // A completing beat arriving while the drain is running and not on its last
    // read means the next group's fill outran the drain; the restart then drops
    // the remaining words of the previous group. There is no back-pressure to
    // prevent it, so this counts and reports it.
`ifndef SYNTHESIS
    integer ovr = 0;
    always @(posedge clk) if (!rst) begin
        if (in_valid && (ch0 + {7'd0, pack} >= c_chan) && d_run &&
            !(((d_w + 10'd1) == nbw) && (d_cp == PIX[1:0] - 2'd1))) begin
            ovr = ovr + 1;
            if (ovr <= 5)
                $display("*** twn_act_scatter: a pixel group completed %0d bank-word reads into the previous group's drain (C %0d, pack %0d, nbw %0d, d_cp %0d, d_w %0d). The fill is outrunning the drain and this module has no back-pressure -- the previous group's remaining words are being dropped. ***",
                         d_cp*nbw + d_w, c_chan, pack, nbw, d_cp, d_w);
        end
    end
`endif

endmodule
`default_nettype wire
