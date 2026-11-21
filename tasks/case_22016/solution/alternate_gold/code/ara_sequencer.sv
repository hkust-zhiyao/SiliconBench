// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module ara_sequencer import ara_pkg::*; import rvv_pkg::*; import cf_math_pkg::idx_width; #(
    parameter  int unsigned NrLanes     = 1,
    parameter  int unsigned VLEN        = 0,
    parameter  type         ara_req_t   = logic,
    parameter  type         ara_resp_t  = logic,
    parameter  type         pe_req_t    = logic,
    parameter  type         pe_resp_t   = logic,
    parameter  type         exception_t = logic,
    localparam int unsigned NrPEs   = NrLanes + 4,
    localparam type         vlen_t  = logic[$clog2(VLEN+1)-1:0]
  ) (
    input  logic                            clk_i,
    input  logic                            rst_ni,
    input  ara_req_t                        ara_req_i,
    input  logic                            ara_req_valid_i,
    output logic                            ara_req_ready_o,
    output ara_resp_t                       ara_resp_o,
    output logic                            ara_resp_valid_o,
    output logic                            ara_idle_o,
    output pe_req_t                         pe_req_o,
    output logic                            pe_req_valid_o,
    output logic              [NrVInsn-1:0] pe_vinsn_running_o,
    input  logic                [NrPEs-1:0] pe_req_ready_i,
    input  pe_resp_t            [NrPEs-1:0] pe_resp_i,
    input  logic                            alu_vinsn_done_i,
    input  logic                            mfpu_vinsn_done_i,
    output logic [NrVInsn-1:0][NrVInsn-1:0] global_hazard_table_o,
    input  elen_t                           pe_scalar_resp_i,
    input  logic                            pe_scalar_resp_valid_i,
    output logic                            pe_scalar_resp_ready_o,
    input  logic                            addrgen_ack_i,
    input  exception_t                      addrgen_exception_i,
    input  vlen_t                           addrgen_exception_vstart_i,
    input  logic                            addrgen_fof_exception_i,
    input  logic                            lsu_current_burst_exception_i
  );

  `include "common_cells/registers.svh"

  logic [NrPEs-1:0][NrVInsn-1:0] pe_vinsn_running_d, pe_vinsn_running_q;
  logic [NrVInsn-1:0]            vinsn_running_d, vinsn_running_q;
  vid_t                          free_vid;
  logic                          all_slots_busy;
  logic [NrVInsn-1:0]            lane_desync_mask;
  logic                          lane_desync;

  assign ara_idle_o         = ~(|vinsn_running_q);
  assign pe_vinsn_running_o = vinsn_running_q;

  lzc #(.WIDTH(NrVInsn)) i_slot_alloc (
    .in_i   (~vinsn_running_q),
    .cnt_o  (free_vid        ),
    .empty_o(all_slots_busy  )
  );

  always_comb begin
    vinsn_running_d = '0;
    for (int unsigned pe = 0; pe < NrPEs; pe++) vinsn_running_d |= pe_vinsn_running_d[pe];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vinsn_running_q    <= '0;
      pe_vinsn_running_q <= '0;
    end else begin
      vinsn_running_q    <= vinsn_running_d;
      pe_vinsn_running_q <= pe_vinsn_running_d;
    end
  end

  always_comb begin
    for (int i = 0; i < NrVInsn; i++) begin
      automatic logic other_lane_active = 1'b0;
      for (int l = 1; l < NrLanes; l++) other_lane_active |= pe_vinsn_running_q[l][i];
      lane_desync_mask[i] = ~pe_vinsn_running_q[0][i] & other_lane_active;
    end
    lane_desync = |lane_desync_mask;
  end

  // Per-slot 32-register bitvector CAM table
  typedef struct packed {
    logic [31:0]   wr_mask;
    logic [31:0]   rd_vs1_mask;
    logic [31:0]   rd_vs2_mask;
    logic [31:0]   rd_vd_mask;
    logic          rd_vm;
    logic [4:0]    vd_base;
    logic [4:0]    vs1_base;
    logic [4:0]    vs2_base;
    rvv_pkg::vew_e vd_eew;
    rvv_pkg::vew_e vs1_eew;
    rvv_pkg::vew_e vs2_eew;
    rvv_pkg::vew_e vd_op_eew;
    logic          has_vd;
    logic          chain_wr_ok;
    logic          chain_rd_ok;
    logic          is_masku_vfu;
  } slot_cam_t;
  slot_cam_t [NrVInsn-1:0] slot_cam_d, slot_cam_q;

  function automatic logic [31:0] build_reg_span_mask(logic en, logic [4:0] base_reg, int unsigned span);
    logic [31:0] m;
    m = '0;
    if (en) begin
      for (int unsigned k = 0; k < 8; k++) begin
        if ((k < span) && ((int'(base_reg) + k) < 32))
          m[int'(base_reg) + k] = 1'b1;
      end
    end
    return m;
  endfunction

  function automatic int unsigned span_from_log2(int lg2);
    if (lg2 <= 0) return 1;
    if (lg2 == 1) return 2;
    if (lg2 == 2) return 4;
    return 8;
  endfunction

  function automatic int unsigned span_vd(ara_req_t r);
    if (!r.use_vd) return 0;
    if (r.op inside {[VMFEQ:VMSIF], [VMANDNOT:VMXNOR], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) return 1;
    return span_from_log2(int'(signed'(r.emul)));
  endfunction

  function automatic int unsigned span_vs1(ara_req_t r);
    if (!r.use_vs1) return 0;
    if (r.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMANDNOT:VMXNOR], VCOMPRESS}) return 1;
    if (r.op inside {[VSE:VSXE]}) return span_from_log2(int'(signed'(r.emul)));
    if (r.op == VRGATHEREI16) return span_from_log2(int'(signed'(r.vtype.vlmul)) + int'(EW16) - int'(r.vtype.vsew));
    if (r.op inside {[VMFEQ:VMSBC]}) return span_from_log2(int'(signed'(r.vtype.vlmul)));
    if (r.cvt_resize == CVT_WIDE) return span_from_log2(int'(signed'(r.emul)) - 1);
    return span_from_log2(int'(signed'(r.emul)));
  endfunction

  function automatic int unsigned span_vs2(ara_req_t r);
    if (!r.use_vs2) return 0;
    if (r.op inside {[VMSBF:VIOTA], [VMANDNOT:VMXNOR], [VMVXS:VFMVFS], VCPOP, VFIRST}) return 1;
    if (r.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMFEQ:VMSBC]}) return span_from_log2(int'(signed'(r.vtype.vlmul)));
    if (r.op inside {VLXE, VSXE}) return span_from_log2(int'(signed'(r.vtype.vlmul)) + int'(r.eew_vs2) - int'(r.vtype.vsew));
    if (r.op inside {VRGATHER, VRGATHEREI16, VCOMPRESS, VSLIDEUP, VSLIDEDOWN}) return span_from_log2(int'(signed'(r.emul)));
    if (r.conversion_vs2 inside {OpQueueConversionZExt8, OpQueueConversionSExt8}) return span_from_log2(int'(signed'(r.emul)) - 3);
    if (r.conversion_vs2 inside {OpQueueConversionZExt4, OpQueueConversionSExt4}) return span_from_log2(int'(signed'(r.emul)) - 2);
    if (r.cvt_resize == CVT_WIDE)
      return (r.eew_vs2 == r.vtype.vsew) ? span_from_log2(int'(signed'(r.emul))) : span_from_log2(int'(signed'(r.emul)) - 1);
    if (int'(r.eew_vs2) > int'(r.vtype.vsew)) return span_from_log2(int'(signed'(r.emul)) + 1);
    return span_from_log2(int'(signed'(r.emul)));
  endfunction

  function automatic vfu_e decode_vfu(ara_op_e op);
    unique case (op) inside
      [VADD:VWREDSUM]      : return VFU_Alu;
      [VMUL:VFWREDOSUM]    : return VFU_MFpu;
      [VMFEQ:VCOMPRESS]    : return VFU_MaskUnit;
      [VLE:VLXE]           : return VFU_LoadUnit;
      [VSE:VSXE]           : return VFU_StoreUnit;
      [VSLIDEUP:VSLIDEDOWN]: return VFU_SlideUnit;
      default              : return VFU_None;
    endcase
  endfunction

  function automatic logic [NrVFUs-1:0] decode_target_vfus(ara_op_e op, logic vm);
    logic [NrVFUs-1:0] tv;
    tv = '0;
    unique case (op) inside
      [VADD:VFMVSF]         : tv[VFU_Alu]       = 1'b1;
      [VREDSUM:VWREDSUM]    : begin tv[VFU_Alu] = 1'b1; tv[VFU_SlideUnit] = 1'b1; end
      [VFREDUSUM:VFWREDOSUM]: begin tv[VFU_MFpu] = 1'b1; tv[VFU_SlideUnit] = 1'b1; end
      [VMUL:VFCVTFF]        : tv[VFU_MFpu]      = 1'b1;
      [VMSEQ:VMXNOR],
      [VRGATHER:VCOMPRESS]  : begin tv[VFU_Alu] = 1'b1; tv[VFU_MaskUnit] = 1'b1; end
      [VMFEQ:VMFGE]         : begin tv[VFU_MFpu] = 1'b1; tv[VFU_MaskUnit] = 1'b1; end
      [VLE:VLXE]            : tv[VFU_LoadUnit]  = 1'b1;
      [VSE:VSXE]            : tv[VFU_StoreUnit] = 1'b1;
      [VSLIDEUP:VSLIDEDOWN] : tv[VFU_SlideUnit] = 1'b1;
      [VMVXS:VFMVFS]        : tv[VFU_None]      = 1'b1;
      default:;
    endcase
    if (!vm) tv[VFU_MaskUnit] = 1'b1;
    return tv;
  endfunction

  localparam int unsigned InsnQueueDepth [NrVFUs] = '{
    ValuInsnQueueDepth,
    MfpuInsnQueueDepth,
    SlduInsnQueueDepth,
    MaskuInsnQueueDepth,
    VlduInsnQueueDepth,
    VstuInsnQueueDepth,
    NoneInsnQueueDepth
  };

  localparam int unsigned CNT_W = idx_width(MaxVInsnQueueDepth + 1);
  logic [NrVFUs-1:0][CNT_W-1:0] vfu_cnt_d, vfu_cnt_q;
  logic [NrVFUs-1:0]            vfu_done_vec;
  logic [NrVFUs-1:0]            req_vfus;
  logic [NrVFUs-1:0]            vfu_can_issue;
  logic                         launch_vinsn;

  pe_req_t                         pe_req_d;
  logic                            pe_req_valid_d;
  logic [NrVInsn-1:0][NrVInsn-1:0] ght_d;
  enum logic { SEQ_IDLE, SEQ_WAIT } seq_state_d, seq_state_q;

  logic [$clog2(NrLanes)-1:0]   start_lane, end_lane;
  logic [$clog2(8*NrLanes)-1:0] buf8;
  logic [$clog2(4*NrLanes)-1:0] buf16;
  logic [$clog2(2*NrLanes)-1:0] buf32;

  always_comb begin
    buf8  = '0;
    buf16 = '0;
    buf32 = '0;
    unique case (ara_req_i.vtype.vsew)
      EW8: begin
        start_lane = &ara_req_i.vstart[$clog2(8*NrLanes)-1:$clog2(NrLanes)]
                   ? ara_req_i.vstart[$clog2(NrLanes)-1:0] : '0;
        buf8       = ara_req_i.vl[$clog2(8*NrLanes)-1:0] - 1;
        end_lane   = !(|buf8[$clog2(8*NrLanes)-1:$clog2(NrLanes)])
                   ? ara_req_i.vl[$clog2(NrLanes)-1:0] - 1 : '1;
      end
      EW16: begin
        start_lane = &ara_req_i.vstart[$clog2(4*NrLanes)-1:$clog2(NrLanes)]
                   ? ara_req_i.vstart[$clog2(NrLanes)-1:0] : '0;
        buf16      = ara_req_i.vl[$clog2(4*NrLanes)-1:0] - 1;
        end_lane   = !(|buf16[$clog2(4*NrLanes)-1:$clog2(NrLanes)])
                   ? ara_req_i.vl[$clog2(NrLanes)-1:0] - 1 : '1;
      end
      EW32: begin
        start_lane = &ara_req_i.vstart[$clog2(2*NrLanes)-1:$clog2(NrLanes)]
                   ? ara_req_i.vstart[$clog2(NrLanes)-1:0] : '0;
        buf32      = ara_req_i.vl[$clog2(2*NrLanes)-1:0] - 1;
        end_lane   = !(|buf32[$clog2(2*NrLanes)-1:$clog2(NrLanes)])
                   ? ara_req_i.vl[$clog2(NrLanes)-1:0] - 1 : '1;
      end
      default: begin
        start_lane = ara_req_i.vstart[$clog2(NrLanes)-1:0];
        end_lane   = ara_req_i.vl[$clog2(NrLanes)-1:0] - 1;
      end
    endcase
  end

  logic lsu_burst_ex_q;
  `FF(lsu_burst_ex_q, lsu_current_burst_exception_i, 1'b0, clk_i, rst_ni);

  logic [NrLanes-1:0] opreq_rdy;
  assign opreq_rdy = pe_req_ready_i[NrLanes-1:0];

  assign req_vfus = decode_target_vfus(ara_req_i.op, ara_req_i.vm);
  for (genvar f = 0; f < NrVFUs; f++) begin : gen_vfu_rdy
    assign vfu_can_issue[f] = ~req_vfus[f] | (vfu_cnt_q[f] < CNT_W'(InsnQueueDepth[f]));
  end

  assign vfu_done_vec[VFU_Alu]       = alu_vinsn_done_i;
  assign vfu_done_vec[VFU_MFpu]      = mfpu_vinsn_done_i;
  assign vfu_done_vec[VFU_LoadUnit]  = |pe_resp_i[NrLanes+OffsetLoad].vinsn_done;
  assign vfu_done_vec[VFU_StoreUnit] = |pe_resp_i[NrLanes+OffsetStore].vinsn_done;
  assign vfu_done_vec[VFU_MaskUnit]  = |pe_resp_i[NrLanes+OffsetMask].vinsn_done;
  assign vfu_done_vec[VFU_SlideUnit] = |pe_resp_i[NrLanes+OffsetSlide].vinsn_done;
  assign vfu_done_vec[VFU_None]      = launch_vinsn & req_vfus[VFU_None];

  always_comb begin
    for (int f = 0; f < NrVFUs; f++) begin
      automatic logic up = launch_vinsn & req_vfus[f];
      automatic logic dn = vfu_done_vec[f];
      vfu_cnt_d[f] = vfu_cnt_q[f];
      if (up && !dn)      vfu_cnt_d[f] = vfu_cnt_q[f] + 1'b1;
      else if (!up && dn) vfu_cnt_d[f] = vfu_cnt_q[f] - 1'b1;
    end
  end

  always_comb begin
    automatic logic [31:0] m_vd, m_vs1, m_vs2, m_vd_op;
    automatic logic        any_masku_vfu_busy;
    automatic logic        no_src_op_held;
    automatic logic        c_lin_rd, c_lin_wr, hazard_block;
    automatic logic [NrVInsn-1:0] h_vs1, h_vs2, h_vm, h_vd;
    automatic rvv_pkg::vew_e eff_vs1_eew;

    seq_state_d            = seq_state_q;
    pe_vinsn_running_d     = pe_vinsn_running_q;
    slot_cam_d             = slot_cam_q;
    ght_d                  = global_hazard_table_o;
    pe_req_d               = '0;
    pe_req_valid_d         = 1'b0;
    ara_resp_o             = '0;
    ara_resp_valid_o       = 1'b0;
    ara_req_ready_o        = 1'b1;
    pe_scalar_resp_ready_o = 1'b0;
    launch_vinsn           = 1'b0;

    for (int pe = 0; pe < NrPEs; pe++) pe_vinsn_running_d[pe] &= ~pe_resp_i[pe].vinsn_done;

    any_masku_vfu_busy = 1'b0;
    for (int s = 0; s < NrVInsn; s++) begin
      if (!vinsn_running_q[s]) begin
        slot_cam_d[s] = '0;
      end
      if (pe_resp_i[NrLanes+OffsetMask].vinsn_done[s])
        slot_cam_d[s].is_masku_vfu = 1'b0;
      if (vinsn_running_q[s] && slot_cam_d[s].is_masku_vfu)
        any_masku_vfu_busy = 1'b1;
    end

    no_src_op_held = ((pe_req_o.op == VLE || pe_req_o.op == VLSE) && pe_req_o.vm);
    m_vd      = build_reg_span_mask(ara_req_i.use_vd,    ara_req_i.vd,  span_vd(ara_req_i));
    m_vd_op   = build_reg_span_mask(ara_req_i.use_vd_op, ara_req_i.vd,  span_vd(ara_req_i));
    m_vs1     = build_reg_span_mask(ara_req_i.use_vs1,   ara_req_i.vs1, span_vs1(ara_req_i));
    m_vs2     = build_reg_span_mask(ara_req_i.use_vs2,   ara_req_i.vs2, span_vs2(ara_req_i));
    eff_vs1_eew = (ara_req_i.op inside {[VSE:VSXE]}) ? ara_req_i.old_eew_vs1 : ara_req_i.eew_vs1;

    c_lin_rd     = (ara_req_i.use_vs1 || ara_req_i.use_vs2 || ara_req_i.use_vd_op) &&
                   !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMVXS:VFMVFS], VLXE, VSXE}) &&
                   (ara_req_i.vstart == '0);
    c_lin_wr     = ara_req_i.use_vd &&
                   !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) &&
                   (ara_req_i.vstart == '0) &&
                   (ara_req_i.cvt_resize == CVT_SAME) &&
                   !(int'(ara_req_i.eew_vs2) > int'(ara_req_i.vtype.vsew));
    hazard_block = 1'b0;
    h_vs1        = '0;
    h_vs2        = '0;
    h_vm         = '0;
    h_vd         = '0;

    case (seq_state_q)
      SEQ_IDLE: begin
        if (pe_req_valid_o && !(&opreq_rdy || no_src_op_held)) begin
          pe_req_d        = pe_req_o;
          pe_req_valid_d  = lsu_burst_ex_q ? 1'b0 : pe_req_valid_o;
          ara_req_ready_o = 1'b0;
        end else if (ara_req_valid_i) begin
          if (&vfu_can_issue && !lane_desync && !all_slots_busy &&
              !((ara_req_i.op inside {[VMVXS:VFMVFS]}) && any_masku_vfu_busy)) begin

            for (int s = 0; s < NrVInsn; s++) begin
              if (vinsn_running_q[s]) begin
                automatic logic ov_raw_vs1 = |(m_vs1   & slot_cam_d[s].wr_mask);
                automatic logic ov_raw_vs2 = |(m_vs2   & slot_cam_d[s].wr_mask);
                automatic logic ov_raw_vd  = |(m_vd_op & slot_cam_d[s].wr_mask);
                automatic logic ov_raw_vm  = (!ara_req_i.vm) && slot_cam_d[s].wr_mask[VMASK];
                automatic logic ov_waw     = |(m_vd    & slot_cam_d[s].wr_mask);
                automatic logic ov_war_vs1 = |(m_vd    & slot_cam_d[s].rd_vs1_mask);
                automatic logic ov_war_vs2 = |(m_vd    & slot_cam_d[s].rd_vs2_mask);
                automatic logic ov_war_vd  = |(m_vd    & slot_cam_d[s].rd_vd_mask);
                automatic logic ov_war_vm  = m_vd[VMASK] && slot_cam_d[s].rd_vm;
                automatic logic ov_war_any = ov_war_vs1 | ov_war_vs2 | ov_war_vd | ov_war_vm;

                if (ov_raw_vs1 | ov_war_any) h_vs1[s] = 1'b1;
                if (ov_raw_vs2 | ov_war_any) h_vs2[s] = 1'b1;
                if (ov_raw_vm  | ov_war_any) h_vm[s]  = 1'b1;
                if (ov_waw     | ov_raw_vd ) h_vd[s]  = 1'b1;

                if (ov_raw_vm || ov_war_vm) hazard_block = 1'b1;
                if (ov_raw_vs1 && !(c_lin_rd && slot_cam_d[s].chain_wr_ok && (ara_req_i.vs1 == slot_cam_d[s].vd_base) && (eff_vs1_eew == slot_cam_d[s].vd_eew)))
                  hazard_block = 1'b1;
                if (ov_raw_vs2 && !(c_lin_rd && slot_cam_d[s].chain_wr_ok && (ara_req_i.vs2 == slot_cam_d[s].vd_base) && (ara_req_i.eew_vs2 == slot_cam_d[s].vd_eew)))
                  hazard_block = 1'b1;
                if (ov_raw_vd && !(c_lin_rd && slot_cam_d[s].chain_wr_ok && (ara_req_i.vd == slot_cam_d[s].vd_base) && (ara_req_i.eew_vd_op == slot_cam_d[s].vd_eew)))
                  hazard_block = 1'b1;
                if (ov_waw && !(c_lin_rd && c_lin_wr && slot_cam_d[s].chain_wr_ok && (ara_req_i.vd == slot_cam_d[s].vd_base) && (ara_req_i.vtype.vsew == slot_cam_d[s].vd_eew)))
                  hazard_block = 1'b1;
                if (ov_war_vs1 && !(c_lin_rd && c_lin_wr && slot_cam_d[s].chain_rd_ok && slot_cam_d[s].has_vd && (ara_req_i.vd == slot_cam_d[s].vs1_base) && (ara_req_i.vtype.vsew == slot_cam_d[s].vs1_eew)))
                  hazard_block = 1'b1;
                if (ov_war_vs2 && !(c_lin_rd && c_lin_wr && slot_cam_d[s].chain_rd_ok && slot_cam_d[s].has_vd && (ara_req_i.vd == slot_cam_d[s].vs2_base) && (ara_req_i.vtype.vsew == slot_cam_d[s].vs2_eew)))
                  hazard_block = 1'b1;
                if (ov_war_vd && !(c_lin_rd && c_lin_wr && slot_cam_d[s].chain_rd_ok && slot_cam_d[s].has_vd && (ara_req_i.vd == slot_cam_d[s].vd_base) && (ara_req_i.vtype.vsew == slot_cam_d[s].vd_op_eew)))
                  hazard_block = 1'b1;
              end
            end

            pe_req_d = '{
              id            : free_vid,
              op            : ara_req_i.op,
              vm            : ara_req_i.vm,
              eew_vmask     : ara_req_i.eew_vmask,
              vfu           : decode_vfu(ara_req_i.op),
              vs1           : ara_req_i.vs1,
              use_vs1       : ara_req_i.use_vs1,
              conversion_vs1: ara_req_i.conversion_vs1,
              eew_vs1       : ara_req_i.eew_vs1,
              old_eew_vs1   : ara_req_i.old_eew_vs1,
              vs2           : ara_req_i.vs2,
              use_vs2       : ara_req_i.use_vs2,
              conversion_vs2: ara_req_i.conversion_vs2,
              eew_vs2       : ara_req_i.eew_vs2,
              use_vd_op     : ara_req_i.use_vd_op,
              eew_vd_op     : ara_req_i.eew_vd_op,
              scalar_op     : ara_req_i.scalar_op,
              use_scalar_op : ara_req_i.use_scalar_op,
              swap_vs2_vd_op: ara_req_i.swap_vs2_vd_op,
              stride        : ara_req_i.stride,
              is_stride_np2 : ara_req_i.is_stride_np2,
              vd            : ara_req_i.vd,
              use_vd        : ara_req_i.use_vd,
              emul          : ara_req_i.emul,
              fp_rm         : ara_req_i.fp_rm,
              wide_fp_imm   : ara_req_i.wide_fp_imm,
              cvt_resize    : ara_req_i.cvt_resize,
              scale_vl      : ara_req_i.scale_vl,
              start_lane    : start_lane,
              end_lane      : end_lane,
              vl            : ara_req_i.vl,
              vstart        : ara_req_i.vstart,
              vtype         : ara_req_i.vtype,
              hazard_vd     : h_vd,
              hazard_vm     : h_vm,
              hazard_vs1    : h_vs1,
              hazard_vs2    : h_vs2,
              default       : '0
            };

            if (hazard_block) begin
              ara_req_ready_o = 1'b0;
              pe_req_valid_d  = 1'b0;
            end else begin
              ara_req_ready_o = 1'b1;
              pe_req_valid_d  = 1'b1;
              launch_vinsn    = 1'b1;
              ght_d[free_vid] = h_vd | h_vm | h_vs1 | h_vs2;

              unique case (decode_vfu(ara_req_i.op))
                VFU_LoadUnit : pe_vinsn_running_d[NrLanes + OffsetLoad][free_vid]  = 1'b1;
                VFU_StoreUnit: pe_vinsn_running_d[NrLanes + OffsetStore][free_vid] = 1'b1;
                VFU_SlideUnit: pe_vinsn_running_d[NrLanes + OffsetSlide][free_vid] = 1'b1;
                VFU_MaskUnit : pe_vinsn_running_d[NrLanes + OffsetMask][free_vid]  = 1'b1;
                VFU_None     : ;
                default: for (int l = 0; l < NrLanes; l++) pe_vinsn_running_d[l][free_vid] = 1'b1;
              endcase
              pe_vinsn_running_d[NrLanes + OffsetMask][free_vid] |= !ara_req_i.vm;

              slot_cam_d[free_vid] = '{
                wr_mask      : m_vd,
                rd_vs1_mask  : m_vs1,
                rd_vs2_mask  : m_vs2,
                rd_vd_mask   : m_vd_op,
                rd_vm        : !ara_req_i.vm,
                vd_base      : ara_req_i.vd,
                vs1_base     : ara_req_i.vs1,
                vs2_base     : ara_req_i.vs2,
                vd_eew       : ara_req_i.vtype.vsew,
                vs1_eew      : eff_vs1_eew,
                vs2_eew      : ara_req_i.eew_vs2,
                vd_op_eew    : ara_req_i.eew_vd_op,
                has_vd       : ara_req_i.use_vd,
                chain_wr_ok  : ara_req_i.use_vd &&
                               !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) &&
                               (ara_req_i.vstart == '0),
                chain_rd_ok  : !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VSE:VSXE], VLXE}) &&
                               (ara_req_i.vstart == '0) &&
                               (ara_req_i.cvt_resize == CVT_SAME) &&
                               !(int'(ara_req_i.eew_vs2) > int'(ara_req_i.vtype.vsew)),
                is_masku_vfu : (decode_vfu(ara_req_i.op) == VFU_MaskUnit)
              };

              if (is_load(ara_req_i.op) || is_store(ara_req_i.op) || !ara_req_i.use_vd) begin
                ara_req_ready_o = 1'b0;
                seq_state_d     = SEQ_WAIT;
              end
            end
          end else begin
            ara_req_ready_o = 1'b0;
          end
        end
      end

      SEQ_WAIT: begin
        ara_req_ready_o = 1'b0;
        pe_req_d        = pe_req_o;
        pe_req_valid_d  = pe_req_valid_o;

        if (!pe_req_o.use_vd && !is_store(pe_req_o.op) && &opreq_rdy)
          pe_req_valid_d = 1'b0;
        if (no_src_op_held && addrgen_ack_i)
          pe_req_valid_d = 1'b0;
        if (lsu_burst_ex_q)
          pe_req_valid_d = 1'b0;

        if ((is_load(pe_req_o.op) || is_store(pe_req_o.op)) && addrgen_ack_i) begin
          seq_state_d                 = SEQ_IDLE;
          ara_req_ready_o             = 1'b1;
          ara_resp_valid_o            = 1'b1;
          ara_resp_o.exception        = addrgen_exception_i;
          ara_resp_o.exception_vstart = addrgen_exception_vstart_i;
          ara_resp_o.fof_exception    = addrgen_fof_exception_i;
        end

        if (!pe_req_o.use_vd && !is_load(pe_req_o.op) && !is_store(pe_req_o.op)) begin
          if (pe_req_o.op inside {[VCPOP:VFIRST]}) begin
            if (pe_scalar_resp_valid_i) begin
              seq_state_d            = SEQ_IDLE;
              ara_req_ready_o        = 1'b1;
              ara_resp_valid_o       = 1'b1;
              ara_resp_o.resp        = pe_scalar_resp_i;
              pe_scalar_resp_ready_o = 1'b0;
            end
          end else if (!pe_req_valid_o && pe_scalar_resp_valid_i && !any_masku_vfu_busy) begin
            seq_state_d            = SEQ_IDLE;
            ara_req_ready_o        = 1'b1;
            ara_resp_valid_o       = 1'b1;
            ara_resp_o.resp        = pe_scalar_resp_i;
            pe_scalar_resp_ready_o = 1'b1;
          end
        end
      end
    endcase

    for (int id = 0; id < NrVInsn; id++) ght_d[id] &= vinsn_running_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      seq_state_q           <= SEQ_IDLE;
      slot_cam_q            <= '0;
      pe_req_o              <= '0;
      pe_req_valid_o        <= 1'b0;
      global_hazard_table_o <= '0;
      vfu_cnt_q             <= '0;
    end else begin
      seq_state_q           <= seq_state_d;
      slot_cam_q            <= slot_cam_d;
      pe_req_o              <= pe_req_d;
      pe_req_valid_o        <= pe_req_valid_d;
      global_hazard_table_o <= ght_d;
      vfu_cnt_q             <= vfu_cnt_d;
    end
  end

endmodule : ara_sequencer
