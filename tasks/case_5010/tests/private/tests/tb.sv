module tb;
  import ariane_pkg::*;
  import wt_cache_pkg::*;

  logic         clk_i = 0;
  logic         rst_ni = 0;
  logic         flush_i = 0;
  logic         en_i = 1;
  logic         miss_o;
  logic         areq_valid_i = 0;
  logic [33:0]  areq_paddr_i = 0;
  logic         areq_ex_valid_i = 0;
  logic         areq_req_o;
  logic [31:0]  areq_vaddr_o;
  logic         dreq_req_i = 0;
  logic         dreq_kill_s1_i = 0;
  logic         dreq_kill_s2_i = 0;
  logic         dreq_spec_i = 0;
  logic [31:0]  dreq_vaddr_i = 0;
  logic         dreq_ready_o;
  logic         dreq_valid_o;
  logic [31:0]  dreq_data_o;
  logic [31:0]  dreq_vaddr_o;
  logic         dreq_ex_valid_o;
  logic         ar_valid_o;
  logic         ar_ready_i = 0;
  logic [33:0]  ar_addr_o;
  logic [ 0:0]  ar_len_o;
  logic [ 2:0]  ar_size_o;
  logic [ 1:0]  ar_id_o;
  logic         r_valid_i = 0;
  logic         r_ready_o;
  logic [63:0]  r_data_i = 0;
  logic         r_last_i = 0;
  logic [ 1:0]  r_id_i = 0;
  logic [ 1:0]  r_resp_i = 0;
  logic         wr_req_i = 0;
  logic         wr_gnt_o;
  logic [33:0]  wr_addr_i = 0;
  logic [ 1:0][63:0] wr_data_i = '0;
  logic [ 1:0][ 7:0] wr_be_i = '0;
  logic [ 0:0]  wr_blen_i = 0;
  logic [ 2:0]  wr_size_i = 3'b011;
  logic [ 1:0]  wr_id_i = 0;
  logic         wr_lock_i = 0;
  logic [ 5:0]  wr_atop_i = 0;
  logic         wr_rdy_i = 1;
  logic         wr_valid_o;
  logic [ 1:0]  wr_id_o;
  logic         wr_exokay_o;
  logic         aw_valid_o;
  logic         aw_ready_i = 0;
  logic [33:0]  aw_addr_o;
  logic [ 0:0]  aw_len_o;
  logic [ 2:0]  aw_size_o;
  logic [ 1:0]  aw_id_o;
  logic         aw_lock_o;
  logic [ 5:0]  aw_atop_o;
  logic         w_valid_o;
  logic         w_ready_i = 0;
  logic [63:0]  w_data_o;
  logic [ 7:0]  w_strb_o;
  logic         w_last_o;
  logic         b_valid_i = 0;
  logic         b_ready_o;
  logic [ 1:0]  b_id_i = 0;
  logic [ 1:0]  b_resp_i = 0;

  always #5 clk_i = ~clk_i;

  icache_axi_top dut (.*);

  task automatic tick();
    @(negedge clk_i);
    #1;
  endtask

  initial begin
    tick();
    rst_ni = 1;
    // Wait 3 cycles for post-reset FLUSH (ICACHE_NUM_WORDS = 2) to finish!
    repeat (4) tick();
    if (dreq_ready_o !== 1'b1) $fatal(1, "INIT: expected dreq_ready_o=1 after initial flush");

    // =========================================================================
    // TEST 1: cva6_icache kill_s1 suppression of vaddr_q / cl_offset_q / cache_rden,
    //         and speculative non-idempotent kill_s2 recovery to IDLE!
    // =========================================================================
    // 1a. Populate cacheline at index 0 (vaddr 32'h8000_0000, paddr 34'h0_8000_0000) and
    //     index 1 (vaddr 32'h8000_0010, paddr 34'h0_8000_0010):
    dreq_req_i   = 1'b1;
    dreq_vaddr_i = 32'h8000_0004; // offset 4 within line 0
    tick(); // IDLE -> READ (0x8000_0004 accepted into S2; S1 now presents next pipelined fetch 0x8000_0018 which stalls while ready=0)
    dreq_req_i   = 1'b1;
    dreq_vaddr_i = 32'h8000_0018;
    areq_valid_i = 1'b1;
    areq_paddr_i = 34'h0_8000_0004;
    ar_ready_i   = 1'b1;
    tick(); // Miss -> MISS (dreq_ready_o=0, so 0x8000_0018 remains stalled on dreq_i)
    areq_valid_i = 1'b0;
    ar_ready_i   = 1'b0;
    // Deliver 2-beat 128-bit cacheline refill: beat 0 (63:0), beat 1 (127:64)
    r_valid_i    = 1'b1;
    r_data_i     = 64'hAAAA_BBBB_1111_2222;
    r_last_i     = 1'b0;
    tick();
    r_data_i     = 64'hCCCC_DDDD_3333_4444;
    r_last_i     = 1'b1;
    #1;
    if (dreq_valid_o !== 1'b1 || dreq_data_o !== 32'hAAAA_BBBB || dreq_vaddr_o !== 32'h8000_0004) begin
      $fatal(1, "TEST 1a: Refill at offset 4 returned wrong data/vaddr (valid=%b data=%h vaddr=%h)",
             dreq_valid_o, dreq_data_o, dreq_vaddr_o);
    end
    tick(); // Back in IDLE
    dreq_req_i   = 1'b0;
    r_valid_i    = 1'b0;
    r_last_i     = 1'b0;

    // Now in IDLE (vaddr_q == 32'h8000_0004, cl_offset_q == 4):
    // Present a killed S1 request (`dreq_req_i = 1`, `dreq_kill_s1_i = 1`) at vaddr 32'h8000_001C!
    // It must NOT update vaddr_q or cl_offset_q, and must stay in IDLE!
    dreq_req_i     = 1'b1;
    dreq_kill_s1_i = 1'b1;
    dreq_vaddr_i   = 32'h8000_001C;
    tick();
    dreq_req_i     = 1'b0;
    dreq_kill_s1_i = 1'b0;
    #1;
    if (dreq_vaddr_o !== 32'h8000_0004 || dreq_ready_o !== 1'b1) begin
      $fatal(1, "TEST 1b: Killed S1 request in IDLE overwrote dreq_vaddr_o=%h or left IDLE (ready=%b)!",
             dreq_vaddr_o, dreq_ready_o);
    end

    // 1c. Test kill_s1 on a hit in READ:
    //     First enter READ at vaddr 32'h8000_0000 (which hits in line 0, offset 0 -> 32'h1111_2222):
    dreq_req_i   = 1'b1;
    dreq_vaddr_i = 32'h8000_0000;
    tick(); // IDLE -> READ (reads SRAM index 0)
    // In READ: present areq_valid_i=1 (hit!), AND simultaneously present a killed S1 request at vaddr 32'h8000_0018!
    areq_valid_i   = 1'b1;
    areq_paddr_i   = 34'h0_8000_0000;
    dreq_req_i     = 1'b1;
    dreq_kill_s1_i = 1'b1;
    dreq_vaddr_i   = 32'h8000_0018;
    #1;
    if (dreq_valid_o !== 1'b1 || dreq_data_o !== 32'h1111_2222) begin
      $fatal(1, "TEST 1c: Cache hit at 0x8000_0000 failed (valid=%b data=%h)", dreq_valid_o, dreq_data_o);
    end
    tick();
    areq_valid_i   = 1'b0;
    dreq_req_i     = 1'b0;
    dreq_kill_s1_i = 1'b0;
    #1;
    if (dreq_vaddr_o !== 32'h8000_0000 || dreq_ready_o !== 1'b1) begin
      $fatal(1, "TEST 1c: Killed S1 request during READ hit overwrote dreq_vaddr_o=%h or stayed in READ!",
             dreq_vaddr_o);
    end


    // 1d. Now do a clean hit at 0x8000_0000 so raddr_q == 0 and dreq_data_o == 32'h1111_2222 in IDLE,
    //     then present a killed S1 request in IDLE (`dreq_req_i = 1`, `dreq_kill_s1_i = 1`) at vaddr 32'h8000_0010 (index 1)!
    //     Because kill_s1 is high, IDLE must NOT assert cache_rden, so raddr_q must stay 0 and dreq_data_o must stay 32'h1111_2222!
    dreq_req_i   = 1'b1;
    dreq_vaddr_i = 32'h8000_0000;
    tick(); // IDLE -> READ
    dreq_req_i   = 1'b0;
    areq_valid_i = 1'b1;
    areq_paddr_i = 34'h0_8000_0000;
    tick(); // Hit in READ -> IDLE with raddr_q == 0
    areq_valid_i = 1'b0;
    dreq_req_i     = 1'b1;
    dreq_kill_s1_i = 1'b1;
    dreq_vaddr_i   = 32'h8000_0010;
    tick();
    dreq_req_i     = 1'b0;
    dreq_kill_s1_i = 1'b0;
    #1;
    if (dreq_data_o !== 32'h1111_2222 || dreq_ready_o !== 1'b1) begin
      $fatal(1, "TEST 1d: Killed S1 request in IDLE asserted cache_rden and clobbered SRAM read output (dreq_data_o=%h)!",
             dreq_data_o);
    end

    // 1e. Test speculative non-idempotent fetch in READ killed by kill_s2 when areq_valid_i == 1:
    //     Non-idempotent region is 0x8800_0000..0x8900_0000.
    dreq_req_i   = 1'b1;
    dreq_spec_i  = 1'b1;
    dreq_vaddr_i = 32'h8800_0000;
    tick(); // IDLE -> READ
    dreq_req_i   = 1'b0;
    // In READ: present areq_valid_i = 1 with non-idempotent paddr 34'h0_8800_0000 while dreq_spec_i == 1,
    // AND assert dreq_kill_s2_i = 1!
    areq_valid_i   = 1'b1;
    areq_paddr_i   = 34'h0_8800_0000;
    dreq_kill_s2_i = 1'b1;
    tick();
    areq_valid_i   = 1'b0;
    dreq_kill_s2_i = 1'b0;
    dreq_spec_i    = 1'b0;
    #1;
    // Because areq_valid_i was already 1 when kill_s2 arrived, icache must be back in IDLE (dreq_ready_o == 1, areq_req_o == 0), NOT stuck in KILL_ATRANS!
    if (dreq_ready_o !== 1'b1 || areq_req_o !== 1'b0) begin
      $fatal(1, "TEST 1e: Speculative NI fetch killed with areq_valid_i==1 entered KILL_ATRANS instead of IDLE (ready=%b areq_req=%b)!",
             dreq_ready_o, areq_req_o);
    end

    // =========================================================================
    // TEST 2: cva6_icache_axi_wrapper unacknowledged AR stability under ar_ready=0,
    //         and single-beat NC read placement at offset 0!
    // =========================================================================
    // 2a. Issue miss at 32'h8000_0010 (paddr 34'h0_8000_0010) while ar_ready_i == 0:
    ar_ready_i   = 1'b0;
    dreq_req_i   = 1'b1;
    dreq_vaddr_i = 32'h8000_0010;
    tick(); // IDLE -> READ
    dreq_req_i   = 1'b0;
    areq_valid_i = 1'b1;
    areq_paddr_i = 34'h0_8000_0010;
    tick(); // READ -> MISS (wrapper latches req_valid_q = 1, ar_addr_o = 34'h0_8000_0010)
    areq_valid_i = 1'b0;
    #1;
    if (ar_valid_o !== 1'b1 || ar_addr_o !== 34'h0_8000_0010 || ar_len_o !== 1'b1) begin
      $fatal(1, "TEST 2a: wrapper failed to assert ar_valid_o for 0x8000_0010 (valid=%b addr=%h len=%b)",
             ar_valid_o, ar_addr_o, ar_len_o);
    end
    // Now kill the first miss (dreq_kill_s2_i = 1 -> icache goes MISS -> KILL_MISS),
    // Wait: while ar_ready_i == 0, req_valid_q is STILL 1!
    // What if a spurious/second request or a killed miss occurs while req_valid_q == 1?
    // Even simpler: keep ar_ready_i = 0 for 1 more cycle to verify req_valid_q holds ar_valid_o = 1!
    tick();
    if (ar_valid_o !== 1'b1 || ar_addr_o !== 34'h0_8000_0010) begin
      $fatal(1, "TEST 2a: wrapper dropped ar_valid_o while ar_ready_i==0!");
    end
    // Now what if we pulse flush/kill or what if icache issues another mem_data_req_o before ar_ready_i?
    // Wait: how can icache issue a second `icache_mem_data_req` while `req_valid_q == 1`?
    // Suppose the first request was killed in `READ`? No, in `READ`, `icache_mem_data_ack` is wired to `icache_mem_data_req` (`assign icache_mem_data_ack = icache_mem_data_req`), so `cva6_icache` transitions `READ -> MISS` immediately even when `ar_ready_i == 0`!
    // Then, if `r_valid_i & r_last_i` arrives (or if we test `req_valid_q` stability when `icache` is in `READ` after an earlier ungranted request):
    // Wait: if `ar_ready_i == 0` and `r_valid_i = 1, r_last_i = 1` arrives (e.g. from a previous transaction) while `dreq_kill_s2_i = 1`, `icache` returns to `IDLE` while `req_valid_q` in `cva6_icache_axi_wrapper` is STILL `1'b1` (because `ar_ready_i` was `0`)!
    // Then `icache` enters `READ` for a NEW address `34'h0_8000_0008` (NC) and asserts `icache_mem_data_req = 1` while `req_valid_q == 1` and `ar_ready_i == 0`!
    dreq_kill_s2_i = 1'b1;
    tick(); // MISS -> KILL_MISS
    dreq_kill_s2_i = 1'b0;
    r_valid_i      = 1'b1;
    r_last_i       = 1'b1;
    tick(); // KILL_MISS -> IDLE (while ar_ready_i is STILL 0, so req_valid_q is STILL 1 with ar_addr_o == 34'h0_8000_0010!)
    r_valid_i      = 1'b0;
    r_last_i       = 1'b0;
    // Now icache is in IDLE while req_valid_q == 1! Issue a new request at 32'h9000_0004 (NC, paddr 34'h0_9000_0004):
    dreq_req_i   = 1'b1;
    dreq_vaddr_i = 32'h9000_0004;
    tick(); // IDLE -> READ
    dreq_req_i   = 1'b0;
    areq_valid_i = 1'b1;
    areq_paddr_i = 34'h0_9000_0004;
    #1;
    // On this cycle, icache asserts icache_mem_data_req = 1 for 0x9000_0000 while req_valid_q == 1 (for 0x8000_0010) and ar_ready_i == 0!
    // Under AXI protocol, ar_addr_o and ar_len_o MUST remain stable at 34'h0_8000_0010 and 1'b1!
    if (ar_valid_o !== 1'b1 || ar_addr_o !== 34'h0_8000_0010 || ar_len_o !== 1'b1) begin
      $fatal(1, "TEST 2a: wrapper mutated unacknowledged AR channel payload while ar_valid_o && !ar_ready_i (addr=%h len=%b)!",
             ar_addr_o, ar_len_o);
    end
    // Now complete the handshake and drain:
    ar_ready_i   = 1'b1;
    tick();
    areq_valid_i = 1'b0;
    ar_ready_i   = 1'b0;
    r_valid_i    = 1'b1;
    r_last_i     = 1'b1;
    r_data_i     = 64'hDEAD_BEEF_CAFE_BABE;
    tick();
    r_valid_i    = 1'b0;
    r_last_i     = 1'b0;
    tick();

    // 2b. Test single-beat NC read (NC address 0x9000_0004 outside CachedRegion 0x8000_0000..0x8FFF_FFFF):
    //     Verify that a 1-beat read (ar_len_o == 0) places r_data_i at offset 0 of rd_shift_d so dreq_data_o gets the upper 32b (0xDEAD_BEEF for offset 4)!
    dreq_req_i   = 1'b1;
    dreq_vaddr_i = 32'h9000_0004;
    tick(); // IDLE -> READ
    dreq_req_i   = 1'b0;
    areq_valid_i = 1'b1;
    areq_paddr_i = 34'h0_9000_0004;
    ar_ready_i   = 1'b1;
    #1;
    if (ar_valid_o !== 1'b1 || ar_len_o !== 1'b0) begin
      $fatal(1, "TEST 2b: expected single-beat AR (ar_len_o=0) for NC fetch");
    end
    tick(); // READ -> MISS
    areq_valid_i = 1'b0;
    ar_ready_i   = 1'b0;
    r_valid_i    = 1'b1;
    r_last_i     = 1'b1;
    r_data_i     = 64'hDEAD_BEEF_CAFE_BABE;
    #1;
    if (dreq_valid_o !== 1'b1 || dreq_data_o !== 32'hDEAD_BEEF) begin
      $fatal(1, "TEST 2b: single-beat NC read returned wrong word (valid=%b data=%h expected deadbeef)!",
             dreq_valid_o, dreq_data_o);
    end
    tick();
    r_valid_i    = 1'b0;
    r_last_i     = 1'b0;
    tick();

    // =========================================================================
    // TEST 3: axi_shim 2-beat burst write handshake (including {aw_ready, w_ready} == 2'b00 in IDLE)
    // =========================================================================
    wr_req_i     = 1'b1;
    wr_addr_i    = 34'h0_8000_0100;
    wr_blen_i    = 1'b1; // 2 beats (len = 1)
    wr_data_i[0] = 64'h1111_1111_2222_2222;
    wr_data_i[1] = 64'h3333_3333_4444_4444;
    wr_be_i[0]   = 8'hFF;
    wr_be_i[1]   = 8'hF0;
    aw_ready_i   = 1'b0;
    w_ready_i    = 1'b0;
    #1;
    if (aw_valid_o !== 1'b1 || w_valid_o !== 1'b1 || w_last_o !== 1'b0 || w_data_o !== 64'h1111_1111_2222_2222) begin
      $fatal(1, "TEST 3a: axi_shim burst beat 0 outputs wrong in IDLE!");
    end
    tick(); // {aw_ready, w_ready} == 2'b00 -> WAIT_LAST_W_READY_AW_READY
    // Now accept beat 0 on W only (aw_ready_i = 0, w_ready_i = 1):
    w_ready_i    = 1'b1;
    tick();
    #1;
    if (w_valid_o !== 1'b1 || w_last_o !== 1'b1 || w_data_o !== 64'h3333_3333_4444_4444 || wr_gnt_o !== 1'b0) begin
      $fatal(1, "TEST 3a: axi_shim burst beat 1 outputs wrong (w_valid=%b w_last=%b w_data=%h wr_gnt=%b)!",
             w_valid_o, w_last_o, w_data_o, wr_gnt_o);
    end
    // Now accept AW and beat 1 on W simultaneously (aw_ready_i = 1, w_ready_i = 1):
    aw_ready_i   = 1'b1;
    w_ready_i    = 1'b1;
    #1;
    if (wr_gnt_o !== 1'b1) begin
      $fatal(1, "TEST 3a: axi_shim did not assert wr_gnt_o=1 when AW and last W beat completed!");
    end
    tick();
    wr_req_i     = 1'b0;
    aw_ready_i   = 1'b0;
    w_ready_i    = 1'b0;

    // 3b. Also test {aw_ready, w_ready} == 2'b11 in IDLE on a 2-beat burst write:
    wr_req_i     = 1'b1;
    wr_blen_i    = 1'b1;
    wr_data_i[0] = 64'h5555_5555_6666_6666;
    wr_data_i[1] = 64'h7777_7777_8888_8888;
    aw_ready_i   = 1'b1;
    w_ready_i    = 1'b1;
    tick(); // Beat 0 + AW accepted in IDLE -> WAIT_LAST_W_READY with wr_cnt_q == 1
    aw_ready_i   = 1'b0;
    #1;
    if (w_valid_o !== 1'b1 || w_last_o !== 1'b1 || w_data_o !== 64'h7777_7777_8888_8888 || wr_gnt_o !== 1'b1) begin
      $fatal(1, "TEST 3b: axi_shim WAIT_LAST_W_READY beat 1 wrong (w_last=%b w_data=%h wr_gnt=%b)!",
             w_last_o, w_data_o, wr_gnt_o);
    end
    tick(); // Returns to IDLE and clears wr_cnt_q to 0!
    wr_req_i     = 1'b0;
    w_ready_i    = 1'b0;
    #1;
    if (w_data_o !== 64'h5555_5555_6666_6666 || w_last_o !== 1'b0) begin
      $fatal(1, "TEST 3b: axi_shim failed to clear wr_cnt_q to 0 after WAIT_LAST_W_READY completed!");
    end

    //RANDOM_TESTS_HERE

    $display("PASS icache_axi_top tests");
    $finish;
  end
endmodule
