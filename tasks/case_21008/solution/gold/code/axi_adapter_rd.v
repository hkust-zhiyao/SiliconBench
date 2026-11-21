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
 * AXI4 width adapter (read channel)
 */
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

    /*
     * AXI slave interface
     */
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

    /*
     * AXI master interface
     */
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
    STATE_DATA_READ = 2'd2,
    STATE_DATA_SPLIT = 2'd3;

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
reg [1:0] resp_reg = 2'd0, resp_next;
reg [RUSER_WIDTH-1:0] ruser_reg = {RUSER_WIDTH{1'b0}}, ruser_next;
reg [7:0] burst_reg = 8'd0, burst_next;
reg [2:0] burst_size_reg = 3'd0, burst_size_next;
reg [7:0] master_burst_reg = 8'd0, master_burst_next;
reg [2:0] master_burst_size_reg = 3'd0, master_burst_size_next;

reg s_axi_arready_reg = 1'b0, s_axi_arready_next;

reg [ID_WIDTH-1:0] m_axi_arid_reg = {ID_WIDTH{1'b0}}, m_axi_arid_next;
reg [ADDR_WIDTH-1:0] m_axi_araddr_reg = {ADDR_WIDTH{1'b0}}, m_axi_araddr_next;
reg [7:0] m_axi_arlen_reg = 8'd0, m_axi_arlen_next;
reg [2:0] m_axi_arsize_reg = 3'd0, m_axi_arsize_next;
reg [1:0] m_axi_arburst_reg = 2'd0, m_axi_arburst_next;
reg m_axi_arlock_reg = 1'b0, m_axi_arlock_next;
reg [3:0] m_axi_arcache_reg = 4'd0, m_axi_arcache_next;
reg [2:0] m_axi_arprot_reg = 3'd0, m_axi_arprot_next;
reg [3:0] m_axi_arqos_reg = 4'd0, m_axi_arqos_next;
reg [3:0] m_axi_arregion_reg = 4'd0, m_axi_arregion_next;
reg [ARUSER_WIDTH-1:0] m_axi_aruser_reg = {ARUSER_WIDTH{1'b0}}, m_axi_aruser_next;
reg m_axi_arvalid_reg = 1'b0, m_axi_arvalid_next;
reg m_axi_rready_reg = 1'b0, m_axi_rready_next;

// internal datapath
reg  [ID_WIDTH-1:0]     s_axi_rid_int;
reg  [S_DATA_WIDTH-1:0] s_axi_rdata_int;
reg  [1:0]              s_axi_rresp_int;
reg                     s_axi_rlast_int;
reg  [RUSER_WIDTH-1:0]  s_axi_ruser_int;
reg                     s_axi_rvalid_int;
reg                     s_axi_rready_int_reg = 1'b0;
wire                    s_axi_rready_int_early;

assign s_axi_arready = s_axi_arready_reg;

assign m_axi_arid = FORWARD_ID ? m_axi_arid_reg : {ID_WIDTH{1'b0}};
assign m_axi_araddr = m_axi_araddr_reg;
assign m_axi_arlen = m_axi_arlen_reg;
assign m_axi_arsize = m_axi_arsize_reg;
assign m_axi_arburst = m_axi_arburst_reg;
assign m_axi_arlock = m_axi_arlock_reg;
assign m_axi_arcache = m_axi_arcache_reg;
assign m_axi_arprot = m_axi_arprot_reg;
assign m_axi_arqos = m_axi_arqos_reg;
assign m_axi_arregion = m_axi_arregion_reg;
assign m_axi_aruser = ARUSER_ENABLE ? m_axi_aruser_reg : {ARUSER_WIDTH{1'b0}};
assign m_axi_arvalid = m_axi_arvalid_reg;
assign m_axi_rready = m_axi_rready_reg;

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
        resp_next = resp_reg;
        ruser_next = ruser_reg;
        burst_next = burst_reg;
        burst_size_next = burst_size_reg;
        master_burst_next = master_burst_reg;
        master_burst_size_next = master_burst_size_reg;

        s_axi_arready_next = 1'b0;
        m_axi_arid_next = m_axi_arid_reg;
        m_axi_araddr_next = m_axi_araddr_reg;
        m_axi_arlen_next = m_axi_arlen_reg;
        m_axi_arsize_next = m_axi_arsize_reg;
        m_axi_arburst_next = m_axi_arburst_reg;
        m_axi_arlock_next = m_axi_arlock_reg;
        m_axi_arcache_next = m_axi_arcache_reg;
        m_axi_arprot_next = m_axi_arprot_reg;
        m_axi_arqos_next = m_axi_arqos_reg;
        m_axi_arregion_next = m_axi_arregion_reg;
        m_axi_aruser_next = m_axi_aruser_reg;
        m_axi_arvalid_next = m_axi_arvalid_reg && !m_axi_arready;
        m_axi_rready_next = 1'b0;

        s_axi_rid_int = id_reg;
        s_axi_rdata_int = m_axi_rdata;
        s_axi_rresp_int = m_axi_rresp;
        s_axi_rlast_int = m_axi_rlast;
        s_axi_ruser_int = m_axi_ruser;
        s_axi_rvalid_int = 1'b0;

        case (state_reg)
            STATE_IDLE: begin
                s_axi_arready_next = !m_axi_arvalid;

                if (s_axi_arready && s_axi_arvalid) begin
                    s_axi_arready_next = 1'b0;
                    id_next = s_axi_arid;
                    m_axi_arid_next = s_axi_arid;
                    m_axi_araddr_next = s_axi_araddr;
                    m_axi_arlen_next = s_axi_arlen;
                    m_axi_arsize_next = s_axi_arsize;
                    m_axi_arburst_next = s_axi_arburst;
                    m_axi_arlock_next = s_axi_arlock;
                    m_axi_arcache_next = s_axi_arcache;
                    m_axi_arprot_next = s_axi_arprot;
                    m_axi_arqos_next = s_axi_arqos;
                    m_axi_arregion_next = s_axi_arregion;
                    m_axi_aruser_next = s_axi_aruser;
                    m_axi_arvalid_next = 1'b1;
                    m_axi_rready_next = s_axi_rready_int_early;
                    state_next = STATE_DATA;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_DATA: begin
                m_axi_rready_next = s_axi_rready_int_early;

                if (m_axi_rready && m_axi_rvalid) begin
                    s_axi_rid_int = id_reg;
                    s_axi_rdata_int = m_axi_rdata;
                    s_axi_rresp_int = m_axi_rresp;
                    s_axi_rlast_int = m_axi_rlast;
                    s_axi_ruser_int = m_axi_ruser;
                    s_axi_rvalid_int = 1'b1;
                    if (m_axi_rlast) begin
                        m_axi_rready_next = 1'b0;
                        s_axi_arready_next = !m_axi_arvalid;
                        state_next = STATE_IDLE;
                    end else begin
                        state_next = STATE_DATA;
                    end
                end else begin
                    state_next = STATE_DATA;
                end
            end
            default: begin
                state_next = STATE_IDLE;
            end
        endcase
    end
end else if (EXPAND) begin : gen_upsize
    localparam [ADDR_WIDTH-1:0] M_OFFSET_MASK = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << M_BURST_SIZE) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};

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
        resp_next = resp_reg;
        ruser_next = ruser_reg;
        burst_next = burst_reg;
        burst_size_next = burst_size_reg;
        master_burst_next = master_burst_reg;
        master_burst_size_next = master_burst_size_reg;

        s_axi_arready_next = 1'b0;
        m_axi_arid_next = m_axi_arid_reg;
        m_axi_araddr_next = m_axi_araddr_reg;
        m_axi_arlen_next = m_axi_arlen_reg;
        m_axi_arsize_next = m_axi_arsize_reg;
        m_axi_arburst_next = m_axi_arburst_reg;
        m_axi_arlock_next = m_axi_arlock_reg;
        m_axi_arcache_next = m_axi_arcache_reg;
        m_axi_arprot_next = m_axi_arprot_reg;
        m_axi_arqos_next = m_axi_arqos_reg;
        m_axi_arregion_next = m_axi_arregion_reg;
        m_axi_aruser_next = m_axi_aruser_reg;
        m_axi_arvalid_next = m_axi_arvalid_reg && !m_axi_arready;
        m_axi_rready_next = 1'b0;

        s_axi_rid_int = id_reg;
        s_axi_rdata_int = m_axi_rdata[S_DATA_WIDTH-1:0];
        s_axi_rresp_int = m_axi_rresp;
        s_axi_rlast_int = m_axi_rlast;
        s_axi_ruser_int = m_axi_ruser;
        s_axi_rvalid_int = 1'b0;

        wmask_init = calc_wrap_mask(s_axi_arsize, s_axi_arlen);
        s_align_mask_init = ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_axi_arsize) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        start_off_init = {{(16-M_ADDR_BIT_OFFSET){1'b0}}, s_axi_araddr[M_ADDR_BIT_OFFSET-1:0]} & {{(16-M_ADDR_BIT_OFFSET){1'b1}}, s_align_mask_init[M_ADDR_BIT_OFFSET-1:0]};
        total_span_init = start_off_init + ({8'd0, s_axi_arlen} << s_axi_arsize);
        m_len_calc = total_span_init >> M_BURST_SIZE;

        can_repack_wide = CONVERT_BURST && s_axi_arcache[1] && (CONVERT_NARROW_BURST || (s_axi_arsize == S_BURST_SIZE_LP)) &&
                          ((s_axi_arburst == 2'b01) ||
                           ((s_axi_arburst == 2'b10) && (((s_axi_araddr & wmask_init) == {ADDR_WIDTH{1'b0}}) || (wmask_init == M_OFFSET_MASK))));

        case (state_reg)
            STATE_IDLE: begin
                s_axi_arready_next = !m_axi_arvalid;

                if (s_axi_arready && s_axi_arvalid) begin
                    s_axi_arready_next = 1'b0;
                    id_next = s_axi_arid;
                    m_axi_arid_next = s_axi_arid;
                    addr_next = s_axi_araddr;
                    orig_addr_next = s_axi_araddr;
                    wrap_mask_next = wmask_init;
                    burst_type_next = s_axi_arburst;
                    burst_next = s_axi_arlen;
                    burst_size_next = s_axi_arsize;
                    if (can_repack_wide) begin
                        master_burst_size_next = M_BURST_SIZE_LP;
                        m_axi_araddr_next = s_axi_araddr & ~M_OFFSET_MASK;
                        m_axi_arlen_next = (s_axi_arburst == 2'b10 && wmask_init == M_OFFSET_MASK) ? 8'd0 : m_len_calc[7:0];
                        m_axi_arsize_next = M_BURST_SIZE_LP;
                        m_axi_arburst_next = 2'b01;
                        state_next = STATE_DATA_READ;
                    end else begin
                        master_burst_size_next = s_axi_arsize;
                        m_axi_araddr_next = s_axi_araddr;
                        m_axi_arlen_next = s_axi_arlen;
                        m_axi_arsize_next = s_axi_arsize;
                        m_axi_arburst_next = s_axi_arburst;
                        state_next = STATE_DATA;
                    end
                    m_axi_arlock_next = s_axi_arlock;
                    m_axi_arcache_next = s_axi_arcache;
                    m_axi_arprot_next = s_axi_arprot;
                    m_axi_arqos_next = s_axi_arqos;
                    m_axi_arregion_next = s_axi_arregion;
                    m_axi_aruser_next = s_axi_aruser;
                    m_axi_arvalid_next = 1'b1;
                    m_axi_rready_next = s_axi_rready_int_early;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_DATA: begin
                m_axi_rready_next = s_axi_rready_int_early;

                if (m_axi_rready && m_axi_rvalid) begin
                    s_axi_rid_int = id_reg;
                    s_axi_rdata_int = m_axi_rdata[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*S_DATA_WIDTH +: S_DATA_WIDTH];
                    s_axi_rresp_int = m_axi_rresp;
                    s_axi_rlast_int = m_axi_rlast;
                    s_axi_ruser_int = m_axi_ruser;
                    s_axi_rvalid_int = 1'b1;
                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
                    if (m_axi_rlast) begin
                        m_axi_rready_next = 1'b0;
                        s_axi_arready_next = !m_axi_arvalid;
                        state_next = STATE_IDLE;
                    end else begin
                        state_next = STATE_DATA;
                    end
                end else begin
                    state_next = STATE_DATA;
                end
            end
            STATE_DATA_READ: begin
                m_axi_rready_next = s_axi_rready_int_early;

                if (m_axi_rready && m_axi_rvalid) begin
                    s_axi_rid_int = id_reg;
                    data_next = m_axi_rdata;
                    resp_next = m_axi_rresp;
                    ruser_next = m_axi_ruser;
                    s_axi_rdata_int = m_axi_rdata[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*S_DATA_WIDTH +: S_DATA_WIDTH];
                    s_axi_rresp_int = m_axi_rresp;
                    s_axi_rlast_int = 1'b0;
                    s_axi_ruser_int = m_axi_ruser;
                    s_axi_rvalid_int = 1'b1;
                    burst_next = burst_reg - 8'd1;
                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
                    if (burst_reg == 8'd0) begin
                        m_axi_rready_next = 1'b0;
                        s_axi_arready_next = !m_axi_arvalid;
                        s_axi_rlast_int = 1'b1;
                        state_next = STATE_IDLE;
                    end else if (addr_next[M_ADDR_BIT_OFFSET] != addr_reg[M_ADDR_BIT_OFFSET]) begin
                        state_next = STATE_DATA_READ;
                    end else begin
                        m_axi_rready_next = 1'b0;
                        state_next = STATE_DATA_SPLIT;
                    end
                end else begin
                    state_next = STATE_DATA_READ;
                end
            end
            STATE_DATA_SPLIT: begin
                m_axi_rready_next = 1'b0;

                if (s_axi_rready_int_reg) begin
                    s_axi_rid_int = id_reg;
                    s_axi_rdata_int = data_reg[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*S_DATA_WIDTH +: S_DATA_WIDTH];
                    s_axi_rresp_int = resp_reg;
                    s_axi_rlast_int = 1'b0;
                    s_axi_ruser_int = ruser_reg;
                    s_axi_rvalid_int = 1'b1;
                    burst_next = burst_reg - 8'd1;
                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
                    if (burst_reg == 8'd0) begin
                        s_axi_arready_next = !m_axi_arvalid;
                        s_axi_rlast_int = 1'b1;
                        state_next = STATE_IDLE;
                    end else if (addr_next[M_ADDR_BIT_OFFSET] != addr_reg[M_ADDR_BIT_OFFSET]) begin
                        m_axi_rready_next = s_axi_rready_int_early;
                        state_next = STATE_DATA_READ;
                    end else begin
                        state_next = STATE_DATA_SPLIT;
                    end
                end else begin
                    state_next = STATE_DATA_SPLIT;
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
        resp_next = resp_reg;
        ruser_next = ruser_reg;
        burst_next = burst_reg;
        burst_size_next = burst_size_reg;
        master_burst_next = master_burst_reg;
        master_burst_size_next = master_burst_size_reg;

        s_axi_arready_next = 1'b0;
        m_axi_arid_next = m_axi_arid_reg;
        m_axi_araddr_next = m_axi_araddr_reg;
        m_axi_arlen_next = m_axi_arlen_reg;
        m_axi_arsize_next = m_axi_arsize_reg;
        m_axi_arburst_next = m_axi_arburst_reg;
        m_axi_arlock_next = m_axi_arlock_reg;
        m_axi_arcache_next = m_axi_arcache_reg;
        m_axi_arprot_next = m_axi_arprot_reg;
        m_axi_arqos_next = m_axi_arqos_reg;
        m_axi_arregion_next = m_axi_arregion_reg;
        m_axi_aruser_next = m_axi_aruser_reg;
        m_axi_arvalid_next = m_axi_arvalid_reg && !m_axi_arready;
        m_axi_rready_next = 1'b0;

        s_axi_rid_int = id_reg;
        s_axi_rdata_int = data_reg;
        s_axi_rresp_int = resp_reg;
        s_axi_rlast_int = 1'b0;
        s_axi_ruser_int = m_axi_ruser;
        s_axi_rvalid_int = 1'b0;

        wmask_init = calc_wrap_mask(s_axi_arsize, s_axi_arlen);
        sub_step_aligned = (addr_reg + ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << master_burst_size_reg)) &
                           ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << master_burst_size_reg) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
        slave_beat_done = (burst_size_reg <= M_BURST_SIZE_LP) || (sub_step_aligned[{2'b00, burst_size_reg}] != addr_reg[{2'b00, burst_size_reg}]);

        case (state_reg)
            STATE_IDLE: begin
                s_axi_arready_next = !m_axi_arvalid;
                data_next = {DATA_WIDTH{1'b0}};
                resp_next = 2'd0;

                if (s_axi_arready && s_axi_arvalid) begin
                    s_axi_arready_next = 1'b0;
                    id_next = s_axi_arid;
                    m_axi_arid_next = s_axi_arid;
                    m_axi_araddr_next = s_axi_araddr;
                    addr_next = s_axi_araddr;
                    orig_addr_next = s_axi_araddr;
                    wrap_mask_next = wmask_init;
                    burst_type_next = s_axi_arburst;
                    burst_next = s_axi_arlen;
                    burst_size_next = s_axi_arsize;
                    if (s_axi_arsize > M_BURST_SIZE_LP) begin
                        master_burst_next = calc_downsize_child_len(s_axi_araddr, wmask_init, s_axi_arlen, s_axi_arsize, s_axi_arburst);
                        master_burst_size_next = M_BURST_SIZE_LP;
                        m_axi_arlen_next = master_burst_next;
                        m_axi_arsize_next = M_BURST_SIZE_LP;
                        m_axi_arburst_next = 2'b01;
                    end else begin
                        master_burst_next = s_axi_arlen;
                        master_burst_size_next = s_axi_arsize;
                        m_axi_arlen_next = s_axi_arlen;
                        m_axi_arsize_next = s_axi_arsize;
                        m_axi_arburst_next = s_axi_arburst;
                    end
                    m_axi_arlock_next = s_axi_arlock;
                    m_axi_arcache_next = s_axi_arcache;
                    m_axi_arprot_next = s_axi_arprot;
                    m_axi_arqos_next = s_axi_arqos;
                    m_axi_arregion_next = s_axi_arregion;
                    m_axi_aruser_next = s_axi_aruser;
                    m_axi_arvalid_next = 1'b1;
                    m_axi_rready_next = 1'b0;
                    state_next = STATE_DATA;
                end else begin
                    state_next = STATE_IDLE;
                end
            end
            STATE_DATA: begin
                m_axi_rready_next = s_axi_rready_int_early && !m_axi_arvalid;

                if (m_axi_rready && m_axi_rvalid) begin
                    data_next[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET]*SEGMENT_DATA_WIDTH +: SEGMENT_DATA_WIDTH] = m_axi_rdata;
                    if (m_axi_rresp > resp_reg) begin
                        resp_next = m_axi_rresp;
                    end
                    s_axi_rid_int = id_reg;
                    s_axi_rdata_int = data_next;
                    s_axi_rresp_int = resp_next;
                    s_axi_rlast_int = 1'b0;
                    s_axi_ruser_int = m_axi_ruser;
                    s_axi_rvalid_int = 1'b0;
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
                    m_axi_araddr_next = addr_next;

                    if (slave_beat_done) begin
                        data_next = {DATA_WIDTH{1'b0}};
                        resp_next = 2'd0;
                        burst_next = burst_reg - 8'd1;
                        s_axi_rvalid_int = 1'b1;
                    end

                    if (master_burst_reg == 8'd0) begin
                        if (burst_reg == 8'd0) begin
                            m_axi_rready_next = 1'b0;
                            s_axi_rlast_int = 1'b1;
                            s_axi_rvalid_int = 1'b1;
                            s_axi_arready_next = !m_axi_arvalid;
                            state_next = STATE_IDLE;
                        end else begin
                            master_burst_next = calc_downsize_child_len(addr_next, wrap_mask_reg, burst_next, burst_size_reg, burst_type_reg);
                            m_axi_arlen_next = master_burst_next;
                            m_axi_arvalid_next = 1'b1;
                            m_axi_rready_next = 1'b0;
                            state_next = STATE_DATA;
                        end
                    end else begin
                        state_next = STATE_DATA;
                    end
                end else begin
                    state_next = STATE_DATA;
                end
            end
            default: begin
                state_next = STATE_IDLE;
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
    resp_reg <= resp_next;
    ruser_reg <= ruser_next;
    burst_reg <= burst_next;
    burst_size_reg <= burst_size_next;
    master_burst_reg <= master_burst_next;
    master_burst_size_reg <= master_burst_size_next;

    s_axi_arready_reg <= s_axi_arready_next;

    m_axi_arid_reg <= m_axi_arid_next;
    m_axi_araddr_reg <= m_axi_araddr_next;
    m_axi_arlen_reg <= m_axi_arlen_next;
    m_axi_arsize_reg <= m_axi_arsize_next;
    m_axi_arburst_reg <= m_axi_arburst_next;
    m_axi_arlock_reg <= m_axi_arlock_next;
    m_axi_arcache_reg <= m_axi_arcache_next;
    m_axi_arprot_reg <= m_axi_arprot_next;
    m_axi_arqos_reg <= m_axi_arqos_next;
    m_axi_arregion_reg <= m_axi_arregion_next;
    m_axi_aruser_reg <= m_axi_aruser_next;
    m_axi_arvalid_reg <= m_axi_arvalid_next;
    m_axi_rready_reg <= m_axi_rready_next;

    if (rst) begin
        state_reg <= STATE_IDLE;
        s_axi_arready_reg <= 1'b0;
        m_axi_arvalid_reg <= 1'b0;
        m_axi_rready_reg <= 1'b0;
    end
end

// output datapath logic
reg [ID_WIDTH-1:0]     s_axi_rid_reg    = {ID_WIDTH{1'b0}};
reg [S_DATA_WIDTH-1:0] s_axi_rdata_reg  = {S_DATA_WIDTH{1'b0}};
reg [1:0]              s_axi_rresp_reg  = 2'd0;
reg                    s_axi_rlast_reg  = 1'b0;
reg [RUSER_WIDTH-1:0]  s_axi_ruser_reg  = {RUSER_WIDTH{1'b0}};
reg                    s_axi_rvalid_reg = 1'b0, s_axi_rvalid_next;

reg [ID_WIDTH-1:0]     temp_s_axi_rid_reg    = {ID_WIDTH{1'b0}};
reg [S_DATA_WIDTH-1:0] temp_s_axi_rdata_reg  = {S_DATA_WIDTH{1'b0}};
reg [1:0]              temp_s_axi_rresp_reg  = 2'd0;
reg                    temp_s_axi_rlast_reg  = 1'b0;
reg [RUSER_WIDTH-1:0]  temp_s_axi_ruser_reg  = {RUSER_WIDTH{1'b0}};
reg                    temp_s_axi_rvalid_reg = 1'b0, temp_s_axi_rvalid_next;

// datapath control
reg store_axi_r_int_to_output;
reg store_axi_r_int_to_temp;
reg store_axi_r_temp_to_output;

assign s_axi_rid    = s_axi_rid_reg;
assign s_axi_rdata  = s_axi_rdata_reg;
assign s_axi_rresp  = s_axi_rresp_reg;
assign s_axi_rlast  = s_axi_rlast_reg;
assign s_axi_ruser  = RUSER_ENABLE ? s_axi_ruser_reg : {RUSER_WIDTH{1'b0}};
assign s_axi_rvalid = s_axi_rvalid_reg;

assign s_axi_rready_int_early = s_axi_rready | (~temp_s_axi_rvalid_reg & (~s_axi_rvalid_reg | ~s_axi_rvalid_int));

always @* begin
    s_axi_rvalid_next = s_axi_rvalid_reg;
    temp_s_axi_rvalid_next = temp_s_axi_rvalid_reg;

    store_axi_r_int_to_output = 1'b0;
    store_axi_r_int_to_temp = 1'b0;
    store_axi_r_temp_to_output = 1'b0;

    if (s_axi_rready_int_reg) begin
        if (s_axi_rready | ~s_axi_rvalid_reg) begin
            s_axi_rvalid_next = s_axi_rvalid_int;
            store_axi_r_int_to_output = 1'b1;
        end else begin
            temp_s_axi_rvalid_next = s_axi_rvalid_int;
            store_axi_r_int_to_temp = 1'b1;
        end
    end else if (s_axi_rready) begin
        s_axi_rvalid_next = temp_s_axi_rvalid_reg;
        temp_s_axi_rvalid_next = 1'b0;
        store_axi_r_temp_to_output = 1'b1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        s_axi_rvalid_reg <= 1'b0;
        s_axi_rready_int_reg <= 1'b0;
        temp_s_axi_rvalid_reg <= 1'b0;
    end else begin
        s_axi_rvalid_reg <= s_axi_rvalid_next;
        s_axi_rready_int_reg <= s_axi_rready_int_early;
        temp_s_axi_rvalid_reg <= temp_s_axi_rvalid_next;
    end

    if (store_axi_r_int_to_output) begin
        s_axi_rid_reg <= s_axi_rid_int;
        s_axi_rdata_reg <= s_axi_rdata_int;
        s_axi_rresp_reg <= s_axi_rresp_int;
        s_axi_rlast_reg <= s_axi_rlast_int;
        s_axi_ruser_reg <= s_axi_ruser_int;
    end else if (store_axi_r_temp_to_output) begin
        s_axi_rid_reg <= temp_s_axi_rid_reg;
        s_axi_rdata_reg <= temp_s_axi_rdata_reg;
        s_axi_rresp_reg <= temp_s_axi_rresp_reg;
        s_axi_rlast_reg <= temp_s_axi_rlast_reg;
        s_axi_ruser_reg <= temp_s_axi_ruser_reg;
    end

    if (store_axi_r_int_to_temp) begin
        temp_s_axi_rid_reg <= s_axi_rid_int;
        temp_s_axi_rdata_reg <= s_axi_rdata_int;
        temp_s_axi_rresp_reg <= s_axi_rresp_int;
        temp_s_axi_rlast_reg <= s_axi_rlast_int;
        temp_s_axi_ruser_reg <= s_axi_ruser_int;
    end
end

endmodule

`resetall
