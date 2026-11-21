// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================

// File Name: int_sum_block.v

module int_sum_block (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,int8_en
  ,len5
  ,len7
  ,len9
  ,load_din_2d
  ,load_din_d
  ,reg2dp_normalz_len
  ,sq_pd_int16_0
  ,sq_pd_int16_1
  ,sq_pd_int16_2
  ,sq_pd_int16_3
  ,sq_pd_int16_4
  ,sq_pd_int16_5
  ,sq_pd_int16_6
  ,sq_pd_int16_7
  ,sq_pd_int16_8
  ,sq_pd_int8_lsb_0
  ,sq_pd_int8_lsb_1
  ,sq_pd_int8_lsb_2
  ,sq_pd_int8_lsb_3
  ,sq_pd_int8_lsb_4
  ,sq_pd_int8_lsb_5
  ,sq_pd_int8_lsb_6
  ,sq_pd_int8_lsb_7
  ,sq_pd_int8_lsb_8
  ,sq_pd_int8_msb_0
  ,sq_pd_int8_msb_1
  ,sq_pd_int8_msb_2
  ,sq_pd_int8_msb_3
  ,sq_pd_int8_msb_4
  ,sq_pd_int8_msb_5
  ,sq_pd_int8_msb_6
  ,sq_pd_int8_msb_7
  ,sq_pd_int8_msb_8
  ,int16_sum
  ,int8_sum
  );
input         nvdla_core_clk;
input         nvdla_core_rstn;
input         int8_en;
input         len5;
input         len7;
input         len9;
input         load_din_2d;
input         load_din_d;
input   [1:0] reg2dp_normalz_len;
input  [32:0] sq_pd_int16_0;
input  [32:0] sq_pd_int16_1;
input  [32:0] sq_pd_int16_2;
input  [32:0] sq_pd_int16_3;
input  [32:0] sq_pd_int16_4;
input  [32:0] sq_pd_int16_5;
input  [32:0] sq_pd_int16_6;
input  [32:0] sq_pd_int16_7;
input  [32:0] sq_pd_int16_8;
input  [16:0] sq_pd_int8_lsb_0;
input  [16:0] sq_pd_int8_lsb_1;
input  [16:0] sq_pd_int8_lsb_2;
input  [16:0] sq_pd_int8_lsb_3;
input  [16:0] sq_pd_int8_lsb_4;
input  [16:0] sq_pd_int8_lsb_5;
input  [16:0] sq_pd_int8_lsb_6;
input  [16:0] sq_pd_int8_lsb_7;
input  [16:0] sq_pd_int8_lsb_8;
input  [16:0] sq_pd_int8_msb_0;
input  [16:0] sq_pd_int8_msb_1;
input  [16:0] sq_pd_int8_msb_2;
input  [16:0] sq_pd_int8_msb_3;
input  [16:0] sq_pd_int8_msb_4;
input  [16:0] sq_pd_int8_msb_5;
input  [16:0] sq_pd_int8_msb_6;
input  [16:0] sq_pd_int8_msb_7;
input  [16:0] sq_pd_int8_msb_8;
output [36:0] int16_sum;
output [41:0] int8_sum;

wire [32:0] sq0 = int8_en ? {16'd0, sq_pd_int8_lsb_0} : sq_pd_int16_0;
wire [32:0] sq1 = int8_en ? {16'd0, sq_pd_int8_lsb_1} : sq_pd_int16_1;
wire [32:0] sq2 = int8_en ? {16'd0, sq_pd_int8_lsb_2} : sq_pd_int16_2;
wire [32:0] sq3 = int8_en ? {16'd0, sq_pd_int8_lsb_3} : sq_pd_int16_3;
wire [32:0] sq4 = int8_en ? {16'd0, sq_pd_int8_lsb_4} : sq_pd_int16_4;
wire [32:0] sq5 = int8_en ? {16'd0, sq_pd_int8_lsb_5} : sq_pd_int16_5;
wire [32:0] sq6 = int8_en ? {16'd0, sq_pd_int8_lsb_6} : sq_pd_int16_6;
wire [32:0] sq7 = int8_en ? {16'd0, sq_pd_int8_lsb_7} : sq_pd_int16_7;
wire [32:0] sq8 = int8_en ? {16'd0, sq_pd_int8_lsb_8} : sq_pd_int16_8;

wire en_ge5 = len5 | len7 | len9;
wire en_ge7 = len7 | len9;

reg [32:0] sq4_d;
reg [33:0] p35_16, p26_16, p17_16, p08_16;
reg [16:0] msb4_d;
reg [17:0] p35_m8, p26_m8, p17_m8, p08_m8;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    sq4_d  <= 33'd0;
    p35_16 <= 34'd0;
    p26_16 <= 34'd0;
    p17_16 <= 34'd0;
    p08_16 <= 34'd0;
    msb4_d <= 17'd0;
    p35_m8 <= 18'd0;
    p26_m8 <= 18'd0;
    p17_m8 <= 18'd0;
    p08_m8 <= 18'd0;
  end else begin
    if (load_din_d) begin
      sq4_d  <= sq4;
      p35_16 <= sq3 + sq5;
      msb4_d <= sq_pd_int8_msb_4;
      p35_m8 <= sq_pd_int8_msb_3 + sq_pd_int8_msb_5;
    end
    if (load_din_d & en_ge5) begin
      p26_16 <= sq2 + sq6;
      p26_m8 <= sq_pd_int8_msb_2 + sq_pd_int8_msb_6;
    end
    if (load_din_d & en_ge7) begin
      p17_16 <= sq1 + sq7;
      p17_m8 <= sq_pd_int8_msb_1 + sq_pd_int8_msb_7;
    end
    if (load_din_d & len9) begin
      p08_16 <= sq0 + sq8;
      p08_m8 <= sq_pd_int8_msb_0 + sq_pd_int8_msb_8;
    end
  end
end

// Length-masked 5-input 3:2 carry-save compression into a single accumulator flop
wire use_26 = (reg2dp_normalz_len != 2'h0);
wire use_17 = reg2dp_normalz_len[1];
wire use_08 = (reg2dp_normalz_len == 2'h3);

wire [36:0] t0_16 = {4'd0, sq4_d};
wire [36:0] t1_16 = {3'd0, p35_16};
wire [36:0] t2_16 = use_26 ? {3'd0, p26_16} : 37'd0;
wire [36:0] t3_16 = use_17 ? {3'd0, p17_16} : 37'd0;
wire [36:0] t4_16 = use_08 ? {3'd0, p08_16} : 37'd0;

wire [36:0] csa1_s_16 = t0_16 ^ t1_16 ^ t2_16;
wire [36:0] csa1_c_16 = ((t0_16 & t1_16) | (t0_16 & t2_16) | (t1_16 & t2_16)) << 1;
wire [36:0] csa2_s_16 = csa1_s_16 ^ csa1_c_16 ^ t3_16;
wire [36:0] csa2_c_16 = ((csa1_s_16 & csa1_c_16) | (csa1_s_16 & t3_16) | (csa1_c_16 & t3_16)) << 1;
wire [36:0] csa3_s_16 = csa2_s_16 ^ csa2_c_16 ^ t4_16;
wire [36:0] csa3_c_16 = ((csa2_s_16 & csa2_c_16) | (csa2_s_16 & t4_16) | (csa2_c_16 & t4_16)) << 1;

wire [20:0] t0_m8 = {4'd0, msb4_d};
wire [20:0] t1_m8 = {3'd0, p35_m8};
wire [20:0] t2_m8 = use_26 ? {3'd0, p26_m8} : 21'd0;
wire [20:0] t3_m8 = use_17 ? {3'd0, p17_m8} : 21'd0;
wire [20:0] t4_m8 = use_08 ? {3'd0, p08_m8} : 21'd0;

wire [20:0] csa1_s_m8 = t0_m8 ^ t1_m8 ^ t2_m8;
wire [20:0] csa1_c_m8 = ((t0_m8 & t1_m8) | (t0_m8 & t2_m8) | (t1_m8 & t2_m8)) << 1;
wire [20:0] csa2_s_m8 = csa1_s_m8 ^ csa1_c_m8 ^ t3_m8;
wire [20:0] csa2_c_m8 = ((csa1_s_m8 & csa1_c_m8) | (csa1_s_m8 & t3_m8) | (csa1_c_m8 & t3_m8)) << 1;
wire [20:0] csa3_s_m8 = csa2_s_m8 ^ csa2_c_m8 ^ t4_m8;
wire [20:0] csa3_c_m8 = ((csa2_s_m8 & csa2_c_m8) | (csa2_s_m8 & t4_m8) | (csa2_c_m8 & t4_m8)) << 1;

reg [36:0] int16_sum_r;
reg [20:0] int8_msb_sum_r;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int16_sum_r    <= 37'd0;
    int8_msb_sum_r <= 21'd0;
  end else if (load_din_2d) begin
    int16_sum_r    <= csa3_s_16 + csa3_c_16;
    int8_msb_sum_r <= csa3_s_m8 + csa3_c_m8;
  end
end

assign int16_sum = int16_sum_r;
assign int8_sum  = {int8_msb_sum_r, int8_en ? int16_sum_r[20:0] : 21'd0};

endmodule // int_sum_block
