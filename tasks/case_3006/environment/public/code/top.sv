// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module top (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,

    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    input  logic        data_err_i,
    input  logic        data_err_pmp_i,

    output logic [31:0] data_addr_o,
    output logic        data_we_o,
    output logic [ 3:0] data_be_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,

    input  logic        data_we_ex_i,
    input  logic [ 1:0] data_type_ex_i,
    input  logic [31:0] data_wdata_ex_i,
    input  logic [ 1:0] data_reg_offset_ex_i,
    input  logic        data_load_event_ex_i,
    input  logic [ 1:0] data_sign_ext_ex_i,

    output logic [31:0] data_rdata_ex_o,
    input  logic        data_req_ex_i,
    input  logic [31:0] operand_a_ex_i,
    input  logic [31:0] operand_b_ex_i,
    input  logic        addr_useincr_ex_i,

    input  logic        data_misaligned_ex_i,
    output logic        data_misaligned_o,

    input  logic [ 5:0] data_atop_ex_i,
    output logic [ 5:0] data_atop_o,

    output logic        load_err_o,
    output logic        store_err_o,

    output logic        p_elw_start_o,
    output logic        p_elw_finish_o,

    output logic        lsu_ready_ex_o,
    output logic        lsu_ready_wb_o,
    output logic        busy_o,

    // Transparent combinational channels
    input  logic [ 7:0] mpu_region_in,
    output logic [ 7:0] mpu_region_out,
    input  logic [ 7:0] hart_dbg_in,
    output logic [ 7:0] hart_dbg_out
);

  cv32e40p_load_store_unit #(
      .PULP_OBI(0)
  ) i_lsu (
      .clk                 (clk_i),
      .rst_n               (rst_ni),
      .flush_i             (flush_i),
      .data_req_o          (data_req_o),
      .data_gnt_i          (data_gnt_i),
      .data_rvalid_i       (data_rvalid_i),
      .data_err_i          (data_err_i),
      .data_err_pmp_i      (data_err_pmp_i),
      .data_addr_o         (data_addr_o),
      .data_we_o           (data_we_o),
      .data_be_o           (data_be_o),
      .data_wdata_o        (data_wdata_o),
      .data_rdata_i        (data_rdata_i),
      .data_we_ex_i        (data_we_ex_i),
      .data_type_ex_i      (data_type_ex_i),
      .data_wdata_ex_i     (data_wdata_ex_i),
      .data_reg_offset_ex_i(data_reg_offset_ex_i),
      .data_load_event_ex_i(data_load_event_ex_i),
      .data_sign_ext_ex_i  (data_sign_ext_ex_i),
      .data_rdata_ex_o     (data_rdata_ex_o),
      .data_req_ex_i       (data_req_ex_i),
      .operand_a_ex_i      (operand_a_ex_i),
      .operand_b_ex_i      (operand_b_ex_i),
      .addr_useincr_ex_i   (addr_useincr_ex_i),
      .data_misaligned_ex_i(data_misaligned_ex_i),
      .data_misaligned_o   (data_misaligned_o),
      .data_atop_ex_i      (data_atop_ex_i),
      .data_atop_o         (data_atop_o),
      .load_err_o          (load_err_o),
      .store_err_o         (store_err_o),
      .p_elw_start_o       (p_elw_start_o),
      .p_elw_finish_o      (p_elw_finish_o),
      .lsu_ready_ex_o      (lsu_ready_ex_o),
      .lsu_ready_wb_o      (lsu_ready_wb_o),
      .busy_o              (busy_o)
  );

  assign mpu_region_out = mpu_region_in;
  assign hart_dbg_out   = hart_dbg_in;

endmodule
