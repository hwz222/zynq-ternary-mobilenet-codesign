// ============================================================================
//  twn_frameseq.v -- frame sequencer: walks blocks 0 .. n_blocks-1, overlapping
//  each block's computation with the weight fetch of the next block.
//
//  Interface: ap_start (a level, from twn_csr) begins a frame; busy is high
//  until the last block is finished, then done pulses for one cycle.
//  blk is the block computing and blk_f the block whose weights are fetched.
//  Per frame:
//      fetch block 0's weights (nothing to overlap with)
//      for b in 0 .. n_blocks-1:
//          start block b computing (blk_start, to twn_blockseq)
//          start block b+1's weight fetch (wf_start, to twn_wfetch), if any
//          wait for both to finish
//
//  Nothing is started until twn_desctab reports desc_ready / descf_ready for
//  the blocks about to run, since a stale descriptor would give wrong output
//  silently. This module does not handle rows or the array (twn_blockseq) and
//  does not touch the head.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_frameseq (
    input  wire clk,
    input  wire rst,

    // ---- from twn_csr ----
    input  wire       ap_start,
    input  wire [4:0] n_blocks,
    output reg        busy,
    output reg        done,

    // ---- descriptor table ----
    output reg  [4:0] blk,              // the block computing
    output reg  [4:0] blk_f,            // the block being fetched
    input  wire       desc_ready,       // the table holds `blk`
    input  wire       descf_ready,      // ... and `blk_f`

    // ---- twn_blockseq ----
    output reg        blk_start,        // 1-cycle pulse
    input  wire       blk_busy,
    input  wire       blk_done,

    // ---- twn_wfetch ----
    output reg        wf_start,         // 1-cycle pulse
    input  wire       wf_busy,
    input  wire       wf_done
);
    localparam [2:0] S_IDLE  = 3'd0,
                     S_PRE   = 3'd1,    // start the fetch of block 0
                     S_PREW  = 3'd2,    // wait for it
                     S_ARM   = 3'd3,    // wait for both descriptors, then start
                     S_RUN   = 3'd4,    // compute b, fetch b+1
                     S_WAIT  = 3'd5,
                     S_NEXT  = 3'd6;

    reg [2:0] st;
    reg       c_done, f_done;           // this block's two halves
    reg       f_needed;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            blk <= 5'd0; blk_f <= 5'd0;
            blk_start <= 1'b0; wf_start <= 1'b0;
            c_done <= 1'b0; f_done <= 1'b0; f_needed <= 1'b0;
        end else begin
            done      <= 1'b0;
            blk_start <= 1'b0;
            wf_start  <= 1'b0;

            case (st)
                S_IDLE: if (ap_start) begin
                    busy  <= 1'b1;
                    blk   <= 5'd0;
                    blk_f <= 5'd0;              // block 0's own weights first
                    st    <= S_PRE;
                end

                S_PRE: if (descf_ready && !wf_busy) begin
                    wf_start <= 1'b1;
                    st       <= S_PREW;
                end

                S_PREW: if (wf_done) begin
                    blk_f <= (n_blocks > 5'd1) ? 5'd1 : 5'd0;
                    st    <= S_ARM;
                end

                // Start block blk and, if there is a next block, its fetch.
                // With no next block f_done is preset so S_WAIT waits only for
                // the compute.
                S_ARM: if (desc_ready && descf_ready) begin
                    f_needed  <= (blk + 5'd1) < n_blocks;
                    c_done    <= 1'b0;
                    f_done    <= ((blk + 5'd1) < n_blocks) ? 1'b0 : 1'b1;
                    blk_start <= 1'b1;
                    if ((blk + 5'd1) < n_blocks) wf_start <= 1'b1;
                    st        <= S_RUN;
                end

                // one cycle for the busy flags to rise, so S_WAIT cannot take
                // "not started yet" for "finished"
                S_RUN: st <= S_WAIT;

                S_WAIT: begin
                    if (blk_done) c_done <= 1'b1;
                    if (wf_done)  f_done <= 1'b1;
                    if ((c_done || blk_done) && (f_done || wf_done)
                        && !blk_busy && !wf_busy) st <= S_NEXT;
                end

                // advance blk; blk_f becomes the block after the new blk, or
                // equals the new blk when that is the last block (no fetch)
                default: begin                  // S_NEXT
                    if ((blk + 5'd1) == n_blocks) begin
                        busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                    end else begin
                        blk   <= blk + 5'd1;
                        blk_f <= ((blk + 5'd2) < n_blocks) ? (blk + 5'd2)
                                                           : (blk + 5'd1);
                        st    <= S_ARM;
                    end
                end
            endcase
        end
    end

endmodule
`default_nettype wire
