// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Clock divider for Snitch isochronous cluster domain (`clk_d2`).
(* keep_hierarchy *)
module snitch_clkdiv2 (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic test_mode_i,
  input  logic bypass_i,
  output logic clk_o
);

  logic clk_div;

  always_ff @(posedge clk_i) begin
    clk_div <= ~clk_div;
  end

  assign clk_o = (test_mode_i | bypass_i) ? clk_i : clk_div;

endmodule
