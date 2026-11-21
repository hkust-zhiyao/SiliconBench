// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenTitan DOE Mailbox Subsystem Top (`ot_mbx_top`)

module ot_mbx_top #(
  parameter int unsigned CfgSramAddrWidth   = 32,
  parameter int unsigned CfgSramDataWidth   = 32,
  parameter int unsigned CfgObjectSizeWidth = 11
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          hostif_control_abort_clear_i,
  input  logic                          mbx_error_set_i,
  input  logic                          hostif_range_valid_write_i,
  input  logic                          hostif_range_valid_i,
  input  logic [CfgSramAddrWidth-1:0]   hostif_imbx_base_i,
  input  logic [CfgSramAddrWidth-1:0]   hostif_imbx_limit_i,
  input  logic [CfgSramAddrWidth-1:0]   hostif_ombx_base_i,
  input  logic [CfgSramAddrWidth-1:0]   hostif_ombx_limit_i,
  input  logic                          sysif_status_busy_i,
  input  logic                          sysif_status_ready_i,
  input  logic                          sysif_control_go_set_i,
  input  logic                          sysif_control_abort_set_i,
  input  logic                          sysif_data_write_valid_i,
  input  logic [CfgSramDataWidth-1:0]   imbx_write_data_i,
  input  logic                          sysif_read_data_read_valid_i,
  input  logic                          sysif_read_data_write_valid_i,
  input  logic                          hostif_ombx_object_size_write_i,
  input  logic [CfgObjectSizeWidth-1:0] hostif_ombx_object_size_i,
  output logic                          hostif_ombx_object_size_update_o,
  output logic [CfgObjectSizeWidth-1:0] hostif_ombx_object_size_o,
  output logic [CfgSramDataWidth-1:0]   ombx_read_data_o,
  output logic                          imbx_state_error_o,
  output logic                          imbx_pending_o,
  output logic                          imbx_irq_ready_o,
  output logic                          imbx_irq_abort_o,
  output logic                          imbx_status_busy_update_o,
  output logic                          imbx_status_busy_o,
  output logic                          imbx_overflow_error_set_o,
  output logic                          ombx_state_error_o,
  output logic                          ombx_doe_intr_ready_set_o,
  output logic                          ombx_pending_o,
  output logic                          ombx_status_ready_update_o,
  output logic                          ombx_status_ready_o,
  output tlul_pkg::tl_h2d_t             tl_host_o,
  input  tlul_pkg::tl_d2h_t             tl_host_i,
  output logic                          intg_err_o,
  output logic                          sram_err_o
);

  logic                        sys_read_all;
  logic                        imbx_sram_write_req, imbx_sram_write_gnt, imbx_sram_all_vld_rcvd;
  logic [CfgSramAddrWidth-1:0] imbx_sram_write_ptr;
  logic                        ombx_sram_read_req, ombx_sram_read_gnt, ombx_sram_read_resp_vld;
  logic [CfgSramAddrWidth-1:0] ombx_sram_read_ptr;
  logic [CfgSramDataWidth-1:0] ombx_sram_read_resp;

  mbx_imbx #(
    .CfgSramAddrWidth(CfgSramAddrWidth),
    .CfgSramDataWidth(CfgSramDataWidth)
  ) u_imbx (
    .clk_i                       (clk_i),
    .rst_ni                      (rst_ni),
    .imbx_state_error_o          (imbx_state_error_o),
    .imbx_pending_o              (imbx_pending_o),
    .imbx_irq_ready_o            (imbx_irq_ready_o),
    .imbx_irq_abort_o            (imbx_irq_abort_o),
    .imbx_status_busy_update_o   (imbx_status_busy_update_o),
    .imbx_status_busy_o          (imbx_status_busy_o),
    .imbx_overflow_error_set_o   (imbx_overflow_error_set_o),
    .hostif_control_abort_clear_i(hostif_control_abort_clear_i),
    .mbx_error_set_i             (mbx_error_set_i),
    .hostif_range_valid_write_i  (hostif_range_valid_write_i),
    .hostif_range_valid_i        (hostif_range_valid_i),
    .hostif_base_i               (hostif_imbx_base_i),
    .hostif_limit_i              (hostif_imbx_limit_i),
    .sys_read_all_i              (sys_read_all),
    .sysif_status_busy_i         (sysif_status_busy_i),
    .sysif_control_go_set_i      (sysif_control_go_set_i),
    .sysif_control_abort_set_i   (sysif_control_abort_set_i),
    .sysif_data_write_valid_i    (sysif_data_write_valid_i),
    .hostif_sram_write_req_o     (imbx_sram_write_req),
    .hostif_sram_write_gnt_i     (imbx_sram_write_gnt),
    .hostif_sram_all_vld_rcvd_i  (imbx_sram_all_vld_rcvd),
    .hostif_sram_write_ptr_o     (imbx_sram_write_ptr)
  );

  mbx_ombx #(
    .CfgSramAddrWidth  (CfgSramAddrWidth),
    .CfgSramDataWidth  (CfgSramDataWidth),
    .CfgObjectSizeWidth(CfgObjectSizeWidth)
  ) u_ombx (
    .clk_i                            (clk_i),
    .rst_ni                           (rst_ni),
    .ombx_state_error_o               (ombx_state_error_o),
    .ombx_doe_intr_ready_set_o        (ombx_doe_intr_ready_set_o),
    .ombx_pending_o                   (ombx_pending_o),
    .ombx_status_ready_update_o       (ombx_status_ready_update_o),
    .ombx_status_ready_o              (ombx_status_ready_o),
    .hostif_range_valid_write_i       (hostif_range_valid_write_i),
    .hostif_range_valid_i             (hostif_range_valid_i),
    .hostif_base_i                    (hostif_ombx_base_i),
    .hostif_limit_i                   (hostif_ombx_limit_i),
    .sys_read_all_o                   (sys_read_all),
    .sysif_status_ready_i             (sysif_status_ready_i),
    .hostif_control_abort_clear_i     (hostif_control_abort_clear_i),
    .mbx_error_set_i                  (mbx_error_set_i),
    .sysif_control_abort_set_i        (sysif_control_abort_set_i),
    .sysif_read_data_read_valid_i     (sysif_read_data_read_valid_i),
    .sysif_read_data_write_valid_i    (sysif_read_data_write_valid_i),
    .hostif_ombx_object_size_write_i  (hostif_ombx_object_size_write_i),
    .hostif_ombx_object_size_i        (hostif_ombx_object_size_i),
    .hostif_ombx_object_size_update_o (hostif_ombx_object_size_update_o),
    .hostif_ombx_object_size_o        (hostif_ombx_object_size_o),
    .ombx_read_data_o                 (ombx_read_data_o),
    .ombx_sram_read_req_o             (ombx_sram_read_req),
    .ombx_sram_read_gnt_i             (ombx_sram_read_gnt),
    .ombx_sram_read_ptr_o             (ombx_sram_read_ptr),
    .ombx_sram_read_resp_valid_i      (ombx_sram_read_resp_vld),
    .ombx_sram_read_resp_i            (ombx_sram_read_resp)
  );

  mbx_sramrwarb #(
    .CfgSramAddrWidth(CfgSramAddrWidth),
    .CfgSramDataWidth(CfgSramDataWidth)
  ) u_arb (
    .clk_i                       (clk_i),
    .rst_ni                      (rst_ni),
    .tl_host_o                   (tl_host_o),
    .tl_host_i                   (tl_host_i),
    .intg_err_o                  (intg_err_o),
    .sram_err_o                  (sram_err_o),
    .hostif_control_abort_clear_i(hostif_control_abort_clear_i),
    .imbx_sram_write_req_i       (imbx_sram_write_req),
    .imbx_sram_write_gnt_o       (imbx_sram_write_gnt),
    .imbx_sram_write_ptr_i       (imbx_sram_write_ptr),
    .imbx_write_data_i           (imbx_write_data_i),
    .imbx_sram_all_vld_rcvd_o    (imbx_sram_all_vld_rcvd),
    .ombx_sram_read_req_i        (ombx_sram_read_req),
    .ombx_sram_read_gnt_o        (ombx_sram_read_gnt),
    .ombx_sram_read_ptr_i        (ombx_sram_read_ptr),
    .ombx_sram_read_resp_vld_o   (ombx_sram_read_resp_vld),
    .ombx_sram_read_resp_o       (ombx_sram_read_resp)
  );

endmodule
