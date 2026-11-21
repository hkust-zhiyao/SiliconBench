// Trusted private testbench for case_3001: cv32e40p_if_stage subsystem
`timescale 1ns / 1ps

module tb #(
    parameter int SEED = 101
);
  import cv32e40p_pkg::*;

  logic        clk;
  logic        rst_n;

  logic [23:0] m_trap_base_addr_i;
  logic [23:0] u_trap_base_addr_i;
  logic [ 1:0] trap_addr_mux_i;
  logic [31:0] boot_addr_i;
  logic [31:0] dm_exception_addr_i;
  logic [31:0] dm_halt_addr_i;

  logic        req_i;

  logic        instr_req_o;
  logic [31:0] instr_addr_o;
  logic        instr_gnt_i;
  logic        instr_rvalid_i;
  logic [31:0] instr_rdata_i;
  logic        instr_err_i;
  logic        instr_err_pmp_i;

  logic        instr_valid_id_o;
  logic [31:0] instr_rdata_id_o;
  logic        is_compressed_id_o;
  logic        illegal_c_insn_id_o;
  logic [31:0] pc_if_o;
  logic [31:0] pc_id_o;
  logic        is_fetch_failed_o;

  logic        clear_instr_valid_i;
  logic        pc_set_i;
  logic [31:0] mepc_i;
  logic [31:0] uepc_i;
  logic [31:0] depc_i;

  logic [3:0]  pc_mux_i;
  logic [2:0]  exc_pc_mux_i;
  logic [4:0]  m_exc_vec_pc_mux_i;
  logic [4:0]  u_exc_vec_pc_mux_i;
  logic        csr_mtvec_init_o;

  logic [31:0] jump_target_id_i;
  logic [31:0] jump_target_ex_i;

  logic        hwlp_jump_i;
  logic [31:0] hwlp_target_i;

  logic        halt_if_i;
  logic        id_ready_i;

  logic        if_busy_o;
  logic        perf_imiss_o;

  cv32e40p_if_stage #(
      .COREV_PULP (1),
      .PULP_OBI   (0),
      .PULP_SECURE(1),
      .FPU        (0),
      .ZFINX      (0)
  ) dut (
      .clk                (clk),
      .rst_n              (rst_n),
      .m_trap_base_addr_i (m_trap_base_addr_i),
      .u_trap_base_addr_i (u_trap_base_addr_i),
      .trap_addr_mux_i    (trap_addr_mux_i),
      .boot_addr_i        (boot_addr_i),
      .dm_exception_addr_i(dm_exception_addr_i),
      .dm_halt_addr_i     (dm_halt_addr_i),
      .req_i              (req_i),
      .instr_req_o        (instr_req_o),
      .instr_addr_o       (instr_addr_o),
      .instr_gnt_i        (instr_gnt_i),
      .instr_rvalid_i     (instr_rvalid_i),
      .instr_rdata_i      (instr_rdata_i),
      .instr_err_i        (instr_err_i),
      .instr_err_pmp_i    (instr_err_pmp_i),
      .instr_valid_id_o   (instr_valid_id_o),
      .instr_rdata_id_o   (instr_rdata_id_o),
      .is_compressed_id_o (is_compressed_id_o),
      .illegal_c_insn_id_o (illegal_c_insn_id_o),
      .pc_if_o            (pc_if_o),
      .pc_id_o            (pc_id_o),
      .is_fetch_failed_o  (is_fetch_failed_o),
      .clear_instr_valid_i(clear_instr_valid_i),
      .pc_set_i           (pc_set_i),
      .mepc_i             (mepc_i),
      .uepc_i             (uepc_i),
      .depc_i             (depc_i),
      .pc_mux_i           (pc_mux_i),
      .exc_pc_mux_i       (exc_pc_mux_i),
      .m_exc_vec_pc_mux_i (m_exc_vec_pc_mux_i),
      .u_exc_vec_pc_mux_i (u_exc_vec_pc_mux_i),
      .csr_mtvec_init_o   (csr_mtvec_init_o),
      .jump_target_id_i   (jump_target_id_i),
      .jump_target_ex_i   (jump_target_ex_i),
      .hwlp_jump_i        (hwlp_jump_i),
      .hwlp_target_i      (hwlp_target_i),
      .halt_if_i          (halt_if_i),
      .id_ready_i         (id_ready_i),
      .if_busy_o          (if_busy_o),
      .perf_imiss_o       (perf_imiss_o)
  );

  // Clock generator
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // OBI protocol & X-check monitor
  logic        obi_pending_q;
  logic [31:0] obi_addr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      obi_pending_q <= 1'b0;
      obi_addr_q    <= 32'h0;
    end else begin
      if ($isunknown(instr_req_o) || $isunknown(instr_valid_id_o) || $isunknown(is_fetch_failed_o)) begin
        $fatal(1, "TB_FAIL: X detected on primary control outputs");
      end
      if (instr_req_o && $isunknown(instr_addr_o)) begin
        $fatal(1, "TB_FAIL: X detected on instr_addr_o while instr_req_o=1");
      end
      if (instr_req_o && (instr_addr_o[1:0] != 2'b00)) begin
        $fatal(1, "TB_FAIL: unaligned OBI address %h", instr_addr_o);
      end
      if (obi_pending_q) begin
        if (!instr_req_o) begin
          $fatal(1, "TB_FAIL: OBI instr_req_o retracted before grant");
        end
        if (instr_addr_o !== obi_addr_q) begin
          $fatal(1, "TB_FAIL: OBI instr_addr_o changed from %h to %h before grant", obi_addr_q, instr_addr_o);
        end
      end
      obi_pending_q <= instr_req_o && !instr_gnt_i;
      if (instr_req_o && !instr_gnt_i) begin
        obi_addr_q <= instr_addr_o;
      end
    end
  end

  function automatic logic [31:0] rv32_addi(input logic [11:0] imm);
    return {imm, 5'd0, 3'b000, 5'd1, 7'b0010011};
  endfunction

  function automatic logic [15:0] rvc_addi(input logic [4:0] nzimm);
    return {3'b000, 1'b0, 5'd1, nzimm, 2'b01};
  endfunction

  function automatic logic [31:0] rvc_addi_expanded(input logic [4:0] nzimm);
    return {7'b0, nzimm, 5'd1, 3'b000, 5'd1, 7'b0010011};
  endfunction

  task automatic reset_dut();
    rst_n               = 1'b0;
    m_trap_base_addr_i  = 24'h001000;
    u_trap_base_addr_i  = 24'h002000;
    trap_addr_mux_i     = TRAP_MACHINE;
    boot_addr_i         = 32'h0000_1000;
    dm_exception_addr_i = 32'h0000_3000;
    dm_halt_addr_i      = 32'h0000_4000;
    req_i               = 1'b0;
    instr_gnt_i         = 1'b0;
    instr_rvalid_i      = 1'b0;
    instr_rdata_i       = 32'h0;
    instr_err_i         = 1'b0;
    instr_err_pmp_i     = 1'b0;
    clear_instr_valid_i = 1'b0;
    pc_set_i            = 1'b0;
    mepc_i              = 32'h0;
    uepc_i              = 32'h0;
    depc_i              = 32'h0;
    pc_mux_i            = PC_BOOT;
    exc_pc_mux_i        = EXC_PC_EXCEPTION;
    m_exc_vec_pc_mux_i  = 5'd0;
    u_exc_vec_pc_mux_i  = 5'd0;
    jump_target_id_i    = 32'h0;
    jump_target_ex_i    = 32'h0;
    hwlp_jump_i         = 1'b0;
    hwlp_target_i       = 32'h0;
    halt_if_i           = 1'b0;
    id_ready_i          = 1'b1;
    repeat (3) @(posedge clk);
    #1;
    rst_n = 1'b1;
    #1;
  endtask

  task automatic step_clk();
    @(posedge clk);
    #1;
  endtask

  int checks;

  // =========================================================================
  // Phase 1: HWLP FIFO preservation while flush_cnt_q > 0 (Case 1A)
  // =========================================================================
  task automatic test_phase_1_hwlp_fifo_preserved();
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b0;
    instr_gnt_i = 1'b1;
    #1;
    if (!(instr_req_o && instr_addr_o == 32'h0000_1000))
      $fatal(1, "P1: expected boot req 0x1000");
    step_clk(); // 0x1000 granted

    pc_set_i       = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h111); // HWLP_END at 0x1000
    instr_gnt_i    = 1'b1; // 0x1004 granted
    #1;
    if (!(instr_req_o && instr_addr_o == 32'h0000_1004))
      $fatal(1, "P1: expected req 0x1004");
    step_clk();

    // Now FIFO has [0x1000] (fifo_cnt=1, fifo_empty=0), and 0x1004 is in flight (cnt_q=1).
    // Assert hwlp_jump_i=1 to 0x2000 while id_ready_i=0 and instr_rvalid_i=0!
    instr_rvalid_i = 1'b0;
    hwlp_jump_i    = 1'b1;
    hwlp_target_i  = 32'h0000_2000;
    instr_gnt_i    = 1'b0; // stall grant of 0x2000
    #1;
    step_clk();

    // On the next cycle: flush_cnt_q == 1 (waiting to flush 0x1004), and 0x1000 is STILL in FIFO!
    // Unstall ID (id_ready_i = 1) while 0x1004 has NOT returned yet (flush_cnt_q == 1)!
    hwlp_jump_i = 1'b0;
    id_ready_i  = 1'b1;
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h111) || pc_id_o !== 32'h0000_1000) begin
      $fatal(1, "P1A: HWLP_END in FIFO was suppressed while flush_cnt_q > 0 (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    // Next cycle: 0x1004 returns on OBI (should be flushed!) and 0x2000 is granted
    instr_rvalid_i      = 1'b1;
    instr_rdata_i       = rv32_addi(12'hBAD);
    instr_gnt_i         = 1'b1;
    clear_instr_valid_i = 1'b1;
    #1;
    if (!(instr_req_o && instr_addr_o == 32'h0000_2000))
      $fatal(1, "P1A: expected held hwlp_target 0x2000 on OBI");
    step_clk();

    if (instr_valid_id_o)
      $fatal(1, "P1A: wrong-path 0x1004 leaked to ID instead of being flushed");
    checks++;

    // Next cycle: 0x2000 returns and is delivered with pc_id_o == 0x2000
    instr_rvalid_i      = 1'b1;
    instr_rdata_i       = rv32_addi(12'h200);
    clear_instr_valid_i = 1'b0;
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h200) || pc_id_o !== 32'h0000_2000) begin
      $fatal(1, "P1A: LOOP_START 0x2000 mismatch (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;
  endtask

  // =========================================================================
  // Phase 2: Same-cycle wrong-path OBI response on hwlp_jump_i when !fifo_empty
  // =========================================================================
  task automatic test_phase_2_hwlp_same_cycle_wrong_resp();
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b0;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted

    pc_set_i       = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h111); // HWLP_END at 0x1000 -> pushed to FIFO
    instr_gnt_i    = 1'b1; // 0x1004 granted
    #1;
    step_clk();

    // Now FIFO has 0x1000 (!fifo_empty_i), and 0x1004 returns on THIS exact cycle WITH instr_err_i = 1
    // while hwlp_jump_i=1 (and then on the NEXT cycle we check that err_freeze_q is 0),
    // AND ALSO test when 0x1004 returns with instr_err_i = 1 on hwlp_jump_i && !fifo_empty_i?
    // Wait: on hwlp_jump_i = 1, err_freeze_n is 0 anyway because `if (branch_i || hwlp_jump_i) err_freeze_n = 1'b0;`!
    // What if we test:
    // 1) In Phase 2: what if `hwlp_wait_resp_flush` triggered on cycle T (fifo_empty=1, resp_valid=0, cnt_q=2 -> hwlp_flush_after_resp=1, delayed_cnt=1),
    //    and on cycle T+1, 0x1000 returns WITH instr_err_i = 0 while id_ready_i = 0 (pushed to FIFO, and hwlp_flush_resp_delayed=1 sets flush_cnt_q <= 1),
    //    and on cycle T+2, 0x1004 returns WITH instr_err_i = 1 while flush_cnt_q == 1!
    //    Because flush_cnt_q == 1, 0x1004 is flushed (`resp_flushed = 1`), so it MUST NOT set `err_freeze_q <= 1`!
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'hBAD); // 0x1004 wrong-path response
    hwlp_jump_i    = 1'b1;
    hwlp_target_i  = 32'h0000_2000;
    instr_gnt_i    = 1'b1; // 0x2000 granted
    id_ready_i     = 1'b0;
    #1;
    step_clk();

    hwlp_jump_i    = 1'b0;
    instr_rvalid_i = 1'b0;
    id_ready_i     = 1'b1;
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h111) || pc_id_o !== 32'h0000_1000) begin
      $fatal(1, "P2: expected 0x1000 first after hwlp_jump_i (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    // Next cycle with instr_rvalid_i=0: FIFO must now be EMPTY (0x1004 was NOT pushed)!
    clear_instr_valid_i = 1'b1;
    #1;
    step_clk();
    if (instr_valid_id_o) begin
      $fatal(1, "P2: wrong-path 0x1004 was pushed into FIFO on hwlp_jump_i && !fifo_empty_i (rdata=%h)",
             instr_rdata_id_o);
    end
    checks++;

    // Now return 0x2000 from OBI
    instr_rvalid_i      = 1'b1;
    instr_rdata_i       = rv32_addi(12'h200);
    clear_instr_valid_i = 1'b0;
    #1;
    step_clk();
    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h200) || pc_id_o !== 32'h0000_2000) begin
      $fatal(1, "P2: expected 0x2000 after 0x1000 (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;
  endtask

  // =========================================================================
  // Phase 3: Delayed HWLP flush + subsequent hwlp_flush_resp canceling stale delayed flush
  // + hwlp_jump_i overriding BRANCH_WAIT + flushing freeing transaction credit
  // =========================================================================
  task automatic test_phase_3_hwlp_delayed_cancel_and_branch_wait();
    logic gnt_2000_3a;
    logic gnt_2000_3b;
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted (cnt_q=1)

    pc_set_i    = 1'b0;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1004 granted (cnt_q=2, fifo_empty=1)

    // Pulse hwlp_jump_i while fifo_empty=1 and resp_valid_i=0 -> sets hwlp_flush_after_resp=1, delayed_cnt=1
    hwlp_jump_i   = 1'b1;
    hwlp_target_i = 32'h0000_2000;
    instr_gnt_i   = 1'b0; // enters BRANCH_WAIT with trans_addr_q = 0x2000
    #1;
    step_clk();

    // Now in BRANCH_WAIT. Another hwlp_jump_i (target 0x3000) arrives while 0x1000 returns (resp_valid_i=1, id_ready_i=0)!
    hwlp_jump_i   = 1'b1;
    hwlp_target_i = 32'h0000_3000;
    instr_rvalid_i= 1'b1;
    instr_rdata_i = rv32_addi(12'h100); // 0x1000 returns while id_ready_i=0
    id_ready_i    = 1'b0;
    instr_gnt_i   = 1'b0;
    #1;
    instr_gnt_i   = (instr_req_o && instr_addr_o == 32'h0000_2000);
    #1;
    gnt_2000_3a   = (instr_req_o && instr_gnt_i);
    step_clk();

    // Now on this cycle:
    // - 0x1000 is in FIFO (fifo_cnt=1)
    // - 0x1004 is in flight on OBI (cnt_q=1), and flush_cnt_q=1 (waiting to discard 0x1004)
    // - Because active_cnt = cnt_q - flush_cnt_q = 0, fifo_cnt (1) + active_cnt (0) = 1 < 2,
    //   instr_req_o MUST BE 1 right now with instr_addr_o == 0x3000!
    hwlp_jump_i    = 1'b0;
    instr_rvalid_i = 1'b0;
    instr_gnt_i    = 1'b1;
    #1;
    if (!instr_req_o || instr_addr_o !== 32'h0000_3000) begin
      $fatal(1, "P3: expected OBI req for 0x3000 while fifo_cnt=1, cnt_q=1, flush_cnt_q=1 (req=%b addr=%h)",
             instr_req_o, instr_addr_o);
    end
    checks++;
    step_clk(); // 0x3000 granted! (cnt_q becomes 2, flush_cnt_q=1)

    // Pop 0x1000 from FIFO while 0x1004 returns (and gets flushed by flush_cnt_q=1)
    id_ready_i     = 1'b1;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'hBAD); // 0x1004 flushed
    instr_gnt_i    = 1'b0;
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h100) || pc_id_o !== 32'h0000_1000) begin
      $fatal(1, "P3: expected 0x1000 delivered to ID (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    if (gnt_2000_3a) begin
      instr_rvalid_i = 1'b1;
      instr_rdata_i  = rv32_addi(12'hBA2); // 0x2000 granted on OBI and flushed by second hwlp_jump_i
      instr_gnt_i    = 1'b0;
      #1;
      step_clk();
    end

    // Next cycle: 0x3000 returns!
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h300);
    instr_gnt_i    = 1'b1; // grant 0x3004
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h300) || pc_id_o !== 32'h0000_3000) begin
      $fatal(1, "P3: expected 0x3000 delivered to ID (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    // Next cycle: 0x3004 returns and MUST NOT be flushed by a stale hwlp_flush_after_resp!
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h304);
    instr_gnt_i    = 1'b0;
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h304) || pc_id_o !== 32'h0000_3004) begin
      $fatal(1, "P3: 0x3004 was erroneously flushed by stale hwlp_flush_after_resp (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    // 3B: Explicit stale hwlp_flush_after_resp test when hwlp_wait_resp_flush had cnt_q=2 (so delayed_cnt=1):
    // Boot 0x1000, grant 0x1000 and 0x1004 (cnt_q=2, fifo_empty=1).
    // Pulse hwlp_jump_i to 0x2000 while fifo_empty=1 and resp_valid=0 -> sets hwlp_flush_after_resp=1, delayed_cnt=1!
    // Then on next cycle, 0x1000 returns WITH hwlp_jump_i=1 to 0x3000 (so hwlp_flush_resp=1!).
    // If hwlp_flush_resp does NOT clear hwlp_flush_after_resp/delayed_cnt, then when 0x1004 returns on the cycle after,
    // hwlp_flush_resp_delayed will fire and reload flush_cnt_q <= 1, which then flushes 0x3000!
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted (cnt_q=1)

    pc_set_i    = 1'b0;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1004 granted (cnt_q=2)

    // Pulse hwlp_jump_i while fifo_empty=1, resp_valid=0, cnt_q=2 -> delayed_cnt=1, hwlp_flush_after_resp=1
    hwlp_jump_i   = 1'b1;
    hwlp_target_i = 32'h0000_2000;
    instr_gnt_i   = 1'b0;
    #1;
    step_clk();

    // Now 0x1000 returns while hwlp_jump_i=1 (to 0x3000) and id_ready_i=1 -> hwlp_flush_resp=1!
    // Because cnt_q=2 and resp_valid_i=1, next_flush_cnt = 1 (to flush 0x1004).
    hwlp_jump_i    = 1'b1;
    hwlp_target_i  = 32'h0000_3000;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h100);
    instr_gnt_i    = 1'b0;
    #1;
    instr_gnt_i    = (instr_req_o && instr_addr_o == 32'h0000_2000);
    #1;
    gnt_2000_3b    = (instr_req_o && instr_gnt_i);
    step_clk(); // 0x1000 retires into ID; if 0x2000 was registered on OBI, it is granted & scheduled for flush

    // Now grant 0x3000 while 0x1004 returns (and gets flushed)!
    // If hwlp_flush_after_resp was STILL 1, 0x1004 returning here will trigger hwlp_flush_resp_delayed
    // and set flush_cnt_q <= delayed_cnt (1) instead of 0!
    hwlp_jump_i    = 1'b0;
    instr_gnt_i    = 1'b1; // 0x3000 granted
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'hBAD); // 0x1004 flushed
    #1;
    step_clk();

    if (gnt_2000_3b) begin
      instr_gnt_i    = 1'b0;
      instr_rvalid_i = 1'b1;
      instr_rdata_i  = rv32_addi(12'hBA2); // 0x2000 flushed
      #1;
      step_clk();
    end

    // Next cycle: 0x3000 returns! It MUST NOT be flushed!
    instr_gnt_i    = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h300);
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h300) || pc_id_o !== 32'h0000_3000) begin
      $fatal(1, "P3B: 0x3000 was flushed because hwlp_flush_resp did not clear hwlp_flush_after_resp (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    // 3C: Direct hwlp_wait_resp_flush delayed flush test (cnt_q=2 -> delayed_cnt=1):
    // Boot 0x1000, grant 0x1000 and 0x1004 (cnt_q=2, fifo_empty=1).
    // Pulse hwlp_jump_i to 0x2000 while fifo_empty=1 and resp_valid=0 -> sets hwlp_flush_after_resp=1, delayed_cnt=1,
    // AND grant 0x2000 on next cycle after 0x1000 returns!
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted (cnt_q=1)

    pc_set_i    = 1'b0;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1004 granted (cnt_q=2)

    // Pulse hwlp_jump_i while fifo_empty=1, resp_valid=0, cnt_q=2 -> delayed_cnt=1
    hwlp_jump_i   = 1'b1;
    hwlp_target_i = 32'h0000_2000;
    instr_gnt_i   = 1'b0;
    #1;
    step_clk();

    // Now 0x1000 (HWLP_END) returns with hwlp_jump_i=0 -> triggers hwlp_flush_resp_delayed!
    // Must deliver 0x1000 to ID and set flush_cnt_q <= delayed_cnt (1, to flush 0x1004, NOT 0x2000!).
    hwlp_jump_i    = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h100);
    instr_gnt_i    = 1'b1; // 0x2000 granted here!
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h100) || pc_id_o !== 32'h0000_1000)
      $fatal(1, "P3C: 0x1000 HWLP_END mismatch");

    // Next cycle: 0x1004 returns and is flushed by flush_cnt_q=1 -> 0
    instr_rvalid_i      = 1'b1;
    instr_rdata_i       = rv32_addi(12'hBAD);
    instr_gnt_i         = 1'b0;
    clear_instr_valid_i = 1'b1;
    #1;
    step_clk();
    if (instr_valid_id_o)
      $fatal(1, "P3C: 0x1004 was not flushed");

    // Next cycle: 0x2000 (LOOP_START) returns! If delayed_cnt was cnt_q (2) instead of cnt_q - 1 (1),
    // 0x2000 would be erroneously flushed!
    instr_rvalid_i      = 1'b1;
    instr_rdata_i       = rv32_addi(12'h200);
    clear_instr_valid_i = 1'b0;
    #1;
    step_clk();
    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h200) || pc_id_o !== 32'h0000_2000)
      $fatal(1, "P3C: 0x2000 LOOP_START was erroneously flushed by over-counted delayed_cnt");
    checks++;
  endtask

  // =========================================================================
  // Phase 4: Aligner HWLP PC update across compressed & misaligned states
  // =========================================================================
  task automatic test_phase_4_aligner_hwlp_compressed_and_misaligned();
    // 4A: ALIGNED32 with 16-bit compressed HWLP_END at 0x1000, jumping to misaligned target 0x2002!
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted

    pc_set_i       = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = {16'hDEAD, rvc_addi(5'd3)};
    hwlp_jump_i    = 1'b1;
    hwlp_target_i  = 32'h0000_2002;
    instr_gnt_i    = 1'b1; // 0x2000 word-aligned request granted
    #1;
    step_clk();

    if (!instr_valid_id_o || !is_compressed_id_o || instr_rdata_id_o !== rvc_addi_expanded(5'd3) || pc_id_o !== 32'h0000_1000) begin
      $fatal(1, "P4A: compressed HWLP_END at 0x1000 mismatch (valid=%b comp=%b rdata=%h pc=%h)",
             instr_valid_id_o, is_compressed_id_o, instr_rdata_id_o, pc_id_o);
    end
    if (pc_if_o !== 32'h0000_2002) begin
      $fatal(1, "P4A: aligner failed to update pc_if_o to hwlp_target 0x2002 on compressed ALIGNED32 (got %h)", pc_if_o);
    end
    checks++;

    // Return word at 0x2000 containing {rvc_addi(5'd7), 16'hBEEF} -> in BRANCH_MISALIGNED, upper halfword at 0x2002 is executed!
    hwlp_jump_i    = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = {rvc_addi(5'd7), 16'hBEEF};
    instr_gnt_i    = 1'b1;
    #1;
    step_clk();

    if (!instr_valid_id_o || !is_compressed_id_o || instr_rdata_id_o !== rvc_addi_expanded(5'd7) || pc_id_o !== 32'h0000_2002) begin
      $fatal(1, "P4A: misaligned HWLP target 0x2002 instruction mismatch (valid=%b comp=%b rdata=%h pc=%h)",
             instr_valid_id_o, is_compressed_id_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    // 4B: MISALIGNED32 32-bit spanning instruction at 0x2006 followed by hwlp_jump_i to 0x3000 while stalled!
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = {rv32_addi(12'h555)[15:0], rvc_addi(5'd1)};
    #1;
    step_clk(); // 0x2004 (c.addi(1)) retires; aligner enters MISALIGNED32 with pc_if_o = 0x2006, r_instr_h = low half

    // Stall ID (id_ready_i = 0) and pulse hwlp_jump_i to 0x3000 while in MISALIGNED32!
    id_ready_i     = 1'b0;
    instr_rvalid_i = 1'b0;
    hwlp_jump_i    = 1'b1;
    hwlp_target_i  = 32'h0000_3000;
    instr_gnt_i    = 1'b1;
    #1;
    step_clk();

    // Unstall ID and provide the second word 0x2008 containing upper half of rv32_addi(12'h555) in [15:0]
    hwlp_jump_i    = 1'b0;
    id_ready_i     = 1'b1;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = {16'hCAFE, rv32_addi(12'h555)[31:16]};
    #1;
    step_clk();

    if (!instr_valid_id_o || is_compressed_id_o || instr_rdata_id_o !== rv32_addi(12'h555) || pc_id_o !== 32'h0000_2006) begin
      $fatal(1, "P4B: spanning 32-bit HWLP_END at 0x2006 mismatch (valid=%b rdata=%h pc=%h)",
             instr_valid_id_o, instr_rdata_id_o, pc_id_o);
    end
    if (pc_if_o !== 32'h0000_3000) begin
      $fatal(1, "P4B: aligner failed to jump from MISALIGNED32 to 0x3000 (pc_if_o=%h)", pc_if_o);
    end
    checks++;

    // 4C: MISALIGNED16 HWLP_END with hwlp_jump_i to 0x4000
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk();

    pc_set_i       = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_rdata_i  = {rvc_addi(5'd4), rvc_addi(5'd2)}; // 0x1000: c.addi(2), 0x1002: c.addi(4)
    #1;
    step_clk(); // 0x1000 retires, state -> MISALIGNED32 (r_instr_h = c.addi(4), pc_if_o = 0x1002)

    instr_rvalid_i = 1'b1;
    instr_rdata_i  = rv32_addi(12'h104); // 0x1004 arrives while 0x1002 retires -> pushed to FIFO, state -> MISALIGNED16 (pc_if_o = 0x1004)
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rvc_addi_expanded(5'd4) || pc_id_o !== 32'h0000_1002)
      $fatal(1, "P4C: 0x1002 mismatch");
    if (pc_if_o !== 32'h0000_1004)
      $fatal(1, "P4C: expected pc_if_o=0x1004 in MISALIGNED16");

    // Now in MISALIGNED16: pulse hwlp_jump_i to 0x4000!
    instr_rvalid_i = 1'b0;
    hwlp_jump_i    = 1'b1;
    hwlp_target_i  = 32'h0000_4000;
    instr_gnt_i    = 1'b1;
    #1;
    step_clk();

    if (!instr_valid_id_o || instr_rdata_id_o !== rv32_addi(12'h104) || pc_id_o !== 32'h0000_1004)
      $fatal(1, "P4C: 0x1004 in MISALIGNED16 mismatch");
    if (pc_if_o !== 32'h0000_4000)
      $fatal(1, "P4C: aligner failed to update pc_if_o to 0x4000 from MISALIGNED16 (got %h)", pc_if_o);
    checks++;
  endtask

  // =========================================================================
  // Phase 5: Instruction Bus Error Attribution, Post-Fault Freeze & Spanning Faults
  // =========================================================================
  task automatic test_phase_5_instruction_bus_faults();
    logic gnt_1004_5a;
    // 5A: Aligned fault at 0x1000
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted

    pc_set_i       = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_err_i    = 1'b1;
    instr_rdata_i  = 32'h0000_0000; // would be illegal compressed instruction if not masked!
    instr_gnt_i    = 1'b1; // 0x1004 is granted on this edge only if DUT still requested 0x1004
    #1;
    gnt_1004_5a    = (instr_req_o && instr_gnt_i);
    step_clk();

    if (!instr_valid_id_o || !is_fetch_failed_o || illegal_c_insn_id_o || pc_id_o !== 32'h0000_1000 || pc_if_o !== 32'h0000_1000) begin
      $fatal(1, "P5A: aligned fault at 0x1000 mismatch (valid=%b fail=%b ill_c=%b pc_id=%h pc_if=%h)",
             instr_valid_id_o, is_fetch_failed_o, illegal_c_insn_id_o, pc_id_o, pc_if_o);
    end
    if (instr_req_o) begin
      $fatal(1, "P5A: prefetcher failed to freeze new OBI requests after non-flushed bus error");
    end
    checks++;

    // Return 0x1004 only if it was actually granted on OBI while clear_instr_valid_i = 1:
    instr_rvalid_i      = gnt_1004_5a;
    instr_err_i         = 1'b0;
    instr_rdata_i       = rv32_addi(12'h104);
    clear_instr_valid_i = 1'b1;
    #1;
    step_clk();

    if (instr_valid_id_o || is_fetch_failed_o || pc_if_o !== 32'h0000_1000) begin
      $fatal(1, "P5A: post-fault state corrupted before redirect (valid=%b fail=%b pc_if=%h)",
             instr_valid_id_o, is_fetch_failed_o, pc_if_o);
    end
    if (instr_req_o) begin
      $fatal(1, "P5A: prefetcher issued request while still frozen before redirect");
    end
    checks++;

    // Now redirect to trap handler via pc_set_i (PC_EXCEPTION -> 0x0010_0000): must unfreeze!
    instr_rvalid_i      = 1'b0;
    clear_instr_valid_i = 1'b0;
    pc_set_i            = 1'b1;
    pc_mux_i            = PC_EXCEPTION;
    exc_pc_mux_i        = EXC_PC_EXCEPTION;
    instr_gnt_i         = 1'b1;
    #1;
    if (!instr_req_o || instr_addr_o !== 32'h0010_0000) begin
      $fatal(1, "P5A: pc_set_i redirect failed to unfreeze prefetcher (req=%b addr=%h)", instr_req_o, instr_addr_o);
    end
    step_clk();

    // 5B: Misaligned branch to 0x2002 where 0x2000 word has no error (32-bit instr starting at 0x2002)
    // and 0x2004 word returns with instr_err_i = 1!
    reset_dut();
    req_i            = 1'b1;
    pc_set_i         = 1'b1;
    pc_mux_i         = PC_JUMP;
    jump_target_id_i = 32'h0000_2002;
    id_ready_i       = 1'b1;
    instr_gnt_i      = 1'b1;
    #1;
    step_clk(); // 0x2000 granted

    pc_set_i       = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_err_i    = 1'b0;
    instr_rdata_i  = {rv32_addi(12'h222)[15:0], 16'hAAAA};
    instr_gnt_i    = 1'b1; // 0x2004 granted
    #1;
    step_clk();

    if (instr_valid_id_o || pc_if_o !== 32'h0000_2002) begin
      $fatal(1, "P5B: expected waiting for second half of 0x2002 (valid=%b pc_if=%h)", instr_valid_id_o, pc_if_o);
    end

    // Second word 0x2004 returns with instr_err_i = 1!
    instr_rvalid_i = 1'b1;
    instr_err_i    = 1'b1;
    instr_rdata_i  = 32'h0000_0000;
    instr_gnt_i    = 1'b0;
    #1;
    step_clk();

    if (!instr_valid_id_o || !is_fetch_failed_o || illegal_c_insn_id_o || pc_id_o !== 32'h0000_2002 || pc_if_o !== 32'h0000_2002) begin
      $fatal(1, "P5B: second-half fault on spanning 32-bit instr at 0x2002 mismatch (valid=%b fail=%b ill=%b pc_id=%h pc_if=%h)",
             instr_valid_id_o, is_fetch_failed_o, illegal_c_insn_id_o, pc_id_o, pc_if_o);
    end
    checks++;

    // 5C: Valid 16-bit compressed instruction in r_instr_h (MISALIGNED32 at 0x1002) when next word 0x1004 returns WITH instr_err_i = 1!
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted

    pc_set_i       = 1'b0;
    instr_rvalid_i = 1'b1;
    instr_err_i    = 1'b0;
    instr_rdata_i  = {rvc_addi(5'd9), rvc_addi(5'd8)}; // 0x1000: c.addi(8), 0x1002: c.addi(9)
    instr_gnt_i    = 1'b1; // 0x1004 granted
    #1;
    step_clk(); // 0x1000 retires, aligner in MISALIGNED32 at pc_if_o=0x1002 with r_instr_h=c.addi(9)

    // Now 0x1004 returns with instr_err_i = 1 on the exact cycle 0x1002 is in MISALIGNED32!
    instr_rvalid_i = 1'b1;
    instr_err_i    = 1'b1;
    instr_rdata_i  = 32'h0000_0000;
    instr_gnt_i    = 1'b0;
    #1;
    step_clk();

    // 0x1002 MUST retire cleanly without error!
    if (!instr_valid_id_o || is_fetch_failed_o || instr_rdata_id_o !== rvc_addi_expanded(5'd9) || pc_id_o !== 32'h0000_1002) begin
      $fatal(1, "P5C: valid 16-bit instruction at 0x1002 was corrupted by next word's fault (valid=%b fail=%b rdata=%h pc=%h)",
             instr_valid_id_o, is_fetch_failed_o, instr_rdata_id_o, pc_id_o);
    end
    checks++;

    // On the next cycle (in MISALIGNED16 at 0x1004), the buffered fault for 0x1004 MUST be reported!
    instr_rvalid_i = 1'b0;
    instr_err_i    = 1'b0;
    #1;
    step_clk();

    if (!instr_valid_id_o || !is_fetch_failed_o || illegal_c_insn_id_o || pc_id_o !== 32'h0000_1004 || pc_if_o !== 32'h0000_1004) begin
      $fatal(1, "P5C: buffered fault at 0x1004 in MISALIGNED16 was lost (valid=%b fail=%b ill=%b pc_id=%h pc_if=%h)",
             instr_valid_id_o, is_fetch_failed_o, illegal_c_insn_id_o, pc_id_o, pc_if_o);
    end
    checks++;

    // 5D: Flushed wrong-path response with instr_err_i = 1 MUST NOT freeze the prefetcher!
    reset_dut();
    req_i       = 1'b1;
    pc_set_i    = 1'b1;
    pc_mux_i    = PC_BOOT;
    boot_addr_i = 32'h0000_1000;
    id_ready_i  = 1'b1;
    instr_gnt_i = 1'b1;
    #1;
    step_clk(); // 0x1000 granted (cnt_q=1)

    // Redirect to 0x5000 before 0x1000 returns, but DO NOT grant 0x5000 yet!
    pc_set_i         = 1'b1;
    pc_mux_i         = PC_JUMP;
    jump_target_id_i = 32'h0000_5000;
    instr_gnt_i      = 1'b0;
    #1;
    step_clk(); // 0x5000 latched in OBI interface (REGISTERED), flush_cnt_q=1, cnt_q=1

    // Now grant 0x5000 on OBI while flushed response for 0x1000 returns WITH instr_err_i = 1!
    pc_set_i       = 1'b0;
    instr_gnt_i    = 1'b1;
    instr_rvalid_i = 1'b1;
    instr_err_i    = 1'b1;
    instr_rdata_i  = 32'hDEAD_BEEF;
    #1;
    step_clk();

    // Now 0x5000 has been accepted by OBI (trans_ready=1 again).
    // Because 0x1000 was flushed (flush_cnt_q == 1), it must NOT freeze the prefetcher:
    // instr_req_o for 0x5004 MUST be asserted!
    instr_rvalid_i = 1'b0;
    instr_err_i    = 1'b0;
    instr_gnt_i    = 1'b0;
    #1;
    if (!instr_req_o || instr_addr_o !== 32'h0000_5004) begin
      $fatal(1, "P5D: flushed wrong-path error response falsely froze prefetcher (req=%b addr=%h)",
             instr_req_o, instr_addr_o);
    end
    checks++;
  endtask

  // =========================================================================
  // Phase 6: Seeded randomized stress across stalls, redirects, HWLP & errors
  // =========================================================================
  task automatic test_phase_6_random_stress();
    int unsigned rng;
    rng = SEED ^ 32'h9E37_79B9;
    for (int iter = 0; iter < 40; iter++) begin
      logic [31:0] base_pc;
      logic [11:0] imm0;
      rng     = rng * 32'd1664525 + 32'd1013904223;
      base_pc = {16'h0001, rng[15:2], 2'b00};
      imm0    = rng[11:0];

      reset_dut();
      req_i            = 1'b1;
      pc_set_i         = 1'b1;
      pc_mux_i         = PC_JUMP;
      jump_target_id_i = base_pc;
      id_ready_i       = 1'b0;
      instr_gnt_i      = 1'b1;
      #1;
      step_clk();

      pc_set_i       = 1'b0;
      instr_rvalid_i = 1'b1;
      instr_err_i    = (iter % 5 == 0);
      instr_rdata_i  = rv32_addi(imm0);
      instr_gnt_i    = 1'b1;
      #1;
      step_clk();

      instr_rvalid_i = 1'b0;
      instr_err_i    = 1'b0;
      id_ready_i     = 1'b1;
      #1;
      step_clk();

      if (!instr_valid_id_o || pc_id_o !== base_pc)
        $fatal(1, "P6 iter %0d: pc_id_o mismatch", iter);
      if (is_fetch_failed_o !== (iter % 5 == 0))
        $fatal(1, "P6 iter %0d: is_fetch_failed_o mismatch", iter);
      checks++;
    end
  endtask

  initial begin
    checks = 0;
    test_phase_1_hwlp_fifo_preserved();
    test_phase_2_hwlp_same_cycle_wrong_resp();
    test_phase_3_hwlp_delayed_cancel_and_branch_wait();
    test_phase_4_aligner_hwlp_compressed_and_misaligned();
    test_phase_5_instruction_bus_faults();
    test_phase_6_random_stress();
    $display("PASS cv32e40p_if_stage seed=%0d checks=%0d", SEED, checks);
    $finish;
  end

endmodule
