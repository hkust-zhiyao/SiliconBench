// Copyright 2021-2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Alternate Gold Architecture for Ara's Slide and Inter-Lane Reduction Unit:
// - Explicit per-lane beat-counted single-stage operand intake registers (no `spill_register`)
// - Dedicated multi-stage FSM (`ALT_FETCH_OP`, `ALT_RESHUFFLE`, `ALT_NP2_STEP`,
//   `ALT_WRITE_SLIDE`, `ALT_ZERO_TAIL`, `ALT_SCALAR_ONLY`, `ALT_RED_TREE`, `ALT_RED_ORD`)
// - Per-instruction pre-decoded metadata table in the vector instruction queue

module sldu import ara_pkg::*; import rvv_pkg::*; #(
    parameter  int  unsigned NrLanes   = 0,
    parameter  int  unsigned VLEN      = 0,
    parameter  type          vaddr_t   = logic,
    parameter  type          pe_req_t  = logic,
    parameter  type          pe_resp_t = logic,
    localparam int  unsigned DataWidth = $bits(elen_t),
    localparam int  unsigned StrbWidth = DataWidth/8,
    localparam type          strb_t    = logic [StrbWidth-1:0],
    localparam type          vlen_t    = logic[$clog2(VLEN+1)-1:0]
  ) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  pe_req_t                pe_req_i,
    input  logic                   pe_req_valid_i,
    input  logic     [NrVInsn-1:0] pe_vinsn_running_i,
    output logic                   pe_req_ready_o,
    output pe_resp_t               pe_resp_o,
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
    output sldu_mux_e              sldu_mux_sel_o,
    output logic     [NrLanes-1:0] sldu_red_valid_o,
    input  strb_t    [NrLanes-1:0] mask_i,
    input  logic     [NrLanes-1:0] mask_valid_i,
    output logic                   mask_ready_o
  );

  import cf_math_pkg::idx_width;

  localparam int unsigned RowBytes         = 8 * NrLanes;
  localparam int unsigned RowShift         = $clog2(RowBytes);
  localparam int unsigned VInsnQueueDepth  = SlduInsnQueueDepth;
  localparam int unsigned ResultQueueDepth = 2;
  localparam int unsigned VLenB            = VLEN / 8;

  typedef logic [$clog2(VLEN+1):0]        cnt_t;
  typedef logic [$clog2(4*VLEN+1):0]      stream_cnt_t;
  typedef logic [idx_width(RowBytes)-1:0] stride_t;

  typedef struct packed {
    logic                 is_null;
    logic                 need_reshuf;
    logic                 is_np2_intra;
    stride_t              intra_slamt;
    logic                 dir_up;
    logic [RowShift:0]    init_in_pnt;
    logic [RowShift:0]    init_out_pnt;
    vaddr_t               init_vrf_pnt;
    cnt_t                 init_src_rem;
    cnt_t                 init_dst_rem;
    cnt_t                 commit_beats;
  } dec_meta_t;

  function automatic cnt_t get_vlmax_bytes(rvv_pkg::vlmul_e lmul);
    unique case (lmul)
      rvv_pkg::LMUL_1  : return cnt_t'(VLenB);
      rvv_pkg::LMUL_2  : return cnt_t'(VLenB << 1);
      rvv_pkg::LMUL_4  : return cnt_t'(VLenB << 2);
      rvv_pkg::LMUL_8  : return cnt_t'(VLenB << 3);
      rvv_pkg::LMUL_1_2: return cnt_t'(VLenB >> 1);
      rvv_pkg::LMUL_1_4: return cnt_t'(VLenB >> 2);
      rvv_pkg::LMUL_1_8: return cnt_t'(VLenB >> 3);
      default          : return cnt_t'(VLenB);
    endcase
  endfunction

  function automatic logic has_multi_bits(stride_t v);
    return (v != '0) && ((v & (v - 1'b1)) != '0);
  endfunction

  // Vector instruction queue with pre-decoded geometry
  struct packed {
    pe_req_t   [VInsnQueueDepth-1:0] vinsn;
    dec_meta_t [VInsnQueueDepth-1:0] meta;
    logic [idx_width(VInsnQueueDepth)-1:0] accept_pnt;
    logic [idx_width(VInsnQueueDepth)-1:0] issue_pnt;
    logic [idx_width(VInsnQueueDepth)-1:0] commit_pnt;
    logic [idx_width(VInsnQueueDepth):0]   issue_cnt;
    logic [idx_width(VInsnQueueDepth):0]   commit_cnt;
  } vq_d, vq_q;

  pe_req_t   issue_req_q;
  dec_meta_t issue_meta_q;
  logic      issue_valid_q;
  logic      vq_full;

  assign vq_full = (vq_q.commit_cnt == VInsnQueueDepth);

  pe_req_t commit_req;
  logic    commit_valid;
  assign commit_req   = vq_q.vinsn[vq_q.commit_pnt];
  assign commit_valid = (vq_q.commit_cnt != '0);

  // Beat-counted 1-entry per-lane operand registers & mask register
  elen_t       [NrLanes-1:0] op_reg_d, op_reg_q;
  logic        [NrLanes-1:0] op_vld_d, op_vld_q;
  logic        [NrLanes-1:0] op_pop;
  stream_cnt_t [NrLanes-1:0] op_rem_d, op_rem_q;

  strb_t       [NrLanes-1:0] msk_reg_d, msk_reg_q;
  logic                      msk_vld_d, msk_vld_q;
  logic                      msk_pop;
  stream_cnt_t               msk_rem_d, msk_rem_q;

  // 2-entry result FIFO
  typedef struct packed {
    vid_t   id;
    vaddr_t addr;
    elen_t  wdata;
    strb_t  be;
    logic   is_red;
  } res_entry_t;

  res_entry_t [ResultQueueDepth-1:0][NrLanes-1:0] rq_d, rq_q;
  logic       [ResultQueueDepth-1:0][NrLanes-1:0] rq_vld_d, rq_vld_q;
  logic       [idx_width(ResultQueueDepth)-1:0]   rq_wpnt_d, rq_wpnt_q;
  logic       [idx_width(ResultQueueDepth)-1:0]   rq_rpnt_d, rq_rpnt_q;
  logic       [idx_width(ResultQueueDepth):0]     rq_cnt_d, rq_cnt_q;
  logic       [NrLanes-1:0][2:0]                  fgnt_cnt_d, fgnt_cnt_q;

  logic rq_full, rq_empty;
  assign rq_full  = (rq_cnt_q == ResultQueueDepth);
  assign rq_empty = (rq_cnt_q == '0);

  stride_t                                 p2_stride_d;
  logic                                    p2_valid_d;
  logic                                    p2_update_d;
  logic [idx_width(idx_width(RowBytes)):0] p2_popc_q;
  stride_t                                 p2_step_q;
  logic                                    p2_valid_q;

  p2_stride_gen #(
    .NrLanes(NrLanes)
  ) i_p2_stride_gen (
    .clk_i      (clk_i      ),
    .rst_ni     (rst_ni     ),
    .stride_i   (p2_stride_d),
    .valid_i    (p2_valid_d ),
    .update_i   (p2_update_d),
    .popc_o     (p2_popc_q  ),
    .stride_p2_o(p2_step_q  ),
    .valid_o    (p2_valid_q )
  );

  always_comb begin
    sldu_mux_sel_o = NO_RED;
    if (((issue_valid_q && (issue_req_q.vfu == VFU_Alu)) && !(commit_valid && (commit_req.vfu != VFU_Alu))) ||
        (commit_valid && (commit_req.vfu == VFU_Alu))) begin
      sldu_mux_sel_o = ALU_RED;
    end else if (((issue_valid_q && (issue_req_q.vfu == VFU_MFpu)) && !(commit_valid && (commit_req.vfu != VFU_MFpu))) ||
                 (commit_valid && (commit_req.vfu == VFU_MFpu))) begin
      sldu_mux_sel_o = MFPU_RED;
    end
  end

  typedef enum logic [3:0] {
    ALT_IDLE,
    ALT_FETCH_OP,
    ALT_RESHUFFLE,
    ALT_NP2_STEP,
    ALT_WRITE_SLIDE,
    ALT_ZERO_TAIL,
    ALT_SCALAR_ONLY,
    ALT_RED_TREE,
    ALT_RED_ORD
  } alt_state_e;

  alt_state_e                    st_d, st_q;
  elen_t      [NrLanes-1:0]      stage_buf_d, stage_buf_q;
  elen_t      [NrLanes-1:0]      part_wdata_d, part_wdata_q;
  strb_t      [NrLanes-1:0]      part_be_d, part_be_q;
  logic       [NrVInsn-1:0]      running_d, running_q;
  pe_resp_t                      pe_resp;

  logic       [RowShift:0]       in_pnt_d, in_pnt_q;
  logic       [RowShift:0]       out_pnt_d, out_pnt_q;
  vaddr_t                        vrf_pnt_d, vrf_pnt_q;
  cnt_t                          src_rem_d, src_rem_q;
  cnt_t                          dst_rem_d, dst_rem_q;
  logic                          first_elem_d, first_elem_q;
  cnt_t                          cbeats_d, cbeats_q;
  logic [idx_width(NrLanes)-1:0] red_rot_d, red_rot_q;
  logic [idx_width(NrLanes)-1:0] ord_ln_d, ord_ln_q;
  cnt_t                          red_rem_d, red_rem_q;

  elen_t                        [NrLanes-1:0] dp_src;
  elen_t                        [NrLanes-1:0] dp_dst;
  rvv_pkg::vew_e                              dp_eew_src;
  rvv_pkg::vew_e                              dp_eew_dst;
  logic                                       dp_dir;
  logic [idx_width(4*NrLanes):0]              dp_slamt;

  always_comb begin : p_alt_dp_ctrl
    dp_src     = op_reg_q;
    dp_eew_src = issue_req_q.vtype.vsew;
    dp_eew_dst = issue_req_q.vtype.vsew;
    dp_dir     = 1'b0;
    dp_slamt   = '0;

    unique case (st_q)
      ALT_FETCH_OP: begin
        dp_src     = op_reg_q;
        dp_eew_src = issue_req_q.vtype.vsew;
        dp_eew_dst = issue_req_q.vtype.vsew;
        if (!issue_meta_q.need_reshuf && !issue_meta_q.is_np2_intra) begin
          dp_slamt = issue_meta_q.intra_slamt;
          dp_dir   = (issue_meta_q.intra_slamt == '0) ? 1'b0 : issue_meta_q.dir_up;
        end
      end
      ALT_RESHUFFLE: begin
        dp_src     = stage_buf_q;
        dp_eew_src = issue_req_q.eew_vs2;
        dp_eew_dst = issue_req_q.vtype.vsew;
        dp_slamt   = '0;
        dp_dir     = 1'b0;
      end
      ALT_NP2_STEP: begin
        dp_src     = stage_buf_q;
        dp_eew_src = issue_req_q.vtype.vsew;
        dp_eew_dst = issue_req_q.vtype.vsew;
        dp_slamt   = p2_step_q;
        dp_dir     = issue_meta_q.dir_up;
      end
      ALT_RED_TREE: begin
        dp_src     = op_reg_q;
        dp_eew_src = rvv_pkg::EW64;
        dp_eew_dst = rvv_pkg::EW64;
        dp_slamt   = {{($bits(dp_slamt)-$bits(red_rot_q)){1'b0}}, red_rot_q};
        dp_dir     = 1'b1;
      end
      default: ;
    endcase
  end

  sldu_op_dp #(
    .NrLanes  (NrLanes   )
  ) i_sldu_op_dp (
    .op_i     (dp_src    ),
    .slamt_i  (dp_slamt  ),
    .eew_src_i(dp_eew_src),
    .eew_dst_i(dp_eew_dst),
    .dir_i    (dp_dir    ),
    .op_o     (dp_dst    )
  );

  always_comb begin : p_alt_fsm
    vq_d          = vq_q;
    st_d          = st_q;
    stage_buf_d   = stage_buf_q;
    part_wdata_d  = part_wdata_q;
    part_be_d     = part_be_q;
    running_d     = running_q & pe_vinsn_running_i;

    in_pnt_d      = in_pnt_q;
    out_pnt_d     = out_pnt_q;
    vrf_pnt_d     = vrf_pnt_q;
    src_rem_d     = src_rem_q;
    dst_rem_d     = dst_rem_q;
    first_elem_d  = first_elem_q;
    cbeats_d      = cbeats_q;
    red_rot_d     = red_rot_q;
    ord_ln_d      = ord_ln_q;
    red_rem_d     = red_rem_q;

    rq_d          = rq_q;
    rq_vld_d      = rq_vld_q;
    rq_wpnt_d     = rq_wpnt_q;
    rq_rpnt_d     = rq_rpnt_q;
    rq_cnt_d      = rq_cnt_q;
    fgnt_cnt_d    = fgnt_cnt_q;

    op_reg_d      = op_reg_q;
    op_vld_d      = op_vld_q;
    op_pop        = '0;
    op_rem_d      = op_rem_q;

    msk_reg_d     = msk_reg_q;
    msk_vld_d     = msk_vld_q;
    msk_pop       = 1'b0;
    msk_rem_d     = msk_rem_q;

    pe_resp        = '0;
    pe_req_ready_o = !vq_full;

    p2_stride_d   = '0;
    p2_valid_d    = 1'b0;
    p2_update_d   = 1'b0;

    unique case (st_q)
      ALT_IDLE: begin
        if (issue_valid_q) begin
          part_wdata_d = '0;
          part_be_d    = '0;
          in_pnt_d     = issue_meta_q.init_in_pnt;
          out_pnt_d    = issue_meta_q.init_out_pnt;
          vrf_pnt_d    = issue_meta_q.init_vrf_pnt;
          src_rem_d    = issue_meta_q.init_src_rem;
          dst_rem_d    = issue_meta_q.init_dst_rem;
          first_elem_d = (issue_req_q.op == VSLIDEUP) && issue_req_q.use_scalar_op && (issue_req_q.vl > 1);

          if (issue_meta_q.is_null) begin
            vq_d.issue_pnt = (vq_q.issue_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.issue_pnt + 1'b1);
            vq_d.issue_cnt -= 1'b1;
          end else if (issue_req_q.vfu inside {VFU_Alu, VFU_MFpu}) begin
            if (issue_req_q.op inside {VFREDOSUM, VFWREDOSUM}) begin
              red_rem_d = cnt_t'(issue_req_q.vl);
              ord_ln_d  = '0;
              st_d      = ALT_RED_ORD;
            end else begin
              red_rem_d = cnt_t'($clog2(NrLanes) + 1);
              red_rot_d = 1;
              st_d      = ALT_RED_TREE;
            end
          end else if (issue_meta_q.init_src_rem == '0) begin
            st_d = issue_req_q.use_scalar_op ? ALT_SCALAR_ONLY : ALT_ZERO_TAIL;
          end else begin
            st_d = ALT_FETCH_OP;
          end
        end
      end

      ALT_FETCH_OP: begin
        if (&op_vld_q) begin
          op_pop = '1;
          if (issue_meta_q.need_reshuf) begin
            stage_buf_d = op_reg_q;
            st_d        = ALT_RESHUFFLE;
          end else if (issue_meta_q.is_np2_intra) begin
            stage_buf_d = op_reg_q;
            p2_stride_d = issue_meta_q.intra_slamt;
            p2_valid_d  = 1'b1;
            st_d        = ALT_NP2_STEP;
          end else begin
            stage_buf_d = dp_dst;
            st_d        = ALT_WRITE_SLIDE;
          end
        end
      end

      ALT_RESHUFFLE: begin
        stage_buf_d = dp_dst;
        if (issue_meta_q.intra_slamt == '0) begin
          st_d = ALT_WRITE_SLIDE;
        end else begin
          p2_stride_d = issue_meta_q.intra_slamt;
          p2_valid_d  = 1'b1;
          st_d        = ALT_NP2_STEP;
        end
      end

      ALT_NP2_STEP: begin
        if (p2_valid_q) begin
          stage_buf_d = dp_dst;
          p2_update_d = 1'b1;
          if (p2_popc_q == {{($bits(p2_popc_q)-1){1'b0}}, 1'b1}) begin
            st_d = ALT_WRITE_SLIDE;
          end
        end
      end

      ALT_WRITE_SLIDE: begin
        automatic int unsigned in_av  = RowBytes - int'(in_pnt_q);
        automatic int unsigned out_av = RowBytes - int'(out_pnt_q);
        automatic int unsigned sew_b  = 1 << int'(issue_req_q.vtype.vsew);
        automatic int unsigned step_b = (int'(src_rem_q) < in_av) ? int'(src_rem_q) : in_av;
        automatic elen_t [NrLanes-1:0] w_acc = part_wdata_q;
        automatic strb_t [NrLanes-1:0] b_acc = part_be_q;

        if (step_b > out_av) step_b = out_av;

        if ((int'(out_pnt_q) + step_b) < RowBytes &&
            ((int'(src_rem_q) > step_b) || (int'(dst_rem_q) > step_b))) begin
          // Row not finished yet: accumulate into staging registers and fetch/tail next
          for (int unsigned b = 0; b < RowBytes; b++) begin
            if ((b >= int'(out_pnt_q)) && (b < (int'(out_pnt_q) + step_b))) begin
              automatic int unsigned sb  = shuffle_index(16'(b), NrLanes, issue_req_q.vtype.vsew);
              w_acc[sb >> 3][8*sb[2:0] +: 8] = stage_buf_q[sb >> 3][8*sb[2:0] +: 8];
              b_acc[sb >> 3][sb[2:0]]        = 1'b1;
            end
          end
          if (first_elem_q) begin
            for (int unsigned k = 0; k < 8; k++) begin
              if (k < sew_b) begin
                automatic int unsigned sk = shuffle_index(16'(k), NrLanes, issue_req_q.vtype.vsew);
                w_acc[sk >> 3][8*sk[2:0] +: 8] = issue_req_q.scalar_op[8*k +: 8];
                b_acc[sk >> 3][sk[2:0]]        = 1'b1;
              end
            end
            first_elem_d = 1'b0;
          end
          part_wdata_d = w_acc;
          part_be_d    = b_acc;
          out_pnt_d    = out_pnt_q + step_b[RowShift:0];
          src_rem_d    = src_rem_q - cnt_t'(step_b);
          dst_rem_d    = dst_rem_q - cnt_t'(step_b);
          in_pnt_d     = '0;
          if (src_rem_d != '0) begin
            st_d = ALT_FETCH_OP;
          end else begin
            st_d = issue_req_q.use_scalar_op ? ALT_SCALAR_ONLY : ALT_ZERO_TAIL;
          end
        end else if (!rq_full && (issue_req_q.vm || msk_vld_q)) begin
          for (int unsigned b = 0; b < RowBytes; b++) begin
            if ((b >= int'(out_pnt_q)) && (b < (int'(out_pnt_q) + step_b))) begin
              automatic int unsigned sb = shuffle_index(16'(b), NrLanes, issue_req_q.vtype.vsew);
              w_acc[sb >> 3][8*sb[2:0] +: 8] = stage_buf_q[sb >> 3][8*sb[2:0] +: 8];
              b_acc[sb >> 3][sb[2:0]]        = 1'b1;
            end
          end
          if (first_elem_q) begin
            for (int unsigned k = 0; k < 8; k++) begin
              if (k < sew_b) begin
                automatic int unsigned sk = shuffle_index(16'(k), NrLanes, issue_req_q.vtype.vsew);
                w_acc[sk >> 3][8*sk[2:0] +: 8] = issue_req_q.scalar_op[8*k +: 8];
                b_acc[sk >> 3][sk[2:0]]        = 1'b1;
              end
            end
            first_elem_d = 1'b0;
          end
          if (!issue_req_q.vm) begin
            b_acc   = b_acc & msk_reg_q;
            msk_pop = 1'b1;
          end
          for (int l = 0; l < NrLanes; l++) begin
            rq_d[rq_wpnt_q][l] = '{
              id: issue_req_q.id, addr: vaddr(issue_req_q.vd, NrLanes, VLEN) + vrf_pnt_q,
              wdata: w_acc[l], be: b_acc[l], is_red: 1'b0
            };
          end
          rq_vld_d[rq_wpnt_q] = '1;
          rq_cnt_d            = rq_cnt_q + 1'b1;
          rq_wpnt_d           = (rq_wpnt_q == ResultQueueDepth-1) ? '0 : (rq_wpnt_q + 1'b1);
          part_wdata_d        = '0;
          part_be_d           = '0;
          vrf_pnt_d           = vrf_pnt_q + 1'b1;
          out_pnt_d           = '0;
          src_rem_d           = src_rem_q - cnt_t'(step_b);
          dst_rem_d           = dst_rem_q - cnt_t'(step_b);

          if (dst_rem_d == '0) begin
            in_pnt_d       = '0;
            vq_d.issue_pnt = (vq_q.issue_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.issue_pnt + 1'b1);
            vq_d.issue_cnt -= 1'b1;
            st_d           = ALT_IDLE;
          end else if (src_rem_d == '0) begin
            in_pnt_d = '0;
            st_d     = issue_req_q.use_scalar_op ? ALT_SCALAR_ONLY : ALT_ZERO_TAIL;
          end else if ((int'(in_pnt_q) + step_b) == RowBytes) begin
            in_pnt_d = '0;
            st_d     = ALT_FETCH_OP;
          end else begin
            in_pnt_d = in_pnt_q + step_b[RowShift:0];
            st_d     = ALT_WRITE_SLIDE;
          end
        end
      end

      ALT_ZERO_TAIL: begin
        if (!rq_full && (issue_req_q.vm || msk_vld_q)) begin
          automatic int unsigned out_av = RowBytes - int'(out_pnt_q);
          automatic int unsigned z_step = (int'(dst_rem_q) < out_av) ? int'(dst_rem_q) : out_av;
          automatic elen_t [NrLanes-1:0] w_acc = part_wdata_q;
          automatic strb_t [NrLanes-1:0] b_acc = part_be_q;

          for (int unsigned b = 0; b < RowBytes; b++) begin
            if ((b >= int'(out_pnt_q)) && (b < (int'(out_pnt_q) + z_step))) begin
              automatic int unsigned sb = shuffle_index(16'(b), NrLanes, issue_req_q.vtype.vsew);
              w_acc[sb >> 3][8*sb[2:0] +: 8] = 8'h00;
              b_acc[sb >> 3][sb[2:0]]        = 1'b1;
            end
          end
          if (!issue_req_q.vm) begin
            b_acc   = b_acc & msk_reg_q;
            msk_pop = 1'b1;
          end
          for (int l = 0; l < NrLanes; l++) begin
            rq_d[rq_wpnt_q][l] = '{
              id: issue_req_q.id, addr: vaddr(issue_req_q.vd, NrLanes, VLEN) + vrf_pnt_q,
              wdata: w_acc[l], be: b_acc[l], is_red: 1'b0
            };
          end
          rq_vld_d[rq_wpnt_q] = '1;
          rq_cnt_d            = rq_cnt_q + 1'b1;
          rq_wpnt_d           = (rq_wpnt_q == ResultQueueDepth-1) ? '0 : (rq_wpnt_q + 1'b1);
          part_wdata_d        = '0;
          part_be_d           = '0;
          vrf_pnt_d           = vrf_pnt_q + 1'b1;
          out_pnt_d           = '0;
          dst_rem_d           = dst_rem_q - cnt_t'(z_step);
          if (dst_rem_d == '0) begin
            vq_d.issue_pnt = (vq_q.issue_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.issue_pnt + 1'b1);
            vq_d.issue_cnt -= 1'b1;
            st_d           = ALT_IDLE;
          end
        end
      end

      ALT_SCALAR_ONLY: begin
        if (!rq_full && (issue_req_q.vm || msk_vld_q)) begin
          automatic int unsigned sew_b = 1 << int'(issue_req_q.vtype.vsew);
          automatic elen_t [NrLanes-1:0] w_acc = part_wdata_q;
          automatic strb_t [NrLanes-1:0] b_acc = part_be_q;

          for (int unsigned k = 0; k < 8; k++) begin
            if (k < sew_b) begin
              automatic int unsigned seq_b = int'(out_pnt_q) + k;
              automatic int unsigned sb    = shuffle_index(16'(seq_b), NrLanes, issue_req_q.vtype.vsew);
              w_acc[sb >> 3][8*sb[2:0] +: 8] = issue_req_q.scalar_op[8*k +: 8];
              b_acc[sb >> 3][sb[2:0]]        = 1'b1;
            end
          end
          if (!issue_req_q.vm) begin
            b_acc   = b_acc & msk_reg_q;
            msk_pop = 1'b1;
          end
          for (int l = 0; l < NrLanes; l++) begin
            rq_d[rq_wpnt_q][l] = '{
              id: issue_req_q.id, addr: vaddr(issue_req_q.vd, NrLanes, VLEN) + vrf_pnt_q,
              wdata: w_acc[l], be: b_acc[l], is_red: 1'b0
            };
          end
          rq_vld_d[rq_wpnt_q] = '1;
          rq_cnt_d            = rq_cnt_q + 1'b1;
          rq_wpnt_d           = (rq_wpnt_q == ResultQueueDepth-1) ? '0 : (rq_wpnt_q + 1'b1);
          part_wdata_d        = '0;
          part_be_d           = '0;
          out_pnt_d           = '0;
          dst_rem_d           = '0;
          vq_d.issue_pnt      = (vq_q.issue_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.issue_pnt + 1'b1);
          vq_d.issue_cnt      -= 1'b1;
          st_d                = ALT_IDLE;
        end
      end

      ALT_RED_TREE: begin
        if ((&op_vld_q) && !rq_full) begin
          automatic logic [idx_width(NrLanes):0] rot_w;
          op_pop = '1;
          for (int l = 0; l < NrLanes; l++) begin
            rq_d[rq_wpnt_q][l] = '{
              id: issue_req_q.id, addr: '0, wdata: dp_dst[l], be: '1, is_red: 1'b1
            };
          end
          rq_vld_d[rq_wpnt_q] = '1;
          rq_cnt_d            = rq_cnt_q + 1'b1;
          rq_wpnt_d           = (rq_wpnt_q == ResultQueueDepth-1) ? '0 : (rq_wpnt_q + 1'b1);

          rot_w     = {red_rot_q, red_rot_q[idx_width(NrLanes)-1]};
          red_rot_d = rot_w[idx_width(NrLanes)-1:0];

          if (red_rem_q <= cnt_t'(1)) begin
            red_rem_d      = '0;
            red_rot_d      = 1;
            vq_d.issue_pnt = (vq_q.issue_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.issue_pnt + 1'b1);
            vq_d.issue_cnt -= 1'b1;
            st_d           = ALT_IDLE;
          end else begin
            red_rem_d = red_rem_q - 1'b1;
          end
        end
      end

      ALT_RED_ORD: begin
        if (!rq_full && op_vld_q[ord_ln_q]) begin
          automatic int unsigned sln = int'(ord_ln_q);
          automatic int unsigned tln = (red_rem_q == cnt_t'(1)) ? 0 : ((sln == (NrLanes - 1)) ? 0 : (sln + 1));
          op_pop[sln] = 1'b1;
          for (int l = 0; l < NrLanes; l++) begin
            rq_d[rq_wpnt_q][l] = '{
              id: issue_req_q.id, addr: '0, wdata: (l == tln) ? op_reg_q[sln] : '0, be: '1, is_red: 1'b1
            };
          end
          rq_vld_d[rq_wpnt_q]      = '0;
          rq_vld_d[rq_wpnt_q][tln] = 1'b1;
          rq_cnt_d                 = rq_cnt_q + 1'b1;
          rq_wpnt_d                = (rq_wpnt_q == ResultQueueDepth-1) ? '0 : (rq_wpnt_q + 1'b1);

          ord_ln_d = (sln == (NrLanes - 1)) ? '0 : (ord_ln_q + 1'b1);
          if (red_rem_q <= cnt_t'(1)) begin
            red_rem_d      = '0;
            ord_ln_d       = '0;
            vq_d.issue_pnt = (vq_q.issue_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.issue_pnt + 1'b1);
            vq_d.issue_cnt -= 1'b1;
            st_d           = ALT_IDLE;
          end else begin
            red_rem_d = red_rem_q - 1'b1;
          end
        end
      end

      default: st_d = ALT_IDLE;
    endcase

    // Beat-counted operand & mask single-stage intake
    for (int l = 0; l < NrLanes; l++) begin
      if (op_pop[l]) op_vld_d[l] = 1'b0;
      sldu_operand_ready_o[l] = (!op_vld_d[l]) && (op_rem_q[l] != '0);
      if (sldu_operand_ready_o[l] && sldu_operand_valid_i[l]) begin
        op_reg_d[l] = sldu_operand_i[l];
        op_vld_d[l] = 1'b1;
        op_rem_d[l] = op_rem_q[l] - 1'b1;
      end
    end

    if (msk_pop) msk_vld_d = 1'b0;
    mask_ready_o = (!msk_vld_d) && (msk_rem_q != '0) && (|mask_valid_i);
    if (mask_ready_o) begin
      msk_reg_d = mask_i;
      msk_vld_d = 1'b1;
      msk_rem_d = msk_rem_q - 1'b1;
    end

    // Commit & VRF writeback
    begin
      automatic logic head_ok = 1'b0;
      automatic logic fg_done = 1'b1;

      if (commit_valid && !rq_empty && (cbeats_q != '0)) begin
        for (int l = 0; l < NrLanes; l++) begin
          if (rq_vld_q[rq_rpnt_q][l] && (rq_q[rq_rpnt_q][l].id == commit_req.id)) begin
            head_ok = 1'b1;
          end
        end
      end

      for (int l = 0; l < NrLanes; l++) begin
        automatic logic lv = head_ok & rq_vld_q[rq_rpnt_q][l];
        automatic logic lr = rq_q[rq_rpnt_q][l].is_red;
        sldu_result_req_o[l]   = lv & ~lr;
        sldu_red_valid_o[l]    = lv &  lr;
        sldu_result_addr_o[l]  = rq_q[rq_rpnt_q][l].addr;
        sldu_result_id_o[l]    = rq_q[rq_rpnt_q][l].id;
        sldu_result_wdata_o[l] = rq_q[rq_rpnt_q][l].wdata;
        sldu_result_be_o[l]    = rq_q[rq_rpnt_q][l].be;

        if ((sldu_result_req_o[l] || sldu_red_valid_o[l]) && sldu_result_gnt_i[l]) begin
          rq_vld_d[rq_rpnt_q][l] = 1'b0;
          rq_d[rq_rpnt_q][l]     = '0;
        end

        if ((sldu_result_req_o[l] & sldu_result_gnt_i[l]) && !sldu_result_final_gnt_i[l])
          fgnt_cnt_d[l] = fgnt_cnt_q[l] + 3'd1;
        else if (!(sldu_result_req_o[l] & sldu_result_gnt_i[l]) && sldu_result_final_gnt_i[l] && (fgnt_cnt_q[l] != '0))
          fgnt_cnt_d[l] = fgnt_cnt_q[l] - 3'd1;

        if (fgnt_cnt_d[l] != '0) fg_done = 1'b0;
      end

      if (head_ok && !(|rq_vld_d[rq_rpnt_q])) begin
        rq_rpnt_d = (rq_rpnt_q == ResultQueueDepth-1) ? '0 : (rq_rpnt_q + 1'b1);
        rq_cnt_d  -= 1'b1;
        cbeats_d  = cbeats_q - 1'b1;
      end

      if (commit_valid && (cbeats_d == '0) &&
          ((commit_req.vfu inside {VFU_Alu, VFU_MFpu}) || fg_done)) begin
        pe_resp.vinsn_done[commit_req.id] = 1'b1;
        vq_d.commit_cnt -= 1'b1;
        vq_d.commit_pnt = (vq_q.commit_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.commit_pnt + 1'b1);
        if (vq_d.commit_cnt != '0) begin
          cbeats_d = vq_q.meta[vq_d.commit_pnt].commit_beats;
        end
      end
    end

    // Accept & pre-decode incoming instruction
    if (!vq_full && pe_req_valid_i && !running_q[pe_req_i.id] &&
        ((pe_req_i.vfu == VFU_SlideUnit) ||
         (pe_req_i.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}))) begin
      automatic pe_req_t   r_in   = pe_req_i;
      automatic dec_meta_t m_in   = '0;
      automatic int unsigned sew_s = int'(pe_req_i.vtype.vsew);
      automatic cnt_t        sew_b = cnt_t'(1) << sew_s;
      automatic cnt_t        vl_b  = cnt_t'(pe_req_i.vl) << sew_s;
      automatic stream_cnt_t add_op [NrLanes];
      automatic stream_cnt_t add_msk;

      for (int l = 0; l < NrLanes; l++) add_op[l] = '0;
      add_msk = '0;

      if (pe_req_i.vfu inside {VFU_Alu, VFU_MFpu}) begin
        r_in.vtype.vsew = rvv_pkg::EW64;
        if (pe_req_i.op inside {VFREDOSUM, VFWREDOSUM}) begin
          m_in.is_null      = (pe_req_i.vl == '0);
          m_in.commit_beats = cnt_t'(pe_req_i.vl);
          for (int l = 0; l < NrLanes; l++) begin
            add_op[l] = stream_cnt_t'((int'(pe_req_i.vl) / NrLanes) + ((l < (int'(pe_req_i.vl) % NrLanes)) ? 1 : 0));
          end
        end else begin
          m_in.commit_beats = cnt_t'($clog2(NrLanes) + 1);
          for (int l = 0; l < NrLanes; l++) add_op[l] = stream_cnt_t'($clog2(NrLanes) + 1);
        end
      end else if (pe_req_i.vl == '0) begin
        m_in.is_null = 1'b1;
      end else if (pe_req_i.op == VSLIDEUP) begin
        m_in.dir_up = 1'b1;
        if (!pe_req_i.use_scalar_op) begin
          if ((|pe_req_i.stride[63:$bits(cnt_t)]) || (pe_req_i.stride[$bits(cnt_t)-1:0] >= cnt_t'(pe_req_i.vl))) begin
            m_in.is_null = 1'b1;
          end else begin
            automatic cnt_t st_b  = cnt_t'(pe_req_i.stride[$bits(cnt_t)-1:0]) << sew_s;
            automatic cnt_t rem_b = vl_b - st_b;
            automatic cnt_t f_row = st_b >> RowShift;
            automatic cnt_t l_row = (vl_b - 1'b1) >> RowShift;
            automatic cnt_t s_row = ((rem_b - 1'b1) >> RowShift) + 1'b1;
            m_in.init_vrf_pnt = vaddr_t'(f_row);
            m_in.init_out_pnt = st_b[RowShift-1:0];
            m_in.init_src_rem = rem_b;
            m_in.init_dst_rem = rem_b;
            m_in.intra_slamt  = stride_t'(st_b[RowShift-1:0] >> sew_s);
            m_in.need_reshuf  = (pe_req_i.eew_vs2 != pe_req_i.vtype.vsew);
            m_in.is_np2_intra = has_multi_bits(m_in.intra_slamt);
            m_in.commit_beats = l_row - f_row + 1'b1;
            for (int l = 0; l < NrLanes; l++) add_op[l] = stream_cnt_t'(s_row);
            if (!pe_req_i.vm) add_msk = stream_cnt_t'(m_in.commit_beats);
          end
        end else begin
          m_in.commit_beats = ((vl_b - 1'b1) >> RowShift) + 1'b1;
          if (pe_req_i.vl == 1) begin
            m_in.init_dst_rem = sew_b;
          end else begin
            automatic cnt_t rem_b = vl_b - sew_b;
            automatic cnt_t s_row = ((rem_b - 1'b1) >> RowShift) + 1'b1;
            m_in.init_out_pnt = sew_b[RowShift:0];
            m_in.init_src_rem = rem_b;
            m_in.init_dst_rem = rem_b;
            m_in.intra_slamt  = stride_t'(1);
            m_in.need_reshuf  = (pe_req_i.eew_vs2 != pe_req_i.vtype.vsew);
            for (int l = 0; l < NrLanes; l++) add_op[l] = stream_cnt_t'(s_row);
          end
          if (!pe_req_i.vm) add_msk = stream_cnt_t'(m_in.commit_beats);
        end
      end else begin
        // VSLIDEDOWN / VSLIDE1DOWN
        m_in.commit_beats = ((vl_b - 1'b1) >> RowShift) + 1'b1;
        m_in.init_dst_rem = vl_b;
        if (pe_req_i.use_scalar_op) begin
          if (pe_req_i.vl > 1) begin
            m_in.init_in_pnt  = sew_b[RowShift:0];
            m_in.init_src_rem = vl_b - sew_b;
            m_in.intra_slamt  = stride_t'(1);
            m_in.need_reshuf  = (pe_req_i.eew_vs2 != pe_req_i.vtype.vsew);
            for (int l = 0; l < NrLanes; l++) add_op[l] = stream_cnt_t'(m_in.commit_beats);
          end
        end else begin
          automatic cnt_t vlm_b  = get_vlmax_bytes(pe_req_i.vtype.vlmul);
          automatic cnt_t vlm_el = vlm_b >> sew_s;
          if (!((|pe_req_i.stride[63:$bits(cnt_t)]) || (pe_req_i.stride[$bits(cnt_t)-1:0] >= vlm_el))) begin
            automatic cnt_t st_b  = cnt_t'(pe_req_i.stride[$bits(cnt_t)-1:0]) << sew_s;
            automatic cnt_t av_b  = vlm_b - st_b;
            automatic cnt_t sb    = (vl_b <= av_b) ? vl_b : av_b;
            automatic cnt_t ioff  = cnt_t'(st_b[RowShift-1:0]);
            automatic cnt_t s_row = ((ioff + sb - 1'b1) >> RowShift) + 1'b1;
            m_in.init_in_pnt  = st_b[RowShift-1:0];
            m_in.init_src_rem = sb;
            m_in.intra_slamt  = stride_t'(st_b[RowShift-1:0] >> sew_s);
            m_in.need_reshuf  = (pe_req_i.eew_vs2 != pe_req_i.vtype.vsew) && (sb != '0);
            m_in.is_np2_intra = has_multi_bits(m_in.intra_slamt);
            for (int l = 0; l < NrLanes; l++) add_op[l] = stream_cnt_t'(s_row);
          end
        end
        if (!pe_req_i.vm) add_msk = stream_cnt_t'(m_in.commit_beats);
      end

      vq_d.vinsn[vq_q.accept_pnt] = r_in;
      vq_d.meta[vq_q.accept_pnt]  = m_in;
      running_d[pe_req_i.id]      = 1'b1;
      for (int l = 0; l < NrLanes; l++) op_rem_d[l] += add_op[l];
      msk_rem_d += add_msk;
      if (vq_d.commit_cnt == '0) cbeats_d = m_in.commit_beats;
      vq_d.accept_pnt = (vq_q.accept_pnt == VInsnQueueDepth-1) ? '0 : (vq_q.accept_pnt + 1'b1);
      vq_d.issue_cnt  += 1'b1;
      vq_d.commit_cnt += 1'b1;
    end
  end : p_alt_fsm

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vq_q          <= '0;
      issue_req_q   <= '0;
      issue_meta_q  <= '0;
      issue_valid_q <= 1'b0;
      op_reg_q      <= '0;
      op_vld_q      <= '0;
      op_rem_q      <= '0;
      msk_reg_q     <= '0;
      msk_vld_q     <= 1'b0;
      msk_rem_q     <= '0;
      rq_q          <= '0;
      rq_vld_q      <= '0;
      rq_wpnt_q     <= '0;
      rq_rpnt_q     <= '0;
      rq_cnt_q      <= '0;
      fgnt_cnt_q    <= '0;
      st_q          <= ALT_IDLE;
      stage_buf_q   <= '0;
      part_wdata_q  <= '0;
      part_be_q     <= '0;
      running_q     <= '0;
      in_pnt_q      <= '0;
      out_pnt_q     <= '0;
      vrf_pnt_q     <= '0;
      src_rem_q     <= '0;
      dst_rem_q     <= '0;
      first_elem_q  <= 1'b0;
      cbeats_q      <= '0;
      red_rot_q     <= 1;
      ord_ln_q      <= '0;
      red_rem_q     <= '0;
      pe_resp_o     <= '0;
    end else begin
      vq_q          <= vq_d;
      issue_req_q   <= vq_d.vinsn[vq_d.issue_pnt];
      issue_meta_q  <= vq_d.meta[vq_d.issue_pnt];
      issue_valid_q <= (vq_d.issue_cnt != '0);
      op_reg_q      <= op_reg_d;
      op_vld_q      <= op_vld_d;
      op_rem_q      <= op_rem_d;
      msk_reg_q     <= msk_reg_d;
      msk_vld_q     <= msk_vld_d;
      msk_rem_q     <= msk_rem_d;
      rq_q          <= rq_d;
      rq_vld_q      <= rq_vld_d;
      rq_wpnt_q     <= rq_wpnt_d;
      rq_rpnt_q     <= rq_rpnt_d;
      rq_cnt_q      <= rq_cnt_d;
      fgnt_cnt_q    <= fgnt_cnt_d;
      st_q          <= st_d;
      stage_buf_q   <= stage_buf_d;
      part_wdata_q  <= part_wdata_d;
      part_be_q     <= part_be_d;
      running_q     <= running_d;
      in_pnt_q      <= in_pnt_d;
      out_pnt_q     <= out_pnt_d;
      vrf_pnt_q     <= vrf_pnt_d;
      src_rem_q     <= src_rem_d;
      dst_rem_q     <= dst_rem_d;
      first_elem_q  <= first_elem_d;
      cbeats_q      <= cbeats_d;
      red_rot_q     <= red_rot_d;
      ord_ln_q      <= ord_ln_d;
      red_rem_q     <= red_rem_d;
      pe_resp_o     <= pe_resp;
    end
  end

endmodule : sldu
