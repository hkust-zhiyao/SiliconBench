// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0

`include "VX_define.vh"

module VX_gbar_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input  wire          clk,
    input  wire          reset,
    VX_gbar_bus_if.slave gbar_bus_if
);
    `UNUSED_SPARAM (INSTANCE_ID)
    localparam CNT_W = `CLOG2(`VX_CFG_NUM_CORES + 1);
    localparam Q_W   = `CLOG2(`VX_CFG_NUM_BARRIERS);

    reg [`VX_CFG_NUM_BARRIERS-1:0][`VX_CFG_NUM_CORES-1:0] seen_cores_q;
    reg [`VX_CFG_NUM_BARRIERS-1:0][CNT_W-1:0]             seen_cnt_q;
    reg [`VX_CFG_NUM_BARRIERS-1:0][NB_WIDTH-1:0]          rsp_ring_q;
    reg [Q_W-1:0] rd_ptr_q, wr_ptr_q;
    reg [Q_W:0]   occ_q;

    wire rsp_full = (occ_q == (Q_W+1)'(`VX_CFG_NUM_BARRIERS));
    wire rsp_pop  = (occ_q != '0) && gbar_bus_if.rsp_ready;
    assign gbar_bus_if.req_ready = !rsp_full || rsp_pop;

    wire req_hs   = gbar_bus_if.req_valid && gbar_bus_if.req_ready;
    wire [NB_WIDTH-1:0] bid = gbar_bus_if.req_data.id;
    wire [NC_WIDTH-1:0] cid = gbar_bus_if.req_data.core_id;
    wire fresh    = req_hs && !seen_cores_q[bid][cid];
    wire hit_goal = fresh && ((seen_cnt_q[bid] + CNT_W'(1)) == (CNT_W'(gbar_bus_if.req_data.size_m1) + CNT_W'(1)));

    always_ff @(posedge clk) begin
        if (reset) begin
            seen_cores_q <= '0;
            seen_cnt_q   <= '0;
            rd_ptr_q     <= '0;
            wr_ptr_q     <= '0;
            occ_q        <= '0;
        end else begin
            if (fresh) begin
                if (hit_goal) begin
                    seen_cores_q[bid] <= '0;
                    seen_cnt_q[bid]   <= '0;
                    rsp_ring_q[wr_ptr_q] <= bid;
                    wr_ptr_q          <= wr_ptr_q + Q_W'(1);
                end else begin
                    seen_cores_q[bid][cid] <= 1'b1;
                    seen_cnt_q[bid]        <= seen_cnt_q[bid] + CNT_W'(1);
                end
            end
            if (rsp_pop) rd_ptr_q <= rd_ptr_q + Q_W'(1);
            case ({hit_goal, rsp_pop})
                2'b10: occ_q <= occ_q + 1'b1;
                2'b01: occ_q <= occ_q - 1'b1;
                default: ;
            endcase
        end
    end

    assign gbar_bus_if.rsp_valid   = (occ_q != '0);
    assign gbar_bus_if.rsp_data.id = rsp_ring_q[rd_ptr_q];
endmodule
