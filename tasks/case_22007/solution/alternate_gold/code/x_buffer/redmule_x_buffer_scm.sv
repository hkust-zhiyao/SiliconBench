// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_x_buffer_scm
  import redmule_pkg::*;
#(
  parameter int unsigned WORD_SIZE   = 32,
  parameter int unsigned WIDTH       = 1 ,
  parameter int unsigned HEIGHT      = 2 ,
  parameter int unsigned N_OUTPUTS   = 1 ,
  parameter int unsigned USE_LATCHES = 0 ,
  localparam int unsigned ROW_BITS   = $clog2(N_OUTPUTS),
  localparam int unsigned SLOT_BITS  = $clog2(HEIGHT),
  localparam int unsigned ADDR_W     = ((ROW_BITS + SLOT_BITS) > 0) ? (ROW_BITS + SLOT_BITS) : 1
) (
  input  logic                                           clk_i        ,
  input  logic                                           rst_ni       ,
  input  logic                                           clear_i      ,
  input  logic                                           write_en_i   ,
  input  logic [ADDR_W-1:0]                              write_addr_i ,
  input  logic [WIDTH-1:0][WORD_SIZE-1:0]                wdata_i      ,
  input  logic                                           read_en_i    ,
  input  logic [ADDR_W-1:0]                              read_addr_i  ,
  output logic [N_OUTPUTS-1:0][WIDTH-1:0][WORD_SIZE-1:0] rdata_o
);
  localparam int unsigned S_AW = (SLOT_BITS > 0) ? SLOT_BITS : 1;
  localparam int unsigned R_AW = (ROW_BITS > 0) ? ROW_BITS : 1;

  logic [HEIGHT-1:0][N_OUTPUTS-1:0][WIDTH-1:0][WORD_SIZE-1:0] storage_q;
  logic [WIDTH-1:0][WORD_SIZE-1:0]                            din_q;
  logic [N_OUTPUTS-1:0][S_AW-1:0]                             active_slot_q;
  logic [HEIGHT-1:0][N_OUTPUTS-1:0]                           slot_written_q;
  logic [HEIGHT-1:0][N_OUTPUTS-1:0]                           wr_cell_oh;
  logic [N_OUTPUTS-1:0]                                       rd_lane_oh;
  logic [S_AW-1:0]                                            wr_slot_idx, rd_slot_idx;
  logic [HEIGHT-1:0][N_OUTPUTS-1:0]                           gated_clk;

  if (SLOT_BITS > 0) begin : g_slot_extract
    assign wr_slot_idx = write_addr_i[ROW_BITS +: SLOT_BITS];
    assign rd_slot_idx = read_addr_i[ROW_BITS +: SLOT_BITS];
  end else begin : g_slot_zero
    assign wr_slot_idx = '0;
    assign rd_slot_idx = '0;
  end

  always_comb begin : decode_lanes
    wr_cell_oh = '0;
    rd_lane_oh = '0;
    for (int unsigned o = 0; o < N_OUTPUTS; o++) begin
      automatic logic lane_w_hit = (N_OUTPUTS == 1) ? 1'b1 : (write_addr_i[R_AW-1:0] == R_AW'(o));
      automatic logic lane_r_hit = (N_OUTPUTS == 1) ? 1'b1 : (read_addr_i[R_AW-1:0]  == R_AW'(o));
      rd_lane_oh[o] = lane_r_hit;
      for (int unsigned h = 0; h < HEIGHT; h++) begin
        if (lane_w_hit && (wr_slot_idx == S_AW'(h))) begin
          wr_cell_oh[h][o] = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : seq_state
    if (!rst_ni) begin
      active_slot_q  <= '0;
      slot_written_q <= '0;
      din_q          <= '0;
    end else if (clear_i) begin
      active_slot_q  <= '0;
      slot_written_q <= '0;
      din_q          <= '0;
    end else begin
      if (write_en_i) begin
        din_q          <= wdata_i;
        slot_written_q <= slot_written_q | wr_cell_oh;
      end
      if (read_en_i) begin
        for (int unsigned o = 0; o < N_OUTPUTS; o++) begin
          if (rd_lane_oh[o]) begin
            active_slot_q[o] <= rd_slot_idx;
          end
        end
      end
    end
  end

  if (USE_LATCHES != 0) begin : g_latch_scm
    for (genvar h = 0; h < HEIGHT; h++) begin : g_h
      for (genvar o = 0; o < N_OUTPUTS; o++) begin : g_o
        tc_clk_gating i_row_cg (
          .clk_i     ( clk_i                              ),
          .en_i      ( (write_en_i && wr_cell_oh[h][o]) || clear_i ),
          .test_en_i ( 1'b0                               ),
          .clk_o     ( gated_clk[h][o]                    )
        );
        always_latch begin
          if (gated_clk[h][o]) begin
            storage_q[h][o] = din_q;
          end
        end
      end
    end
  end else begin : g_ff_scm
    for (genvar h = 0; h < HEIGHT; h++) begin : g_h_ff
      for (genvar o = 0; o < N_OUTPUTS; o++) begin : g_o_ff
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            storage_q[h][o] <= '0;
          end else if (clear_i) begin
            storage_q[h][o] <= '0;
          end else if (write_en_i && wr_cell_oh[h][o]) begin
            storage_q[h][o] <= wdata_i;
          end
        end
      end
    end
  end

  always_comb begin : mux_outputs
    for (int unsigned o = 0; o < N_OUTPUTS; o++) begin
      rdata_o[o] = '0;
      for (int unsigned h = 0; h < HEIGHT; h++) begin
        if ((active_slot_q[o] == S_AW'(h)) && slot_written_q[h][o]) begin
          rdata_o[o] = storage_q[h][o];
        end
      end
    end
  end
endmodule : redmule_x_buffer_scm
