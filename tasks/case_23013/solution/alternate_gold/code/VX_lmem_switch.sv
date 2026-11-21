// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_define.vh"

module VX_lmem_switch import VX_gpu_pkg::*; #(
    parameter GLOBAL_OUT_BUF = 0,
    parameter LOCAL_OUT_BUF = 0,
    parameter RSP_OUT_BUF = 0,
    parameter `STRING ARBITER = "R"
) (
    input wire              clk,
    input wire              reset,
    VX_lsu_mem_if.slave     lsu_in_if,
    VX_lsu_mem_if.master    global_out_if,
    VX_lsu_mem_if.master    local_out_if
);
    localparam REQ_DATAW = `VX_CFG_NUM_LSU_LANES + 1 + `VX_CFG_NUM_LSU_LANES * (LSU_WORD_SIZE + LSU_ADDR_WIDTH + MEM_ATTR_WIDTH + LSU_WORD_SIZE * 8) + LSU_TAG_WIDTH;
    localparam RSP_DATAW = `VX_CFG_NUM_LSU_LANES + `VX_CFG_NUM_LSU_LANES * (LSU_WORD_SIZE * 8) + LSU_TAG_WIDTH;

    wire [`VX_CFG_NUM_LSU_LANES-1:0] is_addr_local_mask;
    for (genvar i = 0; i < `VX_CFG_NUM_LSU_LANES; ++i) begin : g_is_addr_local_mask
        assign is_addr_local_mask[i] = lsu_in_if.req_data.user[i][MEM_ATTR_LOCAL_OFFS];
    end

    wire [`VX_CFG_NUM_LSU_LANES-1:0] global_mask = lsu_in_if.req_data.mask & ~is_addr_local_mask;
    wire [`VX_CFG_NUM_LSU_LANES-1:0] local_mask  = lsu_in_if.req_data.mask &  is_addr_local_mask;

    wire is_addr_global = |global_mask;
    wire is_addr_local  = |local_mask;

    wire req_global_ready;
    wire req_local_ready;

    // Lockstep dual-ready fork: accept into target elastic buffers atomically only when all active branches are ready
    wire both_subsets_ready = (!is_addr_global || req_global_ready)
                           && (!is_addr_local  || req_local_ready);

    assign lsu_in_if.req_ready = both_subsets_ready;

    localparam NUM_SLICES = 4;
    localparam SLICE_W    = (REQ_DATAW + NUM_SLICES - 1) / NUM_SLICES;
    localparam PAD_W      = NUM_SLICES * SLICE_W;

    wire [`VX_CFG_NUM_LSU_LANES-1:0][MEM_ATTR_WIDTH-1:0] local_user;
    for (genvar i = 0; i < `VX_CFG_NUM_LSU_LANES; ++i) begin : g_local_user
        assign local_user[i] = lsu_in_if.req_data.user[i];
    end

    wire [REQ_DATAW-1:0] global_din_raw = {
        global_mask, lsu_in_if.req_data.rw, lsu_in_if.req_data.addr,
        lsu_in_if.req_data.data, lsu_in_if.req_data.byteen,
        lsu_in_if.req_data.user, lsu_in_if.req_data.tag
    };
    wire [REQ_DATAW-1:0] local_din_raw = {
        local_mask, lsu_in_if.req_data.rw, lsu_in_if.req_data.addr,
        lsu_in_if.req_data.data, lsu_in_if.req_data.byteen,
        local_user, lsu_in_if.req_data.tag
    };

    wire [PAD_W-1:0] global_din_pad = PAD_W'(global_din_raw);
    wire [PAD_W-1:0] local_din_pad  = PAD_W'(local_din_raw);
    wire [PAD_W-1:0] global_dout_pad;
    wire [PAD_W-1:0] local_dout_pad;
    wire [NUM_SLICES-1:0] g_rdy_in, g_vld_out, l_rdy_in, l_vld_out;

    for (genvar s = 0; s < NUM_SLICES; ++s) begin : g_req_slices
        (* keep_hierarchy = "yes" *)
        VX_elastic_buffer #(
            .DATAW   (SLICE_W),
            .SIZE    (`TO_OUT_BUF_SIZE(GLOBAL_OUT_BUF)),
            .OUT_REG (`TO_OUT_BUF_REG(GLOBAL_OUT_BUF))
        ) req_global_slice (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (lsu_in_if.req_valid && both_subsets_ready && is_addr_global),
            .data_in   (global_din_pad[s*SLICE_W +: SLICE_W]),
            .ready_in  (g_rdy_in[s]),
            .valid_out (g_vld_out[s]),
            .data_out  (global_dout_pad[s*SLICE_W +: SLICE_W]),
            .ready_out (global_out_if.req_ready)
        );
        (* keep_hierarchy = "yes" *)
        VX_elastic_buffer #(
            .DATAW   (SLICE_W),
            .SIZE    (`TO_OUT_BUF_SIZE(LOCAL_OUT_BUF)),
            .OUT_REG (`TO_OUT_BUF_REG(LOCAL_OUT_BUF))
        ) req_local_slice (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (lsu_in_if.req_valid && both_subsets_ready && is_addr_local),
            .data_in   (local_din_pad[s*SLICE_W +: SLICE_W]),
            .ready_in  (l_rdy_in[s]),
            .valid_out (l_vld_out[s]),
            .data_out  (local_dout_pad[s*SLICE_W +: SLICE_W]),
            .ready_out (local_out_if.req_ready)
        );
    end

    assign req_global_ready       = g_rdy_in[0];
    assign global_out_if.req_valid = g_vld_out[0];
    assign global_out_if.req_data  = global_dout_pad[REQ_DATAW-1:0];

    assign req_local_ready        = l_rdy_in[0];
    assign local_out_if.req_valid  = l_vld_out[0];
    assign local_out_if.req_data   = local_dout_pad[REQ_DATAW-1:0];

    VX_stream_arb #(
        .NUM_INPUTS (2),
        .DATAW      (RSP_DATAW),
        .ARBITER    (ARBITER),
        .OUT_BUF    (RSP_OUT_BUF)
    ) rsp_arb (
        .clk       (clk),
        .reset     (reset),
        .valid_in  ({
            local_out_if.rsp_valid,
            global_out_if.rsp_valid
        }),
        .ready_in  ({
            local_out_if.rsp_ready,
            global_out_if.rsp_ready
        }),
        .data_in   ({
            local_out_if.rsp_data,
            global_out_if.rsp_data
        }),
        .data_out  (lsu_in_if.rsp_data),
        .valid_out (lsu_in_if.rsp_valid),
        .ready_out (lsu_in_if.rsp_ready),
        `UNUSED_PIN (sel_out)
    );

endmodule
