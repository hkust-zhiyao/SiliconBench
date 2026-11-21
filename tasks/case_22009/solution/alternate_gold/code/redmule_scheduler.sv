// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_scheduler
  import fpnew_pkg::*;
  import hci_package::*;
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
  import hwpe_stream_package::*;
#(
  parameter  int unsigned DataW       = MaxDataW      ,
  parameter  int unsigned FpWidth     = 16            ,
  parameter  int unsigned Height      = MaxDim        ,
  parameter  int unsigned Width       = MaxDim        ,
  parameter  int unsigned NumPipeRegs = MaxPipeRegs-1 ,
  localparam int unsigned D           = DataW/FpWidth ,
  localparam int unsigned H           = Height        ,
  localparam int unsigned W           = Width
)(
  input  logic                            clk_i             ,
  input  logic                            rst_ni            ,
  input  logic                            test_mode_i       ,
  input  logic                            clear_i           ,

  input  logic                            x_valid_i         ,
  input  logic                            w_valid_i         ,
  input  logic                            y_valid_i         ,
  input  logic                            z_ready_i         ,

  input  logic                            engine_flush_i    ,

  input  redmule_config_t                 config_i          ,
  input  logic                            config_valid_i    ,

  input  flgs_streamer_t                  flgs_streamer_i   ,
  input  x_buffer_flgs_t                  flgs_x_buffer_i   ,
  input  w_buffer_flgs_t                  flgs_w_buffer_i   ,
  input  z_buffer_flgs_t                  flgs_z_buffer_i   ,

  input  flgs_engine_t                    flgs_engine_i     ,
  input  cntrl_scheduler_t                cntrl_scheduler_i ,

  output logic                            reg_enable_o       ,
  output cntrl_engine_t                   cntrl_engine_o     ,
  output x_buffer_ctrl_t                  cntrl_x_buffer_o   ,
  output w_buffer_ctrl_t                  cntrl_w_buffer_o   ,
  output z_buffer_ctrl_t                  cntrl_z_buffer_o   ,
  output flgs_scheduler_t                 flgs_scheduler_o   ,

  output logic                            sync_o            ,
  input  logic                            sync_i
);

  typedef enum logic [1:0] {
    IDLE,
    PRELOAD,
    LOAD_W,
    WAIT
  } redmule_fsm_state_e;

  redmule_fsm_state_e current_state, next_state;

  logic ctrl_clr;
  assign ctrl_clr = clear_i | cntrl_scheduler_i.rst;

  logic start, stall_engine, first_load, start_computation, computing, x_refill, pushing_y;

  // X tile counters & config
  redmule_config_t x_config;
  logic            x_config_empty, x_config_full;
  logic [15:0]     x_cols_iter_d, x_cols_iter_q, x_w_iters_d, x_w_iters_q, x_rows_iter_d, x_rows_iter_q;
  logic            x_done, x_cols_iter_en, x_w_iters_en, x_rows_iter_en, x_done_en;

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_x_config_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(ctrl_clr), .testmode_i('0),
    .full_o(x_config_full), .empty_o(x_config_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(x_config), .pop_i(x_done_en && ~x_config_empty)
  );

  assign x_cols_iter_en = flgs_x_buffer_i.empty;
  assign x_cols_iter_d  = x_cols_iter_en ? (x_cols_iter_q == x_config.x_cols_iter-1 ? '0 : x_cols_iter_q + 1) : x_cols_iter_q;
  assign x_w_iters_en   = x_cols_iter_en && x_cols_iter_q == x_config.x_cols_iter-1;
  assign x_w_iters_d    = x_w_iters_en ? (x_w_iters_q == x_config.w_cols_iter-1 ? '0 : x_w_iters_q + 1) : x_w_iters_q;
  assign x_rows_iter_en = x_w_iters_q == x_config.w_cols_iter-1 && x_w_iters_en;
  assign x_rows_iter_d  = x_rows_iter_en ? (x_rows_iter_q == x_config.x_rows_iter-1 ? '0 : x_rows_iter_q + 1) : x_rows_iter_q;
  assign x_done_en      = x_rows_iter_en && x_rows_iter_q == x_config.x_rows_iter-1 && x_w_iters_q == x_config.w_cols_iter-1 && x_cols_iter_q == x_config.x_cols_iter-1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      x_cols_iter_q <= '0;
      x_w_iters_q   <= '0;
      x_rows_iter_q <= '0;
      x_done        <= 1'b0;
    end else if (ctrl_clr) begin
      x_cols_iter_q <= '0;
      x_w_iters_q   <= '0;
      x_rows_iter_q <= '0;
      x_done        <= 1'b0;
    end else begin
      if (x_cols_iter_en && ~x_done) x_cols_iter_q <= x_cols_iter_d;
      if (x_w_iters_en   && ~x_done) x_w_iters_q   <= x_w_iters_d;
      if (x_rows_iter_en && ~x_done) x_rows_iter_q <= x_rows_iter_d;
      if ((~x_done && x_config_full) || (x_done && config_valid_i))
        x_done <= 1'b0;
      else if (x_done_en)
        x_done <= 1'b1;
    end
  end

  logic [$clog2(H-1)-1:0] x_shift_cnt_q, x_shift_offs_q;
  logic                   x_reload_q, x_reload_en, x_reload_rst, x_empty;

  always_comb begin
    cntrl_x_buffer_o.height = (x_cols_iter_q == x_config.x_cols_iter-1 && x_config.x_cols_lftovr != '0)
                              ? x_config.x_cols_lftovr[$clog2(MaxDepth)-1:0] : D[$clog2(MaxDepth)-1:0];
    if (x_config.n_size <= H) begin
      cntrl_x_buffer_o.slots = D[$clog2(MaxDepth)-1:0];
    end else if (x_cols_iter_q == x_config.x_cols_iter-1 && x_config.x_cols_lftovr != '0) begin
      cntrl_x_buffer_o.slots = x_config.x_buffer_slots[$clog2(MaxDepth)-1:0];
    end else begin
      cntrl_x_buffer_o.slots = D[$clog2(MaxDepth)-1:0];
    end
    cntrl_x_buffer_o.width = (x_rows_iter_q == x_config.x_rows_iter-1 && x_config.x_rows_lftovr != '0)
                             ? x_config.x_rows_lftovr[$clog2(MaxDim)-1:0] : W[$clog2(MaxDim)-1:0];
    cntrl_x_buffer_o.h_shift     = (current_state == LOAD_W) && ~stall_engine;
    cntrl_x_buffer_o.pad_setup   = (current_state == PRELOAD) && (next_state == LOAD_W);
    cntrl_x_buffer_o.load        = (x_reload_q && ~x_reload_rst) && x_valid_i;
    cntrl_x_buffer_o.rst_w_index = (current_state == LOAD_W && (x_shift_cnt_q == H-1 || flgs_x_buffer_i.empty)) && flgs_x_buffer_i.full && ~stall_engine;
    cntrl_x_buffer_o.last_x      = x_done_en;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      x_shift_cnt_q  <= '0;
      x_shift_offs_q <= '0;
      x_reload_q     <= 1'b0;
      x_empty        <= 1'b0;
    end else if (ctrl_clr) begin
      x_shift_cnt_q  <= '0;
      x_shift_offs_q <= '0;
      x_reload_q     <= 1'b0;
      x_empty        <= 1'b0;
    end else begin
      if (flgs_x_buffer_i.full && flgs_x_buffer_i.empty) begin
        x_shift_cnt_q  <= '0;
        x_shift_offs_q <= x_shift_cnt_q + x_shift_offs_q;
      end else if (current_state == LOAD_W && ~stall_engine) begin
        x_shift_cnt_q <= (x_shift_cnt_q == H-1) ? '0 : (x_shift_cnt_q + 1);
      end

      if (x_reload_rst)     x_reload_q <= 1'b0;
      else if (x_reload_en) x_reload_q <= 1'b1;

      if (~flgs_x_buffer_i.full)                          x_empty <= 1'b0;
      else if (flgs_x_buffer_i.full && flgs_x_buffer_i.empty) x_empty <= 1'b1;
    end
  end

  assign x_reload_en  = start || x_cols_iter_en || (x_empty && ~flgs_x_buffer_i.full);
  assign x_reload_rst = flgs_x_buffer_i.full && ~x_reload_en;

  // W counters & helper function for valid row depth
  redmule_config_t w_config;
  logic            w_config_empty, w_config_full;
  logic [15:0]     w_cols_iter_q, w_rows_iter_q, w_mat_iters_q;
  logic            w_done, w_cols_iter_en, w_rows_iter_en, w_mat_iters_en, w_done_en;
  logic [$clog2(H):0] w_zero_cnt_q;

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_w_config_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(ctrl_clr), .testmode_i('0),
    .full_o(w_config_full), .empty_o(w_config_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(w_config), .pop_i(w_done_en && ~w_config_empty)
  );

  assign w_rows_iter_en = (current_state == LOAD_W) && w_valid_i && ~stall_engine;
  assign w_cols_iter_en = (w_rows_iter_q == w_config.w_rows_iter - 1) && w_rows_iter_en;
  assign w_mat_iters_en = (w_cols_iter_q == w_config.w_cols_iter - 1) && w_cols_iter_en;
  assign w_done_en      = w_mat_iters_en && (w_mat_iters_q == w_config.x_rows_iter - 1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      w_rows_iter_q <= '0;
      w_cols_iter_q <= '0;
      w_mat_iters_q <= '0;
      w_done        <= 1'b0;
      w_zero_cnt_q  <= '0;
    end else if (ctrl_clr) begin
      w_rows_iter_q <= '0;
      w_cols_iter_q <= '0;
      w_mat_iters_q <= '0;
      w_done        <= 1'b0;
      w_zero_cnt_q  <= '0;
    end else begin
      if (w_rows_iter_en && ~w_done) w_rows_iter_q <= (w_rows_iter_q == w_config.w_rows_iter - 1) ? '0 : (w_rows_iter_q + 1);
      if (w_cols_iter_en && ~w_done) w_cols_iter_q <= (w_cols_iter_q == w_config.w_cols_iter - 1) ? '0 : (w_cols_iter_q + 1);
      if (w_mat_iters_en && ~w_done) w_mat_iters_q <= (w_mat_iters_q == w_config.x_rows_iter - 1) ? '0 : (w_mat_iters_q + 1);

      if ((~w_done && w_config_full) || (w_done && config_valid_i))
        w_done <= 1'b0;
      else if (w_done_en)
        w_done <= 1'b1;

      if (w_done && current_state == LOAD_W && ~stall_engine && w_zero_cnt_q != H)
        w_zero_cnt_q <= w_zero_cnt_q + 1;
    end
  end

  function automatic logic [$clog2(MaxDim)-1:0] compute_w_valid_height(
    input redmule_config_t cfg,
    input logic [15:0]     row_idx
  );
    if (cfg.n_size <= H) begin
      return (row_idx < H) ? cfg.n_size[$clog2(MaxDim)-1:0] : '0;
    end else if (cfg.w_rows_lftovr != '0 && row_idx >= (cfg.w_rows_iter - H)) begin
      return cfg.w_rows_lftovr[$clog2(MaxDim)-1:0];
    end else begin
      return H[$clog2(MaxDim)-1:0];
    end
  endfunction

  always_comb begin
    cntrl_w_buffer_o.height   = compute_w_valid_height(w_config, w_rows_iter_q);
    cntrl_w_buffer_o.width    = (w_cols_iter_q == w_config.w_cols_iter - 1 && w_config.w_cols_lftovr != '0)
                                ? w_config.w_cols_lftovr[$clog2(MaxDepth)-1:0] : D[$clog2(MaxDepth)-1:0];
    cntrl_w_buffer_o.load     = (current_state == LOAD_W) && ~stall_engine && ~w_done;
    cntrl_w_buffer_o.shift    = (current_state == LOAD_W || current_state == WAIT) && ~stall_engine;
    cntrl_w_buffer_o.zero_set = '0;
    for (int unsigned i = 0; i < H; i++) begin
      if (w_done && w_zero_cnt_q > i) cntrl_w_buffer_o.zero_set[i] = 1'b1;
    end
  end

  // Y & Z tile tracking with lookahead-registered Z dimensions
  redmule_config_t y_config, y_config_fast, z_config_fast;
  logic            y_config_empty, y_config_full;
  logic            y_config_fast_empty, y_config_fast_full;
  logic            z_config_fast_empty, z_config_fast_full;

  logic [15:0] y_cols_iter_q, y_rows_iter_q, y_loads_cnt_q;
  logic        y_done_q, y_pushed_q, y_cols_iter_en, y_rows_iter_en, y_config_pop, y_config_fast_pop;

  logic [15:0] z_cols_iter_q, z_cols_iter_d, z_rows_iter_q, z_rows_iter_d;
  logic        z_store_retire, z_rows_iter_en, z_config_fast_pop;

  assign y_cols_iter_en    = flgs_z_buffer_i.empty && ~y_done_q;
  assign y_rows_iter_en    = (y_cols_iter_q == y_config.w_cols_iter - 1) && y_cols_iter_en;
  assign y_config_pop      = (y_rows_iter_q == y_config.x_rows_iter - 1) && y_rows_iter_en && ~y_config_empty;
  assign y_config_fast_pop = (y_loads_cnt_q == y_config_fast.tot_stores - 1) && y_pushed_q && ~y_config_fast_empty && ~stall_engine;

  assign z_store_retire    = flgs_z_buffer_i.empty && flgs_z_buffer_i.z_priority;
  assign z_cols_iter_d     = (z_cols_iter_q == z_config_fast.w_cols_iter - 1) ? '0 : (z_cols_iter_q + 1);
  assign z_rows_iter_en    = (z_cols_iter_q == z_config_fast.w_cols_iter - 1) && z_store_retire;
  assign z_rows_iter_d     = z_rows_iter_en ? ((z_rows_iter_q == z_config_fast.x_rows_iter - 1) ? '0 : (z_rows_iter_q + 1)) : z_rows_iter_q;
  assign z_config_fast_pop = (z_rows_iter_q == z_config_fast.x_rows_iter - 1) && z_rows_iter_en && ~z_config_fast_empty;

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_y_config_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(ctrl_clr), .testmode_i('0),
    .full_o(y_config_full), .empty_o(y_config_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(y_config), .pop_i(y_config_pop)
  );

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_y_config_fast_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(ctrl_clr), .testmode_i('0),
    .full_o(y_config_fast_full), .empty_o(y_config_fast_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(y_config_fast), .pop_i(y_config_fast_pop)
  );

  redmule_config_fifo #(.FALL_THROUGH(0), .DEPTH(2), .dtype(redmule_config_t)) i_z_config_fast_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(ctrl_clr), .testmode_i('0),
    .full_o(z_config_fast_full), .empty_o(z_config_fast_empty), .usage_o(),
    .data_i(config_i), .push_i(config_valid_i), .data_o(z_config_fast), .pop_i(z_config_fast_pop)
  );

  logic [$clog2(W):0] y_width, z_width_q;
  logic [$clog2(D):0] y_height, z_height_q, y_push_height;

  assign y_width  = (y_rows_iter_q == y_config.x_rows_iter - 1 && y_config.x_rows_lftovr != '0) ? y_config.x_rows_lftovr[$clog2(W):0] : W[$clog2(W):0];
  assign y_height = (y_cols_iter_q == y_config.w_cols_iter - 1 && y_config.w_cols_lftovr != '0) ? y_config.w_cols_lftovr[$clog2(D):0] : D[$clog2(D):0];

  logic [15:0] next_z_row_idx, next_z_col_idx;
  assign next_z_row_idx = start_computation ? 16'd0 : z_rows_iter_d;
  assign next_z_col_idx = start_computation ? 16'd0 : z_cols_iter_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      y_pushed_q    <= 1'b0;
      y_loads_cnt_q <= '0;
      y_done_q      <= 1'b0;
      y_cols_iter_q <= '0;
      y_rows_iter_q <= '0;
      z_cols_iter_q <= '0;
      z_rows_iter_q <= '0;
      z_width_q     <= '0;
      z_height_q    <= '0;
    end else if (ctrl_clr) begin
      y_pushed_q    <= 1'b0;
      y_loads_cnt_q <= '0;
      y_done_q      <= 1'b0;
      y_cols_iter_q <= '0;
      y_rows_iter_q <= '0;
      z_cols_iter_q <= '0;
      z_rows_iter_q <= '0;
      z_width_q     <= '0;
      z_height_q    <= '0;
    end else begin
      if (y_pushed_q && ~stall_engine) begin
        y_pushed_q    <= 1'b0;
        y_loads_cnt_q <= (y_loads_cnt_q < y_config_fast.tot_stores - 1) ? (y_loads_cnt_q + 1) : '0;
      end else if (flgs_z_buffer_i.y_pushed) begin
        y_pushed_q <= 1'b1;
      end

      if ((~y_done_q && y_config_full) || (y_done_q && config_valid_i))
        y_done_q <= 1'b0;
      else if (y_config_pop)
        y_done_q <= 1'b1;

      if (y_cols_iter_en) y_cols_iter_q <= (y_cols_iter_q == y_config.w_cols_iter - 1) ? '0 : (y_cols_iter_q + 1);
      if (y_rows_iter_en) y_rows_iter_q <= (y_rows_iter_q == y_config.x_rows_iter - 1) ? '0 : (y_rows_iter_q + 1);

      if (z_store_retire) begin
        z_cols_iter_q <= z_cols_iter_d;
        z_rows_iter_q <= z_rows_iter_d;
      end

      if (start_computation || z_store_retire) begin
        z_width_q  <= (next_z_row_idx == z_config_fast.x_rows_iter - 1 && z_config_fast.x_rows_lftovr != '0)
                      ? z_config_fast.x_rows_lftovr[$clog2(W):0] : W[$clog2(W):0];
        z_height_q <= (next_z_col_idx == z_config_fast.w_cols_iter - 1 && z_config_fast.w_cols_lftovr != '0)
                      ? z_config_fast.w_cols_lftovr[$clog2(D):0] : D[$clog2(D):0];
      end
    end
  end

  logic [$clog2(NumPipeRegs+1)-1:0] z_wait_counter_q, waits_cnt;
  logic [$clog2(D)-1:0]             z_avail_counter_q, y_push_counter_q;
  logic                             z_wait_en, z_wait_clr, z_avail_en, z_avail_clr, y_push_en, y_push_clr;

  assign z_wait_clr  = z_wait_en  && ~stall_engine && (z_wait_counter_q == NumPipeRegs);
  assign z_avail_clr = z_avail_en && ~stall_engine && (z_avail_counter_q == z_height_q - 1);
  assign y_push_clr  = y_push_en  && ~stall_engine && (y_push_counter_q == y_push_height - 1);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      z_wait_en         <= 1'b0;
      z_wait_counter_q  <= '0;
      z_avail_en        <= 1'b0;
      z_avail_counter_q <= '0;
      y_push_en         <= 1'b0;
      y_push_counter_q  <= '0;
      y_push_height     <= '0;
      waits_cnt         <= '0;
    end else if (ctrl_clr) begin
      z_wait_en         <= 1'b0;
      z_wait_counter_q  <= '0;
      z_avail_en        <= 1'b0;
      z_avail_counter_q <= '0;
      y_push_en         <= 1'b0;
      y_push_counter_q  <= '0;
      y_push_height     <= '0;
      waits_cnt         <= '0;
    end else begin
      if (z_wait_clr)          z_wait_en <= 1'b0;
      else if (w_cols_iter_en) z_wait_en <= 1'b1;

      if (z_wait_en && ~stall_engine)
        z_wait_counter_q <= (z_wait_counter_q == NumPipeRegs) ? '0 : (z_wait_counter_q + 1);

      if (z_avail_clr)     z_avail_en <= 1'b0;
      else if (z_wait_clr) z_avail_en <= 1'b1;

      if (z_avail_en && ~stall_engine)
        z_avail_counter_q <= (z_avail_counter_q == z_height_q - 1) ? '0 : (z_avail_counter_q + 1);

      if ((z_wait_en && ~stall_engine && z_wait_counter_q == NumPipeRegs - 1) || start_computation) begin
        y_push_en     <= 1'b1;
        y_push_height <= y_height;
      end else if (y_push_clr) begin
        y_push_en <= 1'b0;
      end

      if (y_push_en && ~stall_engine)
        y_push_counter_q <= (y_push_counter_q == y_push_height - 1) ? '0 : (y_push_counter_q + 1);

      if (~stall_engine && current_state != IDLE && current_state != PRELOAD)
        waits_cnt <= (waits_cnt == NumPipeRegs) ? '0 : (waits_cnt + 1);
    end
  end

  assign cntrl_z_buffer_o.ready         = z_ready_i;
  assign cntrl_z_buffer_o.y_valid       = y_valid_i && y_config.gemm_selection && ~y_done_q;
  assign cntrl_z_buffer_o.y_push_enable = y_push_en && ~stall_engine;
  assign cntrl_z_buffer_o.fill          = z_avail_en && reg_enable_o;
  assign cntrl_z_buffer_o.first_load    = (y_cols_iter_q == '0) && (y_rows_iter_q == '0);
  assign cntrl_z_buffer_o.is_biased     = y_config_fast.gemm_selection;
  assign cntrl_z_buffer_o.mask_y        = y_config_fast.gemm_selection;
  assign cntrl_z_buffer_o.y_width       = '0 | y_width;
  assign cntrl_z_buffer_o.y_height      = '0 | y_push_height;
  assign cntrl_z_buffer_o.z_width       = '0 | z_width_q;
  assign cntrl_z_buffer_o.z_height      = '0 | z_height_q;

  logic              reg_enable_q;
  logic [MaxDim-1:0] row_clk_en_d, row_clk_en_q;

  always_comb begin
    row_clk_en_d = '0;
    if (computing && ~stall_engine) begin
      for (int unsigned i = 0; i < W; i++) begin
        if (i < z_width_q) row_clk_en_d[i] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      reg_enable_q <= 1'b0;
      row_clk_en_q <= '0;
    end else if (ctrl_clr) begin
      reg_enable_q <= 1'b0;
      row_clk_en_q <= '0;
    end else begin
      reg_enable_q <= computing & ~stall_engine;
      row_clk_en_q <= row_clk_en_d;
    end
  end

  assign reg_enable_o                    = reg_enable_q;
  assign cntrl_engine_o.fma_is_boxed     = 3'b111;
  assign cntrl_engine_o.noncomp_is_boxed = 2'b11;
  assign cntrl_engine_o.stage1_rnd       = fpnew_pkg::roundmode_e'(config_i.stage_1_rnd_mode);
  assign cntrl_engine_o.stage2_rnd       = fpnew_pkg::roundmode_e'(config_i.stage_2_rnd_mode);
  assign cntrl_engine_o.op1              = fpnew_pkg::operation_e'(config_i.stage_1_op);
  assign cntrl_engine_o.op2              = fpnew_pkg::operation_e'(config_i.stage_2_op);
  assign cntrl_engine_o.op_mod           = 1'b0;
  assign cntrl_engine_o.in_valid         = 1'b1;
  assign cntrl_engine_o.flush            = engine_flush_i;
  assign cntrl_engine_o.out_ready        = 1'b1;
  assign cntrl_engine_o.accumulate       = ~pushing_y;
  assign cntrl_engine_o.row_clk_gate_en  = row_clk_en_q;

  logic check_x_full_en, check_y_loaded_en;
  assign check_x_full_en   = x_refill && (x_shift_cnt_q == (H - 1 - x_shift_offs_q)) && ~x_done;
  assign check_y_loaded_en = (z_wait_counter_q == NumPipeRegs) && ~w_done && y_config_fast.gemm_selection;

  assign stall_engine = (current_state == LOAD_W && ((~w_valid_i && ~w_done) || (~flgs_z_buffer_i.loaded && check_y_loaded_en)))
                     || (z_wait_counter_q == NumPipeRegs && flgs_z_buffer_i.z_priority)
                     || (current_state == WAIT && ~flgs_x_buffer_i.full && check_x_full_en);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      first_load    <= 1'b1;
      computing     <= 1'b0;
      x_refill      <= 1'b0;
      pushing_y     <= 1'b0;
      current_state <= IDLE;
    end else if (ctrl_clr) begin
      first_load    <= 1'b1;
      computing     <= 1'b0;
      x_refill      <= 1'b0;
      pushing_y     <= 1'b0;
      current_state <= IDLE;
    end else begin
      if (current_state == LOAD_W && ~stall_engine) first_load <= 1'b0;
      if (current_state == PRELOAD && next_state == LOAD_W) computing <= 1'b1;
      if (flgs_x_buffer_i.empty) x_refill <= 1'b1;
      else if (cntrl_x_buffer_o.rst_w_index) x_refill <= 1'b0;
      pushing_y     <= y_push_en;
      current_state <= next_state;
    end
  end

  assign start             = (current_state == IDLE) && cntrl_scheduler_i.first_load;
  assign start_computation = first_load && (next_state == LOAD_W) && ~stall_engine;

  always_comb begin
    flgs_scheduler_o          = '0;
    flgs_scheduler_o.w_loaded = (current_state == LOAD_W) && ~stall_engine;
  end

  logic is_tandem;
  assign is_tandem = y_config.send_w || y_config.send_x || y_config.receive_w || y_config.receive_x;
  assign sync_o    = (current_state == PRELOAD) && (y_config.gemm_selection ? (flgs_x_buffer_i.full && flgs_z_buffer_i.loaded) : flgs_x_buffer_i.full);

  wire drain_complete = w_done && z_avail_clr;

  always_comb begin
    next_state = current_state;
    case (current_state)
      IDLE: begin
        if (cntrl_scheduler_i.first_load) next_state = PRELOAD;
      end
      PRELOAD: begin
        if (flgs_x_buffer_i.full && (!y_config.gemm_selection || flgs_z_buffer_i.loaded) && (~is_tandem || sync_i))
          next_state = LOAD_W;
      end
      LOAD_W: begin
        if (drain_complete)     next_state = IDLE;
        else if (~stall_engine) next_state = WAIT;
      end
      WAIT: begin
        if (drain_complete)                               next_state = IDLE;
        else if (waits_cnt == NumPipeRegs && ~stall_engine) next_state = LOAD_W;
      end
    endcase
  end

  wire unused_alt_sched = |{test_mode_i, x_config_empty, w_config_empty, y_config_fast_full, z_config_fast_full, flgs_streamer_i, flgs_w_buffer_i, flgs_engine_i};

endmodule : redmule_scheduler
