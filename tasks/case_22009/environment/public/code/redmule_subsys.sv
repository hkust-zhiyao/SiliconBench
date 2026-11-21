// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module redmule_subsys
  import fpnew_pkg::*;
  import redmule_pkg::*;
  import hci_package::*;
  import hwpe_ctrl_package::*;
  import hwpe_stream_package::*;
#(
  parameter int unsigned  DataW        = 128,
  parameter fp_format_e   FpFormat     = FP16,
  parameter int unsigned  Height       = 4,
  parameter int unsigned  Width        = 4,
  parameter int unsigned  NumPipeRegs  = 1,
  parameter pipe_config_t PipeConfig   = DISTRIBUTED,
  parameter bit           LatchBuffers = 1'b0
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,
  input  logic                       test_mode_i,
  input  logic                       target_clear_i,

  // Job configuration queue port (mirrors decoder -> i_config_fifo in redmule_top)
  input  logic                       cfg_valid_i,
  output logic                       cfg_ready_o,
  input  redmule_config_t            cfg_i,

  output logic                       busy_o,
  output logic                       evt_o,
  output logic                       done_o,

  // Streamer control / status interface
  output cntrl_streamer_t            cntrl_streamer_o,
  input  flgs_streamer_t             flgs_streamer_i,

  // Incoming X, W, Y streams and outgoing Z stream
  input  logic                       x_stream_valid_i,
  output logic                       x_stream_ready_o,
  input  logic [DataW-1:0]           x_stream_data_i,
  input  logic [DataW/8-1:0]         x_stream_strb_i,

  input  logic                       w_stream_valid_i,
  output logic                       w_stream_ready_o,
  input  logic [DataW-1:0]           w_stream_data_i,
  input  logic [DataW/8-1:0]         w_stream_strb_i,

  input  logic                       y_stream_valid_i,
  output logic                       y_stream_ready_o,
  input  logic [DataW-1:0]           y_stream_data_i,
  input  logic [DataW/8-1:0]         y_stream_strb_i,

  output logic                       z_stream_valid_o,
  input  logic                       z_stream_ready_i,
  output logic [DataW-1:0]           z_stream_data_o,
  output logic [DataW/8-1:0]         z_stream_strb_o
);

  localparam int unsigned FpWidth = fp_width(FpFormat);

  logic            clk_acc;
  logic            clear;
  logic            reg_enable;
  logic            cfg_complete;
  logic            engine_flush;
  logic            tiler_busy;
  logic            x_done;
  logic            z_fifo_empty, z_fifo_full;
  logic            config_fifo_empty, config_fifo_full;
  logic            sync_unused;

  cntrl_engine_t    cntrl_engine;
  flgs_engine_t     flgs_engine;
  x_buffer_ctrl_t   x_buffer_ctrl;
  x_buffer_flgs_t   x_buffer_flgs;
  w_buffer_ctrl_t   w_buffer_ctrl;
  w_buffer_flgs_t   w_buffer_flgs;
  z_buffer_ctrl_t   z_buffer_ctrl;
  z_buffer_flgs_t   z_buffer_flgs;
  cntrl_scheduler_t cntrl_scheduler;
  flgs_scheduler_t  flgs_scheduler;
  redmule_config_t  redmule_config;
  redmule_config_t  dec_config_q;
  flags_fifo_t      w_fifo_flgs, z_fifo_flgs;
  cntrl_flags_t     cntrl_flags;

  logic busy_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni)
      busy_q <= 1'b0;
    else
      busy_q <= busy_o;
  end

  tc_clk_gating i_acc_clock_gating (
    .clk_i     ( clk_i                                               ),
    .en_i      ( cfg_valid_i | ~config_fifo_empty | busy_o | busy_q  ),
    .test_en_i ( test_mode_i                                         ),
    .clk_o     ( clk_acc                                             )
  );

  assign cfg_ready_o = ~config_fifo_full;
  assign done_o      = cntrl_scheduler.finished;

  logic            x_fifo_valid, x_fifo_ready;
  logic [DataW-1:0] x_fifo_data;
  logic [DataW/8-1:0] x_fifo_strb;

  logic            w_fifo_valid, w_fifo_ready;
  logic [DataW-1:0] w_fifo_data;
  logic [DataW/8-1:0] w_fifo_strb;

  logic            y_fifo_valid, y_fifo_ready;
  logic [DataW-1:0] y_fifo_data;
  logic [DataW/8-1:0] y_fifo_strb;

  logic            z_buf_valid, z_buf_ready;
  logic [DataW-1:0] z_buf_data;
  logic [DataW/8-1:0] z_buf_strb;

  hwpe_stream_fifo #(
    .DATA_WIDTH ( DataW ),
    .FIFO_DEPTH ( 4     )
  ) i_x_buffer_fifo (
    .clk_i        ( clk_acc          ),
    .rst_ni       ( rst_ni           ),
    .clear_i      ( clear            ),
    .flags_o      (                  ),
    .push_valid_i ( x_stream_valid_i ),
    .push_ready_o ( x_stream_ready_o ),
    .push_data_i  ( x_stream_data_i  ),
    .push_strb_i  ( x_stream_strb_i  ),
    .pop_valid_o  ( x_fifo_valid     ),
    .pop_ready_i  ( x_fifo_ready     ),
    .pop_data_o   ( x_fifo_data      ),
    .pop_strb_o   ( x_fifo_strb      )
  );

  hwpe_stream_fifo #(
    .DATA_WIDTH ( DataW ),
    .FIFO_DEPTH ( 4     )
  ) i_w_buffer_fifo (
    .clk_i        ( clk_acc          ),
    .rst_ni       ( rst_ni           ),
    .clear_i      ( clear            ),
    .flags_o      ( w_fifo_flgs      ),
    .push_valid_i ( w_stream_valid_i ),
    .push_ready_o ( w_stream_ready_o ),
    .push_data_i  ( w_stream_data_i  ),
    .push_strb_i  ( w_stream_strb_i  ),
    .pop_valid_o  ( w_fifo_valid     ),
    .pop_ready_i  ( w_fifo_ready     ),
    .pop_data_o   ( w_fifo_data      ),
    .pop_strb_o   ( w_fifo_strb      )
  );

  hwpe_stream_fifo #(
    .DATA_WIDTH ( DataW ),
    .FIFO_DEPTH ( 4     )
  ) i_y_buffer_fifo (
    .clk_i        ( clk_acc          ),
    .rst_ni       ( rst_ni           ),
    .clear_i      ( clear            ),
    .flags_o      (                  ),
    .push_valid_i ( y_stream_valid_i ),
    .push_ready_o ( y_stream_ready_o ),
    .push_data_i  ( y_stream_data_i  ),
    .push_strb_i  ( y_stream_strb_i  ),
    .pop_valid_o  ( y_fifo_valid     ),
    .pop_ready_i  ( y_fifo_ready     ),
    .pop_data_o   ( y_fifo_data      ),
    .pop_strb_o   ( y_fifo_strb      )
  );

  hwpe_stream_fifo #(
    .DATA_WIDTH ( DataW ),
    .FIFO_DEPTH ( 4     )
  ) i_z_buffer_fifo (
    .clk_i        ( clk_acc          ),
    .rst_ni       ( rst_ni           ),
    .clear_i      ( clear            ),
    .flags_o      ( z_fifo_flgs      ),
    .push_valid_i ( z_buf_valid      ),
    .push_ready_o ( z_buf_ready      ),
    .push_data_i  ( z_buf_data       ),
    .push_strb_i  ( z_buf_strb       ),
    .pop_valid_o  ( z_stream_valid_o ),
    .pop_ready_i  ( z_stream_ready_i ),
    .pop_data_o   ( z_stream_data_o  ),
    .pop_strb_o   ( z_stream_strb_o  )
  );

  assign x_fifo_ready = x_buffer_ctrl.load;
  assign w_fifo_ready = w_buffer_flgs.w_ready;
  assign y_fifo_ready = z_buffer_flgs.y_ready;
  assign z_buf_valid  = z_buffer_flgs.z_valid;

  logic [Width-1:0][Height-1:0][FpWidth-1:0] x_buffer_q;
  redmule_x_buffer #(
    .DataW      ( DataW        ),
    .FpFormat   ( FpFormat     ),
    .Height     ( Height       ),
    .Width      ( Width        ),
    .UseLatches ( LatchBuffers )
  ) i_x_buffer (
    .clk_i      ( clk_acc       ),
    .rst_ni     ( rst_ni        ),
    .clear_i    ( clear         ),
    .ctrl_i     ( x_buffer_ctrl ),
    .flags_o    ( x_buffer_flgs ),
    .x_buffer_o ( x_buffer_q    ),
    .x_buffer_i ( x_fifo_data   )
  );

  logic [Height-1:0][FpWidth-1:0] w_buffer_q;
  redmule_w_buffer #(
    .DataW      ( DataW        ),
    .FpFormat   ( FpFormat     ),
    .Height     ( Height       ),
    .NumRegs    ( NumPipeRegs  ),
    .UseLatches ( LatchBuffers )
  ) i_w_buffer (
    .clk_i      ( clk_acc       ),
    .rst_ni     ( rst_ni        ),
    .clear_i    ( clear         ),
    .ctrl_i     ( w_buffer_ctrl ),
    .flags_o    ( w_buffer_flgs ),
    .w_buffer_o ( w_buffer_q    ),
    .w_buffer_i ( w_fifo_data   )
  );

  logic [Width-1:0][FpWidth-1:0] z_buffer_d, y_bias_q;
  redmule_z_buffer #(
    .DataW      ( DataW        ),
    .FpFormat   ( FpFormat     ),
    .Width      ( Width        ),
    .UseLatches ( LatchBuffers )
  ) i_z_buffer (
    .clk_i        ( clk_acc       ),
    .rst_ni       ( rst_ni        ),
    .clear_i      ( clear         ),
    .reg_enable_i ( reg_enable    ),
    .ctrl_i       ( z_buffer_ctrl ),
    .flags_o      ( z_buffer_flgs ),
    .y_buffer_i   ( y_fifo_data   ),
    .z_buffer_i   ( z_buffer_d    ),
    .y_buffer_o   ( y_bias_q      ),
    .z_buffer_o   ( z_buf_data    ),
    .z_strb_o     ( z_buf_strb    )
  );

  logic       [Width-1:0][Height-1:0] in_ready;
  status_t    [Width-1:0][Height-1:0] status;
  logic       [Width-1:0][Height-1:0] extension_bit;
  classmask_e [Width-1:0][Height-1:0] class_mask;
  logic       [Width-1:0][Height-1:0] is_class;
  logic       [Width-1:0][Height-1:0] out_tag;
  logic       [Width-1:0][Height-1:0] out_aux;
  logic       [Width-1:0][Height-1:0] out_valid;
  logic       [Width-1:0][Height-1:0] busy;

  always_comb begin
    flgs_engine = '0;
    for (int w = 0; w < Width; w++) begin
      for (int h = 0; h < Height; h++) begin
        flgs_engine.in_ready      [w][h] = in_ready      [w][h];
        flgs_engine.status        [w][h] = status        [w][h];
        flgs_engine.extension_bit [w][h] = extension_bit [w][h];
        flgs_engine.out_valid     [w][h] = out_valid     [w][h];
        flgs_engine.busy          [w][h] = busy          [w][h];
      end
    end
  end

  redmule_engine #(
    .FpFormat    ( FpFormat    ),
    .Height      ( Height      ),
    .Width       ( Width       ),
    .NumPipeRegs ( NumPipeRegs ),
    .PipeConfig  ( PipeConfig  )
  ) i_redmule_engine (
    .clk_i              ( clk_acc                       ),
    .rst_ni             ( rst_ni                        ),
    .x_input_i          ( x_buffer_q                    ),
    .w_input_i          ( w_buffer_q                    ),
    .y_bias_i           ( y_bias_q                      ),
    .z_output_o         ( z_buffer_d                    ),
    .fma_is_boxed_i     ( cntrl_engine.fma_is_boxed     ),
    .noncomp_is_boxed_i ( cntrl_engine.noncomp_is_boxed ),
    .stage1_rnd_i       ( cntrl_engine.stage1_rnd       ),
    .stage2_rnd_i       ( cntrl_engine.stage2_rnd       ),
    .op1_i              ( cntrl_engine.op1              ),
    .op2_i              ( cntrl_engine.op2              ),
    .op_mod_i           ( cntrl_engine.op_mod           ),
    .tag_i              ( 1'b0                          ),
    .aux_i              ( 1'b0                          ),
    .in_valid_i         ( cntrl_engine.in_valid         ),
    .in_ready_o         ( in_ready                      ),
    .reg_enable_i       ( reg_enable                    ),
    .flush_i            ( cntrl_engine.flush | clear    ),
    .status_o           ( status                        ),
    .extension_bit_o    ( extension_bit                 ),
    .class_mask_o       ( class_mask                    ),
    .is_class_o         ( is_class                      ),
    .tag_o              ( out_tag                       ),
    .aux_o              ( out_aux                       ),
    .out_valid_o        ( out_valid                     ),
    .out_ready_i        ( cntrl_engine.out_ready        ),
    .busy_o             ( busy                          ),
    .ctrl_engine_i      ( cntrl_engine                  )
  );

  logic z_priority;
  assign z_priority = z_buffer_flgs.z_priority & !z_fifo_flgs.empty;

  redmule_memory_scheduler #(
    .DW ( DataW  ),
    .W  ( Width  ),
    .H  ( Height )
  ) i_memory_scheduler (
    .clk_i             ( clk_acc          ),
    .rst_ni            ( rst_ni           ),
    .clear_i           ( target_clear_i   ),
    .z_priority_i      ( z_priority       ),
    .config_i          ( redmule_config   ),
    .config_valid_i    ( cfg_complete     ),
    .flgs_streamer_i   ( flgs_streamer_i  ),
    .cntrl_scheduler_i ( cntrl_scheduler  ),
    .cntrl_flags_i     ( cntrl_flags      ),
    .z_fifo_empty_o    ( z_fifo_empty     ),
    .z_fifo_full_o     ( z_fifo_full      ),
    .x_done_o          ( x_done           ),
    .cntrl_streamer_o  ( cntrl_streamer_o )
  );

  redmule_config_fifo #(
    .FALL_THROUGH ( 0                ),
    .DEPTH        ( 2                ),
    .dtype        ( redmule_config_t )
  ) i_config_fifo (
    .clk_i      ( clk_acc                                    ),
    .rst_ni     ( rst_ni                                     ),
    .flush_i    ( target_clear_i                             ),
    .testmode_i ( '0                                         ),
    .full_o     ( config_fifo_full                           ),
    .empty_o    ( config_fifo_empty                          ),
    .usage_o    (                                            ),
    .data_i     ( cfg_i                                      ),
    .push_i     ( cfg_valid_i & ~config_fifo_full            ),
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
    .clk_i             ( clk_acc                ),
    .rst_ni            ( rst_ni                 ),
    .test_mode_i       ( test_mode_i            ),
    .flgs_streamer_i   ( flgs_streamer_i        ),
    .busy_o            ( busy_o                 ),
    .tiler_busy_o      ( tiler_busy             ),
    .target_clear_i    ( target_clear_i         ),
    .clear_o           ( clear                  ),
    .evt_o             ( evt_o                  ),
    .config_i          ( dec_config_q           ),
    .config_o          ( redmule_config         ),
    .reg_enable_i      ( reg_enable             ),
    .fifo_empty_i      ( z_fifo_empty           ),
    .fifo_ready_i      ( ~z_fifo_full           ),
    .start_cfg_i       ( ~config_fifo_empty     ),
    .cfg_complete_o    ( cfg_complete           ),
    .w_loaded_i        ( flgs_scheduler.w_loaded),
    .flush_o           ( engine_flush           ),
    .cntrl_scheduler_o ( cntrl_scheduler        ),
    .cntrl_flags_o     ( cntrl_flags            )
  );

  redmule_scheduler #(
    .DataW       ( DataW       ),
    .FpWidth     ( FpWidth     ),
    .Height      ( Height      ),
    .Width       ( Width       ),
    .NumPipeRegs ( NumPipeRegs )
  ) i_scheduler (
    .clk_i             ( clk_acc               ),
    .rst_ni            ( rst_ni                ),
    .test_mode_i       ( test_mode_i           ),
    .clear_i           ( target_clear_i        ),
    .x_valid_i         ( x_fifo_valid          ),
    .w_valid_i         ( w_fifo_valid          ),
    .y_valid_i         ( y_fifo_valid          ),
    .z_ready_i         ( z_buf_ready           ),
    .engine_flush_i    ( engine_flush          ),
    .config_i          ( redmule_config        ),
    .config_valid_i    ( cfg_complete          ),
    .flgs_streamer_i   ( flgs_streamer_i       ),
    .flgs_x_buffer_i   ( x_buffer_flgs         ),
    .flgs_w_buffer_i   ( w_buffer_flgs         ),
    .flgs_z_buffer_i   ( z_buffer_flgs         ),
    .flgs_engine_i     ( flgs_engine           ),
    .cntrl_scheduler_i ( cntrl_scheduler       ),
    .reg_enable_o      ( reg_enable            ),
    .cntrl_engine_o    ( cntrl_engine          ),
    .cntrl_x_buffer_o  ( x_buffer_ctrl         ),
    .cntrl_w_buffer_o  ( w_buffer_ctrl         ),
    .cntrl_z_buffer_o  ( z_buffer_ctrl         ),
    .flgs_scheduler_o  ( flgs_scheduler        ),
    .sync_i            ( 1'b1                  ),
    .sync_o            ( sync_unused           )
  );

  wire unused_ok = |{x_fifo_strb, w_fifo_strb, y_fifo_strb, w_fifo_flgs, tiler_busy, x_done, sync_unused};

endmodule : redmule_subsys
