// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Synthesis & STA top-level wrapper for Ara's lane integer VMFPU subsystem
// (NrLanes = 4, VLEN = 4096, FPUSupport = FPUSupportNone, FixPtSupport = FixedPointEnable).

package vmfpu_synth_pkg;
  import ara_pkg::*;
  import rvv_pkg::*;

  localparam int unsigned NrLanes         = 4;
  localparam int unsigned VLEN            = 4096;
  localparam int unsigned VLENB           = VLEN / 8;
  localparam int unsigned MaxVLenBPerLane = VLENB / NrLanes;
  localparam int unsigned VRFBSizePerLane = MaxVLenBPerLane * 32;

  typedef logic [$clog2(VRFBSizePerLane)-1:0] vaddr_t;
  typedef logic [$clog2(VLEN+1)-1:0]          vlen_t;

  typedef struct packed {
    vid_t                  id;
    ara_op_e               op;
    logic                  vm;
    logic                  use_vs1;
    logic                  use_vs2;
    logic                  use_vd_op;
    elen_t                 scalar_op;
    logic                  use_scalar_op;
    vfu_e                  vfu;
    logic [4:0]            vd;
    logic                  use_vd;
    logic                  swap_vs2_vd_op;
    fpnew_pkg::roundmode_e fp_rm;
    logic                  wide_fp_imm;
    resize_e               cvt_resize;
    vlen_t                 vl;
    vlen_t                 vstart;
    rvv_pkg::vtype_t       vtype;
  } vfu_operation_t;
endpackage : vmfpu_synth_pkg

module vmfpu_synth_top
  import ara_pkg::*;
  import rvv_pkg::*;
  import vmfpu_synth_pkg::*;
(
  input  logic                                       clk_i,
  input  logic                                       rst_ni,
  input  logic [cf_math_pkg::idx_width(NrLanes)-1:0] lane_id_i,
  output logic                                       mfpu_vxsat_o,
  input  vxrm_t                                      mfpu_vxrm_i,
  output logic [4:0]                                 fflags_ex_o,
  output logic                                       fflags_ex_valid_o,
  input  vfu_operation_t                             vfu_operation_i,
  input  logic                                       vfu_operation_valid_i,
  output logic                                       mfpu_ready_o,
  output logic [NrVInsn-1:0]                         mfpu_vinsn_done_o,
  output logic                                       fpu_red_complete_o,
  input  elen_t [2:0]                                mfpu_operand_i,
  input  logic  [2:0]                                mfpu_operand_valid_i,
  output logic  [2:0]                                mfpu_operand_ready_o,
  output logic                                       mfpu_result_req_o,
  output vid_t                                       mfpu_result_id_o,
  output vaddr_t                                     mfpu_result_addr_o,
  output elen_t                                      mfpu_result_wdata_o,
  output logic [7:0]                                 mfpu_result_be_o,
  input  logic                                       mfpu_result_gnt_i,
  output logic                                       mfpu_red_valid_o,
  input  logic                                       mfpu_red_ready_i,
  input  elen_t                                      sldu_operand_i,
  input  logic                                       sldu_mfpu_valid_i,
  output logic                                       sldu_mfpu_ready_o,
  output elen_t                                      mask_operand_o,
  output logic                                       mask_operand_valid_o,
  input  logic                                       mask_operand_ready_i,
  input  logic [7:0]                                 mask_i,
  input  logic                                       mask_valid_i,
  output logic                                       mask_ready_o
);

  vmfpu #(
    .NrLanes        (NrLanes            ),
    .VLEN           (VLEN               ),
    .FPUSupport     (FPUSupportNone     ),
    .FPExtSupport   (FPExtSupportDisable),
    .FixPtSupport   (FixedPointEnable   ),
    .vaddr_t        (vaddr_t            ),
    .vfu_operation_t(vfu_operation_t    )
  ) i_vmfpu (
    .clk_i                (clk_i                ),
    .rst_ni               (rst_ni               ),
    .lane_id_i            (lane_id_i            ),
    .mfpu_vxsat_o         (mfpu_vxsat_o         ),
    .mfpu_vxrm_i          (mfpu_vxrm_i          ),
    .fflags_ex_o          (fflags_ex_o          ),
    .fflags_ex_valid_o    (fflags_ex_valid_o    ),
    .vfu_operation_i      (vfu_operation_i      ),
    .vfu_operation_valid_i(vfu_operation_valid_i),
    .mfpu_ready_o         (mfpu_ready_o         ),
    .mfpu_vinsn_done_o    (mfpu_vinsn_done_o    ),
    .fpu_red_complete_o   (fpu_red_complete_o   ),
    .mfpu_operand_i       (mfpu_operand_i       ),
    .mfpu_operand_valid_i (mfpu_operand_valid_i ),
    .mfpu_operand_ready_o (mfpu_operand_ready_o ),
    .mfpu_result_req_o    (mfpu_result_req_o    ),
    .mfpu_result_id_o     (mfpu_result_id_o     ),
    .mfpu_result_addr_o   (mfpu_result_addr_o   ),
    .mfpu_result_wdata_o  (mfpu_result_wdata_o  ),
    .mfpu_result_be_o     (mfpu_result_be_o     ),
    .mfpu_result_gnt_i    (mfpu_result_gnt_i    ),
    .mfpu_red_valid_o     (mfpu_red_valid_o     ),
    .mfpu_red_ready_i     (mfpu_red_ready_i     ),
    .sldu_operand_i       (sldu_operand_i       ),
    .sldu_mfpu_valid_i    (sldu_mfpu_valid_i    ),
    .sldu_mfpu_ready_o    (sldu_mfpu_ready_o    ),
    .mask_operand_o       (mask_operand_o       ),
    .mask_operand_valid_o (mask_operand_valid_o ),
    .mask_operand_ready_i (mask_operand_ready_i ),
    .mask_i               (mask_i               ),
    .mask_valid_i         (mask_valid_i         ),
    .mask_ready_o         (mask_ready_o         )
  );

endmodule : vmfpu_synth_top
