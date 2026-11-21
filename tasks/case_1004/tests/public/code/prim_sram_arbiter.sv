// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Two-Channel SRAM Request Mux, Response FIFO Steering, and Atomic RMW Sequencer.

`include "prim_assert.sv"

module prim_sram_arbiter #(
  parameter int unsigned N      = 6,
  parameter int unsigned SramDw = 32,
  parameter int unsigned SramAw = 12,
  parameter bit          EnMask = 1'b1
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  // Channel 0 Winner
  input  logic              ch0_valid_i,
  output logic              ch0_ready_o,
  input  logic              ch0_write_i,
  input  logic              ch0_amo_i,
  input  logic [SramAw-1:0] ch0_addr_i,
  input  logic [SramDw-1:0] ch0_wdata_i,
  input  logic [SramDw-1:0] ch0_wmask_i,
  input  logic [7:0]        ch0_gnt_i,

  // Channel 1 Winner
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

  // Downstream SRAM Interface
  output logic              sram_req_o,
  input  logic              sram_gnt_i,
  output logic [SramAw-1:0] sram_addr_o,
  output logic              sram_write_o,
  output logic              sram_amo_write_o,
  output logic [SramDw-1:0] sram_wdata_o,
  output logic [SramDw-1:0] sram_wmask_o,
  input  logic              sram_rvalid_i
);

  logic unused_n_ch0;
  assign unused_n_ch0 = ^N_CH0_i;

  // Channel arbitration (CH0 vs CH1)
  logic rr_flag_q;
  logic sel_ch1;
  logic mux_valid, mux_ready;
  logic mux_write, mux_amo;
  logic [SramAw-1:0] mux_addr;
  logic [SramDw-1:0] mux_wdata, mux_wmask;

  assign mux_valid = ch0_valid_i | ch1_valid_i;
  assign sel_ch1   = ~ch0_valid_i | (rr_flag_q & ch1_valid_i);

  assign ch0_ready_o = (~sel_ch1) & mux_ready;
  assign ch1_ready_o = ( sel_ch1) & mux_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rr_flag_q <= 1'b0;
    end else if (mux_valid && mux_ready) begin
      rr_flag_q <= ~rr_flag_q;
    end
  end

  assign mux_write = sel_ch1 ? ch1_write_i : ch0_write_i;
  assign mux_amo   = sel_ch1 ? ch1_amo_i   : ch0_amo_i;
  assign mux_addr  = sel_ch1 ? ch1_addr_i  : ch0_addr_i;
  assign mux_wdata = sel_ch1 ? ch1_wdata_i : ch0_wdata_i;
  assign mux_wmask = sel_ch1 ? ch1_wmask_i : ch0_wmask_i;

  // Two-cycle Atomic Read-Modify-Write (AMO) Sequencer:
  // When a read (!mux_write) with mux_amo==1 is granted on the SRAM port,
  // issue a follow-up write on the next cycle.
  logic              amo_active_q;
  logic [SramAw-1:0] amo_addr_q;
  logic [SramDw-1:0] amo_wmask_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      amo_active_q <= 1'b0;
      amo_addr_q   <= '0;
      amo_wmask_q  <= '0;
    end else if (!amo_active_q) begin
      if (mux_valid && sram_gnt_i && !mux_write && mux_amo) begin
        amo_active_q <= 1'b1;
        amo_addr_q   <= mux_addr;
        amo_wmask_q  <= mux_wmask;
      end
    end else if (sram_gnt_i) begin
      amo_active_q <= 1'b0;
    end
  end

  assign mux_ready        = ~amo_active_q & sram_gnt_i;
  assign sram_req_o       = amo_active_q | mux_valid;
  assign sram_write_o     = amo_active_q ? 1'b1      : mux_write;
  assign sram_amo_write_o = amo_active_q;
  assign sram_addr_o      = amo_active_q ? amo_addr_q : mux_addr;
  assign sram_wdata_o     = amo_active_q ? {SramDw{1'b1}} : mux_wdata;
  assign sram_wmask_o     = EnMask ? (amo_active_q ? amo_wmask_q : mux_wmask) : {SramDw{1'b1}};

  // Response steering FIFO for read requests
  logic [N-1:0] gnt_combined;
  always_comb begin
    gnt_combined = '0;
    for (int unsigned i = 0; i < N; i++) begin
      if (i < 32'(N_CH0_i)) begin
        gnt_combined[i] = (~sel_ch1) & ch0_gnt_i[i];
      end else begin
        gnt_combined[i] = sel_ch1 & ch1_gnt_i[i - 32'(N_CH0_i)];
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
    .clr_i    ( 1'b0                         ),
    .wvalid_i ( sram_req_o & ~sram_write_o   ),
    .wready_o (                              ),
    .wdata_i  ( gnt_combined                 ),
    .rvalid_o (                              ),
    .rready_i ( sram_ack                     ),
    .rdata_o  ( steer                        ),
    .full_o   (                              ),
    .depth_o  (                              ),
    .err_o    (                              )
  );

  assign rsp_rvalid_o = steer & {N{sram_rvalid_i}};

endmodule
