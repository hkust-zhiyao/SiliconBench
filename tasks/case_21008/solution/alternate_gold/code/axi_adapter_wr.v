/*
 * Copyright (c) 2018 Alex Forencich
 * SPDX-License-Identifier: MIT
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

module axi_adapter_wr #
(
    parameter ADDR_WIDTH = 32,
    parameter S_DATA_WIDTH = 32,
    parameter S_STRB_WIDTH = (S_DATA_WIDTH/8),
    parameter M_DATA_WIDTH = 32,
    parameter M_STRB_WIDTH = (M_DATA_WIDTH/8),
    parameter ID_WIDTH = 8,
    parameter AWUSER_ENABLE = 0,
    parameter AWUSER_WIDTH = 1,
    parameter WUSER_ENABLE = 0,
    parameter WUSER_WIDTH = 1,
    parameter BUSER_ENABLE = 0,
    parameter BUSER_WIDTH = 1,
    parameter CONVERT_BURST = 1,
    parameter CONVERT_NARROW_BURST = 0,
    parameter FORWARD_ID = 0
)
(
    input  wire                     clk,
    input  wire                     rst,

    input  wire [ID_WIDTH-1:0]      s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire [7:0]               s_axi_awlen,
    input  wire [2:0]               s_axi_awsize,
    input  wire [1:0]               s_axi_awburst,
    input  wire                     s_axi_awlock,
    input  wire [3:0]               s_axi_awcache,
    input  wire [2:0]               s_axi_awprot,
    input  wire [3:0]               s_axi_awqos,
    input  wire [3:0]               s_axi_awregion,
    input  wire [AWUSER_WIDTH-1:0]  s_axi_awuser,
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,
    input  wire [S_DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire [S_STRB_WIDTH-1:0]  s_axi_wstrb,
    input  wire                     s_axi_wlast,
    input  wire [WUSER_WIDTH-1:0]   s_axi_wuser,
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,
    output wire [ID_WIDTH-1:0]      s_axi_bid,
    output wire [1:0]               s_axi_bresp,
    output wire [BUSER_WIDTH-1:0]   s_axi_buser,
    output wire                     s_axi_bvalid,
    input  wire                     s_axi_bready,

    output wire [ID_WIDTH-1:0]      m_axi_awid,
    output wire [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [7:0]               m_axi_awlen,
    output wire [2:0]               m_axi_awsize,
    output wire [1:0]               m_axi_awburst,
    output wire                     m_axi_awlock,
    output wire [3:0]               m_axi_awcache,
    output wire [2:0]               m_axi_awprot,
    output wire [3:0]               m_axi_awqos,
    output wire [3:0]               m_axi_awregion,
    output wire [AWUSER_WIDTH-1:0]  m_axi_awuser,
    output wire                     m_axi_awvalid,
    input  wire                     m_axi_awready,
    output wire [M_DATA_WIDTH-1:0]  m_axi_wdata,
    output wire [M_STRB_WIDTH-1:0]  m_axi_wstrb,
    output wire                     m_axi_wlast,
    output wire [WUSER_WIDTH-1:0]   m_axi_wuser,
    output wire                     m_axi_wvalid,
    input  wire                     m_axi_wready,
    input  wire [ID_WIDTH-1:0]      m_axi_bid,
    input  wire [1:0]               m_axi_bresp,
    input  wire [BUSER_WIDTH-1:0]   m_axi_buser,
    input  wire                     m_axi_bvalid,
    output wire                     m_axi_bready
);

localparam S_LSB = $clog2(S_STRB_WIDTH);
localparam M_LSB = $clog2(M_STRB_WIDTH);
localparam [2:0] S_SZ_LP = S_LSB[2:0];
localparam [2:0] M_SZ_LP = M_LSB[2:0];
localparam IS_UPSIZE = (M_STRB_WIDTH > S_STRB_WIDTH);
localparam IS_EQUAL  = (M_STRB_WIDTH == S_STRB_WIDTH);
localparam BUF_DATA_W = IS_UPSIZE ? M_DATA_WIDTH : S_DATA_WIDTH;
localparam BUF_STRB_W = IS_UPSIZE ? M_STRB_WIDTH : S_STRB_WIDTH;
localparam SEG_CNT    = IS_UPSIZE ? (M_STRB_WIDTH / S_STRB_WIDTH) : (S_STRB_WIDTH / M_STRB_WIDTH);

localparam [2:0]
    WR_IDLE       = 3'd0,
    WR_PASSTHRU   = 3'd1,
    WR_PACK_WIDE  = 3'd2,
    WR_SPLIT_HEAD = 3'd3,
    WR_SPLIT_TAIL = 3'd4,
    WR_WAIT_BRESP = 3'd5;

function [ADDR_WIDTH-1:0] wrap_span_mask;
    input [2:0] bsz;
    input [7:0] blen;
    reg [ADDR_WIDTH-1:0] unit_b;
    begin
        unit_b = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << bsz);
        if (blen == 8'd1)
            wrap_span_mask = (unit_b << 1) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
        else if (blen == 8'd3)
            wrap_span_mask = (unit_b << 2) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
        else if (blen == 8'd7)
            wrap_span_mask = (unit_b << 3) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
        else
            wrap_span_mask = (unit_b << 4) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
    end
endfunction

function [ADDR_WIDTH-1:0] advance_addr;
    input [ADDR_WIDTH-1:0] cur_a;
    input [ADDR_WIDTH-1:0] base_a;
    input [ADDR_WIDTH-1:0] w_mask;
    input [2:0] bsz;
    input [1:0] bkind;
    reg [ADDR_WIDTH-1:0] step_b;
    reg [ADDR_WIDTH-1:0] nxt_aligned;
    begin
        step_b = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << bsz);
        nxt_aligned = (cur_a + step_b) & ~(step_b - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        if (bkind == 2'b00)
            advance_addr = base_a;
        else if (bkind == 2'b10)
            advance_addr = (cur_a & ~w_mask) | (nxt_aligned & w_mask);
        else
            advance_addr = nxt_aligned;
    end
endfunction

// 2-entry circular output FIFO for W channel
reg [M_DATA_WIDTH-1:0] wfifo_data [0:1];
reg [M_STRB_WIDTH-1:0] wfifo_strb [0:1];
reg                    wfifo_last [0:1];
reg [WUSER_WIDTH-1:0]  wfifo_user [0:1];
reg                    wfifo_wptr = 1'b0;
reg                    wfifo_rptr = 1'b0;
reg [1:0]              wfifo_cnt  = 2'd0;

reg  [M_DATA_WIDTH-1:0] push_wdata;
reg  [M_STRB_WIDTH-1:0] push_wstrb;
reg                     push_wlast;
reg  [WUSER_WIDTH-1:0]  push_wuser;
reg                     push_wvalid;

wire pop_w = m_axi_wvalid && m_axi_wready;
wire [1:0] wfifo_cnt_after_pop = wfifo_cnt - {1'b0, pop_w};
wire wfifo_can_accept_next = (wfifo_cnt_after_pop + {1'b0, push_wvalid}) <= 2'd1;
reg  pipe_wready_reg = 1'b0;

assign m_axi_wvalid = (wfifo_cnt != 2'd0);
assign m_axi_wdata  = wfifo_data[wfifo_rptr];
assign m_axi_wstrb  = wfifo_strb[wfifo_rptr];
assign m_axi_wlast  = wfifo_last[wfifo_rptr];
assign m_axi_wuser  = WUSER_ENABLE ? wfifo_user[wfifo_rptr] : {WUSER_WIDTH{1'b0}};

always @(posedge clk) begin
    if (rst) begin
        wfifo_wptr <= 1'b0;
        wfifo_rptr <= 1'b0;
        wfifo_cnt  <= 2'd0;
        pipe_wready_reg <= 1'b0;
    end else begin
        pipe_wready_reg <= wfifo_can_accept_next;
        if (push_wvalid) begin
            wfifo_data[wfifo_wptr] <= push_wdata;
            wfifo_strb[wfifo_wptr] <= push_wstrb;
            wfifo_last[wfifo_wptr] <= push_wlast;
            wfifo_user[wfifo_wptr] <= push_wuser;
            wfifo_wptr <= ~wfifo_wptr;
        end
        if (pop_w) begin
            wfifo_rptr <= ~wfifo_rptr;
        end
        case ({push_wvalid, pop_w})
            2'b10: wfifo_cnt <= wfifo_cnt + 2'd1;
            2'b01: wfifo_cnt <= wfifo_cnt - 2'd1;
            default: wfifo_cnt <= wfifo_cnt;
        endcase
    end
end

reg [2:0] fsm_reg = WR_IDLE, fsm_next;
reg [ID_WIDTH-1:0] cur_id_reg = {ID_WIDTH{1'b0}}, cur_id_next;
reg [ADDR_WIDTH-1:0] cur_addr_reg = {ADDR_WIDTH{1'b0}}, cur_addr_next;
reg [ADDR_WIDTH-1:0] start_addr_reg = {ADDR_WIDTH{1'b0}}, start_addr_next;
reg [ADDR_WIDTH-1:0] wmask_reg = {ADDR_WIDTH{1'b0}}, wmask_next;
reg [1:0] bkind_reg = 2'd0, bkind_next;
reg [BUF_DATA_W-1:0] accum_data_reg = {BUF_DATA_W{1'b0}}, accum_data_next;
reg [BUF_STRB_W-1:0] accum_strb_reg = {BUF_STRB_W{1'b0}}, accum_strb_next;
reg [WUSER_WIDTH-1:0] accum_user_reg = {WUSER_WIDTH{1'b0}}, accum_user_next;
reg [7:0] rem_s_reg = 8'd0, rem_s_next;
reg [2:0] s_sz_reg = 3'd0, s_sz_next;
reg [7:0] rem_m_reg = 8'd0, rem_m_next;
reg [2:0] m_sz_reg = 3'd0, m_sz_next;
reg more_s_reg = 1'b0, more_s_next;
reg first_b_reg = 1'b0, first_b_next;

reg awready_reg = 1'b0, awready_next;
reg wready_reg = 1'b0, wready_next;
reg [ID_WIDTH-1:0] s_bid_reg = {ID_WIDTH{1'b0}}, s_bid_next;
reg [1:0] s_bresp_reg = 2'd0, s_bresp_next;
reg [BUSER_WIDTH-1:0] s_buser_reg = {BUSER_WIDTH{1'b0}}, s_buser_next;
reg s_bvalid_reg = 1'b0, s_bvalid_next;

reg [ID_WIDTH-1:0] m_awid_reg = {ID_WIDTH{1'b0}}, m_awid_next;
reg [ADDR_WIDTH-1:0] m_awaddr_reg = {ADDR_WIDTH{1'b0}}, m_awaddr_next;
reg [7:0] m_awlen_reg = 8'd0, m_awlen_next;
reg [2:0] m_awsize_reg = 3'd0, m_awsize_next;
reg [1:0] m_awburst_reg = 2'd0, m_awburst_next;
reg m_awlock_reg = 1'b0, m_awlock_next;
reg [3:0] m_awcache_reg = 4'd0, m_awcache_next;
reg [2:0] m_awprot_reg = 3'd0, m_awprot_next;
reg [3:0] m_awqos_reg = 4'd0, m_awqos_next;
reg [3:0] m_awregion_reg = 4'd0, m_awregion_next;
reg [AWUSER_WIDTH-1:0] m_awuser_reg = {AWUSER_WIDTH{1'b0}}, m_awuser_next;
reg m_awvalid_reg = 1'b0, m_awvalid_next;
reg m_bready_reg = 1'b0, m_bready_next;

assign s_axi_awready = awready_reg;
assign s_axi_wready  = wready_reg;
assign s_axi_bid     = s_bid_reg;
assign s_axi_bresp   = s_bresp_reg;
assign s_axi_buser   = BUSER_ENABLE ? s_buser_reg : {BUSER_WIDTH{1'b0}};
assign s_axi_bvalid  = s_bvalid_reg;

assign m_axi_awid     = FORWARD_ID ? m_awid_reg : {ID_WIDTH{1'b0}};
assign m_axi_awaddr   = m_awaddr_reg;
assign m_axi_awlen    = m_awlen_reg;
assign m_axi_awsize   = m_awsize_reg;
assign m_axi_awburst  = m_awburst_reg;
assign m_axi_awlock   = m_awlock_reg;
assign m_axi_awcache  = m_awcache_reg;
assign m_axi_awprot   = m_awprot_reg;
assign m_axi_awqos    = m_awqos_reg;
assign m_axi_awregion = m_awregion_reg;
assign m_axi_awuser   = AWUSER_ENABLE ? m_awuser_reg : {AWUSER_WIDTH{1'b0}};
assign m_axi_awvalid  = m_awvalid_reg;
assign m_axi_bready   = m_bready_reg;

generate
if (IS_EQUAL) begin : g_eq
    always @* begin
        fsm_next = fsm_reg;
        cur_id_next = cur_id_reg;
        cur_addr_next = cur_addr_reg;
        start_addr_next = start_addr_reg;
        wmask_next = wmask_reg;
        bkind_next = bkind_reg;
        accum_data_next = accum_data_reg;
        accum_strb_next = accum_strb_reg;
        accum_user_next = accum_user_reg;
        rem_s_next = rem_s_reg;
        s_sz_next = s_sz_reg;
        rem_m_next = rem_m_reg;
        m_sz_next = m_sz_reg;
        more_s_next = more_s_reg;
        first_b_next = first_b_reg;

        awready_next = 1'b0;
        wready_next = 1'b0;
        s_bid_next = s_bid_reg;
        s_bresp_next = s_bresp_reg;
        s_buser_next = s_buser_reg;
        s_bvalid_next = s_bvalid_reg && !s_axi_bready;
        m_awid_next = m_awid_reg;
        m_awaddr_next = m_awaddr_reg;
        m_awlen_next = m_awlen_reg;
        m_awsize_next = m_awsize_reg;
        m_awburst_next = m_awburst_reg;
        m_awlock_next = m_awlock_reg;
        m_awcache_next = m_awcache_reg;
        m_awprot_next = m_awprot_reg;
        m_awqos_next = m_awqos_reg;
        m_awregion_next = m_awregion_reg;
        m_awuser_next = m_awuser_reg;
        m_awvalid_next = m_awvalid_reg && !m_axi_awready;
        m_bready_next = 1'b0;

        push_wdata = s_axi_wdata;
        push_wstrb = s_axi_wstrb;
        push_wlast = s_axi_wlast;
        push_wuser = s_axi_wuser;
        push_wvalid = 1'b0;

        case (fsm_reg)
            WR_IDLE: begin
                awready_next = !m_axi_awvalid;
                if (s_axi_awready && s_axi_awvalid) begin
                    awready_next = 1'b0;
                    cur_id_next = s_axi_awid;
                    m_awid_next = s_axi_awid;
                    m_awaddr_next = s_axi_awaddr;
                    m_awlen_next = s_axi_awlen;
                    m_awsize_next = s_axi_awsize;
                    m_awburst_next = s_axi_awburst;
                    m_awlock_next = s_axi_awlock;
                    m_awcache_next = s_axi_awcache;
                    m_awprot_next = s_axi_awprot;
                    m_awqos_next = s_axi_awqos;
                    m_awregion_next = s_axi_awregion;
                    m_awuser_next = s_axi_awuser;
                    m_awvalid_next = 1'b1;
                    wready_next = wfifo_can_accept_next;
                    fsm_next = WR_PASSTHRU;
                end
            end
            WR_PASSTHRU: begin
                wready_next = wfifo_can_accept_next;
                if (s_axi_wready && s_axi_wvalid) begin
                    push_wvalid = 1'b1;
                    wready_next = (wfifo_cnt_after_pop + 2'd1) <= 2'd1;
                    if (s_axi_wlast) begin
                        wready_next = 1'b0;
                        m_bready_next = !s_axi_bvalid;
                        fsm_next = WR_WAIT_BRESP;
                    end
                end
            end
            WR_WAIT_BRESP: begin
                m_bready_next = !s_axi_bvalid;
                if (m_axi_bready && m_axi_bvalid) begin
                    m_bready_next = 1'b0;
                    s_bid_next = cur_id_reg;
                    s_bresp_next = m_axi_bresp;
                    s_buser_next = m_axi_buser;
                    s_bvalid_next = 1'b1;
                    awready_next = !m_axi_awvalid;
                    fsm_next = WR_IDLE;
                end
            end
            default: fsm_next = WR_IDLE;
        endcase
    end
end else if (IS_UPSIZE) begin : g_up
    localparam [ADDR_WIDTH-1:0] M_LOW_MASK = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << M_LSB) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
    integer b;
    reg [ADDR_WIDTH-1:0] s_mask_tmp;
    reg [15:0] off_tmp;
    reg [15:0] wide_len_tmp;
    reg do_wide_incr;

    always @* begin
        fsm_next = fsm_reg;
        cur_id_next = cur_id_reg;
        cur_addr_next = cur_addr_reg;
        start_addr_next = start_addr_reg;
        wmask_next = wmask_reg;
        bkind_next = bkind_reg;
        accum_data_next = accum_data_reg;
        accum_strb_next = accum_strb_reg;
        accum_user_next = accum_user_reg;
        rem_s_next = rem_s_reg;
        s_sz_next = s_sz_reg;
        rem_m_next = rem_m_reg;
        m_sz_next = m_sz_reg;
        more_s_next = more_s_reg;
        first_b_next = first_b_reg;

        awready_next = 1'b0;
        wready_next = 1'b0;
        s_bid_next = s_bid_reg;
        s_bresp_next = s_bresp_reg;
        s_buser_next = s_buser_reg;
        s_bvalid_next = s_bvalid_reg && !s_axi_bready;
        m_awid_next = m_awid_reg;
        m_awaddr_next = m_awaddr_reg;
        m_awlen_next = m_awlen_reg;
        m_awsize_next = m_awsize_reg;
        m_awburst_next = m_awburst_reg;
        m_awlock_next = m_awlock_reg;
        m_awcache_next = m_awcache_reg;
        m_awprot_next = m_awprot_reg;
        m_awqos_next = m_awqos_reg;
        m_awregion_next = m_awregion_reg;
        m_awuser_next = m_awuser_reg;
        m_awvalid_next = m_awvalid_reg && !m_axi_awready;
        m_bready_next = 1'b0;

        push_wdata = {SEG_CNT{s_axi_wdata}};
        push_wstrb = {{(M_STRB_WIDTH-S_STRB_WIDTH){1'b0}}, s_axi_wstrb};
        push_wlast = s_axi_wlast;
        push_wuser = s_axi_wuser;
        push_wvalid = 1'b0;

        wmask_next = wrap_span_mask(s_axi_awsize, s_axi_awlen);
        s_mask_tmp = ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_axi_awsize) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        off_tmp = {{(16-M_LSB){1'b0}}, s_axi_awaddr[M_LSB-1:0]} & {{(16-M_LSB){1'b1}}, s_mask_tmp[M_LSB-1:0]};
        wide_len_tmp = (off_tmp + ({8'd0, s_axi_awlen} << s_axi_awsize)) >> M_LSB;
        do_wide_incr = CONVERT_BURST && s_axi_awcache[1] &&
                       (CONVERT_NARROW_BURST || (s_axi_awsize == S_SZ_LP)) &&
                       ((s_axi_awburst == 2'b01) ||
                        ((s_axi_awburst == 2'b10) && (((s_axi_awaddr & wmask_next) == {ADDR_WIDTH{1'b0}}) || (wmask_next == M_LOW_MASK))));
        wmask_next = wmask_reg;

        case (fsm_reg)
            WR_IDLE: begin
                awready_next = !m_axi_awvalid;
                accum_data_next = {BUF_DATA_W{1'b0}};
                accum_strb_next = {BUF_STRB_W{1'b0}};
                if (s_axi_awready && s_axi_awvalid) begin
                    awready_next = 1'b0;
                    cur_id_next = s_axi_awid;
                    m_awid_next = s_axi_awid;
                    cur_addr_next = s_axi_awaddr;
                    start_addr_next = s_axi_awaddr;
                    wmask_next = wrap_span_mask(s_axi_awsize, s_axi_awlen);
                    bkind_next = s_axi_awburst;
                    rem_s_next = s_axi_awlen;
                    s_sz_next = s_axi_awsize;
                    if (do_wide_incr) begin
                        m_sz_next = M_SZ_LP;
                        m_awaddr_next = s_axi_awaddr & ~M_LOW_MASK;
                        m_awlen_next = (s_axi_awburst == 2'b10 && wmask_next == M_LOW_MASK) ? 8'd0 : wide_len_tmp[7:0];
                        m_awsize_next = M_SZ_LP;
                        m_awburst_next = 2'b01;
                        fsm_next = WR_PACK_WIDE;
                    end else begin
                        m_sz_next = s_axi_awsize;
                        m_awaddr_next = s_axi_awaddr;
                        m_awlen_next = s_axi_awlen;
                        m_awsize_next = s_axi_awsize;
                        m_awburst_next = s_axi_awburst;
                        fsm_next = WR_PASSTHRU;
                    end
                    m_awlock_next = s_axi_awlock;
                    m_awcache_next = s_axi_awcache;
                    m_awprot_next = s_axi_awprot;
                    m_awqos_next = s_axi_awqos;
                    m_awregion_next = s_axi_awregion;
                    m_awuser_next = s_axi_awuser;
                    m_awvalid_next = 1'b1;
                    wready_next = wfifo_can_accept_next;
                end
            end
            WR_PASSTHRU: begin
                wready_next = wfifo_can_accept_next;
                if (s_axi_wready && s_axi_wvalid) begin
                    push_wdata = {SEG_CNT{s_axi_wdata}};
                    push_wstrb = {{(M_STRB_WIDTH-S_STRB_WIDTH){1'b0}}, s_axi_wstrb} << (cur_addr_reg[M_LSB-1:S_LSB] * S_STRB_WIDTH);
                    push_wlast = s_axi_wlast;
                    push_wuser = s_axi_wuser;
                    push_wvalid = 1'b1;
                    cur_addr_next = advance_addr(cur_addr_reg, start_addr_reg, wmask_reg, s_sz_reg, bkind_reg);
                    wready_next = (wfifo_cnt_after_pop + 2'd1) <= 2'd1;
                    if (s_axi_wlast) begin
                        wready_next = 1'b0;
                        m_bready_next = !s_axi_bvalid;
                        fsm_next = WR_WAIT_BRESP;
                    end
                end
            end
            WR_PACK_WIDE: begin
                wready_next = wfifo_can_accept_next;
                if (s_axi_wready && s_axi_wvalid) begin
                    if (CONVERT_NARROW_BURST) begin
                        for (b = 0; b < S_STRB_WIDTH; b = b + 1) begin
                            if (s_axi_wstrb[b]) begin
                                accum_data_next[cur_addr_reg[M_LSB-1:S_LSB]*S_DATA_WIDTH + b*8 +: 8] = s_axi_wdata[b*8 +: 8];
                                accum_strb_next[cur_addr_reg[M_LSB-1:S_LSB]*S_STRB_WIDTH + b] = 1'b1;
                            end
                        end
                    end else begin
                        accum_data_next[cur_addr_reg[M_LSB-1:S_LSB]*S_DATA_WIDTH +: S_DATA_WIDTH] = s_axi_wdata;
                        accum_strb_next[cur_addr_reg[M_LSB-1:S_LSB]*S_STRB_WIDTH +: S_STRB_WIDTH] = s_axi_wstrb;
                    end
                    push_wdata = accum_data_next;
                    push_wstrb = accum_strb_next;
                    push_wlast = (rem_s_reg == 8'd0);
                    push_wuser = s_axi_wuser;
                    rem_s_next = rem_s_reg - 8'd1;
                    cur_addr_next = advance_addr(cur_addr_reg, start_addr_reg, wmask_reg, s_sz_reg, bkind_reg);

                    if (rem_s_reg == 8'd0) begin
                        accum_data_next = {BUF_DATA_W{1'b0}};
                        accum_strb_next = {BUF_STRB_W{1'b0}};
                        push_wvalid = 1'b1;
                        wready_next = 1'b0;
                        m_bready_next = !s_axi_bvalid;
                        fsm_next = WR_WAIT_BRESP;
                    end else if (cur_addr_next[M_LSB] != cur_addr_reg[M_LSB]) begin
                        accum_data_next = {BUF_DATA_W{1'b0}};
                        accum_strb_next = {BUF_STRB_W{1'b0}};
                        push_wvalid = 1'b1;
                        wready_next = (wfifo_cnt_after_pop + 2'd1) <= 2'd1;
                        fsm_next = WR_PACK_WIDE;
                    end else begin
                        wready_next = wfifo_cnt_after_pop <= 2'd1;
                        fsm_next = WR_PACK_WIDE;
                    end
                end
            end
            WR_WAIT_BRESP: begin
                m_bready_next = !s_axi_bvalid;
                if (m_axi_bready && m_axi_bvalid) begin
                    m_bready_next = 1'b0;
                    s_bid_next = cur_id_reg;
                    s_bresp_next = m_axi_bresp;
                    s_buser_next = m_axi_buser;
                    s_bvalid_next = 1'b1;
                    awready_next = !m_axi_awvalid;
                    fsm_next = WR_IDLE;
                end
            end
            default: fsm_next = WR_IDLE;
        endcase
    end
end else begin : g_dn
    function [7:0] child_len_dn;
        input [ADDR_WIDTH-1:0] a_start;
        input [ADDR_WIDTH-1:0] w_m;
        input [7:0] s_rem;
        input [2:0] s_size;
        input [1:0] b_kind;
        reg [2:0] sh;
        reg [ADDR_WIDTH-1:0] sb_mask;
        reg [ADDR_WIDTH-1:0] head_extra;
        reg [ADDR_WIDTH-1:0] to_wrap;
        reg [7:0] cap_s;
        reg [7:0] sel_s;
        begin
            sh = s_size - M_SZ_LP;
            sb_mask = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_size) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
            head_extra = (~a_start & sb_mask) >> M_LSB;
            to_wrap = (~a_start & w_m) >> s_size;
            cap_s = 8'hFF >> sh;
            if (b_kind == 2'b00)
                sel_s = 8'd0;
            else if (b_kind == 2'b10)
                sel_s = (s_rem <= to_wrap[7:0]) ? s_rem : to_wrap[7:0];
            else
                sel_s = (s_rem <= cap_s) ? s_rem : cap_s;
            child_len_dn = (sel_s << sh) | head_extra[7:0];
        end
    endfunction

    reg [ADDR_WIDTH-1:0] wm_i;
    reg [ADDR_WIDTH-1:0] m_step_a;
    reg beat_complete;

    always @* begin
        fsm_next = fsm_reg;
        cur_id_next = cur_id_reg;
        cur_addr_next = cur_addr_reg;
        start_addr_next = start_addr_reg;
        wmask_next = wmask_reg;
        bkind_next = bkind_reg;
        accum_data_next = accum_data_reg;
        accum_strb_next = accum_strb_reg;
        accum_user_next = accum_user_reg;
        rem_s_next = rem_s_reg;
        s_sz_next = s_sz_reg;
        rem_m_next = rem_m_reg;
        m_sz_next = m_sz_reg;
        more_s_next = more_s_reg;
        first_b_next = first_b_reg;

        awready_next = 1'b0;
        wready_next = 1'b0;
        s_bid_next = s_bid_reg;
        s_bresp_next = s_bresp_reg;
        s_buser_next = s_buser_reg;
        s_bvalid_next = s_bvalid_reg && !s_axi_bready;
        m_awid_next = m_awid_reg;
        m_awaddr_next = m_awaddr_reg;
        m_awlen_next = m_awlen_reg;
        m_awsize_next = m_awsize_reg;
        m_awburst_next = m_awburst_reg;
        m_awlock_next = m_awlock_reg;
        m_awcache_next = m_awcache_reg;
        m_awprot_next = m_awprot_reg;
        m_awqos_next = m_awqos_reg;
        m_awregion_next = m_awregion_reg;
        m_awuser_next = m_awuser_reg;
        m_awvalid_next = m_awvalid_reg && !m_axi_awready;
        m_bready_next = 1'b0;

        push_wdata = accum_data_reg[M_DATA_WIDTH-1:0];
        push_wstrb = accum_strb_reg[M_STRB_WIDTH-1:0];
        push_wlast = 1'b0;
        push_wuser = accum_user_reg;
        push_wvalid = 1'b0;

        wm_i = wrap_span_mask(s_axi_awsize, s_axi_awlen);
        m_step_a = (cur_addr_reg + ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << m_sz_reg)) &
                   ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << m_sz_reg) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        beat_complete = (s_sz_reg <= M_SZ_LP) || (m_step_a[{2'b00, s_sz_reg}] != cur_addr_reg[{2'b00, s_sz_reg}]);

        case (fsm_reg)
            WR_IDLE: begin
                awready_next = !m_axi_awvalid;
                first_b_next = 1'b1;
                if (s_axi_awready && s_axi_awvalid) begin
                    awready_next = 1'b0;
                    cur_id_next = s_axi_awid;
                    m_awid_next = s_axi_awid;
                    m_awaddr_next = s_axi_awaddr;
                    cur_addr_next = s_axi_awaddr;
                    start_addr_next = s_axi_awaddr;
                    wmask_next = wm_i;
                    bkind_next = s_axi_awburst;
                    rem_s_next = s_axi_awlen;
                    s_sz_next = s_axi_awsize;
                    more_s_next = 1'b1;
                    s_bresp_next = 2'd0;
                    if (s_axi_awsize > M_SZ_LP) begin
                        rem_m_next = child_len_dn(s_axi_awaddr, wm_i, s_axi_awlen, s_axi_awsize, s_axi_awburst);
                        m_sz_next = M_SZ_LP;
                        m_awlen_next = rem_m_next;
                        m_awsize_next = M_SZ_LP;
                        m_awburst_next = 2'b01;
                    end else begin
                        rem_m_next = s_axi_awlen;
                        m_sz_next = s_axi_awsize;
                        m_awlen_next = s_axi_awlen;
                        m_awsize_next = s_axi_awsize;
                        m_awburst_next = s_axi_awburst;
                    end
                    m_awlock_next = s_axi_awlock;
                    m_awcache_next = s_axi_awcache;
                    m_awprot_next = s_axi_awprot;
                    m_awqos_next = s_axi_awqos;
                    m_awregion_next = s_axi_awregion;
                    m_awuser_next = s_axi_awuser;
                    m_awvalid_next = 1'b1;
                    wready_next = wfifo_can_accept_next;
                    fsm_next = WR_SPLIT_HEAD;
                end
            end
            WR_SPLIT_HEAD: begin
                wready_next = wfifo_can_accept_next;
                if (s_axi_wready && s_axi_wvalid) begin
                    accum_data_next = s_axi_wdata;
                    accum_strb_next = s_axi_wstrb;
                    accum_user_next = s_axi_wuser;
                    push_wdata = s_axi_wdata[cur_addr_reg[S_LSB-1:M_LSB]*M_DATA_WIDTH +: M_DATA_WIDTH];
                    push_wstrb = s_axi_wstrb[cur_addr_reg[S_LSB-1:M_LSB]*M_STRB_WIDTH +: M_STRB_WIDTH];
                    push_wlast = (rem_m_reg == 8'd0);
                    push_wuser = s_axi_wuser;
                    push_wvalid = 1'b1;
                    rem_s_next = rem_s_reg - 8'd1;
                    more_s_next = (rem_s_reg != 8'd0);
                    rem_m_next = rem_m_reg - 8'd1;

                    if (s_sz_reg <= M_SZ_LP) begin
                        cur_addr_next = advance_addr(cur_addr_reg, start_addr_reg, wmask_reg, s_sz_reg, bkind_reg);
                    end else if (beat_complete) begin
                        if (bkind_reg == 2'b00)
                            cur_addr_next = start_addr_reg;
                        else if (bkind_reg == 2'b10)
                            cur_addr_next = (cur_addr_reg & ~wmask_reg) | (m_step_a & wmask_reg);
                        else
                            cur_addr_next = m_step_a;
                    end else begin
                        cur_addr_next = m_step_a;
                    end

                    if (rem_m_reg == 8'd0) begin
                        wready_next = 1'b0;
                        m_bready_next = !s_axi_bvalid && !m_axi_awvalid;
                        fsm_next = WR_WAIT_BRESP;
                    end else if (beat_complete) begin
                        wready_next = (wfifo_cnt_after_pop + 2'd1) <= 2'd1;
                        fsm_next = WR_SPLIT_HEAD;
                    end else begin
                        wready_next = 1'b0;
                        fsm_next = WR_SPLIT_TAIL;
                    end
                end
            end
            WR_SPLIT_TAIL: begin
                wready_next = 1'b0;
                if (pipe_wready_reg) begin
                    push_wdata = accum_data_reg[cur_addr_reg[S_LSB-1:M_LSB]*M_DATA_WIDTH +: M_DATA_WIDTH];
                    push_wstrb = accum_strb_reg[cur_addr_reg[S_LSB-1:M_LSB]*M_STRB_WIDTH +: M_STRB_WIDTH];
                    push_wlast = (rem_m_reg == 8'd0);
                    push_wuser = accum_user_reg;
                    push_wvalid = 1'b1;
                    rem_m_next = rem_m_reg - 8'd1;

                    if (beat_complete) begin
                        if (bkind_reg == 2'b00)
                            cur_addr_next = start_addr_reg;
                        else if (bkind_reg == 2'b10)
                            cur_addr_next = (cur_addr_reg & ~wmask_reg) | (m_step_a & wmask_reg);
                        else
                            cur_addr_next = m_step_a;
                    end else begin
                        cur_addr_next = m_step_a;
                    end

                    if (rem_m_reg == 8'd0) begin
                        wready_next = 1'b0;
                        m_bready_next = !s_axi_bvalid && !m_axi_awvalid;
                        fsm_next = WR_WAIT_BRESP;
                    end else if (beat_complete) begin
                        wready_next = (wfifo_cnt_after_pop + 2'd1) <= 2'd1;
                        fsm_next = WR_SPLIT_HEAD;
                    end else begin
                        fsm_next = WR_SPLIT_TAIL;
                    end
                end
            end
            WR_WAIT_BRESP: begin
                m_bready_next = !s_axi_bvalid && !m_axi_awvalid;
                if (m_axi_bready && m_axi_bvalid) begin
                    first_b_next = 1'b0;
                    m_bready_next = 1'b0;
                    s_bid_next = cur_id_reg;
                    if (first_b_reg) begin
                        s_bresp_next = m_axi_bresp;
                        s_buser_next = m_axi_buser;
                    end else if (m_axi_bresp > s_bresp_reg) begin
                        s_bresp_next = m_axi_bresp;
                        s_buser_next = m_axi_buser;
                    end

                    if (more_s_reg) begin
                        rem_m_next = child_len_dn(cur_addr_reg, wmask_reg, rem_s_reg, s_sz_reg, bkind_reg);
                        m_sz_next = M_SZ_LP;
                        m_awaddr_next = cur_addr_reg;
                        m_awlen_next = rem_m_next;
                        m_awsize_next = M_SZ_LP;
                        m_awburst_next = 2'b01;
                        m_awvalid_next = 1'b1;
                        wready_next = wfifo_can_accept_next;
                        fsm_next = WR_SPLIT_HEAD;
                    end else begin
                        s_bvalid_next = 1'b1;
                        awready_next = !m_axi_awvalid;
                        fsm_next = WR_IDLE;
                    end
                end
            end
            default: fsm_next = WR_IDLE;
        endcase
    end
end
endgenerate

always @(posedge clk) begin
    fsm_reg <= fsm_next;
    cur_id_reg <= cur_id_next;
    cur_addr_reg <= cur_addr_next;
    start_addr_reg <= start_addr_next;
    wmask_reg <= wmask_next;
    bkind_reg <= bkind_next;
    accum_data_reg <= accum_data_next;
    accum_strb_reg <= accum_strb_next;
    accum_user_reg <= accum_user_next;
    rem_s_reg <= rem_s_next;
    s_sz_reg <= s_sz_next;
    rem_m_reg <= rem_m_next;
    m_sz_reg <= m_sz_next;
    more_s_reg <= more_s_next;
    first_b_reg <= first_b_next;

    awready_reg <= awready_next;
    wready_reg <= wready_next;
    s_bid_reg <= s_bid_next;
    s_bresp_reg <= s_bresp_next;
    s_buser_reg <= s_buser_next;
    s_bvalid_reg <= s_bvalid_next;

    m_awid_reg <= m_awid_next;
    m_awaddr_reg <= m_awaddr_next;
    m_awlen_reg <= m_awlen_next;
    m_awsize_reg <= m_awsize_next;
    m_awburst_reg <= m_awburst_next;
    m_awlock_reg <= m_awlock_next;
    m_awcache_reg <= m_awcache_next;
    m_awprot_reg <= m_awprot_next;
    m_awqos_reg <= m_awqos_next;
    m_awregion_reg <= m_awregion_next;
    m_awuser_reg <= m_awuser_next;
    m_awvalid_reg <= m_awvalid_next;
    m_bready_reg <= m_bready_next;

    if (rst) begin
        fsm_reg <= WR_IDLE;
        awready_reg <= 1'b0;
        wready_reg <= 1'b0;
        s_bvalid_reg <= 1'b0;
        m_awvalid_reg <= 1'b0;
        m_bready_reg <= 1'b0;
    end
end

endmodule

`resetall
