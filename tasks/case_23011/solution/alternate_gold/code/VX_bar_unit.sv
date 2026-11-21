// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0

`include "VX_define.vh"

module VX_bar_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter CORE_ID = 0
) (
    input  wire                          clk,
    input  wire                          reset,
    input  wire                          req_valid,
    input  wire [NW_WIDTH-1:0]           req_wid,
    input  barrier_t                     req_data,
    input  wire [BAR_ADDR_W-1:0]         read_addr,
    output wire                          read_phase,
    VX_gbar_bus_if.master                gbar_bus_if,
    input  wire [`VX_CFG_NUM_WARPS-1:0]  active_warps,
    output wire                          unlock_valid,
    output wire [`VX_CFG_NUM_WARPS-1:0]  unlock_mask
);
    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (CORE_ID)

    localparam NUM_SLOTS = (1 << BAR_ADDR_BITS);
    localparam EV_W      = `CLOG2(`VX_CFG_MAX_BAR_EVENTS + 1) + 1;
    localparam USE_GBAR  = (`VX_CFG_NUM_CORES > 1);

    typedef struct packed {
        logic                         epoch;
        logic                         all_arrived;
        logic [`VX_CFG_NUM_WARPS-1:0] wmask;
        logic [NW_WIDTH-1:0]          arr_cnt;
        logic signed [EV_W-1:0]       ev_bal;
    } slot_entry_t;

    slot_entry_t slot_rf_q [NUM_SLOTS];
    slot_entry_t cur_q, nxt_slot;
    reg [BAR_ADDR_W-1:0] active_slot_q;

    reg [`VX_CFG_NUM_BARRIERS-1:0]                         gb_inflight_q;
    reg [`VX_CFG_NUM_BARRIERS-1:0]                         gb_epoch_q;
    reg [`VX_CFG_NUM_BARRIERS-1:0][`VX_CFG_NUM_WARPS-1:0]  gb_wait_q;

    wire [NB_WIDTH-1:0]   rsp_id   = gbar_bus_if.rsp_data.id;
    wire [BAR_ADDR_W-1:0] rsp_slot = BAR_ADDR_W'(rsp_id);
    wire                  rsp_mine = USE_GBAR && gb_inflight_q[rsp_id];
    wire                  rsp_rdy  = ~rsp_mine || ~(req_valid && (active_slot_q == rsp_slot));
    wire                  rsp_commit = rsp_mine && gbar_bus_if.rsp_valid && rsp_rdy;

    logic                          rel_loc_v, rel_gb_v;
    logic [`VX_CFG_NUM_WARPS-1:0]  rel_loc_m, rel_gb_m;
    logic                          gb_push;
    logic [NB_WIDTH-1:0]           gb_push_id;
    logic [NC_WIDTH-1:0]           gb_push_sz;

    wire [`VX_CFG_NUM_WARPS-1:0] w_one = ((`VX_CFG_NUM_WARPS)'(1) << req_wid);
    wire [`VX_CFG_NUM_WARPS-1:0] w_comb = cur_q.wmask | w_one;
    wire signed [EV_W-1:0]       ev_inc = $signed({1'b0, req_data.size_m1}) + EV_W'(1);

    always_comb begin
        nxt_slot   = cur_q;
        rel_loc_v  = 1'b0;
        rel_loc_m  = '0;
        rel_gb_v   = 1'b0;
        rel_gb_m   = '0;
        gb_push    = 1'b0;
        gb_push_id = '0;
        gb_push_sz = '0;

        if (req_valid && !req_data.is_global) begin
            if (req_data.is_event) begin
                nxt_slot.ev_bal = req_data.phase ? (cur_q.ev_bal + ev_inc) : (cur_q.ev_bal - EV_W'(1));
                if (cur_q.all_arrived && (nxt_slot.ev_bal == '0)) begin
                    nxt_slot.all_arrived = 1'b0;
                    nxt_slot.arr_cnt     = '0;
                    nxt_slot.wmask       = '0;
                    nxt_slot.epoch       = ~cur_q.epoch;
                    rel_loc_v            = (cur_q.wmask != '0);
                    rel_loc_m            = cur_q.wmask;
                end
            end else if (req_data.is_arrive) begin
                if (cur_q.arr_cnt == NW_WIDTH'(req_data.size_m1)) begin
                    nxt_slot.arr_cnt = '0;
                    if (cur_q.ev_bal == '0) begin
                        logic [`VX_CFG_NUM_WARPS-1:0] m_out;
                        m_out                = req_data.is_sync ? w_comb : cur_q.wmask;
                        nxt_slot.all_arrived = 1'b0;
                        nxt_slot.wmask       = '0;
                        nxt_slot.epoch       = ~cur_q.epoch;
                        rel_loc_v            = (m_out != '0);
                        rel_loc_m            = m_out;
                    end else begin
                        nxt_slot.all_arrived = 1'b1;
                        if (req_data.is_sync) nxt_slot.wmask = w_comb;
                    end
                end else begin
                    nxt_slot.arr_cnt = cur_q.arr_cnt + NW_WIDTH'(1);
                    if (req_data.is_sync) nxt_slot.wmask = w_comb;
                end
            end else begin
                if (req_data.phase != cur_q.epoch) begin
                    rel_loc_v = 1'b1;
                    rel_loc_m = w_one;
                end else begin
                    nxt_slot.wmask = w_comb;
                end
            end
        end else if (USE_GBAR && req_valid && req_data.is_global) begin
            if (req_data.is_event) begin
                nxt_slot.ev_bal = req_data.phase ? (cur_q.ev_bal + ev_inc) : (cur_q.ev_bal - EV_W'(1));
                if ((nxt_slot.ev_bal == '0) && (active_warps != '0) && (cur_q.wmask == active_warps)) begin
                    nxt_slot.wmask       = '0;
                    nxt_slot.all_arrived = 1'b0;
                    gb_push              = 1'b1;
                    gb_push_id           = req_data.id;
                    gb_push_sz           = NC_WIDTH'(cur_q.arr_cnt);
                end
            end else if (req_data.is_arrive) begin
                nxt_slot.arr_cnt = NW_WIDTH'(req_data.size_m1);
                if ((active_warps != '0) && (w_comb == active_warps) && (cur_q.ev_bal == '0)) begin
                    nxt_slot.wmask = '0;
                    gb_push        = 1'b1;
                    gb_push_id     = req_data.id;
                    gb_push_sz     = NC_WIDTH'(req_data.size_m1);
                end else begin
                    nxt_slot.wmask = w_comb;
                end
            end else if (req_data.phase != cur_q.epoch) begin
                rel_loc_v = 1'b1;
                rel_loc_m = w_one;
            end
        end

        if (USE_GBAR && rsp_commit) begin
            rel_gb_v = (gb_wait_q[rsp_id] != '0);
            rel_gb_m = gb_wait_q[rsp_id];
        end
    end

    slot_entry_t rd_fwd_slot;
    always_comb begin
        rd_fwd_slot = slot_rf_q[read_addr];
        if (req_valid && (active_slot_q == read_addr))
            rd_fwd_slot = nxt_slot;
        if (rsp_commit && (rsp_slot == read_addr))
            rd_fwd_slot.epoch = ~gb_epoch_q[rsp_id];
    end
    assign read_phase = rd_fwd_slot.epoch;

    reg                          unlock_v_q;
    reg [`VX_CFG_NUM_WARPS-1:0]  unlock_m_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int s = 0; s < NUM_SLOTS; s++) slot_rf_q[s] <= '0;
            cur_q         <= '0;
            active_slot_q <= '0;
            gb_inflight_q <= '0;
            gb_epoch_q    <= '0;
            gb_wait_q     <= '0;
            unlock_v_q    <= 1'b0;
            unlock_m_q    <= '0;
        end else begin
            if (req_valid) begin
                slot_rf_q[active_slot_q] <= nxt_slot;
                if (USE_GBAR && req_data.is_global && !req_data.is_event) begin
                    if (req_data.is_arrive && req_data.is_sync)
                        gb_wait_q[req_data.id][req_wid] <= 1'b1;
                    else if (!req_data.is_arrive && (req_data.phase == cur_q.epoch))
                        gb_wait_q[req_data.id][req_wid] <= 1'b1;
                end
            end
            if (rsp_commit) begin
                slot_rf_q[rsp_slot].epoch <= ~gb_epoch_q[rsp_id];
                gb_wait_q[rsp_id]         <= '0;
                gb_inflight_q[rsp_id]     <= 1'b0;
            end
            if (gb_push) begin
                gb_inflight_q[gb_push_id] <= 1'b1;
                gb_epoch_q[gb_push_id]    <= cur_q.epoch;
            end
            active_slot_q <= read_addr;
            cur_q         <= rd_fwd_slot;
            unlock_v_q    <= rel_loc_v || rel_gb_v;
            unlock_m_q    <= (rel_loc_v ? rel_loc_m : '0) | (rel_gb_v ? rel_gb_m : '0);
        end
    end

    assign unlock_valid = unlock_v_q;
    assign unlock_mask  = unlock_m_q;

    if (USE_GBAR) begin : g_gb_out
        localparam Q_DEPTH = (1 << NB_WIDTH);
        localparam Q_PTRW  = `CLOG2(Q_DEPTH);
        reg [Q_DEPTH-1:0][NB_WIDTH+NC_WIDTH-1:0] q_mem;
        reg [Q_PTRW-1:0] q_rd, q_wr;
        reg [Q_PTRW:0]   q_cnt;
        wire q_pop = (q_cnt != '0) && gbar_bus_if.req_ready;
        always_ff @(posedge clk) begin
            if (reset) begin
                q_rd <= '0; q_wr <= '0; q_cnt <= '0;
            end else begin
                if (gb_push) begin q_mem[q_wr] <= {gb_push_id, gb_push_sz}; q_wr <= q_wr + Q_PTRW'(1); end
                if (q_pop)   begin q_rd <= q_rd + Q_PTRW'(1); end
                case ({gb_push, q_pop})
                    2'b10: q_cnt <= q_cnt + 1'b1;
                    2'b01: q_cnt <= q_cnt - 1'b1;
                    default: ;
                endcase
            end
        end
        assign gbar_bus_if.req_valid = (q_cnt != '0);
        assign {gbar_bus_if.req_data.id, gbar_bus_if.req_data.size_m1} = q_mem[q_rd];
        assign gbar_bus_if.req_data.core_id = NC_WIDTH'(CORE_ID % `VX_CFG_NUM_CORES);
        assign gbar_bus_if.rsp_ready = rsp_rdy;
    end else begin : g_no_gb_out
        assign gbar_bus_if.req_valid = 1'b0;
        assign gbar_bus_if.req_data  = '0;
        assign gbar_bus_if.rsp_ready = 1'b0;
        `UNUSED_VAR (gbar_bus_if.req_ready)
        `UNUSED_VAR (gb_push_sz)
    end
endmodule
