// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_xif_offload_subsys
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
  import redmule_xif_pkg::*;
#(
  parameter int unsigned DataW                 = 128,
  parameter int unsigned Height                = 4,
  parameter int unsigned Width                 = 4,
  parameter int unsigned NumPipeRegs           = 1,
  parameter int unsigned FpWidth               = 16,
  parameter int unsigned InstFifoDepth         = 4,
  parameter int unsigned OpIdWidth             = 4,
  parameter int unsigned XifIdWidth            = DefaultXifIdWidth,
  parameter int unsigned XifNumHarts           = DefaultXifNumHarts,
  parameter int unsigned XifIssueRegisterSplit = 0,
  parameter logic [6:0]  McnfigOpCode          = 7'b0001011,
  parameter logic [6:0]  MarithOpCode          = 7'b0001011,
  parameter logic [6:0]  MopcntOpCode          = 7'b0001011,
  parameter logic [2:0]  McnfigFunct3          = 3'b000,
  parameter logic [2:0]  MarithFunct3          = 3'b001,
  parameter logic [2:0]  MopcntFunct3          = 3'b010,
  parameter logic [1:0]  McnfigFunct2          = 2'b00,
  parameter logic [1:0]  MarithFunct2          = 2'b00,
  parameter logic [1:0]  MopcntFunct2          = 2'b00,
  parameter type         x_issue_req_t         = default_xif_issue_req_t,
  parameter type         x_issue_resp_t        = default_xif_issue_resp_t,
  parameter type         x_register_t          = default_xif_register_t,
  parameter type         x_commit_t            = default_xif_commit_t,
  parameter type         x_result_t            = default_xif_result_t
)(
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             clear_i,
  input  logic             test_mode_i,
  // CORE-V-XIF offload interface
  input  x_issue_req_t     x_issue_req_i,
  output x_issue_resp_t    x_issue_resp_o,
  input  logic             x_issue_valid_i,
  output logic             x_issue_ready_o,
  input  x_register_t      x_register_i,
  input  logic             x_register_valid_i,
  output logic             x_register_ready_o,
  input  x_commit_t        x_commit_i,
  input  logic             x_commit_valid_i,
  output x_result_t        x_result_o,
  output logic             x_result_valid_o,
  input  logic             x_result_ready_i,
  // Systolic engine / streamer handshake & status
  input  flgs_streamer_t   flgs_streamer_i,
  input  logic             reg_enable_i,
  input  logic             z_fifo_empty_i,
  input  logic             z_fifo_full_i,
  input  logic             w_loaded_i,
  output logic             busy_o,
  output logic             tiler_busy_o,
  output logic             ctrl_clear_o,
  output logic             evt_o,
  output logic             engine_flush_o,
  output cntrl_scheduler_t cntrl_scheduler_o,
  output cntrl_flags_t     cntrl_flags_o,
  output redmule_config_t  active_config_o,
  output logic             config_fifo_full_o,
  output logic             config_fifo_empty_o,
  output logic             cfg_complete_o
);

  logic            dec_config_valid;
  redmule_config_t dec_config, dec_config_q, redmule_config;
  logic            config_fifo_full, config_fifo_empty;
  logic            cfg_complete;

  redmule_inst_decoder #(
    .McnfigOpCode          ( McnfigOpCode          ),
    .MarithOpCode          ( MarithOpCode          ),
    .MopcntOpCode          ( MopcntOpCode          ),
    .McnfigFunct3          ( McnfigFunct3          ),
    .MarithFunct3          ( MarithFunct3          ),
    .MopcntFunct3          ( MopcntFunct3          ),
    .McnfigFunct2          ( McnfigFunct2          ),
    .MarithFunct2          ( MarithFunct2          ),
    .MopcntFunct2          ( MopcntFunct2          ),
    .InstFifoDepth         ( InstFifoDepth         ),
    .OpIdWidth             ( OpIdWidth             ),
    .XifIdWidth            ( XifIdWidth            ),
    .XifNumHarts           ( XifNumHarts           ),
    .XifIssueRegisterSplit ( XifIssueRegisterSplit ),
    .x_issue_req_t         ( x_issue_req_t         ),
    .x_issue_resp_t        ( x_issue_resp_t        ),
    .x_register_t          ( x_register_t          ),
    .x_commit_t            ( x_commit_t            ),
    .x_result_t            ( x_result_t            )
  ) i_inst_decoder (
    .clk_i              ( clk_i              ),
    .rst_ni             ( rst_ni             ),
    .clear_i            ( clear_i            ),
    .config_ready_i     ( ~config_fifo_full  ),
    .op_done_i          ( evt_o              ),
    .config_valid_o     ( dec_config_valid   ),
    .config_o           ( dec_config         ),
    .x_issue_req_i      ( x_issue_req_i      ),
    .x_issue_resp_o     ( x_issue_resp_o     ),
    .x_issue_valid_i    ( x_issue_valid_i    ),
    .x_issue_ready_o    ( x_issue_ready_o    ),
    .x_register_i       ( x_register_i       ),
    .x_register_valid_i ( x_register_valid_i ),
    .x_register_ready_o ( x_register_ready_o ),
    .x_commit_i         ( x_commit_i         ),
    .x_commit_valid_i   ( x_commit_valid_i   ),
    .x_result_o         ( x_result_o         ),
    .x_result_valid_o   ( x_result_valid_o   ),
    .x_result_ready_i   ( x_result_ready_i   )
  );

  redmule_config_fifo #(
    .FALL_THROUGH ( 0                ),
    .DEPTH        ( 2                ),
    .dtype        ( redmule_config_t )
  ) i_config_fifo (
    .clk_i      ( clk_i                                      ),
    .rst_ni     ( rst_ni                                     ),
    .flush_i    ( clear_i                                    ),
    .testmode_i ( test_mode_i                                ),
    .full_o     ( config_fifo_full                           ),
    .empty_o    ( config_fifo_empty                          ),
    .usage_o    (                                            ),
    .data_i     ( dec_config                                 ),
    .push_i     ( dec_config_valid                           ),
    .data_o     ( dec_config_q                               ),
    .pop_i      ( cfg_complete && !redmule_config.loopback_w )
  );

  redmule_ctrl #(
    .DataW    ( DataW       ),
    .Height   ( Height      ),
    .Width    ( Width       ),
    .PipeRegs ( NumPipeRegs ),
    .FpWidth  ( FpWidth     )
  ) i_control (
    .clk_i             ( clk_i              ),
    .rst_ni            ( rst_ni             ),
    .test_mode_i       ( test_mode_i        ),
    .flgs_streamer_i   ( flgs_streamer_i    ),
    .busy_o            ( busy_o             ),
    .tiler_busy_o      ( tiler_busy_o       ),
    .target_clear_i    ( clear_i            ),
    .clear_o           ( ctrl_clear_o       ),
    .evt_o             ( evt_o              ),
    .config_i          ( dec_config_q       ),
    .config_o          ( redmule_config     ),
    .reg_enable_i      ( reg_enable_i       ),
    .fifo_empty_i      ( z_fifo_empty_i     ),
    .fifo_ready_i      ( ~z_fifo_full_i     ),
    .start_cfg_i       ( ~config_fifo_empty ),
    .cfg_complete_o    ( cfg_complete       ),
    .w_loaded_i        ( w_loaded_i         ),
    .flush_o           ( engine_flush_o     ),
    .cntrl_scheduler_o ( cntrl_scheduler_o  ),
    .cntrl_flags_o     ( cntrl_flags_o      )
  );

  assign active_config_o     = redmule_config;
  assign config_fifo_full_o  = config_fifo_full;
  assign config_fifo_empty_o = config_fifo_empty;
  assign cfg_complete_o      = cfg_complete;

endmodule : redmule_xif_offload_subsys
