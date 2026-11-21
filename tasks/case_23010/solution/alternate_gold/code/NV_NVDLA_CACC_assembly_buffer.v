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

  wire [47:0] p_in [0:3];
  assign p_in[0] = abuf_wr_data_0; assign p_in[1] = abuf_wr_data_1;
  assign p_in[2] = abuf_wr_data_2; assign p_in[3] = abuf_wr_data_3;

  wire [33:0] e_in [0:3];
  assign e_in[0] = abuf_wr_data_4; assign e_in[1] = abuf_wr_data_5;
  assign e_in[2] = abuf_wr_data_6; assign e_in[3] = abuf_wr_data_7;

  wire  [7:0] m_en, w_en, r_en;
  wire  [7:0] m_addr  [0:7];
  wire [47:0] p_wdat  [0:3];
  wire [33:0] e_wdat  [0:3];
  wire [63:0] m_dout  [0:7];

  reg  [47:0] p_out_d2 [0:3];
  reg  [33:0] e_out_d2 [0:3];
  reg   [7:0] r_en_d1, r_en_d2;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      r_en_d1 <= 8'd0;
      r_en_d2 <= 8'd0;
    end else begin
      r_en_d1 <= abuf_rd_en;
      r_en_d2 <= r_en_d1;
    end
  end

  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : g_pri
      reg        q_v0, q_v1;
      reg  [7:0] q_a0, q_a1;
      reg [47:0] q_d0, q_d1;
      reg        byp_d1;
      reg [47:0] byp_val_d1;

      wire m_in = abuf_wr_en[i] && (abuf_wr_addr == abuf_rd_addr);
      wire m_q1 = q_v1 && (q_a1 == abuf_rd_addr);
      wire m_q0 = q_v0 && (q_a0 == abuf_rd_addr);
      wire byp  = abuf_rd_en[i] && (m_in || m_q1 || m_q0);
      wire [47:0] bval = m_in ? p_in[i] : m_q1 ? q_d1 : q_d0;

      wire do_rd = abuf_rd_en[i] && !byp;
      wire do_wr = !do_rd && q_v0;

      assign m_en[i]   = do_rd || do_wr;
      assign w_en[i]   = do_wr;
      assign r_en[i]   = do_rd;
      assign m_addr[i] = do_rd ? abuf_rd_addr : q_a0;
      assign p_wdat[i] = q_d0;

      always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
        if (!nvdla_core_rstn) begin
          q_v0 <= 1'b0; q_v1 <= 1'b0;
          q_a0 <= 8'd0; q_a1 <= 8'd0;
          byp_d1 <= 1'b0;
        end else begin
          byp_d1 <= byp;
          case ({do_wr, abuf_wr_en[i]})
            2'b10: begin
              q_v0 <= q_v1; q_a0 <= q_a1; q_v1 <= 1'b0;
            end
            2'b11: begin
              if (q_v1) begin
                q_v0 <= 1'b1; q_a0 <= q_a1;
                q_v1 <= 1'b1; q_a1 <= abuf_wr_addr;
              end else begin
                q_v0 <= 1'b1; q_a0 <= abuf_wr_addr;
                q_v1 <= 1'b0;
              end
            end
            2'b01: begin
              if (!q_v0) begin
                q_v0 <= 1'b1; q_a0 <= abuf_wr_addr;
              end else begin
                q_v1 <= 1'b1; q_a1 <= abuf_wr_addr;
              end
            end
            default: ;
          endcase
        end
      end
      always @(posedge nvdla_core_clk) begin
        if (do_wr && !abuf_wr_en[i]) q_d0 <= q_d1;
        else if (do_wr && abuf_wr_en[i]) begin
          if (q_v1) begin q_d0 <= q_d1; q_d1 <= p_in[i]; end
          else q_d0 <= p_in[i];
        end else if (!do_wr && abuf_wr_en[i]) begin
          if (!q_v0) q_d0 <= p_in[i];
          else q_d1 <= p_in[i];
        end
        if (byp) byp_val_d1 <= bval;
        if (r_en_d1[i]) p_out_d2[i] <= byp_d1 ? byp_val_d1 : m_dout[i][47:0];
      end
    end

    for (i = 0; i < 4; i = i + 1) begin : g_ext
      localparam bi = i + 4;
      reg        q_v0, q_v1;
      reg  [7:0] q_a0, q_a1;
      reg [33:0] q_d0, q_d1;
      reg        byp_d1;
      reg [33:0] byp_val_d1;

      wire m_in = abuf_wr_en[bi] && (abuf_wr_addr == abuf_rd_addr);
      wire m_q1 = q_v1 && (q_a1 == abuf_rd_addr);
      wire m_q0 = q_v0 && (q_a0 == abuf_rd_addr);
      wire byp  = abuf_rd_en[bi] && (m_in || m_q1 || m_q0);
      wire [33:0] bval = m_in ? e_in[i] : m_q1 ? q_d1 : q_d0;

      wire do_rd = abuf_rd_en[bi] && !byp;
      wire do_wr = !do_rd && q_v0;

      assign m_en[bi]   = do_rd || do_wr;
      assign w_en[bi]   = do_wr;
      assign r_en[bi]   = do_rd;
      assign m_addr[bi] = do_rd ? abuf_rd_addr : q_a0;
      assign e_wdat[i]  = q_d0;

      always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
        if (!nvdla_core_rstn) begin
          q_v0 <= 1'b0; q_v1 <= 1'b0;
          q_a0 <= 8'd0; q_a1 <= 8'd0;
          byp_d1 <= 1'b0;
        end else begin
          byp_d1 <= byp;
          case ({do_wr, abuf_wr_en[bi]})
            2'b10: begin
              q_v0 <= q_v1; q_a0 <= q_a1; q_v1 <= 1'b0;
            end
            2'b11: begin
              if (q_v1) begin
                q_v0 <= 1'b1; q_a0 <= q_a1;
                q_v1 <= 1'b1; q_a1 <= abuf_wr_addr;
              end else begin
                q_v0 <= 1'b1; q_a0 <= abuf_wr_addr;
                q_v1 <= 1'b0;
              end
            end
            2'b01: begin
              if (!q_v0) begin
                q_v0 <= 1'b1; q_a0 <= abuf_wr_addr;
              end else begin
                q_v1 <= 1'b1; q_a1 <= abuf_wr_addr;
              end
            end
            default: ;
          endcase
        end
      end
      always @(posedge nvdla_core_clk) begin
        if (do_wr && !abuf_wr_en[bi]) q_d0 <= q_d1;
        else if (do_wr && abuf_wr_en[bi]) begin
          if (q_v1) begin q_d0 <= q_d1; q_d1 <= e_in[i]; end
          else q_d0 <= e_in[i];
        end else if (!do_wr && abuf_wr_en[bi]) begin
          if (!q_v0) q_d0 <= e_in[i];
          else q_d1 <= e_in[i];
        end
        if (byp) byp_val_d1 <= bval;
        if (r_en_d1[bi]) e_out_d2[i] <= byp_d1 ? byp_val_d1 : m_dout[bi][33:0];
      end
    end
  endgenerate

  always @(posedge nvdla_core_clk) begin
    if (r_en_d2[0]) abuf_rd_data_0 <= p_out_d2[0];
    if (r_en_d2[1]) abuf_rd_data_1 <= p_out_d2[1];
    if (r_en_d2[2]) abuf_rd_data_2 <= p_out_d2[2];
    if (r_en_d2[3]) abuf_rd_data_3 <= p_out_d2[3];
    if (r_en_d2[4]) abuf_rd_data_4 <= e_out_d2[0];
    if (r_en_d2[5]) abuf_rd_data_5 <= e_out_d2[1];
    if (r_en_d2[6]) abuf_rd_data_6 <= e_out_d2[2];
    if (r_en_d2[7]) abuf_rd_data_7 <= e_out_d2[3];
  end

  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_0 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[0]), .A_WEN(w_en[0]), .A_REN(r_en[0]),
    .A_ADDR(m_addr[0]), .A_DIN({16'd0, p_wdat[0]}), .A_DLY(1'b1), .A_DOUT(m_dout[0]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_1 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[1]), .A_WEN(w_en[1]), .A_REN(r_en[1]),
    .A_ADDR(m_addr[1]), .A_DIN({16'd0, p_wdat[1]}), .A_DLY(1'b1), .A_DOUT(m_dout[1]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_2 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[2]), .A_WEN(w_en[2]), .A_REN(r_en[2]),
    .A_ADDR(m_addr[2]), .A_DIN({16'd0, p_wdat[2]}), .A_DLY(1'b1), .A_DOUT(m_dout[2]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_3 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[3]), .A_WEN(w_en[3]), .A_REN(r_en[3]),
    .A_ADDR(m_addr[3]), .A_DIN({16'd0, p_wdat[3]}), .A_DLY(1'b1), .A_DOUT(m_dout[3]),
    .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_4 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[4]), .A_WEN(w_en[4]), .A_REN(r_en[4]),
    .A_ADDR(m_addr[4]), .A_DIN({30'd0, e_wdat[0]}), .A_DLY(1'b1), .A_DOUT(m_dout[4]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_5 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[5]), .A_WEN(w_en[5]), .A_REN(r_en[5]),
    .A_ADDR(m_addr[5]), .A_DIN({30'd0, e_wdat[1]}), .A_DLY(1'b1), .A_DOUT(m_dout[5]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_6 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[6]), .A_WEN(w_en[6]), .A_REN(r_en[6]),
    .A_ADDR(m_addr[6]), .A_DIN({30'd0, e_wdat[2]}), .A_DLY(1'b1), .A_DOUT(m_dout[6]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );
  RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_7 (
    .A_CLK(nvdla_core_clk), .A_MEN(m_en[7]), .A_WEN(w_en[7]), .A_REN(r_en[7]),
    .A_ADDR(m_addr[7]), .A_DIN({30'd0, e_wdat[3]}), .A_DLY(1'b1), .A_DOUT(m_dout[7]),
    .A_BM({30'd0, 34'h3_FFFF_FFFF}),
    .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
    .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
  );

endmodule
