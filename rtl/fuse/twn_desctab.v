// ============================================================================
//  twn_desctab.v -- on-chip block descriptor table, descriptor decode for the
//  running and prefetched block, and the boot-time table check.
//
//  Table: NBLK_MAX descriptors of W = 16 words of 32 bits (64 bytes each),
//  written word by word through wr_en / wr_addr / wr_data (from twn_csr).
//  wr_addr = {block, word}; the low 9 bits index the table.
//
//  One read port serves everything. A register file `cur` holds the running
//  block (`blk`), a second one `curf` holds words 3..10 of the prefetched block
//  (`blk_f`: the block whose weights twn_wfetch is loading while `blk` computes).
//  When blk / blk_f changes, the matching register file is reloaded from the
//  table; desc_ready / descf_ready say the fields below belong to blk / blk_f.
//
//  Boot check: a 1-cycle `check` pulse walks every block 0..n_blocks-1 and sets
//  valid = 0 with err_code / err_block at the first block that fails; it ends
//  with a check_done pulse. It owns the read port while it runs, so blk / blk_f
//  loads are not served during it. The failures it detects are the ones that
//  produce wrong output without any other symptom:
//    in_slot == out_slot            the block would overwrite its own input
//    out_slot(b) != in_slot(b+1)    the next block reads a tensor nobody wrote
//                                   (the last block is followed by block 0)
//    slot >= NSLOT                  slot outside the activation arena
//    base + count > depth           weight/requant region overruns its on-chip
//                                   memory (tern, dw, rqa, rqd; see parameters)
//    zero channel or size field     (E_GEOM)
//  An in_slot of 4'hF is exempt from the range rule and, when it is the next
//  block's in_slot, from the chain rule.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_desctab #(
    parameter integer NBLK_MAX   = 20,
    parameter integer NSLOT      = 2,      // legal in_slot / out_slot values: 0 .. NSLOT-1
    // The four depths below are the overflow guard and must equal the depths of
    // twn_wmem's memories as twn_fuse_top instantiates them (the top does not
    // override these parameters). A region ending exactly at the depth is legal.
    parameter integer TERN_WORDS = 8160,   // ternary weight memory depth
    parameter integer DW_WORDS   = 240,    // depthwise weight memory depth
    parameter integer RQA_WORDS  = 600,    // expand/project requant memory depth
    parameter integer RQD_WORDS  = 240     // depthwise requant memory depth
)(
    input  wire clk,
    input  wire rstn,

    // ---- boot load, from twn_csr ----
    input  wire        wr_en,
    input  wire [12:0] wr_addr,            // {block, word}, 9 bits used
    input  wire [31:0] wr_data,
    input  wire [4:0]  n_blocks,

    // ---- validation ----
    input  wire        check,              // 1-cycle pulse: walk the table
    output reg         check_busy,
    output reg         check_done,         // 1-cycle pulse
    output reg         valid,              // table passed the last check
    output reg  [3:0]  err_code,           // E_* below
    output reg  [4:0]  err_block,

    // ---- the block that is computing ----
    input  wire [4:0]  blk,
    // High only when `cur` has finished loading the block currently on `blk`:
    // gated by blk == cur_blk, so it drops in the same cycle blk changes and a
    // consumer cannot see the previous block's fields as ready.
    output wire        desc_ready,
    output wire [9:0]  c_in, c_mid, c_out,
    output wire [8:0]  h_in, w_in,
    output wire        s_dw,
    output wire [2:0]  pack_e, pack_p,     // packing of the expand / project convolutions
    // pack of segment 0 of the expand / project convolutions (2 bits)
    output wire [1:0]  pack0_e, pack0_p,
    output wire        msg_e, msg_p,       // mixed-segment rotation flags
    output wire [3:0]  nseg_e, nseg_p,     // number of weight segments, one-based
    output wire        stem,               // 3x3 stride-2 first conv (block 0)
    output wire [3:0]  in_slot, out_slot, res_slot,
    output wire        has_res,
    // residual-add constants; blocks without a residual carry the identity
    // values, so one datapath serves all blocks
    output wire signed [17:0] mp_res, mq_res,
    output wire [5:0]         sh_res,
    output wire signed [15:0] lo_res, hi_res,
    output wire [15:0] row_bytes_in, row_bytes_out,
    // the computing block's on-chip weight bases, where the array reads from
    output wire [13:0] mb_tern,
    output wire [9:0]  mb_dw,
    output wire [12:0] mb_rqa, mb_rqd,

    // ---- the block that is being prefetched ----
    // A second register file, so the fetcher's offsets and counts belong to
    // blk_f while the array's geometry belongs to blk.
    input  wire [4:0]  blk_f,
    output wire        descf_ready,        // curf holds blk_f
    output wire [31:0] off_tern, off_dw, off_rqa, off_rqd,   // byte offsets in the weight file
    output wire [15:0] n_tern, n_dw, n_rqa, n_rqd,           // word counts
    output wire [13:0] fb_tern,                              // on-chip bases of blk_f's regions
    output wire [9:0]  fb_dw,
    output wire [12:0] fb_rqa, fb_rqd
);
    localparam integer W = 16;             // 32-bit words per descriptor
    // The load walk runs ld_i = 0 .. NCUR and ends on ld_i == NCUR[4:0], so
    // ld_i must be 5 bits wide: a 4-bit compare would match at ld_i = 0.
    localparam integer NCUR = 16;          // words copied into `cur`

    localparam [3:0] E_NONE      = 4'd0,
                     E_SLOT_RANGE= 4'd1,
                     E_SLOT_SAME = 4'd2,
                     E_SLOT_CHAIN= 4'd3,
                     E_TERN_OVF  = 4'd4,
                     E_DW_OVF    = 4'd5,
                     E_RQA_OVF   = 4'd6,
                     E_RQD_OVF   = 4'd7,
                     E_GEOM      = 4'd8;

    // ---- the table: one write port, one read port ----
    reg [31:0] tab [0:NBLK_MAX*W-1];
    reg [8:0]  rd_a;
    reg [31:0] q;
    always @(posedge clk) begin
        if (wr_en) tab[wr_addr[8:0]] <= wr_data;
        q <= tab[rd_a];
    end

    // ---- the running block, in registers ----
    reg [31:0] cur [0:NCUR-1];
    reg [4:0]  cur_blk;
    reg        desc_ready_r;
    assign     desc_ready = desc_ready_r && (blk == cur_blk);
    reg [4:0]  ld_i;                       // 0 .. NCUR inclusive
    reg        ld_run;

    // ---- the prefetched block: words 3..10, the four regions ----
    localparam integer NCURF = 8;
    reg [31:0] curf [0:NCURF-1];
    reg [4:0]  curf_blk;
    reg        descf_ready_r;
    assign     descf_ready = descf_ready_r && (blk_f == curf_blk);
    reg [3:0]  lf_i;
    reg        lf_run;

    wire [31:0] w0 = cur[0],  w1 = cur[1],  w2 = cur[2],  w3 = cur[3];
    wire [31:0] w4 = cur[4],  w5 = cur[5],  w6 = cur[6],  w7 = cur[7];
    wire [31:0] w8 = cur[8],  w9 = cur[9],  w10= cur[10], w11= cur[11];
    wire [31:0] w12= cur[12], w13= cur[13], w14= cur[14], w15= cur[15];

    // ---- descriptor fields (word layout) ----
    // word 0  [9:0] c_in  [19:10] c_mid  [29:20] c_out  [30] s_dw  [31] has_res
    assign c_in    = w0[9:0];
    assign c_mid   = w0[19:10];
    assign c_out   = w0[29:20];
    assign s_dw    = w0[30];
    assign has_res = w0[31];
    // word 1  [8:0] h_in  [17:9] w_in  [20:18] pack_e  [23:21] pack_p
    //         [27:24] in_slot  [31:28] out_slot
    assign h_in     = w1[8:0];
    assign w_in     = w1[17:9];
    assign pack_e   = w1[20:18];
    assign pack_p   = w1[23:21];
    assign in_slot  = w1[27:24];
    assign out_slot = w1[31:28];
    // word 2  [15:0] row_bytes_in  [31:16] row_bytes_out
    assign row_bytes_in  = w2[15:0];
    assign row_bytes_out = w2[31:16];
    // word 9  [13:0] mb_tern  [23:14] mb_dw   word 10 [12:0] mb_rqa [25:13] mb_rqd
    assign mb_tern = w9[13:0];
    assign mb_dw   = w9[23:14];
    assign mb_rqa  = w10[12:0];
    assign mb_rqd  = w10[25:13];

    // The prefetched block's regions: curf[k] holds word k+3.
    //   words 3..6 offsets; word 7 [15:0] n_tern [31:16] n_dw;
    //   word 8 [15:0] n_rqa [31:16] n_rqd; words 9, 10 on-chip bases
    //   (same bit layout as mb_* above)
    assign off_tern = curf[0];  assign off_dw = curf[1];
    assign off_rqa  = curf[2];  assign off_rqd = curf[3];
    assign n_tern = curf[4][15:0];  assign n_dw  = curf[4][31:16];
    assign n_rqa  = curf[5][15:0];  assign n_rqd = curf[5][31:16];
    assign fb_tern = curf[6][13:0];
    assign fb_dw   = curf[6][23:14];
    assign fb_rqa  = curf[7][12:0];
    assign fb_rqd  = curf[7][25:13];
    // word 11 [3:0] res_slot. The boot check does not read word 11, so
    // res_slot is not validated against in_slot.
    assign res_slot = w11[3:0];

    // word 12 [3:0] n_seg_e  [7:4] n_seg_p  [8] stem  [10:9] pack0_e
    //         [12:11] pack0_p  [13] msg_e  [14] msg_p
    assign nseg_e = w12[3:0];
    assign nseg_p = w12[7:4];
    // word 13 [17:0] mp_res  [23:18] sh_res
    // word 14 [17:0] mq_res
    // word 15 [15:0] lo_res  [31:16] hi_res
    assign mp_res = $signed(w13[17:0]);
    assign sh_res = w13[23:18];
    assign mq_res = $signed(w14[17:0]);
    assign lo_res = $signed(w15[15:0]);
    assign hi_res = $signed(w15[31:16]);
    assign stem   = w12[8];
    assign pack0_e = w12[10:9];
    assign pack0_p = w12[12:11];
    assign msg_e   = w12[13];
    assign msg_p   = w12[14];

    // ================= the boot walk =================
    // Per block it reads words 0, 1, 7, 8, 9, 10 through the read port (into
    // c0, c1, c7, c8, c9, c10) plus the next block's word 1 (cn1) for the
    // chain rule; the next block of the last block is block 0.
    localparam [3:0] C_IDLE = 4'd0, C_W0 = 4'd1, C_W1 = 4'd2, C_W7 = 4'd3,
                     C_W8 = 4'd4, C_W9 = 4'd5, C_W10 = 4'd6, C_NEXT1 = 4'd7,
                     C_EVAL = 4'd8, C_TEST = 4'd9;
    reg [3:0] cst;
    reg [4:0] ci;
    reg [31:0] c0, c1, c7, c8, c9, c10, cn1;
    wire [4:0] ni = (ci == n_blocks - 5'd1) ? 5'd0 : (ci + 5'd1);

    wire [3:0] ci_in  = c1[27:24];
    wire [3:0] ci_out = c1[31:28];
    wire [3:0] ni_in  = cn1[27:24];

    wire slot_range_bad = ((ci_in  >= NSLOT[3:0]) && (ci_in != 4'hF)) ||
                          ( ci_out >= NSLOT[3:0]);
    wire slot_same_bad  = (ci_in == ci_out);
    wire slot_chain_bad = (ci_out != ni_in) && (ni_in != 4'hF);
    wire tern_ovf = ({2'd0, c9[13:0]}   + {2'd0, c7[15:0]})  > TERN_WORDS;
    wire dw_ovf   = ({6'd0, c9[23:14]}  + {6'd0, c7[31:16]}) > DW_WORDS;
    wire rqa_ovf  = ({3'd0, c10[12:0]}  + {3'd0, c8[15:0]})  > RQA_WORDS;
    wire rqd_ovf  = ({3'd0, c10[25:13]} + {3'd0, c8[31:16]}) > RQD_WORDS;
    wire geom_bad = (c0[9:0] == 10'd0) || (c0[19:10] == 10'd0) ||
                    (c0[29:20] == 10'd0) || (c1[8:0] == 9'd0) ||
                    (c1[17:9] == 9'd0);
    wire any_bad = slot_range_bad || slot_same_bad || slot_chain_bad ||
                   tern_ovf || dw_ovf || rqa_ovf || rqd_ovf || geom_bad;

    integer k;
    always @(posedge clk) begin
        if (!rstn) begin
            check_busy <= 1'b0; check_done <= 1'b0; valid <= 1'b0;
            err_code <= E_NONE; err_block <= 5'd0; ci <= 5'd0; cst <= C_IDLE;
            ld_run <= 1'b0; ld_i <= 5'd0; desc_ready_r <= 1'b0; cur_blk <= 5'h1F;
            lf_run <= 1'b0; lf_i <= 4'd0; descf_ready_r <= 1'b0; curf_blk <= 5'h1F;
            rd_a <= 9'd0;
            for (k = 0; k < NCUR;  k = k + 1) cur[k]  <= 32'd0;
            for (k = 0; k < NCURF; k = k + 1) curf[k] <= 32'd0;
        end else begin
            check_done <= 1'b0;

            // ---- the check owns the read port while it runs ----
            // Starting a check also invalidates both register files, so they
            // reload afterwards.
            if (check && cst == C_IDLE) begin
                check_busy <= 1'b1; ci <= 5'd0; valid <= 1'b1;
                err_code <= E_NONE; err_block <= 5'd0;
                cst <= C_W0; rd_a <= 9'd0;         // block 0, word 0
                desc_ready_r  <= 1'b0; cur_blk  <= 5'h1F;
                descf_ready_r <= 1'b0; curf_blk <= 5'h1F;
                ld_run <= 1'b0; lf_run <= 1'b0;
            end else if (cst != C_IDLE) begin
                // q is the table word addressed one cycle earlier
                case (cst)
                    C_W0:    begin rd_a <= {ci, 4'd1};  cst <= C_W1;    end
                    C_W1:    begin c0 <= q; rd_a <= {ci, 4'd7};  cst <= C_W7; end
                    C_W7:    begin c1 <= q; rd_a <= {ci, 4'd8};  cst <= C_W8; end
                    C_W8:    begin c7 <= q; rd_a <= {ci, 4'd9};  cst <= C_W9; end
                    C_W9:    begin c8 <= q; rd_a <= {ci, 4'd10}; cst <= C_W10;end
                    C_W10:   begin c9 <= q; rd_a <= {ni, 4'd1};  cst <= C_NEXT1;end
                    C_NEXT1: begin c10 <= q;                     cst <= C_EVAL;end
                    C_EVAL:  begin cn1 <= q;                     cst <= C_TEST;end
                    default: ;                                   // C_TEST
                endcase
                if (cst == C_TEST) begin
                    if (any_bad) begin
                        valid     <= 1'b0;
                        err_block <= ci;
                        err_code  <= slot_range_bad ? E_SLOT_RANGE
                                   : slot_same_bad  ? E_SLOT_SAME
                                   : slot_chain_bad ? E_SLOT_CHAIN
                                   : tern_ovf       ? E_TERN_OVF
                                   : dw_ovf         ? E_DW_OVF
                                   : rqa_ovf        ? E_RQA_OVF
                                   : rqd_ovf        ? E_RQD_OVF
                                   :                  E_GEOM;
                        check_busy <= 1'b0; check_done <= 1'b1; cst <= C_IDLE;
                    end else if (ci == n_blocks - 5'd1) begin
                        check_busy <= 1'b0; check_done <= 1'b1; cst <= C_IDLE;
                    end else begin
                        ci <= ci + 5'd1;
                        rd_a <= {ci + 5'd1, 4'd0};
                        cst <= C_W0;
                    end
                end
            end else begin
                // ---- otherwise the read port serves the two block loads ----
                // One load at a time; the running block has priority.
                if (ld_run) begin
                    // ld_i[3:0]: a 5-bit sum would make the concatenation 10 bits
                    // against the 9-bit rd_a. At ld_i = 15 the address wraps to
                    // word 0; that read is not stored.
                    rd_a <= {cur_blk, ld_i[3:0] + 4'd1};
                    if (ld_i != 5'd0) cur[ld_i - 1] <= q;
                    if (ld_i == NCUR[4:0]) begin
                        ld_run <= 1'b0; desc_ready_r <= 1'b1;
                    end else begin
                        ld_i <= ld_i + 5'd1;
                    end
                end else if (lf_run) begin
                    rd_a <= {curf_blk, lf_i + 4'd4};      // words 3..10
                    if (lf_i != 4'd0) curf[lf_i - 1] <= q;
                    if (lf_i == NCURF[3:0]) begin
                        lf_run <= 1'b0; descf_ready_r <= 1'b1;
                    end else begin
                        lf_i <= lf_i + 4'd1;
                    end
                end else if (blk != cur_blk) begin
                    ld_run <= 1'b1; ld_i <= 5'd0; desc_ready_r <= 1'b0;
                    cur_blk <= blk; rd_a <= {blk, 4'd0};
                end else if (blk_f != curf_blk) begin
                    lf_run <= 1'b1; lf_i <= 4'd0; descf_ready_r <= 1'b0;
                    curf_blk <= blk_f; rd_a <= {blk_f, 4'd3};
                end
            end
        end
    end

endmodule
`default_nettype wire
