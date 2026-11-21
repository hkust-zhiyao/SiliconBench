// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Alternate structural implementation of prim_arbiter_tree (prefix-mask Policy 1 + stall lock).

`include "prim_assert.sv"

module prim_arbiter_tree #(
  parameter int N   = 8,
  parameter int DW  = 32,
  parameter bit EnDataPort = 1,
  localparam int IdxW = $clog2(N)
) (
  input clk_i,
  input rst_ni,

  input                    policy_i,
  input                    req_chk_i,
  input        [ N-1:0]    req_i,
  input        [DW-1:0]    data_i [N],
  output logic [ N-1:0]    gnt_o,
  output logic [IdxW-1:0]  idx_o,

  output logic             valid_o,
  output logic [DW-1:0]    data_o,
  input                    ready_i
);

  logic unused_req_chk;
  assign unused_req_chk = req_chk_i;

  if (N == 1) begin : gen_degenerate_case
    assign valid_o  = req_i[0];
    assign data_o   = data_i[0];
    assign gnt_o[0] = valid_o & ready_i;
    assign idx_o    = '0;
  end else begin : gen_normal_case
    logic [2**(IdxW+1)-2:0]           req_tree;
    logic [2**(IdxW+1)-2:0]           prio_tree;
    logic [2**(IdxW+1)-2:0]           sel_tree;
    logic [2**(IdxW+1)-2:0]           mask_tree;
    logic [2**(IdxW+1)-2:0][IdxW-1:0] idx_tree;
    logic [2**(IdxW+1)-2:0][DW-1:0]   data_tree;

    logic [IdxW-1:0]                  rr_cnt_q;
    logic [N-1:0]                     prio_mask_q, prio_mask_d;
    logic                             lock_q;
    logic [IdxW-1:0]                  locked_idx_q;
    logic [N-1:0]                     eff_req;

    always_comb begin
      eff_req = req_i;
      if (lock_q) begin
        for (int i = 0; i < N; i++) begin
          if ((locked_idx_q == IdxW'(i)) && req_i[i]) begin
            eff_req = (N'(1) << i);
          end
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        lock_q       <= 1'b0;
        locked_idx_q <= '0;
        prio_mask_q  <= '0;
      end else begin
        if (valid_o && !ready_i) begin
          lock_q       <= 1'b1;
          locked_idx_q <= idx_o;
        end else begin
          lock_q       <= 1'b0;
        end
        if (valid_o && ready_i) begin
          prio_mask_q <= prio_mask_d;
        end
      end
    end

    for (genvar level = 0; level < IdxW+1; level++) begin : gen_tree
      localparam int Base0 = (2**level)-1;
      localparam int Base1 = (2**(level+1))-1;

      for (genvar offset = 0; offset < 2**level; offset++) begin : gen_level
        localparam int Pa = Base0 + offset;
        localparam int C0 = Base1 + 2*offset;
        localparam int C1 = Base1 + 2*offset + 1;

        if (level == IdxW) begin : gen_leafs
          if (offset < N) begin : gen_assign
            wire p_mask = policy_i ? prio_mask_q[offset] : (offset > rr_cnt_q);
            assign req_tree[Pa]        = eff_req[offset];
            assign prio_tree[Pa]       = eff_req[offset] & p_mask;
            assign idx_tree[Pa]        = offset;
            assign data_tree[Pa]       = data_i[offset];
            assign gnt_o[offset]       = eff_req[offset] & sel_tree[Pa] & ready_i;
            assign prio_mask_d[offset] = mask_tree[Pa];
          end else begin : gen_tie_off
            assign req_tree[Pa]  = '0;
            assign prio_tree[Pa] = '0;
            assign idx_tree[Pa]  = '0;
            assign data_tree[Pa] = '0;
          end
        end else begin : gen_nodes
          logic sel;
          assign sel           = ~req_tree[C0] | (~prio_tree[C0] & prio_tree[C1]);
          assign req_tree[Pa]  = req_tree[C0] | req_tree[C1];
          assign prio_tree[Pa] = prio_tree[C1] | prio_tree[C0];
          assign idx_tree[Pa]  = sel ? idx_tree[C1]  : idx_tree[C0];
          assign data_tree[Pa] = sel ? data_tree[C1] : data_tree[C0];
          assign sel_tree[C0]  = sel_tree[Pa] & ~sel;
          assign sel_tree[C1]  = sel_tree[Pa] &  sel;
          assign mask_tree[C0] = mask_tree[Pa];
          assign mask_tree[C1] = mask_tree[Pa] | sel_tree[C0];
        end
      end
    end

    if (EnDataPort) begin : gen_data_port
      assign data_o = data_tree[0];
    end else begin : gen_no_dataport
      assign data_o = '1;
    end

    assign idx_o        = idx_tree[0];
    assign valid_o      = req_tree[0];
    assign sel_tree[0]  = 1'b1;
    assign mask_tree[0] = 1'b0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rr_cnt_q <= '0;
      end else if (valid_o && ready_i) begin
        if (rr_cnt_q == IdxW'(N - 1)) begin
          rr_cnt_q <= '0;
        end else begin
          rr_cnt_q <= rr_cnt_q + 1'b1;
        end
      end
    end
  end
endmodule
