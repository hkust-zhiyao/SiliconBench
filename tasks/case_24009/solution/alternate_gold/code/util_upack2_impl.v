// SPDX-License-Identifier: GPL-2.0-only OR ADIBSD
// Copyright (C) 2017-2026 Analog Devices, Inc. All rights reserved.
`timescale 1ns/100ps

module util_upack2_impl #(
  parameter NUM_OF_CHANNELS = 4,
  parameter SAMPLES_PER_CHANNEL = 1,
  parameter SAMPLE_DATA_WIDTH = 16,
  parameter PARALLEL_OR_SERIAL_N = 0,
  parameter PIPELINE_STAGES = 0
) (
  input clk,
  input reset,

  input [NUM_OF_CHANNELS-1:0] enable,

  input [NUM_OF_CHANNELS-1:0] fifo_rd_en,
  output reg fifo_rd_valid,
  output reg fifo_rd_underflow,
  output reg [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] fifo_rd_data,

  input s_axis_valid,
  output s_axis_ready,
  input [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] s_axis_data
);

  localparam NUM_OF_SAMPLES = NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL;
  localparam TOTAL_DATA_WIDTH = NUM_OF_SAMPLES * SAMPLE_DATA_WIDTH;

  localparam
    SAMPLE_ADDRESS_WIDTH = NUM_OF_SAMPLES > 512 ? 10 :
    NUM_OF_SAMPLES > 256 ? 9 :
    NUM_OF_SAMPLES > 128 ? 8 :
    NUM_OF_SAMPLES > 64 ? 7 :
    NUM_OF_SAMPLES > 32 ? 6 :
    NUM_OF_SAMPLES > 16 ? 5 :
    NUM_OF_SAMPLES > 8 ? 4 :
    NUM_OF_SAMPLES > 4 ? 3 :
    NUM_OF_SAMPLES > 2 ? 2 : 1;

  localparam NON_POWER_OF_TWO = NUM_OF_CHANNELS > 2;
  localparam NETWORK0_STAGES = (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) / 2;
  localparam NETWORK1_STAGES = (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) % 2;
  localparam EXT_NETWORK_STAGES = NON_POWER_OF_TWO ? 1 : 0;

  function integer calc_pipeline_latency;
    input integer num_stages;
    begin
      if (PIPELINE_STAGES == 2)
        calc_pipeline_latency = num_stages;
      else if (PIPELINE_STAGES == 1)
        calc_pipeline_latency = num_stages / 2;
      else
        calc_pipeline_latency = 0;
    end
  endfunction

  localparam
    TOTAL_PIPELINE_LATENCY = (NUM_OF_CHANNELS == 1) ? 0 :
    calc_pipeline_latency(NETWORK0_STAGES) +
    calc_pipeline_latency(NETWORK1_STAGES) +
    calc_pipeline_latency(EXT_NETWORK_STAGES);

  wire [TOTAL_DATA_WIDTH-1:0] out_data;
  wire [TOTAL_DATA_WIDTH-1:0] deinterleaved_data;
  wire data_rd_en;
  wire ce;
  wire ready;
  wire reset_data;

  reg [NUM_OF_CHANNELS-1:0] enable_d = {NUM_OF_CHANNELS{1'b0}};
  always @(posedge clk) begin
    if (reset == 1'b1)
      enable_d <= {NUM_OF_CHANNELS{1'b0}};
    else
      enable_d <= enable;
  end

  wire cfg_busy = reset | reset_data | (~(|enable)) | (enable != enable_d);

  assign data_rd_en = fifo_rd_en[0] & ~cfg_busy;
  assign ce = s_axis_valid & data_rd_en;
  assign s_axis_ready = ready & ce;

  wire data_rd_en_delayed;
  wire s_axis_valid_delayed;
  wire reset_data_delayed;

  util_pipeline_stage #(
    .REGISTERED(TOTAL_PIPELINE_LATENCY),
    .WIDTH(1)
  ) i_data_rd_en_pipe (
    .clk(clk),
    .in(fifo_rd_en[0] & ~reset),
    .out(data_rd_en_delayed));

  util_pipeline_stage #(
    .REGISTERED(TOTAL_PIPELINE_LATENCY),
    .WIDTH(1)
  ) i_s_axis_valid_pipe (
    .clk(clk),
    .in(s_axis_valid),
    .out(s_axis_valid_delayed));

  util_pipeline_stage #(
    .REGISTERED(TOTAL_PIPELINE_LATENCY),
    .WIDTH(1)
  ) i_reset_data_pipe (
    .clk(clk),
    .in(cfg_busy),
    .out(reset_data_delayed));

  pack_shell #(
    .NUM_OF_CHANNELS (NUM_OF_CHANNELS),
    .SAMPLES_PER_CHANNEL (SAMPLES_PER_CHANNEL),
    .SAMPLE_DATA_WIDTH (SAMPLE_DATA_WIDTH),
    .PACK (0),
    .PARALLEL_OR_SERIAL_N (PARALLEL_OR_SERIAL_N),
    .PIPELINE_STAGES (PIPELINE_STAGES)
  ) i_pack_shell (
    .clk (clk),
    .reset (reset),
    .reset_data (reset_data),
    .enable (enable),
    .ce (ce),
    .flush (1'b0),
    .ready (ready),
    .in_data (s_axis_data),
    .out_data (out_data),
    .out_valid (),
    .out_sync ());

  ad_perfect_shuffle #(
    .NUM_GROUPS (SAMPLES_PER_CHANNEL),
    .WORDS_PER_GROUP (NUM_OF_CHANNELS),
    .WORD_WIDTH (SAMPLE_DATA_WIDTH)
  ) i_deinterleave (
    .data_in (out_data),
    .data_out (deinterleaved_data));

  wire reset_out = cfg_busy | reset_data_delayed;

  always @(posedge clk) begin
    if (reset == 1'b1 || reset_out == 1'b1 ||
        (data_rd_en_delayed == 1'b1 && s_axis_valid_delayed == 1'b0)) begin
      fifo_rd_data <= {TOTAL_DATA_WIDTH{1'b0}};
    end else if (data_rd_en_delayed == 1'b1) begin
      fifo_rd_data <= deinterleaved_data;
    end
  end

  always @(posedge clk) begin
    if (reset == 1'b1) begin
      fifo_rd_valid <= 1'b0;
      fifo_rd_underflow <= 1'b0;
    end else if (data_rd_en_delayed == 1'b1 && reset_out == 1'b0) begin
      fifo_rd_valid <= s_axis_valid_delayed;
      fifo_rd_underflow <= ~s_axis_valid_delayed;
    end else begin
      fifo_rd_valid <= 1'b0;
      fifo_rd_underflow <= 1'b0;
    end
  end

endmodule
