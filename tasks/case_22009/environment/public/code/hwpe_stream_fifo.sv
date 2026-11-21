// Copyright 2018-2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module hwpe_stream_fifo
  import hwpe_stream_package::*;
#(
  parameter int unsigned DATA_WIDTH = 256,
  parameter int unsigned FIFO_DEPTH = 4,
  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  logic                  clear_i,
  output flags_fifo_t           flags_o,
  input  logic                  push_valid_i,
  output logic                  push_ready_o,
  input  logic [DATA_WIDTH-1:0] push_data_i,
  input  logic [STRB_WIDTH-1:0] push_strb_i,
  output logic                  pop_valid_o,
  input  logic                  pop_ready_i,
  output logic [DATA_WIDTH-1:0] pop_data_o,
  output logic [STRB_WIDTH-1:0] pop_strb_o
);

  localparam int unsigned ADDR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;

  logic [FIFO_DEPTH-1:0][DATA_WIDTH-1:0] data_q;
  logic [FIFO_DEPTH-1:0][STRB_WIDTH-1:0] strb_q;
  logic [ADDR_W-1:0]                     wptr_q, rptr_q;
  logic [ADDR_W:0]                       cnt_q;

  wire do_push = push_valid_i & push_ready_o;
  wire do_pop  = pop_valid_o  & pop_ready_i;

  assign push_ready_o = (cnt_q < FIFO_DEPTH[ADDR_W:0]);
  assign pop_valid_o  = (cnt_q != '0);
  assign pop_data_o   = data_q[rptr_q];
  assign pop_strb_o   = strb_q[rptr_q];

  assign flags_o.empty        = (cnt_q == '0);
  assign flags_o.full         = (cnt_q == FIFO_DEPTH[ADDR_W:0]);
  assign flags_o.almost_empty = (cnt_q == {{ADDR_W{1'b0}}, 1'b1});
  assign flags_o.almost_full  = (cnt_q == FIFO_DEPTH[ADDR_W:0] - 1'b1);
  assign flags_o.push_pointer = 8'(wptr_q);
  assign flags_o.pop_pointer  = 8'(rptr_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      data_q <= '0;
      strb_q <= '0;
      wptr_q <= '0;
      rptr_q <= '0;
      cnt_q  <= '0;
    end else if (clear_i) begin
      wptr_q <= '0;
      rptr_q <= '0;
      cnt_q  <= '0;
    end else begin
      if (do_push) begin
        data_q[wptr_q] <= push_data_i;
        strb_q[wptr_q] <= push_strb_i;
        wptr_q         <= (wptr_q == ADDR_W'(FIFO_DEPTH - 1)) ? '0 : (wptr_q + 1'b1);
      end
      if (do_pop) begin
        rptr_q <= (rptr_q == ADDR_W'(FIFO_DEPTH - 1)) ? '0 : (rptr_q + 1'b1);
      end
      case ({do_push, do_pop})
        2'b10:   cnt_q <= cnt_q + 1'b1;
        2'b01:   cnt_q <= cnt_q - 1'b1;
        default: cnt_q <= cnt_q;
      endcase
    end
  end

endmodule : hwpe_stream_fifo
