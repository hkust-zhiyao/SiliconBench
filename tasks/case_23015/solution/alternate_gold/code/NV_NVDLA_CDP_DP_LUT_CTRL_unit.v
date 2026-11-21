// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_CDP_DP_LUT_CTRL_unit.v

module cdp_lut_rv_pipe #(
  parameter DW = 56
) (
  input           clk,
  input           rstn,
  input           in_vld,
  output          in_rdy,
  input  [DW-1:0] in_pd,
  output          out_vld,
  input           out_rdy,
  output [DW-1:0] out_pd
);
  reg          v_r;
  reg [DW-1:0] d_r;
  assign in_rdy  = ~v_r | out_rdy;
  assign out_vld = v_r;
  assign out_pd  = d_r;
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      v_r <= 1'b0;
      d_r <= {DW{1'b0}};
    end else begin
      if (in_vld) v_r <= 1'b1;
      else if (out_rdy) v_r <= 1'b0;
      if (in_vld & in_rdy) d_r <= in_pd;
    end
  end
endmodule

module NV_NVDLA_CDP_DP_LUT_CTRL_unit (
   nvdla_core_clk
  ,nvdla_op_gated_clk_fp16
  ,nvdla_op_gated_clk_int
  ,nvdla_core_rstn
  ,dp2lut_prdy
  ,fp16_en
  ,int16_en
  ,int8_en
  ,reg2dp_lut_le_function
  ,reg2dp_lut_le_index_offset
  ,reg2dp_lut_le_index_select
  ,reg2dp_lut_le_start_high
  ,reg2dp_lut_le_start_low
  ,reg2dp_lut_lo_index_select
  ,reg2dp_lut_lo_start_high
  ,reg2dp_lut_lo_start_low
  ,reg2dp_sqsum_bypass
  ,sum2itp_pd
  ,sum2itp_pvld
  ,dp2lut_X_info
  ,dp2lut_X_pd
  ,dp2lut_Y_info
  ,dp2lut_Y_pd
  ,dp2lut_pvld
  ,sum2itp_prdy
  );
input          nvdla_core_clk;
input          nvdla_op_gated_clk_fp16;
input          nvdla_op_gated_clk_int;
input          nvdla_core_rstn;
input          dp2lut_prdy;
input          fp16_en;
input          int16_en;
input          int8_en;
input          reg2dp_lut_le_function;
input    [7:0] reg2dp_lut_le_index_offset;
input    [7:0] reg2dp_lut_le_index_select;
input    [5:0] reg2dp_lut_le_start_high;
input   [31:0] reg2dp_lut_le_start_low;
input    [7:0] reg2dp_lut_lo_index_select;
input    [5:0] reg2dp_lut_lo_start_high;
input   [31:0] reg2dp_lut_lo_start_low;
input          reg2dp_sqsum_bypass;
input   [41:0] sum2itp_pd;
input          sum2itp_pvld;
output  [35:0] dp2lut_X_info;
output  [19:0] dp2lut_X_pd;
output  [35:0] dp2lut_Y_info;
output  [19:0] dp2lut_Y_pd;
output         dp2lut_pvld;
output         sum2itp_prdy;

reg       cfg_le_exp_q;
reg [7:0] cfg_lo_sel_q;
reg       cfg_sqbyp_q;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    cfg_le_exp_q <= 1'b0;
    cfg_lo_sel_q <= 8'd0;
    cfg_sqbyp_q  <= 1'b0;
  end else begin
    cfg_le_exp_q <= ~reg2dp_lut_le_function;
    cfg_lo_sel_q <= reg2dp_lut_lo_index_select;
    cfg_sqbyp_q  <= reg2dp_sqsum_bypass;
  end
end

wire fp_in_rdy, int_in_rdy;
assign sum2itp_prdy = fp16_en ? fp_in_rdy : int_in_rdy;

wire [37:0] le_start_s38 = {reg2dp_lut_le_start_high, reg2dp_lut_le_start_low};
wire [37:0] lo_start_s38 = {reg2dp_lut_lo_start_high, reg2dp_lut_lo_start_low};

// =========================================================================
// Binary-tree MSB index helper (64-bit -> 6-bit index)
// =========================================================================
function [5:0] btree_msb64(input [63:0] x);
  reg [31:0] s32;
  reg [15:0] s16;
  reg  [7:0] s8;
  reg  [3:0] s4;
  reg  [1:0] s2;
  reg  [5:0] r;
  begin
    r[5] = |x[63:32]; s32 = r[5] ? x[63:32] : x[31:0];
    r[4] = |s32[31:16]; s16 = r[4] ? s32[31:16] : s32[15:0];
    r[3] = |s16[15:8];  s8  = r[3] ? s16[15:8]  : s16[7:0];
    r[2] = |s8[7:4];    s4  = r[2] ? s8[7:4]    : s8[3:0];
    r[1] = |s4[3:2];    s2  = r[1] ? s4[3:2]    : s4[1:0];
    r[0] = s2[1];
    btree_msb64 = r;
  end
endfunction

// =========================================================================
// INT8 / INT16 X & Y pipelines
// =========================================================================
wire [20:0] raw_i8_lo = int8_en  ? sum2itp_pd[20:0]  : 21'd0;
wire [20:0] raw_i8_hi = int8_en  ? sum2itp_pd[41:21] : 21'd0;
wire [36:0] raw_i16   = int16_en ? sum2itp_pd[36:0]  : 37'd0;

wire [37:0] in_lsb_s38 = int16_en ? {cfg_sqbyp_q & raw_i16[36], raw_i16}
                       : int8_en  ? {{17{cfg_sqbyp_q & raw_i8_lo[20]}}, raw_i8_lo}
                       : 38'd0;
wire [21:0] in_msb_s22 = int8_en  ? {cfg_sqbyp_q & raw_i8_hi[20], raw_i8_hi} : 22'd0;

wire ix_rdy0, iy_rdy0;
wire int_vld = (~fp16_en) & sum2itp_pvld;
assign int_in_rdy = ix_rdy0 & iy_rdy0;

// INT X Stage 0: offset subtract
wire x_uf0_lo = ($signed(in_lsb_s38) <= $signed(le_start_s38));
wire x_uf0_hi = ($signed(in_msb_s22) <= $signed(le_start_s38[21:0]));
wire [37:0] x_diff_lo = x_uf0_lo ? 38'd0 : (in_lsb_s38 - le_start_s38);
wire [21:0] x_diff_hi = x_uf0_hi ? 22'd0 : (in_msb_s22 - le_start_s38[21:0]);

wire        ix_v0, ix_r1;
wire [61:0] ix_d0;
cdp_lut_rv_pipe #(.DW(62)) u_ix_p0 (
  .clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn),
  .in_vld(int_vld & iy_rdy0), .in_rdy(ix_rdy0),
  .in_pd({x_uf0_hi, x_uf0_lo, x_diff_hi, x_diff_lo}),
  .out_vld(ix_v0), .out_rdy(ix_r1), .out_pd(ix_d0)
);

// INT X Stage 1: binary-tree LZC + mantissa slice
wire [37:0] s0_x_lo  = ix_d0[37:0];
wire [21:0] s0_x_hi  = ix_d0[59:38];
wire  [1:0] s0_x_uf  = ix_d0[61:60];
wire  [5:0] b_idx_lo = btree_msb64({26'd0, s0_x_lo});
wire  [5:0] b_idx_hi = btree_msb64({42'd0, s0_x_hi});
wire [53:0] b_sh_lo  = {s0_x_lo, 16'd0} << (6'd37 - b_idx_lo);
wire [37:0] b_sh_hi  = {s0_x_hi, 16'd0} << (5'd21 - b_idx_hi[4:0]);

wire [37:0] s1_lo_nxt = s0_x_uf[0] ? 38'd0 : (cfg_le_exp_q ? {32'd0, b_idx_lo}      : s0_x_lo);
wire [21:0] s1_hi_nxt = s0_x_uf[1] ? 22'd0 : (cfg_le_exp_q ? {17'd0, b_idx_hi[4:0]} : s0_x_hi);
wire [15:0] s1_fl_nxt = (s0_x_uf[0] | (~|s0_x_lo)) ? 16'd0 : b_sh_lo[52:37];
wire [15:0] s1_fh_nxt = (s0_x_uf[1] | (~|s0_x_hi)) ? 16'd0 : b_sh_hi[36:21];

wire        ix_v1, ix_r2;
wire [93:0] ix_d1;
cdp_lut_rv_pipe #(.DW(94)) u_ix_p1 (
  .clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn),
  .in_vld(ix_v0), .in_rdy(ix_r1),
  .in_pd({s0_x_uf, s1_fh_nxt, s1_fl_nxt, s1_hi_nxt, s1_lo_nxt}),
  .out_vld(ix_v1), .out_rdy(ix_r2), .out_pd(ix_d1)
);

// INT X Stage 2: exponential offset subtract
wire [37:0] s1_x_lo = ix_d1[37:0];
wire [21:0] s1_x_hi = ix_d1[59:38];
wire [31:0] s1_frac = ix_d1[91:60];
wire  [1:0] s1_uf   = ix_d1[93:92];

wire exp_uf_lo = (~s1_uf[0]) & cfg_le_exp_q & (~reg2dp_lut_le_index_offset[7]) & (s1_x_lo < {31'd0, reg2dp_lut_le_index_offset[6:0]});
wire exp_uf_hi = (~s1_uf[1]) & cfg_le_exp_q & (~reg2dp_lut_le_index_offset[7]) & (s1_x_hi < {15'd0, reg2dp_lut_le_index_offset[6:0]});

wire [38:0] s2_lo_nxt = (s1_uf[0] | exp_uf_lo) ? 39'd0
                      : cfg_le_exp_q ? ($signed({1'b0, s1_x_lo}) - $signed({{31{reg2dp_lut_le_index_offset[7]}}, reg2dp_lut_le_index_offset}))
                      : {1'b0, s1_x_lo};
wire [22:0] s2_hi_nxt = (s1_uf[1] | exp_uf_hi) ? 23'd0
                      : cfg_le_exp_q ? ($signed({1'b0, s1_x_hi}) - $signed({{15{reg2dp_lut_le_index_offset[7]}}, reg2dp_lut_le_index_offset}))
                      : {1'b0, s1_x_hi};
wire  [1:0] s2_uf_nxt = s1_uf | {exp_uf_hi, exp_uf_lo};

wire        ix_v2, ix_r3;
wire [95:0] ix_d2;
cdp_lut_rv_pipe #(.DW(96)) u_ix_p2 (
  .clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn),
  .in_vld(ix_v1), .in_rdy(ix_r2),
  .in_pd({s2_uf_nxt, s1_frac, s2_hi_nxt, s2_lo_nxt}),
  .out_vld(ix_v2), .out_rdy(ix_r3), .out_pd(ix_d2)
);

// INT X Stage 3: linear index select scaling
wire [38:0] s2_x_lo  = ix_d2[38:0];
wire [22:0] s2_x_hi  = ix_d2[61:39];
wire [31:0] s2_efrac = ix_d2[93:62];
wire  [1:0] s2_uf    = ix_d2[95:94];

wire  [7:0] x_sel_b   = cfg_le_exp_q ? 8'd0 : reg2dp_lut_le_index_select;
wire        xl_neg    = int16_en ? x_sel_b[6] : x_sel_b[5];
wire  [6:0] xl_mag    = int16_en ? (x_sel_b[6] ? (7'd64 - {1'b0, x_sel_b[5:0]}) : {1'b0, x_sel_b[5:0]})
                                 : (x_sel_b[5] ? (7'd32 - {2'b00, x_sel_b[4:0]}) : {2'b00, x_sel_b[4:0]});
wire [38:0] xl_in     = int16_en ? s2_x_lo : {16'd0, s2_x_lo[22:0]};
wire [54:0] xl_r_algn = (xl_mag >= 7'd55) ? 55'd0 : ({xl_in, 16'd0} >> xl_mag[5:0]);
wire [11:0] xl_l_algn = {6'd0, xl_in[5:0]} << xl_mag[2:0];
wire        xl_l_sat  = (xl_mag >= 7'd6) ? (|xl_in) : ((|xl_in[38:6]) | (xl_l_algn >= 12'd64));
wire        xl_r_sat  = (xl_r_algn[54:16] >= 39'd64);
wire        s3_x_of_lo = s2_uf[0] ? 1'b0 : (xl_neg ? xl_l_sat : xl_r_sat);
wire  [9:0] s3_x_ix_lo = s2_uf[0] ? 10'd0 : (s3_x_of_lo ? 10'd64 : (xl_neg ? xl_l_algn[9:0] : xl_r_algn[25:16]));
wire [15:0] s3_x_fr_lo = xl_neg ? 16'd0 : xl_r_algn[15:0];

wire        xh_neg    = x_sel_b[5];
wire  [5:0] xh_mag    = x_sel_b[5] ? (6'd32 - {1'b0, x_sel_b[4:0]}) : {1'b0, x_sel_b[4:0]};
wire [38:0] xh_r_algn = ({s2_x_hi, 16'd0} >> xh_mag[5:0]);
wire [11:0] xh_l_algn = {6'd0, s2_x_hi[5:0]} << xh_mag[2:0];
wire        xh_l_sat  = (xh_mag >= 6'd6) ? (|s2_x_hi) : ((|s2_x_hi[22:6]) | (xh_l_algn >= 12'd64));
wire        xh_r_sat  = (xh_r_algn[38:16] >= 23'd64);
wire        s3_x_of_hi = s2_uf[1] ? 1'b0 : (xh_neg ? xh_l_sat : xh_r_sat);
wire  [9:0] s3_x_ix_hi = s2_uf[1] ? 10'd0 : (s3_x_of_hi ? 10'd64 : (xh_neg ? xh_l_algn[9:0] : xh_r_algn[25:16]));
wire [15:0] s3_x_fr_hi = xh_neg ? 16'd0 : xh_r_algn[15:0];

wire        ix_v3, ix_out_rdy;
wire [87:0] ix_d3;
cdp_lut_rv_pipe #(.DW(88)) u_ix_p3 (
  .clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn),
  .in_vld(ix_v2), .in_rdy(ix_r3),
  .in_pd({s3_x_of_hi, s3_x_of_lo, s2_uf, s2_efrac, s3_x_fr_hi, s3_x_fr_lo, s3_x_ix_hi, s3_x_ix_lo}),
  .out_vld(ix_v3), .out_rdy(ix_out_rdy), .out_pd(ix_d3)
);

wire int_any = int16_en | int8_en;
wire [19:0] int_x_pd_out = {ix_d3[19:10], int_any ? ix_d3[9:0] : 10'd0};
wire [15:0] int_x_fl_out = cfg_le_exp_q ? ix_d3[67:52] : (int_any ? ix_d3[35:20] : 16'd0);
wire [15:0] int_x_fh_out = cfg_le_exp_q ? ix_d3[83:68] : ix_d3[51:36];
wire [35:0] int_x_if_out = {ix_d3[87], int_any ? ix_d3[86] : 1'b0, ix_d3[85:84], int_x_fh_out, int_x_fl_out};

// INT Y 4-stage pipeline
wire y_uf0_lo = ($signed(in_lsb_s38) <= $signed(lo_start_s38));
wire y_uf0_hi = ($signed(in_msb_s22) <= $signed(lo_start_s38[21:0]));
wire [37:0] y_diff_lo = y_uf0_lo ? 38'd0 : (in_lsb_s38 - lo_start_s38);
wire [21:0] y_diff_hi = y_uf0_hi ? 22'd0 : (in_msb_s22 - lo_start_s38[21:0]);

wire        iy_v0, iy_r1;
wire [61:0] iy_d0;
cdp_lut_rv_pipe #(.DW(62)) u_iy_p0 (
  .clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn),
  .in_vld(int_vld & ix_rdy0), .in_rdy(iy_rdy0),
  .in_pd({y_uf0_hi, y_uf0_lo, y_diff_hi, y_diff_lo}),
  .out_vld(iy_v0), .out_rdy(iy_r1), .out_pd(iy_d0)
);

wire [37:0] y0_lo  = iy_d0[37:0];
wire [21:0] y0_hi  = iy_d0[59:38];
wire  [1:0] y0_uf  = iy_d0[61:60];
wire        yl_neg = int16_en ? cfg_lo_sel_q[6] : cfg_lo_sel_q[5];
wire  [6:0] yl_mag = int16_en ? (cfg_lo_sel_q[6] ? (7'd64 - {1'b0, cfg_lo_sel_q[5:0]}) : {1'b0, cfg_lo_sel_q[5:0]})
                              : (cfg_lo_sel_q[5] ? (7'd32 - {2'b00, cfg_lo_sel_q[4:0]}) : {2'b00, cfg_lo_sel_q[4:0]});
wire [37:0] yl_in     = int16_en ? y0_lo : {16'd0, y0_lo[21:0]};
wire [53:0] yl_r_algn = (yl_mag >= 7'd54) ? 54'd0 : ({yl_in, 16'd0} >> yl_mag[5:0]);
wire [15:0] yl_l_algn = {8'd0, yl_in[7:0]} << yl_mag[2:0];
wire        yl_l_sat  = (yl_mag >= 7'd8) ? (|yl_in) : ((|yl_in[37:8]) | (yl_l_algn >= 16'd256));
wire        yl_r_sat  = (yl_r_algn[53:16] >= 38'd256);
wire        y1_of_lo  = y0_uf[0] ? 1'b0 : (yl_neg ? yl_l_sat : yl_r_sat);
wire  [9:0] y1_ix_lo  = y0_uf[0] ? 10'd0 : (y1_of_lo ? 10'd256 : (yl_neg ? yl_l_algn[9:0] : yl_r_algn[25:16]));
wire [15:0] y1_fr_lo  = yl_neg ? 16'd0 : yl_r_algn[15:0];

wire        yh_neg    = cfg_lo_sel_q[5];
wire  [5:0] yh_mag    = cfg_lo_sel_q[5] ? (6'd32 - {1'b0, cfg_lo_sel_q[4:0]}) : {1'b0, cfg_lo_sel_q[4:0]};
wire [37:0] yh_r_algn = ({y0_hi, 16'd0} >> yh_mag[5:0]);
wire [15:0] yh_l_algn = {8'd0, y0_hi[7:0]} << yh_mag[2:0];
wire        yh_l_sat  = (yh_mag >= 6'd8) ? (|y0_hi) : ((|y0_hi[21:8]) | (yh_l_algn >= 16'd256));
wire        yh_r_sat  = (yh_r_algn[37:16] >= 22'd256);
wire        y1_of_hi  = y0_uf[1] ? 1'b0 : (yh_neg ? yh_l_sat : yh_r_sat);
wire  [9:0] y1_ix_hi  = y0_uf[1] ? 10'd0 : (y1_of_hi ? 10'd256 : (yh_neg ? yh_l_algn[9:0] : yh_r_algn[25:16]));
wire [15:0] y1_fr_hi  = yh_neg ? 16'd0 : yh_r_algn[15:0];

wire        iy_v1, iy_r2, iy_v2, iy_r3, iy_v3, iy_out_rdy;
wire [55:0] iy_d1, iy_d2, iy_d3;
wire [55:0] iy_pack1 = {
  y1_of_hi, int_any ? y1_of_lo : 1'b0,
  y0_uf,
  y1_fr_hi, int_any ? y1_fr_lo : 16'd0,
  y1_ix_hi, int_any ? y1_ix_lo : 10'd0
};
cdp_lut_rv_pipe #(.DW(56)) u_iy_p1 (.clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn), .in_vld(iy_v0), .in_rdy(iy_r1), .in_pd(iy_pack1), .out_vld(iy_v1), .out_rdy(iy_r2),     .out_pd(iy_d1));
cdp_lut_rv_pipe #(.DW(56)) u_iy_p2 (.clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn), .in_vld(iy_v1), .in_rdy(iy_r2), .in_pd(iy_d1),    .out_vld(iy_v2), .out_rdy(iy_r3),     .out_pd(iy_d2));
cdp_lut_rv_pipe #(.DW(56)) u_iy_p3 (.clk(nvdla_op_gated_clk_int), .rstn(nvdla_core_rstn), .in_vld(iy_v2), .in_rdy(iy_r3), .in_pd(iy_d2),    .out_vld(iy_v3), .out_rdy(iy_out_rdy),.out_pd(iy_d3));

// =========================================================================
// FP16 / FP32 X & Y pipelines (bidirectional q = E - 127 - S alignment)
// =========================================================================
wire [31:0] fp_in_d  = fp16_en ? sum2itp_pd[31:0] : 32'd0;
wire        fx_r0, fy_r0;
wire        fp_vld   = fp16_en & sum2itp_pvld;
assign      fp_in_rdy = fx_r0 & fy_r0;

wire        fx_ar, fx_br, fx_s0_v, fx_s0_r;
wire [31:0] fx_sub_z;
assign fx_r0 = fx_ar & fx_br;
HLS_fp32_sub u_CDP_DP_LUTCTRL_XOFFSET (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (fp_in_d)
  ,.chn_a_rsc_vz   (fp_vld & fy_r0 & fx_br)
  ,.chn_a_rsc_lz   (fx_ar)
  ,.chn_b_rsc_z    (le_start_s38[31:0])
  ,.chn_b_rsc_vz   (fp_vld & fy_r0 & fx_ar)
  ,.chn_b_rsc_lz   (fx_br)
  ,.chn_o_rsc_z    (fx_sub_z)
  ,.chn_o_rsc_vz   (fx_s0_r)
  ,.chn_o_rsc_lz   (fx_s0_v)
  );

wire fx_nan  = (&fx_sub_z[30:23]) & (|fx_sub_z[22:0]);
wire fx_pinf = (~fx_sub_z[31]) & (&fx_sub_z[30:23]) & (~|fx_sub_z[22:0]);
wire fx_uf0  = fx_nan | (~|fx_sub_z) | fx_sub_z[31];
wire [31:0] fx_clean = fx_uf0 ? 32'd0 : fx_sub_z;
wire signed [9:0] fx_ediff = $signed({2'b00, fx_clean[30:23]}) - 10'sd127 - $signed({{2{reg2dp_lut_le_index_offset[7]}}, reg2dp_lut_le_index_offset});
wire        fx_euf = (~fx_uf0) & cfg_le_exp_q & (~fx_pinf) & fx_ediff[9];
wire  [8:0] fx_eix = (fx_uf0 | fx_euf) ? 9'd0 : (fx_pinf | (fx_ediff >= 10'sd64)) ? 9'd64 : fx_ediff[8:0];
wire [15:0] fx_efr = (fx_uf0 | fx_euf | (~cfg_le_exp_q) | fx_pinf) ? 16'd0 : fx_clean[22:7];

wire        fx_s1_v, fx_s1_r;
wire [58:0] fx_s1_d;
cdp_lut_rv_pipe #(.DW(59)) u_fx_p1 (
  .clk(nvdla_op_gated_clk_fp16), .rstn(nvdla_core_rstn),
  .in_vld(fx_s0_v), .in_rdy(fx_s0_r),
  .in_pd({fx_pinf, (fx_uf0 | fx_euf), fx_eix, fx_efr, fx_clean}),
  .out_vld(fx_s1_v), .out_rdy(fx_s1_r), .out_pd(fx_s1_d)
);

wire [31:0] fx1_dat  = fx_s1_d[31:0];
wire [15:0] fx1_efr  = fx_s1_d[47:32];
wire  [8:0] fx1_eix  = fx_s1_d[56:48];
wire        fx1_uf   = fx_s1_d[57];
wire        fx1_pinf = fx_s1_d[58];

wire signed [9:0] fx_q    = $signed({2'b00, fx1_dat[30:23]}) - 10'sd127 - $signed({{2{x_sel_b[7]}}, x_sel_b});
wire  [9:0] fx_rq         = -fx_q;
wire [47:0] fx_lsh48      = (fx_q >= 10'sd0 && fx_q <= 10'sd23) ? ({24'd0, 1'b1, fx1_dat[22:0]} << fx_q[4:0]) : 48'd0;
wire [23:0] fx_rsh24      = (fx_q < 10'sd0  && fx_rq <= 10'd16) ? ({1'b1, fx1_dat[22:0]} >> (5'd7 + fx_rq[4:0])) : 24'd0;
wire        fx_lin_of     = fx1_pinf | ((|fx1_dat) & ((fx_q > 10'sd23) | (fx_q >= 10'sd0 && fx_lsh48[47:23] >= 25'd64)));
wire  [9:0] fx_lin_ix     = fx_lin_of ? 10'd64 : ((~|fx1_dat) | (fx_q < 10'sd0)) ? 10'd0 : fx_lsh48[32:23];
wire [15:0] fx_lin_fr     = (fx1_pinf | (~|fx1_dat) | (fx_q > 10'sd23)) ? 16'd0 : (fx_q >= 10'sd0) ? fx_lsh48[22:7] : fx_rsh24[15:0];

wire        fx2_of_nxt    = fx1_uf ? 1'b0  : (cfg_le_exp_q ? (fx1_pinf | (fx1_eix >= 9'd64)) : fx_lin_of);
wire  [9:0] fx2_ix_nxt    = fx1_uf ? 10'd0 : (cfg_le_exp_q ? (fx2_of_nxt ? 10'd64 : {1'b0, fx1_eix}) : fx_lin_ix);
wire [15:0] fx2_fr_nxt    = fx1_uf ? 16'd0 : (cfg_le_exp_q ? fx1_efr : fx_lin_fr);

wire        fx_s2_v, fx_out_rdy;
wire [27:0] fx_s2_d;
cdp_lut_rv_pipe #(.DW(28)) u_fx_p2 (
  .clk(nvdla_op_gated_clk_fp16), .rstn(nvdla_core_rstn),
  .in_vld(fx_s1_v), .in_rdy(fx_s1_r),
  .in_pd({fx2_of_nxt, fx1_uf, fx2_fr_nxt, fx2_ix_nxt}),
  .out_vld(fx_s2_v), .out_rdy(fx_out_rdy), .out_pd(fx_s2_d)
);

// FP16 Y pipeline
wire        fy_ar, fy_br, fy_s0_v, fy_s0_r;
wire [31:0] fy_sub_z;
assign fy_r0 = fy_ar & fy_br;
HLS_fp32_sub u_CDP_DP_LUTCTRL_YOFFSET (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (fp_in_d)
  ,.chn_a_rsc_vz   (fp_vld & fx_r0 & fy_br)
  ,.chn_a_rsc_lz   (fy_ar)
  ,.chn_b_rsc_z    (lo_start_s38[31:0])
  ,.chn_b_rsc_vz   (fp_vld & fx_r0 & fy_ar)
  ,.chn_b_rsc_lz   (fy_br)
  ,.chn_o_rsc_z    (fy_sub_z)
  ,.chn_o_rsc_vz   (fy_s0_r)
  ,.chn_o_rsc_lz   (fy_s0_v)
  );

wire fy_nan  = (&fy_sub_z[30:23]) & (|fy_sub_z[22:0]);
wire fy_pinf = (~fy_sub_z[31]) & (&fy_sub_z[30:23]) & (~|fy_sub_z[22:0]);
wire fy_uf0  = fy_nan | (~|fy_sub_z) | fy_sub_z[31];

wire        fy_s1_v, fy_s1_r;
wire [33:0] fy_s1_d;
cdp_lut_rv_pipe #(.DW(34)) u_fy_p1 (
  .clk(nvdla_op_gated_clk_fp16), .rstn(nvdla_core_rstn),
  .in_vld(fy_s0_v), .in_rdy(fy_s0_r),
  .in_pd({fy_pinf, fy_uf0, fy_uf0 ? 32'd0 : fy_sub_z}),
  .out_vld(fy_s1_v), .out_rdy(fy_s1_r), .out_pd(fy_s1_d)
);

wire [31:0] fy1_dat  = fy_s1_d[31:0];
wire        fy1_uf   = fy_s1_d[32];
wire        fy1_pinf = fy_s1_d[33];
wire signed [9:0] fy_q    = $signed({2'b00, fy1_dat[30:23]}) - 10'sd127 - $signed({{2{cfg_lo_sel_q[7]}}, cfg_lo_sel_q});
wire  [9:0] fy_rq         = -fy_q;
wire [47:0] fy_lsh48      = (fy_q >= 10'sd0 && fy_q <= 10'sd23) ? ({24'd0, 1'b1, fy1_dat[22:0]} << fy_q[4:0]) : 48'd0;
wire [23:0] fy_rsh24      = (fy_q < 10'sd0  && fy_rq <= 10'd16) ? ({1'b1, fy1_dat[22:0]} >> (5'd7 + fy_rq[4:0])) : 24'd0;
wire        fy_lin_of     = (~fy1_uf) & (fy1_pinf | ((|fy1_dat) & ((fy_q > 10'sd23) | (fy_q >= 10'sd0 && fy_lsh48[47:23] >= 25'd256))));
wire  [9:0] fy_lin_ix     = fy1_uf ? 10'd0 : (fy_lin_of ? 10'd256 : ((~|fy1_dat) | (fy_q < 10'sd0)) ? 10'd0 : fy_lsh48[32:23]);
wire [15:0] fy_lin_fr     = (fy1_uf | fy1_pinf | (~|fy1_dat) | (fy_q > 10'sd23)) ? 16'd0 : (fy_q >= 10'sd0) ? fy_lsh48[22:7] : fy_rsh24[15:0];

wire        fy_s2_v, fy_out_rdy;
wire [27:0] fy_s2_d;
cdp_lut_rv_pipe #(.DW(28)) u_fy_p2 (
  .clk(nvdla_op_gated_clk_fp16), .rstn(nvdla_core_rstn),
  .in_vld(fy_s1_v), .in_rdy(fy_s1_r),
  .in_pd({fy_lin_of, fy1_uf, fy_lin_fr, fy_lin_ix}),
  .out_vld(fy_s2_v), .out_rdy(fy_out_rdy), .out_pd(fy_s2_d)
);

// Output join & mux
wire fp_sink_rdy  = fp16_en ? dp2lut_prdy : 1'b1;
wire int_sink_rdy = fp16_en ? 1'b1        : dp2lut_prdy;
assign ix_out_rdy = int_sink_rdy & iy_v3;
assign iy_out_rdy = int_sink_rdy & ix_v3;
assign fx_out_rdy = fp_sink_rdy  & fy_s2_v;
assign fy_out_rdy = fp_sink_rdy  & fx_s2_v;

assign dp2lut_pvld   = fp16_en ? (fx_s2_v & fy_s2_v) : (ix_v3 & iy_v3);
assign dp2lut_X_pd   = fp16_en ? {10'd0, fx_s2_d[9:0]}  : int_x_pd_out;
assign dp2lut_X_info = fp16_en ? {1'b0, fx_s2_d[27], 1'b0, fx_s2_d[26], 16'd0, fx_s2_d[25:10]} : int_x_if_out;
assign dp2lut_Y_pd   = fp16_en ? {10'd0, fy_s2_d[9:0]}  : iy_d3[19:0];
assign dp2lut_Y_info = fp16_en ? {1'b0, fy_s2_d[27], 1'b0, fy_s2_d[26], 16'd0, fy_s2_d[25:10]} : iy_d3[55:20];

endmodule // NV_NVDLA_CDP_DP_LUT_CTRL_unit
