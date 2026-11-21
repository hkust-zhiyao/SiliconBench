// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0

`include "VX_define.vh"

module VX_bar_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter CORE_ID = 0
) (
    input  wire                          clk,
    input  wire                          reset,

    // local barrier interface
    input  wire                          req_valid,
    input  wire [NW_WIDTH-1:0]           req_wid,
    input  barrier_t                     req_data,
    input  wire [BAR_ADDR_W-1:0]         read_addr,
    output wire                          read_phase,

    // global barrier interface
    VX_gbar_bus_if.master                gbar_bus_if,

    // scheduler interface
    input  wire [`VX_CFG_NUM_WARPS-1:0]  active_warps,
    output wire                          unlock_valid,
    output wire [`VX_CFG_NUM_WARPS-1:0]  unlock_mask
);
    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (CORE_ID)

    localparam NUM_SLOTS   = (1 << BAR_ADDR_BITS);
    // +1 sign bit for signed out-of-order expect_tx / txbar event accounting
    localparam EVENT_WIDTH = `CLOG2(`VX_CFG_MAX_BAR_EVENTS + 1) + 1;
    localparam BAR_STATEW  = 1 + `VX_CFG_NUM_WARPS + NW_WIDTH + EVENT_WIDTH;
    localparam GBAR_REQW   = NB_WIDTH + NC_WIDTH;
    localparam USE_GBAR    = (`VX_CFG_NUM_CORES > 1);

    logic                          warps_done_r, warps_done_n;
    logic [`VX_CFG_NUM_WARPS-1:0]  mask_r, mask_n;
    logic [NW_WIDTH-1:0]           count_r, count_n;
    logic signed [EVENT_WIDTH-1:0] events_r, events_n;
    logic                          phase_r, phase_n;

    logic                          local_unlock_v, gbar_unlock_v;
    logic [`VX_CFG_NUM_WARPS-1:0]  local_unlock_m, gbar_unlock_m;

    logic [`VX_CFG_NUM_BARRIERS-1:0] gbar_pending_r, gbar_pending_n;
    logic [`VX_CFG_NUM_BARRIERS-1:0] gbar_pending_phase_r, gbar_pending_phase_n;
    logic [`VX_CFG_NUM_BARRIERS-1:0][`VX_CFG_NUM_WARPS-1:0] gbar_waiters_r, gbar_waiters_n;

    logic                gbar_enqueue;
    logic [NB_WIDTH-1:0] gbar_enqueue_id;
    logic [NC_WIDTH-1:0] gbar_enqueue_size_m1;

    reg [BAR_ADDR_W-1:0] store_waddr;
    wire [BAR_ADDR_W-1:0] rsp_slot_addr = BAR_ADDR_W'(gbar_bus_if.rsp_data.id);
    wire rsp_is_pending = USE_GBAR && gbar_pending_r[gbar_bus_if.rsp_data.id];
    // Non-participating cores never stall global barrier broadcasts; participating cores
    // only stall if the exact same barrier slot is simultaneously being written by req_valid.
    wire gbar_rsp_ready = ~rsp_is_pending || ~(req_valid && (store_waddr == rsp_slot_addr));
    wire gbar_rsp_fire  = gbar_bus_if.rsp_valid && gbar_rsp_ready;
    wire gbar_rsp_apply = rsp_is_pending && gbar_rsp_fire;

    wire [`VX_CFG_NUM_WARPS-1:0] wid_bit   = ((`VX_CFG_NUM_WARPS)'(1) << req_wid);
    wire [`VX_CFG_NUM_WARPS-1:0] wait_mask = wid_bit | mask_r;
    wire [NW_WIDTH-1:0]          next_count = count_r + NW_WIDTH'(1);
    wire                         next_phase = ~phase_r;
    wire signed [EVENT_WIDTH-1:0] ev_delta_pos = $signed({1'b0, req_data.size_m1}) + EVENT_WIDTH'(1);

    always @(*) begin
        warps_done_n         = warps_done_r;
        mask_n               = mask_r;
        count_n              = count_r;
        events_n             = events_r;
        phase_n              = phase_r;
        local_unlock_v       = 1'b0;
        local_unlock_m       = '0;
        gbar_unlock_v        = 1'b0;
        gbar_unlock_m        = '0;
        gbar_pending_n       = gbar_pending_r;
        gbar_pending_phase_n = gbar_pending_phase_r;
        gbar_waiters_n       = gbar_waiters_r;
        gbar_enqueue         = 1'b0;
        gbar_enqueue_id      = '0;
        gbar_enqueue_size_m1 = '0;

        if (req_valid && ~req_data.is_global) begin
            if (req_data.is_event) begin
                events_n = req_data.phase ? (events_r + ev_delta_pos) : (events_r - EVENT_WIDTH'(1));
                if (warps_done_r && (events_n == '0)) begin
                    warps_done_n   = 1'b0;
                    count_n        = '0;
                    mask_n         = '0;
                    phase_n        = next_phase;
                    local_unlock_v = (mask_r != '0);
                    local_unlock_m = mask_r;
                end
            end else if (req_data.is_arrive) begin
                if (count_r == NW_WIDTH'(req_data.size_m1)) begin
                    count_n = '0;
                    if (events_r == '0) begin
                        logic [`VX_CFG_NUM_WARPS-1:0] rel_m;
                        rel_m          = req_data.is_sync ? wait_mask : mask_r;
                        warps_done_n   = 1'b0;
                        mask_n         = '0;
                        phase_n        = next_phase;
                        local_unlock_v = (rel_m != '0);
                        local_unlock_m = rel_m;
                    end else begin
                        warps_done_n = 1'b1;
                        if (req_data.is_sync) mask_n = wait_mask;
                    end
                end else begin
                    count_n = next_count;
                    if (req_data.is_sync) mask_n = wait_mask;
                end
            end else begin
                if (req_data.phase != phase_r) begin
                    local_unlock_v = 1'b1;
                    local_unlock_m = wid_bit;
                end else begin
                    mask_n = wait_mask;
                end
            end
        end

        if (USE_GBAR) begin
            if (req_valid && req_data.is_global) begin
                if (req_data.is_event) begin
                    events_n = req_data.phase ? (events_r + ev_delta_pos) : (events_r - EVENT_WIDTH'(1));
                    if ((events_n == '0) && (active_warps != '0) && (mask_r == active_warps)) begin
                        mask_n               = '0;
                        warps_done_n         = 1'b0;
                        gbar_enqueue         = 1'b1;
                        gbar_enqueue_id      = req_data.id;
                        gbar_enqueue_size_m1 = NC_WIDTH'(count_r);
                    end
                end else if (req_data.is_arrive) begin
                    count_n = NW_WIDTH'(req_data.size_m1);
                    if (req_data.is_sync) begin
                        gbar_waiters_n[req_data.id][req_wid] = 1'b1;
                    end
                    if ((active_warps != '0) && (wait_mask == active_warps) && (events_r == '0)) begin
                        mask_n               = '0;
                        warps_done_n         = 1'b0;
                        gbar_enqueue         = 1'b1;
                        gbar_enqueue_id      = req_data.id;
                        gbar_enqueue_size_m1 = NC_WIDTH'(req_data.size_m1);
                    end else begin
                        mask_n = wait_mask;
                    end
                end else begin
                    if (req_data.phase != phase_r) begin
                        local_unlock_v = 1'b1;
                        local_unlock_m = wid_bit;
                    end else begin
                        gbar_waiters_n[req_data.id][req_wid] = 1'b1;
                    end
                end
            end

            if (gbar_rsp_apply) begin
                gbar_unlock_v = (gbar_waiters_r[gbar_bus_if.rsp_data.id] != '0);
                gbar_unlock_m = gbar_waiters_r[gbar_bus_if.rsp_data.id];
                gbar_waiters_n[gbar_bus_if.rsp_data.id] = '0;
                gbar_pending_n[gbar_bus_if.rsp_data.id] = 1'b0;
            end

            if (gbar_enqueue) begin
                gbar_pending_n[gbar_enqueue_id]       = 1'b1;
                gbar_pending_phase_n[gbar_enqueue_id] = phase_r;
            end
        end
    end

    wire [BAR_STATEW-1:0] store_state_rdata;
    wire [BAR_STATEW-1:0] store_state_wdata = {warps_done_n, mask_n, count_n, events_n};
    wire                  store_state_write = req_valid;

    VX_dp_ram #(
        .DATAW    (BAR_STATEW),
        .SIZE     (NUM_SLOTS),
        .RDW_MODE ("W"),
        .LUTRAM   (1),
        .OUT_REG  (0)
    ) barrier_state_store (
        .clk   (clk),
        .reset (reset),
        .read  (1'b1),
        .write (store_state_write),
        .wren  (1'b1),
        .raddr (read_addr),
        .waddr (store_waddr),
        .wdata (store_state_wdata),
        .rdata (store_state_rdata)
    );

    reg [NUM_SLOTS-1:0]  store_valids;
    reg [NUM_SLOTS-1:0]  phase_vec_r;
    reg [BAR_STATEW-1:0] state_r;

    wire rsp_phase_hit = gbar_rsp_apply && (rsp_slot_addr == read_addr);
    wire req_phase_hit = req_valid && (store_waddr == read_addr);
    wire phase_comb    = rsp_phase_hit ? ~gbar_pending_phase_r[gbar_bus_if.rsp_data.id]
                       : (req_phase_hit ? phase_n : phase_vec_r[read_addr]);
    wire [BAR_STATEW-1:0] state_next_rd = req_phase_hit ? store_state_wdata
                                        : (store_valids[read_addr] ? store_state_rdata : '0);

    always @(posedge clk) begin
        if (reset) begin
            store_valids <= '0;
            phase_vec_r  <= '0;
            phase_r      <= 1'b0;
            store_waddr  <= '0;
            state_r      <= '0;
        end else begin
            if (store_state_write) begin
                store_valids[store_waddr] <= 1'b1;
                phase_vec_r[store_waddr]  <= phase_n;
            end
            if (gbar_rsp_apply) begin
                phase_vec_r[rsp_slot_addr] <= ~gbar_pending_phase_r[gbar_bus_if.rsp_data.id];
            end
            phase_r     <= phase_comb;
            store_waddr <= read_addr;
            state_r     <= state_next_rd;
        end
    end

    assign {warps_done_r, mask_r, count_r, events_r} = state_r;

    reg                          unlock_valid_r;
    reg [`VX_CFG_NUM_WARPS-1:0]  unlock_mask_r;
    wire                         unlock_valid_n = local_unlock_v || gbar_unlock_v;
    wire [`VX_CFG_NUM_WARPS-1:0] unlock_mask_n  = (local_unlock_v ? local_unlock_m : '0)
                                                | (gbar_unlock_v  ? gbar_unlock_m  : '0);

    always @(posedge clk) begin
        if (reset) begin
            unlock_valid_r <= 1'b0;
            unlock_mask_r  <= '0;
            gbar_pending_r <= '0;
            gbar_pending_phase_r <= '0;
            gbar_waiters_r <= '0;
        end else begin
            unlock_valid_r <= unlock_valid_n;
            unlock_mask_r  <= unlock_mask_n;
            gbar_pending_r <= gbar_pending_n;
            gbar_pending_phase_r <= gbar_pending_phase_n;
            gbar_waiters_r <= gbar_waiters_n;
        end
    end

    assign read_phase   = phase_comb;
    assign unlock_valid = unlock_valid_r;
    assign unlock_mask  = unlock_mask_r;

    if (USE_GBAR) begin : g_gbar
        wire [GBAR_REQW-1:0] req_queue_data;
        wire req_empty, req_alm_empty;
        wire req_pop = ~req_empty && gbar_bus_if.req_ready;

        VX_fifo_queue #(
            .DATAW  (GBAR_REQW),
            .DEPTH  (1 << NB_WIDTH),
            .LUTRAM (1)
        ) req_queue (
            .clk      (clk),
            .reset    (reset),
            .push     (gbar_enqueue),
            .pop      (req_pop),
            .data_in  ({gbar_enqueue_id, gbar_enqueue_size_m1}),
            .data_out (req_queue_data),
            .empty    (req_empty),
            .alm_empty(req_alm_empty),
            `UNUSED_PIN (alm_full),
            `UNUSED_PIN (full),
            `UNUSED_PIN (size)
        );

        reg gbar_req_valid_r;
        always @(posedge clk) begin
            if (reset) gbar_req_valid_r <= 1'b0;
            else       gbar_req_valid_r <= gbar_enqueue | (req_pop ? ~req_alm_empty : ~req_empty);
        end

        assign gbar_bus_if.req_valid        = gbar_req_valid_r;
        assign {gbar_bus_if.req_data.id, gbar_bus_if.req_data.size_m1} = req_queue_data;
        assign gbar_bus_if.req_data.core_id = NC_WIDTH'(CORE_ID % `VX_CFG_NUM_CORES);
        assign gbar_bus_if.rsp_ready        = gbar_rsp_ready;
    end else begin : g_nogbar
        assign gbar_bus_if.req_valid = 1'b0;
        assign gbar_bus_if.req_data  = '0;
        assign gbar_bus_if.rsp_ready = 1'b0;
        `UNUSED_VAR (gbar_bus_if.req_ready)
        `UNUSED_VAR (gbar_enqueue_size_m1)
    end

endmodule
