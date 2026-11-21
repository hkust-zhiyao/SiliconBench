// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================
// File Name: NV_NVDLA_CACC_assembly_buffer.v

module NV_NVDLA_CACC_assembly_buffer (
   input  wire        nvdla_core_clk
  ,input  wire        nvdla_core_rstn
  ,input  wire  [7:0] abuf_rd_addr
  ,input  wire  [7:0] abuf_rd_en
  ,input  wire  [7:0] abuf_wr_addr
  ,input  wire [47:0] abuf_wr_data_0
  ,input  wire [47:0] abuf_wr_data_1
  ,input  wire [47:0] abuf_wr_data_2
  ,input  wire [47:0] abuf_wr_data_3
  ,input  wire [33:0] abuf_wr_data_4
  ,input  wire [33:0] abuf_wr_data_5
  ,input  wire [33:0] abuf_wr_data_6
  ,input  wire [33:0] abuf_wr_data_7
  ,input  wire  [7:0] abuf_wr_en
  ,input  wire [31:0] pwrbus_ram_pd
  ,output reg  [47:0] abuf_rd_data_0
  ,output reg  [47:0] abuf_rd_data_1
  ,output reg  [47:0] abuf_rd_data_2
  ,output reg  [47:0] abuf_rd_data_3
  ,output reg  [33:0] abuf_rd_data_4
  ,output reg  [33:0] abuf_rd_data_5
  ,output reg  [33:0] abuf_rd_data_6
  ,output reg  [33:0] abuf_rd_data_7
);

  wire [47:0] pri_wr_in [0:3];
  assign pri_wr_in[0] = abuf_wr_data_0;
  assign pri_wr_in[1] = abuf_wr_data_1;
  assign pri_wr_in[2] = abuf_wr_data_2;
  assign pri_wr_in[3] = abuf_wr_data_3;

  wire [33:0] ext_wr_in [0:3];
  assign ext_wr_in[0] = abuf_wr_data_4;
  assign ext_wr_in[1] = abuf_wr_data_5;
  assign ext_wr_in[2] = abuf_wr_data_6;
  assign ext_wr_in[3] = abuf_wr_data_7;

  reg   [7:0] wr_d1_vld;
  reg   [7:0] wr_d1_addr [0:7];
  reg   [7:0] pend_vld;
  reg   [7:0] pend_addr  [0:7];
  reg   [7:0] abuf_rd_en_d1;
  reg   [7:0] abuf_rd_en_d2;
  reg   [7:0] raw_hit_d1;

  reg  [47:0] pri_wr_d1_data  [0:3];
  reg  [47:0] pri_pend_data   [0:3];
  reg  [47:0] pri_raw_d1      [0:3];
  reg  [47:0] pri_rd_d2       [0:3];

  reg  [33:0] ext_wr_d1_data  [0:3];
  reg  [33:0] ext_pend_data   [0:3];
  reg  [33:0] ext_raw_d1      [0:3];
  reg  [33:0] ext_rd_d2       [0:3];

  wire  [7:0] raw_hit;
  wire  [7:0] sram_rd_go;
  wire  [7:0] sram_wr_go;
  wire  [7:0] sram_men;
  wire  [7:0] sram_wen;
  wire  [7:0] sram_ren;
  wire  [7:0] sram_addr       [0:7];
  wire [47:0] pri_sram_wdata  [0:3];
  wire [33:0] ext_sram_wdata  [0:3];
  wire [63:0] sram_dout       [0:7];

  genvar b;
  generate
    for (b = 0; b < 4; b = b + 1) begin : gen_pri_bank
      wire hit_w0   = abuf_wr_en[b] && (abuf_wr_addr  == abuf_rd_addr);
      wire hit_wd1  = wr_d1_vld[b]  && (wr_d1_addr[b] == abuf_rd_addr);
      wire hit_pend = pend_vld[b]   && (pend_addr[b]  == abuf_rd_addr);
      wire [47:0] fwd_val = hit_w0 ? pri_wr_in[b] : hit_wd1 ? pri_wr_d1_data[b] : pri_pend_data[b];

      assign raw_hit[b]        = abuf_rd_en[b] && (hit_w0 || hit_wd1 || hit_pend);
      assign sram_rd_go[b]     = abuf_rd_en[b] && !raw_hit[b];
      assign sram_wr_go[b]     = !sram_rd_go[b] && (pend_vld[b] || wr_d1_vld[b]);
      assign sram_men[b]       = sram_rd_go[b] || sram_wr_go[b];
      assign sram_wen[b]       = sram_wr_go[b];
      assign sram_ren[b]       = sram_rd_go[b];
      assign sram_addr[b]      = sram_rd_go[b] ? abuf_rd_addr : pend_vld[b] ? pend_addr[b] : wr_d1_addr[b];
      assign pri_sram_wdata[b] = pend_vld[b] ? pri_pend_data[b] : pri_wr_d1_data[b];

      always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
        if (!nvdla_core_rstn) begin
          wr_d1_vld[b]     <= 1'b0;
          wr_d1_addr[b]    <= 8'd0;
          pend_vld[b]      <= 1'b0;
          pend_addr[b]     <= 8'd0;
          abuf_rd_en_d1[b] <= 1'b0;
          abuf_rd_en_d2[b] <= 1'b0;
          raw_hit_d1[b]    <= 1'b0;
        end else begin
          wr_d1_vld[b] <= abuf_wr_en[b];
          if (abuf_wr_en[b]) wr_d1_addr[b] <= abuf_wr_addr;
          if (sram_rd_go[b]) begin
            if (wr_d1_vld[b]) begin
              pend_vld[b]  <= 1'b1;
              pend_addr[b] <= wr_d1_addr[b];
            end
          end else if (pend_vld[b] && wr_d1_vld[b]) begin
            pend_vld[b]  <= 1'b1;
            pend_addr[b] <= wr_d1_addr[b];
          end else begin
            pend_vld[b]  <= 1'b0;
          end
          abuf_rd_en_d1[b] <= abuf_rd_en[b];
          abuf_rd_en_d2[b] <= abuf_rd_en_d1[b];
          raw_hit_d1[b]    <= raw_hit[b];
        end
      end
      always @(posedge nvdla_core_clk) begin
        if (abuf_wr_en[b]) pri_wr_d1_data[b] <= pri_wr_in[b];
        if ((sram_rd_go[b] && wr_d1_vld[b]) || (!sram_rd_go[b] && pend_vld[b] && wr_d1_vld[b]))
          pri_pend_data[b] <= pri_wr_d1_data[b];
        if (raw_hit[b]) pri_raw_d1[b] <= fwd_val;
        if (abuf_rd_en_d1[b])
          pri_rd_d2[b] <= raw_hit_d1[b] ? pri_raw_d1[b] : sram_dout[b][47:0];
      end
    end

    for (b = 4; b < 8; b = b + 1) begin : gen_ext_bank
      wire hit_w0   = abuf_wr_en[b] && (abuf_wr_addr  == abuf_rd_addr);
      wire hit_wd1  = wr_d1_vld[b]  && (wr_d1_addr[b] == abuf_rd_addr);
      wire hit_pend = pend_vld[b]   && (pend_addr[b]  == abuf_rd_addr);
      wire [33:0] fwd_val = hit_w0 ? ext_wr_in[b-4] : hit_wd1 ? ext_wr_d1_data[b-4] : ext_pend_data[b-4];

      assign raw_hit[b]          = abuf_rd_en[b] && (hit_w0 || hit_wd1 || hit_pend);
      assign sram_rd_go[b]       = abuf_rd_en[b] && !raw_hit[b];
      assign sram_wr_go[b]       = !sram_rd_go[b] && (pend_vld[b] || wr_d1_vld[b]);
      assign sram_men[b]         = sram_rd_go[b] || sram_wr_go[b];
      assign sram_wen[b]         = sram_wr_go[b];
      assign sram_ren[b]         = sram_rd_go[b];
      assign sram_addr[b]        = sram_rd_go[b] ? abuf_rd_addr : pend_vld[b] ? pend_addr[b] : wr_d1_addr[b];
      assign ext_sram_wdata[b-4] = pend_vld[b] ? ext_pend_data[b-4] : ext_wr_d1_data[b-4];

      always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
        if (!nvdla_core_rstn) begin
          wr_d1_vld[b]     <= 1'b0;
          wr_d1_addr[b]    <= 8'd0;
          pend_vld[b]      <= 1'b0;
          pend_addr[b]     <= 8'd0;
          abuf_rd_en_d1[b] <= 1'b0;
          abuf_rd_en_d2[b] <= 1'b0;
          raw_hit_d1[b]    <= 1'b0;
        end else begin
          wr_d1_vld[b] <= abuf_wr_en[b];
          if (abuf_wr_en[b]) wr_d1_addr[b] <= abuf_wr_addr;
          if (sram_rd_go[b]) begin
            if (wr_d1_vld[b]) begin
              pend_vld[b]  <= 1'b1;
              pend_addr[b] <= wr_d1_addr[b];
            end
          end else if (pend_vld[b] && wr_d1_vld[b]) begin
            pend_vld[b]  <= 1'b1;
            pend_addr[b] <= wr_d1_addr[b];
          end else begin
            pend_vld[b]  <= 1'b0;
          end
          abuf_rd_en_d1[b] <= abuf_rd_en[b];
          abuf_rd_en_d2[b] <= abuf_rd_en_d1[b];
          raw_hit_d1[b]    <= raw_hit[b];
        end
      end
      always @(posedge nvdla_core_clk) begin
        if (abuf_wr_en[b]) ext_wr_d1_data[b-4] <= ext_wr_in[b-4];
        if ((sram_rd_go[b] && wr_d1_vld[b]) || (!sram_rd_go[b] && pend_vld[b] && wr_d1_vld[b]))
          ext_pend_data[b-4] <= ext_wr_d1_data[b-4];
        if (raw_hit[b]) ext_raw_d1[b-4] <= fwd_val;
        if (abuf_rd_en_d1[b])
          ext_rd_d2[b-4] <= raw_hit_d1[b] ? ext_raw_d1[b-4] : sram_dout[b][33:0];
      end
    end
  endgenerate

  always @(posedge nvdla_core_clk) begin
    if (abuf_rd_en_d2[0]) abuf_rd_data_0 <= pri_rd_d2[0];
    if (abuf_rd_en_d2[1]) abuf_rd_data_1 <= pri_rd_d2[1];
    if (abuf_rd_en_d2[2]) abuf_rd_data_2 <= pri_rd_d2[2];
    if (abuf_rd_en_d2[3]) abuf_rd_data_3 <= pri_rd_d2[3];
    if (abuf_rd_en_d2[4]) abuf_rd_data_4 <= ext_rd_d2[0];
    if (abuf_rd_en_d2[5]) abuf_rd_data_5 <= ext_rd_d2[1];
    if (abuf_rd_en_d2[6]) abuf_rd_data_6 <= ext_rd_d2[2];
    if (abuf_rd_en_d2[7]) abuf_rd_data_7 <= ext_rd_d2[3];
  end

  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_0 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[0]), .A_WEN(sram_wen[0]), .A_REN(sram_ren[0]),
    .A_ADDR(sram_addr[0]), .A_DIN({16'd0, pri_sram_wdata[0]}), .A_DLY(1'b1), .A_DOUT(sram_dout[0]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_1 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[1]), .A_WEN(sram_wen[1]), .A_REN(sram_ren[1]),
    .A_ADDR(sram_addr[1]), .A_DIN({16'd0, pri_sram_wdata[1]}), .A_DLY(1'b1), .A_DOUT(sram_dout[1]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_2 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[2]), .A_WEN(sram_wen[2]), .A_REN(sram_ren[2]),
    .A_ADDR(sram_addr[2]), .A_DIN({16'd0, pri_sram_wdata[2]}), .A_DLY(1'b1), .A_DOUT(sram_dout[2]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_3 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[3]), .A_WEN(sram_wen[3]), .A_REN(sram_ren[3]),
    .A_ADDR(sram_addr[3]), .A_DIN({16'd0, pri_sram_wdata[3]}), .A_DLY(1'b1), .A_DOUT(sram_dout[3]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_4 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[4]), .A_WEN(sram_wen[4]), .A_REN(sram_ren[4]),
    .A_ADDR(sram_addr[4]), .A_DIN({30'd0, ext_sram_wdata[0]}), .A_DLY(1'b1), .A_DOUT(sram_dout[4]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_5 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[5]), .A_WEN(sram_wen[5]), .A_REN(sram_ren[5]),
    .A_ADDR(sram_addr[5]), .A_DIN({30'd0, ext_sram_wdata[1]}), .A_DLY(1'b1), .A_DOUT(sram_dout[5]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_6 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[6]), .A_WEN(sram_wen[6]), .A_REN(sram_ren[6]),
    .A_ADDR(sram_addr[6]), .A_DIN({30'd0, ext_sram_wdata[2]}), .A_DLY(1'b1), .A_DOUT(sram_dout[6]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_7 (
    .A_CLK(nvdla_core_clk), .A_MEN(sram_men[7]), .A_WEN(sram_wen[7]), .A_REN(sram_ren[7]),
    .A_ADDR(sram_addr[7]), .A_DIN({30'd0, ext_sram_wdata[3]}), .A_DLY(1'b1), .A_DOUT(sram_dout[7]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );

endmodule
