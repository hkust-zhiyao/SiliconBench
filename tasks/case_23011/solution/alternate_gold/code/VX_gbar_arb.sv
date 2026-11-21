// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0

`include "VX_define.vh"

module VX_gbar_arb import VX_gpu_pkg::*; #(
    parameter NUM_REQS    = 1,
    parameter REQ_OUT_BUF = 0,
    parameter RSP_OUT_BUF = 0,
    parameter `STRING ARBITER = "R"
) (
    input  wire           clk,
    input  wire           reset,
    VX_gbar_bus_if.slave  bus_in_if [NUM_REQS],
    VX_gbar_bus_if.master bus_out_if
);
    `UNUSED_PARAM (REQ_OUT_BUF)
    `UNUSED_PARAM (RSP_OUT_BUF)
    localparam SELW = `LOG2UP(NUM_REQS);

    wire [NUM_REQS-1:0] req_v_vec;
    gbar_req_t          req_d_vec [NUM_REQS];
    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_in
        assign req_v_vec[i] = bus_in_if[i].req_valid;
        assign req_d_vec[i] = bus_in_if[i].req_data;
    end

    wire [SELW-1:0] pick_idx;
    wire            pick_vld;
    reg             out_req_v_q;
    gbar_req_t      out_req_d_q;
    wire            stage_rdy = !out_req_v_q || bus_out_if.req_ready;

    if (NUM_REQS == 1) begin : g_one
        assign pick_idx = '0;
        assign pick_vld = req_v_vec[0];
    end else begin : g_rr
        VX_generic_arbiter #(.NUM_REQS(NUM_REQS), .TYPE(ARBITER), .STICKY(0)) u_rr (
            .clk(clk), .reset(reset), .requests(req_v_vec),
            .grant_index(pick_idx), `UNUSED_PIN(grant_onehot),
            .grant_valid(pick_vld), .grant_ready(stage_rdy)
        );
    end

    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_rdy
        assign bus_in_if[i].req_ready = stage_rdy && pick_vld && (pick_idx == SELW'(i));
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            out_req_v_q <= 1'b0;
            out_req_d_q <= '0;
        end else if (stage_rdy) begin
            out_req_v_q <= pick_vld;
            if (pick_vld) out_req_d_q <= req_d_vec[pick_idx];
        end
    end
    assign bus_out_if.req_valid = out_req_v_q;
    assign bus_out_if.req_data  = out_req_d_q;

    // Registered per-core eager response broadcast buffer
    reg [NUM_REQS-1:0] pend_rsp_v_q;
    gbar_rsp_t         pend_rsp_d_q;
    wire [NUM_REQS-1:0] in_rsp_rdy;
    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_rsp
        assign in_rsp_rdy[i]         = bus_in_if[i].rsp_ready;
        assign bus_in_if[i].rsp_valid = pend_rsp_v_q[i];
        assign bus_in_if[i].rsp_data  = pend_rsp_d_q;
    end
    wire [NUM_REQS-1:0] rem_after = pend_rsp_v_q & ~in_rsp_rdy;
    wire                can_load  = (rem_after == '0);
    assign bus_out_if.rsp_ready   = can_load;

    always_ff @(posedge clk) begin
        if (reset) begin
            pend_rsp_v_q <= '0;
            pend_rsp_d_q <= '0;
        end else if (can_load && bus_out_if.rsp_valid) begin
            pend_rsp_v_q <= {NUM_REQS{1'b1}};
            pend_rsp_d_q <= bus_out_if.rsp_data;
        end else begin
            pend_rsp_v_q <= rem_after;
        end
    end
endmodule
