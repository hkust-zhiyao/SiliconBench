// Copyright 2021-2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
// Description:
// Ara's slide and inter-lane reduction unit (`NrLanes = 2, 4, 8`).

module sldu import ara_pkg::*; import rvv_pkg::*; #(
    parameter  int  unsigned NrLanes   = 0,
    parameter  int  unsigned VLEN      = 0,
    parameter  type          vaddr_t   = logic,
    parameter  type          pe_req_t  = logic,
    parameter  type          pe_resp_t = logic,
    // Dependant parameters. DO NOT CHANGE!
    localparam int  unsigned DataWidth = $bits(elen_t),
    localparam int  unsigned StrbWidth = DataWidth/8,
    localparam type          strb_t    = logic [StrbWidth-1:0],
    localparam type          vlen_t    = logic[$clog2(VLEN+1)-1:0]
  ) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    // Interface with the main sequencer
    input  pe_req_t                pe_req_i,
    input  logic                   pe_req_valid_i,
    input  logic     [NrVInsn-1:0] pe_vinsn_running_i,
    output logic                   pe_req_ready_o,
    output pe_resp_t               pe_resp_o,
    // Interface with the lanes
    input  elen_t    [NrLanes-1:0] sldu_operand_i,
    input  logic     [NrLanes-1:0] sldu_operand_valid_i,
    output logic     [NrLanes-1:0] sldu_operand_ready_o,
    output logic     [NrLanes-1:0] sldu_result_req_o,
    output vid_t     [NrLanes-1:0] sldu_result_id_o,
    output vaddr_t   [NrLanes-1:0] sldu_result_addr_o,
    output elen_t    [NrLanes-1:0] sldu_result_wdata_o,
    output strb_t    [NrLanes-1:0] sldu_result_be_o,
    input  logic     [NrLanes-1:0] sldu_result_gnt_i,
    input  logic     [NrLanes-1:0] sldu_result_final_gnt_i,
    // Support for reductions
    output sldu_mux_e              sldu_mux_sel_o,
    output logic     [NrLanes-1:0] sldu_red_valid_o,
    // Interface with the Mask Unit
    input  strb_t    [NrLanes-1:0] mask_i,
    input  logic     [NrLanes-1:0] mask_valid_i,
    output logic                   mask_ready_o
  );

  `include "common_cells/registers.svh"

  import cf_math_pkg::idx_width;

  localparam int unsigned RowBytes        = 8 * NrLanes;
  localparam int unsigned RowIdxW         = $clog2(RowBytes);
  localparam int unsigned VInsnQueueDepth = SlduInsnQueueDepth;
  localparam int unsigned ResultQueueDepth = 2;
  localparam int unsigned VLenBytes       = VLEN / 8;

  typedef logic [$clog2(VLEN+1):0]   byte_cnt_t;
  typedef logic [$clog2(VLEN+1):0]   commit_beats_t;
  typedef logic [idx_width(RowBytes)-1:0] stride_t;

  function automatic byte_cnt_t calc_vlmax_bytes(rvv_pkg::vlmul_e vlmul);
    unique case (vlmul)
      rvv_pkg::LMUL_1  : return byte_cnt_t'(VLenBytes);
      rvv_pkg::LMUL_2  : return byte_cnt_t'(VLenBytes << 1);
      rvv_pkg::LMUL_4  : return byte_cnt_t'(VLenBytes << 2);
      rvv_pkg::LMUL_8  : return byte_cnt_t'(VLenBytes << 3);
      rvv_pkg::LMUL_1_2: return byte_cnt_t'(VLenBytes >> 1);
      rvv_pkg::LMUL_1_4: return byte_cnt_t'(VLenBytes >> 2);
      rvv_pkg::LMUL_1_8: return byte_cnt_t'(VLenBytes >> 3);
      default          : return byte_cnt_t'(VLenBytes);
    endcase
  endfunction

  function automatic logic stride_ge_limit(elen_t s, byte_cnt_t lim);
    return (|s[63:$bits(byte_cnt_t)]) || (s[$bits(byte_cnt_t)-1:0] >= lim);
  endfunction

  function automatic commit_beats_t calc_commit_beats(pe_req_t req);
    byte_cnt_t vl_b;
    byte_cnt_t st_b;
    byte_cnt_t first_row;
    byte_cnt_t last_row;
    if (req.vfu inside {VFU_Alu, VFU_MFpu} ||
        req.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) begin
      if (req.op inside {VFREDOSUM, VFWREDOSUM})
        return commit_beats_t'(req.vl);
      else
        return commit_beats_t'($clog2(NrLanes) + 1);
    end
    if (req.vl == '0) return '0;
    vl_b = byte_cnt_t'(req.vl) << int'(req.vtype.vsew);
    if (req.op == VSLIDEUP && !req.use_scalar_op) begin
      if (stride_ge_limit(req.stride, byte_cnt_t'(req.vl))) return '0;
      st_b      = byte_cnt_t'(req.stride[$bits(byte_cnt_t)-1:0]) << int'(req.vtype.vsew);
      first_row = st_b >> RowIdxW;
      last_row  = (vl_b - 1'b1) >> RowIdxW;
      return commit_beats_t'(last_row - first_row + 1'b1);
    end else begin
      last_row = (vl_b - 1'b1) >> RowIdxW;
      return commit_beats_t'(last_row + 1'b1);
    end
  endfunction

  ////////////////////////////////
  //  Vector instruction queue  //
  ////////////////////////////////

  struct packed {
    pe_req_t       [VInsnQueueDepth-1:0] vinsn;
    commit_beats_t [VInsnQueueDepth-1:0] beats;
    logic [idx_width(VInsnQueueDepth)-1:0] accept_pnt;
    logic [idx_width(VInsnQueueDepth)-1:0] issue_pnt;
    logic [idx_width(VInsnQueueDepth)-1:0] commit_pnt;
    logic [idx_width(VInsnQueueDepth):0]   issue_cnt;
    logic [idx_width(VInsnQueueDepth):0]   commit_cnt;
  } vinsn_queue_d, vinsn_queue_q;

  pe_req_t vinsn_issue_q;
  logic    vinsn_issue_valid_q;
  logic    vinsn_queue_full;
  assign vinsn_queue_full = (vinsn_queue_q.commit_cnt == VInsnQueueDepth);

  `FF(vinsn_issue_q, vinsn_queue_d.vinsn[vinsn_queue_d.issue_pnt], '0)
  `FF(vinsn_issue_valid_q, vinsn_queue_d.issue_cnt != '0, 1'b0)

  pe_req_t vinsn_commit;
  logic    vinsn_commit_valid;
  assign vinsn_commit       = vinsn_queue_q.vinsn[vinsn_queue_q.commit_pnt];
  assign vinsn_commit_valid = (vinsn_queue_q.commit_cnt != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) vinsn_queue_q <= '0;
    else         vinsn_queue_q <= vinsn_queue_d;
  end

  /////////////////////
  //  Result queues  //
  /////////////////////

  typedef struct packed {
    vid_t   id;
    vaddr_t addr;
    elen_t  wdata;
    strb_t  be;
    logic   is_red;
  } payload_t;

  payload_t [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_d, result_queue_q;
  logic     [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_valid_d, result_queue_valid_q;
  logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_write_pnt_d, result_queue_write_pnt_q;
  logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_read_pnt_d, result_queue_read_pnt_q;
  logic     [idx_width(ResultQueueDepth):0]     result_queue_cnt_d, result_queue_cnt_q;
  logic     [NrLanes-1:0][2:0]                  final_gnt_pend_d, final_gnt_pend_q;

  logic result_queue_full, result_queue_empty;
  assign result_queue_full  = (result_queue_cnt_q == ResultQueueDepth);
  assign result_queue_empty = (result_queue_cnt_q == '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      result_queue_q           <= '0;
      result_queue_valid_q     <= '0;
      result_queue_write_pnt_q <= '0;
      result_queue_read_pnt_q  <= '0;
      result_queue_cnt_q       <= '0;
      final_gnt_pend_q         <= '0;
    end else begin
      result_queue_q           <= result_queue_d;
      result_queue_valid_q     <= result_queue_valid_d;
      result_queue_write_pnt_q <= result_queue_write_pnt_d;
      result_queue_read_pnt_q  <= result_queue_read_pnt_d;
      result_queue_cnt_q       <= result_queue_cnt_d;
      final_gnt_pend_q         <= final_gnt_pend_d;
    end
  end

  ////////////////////////////////////////////
  //  Input operand & mask staging buffers  //
  ////////////////////////////////////////////

  elen_t [NrLanes-1:0] sldu_operand;
  logic  [NrLanes-1:0] sldu_operand_valid;
  logic  [NrLanes-1:0] sldu_operand_ready;

  for (genvar l = 0; l < NrLanes; l++) begin : gen_in_spill
    spill_register #(
      .T(elen_t)
    ) i_sldu_spill_register (
      .clk_i  (clk_i                  ),
      .rst_ni (rst_ni                 ),
      .valid_i(sldu_operand_valid_i[l]),
      .ready_o(sldu_operand_ready_o[l]),
      .data_i (sldu_operand_i[l]      ),
      .valid_o(sldu_operand_valid[l]  ),
      .ready_i(sldu_operand_ready[l]  ),
      .data_o (sldu_operand[l]        )
    );
  end

  strb_t         [NrLanes-1:0] mask_buf_d, mask_buf_q;
  logic                        mask_buf_valid_d, mask_buf_valid_q;
  commit_beats_t               mask_rows_rem_d, mask_rows_rem_q;

  ///////////////////
  //  NP2 Support  //
  ///////////////////

  stride_t                                  p2_stride_gen_stride_d;
  logic                                     p2_stride_gen_valid_d;
  logic                                     p2_stride_gen_update_d;
  logic [idx_width(idx_width(RowBytes)):0]  p2_stride_gen_popc_q;
  stride_t                                  p2_stride_gen_stride_q;
  logic                                     p2_stride_gen_valid_q;

  p2_stride_gen #(
    .NrLanes (NrLanes)
  ) i_p2_stride_gen (
    .clk_i       (clk_i                 ),
    .rst_ni      (rst_ni                ),
    .stride_i    (p2_stride_gen_stride_d),
    .valid_i     (p2_stride_gen_valid_d ),
    .update_i    (p2_stride_gen_update_d),
    .popc_o      (p2_stride_gen_popc_q  ),
    .stride_p2_o (p2_stride_gen_stride_q),
    .valid_o     (p2_stride_gen_valid_q )
  );

  //////////////////
  //  Reductions  //
  //////////////////

  logic [idx_width(NrLanes)-1:0] red_stride_cnt_d, red_stride_cnt_q;
  logic [idx_width(NrLanes)-1:0] osum_lane_d, osum_lane_q;
  commit_beats_t                 red_steps_rem_d, red_steps_rem_q;

  logic is_issue_alu_reduction, is_issue_vmfpu_reduction;
  assign is_issue_alu_reduction   = vinsn_issue_valid_q & (vinsn_issue_q.vfu == VFU_Alu);
  assign is_issue_vmfpu_reduction = vinsn_issue_valid_q & (vinsn_issue_q.vfu == VFU_MFpu);

  always_comb begin
    sldu_mux_sel_o = NO_RED;
    if ((is_issue_alu_reduction && !(vinsn_commit_valid && vinsn_commit.vfu != VFU_Alu)) ||
        (vinsn_commit_valid && vinsn_commit.vfu == VFU_Alu)) begin
      sldu_mux_sel_o = ALU_RED;
    end else if ((is_issue_vmfpu_reduction && !(vinsn_commit_valid && vinsn_commit.vfu != VFU_MFpu)) ||
                 (vinsn_commit_valid && vinsn_commit.vfu == VFU_MFpu)) begin
      sldu_mux_sel_o = MFPU_RED;
    end
  end

  ///////////////////////
  //  State & Buffers  //
  ///////////////////////

  typedef enum logic [2:0] {
    SLIDE_IDLE,
    SLIDE_LOAD_ROW,
    SLIDE_P2_LOOP,
    SLIDE_EMIT,
    SLIDE_RED_UNORD,
    SLIDE_RED_OSUM
  } slide_state_e;

  slide_state_e state_d, state_q;

  elen_t         [NrLanes-1:0] work_buf_d, work_buf_q;
  elen_t         [NrLanes-1:0] row_acc_wdata_d, row_acc_wdata_q;
  strb_t         [NrLanes-1:0] row_acc_be_d, row_acc_be_q;
  logic          [NrVInsn-1:0] vinsn_running_d, vinsn_running_q;
  pe_resp_t                    pe_resp;

  logic [idx_width(RowBytes):0] in_pnt_d, in_pnt_q;
  logic [idx_width(RowBytes):0] out_pnt_d, out_pnt_q;
  vaddr_t                       vrf_pnt_d, vrf_pnt_q;
  byte_cnt_t                    src_rem_d, src_rem_q;
  byte_cnt_t                    dst_rem_d, dst_rem_q;
  stride_t                      intra_slamt_d, intra_slamt_q;
  logic                         sld_dir_d, sld_dir_q;
  logic                         first_word_d, first_word_q;
  commit_beats_t                commit_beats_d, commit_beats_q;

  /////////////////////
  //  SLDU DataPath  //
  /////////////////////

  elen_t                        [NrLanes-1:0] sld_op_src;
  elen_t                        [NrLanes-1:0] sld_op_dst;
  rvv_pkg::vew_e                              sld_eew_src;
  rvv_pkg::vew_e                              sld_eew_dst;
  logic                                       sld_dir;
  logic [idx_width(4*NrLanes):0]              sld_slamt;

  logic [idx_width(idx_width(RowBytes)):0]    intra_slamt_popc;
  always_comb begin
    intra_slamt_popc = '0;
    for (int b = 0; b < $bits(stride_t); b++) begin
      intra_slamt_popc += intra_slamt_q[b];
    end
  end

  // Dedicated combinational block for sldu_op_dp control (avoids false UNOPTFLAT loop)
  always_comb begin : p_dp_ctrl
    sld_op_src  = sldu_operand;
    sld_eew_src = vinsn_issue_q.vtype.vsew;
    sld_eew_dst = vinsn_issue_q.vtype.vsew;
    sld_dir     = 1'b0;
    sld_slamt   = '0;

    unique case (state_q)
      SLIDE_RED_UNORD: begin
        sld_op_src  = sldu_operand;
        sld_eew_src = rvv_pkg::EW64;
        sld_eew_dst = rvv_pkg::EW64;
        sld_dir     = 1'b1;
        sld_slamt   = {{($bits(sld_slamt)-$bits(red_stride_cnt_q)){1'b0}}, red_stride_cnt_q};
      end
      SLIDE_LOAD_ROW: begin
        sld_op_src  = sldu_operand;
        sld_eew_src = vinsn_issue_q.eew_vs2;
        sld_eew_dst = vinsn_issue_q.vtype.vsew;
        if ((vinsn_issue_q.eew_vs2 == vinsn_issue_q.vtype.vsew) && (intra_slamt_popc <= 1)) begin
          sld_slamt = intra_slamt_q;
          sld_dir   = (intra_slamt_q == '0) ? 1'b0 : sld_dir_q;
        end else begin
          sld_slamt = '0;
          sld_dir   = 1'b0;
        end
      end
      SLIDE_P2_LOOP: begin
        sld_op_src  = work_buf_q;
        sld_eew_src = vinsn_issue_q.vtype.vsew;
        sld_eew_dst = vinsn_issue_q.vtype.vsew;
        sld_slamt   = p2_stride_gen_stride_q;
        sld_dir     = sld_dir_q;
      end
      default: ;
    endcase
  end

  sldu_op_dp #(
    .NrLanes  (NrLanes    )
  ) i_sldu_op_dp (
    .op_i     (sld_op_src ),
    .slamt_i  (sld_slamt  ),
    .eew_src_i(sld_eew_src),
    .eew_dst_i(sld_eew_dst),
    .dir_i    (sld_dir    ),
    .op_o     (sld_op_dst )
  );

  //////////////////
  //  Slide unit  //
  //////////////////

  always_comb begin : p_sldu
    vinsn_queue_d            = vinsn_queue_q;
    state_d                  = state_q;
    work_buf_d               = work_buf_q;
    row_acc_wdata_d          = row_acc_wdata_q;
    row_acc_be_d             = row_acc_be_q;
    vinsn_running_d          = vinsn_running_q & pe_vinsn_running_i;

    in_pnt_d                 = in_pnt_q;
    out_pnt_d                = out_pnt_q;
    vrf_pnt_d                = vrf_pnt_q;
    src_rem_d                = src_rem_q;
    dst_rem_d                = dst_rem_q;
    intra_slamt_d            = intra_slamt_q;
    sld_dir_d                = sld_dir_q;
    first_word_d             = first_word_q;
    commit_beats_d           = commit_beats_q;

    result_queue_d           = result_queue_q;
    result_queue_valid_d     = result_queue_valid_q;
    result_queue_read_pnt_d  = result_queue_read_pnt_q;
    result_queue_write_pnt_d = result_queue_write_pnt_q;
    result_queue_cnt_d       = result_queue_cnt_q;
    final_gnt_pend_d         = final_gnt_pend_q;

    mask_buf_d               = mask_buf_q;
    mask_buf_valid_d         = mask_buf_valid_q;
    mask_rows_rem_d          = mask_rows_rem_q;
    mask_ready_o             = 1'b0;

    pe_resp                  = '0;
    sldu_operand_ready       = '0;
    pe_req_ready_o           = !vinsn_queue_full;

    red_stride_cnt_d         = red_stride_cnt_q;
    osum_lane_d              = osum_lane_q;
    red_steps_rem_d          = red_steps_rem_q;

    p2_stride_gen_stride_d   = '0;
    p2_stride_gen_valid_d    = 1'b0;
    p2_stride_gen_update_d   = 1'b0;

    /////////////////
    //  Slide FSM  //
    /////////////////

    unique case (state_q)
      SLIDE_IDLE: begin
        if (vinsn_issue_valid_q) begin
          automatic byte_cnt_t sew_b = byte_cnt_t'(1) << int'(vinsn_issue_q.vtype.vsew);
          automatic byte_cnt_t vl_b  = byte_cnt_t'(vinsn_issue_q.vl) << int'(vinsn_issue_q.vtype.vsew);

          row_acc_wdata_d = '0;
          row_acc_be_d    = '0;
          first_word_d    = 1'b0;
          mask_rows_rem_d = '0;

          if (vinsn_issue_q.vfu inside {VFU_Alu, VFU_MFpu}) begin
            if (vinsn_issue_q.op inside {VFREDOSUM, VFWREDOSUM}) begin
              if (vinsn_issue_q.vl == '0) begin
                vinsn_queue_d.issue_pnt += 1'b1;
                vinsn_queue_d.issue_cnt -= 1'b1;
              end else begin
                red_steps_rem_d = commit_beats_t'(vinsn_issue_q.vl);
                osum_lane_d     = '0;
                state_d         = SLIDE_RED_OSUM;
              end
            end else begin
              red_steps_rem_d  = commit_beats_t'($clog2(NrLanes) + 1);
              red_stride_cnt_d = 1;
              state_d          = SLIDE_RED_UNORD;
            end
          end else if (vinsn_issue_q.op == VSLIDEUP) begin
            if (!vinsn_issue_q.use_scalar_op) begin
              if ((vinsn_issue_q.vl == '0) ||
                  stride_ge_limit(vinsn_issue_q.stride, byte_cnt_t'(vinsn_issue_q.vl))) begin
                vinsn_queue_d.issue_pnt += 1'b1;
                vinsn_queue_d.issue_cnt -= 1'b1;
              end else begin
                automatic byte_cnt_t st_b = byte_cnt_t'(vinsn_issue_q.stride[$bits(byte_cnt_t)-1:0]) << int'(vinsn_issue_q.vtype.vsew);
                vrf_pnt_d       = vaddr_t'(st_b >> RowIdxW);
                in_pnt_d        = '0;
                out_pnt_d       = st_b[RowIdxW-1:0];
                src_rem_d       = vl_b - st_b;
                dst_rem_d       = vl_b - st_b;
                intra_slamt_d   = stride_t'(st_b[RowIdxW-1:0] >> int'(vinsn_issue_q.vtype.vsew));
                sld_dir_d       = 1'b1;
                mask_rows_rem_d = vinsn_issue_q.vm ? '0 : calc_commit_beats(vinsn_issue_q);
                state_d         = SLIDE_LOAD_ROW;
              end
            end else begin
              if (vinsn_issue_q.vl == '0) begin
                vinsn_queue_d.issue_pnt += 1'b1;
                vinsn_queue_d.issue_cnt -= 1'b1;
              end else if (vinsn_issue_q.vl == 1) begin
                vrf_pnt_d       = '0;
                in_pnt_d        = '0;
                out_pnt_d       = sew_b[RowIdxW:0];
                src_rem_d       = '0;
                dst_rem_d       = '0;
                first_word_d    = 1'b1;
                intra_slamt_d   = '0;
                sld_dir_d       = 1'b1;
                mask_rows_rem_d = vinsn_issue_q.vm ? '0 : commit_beats_t'(1);
                state_d         = SLIDE_EMIT;
              end else begin
                vrf_pnt_d       = '0;
                in_pnt_d        = '0;
                out_pnt_d       = sew_b[RowIdxW:0];
                src_rem_d       = vl_b - sew_b;
                dst_rem_d       = vl_b - sew_b;
                first_word_d    = 1'b1;
                intra_slamt_d   = stride_t'(1);
                sld_dir_d       = 1'b1;
                mask_rows_rem_d = vinsn_issue_q.vm ? '0 : calc_commit_beats(vinsn_issue_q);
                state_d         = SLIDE_LOAD_ROW;
              end
            end
          end else begin
            // VSLIDEDOWN / VSLIDE1DOWN
            if (vinsn_issue_q.vl == '0) begin
              vinsn_queue_d.issue_pnt += 1'b1;
              vinsn_queue_d.issue_cnt -= 1'b1;
            end else if (vinsn_issue_q.use_scalar_op) begin
              vrf_pnt_d       = '0;
              out_pnt_d       = '0;
              dst_rem_d       = vl_b;
              sld_dir_d       = 1'b0;
              mask_rows_rem_d = vinsn_issue_q.vm ? '0 : calc_commit_beats(vinsn_issue_q);
              if (vinsn_issue_q.vl == 1) begin
                in_pnt_d      = '0;
                src_rem_d     = '0;
                intra_slamt_d = '0;
                state_d       = SLIDE_EMIT;
              end else begin
                in_pnt_d      = sew_b[RowIdxW:0];
                src_rem_d     = vl_b - sew_b;
                intra_slamt_d = stride_t'(1);
                state_d       = SLIDE_LOAD_ROW;
              end
            end else begin
              automatic byte_cnt_t vlmax_b  = calc_vlmax_bytes(vinsn_issue_q.vtype.vlmul);
              automatic byte_cnt_t vlmax_el = vlmax_b >> int'(vinsn_issue_q.vtype.vsew);
              vrf_pnt_d       = '0;
              out_pnt_d       = '0;
              dst_rem_d       = vl_b;
              sld_dir_d       = 1'b0;
              mask_rows_rem_d = vinsn_issue_q.vm ? '0 : calc_commit_beats(vinsn_issue_q);
              if (stride_ge_limit(vinsn_issue_q.stride, vlmax_el)) begin
                in_pnt_d      = '0;
                src_rem_d     = '0;
                intra_slamt_d = '0;
                state_d       = SLIDE_EMIT;
              end else begin
                automatic byte_cnt_t st_b    = byte_cnt_t'(vinsn_issue_q.stride[$bits(byte_cnt_t)-1:0]) << int'(vinsn_issue_q.vtype.vsew);
                automatic byte_cnt_t avail_b = vlmax_b - st_b;
                in_pnt_d      = st_b[RowIdxW-1:0];
                src_rem_d     = (vl_b <= avail_b) ? vl_b : avail_b;
                intra_slamt_d = stride_t'(st_b[RowIdxW-1:0] >> int'(vinsn_issue_q.vtype.vsew));
                state_d       = (src_rem_d == '0) ? SLIDE_EMIT : SLIDE_LOAD_ROW;
              end
            end
          end
        end
      end

      SLIDE_LOAD_ROW: begin
        if (&sldu_operand_valid) begin
          sldu_operand_ready = '1;
          work_buf_d         = sld_op_dst;
          if (((vinsn_issue_q.eew_vs2 == vinsn_issue_q.vtype.vsew) && (intra_slamt_popc <= 1)) ||
              (intra_slamt_q == '0)) begin
            state_d = SLIDE_EMIT;
          end else begin
            p2_stride_gen_stride_d = intra_slamt_q;
            p2_stride_gen_valid_d  = 1'b1;
            state_d                = SLIDE_P2_LOOP;
          end
        end
      end

      SLIDE_P2_LOOP: begin
        if (p2_stride_gen_valid_q) begin
          work_buf_d             = sld_op_dst;
          p2_stride_gen_update_d = 1'b1;
          if (p2_stride_gen_popc_q == {{($bits(p2_stride_gen_popc_q)-1){1'b0}}, 1'b1}) begin
            state_d = SLIDE_EMIT;
          end
        end
      end

      SLIDE_EMIT: begin
        automatic int unsigned in_avail  = RowBytes - int'(in_pnt_q);
        automatic int unsigned out_avail = RowBytes - int'(out_pnt_q);
        automatic int unsigned sew_b     = 1 << int'(vinsn_issue_q.vtype.vsew);
        automatic elen_t [NrLanes-1:0] acc_wdata = row_acc_wdata_q;
        automatic strb_t [NrLanes-1:0] acc_be    = row_acc_be_q;

        if ((src_rem_q != '0) && (int'(src_rem_q) > in_avail) && (in_avail < out_avail)) begin
          // Partial row accumulation: current source row finishes before destination row fills
          for (int unsigned b = 0; b < RowBytes; b++) begin
            if ((b >= int'(out_pnt_q)) && (b < (int'(out_pnt_q) + in_avail))) begin
              automatic int unsigned shuf_b = shuffle_index(16'(b), NrLanes, vinsn_issue_q.vtype.vsew);
              automatic int unsigned ln     = shuf_b >> 3;
              automatic int unsigned off    = shuf_b[2:0];
              acc_wdata[ln][8*off +: 8] = work_buf_q[ln][8*off +: 8];
              acc_be[ln][off]           = 1'b1;
            end
          end
          row_acc_wdata_d = acc_wdata;
          row_acc_be_d    = acc_be;
          in_pnt_d        = '0;
          out_pnt_d       = out_pnt_q + in_avail[RowIdxW:0];
          src_rem_d       = src_rem_q - byte_cnt_t'(in_avail);
          dst_rem_d       = dst_rem_q - byte_cnt_t'(in_avail);
          state_d         = SLIDE_LOAD_ROW;
        end else if (!result_queue_full && (vinsn_issue_q.vm || mask_buf_valid_q)) begin
          // Destination row completes on this cycle
          automatic int unsigned src_step  = (int'(src_rem_q) < out_avail) ? int'(src_rem_q) : out_avail;
          automatic int unsigned mid_pnt   = int'(out_pnt_q) + src_step;
          automatic int unsigned rem_after = int'(dst_rem_q) - src_step;
          automatic int unsigned zero_step = (rem_after < (RowBytes - mid_pnt)) ? rem_after : (RowBytes - mid_pnt);
          automatic int unsigned end_pnt   = mid_pnt + zero_step;

          for (int unsigned b = 0; b < RowBytes; b++) begin
            automatic int unsigned shuf_b = shuffle_index(16'(b), NrLanes, vinsn_issue_q.vtype.vsew);
            automatic int unsigned ln     = shuf_b >> 3;
            automatic int unsigned off    = shuf_b[2:0];
            if ((b >= int'(out_pnt_q)) && (b < mid_pnt)) begin
              acc_wdata[ln][8*off +: 8] = work_buf_q[ln][8*off +: 8];
              acc_be[ln][off]           = 1'b1;
            end else if ((b >= mid_pnt) && (b < end_pnt)) begin
              acc_wdata[ln][8*off +: 8] = 8'h00;
              acc_be[ln][off]           = 1'b1;
            end
          end

          // VSLIDE1UP first element from scalar_op
          if (first_word_q) begin
            for (int unsigned k = 0; k < 8; k++) begin
              if (k < sew_b) begin
                automatic int unsigned shuf_k = shuffle_index(16'(k), NrLanes, vinsn_issue_q.vtype.vsew);
                acc_wdata[shuf_k >> 3][8*shuf_k[2:0] +: 8] = vinsn_issue_q.scalar_op[8*k +: 8];
                acc_be[shuf_k >> 3][shuf_k[2:0]]           = 1'b1;
              end
            end
            first_word_d = 1'b0;
          end

          // VSLIDE1DOWN final element from scalar_op
          if ((vinsn_issue_q.op == VSLIDEDOWN) && vinsn_issue_q.use_scalar_op &&
              ((src_step + zero_step) == int'(dst_rem_q))) begin
            for (int unsigned k = 0; k < 8; k++) begin
              if (k < sew_b) begin
                automatic int unsigned seq_k  = (end_pnt - sew_b) + k;
                automatic int unsigned shuf_k = shuffle_index(16'(seq_k), NrLanes, vinsn_issue_q.vtype.vsew);
                acc_wdata[shuf_k >> 3][8*shuf_k[2:0] +: 8] = vinsn_issue_q.scalar_op[8*k +: 8];
                acc_be[shuf_k >> 3][shuf_k[2:0]]           = 1'b1;
              end
            end
          end

          if (!vinsn_issue_q.vm) begin
            acc_be           = acc_be & mask_buf_q;
            mask_buf_valid_d = 1'b0;
          end

          for (int lane = 0; lane < NrLanes; lane++) begin
            result_queue_d[result_queue_write_pnt_q][lane] = '{
              id    : vinsn_issue_q.id,
              addr  : vaddr(vinsn_issue_q.vd, NrLanes, VLEN) + vrf_pnt_q,
              wdata : acc_wdata[lane],
              be    : acc_be[lane],
              is_red: 1'b0
            };
          end
          result_queue_valid_d[result_queue_write_pnt_q] = '1;
          result_queue_cnt_d                             = result_queue_cnt_q + 1'b1;
          result_queue_write_pnt_d                       = (result_queue_write_pnt_q == ResultQueueDepth-1)
                                                         ? '0 : (result_queue_write_pnt_q + 1'b1);

          row_acc_wdata_d = '0;
          row_acc_be_d    = '0;
          vrf_pnt_d       = vrf_pnt_q + 1'b1;
          out_pnt_d       = '0;
          src_rem_d       = src_rem_q - byte_cnt_t'(src_step);
          dst_rem_d       = dst_rem_q - byte_cnt_t'(src_step + zero_step);

          if (dst_rem_d == '0) begin
            in_pnt_d                 = '0;
            vinsn_queue_d.issue_pnt += 1'b1;
            vinsn_queue_d.issue_cnt -= 1'b1;
            state_d                  = SLIDE_IDLE;
          end else if (src_rem_d == '0) begin
            in_pnt_d = '0;
            state_d  = SLIDE_EMIT;
          end else if ((int'(in_pnt_q) + src_step) == RowBytes) begin
            in_pnt_d = '0;
            state_d  = SLIDE_LOAD_ROW;
          end else begin
            in_pnt_d = in_pnt_q + src_step[RowIdxW:0];
            state_d  = SLIDE_EMIT;
          end
        end
      end

      SLIDE_RED_UNORD: begin
        if ((&sldu_operand_valid) && !result_queue_full) begin
          automatic logic [idx_width(NrLanes):0] red_rot_wide;
          sldu_operand_ready = '1;
          for (int lane = 0; lane < NrLanes; lane++) begin
            result_queue_d[result_queue_write_pnt_q][lane] = '{
              id    : vinsn_issue_q.id,
              addr  : '0,
              wdata : sld_op_dst[lane],
              be    : '1,
              is_red: 1'b1
            };
          end
          result_queue_valid_d[result_queue_write_pnt_q] = '1;
          result_queue_cnt_d                             = result_queue_cnt_q + 1'b1;
          result_queue_write_pnt_d                       = (result_queue_write_pnt_q == ResultQueueDepth-1)
                                                         ? '0 : (result_queue_write_pnt_q + 1'b1);

          red_rot_wide     = {red_stride_cnt_q, red_stride_cnt_q[idx_width(NrLanes)-1]};
          red_stride_cnt_d = red_rot_wide[idx_width(NrLanes)-1:0];

          if (red_steps_rem_q <= commit_beats_t'(1)) begin
            red_steps_rem_d          = '0;
            red_stride_cnt_d         = 1;
            vinsn_queue_d.issue_pnt += 1'b1;
            vinsn_queue_d.issue_cnt -= 1'b1;
            state_d                  = SLIDE_IDLE;
          end else begin
            red_steps_rem_d = red_steps_rem_q - 1'b1;
          end
        end
      end

      SLIDE_RED_OSUM: begin
        if (!result_queue_full && sldu_operand_valid[osum_lane_q]) begin
          automatic int unsigned src_ln = int'(osum_lane_q);
          automatic int unsigned tgt_ln = (red_steps_rem_q == commit_beats_t'(1))
                                        ? 0
                                        : ((src_ln == (NrLanes - 1)) ? 0 : (src_ln + 1));

          sldu_operand_ready[src_ln] = 1'b1;
          for (int lane = 0; lane < NrLanes; lane++) begin
            result_queue_d[result_queue_write_pnt_q][lane] = '{
              id    : vinsn_issue_q.id,
              addr  : '0,
              wdata : (lane == tgt_ln) ? sldu_operand[src_ln] : '0,
              be    : '1,
              is_red: 1'b1
            };
          end
          result_queue_valid_d[result_queue_write_pnt_q]         = '0;
          result_queue_valid_d[result_queue_write_pnt_q][tgt_ln] = 1'b1;
          result_queue_cnt_d                                     = result_queue_cnt_q + 1'b1;
          result_queue_write_pnt_d                               = (result_queue_write_pnt_q == ResultQueueDepth-1)
                                                                 ? '0 : (result_queue_write_pnt_q + 1'b1);

          osum_lane_d = (src_ln == (NrLanes - 1)) ? '0 : (osum_lane_q + 1'b1);
          if (red_steps_rem_q <= commit_beats_t'(1)) begin
            red_steps_rem_d          = '0;
            osum_lane_d              = '0;
            vinsn_queue_d.issue_pnt += 1'b1;
            vinsn_queue_d.issue_cnt -= 1'b1;
            state_d                  = SLIDE_IDLE;
          end else begin
            red_steps_rem_d = red_steps_rem_q - 1'b1;
          end
        end
      end

      default: state_d = SLIDE_IDLE;
    endcase

    ////////////////////////////////////////////
    //  Exact per-row mask beat intake        //
    ////////////////////////////////////////////

    if (!mask_buf_valid_d && (mask_rows_rem_d != '0) && (|mask_valid_i)) begin
      mask_ready_o     = 1'b1;
      mask_buf_d       = mask_i;
      mask_buf_valid_d = 1'b1;
      mask_rows_rem_d  = mask_rows_rem_d - 1'b1;
    end

    //////////////////////////////////
    //  Write results into the VRF  //
    //////////////////////////////////

    begin
      automatic logic head_matches_commit;
      automatic logic all_final_gnts_done;

      head_matches_commit = 1'b0;
      if (vinsn_commit_valid && !result_queue_empty && (commit_beats_q != '0)) begin
        for (int lane = 0; lane < NrLanes; lane++) begin
          if (result_queue_valid_q[result_queue_read_pnt_q][lane] &&
              (result_queue_q[result_queue_read_pnt_q][lane].id == vinsn_commit.id)) begin
            head_matches_commit = 1'b1;
          end
        end
      end

      for (int lane = 0; lane < NrLanes; lane++) begin
        automatic logic lane_vld = head_matches_commit & result_queue_valid_q[result_queue_read_pnt_q][lane];
        automatic logic lane_red = result_queue_q[result_queue_read_pnt_q][lane].is_red;

        sldu_result_req_o[lane]   = lane_vld & ~lane_red;
        sldu_red_valid_o[lane]    = lane_vld &  lane_red;
        sldu_result_addr_o[lane]  = result_queue_q[result_queue_read_pnt_q][lane].addr;
        sldu_result_id_o[lane]    = result_queue_q[result_queue_read_pnt_q][lane].id;
        sldu_result_wdata_o[lane] = result_queue_q[result_queue_read_pnt_q][lane].wdata;
        sldu_result_be_o[lane]    = result_queue_q[result_queue_read_pnt_q][lane].be;

        if ((sldu_result_req_o[lane] || sldu_red_valid_o[lane]) && sldu_result_gnt_i[lane]) begin
          result_queue_valid_d[result_queue_read_pnt_q][lane] = 1'b0;
          result_queue_d[result_queue_read_pnt_q][lane]       = '0;
        end
      end

      all_final_gnts_done = 1'b1;
      for (int lane = 0; lane < NrLanes; lane++) begin
        automatic logic inc_fg = sldu_result_req_o[lane] & sldu_result_gnt_i[lane];
        automatic logic dec_fg = sldu_result_final_gnt_i[lane];
        if (inc_fg && !dec_fg) begin
          final_gnt_pend_d[lane] = final_gnt_pend_q[lane] + 3'd1;
        end else if (!inc_fg && dec_fg && (final_gnt_pend_q[lane] != '0)) begin
          final_gnt_pend_d[lane] = final_gnt_pend_q[lane] - 3'd1;
        end
        if (final_gnt_pend_d[lane] != '0) begin
          all_final_gnts_done = 1'b0;
        end
      end

      if (head_matches_commit && !(|result_queue_valid_d[result_queue_read_pnt_q])) begin
        result_queue_read_pnt_d = (result_queue_read_pnt_q == ResultQueueDepth-1)
                                ? '0 : (result_queue_read_pnt_q + 1'b1);
        result_queue_cnt_d      -= 1'b1;
        commit_beats_d          = commit_beats_q - 1'b1;
      end

      if (vinsn_commit_valid && (commit_beats_d == '0) &&
          ((vinsn_commit.vfu inside {VFU_Alu, VFU_MFpu}) || all_final_gnts_done)) begin
        pe_resp.vinsn_done[vinsn_commit.id] = 1'b1;
        vinsn_queue_d.commit_cnt -= 1'b1;
        vinsn_queue_d.commit_pnt = (vinsn_queue_q.commit_pnt == VInsnQueueDepth-1)
                                 ? '0 : (vinsn_queue_q.commit_pnt + 1'b1);
        if (vinsn_queue_d.commit_cnt != '0) begin
          commit_beats_d = vinsn_queue_q.beats[vinsn_queue_d.commit_pnt];
        end
      end
    end

    //////////////////////////////
    //  Accept new instruction  //
    //////////////////////////////

    if (!vinsn_queue_full && pe_req_valid_i && !vinsn_running_q[pe_req_i.id] &&
        ((pe_req_i.vfu == VFU_SlideUnit) ||
         (pe_req_i.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}))) begin
      automatic pe_req_t       accepted_req   = pe_req_i;
      automatic commit_beats_t accepted_beats = calc_commit_beats(pe_req_i);

      if (pe_req_i.vfu inside {VFU_Alu, VFU_MFpu}) begin
        accepted_req.vtype.vsew = rvv_pkg::EW64;
      end

      vinsn_queue_d.vinsn[vinsn_queue_q.accept_pnt] = accepted_req;
      vinsn_queue_d.beats[vinsn_queue_q.accept_pnt] = accepted_beats;
      vinsn_running_d[pe_req_i.id]                  = 1'b1;

      if (vinsn_queue_d.commit_cnt == '0) begin
        commit_beats_d = accepted_beats;
      end

      vinsn_queue_d.accept_pnt = (vinsn_queue_q.accept_pnt == VInsnQueueDepth-1)
                               ? '0 : (vinsn_queue_q.accept_pnt + 1'b1);
      vinsn_queue_d.issue_cnt  += 1'b1;
      vinsn_queue_d.commit_cnt += 1'b1;
    end
  end : p_sldu

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q            <= SLIDE_IDLE;
      work_buf_q         <= '0;
      row_acc_wdata_q    <= '0;
      row_acc_be_q       <= '0;
      vinsn_running_q    <= '0;
      in_pnt_q           <= '0;
      out_pnt_q          <= '0;
      vrf_pnt_q          <= '0;
      src_rem_q          <= '0;
      dst_rem_q          <= '0;
      intra_slamt_q      <= '0;
      sld_dir_q          <= 1'b0;
      first_word_q       <= 1'b0;
      commit_beats_q     <= '0;
      mask_buf_q         <= '0;
      mask_buf_valid_q   <= 1'b0;
      mask_rows_rem_q    <= '0;
      red_stride_cnt_q   <= 1;
      osum_lane_q        <= '0;
      red_steps_rem_q    <= '0;
      pe_resp_o          <= '0;
    end else begin
      state_q            <= state_d;
      work_buf_q         <= work_buf_d;
      row_acc_wdata_q    <= row_acc_wdata_d;
      row_acc_be_q       <= row_acc_be_d;
      vinsn_running_q    <= vinsn_running_d;
      in_pnt_q           <= in_pnt_d;
      out_pnt_q          <= out_pnt_d;
      vrf_pnt_q          <= vrf_pnt_d;
      src_rem_q          <= src_rem_d;
      dst_rem_q          <= dst_rem_d;
      intra_slamt_q      <= intra_slamt_d;
      sld_dir_q          <= sld_dir_d;
      first_word_q       <= first_word_d;
      commit_beats_q     <= commit_beats_d;
      mask_buf_q         <= mask_buf_d;
      mask_buf_valid_q   <= mask_buf_valid_d;
      mask_rows_rem_q    <= mask_rows_rem_d;
      red_stride_cnt_q   <= red_stride_cnt_d;
      osum_lane_q        <= osum_lane_d;
      red_steps_rem_q    <= red_steps_rem_d;
      pe_resp_o          <= pe_resp;
    end
  end

endmodule : sldu
