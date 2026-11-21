module tb;
  import ariane_pkg::*;
  import std_cache_pkg::*;

  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 64; c.IS_XLEN64 = 1; c.PLEN = 56;
    c.AxiDataWidth = 64; c.AxiAddrWidth = 64; c.AxiIdWidth = 4; c.AxiUserWidth = 1;
    c.DCACHE_SET_ASSOC = 2; c.DCACHE_SET_ASSOC_WIDTH = 1;
    c.DCACHE_INDEX_WIDTH = 6; c.DCACHE_TAG_WIDTH = 50;
    c.DCACHE_LINE_WIDTH = 128; c.DCACHE_OFFSET_WIDTH = 4;
    c.DCACHE_NUM_WORDS = 4; c.DcacheIdWidth = 2;
    c.MaxOutstandingStores = 2;
    c.NrCachedRegionRules = 1;
    c.CachedRegionAddrBase[0] = 64'h8000_0000;
    c.CachedRegionLength[0]   = 64'h1000_0000;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();

  typedef struct packed { logic [49:0] tag; logic [127:0] data; logic valid; logic dirty; } cache_line_t;
  typedef struct packed { logic [6:0] tag; logic [15:0] data; logic [1:0] vldrty; } cl_be_t;
  typedef struct packed {
    logic [5:0]  address_index;
    logic [49:0] address_tag;
    logic [63:0] data_wdata;
    logic [7:0]  data_wuser;
    logic        data_req;
    logic        data_we;
    logic [7:0]  data_be;
    logic [1:0]  data_size;
    logic [1:0]  data_id;
    logic        kill_req;
    logic        tag_valid;
    logic [7:0]  cbo_op;
  } dcache_req_i_t;
  typedef struct packed {
    logic        data_gnt;
    logic        data_rvalid;
    logic [1:0]  data_rid;
    logic [63:0] data_rdata;
    logic        data_error;
    logic [7:0]  data_ruser;
  } dcache_req_o_t;
  typedef struct packed { logic [3:0] id; logic [63:0] addr; logic [7:0] len; logic [2:0] size; logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot; logic [3:0] qos; logic [3:0] region; logic [5:0] atop; logic user; } aw_chan_t;
  typedef struct packed { logic [63:0] data; logic [7:0] strb; logic last; logic user; } w_chan_t;
  typedef struct packed { logic [3:0] id; logic [1:0] resp; logic user; } b_chan_t;
  typedef struct packed { logic [3:0] id; logic [63:0] addr; logic [7:0] len; logic [2:0] size; logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot; logic [3:0] qos; logic [3:0] region; logic user; } ar_chan_t;
  typedef struct packed { logic [3:0] id; logic [63:0] data; logic [1:0] resp; logic last; logic user; } r_chan_t;
  typedef struct packed { aw_chan_t aw; logic aw_valid; w_chan_t w; logic w_valid; logic b_ready; ar_chan_t ar; logic ar_valid; logic r_ready; } axi_req_t;
  typedef struct packed { logic aw_ready; logic ar_ready; logic w_ready; logic b_valid; b_chan_t b; logic r_valid; r_chan_t r; } axi_rsp_t;

  logic clk_i = 0;
  logic rst_ni = 0;
  always #5 clk_i = ~clk_i;

  task automatic tick();
    @(negedge clk_i);
    #1;
  endtask

  // =========================================================================
  // 1. Standalone tag_cmp port-boundary instance (NR_PORTS = 3, SET_ASSOC = 2)
  // =========================================================================
  logic [2:0][1:0] tc_req_i = '0;
  logic [2:0]      tc_gnt_o;
  logic [2:0][5:0] tc_addr_i = '0;
  cache_line_t [2:0] tc_wdata_i = '0;
  logic [2:0]      tc_we_i = '0;
  cl_be_t [2:0]    tc_be_i = '0;
  cache_line_t [1:0] tc_rdata_o, tc_rdata_i = '0;
  logic [2:0][49:0] tc_tag_i = '0;
  logic [1:0]      tc_hit_way_o, tc_req_o;
  logic [5:0]      tc_addr_o;
  cache_line_t     tc_wdata_o;
  logic            tc_we_o;
  cl_be_t          tc_be_o;

  tag_cmp #(
    .CVA6Cfg(Cfg), .NR_PORTS(3), .ADDR_WIDTH(6),
    .l_data_t(cache_line_t), .l_be_t(cl_be_t)
  ) u_tc (
    .clk_i, .rst_ni,
    .req_i(tc_req_i), .gnt_o(tc_gnt_o), .addr_i(tc_addr_i),
    .wdata_i(tc_wdata_i), .we_i(tc_we_i), .be_i(tc_be_i),
    .rdata_o(tc_rdata_o), .tag_i(tc_tag_i), .hit_way_o(tc_hit_way_o),
    .req_o(tc_req_o), .addr_o(tc_addr_o), .wdata_o(tc_wdata_o),
    .we_o(tc_we_o), .be_o(tc_be_o), .rdata_i(tc_rdata_i)
  );

  // =========================================================================
  // 2. Standalone cache_ctrl port-boundary instance
  // =========================================================================
  logic cc_flush = 0, cc_bypass = 0, cc_busy;
  dcache_req_i_t cc_req_i = '0;
  dcache_req_o_t cc_req_o;
  logic [1:0] cc_sram_req_o;
  logic [5:0] cc_sram_addr_o;
  logic       cc_sram_gnt_i = 1;
  cache_line_t cc_sram_data_o;
  cl_be_t      cc_sram_be_o;
  logic [49:0] cc_sram_tag_o;
  cache_line_t [1:0] cc_sram_data_i = '0;
  logic        cc_sram_we_o;
  logic [1:0]  cc_hit_way_i = '0;
  miss_req_t   cc_miss_req_o;
  logic        cc_miss_gnt_i = 0, cc_active_serving_i = 0;
  logic [63:0] cc_crit_word_i = '0, cc_bypass_data_i = '0;
  logic        cc_crit_valid_i = 0, cc_bypass_gnt_i = 0, cc_bypass_valid_i = 0;
  logic [55:0] cc_mshr_addr_o;
  logic        cc_mshr_addr_match_i = 0, cc_mshr_idx_match_i = 0;

  cache_ctrl #(
    .CVA6Cfg(Cfg), .cache_line_t(cache_line_t), .cl_be_t(cl_be_t),
    .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t)
  ) u_cc (
    .clk_i, .rst_ni, .flush_i(cc_flush), .bypass_i(cc_bypass), .busy_o(cc_busy),
    .req_port_i(cc_req_i), .req_port_o(cc_req_o),
    .req_o(cc_sram_req_o), .addr_o(cc_sram_addr_o), .gnt_i(cc_sram_gnt_i),
    .data_o(cc_sram_data_o), .be_o(cc_sram_be_o), .tag_o(cc_sram_tag_o),
    .data_i(cc_sram_data_i), .we_o(cc_sram_we_o), .hit_way_i(cc_hit_way_i),
    .miss_req_o(cc_miss_req_o), .miss_gnt_i(cc_miss_gnt_i), .active_serving_i(cc_active_serving_i),
    .critical_word_i(cc_crit_word_i), .critical_word_valid_i(cc_crit_valid_i),
    .bypass_gnt_i(cc_bypass_gnt_i), .bypass_valid_i(cc_bypass_valid_i), .bypass_data_i(cc_bypass_data_i),
    .mshr_addr_o(cc_mshr_addr_o), .mshr_addr_matches_i(cc_mshr_addr_match_i), .mshr_index_matches_i(cc_mshr_idx_match_i)
  );

  // =========================================================================
  // 3. Standalone miss_handler port-boundary instance (NR_PORTS = 2, SET_ASSOC = 2)
  // =========================================================================
  logic mh_flush = 0, mh_flush_ack, mh_miss, mh_busy = 0;
  logic [1:0][$bits(miss_req_t)-1:0] mh_miss_req_i = '0;
  logic [1:0] mh_bypass_gnt_o, mh_bypass_valid_o, mh_miss_gnt_o, mh_active_serving_o;
  logic [1:0][63:0] mh_bypass_data_o;
  axi_req_t mh_axi_bypass_o, mh_axi_data_o;
  axi_rsp_t mh_axi_bypass_i = '0, mh_axi_data_i = '0;
  logic [63:0] mh_crit_word_o;
  logic        mh_crit_valid_o;
  logic [1:0][55:0] mh_mshr_addr_i = '0;
  logic [1:0] mh_mshr_addr_match_o, mh_mshr_idx_match_o;
  amo_req_t  mh_amo_req_i = '0;
  amo_resp_t mh_amo_resp_o;
  logic [1:0] mh_sram_req_o;
  logic [5:0] mh_sram_addr_o;
  cache_line_t mh_sram_data_o;
  cl_be_t      mh_sram_be_o;
  cache_line_t [1:0] mh_sram_data_i = '0;
  logic        mh_sram_we_o;

  miss_handler #(
    .CVA6Cfg(Cfg), .NR_PORTS(2), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .cache_line_t(cache_line_t), .cl_be_t(cl_be_t)
  ) u_mh (
    .clk_i, .rst_ni, .flush_i(mh_flush), .flush_ack_o(mh_flush_ack), .miss_o(mh_miss), .busy_i(mh_busy),
    .miss_req_i(mh_miss_req_i), .bypass_gnt_o(mh_bypass_gnt_o), .bypass_valid_o(mh_bypass_valid_o), .bypass_data_o(mh_bypass_data_o),
    .axi_bypass_o(mh_axi_bypass_o), .axi_bypass_i(mh_axi_bypass_i),
    .miss_gnt_o(mh_miss_gnt_o), .active_serving_o(mh_active_serving_o),
    .critical_word_o(mh_crit_word_o), .critical_word_valid_o(mh_crit_valid_o),
    .axi_data_o(mh_axi_data_o), .axi_data_i(mh_axi_data_i),
    .mshr_addr_i(mh_mshr_addr_i), .mshr_addr_matches_o(mh_mshr_addr_match_o), .mshr_index_matches_o(mh_mshr_idx_match_o),
    .amo_req_i(mh_amo_req_i), .amo_resp_o(mh_amo_resp_o),
    .req_o(mh_sram_req_o), .addr_o(mh_sram_addr_o), .data_o(mh_sram_data_o),
    .be_o(mh_sram_be_o), .data_i(mh_sram_data_i), .we_o(mh_sram_we_o)
  );

  // =========================================================================
  // 4. Standalone axi_adapter_arbiter port-boundary instance
  // =========================================================================
  bypass_req_t [1:0] arb_req_i = '0;
  bypass_rsp_t [1:0] arb_rsp_o;
  bypass_req_t       arb_req_o;
  bypass_rsp_t       arb_rsp_i = '0;

  axi_adapter_arbiter #(
    .NR_PORTS(2), .MAX_OUTSTANDING_REQ(2),
    .req_t(bypass_req_t), .rsp_t(bypass_rsp_t)
  ) u_arb (
    .clk_i, .rst_ni,
    .req_i(arb_req_i), .rsp_o(arb_rsp_o),
    .req_o(arb_req_o), .rsp_i(arb_rsp_i)
  );

  initial begin
    tick();
    rst_ni = 1;
    #1;

    // =========================================================================
    // TEST 1: tag_cmp priority arbitration and one-hot grant exclusivity
    // =========================================================================
    // 1a. When all ports are idle (tc_req_i == '0), tc_gnt_o and tc_req_o must be '0!
    if (tc_gnt_o !== 3'b000 || tc_req_o !== 2'b00) begin
      $fatal(1, "TEST 1a: tag_cmp asserted gnt_o=%b or req_o=%b when all ports idle!", tc_gnt_o, tc_req_o);
    end
    tick();
    // After an idle cycle, id_q must be 0 so hit_way_o is 0 even if rdata_i[2] matches tag_i[2]
    tc_rdata_i[0] = '{tag: 50'h12345, data: '0, valid: 1'b1, dirty: 1'b0};
    tc_tag_i[2]   = 50'h12345;
    #1;
    if (tc_hit_way_o !== 2'b00) begin
      $fatal(1, "TEST 1a: tag_cmp selected port 2 tag after an idle cycle (hit_way_o=%b)!", tc_hit_way_o);
    end

    // 1b. Port 2 requests while ports 0 and 1 are idle: only gnt_o[2] may assert!
    tc_req_i[2]  = 2'b11;
    tc_addr_i[2] = 6'h2A;
    #1;
    if (tc_gnt_o !== 3'b100 || tc_req_o !== 2'b11 || tc_addr_o !== 6'h2A) begin
      $fatal(1, "TEST 1b: tag_cmp wrong grant when only port 2 requests (gnt_o=%b req_o=%b addr_o=%h)",
             tc_gnt_o, tc_req_o, tc_addr_o);
    end
    tick();
    tc_req_i = '0;
    #1;
    if (tc_hit_way_o !== 2'b01) begin
      $fatal(1, "TEST 1b: tag_cmp failed to hit way 0 for port 2 on next cycle (hit_way_o=%b)", tc_hit_way_o);
    end

    // 1c. Ports 1 and 2 request simultaneously while port 0 is idle: only gnt_o[1] may assert!
    tc_req_i[1]  = 2'b10;
    tc_addr_i[1] = 6'h15;
    tc_req_i[2]  = 2'b11;
    tc_addr_i[2] = 6'h2A;
    #1;
    if (tc_gnt_o !== 3'b010 || tc_req_o !== 2'b10 || tc_addr_o !== 6'h15) begin
      $fatal(1, "TEST 1c: tag_cmp failed priority between port 1 and port 2 (gnt_o=%b req_o=%b)", tc_gnt_o, tc_req_o);
    end
    tick();
    tc_req_i = '0;

    // =========================================================================
    // TEST 2: miss_handler INIT/FLUSHING/WB multi-way req_o, flush vs AMO priority,
    //         and same-cycle 32-bit AMO sign-extension
    // =========================================================================
    // 2a. Right after reset, miss_handler is in INIT and must request ALL ways (mh_sram_req_o == 2'b11)!
    // Wait: we already ticked 3 times since rst_ni=1, so let's check on the current INIT cycle (cnt_q=3):
    if (mh_sram_req_o !== 2'b11 || mh_sram_we_o !== 1'b1) begin
      $fatal(1, "TEST 2a: miss_handler INIT failed to assert req_o=2'b11 for all ways (req_o=%b we_o=%b)!",
             mh_sram_req_o, mh_sram_we_o);
    end
    tick(); // Completes INIT (cnt_q==3 -> IDLE)

    // 2b. Simultaneous flush_i=1 and amo_req_i.req=1 in IDLE:
    //     flush_i must win and clear serve_amo_d so flush_ack_o asserts after scanning the 4 words!
    mh_flush          = 1'b1;
    mh_amo_req_i.req  = 1'b1;
    mh_amo_req_i.size = 2'b10;
    tick(); // IDLE -> FLUSH_REQ_STATUS
    mh_amo_req_i.req  = 1'b0;
    // Step through the 4 cache words; on the first word, present a dirty line in way 1 (2'b10) to test WB_CACHELINE_FLUSH!
    mh_sram_data_i[1] = '{tag: 50'h20000, data: 128'hDEAD_BEEF_CAFE_BABE_1122_3344_5566_7788, valid: 1'b1, dirty: 1'b1};
    tick(); // FLUSH_REQ_STATUS -> FLUSHING (sees dirty way 1 -> WB_CACHELINE_FLUSH)
    tick(); // Now in WB_CACHELINE_FLUSH: mh_axi_data_o.aw_valid && w_valid!
    mh_sram_data_i[1].dirty = 1'b0;
    mh_axi_data_i.aw_ready  = 1'b1;
    mh_axi_data_i.w_ready   = 1'b1;
    tick(); // Beat 0 of WB burst accepted
    #1;
    // On Beat 1 (last beat) of WB burst when aw_ready & w_ready, gnt_miss_fsm == 1, so mh_sram_req_o must equal evict_way_q (2'b10)!
    if (mh_sram_req_o !== 2'b10 || mh_sram_we_o !== 1'b1 || mh_sram_be_o.vldrty !== 2'b10) begin
      $fatal(1, "TEST 2b: miss_handler WB_CACHELINE_FLUSH failed to drive req_o=evict_way_q (req_o=%b we=%b vldrty=%b)!",
             mh_sram_req_o, mh_sram_we_o, mh_sram_be_o.vldrty);
    end
    tick();
    mh_axi_data_i.aw_ready = 1'b0;
    mh_axi_data_i.w_ready  = 1'b0;
    mh_axi_data_i.b_valid  = 1'b1;
    tick();
    mh_axi_data_i.b_valid  = 1'b0;

    // Now all lines are clean; verify FLUSHING drives req_o == 2'b11 and pulses mh_flush_ack == 1!
    begin
      int seen_ack = 0;
      for (int step = 0; step < 12; step++) begin
        #1;
        if (mh_sram_we_o && mh_sram_req_o !== 2'b11) begin
          $fatal(1, "TEST 2b: miss_handler FLUSHING drove req_o=%b instead of 2'b11!", mh_sram_req_o);
        end
        if (mh_flush_ack) seen_ack = 1;
        tick();
        if (seen_ack) break;
      end
      if (!seen_ack) begin
        $fatal(1, "TEST 2b: miss_handler failed to assert flush_ack_o when flush_i and amo_req_i.req coincided in IDLE!");
      end
    end
    mh_flush = 1'b0;
    tick();

    // 2c. Test axi_adapter_arbiter same-cycle gnt + valid in IDLE:
    arb_req_i[0].req   = 1'b1;
    arb_req_i[0].addr  = 64'h8000_1004;
    arb_rsp_i.gnt      = 1'b1;
    arb_rsp_i.valid    = 1'b1;
    arb_rsp_i.rdata    = 64'h8765_4321_1234_5678;
    #1;
    if (arb_rsp_o[0].gnt !== 1'b1 || arb_rsp_o[0].valid !== 1'b1 || arb_rsp_o[0].rdata !== 64'h8765_4321_1234_5678) begin
      $fatal(1, "TEST 2c: axi_adapter_arbiter dropped same-cycle gnt+valid in IDLE (gnt=%b valid=%b rdata=%h)!",
             arb_rsp_o[0].gnt, arb_rsp_o[0].valid, arb_rsp_o[0].rdata);
    end
    tick();
    arb_req_i = '0;
    arb_rsp_i = '0;
    // Verify arbiter returned to IDLE and can immediately serve port 1!
    arb_req_i[1].req  = 1'b1;
    arb_req_i[1].addr = 64'h8000_2000;
    #1;
    if (arb_rsp_o[1].gnt !== 1'b1 || arb_req_o.addr !== 64'h8000_2000) begin
      $fatal(1, "TEST 2c: axi_adapter_arbiter stuck in SERVING after same-cycle completion in IDLE!");
    end
    arb_rsp_i.gnt   = 1'b1;
    arb_rsp_i.valid = 1'b1;
    tick();
    arb_req_i = '0;
    arb_rsp_i = '0;
    tick();

    // 2d. Test 32-bit AMO (size == 2'b10) at upper word (operand_a[2:0] == 3'b100) in miss_handler
    //     when AW, W, B, and R all complete on the same cycle in AMO_REQ!
    mh_amo_req_i.req       = 1'b1;
    mh_amo_req_i.amo_op    = AMO_ADD;
    mh_amo_req_i.size      = 2'b10; // 32-bit AMO
    mh_amo_req_i.operand_a = 64'h0000_0000_8000_0004; // upper 32-bit word (bit 2 == 1)
    mh_amo_req_i.operand_b = 64'h0000_0000_0000_0001;
    // Wait until miss_handler finishes its pre-AMO flush and enters AMO_REQ (mh_axi_bypass_o.aw_valid == 1)
    begin
      int guard = 0;
      while (!mh_axi_bypass_o.aw_valid) begin
        tick();
        guard++;
        if (guard > 20) $fatal(1, "TEST 2d: timeout waiting for miss_handler AMO_REQ");
      end
    end
    // Present same-cycle aw_ready, w_ready, b_valid, r_valid with negative 32-bit upper word 32'hF000_1234!
    mh_axi_bypass_i.aw_ready = 1'b1;
    mh_axi_bypass_i.w_ready  = 1'b1;
    mh_axi_bypass_i.b_valid  = 1'b1;
    mh_axi_bypass_i.r_valid  = 1'b1;
    mh_axi_bypass_i.r.data   = 64'hF000_1234_0000_5678;
    mh_axi_bypass_i.r.last   = 1'b1;
    // Step 1 cycle for axi_adapter to enter WAIT_B_VALID (where b_valid & r_valid assert valid_o in same cycle as gnt in arbiter)
    // Actually wait: in axi_adapter, gnt_o is asserted in IDLE when aw_ready & w_ready, and valid_o is asserted in WAIT_B_VALID.
    // Wait: why can amo_bypass_rsp.gnt and amo_bypass_rsp.valid both be 1 in AMO_REQ?
    // Because axi_adapter_arbiter asserts amo_bypass_rsp.gnt = 1 in IDLE, and if another port was served or if gnt & valid coincide!
    // Wait: in miss_handler AMO_REQ, on the first cycle in AMO_REQ, axi_adapter_arbiter is in IDLE, so amo_bypass_rsp.gnt == 1 immediately!
    // Wait: if axi_adapter_arbiter asserts amo_bypass_rsp.gnt = 1 on the FIRST cycle of AMO_REQ (when i_bypass_arbiter is in IDLE),
    // then miss_handler transitions AMO_REQ -> AMO_WAIT_RESP on that first cycle unless amo_bypass_rsp.valid is ALSO 1 on that cycle!
    // How can amo_bypass_rsp.gnt and amo_bypass_rsp.valid both be 1 in AMO_REQ?
    // When i_bypass_arbiter is busy serving a bypass port (state_q == SERVING) when miss_handler enters AMO_REQ:
    // While i_bypass_arbiter is in SERVING for port 0, amo_bypass_rsp.gnt is 0!
    // Then port 0 finishes and i_bypass_arbiter returns to IDLE while miss_handler is STILL in AMO_REQ!
    tick();
    begin
      int guard = 0;
      while (!mh_amo_resp_o.ack) begin
        tick();
        guard++;
        if (guard > 10) $fatal(1, "TEST 2d: timeout waiting for mh_amo_resp_o.ack");
      end
    end
    if (mh_amo_resp_o.result !== 64'hFFFF_FFFF_F000_1234) begin
      $fatal(1, "TEST 2d: 32-bit upper-word AMO sign-extension mismatch: got %h expected fffffffff0001234",
             mh_amo_resp_o.result);
    end
    mh_amo_req_i = '0;
    mh_axi_bypass_i = '0;
    tick();

    // =========================================================================
    // TEST 3: cache_ctrl pipelined store double-grant, WAIT_CRITICAL_WORD flush gate,
    //         and killed miss cancellation in WAIT_REFILL_GNT
    // =========================================================================
    // 3a. Load hit in WAIT_TAG followed immediately by a Store request:
    //     The pipelined Store must NOT receive data_gnt=1 in WAIT_TAG; it must only receive data_gnt=1 in STORE_REQ!
    cc_sram_gnt_i     = 1'b1;
    cc_req_i.data_req = 1'b1;
    cc_req_i.data_we  = 1'b0; // Load first
    cc_req_i.address_index = 6'h10;
    #1;
    if (cc_req_o.data_gnt !== 1'b1) $fatal(1, "TEST 3a: Load in IDLE did not get data_gnt");
    tick(); // Now in WAIT_TAG for the Load!
    // Present tag_valid=1 and hit_way_i=2'b01 for the Load, AND present a new Store (data_req=1, data_we=1) on req_port_i!
    cc_req_i.tag_valid   = 1'b1;
    cc_req_i.address_tag = 50'h0200_0111;
    cc_hit_way_i         = 2'b01;
    cc_sram_data_i[0]    = '{tag: 50'h0200_0111, data: 128'hCAFE_BABE_0000_0000_1234_5678_9ABC_DEF0, valid: 1'b1, dirty: 1'b0};
    cc_req_i.data_req    = 1'b1;
    cc_req_i.data_we     = 1'b1; // Pipelined Store!
    cc_req_i.address_index = 6'h18;
    cc_req_i.data_wdata  = 64'hA5A5_5A5A_F0F0_0F0F;
    cc_req_i.data_be     = 8'hFF;
    #1;
    if (cc_req_o.data_rvalid !== 1'b1 || cc_req_o.data_rdata !== 64'h1234_5678_9ABC_DEF0) begin
      $fatal(1, "TEST 3a: Load hit in WAIT_TAG did not return expected data");
    end
    if (cc_req_o.data_gnt !== 1'b0) begin
      $fatal(1, "TEST 3a: Pipelined Store in WAIT_TAG erroneously received premature data_gnt=1!");
    end
    tick(); // Now in WAIT_TAG for the pipelined Store!
    cc_req_i.data_req    = 1'b0;
    cc_req_i.address_tag = 50'h0200_0222;
    cc_hit_way_i         = 2'b10;
    #1;
    if (cc_sram_tag_o !== 50'h0200_0222) begin
      $fatal(1, "TEST 3a: tag_o did not forward req_port_i.address_tag in WAIT_TAG!");
    end
    tick(); // Now in STORE_REQ for the Store!
    #1;
    if (cc_req_o.data_gnt !== 1'b1 || cc_sram_we_o !== 1'b1 || cc_sram_data_o.tag !== 50'h0200_0222) begin
      $fatal(1, "TEST 3a: Store in STORE_REQ failed to assert data_gnt=1, we_o=1, or preserve tag (gnt=%b we=%b tag=%h)!",
             cc_req_o.data_gnt, cc_sram_we_o, cc_sram_data_o.tag);
    end
    tick(); // Back in IDLE

    // 3b. Load miss entering WAIT_REFILL_GNT, then killed (kill_req=1) before miss_gnt_i:
    //     Must deassert cc_miss_req_o.valid=0 and return to IDLE!
    cc_req_i.data_req      = 1'b1;
    cc_req_i.data_we       = 1'b0;
    cc_req_i.address_index = 6'h20;
    tick(); // IDLE -> WAIT_TAG
    cc_req_i.data_req      = 1'b0;
    cc_req_i.tag_valid     = 1'b1;
    cc_req_i.address_tag   = 50'h0200_0333;
    cc_hit_way_i           = 2'b00; // MISS!
    tick(); // WAIT_TAG -> WAIT_REFILL_GNT
    cc_req_i.tag_valid     = 1'b0;
    #1;
    if (cc_miss_req_o.valid !== 1'b1) $fatal(1, "TEST 3b: expected miss_req_o.valid=1 in WAIT_REFILL_GNT");
    // Now assert kill_req = 1 while miss_gnt_i == 0 and active_serving_i == 0!
    cc_req_i.kill_req      = 1'b1;
    #1;
    if (cc_req_o.data_rvalid !== 1'b1 || cc_miss_req_o.valid !== 1'b0) begin
      $fatal(1, "TEST 3b: kill_req in WAIT_REFILL_GNT failed to suppress miss_req_o.valid=%b or assert rvalid=%b!",
             cc_miss_req_o.valid, cc_req_o.data_rvalid);
    end
    tick();
    cc_req_i.kill_req      = 1'b0;
    #1;
    if (cc_busy !== 1'b0) begin
      $fatal(1, "TEST 3b: cache_ctrl remained busy (did not return to IDLE) after kill_req in WAIT_REFILL_GNT!");
    end

    // 3c. Load miss granted into WAIT_CRITICAL_WORD:
    //     - Verify flush_i suppresses speculative cc_sram_req_o when data_req=1
    //     - Verify pipelined Store on critical_word_valid_i does NOT get premature data_gnt=1!
    cc_req_i.data_req      = 1'b1;
    cc_req_i.data_we       = 1'b0;
    cc_req_i.address_index = 6'h28;
    tick(); // IDLE -> WAIT_TAG
    cc_req_i.data_req      = 1'b0;
    cc_req_i.tag_valid     = 1'b1;
    cc_req_i.address_tag   = 50'h0200_0444;
    cc_hit_way_i           = 2'b00; // MISS!
    tick(); // WAIT_TAG -> WAIT_REFILL_GNT
    cc_req_i.tag_valid     = 1'b0;
    cc_miss_gnt_i          = 1'b1;
    tick(); // WAIT_REFILL_GNT -> WAIT_CRITICAL_WORD
    cc_miss_gnt_i          = 1'b0;

    // In WAIT_CRITICAL_WORD, assert data_req=1 and flush_i=1 while critical_word_valid_i=0:
    cc_req_i.data_req      = 1'b1;
    cc_req_i.data_we       = 1'b1; // Pending Store
    cc_flush               = 1'b1;
    #1;
    if (cc_sram_req_o !== 2'b00) begin
      $fatal(1, "TEST 3c: WAIT_CRITICAL_WORD asserted speculative req_o=%b during flush_i!", cc_sram_req_o);
    end
    // Now deassert flush_i and assert critical_word_valid_i=1 with pending Store (data_req=1, data_we=1):
    cc_flush               = 1'b0;
    cc_crit_valid_i        = 1'b1;
    cc_crit_word_i         = 64'h1122_3344_5566_7788;
    #1;
    if (cc_req_o.data_rvalid !== 1'b1 || cc_req_o.data_rdata !== 64'h1122_3344_5566_7788) begin
      $fatal(1, "TEST 3c: WAIT_CRITICAL_WORD failed to return critical word!");
    end
    if (cc_req_o.data_gnt !== 1'b0) begin
      $fatal(1, "TEST 3c: Pipelined Store in WAIT_CRITICAL_WORD erroneously received premature data_gnt=1!");
    end
    tick();
    cc_crit_valid_i   = 1'b0;
    cc_req_i.data_req = 1'b0;
    tick();

    //RANDOM_TESTS_HERE

    $display("PASS std_nbdcache subsystem tests");
    $finish;
  end
endmodule
