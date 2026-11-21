// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "reqrsp_interface/typedef.svh"
`include "snitch_vm/typedef.svh"

/// Read-only cluster subsystem wrapper integrating per-core L0 ITLB/DTLBs (`clk_d2`),
/// isochronous crossings (`clk_i <-> clk_d2`), `snitch_iso_hive`, `snitch_clkdiv2`,
/// `snitch_ptw`, and `snitch_shared_muldiv`.
module snitch_iso_cluster_subsys #(
  parameter int unsigned CoreCount     = 4,
  parameter int unsigned AddrWidth     = 34,
  parameter int unsigned DataWidth     = 32,
  parameter int unsigned NrTlbEntries  = 2,
  parameter int unsigned PPNWidth      = AddrWidth - snitch_pkg::PAGE_SHIFT
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  input  logic                                test_mode_i,
  input  logic                                clk_d2_bypass_i,

  // Per-core dual-port L0 TLB channels (ch = 2*core + port; port 0 = ITLB, port 1 = DTLB)
  input  logic [2*CoreCount-1:0]              tlb_req_valid_i,
  output logic [2*CoreCount-1:0]              tlb_req_ready_o,
  input  logic [2*CoreCount-1:0]              tlb_req_flush_i,
  input  logic [2*CoreCount*20-1:0]           tlb_req_va_i,
  input  logic [2*CoreCount*PPNWidth-1:0]     tlb_req_ppn_i,
  input  logic [2*CoreCount*2-1:0]            tlb_req_priv_i,
  input  logic [2*CoreCount-1:0]              tlb_req_read_i,
  input  logic [2*CoreCount-1:0]              tlb_req_write_i,
  input  logic [2*CoreCount-1:0]              tlb_req_exec_i,

  output logic [2*CoreCount-1:0]              tlb_rsp_valid_o,
  input  logic [2*CoreCount-1:0]              tlb_rsp_ready_i,
  output logic [2*CoreCount*PPNWidth-1:0]     tlb_rsp_pa_o,
  output logic [2*CoreCount-1:0]              tlb_rsp_fault_o,

  // Per-core shared RV32M offload channels (`clk_i` domain)
  input  logic [CoreCount-1:0]                acc_qvalid_i,
  output logic [CoreCount-1:0]                acc_qready_o,
  input  logic [CoreCount*5-1:0]              acc_qid_i,
  input  logic [CoreCount*32-1:0]             acc_qop_i,
  input  logic [CoreCount*DataWidth-1:0]      acc_qarga_i,
  input  logic [CoreCount*DataWidth-1:0]      acc_qargb_i,
  input  logic [CoreCount*DataWidth-1:0]      acc_qargc_i,

  output logic [CoreCount-1:0]                acc_pvalid_o,
  input  logic [CoreCount-1:0]                acc_pready_i,
  output logic [CoreCount*5-1:0]              acc_pid_o,
  output logic [CoreCount*DataWidth-1:0]      acc_pdata_o,
  output logic [CoreCount-1:0]                acc_perror_o,

  // Shared PTW page-table memory read port (`clk_i` domain)
  output logic                                ptw_mem_qvalid_o,
  input  logic                                ptw_mem_qready_i,
  output logic [AddrWidth-1:0]                ptw_mem_qaddr_o,
  output logic [2:0]                          ptw_mem_qsize_o,
  input  logic                                ptw_mem_pvalid_i,
  output logic                                ptw_mem_pready_o,
  input  logic [DataWidth-1:0]                ptw_mem_pdata_i,
  input  logic                                ptw_mem_perror_i
);

  typedef logic [AddrWidth-1:0]   addr_t;
  typedef logic [DataWidth-1:0]   data_t;
  typedef logic [DataWidth/8-1:0] strb_t;

  `REQRSP_TYPEDEF_ALL(ptw_mem, addr_t, data_t, strb_t)
  `SNITCH_VM_TYPEDEF(AddrWidth)

  typedef struct packed {
    logic [31:0] addr;
    logic [4:0]  id;
    logic [31:0] data_op;
    data_t       data_arga;
    data_t       data_argb;
    data_t       data_argc;
  } core_acc_req_t;

  typedef struct packed {
    logic [4:0] id;
    logic       error;
    data_t      data;
  } core_acc_resp_t;

  typedef struct packed {
    core_acc_req_t       acc_req;
    logic                acc_qvalid;
    logic                acc_pready;
    logic [1:0]          ptw_valid;
    snitch_pkg::va_t [1:0] ptw_va;
    pa_t  [1:0]          ptw_ppn;
  } hive_req_t;

  typedef struct packed {
    logic                acc_qready;
    core_acc_resp_t      acc_resp;
    logic                acc_pvalid;
    logic [1:0]          ptw_ready;
    l0_pte_t [1:0]       ptw_pte;
    logic [1:0]          ptw_is_4mega;
  } hive_rsp_t;

  typedef struct packed {
    logic                  flush;
    snitch_pkg::va_t       va;
    pa_t                   ppn;
    snitch_pkg::priv_lvl_t priv;
    logic                  is_read;
    logic                  is_write;
    logic                  is_exec;
  } tlb_cmd_t;

  typedef struct packed {
    pa_t  pa;
    logic fault;
  } tlb_rsp_t;

  logic clk_d2;
  hive_req_t [CoreCount-1:0] hive_req;
  hive_rsp_t [CoreCount-1:0] hive_rsp;
  ptw_mem_req_t ptw_dreq;
  ptw_mem_rsp_t ptw_drsp;

  assign ptw_mem_qvalid_o   = ptw_dreq.q_valid;
  assign ptw_mem_qaddr_o    = ptw_dreq.q.addr;
  assign ptw_mem_qsize_o    = ptw_dreq.q.size;
  assign ptw_mem_pready_o   = ptw_dreq.p_ready;
  assign ptw_drsp.q_ready   = ptw_mem_qready_i;
  assign ptw_drsp.p_valid   = ptw_mem_pvalid_i;
  assign ptw_drsp.p.data    = ptw_mem_pdata_i;
  assign ptw_drsp.p.error   = ptw_mem_perror_i;

  for (genvar i = 0; i < CoreCount; i++) begin : g_core
    assign hive_req[i].acc_qvalid        = acc_qvalid_i[i];
    assign hive_req[i].acc_pready        = acc_pready_i[i];
    assign hive_req[i].acc_req.addr      = 32'(snitch_pkg::SHARED_MULDIV);
    assign hive_req[i].acc_req.id        = acc_qid_i[i*5 +: 5];
    assign hive_req[i].acc_req.data_op   = acc_qop_i[i*32 +: 32];
    assign hive_req[i].acc_req.data_arga = acc_qarga_i[i*DataWidth +: DataWidth];
    assign hive_req[i].acc_req.data_argb = acc_qargb_i[i*DataWidth +: DataWidth];
    assign hive_req[i].acc_req.data_argc = acc_qargc_i[i*DataWidth +: DataWidth];

    assign acc_qready_o[i]                  = hive_rsp[i].acc_qready;
    assign acc_pvalid_o[i]                  = hive_rsp[i].acc_pvalid;
    assign acc_pid_o[i*5 +: 5]              = hive_rsp[i].acc_resp.id;
    assign acc_pdata_o[i*DataWidth +: DataWidth] = hive_rsp[i].acc_resp.data;
    assign acc_perror_o[i]                  = hive_rsp[i].acc_resp.error;

    for (genvar j = 0; j < 2; j++) begin : g_tlb
      localparam int unsigned Ch = 2 * i + j;
      tlb_cmd_t cmd_in, cmd_d2;
      tlb_rsp_t rsp_d2, rsp_out;
      logic cmd_vld_d2, cmd_rdy_d2;
      logic rsp_vld_d2, rsp_rdy_d2;
      logic l0_valid, l0_ready, l0_flush, l0_fault;
      pa_t  l0_pa;

      assign cmd_in.flush    = tlb_req_flush_i[Ch];
      assign cmd_in.va       = snitch_pkg::va_t'(tlb_req_va_i[Ch*20 +: 20]);
      assign cmd_in.ppn      = pa_t'(tlb_req_ppn_i[Ch*PPNWidth +: PPNWidth]);
      assign cmd_in.priv     = snitch_pkg::priv_lvl_t'(tlb_req_priv_i[Ch*2 +: 2]);
      assign cmd_in.is_read  = tlb_req_read_i[Ch];
      assign cmd_in.is_write = tlb_req_write_i[Ch];
      assign cmd_in.is_exec  = tlb_req_exec_i[Ch];

      isochronous_spill_register #(
        .T      ( tlb_cmd_t ),
        .Bypass ( 1'b0      )
      ) u_cmd_iso (
        .src_clk_i   ( clk_i                ),
        .src_rst_ni  ( rst_ni               ),
        .src_valid_i ( tlb_req_valid_i[Ch]  ),
        .src_ready_o ( tlb_req_ready_o[Ch]  ),
        .src_data_i  ( cmd_in               ),
        .dst_clk_i   ( clk_d2               ),
        .dst_rst_ni  ( rst_ni               ),
        .dst_valid_o ( cmd_vld_d2           ),
        .dst_ready_i ( cmd_rdy_d2           ),
        .dst_data_o  ( cmd_d2               )
      );

      assign l0_flush = cmd_vld_d2 && rsp_rdy_d2 && cmd_d2.flush;
      assign l0_valid = cmd_vld_d2 && rsp_rdy_d2 && !cmd_d2.flush;

      snitch_l0_tlb #(
        .NrEntries ( NrTlbEntries ),
        .pa_t      ( pa_t         ),
        .l0_pte_t  ( l0_pte_t     )
      ) u_l0_tlb (
        .clk_i        ( clk_d2                     ),
        .rst_i        ( ~rst_ni                    ),
        .flush_i      ( l0_flush                   ),
        .priv_lvl_i   ( cmd_d2.priv                ),
        .valid_i      ( l0_valid                   ),
        .ready_o      ( l0_ready                   ),
        .va_i         ( cmd_d2.va                  ),
        .read_i       ( cmd_d2.is_read             ),
        .write_i      ( cmd_d2.is_write            ),
        .execute_i    ( cmd_d2.is_exec             ),
        .page_fault_o ( l0_fault                   ),
        .pa_o         ( l0_pa                      ),
        .valid_o      ( hive_req[i].ptw_valid[j]   ),
        .ready_i      ( hive_rsp[i].ptw_ready[j]   ),
        .va_o         ( hive_req[i].ptw_va[j]      ),
        .pte_i        ( hive_rsp[i].ptw_pte[j]     ),
        .is_4mega_i   ( hive_rsp[i].ptw_is_4mega[j])
      );

      assign hive_req[i].ptw_ppn[j] = cmd_d2.ppn;

      assign cmd_rdy_d2   = cmd_vld_d2 && rsp_rdy_d2 && (cmd_d2.flush || l0_ready);
      assign rsp_vld_d2   = cmd_rdy_d2;
      assign rsp_d2.pa    = cmd_d2.flush ? '0 : l0_pa;
      assign rsp_d2.fault = cmd_d2.flush ? 1'b0 : l0_fault;

      isochronous_spill_register #(
        .T      ( tlb_rsp_t ),
        .Bypass ( 1'b0      )
      ) u_rsp_iso (
        .src_clk_i   ( clk_d2               ),
        .src_rst_ni  ( rst_ni               ),
        .src_valid_i ( rsp_vld_d2           ),
        .src_ready_o ( rsp_rdy_d2           ),
        .src_data_i  ( rsp_d2               ),
        .dst_clk_i   ( clk_i                ),
        .dst_rst_ni  ( rst_ni               ),
        .dst_valid_o ( tlb_rsp_valid_o[Ch]  ),
        .dst_ready_i ( tlb_rsp_ready_i[Ch]  ),
        .dst_data_o  ( rsp_out              )
      );

      assign tlb_rsp_pa_o[Ch*PPNWidth +: PPNWidth] = rsp_out.pa;
      assign tlb_rsp_fault_o[Ch]                   = rsp_out.fault;
    end
  end

  snitch_iso_hive #(
    .CoreCount       ( CoreCount  ),
    .IsoCrossing     ( 1'b1       ),
    .AddrWidth       ( AddrWidth  ),
    .NarrowDataWidth ( DataWidth  ),
    .VMSupport       ( 1'b1       ),
    .dreq_t          ( ptw_mem_req_t ),
    .drsp_t          ( ptw_mem_rsp_t ),
    .hive_req_t      ( hive_req_t ),
    .hive_rsp_t      ( hive_rsp_t )
  ) u_hive (
    .clk_i           ( clk_i           ),
    .rst_ni          ( rst_ni          ),
    .test_mode_i     ( test_mode_i     ),
    .clk_d2_bypass_i ( clk_d2_bypass_i ),
    .clk_d2_o        ( clk_d2          ),
    .hive_req_i      ( hive_req        ),
    .hive_rsp_o      ( hive_rsp        ),
    .ptw_data_req_o  ( ptw_dreq        ),
    .ptw_data_rsp_i  ( ptw_drsp        )
  );

endmodule
