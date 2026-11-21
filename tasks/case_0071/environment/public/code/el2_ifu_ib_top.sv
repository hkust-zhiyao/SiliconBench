// SPDX-License-Identifier: Apache-2.0
module el2_ifu_ib_top
import el2_pkg::*;
#(
`include "el2_param.vh"
)
(
   input  logic                                   clk,
   input  logic                                   rst_l,
   input  logic                                   scan_mode,

   input  logic                                   ic_hit_f,
   input  logic                                   ifu_ic_mb_empty,
   input  logic                                   dec_tlu_flush_noredir_wb,
   input  logic                                   exu_flush_final,
   input  logic [31:1]                            exu_flush_path_final,
   input  logic                                   ifu_bp_hit_taken_f,
   input  logic [31:1]                            ifu_bp_btb_target_f,
   input  logic                                   ic_dma_active,
   input  logic                                   ic_write_stall,
   input  logic                                   dma_iccm_stall_any,
   input  logic [31:0]                            dec_tlu_mrac_ff,

   input  logic                                   ifu_async_error_start,
   input  logic [1:0]                             iccm_rd_ecc_double_err,
   input  logic [1:0]                             ic_access_fault_f,
   input  logic [1:0]                             ic_access_fault_type_f,
   input  logic                                   dec_i0_decode_d,
   input  logic [31:0]                            ifu_fetch_data_f,
   input  logic [1:0]                             ic_fetch_val_f,

   input  logic [pt.BHT_GHR_SIZE-1:0]             ifu_bp_fghr_f,
   input  logic [11:0]                            ifu_bp_poffset_f,
   input  logic [1:0][$clog2(pt.BTB_SIZE)-1:0]    ifu_bp_fa_index_f,
   input  logic [1:0]                             ifu_bp_hist0_f,
   input  logic [1:0]                             ifu_bp_hist1_f,
   input  logic [1:0]                             ifu_bp_pc4_f,
   input  logic [1:0]                             ifu_bp_way_f,
   input  logic [1:0]                             ifu_bp_valid_f,
   input  logic [1:0]                             ifu_bp_ret_f,

   input  logic                                   dbg_cmd_valid,
   input  logic                                   dbg_cmd_write,
   input  logic [1:0]                             dbg_cmd_type,
   input  logic [31:0]                            dbg_cmd_addr,

   output logic [31:1]                            ifc_fetch_addr_f,
   output logic [31:1]                            ifc_fetch_addr_bf,
   output logic                                   ifc_fetch_req_f,
   output logic                                   ifu_pmu_fetch_stall,
   output logic                                   ifc_fetch_uncacheable_bf,
   output logic                                   ifc_fetch_req_bf,
   output logic                                   ifc_fetch_req_bf_raw,
   output logic                                   ifc_iccm_access_bf,
   output logic                                   ifc_region_acc_fault_bf,
   output logic                                   ifc_dma_access_ok,

   output logic                                   ifu_fb_consume1,
   output logic                                   ifu_fb_consume2,
   output logic                                   ifu_i0_valid,
   output logic                                   ifu_pmu_instr_aligned,
   output logic [15:0]                            ifu_i0_cinst,

   output logic                                   dec_ib0_valid_d,
   output logic                                   dec_debug_valid_d,
   output logic [31:0]                            dec_i0_instr_d,
   output logic [31:1]                            dec_i0_pc_d,
   output logic                                   dec_i0_pc4_d,
   output el2_br_pkt_t                            dec_i0_brp,
   output logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   dec_i0_bp_index,
   output logic [pt.BHT_GHR_SIZE-1:0]             dec_i0_bp_fghr,
   output logic [pt.BTB_BTAG_SIZE-1:0]            dec_i0_bp_btag,
   output logic [$clog2(pt.BTB_SIZE)-1:0]         dec_i0_bp_fa_index,
   output logic                                   dec_i0_icaf_d,
   output logic                                   dec_i0_icaf_second_d,
   output logic [1:0]                             dec_i0_icaf_type_d,
   output logic                                   dec_i0_dbecc_d,
   output logic                                   dec_debug_wdata_rs1_d,
   output logic                                   dec_debug_fence_d
);

   logic free_l2clk;
   logic active_clk;
   assign free_l2clk = clk;
   assign active_clk = clk;

   logic [1:0]  ifu_fetch_val;
   logic [31:1] ifu_fetch_pc;
   assign ifu_fetch_val = {2{ifc_fetch_req_f & ic_hit_f}} & ic_fetch_val_f;
   assign ifu_fetch_pc  = ifc_fetch_addr_f;

   logic                                   ifu_i0_icaf;
   logic [1:0]                             ifu_i0_icaf_type;
   logic                                   ifu_i0_icaf_second;
   logic                                   ifu_i0_dbecc;
   logic [31:0]                            ifu_i0_instr;
   logic [31:1]                            ifu_i0_pc;
   logic                                   ifu_i0_pc4;
   el2_br_pkt_t                            i0_brp;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   ifu_i0_bp_index;
   logic [pt.BHT_GHR_SIZE-1:0]             ifu_i0_bp_fghr;
   logic [pt.BTB_BTAG_SIZE-1:0]            ifu_i0_bp_btag;
   logic [$clog2(pt.BTB_SIZE)-1:0]         ifu_i0_fa_index;

   el2_ifu_ifc_ctl #(.pt(pt)) u_ifc (.*);
   el2_ifu_aln_ctl #(.pt(pt)) u_aln (.*);
   el2_dec_ib_ctl  #(.pt(pt)) u_ib  (.*);

endmodule
