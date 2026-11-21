/*

Copyright (c) 2018 Alex Forencich

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
 * AXI4 width adapter (write channel)
 */
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

    /*
     * AXI slave interface
     */
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

    /*
     * AXI master interface
     */
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

parameter S_ADDR_BIT_OFFSET = $clog2(S_STRB_WIDTH);
parameter M_ADDR_BIT_OFFSET = $clog2(M_STRB_WIDTH);
parameter S_WORD_WIDTH = S_STRB_WIDTH;
parameter M_WORD_WIDTH = M_STRB_WIDTH;
parameter S_WORD_SIZE = S_DATA_WIDTH/S_WORD_WIDTH;
parameter M_WORD_SIZE = M_DATA_WIDTH/M_WORD_WIDTH;
parameter S_BURST_SIZE = $clog2(S_STRB_WIDTH);
parameter M_BURST_SIZE = $clog2(M_STRB_WIDTH);

parameter EXPAND = M_STRB_WIDTH > S_STRB_WIDTH;
parameter DATA_WIDTH = EXPAND ? M_DATA_WIDTH : S_DATA_WIDTH;
parameter STRB_WIDTH = EXPAND ? M_STRB_WIDTH : S_STRB_WIDTH;
parameter SEGMENT_COUNT = EXPAND ? (M_STRB_WIDTH / S_STRB_WIDTH) : (S_STRB_WIDTH / M_STRB_WIDTH);
parameter SEGMENT_DATA_WIDTH = DATA_WIDTH / SEGMENT_COUNT;
parameter SEGMENT_STRB_WIDTH = STRB_WIDTH / SEGMENT_COUNT;

localparam [2:0] S_BURST_SIZE_LP = S_BURST_SIZE[2:0];
localparam [2:0] M_BURST_SIZE_LP = M_BURST_SIZE[2:0];

// bus width assertions
initial begin
    if (S_WORD_SIZE * S_STRB_WIDTH != S_DATA_WIDTH) begin
        $error("Error: AXI slave interface data width not evenly divisble (instance %m)");
        $finish;
    end

    if (M_WORD_SIZE * M_STRB_WIDTH != M_DATA_WIDTH) begin
        $error("Error: AXI master interface data width not evenly divisble (instance %m)");
        $finish;
    end

    if (S_WORD_SIZE != M_WORD_SIZE) begin
        $error("Error: word size mismatch (instance %m)");
        $finish;
    end

    if (2**$clog2(S_WORD_WIDTH) != S_WORD_WIDTH) begin
        $error("Error: AXI slave interface word width must be even power of two (instance %m)");
        $finish;
    end

    if (2**$clog2(M_WORD_WIDTH) != M_WORD_WIDTH) begin
        $error("Error: AXI master interface word width must be even power of two (instance %m)");
        $finish;
    end
end

localparam [1:0]
    STATE_IDLE = 2'd0,
    STATE_DATA = 2'd1,
    STATE_DATA_2 = 2'd2,
    STATE_RESP = 2'd3;

function [ADDR_WIDTH-1:0] calc_wrap_mask;
    input [2:0] sz;
    input [7:0] len;
    reg [ADDR_WIDTH-1:0] beat_bytes;
    begin
        beat_bytes = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << sz);
        case (len)
            8'd1:    calc_wrap_mask = (beat_bytes << 1) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
            8'd3:    calc_wrap_mask = (beat_bytes << 2) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
            8'd7:    calc_wrap_mask = (beat_bytes << 3) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
            default: calc_wrap_mask = (beat_bytes << 4) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
        endcase
    end
endfunction

function [ADDR_WIDTH-1:0] step_slave_addr;
    input [ADDR_WIDTH-1:0] cur_addr;
    input [ADDR_WIDTH-1:0] orig_addr;
    input [ADDR_WIDTH-1:0] wmask;
    input [2:0] sz;
    input [1:0] btype;
    reg [ADDR_WIDTH-1:0] beat_step;
    reg [ADDR_WIDTH-1:0] align_mask;
    reg [ADDR_WIDTH-1:0] inc_aligned;
    begin
        beat_step = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << sz);
        align_mask = ~(beat_step - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        inc_aligned = (cur_addr + beat_step) & align_mask;
        case (btype)
            2'b00:   step_slave_addr = orig_addr;
            2'b10:   step_slave_addr = (cur_addr & ~wmask) | (inc_aligned & wmask);
            default: step_slave_addr = inc_aligned;
        endcase
    end
endfunction

reg [1:0] state_reg = STATE_IDLE, state_next;

reg [ID_WIDTH-1:0] id_reg = {ID_WIDTH{1'b0}}, id_next;
reg [ADDR_WIDTH-1:0] addr_reg = {ADDR_WIDTH{1'b0}}, addr_next;
reg [ADDR_WIDTH-1:0] orig_addr_reg = {ADDR_WIDTH{1'b0}}, orig_addr_next;
reg [ADDR_WIDTH-1:0] wrap_mask_reg = {ADDR_WIDTH{1'b0}}, wrap_mask_next;
reg [1:0] burst_type_reg = 2'd0, burst_type_next;
reg [DATA_WIDTH-1:0] data_reg = {DATA_WIDTH{1'b0}}, data_next;
reg [STRB_WIDTH-1:0] strb_reg = {STRB_WIDTH{1'b0}}, strb_next;
reg [WUSER_WIDTH-1:0] wuser_reg = {WUSER_WIDTH{1'b0}}, wuser_next;
reg [7:0] burst_reg = 8'd0, burst_next;
reg [2:0] burst_size_reg = 3'd0, burst_size_next;
reg [7:0] master_burst_reg = 8'd0, master_burst_next;
reg [2:0] master_burst_size_reg = 3'd0, master_burst_size_next;
reg burst_active_reg = 1'b0, burst_active_next;
reg first_transfer_reg = 1'b0, first_transfer_next;

reg s_axi_awready_reg = 1'b0, s_axi_awready_next;
reg s_axi_wready_reg = 1'b0, s_axi_wready_next;
reg [ID_WIDTH-1:0] s_axi_bid_reg = {ID_WIDTH{1'b0}}, s_axi_bid_next;
reg [1:0] s_axi_bresp_reg = 2'd0, s_axi_bresp_next;
reg [BUSER_WIDTH-1:0] s_axi_buser_reg = {BUSER_WIDTH{1'b0}}, s_axi_buser_next;
reg s_axi_bvalid_reg = 1'b0, s_axi_bvalid_next;

reg [ID_WIDTH-1:0] m_axi_awid_reg = {ID_WIDTH{1'b0}}, m_axi_awid_next;
reg [ADDR_WIDTH-1:0] m_axi_awaddr_reg = {ADDR_WIDTH{1'b0}}, m_axi_awaddr_next;
reg [7:0] m_axi_awlen_reg = 8'd0, m_axi_awlen_next;
reg [2:0] m_axi_awsize_reg = 3'd0, m_axi_awsize_next;
reg [1:0] m_axi_awburst_reg = 2'd0, m_axi_awburst_next;
reg m_axi_awlock_reg = 1'b0, m_axi_awlock_next;
reg [3:0] m_axi_awcache_reg = 4'd0, m_axi_awcache_next;
reg [2:0] m_axi_awprot_reg = 3'd0, m_axi_awprot_next;
reg [3:0] m_axi_awqos_reg = 4'd0, m_axi_awqos_next;
reg [3:0] m_axi_awregion_reg = 4'd0, m_axi_awregion_next;
reg [AWUSER_WIDTH-1:0] m_axi_awuser_reg = {AWUSER_WIDTH{1'b0}}, m_axi_awuser_next;
reg m_axi_awvalid_reg = 1'b0, m_axi_awvalid_next;
reg m_axi_bready_reg = 1'b0, m_axi_bready_next;

// internal datapath
reg  [M_DATA_WIDTH-1:0] m_axi_wdata_int;
reg  [M_STRB_WIDTH-1:0] m_axi_wstrb_int;
reg                     m_axi_wlast_int;
reg  [WUSER_WIDTH-1:0]  m_axi_wuser_int;
reg                     m_axi_wvalid_int;
reg                     m_axi_wready_int_reg = 1'b0;
wire                    m_axi_wready_int_early;

assign s_axi_awready = s_axi_awready_reg;
assign s_axi_wready = s_axi_wready_reg;
assign s_axi_bid = s_axi_bid_reg;
assign s_axi_bresp = s_axi_bresp_reg;
assign s_axi_buser = BUSER_ENABLE ? s_axi_buser_reg : {BUSER_WIDTH{1'b0}};
assign s_axi_bvalid = s_axi_bvalid_reg;

assign m_axi_awid = FORWARD_ID ? m_axi_awid_reg : {ID_WIDTH{1'b0}};
assign m_axi_awaddr = m_axi_awaddr_reg;
assign m_axi_awlen = m_axi_awlen_reg;
assign m_axi_awsize = m_axi_awsize_reg;
assign m_axi_awburst = m_axi_awburst_reg;
assign m_axi_awlock = m_axi_awlock_reg;
assign m_axi_awcache = m_axi_awcache_reg;
assign m_axi_awprot = m_axi_awprot_reg;
assign m_axi_awqos = m_axi_awqos_reg;
assign m_axi_awregion = m_axi_awregion_reg;
assign m_axi_awuser = AWUSER_ENABLE ? m_axi_awuser_reg : {AWUSER_WIDTH{1'b0}};
assign m_axi_awvalid = m_axi_awvalid_reg;
assign m_axi_bready = m_axi_bready_reg;

generate
if (SEGMENT_COUNT == 1) begin : gen_passthrough
    always @* begin
        state_next = STATE_IDLE;

        id_next = id_reg;
        addr_next = addr_reg;
        orig_addr_next = orig_addr_reg;
        wrap_mask_next = wrap_mask_reg;
        burst_type_next = burst_type_reg;
        data_next = data_reg;
        strb_next = strb_reg;
        wuser_next = wuser_reg;
        burst_next = burst_reg;
        burst_size_next = burst_size_reg;
        master_burst_next = master_burst_reg;
        master_burst_size_next = master_burst_size_reg;
        burst_active_next = burst_active_reg;
        first_transfer_next = first_transfer_reg;

        s_axi_awready_next = 1'b0;
        s_axi_wready_next = 1'b0;
        s_axi_bid_next = s_axi_bid_reg;
        s_axi_bresp_next = s_axi_bresp_reg;
        s_axi_buser_next = s_axi_buser_reg;
        s_axi_bvalid_next = s_axi_bvalid_reg && !s_axi_bready;
        m_axi_awid_next = m_axi_awid_reg;
        m_axi_awaddr_next = m_axi_awaddr_reg;
        m_axi_awlen_next = m_axi_awlen_reg;
        m_axi_awsize_next = m_axi_awsize_reg;
        m_axi_awburst_next = m_axi_awburst_reg;
        m_axi_awlock_next = m_axi_awlock_reg;
        m_axi_awcache_next = m_axi_awcache_reg;
        m_axi_awprot_next = m_axi_awprot_reg;
        m_axi_awqos_next = m_axi_awqos_reg;
        m_axi_awregion_next = m_axi_awregion_reg;
        m_axi_awuser_next = m_axi_awuser_reg;
        m_axi_awvalid_next = m_axi_awvalid_reg && !m_axi_awready;
        m_axi_bready_next = 1'b0;

        m_axi_wdata_int = s_axi_wdata;
        m_axi_wstrb_int = s_axi_wstrb;
        m_axi_wlast_int = s_axi_wlast;
        m_axi_wuser_int = s_axi_wuser;
        m_axi_wvalid_int = 1'b0;

        case (state_reg)
            STATE_IDLE: begin
                s_axi_awready_next = !m_axi_awvalid;

                if (s_axi_awready && s_axi_awvalid) begin
                    s_axi_awready_next = 1'b0;
                    id_next = s_axi_awid;
                    m_axi_awid_next = s_axi_awid;
                    m_axi_awaddr_next = s_axi_awaddr;
                    m_axi_awlen_next = s_axi_awlen;
                    m_axi_awsize_next = s_axi_awsize;
                    m_axi_awburst_next = s_axi_awburst;
                    m_axi_awlock_next = s_axi_awlock;
                    m_axi_awcache_next = s_axi_awcache;
                    m_axi_awprot_next = s_axi_awprot;
                    m_axi_awqos_next = s_axi_awqos;
                    m_axi_awregion_next = s_axi_awregion;
                    m_axi_awuser_next = s_axi_awuser;
                    m_axi_awvalid_next = 1'b1;
                    s_axi_wready_next = m_axi_wready_int_early;
                    state_next = STATE_DATA;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_DATA: begin
                s_axi_wready_next = m_axi_wready_int_early;

                if (s_axi_wready && s_axi_wvalid) begin
                    m_axi_wdata_int = s_axi_wdata;
                    m_axi_wstrb_int = s_axi_wstrb;
                    m_axi_wlast_int = s_axi_wlast;
                    m_axi_wuser_int = s_axi_wuser;
                    m_axi_wvalid_int = 1'b1;
                    if (s_axi_wlast) begin
                        s_axi_wready_next = 1'b0;
                        m_axi_bready_next = !s_axi_bvalid;
                        state_next = STATE_RESP;
                    end else begin
                        state_next = STATE_DATA;
                    end
                end else begin
                    state_next = STATE_DATA;
                end
            end
            STATE_RESP: begin
                m_axi_bready_next = !s_axi_bvalid;

                if (m_axi_bready && m_axi_bvalid) begin
                    m_axi_bready_next = 1'b0;
                    s_axi_bid_next = id_reg;
                    s_axi_bresp_next = m_axi_bresp;
                    s_axi_buser_next = m_axi_buser;
                    s_axi_bvalid_next = 1'b1;
                    s_axi_awready_next = !m_axi_awvalid;
                    state_next = STATE_IDLE;
                end else begin
                    state_next = STATE_RESP;
                end
            end
            default: begin
                state_next = STATE_IDLE;
            end
        endcase
    end
end else if (EXPAND) begin : gen_upsize
    localparam [ADDR_WIDTH-1:0] M_OFFSET_MASK = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << M_BURST_SIZE) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};

    integer i;
    reg [ADDR_WIDTH-1:0] wmask_init;
    reg [ADDR_WIDTH-1:0] s_align_mask_init;
    reg [15:0] start_off_init;
    reg [15:0] total_span_init;
    reg [15:0] m_len_calc;
    reg can_repack_wide;

    always @* begin
        state_next = STATE_IDLE;

        id_next = id_reg;
        addr_next = addr_reg;
        orig_addr_next = orig_addr_reg;
        wrap_mask_next = wrap_mask_reg;
        burst_type_next = burst_type_reg;
        data_next = data_reg;
        strb_next = strb_reg;
        wuser_next = wuser_reg;
        burst_next = burst_reg;
        burst_size_next = burst_size_reg;
        master_burst_next = master_burst_reg;
        master_burst_size_next = master_burst_size_reg;
        burst_active_next = burst_active_reg;
        first_transfer_next = first_transfer_reg;

        s_axi_awready_next = 1'b0;
        s_axi_wready_next = 1'b0;
        s_axi_bid_next = s_axi_bid_reg;
        s_axi_bresp_next = s_axi_bresp_reg;
        s_axi_buser_next = s_axi_buser_reg;
        s_axi_bvalid_next = s_axi_bvalid_reg && !s_axi_bready;
        m_axi_awid_next = m_axi_awid_reg;
        m_axi_awaddr_next = m_axi_awaddr_reg;
        m_axi_awlen_next = m_axi_awlen_reg;
        m_axi_awsize_next = m_axi_awsize_reg;
        m_axi_awburst_next = m_axi_awburst_reg;
        m_axi_awlock_next = m_axi_awlock_reg;
        m_axi_awcache_next = m_axi_awcache_reg;
        m_axi_awprot_next = m_axi_awprot_reg;
        m_axi_awqos_next = m_axi_awqos_reg;
        m_axi_awregion_next = m_axi_awregion_reg;
        m_axi_awuser_next = m_axi_awuser_reg;
        m_axi_awvalid_next = m_axi_awvalid_reg && !m_axi_awready;
        m_axi_bready_next = 1'b0;

        m_axi_wdata_int = {SEGMENT_COUNT{s_axi_wdata}};
        m_axi_wstrb_int = {{(M_STRB_WIDTH-S_STRB_WIDTH){1'b0}}, s_axi_wstrb};
        m_axi_wlast_int = s_axi_wlast;
        m_axi_wuser_int = s_axi_wuser;
        m_axi_wvalid_int = 1'b0;
        i = 0;

        wmask_init = calc_wrap_mask(s_axi_awsize, s_axi_awlen);
        s_align_mask_init = ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_axi_awsize) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        start_off_init = {{(16-M_ADDR_BIT_OFFSET){1'b0}}, s_axi_awaddr[M_ADDR_BIT_OFFSET-1:0]} & {{(16-M_ADDR_BIT_OFFSET){1'b1}}, s_align_mask_init[M_ADDR_BIT_OFFSET-1:0]};
        total_span_init = start_off_init + ({8'd0, s_axi_awlen} << s_axi_awsize);
        m_len_calc = total_span_init >> M_BURST_SIZE;

        can_repack_wide = CONVERT_BURST && s_axi_awcache[1] && (CONVERT_NARROW_BURST || (s_axi_awsize == S_BURST_SIZE_LP)) &&
                          ((s_axi_awburst == 2'b01) ||
                           ((s_axi_awburst == 2'b10) && (((s_axi_awaddr & wmask_init) == {ADDR_WIDTH{1'b0}}) || (wmask_init == M_OFFSET_MASK))));

        case (state_reg)
            STATE_IDLE: begin
                s_axi_awready_next = !m_axi_awvalid;
                data_next = {DATA_WIDTH{1'b0}};
                strb_next = {STRB_WIDTH{1'b0}};

                if (s_axi_awready && s_axi_awvalid) begin
                    s_axi_awready_next = 1'b0;
                    id_next = s_axi_awid;
                    m_axi_awid_next = s_axi_awid;
                    addr_next = s_axi_awaddr;
                    orig_addr_next = s_axi_awaddr;
                    wrap_mask_next = wmask_init;
                    burst_type_next = s_axi_awburst;
                    burst_next = s_axi_awlen;
                    burst_size_next = s_axi_awsize;
                    if (can_repack_wide) begin
                        master_burst_size_next = M_BURST_SIZE_LP;
                        m_axi_awaddr_next = s_axi_awaddr & ~M_OFFSET_MASK;
                        m_axi_awlen_next = (s_axi_awburst == 2'b10 && wmask_init == M_OFFSET_MASK) ? 8'd0 : m_len_calc[7:0];
                        m_axi_awsize_next = M_BURST_SIZE_LP;
                        m_axi_awburst_next = 2'b01;
                        state_next = STATE_DATA_2;
                    end else begin
                        master_burst_size_next = s_axi_awsize;
                        m_axi_awaddr_next = s_axi_awaddr;
                        m_axi_awlen_next = s_axi_awlen;
                        m_axi_awsize_next = s_axi_awsize;
                        m_axi_awburst_next = s_axi_awburst;
                        state_next = STATE_DATA;
                    end
                    m_axi_awlock_next = s_axi_awlock;
                    m_axi_awcache_next = s_axi_awcache;
                    m_axi_awprot_next = s_axi_awprot;
                    m_axi_awqos_next = s_axi_awqos;
                    m_axi_awregion_next = s_axi_awregion;
                    m_axi_awuser_next = s_axi_awuser;
                    m_axi_awvalid_next = 1'b1;
                    s_axi_wready_next = m_axi_wready_int_early;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_DATA: begin
                s_axi_wready_next = m_axi_wready_int_early;

                if (s_axi_wready && s_axi_wvalid) begin
                    m_axi_wdata_int = {SEGMENT_COUNT{s_axi_wdata}};
                    m_axi_wstrb_int = {{(M_STRB_WIDTH-S_STRB_WIDTH){1'b0}}, s_axi_wstrb} << (addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET] * S_STRB_WIDTH);
                    m_axi_wlast_int = s_axi_wlast;
                    m_axi_wuser_int = s_axi_wuser;
                    m_axi_wvalid_int = 1'b1;
                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
                    if (s_axi_wlast) begin
                        s_axi_wready_next = 1'b0;
                        m_axi_bready_next = !s_axi_bvalid;
                        state_next = STATE_RESP;
                    end else begin
                        state_next = STATE_DATA;
                    end
                end else begin
                    state_next = STATE_DATA;
                end
            end
            STATE_DATA_2: begin
                s_axi_wready_next = m_axi_wready_int_early;

                if (s_axi_wready && s_axi_wvalid) begin
                    if (CONVERT_NARROW_BURST) begin
                        for (i = 0; i < S_WORD_WIDTH; i = i + 1) begin
                            if (s_axi_wstrb[i]) begin
                                data_next[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*SEGMENT_DATA_WIDTH+i*M_WORD_SIZE +: M_WORD_SIZE] = s_axi_wdata[i*M_WORD_SIZE +: M_WORD_SIZE];
                                strb_next[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*SEGMENT_STRB_WIDTH+i] = 1'b1;
                            end
                        end
                    end else begin
                        data_next[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*SEGMENT_DATA_WIDTH +: SEGMENT_DATA_WIDTH] = s_axi_wdata;
                        strb_next[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*SEGMENT_STRB_WIDTH +: SEGMENT_STRB_WIDTH] = s_axi_wstrb;
                    end
                    m_axi_wdata_int = data_next;
                    m_axi_wstrb_int = strb_next;
                    m_axi_wlast_int = 1'b0;
                    m_axi_wuser_int = s_axi_wuser;
                    burst_next = burst_reg - 8'd1;
                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
                    if (burst_reg == 8'd0) begin
                        data_next = {DATA_WIDTH{1'b0}};
                        strb_next = {STRB_WIDTH{1'b0}};
                        m_axi_wlast_int = 1'b1;
                        m_axi_wvalid_int = 1'b1;
                        s_axi_wready_next = 1'b0;
                        m_axi_bready_next = !s_axi_bvalid;
                        state_next = STATE_RESP;
                    end else if (addr_next[M_ADDR_BIT_OFFSET] != addr_reg[M_ADDR_BIT_OFFSET]) begin
                        data_next = {DATA_WIDTH{1'b0}};
                        strb_next = {STRB_WIDTH{1'b0}};
                        m_axi_wvalid_int = 1'b1;
                        state_next = STATE_DATA_2;
                    end else begin
                        state_next = STATE_DATA_2;
                    end
                end else begin
                    state_next = STATE_DATA_2;
                end
            end
            STATE_RESP: begin
                m_axi_bready_next = !s_axi_bvalid;

                if (m_axi_bready && m_axi_bvalid) begin
                    m_axi_bready_next = 1'b0;
                    s_axi_bid_next = id_reg;
                    s_axi_bresp_next = m_axi_bresp;
                    s_axi_buser_next = m_axi_buser;
                    s_axi_bvalid_next = 1'b1;
                    s_axi_awready_next = !m_axi_awvalid;
                    state_next = STATE_IDLE;
                end else begin
                    state_next = STATE_RESP;
                end
            end
        endcase
    end
end else begin : gen_downsize
    function [7:0] calc_downsize_child_len;
        input [ADDR_WIDTH-1:0] start_addr;
        input [ADDR_WIDTH-1:0] wmask;
        input [7:0] rem_slave_len;
        input [2:0] s_sz;
        input [1:0] btype;
        reg [2:0] shift;
        reg [ADDR_WIDTH-1:0] s_beat_mask;
        reg [ADDR_WIDTH-1:0] first_extra_full;
        reg [ADDR_WIDTH-1:0] wrap_rem_full;
        reg [7:0] max_s_len;
        reg [7:0] eff_s_len;
        begin
            shift = s_sz - M_BURST_SIZE_LP;
            s_beat_mask = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_sz) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
            first_extra_full = (~start_addr & s_beat_mask) >> M_BURST_SIZE;
            wrap_rem_full = (~start_addr & wmask) >> s_sz;
            max_s_len = 8'hFF >> shift;
            if (btype == 2'b00) begin
                eff_s_len = 8'd0;
            end else if (btype == 2'b10) begin
                eff_s_len = (rem_slave_len <= wrap_rem_full[7:0]) ? rem_slave_len : wrap_rem_full[7:0];
            end else begin
                eff_s_len = (rem_slave_len <= max_s_len) ? rem_slave_len : max_s_len;
            end
            calc_downsize_child_len = (eff_s_len << shift) | first_extra_full[7:0];
        end
    endfunction

    reg [ADDR_WIDTH-1:0] wmask_init;
    reg [ADDR_WIDTH-1:0] sub_step_aligned;
    reg slave_beat_done;

    always @* begin
        state_next = STATE_IDLE;

        id_next = id_reg;
        addr_next = addr_reg;
        orig_addr_next = orig_addr_reg;
        wrap_mask_next = wrap_mask_reg;
        burst_type_next = burst_type_reg;
        data_next = data_reg;
        strb_next = strb_reg;
        wuser_next = wuser_reg;
        burst_next = burst_reg;
        burst_size_next = burst_size_reg;
        master_burst_next = master_burst_reg;
        master_burst_size_next = master_burst_size_reg;
        burst_active_next = burst_active_reg;
        first_transfer_next = first_transfer_reg;

        s_axi_awready_next = 1'b0;
        s_axi_wready_next = 1'b0;
        s_axi_bid_next = s_axi_bid_reg;
        s_axi_bresp_next = s_axi_bresp_reg;
        s_axi_buser_next = s_axi_buser_reg;
        s_axi_bvalid_next = s_axi_bvalid_reg && !s_axi_bready;
        m_axi_awid_next = m_axi_awid_reg;
        m_axi_awaddr_next = m_axi_awaddr_reg;
        m_axi_awlen_next = m_axi_awlen_reg;
        m_axi_awsize_next = m_axi_awsize_reg;
        m_axi_awburst_next = m_axi_awburst_reg;
        m_axi_awlock_next = m_axi_awlock_reg;
        m_axi_awcache_next = m_axi_awcache_reg;
        m_axi_awprot_next = m_axi_awprot_reg;
        m_axi_awqos_next = m_axi_awqos_reg;
        m_axi_awregion_next = m_axi_awregion_reg;
        m_axi_awuser_next = m_axi_awuser_reg;
        m_axi_awvalid_next = m_axi_awvalid_reg && !m_axi_awready;
        m_axi_bready_next = 1'b0;

        m_axi_wdata_int = data_reg[M_DATA_WIDTH-1:0];
        m_axi_wstrb_int = strb_reg[M_STRB_WIDTH-1:0];
        m_axi_wlast_int = 1'b0;
        m_axi_wuser_int = wuser_reg;
        m_axi_wvalid_int = 1'b0;

        wmask_init = calc_wrap_mask(s_axi_awsize, s_axi_awlen);
        sub_step_aligned = (addr_reg + ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << master_burst_size_reg)) &
                           ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << master_burst_size_reg) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        slave_beat_done = (burst_size_reg <= M_BURST_SIZE_LP) || (sub_step_aligned[{2'b00, burst_size_reg}] != addr_reg[{2'b00, burst_size_reg}]);

        case (state_reg)
            STATE_IDLE: begin
                s_axi_awready_next = !m_axi_awvalid;
                first_transfer_next = 1'b1;

                if (s_axi_awready && s_axi_awvalid) begin
                    s_axi_awready_next = 1'b0;
                    id_next = s_axi_awid;
                    m_axi_awid_next = s_axi_awid;
                    m_axi_awaddr_next = s_axi_awaddr;
                    addr_next = s_axi_awaddr;
                    orig_addr_next = s_axi_awaddr;
                    wrap_mask_next = wmask_init;
                    burst_type_next = s_axi_awburst;
                    burst_next = s_axi_awlen;
                    burst_size_next = s_axi_awsize;
                    burst_active_next = 1'b1;
                    s_axi_bresp_next = 2'd0;
                    if (s_axi_awsize > M_BURST_SIZE_LP) begin
                        master_burst_next = calc_downsize_child_len(s_axi_awaddr, wmask_init, s_axi_awlen, s_axi_awsize, s_axi_awburst);
                        master_burst_size_next = M_BURST_SIZE_LP;
                        m_axi_awlen_next = master_burst_next;
                        m_axi_awsize_next = M_BURST_SIZE_LP;
                        m_axi_awburst_next = 2'b01;
                    end else begin
                        master_burst_next = s_axi_awlen;
                        master_burst_size_next = s_axi_awsize;
                        m_axi_awlen_next = s_axi_awlen;
                        m_axi_awsize_next = s_axi_awsize;
                        m_axi_awburst_next = s_axi_awburst;
                    end
                    m_axi_awlock_next = s_axi_awlock;
                    m_axi_awcache_next = s_axi_awcache;
                    m_axi_awprot_next = s_axi_awprot;
                    m_axi_awqos_next = s_axi_awqos;
                    m_axi_awregion_next = s_axi_awregion;
                    m_axi_awuser_next = s_axi_awuser;
                    m_axi_awvalid_next = 1'b1;
                    s_axi_wready_next = m_axi_wready_int_early;
                    state_next = STATE_DATA;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_DATA: begin
                s_axi_wready_next = m_axi_wready_int_early;

                if (s_axi_wready && s_axi_wvalid) begin
                    data_next = s_axi_wdata;
                    strb_next = s_axi_wstrb;
                    wuser_next = s_axi_wuser;
                    m_axi_wdata_int = s_axi_wdata[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET]*M_DATA_WIDTH +: M_DATA_WIDTH];
                    m_axi_wstrb_int = s_axi_wstrb[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET]*M_STRB_WIDTH +: M_STRB_WIDTH];
                    m_axi_wlast_int = 1'b0;
                    m_axi_wuser_int = s_axi_wuser;
                    m_axi_wvalid_int = 1'b1;
                    burst_next = burst_reg - 8'd1;
                    burst_active_next = (burst_reg != 8'd0);
                    master_burst_next = master_burst_reg - 8'd1;

                    if (burst_size_reg <= M_BURST_SIZE_LP) begin
                        addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
                    end else if (slave_beat_done) begin
                        case (burst_type_reg)
                            2'b00:   addr_next = orig_addr_reg;
                            2'b10:   addr_next = (addr_reg & ~wrap_mask_reg) | (sub_step_aligned & wrap_mask_reg);
                            default: addr_next = sub_step_aligned;
                        endcase
                    end else begin
                        addr_next = sub_step_aligned;
                    end

                    if (master_burst_reg == 8'd0) begin
                        s_axi_wready_next = 1'b0;
                        m_axi_bready_next = !s_axi_bvalid && !m_axi_awvalid;
                        m_axi_wlast_int = 1'b1;
                        state_next = STATE_RESP;
                    end else if (slave_beat_done) begin
                        state_next = STATE_DATA;
                    end else begin
                        s_axi_wready_next = 1'b0;
                        state_next = STATE_DATA_2;
                    end
                end else begin
                    state_next = STATE_DATA;
                end
            end
            STATE_DATA_2: begin
                s_axi_wready_next = 1'b0;

                if (m_axi_wready_int_reg) begin
                    m_axi_wdata_int = data_reg[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET]*M_DATA_WIDTH +: M_DATA_WIDTH];
                    m_axi_wstrb_int = strb_reg[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET]*M_STRB_WIDTH +: M_STRB_WIDTH];
                    m_axi_wlast_int = 1'b0;
                    m_axi_wuser_int = wuser_reg;
                    m_axi_wvalid_int = 1'b1;
                    master_burst_next = master_burst_reg - 8'd1;

                    if (slave_beat_done) begin
                        case (burst_type_reg)
                            2'b00:   addr_next = orig_addr_reg;
                            2'b10:   addr_next = (addr_reg & ~wrap_mask_reg) | (sub_step_aligned & wrap_mask_reg);
                            default: addr_next = sub_step_aligned;
                        endcase
                    end else begin
                        addr_next = sub_step_aligned;
                    end

                    if (master_burst_reg == 8'd0) begin
                        s_axi_wready_next = 1'b0;
                        m_axi_bready_next = !s_axi_bvalid && !m_axi_awvalid;
                        m_axi_wlast_int = 1'b1;
                        state_next = STATE_RESP;
                    end else if (slave_beat_done) begin
                        state_next = STATE_DATA;
                    end else begin
                        s_axi_wready_next = 1'b0;
                        state_next = STATE_DATA_2;
                    end
                end else begin
                    state_next = STATE_DATA_2;
                end
            end
            STATE_RESP: begin
                m_axi_bready_next = !s_axi_bvalid && !m_axi_awvalid;

                if (m_axi_bready && m_axi_bvalid) begin
                    first_transfer_next = 1'b0;
                    m_axi_bready_next = 1'b0;
                    s_axi_bid_next = id_reg;
                    if (first_transfer_reg) begin
                        s_axi_bresp_next = m_axi_bresp;
                        s_axi_buser_next = m_axi_buser;
                    end else if (m_axi_bresp > s_axi_bresp_reg) begin
                        s_axi_bresp_next = m_axi_bresp;
                        s_axi_buser_next = m_axi_buser;
                    end

                    if (burst_active_reg) begin
                        master_burst_next = calc_downsize_child_len(addr_reg, wrap_mask_reg, burst_reg, burst_size_reg, burst_type_reg);
                        master_burst_size_next = M_BURST_SIZE_LP;
                        m_axi_awaddr_next = addr_reg;
                        m_axi_awlen_next = master_burst_next;
                        m_axi_awsize_next = M_BURST_SIZE_LP;
                        m_axi_awburst_next = 2'b01;
                        m_axi_awvalid_next = 1'b1;
                        s_axi_wready_next = m_axi_wready_int_early;
                        state_next = STATE_DATA;
                    end else begin
                        s_axi_bvalid_next = 1'b1;
                        s_axi_awready_next = !m_axi_awvalid;
                        state_next = STATE_IDLE;
                    end
                end else begin
                    state_next = STATE_RESP;
                end
            end
        endcase
    end
end
endgenerate

always @(posedge clk) begin
    state_reg <= state_next;

    id_reg <= id_next;
    addr_reg <= addr_next;
    orig_addr_reg <= orig_addr_next;
    wrap_mask_reg <= wrap_mask_next;
    burst_type_reg <= burst_type_next;
    data_reg <= data_next;
    strb_reg <= strb_next;
    wuser_reg <= wuser_next;
    burst_reg <= burst_next;
    burst_size_reg <= burst_size_next;
    master_burst_reg <= master_burst_next;
    master_burst_size_reg <= master_burst_size_next;
    burst_active_reg <= burst_active_next;
    first_transfer_reg <= first_transfer_next;

    s_axi_awready_reg <= s_axi_awready_next;
    s_axi_wready_reg <= s_axi_wready_next;
    s_axi_bid_reg <= s_axi_bid_next;
    s_axi_bresp_reg <= s_axi_bresp_next;
    s_axi_buser_reg <= s_axi_buser_next;
    s_axi_bvalid_reg <= s_axi_bvalid_next;

    m_axi_awid_reg <= m_axi_awid_next;
    m_axi_awaddr_reg <= m_axi_awaddr_next;
    m_axi_awlen_reg <= m_axi_awlen_next;
    m_axi_awsize_reg <= m_axi_awsize_next;
    m_axi_awburst_reg <= m_axi_awburst_next;
    m_axi_awlock_reg <= m_axi_awlock_next;
    m_axi_awcache_reg <= m_axi_awcache_next;
    m_axi_awprot_reg <= m_axi_awprot_next;
    m_axi_awqos_reg <= m_axi_awqos_next;
    m_axi_awregion_reg <= m_axi_awregion_next;
    m_axi_awuser_reg <= m_axi_awuser_next;
    m_axi_awvalid_reg <= m_axi_awvalid_next;
    m_axi_bready_reg <= m_axi_bready_next;

    if (rst) begin
        state_reg <= STATE_IDLE;

        s_axi_awready_reg <= 1'b0;
        s_axi_wready_reg <= 1'b0;
        s_axi_bvalid_reg <= 1'b0;

        m_axi_awvalid_reg <= 1'b0;
        m_axi_bready_reg <= 1'b0;
    end
end

// output datapath logic
reg [M_DATA_WIDTH-1:0] m_axi_wdata_reg  = {M_DATA_WIDTH{1'b0}};
reg [M_STRB_WIDTH-1:0] m_axi_wstrb_reg  = {M_STRB_WIDTH{1'b0}};
reg                    m_axi_wlast_reg  = 1'b0;
reg [WUSER_WIDTH-1:0]  m_axi_wuser_reg  = {WUSER_WIDTH{1'b0}};
reg                    m_axi_wvalid_reg = 1'b0, m_axi_wvalid_next;

reg [M_DATA_WIDTH-1:0] temp_m_axi_wdata_reg  = {M_DATA_WIDTH{1'b0}};
reg [M_STRB_WIDTH-1:0] temp_m_axi_wstrb_reg  = {M_STRB_WIDTH{1'b0}};
reg                    temp_m_axi_wlast_reg  = 1'b0;
reg [WUSER_WIDTH-1:0]  temp_m_axi_wuser_reg  = {WUSER_WIDTH{1'b0}};
reg                    temp_m_axi_wvalid_reg = 1'b0, temp_m_axi_wvalid_next;

// datapath control
reg store_axi_w_int_to_output;
reg store_axi_w_int_to_temp;
reg store_axi_w_temp_to_output;

assign m_axi_wdata  = m_axi_wdata_reg;
assign m_axi_wstrb  = m_axi_wstrb_reg;
assign m_axi_wlast  = m_axi_wlast_reg;
assign m_axi_wuser  = WUSER_ENABLE ? m_axi_wuser_reg : {WUSER_WIDTH{1'b0}};
assign m_axi_wvalid = m_axi_wvalid_reg;

assign m_axi_wready_int_early = m_axi_wready | (~temp_m_axi_wvalid_reg & (~m_axi_wvalid_reg | ~m_axi_wvalid_int));

always @* begin
    m_axi_wvalid_next = m_axi_wvalid_reg;
    temp_m_axi_wvalid_next = temp_m_axi_wvalid_reg;

    store_axi_w_int_to_output = 1'b0;
    store_axi_w_int_to_temp = 1'b0;
    store_axi_w_temp_to_output = 1'b0;

    if (m_axi_wready_int_reg) begin
        if (m_axi_wready | ~m_axi_wvalid_reg) begin
            m_axi_wvalid_next = m_axi_wvalid_int;
            store_axi_w_int_to_output = 1'b1;
        end else begin
            temp_m_axi_wvalid_next = m_axi_wvalid_int;
            store_axi_w_int_to_temp = 1'b1;
        end
    end else if (m_axi_wready) begin
        m_axi_wvalid_next = temp_m_axi_wvalid_reg;
        temp_m_axi_wvalid_next = 1'b0;
        store_axi_w_temp_to_output = 1'b1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        m_axi_wvalid_reg <= 1'b0;
        m_axi_wready_int_reg <= 1'b0;
        temp_m_axi_wvalid_reg <= 1'b0;
    end else begin
        m_axi_wvalid_reg <= m_axi_wvalid_next;
        m_axi_wready_int_reg <= m_axi_wready_int_early;
        temp_m_axi_wvalid_reg <= temp_m_axi_wvalid_next;
    end

    if (store_axi_w_int_to_output) begin
        m_axi_wdata_reg <= m_axi_wdata_int;
        m_axi_wstrb_reg <= m_axi_wstrb_int;
        m_axi_wlast_reg <= m_axi_wlast_int;
        m_axi_wuser_reg <= m_axi_wuser_int;
    end else if (store_axi_w_temp_to_output) begin
        m_axi_wdata_reg <= temp_m_axi_wdata_reg;
        m_axi_wstrb_reg <= temp_m_axi_wstrb_reg;
        m_axi_wlast_reg <= temp_m_axi_wlast_reg;
        m_axi_wuser_reg <= temp_m_axi_wuser_reg;
    end

    if (store_axi_w_int_to_temp) begin
        temp_m_axi_wdata_reg <= m_axi_wdata_int;
        temp_m_axi_wstrb_reg <= m_axi_wstrb_int;
        temp_m_axi_wlast_reg <= m_axi_wlast_int;
        temp_m_axi_wuser_reg <= m_axi_wuser_int;
    end
end

endmodule

`resetall
