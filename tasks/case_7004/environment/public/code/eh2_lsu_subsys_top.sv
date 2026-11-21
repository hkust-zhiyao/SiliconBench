// SPDX-License-Identifier: Apache-2.0
// VeeR EH2 Dual-Thread LSU DCCM, SECDED ECC, Atomic RMW, and Coalescing Store-Buffer Subsystem Top

module eh2_lsu_subsys_top
import eh2_pkg::*;
#(
`include "eh2_param.vh"
)
(
   input  logic                             clk,
   input  logic                             clk_override,
   input  logic                             rst_l,
   input  logic                             scan_mode,

   input  eh2_lsu_pkt_t                     lsu_pkt_dc1_pre,
   input  eh2_lsu_pkt_t                     lsu_pkt_dc1,
   input  eh2_lsu_pkt_t                     lsu_pkt_dc2,
   input  eh2_lsu_pkt_t                     lsu_pkt_dc3,
   input  eh2_lsu_pkt_t                     lsu_pkt_dc4,
   input  eh2_lsu_pkt_t                     lsu_pkt_dc5,

   input  logic                             core_ldst_dual_dc1,
   input  logic                             ldst_dual_dc2,
   input  logic                             ldst_dual_dc3,
   input  logic                             ldst_dual_dc4,
   input  logic                             ldst_dual_dc5,

   input  logic                             addr_in_dccm_region_dc1,
   input  logic                             addr_in_dccm_dc1,
   input  logic                             addr_in_dccm_dc2,
   input  logic                             addr_in_dccm_dc3,
   input  logic                             addr_in_dccm_dc4,
   input  logic                             addr_in_dccm_dc5,
   input  logic                             addr_in_pic_dc1,
   input  logic                             addr_in_pic_dc2,
   input  logic                             addr_in_pic_dc3,
   input  logic                             addr_in_pic_dc5,

   input  logic                             lsu_cmpen_dc2,
   input  logic                             store_stbuf_reqvld_dc5,
   input  logic                             lsu_commit_dc5,
   input  logic                             lsu_sc_success_dc5,
   input  logic                             lsu_raw_fwd_lo_dc5,
   input  logic                             lsu_raw_fwd_hi_dc5,
   input  logic                             lsu_double_ecc_error_dc5,
   input  logic                             single_ecc_error_hi_dc4,
   input  logic                             single_ecc_error_lo_dc4,
   input  logic                             single_ecc_error_hi_dc5,
   input  logic                             single_ecc_error_lo_dc5,
   input  logic                             dec_tlu_core_ecc_disable,
   input  logic                             misaligned_fault_dc3,
   input  logic                             access_fault_dc3,

   input  logic                             dma_pic_wen,
   input  logic                             dma_dccm_wen,
   input  logic                             dma_dccm_spec_wen,
   input  logic                             dma_dccm_spec_req,
   input  logic                             dma_mem_write,
   input  logic [2:0]                       dma_mem_sz,
   input  logic [pt.XLEN-1:0]               dma_mem_addr,
   input  logic [(pt.XLEN*2)-1:0]           dma_mem_wdata,
   input  logic [2:0]                       dma_mem_tag_dc3,
   input  logic [pt.XLEN-1:0]               dma_dccm_wdata_lo,
   input  logic [pt.XLEN-1:0]               dma_dccm_wdata_hi,

   input  logic [pt.XLEN-1:0]               lsu_addr_dc1,
   input  logic [pt.XLEN-1:0]               lsu_addr_dc2,
   input  logic [pt.XLEN-1:0]               lsu_addr_dc3,
   input  logic [pt.XLEN-1:0]               lsu_addr_dc4,
   input  logic [pt.XLEN-1:0]               lsu_addr_dc5,

   input  logic [pt.XLEN-1:0]               end_addr_dc1,
   input  logic [pt.XLEN-1:0]               end_addr_dc2,
   input  logic [pt.XLEN-1:0]               end_addr_dc3,
   input  logic [pt.XLEN-1:0]               end_addr_dc4,
   input  logic [pt.XLEN-1:0]               end_addr_dc5,

   input  logic [pt.XLEN-1:0]               store_data_dc3,
   input  logic [pt.DCCM_FDATA_WIDTH-1:0]   dccm_rd_data_lo,
   input  logic [pt.DCCM_FDATA_WIDTH-1:0]   dccm_rd_data_hi,
   input  logic [pt.XLEN-1:0]               picm_rd_data,

   output logic [pt.DCCM_FDATA_WIDTH-1:0]   dccm_wr_data_hi,
   output logic [pt.DCCM_FDATA_WIDTH-1:0]   dccm_wr_data_lo,
   output logic [pt.DCCM_DATA_WIDTH-1:0]    dccm_datafn_hi_dc5,
   output logic [pt.DCCM_DATA_WIDTH-1:0]    dccm_datafn_lo_dc5,
   output logic                             stbuf_reqvld_any,
   output logic                             stbuf_reqvld_flushed_any,
   output logic [pt.LSU_SB_BITS-1:0]        stbuf_addr_any,
   output logic [pt.DCCM_DATA_WIDTH-1:0]    stbuf_data_any,
   output logic [pt.NUM_THREADS-1:0]        lsu_stbuf_empty_any,
   output logic [pt.NUM_THREADS-1:0]        lsu_stbuf_full_any,
   output logic                             lsu_stbuf_commit_any,

   output logic                             single_ecc_error_hi_dc3,
   output logic                             single_ecc_error_lo_dc3,
   output logic                             lsu_single_ecc_error_dc3,
   output logic                             lsu_double_ecc_error_dc3,
   output logic                             ld_single_ecc_error_dc3,
   output logic                             ld_single_ecc_error_dc5,
   output logic                             ld_single_ecc_error_dc5_ff,
   output logic                             ld_single_ecc_error_lo_dc5_ff,
   output logic                             ld_single_ecc_error_hi_dc5_ff,

   output logic [pt.DCCM_DATA_WIDTH-1:0]    lsu_dccm_data_dc3,
   output logic [pt.DCCM_DATA_WIDTH-1:0]    lsu_dccm_data_corr_dc3,
   output logic [pt.XLEN-1:0]               amo_data_dc3,
   output logic [pt.XLEN-1:0]               picm_mask_data_dc3,
   output logic [pt.XLEN-1:0]               picm_rd_data_dc3,
   output logic                             lsu_dccm_rden_dc3,

   output logic                             dccm_dma_rvalid,
   output logic                             dccm_dma_ecc_error,
   output logic [2:0]                       dccm_dma_rtag,
   output logic [(pt.XLEN*2)-1:0]           dccm_dma_rdata,

   output logic                             dccm_wren,
   output logic                             dccm_rden,
   output logic [pt.DCCM_BITS-1:0]          dccm_wr_addr_lo,
   output logic [pt.DCCM_BITS-1:0]          dccm_wr_addr_hi,
   output logic [pt.DCCM_BITS-1:0]          dccm_rd_addr_lo,
   output logic [pt.DCCM_BITS-1:0]          dccm_rd_addr_hi,

   output logic                             picm_wren_notdma,
   output logic                             picm_wren,
   output logic                             picm_rden,
   output logic                             picm_mken,
   output logic                             picm_rd_thr,
   output logic [pt.XLEN-1:0]               picm_rdaddr,
   output logic [pt.XLEN-1:0]               picm_wraddr,
   output logic [pt.XLEN-1:0]               picm_wr_data,

   output logic                             picm_fwd_en_dc2,
   output logic [pt.XLEN-1:0]               picm_fwd_data_dc2,
   output logic [pt.DCCM_DATA_WIDTH-1:0]    stbuf_fwddata_hi_dc3,
   output logic [pt.DCCM_DATA_WIDTH-1:0]    stbuf_fwddata_lo_dc3,
   output logic [pt.DCCM_BYTE_WIDTH-1:0]    stbuf_fwdbyteen_hi_dc3,
   output logic [pt.DCCM_BYTE_WIDTH-1:0]    stbuf_fwdbyteen_lo_dc3
);

   logic [pt.DCCM_DATA_WIDTH-1:0]  dccm_data_hi_dc3;
   logic [pt.DCCM_DATA_WIDTH-1:0]  dccm_data_lo_dc3;
   logic [pt.DCCM_ECC_WIDTH-1:0]   dccm_data_ecc_hi_dc3;
   logic [pt.DCCM_ECC_WIDTH-1:0]   dccm_data_ecc_lo_dc3;
   logic [(pt.XLEN*2)-1:0]         store_data_ext_dc3;
   logic [(pt.XLEN*2)-1:0]         store_data_ext_dc4;
   logic [(pt.XLEN*2)-1:0]         store_data_ext_dc5;
   logic                           disable_ecc_check_lo_dc3;
   logic                           disable_ecc_check_hi_dc3;
   logic [pt.DCCM_DATA_WIDTH-1:0]  sec_data_hi_dc3;
   logic [pt.DCCM_DATA_WIDTH-1:0]  sec_data_lo_dc3;
   logic [pt.DCCM_DATA_WIDTH-1:0]  sec_data_hi_dc5;
   logic [pt.DCCM_DATA_WIDTH-1:0]  sec_data_lo_dc5;
   logic [pt.DCCM_DATA_WIDTH-1:0]  store_ecc_data_hi_dc3;
   logic [pt.DCCM_DATA_WIDTH-1:0]  store_ecc_data_lo_dc3;

   eh2_lsu_amo #(.pt(pt)) u_amo (
      .lsu_pkt_dc3            (lsu_pkt_dc3),
      .addr_in_pic_dc3        (addr_in_pic_dc3),
      .lsu_dccm_data_corr_dc3 (lsu_dccm_data_corr_dc3),
      .store_data_dc3         (store_data_dc3),
      .amo_data_dc3           (amo_data_dc3)
   );

   eh2_lsu_ecc #(.pt(pt)) u_ecc (
      .clk                           (clk),
      .clk_override                  (clk_override),
      .scan_mode                     (scan_mode),
      .rst_l                         (rst_l),
      .lsu_pkt_dc3                   (lsu_pkt_dc3),
      .lsu_dccm_rden_dc3             (lsu_dccm_rden_dc3),
      .addr_in_dccm_dc3              (addr_in_dccm_dc3),
      .lsu_addr_dc3                  (lsu_addr_dc3[pt.DCCM_BITS-1:0]),
      .end_addr_dc3                  (end_addr_dc3[pt.DCCM_BITS-1:0]),
      .store_data_dc3                (store_data_dc3),
      .stbuf_data_any                (stbuf_data_any),
      .dccm_data_hi_dc3              (dccm_data_hi_dc3),
      .dccm_data_lo_dc3              (dccm_data_lo_dc3),
      .dccm_data_ecc_hi_dc3          (dccm_data_ecc_hi_dc3),
      .dccm_data_ecc_lo_dc3          (dccm_data_ecc_lo_dc3),
      .sec_data_hi_dc5               (sec_data_hi_dc5),
      .sec_data_lo_dc5               (sec_data_lo_dc5),
      .ld_single_ecc_error_dc5       (ld_single_ecc_error_dc5),
      .ld_single_ecc_error_dc5_ff    (ld_single_ecc_error_dc5_ff),
      .ld_single_ecc_error_lo_dc5_ff (ld_single_ecc_error_lo_dc5_ff),
      .ld_single_ecc_error_hi_dc5_ff (ld_single_ecc_error_hi_dc5_ff),
      .dec_tlu_core_ecc_disable      (dec_tlu_core_ecc_disable),
      .disable_ecc_check_lo_dc3      (disable_ecc_check_lo_dc3),
      .disable_ecc_check_hi_dc3      (disable_ecc_check_hi_dc3),
      .misaligned_fault_dc3          (misaligned_fault_dc3),
      .access_fault_dc3              (access_fault_dc3),
      .dma_dccm_spec_wen             (dma_dccm_spec_wen),
      .dma_dccm_wdata_lo             (dma_dccm_wdata_lo),
      .dma_dccm_wdata_hi             (dma_dccm_wdata_hi),
      .dccm_wr_data_hi               (dccm_wr_data_hi),
      .dccm_wr_data_lo               (dccm_wr_data_lo),
      .sec_data_hi_dc3               (sec_data_hi_dc3),
      .sec_data_lo_dc3               (sec_data_lo_dc3),
      .store_ecc_data_hi_dc3         (store_ecc_data_hi_dc3),
      .store_ecc_data_lo_dc3         (store_ecc_data_lo_dc3),
      .single_ecc_error_hi_dc3       (single_ecc_error_hi_dc3),
      .single_ecc_error_lo_dc3       (single_ecc_error_lo_dc3),
      .lsu_single_ecc_error_dc3      (lsu_single_ecc_error_dc3),
      .lsu_double_ecc_error_dc3      (lsu_double_ecc_error_dc3)
   );

   eh2_lsu_dccm_ctl #(.pt(pt)) u_dccm_ctl (
      .clk                           (clk),
      .clk_override                  (clk_override),
      .lsu_free_c2_clk               (clk),
      .lsu_dccm_c1_dc3_clk           (clk),
      .lsu_c2_dc2_clk                (clk),
      .lsu_c2_dc3_clk                (clk),
      .lsu_pic_c1_dc3_clk            (clk),
      .rst_l                         (rst_l),
      .scan_mode                     (scan_mode),
      .*
   );

   eh2_lsu_stbuf #(.pt(pt)) u_stbuf (
      .clk                           (clk),
      .rst_l                         (rst_l),
      .clk_override                  (clk_override),
      .scan_mode                     (scan_mode),
      .lsu_c1_dc3_clk                (clk),
      .lsu_stbuf_c1_clk              (clk),
      .lsu_free_c2_clk               (clk),
      .*
   );

endmodule
