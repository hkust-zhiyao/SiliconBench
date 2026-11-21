// Copyright 2021-2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Synthesis and verification wrapper for Ara's Slide and Inter-Lane Reduction Unit
// (`sldu` + `p2_stride_gen` + `sldu_op_dp`).

module sldu_subsys_top import ara_pkg::*; import rvv_pkg::*; #(
  parameter int unsigned NrLanes = 4,
  parameter int unsigned VLEN    = 1024,
  localparam int unsigned VRFSizePerLane = VLEN * 32 / NrLanes,
  localparam type vaddr_t = logic [$clog2(VRFSizePerLane / 64)-1:0],
  localparam type strb_t  = logic [7:0],
  localparam type vlen_t  = logic [$clog2(VLEN+1)-1:0]
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  vid_t                   req_id_i,
  input  ara_op_e                req_op_i,
  input  logic                   req_vm_i,
  input  vew_e                   req_eew_vs2_i,
  input  logic                   req_use_vs2_i,
  input  elen_t                  req_scalar_op_i,
  input  logic                   req_use_scalar_op_i,
  input  elen_t                  req_stride_i,
  input  logic                   req_is_stride_np2_i,
  input  vfu_e                   req_vfu_i,
  input  logic [4:0]             req_vd_i,
  input  logic                   req_use_vd_i,
  input  vlen_t                  req_vl_i,
  input  vtype_t                 req_vtype_i,
  input  logic                   pe_req_valid_i,
  input  logic [NrVInsn-1:0]     pe_vinsn_running_i,
  output logic                   pe_req_ready_o,
  output logic [NrVInsn-1:0]     pe_vinsn_done_o,
  input  elen_t [NrLanes-1:0]    sldu_operand_i,
  input  logic  [NrLanes-1:0]    sldu_operand_valid_i,
  output logic  [NrLanes-1:0]    sldu_operand_ready_o,
  output logic  [NrLanes-1:0]    sldu_result_req_o,
  output vid_t  [NrLanes-1:0]    sldu_result_id_o,
  output vaddr_t[NrLanes-1:0]    sldu_result_addr_o,
  output elen_t [NrLanes-1:0]    sldu_result_wdata_o,
  output strb_t [NrLanes-1:0]    sldu_result_be_o,
  input  logic  [NrLanes-1:0]    sldu_result_gnt_i,
  input  logic  [NrLanes-1:0]    sldu_result_final_gnt_i,
  output sldu_mux_e              sldu_mux_sel_o,
  output logic  [NrLanes-1:0]    sldu_red_valid_o,
  input  strb_t [NrLanes-1:0]    mask_i,
  input  logic  [NrLanes-1:0]    mask_valid_i,
  output logic                   mask_ready_o
);
  typedef struct packed {
    vid_t            id;
    ara_op_e         op;
    logic            vm;
    rvv_pkg::vew_e   eew_vs2;
    logic            use_vs2;
    elen_t           scalar_op;
    logic            use_scalar_op;
    elen_t           stride;
    logic            is_stride_np2;
    vfu_e            vfu;
    logic [4:0]      vd;
    logic            use_vd;
    vlen_t           vl;
    rvv_pkg::vtype_t vtype;
  } pe_req_t;

  typedef struct packed {
    logic [NrVInsn-1:0] vinsn_done;
  } pe_resp_t;

  pe_req_t  pe_req;
  pe_resp_t pe_resp;

  assign pe_req = '{
    id: req_id_i, op: req_op_i, vm: req_vm_i, eew_vs2: req_eew_vs2_i,
    use_vs2: req_use_vs2_i, scalar_op: req_scalar_op_i, use_scalar_op: req_use_scalar_op_i,
    stride: req_stride_i, is_stride_np2: req_is_stride_np2_i, vfu: req_vfu_i,
    vd: req_vd_i, use_vd: req_use_vd_i, vl: req_vl_i, vtype: req_vtype_i
  };
  assign pe_vinsn_done_o = pe_resp.vinsn_done;

  sldu #(
    .NrLanes(NrLanes), .VLEN(VLEN), .vaddr_t(vaddr_t), .pe_req_t(pe_req_t), .pe_resp_t(pe_resp_t)
  ) i_sldu (
    .clk_i, .rst_ni,
    .pe_req_i(pe_req), .pe_req_valid_i, .pe_vinsn_running_i, .pe_req_ready_o, .pe_resp_o(pe_resp),
    .sldu_operand_i, .sldu_operand_valid_i, .sldu_operand_ready_o,
    .sldu_result_req_o, .sldu_result_id_o, .sldu_result_addr_o, .sldu_result_wdata_o, .sldu_result_be_o,
    .sldu_result_gnt_i, .sldu_result_final_gnt_i,
    .sldu_mux_sel_o, .sldu_red_valid_o,
    .mask_i, .mask_valid_i, .mask_ready_o
  );
endmodule
