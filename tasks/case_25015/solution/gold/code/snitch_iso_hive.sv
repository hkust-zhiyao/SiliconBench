// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "snitch_vm/typedef.svh"

/// Shared isochronous VM (PTW) and RV32M MulDiv subsystem for `CoreCount` cores.
module snitch_iso_hive #(
  parameter int unsigned CoreCount       = 4,
  parameter bit          IsoCrossing     = 1,
  parameter int unsigned AddrWidth       = 34,
  parameter int unsigned NarrowDataWidth = 32,
  parameter bit          VMSupport       = 1,
  parameter type         dreq_t          = logic,
  parameter type         drsp_t          = logic,
  parameter type         hive_req_t      = logic,
  parameter type         hive_rsp_t      = logic,
  parameter type         addr_t          = logic [AddrWidth-1:0],
  parameter type         data_t          = logic [NarrowDataWidth-1:0]
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic                      test_mode_i,
  input  logic                      clk_d2_bypass_i,
  output logic                      clk_d2_o,
  input  hive_req_t [CoreCount-1:0] hive_req_i,
  output hive_rsp_t [CoreCount-1:0] hive_rsp_o,
  output dreq_t                     ptw_data_req_o,
  input  drsp_t                     ptw_data_rsp_i
);
  localparam int unsigned IdWidth = 5;
  localparam int unsigned LogCoreCount = cf_math_pkg::idx_width(CoreCount);
  localparam int unsigned ExtendedIdWidth = IdWidth + LogCoreCount;

  logic clk_d2;
  assign clk_d2_o = clk_d2;

  if (IsoCrossing) begin : gen_clk_divider
    snitch_clkdiv2 i_snitch_clkdiv2 (
      .clk_i       ( clk_i           ),
      .rst_ni      ( rst_ni          ),
      .test_mode_i ( test_mode_i     ),
      .bypass_i    ( clk_d2_bypass_i ),
      .clk_o       ( clk_d2          )
    );
  end else begin : gen_no_clk_divider
    assign clk_d2 = clk_i;
  end

  // -------------------
  // Shared VM Subsystem
  // -------------------
  `SNITCH_VM_TYPEDEF(AddrWidth)

  typedef struct packed {
    snitch_pkg::va_t va;
    pa_t             ppn;
  } va_arb_t;

  if (VMSupport) begin : gen_ptw
    logic [2*CoreCount-1:0] ptw_valid, ptw_ready;
    va_arb_t [2*CoreCount-1:0] ptw_req_in;
    va_arb_t ptw_req_out;

    l0_pte_t ptw_pte;
    logic    ptw_is_4mega;

    for (genvar i = 0; i < CoreCount; i++) begin : gen_connect_ptw_core
      for (genvar j = 0; j < 2; j++) begin : gen_connect_ptw_port
        assign ptw_req_in[2*i+j].va  = hive_req_i[i].ptw_va[j];
        assign ptw_req_in[2*i+j].ppn = hive_req_i[i].ptw_ppn[j];
        assign ptw_valid[2*i+j]      = hive_req_i[i].ptw_valid[j];
      end
      assign hive_rsp_o[i].ptw_ready    = ptw_ready[2*i+:2];
      assign hive_rsp_o[i].ptw_pte      = {2{ptw_pte}};
      assign hive_rsp_o[i].ptw_is_4mega = {2{ptw_is_4mega}};
    end

    logic ptw_valid_out, ptw_ready_out;

    stream_arbiter #(
      .DATA_T ( va_arb_t    ),
      .N_INP  ( 2*CoreCount )
    ) i_stream_arbiter (
      .clk_i       ( clk_d2        ),
      .rst_ni      ( rst_ni        ),
      .inp_data_i  ( ptw_req_in    ),
      .inp_valid_i ( ptw_valid     ),
      .inp_ready_o ( ptw_ready     ),
      .oup_data_o  ( ptw_req_out   ),
      .oup_valid_o ( ptw_valid_out ),
      .oup_ready_i ( ptw_ready_out )
    );

    dreq_t ptw_req;
    drsp_t ptw_rsp;

    snitch_ptw #(
      .AddrWidth  ( AddrWidth       ),
      .DataWidth  ( NarrowDataWidth ),
      .pa_t       ( pa_t            ),
      .l0_pte_t   ( l0_pte_t        ),
      .pte_sv32_t ( pte_sv32_t      ),
      .dreq_t     ( dreq_t          ),
      .drsp_t     ( drsp_t          )
    ) i_snitch_ptw (
      .clk_i      ( clk_d2          ),
      .rst_ni     ( rst_ni          ),
      .ppn_i      ( ptw_req_out.ppn ),
      .valid_i    ( ptw_valid_out   ),
      .ready_o    ( ptw_ready_out   ),
      .va_i       ( ptw_req_out.va  ),
      .pte_o      ( ptw_pte         ),
      .is_4mega_o ( ptw_is_4mega    ),
      .data_req_o ( ptw_req         ),
      .data_rsp_i ( ptw_rsp         )
    );

    reqrsp_iso #(
      .AddrWidth ( AddrWidth       ),
      .DataWidth ( NarrowDataWidth ),
      .req_t     ( dreq_t          ),
      .rsp_t     ( drsp_t          ),
      .BypassReq ( 1'b0            ),
      .BypassRsp ( 1'b0            )
    ) i_reqrsp_iso (
      .src_clk_i  ( clk_d2         ),
      .src_rst_ni ( rst_ni         ),
      .src_req_i  ( ptw_req        ),
      .src_rsp_o  ( ptw_rsp        ),
      .dst_clk_i  ( clk_i          ),
      .dst_rst_ni ( rst_ni         ),
      .dst_req_o  ( ptw_data_req_o ),
      .dst_rsp_i  ( ptw_data_rsp_i )
    );
  end else begin : gen_no_ptw
    assign ptw_data_req_o = '0;
    for (genvar i = 0; i < CoreCount; i++) begin : gen_tie_ptw_core
      assign hive_rsp_o[i].ptw_ready    = '0;
      assign hive_rsp_o[i].ptw_pte      = '0;
      assign hive_rsp_o[i].ptw_is_4mega = '0;
    end
  end

  // ----------------------------------
  // Shared Accelerator Interconnect
  // ----------------------------------
  typedef struct packed {
    logic [31:0]                addr;
    logic [ExtendedIdWidth-1:0] id;
    logic [31:0]                data_op;
    data_t                      data_arga;
    data_t                      data_argb;
    data_t                      data_argc;
  } acc_req_t;

  typedef struct packed {
    logic [ExtendedIdWidth-1:0] id;
    logic                       error;
    data_t                      data;
  } acc_resp_t;

  acc_req_t  acc_req_sfu, acc_req_sfu_q;
  logic      acc_req_sfu_valid, acc_req_sfu_valid_q;
  logic      acc_req_sfu_ready, acc_req_sfu_ready_q;

  acc_resp_t acc_resp_sfu, acc_resp_sfu_q;
  logic      acc_resp_sfu_valid, acc_resp_sfu_valid_q;
  logic      acc_resp_sfu_ready, acc_resp_sfu_ready_q;

  acc_req_t [CoreCount-1:0] acc_req_ext;
  logic     [CoreCount-1:0] acc_qvalid;
  logic     [CoreCount-1:0] acc_qready;
  logic     [CoreCount-1:0] acc_pvalid;
  logic     [CoreCount-1:0] acc_pready;

  for (genvar i = 0; i < CoreCount; i++) begin : gen_core
    assign acc_qvalid[i]            = hive_req_i[i].acc_qvalid;
    assign acc_pready[i]            = hive_req_i[i].acc_pready;
    assign hive_rsp_o[i].acc_qready = acc_qready[i];
    assign hive_rsp_o[i].acc_pvalid = acc_pvalid[i];
    assign acc_req_ext[i].id        = {i[LogCoreCount-1:0], hive_req_i[i].acc_req.id};
    assign acc_req_ext[i].addr      = hive_req_i[i].acc_req.addr;
    assign acc_req_ext[i].data_op   = hive_req_i[i].acc_req.data_op;
    assign acc_req_ext[i].data_arga = hive_req_i[i].acc_req.data_arga;
    assign acc_req_ext[i].data_argb = hive_req_i[i].acc_req.data_argb;
    assign acc_req_ext[i].data_argc = hive_req_i[i].acc_req.data_argc;
  end

  if (CoreCount > 1) begin : gen_shared_interconnect
    stream_arbiter #(
      .DATA_T  ( acc_req_t ),
      .N_INP   ( CoreCount ),
      .ARBITER ( "rr"      )
    ) i_stream_arbiter (
      .clk_i       ( clk_i             ),
      .rst_ni      ( rst_ni            ),
      .inp_data_i  ( acc_req_ext       ),
      .inp_valid_i ( acc_qvalid        ),
      .inp_ready_o ( acc_qready        ),
      .oup_data_o  ( acc_req_sfu       ),
      .oup_valid_o ( acc_req_sfu_valid ),
      .oup_ready_i ( acc_req_sfu_ready )
    );
  end else begin : gen_no_shared_interconnect
    assign acc_req_sfu       = acc_req_ext[0];
    assign acc_req_sfu_valid = acc_qvalid[0];
    assign acc_qready[0]     = acc_req_sfu_ready;
  end

  spill_register #(
    .T      ( acc_resp_t ),
    .Bypass ( 1'b0       )
  ) i_spill_register_muldiv_rsp (
    .clk_i   ( clk_i                ),
    .rst_ni  ( rst_ni               ),
    .valid_i ( acc_resp_sfu_valid   ),
    .ready_o ( acc_resp_sfu_ready   ),
    .data_i  ( acc_resp_sfu         ),
    .valid_o ( acc_resp_sfu_valid_q ),
    .ready_i ( acc_resp_sfu_ready_q ),
    .data_o  ( acc_resp_sfu_q       )
  );

  logic [LogCoreCount-1:0] resp_sel;
  assign resp_sel = acc_resp_sfu_q.id[ExtendedIdWidth-1:IdWidth];

  stream_demux #(
    .N_OUP ( CoreCount )
  ) i_stream_demux (
    .inp_valid_i ( acc_resp_sfu_valid_q ),
    .inp_ready_o ( acc_resp_sfu_ready_q ),
    .oup_sel_i   ( resp_sel             ),
    .oup_valid_o ( acc_pvalid           ),
    .oup_ready_i ( acc_pready           )
  );

  for (genvar i = 0; i < CoreCount; i++) begin : gen_id_extension
    assign hive_rsp_o[i].acc_resp.id    = acc_resp_sfu_q.id[IdWidth-1:0];
    assign hive_rsp_o[i].acc_resp.error = acc_resp_sfu_q.error;
    assign hive_rsp_o[i].acc_resp.data  = acc_resp_sfu_q.data;
  end

  spill_register #(
    .T      ( acc_req_t ),
    .Bypass ( 1'b0      )
  ) i_spill_register_muldiv (
    .clk_i   ( clk_i               ),
    .rst_ni  ( rst_ni              ),
    .valid_i ( acc_req_sfu_valid   ),
    .ready_o ( acc_req_sfu_ready   ),
    .data_i  ( acc_req_sfu         ),
    .valid_o ( acc_req_sfu_valid_q ),
    .ready_i ( acc_req_sfu_ready_q ),
    .data_o  ( acc_req_sfu_q       )
  );

  snitch_shared_muldiv #(
    .DataWidth ( NarrowDataWidth ),
    .IdWidth   ( ExtendedIdWidth )
  ) i_snitch_shared_muldiv (
    .clk_i            ( clk_i                   ),
    .rst_ni           ( rst_ni                  ),
    .acc_qaddr_i      ( acc_req_sfu_q.addr      ),
    .acc_qid_i        ( acc_req_sfu_q.id        ),
    .acc_qdata_op_i   ( acc_req_sfu_q.data_op   ),
    .acc_qdata_arga_i ( acc_req_sfu_q.data_arga ),
    .acc_qdata_argb_i ( acc_req_sfu_q.data_argb ),
    .acc_qdata_argc_i ( acc_req_sfu_q.data_argc ),
    .acc_qvalid_i     ( acc_req_sfu_valid_q     ),
    .acc_qready_o     ( acc_req_sfu_ready_q     ),
    .acc_pdata_o      ( acc_resp_sfu.data       ),
    .acc_pid_o        ( acc_resp_sfu.id         ),
    .acc_perror_o     ( acc_resp_sfu.error      ),
    .acc_pvalid_o     ( acc_resp_sfu_valid      ),
    .acc_pready_i     ( acc_resp_sfu_ready      )
  );

endmodule
