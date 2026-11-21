// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module otbn_loop_controller
  import otbn_pkg::*;
#(
  parameter int ImemAddrWidth = 12
) (
  input clk_i,
  input rst_ni,

  input state_reset_i,

  input                     insn_valid_i,
  input [ImemAddrWidth-1:0] insn_addr_i,
  input [ImemAddrWidth-1:0] next_insn_addr_i,

  input                     loop_start_req_i,
  input                     loop_start_commit_i,
  input [11:0]              loop_bodysize_i,
  input [31:0]              loop_iterations_i,
  input [ImemAddrWidth-1:0] loop_end_addr_predec_i,

  output                     loop_jump_o,
  output [ImemAddrWidth-1:0] loop_jump_addr_o,

  output sw_err_o,
  output hw_err_o,
  output predec_err_o,

  output                     prefetch_loop_active_o,
  output [31:0]              prefetch_loop_iterations_o,
  output [ImemAddrWidth:0]   prefetch_loop_end_addr_o,
  output [ImemAddrWidth-1:0] prefetch_loop_jump_addr_o,

  input jump_or_branch_i,
  input otbn_stall_i
);
  localparam int unsigned LoopEndAddrWidth = 1 + (ImemAddrWidth < 14 ? 14 : ImemAddrWidth);

  typedef struct packed {
    logic [ImemAddrWidth-1:0] loop_start;
    logic [ImemAddrWidth:0]   loop_end;
    logic [6:0]               loop_addrs_intg;
  } loop_addr_info_t;

  typedef struct packed {
    loop_addr_info_t          loop_addr_info;
    logic [31:0]              loop_iterations;
  } loop_info_t;

  loop_info_t current_loop;
  logic       current_loop_valid;

  logic        at_current_loop_end_insn;
  logic        current_loop_finish;
  logic        active_iter_gt_one_q;
  logic        current_loop_counter_dec;
  logic [38:0] current_loop_addrs_padded_intg_unbuf, current_loop_addrs_padded_intg_buf;
  logic [1:0]  current_loop_intg_err;

  loop_info_t                  new_loop;
  logic [LoopEndAddrWidth-1:0] new_loop_end_addr_full;
  logic [ImemAddrWidth:0]      new_loop_end_addr_imem;
  logic [31:0]                 new_loop_addrs_padded_no_intg;
  logic [38:0]                 new_loop_addrs_padded_intg;

  loop_addr_info_t             next_loop_addr_info;
  logic                        next_loop_valid;
  logic loop_stack_push_req;
  logic loop_stack_full;
  logic loop_stack_pop;
  logic loop_stack_commit;

  logic loop_iteration_err;
  logic loop_branch_err;
  logic loop_stack_overflow_err;
  logic loop_at_end_err;
  logic loop_stack_cnt_err;

  localparam int unsigned StackDepthW = prim_util_pkg::vbits(LoopStackDepth);
  logic [StackDepthW-1:0] loop_stack_wr_idx;
  logic                   loop_stack_write;
  logic [StackDepthW-1:0] loop_stack_rd_idx;

  logic [31:0] saved_outer_iters [LoopStackDepth];

  assign new_loop_end_addr_full = LoopEndAddrWidth'(insn_addr_i) +
                                  LoopEndAddrWidth'({loop_bodysize_i, 2'b00}) + 'd4;

  assign new_loop_end_addr_imem[ImemAddrWidth-1:0] = new_loop_end_addr_full[ImemAddrWidth-1:0];
  assign new_loop_end_addr_imem[ImemAddrWidth] =
      |new_loop_end_addr_full[LoopEndAddrWidth-1:ImemAddrWidth];

  assign new_loop_addrs_padded_no_intg = {{(32 - (ImemAddrWidth * 2) - 1){1'b0}},
                                          next_insn_addr_i,
                                          new_loop_end_addr_imem};

  prim_secded_inv_39_32_enc u_new_loop_addrs_intg_enc (
    .data_i(new_loop_addrs_padded_no_intg),
    .data_o(new_loop_addrs_padded_intg)
  );

  logic unused_new_loop_addrs_padded_intg;
  assign unused_new_loop_addrs_padded_intg = ^new_loop_addrs_padded_intg[31:0];

  assign new_loop = '{
    loop_addr_info : '{
        loop_start:      next_insn_addr_i,
        loop_end:        new_loop_end_addr_imem,
        loop_addrs_intg: new_loop_addrs_padded_intg[38:32]
    },
    loop_iterations: loop_iterations_i
  };

  assign at_current_loop_end_insn =
      current_loop_valid & (current_loop.loop_addr_info.loop_end == {1'b0, insn_addr_i}) &
      insn_valid_i;

  assign current_loop_finish = at_current_loop_end_insn & ~active_iter_gt_one_q & ~otbn_stall_i;

  assign loop_jump_o      = at_current_loop_end_insn & ~current_loop_finish;
  assign loop_jump_addr_o = current_loop.loop_addr_info.loop_start;

  assign loop_iteration_err      = (loop_iterations_i == '0) & loop_start_req_i;
  assign loop_branch_err         = at_current_loop_end_insn & jump_or_branch_i;
  assign loop_stack_overflow_err = loop_stack_push_req & loop_stack_full;
  assign loop_at_end_err         = at_current_loop_end_insn & loop_start_req_i;

  assign sw_err_o = loop_iteration_err      |
                    loop_branch_err         |
                    loop_stack_overflow_err |
                    loop_at_end_err;

  assign current_loop_counter_dec = ~state_reset_i & ~otbn_stall_i & at_current_loop_end_insn;

  assign loop_stack_push_req = loop_start_req_i;

  `ASSERT(NoStartCommitIfLoopErr, loop_start_req_i && loop_start_commit_i |-> !sw_err_o)

  assign loop_stack_pop = current_loop_finish;

  assign loop_stack_commit = loop_stack_push_req ? loop_start_commit_i : loop_stack_pop;

  otbn_stack #(
    .StackWidth($bits(loop_addr_info_t)),
    .StackDepth(LoopStackDepth)
  ) loop_info_stack (
    .clk_i,
    .rst_ni,

    .full_o(loop_stack_full),

    .cnt_err_o(loop_stack_cnt_err),

    .clear_i(state_reset_i),

    .push_data_i(new_loop.loop_addr_info),
    .push_i     (loop_stack_push_req),

    .pop_i      (loop_stack_pop),
    .top_data_o (current_loop.loop_addr_info),
    .top_valid_o(current_loop_valid),

    .commit_i(loop_stack_commit),

    .stack_wr_idx_o(loop_stack_wr_idx),
    .stack_write_o (loop_stack_write),
    .stack_rd_idx_o(loop_stack_rd_idx),
    .stack_read_o  (),

    .next_top_data_o(next_loop_addr_info),
    .next_top_valid_o(next_loop_valid)
  );

  logic [31:0] active_iter_q, active_iter_d, dec_iter_val, restored_iter_val;
  logic [StackDepthW-1:0] parent_slot_q;
  logic push_commit_pulse, pop_commit_pulse;

  assign push_commit_pulse = loop_stack_write & loop_stack_commit;
  assign pop_commit_pulse  = loop_stack_pop & loop_stack_commit;
  assign restored_iter_val = saved_outer_iters[parent_slot_q];
  assign dec_iter_val      = active_iter_q - 32'd1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      parent_slot_q <= StackDepthW'(LoopStackDepth - 2);
    end else if (state_reset_i) begin
      parent_slot_q <= StackDepthW'(LoopStackDepth - 2);
    end else if (push_commit_pulse & ~loop_stack_pop) begin
      parent_slot_q <= loop_stack_rd_idx;
    end else if (pop_commit_pulse & ~loop_stack_write) begin
      parent_slot_q <= parent_slot_q - 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (push_commit_pulse & ~state_reset_i) begin
      saved_outer_iters[loop_stack_rd_idx] <= active_iter_q;
    end
  end

  always_comb begin
    if (push_commit_pulse) begin
      active_iter_d = new_loop.loop_iterations;
    end else if (pop_commit_pulse) begin
      active_iter_d = restored_iter_val;
    end else if (current_loop_counter_dec) begin
      active_iter_d = dec_iter_val;
    end else begin
      active_iter_d = active_iter_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_iter_q        <= {32{1'b1}};
      active_iter_gt_one_q <= 1'b1;
    end else if (state_reset_i) begin
      active_iter_q        <= {32{1'b1}};
      active_iter_gt_one_q <= 1'b1;
    end else if (push_commit_pulse | loop_stack_pop | current_loop_counter_dec) begin
      active_iter_q        <= active_iter_d;
      active_iter_gt_one_q <= (active_iter_d != 32'd1);
    end
  end

  assign current_loop.loop_iterations = active_iter_q;

  assign current_loop_addrs_padded_intg_unbuf =
    {current_loop.loop_addr_info.loop_addrs_intg,
     {(32 - (ImemAddrWidth * 2) - 1){1'b0}},
     current_loop.loop_addr_info.loop_start,
     current_loop.loop_addr_info.loop_end};

  prim_buf #(
    .Width(39)
  ) u_current_loop_addrs_padded_intg_buf (
    .in_i (current_loop_addrs_padded_intg_unbuf),
    .out_o(current_loop_addrs_padded_intg_buf)
  );

  prim_secded_inv_39_32_dec u_loop_addrs_intg_dec (
    .data_i     (current_loop_addrs_padded_intg_buf),
    .data_o     (),
    .syndrome_o (),
    .err_o      (current_loop_intg_err)
  );

  assign hw_err_o = loop_stack_cnt_err | ((|current_loop_intg_err) & current_loop_valid);

  assign predec_err_o =
    (loop_end_addr_predec_i != new_loop_end_addr_full[ImemAddrWidth-1:0]) & loop_start_req_i;

  assign prefetch_loop_active_o = next_loop_valid;

  assign prefetch_loop_iterations_o =
    loop_stack_pop           ? restored_iter_val         :
    current_loop_counter_dec ? dec_iter_val              :
    loop_stack_write         ? new_loop.loop_iterations  :
                               active_iter_q;

  logic unused_next_loop_addr_info_intg;
  assign unused_next_loop_addr_info_intg = ^next_loop_addr_info.loop_addrs_intg;
  logic unused_loop_stack_wr_idx;
  assign unused_loop_stack_wr_idx = ^loop_stack_wr_idx;

  assign prefetch_loop_end_addr_o  = next_loop_addr_info.loop_end;
  assign prefetch_loop_jump_addr_o = next_loop_addr_info.loop_start;

  `ASSERT(LoopStackPushAndPopCausesErr, loop_stack_push_req && loop_stack_pop |-> sw_err_o)
  `ASSERT(LoopStackPushAndPopNeverCommits,
    loop_stack_push_req && loop_stack_pop |-> ~loop_stack_commit)
  `ASSERT(NoLoopWriteIfCounterDec, current_loop_counter_dec |-> (!loop_stack_write | sw_err_o))
endmodule
