// ================================================================
// NVDLA Open Source Project
// 
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with 
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_PDP_CORE_unit1d.v

module NV_NVDLA_PDP_CORE_unit1d (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,average_pooling_en
  ,cur_datin_disable
  ,last_out_en
  ,nvdla_op_gated_clk_fp16
  ,pdma2pdp_pd
  ,pdma2pdp_pvld
  ,pdp_din_lc_f
  ,pooling_din_1st
  ,pooling_din_last
  ,pooling_out_prdy
  ,pooling_type_cfg
  ,pooling_unit_en
  ,reg2dp_fp16_en
  ,reg2dp_int16_en
  ,reg2dp_int8_en
  ,pdma2pdp_prdy
  ,pooling_out
  ,pooling_out_pvld
  );

input          nvdla_core_clk;
input          nvdla_core_rstn;
input          average_pooling_en;
input          cur_datin_disable;
input          last_out_en;
input          nvdla_op_gated_clk_fp16;
input   [93:0] pdma2pdp_pd;
input          pdma2pdp_pvld;
input          pdp_din_lc_f;
input          pooling_din_1st;
input          pooling_din_last;
input          pooling_out_prdy;
input    [1:0] pooling_type_cfg;
input          pooling_unit_en;
input          reg2dp_fp16_en;
input          reg2dp_int16_en;
input          reg2dp_int8_en;
output         pdma2pdp_prdy;
output  [91:0] pooling_out;
output         pooling_out_pvld;

wire           add_out_rdy;
wire           add_out_vld;
wire     [1:0] buf_sel;
wire     [1:0] buf_sel_sync;
wire           cur_datin_disable_sync;
wire    [87:0] data_buf0;
wire    [87:0] data_buf1;
wire    [87:0] data_buf2;
wire    [87:0] data_buf3;
wire           data_buf_lc;
wire    [87:0] datain_ext;
wire    [87:0] datain_ext_sync;
wire    [16:0] fp16_pool_sum_0;
wire    [16:0] fp16_pool_sum_1;
wire    [16:0] fp16_pool_sum_2;
wire    [16:0] fp16_pool_sum_3;
wire           fp16_pool_sum_prdy;
wire           fp16_pool_sum_pvld;
wire           fp_addin_rdy;
wire           fp_addin_vld;
wire    [87:0] fp_cur_pooling_dat;
wire    [87:0] fp_datain_ext;
wire           fp_mean_pool_cfg;
wire    [67:0] fp_pool_sum;
wire    [87:0] fp_pool_sum_use0;
wire    [87:0] fp_pool_sum_use1;
wire    [87:0] fp_pool_sum_use2;
wire    [87:0] fp_pool_sum_use3;
wire    [87:0] int_pool_cur_dat;
wire    [87:0] int_pool_datin_ext;
wire    [87:0] int_pooling;
wire    [87:0] int_pooling_sync;
wire           load_din;
wire           pdma2pdp_prdy_f;
wire     [1:0] pdp_din_cpos;
wire           pdp_din_lc_f_sync;
wire   [184:0] pipe_in_pd;
wire   [184:0] pipe_in_pd_d0;
wire   [184:0] pipe_in_pd_d1;
wire   [184:0] pipe_in_pd_d2;
wire   [184:0] pipe_in_pd_d3;
wire   [184:0] pipe_in_pd_d4;
wire           pipe_in_rdy;
wire           pipe_in_rdy_d0;
wire           pipe_in_rdy_d1;
wire           pipe_in_rdy_d2;
wire           pipe_in_rdy_d3;
wire           pipe_in_rdy_d4;
wire           pipe_in_vld;
wire           pipe_in_vld_d0;
wire           pipe_in_vld_d1;
wire           pipe_in_vld_d2;
wire           pipe_in_vld_d3;
wire           pipe_in_vld_d4;
wire   [184:0] pipe_out_pd;
wire           pipe_out_rdy;
wire           pipe_out_vld;
wire           pool_fun_vld;
wire           pooling_din_1st_sync;
wire           pooling_din_last_sync;
wire     [2:0] pooling_out_size;
wire     [2:0] pooling_out_size_sync;
wire           pooling_out_vld;
wire    [87:0] pooling_result;
reg     [87:0] cur_pooling_dat;
reg     [67:0] fp_pool_sum_result0_d3;
reg     [67:0] fp_pool_sum_result1_d3;
reg     [67:0] fp_pool_sum_result2_d3;
reg     [67:0] fp_pool_sum_result3_d3;
reg     [87:0] latch_result0_d3;
reg     [87:0] latch_result1_d3;
reg     [87:0] latch_result2_d3;
reg     [87:0] latch_result3_d3;
reg      [1:0] pooling_cnt;
reg     [91:0] pooling_out;
reg      [2:0] pooling_size;

assign fp_mean_pool_cfg = (reg2dp_fp16_en & average_pooling_en);
assign pdp_din_cpos     = pdma2pdp_pd[93:92];
assign buf_sel          = pdp_din_cpos[1:0];

assign load_din         = pdma2pdp_pvld & pdma2pdp_prdy_f & (~cur_datin_disable) & pooling_unit_en;
assign pdma2pdp_prdy_f  = fp_mean_pool_cfg ? (pipe_in_rdy & fp_addin_rdy) : pipe_in_rdy;
assign pdma2pdp_prdy    = pdma2pdp_prdy_f;

function [87:0] pooling_fun;
  input        reg2dp_int8_en;
  input        reg2dp_int16_en;
  input        reg2dp_fp16_en;
  input  [1:0] pooling_type;
  input [87:0] data0_in;
  input [87:0] data1_in;
  begin
    pooling_fun = data1_in;
  end
endfunction

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    pooling_size <= 3'd0;
  end else begin
    pooling_size <= 3'd0;
  end
end
assign pooling_out_size = pooling_size;

assign datain_ext = pdma2pdp_pd[87:0];
always @(*) begin
  case (buf_sel)
    2'd0:    cur_pooling_dat = data_buf0;
    2'd1:    cur_pooling_dat = data_buf1;
    2'd2:    cur_pooling_dat = data_buf2;
    default: cur_pooling_dat = data_buf3;
  endcase
end

assign fp_datain_ext      = datain_ext[87:0];
assign fp_cur_pooling_dat = cur_pooling_dat[87:0];
assign fp_addin_vld       = pdma2pdp_pvld & pipe_in_rdy & fp_mean_pool_cfg;

cal1d_fp16_pool_sum u_cal1d_fp16_pool_sum (
   .inp_a_0                 (fp_cur_pooling_dat[16:0])
  ,.inp_a_1                 (fp_cur_pooling_dat[38:22])
  ,.inp_a_2                 (fp_cur_pooling_dat[60:44])
  ,.inp_a_3                 (fp_cur_pooling_dat[82:66])
  ,.inp_b_0                 (fp_datain_ext[16:0])
  ,.inp_b_1                 (fp_datain_ext[38:22])
  ,.inp_b_2                 (fp_datain_ext[60:44])
  ,.inp_b_3                 (fp_datain_ext[82:66])
  ,.inp_in_pvld             (fp_addin_vld)
  ,.inp_out_prdy            (fp16_pool_sum_prdy)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.inp_in_prdy             (fp_addin_rdy)
  ,.inp_out_pvld            (fp16_pool_sum_pvld)
  ,.out_z_0                 (fp16_pool_sum_0[16:0])
  ,.out_z_1                 (fp16_pool_sum_1[16:0])
  ,.out_z_2                 (fp16_pool_sum_2[16:0])
  ,.out_z_3                 (fp16_pool_sum_3[16:0])
  );
assign fp_pool_sum = {fp16_pool_sum_3, fp16_pool_sum_2, fp16_pool_sum_1, fp16_pool_sum_0};

assign pipe_in_vld   = fp_mean_pool_cfg ? (pdma2pdp_pvld & fp_addin_rdy) : pdma2pdp_pvld;
assign pipe_in_pd    = {pooling_din_last, pooling_out_size, cur_datin_disable, buf_sel[1:0], pdp_din_lc_f, pooling_din_1st, datain_ext[87:0], int_pooling[87:0]};
assign pipe_in_vld_d0 = pipe_in_vld;
assign pipe_in_rdy    = pipe_in_rdy_d0;
assign pipe_in_pd_d0  = pipe_in_pd;

NV_NVDLA_PDP_CORE_UNIT1D_pipe_p1 pipe_p1 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d0   (pipe_in_pd_d0[184:0])
  ,.pipe_in_rdy_d1  (pipe_in_rdy_d1)
  ,.pipe_in_vld_d0  (pipe_in_vld_d0)
  ,.pipe_in_pd_d1   (pipe_in_pd_d1[184:0])
  ,.pipe_in_rdy_d0  (pipe_in_rdy_d0)
  ,.pipe_in_vld_d1  (pipe_in_vld_d1)
  );
NV_NVDLA_PDP_CORE_UNIT1D_pipe_p2 pipe_p2 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d1   (pipe_in_pd_d1[184:0])
  ,.pipe_in_rdy_d2  (pipe_in_rdy_d2)
  ,.pipe_in_vld_d1  (pipe_in_vld_d1)
  ,.pipe_in_pd_d2   (pipe_in_pd_d2[184:0])
  ,.pipe_in_rdy_d1  (pipe_in_rdy_d1)
  ,.pipe_in_vld_d2  (pipe_in_vld_d2)
  );
NV_NVDLA_PDP_CORE_UNIT1D_pipe_p3 pipe_p3 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d2   (pipe_in_pd_d2[184:0])
  ,.pipe_in_rdy_d3  (pipe_in_rdy_d3)
  ,.pipe_in_vld_d2  (pipe_in_vld_d2)
  ,.pipe_in_pd_d3   (pipe_in_pd_d3[184:0])
  ,.pipe_in_rdy_d2  (pipe_in_rdy_d2)
  ,.pipe_in_vld_d3  (pipe_in_vld_d3)
  );
NV_NVDLA_PDP_CORE_UNIT1D_pipe_p4 pipe_p4 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d3   (pipe_in_pd_d3[184:0])
  ,.pipe_in_rdy_d4  (pipe_in_rdy_d4)
  ,.pipe_in_vld_d3  (pipe_in_vld_d3)
  ,.pipe_in_pd_d4   (pipe_in_pd_d4[184:0])
  ,.pipe_in_rdy_d3  (pipe_in_rdy_d3)
  ,.pipe_in_vld_d4  (pipe_in_vld_d4)
  );
assign pipe_out_vld       = pipe_in_vld_d4;
assign pipe_in_rdy_d4     = pipe_out_rdy;
assign pipe_out_pd[184:0] = pipe_in_pd_d4[184:0];

assign pipe_out_rdy       = fp_mean_pool_cfg ? (add_out_rdy & fp16_pool_sum_pvld) : add_out_rdy;
assign fp16_pool_sum_prdy = fp_mean_pool_cfg & add_out_rdy & pipe_out_vld;
assign add_out_vld        = fp_mean_pool_cfg ? (pipe_out_vld & fp16_pool_sum_pvld) : pipe_out_vld;
assign add_out_rdy        = ~pooling_out_vld | pooling_out_prdy;

assign int_pooling_sync       = pipe_out_pd[87:0];
assign datain_ext_sync        = pipe_out_pd[175:88];
assign pooling_din_1st_sync   = pipe_out_pd[176];
assign pdp_din_lc_f_sync      = pipe_out_pd[177];
assign buf_sel_sync           = pipe_out_pd[179:178];
assign cur_datin_disable_sync = pipe_out_pd[180];
assign pooling_out_size_sync  = pipe_out_pd[183:181];
assign pooling_din_last_sync  = pipe_out_pd[184];

assign pool_fun_vld       = fp_mean_pool_cfg ? 1'b0 : load_din;
assign int_pool_datin_ext = pool_fun_vld ? datain_ext : 88'd0;
assign int_pool_cur_dat   = pool_fun_vld ? cur_pooling_dat[87:0] : 88'd0;
assign int_pooling        = pooling_fun(reg2dp_int8_en, reg2dp_int16_en, reg2dp_fp16_en, pooling_type_cfg[1:0], int_pool_cur_dat, int_pool_datin_ext);
assign pooling_result     = pooling_din_1st_sync ? datain_ext_sync : int_pooling_sync;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    fp_pool_sum_result0_d3 <= 68'd0;
    fp_pool_sum_result1_d3 <= 68'd0;
    fp_pool_sum_result2_d3 <= 68'd0;
    fp_pool_sum_result3_d3 <= 68'd0;
    latch_result0_d3       <= 88'd0;
    latch_result1_d3       <= 88'd0;
    latch_result2_d3       <= 88'd0;
    latch_result3_d3       <= 88'd0;
  end else if (add_out_vld & add_out_rdy) begin
    case (buf_sel_sync)
      2'd0: begin fp_pool_sum_result0_d3 <= fp_pool_sum; latch_result0_d3 <= pooling_result; end
      2'd1: begin fp_pool_sum_result1_d3 <= fp_pool_sum; latch_result1_d3 <= pooling_result; end
      2'd2: begin fp_pool_sum_result2_d3 <= fp_pool_sum; latch_result2_d3 <= pooling_result; end
      default: begin fp_pool_sum_result3_d3 <= fp_pool_sum; latch_result3_d3 <= pooling_result; end
    endcase
  end
end

assign fp_pool_sum_use0 = {5'd0, fp_pool_sum_result0_d3[67:51], 5'd0, fp_pool_sum_result0_d3[50:34], 5'd0, fp_pool_sum_result0_d3[33:17], 5'd0, fp_pool_sum_result0_d3[16:0]};
assign fp_pool_sum_use1 = {5'd0, fp_pool_sum_result1_d3[67:51], 5'd0, fp_pool_sum_result1_d3[50:34], 5'd0, fp_pool_sum_result1_d3[33:17], 5'd0, fp_pool_sum_result1_d3[16:0]};
assign fp_pool_sum_use2 = {5'd0, fp_pool_sum_result2_d3[67:51], 5'd0, fp_pool_sum_result2_d3[50:34], 5'd0, fp_pool_sum_result2_d3[33:17], 5'd0, fp_pool_sum_result2_d3[16:0]};
assign fp_pool_sum_use3 = {5'd0, fp_pool_sum_result3_d3[67:51], 5'd0, fp_pool_sum_result3_d3[50:34], 5'd0, fp_pool_sum_result3_d3[33:17], 5'd0, fp_pool_sum_result3_d3[16:0]};

assign data_buf0   = fp_mean_pool_cfg ? fp_pool_sum_use0 : latch_result0_d3;
assign data_buf1   = fp_mean_pool_cfg ? fp_pool_sum_use1 : latch_result1_d3;
assign data_buf2   = fp_mean_pool_cfg ? fp_pool_sum_use2 : latch_result2_d3;
assign data_buf3   = fp_mean_pool_cfg ? fp_pool_sum_use3 : latch_result3_d3;
assign data_buf_lc = pdp_din_lc_f_sync;

assign pooling_out_vld  = add_out_vld;
assign pooling_out_pvld = pooling_out_vld;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    pooling_cnt <= 2'd0;
  end else if (pooling_out_vld & pooling_out_prdy & ((pooling_din_last_sync & (~cur_datin_disable_sync)) | last_out_en)) begin
    pooling_cnt <= pooling_cnt + 2'd1;
  end
end

always @(*) begin
  case (pooling_cnt)
    2'd0:    pooling_out = {data_buf_lc, pooling_out_size_sync, data_buf0};
    2'd1:    pooling_out = {data_buf_lc, pooling_out_size_sync, data_buf1};
    2'd2:    pooling_out = {data_buf_lc, pooling_out_size_sync, data_buf2};
    default: pooling_out = {data_buf_lc, pooling_out_size_sync, data_buf3};
  endcase
end

endmodule // NV_NVDLA_PDP_CORE_unit1d

module NV_NVDLA_PDP_CORE_UNIT1D_pipe_p1 (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,pipe_in_pd_d0
  ,pipe_in_rdy_d1
  ,pipe_in_vld_d0
  ,pipe_in_pd_d1
  ,pipe_in_rdy_d0
  ,pipe_in_vld_d1
  );
input          nvdla_core_clk;
input          nvdla_core_rstn;
input  [184:0] pipe_in_pd_d0;
input          pipe_in_rdy_d1;
input          pipe_in_vld_d0;
output [184:0] pipe_in_pd_d1;
output         pipe_in_rdy_d0;
output         pipe_in_vld_d1;
reg    [184:0] p1_pipe_data;
reg            p1_pipe_ready;
reg            p1_pipe_ready_bc;
reg            p1_pipe_valid;
reg    [184:0] pipe_in_pd_d1;
reg            pipe_in_rdy_d0;
reg            pipe_in_vld_d1;
always @(
  p1_pipe_ready
  or p1_pipe_valid
  ) begin
  p1_pipe_ready_bc = p1_pipe_ready || !p1_pipe_valid;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p1_pipe_valid <= 1'b0;
  end else begin
  p1_pipe_valid <= (p1_pipe_ready_bc)? pipe_in_vld_d0 : 1'd1;
  end
end
always @(posedge nvdla_core_clk) begin
  p1_pipe_data <= (p1_pipe_ready_bc && pipe_in_vld_d0)? pipe_in_pd_d0[184:0] : p1_pipe_data;
end
always @(
  p1_pipe_ready_bc
  ) begin
  pipe_in_rdy_d0 = p1_pipe_ready_bc;
end
always @(
  p1_pipe_valid
  or pipe_in_rdy_d1
  or p1_pipe_data
  ) begin
  pipe_in_vld_d1 = p1_pipe_valid;
  p1_pipe_ready = pipe_in_rdy_d1;
  pipe_in_pd_d1[184:0] = p1_pipe_data;
end
`ifndef VIVA_PLUGIN_PIPE_DISABLE_ASSERTIONS
wire p1_assert_clk = nvdla_core_clk;
`endif
endmodule // NV_NVDLA_PDP_CORE_UNIT1D_pipe_p1

module NV_NVDLA_PDP_CORE_UNIT1D_pipe_p2 (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,pipe_in_pd_d1
  ,pipe_in_rdy_d2
  ,pipe_in_vld_d1
  ,pipe_in_pd_d2
  ,pipe_in_rdy_d1
  ,pipe_in_vld_d2
  );
input          nvdla_core_clk;
input          nvdla_core_rstn;
input  [184:0] pipe_in_pd_d1;
input          pipe_in_rdy_d2;
input          pipe_in_vld_d1;
output [184:0] pipe_in_pd_d2;
output         pipe_in_rdy_d1;
output         pipe_in_vld_d2;
reg    [184:0] p2_pipe_data;
reg            p2_pipe_ready;
reg            p2_pipe_ready_bc;
reg            p2_pipe_valid;
reg    [184:0] pipe_in_pd_d2;
reg            pipe_in_rdy_d1;
reg            pipe_in_vld_d2;
always @(
  p2_pipe_ready
  or p2_pipe_valid
  ) begin
  p2_pipe_ready_bc = p2_pipe_ready || !p2_pipe_valid;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p2_pipe_valid <= 1'b0;
  end else begin
  p2_pipe_valid <= (p2_pipe_ready_bc)? pipe_in_vld_d1 : 1'd1;
  end
end
always @(posedge nvdla_core_clk) begin
  p2_pipe_data <= (p2_pipe_ready_bc && pipe_in_vld_d1)? pipe_in_pd_d1[184:0] : p2_pipe_data;
end
always @(
  p2_pipe_ready_bc
  ) begin
  pipe_in_rdy_d1 = p2_pipe_ready_bc;
end
always @(
  p2_pipe_valid
  or pipe_in_rdy_d2
  or p2_pipe_data
  ) begin
  pipe_in_vld_d2 = p2_pipe_valid;
  p2_pipe_ready = pipe_in_rdy_d2;
  pipe_in_pd_d2[184:0] = p2_pipe_data;
end
`ifndef VIVA_PLUGIN_PIPE_DISABLE_ASSERTIONS
wire p2_assert_clk = nvdla_core_clk;
`endif
endmodule // NV_NVDLA_PDP_CORE_UNIT1D_pipe_p2

module NV_NVDLA_PDP_CORE_UNIT1D_pipe_p3 (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,pipe_in_pd_d2
  ,pipe_in_rdy_d3
  ,pipe_in_vld_d2
  ,pipe_in_pd_d3
  ,pipe_in_rdy_d2
  ,pipe_in_vld_d3
  );
input          nvdla_core_clk;
input          nvdla_core_rstn;
input  [184:0] pipe_in_pd_d2;
input          pipe_in_rdy_d3;
input          pipe_in_vld_d2;
output [184:0] pipe_in_pd_d3;
output         pipe_in_rdy_d2;
output         pipe_in_vld_d3;
reg    [184:0] p3_pipe_data;
reg            p3_pipe_ready;
reg            p3_pipe_ready_bc;
reg            p3_pipe_valid;
reg    [184:0] pipe_in_pd_d3;
reg            pipe_in_rdy_d2;
reg            pipe_in_vld_d3;
always @(
  p3_pipe_ready
  or p3_pipe_valid
  ) begin
  p3_pipe_ready_bc = p3_pipe_ready || !p3_pipe_valid;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p3_pipe_valid <= 1'b0;
  end else begin
  p3_pipe_valid <= (p3_pipe_ready_bc)? pipe_in_vld_d2 : 1'd1;
  end
end
always @(posedge nvdla_core_clk) begin
  p3_pipe_data <= (p3_pipe_ready_bc && pipe_in_vld_d2)? pipe_in_pd_d2[184:0] : p3_pipe_data;
end
always @(
  p3_pipe_ready_bc
  ) begin
  pipe_in_rdy_d2 = p3_pipe_ready_bc;
end
always @(
  p3_pipe_valid
  or pipe_in_rdy_d3
  or p3_pipe_data
  ) begin
  pipe_in_vld_d3 = p3_pipe_valid;
  p3_pipe_ready = pipe_in_rdy_d3;
  pipe_in_pd_d3[184:0] = p3_pipe_data;
end
`ifndef VIVA_PLUGIN_PIPE_DISABLE_ASSERTIONS
wire p3_assert_clk = nvdla_core_clk;
`endif
endmodule // NV_NVDLA_PDP_CORE_UNIT1D_pipe_p3

module NV_NVDLA_PDP_CORE_UNIT1D_pipe_p4 (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,pipe_in_pd_d3
  ,pipe_in_rdy_d4
  ,pipe_in_vld_d3
  ,pipe_in_pd_d4
  ,pipe_in_rdy_d3
  ,pipe_in_vld_d4
  );
input          nvdla_core_clk;
input          nvdla_core_rstn;
input  [184:0] pipe_in_pd_d3;
input          pipe_in_rdy_d4;
input          pipe_in_vld_d3;
output [184:0] pipe_in_pd_d4;
output         pipe_in_rdy_d3;
output         pipe_in_vld_d4;
reg    [184:0] p4_pipe_data;
reg            p4_pipe_ready;
reg            p4_pipe_ready_bc;
reg            p4_pipe_valid;
reg    [184:0] pipe_in_pd_d4;
reg            pipe_in_rdy_d3;
reg            pipe_in_vld_d4;
always @(
  p4_pipe_ready
  or p4_pipe_valid
  ) begin
  p4_pipe_ready_bc = p4_pipe_ready || !p4_pipe_valid;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p4_pipe_valid <= 1'b0;
  end else begin
  p4_pipe_valid <= (p4_pipe_ready_bc)? pipe_in_vld_d3 : 1'd1;
  end
end
always @(posedge nvdla_core_clk) begin
  p4_pipe_data <= (p4_pipe_ready_bc && pipe_in_vld_d3)? pipe_in_pd_d3[184:0] : p4_pipe_data;
end
always @(
  p4_pipe_ready_bc
  ) begin
  pipe_in_rdy_d3 = p4_pipe_ready_bc;
end
always @(
  p4_pipe_valid
  or pipe_in_rdy_d4
  or p4_pipe_data
  ) begin
  pipe_in_vld_d4 = p4_pipe_valid;
  p4_pipe_ready = pipe_in_rdy_d4;
  pipe_in_pd_d4[184:0] = p4_pipe_data;
end
`ifndef VIVA_PLUGIN_PIPE_DISABLE_ASSERTIONS
wire p4_assert_clk = nvdla_core_clk;
`endif
endmodule // NV_NVDLA_PDP_CORE_UNIT1D_pipe_p4


