// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

//
// The mux to select between ROM inputs (Gold)
//

module rom_ctrl_mux
  import prim_mubi_pkg::mubi4_t;
#(
  parameter int AW = 8,
  parameter int DW = 39
) (
  input logic           clk_i,
  input logic           rst_ni,

  input mubi4_t         sel_bus_i,

  input logic [AW-1:0]  bus_rom_addr_i,
  input logic [AW-1:0]  bus_prince_addr_i,
  input logic           bus_req_i,
  output logic          bus_gnt_o,
  output logic [DW-1:0] bus_rdata_o,
  output logic          bus_rvalid_o,

  input logic [AW-1:0]  chk_addr_i,
  input logic           chk_req_i,
  output logic [DW-1:0] chk_rdata_o,

  output logic [AW-1:0] rom_rom_addr_o,
  output logic [AW-1:0] rom_prince_addr_o,
  output logic          rom_req_o,
  input logic [DW-1:0]  rom_scr_rdata_i,
  input logic [DW-1:0]  rom_clr_rdata_i,
  input logic           rom_rvalid_i,

  output logic          alert_o
);

  import prim_mubi_pkg::*;

  logic [3:0] sel_bus_q_raw, sel_bus_qq_raw;
  mubi4_t     sel_bus_q, sel_bus_qq;

  prim_flop #(.Width (4), .ResetValue ({MuBi4False}))
  u_sel_bus_q_flop (
    .clk_i,
    .rst_ni,
    .d_i (mubi4_or_hi(sel_bus_q, sel_bus_i)),
    .q_o (sel_bus_q_raw)
  );
  assign sel_bus_q = mubi4_t'(sel_bus_q_raw);

  prim_flop #(.Width (4), .ResetValue ({MuBi4False}))
  u_sel_bus_qq_flop (
    .clk_i,
    .rst_ni,
    .d_i (sel_bus_q),
    .q_o (sel_bus_qq_raw)
  );
  assign sel_bus_qq = mubi4_t'(sel_bus_qq_raw);

  logic sel_invalid;
  assign sel_invalid = mubi4_test_invalid(sel_bus_i) || mubi4_test_invalid(sel_bus_q);

  logic sel_reverted;
  assign sel_reverted = mubi4_test_true_loose(sel_bus_q) & mubi4_test_false_loose(sel_bus_i);

  logic sel_q_reverted;
  assign sel_q_reverted = mubi4_test_true_loose(sel_bus_qq) & mubi4_test_false_loose(sel_bus_q);

  logic alert_q, alert_d;

  assign alert_d = sel_invalid | sel_reverted | sel_q_reverted;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      alert_q <= 0;
    end else begin
      alert_q <= alert_q | alert_d;
    end
  end

  assign alert_o = alert_q;

  assign bus_gnt_o    = mubi4_test_true_strict(sel_bus_i);
  assign bus_rdata_o  = rom_clr_rdata_i;
  assign bus_rvalid_o = mubi4_test_true_strict(sel_bus_q) & rom_rvalid_i;

  assign chk_rdata_o = rom_scr_rdata_i;

  assign rom_req_o         = mubi4_test_true_strict(sel_bus_i) ? bus_req_i         : chk_req_i;
  assign rom_rom_addr_o    = mubi4_test_true_strict(sel_bus_i) ? bus_rom_addr_i    : chk_addr_i;
  assign rom_prince_addr_o = mubi4_test_true_strict(sel_bus_i) ? bus_prince_addr_i : chk_addr_i;

endmodule
