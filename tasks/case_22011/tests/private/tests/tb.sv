// Private verification testbench for case_22011:
// RVV 1.0 Unit-Stride & Strided Segmented Vector Load/Store Decomposition
// across ara_dispatcher + segment_sequencer + ara_sequencer + vlsu.

`timescale 1ns/1ps

module tb;
  import axi_pkg::*;
  import rvv_pkg::*;
  import ara_pkg::*;

  localparam int unsigned NrLanes      = 2;
  localparam int unsigned VLEN         = 128;
  localparam int unsigned VLENB        = VLEN / 8; // 16 bytes per vreg
  localparam int unsigned AxiDataWidth = 64;
  localparam int unsigned AxiAddrWidth = 64;
  localparam int unsigned NrPEs        = NrLanes + 4;
  localparam int unsigned MEM_BYTES    = 65536; // 64 KiB physical RAM

  typedef logic [$clog2(VLEN+1)-1:0] vlen_t;

  `include "axi/typedef.svh"
  `include "ara/intf_typedef.svh"
  `include "ara/ara_typedef.svh"

  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  `CVA6_TYPEDEF_EXCEPTION(exception_t, CVA6Cfg)
  `CVA6_INTF_TYPEDEF_ACC_REQ(accelerator_req_t, CVA6Cfg, fpnew_pkg::roundmode_e)
  `CVA6_INTF_TYPEDEF_ACC_RESP(accelerator_resp_t, CVA6Cfg, exception_t)

  typedef logic [AxiAddrWidth-1:0]   axi_addr_t;
  typedef logic [AxiDataWidth-1:0]   axi_data_t;
  typedef logic [AxiDataWidth/8-1:0] axi_strb_t;
  typedef logic [4:0]                axi_id_t;
  typedef logic [0:0]                axi_user_t;
  `AXI_TYPEDEF_ALL(ara_axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

  typedef logic [cf_math_pkg::idx_width((VLENB/NrLanes)*32)-1:0] vaddr_t;
  typedef logic [7:0] strb_t;

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

  // Clock and reset
  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;
  always #5 clk_i = ~clk_i;

  // Subsystem signals
  accelerator_req_t    acc_req;
  accelerator_resp_t   acc_resp;
  ara_req_t            ara_req;
  logic                ara_req_valid, ara_req_ready, ara_resp_valid, ara_idle;
  ara_resp_t           ara_resp;
  logic                lsu_ex_flush, lsu_ex_flush_done;
  logic                core_st_pending, load_complete, store_complete, store_pending;
  vxrm_t [NrLanes-1:0] alu_vxrm;

  pe_req_t                         pe_req;
  logic                            pe_req_valid;
  logic [NrVInsn-1:0]              pe_vinsn_running;
  logic [NrPEs-1:0]                pe_req_ready;
  pe_resp_t [NrPEs-1:0]            pe_resp;
  logic [NrVInsn-1:0][NrVInsn-1:0] ght;
  logic                            pe_scalar_resp_ready;
  logic                            addrgen_ack, addrgen_fof_ex, lsu_burst_ex;
  exception_t                      addrgen_ex;
  vlen_t                           addrgen_ex_vstart;

  ara_axi_req_t   axi_req;
  ara_axi_resp_t  axi_resp;
  logic [1:0]     vlsu_ready;
  pe_resp_t [1:0] vlsu_resp;

  elen_t [NrLanes-1:0] stu_operand;
  logic  [NrLanes-1:0] stu_operand_valid;
  logic  [NrLanes-1:0] stu_operand_ready;

  strb_t [NrLanes-1:0] mask_bus;
  logic  [NrLanes-1:0] mask_bus_valid;
  logic                vldu_mask_ready, vstu_mask_ready;

  logic                      en_ld_st_translation;
  logic                      mmu_req, mmu_is_store, mmu_valid;
  logic [CVA6Cfg.VLEN-1:0]   mmu_vaddr;
  logic [CVA6Cfg.PLEN-1:0]   mmu_paddr;
  exception_t                mmu_exception;

  logic   [NrLanes-1:0] ldu_result_req;
  vid_t   [NrLanes-1:0] ldu_result_id;
  vaddr_t [NrLanes-1:0] ldu_result_addr;
  elen_t  [NrLanes-1:0] ldu_result_wdata;
  strb_t  [NrLanes-1:0] ldu_result_be;
  logic   [NrLanes-1:0] ldu_result_gnt;
  logic   [NrLanes-1:0] ldu_result_final_gnt;

  // DUT instantiations
  ara_dispatcher #(
    .CVA6Cfg           (CVA6Cfg),
    .NrLanes           (NrLanes),
    .VLEN              (VLEN),
    .SegSupport        (SegSupportEnable),
    .ara_req_t         (ara_req_t),
    .ara_resp_t        (ara_resp_t),
    .accelerator_req_t (accelerator_req_t),
    .accelerator_resp_t(accelerator_resp_t)
  ) i_dispatcher (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .acc_req_i          (acc_req),
    .acc_resp_o         (acc_resp),
    .ara_req_o          (ara_req),
    .ara_req_valid_o    (ara_req_valid),
    .ara_req_ready_i    (ara_req_ready),
    .ara_resp_i         (ara_resp),
    .ara_resp_valid_i   (ara_resp_valid),
    .ara_idle_i         (ara_idle),
    .fflags_ex_i        ('0),
    .fflags_ex_valid_i  ('0),
    .lsu_ex_flush_o     (lsu_ex_flush),
    .lsu_ex_flush_done_i(lsu_ex_flush_done),
    .vxsat_flag_i       ('0),
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
    .clk_i                        (clk_i),
    .rst_ni                       (rst_ni),
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
    .alu_vinsn_done_i             (1'b0),
    .mfpu_vinsn_done_i            (1'b0),
    .global_hazard_table_o        (ght),
    .pe_scalar_resp_i             ('0),
    .pe_scalar_resp_valid_i       (1'b0),
    .pe_scalar_resp_ready_o       (pe_scalar_resp_ready),
    .addrgen_ack_i                (addrgen_ack),
    .addrgen_exception_i          (addrgen_ex),
    .addrgen_exception_vstart_i   (addrgen_ex_vstart),
    .addrgen_fof_exception_i      (addrgen_fof_ex),
    .lsu_current_burst_exception_i(lsu_burst_ex)
  );

  vlsu #(
    .NrLanes     (NrLanes),
    .VLEN        (VLEN),
    .vaddr_t     (vaddr_t),
    .pe_req_t    (pe_req_t),
    .pe_resp_t   (pe_resp_t),
    .CVA6Cfg     (CVA6Cfg),
    .exception_t (exception_t),
    .AxiDataWidth(AxiDataWidth),
    .AxiAddrWidth(AxiAddrWidth),
    .axi_ar_t    (ara_axi_ar_chan_t),
    .axi_r_t     (ara_axi_r_chan_t),
    .axi_aw_t    (ara_axi_aw_chan_t),
    .axi_w_t     (ara_axi_w_chan_t),
    .axi_b_t     (ara_axi_b_chan_t),
    .axi_req_t   (ara_axi_req_t),
    .axi_resp_t  (ara_axi_resp_t)
  ) i_vlsu (
    .clk_i                        (clk_i),
    .rst_ni                       (rst_ni),
    .axi_req_o                    (axi_req),
    .axi_resp_i                   (axi_resp),
    .core_st_pending_i            (core_st_pending),
    .load_complete_o              (load_complete),
    .store_complete_o             (store_complete),
    .store_pending_o              (store_pending),
    .pe_req_i                     (pe_req),
    .pe_req_valid_i               (pe_req_valid),
    .pe_vinsn_running_i           (pe_vinsn_running),
    .pe_req_ready_o               (vlsu_ready),
    .pe_resp_o                    (vlsu_resp),
    .addrgen_ack_o                (addrgen_ack),
    .addrgen_exception_o          (addrgen_ex),
    .addrgen_exception_vstart_o   (addrgen_ex_vstart),
    .addrgen_fof_exception_o      (addrgen_fof_ex),
    .lsu_current_burst_exception_o(lsu_burst_ex),
    .stu_operand_i                (stu_operand),
    .stu_operand_valid_i          (stu_operand_valid),
    .stu_operand_ready_o          (stu_operand_ready),
    .addrgen_operand_i            ('0),
    .addrgen_operand_valid_i      ('0),
    .addrgen_operand_ready_o      (),
    .lsu_ex_flush_i               (lsu_ex_flush),
    .lsu_ex_flush_done_o          (lsu_ex_flush_done),
    .mask_i                       (mask_bus),
    .mask_valid_i                 (mask_bus_valid),
    .vldu_mask_ready_o            (vldu_mask_ready),
    .vstu_mask_ready_o            (vstu_mask_ready),
    .en_ld_st_translation_i       (en_ld_st_translation),
    .mmu_misaligned_ex_o          (),
    .mmu_req_o                    (mmu_req),
    .mmu_vaddr_o                  (mmu_vaddr),
    .mmu_is_store_o               (mmu_is_store),
    .mmu_dtlb_hit_i               (1'b0),
    .mmu_dtlb_ppn_i               ('0),
    .mmu_valid_i                  (mmu_valid),
    .mmu_paddr_i                  (mmu_paddr),
    .mmu_exception_i              (mmu_exception),
    .ldu_result_req_o             (ldu_result_req),
    .ldu_result_id_o              (ldu_result_id),
    .ldu_result_addr_o            (ldu_result_addr),
    .ldu_result_wdata_o           (ldu_result_wdata),
    .ldu_result_be_o              (ldu_result_be),
    .ldu_result_gnt_i             (ldu_result_gnt),
    .ldu_result_final_gnt_i       (ldu_result_final_gnt)
  );

  // =========================================================================
  // PRNG & Stall Configuration
  // =========================================================================
  int unsigned rng_state;
  bit          enable_random_stalls;

  function automatic int unsigned urand();
    rng_state ^= (rng_state << 13);
    rng_state ^= (rng_state >> 17);
    rng_state ^= (rng_state << 5);
    return rng_state;
  endfunction

  logic [31:0] cyc_lfsr;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cyc_lfsr <= 32'hACE1_1234;
    else         cyc_lfsr <= {cyc_lfsr[30:0], cyc_lfsr[31] ^ cyc_lfsr[21] ^ cyc_lfsr[1] ^ cyc_lfsr[0]};
  end

  // =========================================================================
  // Scoreboard Counters on acc_resp_o.{load_complete, store_complete}
  // =========================================================================
  int unsigned obs_load_complete_cnt;
  int unsigned obs_store_complete_cnt;
  int unsigned exp_load_complete_cnt;
  int unsigned exp_store_complete_cnt;
  int unsigned err_cnt;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      obs_load_complete_cnt  <= 0;
      obs_store_complete_cnt <= 0;
    end else begin
      if (acc_resp.load_complete)  obs_load_complete_cnt  <= obs_load_complete_cnt + 1;
      if (acc_resp.store_complete) obs_store_complete_cnt <= obs_store_complete_cnt + 1;
    end
  end

  // =========================================================================
  // 2-Lane Shuffled VRF + VLDU Write + VSTU Read + Mask + Slide Reshuffle
  // =========================================================================
  elen_t vrf_mem [32][NrLanes];
  vew_e  tb_v0_eew; // tracks shuffle encoding of v0 for mask extraction

  function automatic logic [127:0] read_vrf_logical(input int unsigned vreg, input vew_e ew);
    logic [127:0] res;
    for (int unsigned b = 0; b < 16; b++) begin
      int unsigned p = shuffle_index(b[15:0], NrLanes, ew);
      int unsigned ln = p >> 3;
      int unsigned off = p & 7;
      res[b*8 +: 8] = vrf_mem[vreg][ln][off*8 +: 8];
    end
    return res;
  endfunction

  // VLDU write responder + Slide reshuffle responder (8-deep FIFO for back-to-back VSLIDEDOWN uops)
  typedef struct packed {
    vid_t       id;
    logic [4:0] vreg;
    vew_e       old_eew;
    vew_e       new_eew;
  } slide_cmd_t;

  slide_cmd_t         slide_fifo [8];
  int unsigned        slide_wr_ptr, slide_rd_ptr, slide_cnt;
  logic [NrVInsn-1:0] slide_seen_q;
  logic               slide_pending_q;
  pe_resp_t           slide_resp_q;

  assign slide_pending_q   = (slide_cnt != 0);
  assign ldu_result_gnt[0] = ldu_result_req[0] && (!enable_random_stalls || (cyc_lfsr[1:0] != 2'b11));
  assign ldu_result_gnt[1] = ldu_result_req[1] && (!enable_random_stalls || (cyc_lfsr[3:2] != 2'b11));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ldu_result_final_gnt <= '0;
      slide_seen_q         <= '0;
      slide_wr_ptr         <= 0;
      slide_rd_ptr         <= 0;
      slide_cnt            <= 0;
      slide_resp_q         <= '0;
      tb_v0_eew            <= EW8;
    end else begin
      automatic int unsigned next_sl_wr  = slide_wr_ptr;
      automatic int unsigned next_sl_rd  = slide_rd_ptr;
      automatic int unsigned next_sl_cnt = slide_cnt;
      automatic logic [NrVInsn-1:0] next_sl_seen = slide_seen_q & pe_vinsn_running;

      slide_resp_q <= '0;

      for (int ln = 0; ln < NrLanes; ln++) begin
        ldu_result_final_gnt[ln] <= 1'b0;
        if (ldu_result_req[ln] && ldu_result_gnt[ln]) begin
          for (int b = 0; b < 8; b++) begin
            if (ldu_result_be[ln][b]) begin
              vrf_mem[ldu_result_addr[ln]][ln][b*8 +: 8] <= ldu_result_wdata[ln][b*8 +: 8];
            end
          end
          ldu_result_final_gnt[ln] <= 1'b1;
        end
      end

      if (pe_req_valid && (pe_req.vfu == VFU_LoadUnit) && pe_req.use_vd && (pe_req.vd == 5'd0)) begin
        tb_v0_eew <= pe_req.vtype.vsew;
      end

      if ((slide_cnt > 0) && (!enable_random_stalls || cyc_lfsr[4])) begin
        automatic slide_cmd_t scmd = slide_fifo[slide_rd_ptr[2:0]];
        automatic logic [127:0] tmp_vec = read_vrf_logical(scmd.vreg, scmd.old_eew);
        for (int unsigned b = 0; b < 16; b++) begin
          automatic int unsigned p = shuffle_index(b[15:0], NrLanes, scmd.new_eew);
          vrf_mem[scmd.vreg][p >> 3][(p & 7)*8 +: 8] <= tmp_vec[b*8 +: 8];
        end
        if (scmd.vreg == 5'd0) tb_v0_eew <= scmd.new_eew;
        slide_resp_q.vinsn_done[scmd.id] <= 1'b1;
        next_sl_rd  = next_sl_rd + 1;
        next_sl_cnt = next_sl_cnt - 1;
      end

      if (pe_req_valid && (pe_req.vfu == VFU_SlideUnit) && (pe_req.op == VSLIDEDOWN) &&
          !slide_seen_q[pe_req.id] && &pe_req_ready[NrLanes-1:0]) begin
        next_sl_seen[pe_req.id]        = 1'b1;
        slide_fifo[next_sl_wr[2:0]].id      <= pe_req.id;
        slide_fifo[next_sl_wr[2:0]].vreg    <= pe_req.vd;
        slide_fifo[next_sl_wr[2:0]].old_eew <= pe_req.eew_vs2;
        slide_fifo[next_sl_wr[2:0]].new_eew <= pe_req.vtype.vsew;
        next_sl_wr  = next_sl_wr + 1;
        next_sl_cnt = next_sl_cnt + 1;
      end

      slide_seen_q <= next_sl_seen;
      slide_wr_ptr <= next_sl_wr;
      slide_rd_ptr <= next_sl_rd;
      slide_cnt    <= next_sl_cnt;
    end
  end

  // VSTU operand read queue (supports multi-word vse/vs<nr>r and single-word segment micro-ops)
  typedef struct packed {
    logic [4:0] vreg;
  } stu_word_cmd_t;

  stu_word_cmd_t      stu_fifo [16];
  int unsigned        stu_wr_ptr, stu_rd_ptr, stu_cnt;
  logic [NrVInsn-1:0] stu_seen_q;
  logic [NrLanes-1:0] stu_lane_acked_q;

  wire stu_stall_now = enable_random_stalls && (cyc_lfsr[6:5] == 2'b11);
  assign stu_operand[0]       = (stu_cnt > 0) ? vrf_mem[stu_fifo[stu_rd_ptr[3:0]].vreg][0] : '0;
  assign stu_operand[1]       = (stu_cnt > 0) ? vrf_mem[stu_fifo[stu_rd_ptr[3:0]].vreg][1] : '0;
  assign stu_operand_valid[0] = (stu_cnt > 0) && !stu_lane_acked_q[0] && !stu_stall_now;
  assign stu_operand_valid[1] = (stu_cnt > 0) && !stu_lane_acked_q[1] && !stu_stall_now;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stu_wr_ptr       <= 0;
      stu_rd_ptr       <= 0;
      stu_cnt          <= 0;
      stu_seen_q       <= '0;
      stu_lane_acked_q <= '0;
    end else if (lsu_ex_flush || lsu_burst_ex ||
                 (addrgen_ack && addrgen_ex.valid && !is_load(pe_req.op))) begin
      stu_wr_ptr       <= 0;
      stu_rd_ptr       <= 0;
      stu_cnt          <= 0;
      stu_seen_q       <= stu_seen_q & pe_vinsn_running;
      stu_lane_acked_q <= '0;
    end else begin
      automatic int unsigned next_cnt = stu_cnt;
      automatic int unsigned next_wr  = stu_wr_ptr;
      automatic logic [NrLanes-1:0] ack_now = stu_lane_acked_q | (stu_operand_valid & stu_operand_ready);

      stu_seen_q <= stu_seen_q & pe_vinsn_running;

      if (&ack_now && (stu_cnt > 0)) begin
        stu_rd_ptr       <= stu_rd_ptr + 1;
        next_cnt         = next_cnt - 1;
        stu_lane_acked_q <= '0;
      end else begin
        stu_lane_acked_q <= ack_now;
      end

      if (pe_req_valid && (pe_req.vfu == VFU_StoreUnit) && !stu_seen_q[pe_req.id] &&
          &pe_req_ready[NrLanes-1:0]) begin
        stu_seen_q[pe_req.id] <= 1'b1;
        if (pe_req.vl > pe_req.vstart) begin
          automatic int unsigned start_b = int'(pe_req.vstart) << int'(pe_req.vtype.vsew);
          automatic int unsigned end_b   = int'(pe_req.vl)     << int'(pe_req.vtype.vsew);
          automatic int unsigned first_w = int'(pe_req.vs1) + (start_b >> 4);
          automatic int unsigned last_w  = int'(pe_req.vs1) + ((end_b - 1) >> 4);
          for (int unsigned w = first_w; w <= last_w; w++) begin
            stu_fifo[next_wr[3:0]].vreg <= 5'(w);
            next_wr  = next_wr + 1;
            next_cnt = next_cnt + 1;
          end
        end
      end

      stu_wr_ptr <= next_wr;
      stu_cnt    <= next_cnt;
    end
  end

  // Mask unit responder (OffsetMask) for vm == 0 loads/stores
  typedef struct packed {
    vid_t                id;
    strb_t [NrLanes-1:0] mword;
    logic                last_word;
  } mask_cmd_t;

  mask_cmd_t          mask_fifo [16];
  int unsigned        mask_wr_ptr, mask_rd_ptr, mask_cnt;
  logic [NrVInsn-1:0] mask_seen_q;
  pe_resp_t           mask_resp_q;

  wire mask_stall_now = enable_random_stalls && (cyc_lfsr[8:7] == 2'b11);
  assign mask_bus       = (mask_cnt > 0) ? mask_fifo[mask_rd_ptr[3:0]].mword : '0;
  assign mask_bus_valid = {(NrLanes){(mask_cnt > 0) && !mask_stall_now}};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mask_wr_ptr <= 0;
      mask_rd_ptr <= 0;
      mask_cnt    <= 0;
      mask_seen_q <= '0;
      mask_resp_q <= '0;
    end else begin
      automatic int unsigned next_cnt = mask_cnt;
      automatic int unsigned next_wr  = mask_wr_ptr;
      mask_resp_q <= '0;
      mask_seen_q <= mask_seen_q & pe_vinsn_running;

      if ((mask_cnt > 0) &&
          (lsu_burst_ex || (addrgen_ack && addrgen_ex.valid && addrgen_ex.cause == riscv::ILLEGAL_INSTR))) begin
        mask_resp_q.vinsn_done[mask_fifo[mask_rd_ptr[3:0]].id] <= 1'b1;
        mask_wr_ptr <= 0;
        mask_rd_ptr <= 0;
        mask_cnt    <= 0;
      end else begin
        if ((mask_cnt > 0) && !mask_stall_now && (vldu_mask_ready || vstu_mask_ready)) begin
          if (mask_fifo[mask_rd_ptr[3:0]].last_word) begin
            mask_resp_q.vinsn_done[mask_fifo[mask_rd_ptr[3:0]].id] <= 1'b1;
          end
          mask_rd_ptr <= mask_rd_ptr + 1;
          next_cnt    = next_cnt - 1;
        end

        if (pe_req_valid && !pe_req.vm &&
            (pe_req.vfu == VFU_LoadUnit || pe_req.vfu == VFU_StoreUnit) &&
            !mask_seen_q[pe_req.id] && &pe_req_ready[NrLanes-1:0]) begin
          mask_seen_q[pe_req.id] <= 1'b1;
          if (pe_req.vl > pe_req.vstart) begin
            automatic logic [127:0] v0_bits = read_vrf_logical(0, tb_v0_eew);
            automatic int unsigned  start_b = int'(pe_req.vstart) << int'(pe_req.vtype.vsew);
            automatic int unsigned  end_b   = int'(pe_req.vl)     << int'(pe_req.vtype.vsew);
            automatic int unsigned  first_w = start_b >> 4;
            automatic int unsigned  last_w  = (end_b - 1) >> 4;
            automatic vew_e         shuf_ew = (pe_req.vfu == VFU_StoreUnit) ? pe_req.old_eew_vs1 : pe_req.vtype.vsew;
            for (int unsigned w = first_w; w <= last_w; w++) begin
              automatic strb_t [NrLanes-1:0] mw = '0;
              for (int unsigned sb = 0; sb < 16; sb++) begin
                automatic int unsigned elem_i = (w * 16 + sb) >> int'(pe_req.vtype.vsew);
                automatic int unsigned p      = shuffle_index(sb[15:0], NrLanes, shuf_ew);
                mw[p >> 3][p & 7] = v0_bits[elem_i[6:0]];
              end
              mask_fifo[next_wr[3:0]].id        <= pe_req.id;
              mask_fifo[next_wr[3:0]].mword     <= mw;
              mask_fifo[next_wr[3:0]].last_word <= (w == last_w);
              next_wr  = next_wr + 1;
              next_cnt = next_cnt + 1;
            end
          end else begin
            mask_resp_q.vinsn_done[pe_req.id] <= 1'b1;
          end
        end

        mask_wr_ptr <= next_wr;
        mask_cnt    <= next_cnt;
      end
    end
  end

  always_comb begin
    pe_req_ready = '1;
    if (enable_random_stalls && (cyc_lfsr[11:9] == 3'b111)) begin
      pe_req_ready[0] = 1'b0;
      pe_req_ready[1] = 1'b0;
    end
    pe_req_ready[NrLanes + OffsetSlide] = (slide_cnt < 6);
    pe_req_ready[NrLanes + OffsetMask]  = (mask_cnt < 12);
    pe_req_ready[NrLanes + OffsetLoad]  = vlsu_ready[OffsetLoad];
    pe_req_ready[NrLanes + OffsetStore] = vlsu_ready[OffsetStore];

    pe_resp                         = '0;
    pe_resp[NrLanes + OffsetSlide]  = slide_resp_q;
    pe_resp[NrLanes + OffsetMask]   = mask_resp_q;
    pe_resp[NrLanes + OffsetLoad]   = vlsu_resp[OffsetLoad];
    pe_resp[NrLanes + OffsetStore]  = vlsu_resp[OffsetStore];
  end

  // =========================================================================
  // SV39 MMU Responder (Identity Map + Programmable Fault Address Window)
  // =========================================================================
  bit        fault_enable;
  axi_addr_t fault_vaddr_lo, fault_vaddr_hi;
  int unsigned post_fault_axi_reqs;
  bit        saw_mmu_fault_this_op;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mmu_valid     <= 1'b0;
      mmu_paddr     <= '0;
      mmu_exception <= '0;
    end else begin
      mmu_valid     <= 1'b0;
      mmu_paddr     <= '0;
      mmu_exception <= '0;
      if (en_ld_st_translation && mmu_req && (!enable_random_stalls || cyc_lfsr[12])) begin
        mmu_valid <= 1'b1;
        if (fault_enable && (mmu_vaddr >= fault_vaddr_lo) && (mmu_vaddr < fault_vaddr_hi)) begin
          mmu_exception.valid <= 1'b1;
          mmu_exception.cause <= mmu_is_store ? riscv::STORE_PAGE_FAULT : riscv::LOAD_PAGE_FAULT;
          mmu_exception.tval  <= mmu_vaddr;
          saw_mmu_fault_this_op <= 1'b1;
        end else begin
          mmu_paddr <= mmu_vaddr[CVA6Cfg.PLEN-1:0];
        end
      end
    end
  end

  // =========================================================================
  // AXI4 64-bit Memory Responder with INCR Burst & Backpressure Support
  // =========================================================================
  logic [7:0] axi_ram [MEM_BYTES];
  logic [7:0] ref_ram [MEM_BYTES];

  // AR/R channel state
  logic             ar_busy_q;
  ara_axi_ar_chan_t ar_req_q;
  axi_pkg::len_t    r_beat_idx_q;

  // AW/W/B channel state
  typedef struct packed {
    axi_addr_t     addr;
    axi_pkg::len_t len;
    axi_pkg::size_t size;
    axi_id_t       id;
  } aw_entry_t;

  aw_entry_t     aw_fifo [8];
  int unsigned   aw_wr_ptr, aw_rd_ptr, aw_cnt;
  axi_pkg::len_t w_beat_idx_q;
  int unsigned   b_pending_cnt;
  axi_id_t       b_id_q;

  wire ar_ready_now = !ar_busy_q && (!enable_random_stalls || (cyc_lfsr[14:13] != 2'b11));
  wire r_valid_now  = ar_busy_q  && (!enable_random_stalls || (cyc_lfsr[16:15] != 2'b11));
  wire aw_ready_now = (aw_cnt < 6) && (!enable_random_stalls || (cyc_lfsr[18:17] != 2'b11));
  wire w_ready_now  = (aw_cnt > 0) && (!enable_random_stalls || (cyc_lfsr[20:19] != 2'b11));
  wire b_valid_now  = (b_pending_cnt > 0) && (!enable_random_stalls || (cyc_lfsr[22:21] != 2'b11));

  always_comb begin
    axi_resp          = '0;
    axi_resp.ar_ready = ar_ready_now;
    axi_resp.aw_ready = aw_ready_now;
    axi_resp.w_ready  = w_ready_now;

    if (r_valid_now) begin
      automatic axi_addr_t beat_aligned = (ar_req_q.addr & ~64'h7) +
        ((axi_addr_t'(r_beat_idx_q) << ar_req_q.size) & ~64'h7);
      // Exact byte lane alignment for narrow or full bursts
      automatic axi_addr_t cur_addr = (r_beat_idx_q == 0)
        ? (ar_req_q.addr & ~64'h7)
        : (((ar_req_q.addr & ~((64'h1 << ar_req_q.size) - 64'h1)) + (axi_addr_t'(r_beat_idx_q) << ar_req_q.size)) & ~64'h7);
      axi_resp.r_valid = 1'b1;
      axi_resp.r.id    = ar_req_q.id;
      axi_resp.r.resp  = axi_pkg::RESP_OKAY;
      axi_resp.r.last  = (r_beat_idx_q == ar_req_q.len);
      for (int b = 0; b < 8; b++) begin
        axi_resp.r.data[b*8 +: 8] = axi_ram[(cur_addr + b) & (MEM_BYTES - 1)];
      end
    end

    if (b_valid_now) begin
      axi_resp.b_valid = 1'b1;
      axi_resp.b.id    = b_id_q;
      axi_resp.b.resp  = axi_pkg::RESP_OKAY;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_busy_q           <= 1'b0;
      ar_req_q            <= '0;
      r_beat_idx_q        <= '0;
      aw_wr_ptr           <= 0;
      aw_rd_ptr           <= 0;
      aw_cnt              <= 0;
      w_beat_idx_q        <= '0;
      b_pending_cnt       <= 0;
      b_id_q              <= '0;
      post_fault_axi_reqs <= 0;
    end else begin
      automatic int unsigned next_aw_cnt = aw_cnt;
      automatic int unsigned next_b_cnt  = b_pending_cnt;

      if (saw_mmu_fault_this_op &&
          ((axi_req.ar_valid && axi_resp.ar_ready) || (axi_req.aw_valid && axi_resp.aw_ready))) begin
        post_fault_axi_reqs <= post_fault_axi_reqs + 1;
      end

      if (!ar_busy_q) begin
        if (axi_req.ar_valid && ar_ready_now) begin
          ar_busy_q    <= 1'b1;
          ar_req_q     <= axi_req.ar;
          r_beat_idx_q <= '0;
        end
      end else if (r_valid_now && axi_req.r_ready) begin
        if (r_beat_idx_q == ar_req_q.len) begin
          ar_busy_q    <= 1'b0;
          r_beat_idx_q <= '0;
        end else begin
          r_beat_idx_q <= r_beat_idx_q + 1;
        end
      end

      if (axi_req.aw_valid && aw_ready_now) begin
        aw_fifo[aw_wr_ptr[2:0]].addr <= axi_req.aw.addr;
        aw_fifo[aw_wr_ptr[2:0]].len  <= axi_req.aw.len;
        aw_fifo[aw_wr_ptr[2:0]].size <= axi_req.aw.size;
        aw_fifo[aw_wr_ptr[2:0]].id   <= axi_req.aw.id;
        aw_wr_ptr   <= aw_wr_ptr + 1;
        next_aw_cnt = next_aw_cnt + 1;
      end

      if (axi_req.w_valid && w_ready_now) begin
        automatic aw_entry_t cur_aw = aw_fifo[aw_rd_ptr[2:0]];
        automatic axi_addr_t beat_base = (w_beat_idx_q == 0)
          ? (cur_aw.addr & ~64'h7)
          : (((cur_aw.addr & ~((64'h1 << cur_aw.size) - 64'h1)) + (axi_addr_t'(w_beat_idx_q) << cur_aw.size)) & ~64'h7);
        for (int b = 0; b < 8; b++) begin
          if (axi_req.w.strb[b]) begin
            axi_ram[(beat_base + b) & (MEM_BYTES - 1)] <= axi_req.w.data[b*8 +: 8];
          end
        end
        if (axi_req.w.last) begin
          w_beat_idx_q <= '0;
          aw_rd_ptr    <= aw_rd_ptr + 1;
          next_aw_cnt  = next_aw_cnt - 1;
          b_id_q       <= cur_aw.id;
          next_b_cnt   = next_b_cnt + 1;
        end else begin
          w_beat_idx_q <= w_beat_idx_q + 1;
        end
      end

      if (b_valid_now && axi_req.b_ready) begin
        next_b_cnt = next_b_cnt - 1;
      end

      aw_cnt        <= next_aw_cnt;
      b_pending_cnt <= next_b_cnt;
    end
  end

  // =========================================================================
  // RVV 1.0 Instruction Encoders & Dispatcher Driver Tasks
  // =========================================================================
  function automatic logic [31:0] enc_vsetvli(
    input logic [4:0]  rd,
    input logic [4:0]  rs1,
    input vew_e        vsew,
    input vlmul_e      vlmul,
    input logic        vta = 1'b0,
    input logic        vma = 1'b0
  );
    logic [10:0] zimm11;
    zimm11 = {3'b000, vma, vta, vsew[2:0], vlmul[2:0]};
    return {1'b0, zimm11, rs1, 3'b111, rd, riscv::OpcodeVec};
  endfunction

  function automatic logic [31:0] enc_vsetvl_reg(
    input logic [4:0] rd,
    input logic [4:0] rs1,
    input logic [4:0] rs2
  );
    return {7'b1000000, rs2, rs1, 3'b111, rd, riscv::OpcodeVec};
  endfunction

  function automatic logic [31:0] enc_vmem(
    input logic       is_store_op,
    input logic [2:0] nf,
    input logic       mew,
    input logic [1:0] mop,
    input logic       vm,
    input logic [4:0] lumop_or_rs2,
    input logic [4:0] rs1,
    input logic [2:0] width,
    input logic [4:0] vd_or_vs3
  );
    return {nf, mew, mop, vm, lumop_or_rs2, rs1, width, vd_or_vs3,
            is_store_op ? riscv::OpcodeStoreFp : riscv::OpcodeLoadFp};
  endfunction

  function automatic logic [2:0] eew_to_width(input vew_e eew);
    unique case (eew)
      EW8:     return 3'b000;
      EW16:    return 3'b101;
      EW32:    return 3'b110;
      default: return 3'b111; // EW64
    endcase
  endfunction

  function automatic logic [31:0] enc_csrrw(
    input logic [11:0] csr_addr,
    input logic [4:0]  rd,
    input logic [4:0]  rs1
  );
    return {csr_addr, rs1, 3'b001, rd, riscv::OpcodeSystem};
  endfunction

  function automatic logic [31:0] enc_csrrs(
    input logic [11:0] csr_addr,
    input logic [4:0]  rd,
    input logic [4:0]  rs1
  );
    return {csr_addr, rs1, 3'b010, rd, riscv::OpcodeSystem};
  endfunction

  task automatic dispatch_insn(
    input  logic [31:0] insn_word,
    input  elen_t       rs1_val,
    input  elen_t       rs2_val,
    output elen_t       res_val,
    output exception_t  ex_out
  );
    int unsigned timeout_cyc;
    bit          req_accepted;
    bit          resp_received;

    req_accepted  = 1'b0;
    resp_received = 1'b0;
    res_val       = '0;
    ex_out        = '0;
    timeout_cyc   = 0;

    while (!(req_accepted && resp_received)) begin
      bit will_accept;
      bit will_resp;

      @(negedge clk_i);
      acc_req.insn       = insn_word;
      acc_req.rs1        = rs1_val;
      acc_req.rs2        = rs2_val;
      acc_req.req_valid  = !req_accepted;
      acc_req.resp_ready = !enable_random_stalls || (insn_word[31:29] == 3'b000) || (cyc_lfsr[24:23] != 2'b11);

      #4;
      will_accept = acc_req.req_valid && acc_resp.req_ready;
      will_resp   = acc_resp.resp_valid && acc_req.resp_ready;
      if (will_resp) begin
        res_val = acc_resp.result;
        ex_out  = acc_resp.exception;
      end

      @(posedge clk_i);
      if (will_accept) begin
        req_accepted = 1'b1;
      end
      if (will_resp) begin
        resp_received = 1'b1;
      end

      timeout_cyc++;
      if (timeout_cyc > 15000) begin
        $display("[FAIL] Timeout waiting for instruction 0x%08x (req_acc=%0d resp_rcv=%0d state_idle=%0d)",
                 insn_word, req_accepted, resp_received, ara_idle);
        $finish(1);
      end
    end

    @(negedge clk_i);
    acc_req.req_valid  = 1'b0;
    acc_req.resp_ready = 1'b1;
  endtask

  task automatic wait_backend_quiescent();
    int unsigned t = 0;
    while (!ara_idle || !ara_req_ready || ar_busy_q || (aw_cnt != 0) || (b_pending_cnt != 0) ||
           slide_pending_q || (stu_cnt != 0) || (mask_cnt != 0) ||
           (i_dispatcher.lsu_ex_state_q != '0)) begin
      @(posedge clk_i);
      t++;
      if (t > 10000) begin
        $display("[FAIL] Timeout waiting for backend quiescence");
        $finish(1);
      end
    end
    repeat (2) @(posedge clk_i);
  endtask

  task automatic set_vtype_vl(
    input int unsigned avl,
    input vew_e        vsew,
    input vlmul_e      vlmul,
    output int unsigned actual_vl
  );
    elen_t      res;
    exception_t ex;
    dispatch_insn(enc_vsetvli(5'd1, 5'd1, vsew, vlmul), elen_t'(avl), '0, res, ex);
    if (ex.valid) begin
      $display("[FAIL] Unexpected exception on vsetvli");
      err_cnt++;
    end
    actual_vl = int'(res);
  endtask

  task automatic write_vstart(input int unsigned vstart_val);
    elen_t      res;
    exception_t ex;
    dispatch_insn(enc_csrrw(riscv::CSR_VSTART, 5'd0, 5'd1), elen_t'(vstart_val), '0, res, ex);
    if (ex.valid) begin
      $display("[FAIL] Unexpected exception writing CSR_VSTART");
      err_cnt++;
    end
  endtask

  task automatic read_vstart(output int unsigned vstart_val);
    elen_t      res;
    exception_t ex;
    dispatch_insn(enc_csrrs(riscv::CSR_VSTART, 5'd1, 5'd0), '0, '0, res, ex);
    if (ex.valid) begin
      $display("[FAIL] Unexpected exception reading CSR_VSTART");
      err_cnt++;
    end
    vstart_val = int'(res);
  endtask

  task automatic read_vl_csr(output int unsigned vl_val);
    elen_t      res;
    exception_t ex;
    dispatch_insn(enc_csrrs(riscv::CSR_VL, 5'd1, 5'd0), '0, '0, res, ex);
    if (ex.valid) begin
      $display("[FAIL] Unexpected exception reading CSR_VL");
      err_cnt++;
    end
    vl_val = int'(res);
  endtask

  // Architectural VRF shadow model (32 regs x 16 bytes)
  logic [7:0] ref_vrf [32][16];
  vew_e       ref_reg_eew [32];

  // Initialize architectural VRF + DUT VRF cleanly via whole-register loads at EW8..EW64
  task automatic init_vreg_via_vle(
    input int unsigned vreg,
    input vew_e        eew,
    input int unsigned scratch_addr
  );
    int unsigned vl_out;
    elen_t       res;
    exception_t  ex;
    int unsigned elems_per_reg = 16 >> int'(eew);

    for (int b = 0; b < 16; b++) begin
      logic [7:0] val = 8'(urand());
      axi_ram[scratch_addr + b] = val;
      ref_ram[scratch_addr + b] = val;
      ref_vrf[vreg][b]          = val;
    end
    ref_reg_eew[vreg] = eew;

    set_vtype_vl(elems_per_reg, eew, LMUL_1, vl_out);
    exp_load_complete_cnt++;
    dispatch_insn(enc_vmem(1'b0, 3'd0, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(eew), 5'(vreg)),
                  elen_t'(scratch_addr), '0, res, ex);
    if (ex.valid) begin
      $display("[FAIL] Unexpected exception in init_vreg_via_vle v%0d", vreg);
      err_cnt++;
    end
    wait_backend_quiescent();
  endtask

  task automatic load_v0_mask(input logic [127:0] mask_bits, input int unsigned scratch_addr);
    int unsigned vl_out;
    elen_t       res;
    exception_t  ex;

    for (int b = 0; b < 16; b++) begin
      axi_ram[scratch_addr + b] = mask_bits[b*8 +: 8];
      ref_ram[scratch_addr + b] = mask_bits[b*8 +: 8];
      ref_vrf[0][b]             = mask_bits[b*8 +: 8];
    end
    ref_reg_eew[0] = EW8;

    set_vtype_vl(16, EW8, LMUL_1, vl_out);
    exp_load_complete_cnt++;
    dispatch_insn(enc_vmem(1'b0, 3'd0, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, 3'b000, 5'd0),
                  elen_t'(scratch_addr), '0, res, ex);
    if (ex.valid) begin
      $display("[FAIL] Unexpected exception in load_v0_mask");
      err_cnt++;
    end
    wait_backend_quiescent();
  endtask

  function automatic int unsigned calc_emul_regs(input vlmul_e vlmul, input vew_e vsew, input vew_e eew);
    logic [2:0] emul_raw;
    emul_raw = 3'(vlmul) + (3'(eew) - 3'(vsew));
    if (emul_raw[2]) return 1;
    else             return (1 << emul_raw[1:0]);
  endfunction

  // Golden RVV 1.0 reference execution + full VRF & RAM checker for a legal segment op
  task automatic run_and_check_legal_seg_op(
    input string       tag,
    input bit          is_store_op,
    input bit          is_strided_op,
    input logic [2:0]  nf,          // NFIELDS - 1 (1..7)
    input vew_e        vsew,
    input vlmul_e      vlmul,
    input vew_e        eew,
    input bit          vm,
    input int unsigned avl,
    input int unsigned init_vstart,
    input int unsigned base_reg,
    input int unsigned base_addr,
    input longint      stride_bytes
  );
    int unsigned vl_actual, vstart_after;
    int unsigned nfields     = int'(nf) + 1;
    int unsigned eew_bytes   = 1 << int'(eew);
    int unsigned emul_regs   = calc_emul_regs(vlmul, vsew, eew);
    longint      elem_stride = is_strided_op ? stride_bytes : longint'(nfields * eew_bytes);
    elen_t       res;
    exception_t  ex;

    set_vtype_vl(avl, vsew, vlmul, vl_actual);
    if (init_vstart != 0) write_vstart(init_vstart);

    if (is_store_op) exp_store_complete_cnt++;
    else             exp_load_complete_cnt++;

    dispatch_insn(
      enc_vmem(is_store_op, nf, 1'b0, is_strided_op ? 2'b10 : 2'b00, vm, 5'b00000,
               5'd1, eew_to_width(eew), 5'(base_reg)),
      elen_t'(longint'(base_addr)),
      elen_t'(stride_bytes),
      res, ex
    );

    if (ex.valid) begin
      $display("[FAIL] %s raised unexpected exception cause=%0d", tag, ex.cause);
      err_cnt++;
      return;
    end

    wait_backend_quiescent();

    // Update golden reference model
    if (init_vstart < vl_actual) begin
      // Update ref_reg_eew for touched registers if segment load (or reshuffled store)
      if (!is_store_op) begin
        for (int unsigned f = 0; f < nfields; f++) begin
          for (int unsigned r = 0; r < emul_regs; r++) begin
            ref_reg_eew[base_reg + f * emul_regs + r] = eew;
          end
        end
      end

      for (int unsigned e = init_vstart; e < vl_actual; e++) begin
        bit mask_active = vm || ((ref_vrf[0][e >> 3] >> (e & 7)) & 1'b1);
        if (mask_active) begin
          for (int unsigned f = 0; f < nfields; f++) begin
            longint maddr = longint'(base_addr) + longint'(e) * elem_stride + longint'(f * eew_bytes);
            int unsigned reg_off  = (e * eew_bytes) >> 4;
            int unsigned byte_off = (e * eew_bytes) & 15;
            int unsigned vreg_idx = base_reg + f * emul_regs + reg_off;
            for (int unsigned b = 0; b < eew_bytes; b++) begin
              if (is_store_op) begin
                ref_ram[(maddr + b) & (MEM_BYTES - 1)] = ref_vrf[vreg_idx][byte_off + b];
              end else begin
                ref_vrf[vreg_idx][byte_off + b] = ref_ram[(maddr + b) & (MEM_BYTES - 1)];
              end
            end
          end
        end
      end
    end

    // Verify vstart reset to 0 after completion
    read_vstart(vstart_after);
    if (vstart_after != 0) begin
      $display("[FAIL] %s left CSR_VSTART=%0d (expected 0)", tag, vstart_after);
      err_cnt++;
    end

    // Verify VRF contents via architectural store readback on touched registers if load,
    // or verify RAM contents directly if store!
    if (!is_store_op && (init_vstart < vl_actual)) begin
      for (int unsigned f = 0; f < nfields; f++) begin
        for (int unsigned r = 0; r < emul_regs; r++) begin
          int unsigned vr = base_reg + f * emul_regs + r;
          logic [127:0] got_vec = read_vrf_logical(vr, eew);
          for (int unsigned b = 0; b < 16; b++) begin
            if (got_vec[b*8 +: 8] !== ref_vrf[vr][b]) begin
              $display("[FAIL] %s VRF mismatch at v%0d byte %0d: got 0x%02x exp 0x%02x",
                       tag, vr, b, got_vec[b*8 +: 8], ref_vrf[vr][b]);
              err_cnt++;
              if (err_cnt > 20) $finish(1);
            end
          end
        end
      end
    end

    if (is_store_op) begin
      // Check entire active window in RAM
      for (int unsigned a = 0; a < 16384; a++) begin
        if (axi_ram[a] !== ref_ram[a]) begin
          $display("[FAIL] %s RAM mismatch at 0x%04x: got 0x%02x exp 0x%02x",
                   tag, a, axi_ram[a], ref_ram[a]);
          err_cnt++;
          if (err_cnt > 20) $finish(1);
        end
      end
    end
  endtask

  // =========================================================================
  // Main Seeded Test Sequence
  // =========================================================================
  int unsigned seed;

  initial begin
    if (!$value$plusargs("seed=%d", seed)) begin
      if (!$value$plusargs("SEED=%d", seed)) seed = 101;
    end
    rng_state = (seed == 0) ? 32'h1357_9BDF : (32'(seed) ^ 32'h9E37_79B9);

    acc_req               = '0;
    acc_req.resp_ready    = 1'b1;
    en_ld_st_translation  = 1'b0;
    fault_enable          = 1'b0;
    fault_vaddr_lo        = '0;
    fault_vaddr_hi        = '0;
    saw_mmu_fault_this_op = 1'b0;
    enable_random_stalls  = 1'b0;
    exp_load_complete_cnt = 0;
    exp_store_complete_cnt = 0;
    err_cnt               = 0;

    for (int i = 0; i < MEM_BYTES; i++) begin
      logic [7:0] v = 8'(urand());
      axi_ram[i] = v;
      ref_ram[i] = v;
    end
    for (int r = 0; r < 32; r++) begin
      vrf_mem[r][0] = '0;
      vrf_mem[r][1] = '0;
      for (int b = 0; b < 16; b++) ref_vrf[r][b] = 8'h00;
      ref_reg_eew[r] = EW8;
    end

    // Reset sequence
    rst_ni = 1'b0;
    repeat (6) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (4) @(posedge clk_i);

    // Initialize all 32 vector registers via architectural loads
    for (int r = 0; r < 32; r++) begin
      init_vreg_via_vle(r, EW8, 32'h8000 + r * 16);
    end

    // -----------------------------------------------------------------------
    // Suite 5 FIRST-PART: Illegal Encoding Checks BEFORE & BETWEEN Valid Ops
    // (Specifically tests that illegal segment loads/stores raise ILLEGAL_INSTR,
    // pulse load_complete/store_complete once, and do NOT poison pending_seg_mem_op_q!)
    // -----------------------------------------------------------------------
    begin
      elen_t      res;
      exception_t ex;
      int unsigned vl_tmp;

      // 5a. vill == 1 check: set illegal vtype (SEW=EW64 with LMUL_1_8 -> vill=1)
      dispatch_insn(enc_vsetvl_reg(5'd1, 5'd1, 5'd2), 64'd4, 64'b0_0_0_011_101, res, ex);
      // Issue vlseg2e8.v and vsseg2e8.v while vill == 1
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd1, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, 3'b000, 5'd4),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vlseg with vill=1");
        err_cnt++;
      end
      exp_store_complete_cnt++;
      dispatch_insn(enc_vmem(1'b1, 3'd1, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, 3'b000, 5'd4),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vsseg with vill=1");
        err_cnt++;
      end

      // 5b. EMUL * NFIELDS > 8 boundary cases:
      // EMUL = 2, NFIELDS = 5 (nf = 4) -> 2 * 5 = 10 > 8!
      set_vtype_vl(8, EW16, LMUL_2, vl_tmp);
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd4, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW16), 5'd4),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vlseg5e16 with EMUL=2");
        err_cnt++;
      end
      exp_store_complete_cnt++;
      dispatch_insn(enc_vmem(1'b1, 3'd4, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW16), 5'd4),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vsseg5e16 with EMUL=2");
        err_cnt++;
      end

      // EMUL = 4 (via LMUL=2, SEW=16, EEW=32!), NFIELDS = 3 (nf = 2) -> 4 * 3 = 12 > 8!
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd2, 1'b0, 2'b10, 1'b1, 5'b00000, 5'd1, eew_to_width(EW32), 5'd4),
                    64'h1000, 64'd16, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vlsseg3e32 with EMUL=4");
        err_cnt++;
      end

      // EMUL = 8, NFIELDS = 2 (nf = 1) -> 8 * 2 = 16 > 8!
      set_vtype_vl(16, EW32, LMUL_8, vl_tmp);
      exp_store_complete_cnt++;
      dispatch_insn(enc_vmem(1'b1, 3'd1, 1'b0, 2'b10, 1'b1, 5'b00000, 5'd1, eew_to_width(EW32), 5'd0),
                    64'h1000, 64'd16, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vssseg2e32 with EMUL=8");
        err_cnt++;
      end

      // 5c. Register wrap past v31 on BOTH vd (load) AND vs3 (store), for EMUL >= 1 and EMUL < 1!
      // EMUL = 2, nf = 1 (2 fields x 2 regs = 4 regs), base = v30 -> accesses v30..v33 > v31!
      set_vtype_vl(8, EW16, LMUL_2, vl_tmp);
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd1, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW16), 5'd30),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vlseg2e16 vd=v30 EMUL=2 wrap");
        err_cnt++;
      end
      exp_store_complete_cnt++;
      dispatch_insn(enc_vmem(1'b1, 3'd1, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW16), 5'd30),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vsseg2e16 vs3=v30 EMUL=2 wrap");
        err_cnt++;
      end

      // Fractional EMUL = 1/2 (LMUL_1_2, EW8), nf = 5 (6 fields x 1 reg = 6 regs), base = v28 -> v28..v33 > v31!
      set_vtype_vl(4, EW8, LMUL_1_2, vl_tmp);
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd5, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW8), 5'd28),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vlseg6e8 vd=v28 EMUL=1/2 wrap");
        err_cnt++;
      end
      exp_store_complete_cnt++;
      dispatch_insn(enc_vmem(1'b1, 3'd5, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW8), 5'd28),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vsseg6e8 vs3=v28 EMUL=1/2 wrap");
        err_cnt++;
      end

      // 5d. Unaligned base register for EMUL = 2 (vd=v3, vs3=v5) & masked load overlapping v0 (vd=v0, vm=0)
      set_vtype_vl(8, EW16, LMUL_2, vl_tmp);
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd1, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW16), 5'd3),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for unaligned vd=v3 EMUL=2");
        err_cnt++;
      end
      set_vtype_vl(4, EW16, LMUL_1, vl_tmp);
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd2, 1'b0, 2'b00, 1'b0, 5'b00000, 5'd1, eew_to_width(EW16), 5'd0),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for masked vlseg overlapping v0");
        err_cnt++;
      end

      // 5e. vlm.v / vsm.v with nf != 0
      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd1, 1'b0, 2'b00, 1'b1, 5'b01011, 5'd1, 3'b000, 5'd2),
                    64'h1000, '0, res, ex);
      if (!ex.valid || ex.cause != riscv::ILLEGAL_INSTR) begin
        $display("[FAIL] Expected ILLEGAL_INSTR for vlm.v with nf != 0");
        err_cnt++;
      end

      wait_backend_quiescent();
    end

    // -----------------------------------------------------------------------
    // Suite 1: Unit-Stride Segment Loads & Stores Across All NFIELDS=2..8,
    // EW8..EW64, EMUL = {1/8, 1/4, 1/2, 1, 2, 4}, and EEW != SEW
    // -----------------------------------------------------------------------
    for (int unsigned nf_i = 1; nf_i <= 7; nf_i++) begin
      run_and_check_legal_seg_op(
        $sformatf("unit_load_nf%0d_ew8_lmul1", nf_i + 1),
        1'b0, 1'b0, 3'(nf_i), EW8, LMUL_1, EW8, 1'b1, 11, 0, 2, 32'h0400 + nf_i * 256, 0
      );
      run_and_check_legal_seg_op(
        $sformatf("unit_store_nf%0d_ew8_lmul1", nf_i + 1),
        1'b1, 1'b0, 3'(nf_i), EW8, LMUL_1, EW8, 1'b1, 11, 0, 2, 32'h1400 + nf_i * 256, 0
      );
    end

    // EW16, EW32, EW64 with EMUL=2 (nf=1,2,3 -> up to NFIELDS=4 -> v24..v31 exact boundary!)
    run_and_check_legal_seg_op("unit_load_nf4_ew16_emul2_v24",  1'b0, 1'b0, 3'd3, EW32, LMUL_4, EW16, 1'b1, 13, 0, 24, 32'h0200, 0);
    run_and_check_legal_seg_op("unit_store_nf4_ew16_emul2_v24", 1'b1, 1'b0, 3'd3, EW32, LMUL_4, EW16, 1'b1, 13, 0, 24, 32'h2200, 0);

    // EMUL = 4 (LMUL_2, SEW=EW16, EEW=EW32 -> EMUL=4), NFIELDS=2 (nf=1) at v24..v31
    run_and_check_legal_seg_op("unit_load_nf2_ew32_emul4_v24",  1'b0, 1'b0, 3'd1, EW16, LMUL_2, EW32, 1'b1, 14, 0, 24, 32'h0600, 0);
    run_and_check_legal_seg_op("unit_store_nf2_ew32_emul4_v24", 1'b1, 1'b0, 3'd1, EW16, LMUL_2, EW32, 1'b1, 14, 0, 24, 32'h2600, 0);

    // EW64 with NFIELDS=8 (nf=7), EMUL=1 at v24..v31 (exact upper boundary v31!)
    run_and_check_legal_seg_op("unit_load_nf8_ew64_emul1_v24",  1'b0, 1'b0, 3'd7, EW64, LMUL_1, EW64, 1'b1, 2, 0, 24, 32'h0800, 0);
    run_and_check_legal_seg_op("unit_store_nf8_ew64_emul1_v24", 1'b1, 1'b0, 3'd7, EW64, LMUL_1, EW64, 1'b1, 2, 0, 24, 32'h2800, 0);

    // Fractional EMUL = 1/4 (LMUL_1_2, SEW=EW32, EEW=EW16 -> EMUL=1/4), NFIELDS=6 at v26..v31
    run_and_check_legal_seg_op("unit_load_nf6_ew16_emul1_4_v26",  1'b0, 1'b0, 3'd5, EW32, LMUL_1_2, EW16, 1'b1, 2, 0, 26, 32'h0A00, 0);
    run_and_check_legal_seg_op("unit_store_nf6_ew16_emul1_4_v26", 1'b1, 1'b0, 3'd5, EW32, LMUL_1_2, EW16, 1'b1, 2, 0, 26, 32'h2A00, 0);

    // -----------------------------------------------------------------------
    // Suite 2: Strided Segment Loads & Stores (Positive, Negative, and Zero Strides)
    // -----------------------------------------------------------------------
    enable_random_stalls = 1'b1;
    // Positive stride
    run_and_check_legal_seg_op("strided_pos_load_nf3_ew32",  1'b0, 1'b1, 3'd2, EW32, LMUL_2, EW32, 1'b1, 7, 0, 4, 32'h0C00, 64'sd24);
    run_and_check_legal_seg_op("strided_pos_store_nf3_ew32", 1'b1, 1'b1, 3'd2, EW32, LMUL_2, EW32, 1'b1, 7, 0, 4, 32'h2C00, 64'sd20);

    // Negative stride (-32 bytes per element, starting at high address)
    run_and_check_legal_seg_op("strided_neg_load_nf4_ew16",  1'b0, 1'b1, 3'd3, EW16, LMUL_1, EW16, 1'b1, 6, 0, 12, 32'h0F00, -64'sd32);
    run_and_check_legal_seg_op("strided_neg_store_nf4_ew16", 1'b1, 1'b1, 3'd3, EW16, LMUL_1, EW16, 1'b1, 6, 0, 12, 32'h2F00, -64'sd24);

    // Zero stride (broadcast segment load & last-active-element-wins segment store)
    run_and_check_legal_seg_op("strided_zero_load_nf3_ew16",  1'b0, 1'b1, 3'd2, EW16, LMUL_1, EW16, 1'b1, 5, 0, 16, 32'h0D00, 64'sd0);
    run_and_check_legal_seg_op("strided_zero_store_nf3_ew16", 1'b1, 1'b1, 3'd2, EW16, LMUL_1, EW16, 1'b1, 5, 0, 16, 32'h2D00, 64'sd0);

    // -----------------------------------------------------------------------
    // Suite 3: Masked (vm=0), vstart > 0, Masked Store from v0, and vl==0 / vstart>=vl
    // -----------------------------------------------------------------------
    load_v0_mask(128'h0000_0000_0000_0000_0000_0000_A55A_C369, 32'h9000);
    run_and_check_legal_seg_op("masked_load_nf5_ew16_vstart2",  1'b0, 1'b0, 3'd4, EW16, LMUL_1, EW16, 1'b0, 8, 2, 4, 32'h1100, 0);
    run_and_check_legal_seg_op("masked_store_nf5_ew16_vstart3", 1'b1, 1'b1, 3'd4, EW16, LMUL_1, EW16, 1'b0, 8, 3, 4, 32'h3100, 64'sd16);

    // Masked segment store with vs3 == v0 (legal per RVV 1.0!)
    run_and_check_legal_seg_op("masked_store_from_v0_nf2_ew8", 1'b1, 1'b0, 3'd1, EW8, LMUL_1, EW8, 1'b0, 12, 1, 0, 32'h3300, 0);

    // vl == 0 and vstart >= vl NOP segment ops
    run_and_check_legal_seg_op("zero_vl_seg_load",      1'b0, 1'b0, 3'd3, EW32, LMUL_1, EW32, 1'b1, 0, 0, 8, 32'h3400, 0);
    run_and_check_legal_seg_op("zero_vl_seg_store",     1'b1, 1'b0, 3'd3, EW32, LMUL_1, EW32, 1'b1, 0, 0, 8, 32'h3400, 0);
    run_and_check_legal_seg_op("vstart_ge_vl_seg_load", 1'b0, 1'b1, 3'd2, EW16, LMUL_1, EW16, 1'b1, 4, 6, 8, 32'h3400, 64'sd8);
    run_and_check_legal_seg_op("vstart_ge_vl_seg_store",1'b1, 1'b1, 3'd2, EW16, LMUL_1, EW16, 1'b1, 4, 4, 8, 32'h3400, 64'sd8);

    // -----------------------------------------------------------------------
    // Suite 4: Dynamic Per-Register EEW Tracking & Mixed-EEW Reshuffling
    // -----------------------------------------------------------------------
    init_vreg_via_vle(8,  EW64, 32'h9100);
    init_vreg_via_vle(9,  EW8,  32'h9110);
    init_vreg_via_vle(10, EW32, 32'h9120);
    init_vreg_via_vle(11, EW16, 32'h9130);
    // Segment store across v8..v11 with EW16 (tests heterogeneous old_eew_vs1 / reshuffle!)
    run_and_check_legal_seg_op("mixed_eew_seg_store_v8_v11", 1'b1, 1'b0, 3'd3, EW16, LMUL_1, EW16, 1'b1, 7, 1, 8, 32'h3500, 0);

    // Re-init v12..v14 with EW64, EW32, EW16, then masked partial EW8 segment load, then full EW8 segment store!
    init_vreg_via_vle(12, EW64, 32'h9200);
    init_vreg_via_vle(13, EW32, 32'h9210);
    init_vreg_via_vle(14, EW16, 32'h9220);
    run_and_check_legal_seg_op("mixed_eew_partial_masked_load", 1'b0, 1'b0, 3'd2, EW8, LMUL_1, EW8, 1'b0, 6, 0, 12, 32'h1200, 0);
    run_and_check_legal_seg_op("mixed_eew_followup_full_store", 1'b1, 1'b0, 3'd2, EW8, LMUL_1, EW8, 1'b1, 16, 0, 12, 32'h3600, 0);

    // -----------------------------------------------------------------------
    // Suite 6: SV39 MMU Mid-Segment Page Faults, Final-Uop Faults, FoF & Resume
    // -----------------------------------------------------------------------
    en_ld_st_translation = 1'b1;
    begin
      elen_t       res;
      exception_t  ex;
      int unsigned vl_actual, fault_vstart, fof_vl;

      // 6a. Mid-segment load page fault at (elem=3, field=2) of vlseg4e32.v (base 0x0FF0, crosses into 0x1028)
      // elem 3 field 0 = 0x0FF0 + 48 = 0x1020, field 1 = 0x1024, field 2 = 0x1028!
      set_vtype_vl(4, EW32, LMUL_1, vl_actual);
      fault_enable          = 1'b1;
      fault_vaddr_lo        = 64'h1028;
      fault_vaddr_hi        = 64'h1100;
      saw_mmu_fault_this_op = 1'b0;
      post_fault_axi_reqs   = 0;

      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd3, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW32), 5'd20),
                    64'h0FF0, '0, res, ex);
      wait_backend_quiescent();

      if (!ex.valid || ex.cause != riscv::LOAD_PAGE_FAULT) begin
        $display("[FAIL] Expected LOAD_PAGE_FAULT on mid-segment load, got valid=%0d cause=%0d", ex.valid, ex.cause);
        err_cnt++;
      end
      if (post_fault_axi_reqs != 0) begin
        $display("[FAIL] Issued %0d AXI requests after MMU fault on segment load", post_fault_axi_reqs);
        err_cnt++;
      end
      read_vstart(fault_vstart);
      if (fault_vstart != 3) begin
        $display("[FAIL] Mid-segment load fault set vstart=%0d (expected 3)", fault_vstart);
        err_cnt++;
      end

      // Update reference model for pre-fault transfers (elems 0..2 all fields, elem 3 fields 0..1)
      for (int e = 0; e < 4; e++) begin
        for (int f = 0; f < 4; f++) begin
          if ((e < 3) || (e == 3 && f < 2)) begin
            for (int b = 0; b < 4; b++)
              ref_vrf[20 + f][e*4 + b] = ref_ram[32'h0FF0 + e*16 + f*4 + b];
          end
        end
      end

      // Clear page fault ("OS page-in") and resume with vstart == 3!
      fault_enable          = 1'b0;
      saw_mmu_fault_this_op = 1'b0;
      run_and_check_legal_seg_op("resume_after_load_pf", 1'b0, 1'b0, 3'd3, EW32, LMUL_1, EW32, 1'b1, 4, 3, 20, 32'h0FF0, 0);

      // 6b. Final micro-op store page fault at (elem=2, field=2) of vsseg3e32.v (vl=3, nf=2)
      set_vtype_vl(3, EW32, LMUL_1, vl_actual);
      fault_enable          = 1'b1;
      fault_vaddr_lo        = 64'h3820; // base 0x3800: elem 2 field 2 is 0x3800 + 2*12 + 8 = 0x3820!
      fault_vaddr_hi        = 64'h3900;
      saw_mmu_fault_this_op = 1'b0;
      post_fault_axi_reqs   = 0;

      exp_store_complete_cnt++;
      dispatch_insn(enc_vmem(1'b1, 3'd2, 1'b0, 2'b00, 1'b1, 5'b00000, 5'd1, eew_to_width(EW32), 5'd20),
                    64'h3800, '0, res, ex);
      wait_backend_quiescent();

      if (!ex.valid || ex.cause != riscv::STORE_PAGE_FAULT) begin
        $display("[FAIL] Expected STORE_PAGE_FAULT on final micro-op of vsseg, got valid=%0d cause=%0d", ex.valid, ex.cause);
        err_cnt++;
      end
      read_vstart(fault_vstart);
      if (fault_vstart != 2) begin
        $display("[FAIL] Final micro-op store fault set vstart=%0d (expected 2)", fault_vstart);
        err_cnt++;
      end
      // Verify faulted address 0x3820..0x3823 in axi_ram was NOT written!
      for (int b = 0; b < 4; b++) begin
        if (axi_ram[32'h3820 + b] !== ref_ram[32'h3820 + b]) begin
          $display("[FAIL] Faulted final store micro-op modified memory at 0x%04x", 32'h3820 + b);
          err_cnt++;
        end
      end
      // Update ref_ram for committed pre-fault store micro-ops (elems 0..1 all fields, elem 2 fields 0..1)
      for (int e = 0; e < 3; e++) begin
        for (int f = 0; f < 3; f++) begin
          if ((e < 2) || (e == 2 && f < 2)) begin
            for (int b = 0; b < 4; b++)
              ref_ram[32'h3800 + e*12 + f*4 + b] = ref_vrf[20 + f][e*4 + b];
          end
        end
      end
      // Remap page and resume store from vstart=2!
      fault_enable          = 1'b0;
      saw_mmu_fault_this_op = 1'b0;
      run_and_check_legal_seg_op("resume_after_store_pf", 1'b1, 1'b0, 3'd2, EW32, LMUL_1, EW32, 1'b1, 3, 2, 20, 32'h3800, 0);

      // 6c. Fault-only-first vlseg3e32ff.v: fault at elem=2, field=1 trims vl to 2 without trapping!
      set_vtype_vl(4, EW32, LMUL_1, vl_actual);
      fault_enable          = 1'b1;
      fault_vaddr_lo        = 64'h091C; // base 0x0900: elem 2 field 1 is 0x0900 + 2*12 + 4 = 0x091C
      fault_vaddr_hi        = 64'h0980;
      saw_mmu_fault_this_op = 1'b0;

      exp_load_complete_cnt++;
      dispatch_insn(enc_vmem(1'b0, 3'd2, 1'b0, 2'b00, 1'b1, 5'b10000, 5'd1, eew_to_width(EW32), 5'd16),
                    64'h0900, '0, res, ex);
      wait_backend_quiescent();
      if (ex.valid) begin
        $display("[FAIL] vlseg3e32ff.v trapped on elem=2 instead of trimming vl");
        err_cnt++;
      end
      read_vl_csr(fof_vl);
      if (fof_vl != 2) begin
        $display("[FAIL] vlseg3e32ff.v set vl=%0d (expected 2)", fof_vl);
        err_cnt++;
      end
      // Update ref_vrf for Synchronization after FoF
      fault_enable          = 1'b0;
      saw_mmu_fault_this_op = 1'b0;
      for (int f = 0; f < 3; f++) init_vreg_via_vle(16 + f, EW32, 32'h9300 + f * 16);
    end

    // -----------------------------------------------------------------------
    // Randomized Multi-Instruction Stress Stream (36 operations under stalls)
    // -----------------------------------------------------------------------
    for (int iter = 0; iter < 36; iter++) begin
      automatic vew_e        r_eew   = vew_e'(urand() & 3);
      automatic vew_e        r_vsew  = r_eew;
      automatic int unsigned emul_pick = urand() % 5;
      automatic vlmul_e      r_lmul;
      automatic int unsigned max_nf, r_nf_int, emul_r, max_base, r_base, vlmax, r_avl, r_vstart;
      automatic bit          r_store   = bit'(urand() & 1);
      automatic bit          r_strided = bit'((urand() >> 1) & 1);
      automatic bit          r_vm      = bit'((urand() >> 2) & 1);
      automatic int unsigned eew_b     = 1 << int'(r_eew);
      automatic longint      r_stride;
      automatic int unsigned r_addr;

      case (emul_pick)
        0: begin r_lmul = LMUL_1_2; emul_r = 1; max_nf = 7; end
        1: begin r_lmul = LMUL_1;   emul_r = 1; max_nf = 7; end
        2: begin r_lmul = LMUL_2;   emul_r = 2; max_nf = 3; end
        3: begin r_lmul = LMUL_4;   emul_r = 4; max_nf = 1; end
        default: begin r_lmul = LMUL_1; emul_r = 1; max_nf = 7; end
      endcase
      if ((r_lmul == LMUL_1_2) && (r_vsew == EW64)) r_lmul = LMUL_1;

      r_nf_int = 1 + (urand() % max_nf);
      max_base = 32 - ((r_nf_int + 1) * emul_r);
      r_base   = ((urand() % ((max_base / emul_r) + 1)) * emul_r);
      if (!r_store && !r_vm && (r_base == 0)) r_base = emul_r;

      vlmax    = (r_lmul == LMUL_1_2) ? ((VLENB >> 1) >> int'(r_eew)) : ((VLENB * emul_r) >> int'(r_eew));
      if (vlmax == 0) vlmax = 1;
      r_avl    = 1 + (urand() % vlmax);
      r_vstart = ((urand() & 3) == 0) ? (urand() % r_avl) : 0;

      if (r_strided) begin
        int signed step_units = int'((urand() % 9)) - 3; // -3..+5 segments
        r_stride = longint'(step_units) * longint'((r_nf_int + 1) * eew_b);
      end else begin
        r_stride = 0;
      end

      r_addr = (r_store ? 32'h2000 : 32'h0400) + (((urand() % 64) * 16) & ~(eew_b - 1));
      if (r_stride < 0) r_addr += 32'h0800;

      run_and_check_legal_seg_op(
        $sformatf("rand_iter_%0d", iter),
        r_store, r_strided, 3'(r_nf_int), r_vsew, r_lmul, r_eew, r_vm,
        r_avl, r_vstart, r_base, r_addr, r_stride
      );
    end

    wait_backend_quiescent();
    repeat (6) @(posedge clk_i);

    if (obs_load_complete_cnt != exp_load_complete_cnt) begin
      $display("[FAIL] load_complete count mismatch: observed=%0d expected=%0d",
               obs_load_complete_cnt, exp_load_complete_cnt);
      err_cnt++;
    end
    if (obs_store_complete_cnt != exp_store_complete_cnt) begin
      $display("[FAIL] store_complete count mismatch: observed=%0d expected=%0d",
               obs_store_complete_cnt, exp_store_complete_cnt);
      err_cnt++;
    end

    if (err_cnt == 0) begin
      $display("PASS seed=%0d (loads=%0d stores=%0d)", seed, obs_load_complete_cnt, obs_store_complete_cnt);
      $finish(0);
    end else begin
      $display("FAIL seed=%0d errors=%0d", seed, err_cnt);
      $finish(1);
    end
  end
endmodule
