// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

module snitch_icache_handler #(
    parameter snitch_icache_pkg::config_t CFG = '0
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  logic                         flush_valid_i,
    input  logic [CFG.NR_FETCH_PORTS-1:0] flush_ports_i,

    input  logic [CFG.FETCH_AW-1:0]      in_req_addr_i,
    input  logic [CFG.ID_WIDTH_REQ-1:0]  in_req_id_i,
    input  logic [CFG.SET_ALIGN-1:0]     in_req_set_i,
    input  logic                         in_req_hit_i,
    input  logic [CFG.LINE_WIDTH-1:0]    in_req_data_i,
    input  logic                         in_req_error_i,
    input  logic                         in_req_valid_i,
    output logic                         in_req_ready_o,

    output logic [CFG.LINE_WIDTH-1:0]    in_rsp_data_o,
    output logic                         in_rsp_error_o,
    output logic [CFG.ID_WIDTH_RESP-1:0] in_rsp_id_o,
    output logic                         in_rsp_valid_o,
    input  logic                         in_rsp_ready_i,

    output logic [CFG.COUNT_ALIGN-1:0]   write_addr_o,
    output logic [CFG.SET_ALIGN-1:0]     write_set_o,
    output logic [CFG.LINE_WIDTH-1:0]    write_data_o,
    output logic [CFG.TAG_WIDTH-1:0]     write_tag_o,
    output logic                         write_error_o,
    output logic                         write_valid_o,
    input  logic                         write_ready_i,

    output logic [CFG.FETCH_AW-1:0]      out_req_addr_o,
    output logic [CFG.PENDING_IW-1:0]    out_req_id_o,
    output logic                         out_req_valid_o,
    input  logic                         out_req_ready_i,

    input  logic [CFG.LINE_WIDTH-1:0]    out_rsp_data_i,
    input  logic                         out_rsp_error_i,
    input  logic [CFG.PENDING_IW-1:0]    out_rsp_id_i,
    input  logic                         out_rsp_valid_i,
    output logic                         out_rsp_ready_o
);

    `ifndef SYNTHESIS
    initial assert(CFG != '0);
    `endif

    wire _unused_set = ^in_req_set_i;

    logic [CFG.ID_WIDTH_RESP-1:0] flush_id_mask;
    always_comb begin
        flush_id_mask = '0;
        for (int p = 0; p < CFG.NR_FETCH_PORTS; p++) begin
            if (flush_ports_i[p]) begin
                flush_id_mask[2*p +: 2] = 2'b11;
            end
        end
    end

    typedef struct packed {
        logic                         valid;
        logic                         stale;
        logic [CFG.FETCH_AW-1:0]      addr;
        logic [CFG.ID_WIDTH_RESP-1:0] idmask;
    } pending_t;

    pending_t pending_q [CFG.PENDING_COUNT];
    logic [CFG.PENDING_COUNT-1:0] pending_clr;
    logic [CFG.PENDING_COUNT-1:0] pending_set;

    logic [CFG.PENDING_IW-1:0]    push_index;
    logic                         push_init;
    logic [CFG.FETCH_AW-1:0]      push_addr;
    logic [CFG.ID_WIDTH_RESP-1:0] push_idmask;
    logic                         push_enable;

    logic [CFG.PENDING_IW-1:0]    pop_index;
    logic [CFG.FETCH_AW-1:0]      pop_addr;
    logic [CFG.ID_WIDTH_RESP-1:0] pop_idmask;
    logic                         pop_stale;
    logic                         pop_enable;

    wire [CFG.FETCH_AW-1:0] req_line_addr = {in_req_addr_i[CFG.FETCH_AW-1:CFG.LINE_ALIGN], {CFG.LINE_ALIGN{1'b0}}};

    for (genvar i = 0; i < CFG.PENDING_COUNT; i++) begin : g_pending_row
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                pending_q[i].valid  <= 1'b0;
                pending_q[i].stale  <= 1'b0;
                pending_q[i].addr   <= '0;
                pending_q[i].idmask <= '0;
            end else begin
                if (pending_clr[i] && !pending_set[i]) begin
                    pending_q[i].valid  <= 1'b0;
                    pending_q[i].stale  <= 1'b0;
                    pending_q[i].idmask <= '0;
                end else if (pending_set[i] && !pending_clr[i]) begin
                    pending_q[i].valid  <= 1'b1;
                    pending_q[i].addr   <= push_addr;
                    if (push_init) begin
                        pending_q[i].stale  <= flush_valid_i;
                        pending_q[i].idmask <= push_idmask & ~flush_id_mask;
                    end else begin
                        pending_q[i].stale  <= pending_q[i].stale | flush_valid_i;
                        pending_q[i].idmask <= (pending_q[i].idmask | push_idmask) & ~flush_id_mask;
                    end
                end else if (pending_q[i].valid) begin
                    pending_q[i].stale  <= pending_q[i].stale | flush_valid_i;
                    pending_q[i].idmask <= pending_q[i].idmask & ~flush_id_mask;
                end
            end
        end
    end

    always_comb begin : p_pushpop_bypass
        pending_set = push_enable ? CFG.PENDING_COUNT'(1'b1) << push_index : '0;
        pending_clr = pop_enable  ? CFG.PENDING_COUNT'(1'b1) << pop_index  : '0;
        pop_addr    = pending_q[pop_index].addr;
        pop_idmask  = pending_q[pop_index].idmask & ~flush_id_mask;
        pop_stale   = pending_q[pop_index].stale | flush_valid_i;
        if (push_enable && pop_enable && (push_index == pop_index) && !push_init) begin
            pop_addr   = push_addr;
            pop_idmask = (pending_q[pop_index].idmask | push_idmask) & ~flush_id_mask;
        end
    end

    logic [CFG.PENDING_COUNT-1:0] free_entries;
    logic free;
    logic [CFG.PENDING_IW-1:0] free_id;

    always_comb begin : p_free_id
        for (int i = 0; i < CFG.PENDING_COUNT; i++)
            free_entries[i] = ~pending_q[i].valid;
        free = |free_entries;
    end

    lzc #(.WIDTH(CFG.PENDING_COUNT)) i_lzc_free (
        .in_i    ( free_entries ),
        .cnt_o   ( free_id      ),
        .empty_o (              )
    );

    logic [CFG.PENDING_COUNT-1:0] pending_matches;
    logic pending;
    logic [CFG.PENDING_IW-1:0] pending_id;

    always_comb begin : p_pending_id
        for (int i = 0; i < CFG.PENDING_COUNT; i++)
            // Never coalesce a new miss onto a pre-flush stale MSHR refill!
            pending_matches[i] = pending_q[i].valid && !pending_q[i].stale && !flush_valid_i &&
                                 (pending_q[i].addr == req_line_addr);
        pending = |pending_matches;
    end

    lzc #(.WIDTH(CFG.PENDING_COUNT)) i_lzc_pending (
        .in_i    ( pending_matches ),
        .cnt_o   ( pending_id      ),
        .empty_o (                 )
    );

    logic [CFG.ID_WIDTH_RESP-1:0] hit_id;
    logic [CFG.LINE_WIDTH-1:0]    hit_data;
    logic                         hit_error;
    logic                         hit_valid;
    logic                         hit_ready;

    always_comb begin : p_miss_handler
        hit_valid       = 1'b0;
        hit_id          = (CFG.ID_WIDTH_RESP'(1'b1) << in_req_id_i) & ~flush_id_mask;
        hit_data        = in_req_data_i;
        hit_error       = in_req_error_i;

        push_index      = free_id;
        push_init       = 1'b0;
        push_addr       = req_line_addr;
        push_idmask     = (CFG.ID_WIDTH_RESP'(1'b1) << in_req_id_i) & ~flush_id_mask;
        push_enable     = 1'b0;

        in_req_ready_o  = 1'b1;
        out_req_addr_o  = req_line_addr;
        out_req_id_o    = free_id;
        out_req_valid_o = 1'b0;

        if (in_req_valid_i && !flush_ports_i[in_req_id_i >> 1]) begin
            if (in_req_hit_i && !flush_valid_i) begin
                hit_valid      = 1'b1;
                in_req_ready_o = hit_ready;
            end else if (pending) begin
                push_index     = pending_id;
                push_enable    = 1'b1;
            end else if (free && !flush_valid_i) begin
                out_req_addr_o  = req_line_addr;
                out_req_id_o    = free_id;
                out_req_valid_o = 1'b1;
                in_req_ready_o  = out_req_ready_i;
                push_index      = free_id;
                push_init       = 1'b1;
                push_enable     = out_req_ready_i;
            end else begin
                in_req_ready_o = 1'b0;
            end
        end
    end

    logic [CFG.SET_ALIGN-1:0] evict_index;
    logic evict_enable;

    snitch_icache_lfsr #(CFG.SET_ALIGN) i_evict_lfsr (
        .clk_i    ( clk_i        ),
        .rst_ni   ( rst_ni       ),
        .value_o  ( evict_index  ),
        .enable_i ( evict_enable )
    );

    logic write_served_q;
    logic in_rsp_served_q;
    logic rsp_valid, rsp_ready;
    logic need_write, need_rsp;

    typedef struct packed {
        logic sel;
        logic lock;
    } arb_t;
    arb_t arb_q, arb_d;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            arb_q <= '0;
        else
            arb_q <= arb_d;
    end

    always_comb begin : p_response_handler
        pop_index  = out_rsp_id_i;
        pop_enable = 1'b0;

        write_addr_o  = CFG.COUNT_ALIGN'(pop_addr >> CFG.LINE_ALIGN);
        write_set_o   = evict_index;
        write_data_o  = out_rsp_data_i;
        write_tag_o   = CFG.TAG_WIDTH'(pop_addr >> (CFG.LINE_ALIGN + CFG.COUNT_ALIGN));
        write_error_o = 1'b0;
        write_valid_o = 1'b0;

        in_rsp_data_o  = out_rsp_data_i;
        in_rsp_error_o = out_rsp_error_i;
        in_rsp_id_o    = pop_idmask;
        in_rsp_valid_o = 1'b0;

        hit_ready       = 1'b1;
        out_rsp_ready_o = 1'b1;
        evict_enable    = 1'b0;
        rsp_valid       = 1'b0;
        rsp_ready       = 1'b1;
        need_write      = 1'b0;
        need_rsp        = 1'b0;

        arb_d = arb_q;
        if (!arb_q.lock) begin
            if (hit_valid) begin
                arb_d.sel  = 1'b0;
                arb_d.lock = 1'b1;
            end else if (out_rsp_valid_i) begin
                arb_d.sel  = 1'b1;
                arb_d.lock = 1'b1;
            end else begin
                arb_d.sel  = 1'b0;
                arb_d.lock = 1'b0;
            end
        end

        if (arb_d.sel == 1'b0) begin
            if (hit_valid) begin
                out_rsp_ready_o = 1'b0;
                in_rsp_data_o   = hit_data;
                in_rsp_error_o  = hit_error;
                in_rsp_id_o     = hit_id;
                in_rsp_valid_o  = (hit_id != '0);
                hit_ready       = (hit_id != '0) ? in_rsp_ready_i : 1'b1;
            end else begin
                hit_ready = 1'b1;
            end
            if (hit_ready) arb_d.lock = 1'b0;
        end else begin
            if (out_rsp_valid_i) begin
                hit_ready       = 1'b0;
                need_write      = !out_rsp_error_i && !pop_stale;
                need_rsp        = (pop_idmask != '0);
                rsp_valid       = 1'b1;
                rsp_ready       = (!need_rsp   || in_rsp_ready_i || in_rsp_served_q) &&
                                  (!need_write || write_ready_i  || write_served_q);
                write_valid_o   = need_write && !write_served_q;
                in_rsp_valid_o  = need_rsp   && !in_rsp_served_q;
                pop_enable      = rsp_ready;
                out_rsp_ready_o = rsp_ready;
                evict_enable    = rsp_ready && need_write;
            end else begin
                rsp_ready = 1'b1;
            end
            if (rsp_ready) arb_d.lock = 1'b0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            write_served_q  <= 1'b0;
            in_rsp_served_q <= 1'b0;
        end else begin
            write_served_q  <= rsp_valid & ~rsp_ready & (write_served_q  | (need_write & write_ready_i));
            in_rsp_served_q <= rsp_valid & ~rsp_ready & (in_rsp_served_q | (need_rsp   & in_rsp_ready_i));
        end
    end

endmodule
