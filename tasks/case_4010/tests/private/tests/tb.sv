// Copyright 2026 Benchmark Authors.
// Comprehensive private testbench for case_4010 (cv32e41p_ctrl_subsystem with sleep_unit).

module tb;
  import cv32e41p_pkg::*;

  logic        clk;
  logic        clk_ungated_i;
  logic        rst_n;

  logic        fetch_enable_i;
  logic        fetch_enable_o;
  logic        scan_cg_en_i;
  logic        if_busy_i;
  logic        lsu_busy_i;
  logic        apu_busy_i;
  logic        pulp_clock_en_i;
  logic        p_elw_start_i;
  logic        p_elw_finish_i;
  logic        clk_gated_o;
  logic        core_sleep_o;

  logic        ctrl_busy_o;
  logic        is_decoding_o;
  logic        is_fetch_failed_i;
  logic        deassert_we_o;

  logic        illegal_insn_i;
  logic        ecall_insn_i;
  logic        mret_insn_i;
  logic        uret_insn_i;
  logic        dret_insn_i;
  logic        mret_dec_i;
  logic        uret_dec_i;
  logic        dret_dec_i;
  logic        wfi_i;
  logic        ebrk_insn_i;
  logic        fencei_insn_i;
  logic        csr_status_i;

  logic        hwlp_mask_o;
  logic        instr_valid_i;
  logic        instr_req_o;

  logic        pc_set_o;
  logic [ 3:0] pc_mux_o;
  logic [ 2:0] exc_pc_mux_o;
  logic [ 1:0] trap_addr_mux_o;

  logic [31:0] pc_id_i;
  logic        is_compressed_i;

  logic [31:0] hwlp_start_data_i;
  logic [31:0] hwlp_end_data_i;
  logic [31:0] hwlp_cnt_data_i;
  logic [ 2:0] hwlp_we_i;
  logic        hwlp_regid_i;

  logic [1:0][31:0] hwlp_start_addr_o;
  logic [1:0][31:0] hwlp_end_addr_o;
  logic [1:0][31:0] hwlp_counter_o;
  logic [1:0]       hwlp_dec_cnt_o;
  logic             hwlp_jump_o;
  logic [31:0]      hwlp_targ_addr_o;

  logic        data_req_ex_i;
  logic        data_we_ex_i;
  logic        data_misaligned_i;
  logic        data_load_event_i;
  logic        data_err_i;
  logic        data_err_ack_o;

  logic        mult_multicycle_i;
  logic        apu_en_i;
  logic        apu_read_dep_i;
  logic        apu_write_dep_i;
  logic        apu_stall_o;

  logic        branch_taken_ex_i;
  logic [ 1:0] ctrl_transfer_insn_in_id_i;
  logic [ 1:0] ctrl_transfer_insn_in_dec_i;

  logic [31:0] irq_i;
  logic        irq_sec_i;
  logic [31:0] mie_bypass_i;
  logic [31:0] mip_o;
  logic        m_irq_enable_i;
  logic        u_irq_enable_i;
  PrivLvl_t    current_priv_lvl_i;

  logic        irq_req_ctrl_o;
  logic        irq_sec_ctrl_o;
  logic [ 4:0] irq_id_ctrl_o;
  logic        irq_wu_ctrl_o;
  logic        irq_ack_o;
  logic [ 4:0] irq_id_o;
  logic [ 4:0] exc_cause_o;

  logic        debug_mode_o;
  logic [ 2:0] debug_cause_o;
  logic        debug_csr_save_o;
  logic        debug_req_i;
  logic        debug_single_step_i;
  logic        debug_ebreakm_i;
  logic        debug_ebreaku_i;
  logic        trigger_match_i;
  logic        debug_p_elw_no_sleep_o;
  logic        debug_wfi_no_sleep_o;
  logic        debug_havereset_o;
  logic        debug_running_o;
  logic        debug_halted_o;

  logic        wake_from_sleep_o;
  logic        csr_save_if_o;
  logic        csr_save_id_o;
  logic        csr_save_ex_o;
  logic [ 5:0] csr_cause_o;
  logic        csr_irq_sec_o;
  logic        csr_restore_mret_id_o;
  logic        csr_restore_uret_id_o;
  logic        csr_restore_dret_id_o;
  logic        csr_save_cause_o;

  logic        regfile_we_id_i;
  logic [ 5:0] regfile_alu_waddr_id_i;
  logic        regfile_we_ex_i;
  logic [ 5:0] regfile_waddr_ex_i;
  logic        regfile_we_wb_i;
  logic        regfile_alu_we_fw_i;

  logic [ 1:0] operand_a_fw_mux_sel_o;
  logic [ 1:0] operand_b_fw_mux_sel_o;
  logic [ 1:0] operand_c_fw_mux_sel_o;

  logic        reg_d_ex_is_reg_a_i;
  logic        reg_d_ex_is_reg_b_i;
  logic        reg_d_ex_is_reg_c_i;
  logic        reg_d_wb_is_reg_a_i;
  logic        reg_d_wb_is_reg_b_i;
  logic        reg_d_wb_is_reg_c_i;
  logic        reg_d_alu_is_reg_a_i;
  logic        reg_d_alu_is_reg_b_i;
  logic        reg_d_alu_is_reg_c_i;

  logic        halt_if_o;
  logic        halt_id_o;
  logic        misaligned_stall_o;
  logic        jr_stall_o;
  logic        load_stall_o;

  logic        id_ready_i;
  logic        id_valid_i;
  logic        ex_valid_i;
  logic        wb_ready_i;
  logic        perf_pipeline_stall_o;

  cv32e41p_ctrl_subsystem #(
      .PULP_CLUSTER(1),
      .PULP_XPULP  (1),
      .PULP_SECURE (1),
      .N_HWLP      (2)
  ) dut (
      .*
  );

  initial begin
    clk           = 1'b0;
    clk_ungated_i = 1'b0;
    forever begin
      #5;
      clk           = ~clk;
      clk_ungated_i = ~clk_ungated_i;
    end
  end

  task automatic fail_msg(input string msg);
    $display("FAIL: %s (time=%0t)", msg, $time);
    $fatal(1);
  endtask

  task automatic clear_inputs();
    fetch_enable_i              = 1'b0;
    scan_cg_en_i                = 1'b0;
    if_busy_i                   = 1'b0;
    lsu_busy_i                  = 1'b0;
    apu_busy_i                  = 1'b0;
    pulp_clock_en_i             = 1'b1;
    p_elw_start_i               = 1'b0;
    p_elw_finish_i              = 1'b0;
    is_fetch_failed_i           = 1'b0;
    illegal_insn_i              = 1'b0;
    ecall_insn_i                = 1'b0;
    mret_insn_i                 = 1'b0;
    uret_insn_i                 = 1'b0;
    dret_insn_i                 = 1'b0;
    mret_dec_i                  = 1'b0;
    uret_dec_i                  = 1'b0;
    dret_dec_i                  = 1'b0;
    wfi_i                       = 1'b0;
    ebrk_insn_i                 = 1'b0;
    fencei_insn_i               = 1'b0;
    csr_status_i                = 1'b0;
    instr_valid_i               = 1'b0;
    pc_id_i                     = 32'h0000_0000;
    is_compressed_i             = 1'b0;
    hwlp_start_data_i           = 32'h0;
    hwlp_end_data_i             = 32'h0;
    hwlp_cnt_data_i             = 32'h0;
    hwlp_we_i                   = 3'b000;
    hwlp_regid_i                = 1'b0;
    data_req_ex_i               = 1'b0;
    data_we_ex_i                = 1'b0;
    data_misaligned_i           = 1'b0;
    data_load_event_i           = 1'b0;
    data_err_i                  = 1'b0;
    mult_multicycle_i           = 1'b0;
    apu_en_i                    = 1'b0;
    apu_read_dep_i              = 1'b0;
    apu_write_dep_i             = 1'b0;
    branch_taken_ex_i           = 1'b0;
    ctrl_transfer_insn_in_id_i  = 2'b00;
    ctrl_transfer_insn_in_dec_i = 2'b00;
    irq_i                       = 32'h0;
    irq_sec_i                   = 1'b0;
    mie_bypass_i                = 32'h0;
    m_irq_enable_i              = 1'b0;
    u_irq_enable_i              = 1'b0;
    current_priv_lvl_i          = PRIV_LVL_M;
    debug_req_i                 = 1'b0;
    debug_single_step_i         = 1'b0;
    debug_ebreakm_i             = 1'b0;
    debug_ebreaku_i             = 1'b0;
    trigger_match_i             = 1'b0;
    regfile_we_id_i             = 1'b0;
    regfile_alu_waddr_id_i      = 6'd0;
    regfile_we_ex_i             = 1'b0;
    regfile_waddr_ex_i          = 6'd0;
    regfile_we_wb_i             = 1'b0;
    regfile_alu_we_fw_i         = 1'b0;
    reg_d_ex_is_reg_a_i         = 1'b0;
    reg_d_ex_is_reg_b_i         = 1'b0;
    reg_d_ex_is_reg_c_i         = 1'b0;
    reg_d_wb_is_reg_a_i         = 1'b0;
    reg_d_wb_is_reg_b_i         = 1'b0;
    reg_d_wb_is_reg_c_i         = 1'b0;
    reg_d_alu_is_reg_a_i        = 1'b0;
    reg_d_alu_is_reg_b_i        = 1'b0;
    reg_d_alu_is_reg_c_i        = 1'b0;
    id_ready_i                  = 1'b1;
    id_valid_i                  = 1'b1;
    ex_valid_i                  = 1'b1;
    wb_ready_i                  = 1'b1;
  endtask

  task automatic reset_and_boot_to_decode();
    clear_inputs();
    rst_n = 1'b0;
    repeat (2) @(posedge clk);
    #1;
    rst_n          = 1'b1;
    // Pulse fetch_enable_i for 1 cycle ONLY to test sticky fetch_enable_o!
    fetch_enable_i = 1'b1;
    @(posedge clk);
    #1;
    fetch_enable_i = 1'b0;
    if (fetch_enable_o !== 1'b1) begin
      fail_msg("fetch_enable_o did not latch after fetch_enable_i pulse");
    end
    // RESET -> BOOT_SET -> FIRST_FETCH -> DECODE
    repeat (3) @(posedge clk);
    #1;
    if (fetch_enable_o !== 1'b1) begin
      fail_msg("fetch_enable_o is not sticky after fetch_enable_i deasserted");
    end
  endtask

  task automatic write_hwloop(input logic regid, input logic [31:0] s_addr, input logic [31:0] e_addr, input logic [31:0] cnt);
    @(negedge clk);
    hwlp_regid_i      = regid;
    hwlp_start_data_i = s_addr;
    hwlp_end_data_i   = e_addr;
    hwlp_cnt_data_i   = cnt;
    hwlp_we_i         = 3'b111;
    id_ready_i        = 1'b1;
    @(posedge clk);
    #1;
    hwlp_we_i         = 3'b000;
  endtask

  // 0. Test sleep_unit p.elw sleep gating, start/finish priority, and debug sleep suppression
  task automatic test_sleep_unit_elw_and_debug_no_sleep();
    reset_and_boot_to_decode();

    // Pulse p_elw_start_i = 1 while if_busy_i = 0, apu_busy_i = 0:
    // On this cycle p_elw_busy_d = 1, so core_busy_d = 0!
    @(negedge clk);
    p_elw_start_i   = 1'b1;
    p_elw_finish_i  = 1'b0;
    if_busy_i       = 1'b0;
    apu_busy_i      = 1'b0;
    pulp_clock_en_i = 1'b0;
    @(posedge clk); // Latches p_elw_busy_q = 1, core_busy_q = 0!
    #1;
    p_elw_start_i   = 1'b0;
    #1;
    if (core_sleep_o !== 1'b1) begin
      fail_msg($sformatf("Expected core_sleep_o=1 on cycle after p_elw_start_i with idle IF/APU, got %0b", core_sleep_o));
    end

    // While in p.elw sleep, assert trigger_match_i = 1 -> debug_p_elw_no_sleep_o = 1 -> core_sleep_o must immediately drop to 0!
    trigger_match_i = 1'b1;
    #1;
    if (debug_p_elw_no_sleep_o !== 1'b1 || core_sleep_o !== 1'b0) begin
      fail_msg("core_sleep_o was not suppressed by debug_p_elw_no_sleep_o");
    end
    trigger_match_i = 1'b0;
    #1;
    if (core_sleep_o !== 1'b1) begin
      fail_msg("core_sleep_o did not resume when trigger_match_i deasserted");
    end

    // If p_elw_start_i and p_elw_finish_i both assert in the same cycle, p_elw_start_i takes precedence (p_elw_busy_d = 1)
    p_elw_start_i  = 1'b1;
    p_elw_finish_i = 1'b1;
    #1;
    if (core_sleep_o !== 1'b1) begin
      fail_msg("p_elw_start_i did not take precedence over p_elw_finish_i");
    end
    p_elw_start_i  = 1'b0;
    #1;
    // Now only p_elw_finish_i is 1 -> p_elw_busy_d = 0 -> core_sleep_o must drop to 0!
    if (core_sleep_o !== 1'b0) begin
      fail_msg("p_elw_finish_i did not clear core_sleep_o");
    end
    @(posedge clk);
    #1;
    p_elw_finish_i  = 1'b0;
    pulp_clock_en_i = 1'b1;
  endtask

  // 1. Interrupt controller wakeup masking, U-mode secure alignment, and priority encoding
  task automatic test_int_controller_wakeup_and_secure_align();
    int prio_order[19] = '{31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 11, 3, 7};
    logic [31:0] accum_mask;

    reset_and_boot_to_decode();

    mie_bypass_i = 32'hFFFF_FFFF;
    irq_i        = 32'h0000_0000;
    @(posedge clk);
    #1;
    if (irq_id_ctrl_o !== 5'd0 || irq_req_ctrl_o !== 1'b0 || irq_wu_ctrl_o !== 1'b0) begin
      fail_msg("Idle interrupt controller state mismatch");
    end

    irq_i        = ~IRQ_MASK;
    mie_bypass_i = 32'hFFFF_FFFF;
    #1;
    if (irq_wu_ctrl_o !== 1'b0 || wake_from_sleep_o !== 1'b0) begin
      fail_msg("Reserved IRQ bits triggered wakeup");
    end
    @(posedge clk);
    #1;
    if (mip_o !== 32'h0 || irq_req_ctrl_o !== 1'b0 || irq_id_ctrl_o !== 5'd0) begin
      fail_msg("Reserved IRQ bits leaked into mip_o or irq_id_ctrl_o");
    end

    m_irq_enable_i     = 1'b1;
    current_priv_lvl_i = PRIV_LVL_M;
    accum_mask         = 32'hFFFF_0888;
    for (int k = 0; k < 19; k++) begin
      int expected_bit = prio_order[k];
      @(negedge clk);
      irq_i        = accum_mask;
      mie_bypass_i = 32'hFFFF_FFFF;
      @(posedge clk);
      #1;
      if (irq_wu_ctrl_o !== 1'b1 || irq_req_ctrl_o !== 1'b1 || irq_id_ctrl_o !== expected_bit[4:0]) begin
        fail_msg("Priority encoder mismatch");
      end
      accum_mask[expected_bit] = 1'b0;
    end

    @(negedge clk);
    current_priv_lvl_i = PRIV_LVL_U;
    u_irq_enable_i     = 1'b0;
    m_irq_enable_i     = 1'b0;
    mie_bypass_i       = 32'h0000_0800;
    instr_valid_i      = 1'b1;
    irq_i              = 32'h0000_0800;
    irq_sec_i          = 1'b1;
    @(posedge clk);
    #1;
    irq_i              = 32'h0000_0000;
    irq_sec_i          = 1'b0;
    #1;
    if (mip_o !== 32'h0000_0800 || irq_sec_ctrl_o !== 1'b1 || irq_req_ctrl_o !== 1'b1 || irq_ack_o !== 1'b1) begin
      fail_msg("1-cycle secure IRQ pulse in U-mode lost");
    end

    @(negedge clk);
    irq_i     = 32'h0000_0800;
    irq_sec_i = 1'b0;
    @(posedge clk);
    #1;
    irq_i     = 32'h0000_0000;
    irq_sec_i = 1'b1;
    #1;
    if (mip_o !== 32'h0000_0800 || irq_sec_ctrl_o !== 1'b0 || irq_req_ctrl_o !== 1'b0 || irq_ack_o !== 1'b0) begin
      fail_msg("Unsecure U-mode IRQ spuriously triggered on late irq_sec_i");
    end
    @(posedge clk);
    #1;
    irq_sec_i = 1'b0;
  endtask

  // 2. Hardware-loop counter underflow saturation and nested 2-loop priority & target selection
  task automatic test_hwloop_underflow_and_nested_priority();
    reset_and_boot_to_decode();

    write_hwloop(1'b0, 32'h0000_0100, 32'h0000_0108, 32'd0);
    write_hwloop(1'b1, 32'h0000_0100, 32'h0000_0110, 32'd3);

    @(negedge clk);
    instr_valid_i = 1'b1;
    id_ready_i    = 1'b1;
    pc_id_i       = 32'h0000_0100;
    @(posedge clk);
    #1;
    pc_id_i       = 32'h0000_0104;
    #1;
    if (hwlp_jump_o !== 1'b0) fail_msg("Expired Loop 0 pulsed hwlp_jump_o");
    @(posedge clk);
    #1;
    pc_id_i       = 32'h0000_0108;
    #1;
    if (hwlp_dec_cnt_o[0] !== 1'b0) fail_msg("Expired Loop 0 asserted hwlp_dec_cnt_o[0]");
    @(posedge clk);
    #1;
    if (hwlp_counter_o[0] !== 32'd0) fail_msg("Loop 0 counter underflowed");

    pc_id_i = 32'h0000_010C;
    #1;
    if (hwlp_jump_o !== 1'b1 || hwlp_targ_addr_o !== 32'h0000_0100) fail_msg("Loop 1 failed to jump at end[1]-4");
    @(posedge clk);
    #1;
    pc_id_i = 32'h0000_0110;
    #1;
    if (hwlp_dec_cnt_o !== 2'b10) fail_msg("Expected hwlp_dec_cnt_o=2'b10");
    @(posedge clk);
    #1;

    reset_and_boot_to_decode();
    write_hwloop(1'b0, 32'h0000_0204, 32'h0000_0210, 32'd2);
    write_hwloop(1'b1, 32'h0000_0200, 32'h0000_0210, 32'd3);

    @(negedge clk);
    instr_valid_i = 1'b1;
    id_ready_i    = 1'b1;
    pc_id_i       = 32'h0000_0204;
    @(posedge clk);
    #1;
    pc_id_i = 32'h0000_020C;
    #1;
    if (hwlp_jump_o !== 1'b1 || hwlp_targ_addr_o !== 32'h0000_0204) fail_msg("Shared end-4 Loop 0 priority failed");
    @(posedge clk);
    #1;
    pc_id_i = 32'h0000_0210;
    #1;
    if (hwlp_dec_cnt_o !== 2'b01) fail_msg("Shared end Loop 0 dec priority failed");
    @(posedge clk);
    #1;
    pc_id_i = 32'h0000_020C;
    #1;
    if (hwlp_jump_o !== 1'b1 || hwlp_targ_addr_o !== 32'h0000_0200) fail_msg("Shared end-4 Loop 1 target failed");
    @(posedge clk);
    #1;
    pc_id_i = 32'h0000_0210;
    @(posedge clk);
    #1;
    if (hwlp_counter_o[1] !== 32'd2 || hwlp_counter_o[0] !== 32'd0) fail_msg("Counters after shared end mismatch");

    reset_and_boot_to_decode();
    write_hwloop(1'b0, 32'h0000_0300, 32'h0000_0304, 32'd1);
    write_hwloop(1'b1, 32'h0000_0300, 32'h0000_0308, 32'd2);

    @(negedge clk);
    instr_valid_i = 1'b1;
    id_ready_i    = 1'b1;
    pc_id_i       = 32'h0000_0300;
    @(posedge clk);
    #1;
    pc_id_i       = 32'h0000_0304;
    #1;
    if (hwlp_jump_o !== 1'b1 || hwlp_targ_addr_o !== 32'h0000_0300) fail_msg("DECODE failed to enter DECODE_HWLOOP on expired inner loop");
  endtask

  // 3. PMP data_err_i exception cause retention & debug vector selection across FLUSH_WB
  task automatic test_data_err_flush_wb_and_debug_vector();
    reset_and_boot_to_decode();

    @(negedge clk);
    instr_valid_i = 1'b1;
    data_req_ex_i = 1'b1;
    data_we_ex_i  = 1'b1;
    data_err_i    = 1'b1;
    @(posedge clk);
    #1;
    data_err_i    = 1'b0;
    data_we_ex_i  = 1'b0;
    #1;
    if (pc_set_o !== 1'b1 || pc_mux_o !== PC_EXCEPTION || exc_pc_mux_o !== EXC_PC_EXCEPTION || exc_cause_o !== EXC_CAUSE_STORE_FAULT) begin
      fail_msg("Store data_err in FLUSH_WB wrong exc_cause_o/mux");
    end
    @(posedge clk);
    #1;

    @(negedge clk);
    data_req_ex_i = 1'b1;
    data_we_ex_i  = 1'b0;
    data_err_i    = 1'b1;
    @(posedge clk);
    #1;
    data_err_i    = 1'b0;
    data_we_ex_i  = 1'b1;
    #1;
    if (pc_set_o !== 1'b1 || pc_mux_o !== PC_EXCEPTION || exc_pc_mux_o !== EXC_PC_EXCEPTION || exc_cause_o !== EXC_CAUSE_LOAD_FAULT) begin
      fail_msg("Load data_err in FLUSH_WB wrong exc_cause_o/mux");
    end
    @(posedge clk);
    #1;
    data_we_ex_i  = 1'b0;

    @(negedge clk);
    debug_req_i   = 1'b1;
    instr_valid_i = 1'b1;
    @(posedge clk);
    #1;
    debug_req_i   = 1'b0;
    @(posedge clk);
    #1;
    @(posedge clk);
    #1;
    if (debug_mode_o !== 1'b1) fail_msg("Failed to enter debug_mode_o");

    @(negedge clk);
    data_err_i   = 1'b1;
    data_we_ex_i = 1'b1;
    @(posedge clk);
    #1;
    data_err_i   = 1'b0;
    data_we_ex_i = 1'b0;
    #1;
    if (pc_set_o !== 1'b1 || pc_mux_o !== PC_EXCEPTION || exc_pc_mux_o !== EXC_PC_DBE || exc_cause_o !== EXC_CAUSE_STORE_FAULT) begin
      fail_msg("Data error during debug_mode failed EXC_PC_DBE");
    end
  endtask

  int seed;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    test_sleep_unit_elw_and_debug_no_sleep();
    test_int_controller_wakeup_and_secure_align();
    test_hwloop_underflow_and_nested_priority();
    test_data_err_flush_wb_and_debug_vector();
    $display("PASS_CASE_4010 seed=%0d", seed);
    $finish;
  end

endmodule
