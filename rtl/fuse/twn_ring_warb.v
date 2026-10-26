// ============================================================================
//  twn_ring_warb.v -- write-port arbiter for the shared activation ring memory.
//
//  Two producers write one memory through one port (twn_fuse_top's acmem):
//    A  the load stage, writing the block's input rows (RingA). Can be held off.
//    B  the depthwise array, writing its output rows (RingC). Cannot be held
//       off: twn_dw_array has out_valid and no ready input, so a refused write
//       would be lost.
//  Hence B has absolute priority and passes straight through, and A has a
//  single-entry holding slot. Reads need no arbitration and are not handled here.
//
//  Interface:
//    - m_we/m_wa/m_wd/m_lane are registered: a write granted in cycle T appears
//      on the m_* outputs in cycle T+1. *_lane is one write-enable bit per
//      WIDTH/LANES-bit slice of the word; the arbiter only passes it through.
//    - a_ready: a write A presents in this cycle is accepted (slot empty).
//    - a_can: a promise that a write A presents in the NEXT cycle will be
//      accepted. A registered producer can only act on this one, because by
//      the time it reacts to a_ready, that cycle has passed.
//    - a_dropped / b_dropped: sticky error flags, cleared only by reset. A
//      producer that presents only when a_can was high never sets a_dropped.
//      b_dropped can never be set by this design (B is always granted); it
//      exists so a violation shows up as a flag.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module twn_ring_warb #(
    parameter integer WIDTH = 1024,
    parameter integer AW    = 16,
    parameter integer LANES = 16
)(
    input  wire clk,
    input  wire rst,

    // ---- producer A: the load stage. May be told to wait. ----
    input  wire             a_we,
    input  wire [AW-1:0]    a_wa,
    input  wire [WIDTH-1:0] a_wd,
    input  wire [LANES-1:0] a_lane,
    output wire             a_ready,   // status: a write presented this cycle is accepted
    output wire             a_can,     // promise about the next cycle, see header

    // ---- producer B: the depthwise. May NOT be told to wait. ----
    input  wire             b_we,
    input  wire [AW-1:0]    b_wa,
    input  wire [WIDTH-1:0] b_wd,
    input  wire [LANES-1:0] b_lane,

    // ---- the memory ----
    output reg              m_we,
    output reg  [AW-1:0]    m_wa,
    output reg  [WIDTH-1:0] m_wd,
    output reg  [LANES-1:0] m_lane,

    // ---- error flags, sticky ----
    output reg              b_dropped,   // a write from B was not granted
    output reg              a_dropped    // A presented a write while its slot was full
);
    // A's holding slot. B has none.
    reg             a_full;
    reg [AW-1:0]    a_a;
    reg [WIDTH-1:0] a_d;
    reg [LANES-1:0] a_l;

    // a_ready depends only on the slot, never on a_we or B, so a producer that
    // looks at it cannot form a combinational loop through the arbiter.
    assign a_ready = !a_full;

    // Slot next state:
    //     a_full(T+1) = a_full(T) ? !grant_a(T) : (a_we(T) && b_we(T))
    // With the slot empty and no A write this cycle, the slot is still empty
    // next cycle whatever B does, so a write presented next cycle is accepted.
    // WARB_NEG_LOSSY is a negative-test build that promises unconditionally,
    // so refused writes are lost without a_dropped being set.
`ifdef WARB_NEG_LOSSY
    assign a_can = 1'b1;
`else
    assign a_can = !a_full && !a_we;
`endif

    wire grant_b = b_we;                       // straight through
    wire grant_a = !grant_b && (a_full || (a_we && a_ready));

    always @(posedge clk) begin
        if (rst) begin
            a_full <= 1'b0; b_dropped <= 1'b0; a_dropped <= 1'b0;
            m_we <= 1'b0; m_wa <= {AW{1'b0}};
            m_wd <= {WIDTH{1'b0}}; m_lane <= {LANES{1'b0}};
        end else begin
            m_we <= 1'b0;

            if (grant_b) begin
                m_we <= 1'b1; m_wa <= b_wa; m_wd <= b_wd; m_lane <= b_lane;
            end else if (grant_a) begin
                m_we   <= 1'b1;
                m_wa   <= a_full ? a_a : a_wa;
                m_wd   <= a_full ? a_d : a_wd;
                m_lane <= a_full ? a_l : a_lane;
            end

            // Slot: fill when A presents and is not granted straight through;
            // empty when the held word is granted.
            if (a_we && a_ready && !(grant_a && !a_full)) begin
                a_full <= 1'b1; a_a <= a_wa; a_d <= a_wd; a_l <= a_lane;
            end else if (grant_a && a_full) begin
                a_full <= 1'b0;
            end

            if (b_we && !grant_b) b_dropped <= 1'b1;

`ifndef WARB_NEG_LOSSY
            if (a_we && !a_ready) a_dropped <= 1'b1;
`endif
        end
    end

    // ---- WARB_DEPTH_PROBE: simulation-only counters for port A ----
    // q_off/q_ref: writes A presented / presented while the slot was full.
    // q_max: peak occupancy of a hypothetical lossless queue in front of A that
    // takes every offered write and serves one per cycle B leaves the port free.
    // Only meaningful together with WARB_NEG_LOSSY, where A offers at its
    // natural rate.
`ifdef WARB_DEPTH_PROBE
    integer q_now, q_max, q_off, q_srv, q_ref, q_del;
    reg b_we_q;
    always @(posedge clk) b_we_q <= b_we;
    initial begin q_now = 0; q_max = 0; q_off = 0; q_srv = 0; q_ref = 0; q_del = 0; end
    always @(posedge clk) if (!rst) begin
        if (a_we) begin
            q_off = q_off + 1; q_now = q_now + 1;
            if (!a_ready) q_ref = q_ref + 1;
        end
        if (m_we && !b_we_q) q_del = q_del + 1;    // an A write reached the memory
        if (!b_we && q_now > 0) begin q_now = q_now - 1; q_srv = q_srv + 1; end
        if (q_now > q_max) q_max = q_now;
    end
    final begin
        $display("WARB_A_PROBE: presented %0d, REFUSED %0d, reached the array %0d",
                 q_off, q_ref, q_del);
        $display("WARB_DEPTH_PROBE: a lossless queue in front of A would have peaked at %0d entries (%0d served, %0d still held)",
                 q_max, q_srv, q_now);
    end
`endif

endmodule
`default_nettype wire
