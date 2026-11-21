// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
// Andrea Belano <andrea.belano2@unibo.it>
//

import redmule_pkg::*;

module redmule_ctrl
  import hwpe_ctrl_package::*;
#(
  parameter int unsigned DataW = 0,
  parameter int unsigned Height = MaxDim,
  parameter int unsigned Width = MaxDim,
  parameter int unsigned PipeRegs = MaxPipeRegs-1,
  parameter int unsigned FpWidth = 16,
  parameter bit          EnableReordering = 1'b0
)(
  input  logic                    clk_i             ,
  input  logic                    rst_ni            ,
  input  logic                    test_mode_i       ,
  output logic                    busy_o            ,
  input  logic                    target_clear_i    ,
  output logic                    clear_o           ,
  output logic                    evt_o             ,
  input  redmule_config_t         config_i          ,
  output redmule_config_t         config_o          ,
  input  logic                    reg_enable_i      ,
  input  logic                    start_cfg_i       ,
  output logic                    tiler_busy_o      ,
  input  logic                    fifo_empty_i      ,
  input  logic                    fifo_ready_i      ,
  input  flgs_streamer_t          flgs_streamer_i   ,
  output logic                    cfg_complete_o    ,
  // Flags coming from the state machine
  input  logic                    w_loaded_i        ,
  // Control signals for the engine
  output logic                    flush_o           ,
  // Control signals for the state machine
  output cntrl_scheduler_t        cntrl_scheduler_o ,
  output cntrl_flags_t            cntrl_flags_o
);

  logic        latch_clear;
  logic        tiler_setback, tiler_valid;
  logic        tiler_start;
  logic        fifo_z_empty;
  logic        set_offset_q, set_offset_d, loopback_reset;

  typedef enum logic [2:0] {
    REDMULE_LATCH_RST,
    REDMULE_IDLE,
    REDMULE_STARTING,
    REDMULE_COMPUTING,
    REDMULE_LOOPBACK,
    REDMULE_FINISHED
  } redmule_ctrl_state_e;

  redmule_ctrl_state_e current, next;

  redmule_config_t redmule_config;

  // Gate tiler start strictly to REDMULE_IDLE with downstream FIFO readiness so queued jobs in
  // i_config_fifo never overwrite redmule_config or assert cfg_complete_o mid-computation.
  assign tiler_start = start_cfg_i && (current == REDMULE_IDLE) && fifo_ready_i && !tiler_valid;

  redmule_tiler #(
    .DataW    ( DataW    ),
    .Height   ( Height   ),
    .Width    ( Width    ),
    .PipeRegs ( PipeRegs ),
    .FpWidth  ( FpWidth  )
  ) i_cfg_tiler (
    .clk_i       ( clk_i          ),
    .rst_ni      ( rst_ni         ),
    .clear_i     ( target_clear_i ),
    .setback_i   ( tiler_setback  ),
    .loopback_i  ( loopback_reset ),
    .start_cfg_i ( tiler_start    ),
    .valid_o     ( tiler_valid    ),
    .busy_o      ( tiler_busy_o   ),
    .ready_i     ( fifo_ready_i   ),
    .config_i    ( config_i       ),
    .config_o    ( redmule_config )
  );

  assign cfg_complete_o = tiler_valid;

  // State register
  always_ff @(posedge clk_i or negedge rst_ni) begin : state_register
    if (~rst_ni) begin
      current <= REDMULE_LATCH_RST;
    end else if (target_clear_i) begin
      current <= REDMULE_LATCH_RST;
    end else begin
      current <= next;
    end
  end

  // Set offset flag
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      set_offset_q <= 1'b0;
    end else begin
      if (target_clear_i || latch_clear || current == REDMULE_FINISHED || loopback_reset)
        set_offset_q <= 1'b0;
      else
        set_offset_q <= set_offset_d;
    end
  end

  logic slave_start;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      slave_start <= 1'b0;
    end else if (target_clear_i) begin
      slave_start <= 1'b0;
    end else begin
      if (tiler_setback)
        slave_start <= 1'b0;
      else if (tiler_start)
        slave_start <= 1'b1;
    end
  end

  assign config_o = redmule_config;

  assign cntrl_scheduler_o.first_load = current == REDMULE_STARTING;
  assign cntrl_scheduler_o.start_fsm  = 1'b0;
  assign cntrl_scheduler_o.engine_working = 1'b0;
  assign cntrl_scheduler_o.storing    = 1'b0;
  assign cntrl_scheduler_o.done       = 1'b0;
  assign tiler_setback                = tiler_valid;
  assign busy_o                       = slave_start | (current != REDMULE_LATCH_RST && current != REDMULE_IDLE);
  assign loopback_reset               = current == REDMULE_COMPUTING && next == REDMULE_LOOPBACK;
  assign flush_o                      = current == REDMULE_FINISHED || loopback_reset;
  assign cntrl_scheduler_o.rst        = current == REDMULE_FINISHED || loopback_reset;
  assign cntrl_scheduler_o.finished   = current == REDMULE_FINISHED;
  assign latch_clear                  = current == REDMULE_LATCH_RST;
  assign fifo_z_empty                 = EnableReordering ? flgs_streamer_i.store_fifo_empty : 1'b1;

  always_comb begin : controller_fsm
    cntrl_flags_o.idle = 1'b0;
    next = current;
    set_offset_d = set_offset_q;

    case (current)
      REDMULE_LATCH_RST: begin
        cntrl_flags_o.idle = 1'b1;
        set_offset_d = 1'b0;
        next = REDMULE_IDLE;
      end

      REDMULE_IDLE: begin
        cntrl_flags_o.idle = 1'b1;
        if (tiler_start || slave_start) begin
          set_offset_d = config_i.w_cols_offset != '0;
        end
        if ((slave_start && tiler_valid) || test_mode_i) begin
          next = REDMULE_STARTING;
        end
      end

      REDMULE_LOOPBACK: begin
        cntrl_flags_o.idle = 1'b1;
        set_offset_d = 1'b0;
        if (tiler_valid) begin
          next = REDMULE_STARTING;
        end
      end

      REDMULE_STARTING: begin
        if (w_loaded_i) begin
          next = REDMULE_COMPUTING;
        end
      end

      REDMULE_COMPUTING: begin
        if (flgs_streamer_i.z_stream_sink_flags.ready_start && fifo_empty_i
            && flgs_streamer_i.store_fifo_empty && fifo_z_empty) begin
          if (set_offset_q) begin
            next = REDMULE_LOOPBACK;
          end else begin
            next = REDMULE_FINISHED;
          end
        end
      end

      REDMULE_FINISHED: begin
        next = REDMULE_IDLE;
      end

      default: begin
        next = REDMULE_IDLE;
      end
    endcase
  end

  // Single-cycle completion pulse strictly after store FIFO drain in REDMULE_FINISHED
  assign evt_o   = (current == REDMULE_FINISHED);
  assign clear_o = target_clear_i || latch_clear || current == REDMULE_FINISHED || loopback_reset;

endmodule : redmule_ctrl
