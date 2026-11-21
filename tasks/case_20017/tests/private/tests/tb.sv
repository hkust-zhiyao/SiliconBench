`timescale 1ns/1ps
`ifndef DUT_MOD
`define DUT_MOD dcache
`endif

module tb;
    reg         clk;
    reg         rst;
    reg  [31:0] mem_addr;
    reg  [31:0] mem_data_wr;
    reg         mem_rd;
    reg  [ 3:0] mem_wr;
    reg         mem_cacheable;
    reg  [10:0] mem_req_tag;
    reg         mem_invalidate;
    reg         mem_writeback;
    reg         mem_flush;

    reg         axi_awready;
    reg         axi_wready;
    reg         axi_bvalid;
    reg  [ 1:0] axi_bresp;
    reg  [ 3:0] axi_bid;
    reg         axi_arready;
    reg         axi_rvalid;
    reg  [31:0] axi_rdata;
    reg  [ 1:0] axi_rresp;
    reg  [ 3:0] axi_rid;
    reg         axi_rlast;

    wire [31:0] mem_data_rd;
    wire        mem_accept;
    wire        mem_ack;
    wire        mem_error;
    wire [10:0] mem_resp_tag;

    wire        axi_awvalid;
    wire [31:0] axi_awaddr;
    wire [ 3:0] axi_awid;
    wire [ 7:0] axi_awlen;
    wire [ 1:0] axi_awburst;
    wire        axi_wvalid;
    wire [31:0] axi_wdata;
    wire [ 3:0] axi_wstrb;
    wire        axi_wlast;
    wire        axi_bready;
    wire        axi_arvalid;
    wire [31:0] axi_araddr;
    wire [ 3:0] axi_arid;
    wire [ 7:0] axi_arlen;
    wire [ 1:0] axi_arburst;
    wire        axi_rready;

    `DUT_MOD u_dut (
        .clk_i            (clk),
        .rst_i            (rst),
        .mem_addr_i       (mem_addr),
        .mem_data_wr_i    (mem_data_wr),
        .mem_rd_i         (mem_rd),
        .mem_wr_i         (mem_wr),
        .mem_cacheable_i  (mem_cacheable),
        .mem_req_tag_i    (mem_req_tag),
        .mem_invalidate_i (mem_invalidate),
        .mem_writeback_i  (mem_writeback),
        .mem_flush_i      (mem_flush),
        .axi_awready_i    (axi_awready),
        .axi_wready_i     (axi_wready),
        .axi_bvalid_i     (axi_bvalid),
        .axi_bresp_i      (axi_bresp),
        .axi_bid_i        (axi_bid),
        .axi_arready_i    (axi_arready),
        .axi_rvalid_i     (axi_rvalid),
        .axi_rdata_i      (axi_rdata),
        .axi_rresp_i      (axi_rresp),
        .axi_rid_i        (axi_rid),
        .axi_rlast_i      (axi_rlast),
        .mem_data_rd_o    (mem_data_rd),
        .mem_accept_o     (mem_accept),
        .mem_ack_o        (mem_ack),
        .mem_error_o      (mem_error),
        .mem_resp_tag_o   (mem_resp_tag),
        .axi_awvalid_o    (axi_awvalid),
        .axi_awaddr_o     (axi_awaddr),
        .axi_awid_o       (axi_awid),
        .axi_awlen_o      (axi_awlen),
        .axi_awburst_o    (axi_awburst),
        .axi_wvalid_o     (axi_wvalid),
        .axi_wdata_o      (axi_wdata),
        .axi_wstrb_o      (axi_wstrb),
        .axi_wlast_o      (axi_wlast),
        .axi_bready_o     (axi_bready),
        .axi_arvalid_o    (axi_arvalid),
        .axi_araddr_o     (axi_araddr),
        .axi_arid_o       (axi_arid),
        .axi_arlen_o      (axi_arlen),
        .axi_arburst_o    (axi_arburst),
        .axi_rready_o     (axi_rready)
    );

    initial clk = 1'b0;
    always #4.2 clk = ~clk;

    // Backing memory indexed by sparse associative array + AXI4 slave model with protocol assertions
    logic [31:0] ext_mem [int unsigned];
    int unsigned aw_cnt, ar_cnt, seed_val, bp_mode;

    function automatic logic [31:0] rd_mem(input logic [31:0] addr);
        int unsigned idx;
        idx = addr >> 2;
        if (ext_mem.exists(idx)) return ext_mem[idx];
        return 32'hA5A5_0000 ^ (addr * 32'h0101_0103);
    endfunction

    task automatic wr_mem(input logic [31:0] addr, input logic [31:0] dat, input logic [3:0] strb);
        int unsigned idx;
        logic [31:0] cur;
        idx = addr >> 2;
        cur = rd_mem(addr);
        if (strb[0]) cur[ 7: 0] = dat[ 7: 0];
        if (strb[1]) cur[15: 8] = dat[15: 8];
        if (strb[2]) cur[23:16] = dat[23:16];
        if (strb[3]) cur[31:24] = dat[31:24];
        ext_mem[idx] = cur;
    endtask

    // Decoupled AXI4 AW / W / B / AR / R slave with stability assertions & configurable backpressure
    logic        aw_held_v;
    logic [31:0] aw_held_addr;
    logic [ 7:0] aw_held_len;
    logic        w_held_v;
    logic [31:0] w_held_data;
    logic [ 3:0] w_held_strb;
    logic        w_held_last;

    typedef struct packed { logic [31:0] addr; logic [7:0] len; logic [3:0] id; } ax_cmd_t;
    typedef struct packed { logic [31:0] data; logic [3:0] strb; logic last; } w_beat_t;
    ax_cmd_t aw_q[$], ar_q[$];
    w_beat_t w_q[$];
    logic [3:0] b_q[$];
    int unsigned aw_stall_cnt, w_stall_cnt, ar_stall_cnt, r_beat_idx;
    ax_cmd_t cur_wr, cur_rd;
    logic    wr_active, rd_active;
    int unsigned wr_beat_idx;

    always @(posedge clk) begin
        if (rst) begin
            aw_held_v <= 1'b0; w_held_v <= 1'b0;
            aw_q.delete(); ar_q.delete(); w_q.delete(); b_q.delete();
            aw_cnt <= 0; ar_cnt <= 0;
            wr_active <= 1'b0; rd_active <= 1'b0;
            aw_stall_cnt <= 0; w_stall_cnt <= 0; ar_stall_cnt <= 0;
            axi_awready <= 1'b0; axi_wready <= 1'b0; axi_arready <= 1'b0;
            axi_bvalid <= 1'b0; axi_bresp <= 2'b00; axi_bid <= 4'd0;
            axi_rvalid <= 1'b0; axi_rdata <= 32'd0; axi_rresp <= 2'b00; axi_rid <= 4'd0; axi_rlast <= 1'b0;
        end else begin
            // AXI4 AW stability check when stalled
            if (aw_held_v) begin
                if (!axi_awvalid || axi_awaddr !== aw_held_addr || axi_awlen !== aw_held_len) begin
                    $display("FAIL: AXI AW mutated while awready=0 (addr %h->%h len %0d->%0d)", aw_held_addr, axi_awaddr, aw_held_len, axi_awlen);
                    $finish(1);
                end
            end
            aw_held_v <= axi_awvalid && !axi_awready;
            if (axi_awvalid && !axi_awready) begin
                aw_held_addr <= axi_awaddr;
                aw_held_len  <= axi_awlen;
            end

            if (w_held_v) begin
                if (!axi_wvalid || axi_wdata !== w_held_data || axi_wstrb !== w_held_strb || axi_wlast !== w_held_last) begin
                    $display("FAIL: AXI W mutated while wready=0");
                    $finish(1);
                end
            end
            w_held_v <= axi_wvalid && !axi_wready;
            if (axi_wvalid && !axi_wready) begin
                w_held_data <= axi_wdata;
                w_held_strb <= axi_wstrb;
                w_held_last <= axi_wlast;
            end

            // Capture handshakes
            if (axi_awvalid && axi_awready) begin
                aw_q.push_back('{addr: axi_awaddr, len: axi_awlen, id: axi_awid});
                aw_cnt <= aw_cnt + 1;
            end
            if (axi_wvalid && axi_wready) begin
                w_q.push_back('{data: axi_wdata, strb: axi_wstrb, last: axi_wlast});
            end
            if (axi_arvalid && axi_arready) begin
                ar_q.push_back('{addr: axi_araddr, len: axi_arlen, id: axi_arid});
                ar_cnt <= ar_cnt + 1;
            end

            // Commit writes when both AW and W beats arrive
            if (!wr_active && aw_q.size() > 0) begin
                cur_wr = aw_q.pop_front();
                wr_active <= 1'b1;
                wr_beat_idx <= 0;
            end else if (wr_active && w_q.size() > 0) begin
                w_beat_t wb;
                wb = w_q.pop_front();
                wr_mem(cur_wr.addr + (wr_beat_idx * 4), wb.data, wb.strb);
                if (wr_beat_idx == cur_wr.len) begin
                    if (!wb.last) begin $display("FAIL: missing wlast on final beat"); $finish(1); end
                    b_q.push_back(cur_wr.id);
                    wr_active <= 1'b0;
                end else begin
                    if (wb.last) begin $display("FAIL: premature wlast on beat %0d/%0d", wr_beat_idx, cur_wr.len); $finish(1); end
                    wr_beat_idx <= wr_beat_idx + 1;
                end
            end

            // Drive B channel
            if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 1'b0;
            end else if (!axi_bvalid && b_q.size() > 0) begin
                axi_bvalid <= 1'b1;
                axi_bid    <= b_q.pop_front();
                axi_bresp  <= 2'b00;
            end

            // Drive R channel
            if (axi_rvalid && axi_rready) begin
                if (axi_rlast) begin
                    axi_rvalid <= 1'b0;
                    axi_rlast  <= 1'b0;
                    rd_active  <= 1'b0;
                end else begin
                    r_beat_idx <= r_beat_idx + 1;
                    axi_rdata  <= rd_mem(cur_rd.addr + ((r_beat_idx + 1) * 4));
                    axi_rlast  <= ((r_beat_idx + 1) == cur_rd.len);
                end
            end else if (!rd_active && ar_q.size() > 0) begin
                cur_rd     = ar_q.pop_front();
                rd_active  <= 1'b1;
                r_beat_idx <= 0;
                axi_rvalid <= 1'b1;
                axi_rid    <= cur_rd.id;
                axi_rdata  <= rd_mem(cur_rd.addr);
                axi_rresp  <= 2'b00;
                axi_rlast  <= (cur_rd.len == 8'd0);
            end

            // Backpressure generator: bp_mode=1 specifically holds awready=0 for 3 cycles while wready=1!
            if (bp_mode == 1) begin
                if (axi_awvalid && !axi_awready && aw_stall_cnt < 3) begin
                    aw_stall_cnt <= aw_stall_cnt + 1;
                    axi_awready  <= 1'b0;
                end else begin
                    aw_stall_cnt <= 0;
                    axi_awready  <= 1'b1;
                end
                axi_wready  <= 1'b1;
                axi_arready <= 1'b1;
            end else begin
                seed_val    = seed_val * 32'h0019660D + 32'h3C6EF35F;
                axi_awready <= seed_val[0];
                axi_wready  <= seed_val[1];
                axi_arready <= seed_val[2];
            end
        end
    end

    task automatic cpu_req(
        input logic [31:0] addr, input logic [31:0] wdat,
        input logic rd, input logic [3:0] wr, input logic cacheable,
        input logic [10:0] tag, input logic inv, input logic wb, input logic fl,
        output logic [31:0] rdat
    );
        int unsigned tmo;
        @(negedge clk);
        mem_addr       = addr;
        mem_data_wr    = wdat;
        mem_rd         = rd;
        mem_wr         = wr;
        mem_cacheable  = cacheable;
        mem_req_tag    = tag;
        mem_invalidate = inv;
        mem_writeback  = wb;
        mem_flush      = fl;
        tmo = 0;
        while (1) begin
            @(posedge clk);
            if (mem_accept) break;
            tmo = tmo + 1;
            if (tmo > 4000) begin $display("FAIL: timeout waiting for mem_accept"); $finish(1); end
        end
        @(negedge clk);
        mem_rd = 1'b0; mem_wr = 4'b0; mem_invalidate = 1'b0; mem_writeback = 1'b0; mem_flush = 1'b0;
        tmo = 0;
        while (1) begin
            @(posedge clk);
            if (mem_ack) begin
                if (mem_resp_tag !== tag) begin
                    $display("FAIL: resp_tag %h != expected %h", mem_resp_tag, tag);
                    $finish(1);
                end
                if (mem_error !== 1'b0) begin
                    $display("FAIL: unexpected mem_error");
                    $finish(1);
                end
                rdat = mem_data_rd;
                break;
            end
            tmo = tmo + 1;
            if (tmo > 8000) begin $display("FAIL: timeout waiting for mem_ack"); $finish(1); end
        end
    endtask

    initial begin
        logic [31:0] rd_v, exp_v;
        int unsigned aw_before, ar_before;
        if (!$value$plusargs("SEED=%d", seed_val)) seed_val = 101;
        bp_mode = 0;
        rst = 1'b1;
        mem_addr = 0; mem_data_wr = 0; mem_rd = 0; mem_wr = 0; mem_cacheable = 1;
        mem_req_tag = 0; mem_invalidate = 0; mem_writeback = 0; mem_flush = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // 1. Invalid-way-first cold fill in Set 0 (0x8000_0000 and 0x8000_2000) -> 0 AXI writebacks!
        aw_before = aw_cnt;
        cpu_req(32'h8000_0004, 32'hDEAD_BEEF, 1'b0, 4'hF, 1'b1, 11'h101, 1'b0, 1'b0, 1'b0, rd_v);
        cpu_req(32'h8000_2008, 32'hCAFE_1234, 1'b0, 4'hF, 1'b1, 11'h102, 1'b0, 1'b0, 1'b0, rd_v);
        if (aw_cnt != aw_before) begin
            $display("FAIL: cold fill into 2-way empty set triggered premature eviction (%0d)", aw_cnt - aw_before);
            $finish(1);
        end
        // Touch Way 0 so lru_q[0]==1 (pointing to dirty Way 1), then invalidate Way 0 -> next fill must pick invalid Way 0 (0 writebacks)!
        cpu_req(32'h8000_0004, 32'h0,         1'b1, 4'h0, 1'b1, 11'h110, 1'b0, 1'b0, 1'b0, rd_v);
        cpu_req(32'h8000_0004, 32'h0,         1'b0, 4'h0, 1'b1, 11'h111, 1'b1, 1'b0, 1'b0, rd_v);
        cpu_req(32'h8000_0004, 32'hDEAD_BEEF, 1'b0, 4'hF, 1'b1, 11'h112, 1'b0, 1'b0, 1'b0, rd_v);
        if (aw_cnt != aw_before) begin
            $display("FAIL: missed invalid Way 0 and evicted dirty Way 1");
            $finish(1);
        end

        // 2. Per-set 2-way LRU recency + cross-set interference + AW=0/W=1 Beat-0 backpressure
        bp_mode = 1;
        cpu_req(32'h8000_0004, 32'h0, 1'b1, 4'h0, 1'b1, 11'h103, 1'b0, 1'b0, 1'b0, rd_v); // T0 becomes MRU, T1 becomes LRU
        if (rd_v !== 32'hDEAD_BEEF) begin $display("FAIL: T0 hit mismatch %h", rd_v); $finish(1); end
        // Perturb another set (Set 1) so global 1-bit toggle fails
        cpu_req(32'h8000_0020, 32'h1111_2222, 1'b0, 4'hF, 1'b1, 11'h104, 1'b0, 1'b0, 1'b0, rd_v);
        // Allocate T2 (0x8000_4000) in Set 0 -> MUST evict dirty T1 (0x8000_2000) under bp_mode=1 and keep T0!
        aw_before = aw_cnt;
        cpu_req(32'h8000_400C, 32'h5566_7788, 1'b0, 4'hF, 1'b1, 11'h105, 1'b0, 1'b0, 1'b0, rd_v);
        if (aw_cnt != aw_before + 1 || rd_mem(32'h8000_2008) !== 32'hCAFE_1234) begin
            $display("FAIL: LRU dirty victim T1 not written back cleanly");
            $finish(1);
        end
        ar_before = ar_cnt;
        cpu_req(32'h8000_0004, 32'h0, 1'b1, 4'h0, 1'b1, 11'h106, 1'b0, 1'b0, 1'b0, rd_v);
        if (ar_cnt != ar_before || rd_v !== 32'hDEAD_BEEF) begin
            $display("FAIL: MRU way T0 was wrongly evicted instead of LRU way T1");
            $finish(1);
        end

        // 3. High-tag alias & byte-granular partial writes across all 8 words / 4 banks + random backpressure
        bp_mode = 0;
        cpu_req(32'hC000_0004, 32'h0, 1'b1, 4'h0, 1'b1, 11'h201, 1'b0, 1'b0, 1'b0, rd_v);
        if (rd_v === 32'hDEAD_BEEF) begin $display("FAIL: high tag bit [30] alias"); $finish(1); end
        for (int w = 0; w < 8; w++) begin
            logic [31:0] a;
            a = 32'h8000_0200 + (w * 4);
            cpu_req(a, 32'h1020_3040 + w, 1'b0, 4'b1111, 1'b1, 11'(300 + w), 1'b0, 1'b0, 1'b0, rd_v);
            cpu_req(a, 32'hAA00_BB00,     1'b0, 4'b1010, 1'b1, 11'(320 + w), 1'b0, 1'b0, 1'b0, rd_v);
            cpu_req(a, 32'h00CC_00DD + w, 1'b0, 4'b0101, 1'b1, 11'(340 + w), 1'b0, 1'b0, 1'b0, rd_v);
            cpu_req(a, 32'h0,             1'b1, 4'b0000, 1'b1, 11'(360 + w), 1'b0, 1'b0, 1'b0, rd_v);
            exp_v = {8'hAA, 8'hCC, 8'hBB, 8'(8'hDD + w[7:0])};
            if (rd_v !== exp_v) begin $display("FAIL: byte-mask mismatch word %0d got %h exp %h", w, rd_v, exp_v); $finish(1); end
        end

        // 4. Interleaved uncached (mem_cacheable=0) & cached accesses
        cpu_req(32'h1000_0040, 32'hFACE_B00C, 1'b0, 4'b1111, 1'b0, 11'h401, 1'b0, 1'b0, 1'b0, rd_v);
        cpu_req(32'h1000_0040, 32'h0000_55AA, 1'b0, 4'b0011, 1'b0, 11'h402, 1'b0, 1'b0, 1'b0, rd_v);
        cpu_req(32'h8000_0200, 32'h0,         1'b1, 4'b0000, 1'b1, 11'h403, 1'b0, 1'b0, 1'b0, rd_v);
        if (rd_v !== 32'hAACC_BBDD) begin $display("FAIL: cached read after uncached write corrupted %h", rd_v); $finish(1); end
        cpu_req(32'h1000_0040, 32'h0,         1'b1, 4'b0000, 1'b0, 11'h404, 1'b0, 1'b0, 1'b0, rd_v);
        if (rd_v !== 32'hFACE_55AA) begin $display("FAIL: uncached read mismatch %h", rd_v); $finish(1); end

        // 5. CMO: mem_writeback (cleans dirty Way 1 & keeps valid), mem_invalidate (drops dirty without WB), mem_flush (dual-dirty sets)
        cpu_req(32'h8000_0400, 32'h7777_0001, 1'b0, 4'hF, 1'b1, 11'h501, 1'b0, 1'b0, 1'b0, rd_v); // Way 0
        cpu_req(32'h8000_2400, 32'h8888_0002, 1'b0, 4'hF, 1'b1, 11'h502, 1'b0, 1'b0, 1'b0, rd_v); // Way 1
        aw_before = aw_cnt;
        cpu_req(32'h8000_2400, 32'h0, 1'b0, 4'h0, 1'b1, 11'h503, 1'b0, 1'b1, 1'b0, rd_v); // writeback Way 1
        if (aw_cnt != aw_before + 1 || rd_mem(32'h8000_2400) !== 32'h8888_0002) begin
            $display("FAIL: mem_writeback did not write back dirty Way 1");
            $finish(1);
        end
        ar_before = ar_cnt;
        cpu_req(32'h8000_2400, 32'h0, 1'b1, 4'h0, 1'b1, 11'h504, 1'b0, 1'b0, 1'b0, rd_v);
        if (ar_cnt != ar_before || rd_v !== 32'h8888_0002) begin
            $display("FAIL: mem_writeback did not preserve valid clean line");
            $finish(1);
        end

        // mem_invalidate on dirty Way 0 (0x8000_0400) must drop WITHOUT writing back!
        aw_before = aw_cnt;
        cpu_req(32'h8000_0400, 32'h0, 1'b0, 4'h0, 1'b1, 11'h505, 1'b1, 1'b0, 1'b0, rd_v);
        if (aw_cnt != aw_before) begin $display("FAIL: mem_invalidate unexpectedly wrote back"); $finish(1); end
        ar_before = ar_cnt;
        cpu_req(32'h8000_0400, 32'h0, 1'b1, 4'h0, 1'b1, 11'h506, 1'b0, 1'b0, 1'b0, rd_v);
        if (ar_cnt != ar_before + 1 || rd_v === 32'h7777_0001) begin
            $display("FAIL: mem_invalidate did not drop dirty line");
            $finish(1);
        end

        // mem_flush with BOTH ways dirty in Set 0xFF (0x8000_1FE0 & 0x8000_3FE0)
        cpu_req(32'h8000_1FE0, 32'hF0F0_1111, 1'b0, 4'hF, 1'b1, 11'h507, 1'b0, 1'b0, 1'b0, rd_v);
        cpu_req(32'h8000_3FE4, 32'hF0F0_2222, 1'b0, 4'hF, 1'b1, 11'h508, 1'b0, 1'b0, 1'b0, rd_v);
        cpu_req(32'h0000_0000, 32'h0,         1'b0, 4'h0, 1'b1, 11'h509, 1'b0, 1'b0, 1'b1, rd_v);
        if (rd_mem(32'h8000_1FE0) !== 32'hF0F0_1111 || rd_mem(32'h8000_3FE4) !== 32'hF0F0_2222) begin
            $display("FAIL: mem_flush missed dirty way writeback in Set 255");
            $finish(1);
        end
        ar_before = ar_cnt;
        cpu_req(32'h8000_1FE0, 32'h0, 1'b1, 4'h0, 1'b1, 11'h50A, 1'b0, 1'b0, 1'b0, rd_v);
        if (ar_cnt != ar_before + 1 || rd_v !== 32'hF0F0_1111) begin
            $display("FAIL: mem_flush did not invalidate flushed line");
            $finish(1);
        end

        $display("ALL_TESTS_PASSED");
        $finish(0);
    end
endmodule
