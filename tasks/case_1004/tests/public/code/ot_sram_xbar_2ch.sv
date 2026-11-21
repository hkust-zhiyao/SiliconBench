// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Two-Channel OpenTitan SRAM Crossbar with Atomic Read-Modify-Write Continuation.

`include "prim_assert.sv"

module ot_sram_xbar_2ch #(
  parameter int unsigned N_CH0  = 4,
  parameter int unsigned N_CH1  = 2,
  parameter int unsigned SramDw = 32,
  parameter int unsigned SramAw = 12,
  parameter bit          EnMask = 1'b1
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic [1:0]        arb_policy_i,

  // Channel 0 Masters
  input  logic [N_CH0-1:0]  req_ch0_i,
  input  logic [SramAw-1:0] req_addr_ch0_i  [N_CH0],
  input  logic [N_CH0-1:0]  req_write_ch0_i,
  input  logic [N_CH0-1:0]  req_amo_ch0_i,
  input  logic [SramDw-1:0] req_wdata_ch0_i [N_CH0],
  input  logic [SramDw-1:0] req_wmask_ch0_i [N_CH0],
  output logic [N_CH0-1:0]  gnt_ch0_o,
  output logic [N_CH0-1:0]  rsp_rvalid_ch0_o,
  output logic [SramDw-1:0] rsp_rdata_ch0_o [N_CH0],
  output logic [1:0]        rsp_error_ch0_o [N_CH0],

  // Channel 1 Masters
  input  logic [N_CH1-1:0]  req_ch1_i,
  input  logic [SramAw-1:0] req_addr_ch1_i  [N_CH1],
  input  logic [N_CH1-1:0]  req_write_ch1_i,
  input  logic [N_CH1-1:0]  req_amo_ch1_i,
  input  logic [SramDw-1:0] req_wdata_ch1_i [N_CH1],
  input  logic [SramDw-1:0] req_wmask_ch1_i [N_CH1],
  output logic [N_CH1-1:0]  gnt_ch1_o,
  output logic [N_CH1-1:0]  rsp_rvalid_ch1_o,
  output logic [SramDw-1:0] rsp_rdata_ch1_o [N_CH1],
  output logic [1:0]        rsp_error_ch1_o [N_CH1],

  // Downstream SRAM Interface
  output logic              sram_req_o,
  input  logic              sram_gnt_i,
  output logic [SramAw-1:0] sram_addr_o,
  output logic              sram_write_o,
  output logic              sram_amo_write_o,
  output logic [SramDw-1:0] sram_wdata_o,
  output logic [SramDw-1:0] sram_wmask_o,
  input  logic              sram_rvalid_i,
  input  logic [SramDw-1:0] sram_rdata_i,
  input  logic [1:0]        sram_rerror_i
);

  typedef struct packed {
    logic              write;
    logic              amo;
    logic [SramAw-1:0] addr;
    logic [SramDw-1:0] wdata;
    logic [SramDw-1:0] wmask;
  } ch_req_t;

  localparam int unsigned ChReqW = $bits(ch_req_t);

  ch_req_t ch0_in [N_CH0];
  ch_req_t ch1_in [N_CH1];
  ch_req_t ch0_sel, ch1_sel;
  logic    ch0_valid, ch0_ready;
  logic    ch1_valid, ch1_ready;

  for (genvar i = 0; i < N_CH0; i++) begin : g_ch0_pack
    assign ch0_in[i] = '{
      write: req_write_ch0_i[i],
      amo:   req_amo_ch0_i[i],
      addr:  req_addr_ch0_i[i],
      wdata: req_wdata_ch0_i[i],
      wmask: EnMask ? req_wmask_ch0_i[i] : {SramDw{1'b1}}
    };
  end

  for (genvar i = 0; i < N_CH1; i++) begin : g_ch1_pack
    assign ch1_in[i] = '{
      write: req_write_ch1_i[i],
      amo:   req_amo_ch1_i[i],
      addr:  req_addr_ch1_i[i],
      wdata: req_wdata_ch1_i[i],
      wmask: EnMask ? req_wmask_ch1_i[i] : {SramDw{1'b1}}
    };
  end

  prim_arbiter_tree #(
    .N          ( N_CH0  ),
    .DW         ( ChReqW ),
    .EnDataPort ( 1'b1   )
  ) u_arb_ch0 (
    .clk_i,
    .rst_ni,
    .policy_i  ( arb_policy_i[0] ),
    .req_chk_i ( 1'b1            ),
    .req_i     ( req_ch0_i       ),
    .data_i    ( ch0_in          ),
    .gnt_o     ( gnt_ch0_o       ),
    .idx_o     (                 ),
    .valid_o   ( ch0_valid       ),
    .data_o    ( ch0_sel         ),
    .ready_i   ( ch0_ready       )
  );

  prim_arbiter_tree #(
    .N          ( N_CH1  ),
    .DW         ( ChReqW ),
    .EnDataPort ( 1'b1   )
  ) u_arb_ch1 (
    .clk_i,
    .rst_ni,
    .policy_i  ( arb_policy_i[1] ),
    .req_chk_i ( 1'b1            ),
    .req_i     ( req_ch1_i       ),
    .data_i    ( ch1_in          ),
    .gnt_o     ( gnt_ch1_o       ),
    .idx_o     (                 ),
    .valid_o   ( ch1_valid       ),
    .data_o    ( ch1_sel         ),
    .ready_i   ( ch1_ready       )
  );

  logic [7:0] ch0_gnt_pad, ch1_gnt_pad;
  assign ch0_gnt_pad = {{(8 - N_CH0){1'b0}}, gnt_ch0_o};
  assign ch1_gnt_pad = {{(8 - N_CH1){1'b0}}, gnt_ch1_o};

  prim_sram_arbiter #(
    .N      ( N_CH0 + N_CH1 ),
    .SramDw ( SramDw        ),
    .SramAw ( SramAw        ),
    .EnMask ( EnMask        )
  ) u_sram_mux (
    .clk_i,
    .rst_ni,
    .ch0_valid_i   ( ch0_valid                            ),
    .ch0_ready_o   ( ch0_ready                            ),
    .ch0_write_i   ( ch0_sel.write                        ),
    .ch0_amo_i     ( ch0_sel.amo                          ),
    .ch0_addr_i    ( ch0_sel.addr                         ),
    .ch0_wdata_i   ( ch0_sel.wdata                        ),
    .ch0_wmask_i   ( ch0_sel.wmask                        ),
    .ch0_gnt_i     ( ch0_gnt_pad                          ),
    .ch1_valid_i   ( ch1_valid                            ),
    .ch1_ready_o   ( ch1_ready                            ),
    .ch1_write_i   ( ch1_sel.write                        ),
    .ch1_amo_i     ( ch1_sel.amo                          ),
    .ch1_addr_i    ( ch1_sel.addr                         ),
    .ch1_wdata_i   ( ch1_sel.wdata                        ),
    .ch1_wmask_i   ( ch1_sel.wmask                        ),
    .ch1_gnt_i     ( ch1_gnt_pad                          ),
    .N_CH0_i       ( 8'(N_CH0)                            ),
    .rsp_rvalid_o  ( {rsp_rvalid_ch1_o, rsp_rvalid_ch0_o} ),
    .sram_req_o,
    .sram_gnt_i,
    .sram_addr_o,
    .sram_write_o,
    .sram_amo_write_o,
    .sram_wdata_o,
    .sram_wmask_o,
    .sram_rvalid_i
  );

  for (genvar i = 0; i < N_CH0; i++) begin : g_rsp0
    assign rsp_rdata_ch0_o[i] = sram_rdata_i;
    assign rsp_error_ch0_o[i] = sram_rerror_i;
  end
  for (genvar i = 0; i < N_CH1; i++) begin : g_rsp1
    assign rsp_rdata_ch1_o[i] = sram_rdata_i;
    assign rsp_error_ch1_o[i] = sram_rerror_i;
  end

endmodule
