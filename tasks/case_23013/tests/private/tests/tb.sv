`include "VX_define.vh"

module tb import VX_gpu_pkg::*; ();
    localparam NUM_LANES = `VX_CFG_NUM_LSU_LANES; // 2
    localparam NUM_BANKS = `VX_CFG_LMEM_NUM_BANKS; // 8

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic                                   lsu_req_valid;
    wire                                    lsu_req_ready;
    logic [NUM_LANES-1:0]                   lsu_req_mask;
    logic                                   lsu_req_rw;
    logic [NUM_LANES-1:0][15:0]             lsu_req_addr;
    logic [NUM_LANES-1:0][63:0]             lsu_req_data;
    logic [NUM_LANES-1:0][7:0]              lsu_req_byteen;
    logic [NUM_LANES-1:0][MEM_ATTR_WIDTH-1:0] lsu_req_user;
    logic [LSU_TAG_WIDTH-1:0]               lsu_req_tag;

    wire                                    lsu_rsp_valid;
    logic                                   lsu_rsp_ready;
    wire  [NUM_LANES-1:0]                   lsu_rsp_mask;
    wire  [NUM_LANES-1:0][63:0]             lsu_rsp_data;
    wire  [LSU_TAG_WIDTH-1:0]               lsu_rsp_tag;

    wire                                    global_req_valid;
    logic                                   global_req_ready;
    wire  [NUM_LANES-1:0]                   global_req_mask;
    wire                                    global_req_rw;
    wire  [NUM_LANES-1:0][15:0]             global_req_addr;
    wire  [NUM_LANES-1:0][63:0]             global_req_data;
    wire  [NUM_LANES-1:0][7:0]              global_req_byteen;
    wire  [NUM_LANES-1:0][MEM_ATTR_WIDTH-1:0] global_req_user;
    wire  [LSU_TAG_WIDTH-1:0]               global_req_tag;

    logic                                   global_rsp_valid;
    wire                                    global_rsp_ready;
    logic [NUM_LANES-1:0]                   global_rsp_mask;
    logic [NUM_LANES-1:0][63:0]             global_rsp_data;
    logic [LSU_TAG_WIDTH-1:0]               global_rsp_tag;

    logic                                   dma_stage_we;
    logic [2:0]                             dma_stage_bank;
    logic [63:0]                            dma_stage_wdata;
    logic [7:0]                             dma_stage_byteen;

    logic                                   dma_req_valid;
    wire                                    dma_req_ready;
    logic                                   dma_req_rw;
    logic [7:0]                             dma_req_addr;
    logic [3:0]                             dma_req_tag;

    wire                                    dma_rsp_valid;
    logic                                   dma_rsp_ready;
    wire  [3:0]                             dma_rsp_tag;
    logic [2:0]                             dma_rsp_bank_sel;
    wire  [63:0]                            dma_rsp_rdata;

    VX_lmem_subsys dut (.*);

    // Continuous assertion on hard SRAM macro port contract: never simultaneous A_WEN && A_REN
    wire [7:0] sram_men_mon = {
        dut.u_local_mem.u_lmem_bank_7.A_MEN, dut.u_local_mem.u_lmem_bank_6.A_MEN,
        dut.u_local_mem.u_lmem_bank_5.A_MEN, dut.u_local_mem.u_lmem_bank_4.A_MEN,
        dut.u_local_mem.u_lmem_bank_3.A_MEN, dut.u_local_mem.u_lmem_bank_2.A_MEN,
        dut.u_local_mem.u_lmem_bank_1.A_MEN, dut.u_local_mem.u_lmem_bank_0.A_MEN
    };
    wire [7:0] sram_wen_mon = {
        dut.u_local_mem.u_lmem_bank_7.A_WEN, dut.u_local_mem.u_lmem_bank_6.A_WEN,
        dut.u_local_mem.u_lmem_bank_5.A_WEN, dut.u_local_mem.u_lmem_bank_4.A_WEN,
        dut.u_local_mem.u_lmem_bank_3.A_WEN, dut.u_local_mem.u_lmem_bank_2.A_WEN,
        dut.u_local_mem.u_lmem_bank_1.A_WEN, dut.u_local_mem.u_lmem_bank_0.A_WEN
    };
    wire [7:0] sram_ren_mon = {
        dut.u_local_mem.u_lmem_bank_7.A_REN, dut.u_local_mem.u_lmem_bank_6.A_REN,
        dut.u_local_mem.u_lmem_bank_5.A_REN, dut.u_local_mem.u_lmem_bank_4.A_REN,
        dut.u_local_mem.u_lmem_bank_3.A_REN, dut.u_local_mem.u_lmem_bank_2.A_REN,
        dut.u_local_mem.u_lmem_bank_1.A_REN, dut.u_local_mem.u_lmem_bank_0.A_REN
    };

    always @(posedge clk) begin
        if (!reset) begin
            for (int b = 0; b < 8; b++) begin
                if (sram_men_mon[b] && sram_wen_mon[b] && sram_ren_mon[b]) begin
                    $display("FAIL_LMEM: bank %0d asserted A_WEN and A_REN simultaneously (write-through violation)", b);
                    $fatal(1, "sram_wen_ren_excl");
                end
            end
        end
    end

    // Global memory responder model + fire counters
    int global_req_fires = 0;
    int lsu_rsp_fires = 0;
    logic [63:0] gmem [0:1023];
    typedef struct packed {
        logic [NUM_LANES-1:0]       mask;
        logic [NUM_LANES-1:0][63:0] data;
        logic [LSU_TAG_WIDTH-1:0]   tag;
    } grsp_t;
    grsp_t grsp_q[$];

    always @(posedge clk) begin
        if (reset) begin
            global_req_fires <= 0;
            lsu_rsp_fires    <= 0;
            global_rsp_valid <= 1'b0;
            grsp_q.delete();
        end else begin
            if (lsu_rsp_valid && lsu_rsp_ready) begin
                lsu_rsp_fires <= lsu_rsp_fires + 1;
            end
            if (global_rsp_valid && global_rsp_ready) begin
                global_rsp_valid <= 1'b0;
            end
            if (global_req_valid && global_req_ready) begin
                global_req_fires <= global_req_fires + 1;
                if (global_req_rw) begin
                    for (int l = 0; l < NUM_LANES; l++) begin
                        if (global_req_mask[l]) begin
                            for (int jb = 0; jb < 8; jb++)
                                if (global_req_byteen[l][jb])
                                    gmem[global_req_addr[l][9:0]][jb*8 +: 8] <= global_req_data[l][jb*8 +: 8];
                        end
                    end
                end else begin
                    grsp_t item;
                    item.mask = global_req_mask;
                    item.tag  = global_req_tag;
                    for (int l = 0; l < NUM_LANES; l++)
                        item.data[l] = global_req_mask[l] ? gmem[global_req_addr[l][9:0]] : 64'd0;
                    grsp_q.push_back(item);
                end
            end
            if ((!global_rsp_valid || global_rsp_ready) && grsp_q.size() > 0) begin
                grsp_t nxt = grsp_q.pop_front();
                global_rsp_valid <= 1'b1;
                global_rsp_mask  <= nxt.mask;
                global_rsp_data  <= nxt.data;
                global_rsp_tag   <= nxt.tag;
            end
        end
    end

    function automatic logic [MEM_ATTR_WIDTH-1:0] make_attr(
        input logic is_local,
        input logic amo_vld,
        input amo_op_e amo_op,
        input logic amo_uns,
        input int hart
    );
        mem_bus_attr_t a;
        a = '0;
        a.is_addr_local    = is_local;
        a.amo.amo_valid    = amo_vld;
        a.amo.amo_op       = amo_op;
        a.amo.amo_unsigned = amo_uns;
        a.amo.hart_id      = HART_ID_WIDTH'(hart);
        return a;
    endfunction

    function automatic [15:0] lmem_waddr(input int row, input int bank);
        return 16'((row << 3) | (bank & 7));
    endfunction

    task automatic clear_inputs();
        lsu_req_valid    = 1'b0;
        lsu_req_mask     = '0;
        lsu_req_rw       = 1'b0;
        lsu_req_addr     = '0;
        lsu_req_data     = '0;
        lsu_req_byteen   = '0;
        lsu_req_user     = '0;
        lsu_req_tag      = '0;
        lsu_rsp_ready    = 1'b1;
        global_req_ready = 1'b1;
        dma_stage_we     = 1'b0;
        dma_stage_bank   = '0;
        dma_stage_wdata  = '0;
        dma_stage_byteen = '0;
        dma_req_valid    = 1'b0;
        dma_req_rw       = 1'b0;
        dma_req_addr     = '0;
        dma_req_tag      = '0;
        dma_rsp_ready    = 1'b1;
        dma_rsp_bank_sel = '0;
    endtask

    task automatic stage_dma_bank(input int b, input logic [63:0] wdata, input logic [7:0] be);
        @(negedge clk);
        dma_stage_we     = 1'b1;
        dma_stage_bank   = 3'(b);
        dma_stage_wdata  = wdata;
        dma_stage_byteen = be;
        @(posedge clk);
        @(negedge clk);
        dma_stage_we     = 1'b0;
    endtask
    task automatic lsu_write_1lane(input int lane, input logic is_loc, input [15:0] addr, input [63:0] wdata, input [7:0] be, input int tag_id);
        int guard = 0;
        @(negedge clk);
        lsu_req_valid       = 1'b1;
        lsu_req_mask        = (2'b01 << lane);
        lsu_req_rw          = 1'b1;
        lsu_req_addr[lane]  = addr;
        lsu_req_data[lane]  = wdata;
        lsu_req_byteen[lane]= be;
        lsu_req_user[lane]  = make_attr(is_loc, 1'b0, AMO_OP_ADD, 1'b0, 0);
        lsu_req_tag         = LSU_TAG_WIDTH'(tag_id);
        do begin
            @(posedge clk);
            guard++;
            if (guard > 200) $fatal(1, "FAIL_LMEM: timeout waiting lsu_req_ready on write");
        end while (!lsu_req_ready);
        @(negedge clk);
        lsu_req_valid = 1'b0;
        lsu_req_mask  = '0;
    endtask

    task automatic lsu_read_or_amo_1lane(
        input int lane, input logic is_loc, input logic amo_vld, input amo_op_e op,
        input logic amo_uns, input int hart, input [15:0] addr, input [63:0] rhs,
        input [7:0] be, input int tag_id, output logic [63:0] rdata_out
    );
        int guard = 0;
        @(negedge clk);
        lsu_req_valid        = 1'b1;
        lsu_req_mask         = (2'b01 << lane);
        lsu_req_rw           = 1'b0;
        lsu_req_addr[lane]   = addr;
        lsu_req_data[lane]   = rhs;
        lsu_req_byteen[lane] = be;
        lsu_req_user[lane]   = make_attr(is_loc, amo_vld, op, amo_uns, hart);
        lsu_req_tag          = LSU_TAG_WIDTH'(tag_id);
        do begin
            @(posedge clk);
            guard++;
            if (guard > 200) $fatal(1, "FAIL_LMEM: timeout waiting lsu_req_ready on read/amo");
        end while (!lsu_req_ready);
        @(negedge clk);
        lsu_req_valid = 1'b0;
        lsu_req_mask  = '0;
        guard = 0;
        while (!(lsu_rsp_valid && lsu_rsp_ready)) begin
            @(posedge clk);
            guard++;
            if (guard > 200) $fatal(1, "FAIL_LMEM: timeout waiting lsu_rsp_valid");
        end
        if (lsu_rsp_mask !== (2'b01 << lane) || lsu_rsp_tag !== LSU_TAG_WIDTH'(tag_id)) begin
            $display("FAIL_LMEM: rsp mask/tag mismatch got mask=%b tag=%0h exp mask=%b tag=%0h",
                     lsu_rsp_mask, lsu_rsp_tag, (2'b01 << lane), LSU_TAG_WIDTH'(tag_id));
            $fatal(1, "rsp_meta");
        end
        rdata_out = lsu_rsp_data[lane];
        @(posedge clk);
    endtask

    task automatic dma_write_line(input [7:0] row, input [3:0] tag_id);
        int guard = 0;
        @(negedge clk);
        dma_req_valid = 1'b1;
        dma_req_rw    = 1'b1;
        dma_req_addr  = row;
        dma_req_tag   = tag_id;
        do begin
            @(posedge clk);
            guard++;
            if (guard > 200) $fatal(1, "FAIL_LMEM: timeout waiting dma_req_ready on write");
        end while (!dma_req_ready);
        @(negedge clk);
        dma_req_valid = 1'b0;
    endtask

    logic [63:0] shadow [0:255][0:7];

    initial begin
        int seed = 101;
        logic [63:0] rv, exp_v;
        int fires_before;
        int unsigned rng;
        void'($value$plusargs("SEED=%d", seed));
        rng = 32'h9E37_79B9 ^ seed;

        clear_inputs();
        for (int r = 0; r < 256; r++)
            for (int b = 0; b < 8; b++) shadow[r][b] = 64'd0;
        for (int g = 0; g < 1024; g++) gmem[g] = 64'd0;

        repeat (6) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (3) begin
            @(posedge clk);
            if (sram_men_mon !== 8'h00) begin
                $display("FAIL_LMEM: idle SRAM A_MEN must be 8'h00, got 0x%02h", sram_men_mon);
                $fatal(1, "idle_men");
            end
        end

        // Phase 1: 8-bank byte-enable sweep + 2-lane same-bank conflict + RDW hazard
        for (int b = 0; b < 8; b++) begin
            logic [63:0] base_w = {32'(32'hA500_0000 + b), 32'(32'h5A00_0010 + b)};
            logic [63:0] patch_w = 64'h1122_3344_5566_7788 ^ {8{8'(b)}};
            logic [7:0]  be_m    = (b % 2 == 0) ? 8'hF0 : 8'hAA;
            lsu_write_1lane(b & 1, 1'b1, lmem_waddr(2, b), base_w, 8'hFF, b);
            lsu_write_1lane((b + 1) & 1, 1'b1, lmem_waddr(2, b), patch_w, be_m, b + 8);
            exp_v = base_w;
            for (int jb = 0; jb < 8; jb++) if (be_m[jb]) exp_v[jb*8 +: 8] = patch_w[jb*8 +: 8];
            shadow[2][b] = exp_v;
            lsu_read_or_amo_1lane(b & 1, 1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0, lmem_waddr(2, b), 64'd0, 8'hFF, b + 16, rv);
            if (rv !== exp_v) begin
                $display("FAIL_LMEM: Phase1 bank %0d got=0x%016h exp=0x%016h", b, rv, exp_v);
                $fatal(1, "p1_byteen");
            end
        end

        // 2-lane same-bank conflict + back-to-back RDW hazard on bank 3 row 9
        @(negedge clk);
        lsu_req_valid     = 1'b1;
        lsu_req_mask      = 2'b11;
        lsu_req_rw        = 1'b1;
        lsu_req_addr[0]   = lmem_waddr(9, 3);
        lsu_req_addr[1]   = lmem_waddr(10, 3);
        lsu_req_data[0]   = 64'hDEAD_BEEF_1234_5678;
        lsu_req_data[1]   = 64'hFACE_CAFE_8765_4321;
        lsu_req_byteen[0] = 8'hFF;
        lsu_req_byteen[1] = 8'hFF;
        lsu_req_user[0]   = make_attr(1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0);
        lsu_req_user[1]   = make_attr(1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0);
        lsu_req_tag       = LSU_TAG_WIDTH'(5);
        do @(posedge clk); while (!lsu_req_ready);
        // Immediately read back both rows in 1 SIMD beat (triggers bank conflict + RDW hazard!)
        @(negedge clk);
        lsu_req_rw        = 1'b0;
        lsu_req_tag       = LSU_TAG_WIDTH'(6);
        do @(posedge clk); while (!lsu_req_ready);
        @(negedge clk);
        lsu_req_valid = 1'b0;
        begin
            logic [1:0] seen_m = 2'b00;
            logic [63:0] got_d0 = '0, got_d1 = '0;
            int guard = 0;
            while (seen_m != 2'b11) begin
                @(posedge clk);
                guard++;
                if (lsu_rsp_valid && lsu_rsp_ready) begin
                    if (lsu_rsp_mask[0]) got_d0 = lsu_rsp_data[0];
                    if (lsu_rsp_mask[1]) got_d1 = lsu_rsp_data[1];
                    seen_m |= lsu_rsp_mask;
                end
                if (guard > 100) $fatal(1, "FAIL_LMEM: Phase1 same-bank/RDW timeout");
            end
            if (got_d0 !== 64'hDEAD_BEEF_1234_5678 || got_d1 !== 64'hFACE_CAFE_8765_4321) begin
                $display("FAIL_LMEM: Phase1 same-bank/RDW mismatch d0=0x%016h d1=0x%016h", got_d0, got_d1);
                $fatal(1, "p1_rdw_conflict");
            end
        end
        shadow[9][3]  = 64'hDEAD_BEEF_1234_5678;
        shadow[10][3] = 64'hFACE_CAFE_8765_4321;
        @(posedge clk);
        // Phase 2: Mixed Local + Global SIMD Bifurcation under Asymmetric Backpressure
        lsu_write_1lane(0, 1'b1, lmem_waddr(4, 2), 64'h0000_0000_0000_0100, 8'hFF, 1);
        lsu_write_1lane(1, 1'b0, 16'h0020,          64'h8888_7777_6666_5555, 8'hFF, 2);
        repeat (4) @(posedge clk);
        fires_before = global_req_fires;
        begin
            int rsps_before = lsu_rsp_fires;
            // Stall global_req_ready=0 across 4 mixed requests (saturates 2-slot req_global_buf so req_global_ready=0 while local is ready!)
            global_req_ready = 1'b0;
            for (int k = 0; k < 4; k++) begin
                int stall_cyc = 0;
                @(negedge clk);
                lsu_req_valid     = 1'b1;
                lsu_req_mask      = 2'b11;
                lsu_req_rw        = 1'b0; // read/AMO
                lsu_req_addr[0]   = lmem_waddr(4, 2);
                lsu_req_addr[1]   = 16'h0020;
                lsu_req_data[0]   = 64'h0000_0000_0000_0011; // AMOADD +0x11 on local lane 0
                lsu_req_data[1]   = 64'd0;
                lsu_req_byteen[0] = 8'hFF;
                lsu_req_byteen[1] = 8'hFF;
                lsu_req_user[0]   = make_attr(1'b1, 1'b1, AMO_OP_ADD, 1'b0, 0);
                lsu_req_user[1]   = make_attr(1'b0, 1'b0, AMO_OP_ADD, 1'b0, 0);
                lsu_req_tag       = LSU_TAG_WIDTH'(10 + k);
                while (1) begin
                    @(posedge clk);
                    stall_cyc++;
                    if (lsu_req_ready) break;
                    if (stall_cyc == 6) begin
                        @(negedge clk);
                        global_req_ready = 1'b1;
                    end
                    if (stall_cyc > 60) $fatal(1, "FAIL_LMEM: Phase2 mixed stall timeout");
                end
                @(negedge clk);
                lsu_req_valid    = 1'b0;
                global_req_ready = 1'b0;
            end
            @(negedge clk);
            global_req_ready = 1'b1;
            begin
                int guard = 0;
                while ((lsu_rsp_fires - rsps_before) < 8 && guard < 200) begin
                    @(posedge clk);
                    guard++;
                end
            end
            repeat (6) @(posedge clk);
            if ((lsu_rsp_fires - rsps_before) != 8) begin
                $display("FAIL_LMEM: Phase2 expected 8 mixed responses, got %0d", lsu_rsp_fires - rsps_before);
                $fatal(1, "p2_rsp_cnt");
            end
        end
        if ((global_req_fires - fires_before) != 4) begin
            $display("FAIL_LMEM: Phase2 expected 4 global_req fires, got %0d", global_req_fires - fires_before);
            $fatal(1, "p2_global_dup");
        end
        lsu_read_or_amo_1lane(0, 1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0, lmem_waddr(4, 2), 64'd0, 8'hFF, 14, rv);
        if (rv !== 64'h0000_0000_0000_0144) begin
            $display("FAIL_LMEM: Phase2 mixed AMOADD duplicate/drop: got 0x%016h exp 0x144", rv);
            $fatal(1, "p2_local_dup");
        end
        shadow[4][2] = 64'h0000_0000_0000_0144;

        // Phase 2B: Reverse asymmetric stall — saturate local bank 1 while global_req_ready=1
        fires_before = global_req_fires;
        begin
            int rsps_b4 = lsu_rsp_fires;
            lsu_rsp_ready = 1'b0;
            for (int k = 0; k < 14; k++) begin
                @(negedge clk);
                lsu_req_valid     = 1'b1;
                lsu_req_mask      = 2'b11;
                lsu_req_rw        = 1'b0;
                lsu_req_addr[0]   = lmem_waddr(2, 1);
                lsu_req_addr[1]   = 16'h0020;
                lsu_req_byteen[0] = 8'hFF;
                lsu_req_byteen[1] = 8'hFF;
                lsu_req_user[0]   = make_attr(1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0);
                lsu_req_user[1]   = make_attr(1'b0, 1'b0, AMO_OP_ADD, 1'b0, 0);
                lsu_req_tag       = LSU_TAG_WIDTH'(k & 7);
                begin
                    int sc = 0;
                    while (1) begin
                        @(posedge clk);
                        sc++;
                        if (lsu_req_ready) break;
                        if (sc == 6) begin @(negedge clk); lsu_rsp_ready = 1'b1; end
                        if (sc > 80) $fatal(1, "FAIL_LMEM: Phase2B reverse stall timeout");
                    end
                end
                @(negedge clk);
                lsu_req_valid = 1'b0;
                lsu_rsp_ready = 1'b0;
            end
            @(negedge clk);
            lsu_rsp_ready = 1'b1;
            begin
                int gd = 0;
                while ((lsu_rsp_fires - rsps_b4) < 28 && gd < 250) begin
                    @(posedge clk);
                    gd++;
                end
            end
            repeat (10) @(posedge clk);
        end
        if ((global_req_fires - fires_before) != 14) begin
            $display("FAIL_LMEM: Phase2B reverse stall global duplicate fires=%0d exp=14", global_req_fires - fires_before);
            $fatal(1, "p2b_rev_dup");
        end

        // Phase 3A: Upper-lane .W LR/SC reservation success & invalidation failure
        lsu_write_1lane(0, 1'b1, lmem_waddr(15, 6), 64'hAAAA_0010_BBBB_0020, 8'hFF, 1);
        lsu_read_or_amo_1lane(0, 1'b1, 1'b1, AMO_OP_LR, 1'b0, 1, lmem_waddr(15, 6), 64'd0, 8'hF0, 2, rv);
        lsu_read_or_amo_1lane(0, 1'b1, 1'b1, AMO_OP_SC, 1'b0, 1, lmem_waddr(15, 6), 64'hCCCC_9999_0000_0000, 8'hF0, 3, rv);
        if (rv[63:32] !== 32'd0) $fatal(1, "FAIL_LMEM: expected valid upper .W SC to return 0");
        // Now LR by hart 1, invalidate by hart 0 store, then SC by hart 1 must fail (return 1 in upper 32b and not overwrite!)
        lsu_read_or_amo_1lane(0, 1'b1, 1'b1, AMO_OP_LR, 1'b0, 1, lmem_waddr(15, 6), 64'd0, 8'hF0, 4, rv);
        lsu_write_1lane(1, 1'b1, lmem_waddr(15, 6), 64'h0000_0000_DDDD_7777, 8'h0F, 5);
        lsu_read_or_amo_1lane(0, 1'b1, 1'b1, AMO_OP_SC, 1'b0, 1, lmem_waddr(15, 6), 64'hEEEE_EEEE_0000_0000, 8'hF0, 6, rv);
        if (rv[63:32] !== 32'd1) $fatal(1, "FAIL_LMEM: expected invalidated upper .W SC to return 1");
        repeat (3) @(posedge clk);
        lsu_read_or_amo_1lane(0, 1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0, lmem_waddr(15, 6), 64'd0, 8'hFF, 7, rv);
        if (rv !== 64'hCCCC_9999_DDDD_7777) begin
            $display("FAIL_LMEM: Phase3A LR/SC memory state wrong got 0x%016h", rv);
            $fatal(1, "p3a_lrsc");
        end
        shadow[15][6] = 64'hCCCC_9999_DDDD_7777;

        // Phase 3B: Concurrent Wide-Line DMA Read & Write colliding with in-flight AMO_OP_ADD writeback!
        for (int b = 0; b < 8; b++) begin
            stage_dma_bank(b, 64'hCAFE_2500_0000_0000 | b, 8'hFF);
            shadow[25][b] = 64'hCAFE_2500_0000_0000 | b;
        end
        dma_write_line(8'd25, 4'h3);
        lsu_write_1lane(0, 1'b1, lmem_waddr(12, 5), 64'h2000_0000_0000_0300, 8'hFF, 8);

        // Fire AMOADD on (row 12, bank 5) and hammer 6 consecutive DMA reads on row 25 across the entire bank RMW window!
        @(negedge clk);
        lsu_req_valid     = 1'b1;
        lsu_req_mask      = 2'b01;
        lsu_req_rw        = 1'b0;
        lsu_req_addr[0]   = lmem_waddr(12, 5);
        lsu_req_data[0]   = 64'h0000_0000_0000_0077;
        lsu_req_byteen[0] = 8'hFF;
        lsu_req_user[0]   = make_attr(1'b1, 1'b1, AMO_OP_ADD, 1'b0, 0);
        lsu_req_tag       = LSU_TAG_WIDTH'(9);
        do @(posedge clk); while (!lsu_req_ready);
        @(negedge clk);
        lsu_req_valid = 1'b0;

        begin
            logic got_amo_rsp = 1'b0;
            // Let AMO traverse switch+adapter+req_xbar (2-3 cycles) so amo_accept fires, then hit amo_rd_valid_r/amo_wb_valid_r with DMA write!
            for (int w = 0; w < 3; w++) begin
                @(posedge clk);
                if (lsu_rsp_valid && lsu_rsp_ready) begin
                    if (lsu_rsp_data[0] !== 64'h2000_0000_0000_0300)
                        $fatal(1, "FAIL_LMEM: Phase3B AMO old val mismatch");
                    got_amo_rsp = 1'b1;
                end
            end
            for (int d = 0; d < 6; d++) begin
                @(negedge clk);
                dma_req_valid = 1'b1;
                dma_req_rw    = 1'b1; // DMA write to row 25 while AMO writeback to row 12 is in flight!
                dma_req_addr  = 8'd25;
                dma_req_tag   = 4'(d);
                do begin
                    @(posedge clk);
                    if (lsu_rsp_valid && lsu_rsp_ready) begin
                        if (lsu_rsp_data[0] !== 64'h2000_0000_0000_0300)
                            $fatal(1, "FAIL_LMEM: Phase3B AMO old val mismatch");
                        got_amo_rsp = 1'b1;
                    end
                end while (!dma_req_ready);
            end
            @(negedge clk);
            dma_req_valid = 1'b0;
            while (!got_amo_rsp) begin
                @(posedge clk);
                if (lsu_rsp_valid && lsu_rsp_ready) begin
                    if (lsu_rsp_data[0] !== 64'h2000_0000_0000_0300)
                        $fatal(1, "FAIL_LMEM: Phase3B AMO old val mismatch");
                    got_amo_rsp = 1'b1;
                end
            end
            repeat (6) @(posedge clk);
        end

        // Verify neither (row 12, bank 5) AMO writeback was lost nor (row 25, bank 5) was corrupted!
        lsu_read_or_amo_1lane(0, 1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0, lmem_waddr(12, 5), 64'd0, 8'hFF, 11, rv);
        if (rv !== 64'h2000_0000_0000_0377) begin
            $display("FAIL_LMEM: Phase3B AMO writeback dropped under DMA! got 0x%016h exp 0x2000000000000377", rv);
            $fatal(1, "p3b_amo_drop");
        end
        lsu_read_or_amo_1lane(0, 1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0, lmem_waddr(25, 5), 64'd0, 8'hFF, 12, rv);
        if (rv !== (64'hCAFE_2500_0000_0000 | 5)) begin
            $display("FAIL_LMEM: Phase3B DMA target row corrupted by AMO writeback! got 0x%016h", rv);
            $fatal(1, "p3b_dma_corrupt");
        end
        shadow[12][5] = 64'h2000_0000_0000_0377;

        // Phase 4: Hold dma_rsp_ready=0 while issuing LSU reads on banks 0..7 to test dma_rsp_hold_data_r!
        @(negedge clk);
        dma_rsp_ready = 1'b0;
        dma_req_valid = 1'b1;
        dma_req_rw    = 1'b0;
        dma_req_addr  = 8'd25;
        dma_req_tag   = 4'hA;
        do @(posedge clk); while (!dma_req_ready);
        @(negedge clk);
        dma_req_valid = 1'b0;
        while (!dma_rsp_valid) @(posedge clk);
        for (int b = 0; b < 8; b++) begin
            lsu_read_or_amo_1lane(0, 1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0, lmem_waddr(2, b), 64'd0, 8'hFF, b, rv);
        end
        for (int b = 0; b < 8; b++) begin
            @(negedge clk);
            dma_rsp_bank_sel = 3'(b);
            #1;
            if (dma_rsp_rdata !== (64'hCAFE_2500_0000_0000 | b)) begin
                $display("FAIL_LMEM: Phase4 held DMA rsp bank %0d clobbered: got 0x%016h", b, dma_rsp_rdata);
                $fatal(1, "p4_dma_hold");
            end
        end
        @(negedge clk);
        dma_rsp_ready = 1'b1;
        @(posedge clk);

        // Phase 4B: Stalled LSU response hold while DMA read clobbers SRAM OUT_REG
        lsu_rsp_ready = 1'b0;
        for (int q = 0; q < 6; q++) begin
            @(negedge clk);
            lsu_req_valid     = 1'b1;
            lsu_req_mask      = 2'b01;
            lsu_req_rw        = 1'b0;
            lsu_req_addr[0]   = lmem_waddr(9, 3);
            lsu_req_byteen[0] = 8'hFF;
            lsu_req_user[0]   = make_attr(1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0);
            lsu_req_tag       = LSU_TAG_WIDTH'(q);
            do @(posedge clk); while (!lsu_req_ready);
        end
        @(negedge clk);
        lsu_req_valid = 1'b0;
        repeat (6) @(posedge clk);
        // Now issue DMA read on row 25 to overwrite bank 3 A_DOUT while bank 3 rsp is backpressured!
        @(negedge clk);
        dma_req_valid = 1'b1;
        dma_req_rw    = 1'b0;
        dma_req_addr  = 8'd25;
        dma_req_tag   = 4'hB;
        do @(posedge clk); while (!dma_req_ready);
        @(negedge clk);
        dma_req_valid = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        lsu_rsp_ready = 1'b1;
        begin
            int got_q = 0, gd4 = 0;
            while (got_q < 6 && gd4 < 120) begin
                @(posedge clk);
                gd4++;
                if (lsu_rsp_valid && lsu_rsp_ready) begin
                    if (lsu_rsp_data[0] !== 64'hDEAD_BEEF_1234_5678) begin
                        $display("FAIL_LMEM: Phase4B stalled LSU response #%0d clobbered by DMA read! got 0x%016h", got_q, lsu_rsp_data[0]);
                        $fatal(1, "p4b_lsu_hold");
                    end
                    got_q++;
                end
            end
            if (got_q != 6) $fatal(1, "FAIL_LMEM: Phase4B missing drained LSU responses");
        end

        // Phase 5: Seed-driven randomized bank/row/byte-mask/AMO verification
        for (int step = 0; step < 48; step++) begin
            int r, b, ln;
            logic [63:0] val;
            logic [7:0] be;
            rng = rng * 32'h08088405 + 32'd1;
            r   = 40 + (rng % 32);
            b   = (rng >> 8) & 7;
            ln  = (rng >> 12) & 1;
            be  = 8'((rng >> 16) | 8'h01);
            val = {rng ^ 32'h55AA_1234, ~rng};
            if ((step % 3) == 0) begin
                lsu_write_1lane(ln, 1'b1, lmem_waddr(r, b), val, be, step & 7);
                for (int jb = 0; jb < 8; jb++) if (be[jb]) shadow[r][b][jb*8 +: 8] = val[jb*8 +: 8];
            end else if ((step % 3) == 1) begin
                lsu_read_or_amo_1lane(ln, 1'b1, 1'b1, AMO_OP_XOR, 1'b0, 0, lmem_waddr(r, b), val, 8'hFF, step & 7, rv);
                if (rv !== shadow[r][b]) $fatal(1, "FAIL_LMEM: Phase5 AMOXOR old mismatch");
                shadow[r][b] = shadow[r][b] ^ val;
            end else begin
                lsu_read_or_amo_1lane(ln, 1'b1, 1'b0, AMO_OP_ADD, 1'b0, 0, lmem_waddr(r, b), 64'd0, 8'hFF, step & 7, rv);
                if (rv !== shadow[r][b]) $fatal(1, "FAIL_LMEM: Phase5 read mismatch");
            end
        end

        repeat (4) @(posedge clk);
        if (sram_men_mon !== 8'h00) $fatal(1, "FAIL_LMEM: post-run idle A_MEN != 0");
        $display("PASS_LMEM_SUBSYS seed=%0d", seed);
        $finish;
    end
endmodule
