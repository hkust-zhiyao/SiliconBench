// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_x_pad_scm
  import redmule_pkg::*;
#(
  parameter int unsigned WORD_SIZE   = 32,
  parameter int unsigned ROWS        = 1 ,
  parameter int unsigned COLS        = 1 ,
  parameter int unsigned USE_LATCHES = 0
) (
  input  logic                                                  clk_i        ,
  input  logic                                                  rst_ni       ,
  input  logic                                                  clear_i      ,
  input  logic                                                  write_en_i   ,
  input  logic [((ROWS > 1) ? $clog2(ROWS) : 1)-1:0]            write_addr_i ,
  input  logic [COLS-1:0][WORD_SIZE-1:0]                        wdata_i      ,
  input  logic                                                  read_en_i    ,
  input  logic [((COLS > 1) ? $clog2(COLS) : 1)-1:0]            read_addr_i  ,
  output logic [ROWS-1:0][WORD_SIZE-1:0]                        rdata_o
);
  localparam int unsigned R_AW = (ROWS > 1) ? $clog2(ROWS) : 1;
  localparam int unsigned C_AW = (COLS > 1) ? $clog2(COLS) : 1;

  logic [ROWS-1:0][COLS-1:0][WORD_SIZE-1:0] mem_cells_q;
  logic [COLS-1:0][WORD_SIZE-1:0]           din_stage_q;
  logic [C_AW-1:0]                          rd_col_q;
  logic [ROWS-1:0]                          written_mask_q;
  logic [ROWS-1:0]                          wr_row_oh;
  logic [ROWS-1:0]                          gated_wr_clk;

  always_comb begin : decode_write_row
    wr_row_oh = '0;
    if (ROWS == 1) begin
      wr_row_oh[0] = 1'b1;
    end else begin
      for (int unsigned r = 0; r < ROWS; r++) begin
        if (write_addr_i == R_AW'(r)) begin
          wr_row_oh[r] = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : seq_ctrl_regs
    if (!rst_ni) begin
      rd_col_q       <= '0;
      written_mask_q <= '0;
      din_stage_q    <= '0;
    end else if (clear_i) begin
      rd_col_q       <= '0;
      written_mask_q <= '0;
      din_stage_q    <= '0;
    end else begin
      if (read_en_i) begin
        rd_col_q <= (COLS > 1) ? read_addr_i : '0;
      end
      if (write_en_i) begin
        din_stage_q    <= wdata_i;
        written_mask_q <= written_mask_q | wr_row_oh;
      end
    end
  end

  if (USE_LATCHES != 0) begin : g_latch_array
    for (genvar r = 0; r < ROWS; r++) begin : g_icg
      tc_clk_gating i_rows_cg (
        .clk_i     ( clk_i                         ),
        .en_i      ( (write_en_i && wr_row_oh[r]) || clear_i ),
        .test_en_i ( 1'b0                          ),
        .clk_o     ( gated_wr_clk[r]               )
      );
      for (genvar c = 0; c < COLS; c++) begin : g_latch_cell
        always_latch begin
          if (gated_wr_clk[r]) begin
            mem_cells_q[r][c] = din_stage_q[c];
          end
        end
      end
    end
  end else begin : g_ff_array
    for (genvar r = 0; r < ROWS; r++) begin : g_ff_row
      for (genvar c = 0; c < COLS; c++) begin : g_ff_col
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            mem_cells_q[r][c] <= '0;
          end else if (clear_i) begin
            mem_cells_q[r][c] <= '0;
          end else if (write_en_i && wr_row_oh[r]) begin
            mem_cells_q[r][c] <= wdata_i[c];
          end
        end
      end
    end
  end

  always_comb begin : mux_read_out
    for (int unsigned r = 0; r < ROWS; r++) begin
      if (!written_mask_q[r]) begin
        rdata_o[r] = '0;
      end else if (COLS == 1) begin
        rdata_o[r] = mem_cells_q[r][0];
      end else begin
        rdata_o[r] = '0;
        for (int unsigned c = 0; c < COLS; c++) begin
          if (rd_col_q == C_AW'(c)) begin
            rdata_o[r] = mem_cells_q[r][c];
          end
        end
      end
    end
  end
endmodule : redmule_x_pad_scm
