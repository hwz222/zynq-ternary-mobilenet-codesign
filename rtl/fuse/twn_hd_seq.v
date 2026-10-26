`timescale 1ns/1ps
// ============================================================================
//  twn_hd_seq.v -- head operator sequencer.
//
//  On `start` it walks the four head operators in order (op61..op64, table index 0..3).
//  For each one it replays that operator's requantisation table into twn_hd_compute,
//  starts the three data movers (input reader, weight reader, output writer) and the
//  engine from the operator's descriptor, waits for the engine and then for the writer,
//  and moves on. After the last operator it raises `done`. It does not decide when the
//  head runs; that is the caller's `start`.
//
//  Operator shapes and modes come entirely from the descriptors the processor writes.
//  The intended use is op61 = transposed conv in mode A (weight stream), op62 and op63 =
//  transposed convs in mode B (weights resident), op64 = final 1x1 (type 4, raw int32).
//
//  Mode A / mode B / type 4 are twn_hd_compute's modes. e_mode_a = !type4 & slice, where
//  `slice` is a descriptor flag (d_slice). In mode A the engine assembles the whole
//  output tensor in its 1024-word buffer, so it is legal only if 4*H*W*OC <= 8192
//  bytes; this is checked in simulation only.
//
//  Descriptor entries are written with d_we (all fields in the same cycle). The
//  requantisation table is a separate 4 x 32 x 64-bit store written through rq_*.
// ============================================================================
`default_nettype none
module twn_hd_seq #(
    parameter integer NOPS = 4          // number of operators (the index `op` is 2 bits wide)
)(
    input  wire        clk,
    input  wire        rst,

    // ---- control ----
    input  wire        start,          // one frame's worth of head, all four ops
    output reg         busy,
    output reg         done,           // 1-cycle pulse after the last operator
    output reg  [1:0]  cur_op,         // observation: operator started most recently

    // ---- descriptor table: one entry per operator, written by the processor ----
    input  wire        d_we,
    input  wire [1:0]  d_wa,           // operator index
    input  wire [39:0] d_in_base,      // base addresses of the three streams
    input  wire [39:0] d_w_base,
    input  wire [39:0] d_out_base,
    input  wire [23:0] d_in_beats,     // stream lengths in beats
    input  wire [23:0] d_w_beats,
    input  wire [23:0] d_out_beats,
    input  wire [8:0]  d_ic,
    input  wire [5:0]  d_oc,
    input  wire [6:0]  d_h,
    input  wire [6:0]  d_w,
    input  wire        d_type4,
    input  wire        d_slice,        // -> mode_a when !type4
    input  wire        d_relu,
    input  wire [15:0] d_lo,
    input  wire [15:0] d_hi,

    // ---- requantisation table write port ----
    // 256 words of 32 bits: rq_wa = {op[1:0], oc[4:0], half}; two words per 64-bit entry.
    input  wire        rq_we,
    input  wire [7:0]  rq_wa,
    input  wire [31:0] rq_wd,

    // ---- offset added to op61's input base (selects the boundary-tensor slot) ----
    input  wire [39:0] slot_off,

    // ---- to the movers ----
    output wire [39:0] m_in_base,
    output wire [23:0] m_in_beats,
    output wire [39:0] m_w_base,
    output wire [23:0] m_w_beats,
    output wire [39:0] m_out_base,
    output wire [23:0] m_out_beats,
    output reg         m_in_start,
    output reg         m_w_start,
    output reg         m_out_start,
    input  wire        m_in_done,      // one pass of the input has landed
    input  wire        m_out_done,     // the output writer has finished

    // ---- to the engine (descriptor fields and start/done) ----
    output reg         e_start,
    input  wire        e_done,
    output wire [8:0]  e_ic,
    output wire [5:0]  e_oc,
    output wire [6:0]  e_h,
    output wire [6:0]  e_w,
    output wire        e_mode_a,
    output wire        e_type4,
    output wire        e_relu,
    output wire signed [15:0] e_lo,
    output wire signed [15:0] e_hi,

    // ---- to the engine's requantisation write port (same names and widths) ----
    output reg         e_m0_we,
    output reg  [9:0]  e_rq_wa,
    output reg  signed [31:0] e_m0_wd,
    output reg         e_bias_we,
    output reg  signed [63:0] e_bias_wd,
    output reg         e_sh_we,
    output reg  [5:0]  e_sh_wd
);
    // ---------------- descriptor file ----------------
    reg [39:0] t_in_base  [0:NOPS-1];
    reg [39:0] t_w_base   [0:NOPS-1];
    reg [39:0] t_out_base [0:NOPS-1];
    reg [23:0] t_in_beats [0:NOPS-1];
    reg [23:0] t_w_beats  [0:NOPS-1];
    reg [23:0] t_out_beats[0:NOPS-1];
    reg [8:0]  t_ic       [0:NOPS-1];
    reg [5:0]  t_oc       [0:NOPS-1];
    reg [6:0]  t_h        [0:NOPS-1];
    reg [6:0]  t_w        [0:NOPS-1];
    reg [4:0]  t_flags    [0:NOPS-1];   // {relu, slice, type4} + room
    reg [15:0] t_lo       [0:NOPS-1];
    reg [15:0] t_hi       [0:NOPS-1];

    always @(posedge clk) if (d_we) begin
        t_in_base [d_wa] <= d_in_base;
        t_w_base  [d_wa] <= d_w_base;
        t_out_base[d_wa] <= d_out_base;
        t_in_beats[d_wa] <= d_in_beats;
        t_w_beats [d_wa] <= d_w_beats;
        t_out_beats[d_wa]<= d_out_beats;
        t_ic      [d_wa] <= d_ic;
        t_oc      [d_wa] <= d_oc;
        t_h       [d_wa] <= d_h;
        t_w       [d_wa] <= d_w;
        t_flags   [d_wa] <= {2'b0, d_relu, d_slice, d_type4};
        t_lo      [d_wa] <= d_lo;
        t_hi      [d_wa] <= d_hi;
    end

    // ---- simulation-only descriptor checks ----
    // Type 4 emits OC/4 beats per pixel (OC[5:2]); an OC that is not a multiple of 4
    // would silently drop the remaining channels, so op64 must declare 16.
    // synthesis translate_off
    always @(posedge clk) if (d_we && d_type4 && (d_oc[1:0] != 2'b00)) begin
        $display("FAIL hd_seq: type 4 with OC=%0d, which is not a multiple of 4", d_oc);
        $display("  twn_hd_compute emits OC[5:2] = OC/4 beats, so OC=%0d emits %0d channels",
                 d_oc, {d_oc[5:2], 2'b00});
        $display("  and the remainder are dropped in silence. op64 must declare OC=16.");
        $finish;
    end
    // synthesis translate_on

    // Mode A output size: OH*OW*OC = 4*H*W*OC bytes must fit the engine's 1024 x 64-bit buffer.
    // synthesis translate_off
    always @(posedge clk) if (d_we && !d_type4 && d_slice) begin
        if ((4 * d_h * d_w * d_oc) > 8192) begin
            $display("FAIL hd_seq: op %0d asks for mode A with H=%0d W=%0d OC=%0d",
                     d_wa, d_h, d_w, d_oc);
            $display("  mode A buffers the WHOLE output tensor in 1024 x 64 bits = 8192 bytes;");
            $display("  this descriptor needs %0d. Only op61 (8x8x32 -> 16x16x32) fits.",
                     4 * d_h * d_w * d_oc);
            $finish;
        end
    end
    // synthesis translate_on

    // ---------------- requantisation store ----------------
    // The engine holds one 32-entry table (m0 signed 18, bias signed 40, shift 6 bits), and
    // each operator needs its own, so the walk replays the current operator's 32 entries
    // into the engine before starting it. The store is 4 ops x 32 oc x 64 bits in one block
    // RAM of 256 x 32 bits. Word index = {op, oc, half}:
    //     half 0   bias[31:0]
    //     half 1   [7:0] bias[39:32]   [25:8] m0   [31:26] shift
    wire [7:0]  rq_ra;
    wire [31:0] rq_rd;
    bram_sdp #(.W(32), .D(256), .AW(8), .MODE("block")) RQTAB (
        .clk(clk), .we(rq_we), .wa(rq_wa), .wd(rq_wd),
        .ra(rq_ra), .rd(rq_rd));

    // ---------------- the walk ----------------
    localparam [2:0] S_IDLE = 3'd0,
                     S_RQ   = 3'd5,   // the operator's requant table streams in
                     S_ISSUE= 3'd1,   // movers and engine started
                     S_WAIT = 3'd2,   // engine running
                     S_DRAIN= 3'd3,   // wait for the output writer
                     S_NEXT = 3'd4;
    reg [2:0] st;
    reg [1:0] op;
    // Mode A re-reads the whole input once per (phase, oc-group) slice: 4 phases x OC/8
    // groups = OC/2 passes. S_ISSUE starts the first pass, so pass_left holds the number
    // of further passes: {OC[5:3], 2'b00} - 1. Zero for mode B and type 4, which stream the
    // input once.
    reg [4:0] pass_left;
    wire [4:0] pass_init = (e_type4 || !e_mode_a) ? 5'd0
                                                  : ({t_oc[op][5:3], 2'b00} - 5'd1);

    assign m_in_base  = (op == 2'd0) ? (t_in_base[op] + slot_off) : t_in_base[op];
    assign m_in_beats = t_in_beats[op];
    assign m_w_base   = t_w_base[op];
    assign m_w_beats  = t_w_beats[op];
    assign m_out_base = t_out_base[op];
    assign m_out_beats= t_out_beats[op];
    assign e_ic     = t_ic[op];
    assign e_oc     = t_oc[op];
    assign e_h      = t_h[op];
    assign e_w      = t_w[op];
    assign e_type4  = t_flags[op][0];
    assign e_mode_a = ~t_flags[op][0] & t_flags[op][1];   // from the slice flag, not from the shape
    assign e_relu   = t_flags[op][2];
    assign e_lo     = t_lo[op];
    assign e_hi     = t_hi[op];

    // ---------------- requantisation replay ----------------
    // rq_i walks 0..63 (32 entries x 2 words), issuing one store read per cycle; bit 6 set
    // means every read has been issued. The store answers one cycle later, so the word
    // index travels in rq_a1 and an entry is written to the engine when its second word
    // (half 1) arrives.
`ifdef HD_SEQ_BREAK_RQOP
    // Break test, simulation only: replay operator 0's table for every operator.
    wire [1:0] rq_op = 2'd0;
`else
    wire [1:0] rq_op = op;
`endif
    reg  [6:0] rq_i;
    reg        rq_v1;                    // a read was issued last cycle
    reg  [5:0] rq_a1;                    // ...for this word index
    reg [31:0] rq_w0;                    // bias[31:0], held until the second word arrives
    wire       rq_issue = (st == S_RQ) && !rq_i[6];
    assign rq_ra = {rq_op, rq_i[5:0]};

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; op <= 2'd0; busy <= 1'b0; done <= 1'b0; pass_left <= 5'd0;
            m_in_start <= 1'b0; m_w_start <= 1'b0; m_out_start <= 1'b0;
            e_start <= 1'b0; cur_op <= 2'd0;
            rq_i <= 7'd0; rq_v1 <= 1'b0; rq_a1 <= 6'd0; rq_w0 <= 32'd0;
            e_m0_we <= 1'b0; e_bias_we <= 1'b0; e_sh_we <= 1'b0;
            e_rq_wa <= 10'd0; e_m0_wd <= 32'sd0; e_bias_wd <= 64'sd0; e_sh_wd <= 6'd0;
        end else begin
            done        <= 1'b0;
            m_in_start  <= 1'b0;
            m_w_start   <= 1'b0;
            m_out_start <= 1'b0;
            e_start     <= 1'b0;
            e_m0_we     <= 1'b0;
            e_bias_we   <= 1'b0;
            e_sh_we     <= 1'b0;

            // ---- replay read pipeline, one stage deep to match bram_sdp ----
            rq_v1 <= rq_issue;
            rq_a1 <= rq_i[5:0];
            if (rq_issue) rq_i <= rq_i + 7'd1;
            if (rq_v1) begin
                if (!rq_a1[0]) rq_w0 <= rq_rd;      // word 0: bias[31:0]
                else begin
                    // word 1: sign-extend to the engine's port widths (the engine's
                    // simulation checks flag a field that does not fit 18 / 40 bits)
                    e_m0_we   <= 1'b1;
                    e_bias_we <= 1'b1;
                    e_sh_we   <= 1'b1;
                    e_rq_wa   <= {5'd0, rq_a1[5:1]};
                    e_m0_wd   <= {{14{rq_rd[25]}}, rq_rd[25:8]};
                    e_bias_wd <= {{24{rq_rd[7]}}, rq_rd[7:0], rq_w0};
                    e_sh_wd   <= rq_rd[31:26];
                end
            end

            case (st)
            S_IDLE: if (start) begin
                        op <= 2'd0; busy <= 1'b1; st <= S_RQ; rq_i <= 7'd0;
                    end
            // Leave only when every read is issued (rq_i[6]), none is in flight (!rq_v1) and
            // no write is being presented to the engine (!e_m0_we); then the whole table is
            // in the engine before S_ISSUE starts it.
            S_RQ:   if (rq_i[6] && !rq_v1 && !e_m0_we) st <= S_ISSUE;
            S_ISSUE: begin
                        // movers and engine start in the same cycle
                        m_in_start  <= 1'b1;
                        m_w_start   <= 1'b1;
                        m_out_start <= 1'b1;
                        e_start     <= 1'b1;
                        cur_op      <= op;
                        pass_left   <= pass_init;
                        st          <= S_WAIT;
                     end
            // Break tests (simulation only):
            //   HD_SEQ_BREAK_DRAIN  skips the wait for the writer
            //   HD_SEQ_BREAK_PASS   drops the mode-A input re-issue
            S_WAIT:  begin
                        // Restart the input reader for the next mode-A slice while passes
                        // remain; pass_left is 0 in mode B and type 4.
`ifndef HD_SEQ_BREAK_PASS
                        if (m_in_done && pass_left != 5'd0) begin
                            m_in_start <= 1'b1;
                            pass_left  <= pass_left - 5'd1;
                        end
`endif
`ifdef HD_SEQ_BREAK_DRAIN
                        if (e_done) st <= S_NEXT;    // skips the write drain
`else
                        if (e_done) st <= S_DRAIN;
`endif
                     end
            // e_done means the engine produced its last beat, not that the writer has put it
            // in memory; the next operator reads this one's output, so wait for the writer.
            S_DRAIN: if (m_out_done) st <= S_NEXT;
            S_NEXT:  if (op == NOPS[1:0] - 2'd1) begin
                        busy <= 1'b0; done <= 1'b1; st <= S_IDLE;
                     end else begin
                        // back through S_RQ: the next operator needs its own table
                        op <= op + 2'd1; st <= S_RQ; rq_i <= 7'd0;
                     end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
