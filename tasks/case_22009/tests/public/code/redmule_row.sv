// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
// Arpan Suravi Prasad <prasadar@iis.ee.ethz.ch>

module redmule_row
  import fpnew_pkg::*;
  import redmule_pkg::*;
#(
  parameter fpnew_pkg::fp_format_e    FpFormat    = fpnew_pkg::FP16,
  parameter int unsigned              Height      = 4,
  parameter int unsigned              NumPipeRegs = 2,
  parameter fpnew_pkg::pipe_config_t  PipeConfig  = fpnew_pkg::DISTRIBUTED,
  parameter type                      TagType     = logic,
  parameter type                      AuxType     = logic,
  localparam int unsigned             BITW        = fpnew_pkg::fp_width(FpFormat),
  localparam int unsigned             H           = Height
)(
  input  logic                                      clk_i             ,
  input  logic                                      rst_ni            ,
  input  logic                    [H-1:0][BITW-1:0] x_input_i         ,
  input  logic                    [H-1:0][BITW-1:0] w_input_i         ,
  input  logic                           [BITW-1:0] y_bias_i          ,
  output logic                           [BITW-1:0] z_output_o        ,
  input  logic                    [2:0]             fma_is_boxed_i    ,
  input  logic                    [1:0]             noncomp_is_boxed_i,
  input  fpnew_pkg::roundmode_e                     stage1_rnd_i      ,
  input  fpnew_pkg::roundmode_e                     stage2_rnd_i      ,
  input  fpnew_pkg::operation_e                     op1_i             ,
  input  fpnew_pkg::operation_e                     op2_i             ,
  input  logic                                      op_mod_i          ,
  input  TagType                                    tag_i             ,
  input  AuxType                                    aux_i             ,
  input  logic                                      in_valid_i        ,
  output logic                    [H-1:0]           in_ready_o        ,
  input  logic                                      reg_enable_i      ,
  input  logic                                      flush_i           ,
  output fpnew_pkg::status_t      [H-1:0]           status_o          ,
  output logic                    [H-1:0]           extension_bit_o   ,
  output fpnew_pkg::classmask_e   [H-1:0]           class_mask_o      ,
  output logic                    [H-1:0]           is_class_o        ,
  output TagType                  [H-1:0]           tag_o             ,
  output AuxType                  [H-1:0]           aux_o             ,
  output logic                    [H-1:0]           out_valid_o       ,
  input  logic                                      out_ready_i       ,
  output logic                    [H-1:0]           busy_o
);

  logic [H-1:0][2:0][BITW-1:0] fma_operands;
  logic [H-1:0][BITW-1:0]      partial_result;
  logic [H-1:0][BITW-1:0]      output_q;

  wire unused_noncomp = |{noncomp_is_boxed_i, stage2_rnd_i, op2_i};

  generate
    for (genvar index = 0; index < H; index++) begin : gen_computing_element
      logic [BITW-1:0] y_chain;
      logic [BITW-1:0] fma_y;
      assign y_chain = (index > 0) ? output_q[index-1] : y_bias_i;
      assign fma_y   = (op1_i == fpnew_pkg::MUL) ? '0 : y_chain;

      always_comb begin
        if (op1_i == fpnew_pkg::ADD) begin
          fma_operands[index][0] = '0;
          fma_operands[index][1] = x_input_i[index];
          fma_operands[index][2] = w_input_i[index];
        end else begin
          fma_operands[index][0] = x_input_i[index];
          fma_operands[index][1] = w_input_i[index];
          fma_operands[index][2] = fma_y;
        end
      end

      redmule_fma #(
        .FpFormat    ( FpFormat    ),
        .NumPipeRegs ( NumPipeRegs ),
        .PipeConfig  ( PipeConfig  ),
        .TagType     ( TagType     ),
        .AuxType     ( AuxType     ),
        .Stallable   ( 1'b1        )
      ) i_fma (
        .clk_i           ( clk_i                 ),
        .rst_ni          ( rst_ni                ),
        .operands_i      ( fma_operands[index]   ),
        .is_boxed_i      ( fma_is_boxed_i        ),
        .rnd_mode_i      ( stage1_rnd_i          ),
        .op_i            ( op1_i                 ),
        .op_mod_i        ( op_mod_i              ),
        .tag_i           ( tag_i                 ),
        .aux_i           ( aux_i                 ),
        .in_valid_i      ( in_valid_i            ),
        .in_ready_o      ( in_ready_o[index]     ),
        .reg_enable_i    ( reg_enable_i          ),
        .flush_i         ( flush_i               ),
        .result_o        ( partial_result[index] ),
        .status_o        ( status_o[index]       ),
        .extension_bit_o ( extension_bit_o[index]),
        .tag_o           ( tag_o[index]          ),
        .aux_o           ( aux_o[index]          ),
        .out_valid_o     ( out_valid_o[index]    ),
        .out_ready_i     ( out_ready_i           ),
        .busy_o          ( busy_o[index]         )
      );

      assign class_mask_o[index] = fpnew_pkg::QNAN;
      assign is_class_o[index]   = 1'b0;

      always_ff @(posedge clk_i or negedge rst_ni) begin : intermediate_output_register
        if (~rst_ni) begin
          output_q[index] <= '0;
        end else if (flush_i) begin
          output_q[index] <= '0;
        end else if (reg_enable_i) begin
          output_q[index] <= partial_result[index];
        end
      end
    end
  endgenerate

  assign z_output_o = output_q[H-1];

endmodule : redmule_row
