/*
 * Alternate Gold: ARP controller with 2-slot circular TX queue and cache-polling lookup FSM
 */
`resetall
`timescale 1ns / 1ps
`default_nettype none

module arp #
(
    parameter DATA_WIDTH = 8,
    parameter KEEP_ENABLE = (DATA_WIDTH>8),
    parameter KEEP_WIDTH = (DATA_WIDTH/8),
    parameter CACHE_ADDR_WIDTH = 9,
    parameter REQUEST_RETRY_COUNT = 4,
    parameter REQUEST_RETRY_INTERVAL = 125000000*2,
    parameter REQUEST_TIMEOUT = 125000000*30
)
(
    input  wire                   clk,
    input  wire                   rst,

    input  wire                   s_eth_hdr_valid,
    output wire                   s_eth_hdr_ready,
    input  wire [47:0]            s_eth_dest_mac,
    input  wire [47:0]            s_eth_src_mac,
    input  wire [15:0]            s_eth_type,
    input  wire [DATA_WIDTH-1:0]  s_eth_payload_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_eth_payload_axis_tkeep,
    input  wire                   s_eth_payload_axis_tvalid,
    output wire                   s_eth_payload_axis_tready,
    input  wire                   s_eth_payload_axis_tlast,
    input  wire                   s_eth_payload_axis_tuser,

    output wire                   m_eth_hdr_valid,
    input  wire                   m_eth_hdr_ready,
    output wire [47:0]            m_eth_dest_mac,
    output wire [47:0]            m_eth_src_mac,
    output wire [15:0]            m_eth_type,
    output wire [DATA_WIDTH-1:0]  m_eth_payload_axis_tdata,
    output wire [KEEP_WIDTH-1:0]  m_eth_payload_axis_tkeep,
    output wire                   m_eth_payload_axis_tvalid,
    input  wire                   m_eth_payload_axis_tready,
    output wire                   m_eth_payload_axis_tlast,
    output wire                   m_eth_payload_axis_tuser,

    input  wire                   arp_request_valid,
    output wire                   arp_request_ready,
    input  wire [31:0]            arp_request_ip,
    output wire                   arp_response_valid,
    input  wire                   arp_response_ready,
    output wire                   arp_response_error,
    output wire [47:0]            arp_response_mac,

    input  wire [47:0]            local_mac,
    input  wire [31:0]            local_ip,
    input  wire [31:0]            gateway_ip,
    input  wire [31:0]            subnet_mask,
    input  wire                   clear_cache
);

localparam [15:0]
    OP_ARP_REQ   = 16'h0001,
    OP_ARP_REP   = 16'h0002,
    OP_INARP_REQ = 16'h0008,
    OP_INARP_REP = 16'h0009;

localparam [1:0]
    ST_IDLE  = 2'd0,
    ST_FIRST = 2'd1,
    ST_WAIT  = 2'd2;

wire rx_valid;
wire rx_ready;
wire [47:0] rx_eth_dst, rx_eth_src;
wire [15:0] rx_eth_type;
wire [15:0] rx_htype, rx_ptype, rx_oper;
wire [7:0]  rx_hlen, rx_plen;
wire [47:0] rx_sha, rx_tha;
wire [31:0] rx_spa, rx_tpa;

arp_eth_rx #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(KEEP_ENABLE),
    .KEEP_WIDTH(KEEP_WIDTH)
)
rx_inst (
    .clk(clk),
    .rst(rst),
    .s_eth_hdr_valid(s_eth_hdr_valid),
    .s_eth_hdr_ready(s_eth_hdr_ready),
    .s_eth_dest_mac(s_eth_dest_mac),
    .s_eth_src_mac(s_eth_src_mac),
    .s_eth_type(s_eth_type),
    .s_eth_payload_axis_tdata(s_eth_payload_axis_tdata),
    .s_eth_payload_axis_tkeep(s_eth_payload_axis_tkeep),
    .s_eth_payload_axis_tvalid(s_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(s_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(s_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(s_eth_payload_axis_tuser),
    .m_frame_valid(rx_valid),
    .m_frame_ready(rx_ready),
    .m_eth_dest_mac(rx_eth_dst),
    .m_eth_src_mac(rx_eth_src),
    .m_eth_type(rx_eth_type),
    .m_arp_htype(rx_htype),
    .m_arp_ptype(rx_ptype),
    .m_arp_hlen(rx_hlen),
    .m_arp_plen(rx_plen),
    .m_arp_oper(rx_oper),
    .m_arp_sha(rx_sha),
    .m_arp_spa(rx_spa),
    .m_arp_tha(rx_tha),
    .m_arp_tpa(rx_tpa),
    .busy(),
    .error_header_early_termination(),
    .error_invalid_header()
);

// 2-entry circular TX frame queue
reg [47:0] txq_dst  [0:1];
reg [15:0] txq_oper [0:1];
reg [47:0] txq_tha  [0:1];
reg [31:0] txq_tpa  [0:1];
reg [1:0]  txq_wptr, txq_rptr;
reg        bcast_req_deferred;
reg [31:0] bcast_req_ip;

wire tx_valid = (txq_wptr != txq_rptr);
wire tx_ready;
wire [1:0] txq_cnt = txq_wptr - txq_rptr;

arp_eth_tx #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(KEEP_ENABLE),
    .KEEP_WIDTH(KEEP_WIDTH)
)
tx_inst (
    .clk(clk),
    .rst(rst),
    .s_frame_valid(tx_valid),
    .s_frame_ready(tx_ready),
    .s_eth_dest_mac(txq_dst[txq_rptr[0]]),
    .s_eth_src_mac(local_mac),
    .s_eth_type(16'h0806),
    .s_arp_htype(16'h0001),
    .s_arp_ptype(16'h0800),
    .s_arp_oper(txq_oper[txq_rptr[0]]),
    .s_arp_sha(local_mac),
    .s_arp_spa(local_ip),
    .s_arp_tha(txq_tha[txq_rptr[0]]),
    .s_arp_tpa(txq_tpa[txq_rptr[0]]),
    .m_eth_hdr_valid(m_eth_hdr_valid),
    .m_eth_hdr_ready(m_eth_hdr_ready),
    .m_eth_dest_mac(m_eth_dest_mac),
    .m_eth_src_mac(m_eth_src_mac),
    .m_eth_type(m_eth_type),
    .m_eth_payload_axis_tdata(m_eth_payload_axis_tdata),
    .m_eth_payload_axis_tkeep(m_eth_payload_axis_tkeep),
    .m_eth_payload_axis_tvalid(m_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(m_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(m_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(m_eth_payload_axis_tuser),
    .busy()
);

reg        cq_valid_r;
wire       cq_ready;
reg [31:0] cq_ip_r;
wire       cr_valid;
wire       cr_error;
wire [47:0] cr_mac;

reg        cw_valid_r;
wire       cw_ready;
reg [31:0] cw_ip_r;
reg [47:0] cw_mac_r;

arp_cache #(
    .CACHE_ADDR_WIDTH(CACHE_ADDR_WIDTH)
)
cache_inst (
    .clk(clk),
    .rst(rst),
    .query_request_valid(cq_valid_r),
    .query_request_ready(cq_ready),
    .query_request_ip(cq_ip_r),
    .query_response_valid(cr_valid),
    .query_response_ready(1'b1),
    .query_response_error(cr_error),
    .query_response_mac(cr_mac),
    .write_request_valid(cw_valid_r),
    .write_request_ready(cw_ready),
    .write_request_ip(cw_ip_r),
    .write_request_mac(cw_mac_r),
    .clear_cache(clear_cache)
);

reg [1:0]  st_r;
reg        lkp_q_sent_r;
reg        lkp_q_wait_r;
reg [31:0] tgt_ip_r;
reg [5:0]  retries_r;
reg [35:0] timer_r;
reg        hit_latched_r;
reg [47:0] hit_mac_r;

reg        req_ready_r;
reg        resp_valid_r, resp_err_r;
reg [47:0] resp_mac_r;

reg        prb_pend_r, prb_wait_r;
reg [31:0] prb_ip_r;
reg [47:0] prb_mac_r;

reg        cq_is_prb_r;
reg [3:0]  tag_q_r;
reg [1:0]  tag_wptr_r, tag_rptr_r;

assign arp_request_ready  = req_ready_r;
assign arp_response_valid = resp_valid_r;
assign arp_response_error = resp_err_r;
assign arp_response_mac   = resp_mac_r;

wire rx_ok = (rx_eth_type == 16'h0806) && (rx_htype == 16'h0001) && (rx_ptype == 16'h0800) &&
             ((rx_oper == OP_ARP_REQ) || (rx_oper == OP_ARP_REP) ||
              (rx_oper == OP_INARP_REQ) || (rx_oper == OP_INARP_REP));
wire rx_sha_ok = (rx_sha != 48'd0) && !rx_sha[40];
wire rx_spa_ok = (rx_spa != 32'd0) && (rx_spa != 32'hFFFF_FFFF) && (rx_spa[31:28] != 4'hE);

wire rx_arp_rep   = rx_ok && rx_sha_ok && (rx_oper == OP_ARP_REQ)   && (rx_tpa == local_ip);
wire rx_inarp_rep = rx_ok && rx_sha_ok && (rx_oper == OP_INARP_REQ) && (rx_tha == local_mac);
wire rx_need_rep  = rx_arp_rep || rx_inarp_rep;

wire rx_for_us = (((rx_oper == OP_ARP_REQ) || (rx_oper == OP_ARP_REP)) && (rx_tpa == local_ip)) ||
                 (((rx_oper == OP_INARP_REQ) || (rx_oper == OP_INARP_REP)) && (rx_tha == local_mac));

wire pop_txq = tx_valid && tx_ready;
wire [1:0] txq_after_pop = txq_cnt - (pop_txq ? 2'd1 : 2'd0);
wire cw_busy_after = cw_valid_r && !cw_ready;
wire prb_done_now  = cr_valid && tag_q_r[tag_rptr_r] && prb_wait_r;
wire prb_wr_now    = prb_done_now && !cr_error;

assign rx_ready = !prb_pend_r && !prb_wait_r && !cw_busy_after && !prb_wr_now &&
                  (!rx_need_rep || (txq_after_pop < 2'd2));

wire rx_fire = rx_valid && rx_ready;
wire rx_direct_match = rx_fire && rx_ok && rx_sha_ok && rx_spa_ok &&
                       (rx_for_us || ((st_r != ST_IDLE) && (rx_spa == tgt_ip_r)));
wire rx_wakes_tgt = (st_r != ST_IDLE) && rx_fire && rx_ok && rx_sha_ok && rx_spa_ok && (rx_spa == tgt_ip_r);
wire cr_lkp_done  = cr_valid && !tag_q_r[tag_rptr_r];

always @(posedge clk) begin
    if (rst) begin
        st_r <= ST_IDLE;
        lkp_q_sent_r <= 1'b0;
        lkp_q_wait_r <= 1'b0;
        tgt_ip_r <= 32'd0;
        retries_r <= 6'd0;
        timer_r <= 36'd0;
        hit_latched_r <= 1'b0;
        hit_mac_r <= 48'd0;
        req_ready_r <= 1'b0;
        resp_valid_r <= 1'b0;
        resp_err_r <= 1'b0;
        resp_mac_r <= 48'd0;
        prb_pend_r <= 1'b0;
        prb_wait_r <= 1'b0;
        prb_ip_r <= 32'd0;
        prb_mac_r <= 48'd0;
        cq_valid_r <= 1'b0;
        cq_ip_r <= 32'd0;
        cq_is_prb_r <= 1'b0;
        tag_q_r <= 4'd0;
        tag_wptr_r <= 2'd0;
        tag_rptr_r <= 2'd0;
        cw_valid_r <= 1'b0;
        cw_ip_r <= 32'd0;
        cw_mac_r <= 48'd0;
        txq_wptr <= 2'd0;
        txq_rptr <= 2'd0;
        txq_dst[0] <= 48'd0; txq_dst[1] <= 48'd0;
        txq_oper[0] <= 16'd0; txq_oper[1] <= 16'd0;
        txq_tha[0] <= 48'd0; txq_tha[1] <= 48'd0;
        txq_tpa[0] <= 32'd0; txq_tpa[1] <= 32'd0;
        bcast_req_deferred <= 1'b0;
        bcast_req_ip <= 32'd0;
    end else begin : seq_blk
        reg want_bcast;
        reg [31:0] want_bcast_ip;
        reg pushed_rep;
        reg next_resp_v;
        reg [1:0] next_st;
        reg next_cw_v;

        want_bcast = bcast_req_deferred;
        want_bcast_ip = bcast_req_ip;
        pushed_rep = 1'b0;
        next_resp_v = resp_valid_r && !arp_response_ready;
        next_st = st_r;
        next_cw_v = cw_busy_after;

        if (pop_txq) txq_rptr <= txq_rptr + 2'd1;
        if (cw_valid_r && cw_ready) cw_valid_r <= 1'b0;

        if (cq_valid_r && cq_ready) begin
            cq_valid_r <= 1'b0;
            tag_q_r[tag_wptr_r] <= cq_is_prb_r;
            tag_wptr_r <= tag_wptr_r + 2'd1;
        end

        if (cr_valid) begin
            tag_rptr_r <= tag_rptr_r + 2'd1;
            if (tag_q_r[tag_rptr_r] && prb_wait_r) begin
                prb_wait_r <= 1'b0;
                if (!cr_error) begin
                    cw_valid_r <= 1'b1;
                    cw_ip_r <= prb_ip_r;
                    cw_mac_r <= prb_mac_r;
                    next_cw_v = 1'b1;
                end
            end else if (!tag_q_r[tag_rptr_r]) begin
                lkp_q_wait_r <= 1'b0;
            end
        end

        if (rx_fire) begin
            if (rx_need_rep) begin
                txq_dst[txq_wptr[0]]  <= rx_eth_src;
                txq_oper[txq_wptr[0]] <= rx_arp_rep ? OP_ARP_REP : OP_INARP_REP;
                txq_tha[txq_wptr[0]]  <= rx_sha;
                txq_tpa[txq_wptr[0]]  <= rx_spa;
                txq_wptr <= txq_wptr + 2'd1;
                pushed_rep = 1'b1;
            end
            if (rx_ok && rx_sha_ok && rx_spa_ok) begin
                if (rx_direct_match) begin
                    cw_valid_r <= 1'b1;
                    cw_ip_r <= rx_spa;
                    cw_mac_r <= rx_sha;
                    next_cw_v = 1'b1;
                    if (rx_wakes_tgt) begin
                        hit_latched_r <= 1'b1;
                        hit_mac_r <= rx_sha;
                    end
                end else begin
                    prb_pend_r <= 1'b1;
                    prb_ip_r <= rx_spa;
                    prb_mac_r <= rx_sha;
                end
            end
        end

        case (st_r)
            ST_IDLE: begin
                if (arp_request_valid && arp_request_ready) begin
                    hit_latched_r <= 1'b0;
                    lkp_q_sent_r <= 1'b0;
                    lkp_q_wait_r <= 1'b0;
                    if ((arp_request_ip == 32'hFFFF_FFFF) ||
                        ((subnet_mask != 32'hFFFF_FFFF) &&
                         (((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0) &&
                         ((arp_request_ip | subnet_mask) == 32'hFFFF_FFFF))) begin
                        next_resp_v = 1'b1;
                        resp_err_r <= 1'b0;
                        resp_mac_r <= 48'hFFFF_FFFF_FFFF;
                    end else if (arp_request_ip[31:28] == 4'hE) begin
                        next_resp_v = 1'b1;
                        resp_err_r <= 1'b0;
                        resp_mac_r <= {24'h01_00_5E, 1'b0, arp_request_ip[22:0]};
                    end else if (((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0) begin
                        tgt_ip_r <= arp_request_ip;
                        next_st = ST_FIRST;
                    end else if (gateway_ip == 32'd0) begin
                        next_resp_v = 1'b1;
                        resp_err_r <= 1'b1;
                        resp_mac_r <= 48'd0;
                    end else begin
                        tgt_ip_r <= gateway_ip;
                        next_st = ST_FIRST;
                    end
                end
            end

            ST_FIRST: begin
                if ((hit_latched_r || rx_wakes_tgt) && !lkp_q_sent_r && !next_resp_v) begin
                    next_resp_v = 1'b1;
                    resp_err_r <= 1'b0;
                    resp_mac_r <= rx_wakes_tgt ? rx_sha : hit_mac_r;
                    hit_latched_r <= 1'b0;
                    next_st = ST_IDLE;
                end else if (cr_lkp_done) begin
                    if (hit_latched_r || rx_wakes_tgt || !cr_error) begin
                        next_resp_v = 1'b1;
                        resp_err_r <= 1'b0;
                        resp_mac_r <= rx_wakes_tgt ? rx_sha : (hit_latched_r ? hit_mac_r : cr_mac);
                        hit_latched_r <= 1'b0;
                        next_st = ST_IDLE;
                    end else begin
                        want_bcast = 1'b1;
                        want_bcast_ip = tgt_ip_r;
                        lkp_q_sent_r <= 1'b0;
                        if (REQUEST_RETRY_COUNT > 1) begin
                            retries_r <= REQUEST_RETRY_COUNT - 1;
                            timer_r <= REQUEST_RETRY_INTERVAL;
                        end else begin
                            retries_r <= 6'd0;
                            timer_r <= REQUEST_TIMEOUT;
                        end
                        next_st = ST_WAIT;
                    end
                end
            end

            ST_WAIT: begin
                if (hit_latched_r || rx_wakes_tgt || (cr_lkp_done && !cr_error)) begin
                    if (!next_resp_v) begin
                        next_resp_v = 1'b1;
                        resp_err_r <= 1'b0;
                        resp_mac_r <= rx_wakes_tgt ? rx_sha : (hit_latched_r ? hit_mac_r : cr_mac);
                        hit_latched_r <= 1'b0;
                        want_bcast = 1'b0;
                        next_st = ST_IDLE;
                    end
                end else if (timer_r == 36'd0) begin
                    if (retries_r > 6'd0) begin
                        want_bcast = 1'b1;
                        want_bcast_ip = tgt_ip_r;
                        retries_r <= retries_r - 6'd1;
                        timer_r <= (retries_r > 6'd1) ? REQUEST_RETRY_INTERVAL : REQUEST_TIMEOUT;
                    end else if (!next_resp_v) begin
                        next_resp_v = 1'b1;
                        resp_err_r <= 1'b1;
                        resp_mac_r <= 48'd0;
                        want_bcast = 1'b0;
                        next_st = ST_IDLE;
                    end
                end else begin
                    timer_r <= timer_r - 36'd1;
                end
            end
        endcase

        if (!(cq_valid_r && !cq_ready) && !next_cw_v) begin
            if (prb_pend_r) begin
                cq_valid_r <= 1'b1;
                cq_ip_r <= prb_ip_r;
                cq_is_prb_r <= 1'b1;
                prb_pend_r <= 1'b0;
                prb_wait_r <= 1'b1;
            end else if ((st_r == ST_FIRST) && (next_st == ST_FIRST) && !lkp_q_sent_r) begin
                cq_valid_r <= 1'b1;
                cq_ip_r <= tgt_ip_r;
                cq_is_prb_r <= 1'b0;
                lkp_q_sent_r <= 1'b1;
                lkp_q_wait_r <= 1'b1;
            end else if ((st_r == ST_WAIT) && (next_st == ST_WAIT) && !lkp_q_wait_r && !prb_wait_r) begin
                cq_valid_r <= 1'b1;
                cq_ip_r <= tgt_ip_r;
                cq_is_prb_r <= 1'b0;
                lkp_q_wait_r <= 1'b1;
            end
        end

        if (want_bcast) begin
            if (!pushed_rep && (txq_after_pop < 2'd2)) begin
                txq_dst[txq_wptr[0]]  <= 48'hFFFF_FFFF_FFFF;
                txq_oper[txq_wptr[0]] <= OP_ARP_REQ;
                txq_tha[txq_wptr[0]]  <= 48'd0;
                txq_tpa[txq_wptr[0]]  <= want_bcast_ip;
                txq_wptr <= txq_wptr + 2'd1;
                bcast_req_deferred <= 1'b0;
            end else begin
                bcast_req_deferred <= 1'b1;
                bcast_req_ip <= want_bcast_ip;
            end
        end else begin
            bcast_req_deferred <= 1'b0;
        end

        resp_valid_r <= next_resp_v;
        st_r <= next_st;
        req_ready_r <= (next_st == ST_IDLE) && !next_resp_v && !next_cw_v && !lkp_q_wait_r &&
                       !(cq_valid_r && !cq_ready && !cq_is_prb_r) && !clear_cache;
    end
end

endmodule

`resetall
