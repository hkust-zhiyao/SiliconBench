// Copyright 2024 OpenHW Group
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module id_decode_top import ariane_pkg::*; (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic [31:0] fe_addr_i,
  input  logic [31:0] fe_instr_i,
  input  logic        fe_bp_valid_i,
  input  logic [31:0] fe_bp_addr_i,
  input  logic [ 2:0] fe_bp_cf_i,
  input  logic        fe_ex_valid_i,
  input  logic [31:0] fe_ex_cause_i,
  input  logic        fe_valid_i,
  output logic        fe_ready_o,
  input  logic        issue_ack_i,
  output logic        issue_valid_o,
  output logic [31:0] issue_pc_o,
  output logic [ 3:0] issue_fu_o,
  output logic [ 7:0] issue_op_o,
  output logic [ 4:0] issue_rs1_o,
  output logic [ 4:0] issue_rs2_o,
  output logic [ 4:0] issue_rd_o,
  output logic [31:0] issue_result_o,
  output logic        issue_ex_valid_o,
  output logic        issue_is_comp_o,
  output logic        issue_is_macro_o,
  output logic        issue_is_last_macro_o,
  output logic        issue_is_double_rd_o,
  output logic        issue_is_zcmt_o,
  output logic        is_ctrl_flow_o,
  input  logic [25:0] jvt_base_i,
  input  logic [ 5:0] jvt_mode_i,
  input  logic        dcache_gnt_i,
  input  logic        dcache_rvalid_i,
  input  logic [31:0] dcache_rdata_i,
  output logic        dcache_req_o,
  output logic [ 9:0] dcache_idx_o,
  output logic [21:0] dcache_tag_o,
  output logic        dcache_kill_o
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 32;
    c.IS_XLEN32 = 1;
    c.IS_XLEN64 = 0;
    c.VLEN = 32;
    c.PLEN = 34;
    c.GPLEN = 34;
    c.NrIssuePorts = 1;
    c.RVC = 1;
    c.RVB = 1;
    c.RVZCB = 1;
    c.RVZCMP = 1;
    c.RVZCMT = 1;
    c.RVZiCond = 1;
    c.TvalEn = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();

  typedef struct packed {
    logic [31:0] S_SW;
    logic [31:0] VS_SW;
    logic [31:0] M_SW;
    logic [31:0] S_TIMER;
    logic [31:0] VS_TIMER;
    logic [31:0] M_TIMER;
    logic [31:0] S_EXT;
    logic [31:0] VS_EXT;
    logic [31:0] M_EXT;
    logic [31:0] HS_EXT;
  } interrupts_s_t;
  localparam interrupts_s_t INTS = '0;

  typedef struct packed {
    logic [31:0] cause;
    logic [31:0] tval;
    logic [33:0] tval2;
    logic [31:0] tinst;
    logic        gva;
    logic        valid;
    logic        timing;
  } ex_s_t;

  typedef struct packed {
    logic            valid;
    logic [31:0]     predict_address;
    ariane_pkg::cf_t cf;
  } bp_s_t;

  typedef struct packed {
    logic [31:0] address;
    logic [31:0] instruction;
    bp_s_t       branch_predict;
    ex_s_t       ex;
  } fetch_entry_s_t;

  typedef struct packed {
    logic [25:0] base;
    logic [ 5:0] mode;
  } jvt_s_t;

  typedef struct packed {
    logic [31:0] mie;
    logic [31:0] mip;
    logic [31:0] mideleg;
    logic [31:0] hideleg;
    logic        sie;
    logic        global_enable;
  } irq_ctrl_s_t;

  typedef struct packed {
    logic [31:0]      pc;
    logic [ 1:0]      trans_id;
    ariane_pkg::fu_t  fu;
    ariane_pkg::fu_op op;
    logic [ 4:0]      rs1;
    logic [ 4:0]      rs2;
    logic [ 4:0]      rd;
    logic [31:0]      result;
    logic             valid;
    logic             use_imm;
    logic             use_zimm;
    logic             use_pc;
    ex_s_t            ex;
    bp_s_t            bp;
    logic             is_compressed;
    logic             is_macro_instr;
    logic             is_last_macro_instr;
    logic             is_double_rd_macro_instr;
    logic             vfp;
    logic             is_zcmt;
  } sbe_s_t;

  typedef struct packed {
    logic [ 9:0] address_index;
    logic [21:0] address_tag;
    logic [31:0] data_wdata;
    logic        data_wuser;
    logic        data_req;
    logic        data_we;
    logic [ 3:0] data_be;
    logic [ 1:0] data_size;
    logic        data_id;
    logic        kill_req;
    logic        tag_valid;
    logic [ 7:0] cbo_op;
  } dcache_req_i_t;

  typedef struct packed {
    logic        data_gnt;
    logic        data_rvalid;
    logic        data_rid;
    logic [31:0] data_rdata;
    logic        data_error;
    logic        data_ruser;
  } dcache_req_o_t;

  fetch_entry_s_t [0:0] fe_i;
  logic [0:0]           fe_vld_i, fe_rdy_o, iss_vld_o, iss_ack_i, is_cf_o;
  sbe_s_t [0:0]         iss_o, iss_prev_o;
  logic [0:0][31:0]     orig_o;
  jvt_s_t               jvt_s;
  dcache_req_o_t        dc_i;
  dcache_req_i_t        dc_o;
  logic [31:0]          sdtrig_act [1];
  assign sdtrig_act[0] = '0;

  assign fe_i[0] = '{
    address:        fe_addr_i,
    instruction:    fe_instr_i,
    branch_predict: '{valid: fe_bp_valid_i, predict_address: fe_bp_addr_i, cf: ariane_pkg::cf_t'(fe_bp_cf_i)},
    ex:             '{cause: fe_ex_cause_i, tval: '0, tval2: '0, tinst: '0, gva: 1'b0, valid: fe_ex_valid_i, timing: 1'b0}
  };
  assign fe_vld_i[0]  = fe_valid_i;
  assign fe_ready_o   = fe_rdy_o[0];
  assign iss_ack_i[0] = issue_ack_i;
  assign jvt_s        = '{base: jvt_base_i, mode: jvt_mode_i};
  assign dc_i         = '{
    data_gnt:    dcache_gnt_i,
    data_rvalid: dcache_rvalid_i,
    data_rid:    1'b1,
    data_rdata:  dcache_rdata_i,
    data_error:  1'b0,
    data_ruser:  1'b0
  };

  id_stage #(
    .CVA6Cfg             (Cfg),
    .branchpredict_sbe_t (bp_s_t),
    .dcache_req_i_t      (dcache_req_i_t),
    .dcache_req_o_t      (dcache_req_o_t),
    .exception_t         (ex_s_t),
    .fetch_entry_t       (fetch_entry_s_t),
    .jvt_t               (jvt_s_t),
    .irq_ctrl_t          (irq_ctrl_s_t),
    .scoreboard_entry_t  (sbe_s_t),
    .interrupts_t        (interrupts_s_t),
    .INTERRUPTS          (INTS),
    .x_compressed_req_t  (logic),
    .x_compressed_resp_t (logic)
  ) u_id (
    .clk_i                   (clk_i),
    .rst_ni                  (rst_ni),
    .flush_i                 (flush_i),
    .debug_req_i             (1'b0),
    .fetch_entry_i           (fe_i),
    .fetch_entry_valid_i     (fe_vld_i),
    .fetch_entry_ready_o     (fe_rdy_o),
    .issue_entry_o           (iss_o),
    .issue_entry_o_prev      (iss_prev_o),
    .orig_instr_o            (orig_o),
    .issue_entry_valid_o     (iss_vld_o),
    .is_ctrl_flow_o          (is_cf_o),
    .issue_instr_ack_i       (iss_ack_i),
    .rvfi_is_compressed_o    (),
    .priv_lvl_i              (riscv::PRIV_LVL_M),
    .v_i                     (1'b0),
    .fs_i                    (riscv::Off),
    .vfs_i                   (riscv::Off),
    .frm_i                   (3'b0),
    .vs_i                    (riscv::Off),
    .irq_i                   (2'b0),
    .irq_ctrl_i              ('0),
    .debug_mode_i            (1'b0),
    .tvm_i                   (1'b0),
    .tw_i                    (1'b0),
    .vtw_i                   (1'b0),
    .tsr_i                   (1'b0),
    .hu_i                    (1'b0),
    .mcbie_i                 (riscv::CBIE_ILLEGAL),
    .scbie_i                 (riscv::CBIE_ILLEGAL),
    .hcbie_i                 (riscv::CBIE_ILLEGAL),
    .mcbcfe_i                (1'b0),
    .scbcfe_i                (1'b0),
    .hcbcfe_i                (1'b0),
    .hart_id_i               ('0),
    .compressed_ready_i      (1'b0),
    .jvt_i                   (jvt_s),
    .compressed_resp_i       (1'b0),
    .compressed_valid_o      (),
    .compressed_req_o        (),
    .sdtrig_decoder_action_i (sdtrig_act),
    .dcache_req_ports_i      (dc_i),
    .dcache_req_ports_o      (dc_o)
  );

  assign issue_valid_o         = iss_vld_o[0];
  assign issue_pc_o            = iss_o[0].pc;
  assign issue_fu_o            = iss_o[0].fu;
  assign issue_op_o            = iss_o[0].op;
  assign issue_rs1_o           = iss_o[0].rs1;
  assign issue_rs2_o           = iss_o[0].rs2;
  assign issue_rd_o            = iss_o[0].rd;
  assign issue_result_o        = iss_o[0].result;
  assign issue_ex_valid_o      = iss_o[0].ex.valid;
  assign issue_is_comp_o       = iss_o[0].is_compressed;
  assign issue_is_macro_o      = iss_o[0].is_macro_instr;
  assign issue_is_last_macro_o = iss_o[0].is_last_macro_instr;
  assign issue_is_double_rd_o  = iss_o[0].is_double_rd_macro_instr;
  assign issue_is_zcmt_o       = iss_o[0].is_zcmt;
  assign is_ctrl_flow_o        = is_cf_o[0];
  assign dcache_req_o          = dc_o.data_req;
  assign dcache_idx_o          = dc_o.address_index;
  assign dcache_tag_o          = dc_o.address_tag;
  assign dcache_kill_o         = dc_o.kill_req;
endmodule
