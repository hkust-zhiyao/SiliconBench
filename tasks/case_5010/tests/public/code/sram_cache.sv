// Copyright 2018 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module sram_cache #(
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned USER_WIDTH = 1,
  parameter bit          USER_EN    = 0,
  parameter int unsigned NUM_WORDS  = 1024,
  parameter bit          BYTE_ACCESS = 0,
  parameter bit          TECHNO_CUT  = 0
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          req_i,
  input  logic                          we_i,
  input  logic [$clog2(NUM_WORDS)-1:0]  addr_i,
  input  logic [USER_WIDTH-1:0]         wuser_i,
  input  logic [DATA_WIDTH-1:0]         wdata_i,
  input  logic [(DATA_WIDTH+7)/8-1:0]   be_i,
  output logic [USER_WIDTH-1:0]         ruser_o,
  output logic [DATA_WIDTH-1:0]         rdata_o
);
  logic [NUM_WORDS-1:0][DATA_WIDTH-1:0] mem_q;
  logic [$clog2(NUM_WORDS)-1:0] raddr_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_q   <= '0;
      raddr_q <= '0;
    end else if (req_i) begin
      if (we_i) begin
        mem_q[addr_i] <= wdata_i;
      end else begin
        raddr_q <= addr_i;
      end
    end
  end
  assign rdata_o = mem_q[raddr_q];
  assign ruser_o = '0;
endmodule
