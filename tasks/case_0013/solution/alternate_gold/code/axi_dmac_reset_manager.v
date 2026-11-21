// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2023 Analog Devices, Inc. All rights reserved.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//   1. The GNU General Public License version 2 (LICENSE_GPL2)
//   2. An ADI specific BSD license (LICENSE_ADIBSD)
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

module axi_dmac_reset_manager #(
  parameter ASYNC_CLK_REQ_SRC = 1,
  parameter ASYNC_CLK_SRC_DEST = 1,
  parameter ASYNC_CLK_DEST_REQ = 1,
  parameter ASYNC_CLK_REQ_SG = 1,
  parameter DMA_SG_TRANSFER = 0
) (
  input clk,
  input resetn,

  input ctrl_enable,
  input ctrl_pause,
  input ctrl_hwdesc,

  output req_resetn,
  output req_enable,
  input req_enabled,

  input dest_clk,
  input dest_ext_resetn,
  output dest_resetn,
  output dest_enable,
  input dest_enabled,

  input src_clk,
  input src_ext_resetn,
  output src_resetn,
  output src_enable,
  input src_enabled,

  input sg_clk,
  input sg_ext_resetn,
  output sg_resetn,
  output sg_enable,
  input sg_enabled,

  output [11:0] dbg_status
);

  localparam STATE_DO_RESET = 3'h0;
  localparam STATE_RESET = 3'h1;
  localparam STATE_DISABLED = 3'h2;
  localparam STATE_STARTUP = 3'h3;
  localparam STATE_ENABLED = 3'h4;
  localparam STATE_SHUTDOWN = 3'h5;

  reg [2:0] state = 3'b000;
  reg needs_reset = 1'b0;
  reg do_reset = 1'b0;
  reg do_enable = 1'b0;

  wire enabled_dest;
  wire enabled_src;
  wire enabled_sg;

  wire enabled_all;
  wire disabled_all;

  // Per-domain reset synchronizers: immediate assertion, 2-FF local clock release
  reg [1:0] dest_ext_sync_q = 2'b00;
  reg [1:0] src_ext_sync_q = 2'b00;
  reg [1:0] sg_ext_sync_q = 2'b00;

  always @(posedge dest_clk or negedge dest_ext_resetn or negedge resetn) begin
    if (!dest_ext_resetn || !resetn)
      dest_ext_sync_q <= 2'b00;
    else
      dest_ext_sync_q <= {dest_ext_sync_q[0], 1'b1};
  end

  always @(posedge src_clk or negedge src_ext_resetn or negedge resetn) begin
    if (!src_ext_resetn || !resetn)
      src_ext_sync_q <= 2'b00;
    else
      src_ext_sync_q <= {src_ext_sync_q[0], 1'b1};
  end

  always @(posedge sg_clk or negedge sg_ext_resetn or negedge resetn) begin
    if (!sg_ext_resetn || !resetn)
      sg_ext_sync_q <= 2'b00;
    else
      sg_ext_sync_q <= {sg_ext_sync_q[0], 1'b1};
  end

  // Asynchronous pulse catchers per domain, cleared once STATE_RESET sees all released
  wire ext_rel_src, ext_rel_dest, ext_rel_sg;
  wire all_ext_released = ext_rel_src & ext_rel_dest & ((DMA_SG_TRANSFER == 0) | ext_rel_sg);

  reg latch_src_rst = 1'b0;
  reg latch_dest_rst = 1'b0;
  reg latch_sg_rst = 1'b0;

  always @(posedge clk or negedge src_ext_resetn or negedge resetn) begin
    if (!src_ext_resetn)
      latch_src_rst <= 1'b1;
    else if (!resetn)
      latch_src_rst <= 1'b0;
    else if (state == STATE_RESET && all_ext_released)
      latch_src_rst <= 1'b0;
  end

  always @(posedge clk or negedge dest_ext_resetn or negedge resetn) begin
    if (!dest_ext_resetn)
      latch_dest_rst <= 1'b1;
    else if (!resetn)
      latch_dest_rst <= 1'b0;
    else if (state == STATE_RESET && all_ext_released)
      latch_dest_rst <= 1'b0;
  end

  always @(posedge clk or negedge sg_ext_resetn or negedge resetn) begin
    if (!sg_ext_resetn)
      latch_sg_rst <= 1'b1;
    else if (!resetn)
      latch_sg_rst <= 1'b0;
    else if (state == STATE_RESET && all_ext_released)
      latch_sg_rst <= 1'b0;
  end

  wire [2:0] fault_vec_sync;
  sync_bits #(
    .NUM_OF_BITS (3),
    .ASYNC_CLK (1)
  ) i_sync_ext_faults (
    .out_clk (clk),
    .out_resetn (1'b1),
    .in_bits ({latch_sg_rst, latch_dest_rst, latch_src_rst}),
    .out_bits (fault_vec_sync));

  sync_bits #(
    .NUM_OF_BITS (3),
    .ASYNC_CLK (1)
  ) i_sync_ext_releases (
    .out_clk (clk),
    .out_resetn (1'b1),
    .in_bits ({sg_ext_resetn, dest_ext_resetn, src_ext_resetn}),
    .out_bits ({ext_rel_sg, ext_rel_dest, ext_rel_src}));

  wire fault_src_s = fault_vec_sync[0];
  wire fault_dest_s = fault_vec_sync[1];
  wire fault_sg_s = (DMA_SG_TRANSFER == 1) ? fault_vec_sync[2] : 1'b0;
  wire any_ext_fault = fault_src_s | fault_dest_s | fault_sg_s;

  // Track domain acknowledgements during startup so an interrupted startup
  // does not drop do_enable mid-CDC and trigger a premature reset pulse.
  reg [3:0] startup_seen_q = 4'b0000;
  reg req_en_issued_q = 1'b0;

  always @(posedge clk) begin
    if (!resetn || state == STATE_RESET || state == STATE_DISABLED) begin
      startup_seen_q <= 4'b0000;
      req_en_issued_q <= 1'b0;
    end else begin
      if (req_enable)
        req_en_issued_q <= 1'b1;
      startup_seen_q <= startup_seen_q | {enabled_sg, enabled_dest, enabled_src, req_enabled};
    end
  end

  wire req_startup_settled = (~req_en_issued_q) | startup_seen_q[0] | req_enabled;
  wire src_startup_settled = startup_seen_q[1] | enabled_src | fault_src_s;
  wire dest_startup_settled = startup_seen_q[2] | enabled_dest | fault_dest_s;
  wire sg_startup_settled = (DMA_SG_TRANSFER == 0) | (~ctrl_hwdesc) | startup_seen_q[3] | enabled_sg | fault_sg_s;
  wire startup_abort_ready = req_startup_settled & src_startup_settled & dest_startup_settled & sg_startup_settled;

  generate if (DMA_SG_TRANSFER == 1) begin
  assign enabled_all = req_enabled & enabled_src & enabled_dest & (enabled_sg | ~ctrl_hwdesc);
  assign disabled_all = ~(req_enabled | enabled_src | enabled_dest | (enabled_sg & ctrl_hwdesc));
  end else begin
  assign enabled_all = req_enabled & enabled_src & enabled_dest;
  assign disabled_all = ~(req_enabled | enabled_src | enabled_dest);
  end endgenerate

  assign req_enable = do_enable & ~any_ext_fault;

  assign dbg_status = {needs_reset,req_resetn,src_resetn,dest_resetn,sg_resetn,req_enabled,enabled_src,enabled_dest,enabled_sg,state};

  always @(posedge clk) begin
    if (state == STATE_DO_RESET) begin
      do_reset <= 1'b1;
    end else begin
      do_reset <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (state == STATE_STARTUP || state == STATE_ENABLED) begin
      do_enable <= 1'b1;
    end else begin
      do_enable <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (state == STATE_RESET) begin
      needs_reset <= 1'b0;
    end else if (ctrl_enable == 1'b0 || any_ext_fault) begin
      needs_reset <= 1'b1;
    end
  end

  always @(posedge clk) begin
    if (resetn == 1'b0) begin
      state <= STATE_DO_RESET;
    end else begin
      case (state)
      STATE_DO_RESET: begin
        state <= STATE_RESET;
      end
      STATE_RESET: begin
        if (ctrl_enable == 1'b1 && req_resetn == 1'b1 && all_ext_released && !any_ext_fault) begin
          state <= STATE_DISABLED;
        end
      end
      STATE_DISABLED: begin
        if (needs_reset == 1'b1 || any_ext_fault) begin
          state <= STATE_DO_RESET;
        end else if (ctrl_pause == 1'b0) begin
          state <= STATE_STARTUP;
        end
      end
      STATE_STARTUP: begin
        if (any_ext_fault) begin
          if (startup_abort_ready) begin
            state <= STATE_SHUTDOWN;
          end
        end else if (enabled_all == 1'b1) begin
          state <= STATE_ENABLED;
        end
      end
      STATE_ENABLED: begin
        if (needs_reset == 1'b1 || ctrl_pause == 1'b1 || any_ext_fault) begin
          state <= STATE_SHUTDOWN;
        end
      end
      STATE_SHUTDOWN: begin
        if (disabled_all == 1'b1 && all_ext_released == 1'b1) begin
          state <= STATE_DISABLED;
        end
      end
      endcase
    end
  end

  localparam NUM_RESET_LINKS = DMA_SG_TRANSFER ? 4 : 3;
  localparam GEN_ASYNC_RESET = {
    ASYNC_CLK_REQ_SG ? 1'b1 : 1'b0,
    ASYNC_CLK_REQ_SRC ? 1'b1 : 1'b0,
    ASYNC_CLK_SRC_DEST ? 1'b1 : 1'b0,
    1'b1
  };

  wire [NUM_RESET_LINKS:0] reset_async_chain;
  wire [NUM_RESET_LINKS:0] reset_sync_chain;
  wire [3:0] reset_chain_clks = {sg_clk, clk, src_clk, dest_clk};

  assign reset_async_chain[0] = 1'b0;
  assign reset_sync_chain[0] = reset_async_chain[3];

  generate
  genvar i;

  for (i = 0; i < NUM_RESET_LINKS; i = i + 1) begin: reset_gen

    if (GEN_ASYNC_RESET[i] == 1'b1) begin

      reg [3:0] reset_async = 4'b1111;
      reg [1:0] reset_sync = 2'b11;
      reg reset_sync_in = 1'b1;

      always @(posedge reset_chain_clks[i] or posedge reset_sync_chain[i]) begin
        if (reset_sync_chain[i] == 1'b1) begin
          reset_sync_in <= 1'b1;
        end else begin
          reset_sync_in <= reset_async[0];
        end
      end

      always @(posedge reset_chain_clks[i] or posedge do_reset) begin
        if (do_reset == 1'b1) begin
          reset_async <= 4'b1111;
        end else begin
          reset_async <= {reset_async_chain[i], reset_async[3:1]};
        end
      end

      always @(posedge reset_chain_clks[i]) begin
        reset_sync <= {reset_sync_in,reset_sync[1]};
      end

      assign reset_async_chain[i+1] = reset_async[0];
      assign reset_sync_chain[i+1] = reset_sync[0];

    end else begin
      assign reset_async_chain[i+1] = reset_async_chain[i];
      assign reset_sync_chain[i+1] = reset_sync_chain[i];
    end
  end

  endgenerate

  /* De-assertions in the opposite direction of the data flow: dest, src, request */
  assign dest_resetn = ~reset_sync_chain[1] & dest_ext_sync_q[1];
  assign src_resetn = ~reset_sync_chain[2] & src_ext_sync_q[1];
  assign req_resetn = ~reset_sync_chain[3];
  generate if (DMA_SG_TRANSFER == 1) begin
  assign sg_resetn = ~reset_sync_chain[4] & sg_ext_sync_q[1];
  end else begin
  assign sg_resetn = 1'b0;
  end endgenerate

  sync_bits #(
    .NUM_OF_BITS (1),
    .ASYNC_CLK (ASYNC_CLK_DEST_REQ)
  ) i_sync_control_dest (
    .out_clk (dest_clk),
    .out_resetn (1'b1),
    .in_bits (do_enable),
    .out_bits (dest_enable));

  sync_bits #(
    .NUM_OF_BITS (1),
    .ASYNC_CLK (ASYNC_CLK_DEST_REQ)
  ) i_sync_status_dest (
    .out_clk (clk),
    .out_resetn (1'b1),
    .in_bits (dest_enabled),
    .out_bits (enabled_dest));

  sync_bits #(
    .NUM_OF_BITS (1),
    .ASYNC_CLK (ASYNC_CLK_REQ_SRC)
  ) i_sync_control_src (
    .out_clk (src_clk),
    .out_resetn (1'b1),
    .in_bits (do_enable),
    .out_bits (src_enable));

  sync_bits #(
    .NUM_OF_BITS (1),
    .ASYNC_CLK (ASYNC_CLK_REQ_SRC)
  ) i_sync_status_src (
    .out_clk (clk),
    .out_resetn (1'b1),
    .in_bits (src_enabled),
    .out_bits (enabled_src));

  generate if (DMA_SG_TRANSFER == 1) begin
  sync_bits #(
    .NUM_OF_BITS (1),
    .ASYNC_CLK (ASYNC_CLK_REQ_SG)
  ) i_sync_control_sg (
    .out_clk (sg_clk),
    .out_resetn (1'b1),
    .in_bits (do_enable),
    .out_bits (sg_enable));

  sync_bits #(
    .NUM_OF_BITS (1),
    .ASYNC_CLK (ASYNC_CLK_REQ_SG)
  ) i_sync_status_sg (
    .out_clk (clk),
    .out_resetn (1'b1),
    .in_bits (sg_enabled),
    .out_bits (enabled_sg));

  end else begin
  assign sg_enable = 1'b0;
  assign enabled_sg = 1'b0;
  end endgenerate

endmodule
