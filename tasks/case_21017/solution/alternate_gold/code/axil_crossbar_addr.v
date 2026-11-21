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
 * AXI4 lite crossbar address decode (parallel region hit vector + descending reduction)
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
    input  wire [ADDR_WIDTH-1:0]      s_axil_aaddr,
    input  wire [2:0]                 s_axil_aprot,
    input  wire                       s_axil_avalid,
    output wire                       s_axil_aready,
    output wire [CL_M_COUNT-1:0]      m_select,
    output wire                       m_axil_avalid,
    input  wire                       m_axil_aready,
    output wire [CL_M_COUNT-1:0]      m_wc_select,
    output wire                       m_wc_decerr,
    output wire                       m_wc_valid,
    input  wire                       m_wc_ready,
    output wire [CL_M_COUNT-1:0]      m_rc_select,
    output wire                       m_rc_decerr,
    output wire                       m_rc_valid,
    input  wire                       m_rc_ready
);

localparam TOTAL_REGIONS = M_COUNT * M_REGIONS;
localparam [M_COUNT*S_COUNT-1:0] M_CONNECT_VEC = M_CONNECT;
localparam [M_COUNT-1:0]         M_SECURE_VEC  = M_SECURE;

function [TOTAL_REGIONS*ADDR_WIDTH-1:0] calcBaseAddrs(input [31:0] dummy);
    integer k;
    reg [31:0] w;
    reg [ADDR_WIDTH-1:0] base;
    reg [ADDR_WIDTH-1:0] mask;
    reg [ADDR_WIDTH-1:0] size;
    begin
        calcBaseAddrs = {TOTAL_REGIONS*ADDR_WIDTH{1'b0}};
        base = {ADDR_WIDTH{1'b0}};
        for (k = 0; k < TOTAL_REGIONS; k = k + 1) begin
            w = M_ADDR_WIDTH[k*32 +: 32];
            if (w > 0 && w <= ADDR_WIDTH) begin
                mask = (w == ADDR_WIDTH) ? {ADDR_WIDTH{1'b1}} : ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - w));
                size = mask + 1'b1;
                if ((base & mask) != 0)
                    base = base + size - (base & mask);
                calcBaseAddrs[k*ADDR_WIDTH +: ADDR_WIDTH] = base;
                base = base + size;
            end
        end
    end
endfunction

parameter [TOTAL_REGIONS*ADDR_WIDTH-1:0] M_BASE_ADDR_INT = M_BASE_ADDR ? M_BASE_ADDR : calcBaseAddrs(0);

wire [TOTAL_REGIONS-1:0] reg_hit;
genvar gi, gj;
generate
    for (gi = 0; gi < M_COUNT; gi = gi + 1) begin : gen_m_hit
        for (gj = 0; gj < M_REGIONS; gj = gj + 1) begin : gen_r_hit
            localparam integer IDX = gi*M_REGIONS + gj;
            localparam [31:0] W = M_ADDR_WIDTH[IDX*32 +: 32];
            localparam [ADDR_WIDTH-1:0] BASE = M_BASE_ADDR_INT[IDX*ADDR_WIDTH +: ADDR_WIDTH];
            localparam [ADDR_WIDTH-1:0] CMP_MASK = (W == 0 || W >= ADDR_WIDTH) ? {ADDR_WIDTH{1'b0}} : ({ADDR_WIDTH{1'b1}} << W);
            if (W > 0 && W <= ADDR_WIDTH && M_CONNECT_VEC[gi*S_COUNT + S]) begin : active_reg
                assign reg_hit[IDX] = ((s_axil_aaddr & CMP_MASK) == (BASE & CMP_MASK));
            end else begin : inactive_reg
                assign reg_hit[IDX] = 1'b0;
            end
        end
    end
endgenerate

reg                  win_valid;
reg [31:0]           win_w;
reg [CL_M_COUNT-1:0] win_m;
reg                  win_sec;
integer mi, rj;
reg [31:0] rw;

always @* begin
    win_valid = 1'b0;
    win_w     = ADDR_WIDTH + 32'd1;
    win_m     = {CL_M_COUNT{1'b0}};
    win_sec   = 1'b0;
    rw        = 32'd0;
    // Scan from highest master/region downward and update strictly on narrower (<) width
    for (mi = M_COUNT - 1; mi >= 0; mi = mi - 1) begin
        for (rj = M_REGIONS - 1; rj >= 0; rj = rj - 1) begin
            rw = M_ADDR_WIDTH[(mi*M_REGIONS + rj)*32 +: 32];
            if (reg_hit[mi*M_REGIONS + rj]) begin
                if (!win_valid || (rw < win_w)) begin
                    win_valid = 1'b1;
                    win_w     = rw;
                    win_m     = mi[CL_M_COUNT-1:0];
                    win_sec   = M_SECURE_VEC[mi];
                end
            end
        end
    end
end

reg busy_reg;
reg ack_pulse_reg;
reg [CL_M_COUNT-1:0] sel_reg;
reg decerr_reg;
reg avalid_reg;
reg wc_valid_reg;
reg rc_valid_reg;

assign s_axil_aready = ack_pulse_reg;
assign m_select      = sel_reg;
assign m_axil_avalid = avalid_reg;
assign m_wc_select   = sel_reg;
assign m_wc_decerr   = decerr_reg;
assign m_wc_valid    = wc_valid_reg;
assign m_rc_select   = sel_reg;
assign m_rc_decerr   = decerr_reg;
assign m_rc_valid    = rc_valid_reg;

wire next_avalid   = avalid_reg && !m_axil_aready;
wire next_wc_valid = wc_valid_reg && !m_wc_ready;
wire next_rc_valid = rc_valid_reg && !m_rc_ready;

always @(posedge clk) begin
    if (rst) begin
        busy_reg      <= 1'b0;
        ack_pulse_reg <= 1'b0;
        sel_reg       <= {CL_M_COUNT{1'b0}};
        decerr_reg    <= 1'b0;
        avalid_reg    <= 1'b0;
        wc_valid_reg  <= 1'b0;
        rc_valid_reg  <= 1'b0;
    end else begin
        ack_pulse_reg <= 1'b0;
        if (!busy_reg) begin
            if (s_axil_avalid && !ack_pulse_reg) begin
                busy_reg <= 1'b1;
                if (win_valid && !(win_sec && s_axil_aprot[1])) begin
                    sel_reg      <= win_m;
                    decerr_reg   <= 1'b0;
                    avalid_reg   <= 1'b1;
                    wc_valid_reg <= WC_OUTPUT ? 1'b1 : 1'b0;
                    rc_valid_reg <= 1'b1;
                end else begin
                    sel_reg      <= {CL_M_COUNT{1'b0}};
                    decerr_reg   <= 1'b1;
                    avalid_reg   <= 1'b0;
                    wc_valid_reg <= WC_OUTPUT ? 1'b1 : 1'b0;
                    rc_valid_reg <= 1'b1;
                end
            end
        end else begin
            avalid_reg   <= next_avalid;
            wc_valid_reg <= next_wc_valid;
            rc_valid_reg <= next_rc_valid;
            if (!next_avalid && (!next_wc_valid || !WC_OUTPUT) && !next_rc_valid) begin
                busy_reg      <= 1'b0;
                ack_pulse_reg <= 1'b1;
            end
        end
    end
end

endmodule

`resetall
