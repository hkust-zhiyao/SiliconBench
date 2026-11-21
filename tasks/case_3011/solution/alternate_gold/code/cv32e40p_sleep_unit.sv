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

  logic fetch_enable_q, core_busy_q, p_elw_busy_q;
  logic sub_busy_cluster, sub_busy_wfi;
  logic p_elw_next, busy_next, clk_en_w;

  assign sub_busy_cluster = if_busy_i | lsu_busy_i | apu_busy_i;
  assign sub_busy_wfi     = sub_busy_cluster | ctrl_busy_i;
  assign p_elw_next       = cluster_mode_i & ~debug_p_elw_no_sleep_i & ~p_elw_finish_i & (p_elw_start_i | p_elw_busy_q);
  assign busy_next        = cluster_mode_i ? (p_elw_next ? sub_busy_cluster : 1'b1) : sub_busy_wfi;
  assign clk_en_w         = fetch_enable_q & (wake_from_sleep_i | debug_p_elw_no_sleep_i | core_busy_q | (cluster_mode_i & pulp_clock_en_i));

  assign fetch_enable_o   = fetch_enable_q;
  assign core_sleep_o     = cluster_mode_i
                            ? (fetch_enable_q & p_elw_next & ~core_busy_q & ~debug_p_elw_no_sleep_i & ~wake_from_sleep_i)
                            : (fetch_enable_q & ~clk_en_w);

  always_ff @(posedge clk_ungated_i or negedge rst_n) begin
    if (!rst_n) begin
      fetch_enable_q <= 1'b0;
      core_busy_q    <= 1'b0;
      p_elw_busy_q   <= 1'b0;
    end else begin
      fetch_enable_q <= fetch_enable_q | fetch_enable_i;
      core_busy_q    <= busy_next;
      p_elw_busy_q   <= p_elw_next;
    end
  end

  cv32e40p_clock_gate core_clock_gate_i (
      .clk_i       (clk_ungated_i),
      .en_i        (clk_en_w),
      .scan_cg_en_i(scan_cg_en_i),
      .clk_o       (clk_gated_o)
  );

endmodule
