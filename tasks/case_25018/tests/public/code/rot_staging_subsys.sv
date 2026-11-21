// SPDX-License-Identifier: Apache-2.0
// Caliptra RoT 8-Macro SECDED Staging Memory & SHA-512 Direct-Read Subsystem

module rot_staging_subsys
  import axi_pkg::*;
  import soc_ifc_pkg::*;
#(
  parameter int unsigned AXI_AW = 16,
  parameter int unsigned AXI_DW = 32,
  parameter int unsigned AXI_IW = 4,
  parameter int unsigned AXI_UW = 32
) (
  input  logic              clk,
  input  logic              rst_b,
  input  logic              cptra_pwrgood,

  // Allowed AXI_USER identities for staging SRAM access
  input  logic [1:0][31:0]  allow_axi_user_i,

  // Hardware ECC fault-injection test hook (applied on write encode when enabled)
  input  logic              ecc_err_inj_en_i,
  input  logic [1:0]        ecc_err_inj_mask_i,

  // AXI4 Staging Subordinate Write Channels
  input  logic [AXI_AW-1:0] s_axi_awaddr_i,
  input  logic [1:0]        s_axi_awburst_i,
  input  logic [2:0]        s_axi_awsize_i,
  input  logic [7:0]        s_axi_awlen_i,
  input  logic [AXI_UW-1:0] s_axi_awuser_i,
  input  logic [AXI_IW-1:0] s_axi_awid_i,
  input  logic              s_axi_awlock_i,
  input  logic              s_axi_awvalid_i,
  output logic              s_axi_awready_o,

  input  logic [AXI_DW-1:0]   s_axi_wdata_i,
  input  logic [AXI_DW/8-1:0] s_axi_wstrb_i,
  input  logic                s_axi_wlast_i,
  input  logic                s_axi_wvalid_i,
  output logic                s_axi_wready_o,

  output logic [1:0]        s_axi_bresp_o,
  output logic [AXI_IW-1:0] s_axi_bid_o,
  output logic              s_axi_bvalid_o,
  input  logic              s_axi_bready_i,

  // AXI4 Staging Subordinate Read Channels
  input  logic [AXI_AW-1:0] s_axi_araddr_i,
  input  logic [1:0]        s_axi_arburst_i,
  input  logic [2:0]        s_axi_arsize_i,
  input  logic [7:0]        s_axi_arlen_i,
  input  logic [AXI_UW-1:0] s_axi_aruser_i,
  input  logic [AXI_IW-1:0] s_axi_arid_i,
  input  logic              s_axi_arlock_i,
  input  logic              s_axi_arvalid_i,
  output logic              s_axi_arready_o,

  output logic [AXI_DW-1:0] s_axi_rdata_o,
  output logic [1:0]        s_axi_rresp_o,
  output logic [AXI_IW-1:0] s_axi_rid_o,
  output logic              s_axi_rlast_o,
  output logic              s_axi_rvalid_o,
  input  logic              s_axi_rready_i,

  // SHA-512 Accelerator CSR Request Interface
  input  logic                      csr_req_dv_i,
  output logic                      csr_req_hold_o,
  input  logic [SOC_IFC_ADDR_W-1:0] csr_req_addr_i,
  input  logic [31:0]               csr_req_wdata_i,
  input  logic [3:0]                csr_req_wstrb_i,
  input  logic [31:0]               csr_req_user_i,
  input  logic [SOC_IFC_ID_W-1:0]   csr_req_id_i,
  input  logic                      csr_req_write_i,
  input  logic                      csr_req_soc_i,
  output logic [31:0]               csr_rdata_o,
  output logic                      csr_err_o,

  // Interrupts & ECC Telemetry
  output logic              sha_error_intr_o,
  output logic              sha_notif_intr_o,
  output logic              sha_fsm_error_o,
  output logic              ecc_single_err_pulse_o,
  output logic              ecc_double_err_pulse_o
);

  axi_if #(
    .AW ( AXI_AW ),
    .DW ( AXI_DW ),
    .IW ( AXI_IW ),
    .UW ( AXI_UW )
  ) u_axi_if (
    .clk   ( clk   ),
    .rst_n ( rst_b )
  );

  assign u_axi_if.awaddr   = s_axi_awaddr_i;
  assign u_axi_if.awburst  = s_axi_awburst_i;
  assign u_axi_if.awsize   = s_axi_awsize_i;
  assign u_axi_if.awlen    = s_axi_awlen_i;
  assign u_axi_if.awuser   = s_axi_awuser_i;
  assign u_axi_if.awid     = s_axi_awid_i;
  assign u_axi_if.awlock   = s_axi_awlock_i;
  assign u_axi_if.awcache  = 4'h0;
  assign u_axi_if.awprot   = 3'h0;
  assign u_axi_if.awqos    = 4'h0;
  assign u_axi_if.awregion = 4'h0;
  assign u_axi_if.awvalid  = s_axi_awvalid_i;
  assign s_axi_awready_o   = u_axi_if.awready;

  assign u_axi_if.wdata    = s_axi_wdata_i;
  assign u_axi_if.wstrb    = s_axi_wstrb_i;
  assign u_axi_if.wuser    = '0;
  assign u_axi_if.wlast    = s_axi_wlast_i;
  assign u_axi_if.wvalid   = s_axi_wvalid_i;
  assign s_axi_wready_o    = u_axi_if.wready;

  assign s_axi_bresp_o     = u_axi_if.bresp;
  assign s_axi_bid_o       = u_axi_if.bid;
  assign s_axi_bvalid_o    = u_axi_if.bvalid;
  assign u_axi_if.bready   = s_axi_bready_i;

  assign u_axi_if.araddr   = s_axi_araddr_i;
  assign u_axi_if.arburst  = s_axi_arburst_i;
  assign u_axi_if.arsize   = s_axi_arsize_i;
  assign u_axi_if.arlen    = s_axi_arlen_i;
  assign u_axi_if.aruser   = s_axi_aruser_i;
  assign u_axi_if.arid     = s_axi_arid_i;
  assign u_axi_if.arlock   = s_axi_arlock_i;
  assign u_axi_if.arcache  = 4'h0;
  assign u_axi_if.arprot   = 3'h0;
  assign u_axi_if.arqos    = 4'h0;
  assign u_axi_if.arregion = 4'h0;
  assign u_axi_if.arvalid  = s_axi_arvalid_i;
  assign s_axi_arready_o   = u_axi_if.arready;

  assign s_axi_rdata_o     = u_axi_if.rdata;
  assign s_axi_rresp_o     = u_axi_if.rresp;
  assign s_axi_rid_o       = u_axi_if.rid;
  assign s_axi_rlast_o     = u_axi_if.rlast;
  assign s_axi_rvalid_o    = u_axi_if.rvalid;
  assign u_axi_if.rready   = s_axi_rready_i;

  logic              comp_dv, comp_write, comp_last, comp_hld, comp_rd_err, comp_wr_err;
  logic [AXI_AW-1:0] comp_addr;
  logic [AXI_UW-1:0] comp_user;
  logic [AXI_IW-1:0] comp_id;
  logic [AXI_DW-1:0] comp_wdata, comp_rdata;
  logic [3:0]        comp_wstrb;
  logic [2:0]        comp_size;

  axi_sub #(
    .AW    ( AXI_AW ),
    .DW    ( AXI_DW ),
    .UW    ( AXI_UW ),
    .IW    ( AXI_IW ),
    .EX_EN ( 0      ),
    .C_LAT ( 2      )
  ) u_axi_sub (
    .clk        ( clk        ),
    .rst_n      ( rst_b      ),
    .s_axi_w_if ( u_axi_if   ),
    .s_axi_r_if ( u_axi_if   ),
    .dv         ( comp_dv    ),
    .addr       ( comp_addr  ),
    .write      ( comp_write ),
    .user       ( comp_user  ),
    .id         ( comp_id    ),
    .wdata      ( comp_wdata ),
    .wstrb      ( comp_wstrb ),
    .size       ( comp_size  ),
    .rdata      ( comp_rdata ),
    .last       ( comp_last  ),
    .hld        ( comp_hld   ),
    .rd_err     ( comp_rd_err),
    .wr_err     ( comp_wr_err)
  );

  logic                         sha_sram_req_dv;
  logic [CPTRA_MBOX_ADDR_W-1:0] sha_sram_req_addr;
  cptra_mbox_sram_resp_t        sha_sram_resp;
  logic                         sha_sram_hold;
  logic                         sha_sram_resp_dv;
  logic                         sha_sram_resp_ecc_err;
  logic                         sha_lock_active;
  logic [10:0]                  sha_lock_start_dword;
  logic [11:0]                  sha_lock_end_dword;

  rot_sram_ecc_ctrl #(
    .AXI_AW ( AXI_AW ),
    .AXI_UW ( AXI_UW )
  ) u_sram_ctrl (
    .clk                    ( clk                    ),
    .rst_b                  ( rst_b                  ),
    .allow_axi_user_i       ( allow_axi_user_i       ),
    .ecc_err_inj_en_i       ( ecc_err_inj_en_i       ),
    .ecc_err_inj_mask_i     ( ecc_err_inj_mask_i     ),
    .axi_dv_i               ( comp_dv                ),
    .axi_addr_i             ( comp_addr              ),
    .axi_write_i            ( comp_write             ),
    .axi_user_i             ( comp_user              ),
    .axi_wdata_i            ( comp_wdata             ),
    .axi_wstrb_i            ( comp_wstrb             ),
    .axi_hld_o              ( comp_hld               ),
    .axi_rd_err_o           ( comp_rd_err            ),
    .axi_wr_err_o           ( comp_wr_err            ),
    .axi_rdata_o            ( comp_rdata             ),
    .sha_sram_req_dv_i      ( sha_sram_req_dv        ),
    .sha_sram_req_addr_i    ( sha_sram_req_addr      ),
    .sha_sram_hold_o        ( sha_sram_hold          ),
    .sha_sram_resp_o        ( sha_sram_resp          ),
    .sha_sram_resp_dv_o     ( sha_sram_resp_dv       ),
    .sha_sram_resp_ecc_err_o( sha_sram_resp_ecc_err  ),
    .sha_lock_active_i      ( sha_lock_active        ),
    .sha_lock_start_dword_i ( sha_lock_start_dword   ),
    .sha_lock_end_dword_i   ( sha_lock_end_dword     ),
    .ecc_single_err_pulse_o ( ecc_single_err_pulse_o ),
    .ecc_double_err_pulse_o ( ecc_double_err_pulse_o )
  );

  soc_ifc_req_t csr_req;
  always_comb begin
    csr_req         = '0;
    csr_req.addr    = csr_req_addr_i;
    csr_req.wdata   = csr_req_wdata_i;
    csr_req.wstrb   = csr_req_wstrb_i;
    csr_req.user    = csr_req_user_i;
    csr_req.id      = csr_req_id_i;
    csr_req.write   = csr_req_write_i;
    csr_req.soc_req = csr_req_soc_i;
  end

  sha512_acc_top #(
    .DATA_WIDTH ( 32 )
  ) u_sha512_acc (
    .clk                   ( clk                   ),
    .rst_b                 ( rst_b                 ),
    .cptra_pwrgood         ( cptra_pwrgood         ),
    .req_dv                ( csr_req_dv_i          ),
    .req_hold              ( csr_req_hold_o        ),
    .req_data              ( csr_req               ),
    .rdata                 ( csr_rdata_o           ),
    .err                   ( csr_err_o             ),
    .sha_sram_req_dv       ( sha_sram_req_dv       ),
    .sha_sram_req_addr     ( sha_sram_req_addr     ),
    .sha_sram_resp         ( sha_sram_resp         ),
    .sha_sram_hold         ( sha_sram_hold         ),
    .sha_sram_resp_dv      ( sha_sram_resp_dv      ),
    .sha_sram_resp_ecc_err ( sha_sram_resp_ecc_err ),
    .sha_lock_active_o     ( sha_lock_active       ),
    .sha_lock_start_dword_o( sha_lock_start_dword  ),
    .sha_lock_end_dword_o  ( sha_lock_end_dword    ),
    .iccm_hash_dv_i        ( 1'b0                  ),
    .iccm_hash_data_i      ( 32'h0                 ),
    .iccm_lock_i           ( 1'b0                  ),
    .iccm_unlock_i         ( 1'b0                  ),
    .pv_write_o            (                       ),
    .pv_read_o             (                       ),
    .pv_rd_resp_i          ( '0                    ),
    .sha_fsm_error         ( sha_fsm_error_o       ),
    .error_intr            ( sha_error_intr_o      ),
    .notif_intr            ( sha_notif_intr_o      )
  );

  wire _unused_ok = &{1'b0, comp_id, comp_size, comp_last};

endmodule
