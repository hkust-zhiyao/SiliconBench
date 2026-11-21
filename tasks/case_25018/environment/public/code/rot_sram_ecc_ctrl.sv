// SPDX-License-Identifier: Apache-2.0
// 8-Bank (8 x 256 x 39-bit = 8 KB) Hsiao SECDED Hard-SRAM Staging Controller

module rot_sram_ecc_ctrl
  import soc_ifc_pkg::*;
#(
  parameter int unsigned AXI_AW = 16,
  parameter int unsigned AXI_UW = 32
) (
  input  logic                         clk,
  input  logic                         rst_b,

  input  logic [1:0][31:0]             allow_axi_user_i,
  input  logic                         ecc_err_inj_en_i,
  input  logic [1:0]                   ecc_err_inj_mask_i,

  // AXI Subordinate Component Port (paired with axi_sub C_LAT = 2)
  input  logic                         axi_dv_i,
  input  logic [AXI_AW-1:0]            axi_addr_i,
  input  logic                         axi_write_i,
  input  logic [AXI_UW-1:0]            axi_user_i,
  input  logic [31:0]                  axi_wdata_i,
  input  logic [3:0]                   axi_wstrb_i,
  output logic                         axi_hld_o,
  output logic                         axi_rd_err_o,
  output logic                         axi_wr_err_o,
  output logic [31:0]                  axi_rdata_o,

  // Direct SHA-512 Accelerator Staging Read Port
  input  logic                         sha_sram_req_dv_i,
  input  logic [CPTRA_MBOX_ADDR_W-1:0] sha_sram_req_addr_i,
  output logic                         sha_sram_hold_o,
  output cptra_mbox_sram_resp_t        sha_sram_resp_o,
  output logic                         sha_sram_resp_dv_o,
  output logic                         sha_sram_resp_ecc_err_o,

  // Active SHA-512 Staging Window Protection
  input  logic                         sha_lock_active_i,
  input  logic [10:0]                  sha_lock_start_dword_i,
  input  logic [11:0]                  sha_lock_end_dword_i,

  // ECC Fault Telemetry Pulses
  output logic                         ecc_single_err_pulse_o,
  output logic                         ecc_double_err_pulse_o
);

  localparam int unsigned NUM_BANKS = 8;

  logic [38:0] enc_codeword_raw, enc_codeword;
  logic [63:0] bank_dout [NUM_BANKS];
  logic [63:0] bank_din, bank_bm;
  logic [NUM_BANKS-1:0] bank_men, bank_wen, bank_ren;
  logic [7:0]  bank_row_addr;

  logic        sha_win;
  logic [10:0] req_dword;
  logic [2:0]  req_bank, resp_bank_q;
  logic        sha_rd_q, axi_rd_q;

  assign sha_sram_hold_o = 1'b0;
  assign sha_win         = sha_sram_req_dv_i;
  assign axi_hld_o       = sha_win;

  assign axi_wr_err_o = axi_dv_i && axi_write_i && (axi_addr_i >= 16'h2000);

  caliptra_prim_secded_inv_39_32_enc u_ecc_enc (
    .data_i ( axi_wdata_i      ),
    .data_o ( enc_codeword_raw )
  );

  assign enc_codeword = enc_codeword_raw ^ {37'h0, (ecc_err_inj_en_i ? ecc_err_inj_mask_i : 2'b00)};

  always_comb begin
    req_dword = sha_win ? sha_sram_req_addr_i[10:0] : axi_addr_i[12:2];
    req_bank  = req_dword[10:8];
    bank_row_addr = req_dword[7:0];

    bank_din = {25'h0, enc_codeword};
    bank_bm  = 64'h0;
    for (int b = 0; b < 4; b++) begin
      bank_bm[b*8 +: 8] = {8{axi_wstrb_i[b]}};
    end
    bank_bm[38:32] = 7'h7F;

    bank_men = '0;
    bank_wen = '0;
    bank_ren = '0;
    if (sha_win) begin
      bank_men[req_bank] = 1'b1;
      bank_ren[req_bank] = 1'b1;
    end else if (axi_dv_i && (axi_addr_i < 16'h2000)) begin
      bank_men[req_bank] = 1'b1;
      bank_wen[req_bank] = axi_write_i;
      bank_ren[req_bank] = !axi_write_i;
    end
  end

  for (genvar k = 0; k < NUM_BANKS; k++) begin : g_bank
    RM_IHPSG13_1P_256x64_c2_bm_bist u_sram (
      .A_CLK       ( clk           ),
      .A_MEN       ( bank_men[k]   ),
      .A_WEN       ( bank_wen[k]   ),
      .A_REN       ( bank_ren[k]   ),
      .A_ADDR      ( bank_row_addr ),
      .A_DIN       ( bank_din      ),
      .A_DLY       ( 1'b1          ),
      .A_DOUT      ( bank_dout[k]  ),
      .A_BM        ( bank_bm       ),
      .A_BIST_CLK  ( 1'b0          ),
      .A_BIST_EN   ( 1'b0          ),
      .A_BIST_MEN  ( 1'b0          ),
      .A_BIST_WEN  ( 1'b0          ),
      .A_BIST_REN  ( 1'b0          ),
      .A_BIST_ADDR ( 8'h00         ),
      .A_BIST_DIN  ( 64'h0         ),
      .A_BIST_BM   ( 64'h0         )
    );
  end

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      resp_bank_q <= 3'd0;
      sha_rd_q    <= 1'b0;
      axi_rd_q    <= 1'b0;
    end else begin
      resp_bank_q <= req_bank;
      sha_rd_q    <= sha_win;
      axi_rd_q    <= !sha_win && axi_dv_i && !axi_write_i;
    end
  end

  logic [31:0] dec_data;
  logic [6:0]  dec_syndrome;
  logic [1:0]  dec_err;

  caliptra_prim_secded_inv_39_32_dec u_ecc_dec (
    .data_i     ( bank_dout[resp_bank_q][38:0] ),
    .data_o     ( dec_data                     ),
    .syndrome_o ( dec_syndrome                 ),
    .err_o      ( dec_err                      )
  );

  assign axi_rdata_o             = dec_data;
  assign axi_rd_err_o            = axi_rd_q && dec_err[1];
  assign sha_sram_resp_o.rdata   = {dec_syndrome, dec_data};
  assign sha_sram_resp_dv_o      = sha_rd_q;
  assign sha_sram_resp_ecc_err_o = sha_rd_q && dec_err[1];
  assign ecc_single_err_pulse_o  = (sha_rd_q || axi_rd_q) && dec_err[0];
  assign ecc_double_err_pulse_o  = (sha_rd_q || axi_rd_q) && dec_err[1];

  wire _unused_ok = &{1'b0, allow_axi_user_i, sha_lock_active_i, sha_lock_start_dword_i, sha_lock_end_dword_i};

endmodule
