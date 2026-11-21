// ================================================================
// NVDLA Open Source Project
// 
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with 
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_CACC_CALC_int8.v

module NV_NVDLA_CACC_CALC_int8 (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,cfg_truncate
  ,in_data
  ,in_op
  ,in_op_valid
  ,in_sel
  ,in_valid
  ,out_final_data
  ,out_final_sat
  ,out_final_valid
  ,out_partial_data
  ,out_partial_valid
  );
input   [4:0] cfg_truncate;
input  [21:0] in_data;
input  [33:0] in_op;
input         in_op_valid;
input         in_sel;
input         in_valid;
output [31:0] out_final_data;
output        out_final_sat;
output        out_final_valid;
output [33:0] out_partial_data;
output        out_partial_valid;

input nvdla_core_clk;
input nvdla_core_rstn;

reg    [32:0] i_sat_bits;
reg           i_sat_sel;
reg           i_sat_vld;
reg    [34:0] i_sum_pd;
reg    [31:0] out_final_data;
reg           out_final_sat;
reg           out_final_valid;
reg    [33:0] out_partial_data;
reg           out_partial_valid;
wire   [21:0] di_pd;
wire   [31:0] i_final_result;
wire          i_final_vld;
wire          i_guide;
wire   [33:0] i_partial_result;
wire          i_partial_vld;
wire          i_point5;
wire   [31:0] i_pos_pd;
wire   [33:0] i_pre_sft_pd;
wire   [33:0] i_sat_pd;
wire          i_sat_sign;
wire          i_sel;
wire   [31:0] i_sft_max;
wire          i_sft_need_sat;
wire   [33:0] i_sft_pd;
wire   [14:0] i_stick;
wire          i_sum_msb;
wire   [34:0] i_sum_pd_nxt;
wire          i_sum_sign;
wire   [31:0] i_tru_pd;
wire          i_vld;
wire   [33:0] in_mask_op;
wire          mon_pos_pd_c;
wire   [33:0] oi_pd;

// synoff nets

// monitor nets

// debug nets

// tie high nets

// tie low nets

// no connect nets

// not all bits used nets

// todo nets

    

assign i_sel = in_sel;
assign i_vld = in_valid;
assign in_mask_op = in_op_valid ? in_op[33:0] : 34'b0;

assign di_pd = in_data[21:0];
assign oi_pd = in_mask_op[33:0];

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    i_sat_vld <= 1'b0;
  end else begin
  i_sat_vld <= i_vld;
  end
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    i_sat_sel <= 1'b0;
  end else begin
  if ((i_vld) == 1'b1) begin
    i_sat_sel <= i_sel;
  end
  end
end

//====================
// Addition
//====================
assign i_sum_pd_nxt[34:0] = $signed(di_pd) + $signed(oi_pd);
always @(posedge nvdla_core_clk) begin
  if ((i_vld) == 1'b1) begin
    i_sum_pd <= i_sum_pd_nxt;
  end
end

//====================
// narrow down to 34bit, and need satuation only
//====================
assign i_sum_sign = i_sum_pd[34 +1 -1];
assign i_sum_msb  = i_sum_pd[34 +1 -2];
assign i_sat_sign = i_sum_sign;

always @(
  i_sum_sign
  or i_sum_msb
  or i_sum_pd
  ) begin
    if (i_sum_sign ^ i_sum_msb) begin // overflow, need satuation
        i_sat_bits = {33{~i_sum_sign}};
    end else begin
        i_sat_bits = i_sum_pd[32:0];
    end
end

assign i_sat_pd = {i_sat_sign,i_sat_bits};
assign i_partial_result = i_sat_pd;

//====================
// narrow down to 32bit, and need rounding and satuation 
//====================
assign i_pre_sft_pd = i_sat_sel ? i_sat_pd[33:0] : {34{1'b0}};
assign {i_sft_pd[33:0], i_guide, i_stick[14:0]} = ($signed({i_pre_sft_pd, 16'b0}) >>> cfg_truncate);

assign i_sft_need_sat = (i_sat_sign & ~(&i_sft_pd[32:31])) |
                        (~i_sat_sign & (|i_sft_pd[32:31])) |
                        (~i_sat_sign & (&{i_sft_pd[30:0], i_point5}));
assign i_sft_max      = i_sat_sign ? {1'b1, 31'b0} : ~{1'b1, 31'b0};

assign i_point5 = i_sat_sel & i_guide & (~i_sat_sign | (|i_stick));
assign {mon_pos_pd_c, i_pos_pd[31:0]} = i_sft_pd[31:0] + i_point5;
assign i_tru_pd   = i_pos_pd;

assign i_final_result = i_sft_need_sat ? i_sft_max : i_tru_pd;

assign i_partial_vld = i_sat_vld & ~i_sat_sel;
assign i_final_vld = i_sat_vld & i_sat_sel;

//====================
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    out_partial_valid <= 1'b0;
  end else begin
  out_partial_valid <= i_partial_vld;
  end
end
always @(posedge nvdla_core_clk) begin
  if ((i_partial_vld) == 1'b1) begin
    out_partial_data <= i_partial_result;
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    out_final_valid <= 1'b0;
  end else begin
  out_final_valid <= i_final_vld;
  end
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    out_final_sat <= 1'b0;
  end else begin
  out_final_sat <= i_final_vld & i_sft_need_sat;
  end
end
always @(posedge nvdla_core_clk) begin
  if ((i_final_vld) == 1'b1) begin
    out_final_data <= i_final_result;
  end
end

endmodule // NV_NVDLA_CACC_CALC_int8

