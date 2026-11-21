// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
// Andrea Belano <andrea.belano2@unibo.it>
//

module redmule_x_buffer
  import fpnew_pkg::*;
  import redmule_pkg::*;
#(
parameter int unsigned           DataW      = MaxDataW,
parameter fpnew_pkg::fp_format_e FpFormat   = fpnew_pkg::FP16,
parameter int unsigned           Height     = MaxDim,  // Number of PEs per row
parameter int unsigned           Width      = MaxDim,  // Number of parallel index
parameter bit                    UseLatches = 0,
localparam int unsigned          FpWidth    = fpnew_pkg::fp_width(FpFormat), // Number of bits for the given format
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

localparam int unsigned D          = DataW/(H*FpWidth);
localparam int unsigned TOT_DEPTH  = H*D;
localparam int unsigned W_ADDR_W   = (W > 1) ? $clog2(W) : 1;
localparam int unsigned H_ADDR_W   = (H > 1) ? $clog2(H) : 1;
localparam int unsigned PAD_ADDR_W = (TOT_DEPTH > 1) ? $clog2(TOT_DEPTH) : 1;
localparam int unsigned BUF_ADDR_W = $clog2(H) + 1;
localparam int unsigned BUF_CNT_W  = $clog2(2*H + 1);
localparam int unsigned PAD_CNT_W  = $clog2(TOT_DEPTH + 1);

logic [$clog2(W):0]                 w_index_d, w_index_q;
logic [W-1:0]                       pad_row_valid_q;
logic [W_ADDR_W-1:0]                pad_write_addr;

logic [H_ADDR_W-1:0]                h_index_r, h_index_w;
logic                               buf_r_addr, buf_w_addr;
logic [BUF_ADDR_W-1:0]              scm_write_addr, scm_read_addr;

logic [W-1:0][FpWidth-1:0]          x_pad_q;
logic [W-1:0][FpWidth-1:0]          buf_wdata;
logic [H-1:0][W-1:0][FpWidth-1:0]   x_buffer_q;

logic [PAD_ADDR_W-1:0]              pad_r_addr_d, pad_r_addr_q;
logic [PAD_ADDR_W-1:0]              pad_read_addr;
logic [PAD_CNT_W-1:0]               pad_col_idx_q;

logic [BUF_CNT_W-1:0]               init_writes_q;
logic [BUF_CNT_W-1:0]               unread_cnt_q;

logic                               started_q;
logic                               pad_tile_valid_q;
logic                               tile_consumed_q;
logic                               fresh_pad_full;

logic                               pad_read_en;
logic                               buf_can_write;
logic                               buf_write_en;
logic                               buf_read_fire;
logic                               tile_cols_done;
logic                               col_in_bounds;

// Counter to track rows loaded into i_x_pad for the incoming tile
assign w_index_d      = ctrl_i.load ? (w_index_q + 1'b1) : w_index_q;
assign flags_o.full   = (usize_eq(32'(w_index_q), 32'(ctrl_i.width)));
assign pad_write_addr = (W > 1) ? w_index_q[W_ADDR_W-1:0] : '0;

function automatic logic usize_eq(input logic [31:0] a, input logic [31:0] b);
  return (a == b);
endfunction

always_ff @(posedge clk_i or negedge rst_ni) begin : row_loaded_counter
  if (~rst_ni) begin
    w_index_q <= '0;
  end else begin
    if (ctrl_i.rst_w_index || clear_i) begin
      w_index_q <= '0;
    end else if (ctrl_i.load) begin
      w_index_q <= w_index_d;
    end
  end
end

// Persist which rows [0..W-1] were actually loaded for the tile currently in i_x_pad,
// even after ctrl_i.rst_w_index clears w_index_q mid-drain.
always_ff @(posedge clk_i or negedge rst_ni) begin : row_valid_tracker
  if (~rst_ni) begin
    pad_row_valid_q <= '0;
  end else begin
    if (clear_i) begin
      pad_row_valid_q <= '0;
    end else if (ctrl_i.load && !ctrl_i.rst_w_index) begin
      if (w_index_q == '0) begin
        pad_row_valid_q    <= '0;
        pad_row_valid_q[0] <= 1'b1;
      end else if (32'(w_index_q) < W) begin
        pad_row_valid_q[pad_write_addr] <= 1'b1;
      end
    end else if (flags_o.empty) begin
      pad_row_valid_q <= '0;
    end
  end
end

assign fresh_pad_full = flags_o.full && !tile_consumed_q;

always_ff @(posedge clk_i or negedge rst_ni) begin : tile_lifecycle_registers
  if (~rst_ni) begin
    started_q        <= 1'b0;
    pad_tile_valid_q <= 1'b0;
    tile_consumed_q  <= 1'b0;
  end else begin
    if (clear_i) begin
      started_q        <= 1'b0;
      pad_tile_valid_q <= 1'b0;
      tile_consumed_q  <= 1'b0;
    end else begin
      if (ctrl_i.pad_setup) begin
        started_q <= 1'b1;
      end

      if (ctrl_i.pad_setup && flags_o.full) begin
        pad_tile_valid_q <= 1'b1;
        tile_consumed_q  <= ~ctrl_i.rst_w_index;
      end else if (flags_o.empty) begin
        if (fresh_pad_full) begin
          pad_tile_valid_q <= 1'b1;
          tile_consumed_q  <= ~ctrl_i.rst_w_index;
        end else begin
          pad_tile_valid_q <= 1'b0;
          if (ctrl_i.rst_w_index) begin
            tile_consumed_q <= 1'b0;
          end
        end
      end else begin
        if (!pad_tile_valid_q && (started_q || ctrl_i.pad_setup) && fresh_pad_full) begin
          pad_tile_valid_q <= 1'b1;
          tile_consumed_q  <= ~ctrl_i.rst_w_index;
        end else if (ctrl_i.rst_w_index) begin
          tile_consumed_q <= 1'b0;
        end
      end
    end
  end
end

// Capacity / lookahead flow control into the 2*H-deep ping-pong buffer i_x_buf:
// - The first 2*H writes after reset/clear populate slots 0 and 1 for the first time.
// - Thereafter, slot (floor(W_tot/H) mod 2, W_tot mod H) becomes free once R_tot reaches
//   W_tot - H (either R_tot > W_tot - H already, or R_tot == W_tot - H with h_shift=1).
assign buf_can_write = (32'(init_writes_q) < 2*H) ||
                       (32'(unread_cnt_q) < H) ||
                       ((32'(unread_cnt_q) == H) && ctrl_i.h_shift);

assign buf_write_en  = pad_tile_valid_q && (32'(pad_col_idx_q) < 32'(ctrl_i.slots)) && buf_can_write;
assign buf_read_fire = ctrl_i.h_shift && ((unread_cnt_q != '0) || buf_write_en);

always_ff @(posedge clk_i or negedge rst_ni) begin : buf_occupancy_counters
  if (~rst_ni) begin
    init_writes_q <= '0;
    unread_cnt_q  <= '0;
  end else begin
    if (clear_i) begin
      init_writes_q <= '0;
      unread_cnt_q  <= '0;
    end else begin
      if (buf_write_en && (32'(init_writes_q) < 2*H)) begin
        init_writes_q <= init_writes_q + 1'b1;
      end
      unique case ({buf_write_en, buf_read_fire})
        2'b10:   unread_cnt_q <= unread_cnt_q + 1'b1;
        2'b01:   unread_cnt_q <= unread_cnt_q - 1'b1;
        default: unread_cnt_q <= unread_cnt_q;
      endcase
    end
  end
end

// Track how many columns [0..ctrl_i.slots] of the active i_x_pad tile have entered i_x_buf
always_ff @(posedge clk_i or negedge rst_ni) begin : pad_col_counter
  if (~rst_ni) begin
    pad_col_idx_q <= '0;
    pad_r_addr_q  <= '0;
  end else begin
    if (clear_i || ctrl_i.pad_setup || flags_o.empty) begin
      pad_col_idx_q <= '0;
      pad_r_addr_q  <= '0;
    end else if (buf_write_en) begin
      pad_col_idx_q <= pad_col_idx_q + 1'b1;
      pad_r_addr_q  <= pad_r_addr_d;
    end
  end
end

assign pad_r_addr_d   = (32'(pad_col_idx_q) + 32'd1 < 32'(ctrl_i.slots)) ? (pad_r_addr_q + 1'b1) : '0;
assign pad_read_en    = buf_write_en || ctrl_i.pad_setup || flags_o.empty;
assign pad_read_addr  = (ctrl_i.pad_setup || flags_o.empty) ? '0 : pad_r_addr_d;

assign tile_cols_done = pad_tile_valid_q &&
                        ((32'(pad_col_idx_q) >= 32'(ctrl_i.slots)) ||
                         ((32'(pad_col_idx_q) + 32'd1 == 32'(ctrl_i.slots)) && buf_write_en));
assign flags_o.empty  = tile_cols_done && ctrl_i.h_shift;

redmule_x_pad_scm #(
  .WORD_SIZE   ( FpWidth    ),
  .ROWS        ( W          ),
  .COLS        ( TOT_DEPTH  ),
  .USE_LATCHES ( UseLatches )
) i_x_pad (
  .clk_i        ( clk_i          ),
  .rst_ni       ( rst_ni         ),
  .clear_i      ( clear_i        ),
  .write_en_i   ( ctrl_i.load    ),
  .write_addr_i ( pad_write_addr ),
  .wdata_i      ( x_buffer_i     ),
  .read_en_i    ( pad_read_en    ),
  .read_addr_i  ( pad_read_addr  ),
  .rdata_o      ( x_pad_q        )
);

assign col_in_bounds = (32'(pad_col_idx_q) < 32'(ctrl_i.height));
always_comb begin : gen_buf_wdata
  for (int unsigned w = 0; w < W; w++) begin
    buf_wdata[w] = (col_in_bounds && pad_row_valid_q[w]) ? x_pad_q[w] : '0;
  end
end

if (H > 1) begin : gen_multi_h_scm_addr
  assign scm_write_addr = {buf_w_addr, h_index_w};
  assign scm_read_addr  = {buf_r_addr, h_index_r};
end else begin : gen_single_h_scm_addr
  assign scm_write_addr = buf_w_addr;
  assign scm_read_addr  = buf_r_addr;
end

redmule_x_buffer_scm #(
  .WORD_SIZE   ( FpWidth    ),
  .WIDTH       ( W          ),
  .HEIGHT      ( 2          ),
  .N_OUTPUTS   ( H          ),
  .USE_LATCHES ( UseLatches )
) i_x_buf (
  .clk_i        ( clk_i          ),
  .rst_ni       ( rst_ni         ),
  .clear_i      ( clear_i        ),
  .write_en_i   ( buf_write_en   ),
  .write_addr_i ( scm_write_addr ),
  .wdata_i      ( buf_wdata      ),
  .read_en_i    ( ctrl_i.h_shift ),
  .read_addr_i  ( scm_read_addr  ),
  .rdata_o      ( x_buffer_q     )
);

always_ff @(posedge clk_i or negedge rst_ni) begin : h_index_r_register
  if (~rst_ni) begin
    h_index_r <= '0;
  end else begin
    if (clear_i) begin
      h_index_r <= '0;
    end else if (ctrl_i.h_shift && (H > 1)) begin
      h_index_r <= (32'(h_index_r) == (H - 1)) ? '0 : (h_index_r + 1'b1);
    end
  end
end

always_ff @(posedge clk_i or negedge rst_ni) begin : buffer_read_address
  if (~rst_ni) begin
    buf_r_addr <= 1'b0;
  end else begin
    if (clear_i) begin
      buf_r_addr <= 1'b0;
    end else if (((H == 1) || (32'(h_index_r) == (H - 1))) && ctrl_i.h_shift) begin
      buf_r_addr <= ~buf_r_addr;
    end
  end
end

always_ff @(posedge clk_i or negedge rst_ni) begin : h_index_w_register
  if (~rst_ni) begin
    h_index_w <= '0;
  end else begin
    if (clear_i) begin
      h_index_w <= '0;
    end else if (buf_write_en && (H > 1)) begin
      h_index_w <= (32'(h_index_w) == (H - 1)) ? '0 : (h_index_w + 1'b1);
    end
  end
end

always_ff @(posedge clk_i or negedge rst_ni) begin : buffer_write_address
  if (~rst_ni) begin
    buf_w_addr <= 1'b0;
  end else begin
    if (clear_i) begin
      buf_w_addr <= 1'b0;
    end else if (((H == 1) || (32'(h_index_w) == (H - 1))) && buf_write_en) begin
      buf_w_addr <= ~buf_w_addr;
    end
  end
end

// Output assignment
// verilog_lint: waive-start generate-label
generate
  for (genvar w = 0; w < W; w++) begin
    for (genvar h = 0; h < H; h++) begin
      assign x_buffer_o[w][h] = x_buffer_q[h][w];
    end
  end
endgenerate
// verilog_lint: waive-stop generate-label

endmodule : redmule_x_buffer
