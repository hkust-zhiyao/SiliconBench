// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_CDP_DP_INTP_unit.v

module cdp_intp_rv_stage #(
  parameter WIDTH = 17
) (
  input              clk,
  input              rstn,
  input              in_vld,
  output             in_rdy,
  input  [WIDTH-1:0] in_pd,
  output             out_vld,
  input              out_rdy,
  output [WIDTH-1:0] out_pd
);
  reg             vld_r;
  reg [WIDTH-1:0] pd_r;
  assign in_rdy  = ~vld_r | out_rdy;
  assign out_vld = vld_r;
  assign out_pd  = pd_r;
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      vld_r <= 1'b0;
      pd_r  <= {WIDTH{1'b0}};
    end else begin
      if (in_vld)
        vld_r <= 1'b1;
      else if (out_rdy)
        vld_r <= 1'b0;
      if (in_vld & in_rdy)
        pd_r <= in_pd;
    end
  end
endmodule

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
// INT8 / INT16 path: pre-sign-separated unsigned multiplier + post-shift 18b rounder
// =========================================================================
wire        s0_vld, s0_rdy, s1_vld, s1_rdy, s2_vld;
wire        s2_rdy = fp16_en ? 1'b1 : interp_out_rdy;
wire [80:0] s0_pd;
wire [80:0] s1_pd;
wire [15:0] s2_pd;

wire signed [39:0] delta_s40 = $signed({interp_in1_pd[37], interp_in1_pd[37:0]}) - $signed(interp_in0_pd[38:0]);
wire        [39:0] delta_mag = delta_s40[39] ? (40'd0 - delta_s40) : delta_s40;
wire        [16:0] scale_mag = interp_in_scale[16] ? (17'd0 - interp_in_scale) : interp_in_scale;
wire               prod_neg0 = delta_s40[39] ^ interp_in_scale[16];

cdp_intp_rv_stage #(.WIDTH(81)) u_int_s0 (
  .clk    (nvdla_op_gated_clk_int),
  .rstn   (nvdla_core_rstn),
  .in_vld (fp16_en ? 1'b0 : interp_in_vld),
  .in_rdy (int_in_rdy),
  .in_pd  ({prod_neg0, interp_in_shift, scale_mag, interp_in_pd, delta_mag}),
  .out_vld(s0_vld),
  .out_rdy(s0_rdy),
  .out_pd (s0_pd)
);

wire [39:0] d0_dmag  = s0_pd[39:0];
wire [16:0] d0_base  = s0_pd[56:40];
wire [16:0] d0_smag  = s0_pd[73:57];
wire  [5:0] d0_shift = s0_pd[79:74];
wire        d0_pneg  = s0_pd[80];
wire [56:0] prod_u57 = d0_dmag * d0_smag;

cdp_intp_rv_stage #(.WIDTH(81)) u_int_s1 (
  .clk    (nvdla_op_gated_clk_int),
  .rstn   (nvdla_core_rstn),
  .in_vld (s0_vld),
  .in_rdy (s0_rdy),
  .in_pd  ({d0_pneg, d0_shift, d0_base, prod_u57}),
  .out_vld(s1_vld),
  .out_rdy(s1_rdy),
  .out_pd (s1_pd)
);

// Post-shift 18-bit guard rounder + conditional add/sub into base
wire        [56:0] d1_pmag  = s1_pd[56:0];
wire signed [16:0] d1_base  = s1_pd[73:57];
wire         [5:0] d1_shift = s1_pd[79:74];
wire               d1_pneg  = s1_pd[80] & (|d1_pmag);

wire  [5:0] lsh_amt  = {1'b0, ~d1_shift[4:0]} + 6'd1;
wire [57:0] rsh_q1   = {d1_pmag, 1'b0} >> d1_shift[4:0];
wire [35:0] lsh_full = {19'd0, d1_pmag[16:0]} << ((lsh_amt > 6'd18) ? 6'd18 : lsh_amt);
wire        ovf_hi   = d1_shift[5] ? ((lsh_amt >= 6'd18) ? (|d1_pmag) : ((|d1_pmag[56:17]) | (|lsh_full[35:18])))
                                   : (|rsh_q1[57:19]);
wire [18:0] rnd_u19  = d1_shift[5] ? {1'b0, lsh_full[17:0]}
                                   : ({1'b0, rsh_q1[18:1]} + {18'd0, rsh_q1[0]});
wire [17:0] mag_clmp = (ovf_hi | rnd_u19[18]) ? 18'd131072 : rnd_u19[17:0];
wire signed [19:0] base_s20 = {{3{d1_base[16]}}, d1_base};
wire signed [19:0] sum_s20  = d1_pneg ? (base_s20 - $signed({2'b00, mag_clmp}))
                                      : (base_s20 + $signed({2'b00, mag_clmp}));
wire        [15:0] out_s16  = (sum_s20 < -20'sd32768) ? 16'h8000 :
                              (sum_s20 >  20'sd32767) ? 16'h7fff :
                              sum_s20[15:0];

cdp_intp_rv_stage #(.WIDTH(16)) u_int_s2 (
  .clk    (nvdla_op_gated_clk_int),
  .rstn   (nvdla_core_rstn),
  .in_vld (s1_vld),
  .in_rdy (s1_rdy),
  .in_pd  (out_s16),
  .out_vld(s2_vld),
  .out_rdy(s2_rdy),
  .out_pd (s2_pd)
);

// =========================================================================
// FP16 / FP17 path
// =========================================================================
wire        fp_sub_a_rdy, fp_sub_b_rdy, fp_sub_out_vld, fp_sub_out_rdy;
wire [31:0] fp_sub_out_pd;
wire        fp_sub_o_vld, fp_sub_o_rdy;
wire [16:0] fp_sub_o_pd;
wire  [7:0] f1_v;
wire  [7:0] f1_r;
wire [33:0] f1_d [0:7];

wire fp_go = fp16_en & interp_in_vld;
assign fp_in_rdy = fp_sub_a_rdy & fp_sub_b_rdy & f1_r[0];
assign f1_v[0]   = fp_go & fp_sub_a_rdy & fp_sub_b_rdy;
assign f1_d[0]   = {interp_in_pd, interp_in_scale};

HLS_fp32_sub u_fp_sub (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (interp_in1_pd[31:0])
  ,.chn_a_rsc_vz   (fp_go & fp_sub_b_rdy & f1_r[0])
  ,.chn_a_rsc_lz   (fp_sub_a_rdy)
  ,.chn_b_rsc_z    (interp_in0_pd[31:0])
  ,.chn_b_rsc_vz   (fp_go & fp_sub_a_rdy & f1_r[0])
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

genvar k;
generate
  for (k = 0; k < 7; k = k + 1) begin : g_f1
    cdp_intp_rv_stage #(.WIDTH(34)) u_st (
      .clk    (nvdla_op_gated_clk_fp16),
      .rstn   (nvdla_core_rstn),
      .in_vld (f1_v[k]),
      .in_rdy (f1_r[k]),
      .in_pd  (f1_d[k]),
      .out_vld(f1_v[k + 1]),
      .out_rdy(f1_r[k + 1]),
      .out_pd (f1_d[k + 1])
    );
  end
endgenerate

wire        fp_mul_a_rdy, fp_mul_b_rdy, fp_mul_out_vld, fp_mul_out_rdy;
wire [16:0] fp_mul_out_pd;
wire  [3:0] f2_v;
wire  [3:0] f2_r;
wire [16:0] f2_d [0:3];

wire mul_join_rdy = fp_mul_a_rdy & fp_mul_b_rdy & f2_r[0];
wire mul_join_vld = fp_sub_o_vld & f1_v[7];
assign fp_sub_o_rdy = mul_join_rdy & f1_v[7];
assign f1_r[7]      = mul_join_rdy & fp_sub_o_vld;
assign f2_v[0]      = mul_join_vld & fp_mul_a_rdy & fp_mul_b_rdy;
assign f2_d[0]      = f1_d[7][33:17];

HLS_fp17_mul u_fp_mul (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (fp_sub_o_pd)
  ,.chn_a_rsc_vz   (mul_join_vld & fp_mul_b_rdy & f2_r[0])
  ,.chn_a_rsc_lz   (fp_mul_a_rdy)
  ,.chn_b_rsc_z    (f1_d[7][16:0])
  ,.chn_b_rsc_vz   (mul_join_vld & fp_mul_a_rdy & f2_r[0])
  ,.chn_b_rsc_lz   (fp_mul_b_rdy)
  ,.chn_o_rsc_z    (fp_mul_out_pd)
  ,.chn_o_rsc_vz   (fp_mul_out_rdy)
  ,.chn_o_rsc_lz   (fp_mul_out_vld)
  );

generate
  for (k = 0; k < 3; k = k + 1) begin : g_f2
    cdp_intp_rv_stage #(.WIDTH(17)) u_st (
      .clk    (nvdla_op_gated_clk_fp16),
      .rstn   (nvdla_core_rstn),
      .in_vld (f2_v[k]),
      .in_rdy (f2_r[k]),
      .in_pd  (f2_d[k]),
      .out_vld(f2_v[k + 1]),
      .out_rdy(f2_r[k + 1]),
      .out_pd (f2_d[k + 1])
    );
  end
endgenerate

wire        fp_add_a_rdy, fp_add_b_rdy, fp_add_out_vld;
wire [16:0] fp_add_out_pd;
wire add_join_rdy = fp_add_a_rdy & fp_add_b_rdy;
wire add_join_vld = fp_mul_out_vld & f2_v[3];
assign fp_mul_out_rdy = add_join_rdy & f2_v[3];
assign f2_r[3]        = add_join_rdy & fp_mul_out_vld;

HLS_fp17_add u_fp_add (
   .nvdla_core_clk (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn(nvdla_core_rstn)
  ,.chn_a_rsc_z    (fp_mul_out_pd)
  ,.chn_a_rsc_vz   (add_join_vld & fp_add_b_rdy)
  ,.chn_a_rsc_lz   (fp_add_a_rdy)
  ,.chn_b_rsc_z    (f2_d[3])
  ,.chn_b_rsc_vz   (add_join_vld & fp_add_a_rdy)
  ,.chn_b_rsc_lz   (fp_add_b_rdy)
  ,.chn_o_rsc_z    (fp_add_out_pd)
  ,.chn_o_rsc_vz   (fp16_en ? interp_out_rdy : 1'b1)
  ,.chn_o_rsc_lz   (fp_add_out_vld)
  );

assign interp_out_vld = fp16_en ? fp_add_out_vld : s2_vld;
assign interp_out_pd  = fp16_en ? fp_add_out_pd  : {s2_pd[15], s2_pd};

endmodule // NV_NVDLA_CDP_DP_INTP_unit
