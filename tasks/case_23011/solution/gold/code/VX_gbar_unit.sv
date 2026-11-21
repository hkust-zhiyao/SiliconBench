// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0

`include "VX_define.vh"

module VX_gbar_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input  wire            clk,
    input  wire            reset,
    VX_gbar_bus_if.slave   gbar_bus_if
);
    `UNUSED_SPARAM (INSTANCE_ID)

    localparam CORE_CNT_W = `CLOG2(`VX_CFG_NUM_CORES + 1);

    reg [`VX_CFG_NUM_BARRIERS-1:0][`VX_CFG_NUM_CORES-1:0] barrier_masks;
    wire [NB_WIDTH-1:0] req_id = gbar_bus_if.req_data.id;
    wire [NC_WIDTH-1:0] req_cid = gbar_bus_if.req_data.core_id;
    wire [`VX_CFG_NUM_CORES-1:0] curr_mask = barrier_masks[req_id];
    wire [`VX_CFG_NUM_CORES-1:0] next_mask = curr_mask | ((`VX_CFG_NUM_CORES)'(1) << req_cid);
    wire [CORE_CNT_W-1:0] next_cnt;
    `POP_COUNT(next_cnt, next_mask);

    wire rsp_full, rsp_empty;
    wire [NB_WIDTH-1:0] rsp_id_out;
    wire req_fire = gbar_bus_if.req_valid && gbar_bus_if.req_ready;
    wire rsp_pop  = ~rsp_empty && gbar_bus_if.rsp_ready;
    wire is_new_core = ~curr_mask[req_cid];
    wire bar_complete = req_fire && is_new_core && (next_cnt == (CORE_CNT_W'(gbar_bus_if.req_data.size_m1) + CORE_CNT_W'(1)));

    always @(posedge clk) begin
        if (reset) begin
            barrier_masks <= '0;
        end else if (req_fire && is_new_core) begin
            if (bar_complete) begin
                barrier_masks[req_id] <= '0;
            end else begin
                barrier_masks[req_id] <= next_mask;
            end
        end
    end

    VX_fifo_queue #(
        .DATAW  (NB_WIDTH),
        .DEPTH  (`VX_CFG_NUM_BARRIERS),
        .LUTRAM (1)
    ) rsp_fifo (
        .clk      (clk),
        .reset    (reset),
        .push     (bar_complete),
        .pop      (rsp_pop),
        .data_in  (req_id),
        .data_out (rsp_id_out),
        .empty    (rsp_empty),
        .full     (rsp_full),
        `UNUSED_PIN (alm_empty),
        `UNUSED_PIN (alm_full),
        `UNUSED_PIN (size)
    );

    assign gbar_bus_if.req_ready   = ~rsp_full || rsp_pop;
    assign gbar_bus_if.rsp_valid   = ~rsp_empty;
    assign gbar_bus_if.rsp_data.id = rsp_id_out;

endmodule
