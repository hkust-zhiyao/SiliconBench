`timescale 1ns/1ps

module tb_gls;
  reg clk = 1'b0;
  always #2.0 clk = ~clk;
  reg rstn = 1'b0;
  integer errs = 0;

  // 1) int_sum_block gate-level instance
  reg         isb_i8, isb_l5, isb_l7, isb_l9, isb_ld1, isb_ld2;
  reg   [1:0] isb_len;
  reg  [32:0] s16_c;
  reg  [16:0] s8l_c, s8m_c;
  wire [36:0] isb_o16;
  wire [41:0] isb_o8;

  int_sum_block u_gls_isb (
    .nvdla_core_clk(clk), .nvdla_core_rstn(rstn), .int8_en(isb_i8),
    .len5(isb_l5), .len7(isb_l7), .len9(isb_l9),
    .load_din_d(isb_ld1), .load_din_2d(isb_ld2), .reg2dp_normalz_len(isb_len),
    .sq_pd_int16_0(s16_c), .sq_pd_int16_1(s16_c), .sq_pd_int16_2(s16_c),
    .sq_pd_int16_3(s16_c), .sq_pd_int16_4(s16_c), .sq_pd_int16_5(s16_c),
    .sq_pd_int16_6(s16_c), .sq_pd_int16_7(s16_c), .sq_pd_int16_8(s16_c),
    .sq_pd_int8_lsb_0(s8l_c), .sq_pd_int8_lsb_1(s8l_c), .sq_pd_int8_lsb_2(s8l_c),
    .sq_pd_int8_lsb_3(s8l_c), .sq_pd_int8_lsb_4(s8l_c), .sq_pd_int8_lsb_5(s8l_c),
    .sq_pd_int8_lsb_6(s8l_c), .sq_pd_int8_lsb_7(s8l_c), .sq_pd_int8_lsb_8(s8l_c),
    .sq_pd_int8_msb_0(s8m_c), .sq_pd_int8_msb_1(s8m_c), .sq_pd_int8_msb_2(s8m_c),
    .sq_pd_int8_msb_3(s8m_c), .sq_pd_int8_msb_4(s8m_c), .sq_pd_int8_msb_5(s8m_c),
    .sq_pd_int8_msb_6(s8m_c), .sq_pd_int8_msb_7(s8m_c), .sq_pd_int8_msb_8(s8m_c),
    .int16_sum(isb_o16), .int8_sum(isb_o8)
  );

  // 2) NV_NVDLA_CDP_DP_LUT_CTRL_unit gate-level instance
  reg         lc_prdy, lc_fp16, lc_i16, lc_i8, lc_fn, lc_sqb, lc_pvld;
  reg   [7:0] lc_off, lc_les, lc_los;
  reg   [5:0] lc_leh, lc_loh;
  reg  [31:0] lc_lel, lc_lol;
  reg  [41:0] lc_pd;
  wire [35:0] lc_xi, lc_yi;
  wire [19:0] lc_xp, lc_yp;
  wire        lc_ovld, lc_irdy;

  NV_NVDLA_CDP_DP_LUT_CTRL_unit u_gls_lc (
    .nvdla_core_clk(clk), .nvdla_op_gated_clk_fp16(clk), .nvdla_op_gated_clk_int(clk), .nvdla_core_rstn(rstn),
    .dp2lut_prdy(lc_prdy), .fp16_en(lc_fp16), .int16_en(lc_i16), .int8_en(lc_i8),
    .reg2dp_lut_le_function(lc_fn), .reg2dp_lut_le_index_offset(lc_off), .reg2dp_lut_le_index_select(lc_les),
    .reg2dp_lut_le_start_high(lc_leh), .reg2dp_lut_le_start_low(lc_lel),
    .reg2dp_lut_lo_index_select(lc_los), .reg2dp_lut_lo_start_high(lc_loh), .reg2dp_lut_lo_start_low(lc_lol),
    .reg2dp_sqsum_bypass(lc_sqb), .sum2itp_pd(lc_pd), .sum2itp_pvld(lc_pvld),
    .dp2lut_X_info(lc_xi), .dp2lut_X_pd(lc_xp), .dp2lut_Y_info(lc_yi), .dp2lut_Y_pd(lc_yp),
    .dp2lut_pvld(lc_ovld), .sum2itp_prdy(lc_irdy)
  );

  // 3) NV_NVDLA_CDP_DP_INTP_unit gate-level instance
  reg         it_fp16, it_vld, it_ordy;
  reg  [38:0] it_i0;
  reg  [37:0] it_i1;
  reg  [16:0] it_ipd, it_isc;
  reg   [5:0] it_ish;
  wire        it_irdy, it_ovld;
  wire [16:0] it_opd;

  NV_NVDLA_CDP_DP_INTP_unit u_gls_itp (
    .nvdla_op_gated_clk_int(clk), .nvdla_op_gated_clk_fp16(clk), .nvdla_core_rstn(rstn),
    .fp16_en(it_fp16), .interp_in0_pd(it_i0), .interp_in1_pd(it_i1),
    .interp_in_pd(it_ipd), .interp_in_scale(it_isc), .interp_in_shift(it_ish),
    .interp_in_vld(it_vld), .interp_out_rdy(it_ordy),
    .interp_in_rdy(it_irdy), .interp_out_pd(it_opd), .interp_out_vld(it_ovld)
  );

  integer g;
  initial begin
    // Drive X on data buses while in reset to verify clean 4-state reset hygiene
    isb_i8 = 1'b0; isb_l5 = 1'b1; isb_l7 = 1'b0; isb_l9 = 1'b0; isb_ld1 = 1'b0; isb_ld2 = 1'b0; isb_len = 2'd1;
    s16_c = 33'hx; s8l_c = 17'hx; s8m_c = 17'hx;
    lc_prdy = 1'b1; lc_fp16 = 1'b1; lc_i16 = 1'b0; lc_i8 = 1'b0; lc_fn = 1'b0; lc_sqb = 1'b0; lc_pvld = 1'b0;
    lc_off = 8'd0; lc_les = 8'd0; lc_los = 8'd0; lc_leh = 6'd0; lc_loh = 6'd0; lc_lel = 32'hff400000; lc_lol = 32'hff400000; lc_pd = 42'hx;
    it_fp16 = 1'b0; it_vld = 1'b0; it_ordy = 1'b1; it_i0 = 39'hx; it_i1 = 38'hx; it_ipd = 17'hx; it_isc = 17'hx; it_ish = 6'hx;

    repeat (5) @(posedge clk);
    rstn = 1'b1;
    @(posedge clk); #0.2;
    if ((^isb_o16 === 1'bx) || (lc_ovld !== 1'b0) || (lc_irdy !== 1'b1) || (it_ovld !== 1'b0) || (it_irdy !== 1'b1)) begin
      $display("GLS_ERR post-reset X/control state: isb=%h lc_ovld=%b lc_irdy=%b it_ovld=%b it_irdy=%b", isb_o16, lc_ovld, lc_irdy, it_ovld, it_irdy);
      errs = errs + 1;
    end

    // Check 1: int_sum_block L=5 with 5*7 = 35
    s16_c = 33'd7; s8l_c = 17'd3; s8m_c = 17'd5;
    isb_ld1 = 1'b1; isb_ld2 = 1'b1;
    repeat (3) @(posedge clk); #0.2;
    if (isb_o16 !== 37'd35) begin
      $display("GLS_ERR isb L=5: got=%0d exp=35", isb_o16);
      errs = errs + 1;
    end

    // Check 2: INTP_unit negative half-way rounding (-5 >> 1 => -3 + 100 = 97)
    it_i0 = 39'd15; it_i1 = 38'd10; it_ipd = 17'd100; it_isc = 17'd1; it_ish = 6'd1; it_vld = 1'b1;
    @(posedge clk); it_vld = 1'b0;
    g = 0; while (it_ovld !== 1'b1 && g < 20) begin @(posedge clk); #0.2; g = g + 1; end
    if (it_ovld !== 1'b1 || it_opd !== 17'd97 || (^it_opd === 1'bx)) begin
      $display("GLS_ERR itp: vld=%b opd=%h", it_ovld, it_opd);
      errs = errs + 1;
    end

    // Check 3: LUT_CTRL_unit FP32 +Inf overflow (0x7f800000 - 0x3f800000 => +Inf => X_pd=64, Y_pd=256, oflow=1)
    lc_lel = 32'h3f800000; lc_lol = 32'h40000000;
    @(posedge clk);
    lc_pd = {10'd0, 32'h7f800000}; lc_pvld = 1'b1;
    @(posedge clk); lc_pvld = 1'b0;
    g = 0; while (lc_ovld !== 1'b1 && g < 30) begin @(posedge clk); #0.2; g = g + 1; end
    if (lc_ovld !== 1'b1 || lc_xp !== 20'd64 || lc_yp !== 20'd256 || lc_xi[34] !== 1'b1 || lc_yi[34] !== 1'b1 || (^lc_xp === 1'bx) || (^lc_yp === 1'bx)) begin
      $display("GLS_ERR lc +Inf: ovld=%b xp=%h xi=%h yp=%h yi=%h", lc_ovld, lc_xp, lc_xi, lc_yp, lc_yi);
      errs = errs + 1;
    end

    if (errs == 0) $display("GLS_PASS");
    else           $display("GLS_FAIL errs=%0d", errs);
    $finish;
  end
endmodule
