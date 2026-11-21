/*
 * Alternate Gold: Vector-indexed ARP ethernet frame receiver
 */
`resetall
`timescale 1ns / 1ps
`default_nettype none

module arp_eth_rx #
(
    parameter DATA_WIDTH = 8,
    parameter KEEP_ENABLE = (DATA_WIDTH>8),
    parameter KEEP_WIDTH = (DATA_WIDTH/8)
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

    output wire                   m_frame_valid,
    input  wire                   m_frame_ready,
    output wire [47:0]            m_eth_dest_mac,
    output wire [47:0]            m_eth_src_mac,
    output wire [15:0]            m_eth_type,
    output wire [15:0]            m_arp_htype,
    output wire [15:0]            m_arp_ptype,
    output wire [7:0]             m_arp_hlen,
    output wire [7:0]             m_arp_plen,
    output wire [15:0]            m_arp_oper,
    output wire [47:0]            m_arp_sha,
    output wire [31:0]            m_arp_spa,
    output wire [47:0]            m_arp_tha,
    output wire [31:0]            m_arp_tpa,

    output wire                   busy,
    output wire                   error_header_early_termination,
    output wire                   error_invalid_header
);

parameter BYTE_LANES = KEEP_ENABLE ? KEEP_WIDTH : 1;
parameter HDR_SIZE = 28;
parameter CYCLE_COUNT = (HDR_SIZE + BYTE_LANES - 1) / BYTE_LANES;
parameter PTR_WIDTH = (CYCLE_COUNT > 1) ? $clog2(CYCLE_COUNT) : 1;
parameter OFFSET = HDR_SIZE % BYTE_LANES;

localparam [1:0]
    RX_WAIT_HDR = 2'd0,
    RX_READ_ARP = 2'd1,
    RX_DRAIN    = 2'd2;

reg [1:0] state_reg, state_next;
reg [PTR_WIDTH-1:0] beat_idx_reg, beat_idx_next;
reg trunc_seen_reg, trunc_seen_next;
reg tuser_seen_reg, tuser_seen_next;

reg s_hdr_ready_r, s_pay_ready_r;
reg m_valid_r, m_valid_next;
reg [47:0] eth_dst_r, eth_src_r;
reg [15:0] eth_type_r;
reg [223:0] hdr_vec_r, hdr_vec_next;
reg latch_eth_hdr;

reg busy_r;
reg err_early_r, err_early_next;
reg err_inv_r, err_inv_next;

assign s_eth_hdr_ready = s_hdr_ready_r;
assign s_eth_payload_axis_tready = s_pay_ready_r;

assign m_frame_valid = m_valid_r;
assign m_eth_dest_mac = eth_dst_r;
assign m_eth_src_mac  = eth_src_r;
assign m_eth_type     = eth_type_r;

assign {m_arp_htype, m_arp_ptype, m_arp_hlen, m_arp_plen,
        m_arp_oper, m_arp_sha, m_arp_spa, m_arp_tha, m_arp_tpa} = hdr_vec_r;

assign busy = busy_r;
assign error_header_early_termination = err_early_r;
assign error_invalid_header = err_inv_r;

integer ln;
integer bpos;
reg lane_keep_miss;

always @* begin
    state_next = state_reg;
    beat_idx_next = beat_idx_reg;
    trunc_seen_next = trunc_seen_reg;
    tuser_seen_next = tuser_seen_reg;
    hdr_vec_next = hdr_vec_r;
    latch_eth_hdr = 1'b0;

    m_valid_next = m_valid_r && !m_frame_ready;
    err_early_next = 1'b0;
    err_inv_next = 1'b0;
    lane_keep_miss = 1'b0;

    if ((state_reg == RX_WAIT_HDR) && s_eth_hdr_valid && s_eth_hdr_ready) begin
        latch_eth_hdr = 1'b1;
        beat_idx_next = {PTR_WIDTH{1'b0}};
        trunc_seen_next = 1'b0;
        tuser_seen_next = 1'b0;
        state_next = RX_READ_ARP;
    end

    if ((state_reg != RX_WAIT_HDR) && s_eth_payload_axis_tvalid && s_eth_payload_axis_tready) begin
        tuser_seen_next = tuser_seen_reg | s_eth_payload_axis_tuser;

        if (state_reg == RX_READ_ARP) begin
            for (ln = 0; ln < BYTE_LANES; ln = ln + 1) begin
                bpos = beat_idx_reg * BYTE_LANES + ln;
                if (bpos < HDR_SIZE) begin
                    if (KEEP_ENABLE && !s_eth_payload_axis_tkeep[ln]) begin
                        lane_keep_miss = 1'b1;
                    end else begin
                        hdr_vec_next[(HDR_SIZE - 1 - bpos)*8 +: 8] = s_eth_payload_axis_tdata[ln*8 +: 8];
                    end
                end
            end

            if (lane_keep_miss) begin
                trunc_seen_next = 1'b1;
                state_next = RX_DRAIN;
            end else if (beat_idx_reg == (CYCLE_COUNT - 1)) begin
                state_next = RX_DRAIN;
            end else begin
                beat_idx_next = beat_idx_reg + 1'b1;
            end
        end

        if (s_eth_payload_axis_tlast) begin
            if ((state_next == RX_READ_ARP) || trunc_seen_next) begin
                err_early_next = 1'b1;
            end else if ((hdr_vec_next[191:184] != 8'd6) || (hdr_vec_next[183:176] != 8'd4)) begin
                err_inv_next = 1'b1;
            end else if (!tuser_seen_next) begin
                m_valid_next = 1'b1;
            end
            state_next = RX_WAIT_HDR;
            beat_idx_next = {PTR_WIDTH{1'b0}};
            trunc_seen_next = 1'b0;
            tuser_seen_next = 1'b0;
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        state_reg <= RX_WAIT_HDR;
        beat_idx_reg <= {PTR_WIDTH{1'b0}};
        trunc_seen_reg <= 1'b0;
        tuser_seen_reg <= 1'b0;
        s_hdr_ready_r <= 1'b0;
        s_pay_ready_r <= 1'b0;
        m_valid_r <= 1'b0;
        eth_dst_r <= 48'd0;
        eth_src_r <= 48'd0;
        eth_type_r <= 16'd0;
        hdr_vec_r <= 224'd0;
        busy_r <= 1'b0;
        err_early_r <= 1'b0;
        err_inv_r <= 1'b0;
    end else begin
        state_reg <= state_next;
        beat_idx_reg <= beat_idx_next;
        trunc_seen_reg <= trunc_seen_next;
        tuser_seen_reg <= tuser_seen_next;
        m_valid_r <= m_valid_next;
        hdr_vec_r <= hdr_vec_next;
        err_early_r <= err_early_next;
        err_inv_r <= err_inv_next;
        busy_r <= (state_next != RX_WAIT_HDR);
        s_hdr_ready_r <= (state_next == RX_WAIT_HDR) && !m_valid_next;
        s_pay_ready_r <= (state_next != RX_WAIT_HDR);
        if (latch_eth_hdr) begin
            eth_dst_r <= s_eth_dest_mac;
            eth_src_r <= s_eth_src_mac;
            eth_type_r <= s_eth_type;
        end
    end
end

endmodule

`resetall
