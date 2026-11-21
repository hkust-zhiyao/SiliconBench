// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Andrea Belano <andrea.belano2@unibo.it>
//

module redmule_x_buffer_scm
  import redmule_pkg::*;
#(
  parameter int unsigned WORD_SIZE    = 32,
  parameter int unsigned WIDTH        = 1 ,
  parameter int unsigned HEIGHT       = 2 ,
  parameter int unsigned N_OUTPUTS    = 1 ,
  parameter int unsigned USE_LATCHES  = 0 ,
  localparam int unsigned ROW_BITS    = $clog2(N_OUTPUTS),
  localparam int unsigned SLOT_BITS   = $clog2(HEIGHT),
  localparam int unsigned SLOT_ADDR_W = (SLOT_BITS > 0) ? SLOT_BITS : 1,
  localparam int unsigned ADDR_W      = ((ROW_BITS + SLOT_BITS) > 0) ? (ROW_BITS + SLOT_BITS) : 1
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
  logic [HEIGHT-1:0][N_OUTPUTS-1:0][WIDTH-1:0][WORD_SIZE-1:0] buffer_q;
  logic [WIDTH-1:0][WORD_SIZE-1:0]                            wdata_q;
  logic [N_OUTPUTS-1:0][SLOT_ADDR_W-1:0]                      read_addr_q;
  logic [HEIGHT-1:0][N_OUTPUTS-1:0]                           entry_valid_q;

  logic [N_OUTPUTS-1:0]                                       row_w_sel;
  logic [N_OUTPUTS-1:0]                                       row_r_sel;
  logic [SLOT_ADDR_W-1:0]                                     slot_w_addr;
  logic [SLOT_ADDR_W-1:0]                                     slot_r_addr;

  logic [HEIGHT-1:0][N_OUTPUTS-1:0]                           clk_w;

  if (SLOT_BITS > 0) begin : gen_multi_slot_addr
    assign slot_w_addr = write_addr_i[ROW_BITS +: SLOT_BITS];
    assign slot_r_addr = read_addr_i[ROW_BITS +: SLOT_BITS];
  end else begin : gen_single_slot_addr
    assign slot_w_addr = '0;
    assign slot_r_addr = '0;
  end

  for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_row_match
    if (N_OUTPUTS > 1) begin : gen_multi_out
      assign row_w_sel[o] = (write_addr_i[ROW_BITS-1:0] == ROW_BITS'(o));
      assign row_r_sel[o] = (read_addr_i[ROW_BITS-1:0] == ROW_BITS'(o));
    end else begin : gen_single_out
      assign row_w_sel[o] = 1'b1;
      assign row_r_sel[o] = 1'b1;
    end
  end

  for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_read_addr_registers
    always_ff @(posedge clk_i or negedge rst_ni) begin : sample_raddr
      if (~rst_ni) begin
        read_addr_q[o] <= '0;
      end else begin
        if (clear_i) begin
          read_addr_q[o] <= '0;
        end else if (read_en_i && row_r_sel[o]) begin
          read_addr_q[o] <= slot_r_addr;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : track_entry_valid
    if (~rst_ni) begin
      entry_valid_q <= '0;
    end else begin
      if (clear_i) begin
        entry_valid_q <= '0;
      end else if (write_en_i) begin
        for (int unsigned h = 0; h < HEIGHT; h++) begin
          for (int unsigned o = 0; o < N_OUTPUTS; o++) begin
            if ((slot_w_addr == SLOT_ADDR_W'(h)) && row_w_sel[o]) begin
              entry_valid_q[h][o] <= 1'b1;
            end
          end
        end
      end
    end
  end

  for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_output_assignment
    if (HEIGHT > 1) begin : gen_multi_slot_out
      assign rdata_o[o] = entry_valid_q[read_addr_q[o]][o] ? buffer_q[read_addr_q[o]][o] : '0;
    end else begin : gen_single_slot_out
      assign rdata_o[o] = entry_valid_q[0][o] ? buffer_q[0][o] : '0;
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
    for (genvar h = 0; h < HEIGHT; h++) begin : gen_slots_cg
      for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_rows_cg
        tc_clk_gating i_row_cg (
          .clk_i     ( clk_i                                                                  ),
          .en_i      ( (row_w_sel[o] && (slot_w_addr == SLOT_ADDR_W'(h)) && write_en_i) || clear_i ),
          .test_en_i ( 1'b0                                                                   ),
          .clk_o     ( clk_w[h][o]                                                            )
        );
      end
    end

    for (genvar h = 0; h < HEIGHT; h++) begin : gen_slots
      for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_rows
        always_latch begin : wdata
          if (clk_w[h][o]) begin
            buffer_q[h][o] = wdata_q;
          end
        end
      end
    end
  end else begin : gen_flip_flops
    for (genvar h = 0; h < HEIGHT; h++) begin : gen_slots
      for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_rows
        always_ff @(posedge clk_i or negedge rst_ni) begin : wdata
          if (~rst_ni) begin
            buffer_q[h][o] <= '0;
          end else begin
            if (clear_i) begin
              buffer_q[h][o] <= '0;
            end else if (row_w_sel[o] && (slot_w_addr == SLOT_ADDR_W'(h)) && write_en_i) begin
              buffer_q[h][o] <= wdata_i;
            end
          end
        end
      end
    end
  end

endmodule : redmule_x_buffer_scm
