// ============================================================================
//  twn_uop_issue.v -- decides when the ternary array is handed a micro-op.
//
//  twn_uop_enc says what the instruction is; this module says when it is issued.
//  twn_blockseq's e_req / p_req are levels held for a whole row, not pulses, so
//  an edge detect would miss back-to-back rows of the same stage.
//
//  Issue rule (fire): a request is up, the array is not busy, nothing has been
//  issued for the current request yet (`issued` low), and the scatter is not
//  draining the previous row (scat_busy low).
//
//  `issued` is set by fire and cleared by done_q (arr_done delayed one cycle) or
//  when both requests are low. The delay matters: in the cycle arr_done is high
//  the request lines still show the finished row, and the sequencer only
//  re-decides after that, so clearing on arr_done itself would let the finished
//  row's instruction be issued again.
//
//  Outputs: uop_valid is a one-cycle pulse; role_q is loaded at the same edge
//  (0 = expand, 1 = project) and then holds until the next issue, so the
//  activation gather keeps seeing the role for the whole row.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_uop_issue (
    input  wire clk,
    input  wire rst,

    input  wire e_req,          // from twn_blockseq: expand row requested (level)
    input  wire p_req,          // from twn_blockseq: project row requested (level)
    input  wire arr_busy,       // from twn_fuse_array
    input  wire arr_done,       // from twn_fuse_array: row finished

    // High from arr_done until the scatter (the stage that writes the array's
    // output into the row rings) has flushed the finished row. Its row-end
    // steering uses the destination of the current micro-op, so the next row is
    // not issued while this is high.
    input  wire scat_busy,

    output reg  uop_valid,      // one cycle, aligned with role_q
    output reg  role_q          // 0 = expand, 1 = project; holds until next issue
);
    wire arr_req = e_req | p_req;

    reg issued;                 // an instruction is outstanding for this request
    reg done_q;                 // arr_done, one cycle late

`ifdef UOP_NEG_NO_SCAT_HOLD
    // negative test: issue without waiting for the scatter
    wire fire = arr_req & ~arr_busy & ~issued;
`elsif FUSE_EARLY_PRIME
    // with early prime the scatter gates only the array's first output beat
    // (inside twn_fuse_array), not the issue
    wire fire = arr_req & ~arr_busy & ~issued;
`else
    wire fire = arr_req & ~arr_busy & ~issued & ~scat_busy;
`endif

    always @(posedge clk) begin
        if (rst) begin
            uop_valid <= 1'b0;
            role_q    <= 1'b0;
            issued    <= 1'b0;
            done_q    <= 1'b0;
        end else begin
            done_q    <= arr_done;
            uop_valid <= fire;
            if (fire) role_q <= p_req;

            if (fire)                       issued <= 1'b1;
            else if (done_q || !arr_req)    issued <= 1'b0;
        end
    end

endmodule
`default_nettype wire
