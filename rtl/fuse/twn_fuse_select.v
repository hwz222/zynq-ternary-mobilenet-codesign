// ============================================================================
//  twn_fuse_select.v -- operand selection for the ternary array: lane
//  replication, per-lane select of 0 / +x / ~x, and the negative-lane flags.
//
//  One register stage (latency 1 from act_word / w_code / tag_i to the *_q
//  outputs). ce is a clock enable for the whole stage.
//
//  1. Lane replication. A 128-lane word holds `pack` output channels; channel j
//     owns lanes [j*L, j*L + n_eff) with L = 128/pack. Lane j*L+k carries
//     channel j's weight for input channel k, so it wants activation x[k]
//     regardless of j. The activation word has its channels at lanes
//     0..n_eff-1, so it is replicated `pack` times:
//        act_lane[k] = act_word[k & (L-1)]
//     L is a power of two, so this is a mask. In mixed-segment mode (msg),
//     lanes 96..127 read {seg, k[4:0]} instead: a 32-channel chunk of the word
//     selected by `seg`.
//
//  2. Selection in eight bits. Weight code 00 -> 0, 01 -> +x, 11 -> ~x (one's
//     complement of -x), 10 -> 0 (not produced by the packer). The one's
//     complement of any int8 is an int8, so eight bits are enough per lane.
//     Written as en & (x ^ inv) with en = code[0], inv = code[1].
//
//  3. Negative flags. Each ~x is (-x) - 1, so every 11 code owes a +1; neg_q
//     marks those lanes. twn_fuse_tree sums neg_q in a tree of the same shape
//     as the value tree and adds the count at the same tap. neg_q depends only
//     on the weight code, so all PIX pixels share it.
//
//  tag_i is control (position of the result) that rides through the same
//  register as the data, so it stays aligned without a hand-counted delay.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module twn_fuse_select #(
    parameter integer LANES = 128,
    parameter integer PIX   = 4,       // pixels processed in parallel
    parameter integer OCMAX = 4,       // largest packing factor that will be issued
    parameter integer TAGW  = 24
)(
    input  wire                        clk,
    input  wire                        ce,
    // packing factor as a log2 code: 0 -> pack 1 (L=128), 1 -> pack 2 (L=64),
    // 2 -> pack 4 (L=32), 3 -> pack 8 (L=16; only honoured when OCMAX >= 8)
    input  wire [1:0]                  pack,
    // mixed-segment mode: `seg` names a 32-channel chunk inside the word;
    // lane groups 0..2 read chunks 0..2 (what mask 127 already gives them) and
    // lane group 3 reads chunk `seg`
    input  wire                        msg,
    input  wire [1:0]                  seg,
    input  wire [PIX*LANES*8-1:0]      act_word,   // channels at lanes 0..n_eff-1, per pixel
    input  wire [LANES*2-1:0]          w_code,     // 2 bits per lane, shared by all pixels
    input  wire [TAGW-1:0]             tag_i,
    output reg  [PIX*LANES*8-1:0]      sel_q,      // 8-bit signed per lane per pixel
    output reg  [LANES-1:0]            neg_q,      // 1 = this lane owes a +1
    output reg  [TAGW-1:0]             tag_q
);
    // ---- lane replication ---------------------------------------------------
    // mask = L-1 for the current pack; lane k reads act_word[k & mask].
    // Pack codes above what OCMAX allows are left out of the mux so synthesis
    // does not build selector inputs that can never be used.
    localparam integer LMIN = 128 / OCMAX;      // smallest lane group in use

    // msg is one more value of the mask (127, and k & 127 == k) rather than a
    // separate selector, so it adds no second mux per lane.
    wire [6:0] mask = msg                          ? 7'd127 :
                      (OCMAX >= 8 && pack == 2'd3) ? 7'd15  :
                      (OCMAX >= 4 && pack == 2'd2) ? 7'd31  :
                      (OCMAX >= 2 && pack == 2'd1) ? 7'd63  : 7'd127;

    wire [PIX*LANES*8-1:0] act_lane;
    genvar p, k;
    generate
        for (p = 0; p < PIX; p = p + 1) begin : G_PIX
            for (k = 0; k < LANES; k = k + 1) begin : G_LANE
                if (k < LMIN) begin : G_DIRECT
                    // every mask value returns k for k < LMIN: plain wires
                    assign act_lane[(p*LANES + k)*8 +: 8] = act_word[(p*LANES + k)*8 +: 8];
                end else begin : G_MUX
`ifdef FUSE_NEG_NO_REPLICATE
                    // negative-test arm: no replication
                    assign act_lane[(p*LANES + k)*8 +: 8] = act_word[(p*LANES + k)*8 +: 8];
`else
                    // k >= 96 is a compile-time constant, so only lanes 96..127
                    // get the extra {seg, k[4:0]} source in msg mode
                    wire [6:0] src = (msg && (k >= 96)) ? {seg, k[4:0]}
                                                       : (k[6:0] & mask);
                    assign act_lane[(p*LANES + k)*8 +: 8] =
                        act_word[(p*LANES + {25'd0, src})*8 +: 8];
`endif
                end
            end
        end
    endgenerate

    // ---- selection + negative flags ----------------------------------------
    integer i, j, b;
    always @(posedge clk) if (ce) begin
        for (j = 0; j < PIX; j = j + 1)
            for (i = 0; i < LANES; i = i + 1)
                for (b = 0; b < 8; b = b + 1)
                    sel_q[(j*LANES + i)*8 + b] <=
                        w_code[i*2] & (act_lane[(j*LANES + i)*8 + b] ^ w_code[i*2 + 1]);
        for (i = 0; i < LANES; i = i + 1)
            neg_q[i] <= w_code[i*2] & w_code[i*2 + 1];   // code == 2'b11
        tag_q <= tag_i;
    end
endmodule
`default_nettype wire
