// SPDX-License-Identifier: Apache-2.0
module veer_ifu_bp_mem_top
   import veer_types::*;
(
   input  logic                        clk,
   input  logic                        rst_l,
   input  logic                        scan_mode,
   input  logic                        clk_override,
   input  logic                        ifu_bus_clk_en,

   // Aligner / Decode / EXU / TLU feedback to IFU Fetch & BP & Mem
   input  logic                        ifu_fb_consume1,
   input  logic                        ifu_fb_consume2,
   input  logic                        exu_flush_final,
   input  logic [31:1]                 exu_flush_path_final,
   input  logic                        exu_flush_upper_e2,
   input  logic                        dec_tlu_flush_err_wb,
   input  logic                        dec_tlu_flush_noredir_wb,
   input  logic                        dec_tlu_dbg_halted,
   input  logic                        dec_tlu_pmu_fw_halted,
   input  logic [31:0]                 dec_tlu_mrac_ff,
   input  logic                        dec_tlu_fence_i_wb,
   input  logic                        dec_tlu_flush_leak_one_wb,
   input  logic                        dec_tlu_bpred_disable,
   input  logic                        dec_tlu_core_ecc_disable,
   input  logic                        dec_tlu_flush_lower_wb,

   input  logic                        exu_i0_br_ret_e4,
   input  logic                        exu_i1_br_ret_e4,
   input  logic                        exu_i0_br_call_e4,
   input  logic                        exu_i1_br_call_e4,
   input  predict_pkt_t                exu_mp_pkt,
   input  logic [`RV_BHT_GHR_RANGE]    exu_mp_eghr,
   input  br_tlu_pkt_t                 dec_tlu_br0_wb_pkt,
   input  br_tlu_pkt_t                 dec_tlu_br1_wb_pkt,
   input  rets_pkt_t                   exu_rets_e1_pkt,
   input  rets_pkt_t                   exu_rets_e4_pkt,

   input  logic [16:6]                 ifu_icache_error_index,
   input  logic                        ifu_icache_error_val,
   input  logic                        ifu_icache_sb_error_val,
   input  cache_debug_pkt_t            dec_tlu_ic_diag_pkt,

   // DMA ICCM interface
   input  logic                        dma_iccm_req,
   input  logic                        dma_iccm_stall_any,
   input  logic [31:0]                 dma_mem_addr,
   input  logic [2:0]                  dma_mem_sz,
   input  logic                        dma_mem_write,
   input  logic [63:0]                 dma_mem_wdata,
   output logic                        iccm_dma_ecc_error,
   output logic                        iccm_dma_rvalid,
   output logic [63:0]                 iccm_dma_rdata,
   output logic                        iccm_ready,
   output logic                        iccm_dma_sb_error,

   // AXI4 Read/Write Channels
   output logic                        ifu_axi_awvalid,
   input  logic                        ifu_axi_awready,
   output logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_awid,
   output logic [31:0]                 ifu_axi_awaddr,
   output logic [3:0]                  ifu_axi_awregion,
   output logic [7:0]                  ifu_axi_awlen,
   output logic [2:0]                  ifu_axi_awsize,
   output logic [1:0]                  ifu_axi_awburst,
   output logic                        ifu_axi_awlock,
   output logic [3:0]                  ifu_axi_awcache,
   output logic [2:0]                  ifu_axi_awprot,
   output logic [3:0]                  ifu_axi_awqos,
   output logic                        ifu_axi_wvalid,
   input  logic                        ifu_axi_wready,
   output logic [63:0]                 ifu_axi_wdata,
   output logic [7:0]                  ifu_axi_wstrb,
   output logic                        ifu_axi_wlast,
   input  logic                        ifu_axi_bvalid,
   output logic                        ifu_axi_bready,
   input  logic [1:0]                  ifu_axi_bresp,
   input  logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_bid,
   output logic                        ifu_axi_arvalid,
   input  logic                        ifu_axi_arready,
   output logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_arid,
   output logic [31:0]                 ifu_axi_araddr,
   output logic [3:0]                  ifu_axi_arregion,
   output logic [7:0]                  ifu_axi_arlen,
   output logic [2:0]                  ifu_axi_arsize,
   output logic [1:0]                  ifu_axi_arburst,
   output logic                        ifu_axi_arlock,
   output logic [3:0]                  ifu_axi_arcache,
   output logic [2:0]                  ifu_axi_arprot,
   output logic [3:0]                  ifu_axi_arqos,
   input  logic                        ifu_axi_rvalid,
   output logic                        ifu_axi_rready,
   input  logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_rid,
   input  logic [63:0]                 ifu_axi_rdata,
   input  logic [1:0]                  ifu_axi_rresp,
   input  logic                        ifu_axi_rlast,

   // I-Cache & ITAG & ICCM SRAM array ports
   output logic [31:2]                 ic_rw_addr,
   output logic [3:0]                  ic_wr_en,
   output logic                        ic_rd_en,
   output logic [67:0]                 ic_wr_data,
   input  logic [135:0]                ic_rd_data,
   input  logic [20:0]                 ictag_debug_rd_data,
   output logic [33:0]                 ic_debug_wr_data,
   output logic [33:0]                 ifu_ic_debug_rd_data,
   output logic [127:0]                ic_premux_data,
   output logic                        ic_sel_premux_data,
   output logic [15:2]                 ic_debug_addr,
   output logic                        ic_debug_rd_en,
   output logic                        ic_debug_wr_en,
   output logic                        ic_debug_tag_array,
   output logic [3:0]                  ic_debug_way,
   output logic [3:0]                  ic_tag_valid,
   input  logic [3:0]                  ic_rd_hit,
   input  logic                        ic_tag_perr,
   output logic [`RV_ICCM_BITS-1:2]    iccm_rw_addr,
   output logic                        iccm_wren,
   output logic                        iccm_rden,
   output logic [77:0]                 iccm_wr_data,
   output logic [2:0]                  iccm_wr_size,
   input  logic [155:0]                iccm_rd_data,

   // Outputs to Aligner / PMU / Debug
   output logic [31:1]                 ifc_fetch_addr_f1,
   output logic [31:1]                 ifc_fetch_addr_f2,
   output logic                        ifc_fetch_req_f1,
   output logic                        ifc_fetch_req_f2,
   output logic                        ic_hit_f2,
   output logic                        ic_crit_wd_rdy,
   output logic [7:0]                  ic_access_fault_f2,
   output logic                        ic_rd_parity_final_err,
   output logic                        iccm_rd_ecc_single_err,
   output logic [7:0]                  iccm_rd_ecc_double_err,
   output logic [7:0]                  ic_fetch_val_f2,
   output logic [127:0]                ic_data_f2,
   output icache_err_pkt_t             ic_error_f2,
   output logic                        ifu_icache_fetch_f2,
   output logic                        ifu_miss_state_idle,
   output logic                        ifu_ic_mb_empty,
   output logic                        ic_dma_active,
   output logic                        ic_write_stall,
   output logic                        ifu_bp_kill_next_f2,
   output logic [31:1]                 ifu_bp_btb_target_f2,
   output logic [7:1]                  ifu_bp_inst_mask_f2,
   output logic [`RV_BHT_GHR_RANGE]    ifu_bp_fghr_f2,
   output logic [7:0]                  ifu_bp_way_f2,
   output logic [7:0]                  ifu_bp_ret_f2,
   output logic [7:0]                  ifu_bp_hist1_f2,
   output logic [7:0]                  ifu_bp_hist0_f2,
   output logic [11:0]                 ifu_bp_poffset_f2,
   output logic [7:0]                  ifu_bp_pc4_f2,
   output logic [7:0]                  ifu_bp_valid_f2,
   output logic                        ifu_pmu_fetch_stall,
   output logic                        ifu_pmu_ic_miss,
   output logic                        ifu_pmu_ic_hit,
   output logic                        ifu_pmu_bus_error,
   output logic                        ifu_pmu_bus_busy,
   output logic                        ifu_pmu_bus_trxn,
   output logic                        ifu_ic_debug_rd_data_valid
);

   logic free_clk, active_clk;
   assign free_clk   = clk;
   assign active_clk = clk;

   logic ifc_fetch_uncacheable_f1;
   logic ifc_fetch_req_f1_raw;
   logic ifc_iccm_access_f1;
   logic ifc_region_acc_fault_f1;
   logic ifc_dma_access_ok;

   ifu_ifc_ctl u_ifc (.*);
   ifu_bp_ctl  u_bp  (.*);
   ifu_mem_ctl u_mem (
      .*,
      .fetch_addr_f1(ifc_fetch_addr_f1)
   );

endmodule
