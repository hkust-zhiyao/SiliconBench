// Copyright (C) 2019-2021 ETH Zurich, University of Bologna and GreenWaves Technologies
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

import neureka_package::*;

module neureka_normquant #(
  parameter int unsigned NMULT = 4,
  parameter int unsigned NMS = neureka_package::NORM_MULT_SIZE,
  parameter int unsigned ACC = neureka_package::NEUREKA_ACCUM_SIZE,
  parameter int unsigned INT = 48,
  parameter int unsigned QNT = 32,
  parameter int unsigned PIPE = 1,
  parameter int unsigned OUTPUT_REGISTER = 0
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          test_mode_i,
  input  logic                          clear_i,
  input  logic unsigned [NMULT*NMS-1:0] norm_mult_i,
  input  logic unsigned [NMULT*8-1:0]   shift_i,
  input  logic signed   [NMULT*ACC-1:0] accumulator_i,
  output logic signed   [NMULT*ACC-1:0] accumulator_o,
  input  neureka_package::ctrl_normquant_t  ctrl_i,
  output neureka_package::flags_normquant_t [NMULT-1:0] flags_o
);

  logic signed [NMULT-1:0][NMS+ACC-1:0] product;
  logic signed [NMULT-1:0][INT-1:0]     product_to_shift;

  for (genvar ii = 0; ii < NMULT; ii++) begin : mult_gen
    localparam int unsigned ii_div2 = ii / 2;
    logic sign_bit;
    logic signed [NMS:0] norm_mult_signed;
    logic [ACC-1:0]      accumulator_selected;

    assign accumulator_selected = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? accumulator_i[(ii+1)*32-1:ii*32] :
                                  (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? accumulator_i[(ii_div2+1)*32-1:ii_div2*32] :
                                  (ctrl_i.norm_mode == NEUREKA_MODE_32B) ? accumulator_i[31:0] : '0;

    assign sign_bit = (ctrl_i.norm_mode == NEUREKA_MODE_8B)                      ? norm_mult_i[(ii+1)*NMS-1] :
                      ((ctrl_i.norm_mode == NEUREKA_MODE_16B) && (ii % 2 == 1))  ? norm_mult_i[(ii+1)*NMS-1] :
                      ((ctrl_i.norm_mode == NEUREKA_MODE_32B) && (ii == 3))      ? norm_mult_i[NMULT*NMS-1]  : 1'b0;

    assign norm_mult_signed = {ctrl_i.norm_signed & sign_bit, norm_mult_i[(ii+1)*NMS-1:ii*NMS]};
    assign flags_o[ii].ready = 1'b1;

    neureka_normquant_multiplier #(
      .NMS  ( NMS  ),
      .ACC  ( ACC  ),
      .PIPE ( PIPE )
    ) i_multiplier (
      .clk_i              ( clk_i                ),
      .rst_ni             ( rst_ni               ),
      .test_mode_i        ( test_mode_i          ),
      .clear_i            ( clear_i              ),
      .enable_i           ( ctrl_i.start         ),
      .norm_mult_signed_i ( norm_mult_signed     ),
      .accumulator_i      ( accumulator_selected ),
      .product_o          ( product[ii]          )
    );
  end

  wire signed [39:0] p0_s = product[0];
  wire signed [39:0] p1_s = product[1];
  wire signed [39:0] p2_s = product[2];
  wire signed [39:0] p3_s = product[3];

  wire signed [39:0] pair0_hi  = $signed({{8{p0_s[39]}}, p0_s[39:8]}) + p1_s;
  wire signed [39:0] pair1_hi  = $signed({{8{p2_s[39]}}, p2_s[39:8]}) + p3_s;
  wire signed [47:0] pair0_sum = {pair0_hi, p0_s[7:0]};
  wire signed [47:0] pair1_sum = {pair1_hi, p2_s[7:0]};
  wire signed [31:0] quad_hi   = pair0_sum[47:16] + pair1_sum[31:0];
  wire signed [47:0] quad_sum  = {quad_hi, pair0_sum[15:0]};

  assign product_to_shift[0] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p0_s[39]}}, p0_s} :
                               (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? pair0_sum :
                               (ctrl_i.norm_mode == NEUREKA_MODE_32B) ? quad_sum  : '0;
  assign product_to_shift[1] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p1_s[39]}}, p1_s} :
                               (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? pair1_sum : '0;
  assign product_to_shift[2] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p2_s[39]}}, p2_s} : '0;
  assign product_to_shift[3] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p3_s[39]}}, p3_s} : '0;

  for (genvar ii = 0; ii < NMULT; ii++) begin : shift_sat_gen
    localparam int unsigned LANE_INT = (ii < 2) ? 48 : 40;
    logic [31:0] accumulator_loc;
    neureka_normquant_shifter #(
      .ACC             ( ACC             ),
      .INT             ( LANE_INT        ),
      .OUTPUT_REGISTER ( OUTPUT_REGISTER )
    ) i_shifter (
      .clk_i         ( clk_i                              ),
      .rst_ni        ( rst_ni                             ),
      .test_mode_i   ( test_mode_i                        ),
      .clear_i       ( clear_i                            ),
      .data_i        ( product_to_shift[ii][LANE_INT-1:0] ),
      .shift_i       ( shift_i[(ii+1)*8-1:ii*8]           ),
      .accumulator_o ( accumulator_loc                    ),
      .ctrl_i        ( ctrl_i                             )
    );
    assign accumulator_o[(ii+1)*32-1:ii*32] = accumulator_loc;
  end

endmodule
