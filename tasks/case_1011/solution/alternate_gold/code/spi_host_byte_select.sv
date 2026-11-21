// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Byte-select module for dispensing words in SPI Host IP (Alternate Gold).

module spi_host_byte_select (
  input               clk_i,
  input               rst_ni,
  input       [31:0]  word_i,
  input        [3:0]  word_be_i,
  input               word_valid_i,
  output logic        word_ready_o,
  output logic  [7:0] byte_o,
  output logic        byte_valid_o,
  input               byte_ready_i,
  input               flush_i,
  input               sw_rst_i
);

  logic [31:0] data_q, data_d;
  logic [3:0]  be_q, be_d;
  logic [2:0]  rem_q, rem_d;
  logic        clr_q;
  logic        clr;
  logic        byte_valid, byte_ready, do_drain;

  assign clr          = flush_i | sw_rst_i;
  assign byte_valid   = (rem_q != 3'd0) && !clr_q;
  assign byte_valid_o = byte_valid && be_q[0];
  assign do_drain     = byte_valid && !be_q[0];
  assign byte_ready   = byte_ready_i || do_drain;
  assign word_ready_o = (rem_q == 3'd0) && !clr_q;
  assign byte_o       = byte_valid ? data_q[7:0] : 8'h00;

  always_comb begin
    data_d = data_q;
    be_d   = be_q;
    rem_d  = rem_q;
    if (clr_q || (byte_ready && (rem_q == 3'd1))) begin
      rem_d  = 3'd0;
    end else if (word_valid_i && word_ready_o) begin
      data_d = word_i;
      be_d   = word_be_i;
      rem_d  = 3'd4;
    end else if (byte_valid && byte_ready) begin
      data_d = {8'h00, data_q[31:8]};
      be_d   = {1'b0, be_q[3:1]};
      rem_d  = rem_q - 3'd1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_q <= '0;
      be_q   <= '0;
      rem_q  <= '0;
      clr_q  <= 1'b1;
    end else begin
      data_q <= data_d;
      be_q   <= be_d;
      rem_q  <= rem_d;
      clr_q  <= clr;
    end
  end

endmodule : spi_host_byte_select
