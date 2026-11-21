// ================================================================
// NVDLA Open Source Project
// 
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with 
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_PDP_nan.v

module NV_NVDLA_PDP_nan (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,dp2reg_done
  ,nan_preproc_prdy
  ,pdp_rdma2dp_pd
  ,pdp_rdma2dp_valid
  ,reg2dp_flying_mode
  ,reg2dp_input_data
  ,reg2dp_nan_to_zero
  ,reg2dp_op_en
  ,dp2reg_inf_input_num
  ,dp2reg_nan_input_num
  ,nan_preproc_pd
  ,nan_preproc_pvld
  ,pdp_rdma2dp_ready
  );
input         nvdla_core_clk;
input         nvdla_core_rstn;
input         dp2reg_done;
input         nan_preproc_prdy;
input  [75:0] pdp_rdma2dp_pd;
input         pdp_rdma2dp_valid;
input         reg2dp_flying_mode;
input   [1:0] reg2dp_input_data;
input         reg2dp_nan_to_zero;
input         reg2dp_op_en;
output [31:0] dp2reg_inf_input_num;
output [31:0] dp2reg_nan_input_num;
output [75:0] nan_preproc_pd;
output        nan_preproc_pvld;
output        pdp_rdma2dp_ready;

reg    [11:0] datin_info_d;
reg           din_pvld_d1;
reg    [31:0] dp2reg_inf_input_num;
reg    [31:0] dp2reg_nan_input_num;
reg    [15:0] nan_preproc_pd0;
reg    [15:0] nan_preproc_pd1;
reg    [15:0] nan_preproc_pd2;
reg    [15:0] nan_preproc_pd3;
reg           waiting_for_op_en;

wire    [3:0] dat_is_inf;
wire    [3:0] dat_is_nan;
wire          din_prdy_d1;
wire          fp16_en;
wire   [15:0] fp16_in_pd_0;
wire   [15:0] fp16_in_pd_1;
wire   [15:0] fp16_in_pd_2;
wire   [15:0] fp16_in_pd_3;
wire          load_din;
wire          onfly_en;
wire          pdp_rdma2dp_ready_f;
wire          tozero_en;

//==========================================
// Ingress handshake & mode decode
//==========================================
assign pdp_rdma2dp_ready = pdp_rdma2dp_ready_f;
assign pdp_rdma2dp_ready_f = (~din_pvld_d1 | din_prdy_d1) & (~waiting_for_op_en);
assign load_din = pdp_rdma2dp_valid & pdp_rdma2dp_ready_f;

assign tozero_en = (reg2dp_nan_to_zero == 1'h1);
assign fp16_en   = (reg2dp_input_data[1:0] == 2'h2);
assign onfly_en  = (reg2dp_flying_mode == 1'h0);

assign fp16_in_pd_0 = pdp_rdma2dp_pd[15:0];
assign fp16_in_pd_1 = pdp_rdma2dp_pd[31:16];
assign fp16_in_pd_2 = pdp_rdma2dp_pd[47:32];
assign fp16_in_pd_3 = pdp_rdma2dp_pd[63:48];

assign dat_is_nan = 4'b0000;
assign dat_is_inf = 4'b0000;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    waiting_for_op_en <= 1'b0;
  end else begin
    waiting_for_op_en <= 1'b0;
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    nan_preproc_pd0 <= 16'd0;
    nan_preproc_pd1 <= 16'd0;
    nan_preproc_pd2 <= 16'd0;
    nan_preproc_pd3 <= 16'd0;
    datin_info_d    <= 12'd0;
  end else if (load_din) begin
    nan_preproc_pd0 <= fp16_in_pd_0;
    nan_preproc_pd1 <= fp16_in_pd_1;
    nan_preproc_pd2 <= fp16_in_pd_2;
    nan_preproc_pd3 <= fp16_in_pd_3;
    datin_info_d    <= pdp_rdma2dp_pd[75:64];
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    din_pvld_d1 <= 1'b0;
  end else begin
    if (pdp_rdma2dp_valid & (~waiting_for_op_en))
      din_pvld_d1 <= 1'b1;
    else if (din_prdy_d1)
      din_pvld_d1 <= 1'b0;
  end
end

assign din_prdy_d1      = nan_preproc_prdy;
assign nan_preproc_pd   = {datin_info_d, nan_preproc_pd3, nan_preproc_pd2, nan_preproc_pd1, nan_preproc_pd0};
assign nan_preproc_pvld = din_pvld_d1;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    dp2reg_nan_input_num <= 32'd0;
    dp2reg_inf_input_num <= 32'd0;
  end else if (dp2reg_done) begin
    dp2reg_nan_input_num <= 32'd0;
    dp2reg_inf_input_num <= 32'd0;
  end
end

endmodule // NV_NVDLA_PDP_nan
