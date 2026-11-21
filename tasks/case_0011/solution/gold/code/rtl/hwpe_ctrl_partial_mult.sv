// Copyright 2014-2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module hwpe_ctrl_partial_mult
  import hwpe_ctrl_package::*;
#(
  parameter int unsigned AW = 8,
  parameter int unsigned BW = 8,
  parameter int unsigned MULT_BITS = 4
)
(
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             clear_i,
  input  logic             start_i,
  input  logic [AW-1:0]    a_i,
  input  logic [BW-1:0]    b_i,
  input  logic             invert_i,
  output logic             valid_o,
  output logic             ready_o,
  output logic [AW+BW-1:0] prod_o
);

  localparam int unsigned AW_PAD  = (AW % MULT_BITS == 0) ? AW : (AW + MULT_BITS - (AW % MULT_BITS));
  localparam int unsigned N_STEPS = AW_PAD / MULT_BITS;
  localparam int unsigned CNT_W   = $clog2(N_STEPS + 1);

  logic [AW_PAD-1:0] a_pad;
  logic [CNT_W-1:0]  cnt;
  logic              valid_q, ready_q;

  assign a_pad = {{(AW_PAD-AW){1'b0}}, a_i};

  wire last_step = (cnt == CNT_W'(N_STEPS - 1));
  wire step_en   = start_i || (cnt != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      cnt     <= '0;
      valid_q <= 1'b0;
      ready_q <= 1'b1;
    end else if (clear_i) begin
      cnt     <= '0;
      valid_q <= 1'b0;
      ready_q <= 1'b1;
    end else if (last_step) begin
      cnt     <= '0;
      valid_q <= 1'b1;
      ready_q <= 1'b1;
    end else if (step_en) begin
      cnt     <= cnt + 1'b1;
      valid_q <= 1'b0;
      ready_q <= 1'b0;
    end
  end

  assign valid_o = valid_q;
  assign ready_o = ready_q;

  logic [MULT_BITS-1:0]    chunk;
  logic [BW+MULT_BITS-1:0] prod;
  logic [BW:0]             acc_hi_q;
  logic [AW_PAD-1:0]       lo_shift_q;

  assign chunk = a_pad[cnt * MULT_BITS +: MULT_BITS];
  assign prod  = chunk * b_i;

  wire [BW:0]           acc_in   = start_i ? '0 : acc_hi_q;
  wire [BW+MULT_BITS:0] acc_ext  = {{MULT_BITS{acc_in[BW]}}, acc_in};
  wire [BW+MULT_BITS:0] prod_mod = {1'b0, prod} ^ {(BW+MULT_BITS+1){invert_i}};
  wire [BW+MULT_BITS:0] sum      = acc_ext + prod_mod + invert_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      acc_hi_q   <= '0;
      lo_shift_q <= '0;
    end else if (clear_i) begin
      acc_hi_q   <= '0;
      lo_shift_q <= '0;
    end else if (step_en) begin
      acc_hi_q <= sum[BW+MULT_BITS:MULT_BITS];
      if (N_STEPS == 1) begin
        lo_shift_q <= sum[MULT_BITS-1:0];
      end else begin
        lo_shift_q <= {sum[MULT_BITS-1:0], lo_shift_q[AW_PAD-1:MULT_BITS]};
      end
    end
  end

  wire [AW_PAD+BW-1:0] full_res = {acc_hi_q[BW-1:0], lo_shift_q};
  assign prod_o = full_res[AW+BW-1:0];

endmodule
