// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Private boundary verification testbench for ot_mbx_top (`case_1012`).

module tb #(
  parameter int SEED = 101
);
  import tlul_pkg::*;

  localparam int unsigned CfgSramAddrWidth   = 32;
  localparam int unsigned CfgSramDataWidth   = 32;
  localparam int unsigned CfgObjectSizeWidth = 11;

  logic                          clk_i;
  logic                          rst_ni;
  logic                          hostif_control_abort_clear_i;
  logic                          mbx_error_set_i;
  logic                          hostif_range_valid_write_i;
  logic                          hostif_range_valid_i;
  logic [CfgSramAddrWidth-1:0]   hostif_imbx_base_i;
  logic [CfgSramAddrWidth-1:0]   hostif_imbx_limit_i;
  logic [CfgSramAddrWidth-1:0]   hostif_ombx_base_i;
  logic [CfgSramAddrWidth-1:0]   hostif_ombx_limit_i;
  logic                          sysif_status_busy_i;
  logic                          sysif_status_ready_i;
  logic                          sysif_control_go_set_i;
  logic                          sysif_control_abort_set_i;
  logic                          sysif_data_write_valid_i;
  logic [CfgSramDataWidth-1:0]   imbx_write_data_i;
  logic                          sysif_read_data_read_valid_i;
  logic                          sysif_read_data_write_valid_i;
  logic                          hostif_ombx_object_size_write_i;
  logic [CfgObjectSizeWidth-1:0] hostif_ombx_object_size_i;
  tlul_pkg::tl_d2h_t             tl_host_i;

  // DUT outputs
  logic                          dut_hostif_ombx_object_size_update_o;
  logic [CfgObjectSizeWidth-1:0] dut_hostif_ombx_object_size_o;
  logic [CfgSramDataWidth-1:0]   dut_ombx_read_data_o;
  logic                          dut_imbx_state_error_o;
  logic                          dut_imbx_pending_o;
  logic                          dut_imbx_irq_ready_o;
  logic                          dut_imbx_irq_abort_o;
  logic                          dut_imbx_status_busy_update_o;
  logic                          dut_imbx_status_busy_o;
  logic                          dut_imbx_overflow_error_set_o;
  logic                          dut_ombx_state_error_o;
  logic                          dut_ombx_doe_intr_ready_set_o;
  logic                          dut_ombx_pending_o;
  logic                          dut_ombx_status_ready_update_o;
  logic                          dut_ombx_status_ready_o;
  tlul_pkg::tl_h2d_t             dut_tl_host_o;
  logic                          dut_intg_err_o;
  logic                          dut_sram_err_o;

  // Reference outputs
  logic                          ref_hostif_ombx_object_size_update_o;
  logic [CfgObjectSizeWidth-1:0] ref_hostif_ombx_object_size_o;
  logic [CfgSramDataWidth-1:0]   ref_ombx_read_data_o;
  logic                          ref_imbx_state_error_o;
  logic                          ref_imbx_pending_o;
  logic                          ref_imbx_irq_ready_o;
  logic                          ref_imbx_irq_abort_o;
  logic                          ref_imbx_status_busy_update_o;
  logic                          ref_imbx_status_busy_o;
  logic                          ref_imbx_overflow_error_set_o;
  logic                          ref_ombx_state_error_o;
  logic                          ref_ombx_doe_intr_ready_set_o;
  logic                          ref_ombx_pending_o;
  logic                          ref_ombx_status_ready_update_o;
  logic                          ref_ombx_status_ready_o;
  tlul_pkg::tl_h2d_t             ref_tl_host_o;
  logic                          ref_intg_err_o;
  logic                          ref_sram_err_o;

  ot_mbx_top #(
    .CfgSramAddrWidth  (CfgSramAddrWidth),
    .CfgSramDataWidth  (CfgSramDataWidth),
    .CfgObjectSizeWidth(CfgObjectSizeWidth)
  ) dut (
    .clk_i                           (clk_i),
    .rst_ni                          (rst_ni),
    .hostif_control_abort_clear_i    (hostif_control_abort_clear_i),
    .mbx_error_set_i                 (mbx_error_set_i),
    .hostif_range_valid_write_i      (hostif_range_valid_write_i),
    .hostif_range_valid_i            (hostif_range_valid_i),
    .hostif_imbx_base_i              (hostif_imbx_base_i),
    .hostif_imbx_limit_i             (hostif_imbx_limit_i),
    .hostif_ombx_base_i              (hostif_ombx_base_i),
    .hostif_ombx_limit_i             (hostif_ombx_limit_i),
    .sysif_status_busy_i             (sysif_status_busy_i),
    .sysif_status_ready_i            (sysif_status_ready_i),
    .sysif_control_go_set_i          (sysif_control_go_set_i),
    .sysif_control_abort_set_i       (sysif_control_abort_set_i),
    .sysif_data_write_valid_i        (sysif_data_write_valid_i),
    .imbx_write_data_i               (imbx_write_data_i),
    .sysif_read_data_read_valid_i    (sysif_read_data_read_valid_i),
    .sysif_read_data_write_valid_i   (sysif_read_data_write_valid_i),
    .hostif_ombx_object_size_write_i (hostif_ombx_object_size_write_i),
    .hostif_ombx_object_size_i       (hostif_ombx_object_size_i),
    .hostif_ombx_object_size_update_o(dut_hostif_ombx_object_size_update_o),
    .hostif_ombx_object_size_o       (dut_hostif_ombx_object_size_o),
    .ombx_read_data_o                (dut_ombx_read_data_o),
    .imbx_state_error_o              (dut_imbx_state_error_o),
    .imbx_pending_o                  (dut_imbx_pending_o),
    .imbx_irq_ready_o                (dut_imbx_irq_ready_o),
    .imbx_irq_abort_o                (dut_imbx_irq_abort_o),
    .imbx_status_busy_update_o       (dut_imbx_status_busy_update_o),
    .imbx_status_busy_o              (dut_imbx_status_busy_o),
    .imbx_overflow_error_set_o       (dut_imbx_overflow_error_set_o),
    .ombx_state_error_o              (dut_ombx_state_error_o),
    .ombx_doe_intr_ready_set_o       (dut_ombx_doe_intr_ready_set_o),
    .ombx_pending_o                  (dut_ombx_pending_o),
    .ombx_status_ready_update_o      (dut_ombx_status_ready_update_o),
    .ombx_status_ready_o             (dut_ombx_status_ready_o),
    .tl_host_o                       (dut_tl_host_o),
    .tl_host_i                       (tl_host_i),
    .intg_err_o                      (dut_intg_err_o),
    .sram_err_o                      (dut_sram_err_o)
  );

  // Cycle-accurate reference model of ot_mbx_top
  localparam int unsigned LCFG_SRM_ADDRINC = CfgSramDataWidth / 8;
  localparam int unsigned LCFG_MAX_REQS    = 4;
  localparam int unsigned LCFG_MAX_REQS_W  = $clog2(LCFG_MAX_REQS) + 1;

  logic                        ref_sys_read_all;
  logic                        ref_imbx_write_req, ref_imbx_write_gnt, ref_imbx_all_vld_rcvd;
  logic [CfgSramAddrWidth-1:0] ref_imbx_write_ptr;
  logic                        ref_ombx_read_req, ref_ombx_read_gnt, ref_ombx_read_resp_vld;
  logic [CfgSramAddrWidth-1:0] ref_ombx_read_ptr;
  logic [CfgSramDataWidth-1:0] ref_ombx_read_resp;

  // Reference IMBX
  logic [CfgSramAddrWidth-1:0] ref_imbx_ptr_d, ref_imbx_ptr_q;
  logic                        ref_imbx_empty, ref_imbx_write, ref_imbx_read, ref_imbx_sys_abort;
  logic                        ref_imbx_wreq, ref_imbx_req_q;
  logic                        ref_imbx_load_ptr, ref_imbx_adv_ptr, ref_imbx_clr_abort;

  assign ref_imbx_wreq               = (ref_imbx_empty & sysif_data_write_valid_i) |
                                       (ref_imbx_write & sysif_data_write_valid_i & (ref_imbx_ptr_q <= hostif_imbx_limit_i));
  assign ref_imbx_overflow_error_set_o = ref_imbx_write & sysif_data_write_valid_i & (ref_imbx_ptr_q > hostif_imbx_limit_i);
  assign ref_imbx_write_req          = ref_imbx_wreq | ref_imbx_req_q;
  assign ref_imbx_clr_abort          = hostif_control_abort_clear_i & ref_imbx_sys_abort;
  assign ref_imbx_adv_ptr            = ref_imbx_write_req & ref_imbx_write_gnt;
  assign ref_imbx_load_ptr           = (ref_imbx_empty & ~ref_imbx_adv_ptr) | ref_imbx_clr_abort |
                                       (ref_imbx_read & ref_sys_read_all);
  assign ref_imbx_ptr_d              = ref_imbx_load_ptr ? hostif_imbx_base_i :
                                       ref_imbx_adv_ptr  ? (ref_imbx_ptr_q + LCFG_SRM_ADDRINC) :
                                                           ref_imbx_ptr_q;
  assign ref_imbx_write_ptr          = ref_imbx_ptr_q;

  logic ref_imbx_set_busy, ref_imbx_clr_busy;
  assign ref_imbx_set_busy           = (ref_imbx_write & sysif_control_go_set_i & ~mbx_error_set_i & ~sysif_control_abort_set_i) |
                                       sysif_control_abort_set_i | ~hostif_range_valid_i;
  assign ref_imbx_clr_busy           = (hostif_range_valid_write_i & hostif_range_valid_i) |
                                       ref_sys_read_all | hostif_control_abort_clear_i;
  assign ref_imbx_status_busy_update_o = ref_imbx_set_busy | ref_imbx_clr_busy;
  assign ref_imbx_status_busy_o      = ref_imbx_set_busy;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_imbx_req_q     <= 1'b0;
      ref_imbx_pending_o <= 1'b0;
      ref_imbx_ptr_q     <= '0;
    end else begin
      ref_imbx_req_q     <= ref_imbx_write_req & ~ref_imbx_write_gnt & ~hostif_control_abort_clear_i;
      ref_imbx_pending_o <= ~(ref_imbx_write_gnt | hostif_control_abort_clear_i) & (ref_imbx_wreq | ref_imbx_pending_o);
      if (ref_imbx_load_ptr | ref_imbx_adv_ptr) begin
        ref_imbx_ptr_q <= ref_imbx_ptr_d;
      end
    end
  end

  mbx_fsm #(.CfgOmbx(0)) u_ref_imbx_fsm (
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    .mbx_range_valid_i         (hostif_range_valid_i),
    .hostif_abort_ack_i        (hostif_control_abort_clear_i),
    .mbx_error_set_i           (mbx_error_set_i),
    .sysif_control_abort_set_i (sysif_control_abort_set_i),
    .sys_read_all_i            (ref_sys_read_all),
    .writer_close_mbx_i        (sysif_control_go_set_i),
    .writer_last_word_written_i(ref_imbx_all_vld_rcvd),
    .writer_write_valid_i      (sysif_data_write_valid_i),
    .mbx_empty_o               (ref_imbx_empty),
    .mbx_write_o               (ref_imbx_write),
    .mbx_read_o                (ref_imbx_read),
    .mbx_sys_abort_o           (ref_imbx_sys_abort),
    .mbx_ready_update_o        (),
    .mbx_ready_o               (),
    .mbx_irq_ready_o           (ref_imbx_irq_ready_o),
    .mbx_irq_abort_o           (ref_imbx_irq_abort_o),
    .mbx_state_error_o         (ref_imbx_state_error_o)
  );

  // Reference OMBX
  logic [CfgSramAddrWidth-1:0] ref_ombx_ptr_d, ref_ombx_ptr_q, ref_ombx_limit_q;
  logic                        ref_ombx_empty, ref_ombx_read, ref_ombx_sys_abort;
  logic                        ref_ombx_rreq, ref_ombx_req_q, ref_ombx_first_q;
  logic                        ref_ombx_hw_objsz_q, ref_ombx_objsz_upd_vld_q;
  logic                        ref_ombx_set_first, ref_ombx_load_ptr, ref_ombx_adv_ptr, ref_ombx_clr_data;
  logic                        ref_range_valid_set;

  assign ref_range_valid_set = hostif_range_valid_write_i & hostif_range_valid_i;
  logic ref_rem_words_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_rem_words_q <= 1'b0;
    end else if (hostif_control_abort_clear_i) begin
      ref_rem_words_q <= 1'b0;
    end else if (ref_ombx_adv_ptr) begin
      ref_rem_words_q <= (hostif_ombx_object_size_i > CfgObjectSizeWidth'(1));
    end else if (ref_ombx_hw_objsz_q & ~ref_ombx_read) begin
      ref_rem_words_q <= (|hostif_ombx_object_size_i);
    end
  end
  assign ref_ombx_rreq       = ref_ombx_first_q |
                               (ref_ombx_read & sysif_read_data_write_valid_i &
                                (ref_ombx_ptr_q <= hostif_ombx_limit_i) &
                                ref_rem_words_q);
  assign ref_ombx_read_req   = ref_ombx_rreq | ref_ombx_req_q;
  assign ref_sys_read_all    = ref_ombx_read & sysif_read_data_write_valid_i & ~ref_rem_words_q;
  assign ref_ombx_set_first  = ref_ombx_empty & ref_ombx_hw_objsz_q & (|hostif_ombx_object_size_i);
  assign ref_ombx_load_ptr   = ref_range_valid_set | ref_ombx_set_first | ref_sys_read_all |
                               (hostif_control_abort_clear_i & ref_ombx_sys_abort);
  assign ref_ombx_adv_ptr    = ref_ombx_read_req & ref_ombx_read_gnt;
  assign ref_ombx_ptr_d      = ref_ombx_load_ptr ? hostif_ombx_base_i :
                               ref_ombx_adv_ptr  ? (ref_ombx_ptr_q + LCFG_SRM_ADDRINC) :
                                                   ref_ombx_ptr_q;
  assign ref_ombx_read_ptr   = ref_ombx_ptr_q;
  assign ref_ombx_clr_data   = ref_sys_read_all | mbx_error_set_i | sysif_control_abort_set_i |
                               ref_ombx_sys_abort | hostif_control_abort_clear_i;

  assign ref_hostif_ombx_object_size_update_o = ref_ombx_adv_ptr | hostif_control_abort_clear_i;
  assign ref_hostif_ombx_object_size_o        = {CfgObjectSizeWidth{~hostif_control_abort_clear_i}} &
                                                (hostif_ombx_object_size_i - CfgObjectSizeWidth'(1));
  assign ref_ombx_doe_intr_ready_set_o        = ref_ombx_status_ready_o & ref_ombx_status_ready_update_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_ombx_req_q           <= 1'b0;
      ref_ombx_pending_o       <= 1'b0;
      ref_ombx_first_q         <= 1'b0;
      ref_ombx_hw_objsz_q      <= 1'b0;
      ref_ombx_objsz_upd_vld_q <= 1'b0;
      ref_ombx_ptr_q           <= '0;
      ref_ombx_limit_q         <= '0;
      ref_ombx_read_data_o     <= '0;
    end else begin
      ref_ombx_req_q           <= ref_ombx_read_req & ~ref_ombx_read_gnt & ~hostif_control_abort_clear_i;
      ref_ombx_pending_o       <= ~(ref_ombx_read_resp_vld | hostif_control_abort_clear_i) &
                                  ((ref_ombx_read & sysif_read_data_write_valid_i &
                                    (ref_ombx_ptr_q <= hostif_ombx_limit_i) &
                                    ref_rem_words_q) | ref_ombx_pending_o);
      ref_ombx_first_q         <= ref_ombx_set_first | (ref_ombx_first_q & ~ref_ombx_read_gnt);
      ref_ombx_hw_objsz_q      <= hostif_ombx_object_size_write_i & ~ref_ombx_objsz_upd_vld_q;
      ref_ombx_objsz_upd_vld_q <= ref_hostif_ombx_object_size_update_o;
      if (ref_ombx_load_ptr | ref_ombx_adv_ptr) begin
        ref_ombx_ptr_q <= ref_ombx_ptr_d;
      end
      if ((ref_ombx_hw_objsz_q & ~ref_ombx_read) | ref_range_valid_set) begin
        ref_ombx_limit_q <= hostif_ombx_base_i + CfgSramAddrWidth'({hostif_ombx_object_size_i, 2'b0});
      end
      if (ref_ombx_clr_data) begin
        ref_ombx_read_data_o <= '0;
      end else if (ref_ombx_read_resp_vld) begin
        ref_ombx_read_data_o <= ref_ombx_read_resp;
      end
    end
  end

  mbx_fsm #(.CfgOmbx(1)) u_ref_ombx_fsm (
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    .mbx_range_valid_i         (hostif_range_valid_i),
    .hostif_abort_ack_i        (hostif_control_abort_clear_i),
    .mbx_error_set_i           (mbx_error_set_i),
    .sysif_control_abort_set_i (sysif_control_abort_set_i),
    .sys_read_all_i            (ref_sys_read_all),
    .writer_close_mbx_i        (ref_ombx_empty & ref_ombx_read_resp_vld),
    .writer_last_word_written_i(1'b0),
    .writer_write_valid_i      (1'b0),
    .mbx_empty_o               (ref_ombx_empty),
    .mbx_write_o               (),
    .mbx_read_o                (ref_ombx_read),
    .mbx_sys_abort_o           (ref_ombx_sys_abort),
    .mbx_ready_update_o        (ref_ombx_status_ready_update_o),
    .mbx_ready_o               (ref_ombx_status_ready_o),
    .mbx_irq_ready_o           (),
    .mbx_irq_abort_o           (),
    .mbx_state_error_o         (ref_ombx_state_error_o)
  );

  // Reference SRAM R/W Arbiter
  logic                         ref_arb_rd_win, ref_arb_wr_win, ref_sram_gnt, ref_sram_vld, ref_sram_err, ref_max_reqs;
  logic [CfgSramAddrWidth-1:0]  ref_sram_addr;
  logic                         ref_sram_req, ref_inc_cnt, ref_dec_cnt, ref_any_out;
  logic [LCFG_MAX_REQS_W-1:0]   ref_out_cnt_q;

  assign ref_arb_rd_win        = ref_ombx_read_req;
  assign ref_arb_wr_win        = ref_imbx_write_req & ~ref_arb_rd_win;
  assign ref_ombx_read_gnt     = ref_arb_rd_win & (~ref_max_reqs & ref_sram_gnt);
  assign ref_imbx_write_gnt    = ref_arb_wr_win & (~ref_max_reqs & ref_sram_gnt);
  assign ref_sram_addr         = ref_arb_rd_win ? ref_ombx_read_ptr : ref_imbx_write_ptr;
  assign ref_sram_req          = ref_ombx_read_req | ref_imbx_write_req;
  assign ref_inc_cnt           = ref_sram_req & ~ref_max_reqs & ref_sram_gnt;
  assign ref_any_out           = ref_inc_cnt || (ref_out_cnt_q != '0);
  assign ref_dec_cnt           = ref_sram_vld & ref_any_out;
  assign ref_max_reqs          = (ref_out_cnt_q == LCFG_MAX_REQS);
  assign ref_imbx_all_vld_rcvd = (ref_out_cnt_q == '0) & ~ref_sram_req;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_out_cnt_q <= '0;
    end else if (hostif_control_abort_clear_i) begin
      ref_out_cnt_q <= '0;
    end else if (ref_inc_cnt | ref_dec_cnt) begin
      ref_out_cnt_q <= ref_out_cnt_q + ref_inc_cnt - ref_dec_cnt;
    end
  end

  tlul_adapter_host #(
    .MAX_REQS              (LCFG_MAX_REQS),
    .EnableDataIntgGen     (1),
    .EnableRspDataIntgCheck(1)
  ) u_ref_host_adapter (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .req_i       (ref_sram_req & ~ref_max_reqs),
    .gnt_o       (ref_sram_gnt),
    .addr_i      (ref_sram_addr),
    .we_i        (ref_arb_wr_win),
    .wdata_i     (imbx_write_data_i),
    .wdata_intg_i(TL_A_USER_DEFAULT.data_intg),
    .be_i        ({top_pkg::TL_DBW{1'b1}}),
    .instr_type_i(prim_mubi_pkg::MuBi4False),
    .user_rsvd_i ('0),
    .valid_o     (ref_sram_vld),
    .rdata_o     (ref_ombx_read_resp),
    .rdata_intg_o(),
    .err_o       (ref_sram_err),
    .intg_err_o  (ref_intg_err_o),
    .tl_o        (ref_tl_host_o),
    .tl_i        (tl_host_i)
  );

  assign ref_sram_err_o         = ref_sram_err & ref_sram_vld;
  assign ref_ombx_read_resp_vld = ref_sram_vld & ref_any_out & (tl_host_i.d_opcode == tlul_pkg::AccessAckData);

  // Automatic register-side tracking of hostif_ombx_object_size_i when hardware updates it
  logic [CfgObjectSizeWidth-1:0] tb_obj_size_q;
  logic                          tb_obj_size_sw_wr;
  logic [CfgObjectSizeWidth-1:0] tb_obj_size_sw_val;

  assign hostif_ombx_object_size_i       = tb_obj_size_q;
  assign hostif_ombx_object_size_write_i = tb_obj_size_sw_wr;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tb_obj_size_q <= '0;
    end else if (tb_obj_size_sw_wr) begin
      tb_obj_size_q <= tb_obj_size_sw_val;
    end else if (ref_hostif_ombx_object_size_update_o) begin
      tb_obj_size_q <= ref_hostif_ombx_object_size_o;
    end
  end

  initial begin
    clk_i = 1'b0;
    forever #5 clk_i = ~clk_i;
  end

  int cycle_cnt;

  task automatic check_outputs(string tag);
    #1;
    if ( ({dut_hostif_ombx_object_size_update_o, dut_hostif_ombx_object_size_o, dut_ombx_read_data_o,
           dut_imbx_state_error_o, dut_imbx_pending_o, dut_imbx_irq_ready_o, dut_imbx_irq_abort_o,
           dut_imbx_status_busy_update_o, dut_imbx_status_busy_o, dut_imbx_overflow_error_set_o,
           dut_ombx_state_error_o, dut_ombx_doe_intr_ready_set_o, dut_ombx_pending_o,
           dut_ombx_status_ready_update_o, dut_ombx_status_ready_o, dut_tl_host_o, dut_intg_err_o, dut_sram_err_o} ^
          {dut_hostif_ombx_object_size_update_o, dut_hostif_ombx_object_size_o, dut_ombx_read_data_o,
           dut_imbx_state_error_o, dut_imbx_pending_o, dut_imbx_irq_ready_o, dut_imbx_irq_abort_o,
           dut_imbx_status_busy_update_o, dut_imbx_status_busy_o, dut_imbx_overflow_error_set_o,
           dut_ombx_state_error_o, dut_ombx_doe_intr_ready_set_o, dut_ombx_pending_o,
           dut_ombx_status_ready_update_o, dut_ombx_status_ready_o, dut_tl_host_o, dut_intg_err_o, dut_sram_err_o}) !== '0 ) begin
      $display("FAIL [%s] cycle=%0d: X/Z on outputs", tag, cycle_cnt);
      $finish(1);
    end
    if (dut_hostif_ombx_object_size_update_o !== ref_hostif_ombx_object_size_update_o ||
        (ref_hostif_ombx_object_size_update_o && (dut_hostif_ombx_object_size_o !== ref_hostif_ombx_object_size_o))) begin
      $display("FAIL [%s] cycle=%0d: obj_size got=(upd=%b, val=%0d) exp=(upd=%b, val=%0d)",
               tag, cycle_cnt, dut_hostif_ombx_object_size_update_o, dut_hostif_ombx_object_size_o,
               ref_hostif_ombx_object_size_update_o, ref_hostif_ombx_object_size_o);
      $finish(1);
    end
    if (dut_ombx_read_data_o !== ref_ombx_read_data_o) begin
      $display("FAIL [%s] cycle=%0d: ombx_read_data_o got=0x%08x exp=0x%08x",
               tag, cycle_cnt, dut_ombx_read_data_o, ref_ombx_read_data_o);
      $finish(1);
    end
    if ({dut_imbx_state_error_o, dut_imbx_pending_o, dut_imbx_irq_ready_o, dut_imbx_irq_abort_o,
         dut_imbx_status_busy_update_o, dut_imbx_status_busy_o, dut_imbx_overflow_error_set_o} !==
        {ref_imbx_state_error_o, ref_imbx_pending_o, ref_imbx_irq_ready_o, ref_imbx_irq_abort_o,
         ref_imbx_status_busy_update_o, ref_imbx_status_busy_o, ref_imbx_overflow_error_set_o}) begin
      $display("FAIL [%s] cycle=%0d: imbx status mismatch got=%b exp=%b",
               tag, cycle_cnt,
               {dut_imbx_state_error_o, dut_imbx_pending_o, dut_imbx_irq_ready_o, dut_imbx_irq_abort_o,
                dut_imbx_status_busy_update_o, dut_imbx_status_busy_o, dut_imbx_overflow_error_set_o},
               {ref_imbx_state_error_o, ref_imbx_pending_o, ref_imbx_irq_ready_o, ref_imbx_irq_abort_o,
                ref_imbx_status_busy_update_o, ref_imbx_status_busy_o, ref_imbx_overflow_error_set_o});
      $finish(1);
    end
    if ({dut_ombx_state_error_o, dut_ombx_doe_intr_ready_set_o, dut_ombx_pending_o,
         dut_ombx_status_ready_update_o, dut_ombx_status_ready_o} !==
        {ref_ombx_state_error_o, ref_ombx_doe_intr_ready_set_o, ref_ombx_pending_o,
         ref_ombx_status_ready_update_o, ref_ombx_status_ready_o}) begin
      $display("FAIL [%s] cycle=%0d: ombx status mismatch got=%b exp=%b",
               tag, cycle_cnt,
               {dut_ombx_state_error_o, dut_ombx_doe_intr_ready_set_o, dut_ombx_pending_o,
                dut_ombx_status_ready_update_o, dut_ombx_status_ready_o},
               {ref_ombx_state_error_o, ref_ombx_doe_intr_ready_set_o, ref_ombx_pending_o,
                ref_ombx_status_ready_update_o, ref_ombx_status_ready_o});
      $finish(1);
    end
    if (dut_tl_host_o.a_valid !== ref_tl_host_o.a_valid ||
        (ref_tl_host_o.a_valid && (dut_tl_host_o !== ref_tl_host_o))) begin
      $display("FAIL [%s] cycle=%0d: tl_host_o got=(vld=%b, op=%0d, addr=0x%08x, data=0x%08x) exp=(vld=%b, op=%0d, addr=0x%08x, data=0x%08x)",
               tag, cycle_cnt,
               dut_tl_host_o.a_valid, dut_tl_host_o.a_opcode, dut_tl_host_o.a_address, dut_tl_host_o.a_data,
               ref_tl_host_o.a_valid, ref_tl_host_o.a_opcode, ref_tl_host_o.a_address, ref_tl_host_o.a_data);
      $finish(1);
    end
    if (dut_intg_err_o !== ref_intg_err_o || dut_sram_err_o !== ref_sram_err_o) begin
      $display("FAIL [%s] cycle=%0d: err got=(%b,%b) exp=(%b,%b)",
               tag, cycle_cnt, dut_intg_err_o, dut_sram_err_o, ref_intg_err_o, ref_sram_err_o);
      $finish(1);
    end
  endtask

  task automatic step_cycle(string tag);
    check_outputs(tag);
    @(posedge clk_i);
    cycle_cnt++;
  endtask

  task automatic set_tl_d_resp(
    input logic        d_valid,
    input tl_d_op_e    d_opcode,
    input logic [31:0] d_data,
    input logic        d_error
  );
    tl_d2h_t d_raw;
    d_raw          = '0;
    d_raw.d_valid  = d_valid;
    d_raw.d_opcode = d_opcode;
    d_raw.d_size   = 2'd2;
    d_raw.d_data   = d_data;
    d_raw.d_error  = d_error;
    d_raw.d_user.rsp_intg  = prim_secded_pkg::prim_secded_inv_64_57_enc(64'({d_raw.d_opcode, d_raw.d_param, d_raw.d_size, d_raw.d_error}));
    d_raw.d_user.data_intg = prim_secded_pkg::prim_secded_inv_39_32_enc(d_data);
    tl_host_i.d_valid  = d_raw.d_valid;
    tl_host_i.d_opcode = d_raw.d_opcode;
    tl_host_i.d_param  = d_raw.d_param;
    tl_host_i.d_size   = d_raw.d_size;
    tl_host_i.d_source = d_raw.d_source;
    tl_host_i.d_sink   = d_raw.d_sink;
    tl_host_i.d_data   = d_raw.d_data;
    tl_host_i.d_user   = d_raw.d_user;
    tl_host_i.d_error  = d_raw.d_error;
  endtask

  logic [31:0] prng;
  function automatic logic [31:0] next_rand();
    prng = prng ^ (prng << 13);
    prng = prng ^ (prng >> 17);
    prng = prng ^ (prng << 5);
    return prng;
  endfunction

  initial begin
    prng                         = 32'(SEED) ^ 32'hC3A5_F00D;
    if (prng == 0) prng          = 32'h1357_9BDF;
    cycle_cnt                    = 0;
    rst_ni                       = 1'b0;
    hostif_control_abort_clear_i = 1'b0;
    mbx_error_set_i              = 1'b0;
    hostif_range_valid_write_i   = 1'b0;
    hostif_range_valid_i         = 1'b0;
    hostif_imbx_base_i           = 32'h2000_1000;
    hostif_imbx_limit_i          = 32'h2000_1010;
    hostif_ombx_base_i           = 32'h2000_2000;
    hostif_ombx_limit_i          = 32'h2000_2010;
    sysif_status_busy_i          = 1'b0;
    sysif_status_ready_i         = 1'b0;
    sysif_control_go_set_i       = 1'b0;
    sysif_control_abort_set_i    = 1'b0;
    sysif_data_write_valid_i     = 1'b0;
    imbx_write_data_i            = 32'h0;
    sysif_read_data_read_valid_i = 1'b0;
    sysif_read_data_write_valid_i= 1'b0;
    tb_obj_size_sw_wr            = 1'b0;
    tb_obj_size_sw_val           = '0;
    tl_host_i                    = '0;
    tl_host_i.a_ready            = 1'b1;

    repeat (4) @(posedge clk_i);
    rst_ni = 1'b1;
    step_cycle("post_reset");

    // Configure valid SRAM ranges
    hostif_range_valid_write_i = 1'b1;
    hostif_range_valid_i       = 1'b1;
    step_cycle("cfg_range_valid");
    hostif_range_valid_write_i = 1'b0;
    step_cycle("post_cfg_range");

    // -----------------------------------------------------------------------
    // Directed Test 1: Immediate grant on initial word write of Inbound Mailbox
    // (tl_host_i.a_ready = 1, ombx idle -> imbx_sram_write_gnt = 1 on cycle 0 of write!)
    // Verifies that sram_write_ptr_q advances to base + 4 instead of staying at base!
    // -----------------------------------------------------------------------
    tl_host_i.a_ready        = 1'b1;
    sysif_data_write_valid_i = 1'b1;
    imbx_write_data_i        = 32'h1111_0001;
    step_cycle("dir1_imbx_w0_imm_gnt");
    sysif_data_write_valid_i = 1'b0;
    // Return AccessAck
    set_tl_d_resp(1'b1, AccessAck, 32'h0, 1'b0);
    step_cycle("dir1_imbx_w0_ack");
    set_tl_d_resp(1'b0, AccessAck, 32'h0, 1'b0);

    // Write 2nd word with 1-cycle stall on a_ready, then grant!
    // If word 0 failed to advance sram_write_ptr_q to base + 4, this 2nd word will drive address = base instead of base + 4!
    tl_host_i.a_ready        = 1'b0;
    sysif_data_write_valid_i = 1'b1;
    imbx_write_data_i        = 32'h2222_0002;
    step_cycle("dir1_imbx_w1_stall");
    sysif_data_write_valid_i = 1'b0;
    tl_host_i.a_ready        = 1'b1;
    step_cycle("dir1_imbx_w1_gnt");
    set_tl_d_resp(1'b1, AccessAck, 32'h0, 1'b0);
    step_cycle("dir1_imbx_w1_ack");
    set_tl_d_resp(1'b0, AccessAck, 32'h0, 1'b0);

    // Close Inbound Mailbox (go_set = 1)
    sysif_control_go_set_i = 1'b1;
    step_cycle("dir1_imbx_go");
    sysif_control_go_set_i = 1'b0;
    step_cycle("dir1_imbx_in_read");

    // -----------------------------------------------------------------------
    // Directed Test 2: Outbound Mailbox 3-word object transfer + Abort Clear
    // + Late stale AccessAckData response when outstanding_req_count_q == 0!
    // -----------------------------------------------------------------------
    tb_obj_size_sw_wr  = 1'b1;
    tb_obj_size_sw_val = 11'd3;
    step_cycle("dir2_ombx_write_objsz");
    tb_obj_size_sw_wr  = 1'b0;
    // Next cycle: host_write_object_size_q=1 -> set_first_req=1!
    step_cycle("dir2_ombx_first_req");
    // Next cycle: first_req_q=1, granted onto TL-UL bus!
    step_cycle("dir2_ombx_first_gnt");
    // Return 1st read response
    set_tl_d_resp(1'b1, AccessAckData, 32'hAAAA_0001, 1'b0);
    step_cycle("dir2_ombx_first_resp");
    set_tl_d_resp(1'b0, AccessAckData, 32'h0, 1'b0);
    step_cycle("dir2_ombx_ready");

    // Now simulate an Abort from SoC followed by Host Abort Ack while an in-flight read was issued!
    sysif_read_data_write_valid_i = 1'b1;
    step_cycle("dir2_ombx_next_read_req");
    sysif_read_data_write_valid_i = 1'b0;
    // Assert abort_set then hostif_control_abort_clear_i BEFORE the SRAM read response arrives!
    sysif_control_abort_set_i = 1'b1;
    step_cycle("dir2_abort_set");
    sysif_control_abort_set_i    = 1'b0;
    hostif_control_abort_clear_i = 1'b1;
    step_cycle("dir2_abort_clear");
    hostif_control_abort_clear_i = 1'b0;
    step_cycle("dir2_post_abort_clear");

    // Now a late/stale AccessAckData arrives on tl_host_i when outstanding_req_count_q == 0!
    // It MUST be suppressed (ombx_read_data_o must stay 0 and mbx_ombx must NOT transition to MbxRead!)
    set_tl_d_resp(1'b1, AccessAckData, 32'hDEAD_BEEF, 1'b0);
    step_cycle("dir2_stale_resp_after_abort");
    set_tl_d_resp(1'b0, AccessAckData, 32'h0, 1'b0);
    step_cycle("dir2_post_stale_resp");

    // -----------------------------------------------------------------------
    // Directed Test 3: Complete 2-word Outbound Mailbox transfer to completion (sys_read_all)
    // -----------------------------------------------------------------------
    tb_obj_size_sw_wr  = 1'b1;
    tb_obj_size_sw_val = 11'd2;
    step_cycle("dir3_write_objsz_2");
    tb_obj_size_sw_wr  = 1'b0;
    step_cycle("dir3_set_first");
    step_cycle("dir3_gnt_w0");
    set_tl_d_resp(1'b1, AccessAckData, 32'hCAFE_0001, 1'b0);
    step_cycle("dir3_resp_w0");
    set_tl_d_resp(1'b0, AccessAckData, 32'h0, 1'b0);
    step_cycle("dir3_in_mbx_read");

    // System acknowledges word 0 -> triggers read of word 1
    sysif_read_data_write_valid_i = 1'b1;
    step_cycle("dir3_ack_w0_req_w1");
    sysif_read_data_write_valid_i = 1'b0;
    set_tl_d_resp(1'b1, AccessAckData, 32'hCAFE_0002, 1'b0);
    step_cycle("dir3_resp_w1");
    set_tl_d_resp(1'b0, AccessAckData, 32'h0, 1'b0);
    step_cycle("dir3_hold_w1");

    // System acknowledges word 1 (last word!) -> triggers sys_read_all_o = 1!
    sysif_read_data_write_valid_i = 1'b1;
    step_cycle("dir3_ack_w1_sys_read_all");
    sysif_read_data_write_valid_i = 1'b0;
    step_cycle("dir3_back_to_idle");

    // -----------------------------------------------------------------------
    // Randomized Multi-Transaction Stress Test (concurrent IMBX writes, OMBX reads,
    // backpressure on tl_host_i.a_ready, overflow limit checks, errors, and aborts)
    // -----------------------------------------------------------------------
    for (int iter = 0; iter < 30; iter++) begin
      logic [31:0] r;
      int          w_words, r_words;
      r       = next_rand();
      w_words = 1 + (r[1:0]); // 1..4 words
      r_words = 1 + (r[3:2]); // 1..4 words

      hostif_imbx_base_i  = 32'h2000_1000 + {24'h0, r[7:4], 4'h0};
      hostif_imbx_limit_i = hostif_imbx_base_i + 32'((w_words - 1) * 4);
      hostif_ombx_base_i  = 32'h2000_2000 + {24'h0, r[11:8], 4'h0};
      hostif_ombx_limit_i = hostif_ombx_base_i + 32'(r_words * 4);

      hostif_range_valid_write_i = 1'b1;
      hostif_range_valid_i       = 1'b1;
      step_cycle("rand_cfg_range");
      hostif_range_valid_write_i = 1'b0;

      // Start OMBX transfer
      tb_obj_size_sw_wr  = 1'b1;
      tb_obj_size_sw_val = CfgObjectSizeWidth'(r_words);
      step_cycle("rand_start_ombx");
      tb_obj_size_sw_wr  = 1'b0;

      for (int cyc = 0; cyc < 50; cyc++) begin
        logic [31:0] rc;
        rc                = next_rand();
        tl_host_i.a_ready = rc[0];

        // Drive IMBX write if idle or writing and not pending
        if (!ref_imbx_pending_o && (ref_imbx_empty || ref_imbx_write) && rc[2:1] == 2'b01) begin
          sysif_data_write_valid_i = 1'b1;
          imbx_write_data_i        = rc;
        end else begin
          sysif_data_write_valid_i = 1'b0;
        end

        // Drive IMBX go if in write state and all words written
        if (ref_imbx_write && !ref_imbx_pending_o && (rc[5:3] == 3'b111)) begin
          sysif_control_go_set_i = 1'b1;
        end else begin
          sysif_control_go_set_i = 1'b0;
        end

        // Drive OMBX read ack if in read state and not pending
        if (ref_ombx_read && !ref_ombx_pending_o && rc[6]) begin
          sysif_read_data_write_valid_i = 1'b1;
        end else begin
          sysif_read_data_write_valid_i = 1'b0;
        end

        // Return TL-UL D-channel responses when requests are outstanding
        if (ref_out_cnt_q != 0 && rc[7]) begin
          // Decide whether to return AccessAckData or AccessAck
          if (ref_ombx_pending_o || ref_ombx_empty) begin
            set_tl_d_resp(1'b1, AccessAckData, rc ^ 32'h55AA_55AA, 1'b0);
          end else begin
            set_tl_d_resp(1'b1, AccessAck, 32'h0, 1'b0);
          end
        end else begin
          set_tl_d_resp(1'b0, AccessAck, 32'h0, 1'b0);
        end

        step_cycle("rand_step");
        sysif_data_write_valid_i      = 1'b0;
        sysif_control_go_set_i        = 1'b0;
        sysif_read_data_write_valid_i = 1'b0;
        set_tl_d_resp(1'b0, AccessAck, 32'h0, 1'b0);
      end

      // Clean up iteration via abort + abort_clear
      tl_host_i.a_ready         = 1'b1;
      sysif_control_abort_set_i = 1'b1;
      step_cycle("rand_abort_set");
      sysif_control_abort_set_i    = 1'b0;
      hostif_control_abort_clear_i = 1'b1;
      step_cycle("rand_abort_clr");
      hostif_control_abort_clear_i = 1'b0;
      step_cycle("rand_post_abort_clr");
    end

    $display("PASS ot_mbx_top seed=%0d cycles=%0d", SEED, cycle_cnt);
    $finish(0);
  end

endmodule
