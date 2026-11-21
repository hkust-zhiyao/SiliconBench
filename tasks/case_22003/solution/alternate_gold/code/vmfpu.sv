// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
//          Matteo Perotti <mperotti@iis.ee.ethz.ch>
// Description:
// Alternate microarchitecture for Ara's lane integer VMFPU:
// Beat-granular micro-op counters with accept-time tail byte-enable predecoding,
// shared post-mux SIMD multiplier output pipeline stage, and per-EW clock gating.

module vmfpu import ara_pkg::*; import rvv_pkg::*; import fpnew_pkg::*;
  import cf_math_pkg::idx_width; #(
    parameter  int           unsigned NrLanes         = 0,
    parameter  int           unsigned VLEN            = 0,
    parameter  config_pkg::cva6_cfg_t CVA6Cfg         = cva6_config_pkg::cva6_cfg,
    parameter  fpu_support_e          FPUSupport      = FPUSupportHalfSingleDouble,
    parameter  fpext_support_e        FPExtSupport    = FPExtSupportEnable,
    parameter  fixpt_support_e        FixPtSupport    = FixedPointEnable,
    parameter  type                   vaddr_t         = logic,
    parameter  type                   vfu_operation_t = logic,
    localparam int           unsigned DataWidth       = $bits(elen_t),
    localparam int           unsigned StrbWidth       = DataWidth/8,
    localparam type                   strb_t          = logic [DataWidth/8-1:0],
    localparam type                   vlen_t          = logic[$clog2(VLEN+1)-1:0]
  ) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic[idx_width(NrLanes)-1:0] lane_id_i,
    output logic                         mfpu_vxsat_o,
    input  vxrm_t                        mfpu_vxrm_i,
    output logic           [4:0]         fflags_ex_o,
    output logic                         fflags_ex_valid_o,
    input  vfu_operation_t               vfu_operation_i,
    input  logic                         vfu_operation_valid_i,
    output logic                         mfpu_ready_o,
    output logic           [NrVInsn-1:0] mfpu_vinsn_done_o,
    output logic                         fpu_red_complete_o,
    input  elen_t          [2:0]         mfpu_operand_i,
    input  logic           [2:0]         mfpu_operand_valid_i,
    output logic           [2:0]         mfpu_operand_ready_o,
    output logic                         mfpu_result_req_o,
    output vid_t                         mfpu_result_id_o,
    output vaddr_t                       mfpu_result_addr_o,
    output elen_t                        mfpu_result_wdata_o,
    output strb_t                        mfpu_result_be_o,
    input  logic                         mfpu_result_gnt_i,
    output logic                         mfpu_red_valid_o,
    input  logic                         mfpu_red_ready_i,
    input  elen_t                        sldu_operand_i,
    input  logic                         sldu_mfpu_valid_i,
    output logic                         sldu_mfpu_ready_o,
    output elen_t                        mask_operand_o,
    output logic                         mask_operand_valid_o,
    input  logic                         mask_operand_ready_i,
    input  strb_t                        mask_i,
    input  logic                         mask_valid_i,
    output logic                         mask_ready_o
  );

  `include "common_cells/registers.svh"

  if (FPUSupport == FPUSupportNone) begin : gen_unused_fpu_ties
    wire unused_fpu_ports = ^{lane_id_i, mfpu_red_ready_i, sldu_operand_i, sldu_mfpu_valid_i, mask_operand_ready_i};
    assign fflags_ex_o          = '0;
    assign fflags_ex_valid_o    = 1'b0;
    assign fpu_red_complete_o   = 1'b0;
    assign mfpu_red_valid_o     = 1'b0;
    assign sldu_mfpu_ready_o    = 1'b0;
    assign mask_operand_o       = '0;
    assign mask_operand_valid_o = 1'b0;
  end

  /////////////////////////////////////////////////////////
  //  Beat-Granular Predecoded Micro-Op Queue            //
  /////////////////////////////////////////////////////////

  localparam int unsigned QueueDepth  = MfpuInsnQueueDepth;
  localparam int unsigned IdxW        = idx_width(QueueDepth);
  localparam int unsigned OccW        = idx_width(QueueDepth) + 1;
  localparam int unsigned MaxLaneElem = (VLEN / NrLanes);
  typedef logic [$clog2(MaxLaneElem + 1)-1:0] beat_cnt_t;

  typedef struct packed {
    elen_t      scalar_word;
    logic       use_scalar;
    logic [2:0] op_req_vec;
    ara_op_e    op;
  } issue_cmd_t;

  typedef struct packed {
    vid_t      id;
    vew_e      vsew;
    logic      vm;
    logic      is_div;
    logic      is_vsmul;
    vaddr_t    vd_addr;
    beat_cnt_t total_beats;
    strb_t     tail_be;
  } beat_desc_t;

  issue_cmd_t [QueueDepth-1:0] issue_cmd_d, issue_cmd_q;
  beat_desc_t [QueueDepth-1:0] beat_desc_d, beat_desc_q;

  logic [IdxW-1:0] wr_idx_d,     wr_idx_q;
  logic [IdxW-1:0] issue_idx_d,  issue_idx_q;
  logic [IdxW-1:0] proc_idx_d,   proc_idx_q;
  logic [IdxW-1:0] commit_idx_d, commit_idx_q;

  logic [OccW-1:0] issue_occ_d,  issue_occ_q;
  logic [OccW-1:0] proc_occ_d,   proc_occ_q;
  logic [OccW-1:0] commit_occ_d, commit_occ_q;

  beat_cnt_t issue_beats_d,  issue_beats_q;
  beat_cnt_t proc_beats_d,   proc_beats_q;
  beat_cnt_t commit_beats_d, commit_beats_q;
  vaddr_t    wr_vaddr_d,     wr_vaddr_q;

  logic queue_full;
  assign queue_full = (commit_occ_q == OccW'(QueueDepth));

  issue_cmd_t cur_issue_cmd;
  beat_desc_t cur_issue_desc, cur_proc_desc, cur_commit_desc;

  assign cur_issue_cmd   = issue_cmd_q[issue_idx_q];
  assign cur_issue_desc  = beat_desc_q[issue_idx_q];
  assign cur_proc_desc   = beat_desc_q[proc_idx_q];
  assign cur_commit_desc = beat_desc_q[commit_idx_q];

  function automatic elen_t broadcast_scalar(input elen_t s, input vew_e ew);
    unique case (ew)
      EW64   : broadcast_scalar = s;
      EW32   : broadcast_scalar = {2{s[31:0]}};
      EW16   : broadcast_scalar = {4{s[15:0]}};
      default: broadcast_scalar = {8{s[ 7:0]}};
    endcase
  endfunction

  /////////////////////////////////////////////////////////
  //  SIMD Multiplier Array + Shared Output Skid Stage   //
  /////////////////////////////////////////////////////////

  logic [3:0] mul_cg_en_d, mul_cg_en_q;
  logic [3:0] clk_mul_ew;

  for (genvar g = 0; g < 4; g++) begin : gen_mul_cg
    tc_clk_gating i_mul_cg (
      .clk_i    (clk_i         ),
      .en_i     (mul_cg_en_q[g]),
      .test_en_i(1'b0          ),
      .clk_o    (clk_mul_ew[g] )
    );
  end

  elen_t mul_in_a, mul_in_b, mul_in_c;
  // Gate EW8 combinational array inputs when not actively issuing EW8 multiply
  logic  ew8_issue_en;
  assign mul_in_a = cur_issue_cmd.use_scalar ? cur_issue_cmd.scalar_word : mfpu_operand_i[0];
  assign mul_in_b = mfpu_operand_i[1];
  assign mul_in_c = mfpu_operand_i[2];

  logic   [3:0] mul_arr_in_vld,  mul_arr_in_rdy;
  logic   [3:0] mul_arr_out_vld, mul_arr_out_rdy;
  elen_t  [3:0] mul_arr_res;
  strb_t  [3:0] mul_arr_mask;
  vxsat_t [3:0] mul_arr_vxsat;

  assign ew8_issue_en = (issue_occ_q != '0) & ~cur_issue_desc.is_div & (cur_issue_desc.vsew == EW8);

  simd_mul #(
    .FixPtSupport(FixPtSupport    ),
    .NumPipeRegs (LatMultiplierEW8),
    .ElementWidth(EW8             )
  ) i_simd_mul_ew8 (
    .clk_i      (clk_mul_ew[EW8]                        ),
    .rst_ni     (rst_ni                                 ),
    .operand_a_i(ew8_issue_en ? mul_in_a      : '0      ),
    .operand_b_i(ew8_issue_en ? mul_in_b      : '0      ),
    .operand_c_i(ew8_issue_en ? mul_in_c      : '0      ),
    .mask_i     (ew8_issue_en ? mask_i        : '0      ),
    .op_i       (ew8_issue_en ? cur_issue_cmd.op : ara_op_e'('0)),
    .result_o   (mul_arr_res[EW8]                       ),
    .mask_o     (mul_arr_mask[EW8]                      ),
    .vxsat_o    (mul_arr_vxsat[EW8]                     ),
    .vxrm_i     (mfpu_vxrm_i                            ),
    .valid_i    (mul_arr_in_vld[EW8]                    ),
    .ready_o    (mul_arr_in_rdy[EW8]                    ),
    .ready_i    (mul_arr_out_rdy[EW8]                   ),
    .valid_o    (mul_arr_out_vld[EW8]                   )
  );

  simd_mul #(
    .FixPtSupport(FixPtSupport     ),
    .NumPipeRegs (LatMultiplierEW16),
    .ElementWidth(EW16             )
  ) i_simd_mul_ew16 (
    .clk_i      (clk_mul_ew[EW16]    ),
    .rst_ni     (rst_ni              ),
    .operand_a_i(mul_in_a            ),
    .operand_b_i(mul_in_b            ),
    .operand_c_i(mul_in_c            ),
    .mask_i     (mask_i              ),
    .op_i       (cur_issue_cmd.op    ),
    .result_o   (mul_arr_res[EW16]   ),
    .mask_o     (mul_arr_mask[EW16]  ),
    .vxsat_o    (mul_arr_vxsat[EW16] ),
    .vxrm_i     (mfpu_vxrm_i         ),
    .valid_i    (mul_arr_in_vld[EW16]),
    .ready_o    (mul_arr_in_rdy[EW16]),
    .ready_i    (mul_arr_out_rdy[EW16]),
    .valid_o    (mul_arr_out_vld[EW16])
  );

  simd_mul #(
    .FixPtSupport(FixPtSupport     ),
    .NumPipeRegs (LatMultiplierEW32),
    .ElementWidth(EW32             )
  ) i_simd_mul_ew32 (
    .clk_i      (clk_mul_ew[EW32]    ),
    .rst_ni     (rst_ni              ),
    .operand_a_i(mul_in_a            ),
    .operand_b_i(mul_in_b            ),
    .operand_c_i(mul_in_c            ),
    .mask_i     (mask_i              ),
    .op_i       (cur_issue_cmd.op    ),
    .result_o   (mul_arr_res[EW32]   ),
    .mask_o     (mul_arr_mask[EW32]  ),
    .vxsat_o    (mul_arr_vxsat[EW32] ),
    .vxrm_i     (mfpu_vxrm_i         ),
    .valid_i    (mul_arr_in_vld[EW32]),
    .ready_o    (mul_arr_in_rdy[EW32]),
    .ready_i    (mul_arr_out_rdy[EW32]),
    .valid_o    (mul_arr_out_vld[EW32])
  );

  simd_mul #(
    .FixPtSupport(FixPtSupport     ),
    .NumPipeRegs (LatMultiplierEW64),
    .ElementWidth(EW64             )
  ) i_simd_mul_ew64 (
    .clk_i      (clk_mul_ew[EW64]    ),
    .rst_ni     (rst_ni              ),
    .operand_a_i(mul_in_a            ),
    .operand_b_i(mul_in_b            ),
    .operand_c_i(mul_in_c            ),
    .mask_i     (mask_i              ),
    .op_i       (cur_issue_cmd.op    ),
    .result_o   (mul_arr_res[EW64]   ),
    .mask_o     (mul_arr_mask[EW64]  ),
    .vxsat_o    (mul_arr_vxsat[EW64] ),
    .vxrm_i     (mfpu_vxrm_i         ),
    .valid_i    (mul_arr_in_vld[EW64]),
    .ready_o    (mul_arr_in_rdy[EW64]),
    .ready_i    (mul_arr_out_rdy[EW64]),
    .valid_o    (mul_arr_out_vld[EW64])
  );

  // Shared 1-stage output pipeline register capturing the active EW multiplier result
  logic       mul_pipe_vld_q, mul_pipe_rdy_in, mul_out_pop;
  elen_t      mul_pipe_res_q;
  strb_t      mul_pipe_mask_q;
  logic [7:0] mul_pipe_sat_q;

  logic       sel_mul_vld;
  elen_t      sel_mul_res;
  strb_t      sel_mul_mask;
  logic [7:0] sel_mul_sat;

  assign mul_pipe_rdy_in = ~mul_pipe_vld_q | mul_out_pop;

  always_comb begin : p_mul_mux
    mul_arr_out_rdy = '0;
    sel_mul_vld     = mul_arr_out_vld[cur_proc_desc.vsew];
    sel_mul_res     = mul_arr_res    [cur_proc_desc.vsew];
    sel_mul_mask    = mul_arr_mask   [cur_proc_desc.vsew];
    sel_mul_sat     = mul_arr_vxsat  [cur_proc_desc.vsew];
    if ((proc_occ_q != '0) && !cur_proc_desc.is_div) begin
      mul_arr_out_rdy[cur_proc_desc.vsew] = mul_pipe_rdy_in;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mul_pipe_vld_q  <= 1'b0;
      mul_pipe_res_q  <= '0;
      mul_pipe_mask_q <= '0;
      mul_pipe_sat_q  <= '0;
    end else if (mul_pipe_rdy_in) begin
      mul_pipe_vld_q <= ((proc_occ_q != '0) && !cur_proc_desc.is_div) ? sel_mul_vld : 1'b0;
      if (sel_mul_vld && (proc_occ_q != '0) && !cur_proc_desc.is_div) begin
        mul_pipe_res_q  <= sel_mul_res;
        mul_pipe_mask_q <= sel_mul_mask;
        mul_pipe_sat_q  <= sel_mul_sat;
      end
    end
  end

  ///////////////
  //  Divider  //
  ///////////////

  elen_t div_out_res;
  strb_t div_out_mask;
  strb_t div_in_be;
  logic  div_in_vld, div_in_rdy, div_out_vld, div_out_rdy;

  simd_div #(
    .CVA6Cfg(CVA6Cfg)
  ) i_simd_div (
    .clk_i      (clk_i            ),
    .rst_ni     (rst_ni           ),
    .operand_a_i(mfpu_operand_i[1]),
    .operand_b_i(mul_in_a         ),
    .mask_i     (mask_i           ),
    .op_i       (cur_issue_cmd.op ),
    .be_i       (div_in_be        ),
    .vew_i      (cur_issue_desc.vsew),
    .result_o   (div_out_res      ),
    .mask_o     (div_out_mask     ),
    .valid_i    (div_in_vld       ),
    .ready_o    (div_in_rdy       ),
    .ready_i    (div_out_rdy      ),
    .valid_o    (div_out_vld      )
  );

  ////////////////////
  //  Result Queue  //
  ////////////////////

  localparam int unsigned ResQDepth = 2;

  typedef struct packed {
    vid_t   id;
    vaddr_t addr;
    elen_t  wdata;
    strb_t  be;
    logic   sat;
  } res_entry_t;

  res_entry_t [ResQDepth-1:0] res_q_d, res_q_q;
  logic       [ResQDepth-1:0] res_vld_d, res_vld_q;
  logic                       res_wr_ptr_d, res_wr_ptr_q;
  logic                       res_rd_ptr_d, res_rd_ptr_q;
  logic       [1:0]           res_occ_d, res_occ_q;

  logic res_q_full;
  assign res_q_full = (res_occ_q == 2'd2);

  //////////////////////////////////////////
  //  Main Beat-Granular Pipeline Logic   //
  //////////////////////////////////////////

  logic  issue_rdy_from_unit;
  logic  in_ops_ready;
  logic  order_interlock;
  logic  wb_unit_vld;
  elen_t wb_unit_res;
  strb_t wb_unit_mask;
  strb_t issue_pos_be, proc_pos_be, final_wb_be;

  always_comb begin : p_pipeline
    automatic logic [1:0]  acc_sh;
    automatic vlen_t       acc_vl_m1;
    automatic beat_cnt_t   acc_beats;
    automatic logic [3:0]  acc_tail_cnt;
    automatic vaddr_t      acc_vaddr;

    issue_cmd_d    = issue_cmd_q;
    beat_desc_d    = beat_desc_q;
    wr_idx_d       = wr_idx_q;
    issue_idx_d    = issue_idx_q;
    proc_idx_d     = proc_idx_q;
    commit_idx_d   = commit_idx_q;
    issue_occ_d    = issue_occ_q;
    proc_occ_d     = proc_occ_q;
    commit_occ_d   = commit_occ_q;
    issue_beats_d  = issue_beats_q;
    proc_beats_d   = proc_beats_q;
    commit_beats_d = commit_beats_q;
    wr_vaddr_d     = wr_vaddr_q;

    res_q_d      = res_q_q;
    res_vld_d    = res_vld_q;
    res_wr_ptr_d = res_wr_ptr_q;
    res_rd_ptr_d = res_rd_ptr_q;
    res_occ_d    = res_occ_q;

    mfpu_ready_o         = !queue_full;
    mfpu_vinsn_done_o    = '0;
    mfpu_operand_ready_o = '0;
    mask_ready_o         = 1'b0;

    mul_arr_in_vld = '0;
    div_in_vld     = 1'b0;
    mul_out_pop    = ~res_q_full & (proc_occ_q != '0) & ~cur_proc_desc.is_div;
    div_out_rdy    = ~res_q_full & (proc_occ_q != '0) &  cur_proc_desc.is_div;

    issue_pos_be = (issue_beats_q == beat_cnt_t'(1)) ? cur_issue_desc.tail_be : 8'hFF;
    div_in_be    = issue_pos_be & (cur_issue_desc.vm ? 8'hFF : mask_i);

    // Interlock cross-instruction issue when processing is still draining a prior instruction
    // unless both are identical-SEW multipliers
    order_interlock = (issue_occ_q != '0) && (proc_occ_q != '0) && (issue_idx_q != proc_idx_q) &&
                      (cur_issue_desc.is_div || cur_proc_desc.is_div ||
                       (cur_issue_desc.vsew != cur_proc_desc.vsew));

    in_ops_ready = ((mfpu_operand_valid_i & cur_issue_cmd.op_req_vec) == cur_issue_cmd.op_req_vec) &&
                   (mask_valid_i || cur_issue_desc.vm);

    issue_rdy_from_unit = cur_issue_desc.is_div ?
                          div_in_rdy :
                          ((cur_issue_desc.vsew == EW8 ? 1'b1 : mul_cg_en_q[cur_issue_desc.vsew]) &
                           mul_arr_in_rdy[cur_issue_desc.vsew]);

    // 1. Issue Phase
    if ((issue_occ_q != '0) && (issue_beats_q != '0) && in_ops_ready && !order_interlock) begin
      if (cur_issue_desc.is_div) begin
        div_in_vld = 1'b1;
      end else begin
        mul_arr_in_vld[cur_issue_desc.vsew] = (cur_issue_desc.vsew == EW8) ? 1'b1 : mul_cg_en_q[cur_issue_desc.vsew];
      end

      if (issue_rdy_from_unit) begin
        mfpu_operand_ready_o = cur_issue_cmd.op_req_vec;
        mask_ready_o         = ~cur_issue_desc.vm;

        issue_beats_d = issue_beats_q - 1'b1;
        if (issue_beats_d == '0) begin
          issue_occ_d = issue_occ_q - 1'b1;
          issue_idx_d = issue_idx_q + 1'b1;
          if (issue_occ_d != '0) begin
            issue_beats_d = beat_desc_q[issue_idx_d].total_beats;
          end
        end
      end
    end

    // 2. Processing Phase
    if (cur_proc_desc.is_div) begin
      wb_unit_vld  = div_out_vld;
      wb_unit_res  = div_out_res;
      wb_unit_mask = div_out_mask;
    end else begin
      wb_unit_vld  = mul_pipe_vld_q;
      wb_unit_res  = mul_pipe_res_q;
      wb_unit_mask = mul_pipe_mask_q;
    end

    proc_pos_be = (proc_beats_q == beat_cnt_t'(1)) ? cur_proc_desc.tail_be : 8'hFF;
    final_wb_be = proc_pos_be & (cur_proc_desc.vm ? 8'hFF : wb_unit_mask);

    if ((proc_occ_q != '0) && wb_unit_vld && !res_q_full) begin
      res_q_d[res_wr_ptr_q].id    = cur_proc_desc.id;
      res_q_d[res_wr_ptr_q].addr  = wr_vaddr_q;
      res_q_d[res_wr_ptr_q].wdata = wb_unit_res;
      res_q_d[res_wr_ptr_q].be    = final_wb_be;
      res_q_d[res_wr_ptr_q].sat   = cur_proc_desc.is_vsmul & (|(mul_pipe_sat_q & final_wb_be));
      res_vld_d[res_wr_ptr_q]     = 1'b1;

      res_wr_ptr_d = ~res_wr_ptr_q;
      res_occ_d    = res_occ_q + 1'b1;

      proc_beats_d = proc_beats_q - 1'b1;
      if (proc_beats_d == '0) begin
        proc_occ_d = proc_occ_q - 1'b1;
        proc_idx_d = proc_idx_q + 1'b1;
        if (proc_occ_d != '0) begin
          proc_beats_d = beat_desc_q[proc_idx_d].total_beats;
          wr_vaddr_d   = beat_desc_q[proc_idx_d].vd_addr;
        end
      end else begin
        wr_vaddr_d = wr_vaddr_q + 1'b1;
      end
    end

    // 3. VRF Commit Phase
    mfpu_result_req_o   = res_vld_q[res_rd_ptr_q];
    mfpu_result_id_o    = res_q_q[res_rd_ptr_q].id;
    mfpu_result_addr_o  = res_q_q[res_rd_ptr_q].addr;
    mfpu_result_wdata_o = res_q_q[res_rd_ptr_q].wdata;
    mfpu_result_be_o    = res_q_q[res_rd_ptr_q].be;
    mfpu_vxsat_o        = res_vld_q[res_rd_ptr_q] & res_q_q[res_rd_ptr_q].sat;

    if (mfpu_result_gnt_i) begin
      res_vld_d[res_rd_ptr_q] = 1'b0;
      res_q_d[res_rd_ptr_q]   = '0;
      res_rd_ptr_d            = ~res_rd_ptr_q;
      res_occ_d               = res_occ_d - 1'b1;

      commit_beats_d = commit_beats_q - 1'b1;
    end

    if ((commit_occ_q != '0) && (commit_beats_d == '0)) begin
      mfpu_vinsn_done_o[cur_commit_desc.id] = 1'b1;
      commit_occ_d = commit_occ_q - 1'b1;
      commit_idx_d = commit_idx_q + 1'b1;
      if (commit_occ_d != '0) begin
        commit_beats_d = beat_desc_q[commit_idx_d].total_beats;
      end
    end

    // 4. Accept Phase (pre-compute beat count and final-beat byte strobe once)
    acc_sh       = 2'(EW64) - 2'(vfu_operation_i.vtype.vsew);
    acc_vl_m1    = vfu_operation_i.vl - 1'b1;
    acc_beats    = beat_cnt_t'(acc_vl_m1 >> acc_sh) + 1'b1;
    acc_tail_cnt = 4'(acc_vl_m1[2:0] & ((3'd1 << acc_sh) - 3'd1)) + 4'd1;
    acc_vaddr    = vaddr_t'(vaddr(vfu_operation_i.vd, NrLanes, VLEN));

    if (!queue_full && vfu_operation_valid_i && (vfu_operation_i.vfu == VFU_MFpu)) begin
      issue_cmd_d[wr_idx_q].scalar_word = vfu_operation_i.use_scalar_op ?
                                          broadcast_scalar(vfu_operation_i.scalar_op, vfu_operation_i.vtype.vsew) : '0;
      issue_cmd_d[wr_idx_q].use_scalar  = vfu_operation_i.use_scalar_op;
      issue_cmd_d[wr_idx_q].op_req_vec  = vfu_operation_i.swap_vs2_vd_op ?
                                          {vfu_operation_i.use_vs2, vfu_operation_i.use_vd_op, vfu_operation_i.use_vs1} :
                                          {vfu_operation_i.use_vd_op, vfu_operation_i.use_vs2, vfu_operation_i.use_vs1};
      issue_cmd_d[wr_idx_q].op          = vfu_operation_i.op;

      beat_desc_d[wr_idx_q].id          = vfu_operation_i.id;
      beat_desc_d[wr_idx_q].vsew        = vfu_operation_i.vtype.vsew;
      beat_desc_d[wr_idx_q].vm          = vfu_operation_i.vm;
      beat_desc_d[wr_idx_q].is_div      = (vfu_operation_i.op inside {[VDIVU:VREM]});
      beat_desc_d[wr_idx_q].is_vsmul    = (vfu_operation_i.op == VSMUL);
      beat_desc_d[wr_idx_q].vd_addr     = acc_vaddr;
      beat_desc_d[wr_idx_q].total_beats = acc_beats;
      beat_desc_d[wr_idx_q].tail_be     = be(acc_tail_cnt, vfu_operation_i.vtype.vsew);

      if (issue_occ_d == '0) begin
        issue_beats_d = acc_beats;
      end
      if (proc_occ_d == '0) begin
        proc_beats_d = acc_beats;
        wr_vaddr_d   = acc_vaddr;
      end
      if (commit_occ_d == '0) begin
        commit_beats_d = acc_beats;
      end

      wr_idx_d     = wr_idx_q + 1'b1;
      issue_occ_d  = issue_occ_d  + 1'b1;
      proc_occ_d   = proc_occ_d   + 1'b1;
      commit_occ_d = commit_occ_d + 1'b1;
    end

    mul_cg_en_d = '0;
    if ((issue_occ_d != '0) && !beat_desc_d[issue_idx_d].is_div) begin
      mul_cg_en_d[beat_desc_d[issue_idx_d].vsew] = 1'b1;
    end
    if ((proc_occ_d != '0) && !beat_desc_d[proc_idx_d].is_div) begin
      mul_cg_en_d[beat_desc_d[proc_idx_d].vsew] = 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      issue_cmd_q    <= '0;
      beat_desc_q    <= '0;
      wr_idx_q       <= '0;
      issue_idx_q    <= '0;
      proc_idx_q     <= '0;
      commit_idx_q   <= '0;
      issue_occ_q    <= '0;
      proc_occ_q     <= '0;
      commit_occ_q   <= '0;
      issue_beats_q  <= '0;
      proc_beats_q   <= '0;
      commit_beats_q <= '0;
      wr_vaddr_q     <= '0;
      mul_cg_en_q    <= '0;
      res_q_q        <= '0;
      res_vld_q      <= '0;
      res_wr_ptr_q   <= 1'b0;
      res_rd_ptr_q   <= 1'b0;
      res_occ_q      <= '0;
    end else begin
      issue_cmd_q    <= issue_cmd_d;
      beat_desc_q    <= beat_desc_d;
      wr_idx_q       <= wr_idx_d;
      issue_idx_q    <= issue_idx_d;
      proc_idx_q     <= proc_idx_d;
      commit_idx_q   <= commit_idx_d;
      issue_occ_q    <= issue_occ_d;
      proc_occ_q     <= proc_occ_d;
      commit_occ_q   <= commit_occ_d;
      issue_beats_q  <= issue_beats_d;
      proc_beats_q   <= proc_beats_d;
      commit_beats_q <= commit_beats_d;
      wr_vaddr_q     <= wr_vaddr_d;
      mul_cg_en_q    <= mul_cg_en_d;
      res_q_q        <= res_q_d;
      res_vld_q      <= res_vld_d;
      res_wr_ptr_q   <= res_wr_ptr_d;
      res_rd_ptr_q   <= res_rd_ptr_d;
      res_occ_q      <= res_occ_d;
    end
  end

endmodule : vmfpu
