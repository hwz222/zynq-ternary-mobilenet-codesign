// ============================================================================
//  twn_rowbuf.v -- row ring buffer with row-credit pointers. Instantiated in
//  twn_fuse_top as RB_A (block input rows), RB_C (depthwise output rows),
//  RB_T1 (expand output rows, read by the depthwise) and RB_OU (output staging).
//
//  Storage: a row is ROW_WORDS words of ROW_BITS bits. At most DEPTH rows are
//  live (wptr - rptr); `free` is the number of rows the producer may still
//  start. Reads have one cycle of latency.
//
//  Pointers (units: rows)
//    wptr advances when a row has been written completely, rptr when the
//    consumer pulses row_done. Both clear on blk_start.
//    win_ready (rule 1): wptr >= min(r*s + 2, h_in), r = rd_row, s = stride
//      (0 -> 1, 1 -> 2): the three rows r*s-1..r*s+1 are written, capped at the
//      block's height so the last row does not wait for rows that never come.
//    rptr after row_done (rule 2): max(0, s*(r+1) - 1).
//
//  Banking (WINDOW = 3): the depthwise reads three consecutive rows in the same
//  cycle. They have distinct residues mod 3, so row r lives in bank r mod 3 and
//  every bank needs only one read port. Within a bank, the slot is
//  (r / BANKS) mod BD, where BD = ceil(DEPTH / BANKS). The banks are emitted in
//  fixed order on rd_bank with rd_mid_bank naming the bank of the middle row;
//  twn_rowbuf_rot rotates them into (top, mid, bottom) and applies the padding.
//
//  WINDOW = 1: the consumer reads one row; one bank, no padding.
//
//  Options
//    EXT_MEM = 1: the array lives outside (xm_* ports); BANKS must be 1. RB_A
//      and RB_C are two instances sharing one array (MEM_BASE is the ring's
//      word offset, XAW the shared address width).
//    LANE_WR = 1: the producer gives the word index (wr_word_i) and a one-hot
//      piece enable (wr_lane, LANES pieces of ROW_BITS/LANES bits) and ends a
//      row with wr_row_done. With LANE_WR = 0 the write word index is a
//      counter and the whole word is written.
//    MEM_SLICE > 0: each bank is built from arrays of MEM_SLICE words (a power
//      of two dividing BD*ROW_WORDS), read through a mux on the registered
//      slice select; read latency stays one cycle. 0 = one array per bank.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_rowbuf #(
    parameter integer ROW_BITS  = 1024,   // bits per row-word
    parameter integer ROW_WORDS = 128,    // words per row
    parameter integer DEPTH     = 4,      // rows held at once
    parameter integer BANKS     = 3,      // 3 => conflict-free 3-row window read
    parameter integer WINDOW    = 3,      // 3 = depthwise window, 1 = single-row reads
    parameter integer EXT_MEM   = 0,
    parameter integer MEM_BASE  = 0,      // word offset of this ring in the external array
    parameter integer XAW       = 16,     // external array address width
    parameter integer LANE_WR   = 0,
    parameter integer LANES     = 16,     // pieces per word; ROW_BITS/LANES bits each
    parameter integer MEM_SLICE = 0
)(
    input  wire clk,
    input  wire rst,

    // ---- EXT_MEM = 1: the storage lives outside. Unused when EXT_MEM = 0. ----
    output wire                  xm_we,
    output wire [XAW-1:0]        xm_wa,
    output wire [ROW_BITS-1:0]   xm_wd,
    output wire [LANES-1:0]      xm_lane,
    output wire [XAW-1:0]        xm_ra,
    input  wire [ROW_BITS-1:0]   xm_rd,

    // A new block starts the ring over: clears the pointers.
    input  wire                   blk_start,

    // ---- geometry, latched by the consumer of this buffer at block start ----
    input  wire [9:0]  h_in,              // rows this block will write
    input  wire        stride,            // 0 = 1, 1 = 2  (the dw's stride)

    // ---- producer ----
    input  wire                   wr_en,
    input  wire [ROW_BITS-1:0]    wr_data,
    input  wire                   wr_row_last,   // LANE_WR=0: this word ends the row
    // ---- LANE_WR = 1 only. Ignored otherwise. ----
    input  wire [$clog2(ROW_WORDS)-1:0] wr_word_i,  // word index within the row
    input  wire [LANES-1:0]       wr_lane,       // one-hot piece enable
    input  wire                   wr_row_done,   // the row is complete
    output wire                   wr_ready,      // == (free != 0)

    // ---- consumer ----
    input  wire                   rd_en,         // not used
    input  wire [9:0]             rd_row,        // OUTPUT row index r
    input  wire [$clog2(ROW_WORDS)-1:0] rd_word,
    // The banks in fixed order: bank k drives rd_bank[k]. WINDOW 1 uses bank 0.
    output wire [BANKS*ROW_BITS-1:0] rd_bank,
    // Bank holding the middle row r*s; top and bottom are (mid-1) and (mid+1)
    // modulo BANKS. Combinational from rd_row (not delayed like the data).
    output wire [1:0]             rd_mid_bank,
    // Per bank: that bank's row is vertical padding (registered with the data).
    output wire [BANKS-1:0]       rd_bank_pad,
    output wire                   rd_pad_top,    // row r*s-1 is above the image
    output wire                   rd_pad_bot,    // row r*s+1 is at or below h_in

    // ---- row credit ----
    input  wire                   row_done,      // consumer finished output row rd_row
    output wire                   win_ready,     // rule 1 above
    output wire [9:0]             wptr,
    output wire [9:0]             rptr,
    output wire [9:0]             free
);
    localparam integer WAW = $clog2(ROW_WORDS);
    localparam integer BD  = (DEPTH + BANKS - 1) / BANKS;      // rows per bank
    localparam integer BAW = $clog2(BD * ROW_WORDS);           // bank address width

    // ---- MEM_SLICE resolved once: MS = words per array, NSL = arrays per bank ----
    // MEM_SLICE = 0 gives MS = whole bank, NSL = 1 (flat path).
    localparam integer MS   = (MEM_SLICE > 0) ? MEM_SLICE : (BD * ROW_WORDS);
    localparam integer NSL  = (BD * ROW_WORDS + MS - 1) / MS;
    localparam integer SLAW = $clog2(MS);                      // address inside a slice
    localparam integer SELW = (BAW > SLAW) ? (BAW - SLAW) : 1; // which slice

    wire s = stride;                                            // 0 => 1, 1 => 2
    // r*s without a multiplier: s is one bit.
    function [10:0] rs; input [9:0] r; input st;
        begin rs = st ? {r, 1'b0} : {1'b0, r}; end
    endfunction

    // ---- pointers and credit ----
    reg [9:0] wptr_r, rptr_r;
    reg [WAW-1:0] wword;                   // write word counter (LANE_WR = 0)
    assign wptr = wptr_r;
    assign rptr = rptr_r;
    // Saturating: an occupancy above DEPTH reads as zero free rows rather than
    // wrapping around to a large number.
    wire [9:0] occ = wptr_r - rptr_r;
    assign free = (occ >= DEPTH[9:0]) ? 10'd0 : (DEPTH[9:0] - occ);
    assign wr_ready = (free != 10'd0);

    // rule 1, capped at the block height
    wire [10:0] thr_raw = rs(rd_row, s) + 11'd2;
    wire [10:0] thr     = (thr_raw > {1'b0, h_in}) ? {1'b0, h_in} : thr_raw;
    assign win_ready = ({1'b0, wptr_r} >= thr);

    // rule 2, computed as the next value of rptr
    wire [10:0] rp_next_raw = rs(rd_row + 10'd1, s);
    wire [9:0]  rp_next     = (rp_next_raw == 11'd0) ? 10'd0 : (rp_next_raw[9:0] - 10'd1);

    always @(posedge clk) begin
        if (rst || blk_start) begin
            wptr_r <= 10'd0; rptr_r <= 10'd0; wword <= {WAW{1'b0}};
        end else begin
            if (LANE_WR == 0) begin
                if (wr_en) begin
                    if (wr_row_last) begin wword <= {WAW{1'b0}}; wptr_r <= wptr_r + 10'd1; end
                    else                   wword <= wword + 1'b1;
                end
                // wr_row_done also ends a row, for producers that only learn
                // the end after their last write. If it coincides with a write,
                // the write uses the old wword and the row end wins on wword.
                if (wr_row_done) begin
                    wword <= {WAW{1'b0}};
                    wptr_r <= wptr_r + 10'd1;
                end
            end else begin
                // the word index comes from the producer; only the row advances here
                if (wr_row_done) wptr_r <= wptr_r + 10'd1;
            end
            if (row_done) rptr_r <= rp_next;
        end
    end

    // ---- row -> (bank, slot), without a divider ----
    // With BANKS = 3, r % BANKS and r / BANKS written directly would put a division by
    // three on an 11-bit row index in front of the block RAM address, so mod3 below folds it.
    // mod3: since 4 == 1 (mod 3), r mod 3 is the sum of r's base-4 digits,
    // folded until it is below 3.
    function [1:0] mod3; input [10:0] r;
        reg [5:0] s1; reg [3:0] s2; reg [2:0] s3;
        begin
            s1 = {4'd0, r[1:0]} + {4'd0, r[3:2]} + {4'd0, r[5:4]}
               + {4'd0, r[7:6]} + {4'd0, r[9:8]} + {5'd0, r[10]};
            s2 = {2'd0, s1[1:0]} + {2'd0, s1[3:2]} + {2'd0, s1[5:4]};
            s3 = {1'd0, s2[1:0]} + {1'd0, s2[3:2]};
            mod3 = (s3 >= 3'd3) ? (s3[1:0] - 2'd3) : s3[1:0];
        end
    endfunction
    // (r / 3) mod 2 from (r mod 3, r mod 2): it is 1 exactly when r mod 6 is 3, 4 or 5.
    function q3_2; input [1:0] a; input b;
        begin q3_2 = (a == 2'd1) ? ~b : b; end
    endfunction

    function [1:0] bank_of; input [10:0] r;
        begin bank_of = (BANKS == 1) ? 2'd0 : (BANKS == 3) ? mod3(r) : (r % BANKS); end
    endfunction
    // slot within the bank. BANKS == 1 with BD == 3 uses mod3; BD of 1, 2 or 4
    // makes `r % BD` a bit select. BANKS == 3 with BD == 2 uses q3_2.
    function [9:0] slot_of; input [10:0] r;
        begin slot_of = (BANKS == 1 && BD == 3)    ? {8'd0, mod3(r)}
                      : (BANKS == 1)               ? (r % BD)
                      : (BANKS == 3 && BD == 2)    ? {9'd0, q3_2(mod3(r), r[0])}
                      :                              ((r / BANKS) % BD); end
    endfunction

    // ---- the three window rows: r*s-1, r*s, r*s+1 (signed, so pads show as negative) ----
    wire [9:0] rd_row_a = rd_row;          // not used
    wire signed [11:0] row_t = $signed({1'b0, rs(rd_row, s)}) - 12'sd1;
    wire signed [11:0] row_m = $signed({1'b0, rs(rd_row, s)});
    wire signed [11:0] row_b = $signed({1'b0, rs(rd_row, s)}) + 12'sd1;

    assign rd_pad_top = (WINDOW == 3) && (row_t <  0);
    assign rd_pad_bot = (WINDOW == 3) && (row_b >= $signed({2'b0, h_in}));

    wire [10:0] rm = row_m[10:0];
    wire [1:0]  b_mid = bank_of(rm);
    wire [1:0]  b_top = (b_mid == 2'd0) ? (BANKS[1:0] - 2'd1) : (b_mid - 2'd1);
    wire [1:0]  b_bot = (b_mid == BANKS[1:0] - 2'd1) ? 2'd0 : (b_mid + 2'd1);

    assign rd_mid_bank = b_mid;

    // ---- storage: BANKS separate arrays, one write port and one read port each ----
    wire [10:0] w_row  = {1'b0, wptr_r};
    wire [1:0]  w_bank = bank_of(w_row);
    wire [WAW-1:0] w_word_sel = (LANE_WR == 0) ? wword : wr_word_i;
    wire [BAW-1:0] w_addr = slot_of(w_row) * ROW_WORDS + w_word_sel;

    genvar k;
    generate
        for (k = 0; k < BANKS; k = k + 1) begin : g_bank
            // Only the bank owning the write row is enabled.
            wire wr_here = wr_en && (WINDOW == 1 || w_bank == k[1:0]);

            // Bank k serves whichever window row has residue k; the selection
            // is in the address. A pad row reads address 0 and is flagged.
            wire [10:0] r_row = (WINDOW == 1)     ? rm
                              : (k[1:0] == b_mid) ? rm
                              : (k[1:0] == b_top) ? (row_t[10:0])
                              :                     (row_b[10:0]);
            wire        r_pad = (WINDOW == 1)     ? 1'b0
                              : (k[1:0] == b_top) ? rd_pad_top
                              : (k[1:0] == b_bot) ? rd_pad_bot
                              :                     1'b0;
            wire [9:0] slot_c = slot_of(r_row);
            wire [BAW-1:0] r_addr = r_pad ? {BAW{1'b0}}
                                          : (slot_c * ROW_WORDS + rd_word);

            // Storage inferred here (flat or sliced), or handed out (EXT_MEM).
            // Addresses, enables and pointers are the same in all cases.
            wire [ROW_BITS-1:0] q_mem;
            if (EXT_MEM == 0 && NSL > 1) begin : g_sliced
                // Same storage as g_local, cut into NSL arrays of MS words.
                wire [SLAW-1:0] w_off = w_addr[SLAW-1:0];
                wire [SLAW-1:0] r_off = r_addr[SLAW-1:0];
                wire [SELW-1:0] w_sel = w_addr[BAW-1:SLAW];
                wire [SELW-1:0] r_sel = r_addr[BAW-1:SLAW];
                // registered so the mux lines up with the arrays' registered outputs
                reg  [SELW-1:0] r_sel_q;
`ifdef RB_NEG_SLICE_COMB
                // negative test: select with the current address, not the one
                // the registered data came from
                always @(*) r_sel_q = r_sel;
`else
                always @(posedge clk) r_sel_q <= r_sel;
`endif

                wire [ROW_BITS-1:0] qsl [0:NSL-1];
                genvar sl;
                for (sl = 0; sl < NSL; sl = sl + 1) begin : g_sl
                    reg [ROW_BITS-1:0] mem [0:MS-1];
                    integer L;
                    always @(posedge clk) if (wr_here && w_sel == sl[SELW-1:0])
                        for (L = 0; L < LANES; L = L + 1)
                            if (LANE_WR == 0 || wr_lane[L])
                                mem[w_off][L*(ROW_BITS/LANES) +: (ROW_BITS/LANES)]
                                    <= wr_data[L*(ROW_BITS/LANES) +: (ROW_BITS/LANES)];
                    reg [ROW_BITS-1:0] qr;
                    always @(posedge clk) qr <= mem[r_off];
                    assign qsl[sl] = qr;
                end
                // an out-of-range slice index gives X, as in the flat array
                assign q_mem = qsl[r_sel_q];
            end else if (EXT_MEM == 0) begin : g_local
                reg [ROW_BITS-1:0] mem [0:BD*ROW_WORDS-1];
                // per-piece write enable; at LANE_WR = 0 every piece is written
                integer L;
                always @(posedge clk) if (wr_here)
                    for (L = 0; L < LANES; L = L + 1)
                        if (LANE_WR == 0 || wr_lane[L])
                            mem[w_addr][L*(ROW_BITS/LANES) +: (ROW_BITS/LANES)]
                                <= wr_data[L*(ROW_BITS/LANES) +: (ROW_BITS/LANES)];
                reg [ROW_BITS-1:0] qr;
                always @(posedge clk) qr <= mem[r_addr];
                assign q_mem = qr;
            end else begin : g_ext
                // read data comes from the external array
                assign q_mem = xm_rd;
            end

            reg p;
            always @(posedge clk) p <= r_pad;
            assign rd_bank[k*ROW_BITS +: ROW_BITS] = q_mem;
            assign rd_bank_pad[k] = p;
        end
    endgenerate

    // ---- external memory ports (bank 0), zero when EXT_MEM = 0 ----
    // addresses are offset by MEM_BASE
    assign xm_we = (EXT_MEM != 0) ? g_bank[0].wr_here : 1'b0;
    assign xm_wa = (EXT_MEM != 0) ? (MEM_BASE[XAW-1:0] + {{(XAW-BAW){1'b0}}, w_addr})
                                  : {XAW{1'b0}};
    assign xm_wd = wr_data;
    // all ones at LANE_WR = 0, so one external write path serves both modes
    assign xm_lane = (LANE_WR == 0) ? {LANES{1'b1}} : wr_lane;
    assign xm_ra = (EXT_MEM != 0) ? (MEM_BASE[XAW-1:0] + {{(XAW-BAW){1'b0}}, g_bank[0].r_addr})
                                  : {XAW{1'b0}};

    // ---- elaboration checks ----
    // EXT_MEM needs BANKS == 1: the banked window read has one address per bank.
    initial if (EXT_MEM != 0 && BANKS != 1) begin
        $display("twn_rowbuf: EXT_MEM requires BANKS == 1, got %0d", BANKS);
        $finish;
    end

    // The slice select is an address bit slice, so MEM_SLICE must be a power of
    // two that divides the bank exactly.
    initial if (MEM_SLICE != 0 &&
                ((MS & (MS - 1)) != 0 || (NSL * MS) != (BD * ROW_WORDS))) begin
        $display("twn_rowbuf: MEM_SLICE %0d must be a power of two dividing BD*ROW_WORDS %0d",
                 MEM_SLICE, BD * ROW_WORDS);
        $finish;
    end

    // keeps rd_en referenced so lint does not report it unused
    wire _unused_ok = &{1'b0, rd_en, 1'b0};

endmodule
`default_nettype wire
