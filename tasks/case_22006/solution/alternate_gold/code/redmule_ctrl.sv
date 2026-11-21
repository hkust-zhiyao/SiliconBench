// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Alternate Gold implementation: Explicit 7-state controller FSM with dedicated
// REDMULE_TILING state (eliminating auxiliary slave_start flag).

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
  input  logic                    w_loaded_i        ,
  output logic                    flush_o           ,
  output cntrl_scheduler_t        cntrl_scheduler_o ,
  output cntrl_flags_t            cntrl_flags_o
);

  typedef enum logic [2:0] {
    ST_LATCH_RST,
    ST_IDLE,
    ST_TILING,
    ST_STARTING,
    ST_COMPUTING,
    ST_LOOPBACK,
    ST_FINISHED
  } ctrl_fsm_e;

  ctrl_fsm_e       state_q, state_d;
  logic            tiler_valid, tiler_req, loopback_trig;
  logic            multi_pass_q, multi_pass_d;
  logic            reord_empty;
  redmule_config_t tiled_cfg;

  assign tiler_req = ((state_q == ST_IDLE) && start_cfg_i && fifo_ready_i) ||
                     ((state_q == ST_TILING) && fifo_ready_i && !tiler_valid);

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
    .setback_i   ( tiler_valid    ),
    .loopback_i  ( loopback_trig  ),
    .start_cfg_i ( tiler_req      ),
    .valid_o     ( tiler_valid    ),
    .busy_o      ( tiler_busy_o   ),
    .ready_i     ( fifo_ready_i   ),
    .config_i    ( config_i       ),
    .config_o    ( tiled_cfg      )
  );

  assign cfg_complete_o = tiler_valid;
  assign config_o       = tiled_cfg;
  assign reord_empty    = EnableReordering ? flgs_streamer_i.store_fifo_empty : 1'b1;
  assign loopback_trig  = (state_q == ST_COMPUTING) && (state_d == ST_LOOPBACK);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_LATCH_RST;
      multi_pass_q <= 1'b0;
    end else if (target_clear_i) begin
      state_q      <= ST_LATCH_RST;
      multi_pass_q <= 1'b0;
    end else begin
      state_q      <= state_d;
      multi_pass_q <= multi_pass_d;
    end
  end

  always_comb begin
    state_d            = state_q;
    multi_pass_d       = multi_pass_q;
    cntrl_flags_o.idle = 1'b0;

    unique case (state_q)
      ST_LATCH_RST: begin
        cntrl_flags_o.idle = 1'b1;
        multi_pass_d       = 1'b0;
        state_d            = ST_IDLE;
      end
      ST_IDLE: begin
        cntrl_flags_o.idle = 1'b1;
        if (test_mode_i) begin
          state_d = ST_STARTING;
        end else if (start_cfg_i && fifo_ready_i) begin
          multi_pass_d = (config_i.w_cols_offset != '0);
          state_d      = ST_TILING;
        end
      end
      ST_TILING: begin
        cntrl_flags_o.idle = 1'b1;
        multi_pass_d       = (config_i.w_cols_offset != '0);
        if (tiler_valid) begin
          state_d = ST_STARTING;
        end
      end
      ST_LOOPBACK: begin
        cntrl_flags_o.idle = 1'b1;
        multi_pass_d       = 1'b0;
        if (tiler_valid) begin
          state_d = ST_STARTING;
        end
      end
      ST_STARTING: begin
        if (w_loaded_i) begin
          state_d = ST_COMPUTING;
        end
      end
      ST_COMPUTING: begin
        if (flgs_streamer_i.z_stream_sink_flags.ready_start && fifo_empty_i &&
            flgs_streamer_i.store_fifo_empty && reord_empty) begin
          state_d = multi_pass_q ? ST_LOOPBACK : ST_FINISHED;
        end
      end
      ST_FINISHED: begin
        multi_pass_d = 1'b0;
        state_d      = ST_IDLE;
      end
      default: begin
        state_d = ST_IDLE;
      end
    endcase
  end

  assign busy_o                           = (state_q != ST_LATCH_RST) && (state_q != ST_IDLE);
  assign flush_o                          = (state_q == ST_FINISHED) || loopback_trig;
  assign evt_o                            = (state_q == ST_FINISHED);
  assign clear_o                          = target_clear_i || (state_q == ST_LATCH_RST) || (state_q == ST_FINISHED) || loopback_trig;

  assign cntrl_scheduler_o.start_fsm      = 1'b0;
  assign cntrl_scheduler_o.first_load     = (state_q == ST_STARTING);
  assign cntrl_scheduler_o.engine_working = 1'b0;
  assign cntrl_scheduler_o.storing        = 1'b0;
  assign cntrl_scheduler_o.rst            = (state_q == ST_FINISHED) || loopback_trig;
  assign cntrl_scheduler_o.finished       = (state_q == ST_FINISHED);
  assign cntrl_scheduler_o.done           = 1'b0;

endmodule : redmule_ctrl
