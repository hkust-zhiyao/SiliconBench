// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module mbx_imbx #(
  parameter int unsigned CfgSramAddrWidth = 32,
  parameter int unsigned CfgSramDataWidth = 32
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  output logic                        imbx_state_error_o,
  output logic                        imbx_pending_o,
  output logic                        imbx_irq_ready_o,
  output logic                        imbx_irq_abort_o,
  output logic                        imbx_status_busy_update_o,
  output logic                        imbx_status_busy_o,
  output logic                        imbx_overflow_error_set_o,
  input  logic                        hostif_control_abort_clear_i,
  input  logic                        mbx_error_set_i,
  input  logic                        hostif_range_valid_write_i,
  input  logic                        hostif_range_valid_i,
  input  logic [CfgSramAddrWidth-1:0] hostif_base_i,
  input  logic [CfgSramAddrWidth-1:0] hostif_limit_i,
  input  logic                        sys_read_all_i,
  input  logic                        sysif_status_busy_i,
  input  logic                        sysif_control_go_set_i,
  input  logic                        sysif_control_abort_set_i,
  input  logic                        sysif_data_write_valid_i,
  output logic                        hostif_sram_write_req_o,
  input  logic                        hostif_sram_write_gnt_i,
  input  logic                        hostif_sram_all_vld_rcvd_i,
  output logic [CfgSramAddrWidth-1:0] hostif_sram_write_ptr_o
);
  localparam int unsigned LCFG_SRM_ADDRINC = CfgSramDataWidth / 8;

  logic [CfgSramAddrWidth-1:0] sram_write_ptr_q;
  logic mbx_empty, mbx_write, mbx_read, mbx_sys_abort;
  logic req_q, pending_q;

  logic write_req;
  assign write_req = (mbx_empty & sysif_data_write_valid_i) |
                     (mbx_write & sysif_data_write_valid_i & (sram_write_ptr_q <= hostif_limit_i));

  assign imbx_overflow_error_set_o = mbx_write & sysif_data_write_valid_i &
                                     (sram_write_ptr_q > hostif_limit_i);

  assign hostif_sram_write_req_o = write_req | req_q;

  logic host_clear_abort, advance_write_ptr, load_write_ptr;
  assign host_clear_abort  = hostif_control_abort_clear_i & mbx_sys_abort;
  assign advance_write_ptr = hostif_sram_write_req_o & hostif_sram_write_gnt_i;
  assign load_write_ptr    = (mbx_empty & ~advance_write_ptr) | host_clear_abort |
                             (mbx_read & sys_read_all_i);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_q            <= 1'b0;
      pending_q        <= 1'b0;
      sram_write_ptr_q <= '0;
    end else begin
      req_q     <= hostif_sram_write_req_o & ~hostif_sram_write_gnt_i & ~hostif_control_abort_clear_i;
      pending_q <= ~(hostif_sram_write_gnt_i | hostif_control_abort_clear_i) & (write_req | pending_q);
      if (load_write_ptr) begin
        sram_write_ptr_q <= hostif_base_i;
      end else if (advance_write_ptr) begin
        sram_write_ptr_q <= sram_write_ptr_q + LCFG_SRM_ADDRINC;
      end
    end
  end

  assign imbx_pending_o          = pending_q;
  assign hostif_sram_write_ptr_o = sram_write_ptr_q;

  logic imbx_set_busy, imbx_clear_busy;
  assign imbx_set_busy  =
   (mbx_write & sysif_control_go_set_i & ~mbx_error_set_i & ~sysif_control_abort_set_i) |
   sysif_control_abort_set_i | ~hostif_range_valid_i;

  assign imbx_clear_busy = (hostif_range_valid_write_i & hostif_range_valid_i) |
                           sys_read_all_i                                      |
                           hostif_control_abort_clear_i;

  assign imbx_status_busy_update_o = imbx_set_busy | imbx_clear_busy;
  assign imbx_status_busy_o        = imbx_set_busy;

  mbx_fsm #(
    .CfgOmbx ( 0 )
  ) u_mbxfsm(
    .clk_i                     ( clk_i                        ),
    .rst_ni                    ( rst_ni                       ),
    .mbx_range_valid_i         ( hostif_range_valid_i         ),
    .hostif_abort_ack_i        ( hostif_control_abort_clear_i ),
    .mbx_error_set_i           ( mbx_error_set_i              ),
    .sysif_control_abort_set_i ( sysif_control_abort_set_i    ),
    .sys_read_all_i            ( sys_read_all_i               ),
    .writer_close_mbx_i        ( sysif_control_go_set_i       ),
    .writer_last_word_written_i( hostif_sram_all_vld_rcvd_i   ),
    .writer_write_valid_i      ( sysif_data_write_valid_i     ),
    .mbx_empty_o               ( mbx_empty                    ),
    .mbx_write_o               ( mbx_write                    ),
    .mbx_read_o                ( mbx_read                     ),
    .mbx_sys_abort_o           ( mbx_sys_abort                ),
    .mbx_ready_update_o        (                              ),
    .mbx_ready_o               (                              ),
    .mbx_irq_ready_o           ( imbx_irq_ready_o             ),
    .mbx_irq_abort_o           ( imbx_irq_abort_o             ),
    .mbx_state_error_o         ( imbx_state_error_o           )
  );

endmodule
