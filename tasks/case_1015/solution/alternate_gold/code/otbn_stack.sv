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
  logic [StackWidth-1:0]  mem_array [StackDepth];
  logic [StackDepthW:0]   depth_q, depth_d;
  logic [StackDepthW-1:0] head_idx_q, head_idx_d;
  logic [StackDepthW-1:0] parent_idx_q, parent_idx_d;
  logic [StackDepthW-1:0] write_slot_idx;
  logic [StackWidth-1:0]  cached_top_q, parent_entry_data;
  logic                   has_entries_q, is_full_q;
  logic                   do_push_write, do_pop_read;
  logic                   state_update_en;

  assign do_push_write = push_i & (~is_full_q | pop_i);
  assign do_pop_read   = has_entries_q & pop_i;

  always_comb begin
    if (clear_i) begin
      depth_d      = '0;
      head_idx_d   = '1;
      parent_idx_d = StackDepthW'(StackDepth - 2);
    end else begin
      unique case ({do_push_write, do_pop_read})
        2'b10: begin
          depth_d      = depth_q + (StackDepthW+1)'(1'b1);
          head_idx_d   = depth_q[StackDepthW-1:0];
          parent_idx_d = head_idx_q;
        end
        2'b01: begin
          depth_d      = depth_q - (StackDepthW+1)'(1'b1);
          head_idx_d   = parent_idx_q;
          parent_idx_d = parent_idx_q - 1'b1;
        end
        default: begin
          depth_d      = depth_q;
          head_idx_d   = head_idx_q;
          parent_idx_d = parent_idx_q;
        end
      endcase
    end
  end

  assign write_slot_idx    = pop_i ? head_idx_q : depth_q[StackDepthW-1:0];
  assign parent_entry_data = mem_array[parent_idx_q];
  assign state_update_en   = clear_i | commit_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      depth_q       <= '0;
      head_idx_q    <= '1;
      parent_idx_q  <= StackDepthW'(StackDepth - 2);
      has_entries_q <= 1'b0;
      is_full_q     <= 1'b0;
    end else if (state_update_en) begin
      depth_q       <= depth_d;
      head_idx_q    <= head_idx_d;
      parent_idx_q  <= parent_idx_d;
      has_entries_q <= (depth_d != '0);
      is_full_q     <= (depth_d == StackDepth[StackDepthW:0]);
    end
  end

  logic push_commit_en, pop_commit_en;
  assign push_commit_en = do_push_write & commit_i & ~clear_i;
  assign pop_commit_en  = do_pop_read & commit_i & ~clear_i;

  always_ff @(posedge clk_i) begin
    if (push_commit_en) begin
      mem_array[write_slot_idx] <= push_data_i;
      cached_top_q              <= push_data_i;
    end else if (pop_commit_en) begin
      cached_top_q              <= parent_entry_data;
    end
  end

  assign full_o           = is_full_q;
  assign cnt_err_o        = 1'b0;
  assign top_data_o       = cached_top_q;
  assign top_valid_o      = has_entries_q;
  assign stack_wr_idx_o   = write_slot_idx;
  assign stack_rd_idx_o   = head_idx_q;
  assign stack_write_o    = do_push_write;
  assign stack_read_o     = do_pop_read;
  assign next_top_data_o  = do_push_write ? push_data_i :
                            do_pop_read   ? parent_entry_data :
                                            cached_top_q;
  assign next_top_valid_o = (depth_d != '0);
endmodule
