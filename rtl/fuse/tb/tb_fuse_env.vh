// ============================================================================
//  tb_fuse_env.vh -- AXI-Lite driver, descriptor load and boot sequence shared
//  by the top-level testbench (tb_fuse_frame.v).
//
//  The register map is rtl/fuse/twn_csr.v's (16-bit window, PS-written
//  descriptors), the same one sw/app/pl_hal_fuse.c uses.
//  twn_csr starts a frame only if (w_hold[0] && tab_checked && d_valid); a
//  refused start gives no error on the CTRL write, so fuse_boot() decodes
//  err_code / err_block from STATUS and prints the refusal.
//  Descriptor words come from tb_desctab_words.vh, written by
//  tools/gen_desctab.py from the same manifest that produces
//  tools/fuse_desctab.h for the PS driver.
//
//  The including module declares `wire clk` before this file. Provides:
//      s_* AXI-Lite signals (connect to twn_fuse_top), lite_wr / lite_rd,
//      env_init (park the driver before reset is released),
//      fuse_load_desctab (DT_NBLK x 16 words), fuse_boot (the whole sequence).
// ============================================================================

`include "tb_desctab_words.vh"

// ---- the register map (twn_csr.v) ----
localparam [15:0] F_CTRL      = 16'h0000,   // W: [0] start [1] clear done [2] irq_en
                                            // R: [0] ap_start [1] busy [2] ap_done [3] irq_en
                  F_NBLK      = 16'h0008,
                  F_ACT_LO    = 16'h000c, F_ACT_HI = 16'h0010,
                  F_W_LO      = 16'h0014, F_W_HI   = 16'h0018,
                  F_IN_LO     = 16'h001c, F_IN_HI  = 16'h0020,
                  F_OUT_LO    = 16'h0024, F_OUT_HI = 16'h0028,
                  F_STATUS    = 16'h002c,  // [0] d_valid [1] tab_checked
                                           // [6:2] cur_block [10:7] err_code
                                           // [15:11] err_block [16] ring_overrun
                  F_CHECK     = 16'h0030,
                  F_CYC_TOTAL = 16'h0034, F_CYC_ARRAY = 16'h0038,
                  F_CYC_DW    = 16'h003c, F_CYC_STALL = 16'h0040,
                  F_CYC_PRE   = 16'h0044, F_CYC_POST  = 16'h0048,
                  F_DESC_BASE = 16'h1000;  // descriptor words; index = addr[10:2]

localparam [31:0] CTRL_START     = 32'h1,
                  CTRL_CLR_DONE  = 32'h2;
localparam [31:0] ST_D_VALID     = 32'h1,
                  ST_TAB_CHECKED = 32'h2,
                  ST_OVERRUN     = 32'h1_0000;

// ---- the AXI-Lite driver ----
reg  [15:0] s_awaddr;  reg s_awvalid;  wire s_awready;
reg  [31:0] s_wdata;   reg s_wvalid;   wire s_wready;
wire [3:0]  s_wstrb = 4'hF;            // whole words only, as the driver writes
wire [1:0]  s_bresp;   wire s_bvalid;  reg s_bready;
reg  [15:0] s_araddr;  reg s_arvalid;  wire s_arready;
wire [31:0] s_rdata;   wire [1:0] s_rresp;  wire s_rvalid;  reg s_rready;

integer env_errors = 0;

// twn_desctab.v's err_code values
function [8*12-1:0] err_name;
    input [3:0] code;
    begin
        case (code)
            4'd0: err_name = "none";
            4'd1: err_name = "SLOT_RANGE";
            4'd2: err_name = "SLOT_SAME";
            4'd3: err_name = "SLOT_CHAIN";
            4'd4: err_name = "TERN_OVF";
            4'd5: err_name = "DW_OVF";
            4'd6: err_name = "RQA_OVF";
            4'd7: err_name = "RQD_OVF";
            4'd8: err_name = "GEOM";
            default: err_name = "?";
        endcase
    end
endfunction

task env_init;
    begin
        s_awaddr = 16'd0; s_awvalid = 1'b0;
        s_wdata  = 32'd0; s_wvalid  = 1'b0; s_bready = 1'b0;
        s_araddr = 16'd0; s_arvalid = 1'b0; s_rready = 1'b0;
    end
endtask

// One AXI-Lite write (the same two-phase accept as tb_desctab.v's `wr`).
task lite_wr;
    input [15:0] a;
    input [31:0] d;
    begin
        @(posedge clk);
        s_awaddr <= a; s_awvalid <= 1'b1; s_wdata <= d; s_wvalid <= 1'b1;
        s_bready <= 1'b1;
        @(posedge clk);
        while (!(s_awready && s_awvalid)) @(posedge clk);
        s_awvalid <= 1'b0;
        while (!(s_wready && s_wvalid)) @(posedge clk);
        s_wvalid <= 1'b0;
        while (!s_bvalid) @(posedge clk);
        @(posedge clk); s_bready <= 1'b0;
    end
endtask

// One AXI-Lite read. twn_csr registers arready as `!rvalid` and puts rdata up
// with rvalid, so the data is valid on the cycle rvalid is seen high.
task lite_rd;
    input  [15:0] a;
    output [31:0] d;
    begin
        @(posedge clk);
        s_araddr <= a; s_arvalid <= 1'b1; s_rready <= 1'b1;
        @(posedge clk);
        while (!(s_arready && s_arvalid)) @(posedge clk);
        s_arvalid <= 1'b0;
        while (!s_rvalid) @(posedge clk);
        d = s_rdata;
        @(posedge clk); s_rready <= 1'b0;
    end
endtask

// The descriptor words, written as fuse_load_desctab() does on the board.
task fuse_load_desctab;
    integer b, w;
    begin
        for (b = 0; b < DT_NBLK; b = b + 1)
            for (w = 0; w < 16; w = w + 1)
                lite_wr(F_DESC_BASE + (b * 16 + w) * 4,
                        DT_WORDS[(b * 16 + w) * 32 +: 32]);
    end
endtask

// ---- the whole boot, in the driver's order ----
//   descriptors -> N_BLOCKS -> W_BASE / ACT_BASE / IN_PTR -> CHECK -> poll
// OUT_PTR is not written by this task (twn_fuse_top uses it as the last block's write base).
task fuse_boot;
    input [39:0] w_base;
    input [39:0] act_base;
    input [39:0] in_ptr;
    output       ok;
    reg [31:0] st;
    integer spin;
    begin
        ok = 1'b0;
        fuse_load_desctab();
        lite_wr(F_NBLK,   DT_NBLK);
        lite_wr(F_W_LO,   w_base[31:0]);    lite_wr(F_W_HI,   {24'd0, w_base[39:32]});
        lite_wr(F_ACT_LO, act_base[31:0]);  lite_wr(F_ACT_HI, {24'd0, act_base[39:32]});
        lite_wr(F_IN_LO,  in_ptr[31:0]);    lite_wr(F_IN_HI,  {24'd0, in_ptr[39:32]});
        lite_wr(F_CHECK,  32'd1);

        st = 32'd0; spin = 0;
        while (!(st & ST_TAB_CHECKED) && spin < 5000) begin
            lite_rd(F_STATUS, st);
            spin = spin + 1;
        end
        if (!(st & ST_TAB_CHECKED)) begin
            env_errors = env_errors + 1;
            $display("  BOOT: the descriptor check NEVER COMPLETED (STATUS %08h).", st);
            $display("        twn_desctab's walk did not raise check_done; nothing downstream will start.");
        end else if (!(st & ST_D_VALID)) begin
            env_errors = env_errors + 1;
            // A refused start is silent in hardware -- twn_csr reports nothing
            // on the CTRL write itself -- so it must not be silent here.
            $display("  BOOT: descriptor table REFUSED -- %0s at block %0d (STATUS %08h)",
                     err_name(st[10:7]), st[15:11], st);
            $display("        twn_csr will not raise ap_start: the gate is (w_hold[0] && tab_checked && d_valid).");
        end else begin
            ok = 1'b1;
            $display("  BOOT: %0d descriptors loaded, table CHECKED and VALID (STATUS %08h)",
                     DT_NBLK, st);
        end
    end
endtask
