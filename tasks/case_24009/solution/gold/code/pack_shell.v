// SPDX-License-Identifier: GPL-2.0-only OR ADIBSD
// Copyright (C) 2017-2026 Analog Devices, Inc. All rights reserved.
`timescale 1ns/100ps

module pack_shell #(
  parameter NUM_OF_CHANNELS = 4,
  parameter SAMPLES_PER_CHANNEL = 1,
  parameter SAMPLE_DATA_WIDTH = 16,
  parameter PACK = 0,
  parameter PARALLEL_OR_SERIAL_N = 0,
  parameter PIPELINE_STAGES = 0
) (
  input clk,
  input reset,

  output reg reset_data = 1'b1,

  input [NUM_OF_CHANNELS-1:0] enable,

  input ce,
  input flush,

  output ready,
  input [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] in_data,

  output [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] out_data,
  output out_sync,
  output [NUM_OF_CHANNELS*SAMPLES_PER_CHANNEL-1:0] out_valid
);

  localparam NON_POWER_OF_TWO = NUM_OF_CHANNELS > 2;
  localparam CHANNEL_DATA_WIDTH = SAMPLES_PER_CHANNEL * SAMPLE_DATA_WIDTH;
  localparam TOTAL_DATA_WIDTH = CHANNEL_DATA_WIDTH * NUM_OF_CHANNELS;
  localparam NUM_OF_SAMPLES = NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL;
  localparam LOG2_NUM_OF_SAMPLES = $clog2(NUM_OF_SAMPLES);
  localparam CTRL_REPLICAS = NUM_OF_SAMPLES >= 32 && SAMPLE_DATA_WIDTH % 2 == 0 ? 2 : 1;

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

  reg reset_ctrl = 1'b1;
  reg startup_ctrl = 1'b0;
  reg startup_ctrl2 = 1'b0;
  reg [NUM_OF_CHANNELS-1:0] enable_int = {NUM_OF_CHANNELS{1'b0}};

  always @(posedge clk) begin
    if (reset == 1'b1) begin
      enable_int <= {NUM_OF_CHANNELS{1'b0}};
    end else begin
      enable_int <= enable;
    end
  end

  always @(posedge clk) begin
    if (reset == 1'b1 || enable == {NUM_OF_CHANNELS{1'b0}}) begin
      reset_ctrl <= 1'b1;
      reset_data <= 1'b1;
      startup_ctrl <= 1'b0;
      startup_ctrl2 <= 1'b0;
    end else if (enable != enable_int) begin
      reset_ctrl <= 1'b1;
      reset_data <= 1'b1;
      startup_ctrl <= 1'b1;
      startup_ctrl2 <= 1'b1;
    end else begin
      reset_ctrl <= 1'b0;
      reset_data <= NUM_OF_CHANNELS != 1 ? startup_ctrl2 : 1'b0;
      startup_ctrl2 <= 1'b0;
      startup_ctrl <= reset_ctrl | startup_ctrl2;
    end
  end

  generate
    if (NUM_OF_CHANNELS == 1) begin
      assign out_data = in_data;
      assign out_sync = 1'b1;
      assign out_valid = {NUM_OF_SAMPLES{1'b1}};
      assign ready = ~reset_data;
    end else begin
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

      localparam NUM_PORTS_M = 2**SAMPLE_ADDRESS_WIDTH;
      localparam NET_DATA_WIDTH = NUM_PORTS_M * SAMPLE_DATA_WIDTH;

      localparam
        NETWORK0_STAGES = PACK ? (SAMPLE_ADDRESS_WIDTH / 2) :
        ((SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) / 2);
      localparam
        NETWORK1_STAGES = PACK ? (SAMPLE_ADDRESS_WIDTH % 2) :
        ((SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) % 2);
      localparam EXT_NETWORK_STAGES = (NON_POWER_OF_TWO == 1 && PACK == 0) ? 1 : 0;

      localparam
        TOTAL_PIPELINE_LATENCY = calc_pipeline_latency(NETWORK0_STAGES) +
        calc_pipeline_latency(NETWORK1_STAGES) +
        calc_pipeline_latency(EXT_NETWORK_STAGES);

      reg ready_int = 1'b0;
      wire out_sync_int;
      wire [NUM_OF_SAMPLES-1:0] out_valid_int;
      wire pipe_ce = PACK ? ce : 1'b1;

      if (TOTAL_PIPELINE_LATENCY == 0 || PACK == 0) begin: gen_ready_comb
        assign ready = ready_int;
      end else begin: gen_ready_pipe
        (* shreg_extract = "no" *) reg [TOTAL_PIPELINE_LATENCY-1:0] ready_sr = 'h0;
        integer ri;
        always @(posedge clk) begin
          if (reset_ctrl == 1'b1) begin
            ready_sr <= 'h0;
          end else if (ce == 1'b1) begin
            ready_sr[0] <= ready_int;
            for (ri = 1; ri < TOTAL_PIPELINE_LATENCY; ri = ri + 1)
              ready_sr[ri] <= ready_sr[ri-1];
          end
        end
        assign ready = ready_sr[TOTAL_PIPELINE_LATENCY-1];
      end

      if (TOTAL_PIPELINE_LATENCY == 0) begin: gen_sync_comb
        assign out_sync = out_sync_int;
      end else begin: gen_sync_pipe
        (* shreg_extract = "no" *) reg [TOTAL_PIPELINE_LATENCY-1:0] sync_sr = 'h0;
        integer si;
        always @(posedge clk) begin
          if (reset_ctrl == 1'b1) begin
            sync_sr <= 'h0;
          end else if (ce == 1'b1) begin
            sync_sr[0] <= out_sync_int;
            for (si = 1; si < TOTAL_PIPELINE_LATENCY; si = si + 1)
              sync_sr[si] <= sync_sr[si-1];
          end
        end
        assign out_sync = sync_sr[TOTAL_PIPELINE_LATENCY-1];
      end

      if (TOTAL_PIPELINE_LATENCY == 0) begin: gen_valid_comb
        assign out_valid = out_valid_int;
      end else begin: gen_valid_pipe
        (* shreg_extract = "no" *) reg [NUM_OF_SAMPLES-1:0] valid_sr [0:TOTAL_PIPELINE_LATENCY-1];
        integer vj;
        always @(posedge clk) begin
          if (reset_ctrl == 1'b1) begin
            for (vj = 0; vj < TOTAL_PIPELINE_LATENCY; vj = vj + 1)
              valid_sr[vj] <= {NUM_OF_SAMPLES{1'b0}};
          end else if (ce == 1'b1) begin
            valid_sr[0] <= out_valid_int;
            for (vj = 1; vj < TOTAL_PIPELINE_LATENCY; vj = vj + 1)
              valid_sr[vj] <= valid_sr[vj-1];
          end
        end
        assign out_valid = valid_sr[TOTAL_PIPELINE_LATENCY-1];
      end

      reg [SAMPLE_ADDRESS_WIDTH-1:0] rotate = 'h00;
      reg [SAMPLE_ADDRESS_WIDTH*NUM_OF_SAMPLES-1:0] prefix_count;
      wire [SAMPLE_ADDRESS_WIDTH*NUM_PORTS_M-1:0] prefix_count_pad;
      wire ce_ctrl;
      wire [NET_DATA_WIDTH-1:0] data[0:2];
      wire [SAMPLE_ADDRESS_WIDTH-1:0] prefix_count_s[0:NUM_OF_SAMPLES];
      reg  [SAMPLE_ADDRESS_WIDTH:0] total_disabled_r = 'h0;

      assign ce_ctrl = startup_ctrl | ce;

      localparam PREFIX_BLOCK_LOG2 = (LOG2_NUM_OF_SAMPLES + 1) / 2;
      localparam PREFIX_BLOCK = 2**PREFIX_BLOCK_LOG2;
      localparam PREFIX_NUM_BLOCKS = (NUM_OF_SAMPLES + PREFIX_BLOCK - 1) / PREFIX_BLOCK;
      localparam PREFIX_NUM_BLOCKS_LOG2 = PREFIX_NUM_BLOCKS > 1 ? $clog2(PREFIX_NUM_BLOCKS) : 0;

      wire [NUM_OF_CHANNELS-1:0] enable_next = reset == 1'b1 ? {NUM_OF_CHANNELS{1'b0}} : enable;
      wire [NUM_OF_SAMPLES-1:0] samples_enable_next = {SAMPLES_PER_CHANNEL{enable_next}};

      wire [SAMPLE_ADDRESS_WIDTH-1:0] block_count_s[0:PREFIX_BLOCK_LOG2][0:NUM_OF_SAMPLES-1];
      wire [SAMPLE_ADDRESS_WIDTH-1:0] block_count_next[0:NUM_OF_SAMPLES-1];
      wire [SAMPLE_ADDRESS_WIDTH-1:0] block_count[0:NUM_OF_SAMPLES-1];

      wire [SAMPLE_ADDRESS_WIDTH-1:0] block_offset_s[0:PREFIX_NUM_BLOCKS_LOG2][0:PREFIX_NUM_BLOCKS-1];
      wire [SAMPLE_ADDRESS_WIDTH-1:0] block_offset[0:PREFIX_NUM_BLOCKS-1];
      wire [SAMPLE_ADDRESS_WIDTH-1:0] block_total[0:PREFIX_NUM_BLOCKS-1];

      genvar i, j;
      for (i = 0; i < NUM_OF_SAMPLES; i = i + 1) begin: gen_block_count
        assign block_count_s[0][i] = samples_enable_next[i] ? 1'b0 : 1'b1;

        for (j = 1; j <= PREFIX_BLOCK_LOG2; j = j + 1) begin: gen_row
          if (PARALLEL_OR_SERIAL_N == 1 && i % PREFIX_BLOCK >= 2**(j-1)) begin
            assign block_count_s[j][i] = block_count_s[j-1][i] + block_count_s[j-1][i-2**(j-1)];
          end else if (PARALLEL_OR_SERIAL_N == 0 && j == PREFIX_BLOCK_LOG2 && i % PREFIX_BLOCK != 0) begin
            assign block_count_s[j][i] = block_count_next[i-1] + block_count_s[0][i];
          end else begin
            assign block_count_s[j][i] = block_count_s[j-1][i];
          end
        end

        assign block_count_next[i] = block_count_s[PREFIX_BLOCK_LOG2][i];
        reg [SAMPLE_ADDRESS_WIDTH-1:0] block_count_r = 'h0;
        always @(posedge clk) begin
          block_count_r <= block_count_next[i];
        end
        assign block_count[i] = block_count_r;
      end

      for (i = 0; i < PREFIX_NUM_BLOCKS; i = i + 1) begin: gen_block_offset
        localparam LAST = (i + 1) * PREFIX_BLOCK - 1 < NUM_OF_SAMPLES ? (i + 1) * PREFIX_BLOCK - 1 : NUM_OF_SAMPLES - 1;
        if (i == 0) begin
          assign block_offset_s[0][i] = 'h0;
        end else begin
          assign block_offset_s[0][i] = block_total[i-1];
        end
        assign block_total[i] = block_count[LAST];

        for (j = 1; j <= PREFIX_NUM_BLOCKS_LOG2; j = j + 1) begin: gen_row
          if (PARALLEL_OR_SERIAL_N == 1 && i >= 2**(j-1)) begin
            assign block_offset_s[j][i] = block_offset_s[j-1][i] + block_offset_s[j-1][i-2**(j-1)];
          end else if (PARALLEL_OR_SERIAL_N == 0 && j == PREFIX_NUM_BLOCKS_LOG2 && i > 0) begin
            assign block_offset_s[j][i] = block_offset[i-1] + block_offset_s[0][i];
          end else begin
            assign block_offset_s[j][i] = block_offset_s[j-1][i];
          end
        end
        assign block_offset[i] = block_offset_s[PREFIX_NUM_BLOCKS_LOG2][i];
      end

      assign prefix_count_s[0] = 'h0;
      for (i = 0; i < NUM_OF_SAMPLES; i = i + 1) begin: gen_prefix_count
        assign prefix_count_s[i+1] = block_offset[i / PREFIX_BLOCK] + block_count[i];
        if (i < 2 || NUM_OF_CHANNELS <= 2) begin
          always @(*) begin
            prefix_count[i*SAMPLE_ADDRESS_WIDTH+:SAMPLE_ADDRESS_WIDTH] = prefix_count_s[i];
          end
        end else begin
          always @(posedge clk) begin
            prefix_count[i*SAMPLE_ADDRESS_WIDTH+:SAMPLE_ADDRESS_WIDTH] <= prefix_count_s[i];
          end
        end
      end

      // Pad dummy network ports [NUM_OF_SAMPLES .. NUM_PORTS_M - 1] as disabled ports!
      reg [SAMPLE_ADDRESS_WIDTH-1:0] enable_count = 'h0;
      wire [SAMPLE_ADDRESS_WIDTH:0] total_disabled_s = {1'b0, block_offset[(NUM_OF_SAMPLES - 1) / PREFIX_BLOCK]} + {1'b0, block_count[NUM_OF_SAMPLES - 1]};

      always @(posedge clk) begin
        total_disabled_r <= total_disabled_s;
        if (total_disabled_s >= NUM_OF_SAMPLES)
          enable_count <= 'h0;
        else
          enable_count <= (NUM_OF_SAMPLES - 1) - total_disabled_s[SAMPLE_ADDRESS_WIDTH-1:0];
      end

      for (i = 0; i < NUM_PORTS_M; i = i + 1) begin: gen_pad_pc
        if (i < NUM_OF_SAMPLES) begin
          assign prefix_count_pad[i*SAMPLE_ADDRESS_WIDTH+:SAMPLE_ADDRESS_WIDTH] = prefix_count[i*SAMPLE_ADDRESS_WIDTH+:SAMPLE_ADDRESS_WIDTH];
        end else begin
          wire [SAMPLE_ADDRESS_WIDTH:0] pad_v = total_disabled_r + (i - NUM_OF_SAMPLES);
          assign prefix_count_pad[i*SAMPLE_ADDRESS_WIDTH+:SAMPLE_ADDRESS_WIDTH] = pad_v[SAMPLE_ADDRESS_WIDTH-1:0];
        end
      end

      wire [SAMPLE_ADDRESS_WIDTH:0] active_k = {1'b0, enable_count} + 1'b1;

      if (NON_POWER_OF_TWO == 1 && PACK == 0) begin: gen_input_buffer
        localparam NUM_EXT_PORTS = 2 * NUM_PORTS_M;
        localparam D1_BASE_PORT  = NUM_EXT_PORTS - NUM_OF_SAMPLES;

        reg [TOTAL_DATA_WIDTH-1:0] data_d1 = {TOTAL_DATA_WIDTH{1'b0}};
        reg [SAMPLE_ADDRESS_WIDTH-1:0] pos_q = 'h0;
        reg use_d1_q = 1'b0;

        wire [(SAMPLE_ADDRESS_WIDTH+1)*NUM_EXT_PORTS-1:0] ext_prefix_count;
        wire [SAMPLE_DATA_WIDTH*NUM_EXT_PORTS-1:0] ext_data_in;
        wire [SAMPLE_DATA_WIDTH*NUM_EXT_PORTS-1:0] ext_data_out;
        wire [SAMPLE_DATA_WIDTH*NUM_EXT_PORTS-1:0] ext_data_shuffled;
        wire [SAMPLE_ADDRESS_WIDTH:0] ext_rotate;

        for (i = 0; i < NUM_EXT_PORTS; i = i + 1) begin: gen_ext_pc
          if (i < NUM_PORTS_M) begin
            assign ext_prefix_count[i*(SAMPLE_ADDRESS_WIDTH+1)+:(SAMPLE_ADDRESS_WIDTH+1)] = {1'b0, prefix_count_pad[i*SAMPLE_ADDRESS_WIDTH+:SAMPLE_ADDRESS_WIDTH]};
          end else begin
            assign ext_prefix_count[i*(SAMPLE_ADDRESS_WIDTH+1)+:(SAMPLE_ADDRESS_WIDTH+1)] = {(SAMPLE_ADDRESS_WIDTH+1){1'b0}};
          end
        end

        for (i = 0; i < NUM_EXT_PORTS; i = i + 1) begin: gen_ext_din
          if (i < NUM_OF_SAMPLES) begin
            assign ext_data_in[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] = in_data[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH];
          end else if (i >= D1_BASE_PORT) begin
            assign ext_data_in[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] = data_d1[(i - D1_BASE_PORT)*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH];
          end else begin
            assign ext_data_in[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] = {SAMPLE_DATA_WIDTH{1'b0}};
          end
        end

        assign ext_rotate = use_d1_q ? (D1_BASE_PORT[SAMPLE_ADDRESS_WIDTH:0] + {1'b0, pos_q}) : {1'b0, pos_q};

        always @(posedge clk) begin
          if (reset_ctrl == 1'b1) begin
            data_d1 <= {TOTAL_DATA_WIDTH{1'b0}};
          end else if (ce == 1'b1 && ready_int == 1'b1) begin
            data_d1 <= in_data;
          end
        end

        wire [SAMPLE_ADDRESS_WIDTH+1:0] sum1 = {2'b00, pos_q} + {1'b0, active_k};
        wire [SAMPLE_ADDRESS_WIDTH+1:0] rem1 = sum1 - NUM_OF_SAMPLES;
        reg  ready_d;
        reg  [SAMPLE_ADDRESS_WIDTH-1:0] pos_d;
        reg  use_d1_d;

        always @(*) begin
          if (use_d1_q == 1'b0) begin
            if (sum1 == NUM_OF_SAMPLES) begin
              ready_d  = 1'b1;
              pos_d    = 'h0;
              use_d1_d = 1'b0;
            end else if ((sum1 + {1'b0, active_k}) > NUM_OF_SAMPLES) begin
              ready_d  = 1'b1;
              pos_d    = sum1[SAMPLE_ADDRESS_WIDTH-1:0];
              use_d1_d = 1'b1;
            end else begin
              ready_d  = 1'b0;
              pos_d    = sum1[SAMPLE_ADDRESS_WIDTH-1:0];
              use_d1_d = 1'b0;
            end
          end else begin
            if ((rem1 + {1'b0, active_k}) > NUM_OF_SAMPLES) begin
              ready_d  = 1'b1;
              pos_d    = rem1[SAMPLE_ADDRESS_WIDTH-1:0];
              use_d1_d = 1'b1;
            end else begin
              ready_d  = 1'b0;
              pos_d    = rem1[SAMPLE_ADDRESS_WIDTH-1:0];
              use_d1_d = 1'b0;
            end
          end
        end

        always @(posedge clk) begin
          if (reset_ctrl == 1'b1) begin
            ready_int <= 1'b0;
            pos_q     <= 'h0;
            use_d1_q  <= 1'b0;
            rotate    <= 'h0;
          end else if (ce_ctrl == 1'b1) begin
            ready_int <= ready_d;
            pos_q     <= pos_d;
            use_d1_q  <= use_d1_d;
            rotate    <= ext_rotate[SAMPLE_ADDRESS_WIDTH-1:0];
          end
        end

        // Note: i_ext_ctrl_interconnect latches ctrl on ce_ctrl using ext_rotate, AND gen_network ALSO latches ctrl on ce_ctrl!
        // WAIT: verify ext_rotate[SAMPLE_ADDRESS_WIDTH-1:0] vs rotate!
        // Both i_ext_ctrl_interconnect AND gen_network latch their ctrl registers on the SAME `ce_ctrl` clock edge!
        // So gen_network MUST receive `ext_rotate[SAMPLE_ADDRESS_WIDTH-1:0]` COMBINATIONALLY (on the SAME cycle as i_ext_ctrl_interconnect!), NOT 1 cycle delayed!
        pack_network #(
          .PORT_ADDRESS_WIDTH (SAMPLE_ADDRESS_WIDTH + 1),
          .MUX_ORDER (2),
          .MIN_STAGE (0),
          .NUM_STAGES (1),
          .PORT_DATA_WIDTH (SAMPLE_DATA_WIDTH),
          .PIPELINE_STAGES (PIPELINE_STAGES),
          .PIPELINE_OFFSET (0),
          .CTRL_REPLICAS (CTRL_REPLICAS)
        ) i_ext_ctrl_interconnect (
          .clk (clk),
          .ce_ctrl (ce_ctrl),
          .ce (pipe_ce),
          .rotate (ext_rotate),
          .prefix_count (ext_prefix_count),
          .data_in (ext_data_in),
          .data_out (ext_data_out));

        ad_perfect_shuffle #(
          .NUM_GROUPS (NUM_PORTS_M / 2),
          .WORDS_PER_GROUP (2),
          .WORD_WIDTH (2 * SAMPLE_DATA_WIDTH)
        ) i_ext_shuffle (
          .data_in (ext_data_out),
          .data_out (ext_data_shuffled));

        assign data[0] = ext_data_shuffled[0+:NET_DATA_WIDTH];
      end else begin : gen_mod_rotate
        wire [SAMPLE_ADDRESS_WIDTH:0] rot_sum = {1'b0, rotate} + active_k;
        wire rot_wrap = (rot_sum >= NUM_OF_SAMPLES);
        wire [SAMPLE_ADDRESS_WIDTH:0] rot_mod = rot_wrap ? (rot_sum - NUM_OF_SAMPLES) : rot_sum;

        always @(posedge clk) begin
          if (reset_ctrl == 1'b1) begin
            ready_int <= 1'b0;
            rotate    <= 'h0;
          end else if (ce_ctrl == 1'b1) begin
            ready_int <= rot_wrap;
            rotate    <= rot_mod[SAMPLE_ADDRESS_WIDTH-1:0];
          end else if (flush == 1'b1) begin
            ready_int <= 1'b0;
            rotate    <= 'h0;
          end
        end

        for (i = 0; i < NUM_PORTS_M; i = i + 1) begin: gen_din_pad
          if (i < NUM_OF_SAMPLES) begin
            assign data[0][i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] = in_data[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH];
          end else begin
            assign data[0][i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] = {SAMPLE_DATA_WIDTH{1'b0}};
          end
        end
      end

      wire [SAMPLE_ADDRESS_WIDTH-1:0] net_rotate;
      if (NON_POWER_OF_TWO == 1 && PACK == 0) begin: gen_net_rot_upack
        localparam NUM_EXT_PORTS_W = 2 * NUM_PORTS_M;
        localparam D1_BASE_PORT_W  = NUM_EXT_PORTS_W - NUM_OF_SAMPLES;
        wire [SAMPLE_ADDRESS_WIDTH:0] ext_rot_w = gen_input_buffer.use_d1_q ?
            (D1_BASE_PORT_W[SAMPLE_ADDRESS_WIDTH:0] + {1'b0, gen_input_buffer.pos_q}) :
            {1'b0, gen_input_buffer.pos_q};
        assign net_rotate = ext_rot_w[SAMPLE_ADDRESS_WIDTH-1:0];
      end else begin: gen_net_rot_pack
        assign net_rotate = rotate;
      end

      for (i = 0; i < 2; i = i + 1) begin: gen_network
        localparam MUX_ORDER = i == 0 ? 2 : 1;
        localparam
          MIN_STAGE = PACK ? (i == 0 ? SAMPLE_ADDRESS_WIDTH % 2 : 0) :
          (i == 0 ? NON_POWER_OF_TWO : SAMPLE_ADDRESS_WIDTH - 1);
        localparam
          NUM_STAGES = PACK ?
          (i == 0 ? SAMPLE_ADDRESS_WIDTH / 2 : SAMPLE_ADDRESS_WIDTH % 2) :
          (i == 0 ? (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) / 2 :
          (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) % 2);
        localparam
          PIPELINE_OFFSET = (i == 0) ?
          calc_pipeline_latency(EXT_NETWORK_STAGES) :
          calc_pipeline_latency(EXT_NETWORK_STAGES) +
          calc_pipeline_latency(NETWORK0_STAGES);

        if (NUM_STAGES > 0) begin
          pack_network #(
            .PACK (PACK),
            .PORT_ADDRESS_WIDTH (SAMPLE_ADDRESS_WIDTH),
            .MUX_ORDER (MUX_ORDER),
            .MIN_STAGE (MIN_STAGE),
            .NUM_STAGES (NUM_STAGES),
            .PORT_DATA_WIDTH (SAMPLE_DATA_WIDTH),
            .PIPELINE_STAGES (PIPELINE_STAGES),
            .PIPELINE_OFFSET (PIPELINE_OFFSET),
            .CTRL_REPLICAS (CTRL_REPLICAS)
          ) i_ctrl_interconnect (
            .clk (clk),
            .ce_ctrl (ce_ctrl),
            .ce (pipe_ce),
            .rotate (net_rotate),
            .prefix_count (prefix_count_pad),
            .data_in (data[i]),
            .data_out (data[i+1]));
        end else begin
          assign data[i+1] = data[i];
        end
      end

      if (PACK == 1) begin: gen_pack
        reg [NUM_OF_SAMPLES-1:0] valid = {NUM_OF_SAMPLES{1'b0}};
        wire [NUM_OF_SAMPLES-1:0] base_mask = {NUM_OF_SAMPLES{1'b1}} >> ((NUM_OF_SAMPLES - 1) - enable_count);

        if (NON_POWER_OF_TWO == 1) begin: gen_output_buffer
          localparam PREV_VALID_WIDTH = NUM_OF_SAMPLES - 2 * SAMPLES_PER_CHANNEL;
          localparam DELAYED_DATA_WIDTH = PREV_VALID_WIDTH * SAMPLE_DATA_WIDTH;
          localparam PV_DELAY = TOTAL_PIPELINE_LATENCY + 1;

          reg [PREV_VALID_WIDTH-1:0] prev_valid = {PREV_VALID_WIDTH{1'b0}};
          reg [DELAYED_DATA_WIDTH-1:0] data_d1 = {DELAYED_DATA_WIDTH{1'b0}};
          (* shreg_extract = "no" *) reg [PREV_VALID_WIDTH-1:0] pv_sr [0:PV_DELAY-1];
          wire [PREV_VALID_WIDTH-1:0] prev_valid_d1;
          integer pv_i;

          always @(posedge clk) begin
            if (reset_ctrl == 1'b1) begin
              valid      <= {NUM_OF_SAMPLES{1'b0}};
              prev_valid <= {PREV_VALID_WIDTH{1'b0}};
            end else if (ce_ctrl == 1'b1) begin
              {prev_valid, valid} <= ({{PREV_VALID_WIDTH{1'b0}}, base_mask} << rotate) | {{NUM_OF_SAMPLES{1'b0}}, prev_valid};
            end else if (flush == 1'b1) begin
              valid      <= {NUM_OF_SAMPLES{1'b0}};
              prev_valid <= {PREV_VALID_WIDTH{1'b0}};
            end
          end

          always @(posedge clk) begin
            if (reset_ctrl == 1'b1) begin
              for (pv_i = 0; pv_i < PV_DELAY; pv_i = pv_i + 1)
                pv_sr[pv_i] <= {PREV_VALID_WIDTH{1'b0}};
            end else if (ce_ctrl == 1'b1) begin
              pv_sr[0] <= prev_valid;
              for (pv_i = 1; pv_i < PV_DELAY; pv_i = pv_i + 1)
                pv_sr[pv_i] <= pv_sr[pv_i-1];
            end else if (flush == 1'b1) begin
              for (pv_i = 0; pv_i < PV_DELAY; pv_i = pv_i + 1)
                pv_sr[pv_i] <= {PREV_VALID_WIDTH{1'b0}};
            end
          end

          assign prev_valid_d1 = pv_sr[PV_DELAY-1];

          reg sync = 1'b1;
          always @(posedge clk) begin
            if (reset_ctrl == 1'b1) begin
              sync <= 1'b1;
            end else if (ready_int == 1'b1 && ce == 1'b1) begin
              sync <= (rotate == 'h0);
            end else if (flush == 1'b1 && ce_ctrl == 1'b0) begin
              sync <= 1'b1;
            end
          end

          for (i = 0; i < PREV_VALID_WIDTH; i = i + 1) begin: gen_ovf_cap
            localparam OVF_PORT = (NUM_OF_SAMPLES + i) % NUM_PORTS_M;
            always @(posedge clk) begin
              if (reset_ctrl == 1'b1) begin
                data_d1[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] <= {SAMPLE_DATA_WIDTH{1'b0}};
              end else if (ce == 1'b1) begin
                data_d1[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] <= data[2][OVF_PORT*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH];
              end
            end
          end

          for (i = 0; i < NUM_OF_SAMPLES; i = i + 1) begin: gen_out_data
            localparam w = SAMPLE_DATA_WIDTH;
            localparam base = i * w;
            if (i >= PREV_VALID_WIDTH) begin
              assign out_data[base+:w] = data[2][base+:w];
            end else begin
              assign out_data[base+:w] = prev_valid_d1[i] == 1'b1 ? data_d1[base+:w] : data[2][base+:w];
            end
          end

          assign out_sync_int = sync;
        end else begin: gen_pow2_pack
          always @(posedge clk) begin
            if (reset_ctrl == 1'b1) begin
              valid <= {NUM_OF_SAMPLES{1'b0}};
            end else if (ce_ctrl == 1'b1) begin
              valid <= base_mask << rotate;
            end else if (flush == 1'b1) begin
              valid <= {NUM_OF_SAMPLES{1'b0}};
            end
          end
          assign out_data = data[2][0+:TOTAL_DATA_WIDTH];
          assign out_sync_int = 1'b1;
        end

        assign out_valid_int = valid;
      end else begin
        assign out_sync_int = 1'b1;
        assign out_valid_int = {NUM_OF_SAMPLES{1'b1}};
        assign out_data = data[2][0+:TOTAL_DATA_WIDTH];
      end
    end
  endgenerate

endmodule
