// Copyright 2021-2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Alternate Gold: Kernighan bit-clearing (`x & (x - 1)`) and two's-complement
// lowest-set-bit isolator (`x & -x`) power-of-two stride sequencer.

module p2_stride_gen import ara_pkg::*; import rvv_pkg::*; import cf_math_pkg::idx_width; #(
  parameter integer unsigned NrLanes = 0
) (
  input  logic                                     clk_i,
  input  logic                                     rst_ni,
  input  logic          [idx_width(8*NrLanes)-1:0] stride_i,
  input  logic                                     valid_i,
  input  logic                                     update_i,
  output logic [idx_width(idx_width(8*NrLanes)):0] popc_o,
  output logic          [idx_width(8*NrLanes)-1:0] stride_p2_o,
  output logic                                     valid_o
);

  localparam int unsigned W  = idx_width(8*NrLanes);
  localparam int unsigned PW = idx_width(W) + 1;

  logic [W-1:0]  rem_d, rem_q;
  logic [PW-1:0] popc_d, popc_q;

  always_comb begin
    rem_d = rem_q;
    if (valid_i) begin
      rem_d = stride_i;
    end else if (update_i) begin
      rem_d = rem_q & (rem_q - 1'b1);
    end

    popc_d = '0;
    for (int i = 0; i < W; i++) begin
      popc_d += PW'(rem_d[i]);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rem_q  <= '0;
      popc_q <= '0;
    end else if (valid_i || update_i) begin
      rem_q  <= rem_d;
      popc_q <= popc_d;
    end
  end

  assign stride_p2_o = rem_q & (~rem_q + 1'b1);
  assign popc_o      = popc_q;
  assign valid_o     = |rem_q;

endmodule
