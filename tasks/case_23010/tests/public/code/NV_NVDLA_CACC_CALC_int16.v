// ================================================================
// NVDLA Open Source Project
// 
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with 
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_CACC_CALC_int16.v

module NV_NVDLA_CACC_CALC_int16 (
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
input  [37:0] in_data;
input  [47:0] in_op;
input         in_op_valid;
input         in_sel;
input         in_valid;
output [31:0] out_final_data;
output        out_final_sat;
output        out_final_valid;
output [47:0] out_partial_data;
output        out_partial_valid;

input nvdla_core_clk;
input nvdla_core_rstn;

reg           di_sign_d;
reg    [15:0] i_hsame_sign;
reg    [16:0] i_hsum_pd;
reg    [32:0] i_lsum_pd;
reg    [47:0] i_sat_pd3;
reg           i_sat_sel;
reg           i_sat_vld;
reg           in_hsb_same_d;
reg           oi_sign_d;
reg    [31:0] out_final_data;
reg           out_final_sat;
reg           out_final_valid;
reg    [47:0] out_partial_data;
reg           out_partial_valid;
wire    [5:0] di_hsb_pd;
wire    [5:0] di_hsb_pd_tmp;
wire   [31:0] di_lsb_pd;
wire          di_sign;
wire   [31:0] i_final_result;
wire          i_final_vld;
wire          i_guide;
wire          i_hsum_msb;
wire   [16:0] i_hsum_pd_nxt;
wire          i_hsum_sign;
wire   [47:0] i_last_pd;
wire   [48:0] i_last_pd3;
wire          i_lsum_msb;
wire    [1:0] i_lsum_msb_nxt;
wire    [1:0] i_lsum_msb_tmp;
wire   [32:0] i_lsum_pd_nxt;
wire   [47:0] i_partial_result;
wire          i_partial_vld;
wire          i_point5;
wire   [31:0] i_pos_pd;
wire   [47:0] i_pre_sft_pd;
wire   [47:0] i_sat_pd;
wire          i_sat_sign;
wire          i_sel;
wire   [31:0] i_sft_max;
wire          i_sft_need_sat;
wire   [47:0] i_sft_pd;
wire   [14:0] i_stick;
wire   [31:0] i_tru_pd;
wire          i_vld;
wire          in_hsb_same;
wire   [47:0] in_mask_op;
wire          mon_pos_pd_c;
wire   [15:0] oi_hsb_pd;
wire   [15:0] oi_hsb_pd_tmp;
wire   [31:0] oi_lsb_pd;
wire          oi_sign;

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

assign in_mask_op = in_op_valid ? in_op[47:0] : 48'b0;

assign di_sign     = in_data[38  -1];
assign oi_sign     = in_mask_op[48  -1];
assign di_lsb_pd   = in_data[31:0];
assign oi_lsb_pd   = in_mask_op[31:0];
assign di_hsb_pd   = in_data[37:32];
assign oi_hsb_pd   = in_mask_op[47:32];
assign in_hsb_same = (di_hsb_pd == {6{1'b0}} || di_hsb_pd == {6{1'b1}}) && 
                     (oi_hsb_pd == {16{1'b0}} || oi_hsb_pd == {16{1'b1}}); 

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
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    di_sign_d <= 1'b0;
  end else begin
  if ((i_vld) == 1'b1) begin
    di_sign_d <= di_sign;
  end
  end
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    oi_sign_d <= 1'b0;
  end else begin
  if ((i_vld) == 1'b1) begin
    oi_sign_d <= oi_sign;
  end
  end
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    in_hsb_same_d <= 1'b0;
  end else begin
  if ((i_vld) == 1'b1) begin
    in_hsb_same_d <= in_hsb_same;
  end
  end
end

//====================
// Addition
//====================
assign i_lsum_pd_nxt[32:0] = di_lsb_pd + oi_lsb_pd;
assign i_lsum_msb_nxt = {1'b0, i_lsum_pd_nxt[32 +1 -1]};

//pipeline1
always @(posedge nvdla_core_clk) begin
  if ((i_vld) == 1'b1) begin
    i_lsum_pd <= i_lsum_pd_nxt;
  end
end
assign i_lsum_msb = i_lsum_pd[32 +1 -1];

//branch3 high 16bits add
assign di_hsb_pd_tmp  = ~in_hsb_same ? di_hsb_pd : {6{1'b0}};
assign oi_hsb_pd_tmp  = ~in_hsb_same ? oi_hsb_pd : {16{1'b0}};
assign i_lsum_msb_tmp = ~in_hsb_same ? i_lsum_msb_nxt : 2'b0;
assign i_hsum_pd_nxt[16:0] = $signed(di_hsb_pd_tmp) + $signed(oi_hsb_pd_tmp) + $signed(i_lsum_msb_tmp);
always @(posedge nvdla_core_clk) begin
  if ((i_vld & ~in_hsb_same) == 1'b1) begin
    i_hsum_pd <= i_hsum_pd_nxt;
  end
end
assign i_last_pd3 = {i_hsum_pd,i_lsum_pd[31:0]};

//branch1 & 2
always @(
  di_sign_d
  or oi_sign_d
  or i_lsum_msb
  ) begin
    if (di_sign_d ^ oi_sign_d) begin                   //branch1
        i_hsame_sign = {16{~i_lsum_msb}};
    end else begin                                     //branch2 
        i_hsame_sign = {{15{oi_sign_d}},i_lsum_msb};
    end
end
assign i_last_pd   = {i_hsame_sign,i_lsum_pd[31:0]};

// branch3 narrow down to 48bit, and need satuation only
assign i_hsum_sign = i_hsum_pd[48 - 32   ];
assign i_hsum_msb  = i_hsum_pd[48 - 32   -1];

always @(
  i_hsum_sign
  or i_hsum_msb
  or i_last_pd3
  ) begin
    if (i_hsum_sign ^ i_hsum_msb) begin
        i_sat_pd3 = {i_hsum_sign,{47{~i_hsum_sign}}};
    end else begin
        i_sat_pd3 = {i_hsum_sign,i_last_pd3[46:0]};
    end
end

assign i_sat_pd = in_hsb_same_d ? i_last_pd : i_sat_pd3;
assign i_partial_result = i_sat_pd;

//====================
// narrow down to 32bit, and need rounding and satuation 
//====================
assign i_pre_sft_pd = i_sat_sel ? i_sat_pd[47:0] : {48{1'b0}};
assign i_sat_sign   = i_sat_pd[48  -1];
assign {i_sft_pd[47:0], i_guide, i_stick[14:0]} = ($signed({i_pre_sft_pd, 16'b0}) >>> cfg_truncate);

assign i_sft_need_sat = (i_sat_sign  & ~(&i_sft_pd[46:31])) |
                        (~i_sat_sign &  (|i_sft_pd[46:31])) |
                        (~i_sat_sign & (&{i_sft_pd[30:0], i_point5}));
assign i_sft_max = i_sat_sign ? {1'b1, 31'b0} : ~{1'b1, 31'b0};

assign i_point5 = i_sat_sel & i_guide & (~i_sat_sign | (|i_stick));
assign {mon_pos_pd_c,i_pos_pd[31:0]} = i_sft_pd[31:0] + i_point5;

assign i_tru_pd = i_pos_pd;
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

endmodule // NV_NVDLA_CACC_CALC_int16

