// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_merge_unit #(
  parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter type desc_t = logic,
  parameter type cnt_t  = logic
) (
  input  logic  clk_i,
  input  logic  rst_ni,
  input  desc_t bypass_desc_i,
  input  logic  bypass_valid_i,
  output logic  bypass_ready_o,
  input  desc_t refill_desc_i,
  input  logic  refill_valid_i,
  output logic  refill_ready_o,
  output desc_t read_desc_o,
  output logic  read_valid_o,
  input  logic  read_ready_i,
  output desc_t write_desc_o,
  output logic  write_valid_o,
  input  logic  write_ready_i,
  output cnt_t  cnt_down_o
);

  desc_t xbar_w_desc,  xbar_r_desc;
  logic  xbar_w_valid, xbar_w_ready;
  logic  xbar_r_valid, xbar_r_ready;

  assign cnt_down_o.id    = refill_desc_i.a_x_id;
  assign cnt_down_o.rw    = refill_desc_i.rw;
  assign cnt_down_o.valid = refill_valid_i & refill_ready_o;

  stream_xbar #(
    .NumInp     ( 32'd2  ),
    .NumOut     ( 32'd2  ),
    .payload_t  ( desc_t ),
    .OutSpillReg( 1'b0   ),
    .ExtPrio    ( 1'b0   ),
    .AxiVldRdy  ( 1'b1   ),
    .LockIn     ( 1'b1   )
  ) i_stream_xbar (
    .clk_i,
    .rst_ni,
    .flush_i ( '0                                 ),
    .rr_i    ( '0                                 ),
    .data_i  ({bypass_desc_i,    refill_desc_i   }),
    .sel_i   ({bypass_desc_i.rw, refill_desc_i.rw}),
    .valid_i ({bypass_valid_i,   refill_valid_i  }),
    .ready_o ({bypass_ready_o,   refill_ready_o  }),
    .data_o  ({xbar_w_desc,      xbar_r_desc     }),
    .idx_o   (                                    ),
    .valid_o ({xbar_w_valid,     xbar_r_valid    }),
    .ready_i ({xbar_w_ready,     xbar_r_ready    })
  );

  spill_register #(
    .T      ( desc_t ),
    .Bypass ( 1'b0   )
  ) i_write_out_pipe (
    .clk_i,
    .rst_ni,
    .valid_i ( xbar_w_valid  ),
    .ready_o ( xbar_w_ready  ),
    .data_i  ( xbar_w_desc   ),
    .valid_o ( write_valid_o ),
    .ready_i ( write_ready_i ),
    .data_o  ( write_desc_o  )
  );

  spill_register #(
    .T      ( desc_t ),
    .Bypass ( 1'b0   )
  ) i_read_out_pipe (
    .clk_i,
    .rst_ni,
    .valid_i ( xbar_r_valid ),
    .ready_o ( xbar_r_ready ),
    .data_i  ( xbar_r_desc  ),
    .valid_o ( read_valid_o ),
    .ready_i ( read_ready_i ),
    .data_o  ( read_desc_o  )
  );
endmodule
