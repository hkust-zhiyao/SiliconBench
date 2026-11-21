/*

Copyright (c) 2023 Alex Forencich

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
 * AXI4 virtual FIFO
 */
module axi_vfifo #
(
    // AXI channel count
    parameter AXI_CH = 1,
    // Width of AXI data bus in bits
    parameter AXI_DATA_WIDTH = 32,
    // Width of AXI address bus in bits
    parameter AXI_ADDR_WIDTH = 16,
    // Width of AXI wstrb (width of data bus in words)
    parameter AXI_STRB_WIDTH = (AXI_DATA_WIDTH/8),
    // Width of AXI ID signal
    parameter AXI_ID_WIDTH = 8,
    // Maximum AXI burst length to generate
    parameter AXI_MAX_BURST_LEN = 16,
    // Width of AXI stream interfaces in bits
    parameter AXIS_DATA_WIDTH = AXI_DATA_WIDTH*AXI_CH/2,
    // Use AXI stream tkeep signal
    parameter AXIS_KEEP_ENABLE = (AXIS_DATA_WIDTH>8),
    // AXI stream tkeep signal width (words per cycle)
    parameter AXIS_KEEP_WIDTH = (AXIS_DATA_WIDTH/8),
    // Use AXI stream tlast signal
    parameter AXIS_LAST_ENABLE = 1,
    // Propagate AXI stream tid signal
    parameter AXIS_ID_ENABLE = 0,
    // AXI stream tid signal width
    parameter AXIS_ID_WIDTH = 8,
    // Propagate AXI stream tdest signal
    parameter AXIS_DEST_ENABLE = 0,
    // AXI stream tdest signal width
    parameter AXIS_DEST_WIDTH = 8,
    // Propagate AXI stream tuser signal
    parameter AXIS_USER_ENABLE = 1,
    // AXI stream tuser signal width
    parameter AXIS_USER_WIDTH = 1,
    // Width of length field
    parameter LEN_WIDTH = AXI_ADDR_WIDTH,
    // Maximum segment width
    parameter MAX_SEG_WIDTH = 256,
    // Input FIFO depth for AXI write data (full-width words)
    parameter WRITE_FIFO_DEPTH = 64,
    // Max AXI write burst length
    parameter WRITE_MAX_BURST_LEN = WRITE_FIFO_DEPTH/4,
    // Output FIFO depth for AXI read data (full-width words)
    parameter READ_FIFO_DEPTH = 128,
    // Max AXI read burst length
    parameter READ_MAX_BURST_LEN = WRITE_MAX_BURST_LEN
)
(
    input  wire                               clk,
    input  wire                               rst,

    /*
     * AXI stream data input
     */
    input  wire                               s_axis_clk,
    input  wire                               s_axis_rst,
    output wire                               s_axis_rst_out,
    input  wire [AXIS_DATA_WIDTH-1:0]         s_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0]         s_axis_tkeep,
    input  wire                               s_axis_tvalid,
    output wire                               s_axis_tready,
    input  wire                               s_axis_tlast,
    input  wire [AXIS_ID_WIDTH-1:0]           s_axis_tid,
    input  wire [AXIS_DEST_WIDTH-1:0]         s_axis_tdest,
    input  wire [AXIS_USER_WIDTH-1:0]         s_axis_tuser,

    /*
     * AXI stream data output
     */
    input  wire                               m_axis_clk,
    input  wire                               m_axis_rst,
    output wire                               m_axis_rst_out,
    output wire [AXIS_DATA_WIDTH-1:0]         m_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0]         m_axis_tkeep,
    output wire                               m_axis_tvalid,
    input  wire                               m_axis_tready,
    output wire                               m_axis_tlast,
    output wire [AXIS_ID_WIDTH-1:0]           m_axis_tid,
    output wire [AXIS_DEST_WIDTH-1:0]         m_axis_tdest,
    output wire [AXIS_USER_WIDTH-1:0]         m_axis_tuser,

    /*
     * AXI master interfaces
     */
    input  wire [AXI_CH-1:0]                  m_axi_clk,
    input  wire [AXI_CH-1:0]                  m_axi_rst,
    output wire [AXI_CH*AXI_ID_WIDTH-1:0]     m_axi_awid,
    output wire [AXI_CH*AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
    output wire [AXI_CH*8-1:0]                m_axi_awlen,
    output wire [AXI_CH*3-1:0]                m_axi_awsize,
    output wire [AXI_CH*2-1:0]                m_axi_awburst,
    output wire [AXI_CH-1:0]                  m_axi_awlock,
    output wire [AXI_CH*4-1:0]                m_axi_awcache,
    output wire [AXI_CH*3-1:0]                m_axi_awprot,
    output wire [AXI_CH-1:0]                  m_axi_awvalid,
    input  wire [AXI_CH-1:0]                  m_axi_awready,
    output wire [AXI_CH*AXI_DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [AXI_CH*AXI_STRB_WIDTH-1:0]   m_axi_wstrb,
    output wire [AXI_CH-1:0]                  m_axi_wlast,
    output wire [AXI_CH-1:0]                  m_axi_wvalid,
    input  wire [AXI_CH-1:0]                  m_axi_wready,
    input  wire [AXI_CH*AXI_ID_WIDTH-1:0]     m_axi_bid,
    input  wire [AXI_CH*2-1:0]                m_axi_bresp,
    input  wire [AXI_CH-1:0]                  m_axi_bvalid,
    output wire [AXI_CH-1:0]                  m_axi_bready,
    output wire [AXI_CH*AXI_ID_WIDTH-1:0]     m_axi_arid,
    output wire [AXI_CH*AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
    output wire [AXI_CH*8-1:0]                m_axi_arlen,
    output wire [AXI_CH*3-1:0]                m_axi_arsize,
    output wire [AXI_CH*2-1:0]                m_axi_arburst,
    output wire [AXI_CH-1:0]                  m_axi_arlock,
    output wire [AXI_CH*4-1:0]                m_axi_arcache,
    output wire [AXI_CH*3-1:0]                m_axi_arprot,
    output wire [AXI_CH-1:0]                  m_axi_arvalid,
    input  wire [AXI_CH-1:0]                  m_axi_arready,
    input  wire [AXI_CH*AXI_ID_WIDTH-1:0]     m_axi_rid,
    input  wire [AXI_CH*AXI_DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [AXI_CH*2-1:0]                m_axi_rresp,
    input  wire [AXI_CH-1:0]                  m_axi_rlast,
    input  wire [AXI_CH-1:0]                  m_axi_rvalid,
    output wire [AXI_CH-1:0]                  m_axi_rready,

    /*
     * Configuration
     */
    input  wire [AXI_CH*AXI_ADDR_WIDTH-1:0]   cfg_fifo_base_addr,
    input  wire [LEN_WIDTH-1:0]               cfg_fifo_size_mask,
    input  wire                               cfg_enable,
    input  wire                               cfg_reset,

    /*
     * Status
     */
    output wire [AXI_CH*(LEN_WIDTH+1)-1:0]    sts_fifo_occupancy,
    output wire [AXI_CH-1:0]                  sts_fifo_empty,
    output wire [AXI_CH-1:0]                  sts_fifo_full,
    output wire [AXI_CH-1:0]                  sts_reset,
    output wire [AXI_CH-1:0]                  sts_active,
    output wire                               sts_hdr_parity_err
);

parameter CH_SEG_CNT = AXI_DATA_WIDTH > MAX_SEG_WIDTH ? AXI_DATA_WIDTH / MAX_SEG_WIDTH : 1;
parameter SEG_CNT = CH_SEG_CNT * AXI_CH;
parameter SEG_WIDTH = AXI_DATA_WIDTH / CH_SEG_CNT;

wire [AXI_CH-1:0]             ch_input_rst_out;
wire [AXI_CH-1:0]             ch_input_watermark;
wire [SEG_CNT*SEG_WIDTH-1:0]  ch_input_data;
wire [SEG_CNT-1:0]            ch_input_valid;
wire [SEG_CNT-1:0]            ch_input_ready;

wire [AXI_CH-1:0]             ch_output_rst_out;
wire [SEG_CNT*SEG_WIDTH-1:0]  ch_output_data;
wire [SEG_CNT-1:0]            ch_output_valid;
wire [SEG_CNT-1:0]            ch_output_ready;
wire [SEG_CNT*SEG_WIDTH-1:0]  ch_output_ctrl_data;
wire [SEG_CNT-1:0]            ch_output_ctrl_valid;
wire [SEG_CNT-1:0]            ch_output_ctrl_ready;

wire [AXI_CH-1:0] ch_rst_req;
wire enc_empty;
wire dec_empty;

// status sync
wire [AXI_CH*(LEN_WIDTH+1)-1:0] sts_fifo_occupancy_int;
wire [AXI_CH-1:0] sts_fifo_empty_int;
wire [AXI_CH-1:0] sts_fifo_full_int;
wire [AXI_CH-1:0] sts_reset_int;
wire [AXI_CH-1:0] sts_active_int;
wire sts_hdr_parity_err_int;
reg [3:0] sts_hdr_parity_err_cnt_reg = 0;
reg sts_hdr_parity_err_reg = 1'b0;

(* shreg_extract = "no" *)
reg [AXI_CH*(LEN_WIDTH+1)-1:0] sts_fifo_occupancy_sync_reg = 0;
(* shreg_extract = "no" *)
reg [AXI_CH-1:0] sts_fifo_empty_sync_1_reg = {AXI_CH{1'b1}}, sts_fifo_empty_sync_2_reg = {AXI_CH{1'b1}};
(* shreg_extract = "no" *)
reg [AXI_CH-1:0] sts_fifo_full_sync_1_reg = 0, sts_fifo_full_sync_2_reg = 0;
(* shreg_extract = "no" *)
reg [AXI_CH-1:0] sts_reset_sync_1_reg = {AXI_CH{1'b1}}, sts_reset_sync_2_reg = {AXI_CH{1'b1}};
(* shreg_extract = "no" *)
reg [AXI_CH-1:0] sts_active_sync_1_reg = 0, sts_active_sync_2_reg = 0;
(* shreg_extract = "no" *)
reg sts_hdr_parity_err_sync_1_reg = 0, sts_hdr_parity_err_sync_2_reg = 0;
(* shreg_extract = "no" *)
reg enc_empty_sync_1_reg = 1'b1, enc_empty_sync_2_reg = 1'b1;
(* shreg_extract = "no" *)
reg dec_empty_sync_1_reg = 1'b1, dec_empty_sync_2_reg = 1'b1;
(* shreg_extract = "no" *)
reg s_axis_rst_sync_1_reg = 1'b1, s_axis_rst_sync_2_reg = 1'b1;
(* shreg_extract = "no" *)
reg m_axis_rst_sync_1_reg = 1'b1, m_axis_rst_sync_2_reg = 1'b1;

wire [AXI_CH-1:0] ch_occ_ack;
reg [AXI_CH-1:0] occ_req_reg = 0;
(* shreg_extract = "no" *)
reg [AXI_CH-1:0] occ_ack_sync_1_reg = 0, occ_ack_sync_2_reg = 0;

// config management (explicit 4-state flush/reconfig FSM)
localparam [1:0]
    CFG_ST_ASSERT_RST = 2'd0,
    CFG_ST_WAIT_DRAIN = 2'd1,
    CFG_ST_DISABLED   = 2'd2,
    CFG_ST_ENABLED    = 2'd3;

reg [1:0] cfg_fsm_q = CFG_ST_ASSERT_RST;
reg [AXI_CH*AXI_ADDR_WIDTH-1:0] cfg_fifo_base_addr_reg = 0;
reg [LEN_WIDTH-1:0] cfg_fifo_size_mask_reg = 0;
reg cfg_enable_reg = 1'b0;
reg cfg_reset_reg = 1'b1;

wire all_in_reset = (&sts_reset_sync_2_reg) && s_axis_rst_sync_2_reg && m_axis_rst_sync_2_reg;
wire all_out_of_reset = (|sts_reset_sync_2_reg == 1'b0) && !s_axis_rst_sync_2_reg && !m_axis_rst_sync_2_reg;

always @(posedge clk) begin
    if (cfg_reset) begin
        cfg_fsm_q <= CFG_ST_ASSERT_RST;
        cfg_reset_reg <= 1'b1;
        cfg_enable_reg <= 1'b0;
    end else begin
        case (cfg_fsm_q)
            CFG_ST_ASSERT_RST: begin
                cfg_reset_reg <= 1'b1;
                cfg_enable_reg <= 1'b0;
                if (all_in_reset) begin
                    cfg_reset_reg <= 1'b0;
                    cfg_fsm_q <= CFG_ST_WAIT_DRAIN;
                end
            end
            CFG_ST_WAIT_DRAIN: begin
                cfg_reset_reg <= 1'b0;
                cfg_enable_reg <= 1'b0;
                cfg_fifo_base_addr_reg <= cfg_fifo_base_addr;
                cfg_fifo_size_mask_reg <= cfg_fifo_size_mask;
                if (all_out_of_reset) begin
                    if (cfg_enable) begin
                        cfg_enable_reg <= 1'b1;
                        cfg_fsm_q <= CFG_ST_ENABLED;
                    end else begin
                        cfg_fsm_q <= CFG_ST_DISABLED;
                    end
                end
            end
            CFG_ST_DISABLED: begin
                cfg_reset_reg <= 1'b0;
                cfg_enable_reg <= 1'b0;
                cfg_fifo_base_addr_reg <= cfg_fifo_base_addr;
                cfg_fifo_size_mask_reg <= cfg_fifo_size_mask;
                if (cfg_enable && all_out_of_reset) begin
                    cfg_enable_reg <= 1'b1;
                    cfg_fsm_q <= CFG_ST_ENABLED;
                end
            end
            default: begin
                cfg_reset_reg <= 1'b0;
                cfg_enable_reg <= 1'b1;
            end
        endcase
    end

    if (rst) begin
        cfg_fsm_q <= CFG_ST_ASSERT_RST;
        cfg_fifo_base_addr_reg <= 0;
        cfg_fifo_size_mask_reg <= 0;
        cfg_enable_reg <= 1'b0;
        cfg_reset_reg <= 1'b1;
    end
end

assign sts_fifo_occupancy = sts_fifo_occupancy_sync_reg;
assign sts_fifo_empty = sts_fifo_empty_sync_2_reg & {AXI_CH{enc_empty_sync_2_reg & dec_empty_sync_2_reg}};
assign sts_fifo_full = sts_fifo_full_sync_2_reg;
assign sts_reset = sts_reset_sync_2_reg;
assign sts_active = sts_active_sync_2_reg;
assign sts_hdr_parity_err = sts_hdr_parity_err_sync_2_reg;

always @(posedge m_axis_clk) begin
    sts_hdr_parity_err_reg <= 1'b0;

    if (sts_hdr_parity_err_cnt_reg) begin
        sts_hdr_parity_err_reg <= 1'b1;
        sts_hdr_parity_err_cnt_reg <= sts_hdr_parity_err_cnt_reg - 1;
    end

    if (sts_hdr_parity_err_int) begin
        sts_hdr_parity_err_cnt_reg <= 4'hf;
    end

    if (m_axis_rst || m_axis_rst_out) begin
        sts_hdr_parity_err_cnt_reg <= 4'h0;
        sts_hdr_parity_err_reg <= 1'b0;
    end
end

integer ch_idx;

always @(posedge clk) begin
    ch_idx = 0;
    occ_ack_sync_1_reg <= ch_occ_ack;
    occ_ack_sync_2_reg <= occ_ack_sync_1_reg;

    for (ch_idx = 0; ch_idx < AXI_CH; ch_idx = ch_idx + 1) begin
        if (occ_ack_sync_2_reg[ch_idx] == occ_req_reg[ch_idx]) begin
            sts_fifo_occupancy_sync_reg[(LEN_WIDTH+1)*ch_idx +: (LEN_WIDTH+1)] <= sts_fifo_occupancy_int[(LEN_WIDTH+1)*ch_idx +: (LEN_WIDTH+1)];
            occ_req_reg[ch_idx] <= ~occ_req_reg[ch_idx];
        end
    end

    sts_fifo_empty_sync_1_reg <= sts_fifo_empty_int;
    sts_fifo_empty_sync_2_reg <= sts_fifo_empty_sync_1_reg;
    sts_fifo_full_sync_1_reg <= sts_fifo_full_int;
    sts_fifo_full_sync_2_reg <= sts_fifo_full_sync_1_reg;
    sts_reset_sync_1_reg <= sts_reset_int;
    sts_reset_sync_2_reg <= sts_reset_sync_1_reg;
    sts_active_sync_1_reg <= sts_active_int;
    sts_active_sync_2_reg <= sts_active_sync_1_reg;
    sts_hdr_parity_err_sync_1_reg <= sts_hdr_parity_err_reg;
    sts_hdr_parity_err_sync_2_reg <= sts_hdr_parity_err_sync_1_reg;
    enc_empty_sync_1_reg <= enc_empty;
    enc_empty_sync_2_reg <= enc_empty_sync_1_reg;
    dec_empty_sync_1_reg <= dec_empty;
    dec_empty_sync_2_reg <= dec_empty_sync_1_reg;
    s_axis_rst_sync_1_reg <= s_axis_rst_out;
    s_axis_rst_sync_2_reg <= s_axis_rst_sync_1_reg;
    m_axis_rst_sync_1_reg <= m_axis_rst_out;
    m_axis_rst_sync_2_reg <= m_axis_rst_sync_1_reg;

    if (rst) begin
        occ_req_reg <= 0;
        occ_ack_sync_1_reg <= 0;
        occ_ack_sync_2_reg <= 0;
        sts_fifo_occupancy_sync_reg <= 0;
        sts_fifo_empty_sync_1_reg <= {AXI_CH{1'b1}};
        sts_fifo_empty_sync_2_reg <= {AXI_CH{1'b1}};
        sts_fifo_full_sync_1_reg <= 0;
        sts_fifo_full_sync_2_reg <= 0;
        sts_reset_sync_1_reg <= {AXI_CH{1'b1}};
        sts_reset_sync_2_reg <= {AXI_CH{1'b1}};
        sts_active_sync_1_reg <= 0;
        sts_active_sync_2_reg <= 0;
        sts_hdr_parity_err_sync_1_reg <= 1'b0;
        sts_hdr_parity_err_sync_2_reg <= 1'b0;
        enc_empty_sync_1_reg <= 1'b1;
        enc_empty_sync_2_reg <= 1'b1;
        dec_empty_sync_1_reg <= 1'b1;
        dec_empty_sync_2_reg <= 1'b1;
        s_axis_rst_sync_1_reg <= 1'b1;
        s_axis_rst_sync_2_reg <= 1'b1;
        m_axis_rst_sync_1_reg <= 1'b1;
        m_axis_rst_sync_2_reg <= 1'b1;
    end
end

assign s_axis_rst_out = |ch_input_rst_out;

axi_vfifo_enc #(
    .SEG_WIDTH(SEG_WIDTH),
    .SEG_CNT(SEG_CNT),
    .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
    .AXIS_KEEP_ENABLE(AXIS_KEEP_ENABLE),
    .AXIS_KEEP_WIDTH(AXIS_KEEP_WIDTH),
    .AXIS_LAST_ENABLE(AXIS_LAST_ENABLE),
    .AXIS_ID_ENABLE(AXIS_ID_ENABLE),
    .AXIS_ID_WIDTH(AXIS_ID_WIDTH),
    .AXIS_DEST_ENABLE(AXIS_DEST_ENABLE),
    .AXIS_DEST_WIDTH(AXIS_DEST_WIDTH),
    .AXIS_USER_ENABLE(AXIS_USER_ENABLE),
    .AXIS_USER_WIDTH(AXIS_USER_WIDTH)
)
axi_vfifo_enc_inst (
    .clk(s_axis_clk),
    .rst(s_axis_rst),

    /*
     * AXI stream data input
     */
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tid(s_axis_tid),
    .s_axis_tdest(s_axis_tdest),
    .s_axis_tuser(s_axis_tuser),

    /*
     * Segmented data output (to virtual FIFO channel)
     */
    .fifo_rst_in(s_axis_rst_out),
    .output_data(ch_input_data),
    .output_valid(ch_input_valid),
    .fifo_watermark_in(|ch_input_watermark),
    .sts_enc_empty(enc_empty)
);

generate

genvar  n;

for (n = 0; n < AXI_CH; n = n + 1) begin : axi_ch
    
    wire ch_clk = m_axi_clk[1*n +: 1];
    wire ch_rst = m_axi_rst[1*n +: 1];

    wire [AXI_ID_WIDTH-1:0]    ch_axi_awid;
    wire [AXI_ADDR_WIDTH-1:0]  ch_axi_awaddr;
    wire [7:0]                 ch_axi_awlen;
    wire [2:0]                 ch_axi_awsize;
    wire [1:0]                 ch_axi_awburst;
    wire                       ch_axi_awlock;
    wire [3:0]                 ch_axi_awcache;
    wire [2:0]                 ch_axi_awprot;
    wire                       ch_axi_awvalid;
    wire                       ch_axi_awready;
    wire [AXI_DATA_WIDTH-1:0]  ch_axi_wdata;
    wire [AXI_STRB_WIDTH-1:0]  ch_axi_wstrb;
    wire                       ch_axi_wlast;
    wire                       ch_axi_wvalid;
    wire                       ch_axi_wready;
    wire [AXI_ID_WIDTH-1:0]    ch_axi_bid;
    wire [1:0]                 ch_axi_bresp;
    wire                       ch_axi_bvalid;
    wire                       ch_axi_bready;
    wire [AXI_ID_WIDTH-1:0]    ch_axi_arid;
    wire [AXI_ADDR_WIDTH-1:0]  ch_axi_araddr;
    wire [7:0]                 ch_axi_arlen;
    wire [2:0]                 ch_axi_arsize;
    wire [1:0]                 ch_axi_arburst;
    wire                       ch_axi_arlock;
    wire [3:0]                 ch_axi_arcache;
    wire [2:0]                 ch_axi_arprot;
    wire                       ch_axi_arvalid;
    wire                       ch_axi_arready;
    wire [AXI_ID_WIDTH-1:0]    ch_axi_rid;
    wire [AXI_DATA_WIDTH-1:0]  ch_axi_rdata;
    wire [1:0]                 ch_axi_rresp;
    wire                       ch_axi_rlast;
    wire                       ch_axi_rvalid;
    wire                       ch_axi_rready;

    assign m_axi_awid[AXI_ID_WIDTH*n +: AXI_ID_WIDTH] = ch_axi_awid;
    assign m_axi_awaddr[AXI_ADDR_WIDTH*n +: AXI_ADDR_WIDTH] = ch_axi_awaddr;
    assign m_axi_awlen[8*n +: 8] = ch_axi_awlen;
    assign m_axi_awsize[3*n +: 3] = ch_axi_awsize;
    assign m_axi_awburst[2*n +: 2] = ch_axi_awburst;
    assign m_axi_awlock[1*n +: 1] = ch_axi_awlock;
    assign m_axi_awcache[4*n +: 4] = ch_axi_awcache;
    assign m_axi_awprot[3*n +: 3] = ch_axi_awprot;
    assign m_axi_awvalid[1*n +: 1] = ch_axi_awvalid;
    assign ch_axi_awready = m_axi_awready[1*n +: 1];
    assign m_axi_wdata[AXI_DATA_WIDTH*n +: AXI_DATA_WIDTH] = ch_axi_wdata;
    assign m_axi_wstrb[AXI_STRB_WIDTH*n +: AXI_STRB_WIDTH] = ch_axi_wstrb;
    assign m_axi_wlast[1*n +: 1] = ch_axi_wlast;
    assign m_axi_wvalid[1*n +: 1] = ch_axi_wvalid;
    assign ch_axi_wready = m_axi_wready[1*n +: 1];
    assign ch_axi_bid = m_axi_bid[AXI_ID_WIDTH*n +: AXI_ID_WIDTH];
    assign ch_axi_bresp = m_axi_bresp[2*n +: 2];
    assign ch_axi_bvalid = m_axi_bvalid[1*n +: 1];
    assign m_axi_bready[1*n +: 1] = ch_axi_bready;
    assign m_axi_arid[AXI_ID_WIDTH*n +: AXI_ID_WIDTH] = ch_axi_arid;
    assign m_axi_araddr[AXI_ADDR_WIDTH*n +: AXI_ADDR_WIDTH] = ch_axi_araddr;
    assign m_axi_arlen[8*n +: 8] = ch_axi_arlen;
    assign m_axi_arsize[3*n +: 3] = ch_axi_arsize;
    assign m_axi_arburst[2*n +: 2] = ch_axi_arburst;
    assign m_axi_arlock[1*n +: 1] = ch_axi_arlock;
    assign m_axi_arcache[4*n +: 4] = ch_axi_arcache;
    assign m_axi_arprot[3*n +: 3] = ch_axi_arprot;
    assign m_axi_arvalid[1*n +: 1] = ch_axi_arvalid;
    assign ch_axi_arready = m_axi_arready[1*n +: 1];
    assign ch_axi_rid = m_axi_rid[AXI_ID_WIDTH*n +: AXI_ID_WIDTH];
    assign ch_axi_rdata = m_axi_rdata[AXI_DATA_WIDTH*n +: AXI_DATA_WIDTH];
    assign ch_axi_rresp = m_axi_rresp[2*n +: 2];
    assign ch_axi_rlast = m_axi_rlast[1*n +: 1];
    assign ch_axi_rvalid = m_axi_rvalid[1*n +: 1];
    assign m_axi_rready[1*n +: 1] = ch_axi_rready;

    // control sync
    (* shreg_extract = "no" *)
    reg ch_cfg_enable_sync_1_reg = 1'b0,  ch_cfg_enable_sync_2_reg = 1'b0;
    (* shreg_extract = "no" *)
    reg ch_cfg_reset_sync_1_reg = 1'b1,  ch_cfg_reset_sync_2_reg = 1'b1;

    always @(posedge ch_clk) begin
        ch_cfg_enable_sync_1_reg <= cfg_enable_reg;
        ch_cfg_enable_sync_2_reg <= ch_cfg_enable_sync_1_reg;
        ch_cfg_reset_sync_1_reg <= cfg_reset_reg;
        ch_cfg_reset_sync_2_reg <= ch_cfg_reset_sync_1_reg;
        if (ch_rst) begin
            ch_cfg_enable_sync_1_reg <= 1'b0;
            ch_cfg_enable_sync_2_reg <= 1'b0;
            ch_cfg_reset_sync_1_reg <= 1'b1;
            ch_cfg_reset_sync_2_reg <= 1'b1;
        end
    end

    // status sync
    wire [LEN_WIDTH+1-1:0] ch_sts_fifo_occupancy;
    reg [LEN_WIDTH+1-1:0] ch_sts_fifo_occupancy_reg = 0;
    reg ch_occ_ack_reg = 1'b0;

    (* shreg_extract = "no" *)
    reg ch_sts_flag_sync_1_reg = 1'b0,  ch_sts_flag_sync_2_reg = 1'b0;

    assign sts_fifo_occupancy_int[(LEN_WIDTH+1)*n +: LEN_WIDTH+1] = ch_sts_fifo_occupancy_reg;
    assign ch_occ_ack[n] = ch_occ_ack_reg;

    always @(posedge ch_clk) begin
        ch_sts_flag_sync_1_reg <= occ_req_reg[n];
        ch_sts_flag_sync_2_reg <= ch_sts_flag_sync_1_reg;

        if (ch_sts_flag_sync_2_reg != ch_occ_ack_reg) begin
            ch_sts_fifo_occupancy_reg <= ch_sts_fifo_occupancy;
            ch_occ_ack_reg <= ch_sts_flag_sync_2_reg;
        end

        if (ch_rst) begin
            ch_sts_flag_sync_1_reg <= 1'b0;
            ch_sts_flag_sync_2_reg <= 1'b0;
            ch_sts_fifo_occupancy_reg <= 0;
            ch_occ_ack_reg <= 1'b0;
        end
    end

    axi_vfifo_raw #(
        .SEG_WIDTH(SEG_WIDTH),
        .SEG_CNT(CH_SEG_CNT),
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_STRB_WIDTH(AXI_STRB_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .AXI_MAX_BURST_LEN(AXI_MAX_BURST_LEN),
        .LEN_WIDTH(LEN_WIDTH),
        .WRITE_FIFO_DEPTH(WRITE_FIFO_DEPTH),
        .WRITE_MAX_BURST_LEN(WRITE_MAX_BURST_LEN),
        .READ_FIFO_DEPTH(READ_FIFO_DEPTH),
        .READ_MAX_BURST_LEN(READ_MAX_BURST_LEN),
        .WATERMARK_LEVEL(WRITE_FIFO_DEPTH-4),
        .CTRL_OUT_EN(1)
    )
    axi_vfifo_raw_inst (
        .clk(ch_clk),
        .rst(ch_rst),

        /*
         * Segmented data input (from encode logic)
         */
        .input_clk(s_axis_clk),
        .input_rst(s_axis_rst),
        .input_rst_out(ch_input_rst_out[n]),
        .input_watermark(ch_input_watermark[n]),
        .input_data(ch_input_data[SEG_WIDTH*CH_SEG_CNT*n +: SEG_WIDTH*CH_SEG_CNT]),
        .input_valid(ch_input_valid[CH_SEG_CNT*n +: CH_SEG_CNT]),
        .input_ready(ch_input_ready[CH_SEG_CNT*n +: CH_SEG_CNT]),

        /*
         * Segmented data output (to decode logic)
         */
        .output_clk(m_axis_clk),
        .output_rst(m_axis_rst),
        .output_rst_out(ch_output_rst_out[n]),
        .output_data(ch_output_data[SEG_WIDTH*CH_SEG_CNT*n +: SEG_WIDTH*CH_SEG_CNT]),
        .output_valid(ch_output_valid[CH_SEG_CNT*n +: CH_SEG_CNT]),
        .output_ready(ch_output_ready[CH_SEG_CNT*n +: CH_SEG_CNT]),
        .output_ctrl_data(ch_output_ctrl_data[SEG_WIDTH*CH_SEG_CNT*n +: SEG_WIDTH*CH_SEG_CNT]),
        .output_ctrl_valid(ch_output_ctrl_valid[CH_SEG_CNT*n +: CH_SEG_CNT]),
        .output_ctrl_ready(ch_output_ctrl_ready[CH_SEG_CNT*n +: CH_SEG_CNT]),

        /*
         * AXI master interface
         */
        .m_axi_awid(ch_axi_awid),
        .m_axi_awaddr(ch_axi_awaddr),
        .m_axi_awlen(ch_axi_awlen),
        .m_axi_awsize(ch_axi_awsize),
        .m_axi_awburst(ch_axi_awburst),
        .m_axi_awlock(ch_axi_awlock),
        .m_axi_awcache(ch_axi_awcache),
        .m_axi_awprot(ch_axi_awprot),
        .m_axi_awvalid(ch_axi_awvalid),
        .m_axi_awready(ch_axi_awready),
        .m_axi_wdata(ch_axi_wdata),
        .m_axi_wstrb(ch_axi_wstrb),
        .m_axi_wlast(ch_axi_wlast),
        .m_axi_wvalid(ch_axi_wvalid),
        .m_axi_wready(ch_axi_wready),
        .m_axi_bid(ch_axi_bid),
        .m_axi_bresp(ch_axi_bresp),
        .m_axi_bvalid(ch_axi_bvalid),
        .m_axi_bready(ch_axi_bready),
        .m_axi_arid(ch_axi_arid),
        .m_axi_araddr(ch_axi_araddr),
        .m_axi_arlen(ch_axi_arlen),
        .m_axi_arsize(ch_axi_arsize),
        .m_axi_arburst(ch_axi_arburst),
        .m_axi_arlock(ch_axi_arlock),
        .m_axi_arcache(ch_axi_arcache),
        .m_axi_arprot(ch_axi_arprot),
        .m_axi_arvalid(ch_axi_arvalid),
        .m_axi_arready(ch_axi_arready),
        .m_axi_rid(ch_axi_rid),
        .m_axi_rdata(ch_axi_rdata),
        .m_axi_rresp(ch_axi_rresp),
        .m_axi_rlast(ch_axi_rlast),
        .m_axi_rvalid(ch_axi_rvalid),
        .m_axi_rready(ch_axi_rready),

        /*
         * Reset sync
         */
        .rst_req_out(ch_rst_req[n]),
        .rst_req_in(|ch_rst_req),

        /*
         * Configuration
         */
        .cfg_fifo_base_addr(cfg_fifo_base_addr_reg[AXI_ADDR_WIDTH*n +: AXI_ADDR_WIDTH]),
        .cfg_fifo_size_mask(cfg_fifo_size_mask_reg),
        .cfg_enable(ch_cfg_enable_sync_2_reg),
        .cfg_reset(ch_cfg_reset_sync_2_reg),

        /*
         * Status
         */
        .sts_fifo_occupancy(ch_sts_fifo_occupancy),
        .sts_fifo_empty(sts_fifo_empty_int[n]),
        .sts_fifo_full(sts_fifo_full_int[n]),
        .sts_reset(sts_reset_int[n]),
        .sts_active(sts_active_int[n]),
        .sts_write_active(),
        .sts_read_active(),
        .input_idle_in(enc_empty),
        .output_idle_in(dec_empty)
    );

end

endgenerate

assign m_axis_rst_out = |ch_output_rst_out;

axi_vfifo_dec #(
    .SEG_WIDTH(SEG_WIDTH),
    .SEG_CNT(SEG_CNT),
    .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
    .AXIS_KEEP_ENABLE(AXIS_KEEP_ENABLE),
    .AXIS_KEEP_WIDTH(AXIS_KEEP_WIDTH),
    .AXIS_LAST_ENABLE(AXIS_LAST_ENABLE),
    .AXIS_ID_ENABLE(AXIS_ID_ENABLE),
    .AXIS_ID_WIDTH(AXIS_ID_WIDTH),
    .AXIS_DEST_ENABLE(AXIS_DEST_ENABLE),
    .AXIS_DEST_WIDTH(AXIS_DEST_WIDTH),
    .AXIS_USER_ENABLE(AXIS_USER_ENABLE),
    .AXIS_USER_WIDTH(AXIS_USER_WIDTH)
)
axi_vfifo_dec_inst (
    .clk(m_axis_clk),
    .rst(m_axis_rst),

    /*
     * Segmented data input (from virtual FIFO channel)
     */
    .fifo_rst_in(m_axis_rst_out),
    .input_data(ch_output_data),
    .input_valid(ch_output_valid),
    .input_ready(ch_output_ready),
    .input_ctrl_data(ch_output_ctrl_data),
    .input_ctrl_valid(ch_output_ctrl_valid),
    .input_ctrl_ready(ch_output_ctrl_ready),

    /*
     * AXI stream data output
     */
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tid(m_axis_tid),
    .m_axis_tdest(m_axis_tdest),
    .m_axis_tuser(m_axis_tuser),

    /*
     * Status
     */
    .sts_hdr_parity_err(sts_hdr_parity_err_int),
    .sts_dec_empty(dec_empty)
);

endmodule

`resetall
