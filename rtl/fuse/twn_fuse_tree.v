// ============================================================================
//  twn_fuse_tree.v -- one pixel's 128-input adder tree with the one's-
//  complement correction applied at the tap the packing factor reads.
//
//  Input `sel` is 128 signed 8-bit values from twn_fuse_select; `neg` marks the
//  lanes that used ~x and so owe +1. Each tree level adds adjacent pairs:
//  level n has 128/2^n nodes. The result for a packing factor is read from the
//  level whose nodes each cover 128/pack lanes:
//     pack 1 -> level 7 (root, 1 node, 15 bits)
//     pack 2 -> level 6 (2 nodes, 14 bits)
//     pack 4 -> level 5 (4 nodes, 13 bits)
//     pack 8 -> level 4 (8 nodes, 12 bits; only taken for OCMAX >= 8)
//  A second tree of the same shape sums `neg` (levels 1..7 are 2..8 bits wide),
//  and each tapped partial sum is corrected with the count of its own lanes.
//  The correction cannot be applied once at the root because the packed
//  factors read before the root. The neg tree is per pixel here but depends
//  only on the weight code; the caller shares `neg` across pixels.
//
//  Pipeline: two adder levels per stage, four stages; psum is valid 4 cycles
//  after `sel`.
//    T1  levels 1,2     T2  levels 3,4
//    T3  levels 5,6 and capture of the early taps (levels 4 and 5)
//    T4  level 7, tap select, correction
//  Level 5 is combinational out of the level-4 registers, so the level-4/5 taps
//  are captured into a carrier register at T3 and chosen from at T4; reading
//  level 5 at T4 would see the next item.
//
//  Output psum holds OCMAX signed 32-bit partial sums: all OCMAX are live at
//  the maximum pack, the first `pack` for smaller packs (index 0 only at pack 1).
//  With OCMAX = 4 only pack codes 0..2 occur.
//
//  Tags: tag_i is delayed with the data (tag_o is aligned with psum). tag_rq
//  is the same tag two stages earlier, for addressing the requant table so its
//  data arrives with psum.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module twn_fuse_tree #(
    parameter integer LANES = 128,
    parameter integer OCMAX = 4,       // largest packing factor / number of partial sums
    parameter integer TAGW  = 24
)(
    input  wire                     clk,
    input  wire                     ce,
    input  wire [1:0]               pack,          // log2 code: 0=1, 1=2, 2=4, 3=8
    input  wire [LANES*8-1:0]       sel,           // one pixel's selected values, 8-bit
    input  wire [LANES-1:0]         neg,           // negative-lane flags
    input  wire [TAGW-1:0]          tag_i,
    output wire [OCMAX*32-1:0]      psum,          // valid 4 cycles after `sel`
    output wire [TAGW-1:0]          tag_o,         // aligned with psum
    output wire [TAGW-1:0]          tag_rq         // tag two stages before psum
);
    // ---- pack and tag, delayed to match each stage -------------------------
    reg [1:0] pack_1, pack_2, pack_3;
    reg [TAGW-1:0] tag_1, tag_2, tag_3, tag_4;
    always @(posedge clk) if (ce) begin
        pack_1 <= pack; pack_2 <= pack_1; pack_3 <= pack_2;
        tag_1 <= tag_i; tag_2 <= tag_1; tag_3 <= tag_2; tag_4 <= tag_3;
    end
    assign tag_o  = tag_4;
    assign tag_rq = tag_2;

    // ---- T1: levels 1 and 2 (L = value sums, N = neg counts) ----------------
    wire signed [8:0]  L1 [0:63];
    wire [1:0]         N1 [0:63];
    reg  signed [9:0]  L2 [0:31];
    reg  [2:0]         N2 [0:31];
    genvar i;
    generate
        for (i = 0; i < 64; i = i + 1) begin : G_L1
            assign L1[i] = $signed(sel[(2*i)*8 +: 8]) + $signed(sel[(2*i+1)*8 +: 8]);
            assign N1[i] = {1'b0, neg[2*i]} + {1'b0, neg[2*i+1]};
        end
        for (i = 0; i < 32; i = i + 1) begin : G_L2
            always @(posedge clk) if (ce) begin
                L2[i] <= L1[2*i] + L1[2*i+1];
                N2[i] <= {1'b0, N1[2*i]} + {1'b0, N1[2*i+1]};
            end
        end
    endgenerate

    // ---- T2: levels 3 and 4 -------------------------------------------------
    wire signed [10:0] L3 [0:15];
    wire [3:0]         N3 [0:15];
    reg  signed [11:0] L4 [0:7];
    reg  [4:0]         N4 [0:7];
    generate
        for (i = 0; i < 16; i = i + 1) begin : G_L3
            assign L3[i] = L2[2*i] + L2[2*i+1];
            assign N3[i] = {1'b0, N2[2*i]} + {1'b0, N2[2*i+1]};
        end
        for (i = 0; i < 8; i = i + 1) begin : G_L4
            always @(posedge clk) if (ce) begin
                L4[i] <= L3[2*i] + L3[2*i+1];
                N4[i] <= {1'b0, N3[2*i]} + {1'b0, N3[2*i+1]};
            end
        end
    endgenerate

    // ---- T3: levels 5 and 6, plus the early-tap carrier ---------------------
    wire signed [12:0] L5 [0:3];
    wire [5:0]         N5 [0:3];
    reg  signed [13:0] L6 [0:1];
    reg  [6:0]         N6 [0:1];
    generate
        for (i = 0; i < 4; i = i + 1) begin : G_L5
            assign L5[i] = L4[2*i] + L4[2*i+1];
            assign N5[i] = {1'b0, N4[2*i]} + {1'b0, N4[2*i+1]};
        end
        for (i = 0; i < 2; i = i + 1) begin : G_L6
            always @(posedge clk) if (ce) begin
                L6[i] <= L5[2*i] + L5[2*i+1];
                N6[i] <= {1'b0, N5[2*i]} + {1'b0, N5[2*i+1]};
            end
        end
    endgenerate

    // Carrier with 13-bit slots (level 5 is the wider early tap): level 4 for
    // pack code 3, level 5 otherwise. pack_2 is the pack of the item whose
    // level-4 registers are being read.
    reg signed [12:0] tap  [0:OCMAX-1];
    reg        [5:0]  tapn [0:OCMAX-1];
    integer q;
    always @(posedge clk) if (ce) begin
        for (q = 0; q < OCMAX; q = q + 1) begin
            if (pack_2 == 2'd3) begin           // level 4
                tap [q] <= {{1{L4[q][11]}}, L4[q]};
                tapn[q] <= {1'b0, N4[q]};
            end else begin                      // level 5 (q[1:0] wraps)
                tap [q] <= L5[q[1:0]];
                tapn[q] <= N5[q[1:0]];
            end
        end
    end

    // ---- T4: root, tap select, correction -----------------------------------
    wire signed [14:0] L7 = L6[0] + L6[1];
    wire [7:0]         N7 = {1'b0, N6[0]} + {1'b0, N6[1]};

    reg signed [31:0] acc [0:OCMAX-1];
    integer s;
    always @(posedge clk) if (ce) begin
        for (s = 0; s < OCMAX; s = s + 1) begin
            case (pack_3)
`ifdef FUSE_NEG_CORRECT_AT_ROOT
                // negative-test arm: correct every tap with the whole-word count
                2'd3, 2'd2: acc[s] <= {{19{tap[s][12]}}, tap[s]} + {24'd0, N7};
                2'd1:       acc[s] <= {{18{L6[s[0]][13]}}, L6[s[0]]} + {24'd0, N7};
                default:    acc[s] <= {{17{L7[14]}}, L7} + {24'd0, N7};
`else
                2'd3, 2'd2: acc[s] <= {{19{tap[s][12]}}, tap[s]} + {26'd0, tapn[s]};
                2'd1:       acc[s] <= {{18{L6[s[0]][13]}}, L6[s[0]]} + {25'd0, N6[s[0]]};
                default:    acc[s] <= {{17{L7[14]}}, L7} + {24'd0, N7};
`endif
            endcase
        end
    end

    generate
        for (i = 0; i < OCMAX; i = i + 1) begin : G_OUT
            assign psum[i*32 +: 32] = acc[i];
        end
    endgenerate
endmodule
`default_nettype wire
