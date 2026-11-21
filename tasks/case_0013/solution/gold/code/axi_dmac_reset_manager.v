// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2023 Analog Devices, Inc. All rights reserved.
//
// In this HDL repository, there are many different and unique modules, consisting
// of various HDL (Verilog or VHDL) components. The individual modules are
// developed independently, and may be accompanied by separate and unique license
// terms.
//
// The user should read each of these license terms, and understand the
// freedoms and responsibilities that he or she has by using this source/core.
//
// This core is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//
//   1. The GNU General Public License version 2 as published by the
//      Free Software Foundation, which can be found in the top level directory
//      of this repository (LICENSE_GPL2), and also online at:
//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
//
// OR
//
//   2. An ADI specific BSD license, which can be found in the top level directory
//      of this repository (LICENSE_ADIBSD), and also on-line at:
//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
//      This will allow to generate bit files and not release the source code,
//      as long as it attaches to an ADI device.
//
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

  /*
   * TODO:
   * If an external reset is asserted for a domain that domain will go into reset
   * immediately. If a transfer is currently active the transfer will be aborted
   * and other domains will be shutdown gracefully. The reset manager will stay in
   * the shutdown state until all external resets have been de-asserted.
   */

  localparam STATE_DO_RESET = 3'h0;
  localparam STATE_RESET = 3'h1;
  localparam STATE_DISABLED = 3'h2;
  localparam STATE_STARTUP = 3'h3;
  localparam STATE_ENABLED = 3'h4;
  localparam STATE_SHUTDOWN = 3'h5;
  localparam STATE_ABORT_STARTUP = 3'h6;

  reg [2:0] state = 3'b000;
  reg needs_reset = 1'b0;
  reg do_reset = 1'b0;
  reg do_enable = 1'b0;

  // Asynchronously remember even short reset assertions until shutdown reaches reset.
  reg src_fault = 1'b0, dest_fault = 1'b0, sg_fault = 1'b0;
  wire src_fault_sync, dest_fault_sync, sg_fault_sync;
  wire src_released, dest_released, sg_released;
  wire external_fault = src_fault_sync | dest_fault_sync | (DMA_SG_TRANSFER && sg_fault_sync);
  wire external_released = src_released & dest_released & (!DMA_SG_TRANSFER | sg_released);
  always @(posedge clk or negedge src_ext_resetn or negedge resetn)
    if (!src_ext_resetn) src_fault <= 1'b1;
    else if (!resetn) src_fault <= 1'b0;
    else if (state == STATE_RESET && external_released) src_fault <= 1'b0;
  always @(posedge clk or negedge dest_ext_resetn or negedge resetn)
    if (!dest_ext_resetn) dest_fault <= 1'b1;
    else if (!resetn) dest_fault <= 1'b0;
    else if (state == STATE_RESET && external_released) dest_fault <= 1'b0;
  always @(posedge clk or negedge sg_ext_resetn or negedge resetn)
    if (!sg_ext_resetn) sg_fault <= 1'b1;
    else if (!resetn) sg_fault <= 1'b0;
    else if (state == STATE_RESET && external_released) sg_fault <= 1'b0;
  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) fault_src (.in_bits(src_fault), .out_clk(clk), .out_resetn(1'b1), .out_bits(src_fault_sync));
  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) fault_dest (.in_bits(dest_fault), .out_clk(clk), .out_resetn(1'b1), .out_bits(dest_fault_sync));
  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) fault_sg (.in_bits(sg_fault), .out_clk(clk), .out_resetn(1'b1), .out_bits(sg_fault_sync));
  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) release_src (.in_bits(src_ext_resetn), .out_clk(clk), .out_resetn(1'b1), .out_bits(src_released));
  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) release_dest (.in_bits(dest_ext_resetn), .out_clk(clk), .out_resetn(1'b1), .out_bits(dest_released));
  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) release_sg (.in_bits(sg_ext_resetn), .out_clk(clk), .out_resetn(1'b1), .out_bits(sg_released));
  reg [1:0] src_release = 0, dest_release = 0, sg_release = 0;
  always @(posedge src_clk or negedge src_ext_resetn or negedge resetn)
    if (!src_ext_resetn || !resetn) src_release <= 0; else src_release <= {src_release[0],1'b1};
  always @(posedge dest_clk or negedge dest_ext_resetn or negedge resetn)
    if (!dest_ext_resetn || !resetn) dest_release <= 0; else dest_release <= {dest_release[0],1'b1};
  always @(posedge sg_clk or negedge sg_ext_resetn or negedge resetn)
    if (!sg_ext_resetn || !resetn) sg_release <= 0; else sg_release <= {sg_release[0],1'b1};

  wire enabled_dest;
  wire enabled_src;
  wire enabled_sg;

  wire enabled_all;
  wire disabled_all;
  reg req_started=0, seen_req=0, seen_src=0, seen_dest=0, seen_sg=0;
  always @(posedge clk) begin
    if (!resetn || state == STATE_DISABLED || state == STATE_RESET) begin
      req_started<=0; seen_req<=0; seen_src<=0; seen_dest<=0; seen_sg<=0;
    end else begin
      if (req_enable) req_started<=1;
      if (req_enabled) seen_req<=1;
      if (enabled_src) seen_src<=1;
      if (enabled_dest) seen_dest<=1;
      if (enabled_sg) seen_sg<=1;
    end
  end
  wire startup_drained = (!req_started || seen_req || req_enabled)
      && (seen_src || enabled_src || src_fault_sync)
      && (seen_dest || enabled_dest || dest_fault_sync)
      && (!DMA_SG_TRANSFER || !ctrl_hwdesc || seen_sg || enabled_sg || sg_fault_sync);

  generate if (DMA_SG_TRANSFER == 1) begin
  assign enabled_all = req_enabled & enabled_src & enabled_dest & (enabled_sg | ~ctrl_hwdesc);
  assign disabled_all = ~(req_enabled | enabled_src | enabled_dest | (enabled_sg & ctrl_hwdesc));
  end else begin
  assign enabled_all = req_enabled & enabled_src & enabled_dest;
  assign disabled_all = ~(req_enabled | enabled_src | enabled_dest);
  end endgenerate

  assign req_enable = do_enable & ~external_fault;

  assign dbg_status = {needs_reset,req_resetn,src_resetn,dest_resetn,sg_resetn,req_enabled,enabled_src,enabled_dest,enabled_sg,state};

  always @(posedge clk) begin
    if (state == STATE_DO_RESET) begin
      do_reset <= 1'b1;
    end else begin
      do_reset <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (state == STATE_STARTUP || state == STATE_ENABLED || state == STATE_ABORT_STARTUP) begin
      do_enable <= 1'b1;
    end else begin
      do_enable <= 1'b0;
    end
  end

  /*
   * If ctrl_enable goes from 1 to 0 a shutdown procedure is initiated. During the
   * shutdown procedure all domains are signaled that a shutdown should occur. The
   * domains will then complete any active transactions that are required to
   * complete according to the interface semantics. Once a domain has completed
   * its transactions it will indicate that it has been shutdown. Once all domains
   * indicate that they have been disabled a reset pulse will be generated to all
   * domains to clear all residual state. The reset pulse is long enough so that it
   * is active in all domains for at least 4 clock cycles.
   *
   * Once the reset signal is de-asserted the DMA is in an idle state and can be
   * enabled again. If the DMA receives a enable while it is performing a shutdown
   * sequence it will only be re-enabled once the shutdown sequence has
   * successfully completed.
   *
   * If ctrl_pause is asserted all domains will be disabled. But there will be no
   * reset, so when the ctrl_pause signal is de-asserted again the DMA will resume
   * with its previous state.
   *
   */

  /*
   * If ctrl_enable goes low, even for a single clock cycle, we want to go through
   * a full reset sequence. This might happen when the state machine is busy, e.g.
   * going through a startup sequence. To avoid missing the event store it for
   * later.
   */
  always @(posedge clk) begin
    if (state == STATE_RESET) begin
      needs_reset <= 1'b0;
    end else if (ctrl_enable == 1'b0 || external_fault) begin
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
        /*
         * Wait for the reset sequence to complete. Stay in this state when
         * ctrl_enable == 1'b0, otherwise we'd go through the reset sequence
         * again and again.
         */
        if (ctrl_enable == 1'b1 && req_resetn == 1'b1 && external_released && !external_fault) begin
          state <= STATE_DISABLED;
        end
      end
      STATE_DISABLED: begin
        if (needs_reset == 1'b1 || external_fault) begin
          state <= STATE_DO_RESET;
        end else if (ctrl_pause == 1'b0) begin
          state <= STATE_STARTUP;
        end
      end
      STATE_STARTUP: begin
        /* Wait for all domains to be ready */
        if (external_fault) begin
          state <= STATE_ABORT_STARTUP;
        end else if (enabled_all == 1'b1) begin
          state <= STATE_ENABLED;
        end
      end
      STATE_ABORT_STARTUP: begin
        if (startup_drained) state <= STATE_SHUTDOWN;
      end
      STATE_ENABLED: begin
        if (needs_reset == 1'b1 || ctrl_pause == 1'b1 || external_fault) begin
          state <= STATE_SHUTDOWN;
        end
      end
      STATE_SHUTDOWN: begin
        /* Wait for all domains to complete outstanding transactions */
        if (disabled_all == 1'b1) begin
          state <= STATE_DISABLED;
        end
      end
      endcase
    end
  end

  /*
   * Chain the reset through all clock domains. This makes sure that is asserted
   * for at least 4 clock cycles of the slowest domain, no matter what. If
   * successive domains have the same clock they'll share their reset signal.
   */

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
  assign dest_resetn = ~reset_sync_chain[1] & dest_release[1];
  assign src_resetn = ~reset_sync_chain[2] & src_release[1];
  assign req_resetn = ~reset_sync_chain[3];
  generate if (DMA_SG_TRANSFER == 1) begin
  assign sg_resetn = ~reset_sync_chain[4] & sg_release[1];
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
