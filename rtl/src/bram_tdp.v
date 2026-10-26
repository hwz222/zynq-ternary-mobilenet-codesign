// ============================================================================
//  bram_tdp.v -- true dual-port RAM on one clock, registered read on both ports
//  (rda/rdb valid one cycle after aa/ab). Port A can write (wea) and read; port
//  B is read-only (web is tied low). ena/enb gate the read registers (and, on
//  port A, the write). Read-first. With USE_XPM defined it instantiates
//  xpm_memory_tdpram (block RAM); otherwise it is a behavioural array.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module bram_tdp #(
    parameter W  = 128,
    parameter D  = 1560,
    parameter AW = 11
)(
    input  wire          clk,
    input  wire          ena,
    input  wire          wea,
    input  wire [AW-1:0] aa,
    input  wire [W-1:0]  wd,
    output wire [W-1:0]  rda,
    input  wire          enb,
    input  wire [AW-1:0] ab,
    output wire [W-1:0]  rdb
);
`ifdef USE_XPM
    xpm_memory_tdpram #(
        .ADDR_WIDTH_A(AW), .ADDR_WIDTH_B(AW),
        .WRITE_DATA_WIDTH_A(W), .READ_DATA_WIDTH_A(W),
        .WRITE_DATA_WIDTH_B(W), .READ_DATA_WIDTH_B(W),
        .BYTE_WRITE_WIDTH_A(W), .BYTE_WRITE_WIDTH_B(W),
        .MEMORY_SIZE(D*W), .MEMORY_PRIMITIVE("block"),
        .READ_LATENCY_A(1), .READ_LATENCY_B(1),
        .CLOCKING_MODE("common_clock"),
        .WRITE_MODE_A("read_first"), .WRITE_MODE_B("read_first"),
        .READ_RESET_VALUE_A("0"), .READ_RESET_VALUE_B("0"),
        .USE_MEM_INIT(0), .ECC_MODE("no_ecc")
    ) u (
        .clka(clk), .ena(ena), .wea(wea), .addra(aa), .dina(wd), .douta(rda),
        .injectsbiterra(1'b0), .injectdbiterra(1'b0), .regcea(1'b1),
        .sbiterra(), .dbiterra(),
        .clkb(clk), .enb(enb), .web(1'b0), .addrb(ab), .dinb({W{1'b0}}), .doutb(rdb),
        .injectsbiterrb(1'b0), .injectdbiterrb(1'b0), .regceb(1'b1),
        .sbiterrb(), .dbiterrb(),
        .rsta(1'b0), .rstb(1'b0), .sleep(1'b0)
    );
`else
    reg [W-1:0] mem[0:D-1];
    reg [W-1:0] rda_r, rdb_r;
    always @(posedge clk) begin
        if (ena) begin
            if (wea) mem[aa] <= wd;
            rda_r <= mem[aa];
        end
        if (enb) rdb_r <= mem[ab];
    end
    assign rda = rda_r;
    assign rdb = rdb_r;
`endif
endmodule
`default_nettype wire
