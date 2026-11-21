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

  // Decoupled A/B spill stage for write descriptors (zero downstream ready load on xbar_w_desc)
  desc_t w_a_q, w_b_q;
  logic  w_a_full_q, w_b_full_q;
  wire   w_a_fill  = xbar_w_valid & xbar_w_ready;
  wire   w_a_drain = w_a_full_q & ~w_b_full_q;
  wire   w_b_fill  = w_a_drain & ~write_ready_i;
  wire   w_b_drain = w_b_full_q & write_ready_i;

  assign xbar_w_ready  = ~w_a_full_q | ~w_b_full_q;
  assign write_valid_o = w_a_full_q | w_b_full_q;
  assign write_desc_o  = w_b_full_q ? w_b_q : w_a_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_a_q      <= '0;
      w_b_q      <= '0;
      w_a_full_q <= 1'b0;
      w_b_full_q <= 1'b0;
    end else begin
      if (w_a_fill)
        w_a_q <= xbar_w_desc;
      if (w_b_fill)
        w_b_q <= w_a_q;
      if (w_a_fill || w_a_drain)
        w_a_full_q <= w_a_fill;
      if (w_b_fill || w_b_drain)
        w_b_full_q <= w_b_fill;
    end
  end

  // Decoupled A/B spill stage for read descriptors
  desc_t r_a_q, r_b_q;
  logic  r_a_full_q, r_b_full_q;
  wire   r_a_fill  = xbar_r_valid & xbar_r_ready;
  wire   r_a_drain = r_a_full_q & ~r_b_full_q;
  wire   r_b_fill  = r_a_drain & ~read_ready_i;
  wire   r_b_drain = r_b_full_q & read_ready_i;

  assign xbar_r_ready = ~r_a_full_q | ~r_b_full_q;
  assign read_valid_o = r_a_full_q | r_b_full_q;
  assign read_desc_o  = r_b_full_q ? r_b_q : r_a_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_a_q      <= '0;
      r_b_q      <= '0;
      r_a_full_q <= 1'b0;
      r_b_full_q <= 1'b0;
    end else begin
      if (r_a_fill)
        r_a_q <= xbar_r_desc;
      if (r_b_fill)
        r_b_q <= r_a_q;
      if (r_a_fill || r_a_drain)
        r_a_full_q <= r_a_fill;
      if (r_b_fill || r_b_drain)
        r_b_full_q <= r_b_fill;
    end
  end
endmodule
