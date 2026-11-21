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

  reg        in_vld_q;
  reg  [2:0] in_flags_q;
  reg  [7:0] in_mask_q;
  reg        op_en_prev;
  reg        cfg_wg_q;
  reg  [9:0] beat_idx_q;
  reg        first_stripe_q;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      in_vld_q   <= 1'b0;
      in_flags_q <= 3'd0;
      in_mask_q  <= 8'd0;
      op_en_prev <= 1'b0;
    end else begin
      in_vld_q   <= mac_a2accu_pvld;
      op_en_prev <= reg2dp_op_en;
      if (mac_a2accu_pvld) begin
        in_flags_q <= mac_a2accu_pd[8:6];
        in_mask_q  <= mac_a2accu_mask;
      end
    end
  end

  wire f_stripe_end = in_flags_q[0];
  wire f_chan_end   = in_flags_q[1];
  wire f_layer_end  = in_flags_q[2];

  wire start_pulse = wait_for_op_en & reg2dp_op_en & ~op_en_prev;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      wait_for_op_en <= 1'b1;
      cfg_wg_q       <= 1'b0;
      cfg_is_int8    <= 1'b1;
      cfg_is_int16   <= 1'b0;
      cfg_is_fp16    <= 1'b0;
      cfg_truncate   <= 5'd0;
      beat_idx_q     <= 10'd0;
      first_stripe_q <= 1'b1;
    end else begin
      if (dp2reg_done)
        wait_for_op_en <= 1'b1;
      else if (start_pulse)
        wait_for_op_en <= 1'b0;

      if (start_pulse) begin
        cfg_wg_q       <= (reg2dp_conv_mode == 1'b1);
        cfg_is_int8    <= (reg2dp_proc_precision == 2'h0);
        cfg_is_int16   <= (reg2dp_proc_precision == 2'h1);
        cfg_is_fp16    <= (reg2dp_proc_precision == 2'h2);
        cfg_truncate   <= reg2dp_clip_truncate;
        beat_idx_q     <= 10'd0;
        first_stripe_q <= 1'b1;
      end else if (in_vld_q) begin
        beat_idx_q <= f_stripe_end ? 10'd0 : (beat_idx_q + 10'd1);
        if (f_stripe_end)
          first_stripe_q <= f_chan_end;
      end
    end
  end

  reg [3:0] slcg_q1, slcg_q2, slcg_q3;
  wire p_fp16 = (reg2dp_proc_precision == 2'h2);
  wire p_wg   = (reg2dp_conv_mode == 1'b1);
  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      slcg_q1 <= 4'd0; slcg_q2 <= 4'd0; slcg_q3 <= 4'd0;
    end else begin
      slcg_q1 <= {reg2dp_op_en & p_fp16 & p_wg, reg2dp_op_en & p_fp16, reg2dp_op_en & ~p_fp16 & p_wg, reg2dp_op_en & ~p_fp16};
      slcg_q2 <= slcg_q1;
      slcg_q3 <= slcg_q2;
    end
  end
  assign slcg_cell_en = slcg_q3;

  wire [3:0] low_banks  = cfg_wg_q ? (beat_idx_q[0] ? 4'b1100 : 4'b0011) : (4'b0001 << beat_idx_q[1:0]);
  wire [7:0] full_bmask = {cfg_is_int8 ? low_banks : 4'b0000, low_banks};
  wire [7:0] cur_lanes  = full_bmask & in_mask_q;
  wire [7:0] cur_addr   = cfg_wg_q ? beat_idx_q[8:1] : beat_idx_q[9:2];

  assign abuf_rd_addr = cur_addr;
  assign abuf_rd_en   = (in_vld_q & ~first_stripe_q) ? cur_lanes : 8'd0;

  reg        s1_v, s2_v;
  reg  [7:0] s1_addr, s2_addr, s3_addr;
  reg  [7:0] s1_bm,   s2_bm;
  reg  [7:0] s1_ln,   s2_ln;
  reg  [7:0] s1_rv,   s2_rv;
  reg        s1_ce,   s2_ce;
  reg        s1_le,   s2_le,   s3_le;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      s1_v <= 1'b0; s2_v <= 1'b0; accu_ctrl_valid <= 1'b0;
      s1_addr <= 8'd0; s2_addr <= 8'd0; s3_addr <= 8'd0;
      s1_bm <= 8'd0; s2_bm <= 8'd0; accu_ctrl_bank_mask <= 8'd0;
      s1_ln <= 8'd0; s2_ln <= 8'd0; accu_ctrl_lane_en <= 8'd0;
      s1_rv <= 8'd0; s2_rv <= 8'd0; accu_ctrl_ram_valid <= 8'd0;
      s1_ce <= 1'b0; s2_ce <= 1'b0; accu_ctrl_dlv_sel <= 1'b0;
      s1_le <= 1'b0; s2_le <= 1'b0; s3_le <= 1'b0;
    end else begin
      s1_v <= in_vld_q;
      s2_v <= s1_v;
      accu_ctrl_valid <= s2_v;
      if (in_vld_q) begin
        s1_addr <= cur_addr;
        s1_bm   <= full_bmask;
        s1_ln   <= cur_lanes;
        s1_rv   <= first_stripe_q ? 8'd0 : cur_lanes;
        s1_ce   <= f_chan_end;
        s1_le   <= f_stripe_end & f_chan_end & f_layer_end;
      end
      if (s1_v) begin
        s2_addr <= s1_addr; s2_bm <= s1_bm; s2_ln <= s1_ln;
        s2_rv   <= s1_rv;   s2_ce <= s1_ce; s2_le <= s1_le;
      end
      if (s2_v) begin
        s3_addr             <= s2_addr;
        accu_ctrl_bank_mask <= s2_bm;
        accu_ctrl_lane_en   <= s2_ln;
        accu_ctrl_ram_valid <= s2_rv;
        accu_ctrl_dlv_sel   <= s2_ce;
        s3_le               <= s2_le;
      end
    end
  end

  reg [7:0] w_en_q [1:3];
  reg [7:0] w_ad_q [1:3];
  reg       d_vl_q [1:4];
  reg [7:0] d_mk_q [1:4];
  reg       d_le_q [1:4];
  integer k;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      for (k = 1; k <= 3; k = k + 1) begin
        w_en_q[k] <= 8'd0;
        w_ad_q[k] <= 8'd0;
      end
      for (k = 1; k <= 4; k = k + 1) begin
        d_vl_q[k] <= 1'b0;
        d_mk_q[k] <= 8'd0;
        d_le_q[k] <= 1'b0;
      end
    end else begin
      w_en_q[1] <= (accu_ctrl_valid & ~accu_ctrl_dlv_sel) ? accu_ctrl_lane_en : 8'd0;
      w_ad_q[1] <= s3_addr;
      w_en_q[2] <= w_en_q[1]; w_ad_q[2] <= w_ad_q[1];
      w_en_q[3] <= w_en_q[2]; w_ad_q[3] <= w_ad_q[2];

      d_vl_q[1] <= accu_ctrl_valid & accu_ctrl_dlv_sel;
      d_mk_q[1] <= accu_ctrl_lane_en;
      d_le_q[1] <= s3_le;
      for (k = 2; k <= 4; k = k + 1) begin
        d_vl_q[k] <= d_vl_q[k-1];
        d_mk_q[k] <= d_mk_q[k-1];
        d_le_q[k] <= d_le_q[k-1];
      end
    end
  end

  assign abuf_wr_en        = cfg_is_fp16 ? (w_en_q[3] & 8'h0f) : w_en_q[2];
  assign abuf_wr_addr      = cfg_is_fp16 ? w_ad_q[3]           : w_ad_q[2];
  assign dlv_out_valid     = cfg_is_fp16 ? d_vl_q[4]           : d_vl_q[2];
  assign dlv_out_mask      = cfg_is_fp16 ? (d_mk_q[4] & 8'h0f) : d_mk_q[2];
  assign dlv_out_layer_end = cfg_is_fp16 ? d_le_q[4]           : d_le_q[2];

endmodule
