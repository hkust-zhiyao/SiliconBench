// SPDX-License-Identifier: Apache-2.0
`include "common_defines.vh"
module top
import el2_pkg::*;
#(
`include "el2_param.vh"
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // PMP CSR read/write interface
  input  logic        dec_csr_wen_r_mod,
  input  logic [11:0] dec_csr_wraddr_r,
  input  logic [31:0] dec_csr_wrdata_r,
  input  logic [11:0] dec_csr_rdaddr_d,
  input  logic        csr_pmpcfg,
  input  logic        csr_pmpaddr0,
  input  logic        csr_pmpaddr16,
  input  logic        csr_pmpaddr32,
  input  logic        csr_pmpaddr48,
  input  logic        mseccfg_rlb,
  input  logic        mseccfg_mmwp,
  input  logic        mseccfg_mml,
  input  logic        priv_mode_ns,
  input  logic        priv_mode_eff,
  output logic [31:0] dec_pmp_rddata_d,
  output logic        dec_pmp_read_d,

  // 3-channel PMP access check interface
  input  logic [31:0] pmp_chan_addr_0,
  input  logic [31:0] pmp_chan_addr_1,
  input  logic [31:0] pmp_chan_addr_2,
  input  logic [2:0]  pmp_chan_type_0,
  input  logic [2:0]  pmp_chan_type_1,
  input  logic [2:0]  pmp_chan_type_2,
  output logic        pmp_chan_err_0,
  output logic        pmp_chan_err_1,
  output logic        pmp_chan_err_2,

  // Transparent 8-bit zero-cut sideband channels
  input  logic [7:0]  fault_in,
  output logic [7:0]  fault_out,
  input  logic [7:0]  trace_in,
  output logic [7:0]  trace_out
);

  el2_mseccfg_pkt_t mseccfg_pkt;
  assign mseccfg_pkt.RLB  = mseccfg_rlb;
  assign mseccfg_pkt.MMWP = mseccfg_mmwp;
  assign mseccfg_pkt.MML  = mseccfg_mml;

  el2_pmp_cfg_pkt_t  pmp_pmpcfg  [pt.PMP_ENTRIES];
  logic [31:0]       pmp_pmpaddr [pt.PMP_ENTRIES];

  logic [31:0]       chan_addr [3];
  el2_pmp_type_pkt_t chan_type [3];
  logic              chan_err  [3];

  assign chan_addr[0] = pmp_chan_addr_0;
  assign chan_addr[1] = pmp_chan_addr_1;
  assign chan_addr[2] = pmp_chan_addr_2;
  assign chan_type[0] = el2_pmp_type_pkt_t'(pmp_chan_type_0);
  assign chan_type[1] = el2_pmp_type_pkt_t'(pmp_chan_type_1);
  assign chan_type[2] = el2_pmp_type_pkt_t'(pmp_chan_type_2);
  assign pmp_chan_err_0 = chan_err[0];
  assign pmp_chan_err_1 = chan_err[1];
  assign pmp_chan_err_2 = chan_err[2];

  el2_dec_pmp_ctl #(
    .pt ( pt )
  ) u_pmp_ctl (
    .clk                      ( clk_i             ),
    .free_l2clk               ( clk_i             ),
    .csr_wr_clk               ( clk_i             ),
    .rst_l                    ( rst_ni            ),
    .dec_csr_wen_r_mod        ( dec_csr_wen_r_mod ),
    .dec_csr_wraddr_r         ( dec_csr_wraddr_r  ),
    .dec_csr_wrdata_r         ( dec_csr_wrdata_r  ),
    .dec_csr_rdaddr_d         ( dec_csr_rdaddr_d  ),
    .csr_pmpcfg               ( csr_pmpcfg        ),
    .csr_pmpaddr0             ( csr_pmpaddr0      ),
    .csr_pmpaddr16            ( csr_pmpaddr16     ),
    .csr_pmpaddr32            ( csr_pmpaddr32     ),
    .csr_pmpaddr48            ( csr_pmpaddr48     ),
    .dec_pause_state          ( 1'b0              ),
    .dec_tlu_pmu_fw_halted    ( 1'b0              ),
    .internal_dbg_halt_timers ( 1'b0              ),
    .mseccfg                  ( mseccfg_pkt       ),
    .dec_pmp_rddata_d         ( dec_pmp_rddata_d  ),
    .dec_pmp_read_d           ( dec_pmp_read_d    ),
    .pmp_pmpcfg               ( pmp_pmpcfg        ),
    .pmp_pmpaddr              ( pmp_pmpaddr       ),
    .scan_mode                ( 1'b0              )
  );

  el2_pmp #(
    .PMP_CHANNELS    ( 3  ),
    .PMP_GRANULARITY ( 0  ),
    .pt              ( pt )
  ) u_pmp (
    .clk           ( clk_i         ),
    .rst_l         ( rst_ni        ),
    .scan_mode     ( 1'b0          ),
    .mseccfg       ( mseccfg_pkt   ),
    .priv_mode_ns  ( priv_mode_ns  ),
    .priv_mode_eff ( priv_mode_eff ),
    .pmp_pmpcfg    ( pmp_pmpcfg    ),
    .pmp_pmpaddr   ( pmp_pmpaddr   ),
    .pmp_chan_addr ( chan_addr     ),
    .pmp_chan_type ( chan_type     ),
    .pmp_chan_err  ( chan_err      )
  );

  assign fault_out = fault_in;
  assign trace_out = trace_in;

endmodule
