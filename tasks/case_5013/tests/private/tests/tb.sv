`timescale 1ns/1ps
module tb;
  import ariane_pkg::*;

  logic        clk_i = 0;
  logic        rst_ni = 0;
  logic        flush_i = 0;
  logic        stall_st_pending_i = 0;
  logic        no_st_pending_o;
  logic [ 3:0] fu_i = 0;
  logic [ 7:0] op_i = 0;
  logic [31:0] opa_i = 0;
  logic [31:0] opb_i = 0;
  logic [31:0] imm_i = 0;
  logic [ 1:0] tid_i = 0;
  logic        lsu_valid_i = 0;
  logic        spec_load_i = 0;
  logic        lsu_ready_o;
  logic [ 1:0] load_trans_id_o;
  logic [31:0] load_result_o;
  logic        load_valid_o;
  logic        load_ex_valid_o;
  logic [31:0] load_ex_cause_o;
  logic [ 1:0] store_trans_id_o;
  logic [31:0] store_result_o;
  logic        store_valid_o;
  logic        store_ex_valid_o;
  logic [31:0] store_ex_cause_o;
  logic        commit_i = 0;
  logic        commit_ready_o;
  logic [ 1:0] commit_tran_id_i = 0;
  logic        br_res_valid_i = 0;
  logic        br_res_mispredict_i = 0;
  logic        mbe_i = 0;
  logic        ld_gnt_i = 0;
  logic        ld_rvalid_i = 0;
  logic [ 1:0] ld_rid_i = 0;
  logic [31:0] ld_rdata_i = 0;
  logic        ld_err_i = 0;
  logic        ld_req_o;
  logic [ 9:0] ld_idx_o;
  logic [21:0] ld_tag_o;
  logic [ 3:0] ld_be_o;
  logic [ 1:0] ld_size_o;
  logic [ 1:0] ld_id_o;
  logic        ld_kill_o;
  logic        ld_tag_vld_o;
  logic        st_gnt_i = 0;
  logic        st_rvalid_i = 0;
  logic        st_req_o;
  logic [ 9:0] st_idx_o;
  logic [21:0] st_tag_o;
  logic [31:0] st_wdata_o;
  logic [ 3:0] st_be_o;
  logic [ 1:0] st_size_o;
  logic [ 7:0] st_cbo_o;
  logic        dcache_wbuffer_empty_i = 1;
  logic        dcache_wbuffer_not_ni_i = 1;

  always #5 clk_i = ~clk_i;

  lsu_subsys_top dut (.*);

  int seed = 101;
  int fail_cnt = 0;
  logic [1:0] saved_ld_id;

  task automatic fail(input string msg);
    $display("FAIL: %s (t=%0t)", msg, $time);
    fail_cnt++;
  endtask

  task automatic step();
    @(posedge clk_i);
    #1;
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    rst_ni = 0;
    flush_i = 0;
    ld_gnt_i = 1;
    st_gnt_i = 1;
    dcache_wbuffer_empty_i = 1;
    dcache_wbuffer_not_ni_i = 1;

    repeat (4) step();
    rst_ni = 1;
    step();

    // -----------------------------------------------------------------------
    // T1: Speculative Load to Non-Idempotent Region (`0x1000_0020`, `paddr_ni = 1`)
    // -----------------------------------------------------------------------
    fu_i             = LOAD;
    op_i             = LW;
    opa_i            = 32'h1000_0000;
    imm_i            = 32'h0000_0020;
    tid_i            = 2'd2;
    commit_tran_id_i = 2'd2;
    spec_load_i      = 1'b1;
    lsu_valid_i      = 1'b1;
    br_res_valid_i   = 1'b0;
    #1;
    if (ld_req_o !== 1'b0) fail("T1a: speculative load to NI address 0x1000_0020 fired ld_req_o in IDLE before branch resolution");
    step(); // now queued in lsu_bypass, load_unit in WAIT_SPEC_LOAD
    lsu_valid_i = 1'b0;
    spec_load_i = 1'b0;
    if (lsu_ready_o !== 1'b0 || ld_req_o !== 1'b0) begin
      fail($sformatf("T1b: wait cycle 0 in WAIT_SPEC_LOAD rdy=%b ld_req=%b", lsu_ready_o, ld_req_o));
    end
    step(); // 2nd cycle with br_res_valid_i = 0: must STILL wait in WAIT_SPEC_LOAD
    if (ld_req_o !== 1'b0 || load_valid_o !== 1'b0) begin
      fail($sformatf("T1c: speculative NI load escaped WAIT_SPEC_LOAD before branch resolved (ld_req=%b ld_vld=%b)", ld_req_o, load_valid_o));
    end
    // Resolve branch as NOT mispredicted (`br_res_valid_i = 1`, `br_res_mispredict_i = 0`)
    br_res_valid_i      = 1'b1;
    br_res_mispredict_i = 1'b0;
    step(); // lsu_bypass clears is_speculative_load in mem_q, load_unit returns to IDLE
    br_res_valid_i = 1'b0;
    #1;
    saved_ld_id = ld_id_o;
    if (ld_req_o !== 1'b1 || ld_idx_o !== 10'h020) begin
      fail($sformatf("T1d: resolved non-mispredicted NI load did not issue ld_req_o (req=%b idx=%h)", ld_req_o, ld_idx_o));
    end
    step(); // SEND_TAG cycle
    if (ld_tag_vld_o !== 1'b1 || ld_tag_o !== 22'h040000 || lsu_ready_o !== 1'b1) begin
      fail($sformatf("T1e: SEND_TAG mismatch tag_vld=%b tag=%h rdy=%b", ld_tag_vld_o, ld_tag_o, lsu_ready_o));
    end
    ld_rvalid_i = 1'b1;
    ld_rid_i    = saved_ld_id;
    ld_rdata_i  = 32'hDEAD_BEEF;
    #1;
    if (load_valid_o !== 1'b1 || load_trans_id_o !== 2'd2 || load_result_o !== 32'hDEAD_BEEF) begin
      fail($sformatf("T1f: NI load retirement mismatch vld=%b tid=%0d res=%h", load_valid_o, load_trans_id_o, load_result_o));
    end
    step();
    ld_rvalid_i = 1'b0;

    // -----------------------------------------------------------------------
    // T2: Speculative Load to Non-Idempotent Region (`0x1000_0040`) resolved as MISPREDICTED:
    // -----------------------------------------------------------------------
    fu_i             = LOAD;
    op_i             = LW;
    opa_i            = 32'h1000_0000;
    imm_i            = 32'h0000_0040;
    tid_i            = 2'd3;
    commit_tran_id_i = 2'd3;
    spec_load_i      = 1'b1;
    lsu_valid_i      = 1'b1;
    step(); // enters WAIT_SPEC_LOAD
    lsu_valid_i = 1'b0;
    spec_load_i = 1'b0;
    br_res_valid_i      = 1'b1;
    br_res_mispredict_i = 1'b1;
    #1;
    if (ld_req_o !== 1'b0 || load_valid_o !== 1'b1 || load_trans_id_o !== 2'd3 || load_ex_valid_o !== 1'b0) begin
      fail($sformatf("T2a: mispredicted speculative NI load retirement mismatch req=%b vld=%b tid=%0d ex=%b",
        ld_req_o, load_valid_o, load_trans_id_o, load_ex_valid_o));
    end
    step();
    br_res_valid_i      = 1'b0;
    br_res_mispredict_i = 1'b0;
    if (lsu_ready_o !== 1'b1) fail("T2b: lsu_ready_o did not recover to 1 after popping mispredicted speculative load");

    // -----------------------------------------------------------------------
    // T3: 32-bit Word-Granular Store-Buffer Page-Offset Hazard Detection (`[11:2]`):
    // -----------------------------------------------------------------------
    st_gnt_i    = 1'b0; // hold store in commit queue once committed
    fu_i        = STORE;
    op_i        = SW;
    opa_i       = 32'h8000_0100;
    opb_i       = 32'hCAFE_1234;
    imm_i       = 32'h0;
    tid_i       = 2'd1;
    lsu_valid_i = 1'b1;
    step(); // store enters VALID_STORE
    lsu_valid_i = 1'b0;
    if (store_valid_o !== 1'b1 || store_trans_id_o !== 2'd1) fail("T3a: store_valid_o not asserted in VALID_STORE");
    step(); // store is now in speculative_queue_q at 0x8000_0100!
    // Issue LW to 0x8000_0104 while store is in speculative_queue_q:
    fu_i        = LOAD;
    op_i        = LW;
    opa_i       = 32'h8000_0104;
    imm_i       = 32'h0;
    tid_i       = 2'd2;
    lsu_valid_i = 1'b1;
    #1;
    saved_ld_id = ld_id_o;
    if (ld_req_o !== 1'b1) fail("T3b_spec: LW to 0x8000_0104 false-stalled on speculative_queue_q store at 0x8000_0100");
    step(); // LW 0x8000_0104 in SEND_TAG
    lsu_valid_i = 1'b0;
    ld_rvalid_i = 1'b1;
    ld_rid_i    = saved_ld_id;
    ld_rdata_i  = 32'h1122_3344;
    step();
    ld_rvalid_i = 1'b0;

    // Commit the pending store at 0x8000_0100 into commit_queue_q (st_gnt_i = 0 keeps it in commit_queue_q)
    commit_i = 1'b1;
    step();
    commit_i = 1'b0;
    if (st_req_o !== 1'b1 || st_idx_o !== 10'h100 || st_wdata_o !== 32'hCAFE_1234) begin
      fail("T3c: committed store not requesting on st_req_o");
    end
    // Issue LW to 0x8000_0104 while store is in commit_queue_q:
    fu_i        = LOAD;
    op_i        = LW;
    opa_i       = 32'h8000_0104;
    imm_i       = 32'h0;
    tid_i       = 2'd2;
    lsu_valid_i = 1'b1;
    #1;
    saved_ld_id = ld_id_o;
    if (ld_req_o !== 1'b1) fail("T3b_commit: LW to 0x8000_0104 false-stalled on commit_queue_q store at 0x8000_0100");
    step();
    lsu_valid_i = 1'b0;
    ld_rvalid_i = 1'b1;
    ld_rid_i    = saved_ld_id;
    ld_rdata_i  = 32'h1122_3344;
    step();
    ld_rvalid_i = 1'b0;

    // Issue signed LH to 0x8000_0102 (`[11:2] = 10'h040`, overlaps committed store at 0x8000_0100!):
    fu_i        = LOAD;
    op_i        = LH;
    opa_i       = 32'h8000_0102;
    imm_i       = 32'h0;
    tid_i       = 2'd3;
    lsu_valid_i = 1'b1;
    #1;
    if (ld_req_o !== 1'b0) fail("T3d: LH to 0x8000_0102 failed to stall on overlapping store at 0x8000_0100");
    step(); // LH enters WAIT_PAGE_OFFSET
    lsu_valid_i = 1'b0;
    // Grant the store so commit_queue_q drains!
    st_gnt_i = 1'b1;
    step(); // store drains from commit_queue_q (commit_queue_q[0].valid becomes 0)
    st_gnt_i = 1'b0;
    step(); // load_unit sees !page_offset_matches_i and transitions WAIT_PAGE_OFFSET -> WAIT_GNT
    #1;
    saved_ld_id = ld_id_o;
    if (ld_req_o !== 1'b1) fail("T3e: load_unit did not issue ld_req_o in WAIT_GNT after store drained");
    step(); // SEND_TAG
    ld_rvalid_i = 1'b1;
    ld_rid_i    = saved_ld_id;
    ld_rdata_i  = 32'h8005_1234; // halfword at offset +2 is 16'h8005 -> sign-extended 32'hFFFF_8005
    #1;
    if (load_valid_o !== 1'b1 || load_result_o !== 32'hFFFF_8005) begin
      fail($sformatf("T3f: signed LH at offset +2 mismatch vld=%b res=%h (exp ffff8005)", load_valid_o, load_result_o));
    end
    step();
    ld_rvalid_i = 1'b0;

    // -----------------------------------------------------------------------
    // T4: CBO Operation (`CBO_FLUSH`) Commit-Queue Two-Phase Handshake
    // -----------------------------------------------------------------------
    st_gnt_i    = 1'b0;
    st_rvalid_i = 1'b0;
    fu_i        = STORE;
    op_i        = CBO_FLUSH;
    opa_i       = 32'h8000_0200;
    imm_i       = 32'h0;
    tid_i       = 2'd0;
    lsu_valid_i = 1'b1;
    step(); // VALID_STORE (push to speculative_queue_q at next posedge)
    lsu_valid_i = 1'b0;
    step(); // CBO_FLUSH is now in speculative_queue_q
    commit_i    = 1'b1;
    step(); // CBO_FLUSH is now in commit_queue_q
    commit_i    = 1'b0;
    if (st_req_o !== 1'b1 || no_st_pending_o !== 1'b0) fail("T4a: CBO_FLUSH not requesting in commit_queue");
    // Grant CBO_FLUSH while st_rvalid_i happens to be 1 on the grant cycle!
    st_gnt_i    = 1'b1;
    st_rvalid_i = 1'b1;
    step();
    st_gnt_i    = 1'b0;
    st_rvalid_i = 1'b0;
    #1;
    if (no_st_pending_o !== 1'b0 || st_req_o !== 1'b0) begin
      fail($sformatf("T4b: CBO_FLUSH evicted prematurely on grant cycle (no_st_pending=%b st_req=%b)", no_st_pending_o, st_req_o));
    end
    step(); // still waiting for CBO rvalid
    if (no_st_pending_o !== 1'b0) fail("T4c: CBO_FLUSH did not wait for its completion rvalid");
    st_rvalid_i = 1'b1;
    step();
    st_rvalid_i = 1'b0;
    if (no_st_pending_o !== 1'b1) fail("T4d: CBO_FLUSH did not retire after completion rvalid");

    // -----------------------------------------------------------------------
    // T5: Pipeline `flush_i` with In-Flight Load in `ldbuf_q` and Speculative Store
    // -----------------------------------------------------------------------
    fu_i        = LOAD;
    op_i        = LW;
    opa_i       = 32'h8000_0300;
    imm_i       = 32'h0;
    tid_i       = 2'd1;
    lsu_valid_i = 1'b1;
    #1;
    saved_ld_id = ld_id_o;
    step(); // load granted into ldbuf_q[saved_ld_id], now in SEND_TAG
    fu_i        = STORE;
    op_i        = SW;
    opa_i       = 32'h8000_0300;
    opb_i       = 32'h5566_7788;
    tid_i       = 2'd2;
    lsu_valid_i = 1'b1;
    step(); // store in VALID_STORE -> enters speculative_queue_q at next posedge
    lsu_valid_i = 1'b0;
    step(); // store is now in speculative_queue_q
    flush_i     = 1'b1;
    step(); // load_unit enters WAIT_FLUSH
    flush_i     = 1'b0;
    step(); // load_unit returns from WAIT_FLUSH to IDLE (kill_req is now 0, so only ldbuf_flushed_q suppresses rvalid!)
    // Return ld_rvalid_i = 1 for the flushed load in ldbuf_q[saved_ld_id]: load_valid_o MUST be 0!
    ld_rvalid_i = 1'b1;
    ld_rid_i    = saved_ld_id;
    ld_rdata_i  = 32'hAAAA_BBBB;
    #1;
    if (load_valid_o !== 1'b0) fail("T5a: flushed load in ldbuf_q produced phantom load_valid_o writeback");
    step();
    ld_rvalid_i = 1'b0;
    // New load to 0x8000_0300 must NOT stall on the flushed speculative store!
    fu_i        = LOAD;
    op_i        = LW;
    opa_i       = 32'h8000_0300;
    tid_i       = 2'd0;
    lsu_valid_i = 1'b1;
    #1;
    saved_ld_id = ld_id_o;
    if (ld_req_o !== 1'b1) fail("T5b: flushed speculative store was not evicted from store_buffer");
    step(); // SEND_TAG for 0x8000_0300
    lsu_valid_i = 1'b0;
    ld_rvalid_i = 1'b1;
    ld_rid_i    = saved_ld_id;
    ld_rdata_i  = 32'h1234_5678;
    step();
    ld_rvalid_i = 1'b0;

    // -----------------------------------------------------------------------
    // T6: SEND_TAG Exception Retirement & Killed Load-Buffer Slot Reclamation
    // -----------------------------------------------------------------------
    // 1st misaligned LW (0x8000_0402, tid=1) with ld_rvalid_i = 0:
    fu_i        = LOAD;
    op_i        = LW;
    opa_i       = 32'h8000_0402;
    imm_i       = 32'h0;
    tid_i       = 2'd1;
    lsu_valid_i = 1'b1;
    step(); // granted in IDLE -> enters SEND_TAG, pmp_exception.valid latches 1
    lsu_valid_i = 1'b0;
    #1;
    if (ld_kill_o !== 1'b1 || load_valid_o !== 1'b1 || load_ex_valid_o !== 1'b1 || load_trans_id_o !== 2'd1) begin
      fail($sformatf("T6a: 1st misaligned LW in SEND_TAG did not retire exception (kill=%b vld=%b ex=%b tid=%0d)",
        ld_kill_o, load_valid_o, load_ex_valid_o, load_trans_id_o));
    end
    step(); // returns to IDLE and reclaims ldbuf_valid_q[ldbuf_last_id_q]

    // 2nd misaligned LW (0x8000_0406, tid=2) with ld_rvalid_i = 0:
    fu_i        = LOAD;
    op_i        = LW;
    opa_i       = 32'h8000_0406;
    imm_i       = 32'h0;
    tid_i       = 2'd2;
    lsu_valid_i = 1'b1;
    step(); // enters SEND_TAG
    lsu_valid_i = 1'b0;
    #1;
    if (ld_kill_o !== 1'b1 || load_valid_o !== 1'b1 || load_ex_valid_o !== 1'b1 || load_trans_id_o !== 2'd2) begin
      fail($sformatf("T6b: 2nd misaligned LW in SEND_TAG did not retire exception (kill=%b vld=%b ex=%b tid=%0d)",
        ld_kill_o, load_valid_o, load_ex_valid_o, load_trans_id_o));
    end
    step(); // returns to IDLE and reclaims ldbuf_valid_q[ldbuf_last_id_q]

    // 3rd aligned LW (0x8000_0400, tid=3): must NOT deadlock on ldbuf_full!
    fu_i        = LOAD;
    op_i        = LW;
    opa_i       = 32'h8000_0400;
    imm_i       = 32'h0;
    tid_i       = 2'd3;
    lsu_valid_i = 1'b1;
    #1;
    saved_ld_id = ld_id_o;
    if (ld_req_o !== 1'b1) begin
      fail("T6c: aligned LW deadlocked after two killed misaligned loads (ldbuf_valid_q leaked)");
    end
    step(); // SEND_TAG
    lsu_valid_i = 1'b0;
    ld_rvalid_i = 1'b1;
    ld_rid_i    = saved_ld_id;
    ld_rdata_i  = 32'hCAFE_BABE;
    #1;
    if (load_valid_o !== 1'b1 || load_ex_valid_o !== 1'b0 || load_trans_id_o !== 2'd3 || load_result_o !== 32'hCAFE_BABE) begin
      fail($sformatf("T6d: post-exception aligned LW retirement mismatch vld=%b ex=%b tid=%0d res=%h",
        load_valid_o, load_ex_valid_o, load_trans_id_o, load_result_o));
    end
    step();
    ld_rvalid_i = 1'b0;

    if (fail_cnt == 0) begin
      $display("PASS: all LSU subsystem checks passed (seed=%0d)", seed);
      $finish;
    end else begin
      $display("FAIL: %0d checks failed", fail_cnt);
      $fatal(1, "tb failed");
    end
  end
endmodule
