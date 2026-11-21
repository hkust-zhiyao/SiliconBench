// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module mbx_sramrwarb
  import  tlul_pkg::*;
#(
  parameter int unsigned CfgSramAddrWidth = 32,
  parameter int unsigned CfgSramDataWidth = 32
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  output  tlul_pkg::tl_h2d_t          tl_host_o,
  input   tlul_pkg::tl_d2h_t          tl_host_i,
  output  logic                       intg_err_o,
  output  logic                       sram_err_o,

  input   logic                       hostif_control_abort_clear_i,

  input  logic                        imbx_sram_write_req_i,
  output logic                        imbx_sram_write_gnt_o,
  input  logic [CfgSramAddrWidth-1:0] imbx_sram_write_ptr_i,
  input  logic [CfgSramDataWidth-1:0] imbx_write_data_i,
  output logic                        imbx_sram_all_vld_rcvd_o,
  input  logic                        ombx_sram_read_req_i,
  output logic                        ombx_sram_read_gnt_o,
  input  logic [CfgSramAddrWidth-1:0] ombx_sram_read_ptr_i,
  output logic                        ombx_sram_read_resp_vld_o,
  output logic [CfgSramDataWidth-1:0] ombx_sram_read_resp_o
);
  import  prim_mubi_pkg::*;
  localparam  int unsigned LCFG_MAX_REQS = 4;
  localparam  int unsigned LCFG_MAX_REQS_LOG2 = $clog2(LCFG_MAX_REQS) + 1;

  logic arb_read_winner, arb_write_winner;
  assign arb_read_winner  = ombx_sram_read_req_i;
  assign arb_write_winner = imbx_sram_write_req_i & ~arb_read_winner;

  logic sram_gnt, sram_valid, sram_err, max_outstanding_reqs_reached;
  assign ombx_sram_read_gnt_o  = arb_read_winner  & (~max_outstanding_reqs_reached & sram_gnt);
  assign imbx_sram_write_gnt_o = arb_write_winner & (~max_outstanding_reqs_reached & sram_gnt);

  logic [CfgSramAddrWidth-1:0] sram_address;
  assign sram_address = arb_read_winner ? ombx_sram_read_ptr_i : imbx_sram_write_ptr_i;

  logic sram_req;
  assign sram_req = ombx_sram_read_req_i | imbx_sram_write_req_i;

  logic [LCFG_MAX_REQS_LOG2-1:0] outstanding_req_count_q;
  logic inc_cnt, dec_cnt, any_outstanding_reqs;

  assign inc_cnt              = sram_req & ~max_outstanding_reqs_reached & sram_gnt;
  assign any_outstanding_reqs = inc_cnt | (outstanding_req_count_q != '0);
  assign dec_cnt              = sram_valid & any_outstanding_reqs;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      outstanding_req_count_q <= '0;
    end else if (hostif_control_abort_clear_i) begin
      outstanding_req_count_q <= '0;
    end else if (inc_cnt ^ dec_cnt) begin
      outstanding_req_count_q <= inc_cnt ? (outstanding_req_count_q + 1'b1)
                                         : (outstanding_req_count_q - 1'b1);
    end
  end

  assign max_outstanding_reqs_reached = (outstanding_req_count_q == LCFG_MAX_REQS);
  assign imbx_sram_all_vld_rcvd_o     = (outstanding_req_count_q == '0) & ~sram_req;

  tlul_adapter_host #(
    .MAX_REQS              ( LCFG_MAX_REQS ),
    .EnableDataIntgGen     ( 1             ),
    .EnableRspDataIntgCheck( 1             )
  )  u_sram_host_adapter (
    .clk_i             ( clk_i                                    ),
    .rst_ni            ( rst_ni                                   ),
    .req_i             ( sram_req & ~max_outstanding_reqs_reached ),
    .gnt_o             ( sram_gnt                                 ),
    .addr_i            ( sram_address                             ),
    .we_i              ( arb_write_winner                         ),
    .wdata_i           ( imbx_write_data_i                        ),
    .wdata_intg_i      ( TL_A_USER_DEFAULT.data_intg              ),
    .be_i              ( {top_pkg::TL_DBW{1'b1}}                  ),
    .instr_type_i      ( prim_mubi_pkg::MuBi4False                ),
    .user_rsvd_i       ( '0                                       ),
    .valid_o           ( sram_valid                               ),
    .rdata_o           ( ombx_sram_read_resp_o                    ),
    .rdata_intg_o      (                                          ),
    .err_o             ( sram_err                                 ),
    .intg_err_o        ( intg_err_o                               ),
    .tl_o              ( tl_host_o                                ),
    .tl_i              ( tl_host_i                                )
  );

  assign sram_err_o                 = sram_err & sram_valid;
  assign ombx_sram_read_resp_vld_o  = sram_valid & any_outstanding_reqs &
                                      (tl_host_i.d_opcode == tlul_pkg::AccessAckData);

endmodule
