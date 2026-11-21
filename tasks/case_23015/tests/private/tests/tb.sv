`timescale 1ns/1ps

module tb;
  reg clk = 1'b0;
  always #2.0 clk = ~clk;
  reg rstn = 1'b0;

  integer seed = 101;
  integer err_cnt = 0;

  // =========================================================================
  // Part A1: Bit-accurate unit scoreboard for int_sum_block
  // =========================================================================
  reg         isb_i8, isb_ld1, isb_ld2;
  reg   [1:0] isb_len;
  reg  [32:0] isb_s16 [0:8];
  reg  [16:0] isb_s8l [0:8];
  reg  [16:0] isb_s8m [0:8];
  wire [36:0] isb_out16;
  wire [41:0] isb_out8;

  int_sum_block u_chk_isb (
    .nvdla_core_clk(clk), .nvdla_core_rstn(rstn), .int8_en(isb_i8),
    .len5(isb_len == 2'd1), .len7(isb_len == 2'd2), .len9(isb_len == 2'd3),
    .load_din_d(isb_ld1), .load_din_2d(isb_ld2), .reg2dp_normalz_len(isb_len),
    .sq_pd_int16_0(isb_s16[0]), .sq_pd_int16_1(isb_s16[1]), .sq_pd_int16_2(isb_s16[2]),
    .sq_pd_int16_3(isb_s16[3]), .sq_pd_int16_4(isb_s16[4]), .sq_pd_int16_5(isb_s16[5]),
    .sq_pd_int16_6(isb_s16[6]), .sq_pd_int16_7(isb_s16[7]), .sq_pd_int16_8(isb_s16[8]),
    .sq_pd_int8_lsb_0(isb_s8l[0]), .sq_pd_int8_lsb_1(isb_s8l[1]), .sq_pd_int8_lsb_2(isb_s8l[2]),
    .sq_pd_int8_lsb_3(isb_s8l[3]), .sq_pd_int8_lsb_4(isb_s8l[4]), .sq_pd_int8_lsb_5(isb_s8l[5]),
    .sq_pd_int8_lsb_6(isb_s8l[6]), .sq_pd_int8_lsb_7(isb_s8l[7]), .sq_pd_int8_lsb_8(isb_s8l[8]),
    .sq_pd_int8_msb_0(isb_s8m[0]), .sq_pd_int8_msb_1(isb_s8m[1]), .sq_pd_int8_msb_2(isb_s8m[2]),
    .sq_pd_int8_msb_3(isb_s8m[3]), .sq_pd_int8_msb_4(isb_s8m[4]), .sq_pd_int8_msb_5(isb_s8m[5]),
    .sq_pd_int8_msb_6(isb_s8m[6]), .sq_pd_int8_msb_7(isb_s8m[7]), .sq_pd_int8_msb_8(isb_s8m[8]),
    .int16_sum(isb_out16), .int8_sum(isb_out8)
  );

  reg [41:0] isb_st1_exp, isb_st2_exp;
  reg        isb_st1_v,   isb_st2_v;
  integer    isb_rd = 0;
  function [41:0] calc_isb_now(input i8, input [1:0] ln);
    integer k, lk, hk;
    reg [36:0] a16;
    reg [20:0] a8l, a8m;
    begin
      lk = 3 - ln; hk = 5 + ln;
      a16 = 37'd0; a8l = 21'd0; a8m = 21'd0;
      for (k = 0; k < 9; k = k + 1)
        if (k >= lk && k <= hk) begin
          a16 = a16 + {4'd0, isb_s16[k]};
          a8l = a8l + {4'd0, isb_s8l[k]};
          a8m = a8m + {4'd0, isb_s8m[k]};
        end
      calc_isb_now = i8 ? {a8m, a8l} : {5'd0, a16};
    end
  endfunction

  reg        isb_chk_v;
  reg [41:0] isb_chk_exp;
  always @(posedge clk) begin
    if (!rstn) begin
      isb_st1_v <= 1'b0; isb_chk_v <= 1'b0;
    end else begin
      isb_chk_v   <= isb_ld2 & isb_st1_v;
      isb_chk_exp <= isb_st1_exp;
      if (isb_ld1) begin
        isb_st1_v   <= 1'b1;
        isb_st1_exp <= calc_isb_now(isb_i8, isb_len);
      end else if (isb_ld2) begin
        isb_st1_v   <= 1'b0;
      end
      if (isb_chk_v) begin
        reg [41:0] got_isb;
        got_isb = isb_i8 ? isb_out8 : {5'd0, isb_out16};
        if (got_isb !== isb_chk_exp) begin
          if (err_cnt < 10) $display("ERR isb[%0d]: got=%h exp=%h", isb_rd, got_isb, isb_chk_exp);
          err_cnt = err_cnt + 1;
        end
        isb_rd <= isb_rd + 1;
      end
    end
  end

  // =========================================================================
  // Part A2: Bit-accurate unit scoreboard for NV_NVDLA_CDP_DP_INTP_unit (INT)
  // =========================================================================
  reg         itp_fp16, itp_vld, itp_rdy_in;
  reg  [38:0] itp_in0;
  reg  [37:0] itp_in1;
  reg  [16:0] itp_base, itp_scale;
  reg   [5:0] itp_shift;
  wire        itp_in_rdy, itp_out_vld;
  wire [16:0] itp_out_pd;

  NV_NVDLA_CDP_DP_INTP_unit u_chk_itp (
    .nvdla_op_gated_clk_int(clk), .nvdla_op_gated_clk_fp16(clk), .nvdla_core_rstn(rstn),
    .fp16_en(itp_fp16), .interp_in0_pd(itp_in0), .interp_in1_pd(itp_in1),
    .interp_in_pd(itp_base), .interp_in_scale(itp_scale), .interp_in_shift(itp_shift),
    .interp_in_vld(itp_vld), .interp_out_rdy(itp_rdy_in),
    .interp_in_rdy(itp_in_rdy), .interp_out_pd(itp_out_pd), .interp_out_vld(itp_out_vld)
  );

  function [16:0] ref_itp_int(input [38:0] i0, input [37:0] i1, input [16:0] b, input [16:0] sc, input [5:0] sh);
    reg signed [63:0] d0, d1, diff, scl;
    reg signed [127:0] prod, mag, q, tot;
    integer s;
    begin
      d0 = {{25{i0[38]}}, i0};
      d1 = {{26{i1[37]}}, i1};
      diff = d1 - d0;
      scl  = {{47{sc[16]}}, sc};
      prod = diff * scl;
      s    = $signed(sh);
      mag  = (prod < 0) ? -prod : prod;
      if (s < 0)      q = mag <<< (-s);
      else if (s==0)  q = mag;
      else            q = (mag + (128'sd1 <<< (s - 1))) >>> s;
      tot = {{111{b[16]}}, b} + ((prod < 0) ? -q : q);
      if (tot < -128'sd32768)      ref_itp_int = 17'h18000;
      else if (tot > 128'sd32767)  ref_itp_int = 17'h07fff;
      else                         ref_itp_int = {tot[15], tot[15:0]};
    end
  endfunction

  reg [16:0] itp_exp_q [0:1023];
  integer itp_wr = 0, itp_rd = 0;
  always @(posedge clk) begin
    if (rstn && itp_vld && itp_in_rdy) begin
      itp_exp_q[itp_wr] <= ref_itp_int(itp_in0, itp_in1, itp_base, itp_scale, itp_shift);
      itp_wr <= itp_wr + 1;
    end
    if (rstn && itp_out_vld && itp_rdy_in) begin
      if (itp_out_pd !== itp_exp_q[itp_rd]) begin
        if (err_cnt < 10) $display("ERR itp[%0d]: got=%h exp=%h", itp_rd, itp_out_pd, itp_exp_q[itp_rd]);
        err_cnt = err_cnt + 1;
      end
      itp_rd <= itp_rd + 1;
    end
  end

  // =========================================================================
  // Part A3: Bit-accurate unit scoreboard for NV_NVDLA_CDP_DP_LUT_CTRL_unit
  // =========================================================================
  reg         lc_fp16, lc_i16, lc_i8, lc_fn, lc_sqb, lc_vld, lc_rdy_in;
  reg   [7:0] lc_le_off, lc_le_sel, lc_lo_sel;
  reg   [5:0] lc_le_sh, lc_lo_sh;
  reg  [31:0] lc_le_sl, lc_lo_sl;
  reg  [41:0] lc_din;
  wire [35:0] lc_xi, lc_yi;
  wire [19:0] lc_xp, lc_yp;
  wire        lc_out_vld, lc_in_rdy;

  NV_NVDLA_CDP_DP_LUT_CTRL_unit u_chk_lc (
    .nvdla_core_clk(clk), .nvdla_op_gated_clk_fp16(clk), .nvdla_op_gated_clk_int(clk), .nvdla_core_rstn(rstn),
    .dp2lut_prdy(lc_rdy_in), .fp16_en(lc_fp16), .int16_en(lc_i16), .int8_en(lc_i8),
    .reg2dp_lut_le_function(lc_fn), .reg2dp_lut_le_index_offset(lc_le_off), .reg2dp_lut_le_index_select(lc_le_sel),
    .reg2dp_lut_le_start_high(lc_le_sh), .reg2dp_lut_le_start_low(lc_le_sl),
    .reg2dp_lut_lo_index_select(lc_lo_sel), .reg2dp_lut_lo_start_high(lc_lo_sh), .reg2dp_lut_lo_start_low(lc_lo_sl),
    .reg2dp_sqsum_bypass(lc_sqb), .sum2itp_pd(lc_din), .sum2itp_pvld(lc_vld),
    .dp2lut_X_info(lc_xi), .dp2lut_X_pd(lc_xp), .dp2lut_Y_info(lc_yi), .dp2lut_Y_pd(lc_yp),
    .dp2lut_pvld(lc_out_vld), .sum2itp_prdy(lc_in_rdy)
  );

  // Reference FP32 subtractors (read-only HLS_fp32_sub) for exact IEEE-754 diff
  wire [31:0] ref_fx_diff, ref_fy_diff;
  wire        ref_fx_v, ref_fy_v, ref_fx_ar, ref_fx_br, ref_fy_ar, ref_fy_br;
  HLS_fp32_sub u_ref_fx (.nvdla_core_clk(clk), .nvdla_core_rstn(rstn),
    .chn_a_rsc_z(lc_din[31:0]), .chn_a_rsc_vz(lc_fp16 & lc_vld & lc_in_rdy), .chn_a_rsc_lz(ref_fx_ar),
    .chn_b_rsc_z(lc_le_sl),     .chn_b_rsc_vz(lc_fp16 & lc_vld & lc_in_rdy), .chn_b_rsc_lz(ref_fx_br),
    .chn_o_rsc_z(ref_fx_diff),  .chn_o_rsc_vz(1'b1), .chn_o_rsc_lz(ref_fx_v));
  HLS_fp32_sub u_ref_fy (.nvdla_core_clk(clk), .nvdla_core_rstn(rstn),
    .chn_a_rsc_z(lc_din[31:0]), .chn_a_rsc_vz(lc_fp16 & lc_vld & lc_in_rdy), .chn_a_rsc_lz(ref_fy_ar),
    .chn_b_rsc_z(lc_lo_sl),     .chn_b_rsc_vz(lc_fp16 & lc_vld & lc_in_rdy), .chn_b_rsc_lz(ref_fy_br),
    .chn_o_rsc_z(ref_fy_diff),  .chn_o_rsc_vz(1'b1), .chn_o_rsc_lz(ref_fy_v));

  function [27:0] ref_fp_lut(input [31:0] diff, input is_exp, input [7:0] off, input [7:0] sel, input [9:0] lim);
    reg nan_f, pinf_f, uf0;
    integer e_unb, e_idx, p;
    reg [63:0] w;
    reg [9:0] ix;
    reg [15:0] fr;
    reg of_f, uf_f;
    begin
      nan_f  = (&diff[30:23]) & (|diff[22:0]);
      pinf_f = (~diff[31]) & (&diff[30:23]) & (~|diff[22:0]);
      uf0    = nan_f | (~|diff) | diff[31];
      if (uf0) begin
        ref_fp_lut = {1'b0, 1'b1, 16'd0, 10'd0};
      end else if (pinf_f) begin
        ref_fp_lut = {1'b1, 1'b0, 16'd0, lim};
      end else if (is_exp) begin
        e_unb = $signed({1'b0, diff[30:23]}) - 127 - $signed(off);
        if (e_unb < 0)        ref_fp_lut = {1'b0, 1'b1, 16'd0, 10'd0};
        else if (e_unb >= 64) ref_fp_lut = {1'b1, 1'b0, diff[22:7], 10'd64};
        else                  ref_fp_lut = {1'b0, 1'b0, diff[22:7], e_unb[9:0]};
      end else begin
        p = $signed({2'b00, diff[30:23]}) - 110 - $signed(sel);
        if (p < 0)       ref_fp_lut = {1'b0, 1'b0, 16'd0, 10'd0};
        else if (p > 40) ref_fp_lut = {1'b1, 1'b0, 16'd0, lim};
        else begin
          w    = {40'd0, 1'b1, diff[22:0]} << p;
          fr   = w[39:24];
          of_f = (w[63:40] >= {14'd0, lim});
          ix   = of_f ? lim : w[49:40];
          ref_fp_lut = {of_f, 1'b0, fr, ix};
        end
      end
    end
  endfunction

  reg [55:0] lc_fp_exp_x [0:511];
  reg [55:0] lc_fp_exp_y [0:511];
  integer lc_fx_wr = 0, lc_fy_wr = 0, lc_fp_rd = 0;
  always @(posedge clk) begin
    if (rstn && ref_fx_v) begin
      reg [27:0] rx;
      rx = ref_fp_lut(ref_fx_diff, ~lc_fn, lc_le_off, lc_le_sel, 10'd64);
      lc_fp_exp_x[lc_fx_wr] <= {1'b0, rx[27], 1'b0, rx[26], 16'd0, rx[25:10], 10'd0, rx[9:0]};
      lc_fx_wr <= lc_fx_wr + 1;
    end
    if (rstn && ref_fy_v) begin
      reg [27:0] ry;
      ry = ref_fp_lut(ref_fy_diff, 1'b0, 8'd0, lc_lo_sel, 10'd256);
      lc_fp_exp_y[lc_fy_wr] <= {1'b0, ry[27], 1'b0, ry[26], 16'd0, ry[25:10], 10'd0, ry[9:0]};
      lc_fy_wr <= lc_fy_wr + 1;
    end
    if (rstn && lc_fp16 && lc_out_vld && lc_rdy_in) begin
      reg [27:0] gx, ex, gy, ey;
      gx = {lc_xi[34], lc_xi[32], (lc_xi[34]|lc_xi[32]) ? 16'd0 : lc_xi[15:0], lc_xp[9:0]};
      ex = {lc_fp_exp_x[lc_fp_rd][54], lc_fp_exp_x[lc_fp_rd][52], (lc_fp_exp_x[lc_fp_rd][54]|lc_fp_exp_x[lc_fp_rd][52]) ? 16'd0 : lc_fp_exp_x[lc_fp_rd][35:20], lc_fp_exp_x[lc_fp_rd][9:0]};
      gy = {lc_yi[34], lc_yi[32], (lc_yi[34]|lc_yi[32]) ? 16'd0 : lc_yi[15:0], lc_yp[9:0]};
      ey = {lc_fp_exp_y[lc_fp_rd][54], lc_fp_exp_y[lc_fp_rd][52], (lc_fp_exp_y[lc_fp_rd][54]|lc_fp_exp_y[lc_fp_rd][52]) ? 16'd0 : lc_fp_exp_y[lc_fp_rd][35:20], lc_fp_exp_y[lc_fp_rd][9:0]};
      if (gx !== ex || gy !== ey) begin
        if (err_cnt < 10)
          $display("ERR lc_fp[%0d]: gotX=%h expX=%h gotY=%h expY=%h", lc_fp_rd, gx, ex, gy, ey);
        err_cnt = err_cnt + 1;
      end
      lc_fp_rd <= lc_fp_rd + 1;
    end
  end

  // =========================================================================
  // Part B: Full End-to-End NV_NVDLA_CDP_dp Multi-Cube Subsystem Verification
  // =========================================================================
  reg         cdp_dp2wdma_ready;
  reg  [86:0] cdp_rdma2dp_pd;
  reg         cdp_rdma2dp_valid, dp2reg_done;
  reg  [15:0] reg2dp_datin_offset, reg2dp_datin_scale, reg2dp_datout_scale, reg2dp_lut_data;
  reg   [4:0] reg2dp_datin_shifter;
  reg  [31:0] reg2dp_datout_offset;
  reg   [5:0] reg2dp_datout_shifter;
  reg   [1:0] reg2dp_input_data_type, reg2dp_normalz_len;
  reg         reg2dp_lut_access_type, reg2dp_lut_data_trigger, reg2dp_lut_hybrid_priority;
  reg         reg2dp_lut_le_function, reg2dp_lut_oflow_priority, reg2dp_lut_table_id, reg2dp_lut_uflow_priority;
  reg         reg2dp_mul_bypass, reg2dp_sqsum_bypass;
  reg   [9:0] reg2dp_lut_addr;
  reg   [5:0] reg2dp_lut_le_end_high, reg2dp_lut_le_start_high, reg2dp_lut_lo_end_high, reg2dp_lut_lo_start_high;
  reg  [31:0] reg2dp_lut_le_end_low, reg2dp_lut_le_start_low, reg2dp_lut_lo_end_low, reg2dp_lut_lo_start_low;
  reg   [7:0] reg2dp_lut_le_index_offset, reg2dp_lut_le_index_select, reg2dp_lut_lo_index_select;
  reg  [15:0] reg2dp_lut_le_slope_oflow_scale, reg2dp_lut_le_slope_uflow_scale;
  reg  [15:0] reg2dp_lut_lo_slope_oflow_scale, reg2dp_lut_lo_slope_uflow_scale;
  reg   [4:0] reg2dp_lut_le_slope_oflow_shift, reg2dp_lut_le_slope_uflow_shift;
  reg   [4:0] reg2dp_lut_lo_slope_oflow_shift, reg2dp_lut_lo_slope_uflow_shift;

  wire [78:0] cdp_dp2wdma_pd;
  wire        cdp_dp2wdma_valid, cdp_rdma2dp_ready;
  wire [31:0] d0_sat, d0_hyb, d0_le, d0_lo, d0_of, d0_uf;
  wire [31:0] d1_sat, d1_hyb, d1_le, d1_lo, d1_of, d1_uf;
  wire [15:0] dp2reg_lut_data;

  NV_NVDLA_CDP_dp u_dut (
    .nvdla_core_clk(clk), .nvdla_core_rstn(rstn),
    .nvdla_core_clk_orig(clk), .nvdla_op_gated_clk_fp16(clk), .nvdla_op_gated_clk_int(clk),
    .pwrbus_ram_pd(32'd0),
    .cdp_dp2wdma_ready(cdp_dp2wdma_ready), .cdp_dp2wdma_pd(cdp_dp2wdma_pd), .cdp_dp2wdma_valid(cdp_dp2wdma_valid),
    .cdp_rdma2dp_pd(cdp_rdma2dp_pd), .cdp_rdma2dp_valid(cdp_rdma2dp_valid), .cdp_rdma2dp_ready(cdp_rdma2dp_ready),
    .dp2reg_done(dp2reg_done),
    .reg2dp_datin_offset(reg2dp_datin_offset), .reg2dp_datin_scale(reg2dp_datin_scale), .reg2dp_datin_shifter(reg2dp_datin_shifter),
    .reg2dp_datout_offset(reg2dp_datout_offset), .reg2dp_datout_scale(reg2dp_datout_scale), .reg2dp_datout_shifter(reg2dp_datout_shifter),
    .reg2dp_input_data_type(reg2dp_input_data_type),
    .reg2dp_lut_access_type(reg2dp_lut_access_type), .reg2dp_lut_addr(reg2dp_lut_addr), .reg2dp_lut_data(reg2dp_lut_data),
    .reg2dp_lut_data_trigger(reg2dp_lut_data_trigger), .reg2dp_lut_hybrid_priority(reg2dp_lut_hybrid_priority),
    .reg2dp_lut_le_end_high(reg2dp_lut_le_end_high), .reg2dp_lut_le_end_low(reg2dp_lut_le_end_low),
    .reg2dp_lut_le_function(reg2dp_lut_le_function), .reg2dp_lut_le_index_offset(reg2dp_lut_le_index_offset),
    .reg2dp_lut_le_index_select(reg2dp_lut_le_index_select),
    .reg2dp_lut_le_slope_oflow_scale(reg2dp_lut_le_slope_oflow_scale), .reg2dp_lut_le_slope_oflow_shift(reg2dp_lut_le_slope_oflow_shift),
    .reg2dp_lut_le_slope_uflow_scale(reg2dp_lut_le_slope_uflow_scale), .reg2dp_lut_le_slope_uflow_shift(reg2dp_lut_le_slope_uflow_shift),
    .reg2dp_lut_le_start_high(reg2dp_lut_le_start_high), .reg2dp_lut_le_start_low(reg2dp_lut_le_start_low),
    .reg2dp_lut_lo_end_high(reg2dp_lut_lo_end_high), .reg2dp_lut_lo_end_low(reg2dp_lut_lo_end_low),
    .reg2dp_lut_lo_index_select(reg2dp_lut_lo_index_select),
    .reg2dp_lut_lo_slope_oflow_scale(reg2dp_lut_lo_slope_oflow_scale), .reg2dp_lut_lo_slope_oflow_shift(reg2dp_lut_lo_slope_oflow_shift),
    .reg2dp_lut_lo_slope_uflow_scale(reg2dp_lut_lo_slope_uflow_scale), .reg2dp_lut_lo_slope_uflow_shift(reg2dp_lut_lo_slope_uflow_shift),
    .reg2dp_lut_lo_start_high(reg2dp_lut_lo_start_high), .reg2dp_lut_lo_start_low(reg2dp_lut_lo_start_low),
    .reg2dp_lut_oflow_priority(reg2dp_lut_oflow_priority), .reg2dp_lut_table_id(reg2dp_lut_table_id), .reg2dp_lut_uflow_priority(reg2dp_lut_uflow_priority),
    .reg2dp_mul_bypass(reg2dp_mul_bypass), .reg2dp_normalz_len(reg2dp_normalz_len), .reg2dp_sqsum_bypass(reg2dp_sqsum_bypass),
    .dp2reg_d0_out_saturation(d0_sat), .dp2reg_d0_perf_lut_hybrid(d0_hyb),
    .dp2reg_d0_perf_lut_le_hit(d0_le), .dp2reg_d0_perf_lut_lo_hit(d0_lo),
    .dp2reg_d0_perf_lut_oflow(d0_of), .dp2reg_d0_perf_lut_uflow(d0_uf),
    .dp2reg_d1_out_saturation(d1_sat), .dp2reg_d1_perf_lut_hybrid(d1_hyb),
    .dp2reg_d1_perf_lut_le_hit(d1_le), .dp2reg_d1_perf_lut_lo_hit(d1_lo),
    .dp2reg_d1_perf_lut_oflow(d1_of), .dp2reg_d1_perf_lut_uflow(d1_uf),
    .dp2reg_lut_data(dp2reg_lut_data)
  );

  // INT LUT reference helper
  function [27:0] ref_int_lut(input signed [37:0] v, input signed [37:0] st, input is_exp, input [7:0] off, input [7:0] sel, input i16, input [9:0] lim);
    reg [37:0] d;
    integer hi, k, idx_s, sh_s, sh_abs;
    reg [54:0] rsh;
    reg [31:0] lsh;
    begin
      if (v <= st) begin
        ref_int_lut = {1'b0, 1'b1, 16'd0, 10'd0};
      end else begin
        d = v - st;
        if (is_exp) begin
          hi = 0;
          for (k = 0; k < 38; k = k + 1) if (d[k]) hi = k;
          if ((~off[7]) && (hi < off[6:0])) begin
            ref_int_lut = {1'b0, 1'b1, 16'd0, 10'd0};
          end else begin
            idx_s = hi - $signed(off);
            rsh   = ({17'd0, d} << 16) >> hi;
            if (idx_s >= 64) ref_int_lut = {1'b1, 1'b0, (|d) ? rsh[15:0] : 16'd0, 10'd64};
            else             ref_int_lut = {1'b0, 1'b0, (|d) ? rsh[15:0] : 16'd0, idx_s[9:0]};
          end
        end else begin
          sh_s = i16 ? $signed({{25{sel[6]}}, sel[6:0]}) : $signed({{26{sel[5]}}, sel[5:0]});
          if (sh_s < 0) begin
            sh_abs = -sh_s;
            if (sh_abs >= 10) ref_int_lut = (|d) ? {1'b1, 1'b0, 16'd0, lim} : {1'b0, 1'b0, 16'd0, 10'd0};
            else begin
              lsh = d[9:0] << sh_abs;
              if ((|d[37:10]) || (lsh >= {22'd0, lim})) ref_int_lut = {1'b1, 1'b0, 16'd0, lim};
              else                                      ref_int_lut = {1'b0, 1'b0, 16'd0, lsh[9:0]};
            end
          end else begin
            rsh = (sh_s >= 55) ? 55'd0 : ({1'b0, d, 16'd0} >> sh_s);
            if (rsh[54:16] >= {29'd0, lim}) ref_int_lut = {1'b1, 1'b0, rsh[15:0], lim};
            else                            ref_int_lut = {1'b0, 1'b0, rsh[15:0], rsh[25:16]};
          end
        end
      end
    end
  endfunction

  reg [55:0] lc_int_exp_x [0:511];
  reg [55:0] lc_int_exp_y [0:511];
  integer lc_int_wr = 0, lc_int_rd = 0;
  always @(posedge clk) begin
    if (rstn && (~lc_fp16) && lc_vld && lc_in_rdy) begin
      reg signed [37:0] vl, vh, stl, sth, ytl, yth;
      reg [27:0] xl, xh, yl, yh;
      vl  = lc_i16 ? {lc_sqb & lc_din[36], lc_din[36:0]} : {{17{lc_sqb & lc_din[20]}}, lc_din[20:0]};
      vh  = lc_i8  ? {{16{1'b0}}, lc_sqb & lc_din[41], lc_din[41:21]} : 38'sd0;
      stl = {lc_le_sh, lc_le_sl};
      sth = {{16{stl[21]}}, stl[21:0]};
      ytl = {lc_lo_sh, lc_lo_sl};
      yth = {{16{ytl[21]}}, ytl[21:0]};
      xl  = ref_int_lut(vl, stl, ~lc_fn, lc_le_off, lc_le_sel, lc_i16, 10'd64);
      xh  = lc_i8 ? ref_int_lut({{16{vh[21]}}, vh[21:0]}, sth, ~lc_fn, lc_le_off, lc_le_sel, 1'b0, 10'd64) : {1'b0, 1'b1, 16'd0, 10'd0};
      yl  = ref_int_lut(vl, ytl, 1'b0, 8'd0, lc_lo_sel, lc_i16, 10'd256);
      yh  = lc_i8 ? ref_int_lut({{16{vh[21]}}, vh[21:0]}, yth, 1'b0, 8'd0, lc_lo_sel, 1'b0, 10'd256) : {1'b0, 1'b1, 16'd0, 10'd0};
      lc_int_exp_x[lc_int_wr] <= {xh[27], xl[27], xh[26], xl[26], xh[25:10], xl[25:10], xh[9:0], xl[9:0]};
      lc_int_exp_y[lc_int_wr] <= {yh[27], yl[27], yh[26], yl[26], yh[25:10], yl[25:10], yh[9:0], yl[9:0]};
      lc_int_wr <= lc_int_wr + 1;
    end
    if (rstn && (~lc_fp16) && lc_out_vld && lc_rdy_in) begin
      reg [27:0] gxl, exl, gyl, eyl, gxh, exh, gyh, eyh;
      gxl = {lc_xi[34], lc_xi[32], (lc_xi[34]|lc_xi[32]) ? 16'd0 : lc_xi[15:0], lc_xp[9:0]};
      exl = {lc_int_exp_x[lc_int_rd][54], lc_int_exp_x[lc_int_rd][52], (lc_int_exp_x[lc_int_rd][54]|lc_int_exp_x[lc_int_rd][52]) ? 16'd0 : lc_int_exp_x[lc_int_rd][35:20], lc_int_exp_x[lc_int_rd][9:0]};
      gyl = {lc_yi[34], lc_yi[32], (lc_yi[34]|lc_yi[32]) ? 16'd0 : lc_yi[15:0], lc_yp[9:0]};
      eyl = {lc_int_exp_y[lc_int_rd][54], lc_int_exp_y[lc_int_rd][52], (lc_int_exp_y[lc_int_rd][54]|lc_int_exp_y[lc_int_rd][52]) ? 16'd0 : lc_int_exp_y[lc_int_rd][35:20], lc_int_exp_y[lc_int_rd][9:0]};
      gxh = lc_i8 ? {lc_xi[35], lc_xi[33], (lc_xi[35]|lc_xi[33]) ? 16'd0 : lc_xi[31:16], lc_xp[19:10]} : 28'd0;
      exh = lc_i8 ? {lc_int_exp_x[lc_int_rd][55], lc_int_exp_x[lc_int_rd][53], (lc_int_exp_x[lc_int_rd][55]|lc_int_exp_x[lc_int_rd][53]) ? 16'd0 : lc_int_exp_x[lc_int_rd][51:36], lc_int_exp_x[lc_int_rd][19:10]} : 28'd0;
      gyh = lc_i8 ? {lc_yi[35], lc_yi[33], (lc_yi[35]|lc_yi[33]) ? 16'd0 : lc_yi[31:16], lc_yp[19:10]} : 28'd0;
      eyh = lc_i8 ? {lc_int_exp_y[lc_int_rd][55], lc_int_exp_y[lc_int_rd][53], (lc_int_exp_y[lc_int_rd][55]|lc_int_exp_y[lc_int_rd][53]) ? 16'd0 : lc_int_exp_y[lc_int_rd][51:36], lc_int_exp_y[lc_int_rd][19:10]} : 28'd0;
      if (gxl !== exl || gyl !== eyl || gxh !== exh || gyh !== eyh) begin
        if (err_cnt < 10)
          $display("ERR lc_int[%0d]: gxl=%h exl=%h gxh=%h exh=%h gyl=%h eyl=%h gyh=%h eyh=%h",
            lc_int_rd, gxl, exl, gxh, exh, gyl, eyl, gyh, eyh);
        err_cnt = err_cnt + 1;
      end
      lc_int_rd <= lc_int_rd + 1;
    end
  end

  reg bp_en = 0;
  reg [31:0] bp_lfsr = 32'h12345678;
  always @(posedge clk) begin
    if (!rstn) begin
      cdp_dp2wdma_ready <= 1'b1; bp_lfsr <= seed ^ 32'h5a5aa5a5;
      itp_rdy_in <= 1'b1; lc_rdy_in <= 1'b1;
    end else begin
      bp_lfsr <= {bp_lfsr[30:0], bp_lfsr[31] ^ bp_lfsr[21] ^ bp_lfsr[1] ^ bp_lfsr[0]};
      cdp_dp2wdma_ready <= bp_en ? (bp_lfsr[2:0] != 3'b000) : 1'b1;
      itp_rdy_in <= (bp_lfsr[7:6] != 2'b00);
      lc_rdy_in  <= (bp_lfsr[9:8] != 2'b00);
    end
  end

  task write_lut(input tbl, input [9:0] addr, input [15:0] val);
    begin
      @(posedge clk);
      reg2dp_lut_table_id <= tbl; reg2dp_lut_access_type <= 1'b1;
      reg2dp_lut_addr <= addr; reg2dp_lut_data <= val; reg2dp_lut_data_trigger <= 1'b1;
      @(posedge clk);
      reg2dp_lut_data_trigger <= 1'b0; reg2dp_lut_access_type <= 1'b0;
    end
  endtask

  task send_pkt(input [63:0] dat, input [3:0] pw, input [3:0] w, input [2:0] pc, input bsync, input lw, input lh, input lc);
    begin
      while ((bp_lfsr[4:3] == 2'b11) && bp_en) begin cdp_rdma2dp_valid <= 1'b0; @(posedge clk); end
      cdp_rdma2dp_valid <= 1'b1;
      cdp_rdma2dp_pd <= {8'h00, lc, lh, lw, bsync, pc, w, pw, dat};
      @(posedge clk);
      while (!cdp_rdma2dp_ready) @(posedge clk);
      cdp_rdma2dp_valid <= 1'b0;
    end
  endtask

  reg [63:0] out_hash;
  integer out_cnt;
  always @(posedge clk) begin
    if (!rstn) begin out_hash <= 64'hcbf29ce484222325; out_cnt <= 0; end
    else if (cdp_dp2wdma_valid && cdp_dp2wdma_ready) begin
      out_hash <= ((out_hash ^ cdp_dp2wdma_pd[63:0]) * 64'h100000001b3) ^ {49'd0, cdp_dp2wdma_pd[78:64]};
      out_cnt  <= out_cnt + 1;
    end
  end

  task check_cube(input [31:0] id, input integer exp_cnt, input [63:0] exp_hash,
                  input [31:0] got_le, input [31:0] got_lo, input [31:0] got_of, input [31:0] got_uf, input [31:0] got_hyb,
                  input [31:0] e_le, input [31:0] e_lo, input [31:0] e_of, input [31:0] e_uf, input [31:0] e_hyb);
    begin
      if (out_cnt !== exp_cnt || out_hash !== exp_hash ||
          got_le !== e_le || got_lo !== e_lo || got_of !== e_of || got_uf !== e_uf || got_hyb !== e_hyb) begin
        $display("ERR cube %0d: cnt=%0d(exp %0d) hash=%h(exp %h) pf=%0d,%0d,%0d,%0d,%0d(exp %0d,%0d,%0d,%0d,%0d)",
          id, out_cnt, exp_cnt, out_hash, exp_hash, got_le, got_lo, got_of, got_uf, got_hyb, e_le, e_lo, e_of, e_uf, e_hyb);
        err_cnt = err_cnt + 1;
      end
    end
  endtask

  task wait_beats(input integer target);
    integer guard;
    begin
      guard = 0;
      while (out_cnt < target && guard < 5000) begin @(posedge clk); guard = guard + 1; end
      repeat (24) @(posedge clk);
      dp2reg_done <= 1'b1; @(posedge clk); dp2reg_done <= 1'b0; repeat (4) @(posedge clk);
    end
  endtask

  integer i, c, w, rng;
  reg [31:0] r0, r1, r2, r3, r4, r5, r6;
  initial begin
    if ($value$plusargs("seed=%d", seed)) ;
    rng = $urandom(seed);
    isb_i8 = 1; isb_ld1 = 0; isb_ld2 = 0; isb_len = 0;
    for (i = 0; i < 9; i = i + 1) begin isb_s16[i] = 0; isb_s8l[i] = 0; isb_s8m[i] = 0; end
    itp_fp16 = 0; itp_vld = 0; itp_in0 = 0; itp_in1 = 0; itp_base = 0; itp_scale = 0; itp_shift = 0;
    lc_fp16 = 0; lc_i16 = 0; lc_i8 = 1; lc_fn = 0; lc_sqb = 0; lc_vld = 0;
    lc_le_off = 0; lc_le_sel = 0; lc_lo_sel = 0; lc_le_sh = 0; lc_lo_sh = 0; lc_le_sl = 0; lc_lo_sl = 0; lc_din = 0;
    cdp_rdma2dp_valid = 0; cdp_rdma2dp_pd = 0; dp2reg_done = 0;
    reg2dp_datin_offset = 16'd5; reg2dp_datin_scale = 16'd3; reg2dp_datin_shifter = 5'd1;
    reg2dp_datout_offset = 32'sd12; reg2dp_datout_scale = 16'd5; reg2dp_datout_shifter = 6'd8;
    reg2dp_input_data_type = 2'd0; reg2dp_lut_access_type = 0; reg2dp_lut_addr = 0; reg2dp_lut_data = 0; reg2dp_lut_data_trigger = 0;
    reg2dp_lut_hybrid_priority = 0; reg2dp_lut_oflow_priority = 0; reg2dp_lut_uflow_priority = 1; reg2dp_lut_table_id = 0;
    reg2dp_lut_le_start_high = 0; reg2dp_lut_le_start_low = 32'd64; reg2dp_lut_le_end_high = 0; reg2dp_lut_le_end_low = 32'd16448;
    reg2dp_lut_lo_start_high = 0; reg2dp_lut_lo_start_low = 32'd128; reg2dp_lut_lo_end_high = 0; reg2dp_lut_lo_end_low = 32'd32896;
    reg2dp_lut_le_function = 0; reg2dp_lut_le_index_offset = 8'd3; reg2dp_lut_le_index_select = 8'd4; reg2dp_lut_lo_index_select = 8'd6;
    reg2dp_lut_le_slope_oflow_scale = 16'd29; reg2dp_lut_le_slope_oflow_shift = 5'd5;
    reg2dp_lut_le_slope_uflow_scale = 16'hffd4; reg2dp_lut_le_slope_uflow_shift = 5'd4;
    reg2dp_lut_lo_slope_oflow_scale = 16'd21; reg2dp_lut_lo_slope_oflow_shift = 5'd5;
    reg2dp_lut_lo_slope_uflow_scale = 16'hffe2; reg2dp_lut_lo_slope_uflow_shift = 5'd4;
    reg2dp_mul_bypass = 0; reg2dp_normalz_len = 2'd0; reg2dp_sqsum_bypass = 0;

    repeat (8) @(posedge clk);
    rstn = 1'b1;
    repeat (6) @(posedge clk);

    // --- Drive Part A1 (int_sum_block: 480 random beats across configs & stalls) ---
    for (c = 0; c < 8; c = c + 1) begin
      isb_i8 <= c[0]; isb_len <= c[2:1];
      isb_ld1 <= 1'b0; isb_ld2 <= 1'b1;
      repeat (3) @(posedge clk);
      isb_ld2 <= 1'b0;
      for (i = 0; i < 60; i = i + 1) begin
        while (bp_lfsr[5:4] == 2'b11) begin
          isb_ld1 <= 1'b0; isb_ld2 <= 1'b0;
          @(posedge clk);
        end
        for (w = 0; w < 9; w = w + 1) begin
          r0 = $urandom; r1 = $urandom;
          isb_s16[w] <= {r1[0], r0};
          isb_s8l[w] <= r0[16:0];
          isb_s8m[w] <= r1[17:1];
        end
        isb_ld1 <= 1'b1; isb_ld2 <= 1'b1;
        @(posedge clk);
        isb_ld1 <= 1'b0; isb_ld2 <= 1'b0;
      end
      isb_ld1 <= 1'b0; isb_ld2 <= 1'b1;
      repeat (2) @(posedge clk);
      isb_ld2 <= 1'b0;
      @(posedge clk);
    end

    // --- Drive Part A2 (INTP_unit INT: directed half-way + 450 random beats) ---
    for (i = 0; i < 460; i = i + 1) begin
      r0 = $urandom; r1 = $urandom; r2 = $urandom; r3 = $urandom;
      if (i == 0) begin itp_in0 <= 39'd10; itp_in1 <= 38'd11; itp_base <= 17'd100; itp_scale <= 17'd1; itp_shift <= 6'd1; end
      else if (i == 1) begin itp_in0 <= 39'd11; itp_in1 <= 38'd10; itp_base <= 17'd100; itp_scale <= 17'd1; itp_shift <= 6'd1; end
      else if (i == 2) begin itp_in0 <= 39'd10; itp_in1 <= 38'd13; itp_base <= -17'sd50; itp_scale <= -17'sd1; itp_shift <= 6'd1; end
      else if (i == 3) begin itp_in0 <= 39'd0;  itp_in1 <= 38'h1f_ffff_ffff; itp_base <= 17'sd30000; itp_scale <= 17'sd20000; itp_shift <= 6'h34; end
      else if (i == 4) begin itp_in0 <= 39'd15; itp_in1 <= 38'd10; itp_base <= 17'd100; itp_scale <= 17'd1; itp_shift <= 6'd2; end
      else if (i == 5) begin itp_in0 <= 39'd16; itp_in1 <= 38'd10; itp_base <= 17'd100; itp_scale <= 17'd1; itp_shift <= 6'd2; end
      else begin
        itp_in0   <= (i[1:0]!=2'd3) ? {{27{r0[11]}}, r0[11:0]} : {r1[6:0], r0};
        itp_in1   <= (i[1:0]!=2'd3) ? {{26{r1[11]}}, r1[11:0]} : {r2[5:0], r1};
        itp_base  <= r2[22:6];
        itp_scale <= (i[1:0]!=2'd3) ? {{9{r3[7]}}, r3[7:0]} : r3[16:0];
        itp_shift <= $signed((r3[24:17] % 33) - 16);
      end
      while (bp_lfsr[11:10] == 2'b11) begin itp_vld <= 1'b0; @(posedge clk); end
      itp_vld <= 1'b1;
      @(posedge clk);
      while (!itp_in_rdy) @(posedge clk);
    end
    itp_vld <= 1'b0;
    repeat (32) @(posedge clk);

    // --- Drive Part A3 (LUT_CTRL_unit INT & FP32 including IEEE-754 +Inf overflow) ---
    for (c = 0; c < 8; c = c + 1) begin
      lc_fp16 <= 1'b0; lc_i16 <= c[0]; lc_i8 <= ~c[0]; lc_fn <= c[1]; lc_sqb <= c[2];
      lc_le_off <= (c[1] ? 8'd0 : (c[2] ? 8'hfd : 8'd4));
      lc_le_sel <= (c[2] ? 8'hfe : 8'd5);
      lc_lo_sel <= (c[0] ? 8'd8 : 8'hfd);
      lc_le_sh <= (c[2] ? 6'h3f : 6'h00); lc_le_sl <= (c[2] ? -32'sd64 : 32'd32);
      lc_lo_sh <= 6'h00; lc_lo_sl <= 32'd64;
      repeat (4) @(posedge clk);
      for (i = 0; i < 32; i = i + 1) begin
        r0 = $urandom; r1 = $urandom;
        lc_din <= {r1[9:0], r0};
        lc_vld <= 1'b1;
        @(posedge clk);
        while (!lc_in_rdy) @(posedge clk);
      end
      lc_vld <= 1'b0;
      repeat (10) @(posedge clk);
    end

    for (c = 0; c < 4; c = c + 1) begin
      lc_fp16 <= 1'b1; lc_i16 <= 1'b0; lc_i8 <= 1'b0; lc_fn <= c[0]; lc_sqb <= 1'b0;
      lc_le_off <= c[1] ? 8'hfc : 8'd3;
      lc_le_sel <= c[1] ? 8'hfd : 8'd4;
      lc_lo_sel <= c[1] ? 8'hfc : 8'd5;
      lc_le_sh <= 6'd0; lc_lo_sh <= 6'd0;
      lc_le_sl <= (c >= 2) ? 32'hff400000 : 32'h3f800000;
      lc_lo_sl <= (c >= 2) ? 32'hff200000 : 32'h40000000;
      repeat (4) @(posedge clk);
      for (i = 0; i < 40; i = i + 1) begin
        r0 = $urandom;
        if      (i == 0) lc_din <= {10'd0, 32'h7f400000}; // finite - (-2.55e38) => +Inf overflow!
        else if (i == 1) lc_din <= {10'd0, 32'h7f800000}; // +Inf input
        else if (i == 2) lc_din <= {10'd0, 32'hff800000}; // -Inf input
        else if (i == 3) lc_din <= {10'd0, 32'h7fc00001}; // quiet NaN
        else if (i == 4) lc_din <= {10'd0, 32'h80000000}; // -0.0
        else if (i == 5) lc_din <= {10'd0, 32'h00400000}; // subnormal
        else             lc_din <= {10'd0, 1'b0, (r0[30:23] == 8'hff) ? 8'h8e : r0[30:23], r0[22:0]};
        lc_vld <= 1'b1;
        @(posedge clk);
        while (!lc_in_rdy) @(posedge clk);
      end
      lc_vld <= 1'b0;
      repeat (16) @(posedge clk);
    end

    if (isb_rd !== 480 || itp_rd !== 460 || lc_int_rd !== 256 || lc_fp_rd !== 160) begin
      $display("ERR unit drain counts: isb=%0d itp=%0d lc_int=%0d lc_fp=%0d", isb_rd, itp_rd, lc_int_rd, lc_fp_rd);
      err_cnt = err_cnt + 1;
    end

    // --- Drive Part B (Full NV_NVDLA_CDP_dp 6-Cube Subsystem Streaming) ---
    for (i = 0; i <= 64; i = i + 1)  write_lut(1'b0, i[9:0], $signed(16'sh0300) + $signed(i[15:0] * 16'sd37) - $signed({9'd0, i[6:0]} * 16'sd11));
    for (i = 0; i <= 256; i = i + 1) write_lut(1'b1, i[9:0], $signed(16'shfe80) + $signed(i[15:0] * 16'sd13));
    bp_en = 1;

    for (c = 0; c < 4; c = c + 1)
      for (w = 0; w < 2; w = w + 1)
        send_pkt(64'h9bc3_127e_f450_3a8d ^ ({32'd0, c[3:0], w[3:0], 24'h55aa11} * 64'h9e3779b9), w[3:0], 4'd2, c[2:0], (w==1), (w==1), 1'b1, (c==3));
    wait_beats(8);
    check_cube(1, 8, 64'h7f82a59ff3799cb5, d0_le, d0_lo, d0_of, d0_uf, d0_hyb, 32'd58, 32'd0, 32'd0, 32'd0, 32'd6);

    reg2dp_normalz_len = 2'd2; reg2dp_lut_le_function = 1'b1; reg2dp_lut_hybrid_priority = 1'b1;
    reg2dp_lut_le_index_select = 8'd5; reg2dp_lut_lo_index_select = 8'd7;
    repeat (4) @(posedge clk);
    for (c = 0; c < 4; c = c + 1)
      for (w = 0; w < 2; w = w + 1)
        send_pkt(64'h7f80_05e1_29a4_c01b ^ ({28'd0, w[3:0], c[3:0], 28'h13579bd} * 64'h85ebca6b), w[3:0], 4'd2, c[2:0], (w==1), (w==1), 1'b1, (c==3));
    wait_beats(16);
    check_cube(2, 16, 64'h11bce7987be63a85, d1_le, d1_lo, d1_of, d1_uf, d1_hyb, 32'd0, 32'd2, 32'd62, 32'd0, 32'd0);

    reg2dp_input_data_type = 2'd1; reg2dp_normalz_len = 2'd3; reg2dp_lut_le_function = 1'b0;
    reg2dp_lut_le_index_offset = 8'd8; reg2dp_lut_lo_index_select = 8'd14;
    reg2dp_lut_le_start_low = 32'd1024; reg2dp_lut_le_end_low = 32'h0400_0000;
    reg2dp_lut_lo_start_low = 32'd2048; reg2dp_lut_lo_end_low = 32'h0800_0000;
    reg2dp_datout_shifter = 6'd14;
    repeat (4) @(posedge clk);
    for (c = 0; c < 4; c = c + 1)
      for (w = 0; w < 2; w = w + 1)
        send_pkt({16'sh1234 + c*16'sd701, -16'sh0abc + w*16'sd333, 16'sh3100 - c*16'sd511, 16'sh0095 + w*16'sd99}, w[3:0], 4'd2, c[2:0], (w==1), (w==1), 1'b1, (c==3));
    wait_beats(24);
    check_cube(3, 24, 64'h308e8632a3405c8e, d0_le, d0_lo, d0_of, d0_uf, d0_hyb, 32'd32, 32'd8, 32'd24, 32'd0, 32'd0);

    reg2dp_sqsum_bypass = 1'b1; reg2dp_lut_le_function = 1'b1;
    reg2dp_lut_le_start_high = 6'h3f; reg2dp_lut_le_start_low = -32'sd2048;
    reg2dp_lut_le_end_high   = 6'h00; reg2dp_lut_le_end_low   = 32'sd6144;
    reg2dp_lut_lo_start_high = 6'h3f; reg2dp_lut_lo_start_low = -32'sd4096;
    reg2dp_lut_lo_end_high   = 6'h00; reg2dp_lut_lo_end_low   = 32'sd12288;
    reg2dp_lut_le_index_select = 8'd7; reg2dp_lut_lo_index_select = 8'd6;
    repeat (4) @(posedge clk);
    for (c = 0; c < 4; c = c + 1)
      for (w = 0; w < 2; w = w + 1)
        send_pkt({-16'sd1500 + c*16'sd900, 16'sd3200 - w*16'sd1100, -16'sd4800 + c*16'sd600, 16'sd700 + w*16'sd400}, w[3:0], 4'd2, c[2:0], (w==1), (w==1), 1'b1, (c==3));
    wait_beats(32);
    check_cube(4, 32, 64'h4a70818dedd537be, d1_le, d1_lo, d1_of, d1_uf, d1_hyb, 32'd0, 32'd8, 32'd24, 32'd8, 32'd24);

    reg2dp_sqsum_bypass = 1'b0; reg2dp_input_data_type = 2'd2; reg2dp_normalz_len = 2'd1; reg2dp_lut_le_function = 1'b0;
    reg2dp_lut_le_start_high = 0; reg2dp_lut_le_start_low = 32'h3f800000; reg2dp_lut_le_end_low = 32'h46800000;
    reg2dp_lut_lo_start_high = 0; reg2dp_lut_lo_start_low = 32'h40000000; reg2dp_lut_lo_end_low = 32'h47000000;
    reg2dp_lut_le_index_offset = 8'hfe; reg2dp_lut_lo_index_select = 8'd2;
    reg2dp_lut_le_slope_oflow_scale = 16'h3400; reg2dp_lut_lo_slope_oflow_scale = 16'h3400;
    reg2dp_lut_le_slope_uflow_scale = 16'hb400; reg2dp_lut_lo_slope_uflow_scale = 16'hb400;
    for (i = 0; i <= 64; i = i + 1)  write_lut(1'b0, i[9:0], 16'h3c00 + (i[15:0] << 3));
    for (i = 0; i <= 256; i = i + 1) write_lut(1'b1, i[9:0], 16'h3800 + (i[15:0] << 2));
    repeat (6) @(posedge clk);
    for (c = 0; c < 4; c = c + 1)
      for (w = 0; w < 2; w = w + 1)
        send_pkt({16'h4900 + (c[15:0]<<7), 16'hc400 + (w[15:0]<<8), 16'h3555 + (c[15:0]<<6), 16'h3c00 + (w[15:0]<<5)}, w[3:0], 4'd2, c[2:0], (w==1), (w==1), 1'b1, (c==3));
    wait_beats(40);
    check_cube(5, 40, 64'h0beaf6d33cbcf1b8, d0_le, d0_lo, d0_of, d0_uf, d0_hyb, 32'd0, 32'd0, 32'd0, 32'd0, 32'd64);

    reg2dp_normalz_len = 2'd0; reg2dp_lut_le_function = 1'b1; reg2dp_lut_le_index_select = 8'd3;
    repeat (6) @(posedge clk);
    for (c = 0; c < 4; c = c + 1)
      for (w = 0; w < 2; w = w + 1)
        send_pkt({16'h4600 + (w[15:0]<<7), 16'h4200 + (c[15:0]<<6), 16'hc100, 16'h3a00 + (c[15:0]<<5)}, w[3:0], 4'd2, c[2:0], (w==1), (w==1), 1'b1, (c==3));
    wait_beats(48);
    check_cube(6, 48, 64'h7d32b9522088a59c, d1_le, d1_lo, d1_of, d1_uf, d1_hyb, 32'd0, 32'd0, 32'd0, 32'd0, 32'd64);

    if (err_cnt == 0)
      $display("TEST_PASS seed=%0d beats=%0d", seed, out_cnt);
    else
      $display("TEST_FAIL seed=%0d errors=%0d", seed, err_cnt);
    $finish;
  end
endmodule
