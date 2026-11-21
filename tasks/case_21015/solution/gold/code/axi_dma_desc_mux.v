/*

Copyright (c) 2019 Alex Forencich

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
 * AXI DMA descriptor mux
 */
module axi_dma_desc_mux #
(
    parameter PORTS = 2,
    parameter AXI_ADDR_WIDTH = 16,
    parameter AXIS_ID_ENABLE = 0,
    parameter AXIS_ID_WIDTH = 8,
    parameter AXIS_DEST_ENABLE = 0,
    parameter AXIS_DEST_WIDTH = 8,
    parameter AXIS_USER_ENABLE = 1,
    parameter AXIS_USER_WIDTH = 1,
    parameter LEN_WIDTH = 20,
    parameter S_TAG_WIDTH = 8,
    parameter M_TAG_WIDTH = S_TAG_WIDTH+$clog2(PORTS),
    parameter ARB_TYPE_ROUND_ROBIN = 1,
    parameter ARB_LSB_HIGH_PRIORITY = 1
)
(
    input  wire                             clk,
    input  wire                             rst,

    /*
     * Descriptor output (to AXI DMA core)
     */
    output wire [AXI_ADDR_WIDTH-1:0]        m_axis_desc_addr,
    output wire [LEN_WIDTH-1:0]             m_axis_desc_len,
    output wire [M_TAG_WIDTH-1:0]           m_axis_desc_tag,
    output wire [AXIS_ID_WIDTH-1:0]         m_axis_desc_id,
    output wire [AXIS_DEST_WIDTH-1:0]       m_axis_desc_dest,
    output wire [AXIS_USER_WIDTH-1:0]       m_axis_desc_user,
    output wire                             m_axis_desc_valid,
    input  wire                             m_axis_desc_ready,

    /*
     * Descriptor status input (from AXI DMA core)
     */
    input  wire [LEN_WIDTH-1:0]             s_axis_desc_status_len,
    input  wire [M_TAG_WIDTH-1:0]           s_axis_desc_status_tag,
    input  wire [AXIS_ID_WIDTH-1:0]         s_axis_desc_status_id,
    input  wire [AXIS_DEST_WIDTH-1:0]       s_axis_desc_status_dest,
    input  wire [AXIS_USER_WIDTH-1:0]       s_axis_desc_status_user,
    input  wire [3:0]                       s_axis_desc_status_error,
    input  wire                             s_axis_desc_status_valid,

    /*
     * Descriptor input
     */
    input  wire [PORTS*AXI_ADDR_WIDTH-1:0]  s_axis_desc_addr,
    input  wire [PORTS*LEN_WIDTH-1:0]       s_axis_desc_len,
    input  wire [PORTS*S_TAG_WIDTH-1:0]     s_axis_desc_tag,
    input  wire [PORTS*AXIS_ID_WIDTH-1:0]   s_axis_desc_id,
    input  wire [PORTS*AXIS_DEST_WIDTH-1:0] s_axis_desc_dest,
    input  wire [PORTS*AXIS_USER_WIDTH-1:0] s_axis_desc_user,
    input  wire [PORTS-1:0]                 s_axis_desc_valid,
    output wire [PORTS-1:0]                 s_axis_desc_ready,

    /*
     * Descriptor status output
     */
    output wire [PORTS*LEN_WIDTH-1:0]       m_axis_desc_status_len,
    output wire [PORTS*S_TAG_WIDTH-1:0]     m_axis_desc_status_tag,
    output wire [PORTS*AXIS_ID_WIDTH-1:0]   m_axis_desc_status_id,
    output wire [PORTS*AXIS_DEST_WIDTH-1:0] m_axis_desc_status_dest,
    output wire [PORTS*AXIS_USER_WIDTH-1:0] m_axis_desc_status_user,
    output wire [PORTS*4-1:0]               m_axis_desc_status_error,
    output wire [PORTS-1:0]                 m_axis_desc_status_valid
);

localparam CL_PORTS = PORTS > 1 ? $clog2(PORTS) : 1;
localparam TAG_PORT_BITS = PORTS > 1 ? $clog2(PORTS) : 0;

initial begin
    if (M_TAG_WIDTH < S_TAG_WIDTH + TAG_PORT_BITS) begin
        $error("Error: M_TAG_WIDTH must be at least $clog2(PORTS) larger than S_TAG_WIDTH (instance %m)");
        $finish;
    end
end

wire [PORTS-1:0] request;
wire [PORTS-1:0] acknowledge;
wire [PORTS-1:0] grant;
wire grant_valid;
wire [CL_PORTS-1:0] grant_encoded;

reg  [AXI_ADDR_WIDTH-1:0]  m_axis_desc_addr_int;
reg  [LEN_WIDTH-1:0]       m_axis_desc_len_int;
reg  [M_TAG_WIDTH-1:0]     m_axis_desc_tag_int;
reg  [AXIS_ID_WIDTH-1:0]   m_axis_desc_id_int;
reg  [AXIS_DEST_WIDTH-1:0] m_axis_desc_dest_int;
reg  [AXIS_USER_WIDTH-1:0] m_axis_desc_user_int;
reg                        m_axis_desc_valid_int;
reg                        m_axis_desc_ready_int_reg = 1'b0;
wire                       m_axis_desc_ready_int_early;

assign s_axis_desc_ready = (m_axis_desc_ready_int_reg && grant_valid) ? ({{(PORTS-1){1'b0}}, 1'b1} << grant_encoded) : {PORTS{1'b0}};

wire [AXI_ADDR_WIDTH-1:0]  current_s_desc_addr  = s_axis_desc_addr[grant_encoded*AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH];
wire [LEN_WIDTH-1:0]       current_s_desc_len   = s_axis_desc_len[grant_encoded*LEN_WIDTH +: LEN_WIDTH];
wire [S_TAG_WIDTH-1:0]     current_s_desc_tag   = s_axis_desc_tag[grant_encoded*S_TAG_WIDTH +: S_TAG_WIDTH];
wire [AXIS_ID_WIDTH-1:0]   current_s_desc_id    = s_axis_desc_id[grant_encoded*AXIS_ID_WIDTH +: AXIS_ID_WIDTH];
wire [AXIS_DEST_WIDTH-1:0] current_s_desc_dest  = s_axis_desc_dest[grant_encoded*AXIS_DEST_WIDTH +: AXIS_DEST_WIDTH];
wire [AXIS_USER_WIDTH-1:0] current_s_desc_user  = s_axis_desc_user[grant_encoded*AXIS_USER_WIDTH +: AXIS_USER_WIDTH];
wire                       current_s_desc_valid = s_axis_desc_valid[grant_encoded];

generate
    if (PORTS > 1) begin : gen_arb
        arbiter #(
            .PORTS(PORTS),
            .ARB_TYPE_ROUND_ROBIN(ARB_TYPE_ROUND_ROBIN),
            .ARB_BLOCK(1),
            .ARB_BLOCK_ACK(1),
            .ARB_LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
        )
        arb_inst (
            .clk(clk),
            .rst(rst),
            .request(request),
            .acknowledge(acknowledge),
            .grant(grant),
            .grant_valid(grant_valid),
            .grant_encoded(grant_encoded)
        );
    end else begin : gen_single
        assign grant = s_axis_desc_valid;
        assign grant_valid = s_axis_desc_valid[0];
        assign grant_encoded = 1'b0;
    end
endgenerate

assign request = s_axis_desc_valid & ~grant;
assign acknowledge = grant & s_axis_desc_valid & s_axis_desc_ready;

wire [M_TAG_WIDTH-1:0] packed_m_tag;
generate
    if (PORTS > 1) begin : gen_pack_multi
        if (M_TAG_WIDTH > S_TAG_WIDTH + CL_PORTS) begin : gen_pack_pad
            assign packed_m_tag = {{(M_TAG_WIDTH-S_TAG_WIDTH-CL_PORTS){1'b0}}, grant_encoded, current_s_desc_tag};
        end else begin : gen_pack_exact
            assign packed_m_tag = {grant_encoded, current_s_desc_tag};
        end
    end else begin : gen_pack_single
        if (M_TAG_WIDTH > S_TAG_WIDTH) begin : gen_pack_spad
            assign packed_m_tag = {{(M_TAG_WIDTH-S_TAG_WIDTH){1'b0}}, current_s_desc_tag};
        end else begin : gen_pack_sexact
            assign packed_m_tag = current_s_desc_tag;
        end
    end
endgenerate

always @* begin
    m_axis_desc_addr_int  = current_s_desc_addr;
    m_axis_desc_len_int   = current_s_desc_len;
    m_axis_desc_tag_int   = packed_m_tag;
    m_axis_desc_id_int    = current_s_desc_id;
    m_axis_desc_dest_int  = current_s_desc_dest;
    m_axis_desc_user_int  = current_s_desc_user;
    m_axis_desc_valid_int = current_s_desc_valid && m_axis_desc_ready_int_reg && grant_valid;
end

reg [AXI_ADDR_WIDTH-1:0]  m_axis_desc_addr_reg  = {AXI_ADDR_WIDTH{1'b0}};
reg [LEN_WIDTH-1:0]       m_axis_desc_len_reg   = {LEN_WIDTH{1'b0}};
reg [M_TAG_WIDTH-1:0]     m_axis_desc_tag_reg   = {M_TAG_WIDTH{1'b0}};
reg [AXIS_ID_WIDTH-1:0]   m_axis_desc_id_reg    = {AXIS_ID_WIDTH{1'b0}};
reg [AXIS_DEST_WIDTH-1:0] m_axis_desc_dest_reg  = {AXIS_DEST_WIDTH{1'b0}};
reg [AXIS_USER_WIDTH-1:0] m_axis_desc_user_reg  = {AXIS_USER_WIDTH{1'b0}};
reg                       m_axis_desc_valid_reg = 1'b0, m_axis_desc_valid_next;

reg [AXI_ADDR_WIDTH-1:0]  temp_m_axis_desc_addr_reg  = {AXI_ADDR_WIDTH{1'b0}};
reg [LEN_WIDTH-1:0]       temp_m_axis_desc_len_reg   = {LEN_WIDTH{1'b0}};
reg [M_TAG_WIDTH-1:0]     temp_m_axis_desc_tag_reg   = {M_TAG_WIDTH{1'b0}};
reg [AXIS_ID_WIDTH-1:0]   temp_m_axis_desc_id_reg    = {AXIS_ID_WIDTH{1'b0}};
reg [AXIS_DEST_WIDTH-1:0] temp_m_axis_desc_dest_reg  = {AXIS_DEST_WIDTH{1'b0}};
reg [AXIS_USER_WIDTH-1:0] temp_m_axis_desc_user_reg  = {AXIS_USER_WIDTH{1'b0}};
reg                       temp_m_axis_desc_valid_reg = 1'b0, temp_m_axis_desc_valid_next;

reg store_axis_int_to_output;
reg store_axis_int_to_temp;
reg store_axis_temp_to_output;

assign m_axis_desc_addr  = m_axis_desc_addr_reg;
assign m_axis_desc_len   = m_axis_desc_len_reg;
assign m_axis_desc_tag   = m_axis_desc_tag_reg;
assign m_axis_desc_id    = AXIS_ID_ENABLE   ? m_axis_desc_id_reg   : {AXIS_ID_WIDTH{1'b0}};
assign m_axis_desc_dest  = AXIS_DEST_ENABLE ? m_axis_desc_dest_reg : {AXIS_DEST_WIDTH{1'b0}};
assign m_axis_desc_user  = AXIS_USER_ENABLE ? m_axis_desc_user_reg : {AXIS_USER_WIDTH{1'b0}};
assign m_axis_desc_valid = m_axis_desc_valid_reg;

assign m_axis_desc_ready_int_early = m_axis_desc_ready || (!temp_m_axis_desc_valid_reg && (!m_axis_desc_valid_reg || !m_axis_desc_valid_int));

always @* begin
    m_axis_desc_valid_next = m_axis_desc_valid_reg;
    temp_m_axis_desc_valid_next = temp_m_axis_desc_valid_reg;

    store_axis_int_to_output = 1'b0;
    store_axis_int_to_temp = 1'b0;
    store_axis_temp_to_output = 1'b0;

    if (m_axis_desc_ready_int_reg) begin
        if (m_axis_desc_ready || !m_axis_desc_valid_reg) begin
            m_axis_desc_valid_next = m_axis_desc_valid_int;
            store_axis_int_to_output = 1'b1;
        end else begin
            temp_m_axis_desc_valid_next = m_axis_desc_valid_int;
            store_axis_int_to_temp = 1'b1;
        end
    end else if (m_axis_desc_ready) begin
        m_axis_desc_valid_next = temp_m_axis_desc_valid_reg;
        temp_m_axis_desc_valid_next = 1'b0;
        store_axis_temp_to_output = 1'b1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        m_axis_desc_valid_reg <= 1'b0;
        m_axis_desc_ready_int_reg <= 1'b0;
        temp_m_axis_desc_valid_reg <= 1'b0;
    end else begin
        m_axis_desc_valid_reg <= m_axis_desc_valid_next;
        m_axis_desc_ready_int_reg <= m_axis_desc_ready_int_early;
        temp_m_axis_desc_valid_reg <= temp_m_axis_desc_valid_next;
    end

    if (store_axis_int_to_output) begin
        m_axis_desc_addr_reg <= m_axis_desc_addr_int;
        m_axis_desc_len_reg  <= m_axis_desc_len_int;
        m_axis_desc_tag_reg  <= m_axis_desc_tag_int;
        m_axis_desc_id_reg   <= m_axis_desc_id_int;
        m_axis_desc_dest_reg <= m_axis_desc_dest_int;
        m_axis_desc_user_reg <= m_axis_desc_user_int;
    end else if (store_axis_temp_to_output) begin
        m_axis_desc_addr_reg <= temp_m_axis_desc_addr_reg;
        m_axis_desc_len_reg  <= temp_m_axis_desc_len_reg;
        m_axis_desc_tag_reg  <= temp_m_axis_desc_tag_reg;
        m_axis_desc_id_reg   <= temp_m_axis_desc_id_reg;
        m_axis_desc_dest_reg <= temp_m_axis_desc_dest_reg;
        m_axis_desc_user_reg <= temp_m_axis_desc_user_reg;
    end

    if (store_axis_int_to_temp) begin
        temp_m_axis_desc_addr_reg <= m_axis_desc_addr_int;
        temp_m_axis_desc_len_reg  <= m_axis_desc_len_int;
        temp_m_axis_desc_tag_reg  <= m_axis_desc_tag_int;
        temp_m_axis_desc_id_reg   <= m_axis_desc_id_int;
        temp_m_axis_desc_dest_reg <= m_axis_desc_dest_int;
        temp_m_axis_desc_user_reg <= m_axis_desc_user_int;
    end
end

reg [LEN_WIDTH-1:0]       m_axis_desc_status_len_reg   = {LEN_WIDTH{1'b0}};
reg [S_TAG_WIDTH-1:0]     m_axis_desc_status_tag_reg   = {S_TAG_WIDTH{1'b0}};
reg [AXIS_ID_WIDTH-1:0]   m_axis_desc_status_id_reg    = {AXIS_ID_WIDTH{1'b0}};
reg [AXIS_DEST_WIDTH-1:0] m_axis_desc_status_dest_reg  = {AXIS_DEST_WIDTH{1'b0}};
reg [AXIS_USER_WIDTH-1:0] m_axis_desc_status_user_reg  = {AXIS_USER_WIDTH{1'b0}};
reg [3:0]                 m_axis_desc_status_error_reg = 4'd0;
reg [PORTS-1:0]           m_axis_desc_status_valid_reg = {PORTS{1'b0}};

wire [CL_PORTS-1:0] status_port_idx;
generate
    if (PORTS > 1) begin : gen_demux_multi
        assign status_port_idx = s_axis_desc_status_tag[S_TAG_WIDTH +: CL_PORTS];
    end else begin : gen_demux_single
        assign status_port_idx = 1'b0;
    end
endgenerate

assign m_axis_desc_status_len   = {PORTS{m_axis_desc_status_len_reg}};
assign m_axis_desc_status_tag   = {PORTS{m_axis_desc_status_tag_reg}};
assign m_axis_desc_status_id    = AXIS_ID_ENABLE   ? {PORTS{m_axis_desc_status_id_reg}}   : {AXIS_ID_WIDTH*PORTS{1'b0}};
assign m_axis_desc_status_dest  = AXIS_DEST_ENABLE ? {PORTS{m_axis_desc_status_dest_reg}} : {AXIS_DEST_WIDTH*PORTS{1'b0}};
assign m_axis_desc_status_user  = AXIS_USER_ENABLE ? {PORTS{m_axis_desc_status_user_reg}} : {AXIS_USER_WIDTH*PORTS{1'b0}};
assign m_axis_desc_status_error = {PORTS{m_axis_desc_status_error_reg}};
assign m_axis_desc_status_valid = m_axis_desc_status_valid_reg;

always @(posedge clk) begin
    if (rst) begin
        m_axis_desc_status_valid_reg <= {PORTS{1'b0}};
    end else if (s_axis_desc_status_valid && (PORTS == 1 || status_port_idx < PORTS)) begin
        m_axis_desc_status_valid_reg <= {{(PORTS-1){1'b0}}, 1'b1} << status_port_idx;
    end else begin
        m_axis_desc_status_valid_reg <= {PORTS{1'b0}};
    end

    if (s_axis_desc_status_valid) begin
        m_axis_desc_status_len_reg   <= s_axis_desc_status_len;
        m_axis_desc_status_tag_reg   <= s_axis_desc_status_tag[S_TAG_WIDTH-1:0];
        m_axis_desc_status_id_reg    <= s_axis_desc_status_id;
        m_axis_desc_status_dest_reg  <= s_axis_desc_status_dest;
        m_axis_desc_status_user_reg  <= s_axis_desc_status_user;
        m_axis_desc_status_error_reg <= s_axis_desc_status_error;
    end
end

endmodule

`resetall
