// ============================================================================
//  bram_sdp.v -- simple dual-port RAM, one write port and one read port on the
//  same clock, registered read (rd is valid one cycle after ra). Read-first: a
//  read of the address being written in the same cycle returns the old data.
//  With USE_XPM defined it instantiates xpm_memory_sdpram with
//  MEMORY_PRIMITIVE = MODE; otherwise it is a behavioural array with the same
//  behaviour.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module bram_sdp #(
    parameter W  = 1024,       // data width
    parameter D  = 120,        // depth in words
    parameter AW = 7,          // address width, >= clog2(D)
    parameter MODE = "block"   // "block" (block RAM) or "distributed" (LUT RAM)
)(
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [W-1:0]  wd,
    input  wire [AW-1:0] ra,
    output wire [W-1:0]  rd
);
`ifdef USE_XPM
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(AW), .ADDR_WIDTH_B(AW),
        .WRITE_DATA_WIDTH_A(W), .READ_DATA_WIDTH_B(W),
        .BYTE_WRITE_WIDTH_A(W), .MEMORY_SIZE(D*W),
        .MEMORY_PRIMITIVE(MODE), .READ_LATENCY_B(1),
        .CLOCKING_MODE("common_clock"), .WRITE_MODE_B("read_first"),
        .READ_RESET_VALUE_B("0"), .USE_MEM_INIT(0), .ECC_MODE("no_ecc")
    ) u (
        .clka(clk), .ena(1'b1), .wea(we), .addra(wa), .dina(wd),
        .injectsbiterra(1'b0), .injectdbiterra(1'b0),
        .clkb(clk), .enb(1'b1), .addrb(ra), .doutb(rd),
        .rstb(1'b0), .regceb(1'b1), .sbiterrb(), .dbiterrb(), .sleep(1'b0)
    );
`else
    (* ram_style=MODE *) reg [W-1:0] mem[0:D-1];
    reg [W-1:0] rd_r;
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd_r <= mem[ra];
    end
    assign rd = rd_r;
`endif
endmodule
`default_nettype wire
