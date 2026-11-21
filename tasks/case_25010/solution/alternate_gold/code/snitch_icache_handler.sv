// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Alternate MSHR handler using epoch-tagged refill entries and per-port cancellation.
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

    logic [15:0] epoch_q, epoch_d;
    assign epoch_d = epoch_q + {15'd0, flush_valid_i};

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) epoch_q <= 16'd0;
        else         epoch_q <= epoch_d;
    end

    logic [CFG.ID_WIDTH_RESP-1:0] cancel_mask;
    always_comb begin
        cancel_mask = '0;
        for (int p = 0; p < CFG.NR_FETCH_PORTS; p++) begin
            if (flush_ports_i[p]) cancel_mask[2*p +: 2] = 2'b11;
        end
    end

    typedef struct packed {
        logic                         valid;
        logic [15:0]                  epoch;
        logic [CFG.FETCH_AW-1:0]      addr;
        logic [CFG.ID_WIDTH_RESP-1:0] idmask;
    } mshr_t;

    mshr_t mshr_q [CFG.PENDING_COUNT];
    logic [CFG.PENDING_COUNT-1:0] slot_clr, slot_set;

    logic [CFG.PENDING_IW-1:0]    alloc_idx;
    logic                         alloc_new;
    logic [CFG.FETCH_AW-1:0]      alloc_addr;
    logic [CFG.ID_WIDTH_RESP-1:0] alloc_mask;
    logic                         alloc_en;

    logic [CFG.PENDING_IW-1:0]    ret_idx;
    logic [CFG.FETCH_AW-1:0]      ret_addr;
    logic [CFG.ID_WIDTH_RESP-1:0] ret_mask;
    logic                         ret_stale;
    logic                         ret_en;

    wire [CFG.FETCH_AW-1:0] aligned_addr = {in_req_addr_i[CFG.FETCH_AW-1:CFG.LINE_ALIGN], {CFG.LINE_ALIGN{1'b0}}};

    for (genvar i = 0; i < CFG.PENDING_COUNT; i++) begin : g_mshr
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                mshr_q[i].valid  <= 1'b0;
                mshr_q[i].epoch  <= 16'd0;
                mshr_q[i].addr   <= '0;
                mshr_q[i].idmask <= '0;
            end else begin
                if (slot_clr[i] && !slot_set[i]) begin
                    mshr_q[i].valid  <= 1'b0;
                    mshr_q[i].idmask <= '0;
                end else if (slot_set[i] && !slot_clr[i]) begin
                    mshr_q[i].valid  <= 1'b1;
                    mshr_q[i].addr   <= alloc_addr;
                    if (alloc_new) begin
                        mshr_q[i].epoch  <= epoch_q;
                        mshr_q[i].idmask <= alloc_mask & ~cancel_mask;
                    end else begin
                        mshr_q[i].idmask <= (mshr_q[i].idmask | alloc_mask) & ~cancel_mask;
                    end
                end else if (mshr_q[i].valid) begin
                    mshr_q[i].idmask <= mshr_q[i].idmask & ~cancel_mask;
                end
            end
        end
    end

    always_comb begin
        slot_set  = alloc_en ? (CFG.PENDING_COUNT'(1'b1) << alloc_idx) : '0;
        slot_clr  = ret_en   ? (CFG.PENDING_COUNT'(1'b1) << ret_idx)   : '0;
        ret_addr  = mshr_q[ret_idx].addr;
        ret_mask  = mshr_q[ret_idx].idmask & ~cancel_mask;
        ret_stale = (mshr_q[ret_idx].epoch != epoch_d);
        if (alloc_en && ret_en && (alloc_idx == ret_idx) && !alloc_new) begin
            ret_addr = alloc_addr;
            ret_mask = (mshr_q[ret_idx].idmask | alloc_mask) & ~cancel_mask;
        end
    end

    logic [CFG.PENDING_COUNT-1:0] free_bmp, match_bmp;
    logic has_free, has_match;
    logic [CFG.PENDING_IW-1:0] free_idx, match_idx;

    always_comb begin
        for (int i = 0; i < CFG.PENDING_COUNT; i++) begin
            free_bmp[i]  = ~mshr_q[i].valid;
            match_bmp[i] = mshr_q[i].valid && !flush_valid_i &&
                           (mshr_q[i].epoch == epoch_q) &&
                           (mshr_q[i].addr == aligned_addr);
        end
        has_free  = |free_bmp;
        has_match = |match_bmp;
    end

    lzc #(.WIDTH(CFG.PENDING_COUNT)) i_lzc_f (
        .in_i    ( free_bmp ),
        .cnt_o   ( free_idx ),
        .empty_o (          )
    );

    lzc #(.WIDTH(CFG.PENDING_COUNT)) i_lzc_m (
        .in_i    ( match_bmp ),
        .cnt_o   ( match_idx ),
        .empty_o (           )
    );

    logic [CFG.ID_WIDTH_RESP-1:0] hit_id;
    logic [CFG.LINE_WIDTH-1:0]    hit_data;
    logic                         hit_err;
    logic                         hit_vld, hit_rdy;

    always_comb begin
        hit_vld    = 1'b0;
        hit_id     = (CFG.ID_WIDTH_RESP'(1'b1) << in_req_id_i) & ~cancel_mask;
        hit_data   = in_req_data_i;
        hit_err    = in_req_error_i;

        alloc_idx  = free_idx;
        alloc_new  = 1'b0;
        alloc_addr = aligned_addr;
        alloc_mask = (CFG.ID_WIDTH_RESP'(1'b1) << in_req_id_i) & ~cancel_mask;
        alloc_en   = 1'b0;

        in_req_ready_o  = 1'b1;
        out_req_addr_o  = aligned_addr;
        out_req_id_o    = free_idx;
        out_req_valid_o = 1'b0;

        if (in_req_valid_i && !flush_ports_i[in_req_id_i >> 1]) begin
            if (in_req_hit_i && !flush_valid_i) begin
                hit_vld        = 1'b1;
                in_req_ready_o = hit_rdy;
            end else if (has_match) begin
                alloc_idx      = match_idx;
                alloc_en       = 1'b1;
            end else if (has_free && !flush_valid_i) begin
                out_req_addr_o  = aligned_addr;
                out_req_id_o    = free_idx;
                out_req_valid_o = 1'b1;
                in_req_ready_o  = out_req_ready_i;
                alloc_idx       = free_idx;
                alloc_new       = 1'b1;
                alloc_en        = out_req_ready_i;
            end else begin
                in_req_ready_o = 1'b0;
            end
        end
    end

    logic [CFG.SET_ALIGN-1:0] repl_way_q;
    logic repl_step;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) repl_way_q <= '0;
        else if (repl_step) repl_way_q <= repl_way_q + 1'b1;
    end

    logic wr_done_q, rsp_done_q;
    logic rsp_active, rsp_done;
    logic do_wr, do_rsp;
    logic arb_sel_q, arb_lock_q, arb_sel_d, arb_lock_d;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            arb_sel_q  <= 1'b0;
            arb_lock_q <= 1'b0;
            wr_done_q  <= 1'b0;
            rsp_done_q <= 1'b0;
        end else begin
            arb_sel_q  <= arb_sel_d;
            arb_lock_q <= arb_lock_d;
            wr_done_q  <= rsp_active & ~rsp_done & (wr_done_q  | (do_wr  & write_ready_i));
            rsp_done_q <= rsp_active & ~rsp_done & (rsp_done_q | (do_rsp & in_rsp_ready_i));
        end
    end

    always_comb begin
        ret_idx         = out_rsp_id_i;
        ret_en          = 1'b0;
        write_addr_o    = CFG.COUNT_ALIGN'(ret_addr >> CFG.LINE_ALIGN);
        write_set_o     = repl_way_q;
        write_data_o    = out_rsp_data_i;
        write_tag_o     = CFG.TAG_WIDTH'(ret_addr >> (CFG.LINE_ALIGN + CFG.COUNT_ALIGN));
        write_error_o   = 1'b0;
        write_valid_o   = 1'b0;
        in_rsp_data_o   = out_rsp_data_i;
        in_rsp_error_o  = out_rsp_error_i;
        in_rsp_id_o     = ret_mask;
        in_rsp_valid_o  = 1'b0;
        hit_rdy         = 1'b1;
        out_rsp_ready_o = 1'b1;
        repl_step       = 1'b0;
        rsp_active      = 1'b0;
        rsp_done        = 1'b1;
        do_wr           = 1'b0;
        do_rsp          = 1'b0;

        arb_sel_d  = arb_sel_q;
        arb_lock_d = arb_lock_q;
        if (!arb_lock_q) begin
            if (hit_vld) begin
                arb_sel_d  = 1'b0;
                arb_lock_d = 1'b1;
            end else if (out_rsp_valid_i) begin
                arb_sel_d  = 1'b1;
                arb_lock_d = 1'b1;
            end else begin
                arb_sel_d  = 1'b0;
                arb_lock_d = 1'b0;
            end
        end

        if (!arb_sel_d) begin
            if (hit_vld) begin
                out_rsp_ready_o = 1'b0;
                in_rsp_data_o   = hit_data;
                in_rsp_error_o  = hit_err;
                in_rsp_id_o     = hit_id;
                in_rsp_valid_o  = (hit_id != '0);
                hit_rdy         = (hit_id != '0) ? in_rsp_ready_i : 1'b1;
            end
            if (hit_rdy) arb_lock_d = 1'b0;
        end else begin
            if (out_rsp_valid_i) begin
                hit_rdy         = 1'b0;
                do_wr           = !out_rsp_error_i && !ret_stale;
                do_rsp          = (ret_mask != '0);
                rsp_active      = 1'b1;
                rsp_done        = (!do_rsp || in_rsp_ready_i || rsp_done_q) &&
                                  (!do_wr  || write_ready_i  || wr_done_q);
                write_valid_o   = do_wr  && !wr_done_q;
                in_rsp_valid_o  = do_rsp && !rsp_done_q;
                ret_en          = rsp_done;
                out_rsp_ready_o = rsp_done;
                repl_step       = rsp_done && do_wr;
            end
            if (rsp_done) arb_lock_d = 1'b0;
        end
    end

endmodule
