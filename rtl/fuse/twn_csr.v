// ============================================================================
//  twn_csr.v -- AXI4-Lite control/status registers of the fused accelerator,
//  plus the write windows for the block descriptor table (twn_desctab) and the
//  head requantisation table.
//
//  Write protocol: the address and data channels are captured independently
//  (aw_hold / w_hold); the write executes when both are held and no response is
//  pending. wstrb is ignored: every write is a whole-word write. Reads are
//  answered one transaction at a time. Unmapped addresses read 0 and ignore
//  writes. Every response is OKAY.
//
//  ap_start and hd_start are levels, not pulses: set by a CTRL write, cleared
//  when the core (resp. head sequencer) is seen busy. A start written while the
//  target is already busy is therefore dropped, not queued.
//
//  Write windows, chosen by the address:
//    0x1000..0x17ff  block descriptor table: word index = addr[10:2]
//                    (twn_desctab holds 20 blocks x 16 words)
//    0x0400..0x07ff  head requantisation table, see below
//    anything else   the named registers
//  The two windows cannot overlap each other or a named register; a
//  simulation-only check at the end of the file walks all 65,536 addresses.
//
//  Register map (offsets; bit layouts are given at each register's write arm
//  and read arm in the body):
//    0x0000 CTRL            0x0008 NBLK (reset 17)    0x000c/0x0010 ACT lo/hi
//    0x0014/0x0018 W lo/hi  0x001c/0x0020 IN lo/hi    0x0024/0x0028 OUT lo/hi
//    0x002c STATUS (read)   0x0030 CHECK (write)
//    0x0034 CYCLES  0x0038 CYC_ARR  0x003c CYC_DW  0x0040 CYC_STAL
//    0x0044 CYC_PRE 0x0048 CYC_POST (read-only counters from the core)
//    0x004c PIX_NZ  0x0050..0x005c CAP0..CAP3 (read-only observation words)
//    0x0060 BB2HD   0x0064 IRQ   0x0100..0x013c head registers (HD_*)
//  The "lo/hi" pairs hold 40-bit addresses as two 32-bit words (hi uses [7:0]).
//
//  Interrupt (v1.1): irq = (bb_irq_en & ap_done) | (hd_irq_en & hd_done), one register
//  stage, level high. The enables live in their own register (IRQ, 0x0064), so the
//  START and clear-done writes to CTRL / HD_CTRL do not touch them; irq falls when
//  the done it reports is cleared. CTRL[2] (irq_en) is still only stored, as before.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_csr (
    input  wire        clk,
    input  wire        rstn,

    // ---- AXI4-Lite ----
    input  wire [15:0] awaddr,
    input  wire        awvalid,
    output reg         awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output reg         wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [15:0] araddr,
    input  wire        arvalid,
    output reg         arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rvalid,
    input  wire        rready,

    // ---- to the core (backbone start/busy/done) ----
    output reg         ap_start,
    input  wire        core_busy,
    input  wire        core_done,

    // 40-bit DDR addresses and the number of blocks to run
    output reg  [39:0] act_base,
    output reg  [39:0] w_base,
    output reg  [39:0] in_ptr,
    output reg  [39:0] out_ptr,
    output reg  [4:0]  n_blocks,

    // ---- the descriptor table's write port and its check ----
    output reg         d_wr_en,
    output reg  [12:0] d_wr_addr,
    output reg  [31:0] d_wr_data,
    output reg         d_check,           // 1-cycle pulse: walk the table
    input  wire        d_valid,
    input  wire        d_check_done,
    input  wire [3:0]  d_err_code,
    input  wire [4:0]  d_err_block,

    // ---- status ----
    input  wire [4:0]  cur_block,
    // A row buffer was written while it was full or refused; latched until reset.
    input  wire        ring_overrun,
    // performance counters, read-only
    input  wire [31:0] cyc_total,
    input  wire [31:0] cyc_array,
    input  wire [31:0] cyc_dw,
    input  wire [31:0] cyc_stall_mem,
    input  wire [31:0] cyc_idle_pre,
    input  wire [31:0] cyc_idle_post,

    // Pixel-phase observation, three groups of 4 bits, read at PIX_NZ[11:0].
    // twn_fuse_top drives zeros unless it is built with FUSE_OBS.
    input  wire [11:0] pix_nz,

    // The first project beat of the frame, captured verbatim (zeros unless
    // twn_fuse_top is built with FUSE_OBS). Read as four words at 0x0050..0x005c.
    input  wire [127:0] arr_cap,

    // ---- the head engine: control (twn_hd_seq's start/busy/done) ----
    output reg         hd_start,
    input  wire        hd_busy,
    input  wire        hd_done,           // 1-cycle pulse; latched here

    // ---- the head engine: one descriptor, presented whole ----
    // Names and widths follow twn_hd_seq's d_* ports. hd_d_we is the only
    // pulse; the other outputs are the staging registers written through the
    // HD_* registers and stay stable until rewritten.
    output reg         hd_d_we,
    output reg  [1:0]  hd_d_wa,           // operator index being committed
    output reg  [39:0] hd_d_in_base,
    output reg  [39:0] hd_d_w_base,
    output reg  [39:0] hd_d_out_base,
    output reg  [23:0] hd_d_in_beats,
    output reg  [23:0] hd_d_w_beats,
    output reg  [23:0] hd_d_out_beats,
    output reg  [8:0]  hd_d_ic,
    output reg  [5:0]  hd_d_oc,
    output reg  [6:0]  hd_d_h,
    output reg  [6:0]  hd_d_w,
    output reg         hd_d_type4,
    output reg         hd_d_slice,
    output reg         hd_d_relu,
    output reg  [15:0] hd_d_lo,
    output reg  [15:0] hd_d_hi,

    // ---- the head engine: the requantisation table's write port ----
    // Separate from the block table's port; layout in the window section below.
    output reg         hd_rq_we,
    output reg  [7:0]  hd_rq_wa,          // {op[1:0], oc[4:0], half}
    output reg  [31:0] hd_rq_wd,

    // ---- A_BB2HD: the last backbone block writes straight into the head's input ----
    // The parity and the head's latched slot live in twn_fuse_top; this file
    // holds the enable and reports the state.
    output reg         bb2hd_en,
    output reg         bb_par_clr,        // 1-cycle pulse: parity back to 0
    input  wire        bb_par,
    input  wire        hd_sel,
    input  wire        hd_en_l,
    input  wire        bb2hd_coll,         // 1-cycle pulse; latched here

    // ---- interrupt to the processor (level high, registered) ----
    output reg         irq
);
    localparam [15:0] A_CTRL     = 16'h0000,
                      A_NBLK     = 16'h0008,
                      A_ACT_LO   = 16'h000c, A_ACT_HI  = 16'h0010,
                      A_W_LO     = 16'h0014, A_W_HI    = 16'h0018,
                      A_IN_LO    = 16'h001c, A_IN_HI   = 16'h0020,
                      A_OUT_LO   = 16'h0024, A_OUT_HI  = 16'h0028,
                      A_STATUS   = 16'h002c,
                      A_CHECK    = 16'h0030,
                      A_CYCLES   = 16'h0034,
                      A_CYC_ARR  = 16'h0038,
                      A_CYC_DW   = 16'h003c,
                      A_CYC_STAL = 16'h0040,
                      A_CYC_PRE  = 16'h0044,
                      A_CYC_POST = 16'h0048,
                      A_PIX_NZ   = 16'h004c,
                      A_CAP0     = 16'h0050, A_CAP1 = 16'h0054,
                      A_CAP2     = 16'h0058, A_CAP3 = 16'h005c,
                      A_BB2HD    = 16'h0060,
                      A_IRQ      = 16'h0064;

    // ========================================================================
    //  A_BB2HD (0x0060): backbone output straight into the head's input slots
    //
    //  Enable = 0: the last block writes to its descriptor's out_slot and the
    //  head's operator 61 input offset is hd_slot (twn_fuse_top).
    //  Enable = 1 (sampled when a backbone frame starts and when a head starts,
    //  so a mid-frame write does not split a frame):
    //    * the last block writes to OUT_PTR + bb_par * 0x10000;
    //    * bb_par flips at every backbone done;
    //    * a head start latches hd_sel = ~bb_par, the slot the most recently
    //      finished backbone wrote, and the head reads its input from it.
    //
    //    bit   read                              write
    //     0    enable                            enable
    //     1    bb_par (slot the next backbone    1 = clear bb_par to 0 (takes
    //          writes)                           effect only while backbone idle)
    //     2    hd_sel (slot of the most          ignored
    //          recently started head)
    //     3    collision, sticky: the last       1 = clear it
    //          block started a row into the
    //          slot a running head uses
    //     4    the most recently started head    ignored
    //          ran with the enable on
    // ========================================================================

    // ========================================================================
    //  Head registers, 0x0100 .. 0x013c
    //  0x0100  HD_CTRL       start / busy / done, see its write arm
    //  0x0104  HD_COMMIT     W [1:0] operator index; commits the staged entry
    //                        R [1:0] last operator committed
    //                          [7:4] sticky mask of operators committed
    //  0x0108  HD_RQ_STAT    requantisation-table write evidence, see below
    //  0x0110  HD_IN_LO      in_base[31:0]       0x0114  HD_IN_HI   in_base[39:32]
    //  0x0118  HD_W_LO       w_base[31:0]        0x011c  HD_W_HI    w_base[39:32]
    //  0x0120  HD_OUT_LO     out_base[31:0]      0x0124  HD_OUT_HI  out_base[39:32]
    //  0x0128  HD_IN_BEATS   in_beats[23:0]
    //  0x012c  HD_W_BEATS    w_beats[23:0]
    //  0x0130  HD_OUT_BEATS  out_beats[23:0]
    //  0x0134  HD_SHAPE      [8:0] ic  [14:9] oc  [21:15] h  [28:22] w
    //  0x0138  HD_FLAGS      [0] type4  [1] slice  [2] relu
    //  0x013c  HD_CLAMP      [15:0] lo (signed)  [31:16] hi (signed)
    //
    //  There is ONE staging set (the hd_d_* output registers). The processor
    //  writes the fields, then writes the operator index to HD_COMMIT, which
    //  pulses hd_d_we once so twn_hd_seq latches the whole entry together.
    //  A commit does not clear the staging set: a field not rewritten keeps the
    //  previous operator's value.
    //  A committed entry cannot be read back; the HD_COMMIT sticky mask is the
    //  only evidence that each operator was committed.
    // ========================================================================
    localparam [15:0] A_HD_CTRL     = 16'h0100,
                      A_HD_COMMIT   = 16'h0104,
                      A_HD_RQ_STAT  = 16'h0108,
                      A_HD_IN_LO    = 16'h0110, A_HD_IN_HI  = 16'h0114,
                      A_HD_W_LO     = 16'h0118, A_HD_W_HI   = 16'h011c,
                      A_HD_OUT_LO   = 16'h0120, A_HD_OUT_HI = 16'h0124,
                      A_HD_IN_BEATS = 16'h0128,
                      A_HD_W_BEATS  = 16'h012c,
                      A_HD_OUT_BEATS= 16'h0130,
                      A_HD_SHAPE    = 16'h0134,
                      A_HD_FLAGS    = 16'h0138,
                      A_HD_CLAMP    = 16'h013c;

    // ========================================================================
    //  Head requantisation window, 0x0400 .. 0x07fc (write only)
    //
    //  256 words: 4 operators x 32 output channels x 2 words per entry.
    //    address bits   [9:8] operator   [7:3] output channel   [2] half
    //      half 0 (a[2]=0)   bias[31:0]
    //      half 1 (a[2]=1)   [7:0] bias[39:32]  [25:8] m0 (signed 18)  [31:26] shift
    //  The table is not readable. HD_RQ_STAT (0x0108) is the evidence instead:
    //    read   [3:0]  sticky: operator n has had a word written
    //           [12:4] words written since the last clear, saturating at 256
    //    write  any value clears both
    //  A complete boot (256 words, all four operators) reads 0x0100F.
    // ========================================================================

    // CSR_HD_BREAK_RQWIN (simulation only) moves the requantisation window to
    // 0x1400 so the disjointness check at the end of the file can be shown to
    // catch an overlap with the descriptor window.
`ifdef CSR_HD_BREAK_RQWIN
    localparam [15:0] A_HD_RQ_BASE = 16'h1400,
                      A_HD_RQ_TOP  = 16'h17fc;
`else
    localparam [15:0] A_HD_RQ_BASE = 16'h0400,
                      A_HD_RQ_TOP  = 16'h07fc;
`endif

    // The two window selects are functions so that the disjointness check at
    // the end of the file evaluates the same decode the write path uses.
    function SEL_DESC(input [15:0] a);
        SEL_DESC = (a[15:11] == 5'b00010);      // 0x1000..0x17ff: the block table
    endfunction
    function SEL_HRQ(input [15:0] a);
`ifdef CSR_HD_BREAK_RQWIN
        SEL_HRQ = (a[15:10] == 6'b000101);      // 0x1400..0x17ff, overlaps SEL_DESC
`else
        SEL_HRQ = (a[15:10] == 6'b000001);      // 0x0400..0x07ff: the head's rq table
`endif
    endfunction

    reg irq_en, ap_done, tab_checked;       // irq_en is stored and read back only
    reg bb_irq_en, hd_irq_en;               // A_IRQ: the enables that drive irq
    reg ovr_sticky;                      // STATUS[16], cleared only by reset
    reg [15:0] aw_hold;
    reg        aw_seen, w_seen;
    reg [31:0] w_hold;

    reg        hd_done_l;                // latched hd_done pulse
    reg        coll_sticky;              // A_BB2HD[3]
    reg [1:0]  hd_last_wa;               // HD_COMMIT read: last index committed
    reg [3:0]  hd_seen;                  // HD_COMMIT read: sticky commit mask
    reg [3:0]  hd_rq_seen;               // HD_RQ_STAT read: sticky per-operator
    reg [8:0]  hd_rq_words;              // HD_RQ_STAT read: words written, sat 256

    wire in_desc = SEL_DESC(aw_hold);
    wire in_hrq  = SEL_HRQ(aw_hold);

    always @(posedge clk) begin
        if (!rstn) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bresp <= 2'b00;
            arready <= 1'b0; rvalid <= 1'b0; rresp <= 2'b00;
            aw_seen <= 1'b0; w_seen <= 1'b0;
            ap_start <= 1'b0; ap_done <= 1'b0; irq_en <= 1'b0;
            bb_irq_en <= 1'b0; hd_irq_en <= 1'b0; irq <= 1'b0;
            d_wr_en <= 1'b0; d_check <= 1'b0; tab_checked <= 1'b0;
            ovr_sticky <= 1'b0;
            n_blocks <= 5'd17;
            act_base <= 40'd0; w_base <= 40'd0; in_ptr <= 40'd0; out_ptr <= 40'd0;
            hd_start <= 1'b0; hd_done_l <= 1'b0;
            hd_d_we <= 1'b0; hd_d_wa <= 2'd0;
            hd_last_wa <= 2'd0; hd_seen <= 4'd0;
            hd_rq_we <= 1'b0; hd_rq_wa <= 8'd0; hd_rq_wd <= 32'd0;
            hd_rq_seen <= 4'd0; hd_rq_words <= 9'd0;
            bb2hd_en <= 1'b0; bb_par_clr <= 1'b0; coll_sticky <= 1'b0;
            // The staging registers reset to zero so no X reaches twn_hd_seq.
            hd_d_in_base <= 40'd0; hd_d_w_base <= 40'd0; hd_d_out_base <= 40'd0;
            hd_d_in_beats <= 24'd0; hd_d_w_beats <= 24'd0; hd_d_out_beats <= 24'd0;
            hd_d_ic <= 9'd0; hd_d_oc <= 6'd0; hd_d_h <= 7'd0; hd_d_w <= 7'd0;
            hd_d_type4 <= 1'b0; hd_d_slice <= 1'b0; hd_d_relu <= 1'b0;
            hd_d_lo <= 16'd0; hd_d_hi <= 16'd0;
        end else begin
            d_wr_en <= 1'b0;
            d_check <= 1'b0;
            hd_d_we <= 1'b0;
            hd_rq_we <= 1'b0;
            bb_par_clr <= 1'b0;
            if (bb2hd_coll) coll_sticky <= 1'b1;
            // ovr_sticky is not cleared by reading STATUS or by starting a frame.
            if (ring_overrun) ovr_sticky <= 1'b1;
            if (core_busy)  ap_start <= 1'b0;
            if (core_done)  ap_done  <= 1'b1;
            if (d_check_done) tab_checked <= 1'b1;
            if (hd_busy) hd_start  <= 1'b0;
            if (hd_done) hd_done_l <= 1'b1;
            // level interrupt from the registered state: it rises a cycle after a
            // done is latched and falls a cycle after the done is cleared
`ifdef CSR_IRQ_BREAK_MASK
            // negative-test form (simulation only): the enables are ignored
            irq <= ap_done | hd_done_l;
`else
            irq <= (bb_irq_en & ap_done) | (hd_irq_en & hd_done_l);
`endif

            // ---- write channel ----
            // Ready drops in the cycle after its own handshake, so a
            // back-to-back second transaction cannot be accepted early.
`ifdef CSR_NEG_READY_LATE
            // negative-test form: ready stays high one cycle after its handshake
            awready <= !aw_seen && !bvalid;
            wready  <= !w_seen  && !bvalid;
`else
            awready <= !aw_seen && !bvalid && !(awvalid && awready);
            wready  <= !w_seen  && !bvalid && !(wvalid  && wready );
`endif
            if (awvalid && awready) begin aw_hold <= awaddr; aw_seen <= 1'b1; end
            if (wvalid  && wready ) begin w_hold  <= wdata;  w_seen  <= 1'b1; end

            if (aw_seen && w_seen && !bvalid) begin
                aw_seen <= 1'b0; w_seen <= 1'b0;
                bvalid  <= 1'b1; bresp <= 2'b00;
                if (in_desc) begin
                    // index from the low address bits only, not the window-select bit
                    d_wr_en   <= 1'b1;
                    d_wr_addr <= {4'd0, aw_hold[10:2]};
                    d_wr_data <= w_hold;
                end else if (in_hrq) begin
                    // own write port: never shares a strobe with the block table
                    hd_rq_we   <= 1'b1;
                    hd_rq_wa   <= aw_hold[9:2];
                    hd_rq_wd   <= w_hold;
                    hd_rq_seen[aw_hold[9:8]] <= 1'b1;
                    if (hd_rq_words != 9'd256) hd_rq_words <= hd_rq_words + 9'd1;
                end else begin
                    case (aw_hold)
                        // CTRL write: [0] start  [1] clear ap_done  [2] irq_en
                        // CTRL read (different layout, see the read case):
                        //   [0] ap_start  [1] core_busy  [2] ap_done  [3] irq_en
                        A_CTRL: begin
                            // a start is refused unless the descriptor table
                            // has been checked and found valid
                            if (w_hold[0] && tab_checked && d_valid) ap_start <= 1'b1;
                            if (w_hold[1]) ap_done <= 1'b0;
                            irq_en <= w_hold[2];
`ifdef CSR_IRQ_BREAK_CTRL
                            // negative-test form (simulation only): the backbone enable
                            // follows CTRL[2], so a START or clear-done write turns it off
                            bb_irq_en <= w_hold[2];
`endif
                        end
                        A_NBLK:   n_blocks <= w_hold[4:0];
                        A_ACT_LO: act_base[31:0]  <= w_hold;
                        A_ACT_HI: act_base[39:32] <= w_hold[7:0];
                        A_W_LO:   w_base[31:0]    <= w_hold;
                        A_W_HI:   w_base[39:32]   <= w_hold[7:0];
                        A_IN_LO:  in_ptr[31:0]    <= w_hold;
                        A_IN_HI:  in_ptr[39:32]   <= w_hold[7:0];
                        A_OUT_LO: out_ptr[31:0]   <= w_hold;
                        A_OUT_HI: out_ptr[39:32]  <= w_hold[7:0];
                        // CHECK: write bit 0 = 1 starts the descriptor table walk
                        // and clears tab_checked until it finishes
                        A_CHECK:  if (w_hold[0]) begin
                                      d_check <= 1'b1; tab_checked <= 1'b0;
                                  end
                        A_BB2HD: begin
                            bb2hd_en <= w_hold[0];
                            if (w_hold[1]) bb_par_clr  <= 1'b1;
                            if (w_hold[3]) coll_sticky <= 1'b0;
                        end
                        // IRQ write: [0] backbone done -> irq  [1] head done -> irq
                        A_IRQ: begin
                            bb_irq_en <= w_hold[0];
                            hd_irq_en <= w_hold[1];
                        end

                        // ---- the head ----
                        //  HD_CTRL has the same bit meaning on read and write:
                        //    bit   read                    write
                        //     0    a start is pending      1 = start (also clears done)
                        //     1    hd_busy                 ignored
                        //     2    done is set             1 = clear done
                        //  A head start is not gated on tab_checked / d_valid,
                        //  which describe the block table only.
                        //  If a done pulse and a start/clear write coincide, the
                        //  write wins (it comes later in this block).
                        A_HD_CTRL: begin
                            if (w_hold[0]) begin
                                hd_start  <= 1'b1;
                                hd_done_l <= 1'b0;
                            end
                            if (w_hold[2]) hd_done_l <= 1'b0;
                        end

                        // the only pulse in the head window: the staged fields
                        // are already on the output ports
                        A_HD_COMMIT: begin
                            hd_d_we    <= 1'b1;
                            hd_d_wa    <= w_hold[1:0];
                            hd_last_wa <= w_hold[1:0];
                            hd_seen[w_hold[1:0]] <= 1'b1;
                        end

                        // any written value clears the requantisation-window evidence
                        A_HD_RQ_STAT: begin
                            hd_rq_seen  <= 4'd0;
                            hd_rq_words <= 9'd0;
                        end

                        A_HD_IN_LO:     hd_d_in_base[31:0]   <= w_hold;
                        A_HD_IN_HI:     hd_d_in_base[39:32]  <= w_hold[7:0];
                        A_HD_W_LO:      hd_d_w_base[31:0]    <= w_hold;
                        A_HD_W_HI:      hd_d_w_base[39:32]   <= w_hold[7:0];
                        A_HD_OUT_LO:    hd_d_out_base[31:0]  <= w_hold;
                        A_HD_OUT_HI:    hd_d_out_base[39:32] <= w_hold[7:0];
                        A_HD_IN_BEATS:  hd_d_in_beats  <= w_hold[23:0];
                        A_HD_W_BEATS:   hd_d_w_beats   <= w_hold[23:0];
                        A_HD_OUT_BEATS: hd_d_out_beats <= w_hold[23:0];
                        A_HD_SHAPE: begin
                            hd_d_ic <= w_hold[8:0];
                            hd_d_oc <= w_hold[14:9];
                            hd_d_h  <= w_hold[21:15];
                            hd_d_w  <= w_hold[28:22];
                        end
                        A_HD_FLAGS: begin
                            hd_d_type4 <= w_hold[0];
                            hd_d_slice <= w_hold[1];
                            hd_d_relu  <= w_hold[2];
                        end
                        A_HD_CLAMP: begin
                            hd_d_lo <= w_hold[15:0];
                            hd_d_hi <= w_hold[31:16];
                        end
                        default: ;
                    endcase
                    // CSR_HD_BREAK_STREAM (simulation only): every field write
                    // also pulses hd_d_we, so twn_hd_seq stores partial entries.
                    // Used to show the unit gate catches that.
`ifdef CSR_HD_BREAK_STREAM
                    if (aw_hold >= A_HD_IN_LO && aw_hold <= A_HD_CLAMP)
                        hd_d_we <= 1'b1;
`endif
                end
            end
            if (bvalid && bready) bvalid <= 1'b0;

            // ---- read channel ----
`ifdef CSR_NEG_READY_LATE
            arready <= !rvalid;
`else
            arready <= !rvalid && !(arvalid && arready);
`endif
            if (arvalid && arready) begin
                rvalid <= 1'b1; rresp <= 2'b00;
                case (araddr)
                    A_CTRL:   rdata <= {28'd0, irq_en, ap_done, core_busy, ap_start};
                    A_NBLK:   rdata <= {27'd0, n_blocks};
                    A_ACT_LO: rdata <= act_base[31:0];
                    A_ACT_HI: rdata <= {24'd0, act_base[39:32]};
                    A_W_LO:   rdata <= w_base[31:0];
                    A_W_HI:   rdata <= {24'd0, w_base[39:32]};
                    A_IN_LO:  rdata <= in_ptr[31:0];
                    A_IN_HI:  rdata <= {24'd0, in_ptr[39:32]};
                    A_OUT_LO: rdata <= out_ptr[31:0];
                    A_OUT_HI: rdata <= {24'd0, out_ptr[39:32]};
                    // STATUS: [0] d_valid  [1] tab_checked  [6:2] cur_block
                    //         [10:7] err_code  [15:11] err_block  [16] ovr_sticky
                    A_STATUS: rdata <= {15'd0, ovr_sticky,
                                        d_err_block, d_err_code,
                                        cur_block, tab_checked, d_valid};
                    A_CYCLES:   rdata <= cyc_total;
                    A_CYC_ARR:  rdata <= cyc_array;
                    A_CYC_DW:   rdata <= cyc_dw;
                    A_CYC_STAL: rdata <= cyc_stall_mem;
                    A_CYC_PRE:  rdata <= cyc_idle_pre;
                    A_CYC_POST: rdata <= cyc_idle_post;
                    A_PIX_NZ:   rdata <= {20'd0, pix_nz};
                    A_CAP0:     rdata <= arr_cap[31:0];
                    A_CAP1:     rdata <= arr_cap[63:32];
                    A_CAP2:     rdata <= arr_cap[95:64];
                    A_CAP3:     rdata <= arr_cap[127:96];
                    A_BB2HD:    rdata <= {27'd0, hd_en_l, coll_sticky, hd_sel, bb_par, bb2hd_en};
                    // IRQ read: [0] bb_irq_en [1] hd_irq_en [2] ap_done [3] hd_done [4] irq
                    A_IRQ:      rdata <= {27'd0, irq, hd_done_l, ap_done, hd_irq_en, bb_irq_en};

                    // ---- the head ----
`ifdef CSR_HD_BREAK_ASYM
                    // CSR_HD_BREAK_ASYM (simulation only): busy and done swap
                    // places on the read side, so the write-side layout no
                    // longer matches the read side.
                    A_HD_CTRL:   rdata <= {29'd0, hd_busy, hd_done_l, hd_start};
`else
                    A_HD_CTRL:   rdata <= {29'd0, hd_done_l, hd_busy, hd_start};
`endif
                    A_HD_COMMIT: rdata <= {24'd0, hd_seen, 2'd0, hd_last_wa};
                    A_HD_RQ_STAT: rdata <= {19'd0, hd_rq_words, hd_rq_seen};
                    A_HD_IN_LO:  rdata <= hd_d_in_base[31:0];
                    A_HD_IN_HI:  rdata <= {24'd0, hd_d_in_base[39:32]};
                    A_HD_W_LO:   rdata <= hd_d_w_base[31:0];
                    A_HD_W_HI:   rdata <= {24'd0, hd_d_w_base[39:32]};
                    A_HD_OUT_LO: rdata <= hd_d_out_base[31:0];
                    A_HD_OUT_HI: rdata <= {24'd0, hd_d_out_base[39:32]};
                    A_HD_IN_BEATS:  rdata <= {8'd0, hd_d_in_beats};
                    A_HD_W_BEATS:   rdata <= {8'd0, hd_d_w_beats};
                    A_HD_OUT_BEATS: rdata <= {8'd0, hd_d_out_beats};
                    A_HD_SHAPE:  rdata <= {3'd0, hd_d_w, hd_d_h, hd_d_oc, hd_d_ic};
                    A_HD_FLAGS:  rdata <= {29'd0, hd_d_relu, hd_d_slice, hd_d_type4};
                    A_HD_CLAMP:  rdata <= {hd_d_hi, hd_d_lo};
                    default:  rdata <= 32'd0;
                endcase
            end
            if (rvalid && rready) rvalid <= 1'b0;
        end
    end

    // ---- window disjointness check (simulation only) ----
    // At time 0, over all 65,536 addresses: no address selects both windows,
    // and no named register falls inside either window. It calls SEL_DESC and
    // SEL_HRQ, the same functions the write path uses.
    // synthesis translate_off
    localparam integer N_NAMED = 40;
    reg [15:0] named [0:N_NAMED-1];
    integer ck_i, ck_a, ck_both, ck_eaten;
    initial begin
        named[ 0]=A_CTRL;         named[ 1]=A_NBLK;        named[ 2]=A_ACT_LO;
        named[ 3]=A_ACT_HI;       named[ 4]=A_W_LO;        named[ 5]=A_W_HI;
        named[ 6]=A_IN_LO;        named[ 7]=A_IN_HI;       named[ 8]=A_OUT_LO;
        named[ 9]=A_OUT_HI;       named[10]=A_STATUS;      named[11]=A_CHECK;
        named[12]=A_CYCLES;       named[13]=A_CYC_ARR;     named[14]=A_CYC_DW;
        named[15]=A_CYC_STAL;     named[16]=A_CYC_PRE;     named[17]=A_CYC_POST;
        named[18]=A_PIX_NZ;       named[19]=A_CAP0;        named[20]=A_CAP1;
        named[21]=A_CAP2;         named[22]=A_CAP3;        named[23]=A_HD_CTRL;
        named[24]=A_HD_COMMIT;    named[25]=A_HD_RQ_STAT;  named[26]=A_HD_IN_LO;
        named[27]=A_HD_IN_HI;     named[28]=A_HD_W_LO;     named[29]=A_HD_W_HI;
        named[30]=A_HD_OUT_LO;    named[31]=A_HD_OUT_HI;   named[32]=A_HD_IN_BEATS;
        named[33]=A_HD_W_BEATS;   named[34]=A_HD_OUT_BEATS;named[35]=A_HD_SHAPE;
        named[36]=A_HD_FLAGS;     named[37]=A_HD_CLAMP;    named[38]=A_BB2HD;
        named[39]=A_IRQ;

        ck_both = 0;
        for (ck_a = 0; ck_a < 65536; ck_a = ck_a + 1)
            if (SEL_DESC(ck_a[15:0]) && SEL_HRQ(ck_a[15:0])) begin
                if (ck_both == 0)
                    $display("FAIL twn_csr: address 0x%04h selects BOTH the block descriptor window and the head requant window",
                             ck_a[15:0]);
                ck_both = ck_both + 1;
            end

        ck_eaten = 0;
        for (ck_i = 0; ck_i < N_NAMED; ck_i = ck_i + 1)
            if (SEL_DESC(named[ck_i]) || SEL_HRQ(named[ck_i])) begin
                $display("FAIL twn_csr: named register 0x%04h falls inside a window (desc=%b hrq=%b) and can never be written",
                         named[ck_i], SEL_DESC(named[ck_i]), SEL_HRQ(named[ck_i]));
                ck_eaten = ck_eaten + 1;
            end

        // the window bounds must lie inside the window SEL_HRQ decodes
        if (!SEL_HRQ(A_HD_RQ_BASE) || !SEL_HRQ(A_HD_RQ_TOP)) begin
            $display("FAIL twn_csr: the documented requant window 0x%04h..0x%04h is not what SEL_HRQ decodes",
                     A_HD_RQ_BASE, A_HD_RQ_TOP);
            ck_eaten = ck_eaten + 1;
        end

        if (ck_both != 0 || ck_eaten != 0) begin
            $display("FAIL twn_csr: %0d addresses select both windows, %0d named registers swallowed",
                     ck_both, ck_eaten);
            $finish;
        end
        $display("[twn_csr] window map OK: 65536 addresses, 0 select both windows; %0d named registers, 0 swallowed; requant window 0x%04h..0x%04h",
                 N_NAMED, A_HD_RQ_BASE, A_HD_RQ_TOP);
    end
    // synthesis translate_on

endmodule
`default_nettype wire
