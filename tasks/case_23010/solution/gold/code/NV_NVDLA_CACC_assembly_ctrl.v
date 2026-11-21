// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================
// File Name: NV_NVDLA_CACC_assembly_ctrl.v

module NV_NVDLA_CACC_assembly_ctrl (
   input  wire       nvdla_core_clk
  ,input  wire       nvdla_core_rstn
  ,input  wire       dp2reg_done
  ,input  wire [8:0] mac_a2accu_pd
  ,input  wire       mac_a2accu_pvld
  ,input  wire [7:0] mac_a2accu_mask
  ,input  wire [4:0] reg2dp_clip_truncate
  ,input  wire       reg2dp_conv_mode
  ,input  wire       reg2dp_op_en
  ,input  wire [1:0] reg2dp_proc_precision
  ,output wire [7:0] abuf_rd_addr
  ,output wire [7:0] abuf_rd_en
  ,output reg        accu_ctrl_valid
  ,output reg  [7:0] accu_ctrl_bank_mask
  ,output reg  [7:0] accu_ctrl_ram_valid
  ,output reg  [7:0] accu_ctrl_lane_en
  ,output reg        accu_ctrl_dlv_sel
  ,output wire [7:0] abuf_wr_addr
  ,output wire [7:0] abuf_wr_en
  ,output wire       dlv_out_valid
  ,output wire [7:0] dlv_out_mask
  ,output wire       dlv_out_layer_end
  ,output reg        cfg_is_int8
  ,output reg        cfg_is_int16
  ,output reg        cfg_is_fp16
  ,output reg  [4:0] cfg_truncate
  ,output wire [3:0] slcg_cell_en
  ,output reg        wait_for_op_en
);

  reg        accu_valid;
  reg  [8:0] accu_pd;
  reg  [7:0] accu_mask_d0;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      accu_valid   <= 1'b0;
      accu_pd      <= 9'd0;
      accu_mask_d0 <= 8'd0;
    end else begin
      accu_valid <= mac_a2accu_pvld;
      if (mac_a2accu_pvld) begin
        accu_pd      <= mac_a2accu_pd;
        accu_mask_d0 <= mac_a2accu_mask;
      end
    end
  end

  wire       accu_stripe_end  = accu_pd[6];
  wire       accu_channel_end = accu_pd[7];
  wire       accu_layer_end   = accu_pd[8];

  wire       is_int8     = (reg2dp_proc_precision == 2'h0);
  wire       is_int16    = (reg2dp_proc_precision == 2'h1);
  wire       is_fp16     = (reg2dp_proc_precision == 2'h2);
  wire       is_winograd = (reg2dp_conv_mode == 1'b1);

  wire       is_x1 = ~is_int8 & ~is_winograd;
  wire       is_x2 =  is_int8 & ~is_winograd;
  wire       is_x4 = ~is_int8 &  is_winograd;
  wire       is_x8 =  is_int8 &  is_winograd;

  reg  [3:0] slcg_cell_en_d1, slcg_cell_en_d2, slcg_cell_en_d3;
  wire [3:0] slcg_cell_en_w = {
    reg2dp_op_en &  is_fp16 &  is_winograd,
    reg2dp_op_en &  is_fp16,
    reg2dp_op_en & ~is_fp16 &  is_winograd,
    reg2dp_op_en & ~is_fp16
  };

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      slcg_cell_en_d1 <= 4'd0;
      slcg_cell_en_d2 <= 4'd0;
      slcg_cell_en_d3 <= 4'd0;
    end else begin
      slcg_cell_en_d1 <= slcg_cell_en_w;
      slcg_cell_en_d2 <= slcg_cell_en_d1;
      slcg_cell_en_d3 <= slcg_cell_en_d2;
    end
  end
  assign slcg_cell_en = slcg_cell_en_d3;

  reg op_en_d1;
  wire op_en_start = reg2dp_op_en & (~op_en_d1 | wait_for_op_en) & (~dp2reg_done);
  wire wait_for_op_en_w = dp2reg_done ? 1'b1 :
                          (reg2dp_op_en & ~op_en_d1) ? 1'b0 :
                          wait_for_op_en;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      wait_for_op_en <= 1'b1;
      op_en_d1       <= 1'b0;
    end else begin
      wait_for_op_en <= wait_for_op_en_w;
      op_en_d1       <= reg2dp_op_en;
    end
  end

  wire layer_st = wait_for_op_en & reg2dp_op_en & ~op_en_d1;

  reg        cfg_winograd;
  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      cfg_winograd <= 1'b0;
      cfg_is_int8  <= 1'b1;
      cfg_is_int16 <= 1'b0;
      cfg_is_fp16  <= 1'b0;
      cfg_truncate <= 5'd0;
    end else if (layer_st) begin
      cfg_winograd <= is_winograd;
      cfg_is_int8  <= is_int8;
      cfg_is_int16 <= is_int16;
      cfg_is_fp16  <= is_fp16;
      cfg_truncate <= reg2dp_clip_truncate;
    end
  end

  reg  [9:0] accu_cnt;
  wire [9:0] accu_cnt_inc = accu_cnt + 10'd1;
  wire [9:0] accu_cnt_w   = (layer_st | (accu_valid & accu_stripe_end)) ? 10'd0 : accu_cnt_inc;

  reg        accu_channel_st;
  wire       accu_channel_st_w = layer_st ? 1'b1 :
                                 (accu_valid & accu_stripe_end) ? accu_channel_end :
                                 accu_channel_st;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      accu_cnt        <= 10'd0;
      accu_channel_st <= 1'b1;
    end else if (layer_st) begin
      accu_cnt        <= 10'd0;
      accu_channel_st <= 1'b1;
    end else if (accu_valid) begin
      accu_cnt        <= accu_stripe_end ? 10'd0 : accu_cnt_inc;
      accu_channel_st <= accu_channel_st_w;
    end
  end

  wire [3:0] dir_sel_d0 = (4'b0001 << accu_cnt[1:0]);
  wire [3:0] wg_pair_d0 = accu_cnt[0] ? 4'b1100 : 4'b0011;
  wire [3:0] pri_mask_d0 = cfg_winograd ? wg_pair_d0 : dir_sel_d0;
  wire [7:0] accu_bank_mask = {cfg_is_int8 ? pri_mask_d0 : 4'b0000, pri_mask_d0};

  wire [7:0] accu_addr_d0 = cfg_winograd ? accu_cnt[8:1] : accu_cnt[9:2];
  wire [7:0] active_lanes_d0 = accu_bank_mask & accu_mask_d0;

  assign abuf_rd_addr = accu_addr_d0;
  assign abuf_rd_en   = (accu_valid & ~accu_channel_st) ? active_lanes_d0 : 8'd0;

  // 3-stage control delay matching assembly_buffer 3-cycle read latency (d0 -> d1 -> d2 -> ctrl)
  reg        vld_d1, vld_d2;
  reg  [7:0] addr_d1, addr_d2, accu_ctrl_addr;
  reg  [7:0] bmask_d1, bmask_d2;
  reg  [7:0] lane_d1, lane_d2;
  reg  [7:0] ramv_d1, ramv_d2;
  reg        cend_d1, cend_d2;
  reg        lend_d1, lend_d2, accu_ctrl_layer_end;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      vld_d1              <= 1'b0;
      vld_d2              <= 1'b0;
      accu_ctrl_valid     <= 1'b0;
      addr_d1             <= 8'd0; addr_d2  <= 8'd0; accu_ctrl_addr      <= 8'd0;
      bmask_d1            <= 8'd0; bmask_d2 <= 8'd0; accu_ctrl_bank_mask <= 8'd0;
      lane_d1             <= 8'd0; lane_d2  <= 8'd0; accu_ctrl_lane_en   <= 8'd0;
      ramv_d1             <= 8'd0; ramv_d2  <= 8'd0; accu_ctrl_ram_valid <= 8'd0;
      cend_d1             <= 1'b0; cend_d2  <= 1'b0; accu_ctrl_dlv_sel   <= 1'b0;
      lend_d1             <= 1'b0; lend_d2  <= 1'b0; accu_ctrl_layer_end <= 1'b0;
    end else begin
      vld_d1          <= accu_valid;
      vld_d2          <= vld_d1;
      accu_ctrl_valid <= vld_d2;

      if (accu_valid) begin
        addr_d1  <= accu_addr_d0;
        bmask_d1 <= accu_bank_mask;
        lane_d1  <= active_lanes_d0;
        ramv_d1  <= accu_channel_st ? 8'd0 : active_lanes_d0;
        cend_d1  <= accu_channel_end;
        lend_d1  <= accu_stripe_end & accu_channel_end & accu_layer_end;
      end
      if (vld_d1) begin
        addr_d2  <= addr_d1;
        bmask_d2 <= bmask_d1;
        lane_d2  <= lane_d1;
        ramv_d2  <= ramv_d1;
        cend_d2  <= cend_d1;
        lend_d2  <= lend_d1;
      end
      if (vld_d2) begin
        accu_ctrl_addr      <= addr_d2;
        accu_ctrl_bank_mask <= bmask_d2;
        accu_ctrl_lane_en   <= lane_d2;
        accu_ctrl_ram_valid <= ramv_d2;
        accu_ctrl_dlv_sel   <= cend_d2;
        accu_ctrl_layer_end <= lend_d2;
      end
    end
  end

  // Calculator writeback & delivery alignment:
  // INT8 / INT16 calculators: 2-cycle latency (c1 -> c2)
  // FP16 (CALC_fp_48b)      : 4-cycle latency (c1 -> c2 -> c3 -> c4)
  wire [7:0] wb_en_c0  = (accu_ctrl_valid & ~accu_ctrl_dlv_sel) ? accu_ctrl_lane_en : 8'd0;
  wire       dlv_v_c0  = accu_ctrl_valid & accu_ctrl_dlv_sel;

  reg  [7:0] wb_en_c1,   wb_en_c2,   wb_en_c3,   wb_en_c4;
  reg  [7:0] wb_addr_c1, wb_addr_c2, wb_addr_c3, wb_addr_c4;
  reg        dlv_v_c1,   dlv_v_c2,   dlv_v_c3,   dlv_v_c4;
  reg  [7:0] dlv_m_c1,   dlv_m_c2,   dlv_m_c3,   dlv_m_c4;
  reg        dlv_le_c1,  dlv_le_c2,  dlv_le_c3,  dlv_le_c4;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      wb_en_c1   <= 8'd0; wb_en_c2   <= 8'd0; wb_en_c3   <= 8'd0; wb_en_c4   <= 8'd0;
      wb_addr_c1 <= 8'd0; wb_addr_c2 <= 8'd0; wb_addr_c3 <= 8'd0; wb_addr_c4 <= 8'd0;
      dlv_v_c1   <= 1'b0; dlv_v_c2   <= 1'b0; dlv_v_c3   <= 1'b0; dlv_v_c4   <= 1'b0;
      dlv_m_c1   <= 8'd0; dlv_m_c2   <= 8'd0; dlv_m_c3   <= 8'd0; dlv_m_c4   <= 8'd0;
      dlv_le_c1  <= 1'b0; dlv_le_c2  <= 1'b0; dlv_le_c3  <= 1'b0; dlv_le_c4  <= 1'b0;
    end else begin
      wb_en_c1   <= wb_en_c0;
      wb_en_c2   <= wb_en_c1;
      wb_en_c3   <= wb_en_c2;
      wb_en_c4   <= wb_en_c3;

      wb_addr_c1 <= accu_ctrl_addr;
      wb_addr_c2 <= wb_addr_c1;
      wb_addr_c3 <= wb_addr_c2;
      wb_addr_c4 <= wb_addr_c3;

      dlv_v_c1   <= dlv_v_c0;
      dlv_v_c2   <= dlv_v_c1;
      dlv_v_c3   <= dlv_v_c2;
      dlv_v_c4   <= dlv_v_c3;

      dlv_m_c1   <= accu_ctrl_lane_en;
      dlv_m_c2   <= dlv_m_c1;
      dlv_m_c3   <= dlv_m_c2;
      dlv_m_c4   <= dlv_m_c3;

      dlv_le_c1  <= accu_ctrl_layer_end;
      dlv_le_c2  <= dlv_le_c1;
      dlv_le_c3  <= dlv_le_c2;
      dlv_le_c4  <= dlv_le_c3;
    end
  end

  assign abuf_wr_en        = cfg_is_fp16 ? (wb_en_c3 & 8'h0f) : wb_en_c2;
  assign abuf_wr_addr      = cfg_is_fp16 ? wb_addr_c3         : wb_addr_c2;
  assign dlv_out_valid     = cfg_is_fp16 ? dlv_v_c4           : dlv_v_c2;
  assign dlv_out_mask      = cfg_is_fp16 ? (dlv_m_c4 & 8'h0f) : dlv_m_c2;
  assign dlv_out_layer_end = cfg_is_fp16 ? dlv_le_c4          : dlv_le_c2;

endmodule
