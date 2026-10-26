// tb_act_rt.v -- twn_act_wr -> modelled DDR -> twn_act_rd round trip.
//
// Real: twn_act_wr, twn_act_rd (with the twn_axi_wr / twn_axi_rd inside them).
// Modelled: one DDR array shared by both masters, a source row buffer for the
//   writer, and a sink for the reader that deasserts wr_can at random.
// Checks, for the (slot, row, row_bytes) cases listed in the initial block:
//   - the first AW and AR address equal act_base + (slot << SLOT_LOG2) + row * row_bytes,
//     computed in the testbench;
//   - the 1024-bit words the reader delivers equal the 128-bit beats the writer sent;
//   - wr_en is only presented in a cycle after wr_can was high, and wr_can was low
//     at least once.
// The write and read slaves stall and gap on both channels. Slot code 4'hF is
// run as slot 0 (the writer has no in_ptr path), so the reader's in_ptr path is
// not exercised here. Cases include a row that crosses a 4 KB boundary (row 1 of
// 2,560 bytes). No inputs from files, no `ifdef break arms. 20 ms timeout.
`timescale 1ns/1ps
`default_nettype none

module tb_act_rt;
    localparam integer ADDR_W = 32;
    localparam integer SLOT_LOG2 = 18;
    localparam integer NBEAT = 1 << 16;          // 1 MB of modelled DDR
    localparam [ADDR_W-1:0] ACT_BASE = 32'h0001_0000;
    localparam [ADDR_W-1:0] IN_PTR   = 32'h000C_0000;

    reg clk = 1'b0, rstn = 1'b0;
    always #2 clk = ~clk;

    reg [127:0] ddr [0:NBEAT-1];

    // ================= the write side =================
    reg  [ADDR_W-1:0] w_base_r;
    reg  [3:0]        w_slot;
    reg  [8:0]        w_row;
    reg  [15:0]       w_bytes;
    reg               w_start = 1'b0;
    wire              w_busy, w_done;

    reg  [127:0] src [0:511];                    // the row buffer the writer reads
    wire [15:0]  rb_word;
    wire         rb_re;
    reg  [127:0] rb_data;
    always @(posedge clk) if (rb_re) rb_data <= src[rb_word[8:0]];

    wire [ADDR_W-1:0] awaddr; wire [7:0] awlen; wire [2:0] awsize;
    wire [1:0] awburst; wire [3:0] awcache; wire [2:0] awprot;
    wire awvalid; reg awready;
    wire [127:0] wdata; wire [15:0] wstrb; wire wlast, wvalid; reg wready;
    reg bvalid; wire bready;

    twn_act_wr #(.ADDR_W(ADDR_W), .ROW_BITS(128), .SLOT_LOG2(SLOT_LOG2)) WRM (
        .clk(clk), .rstn(rstn), .start(w_start), .act_base(ACT_BASE),
        .slot(w_slot), .row(w_row), .row_bytes(w_bytes),
        .busy(w_busy), .done(w_done),
        .rb_word(rb_word), .rb_re(rb_re), .rb_data(rb_data),
        .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awcache(awcache), .awprot(awprot), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(2'b00), .bvalid(bvalid), .bready(bready));

    // a write slave that stalls
    reg [ADDR_W-1:0] w_addr_c;
    reg [15:0]       lfsr_w = 16'hBEEF;
    reg [31:0]       n_aw = 0, n_wbeat = 0;
    reg [ADDR_W-1:0] first_aw; reg got_aw;
    always @(posedge clk) begin
        if (!rstn) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; got_aw <= 1'b0;
        end else begin
            lfsr_w <= {lfsr_w[14:0], lfsr_w[15]^lfsr_w[13]^lfsr_w[12]^lfsr_w[10]};
            awready <= lfsr_w[2];
            wready  <= (lfsr_w[5:4] != 2'b00);
            if (awvalid && awready) begin
                w_addr_c <= awaddr; n_aw <= n_aw + 1;
                if (!got_aw) begin first_aw <= awaddr; got_aw <= 1'b1; end
            end
            if (wvalid && wready) begin
                ddr[w_addr_c[ADDR_W-1:4]] <= wdata;
                w_addr_c <= w_addr_c + 16;
                n_wbeat <= n_wbeat + 1;
            end
            bvalid <= (wvalid && wready && wlast);
        end
    end

    // ================= the read side =================
    reg  [3:0]  r_slot;
    reg  [8:0]  r_row;
    reg  [15:0] r_bytes;
    reg         r_start = 1'b0;
    wire        r_busy, r_done;
    wire [1023:0] rb_wr_data;
    wire          rb_wr_en, rb_wr_last;

    wire [ADDR_W-1:0] araddr; wire [7:0] arlen; wire [2:0] arsize;
    wire [1:0] arburst; wire [3:0] arcache; wire [2:0] arprot;
    wire arvalid; reg arready;
    reg [127:0] rdata; reg rlast, rvalid; wire rready;

    twn_act_rd #(.ADDR_W(ADDR_W), .ROW_BITS(1024), .SLOT_LOG2(SLOT_LOG2)) RDM (
        .clk(clk), .rstn(rstn), .start(r_start), .act_base(ACT_BASE),
        .slot(r_slot), .in_ptr(IN_PTR), .row(r_row), .row_bytes(r_bytes),
        .busy(r_busy), .done(r_done),
        .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(2'b00), .rlast(rlast), .rvalid(rvalid), .rready(rready),
        .wr_can(rb_wr_can),
        .wr_en(rb_wr_en), .wr_data(rb_wr_data), .wr_row_last(rb_wr_last));

    // ---- sink that refuses ----
    // The stall is on the R channel, so a beat taken twice or a word lost
    // shows up as a shifted or missing word in the comparison below.
    reg [15:0] bp_lfsr = 16'hBEEF;
    reg        rb_wr_can;
    always @(posedge clk) begin
        if (!rstn) begin bp_lfsr <= 16'hBEEF; rb_wr_can <= 1'b1; end
        else begin
            bp_lfsr <= {bp_lfsr[14:0], bp_lfsr[15]^bp_lfsr[13]^bp_lfsr[12]^bp_lfsr[10]};
            // about half the cycles, with runs of both -- bounded, so the read
            // always finishes and a hang is a real hang
            rb_wr_can <= bp_lfsr[4] | bp_lfsr[9];
        end
    end

    // wr_can is a promise about the next cycle: a word may only be presented in
    // a cycle whose predecessor promised it.
    reg  wr_can_q;
    integer bp_viol = 0, bp_stalled = 0;
    always @(posedge clk) if (rstn) begin
        wr_can_q <= rb_wr_can;
        if (!rb_wr_can) bp_stalled = bp_stalled + 1;
        if (rb_wr_en && !wr_can_q) bp_viol = bp_viol + 1;
    end

    reg [ADDR_W-1:0] s_addr; reg [8:0] s_left; reg s_run = 1'b0;
    reg [15:0] lfsr_r = 16'hACE1;
    reg [31:0] n_ar = 0, n_rbeat = 0;
    reg [ADDR_W-1:0] first_ar; reg got_ar;
    always @(posedge clk) begin
        if (!rstn) begin
            arready <= 1'b0; rvalid <= 1'b0; rlast <= 1'b0; s_run <= 1'b0;
            got_ar <= 1'b0;
        end else begin
            lfsr_r <= {lfsr_r[14:0], lfsr_r[15]^lfsr_r[13]^lfsr_r[12]^lfsr_r[10]};
            arready <= !s_run && !arready;
            if (arvalid && arready) begin
                s_addr <= araddr; s_left <= {1'b0, arlen} + 9'd1;
                s_run <= 1'b1; arready <= 1'b0; n_ar <= n_ar + 1;
                if (!got_ar) begin first_ar <= araddr; got_ar <= 1'b1; end
            end
            if (s_run && (!rvalid || rready)) begin
                if (lfsr_r[3:0] == 4'h5) begin
                    rvalid <= 1'b0;
                end else begin
                    rdata <= ddr[s_addr[ADDR_W-1:4]];
                    rlast <= (s_left == 9'd1);
                    rvalid <= 1'b1;
                    s_addr <= s_addr + 16; s_left <= s_left - 9'd1;
                    n_rbeat <= n_rbeat + 1;
                    if (s_left == 9'd1) s_run <= 1'b0;
                end
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    // ================= the check =================
    reg [1023:0] got [0:63];
    integer      n_got;
    always @(posedge clk) if (rstn && rb_wr_en) begin
        got[n_got] = rb_wr_data;
        n_got = n_got + 1;
    end

    integer errors = 0, cases = 0, values = 0;
    integer i, j, w;
    reg [ADDR_W-1:0] want_addr;
    reg [127:0]      want;

    task one;
        input [3:0]  slot;
        input [8:0]  row;
        input [15:0] nbytes;
        integer k, nw;
        begin
            cases = cases + 1;
            for (k = 0; k < nbytes / 16; k = k + 1)
                src[k] = {slot, row[7:0], 4'hA, k[15:0], nbytes,
                          32'hDEAD0000 + k[31:0], 32'h5A5A0000 + k[31:0]};

            // ---- write it ----
            got_aw = 1'b0;
            w_slot = (slot == 4'hF) ? 4'd0 : slot;   // the writer has no IN_PTR path
            w_row = row; w_bytes = nbytes;
            @(posedge clk); w_start = 1'b1; @(posedge clk); w_start = 1'b0;
            wait (w_done); @(posedge clk);

            // the address, checked against the formula in the testbench, not against
            // the other module
            want_addr = ACT_BASE + ({{(ADDR_W-4){1'b0}}, w_slot} << SLOT_LOG2)
                        + row * nbytes;
            if (first_aw !== want_addr) begin
                errors = errors + 1;
                $display("  write addr %h, want %h  (slot %0d row %0d)",
                         first_aw, want_addr, w_slot, row);
            end

            // ---- read it back ----
            n_got = 0; got_ar = 1'b0;
            r_slot = w_slot; r_row = row; r_bytes = nbytes;
            @(posedge clk); r_start = 1'b1; @(posedge clk); r_start = 1'b0;
            wait (r_done); @(posedge clk); @(posedge clk);

            if (first_ar !== want_addr) begin
                errors = errors + 1;
                $display("  read addr %h, want %h", first_ar, want_addr);
            end

            nw = (nbytes / 16) / 8;                 // 1024-bit words
            if (n_got !== nw) begin
                errors = errors + 1;
                $display("  slot %0d row %0d: %0d words back, want %0d",
                         w_slot, row, n_got, nw);
            end
            for (k = 0; k < nw; k = k + 1)
                for (j = 0; j < 8; j = j + 1) begin
                    values = values + 1;
                    want = src[k * 8 + j];
                    if (got[k][j*128 +: 128] !== want) begin
                        errors = errors + 1;
                        if (errors < 8)
                            $display("  slot %0d row %0d word %0d beat %0d differs",
                                     w_slot, row, k, j);
                    end
                end
        end
    endtask

    initial begin
        n_got = 0;
        rstn = 1'b0;
        repeat (8) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk);

        // real row sizes, rows that cross or end on a 4 KB boundary, and row 0
        one(4'd0,  9'd0,   16'd2048);      // block 0's output row, the largest
        one(4'd1,  9'd0,   16'd2048);      // the other slot
        one(4'd0,  9'd3,   16'd2048);      // 6,144 -> ends exactly ON 4 KB
        one(4'd0,  9'd1,   16'd2560);      // 2,560..5,120 -> genuinely CROSSES it,
                                           // so twn_axi_rd/wr must split the burst
        one(4'd1,  9'd63,  16'd1024);      // 64,512, deep in the tensor
        one(4'd0,  9'd127,16'd128);
        one(4'd1,  9'd7,   16'd1536);      // 10,752, an odd multiple
        one(4'd0,  9'd1,   16'd512);
        one(4'hF,  9'd0,   16'd768);       // slot code 4'hF, run as slot 0

        if (bp_viol != 0) begin
            errors = errors + 1;
            $display("  wr_en fired on %0d cycles whose predecessor did not promise it --",
                     bp_viol);
            $display("  the word was presented into a sink that had said no.");
        end
        if (bp_stalled == 0) begin
            errors = errors + 1;
            $display("  the sink never refused once -- the back-pressure was not exercised,");
            $display("  which is the state this gate was in while RingA lost 93 writes a frame.");
        end
        $display("  sink refused on %0d cycles; %0d contract violations", bp_stalled, bp_viol);
        $display("=== tb_act_rt: %0d cases, %0d beats compared, %0d errors, %0d AW, %0d AR, %s ===",
                 cases, values, errors, n_aw, n_ar,
                 (errors == 0 && values > 0) ? "ALL PASS" : "FAIL");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("=== tb_act_rt: TIMEOUT after %0d cases, %0d errors ===", cases, errors);
        $finish;
    end
endmodule
`default_nettype wire
