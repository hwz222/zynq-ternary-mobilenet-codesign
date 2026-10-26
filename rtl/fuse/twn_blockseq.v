// ============================================================================
//  twn_blockseq.v -- block sequencer: schedules one backbone block, row by row.
//
//  A block has five stages. Each advances when its input rows are present and
//  its output buffer has room (credits come from the row buffers' wptr / free):
//
//      LD  load an input row from DDR       -> input ring     (in_*)
//      E   expand conv, one row             -> expand ring    (t1_*)  } share the
//      D   3x3 depthwise, one row           -> depthwise ring (dw_*)  } ternary
//      P   project conv, one row            -> output buffer  (out_*) } array
//      ST  store an output row to DDR
//
//  E and P are served one at a time by the single ternary array; D has its own
//  engine and runs in parallel with it. For block 0 (`stem`) the expand is a
//  3x3 stride-2 convolution: it consumes two input rows per output row and
//  halves the width.
//
//  Protocol: pulse `start` (one block); `busy` stays high until `done` pulses
//  for one cycle. *_req are request levels to each stage's master, *_done are
//  that master's row-complete pulses; *_row count completed rows.
//
//  Grants are per row: whichever stage wins starts a row and keeps ownership
//  (own_*) until its done pulse. Buffer levels and credits decide who starts
//  next, never who continues.
//
//  Row rules:
//    D may start output row r when  t1_wptr >= min(r*s_dw + 2, h_mid)  and the
//    depthwise ring has counted every row D has finished (dw_wptr >= d_row).
//    After D finishes row r, the expand ring's read pointer becomes
//    max(0, s_dw*(r+1) - 1).
//
//  Arbitration between E and P: P wins when it can run and either E cannot,
//  the expand ring is full, or E's credit is exhausted. Credits are in rows
//  (E gets 2 rows per P row at stride 2, else 1) and break ties only.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_blockseq #(
    parameter integer PIX      = 4,      // not used in this module
    parameter integer LANES    = 128,    // not used in this module
    parameter integer DW_LANES = 8,      // not used in this module
    // DEPTH of the residual buffer (twn_res_buf instance RESB in twn_fuse_top),
    // which has no credit wire; the loader's grant is limited here instead.
    parameter integer RES_DEPTH = 10
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    // Clears the performance counters. Driven per frame (ap_start), whereas
    // `start` is per block.
    input  wire cyc_clr,

    // ---- block descriptor ----
    input  wire [9:0]  c_in,
    input  wire [9:0]  c_mid,
    input  wire [9:0]  c_out,
    // h_in and the row counters are nine bits because block 0 has 256 input rows.
    input  wire [8:0]  h_in,
    input  wire [8:0]  w_in,
    input  wire        s_dw,        // depthwise stride: 0 = 1, 1 = 2
    input  wire        stem,        // 1 = the expand is the 3x3 stride-2 stem (block 0)
    input  wire [2:0]  pack_e,      // packing factor as a power-of-two exponent (0/1/2)
    input  wire [2:0]  pack_p,

    // ---- stage handshakes ----
    // ld_req, d_req and st_req are gated combinationally with the stage's done
    // pulse (see the assigns below): those masters latch a start whenever they
    // are idle and the request is up, so the request must already be low in the
    // cycle they report done. e_req and p_req are registered levels.
    output wire        ld_req,   input wire ld_done,
    output reg         e_req,    input wire e_done,
    output wire        d_req,    input wire d_done,
    output reg         p_req,    input wire p_done,
    output wire        st_req,   input wire st_done,
    output reg  [8:0]  e_row, d_row, p_row, ld_row, st_row,

    // ---- row buffer levels ----
    input  wire [9:0]  in_wptr,  input wire [9:0] in_free,
    input  wire [9:0]  t1_wptr,  input wire [9:0] t1_free,
    output reg  [9:0]  t1_rptr,   // this module's own copy of the expand ring's read pointer
    input  wire [9:0]  dw_wptr,  input wire [9:0] dw_free,
    input  wire [9:0]  out_free,
    // 1 if the block has a residual connection. The residual buffer holds the
    // block's input rows from p_row up to ld_row and has no credit wire, so for
    // blocks with a residual the loader is held to a distance below RES_DEPTH - 2
    // (see res_room).
    input  wire        has_res,

    output reg         busy,
    output reg         done,

    // ---- performance counters (cleared by cyc_clr, accumulate across blocks) ----
    output reg [31:0]  cyc_total,
    output reg [31:0]  cyc_array,     // cycles E or P held the array
    output reg [31:0]  cyc_dw,        // cycles D was granted
    output reg [31:0]  cyc_stall_mem, // cycles in which no stage could advance
    // Array idle cycles by phase, relative to the array's first and last grant
    // within each block:
    //   pre   before the first grant
    //   post  after the last grant (tail draining through D, P and the store)
    // The idle cycles between the two are split by cause below.
    output reg [31:0]  cyc_idle_pre,
    output reg [31:0]  cyc_idle_post,
    // Mid-block idle cycles by blocking condition; the counters can overlap.
    output reg [31:0]  why_e_ld,      // E waiting for input rows to arrive
    output reg [31:0]  why_e_t1full,  // E blocked: expand ring full
    output reg [31:0]  why_p_dw,      // P waiting for the depthwise to produce a row
    output reg [31:0]  why_p_outfull  // P blocked: output buffer full
);
    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;
    reg [1:0] st;

    // ---- row and width geometry ----
    // The loader loads h_in rows; the expand produces h_mid rows; the depthwise
    // and project produce h_out rows.
    wire [9:0] h_ld   = {1'b0, h_in};                       // rows to load
    wire [9:0] h_mid  = stem ? {2'b0, h_in[8:1]} : {1'b0, h_in};
    wire [9:0] h_out  = s_dw ? {1'b0, h_mid[9:1]} : h_mid;
    wire [8:0] w_out  = s_dw ? {1'b0, w_in[8:1]} : w_in;

    // ---- depthwise window: rows of the expand ring needed, capped at h_mid ----
    wire [10:0] d_thr_raw = (s_dw ? {1'b0, d_row, 1'b0} : {2'b0, d_row}) + 11'd2;
    wire [10:0] d_thr     = (d_thr_raw > {1'b0, h_mid}) ? {1'b0, h_mid} : d_thr_raw;
    wire        d_window  = ({1'b0, t1_wptr} >= d_thr);

    // ---- expand ring read pointer after D finishes row d_row ----
    wire [10:0] rp_raw  = s_dw ? {1'b0, d_row + 9'd1, 1'b0} : {2'b0, d_row + 9'd1};
    wire [9:0]  rp_next = (rp_raw == 11'd0) ? 10'd0 : rp_raw[9:0] - 10'd1;

    // ---- can-run conditions ----
    reg [3:0] cred_e, cred_p;
    wire e_more   = ({1'b0, e_row} < h_mid);
    // Input rows the expand needs loaded before it may start row e_row: the stem
    // reads input rows 2r-1 .. 2r+1, so 2r+2 must have been loaded; otherwise r+1.
    wire [10:0] e_need = stem ? ({1'b0, e_row, 1'b0} + 11'd2)    // 2r + 2
                              : ({2'b0, e_row}       + 11'd1);   // r + 1
`ifdef FUSE_NEG_STEM_HASIN
    // negative test: one input row per output row for the stem too
    wire e_has_in = ({1'b0, in_wptr} > {1'b0, e_row});
`else
    wire e_has_in = ({1'b0, in_wptr} >= e_need);
`endif
    wire e_has_rm = (t1_free != 10'd0);
    wire e_can    = e_has_in && e_has_rm && e_more;
    wire p_more   = ({1'b0, p_row} < h_out);
    wire p_has_in = ({1'b0, dw_wptr} > {1'b0, p_row});
    wire p_has_rm = (out_free != 10'd0);
    wire p_can    = p_has_in && p_has_rm && p_more;
    // d_counted: the depthwise ring has counted every row D has finished. d_row
    // advances on the d_done cycle, but twn_fuse_top delays the ring's row-done
    // by one cycle, so for that cycle dw_free still reflects the previous row.
    // Testing the pointers (rather than counting a cycle) holds if that delay
    // changes.
`ifdef FUSE_NEG_DW_UNCOUNTED
    // negative test: grant D without checking the ring has counted its last row
    wire d_counted = 1'b1;
`else
    wire d_counted = ({1'b0, dw_wptr} >= {1'b0, d_row});
`endif
    wire d_can = d_window && (dw_free != 10'd0) && ({1'b0, d_row} < h_out)
                 && d_counted;

    // Buffer levels decide first; credits only break a tie.
    wire pick_p = p_can && (!e_can || (t1_free == 10'd0) || (cred_e == 4'd0));
    wire pick_e = e_can && !pick_p;

    // ---- ownership (latched for a whole row) ----
    reg own_e, own_p, own_d, own_ld, own_st;
    reg ld_req_r, d_req_r, st_req_r;
    assign ld_req = ld_req_r & ~ld_done;
    assign d_req  = d_req_r  & ~d_done;
    assign st_req = st_req_r & ~st_done;
    reg arr_seen;                  // the array has been granted at least once in this block
    reg [31:0] idle_tail;          // idle cycles since the most recent array grant
    wire grant_e = own_e || (!own_e && !own_p && pick_e);
    wire grant_p = own_p || (!own_e && !own_p && pick_p);
    wire grant_d = own_d || (!own_d && d_can);
    // Residual-buffer room: for blocks with a residual, the loader may run at
    // most RES_DEPTH-2 rows ahead of the project. The test is made before the
    // grant, which is why the limit is two below the buffer depth. Blocks
    // without a residual are not limited.
`ifdef FUSE_NEG_NO_RES_BRAKE
    wire res_room = 1'b1;
`else
    wire res_room = !has_res || (({1'b0, ld_row} - {1'b0, p_row}) < (RES_DEPTH - 2));
`endif
    wire grant_ld = own_ld || (!own_ld && (in_free != 10'd0) && res_room && ({1'b0, ld_row} < h_ld));
    wire grant_st = own_st || (!own_st && (st_row < p_row));

    wire any_move = grant_e || grant_p || grant_d || grant_ld || grant_st;

    // ---- credits: E gets 2 rows per P row at stride 2, else 1; each counts down to zero and
    // both reload only when both are zero ----
    wire [3:0] cred_e_ld = s_dw ? 4'd2 : 4'd1;      // rows of E per row of P
    reg  [3:0] ce_n, cp_n;
    always @* begin
        ce_n = cred_e; cp_n = cred_p;
        if (grant_e && e_done && cred_e != 4'd0) ce_n = cred_e - 4'd1;
        if (grant_p && p_done && cred_p != 4'd0) cp_n = cred_p - 4'd1;
        if (ce_n == 4'd0 && cp_n == 4'd0) begin ce_n = cred_e_ld; cp_n = 4'd1; end
    end

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            ld_req_r <= 0; e_req <= 0; d_req_r <= 0; p_req <= 0; st_req_r <= 0;
            e_row <= 0; d_row <= 0; p_row <= 0; ld_row <= 0; st_row <= 0;
            t1_rptr <= 0; cred_e <= 0; cred_p <= 0;
            own_e <= 0; own_p <= 0; own_d <= 0; own_ld <= 0; own_st <= 0;
            cyc_total <= 0; cyc_array <= 0; cyc_dw <= 0; cyc_stall_mem <= 0;
            cyc_idle_pre <= 0; cyc_idle_post <= 0; arr_seen <= 0; idle_tail <= 0;
            why_e_ld <= 0; why_e_t1full <= 0; why_p_dw <= 0; why_p_outfull <= 0;
        end else begin
            ld_req_r <= 0; e_req <= 0; d_req_r <= 0; p_req <= 0; st_req_r <= 0;

            case (st)
            S_IDLE: if (start) begin
                st <= S_RUN; busy <= 1'b1; done <= 1'b0;
                e_row <= 0; d_row <= 0; p_row <= 0; ld_row <= 0; st_row <= 0;
                t1_rptr <= 0;
                own_e <= 0; own_p <= 0; own_d <= 0; own_ld <= 0; own_st <= 0;
                arr_seen <= 0; idle_tail <= 0;
                why_e_ld <= 0; why_e_t1full <= 0; why_p_dw <= 0; why_p_outfull <= 0;
                cred_e <= cred_e_ld;             // rows, not work
                cred_p <= 4'd1;
                // the cycle counters are not cleared here (start is per block);
                // cyc_clr clears them
                why_e_ld <= 0; why_e_t1full <= 0; why_p_dw <= 0; why_p_outfull <= 0;
            end

            S_RUN: begin
                cyc_total <= cyc_total + 32'd1;
                cred_e <= ce_n; cred_p <= cp_n;
                if (!any_move) cyc_stall_mem <= cyc_stall_mem + 32'd1;
                // Idle accounting: `post` is only known once the block ends, so
                // it accumulates in idle_tail and is added at S_DRAIN.
                if (grant_e || grant_p) begin
                    arr_seen  <= 1'b1;
                    idle_tail <= 32'd0;
                end else if (!arr_seen) begin
                    cyc_idle_pre <= cyc_idle_pre + 32'd1;
                end else begin
                    idle_tail <= idle_tail + 32'd1;
                    // why_* count only mid-block idle (between first and last grant)
                    if (e_more && !e_has_in) why_e_ld     <= why_e_ld     + 32'd1;
                    if (e_more && !e_has_rm) why_e_t1full <= why_e_t1full + 32'd1;
                    if (p_more && !p_has_in) why_p_dw     <= why_p_dw     + 32'd1;
                    if (p_more && !p_has_rm) why_p_outfull<= why_p_outfull+ 32'd1;
                end

                // ---- LD ----
                // The request is not raised on the done cycle, so the master
                // cannot start another row without the grant being re-evaluated.
                if (grant_ld) begin
                    own_ld <= 1'b1;
                    if (ld_done) begin ld_row <= ld_row + 9'd1; own_ld <= 1'b0; end
                    else ld_req_r <= 1'b1;      // not on the done cycle
                end

                // ---- the shared array: the owner keeps it until its row ends ----
                if (grant_e) begin
                    e_req <= 1'b1; own_e <= 1'b1;
                    cyc_array <= cyc_array + 32'd1;
                    if (e_done) begin
                        e_row <= e_row + 9'd1; own_e <= 1'b0;
                    end
                end else if (grant_p) begin
                    p_req <= 1'b1; own_p <= 1'b1;
                    cyc_array <= cyc_array + 32'd1;
                    if (p_done) begin
                        p_row <= p_row + 9'd1; own_p <= 1'b0;
                    end
                end

                // ---- D runs on its own engine, in parallel with the array ----
                // d_req_r is low on the done cycle, so the depthwise sequencer
                // sees the request fall between rows.
                if (grant_d) begin
                    own_d <= 1'b1;
                    cyc_dw <= cyc_dw + 32'd1;
                    if (d_done) begin
                        d_row <= d_row + 9'd1; own_d <= 1'b0;
                        t1_rptr <= rp_next;          // read pointer rule above
                    end else d_req_r <= 1'b1;        // not on the done cycle
                end

                // ---- ST: drain finished output rows ----
                // Same request timing as LD. The grant requires st_row < p_row.
                if (grant_st) begin
                    own_st <= 1'b1;
                    if (st_done) begin st_row <= st_row + 9'd1; own_st <= 1'b0; end
                    else st_req_r <= 1'b1;      // not on the done cycle
                end

                if (({1'b0, p_row} >= h_out) && ({1'b0, st_row} >= h_out)) st <= S_DRAIN;
            end

            S_DRAIN: begin
                cyc_total     <= cyc_total + 32'd1;
                // idle_tail is per block; cyc_idle_post accumulates over blocks.
                cyc_idle_post <= cyc_idle_post + idle_tail + 32'd1;
                st <= S_DONE;
            end
            S_DONE:  begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
            endcase

            // Frame-scoped clear, last in the block so it wins over the counter
            // updates above on the cycle it is asserted.
            if (cyc_clr) begin
                cyc_total <= 0; cyc_array <= 0; cyc_dw <= 0; cyc_stall_mem <= 0;
                cyc_idle_pre <= 0; cyc_idle_post <= 0;
            end
        end
    end

    wire _unused_ok = &{1'b0, c_in, c_mid, c_out, pack_e, pack_p, w_out, 1'b0};

endmodule
`default_nettype wire
