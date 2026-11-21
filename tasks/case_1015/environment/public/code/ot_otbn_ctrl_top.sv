// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenTitan OTBN Start/Stop Secure Wipe, Loop Stack & Call Stack Subsystem Top (`ot_otbn_ctrl_top`)

module ot_otbn_ctrl_top
  import otbn_pkg::*;
  import prim_mubi_pkg::*;
#(
  parameter int ImemAddrWidth  = 12,
  parameter int CallStackWidth = 32,
  parameter int CallStackDepth = 8
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic                      start_i,
  input  mubi4_t                    escalate_en_i,
  input  mubi4_t                    rma_req_i,
  output mubi4_t                    rma_ack_o,
  output logic                      controller_start_o,
  output logic                      urnd_reseed_req_o,
  input  logic                      urnd_reseed_ack_i,
  output logic                      urnd_reseed_err_o,
  output logic                      urnd_advance_o,
  output logic                      urnd_must_advance_o,
  input  logic                      secure_wipe_req_i,
  output logic                      secure_wipe_ack_o,
  output logic                      secure_wipe_running_o,
  output logic                      done_o,
  output logic                      sec_wipe_wdr_o,
  output logic                      sec_wipe_wdr_urnd_o,
  output logic                      sec_wipe_base_o,
  output logic                      sec_wipe_base_urnd_o,
  output logic [4:0]                sec_wipe_addr_o,
  output logic                      sec_wipe_mac_urnd_o,
  output logic                      sec_wipe_mod_urnd_o,
  output logic                      sec_wipe_zero_o,
  output logic                      ispr_init_o,
  output logic                      state_reset_o,
  output logic                      insn_cnt_clear_int_o,
  output logic                      start_stop_fatal_error_o,
  input  logic                      insn_valid_i,
  input  logic [ImemAddrWidth-1:0]  insn_addr_i,
  input  logic [ImemAddrWidth-1:0]  next_insn_addr_i,
  input  logic                      loop_start_req_i,
  input  logic                      loop_start_commit_i,
  input  logic [11:0]               loop_bodysize_i,
  input  logic [31:0]               loop_iterations_i,
  input  logic [ImemAddrWidth-1:0]  loop_end_addr_predec_i,
  output logic                      loop_jump_o,
  output logic [ImemAddrWidth-1:0]  loop_jump_addr_o,
  output logic                      loop_sw_err_o,
  output logic                      loop_hw_err_o,
  output logic                      loop_predec_err_o,
  output logic                      prefetch_loop_active_o,
  output logic [31:0]               prefetch_loop_iterations_o,
  output logic [ImemAddrWidth:0]    prefetch_loop_end_addr_o,
  output logic [ImemAddrWidth-1:0]  prefetch_loop_jump_addr_o,
  input  logic                      jump_or_branch_i,
  input  logic                      otbn_stall_i,
  input  logic                      call_stack_push_i,
  input  logic [CallStackWidth-1:0] call_stack_push_data_i,
  input  logic                      call_stack_pop_i,
  input  logic                      call_stack_commit_i,
  output logic                      call_stack_full_o,
  output logic                      call_stack_cnt_err_o,
  output logic [CallStackWidth-1:0] call_stack_top_data_o,
  output logic                      call_stack_top_valid_o,
  output logic [CallStackWidth-1:0] call_stack_next_top_data_o,
  output logic                      call_stack_next_top_valid_o
);

  logic state_reset;
  logic sec_wipe_zero;
  assign state_reset_o   = state_reset;
  assign sec_wipe_zero_o = sec_wipe_zero;

  otbn_start_stop_control u_start_stop (
    .clk_i                       (clk_i),
    .rst_ni                      (rst_ni),
    .start_i                     (start_i),
    .escalate_en_i               (escalate_en_i),
    .rma_req_i                   (rma_req_i),
    .rma_ack_o                   (rma_ack_o),
    .controller_start_o          (controller_start_o),
    .urnd_reseed_req_o           (urnd_reseed_req_o),
    .urnd_reseed_ack_i           (urnd_reseed_ack_i),
    .urnd_reseed_err_o           (urnd_reseed_err_o),
    .urnd_advance_o              (urnd_advance_o),
    .urnd_must_advance_o         (urnd_must_advance_o),
    .secure_wipe_req_i           (secure_wipe_req_i),
    .secure_wipe_ack_o           (secure_wipe_ack_o),
    .secure_wipe_running_o       (secure_wipe_running_o),
    .done_o                      (done_o),
    .sec_wipe_wdr_o              (sec_wipe_wdr_o),
    .sec_wipe_wdr_urnd_o         (sec_wipe_wdr_urnd_o),
    .sec_wipe_base_o             (sec_wipe_base_o),
    .sec_wipe_base_urnd_o        (sec_wipe_base_urnd_o),
    .sec_wipe_addr_o             (sec_wipe_addr_o),
    .sec_wipe_mac_urnd_o         (sec_wipe_mac_urnd_o),
    .sec_wipe_mod_urnd_o         (sec_wipe_mod_urnd_o),
    .sec_wipe_zero_o             (sec_wipe_zero),
    .sec_wipe_mai_in0_s0_urnd_o  (),
    .sec_wipe_mai_in0_s1_urnd_o  (),
    .sec_wipe_mai_in1_s0_urnd_o  (),
    .sec_wipe_mai_in1_s1_urnd_o  (),
    .sec_wipe_mai_res_s0_urnd_o  (),
    .sec_wipe_mai_res_s1_urnd_o  (),
    .sec_wipe_kmac_data_s0_urnd_o(),
    .sec_wipe_kmac_data_s1_urnd_o(),
    .ispr_init_o                 (ispr_init_o),
    .state_reset_o               (state_reset),
    .insn_cnt_clear_int_o        (insn_cnt_clear_int_o),
    .fatal_error_o               (start_stop_fatal_error_o)
  );

  otbn_loop_controller #(
    .ImemAddrWidth(ImemAddrWidth)
  ) u_loop_ctrl (
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    .state_reset_i             (state_reset | sec_wipe_zero),
    .insn_valid_i              (insn_valid_i),
    .insn_addr_i               (insn_addr_i),
    .next_insn_addr_i          (next_insn_addr_i),
    .loop_start_req_i          (loop_start_req_i),
    .loop_start_commit_i       (loop_start_commit_i),
    .loop_bodysize_i           (loop_bodysize_i),
    .loop_iterations_i         (loop_iterations_i),
    .loop_end_addr_predec_i    (loop_end_addr_predec_i),
    .loop_jump_o               (loop_jump_o),
    .loop_jump_addr_o          (loop_jump_addr_o),
    .sw_err_o                  (loop_sw_err_o),
    .hw_err_o                  (loop_hw_err_o),
    .predec_err_o              (loop_predec_err_o),
    .prefetch_loop_active_o    (prefetch_loop_active_o),
    .prefetch_loop_iterations_o(prefetch_loop_iterations_o),
    .prefetch_loop_end_addr_o  (prefetch_loop_end_addr_o),
    .prefetch_loop_jump_addr_o (prefetch_loop_jump_addr_o),
    .jump_or_branch_i          (jump_or_branch_i),
    .otbn_stall_i              (otbn_stall_i)
  );

  otbn_stack #(
    .StackWidth(CallStackWidth),
    .StackDepth(CallStackDepth)
  ) u_call_stack (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .full_o          (call_stack_full_o),
    .cnt_err_o       (call_stack_cnt_err_o),
    .clear_i         (state_reset | sec_wipe_zero),
    .push_i          (call_stack_push_i),
    .push_data_i     (call_stack_push_data_i),
    .pop_i           (call_stack_pop_i),
    .top_data_o      (call_stack_top_data_o),
    .top_valid_o     (call_stack_top_valid_o),
    .commit_i        (call_stack_commit_i),
    .stack_wr_idx_o  (),
    .stack_write_o   (),
    .stack_rd_idx_o  (),
    .stack_read_o    (),
    .next_top_data_o (call_stack_next_top_data_o),
    .next_top_valid_o(call_stack_next_top_valid_o)
  );

endmodule
