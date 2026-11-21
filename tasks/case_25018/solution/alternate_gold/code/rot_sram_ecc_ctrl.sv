// SPDX-License-Identifier: Apache-2.0
// Alternate Gold: One-Hot Bank Reduction & Latched-Beat RMW SECDED Controller

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

  input  logic                         sha_sram_req_dv_i,
  input  logic [CPTRA_MBOX_ADDR_W-1:0] sha_sram_req_addr_i,
  output logic                         sha_sram_hold_o,
  output cptra_mbox_sram_resp_t        sha_sram_resp_o,
  output logic                         sha_sram_resp_dv_o,
  output logic                         sha_sram_resp_ecc_err_o,

  input  logic                         sha_lock_active_i,
  input  logic [10:0]                  sha_lock_start_dword_i,
  input  logic [11:0]                  sha_lock_end_dword_i,

  output logic                         ecc_single_err_pulse_o,
  output logic                         ecc_double_err_pulse_o
);

  localparam int unsigned NUM_BANKS = 8;

  logic [31:0] rmw_wdata_q, rmw_merged_q;
  logic [3:0]  rmw_wstrb_q;
  logic [10:0] rmw_dword_q;
  logic [3:0]  rmw_phase_q; // one-hot: [0]=IDLE, [1]=RD, [2]=DEC, [3]=WB

  logic        scrub_pend_q;
  logic [10:0] scrub_addr_q;
  logic [31:0] scrub_word_q;

  wire user_authorized = (axi_user_i == allow_axi_user_i[0]) || (axi_user_i == allow_axi_user_i[1]);
  wire addr_in_range   = ~|axi_addr_i[AXI_AW-1:13];
  wire [10:0] axi_dw   = axi_addr_i[12:2];
  wire wr_win_locked   = sha_lock_active_i &&
                         ({1'b0, axi_dw} >= {1'b0, sha_lock_start_dword_i}) &&
                         ({1'b0, axi_dw} < sha_lock_end_dword_i);

  wire rd_permitted = user_authorized && addr_in_range;
  wire wr_permitted = user_authorized && addr_in_range && !wr_win_locked;
  wire need_rmw     = wr_permitted && (|axi_wstrb_i) && (&axi_wstrb_i == 1'b0);

  logic [NUM_BANKS-1:0] s1_bank_oh_q;
  logic [10:0]          s1_addr_q, s2_addr_q;
  logic                 s1_is_sha_q, s1_is_axi_q, s1_axi_bad_q;
  logic                 s2_is_sha_q, s2_is_axi_q, s2_axi_bad_q;
  logic [38:0]          s2_cw_q;

  logic [63:0] bank_dout [NUM_BANKS];
  logic [38:0] muxed_s1_cw;
  always_comb begin
    muxed_s1_cw = 39'h0;
    for (int i = 0; i < NUM_BANKS; i++) begin
      if (s1_bank_oh_q[i]) muxed_s1_cw |= bank_dout[i][38:0];
    end
  end

  logic [31:0] dec_word;
  logic [6:0]  dec_synd;
  logic [1:0]  dec_flags;

  caliptra_prim_secded_inv_39_32_dec u_secded_dec (
    .data_i     ( s2_cw_q   ),
    .data_o     ( dec_word  ),
    .syndrome_o ( dec_synd  ),
    .err_o      ( dec_flags )
  );

  assign sha_sram_hold_o = scrub_pend_q || !rmw_phase_q[0];
  wire sha_take = sha_sram_req_dv_i && !sha_sram_hold_o;

  always_comb begin
    axi_hld_o    = 1'b0;
    axi_wr_err_o = 1'b0;
    if (rmw_phase_q[0]) begin
      if (scrub_pend_q || sha_take) begin
        axi_hld_o = 1'b1;
      end else if (axi_dv_i && axi_write_i) begin
        if (!wr_permitted) axi_wr_err_o = 1'b1;
        else if (need_rmw) axi_hld_o    = 1'b1;
      end
    end else if (rmw_phase_q[1]) begin
      axi_hld_o = 1'b1;
    end else if (rmw_phase_q[2]) begin
      if (dec_flags[1]) begin
        axi_hld_o    = 1'b0;
        axi_wr_err_o = 1'b1;
      end else begin
        axi_hld_o = 1'b1;
      end
    end
  end

  wire [31:0] enc_src = scrub_pend_q   ? scrub_word_q :
                        rmw_phase_q[3] ? rmw_merged_q : axi_wdata_i;
  logic [38:0] enc_raw, enc_final;

  caliptra_prim_secded_inv_39_32_enc u_secded_enc (
    .data_i ( enc_src ),
    .data_o ( enc_raw )
  );

  assign enc_final = enc_raw ^ {37'h0, ((!scrub_pend_q && ecc_err_inj_en_i) ? ecc_err_inj_mask_i : 2'b00)};

  wire launch_axi_rd  = rmw_phase_q[0] && !scrub_pend_q && !sha_take && axi_dv_i && !axi_write_i;
  wire launch_full_wr = rmw_phase_q[0] && !scrub_pend_q && !sha_take && axi_dv_i && axi_write_i && wr_permitted && (&axi_wstrb_i);
  wire launch_rmw_rd  = rmw_phase_q[0] && !scrub_pend_q && !sha_take && axi_dv_i && axi_write_i && need_rmw;

  wire [10:0] active_dw = scrub_pend_q   ? scrub_addr_q :
                          rmw_phase_q[3] ? rmw_dword_q  :
                          sha_take       ? sha_sram_req_addr_i[10:0] : axi_dw;

  logic [NUM_BANKS-1:0] b_men, b_wen, b_ren;
  always_comb begin
    b_men = '0; b_wen = '0; b_ren = '0;
    if (scrub_pend_q || rmw_phase_q[3] || launch_full_wr) begin
      b_men[active_dw[10:8]] = 1'b1;
      b_wen[active_dw[10:8]] = 1'b1;
    end else if (sha_take || (launch_axi_rd && rd_permitted) || launch_rmw_rd) begin
      b_men[active_dw[10:8]] = 1'b1;
      b_ren[active_dw[10:8]] = 1'b1;
    end
  end

  for (genvar g = 0; g < NUM_BANKS; g++) begin : g_bank
    RM_IHPSG13_1P_256x64_c2_bm_bist u_sram (
      .A_CLK(clk), .A_MEN(b_men[g]), .A_WEN(b_wen[g]), .A_REN(b_ren[g]),
      .A_ADDR(active_dw[7:0]), .A_DIN({25'h0, enc_final}), .A_DLY(1'b1),
      .A_DOUT(bank_dout[g]), .A_BM(64'h0000_007F_FFFF_FFFF),
      .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0),
      .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(8'h0),
      .A_BIST_DIN(64'h0), .A_BIST_BM(64'h0)
    );
  end

  wire s2_good_rd   = s2_is_sha_q || (s2_is_axi_q && !s2_axi_bad_q);
  wire s2_corr_err  = s2_good_rd && (dec_flags == 2'b01);
  wire s2_uncor_err = s2_good_rd && dec_flags[1];

  always_ff @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      rmw_phase_q  <= 4'b0001;
      rmw_wdata_q  <= 32'h0;
      rmw_wstrb_q  <= 4'h0;
      rmw_dword_q  <= 11'h0;
      rmw_merged_q <= 32'h0;
      s1_bank_oh_q <= '0;
      s1_addr_q    <= 11'h0;
      s1_is_sha_q  <= 1'b0;
      s1_is_axi_q  <= 1'b0;
      s1_axi_bad_q <= 1'b0;
      s2_addr_q    <= 11'h0;
      s2_is_sha_q  <= 1'b0;
      s2_is_axi_q  <= 1'b0;
      s2_axi_bad_q <= 1'b0;
      s2_cw_q      <= 39'h0;
      scrub_pend_q <= 1'b0;
      scrub_addr_q <= 11'h0;
      scrub_word_q <= 32'h0;
    end else begin
      if (rmw_phase_q[0]) begin
        if (launch_rmw_rd) begin
          rmw_phase_q <= 4'b0010;
          rmw_wdata_q <= axi_wdata_i;
          rmw_wstrb_q <= axi_wstrb_i;
          rmw_dword_q <= axi_dw;
        end
      end else if (rmw_phase_q[1]) begin
        rmw_phase_q <= 4'b0100;
      end else if (rmw_phase_q[2]) begin
        for (int b = 0; b < 4; b++) begin
          rmw_merged_q[b*8 +: 8] <= rmw_wstrb_q[b] ? rmw_wdata_q[b*8 +: 8] : dec_word[b*8 +: 8];
        end
        rmw_phase_q <= dec_flags[1] ? 4'b0001 : 4'b1000;
      end else begin
        rmw_phase_q <= 4'b0001;
      end

      s1_is_sha_q  <= sha_take;
      s1_is_axi_q  <= launch_axi_rd;
      s1_axi_bad_q <= launch_axi_rd && !rd_permitted;
      if (sha_take || launch_axi_rd || launch_rmw_rd) begin
        s1_addr_q    <= active_dw;
        s1_bank_oh_q <= (8'd1 << active_dw[10:8]);
      end

      s2_is_sha_q  <= s1_is_sha_q;
      s2_is_axi_q  <= s1_is_axi_q;
      s2_axi_bad_q <= s1_axi_bad_q;
      s2_addr_q    <= s1_addr_q;
      if (s1_is_sha_q || (s1_is_axi_q && !s1_axi_bad_q) || rmw_phase_q[1]) begin
        s2_cw_q <= muxed_s1_cw;
      end

      scrub_pend_q <= s2_corr_err;
      if (s2_corr_err) begin
        scrub_addr_q <= s2_addr_q;
        scrub_word_q <= dec_word;
      end
    end
  end

  assign axi_rd_err_o            = s2_is_axi_q && (s2_axi_bad_q || dec_flags[1]);
  assign axi_rdata_o             = (s2_is_axi_q && !axi_rd_err_o) ? dec_word : 32'h0;
  assign sha_sram_resp_o.rdata   = {dec_synd, dec_word};
  assign sha_sram_resp_dv_o      = s2_is_sha_q;
  assign sha_sram_resp_ecc_err_o = s2_is_sha_q && dec_flags[1];
  assign ecc_single_err_pulse_o  = s2_corr_err  || (rmw_phase_q[2] && (dec_flags == 2'b01));
  assign ecc_double_err_pulse_o  = s2_uncor_err || (rmw_phase_q[2] && dec_flags[1]);

  wire _unused_alt = &{1'b0, sha_sram_req_addr_i[CPTRA_MBOX_ADDR_W-1:11], axi_addr_i[1:0]};

endmodule
