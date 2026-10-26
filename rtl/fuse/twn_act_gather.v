// ============================================================================
//  twn_act_gather.v -- row buffer -> activation word for the ternary array.
//
//  The array takes one "activation word" per request: PIX pixels x LANES
//  channels, one byte each. Pixel p of the word is lanes 0..len-1 = channels
//  [seg*LANES, seg*LANES+len) of pixel x_abs = xg*PIX + p, zero-padded to LANES.
//  Row buffer layout is channel-innermost, so byte (c, x) of a row is at x*C + c
//  (C = c_chan). A pixel's run of bytes therefore starts at x*C + seg*LANES,
//  anywhere inside a row buffer word. This module holds two consecutive row
//  buffer words (`lo`, `hi`) and funnels the run out of them, CHUNK bytes per
//  cycle.
//
//  Stem mode (stem = 1, block 0 only): the 3x3 stride-2 convolution on a
//  3-channel image. The nine bytes (kx, c) of one kernel row are contiguous, so
//  the run starts at byte 6*x_abs - 3 and is 9 bytes long, and it is reordered
//  to lane = c*3 + kx. At x_abs = 0 the run is clamped to start at byte 0 and
//  shifted by 3 lanes, so the three kx = 0 lanes are zero. For the stem, `seg`
//  does not enter the address; the caller selects the kernel row through the
//  row buffer read port and passes stem_pad_row when that row is off the image.
//
//  Protocol: raise `req` for one cycle while `busy` is low, with xg, seg,
//  c_chan, stem, stem_pad_row and src held until `done`. `done` is a one-cycle
//  pulse; busy is low in that cycle. act_data is complete from the `done` cycle
//  and is next overwritten when a later request starts. A request made while
//  busy is dropped (there is no queue).
//
//  Fixed assumptions in the code: PIX = 4 (2-bit pixel counter), LANES/CHUNK <= 4
//  (2-bit chunk counter), seg is 3 bits, row buffer word = 128 bytes.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_act_gather #(
    parameter integer ROW_BITS = 1024,          // row buffer word
    parameter integer LANES    = 128,           // channels the array takes at once
    parameter integer PIX      = 4              // pixels per activation word
)(
    input  wire clk,
    input  wire rst,

    // ---- request: one activation word ----
    input  wire        req,
    input  wire [9:0]  xg,                      // pixel group, PIX pixels wide
    input  wire [2:0]  seg,                     // channel chunk (non-stem)
    input  wire [9:0]  c_chan,                  // C, the tensor's channels
    // ---- the 3x3 stride-2 stem (block 0 only) ----
    input  wire        stem,                    // 1 = the stem addressing
    input  wire        stem_pad_row,            // this pass' input row is off the
                                                // image: run length is forced to 0,
                                                // so the word is all zero
    // Identifies which row of which buffer the caller's read port selects. The
    // two-word cache is valid only for the source it was filled from, because
    // the caller can change the row while the word index stays the same. The
    // value is opaque here: any tag that changes whenever the selected row
    // changes will do. It must be held for the whole service.
    input  wire [10:0] src,
    output reg         busy,
    output reg         done,

    // ---- row buffer read port ----
    output reg  [15:0]          rb_word,        // word index
    output reg                  rb_re,
    input  wire [ROW_BITS-1:0]  rb_data,        // sampled the cycle after rb_re

    // ---- to the array ----
    // PIX x LANES bytes; pixel p occupies bytes [p*LANES, (p+1)*LANES)
    output wire [PIX*LANES*8-1:0] act_data
);
    localparam integer WB  = ROW_BITS / 8;      // bytes per word
    localparam integer WBL = $clog2(WB);        // 7 for 1024 bits
    localparam integer LBL = $clog2(LANES);

    // ---- two-word cache ----
    // `hi` holds word hi_idx, `lo` holds word hi_idx - 1 (valid when lo_ok).
    // A run starting in word need_w is served when hi_idx == need_w + 1, so the
    // run's first byte is inside `lo`. src_q is the source the cache was read from.
    reg [ROW_BITS-1:0] lo, hi;
    reg [15:0]         hi_idx, pend_idx;
    reg                primed;
    reg [10:0]         src_q;
    // lo_ok: `lo` really is word hi_idx - 1. hi_only: the run is served from
    // `hi` alone (see the one-word-run section). Declared here because qsel
    // reads hi_only above the fetch FSM.
    reg                lo_ok;
    reg                hi_only;

    reg [1:0]  p;                       // pixel within the word
    reg [2:0]  st;
    reg [15:0] need_w, target;          // run's first word index; need_w + 1
    reg [WBL-1:0] need_s;               // run's first byte within that word
    reg [7:0]  run_len;                 // bytes in this pixel's run
    reg        rb_re_d;
    // Latched with run_len so the emit stage does not depend on inputs still
    // being held by the caller.
    reg        r_stem, r_lpad;
    // Index of the last chunk that carries any of the run (same value for all
    // pixels of a request).
    reg [1:0]  last_j;

    localparam [2:0] S_IDLE = 3'd0, S_CALC = 3'd1, S_FETCH = 3'd2,
                     S_WAIT = 3'd3, S_EMIT = 3'd4, S_DONE = 3'd5;

    // non-stem run length: channels left in this chunk, capped at LANES
    wire [9:0]  rest    = c_chan - ({7'd0, seg} << LBL);
    wire [7:0]  len_of  = (rest >= LANES) ? LANES[7:0] : rest[7:0];

    // ---- per-pixel byte offset, accumulated rather than multiplied ----------
    // The multiply x_abs * c_chan is done once per request, in S_IDLE, using
    // x_abs0 = xg * PIX (pixel 0 literally: `p` still holds the previous
    // request's last pixel in S_IDLE). byte_q then steps by byte_step per pixel
    // (c_chan, or 6 for the stem). byte_q holds the stem offset unclamped (-3 at
    // x_abs 0); the left-edge clamp is applied on the way out in byte_st, so the
    // accumulation steps by +6 across the first pixel.
    wire [25:0] x_abs0  = {14'd0, xg} * PIX;
    wire [25:0] gen_st0 = x_abs0 * {16'd0, c_chan} + ({23'd0, seg} << LBL);
    // 6*x_abs0 written as shifts of sliced operands so each operand has a defined width
    wire [25:0] stem_st0 = {x_abs0[24:0], 1'b0} + {x_abs0[23:0], 2'b00} - 26'd3;
    wire [25:0] byte_st0 = stem ? stem_st0 : gen_st0;
    wire [25:0] byte_step = stem ? 26'd6 : {16'd0, c_chan};
    reg  [25:0] byte_q;
    reg         lpad_q;                       // x_abs == 0, i.e. xg == 0 && p == 0
`ifdef GATH_NEG_BYTE_COMB
    // Alternative: recompute the offset from xg and p each pixel.
    wire [25:0] x_abs   = {14'd0, xg} * PIX + {24'd0, p};
    wire [25:0] gen_st  = x_abs * {16'd0, c_chan} + ({23'd0, seg} << LBL);
    wire        lpad_w  = (x_abs == 26'd0);
    wire [25:0] stem_st = lpad_w ? 26'd0
                                 : ({x_abs[24:0], 1'b0} + {x_abs[23:0], 2'b00} - 26'd3);
    wire [25:0] byte_st = stem ? stem_st : gen_st;
`else
    wire        lpad_w  = lpad_q;
    wire [25:0] byte_st = (stem && lpad_q) ? 26'd0 : byte_q;
`endif
    // run length: 9 bytes for a live stem pass, 0 for a stem pass whose input
    // row is off the image (the word then comes out all zero)
`ifdef GATH_NEG_NO_PADROW
    wire [7:0]  run_now = stem ? 8'd9 : len_of;
`else
    wire [7:0]  run_now = stem ? (stem_pad_row ? 8'd0 : 8'd9) : len_of;
`endif

    // ---- the funnel: CHUNK bytes per cycle ----------------------------------
    // A run is emitted CHUNK bytes at a time. The shift splits in two because
    // the offset does:
    //     offset(chunk j) = need_s + CHUNK*j  =  CHUNK*(q0 + j) + r
    // The coarse part selects a CHUNK-byte block (qsel) with an 8:1 mux over
    // the 2-word window; the fine part r = need_s's low bits is constant for all
    // chunks of a pixel and drives a CHUNK-byte funnel.
    localparam integer CHUNK = 32;                    // bytes emitted per cycle
    localparam integer CHL   = $clog2(CHUNK);         // 5
    localparam integer NCH   = LANES / CHUNK;         // 4 chunks per lane word

    wire [2*ROW_BITS-1:0] win = {hi, lo};
    reg  [1:0] j;                                     // chunk within the run
    // CHUNK-byte block index into win; +NCH when the run is served from `hi`
    wire [3:0] qsel = need_s[WBL-1:CHL] + {2'd0, j}
                    + (hi_only ? NCH[3:0] : 4'd0);

    // Number of chunks this run needs. run_now == 0 (stem pad row) would
    // underflow run_now - 1, so it is named: one chunk is still emitted, and it
    // is all zero.
    wire [1:0] last_of = (run_now == 8'd0) ? 2'd0 : (run_now - 8'd1) >> CHL;
    // FUSE_GATH_ALLCHUNKS: always walk all NCH chunks
`ifdef FUSE_GATH_ALLCHUNKS
    wire [1:0] last_now = NCH[1:0] - 2'd1;
`else
    wire [1:0] last_now = last_of;
`endif

    // Two consecutive CHUNK-byte blocks, selected explicitly so this is an 8:1
    // mux. qsel can reach 7 when a run served from `hi` ends in the word's last
    // block, so the window is widened by one zero block; bytes taken from it are
    // past the run and are masked in S_EMIT by the `< run_len` test.
    wire [2*ROW_BITS+CHUNK*8-1:0] winz = {{(CHUNK*8){1'b0}}, win};
    reg [2*CHUNK*8-1:0] pair;
    integer qi;
    always @* begin
        pair = {(2*CHUNK*8){1'b0}};
        for (qi = 0; qi < (2*WB)/CHUNK; qi = qi + 1)
            if (qsel == qi[3:0]) pair = winz[qi*CHUNK*8 +: 2*CHUNK*8];
    end

    // fine funnel: CHUNK bytes out of 2*CHUNK, by r = need_s's low bits
    wire [CHL-1:0] r_fine = need_s[CHL-1:0];
    wire [2*CHUNK*8-1:0] fstg [0:CHL];
    assign fstg[0] = pair;
    genvar fj;
    generate
        for (fj = 0; fj < CHL; fj = fj + 1) begin : g_fine
            assign fstg[fj+1] = r_fine[fj] ? (fstg[fj] >> (8 << fj)) : fstg[fj];
        end
    endgenerate
    wire [CHUNK*8-1:0] fun = fstg[CHL][CHUNK*8-1:0];

    // ---- output chunk registers ----
    // acc[{p, j}] is chunk j of pixel p. Bytes past the run are zero: a short
    // last chunk is masked in chunk_word, chunks entirely past the run are
    // blanked when the pixel starts (S_CALC, or the previous pixel's last S_EMIT).
    reg [CHUNK*8-1:0] acc [0:PIX*NCH-1];
    genvar ai;
    generate
        for (ai = 0; ai < PIX*NCH; ai = ai + 1) begin : g_acc
            assign act_data[ai*CHUNK*8 +: CHUNK*8] = acc[ai];
        end
    endgenerate

    integer k;
    integer bz;                       // loop over the NCH chunks being blanked
    reg [CHUNK*8-1:0] chunk_word;
    // Stem lane mapping: lane k takes run byte (k%3)*3 + k/3 (a 3x3 transpose);
    // when r_lpad the run is one colour triple early, so lanes 0, 3 and 6 are zero.
    // GATH_NEG_NO_TRANSPOSE: use the row's own order instead.
`ifdef GATH_NEG_NO_TRANSPOSE
    localparam integer TRP = 0;
`else
    localparam integer TRP = 1;
`endif
    always @* begin
        chunk_word = {(CHUNK*8){1'b0}};
        // Nonzero only in S_EMIT: S_CALC writes chunk_word into the pixel's chunk
        // registers to blank them, and there run_len, j and r_stem still hold the
        // previous pixel's values.
        if (st == S_EMIT) begin
        if (r_stem) begin
            // Only chunk 0 carries the nine taps; the other chunks are blanked.
            if ((j == 2'd0) && (run_len != 8'd0)) begin
                if (TRP != 0) begin
                    chunk_word[0*8 +: 8] = r_lpad ? 8'd0          : fun[0*8 +: 8];
                    chunk_word[1*8 +: 8] = r_lpad ? fun[0*8 +: 8] : fun[3*8 +: 8];
                    chunk_word[2*8 +: 8] = r_lpad ? fun[3*8 +: 8] : fun[6*8 +: 8];
                    chunk_word[3*8 +: 8] = r_lpad ? 8'd0          : fun[1*8 +: 8];
                    chunk_word[4*8 +: 8] = r_lpad ? fun[1*8 +: 8] : fun[4*8 +: 8];
                    chunk_word[5*8 +: 8] = r_lpad ? fun[4*8 +: 8] : fun[7*8 +: 8];
                    chunk_word[6*8 +: 8] = r_lpad ? 8'd0          : fun[2*8 +: 8];
                    chunk_word[7*8 +: 8] = r_lpad ? fun[2*8 +: 8] : fun[5*8 +: 8];
                    chunk_word[8*8 +: 8] = r_lpad ? fun[5*8 +: 8] : fun[8*8 +: 8];
                end else begin
                    for (k = 0; k < 9; k = k + 1)
                        if (!(r_lpad && (k < 3)))
                            chunk_word[k*8 +: 8] = fun[(r_lpad ? (k-3) : k)*8 +: 8];
                end
            end
        end else begin
            for (k = 0; k < CHUNK; k = k + 1)
                if (({6'd0, j} * CHUNK + k[7:0]) < run_len)
                    chunk_word[k*8 +: 8] = fun[k*8 +: 8];
        end
        end
    end

    // ---- cache hit / fetch decision -----------------------------------------
    // The cache is usable only if it was filled from the source selected now.
    // GATH_NEG_NO_SRC_TAG: ignore the source tag.
`ifdef GATH_NEG_NO_SRC_TAG
    wire src_ok = primed;
`else
    wire src_ok = primed && (src_q == src);
`endif
    // slide by one word (read word `target`), or jump (read target-1 first,
    // then target)
    wire slide = src_ok && ((hi_idx + 16'd1) == target);
    wire [15:0] rd_idx = slide ? target : (target - 16'd1);

    // ---- one-word runs ----
    // A jump reads word need_w first (into `hi`) and then need_w+1 only to shift
    // need_w down into `lo`. If the whole run is inside need_w, that second read
    // is skipped and the funnel indexes `hi` instead (hi_only; qsel += NCH).
    //   fits_one  need_s + run < 128 bytes, i.e. the run ends inside need_w
    // run_now, not run_len: in S_FETCH run_len still belongs to the previous
    // pixel. Both operands are widened to 9 bits (need_s is 7, run_now is 8).
    wire        fits_one = ({2'd0, need_s} + {1'b0, run_now}) <= 9'd128;

    // ---- fetch decision made in S_CALC from combinational values ------------
    // Computed from byte_st directly, so S_CALC can choose between S_EMIT and a
    // read without an S_FETCH cycle. rb_word stays a register: its input is the
    // same byte_st arithmetic, not new logic ahead of the RAM address pin.
    // S_FETCH is still used by FUSE_NEG_FETCH_LATE.
    wire [15:0] target_c   = byte_st[25:WBL] + 16'd1;
    wire [WBL-1:0] need_s_c = byte_st[WBL-1:0];
    wire        fits_one_c = ({2'd0, need_s_c} + {1'b0, run_now}) <= 9'd128;
    wire        hit_c      = src_ok && lo_ok && (hi_idx == target_c);
`ifdef GATH_NEG_NO_VA
    wire        va_stop_c  = 1'b0;
`else
    wire        va_stop_c  = fits_one_c && src_ok && (hi_idx == (target_c - 16'd1));
`endif
    wire        slide_c    = src_ok && ((hi_idx + 16'd1) == target_c);
    wire [15:0] rd_idx_c   = slide_c ? target_c : (target_c - 16'd1);
`ifdef GATH_NEG_NO_VA
    wire        va_stop  = 1'b0;
`else
    wire        va_stop  = fits_one && src_ok && (hi_idx == (target - 16'd1));
`endif

    // ---- fetch decision in S_WAIT, when a read lands ----
    // The word just read is pend_idx and the word wanted is `target`, both
    // registers. After the latch hi_idx == pend_idx and src_q == src, so src_ok
    // is true by construction. The address written to rb_word is `target` or
    // target-1. FUSE_NEG_WAIT_LATE routes through S_FETCH instead.
    wire        w_lo_ok  = (pend_idx == (hi_idx + 16'd1));
    wire        w_hit    = w_lo_ok && (pend_idx == target);
`ifdef GATH_NEG_NO_VA
    wire        w_vastop = 1'b0;
`else
    wire        w_vastop = fits_one && (pend_idx == (target - 16'd1));
`endif
    wire        w_slide  = ((pend_idx + 16'd1) == target);
    wire [15:0] w_rd_idx = w_slide ? target : (target - 16'd1);

    // ---- next pixel's decision, made in the current pixel's last S_EMIT -----
    // byte_nx is the sum byte_q takes at that edge. run_now and last_now do not
    // depend on p, stem / c_chan / seg are held for the service, and lpad is
    // true only for x_abs == 0, so pixel p+1 needs no S_CALC cycle of its own.
    // GATH_NEG_CALC_PER_PIXEL runs S_CALC for every pixel instead.
    wire [25:0] byte_nx    = byte_q + byte_step;
    wire [15:0] target_n   = byte_nx[25:WBL] + 16'd1;
    wire [WBL-1:0] need_s_n = byte_nx[WBL-1:0];
    wire        fits_one_n = ({2'd0, need_s_n} + {1'b0, run_now}) <= 9'd128;
    wire        hit_n      = src_ok && lo_ok && (hi_idx == target_n);
`ifdef GATH_NEG_NO_VA
    wire        va_stop_n  = 1'b0;
`else
    wire        va_stop_n  = fits_one_n && src_ok && (hi_idx == (target_n - 16'd1));
`endif
    wire        slide_n    = src_ok && ((hi_idx + 16'd1) == target_n);
    wire [15:0] rd_idx_n   = slide_n ? target_n : (target_n - 16'd1);

    // Invariant: a cache hit needs `lo == word(hi_idx - 1)`. Stopping early on a
    // one-word run leaves `lo` stale while hi_idx moves, so lo_ok records
    // whether the invariant holds, and a hit requires it. A slide rewrites `lo`
    // from `hi`, so it does not need the check.

    // ---- state machine ----
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            rb_re <= 1'b0; rb_re_d <= 1'b0; primed <= 1'b0; p <= 2'd0;
            byte_q <= 26'd0; lpad_q <= 1'b0;
            lo_ok <= 1'b0; hi_only <= 1'b0;
        end else begin
            done    <= 1'b0;
            rb_re   <= 1'b0;
            rb_re_d <= rb_re;

            case (st)
                S_IDLE: if (req) begin
                    busy <= 1'b1; p <= 2'd0; st <= S_CALC;
                    byte_q <= byte_st0;      // the one multiply, given its own cycle
                    lpad_q <= (xg == 10'd0); // x_abs0 == 0
                end

                // S_CALC: pixel 0 of a request (all pixels under
                // GATH_NEG_CALC_PER_PIXEL)
                S_CALC: begin
                    need_w  <= byte_st[25:WBL];
                    need_s  <= byte_st[WBL-1:0];
                    target  <= byte_st[25:WBL] + 16'd1;
                    run_len <= run_now;
                    last_j  <= last_now;
                    // Blank this pixel's chunks. S_EMIT stops at last_j, so the
                    // chunks past the run must already be zero. chunk_word is zero
                    // outside S_EMIT, so this is a write enable, not a data mux.
                    for (bz = 0; bz < NCH; bz = bz + 1)
                        acc[{p, bz[1:0]}] <= chunk_word;
                    r_stem  <= stem;
                    // GATH_NEG_NO_LPAD: never shift the stem lane mapping at the left edge
`ifdef GATH_NEG_NO_LPAD
                    r_lpad  <= 1'b0;
`else
                    r_lpad  <= stem && lpad_w;
`endif
                    j       <= 2'd0;
                    // FUSE_NEG_FETCH_LATE: always go through S_FETCH
`ifdef FUSE_NEG_FETCH_LATE
                    st      <= S_FETCH;
`else
                    if (hit_c) begin
                        hi_only <= 1'b0;
                        st      <= S_EMIT;
                    end else if (va_stop_c) begin
                        hi_only <= 1'b1;
                        st      <= S_EMIT;
                    end else begin
                        rb_word  <= rd_idx_c;
                        pend_idx <= rd_idx_c;
                        rb_re    <= 1'b1;
                        st       <= S_WAIT;
                    end
`endif
                end

                S_FETCH: begin
                    if (src_ok && lo_ok && (hi_idx == target)) begin
                        hi_only <= 1'b0;
                        st      <= S_EMIT;
                    end else if (va_stop) begin
                        // the word is already in `hi`; index the funnel there
                        hi_only <= 1'b1;
                        st      <= S_EMIT;
                    end else begin
                        rb_word  <= rd_idx;
                        pend_idx <= rd_idx;
                        rb_re    <= 1'b1;
                        st       <= S_WAIT;
                    end
                end

                S_WAIT: if (rb_re_d) begin
                    lo     <= hi;
                    hi     <= rb_data;
                    hi_idx <= pend_idx;
                    primed <= 1'b1;
                    // `lo` becomes the old `hi`, so lo == word(hi_idx - 1) holds
                    // only if this read stepped by exactly one word.
                    lo_ok  <= (pend_idx == (hi_idx + 16'd1));
                    // the tag goes with the data
                    src_q  <= src;
                    // FUSE_NEG_WAIT_LATE: always go through S_FETCH
`ifdef FUSE_NEG_WAIT_LATE
                    st     <= S_FETCH;
`else
                    if (w_hit) begin
                        hi_only <= 1'b0;
                        st      <= S_EMIT;
                    end else if (w_vastop) begin
                        hi_only <= 1'b1;
                        st      <= S_EMIT;
                    end else begin
                        rb_word  <= w_rd_idx;
                        pend_idx <= w_rd_idx;
                        rb_re    <= 1'b1;
                        st       <= S_WAIT;
                    end
`endif
                end

                S_EMIT: begin
                    // One register per (pixel, chunk), written by index. A
                    // variable part-select into one wide register would make
                    // the write data a barrel shift.
                    acc[{p, j}] <= chunk_word;
                    if (j == last_j) begin
                        j <= 2'd0;
                        // The last chunk lands at the end of this cycle and
                        // `done` is a register, so it rises in the first cycle
                        // act_data is complete. busy and done change together.
                        if (p == PIX[1:0] - 2'd1) begin
`ifdef GATH_NEG_DONE_STATE
                            st <= S_DONE;
`else
                            busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
`endif
                        end
                        else begin
                            p <= p + 2'd1;
                            byte_q <= byte_nx;
                            lpad_q <= 1'b0;
`ifdef GATH_NEG_CALC_PER_PIXEL
                            st <= S_CALC;
`else
                            // S_CALC's body for pixel p+1
                            need_w  <= byte_nx[25:WBL];
                            need_s  <= need_s_n;
                            target  <= target_n;
                            run_len <= run_now;
                            last_j  <= last_now;
                            // Blank pixel p+1's chunks. chunk_word is live data
                            // in S_EMIT, so the zero is written as a literal.
                            // acc[{p, j}] above is a different register from
                            // acc[{p+1, *}], so the writes do not collide.
                            for (bz = 0; bz < NCH; bz = bz + 1)
                                acc[{p + 2'd1, bz[1:0]}] <= {(CHUNK*8){1'b0}};
                            r_stem  <= stem;
                            r_lpad  <= 1'b0;   // lpad is only ever x_abs == 0
                            j       <= 2'd0;
                            if (hit_n) begin
                                hi_only <= 1'b0;
                                st      <= S_EMIT;
                            end else if (va_stop_n) begin
                                hi_only <= 1'b1;
                                st      <= S_EMIT;
                            end else begin
                                rb_word  <= rd_idx_n;
                                pend_idx <= rd_idx_n;
                                rb_re    <= 1'b1;
                                st       <= S_WAIT;
                            end
`endif
                        end
                    end else begin
                        j <= j + 2'd1;
                    end
                end

                default: begin                   // S_DONE
                    busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                end
            endcase
        end
    end

    // ---- simulation checks ----
    // A request while busy is dropped, so it is a fatal error in simulation.
`ifndef SYNTHESIS
    always @(posedge clk) if (!rst)
        if ((req === 1'b1) && (busy === 1'b1)) begin
            $display("*** twn_act_gather: request while busy -- DROPPED, there is no queue ***");
            $fatal(1);
        end
`endif

    // The inputs are read at several points of a service (S_IDLE, S_CALC, each
    // pixel's last S_EMIT, and `src` at each read decision), so the caller must
    // hold xg, seg, stem_pad_row and src from the req cycle until done. This
    // check counts violations in unstable_n and prints the first few; it does not
    // $fatal.
`ifndef SYNTHESIS
    reg [10:0] hold_src;
    reg [9:0]  hold_xg;
    reg [2:0]  hold_seg;
    reg        hold_pad;
    reg        hold_v;
    reg [31:0] unstable_n;              // read hierarchically by testbenches
    always @(posedge clk) begin
        if (rst) begin
            hold_v <= 1'b0; unstable_n <= 32'd0;
        end else if ((st == S_IDLE) && req) begin
            hold_src <= src;  hold_xg  <= xg;
            hold_seg <= seg;  hold_pad <= stem_pad_row;
            hold_v   <= 1'b1;
        end else if (!busy) hold_v <= 1'b0;
        else if (hold_v &&
                 ((src !== hold_src) || (xg  !== hold_xg) ||
                  (seg !== hold_seg) || (stem_pad_row !== hold_pad))) begin
            unstable_n <= unstable_n + 32'd1;
            if (unstable_n < 32'd8)
                $display("*** twn_act_gather: an input MOVED during a service -- the word being assembled belongs to two different requests. src %0d->%0d  xg %0d->%0d  seg %0d->%0d  stem_pad_row %0b->%0b ***",
                         hold_src, src, hold_xg, xg, hold_seg, seg,
                         hold_pad, stem_pad_row);
        end
    end
`endif

endmodule
`default_nettype wire
