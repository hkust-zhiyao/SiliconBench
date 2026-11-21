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

    output wire [AXI_ADDR_WIDTH-1:0]        m_axis_desc_addr,
    output wire [LEN_WIDTH-1:0]             m_axis_desc_len,
    output wire [M_TAG_WIDTH-1:0]           m_axis_desc_tag,
    output wire [AXIS_ID_WIDTH-1:0]         m_axis_desc_id,
    output wire [AXIS_DEST_WIDTH-1:0]       m_axis_desc_dest,
    output wire [AXIS_USER_WIDTH-1:0]       m_axis_desc_user,
    output wire                             m_axis_desc_valid,
    input  wire                             m_axis_desc_ready,

    input  wire [LEN_WIDTH-1:0]             s_axis_desc_status_len,
    input  wire [M_TAG_WIDTH-1:0]           s_axis_desc_status_tag,
    input  wire [AXIS_ID_WIDTH-1:0]         s_axis_desc_status_id,
    input  wire [AXIS_DEST_WIDTH-1:0]       s_axis_desc_status_dest,
    input  wire [AXIS_USER_WIDTH-1:0]       s_axis_desc_status_user,
    input  wire [3:0]                       s_axis_desc_status_error,
    input  wire                             s_axis_desc_status_valid,

    input  wire [PORTS*AXI_ADDR_WIDTH-1:0]  s_axis_desc_addr,
    input  wire [PORTS*LEN_WIDTH-1:0]       s_axis_desc_len,
    input  wire [PORTS*S_TAG_WIDTH-1:0]     s_axis_desc_tag,
    input  wire [PORTS*AXIS_ID_WIDTH-1:0]   s_axis_desc_id,
    input  wire [PORTS*AXIS_DEST_WIDTH-1:0] s_axis_desc_dest,
    input  wire [PORTS*AXIS_USER_WIDTH-1:0] s_axis_desc_user,
    input  wire [PORTS-1:0]                 s_axis_desc_valid,
    output wire [PORTS-1:0]                 s_axis_desc_ready,

    output wire [PORTS*LEN_WIDTH-1:0]       m_axis_desc_status_len,
    output wire [PORTS*S_TAG_WIDTH-1:0]     m_axis_desc_status_tag,
    output wire [PORTS*AXIS_ID_WIDTH-1:0]   m_axis_desc_status_id,
    output wire [PORTS*AXIS_DEST_WIDTH-1:0] m_axis_desc_status_dest,
    output wire [PORTS*AXIS_USER_WIDTH-1:0] m_axis_desc_status_user,
    output wire [PORTS*4-1:0]               m_axis_desc_status_error,
    output wire [PORTS-1:0]                 m_axis_desc_status_valid
);

localparam CL_PORTS = PORTS > 1 ? $clog2(PORTS) : 1;

wire [PORTS-1:0] request;
wire [PORTS-1:0] acknowledge;
wire [PORTS-1:0] grant;
wire grant_valid;
wire [CL_PORTS-1:0] grant_encoded;

// 2-deep circular descriptor FIFO
reg [AXI_ADDR_WIDTH-1:0]  fifo_addr [0:1];
reg [LEN_WIDTH-1:0]       fifo_len  [0:1];
reg [M_TAG_WIDTH-1:0]     fifo_tag  [0:1];
reg [AXIS_ID_WIDTH-1:0]   fifo_id   [0:1];
reg [AXIS_DEST_WIDTH-1:0] fifo_dest [0:1];
reg [AXIS_USER_WIDTH-1:0] fifo_user [0:1];

reg [1:0] wr_ptr_reg = 2'd0;
reg [1:0] rd_ptr_reg = 2'd0;

wire fifo_empty = (wr_ptr_reg == rd_ptr_reg);
wire fifo_full  = (wr_ptr_reg == (rd_ptr_reg ^ 2'b10));
wire can_accept = !fifo_full;

generate
    if (PORTS > 1) begin : g_arb
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
    end else begin : g_one
        assign grant = s_axis_desc_valid;
        assign grant_valid = s_axis_desc_valid[0];
        assign grant_encoded = 1'b0;
    end
endgenerate

assign s_axis_desc_ready = (can_accept && grant_valid) ? grant : {PORTS{1'b0}};
assign request = s_axis_desc_valid & ~grant;
assign acknowledge = grant & s_axis_desc_valid & s_axis_desc_ready;

wire push_en = can_accept && grant_valid && s_axis_desc_valid[grant_encoded];
wire pop_en  = !fifo_empty && m_axis_desc_ready;

reg [M_TAG_WIDTH-1:0] muxed_tag;
integer b;
always @* begin
    muxed_tag = {M_TAG_WIDTH{1'b0}};
    muxed_tag[0 +: S_TAG_WIDTH] = s_axis_desc_tag[grant_encoded*S_TAG_WIDTH +: S_TAG_WIDTH];
    if (PORTS > 1) begin
        for (b = 0; b < CL_PORTS; b = b + 1) begin
            muxed_tag[S_TAG_WIDTH + b] = grant_encoded[b];
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        wr_ptr_reg <= 2'd0;
        rd_ptr_reg <= 2'd0;
    end else begin
        if (push_en) begin
            fifo_addr[wr_ptr_reg[0]] <= s_axis_desc_addr[grant_encoded*AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH];
            fifo_len[wr_ptr_reg[0]]  <= s_axis_desc_len[grant_encoded*LEN_WIDTH +: LEN_WIDTH];
            fifo_tag[wr_ptr_reg[0]]  <= muxed_tag;
            fifo_id[wr_ptr_reg[0]]   <= s_axis_desc_id[grant_encoded*AXIS_ID_WIDTH +: AXIS_ID_WIDTH];
            fifo_dest[wr_ptr_reg[0]] <= s_axis_desc_dest[grant_encoded*AXIS_DEST_WIDTH +: AXIS_DEST_WIDTH];
            fifo_user[wr_ptr_reg[0]] <= s_axis_desc_user[grant_encoded*AXIS_USER_WIDTH +: AXIS_USER_WIDTH];
            wr_ptr_reg <= wr_ptr_reg + 2'd1;
        end
        if (pop_en) begin
            rd_ptr_reg <= rd_ptr_reg + 2'd1;
        end
    end
end

assign m_axis_desc_valid = !fifo_empty;
assign m_axis_desc_addr  = fifo_addr[rd_ptr_reg[0]];
assign m_axis_desc_len   = fifo_len[rd_ptr_reg[0]];
assign m_axis_desc_tag   = fifo_tag[rd_ptr_reg[0]];
assign m_axis_desc_id    = AXIS_ID_ENABLE   ? fifo_id[rd_ptr_reg[0]]   : {AXIS_ID_WIDTH{1'b0}};
assign m_axis_desc_dest  = AXIS_DEST_ENABLE ? fifo_dest[rd_ptr_reg[0]] : {AXIS_DEST_WIDTH{1'b0}};
assign m_axis_desc_user  = AXIS_USER_ENABLE ? fifo_user[rd_ptr_reg[0]] : {AXIS_USER_WIDTH{1'b0}};

reg [LEN_WIDTH-1:0]       st_len_r   = {LEN_WIDTH{1'b0}};
reg [S_TAG_WIDTH-1:0]     st_tag_r   = {S_TAG_WIDTH{1'b0}};
reg [AXIS_ID_WIDTH-1:0]   st_id_r    = {AXIS_ID_WIDTH{1'b0}};
reg [AXIS_DEST_WIDTH-1:0] st_dest_r  = {AXIS_DEST_WIDTH{1'b0}};
reg [AXIS_USER_WIDTH-1:0] st_user_r  = {AXIS_USER_WIDTH{1'b0}};
reg [3:0]                 st_err_r   = 4'd0;
reg [PORTS-1:0]           st_valid_r = {PORTS{1'b0}};

wire [CL_PORTS-1:0] ret_port;
generate
    if (PORTS > 1) begin : g_ret_port
        assign ret_port = s_axis_desc_status_tag[S_TAG_WIDTH +: CL_PORTS];
    end else begin : g_ret_one
        assign ret_port = 1'b0;
    end
endgenerate

integer p;
always @(posedge clk) begin
    if (rst) begin
        st_valid_r <= {PORTS{1'b0}};
    end else begin
        for (p = 0; p < PORTS; p = p + 1) begin
            st_valid_r[p] <= s_axis_desc_status_valid && ((PORTS == 1) ? 1'b1 : (ret_port == p[CL_PORTS-1:0]));
        end
    end
    if (s_axis_desc_status_valid) begin
        st_len_r  <= s_axis_desc_status_len;
        st_tag_r  <= s_axis_desc_status_tag[S_TAG_WIDTH-1:0];
        st_id_r   <= s_axis_desc_status_id;
        st_dest_r <= s_axis_desc_status_dest;
        st_user_r <= s_axis_desc_status_user;
        st_err_r  <= s_axis_desc_status_error;
    end
end

assign m_axis_desc_status_len   = {PORTS{st_len_r}};
assign m_axis_desc_status_tag   = {PORTS{st_tag_r}};
assign m_axis_desc_status_id    = AXIS_ID_ENABLE   ? {PORTS{st_id_r}}   : {AXIS_ID_WIDTH*PORTS{1'b0}};
assign m_axis_desc_status_dest  = AXIS_DEST_ENABLE ? {PORTS{st_dest_r}} : {AXIS_DEST_WIDTH*PORTS{1'b0}};
assign m_axis_desc_status_user  = AXIS_USER_ENABLE ? {PORTS{st_user_r}} : {AXIS_USER_WIDTH*PORTS{1'b0}};
assign m_axis_desc_status_error = {PORTS{st_err_r}};
assign m_axis_desc_status_valid = st_valid_r;

endmodule

`resetall
