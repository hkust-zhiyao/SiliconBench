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
output reg [91:0] pooling_out;
output         pooling_out_pvld;

wire        is_fp_ave = reg2dp_fp16_en & average_pooling_en;
wire  [1:0] in_slot   = pdma2pdp_pd[93:92];
wire [87:0] in_vec    = pdma2pdp_pd[87:0];

wire        pipe_in_rdy_d0, pipe_in_rdy_d1, pipe_in_rdy_d2, pipe_in_rdy_d3, pipe_in_rdy_d4;
wire        pipe_in_vld_d0, pipe_in_vld_d1, pipe_in_vld_d2, pipe_in_vld_d3, pipe_in_vld_d4;
wire [184:0] pipe_in_pd_d0, pipe_in_pd_d1, pipe_in_pd_d2, pipe_in_pd_d3, pipe_in_pd_d4;
wire        fp_in_rdy, fp_out_vld, fp_out_rdy;
wire [16:0] fp_sum_lane0, fp_sum_lane1, fp_sum_lane2, fp_sum_lane3;

assign pdma2pdp_prdy = is_fp_ave ? (pipe_in_rdy_d0 & fp_in_rdy) : pipe_in_rdy_d0;
wire   accept_in     = pdma2pdp_pvld & pdma2pdp_prdy & (~cur_datin_disable) & pooling_unit_en;

// Monotonic unsigned order mapping for sign-magnitude FP16 comparison
function [15:0] fp16_order_key;
  input [15:0] x;
  begin
    fp16_order_key = x[15] ? (~x) : {1'b1, x[14:0]};
  end
endfunction

function [21:0] reduce_slice22;
  input        en_i8;
  input        en_i16;
  input        en_f16;
  input  [1:0] mode;
  input [21:0] a;
  input [21:0] b;
  reg          a_nan, b_nan;
  reg   [15:0] ka, kb;
  reg   [10:0] r8_lo, r8_hi;
  begin
    a_nan = (&a[14:10]) & (|a[9:0]);
    b_nan = (&b[14:10]) & (|b[9:0]);
    ka    = fp16_order_key(a[15:0]);
    kb    = fp16_order_key(b[15:0]);
    if (mode == 2'h0) begin
      if (en_i16) begin
        reduce_slice22 = $signed(a) + $signed(b);
      end else begin
        r8_lo = $signed(a[10:0])  + $signed(b[10:0]);
        r8_hi = $signed(a[21:11]) + $signed(b[21:11]);
        reduce_slice22 = {r8_hi, r8_lo};
      end
    end else if (mode == 2'h2) begin
      // MIN
      if (en_f16) begin
        if (a_nan)      reduce_slice22 = a;
        else if (b_nan) reduce_slice22 = b;
        else            reduce_slice22 = (ka > kb) ? b : a;
      end else if (en_i16) begin
        reduce_slice22 = ($signed(b) > $signed(a)) ? a : b;
      end else begin
        r8_lo = ($signed(b[10:0])  > $signed(a[10:0]))  ? a[10:0]  : b[10:0];
        r8_hi = ($signed(b[21:11]) > $signed(a[21:11])) ? a[21:11] : b[21:11];
        reduce_slice22 = {r8_hi, r8_lo};
      end
    end else if (mode == 2'h1) begin
      // MAX
      if (en_f16) begin
        if (a_nan)      reduce_slice22 = a;
        else if (b_nan) reduce_slice22 = b;
        else            reduce_slice22 = (ka > kb) ? a : b;
      end else if (en_i16) begin
        reduce_slice22 = ($signed(a) > $signed(b)) ? a : b;
      end else begin
        r8_lo = ($signed(a[10:0])  > $signed(b[10:0]))  ? a[10:0]  : b[10:0];
        r8_hi = ($signed(a[21:11]) > $signed(b[21:11])) ? a[21:11] : b[21:11];
        reduce_slice22 = {r8_hi, r8_lo};
      end
    end else begin
      reduce_slice22 = 22'd0;
    end
  end
endfunction

reg  [2:0] win_elem_cnt;
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    win_elem_cnt <= 3'd0;
  end else if (accept_in & pdp_din_lc_f) begin
    win_elem_cnt <= pooling_din_last ? 3'd0 : (win_elem_cnt + 3'd1);
  end
end

wire [87:0] slot_view [0:3];
wire [87:0] cur_slot_data = slot_view[in_slot];

wire fp_fire_in = pdma2pdp_pvld & pipe_in_rdy_d0 & is_fp_ave;
cal1d_fp16_pool_sum u_cal1d_fp16_pool_sum (
   .inp_a_0                 (cur_slot_data[16:0])
  ,.inp_a_1                 (cur_slot_data[38:22])
  ,.inp_a_2                 (cur_slot_data[60:44])
  ,.inp_a_3                 (cur_slot_data[82:66])
  ,.inp_b_0                 (in_vec[16:0])
  ,.inp_b_1                 (in_vec[38:22])
  ,.inp_b_2                 (in_vec[60:44])
  ,.inp_b_3                 (in_vec[82:66])
  ,.inp_in_pvld             (fp_fire_in)
  ,.inp_out_prdy            (fp_out_rdy)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.inp_in_prdy             (fp_in_rdy)
  ,.inp_out_pvld            (fp_out_vld)
  ,.out_z_0                 (fp_sum_lane0)
  ,.out_z_1                 (fp_sum_lane1)
  ,.out_z_2                 (fp_sum_lane2)
  ,.out_z_3                 (fp_sum_lane3)
  );
wire [67:0] fp_sum_packed = {fp_sum_lane3, fp_sum_lane2, fp_sum_lane1, fp_sum_lane0};

wire use_comb_op = (~is_fp_ave) & accept_in;
wire [87:0] op_lhs = use_comb_op ? cur_slot_data : 88'd0;
wire [87:0] op_rhs = use_comb_op ? in_vec        : 88'd0;
wire [87:0] comb_reduced = {
  reduce_slice22(reg2dp_int8_en, reg2dp_int16_en, reg2dp_fp16_en, pooling_type_cfg, op_lhs[87:66], op_rhs[87:66]),
  reduce_slice22(reg2dp_int8_en, reg2dp_int16_en, reg2dp_fp16_en, pooling_type_cfg, op_lhs[65:44], op_rhs[65:44]),
  reduce_slice22(reg2dp_int8_en, reg2dp_int16_en, reg2dp_fp16_en, pooling_type_cfg, op_lhs[43:22], op_rhs[43:22]),
  reduce_slice22(reg2dp_int8_en, reg2dp_int16_en, reg2dp_fp16_en, pooling_type_cfg, op_lhs[21:0],  op_rhs[21:0])
};

assign pipe_in_vld_d0 = is_fp_ave ? (pdma2pdp_pvld & fp_in_rdy) : pdma2pdp_pvld;
assign pipe_in_pd_d0  = {pooling_din_last, win_elem_cnt, cur_datin_disable, in_slot, pdp_din_lc_f, pooling_din_1st, in_vec, comb_reduced};

NV_NVDLA_PDP_CORE_UNIT1D_pipe_p1 pipe_p1 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d0   (pipe_in_pd_d0)
  ,.pipe_in_rdy_d1  (pipe_in_rdy_d1)
  ,.pipe_in_vld_d0  (pipe_in_vld_d0)
  ,.pipe_in_pd_d1   (pipe_in_pd_d1)
  ,.pipe_in_rdy_d0  (pipe_in_rdy_d0)
  ,.pipe_in_vld_d1  (pipe_in_vld_d1)
  );
NV_NVDLA_PDP_CORE_UNIT1D_pipe_p2 pipe_p2 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d1   (pipe_in_pd_d1)
  ,.pipe_in_rdy_d2  (pipe_in_rdy_d2)
  ,.pipe_in_vld_d1  (pipe_in_vld_d1)
  ,.pipe_in_pd_d2   (pipe_in_pd_d2)
  ,.pipe_in_rdy_d1  (pipe_in_rdy_d1)
  ,.pipe_in_vld_d2  (pipe_in_vld_d2)
  );
NV_NVDLA_PDP_CORE_UNIT1D_pipe_p3 pipe_p3 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d2   (pipe_in_pd_d2)
  ,.pipe_in_rdy_d3  (pipe_in_rdy_d3)
  ,.pipe_in_vld_d2  (pipe_in_vld_d2)
  ,.pipe_in_pd_d3   (pipe_in_pd_d3)
  ,.pipe_in_rdy_d2  (pipe_in_rdy_d2)
  ,.pipe_in_vld_d3  (pipe_in_vld_d3)
  );
NV_NVDLA_PDP_CORE_UNIT1D_pipe_p4 pipe_p4 (
   .nvdla_core_clk  (nvdla_core_clk)
  ,.nvdla_core_rstn (nvdla_core_rstn)
  ,.pipe_in_pd_d3   (pipe_in_pd_d3)
  ,.pipe_in_rdy_d4  (pipe_in_rdy_d4)
  ,.pipe_in_vld_d3  (pipe_in_vld_d3)
  ,.pipe_in_pd_d4   (pipe_in_pd_d4)
  ,.pipe_in_rdy_d3  (pipe_in_rdy_d3)
  ,.pipe_in_vld_d4  (pipe_in_vld_d4)
  );

wire        s4_vld     = is_fp_ave ? (pipe_in_vld_d4 & fp_out_vld) : pipe_in_vld_d4;
wire        s4_rdy     = (~s4_vld) | pooling_out_prdy;
assign pipe_in_rdy_d4  = is_fp_ave ? (s4_rdy & fp_out_vld) : s4_rdy;
assign fp_out_rdy      = is_fp_ave & s4_rdy & pipe_in_vld_d4;
assign pooling_out_pvld = s4_vld;

wire [87:0] s4_comb    = pipe_in_pd_d4[87:0];
wire [87:0] s4_raw     = pipe_in_pd_d4[175:88];
wire        s4_first   = pipe_in_pd_d4[176];
wire        s4_lc      = pipe_in_pd_d4[177];
wire  [1:0] s4_slot    = pipe_in_pd_d4[179:178];
wire        s4_dis     = pipe_in_pd_d4[180];
wire  [2:0] s4_sz      = pipe_in_pd_d4[183:181];
wire        s4_last    = pipe_in_pd_d4[184];

wire [67:0] s4_fp_init = {s4_raw[82:66], s4_raw[60:44], s4_raw[38:22], s4_raw[16:0]};
wire [67:0] s4_fp_val  = s4_first ? s4_fp_init : fp_sum_packed;
wire [87:0] s4_int_val = s4_first ? s4_raw     : s4_comb;

reg [67:0] fp_acc_q  [0:3];
reg [87:0] int_acc_q [0:3];
reg [91:0] flush_q   [0:3];
integer k;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    for (k = 0; k < 4; k = k + 1) begin
      fp_acc_q[k]  <= 68'd0;
      int_acc_q[k] <= 88'd0;
    end
  end else if (s4_vld & s4_rdy) begin
    fp_acc_q[s4_slot]  <= s4_fp_val;
    int_acc_q[s4_slot] <= s4_int_val;
  end
end

genvar c;
generate
  for (c = 0; c < 4; c = c + 1) begin : g_slot_fwd
    wire [67:0] fp_fwd  = (s4_slot == c[1:0]) ? s4_fp_val  : fp_acc_q[c];
    wire [87:0] int_fwd = (s4_slot == c[1:0]) ? s4_int_val : int_acc_q[c];
    wire [87:0] fp_exp  = {5'd0, fp_fwd[67:51], 5'd0, fp_fwd[50:34], 5'd0, fp_fwd[33:17], 5'd0, fp_fwd[16:0]};
    assign slot_view[c] = is_fp_ave ? fp_exp : int_fwd;
  end
endgenerate

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    for (k = 0; k < 4; k = k + 1)
      flush_q[k] <= 92'd0;
  end else if (s4_last & (~s4_dis)) begin
    flush_q[s4_slot] <= {s4_lc, s4_sz, slot_view[s4_slot]};
  end
end

reg [1:0] out_sub_idx;
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    out_sub_idx <= 2'd0;
  end else if (s4_vld & pooling_out_prdy & ((s4_last & (~s4_dis)) | last_out_en)) begin
    out_sub_idx <= out_sub_idx + 2'd1;
  end
end

always @(*) begin
  if (last_out_en)
    pooling_out = flush_q[out_sub_idx];
  else
    pooling_out = {s4_lc, s4_sz, slot_view[out_sub_idx]};
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


