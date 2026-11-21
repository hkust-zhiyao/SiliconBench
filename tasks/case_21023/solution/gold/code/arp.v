/*

Copyright (c) 2014-2020 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ARP block for IPv4, ethernet frame interface
 */
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

    /*
     * Ethernet frame input
     */
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

    /*
     * Ethernet frame output
     */
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

    /*
     * ARP requests
     */
    input  wire                   arp_request_valid,
    output wire                   arp_request_ready,
    input  wire [31:0]            arp_request_ip,
    output wire                   arp_response_valid,
    input  wire                   arp_response_ready,
    output wire                   arp_response_error,
    output wire [47:0]            arp_response_mac,

    /*
     * Configuration
     */
    input  wire [47:0]            local_mac,
    input  wire [31:0]            local_ip,
    input  wire [31:0]            gateway_ip,
    input  wire [31:0]            subnet_mask,
    input  wire                   clear_cache
);

localparam [15:0]
    ARP_OPER_ARP_REQUEST = 16'h0001,
    ARP_OPER_ARP_REPLY = 16'h0002,
    ARP_OPER_INARP_REQUEST = 16'h0008,
    ARP_OPER_INARP_REPLY = 16'h0009;

localparam [1:0]
    LKP_IDLE       = 2'd0,
    LKP_INIT_QUERY = 2'd1,
    LKP_INIT_WAIT  = 2'd2,
    LKP_WAIT_REPLY = 2'd3;

localparam [1:0]
    MRG_IDLE = 2'd0,
    MRG_REQ  = 2'd1,
    MRG_WAIT = 2'd2;

wire incoming_frame_valid;
reg  incoming_frame_ready;
wire [47:0] incoming_eth_dest_mac;
wire [47:0] incoming_eth_src_mac;
wire [15:0] incoming_eth_type;
wire [15:0] incoming_arp_htype;
wire [15:0] incoming_arp_ptype;
wire [7:0]  incoming_arp_hlen;
wire [7:0]  incoming_arp_plen;
wire [15:0] incoming_arp_oper;
wire [47:0] incoming_arp_sha;
wire [31:0] incoming_arp_spa;
wire [47:0] incoming_arp_tha;
wire [31:0] incoming_arp_tpa;

arp_eth_rx #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(KEEP_ENABLE),
    .KEEP_WIDTH(KEEP_WIDTH)
)
arp_eth_rx_inst (
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
    .m_frame_valid(incoming_frame_valid),
    .m_frame_ready(incoming_frame_ready),
    .m_eth_dest_mac(incoming_eth_dest_mac),
    .m_eth_src_mac(incoming_eth_src_mac),
    .m_eth_type(incoming_eth_type),
    .m_arp_htype(incoming_arp_htype),
    .m_arp_ptype(incoming_arp_ptype),
    .m_arp_hlen(incoming_arp_hlen),
    .m_arp_plen(incoming_arp_plen),
    .m_arp_oper(incoming_arp_oper),
    .m_arp_sha(incoming_arp_sha),
    .m_arp_spa(incoming_arp_spa),
    .m_arp_tha(incoming_arp_tha),
    .m_arp_tpa(incoming_arp_tpa),
    .busy(),
    .error_header_early_termination(),
    .error_invalid_header()
);

reg outgoing_frame_valid_reg = 1'b0, outgoing_frame_valid_next;
wire outgoing_frame_ready;
reg [47:0] outgoing_eth_dest_mac_reg = 48'd0, outgoing_eth_dest_mac_next;
reg [15:0] outgoing_arp_oper_reg = 16'd0, outgoing_arp_oper_next;
reg [47:0] outgoing_arp_tha_reg = 48'd0, outgoing_arp_tha_next;
reg [31:0] outgoing_arp_tpa_reg = 32'd0, outgoing_arp_tpa_next;

arp_eth_tx #(
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(KEEP_ENABLE),
    .KEEP_WIDTH(KEEP_WIDTH)
)
arp_eth_tx_inst (
    .clk(clk),
    .rst(rst),
    .s_frame_valid(outgoing_frame_valid_reg),
    .s_frame_ready(outgoing_frame_ready),
    .s_eth_dest_mac(outgoing_eth_dest_mac_reg),
    .s_eth_src_mac(local_mac),
    .s_eth_type(16'h0806),
    .s_arp_htype(16'h0001),
    .s_arp_ptype(16'h0800),
    .s_arp_oper(outgoing_arp_oper_reg),
    .s_arp_sha(local_mac),
    .s_arp_spa(local_ip),
    .s_arp_tha(outgoing_arp_tha_reg),
    .s_arp_tpa(outgoing_arp_tpa_reg),
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

reg        cache_query_request_valid_reg = 1'b0, cache_query_request_valid_next;
wire       cache_query_request_ready;
reg [31:0] cache_query_request_ip_reg = 32'd0, cache_query_request_ip_next;
wire       cache_query_response_valid;
wire       cache_query_response_error;
wire [47:0] cache_query_response_mac;

reg        cache_write_request_valid_reg = 1'b0, cache_write_request_valid_next;
wire       cache_write_request_ready;
reg [31:0] cache_write_request_ip_reg = 32'd0, cache_write_request_ip_next;
reg [47:0] cache_write_request_mac_reg = 48'd0, cache_write_request_mac_next;

arp_cache #(
    .CACHE_ADDR_WIDTH(CACHE_ADDR_WIDTH)
)
arp_cache_inst (
    .clk(clk),
    .rst(rst),
    .query_request_valid(cache_query_request_valid_reg),
    .query_request_ready(cache_query_request_ready),
    .query_request_ip(cache_query_request_ip_reg),
    .query_response_valid(cache_query_response_valid),
    .query_response_ready(1'b1),
    .query_response_error(cache_query_response_error),
    .query_response_mac(cache_query_response_mac),
    .write_request_valid(cache_write_request_valid_reg),
    .write_request_ready(cache_write_request_ready),
    .write_request_ip(cache_write_request_ip_reg),
    .write_request_mac(cache_write_request_mac_reg),
    .clear_cache(clear_cache)
);

reg [1:0]  lkp_state_reg = LKP_IDLE, lkp_state_next;
reg        arp_request_ready_reg = 1'b0, arp_request_ready_next;
reg [31:0] arp_request_ip_reg = 32'd0, arp_request_ip_next;

reg        arp_response_valid_reg = 1'b0, arp_response_valid_next;
reg        arp_response_error_reg = 1'b0, arp_response_error_next;
reg [47:0] arp_response_mac_reg = 48'd0, arp_response_mac_next;

reg [5:0]  arp_request_retry_cnt_reg = 6'd0, arp_request_retry_cnt_next;
reg [35:0] arp_request_timer_reg = 36'd0, arp_request_timer_next;

reg        lkp_wakeup_valid_reg = 1'b0, lkp_wakeup_valid_next;
reg [47:0] lkp_wakeup_mac_reg = 48'd0, lkp_wakeup_mac_next;

reg [1:0]  mrg_state_reg = MRG_IDLE, mrg_state_next;
reg [31:0] mrg_ip_reg = 32'd0, mrg_ip_next;
reg [47:0] mrg_mac_reg = 48'd0, mrg_mac_next;

reg [3:0]  q_tag_mem_reg = 4'd0, q_tag_mem_next;
reg [1:0]  q_wr_ptr_reg = 2'd0, q_wr_ptr_next;
reg [1:0]  q_rd_ptr_reg = 2'd0, q_rd_ptr_next;
reg        cur_q_is_mrg_reg = 1'b0, cur_q_is_mrg_next;

reg        reply_pending_reg = 1'b0, reply_pending_next;
reg [47:0] reply_eth_dest_reg = 48'd0, reply_eth_dest_next;
reg [15:0] reply_oper_reg = 16'd0, reply_oper_next;
reg [47:0] reply_tha_reg = 48'd0, reply_tha_next;
reg [31:0] reply_tpa_reg = 32'd0, reply_tpa_next;

reg        req_tx_pending_reg = 1'b0, req_tx_pending_next;
reg [31:0] req_tx_ip_reg = 32'd0, req_tx_ip_next;

assign arp_request_ready = arp_request_ready_reg;
assign arp_response_valid = arp_response_valid_reg;
assign arp_response_error = arp_response_error_reg;
assign arp_response_mac = arp_response_mac_reg;

wire in_proto_ok = (incoming_eth_type == 16'h0806) &&
                   (incoming_arp_htype == 16'h0001) &&
                   (incoming_arp_ptype == 16'h0800) &&
                   ((incoming_arp_oper == ARP_OPER_ARP_REQUEST) ||
                    (incoming_arp_oper == ARP_OPER_ARP_REPLY) ||
                    (incoming_arp_oper == ARP_OPER_INARP_REQUEST) ||
                    (incoming_arp_oper == ARP_OPER_INARP_REPLY));

wire in_sha_valid = (incoming_arp_sha != 48'd0) && !incoming_arp_sha[40];
wire in_spa_valid = (incoming_arp_spa != 32'd0) &&
                    (incoming_arp_spa != 32'hFFFF_FFFF) &&
                    (incoming_arp_spa[31:28] != 4'hE);

wire in_need_arp_reply   = in_proto_ok && in_sha_valid && (incoming_arp_oper == ARP_OPER_ARP_REQUEST) && (incoming_arp_tpa == local_ip);
wire in_need_inarp_reply = in_proto_ok && in_sha_valid && (incoming_arp_oper == ARP_OPER_INARP_REQUEST) && (incoming_arp_tha == local_mac);
wire in_need_reply       = in_need_arp_reply || in_need_inarp_reply;

wire in_targeted = (((incoming_arp_oper == ARP_OPER_ARP_REQUEST) || (incoming_arp_oper == ARP_OPER_ARP_REPLY)) && (incoming_arp_tpa == local_ip)) ||
                   (((incoming_arp_oper == ARP_OPER_INARP_REQUEST) || (incoming_arp_oper == ARP_OPER_INARP_REPLY)) && (incoming_arp_tha == local_mac));

wire tx_port_free = !outgoing_frame_valid_reg || outgoing_frame_ready;
wire wr_port_free = !cache_write_request_valid_reg || cache_write_request_ready;
wire q_port_free  = !cache_query_request_valid_reg || cache_query_request_ready;

wire resp_is_mrg = q_tag_mem_reg[q_rd_ptr_reg];

always @* begin
    lkp_state_next = lkp_state_reg;
    arp_request_ip_next = arp_request_ip_reg;
    arp_request_retry_cnt_next = arp_request_retry_cnt_reg;
    arp_request_timer_next = arp_request_timer_reg;

    arp_response_valid_next = arp_response_valid_reg && !arp_response_ready;
    arp_response_error_next = arp_response_error_reg;
    arp_response_mac_next = arp_response_mac_reg;

    lkp_wakeup_valid_next = lkp_wakeup_valid_reg;
    lkp_wakeup_mac_next = lkp_wakeup_mac_reg;

    mrg_state_next = mrg_state_reg;
    mrg_ip_next = mrg_ip_reg;
    mrg_mac_next = mrg_mac_reg;

    cache_query_request_valid_next = cache_query_request_valid_reg && !cache_query_request_ready;
    cache_query_request_ip_next = cache_query_request_ip_reg;
    cur_q_is_mrg_next = cur_q_is_mrg_reg;

    q_tag_mem_next = q_tag_mem_reg;
    q_wr_ptr_next = q_wr_ptr_reg;
    q_rd_ptr_next = q_rd_ptr_reg;

    cache_write_request_valid_next = cache_write_request_valid_reg && !cache_write_request_ready;
    cache_write_request_ip_next = cache_write_request_ip_reg;
    cache_write_request_mac_next = cache_write_request_mac_reg;

    reply_pending_next = reply_pending_reg;
    reply_eth_dest_next = reply_eth_dest_reg;
    reply_oper_next = reply_oper_reg;
    reply_tha_next = reply_tha_reg;
    reply_tpa_next = reply_tpa_reg;

    req_tx_pending_next = req_tx_pending_reg;
    req_tx_ip_next = req_tx_ip_reg;

    outgoing_frame_valid_next = outgoing_frame_valid_reg && !outgoing_frame_ready;
    outgoing_eth_dest_mac_next = outgoing_eth_dest_mac_reg;
    outgoing_arp_oper_next = outgoing_arp_oper_reg;
    outgoing_arp_tha_next = outgoing_arp_tha_reg;
    outgoing_arp_tpa_next = outgoing_arp_tpa_reg;

    if (cache_query_request_valid_reg && cache_query_request_ready) begin
        q_tag_mem_next[q_wr_ptr_reg] = cur_q_is_mrg_reg;
        q_wr_ptr_next = q_wr_ptr_reg + 2'd1;
    end

    if (cache_query_response_valid) begin
        q_rd_ptr_next = q_rd_ptr_reg + 2'd1;
        if (resp_is_mrg && (mrg_state_reg == MRG_WAIT)) begin
            mrg_state_next = MRG_IDLE;
            if (!cache_query_response_error) begin
                cache_write_request_valid_next = 1'b1;
                cache_write_request_ip_next = mrg_ip_reg;
                cache_write_request_mac_next = mrg_mac_reg;
            end
        end
    end

    // Accept incoming frame when write/merge path is free and (if reply needed) reply buffer is free
    incoming_frame_ready = (mrg_state_reg == MRG_IDLE) && !cache_write_request_valid_next &&
                           (!in_need_reply || !reply_pending_reg || tx_port_free);

    if (incoming_frame_valid && incoming_frame_ready) begin
        if (in_need_arp_reply) begin
            reply_pending_next = 1'b1;
            reply_eth_dest_next = incoming_eth_src_mac;
            reply_oper_next = ARP_OPER_ARP_REPLY;
            reply_tha_next = incoming_arp_sha;
            reply_tpa_next = incoming_arp_spa;
        end else if (in_need_inarp_reply) begin
            reply_pending_next = 1'b1;
            reply_eth_dest_next = incoming_eth_src_mac;
            reply_oper_next = ARP_OPER_INARP_REPLY;
            reply_tha_next = incoming_arp_sha;
            reply_tpa_next = incoming_arp_spa;
        end

        if (in_proto_ok && in_sha_valid && in_spa_valid) begin
            if (in_targeted || ((lkp_state_reg != LKP_IDLE) && (incoming_arp_spa == arp_request_ip_reg))) begin
                cache_write_request_valid_next = 1'b1;
                cache_write_request_ip_next = incoming_arp_spa;
                cache_write_request_mac_next = incoming_arp_sha;
                if ((lkp_state_reg != LKP_IDLE) && (incoming_arp_spa == arp_request_ip_reg)) begin
                    lkp_wakeup_valid_next = 1'b1;
                    lkp_wakeup_mac_next = incoming_arp_sha;
                end
            end else begin
                mrg_state_next = MRG_REQ;
                mrg_ip_next = incoming_arp_spa;
                mrg_mac_next = incoming_arp_sha;
            end
        end
    end

    // Issue pending cache query (MERGE probe or initial LOOKUP check)
    if (!cache_query_request_valid_next && !cache_write_request_valid_next) begin
        if (mrg_state_next == MRG_REQ) begin
            cache_query_request_valid_next = 1'b1;
            cache_query_request_ip_next = mrg_ip_next;
            cur_q_is_mrg_next = 1'b1;
            mrg_state_next = MRG_WAIT;
        end else if ((lkp_state_reg == LKP_INIT_QUERY) && !lkp_wakeup_valid_next) begin
            cache_query_request_valid_next = 1'b1;
            cache_query_request_ip_next = arp_request_ip_reg;
            cur_q_is_mrg_next = 1'b0;
            lkp_state_next = LKP_INIT_WAIT;
        end
    end

    // Lookup state machine
    case (lkp_state_reg)
        LKP_IDLE: begin
            if (arp_request_valid && arp_request_ready) begin
                lkp_wakeup_valid_next = 1'b0;
                if ((arp_request_ip == 32'hFFFF_FFFF) ||
                    ((subnet_mask != 32'hFFFF_FFFF) &&
                     (((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0) &&
                     ((arp_request_ip | subnet_mask) == 32'hFFFF_FFFF))) begin
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b0;
                    arp_response_mac_next = 48'hFFFF_FFFF_FFFF;
                end else if (arp_request_ip[31:28] == 4'hE) begin
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b0;
                    arp_response_mac_next = {24'h01_00_5E, 1'b0, arp_request_ip[22:0]};
                end else if (((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0) begin
                    arp_request_ip_next = arp_request_ip;
                    lkp_state_next = LKP_INIT_QUERY;
                end else if (gateway_ip == 32'd0) begin
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b1;
                    arp_response_mac_next = 48'd0;
                end else begin
                    arp_request_ip_next = gateway_ip;
                    lkp_state_next = LKP_INIT_QUERY;
                end
            end
        end

        LKP_INIT_QUERY: begin
            // Handled above when query port is free; if woken early before query launched, resolve!
            if (lkp_wakeup_valid_next && !arp_response_valid_next) begin
                arp_response_valid_next = 1'b1;
                arp_response_error_next = 1'b0;
                arp_response_mac_next = lkp_wakeup_mac_next;
                lkp_wakeup_valid_next = 1'b0;
                lkp_state_next = LKP_IDLE;
            end
        end

        LKP_INIT_WAIT: begin
            if (cache_query_response_valid && !resp_is_mrg) begin
                if (lkp_wakeup_valid_next) begin
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b0;
                    arp_response_mac_next = lkp_wakeup_mac_next;
                    lkp_wakeup_valid_next = 1'b0;
                    lkp_state_next = LKP_IDLE;
                end else if (!cache_query_response_error) begin
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b0;
                    arp_response_mac_next = cache_query_response_mac;
                    lkp_state_next = LKP_IDLE;
                end else begin
                    req_tx_pending_next = 1'b1;
                    req_tx_ip_next = arp_request_ip_reg;
                    if (REQUEST_RETRY_COUNT > 1) begin
                        arp_request_retry_cnt_next = REQUEST_RETRY_COUNT - 1;
                        arp_request_timer_next = REQUEST_RETRY_INTERVAL;
                    end else begin
                        arp_request_retry_cnt_next = 6'd0;
                        arp_request_timer_next = REQUEST_TIMEOUT;
                    end
                    lkp_state_next = LKP_WAIT_REPLY;
                end
            end
        end

        LKP_WAIT_REPLY: begin
            if (lkp_wakeup_valid_next) begin
                if (!arp_response_valid_next) begin
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b0;
                    arp_response_mac_next = lkp_wakeup_mac_next;
                    lkp_wakeup_valid_next = 1'b0;
                    req_tx_pending_next = 1'b0;
                    lkp_state_next = LKP_IDLE;
                end
            end else if (arp_request_timer_reg == 36'd0) begin
                if (arp_request_retry_cnt_reg > 6'd0) begin
                    req_tx_pending_next = 1'b1;
                    req_tx_ip_next = arp_request_ip_reg;
                    arp_request_retry_cnt_next = arp_request_retry_cnt_reg - 6'd1;
                    if (arp_request_retry_cnt_reg > 6'd1) begin
                        arp_request_timer_next = REQUEST_RETRY_INTERVAL;
                    end else begin
                        arp_request_timer_next = REQUEST_TIMEOUT;
                    end
                end else if (!arp_response_valid_next) begin
                    arp_response_valid_next = 1'b1;
                    arp_response_error_next = 1'b1;
                    arp_response_mac_next = 48'd0;
                    lkp_state_next = LKP_IDLE;
                end
            end else begin
                arp_request_timer_next = arp_request_timer_reg - 36'd1;
            end
        end
    endcase

    // Outgoing TX frame arbiter (strict valid/ready stability; Reply prioritized over Request)
    if (tx_port_free) begin
        if (reply_pending_next) begin
            outgoing_frame_valid_next = 1'b1;
            outgoing_eth_dest_mac_next = reply_eth_dest_next;
            outgoing_arp_oper_next = reply_oper_next;
            outgoing_arp_tha_next = reply_tha_next;
            outgoing_arp_tpa_next = reply_tpa_next;
            reply_pending_next = 1'b0;
        end else if (req_tx_pending_next) begin
            outgoing_frame_valid_next = 1'b1;
            outgoing_eth_dest_mac_next = 48'hFFFF_FFFF_FFFF;
            outgoing_arp_oper_next = ARP_OPER_ARP_REQUEST;
            outgoing_arp_tha_next = 48'h0000_0000_0000;
            outgoing_arp_tpa_next = req_tx_ip_next;
            req_tx_pending_next = 1'b0;
        end
    end

    arp_request_ready_next = (lkp_state_next == LKP_IDLE) && !arp_response_valid_next &&
                             !cache_write_request_valid_next && !clear_cache;
end

always @(posedge clk) begin
    if (rst) begin
        lkp_state_reg <= LKP_IDLE;
        arp_request_ready_reg <= 1'b0;
        arp_request_ip_reg <= 32'd0;
        arp_response_valid_reg <= 1'b0;
        arp_response_error_reg <= 1'b0;
        arp_response_mac_reg <= 48'd0;
        arp_request_retry_cnt_reg <= 6'd0;
        arp_request_timer_reg <= 36'd0;
        lkp_wakeup_valid_reg <= 1'b0;
        lkp_wakeup_mac_reg <= 48'd0;
        mrg_state_reg <= MRG_IDLE;
        mrg_ip_reg <= 32'd0;
        mrg_mac_reg <= 48'd0;
        cache_query_request_valid_reg <= 1'b0;
        cache_query_request_ip_reg <= 32'd0;
        cur_q_is_mrg_reg <= 1'b0;
        q_tag_mem_reg <= 4'd0;
        q_wr_ptr_reg <= 2'd0;
        q_rd_ptr_reg <= 2'd0;
        cache_write_request_valid_reg <= 1'b0;
        cache_write_request_ip_reg <= 32'd0;
        cache_write_request_mac_reg <= 48'd0;
        reply_pending_reg <= 1'b0;
        reply_eth_dest_reg <= 48'd0;
        reply_oper_reg <= 16'd0;
        reply_tha_reg <= 48'd0;
        reply_tpa_reg <= 32'd0;
        req_tx_pending_reg <= 1'b0;
        req_tx_ip_reg <= 32'd0;
        outgoing_frame_valid_reg <= 1'b0;
        outgoing_eth_dest_mac_reg <= 48'd0;
        outgoing_arp_oper_reg <= 16'd0;
        outgoing_arp_tha_reg <= 48'd0;
        outgoing_arp_tpa_reg <= 32'd0;
    end else begin
        lkp_state_reg <= lkp_state_next;
        arp_request_ready_reg <= arp_request_ready_next;
        arp_request_ip_reg <= arp_request_ip_next;
        arp_response_valid_reg <= arp_response_valid_next;
        arp_response_error_reg <= arp_response_error_next;
        arp_response_mac_reg <= arp_response_mac_next;
        arp_request_retry_cnt_reg <= arp_request_retry_cnt_next;
        arp_request_timer_reg <= arp_request_timer_next;
        lkp_wakeup_valid_reg <= lkp_wakeup_valid_next;
        lkp_wakeup_mac_reg <= lkp_wakeup_mac_next;
        mrg_state_reg <= mrg_state_next;
        mrg_ip_reg <= mrg_ip_next;
        mrg_mac_reg <= mrg_mac_next;
        cache_query_request_valid_reg <= cache_query_request_valid_next;
        cache_query_request_ip_reg <= cache_query_request_ip_next;
        cur_q_is_mrg_reg <= cur_q_is_mrg_next;
        q_tag_mem_reg <= q_tag_mem_next;
        q_wr_ptr_reg <= q_wr_ptr_next;
        q_rd_ptr_reg <= q_rd_ptr_next;
        cache_write_request_valid_reg <= cache_write_request_valid_next;
        cache_write_request_ip_reg <= cache_write_request_ip_next;
        cache_write_request_mac_reg <= cache_write_request_mac_next;
        reply_pending_reg <= reply_pending_next;
        reply_eth_dest_reg <= reply_eth_dest_next;
        reply_oper_reg <= reply_oper_next;
        reply_tha_reg <= reply_tha_next;
        reply_tpa_reg <= reply_tpa_next;
        req_tx_pending_reg <= req_tx_pending_next;
        req_tx_ip_reg <= req_tx_ip_next;
        outgoing_frame_valid_reg <= outgoing_frame_valid_next;
        outgoing_eth_dest_mac_reg <= outgoing_eth_dest_mac_next;
        outgoing_arp_oper_reg <= outgoing_arp_oper_next;
        outgoing_arp_tha_reg <= outgoing_arp_tha_next;
        outgoing_arp_tpa_reg <= outgoing_arp_tpa_next;
    end
end

endmodule

`resetall
