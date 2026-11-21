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

  localparam int unsigned AddrDepth = (BufDepth > 1) ? $clog2(BufDepth) : 1;
  typedef logic [$clog2(BufDepth+1):0] cnt_t;

  cnt_t cnt_d, cnt_q;
  cnt_t discard_d, discard_q;
  logic [AddrDepth-1:0] fifo_usage;
  logic buf_ready,
        buf_valid,
        req_ready;

  if (BufDepth > 0) begin : gen_buf
    cnt_t fifo_occupancy;
    cnt_t bus_inflight;
    logic accept_req, accept_resp, drop_resp;

    assign fifo_occupancy = (!buf_ready) ? cnt_t'(BufDepth) : cnt_t'(fifo_usage);
    assign bus_inflight   = (cnt_q >= fifo_occupancy) ? (cnt_q - fifo_occupancy) : '0;

    assign accept_req  = req_valid_i && req_ready_o;
    assign accept_resp = resp_valid_o && resp_ready_i;
    assign drop_resp   = mem_resp_valid_i && (discard_q > '0);

    always_comb begin
      if (flush_i) begin
        cnt_t next_bus;
        next_bus  = (bus_inflight > '0 && mem_resp_valid_i) ? (bus_inflight - 1'b1) : bus_inflight;
        cnt_d     = next_bus;
        discard_d = next_bus;
      end else begin
        cnt_d     = cnt_q + cnt_t'(accept_req) - cnt_t'(accept_resp) - cnt_t'(drop_resp);
        discard_d = discard_q - cnt_t'(drop_resp);
      end
    end

    assign req_ready       = !flush_i && ((cnt_q < BufDepth) | (resp_valid_o & resp_ready_i));
    assign req_ready_o     = mem_req_ready_i & req_ready;
    assign mem_req_valid_o = req_valid_i & req_ready;
    assign resp_valid_o    = buf_valid & ~flush_i;

    stream_fifo #(
      .FALL_THROUGH ( 1'b1       ),
      .DEPTH        ( BufDepth   ),
      .T            ( mem_resp_t )
    ) i_resp_buf (
      .clk_i,
      .rst_ni,
      .flush_i    ( flush_i                                      ),
      .testmode_i ( 1'b0                                         ),
      .data_i     ( mem_resp_i                                   ),
      .valid_i    ( mem_resp_valid_i & ~flush_i & (discard_q == '0) ),
      .ready_o    ( buf_ready                                    ),
      .data_o     ( resp_o                                       ),
      .valid_o    ( buf_valid                                    ),
      .ready_i    ( resp_ready_i & ~flush_i                      ),
      .usage_o    ( fifo_usage                                   )
    );

    `FFARN(cnt_q,     cnt_d,     '0, clk_i, rst_ni)
    `FFARN(discard_q, discard_d, '0, clk_i, rst_ni)

  end else begin : gen_no_buf
    assign mem_req_valid_o = req_valid_i & ~flush_i;
    assign resp_valid_o    = mem_req_valid_o & mem_req_ready_i & mem_resp_valid_i & ~flush_i;
    assign req_ready_o     = resp_ready_i    & resp_valid_o;
    assign resp_o          = mem_resp_i;
  end

  assign mem_req_o = req_i;

endmodule
