// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_tiler
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
#(
  parameter int unsigned DataW     = 0,
  parameter int unsigned Height    = MaxDim,
  parameter int unsigned Width     = MaxDim,
  parameter int unsigned PipeRegs  = MaxPipeRegs-1,
  parameter int unsigned FpWidth   = 16,
  parameter int unsigned AddrWidth = 32
) (
  input  logic            clk_i      ,
  input  logic            rst_ni     ,
  input  logic            clear_i    ,
  input  logic            setback_i  ,
  input  logic            loopback_i ,
  input  logic            start_cfg_i,
  output logic            valid_o    ,
  output logic            busy_o     ,
  input  logic            ready_i    ,
  input  redmule_config_t config_i   ,
  output redmule_config_t config_o
);

  localparam int unsigned MinimumSizeN = MinimumSizeNFactor * Height;
  localparam int unsigned TileDepth    = Height * (PipeRegs + 1);
  localparam int unsigned ElemBytes    = FpWidth / 8;

  typedef enum logic [1:0] {
    TILER_IDLE,
    TILER_STAGE1,
    TILER_STAGE2,
    TILER_HOLD
  } tiler_state_e;

  tiler_state_e    state_q, state_d;
  logic            clk_en, clk_int;
  logic            is_loopback_q;
  redmule_config_t latched_cfg_q, src_cfg;
  redmule_config_t assembled_cfg, config_q;

  logic [31:0] tiles_mn_q, yz_words_q;
  logic [31:0] tot_x_words_q, tot_w_words_q;

  assign clk_en = (state_q != TILER_IDLE) || (start_cfg_i && ready_i && !is_loopback_q) || loopback_i;
  assign busy_o = (state_q != TILER_IDLE) || ~ready_i;

  tc_clk_gating i_tiler_clockg (
    .clk_i     ( clk_i            ),
    .en_i      ( clk_en | clear_i ),
    .test_en_i ( 1'b0             ),
    .clk_o     ( clk_int          )
  );

  always_comb begin
    state_d = state_q;
    case (state_q)
      TILER_IDLE: begin
        if (loopback_i || (start_cfg_i && ready_i && !is_loopback_q)) begin
          state_d = TILER_STAGE1;
        end
      end
      TILER_STAGE1: state_d = TILER_STAGE2;
      TILER_STAGE2: state_d = TILER_HOLD;
      TILER_HOLD: begin
        if (setback_i) begin
          state_d = TILER_IDLE;
        end
      end
      default: state_d = TILER_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      state_q       <= TILER_IDLE;
      is_loopback_q <= 1'b0;
      latched_cfg_q <= '0;
    end else if (clear_i) begin
      state_q       <= TILER_IDLE;
      is_loopback_q <= 1'b0;
      latched_cfg_q <= '0;
    end else begin
      state_q <= setback_i ? TILER_IDLE : state_d;
      if (setback_i) begin
        is_loopback_q <= 1'b0;
      end else if (loopback_i) begin
        is_loopback_q <= 1'b1;
      end
      if (state_q == TILER_IDLE && !loopback_i && !is_loopback_q && start_cfg_i && ready_i) begin
        latched_cfg_q <= config_i;
      end
    end
  end

  wire use_loopback = loopback_i || is_loopback_q;
  assign src_cfg    = (use_loopback || state_q != TILER_IDLE) ? latched_cfg_q : config_i;

  logic [15:0] eff_n_rows, eff_k_cols;
  logic [15:0] m_quo, n_quo, k_quo, nr_quo;
  logic [7:0]  m_rem, n_rem, k_rem, nr_rem;
  logic [15:0] m_tiles, n_tiles, k_tiles, w_row_steps;
  logic [31:0] offs_bytes;

  assign eff_n_rows = (src_cfg.n_size <= Height) ? MinimumSizeN[15:0] : src_cfg.n_size;
  assign eff_k_cols = use_loopback ? src_cfg.w_cols_offset : (src_cfg.k_size - src_cfg.w_cols_offset);
  assign offs_bytes = use_loopback ? 32'd0 : (32'(src_cfg.w_cols_offset) * ElemBytes);

  assign m_quo  = src_cfg.m_size / Width[15:0];
  assign m_rem  = 8'(src_cfg.m_size - (m_quo * Width[15:0]));
  assign m_tiles = (m_rem != 8'd0) ? (m_quo + 16'd1) : m_quo;

  assign n_quo  = src_cfg.n_size / TileDepth[15:0];
  assign n_rem  = 8'(src_cfg.n_size - (n_quo * TileDepth[15:0]));
  assign n_tiles = (n_rem != 8'd0) ? (n_quo + 16'd1) : n_quo;

  assign k_quo  = eff_k_cols / TileDepth[15:0];
  assign k_rem  = 8'(eff_k_cols - (k_quo * TileDepth[15:0]));
  assign k_tiles = (k_rem != 8'd0) ? (k_quo + 16'd1) : k_quo;

  assign nr_quo     = eff_n_rows / Height[15:0];
  assign nr_rem     = 8'(eff_n_rows - (nr_quo * Height[15:0]));
  assign w_row_steps = (nr_rem != 8'd0) ? (eff_n_rows + Height[15:0] - 16'(nr_rem)) : eff_n_rows;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      tiles_mn_q    <= '0;
      yz_words_q    <= '0;
      tot_x_words_q <= '0;
      tot_w_words_q <= '0;
    end else if (clear_i || setback_i) begin
      tiles_mn_q    <= '0;
      yz_words_q    <= '0;
      tot_x_words_q <= '0;
      tot_w_words_q <= '0;
    end else begin
      if (state_q == TILER_IDLE && state_d == TILER_STAGE1) begin
        tiles_mn_q <= 32'(m_tiles) * 32'(k_tiles);
        yz_words_q <= 32'(src_cfg.m_size) * 32'(k_tiles);
      end else if (state_q == TILER_STAGE1) begin
        tot_x_words_q <= tiles_mn_q * 32'(n_tiles);
        tot_w_words_q <= tiles_mn_q * 32'(w_row_steps);
      end
    end
  end

  logic [31:0] slot_groups;
  assign slot_groups = 32'(n_rem) / Height;

  always_comb begin
    assembled_cfg                  = '0;
    assembled_cfg.x_addr           = src_cfg.x_addr;
    assembled_cfg.w_addr           = src_cfg.w_addr + offs_bytes;
    assembled_cfg.z_addr           = src_cfg.z_addr + offs_bytes;
    assembled_cfg.y_addr           = src_cfg.z_addr + src_cfg.y_offs + offs_bytes;
    assembled_cfg.m_size           = src_cfg.m_size;
    assembled_cfg.n_size           = src_cfg.n_size;
    assembled_cfg.k_size           = src_cfg.k_size;
    assembled_cfg.y_offs           = src_cfg.y_offs;
    assembled_cfg.gemm_ops         = src_cfg.gemm_ops;
    assembled_cfg.gemm_input_fmt   = src_cfg.gemm_input_fmt;
    assembled_cfg.gemm_output_fmt  = src_cfg.gemm_output_fmt;
    assembled_cfg.x_cols_iter      = n_tiles;
    assembled_cfg.x_rows_iter      = m_tiles;
    assembled_cfg.w_cols_iter      = k_tiles;
    assembled_cfg.w_rows_iter      = w_row_steps;
    assembled_cfg.w_cols_offset    = use_loopback ? 16'd0 : src_cfg.w_cols_offset;
    assembled_cfg.x_cols_lftovr    = n_rem;
    assembled_cfg.x_rows_lftovr    = m_rem;
    assembled_cfg.w_cols_lftovr    = k_rem;
    assembled_cfg.w_rows_lftovr    = nr_rem;
    assembled_cfg.tot_stores       = tiles_mn_q[15:0];
    assembled_cfg.x_d1_stride      = ElemBytes * 32'(src_cfg.n_size);
    assembled_cfg.x_rows_offs      = Width * assembled_cfg.x_d1_stride;
    assembled_cfg.w_tot_len        = tot_w_words_q;
    assembled_cfg.tot_x_read       = tot_x_words_q;
    assembled_cfg.w_d0_stride      = ElemBytes * 32'(src_cfg.k_size);
    assembled_cfg.yz_tot_len       = yz_words_q;
    assembled_cfg.yz_d0_stride     = assembled_cfg.w_d0_stride;
    assembled_cfg.yz_d2_stride     = Width * assembled_cfg.w_d0_stride;
    assembled_cfg.x_buffer_slots   = ((32'(n_rem) % Height != 0) ? (slot_groups + 32'd1) : slot_groups) * Height;
    assembled_cfg.x_tot_len        = '0;

    assembled_cfg.stage_1_rnd_mode = (src_cfg.gemm_ops == MAXMIN) ? RTZ : RNE;
    assembled_cfg.stage_2_rnd_mode = (src_cfg.gemm_ops == ADDMAX || src_cfg.gemm_ops == MULMAX || src_cfg.gemm_ops == MINMAX) ? RTZ : RNE;
    unique case (src_cfg.gemm_ops)
      MATMUL, GEMM:   assembled_cfg.stage_1_op = FPU_FMADD;
      ADDMAX, ADDMIN: assembled_cfg.stage_1_op = FPU_ADD;
      MULMAX, MULMIN: assembled_cfg.stage_1_op = FPU_MUL;
      default:        assembled_cfg.stage_1_op = FPU_MINMAX;
    endcase
    assembled_cfg.stage_2_op       = FPU_MINMAX;
    unique case (src_cfg.gemm_input_fmt)
      Float16:    assembled_cfg.input_format = FPU_FP16;
      Float8:     assembled_cfg.input_format = FPU_FP8;
      Float16Alt: assembled_cfg.input_format = FPU_FP16ALT;
      default:    assembled_cfg.input_format = FPU_FP8ALT;
    endcase
    unique case (src_cfg.gemm_output_fmt)
      Float16:    assembled_cfg.computing_format = FPU_FP16;
      Float8:     assembled_cfg.computing_format = FPU_FP8;
      Float16Alt: assembled_cfg.computing_format = FPU_FP16ALT;
      default:    assembled_cfg.computing_format = FPU_FP8ALT;
    endcase
    assembled_cfg.gemm_selection   = (src_cfg.gemm_ops != MATMUL);
    assembled_cfg.loopback_w       = use_loopback;
    assembled_cfg.send_w           = src_cfg.send_w;
    assembled_cfg.receive_w        = src_cfg.receive_w;
    assembled_cfg.send_x           = src_cfg.send_x;
    assembled_cfg.receive_x        = src_cfg.receive_x;
  end

  always_ff @(posedge clk_int or negedge rst_ni) begin
    if (~rst_ni) begin
      config_q <= '0;
      valid_o  <= 1'b0;
    end else if (clear_i) begin
      config_q <= '0;
      valid_o  <= 1'b0;
    end else if (setback_i) begin
      valid_o  <= 1'b0;
    end else if (state_q == TILER_STAGE2) begin
      config_q <= assembled_cfg;
      valid_o  <= 1'b1;
    end
  end

  assign config_o = config_q;

  wire unused_params = |{DataW, AddrWidth};

endmodule : redmule_tiler
