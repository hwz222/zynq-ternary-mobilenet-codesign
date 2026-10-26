// ============================================================================
//  twn_fuse_array.v -- the ternary multiply-free array of the fused block
//  engine: sequencer, activation prefetch, select -> adder tree -> cross-segment
//  accumulate -> requant, and output addressing.
//
//  One instance serves both ternary convolutions of a block (expand and
//  project); the micro-op (`uop`) supplies base addresses, so the datapath is
//  the same. Terms used below:
//    pixel group (xg)   PIX output pixels processed together
//    segment (seg)      a slice of up to 128 input channels (for the stem, a
//                       kernel row); one 128-lane activation word per pixel
//    output-channel group (ocg)
//                       the output channels produced by one weight word; each
//                       weight word has 128 lanes of 2-bit ternary codes
//    pack               output channels per weight word (1, 2 or 4)
//    tag                the 24-bit control word {0, run, xg, seg, ocg} that
//                       travels through the datapath registers with the data
//    bank               one entry of the activation hold register (act_hold)
//
//  Loop order for a micro-op (normal stages):
//      for xg:  for seg:  hold this (xg, seg) activation word;
//                         for ocg: accumulate into ocg's accumulator entry
//      on the last segment, requant and emit
//  Stages for which `seg_outer` is true (the stem: pack > 1 and n_seg > 1, not
//  msg) swap the two outer loops, so seg is outer and xg inner.
//
//  Protocol: uop_valid starts a micro-op while idle; busy is high until done
//  pulses once after the pipeline has drained. Activation words are fetched
//  with a request/ready/valid handshake (act_re/act_ready/act_valid); up to
//  NBANK words are held ahead of the one being consumed. A stall holds the loop
//  at the last ocg until the next word has arrived.
//
//  Requant constants are read pack-wide: the table holds OCMAX channels per
//  word, so rq_addr is channel/4 and a lane rotate selects the group's first
//  channel. See the requant-address section.
//
//  act_data carries PIX pixels already gathered into one word; the producer
//  handles stride (the array does not).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module twn_fuse_array #(
    parameter integer LANES = 128,
    parameter integer PIX   = 4,
    parameter integer OCMAX = 4,        // maximum pack; requant lanes per pixel
    parameter integer ACCD  = 1024,     // depth of the narrow accumulator memory
    parameter integer ACCAW = 10,       // accumulator index width
    parameter integer TAGW  = 24,
    // RQ_SPLIT: extra register stage inside twn_fuse_requant (see its SPLIT)
    parameter integer RQ_SPLIT = 1,
    // ACC_SPLIT: one register between the accumulate sum and the requant input;
    // the requant constants' address is delayed by one register to match
    parameter integer ACC_SPLIT = 1
)(
    input  wire                       clk,
    input  wire                       rst,
    // ---- micro-instruction ----
    input  wire [94:0]                uop,
    input  wire                       uop_valid,
    output wire                       busy,
    output reg                        done,
    // ---- activations: PIX pixels of one segment, already gathered ----
    //   act_re    one-cycle request, raised only when act_ready was high
    //   act_ready the producer is idle and will accept a request
    //   act_valid the requested word is on act_data this cycle; it is latched
    //             on this and on nothing else
    output reg  [16:0]                act_addr,
    output reg                        act_re,
    input  wire [PIX*LANES*8-1:0]     act_data,
    input  wire                       act_ready,
    input  wire                       act_valid,
    // ---- ternary weights: one 128-lane word per cycle ----
    output reg  [17:0]                w_addr,
    output wire                       w_re,
    input  wire [LANES*2-1:0]         w_data,
    // ---- requant constants, pack-wide: OCMAX consecutive channels per word ----
    output reg  [12:0]                rq_addr,
    input  wire [OCMAX*18-1:0]        rq_m0,
    input  wire [OCMAX*40-1:0]        rq_bias,
    input  wire [OCMAX*6-1:0]         rq_sh,
    // ---- output: PIX pixels x up to OCMAX channels ----
    output reg  [PIX*OCMAX*8-1:0]     out_data,
    output reg                        out_valid,
    output reg  [16:0]                out_addr,
    // Position of the word being requested / emitted, for the gather and the
    // scatter. act_xg/act_seg describe the outstanding request (registered at
    // the request, held until served), not the live loop counters.
    output wire [8:0]                 act_xg,
    output wire [2:0]                 act_seg,
    output reg  [8:0]                 out_xg,
    output reg  [9:0]                 out_ocg,
`ifdef FUSE_EARLY_PRIME
    output reg                        out_dst,   // 0 = expand ring, 1 = block-output ring
    // high from the previous row's arr_done until the scatter's flush_done;
    // only S_RUN honours it, S_PRIME does not
    input  wire                       scat_hold
`else
    output reg                        out_dst    // 0 = expand ring, 1 = block-output ring
`endif
);
    // ---- uop decode ---------------------------------------------------------
    // n_ocg is 10 bits (up to 960 groups at pack 1) and n_seg is stored minus
    // one (3 bits cover 1..8 segments).
    wire        u_role     = uop[0];
    wire [8:0]  u_row      = uop[9:1];
    wire [8:0]  u_npix     = uop[18:10];
    wire [2:0]  u_nseg_m1  = uop[21:19];
    wire [9:0]  u_nocg     = uop[31:22];
    wire [1:0]  u_pack     = uop[33:32];
    wire [16:0] u_actbase  = uop[50:34];
    wire [17:0] u_wbase    = uop[68:51];
    wire [12:0] u_rqbase   = uop[81:69];
    wire        u_relu     = uop[82];
    wire [1:0]  u_otype    = uop[84:83];
    wire        u_dst      = uop[85];
    // Bits 86 and 87 are driven by the uop encoder as valid flags and are not
    // read here. u_pack0 is segment 0's pack, which may differ from u_pack when
    // the stage has a short first segment; 0 means "same as u_pack".
    wire [1:0]  u_pack0    = uop[89:88];
    // u_msg: mixed-segment mode (segments are 32-channel chunks of one word)
    wire        u_msg      = uop[90];

    reg         r_relu, r_dst;
    reg  [8:0]  r_npix;
    reg  [2:0]  r_nseg_m1;      // n_seg - 1
    reg  [9:0]  r_nocg;
    reg  [1:0]  r_pack0;        // segment 0's pack
    // ceil(log2(n_ocg)), so the accumulator index can be (xg << r_ocgsh) + ocg
    // without a multiply
    reg  [3:0]  r_ocgsh;
    reg  [17:0] r_wtail;        // where this stage's packed tail words start
    reg  [1:0]  r_pack, r_otype;
    reg  [16:0] r_actbase;
    reg  [17:0] r_wbase;
    reg  [12:0] r_rqbase;
    reg  [8:0]  r_nxg;

    // A tail-packed stage: segment 0 (a short segment) is packed more tightly
    // than the rest. Declared here because act_seg, the weight address rule and
    // the accumulator shape all read it.
    wire       tailpack = (r_pack0 != r_pack);

    // ---- sequencer ----------------------------------------------------------
    // S_PRIME requests the first activation word and waits for it to arrive.
    // S_RUN walks the loops, prefetching ahead. S_DRAIN waits for the pipeline.
    localparam S_IDLE = 2'd0, S_PRIME = 2'd1, S_RUN = 2'd2, S_DRAIN = 2'd3;

    // Number of banks in the activation hold register (words that may be ahead).
`ifdef FUSE_NEG_BANK2
    localparam integer NBANK = 2;
    localparam integer BW    = 1;
`else
    localparam integer NBANK = 4;
    localparam integer BW    = 2;
`endif
    reg [1:0] st;
    reg [8:0] xg;
    reg [2:0] seg;
    reg [9:0] ocg;
    reg [BW-1:0] bank;                    // which bank of act_hold is being read
    reg [2:0] n_arr;                      // words arrived and not yet consumed
    reg [8:0] p_xg;                       // prefetch pointer: runs ahead of
    reg [2:0] p_seg;                      // (xg, seg) by up to NBANK-1 words
    reg       p_stop;                     // the last word has been requested
    reg [5:0] drain;
    reg       r_msg;      // this micro-op is mixed-segment packed

    // ---- drain length ------------------------------------------------------
    // After the last issue the pipeline holds tag_w, select (1), tree (4),
    // sum_r (1), requant (3 + RQ_SPLIT) and the output register: 12 stages at
    // the default parameters.
    localparam integer DRAIN_N = 12;
`ifdef FUSE_NEG_DRAIN24
    localparam [5:0] DRAIN_LAST = 6'd24;  // negative-test arm: longer drain
`else
    localparam [5:0] DRAIN_LAST = DRAIN_N;
`endif

    // ---- the activation handshake -------------------------------------------
    reg        pref_want;                 // wanted, not yet requested
    reg        pend;                      // requested, not yet arrived
    reg [16:0] nx_addr;                   // what to ask for, latched when the
    reg [8:0]  nx_xg;                     // want is raised (the counters move on
    reg [2:0]  nx_seg;                    // while the producer is not ready)
    reg [8:0]  req_xg;                    // what was asked for, held until served
    reg [2:0]  req_seg;
    reg [BW-1:0] fill;                    // which bank the outstanding read fills

    assign act_xg  = req_xg;
    // The gather wants the physical segment. A tail-packed stage walks its
    // short segment (physically last) first, as logical segment 0, so the
    // logical order is rotated by one: logical 0 -> last, logical L -> L-1.
    // An msg stage asks for the same word every segment (its segments are
    // chunks inside one word), so it reports segment 0.
    assign act_seg = r_msg    ? 3'd0
                   : tailpack ? ((req_seg == 3'd0) ? r_nseg_m1 : (req_seg - 3'd1))
                              : req_seg;

    assign busy = (st != S_IDLE);
    assign w_re = (st == S_RUN);

    // Number of ocg beats for the segment now in force. u_nocg already has the
    // stage's pack divided out, so segment 0 of a tail-packed stage divides
    // only by the extra packing, pack0 - pack (zero when not tail-packed).
    wire [1:0] pack0_dx  = r_pack0 - r_pack;
    wire [9:0] nocg_eff  = (seg == 3'd0) ? (r_nocg >> pack0_dx) : r_nocg;
    wire last_ocg = (ocg == nocg_eff - 10'd1);
    wire last_seg = (seg == r_nseg_m1);
    wire last_xg  = (xg  == r_nxg  - 9'd1);

    // seg_outer: segment is the outer loop (stem only). The stem's segments are
    // kernel rows, and walking one row across the whole output row lets the
    // gather's window slide. An msg stage also has pack > 1 and n_seg > 1 but
    // its segments are chunks of one word, so it keeps the normal order.
`ifdef FUSE_NEG_SEGOUTER
    wire seg_outer = 1'b0;      // negative-test arm: never segment-outer
`else
    wire seg_outer = (r_pack != 2'd0) && (r_nseg_m1 != 3'd0) && !r_msg;
`endif

    // the next word is in act_hold: neither still wanted nor still outstanding
    wire nxt_here = !pref_want && !pend;

    // stall: hold the loop at the last ocg until two words have arrived (the
    // one being read and the next). The row's last word has no successor.
`ifdef FUSE_NEG_ACT_NOWAIT
    wire stall    = 1'b0;     // negative-test arm: never wait
`else
`ifdef FUSE_NEG_BANK2
    wire stall    = (st == S_RUN) && last_ocg && !nxt_here;
`else
    wire stall    = (st == S_RUN) && last_ocg && (n_arr < 3'd2)
                    && !(last_seg && last_xg);
`endif
    // run_hold is what advances S_RUN; stall alone is the activation-word wait.
`ifdef FUSE_EARLY_PRIME
    wire run_hold = stall || ((st == S_RUN) && scat_hold);
`else
    wire run_hold = stall;
`endif
    wire consume  = (st == S_RUN) && !run_hold && last_ocg;
`endif

    // The prefetch is a latched want (pref_want holds until the request is
    // issued), not a one-cycle edge, so a busy producer cannot lose it.
`ifdef FUSE_NEG_BANK2
    wire want_now = (st == S_RUN) && (ocg == 10'd0) && nxt_here
                    && !(last_seg && last_xg);
`else
    // ask whenever a bank is free and nothing is outstanding
    wire want_now = (st == S_RUN) && !p_stop && !pref_want && !pend
                    && (n_arr < NBANK[2:0]);
`endif
    // Issue only into a producer that is ready; twn_act_gather ignores a
    // request that arrives while it is busy.
`ifdef FUSE_NEG_ACT_NOREADY
    wire issue = pref_want && !pend;      // negative-test arm: ignore act_ready
`else
    wire issue = pref_want && !pend && act_ready;
`endif

    // Prefetch pointer: the same advance rule as the consumption pointer
    // (nxt_xg / nxt_seg below), applied to (p_xg, p_seg) on each issue.
    wire p_last_seg = (p_seg == r_nseg_m1);
    wire p_last_xg  = (p_xg  == r_nxg - 9'd1);
    wire p_at_end   = p_last_seg && p_last_xg;
    wire [2:0] p_nseg = seg_outer ? (p_last_xg  ? (p_seg + 3'd1) : p_seg)
                                  : (p_last_seg ? 3'd0 : (p_seg + 3'd1));
    wire [8:0] p_nxg  = seg_outer ? (p_last_xg  ? 9'd0 : (p_xg + 9'd1))
                                  : (p_last_seg ? (p_xg + 9'd1) : p_xg);
    // an msg stage's segment is a chunk inside one word, so it adds no offset
    wire [17:0] p_off  = r_msg ? 18'd0 : ({9'd0, p_seg} * {9'd0, r_nxg});
    wire [16:0] p_addr = r_actbase + p_off[16:0] + {8'd0, p_xg};

    // next (xg, seg) of the consumption pointer: seg inner normally, xg inner
    // when seg_outer
    wire [2:0] nxt_seg = seg_outer ? (last_xg  ? (seg + 3'd1) : seg)
                                   : (last_seg ? 3'd0 : (seg + 3'd1));
    wire [8:0] nxt_xg  = seg_outer ? (last_xg  ? 9'd0 : (xg + 9'd1))
                                   : (last_seg ? (xg + 9'd1) : xg);
    // address of the next word (used by the two-bank arm); widths truncate to
    // the 17-bit port
    wire [17:0] act_off  = r_msg ? 18'd0 : ({9'd0, nxt_seg} * {9'd0, r_nxg});
    wire [16:0] act_next = r_actbase + act_off[16:0] + {8'd0, nxt_xg};

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; done <= 1'b0; drain <= 6'd0; act_re <= 1'b0;
            r_msg <= 1'b0;
            bank <= {BW{1'b0}}; fill <= {BW{1'b0}};
            pref_want <= 1'b0; pend <= 1'b0;
            n_arr <= 3'd0; p_xg <= 9'd0; p_seg <= 3'd0; p_stop <= 1'b0;
        end else begin
            done   <= 1'b0;
            act_re <= 1'b0;

            // ---- the handshake ---------------------------------------------
            // The clear of pend is written before the set so that a collision
            // would hold the request rather than lose it. They cannot coincide:
            // issue needs !pend and act_valid implies pend (asserted at the end
            // of the file).
            if (act_valid) pend <= 1'b0;
            // arrival and consumption on the same edge are resolved together
            if (act_valid && !consume)      n_arr <= n_arr + 3'd1;
            else if (!act_valid && consume) n_arr <= n_arr - 3'd1;
            if (want_now) begin
                pref_want <= 1'b1;
`ifdef FUSE_NEG_BANK2
                nx_addr   <= act_next;
                nx_xg     <= nxt_xg;
                nx_seg    <= nxt_seg;
`else
                // the prefetch pointer's current position
                nx_addr   <= p_addr;
                nx_xg     <= p_xg;
                nx_seg    <= p_seg;
`endif
            end
            if (issue) begin
                act_re    <= 1'b1;
                act_addr  <= nx_addr;
                req_xg    <= nx_xg;
                req_seg   <= nx_seg;
                // the bank this read will fill; in S_PRIME it is bank 0
                fill      <= (st == S_RUN) ? (fill + 1'b1) : {BW{1'b0}};
                pref_want <= 1'b0;
                pend      <= 1'b1;
                // the prefetch pointer moves on the request; p_stop latches once
                // the row's last word has been asked for
                if (p_at_end) p_stop <= 1'b1;
                else begin p_xg <= p_nxg; p_seg <= p_nseg; end
            end

            case (st)
                S_IDLE: if (uop_valid) begin
                    r_npix    <= u_npix;   r_nseg_m1 <= u_nseg_m1;  r_nocg <= u_nocg;
                    r_pack    <= u_pack;   r_relu  <= u_relu;  r_otype <= u_otype;
                    r_msg     <= u_msg;
                    // ceil(log2(n_ocg)), computed once per micro-op
                    r_ocgsh   <= (u_nocg <= 10'd1)   ? 4'd0 :
                                 (u_nocg <= 10'd2)   ? 4'd1 :
                                 (u_nocg <= 10'd4)   ? 4'd2 :
                                 (u_nocg <= 10'd8)   ? 4'd3 :
                                 (u_nocg <= 10'd16)  ? 4'd4 :
                                 (u_nocg <= 10'd32)  ? 4'd5 :
                                 (u_nocg <= 10'd64)  ? 4'd6 :
                                 (u_nocg <= 10'd128) ? 4'd7 :
                                 (u_nocg <= 10'd256) ? 4'd8 :
                                 (u_nocg <= 10'd512) ? 4'd9 : 4'd10;
`ifdef FUSE_NEG_TAILPACK
                    r_pack0   <= u_pack;   // negative-test arm: no tail packing
`else
                    // u_pack0 == 0 means "not specified": use the stage's pack
                    r_pack0   <= (u_pack0 == 2'd0) ? u_pack : u_pack0;
`endif
                    r_actbase <= u_actbase; r_wbase <= u_wbase; r_rqbase <= u_rqbase;
                    r_dst     <= u_dst;
                    r_nxg     <= (u_npix + PIX[8:0] - 9'd1) / PIX[8:0];
                    // The packed tail weight words are appended after the
                    // stage's own n_ocg * n_seg words. All operands are widened
                    // to 18 bits before the multiply: inside a concatenation the
                    // product would be sized to its widest operand and truncate.
                    // (u_nseg_m1 + 1) is widened too, as n_seg can be 8.
                    r_wtail   <= u_wbase + ({8'd0, u_nocg} * ({15'd0, u_nseg_m1} + 18'd1));
                    xg <= 9'd0; seg <= 3'd0; ocg <= 10'd0; bank <= {BW{1'b0}};
                    // the prefetch pointer starts at the first word, which the
                    // prime request below asks for
                    p_xg <= 9'd0; p_seg <= 3'd0; p_stop <= 1'b0; n_arr <= 3'd0;
                    pref_want <= 1'b1;
                    nx_addr   <= u_actbase;
                    nx_xg     <= 9'd0;
                    nx_seg    <= 3'd0;
                    st <= S_PRIME;
                end
                // S_PRIME leaves when the first word has arrived.
                S_PRIME: begin
                    // logical segment 0 of a tail-packed stage is the packed
                    // tail, a contiguous run; otherwise the stage's first word
                    w_addr <= tailpack ? r_wtail : r_wbase;
                    ocg    <= 10'd0;
                    if (nxt_here) st <= S_RUN;
                end
                S_RUN: if (!run_hold) begin
                    if (last_ocg) begin
                        ocg  <= 10'd0;
                        bank <= bank + 1'b1;
                        seg  <= nxt_seg;
                        // weight base for the next segment, group 0. Logical
                        // segment L >= 1 of a tail-packed stage is physical
                        // segment L-1; logical 0 is the appended tail.
                        w_addr <= tailpack
                                  ? ((nxt_seg == 3'd0)
                                     ? r_wtail
                                     : (r_wbase + {15'd0, (nxt_seg - 3'd1)}))
                                  : (r_wbase + {15'd0, nxt_seg});
                        // The inner index always advances, the outer one when the
                        // inner wraps; the row ends when both are last.
                        if (seg_outer) begin
                            xg <= nxt_xg;
                            if (last_xg && last_seg) begin st <= S_DRAIN; drain <= 6'd0; end
                        end else if (last_seg) begin
                            xg <= nxt_xg;
                            if (last_xg) begin st <= S_DRAIN; drain <= 6'd0; end
                        end
                    end else begin
                        ocg    <= ocg + 10'd1;
                        // the packed tail has stride 1; other segments are
                        // interleaved with stride n_seg
                        w_addr <= (tailpack && (seg == 3'd0))
                                  ? (w_addr + 18'd1)
                                  : (w_addr + {14'd0, r_nseg_m1} + 18'd1);
                    end
                end
                S_DRAIN: begin
                    if (drain == DRAIN_LAST) begin st <= S_IDLE; done <= 1'b1; end
                    else drain <= drain + 6'd1;
                end
            endcase
        end
    end

    // ---- activation hold: NBANK banks ---------------------------------------
    // Latched on act_valid into the bank chosen at issue (`fill`); only one
    // request is outstanding at a time, so fill cannot move before the valid.
    reg [PIX*LANES*8-1:0] act_hold [0:NBANK-1];
    always @(posedge clk) if (act_valid) act_hold[fill] <= act_data;
    // bank advances when the ocg loop wraps, but the last group's weight word is
    // consumed one cycle later, so the read uses a delayed copy
    reg [BW-1:0] bank_d;
    always @(posedge clk) bank_d <= bank;
    wire [PIX*LANES*8-1:0] act_live = act_hold[bank_d];

    // ---- datapath -----------------------------------------------------------
    wire [PIX*LANES*8-1:0] sel;
    wire [LANES-1:0]       neg;
    // tag_w is the control that belongs with w_data (the weight memory answers
    // one cycle after w_addr). It is the only hand-counted delay; later stages
    // carry the tag in their own registers. The run bit is suppressed while the
    // array stalls, since the counters freeze but this register does not, and a
    // repeated tag would repeat the accumulator update.
    reg [TAGW-1:0] tag_w;
    always @(posedge clk)
        tag_w <= {1'b0, (st == S_RUN) && !stall && !rst, xg, seg, ocg};

    wire [TAGW-1:0] tag_s, tag_o, tag_rq;

    // The pack applies per beat, not to whatever the sequencer is issuing now:
    // beats of segment 0 use r_pack0, others r_pack. Each consumer derives it
    // from the tag of the beat it holds (tag_w for the select, tag_s for the tree).
    wire [1:0] pack_w    = (tag_w[12:10] == 3'd0) ? r_pack0 : r_pack;
    wire [1:0] pack_s    = (tag_s[12:10] == 3'd0) ? r_pack0 : r_pack;
    twn_fuse_select #(.LANES(LANES), .PIX(PIX), .OCMAX(OCMAX), .TAGW(TAGW)) u_sel (
        .clk(clk), .ce(1'b1), .pack(pack_w),
        .msg(r_msg), .seg(tag_w[11:10]),
        .act_word(act_live), .w_code(w_data), .tag_i(tag_w),
        .sel_q(sel), .neg_q(neg), .tag_q(tag_s));

    wire [OCMAX*32-1:0] psum [0:PIX-1];
    genvar p, j;
    generate for (p = 0; p < PIX; p = p + 1) begin : G_TREE
        wire [TAGW-1:0] tg_o, tg_rq;
        twn_fuse_tree #(.LANES(LANES), .OCMAX(OCMAX), .TAGW(TAGW)) u_tree (
            .clk(clk), .ce(1'b1), .pack(pack_s),
            .sel(sel[p*LANES*8 +: LANES*8]), .neg(neg), .tag_i(tag_s),
            .psum(psum[p]), .tag_o(tg_o), .tag_rq(tg_rq));
    end endgenerate
    // every pixel's tree carries the same tag; take pixel 0's
    assign tag_o  = G_TREE[0].tg_o;
    assign tag_rq = G_TREE[0].tg_rq;

    wire        d_run = tag_o[22];
    wire [8:0]  d_xg  = tag_o[21:13];
    wire [2:0]  d_seg = tag_o[12:10];
    wire [9:0]  d_ocg = tag_o[9:0];
    // Accumulator entry index. Normally one entry per ocg is enough (a pixel
    // group finishes all its segments before the next starts). With seg_outer a
    // whole output row is in flight, so the entry is (xg << r_ocgsh) + ocg.
    wire [ACCAW-1:0] acc_ix_w = seg_outer
        ? (({1'd0, d_xg} << r_ocgsh) + {{(ACCAW-10){1'b0}}, d_ocg})
        : {{(ACCAW-10){1'b0}}, d_ocg};

    // ---- requant constants: addressed late ----------------------------------
    // The weight word enters the pipeline several stages before the requant
    // needs its constants. Delaying the address (from tag_rq, which is already
    // two tree stages early) is cheaper than delaying the constants. ACC_SPLIT
    // delays the requant input by one more register, so the address gets one
    // more register too.
    //
    // The table is dense: OCMAX channels per word, indexed by channel, not by
    // ocg.
    //     ch0     = ocg * pack        the group's first output channel
    //     rq_addr = rq_base + ch0/4   the word that holds it
    //     sel     = ch0 % 4           its lane offset inside that word
    // A group never straddles two words: pack is 1, 2 or 4, all dividing 4, and
    // ch0 is a multiple of pack, so sel <= 4 - pack. (Pack 8 would break this.)
    wire [9:0]  rq_ocg  = tag_rq[9:0];
    // r_pack is the log2 code, so ocg * pack is a shift
    wire [12:0] rq_ch0  = {3'd0, rq_ocg} << r_pack;
    wire [12:0] rq_grp  = {2'd0, rq_ch0[12:2]};      // ch0 >> 2
    wire [1:0]  rq_sel_c = rq_ch0[1:0];              // ch0 & 3
`ifdef FUSE_NEG_RQ_OCG_WALK
    // negative-test arm: one table word per ocg instead of the dense layout
    wire [12:0] rq_grp_u = {3'd0, rq_ocg};
`else
    wire [12:0] rq_grp_u = rq_grp;
`endif
    // rq_sel_q tracks rq_addr; rq_sel_d2 is one register later, because the
    // table answers the cycle after the address and the rotate acts on the data
    reg [12:0] rq_addr_d;
    reg [1:0]  rq_sel_d, rq_sel_q, rq_sel_d2;
    always @(posedge clk) begin
        rq_addr_d  <= r_rqbase + rq_grp_u;
        rq_addr    <= ACC_SPLIT ? rq_addr_d : (r_rqbase + rq_grp_u);
        rq_sel_d   <= rq_sel_c;
        rq_sel_q   <= ACC_SPLIT ? rq_sel_d : rq_sel_c;
        rq_sel_d2  <= rq_sel_q;
    end

    // ---- cross-segment accumulators ----------------------------------------
    // Two memories, for the two shapes that need a carry between segments:
    //   narrow (u_acc_n): pack 1 stages with n_seg > 1; one 20-bit sum per
    //             pixel per entry
    //   wide   (u_acc_w): stages with pack > 1 (the stem) or tail-packed stages;
    //             OCMAX 20-bit sums per pixel per entry
    // With n_seg == 1 both are bypassed.
    wire acc_en  = (r_nseg_m1 != 3'd0);
    // A tail-packed stage writes like a wide stage (all OCMAX lanes of one entry
    // at segment 0) and reads one lane at a time, so it uses the wide memory.
    wire acc_wide = acc_en && ((r_pack != 2'd0) || tailpack);
    wire acc_narr = acc_en && (r_pack == 2'd0) && !tailpack;

    // Read address, registered so the data lands with psum. Only the ocg field
    // of the tag is taken (tag_rq[9:0]); a wider slice would pick up seg bits.
    // A tail-packed stage's wide entry g holds channels g*2^dx .. g*2^dx+2^dx-1,
    // so the channel index is shifted down by pack0_dx before reading. seg_outer
    // and tailpack are mutually exclusive (asserted below).
    reg  [ACCAW-1:0]  acc_ra_r;
    always @(posedge clk)
        acc_ra_r <= seg_outer
                    ? ((({1'd0, tag_rq[21:13]}) << r_ocgsh)
                       + {{(ACCAW-10){1'b0}}, tag_rq[9:0]})
                    : (tailpack ? (tag_rq[9:0] >> pack0_dx) : tag_rq[9:0]);
`ifndef SYNTHESIS
    always @(posedge clk) if (!rst && seg_outer && tailpack)
        $fatal(1, "twn_fuse_array: seg_outer and tailpack are both live -- they use the same accumulator index in two different ways");
`endif
    wire [ACCAW-1:0]  acc_ra = acc_ra_r;
    wire [PIX*20-1:0] accn_rd;
    reg  [PIX*20-1:0] accn_wd;
    reg               accn_we;
    reg  [ACCAW-1:0]  acc_wa;
    bram_sdp #(.W(PIX*20), .D(ACCD), .AW(ACCAW)) u_acc_n (
        .clk(clk), .we(accn_we), .wa(acc_wa), .wd(accn_wd), .ra(acc_ra), .rd(accn_rd));

    wire [PIX*OCMAX*20-1:0] accw_rd;
    reg  [PIX*OCMAX*20-1:0] accw_wd;
    reg                     accw_we;
    // wide memory: 256 entries in block RAM
    bram_sdp #(.W(PIX*OCMAX*20), .D(256), .AW(8), .MODE("block")) u_acc_w (
        .clk(clk), .we(accw_we), .wa(acc_wa[7:0]), .wd(accw_wd),
        .ra(acc_ra[7:0]), .rd(accw_rd));

    wire first_seg_d = (d_seg == 3'd0);
    wire last_seg_d  = (d_seg == r_nseg_m1);

    // carry[p][j]: what pixel p, channel-in-group j already has from earlier
    // segments (0 on the first segment or when n_seg == 1). The narrow memory
    // has only j = 0.
    // Wide lane holding this beat's carry: j for the stem; for a tail-packed
    // stage segment 0 wrote channel (ocg << pack0) + lane and later segments
    // walk one channel per beat, so the lane is d_ocg & (2^pack0 - 1).
    wire [OCMAX-1:0] tp_mask = ({{(OCMAX-1){1'b0}}, 1'b1} << r_pack0) - 1'b1;
    wire [$clog2(OCMAX)-1:0] tp_lane = d_ocg[$clog2(OCMAX)-1:0] & tp_mask[$clog2(OCMAX)-1:0];

    wire signed [31:0] carry [0:PIX-1][0:OCMAX-1];
    generate for (p = 0; p < PIX; p = p + 1) begin : G_CARRY
        for (j = 0; j < OCMAX; j = j + 1) begin : G_CARRYJ
            wire [19:0] wsel = accw_rd[(p*OCMAX + (tailpack ? tp_lane : j[$clog2(OCMAX)-1:0]))*20 +: 20];
            assign carry[p][j] =
                (!acc_en || first_seg_d) ? 32'sd0 :
                (tailpack && j != 0)     ? 32'sd0 :
                acc_wide ? {{12{wsel[19]}}, wsel} :
                (j == 0) ? {{12{accn_rd[p*20 + 19]}}, accn_rd[p*20 +: 20]} : 32'sd0;
        end
    end endgenerate

    wire signed [31:0] sum [0:PIX-1][0:OCMAX-1];
    generate for (p = 0; p < PIX; p = p + 1) begin : G_SUMP
        for (j = 0; j < OCMAX; j = j + 1) begin : G_SUMJ
            // Normally accumulator lane j takes tap j. In msg mode lane j takes
            // the tap of lane group (j - seg) mod 4, a rotation by the segment
            // index; the 2-bit index assumes OCMAX = 4.
            wire [1:0] rot_g = r_msg ? (j[1:0] - d_seg[1:0]) : j[1:0];
            wire [OCMAX*32-1:0] ps_p = psum[p];
            assign sum[p][j] = $signed(ps_p[{30'd0, rot_g}*32 +: 32])
                             + carry[p][j];
        end
    end endgenerate

    // Optional register between the sum and the requant (ACC_SPLIT). The
    // accumulator write stays on the unregistered sum.
    reg signed [19:0] sum_r [0:PIX-1][0:OCMAX-1];
    integer sp, sj;
    always @(posedge clk) begin
        for (sp = 0; sp < PIX; sp = sp + 1)
            for (sj = 0; sj < OCMAX; sj = sj + 1)
                sum_r[sp][sj] <= sum[sp][sj][19:0];
    end
    wire signed [19:0] sum_x [0:PIX-1][0:OCMAX-1];
    generate for (p = 0; p < PIX; p = p + 1) begin : G_SX
        for (j = 0; j < OCMAX; j = j + 1) begin : G_SXJ
            assign sum_x[p][j] = ACC_SPLIT ? sum_r[p][j] : sum[p][j][19:0];
        end
    end endgenerate

    integer w, wj;
    always @(posedge clk) begin
        // write back on every segment except the last (the last one is emitted)
        accn_we <= acc_narr && d_run && !last_seg_d;
        accw_we <= acc_wide && d_run && !last_seg_d;
        // The write index is d_ocg unshifted. For a tail-packed stage this is
        // right only for a write at segment 0 (d_ocg is then the group index);
        // an intermediate segment would need the shifted index and a per-lane
        // write, which u_acc_w does not have. It holds when the stage has two
        // segments, since the last segment is never written back.
        acc_wa  <= acc_ix_w;
        for (w = 0; w < PIX; w = w + 1) begin
            // 20 bits: the width of the requant input
            accn_wd[w*20 +: 20] <= sum[w][0][19:0];
            for (wj = 0; wj < OCMAX; wj = wj + 1)
                accw_wd[(w*OCMAX + wj)*20 +: 20] <= sum[w][wj][19:0];
        end
    end

    // ---- requant constants, rotated so lane 0 is this group's channel ------
    // The table word holds OCMAX consecutive channels; rq_sel_d2 is the offset
    // of this group's first channel inside it, so lane r takes field
    // (rq_sel_d2 + r) mod OCMAX. Lanes r >= pack are don't-care (twn_act_scatter
    // ignores them).
    wire [OCMAX*18-1:0] rqr_m0;
    wire [OCMAX*40-1:0] rqr_bias;
    wire [OCMAX*6-1:0]  rqr_sh;
    genvar r;
    generate for (r = 0; r < OCMAX; r = r + 1) begin : G_RQROT
`ifdef FUSE_NEG_NO_RQ_ROTATE
        // negative-test arm: no rotation
        wire [1:0] s = r;
`else
        wire [1:0] s = rq_sel_d2 + r;        // truncates to 2 bits = mod OCMAX
`endif
        assign rqr_m0  [r*18 +: 18] = rq_m0  [s*18 +: 18];
        assign rqr_bias[r*40 +: 40] = rq_bias[s*40 +: 40];
        assign rqr_sh  [r*6  +:  6] = rq_sh  [s*6  +:  6];
    end endgenerate

    // ---- requant: PIX x OCMAX lanes, each with its own constants ------------
    wire emit_d = d_run && (!acc_en || last_seg_d);
    wire signed [7:0] rqo [0:PIX-1][0:OCMAX-1];
    generate for (p = 0; p < PIX; p = p + 1) begin : G_RQP
        for (j = 0; j < OCMAX; j = j + 1) begin : G_RQJ
            twn_fuse_requant #(.SPLIT(RQ_SPLIT)) u_rq (
                .clk(clk), .ce(1'b1), .acc(sum_x[p][j]),
                .m0   ($signed(rqr_m0  [j*18 +: 18])),
                .bias ($signed(rqr_bias[j*40 +: 40])),
                .sh   (rqr_sh[j*6 +: 6]),
                .relu(r_relu), .otype(r_otype), .out(rqo[p][j]));
        end
    end endgenerate

    // ---- output alignment ---------------------------------------------------
    // The emit flag, ocg and xg ride RQD registers, matching the sum_r register
    // (ACC_SPLIT) and the requant depth (3 + RQ_SPLIT) by construction.
    localparam integer RQD = 3 + RQ_SPLIT + ACC_SPLIT;
    reg [RQD-1:0] emit_p;
    reg [9:0] ocg_p [0:RQD-1];
    reg [8:0] xg_p  [0:RQD-1];
    integer e;
    always @(posedge clk) begin
        emit_p   <= {emit_p[RQD-2:0], emit_d};
        ocg_p[0] <= d_ocg; xg_p[0] <= d_xg;
        for (e = 1; e < RQD; e = e + 1) begin
            ocg_p[e] <= ocg_p[e-1]; xg_p[e] <= xg_p[e-1];
        end
    end

    wire [17:0] out_off = {8'd0, ocg_p[RQD-1]} * {9'd0, r_nxg};
    integer op, oj;
    always @(posedge clk) begin
        out_valid <= emit_p[RQD-1];
        out_dst   <= r_dst;
        // output row buffer: one entry per (output-channel group, pixel group)
        out_addr  <= out_off[16:0] + {8'd0, xg_p[RQD-1]};
        out_xg    <= xg_p[RQD-1];
        out_ocg   <= ocg_p[RQD-1];
        for (op = 0; op < PIX; op = op + 1)
            for (oj = 0; oj < OCMAX; oj = oj + 1)
                out_data[(op*OCMAX + oj)*8 +: 8] <= rqo[op][oj];
    end

    // ---- simulation checks of the handshake ----------------------------------
    // X values are tolerated: act_valid and act_ready can be X for the first
    // cycles after reset.
`ifndef SYNTHESIS
    always @(posedge clk) if (!rst) begin
        if ((act_valid === 1'b1) && (pend !== 1'b1)) begin
            $display("*** twn_fuse_array: act_valid with no request outstanding ***");
            $fatal(1);
        end
        // not checked under the FUSE_NEG_ACT_NOREADY negative-test arm, which
        // needs the dropped request to reach the producer
`ifndef FUSE_NEG_ACT_NOREADY
        if ((act_re === 1'b1) && (act_ready === 1'b0)) begin
            $display("*** twn_fuse_array: request issued into a producer that is not ready -- it will be dropped ***");
            $fatal(1);
        end
`endif
    end
`endif

    // unused uop bits: role, row, the two valid flags at 86/87, and 90..94
    wire _unused = &{1'b0, u_role, u_row, uop[94:90], uop[87:86], 1'b0};
endmodule
`default_nettype wire
