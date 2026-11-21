`timescale 1ns/1ps

module tb;
  import ara_pkg::*;
  import rvv_pkg::*;
  import cf_math_pkg::idx_width;

  localparam int unsigned NrLanes      = 2;
  localparam int unsigned VLEN         = 1024;
  localparam int unsigned VLENB        = VLEN / 8; // 128B = 16x64b per vreg (8 words/lane)
  localparam int unsigned NrBanks      = 8;
  localparam int unsigned NrPEs        = NrLanes + 4;
  localparam int unsigned WordsPerVReg = VLENB / NrLanes / 8; // 8
  localparam int unsigned VRFWords     = 32 * WordsPerVReg;   // 256
  typedef logic [$clog2(VLEN+1)-1:0] vlen_t;
  typedef logic [7:0]                vaddr_t;
  typedef logic [7:0]                strb_t;

  `include "ara/intf_typedef.svh"
  `include "ara/ara_typedef.svh"

  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  `CVA6_TYPEDEF_EXCEPTION(exception_t, CVA6Cfg)
  `CVA6_INTF_TYPEDEF_ACC_REQ(accelerator_req_t, CVA6Cfg, fpnew_pkg::roundmode_e)
  `CVA6_INTF_TYPEDEF_ACC_RESP(accelerator_resp_t, CVA6Cfg, exception_t)

  typedef struct packed {
    ara_op_e op;
    logic scale_vl;
    logic vm;
    rvv_pkg::vew_e eew_vmask;
    logic [4:0] vs1;
    logic use_vs1;
    opqueue_conversion_e conversion_vs1;
    rvv_pkg::vew_e eew_vs1;
    rvv_pkg::vew_e old_eew_vs1;
    logic [4:0] vs2;
    logic use_vs2;
    opqueue_conversion_e conversion_vs2;
    rvv_pkg::vew_e eew_vs2;
    logic use_vd_op;
    rvv_pkg::vew_e eew_vd_op;
    elen_t scalar_op;
    logic use_scalar_op;
    elen_t stride;
    logic is_stride_np2;
    logic [4:0] vd;
    logic use_vd;
    logic swap_vs2_vd_op;
    rvv_pkg::vlmul_e emul;
    logic [2:0] nf;
    logic fault_only_first;
    fpnew_pkg::roundmode_e fp_rm;
    logic wide_fp_imm;
    resize_e cvt_resize;
    vlen_t vl;
    vlen_t vstart;
    rvv_pkg::vtype_t vtype;
    logic token;
  } ara_req_t;

  typedef struct packed {
    elen_t resp;
    exception_t exception;
    logic fof_exception;
    vlen_t exception_vstart;
  } ara_resp_t;

  typedef struct packed {
    vid_t id;
    logic [4:0] vs;
    logic scale_vl;
    resize_e cvt_resize;
    logic is_reduct;
    logic is_slide;
    rvv_pkg::vew_e eew;
    opqueue_conversion_e conv;
    target_fu_e target_fu;
    rvv_pkg::vtype_t vtype;
    vlen_t vl;
    vlen_t vstart;
    logic [NrVInsn-1:0] hazard;
  } operand_request_cmd_t;

  typedef struct packed {
    rvv_pkg::vew_e eew;
    vlen_t elem_count;
    opqueue_conversion_e conv;
    logic [1:0] ntr_red;
    logic is_reduct;
    target_fu_e target_fu;
  } operand_queue_cmd_t;

  typedef struct packed {
    vid_t id;
    ara_op_e op;
    logic vm;
    logic use_vs1;
    logic use_vs2;
    logic use_vd_op;
    elen_t scalar_op;
    logic use_scalar_op;
    vfu_e vfu;
    logic [4:0] vd;
    logic use_vd;
    logic swap_vs2_vd_op;
    fpnew_pkg::roundmode_e fp_rm;
    logic wide_fp_imm;
    resize_e cvt_resize;
    vlen_t vl;
    vlen_t vstart;
    rvv_pkg::vtype_t vtype;
  } vfu_operation_t;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #2.5 clk = ~clk;

  int seed = 101;
  int fail_cnt = 0;

  accelerator_req_t  acc_req;
  accelerator_resp_t acc_resp;
  ara_req_t          ara_req;
  ara_resp_t         ara_resp;
  logic              ara_req_valid, ara_req_ready, ara_resp_valid, ara_idle;
  logic [NrLanes-1:0][4:0] fflags_ex;
  logic [NrLanes-1:0]      fflags_ex_valid;
  logic                    lsu_ex_flush, lsu_ex_flush_done;
  logic [NrLanes-1:0]      vxsat_flag;
  vxrm_t [NrLanes-1:0]     alu_vxrm;
  logic                    core_st_pending, load_complete, store_complete, store_pending;

  pe_req_t                         pe_req;
  logic                            pe_req_valid;
  logic [NrVInsn-1:0]              pe_vinsn_running;
  logic [NrPEs-1:0]                pe_req_ready;
  pe_resp_t [NrPEs-1:0]            pe_resp;
  pe_resp_t [NrLanes-1:0]          pe_resp_lane;
  pe_resp_t                        pe_resp_ld, pe_resp_st, pe_resp_mk, pe_resp_sld;
  always_comb begin
    pe_resp = '0;
    for (int l = 0; l < NrLanes; l++) pe_resp[l] = pe_resp_lane[l];
    pe_resp[NrLanes + OffsetLoad]  = pe_resp_ld;
    pe_resp[NrLanes + OffsetStore] = pe_resp_st;
    pe_resp[NrLanes + OffsetMask]  = pe_resp_mk;
    pe_resp[NrLanes + OffsetSlide] = pe_resp_sld;
  end
  logic [NrLanes-1:0]              lane_alu_done_pulse, lane_mfpu_done_pulse;
  logic [NrVInsn-1:0][NrVInsn-1:0] ght;
  elen_t                           pe_scalar_resp;
  logic                            pe_scalar_resp_valid, pe_scalar_resp_ready;
  logic                            addrgen_ack;
  exception_t                      addrgen_exception;
  vlen_t                           addrgen_exception_vstart;
  logic                            addrgen_fof_exception;
  logic                            lsu_current_burst_exception;

  ara_dispatcher #(
    .CVA6Cfg           (CVA6Cfg),
    .NrLanes           (NrLanes),
    .VLEN              (VLEN),
    .SegSupport        (SegSupportDisable),
    .ara_req_t         (ara_req_t),
    .ara_resp_t        (ara_resp_t),
    .accelerator_req_t (accelerator_req_t),
    .accelerator_resp_t(accelerator_resp_t)
  ) i_dispatcher (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .acc_req_i          (acc_req),
    .acc_resp_o         (acc_resp),
    .ara_req_o          (ara_req),
    .ara_req_valid_o    (ara_req_valid),
    .ara_req_ready_i    (ara_req_ready),
    .ara_resp_i         (ara_resp),
    .ara_resp_valid_i   (ara_resp_valid),
    .ara_idle_i         (ara_idle),
    .fflags_ex_i        (fflags_ex),
    .fflags_ex_valid_i  (fflags_ex_valid),
    .lsu_ex_flush_o     (lsu_ex_flush),
    .lsu_ex_flush_done_i(lsu_ex_flush_done),
    .vxsat_flag_i       (vxsat_flag),
    .alu_vxrm_o         (alu_vxrm),
    .core_st_pending_o  (core_st_pending),
    .load_complete_i    (load_complete),
    .store_complete_i   (store_complete),
    .store_pending_i    (store_pending)
  );

  ara_sequencer #(
    .NrLanes    (NrLanes),
    .VLEN       (VLEN),
    .ara_req_t  (ara_req_t),
    .ara_resp_t (ara_resp_t),
    .pe_req_t   (pe_req_t),
    .pe_resp_t  (pe_resp_t),
    .exception_t(exception_t)
  ) i_sequencer (
    .clk_i                        (clk),
    .rst_ni                       (rst_n),
    .ara_req_i                    (ara_req),
    .ara_req_valid_i              (ara_req_valid),
    .ara_req_ready_o              (ara_req_ready),
    .ara_resp_o                   (ara_resp),
    .ara_resp_valid_o             (ara_resp_valid),
    .ara_idle_o                   (ara_idle),
    .pe_req_o                     (pe_req),
    .pe_req_valid_o               (pe_req_valid),
    .pe_vinsn_running_o           (pe_vinsn_running),
    .pe_req_ready_i               (pe_req_ready),
    .pe_resp_i                    (pe_resp),
    .alu_vinsn_done_i             (lane_alu_done_pulse[0]),
    .mfpu_vinsn_done_i            (lane_mfpu_done_pulse[0]),
    .global_hazard_table_o        (ght),
    .pe_scalar_resp_i             (pe_scalar_resp),
    .pe_scalar_resp_valid_i       (pe_scalar_resp_valid),
    .pe_scalar_resp_ready_o       (pe_scalar_resp_ready),
    .addrgen_ack_i                (addrgen_ack),
    .addrgen_exception_i          (addrgen_exception),
    .addrgen_exception_vstart_i   (addrgen_exception_vstart),
    .addrgen_fof_exception_i      (addrgen_fof_exception),
    .lsu_current_burst_exception_i(lsu_current_burst_exception)
  );

  // Per-lane signals & VRF
  elen_t vrf_mem [NrLanes][NrBanks][32];

  operand_request_cmd_t [NrLanes-1:0][NrOperandQueues-1:0] op_req_cmd;
  logic                 [NrLanes-1:0][NrOperandQueues-1:0] op_req_valid, op_req_ready;
  operand_queue_cmd_t   [NrLanes-1:0][NrOperandQueues-1:0] oq_cmd;
  logic                 [NrLanes-1:0][NrOperandQueues-1:0] oq_cmd_valid, oq_ready, oq_issued;
  vfu_operation_t       [NrLanes-1:0]                      vfu_op;
  logic                 [NrLanes-1:0]                      vfu_op_valid;
  logic                 [NrLanes-1:0]                      alu_ready, mfpu_ready;
  logic                 [NrLanes-1:0][NrVInsn-1:0]         alu_vinsn_done, mfpu_vinsn_done;
  logic                 [NrLanes-1:0]                      mask_b_cmd_pop;
  logic                 [NrLanes-1:0]                      masku_vrgat_valid, masku_vrgat_ready;
  vrgat_req_t           [NrLanes-1:0]                      masku_vrgat_req;

  logic   [NrLanes-1:0] alu_res_req, alu_res_gnt;
  vid_t   [NrLanes-1:0] alu_res_id;
  vaddr_t [NrLanes-1:0] alu_res_addr;
  elen_t  [NrLanes-1:0] alu_res_wdata;
  strb_t  [NrLanes-1:0] alu_res_be;

  logic   [NrLanes-1:0] mfpu_res_req, mfpu_res_gnt;
  vid_t   [NrLanes-1:0] mfpu_res_id;
  vaddr_t [NrLanes-1:0] mfpu_res_addr;
  elen_t  [NrLanes-1:0] mfpu_res_wdata;
  strb_t  [NrLanes-1:0] mfpu_res_be;

  logic   [NrLanes-1:0] masku_res_req, masku_res_gnt, masku_res_final_gnt;
  vid_t   [NrLanes-1:0] masku_res_id;
  vaddr_t [NrLanes-1:0] masku_res_addr;
  elen_t  [NrLanes-1:0] masku_res_wdata;
  strb_t  [NrLanes-1:0] masku_res_be;

  logic   [NrLanes-1:0] sldu_res_req, sldu_res_gnt, sldu_res_final_gnt;
  vid_t   [NrLanes-1:0] sldu_res_id;
  vaddr_t [NrLanes-1:0] sldu_res_addr;
  elen_t  [NrLanes-1:0] sldu_res_wdata;
  strb_t  [NrLanes-1:0] sldu_res_be;

  logic   [NrLanes-1:0] ldu_res_req, ldu_res_gnt, ldu_res_final_gnt;
  vid_t   [NrLanes-1:0] ldu_res_id;
  vaddr_t [NrLanes-1:0] ldu_res_addr;
  elen_t  [NrLanes-1:0] ldu_res_wdata;
  strb_t  [NrLanes-1:0] ldu_res_be;

  // Operand queue FIFOs (64 deep) + 1-cycle synchronous VRF read pipe
  elen_t  oq_fifo [NrLanes][NrOperandQueues][64];
  int     oq_wr_ptr [NrLanes][NrOperandQueues];
  int     oq_rd_ptr [NrLanes][NrOperandQueues];
  int     oq_count  [NrLanes][NrOperandQueues];
  logic   oq_pop    [NrLanes][NrOperandQueues];
  opqueue_conversion_e maskb_conv_q [NrLanes];

  for (genvar l = 0; l < NrLanes; l++) begin : gen_lanes
    logic     [NrBanks-1:0] vrf_req, vrf_wen;
    vaddr_t   [NrBanks-1:0] vrf_addr;
    elen_t    [NrBanks-1:0] vrf_wdata;
    strb_t    [NrBanks-1:0] vrf_be;
    opqueue_e [NrBanks-1:0] vrf_tgt_oq;
    logic                   lsu_ex_flush_ls, lsu_ex_flush_or;
    logic     [NrBanks-1:0] rd_valid_q;
    opqueue_e [NrBanks-1:0] rd_tgt_q;
    elen_t    [NrBanks-1:0] rd_data_q;

    lane_sequencer #(
      .NrLanes              (NrLanes),
      .pe_req_t             (pe_req_t),
      .pe_resp_t            (pe_resp_t),
      .operand_request_cmd_t(operand_request_cmd_t),
      .vfu_operation_t      (vfu_operation_t)
    ) i_lane_seq (
      .clk_i                  (clk),
      .rst_ni                 (rst_n),
      .lane_id_i              (l[idx_width(NrLanes)-1:0]),
      .pe_req_i               (pe_req),
      .pe_req_valid_i         (pe_req_valid),
      .pe_vinsn_running_i     (pe_vinsn_running),
      .pe_req_ready_o         (pe_req_ready[l]),
      .pe_resp_o              (pe_resp_lane[l]),
      .lsu_ex_flush_i         (lsu_ex_flush),
      .lsu_ex_flush_o         (lsu_ex_flush_ls),
      .operand_request_o      (op_req_cmd[l]),
      .operand_request_valid_o(op_req_valid[l]),
      .operand_request_ready_i(op_req_ready[l]),
      .alu_vinsn_done_o       (lane_alu_done_pulse[l]),
      .mfpu_vinsn_done_o      (lane_mfpu_done_pulse[l]),
      .mask_b_cmd_pop_i       (mask_b_cmd_pop[l]),
      .vfu_operation_o        (vfu_op[l]),
      .vfu_operation_valid_o  (vfu_op_valid[l]),
      .alu_ready_i            (alu_ready[l]),
      .alu_vinsn_done_i       (alu_vinsn_done[l]),
      .mfpu_ready_i           (mfpu_ready[l]),
      .mfpu_vinsn_done_i      (mfpu_vinsn_done[l]),
      .masku_vrgat_req_valid_i(masku_vrgat_valid[l]),
      .masku_vrgat_req_ready_o(masku_vrgat_ready[l]),
      .masku_vrgat_req_i      (masku_vrgat_req[l])
    );

    operand_requester #(
      .NrLanes              (NrLanes),
      .VLEN                 (VLEN),
      .NrBanks              (NrBanks),
      .vaddr_t              (vaddr_t),
      .operand_request_cmd_t(operand_request_cmd_t),
      .operand_queue_cmd_t  (operand_queue_cmd_t)
    ) i_op_req (
      .clk_i                    (clk),
      .rst_ni                   (rst_n),
      .global_hazard_table_i    (ght),
      .operand_request_i        (op_req_cmd[l]),
      .operand_request_valid_i  (op_req_valid[l]),
      .operand_request_ready_o  (op_req_ready[l]),
      .lsu_ex_flush_i           (lsu_ex_flush_ls),
      .lsu_ex_flush_o           (lsu_ex_flush_or),
      .vrf_req_o                (vrf_req),
      .vrf_addr_o               (vrf_addr),
      .vrf_wen_o                (vrf_wen),
      .vrf_wdata_o              (vrf_wdata),
      .vrf_be_o                 (vrf_be),
      .vrf_tgt_opqueue_o        (vrf_tgt_oq),
      .operand_queue_ready_i    (oq_ready[l]),
      .operand_issued_o         (oq_issued[l]),
      .operand_queue_cmd_o      (oq_cmd[l]),
      .operand_queue_cmd_valid_o(oq_cmd_valid[l]),
      .alu_result_req_i         (alu_res_req[l]),
      .alu_result_id_i          (alu_res_id[l]),
      .alu_result_addr_i        (alu_res_addr[l]),
      .alu_result_wdata_i       (alu_res_wdata[l]),
      .alu_result_be_i          (alu_res_be[l]),
      .alu_result_gnt_o         (alu_res_gnt[l]),
      .mfpu_result_req_i        (mfpu_res_req[l]),
      .mfpu_result_id_i         (mfpu_res_id[l]),
      .mfpu_result_addr_i       (mfpu_res_addr[l]),
      .mfpu_result_wdata_i      (mfpu_res_wdata[l]),
      .mfpu_result_be_i         (mfpu_res_be[l]),
      .mfpu_result_gnt_o        (mfpu_res_gnt[l]),
      .masku_result_req_i       (masku_res_req[l]),
      .masku_result_id_i        (masku_res_id[l]),
      .masku_result_addr_i      (masku_res_addr[l]),
      .masku_result_wdata_i     (masku_res_wdata[l]),
      .masku_result_be_i        (masku_res_be[l]),
      .masku_result_gnt_o       (masku_res_gnt[l]),
      .masku_result_final_gnt_o (masku_res_final_gnt[l]),
      .sldu_result_req_i        (sldu_res_req[l]),
      .sldu_result_id_i         (sldu_res_id[l]),
      .sldu_result_addr_i       (sldu_res_addr[l]),
      .sldu_result_wdata_i      (sldu_res_wdata[l]),
      .sldu_result_be_i         (sldu_res_be[l]),
      .sldu_result_gnt_o        (sldu_res_gnt[l]),
      .sldu_result_final_gnt_o  (sldu_res_final_gnt[l]),
      .ldu_result_req_i         (ldu_res_req[l]),
      .ldu_result_id_i          (ldu_res_id[l]),
      .ldu_result_addr_i        (ldu_res_addr[l]),
      .ldu_result_wdata_i       (ldu_res_wdata[l]),
      .ldu_result_be_i          (ldu_res_be[l]),
      .ldu_result_gnt_o         (ldu_res_gnt[l]),
      .ldu_result_final_gnt_o   (ldu_res_final_gnt[l])
    );

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        rd_valid_q      <= '0;
        rd_tgt_q        <= '0;
        rd_data_q       <= '0;
        maskb_conv_q[l] <= OpQueueConversionNone;
        for (int q = 0; q < NrOperandQueues; q++) begin
          oq_wr_ptr[l][q] <= 0;
          oq_rd_ptr[l][q] <= 0;
          oq_count[l][q]  <= 0;
        end
      end else begin
        if (oq_cmd_valid[l][MaskB]) maskb_conv_q[l] <= oq_cmd[l][MaskB].conv;
        for (int b = 0; b < NrBanks; b++) begin
          rd_valid_q[b] <= vrf_req[b] && !vrf_wen[b];
          rd_tgt_q[b]   <= vrf_tgt_oq[b];
          if (vrf_req[b]) begin
            if (vrf_wen[b]) begin
              for (int by = 0; by < 8; by++)
                if (vrf_be[b][by]) vrf_mem[l][b][vrf_addr[b][4:0]][by*8 +: 8] <= vrf_wdata[b][by*8 +: 8];
            end else begin
              rd_data_q[b] <= vrf_mem[l][b][vrf_addr[b][4:0]];
            end
          end
        end
        for (int q = 0; q < NrOperandQueues; q++) begin
          automatic int delta = 0;
          for (int b = 0; b < NrBanks; b++) begin
            if (rd_valid_q[b] && (int'(rd_tgt_q[b]) == q)) begin
              oq_fifo[l][q][(oq_wr_ptr[l][q] + delta) % 64] <= rd_data_q[b];
              delta++;
            end
          end
          oq_wr_ptr[l][q] <= (oq_wr_ptr[l][q] + delta) % 64;
          if (oq_pop[l][q]) begin
            if (oq_count[l][q] + delta <= 0) begin
              $display("[FAIL] Lane %0d OpQueue %0d popped while empty!", l, q);
              fail_cnt <= fail_cnt + 1;
            end else begin
              oq_rd_ptr[l][q] <= (oq_rd_ptr[l][q] + 1) % 64;
              oq_count[l][q]  <= oq_count[l][q] + delta - 1;
            end
          end else begin
            oq_count[l][q] <= oq_count[l][q] + delta;
          end
        end
      end
    end

    for (genvar q = 0; q < NrOperandQueues; q++) begin : gen_oq_rdy
      assign oq_ready[l][q] = (oq_count[l][q] < 48);
    end
  end

  // Configurable latencies & test telemetry
  int cfg_alu_lat   = 1;
  int cfg_mfpu_lat  = 8;
  int cfg_sldu_lat  = 4;
  int cfg_masku_lat = 5;
  int cfg_lsu_lat   = 3;
  logic cfg_force_vxsat  = 1'b0;
  logic cfg_force_fflags = 1'b0;

  elen_t ext_mem [0:511];
  elen_t masku_scalar_res;
  logic  masku_scalar_valid;
  logic  [NrLanes-1:0] masku_pop_maskb;
  logic  masku_busy;

  int max_concurrent_vinsn;
  int reshuffle_issue_cnt;
  int vfu_active_cnt [NrVFUs];

  localparam int unsigned ExpQueueDepth [NrVFUs] = '{
    ValuInsnQueueDepth, MfpuInsnQueueDepth, SlduInsnQueueDepth,
    MaskuInsnQueueDepth, VlduInsnQueueDepth, VstuInsnQueueDepth, NoneInsnQueueDepth
  };

  function automatic int words_for_oq_cmd(operand_queue_cmd_t c);
    int epw;
    epw = 1 << (int'(EW64) - int'(c.eew));
    return (int'(c.elem_count) + epw - 1) / epw;
  endfunction

  // Record exact expected word counts & target FU per (lane, queue) command FIFO
  int         cmd_words_fifo [NrLanes][NrOperandQueues][16];
  target_fu_e cmd_tgt_fifo   [NrLanes][NrOperandQueues][16];
  int         cmd_wr_ptr     [NrLanes][NrOperandQueues];
  int         cmd_rd_ptr     [NrLanes][NrOperandQueues];
  int         cmd_cnt        [NrLanes][NrOperandQueues];
  logic       cmd_pop        [NrLanes][NrOperandQueues];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int l = 0; l < NrLanes; l++)
        for (int q = 0; q < NrOperandQueues; q++) begin
          cmd_wr_ptr[l][q] <= 0;
          cmd_rd_ptr[l][q] <= 0;
          cmd_cnt[l][q]    <= 0;
        end
    end else begin
      for (int l = 0; l < NrLanes; l++)
        for (int q = 0; q < NrOperandQueues; q++) begin
          automatic int push_c = oq_cmd_valid[l][q] ? 1 : 0;
          automatic int pop_c  = cmd_pop[l][q] ? 1 : 0;
          if (oq_cmd_valid[l][q]) begin
            cmd_words_fifo[l][q][cmd_wr_ptr[l][q]] <= words_for_oq_cmd(oq_cmd[l][q]);
            cmd_tgt_fifo[l][q][cmd_wr_ptr[l][q]]   <= oq_cmd[l][q].target_fu;
            cmd_wr_ptr[l][q] <= (cmd_wr_ptr[l][q] + 1) % 16;
          end
          if (cmd_pop[l][q]) cmd_rd_ptr[l][q] <= (cmd_rd_ptr[l][q] + 1) % 16;
          cmd_cnt[l][q] <= cmd_cnt[l][q] + push_c - pop_c;
        end
    end
  end

  // Top-level scalar response mux (matches ara.sv lines 304-320)
  elen_t maskb0_raw, maskb0_ext;
  always_comb begin
    maskb0_raw = oq_fifo[0][MaskB][oq_rd_ptr[0][MaskB]];
    unique case (maskb_conv_q[0])
      OpQueueConversionSExt8: maskb0_ext = {{56{maskb0_raw[7]}},  maskb0_raw[7:0]};
      OpQueueConversionSExt4: maskb0_ext = {{48{maskb0_raw[15]}}, maskb0_raw[15:0]};
      OpQueueConversionSExt2: maskb0_ext = {{32{maskb0_raw[31]}}, maskb0_raw[31:0]};
      default:                maskb0_ext = maskb0_raw;
    endcase
    pe_scalar_resp       = (pe_req.op inside {[VCPOP:VFIRST]}) ? masku_scalar_res   : maskb0_ext;
    pe_scalar_resp_valid = (pe_req.op inside {[VCPOP:VFIRST]}) ? masku_scalar_valid : (oq_count[0][MaskB] > 0);
  end

  // Chaining concurrency & RESHUFFLE telemetry + scalar pop checks
  logic pe_req_seen_id_valid;
  vid_t pe_req_seen_id;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      max_concurrent_vinsn <= 0;
      reshuffle_issue_cnt  <= 0;
      pe_req_seen_id_valid <= 1'b0;
      pe_req_seen_id       <= '0;
    end else begin
      automatic int active_n = 0;
      for (int i = 0; i < NrVInsn; i++) if (pe_vinsn_running[i]) active_n++;
      if (active_n > max_concurrent_vinsn) max_concurrent_vinsn <= active_n;

      if (!pe_req_valid) pe_req_seen_id_valid <= 1'b0;
      else if (!pe_req_seen_id_valid || (pe_req.id != pe_req_seen_id)) begin
        pe_req_seen_id_valid <= 1'b1;
        pe_req_seen_id       <= pe_req.id;
        if (pe_req.op == VSLIDEDOWN && pe_req.scale_vl && (pe_req.stride == '0)) begin
          reshuffle_issue_cnt <= reshuffle_issue_cnt + 1;
          if (pe_req.emul != LMUL_1 || pe_req.vtype.vlmul != LMUL_1) begin
            $display("[FAIL] RESHUFFLE micro-op issued with non-LMUL_1 emul=%0d vlmul=%0d", pe_req.emul, pe_req.vtype.vlmul);
            fail_cnt <= fail_cnt + 1;
          end
        end
      end

      if (pe_scalar_resp_ready && (pe_req.op inside {[VCPOP:VFIRST]})) begin
        $display("[FAIL] pe_scalar_resp_ready asserted on VCPOP/VFIRST (illegally pops MaskB)!");
        fail_cnt <= fail_cnt + 1;
      end
      if (pe_scalar_resp_ready && masku_busy) begin
        $display("[FAIL] pe_scalar_resp_ready asserted while MASKU instruction is active!");
        fail_cnt <= fail_cnt + 1;
      end
    end
  end

  // VFU Queue Depth Monitor (tracks exact issue/done per VFU against InsnQueueDepth)
  logic vfu_mon_sync_en;
  vid_t vfu_mon_last_id;
  function automatic logic [NrVFUs-1:0] mon_target_vfus(ara_op_e op, logic vm);
    logic [NrVFUs-1:0] tv = '0;
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vfu_mon_sync_en <= 1'b0;
      vfu_mon_last_id <= '0;
      for (int u = 0; u < NrVFUs; u++) vfu_active_cnt[u] <= 0;
    end else begin
      automatic logic new_pe_issue = 1'b0;
      automatic logic [NrVFUs-1:0] tv = mon_target_vfus(pe_req.op, pe_req.vm);
      automatic logic [NrVFUs-1:0] dn = '0;
      dn[VFU_Alu]       = lane_alu_done_pulse[0];
      dn[VFU_MFpu]      = lane_mfpu_done_pulse[0];
      dn[VFU_LoadUnit]  = |pe_resp[NrLanes+OffsetLoad].vinsn_done;
      dn[VFU_StoreUnit] = |pe_resp[NrLanes+OffsetStore].vinsn_done;
      dn[VFU_MaskUnit]  = |pe_resp[NrLanes+OffsetMask].vinsn_done;
      dn[VFU_SlideUnit] = |pe_resp[NrLanes+OffsetSlide].vinsn_done;

      if (!pe_req_valid) vfu_mon_sync_en <= 1'b0;
      else if (!vfu_mon_sync_en || (pe_req.id != vfu_mon_last_id)) begin
        vfu_mon_sync_en <= 1'b1;
        vfu_mon_last_id <= pe_req.id;
        new_pe_issue    = 1'b1;
      end
      dn[VFU_None] = new_pe_issue && tv[VFU_None];

      for (int u = 0; u < NrVFUs; u++) begin
        automatic int nxt = vfu_active_cnt[u] + ((new_pe_issue && tv[u]) ? 1 : 0) - (dn[u] ? 1 : 0);
        if (nxt > int'(ExpQueueDepth[u])) begin
          $display("[FAIL] VFU %0d InsnQueueDepth overflow: active=%0d > max=%0d (op=%0d)", u, nxt, ExpQueueDepth[u], pe_req.op);
          fail_cnt <= fail_cnt + 1;
        end
        vfu_active_cnt[u] <= nxt;
      end
    end
  end

  // Shared synchronization flags between lane VFUs and external PEs (MASKU / SLDU)
  elen_t masku_src_a    [NrLanes][64];
  elen_t masku_src_b    [NrLanes][64];
  int    masku_prep_seq [NrLanes][NrVInsn];
  elen_t red_lane_sum   [NrLanes][NrVInsn];
  int    red_lane_seq   [NrLanes][NrVInsn];

  logic [NrLanes-1:0] valu_pop_a, valu_pop_b, valu_cmd_pop_a, valu_cmd_pop_b;
  logic [NrLanes-1:0] mfpu_pop_a, mfpu_pop_b, mfpu_pop_c, mfpu_cmd_pop_a, mfpu_cmd_pop_b, mfpu_cmd_pop_c;
  logic [NrLanes-1:0] ext_pop_sta, ext_pop_sld, ext_pop_maskm;
  logic [NrLanes-1:0] ext_cmd_pop_sta, ext_cmd_pop_sld, ext_cmd_pop_maskm, ext_cmd_pop_maskb;

  always_comb begin
    for (int l = 0; l < NrLanes; l++) begin
      for (int q = 0; q < NrOperandQueues; q++) begin
        oq_pop[l][q]  = 1'b0;
        cmd_pop[l][q] = 1'b0;
      end
      oq_pop[l][AluA]          = valu_pop_a[l];
      oq_pop[l][AluB]          = valu_pop_b[l];
      oq_pop[l][MulFPUA]       = mfpu_pop_a[l];
      oq_pop[l][MulFPUB]       = mfpu_pop_b[l];
      oq_pop[l][MulFPUC]       = mfpu_pop_c[l];
      oq_pop[l][StA]           = ext_pop_sta[l];
      oq_pop[l][SlideAddrGenA] = ext_pop_sld[l];
      oq_pop[l][MaskM]         = ext_pop_maskm[l];
      oq_pop[l][MaskB]         = masku_pop_maskb[l] | ((l == 0) ? pe_scalar_resp_ready : 1'b0);

      cmd_pop[l][AluA]          = valu_cmd_pop_a[l];
      cmd_pop[l][AluB]          = valu_cmd_pop_b[l];
      cmd_pop[l][MulFPUA]       = mfpu_cmd_pop_a[l];
      cmd_pop[l][MulFPUB]       = mfpu_cmd_pop_b[l];
      cmd_pop[l][MulFPUC]       = mfpu_cmd_pop_c[l];
      cmd_pop[l][StA]           = ext_cmd_pop_sta[l];
      cmd_pop[l][SlideAddrGenA] = ext_cmd_pop_sld[l];
      cmd_pop[l][MaskM]         = ext_cmd_pop_maskm[l];
      cmd_pop[l][MaskB]         = ext_cmd_pop_maskb[l] | ((l == 0) ? pe_scalar_resp_ready : 1'b0);
    end
  end

  // Per-lane VALU & VMFPU streaming models
  for (genvar l = 0; l < NrLanes; l++) begin : gen_lane_vfus
    // VALU queue & FSM
    vfu_operation_t valu_q [4];
    int valu_wr, valu_rd, valu_cnt;
    enum int { ALU_IDLE, ALU_PREP_CMD, ALU_FETCH, ALU_WAIT_LAT, ALU_WRITE } alu_st;
    vfu_operation_t cur_alu;
    int alu_rem_a, alu_rem_b, alu_tot_w, alu_w_idx, alu_lat_cnt;
    elen_t alu_cur_a, alu_cur_b, alu_acc;
    logic alu_got_a, alu_got_b, alu_got_b2;

    assign alu_ready[l] = (valu_cnt < 4);

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        valu_wr <= 0; valu_rd <= 0; valu_cnt <= 0;
        alu_st <= ALU_IDLE;
        alu_vinsn_done[l] <= '0;
        alu_res_req[l] <= 1'b0; alu_res_id[l] <= '0; alu_res_addr[l] <= '0; alu_res_wdata[l] <= '0; alu_res_be[l] <= '0;
        valu_pop_a[l] <= 1'b0; valu_pop_b[l] <= 1'b0; valu_cmd_pop_a[l] <= 1'b0; valu_cmd_pop_b[l] <= 1'b0;
        vxsat_flag[l] <= 1'b0;
      end else begin
        automatic logic push_v = vfu_op_valid[l] && alu_ready[l] &&
                                 (vfu_op[l].op inside {[VADD:VWREDSUM], [VMSEQ:VMXNOR], [VRGATHER:VCOMPRESS]});
        automatic logic pop_v = 1'b0;
        alu_vinsn_done[l] <= '0;
        valu_pop_a[l] <= 1'b0; valu_pop_b[l] <= 1'b0; valu_cmd_pop_a[l] <= 1'b0; valu_cmd_pop_b[l] <= 1'b0;
        vxsat_flag[l] <= 1'b0;

        if (push_v) begin
          valu_q[valu_wr] <= vfu_op[l];
          valu_wr <= (valu_wr + 1) % 4;
        end

        case (alu_st)
          ALU_IDLE: begin
            if (valu_cnt > 0) begin
              cur_alu   <= valu_q[valu_rd];
              valu_rd   <= (valu_rd + 1) % 4;
              pop_v      = 1'b1;
              alu_w_idx <= 0;
              alu_acc   <= '0;
              alu_st    <= ALU_PREP_CMD;
            end
          end
          ALU_PREP_CMD: begin
            automatic logic need_a = cur_alu.use_vs1 && !(cur_alu.op inside {[VMFEQ:VMFGE]});
            automatic logic need_b = cur_alu.use_vs2 && !(cur_alu.op inside {[VMFEQ:VMFGE], [VRGATHER:VCOMPRESS]});
            if ((!need_a || cmd_cnt[l][AluA] > 0) && (!need_b || cmd_cnt[l][AluB] > 0)) begin
              automatic int epw = 1 << (int'(EW64) - int'(cur_alu.vtype.vsew));
              alu_rem_a <= need_a ? cmd_words_fifo[l][AluA][cmd_rd_ptr[l][AluA]] : 0;
              alu_rem_b <= need_b ? cmd_words_fifo[l][AluB][cmd_rd_ptr[l][AluB]] : 0;
              valu_cmd_pop_a[l] <= need_a;
              valu_cmd_pop_b[l] <= need_b;
              if (cur_alu.op inside {[VMSEQ:VMXNOR], [VRGATHER:VCOMPRESS]})
                alu_tot_w <= need_b ? cmd_words_fifo[l][AluB][cmd_rd_ptr[l][AluB]] :
                            (need_a ? cmd_words_fifo[l][AluA][cmd_rd_ptr[l][AluA]] : 0);
              else if (cur_alu.op inside {[VREDSUM:VWREDSUM]})
                alu_tot_w <= need_b ? cmd_words_fifo[l][AluB][cmd_rd_ptr[l][AluB]] : 1;
              else
                alu_tot_w <= (int'(cur_alu.vl) + epw - 1) / epw;
              alu_got_a <= !need_a; alu_got_b <= !need_b; alu_got_b2 <= 1'b1;
              alu_st    <= ALU_FETCH;
            end
          end
          ALU_FETCH: begin
            if (alu_w_idx >= alu_tot_w && alu_rem_a == 0 && alu_rem_b == 0) begin
              if (cur_alu.op inside {[VMSEQ:VMXNOR], [VRGATHER:VCOMPRESS]})
                masku_prep_seq[l][cur_alu.id] <= masku_prep_seq[l][cur_alu.id] + 1;
              if (cur_alu.op inside {[VREDSUM:VWREDSUM]}) begin
                if (l == 1) begin
                  red_lane_sum[1][cur_alu.id]   <= alu_acc;
                  red_lane_seq[1][cur_alu.id]   <= red_lane_seq[1][cur_alu.id] + 1;
                  alu_vinsn_done[1][cur_alu.id] <= 1'b1;
                  alu_st <= ALU_IDLE;
                end else if (red_lane_seq[1][cur_alu.id] > red_lane_seq[0][cur_alu.id]) begin
                  red_lane_seq[0][cur_alu.id] <= red_lane_seq[0][cur_alu.id] + 1;
                  alu_res_req[0]   <= 1'b1;
                  alu_res_id[0]    <= cur_alu.id;
                  alu_res_addr[0]  <= vaddr_t'(vaddr(cur_alu.vd, NrLanes, VLEN));
                  alu_res_wdata[0] <= alu_acc + red_lane_sum[1][cur_alu.id];
                  alu_res_be[0]    <= 8'hFF;
                  alu_st           <= ALU_WRITE;
                end
              end else begin
                alu_vinsn_done[l][cur_alu.id] <= 1'b1;
                alu_st <= ALU_IDLE;
              end
            end else begin
              automatic logic take_a = !alu_got_a && (alu_rem_a > 0) && (oq_count[l][AluA] > 0) && !valu_pop_a[l];
              automatic logic take_b = !alu_got_b && (alu_rem_b > 0) && (oq_count[l][AluB] > 0) && !valu_pop_b[l];
              if (take_a) begin
                alu_cur_a     <= oq_fifo[l][AluA][oq_rd_ptr[l][AluA]];
                valu_pop_a[l] <= 1'b1;
                alu_rem_a     <= alu_rem_a - 1;
                alu_got_a     <= 1'b1;
              end else if (alu_rem_a == 0) alu_got_a <= 1'b1;

              if (take_b) begin
                alu_cur_b     <= oq_fifo[l][AluB][oq_rd_ptr[l][AluB]];
                valu_pop_b[l] <= 1'b1;
                alu_rem_b     <= alu_rem_b - 1;
                if (cur_alu.cvt_resize == CVT_NARROW && alu_got_b2 && alu_rem_b > 1)
                  alu_got_b2 <= 1'b0;
                else begin
                  alu_got_b  <= 1'b1;
                  alu_got_b2 <= 1'b1;
                end
              end else if (alu_rem_b == 0) alu_got_b <= 1'b1;

              if ((alu_got_a || take_a || alu_rem_a == 0) &&
                  (alu_got_b || (take_b && !(cur_alu.cvt_resize == CVT_NARROW && alu_got_b2 && alu_rem_b > 1)) || alu_rem_b == 0)) begin
                alu_lat_cnt <= (cfg_alu_lat > 1) ? (cfg_alu_lat - 1) : 0;
                alu_st      <= ALU_WAIT_LAT;
              end
            end
          end
          ALU_WAIT_LAT: begin
            if (alu_lat_cnt > 0) alu_lat_cnt <= alu_lat_cnt - 1;
            else begin
              automatic elen_t op_a = cur_alu.use_scalar_op ? cur_alu.scalar_op : alu_cur_a;
              automatic elen_t op_b = alu_cur_b;
              automatic elen_t res;
              unique case (cur_alu.op)
                VSUB:            res = op_b - op_a;
                VRSUB:           res = op_a - op_b;
                VXOR:            res = op_b ^ op_a;
                VAND:            res = op_b & op_a;
                VOR:             res = op_b | op_a;
                VAADDU, VAADD:   res = (op_b >> 1) + (op_a >> 1) + (op_b[0] & op_a[0]);
                VSADDU, VSADD:   res = ((op_b + op_a) < op_b) ? 64'hFFFF_FFFF_FFFF_FFFF : (op_b + op_a);
                VMERGE:          res = cur_alu.vm ? op_a : (vrf_mem[l][0][0][alu_w_idx & 63] ? op_a : op_b);
                VMVSX, VFMVSF:   res = (l == 0 && alu_w_idx == 0) ? cur_alu.scalar_op : op_b;
                default:         res = op_b + op_a;
              endcase
              if (cur_alu.op inside {[VMSEQ:VMXNOR], [VRGATHER:VCOMPRESS]}) begin
                if (alu_w_idx < 64) begin
                  masku_src_a[l][alu_w_idx] <= op_a;
                  masku_src_b[l][alu_w_idx] <= op_b;
                end
                alu_w_idx <= alu_w_idx + 1;
                alu_got_a <= (alu_rem_a == 0); alu_got_b <= (alu_rem_b == 0);
                alu_st    <= ALU_FETCH;
              end else if (cur_alu.op inside {[VREDSUM:VWREDSUM]}) begin
                alu_acc   <= ((alu_w_idx == 0) ? alu_cur_a : alu_acc) + op_b;
                alu_w_idx <= alu_w_idx + 1;
                alu_got_a <= 1'b1; alu_got_b <= (alu_rem_b == 0);
                alu_st    <= ALU_FETCH;
              end else if (cur_alu.use_vd) begin
                automatic logic m_en = cur_alu.vm ? 1'b1 : vrf_mem[l][0][0][alu_w_idx & 63];
                alu_res_req[l]   <= 1'b1;
                alu_res_id[l]    <= cur_alu.id;
                alu_res_addr[l]  <= vaddr_t'(vaddr(cur_alu.vd, NrLanes, VLEN) + alu_w_idx);
                alu_res_wdata[l] <= res;
                alu_res_be[l]    <= m_en ? 8'hFF : 8'h00;
                if ((cur_alu.op inside {VSADDU, VSADD}) && (alu_w_idx + 1 == alu_tot_w) &&
                    (cfg_force_vxsat || ((op_b + op_a) < op_b && m_en)))
                  vxsat_flag[l] <= 1'b1;
                alu_st <= ALU_WRITE;
              end else begin
                alu_w_idx <= alu_w_idx + 1;
                alu_st    <= ALU_FETCH;
              end
            end
          end
          ALU_WRITE: begin
            if (alu_res_gnt[l]) begin
              alu_res_req[l] <= 1'b0;
              if (cur_alu.op inside {[VREDSUM:VWREDSUM]}) begin
                alu_vinsn_done[l][cur_alu.id] <= 1'b1;
                alu_st <= ALU_IDLE;
              end else begin
                alu_w_idx <= alu_w_idx + 1;
                if (cur_alu.cvt_resize == CVT_WIDE && (alu_w_idx[0] == 1'b0)) begin
                  // Widening writes 2 vd words per source word
                  alu_got_a <= 1'b1; alu_got_b <= 1'b1;
                end else begin
                  alu_got_a <= (alu_rem_a == 0); alu_got_b <= (alu_rem_b == 0);
                end
                alu_st <= ALU_FETCH;
              end
            end
          end
        endcase
        valu_cnt <= valu_cnt + (push_v ? 1 : 0) - (pop_v ? 1 : 0);
      end
    end

    // VMFPU queue & FSM (configurable multi-cycle latency per word)
    vfu_operation_t mfpu_q [4];
    int mfpu_wr, mfpu_rd, mfpu_cnt;
    enum int { MFPU_IDLE, MFPU_PREP_CMD, MFPU_FETCH, MFPU_WAIT_LAT, MFPU_WRITE } mfpu_st;
    vfu_operation_t cur_mfpu;
    int mfpu_rem_a, mfpu_rem_b, mfpu_rem_c, mfpu_tot_w, mfpu_w_idx, mfpu_lat_cnt;
    elen_t mfpu_cur_a, mfpu_cur_b, mfpu_cur_c;
    logic mfpu_got_a, mfpu_got_b, mfpu_got_c;

    assign mfpu_ready[l] = (mfpu_cnt < 4);

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        mfpu_wr <= 0; mfpu_rd <= 0; mfpu_cnt <= 0;
        mfpu_st <= MFPU_IDLE;
        mfpu_vinsn_done[l] <= '0;
        mfpu_res_req[l] <= 1'b0; mfpu_res_id[l] <= '0; mfpu_res_addr[l] <= '0; mfpu_res_wdata[l] <= '0; mfpu_res_be[l] <= '0;
        mfpu_pop_a[l] <= 1'b0; mfpu_pop_b[l] <= 1'b0; mfpu_pop_c[l] <= 1'b0;
        mfpu_cmd_pop_a[l] <= 1'b0; mfpu_cmd_pop_b[l] <= 1'b0; mfpu_cmd_pop_c[l] <= 1'b0;
        fflags_ex[l] <= '0; fflags_ex_valid[l] <= 1'b0;
      end else begin
        automatic logic push_m = vfu_op_valid[l] && mfpu_ready[l] &&
                                 (vfu_op[l].op inside {[VMUL:VFWREDOSUM], [VMFEQ:VMFGE]});
        automatic logic pop_m = 1'b0;
        mfpu_vinsn_done[l] <= '0;
        mfpu_pop_a[l] <= 1'b0; mfpu_pop_b[l] <= 1'b0; mfpu_pop_c[l] <= 1'b0;
        mfpu_cmd_pop_a[l] <= 1'b0; mfpu_cmd_pop_b[l] <= 1'b0; mfpu_cmd_pop_c[l] <= 1'b0;
        fflags_ex[l] <= '0; fflags_ex_valid[l] <= 1'b0;

        if (push_m) begin
          mfpu_q[mfpu_wr] <= vfu_op[l];
          mfpu_wr <= (mfpu_wr + 1) % 4;
        end

        case (mfpu_st)
          MFPU_IDLE: begin
            if (mfpu_cnt > 0) begin
              cur_mfpu   <= mfpu_q[mfpu_rd];
              mfpu_rd    <= (mfpu_rd + 1) % 4;
              pop_m       = 1'b1;
              mfpu_w_idx <= 0;
              mfpu_st    <= MFPU_PREP_CMD;
            end
          end
          MFPU_PREP_CMD: begin
            automatic logic need_a = cur_mfpu.use_vs1;
            automatic logic need_b = (cur_mfpu.op inside {[VMFEQ:VMFGE]}) ? cur_mfpu.use_vs2 :
                                     (cur_mfpu.swap_vs2_vd_op ? cur_mfpu.use_vd_op : cur_mfpu.use_vs2);
            automatic logic need_c = (cur_mfpu.op inside {[VMFEQ:VMFGE]}) ? 1'b0 :
                                     (cur_mfpu.swap_vs2_vd_op ? cur_mfpu.use_vs2 : cur_mfpu.use_vd_op);
            if ((!need_a || cmd_cnt[l][MulFPUA] > 0) &&
                (!need_b || cmd_cnt[l][MulFPUB] > 0) &&
                (!need_c || cmd_cnt[l][MulFPUC] > 0)) begin
              automatic int epw = 1 << (int'(EW64) - int'(cur_mfpu.vtype.vsew));
              mfpu_rem_a <= need_a ? cmd_words_fifo[l][MulFPUA][cmd_rd_ptr[l][MulFPUA]] : 0;
              mfpu_rem_b <= need_b ? cmd_words_fifo[l][MulFPUB][cmd_rd_ptr[l][MulFPUB]] : 0;
              mfpu_rem_c <= need_c ? cmd_words_fifo[l][MulFPUC][cmd_rd_ptr[l][MulFPUC]] : 0;
              mfpu_cmd_pop_a[l] <= need_a;
              mfpu_cmd_pop_b[l] <= need_b;
              mfpu_cmd_pop_c[l] <= need_c;
              mfpu_tot_w <= (cur_mfpu.op inside {[VFREDUSUM:VFWREDOSUM]}) ?
                            (need_b ? cmd_words_fifo[l][MulFPUB][cmd_rd_ptr[l][MulFPUB]] : 1) :
                            ((int'(cur_mfpu.vl) + epw - 1) / epw);
              mfpu_got_a <= !need_a; mfpu_got_b <= !need_b; mfpu_got_c <= !need_c;
              mfpu_st    <= MFPU_FETCH;
            end
          end
          MFPU_FETCH: begin
            if (mfpu_w_idx >= mfpu_tot_w && mfpu_rem_a == 0 && mfpu_rem_b == 0 && mfpu_rem_c == 0) begin
              if (cur_mfpu.op inside {[VMFEQ:VMFGE]})
                masku_prep_seq[l][cur_mfpu.id] <= masku_prep_seq[l][cur_mfpu.id] + 1;
              mfpu_vinsn_done[l][cur_mfpu.id] <= 1'b1;
              mfpu_st <= MFPU_IDLE;
            end else begin
              automatic logic ta = !mfpu_got_a && (mfpu_rem_a > 0) && (oq_count[l][MulFPUA] > 0) && !mfpu_pop_a[l];
              automatic logic tb_f = !mfpu_got_b && (mfpu_rem_b > 0) && (oq_count[l][MulFPUB] > 0) && !mfpu_pop_b[l];
              automatic logic tc = !mfpu_got_c && (mfpu_rem_c > 0) && (oq_count[l][MulFPUC] > 0) && !mfpu_pop_c[l];
              if (ta) begin
                mfpu_cur_a <= oq_fifo[l][MulFPUA][oq_rd_ptr[l][MulFPUA]];
                mfpu_pop_a[l] <= 1'b1; mfpu_rem_a <= mfpu_rem_a - 1; mfpu_got_a <= 1'b1;
              end else if (mfpu_rem_a == 0) mfpu_got_a <= 1'b1;
              if (tb_f) begin
                mfpu_cur_b <= oq_fifo[l][MulFPUB][oq_rd_ptr[l][MulFPUB]];
                mfpu_pop_b[l] <= 1'b1; mfpu_rem_b <= mfpu_rem_b - 1; mfpu_got_b <= 1'b1;
              end else if (mfpu_rem_b == 0) mfpu_got_b <= 1'b1;
              if (tc) begin
                mfpu_cur_c <= oq_fifo[l][MulFPUC][oq_rd_ptr[l][MulFPUC]];
                mfpu_pop_c[l] <= 1'b1; mfpu_rem_c <= mfpu_rem_c - 1; mfpu_got_c <= 1'b1;
              end else if (mfpu_rem_c == 0) mfpu_got_c <= 1'b1;

              if ((mfpu_got_a || ta || mfpu_rem_a == 0) &&
                  (mfpu_got_b || tb_f || mfpu_rem_b == 0) &&
                  (mfpu_got_c || tc || mfpu_rem_c == 0)) begin
                mfpu_lat_cnt <= (cfg_mfpu_lat > 1) ? (cfg_mfpu_lat - 1) : 0;
                mfpu_st      <= MFPU_WAIT_LAT;
              end
            end
          end
          MFPU_WAIT_LAT: begin
            if (mfpu_lat_cnt > 0) mfpu_lat_cnt <= mfpu_lat_cnt - 1;
            else begin
              automatic elen_t vs1_v = cur_mfpu.use_scalar_op ? cur_mfpu.scalar_op : mfpu_cur_a;
              automatic elen_t vs2_v = cur_mfpu.swap_vs2_vd_op ? mfpu_cur_c : mfpu_cur_b;
              automatic elen_t vd_v  = cur_mfpu.swap_vs2_vd_op ? mfpu_cur_b : mfpu_cur_c;
              automatic elen_t res;
              unique case (cur_mfpu.op)
                VMUL:    res = vs2_v * vs1_v;
                VMACC:   res = vd_v + (vs1_v * vs2_v);
                VMADD:   res = vs2_v + (vs1_v * vd_v);
                VDIVU:   res = (vs1_v == '0) ? 64'hFFFF_FFFF_FFFF_FFFF : (vs2_v / vs1_v);
                VREMU:   res = (vs1_v == '0) ? vs2_v : (vs2_v % vs1_v);
                default: res = vs2_v * vs1_v;
              endcase
              if (cur_mfpu.op inside {[VMFEQ:VMFGE]}) begin
                if (mfpu_w_idx < 64) begin
                  masku_src_a[l][mfpu_w_idx] <= vs1_v;
                  masku_src_b[l][mfpu_w_idx] <= vs2_v;
                end
                mfpu_w_idx <= mfpu_w_idx + 1;
                mfpu_got_a <= (mfpu_rem_a == 0); mfpu_got_b <= (mfpu_rem_b == 0); mfpu_got_c <= 1'b1;
                mfpu_st <= MFPU_FETCH;
              end else if (cur_mfpu.use_vd) begin
                automatic logic m_en = cur_mfpu.vm ? 1'b1 : vrf_mem[l][0][0][mfpu_w_idx & 63];
                mfpu_res_req[l]   <= 1'b1;
                mfpu_res_id[l]    <= cur_mfpu.id;
                mfpu_res_addr[l]  <= vaddr_t'(vaddr(cur_mfpu.vd, NrLanes, VLEN) + mfpu_w_idx);
                mfpu_res_wdata[l] <= res;
                mfpu_res_be[l]    <= m_en ? 8'hFF : 8'h00;
                if (cfg_force_fflags && (mfpu_w_idx + 1 == mfpu_tot_w)) begin
                  fflags_ex[l]       <= 5'b00001;
                  fflags_ex_valid[l] <= 1'b1;
                end
                mfpu_st <= MFPU_WRITE;
              end else begin
                mfpu_w_idx <= mfpu_w_idx + 1;
                mfpu_st    <= MFPU_FETCH;
              end
            end
          end
          MFPU_WRITE: begin
            if (mfpu_res_gnt[l]) begin
              mfpu_res_req[l] <= 1'b0;
              mfpu_w_idx <= mfpu_w_idx + 1;
              if (cur_mfpu.cvt_resize == CVT_WIDE && (mfpu_w_idx[0] == 1'b0)) begin
                mfpu_got_a <= 1'b1; mfpu_got_b <= 1'b1; mfpu_got_c <= 1'b1;
              end else begin
                mfpu_got_a <= (mfpu_rem_a == 0); mfpu_got_b <= (mfpu_rem_b == 0); mfpu_got_c <= (mfpu_rem_c == 0);
              end
              mfpu_st <= MFPU_FETCH;
            end
          end
        endcase
        mfpu_cnt <= mfpu_cnt + (push_m ? 1 : 0) - (pop_m ? 1 : 0);
      end
    end
  end

  // External PEs: shared handshake detector + VLDU + VSTU + SLDU + MASKU
  assign pe_req_ready[NrLanes + OffsetLoad]  = 1'b1;
  assign pe_req_ready[NrLanes + OffsetStore] = 1'b1;
  assign pe_req_ready[NrLanes + OffsetMask]  = 1'b1;
  assign pe_req_ready[NrLanes + OffsetSlide] = 1'b1;
  assign addrgen_exception        = '0;
  assign addrgen_exception_vstart = '0;
  assign addrgen_fof_exception    = 1'b0;
  assign lsu_current_burst_exception = 1'b0;
  assign lsu_ex_flush_done        = 1'b1;

  logic ext_sync_en;
  vid_t ext_last_id;
  logic new_ext_req;
  always_comb begin
    new_ext_req = 1'b0;
    if (pe_req_valid && (&pe_req_ready[NrLanes-1:0] || ((pe_req.op == VLE || pe_req.op == VLSE) && pe_req.vm))) begin
      if (!ext_sync_en || (pe_req.id != ext_last_id))
        new_ext_req = 1'b1;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ext_sync_en <= 1'b0;
      ext_last_id <= '0;
    end else begin
      if (!pe_req_valid) ext_sync_en <= 1'b0;
      else if (new_ext_req) begin
        ext_sync_en <= 1'b1;
        ext_last_id <= pe_req.id;
      end
    end
  end

  logic [NrLanes-1:0] ldu_pop_sld, stu_pop_sld, sldu_pop_sld;
  logic [NrLanes-1:0] ldu_cmd_sld, stu_cmd_sld, sldu_cmd_sld;
  assign ext_pop_sld     = ldu_pop_sld | stu_pop_sld | sldu_pop_sld;
  assign ext_cmd_pop_sld = ldu_cmd_sld | stu_cmd_sld | sldu_cmd_sld;

  // Addrgen ACK queue (for loads & stores)
  int ag_q_cnt, ag_lat;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ag_q_cnt    <= 0;
      ag_lat      <= 0;
      addrgen_ack <= 1'b0;
    end else begin
      automatic logic push_ag = new_ext_req && (is_load(pe_req.op) || is_store(pe_req.op));
      automatic logic pop_ag  = 1'b0;
      addrgen_ack <= 1'b0;
      if (ag_q_cnt > 0) begin
        if (ag_lat > 0) ag_lat <= ag_lat - 1;
        else begin
          addrgen_ack <= 1'b1;
          pop_ag       = 1'b1;
          ag_lat      <= cfg_lsu_lat;
        end
      end else if (push_ag) begin
        ag_lat <= cfg_lsu_lat;
      end
      ag_q_cnt <= ag_q_cnt + (push_ag ? 1 : 0) - (pop_ag ? 1 : 0);
    end
  end

  // VLDU model
  pe_req_t ldu_q [4];
  int ldu_wr, ldu_rd, ldu_cnt, ldu_w, ldu_tot_w [NrLanes], ldu_lat;
  pe_req_t cur_ldu;
  enum int { LDU_IDLE, LDU_PREP, LDU_STEP, LDU_WAIT_GNT, LDU_WAIT_FINAL } ldu_st;
  logic [NrLanes-1:0] ldu_lane_done;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ldu_wr <= 0; ldu_rd <= 0; ldu_cnt <= 0; ldu_st <= LDU_IDLE;
      pe_resp_ld <= '0; load_complete <= 1'b0;
      ldu_res_req <= '0; ldu_res_id <= '0; ldu_res_addr <= '0; ldu_res_wdata <= '0; ldu_res_be <= '0;
      ldu_pop_sld <= '0; ldu_cmd_sld <= '0;
    end else begin
      automatic logic push_l = new_ext_req && is_load(pe_req.op);
      automatic logic pop_l  = 1'b0;
      pe_resp_ld <= '0; load_complete <= 1'b0;
      ldu_pop_sld <= '0; ldu_cmd_sld <= '0;
      if (push_l) begin ldu_q[ldu_wr] <= pe_req; ldu_wr <= (ldu_wr + 1) % 4; end
      case (ldu_st)
        LDU_IDLE: if (ldu_cnt > 0) begin
          cur_ldu <= ldu_q[ldu_rd]; ldu_rd <= (ldu_rd + 1) % 4; pop_l = 1'b1;
          ldu_w <= 0; ldu_st <= LDU_PREP;
        end
        LDU_PREP: begin
          automatic logic idx_ld = (cur_ldu.op == VLXE);
          if (!idx_ld || (cmd_cnt[0][SlideAddrGenA] > 0 && cmd_cnt[1][SlideAddrGenA] > 0 &&
                          cmd_tgt_fifo[0][SlideAddrGenA][cmd_rd_ptr[0][SlideAddrGenA]] == MFPU_ADDRGEN &&
                          cmd_tgt_fifo[1][SlideAddrGenA][cmd_rd_ptr[1][SlideAddrGenA]] == MFPU_ADDRGEN)) begin
            automatic int epw = 1 << (int'(EW64) - int'(cur_ldu.vtype.vsew));
            for (int l = 0; l < NrLanes; l++) begin
              automatic int lvl = int'(cur_ldu.vl) / NrLanes + ((l < int'(cur_ldu.vl[0])) ? 1 : 0);
              ldu_tot_w[l] <= (lvl + epw - 1) / epw;
            end
            ldu_lat <= cfg_lsu_lat; ldu_st <= LDU_STEP;
          end
        end
        LDU_STEP: begin
          if (ldu_lat > 0) ldu_lat <= ldu_lat - 1;
          else if (ldu_w >= ldu_tot_w[0] && ldu_w >= ldu_tot_w[1]) begin
            ldu_lane_done <= '0; ldu_st <= LDU_WAIT_FINAL;
          end else if (cur_ldu.op != VLXE || ((ldu_w >= ldu_tot_w[0] || oq_count[0][SlideAddrGenA] > 0) &&
                                              (ldu_w >= ldu_tot_w[1] || oq_count[1][SlideAddrGenA] > 0))) begin
            ldu_lane_done <= '0;
            for (int l = 0; l < NrLanes; l++) begin
              if (ldu_w < ldu_tot_w[l]) begin
                automatic elen_t idx_b = (cur_ldu.op == VLXE) ? oq_fifo[l][SlideAddrGenA][oq_rd_ptr[l][SlideAddrGenA]] :
                                         elen_t'((2*ldu_w + l) * 8);
                automatic logic m_en = cur_ldu.vm ? 1'b1 : vrf_mem[l][0][0][ldu_w & 63];
                if (cur_ldu.op == VLXE) begin
                  ldu_pop_sld[l] <= 1'b1;
                  if (ldu_w + 1 == ldu_tot_w[l]) ldu_cmd_sld[l] <= 1'b1;
                end
                ldu_res_req[l]   <= 1'b1;
                ldu_res_id[l]    <= cur_ldu.id;
                ldu_res_addr[l]  <= vaddr_t'(vaddr(cur_ldu.vd, NrLanes, VLEN) + ldu_w);
                ldu_res_wdata[l] <= ext_mem[((cur_ldu.scalar_op + idx_b) >> 3) & 511];
                ldu_res_be[l]    <= m_en ? 8'hFF : 8'h00;
              end else ldu_lane_done[l] <= 1'b1;
            end
            ldu_st <= LDU_WAIT_GNT;
          end
        end
        LDU_WAIT_GNT: begin
          automatic logic [NrLanes-1:0] dn = ldu_lane_done;
          for (int l = 0; l < NrLanes; l++) begin
            if (ldu_res_req[l] && ldu_res_gnt[l]) begin ldu_res_req[l] <= 1'b0; dn[l] = 1'b1; end
          end
          ldu_lane_done <= dn;
          if (&dn) begin ldu_w <= ldu_w + 1; ldu_lat <= 1; ldu_st <= LDU_STEP; end
        end
        LDU_WAIT_FINAL: begin
          // Wait 1 extra cycle for operand_requester stream_register -> final_gnt drain
          pe_resp_ld.vinsn_done[cur_ldu.id] <= 1'b1;
          load_complete <= 1'b1;
          ldu_st <= LDU_IDLE;
        end
      endcase
      ldu_cnt <= ldu_cnt + (push_l ? 1 : 0) - (pop_l ? 1 : 0);
    end
  end

  // VSTU model
  pe_req_t stu_q [4];
  int stu_wr, stu_rd, stu_cnt, stu_w, stu_rem [NrLanes], stu_idx_rem [NrLanes];
  pe_req_t cur_stu;
  enum int { STU_IDLE, STU_PREP, STU_DRAIN } stu_st;
  assign store_pending = (stu_cnt > 0) || (stu_st != STU_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stu_wr <= 0; stu_rd <= 0; stu_cnt <= 0; stu_st <= STU_IDLE;
      pe_resp_st <= '0; store_complete <= 1'b0;
      ext_pop_sta <= '0; ext_cmd_pop_sta <= '0; stu_pop_sld <= '0; stu_cmd_sld <= '0;
    end else begin
      automatic logic push_s = new_ext_req && is_store(pe_req.op);
      automatic logic pop_s  = 1'b0;
      pe_resp_st <= '0; store_complete <= 1'b0;
      ext_pop_sta <= '0; ext_cmd_pop_sta <= '0; stu_pop_sld <= '0; stu_cmd_sld <= '0;
      if (push_s) begin stu_q[stu_wr] <= pe_req; stu_wr <= (stu_wr + 1) % 4; end
      case (stu_st)
        STU_IDLE: if (stu_cnt > 0) begin
          cur_stu <= stu_q[stu_rd]; stu_rd <= (stu_rd + 1) % 4; pop_s = 1'b1;
          stu_w <= 0; stu_st <= STU_PREP;
        end
        STU_PREP: begin
          automatic logic idx_st = (cur_stu.op == VSXE);
          if (cmd_cnt[0][StA] > 0 && cmd_cnt[1][StA] > 0 &&
              (!idx_st || (cmd_cnt[0][SlideAddrGenA] > 0 && cmd_cnt[1][SlideAddrGenA] > 0 &&
                           cmd_tgt_fifo[0][SlideAddrGenA][cmd_rd_ptr[0][SlideAddrGenA]] == MFPU_ADDRGEN &&
                           cmd_tgt_fifo[1][SlideAddrGenA][cmd_rd_ptr[1][SlideAddrGenA]] == MFPU_ADDRGEN))) begin
            for (int l = 0; l < NrLanes; l++) begin
              stu_rem[l]     <= cmd_words_fifo[l][StA][cmd_rd_ptr[l][StA]];
              stu_idx_rem[l] <= idx_st ? cmd_words_fifo[l][SlideAddrGenA][cmd_rd_ptr[l][SlideAddrGenA]] : 0;
              ext_cmd_pop_sta[l] <= 1'b1;
            end
            stu_st <= STU_DRAIN;
          end
        end
        STU_DRAIN: begin
          if (stu_rem[0] == 0 && stu_rem[1] == 0 && stu_idx_rem[0] == 0 && stu_idx_rem[1] == 0) begin
            pe_resp_st.vinsn_done[cur_stu.id] <= 1'b1;
            store_complete <= 1'b1;
            stu_st <= STU_IDLE;
          end else begin
            for (int l = 0; l < NrLanes; l++) begin
              automatic logic need_i = (stu_idx_rem[l] > 0);
              if (stu_rem[l] > 0 && oq_count[l][StA] > 0 && !ext_pop_sta[l] &&
                  (!need_i || (oq_count[l][SlideAddrGenA] > 0 && !stu_pop_sld[l]))) begin
                automatic elen_t val = oq_fifo[l][StA][oq_rd_ptr[l][StA]];
                automatic elen_t off = need_i ? oq_fifo[l][SlideAddrGenA][oq_rd_ptr[l][SlideAddrGenA]] :
                                       elen_t'(((cmd_words_fifo[l][StA][(cmd_rd_ptr[l][StA]+15)%16] - stu_rem[l])*2 + l)*8);
                automatic int e_idx = (cmd_words_fifo[l][StA][(cmd_rd_ptr[l][StA]+15)%16] - stu_rem[l])*2 + l;
                if (e_idx < int'(cur_stu.vl) && (cur_stu.vm || vrf_mem[l][0][0][(e_idx >> 1) & 63]))
                  ext_mem[((cur_stu.scalar_op + off) >> 3) & 511] <= val;
                ext_pop_sta[l] <= 1'b1;
                stu_rem[l]     <= stu_rem[l] - 1;
                if (need_i) begin
                  stu_pop_sld[l] <= 1'b1; stu_idx_rem[l] <= stu_idx_rem[l] - 1;
                  if (stu_idx_rem[l] == 1) stu_cmd_sld[l] <= 1'b1;
                end
              end else if (stu_rem[l] == 0 && need_i && oq_count[l][SlideAddrGenA] > 0 && !stu_pop_sld[l]) begin
                stu_pop_sld[l] <= 1'b1; stu_idx_rem[l] <= stu_idx_rem[l] - 1;
                if (stu_idx_rem[l] == 1) stu_cmd_sld[l] <= 1'b1;
              end
            end
          end
        end
      endcase
      stu_cnt <= stu_cnt + (push_s ? 1 : 0) - (pop_s ? 1 : 0);
    end
  end

  // Track per-vid completion of lane/LSU/SLDU VFUs for MASKU & SLDU coordination
  logic [NrVInsn-1:0] lane0_done_seen, lane1_done_seen, main_done_seen;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lane0_done_seen <= '0;
      lane1_done_seen <= '0;
      main_done_seen  <= '0;
    end else begin
      if (new_ext_req) begin
        lane0_done_seen[pe_req.id] <= 1'b0;
        lane1_done_seen[pe_req.id] <= 1'b0;
        main_done_seen[pe_req.id]  <= 1'b0;
      end
      lane0_done_seen |= pe_resp[0].vinsn_done;
      lane1_done_seen |= pe_resp[1].vinsn_done;
      main_done_seen  |= (pe_resp[0].vinsn_done & (lane1_done_seen | pe_resp[1].vinsn_done)) |
                         (pe_resp[1].vinsn_done & lane0_done_seen) |
                         pe_resp[NrLanes+OffsetLoad].vinsn_done |
                         pe_resp[NrLanes+OffsetStore].vinsn_done |
                         pe_resp[NrLanes+OffsetSlide].vinsn_done;
    end
  end

  // SLDU model (Depth = 2)
  pe_req_t sldu_q [4];
  int sldu_wr, sldu_rd, sldu_cnt, sld_rem [NrLanes], sld_got [NrLanes], sld_out_tot [NrLanes], sld_w, sld_lat;
  elen_t sld_buf [NrLanes][64];
  pe_req_t cur_sld;
  logic [NrLanes-1:0] sld_lane_done;
  enum int { SLD_IDLE, SLD_WAIT_RED, SLD_PREP, SLD_READ, SLD_LAT, SLD_WRITE, SLD_WAIT_GNT, SLD_FINAL } sld_st;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sldu_wr <= 0; sldu_rd <= 0; sldu_cnt <= 0; sld_st <= SLD_IDLE;
      pe_resp_sld <= '0;
      sldu_res_req <= '0; sldu_res_id <= '0; sldu_res_addr <= '0; sldu_res_wdata <= '0; sldu_res_be <= '0;
      sldu_pop_sld <= '0; sldu_cmd_sld <= '0;
    end else begin
      automatic logic push_sl = new_ext_req && (pe_req.op inside {[VSLIDEUP:VSLIDEDOWN], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]});
      automatic logic pop_sl  = 1'b0;
      pe_resp_sld <= '0;
      sldu_pop_sld <= '0; sldu_cmd_sld <= '0;
      if (push_sl) begin sldu_q[sldu_wr] <= pe_req; sldu_wr <= (sldu_wr + 1) % 4; end
      case (sld_st)
        SLD_IDLE: if (sldu_cnt > 0) begin
          cur_sld <= sldu_q[sldu_rd]; sldu_rd <= (sldu_rd + 1) % 4; pop_sl = 1'b1;
          if (sldu_q[sldu_rd].op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]})
            sld_st <= SLD_WAIT_RED;
          else
            sld_st <= SLD_PREP;
        end
        SLD_WAIT_RED: begin
          if (lane0_done_seen[cur_sld.id] && lane1_done_seen[cur_sld.id]) begin
            pe_resp_sld.vinsn_done[cur_sld.id] <= 1'b1;
            sld_st <= SLD_IDLE;
          end
        end
        SLD_PREP: begin
          if (cmd_cnt[0][SlideAddrGenA] > 0 && cmd_cnt[1][SlideAddrGenA] > 0 &&
              cmd_tgt_fifo[0][SlideAddrGenA][cmd_rd_ptr[0][SlideAddrGenA]] == ALU_SLDU &&
              cmd_tgt_fifo[1][SlideAddrGenA][cmd_rd_ptr[1][SlideAddrGenA]] == ALU_SLDU) begin
            automatic int epw = 1 << (int'(EW64) - int'(cur_sld.vtype.vsew));
            for (int l = 0; l < NrLanes; l++) begin
              automatic int lvl = int'(cur_sld.vl) / NrLanes + ((l < int'(cur_sld.vl[0])) ? 1 : 0);
              sld_rem[l]      <= cmd_words_fifo[l][SlideAddrGenA][cmd_rd_ptr[l][SlideAddrGenA]];
              sld_got[l]      <= 0;
              sld_out_tot[l]  <= (lvl + epw - 1) / epw;
            end
            sld_st <= SLD_READ;
          end
        end
        SLD_READ: begin
          if (sld_rem[0] == 0 && sld_rem[1] == 0) begin
            sld_lat <= cfg_sldu_lat; sld_w <= 0; sld_st <= SLD_LAT;
          end else begin
            for (int l = 0; l < NrLanes; l++) begin
              if (sld_rem[l] > 0 && oq_count[l][SlideAddrGenA] > 0 && !sldu_pop_sld[l]) begin
                sld_buf[l][sld_got[l]] <= oq_fifo[l][SlideAddrGenA][oq_rd_ptr[l][SlideAddrGenA]];
                sldu_pop_sld[l] <= 1'b1;
                sld_rem[l]      <= sld_rem[l] - 1;
                sld_got[l]      <= sld_got[l] + 1;
                if (sld_rem[l] == 1) sldu_cmd_sld[l] <= 1'b1;
              end
            end
          end
        end
        SLD_LAT: begin
          if (sld_lat > 0) sld_lat <= sld_lat - 1;
          else sld_st <= SLD_WRITE;
        end
        SLD_WRITE: begin
          if (sld_w >= sld_out_tot[0] && sld_w >= sld_out_tot[1]) begin
            sld_st <= SLD_FINAL;
          end else begin
            sld_lane_done <= '0;
            for (int l = 0; l < NrLanes; l++) begin
              if (sld_w < sld_out_tot[l]) begin
                automatic int dst_e = 2*sld_w + l;
                automatic int st    = int'(cur_sld.stride);
                automatic elen_t val = '0;
                automatic logic wr_en = 1'b1;
                if (cur_sld.scale_vl && st == 0) begin
                  val = sld_buf[l][sld_w];
                end else if (cur_sld.op == VSLIDEUP) begin
                  if (dst_e < st) wr_en = 1'b0;
                  else val = sld_buf[(dst_e - st) & 1][(dst_e - st) >> 1];
                end else begin
                  automatic int rel = dst_e + st - (cur_sld.use_scalar_op ? 0 : ((st >> 1) << 1));
                  if (cur_sld.use_scalar_op && (dst_e + st >= int'(cur_sld.vl))) val = cur_sld.scalar_op;
                  else if ((rel >> 1) < sld_got[rel & 1]) val = sld_buf[rel & 1][rel >> 1];
                  else val = '0;
                end
                if (!cur_sld.vm && !vrf_mem[l][0][0][sld_w & 63]) wr_en = 1'b0;
                sldu_res_req[l]   <= 1'b1;
                sldu_res_id[l]    <= cur_sld.id;
                sldu_res_addr[l]  <= vaddr_t'(vaddr(cur_sld.vd, NrLanes, VLEN) + sld_w);
                sldu_res_wdata[l] <= val;
                sldu_res_be[l]    <= wr_en ? 8'hFF : 8'h00;
              end else sld_lane_done[l] <= 1'b1;
            end
            sld_st <= SLD_WAIT_GNT;
          end
        end
        SLD_WAIT_GNT: begin
          automatic logic [NrLanes-1:0] dn = sld_lane_done;
          for (int l = 0; l < NrLanes; l++)
            if (sldu_res_req[l] && sldu_res_gnt[l]) begin sldu_res_req[l] <= 1'b0; dn[l] = 1'b1; end
          sld_lane_done <= dn;
          if (&dn) begin sld_w <= sld_w + 1; sld_st <= SLD_WRITE; end
        end
        SLD_FINAL: begin
          pe_resp_sld.vinsn_done[cur_sld.id] <= 1'b1;
          sld_st <= SLD_IDLE;
        end
      endcase
      sldu_cnt <= sldu_cnt + (push_sl ? 1 : 0) - (pop_sl ? 1 : 0);
    end
  end

  // MASKU model (Depth = 1)
  pe_req_t masku_q [4];
  int mk_wr, mk_rd, mk_cnt, mk_rem_m [NrLanes], mk_rem_b [NrLanes], mk_w, mk_tot_w [NrLanes], mk_lat;
  int mk_seen_prep [NrLanes][NrVInsn];
  elen_t mk_vd_buf [NrLanes][64], mk_vrgat_buf [NrLanes][64];
  pe_req_t cur_mk;
  logic [NrLanes-1:0] mk_lane_done;
  enum int { MK_IDLE, MK_PREP, MK_WAIT_LAT_DRAIN, MK_VRGAT_REQ, MK_VRGAT_WAIT, MK_SCALAR, MK_WRITE, MK_WAIT_GNT, MK_WAIT_MAIN, MK_FINAL } mk_st;
  assign masku_busy = (mk_st != MK_IDLE) && (cur_mk.op inside {[VMFEQ:VCOMPRESS]});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mk_wr <= 0; mk_rd <= 0; mk_cnt <= 0; mk_st <= MK_IDLE;
      pe_resp_mk <= '0;
      masku_scalar_res <= '0; masku_scalar_valid <= 1'b0;
      masku_pop_maskb <= '0; ext_cmd_pop_maskb <= '0; mask_b_cmd_pop <= '0;
      ext_pop_maskm <= '0; ext_cmd_pop_maskm <= '0;
      masku_vrgat_valid <= '0; masku_vrgat_req <= '0;
      masku_res_req <= '0; masku_res_id <= '0; masku_res_addr <= '0; masku_res_wdata <= '0; masku_res_be <= '0;
      for (int l = 0; l < NrLanes; l++) for (int i = 0; i < NrVInsn; i++) mk_seen_prep[l][i] <= 0;
    end else begin
      automatic logic push_mk = new_ext_req && ((pe_req.op inside {[VMFEQ:VCOMPRESS]}) || !pe_req.vm);
      automatic logic pop_mk  = 1'b0;
      pe_resp_mk <= '0;
      masku_pop_maskb <= '0; ext_cmd_pop_maskb <= '0; mask_b_cmd_pop <= '0;
      ext_pop_maskm <= '0; ext_cmd_pop_maskm <= '0;
      if (push_mk) begin masku_q[mk_wr] <= pe_req; mk_wr <= (mk_wr + 1) % 4; end
      case (mk_st)
        MK_IDLE: if (mk_cnt > 0) begin
          cur_mk <= masku_q[mk_rd]; mk_rd <= (mk_rd + 1) % 4; pop_mk = 1'b1;
          mk_st <= MK_PREP;
        end
        MK_PREP: begin
          automatic logic need_m = !cur_mk.vm;
          automatic logic need_b = (cur_mk.op inside {[VMFEQ:VCOMPRESS]}) && cur_mk.use_vd_op;
          if ((!need_m || (cmd_cnt[0][MaskM] > 0 && cmd_cnt[1][MaskM] > 0)) &&
              (!need_b || (cmd_cnt[0][MaskB] > 0 && cmd_cnt[1][MaskB] > 0))) begin
            automatic int epw = 1 << (int'(EW64) - int'(cur_mk.vtype.vsew));
            for (int l = 0; l < NrLanes; l++) begin
              automatic int lvl = int'(cur_mk.vl) / NrLanes + ((l < int'(cur_mk.vl[0])) ? 1 : 0);
              mk_rem_m[l]         <= need_m ? cmd_words_fifo[l][MaskM][cmd_rd_ptr[l][MaskM]] : 0;
              mk_rem_b[l]         <= need_b ? cmd_words_fifo[l][MaskB][cmd_rd_ptr[l][MaskB]] : 0;
              ext_cmd_pop_maskm[l]<= need_m;
              ext_cmd_pop_maskb[l]<= need_b;
              mk_tot_w[l]         <= (cur_mk.op inside {VID, VIOTA, VRGATHER, VRGATHEREI16, VCOMPRESS}) ?
                                     ((lvl + epw - 1) / epw) : 1;
            end
            mk_lat <= cfg_masku_lat; mk_w <= 0;
            mk_st  <= (cur_mk.op inside {[VMFEQ:VCOMPRESS]}) ? MK_WAIT_LAT_DRAIN : MK_WAIT_MAIN;
          end
        end
        MK_WAIT_MAIN: begin
          for (int l = 0; l < NrLanes; l++)
            if (mk_rem_m[l] > 0 && oq_count[l][MaskM] > 0 && !ext_pop_maskm[l]) begin
              ext_pop_maskm[l] <= 1'b1; mk_rem_m[l] <= mk_rem_m[l] - 1;
            end
          if (mk_rem_m[0] == 0 && mk_rem_m[1] == 0 && main_done_seen[cur_mk.id]) begin
            pe_resp_mk.vinsn_done[cur_mk.id] <= 1'b1;
            mk_st <= MK_IDLE;
          end
        end
        MK_WAIT_LAT_DRAIN: begin
          // Hold MaskB unpopped during mk_lat to expose any premature vmv.x.s collision
          automatic logic need_prep = (cur_mk.use_vs1 || (cur_mk.use_vs2 && !(cur_mk.op inside {[VRGATHER:VCOMPRESS]})));
          automatic logic prep_ok   = !need_prep || ((masku_prep_seq[0][cur_mk.id] > mk_seen_prep[0][cur_mk.id]) &&
                                                     (masku_prep_seq[1][cur_mk.id] > mk_seen_prep[1][cur_mk.id]));
          for (int l = 0; l < NrLanes; l++)
            if (mk_rem_m[l] > 0 && oq_count[l][MaskM] > 0 && !ext_pop_maskm[l]) begin
              ext_pop_maskm[l] <= 1'b1; mk_rem_m[l] <= mk_rem_m[l] - 1;
            end
          if (!prep_ok) begin
            // Wait for VALU/VMFPU comparison operands before consuming MaskB old-vd
          end else if (mk_lat > 0) begin
            mk_lat <= mk_lat - 1;
          end else begin
            for (int l = 0; l < NrLanes; l++)
              if (mk_rem_b[l] > 0 && oq_count[l][MaskB] > 0 && !masku_pop_maskb[l]) begin
                mk_vd_buf[l][0]   <= oq_fifo[l][MaskB][oq_rd_ptr[l][MaskB]];
                masku_pop_maskb[l]<= 1'b1; mk_rem_b[l] <= mk_rem_b[l] - 1;
              end
            if (mk_rem_m[0] == 0 && mk_rem_m[1] == 0 && mk_rem_b[0] == 0 && mk_rem_b[1] == 0) begin
              if (need_prep) begin
                mk_seen_prep[0][cur_mk.id] <= masku_prep_seq[0][cur_mk.id];
                mk_seen_prep[1][cur_mk.id] <= masku_prep_seq[1][cur_mk.id];
              end
              mk_w <= 0;
              if (cur_mk.op inside {[VRGATHER:VCOMPRESS]}) mk_st <= MK_VRGAT_REQ;
              else if (cur_mk.op inside {[VCPOP:VFIRST]})  mk_st <= MK_SCALAR;
              else                                         mk_st <= MK_WRITE;
            end
          end
        end
        MK_VRGAT_REQ: begin
          for (int l = 0; l < NrLanes; l++) begin
            masku_vrgat_valid[l] <= 1'b1;
            masku_vrgat_req[l]   <= '{
              vs         : cur_mk.vs2,
              eew        : (cur_mk.op == VCOMPRESS) ? cur_mk.vtype.vsew : cur_mk.eew_vs2,
              idx        : vlen_t'(mk_w),
              is_last_req: (mk_w + 1 >= ((mk_tot_w[0] > 0) ? mk_tot_w[0] : 1))
            };
          end
          mk_st <= MK_VRGAT_WAIT;
        end
        MK_VRGAT_WAIT: begin
          for (int l = 0; l < NrLanes; l++)
            if (masku_vrgat_valid[l] && masku_vrgat_ready[l]) masku_vrgat_valid[l] <= 1'b0;
          if (!masku_vrgat_valid[0] && !masku_vrgat_valid[1] &&
              cmd_cnt[0][MaskB] > 0 && cmd_cnt[1][MaskB] > 0 &&
              oq_count[0][MaskB] > 0 && oq_count[1][MaskB] > 0) begin
            for (int l = 0; l < NrLanes; l++) begin
              mk_vrgat_buf[l][mk_w] <= oq_fifo[l][MaskB][oq_rd_ptr[l][MaskB]];
              masku_pop_maskb[l]    <= 1'b1;
              ext_cmd_pop_maskb[l]  <= 1'b1;
              mask_b_cmd_pop[l]     <= 1'b1;
            end
            if (mk_w + 1 >= ((mk_tot_w[0] > 0) ? mk_tot_w[0] : 1)) begin
              mk_w <= 0; mk_st <= MK_WRITE;
            end else begin
              mk_w <= mk_w + 1; mk_st <= MK_VRGAT_REQ;
            end
          end
        end
        MK_SCALAR: begin
          automatic int cnt_ones = 0;
          automatic longint first_idx = -1;
          for (int i = 0; i < int'(cur_mk.vl) && i < 128; i++) begin
            automatic logic b = masku_src_b[i & 1][0][(i >> 1) & 63];
            automatic logic m = cur_mk.vm ? 1'b1 : vrf_mem[i & 1][0][0][(i >> 1) & 63];
            if (b && m) begin
              cnt_ones++;
              if (first_idx < 0) first_idx = i;
            end
          end
          masku_scalar_res   <= (cur_mk.op == VCPOP) ? elen_t'(cnt_ones) : elen_t'(first_idx);
          masku_scalar_valid <= 1'b1;
          if (masku_scalar_valid && ara_resp_valid) begin
            masku_scalar_valid <= 1'b0;
            mk_st <= MK_FINAL;
          end
        end
        MK_WRITE: begin
          if (mk_w >= mk_tot_w[0] && mk_w >= mk_tot_w[1]) mk_st <= MK_FINAL;
          else begin
            mk_lane_done <= '0;
            for (int l = 0; l < NrLanes; l++) begin
              if (mk_w < mk_tot_w[l]) begin
                automatic elen_t wval = '0;
                unique case (cur_mk.op)
                  VID: begin
                    wval = elen_t'(2*mk_w + l);
                  end
                  VIOTA: begin
                    automatic int ps = 0;
                    for (int k = 0; k < (2*mk_w + l) && k < 128; k++)
                      if (masku_src_b[k & 1][0][(k >> 1) & 63]) ps++;
                    wval = elen_t'(ps);
                  end
                  VCOMPRESS: begin
                    wval = mk_vrgat_buf[l][mk_w];
                  end
                  VRGATHER, VRGATHEREI16: begin
                    automatic int gidx = int'(masku_src_a[l][mk_w]);
                    wval = (gidx < 2*mk_tot_w[0]) ? mk_vrgat_buf[gidx & 1][gidx >> 1] : '0;
                  end
                  VMSEQ: begin
                    for (int k = 0; k < 64; k++)
                      wval[k] = (k < ((int'(cur_mk.vl)+1-l)/2)) ? (masku_src_b[l][k] == masku_src_a[l][k]) : mk_vd_buf[l][0][k];
                  end
                  VMAND:   wval = masku_src_b[l][0] & masku_src_a[l][0];
                  VMOR:    wval = masku_src_b[l][0] | masku_src_a[l][0];
                  VMXOR:   wval = masku_src_b[l][0] ^ masku_src_a[l][0];
                  VMXNOR:  wval = ~(masku_src_b[l][0] ^ masku_src_a[l][0]);
                  VMSBF:   wval = ~masku_src_b[l][0] & (masku_src_b[l][0] - 64'd1);
                  VMSIF:   wval = masku_src_b[l][0] ^ (masku_src_b[l][0] - 64'd1);
                  VMSOF:   wval = masku_src_b[l][0] & (~masku_src_b[l][0] + 64'd1);
                  default: wval = masku_src_b[l][0] & masku_src_a[l][0];
                endcase
                masku_res_req[l]   <= 1'b1;
                masku_res_id[l]    <= cur_mk.id;
                masku_res_addr[l]  <= vaddr_t'(vaddr(cur_mk.vd, NrLanes, VLEN) + mk_w);
                masku_res_wdata[l] <= wval;
                masku_res_be[l]    <= (!cur_mk.vm && (cur_mk.op inside {VID, VIOTA}) && !vrf_mem[l][0][0][mk_w & 63]) ? 8'h00 : 8'hFF;
              end else mk_lane_done[l] <= 1'b1;
            end
            mk_st <= MK_WAIT_GNT;
          end
        end
        MK_WAIT_GNT: begin
          automatic logic [NrLanes-1:0] dn = mk_lane_done;
          for (int l = 0; l < NrLanes; l++)
            if (masku_res_req[l] && masku_res_gnt[l]) begin masku_res_req[l] <= 1'b0; dn[l] = 1'b1; end
          mk_lane_done <= dn;
          if (&dn) begin mk_w <= mk_w + 1; mk_st <= MK_WRITE; end
        end
        MK_FINAL: begin
          // Wait 1 extra cycle for stream_register -> final_gnt write drain
          pe_resp_mk.vinsn_done[cur_mk.id] <= 1'b1;
          mk_st <= MK_IDLE;
        end
      endcase
      mk_cnt <= mk_cnt + (push_mk ? 1 : 0) - (pop_mk ? 1 : 0);
    end
  end

  // RVV 1.0 Instruction Encoders & Driver Helpers
  function automatic logic [31:0] enc_vsetvli(logic [4:0] rd, logic [4:0] rs1, vew_e sew, vlmul_e lmul);
    return {1'b0, 3'b000, 1'b1, 1'b1, sew, lmul, rs1, 3'b111, rd, 7'b1010111};
  endfunction

  function automatic logic [31:0] enc_vv(logic [5:0] func6, logic vm, logic [4:0] vs2, logic [4:0] vs1, logic [2:0] funct3, logic [4:0] vd);
    return {func6, vm, vs2, vs1, funct3, vd, 7'b1010111};
  endfunction

  function automatic logic [31:0] enc_vle64(logic vm, logic [4:0] rs1, logic [4:0] vd);
    return {3'b000, 1'b0, 2'b00, vm, 5'b00000, rs1, 3'b111, vd, 7'b0000111};
  endfunction

  function automatic logic [31:0] enc_vse64(logic vm, logic [4:0] rs1, logic [4:0] vs3);
    return {3'b000, 1'b0, 2'b00, vm, 5'b00000, rs1, 3'b111, vs3, 7'b0100111};
  endfunction

  function automatic logic [31:0] enc_vluxei64(logic vm, logic [4:0] vs2, logic [4:0] rs1, logic [4:0] vd);
    return {3'b000, 1'b0, 2'b01, vm, vs2, rs1, 3'b111, vd, 7'b0000111};
  endfunction

  function automatic logic [31:0] enc_vsuxei64(logic vm, logic [4:0] vs2, logic [4:0] rs1, logic [4:0] vs3);
    return {3'b000, 1'b0, 2'b01, vm, vs2, rs1, 3'b111, vs3, 7'b0100111};
  endfunction

  function automatic logic [31:0] enc_csr(logic [11:0] csr, logic [4:0] rs1_zimm, logic [2:0] funct3, logic [4:0] rd);
    return {csr, rs1_zimm, funct3, rd, 7'b1110011};
  endfunction

  task automatic write_elem64(int base_reg, int elem_idx, elen_t val);
    int addr, l, bank, row;
    l    = elem_idx & 1;
    addr = int'(vaddr(base_reg[4:0], NrLanes, VLEN)) + (elem_idx >> 1);
    bank = addr & (NrBanks - 1);
    row  = (addr >> $clog2(NrBanks)) & 31;
    vrf_mem[l][bank][row] = val;
  endtask

  function automatic elen_t read_elem64(int base_reg, int elem_idx);
    int addr, l, bank, row;
    l    = elem_idx & 1;
    addr = int'(vaddr(base_reg[4:0], NrLanes, VLEN)) + (elem_idx >> 1);
    bank = addr & (NrBanks - 1);
    row  = (addr >> $clog2(NrBanks)) & 31;
    return vrf_mem[l][bank][row];
  endfunction

  task automatic issue_insn(
    input  logic [31:0] insn_bits,
    input  elen_t       rs1_val,
    input  elen_t       rs2_val,
    output elen_t       resp_res,
    output logic        resp_exc
  );
    int timeout_c;
    #0.2;
    acc_req            = '0;
    acc_req.req_valid  = 1'b1;
    acc_req.resp_ready = 1'b1;
    acc_req.insn       = insn_bits;
    acc_req.rs1        = rs1_val;
    acc_req.rs2        = rs2_val;
    timeout_c = 0;
    while (1) begin
      @(negedge clk);
      if (acc_resp.req_ready && acc_resp.resp_valid) begin
        resp_res = acc_resp.result;
        resp_exc = acc_resp.exception.valid;
        @(posedge clk);
        break;
      end
      @(posedge clk);
      timeout_c++;
      if (timeout_c > 4000) begin
        $display("[FAIL] Timeout waiting for dispatcher handshake on insn=0x%08x", insn_bits);
        fail_cnt++;
        resp_res = '0;
        resp_exc = 1'b0;
        break;
      end
    end
    #0.2;
    acc_req.req_valid = 1'b0;
  endtask

  task automatic wait_backend_idle();
    int t = 0;
    while (!(ara_idle && !ara_req_valid && !pe_req_valid && !store_pending)) begin
      @(posedge clk);
      t++;
      if (t > 6000) begin
        $display("[FAIL] Timeout waiting for Ara backend idle! vinsn_running=0x%0x", pe_vinsn_running);
        fail_cnt++;
        break;
      end
    end
    repeat (2) @(posedge clk);
  endtask

  task automatic do_vsetvli(int avl, vew_e sew, vlmul_e lmul);
    elen_t r; logic ex;
    issue_insn(enc_vsetvli(5'd1, 5'd1, sew, lmul), elen_t'(avl), '0, r, ex);
    if (ex) begin
      $display("[FAIL] Unexpected illegal exception on vsetvli avl=%0d sew=%0d lmul=%0d", avl, sew, lmul);
      fail_cnt++;
    end
  endtask

  // Suite 1: Multi-Register (LMUL>1) OPMVV Group Decoding, Scoreboarding & Scalar Moves
  task automatic run_suite1_lmul_opmvv();
    elen_t r; logic ex;
    cfg_alu_lat = 1; cfg_mfpu_lat = 8; cfg_masku_lat = 4; cfg_sldu_lat = 3;

    // 1A: Back-to-back (NO vsetvli idle drain!) LMUL=2 vmul.vv v4..v5 -> vmv1r.v v16, v5 & vmv.x.s v5
    do_vsetvli(32, EW64, LMUL_2);
    for (int i = 0; i < 32; i++) begin
      write_elem64(4,  i, 64'hDEAD_0000 + i);
      write_elem64(8,  i, 64'd10 + i);
      write_elem64(12, i, 64'd3);
    end
    // Establish EW64 eew_q on v4..v5 and v16 first so whole-reg moves use EW64 without reshuffling
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd4, 5'd4, 3'b000, 5'd4), '0, '0, r, ex);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd16), '0, '0, r, ex);
    wait_backend_idle();
    for (int i = 0; i < 32; i++) write_elem64(4, i, 64'hDEAD_0000 + i);

    cfg_alu_lat = 1; cfg_mfpu_lat = 10;
    issue_insn(enc_vv(6'b100101, 1'b1, 5'd8, 5'd12, 3'b010, 5'd4), '0, '0, r, ex);   // slow vmul.vv v4..v5 (LMUL=2)
    issue_insn(enc_vv(6'b100111, 1'b1, 5'd5, 5'd0,  3'b011, 5'd16), '0, '0, r, ex);  // fast vmv1r.v v16, v5 (reads v5 on vs1 with ZERO vsetvli!)
    issue_insn(enc_vv(6'b010000, 1'b1, 5'd5, 5'b00000, 3'b010, 5'd10), '0, '0, r, ex); // vmv.x.s x10, v5
    if (ex || r !== (64'd10 + 16) * 64'd3) begin
      $display("[FAIL] S1A LMUL=2 vmul->v5 vmv.x.s mismatch: got=0x%0x exp=0x%0x", r, (64'd10+16)*3);
      fail_cnt++;
    end
    wait_backend_idle();
    for (int i = 0; i < 16; i++) begin
      automatic elen_t got = read_elem64(16, i);
      automatic elen_t exp = (64'd10 + 16 + i) * 64'd3;
      if (got !== exp) begin
        $display("[FAIL] S1A LMUL=2 vmul->v5 vmv1r offset RAW mismatch at e=%0d: got=0x%0x exp=0x%0x", i, got, exp);
        fail_cnt++;
      end
    end

    // Also test vs2 offset-group RAW without vsetvli or reshuffle: slow vmv2r.v v4..v5 (VALU) -> fast vmul.vv v18, v5, v20 (VMFPU)
    do_vsetvli(32, EW64, LMUL_2);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd8), '0, '0, r, ex); // establish eew_q[8..9]=EW64
    do_vsetvli(16, EW64, LMUL_1);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd20, 5'd20, 3'b000, 5'd20), '0, '0, r, ex); // establish eew_q[20]=EW64
    wait_backend_idle();
    for (int i = 0; i < 16; i++) write_elem64(20, i, 64'd5);
    for (int i = 0; i < 32; i++) begin
      write_elem64(4, i, 64'hBEEF_0000 + i);
      write_elem64(8, i, 64'd20 + i);
    end
    cfg_alu_lat = 9; cfg_mfpu_lat = 1;
    issue_insn(enc_vv(6'b100111, 1'b1, 5'd8, 5'd1, 3'b011, 5'd4), '0, '0, r, ex);   // slow vmv2r.v v4..v5, v8..v9 (VALU)
    issue_insn(enc_vv(6'b100101, 1'b1, 5'd5, 5'd20, 3'b010, 5'd18), '0, '0, r, ex); // fast vmul.vv v18, v5, v20 (vs2=v5 != base_vd=v4!)
    wait_backend_idle();
    for (int i = 0; i < 16; i++) begin
      automatic elen_t got = read_elem64(18, i);
      automatic elen_t exp = (64'd20 + 16 + i) * 64'd5;
      if (got !== exp) begin
        $display("[FAIL] S1A vmv2r->vmul(vs2=v5) offset RAW mismatch at e=%0d: got=0x%0x exp=0x%0x", i, got, exp);
        fail_cnt++;
      end
    end
    cfg_alu_lat = 1; cfg_mfpu_lat = 8;

    // 1B: LMUL=4 vid.v v8..v11 & viota.m v12..v15 & vaadd.vv v16..v19 -> consumer reading v11, v15, v19
    do_vsetvli(64, EW64, LMUL_4);
    write_elem64(2, 0, 64'hAAAA_AAAA_AAAA_AAAA); // v2 mask source (LMUL_1!)
    write_elem64(2, 1, 64'h5555_5555_5555_5555);
    for (int i = 0; i < 64; i++) begin
      write_elem64(8,  i, 64'hBAD0_0000);
      write_elem64(12, i, 64'hBAD1_0000);
    end
    issue_insn(enc_vv(6'b010100, 1'b1, 5'd0, 5'b10001, 3'b010, 5'd8), '0, '0, r, ex);  // vid.v v8 (LMUL=4 -> v8..v11)
    issue_insn(enc_vv(6'b010100, 1'b1, 5'd2, 5'b10000, 3'b010, 5'd12), '0, '0, r, ex); // viota.m v12, v2 (vs2=v2 is LMUL_1, vd=v12..v15!)
    if (ex) begin $display("[FAIL] S1B unexpected illegal on viota.m v12, v2 under LMUL=4"); fail_cnt++; end
    do_vsetvli(16, EW64, LMUL_1);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd11, 5'd15, 3'b000, 5'd24), '0, '0, r, ex); // vadd.vv v24, v11, v15 (reads 4th reg of vid & viota!)
    wait_backend_idle();
    for (int i = 0; i < 16; i++) begin
      if (read_elem64(8, 48 + i) !== elen_t'(48 + i)) begin
        $display("[FAIL] S1B LMUL=4 vid.v v11 mismatch at e=%0d: got=%0d exp=%0d", i, read_elem64(8, 48+i), 48+i);
        fail_cnt++;
      end
    end

    // 1C: Reduction vs1 scalar at LMUL=1 (v1 unaligned to LMUL=2!) & VWXUNARY0 (vmv.x.s, vcpop.m, vfirst.m) under LMUL=4
    do_vsetvli(32, EW64, LMUL_2);
    write_elem64(1, 0, 64'd50); // v1 scalar init (valid LMUL_1 reg even when vlmul=LMUL_2!)
    for (int i = 0; i < 32; i++) write_elem64(4, i, 64'd2);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd4, 5'd1, 3'b010, 5'd3), '0, '0, r, ex); // vredsum.vs v3, v4, v1
    if (ex) begin $display("[FAIL] S1C vredsum.vs rejected odd scalar vs1/vd under LMUL=2!"); fail_cnt++; end
    wait_backend_idle();
    if (read_elem64(3, 0) !== 64'd114) begin
      $display("[FAIL] S1C vredsum.vs result mismatch: got=%0d exp=114", read_elem64(3, 0));
      fail_cnt++;
    end

    do_vsetvli(32, EW64, LMUL_4);
    write_elem64(7, 0, 64'hCAFE_BABE_1234_5678);
    issue_insn(enc_vv(6'b010000, 1'b1, 5'd7, 5'b00000, 3'b010, 5'd10), '0, '0, r, ex); // vmv.x.s x10, v7 (rs1=00000, vs2=v7 single reg!)
    if (ex || r !== 64'hCAFE_BABE_1234_5678) begin
      $display("[FAIL] S1C vmv.x.s under LMUL=4 failed: ex=%0b r=0x%0x", ex, r);
      fail_cnt++;
    end
    write_elem64(6, 0, 64'b1010_0100); // lane 0 bits (elems 0,2,4,6..): bit 2 -> elem 4, bit 5 -> elem 10, bit 7 -> elem 14
    write_elem64(6, 1, 64'b0000_0000);
    issue_insn(enc_vv(6'b010000, 1'b1, 5'd6, 5'b10000, 3'b010, 5'd11), '0, '0, r, ex); // vcpop.m (rs1=10000 -> odd 16, must NOT check LMUL=4 vs1!)
    if (ex || r !== 64'd3) begin
      $display("[FAIL] S1C vcpop.m under LMUL=4 failed: ex=%0b r=%0d exp=3", ex, r);
      fail_cnt++;
    end
    issue_insn(enc_vv(6'b010000, 1'b1, 5'd6, 5'b10001, 3'b010, 5'd12), '0, '0, r, ex); // vfirst.m (rs1=10001 -> 17, must NOT check LMUL=4 vs1!)
    if (ex || r !== 64'd4) begin
      $display("[FAIL] S1C vfirst.m under LMUL=4 failed: ex=%0b r=%0d exp=4", ex, r);
      fail_cnt++;
    end
  endtask

  // Suite 2: Active Vector Chaining Overlap vs. Unchainable Hazard Stall Interlocks
  task automatic run_suite2_chaining_and_hazards();
    elen_t r; logic ex;
    cfg_alu_lat = 1; cfg_mfpu_lat = 9; cfg_masku_lat = 5; cfg_sldu_lat = 4; cfg_lsu_lat = 2;

    // 2A: Aligned RAW + WAW + WAR chaining must run concurrently (max_concurrent_vinsn >= 2) AND be bit-exact
    do_vsetvli(32, EW64, LMUL_2);
    for (int i = 0; i < 32; i++) begin
      write_elem64(4,  i, 64'd1 + i);
      write_elem64(8,  i, 64'd5 + i);
      write_elem64(12, i, 64'd7);
      write_elem64(16, i, 64'd100 + i);
      write_elem64(20, i, 64'd200 + i);
    end
    wait_backend_idle();
    max_concurrent_vinsn = 0;
    issue_insn(enc_vv(6'b100101, 1'b1, 5'd8,  5'd12, 3'b010, 5'd4),  '0, '0, r, ex); // vmul.vv v4, v8, v12 (slow)
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd4,  5'd16, 3'b000, 5'd24), '0, '0, r, ex); // vadd.vv v24, v4, v16 (aligned RAW chain!)
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd16, 5'd20, 3'b000, 5'd4),  '0, '0, r, ex); // vadd.vv v4, v16, v20 (aligned WAR+WAW chain!)
    wait_backend_idle();
    if (max_concurrent_vinsn < 2) begin
      $display("[FAIL] S2A Aligned linear chaining serialized! max_concurrent_vinsn=%0d (expected >= 2)", max_concurrent_vinsn);
      fail_cnt++;
    end
    for (int i = 0; i < 32; i++) begin
      automatic elen_t exp24 = (64'd5 + i) * 64'd7 + (64'd100 + i);
      automatic elen_t exp4  = (64'd100 + i) + (64'd200 + i);
      if (read_elem64(24, i) !== exp24) begin
        $display("[FAIL] S2A Chained RAW v24[%0d] mismatch: got=0x%0x exp=0x%0x", i, read_elem64(24, i), exp24);
        fail_cnt++;
      end
      if (read_elem64(4, i) !== exp4) begin
        $display("[FAIL] S2A Chained WAR/WAW v4[%0d] mismatch: got=0x%0x exp=0x%0x", i, read_elem64(4, i), exp4);
        fail_cnt++;
      end
    end

    // 2B: Multi-reader WAR hazard (slow vmul + fast vsub both reading v4, then fast vadd overwriting v4)
    do_vsetvli(16, EW64, LMUL_1);
    for (int i = 0; i < 16; i++) begin
      write_elem64(4,  i, 64'd11 + i);
      write_elem64(5,  i, 64'd3);
      write_elem64(6,  i, 64'd2);
      write_elem64(7,  i, 64'd900 + i);
    end
    issue_insn(enc_vv(6'b100101, 1'b1, 5'd4, 5'd5, 3'b010, 5'd10), '0, '0, r, ex); // vid0: vmul.vv v10, v4, v5 (slow reader of v4)
    issue_insn(enc_vv(6'b000010, 1'b1, 5'd4, 5'd6, 3'b000, 5'd11), '0, '0, r, ex); // vid1: vsub.vv v11, v4, v6 (fast reader of v4)
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd7, 5'd6, 3'b000, 5'd4),  '0, '0, r, ex); // vid2: vadd.vv v4, v7, v6  (fast writer of v4 -> WAR on BOTH vid0 & vid1!)
    wait_backend_idle();
    for (int i = 0; i < 16; i++) begin
      if (read_elem64(10, i) !== (64'd11 + i) * 64'd3) begin
        $display("[FAIL] S2B Multi-reader WAR corrupted slow vmul v10[%0d]: got=%0d exp=%0d", i, read_elem64(10, i), (11+i)*3);
        fail_cnt++;
      end
    end

    // 2C: Unchainable no-source WAW (slow vmul writing v4 -> unmasked vle64.v writing v4)
    for (int i = 0; i < 16; i++) ext_mem[i] = 64'hABCD_1000 + i;
    issue_insn(enc_vv(6'b100101, 1'b1, 5'd7, 5'd5, 3'b010, 5'd4), '0, '0, r, ex); // slow vmul.vv v4, v7, v5
    issue_insn(enc_vle64(1'b1, 5'd1, 5'd4), 64'd0, '0, r, ex);                    // vle64.v v4, (0) (no VRF source -> must stall until vmul finishes!)
    wait_backend_idle();
    for (int i = 0; i < 16; i++) begin
      if (read_elem64(4, i) !== (64'hABCD_1000 + i)) begin
        $display("[FAIL] S2C No-source vle64 WAW hazard clobbered by older slow vmul at e=%0d: got=0x%0x", i, read_elem64(4, i));
        fail_cnt++;
      end
    end

    // 2D: v0 Mask RAW & Mask WAR hazards
    for (int i = 0; i < 16; i++) begin
      write_elem64(8,  i, (i % 2 == 0) ? 64'd42 : 64'd99);
      write_elem64(9,  i, 64'd42);
      write_elem64(12, i, 64'h1111_0000 + i);
      write_elem64(14, i, 64'd10);
      write_elem64(15, i, 64'd5);
    end
    write_elem64(0, 0, 64'hFFFF_FFFF_FFFF_FFFF);
    write_elem64(0, 1, 64'h0000_0000_0000_0000);
    // Mask RAW: vmseq.vv v0, v8, v9 -> vadd.vv v12, v14, v15, v0.t
    issue_insn(enc_vv(6'b011000, 1'b1, 5'd8, 5'd9, 3'b000, 5'd0), '0, '0, r, ex);   // vmseq.vv v0, v8, v9 (sets lane 0 mask=1, lane 1 mask=0)
    issue_insn(enc_vv(6'b000000, 1'b0, 5'd14, 5'd15, 3'b000, 5'd12), '0, '0, r, ex); // vadd.vv v12, v14, v15, v0.t
    // Mask WAR: slow masked vmul.vv v16, v14, v15, v0.t reading v0 -> fast vadd.vv v0, v9, v9 overwriting v0=84 (all 0 in low bits? 84=0b01010100)
    for (int i = 0; i < 16; i++) write_elem64(16, i, 64'h7777_0000 + i);
    write_elem64(18, 0, 64'd0); write_elem64(18, 1, 64'hFFFF_FFFF_FFFF_FFFF);
    for (int i = 2; i < 16; i++) write_elem64(18, i, 64'd0);
    issue_insn(enc_vv(6'b100101, 1'b0, 5'd14, 5'd15, 3'b010, 5'd16), '0, '0, r, ex); // slow masked vmul reading v0 (lane 0 enabled, lane 1 disabled)
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd18, 5'd18, 3'b000, 5'd0), '0, '0, r, ex);  // fast vadd writing v0=0 on lane 0! Must stall on Mask WAR!
    wait_backend_idle();
    for (int i = 0; i < 16; i++) begin
      automatic elen_t exp12 = (i % 2 == 0) ? 64'd15 : (64'h1111_0000 + i);
      automatic elen_t exp16 = (i % 2 == 0) ? 64'd50 : (64'h7777_0000 + i);
      if (read_elem64(12, i) !== exp12) begin $display("[FAIL] S2D v0 Mask RAW mismatch at e=%0d: got=0x%0x exp=0x%0x", i, read_elem64(12, i), exp12); fail_cnt++; end
      if (read_elem64(16, i) !== exp16) begin $display("[FAIL] S2D v0 Mask WAR mismatch at e=%0d: got=0x%0x exp=0x%0x", i, read_elem64(16, i), exp16); fail_cnt++; end
    end

    // 2E: Unchainable Slide & Indexed Memory RAW hazards on slow vmul
    for (int i = 0; i < 16; i++) begin
      write_elem64(20, i, 64'd0);
      write_elem64(21, i, elen_t'(i));
      write_elem64(22, i, 64'd8); // stride=8 bytes -> elem i*8 bytes
      ext_mem[100 + i] = 64'h5500_0000 + i;
    end
    issue_insn(enc_vv(6'b100101, 1'b1, 5'd21, 5'd22, 3'b010, 5'd20), '0, '0, r, ex); // slow vmul.vv v20, v21, v22 -> byte offsets 0,8,16..
    issue_insn(enc_vv(6'b001110, 1'b1, 5'd20, 5'd2,  3'b100, 5'd25), 64'd2, '0, r, ex); // vslideup.vx v25, v20, rs1=2
    issue_insn(enc_vluxei64(1'b1, 5'd20, 5'd1, 5'd26), 64'd800, '0, r, ex);          // vluxei64.v v26, (800), v20 (base=800B=mem[100])
    wait_backend_idle();
    for (int i = 2; i < 16; i++)
      if (read_elem64(25, i) !== elen_t'((i - 2) * 8)) begin
        $display("[FAIL] S2E vslideup RAW hazard mismatch at e=%0d: got=%0d exp=%0d", i, read_elem64(25, i), (i-2)*8);
        fail_cnt++;
      end
    for (int i = 0; i < 16; i++)
      if (read_elem64(26, i) !== (64'h5500_0000 + i)) begin
        $display("[FAIL] S2E vluxei64 RAW hazard mismatch at e=%0d: got=0x%0x exp=0x%0x", i, read_elem64(26, i), 64'h5500_0000+i);
        fail_cnt++;
      end
  endtask

  // Suite 3: VFU Instruction-Queue Depth Saturation & Scalar Move vs. MASKU Multiplexing
  task automatic run_suite3_queues_and_scalar_mux();
    elen_t r; logic ex;
    cfg_alu_lat = 5; cfg_mfpu_lat = 6; cfg_sldu_lat = 8; cfg_masku_lat = 10;
    do_vsetvli(16, EW64, LMUL_1);
    for (int reg_i = 1; reg_i < 30; reg_i++)
      for (int i = 0; i < 16; i++) write_elem64(reg_i, i, elen_t'(reg_i * 10 + i));

    // 3A: Saturate VALU (Depth=4 -> issue 6 independent ops), VMFPU (Depth=4 -> issue 6), SLDU (Depth=2 -> issue 4), MASKU (Depth=1 -> issue 3)
    for (int k = 0; k < 6; k++)
      issue_insn(enc_vv(6'b000000, 1'b1, 5'(1 + k), 5'd1, 3'b000, 5'(10 + k)), '0, '0, r, ex);
    for (int k = 0; k < 6; k++)
      issue_insn(enc_vv(6'b100101, 1'b1, 5'(1 + k), 5'd2, 3'b010, 5'(16 + k)), '0, '0, r, ex);
    for (int k = 0; k < 4; k++)
      issue_insn(enc_vv(6'b001111, 1'b1, 5'(1 + k), 5'd1, 3'b100, 5'(22 + k)), 64'd1, '0, r, ex); // 4x vslidedown (Depth=2!)
    // Also saturate MaskuInsnQueueDepth=1 with 3 back-to-back masked ops while queues are hot
    write_elem64(0, 0, 64'hFFFF); write_elem64(0, 1, 64'hFFFF);
    issue_insn(enc_vv(6'b000000, 1'b0, 5'd2, 5'd3, 3'b000, 5'd27), '0, '0, r, ex); // masked vadd #1
    issue_insn(enc_vv(6'b000000, 1'b0, 5'd3, 5'd2, 3'b000, 5'd28), '0, '0, r, ex); // masked vadd #2
    issue_insn(enc_vv(6'b010100, 1'b1, 5'd2, 5'b00001, 3'b010, 5'd29), '0, '0, r, ex); // vmsbf.m #3
    wait_backend_idle();

    // 3B: Direct MaskB collision check (zero reshuffle, idle NrVInsn slots): vmseq.vv holds MaskB while vmv.x.s arrives
    cfg_alu_lat = 1; cfg_masku_lat = 12;
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd2, 5'd2, 3'b000, 5'd2), '0, '0, r, ex); // eew_q[2]=EW64
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd3, 5'd3, 3'b000, 5'd3), '0, '0, r, ex); // eew_q[3]=EW64
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd4, 5'd4, 3'b000, 5'd4), '0, '0, r, ex); // eew_q[4]=EW64 (no reshuffle on vmv.x.s!)
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd6, 5'd6, 3'b000, 5'd6), '0, '0, r, ex); // eew_q[6]=EW64
    wait_backend_idle();
    for (int i = 0; i < 16; i++) begin
      write_elem64(2, i, 64'd100 + i);
      write_elem64(3, i, 64'd100 + (i & ~1));
    end
    write_elem64(26, 0, 64'hBAD0_BAD0_BAD0_BAD0);
    write_elem64(4,  0, 64'h9988_7766_5544_3322);
    issue_insn(enc_vv(6'b011000, 1'b1, 5'd2, 5'd3, 3'b000, 5'd26), '0, '0, r, ex); // vmseq.vv v26, v2, v3 (holds MaskB!)
    issue_insn(enc_vv(6'b010000, 1'b1, 5'd4, 5'b00000, 3'b010, 5'd10), '0, '0, r, ex); // vmv.x.s x10, v4 -> must wait for MASKU!
    if (r !== 64'h9988_7766_5544_3322) begin
      $display("[FAIL] S3B vmv.x.s collided with active MASKU MaskB traffic: got=0x%0x exp=0x9988776655443322", r);
      fail_cnt++;
    end
    write_elem64(5, 0, 64'h000F); write_elem64(5, 1, 64'h0003);
    issue_insn(enc_vv(6'b010000, 1'b1, 5'd5, 5'b10000, 3'b010, 5'd11), '0, '0, r, ex); // vcpop.m -> 6 bits (must NOT pop MaskB!)
    if (r !== 64'd6) begin
      $display("[FAIL] S3B vcpop.m mismatch: got=%0d exp=6", r);
      fail_cnt++;
    end
    write_elem64(6, 0, 64'h1357_2468_ABCD_EF01);
    issue_insn(enc_vv(6'b010000, 1'b1, 5'd6, 5'b00000, 3'b010, 5'd12), '0, '0, r, ex); // vmv.x.s -> verifies MaskB remained clean!
    if (r !== 64'h1357_2468_ABCD_EF01) begin
      $display("[FAIL] S3B vmv.x.s after vcpop.m mismatch: got=0x%0x", r);
      fail_cnt++;
    end
    wait_backend_idle();
  endtask


  // Suite 4: Zero-Length No-Op Retirement & OpcodeSystem CSR Drain / Bitfield Semantics
  task automatic run_suite4_zero_vl_and_csr();
    elen_t r; logic ex;
    int rsh_before;
    cfg_alu_lat = 2; cfg_mfpu_lat = 6; cfg_sldu_lat = 3; cfg_masku_lat = 3;

    // 4A: Zero-vl, vstart>=vl, and null_vslideup must retire without RESHUFFLE or eew_q mutation
    do_vsetvli(32, EW64, LMUL_2);
    for (int i = 0; i < 32; i++) write_elem64(8, i, 64'd10 + i);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd8), '0, '0, r, ex); // establish eew_q[8..9]=EW64
    wait_backend_idle();
    rsh_before = reshuffle_issue_cnt;

    // vl == 0 with EW8 must NOT reshuffle or mutate eew_q[8..9]
    do_vsetvli(0, EW8, LMUL_2);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd8), '0, '0, r, ex);
    // vstart >= vl with EW16 must NOT reshuffle or mutate eew_q[8]
    do_vsetvli(16, EW16, LMUL_1);
    issue_insn(enc_csr(12'h008, 5'd1, 3'b001, 5'd1), 64'd16, '0, r, ex); // csrrw vstart = 16
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd8), '0, '0, r, ex);
    // null_vslideup (stride=8 >= vl=8) with EW32 must NOT reshuffle or mutate eew_q[8]
    do_vsetvli(8, EW32, LMUL_1);
    issue_insn(enc_vv(6'b001110, 1'b1, 5'd8, 5'd1, 3'b100, 5'd8), 64'd8, '0, r, ex); // vslideup.vx stride=8

    // Partial EW64 write on v8..v9: if eew_q[8..9] stayed EW64, zero reshuffles occur!
    do_vsetvli(16, EW64, LMUL_2);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd8), '0, '0, r, ex);
    wait_backend_idle();
    if (reshuffle_issue_cnt != rsh_before) begin
      $display("[FAIL] S4A Zero-trip instructions triggered spurious RESHUFFLE or mutated eew_q (%0d -> %0d)!",
               rsh_before, reshuffle_issue_cnt);
      fail_cnt++;
    end

    // Real EW8 partial write on LMUL=2 v8..v9 must trigger LMUL_1 reshuffle cleanly
    do_vsetvli(8, EW8, LMUL_2);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd8), '0, '0, r, ex);
    wait_backend_idle();
    if (reshuffle_issue_cnt <= rsh_before) begin
      $display("[FAIL] S4A Expected genuine RESHUFFLE on partial EW8 write after EW64!");
      fail_cnt++;
    end

    // Restore clean EW64 across v8..v9
    do_vsetvli(32, EW64, LMUL_2);
    issue_insn(enc_vv(6'b000000, 1'b1, 5'd8, 5'd8, 3'b000, 5'd8), '0, '0, r, ex);
    wait_backend_idle();

    // 4B: OpcodeSystem CSR drain ordering (including after WAIT_IDLE) & bit-exact VXRM/VXSAT/VCSR
    issue_insn(enc_csr(12'h00F, 5'd1, 3'b001, 5'd0), 64'd0, '0, r, ex); // clear VCSR
    cfg_alu_lat = 8;
    cfg_force_vxsat = 1'b1;
    // Trigger LMUL change (LMUL_2 -> LMUL_1 enters WAIT_IDLE) then slow vsaddu.vv + immediate CSR_VXSAT read
    do_vsetvli(16, EW64, LMUL_1);
    for (int i = 0; i < 16; i++) begin
      write_elem64(10, i, 64'hFFFF_FFFF_FFFF_FFF0);
      write_elem64(11, i, 64'h0000_0000_0000_00FF);
    end
    issue_insn(enc_vv(6'b100000, 1'b1, 5'd10, 5'd11, 3'b000, 5'd12), '0, '0, r, ex); // vsaddu.vv (sets vxsat on last word)
    issue_insn(enc_csr(12'h009, 5'd0, 3'b010, 5'd5), 64'd0, '0, r, ex);              // csrrs x5, vxsat, x0
    cfg_force_vxsat = 1'b0;
    if (ex || r !== 64'd1 || !ara_idle) begin
      $display("[FAIL] S4B CSR_VXSAT read did not drain slow vsaddu.vv: ex=%0b r=0x%0x idle=%0b", ex, r, ara_idle);
      fail_cnt++;
    end

    // Slow VMFPU fflags + immediate CSR_VL read must wait until ara_idle
    cfg_mfpu_lat = 8;
    cfg_force_fflags = 1'b1;
    issue_insn(enc_vv(6'b100101, 1'b1, 5'd10, 5'd11, 3'b010, 5'd13), '0, '0, r, ex); // slow vmul.vv
    issue_insn(enc_csr(12'hC20, 5'd0, 3'b010, 5'd6), 64'd0, '0, r, ex);              // csrrs x6, vl, x0
    cfg_force_fflags = 1'b0;
    if (ex || r !== 64'd16 || !ara_idle) begin
      $display("[FAIL] S4B CSR_VL read did not drain slow vmul.vv: ex=%0b r=%0d idle=%0b", ex, r, ara_idle);
      fail_cnt++;
    end

    // Bit-exact VXRM [1:0], VXSAT [0], VCSR {vxrm[1:0], vxsat[0]} across reg & imm CSR ops
    issue_insn(enc_csr(12'h00A, 5'd1, 3'b001, 5'd1), 64'b10, '0, r, ex);   // csrrw vxrm = 2
    issue_insn(enc_csr(12'h00A, 5'b00001, 3'b110, 5'd2), 64'd1, '0, r, ex); // csrrsi vxrm |= 1 -> old=2, new=3
    if (ex || r !== 64'd2) begin $display("[FAIL] S4B CSR_VXRM csrrw/csrrsi old mismatch: r=%0d exp=2", r); fail_cnt++; end
    issue_insn(enc_csr(12'h00F, 5'd0, 3'b010, 5'd3), 64'd0, '0, r, ex);    // csrrs vcsr -> {vxrm=3, vxsat=1} = 7
    if (ex || r !== 64'd7) begin $display("[FAIL] S4B CSR_VCSR read mismatch: r=%0d exp=7", r); fail_cnt++; end
    issue_insn(enc_csr(12'h00F, 5'b00011, 3'b111, 5'd4), 64'd3, '0, r, ex); // csrrci vcsr &= ~3 -> {vxrm=2, vxsat=0} = 4
    issue_insn(enc_csr(12'h00F, 5'd1, 3'b011, 5'd5), 64'b100, '0, r, ex);   // csrrc vcsr &= ~4 -> old=4, new=0
    if (ex || r !== 64'd4) begin $display("[FAIL] S4B CSR_VCSR csrrci/csrrc mismatch: r=%0d exp=4", r); fail_cnt++; end
    issue_insn(enc_csr(12'h00F, 5'b00101, 3'b101, 5'd6), 64'd5, '0, r, ex); // csrrwi vcsr = 5 ({vxrm=2, vxsat=1})
    if (ex || r !== 64'd0) begin $display("[FAIL] S4B CSR_VCSR csrrwi old mismatch: r=%0d exp=0", r); fail_cnt++; end
    issue_insn(enc_csr(12'h00A, 5'd0, 3'b010, 5'd7), 64'd0, '0, r, ex);
    if (ex || r !== 64'd2) begin $display("[FAIL] S4B CSR_VXRM after csrrwi vcsr=5 mismatch: r=%0d exp=2", r); fail_cnt++; end

    // Read-only CSRs (CSR_VLENB, CSR_VL, CSR_VTYPE) must return architectural values on rs1=0 and trap on writes
    issue_insn(enc_csr(12'hC22, 5'd0, 3'b010, 5'd8), 64'd0, '0, r, ex);
    if (ex || r !== elen_t'(VLENB)) begin $display("[FAIL] S4B CSR_VLENB mismatch: r=%0d", r); fail_cnt++; end
    issue_insn(enc_csr(12'hC20, 5'd1, 3'b010, 5'd8), 64'd1, '0, r, ex); // illegal write to CSR_VL!
    if (!ex) begin $display("[FAIL] S4B Expected illegal exception writing read-only CSR_VL!"); fail_cnt++; end
  endtask

  // Suite 5: Seed-Parameterized Multi-LMUL Multi-VFU Scoreboard & Chaining Stress
  task automatic run_suite5_random_stress(int s);
    elen_t gold_vrf [32][16];
    elen_t r; logic ex;
    int unsigned rng;
    rng = 32'(s) ^ 32'h9E37_79B9;

    // Initialize all 32 registers at EW64 cleanly
    do_vsetvli(128, EW64, LMUL_8);
    for (int g = 0; g < 32; g += 8) begin
      for (int i = 0; i < 128; i++)
        write_elem64(g, i, (64'(rng + g * 37 + i) * 64'h0101_0101_0001_0003) ^ 64'(i));
      issue_insn(enc_vv(6'b000000, 1'b1, 5'(g), 5'd0, 3'b011, 5'(g)), '0, '0, r, ex); // vadd.vi vg, vg, 0
    end
    wait_backend_idle();
    for (int v = 0; v < 32; v++)
      for (int e = 0; e < 16; e++)
        gold_vrf[v][e] = read_elem64(v, e);
    for (int m = 0; m < 256; m++)
      ext_mem[m] = 64'hF00D_0000_0000_0000 ^ (64'(s) << 16) ^ 64'(m * 13);

    for (int step = 0; step < 28; step++) begin
      automatic logic use_m2 = ((rng >> 3) & 1) != 0;
      automatic int nreg     = use_m2 ? 2 : 1;
      automatic int nelem    = 16 * nreg;
      automatic int vd, vs1, vs2, op_sel, mbase;
      rng = rng * 32'd1664525 + 32'd1013904223;
      cfg_alu_lat  = 1 + int'(rng % 4);
      cfg_mfpu_lat = 2 + int'((rng >> 4) % 7);
      cfg_lsu_lat  = 1 + int'((rng >> 8) % 4);

      if (use_m2) begin
        do_vsetvli(32, EW64, LMUL_2);
        vd  = 2 * (1 + int'((rng >> 10) % 15));
        vs1 = 2 * (1 + int'((rng >> 15) % 15));
        vs2 = 2 * (1 + int'((rng >> 20) % 15));
      end else begin
        do_vsetvli(16, EW64, LMUL_1);
        vd  = 1 + int'((rng >> 10) % 31);
        vs1 = 1 + int'((rng >> 15) % 31);
        vs2 = 1 + int'((rng >> 20) % 31);
      end
      op_sel = int'((rng >> 25) % 6);
      mbase  = int'((rng >> 12) % 160);

      case (op_sel)
        0: begin // vadd.vv
          issue_insn(enc_vv(6'b000000, 1'b1, 5'(vs2), 5'(vs1), 3'b000, 5'(vd)), '0, '0, r, ex);
          for (int i = 0; i < nelem; i++)
            gold_vrf[vd + (i/16)][i%16] = gold_vrf[vs2 + (i/16)][i%16] + gold_vrf[vs1 + (i/16)][i%16];
        end
        1: begin // vsub.vv
          issue_insn(enc_vv(6'b000010, 1'b1, 5'(vs2), 5'(vs1), 3'b000, 5'(vd)), '0, '0, r, ex);
          for (int i = 0; i < nelem; i++)
            gold_vrf[vd + (i/16)][i%16] = gold_vrf[vs2 + (i/16)][i%16] - gold_vrf[vs1 + (i/16)][i%16];
        end
        2: begin // vmul.vv (slow VMFPU)
          issue_insn(enc_vv(6'b100101, 1'b1, 5'(vs2), 5'(vs1), 3'b010, 5'(vd)), '0, '0, r, ex);
          for (int i = 0; i < nelem; i++)
            gold_vrf[vd + (i/16)][i%16] = gold_vrf[vs2 + (i/16)][i%16] * gold_vrf[vs1 + (i/16)][i%16];
        end
        3: begin // vxor.vv
          issue_insn(enc_vv(6'b001011, 1'b1, 5'(vs2), 5'(vs1), 3'b000, 5'(vd)), '0, '0, r, ex);
          for (int i = 0; i < nelem; i++)
            gold_vrf[vd + (i/16)][i%16] = gold_vrf[vs2 + (i/16)][i%16] ^ gold_vrf[vs1 + (i/16)][i%16];
        end
        4: begin // vle64.v
          issue_insn(enc_vle64(1'b1, 5'd1, 5'(vd)), elen_t'(mbase * 8), '0, r, ex);
          for (int i = 0; i < nelem; i++)
            gold_vrf[vd + (i/16)][i%16] = ext_mem[mbase + i];
        end
        default: begin // vmv.x.s scalar read check
          issue_insn(enc_vv(6'b010000, 1'b1, 5'(vs2), 5'b00000, 3'b010, 5'd10), '0, '0, r, ex);
          if (ex || r !== gold_vrf[vs2][0]) begin
            $display("[FAIL] S5 step=%0d vmv.x.s v%0d mismatch: got=0x%0x exp=0x%0x", step, vs2, r, gold_vrf[vs2][0]);
            fail_cnt++;
          end
        end
      endcase
    end

    wait_backend_idle();
    for (int v = 1; v < 32; v++) begin
      for (int e = 0; e < 16; e++) begin
        if (read_elem64(v, e) !== gold_vrf[v][e]) begin
          $display("[FAIL] S5 Final VRF mismatch at v%0d[%0d]: got=0x%0x exp=0x%0x",
                   v, e, read_elem64(v, e), gold_vrf[v][e]);
          fail_cnt++;
        end
      end
    end
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    acc_req        = '0;
    load_complete  = 1'b0;
    store_complete = 1'b0;
    store_pending  = 1'b0;
    for (int m = 0; m < 512; m++) ext_mem[m] = '0;
    for (int l = 0; l < NrLanes; l++)
      for (int b = 0; b < NrBanks; b++)
        for (int r = 0; r < 32; r++)
          vrf_mem[l][b][r] = '0;

    rst_n = 1'b0;
    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    run_suite1_lmul_opmvv();
    run_suite2_chaining_and_hazards();
    run_suite3_queues_and_scalar_mux();
    run_suite4_zero_vl_and_csr();
    run_suite5_random_stress(seed);

    if (fail_cnt == 0) begin
      $display("PASS seed=%0d", seed);
      $finish;
    end else begin
      $display("FAIL seed=%0d fail_cnt=%0d", seed, fail_cnt);
      $fatal(1, "Testbench failed with %0d errors", fail_cnt);
    end
  end

endmodule
