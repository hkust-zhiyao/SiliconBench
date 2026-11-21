// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenTitan Entropy Complex Command Staging, Auto-Request & Endpoint Ack Top (`ot_entropy_cmd_top`)

module ot_entropy_cmd_top
  import csrng_pkg::*;
  import edn_pkg::*;
(
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          cs_enable_i,
  input  logic                          edn_enable_i,
  input  logic                          boot_req_mode_i,
  input  logic                          auto_req_mode_i,
  input  logic                          sw_cmd_req_load_i,
  input  logic                          max_reqs_cnt_zero_i,
  input  logic                          csrng_ack_err_i,
  input  logic                          local_escalate_i,
  output logic                          sw_cmd_mode_o,
  output logic                          boot_wr_ins_cmd_o,
  output logic                          boot_send_ins_cmd_o,
  output logic                          boot_wr_gen_cmd_o,
  output logic                          boot_wr_uni_cmd_o,
  output logic                          accept_sw_cmds_pulse_o,
  output logic                          main_sm_done_pulse_o,
  output logic                          capt_gencmd_fifo_cnt_o,
  output logic                          send_gencmd_o,
  output logic                          capt_rescmd_fifo_cnt_o,
  output logic                          send_rescmd_o,
  output logic                          auto_req_mode_busy_o,
  output logic [edn_pkg::StateWidth-1:0] edn_main_sm_state_o,
  output logic                          reject_csrng_entropy_o,
  output logic                          edn_main_sm_err_o,
  input  logic                          cmd_stage_vld_i,
  input  logic [InstIdWidth-1:0]        cmd_stage_shid_i,
  input  logic [CmdBusWidth-1:0]        cmd_stage_bus_i,
  output logic                          cmd_stage_rdy_o,
  input  logic                          reseed_cnt_reached_i,
  output logic                          reseed_cnt_alert_o,
  output logic                          invalid_cmd_seq_alert_o,
  output logic                          invalid_acmd_alert_o,
  input  logic                          gen_abort_req_i,
  output logic                          gen_abort_invalid_o,
  output logic                          cmd_arb_req_o,
  output logic                          cmd_arb_sop_o,
  output logic                          cmd_arb_mop_o,
  output logic                          cmd_arb_eop_o,
  output logic [CmdBusWidth-1:0]        cmd_arb_bus_o,
  input  logic                          cmd_entropy_avail_i,
  output logic                          cmd_entropy_req_o,
  output logic                          core_cmd_vld_o,
  input  logic                          core_cmd_rdy_i,
  output logic                          clr_adata_packer_o,
  input  logic                          cmd_complete_i,
  output logic [MainSmStateWidth-1:0]   csrng_main_sm_state_o,
  output logic                          csrng_main_sm_err_o,
  input  logic                          cmd_ack_i,
  input  csrng_cmd_sts_e                cmd_ack_sts_i,
  output logic                          cmd_stage_ack_o,
  output csrng_cmd_sts_e                cmd_stage_ack_sts_o,
  input  logic                          genbits_vld_i,
  input  logic [127:0]                  genbits_bus_i,
  input  logic                          genbits_fips_i,
  output logic                          genbits_vld_o,
  output logic [127:0]                  genbits_bus_o,
  output logic                          genbits_fips_o,
  input  logic                          ep_req_i,
  output logic                          ep_ack_o,
  output logic                          ep_fifo_clr_o,
  output logic                          ep_ack_sm_err_o,
  output logic [2:0]                    cmd_stage_sfifo_cmd_err_o,
  output logic [2:0]                    cmd_stage_sfifo_genbits_err_o,
  output logic                          cmd_gen_cnt_err_o,
  output logic                          cmd_stage_sm_err_o
);

  logic cmd_arb_gnt;
  logic ep_fifo_pop;
  logic cmd_sent;

  assign cmd_sent = cmd_stage_vld_i & cmd_stage_rdy_o;

  edn_main_sm u_edn_main_sm (
    .clk_i                 (clk_i),
    .rst_ni                (rst_ni),
    .edn_enable_i          (edn_enable_i),
    .boot_req_mode_i       (boot_req_mode_i),
    .auto_req_mode_i       (auto_req_mode_i),
    .sw_cmd_req_load_i     (sw_cmd_req_load_i),
    .sw_cmd_mode_o         (sw_cmd_mode_o),
    .boot_wr_ins_cmd_o     (boot_wr_ins_cmd_o),
    .boot_send_ins_cmd_o   (boot_send_ins_cmd_o),
    .boot_wr_gen_cmd_o     (boot_wr_gen_cmd_o),
    .boot_wr_uni_cmd_o     (boot_wr_uni_cmd_o),
    .accept_sw_cmds_pulse_o(accept_sw_cmds_pulse_o),
    .main_sm_done_pulse_o  (main_sm_done_pulse_o),
    .csrng_cmd_ack_i       (cmd_stage_ack_o),
    .capt_gencmd_fifo_cnt_o(capt_gencmd_fifo_cnt_o),
    .send_gencmd_o         (send_gencmd_o),
    .max_reqs_cnt_zero_i   (max_reqs_cnt_zero_i),
    .capt_rescmd_fifo_cnt_o(capt_rescmd_fifo_cnt_o),
    .send_rescmd_o         (send_rescmd_o),
    .cmd_sent_i            (cmd_sent),
    .auto_req_mode_busy_o  (auto_req_mode_busy_o),
    .main_sm_state_o       (edn_main_sm_state_o),
    .csrng_ack_err_i       (csrng_ack_err_i | (cmd_stage_ack_o & (cmd_stage_ack_sts_o != CMD_STS_SUCCESS))),
    .reject_csrng_entropy_o(reject_csrng_entropy_o),
    .local_escalate_i      (local_escalate_i),
    .main_sm_err_o         (edn_main_sm_err_o)
  );

  csrng_cmd_stage u_cmd_stage (
    .clk_i                        (clk_i),
    .rst_ni                       (rst_ni),
    .cs_enable_i                  (cs_enable_i),
    .cmd_stage_vld_i              (cmd_stage_vld_i),
    .cmd_stage_shid_i             (cmd_stage_shid_i),
    .cmd_stage_bus_i              (cmd_stage_bus_i),
    .cmd_stage_rdy_o              (cmd_stage_rdy_o),
    .reseed_cnt_reached_i         (reseed_cnt_reached_i),
    .reseed_cnt_alert_o           (reseed_cnt_alert_o),
    .invalid_cmd_seq_alert_o      (invalid_cmd_seq_alert_o),
    .invalid_acmd_alert_o         (invalid_acmd_alert_o),
    .gen_abort_req_i              (gen_abort_req_i),
    .gen_abort_invalid_o          (gen_abort_invalid_o),
    .cmd_arb_req_o                (cmd_arb_req_o),
    .cmd_arb_sop_o                (cmd_arb_sop_o),
    .cmd_arb_mop_o                (cmd_arb_mop_o),
    .cmd_arb_eop_o                (cmd_arb_eop_o),
    .cmd_arb_gnt_i                (cmd_arb_gnt),
    .cmd_arb_bus_o                (cmd_arb_bus_o),
    .cmd_ack_i                    (cmd_ack_i),
    .cmd_ack_sts_i                (cmd_ack_sts_i),
    .cmd_stage_ack_o              (cmd_stage_ack_o),
    .cmd_stage_ack_sts_o          (cmd_stage_ack_sts_o),
    .genbits_vld_i                (genbits_vld_i & ~reject_csrng_entropy_o),
    .genbits_bus_i                (genbits_bus_i),
    .genbits_fips_i               (genbits_fips_i),
    .genbits_vld_o                (genbits_vld_o),
    .genbits_rdy_i                (ep_fifo_pop),
    .genbits_bus_o                (genbits_bus_o),
    .genbits_fips_o               (genbits_fips_o),
    .cmd_stage_sfifo_cmd_err_o    (cmd_stage_sfifo_cmd_err_o),
    .cmd_stage_sfifo_genbits_err_o(cmd_stage_sfifo_genbits_err_o),
    .cmd_gen_cnt_err_o            (cmd_gen_cnt_err_o),
    .cmd_stage_sm_err_o           (cmd_stage_sm_err_o)
  );

  csrng_main_sm u_csrng_main_sm (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .enable_i           (cs_enable_i),
    .acmd_avail_i       (cmd_arb_req_o),
    .acmd_accept_o      (cmd_arb_gnt),
    .acmd_i             (acmd_e'(cmd_arb_bus_o[2:0])),
    .acmd_eop_i         (cmd_arb_eop_o),
    .flag0_i            (cmd_arb_bus_o[8]),
    .cmd_entropy_req_o  (cmd_entropy_req_o),
    .cmd_entropy_avail_i(cmd_entropy_avail_i),
    .cmd_vld_o          (core_cmd_vld_o),
    .cmd_rdy_i          (core_cmd_rdy_i),
    .clr_adata_packer_o (clr_adata_packer_o),
    .cmd_complete_i     (cmd_complete_i),
    .local_escalate_i   (local_escalate_i | cmd_stage_sm_err_o | cmd_gen_cnt_err_o),
    .main_sm_state_o    (csrng_main_sm_state_o),
    .main_sm_err_o      (csrng_main_sm_err_o)
  );

  edn_ack_sm u_edn_ack_sm (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .enable_i        (edn_enable_i),
    .req_i           (ep_req_i),
    .ack_o           (ep_ack_o),
    .local_escalate_i(local_escalate_i | edn_main_sm_err_o),
    .fifo_not_empty_i(genbits_vld_o),
    .fifo_pop_o      (ep_fifo_pop),
    .fifo_clr_o      (ep_fifo_clr_o),
    .ack_sm_err_o    (ep_ack_sm_err_o)
  );

endmodule
