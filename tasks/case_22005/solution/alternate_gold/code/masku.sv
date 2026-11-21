// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Mask Unit (Alternate Architecture: Full-Beat Parallel Prefix & Wide 4-Way VIOTA Engine)

module masku import ara_pkg::*; import rvv_pkg::*; #(
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
    input  logic                                       clk_i,
    input  logic                                       rst_ni,
    // Interface with the main sequencer / dispatcher
    input  pe_req_t                                    pe_req_i,
    input  logic                                       pe_req_valid_i,
    input  logic     [NrVInsn-1:0]                     pe_vinsn_running_i,
    output logic                                       pe_req_ready_o,
    output pe_resp_t                                   pe_resp_o,
    output elen_t                                      result_scalar_o,
    output logic                                       result_scalar_valid_o,
    input  logic                                       result_scalar_ready_i,
    // Interface with the lanes
    input  elen_t    [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_i,
    input  logic     [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_valid_i,
    output logic     [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_ready_o,
    output logic     [NrLanes-1:0]                     masku_result_req_o,
    output vid_t     [NrLanes-1:0]                     masku_result_id_o,
    output vaddr_t   [NrLanes-1:0]                     masku_result_addr_o,
    output elen_t    [NrLanes-1:0]                     masku_result_wdata_o,
    output strb_t    [NrLanes-1:0]                     masku_result_be_o,
    input  logic     [NrLanes-1:0]                     masku_result_gnt_i,
    input  logic     [NrLanes-1:0]                     masku_result_final_gnt_i,
    output logic     [NrLanes-1:0]                     masku_vrgat_req_valid_o,
    input  logic     [NrLanes-1:0]                     masku_vrgat_req_ready_i,
    output vrgat_req_t                                 masku_vrgat_req_o,
    // Interface with the VFUs
    output strb_t    [NrLanes-1:0]                     mask_o,
    output logic     [NrLanes-1:0]                     mask_valid_o,
    output logic                                       mask_valid_lane_o,
    input  logic     [NrLanes-1:0]                     lane_mask_ready_i,
    input  logic                                       vldu_mask_ready_i,
    input  logic                                       vstu_mask_ready_i,
    input  logic                                       sldu_mask_ready_i
  );

  import cf_math_pkg::idx_width;

  localparam int unsigned BeatBits  = NrLanes * DataWidth;
  localparam int unsigned BeatBytes = NrLanes * StrbWidth;

  logic [idx_width(BeatBits):0] mask_pnt_d, mask_pnt_q;
  logic [idx_width(BeatBits):0] vrf_pnt_d, vrf_pnt_q;

  vlen_t read_cnt_d, read_cnt_q;
  vlen_t issue_cnt_d, issue_cnt_q;
  vlen_t processing_cnt_d, processing_cnt_q;
  vlen_t commit_cnt_d, commit_cnt_q;
  vlen_t global_pos_d, global_pos_q;

  ////////////////
  //  Operands  //
  ////////////////

  masku_fu_e masku_operand_fu;

  elen_t [NrLanes-1:0]  masku_operand_alu;
  logic  [NrLanes-1:0]  masku_operand_alu_valid;
  logic  [NrLanes-1:0]  masku_operand_alu_ready;
  logic  [BeatBits-1:0] masku_operand_alu_seq;

  elen_t [NrLanes-1:0]  masku_operand_vd;
  logic  [NrLanes-1:0]  masku_operand_vd_valid;
  logic  [NrLanes-1:0]  masku_operand_vd_ready;
  logic  [BeatBits-1:0] masku_operand_vd_seq;
  logic  [NrLanes-1:0]  masku_operand_vd_seq_valid;

  elen_t [NrLanes-1:0]  masku_operand_m;
  logic  [NrLanes-1:0]  masku_operand_m_valid;
  logic  [NrLanes-1:0]  masku_operand_m_ready;
  logic  [BeatBits-1:0] masku_operand_m_seq;

  pe_req_t vinsn_issue;

  logic [BeatBits-1:0] active_mask_seq;
  logic [BeatBits-1:0] alu_result_compressed_seq;

  masku_operands #(
    .NrLanes  ( NrLanes   ),
    .pe_req_t ( pe_req_t  ),
    .pe_resp_t( pe_resp_t )
  ) i_masku_operands (
    .clk_i                         (                     clk_i ),
    .rst_ni                        (                    rst_ni ),
    .masku_fu_i                    (          masku_operand_fu ),
    .vinsn_issue_i                 (               vinsn_issue ),
    .vrf_pnt_i                     (                 vrf_pnt_q ),
    .masku_operand_valid_i         (     masku_operand_valid_i ),
    .masku_operand_ready_o         (     masku_operand_ready_o ),
    .masku_operands_i              (           masku_operand_i ),
    .masku_operand_alu_o           (         masku_operand_alu ),
    .masku_operand_alu_valid_o     (   masku_operand_alu_valid ),
    .masku_operand_alu_ready_i     (   masku_operand_alu_ready ),
    .masku_operand_alu_seq_o       (     masku_operand_alu_seq ),
    .masku_operand_alu_seq_valid_o (                           ),
    .masku_operand_alu_seq_ready_i (                        '0 ),
    .masku_operand_vd_o            (          masku_operand_vd ),
    .masku_operand_vd_valid_o      (    masku_operand_vd_valid ),
    .masku_operand_vd_ready_i      (    masku_operand_vd_ready ),
    .masku_operand_vd_seq_o        (      masku_operand_vd_seq ),
    .masku_operand_vd_seq_valid_o  (masku_operand_vd_seq_valid ),
    .masku_operand_vd_seq_ready_i  (                        '0 ),
    .masku_operand_m_o             (           masku_operand_m ),
    .masku_operand_m_valid_o       (     masku_operand_m_valid ),
    .masku_operand_m_ready_i       (     masku_operand_m_ready ),
    .masku_operand_m_seq_o         (       masku_operand_m_seq ),
    .masku_operand_m_seq_valid_o   (                           ),
    .masku_operand_m_seq_ready_i   (                        '0 ),
    .bit_enable_mask_o             (           active_mask_seq ),
    .alu_result_compressed_seq_o   ( alu_result_compressed_seq )
  );

  // Full-beat (256-bit) parallel execution for VCPOP, VFIRST, VMSBF, VMSOF, VMSIF;
  // Wide NrLanes-way (4-element/cycle) parallel prefix-sum for VIOTA and VID.
  localparam int unsigned FullBeatParallelism = BeatBits;
  localparam int unsigned WideViotaWays       = NrLanes;

  elen_t                             cpop_acc_d, cpop_acc_q;
  logic                              first_hit_d, first_hit_q;
  elen_t                             first_pos_d, first_pos_q;
  logic                              scan_seen_d, scan_seen_q, scan_seen_comb;
  logic [$clog2(RISCV_MAX_VLEN)-1:0] prefix_sum_d, prefix_sum_q, prefix_sum_comb;

  logic [$clog2(BeatBits):0]         beat_popc_comb;
  logic                              beat_first_valid_comb;
  logic [idx_width(BeatBits)-1:0]    beat_first_offset_comb;

  // Dedicated sequential staging registers for wide VIOTA/VID beats
  logic [BeatBits-1:0]  viota_wdata_seq_d, viota_wdata_seq_q, viota_wdata_seq_comb;
  logic [BeatBytes-1:0] viota_be_seq_d, viota_be_seq_q, viota_be_seq_comb;

  logic [3:0]           elm_per_lane;
  logic [NrLanes-1:0]   additional_elm;
  logic [BeatBytes-1:0] be_vrgat_seq_d, be_vrgat_seq_q, be_vrgat_seq_comb;
  logic [BeatBytes-1:0] be_masku_alu_shuf;

  logic [BeatBits-1:0]  alu_result_vm_m, alu_result_vm_shuf;
  elen_t [NrLanes-1:0]  alu_result;

  logic [idx_width(BeatBits):0] delta_elm_d, delta_elm_q;
  logic out_vrf_word_valid, out_scalar_valid;

  ////////////////////////////////
  //  Vector instruction queue  //
  ////////////////////////////////

  localparam VInsnQueueDepth = MaskuInsnQueueDepth;

  struct packed {
    pe_req_t [VInsnQueueDepth-1:0]         vinsn;
    logic [idx_width(VInsnQueueDepth)-1:0] issue_cnt;
    logic [idx_width(VInsnQueueDepth)-1:0] commit_cnt;
  } vinsn_queue_d, vinsn_queue_q;

  logic vinsn_queue_full;
  assign vinsn_queue_full = (vinsn_queue_q.commit_cnt == VInsnQueueDepth);

  logic vinsn_issue_valid;
  assign vinsn_issue       = vinsn_queue_q.vinsn[0];
  assign vinsn_issue_valid = (vinsn_queue_q.issue_cnt != '0);

  pe_req_t vinsn_commit;
  logic    vinsn_commit_valid;
  assign vinsn_commit       = vinsn_queue_q.vinsn[0];
  assign vinsn_commit_valid = (vinsn_queue_q.commit_cnt != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vinsn_queue_q <= '0;
    end else begin
      vinsn_queue_q <= vinsn_queue_d;
    end
  end

  ///////////////////
  //  Mask queues  //
  ///////////////////

  localparam int unsigned MaskQueueDepth = 2;

  strb_t [MaskQueueDepth-1:0][NrLanes-1:0] mask_queue_d, mask_queue_q;
  logic  [MaskQueueDepth-1:0][NrLanes-1:0] mask_queue_valid_d, mask_queue_valid_q;
  logic  [idx_width(MaskQueueDepth)-1:0]   mask_queue_write_pnt_d, mask_queue_write_pnt_q;
  logic  [idx_width(MaskQueueDepth)-1:0]   mask_queue_read_pnt_d, mask_queue_read_pnt_q;
  logic  [idx_width(MaskQueueDepth):0]     mask_queue_cnt_d, mask_queue_cnt_q;

  logic mask_queue_full, mask_queue_empty;
  assign mask_queue_full  = (mask_queue_cnt_q == MaskQueueDepth);
  assign mask_queue_empty = (mask_queue_cnt_q == '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_mask_queue_ff
    if (!rst_ni) begin
      mask_queue_q           <= '0;
      mask_queue_valid_q     <= '0;
      mask_queue_write_pnt_q <= '0;
      mask_queue_read_pnt_q  <= '0;
      mask_queue_cnt_q       <= '0;
    end else begin
      mask_queue_q           <= mask_queue_d;
      mask_queue_valid_q     <= mask_queue_valid_d;
      mask_queue_write_pnt_q <= mask_queue_write_pnt_d;
      mask_queue_read_pnt_q  <= mask_queue_read_pnt_d;
      mask_queue_cnt_q       <= mask_queue_cnt_d;
    end
  end

  /////////////////////
  //  Result queues  //
  /////////////////////

  localparam int unsigned ResultQueueDepth = 2;

  typedef struct packed {
    vid_t   id;
    vaddr_t addr;
    elen_t  wdata;
    strb_t  be;
  } payload_t;

  payload_t [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_d, result_queue_q;
  logic     [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_valid_d, result_queue_valid_q;
  logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_write_pnt_d, result_queue_write_pnt_q;
  logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_read_pnt_d, result_queue_read_pnt_q;
  logic     [idx_width(ResultQueueDepth):0]     result_queue_cnt_d, result_queue_cnt_q;
  logic     [NrLanes-1:0][7:0]                  inflight_writes_d, inflight_writes_q;
  logic                                         no_inflight_writes;

  elen_t [NrLanes-1:0]  result_queue_background_data;
  logic  [BeatBits-1:0] result_queue_mask_seq;
  logic  [BeatBits-1:0] background_data_init_seq, background_data_init_shuf;

  logic result_queue_full, result_queue_empty;
  assign result_queue_full  = (result_queue_cnt_q == ResultQueueDepth);
  assign result_queue_empty = (result_queue_cnt_q == '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_result_queue_ff
    if (!rst_ni) begin
      result_queue_q           <= '0;
      result_queue_valid_q     <= '0;
      result_queue_write_pnt_q <= '0;
      result_queue_read_pnt_q  <= '0;
      result_queue_cnt_q       <= '0;
      inflight_writes_q        <= '0;
    end else begin
      result_queue_q           <= result_queue_d;
      result_queue_valid_q     <= result_queue_valid_d;
      result_queue_write_pnt_q <= result_queue_write_pnt_d;
      result_queue_read_pnt_q  <= result_queue_read_pnt_d;
      result_queue_cnt_q       <= result_queue_cnt_d;
      inflight_writes_q        <= inflight_writes_d;
    end
  end

  ////////////////////
  //  ALU counters  //
  ////////////////////

  localparam int unsigned CNT_W = idx_width(BeatBits);
  typedef logic [CNT_W-1:0] slice_cnt_t;

  logic in_ready_cnt_en, in_ready_cnt_clr;
  slice_cnt_t in_ready_cnt_q, in_ready_threshold_d, in_ready_threshold_q;

  delta_counter #(.WIDTH(CNT_W)) i_in_ready_cnt (
    .clk_i, .rst_ni,
    .clear_i   (in_ready_cnt_clr),
    .en_i      (in_ready_cnt_en ),
    .load_i    (1'b0            ),
    .down_i    (1'b0            ),
    .delta_i   (slice_cnt_t'(1) ),
    .d_i       ('0              ),
    .q_o       (in_ready_cnt_q  ),
    .overflow_o(                )
  );

  logic in_m_ready_cnt_en, in_m_ready_cnt_clr;
  slice_cnt_t in_m_ready_cnt_q, in_m_ready_threshold_d, in_m_ready_threshold_q;

  delta_counter #(.WIDTH(CNT_W)) i_in_m_ready_cnt (
    .clk_i, .rst_ni,
    .clear_i   (in_m_ready_cnt_clr),
    .en_i      (in_m_ready_cnt_en ),
    .load_i    (1'b0              ),
    .down_i    (1'b0              ),
    .delta_i   (slice_cnt_t'(1)   ),
    .d_i       ('0                ),
    .q_o       (in_m_ready_cnt_q  ),
    .overflow_o(                  )
  );

  logic out_valid_cnt_en, out_valid_cnt_clr;
  slice_cnt_t out_valid_cnt_q, out_valid_threshold_d, out_valid_threshold_q;

  delta_counter #(.WIDTH(CNT_W)) i_out_valid_cnt (
    .clk_i, .rst_ni,
    .clear_i   (out_valid_cnt_clr),
    .en_i      (out_valid_cnt_en ),
    .load_i    (1'b0             ),
    .down_i    (1'b0             ),
    .delta_i   (slice_cnt_t'(1)  ),
    .d_i       ('0               ),
    .q_o       (out_valid_cnt_q  ),
    .overflow_o(                 )
  );

  localparam int unsigned MAX_NUM_VRF_WORDS = VLEN / NrLanes / 8;
  localparam int unsigned ITER_CNT_WIDTH    = idx_width(MAX_NUM_VRF_WORDS) + 1;
  logic iteration_cnt_clr;
  logic [ITER_CNT_WIDTH-1:0] iteration_cnt_q;

  delta_counter #(.WIDTH(ITER_CNT_WIDTH)) i_iteration_cnt (
    .clk_i, .rst_ni,
    .clear_i   (iteration_cnt_clr             ),
    .en_i      (out_valid_cnt_clr             ),
    .load_i    (1'b0                          ),
    .down_i    (1'b0                          ),
    .delta_i   ({{(ITER_CNT_WIDTH-1){1'b0}}, 1'b1}),
    .d_i       ('0                            ),
    .q_o       (iteration_cnt_q               ),
    .overflow_o(                              )
  );

  ///////////////////////////////
  //// VRGATHER / VCOMPRESS  ////
  ///////////////////////////////

  localparam int unsigned VrgatFifoDepth = 3;

  logic  vrgat_m_seq_bit;
  logic  vcompress_issue_end_d, vcompress_issue_end_q;
  vlen_t vcompress_cnt_d, vcompress_cnt_q;
  vlen_t effective_elm_cnt;
  vlen_t vrgat_cnt_d, vrgat_cnt_q;
  logic  vcompress_bit;

  logic vrgat_req_fifo_empty, vrgat_req_fifo_full, vrgat_req_fifo_push, vrgat_req_fifo_pop;
  logic vrgat_idx_fifo_empty, vrgat_idx_fifo_full, vrgat_idx_fifo_push, vrgat_idx_fifo_pop;

  max_vlen_t  vrgat_req_idx_d, vrgat_req_idx_q;
  vrgat_req_t vrgat_req_d, vrgat_req_q;

  vew_e       vrgat_req_eew_d;
  logic [4:0] vrgat_req_vs_d;
  logic       vrgat_req_is_last_req_d;

  logic [1:0] vrgat_eff_vsew;
  assign vrgat_eff_vsew = (pe_req_i.op == VRGATHEREI16) ? 2'b1 : unsigned'(pe_req_i.vtype.vsew);

  assign vrgat_req_eew_d  = vinsn_issue.vtype.vsew;
  assign vrgat_req_vs_d   = vinsn_issue.vs2;
  assign vrgat_req_d      = {vrgat_req_idx_d / NrLanes, vrgat_req_eew_d, vrgat_req_vs_d, vrgat_req_is_last_req_d};
  assign masku_vrgat_req_o = vrgat_req_q;

  logic [NrLanes-1:0] vrgat_req_valid_mask_d, vrgat_req_valid_mask_q;

  always_comb begin
    vrgat_req_fifo_pop     = 1'b0;
    vrgat_req_valid_mask_d = vrgat_req_valid_mask_q;

    for (int lane = 0; lane < NrLanes; lane++) begin
      masku_vrgat_req_valid_o[lane] = ~vrgat_req_fifo_empty & ~vrgat_req_valid_mask_q[lane];
      vrgat_req_valid_mask_d[lane]  = masku_vrgat_req_ready_i[lane];
    end

    if (&masku_vrgat_req_ready_i) vrgat_req_valid_mask_d = '0;
    if (&(masku_vrgat_req_ready_i | vrgat_req_valid_mask_q) && ~vrgat_req_fifo_empty)
      vrgat_req_fifo_pop = 1'b1;
  end

  logic vrgat_idx_overflow;
  logic vrgat_idx_oor_d, vrgat_idx_oor_q;
  logic vcompress_last_idx_d, vcompress_last_idx_q;

  fifo_v3 #(
    .DATA_WIDTH($clog2(RISCV_MAX_VLEN) + 2),
    .DEPTH     (VrgatFifoDepth            )
  ) i_fifo_vrgat_idx (
    .clk_i, .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .full_o    (vrgat_idx_fifo_full ),
    .empty_o   (vrgat_idx_fifo_empty),
    .usage_o   (                    ),
    .data_i    ({vcompress_last_idx_d, vrgat_idx_oor_d, vrgat_req_idx_d}),
    .push_i    (vrgat_idx_fifo_push ),
    .data_o    ({vcompress_last_idx_q, vrgat_idx_oor_q, vrgat_req_idx_q}),
    .pop_i     (vrgat_idx_fifo_pop  )
  );

  fifo_v3 #(
    .dtype(vrgat_req_t   ),
    .DEPTH(VrgatFifoDepth)
  ) i_fifo_vrgat_req (
    .clk_i, .rst_ni,
    .flush_i   (1'b0),
    .testmode_i(1'b0),
    .full_o    (vrgat_req_fifo_full ),
    .empty_o   (vrgat_req_fifo_empty),
    .usage_o   (                    ),
    .data_i    (vrgat_req_d         ),
    .push_i    (vrgat_req_fifo_push ),
    .data_o    (vrgat_req_q         ),
    .pop_i     (vrgat_req_fifo_pop  )
  );

  ////////////////////////////
  //// Scalar result reg  ////
  ////////////////////////////

  elen_t result_scalar_d;
  logic  result_scalar_valid_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      result_scalar_o       <= '0;
      result_scalar_valid_o <= '0;
    end else begin
      result_scalar_o       <= result_scalar_d;
      result_scalar_valid_o <= result_scalar_valid_d;
    end
  end

  ////////////////
  //  Mask ALU  //
  ////////////////

  logic [NrVInsn-1:0] vinsn_running_d, vinsn_running_q;
  pe_resp_t           pe_resp;
  elen_t              trimmed_stride;

  assign masku_operand_fu = (vinsn_issue.op inside {[VMFEQ:VMFGE]}) ? MaskFUMFpu : MaskFUAlu;

  always_comb begin : p_masku_alu_comb
    logic [BeatBits-1:0]  body_qualified_bits;
    logic [BeatBits-1:0]  prefix_seen_before;
    logic [BeatBits-1:0]  vmsxf_full_beat_seq;

    alu_result              = '1;
    alu_result_vm_m         = '1;
    alu_result_vm_shuf      = '1;
    vrgat_m_seq_bit         = 1'b0;
    beat_popc_comb          = '0;
    beat_first_valid_comb   = 1'b0;
    beat_first_offset_comb  = '0;
    scan_seen_comb          = scan_seen_q;
    prefix_sum_comb         = prefix_sum_q;
    vmsxf_full_beat_seq     = '0;
    body_qualified_bits     = '0;
    prefix_seen_before      = '0;

    // Initialize or carry forward wide VIOTA/VID staging buffers
    if (out_valid_cnt_q == '0) begin
      viota_wdata_seq_comb = '1;
      for (int b = 0; b < BeatBytes; b++) begin
        automatic int unsigned elm_b = b >> unsigned'(vinsn_issue.vtype.vsew);
        automatic vlen_t       g_b   = vlen_t'(iteration_cnt_q) *
                                       vlen_t'(BeatBytes >> unsigned'(vinsn_issue.vtype.vsew)) +
                                       vlen_t'(elm_b);
        viota_be_seq_comb[b] = (g_b >= vinsn_issue.vl) ? vinsn_issue.vtype.vta : 1'b0;
      end
    end else begin
      viota_wdata_seq_comb = viota_wdata_seq_q;
      viota_be_seq_comb    = viota_be_seq_q;
    end

    be_vrgat_seq_comb = be_vrgat_seq_q;

    // Build full-beat body-qualified active vector for 1-cycle-per-beat operations
    for (int bit_i = 0; bit_i < BeatBits; bit_i++) begin
      automatic vlen_t g_bit = global_pos_q + vlen_t'(bit_i);
      if ((g_bit >= vinsn_issue.vstart) && (g_bit < vinsn_issue.vl)) begin
        body_qualified_bits[bit_i] = masku_operand_alu_seq[bit_i] & active_mask_seq[bit_i];
      end else begin
        body_qualified_bits[bit_i] = 1'b0;
      end
    end

    if (vinsn_issue_valid) begin
      unique case (vinsn_issue.op) inside
        [VMANDNOT:VMXNOR]: alu_result_vm_m = masku_operand_alu_seq;
        [VMFEQ:VMSGT]:     alu_result_vm_m = alu_result_compressed_seq | ~active_mask_seq;
        [VMADC:VMSBC]:     alu_result_vm_m = alu_result_compressed_seq;

        // Full-beat 256-bit parallel prefix-OR scan in a single cycle per beat
        [VMSBF:VMSIF]: begin
          prefix_seen_before[0] = scan_seen_q;
          for (int bit_i = 1; bit_i < BeatBits; bit_i++) begin
            prefix_seen_before[bit_i] = prefix_seen_before[bit_i-1] | body_qualified_bits[bit_i-1];
          end
          scan_seen_comb = prefix_seen_before[BeatBits-1] | body_qualified_bits[BeatBits-1];

          for (int bit_i = 0; bit_i < BeatBits; bit_i++) begin
            automatic vlen_t g_bit = global_pos_q + vlen_t'(bit_i);
            if (g_bit < vinsn_issue.vstart) begin
              vmsxf_full_beat_seq[bit_i] = masku_operand_vd_seq[bit_i];
            end else if (g_bit >= vinsn_issue.vl) begin
              vmsxf_full_beat_seq[bit_i] = vinsn_issue.vtype.vta ? 1'b1 : masku_operand_vd_seq[bit_i];
            end else if (active_mask_seq[bit_i]) begin
              unique case (vinsn_issue.op)
                VMSBF:   vmsxf_full_beat_seq[bit_i] = ~prefix_seen_before[bit_i] & ~body_qualified_bits[bit_i];
                VMSIF:   vmsxf_full_beat_seq[bit_i] = ~prefix_seen_before[bit_i];
                default: vmsxf_full_beat_seq[bit_i] = ~prefix_seen_before[bit_i] &  body_qualified_bits[bit_i];
              endcase
            end else begin
              vmsxf_full_beat_seq[bit_i] = vinsn_issue.vtype.vma ? 1'b1 : masku_operand_vd_seq[bit_i];
            end
          end
          alu_result_vm_m = vmsxf_full_beat_seq;
        end

        // Wide NrLanes-way (4-element/cycle) parallel prefix-sum VIOTA & VID
        VIOTA, VID: begin
          logic [$clog2(RISCV_MAX_VLEN)-1:0] way_val [WideViotaWays-1:0];
          logic [$clog2(RISCV_MAX_VLEN)-1:0] run_sum;
          run_sum = prefix_sum_q;

          for (int w = 0; w < WideViotaWays; w++) begin
            automatic int unsigned local_bit =
              in_ready_cnt_q[idx_width(BeatBits/WideViotaWays)-1:0] * WideViotaWays + w;
            automatic vlen_t g_elm = global_pos_q + vlen_t'(w);
            automatic logic  m_en  = active_mask_seq[local_bit];
            automatic logic  add_1 = (vinsn_issue.op == VIOTA) && (g_elm < vinsn_issue.vl) &&
                                     masku_operand_alu_seq[local_bit] && m_en;

            way_val[w] = (vinsn_issue.op == VID) ? ($clog2(RISCV_MAX_VLEN))'(g_elm) : run_sum;
            run_sum    = run_sum + {{($clog2(RISCV_MAX_VLEN)-1){1'b0}}, add_1};

            unique case (vinsn_issue.vtype.vsew)
              EW8: begin
                automatic int unsigned dst =
                  out_valid_cnt_q[idx_width(BeatBytes/1/WideViotaWays)-1:0] * WideViotaWays + w;
                if (g_elm < vinsn_issue.vstart) begin
                  viota_be_seq_comb[dst] = 1'b0;
                end else if (g_elm < vinsn_issue.vl) begin
                  viota_wdata_seq_comb[dst*8 +: 8] = m_en ? way_val[w][7:0] : 8'hFF;
                  viota_be_seq_comb[dst]           = m_en ? 1'b1 : vinsn_issue.vtype.vma;
                end else begin
                  viota_wdata_seq_comb[dst*8 +: 8] = 8'hFF;
                  viota_be_seq_comb[dst]           = vinsn_issue.vtype.vta;
                end
              end
              EW16: begin
                automatic int unsigned dst =
                  out_valid_cnt_q[idx_width(BeatBytes/2/WideViotaWays)-1:0] * WideViotaWays + w;
                if (g_elm < vinsn_issue.vstart) begin
                  viota_be_seq_comb[dst*2 +: 2] = 2'b00;
                end else if (g_elm < vinsn_issue.vl) begin
                  viota_wdata_seq_comb[dst*16 +: 16] = m_en ? 16'(way_val[w]) : 16'hFFFF;
                  viota_be_seq_comb[dst*2 +: 2]      = m_en ? 2'b11 : {2{vinsn_issue.vtype.vma}};
                end else begin
                  viota_wdata_seq_comb[dst*16 +: 16] = 16'hFFFF;
                  viota_be_seq_comb[dst*2 +: 2]      = {2{vinsn_issue.vtype.vta}};
                end
              end
              EW32: begin
                automatic int unsigned dst =
                  out_valid_cnt_q[idx_width(BeatBytes/4/WideViotaWays)-1:0] * WideViotaWays + w;
                if (g_elm < vinsn_issue.vstart) begin
                  viota_be_seq_comb[dst*4 +: 4] = 4'h0;
                end else if (g_elm < vinsn_issue.vl) begin
                  viota_wdata_seq_comb[dst*32 +: 32] = m_en ? 32'(way_val[w]) : 32'hFFFF_FFFF;
                  viota_be_seq_comb[dst*4 +: 4]      = m_en ? 4'hF : {4{vinsn_issue.vtype.vma}};
                end else begin
                  viota_wdata_seq_comb[dst*32 +: 32] = 32'hFFFF_FFFF;
                  viota_be_seq_comb[dst*4 +: 4]      = {4{vinsn_issue.vtype.vta}};
                end
              end
              default: begin // EW64
                automatic int unsigned dst = w; // 4 EW64 elements == 1 full 256-bit beat per cycle!
                if (g_elm < vinsn_issue.vstart) begin
                  viota_be_seq_comb[dst*8 +: 8] = 8'h00;
                end else if (g_elm < vinsn_issue.vl) begin
                  viota_wdata_seq_comb[dst*64 +: 64] = m_en ? 64'(way_val[w]) : 64'hFFFF_FFFF_FFFF_FFFF;
                  viota_be_seq_comb[dst*8 +: 8]      = m_en ? 8'hFF : {8{vinsn_issue.vtype.vma}};
                end else begin
                  viota_wdata_seq_comb[dst*64 +: 64] = 64'hFFFF_FFFF_FFFF_FFFF;
                  viota_be_seq_comb[dst*8 +: 8]      = {8{vinsn_issue.vtype.vta}};
                end
              end
            endcase
          end

          prefix_sum_comb = run_sum;
          alu_result_vm_m = viota_wdata_seq_comb;
        end

        [VRGATHER:VCOMPRESS]: begin
          logic [BeatBits-1:0]  vrgat_res;
          logic [DataWidth-1:0] vrgat_buf;

          vrgat_res = '1;
          vrgat_buf = masku_operand_vd_seq[vrgat_req_idx_q[idx_width(NrLanes*ELENB/8)-1:0] * 64 +: 64];
          unique case (vinsn_issue.vtype.vsew)
            EW8: begin
              vrgat_buf[0 +: 8] = masku_operand_vd_seq[vrgat_req_idx_q[idx_width(NrLanes*ELENB/1)-1:0] * 8 +: 8];
              vrgat_res[out_valid_cnt_q[idx_width(NrLanes*ELENB/1)-1:0] * 8 +: 8] = vrgat_idx_oor_q ? '0 : vrgat_buf[0 +: 8];
            end
            EW16: begin
              vrgat_buf[0 +: 16] = masku_operand_vd_seq[vrgat_req_idx_q[idx_width(NrLanes*ELENB/2)-1:0] * 16 +: 16];
              vrgat_res[out_valid_cnt_q[idx_width(NrLanes*ELENB/2)-1:0] * 16 +: 16] = vrgat_idx_oor_q ? '0 : vrgat_buf[0 +: 16];
            end
            EW32: begin
              vrgat_buf[0 +: 32] = masku_operand_vd_seq[vrgat_req_idx_q[idx_width(NrLanes*ELENB/4)-1:0] * 32 +: 32];
              vrgat_res[out_valid_cnt_q[idx_width(NrLanes*ELENB/4)-1:0] * 32 +: 32] = vrgat_idx_oor_q ? '0 : vrgat_buf[0 +: 32];
            end
            default: begin
              vrgat_buf[0 +: 64] = masku_operand_vd_seq[vrgat_req_idx_q[idx_width(NrLanes*ELENB/8)-1:0] * 64 +: 64];
              vrgat_res[out_valid_cnt_q[idx_width(NrLanes*ELENB/8)-1:0] * 64 +: 64] = vrgat_idx_oor_q ? '0 : vrgat_buf[0 +: 64];
            end
          endcase

          unique case (vinsn_issue.vtype.vsew)
            EW8: begin
              vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(BeatBits)-1:0]];
              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(BeatBytes/1)-1:0] * 1 +: 1] =
                {1{vinsn_issue.vm}} | {1{vrgat_m_seq_bit}};
            end
            EW16: begin
              vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(BeatBits)-1:0]];
              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(BeatBytes/2)-1:0] * 2 +: 2] =
                {2{vinsn_issue.vm}} | {2{vrgat_m_seq_bit}};
            end
            EW32: begin
              vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(BeatBits)-1:0]];
              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(BeatBytes/4)-1:0] * 4 +: 4] =
                {4{vinsn_issue.vm}} | {4{vrgat_m_seq_bit}};
            end
            default: begin
              vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(BeatBits)-1:0]];
              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(BeatBytes/8)-1:0] * 8 +: 8] =
                {8{vinsn_issue.vm}} | {8{vrgat_m_seq_bit}};
            end
          endcase

          alu_result_vm_m = vrgat_res;
        end

        // Full 256-bit 1-cycle-per-beat popcount & priority find-first scanner
        [VCPOP:VFIRST]: begin
          for (int bit_i = 0; bit_i < BeatBits; bit_i++) begin
            beat_popc_comb = beat_popc_comb + {{$clog2(BeatBits){1'b0}}, body_qualified_bits[bit_i]};
            if (!beat_first_valid_comb && body_qualified_bits[bit_i]) begin
              beat_first_valid_comb  = 1'b1;
              beat_first_offset_comb = bit_i[idx_width(BeatBits)-1:0];
            end
          end
        end

        default:;
      endcase
    end

    for (int b = 0; b < BeatBytes; b++) begin
      automatic int shuffle_byte              = shuffle_index(b, NrLanes, vinsn_issue.vtype.vsew);
      alu_result_vm_shuf[8*shuffle_byte +: 8] = alu_result_vm_m[8*b +: 8];
    end

    be_masku_alu_shuf = '0;
    for (int b = 0; b < BeatBytes; b++) begin
      automatic int shuffle_byte      = shuffle_index(b, NrLanes, vinsn_issue.vtype.vsew);
      be_masku_alu_shuf[shuffle_byte] = vinsn_issue.op inside {VRGATHER, VRGATHEREI16}
                                      ? be_vrgat_seq_comb[b]
                                      : viota_be_seq_comb[b];
    end

    alu_result = alu_result_vm_shuf;

    result_queue_mask_seq = vinsn_issue.op inside {[VIOTA:VID], [VRGATHER:VCOMPRESS]}
                          ? '0
                          : active_mask_seq | {BeatBits{vinsn_issue.op inside {[VMADC:VMSBC]}}};
    background_data_init_seq = (!vinsn_issue.use_vd_op && (vinsn_issue.op inside {[VMANDNOT:VMXNOR]}))
                             ? '1
                             : (masku_operand_vd_seq | result_queue_mask_seq);
    background_data_init_shuf = '0;
    for (int b = 0; b < BeatBytes; b++) begin
      automatic int shuffle_byte                     = shuffle_index(b, NrLanes, vinsn_issue.vtype.vsew);
      background_data_init_shuf[8*shuffle_byte +: 8] = background_data_init_seq[8*b +: 8];
    end
  end

  /////////////////
  //  Mask unit  //
  /////////////////

  always_comb begin : p_masku_ctrl_comb
    elen_t cpop_next;
    logic  first_hit_next;
    elen_t first_pos_next;

    vinsn_queue_d    = vinsn_queue_q;
    read_cnt_d       = read_cnt_q;
    issue_cnt_d      = issue_cnt_q;
    processing_cnt_d = processing_cnt_q;
    commit_cnt_d     = commit_cnt_q;
    global_pos_d     = global_pos_q;

    mask_pnt_d = mask_pnt_q;
    vrf_pnt_d  = vrf_pnt_q;

    cpop_acc_d        = cpop_acc_q;
    first_hit_d       = first_hit_q;
    first_pos_d       = first_pos_q;
    scan_seen_d       = scan_seen_q;
    prefix_sum_d      = prefix_sum_q;
    viota_wdata_seq_d = viota_wdata_seq_q;
    viota_be_seq_d    = viota_be_seq_q;
    be_vrgat_seq_d    = be_vrgat_seq_q;

    cpop_next      = cpop_acc_q;
    first_hit_next = first_hit_q;
    first_pos_next = first_pos_q;

    mask_queue_d           = mask_queue_q;
    mask_queue_valid_d     = mask_queue_valid_q;
    mask_queue_write_pnt_d = mask_queue_write_pnt_q;
    mask_queue_read_pnt_d  = mask_queue_read_pnt_q;
    mask_queue_cnt_d       = mask_queue_cnt_q;

    result_queue_d           = result_queue_q;
    result_queue_valid_d     = result_queue_valid_q;
    result_queue_write_pnt_d = result_queue_write_pnt_q;
    result_queue_read_pnt_d  = result_queue_read_pnt_q;
    result_queue_cnt_d       = result_queue_cnt_q;
    inflight_writes_d        = inflight_writes_q;

    trimmed_stride     = pe_req_i.stride;
    out_vrf_word_valid = 1'b0;
    out_scalar_valid   = 1'b0;

    vinsn_running_d = vinsn_running_q & pe_vinsn_running_i;
    pe_resp         = '0;

    masku_operand_alu_ready = '0;
    masku_operand_m_ready   = '0;
    masku_operand_vd_ready  = '0;

    pe_req_ready_o = !vinsn_queue_full;

    result_scalar_d       = result_scalar_o;
    result_scalar_valid_d = result_scalar_valid_o;

    in_ready_cnt_en   = 1'b0;
    in_m_ready_cnt_en = 1'b0;
    out_valid_cnt_en  = 1'b0;

    for (int unsigned lane = 0; lane < NrLanes; lane++)
      result_queue_background_data[lane] = result_queue_q[result_queue_write_pnt_q][lane].wdata;

    delta_elm_d            = delta_elm_q;
    in_ready_threshold_d   = in_ready_threshold_q;
    in_m_ready_threshold_d = in_m_ready_threshold_q;
    out_valid_threshold_d  = out_valid_threshold_q;

    in_ready_cnt_clr   = 1'b0;
    in_m_ready_cnt_clr = 1'b0;
    out_valid_cnt_clr  = 1'b0;
    iteration_cnt_clr  = 1'b0;

    ////////////////////////////
    //  Predicated execution  //
    ////////////////////////////

    if (!mask_queue_full) begin
      for (int vrf_seq_byte = 0; vrf_seq_byte < BeatBytes; vrf_seq_byte++) begin
        automatic int vrf_byte            = shuffle_index(vrf_seq_byte, NrLanes, vinsn_issue.vtype.vsew);
        automatic int vrf_lane            = vrf_byte >> $clog2(StrbWidth);
        automatic int vrf_offset          = vrf_byte[idx_width(StrbWidth)-1:0];
        automatic int vrf_pnt_byte_offset = mask_pnt_q >> $clog2(StrbWidth);
        automatic int vrf_pnt_bit_offset  = mask_pnt_q[idx_width(StrbWidth)-1:0];
        automatic int mask_seq_bit        = vrf_seq_byte >> int'(vinsn_issue.vtype.vsew);
        automatic int mask_seq_byte       = (mask_seq_bit >> $clog2(StrbWidth)) + vrf_pnt_byte_offset;
        automatic int mask_byte           = shuffle_index(mask_seq_byte, NrLanes, vinsn_issue.eew_vmask);
        automatic int mask_bit            = (mask_byte << $clog2(StrbWidth)) +
                                            mask_seq_bit[idx_width(StrbWidth)-1:0] + vrf_pnt_bit_offset;
        automatic int mask_lane           = mask_bit >> idx_width(DataWidth);
        automatic int mask_offset         = mask_bit[idx_width(DataWidth)-1:0];

        mask_queue_d[mask_queue_write_pnt_q][vrf_lane][vrf_offset] =
          masku_operand_m[mask_lane][mask_offset];
      end

      if (vinsn_issue_valid && ((vinsn_issue.vfu != VFU_MaskUnit) || (vinsn_issue.op inside {[VMADC:VMSBC]}))) begin
        if (!vinsn_issue.vm && &masku_operand_m_valid) begin
          mask_pnt_d += NrLanes * (1 << (int'(EW64) - vinsn_issue.vtype.vsew));

          mask_queue_cnt_d += 1;
          if (mask_queue_write_pnt_q == MaskQueueDepth-1)
            mask_queue_write_pnt_d = '0;
          else
            mask_queue_write_pnt_d = mask_queue_write_pnt_q + 1;

          read_cnt_d = read_cnt_q - NrLanes * (1 << (int'(EW64) - vinsn_issue.vtype.vsew));
          if (read_cnt_q < NrLanes * (1 << (int'(EW64) - vinsn_issue.vtype.vsew)))
            read_cnt_d = '0;

          mask_queue_valid_d[mask_queue_write_pnt_q] = {NrLanes{1'b1}};
          if (read_cnt_q < NrLanes)
            mask_queue_valid_d[mask_queue_write_pnt_q] = (1 << read_cnt_q) - 1;

          if (mask_pnt_d == BeatBits || read_cnt_d == '0) begin
            masku_operand_m_ready = '1;
            mask_pnt_d            = '0;
          end
        end
      end
    end

    for (int lane = 0; lane < NrLanes; lane++) begin : send_operand
      mask_valid_o[lane] = mask_queue_valid_q[mask_queue_read_pnt_q][lane];
      mask_o[lane]       = mask_queue_q[mask_queue_read_pnt_q][lane];
      if ((lane_mask_ready_i[lane] && mask_valid_o[lane] && (vinsn_issue.vfu inside {VFU_Alu, VFU_MFpu} || vinsn_issue.op inside {[VMADC:VMSBC]})) ||
           vldu_mask_ready_i || vstu_mask_ready_i || sldu_mask_ready_i) begin
        mask_queue_valid_d[mask_queue_read_pnt_q][lane] = 1'b0;
        mask_queue_d[mask_queue_read_pnt_q][lane]       = '0;
      end
    end

    mask_valid_lane_o = vinsn_issue.vfu inside {VFU_Alu, VFU_MFpu, VFU_MaskUnit};

    if (!(|mask_queue_valid_d[mask_queue_read_pnt_q])) begin
      if (!mask_queue_empty) begin
        if (mask_queue_read_pnt_q == MaskQueueDepth-1)
          mask_queue_read_pnt_d = 0;
        else
          mask_queue_read_pnt_d = mask_queue_read_pnt_q + 1;

        mask_queue_d[mask_queue_read_pnt_q] = '0;
        mask_queue_cnt_d -= 1;

        if (vldu_mask_ready_i || vstu_mask_ready_i || sldu_mask_ready_i || vinsn_issue.vm || (vinsn_issue.vfu != VFU_MaskUnit)) begin
          commit_cnt_d = commit_cnt_q - NrLanes * (1 << (int'(EW64) - vinsn_commit.vtype.vsew));
          if (commit_cnt_q < (NrLanes * (1 << (int'(EW64) - vinsn_commit.vtype.vsew))))
            commit_cnt_d = '0;
        end
      end
    end

    ////////////////////////
    //  Index generation  //
    ////////////////////////

    vrgat_cnt_d             = vrgat_cnt_q;
    vrgat_req_idx_d         = '0;
    vrgat_idx_fifo_push     = 1'b0;
    vrgat_req_fifo_push     = 1'b0;
    vrgat_idx_overflow      = 1'b0;
    vrgat_idx_oor_d         = 1'b0;
    vcompress_bit           = 1'b0;
    vrgat_req_is_last_req_d = 1'b0;
    vcompress_last_idx_d    = 1'b0;
    vcompress_issue_end_d   = vcompress_issue_end_q;
    vcompress_cnt_d         = vcompress_cnt_q;

    if (vinsn_issue_valid) begin
      unique case (vinsn_issue.op)
        VCOMPRESS: begin
          vcompress_bit   = masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBits)-1:0]];
          vrgat_req_idx_d = vrgat_cnt_q;
          if (&masku_operand_alu_valid && ~vrgat_idx_fifo_full && ~vrgat_req_fifo_full) begin
            if (vcompress_bit) begin
              vrgat_idx_fifo_push = 1'b1;
              vrgat_req_fifo_push = 1'b1;
              vcompress_cnt_d     = vcompress_cnt_q + 1;
            end
          end
        end
        VRGATHER,
        VRGATHEREI16: begin
          automatic int unsigned vlmax = (VLEN/8) >> vinsn_issue.vtype.vsew;
          unique case (vinsn_issue.vtype.vlmul)
            LMUL_1  : vlmax <<= 0;
            LMUL_2  : vlmax <<= 1;
            LMUL_4  : vlmax <<= 2;
            LMUL_8  : vlmax <<= 3;
            LMUL_1_2: vlmax >>= 1;
            LMUL_1_4: vlmax >>= 2;
            LMUL_1_8: vlmax >>= 3;
            default:;
          endcase

          if (vinsn_issue.op == VRGATHER) begin
            unique case (vinsn_issue.vtype.vsew)
              EW8:  vrgat_req_idx_d = {8'b0, masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBytes/1)-1:0] * 8 +: 8]};
              EW16: vrgat_req_idx_d = masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBytes/2)-1:0] * 16 +: 16];
              EW32: begin
                vrgat_req_idx_d    = masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBytes/4)-1:0] * 32 +: 16];
                vrgat_idx_overflow = |masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBytes/4)-1:0] * 32 + 16 +: 16];
              end
              default: begin
                vrgat_req_idx_d    = masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBytes/8)-1:0] * 64 +: 16];
                vrgat_idx_overflow = |masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBytes/8)-1:0] * 64 + 16 +: 48];
              end
            endcase
          end else begin
            vrgat_req_idx_d = masku_operand_alu_seq[vrgat_cnt_q[idx_width(BeatBytes/2)-1:0] * 16 +: 16];
          end

          if (vinsn_issue.use_scalar_op) begin
            vrgat_req_idx_d    = vinsn_issue.scalar_op[15:0];
            vrgat_idx_overflow = |vinsn_issue.scalar_op[16 +: ELEN - 16];
          end

          vrgat_idx_oor_d = (vrgat_req_idx_d >= vlmax) | vrgat_idx_overflow;

          if (&masku_operand_alu_valid && ~vrgat_idx_fifo_full && ~vrgat_req_fifo_full) begin
            vrgat_idx_fifo_push = 1'b1;
            if (!vrgat_idx_oor_d) begin
              vrgat_req_fifo_push = 1'b1;
            end
          end
        end
        default:;
      endcase
    end

    if (vinsn_issue.op inside {[VRGATHER:VCOMPRESS]} && &masku_operand_alu_valid &&
        (vrgat_idx_fifo_push || (~vrgat_idx_fifo_full && ~vrgat_req_fifo_full && (vinsn_issue.op == VCOMPRESS)))) begin
      vrgat_cnt_d     = vrgat_cnt_q + 1;
      in_ready_cnt_en = 1'b1;

      if ((in_ready_cnt_q == in_ready_threshold_q) || (vrgat_cnt_q == (vinsn_issue.vl - 1))) begin
        in_ready_cnt_clr        = 1'b1;
        masku_operand_alu_ready = '1;
        if (vrgat_cnt_q == (vinsn_issue.vl - 1)) begin
          vrgat_cnt_d             = '0;
          vcompress_last_idx_d    = (vinsn_issue.op == VCOMPRESS);
          vrgat_req_is_last_req_d = 1'b1;
        end
      end
    end

    ///////////////////////
    // MASKU ALU Control //
    ///////////////////////

    vrgat_idx_fifo_pop = 1'b0;

    effective_elm_cnt = vinsn_issue.op == VCOMPRESS ? vcompress_cnt_q : processing_cnt_q;
    elm_per_lane      = effective_elm_cnt / NrLanes;
    if ((effective_elm_cnt / NrLanes) > 4'b1000)
      elm_per_lane = 4'b1000;
    for (int l = 0; l < NrLanes; l++) additional_elm[l] = effective_elm_cnt[idx_width(NrLanes)-1:0] > l;

    if (!result_queue_full) begin
      for (int unsigned lane = 0; lane < NrLanes; lane++) begin
        result_queue_d[result_queue_write_pnt_q][lane] = '{
          wdata: result_queue_q[result_queue_write_pnt_q][lane].wdata,
          be   : vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}
                 ? be(elm_per_lane + additional_elm[lane], vinsn_issue.vtype.vsew) & be_masku_alu_shuf[lane*StrbWidth +: StrbWidth]
                 : (vinsn_issue.op inside {[VIOTA:VID]} ? be_masku_alu_shuf[lane*StrbWidth +: StrbWidth] : '1),
          addr : vaddr(vinsn_issue.vd, NrLanes, VLEN) + vaddr_t'(iteration_cnt_q),
          id   : vinsn_issue.id
        };
      end
    end

    if (vinsn_issue_valid && vinsn_issue.op inside {[VMFEQ:VCOMPRESS]}) begin
      if ((!result_queue_full || vd_scalar(vinsn_issue.op))
          && (&masku_operand_alu_valid || vinsn_issue.op inside {VID, [VRGATHER:VCOMPRESS]} || !vinsn_issue.use_vs2)
          && (&masku_operand_vd_valid  || (!vinsn_issue.use_vd_op && !(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]})))
          && (&masku_operand_m_valid   || vinsn_issue.vm || vinsn_issue.op inside {[VMADC:VMSBC]})
          && (!vrgat_idx_fifo_empty    || !(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}))
          && (!result_scalar_valid_o   || !vd_scalar(vinsn_issue.op))) begin

        if (vinsn_issue.op inside {[VMSBF:VID]}) begin
          // Full-beat VMSBF/VMSOF/VMSIF and staged wide VIOTA/VID write alu_result directly
          for (int unsigned lane = 0; lane < NrLanes; lane++) begin
            result_queue_d[result_queue_write_pnt_q][lane].wdata = alu_result[lane];
          end
        end else begin
          for (int unsigned lane = 0; lane < NrLanes; lane++) begin
            result_queue_background_data[lane] = (out_valid_cnt_q != '0)
                                               ? result_queue_q[result_queue_write_pnt_q][lane].wdata
                                               : (vinsn_issue.op inside {[VRGATHER:VCOMPRESS]} ? '1 : background_data_init_shuf[lane*DataWidth +: DataWidth]);
            result_queue_d[result_queue_write_pnt_q][lane].wdata = result_queue_background_data[lane] & alu_result[lane];
          end
        end

        cpop_next = cpop_acc_q + elen_t'(beat_popc_comb);
        if (!first_hit_q && beat_first_valid_comb) begin
          first_hit_next = 1'b1;
          first_pos_next = elen_t'(global_pos_q) + elen_t'(beat_first_offset_comb);
        end
        cpop_acc_d        = cpop_next;
        first_hit_d       = first_hit_next;
        first_pos_d       = first_pos_next;
        scan_seen_d       = scan_seen_comb;
        prefix_sum_d      = prefix_sum_comb;
        viota_wdata_seq_d = viota_wdata_seq_comb;
        viota_be_seq_d    = viota_be_seq_comb;
        be_vrgat_seq_d    = be_vrgat_seq_comb;
        vrf_pnt_d         = vrf_pnt_q + delta_elm_q;
        if (vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}) vrgat_idx_fifo_pop = 1'b1;

        if (!(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]})) in_ready_cnt_en   = 1'b1;
        if (!(vinsn_issue.op inside {[VMADC:VMSBC]}))        in_m_ready_cnt_en = 1'b1;
        if (!vd_scalar(vinsn_issue.op))                      out_valid_cnt_en  = 1'b1;

        issue_cnt_d = (issue_cnt_q <= vlen_t'(delta_elm_q)) ? '0 : (issue_cnt_q - vlen_t'(delta_elm_q));
        global_pos_d = (issue_cnt_d == '0) ? '0 : (global_pos_q + vlen_t'(delta_elm_q));

        if (((in_ready_cnt_q == in_ready_threshold_q) || (issue_cnt_d == '0)) && !(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]})) begin
          in_ready_cnt_clr = 1'b1;
          if (vinsn_issue.op != VID && vinsn_issue.use_vs2) begin
            masku_operand_alu_ready = '1;
          end
        end

        if (((in_m_ready_cnt_q == in_m_ready_threshold_q) || (issue_cnt_d == '0)) && !(vinsn_issue.op inside {[VMADC:VMSBC]})) begin
          in_m_ready_cnt_clr = 1'b1;
          if (!vinsn_issue.vm) begin
            masku_operand_m_ready = '1;
          end
        end

        vcompress_issue_end_d = vcompress_last_idx_q;
        if (vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}) masku_operand_vd_ready = '1;
        if (!vd_scalar(vinsn_issue.op) && ((out_valid_cnt_q == out_valid_threshold_q) || (issue_cnt_d == '0) || vcompress_last_idx_q)) begin
          out_valid_cnt_clr = 1'b1;
          if (vinsn_issue.use_vd_op) begin
            masku_operand_vd_ready = '1;
          end
          out_vrf_word_valid = 1'b1;
        end

        if (vd_scalar(vinsn_issue.op) && (issue_cnt_d == '0)) begin
          out_scalar_valid = 1'b1;
        end

        if (issue_cnt_d == '0) begin
          viota_wdata_seq_d = '1;
          viota_be_seq_d    = '0;
          be_vrgat_seq_d    = '1;
          prefix_sum_d      = '0;
          scan_seen_d       = 1'b0;
          cpop_acc_d        = '0;
          first_hit_d       = 1'b0;
          first_pos_d       = '0;
        end
      end
    end

    if (out_vrf_word_valid) begin
      automatic vlen_t proc_step = vinsn_issue.op inside {[VIOTA:VID], [VRGATHER:VRGATHEREI16]}
                                 ? vlen_t'(BeatBytes >> unsigned'(vinsn_issue.vtype.vsew))
                                 : vlen_t'(BeatBits);
      result_queue_valid_d[result_queue_write_pnt_q] = {NrLanes{1'b1}};
      result_queue_cnt_d += 1;
      result_queue_write_pnt_d = (result_queue_write_pnt_q == ResultQueueDepth-1) ? '0 : (result_queue_write_pnt_q + 1);

      viota_wdata_seq_d = '1;
      viota_be_seq_d    = '0;
      be_vrgat_seq_d    = '1;

      processing_cnt_d = (processing_cnt_q <= proc_step) ? '0 : (processing_cnt_q - proc_step);
      if (vinsn_issue.op == VCOMPRESS) begin
        vcompress_cnt_d = (vcompress_cnt_d <= proc_step) ? '0 : (vcompress_cnt_d - proc_step);
      end
    end

    if (out_scalar_valid) begin
      result_scalar_d       = (vinsn_issue.op == VCPOP)
                            ? cpop_next
                            : (first_hit_next ? first_pos_next : 64'hFFFF_FFFF_FFFF_FFFF);
      result_scalar_valid_d = 1'b1;
      issue_cnt_d           = '0;
      processing_cnt_d      = '0;
      commit_cnt_d          = '0;
    end

    if (vinsn_issue_valid && (
          ((vinsn_issue.vm || vinsn_issue.vfu == VFU_MaskUnit) && issue_cnt_d == '0) || vcompress_issue_end_q ||
          (!(vinsn_issue.vm || vinsn_issue.vfu == VFU_MaskUnit) && read_cnt_d == '0))) begin
      vinsn_queue_d.issue_cnt -= 1;
    end

    //////////////
    //  Commit  //
    //////////////

    for (int lane = 0; lane < NrLanes; lane++) begin : result_write
      automatic logic accepted;
      automatic logic retired;

      masku_result_req_o[lane]   = result_queue_valid_q[result_queue_read_pnt_q][lane];
      masku_result_addr_o[lane]  = result_queue_q[result_queue_read_pnt_q][lane].addr;
      masku_result_id_o[lane]    = result_queue_q[result_queue_read_pnt_q][lane].id;
      masku_result_wdata_o[lane] = result_queue_q[result_queue_read_pnt_q][lane].wdata;
      masku_result_be_o[lane]    = result_queue_q[result_queue_read_pnt_q][lane].be;

      accepted = masku_result_req_o[lane] && masku_result_gnt_i[lane];
      retired  = masku_result_final_gnt_i[lane];

      if (accepted) begin
        result_queue_valid_d[result_queue_read_pnt_q][lane] = 1'b0;
        result_queue_d[result_queue_read_pnt_q][lane]       = '0;
      end

      if (accepted && !retired) begin
        inflight_writes_d[lane] = inflight_writes_q[lane] + 8'd1;
      end else if (!accepted && retired && (inflight_writes_q[lane] != '0)) begin
        inflight_writes_d[lane] = inflight_writes_q[lane] - 8'd1;
      end
    end

    if (!(|result_queue_valid_d[result_queue_read_pnt_q]) && !result_queue_empty) begin
      result_queue_read_pnt_d = (result_queue_read_pnt_q == ResultQueueDepth-1) ? '0 : (result_queue_read_pnt_q + 1);
      result_queue_cnt_d -= 1;
      result_queue_d[result_queue_read_pnt_q] = '0;

      if (!(vinsn_commit.op inside {VSE})) begin
        automatic vlen_t c_step = (vinsn_commit.op inside {[VIOTA:VID], [VRGATHER:VCOMPRESS]})
                                ? vlen_t'(BeatBytes >> unsigned'(vinsn_commit.vtype.vsew))
                                : vlen_t'(BeatBits);
        commit_cnt_d = (commit_cnt_q <= c_step) ? '0 : (commit_cnt_q - c_step);
      end
    end

    no_inflight_writes = 1'b1;
    for (int lane = 0; lane < NrLanes; lane++) begin
      if (inflight_writes_d[lane] != '0) no_inflight_writes = 1'b0;
    end

    if (vinsn_commit_valid && vd_scalar(vinsn_commit.op)) begin
      if (result_scalar_valid_o && result_scalar_ready_i) begin
        result_scalar_d                     = '0;
        result_scalar_valid_d               = 1'b0;
        out_valid_cnt_clr                   = 1'b1;
        iteration_cnt_clr                   = 1'b1;
        vrf_pnt_d                           = '0;
        pe_resp.vinsn_done[vinsn_commit.id] = 1'b1;
        vinsn_queue_d.commit_cnt           -= 1;
      end
    end else if (vinsn_commit_valid &&
                 ((commit_cnt_d == '0) || (!(|result_queue_valid_q[result_queue_read_pnt_q]) && vcompress_issue_end_q)) &&
                 (result_queue_cnt_d == '0) && (vinsn_queue_d.issue_cnt == '0)) begin
      out_valid_cnt_clr = 1'b1;
      vrf_pnt_d         = '0;
      vcompress_cnt_d   = '0;
      iteration_cnt_clr = 1'b1;

      if (no_inflight_writes || (vinsn_commit.vfu != VFU_MaskUnit)) begin
        pe_resp.vinsn_done[vinsn_commit.id] = 1'b1;
        vcompress_issue_end_d               = 1'b0;
        vinsn_queue_d.commit_cnt           -= 1;
      end
    end

    //////////////////////////////
    //  Accept new instruction  //
    //////////////////////////////

    if (pe_req_i.stride >= NrLanes * 64)
      trimmed_stride = pe_req_i.stride - ((pe_req_i.stride >> $clog2(NrLanes * 64)) << $clog2(NrLanes * 64));

    if (!vinsn_queue_full && pe_req_valid_i && !vinsn_running_q[pe_req_i.id] &&
        (!pe_req_i.vm || pe_req_i.vfu == VFU_MaskUnit)) begin
      automatic logic zero_trip = (pe_req_i.vfu == VFU_MaskUnit) &&
                                  ((pe_req_i.vl == '0) || (pe_req_i.vstart >= pe_req_i.vl));

      vinsn_queue_d.vinsn[0]       = pe_req_i;
      vinsn_running_d[pe_req_i.id] = 1'b1;

      in_ready_cnt_clr   = 1'b1;
      in_m_ready_cnt_clr = 1'b1;
      out_valid_cnt_clr  = 1'b1;
      iteration_cnt_clr  = 1'b1;
      global_pos_d       = '0;
      vrf_pnt_d          = '0;
      scan_seen_d        = 1'b0;
      prefix_sum_d       = '0;
      viota_wdata_seq_d  = '1;
      viota_be_seq_d     = '0;
      be_vrgat_seq_d     = '1;
      cpop_acc_d         = '0;
      first_hit_d        = 1'b0;
      first_pos_d        = '0;

      if (zero_trip) begin
        issue_cnt_d      = '0;
        processing_cnt_d = '0;
        read_cnt_d       = '0;
        commit_cnt_d     = '0;
        if (vd_scalar(pe_req_i.op)) begin
          result_scalar_d       = (pe_req_i.op == VCPOP) ? 64'd0 : 64'hFFFF_FFFF_FFFF_FFFF;
          result_scalar_valid_d = 1'b1;
        end
        vinsn_queue_d.commit_cnt += 1;
      end else begin
        if (vinsn_queue_d.issue_cnt == '0) begin
          issue_cnt_d      = pe_req_i.vl;
          processing_cnt_d = pe_req_i.vl;
          read_cnt_d       = pe_req_i.vl;

          if (pe_req_i.op == VSLIDEUP) begin
            issue_cnt_d      -= vlen_t'(trimmed_stride);
            processing_cnt_d -= vlen_t'(trimmed_stride);
            case (pe_req_i.vtype.vsew)
              EW8: begin
                read_cnt_d -= (vlen_t'(trimmed_stride) >> $clog2(NrLanes << 3)) << $clog2(NrLanes << 3);
                mask_pnt_d  = (vlen_t'(trimmed_stride) >> $clog2(NrLanes << 3)) << $clog2(NrLanes << 3);
              end
              EW16: begin
                read_cnt_d -= (vlen_t'(trimmed_stride) >> $clog2(NrLanes << 2)) << $clog2(NrLanes << 2);
                mask_pnt_d  = (vlen_t'(trimmed_stride) >> $clog2(NrLanes << 2)) << $clog2(NrLanes << 2);
              end
              EW32: begin
                read_cnt_d -= (vlen_t'(trimmed_stride) >> $clog2(NrLanes << 1)) << $clog2(NrLanes << 1);
                mask_pnt_d  = (vlen_t'(trimmed_stride) >> $clog2(NrLanes << 1)) << $clog2(NrLanes << 1);
              end
              EW64: begin
                read_cnt_d -= (vlen_t'(trimmed_stride) >> $clog2(NrLanes)) << $clog2(NrLanes);
                mask_pnt_d  = (vlen_t'(trimmed_stride) >> $clog2(NrLanes)) << $clog2(NrLanes);
              end
              default:;
            endcase
          end

          unique case (pe_req_i.op) inside
            [VMFEQ:VMSBC]: begin
              delta_elm_d            = NrLanes << (EW64 - pe_req_i.eew_vs2[1:0]);
              in_ready_threshold_d   = 0;
              in_m_ready_threshold_d = (DataWidth >> (EW64 - pe_req_i.eew_vs2[1:0])) - 1;
              out_valid_threshold_d  = (DataWidth >> (EW64 - pe_req_i.eew_vs2[1:0])) - 1;
            end
            [VMANDNOT:VMXNOR],
            [VMSBF:VMSIF],
            VCPOP,
            VFIRST: begin
              delta_elm_d            = FullBeatParallelism;
              in_ready_threshold_d   = '0;
              in_m_ready_threshold_d = '0;
              out_valid_threshold_d  = '0;
            end
            [VIOTA:VID]: begin
              delta_elm_d            = WideViotaWays;
              in_ready_threshold_d   = (BeatBits / WideViotaWays) - 1;
              in_m_ready_threshold_d = (BeatBits / WideViotaWays) - 1;
              out_valid_threshold_d  = ((BeatBytes / WideViotaWays) >> pe_req_i.vtype.vsew[1:0]) - 1;
            end
            default: begin
              delta_elm_d            = 1;
              in_ready_threshold_d   = pe_req_i.op == VCOMPRESS ? BeatBits - 1 : (BeatBytes >> vrgat_eff_vsew) - 1;
              in_m_ready_threshold_d = BeatBits - 1;
              out_valid_threshold_d  = (BeatBytes >> pe_req_i.vtype.vsew[1:0]) - 1;
              vrgat_cnt_d            = '0;
            end
          endcase
        end
        if (vinsn_queue_d.commit_cnt == '0) begin
          commit_cnt_d = pe_req_i.vl;
          if (pe_req_i.op == VSLIDEUP && !pe_req_i.use_scalar_op)
            commit_cnt_d -= vlen_t'(trimmed_stride);
        end

        vinsn_queue_d.issue_cnt  += 1;
        vinsn_queue_d.commit_cnt += 1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vinsn_running_q        <= '0;
      read_cnt_q             <= '0;
      issue_cnt_q            <= '0;
      processing_cnt_q       <= '0;
      commit_cnt_q           <= '0;
      global_pos_q           <= '0;
      vrf_pnt_q              <= '0;
      mask_pnt_q             <= '0;
      pe_resp_o              <= '0;
      cpop_acc_q             <= '0;
      first_hit_q            <= 1'b0;
      first_pos_q            <= '0;
      scan_seen_q            <= 1'b0;
      prefix_sum_q           <= '0;
      viota_wdata_seq_q      <= '1;
      viota_be_seq_q         <= '0;
      delta_elm_q            <= '0;
      in_ready_threshold_q   <= '0;
      in_m_ready_threshold_q <= '0;
      out_valid_threshold_q  <= '0;
      be_vrgat_seq_q         <= '1;
      vrgat_req_valid_mask_q <= '0;
      vrgat_cnt_q            <= '0;
      vcompress_issue_end_q  <= '0;
      vcompress_cnt_q        <= '0;
    end else begin
      vinsn_running_q        <= vinsn_running_d;
      read_cnt_q             <= read_cnt_d;
      issue_cnt_q            <= issue_cnt_d;
      processing_cnt_q       <= processing_cnt_d;
      commit_cnt_q           <= commit_cnt_d;
      global_pos_q           <= global_pos_d;
      vrf_pnt_q              <= vrf_pnt_d;
      mask_pnt_q             <= mask_pnt_d;
      pe_resp_o              <= pe_resp;
      cpop_acc_q             <= cpop_acc_d;
      first_hit_q            <= first_hit_d;
      first_pos_q            <= first_pos_d;
      scan_seen_q            <= scan_seen_d;
      prefix_sum_q           <= prefix_sum_d;
      viota_wdata_seq_q      <= viota_wdata_seq_d;
      viota_be_seq_q         <= viota_be_seq_d;
      delta_elm_q            <= delta_elm_d;
      in_ready_threshold_q   <= in_ready_threshold_d;
      in_m_ready_threshold_q <= in_m_ready_threshold_d;
      out_valid_threshold_q  <= out_valid_threshold_d;
      be_vrgat_seq_q         <= be_vrgat_seq_d;
      vrgat_req_valid_mask_q <= vrgat_req_valid_mask_d;
      vrgat_cnt_q            <= vrgat_cnt_d;
      vcompress_issue_end_q  <= vcompress_issue_end_d;
      vcompress_cnt_q        <= vcompress_cnt_d;
    end
  end

endmodule : masku
