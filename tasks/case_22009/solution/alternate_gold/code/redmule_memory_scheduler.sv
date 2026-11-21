// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_memory_scheduler
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
#(
  parameter int unsigned   DW   = MaxDataW,
  parameter int unsigned   W    = MaxDim,
  parameter int unsigned   H    = MaxDim,
  parameter int unsigned   ELW  = 16,
  localparam int unsigned  D    = DW/ELW
) (
  input  logic                   clk_i            ,
  input  logic                   rst_ni           ,
  input  logic                   clear_i          ,
  input  logic                   z_priority_i     ,
  input  redmule_config_t        config_i         ,
  input  logic                   config_valid_i   ,
  input  flgs_streamer_t         flgs_streamer_i  ,
  input  cntrl_scheduler_t       cntrl_scheduler_i,
  input  cntrl_flags_t           cntrl_flags_i    ,
  output logic                   z_fifo_empty_o   ,
  output logic                   z_fifo_full_o    ,
  output logic                   x_done_o         ,
  output cntrl_streamer_t        cntrl_streamer_o
);
  localparam int unsigned JMP = DW / 8;

  redmule_config_t x_cfg, w_cfg, y_cfg, z_cfg;
  logic            x_empty, w_empty, y_empty, z_empty;
  logic            x_full,  w_full,  y_full,  z_full;

  logic fifo_rst;
  assign fifo_rst = clear_i | cntrl_scheduler_i.rst;

  // Per-tile 1D stepping state for X, Y, and Z (zero multipliers required)
  logic [15:0] x_col_q, x_wcol_q, x_row_q;
  logic [31:0] x_tot_q, x_col_off_q, x_row_off_q;

  logic [15:0] y_col_q, y_row_q, y_tile_q;
  logic [31:0] y_col_off_q, y_row_off_q;

  logic [15:0] z_col_q, z_row_q, z_tile_q;
  logic [31:0] z_col_off_q, z_row_off_q;

  logic y_all_done, z_all_done, y_pop;

  assign x_done_o   = ~x_empty && (x_tot_q == x_cfg.tot_x_read - 1) && flgs_streamer_i.x_stream_source_flags.done;
  assign y_all_done = ~y_empty && (y_tile_q == y_cfg.tot_stores - 1) && flgs_streamer_i.y_stream_source_flags.done;
  assign z_all_done = ~z_empty && (z_tile_q == z_cfg.tot_stores - 1) && flgs_streamer_i.z_stream_sink_flags.done;
  assign y_pop      = ~y_empty && (y_cfg.gemm_selection ? y_all_done : z_all_done);

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_x_config_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(fifo_rst), .testmode_i('0),
    .full_o(x_full), .empty_o(x_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(x_cfg), .pop_i(x_done_o)
  );

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_w_config_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(fifo_rst), .testmode_i('0),
    .full_o(w_full), .empty_o(w_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(w_cfg),
    .pop_i(~w_empty && flgs_streamer_i.w_stream_source_flags.done)
  );

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_y_config_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(fifo_rst), .testmode_i('0),
    .full_o(y_full), .empty_o(y_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(y_cfg), .pop_i(y_pop)
  );

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_z_config_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(fifo_rst), .testmode_i('0),
    .full_o(z_full), .empty_o(z_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(z_cfg), .pop_i(z_all_done)
  );

  assign z_fifo_empty_o = z_empty;
  assign z_fifo_full_o  = z_full || ~z_empty || ~cntrl_flags_i.idle;

  // X tile stepping
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      x_col_q     <= '0;
      x_wcol_q    <= '0;
      x_row_q     <= '0;
      x_tot_q     <= '0;
      x_col_off_q <= '0;
      x_row_off_q <= '0;
    end else if (fifo_rst || x_done_o) begin
      x_col_q     <= '0;
      x_wcol_q    <= '0;
      x_row_q     <= '0;
      x_tot_q     <= '0;
      x_col_off_q <= '0;
      x_row_off_q <= '0;
    end else if (flgs_streamer_i.x_stream_source_flags.done) begin
      x_tot_q <= x_tot_q + 32'd1;
      if (x_col_q == x_cfg.x_cols_iter - 1) begin
        x_col_q     <= '0;
        x_col_off_q <= '0;
        if (x_wcol_q == x_cfg.w_cols_iter - 1) begin
          x_wcol_q    <= '0;
          x_row_q     <= x_row_q + 16'd1;
          x_row_off_q <= x_row_off_q + x_cfg.x_rows_offs;
        end else begin
          x_wcol_q <= x_wcol_q + 16'd1;
        end
      end else begin
        x_col_q     <= x_col_q + 16'd1;
        x_col_off_q <= x_col_off_q + JMP;
      end
    end
  end

  // Y per-tile 1D stepping (col_tile inside row_block)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      y_col_q     <= '0;
      y_row_q     <= '0;
      y_tile_q    <= '0;
      y_col_off_q <= '0;
      y_row_off_q <= '0;
    end else if (fifo_rst || y_pop) begin
      y_col_q     <= '0;
      y_row_q     <= '0;
      y_tile_q    <= '0;
      y_col_off_q <= '0;
      y_row_off_q <= '0;
    end else if (flgs_streamer_i.y_stream_source_flags.done) begin
      y_tile_q <= y_tile_q + 16'd1;
      if (y_col_q == y_cfg.w_cols_iter - 1) begin
        y_col_q     <= '0;
        y_col_off_q <= '0;
        y_row_q     <= y_row_q + 16'd1;
        y_row_off_q <= y_row_off_q + y_cfg.yz_d2_stride;
      end else begin
        y_col_q     <= y_col_q + 16'd1;
        y_col_off_q <= y_col_off_q + JMP;
      end
    end
  end

  // Z per-tile 1D stepping (col_tile inside row_block)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      z_col_q     <= '0;
      z_row_q     <= '0;
      z_tile_q    <= '0;
      z_col_off_q <= '0;
      z_row_off_q <= '0;
    end else if (fifo_rst || z_all_done) begin
      z_col_q     <= '0;
      z_row_q     <= '0;
      z_tile_q    <= '0;
      z_col_off_q <= '0;
      z_row_off_q <= '0;
    end else if (flgs_streamer_i.z_stream_sink_flags.done) begin
      z_tile_q <= z_tile_q + 16'd1;
      if (z_col_q == z_cfg.w_cols_iter - 1) begin
        z_col_q     <= '0;
        z_col_off_q <= '0;
        z_row_q     <= z_row_q + 16'd1;
        z_row_off_q <= z_row_off_q + z_cfg.yz_d2_stride;
      end else begin
        z_col_q     <= z_col_q + 16'd1;
        z_col_off_q <= z_col_off_q + JMP;
      end
    end
  end

  logic [$clog2(W):0] x_cur_rows, y_cur_rows, z_cur_rows;
  assign x_cur_rows = (x_row_q == x_cfg.x_rows_iter - 1 && x_cfg.x_rows_lftovr != '0) ? x_cfg.x_rows_lftovr[$clog2(W):0] : W[$clog2(W):0];
  assign y_cur_rows = (y_row_q == y_cfg.x_rows_iter - 1 && y_cfg.x_rows_lftovr != '0) ? y_cfg.x_rows_lftovr[$clog2(W):0] : W[$clog2(W):0];
  assign z_cur_rows = (z_row_q == z_cfg.x_rows_iter - 1 && z_cfg.x_rows_lftovr != '0) ? z_cfg.x_rows_lftovr[$clog2(W):0] : W[$clog2(W):0];

  logic start_x;
  assign start_x = (~x_empty && ~x_full && ~x_done_o) || x_full;

  always_comb begin
    cntrl_streamer_o = '0;

    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.base_addr     = x_cfg.x_addr + x_row_off_q + x_col_off_q;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.tot_len       = x_cur_rows;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d0_len        = 'd1;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d0_stride     = 'd0;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d1_len        = W;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.d1_stride     = x_cfg.x_d1_stride;
    cntrl_streamer_o.x_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 3'b011;

    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.base_addr     = w_cfg.w_addr;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.tot_len       = w_cfg.w_tot_len;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_len        = w_cfg.w_rows_iter;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d0_stride     = w_cfg.w_d0_stride;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d1_len        = w_cfg.w_cols_iter;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.d1_stride     = JMP;
    cntrl_streamer_o.w_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 3'b011;

    // 1D per-tile Y transfer (exact row count for current row-block)
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.base_addr     = y_cfg.y_addr + y_row_off_q + y_col_off_q;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.tot_len       = y_cur_rows;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_len        = y_cur_rows;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d0_stride     = y_cfg.yz_d0_stride;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d1_len        = 'd1;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.d1_stride     = JMP;
    cntrl_streamer_o.y_stream_source_ctrl.addressgen_ctrl.dim_enable_1h = 3'b000;

    // 1D per-tile Z transfer (exact row count for current row-block)
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.base_addr       = z_cfg.z_addr + z_row_off_q + z_col_off_q;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.tot_len         = z_cur_rows;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_len          = z_cur_rows;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d0_stride       = z_cfg.yz_d0_stride;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d1_len          = 'd1;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.d1_stride       = JMP;
    cntrl_streamer_o.z_stream_sink_ctrl.addressgen_ctrl.dim_enable_1h   = 3'b000;

    cntrl_streamer_o.x_stream_source_ctrl.req_start = (start_x || (x_tot_q != '0 && x_tot_q != x_cfg.tot_x_read)) && flgs_streamer_i.x_stream_source_flags.ready_start;
    cntrl_streamer_o.w_stream_source_ctrl.req_start = ~w_empty && flgs_streamer_i.w_stream_source_flags.ready_start;
    cntrl_streamer_o.y_stream_source_ctrl.req_start = ~y_empty && y_cfg.gemm_selection && flgs_streamer_i.y_stream_source_flags.ready_start;
    cntrl_streamer_o.z_stream_sink_ctrl.req_start   = ~z_empty && flgs_streamer_i.z_stream_sink_flags.ready_start && ~flgs_streamer_i.z_stream_sink_flags.done;

    cntrl_streamer_o.input_cast_src_fmt  = fpnew_pkg::fp_format_e'(config_i.input_format);
    cntrl_streamer_o.input_cast_dst_fmt  = fpnew_pkg::fp_format_e'(config_i.computing_format);
    cntrl_streamer_o.output_cast_src_fmt = fpnew_pkg::fp_format_e'(config_i.computing_format);
    cntrl_streamer_o.output_cast_dst_fmt = fpnew_pkg::fp_format_e'(config_i.input_format);

    cntrl_streamer_o.z_priority       = z_priority_i;
    cntrl_streamer_o.receive_w_stream = w_cfg.receive_w;
    cntrl_streamer_o.receive_x_stream = x_cfg.receive_x;
  end

  wire unused_alt_mem = |{w_full, y_full, H, D};

endmodule : redmule_memory_scheduler
