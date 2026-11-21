/*

Copyright (c) 2021 Alex Forencich

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
 * AXI4 lite crossbar address decode and admission control
 */
module axil_crossbar_addr #
(
    parameter S = 0,
    parameter S_COUNT = 4,
    parameter M_COUNT = 4,
    parameter ADDR_WIDTH = 32,
    parameter M_REGIONS = 1,
    parameter M_BASE_ADDR = 0,
    parameter M_ADDR_WIDTH = {M_COUNT{{M_REGIONS{32'd24}}}},
    parameter M_CONNECT = {M_COUNT{{S_COUNT{1'b1}}}},
    parameter M_SECURE = {M_COUNT{1'b0}},
    parameter WC_OUTPUT = 0,
    parameter CL_M_COUNT = M_COUNT > 1 ? $clog2(M_COUNT) : 1
)
(
    input  wire                       clk,
    input  wire                       rst,

    /*
     * Address input
     */
    input  wire [ADDR_WIDTH-1:0]      s_axil_aaddr,
    input  wire [2:0]                 s_axil_aprot,
    input  wire                       s_axil_avalid,
    output wire                       s_axil_aready,

    /*
     * Address output
     */
    output wire [CL_M_COUNT-1:0]      m_select,
    output wire                       m_axil_avalid,
    input  wire                       m_axil_aready,

    /*
     * Write command output
     */
    output wire [CL_M_COUNT-1:0]      m_wc_select,
    output wire                       m_wc_decerr,
    output wire                       m_wc_valid,
    input  wire                       m_wc_ready,

    /*
     * Reply command output
     */
    output wire [CL_M_COUNT-1:0]      m_rc_select,
    output wire                       m_rc_decerr,
    output wire                       m_rc_valid,
    input  wire                       m_rc_ready
);

localparam [M_COUNT*S_COUNT-1:0] M_CONNECT_VEC = M_CONNECT;
localparam [M_COUNT-1:0]         M_SECURE_VEC  = M_SECURE;

// default address computation
function [M_COUNT*M_REGIONS*ADDR_WIDTH-1:0] calcBaseAddrs(input [31:0] dummy);
    integer k;
    reg [31:0] width;
    reg [ADDR_WIDTH-1:0] base;
    reg [ADDR_WIDTH-1:0] size;
    reg [ADDR_WIDTH-1:0] mask;
    begin
        calcBaseAddrs = {M_COUNT*M_REGIONS*ADDR_WIDTH{1'b0}};
        base = {ADDR_WIDTH{1'b0}};
        for (k = 0; k < M_COUNT*M_REGIONS; k = k + 1) begin
            width = M_ADDR_WIDTH[k*32 +: 32];
            if (width > 0 && width <= ADDR_WIDTH) begin
                mask = (width == ADDR_WIDTH) ? {ADDR_WIDTH{1'b1}} : ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - width));
                size = mask + 1'b1;
                if ((base & mask) != 0) begin
                    base = base + size - (base & mask);
                end
                calcBaseAddrs[k * ADDR_WIDTH +: ADDR_WIDTH] = base;
                base = base + size;
            end
        end
    end
endfunction

parameter [M_COUNT*M_REGIONS*ADDR_WIDTH-1:0] M_BASE_ADDR_INT = M_BASE_ADDR ? M_BASE_ADDR : calcBaseAddrs(0);

integer i, j;
initial begin
    if (M_REGIONS < 1) begin
        $display("Error: need at least 1 region (instance %m)");
        $finish;
    end

    for (i = 0; i < M_COUNT*M_REGIONS; i = i + 1) begin
        if (M_ADDR_WIDTH[i*32 +: 32] && M_ADDR_WIDTH[i*32 +: 32] > ADDR_WIDTH) begin
            $display("Error: address width out of range (instance %m)");
            $finish;
        end
        if (M_ADDR_WIDTH[i*32 +: 32] && M_ADDR_WIDTH[i*32 +: 32] < ADDR_WIDTH) begin
            if ((M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[i*32 +: 32]))) != 0) begin
                $display("Error: address range not aligned (instance %m)");
                $finish;
            end
        end
    end
end

localparam [1:0]
    STATE_IDLE   = 2'd0,
    STATE_DECODE = 2'd1;

reg [1:0] state_reg, state_next;
reg s_axil_aready_reg, s_axil_aready_next;
reg [CL_M_COUNT-1:0] m_select_reg, m_select_next;
reg m_axil_avalid_reg, m_axil_avalid_next;
reg m_decerr_reg, m_decerr_next;
reg m_wc_valid_reg, m_wc_valid_next;
reg m_rc_valid_reg, m_rc_valid_next;

assign s_axil_aready = s_axil_aready_reg;
assign m_select      = m_select_reg;
assign m_axil_avalid = m_axil_avalid_reg;
assign m_wc_select   = m_select_reg;
assign m_wc_decerr   = m_decerr_reg;
assign m_wc_valid    = m_wc_valid_reg;
assign m_rc_select   = m_select_reg;
assign m_rc_decerr   = m_decerr_reg;
assign m_rc_valid    = m_rc_valid_reg;

reg match;
reg [31:0] best_width;
reg [CL_M_COUNT-1:0] best_master;
reg best_secure;
reg [31:0] cur_w;
reg [ADDR_WIDTH-1:0] cur_base;
reg [ADDR_WIDTH-1:0] cur_mask;

always @* begin
    state_next = STATE_IDLE;
    match = 1'b0;
    best_width = ADDR_WIDTH + 32'd1;
    best_master = {CL_M_COUNT{1'b0}};
    best_secure = 1'b0;
    cur_w = 32'd0;
    cur_base = {ADDR_WIDTH{1'b0}};
    cur_mask = {ADDR_WIDTH{1'b0}};

    s_axil_aready_next = 1'b0;
    m_select_next = m_select_reg;
    m_axil_avalid_next = m_axil_avalid_reg && !m_axil_aready;
    m_decerr_next = m_decerr_reg;
    m_wc_valid_next = m_wc_valid_reg && !m_wc_ready;
    m_rc_valid_next = m_rc_valid_reg && !m_rc_ready;

    case (state_reg)
        STATE_IDLE: begin
            s_axil_aready_next = 1'b0;
            if (s_axil_avalid && !s_axil_aready) begin
                match = 1'b0;
                best_width = ADDR_WIDTH + 32'd1;
                best_master = {CL_M_COUNT{1'b0}};
                best_secure = 1'b0;

                for (i = 0; i < M_COUNT; i = i + 1) begin
                    for (j = 0; j < M_REGIONS; j = j + 1) begin
                        cur_w = M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32];
                        cur_base = M_BASE_ADDR_INT[(i*M_REGIONS+j)*ADDR_WIDTH +: ADDR_WIDTH];
                        if (cur_w > 32'd0 && cur_w <= ADDR_WIDTH && M_CONNECT_VEC[i*S_COUNT + S]) begin
                            cur_mask = (cur_w == ADDR_WIDTH) ? {ADDR_WIDTH{1'b1}} : ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - cur_w));
                            if (((s_axil_aaddr ^ cur_base) & ~cur_mask) == {ADDR_WIDTH{1'b0}}) begin
                                if (!match || (cur_w <= best_width)) begin
                                    match = 1'b1;
                                    best_width = cur_w;
                                    best_master = i[CL_M_COUNT-1:0];
                                    best_secure = M_SECURE_VEC[i];
                                end
                            end
                        end
                    end
                end

                if (match && !(best_secure && s_axil_aprot[1])) begin
                    m_select_next = best_master;
                    m_axil_avalid_next = 1'b1;
                    m_decerr_next = 1'b0;
                    m_wc_valid_next = WC_OUTPUT ? 1'b1 : 1'b0;
                    m_rc_valid_next = 1'b1;
                    state_next = STATE_DECODE;
                end else begin
                    m_select_next = {CL_M_COUNT{1'b0}};
                    m_axil_avalid_next = 1'b0;
                    m_decerr_next = 1'b1;
                    m_wc_valid_next = WC_OUTPUT ? 1'b1 : 1'b0;
                    m_rc_valid_next = 1'b1;
                    state_next = STATE_DECODE;
                end
            end
        end
        STATE_DECODE: begin
            if (!m_axil_avalid_next && (!m_wc_valid_next || !WC_OUTPUT) && !m_rc_valid_next) begin
                s_axil_aready_next = 1'b1;
                state_next = STATE_IDLE;
            end else begin
                state_next = STATE_DECODE;
            end
        end
        default: begin
            state_next = STATE_IDLE;
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        state_reg         <= STATE_IDLE;
        s_axil_aready_reg <= 1'b0;
        m_select_reg      <= {CL_M_COUNT{1'b0}};
        m_axil_avalid_reg <= 1'b0;
        m_decerr_reg      <= 1'b0;
        m_wc_valid_reg    <= 1'b0;
        m_rc_valid_reg    <= 1'b0;
    end else begin
        state_reg         <= state_next;
        s_axil_aready_reg <= s_axil_aready_next;
        m_select_reg      <= m_select_next;
        m_axil_avalid_reg <= m_axil_avalid_next;
        m_decerr_reg      <= m_decerr_next;
        m_wc_valid_reg    <= m_wc_valid_next;
        m_rc_valid_reg    <= m_rc_valid_next;
    end
end

endmodule

`resetall
