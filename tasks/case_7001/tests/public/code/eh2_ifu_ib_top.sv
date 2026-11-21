// SPDX-License-Identifier: Apache-2.0
module eh2_ifu_ib_top
import eh2_pkg::*;
#(
`include "eh2_param.vh"
)
(
   input  logic                                   clk,
   input  logic                                   rst_l,
   input  logic                                   scan_mode,

   input  logic                                   tid,
   input  logic                                   ifc_select_tid_f1,
   input  logic                                   dec_i0_tid_d,
   input  logic                                   dec_i1_tid_d,

   input  logic                                   ic_hit_f2,
   input  logic                                   ic_crit_wd_rdy,
   input  logic                                   ifu_ic_mb_empty,
   input  logic                                   dec_tlu_flush_noredir_wb,
   input  logic                                   dec_tlu_flush_mp_wb,
   input  logic                                   dec_tlu_flush_lower_wb,
   input  logic                                   exu_flush_final,
   input  logic [pt.XLEN-1:1]                     exu_flush_path_final,
   input  logic [pt.XLEN-1:1]                     dec_tlu_flush_path_wb,
   input  logic                                   exu_flush_final_early,
   input  logic [pt.XLEN-1:1]                     exu_flush_path_final_early,
   input  logic                                   ifu_bp_kill_next_f2,
   input  logic [pt.XLEN-1:1]                     ifu_bp_btb_target_f2,
   input  logic                                   ic_dma_active,
   input  logic                                   ic_write_stall,
   input  logic                                   dma_iccm_stall_any,
   input  logic [pt.XLEN-1:0]                     dec_tlu_mrac_ff,

   input  logic                                   dec_i1_cancel_e1,
   input  logic                                   ifu_async_error_start,
   input  logic [3:0]                             iccm_rd_ecc_double_err,
   input  logic [3:0]                             ic_access_fault_f2,
   input  logic [1:0]                             ic_access_fault_type_f2,
   input  logic                                   dec_i0_decode_d,
   input  logic                                   dec_i1_decode_d,
   input  logic [63:0]                            ifu_fetch_data_f2,
   input  logic [3:0]                             ic_fetch_val_f2,

   input  logic [pt.BHT_GHR_SIZE-1:0]             ifu_bp_fghr_f2,
   input  logic [pt.BTB_TOFFSET_SIZE-1:0]         ifu_bp_poffset_f2,
   input  logic [3:0][$clog2(pt.BTB_SIZE)-1:0]    ifu_bp_fa_index_f2,
   input  logic [3:0]                             ifu_bp_hist0_f2,
   input  logic [3:0]                             ifu_bp_hist1_f2,
   input  logic [3:0]                             ifu_bp_pc4_f2,
   input  logic [3:0]                             ifu_bp_way_f2,
   input  logic [3:0]                             ifu_bp_valid_f2,
   input  logic [3:0]                             ifu_bp_ret_f2,

   input  logic                                   dbg_cmd_valid,
   input  logic                                   dbg_cmd_tid,
   input  logic                                   dbg_cmd_write,
   input  logic [1:0]                             dbg_cmd_type,
   input  logic [pt.XLEN-1:0]                     dbg_cmd_addr,

   output logic                                   fetch_uncacheable_f1,
   output logic [pt.XLEN-1:1]                     fetch_addr_f1,
   output logic [pt.XLEN-1:1]                     fetch_addr_bf,
   output logic [pt.XLEN-1:1]                     fetch_addr_f2,
   output logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   fetch_btb_rd_addr_f1,
   output logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   fetch_btb_rd_addr_p1_f1,
   output logic                                   fetch_req_bf,
   output logic                                   fetch_req_f1,
   output logic                                   fetch_req_f1_raw,
   output logic                                   fetch_req_f2,
   output logic                                   pmu_fetch_stall,
   output logic                                   iccm_access_f1,
   output logic                                   region_acc_fault_f1,
   output logic                                   dma_access_ok,
   output logic                                   ready,

   output logic                                   ifu_fb_consume1,
   output logic                                   ifu_fb_consume2,
   output logic                                   ifu_i0_valid,
   output logic                                   ifu_i1_valid,
   output logic [1:0]                             pmu_instr_aligned,
   output logic                                   pmu_align_stall,

   output logic                                   ib3_valid_d,
   output logic                                   ib2_valid_d,
   output logic                                   ib1_valid_d,
   output logic                                   ib0_valid_d,
   output logic                                   ib0_valid_in,
   output logic                                   ib0_lsu_in,
   output logic                                   ib0_mul_in,
   output logic                                   ib0_i0_only_in,

   output logic [31:0]                            i0_instr_d,
   output logic [31:0]                            i1_instr_d,
   output logic [pt.XLEN-1:1]                     i0_pc_d,
   output logic [pt.XLEN-1:1]                     i1_pc_d,
   output logic                                   i0_pc4_d,
   output logic                                   i1_pc4_d,
   output eh2_br_pkt_t                            i0_br_p,
   output eh2_br_pkt_t                            i1_br_p,
   output logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   i0_bp_index,
   output logic [pt.BHT_GHR_SIZE-1:0]             i0_bp_fghr,
   output logic [pt.BTB_BTAG_SIZE-1:0]            i0_bp_btag,
   output logic [pt.BTB_TOFFSET_SIZE-1:0]         i0_bp_toffset,
   output logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   i1_bp_index,
   output logic [pt.BHT_GHR_SIZE-1:0]             i1_bp_fghr,
   output logic [pt.BTB_BTAG_SIZE-1:0]            i1_bp_btag,
   output logic [pt.BTB_TOFFSET_SIZE-1:0]         i1_bp_toffset,
   output logic [$clog2(pt.BTB_SIZE)-1:0]         i0_bp_fa_index,
   output logic                                   i0_icaf_d,
   output logic                                   i1_icaf_d,
   output logic                                   i0_icaf_second_d,
   output logic [1:0]                             i0_icaf_type_d,
   output logic                                   i0_dbecc_d,
   output logic                                   i1_dbecc_d,
   output logic                                   debug_wdata_rs1_d,
   output logic                                   debug_fence_d,
   output logic                                   i0_debug_valid_d,
   output logic [15:0]                            i0_cinst_d,
   output logic [15:0]                            i1_cinst_d,
   output eh2_predecode_pkt_t                     i0_predecode,
   output eh2_predecode_pkt_t                     i1_predecode
);

   localparam eh2_param_t pt_cfg = '{
      default: '0,
      ATOMIC_ENABLE          : pt.ATOMIC_ENABLE,
      BHT_ADDR_HI            : pt.BHT_ADDR_HI,
      BHT_ADDR_LO            : pt.BHT_ADDR_LO,
      BHT_ARRAY_DEPTH        : pt.BHT_ARRAY_DEPTH,
      BHT_GHR_HASH_1         : pt.BHT_GHR_HASH_1,
      BHT_GHR_SIZE           : pt.BHT_GHR_SIZE,
      BHT_SIZE               : pt.BHT_SIZE,
      BITMANIP_ZBA           : pt.BITMANIP_ZBA,
      BITMANIP_ZBB           : pt.BITMANIP_ZBB,
      BITMANIP_ZBC           : pt.BITMANIP_ZBC,
      BITMANIP_ZBKB          : pt.BITMANIP_ZBKB,
      BITMANIP_ZBKX          : pt.BITMANIP_ZBKX,
      BITMANIP_ZBS           : pt.BITMANIP_ZBS,
      BTB_ADDR_HI            : pt.BTB_ADDR_HI,
      BTB_ADDR_LO            : pt.BTB_ADDR_LO,
      BTB_ARRAY_DEPTH        : pt.BTB_ARRAY_DEPTH,
      BTB_BTAG_FOLD          : pt.BTB_BTAG_FOLD,
      BTB_BTAG_SIZE          : pt.BTB_BTAG_SIZE,
      BTB_BYPASS_ENABLE      : pt.BTB_BYPASS_ENABLE,
      BTB_FOLD2_INDEX_HASH   : pt.BTB_FOLD2_INDEX_HASH,
      BTB_FULLYA             : pt.BTB_FULLYA,
      BTB_INDEX1_HI          : pt.BTB_INDEX1_HI,
      BTB_INDEX1_LO          : pt.BTB_INDEX1_LO,
      BTB_INDEX2_HI          : pt.BTB_INDEX2_HI,
      BTB_INDEX2_LO          : pt.BTB_INDEX2_LO,
      BTB_INDEX3_HI          : pt.BTB_INDEX3_HI,
      BTB_INDEX3_LO          : pt.BTB_INDEX3_LO,
      BTB_NUM_BYPASS         : pt.BTB_NUM_BYPASS,
      BTB_NUM_BYPASS_WIDTH   : pt.BTB_NUM_BYPASS_WIDTH,
      BTB_SIZE               : pt.BTB_SIZE,
      BTB_TOFFSET_SIZE       : pt.BTB_TOFFSET_SIZE,
      BTB_USE_SRAM           : pt.BTB_USE_SRAM,
      BUILD_AHB_LITE         : pt.BUILD_AHB_LITE,
      BUILD_AXI4             : pt.BUILD_AXI4,
      BUILD_AXI_NATIVE       : pt.BUILD_AXI_NATIVE,
      BUS_ADDR_OFF           : pt.BUS_ADDR_OFF,
      BUS_BYTES              : pt.BUS_BYTES,
      BUS_PRTY_DEFAULT       : pt.BUS_PRTY_DEFAULT,
      BUS_WIDTH              : pt.BUS_WIDTH,
      ICACHE_TAG_INDEX_LO    : pt.ICACHE_TAG_INDEX_LO,
      ICCM_BANK_BITS         : pt.ICCM_BANK_BITS,
      ICCM_BANK_HI           : pt.ICCM_BANK_HI,
      ICCM_BANK_INDEX_LO     : pt.ICCM_BANK_INDEX_LO,
      ICCM_BITS              : pt.ICCM_BITS,
      ICCM_ENABLE            : pt.ICCM_ENABLE,
      ICCM_ICACHE            : pt.ICCM_ICACHE,
      ICCM_INDEX_BITS        : pt.ICCM_INDEX_BITS,
      ICCM_NUM_BANKS         : pt.ICCM_NUM_BANKS,
      ICCM_ONLY              : pt.ICCM_ONLY,
      ICCM_REGION            : pt.ICCM_REGION,
      ICCM_SADR              : pt.ICCM_SADR,
      ICCM_SIZE              : pt.ICCM_SIZE,
      NUM_THREADS            : 6'h01,
      RET_STACK_SIZE         : pt.RET_STACK_SIZE,
      XLEN                   : pt.XLEN,
      XLEN_ADDR_OFF          : pt.XLEN_ADDR_OFF,
      XLEN_BYTES             : pt.XLEN_BYTES,
      XLENW                  : pt.XLENW
   };

   logic active_clk;
   assign active_clk = clk;

   logic [3:0]         ifu_fetch_val;
   logic [63:0]        ifu_fetch_data;
   logic [pt.XLEN-1:1] ifu_fetch_pc;
   assign ifu_fetch_val  = {4{fetch_req_f2 & ic_hit_f2}} & ic_fetch_val_f2;
   assign ifu_fetch_data = ifu_fetch_data_f2;
   assign ifu_fetch_pc   = fetch_addr_f2;

   logic                                   ifu_i0_icaf;
   logic [1:0]                             ifu_i0_icaf_type;
   logic                                   ifu_i0_icaf_second;
   logic                                   ifu_i0_dbecc;
   logic [31:0]                            ifu_i0_instr;
   logic [31:0]                            ifu_i1_instr;
   logic [pt.XLEN-1:1]                     ifu_i0_pc;
   logic [pt.XLEN-1:1]                     ifu_i1_pc;
   logic                                   ifu_i0_pc4;
   logic                                   ifu_i1_pc4;
   eh2_predecode_pkt_t                     ifu_i0_predecode;
   eh2_predecode_pkt_t                     ifu_i1_predecode;
   eh2_br_pkt_t                            i0_brp;
   eh2_br_pkt_t                            i1_brp;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   ifu_i0_bp_index;
   logic [pt.BHT_GHR_SIZE-1:0]             ifu_i0_bp_fghr;
   logic [pt.BTB_BTAG_SIZE-1:0]            ifu_i0_bp_btag;
   logic [pt.BTB_TOFFSET_SIZE-1:0]         ifu_i0_bp_toffset;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   ifu_i1_bp_index;
   logic [pt.BHT_GHR_SIZE-1:0]             ifu_i1_bp_fghr;
   logic [pt.BTB_BTAG_SIZE-1:0]            ifu_i1_bp_btag;
   logic [pt.BTB_TOFFSET_SIZE-1:0]         ifu_i1_bp_toffset;
   logic [$clog2(pt.BTB_SIZE)-1:0]         ifu_i0_bp_fa_index;
   logic [$clog2(pt.BTB_SIZE)-1:0]         ifu_i1_bp_fa_index;
   logic [15:0]                            ifu_i0_cinst;
   logic [15:0]                            ifu_i1_cinst;

   eh2_ifu_ifc_ctl #(.pt(pt_cfg)) u_ifc (.*);

   eh2_ifu_aln_ctl #(.pt(pt_cfg)) u_aln (
      .*,
      .dec_ib3_valid_d   (ib3_valid_d),
      .dec_ib2_valid_d   (ib2_valid_d),
      .i0_valid          (ifu_i0_valid),
      .i1_valid          (ifu_i1_valid),
      .i0_icaf           (ifu_i0_icaf),
      .i0_icaf_second    (ifu_i0_icaf_second),
      .i0_icaf_type      (ifu_i0_icaf_type),
      .i0_dbecc          (ifu_i0_dbecc),
      .i0_instr          (ifu_i0_instr),
      .i1_instr          (ifu_i1_instr),
      .i0_pc             (ifu_i0_pc),
      .i1_pc             (ifu_i1_pc),
      .i0_pc4            (ifu_i0_pc4),
      .i1_pc4            (ifu_i1_pc4),
      .i0_predecode      (ifu_i0_predecode),
      .i1_predecode      (ifu_i1_predecode),
      .fb_consume1       (ifu_fb_consume1),
      .fb_consume2       (ifu_fb_consume2),
      .i0_br_p           (i0_brp),
      .i1_br_p           (i1_brp),
      .i0_bp_index       (ifu_i0_bp_index),
      .i0_bp_fghr        (ifu_i0_bp_fghr),
      .i0_bp_btag        (ifu_i0_bp_btag),
      .i0_bp_toffset     (ifu_i0_bp_toffset),
      .i1_bp_index       (ifu_i1_bp_index),
      .i1_bp_fghr        (ifu_i1_bp_fghr),
      .i1_bp_btag        (ifu_i1_bp_btag),
      .i1_bp_toffset     (ifu_i1_bp_toffset),
      .i0_bp_fa_index    (ifu_i0_bp_fa_index),
      .i1_bp_fa_index    (ifu_i1_bp_fa_index),
      .i0_cinst          (ifu_i0_cinst),
      .i1_cinst          (ifu_i1_cinst)
   );

   eh2_dec_ib_ctl #(.pt(pt_cfg)) u_ib (.*);

endmodule
