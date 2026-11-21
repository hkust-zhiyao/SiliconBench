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
  vid_t                          vinsn_id_n;
  logic                          vinsn_running_full;
  logic [NrVInsn-1:0]            stall_lanes_desynch_vec;
  logic                          stall_lanes_desynch;
  logic [NrVInsn-1:0][NrPEs-1:0] pe_vinsn_running_q_trns;

  assign ara_idle_o = !(|vinsn_running_q);

  lzc #(.WIDTH(NrVInsn)) i_next_id (
    .in_i   (~vinsn_running_q  ),
    .cnt_o  (vinsn_id_n        ),
    .empty_o(vinsn_running_full)
  );

  always_comb begin: p_vinsn_running
    vinsn_running_d = '0;
    for (int unsigned pe = 0; pe < NrPEs; pe++) vinsn_running_d |= pe_vinsn_running_d[pe];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin: p_vinsn_running_ff
    if (!rst_ni) begin
      vinsn_running_q    <= '0;
      pe_vinsn_running_q <= '0;
    end else begin
      vinsn_running_q    <= vinsn_running_d;
      pe_vinsn_running_q <= pe_vinsn_running_d;
    end
  end

  assign pe_vinsn_running_o = vinsn_running_q;

  for (genvar r = 0; r < NrVInsn; r++) begin : gen_trans_mtx_r
    for (genvar c = 0; c < NrPEs; c++) begin : gen_trans_mtx_c
      assign pe_vinsn_running_q_trns[r][c] = pe_vinsn_running_q[c][r];
    end
  end

  for (genvar i = 0; i < NrVInsn; i++) begin : gen_stall_lane_desynch
    assign stall_lanes_desynch_vec[i] = ~pe_vinsn_running_q[0][i] & |pe_vinsn_running_q_trns[i][NrLanes-1:1];
  end
  assign stall_lanes_desynch = |stall_lanes_desynch_vec;

  logic [NrVInsn-1:0][NrVInsn-1:0] global_hazard_table_d;

  pe_req_t pe_req_d;
  logic    pe_req_valid_d;

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

  enum logic { IDLE, WAIT } state_d, state_q;

  // Register-indexed multi-vid bitmaps + per-vid chaining metadata
  logic [31:0][NrVInsn-1:0] vreg_write_d, vreg_write_q;
  logic [31:0][NrVInsn-1:0] vreg_read_vs1_d, vreg_read_vs1_q;
  logic [31:0][NrVInsn-1:0] vreg_read_vs2_d, vreg_read_vs2_q;
  logic [31:0][NrVInsn-1:0] vreg_read_vd_d,  vreg_read_vd_q;
  logic [NrVInsn-1:0]       vmask_read_d,    vmask_read_q;

  typedef struct packed {
    logic [4:0]    base_vd;
    logic [4:0]    base_vs1;
    logic [4:0]    base_vs2;
    rvv_pkg::vew_e eew_vd;
    rvv_pkg::vew_e eew_vs1;
    rvv_pkg::vew_e eew_vs2;
    rvv_pkg::vew_e eew_vd_op;
    logic          use_vd;
    logic          use_vs1;
    logic          use_vs2;
    logic          use_vd_op;
    logic          linear_wr;
    logic          linear_rd;
  } vinsn_meta_t;
  vinsn_meta_t [NrVInsn-1:0] vinsn_meta_d, vinsn_meta_q;

  logic [NrVInsn-1:0] masku_vfu_running_d, masku_vfu_running_q;

  function automatic vfu_e vfu(ara_op_e op);
    unique case (op) inside
      [VADD:VWREDSUM]      : vfu = VFU_Alu;
      [VMUL:VFWREDOSUM]    : vfu = VFU_MFpu;
      [VMFEQ:VCOMPRESS]    : vfu = VFU_MaskUnit;
      [VLE:VLXE]           : vfu = VFU_LoadUnit;
      [VSE:VSXE]           : vfu = VFU_StoreUnit;
      [VSLIDEUP:VSLIDEDOWN]: vfu = VFU_SlideUnit;
      [VMVXS:VFMVFS]       : vfu = VFU_None;
      default              : vfu = VFU_None;
    endcase
  endfunction

  function automatic logic [NrVFUs-1:0] target_vfus(ara_op_e op);
    target_vfus = '0;
    unique case (op) inside
      [VADD:VFMVSF]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_Alu) target_vfus[i] = 1'b1;
      [VREDSUM:VWREDSUM]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_Alu || i == VFU_SlideUnit) target_vfus[i] = 1'b1;
      [VFREDUSUM:VFWREDOSUM]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_MFpu || i == VFU_SlideUnit) target_vfus[i] = 1'b1;
      [VMUL:VFCVTFF]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_MFpu) target_vfus[i] = 1'b1;
      [VMSEQ:VMXNOR]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_Alu || i == VFU_MaskUnit) target_vfus[i] = 1'b1;
      [VRGATHER:VCOMPRESS]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_Alu || i == VFU_MaskUnit) target_vfus[i] = 1'b1;
      [VMFEQ:VMFGE]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_MFpu || i == VFU_MaskUnit) target_vfus[i] = 1'b1;
      [VLE:VLXE]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_LoadUnit) target_vfus[i] = 1'b1;
      [VSE:VSXE]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_StoreUnit) target_vfus[i] = 1'b1;
      [VSLIDEUP:VSLIDEDOWN]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_SlideUnit) target_vfus[i] = 1'b1;
      [VMVXS:VFMVFS]:
        for (int i = 0; i < NrVFUs; i++)
          if (i == VFU_None) target_vfus[i] = 1'b1;
      default:;
    endcase
  endfunction

  function automatic logic no_src_vrf(pe_req_t pe_req);
    no_src_vrf = ((pe_req.op == VLE || pe_req.op == VLSE) && pe_req.vm);
  endfunction

  function automatic int unsigned nregs_from_steps(int steps);
    if (steps <= 0) return 1;
    if (steps == 1) return 2;
    if (steps == 2) return 4;
    return 8;
  endfunction

  function automatic int unsigned calc_nregs_vd(ara_req_t req);
    if (!req.use_vd) return 0;
    if (req.op inside {[VMFEQ:VMSIF], [VMANDNOT:VMXNOR], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) return 1;
    return nregs_from_steps(int'(signed'(req.emul)));
  endfunction

  function automatic int unsigned calc_nregs_vs1(ara_req_t req);
    if (!req.use_vs1) return 0;
    if (req.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMANDNOT:VMXNOR], VCOMPRESS}) return 1;
    if (req.op inside {[VSE:VSXE]}) return nregs_from_steps(int'(signed'(req.emul)));
    if (req.op == VRGATHEREI16) return nregs_from_steps(int'(signed'(req.vtype.vlmul)) + int'(EW16) - int'(req.vtype.vsew));
    if (req.op inside {[VMFEQ:VMSBC]}) return nregs_from_steps(int'(signed'(req.vtype.vlmul)));
    if (req.cvt_resize == CVT_WIDE) return nregs_from_steps(int'(signed'(req.emul)) - 1);
    return nregs_from_steps(int'(signed'(req.emul)));
  endfunction

  function automatic int unsigned calc_nregs_vs2(ara_req_t req);
    if (!req.use_vs2) return 0;
    if (req.op inside {[VMSBF:VIOTA], [VMANDNOT:VMXNOR], [VMVXS:VFMVFS], VCPOP, VFIRST}) return 1;
    if (req.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMFEQ:VMSBC]}) return nregs_from_steps(int'(signed'(req.vtype.vlmul)));
    if (req.op inside {VLXE, VSXE}) return nregs_from_steps(int'(signed'(req.vtype.vlmul)) + int'(req.eew_vs2) - int'(req.vtype.vsew));
    if (req.op inside {VRGATHER, VRGATHEREI16, VCOMPRESS, VSLIDEUP, VSLIDEDOWN}) return nregs_from_steps(int'(signed'(req.emul)));
    if (req.conversion_vs2 inside {OpQueueConversionZExt8, OpQueueConversionSExt8}) return nregs_from_steps(int'(signed'(req.emul)) - 3);
    if (req.conversion_vs2 inside {OpQueueConversionZExt4, OpQueueConversionSExt4}) return nregs_from_steps(int'(signed'(req.emul)) - 2);
    if (req.cvt_resize == CVT_WIDE)
      return (req.eew_vs2 == req.vtype.vsew) ? nregs_from_steps(int'(signed'(req.emul))) : nregs_from_steps(int'(signed'(req.emul)) - 1);
    if (int'(req.eew_vs2) > int'(req.vtype.vsew)) return nregs_from_steps(int'(signed'(req.emul)) + 1);
    return nregs_from_steps(int'(signed'(req.emul)));
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

  logic [NrVFUs-1:0][idx_width(MaxVInsnQueueDepth + 1)-1:0] insn_queue_cnt_q;
  logic [NrVFUs-1:0] insn_queue_done;
  logic [NrVFUs-1:0] insn_queue_cnt_en, insn_queue_cnt_down, insn_queue_cnt_up;
  logic [NrVFUs-1:0] vinsn_queue_issue;
  logic [NrVFUs-1:0] target_vfus_vec;
  logic              insn_issue_fire;

  logic lsu_current_burst_exception_q;
  `FF(lsu_current_burst_exception_q, lsu_current_burst_exception_i, 1'b0, clk_i, rst_ni);

  logic [NrLanes-1:0] operand_requester_ready;
  assign operand_requester_ready = pe_req_ready_i[NrLanes-1:0];

  always_comb begin: p_sequencer
    automatic int unsigned nr_vd, nr_vs1, nr_vs2;
    automatic logic [NrVInsn-1:0] raw_vs1, raw_vs2, raw_vd_op, raw_vm;
    automatic logic [NrVInsn-1:0] waw_vd, war_vs1, war_vs2, war_vd_op, war_vm;
    automatic logic               c_linear_consumer, c_linear_writer, must_stall_hazard;

    state_d               = state_q;
    pe_vinsn_running_d    = pe_vinsn_running_q;
    vreg_write_d          = vreg_write_q;
    vreg_read_vs1_d       = vreg_read_vs1_q;
    vreg_read_vs2_d       = vreg_read_vs2_q;
    vreg_read_vd_d        = vreg_read_vd_q;
    vmask_read_d          = vmask_read_q;
    vinsn_meta_d          = vinsn_meta_q;
    global_hazard_table_d = global_hazard_table_o;
    masku_vfu_running_d   = masku_vfu_running_q & ~pe_resp_i[NrLanes+OffsetMask].vinsn_done;

    pe_req_d               = '0;
    pe_req_valid_d         = 1'b0;
    ara_resp_o             = '0;
    ara_resp_valid_o       = 1'b0;
    ara_req_ready_o        = 1'b1;
    pe_scalar_resp_ready_o = 1'b0;
    insn_issue_fire        = 1'b0;

    nr_vd  = calc_nregs_vd(ara_req_i);
    nr_vs1 = calc_nregs_vs1(ara_req_i);
    nr_vs2 = calc_nregs_vs2(ara_req_i);

    raw_vs1           = '0;
    raw_vs2           = '0;
    raw_vd_op         = '0;
    raw_vm            = '0;
    waw_vd            = '0;
    war_vs1           = '0;
    war_vs2           = '0;
    war_vd_op         = '0;
    war_vm            = '0;
    c_linear_consumer = 1'b0;
    c_linear_writer   = 1'b0;
    must_stall_hazard = 1'b0;

    for (int pe = 0; pe < NrPEs; pe++) pe_vinsn_running_d[pe] &= ~pe_resp_i[pe].vinsn_done;

    for (int unsigned v = 0; v < 32; v++) begin
      vreg_write_d[v]    &= vinsn_running_q;
      vreg_read_vs1_d[v] &= vinsn_running_q;
      vreg_read_vs2_d[v] &= vinsn_running_q;
      vreg_read_vd_d[v]  &= vinsn_running_q;
    end
    vmask_read_d &= vinsn_running_q;

    case (state_q)
      IDLE: begin
        if (pe_req_valid_o && !(&operand_requester_ready || no_src_vrf(pe_req_o))) begin
          pe_req_d       = pe_req_o;
          pe_req_valid_d = pe_req_valid_o;
          if (lsu_current_burst_exception_q)
            pe_req_valid_d = 1'b0;
          ara_req_ready_o = 1'b0;
        end else if (ara_req_valid_i) begin
          if (&vinsn_queue_issue && !stall_lanes_desynch && !vinsn_running_full &&
              !((ara_req_i.op inside {[VMVXS:VFMVFS]}) && (|masku_vfu_running_d))) begin

            for (int unsigned k = 0; k < 8; k++) begin
              if (ara_req_i.use_vs1 && (k < nr_vs1) && ((int'(ara_req_i.vs1) + k) < 32))
                raw_vs1 |= vreg_write_d[ara_req_i.vs1 + k[4:0]];
              if (ara_req_i.use_vs2 && (k < nr_vs2) && ((int'(ara_req_i.vs2) + k) < 32))
                raw_vs2 |= vreg_write_d[ara_req_i.vs2 + k[4:0]];
              if (ara_req_i.use_vd_op && (k < nr_vd) && ((int'(ara_req_i.vd) + k) < 32))
                raw_vd_op |= vreg_write_d[ara_req_i.vd + k[4:0]];
              if (ara_req_i.use_vd && (k < nr_vd) && ((int'(ara_req_i.vd) + k) < 32)) begin
                waw_vd    |= vreg_write_d[ara_req_i.vd + k[4:0]];
                war_vs1   |= vreg_read_vs1_d[ara_req_i.vd + k[4:0]];
                war_vs2   |= vreg_read_vs2_d[ara_req_i.vd + k[4:0]];
                war_vd_op |= vreg_read_vd_d[ara_req_i.vd + k[4:0]];
              end
            end
            if (!ara_req_i.vm)
              raw_vm |= vreg_write_d[VMASK];
            if (ara_req_i.use_vd && (ara_req_i.vd == VMASK))
              war_vm |= vmask_read_d;

            c_linear_consumer = (ara_req_i.use_vs1 || ara_req_i.use_vs2 || ara_req_i.use_vd_op) &&
                                !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMVXS:VFMVFS], VLXE, VSXE}) &&
                                (ara_req_i.vstart == '0);
            c_linear_writer   = ara_req_i.use_vd &&
                                !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) &&
                                (ara_req_i.vstart == '0) &&
                                (ara_req_i.cvt_resize == CVT_SAME) &&
                                !(int'(ara_req_i.eew_vs2) > int'(ara_req_i.vtype.vsew));

            if (|raw_vm || |war_vm)
              must_stall_hazard = 1'b1;

            for (int p = 0; p < NrVInsn; p++) begin
              if (raw_vs1[p]) begin
                if (!(c_linear_consumer && vinsn_meta_q[p].linear_wr &&
                      (ara_req_i.vs1 == vinsn_meta_q[p].base_vd) &&
                      ((ara_req_i.op inside {[VSE:VSXE]} ? ara_req_i.old_eew_vs1 : ara_req_i.eew_vs1) == vinsn_meta_q[p].eew_vd)))
                  must_stall_hazard = 1'b1;
              end
              if (raw_vs2[p]) begin
                if (!(c_linear_consumer && vinsn_meta_q[p].linear_wr &&
                      (ara_req_i.vs2 == vinsn_meta_q[p].base_vd) &&
                      (ara_req_i.eew_vs2 == vinsn_meta_q[p].eew_vd)))
                  must_stall_hazard = 1'b1;
              end
              if (raw_vd_op[p]) begin
                if (!(c_linear_consumer && vinsn_meta_q[p].linear_wr &&
                      (ara_req_i.vd == vinsn_meta_q[p].base_vd) &&
                      (ara_req_i.eew_vd_op == vinsn_meta_q[p].eew_vd)))
                  must_stall_hazard = 1'b1;
              end
              if (waw_vd[p]) begin
                if (!(c_linear_consumer && c_linear_writer && vinsn_meta_q[p].linear_wr &&
                      (ara_req_i.vd == vinsn_meta_q[p].base_vd) &&
                      (ara_req_i.vtype.vsew == vinsn_meta_q[p].eew_vd)))
                  must_stall_hazard = 1'b1;
              end
              if (war_vs1[p]) begin
                if (!(c_linear_consumer && c_linear_writer && vinsn_meta_q[p].linear_rd && vinsn_meta_q[p].use_vd &&
                      (ara_req_i.vd == vinsn_meta_q[p].base_vs1) &&
                      (ara_req_i.vtype.vsew == vinsn_meta_q[p].eew_vs1)))
                  must_stall_hazard = 1'b1;
              end
              if (war_vs2[p]) begin
                if (!(c_linear_consumer && c_linear_writer && vinsn_meta_q[p].linear_rd && vinsn_meta_q[p].use_vd &&
                      (ara_req_i.vd == vinsn_meta_q[p].base_vs2) &&
                      (ara_req_i.vtype.vsew == vinsn_meta_q[p].eew_vs2)))
                  must_stall_hazard = 1'b1;
              end
              if (war_vd_op[p]) begin
                if (!(c_linear_consumer && c_linear_writer && vinsn_meta_q[p].linear_rd && vinsn_meta_q[p].use_vd &&
                      (ara_req_i.vd == vinsn_meta_q[p].base_vd) &&
                      (ara_req_i.vtype.vsew == vinsn_meta_q[p].eew_vd_op)))
                  must_stall_hazard = 1'b1;
              end
            end

            pe_req_d = '{
              id            : vinsn_id_n,
              op            : ara_req_i.op,
              vm            : ara_req_i.vm,
              eew_vmask     : ara_req_i.eew_vmask,
              vfu           : vfu(ara_req_i.op),
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
              hazard_vd     : waw_vd  | raw_vd_op,
              hazard_vm     : raw_vm  | war_vs1 | war_vs2 | war_vd_op | war_vm,
              hazard_vs1    : raw_vs1 | war_vs1 | war_vs2 | war_vd_op | war_vm,
              hazard_vs2    : raw_vs2 | war_vs1 | war_vs2 | war_vd_op | war_vm,
              default       : '0
            };

            if (must_stall_hazard) begin
              ara_req_ready_o = 1'b0;
              pe_req_valid_d  = 1'b0;
            end else begin
              ara_req_ready_o = 1'b1;
              insn_issue_fire = 1'b1;

              global_hazard_table_d[vinsn_id_n] = pe_req_d.hazard_vd  | pe_req_d.hazard_vm |
                                                  pe_req_d.hazard_vs1 | pe_req_d.hazard_vs2;

              unique case (vfu(ara_req_i.op))
                VFU_LoadUnit : pe_vinsn_running_d[NrLanes + OffsetLoad][vinsn_id_n]  = 1'b1;
                VFU_StoreUnit: pe_vinsn_running_d[NrLanes + OffsetStore][vinsn_id_n] = 1'b1;
                VFU_SlideUnit: pe_vinsn_running_d[NrLanes + OffsetSlide][vinsn_id_n] = 1'b1;
                VFU_MaskUnit : begin
                  pe_vinsn_running_d[NrLanes + OffsetMask][vinsn_id_n] = 1'b1;
                  masku_vfu_running_d[vinsn_id_n]                      = 1'b1;
                end
                VFU_None     : ;
                default: for (int l = 0; l < NrLanes; l++)
                  pe_vinsn_running_d[l][vinsn_id_n] = 1'b1;
              endcase

              pe_vinsn_running_d[NrLanes + OffsetMask][vinsn_id_n] |= !ara_req_i.vm;

              if (is_load(ara_req_i.op) || is_store(ara_req_i.op) || !ara_req_i.use_vd) begin
                ara_req_ready_o = 1'b0;
                state_d         = WAIT;
              end

              pe_req_valid_d = 1'b1;

              for (int unsigned k = 0; k < 8; k++) begin
                if (ara_req_i.use_vd && (k < nr_vd) && ((int'(ara_req_i.vd) + k) < 32))
                  vreg_write_d[ara_req_i.vd + k[4:0]][vinsn_id_n] = 1'b1;
                if (ara_req_i.use_vs1 && (k < nr_vs1) && ((int'(ara_req_i.vs1) + k) < 32))
                  vreg_read_vs1_d[ara_req_i.vs1 + k[4:0]][vinsn_id_n] = 1'b1;
                if (ara_req_i.use_vs2 && (k < nr_vs2) && ((int'(ara_req_i.vs2) + k) < 32))
                  vreg_read_vs2_d[ara_req_i.vs2 + k[4:0]][vinsn_id_n] = 1'b1;
                if (ara_req_i.use_vd_op && (k < nr_vd) && ((int'(ara_req_i.vd) + k) < 32))
                  vreg_read_vd_d[ara_req_i.vd + k[4:0]][vinsn_id_n] = 1'b1;
              end
              if (!ara_req_i.vm)
                vmask_read_d[vinsn_id_n] = 1'b1;

              vinsn_meta_d[vinsn_id_n] = '{
                base_vd   : ara_req_i.vd,
                base_vs1  : ara_req_i.vs1,
                base_vs2  : ara_req_i.vs2,
                eew_vd    : ara_req_i.vtype.vsew,
                eew_vs1   : (ara_req_i.op inside {[VSE:VSXE]}) ? ara_req_i.old_eew_vs1 : ara_req_i.eew_vs1,
                eew_vs2   : ara_req_i.eew_vs2,
                eew_vd_op : ara_req_i.eew_vd_op,
                use_vd    : ara_req_i.use_vd,
                use_vs1   : ara_req_i.use_vs1,
                use_vs2   : ara_req_i.use_vs2,
                use_vd_op : ara_req_i.use_vd_op,
                linear_wr : ara_req_i.use_vd &&
                            !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) &&
                            (ara_req_i.vstart == '0),
                linear_rd : !(ara_req_i.op inside {[VMFEQ:VCOMPRESS], [VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VSE:VSXE], VLXE}) &&
                            (ara_req_i.vstart == '0) &&
                            (ara_req_i.cvt_resize == CVT_SAME) &&
                            !(int'(ara_req_i.eew_vs2) > int'(ara_req_i.vtype.vsew))
              };
            end
          end else begin
            ara_req_ready_o = 1'b0;
          end
        end
      end

      WAIT: begin
        ara_req_ready_o = 1'b0;
        pe_req_d        = pe_req_o;
        pe_req_valid_d  = pe_req_valid_o;

        if (!pe_req_o.use_vd && !is_store(pe_req_o.op) && &operand_requester_ready)
          pe_req_valid_d = 1'b0;
        if (no_src_vrf(pe_req_o) && addrgen_ack_i)
          pe_req_valid_d = 1'b0;
        if (lsu_current_burst_exception_q)
          pe_req_valid_d = 1'b0;

        if ((is_load(pe_req_o.op) || is_store(pe_req_o.op)) && addrgen_ack_i) begin
          state_d                     = IDLE;
          ara_req_ready_o             = 1'b1;
          ara_resp_valid_o            = 1'b1;
          ara_resp_o.exception        = addrgen_exception_i;
          ara_resp_o.exception_vstart = addrgen_exception_vstart_i;
          ara_resp_o.fof_exception    = addrgen_fof_exception_i;
        end

        if (!pe_req_o.use_vd && !is_load(pe_req_o.op) && !is_store(pe_req_o.op)) begin
          if (pe_req_o.op inside {[VCPOP:VFIRST]}) begin
            if (pe_scalar_resp_valid_i) begin
              state_d                = IDLE;
              ara_req_ready_o        = 1'b1;
              ara_resp_valid_o       = 1'b1;
              ara_resp_o.resp        = pe_scalar_resp_i;
              pe_scalar_resp_ready_o = 1'b0;
            end
          end else begin
            if (!pe_req_valid_o && pe_scalar_resp_valid_i && !(|masku_vfu_running_d)) begin
              state_d                = IDLE;
              ara_req_ready_o        = 1'b1;
              ara_resp_valid_o       = 1'b1;
              ara_resp_o.resp        = pe_scalar_resp_i;
              pe_scalar_resp_ready_o = 1'b1;
            end
          end
        end
      end
    endcase

    for (int id = 0; id < NrVInsn; id++) global_hazard_table_d[id] &= vinsn_running_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin: p_sequencer_ff
    if (!rst_ni) begin
      state_q               <= IDLE;
      vreg_write_q          <= '0;
      vreg_read_vs1_q       <= '0;
      vreg_read_vs2_q       <= '0;
      vreg_read_vd_q        <= '0;
      vmask_read_q          <= '0;
      vinsn_meta_q          <= '0;
      pe_req_o              <= '0;
      pe_req_valid_o        <= 1'b0;
      global_hazard_table_o <= '0;
      masku_vfu_running_q   <= '0;
    end else begin
      state_q               <= state_d;
      vreg_write_q          <= vreg_write_d;
      vreg_read_vs1_q       <= vreg_read_vs1_d;
      vreg_read_vs2_q       <= vreg_read_vs2_d;
      vreg_read_vd_q        <= vreg_read_vd_d;
      vmask_read_q          <= vmask_read_d;
      vinsn_meta_q          <= vinsn_meta_d;
      pe_req_o              <= pe_req_d;
      pe_req_valid_o        <= pe_req_valid_d;
      global_hazard_table_o <= global_hazard_table_d;
      masku_vfu_running_q   <= masku_vfu_running_d;
    end
  end

  assign insn_queue_done[VFU_Alu]       = alu_vinsn_done_i;
  assign insn_queue_done[VFU_MFpu]      = mfpu_vinsn_done_i;
  assign insn_queue_done[VFU_LoadUnit]  = |pe_resp_i[NrLanes+OffsetLoad].vinsn_done;
  assign insn_queue_done[VFU_StoreUnit] = |pe_resp_i[NrLanes+OffsetStore].vinsn_done;
  assign insn_queue_done[VFU_MaskUnit]  = |pe_resp_i[NrLanes+OffsetMask].vinsn_done;
  assign insn_queue_done[VFU_SlideUnit] = |pe_resp_i[NrLanes+OffsetSlide].vinsn_done;
  assign insn_queue_done[VFU_None]      = insn_queue_cnt_up[VFU_None];

  always_comb begin
    target_vfus_vec                = target_vfus(ara_req_i.op);
    target_vfus_vec[VFU_MaskUnit] |= ~ara_req_i.vm;
  end

  for (genvar i = 0; i < NrVFUs; i++) begin : gen_seq_fu_cnt
    localparam CNT_WIDTH = idx_width(MaxVInsnQueueDepth + 1);
    counter #(
      .WIDTH           (CNT_WIDTH),
      .STICKY_OVERFLOW (0)
    ) i_insn_queue_cnt (
      .clk_i      (clk_i                 ),
      .rst_ni     (rst_ni                ),
      .clear_i    (1'b0                  ),
      .en_i       (insn_queue_cnt_en[i]  ),
      .load_i     (1'b0                  ),
      .down_i     (insn_queue_cnt_down[i]),
      .d_i        ('0                    ),
      .q_o        (insn_queue_cnt_q[i]   ),
      .overflow_o (/* Unconnected */     )
    );
    assign insn_queue_cnt_up[i]   = insn_issue_fire & target_vfus_vec[i];
    assign insn_queue_cnt_down[i] = insn_queue_done[i];
    assign insn_queue_cnt_en[i]   = insn_queue_cnt_up[i] ^ insn_queue_cnt_down[i];
    assign vinsn_queue_issue[i]   = ~target_vfus_vec[i] | (insn_queue_cnt_q[i] < InsnQueueDepth[i]);
  end

endmodule : ara_sequencer
