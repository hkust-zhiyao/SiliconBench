// SPDX-License-Identifier: Apache-2.0
`include "common_defines.vh"
module top
import el2_pkg::*;
#(
`include "el2_param.vh"
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        clk_override,
  input  logic [31:0] lsu_ld_data_r,
  input  logic [31:0] lsu_ld_data_corr_r,
  input  logic        lsu_single_ecc_error_r,
  input  logic        lsu_double_ecc_error_r,
  input  logic [31:0] lsu_ld_data_m,
  input  logic        lsu_single_ecc_error_m,
  input  logic        lsu_double_ecc_error_m,
  input  logic        flush_m_up,
  input  logic        flush_r,
  input  logic [31:0] exu_lsu_rs1_d,
  input  logic [31:0] exu_lsu_rs2_d,
  input  logic [13:0] lsu_pkt_bits,
  input  logic        dec_lsu_valid_raw_d,
  input  logic [11:0] dec_lsu_offset_d,
  input  logic [31:0] picm_mask_data_m,
  input  logic [31:0] bus_read_data_m,
  input  logic [31:0] dec_tlu_mrac_ff,
  input  logic        dma_dccm_req,
  input  logic [31:0] dma_mem_addr,
  input  logic [2:0]  dma_mem_sz,
  input  logic        dma_mem_write,
  input  logic [63:0] dma_mem_wdata,
  input  logic        lsu_pmp_error_start,
  input  logic        lsu_pmp_error_end,
  input  logic [37:0] trigger_pkt_0,
  input  logic [37:0] trigger_pkt_1,
  input  logic [37:0] trigger_pkt_2,
  input  logic [37:0] trigger_pkt_3,
  output logic [31:0] lsu_result_m,
  output logic [31:0] lsu_result_corr_r,
  output logic [31:0] lsu_addr_d,
  output logic [31:0] lsu_addr_m,
  output logic [31:0] lsu_addr_r,
  output logic [31:0] end_addr_d,
  output logic [31:0] end_addr_m,
  output logic [31:0] end_addr_r,
  output logic [31:0] store_data_m,
  output logic        lsu_exc_m,
  output logic        is_sideeffects_m,
  output logic        lsu_commit_r,
  output logic        lsu_single_ecc_error_incr,
  output logic [39:0] lsu_error_pkt_r_bits,
  output logic [30:0] lsu_fir_addr,
  output logic [1:0]  lsu_fir_error,
  output logic        addr_in_dccm_d,
  output logic        addr_in_dccm_m,
  output logic        addr_in_dccm_r,
  output logic        addr_in_pic_d,
  output logic        addr_in_pic_m,
  output logic        addr_in_pic_r,
  output logic        addr_external_m,
  output logic [3:0]  lsu_trigger_match_m,

  // Transparent 8-bit zero-cut sideband channels
  input  logic [7:0]  pmu_in,
  output logic [7:0]  pmu_out,
  input  logic [7:0]  fir_in,
  output logic [7:0]  fir_out
);

  el2_lsu_pkt_t           lsu_p, lsu_pkt_d, lsu_pkt_m, lsu_pkt_r;
  el2_lsu_error_pkt_t     lsu_error_pkt_r;
  el2_trigger_pkt_t [3:0] trigger_pkt_any;
  logic                   ldst_dual_d, ldst_dual_m, ldst_dual_r;

  assign lsu_p                = el2_lsu_pkt_t'(lsu_pkt_bits);
  assign lsu_error_pkt_r_bits = lsu_error_pkt_r;
  assign trigger_pkt_any[0]   = el2_trigger_pkt_t'(trigger_pkt_0);
  assign trigger_pkt_any[1]   = el2_trigger_pkt_t'(trigger_pkt_1);
  assign trigger_pkt_any[2]   = el2_trigger_pkt_t'(trigger_pkt_2);
  assign trigger_pkt_any[3]   = el2_trigger_pkt_t'(trigger_pkt_3);

  assign ldst_dual_d = (lsu_addr_d[2] != end_addr_d[2]);
  assign ldst_dual_m = (lsu_addr_m[2] != end_addr_m[2]);
  assign ldst_dual_r = (lsu_addr_r[2] != end_addr_r[2]);

  el2_lsu_lsc_ctl #(
    .pt ( pt )
  ) u_lsc_ctl (
    .rst_l                     ( rst_ni                    ),
    .clk_override              ( clk_override              ),
    .clk                       ( clk_i                     ),
    .lsu_c1_m_clk              ( clk_i                     ),
    .lsu_c1_r_clk              ( clk_i                     ),
    .lsu_c2_m_clk              ( clk_i                     ),
    .lsu_c2_r_clk              ( clk_i                     ),
    .lsu_store_c1_m_clk        ( clk_i                     ),
    .lsu_ld_data_r             ( lsu_ld_data_r             ),
    .lsu_ld_data_corr_r        ( lsu_ld_data_corr_r        ),
    .lsu_single_ecc_error_r    ( lsu_single_ecc_error_r    ),
    .lsu_double_ecc_error_r    ( lsu_double_ecc_error_r    ),
    .lsu_ld_data_m             ( lsu_ld_data_m             ),
    .lsu_single_ecc_error_m    ( lsu_single_ecc_error_m    ),
    .lsu_double_ecc_error_m    ( lsu_double_ecc_error_m    ),
    .flush_m_up                ( flush_m_up                ),
    .flush_r                   ( flush_r                   ),
    .ldst_dual_d               ( ldst_dual_d               ),
    .ldst_dual_m               ( ldst_dual_m               ),
    .ldst_dual_r               ( ldst_dual_r               ),
    .exu_lsu_rs1_d             ( exu_lsu_rs1_d             ),
    .exu_lsu_rs2_d             ( exu_lsu_rs2_d             ),
    .lsu_p                     ( lsu_p                     ),
    .dec_lsu_valid_raw_d       ( dec_lsu_valid_raw_d       ),
    .dec_lsu_offset_d          ( dec_lsu_offset_d          ),
    .picm_mask_data_m          ( picm_mask_data_m          ),
    .bus_read_data_m           ( bus_read_data_m           ),
    .lsu_result_m              ( lsu_result_m              ),
    .lsu_result_corr_r         ( lsu_result_corr_r         ),
    .lsu_addr_d                ( lsu_addr_d                ),
    .lsu_addr_m                ( lsu_addr_m                ),
    .lsu_addr_r                ( lsu_addr_r                ),
    .end_addr_d                ( end_addr_d                ),
    .end_addr_m                ( end_addr_m                ),
    .end_addr_r                ( end_addr_r                ),
    .store_data_m              ( store_data_m              ),
    .dec_tlu_mrac_ff           ( dec_tlu_mrac_ff           ),
    .lsu_exc_m                 ( lsu_exc_m                 ),
    .is_sideeffects_m          ( is_sideeffects_m          ),
    .lsu_commit_r              ( lsu_commit_r              ),
    .lsu_single_ecc_error_incr ( lsu_single_ecc_error_incr ),
    .lsu_error_pkt_r           ( lsu_error_pkt_r           ),
    .lsu_fir_addr              ( lsu_fir_addr              ),
    .lsu_fir_error             ( lsu_fir_error             ),
    .addr_in_dccm_d            ( addr_in_dccm_d            ),
    .addr_in_dccm_m            ( addr_in_dccm_m            ),
    .addr_in_dccm_r            ( addr_in_dccm_r            ),
    .addr_in_pic_d             ( addr_in_pic_d             ),
    .addr_in_pic_m             ( addr_in_pic_m             ),
    .addr_in_pic_r             ( addr_in_pic_r             ),
    .addr_external_m           ( addr_external_m           ),
    .dma_dccm_req              ( dma_dccm_req              ),
    .dma_mem_addr              ( dma_mem_addr              ),
    .dma_mem_sz                ( dma_mem_sz                ),
    .dma_mem_write             ( dma_mem_write             ),
    .dma_mem_wdata             ( dma_mem_wdata             ),
    .lsu_pkt_d                 ( lsu_pkt_d                 ),
    .lsu_pkt_m                 ( lsu_pkt_m                 ),
    .lsu_pkt_r                 ( lsu_pkt_r                 ),
    .lsu_pmp_error_start       ( lsu_pmp_error_start       ),
    .lsu_pmp_error_end         ( lsu_pmp_error_end         ),
    .scan_mode                 ( 1'b0                      )
  );

  el2_lsu_trigger #(
    .pt ( pt )
  ) u_trigger (
    .trigger_pkt_any     ( trigger_pkt_any     ),
    .lsu_pkt_m           ( lsu_pkt_m           ),
    .lsu_addr_m          ( lsu_addr_m          ),
    .store_data_m        ( store_data_m        ),
    .lsu_trigger_match_m ( lsu_trigger_match_m )
  );

  assign pmu_out = pmu_in;
  assign fir_out = fir_in;

endmodule
