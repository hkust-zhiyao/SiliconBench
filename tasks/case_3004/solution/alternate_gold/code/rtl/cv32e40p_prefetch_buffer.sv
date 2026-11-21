// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e40p_prefetch_buffer #(
    parameter PULP_OBI = 0,
    parameter COREV_PULP = 1
) (
    input logic clk,
    input logic rst_n,

    input logic        req_i,
    input logic        branch_i,
    input logic [31:0] branch_addr_i,

    input logic        hwlp_jump_i,
    input logic [31:0] hwlp_target_i,

    input  logic        fetch_ready_i,
    output logic        fetch_valid_o,
    output logic [31:0] fetch_rdata_o,
    output logic        fetch_err_o,

    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic        instr_rvalid_i,
    input  logic        instr_err_i,
    input  logic        instr_err_pmp_i,

    output logic busy_o
);

  localparam FIFO_DEPTH = 2;
  localparam int unsigned FIFO_ADDR_DEPTH = $clog2(FIFO_DEPTH);

  logic                     trans_valid;
  logic                     trans_ready;
  logic [             31:0] trans_addr;

  logic                     fifo_flush;
  logic                     fifo_flush_but_first;
  logic [FIFO_ADDR_DEPTH:0] fifo_cnt;

  logic [             32:0] fifo_bundle_out;
  logic                     fifo_push;
  logic                     fifo_pop;
  logic                     fifo_empty;

  logic                     resp_valid;
  logic [             31:0] resp_rdata;
  logic                     resp_err;

  cv32e40p_prefetch_controller #(
      .DEPTH     (FIFO_DEPTH),
      .PULP_OBI  (PULP_OBI),
      .COREV_PULP(COREV_PULP)
  ) prefetch_controller_i (
      .clk  (clk),
      .rst_n(rst_n),

      .req_i        (req_i),
      .branch_i     (branch_i),
      .branch_addr_i(branch_addr_i),
      .busy_o       (busy_o),

      .hwlp_jump_i  (hwlp_jump_i),
      .hwlp_target_i(hwlp_target_i),

      .trans_valid_o(trans_valid),
      .trans_ready_i(trans_ready),
      .trans_addr_o (trans_addr),

      .resp_valid_i(resp_valid),
      .resp_err_i  (resp_err),

      .fetch_ready_i(fetch_ready_i),
      .fetch_valid_o(fetch_valid_o),

      .fifo_push_o           (fifo_push),
      .fifo_pop_o            (fifo_pop),
      .fifo_flush_o          (fifo_flush),
      .fifo_flush_but_first_o(fifo_flush_but_first),
      .fifo_cnt_i            (fifo_cnt),
      .fifo_empty_i          (fifo_empty)
  );

  cv32e40p_fifo #(
      .FALL_THROUGH(1'b0),
      .DATA_WIDTH  (33),
      .DEPTH       (FIFO_DEPTH)
  ) fifo_i (
      .clk_i            (clk),
      .rst_ni           (rst_n),
      .flush_i          (fifo_flush),
      .flush_but_first_i(fifo_flush_but_first),
      .testmode_i       (1'b0),
      .full_o           (),
      .empty_o          (fifo_empty),
      .cnt_o            (fifo_cnt),
      .data_i           ({resp_err, resp_rdata}),
      .push_i           (fifo_push),
      .data_o           (fifo_bundle_out),
      .pop_i            (fifo_pop)
  );

  assign {fetch_err_o, fetch_rdata_o} = fifo_empty ? {resp_err, resp_rdata} : fifo_bundle_out;

  cv32e40p_obi_interface #(
      .TRANS_STABLE(0)
  ) instruction_obi_i (
      .clk  (clk),
      .rst_n(rst_n),

      .trans_valid_i(trans_valid),
      .trans_ready_o(trans_ready),
      .trans_addr_i ({trans_addr[31:2], 2'b00}),
      .trans_we_i   (1'b0),
      .trans_be_i   (4'b1111),
      .trans_wdata_i(32'b0),
      .trans_atop_i (6'b0),

      .resp_valid_o(resp_valid),
      .resp_rdata_o(resp_rdata),
      .resp_err_o  (resp_err),

      .obi_req_o   (instr_req_o),
      .obi_gnt_i   (instr_gnt_i),
      .obi_addr_o  (instr_addr_o),
      .obi_we_o    (),
      .obi_be_o    (),
      .obi_wdata_o (),
      .obi_atop_o  (),
      .obi_rdata_i (instr_rdata_i),
      .obi_rvalid_i(instr_rvalid_i),
      .obi_err_i   (instr_err_i)
  );

endmodule
