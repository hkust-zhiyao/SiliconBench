// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_miss_counters #(
  parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter type cnt_t  = logic,
  parameter int unsigned AxiIdLookupBits = 32'd0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  cnt_t cnt_up_i,
  input  cnt_t cnt_down_i,
  output logic to_miss_o,
  output logic stall_o
);
  localparam int unsigned NoCounters = 32'd1 << AxiIdLookupBits;
  localparam int unsigned IdWidth    = $bits(cnt_up_i.id);
  localparam int unsigned IdxWidth   = (AxiIdLookupBits > 32'd0) ? AxiIdLookupBits : 32'd1;

  logic [IdxWidth-1:0] up_idx, down_idx;
  if (AxiIdLookupBits == 32'd0) begin : gen_zero_lookup_bits
    assign up_idx   = 1'b0;
    assign down_idx = 1'b0;
  end else if (AxiIdLookupBits >= IdWidth) begin : gen_full_lookup_bits
    assign up_idx   = IdxWidth'(cnt_up_i.id);
    assign down_idx = IdxWidth'(cnt_down_i.id);
  end else begin : gen_slice_lookup_bits
    assign up_idx   = cnt_up_i.id[AxiIdLookupBits-1:0];
    assign down_idx = cnt_down_i.id[AxiIdLookupBits-1:0];
  end

  logic [NoCounters:0]   stall;
  logic [NoCounters-1:0] en;
  logic                  en_w;
  logic [NoCounters-1:0] down;
  logic                  down_w;
  logic [NoCounters-1:0][axi_llc_pkg::MissCntWidth-1:0] q_miss;
  logic [axi_llc_pkg::MissCntMaxWWidth-1:0]             q_write;

  assign stall_o = |stall;

  always_comb begin : proc_control
    to_miss_o = 1'b0;
    for (int unsigned i = 0; i < NoCounters; i++) begin
      logic up_hit, down_hit, bucket_nonzero, bucket_full;
      up_hit         = (up_idx == IdxWidth'(i)) && cnt_up_i.valid;
      down_hit       = (down_idx == IdxWidth'(i)) && cnt_down_i.valid;
      bucket_full    = stall[i];
      bucket_nonzero = (|q_miss[i]) || bucket_full;

      en[i]   = 1'b0;
      down[i] = 1'b0;

      if (up_hit && !down_hit) begin
        if (!bucket_full) begin
          en[i]   = 1'b1;
          down[i] = 1'b0;
        end
      end else if (!up_hit && down_hit) begin
        if (bucket_nonzero) begin
          en[i]   = 1'b1;
          down[i] = 1'b1;
        end
      end

      if (up_idx == IdxWidth'(i)) begin
        to_miss_o = bucket_nonzero;
        if (cnt_up_i.rw) begin
          to_miss_o = to_miss_o || (|q_write) || stall[NoCounters];
        end
      end
    end
  end

  always_comb begin : proc_w_control
    logic w_up, w_down, w_full, w_nonzero;
    w_up      = cnt_up_i.valid   && cnt_up_i.rw;
    w_down    = cnt_down_i.valid && cnt_down_i.rw;
    w_full    = stall[NoCounters];
    w_nonzero = (|q_write) || w_full;

    en_w   = 1'b0;
    down_w = 1'b0;
    if (w_up && !w_down) begin
      if (!w_full) begin
        en_w   = 1'b1;
        down_w = 1'b0;
      end
    end else if (!w_up && w_down) begin
      if (w_nonzero) begin
        en_w   = 1'b1;
        down_w = 1'b1;
      end
    end
  end

  for (genvar j = 0; unsigned'(j) < NoCounters; j++) begin : gen_cmiss_counters
    counter #(
      .WIDTH      ( axi_llc_pkg::MissCntWidth )
    ) i_miss_cnt (
      .clk_i      (     clk_i ),
      .rst_ni     (    rst_ni ),
      .clear_i    (        '0 ),
      .en_i       (     en[j] ),
      .load_i     (        '0 ),
      .down_i     (   down[j] ),
      .d_i        (        '0 ),
      .q_o        ( q_miss[j] ),
      .overflow_o (  stall[j] )
    );
  end

  counter #(
    .WIDTH      ( axi_llc_pkg::MissCntMaxWWidth )
  ) i_miss_w_cnt (
    .clk_i      ( clk_i             ),
    .rst_ni     ( rst_ni            ),
    .clear_i    ( '0                ),
    .en_i       ( en_w              ),
    .load_i     ( '0                ),
    .down_i     ( down_w            ),
    .d_i        ( '0                ),
    .q_o        ( q_write           ),
    .overflow_o ( stall[NoCounters] )
  );
endmodule
