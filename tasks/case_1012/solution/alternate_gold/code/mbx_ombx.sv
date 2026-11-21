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

  logic [CfgSramAddrWidth-1:0] sram_read_ptr_q;
  logic [CfgSramDataWidth-1:0] read_data_q;
  logic                        mbx_empty, mbx_read, mbx_sys_abort;
  logic                        req_q, pending_q, first_req_q;
  logic                        host_write_object_size_q, ombx_object_size_update_valid_q;
  logic                        has_rem_words, ptr_in_range, rem_words_q;
  logic                        range_valid_set, host_clear_abort, set_first_req, load_read_ptr, advance_read_ptr;
  logic                        set_pending, read_req, clear_read_data;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rem_words_q <= 1'b0;
    end else if (hostif_control_abort_clear_i) begin
      rem_words_q <= 1'b0;
    end else if (advance_read_ptr) begin
      rem_words_q <= (hostif_ombx_object_size_i > CfgObjectSizeWidth'(1));
    end else if (host_write_object_size_q & ~mbx_read) begin
      rem_words_q <= (hostif_ombx_object_size_i != '0);
    end
  end
  assign has_rem_words = rem_words_q;
  assign ptr_in_range  = (sram_read_ptr_q <= hostif_limit_i);

  assign set_pending          = mbx_read & sysif_read_data_write_valid_i & ptr_in_range & has_rem_words;
  assign read_req             = first_req_q | set_pending;
  assign ombx_sram_read_req_o = read_req | req_q;

  assign sys_read_all_o = mbx_read & sysif_read_data_write_valid_i & ~has_rem_words;

  assign range_valid_set  = hostif_range_valid_write_i & hostif_range_valid_i;
  assign host_clear_abort = hostif_control_abort_clear_i & mbx_sys_abort;
  assign set_first_req    = mbx_empty & host_write_object_size_q & (hostif_ombx_object_size_i != '0);
  assign load_read_ptr    = range_valid_set | set_first_req | sys_read_all_o | host_clear_abort;
  assign advance_read_ptr = ombx_sram_read_req_o & ombx_sram_read_gnt_i;

  assign clear_read_data = sys_read_all_o | mbx_error_set_i | sysif_control_abort_set_i |
                           mbx_sys_abort  | hostif_control_abort_clear_i;

  assign hostif_ombx_object_size_update_o = advance_read_ptr | hostif_control_abort_clear_i;
  assign hostif_ombx_object_size_o        = hostif_control_abort_clear_i ? '0 :
                                            (hostif_ombx_object_size_i - CfgObjectSizeWidth'(1));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_q                           <= 1'b0;
      pending_q                       <= 1'b0;
      first_req_q                     <= 1'b0;
      host_write_object_size_q        <= 1'b0;
      ombx_object_size_update_valid_q <= 1'b0;
      sram_read_ptr_q                 <= '0;
      read_data_q                     <= '0;
    end else begin
      req_q                           <= ombx_sram_read_req_o & ~ombx_sram_read_gnt_i & ~hostif_control_abort_clear_i;
      pending_q                       <= ~(ombx_sram_read_resp_valid_i | hostif_control_abort_clear_i) & (set_pending | pending_q);
      first_req_q                     <= set_first_req | (first_req_q & ~ombx_sram_read_gnt_i);
      host_write_object_size_q        <= hostif_ombx_object_size_write_i & ~ombx_object_size_update_valid_q;
      ombx_object_size_update_valid_q <= hostif_ombx_object_size_update_o;
      if (load_read_ptr) begin
        sram_read_ptr_q <= hostif_base_i;
      end else if (advance_read_ptr) begin
        sram_read_ptr_q <= sram_read_ptr_q + LCFG_SRM_ADDRINC;
      end
      if (clear_read_data) begin
        read_data_q <= '0;
      end else if (ombx_sram_read_resp_valid_i) begin
        read_data_q <= ombx_sram_read_resp_i;
      end
    end
  end

  assign ombx_pending_o       = pending_q;
  assign ombx_sram_read_ptr_o = sram_read_ptr_q;
  assign ombx_read_data_o     = read_data_q;

  assign ombx_doe_intr_ready_set_o = (ombx_status_ready_o & ombx_status_ready_update_o);

  mbx_fsm #(
    .CfgOmbx ( 1 )
  ) u_mbxfsm(
    .clk_i                     ( clk_i                                     ),
    .rst_ni                    ( rst_ni                                    ),
    .mbx_range_valid_i         ( hostif_range_valid_i                      ),
    .hostif_abort_ack_i        ( hostif_control_abort_clear_i              ),
    .mbx_error_set_i           ( mbx_error_set_i                           ),
    .sysif_control_abort_set_i ( sysif_control_abort_set_i                 ),
    .sys_read_all_i            ( sys_read_all_o                            ),
    .writer_close_mbx_i        ( mbx_empty & ombx_sram_read_resp_valid_i   ),
    .writer_last_word_written_i( 1'b0                                      ),
    .writer_write_valid_i      ( 1'b0                                      ),
    .mbx_empty_o               ( mbx_empty                                 ),
    .mbx_write_o               (                                           ),
    .mbx_read_o                ( mbx_read                                  ),
    .mbx_sys_abort_o           ( mbx_sys_abort                             ),
    .mbx_ready_update_o        ( ombx_status_ready_update_o                ),
    .mbx_ready_o               ( ombx_status_ready_o                       ),
    .mbx_irq_ready_o           (                                           ),
    .mbx_irq_abort_o           (                                           ),
    .mbx_state_error_o         ( ombx_state_error_o                        )
  );

  logic unused_signals;
  assign unused_signals = sysif_status_ready_i;

endmodule
