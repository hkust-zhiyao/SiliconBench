// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_CDP_DP_INTP_unit.v

module NV_NVDLA_CDP_DP_INTP_unit (
   nvdla_op_gated_clk_int
  ,nvdla_core_rstn
  ,fp16_en
  ,interp_in0_pd
  ,interp_in1_pd
  ,interp_in_pd
  ,interp_in_scale
  ,interp_in_shift
  ,interp_in_vld
  ,interp_out_rdy
  ,nvdla_op_gated_clk_fp16
  ,interp_in_rdy
  ,interp_out_pd
  ,interp_out_vld
  );
input         nvdla_op_gated_clk_int;
input         nvdla_core_rstn;
input         fp16_en;
input  [38:0] interp_in0_pd;
input  [37:0] interp_in1_pd;
input  [16:0] interp_in_pd;
input  [16:0] interp_in_scale;
input   [5:0] interp_in_shift;
input         interp_in_vld;
input         interp_out_rdy;
input         nvdla_op_gated_clk_fp16;
output        interp_in_rdy;
output [16:0] interp_out_pd;
output        interp_out_vld;

wire fp_in_rdy;
wire int_in_rdy;
assign interp_in_rdy = fp16_en ? fp_in_rdy : int_in_rdy;

// =========================================================================
// INT8 / INT16 3-stage elastic linear interpolator with range-clamped shift
// =========================================================================
reg         int_vld_d0, int_vld_d1, int_vld_d2;
reg  [39:0] int_sub;
reg  [16:0] interp_in0_pd_d0, interp_in0_pd_d1;
reg  [16:0] interp_in_offset_d0;
reg   [5:0] interp_in_shift_d0, interp_in_shift_d1;
reg  [56:0] int_mul;
reg  [15:0] int_out_q;

wire int_interp_out_rdy = fp16_en ? 1'b1 : interp_out_rdy;
wire int_rdy_d2 = int_interp_out_rdy;
wire int_rdy_d1 = ~int_vld_d2 | int_rdy_d2;
wire int_rdy_d0 = ~int_vld_d1 | int_rdy_d1;
wire int_in_vld = fp16_en ? 1'b0 : interp_in_vld;
assign int_in_rdy = ~int_vld_d0 | int_rdy_d0;

wire int_in_load    = int_in_vld & int_in_rdy;
wire int_in_load_d0 = int_vld_d0 & int_rdy_d0;
wire int_in_load_d1 = int_vld_d1 & int_rdy_d1;

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_vld_d0          <= 1'b0;
    int_sub             <= 40'd0;
    interp_in0_pd_d0    <= 17'd0;
    interp_in_offset_d0 <= 17'd0;
    interp_in_shift_d0  <= 6'd0;
  end else begin
    if (int_in_vld)
      int_vld_d0 <= 1'b1;
    else if (int_rdy_d0)
      int_vld_d0 <= 1'b0;

    if (int_in_load) begin
      int_sub             <= $signed({interp_in1_pd[37], interp_in1_pd[37:0]}) - $signed(interp_in0_pd[38:0]);
      interp_in0_pd_d0    <= interp_in_pd;
      interp_in_offset_d0 <= interp_in_scale;
      interp_in_shift_d0  <= interp_in_shift;
    end
  end
end

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_vld_d1         <= 1'b0;
    int_mul            <= 57'd0;
    interp_in0_pd_d1   <= 17'd0;
    interp_in_shift_d1 <= 6'd0;
  end else begin
    if (int_vld_d0)
      int_vld_d1 <= 1'b1;
    else if (int_rdy_d1)
      int_vld_d1 <= 1'b0;

    if (int_in_load_d0) begin
      int_mul            <= $signed(int_sub) * $signed(interp_in_offset_d0);
      interp_in0_pd_d1   <= interp_in0_pd_d0;
      interp_in_shift_d1 <= interp_in_shift_d0;
    end
  end
end

// Stage d1 -> d2: two's-complement clamped shift + round-half-away-from-zero + saturate
wire        mul_neg   = int_mul[56];
wire        mul_nz    = |int_mul;
wire        is_lshift = interp_in_shift_d1[5];
wire  [5:0] sh_left   = {1'b0, ~interp_in_shift_d1[4:0]} + 6'd1;
wire  [4:0] sh_right  = interp_in_shift_d1[4:0];

// Left shift: clamp signed result to 18-bit [-131072, +131071]
wire signed [74:0] mul_lsh_ext = $signed({{18{mul_neg}}, int_mul}) <<< (sh_left > 6'd18 ? 6'd18 : sh_left);
wire        lsh_ovf_pos = (~mul_neg) & ((sh_left >= 6'd18) ? mul_nz : (|mul_lsh_ext[74:17]));
wire        lsh_ovf_neg = mul_neg    & ((sh_left >= 6'd18) ? 1'b1   : (~(&mul_lsh_ext[74:17])));
wire signed [17:0] lsh_clamped = lsh_ovf_pos ? 18'sd131071 :
                                 lsh_ovf_neg ? -18'sd131072 :
                                 mul_lsh_ext[17:0];

// Right shift: arithmetic shift + guard/sticky half-away-from-zero rounding
wire signed [56:0] rsh_q = $signed(int_mul) >>> sh_right;
wire [31:0] rsh_frac = ({int_mul[30:0], 1'b0} << (5'd31 - sh_right));
wire        rsh_guard  = (sh_right != 5'd0) & rsh_frac[31];
wire        rsh_sticky = (sh_right >  5'd1) & (|rsh_frac[30:0]);
wire        rsh_rnd    = rsh_guard & ((~mul_neg) | rsh_sticky);
wire        rsh_ovf_pos = (~mul_neg) & (|rsh_q[56:17]);
wire        rsh_ovf_neg = mul_neg    & (~(&rsh_q[56:17]));
wire signed [17:0] rsh_clamped = rsh_ovf_pos ? 18'sd131071 :
                                 rsh_ovf_neg ? -18'sd131072 :
                                 rsh_q[17:0];

wire signed [17:0] shifted_term = is_lshift ? lsh_clamped : rsh_clamped;
wire        [1:0]  rnd_term     = {1'b0, (~is_lshift) & rsh_rnd};
wire signed [18:0] sum_s19 = $signed({shifted_term[17], shifted_term}) +
                             $signed({{2{interp_in0_pd_d1[16]}}, interp_in0_pd_d1}) +
                             $signed({17'd0, rnd_term});
wire [15:0] sat_s16 = sum_s19[18] ? ((&sum_s19[18:15]) ? sum_s19[15:0] : 16'h8000)
                                  : ((|sum_s19[18:15]) ? 16'h7fff      : sum_s19[15:0]);

always @(posedge nvdla_op_gated_clk_int or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    int_vld_d2 <= 1'b0;
    int_out_q  <= 16'd0;
  end else begin
    if (int_vld_d1)
      int_vld_d2 <= 1'b1;
    else if (int_rdy_d2)
      int_vld_d2 <= 1'b0;

    if (int_in_load_d1)
      int_out_q <= sat_s16;
  end
end

// =========================================================================
// FP16 / FP17 elastic linear interpolator
// =========================================================================
wire        fp_sub_a_rdy, fp_sub_b_rdy, fp_sub_out_vld, fp_sub_out_rdy;
wire [31:0] fp_sub_out_pd;
wire        fp_sub_o_vld, fp_sub_o_rdy;
wire [16:0] fp_sub_o_pd;

wire        fp_in_vld = fp16_en ? interp_in_vld : 1'b0;
wire  [7:0] sub_sync_vld;
wire  [7:0] sub_sync_rdy;
wire [33:0] sub_sync_pd [0:7];

assign fp_in_rdy      = fp_sub_a_rdy & fp_sub_b_rdy & sub_sync_rdy[0];
wire   fp_sub_a_vld   = fp_in_vld & fp_sub_b_rdy & sub_sync_rdy[0];
wire   fp_sub_b_vld   = fp_in_vld & fp_sub_a_rdy & sub_sync_rdy[0];
assign sub_sync_vld[0] = fp_in_vld & fp_sub_a_rdy & fp_sub_b_rdy;
assign sub_sync_pd[0]  = {interp_in_pd, interp_in_scale};

HLS_fp32_sub u_fp_sub (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (interp_in1_pd[31:0])
  ,.chn_a_rsc_vz   (fp_sub_a_vld)
  ,.chn_a_rsc_lz   (fp_sub_a_rdy)
  ,.chn_b_rsc_z    (interp_in0_pd[31:0])
  ,.chn_b_rsc_vz   (fp_sub_b_vld)
  ,.chn_b_rsc_lz   (fp_sub_b_rdy)
  ,.chn_o_rsc_z    (fp_sub_out_pd)
  ,.chn_o_rsc_vz   (fp_sub_out_rdy)
  ,.chn_o_rsc_lz   (fp_sub_out_vld)
  );

HLS_fp32_to_fp17 u_HLS_fp32_to_fp17 (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (fp_sub_out_pd)
  ,.chn_a_rsc_vz   (fp_sub_out_vld)
  ,.chn_a_rsc_lz   (fp_sub_out_rdy)
  ,.chn_o_rsc_z    (fp_sub_o_pd)
  ,.chn_o_rsc_vz   (fp_sub_o_rdy)
  ,.chn_o_rsc_lz   (fp_sub_o_vld)
  );

genvar gs;
generate
  for (gs = 0; gs < 7; gs = gs + 1) begin : g_sub_sync
    reg        v_q;
    reg [33:0] d_q;
    assign sub_sync_rdy[gs] = ~v_q | sub_sync_rdy[gs + 1];
    always @(posedge nvdla_op_gated_clk_fp16 or negedge nvdla_core_rstn) begin
      if (!nvdla_core_rstn) begin
        v_q <= 1'b0;
        d_q <= 34'd0;
      end else begin
        if (sub_sync_vld[gs])
          v_q <= 1'b1;
        else if (sub_sync_rdy[gs + 1])
          v_q <= 1'b0;
        if (sub_sync_vld[gs] & sub_sync_rdy[gs])
          d_q <= sub_sync_pd[gs];
      end
    end
    assign sub_sync_vld[gs + 1] = v_q;
    assign sub_sync_pd[gs + 1]  = d_q;
  end
endgenerate

wire        fp_mul_a_rdy, fp_mul_b_rdy, fp_mul_out_vld, fp_mul_out_rdy;
wire [16:0] fp_mul_out_pd;
wire  [3:0] mul_sync_vld;
wire  [3:0] mul_sync_rdy;
wire [16:0] mul_sync_pd [0:3];

wire fp_interp_rdy_d0 = fp_mul_a_rdy & fp_mul_b_rdy & mul_sync_rdy[0];
assign fp_sub_o_rdy     = fp_interp_rdy_d0 & sub_sync_vld[7];
assign sub_sync_rdy[7]  = fp_interp_rdy_d0 & fp_sub_o_vld;
wire fp_interp_vld_d0   = fp_sub_o_vld & sub_sync_vld[7];

wire fp_mul_a_vld      = fp_interp_vld_d0 & fp_mul_b_rdy & mul_sync_rdy[0];
wire fp_mul_b_vld      = fp_interp_vld_d0 & fp_mul_a_rdy & mul_sync_rdy[0];
assign mul_sync_vld[0] = fp_interp_vld_d0 & fp_mul_a_rdy & fp_mul_b_rdy;
assign mul_sync_pd[0]  = sub_sync_pd[7][33:17];

HLS_fp17_mul u_fp_mul (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (fp_sub_o_pd)
  ,.chn_a_rsc_vz   (fp_mul_a_vld)
  ,.chn_a_rsc_lz   (fp_mul_a_rdy)
  ,.chn_b_rsc_z    (sub_sync_pd[7][16:0])
  ,.chn_b_rsc_vz   (fp_mul_b_vld)
  ,.chn_b_rsc_lz   (fp_mul_b_rdy)
  ,.chn_o_rsc_z    (fp_mul_out_pd)
  ,.chn_o_rsc_vz   (fp_mul_out_rdy)
  ,.chn_o_rsc_lz   (fp_mul_out_vld)
  );

generate
  for (gs = 0; gs < 3; gs = gs + 1) begin : g_mul_sync
    reg        v_q;
    reg [16:0] d_q;
    assign mul_sync_rdy[gs] = ~v_q | mul_sync_rdy[gs + 1];
    always @(posedge nvdla_op_gated_clk_fp16 or negedge nvdla_core_rstn) begin
      if (!nvdla_core_rstn) begin
        v_q <= 1'b0;
        d_q <= 17'd0;
      end else begin
        if (mul_sync_vld[gs])
          v_q <= 1'b1;
        else if (mul_sync_rdy[gs + 1])
          v_q <= 1'b0;
        if (mul_sync_vld[gs] & mul_sync_rdy[gs])
          d_q <= mul_sync_pd[gs];
      end
    end
    assign mul_sync_vld[gs + 1] = v_q;
    assign mul_sync_pd[gs + 1]  = d_q;
  end
endgenerate

wire        fp_add_a_rdy, fp_add_b_rdy, fp_add_out_vld;
wire [16:0] fp_add_out_pd;
wire        fp_interp_rdy_d1 = fp_add_a_rdy & fp_add_b_rdy;
assign fp_mul_out_rdy   = fp_interp_rdy_d1 & mul_sync_vld[3];
assign mul_sync_rdy[3]  = fp_interp_rdy_d1 & fp_mul_out_vld;
wire fp_interp_vld_d1   = fp_mul_out_vld & mul_sync_vld[3];
wire fp_add_a_vld       = fp_interp_vld_d1 & fp_add_b_rdy;
wire fp_add_b_vld       = fp_interp_vld_d1 & fp_add_a_rdy;
wire fp_add_out_rdy     = fp16_en ? interp_out_rdy : 1'b1;

HLS_fp17_add u_fp_add (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (fp_mul_out_pd)
  ,.chn_a_rsc_vz   (fp_add_a_vld)
  ,.chn_a_rsc_lz   (fp_add_a_rdy)
  ,.chn_b_rsc_z    (mul_sync_pd[3])
  ,.chn_b_rsc_vz   (fp_add_b_vld)
  ,.chn_b_rsc_lz   (fp_add_b_rdy)
  ,.chn_o_rsc_z    (fp_add_out_pd)
  ,.chn_o_rsc_vz   (fp_add_out_rdy)
  ,.chn_o_rsc_lz   (fp_add_out_vld)
  );

assign interp_out_vld = fp16_en ? fp_add_out_vld : int_vld_d2;
assign interp_out_pd  = fp16_en ? fp_add_out_pd  : {int_out_q[15], int_out_q};

endmodule // NV_NVDLA_CDP_DP_INTP_unit
