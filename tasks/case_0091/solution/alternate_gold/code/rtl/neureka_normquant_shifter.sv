// Copyright (C) 2019-2021 ETH Zurich, University of Bologna and GreenWaves Technologies
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

import neureka_package::*;

module neureka_normquant_shifter #(
  parameter int unsigned ACC = neureka_package::NEUREKA_ACCUM_SIZE,
  parameter int unsigned INT = 33,
  parameter int unsigned OUTPUT_REGISTER = 0
) (
  input  logic                           clk_i,
  input  logic                           rst_ni,
  input  logic                           test_mode_i,
  input  logic                           clear_i,
  input  logic unsigned [INT-1:0]        data_i,
  input  logic unsigned [7:0]            shift_i,
  output logic signed   [ACC-1:0]        accumulator_o,
  input  neureka_package::ctrl_normquant_t  ctrl_i
);

  wire [4:0] shamt = ctrl_i.use_shifting ? shift_i[4:0] : 5'd0;
  wire signed [INT:0] data_ext = {data_i[INT-1], data_i, 1'b0};
  wire signed [INT:0] shifted_with_half = data_ext >>> shamt;
  wire round_inc = ctrl_i.use_shifting & ctrl_i.use_rounding & shifted_with_half[0];
  wire [INT-1:0] pre_u = shifted_with_half[INT:1];

  logic [7:0]  grp_all;
  logic [8:0]  grp_c;
  logic [31:0] low32;
  always_comb begin
    for (int g = 0; g < 8; g++) begin
      grp_all[g] = &pre_u[g*4 +: 4];
    end
    grp_c[0] = round_inc;
    grp_c[1] = round_inc & grp_all[0];
    grp_c[2] = round_inc & (&grp_all[1:0]);
    grp_c[3] = round_inc & (&grp_all[2:0]);
    grp_c[4] = round_inc & (&grp_all[3:0]);
    grp_c[5] = grp_c[4]  & grp_all[4];
    grp_c[6] = grp_c[4]  & (&grp_all[5:4]);
    grp_c[7] = grp_c[4]  & (&grp_all[6:4]);
    grp_c[8] = grp_c[4]  & (&grp_all[7:4]);
    for (int g = 0; g < 8; g++) begin
      low32[g*4 + 0] = pre_u[g*4 + 0] ^ grp_c[g];
      low32[g*4 + 1] = pre_u[g*4 + 1] ^ (grp_c[g] & pre_u[g*4 + 0]);
      low32[g*4 + 2] = pre_u[g*4 + 2] ^ (grp_c[g] & (&pre_u[g*4 +: 2]));
      low32[g*4 + 3] = pre_u[g*4 + 3] ^ (grp_c[g] & (&pre_u[g*4 +: 3]));
    end
  end
  wire c8  = grp_c[2];
  wire c16 = grp_c[4];
  wire c32 = grp_c[8];

  wire is_neg = pre_u[INT-1];
  wire is_8b  = (ctrl_i.quant_mode == NEUREKA_MODE_8B);
  wire is_16b = (ctrl_i.quant_mode == NEUREKA_MODE_16B);
  wire is_32b = (ctrl_i.quant_mode == NEUREKA_MODE_32B);

  wire hi_nz_32 = |pre_u[INT-2:32];
  wire hi_nz_16 = hi_nz_32 | (|pre_u[31:16]);
  wire hi_nz_8  = hi_nz_16 | (|pre_u[15:8]);

  wire hi_all1_32 = &pre_u[INT-2:32];
  wire hi_all1_16 = hi_all1_32 & (&pre_u[31:16]);
  wire hi_all1_8  = hi_all1_16 & (&pre_u[15:8]);

  wire ovf_pos = is_8b  ? ((ctrl_i.relu ? 1'b0 : low32[7])  | hi_nz_8  | c8)  :
                 is_16b ? ((ctrl_i.relu ? 1'b0 : low32[15]) | hi_nz_16 | c16) :
                 is_32b ? ((ctrl_i.relu ? 1'b0 : low32[31]) | hi_nz_32 | c32) : 1'b0;

  wire in_neg_range = is_8b  ? (hi_all1_8  & (low32[7]  | c8))  :
                      is_16b ? (hi_all1_16 & (low32[15] | c16)) :
                      is_32b ? (hi_all1_32 & (low32[31] | c32)) : 1'b1;

  wire do_zero = (ctrl_i.use_shifting & ctrl_i.relu & is_neg) | (~is_8b & ~is_16b & ~is_32b);
  wire do_sat_pos = ctrl_i.use_shifting & ~is_neg & ovf_pos;
  wire do_sat_neg = ctrl_i.use_shifting & ~ctrl_i.relu & is_neg & ~in_neg_range;

  logic [ACC-1:0] accumulator, accumulator_d, accumulator_q;

  always_comb begin
    if (do_zero) begin
      accumulator = '0;
    end else if (do_sat_neg) begin
      accumulator = {is_32b, 15'b0, is_16b, 7'b0, is_8b, 7'b0};
    end else if (do_sat_pos) begin
      accumulator = {
        is_32b & ctrl_i.relu,
        {15{is_32b}},
        (is_32b | (is_16b & ctrl_i.relu)),
        {7{is_32b | is_16b}},
        (is_32b | is_16b | (is_8b & ctrl_i.relu)),
        {7{is_32b | is_16b | is_8b}}
      };
    end else begin
      accumulator = {
        is_32b ? low32[31:16] : 16'b0,
        (is_32b | is_16b) ? low32[15:8] : 8'b0,
        low32[7:0]
      };
    end
  end

  if(OUTPUT_REGISTER) begin : output_register_gen
    always_comb begin
      accumulator_d = accumulator_q;
      if(clear_i) begin
        accumulator_d = '0;
      end else if (ctrl_i.start) begin
        accumulator_d = accumulator;
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if(~rst_ni) begin
        accumulator_q <= '0;
      end else begin
        accumulator_q <= accumulator_d;
      end
    end
  end else begin : no_output_register_gen
    assign accumulator_q = accumulator;
  end

  assign accumulator_o = accumulator_q;

endmodule
