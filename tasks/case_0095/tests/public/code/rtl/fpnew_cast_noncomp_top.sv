// Copyright 2019 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE.solderpad for details.
// SPDX-License-Identifier: SHL-0.51

module fpnew_cast_noncomp_top #(
  parameter fpnew_pkg::fmt_logic_t   FpFmtConfig  = 5'b10101, // FP32, FP16, FP16ALT
  parameter fpnew_pkg::ifmt_logic_t  IntFmtConfig = 4'b1110,  // INT8, INT16, INT32
  parameter int unsigned             NumPipeRegs  = 1,
  parameter fpnew_pkg::pipe_config_t PipeConfig   = fpnew_pkg::INSIDE
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  logic [1:0][31:0]        operands_i,
  input  logic [4:0][1:0]         is_boxed_i,
  input  fpnew_pkg::roundmode_e   rnd_mode_i,
  input  fpnew_pkg::operation_e   op_i,
  input  logic                    op_mod_i,
  input  fpnew_pkg::fp_format_e   src_fmt_i,
  input  fpnew_pkg::fp_format_e   dst_fmt_i,
  input  fpnew_pkg::int_format_e  int_fmt_i,
  input  logic                    in_valid_i,
  output logic                    in_ready_o,
  input  logic                    flush_i,
  output logic [31:0]             cast_result_o,
  output fpnew_pkg::status_t      cast_status_o,
  output logic                    cast_ext_bit_o,
  output logic                    cast_out_valid_o,
  input  logic                    cast_out_ready_i,
  output logic [31:0]             noncomp_result_o,
  output fpnew_pkg::status_t      noncomp_status_o,
  output logic                    noncomp_ext_bit_o,
  output fpnew_pkg::classmask_e   noncomp_class_mask_o,
  output logic                    noncomp_is_class_o,
  output logic                    noncomp_out_valid_o,
  input  logic                    noncomp_out_ready_i
);

  logic [4:0] is_boxed_1op;
  for (genvar fmt = 0; fmt < 5; fmt++) begin : gen_box
    assign is_boxed_1op[fmt] = is_boxed_i[fmt][0];
  end

  fpnew_cast_multi #(
    .FpFmtConfig  ( FpFmtConfig  ),
    .IntFmtConfig ( IntFmtConfig ),
    .NumPipeRegs  ( NumPipeRegs  ),
    .PipeConfig   ( PipeConfig   )
  ) i_cast_multi (
    .clk_i             ( clk_i            ),
    .rst_ni            ( rst_ni           ),
    .operands_i        ( operands_i[0]    ),
    .is_boxed_i        ( is_boxed_1op     ),
    .rnd_mode_i        ( rnd_mode_i       ),
    .op_i              ( op_i             ),
    .op_mod_i          ( op_mod_i         ),
    .src_fmt_i         ( src_fmt_i        ),
    .dst_fmt_i         ( dst_fmt_i        ),
    .int_fmt_i         ( int_fmt_i        ),
    .tag_i             ( 1'b0             ),
    .mask_i            ( 1'b0             ),
    .aux_i             ( 1'b0             ),
    .in_valid_i        ( in_valid_i       ),
    .in_ready_o        ( in_ready_o       ),
    .flush_i           ( flush_i          ),
    .result_o          ( cast_result_o    ),
    .status_o          ( cast_status_o    ),
    .extension_bit_o   ( cast_ext_bit_o   ),
    .tag_o             (                  ),
    .mask_o            (                  ),
    .aux_o             (                  ),
    .out_valid_o       ( cast_out_valid_o ),
    .out_ready_i       ( cast_out_ready_i ),
    .busy_o            (                  ),
    .reg_ena_i         ( '0               ),
    .early_out_valid_o (                  )
  );

  fpnew_noncomp #(
    .FpFormat    ( fpnew_pkg::FP32 ),
    .NumPipeRegs ( NumPipeRegs     ),
    .PipeConfig  ( PipeConfig      )
  ) i_noncomp (
    .clk_i             ( clk_i                ),
    .rst_ni            ( rst_ni               ),
    .operands_i        ( operands_i           ),
    .is_boxed_i        ( is_boxed_i[0]        ),
    .rnd_mode_i        ( rnd_mode_i           ),
    .op_i              ( op_i                 ),
    .op_mod_i          ( op_mod_i             ),
    .tag_i             ( 1'b0                 ),
    .mask_i            ( 1'b0                 ),
    .aux_i             ( 1'b0                 ),
    .in_valid_i        ( in_valid_i           ),
    .in_ready_o        (                      ),
    .flush_i           ( flush_i              ),
    .result_o          ( noncomp_result_o     ),
    .status_o          ( noncomp_status_o     ),
    .extension_bit_o   ( noncomp_ext_bit_o    ),
    .class_mask_o      ( noncomp_class_mask_o ),
    .is_class_o        ( noncomp_is_class_o   ),
    .tag_o             (                      ),
    .mask_o            (                      ),
    .aux_o             (                      ),
    .out_valid_o       ( noncomp_out_valid_o  ),
    .out_ready_i       ( noncomp_out_ready_i  ),
    .busy_o            (                      ),
    .reg_ena_i         ( '0                   ),
    .early_out_valid_o (                      )
  );

endmodule
