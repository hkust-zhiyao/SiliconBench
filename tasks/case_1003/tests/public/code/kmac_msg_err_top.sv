`include "prim_assert.sv"

module kmac_msg_err_top
  import kmac_pkg::*;
#(
  parameter int OutWidth = 32,
  parameter bit EnMasking = 1'b0,
  localparam int Share = (EnMasking) ? 2 : 1,
  parameter int MsgDepth = 2,
  localparam int MsgDepthW = $clog2(MsgDepth+1)
) (
  input clk_i,
  input rst_ni,

  // Configuration
  input sha3_pkg::sha3_mode_e       cfg_mode_i,
  input sha3_pkg::keccak_strength_e cfg_strength_i,
  input logic                       kmac_en_i,
  input logic                       cfg_sideload_i,
  input logic [47:0]                cfg_prefix_6B_i,
  input logic                       cfg_en_unsupported_modestrength_i,
  input logic                       entropy_ready_pulse_i,

  // SW command & status
  input  kmac_cmd_e                 sw_cmd_i,
  output kmac_cmd_e                 sw_cmd_o,
  input  logic                      app_active_i,
  input  prim_mubi_pkg::mubi4_t     sha3_absorbed_i,
  input  prim_mubi_pkg::mubi4_t     sha3_stopped_i,
  input  logic                      sha3_stop_error_i,
  input  logic                      keccak_done_i,
  input  lc_ctrl_pkg::lc_tx_t       lc_escalate_en_i,
  input  logic                      err_processed_i,
  input  prim_mubi_pkg::mubi4_t     clear_after_error_i,

  // Incoming message FIFO write interface
  input  logic                      fifo_valid_i,
  input  logic [OutWidth-1:0]       fifo_data_i [Share],
  input  logic [OutWidth-1:0]       fifo_strb_i,
  output logic                      fifo_ready_o,
  input  logic                      fifo_bypass_i,

  // Packed message output interface
  output logic                      msg_valid_o,
  output logic [OutWidth-1:0]       msg_data_o [Share],
  output logic [OutWidth/8-1:0]     msg_strb_o,
  input  logic                      msg_ready_i,

  output logic                      fifo_empty_o,
  output logic                      fifo_full_o,
  output logic [MsgDepthW-1:0]      fifo_depth_o,
  output logic                      flush_done_o,

  output kmac_pkg::err_t            errchk_error_o,
  output kmac_pkg::err_t            msgfifo_error_o,
  output logic                      sparse_fsm_error_o
);

  logic                  cmd_process;
  logic                  cmd_stop;
  logic                  cmd_done;
  logic                  flush_req;
  prim_mubi_pkg::mubi4_t clear_fifo;

  assign cmd_process = (sw_cmd_o == CmdProcess);
  assign cmd_stop    = (sw_cmd_o == CmdStop);
  assign cmd_done    = (sw_cmd_o == CmdDone);

  assign flush_req  = cmd_process | cmd_stop;
  assign clear_fifo = (cmd_done || prim_mubi_pkg::mubi4_test_true_strict(clear_after_error_i))
                    ? prim_mubi_pkg::MuBi4True : prim_mubi_pkg::MuBi4False;

  kmac_errchk #(
    .EnMasking(EnMasking)
  ) u_errchk (
    .clk_i                            (clk_i),
    .rst_ni                           (rst_ni),
    .cfg_mode_i                       (cfg_mode_i),
    .cfg_strength_i                   (cfg_strength_i),
    .kmac_en_i                        (kmac_en_i),
    .cfg_sideload_i                   (cfg_sideload_i),
    .cfg_prefix_6B_i                  (cfg_prefix_6B_i),
    .cfg_en_unsupported_modestrength_i(cfg_en_unsupported_modestrength_i),
    .entropy_ready_pulse_i            (entropy_ready_pulse_i),
    .sw_cmd_i                         (sw_cmd_i),
    .sw_cmd_o                         (sw_cmd_o),
    .app_active_i                     (app_active_i),
    .sha3_absorbed_i                  (sha3_absorbed_i),
    .sha3_stopped_i                   (sha3_stopped_i),
    .sha3_stop_error_i                (sha3_stop_error_i),
    .keccak_done_i                    (keccak_done_i),
    .lc_escalate_en_i                 (lc_escalate_en_i),
    .err_processed_i                  (err_processed_i),
    .clear_after_error_i              (clear_after_error_i),
    .error_o                          (errchk_error_o),
    .sparse_fsm_error_o               (sparse_fsm_error_o)
  );

  kmac_msgfifo #(
    .OutWidth (OutWidth),
    .EnMasking(EnMasking),
    .MsgDepth (MsgDepth)
  ) u_msgfifo (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .fifo_valid_i(fifo_valid_i),
    .fifo_data_i (fifo_data_i),
    .fifo_strb_i (fifo_strb_i),
    .fifo_ready_o(fifo_ready_o),
    .fifo_bypass_i(fifo_bypass_i),
    .msg_valid_o (msg_valid_o),
    .msg_data_o  (msg_data_o),
    .msg_strb_o  (msg_strb_o),
    .msg_ready_i (msg_ready_i),
    .fifo_empty_o(fifo_empty_o),
    .fifo_full_o (fifo_full_o),
    .fifo_depth_o(fifo_depth_o),
    .clear_i     (clear_fifo),
    .flush_i     (flush_req),
    .flush_done_o(flush_done_o),
    .err_o       (msgfifo_error_o)
  );

endmodule
