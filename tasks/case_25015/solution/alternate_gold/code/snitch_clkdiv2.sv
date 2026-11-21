// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

(* keep_hierarchy *)
module snitch_clkdiv2 (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic test_mode_i,
  input  logic bypass_i,
  output logic clk_o
);

  logic div_toggle_q;
  logic sel_fast;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      div_toggle_q <= 1'b0;
    end else begin
      div_toggle_q <= ~div_toggle_q;
    end
  end

  assign sel_fast = test_mode_i || bypass_i;
  assign clk_o    = sel_fast ? clk_i : div_toggle_q;

endmodule
