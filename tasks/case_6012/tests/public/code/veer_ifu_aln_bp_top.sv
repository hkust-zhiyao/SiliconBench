// SPDX-License-Identifier: Apache-2.0
module veer_ifu_aln_bp_top
   import veer_types::*;
(
   input  logic                                 clk,
   input  logic                                 rst_l,
   input  logic                                 scan_mode,
   input  logic                                 clk_override,

   // Decode I-Buffer occupancy & flush control
   input  logic                                 dec_ib3_valid_d,
   input  logic                                 dec_ib2_valid_d,
   input  logic                                 dec_ib0_valid_eff_d,
   input  logic                                 dec_ib1_valid_eff_d,
   input  logic                                 exu_flush_final,
   input  logic                                 dec_tlu_flush_err_wb,
   input  logic                                 dec_tlu_flush_noredir_wb,
   input  logic                                 dec_tlu_dbg_halted,
   input  logic                                 dec_tlu_pmu_fw_halted,
   input  logic [31:1]                          exu_flush_path_final,
   input  logic                                 exu_flush_upper_e2,
   input  logic [31:0]                          dec_tlu_mrac_ff,
   input  logic                                 dec_tlu_bpred_disable,
   input  logic                                 dec_tlu_core_ecc_disable,

   // Memory / I-Cache / ICCM F2 response inputs to Aligner, IFC & BP
   input  logic                                 ic_hit_f2,
   input  logic                                 ic_crit_wd_rdy,
   input  logic                                 ic_write_stall,
   input  logic                                 ic_dma_active,
   input  logic                                 dma_iccm_stall_any,
   input  logic                                 ifu_ic_mb_empty,
   input  logic                                 ifu_fb_consume1_ext_nc,
   input  logic [7:0]                           ic_fetch_val_f2,
   input  logic [127:0]                         ic_data_f2,
   input  logic [7:0]                           ic_access_fault_f2,
   input  logic                                 ic_rd_parity_final_err,
   input  logic                                 iccm_rd_ecc_single_err,
   input  logic [7:0]                           iccm_rd_ecc_double_err,
   input  icache_err_pkt_t                      ic_error_f2,
   input  logic                                 ifu_icache_fetch_f2,

   // Branch Predictor execution/commit updates
   input  predict_pkt_t                         exu_mp_pkt,
   input  logic [`RV_BHT_GHR_RANGE]             exu_mp_eghr,
   input  br_tlu_pkt_t                          dec_tlu_br0_wb_pkt,
   input  br_tlu_pkt_t                          dec_tlu_br1_wb_pkt,
   input  logic                                 dec_tlu_flush_lower_wb,
   input  logic                                 dec_tlu_flush_leak_one_wb,
   input  rets_pkt_t                            exu_rets_e1_pkt,
   input  rets_pkt_t                            exu_rets_e4_pkt,
   input  logic                                 exu_i0_br_ret_e4,
   input  logic                                 exu_i1_br_ret_e4,
   input  logic                                 exu_i0_br_call_e4,
   input  logic                                 exu_i1_br_call_e4,

   // IFC outputs to Memory Controller
   output logic [31:1]                          ifc_fetch_addr_f1,
   output logic [31:1]                          ifc_fetch_addr_f2,
   output logic                                 ifc_fetch_req_f1,
   output logic                                 ifc_fetch_req_f1_raw,
   output logic                                 ifc_fetch_req_f2,
   output logic                                 ifc_fetch_uncacheable_f1,
   output logic                                 ifc_iccm_access_f1,
   output logic                                 ifc_region_acc_fault_f1,
   output logic                                 ifc_dma_access_ok,
   output logic                                 ifu_pmu_fetch_stall,

   // Branch Predictor F2 outputs
   output logic                                 ifu_bp_kill_next_f2,
   output logic [31:1]                          ifu_bp_btb_target_f2,
   output logic [7:1]                           ifu_bp_inst_mask_f2,
   output logic [7:0]                           ifu_bp_hist1_f2,
   output logic [7:0]                           ifu_bp_hist0_f2,
   output logic [11:0]                          ifu_bp_poffset_f2,
   output logic [7:0]                           ifu_bp_ret_f2,
   output logic [7:0]                           ifu_bp_pc4_f2,
   output logic [7:0]                           ifu_bp_valid_f2,
   output logic [`RV_BHT_GHR_RANGE]             ifu_bp_fghr_f2,

   // Aligner outputs to Decode
   output logic                                 ifu_i0_valid,
   output logic                                 ifu_i1_valid,
   output logic                                 ifu_i0_icaf,
   output logic                                 ifu_i1_icaf,
   output logic                                 ifu_i0_icaf_second,
   output logic                                 ifu_i1_icaf_second,
   output logic                                 ifu_i0_perr,
   output logic                                 ifu_i1_perr,
   output logic                                 ifu_i0_sbecc,
   output logic                                 ifu_i1_sbecc,
   output logic                                 ifu_i0_dbecc,
   output logic                                 ifu_i1_dbecc,
   output logic [31:0]                          ifu_i0_instr,
   output logic [31:0]                          ifu_i1_instr,
   output logic [31:1]                          ifu_i0_pc,
   output logic [31:1]                          ifu_i1_pc,
   output logic                                 ifu_i0_pc4,
   output logic                                 ifu_i1_pc4,
   output logic [15:0]                          ifu_i0_cinst,
   output logic [15:0]                          ifu_i1_cinst,
   output logic                                 ifu_fb_consume1,
   output logic                                 ifu_fb_consume2,
   output logic [15:0]                          ifu_illegal_inst,
   output br_pkt_t                              i0_brp,
   output br_pkt_t                              i1_brp,
   output logic [1:0]                           ifu_pmu_instr_aligned,
   output logic                                 ifu_pmu_align_stall,
   output logic [16:2]                          ifu_icache_error_index,
   output logic                                 ifu_icache_error_val,
   output logic                                 ifu_icache_sb_error_val,

   // Transparent pass-through sideband channels
   input  logic [7:0]                           ghr_in,
   output logic [7:0]                           ghr_out,
   input  logic [7:0]                           ras_in,
   output logic [7:0]                           ras_out
);

   logic free_clk, active_clk;
   assign free_clk   = clk;
   assign active_clk = clk;

   assign ghr_out = ghr_in;
   assign ras_out = ras_in;

`ifdef RV_BTB_48
   logic [7:0][1:0] ifu_bp_way_f2;
`else
   logic [7:0]      ifu_bp_way_f2;
`endif

   logic [127:0] ifu_fetch_data;
   logic [7:0]   ifu_fetch_val;
   logic [31:1]  ifu_fetch_pc;

   assign ifu_fetch_data[127:0] = ic_data_f2[127:0];
   assign ifu_fetch_val[7:0]    = ic_fetch_val_f2[7:0];
   assign ifu_fetch_pc[31:1]    = ifc_fetch_addr_f2[31:1];

   ifu_ifc_ctl u_ifc (.*);
   ifu_bp_ctl  u_bp  (.*);
   ifu_aln_ctl u_aln (.*);

endmodule
