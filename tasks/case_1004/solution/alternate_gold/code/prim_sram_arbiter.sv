// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Alternate structural implementation of prim_sram_arbiter.

`include "prim_assert.sv"

module prim_sram_arbiter #(
  parameter int unsigned N      = 6,
  parameter int unsigned SramDw = 32,
  parameter int unsigned SramAw = 12,
  parameter bit          EnMask = 1'b1
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              ch0_valid_i,
  output logic              ch0_ready_o,
  input  logic              ch0_write_i,
  input  logic              ch0_amo_i,
  input  logic [SramAw-1:0] ch0_addr_i,
  input  logic [SramDw-1:0] ch0_wdata_i,
  input  logic [SramDw-1:0] ch0_wmask_i,
  input  logic [7:0]        ch0_gnt_i,

  input  logic              ch1_valid_i,
  output logic              ch1_ready_o,
  input  logic              ch1_write_i,
  input  logic              ch1_amo_i,
  input  logic [SramAw-1:0] ch1_addr_i,
  input  logic [SramDw-1:0] ch1_wdata_i,
  input  logic [SramDw-1:0] ch1_wmask_i,
  input  logic [7:0]        ch1_gnt_i,

  input  logic [7:0]        N_CH0_i,
  output logic [N-1:0]      rsp_rvalid_o,

  output logic              sram_req_o,
  input  logic              sram_gnt_i,
  output logic [SramAw-1:0] sram_addr_o,
  output logic              sram_write_o,
  output logic              sram_amo_write_o,
  output logic [SramDw-1:0] sram_wdata_o,
  output logic [SramDw-1:0] sram_wmask_o,
  input  logic              sram_rvalid_i
);

  logic              pref_ch1_q;
  logic              hold_ch_q;
  logic              held_ch1_q;
  logic              v0, v1, use_ch1;
  logic              arb_v, arb_r;

  always_comb begin
    if (hold_ch_q && (held_ch1_q ? ch1_valid_i : ch0_valid_i)) begin
      v0 = ~held_ch1_q & ch0_valid_i;
      v1 =  held_ch1_q & ch1_valid_i;
    end else begin
      v0 = ch0_valid_i;
      v1 = ch1_valid_i;
    end
    arb_v   = v0 | v1;
    use_ch1 = v1 & (~v0 | pref_ch1_q);
  end

  assign ch0_ready_o = arb_r & v0 & ~use_ch1;
  assign ch1_ready_o = arb_r & v1 &  use_ch1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pref_ch1_q <= 1'b0;
      hold_ch_q  <= 1'b0;
      held_ch1_q <= 1'b0;
    end else if (arb_v && arb_r) begin
      pref_ch1_q <= ~use_ch1;
      hold_ch_q  <= 1'b0;
    end else if (arb_v && !arb_r) begin
      hold_ch_q  <= 1'b1;
      held_ch1_q <= use_ch1;
    end else begin
      hold_ch_q  <= 1'b0;
    end
  end

  logic              sel_write, sel_amo;
  logic [SramAw-1:0] sel_addr;
  logic [SramDw-1:0] sel_wdata, sel_wmask;

  assign sel_write = use_ch1 ? ch1_write_i : ch0_write_i;
  assign sel_amo   = use_ch1 ? ch1_amo_i   : ch0_amo_i;
  assign sel_addr  = use_ch1 ? ch1_addr_i  : ch0_addr_i;
  assign sel_wdata = use_ch1 ? ch1_wdata_i : ch0_wdata_i;
  assign sel_wmask = use_ch1 ? ch1_wmask_i : ch0_wmask_i;

  logic              amo_st_q;
  logic [SramAw-1:0] amo_addr_q;
  logic [SramDw-1:0] amo_wdata_q, amo_wmask_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      amo_st_q    <= 1'b0;
      amo_addr_q  <= '0;
      amo_wdata_q <= '0;
      amo_wmask_q <= '0;
    end else if (!amo_st_q) begin
      if (arb_v && sram_gnt_i && !sel_write && sel_amo) begin
        amo_st_q    <= 1'b1;
        amo_addr_q  <= sel_addr;
        amo_wdata_q <= sel_wdata;
        amo_wmask_q <= sel_wmask;
      end
    end else if (sram_gnt_i) begin
      amo_st_q <= 1'b0;
    end
  end

  assign arb_r            = ~amo_st_q & sram_gnt_i;
  assign sram_req_o       = amo_st_q | arb_v;
  assign sram_write_o     = amo_st_q ? 1'b1        : sel_write;
  assign sram_amo_write_o = amo_st_q;
  assign sram_addr_o      = amo_st_q ? amo_addr_q  : sel_addr;
  assign sram_wdata_o     = amo_st_q ? amo_wdata_q : sel_wdata;
  assign sram_wmask_o     = EnMask ? (amo_st_q ? amo_wmask_q : sel_wmask) : {SramDw{1'b1}};

  logic [N-1:0] gnt_vec;
  always_comb begin
    gnt_vec = '0;
    for (int unsigned i = 0; i < N; i++) begin
      if (i < 32'(N_CH0_i)) begin
        gnt_vec[i] = (~use_ch1) & ch0_gnt_i[i];
      end else begin
        gnt_vec[i] = use_ch1 & ch1_gnt_i[i - 32'(N_CH0_i)];
      end
    end
  end

  logic [N-1:0] steer;
  logic         sram_ack;
  assign sram_ack = sram_rvalid_i & (|steer);

  prim_fifo_sync #(
    .Width            ( N    ),
    .Pass             ( 1'b0 ),
    .Depth            ( 4    ),
    .OutputZeroIfEmpty( 1'b1 ),
    .NeverClears      ( 1'b1 )
  ) u_req_fifo (
    .clk_i,
    .rst_ni,
    .clr_i    ( 1'b0                                   ),
    .wvalid_i ( sram_req_o & sram_gnt_i & ~sram_write_o ),
    .wready_o (                                        ),
    .wdata_i  ( gnt_vec                                ),
    .rvalid_o (                                        ),
    .rready_i ( sram_ack                               ),
    .rdata_o  ( steer                                  ),
    .full_o   (                                        ),
    .depth_o  (                                        ),
    .err_o    (                                        )
  );

  assign rsp_rvalid_o = steer & {N{sram_rvalid_i}};

endmodule
