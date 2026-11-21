// Copyright 2020 Silicon Labs, Inc. & ETH Zurich / University of Bologna.
// Solderpad Hardware License, Version 2.0 / 0.51

module top
  import cv32e40p_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        scan_cg_en_i,
    input  logic        cluster_mode_i,

    // Sleep unit interface
    input  logic        fetch_enable_i,
    output logic        fetch_enable_o,
    output logic        clk_gated_o,
    output logic        core_sleep_o,

    input  logic        if_busy_i,
    input  logic        ctrl_busy_i,
    input  logic        lsu_busy_i,
    input  logic        apu_busy_i,

    input  logic        pulp_clock_en_i,
    input  logic        p_elw_start_i,
    input  logic        p_elw_finish_i,
    input  logic        debug_p_elw_no_sleep_i,
    input  logic        wake_from_ctrl_i,

    // Interrupt controller interface
    input  logic [31:0] irq_i,
    input  logic        irq_sec_i,
    input  logic [31:0] mie_bypass_i,
    output logic [31:0] mip_o,
    input  logic        m_ie_i,
    input  logic        u_ie_i,
    input  logic [ 1:0] current_priv_lvl_i,

    output logic        irq_req_ctrl_o,
    output logic        irq_sec_ctrl_o,
    output logic [ 4:0] irq_id_ctrl_o,
    output logic        irq_wu_ctrl_o,

    // Transparent combinational channels
    input  logic [ 7:0] clint_timer_in,
    output logic [ 7:0] clint_timer_out,
    input  logic [ 7:0] eu_event_in,
    output logic [ 7:0] eu_event_out
);

  PrivLvl_t priv_lvl;
  assign priv_lvl = PrivLvl_t'(current_priv_lvl_i);

  cv32e40p_int_controller #(
      .PULP_SECURE(1)
  ) i_int_controller (
      .clk               (clk_i),
      .rst_n             (rst_ni),
      .irq_i             (irq_i),
      .irq_sec_i         (irq_sec_i),
      .irq_req_ctrl_o    (irq_req_ctrl_o),
      .irq_sec_ctrl_o    (irq_sec_ctrl_o),
      .irq_id_ctrl_o     (irq_id_ctrl_o),
      .irq_wu_ctrl_o     (irq_wu_ctrl_o),
      .mie_bypass_i      (mie_bypass_i),
      .mip_o             (mip_o),
      .m_ie_i            (m_ie_i),
      .u_ie_i            (u_ie_i),
      .current_priv_lvl_i(priv_lvl)
  );

  cv32e40p_sleep_unit #(
      .COREV_CLUSTER(1)
  ) i_sleep_unit (
      .clk_ungated_i         (clk_i),
      .rst_n                 (rst_ni),
      .clk_gated_o           (clk_gated_o),
      .scan_cg_en_i          (scan_cg_en_i),
      .cluster_mode_i        (cluster_mode_i),
      .core_sleep_o          (core_sleep_o),
      .fetch_enable_i        (fetch_enable_i),
      .fetch_enable_o        (fetch_enable_o),
      .if_busy_i             (if_busy_i),
      .ctrl_busy_i           (ctrl_busy_i),
      .lsu_busy_i            (lsu_busy_i),
      .apu_busy_i            (apu_busy_i),
      .pulp_clock_en_i       (pulp_clock_en_i),
      .p_elw_start_i         (p_elw_start_i),
      .p_elw_finish_i        (p_elw_finish_i),
      .debug_p_elw_no_sleep_i(debug_p_elw_no_sleep_i),
      .wake_from_sleep_i     (wake_from_ctrl_i || irq_wu_ctrl_o)
  );

  assign clint_timer_out = clint_timer_in;
  assign eu_event_out    = eu_event_in;

endmodule
