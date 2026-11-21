// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE.llc for details.
// SPDX-License-Identifier: SHL-0.51
// Synthesizable parameterized single-port SRAM model for PULP axi_llc tag store.

module tc_sram #(
  parameter int unsigned NumWords     = 32'd1024,
  parameter int unsigned DataWidth    = 32'd128,
  parameter int unsigned ByteWidth    = 32'd8,
  parameter int unsigned NumPorts     = 32'd1,
  parameter int unsigned Latency      = 32'd1,
  parameter              SimInit      = "none",
  parameter bit          PrintSimCfg  = 1'b0,
  parameter              ImplKey      = "none",
  parameter int unsigned AddrWidth    = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
  parameter int unsigned BeWidth      = (DataWidth + ByteWidth - 32'd1) / ByteWidth,
  parameter type         addr_t       = logic [AddrWidth-1:0],
  parameter type         data_t       = logic [DataWidth-1:0],
  parameter type         be_t         = logic [BeWidth-1:0]
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic  [NumPorts-1:0] req_i,
  input  logic  [NumPorts-1:0] we_i,
  input  addr_t [NumPorts-1:0] addr_i,
  input  data_t [NumPorts-1:0] wdata_i,
  input  be_t   [NumPorts-1:0] be_i,
  output data_t [NumPorts-1:0] rdata_o
);
  logic [DataWidth-1:0] mem_q [0:NumWords-1];

  for (genvar p = 0; p < NumPorts; p++) begin : gen_ports
    if (Latency == 32'd0) begin : gen_lat0
      assign rdata_o[p] = mem_q[addr_i[p]];
    end else begin : gen_lat_pos
      data_t [Latency-1:0] rpipe_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          rpipe_q <= '0;
        end else begin
          if (req_i[p] && !we_i[p]) begin
            rpipe_q[0] <= mem_q[addr_i[p]];
          end
          for (int unsigned k = 1; k < Latency; k++) begin
            rpipe_q[k] <= rpipe_q[k-1];
          end
        end
      end
      assign rdata_o[p] = rpipe_q[Latency-1];
    end
  end

  always_ff @(posedge clk_i) begin
    for (int unsigned p = 0; p < NumPorts; p++) begin
      if (req_i[p] && we_i[p]) begin
        for (int unsigned b = 0; b < DataWidth; b++) begin
          if (be_i[p][b / ByteWidth]) begin
            mem_q[addr_i[p]][b] <= wdata_i[p][b];
          end
        end
      end
    end
  end
endmodule
