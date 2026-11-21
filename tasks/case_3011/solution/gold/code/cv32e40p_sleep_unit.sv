// Copyright 2020 Silicon Labs, Inc.
// Solderpad Hardware License, Version 2.0

module cv32e40p_sleep_unit #(
    parameter COREV_CLUSTER = 0
) (
    input  logic clk_ungated_i,
    input  logic rst_n,
    output logic clk_gated_o,
    input  logic scan_cg_en_i,

    input  logic cluster_mode_i,
    output logic core_sleep_o,

    input  logic fetch_enable_i,
    output logic fetch_enable_o,

    input  logic if_busy_i,
    input  logic ctrl_busy_i,
    input  logic lsu_busy_i,
    input  logic apu_busy_i,

    input  logic pulp_clock_en_i,
    input  logic p_elw_start_i,
    input  logic p_elw_finish_i,
    input  logic debug_p_elw_no_sleep_i,

    input  logic wake_from_sleep_i
);

  import cv32e40p_pkg::*;

  logic fetch_enable_q, fetch_enable_d;
  logic core_busy_q, core_busy_d;
  logic p_elw_busy_q, p_elw_busy_d;
  logic clock_en;

  assign fetch_enable_d = fetch_enable_i ? 1'b1 : fetch_enable_q;

  always_comb begin
    if (!cluster_mode_i || debug_p_elw_no_sleep_i) begin
      p_elw_busy_d = 1'b0;
    end else if (p_elw_finish_i) begin
      p_elw_busy_d = 1'b0;
    end else if (p_elw_start_i) begin
      p_elw_busy_d = 1'b1;
    end else begin
      p_elw_busy_d = p_elw_busy_q;
    end

    if (cluster_mode_i) begin
      core_busy_d  = p_elw_busy_d ? (if_busy_i || lsu_busy_i || apu_busy_i) : 1'b1;
      clock_en     = fetch_enable_q && (pulp_clock_en_i || wake_from_sleep_i || debug_p_elw_no_sleep_i || core_busy_q);
      core_sleep_o = fetch_enable_q && p_elw_busy_d && !core_busy_q && !debug_p_elw_no_sleep_i && !wake_from_sleep_i;
    end else begin
      core_busy_d  = if_busy_i || ctrl_busy_i || lsu_busy_i || apu_busy_i;
      clock_en     = fetch_enable_q && (wake_from_sleep_i || debug_p_elw_no_sleep_i || core_busy_q);
      core_sleep_o = fetch_enable_q && !clock_en;
    end
  end

  always_ff @(posedge clk_ungated_i, negedge rst_n) begin
    if (rst_n == 1'b0) begin
      core_busy_q    <= 1'b0;
      p_elw_busy_q   <= 1'b0;
      fetch_enable_q <= 1'b0;
    end else begin
      core_busy_q    <= core_busy_d;
      p_elw_busy_q   <= p_elw_busy_d;
      fetch_enable_q <= fetch_enable_d;
    end
  end

  assign fetch_enable_o = fetch_enable_q;

  cv32e40p_clock_gate core_clock_gate_i (
      .clk_i       (clk_ungated_i),
      .en_i        (clock_en),
      .scan_cg_en_i(scan_cg_en_i),
      .clk_o       (clk_gated_o)
  );

endmodule
