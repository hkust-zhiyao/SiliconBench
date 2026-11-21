// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0

`include "VX_define.vh"

module VX_cluster_bar_subsys import VX_gpu_pkg::*; #(
    parameter NUM_CORES   = `VX_CFG_NUM_CORES,
    parameter REQ_OUT_BUF = 0,
    parameter RSP_OUT_BUF = 0
) (
    input  wire                                             clk,
    input  wire                                             reset,

    // Per-core barrier unit ports
    input  wire [NUM_CORES-1:0]                             req_valid,
    input  wire [NUM_CORES-1:0][NW_WIDTH-1:0]               req_wid,
    input  barrier_t [NUM_CORES-1:0]                        req_data,
    input  wire [NUM_CORES-1:0][BAR_ADDR_W-1:0]             read_addr,
    output wire [NUM_CORES-1:0]                             read_phase,

    input  wire [NUM_CORES-1:0][`VX_CFG_NUM_WARPS-1:0]      active_warps,
    output wire [NUM_CORES-1:0]                             unlock_valid,
    output wire [NUM_CORES-1:0][`VX_CFG_NUM_WARPS-1:0]      unlock_mask
);
    VX_gbar_bus_if core_gbar_if [NUM_CORES]();
    VX_gbar_bus_if cluster_gbar_if();

    for (genvar c = 0; c < NUM_CORES; ++c) begin : g_cores
        VX_bar_unit #(
            .INSTANCE_ID ("cluster-bar"),
            .CORE_ID     (c)
        ) u_bar_unit (
            .clk          (clk),
            .reset        (reset),
            .req_valid    (req_valid[c]),
            .req_wid      (req_wid[c]),
            .req_data     (req_data[c]),
            .read_addr    (read_addr[c]),
            .read_phase   (read_phase[c]),
            .gbar_bus_if  (core_gbar_if[c]),
            .active_warps (active_warps[c]),
            .unlock_valid (unlock_valid[c]),
            .unlock_mask  (unlock_mask[c])
        );
    end

    VX_gbar_arb #(
        .NUM_REQS    (NUM_CORES),
        .REQ_OUT_BUF (REQ_OUT_BUF),
        .RSP_OUT_BUF (RSP_OUT_BUF),
        .ARBITER     ("R")
    ) u_gbar_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (core_gbar_if),
        .bus_out_if (cluster_gbar_if)
    );

    VX_gbar_unit #(
        .INSTANCE_ID ("cluster-gbar")
    ) u_gbar_unit (
        .clk         (clk),
        .reset       (reset),
        .gbar_bus_if (cluster_gbar_if)
    );

endmodule
