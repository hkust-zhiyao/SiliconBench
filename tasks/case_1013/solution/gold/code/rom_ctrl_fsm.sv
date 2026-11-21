// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

//
// The ROM checker FSM module (Gold)
//

`include "prim_assert.sv"

module rom_ctrl_fsm
  import prim_mubi_pkg::mubi4_t;
  import prim_util_pkg::vbits;
  import rom_ctrl_pkg::*;
#(
  parameter int RomDepth = 16,
  parameter int TopCount = 8
) (
  input logic                        clk_i,
  input logic                        rst_ni,

  input logic [TopCount*32-1:0]      digest_i,
  input logic [TopCount*32-1:0]      exp_digest_i,

  output logic [TopCount*32-1:0]     digest_o,
  output logic                       digest_vld_o,
  output logic [31:0]                exp_digest_o,
  output logic                       exp_digest_vld_o,
  output logic [vbits(TopCount)-1:0] exp_digest_idx_o,

  output pwrmgr_data_t               pwrmgr_data_o,
  output keymgr_data_t               keymgr_data_o,

  input logic                        kmac_rom_rdy_i,
  output logic                       kmac_rom_vld_o,
  output logic                       kmac_rom_last_o,

  input logic                        kmac_done_i,
  input logic [TopCount*32-1:0]      kmac_digest_i,
  input logic                        kmac_err_i,

  output mubi4_t                     rom_select_bus_o,
  output logic [vbits(RomDepth)-1:0] rom_addr_o,
  output logic                       rom_req_o,

  input logic [31:0]                 rom_data_i,

  output logic                       alert_o
);

  import prim_mubi_pkg::mubi4_test_true_loose;
  import prim_mubi_pkg::MuBi4False, prim_mubi_pkg::MuBi4True;

  localparam int AW = vbits(RomDepth);
  localparam int TAW = vbits(TopCount);

  localparam int unsigned TopStartAddrInt = RomDepth - TopCount;
  localparam bit [AW-1:0] TopStartAddr    = TopStartAddrInt[0 +: AW];

  logic          counter_done;
  logic [AW-1:0] counter_read_addr;
  logic          counter_read_req;
  logic [AW-1:0] counter_data_addr;
  logic          counter_data_rdy;
  logic          counter_lnt;
  rom_ctrl_counter #(
    .RomDepth (RomDepth),
    .RomTopCount (TopCount)
  ) u_counter (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .done_o             (counter_done),
    .read_addr_o        (counter_read_addr),
    .read_req_o         (counter_read_req),
    .data_addr_o        (counter_data_addr),
    .data_rdy_i         (counter_data_rdy),
    .data_last_nontop_o (counter_lnt)
  );

  logic   start_checker_q;
  logic   checker_done, checker_alert;
  mubi4_t checker_good;
  rom_ctrl_compare #(
    .NumWords  (TopCount)
  ) u_compare (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .start_i      (start_checker_q),
    .done_o       (checker_done),
    .good_o       (checker_good),
    .digest_i     (digest_i),
    .exp_digest_i (exp_digest_i),
    .alert_o      (checker_alert)
  );

  fsm_state_e state_d, state_q;
  logic       fsm_alert;

  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, fsm_state_e, ReadingLow)

  always_comb begin
    state_d = state_q;
    fsm_alert = 1'b0;

    unique case (state_q)
      ReadingLow: begin
        if (counter_lnt && kmac_rom_rdy_i) begin
          state_d = ReadingHigh;
        end
      end

      ReadingHigh: begin
        unique case ({kmac_done_i, counter_done})
          2'b01: state_d = RomAhead;
          2'b10: state_d = kmac_err_i ? Invalid : KmacAhead;
          2'b11: state_d = kmac_err_i ? Invalid : Checking;
          default: ;
        endcase
      end

      RomAhead: begin
        if (kmac_done_i) state_d = kmac_err_i ? Invalid : Checking;
      end

      KmacAhead: begin
        if (counter_done) state_d = Checking;
      end

      Checking: begin
        if (checker_done) state_d = Done;
      end

      Done: begin
      end

      default: begin
        fsm_alert = 1'b1;
        state_d = Invalid;
      end
    endcase

    if ((checker_done && !(state_q inside {Checking, Done})) ||
        (counter_done && state_q == ReadingLow) ||
        (kmac_done_i && !(state_q inside {ReadingHigh, RomAhead}))) begin
      state_d = Invalid;
    end

    if (alert_o) begin
      state_d = Invalid;
    end
  end

  logic [9:0] state_q_bits;
  logic       unused_state_q_top_bits;
  assign state_q_bits = {state_q};
  assign unused_state_q_top_bits = ^state_q_bits[9:4];

  mubi4_t in_state_done;
  assign in_state_done = mubi4_t'(state_q_bits[3:0]);

  assign digest_o     = kmac_digest_i;
  assign digest_vld_o = kmac_done_i;

  logic reading_top;
  logic [TAW-1:0] rel_addr;

  assign reading_top = (state_q == ReadingHigh || state_q == KmacAhead) & ~counter_done;
  assign rel_addr    = counter_data_addr[TAW-1:0] - TopStartAddr[TAW-1:0];

  logic unused_top_data_addr;
  assign unused_top_data_addr = ^counter_data_addr[AW-1:TAW];

  assign exp_digest_o = rom_data_i;
  assign exp_digest_vld_o = reading_top;
  assign exp_digest_idx_o = rel_addr;

  assign pwrmgr_data_o = '{done: in_state_done, good: checker_good};
  assign keymgr_data_o = '{data: digest_i, valid: mubi4_test_true_loose(in_state_done)};

  logic kmac_rom_vld_d, kmac_rom_vld_q;
  always_comb begin
    kmac_rom_vld_d = kmac_rom_vld_q;
    if (kmac_rom_rdy_i) begin
      kmac_rom_vld_d = 0;
    end
    if (counter_read_req && state_q == ReadingLow && !counter_lnt) begin
      kmac_rom_vld_d = 1;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      kmac_rom_vld_q <= 0;
    end else begin
      kmac_rom_vld_q <= kmac_rom_vld_d;
    end
  end

  assign counter_data_rdy = kmac_rom_rdy_i | (state_q inside {ReadingHigh, KmacAhead});
  assign kmac_rom_vld_o = kmac_rom_vld_q;
  assign kmac_rom_last_o = counter_lnt;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_checker_q <= 1'b0;
    end else begin
      start_checker_q <= (state_q != Checking) && (state_d == Checking);
    end
  end

  logic unexpected_counter_change;
  assign unexpected_counter_change = mubi4_test_true_loose(in_state_done) & !counter_done;

  assign rom_select_bus_o = in_state_done;
  assign rom_addr_o = counter_read_addr;
  assign rom_req_o = counter_read_req;

  assign alert_o = fsm_alert | checker_alert | unexpected_counter_change;

endmodule
