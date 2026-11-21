// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module mbx_ombx #(
  parameter int unsigned CfgSramAddrWidth   = 32,
  parameter int unsigned CfgSramDataWidth   = 32,
  parameter int unsigned CfgObjectSizeWidth = 11
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  output logic                          ombx_state_error_o,
  output logic                          ombx_doe_intr_ready_set_o,
  output logic                          ombx_pending_o,
  output logic                          ombx_status_ready_update_o,
  output logic                          ombx_status_ready_o,
  input  logic                          hostif_range_valid_write_i,
  input  logic                          hostif_range_valid_i,
  input  logic [CfgSramAddrWidth-1:0]   hostif_base_i,
  input  logic [CfgSramAddrWidth-1:0]   hostif_limit_i,
  output logic                          sys_read_all_o,
  input  logic                          sysif_status_ready_i,
  input  logic                          hostif_control_abort_clear_i,
  input  logic                          mbx_error_set_i,
  input  logic                          sysif_control_abort_set_i,
  input  logic                          sysif_read_data_read_valid_i,
  input  logic                          sysif_read_data_write_valid_i,
  input logic                           hostif_ombx_object_size_write_i,
  input logic [CfgObjectSizeWidth-1:0]  hostif_ombx_object_size_i,
  output logic                          hostif_ombx_object_size_update_o,
  output logic [CfgObjectSizeWidth-1:0] hostif_ombx_object_size_o,
  output  logic [CfgSramDataWidth-1:0]  ombx_read_data_o,
  output logic                          ombx_sram_read_req_o,
  input  logic                          ombx_sram_read_gnt_i,
  output logic [CfgSramAddrWidth-1:0]   ombx_sram_read_ptr_o,
  input  logic                          ombx_sram_read_resp_valid_i,
  input  logic [CfgSramDataWidth-1:0]   ombx_sram_read_resp_i
);
  localparam int unsigned LCFG_SRM_ADDRINC = CfgSramDataWidth / 8;

  logic [CfgSramAddrWidth-1:0] sram_read_ptr_d, sram_read_ptr_q;
  logic [CfgSramAddrWidth-1:0] sram_read_ptr_limit_d, sram_read_ptr_limit_q;

  logic mbx_empty, mbx_read, mbx_sys_abort;
  logic set_first_req, clear_first_req;

  logic read_req, first_req_q;
  assign read_req = first_req_q |
                    (mbx_read & sysif_read_data_write_valid_i   &
                    (sram_read_ptr_q <= hostif_limit_i)         &
                    (sram_read_ptr_q < sram_read_ptr_limit_q));

  logic awaiting_gnt;
  assign awaiting_gnt = ombx_sram_read_req_o & ~ombx_sram_read_gnt_i &
                       ~hostif_control_abort_clear_i;

  logic req_q;
  assign ombx_sram_read_req_o = read_req | req_q;

  prim_flop #(
    .Width(1)
  ) u_req_state (
    .clk_i ( clk_i        ),
    .rst_ni( rst_ni       ),
    .d_i   ( awaiting_gnt ),
    .q_o   ( req_q        )
  );

  logic set_pending, clear_pending;

  assign set_pending   = mbx_read & sysif_read_data_write_valid_i &
                        (sram_read_ptr_q <= hostif_limit_i)       &
                        (sram_read_ptr_q < sram_read_ptr_limit_q);
  assign clear_pending = ombx_sram_read_resp_valid_i | hostif_control_abort_clear_i;

  prim_flop #(
    .Width(1)
  ) u_pending (
    .clk_i ( clk_i                                           ),
    .rst_ni( rst_ni                                          ),
    .d_i   ( ~clear_pending & (set_pending | ombx_pending_o) ),
    .q_o   ( ombx_pending_o                                  )
  );

  logic writer_close_mbx;
  assign writer_close_mbx = mbx_empty & ombx_sram_read_resp_valid_i;

  assign sys_read_all_o = mbx_read                       &
                          sysif_read_data_write_valid_i  &
                          (sram_read_ptr_q == sram_read_ptr_limit_q);

  logic host_clear_abort;
  assign host_clear_abort = hostif_control_abort_clear_i & mbx_sys_abort;

  logic load_read_ptr, advance_read_ptr;

  logic range_valid_set;
  assign range_valid_set = hostif_range_valid_write_i & hostif_range_valid_i;

  assign load_read_ptr = range_valid_set | set_first_req | sys_read_all_o | host_clear_abort;

  assign advance_read_ptr = ombx_sram_read_req_o & ombx_sram_read_gnt_i;

  always_comb begin
    sram_read_ptr_d = sram_read_ptr_q;

    if (load_read_ptr) begin
      sram_read_ptr_d = hostif_base_i;
    end else if (advance_read_ptr) begin
      sram_read_ptr_d = sram_read_ptr_q + LCFG_SRM_ADDRINC;
    end
  end

  prim_flop_en #(
    .Width(CfgSramAddrWidth)
  ) u_sram_read_ptr (
    .clk_i ( clk_i                            ),
    .rst_ni( rst_ni                           ),
    .en_i  ( load_read_ptr | advance_read_ptr ),
    .d_i   ( sram_read_ptr_d                  ),
    .q_o   ( sram_read_ptr_q                  )
  );
  assign ombx_sram_read_ptr_o = sram_read_ptr_q;

  logic aborting;
  assign aborting = sysif_control_abort_set_i | mbx_sys_abort;

  logic clear_read_data;
  assign clear_read_data = sys_read_all_o             |
                           mbx_error_set_i            |
                           aborting                   |
                           hostif_control_abort_clear_i;

  prim_flop_en #(
    .Width(CfgSramDataWidth)
  ) u_sram_read_data (
    .clk_i ( clk_i                                                        ),
    .rst_ni( rst_ni                                                       ),
    .en_i  ( ombx_sram_read_resp_valid_i | clear_read_data                ),
    .d_i   ( {CfgSramDataWidth{~clear_read_data}} & ombx_sram_read_resp_i ),
    .q_o   ( ombx_read_data_o                                             )
  );

  logic host_write_object_size_q;
  logic ombx_object_size_update_valid_q;

  prim_flop #(
    .Width(1)
  ) u_host_write_object_size (
    .clk_i ( clk_i                                                              ),
    .rst_ni( rst_ni                                                             ),
    .d_i   ( hostif_ombx_object_size_write_i & ~ombx_object_size_update_valid_q ),
    .q_o   ( host_write_object_size_q                                           )
  );

  logic [CfgObjectSizeWidth-1:0] hostif_ob_object_size_minus_one;
  assign hostif_ombx_object_size_update_o = (ombx_sram_read_req_o & ombx_sram_read_gnt_i) |
                                             hostif_control_abort_clear_i;
  assign hostif_ob_object_size_minus_one = hostif_ombx_object_size_i - 1;
  assign hostif_ombx_object_size_o       = hostif_ob_object_size_minus_one;

  prim_flop #(
    .Width(1)
  ) u_host_object_size_update_valid (
    .clk_i ( clk_i                            ),
    .rst_ni( rst_ni                           ),
    .d_i   ( hostif_ombx_object_size_update_o ),
    .q_o   ( ombx_object_size_update_valid_q  )
  );

  assign sram_read_ptr_limit_d = hostif_base_i +
                                 CfgSramAddrWidth'({hostif_ombx_object_size_i, 2'b0});

  prim_flop_en #(
    .Width(CfgSramAddrWidth)
  ) u_sram_read_ptr_limit (
    .clk_i ( clk_i                                                    ),
    .rst_ni( rst_ni                                                   ),
    .en_i  ( (host_write_object_size_q & ~mbx_read) | range_valid_set ),
    .d_i   ( sram_read_ptr_limit_d                                    ),
    .q_o   ( sram_read_ptr_limit_q                                    )
  );

  assign set_first_req   = mbx_empty & host_write_object_size_q & (|hostif_ombx_object_size_i);
  assign clear_first_req = ombx_sram_read_gnt_i;

  prim_flop #(
    .Width(1)
  ) u_pop_entry (
    .clk_i ( clk_i                                            ),
    .rst_ni( rst_ni                                           ),
    .d_i   ( set_first_req | (first_req_q & ~clear_first_req) ),
    .q_o   ( first_req_q                                      )
  );

  assign ombx_doe_intr_ready_set_o = (ombx_status_ready_o & ombx_status_ready_update_o);

  mbx_fsm #(
    .CfgOmbx ( 1 )
  ) u_mbxfsm(
    .clk_i                     ( clk_i                        ),
    .rst_ni                    ( rst_ni                       ),
    .mbx_range_valid_i         ( hostif_range_valid_i         ),
    .hostif_abort_ack_i        ( hostif_control_abort_clear_i ),
    .mbx_error_set_i           ( mbx_error_set_i              ),
    .sysif_control_abort_set_i ( sysif_control_abort_set_i    ),
    .sys_read_all_i            ( sys_read_all_o               ),
    .writer_close_mbx_i        ( writer_close_mbx             ),
    .writer_last_word_written_i( 1'b0                         ),
    .writer_write_valid_i      ( 1'b0                         ),
    .mbx_empty_o               ( mbx_empty                    ),
    .mbx_write_o               (                              ),
    .mbx_read_o                ( mbx_read                     ),
    .mbx_sys_abort_o           ( mbx_sys_abort                ),
    .mbx_ready_update_o        ( ombx_status_ready_update_o   ),
    .mbx_ready_o               ( ombx_status_ready_o          ),
    .mbx_irq_ready_o           (                              ),
    .mbx_irq_abort_o           (                              ),
    .mbx_state_error_o         ( ombx_state_error_o           )
  );

  logic unused_signals;
  assign unused_signals = sysif_status_ready_i;

endmodule
