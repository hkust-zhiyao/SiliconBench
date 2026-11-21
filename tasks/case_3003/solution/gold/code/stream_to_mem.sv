// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

`include "common_cells/registers.svh"
module stream_to_mem #(
  parameter type         mem_req_t  = logic,
  parameter type         mem_resp_t = logic,
  parameter int unsigned BufDepth   = 32'd1
) (
  input  logic      clk_i,
  input  logic      rst_ni,
  input  logic      flush_i,
  input  mem_req_t  req_i,
  input  logic      req_valid_i,
  output logic      req_ready_o,
  output mem_resp_t resp_o,
  output logic      resp_valid_o,
  input  logic      resp_ready_i,
  output mem_req_t  mem_req_o,
  output logic      mem_req_valid_o,
  input  logic      mem_req_ready_i,
  input  mem_resp_t mem_resp_i,
  input  logic      mem_resp_valid_i
);

  typedef logic [$clog2(BufDepth+1):0] cnt_t;

  cnt_t cnt_d, cnt_q;
  cnt_t inflight_d, inflight_q;
  cnt_t drop_cnt_d, drop_cnt_q;
  logic buf_ready,
        buf_valid,
        req_ready,
        fifo_push_valid,
        fifo_pop_ready;

  if (BufDepth > 0) begin : gen_buf
    logic req_acc, resp_acc, stale_ret;
    assign req_acc   = req_valid_i && req_ready_o;
    assign resp_acc  = resp_valid_o && resp_ready_i;
    assign stale_ret = mem_resp_valid_i && (drop_cnt_q > '0);

    always_comb begin
      if (flush_i) begin
        cnt_t rem_inflight;
        rem_inflight = (inflight_q > '0 && mem_resp_valid_i) ? (inflight_q - 1'b1) : inflight_q;
        cnt_d        = rem_inflight;
        inflight_d   = rem_inflight;
        drop_cnt_d   = rem_inflight;
      end else begin
        cnt_d      = cnt_q + cnt_t'(req_acc) - cnt_t'(resp_acc) - cnt_t'(stale_ret);
        inflight_d = inflight_q + cnt_t'(req_acc) - cnt_t'(mem_resp_valid_i);
        drop_cnt_d = drop_cnt_q - cnt_t'(stale_ret);
      end
    end

    assign req_ready       = !flush_i && ((cnt_q < BufDepth) | (resp_valid_o & resp_ready_i));
    assign req_ready_o     = mem_req_ready_i & req_ready;
    assign mem_req_valid_o = req_valid_i & req_ready;

    assign fifo_push_valid = mem_resp_valid_i & ~flush_i & (drop_cnt_q == '0);
    assign resp_valid_o    = buf_valid & ~flush_i;
    assign fifo_pop_ready  = resp_ready_i & ~flush_i;

    stream_fifo #(
      .FALL_THROUGH ( 1'b1       ),
      .DEPTH        ( BufDepth   ),
      .T            ( mem_resp_t )
    ) i_resp_buf (
      .clk_i,
      .rst_ni,
      .flush_i    ( flush_i         ),
      .testmode_i ( 1'b0            ),
      .data_i     ( mem_resp_i      ),
      .valid_i    ( fifo_push_valid ),
      .ready_o    ( buf_ready       ),
      .data_o     ( resp_o          ),
      .valid_o    ( buf_valid       ),
      .ready_i    ( fifo_pop_ready  ),
      .usage_o    ( /* unused */    )
    );

    `FFARN(cnt_q,      cnt_d,      '0, clk_i, rst_ni)
    `FFARN(inflight_q, inflight_d, '0, clk_i, rst_ni)
    `FFARN(drop_cnt_q, drop_cnt_d, '0, clk_i, rst_ni)

  end else begin : gen_no_buf
    assign mem_req_valid_o = req_valid_i & ~flush_i;
    assign resp_valid_o    = mem_req_valid_o & mem_req_ready_i & mem_resp_valid_i & ~flush_i;
    assign req_ready_o     = resp_ready_i    & resp_valid_o;
    assign resp_o          = mem_resp_i;
  end

  assign mem_req_o = req_i;

endmodule
