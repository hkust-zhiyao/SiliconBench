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

  typedef enum logic [1:0] {
    RMW_IDLE   = 2'd0,
    RMW_RD_S1  = 2'd1,
    RMW_DEC_S2 = 2'd2,
    RMW_WR_S3  = 2'd3
  } rmw_state_e;

  rmw_state_e  rmw_state_q, rmw_state_d;
  logic [31:0] rmw_merged_q, rmw_merged_d;

  logic        scrub_valid_q;
  logic [10:0] scrub_dword_q;
  logic [31:0] scrub_data_q;

  logic        axi_user_ok, axi_addr_ok, axi_locked, axi_rd_legal, axi_wr_legal;
  logic        axi_subword_rmw;
  logic [10:0] axi_dword;

  assign axi_user_ok  = (axi_user_i == allow_axi_user_i[0]) || (axi_user_i == allow_axi_user_i[1]);
  assign axi_addr_ok  = (axi_addr_i < 16'h2000);
  assign axi_dword    = axi_addr_i[12:2];
  assign axi_locked   = sha_lock_active_i &&
                        ({1'b0, axi_dword} >= {1'b0, sha_lock_start_dword_i}) &&
                        ({1'b0, axi_dword} < sha_lock_end_dword_i);
  assign axi_rd_legal = axi_user_ok && axi_addr_ok;
  assign axi_wr_legal = axi_user_ok && axi_addr_ok && !axi_locked;
  assign axi_subword_rmw = axi_wr_legal && (axi_wstrb_i != 4'hF) && (axi_wstrb_i != 4'h0);

  // Stage-1 / Stage-2 registered read & SECDED decode pipeline (C_LAT = 2)
  logic        s1_sha_rd_q, s1_axi_rd_q, s1_axi_err_q;
  logic [10:0] s1_dword_q;
  logic        s2_sha_rd_q, s2_axi_rd_q, s2_axi_err_q;
  logic [10:0] s2_dword_q;
  logic [38:0] s2_codeword_q;

  logic [31:0] dec_data;
  logic [6:0]  dec_syndrome;
  logic [1:0]  dec_err;

  caliptra_prim_secded_inv_39_32_dec u_ecc_dec (
    .data_i     ( s2_codeword_q ),
    .data_o     ( dec_data      ),
    .syndrome_o ( dec_syndrome  ),
    .err_o      ( dec_err       )
  );

  // Hold & arbitration logic
  logic sram_busy_maint;
  logic sha_grant;
  assign sram_busy_maint = scrub_valid_q || (rmw_state_q != RMW_IDLE);
  assign sha_sram_hold_o = sram_busy_maint;
  assign sha_grant       = sha_sram_req_dv_i && !sha_sram_hold_o;

  always_comb begin
    axi_hld_o    = 1'b0;
    axi_wr_err_o = 1'b0;
    rmw_state_d  = rmw_state_q;
    rmw_merged_d = rmw_merged_q;

    unique case (rmw_state_q)
      RMW_IDLE: begin
        if (scrub_valid_q || sha_grant) begin
          axi_hld_o = 1'b1;
        end else if (axi_dv_i && axi_write_i) begin
          if (!axi_wr_legal) begin
            axi_hld_o    = 1'b0;
            axi_wr_err_o = 1'b1;
          end else if (axi_subword_rmw) begin
            axi_hld_o   = 1'b1;
            rmw_state_d = RMW_RD_S1;
          end
        end
      end
      RMW_RD_S1: begin
        axi_hld_o   = 1'b1;
        rmw_state_d = RMW_DEC_S2;
      end
      RMW_DEC_S2: begin
        for (int b = 0; b < 4; b++) begin
          rmw_merged_d[b*8 +: 8] = axi_wstrb_i[b] ? axi_wdata_i[b*8 +: 8] : dec_data[b*8 +: 8];
        end
        if (dec_err[1]) begin
          // Uncorrectable 2-bit ECC fault on pre-write read: abort RMW without writing SRAM
          axi_hld_o    = 1'b0;
          axi_wr_err_o = 1'b1;
          rmw_state_d  = RMW_IDLE;
        end else begin
          axi_hld_o   = 1'b1;
          rmw_state_d = RMW_WR_S3;
        end
      end
      RMW_WR_S3: begin
        axi_hld_o    = 1'b0;
        axi_wr_err_o = 1'b0;
        rmw_state_d  = RMW_IDLE;
      end
      default: rmw_state_d = RMW_IDLE;
    endcase
  end

  // Encode path (shared by full-dword AXI write, RMW writeback, and clean single-bit scrub)
  logic [31:0] enc_data_in;
  logic [38:0] enc_codeword_raw, enc_codeword;
  logic        enc_apply_inj;

  assign enc_data_in   = scrub_valid_q ? scrub_data_q :
                         (rmw_state_q == RMW_WR_S3) ? rmw_merged_q : axi_wdata_i;
  assign enc_apply_inj = !scrub_valid_q && ecc_err_inj_en_i;

  caliptra_prim_secded_inv_39_32_enc u_ecc_enc (
    .data_i ( enc_data_in      ),
    .data_o ( enc_codeword_raw )
  );

  assign enc_codeword = enc_codeword_raw ^ {37'h0, (enc_apply_inj ? ecc_err_inj_mask_i : 2'b00)};

  logic [63:0]          bank_dout [NUM_BANKS];
  logic [63:0]          bank_din, bank_bm;
  logic [NUM_BANKS-1:0] bank_men, bank_wen, bank_ren;
  logic [10:0]          sram_dword;
  logic [2:0]           sram_bank;
  logic [7:0]           sram_row;
  logic                 axi_accept_rd, axi_accept_full_wr, rmw_launch_rd;

  assign axi_accept_rd      = (rmw_state_q == RMW_IDLE) && !scrub_valid_q && !sha_grant && axi_dv_i && !axi_write_i;
  assign axi_accept_full_wr = (rmw_state_q == RMW_IDLE) && !scrub_valid_q && !sha_grant &&
                              axi_dv_i && axi_write_i && axi_wr_legal && (axi_wstrb_i == 4'hF);
  assign rmw_launch_rd      = (rmw_state_q == RMW_IDLE) && !scrub_valid_q && !sha_grant &&
                              axi_dv_i && axi_write_i && axi_subword_rmw;

  always_comb begin
    if (scrub_valid_q)                   sram_dword = scrub_dword_q;
    else if (sha_grant)                  sram_dword = sha_sram_req_addr_i[10:0];
    else                                 sram_dword = axi_dword;

    sram_bank = sram_dword[10:8];
    sram_row  = sram_dword[7:0];
    bank_din  = {25'h0, enc_codeword};
    bank_bm   = 64'h0000_007F_FFFF_FFFF;

    bank_men  = '0;
    bank_wen  = '0;
    bank_ren  = '0;

    if (scrub_valid_q || (rmw_state_q == RMW_WR_S3) || axi_accept_full_wr) begin
      bank_men[sram_bank] = 1'b1;
      bank_wen[sram_bank] = 1'b1;
    end else if (sha_grant || (axi_accept_rd && axi_rd_legal) || rmw_launch_rd) begin
      bank_men[sram_bank] = 1'b1;
      bank_ren[sram_bank] = 1'b1;
    end
  end

  for (genvar k = 0; k < NUM_BANKS; k++) begin : g_bank
    RM_IHPSG13_1P_256x64_c2_bm_bist u_sram (
      .A_CLK       ( clk          ),
      .A_MEN       ( bank_men[k]  ),
      .A_WEN       ( bank_wen[k]  ),
      .A_REN       ( bank_ren[k]  ),
      .A_ADDR      ( sram_row     ),
      .A_DIN       ( bank_din     ),
      .A_DLY       ( 1'b1         ),
      .A_DOUT      ( bank_dout[k] ),
      .A_BM        ( bank_bm      ),
      .A_BIST_CLK  ( 1'b0         ),
      .A_BIST_EN   ( 1'b0         ),
      .A_BIST_MEN  ( 1'b0         ),
      .A_BIST_WEN  ( 1'b0         ),
      .A_BIST_REN  ( 1'b0         ),
      .A_BIST_ADDR ( 8'h00        ),
      .A_BIST_DIN  ( 64'h0        ),
      .A_BIST_BM   ( 64'h0        )
    );
  end

  logic valid_rd_s2, single_fault_rd_s2, double_fault_rd_s2;
  assign valid_rd_s2        = s2_sha_rd_q || (s2_axi_rd_q && !s2_axi_err_q);
  assign single_fault_rd_s2 = valid_rd_s2 && (dec_err == 2'b01);
  assign double_fault_rd_s2 = valid_rd_s2 && dec_err[1];

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      rmw_state_q   <= RMW_IDLE;
      rmw_merged_q  <= 32'h0;
      s1_sha_rd_q   <= 1'b0;
      s1_axi_rd_q   <= 1'b0;
      s1_axi_err_q  <= 1'b0;
      s1_dword_q    <= 11'h0;
      s2_sha_rd_q   <= 1'b0;
      s2_axi_rd_q   <= 1'b0;
      s2_axi_err_q  <= 1'b0;
      s2_dword_q    <= 11'h0;
      s2_codeword_q <= 39'h0;
      scrub_valid_q <= 1'b0;
      scrub_dword_q <= 11'h0;
      scrub_data_q  <= 32'h0;
    end else begin
      rmw_state_q   <= rmw_state_d;
      rmw_merged_q  <= rmw_merged_d;

      s1_sha_rd_q   <= sha_grant;
      s1_axi_rd_q   <= axi_accept_rd;
      s1_axi_err_q  <= axi_accept_rd && !axi_rd_legal;
      if (sha_grant || axi_accept_rd || rmw_launch_rd) begin
        s1_dword_q <= sram_dword;
      end

      s2_sha_rd_q   <= s1_sha_rd_q;
      s2_axi_rd_q   <= s1_axi_rd_q;
      s2_axi_err_q  <= s1_axi_err_q;
      s2_dword_q    <= s1_dword_q;
      if (s1_sha_rd_q || (s1_axi_rd_q && !s1_axi_err_q) || (rmw_state_q == RMW_RD_S1)) begin
        s2_codeword_q <= bank_dout[s1_dword_q[10:8]][38:0];
      end

      scrub_valid_q <= single_fault_rd_s2;
      if (single_fault_rd_s2) begin
        scrub_dword_q <= s2_dword_q;
        scrub_data_q  <= dec_data;
      end
    end
  end

  assign axi_rd_err_o            = s2_axi_rd_q && (s2_axi_err_q || dec_err[1]);
  assign axi_rdata_o             = (s2_axi_rd_q && !axi_rd_err_o) ? dec_data : 32'h0;
  assign sha_sram_resp_o.rdata   = {dec_syndrome, dec_data};
  assign sha_sram_resp_dv_o      = s2_sha_rd_q;
  assign sha_sram_resp_ecc_err_o = s2_sha_rd_q && dec_err[1];

  assign ecc_single_err_pulse_o  = single_fault_rd_s2 || ((rmw_state_q == RMW_DEC_S2) && (dec_err == 2'b01));
  assign ecc_double_err_pulse_o  = double_fault_rd_s2 || ((rmw_state_q == RMW_DEC_S2) && dec_err[1]);

  wire _unused_ok = &{1'b0, sha_sram_req_addr_i[CPTRA_MBOX_ADDR_W-1:11], axi_addr_i[1:0], axi_addr_i[AXI_AW-1:13]};

endmodule
