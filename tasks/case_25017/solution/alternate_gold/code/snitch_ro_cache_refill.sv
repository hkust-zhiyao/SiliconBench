// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Cache line refill engine with beat-tracked error aggregation (alt_gold_1).
module snitch_ro_cache_refill #(
    parameter snitch_icache_pkg::config_t CFG = '0,
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic [CFG.FETCH_AW-1:0]     in_req_addr_i,
    input  logic [CFG.PENDING_IW-1:0]   in_req_id_i,
    input  logic                        in_req_bypass_i,
    input  logic                        in_req_valid_i,
    output logic                        in_req_ready_o,

    output logic [CFG.LINE_WIDTH-1:0]   in_rsp_data_o,
    output logic                        in_rsp_error_o,
    output logic [CFG.PENDING_IW-1:0]   in_rsp_id_o,
    output logic                        in_rsp_bypass_o,
    output logic                        in_rsp_valid_o,
    input  logic                        in_rsp_ready_i,

    output axi_req_t                    axi_req_o,
    input  axi_rsp_t                    axi_rsp_i
);

    localparam int unsigned BeatsPerRefill =
      CFG.LINE_WIDTH >= CFG.FILL_DW ? CFG.LINE_WIDTH/CFG.FILL_DW : 1;
    localparam int unsigned TransactionQueueDepth = 4;

    logic queue_full, queue_push, queue_pop;
    logic sticky_err_q;

    fifo_v3 #(
        .DEPTH      ( TransactionQueueDepth ),
        .DATA_WIDTH ( CFG.PENDING_IW+1 )
    ) i_fifo_id_queue (
        .clk_i      ( clk_i                          ),
        .rst_ni     ( rst_ni                         ),
        .flush_i    ( 1'b0                           ),
        .testmode_i ( 1'b0                           ),
        .full_o     ( queue_full                     ),
        .empty_o    (                                ),
        .usage_o    (                                ),
        .data_i     ( {in_req_bypass_i, in_req_id_i} ),
        .push_i     ( queue_push                     ),
        .data_o     ( {in_rsp_bypass_o, in_rsp_id_o} ),
        .pop_i      ( queue_pop                      )
    );

    assign in_req_ready_o = axi_rsp_i.ar_ready & ~queue_full;
    assign queue_push     = axi_req_o.ar_valid & axi_rsp_i.ar_ready;

    logic [CFG.LINE_WIDTH-1:0] response_data;
    if (CFG.LINE_WIDTH > CFG.FILL_DW) begin : g_data_concat
        logic [CFG.LINE_WIDTH-CFG.FILL_DW-1:0] shift_buf_q;
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                shift_buf_q <= '0;
            end else if (axi_rsp_i.r_valid && axi_req_o.r_ready) begin
                shift_buf_q <= response_data[CFG.LINE_WIDTH-1:CFG.FILL_DW];
            end
        end
        assign response_data = {axi_rsp_i.r.data, shift_buf_q};
    end else begin : g_data_passthrough
        assign response_data = axi_rsp_i.r.data[CFG.LINE_WIDTH-1:0];
    end

    wire beat_err = (axi_rsp_i.r.resp == axi_pkg::RESP_SLVERR) ||
                    (axi_rsp_i.r.resp == axi_pkg::RESP_DECERR);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            sticky_err_q <= 1'b0;
        end else if (axi_rsp_i.r_valid && axi_req_o.r_ready) begin
            sticky_err_q <= axi_rsp_i.r.last ? 1'b0 : (sticky_err_q | beat_err);
        end
    end

    always_comb begin : p_response
        axi_req_o          = '0;
        axi_req_o.b_ready  = 1'b1;
        axi_req_o.ar.addr  = {in_req_addr_i[CFG.FETCH_AW-1:CFG.LINE_ALIGN], {CFG.LINE_ALIGN{1'b0}}};
        axi_req_o.ar.size  = $clog2(CFG.FILL_DW/8);
        axi_req_o.ar.burst = axi_pkg::BURST_INCR;
        axi_req_o.ar.len   = $unsigned(BeatsPerRefill - 1);
        axi_req_o.ar.cache = axi_pkg::CACHE_MODIFIABLE;
        axi_req_o.ar_valid = in_req_valid_i & ~queue_full;

        in_rsp_data_o     = response_data;
        in_rsp_error_o    = sticky_err_q | beat_err;
        in_rsp_valid_o    = 1'b0;
        queue_pop         = 1'b0;
        axi_req_o.r_ready = 1'b0;

        if (axi_rsp_i.r_valid) begin
            if (!axi_rsp_i.r.last) begin
                axi_req_o.r_ready = 1'b1;
            end else begin
                in_rsp_valid_o = 1'b1;
                if (in_rsp_ready_i) begin
                    axi_req_o.r_ready = 1'b1;
                    queue_pop         = 1'b1;
                end
            end
        end
    end

endmodule
