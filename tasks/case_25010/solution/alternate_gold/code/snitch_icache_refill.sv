// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module snitch_icache_refill #(
    parameter snitch_icache_pkg::config_t CFG = '0,
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic [CFG.FETCH_AW-1:0]   in_req_addr_i,
    input  logic [CFG.PENDING_IW-1:0] in_req_id_i,
    input  logic                      in_req_bypass_i,
    input  logic                      in_req_valid_i,
    output logic                      in_req_ready_o,

    output logic [CFG.LINE_WIDTH-1:0] in_rsp_data_o,
    output logic                      in_rsp_error_o,
    output logic [CFG.PENDING_IW-1:0] in_rsp_id_o,
    output logic                      in_rsp_bypass_o,
    output logic                      in_rsp_valid_o,
    input  logic                      in_rsp_ready_i,

    output axi_req_t axi_req_o,
    input  axi_rsp_t axi_rsp_i
);

    `ifndef SYNTHESIS
    initial assert(CFG != '0);
    `endif

    localparam int unsigned BeatsPerRefill =
        CFG.LINE_WIDTH >= CFG.FILL_DW ? CFG.LINE_WIDTH / CFG.FILL_DW : 1;
    localparam logic [CFG.FETCH_AW-1:0] LineAlignMask =
        ~((CFG.FETCH_AW'(1) << CFG.LINE_ALIGN) - 1'b1);

    localparam int unsigned QueueDepth = 4;

    typedef struct packed {
        logic                      bypass;
        logic [CFG.PENDING_IW-1:0] id;
    } queue_item_t;

    logic queue_full, queue_empty;
    logic queue_push, queue_pop;
    logic r_ready_int;
    queue_item_t queue_in, queue_out;

    always_comb begin
        axi_req_o           = '0;
        axi_req_o.b_ready   = 1'b1;
        axi_req_o.ar.id     = 1'b0;
        axi_req_o.ar.addr   = in_req_addr_i & LineAlignMask;
        axi_req_o.ar.size   = $clog2(CFG.FILL_DW / 8);
        axi_req_o.ar.len    = BeatsPerRefill - 1;
        axi_req_o.ar.burst  = axi_pkg::BURST_INCR;
        axi_req_o.ar.cache  = in_req_bypass_i ? 4'b0000 : axi_pkg::CACHE_MODIFIABLE;
        axi_req_o.ar_valid  = in_req_valid_i & ~queue_full;
        axi_req_o.r_ready   = r_ready_int;
        in_req_ready_o      = axi_rsp_i.ar_ready & ~queue_full;
        queue_push          = axi_req_o.ar_valid & axi_rsp_i.ar_ready;
    end

    assign queue_in.id     = in_req_id_i;
    assign queue_in.bypass = in_req_bypass_i;

    fifo_v3 #(
        .DEPTH ( QueueDepth   ),
        .dtype ( queue_item_t )
    ) i_fifo_transaction_queue (
        .clk_i      ( clk_i       ),
        .rst_ni     ( rst_ni      ),
        .flush_i    ( 1'b0        ),
        .testmode_i ( 1'b0        ),
        .full_o     ( queue_full  ),
        .empty_o    ( queue_empty ),
        .usage_o    (             ),
        .data_i     ( queue_in    ),
        .push_i     ( queue_push  ),
        .data_o     ( queue_out   ),
        .pop_i      ( queue_pop   )
    );

    typedef struct packed {
        logic [CFG.LINE_WIDTH-1:0] data;
        logic                      error;
        logic [CFG.PENDING_IW-1:0] id;
        logic                      bypass;
    } rsp_pkt_t;

    logic rsp_fifo_pop, rsp_fifo_push;
    logic rsp_fifo_full, rsp_fifo_empty;
    rsp_pkt_t rsp_pkt_in, rsp_pkt_out;

    assign in_rsp_data_o   = rsp_pkt_out.data;
    assign in_rsp_error_o  = rsp_pkt_out.error;
    assign in_rsp_id_o     = rsp_pkt_out.id;
    assign in_rsp_bypass_o = rsp_pkt_out.bypass;

    fifo_v3 #(
        .DEPTH ( CFG.PENDING_COUNT ),
        .dtype ( rsp_pkt_t         )
    ) i_fifo_response_buf (
        .clk_i      ( clk_i          ),
        .rst_ni     ( rst_ni         ),
        .flush_i    ( 1'b0           ),
        .testmode_i ( 1'b0           ),
        .full_o     ( rsp_fifo_full  ),
        .empty_o    ( rsp_fifo_empty ),
        .usage_o    (                ),
        .data_i     ( rsp_pkt_in     ),
        .push_i     ( rsp_fifo_push  ),
        .data_o     ( rsp_pkt_out    ),
        .pop_i      ( rsp_fifo_pop   )
    );

    if (BeatsPerRefill == 1) begin : g_single_beat
        always_comb begin
            r_ready_int       = ~rsp_fifo_full;
            rsp_pkt_in.data   = axi_rsp_i.r.data[CFG.LINE_WIDTH-1:0];
            rsp_pkt_in.error  = axi_rsp_i.r.resp[1];
            rsp_pkt_in.id     = queue_out.id;
            rsp_pkt_in.bypass = queue_out.bypass;
            rsp_fifo_push     = axi_rsp_i.r_valid & ~rsp_fifo_full;
            queue_pop         = axi_rsp_i.r_valid & r_ready_int & axi_rsp_i.r.last;
            in_rsp_valid_o    = ~rsp_fifo_empty;
            rsp_fifo_pop      = in_rsp_valid_o & in_rsp_ready_i;
        end
    end else begin : g_multi_beat
        localparam int unsigned CntW = $clog2(BeatsPerRefill);
        logic [CFG.LINE_WIDTH-CFG.FILL_DW-1:0] accum_data_q;
        logic                                  err_sticky_q;
        logic [CntW-1:0]                       beat_idx_q;

        wire beat_fire = axi_rsp_i.r_valid & r_ready_int;

        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                accum_data_q <= '0;
                err_sticky_q <= 1'b0;
                beat_idx_q   <= '0;
            end else if (beat_fire) begin
                if (axi_rsp_i.r.last) begin
                    err_sticky_q <= 1'b0;
                    beat_idx_q   <= '0;
                end else begin
                    accum_data_q[beat_idx_q * CFG.FILL_DW +: CFG.FILL_DW] <= axi_rsp_i.r.data;
                    err_sticky_q <= err_sticky_q | axi_rsp_i.r.resp[1];
                    beat_idx_q   <= beat_idx_q + 1'b1;
                end
            end
        end

        always_comb begin
            r_ready_int       = ~axi_rsp_i.r.last | ~rsp_fifo_full;
            rsp_pkt_in.data   = {axi_rsp_i.r.data, accum_data_q};
            rsp_pkt_in.error  = err_sticky_q | axi_rsp_i.r.resp[1];
            rsp_pkt_in.id     = queue_out.id;
            rsp_pkt_in.bypass = queue_out.bypass;
            rsp_fifo_push     = axi_rsp_i.r_valid & axi_rsp_i.r.last & ~rsp_fifo_full;
            queue_pop         = beat_fire & axi_rsp_i.r.last;
            in_rsp_valid_o    = ~rsp_fifo_empty;
            rsp_fifo_pop      = in_rsp_valid_o & in_rsp_ready_i;
        end
    end

endmodule
