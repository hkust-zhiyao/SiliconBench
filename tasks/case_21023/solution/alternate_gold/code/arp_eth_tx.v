/*
 * Alternate Gold: Vector-sliced ARP ethernet frame transmitter with 2-entry AXIS FIFO
 */
`resetall
`timescale 1ns / 1ps
`default_nettype none

module arp_eth_tx #
(
    parameter DATA_WIDTH = 8,
    parameter KEEP_ENABLE = (DATA_WIDTH>8),
    parameter KEEP_WIDTH = (DATA_WIDTH/8)
)
(
    input  wire                   clk,
    input  wire                   rst,

    input  wire                   s_frame_valid,
    output wire                   s_frame_ready,
    input  wire [47:0]            s_eth_dest_mac,
    input  wire [47:0]            s_eth_src_mac,
    input  wire [15:0]            s_eth_type,
    input  wire [15:0]            s_arp_htype,
    input  wire [15:0]            s_arp_ptype,
    input  wire [15:0]            s_arp_oper,
    input  wire [47:0]            s_arp_sha,
    input  wire [31:0]            s_arp_spa,
    input  wire [47:0]            s_arp_tha,
    input  wire [31:0]            s_arp_tpa,

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

    output wire                   busy
);

parameter BYTE_LANES = KEEP_ENABLE ? KEEP_WIDTH : 1;
parameter HDR_SIZE = 28;
parameter CYCLE_COUNT = (HDR_SIZE + BYTE_LANES - 1) / BYTE_LANES;
parameter PTR_WIDTH = (CYCLE_COUNT > 1) ? $clog2(CYCLE_COUNT) : 1;
parameter OFFSET = HDR_SIZE % BYTE_LANES;

reg active_r, active_next;
reg [PTR_WIDTH-1:0] beat_r, beat_next;
reg [223:0] hdr_vec_r;
reg latch_in;

reg s_ready_r;
reg m_hdr_valid_r, m_hdr_valid_next;
reg [47:0] eth_dst_r, eth_src_r;
reg [15:0] eth_type_r;
reg busy_r;

reg [DATA_WIDTH-1:0] q_data [0:1];
reg [KEEP_WIDTH-1:0] q_keep [0:1];
reg                  q_last [0:1];
reg [1:0] q_wr_ptr, q_rd_ptr;

wire [1:0] q_cnt = q_wr_ptr - q_rd_ptr;
wire q_empty = (q_wr_ptr == q_rd_ptr);
wire q_can_push = (q_cnt < 2'd2) || m_eth_payload_axis_tready;

assign s_frame_ready = s_ready_r;
assign m_eth_hdr_valid = m_hdr_valid_r;
assign m_eth_dest_mac = eth_dst_r;
assign m_eth_src_mac  = eth_src_r;
assign m_eth_type     = eth_type_r;
assign busy           = busy_r;

assign m_eth_payload_axis_tvalid = !q_empty;
assign m_eth_payload_axis_tdata  = q_data[q_rd_ptr[0]];
assign m_eth_payload_axis_tkeep  = KEEP_ENABLE ? q_keep[q_rd_ptr[0]] : {KEEP_WIDTH{1'b1}};
assign m_eth_payload_axis_tlast  = q_last[q_rd_ptr[0]];
assign m_eth_payload_axis_tuser  = 1'b0;

reg                  push_beat;
reg [DATA_WIDTH-1:0] push_data;
reg [KEEP_WIDTH-1:0] push_keep;
reg                  push_last;

integer ln;
integer bpos;

always @* begin
    active_next = active_r;
    beat_next = beat_r;
    latch_in = 1'b0;
    m_hdr_valid_next = m_hdr_valid_r && !m_eth_hdr_ready;

    push_beat = 1'b0;
    push_data = {DATA_WIDTH{1'b0}};
    push_keep = {KEEP_WIDTH{1'b0}};
    push_last = 1'b0;

    if (s_frame_valid && s_frame_ready) begin
        latch_in = 1'b1;
        m_hdr_valid_next = 1'b1;
        beat_next = {PTR_WIDTH{1'b0}};
        active_next = 1'b1;
    end

    if (active_r && q_can_push) begin
        push_beat = 1'b1;
        for (ln = 0; ln < BYTE_LANES; ln = ln + 1) begin
            bpos = beat_r * BYTE_LANES + ln;
            if (bpos < HDR_SIZE) begin
                push_data[ln*8 +: 8] = hdr_vec_r[(HDR_SIZE - 1 - bpos)*8 +: 8];
                push_keep[ln] = 1'b1;
            end
        end
        if (beat_r == (CYCLE_COUNT - 1)) begin
            push_last = 1'b1;
            active_next = 1'b0;
        end else begin
            beat_next = beat_r + 1'b1;
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        active_r <= 1'b0;
        beat_r <= {PTR_WIDTH{1'b0}};
        hdr_vec_r <= 224'd0;
        s_ready_r <= 1'b0;
        m_hdr_valid_r <= 1'b0;
        eth_dst_r <= 48'd0;
        eth_src_r <= 48'd0;
        eth_type_r <= 16'd0;
        busy_r <= 1'b0;
        q_wr_ptr <= 2'd0;
        q_rd_ptr <= 2'd0;
        q_data[0] <= {DATA_WIDTH{1'b0}};
        q_data[1] <= {DATA_WIDTH{1'b0}};
        q_keep[0] <= {KEEP_WIDTH{1'b0}};
        q_keep[1] <= {KEEP_WIDTH{1'b0}};
        q_last[0] <= 1'b0;
        q_last[1] <= 1'b0;
    end else begin
        active_r <= active_next;
        beat_r <= beat_next;
        m_hdr_valid_r <= m_hdr_valid_next;
        busy_r <= active_next;
        s_ready_r <= !m_hdr_valid_next && !active_next;

        if (latch_in) begin
            eth_dst_r <= s_eth_dest_mac;
            eth_src_r <= s_eth_src_mac;
            eth_type_r <= s_eth_type;
            hdr_vec_r <= {s_arp_htype, s_arp_ptype, 8'd6, 8'd4, s_arp_oper,
                          s_arp_sha, s_arp_spa, s_arp_tha, s_arp_tpa};
        end

        if (!q_empty && m_eth_payload_axis_tready) begin
            q_rd_ptr <= q_rd_ptr + 2'd1;
        end

        if (push_beat) begin
            q_data[q_wr_ptr[0]] <= push_data;
            q_keep[q_wr_ptr[0]] <= push_keep;
            q_last[q_wr_ptr[0]] <= push_last;
            q_wr_ptr <= q_wr_ptr + 2'd1;
        end
    end
end

endmodule

`resetall
