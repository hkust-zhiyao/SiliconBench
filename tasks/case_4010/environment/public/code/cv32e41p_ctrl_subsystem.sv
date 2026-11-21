// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e41p_ctrl_subsystem
  import cv32e41p_pkg::*;
#(
    parameter PULP_CLUSTER = 1,
    parameter PULP_XPULP   = 1,
    parameter PULP_SECURE  = 1,
    parameter N_HWLP       = 2,
    parameter N_HWLP_BITS  = $clog2(N_HWLP)
) (
    input  logic        clk,
    input  logic        clk_ungated_i,
    input  logic        rst_n,

    input  logic        fetch_enable_i,
    output logic        fetch_enable_o,
    input  logic        scan_cg_en_i,
    input  logic        if_busy_i,
    input  logic        lsu_busy_i,
    input  logic        apu_busy_i,
    input  logic        pulp_clock_en_i,
    input  logic        p_elw_start_i,
    input  logic        p_elw_finish_i,
    output logic        clk_gated_o,
    output logic        core_sleep_o,

    output logic        ctrl_busy_o,
    output logic        is_decoding_o,
    input  logic        is_fetch_failed_i,

    output logic        deassert_we_o,

    input  logic        illegal_insn_i,
    input  logic        ecall_insn_i,
    input  logic        mret_insn_i,
    input  logic        uret_insn_i,
    input  logic        dret_insn_i,
    input  logic        mret_dec_i,
    input  logic        uret_dec_i,
    input  logic        dret_dec_i,
    input  logic        wfi_i,
    input  logic        ebrk_insn_i,
    input  logic        fencei_insn_i,
    input  logic        csr_status_i,

    output logic        hwlp_mask_o,
    input  logic        instr_valid_i,
    output logic        instr_req_o,

    output logic        pc_set_o,
    output logic [ 3:0] pc_mux_o,
    output logic [ 2:0] exc_pc_mux_o,
    output logic [ 1:0] trap_addr_mux_o,

    input  logic [31:0] pc_id_i,
    input  logic        is_compressed_i,

    // Hardware loop register write interface
    input  logic [          31:0] hwlp_start_data_i,
    input  logic [          31:0] hwlp_end_data_i,
    input  logic [          31:0] hwlp_cnt_data_i,
    input  logic [           2:0] hwlp_we_i,
    input  logic [N_HWLP_BITS-1:0] hwlp_regid_i,

    output logic [N_HWLP-1:0][31:0] hwlp_start_addr_o,
    output logic [N_HWLP-1:0][31:0] hwlp_end_addr_o,
    output logic [N_HWLP-1:0][31:0] hwlp_counter_o,
    output logic [N_HWLP-1:0]       hwlp_dec_cnt_o,
    output logic                    hwlp_jump_o,
    output logic [          31:0]   hwlp_targ_addr_o,

    // LSU
    input  logic        data_req_ex_i,
    input  logic        data_we_ex_i,
    input  logic        data_misaligned_i,
    input  logic        data_load_event_i,
    input  logic        data_err_i,
    output logic        data_err_ack_o,

    // ALU / MUL / APU
    input  logic        mult_multicycle_i,
    input  logic        apu_en_i,
    input  logic        apu_read_dep_i,
    input  logic        apu_write_dep_i,
    output logic        apu_stall_o,

    // Jump/branch
    input  logic        branch_taken_ex_i,
    input  logic [ 1:0] ctrl_transfer_insn_in_id_i,
    input  logic [ 1:0] ctrl_transfer_insn_in_dec_i,

    // External Interrupts & CSR Interrupt Controls
    input  logic [31:0] irq_i,
    input  logic        irq_sec_i,
    input  logic [31:0] mie_bypass_i,
    output logic [31:0] mip_o,
    input  logic        m_irq_enable_i,
    input  logic        u_irq_enable_i,
    input  PrivLvl_t    current_priv_lvl_i,

    output logic        irq_req_ctrl_o,
    output logic        irq_sec_ctrl_o,
    output logic [ 4:0] irq_id_ctrl_o,
    output logic        irq_wu_ctrl_o,
    output logic        irq_ack_o,
    output logic [ 4:0] irq_id_o,
    output logic [ 4:0] exc_cause_o,

    // Debug
    output logic        debug_mode_o,
    output logic [ 2:0] debug_cause_o,
    output logic        debug_csr_save_o,
    input  logic        debug_req_i,
    input  logic        debug_single_step_i,
    input  logic        debug_ebreakm_i,
    input  logic        debug_ebreaku_i,
    input  logic        trigger_match_i,
    output logic        debug_p_elw_no_sleep_o,
    output logic        debug_wfi_no_sleep_o,
    output logic        debug_havereset_o,
    output logic        debug_running_o,
    output logic        debug_halted_o,

    // Wakeup & CSR save/restore
    output logic        wake_from_sleep_o,
    output logic        csr_save_if_o,
    output logic        csr_save_id_o,
    output logic        csr_save_ex_o,
    output logic [ 5:0] csr_cause_o,
    output logic        csr_irq_sec_o,
    output logic        csr_restore_mret_id_o,
    output logic        csr_restore_uret_id_o,
    output logic        csr_restore_dret_id_o,
    output logic        csr_save_cause_o,

    // Regfile & Forwarding
    input  logic        regfile_we_id_i,
    input  logic [ 5:0] regfile_alu_waddr_id_i,
    input  logic        regfile_we_ex_i,
    input  logic [ 5:0] regfile_waddr_ex_i,
    input  logic        regfile_we_wb_i,
    input  logic        regfile_alu_we_fw_i,

    output logic [ 1:0] operand_a_fw_mux_sel_o,
    output logic [ 1:0] operand_b_fw_mux_sel_o,
    output logic [ 1:0] operand_c_fw_mux_sel_o,

    input  logic        reg_d_ex_is_reg_a_i,
    input  logic        reg_d_ex_is_reg_b_i,
    input  logic        reg_d_ex_is_reg_c_i,
    input  logic        reg_d_wb_is_reg_a_i,
    input  logic        reg_d_wb_is_reg_b_i,
    input  logic        reg_d_wb_is_reg_c_i,
    input  logic        reg_d_alu_is_reg_a_i,
    input  logic        reg_d_alu_is_reg_b_i,
    input  logic        reg_d_alu_is_reg_c_i,

    // Stalls & readiness
    output logic        halt_if_o,
    output logic        halt_id_o,
    output logic        misaligned_stall_o,
    output logic        jr_stall_o,
    output logic        load_stall_o,

    input  logic        id_ready_i,
    input  logic        id_valid_i,
    input  logic        ex_valid_i,
    input  logic        wb_ready_i,

    output logic        perf_pipeline_stall_o
);

  logic       hwlp_valid;
  logic [2:0] hwlp_we_masked;

  assign hwlp_valid     = instr_valid_i & (id_ready_i | halt_id_o | branch_taken_ex_i);
  assign hwlp_we_masked = hwlp_we_i & ~{3{hwlp_mask_o}} & {3{id_ready_i}};

  cv32e41p_sleep_unit #(
      .PULP_CLUSTER(PULP_CLUSTER)
  ) sleep_unit_i (
      .clk_ungated_i         (clk_ungated_i),
      .rst_n                 (rst_n),
      .clk_gated_o           (clk_gated_o),
      .scan_cg_en_i          (scan_cg_en_i),
      .core_sleep_o          (core_sleep_o),
      .fetch_enable_i        (fetch_enable_i),
      .fetch_enable_o        (fetch_enable_o),
      .if_busy_i             (if_busy_i),
      .ctrl_busy_i           (ctrl_busy_o),
      .lsu_busy_i            (lsu_busy_i),
      .apu_busy_i            (apu_busy_i),
      .pulp_clock_en_i       (pulp_clock_en_i),
      .p_elw_start_i         (p_elw_start_i),
      .p_elw_finish_i        (p_elw_finish_i),
      .debug_p_elw_no_sleep_i(debug_p_elw_no_sleep_o),
      .wake_from_sleep_i     (wake_from_sleep_o)
  );

  cv32e41p_int_controller #(
      .PULP_SECURE(PULP_SECURE)
  ) int_controller_i (
      .clk               (clk),
      .rst_n             (rst_n),
      .irq_i             (irq_i),
      .irq_sec_i         (irq_sec_i),
      .irq_req_ctrl_o    (irq_req_ctrl_o),
      .irq_sec_ctrl_o    (irq_sec_ctrl_o),
      .irq_id_ctrl_o     (irq_id_ctrl_o),
      .irq_wu_ctrl_o     (irq_wu_ctrl_o),
      .mie_bypass_i      (mie_bypass_i),
      .mip_o             (mip_o),
      .m_ie_i            (m_irq_enable_i),
      .u_ie_i            (u_irq_enable_i),
      .current_priv_lvl_i(current_priv_lvl_i)
  );

  cv32e41p_hwloop_regs #(
      .N_REGS(N_HWLP)
  ) hwloop_regs_i (
      .clk              (clk),
      .rst_n            (rst_n),
      .hwlp_start_data_i(hwlp_start_data_i),
      .hwlp_end_data_i  (hwlp_end_data_i),
      .hwlp_cnt_data_i  (hwlp_cnt_data_i),
      .hwlp_we_i        (hwlp_we_masked),
      .hwlp_regid_i     (hwlp_regid_i),
      .valid_i          (hwlp_valid),
      .hwlp_dec_cnt_i   (hwlp_dec_cnt_o),
      .hwlp_start_addr_o(hwlp_start_addr_o),
      .hwlp_end_addr_o  (hwlp_end_addr_o),
      .hwlp_counter_o   (hwlp_counter_o)
  );

  cv32e41p_controller #(
      .PULP_CLUSTER(PULP_CLUSTER),
      .PULP_XPULP  (PULP_XPULP)
  ) controller_i (
      .clk                        (clk),
      .clk_ungated_i              (clk_ungated_i),
      .rst_n                      (rst_n),
      .fetch_enable_i             (fetch_enable_o),
      .ctrl_busy_o                (ctrl_busy_o),
      .is_decoding_o              (is_decoding_o),
      .is_fetch_failed_i          (is_fetch_failed_i),
      .deassert_we_o              (deassert_we_o),
      .illegal_insn_i             (illegal_insn_i),
      .ecall_insn_i               (ecall_insn_i),
      .mret_insn_i                (mret_insn_i),
      .uret_insn_i                (uret_insn_i),
      .dret_insn_i                (dret_insn_i),
      .mret_dec_i                 (mret_dec_i),
      .uret_dec_i                 (uret_dec_i),
      .dret_dec_i                 (dret_dec_i),
      .wfi_i                      (wfi_i),
      .ebrk_insn_i                (ebrk_insn_i),
      .fencei_insn_i              (fencei_insn_i),
      .csr_status_i               (csr_status_i),
      .hwlp_mask_o                (hwlp_mask_o),
      .instr_valid_i              (instr_valid_i),
      .instr_req_o                (instr_req_o),
      .pc_set_o                   (pc_set_o),
      .pc_mux_o                   (pc_mux_o),
      .exc_pc_mux_o               (exc_pc_mux_o),
      .trap_addr_mux_o            (trap_addr_mux_o),
      .pc_id_i                    (pc_id_i),
      .is_compressed_i            (is_compressed_i),
      .hwlp_start_addr_i          (hwlp_start_addr_o),
      .hwlp_end_addr_i            (hwlp_end_addr_o),
      .hwlp_counter_i             (hwlp_counter_o),
      .hwlp_dec_cnt_o             (hwlp_dec_cnt_o),
      .hwlp_jump_o                (hwlp_jump_o),
      .hwlp_targ_addr_o           (hwlp_targ_addr_o),
      .data_req_ex_i              (data_req_ex_i),
      .data_we_ex_i               (data_we_ex_i),
      .data_misaligned_i          (data_misaligned_i),
      .data_load_event_i          (data_load_event_i),
      .data_err_i                 (data_err_i),
      .data_err_ack_o             (data_err_ack_o),
      .mult_multicycle_i          (mult_multicycle_i),
      .apu_en_i                   (apu_en_i),
      .apu_read_dep_i             (apu_read_dep_i),
      .apu_write_dep_i            (apu_write_dep_i),
      .apu_stall_o                (apu_stall_o),
      .branch_taken_ex_i          (branch_taken_ex_i),
      .ctrl_transfer_insn_in_id_i (ctrl_transfer_insn_in_id_i),
      .ctrl_transfer_insn_in_dec_i(ctrl_transfer_insn_in_dec_i),
      .irq_req_ctrl_i             (irq_req_ctrl_o),
      .irq_sec_ctrl_i             (irq_sec_ctrl_o),
      .irq_id_ctrl_i              (irq_id_ctrl_o),
      .irq_wu_ctrl_i              (irq_wu_ctrl_o),
      .current_priv_lvl_i         (current_priv_lvl_i),
      .irq_ack_o                  (irq_ack_o),
      .irq_id_o                   (irq_id_o),
      .exc_cause_o                (exc_cause_o),
      .debug_mode_o               (debug_mode_o),
      .debug_cause_o              (debug_cause_o),
      .debug_csr_save_o           (debug_csr_save_o),
      .debug_req_i                (debug_req_i),
      .debug_single_step_i        (debug_single_step_i),
      .debug_ebreakm_i            (debug_ebreakm_i),
      .debug_ebreaku_i            (debug_ebreaku_i),
      .trigger_match_i            (trigger_match_i),
      .debug_p_elw_no_sleep_o     (debug_p_elw_no_sleep_o),
      .debug_wfi_no_sleep_o       (debug_wfi_no_sleep_o),
      .debug_havereset_o          (debug_havereset_o),
      .debug_running_o            (debug_running_o),
      .debug_halted_o             (debug_halted_o),
      .wake_from_sleep_o          (wake_from_sleep_o),
      .csr_save_if_o              (csr_save_if_o),
      .csr_save_id_o              (csr_save_id_o),
      .csr_save_ex_o              (csr_save_ex_o),
      .csr_cause_o                (csr_cause_o),
      .csr_irq_sec_o              (csr_irq_sec_o),
      .csr_restore_mret_id_o      (csr_restore_mret_id_o),
      .csr_restore_uret_id_o      (csr_restore_uret_id_o),
      .csr_restore_dret_id_o      (csr_restore_dret_id_o),
      .csr_save_cause_o           (csr_save_cause_o),
      .regfile_we_id_i            (regfile_we_id_i),
      .regfile_alu_waddr_id_i     (regfile_alu_waddr_id_i),
      .regfile_we_ex_i            (regfile_we_ex_i),
      .regfile_waddr_ex_i         (regfile_waddr_ex_i),
      .regfile_we_wb_i            (regfile_we_wb_i),
      .regfile_alu_we_fw_i        (regfile_alu_we_fw_i),
      .operand_a_fw_mux_sel_o     (operand_a_fw_mux_sel_o),
      .operand_b_fw_mux_sel_o     (operand_b_fw_mux_sel_o),
      .operand_c_fw_mux_sel_o     (operand_c_fw_mux_sel_o),
      .reg_d_ex_is_reg_a_i        (reg_d_ex_is_reg_a_i),
      .reg_d_ex_is_reg_b_i        (reg_d_ex_is_reg_b_i),
      .reg_d_ex_is_reg_c_i        (reg_d_ex_is_reg_c_i),
      .reg_d_wb_is_reg_a_i        (reg_d_wb_is_reg_a_i),
      .reg_d_wb_is_reg_b_i        (reg_d_wb_is_reg_b_i),
      .reg_d_wb_is_reg_c_i        (reg_d_wb_is_reg_c_i),
      .reg_d_alu_is_reg_a_i       (reg_d_alu_is_reg_a_i),
      .reg_d_alu_is_reg_b_i       (reg_d_alu_is_reg_b_i),
      .reg_d_alu_is_reg_c_i       (reg_d_alu_is_reg_c_i),
      .halt_if_o                  (halt_if_o),
      .halt_id_o                  (halt_id_o),
      .misaligned_stall_o         (misaligned_stall_o),
      .jr_stall_o                 (jr_stall_o),
      .load_stall_o               (load_stall_o),
      .id_ready_i                 (id_ready_i),
      .id_valid_i                 (id_valid_i),
      .ex_valid_i                 (ex_valid_i),
      .wb_ready_i                 (wb_ready_i),
      .perf_pipeline_stall_o      (perf_pipeline_stall_o)
  );

endmodule
