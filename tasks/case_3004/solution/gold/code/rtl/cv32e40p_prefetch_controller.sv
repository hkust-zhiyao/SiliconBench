// Copyright 2020 Silicon Labs, Inc.
// Solderpad Hardware License, Version 2.0

module cv32e40p_prefetch_controller #(
    parameter PULP_OBI = 0,
    parameter COREV_PULP = 1,
    parameter DEPTH = 4,
    parameter FIFO_ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input logic clk,
    input logic rst_n,

    // Fetch stage interface
    input  logic        req_i,
    input  logic        branch_i,
    input  logic [31:0] branch_addr_i,
    output logic        busy_o,

    // HW loop signals
    input logic        hwlp_jump_i,
    input logic [31:0] hwlp_target_i,

    // Transaction request interface
    output logic        trans_valid_o,
    input  logic        trans_ready_i,
    output logic [31:0] trans_addr_o,

    // Transaction response interface
    input logic resp_valid_i,
    input logic resp_err_i,

    // Fetch interface is ready/valid
    input  logic fetch_ready_i,
    output logic fetch_valid_o,

    // FIFO interface
    output logic                       fifo_push_o,
    output logic                       fifo_pop_o,
    output logic                       fifo_flush_o,
    output logic                       fifo_flush_but_first_o,
    input  logic [FIFO_ADDR_DEPTH:0]   fifo_cnt_i,
    input  logic                       fifo_empty_i
);

  import cv32e40p_pkg::*;

  prefetch_state_e state_q, next_state;

  logic [FIFO_ADDR_DEPTH:0] cnt_q;
  logic [FIFO_ADDR_DEPTH:0] next_cnt;
  logic                     count_up;
  logic                     count_down;

  logic [FIFO_ADDR_DEPTH:0] flush_cnt_q;
  logic [FIFO_ADDR_DEPTH:0] next_flush_cnt;

  logic [31:0] trans_addr_q, trans_addr_incr;
  logic [31:0] aligned_branch_addr;

  logic                     fifo_valid;
  logic [FIFO_ADDR_DEPTH:0] fifo_cnt_masked;
  logic [FIFO_ADDR_DEPTH:0] active_cnt;

  logic                     hwlp_wait_resp_flush;
  logic                     hwlp_flush_after_resp;
  logic [FIFO_ADDR_DEPTH:0] hwlp_flush_cnt_delayed_q;
  logic                     hwlp_flush_resp_delayed;
  logic                     hwlp_flush_resp;

  logic                     err_freeze_q, err_freeze_n;
  logic                     resp_flushed;
  logic                     valid_err_resp;

  assign busy_o = (cnt_q != '0) || trans_valid_o;

  assign fifo_valid = !fifo_empty_i;
  assign resp_flushed = branch_i || (flush_cnt_q > 0);
  assign valid_err_resp = resp_valid_i && resp_err_i && !resp_flushed && !(hwlp_jump_i && !fifo_empty_i);

  // Preserve valid FIFO head across flush_cnt_q > 0; only suppress the incoming OBI bypass path
  assign fetch_valid_o = !branch_i && (fifo_valid || (resp_valid_i && !resp_flushed));

  assign aligned_branch_addr = {branch_addr_i[31:2], 2'b00};
  assign trans_addr_incr     = {trans_addr_q[31:2], 2'b00} + 32'd4;

  assign fifo_cnt_masked = (branch_i || hwlp_jump_i) ? '0 : fifo_cnt_i;
  assign active_cnt      = (cnt_q > flush_cnt_q) ? (cnt_q - flush_cnt_q) : '0;

  logic allow_new_req;
  assign allow_new_req = req_i && (!err_freeze_q || branch_i || hwlp_jump_i) &&
                         ((fifo_cnt_masked + active_cnt) < DEPTH[FIFO_ADDR_DEPTH:0]);

  generate
    if (PULP_OBI == 0) begin : gen_no_pulp_obi
      assign trans_valid_o = allow_new_req;
    end else begin : gen_pulp_obi
      assign trans_valid_o = (cnt_q == '0) ? allow_new_req : (allow_new_req && resp_valid_i);
    end
  endgenerate

  always_comb begin
    next_state   = state_q;
    trans_addr_o = trans_addr_q;

    case (state_q)
      IDLE: begin
        if (branch_i) begin
          trans_addr_o = aligned_branch_addr;
        end else if (hwlp_jump_i) begin
          trans_addr_o = {hwlp_target_i[31:2], 2'b00};
        end else begin
          trans_addr_o = trans_addr_incr;
        end
        if ((branch_i || hwlp_jump_i) && !(trans_valid_o && trans_ready_i)) begin
          next_state = BRANCH_WAIT;
        end
      end

      BRANCH_WAIT: begin
        if (branch_i) begin
          trans_addr_o = aligned_branch_addr;
        end else if (hwlp_jump_i) begin
          trans_addr_o = {hwlp_target_i[31:2], 2'b00};
        end else begin
          trans_addr_o = trans_addr_q;
        end
        if (trans_valid_o && trans_ready_i) begin
          next_state = IDLE;
        end
      end
    endcase
  end

  assign fifo_push_o = resp_valid_i && (fifo_valid || !fetch_ready_i) && !resp_flushed && !(hwlp_jump_i && !fifo_empty_i);
  assign fifo_pop_o  = fifo_valid && fetch_ready_i && !branch_i;

  assign count_up   = trans_valid_o && trans_ready_i;
  assign count_down = resp_valid_i;

  always_comb begin
    case ({count_up, count_down})
      2'b00: next_cnt = cnt_q;
      2'b01: next_cnt = cnt_q - 1'b1;
      2'b10: next_cnt = cnt_q + 1'b1;
      2'b11: next_cnt = cnt_q;
    endcase
  end

  generate
    if (COREV_PULP) begin : gen_hwlp
      assign fifo_flush_o           = branch_i || (hwlp_jump_i && !fifo_empty_i && fifo_pop_o);
      assign fifo_flush_but_first_o = (hwlp_jump_i && !fifo_empty_i && !fifo_pop_o);

      assign hwlp_flush_resp        = hwlp_jump_i && !(fifo_empty_i && !resp_valid_i);
      assign hwlp_wait_resp_flush   = hwlp_jump_i && (fifo_empty_i && !resp_valid_i);

      always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
          hwlp_flush_after_resp    <= 1'b0;
          hwlp_flush_cnt_delayed_q <= '0;
        end else begin
          if (branch_i) begin
            hwlp_flush_after_resp    <= 1'b0;
            hwlp_flush_cnt_delayed_q <= '0;
          end else if (hwlp_wait_resp_flush) begin
            hwlp_flush_after_resp    <= 1'b1;
            hwlp_flush_cnt_delayed_q <= (cnt_q > 0) ? (cnt_q - 1'b1) : '0;
          end else if (hwlp_flush_resp || hwlp_flush_resp_delayed) begin
            hwlp_flush_after_resp    <= 1'b0;
            hwlp_flush_cnt_delayed_q <= '0;
          end
        end
      end

      assign hwlp_flush_resp_delayed = hwlp_flush_after_resp && resp_valid_i;
    end else begin : gen_no_hwlp
      assign fifo_flush_o             = branch_i;
      assign fifo_flush_but_first_o   = 1'b0;
      assign hwlp_flush_resp          = 1'b0;
      assign hwlp_wait_resp_flush     = 1'b0;
      assign hwlp_flush_after_resp    = 1'b0;
      assign hwlp_flush_cnt_delayed_q = '0;
      assign hwlp_flush_resp_delayed  = 1'b0;
    end
  endgenerate

  always_comb begin
    next_flush_cnt = flush_cnt_q;
    if (branch_i || hwlp_flush_resp) begin
      next_flush_cnt = cnt_q;
      if (resp_valid_i && (cnt_q > 0)) begin
        next_flush_cnt = cnt_q - 1'b1;
      end
    end else if (hwlp_flush_resp_delayed) begin
      next_flush_cnt = hwlp_flush_cnt_delayed_q;
    end else if (resp_valid_i && (flush_cnt_q > 0)) begin
      next_flush_cnt = flush_cnt_q - 1'b1;
    end
  end

  always_comb begin
    err_freeze_n = err_freeze_q;
    if (branch_i || hwlp_jump_i) begin
      err_freeze_n = 1'b0;
    end else if (valid_err_resp) begin
      err_freeze_n = 1'b1;
    end
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (rst_n == 1'b0) begin
      state_q      <= IDLE;
      cnt_q        <= '0;
      flush_cnt_q  <= '0;
      trans_addr_q <= '0;
      err_freeze_q <= 1'b0;
    end else begin
      state_q      <= next_state;
      cnt_q        <= next_cnt;
      flush_cnt_q  <= next_flush_cnt;
      err_freeze_q <= err_freeze_n;
      if (branch_i || hwlp_jump_i || (trans_valid_o && trans_ready_i)) begin
        trans_addr_q <= trans_addr_o;
      end
    end
  end

endmodule
