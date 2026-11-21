// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenTitan ROM Controller Subsystem Top (`ot_rom_ctrl_top`)

module ot_rom_ctrl_top
  import prim_mubi_pkg::mubi4_t;
  import prim_util_pkg::vbits;
  import rom_ctrl_pkg::*;
#(
  parameter int RomDepth = 1024,
  parameter int TopCount = 8,
  parameter int DW       = 39,
  localparam int AW      = vbits(RomDepth)
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic [TopCount*32-1:0]    digest_i,
  input  logic [TopCount*32-1:0]    exp_digest_i,
  output logic [TopCount*32-1:0]    digest_o,
  output logic                      digest_vld_o,
  output logic [31:0]               exp_digest_word_o,
  output logic                      exp_digest_vld_o,
  output logic [vbits(TopCount)-1:0] exp_digest_idx_o,
  output pwrmgr_data_t              pwrmgr_data_o,
  output keymgr_data_t              keymgr_data_o,
  input  logic                      kmac_rom_rdy_i,
  output logic                      kmac_rom_vld_o,
  output logic                      kmac_rom_last_o,
  output logic [DW-1:0]             kmac_rom_data_o,
  input  logic                      kmac_done_i,
  input  logic [TopCount*32-1:0]    kmac_digest_i,
  input  logic                      kmac_err_i,
  input  logic [AW-1:0]             bus_rom_addr_i,
  input  logic [AW-1:0]             bus_prince_addr_i,
  input  logic                      bus_req_i,
  output logic                      bus_gnt_o,
  output logic [DW-1:0]             bus_rdata_o,
  output logic                      bus_rvalid_o,
  output logic [AW-1:0]             rom_rom_addr_o,
  output logic [AW-1:0]             rom_prince_addr_o,
  output logic                      rom_req_o,
  input  logic [DW-1:0]             rom_scr_rdata_i,
  input  logic [DW-1:0]             rom_clr_rdata_i,
  input  logic                      rom_rvalid_i,
  output logic                      alert_o
);

  mubi4_t        rom_select_bus;
  logic [AW-1:0] chk_addr;
  logic          chk_req;
  logic [DW-1:0] chk_rdata;
  logic          fsm_alert, mux_alert;

  assign kmac_rom_data_o = chk_rdata;

  rom_ctrl_fsm #(
    .RomDepth(RomDepth),
    .TopCount(TopCount)
  ) u_fsm (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .digest_i        (digest_i),
    .exp_digest_i    (exp_digest_i),
    .digest_o        (digest_o),
    .digest_vld_o    (digest_vld_o),
    .exp_digest_o    (exp_digest_word_o),
    .exp_digest_vld_o(exp_digest_vld_o),
    .exp_digest_idx_o(exp_digest_idx_o),
    .pwrmgr_data_o   (pwrmgr_data_o),
    .keymgr_data_o   (keymgr_data_o),
    .kmac_rom_rdy_i  (kmac_rom_rdy_i),
    .kmac_rom_vld_o  (kmac_rom_vld_o),
    .kmac_rom_last_o (kmac_rom_last_o),
    .kmac_done_i     (kmac_done_i),
    .kmac_digest_i   (kmac_digest_i),
    .kmac_err_i      (kmac_err_i),
    .rom_select_bus_o(rom_select_bus),
    .rom_addr_o      (chk_addr),
    .rom_req_o       (chk_req),
    .rom_data_i      (chk_rdata[31:0]),
    .alert_o         (fsm_alert)
  );

  rom_ctrl_mux #(
    .AW(AW),
    .DW(DW)
  ) u_mux (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .sel_bus_i        (rom_select_bus),
    .bus_rom_addr_i   (bus_rom_addr_i),
    .bus_prince_addr_i(bus_prince_addr_i),
    .bus_req_i        (bus_req_i),
    .bus_gnt_o        (bus_gnt_o),
    .bus_rdata_o      (bus_rdata_o),
    .bus_rvalid_o     (bus_rvalid_o),
    .chk_addr_i       (chk_addr),
    .chk_req_i        (chk_req),
    .chk_rdata_o      (chk_rdata),
    .rom_rom_addr_o   (rom_rom_addr_o),
    .rom_prince_addr_o(rom_prince_addr_o),
    .rom_req_o        (rom_req_o),
    .rom_scr_rdata_i  (rom_scr_rdata_i),
    .rom_clr_rdata_i  (rom_clr_rdata_i),
    .rom_rvalid_i     (rom_rvalid_i),
    .alert_o          (mux_alert)
  );

  assign alert_o = fsm_alert | mux_alert;

endmodule
