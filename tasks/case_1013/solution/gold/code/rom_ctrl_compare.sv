// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

//
// The comparator inside the ROM checker (Gold)
//

`include "prim_assert.sv"

module rom_ctrl_compare
  import prim_mubi_pkg::mubi4_t;
#(
  parameter int NumWords = 2
) (
  input logic                        clk_i,
  input logic                        rst_ni,

  input logic                        start_i,
  output logic                       done_o,
  output mubi4_t                     good_o,

  input logic [NumWords*32-1:0]      digest_i,
  input logic [NumWords*32-1:0]      exp_digest_i,

  output logic                       alert_o
);

  import prim_util_pkg::vbits;
  import prim_mubi_pkg::mubi4_bool_to_mubi;

  localparam int AW = vbits(NumWords);

  localparam int unsigned LastAddrInt = NumWords - 1;
  localparam bit [AW-1:0] LastAddr    = LastAddrInt[AW-1:0];

  logic          addr_incr;
  logic [AW-1:0] addr_q;

  typedef enum logic [4:0] {
    Waiting  = 5'b00100,
    Checking = 5'b10010,
    Done     = 5'b11001
  } state_e;

  state_e state_q, state_d;
  logic   matches_q, matches_d;
  logic   fsm_alert;

  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, state_e, Waiting)

  always_comb begin
    state_d = state_q;
    fsm_alert = 1'b0;
    unique case (state_q)
      Waiting: begin
        if (start_i) state_d = Checking;
      end
      Checking: begin
        if (addr_q == LastAddr) state_d = Done;
      end
      Done: begin
      end
      default: fsm_alert = 1'b1;
    endcase
  end

  logic start_alert;
  assign start_alert = start_i && (state_q != Waiting);

  logic wait_addr_alert;
  assign wait_addr_alert = (state_q == Waiting) && (addr_q != '0);

  logic done_addr_alert;
  assign done_addr_alert = (state_q == Done) && (addr_q != LastAddr);

  assign addr_incr = (state_q == Checking) && (addr_q != LastAddr);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      addr_q <= '0;
    end else if (addr_incr) begin
      addr_q <= addr_q + AW'(1);
    end
  end

  logic [NumWords-1:0] word_eq;
  for (genvar w = 0; w < NumWords; w++) begin : gen_word_eq
    assign word_eq[w] = (digest_i[w*32 +: 32] == exp_digest_i[w*32 +: 32]);
  end

  assign matches_d = matches_q && (&word_eq);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      matches_q <= 1'b1;
    end else begin
      if (state_q == Checking) begin
        matches_q <= matches_d;
      end
    end
  end

  assign done_o = (state_q == Done);

  prim_mubi4_sender
  u_done_sender (
    .clk_i,
    .rst_ni,
    .mubi_i (mubi4_bool_to_mubi(matches_q)),
    .mubi_o (good_o)
  );

  assign alert_o = fsm_alert | start_alert | wait_addr_alert | done_addr_alert;

endmodule
