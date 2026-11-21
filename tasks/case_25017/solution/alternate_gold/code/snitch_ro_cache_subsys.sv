// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Synthesis & PnR top-level wrapper for Snitch Wide-Bus AXI4 Read-Only Cache Subsystem.

module snitch_ro_cache_subsys #(
  parameter int unsigned LineWidth    = 256,
  parameter int unsigned LineCount    = 256,
  parameter int unsigned SetCount     = 2,
  parameter int unsigned AxiAddrWidth = 32,
  parameter int unsigned AxiDataWidth = 64,
  parameter int unsigned AxiIdWidth   = 3,
  parameter int unsigned AxiUserWidth = 2,
  parameter int unsigned MaxTrans     = 4,
  parameter int unsigned NrAddrRules  = 2
) (
  input  logic                                     clk_i,
  input  logic                                     rst_ni,
  input  logic                                     enable_i,
  input  logic                                     flush_valid_i,
  output logic                                     flush_ready_o,
  input  logic [NrAddrRules-1:0][AxiAddrWidth-1:0] start_addr_i,
  input  logic [NrAddrRules-1:0][AxiAddrWidth-1:0] end_addr_i,

  // AXI4 Slave Port
  input  logic [AxiIdWidth-1:0]                    slv_aw_id_i,
  input  logic [AxiAddrWidth-1:0]                  slv_aw_addr_i,
  input  logic [7:0]                               slv_aw_len_i,
  input  logic [2:0]                               slv_aw_size_i,
  input  logic [1:0]                               slv_aw_burst_i,
  input  logic                                     slv_aw_lock_i,
  input  logic [3:0]                               slv_aw_cache_i,
  input  logic [2:0]                               slv_aw_prot_i,
  input  logic [3:0]                               slv_aw_qos_i,
  input  logic [3:0]                               slv_aw_region_i,
  input  logic [5:0]                               slv_aw_atop_i,
  input  logic [AxiUserWidth-1:0]                  slv_aw_user_i,
  input  logic                                     slv_aw_valid_i,
  output logic                                     slv_aw_ready_o,

  input  logic [AxiDataWidth-1:0]                  slv_w_data_i,
  input  logic [AxiDataWidth/8-1:0]                slv_w_strb_i,
  input  logic                                     slv_w_last_i,
  input  logic [AxiUserWidth-1:0]                  slv_w_user_i,
  input  logic                                     slv_w_valid_i,
  output logic                                     slv_w_ready_o,

  output logic [AxiIdWidth-1:0]                    slv_b_id_o,
  output logic [1:0]                               slv_b_resp_o,
  output logic [AxiUserWidth-1:0]                  slv_b_user_o,
  output logic                                     slv_b_valid_o,
  input  logic                                     slv_b_ready_i,

  input  logic [AxiIdWidth-1:0]                    slv_ar_id_i,
  input  logic [AxiAddrWidth-1:0]                  slv_ar_addr_i,
  input  logic [7:0]                               slv_ar_len_i,
  input  logic [2:0]                               slv_ar_size_i,
  input  logic [1:0]                               slv_ar_burst_i,
  input  logic                                     slv_ar_lock_i,
  input  logic [3:0]                               slv_ar_cache_i,
  input  logic [2:0]                               slv_ar_prot_i,
  input  logic [3:0]                               slv_ar_qos_i,
  input  logic [3:0]                               slv_ar_region_i,
  input  logic [AxiUserWidth-1:0]                  slv_ar_user_i,
  input  logic                                     slv_ar_valid_i,
  output logic                                     slv_ar_ready_o,

  output logic [AxiIdWidth-1:0]                    slv_r_id_o,
  output logic [AxiDataWidth-1:0]                  slv_r_data_o,
  output logic [1:0]                               slv_r_resp_o,
  output logic                                     slv_r_last_o,
  output logic [AxiUserWidth-1:0]                  slv_r_user_o,
  output logic                                     slv_r_valid_o,
  input  logic                                     slv_r_ready_i,

  // AXI4 Master Port
  output logic [AxiIdWidth:0]                      mst_aw_id_o,
  output logic [AxiAddrWidth-1:0]                  mst_aw_addr_o,
  output logic [7:0]                               mst_aw_len_o,
  output logic [2:0]                               mst_aw_size_o,
  output logic [1:0]                               mst_aw_burst_o,
  output logic                                     mst_aw_lock_o,
  output logic [3:0]                               mst_aw_cache_o,
  output logic [2:0]                               mst_aw_prot_o,
  output logic [3:0]                               mst_aw_qos_o,
  output logic [3:0]                               mst_aw_region_o,
  output logic [5:0]                               mst_aw_atop_o,
  output logic [AxiUserWidth-1:0]                  mst_aw_user_o,
  output logic                                     mst_aw_valid_o,
  input  logic                                     mst_aw_ready_i,

  output logic [AxiDataWidth-1:0]                  mst_w_data_o,
  output logic [AxiDataWidth/8-1:0]                mst_w_strb_o,
  output logic                                     mst_w_last_o,
  output logic [AxiUserWidth-1:0]                  mst_w_user_o,
  output logic                                     mst_w_valid_o,
  input  logic                                     mst_w_ready_i,

  input  logic [AxiIdWidth:0]                      mst_b_id_i,
  input  logic [1:0]                               mst_b_resp_i,
  input  logic [AxiUserWidth-1:0]                  mst_b_user_i,
  input  logic                                     mst_b_valid_i,
  output logic                                     mst_b_ready_o,

  output logic [AxiIdWidth:0]                      mst_ar_id_o,
  output logic [AxiAddrWidth-1:0]                  mst_ar_addr_o,
  output logic [7:0]                               mst_ar_len_o,
  output logic [2:0]                               mst_ar_size_o,
  output logic [1:0]                               mst_ar_burst_o,
  output logic                                     mst_ar_lock_o,
  output logic [3:0]                               mst_ar_cache_o,
  output logic [2:0]                               mst_ar_prot_o,
  output logic [3:0]                               mst_ar_qos_o,
  output logic [3:0]                               mst_ar_region_o,
  output logic [AxiUserWidth-1:0]                  mst_ar_user_o,
  output logic                                     mst_ar_valid_o,
  input  logic                                     mst_ar_ready_i,

  input  logic [AxiIdWidth:0]                      mst_r_id_i,
  input  logic [AxiDataWidth-1:0]                  mst_r_data_i,
  input  logic [1:0]                               mst_r_resp_i,
  input  logic                                     mst_r_last_i,
  input  logic [AxiUserWidth-1:0]                  mst_r_user_i,
  input  logic                                     mst_r_valid_i,
  output logic                                     mst_r_ready_o
);

  `include "axi/typedef.svh"

  typedef logic [AxiIdWidth-1:0]     slv_id_t;
  typedef logic [AxiIdWidth:0]       mst_id_t;
  typedef logic [AxiAddrWidth-1:0]   addr_t;
  typedef logic [AxiDataWidth-1:0]   data_t;
  typedef logic [AxiDataWidth/8-1:0] strb_t;
  typedef logic [AxiUserWidth-1:0]   user_t;

  `AXI_TYPEDEF_ALL(slv, addr_t, slv_id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(mst, addr_t, mst_id_t, data_t, strb_t, user_t)

  slv_req_t  slv_req;
  slv_resp_t slv_rsp;
  mst_req_t  mst_req;
  mst_resp_t mst_rsp;

  assign slv_req.aw = '{id: slv_aw_id_i, addr: slv_aw_addr_i, len: slv_aw_len_i, size: slv_aw_size_i,
                        burst: slv_aw_burst_i, lock: slv_aw_lock_i, cache: slv_aw_cache_i, prot: slv_aw_prot_i,
                        qos: slv_aw_qos_i, region: slv_aw_region_i, atop: slv_aw_atop_i, user: slv_aw_user_i};
  assign slv_req.aw_valid = slv_aw_valid_i;
  assign slv_aw_ready_o   = slv_rsp.aw_ready;

  assign slv_req.w = '{data: slv_w_data_i, strb: slv_w_strb_i, last: slv_w_last_i, user: slv_w_user_i};
  assign slv_req.w_valid = slv_w_valid_i;
  assign slv_w_ready_o   = slv_rsp.w_ready;

  assign slv_b_id_o      = slv_rsp.b.id;
  assign slv_b_resp_o    = slv_rsp.b.resp;
  assign slv_b_user_o    = slv_rsp.b.user;
  assign slv_b_valid_o   = slv_rsp.b_valid;
  assign slv_req.b_ready = slv_b_ready_i;

  assign slv_req.ar = '{id: slv_ar_id_i, addr: slv_ar_addr_i, len: slv_ar_len_i, size: slv_ar_size_i,
                        burst: slv_ar_burst_i, lock: slv_ar_lock_i, cache: slv_ar_cache_i, prot: slv_ar_prot_i,
                        qos: slv_ar_qos_i, region: slv_ar_region_i, user: slv_ar_user_i};
  assign slv_req.ar_valid = slv_ar_valid_i;
  assign slv_ar_ready_o   = slv_rsp.ar_ready;

  assign slv_r_id_o      = slv_rsp.r.id;
  assign slv_r_data_o    = slv_rsp.r.data;
  assign slv_r_resp_o    = slv_rsp.r.resp;
  assign slv_r_last_o    = slv_rsp.r.last;
  assign slv_r_user_o    = slv_rsp.r.user;
  assign slv_r_valid_o   = slv_rsp.r_valid;
  assign slv_req.r_ready = slv_r_ready_i;

  assign mst_aw_id_o     = mst_req.aw.id;
  assign mst_aw_addr_o   = mst_req.aw.addr;
  assign mst_aw_len_o    = mst_req.aw.len;
  assign mst_aw_size_o   = mst_req.aw.size;
  assign mst_aw_burst_o  = mst_req.aw.burst;
  assign mst_aw_lock_o   = mst_req.aw.lock;
  assign mst_aw_cache_o  = mst_req.aw.cache;
  assign mst_aw_prot_o   = mst_req.aw.prot;
  assign mst_aw_qos_o    = mst_req.aw.qos;
  assign mst_aw_region_o = mst_req.aw.region;
  assign mst_aw_atop_o   = mst_req.aw.atop;
  assign mst_aw_user_o   = mst_req.aw.user;
  assign mst_aw_valid_o  = mst_req.aw_valid;
  assign mst_rsp.aw_ready = mst_aw_ready_i;

  assign mst_w_data_o    = mst_req.w.data;
  assign mst_w_strb_o    = mst_req.w.strb;
  assign mst_w_last_o    = mst_req.w.last;
  assign mst_w_user_o    = mst_req.w.user;
  assign mst_w_valid_o   = mst_req.w_valid;
  assign mst_rsp.w_ready = mst_w_ready_i;

  assign mst_rsp.b = '{id: mst_b_id_i, resp: mst_b_resp_i, user: mst_b_user_i};
  assign mst_rsp.b_valid = mst_b_valid_i;
  assign mst_b_ready_o   = mst_req.b_ready;

  assign mst_ar_id_o     = mst_req.ar.id;
  assign mst_ar_addr_o   = mst_req.ar.addr;
  assign mst_ar_len_o    = mst_req.ar.len;
  assign mst_ar_size_o   = mst_req.ar.size;
  assign mst_ar_burst_o  = mst_req.ar.burst;
  assign mst_ar_lock_o   = mst_req.ar.lock;
  assign mst_ar_cache_o  = mst_req.ar.cache;
  assign mst_ar_prot_o   = mst_req.ar.prot;
  assign mst_ar_qos_o    = mst_req.ar.qos;
  assign mst_ar_region_o = mst_req.ar.region;
  assign mst_ar_user_o   = mst_req.ar.user;
  assign mst_ar_valid_o  = mst_req.ar_valid;
  assign mst_rsp.ar_ready = mst_ar_ready_i;

  assign mst_rsp.r = '{id: mst_r_id_i, data: mst_r_data_i, resp: mst_r_resp_i, last: mst_r_last_i, user: mst_r_user_i};
  assign mst_rsp.r_valid = mst_r_valid_i;
  assign mst_r_ready_o   = mst_req.r_ready;

  snitch_read_only_cache #(
    .LineWidth       ( LineWidth    ),
    .LineCount       ( LineCount    ),
    .SetCount        ( SetCount     ),
    .AxiAddrWidth    ( AxiAddrWidth ),
    .AxiDataWidth    ( AxiDataWidth ),
    .AxiIdWidth      ( AxiIdWidth   ),
    .AxiUserWidth    ( AxiUserWidth ),
    .MaxTrans        ( MaxTrans     ),
    .NrAddrRules     ( NrAddrRules  ),
    .slv_req_t       ( slv_req_t    ),
    .slv_rsp_t       ( slv_resp_t   ),
    .mst_req_t       ( mst_req_t    ),
    .mst_rsp_t       ( mst_resp_t   ),
    .sram_cfg_data_t ( logic        ),
    .sram_cfg_tag_t  ( logic        )
  ) u_ro_cache (
    .clk_i,
    .rst_ni,
    .enable_i,
    .flush_valid_i,
    .flush_ready_o,
    .start_addr_i,
    .end_addr_i,
    .axi_slv_req_i   ( slv_req ),
    .axi_slv_rsp_o   ( slv_rsp ),
    .axi_mst_req_o   ( mst_req ),
    .axi_mst_rsp_i   ( mst_rsp ),
    .sram_cfg_data_i ( 1'b0    ),
    .sram_cfg_tag_i  ( 1'b0    )
  );

endmodule
