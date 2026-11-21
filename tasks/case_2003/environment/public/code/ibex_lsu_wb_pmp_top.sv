// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"
`include "dv_fcov_macros.svh"

module ibex_lsu_wb_pmp_top import ibex_pkg::*; import ibex_cheriot_pkg::*; #(
  parameter int unsigned PMPGranularity = 0,
  parameter int unsigned PMPNumRegions  = 4
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,
  input  ibex_mubi_t               cheriot_enable_i,
  input  logic                     debug_mode_i,

  // PMP CSR configuration & instruction-side check channel
  input  pmp_cfg_t                 csr_pmp_cfg_i     [PMPNumRegions],
  input  logic [PMP_ADDR_MSB:0]    csr_pmp_addr_i    [PMPNumRegions],
  input  pmp_mseccfg_t             csr_pmp_mseccfg_i,
  input  priv_lvl_e                priv_mode_if_i,
  input  priv_lvl_e                priv_mode_lsu_i,
  input  logic [PMP_ADDR_MSB:0]    pmp_req_addr_if_i,
  output logic                     pmp_req_err_if_o,
  output logic                     pmp_req_err_dside_o,

  // Data memory OBI interface (with 39-bit SECDED ECC word)
  output logic                     data_req_o,
  input  logic                     data_gnt_i,
  input  logic                     data_rvalid_i,
  input  logic                     data_bus_err_i,
  output logic [31:0]              data_addr_o,
  output logic                     data_we_o,
  output logic [3:0]               data_be_o,
  output logic [38:0]              data_wdata_o,
  output logic                     data_tag_o,
  input  logic [38:0]              data_rdata_i,
  input  logic                     data_tag_i,

  // ID/EX to LSU request interface
  input  logic                     lsu_req_i,
  input  logic                     lsu_we_i,
  input  logic                     lsu_is_cap_i,
  input  logic                     lsu_cheriot_err_i,
  input  logic [1:0]               lsu_type_i,
  input  logic [31:0]              lsu_wdata_i,
  input  cap_t                     lsu_wcap_i,
  input  cap_clrperm_t             lsu_lc_clrperm_i,
  input  logic                     lsu_sign_ext_i,
  input  logic [31:0]              base_addr_ex_i,

  output logic                     addr_incr_req_o,
  output logic [31:0]              addr_last_o,
  output logic                     lsu_req_done_o,
  output logic                     lsu_resp_valid_o,
  output logic                     load_err_o,
  output logic                     load_resp_intg_err_o,
  output logic                     store_err_o,
  output logic                     store_resp_intg_err_o,
  output logic                     lsu_err_is_cheriot_o,
  output logic                     lsu_busy_o,
  output logic                     perf_load_o,
  output logic                     perf_store_o,

  // ID/EX to Writeback stage interface
  input  logic                     en_wb_i,
  input  wb_instr_type_e           instr_type_wb_i,
  input  logic [31:0]              pc_id_i,
  input  logic                     instr_is_compressed_id_i,
  input  logic                     instr_perf_count_id_i,
  input  logic                     instr_is_cheriot_i,
  input  logic                     cheriot_load_i,
  input  logic                     cheriot_store_i,
  input  logic [4:0]               rf_waddr_id_i,
  input  logic [31:0]              rf_wdata_id_i,
  input  logic                     rf_we_id_i,
  input  logic                     cheriot_rf_we_i,
  input  logic [31:0]              cheriot_rf_wdata_i,
  input  cap_t                     cheriot_rf_wcap_i,
  input  logic                     dummy_instr_id_i,

  // Writeback outputs
  output logic                     ready_wb_o,
  output logic                     rf_write_wb_o,
  output logic                     outstanding_load_wb_o,
  output logic                     outstanding_store_wb_o,
  output logic [31:0]              pc_wb_o,
  output logic                     perf_instr_ret_wb_o,
  output logic                     perf_instr_ret_compressed_wb_o,
  output logic                     perf_instr_ret_wb_spec_o,
  output logic                     perf_instr_ret_compressed_wb_spec_o,
  output logic [31:0]              rf_wdata_fwd_wb_o,
  output cap_t                     rf_wcap_fwd_wb_o,
  output logic [4:0]               rf_waddr_wb_o,
  output logic [31:0]              rf_wdata_wb_o,
  output cap_t                     rf_wcap_wb_o,
  output logic                     rf_we_wb_o,
  output logic                     dummy_instr_wb_o,
  output logic                     instr_done_wb_o
);

  logic [31:0] adder_result_ex;
  logic [31:0] lsu_rdata;
  cap_t        lsu_rcap;
  logic        lsu_rdata_valid;
  logic        lsu_resp_err;

  priv_lvl_e            pmp_priv_mode [2];
  logic [PMP_ADDR_MSB:0] pmp_req_addr  [2];
  pmp_req_e             pmp_req_type  [2];
  logic                 pmp_req_err   [2];

  // AGU mux: during second phase of misaligned or capability access, increment last aligned address by 4
  assign adder_result_ex = addr_incr_req_o ? (addr_last_o + 32'd4) : base_addr_ex_i;

  assign pmp_priv_mode[0] = priv_mode_if_i;
  assign pmp_priv_mode[1] = priv_mode_lsu_i;
  assign pmp_req_addr[0]  = pmp_req_addr_if_i;
  assign pmp_req_addr[1]  = {2'b00, data_addr_o};
  assign pmp_req_type[0]  = PMP_ACC_EXEC;
  assign pmp_req_type[1]  = data_we_o ? PMP_ACC_WRITE : PMP_ACC_READ;

  assign pmp_req_err_if_o    = pmp_req_err[0];
  assign pmp_req_err_dside_o = pmp_req_err[1];

  ibex_pmp #(
    .DmBaseAddr    (32'h1A110000),
    .DmAddrMask    (32'h00000FFF),
    .PMPGranularity(PMPGranularity),
    .PMPNumChan    (2),
    .PMPNumRegions (PMPNumRegions)
  ) u_pmp (
    .csr_pmp_cfg_i    (csr_pmp_cfg_i),
    .csr_pmp_addr_i   (csr_pmp_addr_i),
    .csr_pmp_mseccfg_i(csr_pmp_mseccfg_i),
    .debug_mode_i     (debug_mode_i),
    .priv_mode_i      (pmp_priv_mode),
    .pmp_req_addr_i   (pmp_req_addr),
    .pmp_req_type_i   (pmp_req_type),
    .pmp_req_err_o    (pmp_req_err)
  );

  ibex_load_store_unit #(
    .BaseIsa     (BaseIsaRV32IorCHERIoT),
    .MemECC      (1'b1),
    .MemDataWidth(39)
  ) u_lsu (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .cheriot_enable_i     (cheriot_enable_i),
    .data_req_o           (data_req_o),
    .data_gnt_i           (data_gnt_i),
    .data_rvalid_i        (data_rvalid_i),
    .data_bus_err_i       (data_bus_err_i),
    .data_pmp_err_i       (pmp_req_err[1]),
    .data_addr_o          (data_addr_o),
    .data_we_o            (data_we_o),
    .data_be_o            (data_be_o),
    .data_wdata_o         (data_wdata_o),
    .data_tag_o           (data_tag_o),
    .data_rdata_i         (data_rdata_i),
    .data_tag_i           (data_tag_i),
    .lsu_we_i             (lsu_we_i),
    .lsu_is_cap_i         (lsu_is_cap_i),
    .lsu_cheriot_err_i    (lsu_cheriot_err_i),
    .lsu_type_i           (lsu_type_i),
    .lsu_wdata_i          (lsu_wdata_i),
    .lsu_wcap_i           (lsu_wcap_i),
    .lsu_lc_clrperm_i     (lsu_lc_clrperm_i),
    .lsu_sign_ext_i       (lsu_sign_ext_i),
    .lsu_rcap_o           (lsu_rcap),
    .lsu_rdata_o          (lsu_rdata),
    .lsu_rdata_valid_o    (lsu_rdata_valid),
    .lsu_req_i            (lsu_req_i),
    .adder_result_ex_i    (adder_result_ex),
    .addr_incr_req_o      (addr_incr_req_o),
    .addr_last_o          (addr_last_o),
    .lsu_req_done_o       (lsu_req_done_o),
    .lsu_resp_valid_o     (lsu_resp_valid_o),
    .load_err_o           (load_err_o),
    .load_resp_intg_err_o (load_resp_intg_err_o),
    .store_err_o          (store_err_o),
    .store_resp_intg_err_o(store_resp_intg_err_o),
    .lsu_err_is_cheriot_o (lsu_err_is_cheriot_o),
    .busy_o               (lsu_busy_o),
    .perf_load_o          (perf_load_o),
    .perf_store_o         (perf_store_o)
  );

  assign lsu_resp_err = load_err_o | store_err_o | load_resp_intg_err_o | store_resp_intg_err_o;

  ibex_wb_stage #(
    .ResetAll         (1'b1),
    .WritebackStage   (1'b1),
    .DummyInstructions(1'b1)
  ) u_wb (
    .clk_i                              (clk_i),
    .rst_ni                             (rst_ni),
    .en_wb_i                            (en_wb_i),
    .instr_type_wb_i                    (instr_type_wb_i),
    .pc_id_i                            (pc_id_i),
    .instr_is_compressed_id_i           (instr_is_compressed_id_i),
    .instr_perf_count_id_i              (instr_perf_count_id_i),
    .instr_is_cheriot_i                 (instr_is_cheriot_i),
    .cheriot_load_i                     (cheriot_load_i),
    .cheriot_store_i                    (cheriot_store_i),
    .ready_wb_o                         (ready_wb_o),
    .rf_write_wb_o                      (rf_write_wb_o),
    .outstanding_load_wb_o              (outstanding_load_wb_o),
    .outstanding_store_wb_o             (outstanding_store_wb_o),
    .pc_wb_o                            (pc_wb_o),
    .perf_instr_ret_wb_o                (perf_instr_ret_wb_o),
    .perf_instr_ret_compressed_wb_o     (perf_instr_ret_compressed_wb_o),
    .perf_instr_ret_wb_spec_o           (perf_instr_ret_wb_spec_o),
    .perf_instr_ret_compressed_wb_spec_o(perf_instr_ret_compressed_wb_spec_o),
    .rf_waddr_id_i                      (rf_waddr_id_i),
    .rf_wdata_id_i                      (rf_wdata_id_i),
    .rf_we_id_i                         (rf_we_id_i),
    .cheriot_rf_we_i                    (cheriot_rf_we_i),
    .cheriot_rf_wdata_i                 (cheriot_rf_wdata_i),
    .cheriot_rf_wcap_i                  (cheriot_rf_wcap_i),
    .dummy_instr_id_i                   (dummy_instr_id_i),
    .rf_wdata_lsu_i                     (lsu_rdata),
    .rf_wcap_lsu_i                      (lsu_rcap),
    .rf_we_lsu_i                        (lsu_rdata_valid),
    .rf_wdata_fwd_wb_o                  (rf_wdata_fwd_wb_o),
    .rf_wcap_fwd_wb_o                   (rf_wcap_fwd_wb_o),
    .rf_waddr_wb_o                      (rf_waddr_wb_o),
    .rf_wdata_wb_o                      (rf_wdata_wb_o),
    .rf_wcap_wb_o                       (rf_wcap_wb_o),
    .rf_we_wb_o                         (rf_we_wb_o),
    .dummy_instr_wb_o                   (dummy_instr_wb_o),
    .lsu_resp_valid_i                   (lsu_resp_valid_o),
    .lsu_resp_err_i                     (lsu_resp_err),
    .instr_done_wb_o                    (instr_done_wb_o)
  );

endmodule
