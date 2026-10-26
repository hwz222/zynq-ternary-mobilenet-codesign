// ============================================================================
//  bram_sdp_bw.v -- simple dual-port RAM with per-lane write enable and a
//  registered, enable-gated read (rd is valid one cycle after ra when en is high).
//  The word is W bits wide and split into W/BW lanes of BW bits; wea has one bit
//  per lane and a lane is written from the same bit positions of wd. Read-first.
//  With USE_XPM defined it instantiates xpm_memory_sdpram (block RAM);
//  otherwise it is a behavioural array.
//
//  en gates the read register, which is a pipeline stage: if the reader's
//  pipeline stalls while this register keeps clocking, it fetches the next
//  address's data and the resumed stage captures the wrong word. Tie en to the
//  reader's clock enable, or to 1'b1 only if the reader never stalls.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none
module bram_sdp_bw #(
    parameter W  = 576,
    parameter D  = 120,
    parameter AW = 7,
    parameter BW = 8               // write granularity (bits); W/BW lanes
)(
    input  wire            clk,
    input  wire [W/BW-1:0] wea,    // per-lane write enable
    input  wire [AW-1:0]   wa,
    input  wire [W-1:0]    wd,     // lane b is written from wd[b*BW +: BW] where wea[b]=1
    input  wire [AW-1:0]   ra,
    input  wire            en,     // read-register enable
    output wire [W-1:0]    rd
);
`ifdef USE_XPM
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(AW), .ADDR_WIDTH_B(AW),
        .WRITE_DATA_WIDTH_A(W), .READ_DATA_WIDTH_B(W),
        .BYTE_WRITE_WIDTH_A(BW), .MEMORY_SIZE(D*W),
        .MEMORY_PRIMITIVE("block"), .READ_LATENCY_B(1),
        .CLOCKING_MODE("common_clock"), .WRITE_MODE_B("read_first"),
        .READ_RESET_VALUE_B("0"), .USE_MEM_INIT(0), .ECC_MODE("no_ecc")
    ) u (
        .clka(clk), .ena(1'b1), .wea(wea), .addra(wa), .dina(wd),
        .injectsbiterra(1'b0), .injectdbiterra(1'b0),
        .clkb(clk), .enb(en), .addrb(ra), .doutb(rd),
        .rstb(1'b0), .regceb(1'b1), .sbiterrb(), .dbiterrb(), .sleep(1'b0)
    );
`else
    (* ram_style="block" *) reg [W-1:0] mem[0:D-1];
    reg [W-1:0] rd_r; integer b;
    always @(posedge clk) begin
        for (b=0; b<W/BW; b=b+1) if (wea[b]) mem[wa][b*BW +: BW] <= wd[b*BW +: BW];
        if (en) rd_r <= mem[ra];
    end
    assign rd = rd_r;
`endif
endmodule
`default_nettype wire
