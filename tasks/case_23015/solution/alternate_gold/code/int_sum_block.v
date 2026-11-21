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

reg [32:0] center_lo_q;
reg [33:0] ring1_lo_q, ring2_lo_q, ring3_lo_q, ring4_lo_q;
reg [16:0] center_hi_q;
reg [17:0] ring1_hi_q, ring2_hi_q, ring3_hi_q, ring4_hi_q;

wire [32:0] in_lo_0 = int8_en ? {16'd0, sq_pd_int8_lsb_0} : sq_pd_int16_0;
wire [32:0] in_lo_1 = int8_en ? {16'd0, sq_pd_int8_lsb_1} : sq_pd_int16_1;
wire [32:0] in_lo_2 = int8_en ? {16'd0, sq_pd_int8_lsb_2} : sq_pd_int16_2;
wire [32:0] in_lo_3 = int8_en ? {16'd0, sq_pd_int8_lsb_3} : sq_pd_int16_3;
wire [32:0] in_lo_4 = int8_en ? {16'd0, sq_pd_int8_lsb_4} : sq_pd_int16_4;
wire [32:0] in_lo_5 = int8_en ? {16'd0, sq_pd_int8_lsb_5} : sq_pd_int16_5;
wire [32:0] in_lo_6 = int8_en ? {16'd0, sq_pd_int8_lsb_6} : sq_pd_int16_6;
wire [32:0] in_lo_7 = int8_en ? {16'd0, sq_pd_int8_lsb_7} : sq_pd_int16_7;
wire [32:0] in_lo_8 = int8_en ? {16'd0, sq_pd_int8_lsb_8} : sq_pd_int16_8;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    center_lo_q <= 33'd0;
    ring1_lo_q  <= 34'd0;
    ring2_lo_q  <= 34'd0;
    ring3_lo_q  <= 34'd0;
    ring4_lo_q  <= 34'd0;
    center_hi_q <= 17'd0;
    ring1_hi_q  <= 18'd0;
    ring2_hi_q  <= 18'd0;
    ring3_hi_q  <= 18'd0;
    ring4_hi_q  <= 18'd0;
  end else if (load_din_d) begin
    center_lo_q <= in_lo_4;
    ring1_lo_q  <= in_lo_3 + in_lo_5;
    center_hi_q <= sq_pd_int8_msb_4;
    ring1_hi_q  <= sq_pd_int8_msb_3 + sq_pd_int8_msb_5;
    if (len5 | len7 | len9) begin
      ring2_lo_q <= in_lo_2 + in_lo_6;
      ring2_hi_q <= sq_pd_int8_msb_2 + sq_pd_int8_msb_6;
    end
    if (len7 | len9) begin
      ring3_lo_q <= in_lo_1 + in_lo_7;
      ring3_hi_q <= sq_pd_int8_msb_1 + sq_pd_int8_msb_7;
    end
    if (len9) begin
      ring4_lo_q <= in_lo_0 + in_lo_8;
      ring4_hi_q <= sq_pd_int8_msb_0 + sq_pd_int8_msb_8;
    end
  end
end

// Incremental concentric-ring prefix adder cascade selected prior to single output stage
wire [34:0] pref3_lo = ring1_lo_q + {1'b0, center_lo_q};
wire [35:0] pref5_lo = {1'b0, pref3_lo} + {2'd0, ring2_lo_q};
wire [34:0] outer23_lo = ring2_lo_q + ring3_lo_q;
wire [35:0] pref7_lo = {1'b0, pref3_lo} + {1'b0, outer23_lo};
wire [36:0] pref9_lo = {1'b0, pref7_lo} + {3'd0, ring4_lo_q};

wire [18:0] pref3_hi = ring1_hi_q + {1'b0, center_hi_q};
wire [19:0] pref5_hi = {1'b0, pref3_hi} + {2'd0, ring2_hi_q};
wire [18:0] outer23_hi = ring2_hi_q + ring3_hi_q;
wire [19:0] pref7_hi = {1'b0, pref3_hi} + {1'b0, outer23_hi};
wire [20:0] pref9_hi = {1'b0, pref7_hi} + {3'd0, ring4_hi_q};

reg [36:0] sel_lo_d;
reg [20:0] sel_hi_d;
always @(*) begin
  case (reg2dp_normalz_len)
    2'h0: begin
      sel_lo_d = {2'd0, pref3_lo};
      sel_hi_d = {2'd0, pref3_hi};
    end
    2'h1: begin
      sel_lo_d = {1'b0, pref5_lo};
      sel_hi_d = {1'b0, pref5_hi};
    end
    2'h2: begin
      sel_lo_d = {1'b0, pref7_lo};
      sel_hi_d = {1'b0, pref7_hi};
    end
    default: begin
      sel_lo_d = pref9_lo;
      sel_hi_d = pref9_hi;
    end
  endcase
end

reg [36:0] acc_lo_q;
reg [20:0] acc_hi_q;
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    acc_lo_q <= 37'd0;
    acc_hi_q <= 21'd0;
  end else if (load_din_2d) begin
    acc_lo_q <= sel_lo_d;
    acc_hi_q <= sel_hi_d;
  end
end

assign int16_sum = acc_lo_q;
assign int8_sum  = {acc_hi_q, int8_en ? acc_lo_q[20:0] : 21'd0};

endmodule // int_sum_block
