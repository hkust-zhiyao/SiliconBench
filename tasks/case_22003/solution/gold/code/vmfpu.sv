// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
//          Matteo Perotti <mperotti@iis.ee.ethz.ch>
// Description:
// Ara's integer multiplier and division functional unit (configured with
// phase-decoupled instruction descriptors, incremental VRF write addressing,
// per-EW clock-gated multiplier pipelines, and masked fast-skip division).

module vmfpu import ara_pkg::*; import rvv_pkg::*; import fpnew_pkg::*;
  import cf_math_pkg::idx_width; #(
    parameter  int           unsigned NrLanes         = 0,
    parameter  int           unsigned VLEN            = 0,
    parameter  config_pkg::cva6_cfg_t CVA6Cfg         = cva6_config_pkg::cva6_cfg,
    // Support for floating-point data types
    parameter  fpu_support_e          FPUSupport      = FPUSupportHalfSingleDouble,
    // External support for vfrec7, vfrsqrt7, rounding-toward-odd
    parameter  fpext_support_e        FPExtSupport    = FPExtSupportEnable,
    // Support for fixed-point data types
    parameter  fixpt_support_e        FixPtSupport    = FixedPointEnable,
    // Type used to address vector register file elements
    parameter  type                   vaddr_t         = logic,
    parameter  type                   vfu_operation_t = logic,
    // Dependant parameters. DO NOT CHANGE!
    localparam int           unsigned DataWidth    = $bits(elen_t),
    localparam int           unsigned StrbWidth    = DataWidth/8,
    localparam type                   strb_t       = logic [DataWidth/8-1:0],
    localparam type                   vlen_t       = logic[$clog2(VLEN+1)-1:0]
  ) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic[idx_width(NrLanes)-1:0] lane_id_i,
    // Interface with Dispatcher
    output logic                         mfpu_vxsat_o,
    input  vxrm_t                        mfpu_vxrm_i,
    // Interface with CVA6
    output logic           [4:0]         fflags_ex_o,
    output logic                         fflags_ex_valid_o,
    // Interface with the lane sequencer
    input  vfu_operation_t               vfu_operation_i,
    input  logic                         vfu_operation_valid_i,
    output logic                         mfpu_ready_o,
    output logic           [NrVInsn-1:0] mfpu_vinsn_done_o,
    // Interface with the lane
    output logic                         fpu_red_complete_o,
    // Interface with the operand queues
    input  elen_t          [2:0]         mfpu_operand_i,
    input  logic           [2:0]         mfpu_operand_valid_i,
    output logic           [2:0]         mfpu_operand_ready_o,
    // Interface with the vector register file
    output logic                         mfpu_result_req_o,
    output vid_t                         mfpu_result_id_o,
    output vaddr_t                       mfpu_result_addr_o,
    output elen_t                        mfpu_result_wdata_o,
    output strb_t                        mfpu_result_be_o,
    input  logic                         mfpu_result_gnt_i,
    // Interface with the Slide Unit
    output logic                         mfpu_red_valid_o,
    input  logic                         mfpu_red_ready_i,
    input  elen_t                        sldu_operand_i,
    input  logic                         sldu_mfpu_valid_i,
    output logic                         sldu_mfpu_ready_o,
    // Interface with the Mask unit
    output elen_t                        mask_operand_o,
    output logic                         mask_operand_valid_o,
    input  logic                         mask_operand_ready_i,
    input  strb_t                        mask_i,
    input  logic                         mask_valid_i,
    output logic                         mask_ready_o
  );

  `include "common_cells/registers.svh"

  // Tie off unused floating-point / reduction / mask-comparison ports when FPUSupport == FPUSupportNone
  if (FPUSupport == FPUSupportNone) begin : gen_no_fpu_ties
    wire unused_fpu_inputs = ^{lane_id_i, mfpu_red_ready_i, sldu_operand_i, sldu_mfpu_valid_i, mask_operand_ready_i};
    assign fflags_ex_o          = '0;
    assign fflags_ex_valid_o    = 1'b0;
    assign fpu_red_complete_o   = 1'b0;
    assign mfpu_red_valid_o     = 1'b0;
    assign sldu_mfpu_ready_o    = 1'b0;
    assign mask_operand_o       = '0;
    assign mask_operand_valid_o = 1'b0;
  end

  ///////////////////////////////////////////////////
  //  Phase-Decoupled Vector Instruction Descriptors
  ///////////////////////////////////////////////////

  localparam int unsigned VInsnQueueDepth = MfpuInsnQueueDepth;
  localparam int unsigned PntWidth        = idx_width(VInsnQueueDepth);
  localparam int unsigned CntWidth        = idx_width(VInsnQueueDepth) + 1;

  // Issue-only metadata (never muxed into processing or commit stages)
  typedef struct packed {
    elen_t      scalar_rep;
    logic       use_scalar_op;
    logic [2:0] req_op_mask;
    ara_op_e    op;
  } issue_meta_t;

  // Compact control metadata shared across issue / processing / commit phases
  typedef struct packed {
    vid_t   id;
    vew_e   vsew;
    logic   vm;
    logic   is_div;
    logic   is_vsmul;
    vaddr_t base_vaddr;
    vlen_t  vl;
  } ctrl_meta_t;

  issue_meta_t [VInsnQueueDepth-1:0] issue_tbl_d, issue_tbl_q;
  ctrl_meta_t  [VInsnQueueDepth-1:0] ctrl_tbl_d,  ctrl_tbl_q;

  logic [PntWidth-1:0] accept_pnt_d, accept_pnt_q;
  logic [PntWidth-1:0] issue_pnt_d,  issue_pnt_q;
  logic [PntWidth-1:0] proc_pnt_d,   proc_pnt_q;
  logic [PntWidth-1:0] commit_pnt_d, commit_pnt_q;

  logic [CntWidth-1:0] issue_insns_d,  issue_insns_q;
  logic [CntWidth-1:0] proc_insns_d,   proc_insns_q;
  logic [CntWidth-1:0] commit_insns_d, commit_insns_q;

  logic vinsn_queue_full;
  assign vinsn_queue_full = (commit_insns_q == CntWidth'(VInsnQueueDepth));

  // Direct registered-pointer lookups (no next-pointer combinational cascade)
  issue_meta_t issue_meta;
  ctrl_meta_t  issue_ctrl, proc_ctrl, commit_ctrl;
  logic        issue_active, proc_active, commit_active;

  assign issue_meta    = issue_tbl_q[issue_pnt_q];
  assign issue_ctrl    = ctrl_tbl_q[issue_pnt_q];
  assign proc_ctrl     = ctrl_tbl_q[proc_pnt_q];
  assign commit_ctrl   = ctrl_tbl_q[commit_pnt_q];

  assign issue_active  = (issue_insns_q  != '0);
  assign proc_active   = (proc_insns_q   != '0);
  assign commit_active = (commit_insns_q != '0);

  // Replicate scalar operand once on accept according to SEW
  function automatic elen_t replicate_scalar(input elen_t raw_scalar, input vew_e sew);
    unique case (sew)
      EW64   : replicate_scalar = raw_scalar;
      EW32   : replicate_scalar = {2{raw_scalar[31:0]}};
      EW16   : replicate_scalar = {4{raw_scalar[15:0]}};
      default: replicate_scalar = {8{raw_scalar[ 7:0]}};
    endcase
  endfunction

  // Effective pipeline depth per integer multiplier SEW for in-order hazard tracking
  function automatic logic [2:0] mul_pipe_lat(input vew_e sew);
    unique case (sew)
      EW64   : mul_pipe_lat = 3'd4; // 3 internal stages + 1 output timing register
      EW32   : mul_pipe_lat = 3'd2;
      EW16   : mul_pipe_lat = 3'd1;
      default: mul_pipe_lat = 3'd1; // 1 input register + combinational EW8 array
    endcase
  endfunction

  ////////////////////
  //  Result Queue  //
  ////////////////////

  localparam int unsigned ResultQueueDepth = 2;

  typedef struct packed {
    vid_t   id;
    vaddr_t addr;
    elen_t  wdata;
    strb_t  be;
    logic   sat;
  } payload_t;

  payload_t [ResultQueueDepth-1:0]            result_queue_d, result_queue_q;
  logic     [ResultQueueDepth-1:0]            result_queue_valid_d, result_queue_valid_q;
  logic     [idx_width(ResultQueueDepth)-1:0] result_queue_write_pnt_d, result_queue_write_pnt_q;
  logic     [idx_width(ResultQueueDepth)-1:0] result_queue_read_pnt_d, result_queue_read_pnt_q;
  logic     [idx_width(ResultQueueDepth):0]   result_queue_cnt_d, result_queue_cnt_q;

  logic result_queue_full;
  assign result_queue_full = (result_queue_cnt_q == ResultQueueDepth);

  /////////////////////////////////////////////////////
  //  Per-EW Clock-Gated SIMD Multiplier Subsystem   //
  /////////////////////////////////////////////////////

  logic [3:0] clkgate_ew_d, clkgate_ew_q;
  logic [3:0] clk_ew;

  for (genvar e = 0; e < 4; e++) begin : gen_ew_clkgate
    tc_clk_gating i_ew_clk_gate (
      .clk_i    (clk_i          ),
      .en_i     (clkgate_ew_q[e]),
      .test_en_i(1'b0           ),
      .clk_o    (clk_ew[e]      )
    );
  end

  elen_t  mul_op_a, mul_op_b, mul_op_c;
  assign mul_op_a = issue_meta.use_scalar_op ? issue_meta.scalar_rep : mfpu_operand_i[0];
  assign mul_op_b = mfpu_operand_i[1];
  assign mul_op_c = mfpu_operand_i[2];

  logic   [3:0] vmul_simd_in_valid;
  logic   [3:0] vmul_simd_in_ready;
  logic   [3:0] vmul_simd_out_valid;
  logic   [3:0] vmul_simd_out_ready;
  elen_t  [3:0] vmul_simd_result;
  strb_t  [3:0] vmul_simd_mask;
  vxsat_t [3:0] vmul_simd_vxsat;

  // EW8: 1-stage input register (since LatMultiplierEW8 == 0) clocked by clk_ew[EW8]
  elen_t   ew8_opa_q, ew8_opb_q, ew8_opc_q;
  strb_t   ew8_mask_q;
  ara_op_e ew8_op_q;
  logic    ew8_valid_q;
  logic    ew8_reg_ready;

  assign ew8_reg_ready           = ~ew8_valid_q | vmul_simd_out_ready[EW8];
  assign vmul_simd_in_ready[EW8] = ew8_reg_ready;

  always_ff @(posedge clk_ew[EW8] or negedge rst_ni) begin
    if (!rst_ni) begin
      ew8_valid_q <= 1'b0;
      ew8_opa_q   <= '0;
      ew8_opb_q   <= '0;
      ew8_opc_q   <= '0;
      ew8_mask_q  <= '0;
      ew8_op_q    <= ara_op_e'('0);
    end else if (ew8_reg_ready) begin
      ew8_valid_q <= vmul_simd_in_valid[EW8];
      if (vmul_simd_in_valid[EW8]) begin
        ew8_opa_q  <= mul_op_a;
        ew8_opb_q  <= mul_op_b;
        ew8_opc_q  <= mul_op_c;
        ew8_mask_q <= mask_i;
        ew8_op_q   <= issue_meta.op;
      end
    end
  end

  simd_mul #(
    .FixPtSupport(FixPtSupport    ),
    .NumPipeRegs (LatMultiplierEW8),
    .ElementWidth(EW8             )
  ) i_simd_mul_ew8 (
    .clk_i      (clk_ew[EW8]              ),
    .rst_ni     (rst_ni                   ),
    .operand_a_i(ew8_opa_q                ),
    .operand_b_i(ew8_opb_q                ),
    .operand_c_i(ew8_opc_q                ),
    .mask_i     (ew8_mask_q               ),
    .op_i       (ew8_op_q                 ),
    .result_o   (vmul_simd_result[EW8]    ),
    .mask_o     (vmul_simd_mask[EW8]      ),
    .vxsat_o    (vmul_simd_vxsat[EW8]     ),
    .vxrm_i     (mfpu_vxrm_i              ),
    .valid_i    (ew8_valid_q              ),
    .ready_o    (/* unused: NumPipeRegs=0 */),
    .ready_i    (vmul_simd_out_ready[EW8] ),
    .valid_o    (vmul_simd_out_valid[EW8] )
  );

  // EW16: internal 1-stage pipeline clocked by clk_ew[EW16]
  simd_mul #(
    .FixPtSupport(FixPtSupport     ),
    .NumPipeRegs (LatMultiplierEW16),
    .ElementWidth(EW16             )
  ) i_simd_mul_ew16 (
    .clk_i      (clk_ew[EW16]              ),
    .rst_ni     (rst_ni                    ),
    .operand_a_i(mul_op_a                  ),
    .operand_b_i(mul_op_b                  ),
    .operand_c_i(mul_op_c                  ),
    .mask_i     (mask_i                    ),
    .op_i       (issue_meta.op             ),
    .result_o   (vmul_simd_result[EW16]    ),
    .mask_o     (vmul_simd_mask[EW16]      ),
    .vxsat_o    (vmul_simd_vxsat[EW16]     ),
    .vxrm_i     (mfpu_vxrm_i               ),
    .valid_i    (vmul_simd_in_valid[EW16]  ),
    .ready_o    (vmul_simd_in_ready[EW16]  ),
    .ready_i    (vmul_simd_out_ready[EW16] ),
    .valid_o    (vmul_simd_out_valid[EW16] )
  );

  // EW32: internal 2-stage pipeline clocked by clk_ew[EW32]
  simd_mul #(
    .FixPtSupport(FixPtSupport     ),
    .NumPipeRegs (LatMultiplierEW32),
    .ElementWidth(EW32             )
  ) i_simd_mul_ew32 (
    .clk_i      (clk_ew[EW32]              ),
    .rst_ni     (rst_ni                    ),
    .operand_a_i(mul_op_a                  ),
    .operand_b_i(mul_op_b                  ),
    .operand_c_i(mul_op_c                  ),
    .mask_i     (mask_i                    ),
    .op_i       (issue_meta.op             ),
    .result_o   (vmul_simd_result[EW32]    ),
    .mask_o     (vmul_simd_mask[EW32]      ),
    .vxsat_o    (vmul_simd_vxsat[EW32]     ),
    .vxrm_i     (mfpu_vxrm_i               ),
    .valid_i    (vmul_simd_in_valid[EW32]  ),
    .ready_o    (vmul_simd_in_ready[EW32]  ),
    .ready_i    (vmul_simd_out_ready[EW32] ),
    .valid_o    (vmul_simd_out_valid[EW32] )
  );

  // EW64: internal 3-stage pipeline + 1-stage output register isolating the 64x64 MAC array from result_queue muxes
  elen_t  ew64_raw_res, ew64_res_q;
  strb_t  ew64_raw_mask, ew64_mask_q;
  vxsat_t ew64_raw_vxsat, ew64_vxsat_q;
  logic   ew64_raw_valid, ew64_raw_ready, ew64_valid_q;

  assign ew64_raw_ready = ~ew64_valid_q | vmul_simd_out_ready[EW64];

  simd_mul #(
    .FixPtSupport(FixPtSupport     ),
    .NumPipeRegs (LatMultiplierEW64),
    .ElementWidth(EW64             )
  ) i_simd_mul_ew64 (
    .clk_i      (clk_ew[EW64]             ),
    .rst_ni     (rst_ni                   ),
    .operand_a_i(mul_op_a                 ),
    .operand_b_i(mul_op_b                 ),
    .operand_c_i(mul_op_c                 ),
    .mask_i     (mask_i                   ),
    .op_i       (issue_meta.op            ),
    .result_o   (ew64_raw_res             ),
    .mask_o     (ew64_raw_mask            ),
    .vxsat_o    (ew64_raw_vxsat           ),
    .vxrm_i     (mfpu_vxrm_i              ),
    .valid_i    (vmul_simd_in_valid[EW64] ),
    .ready_o    (vmul_simd_in_ready[EW64] ),
    .ready_i    (ew64_raw_ready           ),
    .valid_o    (ew64_raw_valid           )
  );

  always_ff @(posedge clk_ew[EW64] or negedge rst_ni) begin
    if (!rst_ni) begin
      ew64_valid_q <= 1'b0;
      ew64_res_q   <= '0;
      ew64_mask_q  <= '0;
      ew64_vxsat_q <= '0;
    end else if (ew64_raw_ready) begin
      ew64_valid_q <= ew64_raw_valid;
      if (ew64_raw_valid) begin
        ew64_res_q   <= ew64_raw_res;
        ew64_mask_q  <= ew64_raw_mask;
        ew64_vxsat_q <= ew64_raw_vxsat;
      end
    end
  end

  assign vmul_simd_result[EW64]    = ew64_res_q;
  assign vmul_simd_mask[EW64]      = ew64_mask_q;
  assign vmul_simd_vxsat[EW64]     = ew64_vxsat_q;
  assign vmul_simd_out_valid[EW64] = ew64_valid_q;

  logic  vmul_in_valid, vmul_in_ready, vmul_out_valid, vmul_out_ready;
  elen_t vmul_result;
  strb_t vmul_mask;
  logic [7:0] vmul_vxsat_bits;

  always_comb begin : p_vmul_steer
    vmul_simd_in_valid  = '0;
    vmul_simd_out_ready = '0;

    vmul_simd_in_valid [issue_ctrl.vsew] = clkgate_ew_q[issue_ctrl.vsew] & vmul_in_valid;
    vmul_in_ready                        = clkgate_ew_q[issue_ctrl.vsew] & vmul_simd_in_ready[issue_ctrl.vsew];

    vmul_result                          = vmul_simd_result   [proc_ctrl.vsew];
    vmul_mask                            = vmul_simd_mask     [proc_ctrl.vsew];
    vmul_vxsat_bits                      = vmul_simd_vxsat    [proc_ctrl.vsew];
    vmul_out_valid                       = vmul_simd_out_valid[proc_ctrl.vsew];
    vmul_simd_out_ready[proc_ctrl.vsew]  = vmul_out_ready;
  end

  ///////////////
  //  Divider  //
  ///////////////

  elen_t vdiv_result;
  strb_t vdiv_mask;
  strb_t issue_be;
  logic  vdiv_in_valid, vdiv_in_ready, vdiv_out_valid, vdiv_out_ready;

  simd_div #(
    .CVA6Cfg(CVA6Cfg)
  ) i_simd_div (
    .clk_i      (clk_i                                                            ),
    .rst_ni     (rst_ni                                                           ),
    .operand_a_i(mfpu_operand_i[1]                                                ),
    .operand_b_i(issue_meta.use_scalar_op ? issue_meta.scalar_rep : mfpu_operand_i[0]),
    .mask_i     (mask_i                                                           ),
    .op_i       (issue_meta.op                                                    ),
    .be_i       (issue_be                                                         ),
    .vew_i      (issue_ctrl.vsew                                                  ),
    .result_o   (vdiv_result                                                      ),
    .mask_o     (vdiv_mask                                                        ),
    .valid_i    (vdiv_in_valid                                                    ),
    .ready_o    (vdiv_in_ready                                                    ),
    .ready_i    (vdiv_out_ready                                                   ),
    .valid_o    (vdiv_out_valid                                                   )
  );

  //////////////////////////////////////////
  //  Multi-Phase Control & Writeback     //
  //////////////////////////////////////////

  vlen_t  issue_cnt_d,      issue_cnt_q;
  vlen_t  to_process_cnt_d, to_process_cnt_q;
  vlen_t  commit_cnt_d,     commit_cnt_q;
  vaddr_t proc_vaddr_d,     proc_vaddr_q;

  logic operands_valid;
  logic latency_stall;
  logic unit_out_valid;
  elen_t unit_out_result;
  strb_t unit_out_mask;
  logic [3:0] issue_elem_cnt;
  logic [3:0] proc_elem_cnt;
  logic [3:0] commit_elem_cnt;
  strb_t      entry_be;
  vaddr_t     new_base_vaddr;

  always_comb begin : p_vmfpu
    issue_tbl_d    = issue_tbl_q;
    ctrl_tbl_d     = ctrl_tbl_q;
    accept_pnt_d   = accept_pnt_q;
    issue_pnt_d    = issue_pnt_q;
    proc_pnt_d     = proc_pnt_q;
    commit_pnt_d   = commit_pnt_q;
    issue_insns_d  = issue_insns_q;
    proc_insns_d   = proc_insns_q;
    commit_insns_d = commit_insns_q;

    issue_cnt_d      = issue_cnt_q;
    to_process_cnt_d = to_process_cnt_q;
    commit_cnt_d     = commit_cnt_q;
    proc_vaddr_d     = proc_vaddr_q;

    result_queue_d           = result_queue_q;
    result_queue_valid_d     = result_queue_valid_q;
    result_queue_read_pnt_d  = result_queue_read_pnt_q;
    result_queue_write_pnt_d = result_queue_write_pnt_q;
    result_queue_cnt_d       = result_queue_cnt_q;

    mfpu_ready_o         = !vinsn_queue_full;
    mfpu_vinsn_done_o    = '0;
    mfpu_operand_ready_o = '0;
    mask_ready_o         = 1'b0;

    vmul_in_valid  = 1'b0;
    vdiv_in_valid  = 1'b0;
    vmul_out_ready = ~result_queue_full & proc_active & ~proc_ctrl.is_div;
    vdiv_out_ready = ~result_queue_full & proc_active &  proc_ctrl.is_div;

    issue_be        = '0;
    issue_elem_cnt  = '0;
    proc_elem_cnt   = '0;
    commit_elem_cnt = '0;
    entry_be        = '0;
    new_base_vaddr  = '0;

    // Enforce strict in-order completion across variable-latency division and differing-SEW multipliers
    latency_stall = issue_active & proc_active & (issue_pnt_q != proc_pnt_q) &
                    (issue_ctrl.is_div | proc_ctrl.is_div |
                     (mul_pipe_lat(issue_ctrl.vsew) < mul_pipe_lat(proc_ctrl.vsew)));

    operands_valid = ((mfpu_operand_valid_i & issue_meta.req_op_mask) == issue_meta.req_op_mask) &&
                     (mask_valid_i || issue_ctrl.vm);

    // ---------------------------------------------------
    // 1. Issue Phase
    // ---------------------------------------------------
    if (issue_active && operands_valid && (issue_cnt_q != '0) && !latency_stall) begin
      issue_elem_cnt = 4'd1 << (2'(EW64) - 2'(issue_ctrl.vsew));
      if (vlen_t'(issue_elem_cnt) > issue_cnt_q) begin
        issue_elem_cnt = issue_cnt_q[3:0];
      end
      issue_be = be(issue_elem_cnt, issue_ctrl.vsew) & (issue_ctrl.vm ? {StrbWidth{1'b1}} : mask_i);

      vmul_in_valid = ~issue_ctrl.is_div;
      vdiv_in_valid =  issue_ctrl.is_div;

      if ((~issue_ctrl.is_div && vmul_in_ready) || (issue_ctrl.is_div && vdiv_in_ready)) begin
        mfpu_operand_ready_o = issue_meta.req_op_mask;
        mask_ready_o         = ~issue_ctrl.vm;

        issue_cnt_d = issue_cnt_q - vlen_t'(issue_elem_cnt);
        if (issue_cnt_d == '0) begin
          issue_insns_d = issue_insns_q - 1'b1;
          issue_pnt_d   = (issue_pnt_q == PntWidth'(VInsnQueueDepth - 1)) ? '0 : (issue_pnt_q + 1'b1);
          if (issue_insns_d != '0) begin
            issue_cnt_d = ctrl_tbl_q[issue_pnt_d].vl;
          end
        end
      end
    end

    // ---------------------------------------------------
    // 2. Processing Phase -> Result Queue Write
    // ---------------------------------------------------
    if (proc_ctrl.is_div) begin
      unit_out_valid  = vdiv_out_valid;
      unit_out_result = vdiv_result;
      unit_out_mask   = vdiv_mask;
    end else begin
      unit_out_valid  = vmul_out_valid;
      unit_out_result = vmul_result;
      unit_out_mask   = vmul_mask;
    end

    if (proc_active && unit_out_valid && !result_queue_full) begin
      proc_elem_cnt = 4'd1 << (2'(EW64) - 2'(proc_ctrl.vsew));
      if (vlen_t'(proc_elem_cnt) > to_process_cnt_q) begin
        proc_elem_cnt = to_process_cnt_q[3:0];
      end

      entry_be = be(proc_elem_cnt, proc_ctrl.vsew) &
                 (proc_ctrl.vm ? {StrbWidth{1'b1}} : unit_out_mask);

      result_queue_d[result_queue_write_pnt_q].id    = proc_ctrl.id;
      result_queue_d[result_queue_write_pnt_q].addr  = proc_vaddr_q;
      result_queue_d[result_queue_write_pnt_q].wdata = unit_out_result;
      result_queue_d[result_queue_write_pnt_q].be    = entry_be;
      result_queue_d[result_queue_write_pnt_q].sat   = proc_ctrl.is_vsmul & (|(vmul_vxsat_bits & entry_be));
      result_queue_valid_d[result_queue_write_pnt_q] = 1'b1;

      result_queue_cnt_d       = result_queue_cnt_q + 1'b1;
      result_queue_write_pnt_d = (result_queue_write_pnt_q == ResultQueueDepth - 1) ? '0 : (result_queue_write_pnt_q + 1'b1);

      to_process_cnt_d = to_process_cnt_q - vlen_t'(proc_elem_cnt);
      if (to_process_cnt_d == '0) begin
        proc_insns_d = proc_insns_q - 1'b1;
        proc_pnt_d   = (proc_pnt_q == PntWidth'(VInsnQueueDepth - 1)) ? '0 : (proc_pnt_q + 1'b1);
        if (proc_insns_d != '0) begin
          to_process_cnt_d = ctrl_tbl_q[proc_pnt_d].vl;
          proc_vaddr_d     = ctrl_tbl_q[proc_pnt_d].base_vaddr;
        end
      end else begin
        proc_vaddr_d = proc_vaddr_q + 1'b1;
      end
    end

    // ---------------------------------------------------
    // 3. VRF Writeback & Commit Phase
    // ---------------------------------------------------
    mfpu_result_req_o   = result_queue_valid_q[result_queue_read_pnt_q];
    mfpu_result_id_o    = result_queue_q[result_queue_read_pnt_q].id;
    mfpu_result_addr_o  = result_queue_q[result_queue_read_pnt_q].addr;
    mfpu_result_wdata_o = result_queue_q[result_queue_read_pnt_q].wdata;
    mfpu_result_be_o    = result_queue_q[result_queue_read_pnt_q].be;
    mfpu_vxsat_o        = result_queue_valid_q[result_queue_read_pnt_q] & result_queue_q[result_queue_read_pnt_q].sat;

    if (mfpu_result_gnt_i) begin
      commit_elem_cnt = 4'd1 << (2'(EW64) - 2'(commit_ctrl.vsew));

      result_queue_valid_d[result_queue_read_pnt_q] = 1'b0;
      result_queue_d[result_queue_read_pnt_q]       = '0;
      result_queue_read_pnt_d = (result_queue_read_pnt_q == ResultQueueDepth - 1) ? '0 : (result_queue_read_pnt_q + 1'b1);
      result_queue_cnt_d      = result_queue_cnt_d - 1'b1;

      if (commit_cnt_q <= vlen_t'(commit_elem_cnt)) begin
        commit_cnt_d = '0;
      end else begin
        commit_cnt_d = commit_cnt_q - vlen_t'(commit_elem_cnt);
      end
    end

    if (commit_active && (commit_cnt_d == '0)) begin
      mfpu_vinsn_done_o[commit_ctrl.id] = 1'b1;
      commit_insns_d = commit_insns_q - 1'b1;
      commit_pnt_d   = (commit_pnt_q == PntWidth'(VInsnQueueDepth - 1)) ? '0 : (commit_pnt_q + 1'b1);
      if (commit_insns_d != '0) begin
        commit_cnt_d = ctrl_tbl_q[commit_pnt_d].vl;
      end
    end

    // ---------------------------------------------------
    // 4. Accept New Vector Instruction
    // ---------------------------------------------------
    if (!vinsn_queue_full && vfu_operation_valid_i && (vfu_operation_i.vfu == VFU_MFpu)) begin
      new_base_vaddr = vaddr_t'(vaddr(vfu_operation_i.vd, NrLanes, VLEN));

      issue_tbl_d[accept_pnt_q].scalar_rep    = vfu_operation_i.use_scalar_op ?
                                                replicate_scalar(vfu_operation_i.scalar_op, vfu_operation_i.vtype.vsew) : '0;
      issue_tbl_d[accept_pnt_q].use_scalar_op = vfu_operation_i.use_scalar_op;
      issue_tbl_d[accept_pnt_q].req_op_mask   = vfu_operation_i.swap_vs2_vd_op ?
                                                {vfu_operation_i.use_vs2, vfu_operation_i.use_vd_op, vfu_operation_i.use_vs1} :
                                                {vfu_operation_i.use_vd_op, vfu_operation_i.use_vs2, vfu_operation_i.use_vs1};
      issue_tbl_d[accept_pnt_q].op            = vfu_operation_i.op;

      ctrl_tbl_d[accept_pnt_q].id         = vfu_operation_i.id;
      ctrl_tbl_d[accept_pnt_q].vsew       = vfu_operation_i.vtype.vsew;
      ctrl_tbl_d[accept_pnt_q].vm         = vfu_operation_i.vm;
      ctrl_tbl_d[accept_pnt_q].is_div     = (vfu_operation_i.op inside {[VDIVU:VREM]});
      ctrl_tbl_d[accept_pnt_q].is_vsmul   = (vfu_operation_i.op == VSMUL);
      ctrl_tbl_d[accept_pnt_q].base_vaddr = new_base_vaddr;
      ctrl_tbl_d[accept_pnt_q].vl         = vfu_operation_i.vl;

      if (issue_insns_d == '0) begin
        issue_cnt_d = vfu_operation_i.vl;
      end
      if (proc_insns_d == '0) begin
        to_process_cnt_d = vfu_operation_i.vl;
        proc_vaddr_d     = new_base_vaddr;
      end
      if (commit_insns_d == '0) begin
        commit_cnt_d = vfu_operation_i.vl;
      end

      accept_pnt_d   = (accept_pnt_q == PntWidth'(VInsnQueueDepth - 1)) ? '0 : (accept_pnt_q + 1'b1);
      issue_insns_d  = issue_insns_d  + 1'b1;
      proc_insns_d   = proc_insns_d   + 1'b1;
      commit_insns_d = commit_insns_d + 1'b1;
    end

    // Per-EW multiplier clock-gate enables
    clkgate_ew_d = '0;
    if (issue_insns_d != '0 && !ctrl_tbl_d[issue_pnt_d].is_div) begin
      clkgate_ew_d[ctrl_tbl_d[issue_pnt_d].vsew] = 1'b1;
    end
    if (proc_insns_d != '0 && !ctrl_tbl_d[proc_pnt_d].is_div) begin
      clkgate_ew_d[ctrl_tbl_d[proc_pnt_d].vsew] = 1'b1;
    end
    if (ew8_valid_q)  clkgate_ew_d[EW8]  = 1'b1;
    if (ew64_valid_q) clkgate_ew_d[EW64] = 1'b1;
  end : p_vmfpu

  //////////////////////////////
  //  Sequential State Flops  //
  //////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      issue_tbl_q              <= '0;
      ctrl_tbl_q               <= '0;
      accept_pnt_q             <= '0;
      issue_pnt_q              <= '0;
      proc_pnt_q               <= '0;
      commit_pnt_q             <= '0;
      issue_insns_q            <= '0;
      proc_insns_q             <= '0;
      commit_insns_q           <= '0;
      issue_cnt_q              <= '0;
      to_process_cnt_q         <= '0;
      commit_cnt_q             <= '0;
      proc_vaddr_q             <= '0;
      clkgate_ew_q             <= '0;
      result_queue_q           <= '0;
      result_queue_valid_q     <= '0;
      result_queue_write_pnt_q <= '0;
      result_queue_read_pnt_q  <= '0;
      result_queue_cnt_q       <= '0;
    end else begin
      issue_tbl_q              <= issue_tbl_d;
      ctrl_tbl_q               <= ctrl_tbl_d;
      accept_pnt_q             <= accept_pnt_d;
      issue_pnt_q              <= issue_pnt_d;
      proc_pnt_q               <= proc_pnt_d;
      commit_pnt_q             <= commit_pnt_d;
      issue_insns_q            <= issue_insns_d;
      proc_insns_q             <= proc_insns_d;
      commit_insns_q           <= commit_insns_d;
      issue_cnt_q              <= issue_cnt_d;
      to_process_cnt_q         <= to_process_cnt_d;
      commit_cnt_q             <= commit_cnt_d;
      proc_vaddr_q             <= proc_vaddr_d;
      clkgate_ew_q             <= clkgate_ew_d;
      result_queue_q           <= result_queue_d;
      result_queue_valid_q     <= result_queue_valid_d;
      result_queue_write_pnt_q <= result_queue_write_pnt_d;
      result_queue_read_pnt_q  <= result_queue_read_pnt_d;
      result_queue_cnt_q       <= result_queue_cnt_d;
    end
  end

endmodule : vmfpu
