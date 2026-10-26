// ============================================================================
//  twn_uop_enc.v -- micro-op encoder: turns the current block's descriptor
//  fields plus a stage select (`role`) into the 95-bit micro-op that
//  twn_fuse_array executes. Purely combinational.
//
//  A "stage" is one of the block's two ternary convolutions: the expand
//  (role 0) or the project (role 1). Most fields are derived:
//
//    n_pix   pixels per row walked: the expand's output row (w_mid), the
//            project's output row (w_out). The stem halves the width in the
//            expand; a stride-2 depthwise halves it again before the project.
//    n_ocg   output-channel groups = channels >> pack (pack is held as a log2)
//    pack    the low two bits of the descriptor's 3-bit pack field
//    relu    1 for the expand, 0 for the project
//    otype   0 for the expand, 1 for the project
//    n_seg   segment count from the descriptor, sent minus one
//
//  Both ternary stages of a block are stored back to back in the on-chip weight
//  memory (and likewise in the requant memory), expand first. So the project's
//  base addresses are the block's base plus the length of the expand's run.
//  That length is what the array consumes, computed below as we_words (weight
//  words) and n_rqw_e (requant words); act_base is constant zero.
//
//  Micro-op layout: see the final assign.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_uop_enc (
    // ---- from twn_desctab, the block that is computing ----
    input  wire [9:0]  c_mid,
    input  wire [9:0]  c_out,
    input  wire [8:0]  w_in,
    input  wire        s_dw,          // 0 => stride 1, 1 => stride 2
    // stem: block 0's expand halves the width itself (its depthwise is stride 1),
    // so w_out = s_dw ? w_in/2 : w_in alone would be wrong there.
    input  wire        stem,
    input  wire [2:0]  pack_e,        // log2 of the packing factor
    input  wire [2:0]  pack_p,
    input  wire [1:0]  pack0_e,       // log2 of segment 0's packing factor;
    input  wire [1:0]  pack0_p,       // zero means "same as pack"
    input  wire        msg_e,         // mixed-segment rotation
    input  wire        msg_p,
    // Segment counts, one-based, four bits wide (the project's count reaches 8,
    // which does not fit in three). The minus one is taken at full width below.
    // nseg_e must include the stem's passes: block 0's expand makes three passes
    // per output row, so it is 3 x the per-pass segment count, and the project's
    // weight base (we_words) depends on it.
    input  wire [3:0]  nseg_e,
    input  wire [3:0]  nseg_p,

    // ---- region bases of the computing block (not the prefetched one) ----
    // The on-chip placement of each block is chosen on the host and carried in
    // the descriptor; these are twn_desctab's mb_tern / mb_rqa.
    input  wire [13:0] mb_tern,       // ternary-weight memory, word address
    input  wire [12:0] mb_rqa,        // array requant memory, word address

    // ---- which ternary stage is being issued ----
    input  wire        role,          // 0 = expand, 1 = project

    output wire [94:0] uop
);
    // ---- pixels per row ----
    wire [8:0] w_mid = stem ? {1'b0, w_in[8:1]} : w_in;   // the expand's output
    wire [8:0] w_out = s_dw ? {1'b0, w_mid[8:1]} : w_mid; // the block's output
    wire [8:0] n_pix = role ? w_out : w_mid;

    // ---- per-stage fields ----
    // The expand's group count is needed in both roles (it sets the project's
    // weight base).
    wire [9:0] n_ocg_e = c_mid >> pack_e;
    wire [9:0] n_ocg_p = c_out >> pack_p;
    wire [9:0] n_ocg   = role ? n_ocg_p : n_ocg_e;

    wire [3:0] nseg    = role ? nseg_p : nseg_e;
    wire [3:0] nseg_m1 = nseg - 4'd1;      // at full width, then sliced in the concatenation
    wire [1:0] pk      = role ? pack_p[1:0] : pack_e[1:0];
    wire [1:0] pk0     = role ? pack0_p : pack0_e;
    wire       msg     = role ? msg_p   : msg_e;

    // ---- how many ternary-weight words the expand consumes ----
    // The array reads one word per (output-channel group, segment), so the main
    // run is n_ocg_e x nseg_e words. Both operands are widened before the
    // multiply so the product keeps its high bit (it can exceed 10 bits).
    // When pack0_e is nonzero the stage is tail-packed and its run also carries
    // an appendix of extra words after its own; the appendix divides by the
    // additional packing (pack0_e - pack_e), since n_ocg_e already has pack_e
    // divided out.
    wire [9:0]  we_apx   = (pack0_e != 2'd0) ? (n_ocg_e >> (pack0_e - pack_e))
                                             : 10'd0;
    wire [13:0] we_words = {4'd0, n_ocg_e} * {10'd0, nseg_e} + {4'd0, we_apx};

    // ---- the three base fields, at exactly their field widths ----
    // Declared at the widths the concatenation needs, so an operand cannot
    // contribute more bits than its field and shift the fields above it.

    // act_base is zero: activations are not addressed through the array. The
    // gather in twn_fuse_top computes its own row-buffer offsets from the
    // position (act_xg, act_seg), and the array's act_addr only reaches a debug
    // port.
    wire [16:0] f_actbase = 17'd0;

`ifdef UOP_NEG_PROJBASE
    // negative test: give the project the expand's bases
    wire [17:0] f_wbase  = {4'd0, mb_tern};
    wire [12:0] f_rqbase = mb_rqa;
`else
    wire [17:0] f_wbase  = {4'd0, mb_tern} + (role ? {4'd0, we_words} : 18'd0);
    // Requant entries are packed densely, OCMAX = 4 channels per word (the array
    // addresses them as (ocg*pack) >> 2), so the expand's table occupies
    // ceil(c_mid / 4) words regardless of pack.
    wire [9:0]  n_rqw_e  = (c_mid + 10'd3) >> 2;      // ceil(c_mid / OCMAX)
  `ifdef UOP_NEG_RQBASE_OCG
    // negative test: one requant word per output-channel group instead of per
    // four channels
    wire [12:0] f_rqbase = mb_rqa + (role ? {3'd0, (c_mid >> pack_e)} : 13'd0);
  `else
    wire [12:0] f_rqbase = mb_rqa          + (role ? {3'd0, n_rqw_e}  : 13'd0);
  `endif
`endif

    assign uop = { 4'd0,                  // [94:91] unused
                   msg,                   // [90] mixed-segment rotation
                   pk0,                   // [89:88] segment 0's pack; 0 = same as pk
                   1'b1,                  // [87] constant 1 (not read by twn_fuse_array)
                   1'b1,                  // [86] constant 1 (not read by twn_fuse_array)
                   role,                  // [85] destination ring: 0 = expand ring, 1 = block-output ring
                   role ? 2'd1 : 2'd0,    // [84:83] otype
                   role ? 1'b0 : 1'b1,    // [82] relu
                   f_rqbase,              // [81:69]
                   f_wbase,               // [68:51]
                   f_actbase,             // [50:34]
                   pk,                    // [33:32]
                   n_ocg,                 // [31:22]
                   // [21:19] n_seg minus one, sliced to 3 bits: an unsliced 4-bit
                   // operand would widen the concatenation and shift every
                   // field above it.
                   nseg_m1[2:0],
                   n_pix,                 // [18:10]
                   9'd0,                  // [9:1] unused
                   role };                // [0]

endmodule
`default_nettype wire
