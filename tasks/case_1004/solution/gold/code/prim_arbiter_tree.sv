// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

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
    logic [2**(IdxW+1)-2:0][IdxW-1:0] idx_tree;
    logic [2**(IdxW+1)-2:0][DW-1:0]   data_tree;

    logic [IdxW-1:0]                  rr_cnt_q;
    logic                             lock_q;
    logic [IdxW-1:0]                  locked_idx_q;
    logic [N-1:0]                     eff_req;
    logic [(1<<IdxW)-2:0]             fair_next_q;

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
      end else if (valid_o && !ready_i) begin
        lock_q       <= 1'b1;
        locked_idx_q <= idx_o;
      end else begin
        lock_q       <= 1'b0;
      end
    end

    integer lv, nd;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        fair_next_q <= '0;
      end else if (valid_o && ready_i) begin
        for (lv = 0; lv < IdxW; lv = lv + 1) begin
          for (nd = 0; nd < (1 << lv); nd = nd + 1) begin
            if ((idx_o >> (IdxW - lv)) == nd) begin
              fair_next_q[(1 << lv) - 1 + nd] <= ~idx_o[IdxW - lv - 1];
            end
          end
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
            assign req_tree[Pa]  = eff_req[offset];
            assign prio_tree[Pa] = eff_req[offset] & (offset > rr_cnt_q);
            assign idx_tree[Pa]  = offset;
            assign data_tree[Pa] = data_i[offset];
            assign gnt_o[offset] = eff_req[offset] & sel_tree[Pa] & ready_i;
          end else begin : gen_tie_off
            assign req_tree[Pa]  = '0;
            assign prio_tree[Pa] = '0;
            assign idx_tree[Pa]  = '0;
            assign data_tree[Pa] = '0;
          end
        end else begin : gen_nodes
          logic sel;
          wire node_pref = policy_i ? fair_next_q[Pa] : (~prio_tree[C0] & prio_tree[C1]);
          assign sel           = ~req_tree[C0] | (req_tree[C1] & node_pref);
          assign req_tree[Pa]  = req_tree[C0] | req_tree[C1];
          assign prio_tree[Pa] = prio_tree[C1] | prio_tree[C0];
          assign idx_tree[Pa]  = sel ? idx_tree[C1]  : idx_tree[C0];
          assign data_tree[Pa] = sel ? data_tree[C1] : data_tree[C0];
          assign sel_tree[C0]  = sel_tree[Pa] & ~sel;
          assign sel_tree[C1]  = sel_tree[Pa] &  sel;
        end
      end
    end

    if (EnDataPort) begin : gen_data_port
      assign data_o = data_tree[0];
    end else begin : gen_no_dataport
      assign data_o = '1;
    end

    assign idx_o       = idx_tree[0];
    assign valid_o     = req_tree[0];
    assign sel_tree[0] = 1'b1;

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
