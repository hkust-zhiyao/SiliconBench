// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module otbn_stack
  import otbn_pkg::*;
#(
  parameter int unsigned StackWidth = 32,
  parameter int unsigned StackDepth = 4,

  localparam int unsigned StackDepthW = prim_util_pkg::vbits(StackDepth)
) (
  input clk_i,
  input rst_ni,

  output logic                  full_o,
  output logic                  cnt_err_o,
  input  logic                  clear_i,

  input  logic                  push_i,
  input  logic [StackWidth-1:0] push_data_i,

  input  logic                  pop_i,
  output logic [StackWidth-1:0] top_data_o,
  output logic                  top_valid_o,

  input  logic                  commit_i,

  output logic [StackDepthW-1:0] stack_wr_idx_o,
  output logic                   stack_write_o,
  output logic [StackDepthW-1:0] stack_rd_idx_o,
  output logic                   stack_read_o,

  output logic [StackWidth-1:0]  next_top_data_o,
  output logic                   next_top_valid_o
);
  logic [StackWidth-1:0]  stack_storage [StackDepth];
  logic [StackDepthW:0]   stack_wr_ptr, next_stack_wr_ptr;
  logic [StackDepthW-1:0] stack_rd_idx_q, stack_prev_idx_q, stack_wr_idx;
  logic [StackWidth-1:0]  top_data_q, prev_data_w;
  logic                   stack_empty_q, stack_full_q;
  logic                   stack_write, stack_read;

  assign stack_write = push_i & (~stack_full_q | pop_i);
  assign stack_read  = ~stack_empty_q & pop_i;

  assign next_stack_wr_ptr = clear_i                     ? '0 :
                             (stack_write & ~stack_read) ? (stack_wr_ptr + (StackDepthW+1)'(1'b1)) :
                             (~stack_write & stack_read) ? (stack_wr_ptr - (StackDepthW+1)'(1'b1)) :
                                                           stack_wr_ptr;
  assign stack_wr_idx = pop_i ? stack_rd_idx_q : stack_wr_ptr[StackDepthW-1:0];
  assign prev_data_w  = stack_storage[stack_prev_idx_q];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stack_wr_ptr     <= '0;
      stack_rd_idx_q   <= '1;
      stack_prev_idx_q <= StackDepthW'(StackDepth - 2);
      stack_empty_q    <= 1'b1;
      stack_full_q     <= 1'b0;
    end else if (clear_i | commit_i) begin
      stack_wr_ptr     <= next_stack_wr_ptr;
      stack_rd_idx_q   <= next_stack_wr_ptr[StackDepthW-1:0] - 1'b1;
      stack_prev_idx_q <= next_stack_wr_ptr[StackDepthW-1:0] - 2'd2;
      stack_empty_q    <= (next_stack_wr_ptr == '0);
      stack_full_q     <= (next_stack_wr_ptr == StackDepth[StackDepthW:0]);
    end
  end

  always_ff @(posedge clk_i) begin
    if (stack_write & commit_i & ~clear_i) begin
      stack_storage[stack_wr_idx] <= push_data_i;
      top_data_q                  <= push_data_i;
    end else if (stack_read & commit_i & ~clear_i) begin
      top_data_q                  <= prev_data_w;
    end
  end

  assign full_o           = stack_full_q;
  assign cnt_err_o        = 1'b0;
  assign top_data_o       = top_data_q;
  assign top_valid_o      = ~stack_empty_q;
  assign stack_wr_idx_o   = stack_wr_idx;
  assign stack_rd_idx_o   = stack_rd_idx_q;
  assign stack_write_o    = stack_write;
  assign stack_read_o     = stack_read;
  assign next_top_data_o  = stack_write ? push_data_i :
                            stack_read  ? prev_data_w :
                                          top_data_q;
  assign next_top_valid_o = (next_stack_wr_ptr != '0);
endmodule
