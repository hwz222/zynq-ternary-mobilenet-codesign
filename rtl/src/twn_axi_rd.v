// ============================================================================
//  twn_axi_rd.v -- generic AXI4 read burst master.
//
//  start (while idle) with `base` and `nbeats` reads nbeats DATA_W-wide words
//  and presents them as a stream (s_valid/s_ready/s_data); done pulses for one
//  cycle after the last beat has been accepted. The request is split into INCR
//  bursts of at most 256 beats that do not cross a 4 KB boundary. One burst is
//  outstanding at a time. rresp is not checked.
//
//  The 4 KB computation (to4k) and the address step assume 16-byte beats, i.e.
//  DATA_W = 128. base must be aligned to DATA_W/8 bytes.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module twn_axi_rd #(
    parameter ADDR_W = 40,
    parameter DATA_W = 128
)(
    input  wire              clk,
    input  wire              rstn,
    // control
    input  wire              start,
    input  wire [ADDR_W-1:0] base,       // byte address
    input  wire [23:0]       nbeats,      // number of DATA_W words to read
    output reg               busy,
    output reg               done,        // 1-cycle pulse
    // stream out
    output wire              s_valid,
    input  wire              s_ready,
    output wire [DATA_W-1:0] s_data,
    // AXI4 AR
    output reg  [ADDR_W-1:0] araddr,
    output reg  [7:0]        arlen,
    output wire [2:0]        arsize,
    output wire [1:0]        arburst,
    output wire [3:0]        arcache,
    output wire [2:0]        arprot,
    output reg               arvalid,
    input  wire              arready,
    // AXI4 R
    input  wire [DATA_W-1:0] rdata,
    input  wire [1:0]        rresp,
    input  wire              rlast,
    input  wire              rvalid,
    output wire              rready
);
    localparam SZ = (DATA_W==128)?4:(DATA_W==64)?3:(DATA_W==256)?5:2;
    assign arsize  = SZ[2:0];
    assign arburst = 2'b01;              // INCR
    assign arcache = 4'b0011;
    assign arprot  = 3'b000;

    localparam IDLE=0, ADDR=1, DATA=2, FIN=3;
    reg [1:0] st;
    reg [ADDR_W-1:0] cur;                // address of the next burst
    reg [23:0]       rem;                // beats not yet requested/received
    reg [8:0]        blen;               // current burst beats (1..256)

    // beats until the next 4 KB boundary from cur (16-byte beats: 256 per 4 KB)
    wire [8:0] to4k  = 9'd256 - {1'b0, cur[11:4]};
    localparam [8:0] MAXB = 9'd256;
`ifdef AXIRD_NEG_NO_4K
    // Negative-test build only: no 4 KB split, bursts capped at 256 beats.
    wire [8:0] capN  = MAXB;
`else
    wire [8:0] capN  = (to4k > MAXB) ? MAXB : to4k;
`endif
    wire [8:0] chunk = (rem >= {15'b0, capN}) ? capN : rem[8:0];

    // rready follows s_ready combinationally; s_valid does not depend on s_ready.
    assign s_valid = (st==DATA) && rvalid;
    assign s_data  = rdata;
    assign rready  = (st==DATA) && s_ready;

    always @(posedge clk) begin
        if (!rstn) begin st<=IDLE; busy<=0; done<=0; arvalid<=0; end
        else begin
            done<=0;
            case (st)
                IDLE: begin
                    arvalid<=0;
                    if (start) begin
                        cur<=base; rem<=nbeats; busy<=1;
                        st <= (nbeats!=0) ? ADDR : FIN;
                    end
                end
                ADDR: begin
                    if (!arvalid) begin
                        araddr<=cur; arlen<=chunk-9'd1; blen<=chunk; arvalid<=1;
                    end else if (arready) begin
                        arvalid<=0; st<=DATA;
                    end
                end
                DATA: begin
                    if (rvalid && rready && rlast) begin
                        cur <= cur + (blen << SZ);
                        rem <= rem - blen;
                        st  <= (rem - blen == 0) ? FIN : ADDR;
                    end
                end
                FIN: begin busy<=0; done<=1; st<=IDLE; end
            endcase
        end
    end
endmodule
`default_nettype wire
