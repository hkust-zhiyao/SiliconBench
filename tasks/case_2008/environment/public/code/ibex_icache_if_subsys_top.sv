// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"
`include "dv_fcov_macros.svh"

module ibex_icache_if_subsys_top import ibex_pkg::*; import ibex_cheriot_pkg::*; #(
  parameter int unsigned TagSizeECC  = IC_TAG_SIZE + 6,
  parameter int unsigned BusSizeECC  = BUS_SIZE + 7,
  parameter int unsigned LineSizeECC = BusSizeECC * IC_LINE_BEATS
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  ibex_mubi_t                   cheriot_enable_i,
  input  logic [31:0]                  boot_addr_i,
  input  logic                         req_i,
  input  logic                         debug_mode_i,

  output logic                         instr_req_o,
  output logic [31:0]                  instr_addr_o,
  input  logic                         instr_gnt_i,
  input  logic                         instr_rvalid_i,
  input  logic [38:0]                  instr_rdata_i,
  input  logic                         instr_bus_err_i,
  output logic                         instr_intg_err_o,

  output logic [IC_NUM_WAYS-1:0]       ic_tag_req_o,
  output logic                         ic_tag_write_o,
  output logic [IC_INDEX_W-1:0]        ic_tag_addr_o,
  output logic [TagSizeECC-1:0]        ic_tag_wdata_o,
  input  logic [TagSizeECC-1:0]        ic_tag_rdata_i [IC_NUM_WAYS],
  output logic [IC_NUM_WAYS-1:0]       ic_data_req_o,
  output logic                         ic_data_write_o,
  output logic [IC_INDEX_W-1:0]        ic_data_addr_o,
  output logic [LineSizeECC-1:0]       ic_data_wdata_o,
  input  logic [LineSizeECC-1:0]       ic_data_rdata_i [IC_NUM_WAYS],
  input  logic                         ic_scr_key_valid_i,
  output logic                         ic_scr_key_req_o,

  output logic                         instr_valid_id_o,
  output logic                         instr_new_id_o,
  output logic [31:0]                  instr_rdata_id_o,
  output logic [31:0]                  instr_rdata_alu_id_o,
  output logic [15:0]                  instr_rdata_c_id_o,
  output logic                         instr_is_compressed_id_o,
  output instr_exp_e                   instr_gets_expanded_id_o,
  output logic [15:0]                  instr_expanded_id_o,
  output logic                         instr_bp_taken_o,
  output logic                         instr_fetch_err_o,
  output logic                         instr_fetch_err_plus2_o,
  output logic                         illegal_c_insn_id_o,
  output logic                         instr_fetch_cheriot_acc_vio_o,
  output logic                         instr_fetch_cheriot_bound_vio_o,
  output logic                         dummy_instr_id_o,
  output logic [31:0]                  pc_if_o,
  output logic [31:0]                  pc_id_o,
  input  logic                         pmp_err_if_i,
  input  logic                         pmp_err_if_plus2_i,

  input  logic                         instr_valid_clear_i,
  input  logic                         pc_set_i,
  input  pc_sel_e                      pc_mux_i,
  input  logic                         nt_branch_mispredict_i,
  input  logic [31:0]                  nt_branch_addr_i,
  input  exc_pc_sel_e                  exc_pc_mux_i,
  input  exc_cause_t                   exc_cause,
  input  logic                         dummy_instr_en_i,
  input  logic [2:0]                   dummy_instr_mask_i,
  input  logic                         dummy_instr_seed_en_i,
  input  logic [31:0]                  dummy_instr_seed_i,
  input  logic                         icache_enable_i,
  input  logic                         icache_inval_i,
  output logic                         icache_ecc_error_o,

  input  logic [31:0]                  branch_target_ex_i,
  input  logic [31:0]                  csr_mepc_i,
  input  logic [31:0]                  csr_depc_i,
  input  logic [31:0]                  csr_mtvec_i,
  output logic                         csr_mtvec_init_o,
  input  logic                         id_in_ready_i,
  output logic                         pc_mismatch_alert_o,
  output logic                         if_busy_o,
  input  decoded_cap_t                 pcc_cap_i,

  // Transparent combinational monitoring channels constrained via constraints.json
  input  logic [7:0]                   scr_mon_in,
  output logic [7:0]                   scr_mon_out,
  input  logic [7:0]                   pmp_mon_in,
  output logic [7:0]                   pmp_mon_out
);

  assign scr_mon_out = scr_mon_in;
  assign pmp_mon_out = pmp_mon_in;

  ibex_if_stage #(
    .BaseIsa             (BaseIsaRV32IorCHERIoT),
    .DmHaltAddr          (32'h1A11_0800),
    .DmExceptionAddr     (32'h1A11_0808),
    .DummyInstructions   (1'b1),
    .ICache              (1'b1),
    .RV32ZC              (RV32ZcaZcbZcmp),
    .ICacheECC           (1'b1),
    .ICacheTweakInfection(1'b1),
    .BusSizeECC          (BusSizeECC),
    .TagSizeECC          (TagSizeECC),
    .LineSizeECC         (LineSizeECC),
    .PCIncrCheck         (1'b1),
    .ResetAll            (1'b1),
    .BranchPredictor     (1'b1),
    .MemECC              (1'b1),
    .MemDataWidth        (39),
    .RV32E               (1'b0)
  ) u_if_stage (.*);

endmodule
