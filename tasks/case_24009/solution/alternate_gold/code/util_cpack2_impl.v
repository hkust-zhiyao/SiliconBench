// SPDX-License-Identifier: GPL-2.0-only OR ADIBSD
// Copyright (C) 2017-2026 Analog Devices, Inc. All rights reserved.
`timescale 1ns/100ps

module util_cpack2_impl #(
  parameter NUM_OF_CHANNELS = 4,
  parameter SAMPLES_PER_CHANNEL = 1,
  parameter SAMPLE_DATA_WIDTH = 16,
  parameter INTERFACE_TYPE = 1,
  parameter PARALLEL_OR_SERIAL_N = 0,
  parameter PIPELINE_STAGES = 0
) (
  input clk,
  input reset,

  input [NUM_OF_CHANNELS-1:0] enable,

  input [NUM_OF_CHANNELS-1:0] fifo_wr_en,
  output fifo_wr_overflow,
  input [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] fifo_wr_data,

  input m_axis_ready,
  output m_axis_valid,
  output [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] m_axis_data,
  output [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL/8-1:0] m_axis_keep,
  output m_axis_last,

  output packed_fifo_wr_en,
  input packed_fifo_wr_overflow,
  output [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] packed_fifo_wr_data,
  output reg packed_sync = 1'b0
);

  localparam TOTAL_DATA_WIDTH = SAMPLE_DATA_WIDTH * SAMPLES_PER_CHANNEL * NUM_OF_CHANNELS;
  localparam NUM_OF_SAMPLES = NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL;
  localparam KEEP_WIDTH = TOTAL_DATA_WIDTH / 8 > 0 ? TOTAL_DATA_WIDTH / 8 : 1;
  localparam PIPELINE_STAGES_INT = INTERFACE_TYPE == 1 ? PIPELINE_STAGES : 0;

  wire data_wr_en;
  wire ce;
  wire flush;
  wire ready;
  wire reset_data;
  wire active_cfg;

  wire out_ready_int;
  reg out_valid_int = 1'b0;
  reg [TOTAL_DATA_WIDTH-1:0] out_data_int = {TOTAL_DATA_WIDTH{1'b0}};

  wire [TOTAL_DATA_WIDTH-1:0] interleaved_data;
  wire [TOTAL_DATA_WIDTH-1:0] out_data;
  wire out_sync;
  wire [NUM_OF_SAMPLES-1:0] out_valid;

  reg [NUM_OF_CHANNELS-1:0] enable_d = {NUM_OF_CHANNELS{1'b0}};
  always @(posedge clk) begin
    if (reset == 1'b1)
      enable_d <= {NUM_OF_CHANNELS{1'b0}};
    else
      enable_d <= enable;
  end
  assign active_cfg = (~reset) & (~reset_data) & (|enable) & (enable == enable_d);

  generate if (INTERFACE_TYPE == 1) begin
    assign out_ready_int = 1'b1;
    assign packed_fifo_wr_en = out_valid_int;
    assign packed_fifo_wr_data = out_data_int;
    assign m_axis_valid = 1'b0;
    assign m_axis_data = {TOTAL_DATA_WIDTH{1'b0}};
    assign m_axis_keep = {KEEP_WIDTH{1'b0}};
    assign m_axis_last = 1'b0;
  end else begin
    assign out_ready_int = m_axis_ready;
    assign packed_fifo_wr_en = 1'b0;
    assign packed_fifo_wr_data = {TOTAL_DATA_WIDTH{1'b0}};
    assign m_axis_valid = out_valid_int;
    assign m_axis_data = out_data_int;
    assign m_axis_keep = {KEEP_WIDTH{1'b1}};
    assign m_axis_last = 1'b0;
  end endgenerate

  assign data_wr_en = fifo_wr_en[0] & active_cfg;
  assign ce = data_wr_en & out_ready_int;
  assign flush = ~out_ready_int;
  assign fifo_wr_overflow = packed_fifo_wr_overflow;

  ad_perfect_shuffle #(
    .NUM_GROUPS (NUM_OF_CHANNELS),
    .WORDS_PER_GROUP (SAMPLES_PER_CHANNEL),
    .WORD_WIDTH (SAMPLE_DATA_WIDTH)
  ) i_interleave (
    .data_in (fifo_wr_data),
    .data_out (interleaved_data));

  pack_shell #(
    .NUM_OF_CHANNELS (NUM_OF_CHANNELS),
    .SAMPLES_PER_CHANNEL (SAMPLES_PER_CHANNEL),
    .SAMPLE_DATA_WIDTH (SAMPLE_DATA_WIDTH),
    .PACK (1),
    .PARALLEL_OR_SERIAL_N (PARALLEL_OR_SERIAL_N),
    .PIPELINE_STAGES (PIPELINE_STAGES_INT)
  ) i_pack_shell (
    .clk (clk),
    .reset (reset),
    .reset_data (reset_data),
    .enable (enable),
    .ce (ce),
    .flush (flush),
    .ready (ready),
    .in_data (interleaved_data),
    .out_data (out_data),
    .out_sync (out_sync),
    .out_valid (out_valid));

  always @(posedge clk) begin
    if (reset == 1'b1 || reset_data == 1'b1 || !active_cfg) begin
      out_valid_int <= 1'b0;
      packed_sync <= 1'b0;
    end else if (ready == 1'b1 && ce == 1'b1) begin
      out_valid_int <= 1'b1;
      packed_sync <= out_sync;
    end else begin
      out_valid_int <= 1'b0;
      packed_sync <= 1'b0;
    end
  end

  always @(posedge clk) begin: gen_packed_fifo_wr_data
    integer i;
    if (reset == 1'b1 || reset_data == 1'b1 || !active_cfg) begin
      out_data_int <= {TOTAL_DATA_WIDTH{1'b0}};
    end else if (ce == 1'b1) begin
      for (i = 0; i < NUM_OF_SAMPLES; i = i + 1) begin
        if (out_valid[i] == 1'b1) begin
          out_data_int[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] <= out_data[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH];
        end
      end
    end
  end

endmodule
