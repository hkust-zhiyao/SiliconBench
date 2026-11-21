/*
 * Copyright (c) 2018 Alex Forencich
 * SPDX-License-Identifier: MIT
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

module axi_adapter_rd #
(
    parameter ADDR_WIDTH = 32,
    parameter S_DATA_WIDTH = 32,
    parameter S_STRB_WIDTH = (S_DATA_WIDTH/8),
    parameter M_DATA_WIDTH = 32,
    parameter M_STRB_WIDTH = (M_DATA_WIDTH/8),
    parameter ID_WIDTH = 8,
    parameter ARUSER_ENABLE = 0,
    parameter ARUSER_WIDTH = 1,
    parameter RUSER_ENABLE = 0,
    parameter RUSER_WIDTH = 1,
    parameter CONVERT_BURST = 1,
    parameter CONVERT_NARROW_BURST = 0,
    parameter FORWARD_ID = 0
)
(
    input  wire                     clk,
    input  wire                     rst,

    input  wire [ID_WIDTH-1:0]      s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire [7:0]               s_axi_arlen,
    input  wire [2:0]               s_axi_arsize,
    input  wire [1:0]               s_axi_arburst,
    input  wire                     s_axi_arlock,
    input  wire [3:0]               s_axi_arcache,
    input  wire [2:0]               s_axi_arprot,
    input  wire [3:0]               s_axi_arqos,
    input  wire [3:0]               s_axi_arregion,
    input  wire [ARUSER_WIDTH-1:0]  s_axi_aruser,
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,
    output wire [ID_WIDTH-1:0]      s_axi_rid,
    output wire [S_DATA_WIDTH-1:0]  s_axi_rdata,
    output wire [1:0]               s_axi_rresp,
    output wire                     s_axi_rlast,
    output wire [RUSER_WIDTH-1:0]   s_axi_ruser,
    output wire                     s_axi_rvalid,
    input  wire                     s_axi_rready,

    output wire [ID_WIDTH-1:0]      m_axi_arid,
    output wire [ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]               m_axi_arlen,
    output wire [2:0]               m_axi_arsize,
    output wire [1:0]               m_axi_arburst,
    output wire                     m_axi_arlock,
    output wire [3:0]               m_axi_arcache,
    output wire [2:0]               m_axi_arprot,
    output wire [3:0]               m_axi_arqos,
    output wire [3:0]               m_axi_arregion,
    output wire [ARUSER_WIDTH-1:0]  m_axi_aruser,
    output wire                     m_axi_arvalid,
    input  wire                     m_axi_arready,
    input  wire [ID_WIDTH-1:0]      m_axi_rid,
    input  wire [M_DATA_WIDTH-1:0]  m_axi_rdata,
    input  wire [1:0]               m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire [RUSER_WIDTH-1:0]   m_axi_ruser,
    input  wire                     m_axi_rvalid,
    output wire                     m_axi_rready
);

localparam S_LSB = $clog2(S_STRB_WIDTH);
localparam M_LSB = $clog2(M_STRB_WIDTH);
localparam [2:0] S_SZ_LP = S_LSB[2:0];
localparam [2:0] M_SZ_LP = M_LSB[2:0];
localparam IS_UPSIZE = (M_STRB_WIDTH > S_STRB_WIDTH);
localparam IS_EQUAL  = (M_STRB_WIDTH == S_STRB_WIDTH);
localparam BUF_DATA_W = IS_UPSIZE ? M_DATA_WIDTH : S_DATA_WIDTH;

localparam [2:0]
    RD_IDLE         = 3'd0,
    RD_PASSTHRU     = 3'd1,
    RD_FETCH_WIDE   = 3'd2,
    RD_DRAIN_SLICE  = 3'd3,
    RD_MERGE_NARROW = 3'd4;

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

// 2-entry circular output FIFO for R channel
reg [ID_WIDTH-1:0]     rfifo_id   [0:1];
reg [S_DATA_WIDTH-1:0] rfifo_data [0:1];
reg [1:0]              rfifo_resp [0:1];
reg                    rfifo_last [0:1];
reg [RUSER_WIDTH-1:0]  rfifo_user [0:1];
reg                    rfifo_wptr = 1'b0;
reg                    rfifo_rptr = 1'b0;
reg [1:0]              rfifo_cnt  = 2'd0;

reg  [ID_WIDTH-1:0]     push_rid;
reg  [S_DATA_WIDTH-1:0] push_rdata;
reg  [1:0]              push_rresp;
reg                     push_rlast;
reg  [RUSER_WIDTH-1:0]  push_ruser;
reg                     push_rvalid;

wire pop_r = s_axi_rvalid && s_axi_rready;
wire [1:0] rfifo_cnt_after_pop = rfifo_cnt - {1'b0, pop_r};
wire rfifo_can_accept_next = (rfifo_cnt_after_pop + {1'b0, push_rvalid}) <= 2'd1;
reg  pipe_rready_reg = 1'b0;

assign s_axi_rvalid = (rfifo_cnt != 2'd0);
assign s_axi_rid    = rfifo_id[rfifo_rptr];
assign s_axi_rdata  = rfifo_data[rfifo_rptr];
assign s_axi_rresp  = rfifo_resp[rfifo_rptr];
assign s_axi_rlast  = rfifo_last[rfifo_rptr];
assign s_axi_ruser  = RUSER_ENABLE ? rfifo_user[rfifo_rptr] : {RUSER_WIDTH{1'b0}};

always @(posedge clk) begin
    if (rst) begin
        rfifo_wptr <= 1'b0;
        rfifo_rptr <= 1'b0;
        rfifo_cnt  <= 2'd0;
        pipe_rready_reg <= 1'b0;
    end else begin
        pipe_rready_reg <= rfifo_can_accept_next;
        if (push_rvalid) begin
            rfifo_id[rfifo_wptr]   <= push_rid;
            rfifo_data[rfifo_wptr] <= push_rdata;
            rfifo_resp[rfifo_wptr] <= push_rresp;
            rfifo_last[rfifo_wptr] <= push_rlast;
            rfifo_user[rfifo_wptr] <= push_ruser;
            rfifo_wptr <= ~rfifo_wptr;
        end
        if (pop_r) begin
            rfifo_rptr <= ~rfifo_rptr;
        end
        case ({push_rvalid, pop_r})
            2'b10: rfifo_cnt <= rfifo_cnt + 2'd1;
            2'b01: rfifo_cnt <= rfifo_cnt - 2'd1;
            default: rfifo_cnt <= rfifo_cnt;
        endcase
    end
end

reg [2:0] fsm_reg = RD_IDLE, fsm_next;
reg [ID_WIDTH-1:0] cur_id_reg = {ID_WIDTH{1'b0}}, cur_id_next;
reg [ADDR_WIDTH-1:0] cur_addr_reg = {ADDR_WIDTH{1'b0}}, cur_addr_next;
reg [ADDR_WIDTH-1:0] start_addr_reg = {ADDR_WIDTH{1'b0}}, start_addr_next;
reg [ADDR_WIDTH-1:0] wmask_reg = {ADDR_WIDTH{1'b0}}, wmask_next;
reg [1:0] bkind_reg = 2'd0, bkind_next;
reg [BUF_DATA_W-1:0] hold_data_reg = {BUF_DATA_W{1'b0}}, hold_data_next;
reg [1:0] hold_resp_reg = 2'd0, hold_resp_next;
reg [RUSER_WIDTH-1:0] hold_user_reg = {RUSER_WIDTH{1'b0}}, hold_user_next;
reg [7:0] rem_s_reg = 8'd0, rem_s_next;
reg [2:0] s_sz_reg = 3'd0, s_sz_next;
reg [7:0] rem_m_reg = 8'd0, rem_m_next;
reg [2:0] m_sz_reg = 3'd0, m_sz_next;

reg arready_reg = 1'b0, arready_next;
reg [ID_WIDTH-1:0] m_arid_reg = {ID_WIDTH{1'b0}}, m_arid_next;
reg [ADDR_WIDTH-1:0] m_araddr_reg = {ADDR_WIDTH{1'b0}}, m_araddr_next;
reg [7:0] m_arlen_reg = 8'd0, m_arlen_next;
reg [2:0] m_arsize_reg = 3'd0, m_arsize_next;
reg [1:0] m_arburst_reg = 2'd0, m_arburst_next;
reg m_arlock_reg = 1'b0, m_arlock_next;
reg [3:0] m_arcache_reg = 4'd0, m_arcache_next;
reg [2:0] m_arprot_reg = 3'd0, m_arprot_next;
reg [3:0] m_arqos_reg = 4'd0, m_arqos_next;
reg [3:0] m_arregion_reg = 4'd0, m_arregion_next;
reg [ARUSER_WIDTH-1:0] m_aruser_reg = {ARUSER_WIDTH{1'b0}}, m_aruser_next;
reg m_arvalid_reg = 1'b0, m_arvalid_next;
reg m_rready_reg = 1'b0, m_rready_next;

assign s_axi_arready = arready_reg;
assign m_axi_arid = FORWARD_ID ? m_arid_reg : {ID_WIDTH{1'b0}};
assign m_axi_araddr = m_araddr_reg;
assign m_axi_arlen = m_arlen_reg;
assign m_axi_arsize = m_arsize_reg;
assign m_axi_arburst = m_arburst_reg;
assign m_axi_arlock = m_arlock_reg;
assign m_axi_arcache = m_arcache_reg;
assign m_axi_arprot = m_arprot_reg;
assign m_axi_arqos = m_arqos_reg;
assign m_axi_arregion = m_arregion_reg;
assign m_axi_aruser = ARUSER_ENABLE ? m_aruser_reg : {ARUSER_WIDTH{1'b0}};
assign m_axi_arvalid = m_arvalid_reg;
assign m_axi_rready = m_rready_reg;

generate
if (IS_EQUAL) begin : g_eq
    always @* begin
        fsm_next = fsm_reg;
        cur_id_next = cur_id_reg;
        cur_addr_next = cur_addr_reg;
        start_addr_next = start_addr_reg;
        wmask_next = wmask_reg;
        bkind_next = bkind_reg;
        hold_data_next = hold_data_reg;
        hold_resp_next = hold_resp_reg;
        hold_user_next = hold_user_reg;
        rem_s_next = rem_s_reg;
        s_sz_next = s_sz_reg;
        rem_m_next = rem_m_reg;
        m_sz_next = m_sz_reg;

        arready_next = 1'b0;
        m_arid_next = m_arid_reg;
        m_araddr_next = m_araddr_reg;
        m_arlen_next = m_arlen_reg;
        m_arsize_next = m_arsize_reg;
        m_arburst_next = m_arburst_reg;
        m_arlock_next = m_arlock_reg;
        m_arcache_next = m_arcache_reg;
        m_arprot_next = m_arprot_reg;
        m_arqos_next = m_arqos_reg;
        m_arregion_next = m_arregion_reg;
        m_aruser_next = m_aruser_reg;
        m_arvalid_next = m_arvalid_reg && !m_axi_arready;
        m_rready_next = 1'b0;

        push_rid = cur_id_reg;
        push_rdata = m_axi_rdata;
        push_rresp = m_axi_rresp;
        push_rlast = m_axi_rlast;
        push_ruser = m_axi_ruser;
        push_rvalid = 1'b0;

        case (fsm_reg)
            RD_IDLE: begin
                arready_next = !m_axi_arvalid;
                if (s_axi_arready && s_axi_arvalid) begin
                    arready_next = 1'b0;
                    cur_id_next = s_axi_arid;
                    m_arid_next = s_axi_arid;
                    m_araddr_next = s_axi_araddr;
                    m_arlen_next = s_axi_arlen;
                    m_arsize_next = s_axi_arsize;
                    m_arburst_next = s_axi_arburst;
                    m_arlock_next = s_axi_arlock;
                    m_arcache_next = s_axi_arcache;
                    m_arprot_next = s_axi_arprot;
                    m_arqos_next = s_axi_arqos;
                    m_arregion_next = s_axi_arregion;
                    m_aruser_next = s_axi_aruser;
                    m_arvalid_next = 1'b1;
                    m_rready_next = rfifo_can_accept_next;
                    fsm_next = RD_PASSTHRU;
                end
            end
            RD_PASSTHRU: begin
                m_rready_next = rfifo_can_accept_next;
                if (m_axi_rready && m_axi_rvalid) begin
                    push_rvalid = 1'b1;
                    m_rready_next = (rfifo_cnt_after_pop + 2'd1) <= 2'd1;
                    if (m_axi_rlast) begin
                        m_rready_next = 1'b0;
                        arready_next = !m_axi_arvalid;
                        fsm_next = RD_IDLE;
                    end
                end
            end
            default: fsm_next = RD_IDLE;
        endcase
    end
end else if (IS_UPSIZE) begin : g_up
    localparam [ADDR_WIDTH-1:0] M_LOW_MASK = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << M_LSB) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
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
        hold_data_next = hold_data_reg;
        hold_resp_next = hold_resp_reg;
        hold_user_next = hold_user_reg;
        rem_s_next = rem_s_reg;
        s_sz_next = s_sz_reg;
        rem_m_next = rem_m_reg;
        m_sz_next = m_sz_reg;

        arready_next = 1'b0;
        m_arid_next = m_arid_reg;
        m_araddr_next = m_araddr_reg;
        m_arlen_next = m_arlen_reg;
        m_arsize_next = m_arsize_reg;
        m_arburst_next = m_arburst_reg;
        m_arlock_next = m_arlock_reg;
        m_arcache_next = m_arcache_reg;
        m_arprot_next = m_arprot_reg;
        m_arqos_next = m_arqos_reg;
        m_arregion_next = m_arregion_reg;
        m_aruser_next = m_aruser_reg;
        m_arvalid_next = m_arvalid_reg && !m_axi_arready;
        m_rready_next = 1'b0;

        push_rid = cur_id_reg;
        push_rdata = m_axi_rdata[S_DATA_WIDTH-1:0];
        push_rresp = m_axi_rresp;
        push_rlast = m_axi_rlast;
        push_ruser = m_axi_ruser;
        push_rvalid = 1'b0;

        wmask_next = wrap_span_mask(s_axi_arsize, s_axi_arlen);
        s_mask_tmp = ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_axi_arsize) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        off_tmp = {{(16-M_LSB){1'b0}}, s_axi_araddr[M_LSB-1:0]} & {{(16-M_LSB){1'b1}}, s_mask_tmp[M_LSB-1:0]};
        wide_len_tmp = (off_tmp + ({8'd0, s_axi_arlen} << s_axi_arsize)) >> M_LSB;
        do_wide_incr = CONVERT_BURST && s_axi_arcache[1] &&
                       (CONVERT_NARROW_BURST || (s_axi_arsize == S_SZ_LP)) &&
                       ((s_axi_arburst == 2'b01) ||
                        ((s_axi_arburst == 2'b10) && (((s_axi_araddr & wmask_next) == {ADDR_WIDTH{1'b0}}) || (wmask_next == M_LOW_MASK))));
        wmask_next = wmask_reg;

        case (fsm_reg)
            RD_IDLE: begin
                arready_next = !m_axi_arvalid;
                if (s_axi_arready && s_axi_arvalid) begin
                    arready_next = 1'b0;
                    cur_id_next = s_axi_arid;
                    m_arid_next = s_axi_arid;
                    cur_addr_next = s_axi_araddr;
                    start_addr_next = s_axi_araddr;
                    wmask_next = wrap_span_mask(s_axi_arsize, s_axi_arlen);
                    bkind_next = s_axi_arburst;
                    rem_s_next = s_axi_arlen;
                    s_sz_next = s_axi_arsize;
                    if (do_wide_incr) begin
                        m_sz_next = M_SZ_LP;
                        m_araddr_next = s_axi_araddr & ~M_LOW_MASK;
                        m_arlen_next = (s_axi_arburst == 2'b10 && wmask_next == M_LOW_MASK) ? 8'd0 : wide_len_tmp[7:0];
                        m_arsize_next = M_SZ_LP;
                        m_arburst_next = 2'b01;
                        fsm_next = RD_FETCH_WIDE;
                    end else begin
                        m_sz_next = s_axi_arsize;
                        m_araddr_next = s_axi_araddr;
                        m_arlen_next = s_axi_arlen;
                        m_arsize_next = s_axi_arsize;
                        m_arburst_next = s_axi_arburst;
                        fsm_next = RD_PASSTHRU;
                    end
                    m_arlock_next = s_axi_arlock;
                    m_arcache_next = s_axi_arcache;
                    m_arprot_next = s_axi_arprot;
                    m_arqos_next = s_axi_arqos;
                    m_arregion_next = s_axi_arregion;
                    m_aruser_next = s_axi_aruser;
                    m_arvalid_next = 1'b1;
                    m_rready_next = rfifo_can_accept_next;
                end
            end
            RD_PASSTHRU: begin
                m_rready_next = rfifo_can_accept_next;
                if (m_axi_rready && m_axi_rvalid) begin
                    push_rdata = m_axi_rdata[cur_addr_reg[M_LSB-1:S_LSB]*S_DATA_WIDTH +: S_DATA_WIDTH];
                    push_rresp = m_axi_rresp;
                    push_rlast = m_axi_rlast;
                    push_ruser = m_axi_ruser;
                    push_rvalid = 1'b1;
                    cur_addr_next = advance_addr(cur_addr_reg, start_addr_reg, wmask_reg, s_sz_reg, bkind_reg);
                    m_rready_next = (rfifo_cnt_after_pop + 2'd1) <= 2'd1;
                    if (m_axi_rlast) begin
                        m_rready_next = 1'b0;
                        arready_next = !m_axi_arvalid;
                        fsm_next = RD_IDLE;
                    end
                end
            end
            RD_FETCH_WIDE: begin
                m_rready_next = rfifo_can_accept_next;
                if (m_axi_rready && m_axi_rvalid) begin
                    hold_data_next = m_axi_rdata;
                    hold_resp_next = m_axi_rresp;
                    hold_user_next = m_axi_ruser;
                    push_rdata = m_axi_rdata[cur_addr_reg[M_LSB-1:S_LSB]*S_DATA_WIDTH +: S_DATA_WIDTH];
                    push_rresp = m_axi_rresp;
                    push_rlast = (rem_s_reg == 8'd0);
                    push_ruser = m_axi_ruser;
                    push_rvalid = 1'b1;
                    rem_s_next = rem_s_reg - 8'd1;
                    cur_addr_next = advance_addr(cur_addr_reg, start_addr_reg, wmask_reg, s_sz_reg, bkind_reg);
                    if (rem_s_reg == 8'd0) begin
                        m_rready_next = 1'b0;
                        arready_next = !m_axi_arvalid;
                        fsm_next = RD_IDLE;
                    end else if (cur_addr_next[M_LSB] != cur_addr_reg[M_LSB]) begin
                        m_rready_next = (rfifo_cnt_after_pop + 2'd1) <= 2'd1;
                        fsm_next = RD_FETCH_WIDE;
                    end else begin
                        m_rready_next = 1'b0;
                        fsm_next = RD_DRAIN_SLICE;
                    end
                end
            end
            RD_DRAIN_SLICE: begin
                m_rready_next = 1'b0;
                if (pipe_rready_reg) begin
                    push_rdata = hold_data_reg[cur_addr_reg[M_LSB-1:S_LSB]*S_DATA_WIDTH +: S_DATA_WIDTH];
                    push_rresp = hold_resp_reg;
                    push_rlast = (rem_s_reg == 8'd0);
                    push_ruser = hold_user_reg;
                    push_rvalid = 1'b1;
                    rem_s_next = rem_s_reg - 8'd1;
                    cur_addr_next = advance_addr(cur_addr_reg, start_addr_reg, wmask_reg, s_sz_reg, bkind_reg);
                    if (rem_s_reg == 8'd0) begin
                        arready_next = !m_axi_arvalid;
                        fsm_next = RD_IDLE;
                    end else if (cur_addr_next[M_LSB] != cur_addr_reg[M_LSB]) begin
                        m_rready_next = (rfifo_cnt_after_pop + 2'd1) <= 2'd1;
                        fsm_next = RD_FETCH_WIDE;
                    end else begin
                        fsm_next = RD_DRAIN_SLICE;
                    end
                end
            end
            default: fsm_next = RD_IDLE;
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
        hold_data_next = hold_data_reg;
        hold_resp_next = hold_resp_reg;
        hold_user_next = hold_user_reg;
        rem_s_next = rem_s_reg;
        s_sz_next = s_sz_reg;
        rem_m_next = rem_m_reg;
        m_sz_next = m_sz_reg;

        arready_next = 1'b0;
        m_arid_next = m_arid_reg;
        m_araddr_next = m_araddr_reg;
        m_arlen_next = m_arlen_reg;
        m_arsize_next = m_arsize_reg;
        m_arburst_next = m_arburst_reg;
        m_arlock_next = m_arlock_reg;
        m_arcache_next = m_arcache_reg;
        m_arprot_next = m_arprot_reg;
        m_arqos_next = m_arqos_reg;
        m_arregion_next = m_arregion_reg;
        m_aruser_next = m_aruser_reg;
        m_arvalid_next = m_arvalid_reg && !m_axi_arready;
        m_rready_next = 1'b0;

        push_rid = cur_id_reg;
        push_rdata = hold_data_reg;
        push_rresp = hold_resp_reg;
        push_rlast = 1'b0;
        push_ruser = m_axi_ruser;
        push_rvalid = 1'b0;

        wm_i = wrap_span_mask(s_axi_arsize, s_axi_arlen);
        m_step_a = (cur_addr_reg + ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << m_sz_reg)) &
                   ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << m_sz_reg) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        beat_complete = (s_sz_reg <= M_SZ_LP) || (m_step_a[{2'b00, s_sz_reg}] != cur_addr_reg[{2'b00, s_sz_reg}]);

        case (fsm_reg)
            RD_IDLE: begin
                arready_next = !m_axi_arvalid;
                hold_data_next = {BUF_DATA_W{1'b0}};
                hold_resp_next = 2'd0;
                if (s_axi_arready && s_axi_arvalid) begin
                    arready_next = 1'b0;
                    cur_id_next = s_axi_arid;
                    m_arid_next = s_axi_arid;
                    m_araddr_next = s_axi_araddr;
                    cur_addr_next = s_axi_araddr;
                    start_addr_next = s_axi_araddr;
                    wmask_next = wm_i;
                    bkind_next = s_axi_arburst;
                    rem_s_next = s_axi_arlen;
                    s_sz_next = s_axi_arsize;
                    if (s_axi_arsize > M_SZ_LP) begin
                        rem_m_next = child_len_dn(s_axi_araddr, wm_i, s_axi_arlen, s_axi_arsize, s_axi_arburst);
                        m_sz_next = M_SZ_LP;
                        m_arlen_next = rem_m_next;
                        m_arsize_next = M_SZ_LP;
                        m_arburst_next = 2'b01;
                    end else begin
                        rem_m_next = s_axi_arlen;
                        m_sz_next = s_axi_arsize;
                        m_arlen_next = s_axi_arlen;
                        m_arsize_next = s_axi_arsize;
                        m_arburst_next = s_axi_arburst;
                    end
                    m_arlock_next = s_axi_arlock;
                    m_arcache_next = s_axi_arcache;
                    m_arprot_next = s_axi_arprot;
                    m_arqos_next = s_axi_arqos;
                    m_arregion_next = s_axi_arregion;
                    m_aruser_next = s_axi_aruser;
                    m_arvalid_next = 1'b1;
                    m_rready_next = 1'b0;
                    fsm_next = RD_MERGE_NARROW;
                end
            end
            RD_MERGE_NARROW: begin
                m_rready_next = rfifo_can_accept_next && !m_axi_arvalid;
                if (m_axi_rready && m_axi_rvalid) begin
                    hold_data_next[cur_addr_reg[S_LSB-1:M_LSB]*M_DATA_WIDTH +: M_DATA_WIDTH] = m_axi_rdata;
                    if (m_axi_rresp > hold_resp_reg) begin
                        hold_resp_next = m_axi_rresp;
                    end
                    push_rdata = hold_data_next;
                    push_rresp = hold_resp_next;
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
                    m_araddr_next = cur_addr_next;

                    if (beat_complete) begin
                        hold_data_next = {BUF_DATA_W{1'b0}};
                        hold_resp_next = 2'd0;
                        rem_s_next = rem_s_reg - 8'd1;
                        push_rvalid = 1'b1;
                    end

                    m_rready_next = ((rfifo_cnt_after_pop + {1'b0, push_rvalid}) <= 2'd1) && !m_axi_arvalid;

                    if (rem_m_reg == 8'd0) begin
                        if (rem_s_reg == 8'd0) begin
                            m_rready_next = 1'b0;
                            push_rlast = 1'b1;
                            push_rvalid = 1'b1;
                            arready_next = !m_axi_arvalid;
                            fsm_next = RD_IDLE;
                        end else begin
                            rem_m_next = child_len_dn(cur_addr_next, wmask_reg, rem_s_next, s_sz_reg, bkind_reg);
                            m_arlen_next = rem_m_next;
                            m_arvalid_next = 1'b1;
                            m_rready_next = 1'b0;
                            fsm_next = RD_MERGE_NARROW;
                        end
                    end
                end
            end
            default: fsm_next = RD_IDLE;
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
    hold_data_reg <= hold_data_next;
    hold_resp_reg <= hold_resp_next;
    hold_user_reg <= hold_user_next;
    rem_s_reg <= rem_s_next;
    s_sz_reg <= s_sz_next;
    rem_m_reg <= rem_m_next;
    m_sz_reg <= m_sz_next;

    arready_reg <= arready_next;
    m_arid_reg <= m_arid_next;
    m_araddr_reg <= m_araddr_next;
    m_arlen_reg <= m_arlen_next;
    m_arsize_reg <= m_arsize_next;
    m_arburst_reg <= m_arburst_next;
    m_arlock_reg <= m_arlock_next;
    m_arcache_reg <= m_arcache_next;
    m_arprot_reg <= m_arprot_next;
    m_arqos_reg <= m_arqos_next;
    m_arregion_reg <= m_arregion_next;
    m_aruser_reg <= m_aruser_next;
    m_arvalid_reg <= m_arvalid_next;
    m_rready_reg <= m_rready_next;

    if (rst) begin
        fsm_reg <= RD_IDLE;
        arready_reg <= 1'b0;
        m_arvalid_reg <= 1'b0;
        m_rready_reg <= 1'b0;
    end
end

endmodule

`resetall
