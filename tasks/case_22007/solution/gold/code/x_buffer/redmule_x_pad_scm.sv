// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Andrea Belano <andrea.belano2@unibo.it>
//

module redmule_x_pad_scm
  import redmule_pkg::*;
#(
  parameter int unsigned WORD_SIZE   = 32,
  parameter int unsigned ROWS        = 1 ,
  parameter int unsigned COLS        = 1 ,
  parameter int unsigned USE_LATCHES = 0 ,
  localparam int unsigned ROW_ADDR_W = (ROWS > 1) ? $clog2(ROWS) : 1,
  localparam int unsigned COL_ADDR_W = (COLS > 1) ? $clog2(COLS) : 1
) (
  input  logic                           clk_i        ,
  input  logic                           rst_ni       ,
  input  logic                           clear_i      ,
  input  logic                           write_en_i   ,
  input  logic [ROW_ADDR_W-1:0]          write_addr_i ,
  input  logic [COLS-1:0][WORD_SIZE-1:0] wdata_i      ,
  input  logic                           read_en_i    ,
  input  logic [COL_ADDR_W-1:0]          read_addr_i  ,
  output logic [ROWS-1:0][WORD_SIZE-1:0] rdata_o
);
  logic [ROWS-1:0][COLS-1:0][WORD_SIZE-1:0] buffer_q;
  logic [COLS-1:0][WORD_SIZE-1:0]           wdata_q;
  logic [COL_ADDR_W-1:0]                    read_addr_q;
  logic [ROWS-1:0]                          row_valid_q;
  logic [ROWS-1:0]                          row_w_sel;
  logic [ROWS-1:0]                          clk_w;

  for (genvar r = 0; r < ROWS; r++) begin : gen_row_sel
    if (ROWS > 1) begin : gen_multi_row
      assign row_w_sel[r] = (write_addr_i == ROW_ADDR_W'(r));
    end else begin : gen_single_row
      assign row_w_sel[r] = 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : sample_raddr
    if (~rst_ni) begin
      read_addr_q <= '0;
    end else begin
      if (clear_i) begin
        read_addr_q <= '0;
      end else if (read_en_i) begin
        read_addr_q <= (COLS > 1) ? read_addr_i : '0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : track_row_valid
    if (~rst_ni) begin
      row_valid_q <= '0;
    end else begin
      if (clear_i) begin
        row_valid_q <= '0;
      end else if (write_en_i) begin
        for (int unsigned r = 0; r < ROWS; r++) begin
          if (row_w_sel[r]) begin
            row_valid_q[r] <= 1'b1;
          end
        end
      end
    end
  end

  for (genvar r = 0; r < ROWS; r++) begin : gen_output_assignment
    if (COLS > 1) begin : gen_multi_col_out
      assign rdata_o[r] = row_valid_q[r] ? buffer_q[r][read_addr_q] : '0;
    end else begin : gen_single_col_out
      assign rdata_o[r] = row_valid_q[r] ? buffer_q[r][0] : '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : sample_wdata
    if (~rst_ni) begin
      wdata_q <= '0;
    end else begin
      if (clear_i) begin
        wdata_q <= '0;
      end else if (write_en_i) begin
        wdata_q <= wdata_i;
      end
    end
  end

  if (USE_LATCHES != 0) begin : gen_latches
    for (genvar r = 0; r < ROWS; r++) begin : gen_write_clock_gates
      tc_clk_gating i_rows_cg (
        .clk_i     ( clk_i                                ),
        .en_i      ( (row_w_sel[r] && write_en_i) || clear_i ),
        .test_en_i ( 1'b0                                 ),
        .clk_o     ( clk_w[r]                             )
      );
    end

    for (genvar r = 0; r < ROWS; r++) begin : gen_rows
      for (genvar c = 0; c < COLS; c++) begin : gen_cols
        always_latch begin : wdata
          if (clk_w[r]) begin
            buffer_q[r][c] = wdata_q[c];
          end
        end
      end
    end
  end else begin : gen_flip_flops
    for (genvar r = 0; r < ROWS; r++) begin : gen_rows
      for (genvar c = 0; c < COLS; c++) begin : gen_cols
        always_ff @(posedge clk_i or negedge rst_ni) begin : wdata
          if (~rst_ni) begin
            buffer_q[r][c] <= '0;
          end else begin
            if (clear_i) begin
              buffer_q[r][c] <= '0;
            end else if (row_w_sel[r] && write_en_i) begin
              buffer_q[r][c] <= wdata_i[c];
            end
          end
        end
      end
    end
  end

endmodule : redmule_x_pad_scm
