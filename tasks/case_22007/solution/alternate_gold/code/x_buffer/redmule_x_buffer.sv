// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_x_buffer
  import fpnew_pkg::*;
  import redmule_pkg::*;
#(
  parameter int unsigned           DataW      = MaxDataW,
  parameter fpnew_pkg::fp_format_e FpFormat   = fpnew_pkg::FP16,
  parameter int unsigned           Height     = MaxDim,
  parameter int unsigned           Width      = MaxDim,
  parameter bit                    UseLatches = 0,
  localparam int unsigned          FpWidth    = fpnew_pkg::fp_width(FpFormat),
  localparam int unsigned          H          = Height,
  localparam int unsigned          W          = Width
)(
  input  logic                                       clk_i      ,
  input  logic                                       rst_ni     ,
  input  logic                                       clear_i    ,
  input  x_buffer_ctrl_t                             ctrl_i     ,
  output x_buffer_flgs_t                             flags_o    ,
  output logic           [W-1:0][H-1:0][FpWidth-1:0] x_buffer_o ,
  input  logic                           [DataW-1:0] x_buffer_i
);
  localparam int unsigned D          = DataW / (H * FpWidth);
  localparam int unsigned TOT_DEPTH  = H * D;
  localparam int unsigned W_AW       = (W > 1) ? $clog2(W) : 1;
  localparam int unsigned H_AW       = (H > 1) ? $clog2(H) : 1;
  localparam int unsigned PAD_AW     = (TOT_DEPTH > 1) ? $clog2(TOT_DEPTH) : 1;
  localparam int unsigned SCM_AW     = $clog2(H) + 1;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_ACTIVE_TILE,
    ST_WAIT_TILE
  } drain_state_e;

  drain_state_e                       state_q;
  logic [$clog2(W):0]                 rows_loaded_q;
  logic [$clog2(W):0]                 active_tile_rows_q;
  logic [$clog2(W):0]                 staged_tile_rows_q;
  logic                               unclaimed_tile_q;

  logic [31:0]                        wr_seq_q, rd_seq_q;
  logic [$clog2(TOT_DEPTH+1)-1:0]     col_cursor_q;
  logic [PAD_AW-1:0]                  pad_next_col;
  logic [PAD_AW-1:0]                  pad_rd_addr;
  logic                               pad_rd_en;

  logic [H_AW-1:0]                    wr_lane_q, rd_lane_q;
  logic                               wr_bank_q, rd_bank_q;
  logic [SCM_AW-1:0]                  scm_waddr, scm_raddr;

  logic [W-1:0][FpWidth-1:0]          pad_rdata;
  logic [W-1:0][FpWidth-1:0]          masked_col_data;
  logic [H-1:0][W-1:0][FpWidth-1:0]   scm_rdata;

  logic                               can_push_scm;
  logic                               push_scm;
  logic                               pop_scm;
  logic                               last_col_leaving;

  assign flags_o.full = (32'(rows_loaded_q) == 32'(ctrl_i.width));

  always_ff @(posedge clk_i or negedge rst_ni) begin : load_tracker
    if (!rst_ni) begin
      rows_loaded_q      <= '0;
      staged_tile_rows_q <= '0;
      unclaimed_tile_q   <= 1'b0;
    end else if (clear_i) begin
      rows_loaded_q      <= '0;
      staged_tile_rows_q <= '0;
      unclaimed_tile_q   <= 1'b0;
    end else begin
      if (ctrl_i.rst_w_index) begin
        rows_loaded_q <= '0;
      end else if (ctrl_i.load) begin
        rows_loaded_q      <= rows_loaded_q + 1'b1;
        staged_tile_rows_q <= (rows_loaded_q == '0) ? {{($clog2(W)){1'b0}}, 1'b1} : (rows_loaded_q + 1'b1);
      end

      // Track whether the currently full pad load has already been claimed by the drain FSM
      if (ctrl_i.pad_setup && flags_o.full) begin
        unclaimed_tile_q <= 1'b0;
      end else if ((state_q == ST_ACTIVE_TILE) && flags_o.empty && flags_o.full && unclaimed_tile_q) begin
        unclaimed_tile_q <= 1'b0;
      end else if ((state_q == ST_WAIT_TILE) && flags_o.full && unclaimed_tile_q) begin
        unclaimed_tile_q <= 1'b0;
      end else if (ctrl_i.load && !ctrl_i.rst_w_index && (32'(rows_loaded_q + 1'b1) == 32'(ctrl_i.width))) begin
        unclaimed_tile_q <= 1'b1;
      end
    end
  end

  // Monotonic sequence counters: first 2*H pushes fill virgin banks; thereafter occupancy <= H
  assign can_push_scm = (wr_seq_q < 32'(2 * H)) ||
                        ((wr_seq_q - rd_seq_q) < 32'(H)) ||
                        (((wr_seq_q - rd_seq_q) == 32'(H)) && ctrl_i.h_shift);

  assign push_scm = (state_q == ST_ACTIVE_TILE) && (32'(col_cursor_q) < 32'(ctrl_i.slots)) && can_push_scm;
  assign pop_scm  = ctrl_i.h_shift && ((wr_seq_q > rd_seq_q) || push_scm);

  assign last_col_leaving = (state_q == ST_ACTIVE_TILE) &&
                            ((32'(col_cursor_q) >= 32'(ctrl_i.slots)) ||
                             ((32'(col_cursor_q) + 32'd1 == 32'(ctrl_i.slots)) && push_scm));
  assign flags_o.empty    = last_col_leaving && ctrl_i.h_shift;

  always_ff @(posedge clk_i or negedge rst_ni) begin : drain_fsm_seq
    if (!rst_ni) begin
      state_q            <= ST_IDLE;
      active_tile_rows_q <= '0;
      col_cursor_q       <= '0;
      wr_seq_q           <= '0;
      rd_seq_q           <= '0;
    end else if (clear_i) begin
      state_q            <= ST_IDLE;
      active_tile_rows_q <= '0;
      col_cursor_q       <= '0;
      wr_seq_q           <= '0;
      rd_seq_q           <= '0;
    end else begin
      if (push_scm) wr_seq_q <= wr_seq_q + 32'd1;
      if (pop_scm)  rd_seq_q <= rd_seq_q + 32'd1;

      unique case (state_q)
        ST_IDLE: begin
          col_cursor_q <= '0;
          if (ctrl_i.pad_setup) begin
            if (flags_o.full && unclaimed_tile_q) begin
              state_q            <= ST_ACTIVE_TILE;
              active_tile_rows_q <= staged_tile_rows_q;
            end else begin
              state_q <= ST_WAIT_TILE;
            end
          end
        end
        ST_ACTIVE_TILE: begin
          if (ctrl_i.pad_setup) begin
            col_cursor_q       <= '0;
            active_tile_rows_q <= staged_tile_rows_q;
          end else if (flags_o.empty) begin
            col_cursor_q <= '0;
            if (flags_o.full && unclaimed_tile_q) begin
              state_q            <= ST_ACTIVE_TILE;
              active_tile_rows_q <= staged_tile_rows_q;
            end else begin
              state_q <= ST_WAIT_TILE;
            end
          end else if (push_scm) begin
            col_cursor_q <= col_cursor_q + 1'b1;
          end
        end
        ST_WAIT_TILE: begin
          col_cursor_q <= '0;
          if (flags_o.full && unclaimed_tile_q) begin
            state_q            <= ST_ACTIVE_TILE;
            active_tile_rows_q <= staged_tile_rows_q;
          end
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign pad_next_col = (32'(col_cursor_q) + 32'd1 < 32'(ctrl_i.slots)) ? PAD_AW'(col_cursor_q + 1'b1) : '0;
  assign pad_rd_en    = push_scm || ctrl_i.pad_setup || flags_o.empty;
  assign pad_rd_addr  = (ctrl_i.pad_setup || flags_o.empty) ? '0 : pad_next_col;

  redmule_x_pad_scm #(
    .WORD_SIZE   ( FpWidth    ),
    .ROWS        ( W          ),
    .COLS        ( TOT_DEPTH  ),
    .USE_LATCHES ( UseLatches )
  ) i_x_pad (
    .clk_i        ( clk_i                                     ),
    .rst_ni       ( rst_ni                                    ),
    .clear_i      ( clear_i                                   ),
    .write_en_i   ( ctrl_i.load                               ),
    .write_addr_i ( (W > 1) ? rows_loaded_q[W_AW-1:0] : 1'b0  ),
    .wdata_i      ( x_buffer_i                                ),
    .read_en_i    ( pad_rd_en                                 ),
    .read_addr_i  ( pad_rd_addr                               ),
    .rdata_o      ( pad_rdata                                 )
  );

  always_comb begin : pad_zero_mask
    for (int unsigned w = 0; w < W; w++) begin
      if ((32'(col_cursor_q) < 32'(ctrl_i.height)) && (w < 32'(active_tile_rows_q))) begin
        masked_col_data[w] = pad_rdata[w];
      end else begin
        masked_col_data[w] = '0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : scm_pointers
    if (!rst_ni) begin
      wr_lane_q <= '0;
      wr_bank_q <= 1'b0;
      rd_lane_q <= '0;
      rd_bank_q <= 1'b0;
    end else if (clear_i) begin
      wr_lane_q <= '0;
      wr_bank_q <= 1'b0;
      rd_lane_q <= '0;
      rd_bank_q <= 1'b0;
    end else begin
      if (push_scm) begin
        if ((H == 1) || (32'(wr_lane_q) == (H - 1))) begin
          wr_lane_q <= '0;
          wr_bank_q <= ~wr_bank_q;
        end else begin
          wr_lane_q <= wr_lane_q + 1'b1;
        end
      end
      if (ctrl_i.h_shift) begin
        if ((H == 1) || (32'(rd_lane_q) == (H - 1))) begin
          rd_lane_q <= '0;
          rd_bank_q <= ~rd_bank_q;
        end else begin
          rd_lane_q <= rd_lane_q + 1'b1;
        end
      end
    end
  end

  if (H > 1) begin : g_scm_addr_multi
    assign scm_waddr = {wr_bank_q, wr_lane_q};
    assign scm_raddr = {rd_bank_q, rd_lane_q};
  end else begin : g_scm_addr_single
    assign scm_waddr = wr_bank_q;
    assign scm_raddr = rd_bank_q;
  end

  redmule_x_buffer_scm #(
    .WORD_SIZE   ( FpWidth    ),
    .WIDTH       ( W          ),
    .HEIGHT      ( 2          ),
    .N_OUTPUTS   ( H          ),
    .USE_LATCHES ( UseLatches )
  ) i_x_buf (
    .clk_i        ( clk_i           ),
    .rst_ni       ( rst_ni          ),
    .clear_i      ( clear_i         ),
    .write_en_i   ( push_scm        ),
    .write_addr_i ( scm_waddr       ),
    .wdata_i      ( masked_col_data ),
    .read_en_i    ( ctrl_i.h_shift  ),
    .read_addr_i  ( scm_raddr       ),
    .rdata_o      ( scm_rdata       )
  );

  for (genvar w = 0; w < W; w++) begin : g_out_w
    for (genvar h = 0; h < H; h++) begin : g_out_h
      assign x_buffer_o[w][h] = scm_rdata[h][w];
    end
  end
endmodule : redmule_x_buffer
