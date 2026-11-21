// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================
// File Name: cacc_sram_subsys.v

module cacc_sram_subsys (
   input  wire         nvdla_core_clk
  ,input  wire         nvdla_core_rstn
  ,input  wire         reg2dp_op_en
  ,input  wire         reg2dp_conv_mode
  ,input  wire   [1:0] reg2dp_proc_precision
  ,input  wire   [4:0] reg2dp_clip_truncate
  ,input  wire         mac2accu_pvld
  ,input  wire   [7:0] mac2accu_mask
  ,input  wire   [8:0] mac2accu_pd
  ,input  wire  [43:0] mac2accu_data_even_pri
  ,input  wire  [43:0] mac2accu_data_odd_pri
  ,input  wire  [21:0] mac2accu_data_even_ext
  ,input  wire  [21:0] mac2accu_data_odd_ext
  ,input  wire         cacc2sdp_ready
  ,output wire         cacc2sdp_valid
  ,output wire [129:0] cacc2sdp_pd
  ,output wire   [1:0] cacc2glb_done_intr_pd
  ,output wire         dp2reg_done
);

  wire        wait_for_op_en;
  wire  [7:0] abuf_rd_addr;
  wire  [7:0] abuf_rd_en;
  wire        accu_ctrl_valid;
  wire  [7:0] accu_ctrl_bank_mask;
  wire  [7:0] accu_ctrl_ram_valid;
  wire  [7:0] accu_ctrl_lane_en;
  wire        accu_ctrl_dlv_sel;
  wire  [7:0] abuf_wr_addr;
  wire  [7:0] abuf_wr_en;
  wire        dlv_out_valid;
  wire  [7:0] dlv_out_mask;
  wire        dlv_out_layer_end;
  wire        cfg_is_int8;
  wire        cfg_is_int16;
  wire        cfg_is_fp16;
  wire  [4:0] cfg_truncate;
  wire  [3:0] slcg_cell_en;

  wire [47:0] abuf_rd_data_0;
  wire [47:0] abuf_rd_data_1;
  wire [47:0] abuf_rd_data_2;
  wire [47:0] abuf_rd_data_3;
  wire [33:0] abuf_rd_data_4;
  wire [33:0] abuf_rd_data_5;
  wire [33:0] abuf_rd_data_6;
  wire [33:0] abuf_rd_data_7;

  wire [47:0] abuf_wr_data_0;
  wire [47:0] abuf_wr_data_1;
  wire [47:0] abuf_wr_data_2;
  wire [47:0] abuf_wr_data_3;
  wire [33:0] abuf_wr_data_4;
  wire [33:0] abuf_wr_data_5;
  wire [33:0] abuf_wr_data_6;
  wire [33:0] abuf_wr_data_7;

  reg         mac_vld_d0, mac_vld_d1, mac_vld_d2;
  reg  [43:0] mac_ep_d0, mac_ep_d1, mac_ep_d2, mac_ep_d3;
  reg  [43:0] mac_op_d0, mac_op_d1, mac_op_d2, mac_op_d3;
  reg  [21:0] mac_ee_d0, mac_ee_d1, mac_ee_d2, mac_ee_d3;
  reg  [21:0] mac_oe_d0, mac_oe_d1, mac_oe_d2, mac_oe_d3;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      mac_vld_d0 <= 1'b0;
      mac_vld_d1 <= 1'b0;
      mac_vld_d2 <= 1'b0;
    end else begin
      mac_vld_d0 <= mac2accu_pvld;
      mac_vld_d1 <= mac_vld_d0;
      mac_vld_d2 <= mac_vld_d1;
    end
  end
  always @(posedge nvdla_core_clk) begin
    if (mac2accu_pvld) begin
      mac_ep_d0 <= mac2accu_data_even_pri;
      mac_op_d0 <= mac2accu_data_odd_pri;
      mac_ee_d0 <= mac2accu_data_even_ext;
      mac_oe_d0 <= mac2accu_data_odd_ext;
    end
    if (mac_vld_d0) begin
      mac_ep_d1 <= mac_ep_d0;
      mac_op_d1 <= mac_op_d0;
      mac_ee_d1 <= mac_ee_d0;
      mac_oe_d1 <= mac_oe_d0;
    end
    if (mac_vld_d1) begin
      mac_ep_d2 <= mac_ep_d1;
      mac_op_d2 <= mac_op_d1;
      mac_ee_d2 <= mac_ee_d1;
      mac_oe_d2 <= mac_oe_d1;
    end
    if (mac_vld_d2) begin
      mac_ep_d3 <= mac_ep_d2;
      mac_op_d3 <= mac_op_d2;
      mac_ee_d3 <= mac_ee_d2;
      mac_oe_d3 <= mac_oe_d2;
    end
  end

  NV_NVDLA_CACC_assembly_ctrl u_assembly_ctrl (
     .nvdla_core_clk       (nvdla_core_clk)
    ,.nvdla_core_rstn      (nvdla_core_rstn)
    ,.dp2reg_done          (dp2reg_done)
    ,.mac_a2accu_pd        (mac2accu_pd)
    ,.mac_a2accu_pvld      (mac2accu_pvld)
    ,.mac_a2accu_mask      (mac2accu_mask)
    ,.reg2dp_clip_truncate (reg2dp_clip_truncate)
    ,.reg2dp_conv_mode     (reg2dp_conv_mode)
    ,.reg2dp_op_en         (reg2dp_op_en)
    ,.reg2dp_proc_precision(reg2dp_proc_precision)
    ,.abuf_rd_addr         (abuf_rd_addr)
    ,.abuf_rd_en           (abuf_rd_en)
    ,.accu_ctrl_valid      (accu_ctrl_valid)
    ,.accu_ctrl_bank_mask  (accu_ctrl_bank_mask)
    ,.accu_ctrl_ram_valid  (accu_ctrl_ram_valid)
    ,.accu_ctrl_lane_en    (accu_ctrl_lane_en)
    ,.accu_ctrl_dlv_sel    (accu_ctrl_dlv_sel)
    ,.abuf_wr_addr         (abuf_wr_addr)
    ,.abuf_wr_en           (abuf_wr_en)
    ,.dlv_out_valid        (dlv_out_valid)
    ,.dlv_out_mask         (dlv_out_mask)
    ,.dlv_out_layer_end    (dlv_out_layer_end)
    ,.cfg_is_int8          (cfg_is_int8)
    ,.cfg_is_int16         (cfg_is_int16)
    ,.cfg_is_fp16          (cfg_is_fp16)
    ,.cfg_truncate         (cfg_truncate)
    ,.slcg_cell_en         (slcg_cell_en)
    ,.wait_for_op_en       (wait_for_op_en)
  );

  NV_NVDLA_CACC_assembly_buffer u_assembly_buffer (
     .nvdla_core_clk  (nvdla_core_clk)
    ,.nvdla_core_rstn (nvdla_core_rstn)
    ,.abuf_rd_addr    (abuf_rd_addr)
    ,.abuf_rd_en      (abuf_rd_en)
    ,.abuf_wr_addr    (abuf_wr_addr)
    ,.abuf_wr_data_0  (abuf_wr_data_0)
    ,.abuf_wr_data_1  (abuf_wr_data_1)
    ,.abuf_wr_data_2  (abuf_wr_data_2)
    ,.abuf_wr_data_3  (abuf_wr_data_3)
    ,.abuf_wr_data_4  (abuf_wr_data_4)
    ,.abuf_wr_data_5  (abuf_wr_data_5)
    ,.abuf_wr_data_6  (abuf_wr_data_6)
    ,.abuf_wr_data_7  (abuf_wr_data_7)
    ,.abuf_wr_en      (abuf_wr_en)
    ,.pwrbus_ram_pd   (32'd0)
    ,.abuf_rd_data_0  (abuf_rd_data_0)
    ,.abuf_rd_data_1  (abuf_rd_data_1)
    ,.abuf_rd_data_2  (abuf_rd_data_2)
    ,.abuf_rd_data_3  (abuf_rd_data_3)
    ,.abuf_rd_data_4  (abuf_rd_data_4)
    ,.abuf_rd_data_5  (abuf_rd_data_5)
    ,.abuf_rd_data_6  (abuf_rd_data_6)
    ,.abuf_rd_data_7  (abuf_rd_data_7)
  );

  wire [47:0] even_pri_op     = accu_ctrl_bank_mask[2] ? abuf_rd_data_2 : abuf_rd_data_0;
  wire [47:0] odd_pri_op      = accu_ctrl_bank_mask[3] ? abuf_rd_data_3 : abuf_rd_data_1;
  wire [33:0] even_ext_op     = accu_ctrl_bank_mask[6] ? abuf_rd_data_6 : abuf_rd_data_4;
  wire [33:0] odd_ext_op      = accu_ctrl_bank_mask[7] ? abuf_rd_data_7 : abuf_rd_data_5;

  wire        even_pri_op_vld = |(accu_ctrl_ram_valid & 8'b0000_0101);
  wire        odd_pri_op_vld  = |(accu_ctrl_ram_valid & 8'b0000_1010);
  wire        even_ext_op_vld = |(accu_ctrl_ram_valid & 8'b0101_0000);
  wire        odd_ext_op_vld  = |(accu_ctrl_ram_valid & 8'b1010_0000);

  wire        even_pri_vld    = accu_ctrl_valid & (|(accu_ctrl_lane_en & 8'b0000_0101));
  wire        odd_pri_vld     = accu_ctrl_valid & (|(accu_ctrl_lane_en & 8'b0000_1010));
  wire        even_ext_vld    = accu_ctrl_valid & cfg_is_int8 & (|(accu_ctrl_lane_en & 8'b0101_0000));
  wire        odd_ext_vld     = accu_ctrl_valid & cfg_is_int8 & (|(accu_ctrl_lane_en & 8'b1010_0000));

  wire [31:0] i8_ep_final,  i16_ep_final;
  wire [33:0] i8_ep_part;
  wire [47:0] i16_ep_part;
  wire        i8_ep_fvld,   i8_ep_pvld,  i8_ep_sat;
  wire        i16_ep_fvld,  i16_ep_pvld, i16_ep_sat;

  NV_NVDLA_CACC_CALC_int8 u_calc_i8_pri_even (
     .nvdla_core_clk    (nvdla_core_clk)
    ,.nvdla_core_rstn   (nvdla_core_rstn)
    ,.cfg_truncate      (cfg_truncate)
    ,.in_data           (mac_ep_d3[21:0])
    ,.in_op             (even_pri_op[33:0])
    ,.in_op_valid       (even_pri_op_vld)
    ,.in_sel            (accu_ctrl_dlv_sel)
    ,.in_valid          (even_pri_vld & cfg_is_int8)
    ,.out_final_data    (i8_ep_final)
    ,.out_final_sat     (i8_ep_sat)
    ,.out_final_valid   (i8_ep_fvld)
    ,.out_partial_data  (i8_ep_part)
    ,.out_partial_valid (i8_ep_pvld)
  );

  NV_NVDLA_CACC_CALC_int16 u_calc_i16_even (
     .nvdla_core_clk    (nvdla_core_clk)
    ,.nvdla_core_rstn   (nvdla_core_rstn)
    ,.cfg_truncate      (cfg_truncate)
    ,.in_data           (mac_ep_d3[37:0])
    ,.in_op             (even_pri_op[47:0])
    ,.in_op_valid       (even_pri_op_vld)
    ,.in_sel            (accu_ctrl_dlv_sel)
    ,.in_valid          (even_pri_vld & cfg_is_int16)
    ,.out_final_data    (i16_ep_final)
    ,.out_final_sat     (i16_ep_sat)
    ,.out_final_valid   (i16_ep_fvld)
    ,.out_partial_data  (i16_ep_part)
    ,.out_partial_valid (i16_ep_pvld)
  );

  wire [31:0] i8_op_final,  i16_op_final;
  wire [33:0] i8_op_part;
  wire [47:0] i16_op_part;
  wire        i8_op_fvld,   i8_op_pvld,  i8_op_sat;
  wire        i16_op_fvld,  i16_op_pvld, i16_op_sat;

  NV_NVDLA_CACC_CALC_int8 u_calc_i8_pri_odd (
     .nvdla_core_clk    (nvdla_core_clk)
    ,.nvdla_core_rstn   (nvdla_core_rstn)
    ,.cfg_truncate      (cfg_truncate)
    ,.in_data           (mac_op_d3[21:0])
    ,.in_op             (odd_pri_op[33:0])
    ,.in_op_valid       (odd_pri_op_vld)
    ,.in_sel            (accu_ctrl_dlv_sel)
    ,.in_valid          (odd_pri_vld & cfg_is_int8)
    ,.out_final_data    (i8_op_final)
    ,.out_final_sat     (i8_op_sat)
    ,.out_final_valid   (i8_op_fvld)
    ,.out_partial_data  (i8_op_part)
    ,.out_partial_valid (i8_op_pvld)
  );

  NV_NVDLA_CACC_CALC_int16 u_calc_i16_odd (
     .nvdla_core_clk    (nvdla_core_clk)
    ,.nvdla_core_rstn   (nvdla_core_rstn)
    ,.cfg_truncate      (cfg_truncate)
    ,.in_data           (mac_op_d3[37:0])
    ,.in_op             (odd_pri_op[47:0])
    ,.in_op_valid       (odd_pri_op_vld)
    ,.in_sel            (accu_ctrl_dlv_sel)
    ,.in_valid          (odd_pri_vld & cfg_is_int16)
    ,.out_final_data    (i16_op_final)
    ,.out_final_sat     (i16_op_sat)
    ,.out_final_valid   (i16_op_fvld)
    ,.out_partial_data  (i16_op_part)
    ,.out_partial_valid (i16_op_pvld)
  );

  // Shared Direct-Mode FP48 Calculator across primary banks {0..3}
  wire        fp_use_odd = |(accu_ctrl_bank_mask & 8'b0000_1010);
  wire [43:0] fp_in_data = fp_use_odd ? mac_op_d3[43:0] : mac_ep_d3[43:0];
  wire [47:0] fp_in_op   = fp_use_odd ? odd_pri_op      : even_pri_op;
  wire        fp_op_vld  = fp_use_odd ? odd_pri_op_vld  : even_pri_op_vld;
  wire        fp_in_vld  = (even_pri_vld | odd_pri_vld) & cfg_is_fp16;
  wire [31:0] fp_final;
  wire [47:0] fp_part;
  wire        fp_fvld, fp_pvld;

  NV_NVDLA_CACC_CALC_fp_48b u_calc_fp_pri (
     .nvdla_core_clk    (nvdla_core_clk)
    ,.nvdla_core_rstn   (nvdla_core_rstn)
    ,.in_data           (fp_in_data)
    ,.in_op             (fp_in_op)
    ,.in_op_valid       (fp_op_vld)
    ,.in_sel            (accu_ctrl_dlv_sel)
    ,.in_valid          (fp_in_vld)
    ,.out_final_data    (fp_final)
    ,.out_final_valid   (fp_fvld)
    ,.out_partial_data  (fp_part)
    ,.out_partial_valid (fp_pvld)
  );

  wire [31:0] i8_ee_final, i8_oe_final;
  wire [33:0] i8_ee_part,  i8_oe_part;
  wire        i8_ee_fvld,  i8_ee_pvld, i8_ee_sat;
  wire        i8_oe_fvld,  i8_oe_pvld, i8_oe_sat;

  NV_NVDLA_CACC_CALC_int8 u_calc_i8_ext_even (
     .nvdla_core_clk    (nvdla_core_clk)
    ,.nvdla_core_rstn   (nvdla_core_rstn)
    ,.cfg_truncate      (cfg_truncate)
    ,.in_data           (mac_ee_d3)
    ,.in_op             (even_ext_op)
    ,.in_op_valid       (even_ext_op_vld)
    ,.in_sel            (accu_ctrl_dlv_sel)
    ,.in_valid          (even_ext_vld)
    ,.out_final_data    (i8_ee_final)
    ,.out_final_sat     (i8_ee_sat)
    ,.out_final_valid   (i8_ee_fvld)
    ,.out_partial_data  (i8_ee_part)
    ,.out_partial_valid (i8_ee_pvld)
  );

  NV_NVDLA_CACC_CALC_int8 u_calc_i8_ext_odd (
     .nvdla_core_clk    (nvdla_core_clk)
    ,.nvdla_core_rstn   (nvdla_core_rstn)
    ,.cfg_truncate      (cfg_truncate)
    ,.in_data           (mac_oe_d3)
    ,.in_op             (odd_ext_op)
    ,.in_op_valid       (odd_ext_op_vld)
    ,.in_sel            (accu_ctrl_dlv_sel)
    ,.in_valid          (odd_ext_vld)
    ,.out_final_data    (i8_oe_final)
    ,.out_final_sat     (i8_oe_sat)
    ,.out_final_valid   (i8_oe_fvld)
    ,.out_partial_data  (i8_oe_part)
    ,.out_partial_valid (i8_oe_pvld)
  );

  wire [47:0] even_pri_wb = cfg_is_fp16  ? fp_part     :
                            cfg_is_int16 ? i16_ep_part :
                            {14'd0, i8_ep_part};
  wire [47:0] odd_pri_wb  = cfg_is_fp16  ? fp_part     :
                            cfg_is_int16 ? i16_op_part :
                            {14'd0, i8_op_part};

  assign abuf_wr_data_0 = even_pri_wb;
  assign abuf_wr_data_2 = even_pri_wb;
  assign abuf_wr_data_1 = odd_pri_wb;
  assign abuf_wr_data_3 = odd_pri_wb;
  assign abuf_wr_data_4 = i8_ee_part;
  assign abuf_wr_data_6 = i8_ee_part;
  assign abuf_wr_data_5 = i8_oe_part;
  assign abuf_wr_data_7 = i8_oe_part;

  wire [31:0] ep_fin_mux = cfg_is_fp16 ? fp_final : cfg_is_int16 ? i16_ep_final : i8_ep_final;
  wire [31:0] op_fin_mux = cfg_is_fp16 ? fp_final : cfg_is_int16 ? i16_op_final : i8_op_final;

  wire        ep_has_dlv = |(dlv_out_mask & 8'b0000_0101);
  wire        op_has_dlv = |(dlv_out_mask & 8'b0000_1010);
  wire        ee_has_dlv = cfg_is_int8 & (|(dlv_out_mask & 8'b0101_0000));
  wire        oe_has_dlv = cfg_is_int8 & (|(dlv_out_mask & 8'b1010_0000));

  wire [127:0] dlv_pack_data = {
    oe_has_dlv ? i8_oe_final : 32'd0,
    ee_has_dlv ? i8_ee_final : 32'd0,
    op_has_dlv ? op_fin_mux  : 32'd0,
    ep_has_dlv ? ep_fin_mux  : 32'd0
  };

  // Compact 4-entry (2-bank x 2-row) circular delivery controller feeding NV_NVDLA_CACC_delivery_buffer
  reg   [2:0] dbuf_wptr;
  reg   [2:0] dbuf_wptr_commit;
  reg   [2:0] dbuf_rptr;
  reg         wr_commit_pipe;
  reg   [3:0] entry_layer_end;

  wire        dbuf_rd_ready;
  wire  [2:0] dbuf_occ  = dbuf_wptr_commit - dbuf_rptr;
  wire        dbuf_pop  = (dbuf_occ != 3'd0) && dbuf_rd_ready;
  wire        dbuf_push = dlv_out_valid;

  wire  [1:0] dbuf_wr_en        = dbuf_push ? (dbuf_wptr[0] ? 2'b10 : 2'b01) : 2'b00;
  wire        dbuf_wr_addr      = dbuf_wptr[1];
  wire  [1:0] dbuf_rd_en        = dbuf_pop  ? (dbuf_rptr[0] ? 2'b10 : 2'b01) : 2'b00;
  wire        dbuf_rd_addr      = dbuf_rptr[1];
  wire        dbuf_rd_layer_end = dbuf_pop && entry_layer_end[dbuf_rptr[1:0]];

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      dbuf_wptr        <= 3'd0;
      dbuf_wptr_commit <= 3'd0;
      dbuf_rptr        <= 3'd0;
      wr_commit_pipe   <= 1'b0;
      entry_layer_end  <= 4'd0;
    end else begin
      wr_commit_pipe <= dbuf_push;
      if (wr_commit_pipe) begin
        dbuf_wptr_commit <= dbuf_wptr_commit + 3'd1;
      end
      if (dbuf_push) begin
        entry_layer_end[dbuf_wptr[1:0]] <= dlv_out_layer_end;
        dbuf_wptr <= dbuf_wptr + 3'd1;
      end
      if (dbuf_pop) begin
        dbuf_rptr <= dbuf_rptr + 3'd1;
      end
    end
  end

  reg dp2reg_done_r;
  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      dp2reg_done_r <= 1'b0;
    end else begin
      dp2reg_done_r <= dlv_out_valid && dlv_out_layer_end;
    end
  end
  assign dp2reg_done = dp2reg_done_r;

  NV_NVDLA_CACC_delivery_buffer u_delivery_buffer (
     .nvdla_core_clk        (nvdla_core_clk)
    ,.nvdla_core_rstn       (nvdla_core_rstn)
    ,.cacc2sdp_ready        (cacc2sdp_ready)
    ,.dbuf_rd_addr          (dbuf_rd_addr)
    ,.dbuf_rd_en            (dbuf_rd_en)
    ,.dbuf_rd_layer_end     (dbuf_rd_layer_end)
    ,.dbuf_wr_addr          (dbuf_wr_addr)
    ,.dbuf_wr_data          (dlv_pack_data)
    ,.dbuf_wr_en            (dbuf_wr_en)
    ,.pwrbus_ram_pd         (32'd0)
    ,.cacc2glb_done_intr_pd (cacc2glb_done_intr_pd)
    ,.cacc2sdp_pd           (cacc2sdp_pd)
    ,.cacc2sdp_valid        (cacc2sdp_valid)
    ,.dbuf_rd_ready         (dbuf_rd_ready)
  );

endmodule
