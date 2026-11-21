// SPDX-License-Identifier: GPL-2.0-only OR ADIBSD
// Copyright (C) 2017-2026 Analog Devices, Inc. All rights reserved.
`timescale 1ns/100ps

module pack_ctrl #(
  parameter PORT_ADDRESS_WIDTH = 2,
  parameter MUX_ORDER = 1,
  parameter MIN_STAGE = 0,
  parameter NUM_STAGES = 2,
  parameter PACK = 0
) (
  input [PORT_ADDRESS_WIDTH-1:0] rotate,
  input [2**PORT_ADDRESS_WIDTH*PORT_ADDRESS_WIDTH-1:0] prefix_count,

  output [2**PORT_ADDRESS_WIDTH*MUX_ORDER*NUM_STAGES-1:0] ctrl
);

  localparam NUM_OF_PORTS = 2**PORT_ADDRESS_WIDTH;
  localparam z = 2**MUX_ORDER;

  wire [NUM_OF_PORTS*MUX_ORDER*NUM_STAGES-1:0] ctrl1;
  reg  [NUM_OF_PORTS*MUX_ORDER*NUM_STAGES-1:0] ctrl2;

  generate
    genvar i, j, k;

    for (i = 0; i < NUM_STAGES; i = i + 1) begin: ctrl_gen_outer
      localparam k0 = 2**(PORT_ADDRESS_WIDTH - MUX_ORDER*(i+1) - MIN_STAGE);
      localparam k1 = 2**(MUX_ORDER*(1+i) + MIN_STAGE);

      for (j = 0; j < NUM_OF_PORTS; j = j + 1) begin: ctrl_gen_inner
        localparam s = (i*NUM_OF_PORTS + j)*MUX_ORDER;
        localparam m = (j % k1) * k0;
        localparam n = j / k1;

        if (MUX_ORDER == 1 && j % 2 == 0) begin
          assign ctrl1[s] = ~ctrl1[s+1];
        end else begin
          assign ctrl1[s+:MUX_ORDER] = (j - (prefix_count[m*PORT_ADDRESS_WIDTH+:PORT_ADDRESS_WIDTH] + n - rotate) / k0) % z;
        end
      end
    end

    if (PACK == 0 || MUX_ORDER == 1) begin
      assign ctrl = ctrl1;
    end else begin
      for (i = 0; i < NUM_STAGES*NUM_OF_PORTS; i = i + z) begin: demux_gen_outer
        localparam base = i*MUX_ORDER;
        for (k = 0; k < z; k = k + 1) begin: demux_gen_inner
          always @(*) begin : comb_demux
            integer n_idx;
            ctrl2[base+k*MUX_ORDER+:MUX_ORDER] = {MUX_ORDER{1'b1}};
            for (n_idx = 0; n_idx < z; n_idx = n_idx + 1) begin
              if (ctrl1[base+n_idx*MUX_ORDER+:MUX_ORDER] == k[MUX_ORDER-1:0]) begin
                ctrl2[base+k*MUX_ORDER+:MUX_ORDER] = n_idx[MUX_ORDER-1:0];
              end
            end
          end
        end
      end
      assign ctrl = ctrl2;
    end
  endgenerate

endmodule
