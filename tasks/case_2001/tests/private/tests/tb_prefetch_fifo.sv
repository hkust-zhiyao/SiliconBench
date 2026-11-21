`timescale 1ns/1ps

module tb_prefetch_fifo #(
  parameter int unsigned NUM_REQS = 2,
  parameter bit          ResetAll = 1'b0
);

  logic        clk_i;
  logic        rst_ni;
  logic        req_i;
  logic        branch_i;
  logic [31:0] addr_i;
  logic        ready_i;
  logic        valid_o;
  logic [31:0] rdata_o;
  logic [31:0] addr_o;
  logic        err_o;
  logic        err_plus2_o;
  logic        cheriot_force_uc_i;
  logic        instr_req_o;
  logic        instr_gnt_i;
  logic [31:0] instr_addr_o;
  logic [31:0] instr_rdata_i;
  logic        instr_err_i;
  logic        instr_rvalid_i;
  logic        busy_o;

  ibex_prefetch_buffer #(
    .NUM_REQS (NUM_REQS),
    .ResetAll (ResetAll)
  ) dut (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .req_i              (req_i),
    .branch_i           (branch_i),
    .addr_i             (addr_i),
    .ready_i            (ready_i),
    .valid_o            (valid_o),
    .rdata_o            (rdata_o),
    .addr_o             (addr_o),
    .err_o              (err_o),
    .err_plus2_o        (err_plus2_o),
    .cheriot_force_uc_i (cheriot_force_uc_i),
    .instr_req_o        (instr_req_o),
    .instr_gnt_i        (instr_gnt_i),
    .instr_addr_o       (instr_addr_o),
    .instr_rdata_i      (instr_rdata_i),
    .instr_err_i        (instr_err_i),
    .instr_rvalid_i     (instr_rvalid_i),
    .busy_o             (busy_o)
  );

  initial begin
    clk_i = 1'b0;
    forever #5 clk_i = ~clk_i;
  end

  int unsigned error_count = 0;
  int unsigned total_checks = 0;
  int unsigned seed = 101;

  task automatic fail_msg(input string msg);
    begin
      $display("TB_FAIL [t=%0t NUM_REQS=%0d ResetAll=%0d]: %s", $time, NUM_REQS, ResetAll, msg);
      error_count++;
    end
  endtask

  task automatic check_cond(input bit cond, input string msg);
    begin
      total_checks++;
      if (cond !== 1'b1) begin
        fail_msg(msg);
      end
    end
  endtask

  // Protocol & stability tracking across cycles
  bit          prev_ungranted_req;
  logic [31:0] prev_ungranted_addr;
  int unsigned outstanding_cnt;

  always @(negedge clk_i) begin
    if (!rst_ni) begin
      prev_ungranted_req  <= 1'b0;
      prev_ungranted_addr <= 32'h0;
    end else begin
      if (instr_req_o === 1'b1) begin
        total_checks++;
        if (instr_addr_o[1:0] !== 2'b00) begin
          fail_msg($sformatf("instr_addr_o not word-aligned: %h", instr_addr_o));
        end
        if (^instr_addr_o === 1'bx) begin
          fail_msg("instr_addr_o is X while instr_req_o=1");
        end
      end
      if (prev_ungranted_req) begin
        total_checks++;
        if (instr_req_o !== 1'b1) begin
          fail_msg("OBI violation: instr_req_o dropped before instr_gnt_i");
        end
        if (instr_addr_o !== prev_ungranted_addr) begin
          fail_msg($sformatf("OBI violation: instr_addr_o changed while waiting for grant (%h -> %h)",
                             prev_ungranted_addr, instr_addr_o));
        end
      end
      if (valid_o === 1'b1 && err_o === 1'b0) begin
        total_checks++;
        if (err_plus2_o !== 1'b0) begin
          fail_msg("err_plus2_o asserted when err_o is 0");
        end
      end
      if (valid_o === 1'b1 && addr_o[1] === 1'b0) begin
        total_checks++;
        if (err_plus2_o !== 1'b0) begin
          fail_msg("err_plus2_o asserted on word-aligned PC");
        end
      end
      prev_ungranted_req  <= (instr_req_o === 1'b1) && (instr_gnt_i !== 1'b1);
      prev_ungranted_addr <= instr_addr_o;
    end
  end

  // Helper to advance 1 clock cycle and settle combinational outputs
  task automatic step_cycle(
    input bit          in_req,
    input bit          in_branch,
    input logic [31:0] in_addr,
    input bit          in_ready,
    input bit          in_force_uc,
    input bit          in_allow_gnt,
    input bit          in_rvalid,
    input logic [31:0] in_rdata,
    input bit          in_err
  );
    begin
      @(posedge clk_i);
      #1;
      req_i              = in_req;
      branch_i           = in_branch;
      addr_i             = in_addr;
      ready_i            = in_ready;
      cheriot_force_uc_i = in_force_uc;
      instr_rvalid_i     = in_rvalid;
      instr_rdata_i      = in_rdata;
      instr_err_i        = in_rvalid ? in_err : 1'b0;
      instr_gnt_i        = 1'b0;
      #1;
      instr_gnt_i        = in_allow_gnt && (instr_req_o === 1'b1);
      @(negedge clk_i);
    end
  endtask

  task automatic do_reset();
    begin
      rst_ni             = 1'b0;
      req_i              = 1'b0;
      branch_i           = 1'b0;
      addr_i             = 32'h0;
      ready_i            = 1'b0;
      cheriot_force_uc_i = 1'b0;
      instr_gnt_i        = 1'b0;
      instr_rdata_i      = 32'h0;
      instr_err_i        = 1'b0;
      instr_rvalid_i     = 1'b0;
      repeat (3) @(posedge clk_i);
      #1;
      rst_ni = 1'b1;
      @(negedge clk_i);
      check_cond(valid_o === 1'b0, "valid_o must be 0 after reset");
      check_cond(instr_req_o === 1'b0, "instr_req_o must be 0 after reset when req_i=0");
      check_cond(busy_o === 1'b0, "busy_o must be 0 after reset");
    end
  endtask

  // Deterministic instruction word generator:
  // Halfword at haddr:
  // If compressed_mask bit is 1 -> 16-bit compressed instruction (bits [1:0] = 2'b01)
  // Else -> 32-bit uncompressed instruction (bits [1:0] = 2'b11)
  function automatic logic [15:0] make_halfword(input logic [15:0] tag, input bit is_comp);
    if (is_comp) begin
      return {tag[15:2], 2'b01};
    end else begin
      return {tag[15:2], 2'b11};
    end
  endfunction

  initial begin
    void'($value$plusargs("SEED=%d", seed));
    do_reset();

    // =========================================================================
    // PHASE 1: Parameterized NUM_REQS window, busy_o status, and aligned stream
    // =========================================================================
    begin
      logic [31:0] w0, w1, w2;
      w0 = {make_halfword(16'hA002, 1'b0), make_halfword(16'hA000, 1'b0)}; // 32-bit at 0x1000
      w1 = {make_halfword(16'hA006, 1'b1), make_halfword(16'hA004, 1'b1)}; // two 16-bit at 0x1004, 0x1006
      w2 = {make_halfword(16'hA00A, 1'b0), make_halfword(16'hA008, 1'b0)}; // 32-bit at 0x1008

      // Cycle 1: Branch to 0x1000, grant request 0
      step_cycle(1'b1, 1'b1, 32'h0000_1000, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_1000,
                 "Phase 1: req 0 at 0x1000 expected");
      check_cond(busy_o === 1'b1, "Phase 1: busy_o must be 1 when instr_req_o=1");

      // Cycle 2: Sequential request 1 at 0x1004, grant it, no rvalid yet
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_1004,
                 "Phase 1: req 1 at 0x1004 expected");
      check_cond(busy_o === 1'b1, "Phase 1: busy_o must be 1 with outstanding reqs");

      if (NUM_REQS == 2) begin
        // With 2 outstanding requests and NUM_REQS=2, no 3rd request may be issued yet
        step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
        check_cond(instr_req_o === 1'b0,
                   "Phase 1 (NUM_REQS=2): instr_req_o must be 0 when 2 reqs outstanding");
        check_cond(busy_o === 1'b1,
                   "Phase 1 (NUM_REQS=2): busy_o must stay 1 while rdata_outstanding_q != 0");
      end else if (NUM_REQS == 3) begin
        // With NUM_REQS=3, a 3rd request at 0x1008 must be issued and granted!
        step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
        check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_1008,
                   "Phase 1 (NUM_REQS=3): req 2 at 0x1008 expected");
        // Now all 3 slots are full
        step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
        check_cond(instr_req_o === 1'b0,
                   "Phase 1 (NUM_REQS=3): instr_req_o must be 0 when 3 reqs outstanding");
        check_cond(busy_o === 1'b1,
                   "Phase 1 (NUM_REQS=3): busy_o must stay 1 while 3 reqs outstanding");
      end

      // Return rvalid for w0 (0x1000) while ready_i=0 (pushes into FIFO entry 0)
      step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, w0, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_1000 && rdata_o === w0 &&
                 err_o === 1'b0 && err_plus2_o === 1'b0,
                 "Phase 1: w0 at 0x1000 output mismatch");

      // Return rvalid for w1 (0x1004) while ready_i=1 (pops w0 at 0x1000)
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b1, w1, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_1000 && rdata_o === w0,
                 "Phase 1: w0 handshake at 0x1000 mismatch");

      if (NUM_REQS == 3) begin
        // Return rvalid for w2 (0x1008) while ready_i=1 (pops first compressed halfword at 0x1004)
        step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b1, w2, 1'b0);
      end else begin
        // Pop first compressed halfword at 0x1004
        step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      end
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_1004 &&
                 rdata_o[15:0] === w1[15:0] && err_o === 1'b0 && err_plus2_o === 1'b0,
                 "Phase 1: compressed instr at 0x1004 mismatch");

      // Next cycle: upper halfword of w1 at 0x1006 (compressed)
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_1006 &&
                 rdata_o[15:0] === w1[31:16] && err_o === 1'b0 && err_plus2_o === 1'b0,
                 "Phase 1: compressed instr at 0x1006 mismatch");
      check_cond(busy_o === 1'b0,
                 "Phase 1: busy_o must be 0 when req_i=0 and no requests outstanding");
    end

    // =========================================================================
    // PHASE 2: Fault retirement, FIFO forwarding, and Registered Fault Freeze
    // =========================================================================
    begin
      logic [31:0] w_ok;
      w_ok = {make_halfword(16'hB002, 1'b0), make_halfword(16'hB000, 1'b0)};

      // Branch to 0x2000, grant req 0 (0x2000)
      step_cycle(1'b1, 1'b1, 32'h0000_2000, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_2000,
                 "Phase 2: req 0 at 0x2000 expected");

      // Next cycle: req 1 (0x2004) is issued and granted; simultaneously 0x2000 returns ERROR!
      // Because fault_hold_q is registered (no combinational path from instr_rvalid_i/instr_err_i
      // to instr_req_o), req 1 at 0x2004 is still valid on this cycle and gets granted.
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, 32'hDEAD_BEEF, 1'b1);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_2004,
                 "Phase 2: req 1 at 0x2004 should not have combinational rvalid->req path");
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_2000 &&
                 err_o === 1'b1 && err_plus2_o === 1'b0,
                 "Phase 2: error response at 0x2000 must be presented at FIFO output");

      // Now fault_hold_q is 1! Even though only 1 request (0x2004) is outstanding and FIFO has
      // space, NO new sequential request (0x2008) may be initiated on subsequent cycles!
      step_cycle(1'b1, 1'b0, 32'h0, 1'b1, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b0,
                 "Phase 2: new sequential request must be frozen after non-discarded fault");
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_2000 && err_o === 1'b1,
                 "Phase 2: latched error at 0x2000 must remain valid until consumed");

      // Return response for 0x2004 while req_i=1, branch_i=0: still frozen!
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, w_ok, 1'b0);
      check_cond(instr_req_o === 1'b0,
                 "Phase 2: must remain frozen after consuming fault until branch_i");

      // One more cycle before branch_i: still frozen, busy_o must be 0 now
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b0 && busy_o === 1'b0,
                 "Phase 2: no speculative req and busy_o=0 while fault-frozen with 0 outstanding");

      // Now redirect via branch_i=1 to 0x2100: must unfreeze immediately and allow all NUM_REQS slots!
      step_cycle(1'b1, 1'b1, 32'h0000_2100, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_2100,
                 "Phase 2: branch_i must unfreeze and issue 0x2100 immediately");

      for (int unsigned s = 1; s < NUM_REQS; s++) begin
        step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
        check_cond(instr_req_o === 1'b1 && instr_addr_o === (32'h0000_2100 + s * 32'd4),
                   $sformatf("Phase 2: slot %0d must be reusable after earlier fault retirement", s));
      end

      // Drain the NUM_REQS outstanding requests
      for (int unsigned s = 0; s < NUM_REQS; s++) begin
        step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b1, w_ok, 1'b0);
        check_cond(valid_o === 1'b1 && addr_o === (32'h0000_2100 + s * 32'd4) && err_o === 1'b0,
                   $sformatf("Phase 2: post-recovery word %0d mismatch", s));
      end
    end

    // =========================================================================
    // PHASE 3: Branch-discarded error response & Ungranted request stability
    // =========================================================================
    begin
      logic [31:0] w_target;
      w_target = {make_halfword(16'hC002, 1'b0), make_halfword(16'hC000, 1'b0)};

      // Subtest 3A: Issue & grant 0x3000, then branch to 0x3100 BEFORE 0x3000 responds
      step_cycle(1'b1, 1'b1, 32'h0000_3000, 1'b1, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      // Branch to 0x3100 and grant 0x3100
      step_cycle(1'b1, 1'b1, 32'h0000_3100, 1'b1, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_3100,
                 "Phase 3A: branch target 0x3100 request expected");

      // Now old request 0x3000 returns with instr_err_i=1 (discarded by branch!)
      step_cycle(1'b1, 1'b0, 32'h0, 1'b1, 1'b0, 1'b1, 1'b1, 32'hBAD0_3000, 1'b1);
      check_cond(valid_o === 1'b0,
                 "Phase 3A: branch-discarded error response must not assert valid_o");

      // Next cycle: because the error was branch-discarded, fault_hold_q must NOT be set!
      // And 0x3100's normal response must NOT be discarded!
      step_cycle(1'b1, 1'b0, 32'h0, 1'b1, 1'b0, 1'b1, 1'b1, w_target, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_3100 && rdata_o === w_target && err_o === 1'b0,
                 "Phase 3A: post-branch response 0x3100 must be delivered after discarded error");
      check_cond(instr_req_o === 1'b1,
                 "Phase 3A: sequential prefetching must not freeze after a branch-discarded error");

      // Drain remaining in-flight request(s) from 3A
      while (busy_o === 1'b1) begin
        step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b1, 1'b1, w_target, 1'b0);
      end

      // Subtest 3B: Same-cycle branch_i=1 and instr_rvalid_i=1 with instr_err_i=1
      step_cycle(1'b1, 1'b1, 32'h0000_3200, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      // Same cycle: branch to 0x3300 while 0x3200 returns an error
      step_cycle(1'b1, 1'b1, 32'h0000_3300, 1'b0, 1'b0, 1'b1, 1'b1, 32'hBAD0_3200, 1'b1);
      // Next cycle: must NOT be frozen because branch_i was 1 on the error cycle!
      step_cycle(1'b1, 1'b0, 32'h0, 1'b1, 1'b0, 1'b1, 1'b1, w_target, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_3304,
                 "Phase 3B: same-cycle branch_i with error response must not freeze next sequential req");
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_3300 && err_o === 1'b0,
                 "Phase 3B: 0x3300 response must arrive cleanly");
      // Drain 0x3304
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b1, w_target, 1'b0);

      // Subtest 3C: Ungranted valid_req_q stability when an earlier request returns an error
      // Cycle 1: Branch to 0x3400, grant 0x3400
      step_cycle(1'b1, 1'b1, 32'h0000_3400, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      // Cycle 2: DUT requests 0x3404, hold instr_gnt_i=0, and return ERROR for 0x3400!
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, 32'hBAD0_3400, 1'b1);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_3404,
                 "Phase 3C: ungranted 0x3404 asserted on cycle of 0x3400 error");
      // Cycle 3: fault_hold_q is now 1, but 0x3404 was already ungranted in valid_req_q!
      // It MUST stay asserted on instr_req_o with instr_addr_o == 0x3404 until granted!
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_3404,
                 "Phase 3C: valid_req_q must remain stable on instr_req_o until granted");
      // Cycle 4: Now that 0x3404 was granted, no new request (0x3408) may be started!
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, w_target, 1'b0);
      check_cond(instr_req_o === 1'b0,
                 "Phase 3C: after ungranted request is granted, fault_hold_q must block 0x3408");
    end

    // =========================================================================
    // PHASE 4: Unaligned First-Word Fault Immediate Presentation (out_addr_o[1]==1)
    // =========================================================================
    begin
      logic [31:0] w_ok;
      w_ok = {make_halfword(16'hD002, 1'b0), make_halfword(16'hD000, 1'b0)};

      // Subtest 4A: Branch to halfword-aligned 0x4002 (cheriot_force_uc_i=0)
      // Grant 0x4000, then do NOT grant 0x4004 before 0x4000 returns an error!
      step_cycle(1'b1, 1'b1, 32'h0000_4002, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      check_cond(instr_req_o === 1'b1 && instr_addr_o === 32'h0000_4000,
                 "Phase 4A: word-aligned request 0x4000 expected for branch to 0x4002");

      // Return error on 0x4000 (while 0x4004 is NOT yet in the FIFO)
      // Note: rdata has [17:16] == 2'b11, and err == 1 so unaligned_is_compressed == 0.
      // out_valid_o MUST assert immediately on the first word without waiting for 0x4004!
      step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, 32'hFFFF_FFFF, 1'b1);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_4002 &&
                 err_o === 1'b1 && err_plus2_o === 1'b0,
                 "Phase 4A (bypass): unaligned first-word error must assert valid_o=1, err_o=1, err_plus2_o=0 immediately");

      // Next cycle (stored in entry[0], still no second word in entry[1]):
      // Must remain valid_o=1, err_o=1, err_plus2_o=0, and handshake when ready_i=1!
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_4002 &&
                 err_o === 1'b1 && err_plus2_o === 1'b0,
                 "Phase 4A (registered): unaligned first-word error in entry[0] must assert valid_o=1 without entry[1]");

      // Subtest 4B: Unaligned first-word error in entry[0] when entry[1] IS valid with err_q[1]=0
      step_cycle(1'b1, 1'b1, 32'h0000_4102, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      // Grant 0x4104 while returning error for 0x4100 (ready_i=0)
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, 32'hFFFF_FFFF, 1'b1);
      // Return good data for 0x4104 (ready_i=0) so entry[0] (err=1) and incoming 0x4104 (err=0) are tested
      step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, w_ok, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_4102 &&
                 err_o === 1'b1 && err_plus2_o === 1'b0,
                 "Phase 4B (bypass): when entry[0] has err=1 and in_valid_i has err=0 at unaligned PC, err_o=1 and err_plus2_o=0");
      // Next cycle: now both valid_q[0] (err_q[0]=1) and valid_q[1] (err_q[1]=0) are registered in the FIFO!
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_4102 &&
                 err_o === 1'b1 && err_plus2_o === 1'b0,
                 "Phase 4B (registered): when entry[0] has err=1 and entry[1] has err=0 at unaligned PC, err_o=1 and err_plus2_o=0");
    end

    // =========================================================================
    // PHASE 5: Unaligned Compressed vs Uncompressed Second-Word Error Attribution
    // =========================================================================
    begin
      logic [31:0] w_comp_hi, w_uncomp_hi, w_next_ok;
      // Upper halfword [31:16] is compressed (bits [17:16] = 2'b01 != 2'b11)
      w_comp_hi   = {make_halfword(16'h4504, 1'b1), make_halfword(16'h1110, 1'b0)};
      // Upper halfword [31:16] is uncompressed 32-bit lower half (bits [17:16] = 2'b11)
      w_uncomp_hi = {make_halfword(16'hE000, 1'b0), make_halfword(16'h2220, 1'b0)};
      w_next_ok   = {make_halfword(16'hE004, 1'b0), make_halfword(16'hE002, 1'b0)};

      // Subtest 5A: Unaligned compressed instruction in entry[0][31:16] (err_q[0]=0)
      // followed by faulted word in entry[1] (err_q[1]=1).
      step_cycle(1'b1, 1'b1, 32'h0000_5002, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      // Grant 0x5004 and return 0x5000 (w_comp_hi, err=0) with ready_i=0
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, w_comp_hi, 1'b0);
      // Return 0x5004 with err=1 while ready_i=0 -> now entry[0] has err=0 (compressed) and entry[1] has err=1!
      step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, 32'hDEAD_5004, 1'b1);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5002 &&
                 rdata_o[15:0] === w_comp_hi[31:16] &&
                 err_o === 1'b0 && err_plus2_o === 1'b0,
                 "Phase 5A: unaligned compressed instr with fault in entry[1] must have err_o=0 AND err_plus2_o=0");

      // Now consume the compressed instruction at 0x5002 (ready_i=1)
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      // Next cycle: PC must advance by +2 to 0x5004 (aligned), presenting the faulted word 0x5004!
      step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5004 &&
                 err_o === 1'b1 && err_plus2_o === 1'b0,
                 "Phase 5A: after popping compressed instr at 0x5002, aligned fault at 0x5004 must have err_o=1, err_plus2_o=0");

      // Subtest 5B: Same as 5A but with second word arriving on bypass (valid_q[0]=1, valid_q[1]=0, in_valid_i=1, in_err_i=1)
      step_cycle(1'b1, 1'b1, 32'h0000_5102, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      // Grant 0x5104 and return 0x5100 (w_comp_hi, err=0) with ready_i=0
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, w_comp_hi, 1'b0);
      // On the cycle 0x5104 arrives on in_valid_i=1 with in_err_i=1, check bypass err_plus2_o!
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b1, 32'hDEAD_5104, 1'b1);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5102 &&
                 rdata_o[15:0] === w_comp_hi[31:16] &&
                 err_o === 1'b0 && err_plus2_o === 1'b0,
                 "Phase 5B: unaligned compressed instr with bypass fault on in_err_i must have err_o=0 AND err_plus2_o=0");

      // Subtest 5C: Unaligned 32-bit uncompressed instruction spanning 0x5202..0x5205
      // where first word (0x5200) has err=0 and second word (0x5204) has err=1 -> err_o=1, err_plus2_o=1!
      step_cycle(1'b1, 1'b1, 32'h0000_5202, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
      // Grant 0x5204 and return 0x5200 (w_uncomp_hi, err=0)
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, w_uncomp_hi, 1'b0);
      check_cond(valid_o === 1'b0,
                 "Phase 5C: unaligned 32-bit uncompressed instr without error in word 0 must wait for word 1");
      // Now 0x5204 returns with err=1 (bypass check)
      step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, 32'hDEAD_5204, 1'b1);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5202 &&
                 err_o === 1'b1 && err_plus2_o === 1'b1,
                 "Phase 5C (bypass): second-half fault on unaligned 32-bit instr must set err_o=1 and err_plus2_o=1");
      // Next cycle (registered in entry[1]): still err_o=1 and err_plus2_o=1
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5202 &&
                 err_o === 1'b1 && err_plus2_o === 1'b1,
                 "Phase 5C (registered): second-half fault on unaligned 32-bit instr must set err_o=1 and err_plus2_o=1");

      // Subtest 5D: cheriot_force_uc_i=1 on an unaligned 32-bit opcode (w_uncomp_hi) followed by faulted word
      step_cycle(1'b1, 1'b1, 32'h0000_5302, 1'b0, 1'b1, 1'b1, 1'b0, 32'h0, 1'b0);
      step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b1, 1'b1, 1'b1, w_uncomp_hi, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5302 &&
                 rdata_o[15:0] === w_uncomp_hi[31:16] &&
                 err_o === 1'b0 && err_plus2_o === 1'b0,
                 "Phase 5D: cheriot_force_uc_i=1 must make unaligned instr immediately valid without word 1");
      // Return faulted 0x5304 while cheriot_force_uc_i=1 and consume 0x5302
      step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b1, 1'b0, 1'b1, 32'hDEAD_5304, 1'b1);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5302 &&
                 err_o === 1'b0 && err_plus2_o === 1'b0,
                 "Phase 5D: cheriot_force_uc_i=1 must suppress err_o and err_plus2_o from word 1");
      // Next cycle: PC must have incremented by +2 to 0x5304!
      step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
      check_cond(valid_o === 1'b1 && addr_o === 32'h0000_5304 &&
                 err_o === 1'b1 && err_plus2_o === 1'b0,
                 "Phase 5D: after cheriot_force_uc_i=1 pop at 0x5302, PC must be 0x5304 with err_o=1");
    end

    // =========================================================================
    // PHASE 6: Seed-driven Randomized Multi-Transaction Stress Test
    // =========================================================================
    begin
      int unsigned rng;
      logic [31:0] base_pc;
      logic [31:0] wA, wB, wC;
      bit          c0, c1, c2, c3;
      int unsigned gnt_delay, rvalid_delay;
      rng = seed ^ (NUM_REQS * 32'h1357_9BDF) ^ (ResetAll ? 32'hA5A5_5A5A : 32'h0);

      for (int unsigned iter = 0; iter < 24; iter++) begin
        rng          = (rng * 32'd1664525) + 32'd1013904223;
        base_pc      = {16'h0008, rng[15:2], 2'b00};
        c0           = rng[0];
        c1           = rng[1];
        c2           = rng[2];
        c3           = rng[3];
        gnt_delay    = (rng >> 4) & 2'd3;
        rvalid_delay = ((rng >> 6) & 2'd3) + 1;

        wA = {make_halfword(base_pc[15:0] + 16'd2, c1), make_halfword(base_pc[15:0], c0)};
        wB = {make_halfword(base_pc[15:0] + 16'd6, c3), make_halfword(base_pc[15:0] + 16'd4, c2)};
        wC = {make_halfword(base_pc[15:0] + 16'd10, 1'b0), make_halfword(base_pc[15:0] + 16'd8, 1'b0)};

        if (iter[0]) begin
          // Unaligned branch + 32-bit/16-bit sequence + injected fault on 2nd word
          step_cycle(1'b1, 1'b1, base_pc | 32'h2, 1'b0, 1'b0, (gnt_delay == 0), 1'b0, 32'h0, 1'b0);
          if (gnt_delay > 0) begin
            for (int unsigned d = 1; d < gnt_delay; d++) begin
              step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
            end
            step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
          end
          // Grant second request (base_pc + 4), then deassert req_i while draining the 2 responses
          step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
          for (int unsigned d = 0; d < rvalid_delay; d++) begin
            step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
          end
          // Return wA (no error) and then wB (with error if iter[1], else no error)
          step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, wA, 1'b0);
          step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, wB, iter[1]);

          if (c1) begin
            // Upper halfword of wA at base_pc+2 is compressed (16-bit)
            check_cond(valid_o === 1'b1 && addr_o === (base_pc | 32'h2) &&
                       rdata_o[15:0] === wA[31:16] &&
                       err_o === 1'b0 && err_plus2_o === 1'b0,
                       "Phase 6: unaligned compressed instr mismatch");
            // Pop it
            step_cycle(1'b0, 1'b0, 32'h0, 1'b1, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
            // Next instruction is at base_pc + 4
            step_cycle(1'b0, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
            check_cond(valid_o === 1'b1 && addr_o === (base_pc + 32'd4) &&
                       err_o === iter[1] && err_plus2_o === 1'b0,
                       "Phase 6: aligned instr at base_pc+4 after compressed unaligned mismatch");
          end else begin
            // Upper halfword of wA at base_pc+2 is uncompressed (32-bit spanning wA[31:16] and wB[15:0])
            check_cond(valid_o === 1'b1 && addr_o === (base_pc | 32'h2) &&
                       err_o === iter[1] && err_plus2_o === iter[1],
                       "Phase 6: unaligned 32-bit instr error attribution mismatch");
            if (!iter[1]) begin
              check_cond(rdata_o === {wB[15:0], wA[31:16]},
                         "Phase 6: unaligned 32-bit instr rdata mismatch");
            end
          end
        end else begin
          // Aligned branch + first-word error freeze test
          step_cycle(1'b1, 1'b1, base_pc, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
          step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b0, 1'b1, wA, 1'b1);
          check_cond(valid_o === 1'b1 && addr_o === base_pc && err_o === 1'b1 && err_plus2_o === 1'b0,
                     "Phase 6: aligned error delivery mismatch");
          // Grant the already-asserted request at base_pc+4
          step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b0, 32'h0, 1'b0);
          // Now fault_hold_q must freeze any further request (base_pc+8)
          step_cycle(1'b1, 1'b0, 32'h0, 1'b0, 1'b0, 1'b1, 1'b1, wB, 1'b0);
          check_cond(instr_req_o === 1'b0,
                     "Phase 6: post-fault freeze failed in stress loop");
        end
      end
    end

    if (error_count == 0 && total_checks >= 100) begin
      $display("TB_PASS [NUM_REQS=%0d ResetAll=%0d seed=%0d checks=%0d]",
               NUM_REQS, ResetAll, seed, total_checks);
      $finish(0);
    end else begin
      $display("TB_FAIL_SUMMARY [NUM_REQS=%0d ResetAll=%0d seed=%0d errors=%0d checks=%0d]",
               NUM_REQS, ResetAll, seed, error_count, total_checks);
      $finish(1);
    end
  end

endmodule
