// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_CDP_DP_LUT_CTRL_unit.v

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

reg       X_exp;
reg       X_exp_s;
reg [7:0] Y_shift_bits;
reg       sqsum_bypass_enable;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    X_exp               <= 1'b0;
    X_exp_s             <= 1'b0;
    Y_shift_bits        <= 8'd0;
    sqsum_bypass_enable <= 1'b0;
  end else begin
    X_exp               <= (reg2dp_lut_le_function == 1'h0);
    X_exp_s             <= (reg2dp_lut_le_function == 1'h0);
    Y_shift_bits        <= reg2dp_lut_lo_index_select;
    sqsum_bypass_enable <= (reg2dp_sqsum_bypass == 1'h1);
  end
end

wire fp_en_rdy, int_en_rdy;
assign sum2itp_prdy = fp16_en ? fp_en_rdy : int_en_rdy;
wire int_en_vld     = fp16_en ? 1'b0 : sum2itp_pvld;
wire fp_en_vld      = fp16_en ? sum2itp_pvld : 1'b0;

wire [20:0] datin_int8_lsb = {21{int8_en }} & sum2itp_pd[20:0];
wire [20:0] datin_int8_msb = {21{int8_en }} & sum2itp_pd[41:21];
wire [36:0] datin_int16    = {37{int16_en}} & sum2itp_pd[36:0];

wire [37:0] reg2dp_X_offset = {reg2dp_lut_le_start_high, reg2dp_lut_le_start_low};
wire [37:0] reg2dp_Y_offset = {reg2dp_lut_lo_start_high, reg2dp_lut_lo_start_low};

// =========================================================================
// INT8 / INT16 X and Y LUT index pipelines
// =========================================================================
wire int_X_datin_prdy, int_Y_datin_prdy;
wire int_X_proc_in_vld = int_en_vld & int_Y_datin_prdy;
wire int_Y_proc_in_vld = int_en_vld & int_X_datin_prdy;
assign int_en_rdy      = int_X_datin_prdy & int_Y_datin_prdy;

wire [37:0] dec_lsb_f0 = int16_en ? {1'b0, datin_int16} : (int8_en ? {17'd0, datin_int8_lsb} : 38'd0);
wire [21:0] dec_msb_f0 = int8_en  ? {1'b0, datin_int8_msb} : 22'd0;
wire [37:0] dec_lsb_f1 = int16_en ? {datin_int16[36], datin_int16} : (int8_en ? {{17{datin_int8_lsb[20]}}, datin_int8_lsb} : 38'd0);
wire [21:0] dec_msb_f1 = int8_en  ? {datin_int8_msb[20], datin_int8_msb} : 22'd0;
wire [37:0] dec_offset_datin_lsb = sqsum_bypass_enable ? dec_lsb_f1 : dec_lsb_f0;
wire [21:0] dec_offset_datin_msb = sqsum_bypass_enable ? dec_msb_f1 : dec_msb_f0;

wire x_le_lsb = ($signed(dec_offset_datin_lsb) <= $signed(reg2dp_X_offset));
wire x_le_msb = ($signed(dec_offset_datin_msb) <= $signed(reg2dp_X_offset[21:0]));

reg        int_stage0_pvld, int_stage1_pvld, int_stage2_pvld, int_stage3_pvld;
wire       int_stage3_prdy;
wire       int_stage2_prdy = ~int_stage3_pvld | int_stage3_prdy;
wire       int_stage1_prdy = ~int_stage2_pvld | int_stage2_prdy;
wire       int_stage0_prdy = ~int_stage1_pvld | int_stage1_prdy;
assign     int_X_datin_prdy = ~int_stage0_pvld | int_stage0_prdy;

wire load_in_intX    = int_X_proc_in_vld & int_X_datin_prdy;
wire load_int_stage0 = int_stage0_pvld   & int_stage0_prdy;
wire load_int_stage1 = int_stage1_pvld   & int_stage1_prdy;
wire load_int_stage2 = int_stage2_pvld   & int_stage2_prdy;

reg [37:0] dec_offset_lsb;
reg [21:0] dec_offset_msb;
reg        int_X_input_uflow_lsb, int_X_input_uflow_msb;

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_stage0_pvld       <= 1'b0;
    dec_offset_lsb        <= 38'd0;
    dec_offset_msb        <= 22'd0;
    int_X_input_uflow_lsb <= 1'b0;
    int_X_input_uflow_msb <= 1'b0;
  end else begin
    if (int_X_proc_in_vld) int_stage0_pvld <= 1'b1;
    else if (int_stage0_prdy) int_stage0_pvld <= 1'b0;

    if (load_in_intX) begin
      dec_offset_lsb        <= x_le_lsb ? 38'd0 : (dec_offset_datin_lsb - reg2dp_X_offset);
      int_X_input_uflow_lsb <= x_le_lsb;
      dec_offset_msb        <= x_le_msb ? 22'd0 : (dec_offset_datin_msb - reg2dp_X_offset[21:0]);
      int_X_input_uflow_msb <= x_le_msb;
    end
  end
end

// Stage 0 -> Stage 1: priority-index encoder + single 54b / 38b barrel shift
function [5:0] msb_idx38(input [37:0] v);
  integer i;
  begin
    msb_idx38 = 6'd0;
    for (i = 0; i < 38; i = i + 1)
      if (v[i]) msb_idx38 = i[5:0];
  end
endfunction

function [4:0] msb_idx22(input [21:0] v);
  integer i;
  begin
    msb_idx22 = 5'd0;
    for (i = 0; i < 22; i = i + 1)
      if (v[i]) msb_idx22 = i[4:0];
  end
endfunction

wire  [5:0] lsb_hi_idx  = msb_idx38(dec_offset_lsb);
wire [53:0] lsb_norm_sh = {dec_offset_lsb, 16'd0} << (6'd37 - lsb_hi_idx);
wire  [4:0] msb_hi_idx  = msb_idx22(dec_offset_msb);
wire [37:0] msb_norm_sh = {dec_offset_msb, 16'd0} << (5'd21 - msb_hi_idx);

reg [37:0] log2_datout_lsb;
reg [21:0] log2_datout_msb;
reg [15:0] exp_frac_lsb_q, exp_frac_msb_q;
reg  [1:0] int_X_input_uflow_d;

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_stage1_pvld     <= 1'b0;
    log2_datout_lsb     <= 38'd0;
    log2_datout_msb     <= 22'd0;
    exp_frac_lsb_q      <= 16'd0;
    exp_frac_msb_q      <= 16'd0;
    int_X_input_uflow_d <= 2'd0;
  end else begin
    if (int_stage0_pvld) int_stage1_pvld <= 1'b1;
    else if (int_stage1_prdy) int_stage1_pvld <= 1'b0;

    if (load_int_stage0) begin
      int_X_input_uflow_d <= {int_X_input_uflow_msb, int_X_input_uflow_lsb};
      if (int_X_input_uflow_lsb) begin
        log2_datout_lsb <= 38'd0;
        exp_frac_lsb_q  <= 16'd0;
      end else if (X_exp) begin
        log2_datout_lsb <= {32'd0, lsb_hi_idx};
        exp_frac_lsb_q  <= (|dec_offset_lsb) ? lsb_norm_sh[52:37] : 16'd0;
      end else begin
        log2_datout_lsb <= dec_offset_lsb;
      end

      if (int_X_input_uflow_msb) begin
        log2_datout_msb <= 22'd0;
        exp_frac_msb_q  <= 16'd0;
      end else if (X_exp) begin
        log2_datout_msb <= {17'd0, msb_hi_idx};
        exp_frac_msb_q  <= (|dec_offset_msb) ? msb_norm_sh[36:21] : 16'd0;
      end else begin
        log2_datout_msb <= dec_offset_msb;
      end
    end
  end
end

// Stage 1 -> Stage 2: exponential index offset subtraction
wire [33:0] dat_info = {int_X_input_uflow_d, exp_frac_msb_q, exp_frac_lsb_q};
reg  [38:0] dec_Xindex_lsb;
reg  [22:0] dec_Xindex_msb;
reg         int_X_index_uflow_lsb, int_X_index_uflow_msb;
reg  [33:0] dat_info_d;

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_stage2_pvld       <= 1'b0;
    dec_Xindex_lsb        <= 39'd0;
    dec_Xindex_msb        <= 23'd0;
    int_X_index_uflow_lsb <= 1'b0;
    int_X_index_uflow_msb <= 1'b0;
    dat_info_d            <= 34'd0;
  end else begin
    if (int_stage1_pvld) int_stage2_pvld <= 1'b1;
    else if (int_stage2_prdy) int_stage2_pvld <= 1'b0;

    if (load_int_stage1) begin
      dat_info_d <= dat_info;
      if (dat_info[32]) begin
        dec_Xindex_lsb        <= 39'd0;
        int_X_index_uflow_lsb <= 1'b0;
      end else if (X_exp) begin
        if ((log2_datout_lsb < {31'd0, reg2dp_lut_le_index_offset[6:0]}) & (~reg2dp_lut_le_index_offset[7])) begin
          dec_Xindex_lsb        <= 39'd0;
          int_X_index_uflow_lsb <= 1'b1;
        end else begin
          dec_Xindex_lsb        <= $signed({1'b0, log2_datout_lsb}) - $signed({{31{reg2dp_lut_le_index_offset[7]}}, reg2dp_lut_le_index_offset});
          int_X_index_uflow_lsb <= 1'b0;
        end
      end else begin
        dec_Xindex_lsb        <= {1'b0, log2_datout_lsb};
        int_X_index_uflow_lsb <= 1'b0;
      end

      if (dat_info[33]) begin
        dec_Xindex_msb        <= 23'd0;
        int_X_index_uflow_msb <= 1'b0;
      end else if (X_exp) begin
        if ((log2_datout_msb < {15'd0, reg2dp_lut_le_index_offset[6:0]}) & (~reg2dp_lut_le_index_offset[7])) begin
          dec_Xindex_msb        <= 23'd0;
          int_X_index_uflow_msb <= 1'b1;
        end else begin
          dec_Xindex_msb        <= $signed({1'b0, log2_datout_msb}) - $signed({{15{reg2dp_lut_le_index_offset[7]}}, reg2dp_lut_le_index_offset});
          int_X_index_uflow_msb <= 1'b0;
        end
      end else begin
        dec_Xindex_msb        <= {1'b0, log2_datout_msb};
        int_X_index_uflow_msb <= 1'b0;
      end
    end
  end
end

// Stage 2 -> Stage 3: shared INT16/INT8_LSB linear index shifter + INT8_MSB shifter
wire [33:0] dat_info_index_sub = {dat_info_d[33:32] | {int_X_index_uflow_msb, int_X_index_uflow_lsb}, dat_info_d[31:0]};
wire  [7:0] shift_bits   = X_exp ? 8'd0 : reg2dp_lut_le_index_select;
wire        x_lsb_sh_neg = int16_en ? shift_bits[6] : shift_bits[5];
wire  [6:0] x_lsb_sh_abs = int16_en ? (shift_bits[6] ? ({1'b0, ~shift_bits[5:0]} + 7'd1) : {1'b0, shift_bits[5:0]})
                                    : (shift_bits[5] ? ({2'b00, ~shift_bits[4:0]} + 7'd1) : {2'b00, shift_bits[4:0]});
wire [38:0] x_lsb_val    = int16_en ? dec_Xindex_lsb : {16'd0, dec_Xindex_lsb[22:0]};
wire [54:0] x_lsb_rsh    = (x_lsb_sh_abs >= 7'd55) ? 55'd0 : ({x_lsb_val, 16'd0} >> x_lsb_sh_abs[5:0]);
wire [11:0] x_lsb_lsh    = {6'd0, x_lsb_val[5:0]} << x_lsb_sh_abs[2:0];
wire        x_lsb_l_ovf  = (x_lsb_sh_abs >= 7'd6) ? (|x_lsb_val) : ((|x_lsb_val[38:6]) | (x_lsb_lsh >= 12'd64));

wire        x_msb_sh_neg = shift_bits[5];
wire  [5:0] x_msb_sh_abs = shift_bits[5] ? ({1'b0, ~shift_bits[4:0]} + 6'd1) : {1'b0, shift_bits[4:0]};
wire [38:0] x_msb_rsh    = ({dec_Xindex_msb, 16'd0} >> x_msb_sh_abs[5:0]);
wire [11:0] x_msb_lsh    = {6'd0, dec_Xindex_msb[5:0]} << x_msb_sh_abs[2:0];
wire        x_msb_l_ovf  = (x_msb_sh_abs >= 6'd6) ? (|dec_Xindex_msb) : ((|dec_Xindex_msb[22:6]) | (x_msb_lsh >= 12'd64));

reg  [9:0] x_shift_lsb_q, x_shift_msb_q;
reg        x_oflow_lsb_q, x_oflow_msb_q;
reg [15:0] x_lfrac_lsb_q, x_lfrac_msb_q;
reg [33:0] dat_info_shift;

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_stage3_pvld <= 1'b0;
    x_shift_lsb_q   <= 10'd0;
    x_shift_msb_q   <= 10'd0;
    x_oflow_lsb_q   <= 1'b0;
    x_oflow_msb_q   <= 1'b0;
    x_lfrac_lsb_q   <= 16'd0;
    x_lfrac_msb_q   <= 16'd0;
    dat_info_shift  <= 34'd0;
  end else begin
    if (int_stage2_pvld) int_stage3_pvld <= 1'b1;
    else if (int_stage3_prdy) int_stage3_pvld <= 1'b0;

    if (load_int_stage2) begin
      dat_info_shift <= dat_info_index_sub;
      x_lfrac_lsb_q  <= x_lsb_sh_neg ? 16'd0 : x_lsb_rsh[15:0];
      x_lfrac_msb_q  <= x_msb_sh_neg ? 16'd0 : x_msb_rsh[15:0];

      if (dat_info_index_sub[32]) begin
        x_shift_lsb_q <= 10'd0;
        x_oflow_lsb_q <= 1'b0;
      end else if (x_lsb_sh_neg) begin
        x_shift_lsb_q <= x_lsb_l_ovf ? 10'd64 : x_lsb_lsh[9:0];
        x_oflow_lsb_q <= x_lsb_l_ovf;
      end else if (x_lsb_rsh[54:16] >= 39'd64) begin
        x_shift_lsb_q <= 10'd64;
        x_oflow_lsb_q <= 1'b1;
      end else begin
        x_shift_lsb_q <= x_lsb_rsh[25:16];
        x_oflow_lsb_q <= 1'b0;
      end

      if (dat_info_index_sub[33]) begin
        x_shift_msb_q <= 10'd0;
        x_oflow_msb_q <= 1'b0;
      end else if (x_msb_sh_neg) begin
        x_shift_msb_q <= x_msb_l_ovf ? 10'd64 : x_msb_lsh[9:0];
        x_oflow_msb_q <= x_msb_l_ovf;
      end else if (x_msb_rsh[38:16] >= 23'd64) begin
        x_shift_msb_q <= 10'd64;
        x_oflow_msb_q <= 1'b1;
      end else begin
        x_shift_msb_q <= x_msb_rsh[25:16];
        x_oflow_msb_q <= 1'b0;
      end
    end
  end
end

wire        int_act        = int16_en | int8_en;
wire  [9:0] X_index_lsb    = int_act ? x_shift_lsb_q : 10'd0;
wire  [9:0] X_index_msb    = x_shift_msb_q;
wire        X_oflow_lsb    = int_act ? x_oflow_lsb_q : 1'b0;
wire [15:0] X_lin_frac_lsb = int_act ? x_lfrac_lsb_q : 16'd0;
wire [15:0] X_frac_lsb     = X_exp ? dat_info_shift[15:0]  : X_lin_frac_lsb;
wire [15:0] X_frac_msb     = X_exp ? dat_info_shift[31:16] : x_lfrac_msb_q;
wire [35:0] X_dat_info     = {x_oflow_msb_q, X_oflow_lsb, dat_info_shift[33:32], X_frac_msb, X_frac_lsb};

// INT Y linear LUT index pipeline (4 stages aligned with INT X)
wire y_le_lsb = ($signed(dec_offset_datin_lsb) <= $signed(reg2dp_Y_offset));
wire y_le_msb = ($signed(dec_offset_datin_msb) <= $signed(reg2dp_Y_offset[21:0]));

reg        int_Y_s0_vld, int_Y_s1_vld, int_Y_s2_vld, int_Y_s3_vld;
wire       Y_int_stage3_prdy;
wire       int_Y_s2_rdy = ~int_Y_s3_vld | Y_int_stage3_prdy;
wire       int_Y_s1_rdy = ~int_Y_s2_vld | int_Y_s2_rdy;
wire       int_Y_s0_rdy = ~int_Y_s1_vld | int_Y_s1_rdy;
assign     int_Y_datin_prdy = ~int_Y_s0_vld | int_Y_s0_rdy;

reg [37:0] Y_dec_offset_lsb;
reg [21:0] Y_dec_offset_msb;
reg        int_Y_uflow_lsb, int_Y_uflow_msb;

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_Y_s0_vld     <= 1'b0;
    Y_dec_offset_lsb <= 38'd0;
    Y_dec_offset_msb <= 22'd0;
    int_Y_uflow_lsb  <= 1'b0;
    int_Y_uflow_msb  <= 1'b0;
  end else begin
    if (int_Y_proc_in_vld) int_Y_s0_vld <= 1'b1;
    else if (int_Y_s0_rdy) int_Y_s0_vld <= 1'b0;

    if (int_Y_proc_in_vld & int_Y_datin_prdy) begin
      Y_dec_offset_lsb <= y_le_lsb ? 38'd0 : (dec_offset_datin_lsb - reg2dp_Y_offset);
      int_Y_uflow_lsb  <= y_le_lsb;
      Y_dec_offset_msb <= y_le_msb ? 22'd0 : (dec_offset_datin_msb - reg2dp_Y_offset[21:0]);
      int_Y_uflow_msb  <= y_le_msb;
    end
  end
end

wire        y_lsb_sh_neg = int16_en ? Y_shift_bits[6] : Y_shift_bits[5];
wire  [6:0] y_lsb_sh_abs = int16_en ? (Y_shift_bits[6] ? ({1'b0, ~Y_shift_bits[5:0]} + 7'd1) : {1'b0, Y_shift_bits[5:0]})
                                    : (Y_shift_bits[5] ? ({2'b00, ~Y_shift_bits[4:0]} + 7'd1) : {2'b00, Y_shift_bits[4:0]});
wire [37:0] y_lsb_val    = int16_en ? Y_dec_offset_lsb : {16'd0, Y_dec_offset_lsb[21:0]};
wire [53:0] y_lsb_rsh    = (y_lsb_sh_abs >= 7'd54) ? 54'd0 : ({y_lsb_val, 16'd0} >> y_lsb_sh_abs[5:0]);
wire [15:0] y_lsb_lsh    = {8'd0, y_lsb_val[7:0]} << y_lsb_sh_abs[2:0];
wire        y_lsb_l_ovf  = (y_lsb_sh_abs >= 7'd8) ? (|y_lsb_val) : ((|y_lsb_val[37:8]) | (y_lsb_lsh >= 16'd256));

wire        y_msb_sh_neg = Y_shift_bits[5];
wire  [5:0] y_msb_sh_abs = Y_shift_bits[5] ? ({1'b0, ~Y_shift_bits[4:0]} + 6'd1) : {1'b0, Y_shift_bits[4:0]};
wire [37:0] y_msb_rsh    = ({Y_dec_offset_msb, 16'd0} >> y_msb_sh_abs[5:0]);
wire [15:0] y_msb_lsh    = {8'd0, Y_dec_offset_msb[7:0]} << y_msb_sh_abs[2:0];
wire        y_msb_l_ovf  = (y_msb_sh_abs >= 6'd8) ? (|Y_dec_offset_msb) : ((|Y_dec_offset_msb[21:8]) | (y_msb_lsh >= 16'd256));

reg  [9:0] y_shift_lsb_q, y_shift_msb_q;
reg        y_oflow_lsb_q, y_oflow_msb_q;
reg [15:0] y_lfrac_lsb_q, y_lfrac_msb_q;
reg  [1:0] Y_dat_info_shift;
reg [55:0] int_Y_s2_pd, int_Y_s3_pd;

wire [55:0] Y_s1_pd = {
  y_oflow_msb_q, int_act ? y_oflow_lsb_q : 1'b0,
  Y_dat_info_shift,
  y_lfrac_msb_q, int_act ? y_lfrac_lsb_q : 16'd0,
  y_shift_msb_q, int_act ? y_shift_lsb_q : 10'd0
};

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_Y_s1_vld     <= 1'b0;
    int_Y_s2_vld     <= 1'b0;
    int_Y_s3_vld     <= 1'b0;
    y_shift_lsb_q    <= 10'd0;
    y_shift_msb_q    <= 10'd0;
    y_oflow_lsb_q    <= 1'b0;
    y_oflow_msb_q    <= 1'b0;
    y_lfrac_lsb_q    <= 16'd0;
    y_lfrac_msb_q    <= 16'd0;
    Y_dat_info_shift <= 2'd0;
    int_Y_s2_pd      <= 56'd0;
    int_Y_s3_pd      <= 56'd0;
  end else begin
    if (int_Y_s0_vld) int_Y_s1_vld <= 1'b1;
    else if (int_Y_s1_rdy) int_Y_s1_vld <= 1'b0;

    if (int_Y_s0_vld & int_Y_s0_rdy) begin
      Y_dat_info_shift <= {int_Y_uflow_msb, int_Y_uflow_lsb};
      y_lfrac_lsb_q    <= y_lsb_sh_neg ? 16'd0 : y_lsb_rsh[15:0];
      y_lfrac_msb_q    <= y_msb_sh_neg ? 16'd0 : y_msb_rsh[15:0];

      if (int_Y_uflow_lsb) begin
        y_shift_lsb_q <= 10'd0;
        y_oflow_lsb_q <= 1'b0;
      end else if (y_lsb_sh_neg) begin
        y_shift_lsb_q <= y_lsb_l_ovf ? 10'd256 : y_lsb_lsh[9:0];
        y_oflow_lsb_q <= y_lsb_l_ovf;
      end else if (y_lsb_rsh[53:16] >= 38'd256) begin
        y_shift_lsb_q <= 10'd256;
        y_oflow_lsb_q <= 1'b1;
      end else begin
        y_shift_lsb_q <= y_lsb_rsh[25:16];
        y_oflow_lsb_q <= 1'b0;
      end

      if (int_Y_uflow_msb) begin
        y_shift_msb_q <= 10'd0;
        y_oflow_msb_q <= 1'b0;
      end else if (y_msb_sh_neg) begin
        y_shift_msb_q <= y_msb_l_ovf ? 10'd256 : y_msb_lsh[9:0];
        y_oflow_msb_q <= y_msb_l_ovf;
      end else if (y_msb_rsh[37:16] >= 22'd256) begin
        y_shift_msb_q <= 10'd256;
        y_oflow_msb_q <= 1'b1;
      end else begin
        y_shift_msb_q <= y_msb_rsh[25:16];
        y_oflow_msb_q <= 1'b0;
      end
    end

    if (int_Y_s1_vld) int_Y_s2_vld <= 1'b1;
    else if (int_Y_s2_rdy) int_Y_s2_vld <= 1'b0;
    if (int_Y_s1_vld & int_Y_s1_rdy) int_Y_s2_pd <= Y_s1_pd;

    if (int_Y_s2_vld) int_Y_s3_vld <= 1'b1;
    else if (Y_int_stage3_prdy) int_Y_s3_vld <= 1'b0;
    if (int_Y_s2_vld & int_Y_s2_rdy) int_Y_s3_pd <= int_Y_s2_pd;
  end
end

wire  [9:0] Y_index_lsb = int_Y_s3_pd[9:0];
wire  [9:0] Y_index_msb = int_Y_s3_pd[19:10];
wire [35:0] Y_dat_info  = int_Y_s3_pd[55:20];
wire        int_out_rdy;
assign int_stage3_prdy   = int_out_rdy & int_Y_s3_vld;
assign Y_int_stage3_prdy = int_out_rdy & int_stage3_pvld;
wire   int_out_vld       = int_stage3_pvld & int_Y_s3_vld;

// =========================================================================
// FP16 / FP32 X and Y LUT index pipelines (with IEEE-754 +Inf overflow fix)
// =========================================================================
wire [31:0] datin_fp16 = {32{fp16_en}} & sum2itp_pd[31:0];
wire        fp16_X_datin_prdy, fp16_Y_datin_prdy;
wire        fp_X_proc_in_vld = fp_en_vld & fp16_Y_datin_prdy;
wire        fp_Y_proc_in_vld = fp_en_vld & fp16_X_datin_prdy;
assign      fp_en_rdy        = fp16_X_datin_prdy & fp16_Y_datin_prdy;

wire        datin_fp16_rdy, offset_rdy, fp_stage0_pvld;
wire [31:0] fp_dec_offset;
assign fp16_X_datin_prdy = datin_fp16_rdy & offset_rdy;

wire fp_X_stage0_rdy;
HLS_fp32_sub u_CDP_DP_LUTCTRL_XOFFSET (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (datin_fp16)
  ,.chn_a_rsc_vz   (fp_X_proc_in_vld & offset_rdy)
  ,.chn_a_rsc_lz   (datin_fp16_rdy)
  ,.chn_b_rsc_z    (reg2dp_X_offset[31:0])
  ,.chn_b_rsc_vz   (fp_X_proc_in_vld & datin_fp16_rdy)
  ,.chn_b_rsc_lz   (offset_rdy)
  ,.chn_o_rsc_z    (fp_dec_offset)
  ,.chn_o_rsc_vz   (fp_X_stage0_rdy)
  ,.chn_o_rsc_lz   (fp_stage0_pvld)
  );

wire Xinput_is_NaN = (&fp_dec_offset[30:23]) & (|fp_dec_offset[22:0]);
wire fp_X_pos_inf  = (~fp_dec_offset[31]) & (&fp_dec_offset[30:23]) & (~(|fp_dec_offset[22:0]));
wire fp_X_uflow    = Xinput_is_NaN | (~(|fp_dec_offset)) | fp_dec_offset[31];

wire [31:0] fp_log2_datin   = fp_X_uflow ? 32'd0 : fp_dec_offset;
wire signed [8:0] fp_X_exp_unb = $signed({1'b0, fp_log2_datin[30:23]}) - 9'sd127;
wire signed [8:0] fp_X_idx_off = $signed({reg2dp_lut_le_index_offset[7], reg2dp_lut_le_index_offset});
wire signed [9:0] fp_X_exp_sub = $signed({fp_X_exp_unb[8], fp_X_exp_unb}) - $signed({fp_X_idx_off[8], fp_X_idx_off});

reg        fp_X_stage1_vld, fp_X_stage2_vld;
wire       fp_X_stage2_rdy;
wire       fp_X_stage1_rdy = ~fp_X_stage2_vld | fp_X_stage2_rdy;
assign     fp_X_stage0_rdy = ~fp_X_stage1_vld | fp_X_stage1_rdy;
wire       fp_X_stage0_load = fp_stage0_pvld & fp_X_stage0_rdy;
wire       fp_X_stage1_load = fp_X_stage1_vld & fp_X_stage1_rdy;

reg  [8:0] fp_Xindex;
reg        fp_X_index_uflow;
reg        fp_X_pos_inf_d;
reg [31:0] fp_X_lin_dat_d;
reg [16:0] fp_X_info_d;

always @(posedge nvdla_op_gated_clk_fp16 or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    fp_X_stage1_vld  <= 1'b0;
    fp_Xindex        <= 9'd0;
    fp_X_index_uflow <= 1'b0;
    fp_X_pos_inf_d   <= 1'b0;
    fp_X_lin_dat_d   <= 32'd0;
    fp_X_info_d      <= 17'd0;
  end else begin
    if (fp_stage0_pvld) fp_X_stage1_vld <= 1'b1;
    else if (fp_X_stage1_rdy) fp_X_stage1_vld <= 1'b0;

    if (fp_X_stage0_load) begin
      fp_X_pos_inf_d <= fp_X_pos_inf;
      fp_X_lin_dat_d <= fp_log2_datin;
      fp_X_info_d    <= {fp_X_uflow, (fp_X_uflow | (~X_exp) | fp_X_pos_inf) ? 16'd0 : fp_log2_datin[22:7]};
      if (fp_X_uflow) begin
        fp_Xindex        <= 9'd0;
        fp_X_index_uflow <= 1'b0;
      end else if (X_exp) begin
        if (fp_X_pos_inf) begin
          fp_Xindex        <= 9'd64;
          fp_X_index_uflow <= 1'b0;
        end else if (fp_X_exp_sub[9]) begin
          fp_Xindex        <= 9'd0;
          fp_X_index_uflow <= 1'b1;
        end else begin
          fp_Xindex        <= (fp_X_exp_sub >= 10'sd64) ? 9'd64 : fp_X_exp_sub[8:0];
          fp_X_index_uflow <= 1'b0;
        end
      end
    end
  end
end

// Stage 1 -> Stage 2 for FP16 X: compact 64-bit window shift (p = E - 110 - S)
wire [16:0] fp_Xindex_info = X_exp ? {(fp_X_info_d[16] | fp_X_index_uflow), fp_X_info_d[15:0]} : fp_X_info_d;
wire signed [9:0] fp_X_p   = $signed({2'b00, fp_X_lin_dat_d[30:23]}) - 10'sd110 - $signed({{2{shift_bits[7]}}, shift_bits});
wire [63:0] fp_X_win       = (fp_X_p < 10'sd0 || fp_X_p > 10'sd40) ? 64'd0
                           : ({40'd0, 1'b1, fp_X_lin_dat_d[22:0]} << fp_X_p[5:0]);

reg  [9:0] fp_Xshift;
reg        fp_Xshift_oflow;
reg [15:0] fp_Xshift_frac;
reg [16:0] fp_Xindex_info_d;

always @(posedge nvdla_op_gated_clk_fp16 or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    fp_X_stage2_vld  <= 1'b0;
    fp_Xshift        <= 10'd0;
    fp_Xshift_oflow  <= 1'b0;
    fp_Xshift_frac   <= 16'd0;
    fp_Xindex_info_d <= 17'd0;
  end else begin
    if (fp_X_stage1_vld) fp_X_stage2_vld <= 1'b1;
    else if (fp_X_stage2_rdy) fp_X_stage2_vld <= 1'b0;

    if (fp_X_stage1_load) begin
      fp_Xindex_info_d <= fp_Xindex_info;
      if (fp_Xindex_info[16]) begin
        fp_Xshift       <= 10'd0;
        fp_Xshift_oflow <= 1'b0;
        fp_Xshift_frac  <= 16'd0;
      end else if (X_exp_s) begin
        if (fp_X_pos_inf_d || (fp_Xindex >= 9'd64)) begin
          fp_Xshift       <= 10'd64;
          fp_Xshift_oflow <= 1'b1;
        end else begin
          fp_Xshift       <= {1'b0, fp_Xindex};
          fp_Xshift_oflow <= 1'b0;
        end
      end else if (fp_X_pos_inf_d) begin
        fp_Xshift       <= 10'd64;
        fp_Xshift_oflow <= 1'b1;
        fp_Xshift_frac  <= 16'd0;
      end else if (~(|fp_X_lin_dat_d)) begin
        fp_Xshift       <= 10'd0;
        fp_Xshift_oflow <= 1'b0;
        fp_Xshift_frac  <= 16'd0;
      end else if (fp_X_p < 10'sd0) begin
        fp_Xshift       <= 10'd0;
        fp_Xshift_oflow <= 1'b0;
        fp_Xshift_frac  <= 16'd0;
      end else if (fp_X_p > 10'sd40) begin
        fp_Xshift       <= 10'd64;
        fp_Xshift_oflow <= 1'b1;
        fp_Xshift_frac  <= 16'd0;
      end else begin
        fp_Xshift_frac  <= fp_X_win[39:24];
        if (fp_X_win[63:40] >= 24'd64) begin
          fp_Xshift       <= 10'd64;
          fp_Xshift_oflow <= 1'b1;
        end else begin
          fp_Xshift       <= fp_X_win[49:40];
          fp_Xshift_oflow <= 1'b0;
        end
      end
    end
  end
end

wire [15:0] fp_X_frac      = X_exp_s ? fp_Xindex_info_d[15:0] : fp_Xshift_frac;
wire [17:0] fp_Xshift_info = {fp_Xshift_oflow, fp_Xindex_info_d[16], fp_X_frac};

// FP16 Y linear LUT pipeline: register HLS_fp32_sub output in Stage 1, window-shift in Stage 2
wire        Y_datin_fp16_rdy, Y_offset_rdy, Y_fp_stage0_pvld;
wire [31:0] Y_fp_dec_offset;
assign fp16_Y_datin_prdy = Y_datin_fp16_rdy & Y_offset_rdy;

reg        fp_Y_stage1_vld, fp_Y_stage2_vld;
wire       fp_Y_stage2_rdy;
wire       fp_Y_stage1_rdy = ~fp_Y_stage2_vld | fp_Y_stage2_rdy;
wire       fp_Y_stage0_rdy = ~fp_Y_stage1_vld | fp_Y_stage1_rdy;

HLS_fp32_sub u_CDP_DP_LUTCTRL_YOFFSET (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (datin_fp16)
  ,.chn_a_rsc_vz   (fp_Y_proc_in_vld & Y_offset_rdy)
  ,.chn_a_rsc_lz   (Y_datin_fp16_rdy)
  ,.chn_b_rsc_z    (reg2dp_Y_offset[31:0])
  ,.chn_b_rsc_vz   (fp_Y_proc_in_vld & Y_datin_fp16_rdy)
  ,.chn_b_rsc_lz   (Y_offset_rdy)
  ,.chn_o_rsc_z    (Y_fp_dec_offset)
  ,.chn_o_rsc_vz   (fp_Y_stage0_rdy)
  ,.chn_o_rsc_lz   (Y_fp_stage0_pvld)
  );

wire Yinput_is_NaN = (&Y_fp_dec_offset[30:23]) & (|Y_fp_dec_offset[22:0]);
wire fp_Y_pos_inf  = (~Y_fp_dec_offset[31]) & (&Y_fp_dec_offset[30:23]) & (~(|Y_fp_dec_offset[22:0]));
wire fp_Y_uflow    = Yinput_is_NaN | (~(|Y_fp_dec_offset)) | Y_fp_dec_offset[31];

reg [31:0] fp_Y_dat_d;
reg        fp_Y_uflow_d;
reg        fp_Y_pos_inf_d;

always @(posedge nvdla_op_gated_clk_fp16 or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    fp_Y_stage1_vld <= 1'b0;
    fp_Y_dat_d      <= 32'd0;
    fp_Y_uflow_d    <= 1'b0;
    fp_Y_pos_inf_d  <= 1'b0;
  end else begin
    if (Y_fp_stage0_pvld) fp_Y_stage1_vld <= 1'b1;
    else if (fp_Y_stage1_rdy) fp_Y_stage1_vld <= 1'b0;

    if (Y_fp_stage0_pvld & fp_Y_stage0_rdy) begin
      fp_Y_dat_d     <= fp_Y_uflow ? 32'd0 : Y_fp_dec_offset;
      fp_Y_uflow_d   <= fp_Y_uflow;
      fp_Y_pos_inf_d <= fp_Y_pos_inf;
    end
  end
end

wire signed [9:0] fp_Y_p = $signed({2'b00, fp_Y_dat_d[30:23]}) - 10'sd110 - $signed({{2{Y_shift_bits[7]}}, Y_shift_bits});
wire [63:0] fp_Y_win     = (fp_Y_p < 10'sd0 || fp_Y_p > 10'sd40) ? 64'd0
                         : ({40'd0, 1'b1, fp_Y_dat_d[22:0]} << fp_Y_p[5:0]);

reg  [9:0] fp_Y_index;
reg        fp_Yshift_oflow_q;
reg        fp_Y_uflow_q2;
reg [15:0] fp_Yshift_frac_q;

always @(posedge nvdla_op_gated_clk_fp16 or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    fp_Y_stage2_vld   <= 1'b0;
    fp_Y_index        <= 10'd0;
    fp_Yshift_oflow_q <= 1'b0;
    fp_Y_uflow_q2     <= 1'b0;
    fp_Yshift_frac_q  <= 16'd0;
  end else begin
    if (fp_Y_stage1_vld) fp_Y_stage2_vld <= 1'b1;
    else if (fp_Y_stage2_rdy) fp_Y_stage2_vld <= 1'b0;

    if (fp_Y_stage1_vld & fp_Y_stage1_rdy) begin
      fp_Y_uflow_q2 <= fp_Y_uflow_d;
      if (fp_Y_uflow_d) begin
        fp_Y_index        <= 10'd0;
        fp_Yshift_oflow_q <= 1'b0;
        fp_Yshift_frac_q  <= 16'd0;
      end else if (fp_Y_pos_inf_d) begin
        fp_Y_index        <= 10'd256;
        fp_Yshift_oflow_q <= 1'b1;
        fp_Yshift_frac_q  <= 16'd0;
      end else if (~(|fp_Y_dat_d)) begin
        fp_Y_index        <= 10'd0;
        fp_Yshift_oflow_q <= 1'b0;
        fp_Yshift_frac_q  <= 16'd0;
      end else if (fp_Y_p < 10'sd0) begin
        fp_Y_index        <= 10'd0;
        fp_Yshift_oflow_q <= 1'b0;
        fp_Yshift_frac_q  <= 16'd0;
      end else if (fp_Y_p > 10'sd40) begin
        fp_Y_index        <= 10'd256;
        fp_Yshift_oflow_q <= 1'b1;
        fp_Yshift_frac_q  <= 16'd0;
      end else begin
        fp_Yshift_frac_q <= fp_Y_win[39:24];
        if (fp_Y_win[63:40] >= 24'd256) begin
          fp_Y_index        <= 10'd256;
          fp_Yshift_oflow_q <= 1'b1;
        end else begin
          fp_Y_index        <= fp_Y_win[49:40];
          fp_Yshift_oflow_q <= 1'b0;
        end
      end
    end
  end
end

wire [17:0] fp_Y_index_info = {fp_Yshift_oflow_q, fp_Y_uflow_q2, fp_Yshift_frac_q};
wire        fp_out_rdy      = fp16_en ? dp2lut_prdy : 1'b1;
assign      int_out_rdy     = fp16_en ? 1'b1        : dp2lut_prdy;
assign      fp_X_stage2_rdy = fp_out_rdy & fp_Y_stage2_vld;
assign      fp_Y_stage2_rdy = fp_out_rdy & fp_X_stage2_vld;
wire        fp_out_vld      = fp_X_stage2_vld & fp_Y_stage2_vld;

assign dp2lut_pvld   = fp16_en ? fp_out_vld : int_out_vld;
assign dp2lut_X_pd   = fp16_en ? {10'd0, fp_Xshift} : {X_index_msb, X_index_lsb};
assign dp2lut_X_info = fp16_en ? {1'b0, fp_Xshift_info[17], 1'b0, fp_Xshift_info[16], 16'd0, fp_Xshift_info[15:0]} : X_dat_info;
assign dp2lut_Y_pd   = fp16_en ? {10'd0, fp_Y_index} : {Y_index_msb, Y_index_lsb};
assign dp2lut_Y_info = fp16_en ? {1'b0, fp_Y_index_info[17], 1'b0, fp_Y_index_info[16], 16'd0, fp_Y_index_info[15:0]} : Y_dat_info;

endmodule // NV_NVDLA_CDP_DP_LUT_CTRL_unit
