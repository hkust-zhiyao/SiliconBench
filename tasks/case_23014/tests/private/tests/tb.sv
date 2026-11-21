`include "VX_cache_define.vh"

module tb import VX_gpu_pkg::*; ();
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    logic [1:0]                           core_req_valid;
    wire  [1:0]                           core_req_ready;
    logic [1:0]                           core_req_rw;
    logic [1:0][24:0]                     core_req_addr;
    logic [1:0][63:0]                     core_req_data;
    logic [1:0][7:0]                      core_req_byteen;
    logic [1:0][`UP(MEM_ATTR_WIDTH)-1:0]  core_req_attr;
    logic [1:0][5:0]                      core_req_tag;

    wire  [1:0]                           core_rsp_valid;
    logic [1:0]                           core_rsp_ready;
    wire  [1:0][63:0]                     core_rsp_data;
    wire  [1:0][5:0]                      core_rsp_tag;

    wire                                  mem_req_valid;
    logic                                 mem_req_ready;
    wire                                  mem_req_rw;
    wire  [23:0]                          mem_req_addr;
    wire  [127:0]                         mem_req_data;
    wire  [15:0]                          mem_req_byteen;
    wire  [`UP(MEM_ATTR_WIDTH)-1:0]       mem_req_attr;
    wire  [2:0]                           mem_req_tag;

    logic                                 mem_rsp_valid;
    wire                                  mem_rsp_ready;
    logic [127:0]                         mem_rsp_data;
    logic [2:0]                           mem_rsp_tag;

    VX_cache_subsys dut (.*);

    // Monitor all 10 hard 1P SRAM macros (2 tag macros + 8 data-slice macros)
    wire [9:0] macro_men = {
        dut.u_cache.u_bank_1.cache_data.u_data_slice_3.A_MEN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_2.A_MEN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_1.A_MEN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_0.A_MEN,
        dut.u_cache.u_bank_1.cache_tags.u_tag_sram.A_MEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_3.A_MEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_2.A_MEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_1.A_MEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_0.A_MEN,
        dut.u_cache.u_bank_0.cache_tags.u_tag_sram.A_MEN
    };
    wire [9:0] macro_wen = {
        dut.u_cache.u_bank_1.cache_data.u_data_slice_3.A_WEN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_2.A_WEN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_1.A_WEN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_0.A_WEN,
        dut.u_cache.u_bank_1.cache_tags.u_tag_sram.A_WEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_3.A_WEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_2.A_WEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_1.A_WEN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_0.A_WEN,
        dut.u_cache.u_bank_0.cache_tags.u_tag_sram.A_WEN
    };
    wire [9:0] macro_ren = {
        dut.u_cache.u_bank_1.cache_data.u_data_slice_3.A_REN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_2.A_REN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_1.A_REN,
        dut.u_cache.u_bank_1.cache_data.u_data_slice_0.A_REN,
        dut.u_cache.u_bank_1.cache_tags.u_tag_sram.A_REN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_3.A_REN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_2.A_REN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_1.A_REN,
        dut.u_cache.u_bank_0.cache_data.u_data_slice_0.A_REN,
        dut.u_cache.u_bank_0.cache_tags.u_tag_sram.A_REN
    };

    int data_slice_multi_rd_err = 0;
    always @(posedge clk) begin
        if (!reset) begin
            for (int m = 0; m < 10; m++) begin
                if (macro_men[m] && macro_wen[m] && macro_ren[m]) begin
                    $display("FAIL_CACHE: macro %0d asserted A_WEN and A_REN simultaneously", m);
                    $fatal(1, "sram_wen_ren_excl");
                end
            end
            // On a non-fill read cycle, at most 1 of the 4 data slices per bank may assert A_MEN+A_REN
            if ($countones(macro_men[4:1] & macro_ren[4:1]) > 1)
                data_slice_multi_rd_err++;
            if ($countones(macro_men[9:6] & macro_ren[9:6]) > 1)
                data_slice_multi_rd_err++;
        end
    end

    // 128-bit Sectored Backing Memory + Non-LLC AMO Responder
    logic [127:0] backing_mem [logic [23:0]];
    int mem_rd_fills = 0;
    int mem_wr_beats = 0;
    int mem_amo_ops  = 0;

    typedef struct packed {
        int          delay;
        logic [127:0] data;
        logic [2:0]  tag;
    } mrsp_t;
    mrsp_t mrsp_q[$];

    function automatic [127:0] get_sec(input [23:0] saddr);
        if (backing_mem.exists(saddr)) return backing_mem[saddr];
        return {32'hD100_0000 ^ {8'h0, saddr}, 32'hBEEF_0001, 32'hD000_0000 ^ {8'h0, saddr}, 32'hCAFE_0000};
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            mem_rsp_valid <= 1'b0;
            mem_rd_fills  <= 0;
            mem_wr_beats  <= 0;
            mem_amo_ops   <= 0;
            mrsp_q.delete();
        end else begin
            if (mem_rsp_valid && mem_rsp_ready) begin
                mem_rsp_valid <= 1'b0;
            end
            for (int qi = 0; qi < mrsp_q.size(); qi++) begin
                if (mrsp_q[qi].delay > 0) mrsp_q[qi].delay--;
            end
            if (mem_req_valid && mem_req_ready) begin
                mem_bus_attr_t ma;
                logic [127:0] cur_sec;
                ma = mem_bus_attr_t'(mem_req_attr);
                cur_sec = get_sec(mem_req_addr);
                if (mem_req_rw) begin
                    mem_wr_beats <= mem_wr_beats + 1;
                    for (int jb = 0; jb < 16; jb++) begin
                        if (mem_req_byteen[jb])
                            cur_sec[jb*8 +: 8] = mem_req_data[jb*8 +: 8];
                    end
                    backing_mem[mem_req_addr] = cur_sec;
                end else if (ma.amo.amo_valid) begin
                    mrsp_t item;
                    logic hi_w = mem_req_byteen[8];
                    logic [63:0] old_w = hi_w ? cur_sec[127:64] : cur_sec[63:0];
                    logic [63:0] rhs_w = hi_w ? mem_req_data[127:64] : mem_req_data[63:0];
                    logic [63:0] new_w = (ma.amo.amo_op == AMO_OP_XOR) ? (old_w ^ rhs_w) : (old_w + rhs_w);
                    mem_amo_ops <= mem_amo_ops + 1;
                    item.delay = 2;
                    item.data  = cur_sec;
                    item.tag   = mem_req_tag;
                    mrsp_q.push_back(item);
                    if (hi_w) cur_sec[127:64] = new_w; else cur_sec[63:0] = new_w;
                    backing_mem[mem_req_addr] = cur_sec;
                end else begin
                    mrsp_t item;
                    mem_rd_fills <= mem_rd_fills + 1;
                    item.delay = 2;
                    item.data  = cur_sec;
                    item.tag   = mem_req_tag;
                    mrsp_q.push_back(item);
                end
            end
            if ((!mem_rsp_valid || mem_rsp_ready) && mrsp_q.size() > 0 && mrsp_q[0].delay == 0) begin
                mrsp_t nxt = mrsp_q.pop_front();
                mem_rsp_valid <= 1'b1;
                mem_rsp_data  <= nxt.data;
                mem_rsp_tag   <= nxt.tag;
            end
        end
    end

    function automatic [24:0] make_waddr(input [15:0] tag, input [5:0] set_idx, input logic bank, input [1:0] wsel);
        return {tag, set_idx, bank, wsel};
    endfunction

    function automatic [`UP(MEM_ATTR_WIDTH)-1:0] make_attr(input logic amo_vld, input amo_op_e op);
        mem_bus_attr_t a;
        a = '0;
        a.amo.amo_valid = amo_vld;
        a.amo.amo_op    = op;
        return a;
    endfunction

    task automatic clear_core();
        core_req_valid  = 2'b00;
        core_req_rw     = 2'b00;
        core_req_addr   = '0;
        core_req_data   = '0;
        core_req_byteen = '0;
        core_req_attr   = '0;
        core_req_tag    = '0;
        core_rsp_ready  = 2'b11;
        mem_req_ready   = 1'b1;
    endtask

    task automatic core_read_1p(input int p, input [24:0] waddr, input [5:0] ctag, output logic [63:0] rdata);
        int gd = 0;
        @(negedge clk);
        core_req_valid[p]  = 1'b1;
        core_req_rw[p]     = 1'b0;
        core_req_addr[p]   = waddr;
        core_req_byteen[p] = 8'hFF;
        core_req_attr[p]   = make_attr(1'b0, AMO_OP_ADD);
        core_req_tag[p]    = ctag;
        do begin
            @(posedge clk);
            gd = gd + 1;
            if (gd > 400) $fatal(1, "FAIL_CACHE: timeout waiting core_req_ready on read");
        end while (!core_req_ready[p]);
        @(negedge clk);
        core_req_valid[p] = 1'b0;
        gd = 0;
        while (!(core_rsp_valid[p] && core_rsp_ready[p])) begin
            @(posedge clk);
            gd = gd + 1;
            if (gd > 400) $fatal(1, "FAIL_CACHE: timeout waiting core_rsp_valid on read");
        end
        if (core_rsp_tag[p] !== ctag) $fatal(1, "FAIL_CACHE: core_rsp_tag mismatch");
        rdata = core_rsp_data[p];
        @(posedge clk);
    endtask

    task automatic core_write_1p(input int p, input [24:0] waddr, input [63:0] wdata, input [7:0] be, input [5:0] ctag);
        int gd = 0;
        @(negedge clk);
        core_req_valid[p]  = 1'b1;
        core_req_rw[p]     = 1'b1;
        core_req_addr[p]   = waddr;
        core_req_data[p]   = wdata;
        core_req_byteen[p] = be;
        core_req_attr[p]   = make_attr(1'b0, AMO_OP_ADD);
        core_req_tag[p]    = ctag;
        do begin
            @(posedge clk);
            gd = gd + 1;
            if (gd > 400) $fatal(1, "FAIL_CACHE: timeout waiting core_req_ready on write");
        end while (!core_req_ready[p]);
        @(negedge clk);
        core_req_valid[p] = 1'b0;
        @(posedge clk);
    endtask

    initial begin
        int seed = 101;
        int unsigned rng;
        int fills_b4;
        logic [63:0] rv, exp_w;
        void'($value$plusargs("SEED=%d", seed));
        rng = 32'hA5A5_1357 ^ seed;

        clear_core();
        repeat (6) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Phase 1: Set 63 (last set after init walk) 4-way PLRU allocation in both banks (no Way-0 thrashing!)
        for (int b = 0; b < 2; b++) begin
            for (int w = 0; w < 4; w++) begin
                logic [24:0] wa = make_waddr(16'h0100 + w, 6'd63, b[0], 2'(w));
                logic [127:0] sc = get_sec(wa[24:1]);
                exp_w = wa[0] ? sc[127:64] : sc[63:0];
                core_read_1p(b, wa, 6'(w + 1), rv);
                if (rv !== exp_w) $fatal(1, "FAIL_CACHE: P1 cold miss data mismatch");
            end
            fills_b4 = mem_rd_fills;
            for (int w = 0; w < 4; w++) begin
                logic [24:0] wa = make_waddr(16'h0100 + w, 6'd63, b[0], 2'(w));
                logic [127:0] sc = get_sec(wa[24:1]);
                exp_w = wa[0] ? sc[127:64] : sc[63:0];
                core_read_1p(b, wa, 6'(w + 9), rv);
                if (rv !== exp_w) $fatal(1, "FAIL_CACHE: P1 hit data mismatch");
            end
            if (mem_rd_fills != fills_b4) begin
                $display("FAIL_CACHE: P1 Set 63 PLRU failed to retain all 4 ways (extra fills=%0d)", mem_rd_fills - fills_b4);
                $fatal(1, "p1_plru_alloc");
            end
        end

        // Phase 2: Same-Set Back-to-Back Hit-then-Miss PLRU RDW Hazard on Set 12 Bank 0
        for (int w = 0; w < 4; w++)
            core_read_1p(0, make_waddr(16'h1200 + w, 6'd12, 1'b0, 2'd0), 6'(w), rv);
        // Touch w=1,2,3 so w=0 becomes the current PLRU victim unless promoted right before miss!
        for (int w = 1; w < 4; w++)
            core_read_1p(0, make_waddr(16'h1200 + w, 6'd12, 1'b0, 2'd0), 6'(w), rv);
        repeat (4) @(posedge clk);
        // Now issue HIT to w=0 immediately followed on next cycle by MISS to w=4 (same set 12)!
        @(negedge clk);
        core_req_valid[0]  = 1'b1;
        core_req_rw[0]     = 1'b0;
        core_req_addr[0]   = make_waddr(16'h1200, 6'd12, 1'b0, 2'd0);
        core_req_byteen[0] = 8'hFF;
        core_req_attr[0]   = make_attr(1'b0, AMO_OP_ADD);
        core_req_tag[0]    = 6'h21;
        do @(posedge clk); while (!core_req_ready[0]);
        @(negedge clk);
        core_req_addr[0]   = make_waddr(16'h1204, 6'd12, 1'b0, 2'd0);
        core_req_tag[0]    = 6'h22;
        do @(posedge clk); while (!core_req_ready[0]);
        @(negedge clk);
        core_req_valid[0] = 1'b0;
        begin
            int got2 = 0, gd2 = 0;
            while (got2 < 2 && gd2 < 300) begin
                @(posedge clk); gd2++;
                if (core_rsp_valid[0] && core_rsp_ready[0]) got2++;
            end
            if (got2 != 2) $fatal(1, "FAIL_CACHE: P2 hit+miss drain timeout");
        end
        repeat (4) @(posedge clk);
        // w=0 (0x1200) was just hit right before w=4 missed, so w=0 MUST still be resident in cache!
        fills_b4 = mem_rd_fills;
        core_read_1p(0, make_waddr(16'h1200, 6'd12, 1'b0, 2'd0), 6'h23, rv);
        if (mem_rd_fills != fills_b4) begin
            $display("FAIL_CACHE: P2 same-set hit->miss PLRU RDW hazard evicted MRU line 0x1200!");
            $fatal(1, "p2_plru_rdw");
        end

        // Phase 2b: Left & Right PLRU Leaf Subtree Isolation Checks (Set 14 & Set 15 Bank 0)
        // Cold allocation from init=000 maps: +0->Way0, +1->Way2, +2->Way1, +3->Way3.
        // Left-leaf test on Set 14: touch +0 (Way0 -> left_leaf=1) then +3 (Way3 -> root=0, must NOT clobber left_leaf!).
        // Miss +4 must evict Way1 (+2), keeping {+0, +1, +3} resident!
        for (int w = 0; w < 4; w++)
            core_read_1p(0, make_waddr(16'h1400 + w, 6'd14, 1'b0, 2'd0), 6'(w), rv);
        core_read_1p(0, make_waddr(16'h1400, 6'd14, 1'b0, 2'd0), 6'h10, rv);
        core_read_1p(0, make_waddr(16'h1403, 6'd14, 1'b0, 2'd0), 6'h12, rv);
        core_read_1p(0, make_waddr(16'h1404, 6'd14, 1'b0, 2'd0), 6'h13, rv);
        fills_b4 = mem_rd_fills;
        core_read_1p(0, make_waddr(16'h1400, 6'd14, 1'b0, 2'd0), 6'h14, rv);
        core_read_1p(0, make_waddr(16'h1401, 6'd14, 1'b0, 2'd0), 6'h15, rv);
        core_read_1p(0, make_waddr(16'h1403, 6'd14, 1'b0, 2'd0), 6'h16, rv);
        if (mem_rd_fills != fills_b4) begin
            $display("FAIL_CACHE: P2b left-subtree PLRU corrupted sibling leaf mask (extra fills=%0d)", mem_rd_fills - fills_b4);
            $fatal(1, "p2b_plru_left_leaf");
        end
        // Right-leaf test on Set 15: touch +1 (Way2 -> right_leaf=1) then +0 (Way0 -> root=1, must NOT clobber right_leaf!).
        // Miss +4 must evict Way3 (+3), keeping {+0, +1, +2} resident!
        for (int w = 0; w < 4; w++)
            core_read_1p(0, make_waddr(16'h1500 + w, 6'd15, 1'b0, 2'd0), 6'(w), rv);
        core_read_1p(0, make_waddr(16'h1501, 6'd15, 1'b0, 2'd0), 6'h17, rv);
        core_read_1p(0, make_waddr(16'h1500, 6'd15, 1'b0, 2'd0), 6'h19, rv);
        core_read_1p(0, make_waddr(16'h1504, 6'd15, 1'b0, 2'd0), 6'h1A, rv);
        fills_b4 = mem_rd_fills;
        core_read_1p(0, make_waddr(16'h1500, 6'd15, 1'b0, 2'd0), 6'h1B, rv);
        core_read_1p(0, make_waddr(16'h1501, 6'd15, 1'b0, 2'd0), 6'h1C, rv);
        core_read_1p(0, make_waddr(16'h1502, 6'd15, 1'b0, 2'd0), 6'h1D, rv);
        if (mem_rd_fills != fills_b4) begin
            $display("FAIL_CACHE: P2b right-subtree PLRU corrupted sibling leaf mask (extra fills=%0d)", mem_rd_fills - fills_b4);
            $fatal(1, "p2b_plru_right_leaf");
        end

        // Phase 3: Sector Refill + Byte-Masked Write Hit + Word-Slice Isolation Check
        begin
            logic [63:0] w1_orig, w1_after;
            core_read_1p(0, make_waddr(16'h2200, 6'd20, 1'b0, 2'd1), 6'h27, w1_orig); // fills Sector 0 (words 0,1)
            core_read_1p(0, make_waddr(16'h2200, 6'd20, 1'b0, 2'd0), 6'h28, rv);
            core_write_1p(0, make_waddr(16'h2200, 6'd20, 1'b0, 2'd0), 64'hAABB_CCDD_1122_3344, 8'hF5, 6'h29);
            exp_w = (rv & ~64'hFFFF_FFFF_00FF_00FF) | (64'hAABB_CCDD_1122_3344 & 64'hFFFF_FFFF_00FF_00FF);
            core_read_1p(0, make_waddr(16'h2200, 6'd20, 1'b0, 2'd1), 6'h2C, w1_after);
            if (w1_after !== w1_orig) begin
                $display("FAIL_CACHE: P3 write to word 0 clobbered word 1 got=0x%016h exp=0x%016h", w1_after, w1_orig);
                $fatal(1, "p3_word_slice_clobber");
            end
            // Now read Sector 1 (word 2) of SAME tag 0x2200 -> must sector-refill into SAME way without clobbering Sector 0!
            core_read_1p(0, make_waddr(16'h2200, 6'd20, 1'b0, 2'd2), 6'h2A, rv);
            fills_b4 = mem_rd_fills;
            core_read_1p(0, make_waddr(16'h2200, 6'd20, 1'b0, 2'd0), 6'h2B, rv);
            if (mem_rd_fills != fills_b4 || rv !== exp_w) begin
                $display("FAIL_CACHE: P3 sector refill clobbered or evicted Sector 0 byte-masked data got=0x%016h exp=0x%016h", rv, exp_w);
                $fatal(1, "p3_sector_refill");
            end
        end

        // Phase 4: Non-LLC AMO Passthrough Invalidation + Same-Set Next-Cycle Load RDW Hazard
        begin
            logic [24:0] amo_wa = make_waddr(16'h3300, 6'd30, 1'b1, 2'd1);
            logic [63:0] base64, got_amo = '0, got_ld = '0;
            int got4 = 0, gd4 = 0;
            core_read_1p(1, amo_wa, 6'h30, base64); // install 0x3300 into Bank 1 Set 30
            repeat (3) @(posedge clk);
            // Issue AMO_OP_ADD (+0x5500) on cycle T, immediately followed by plain load to amo_wa on cycle T+1!
            @(negedge clk);
            core_req_valid[1]  = 1'b1;
            core_req_rw[1]     = 1'b0;
            core_req_addr[1]   = amo_wa;
            core_req_data[1]   = 64'h0000_0000_0000_5500;
            core_req_byteen[1] = 8'hFF;
            core_req_attr[1]   = make_attr(1'b1, AMO_OP_ADD);
            core_req_tag[1]    = 6'h31;
            do @(posedge clk); while (!core_req_ready[1]);
            @(negedge clk);
            core_req_data[1]   = 64'd0;
            core_req_attr[1]   = make_attr(1'b0, AMO_OP_ADD);
            core_req_tag[1]    = 6'h32;
            do @(posedge clk); while (!core_req_ready[1]);
            @(negedge clk);
            core_req_valid[1] = 1'b0;
            while (got4 < 2 && gd4 < 400) begin
                @(posedge clk); gd4++;
                if (core_rsp_valid[1] && core_rsp_ready[1]) begin
                    if (core_rsp_tag[1] == 6'h31) got_amo = core_rsp_data[1];
                    if (core_rsp_tag[1] == 6'h32) got_ld  = core_rsp_data[1];
                    got4++;
                end
            end
            if (got4 != 2 || got_amo !== base64 || got_ld !== (base64 + 64'h5500)) begin
                $display("FAIL_CACHE: P4 AMO inval RDW mismatch base=0x%016h amo=0x%016h ld=0x%016h", base64, got_amo, got_ld);
                $fatal(1, "p4_amo_inval_rdw");
            end
        end

        // Phase 5: Seed-driven dual-bank randomized read/write/sector stress + backpressure
        for (int step = 0; step < 40; step++) begin
            logic [15:0] tg;
            logic [5:0]  st;
            logic        bk;
            logic [1:0]  ws;
            logic [24:0] wa;
            logic [127:0] sc;
            rng = rng * 32'h08088405 + 32'd1;
            tg = 16'h4000 + (rng[3:0] & 16'h0007);
            st = 6'd40 + (rng[7:4] & 6'd3);
            bk = rng[8];
            ws = rng[10:9];
            wa = make_waddr(tg, st, bk, ws);
            if (rng[11]) begin
                logic [63:0] wd = {rng ^ 32'hDEAD_BEEF, ~rng};
                logic [7:0]  be = 8'(rng[23:16] | 8'h01);
                core_write_1p(bk, wa, wd, be, 6'(step & 63));
                repeat (4) @(posedge clk);
            end else begin
                core_read_1p(bk, wa, 6'(step & 63), rv);
                sc = get_sec(wa[24:1]);
                exp_w = wa[0] ? sc[127:64] : sc[63:0];
                if (rv !== exp_w) begin
                    $display("FAIL_CACHE: P5 step %0d got=0x%016h exp=0x%016h", step, rv, exp_w);
                    $fatal(1, "p5_rand_mismatch");
                end
            end
        end

        if (data_slice_multi_rd_err != 0) begin
            $display("FAIL_CACHE: multiple data-slice macros asserted A_REN on single-word read (%0d)", data_slice_multi_rd_err);
            $fatal(1, "slice_power_gate");
        end
        repeat (6) @(posedge clk);
        $display("PASS_CACHE_SUBSYS seed=%0d", seed);
        $finish;
    end
endmodule
