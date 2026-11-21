// Copyright 2025 OpenHW Group
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module lsu_subsys_top import ariane_pkg::*; (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        stall_st_pending_i,
  output logic        no_st_pending_o,
  input  logic [ 3:0] fu_i,
  input  logic [ 7:0] op_i,
  input  logic [31:0] opa_i,
  input  logic [31:0] opb_i,
  input  logic [31:0] imm_i,
  input  logic [ 1:0] tid_i,
  input  logic        lsu_valid_i,
  input  logic        spec_load_i,
  output logic        lsu_ready_o,
  output logic [ 1:0] load_trans_id_o,
  output logic [31:0] load_result_o,
  output logic        load_valid_o,
  output logic        load_ex_valid_o,
  output logic [31:0] load_ex_cause_o,
  output logic [ 1:0] store_trans_id_o,
  output logic [31:0] store_result_o,
  output logic        store_valid_o,
  output logic        store_ex_valid_o,
  output logic [31:0] store_ex_cause_o,
  input  logic        commit_i,
  output logic        commit_ready_o,
  input  logic [ 1:0] commit_tran_id_i,
  input  logic        br_res_valid_i,
  input  logic        br_res_mispredict_i,
  input  logic        mbe_i,
  input  logic        ld_gnt_i,
  input  logic        ld_rvalid_i,
  input  logic [ 1:0] ld_rid_i,
  input  logic [31:0] ld_rdata_i,
  input  logic        ld_err_i,
  output logic        ld_req_o,
  output logic [ 9:0] ld_idx_o,
  output logic [21:0] ld_tag_o,
  output logic [ 3:0] ld_be_o,
  output logic [ 1:0] ld_size_o,
  output logic [ 1:0] ld_id_o,
  output logic        ld_kill_o,
  output logic        ld_tag_vld_o,
  input  logic        st_gnt_i,
  input  logic        st_rvalid_i,
  output logic        st_req_o,
  output logic [ 9:0] st_idx_o,
  output logic [21:0] st_tag_o,
  output logic [31:0] st_wdata_o,
  output logic [ 3:0] st_be_o,
  output logic [ 1:0] st_size_o,
  output logic [ 7:0] st_cbo_o,
  input  logic        dcache_wbuffer_empty_i,
  input  logic        dcache_wbuffer_not_ni_i
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 32;
    c.IS_XLEN32 = 1;
    c.IS_XLEN64 = 0;
    c.XLEN_ALIGN_BYTES = 2;
    c.VLEN = 32;
    c.PLEN = 32;
    c.GPLEN = 32;
    c.PPNW = 20;
    c.TRANS_ID_BITS = 2;
    c.NrLoadBufEntries = 2;
    c.DcacheIdWidth = 2;
    c.DCACHE_INDEX_WIDTH = 10;
    c.DCACHE_TAG_WIDTH = 22;
    c.NrLoadPipeRegs = 0;
    c.NrStorePipeRegs = 0;
    c.RVA = 0;
    c.RVZiCbom = 1;
    c.SpeculativeSb = 1;
    c.NonIdemPotenceEn = 1;
    c.NrNonIdempotentRules = 1;
    c.NonIdempotentAddrBase[0] = 64'h1000_0000;
    c.NonIdempotentLength[0]   = 64'h1000_0000;
    c.TvalEn = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();

  typedef struct packed {
    fu_t         fu;
    fu_op        operation;
    logic [31:0] operand_a;
    logic [31:0] operand_b;
    logic [31:0] imm;
    logic [ 1:0] trans_id;
  } fu_data_s_t;

  typedef struct packed {
    logic [31:0] cause;
    logic [31:0] tval;
    logic [31:0] tval2;
    logic [31:0] tinst;
    logic        gva;
    logic        valid;
    logic        timing;
  } ex_s_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] vaddr;
    logic [31:0] tinst;
    logic        hs_ld_st_inst;
    logic        hlvx_inst;
    logic        overflow;
    logic        g_overflow;
    logic [31:0] data;
    logic [ 3:0] be;
    fu_t         fu;
    fu_op        operation;
    logic [ 1:0] trans_id;
    logic        is_speculative_load;
    logic        is_speculative_load_miss;
  } lsu_ctrl_s_t;

  typedef struct packed {
    logic            valid;
    logic [31:0]     pc;
    logic [31:0]     target_address;
    logic            is_mispredict;
    logic            is_taken;
    ariane_pkg::cf_t cf_type;
  } bp_resolve_s_t;

  typedef struct packed {
    logic        fetch_valid;
    logic [31:0] fetch_paddr;
    ex_s_t       fetch_exception;
  } icache_areq_s_t;

  typedef struct packed {
    logic        fetch_req;
    logic [31:0] fetch_vaddr;
  } icache_arsp_s_t;

  typedef struct packed {
    logic [ 9:0] address_index;
    logic [21:0] address_tag;
    logic [31:0] data_wdata;
    logic        data_wuser;
    logic        data_req;
    logic        data_we;
    logic [ 3:0] data_be;
    logic [ 1:0] data_size;
    logic [ 1:0] data_id;
    logic        kill_req;
    logic        tag_valid;
    logic [ 7:0] cbo_op;
  } dcache_req_i_t;

  typedef struct packed {
    logic        data_gnt;
    logic        data_rvalid;
    logic [ 1:0] data_rid;
    logic [31:0] data_rdata;
    logic        data_error;
    logic        data_ruser;
  } dcache_req_o_t;

  fu_data_s_t         fu_data_s;
  bp_resolve_s_t      bp_res_s;
  ex_s_t              ld_ex_s, st_ex_s;
  dcache_req_o_t [2:0] dc_i;
  dcache_req_i_t [2:0] dc_o;

  assign fu_data_s = '{fu: fu_t'(fu_i), operation: fu_op'(op_i), operand_a: opa_i, operand_b: opb_i, imm: imm_i, trans_id: tid_i};
  assign bp_res_s  = '{valid: br_res_valid_i, pc: '0, target_address: '0, is_mispredict: br_res_mispredict_i, is_taken: 1'b0, cf_type: ariane_pkg::NoCF};

  assign dc_i[0] = '0;
  assign dc_i[1] = '{data_gnt: ld_gnt_i, data_rvalid: ld_rvalid_i, data_rid: ld_rid_i, data_rdata: ld_rdata_i, data_error: ld_err_i, data_ruser: 1'b0};
  assign dc_i[2] = '{data_gnt: st_gnt_i, data_rvalid: st_rvalid_i, data_rid: '0, data_rdata: '0, data_error: 1'b0, data_ruser: 1'b0};

  load_store_unit #(
    .CVA6Cfg       (Cfg),
    .dcache_req_i_t(dcache_req_i_t),
    .dcache_req_o_t(dcache_req_o_t),
    .exception_t   (ex_s_t),
    .fu_data_t     (fu_data_s_t),
    .icache_areq_t (icache_areq_s_t),
    .icache_arsp_t (icache_arsp_s_t),
    .icache_dreq_t (logic),
    .icache_drsp_t (logic),
    .lsu_ctrl_t    (lsu_ctrl_s_t),
    .acc_mmu_req_t (logic),
    .acc_mmu_resp_t(logic),
    .cbo_t         (logic [7:0]),
    .bp_resolve_t  (bp_resolve_s_t)
  ) u_lsu (
    .clk_i                  (clk_i),
    .rst_ni                 (rst_ni),
    .flush_i                (flush_i),
    .stall_st_pending_i     (stall_st_pending_i),
    .no_st_pending_o        (no_st_pending_o),
    .shared_tlb_flush_busy_o(),
    .amo_valid_commit_i     (1'b0),
    .tinst_i                ('0),
    .fu_data_i              (fu_data_s),
    .lsu_ready_o            (lsu_ready_o),
    .lsu_valid_i            (lsu_valid_i),
    .speculative_load_i     (spec_load_i),
    .load_trans_id_o        (load_trans_id_o),
    .load_result_o          (load_result_o),
    .load_valid_o           (load_valid_o),
    .load_exception_o       (ld_ex_s),
    .store_trans_id_o       (store_trans_id_o),
    .store_result_o         (store_result_o),
    .store_valid_o          (store_valid_o),
    .store_exception_o      (st_ex_s),
    .commit_i               (commit_i),
    .commit_ready_o         (commit_ready_o),
    .commit_tran_id_i       (commit_tran_id_i),
    .resolved_branch_i      (bp_res_s),
    .enable_translation_i   (1'b0),
    .enable_g_translation_i (1'b0),
    .en_ld_st_translation_i (1'b0),
    .en_ld_st_g_translation_i(1'b0),
    .acc_mmu_req_i          (1'b0),
    .acc_mmu_resp_o         (),
    .icache_areq_i          ('0),
    .icache_areq_o          (),
    .priv_lvl_i             (riscv::PRIV_LVL_M),
    .mbe_i                  (mbe_i),
    .v_i                    (1'b0),
    .ld_st_priv_lvl_i       (riscv::PRIV_LVL_M),
    .ld_st_v_i              (1'b0),
    .csr_hs_ld_st_inst_o    (),
    .sum_i                  (1'b0),
    .vs_sum_i               (1'b0),
    .mxr_i                  (1'b0),
    .vmxr_i                 (1'b0),
    .satp_ppn_i             ('0),
    .asid_i                 ('0),
    .vsatp_ppn_i            ('0),
    .vs_asid_i              ('0),
    .hgatp_ppn_i            ('0),
    .vmid_i                 ('0),
    .asid_to_be_flushed_i   ('0),
    .vmid_to_be_flushed_i   ('0),
    .vaddr_to_be_flushed_i  ('0),
    .gpaddr_to_be_flushed_i ('0),
    .flush_tlb_i            (1'b0),
    .flush_tlb_vvma_i       (1'b0),
    .flush_tlb_gvma_i       (1'b0),
    .itlb_miss_o            (),
    .dtlb_miss_o            (),
    .dcache_req_ports_i     (dc_i),
    .dcache_req_ports_o     (dc_o),
    .dcache_wbuffer_empty_i (dcache_wbuffer_empty_i),
    .dcache_wbuffer_not_ni_i(dcache_wbuffer_not_ni_i),
    .amo_req_o              (),
    .amo_resp_i             ('0),
    .pmpcfg_i               ('0),
    .pmpaddr_i              ('0),
    .rvfi_lsu_ctrl_o        (),
    .rvfi_mem_paddr_o       (),
    .sdtrig_load_stall_i    (1'b0),
    .sdtrig_load_cancel_i   (1'b0),
    .sdtrig_load_action_i   ('0),
    .sdtrig_store_stall_i   (1'b0),
    .sdtrig_store_action_i  ('0)
  );

  assign load_ex_valid_o  = ld_ex_s.valid;
  assign load_ex_cause_o  = ld_ex_s.cause;
  assign store_ex_valid_o = st_ex_s.valid;
  assign store_ex_cause_o = st_ex_s.cause;

  assign ld_req_o     = dc_o[1].data_req;
  assign ld_idx_o     = dc_o[1].address_index;
  assign ld_tag_o     = dc_o[1].address_tag;
  assign ld_be_o      = dc_o[1].data_be;
  assign ld_size_o    = dc_o[1].data_size;
  assign ld_id_o      = dc_o[1].data_id;
  assign ld_kill_o    = dc_o[1].kill_req;
  assign ld_tag_vld_o = dc_o[1].tag_valid;

  assign st_req_o     = dc_o[2].data_req;
  assign st_idx_o     = dc_o[2].address_index;
  assign st_tag_o     = dc_o[2].address_tag;
  assign st_wdata_o   = dc_o[2].data_wdata;
  assign st_be_o      = dc_o[2].data_be;
  assign st_size_o    = dc_o[2].data_size;
  assign st_cbo_o     = dc_o[2].cbo_op;
endmodule
