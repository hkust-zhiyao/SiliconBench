// Copyright 2020 Silicon Labs, Inc.
// Solderpad License, Version 2.0

module cv32e41p_sleep_unit #(
    parameter PULP_CLUSTER = 0
) (
    input  logic clk_ungated_i,
    input  logic rst_n,
    output logic clk_gated_o,
    input  logic scan_cg_en_i,

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

  logic fetch_en_q, core_busy_q, elw_busy_q;
  logic fetch_en_d, core_busy_d, elw_busy_d;
  logic cg_en;

  assign fetch_en_d = fetch_en_q | fetch_enable_i;

  generate
    if (PULP_CLUSTER) begin : g_pulp_sleep
      assign elw_busy_d   = p_elw_start_i | (elw_busy_q & ~p_elw_finish_i);
      assign core_busy_d  = ~elw_busy_d | if_busy_i | apu_busy_i;
      assign cg_en        = fetch_en_q & (pulp_clock_en_i | core_busy_q);
      assign core_sleep_o = elw_busy_d & ~core_busy_q & ~debug_p_elw_no_sleep_i;
    end else begin : g_no_pulp_sleep
      assign elw_busy_d   = 1'b0;
      assign core_busy_d  = if_busy_i | ctrl_busy_i | lsu_busy_i | apu_busy_i;
      assign cg_en        = fetch_en_q & (wake_from_sleep_i | core_busy_q);
      assign core_sleep_o = fetch_en_q & ~cg_en;
    end
  endgenerate

  always_ff @(posedge clk_ungated_i or negedge rst_n) begin
    if (~rst_n) begin
      fetch_en_q  <= 1'b0;
      core_busy_q <= 1'b0;
      elw_busy_q  <= 1'b0;
    end else begin
      fetch_en_q  <= fetch_en_d;
      core_busy_q <= core_busy_d;
      elw_busy_q  <= elw_busy_d;
    end
  end

  assign fetch_enable_o = fetch_en_q;
  assign clk_gated_o    = clk_ungated_i & (cg_en | scan_cg_en_i);

endmodule
