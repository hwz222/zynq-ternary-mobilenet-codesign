// ============================================================================
//  twn_axi_wr.v -- generic AXI4 write burst master.
//
//  start (while idle) with `base` and `nbeats` writes nbeats DATA_W-wide words
//  taken from a stream (w_valid/w_ready/w_data); done pulses for one cycle after
//  the last burst's write response. The request is split into INCR bursts of at
//  most 256 beats that do not cross a 4 KB boundary. For each burst the address
//  is issued before the data, and the next burst starts only after the response
//  (bvalid) of the previous one. All byte strobes are set. bresp is not checked.
//
//  The 4 KB computation (to4k) and the address step assume 16-byte beats, i.e.
//  DATA_W = 128. base must be aligned to DATA_W/8 bytes.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module twn_axi_wr #(
    parameter ADDR_W = 40,
    parameter DATA_W = 128
)(
    input  wire              clk,
    input  wire              rstn,
    // control
    input  wire              start,
    input  wire [ADDR_W-1:0] base,
    input  wire [23:0]       nbeats,
    output reg               busy,
    output reg               done,
    // stream in
    input  wire              w_valid,
    output wire              w_ready,
    input  wire [DATA_W-1:0] w_data,
    // AXI4 AW
    output reg  [ADDR_W-1:0] awaddr,
    output reg  [7:0]        awlen,
    output wire [2:0]        awsize,
    output wire [1:0]        awburst,
    output wire [3:0]        awcache,
    output wire [2:0]        awprot,
    output reg               awvalid,
    input  wire              awready,
    // AXI4 W
    output wire [DATA_W-1:0]   wdata,
    output wire [DATA_W/8-1:0] wstrb,
    output wire                wlast,
    output wire                wvalid,
    input  wire                wready,
    // AXI4 B
    input  wire [1:0]        bresp,
    input  wire              bvalid,
    output reg               bready
);
    localparam SZ = (DATA_W==128)?4:(DATA_W==64)?3:(DATA_W==256)?5:2;
    assign awsize  = SZ[2:0];
    assign awburst = 2'b01;              // INCR
    assign awcache = 4'b0011;
    // [1] = 1: Non-secure, so the SMMU can translate and check it (see twn_axi_rd.v)
    assign awprot  = 3'b010;
    assign wstrb   = {(DATA_W/8){1'b1}};

    localparam IDLE=0, AWA=1, WD=2, WR=3, FIN=4;
    reg [2:0] st;
    reg [ADDR_W-1:0] cur;                // address of the next burst
    reg [23:0]       rem;                // beats not yet written
    reg [8:0]        blen, beat;         // current burst length; beats sent so far

    // beats until the next 4 KB boundary from cur (16-byte beats: 256 per 4 KB)
    wire [8:0] to4k  = 9'd256 - {1'b0, cur[11:4]};
    localparam [8:0] MAXB = 9'd256;
    wire [8:0] capN  = (to4k > MAXB) ? MAXB : to4k;
    wire [8:0] chunk = (rem >= {15'b0, capN}) ? capN : rem[8:0];

    wire wv = (st==WD) && w_valid;
    assign wvalid  = wv;
    assign w_ready = (st==WD) && wready;
    assign wdata   = w_data;
    assign wlast   = (st==WD) && (beat == blen-9'd1);

    always @(posedge clk) begin
        if (!rstn) begin st<=IDLE; busy<=0; done<=0; awvalid<=0; bready<=0; end
        else begin
            done<=0;
            case (st)
                IDLE: begin
                    awvalid<=0; bready<=0;
                    if (start) begin cur<=base; rem<=nbeats; busy<=1; st<=(nbeats!=0)?AWA:FIN; end
                end
                AWA: begin
                    if (!awvalid) begin
                        awaddr<=cur; awlen<=chunk-9'd1; blen<=chunk; awvalid<=1; beat<=0;
                    end else if (awready) begin
                        awvalid<=0; st<=WD;
                    end
                end
                WD: begin
                    if (wv && wready) begin
                        if (beat == blen-9'd1) begin bready<=1; st<=WR; end
                        beat <= beat + 9'd1;
                    end
                end
                WR: begin
                    if (bvalid) begin
                        bready<=0;
                        cur <= cur + (blen << SZ);
                        rem <= rem - blen;
                        st  <= (rem - blen == 0) ? FIN : AWA;
                    end
                end
                FIN: begin busy<=0; done<=1; st<=IDLE; end
            endcase
        end
    end
endmodule
`default_nettype wire
