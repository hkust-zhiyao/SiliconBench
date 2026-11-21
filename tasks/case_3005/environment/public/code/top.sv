// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module top (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,

    // Hardware Loop Register File Interface
    input  logic [31:0] hwlp_start_data,
    input  logic [31:0] hwlp_end_data,
    input  logic [31:0] hwlp_cnt_data,
    input  logic [ 2:0] hwlp_we,
    input  logic        hwlp_regid,
    input  logic        hwlp_valid,
    input  logic [ 1:0] hwlp_dec_cnt,
    output logic [31:0] hwlp_start_addr0,
    output logic [31:0] hwlp_start_addr1,
    output logic [31:0] hwlp_end_addr0,
    output logic [31:0] hwlp_end_addr1,
    output logic [31:0] hwlp_counter0,
    output logic [31:0] hwlp_counter1,

    // APU Dispatcher Interface
    input  logic        apu_enable,
    input  logic [ 1:0] apu_lat,
    input  logic [ 5:0] apu_waddr_in,
    output logic [ 5:0] apu_waddr_out,
    output logic        apu_multicycle,
    output logic        apu_singlecycle,
    output logic        apu_rvalid_wb,
    output logic        apu_active,
    output logic        apu_stall,
    input  logic        is_decoding,
    input  logic [ 5:0] read_reg0,
    input  logic [ 5:0] read_reg1,
    input  logic [ 5:0] read_reg2,
    input  logic [ 2:0] read_regs_valid,
    output logic        read_dep,
    output logic        read_dep_for_jalr,
    input  logic [ 5:0] write_reg0,
    input  logic [ 5:0] write_reg1,
    input  logic [ 1:0] write_regs_valid,
    output logic        write_dep,
    output logic        perf_type,
    output logic        perf_cont,
    output logic        apu_req,
    input  logic        apu_gnt,
    input  logic        apu_rvalid,

    // Transparent combinational feedthrough channels
    input  logic [ 7:0] fpu_rm_in,
    output logic [ 7:0] fpu_rm_out,
    input  logic [ 7:0] hart_ctrl_in,
    output logic [ 7:0] hart_ctrl_out
);

  logic [1:0][31:0] s_hwlp_start;
  logic [1:0][31:0] s_hwlp_end;
  logic [1:0][31:0] s_hwlp_cnt;

  assign hwlp_start_addr0 = s_hwlp_start[0];
  assign hwlp_start_addr1 = s_hwlp_start[1];
  assign hwlp_end_addr0   = s_hwlp_end[0];
  assign hwlp_end_addr1   = s_hwlp_end[1];
  assign hwlp_counter0    = s_hwlp_cnt[0];
  assign hwlp_counter1    = s_hwlp_cnt[1];

  cv32e40p_hwloop_regs #(
      .N_REGS(2)
  ) i_hwloop_regs (
      .clk              (clk_i),
      .rst_n            (rst_ni),
      .hwlp_start_data_i(hwlp_start_data),
      .hwlp_end_data_i  (hwlp_end_data),
      .hwlp_cnt_data_i  (hwlp_cnt_data),
      .hwlp_we_i        (hwlp_we),
      .hwlp_regid_i     (hwlp_regid),
      .valid_i          (hwlp_valid),
      .hwlp_dec_cnt_i   (hwlp_dec_cnt),
      .hwlp_start_addr_o(s_hwlp_start),
      .hwlp_end_addr_o  (s_hwlp_end),
      .hwlp_counter_o   (s_hwlp_cnt)
  );

  cv32e40p_apu_disp i_apu_disp (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .enable_i           (apu_enable),
      .apu_lat_i          (apu_lat),
      .apu_waddr_i        (apu_waddr_in),
      .apu_waddr_o        (apu_waddr_out),
      .apu_multicycle_o   (apu_multicycle),
      .apu_singlecycle_o  (apu_singlecycle),
      .apu_rvalid_wb_o    (apu_rvalid_wb),
      .active_o           (apu_active),
      .stall_o            (apu_stall),
      .is_decoding_i      (is_decoding),
      .read_regs_i        ({read_reg2, read_reg1, read_reg0}),
      .read_regs_valid_i  (read_regs_valid),
      .read_dep_o         (read_dep),
      .read_dep_for_jalr_o(read_dep_for_jalr),
      .write_regs_i       ({write_reg1, write_reg0}),
      .write_regs_valid_i (write_regs_valid),
      .write_dep_o        (write_dep),
      .perf_type_o        (perf_type),
      .perf_cont_o        (perf_cont),
      .apu_req_o          (apu_req),
      .apu_gnt_i          (apu_gnt),
      .apu_rvalid_i       (apu_rvalid)
  );

  assign fpu_rm_out    = fpu_rm_in;
  assign hart_ctrl_out = hart_ctrl_in;

endmodule
