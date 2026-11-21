`timescale 1ns / 1ps
`default_nettype none

module tb_verilator_top (
    input  wire         clk,
    input  wire         rst,

    input  wire         read_enable,
    input  wire         write_enable,
    input  wire         rd_desc_stall,
    input  wire         wr_desc_stall,

    // 4-port Read Descriptor Mux slave ports
    input  wire [63:0]     s_rd_desc_addr,
    input  wire [19:0]     s_rd_desc_len_0,
    input  wire [19:0]     s_rd_desc_len_1,
    input  wire [19:0]     s_rd_desc_len_2,
    input  wire [19:0]     s_rd_desc_len_3,
    input  wire [31:0]     s_rd_desc_tag,
    input  wire [31:0]     s_rd_desc_id,
    input  wire [31:0]     s_rd_desc_dest,
    input  wire [15:0]     s_rd_desc_user,
    input  wire [3:0]      s_rd_desc_valid,
    output wire [3:0]      s_rd_desc_ready,

    output wire [31:0]     m_rd_status_tag,
    output wire [15:0]     m_rd_status_error,
    output wire [3:0]      m_rd_status_valid,

    // 4-port Write Descriptor Mux slave ports
    input  wire [63:0]     s_wr_desc_addr,
    input  wire [19:0]     s_wr_desc_len_0,
    input  wire [19:0]     s_wr_desc_len_1,
    input  wire [19:0]     s_wr_desc_len_2,
    input  wire [19:0]     s_wr_desc_len_3,
    input  wire [31:0]     s_wr_desc_tag,
    input  wire [3:0]      s_wr_desc_valid,
    output wire [3:0]      s_wr_desc_ready,

    output wire [19:0]     m_wr_status_len_0,
    output wire [19:0]     m_wr_status_len_1,
    output wire [19:0]     m_wr_status_len_2,
    output wire [19:0]     m_wr_status_len_3,
    output wire [31:0]     m_wr_status_tag,
    output wire [31:0]     m_wr_status_id,
    output wire [31:0]     m_wr_status_dest,
    output wire [15:0]     m_wr_status_user,
    output wire [15:0]     m_wr_status_error,
    output wire [3:0]      m_wr_status_valid,

    // AXI-Stream Read Data output
    output wire [63:0]     m_axis_read_data_tdata,
    output wire [7:0]      m_axis_read_data_tkeep,
    output wire            m_axis_read_data_tvalid,
    input  wire            m_axis_read_data_tready,
    output wire            m_axis_read_data_tlast,
    output wire [7:0]      m_axis_read_data_tid,
    output wire [7:0]      m_axis_read_data_tdest,
    output wire [3:0]      m_axis_read_data_tuser,

    // AXI-Stream Write Data input
    input  wire [63:0]     s_axis_write_data_tdata,
    input  wire [7:0]      s_axis_write_data_tkeep,
    input  wire            s_axis_write_data_tvalid,
    output wire            s_axis_write_data_tready,
    input  wire            s_axis_write_data_tlast,
    input  wire [7:0]      s_axis_write_data_tid,
    input  wire [7:0]      s_axis_write_data_tdest,
    input  wire [3:0]      s_axis_write_data_tuser,

    // AXI4 Master interface (to C++ memory & protocol monitor)
    output wire [7:0]      m_axi_awid,
    output wire [15:0]     m_axi_awaddr,
    output wire [7:0]      m_axi_awlen,
    output wire [2:0]      m_axi_awsize,
    output wire [1:0]      m_axi_awburst,
    output wire            m_axi_awlock,
    output wire [3:0]      m_axi_awcache,
    output wire [2:0]      m_axi_awprot,
    output wire            m_axi_awvalid,
    input  wire            m_axi_awready,

    output wire [63:0]     m_axi_wdata,
    output wire [7:0]      m_axi_wstrb,
    output wire            m_axi_wlast,
    output wire            m_axi_wvalid,
    input  wire            m_axi_wready,

    input  wire [7:0]      m_axi_bid,
    input  wire [1:0]      m_axi_bresp,
    input  wire            m_axi_bvalid,
    output wire            m_axi_bready,

    output wire [7:0]      m_axi_arid,
    output wire [15:0]     m_axi_araddr,
    output wire [7:0]      m_axi_arlen,
    output wire [2:0]      m_axi_arsize,
    output wire [1:0]      m_axi_arburst,
    output wire            m_axi_arlock,
    output wire [3:0]      m_axi_arcache,
    output wire [2:0]      m_axi_arprot,
    output wire            m_axi_arvalid,
    input  wire            m_axi_arready,

    input  wire [7:0]      m_axi_rid,
    input  wire [63:0]     m_axi_rdata,
    input  wire [1:0]      m_axi_rresp,
    input  wire            m_axi_rlast,
    input  wire            m_axi_rvalid,
    output wire            m_axi_rready
);

    wire [4*20-1:0] s_rd_desc_len = {s_rd_desc_len_3, s_rd_desc_len_2, s_rd_desc_len_1, s_rd_desc_len_0};
    wire [4*20-1:0] s_wr_desc_len = {s_wr_desc_len_3, s_wr_desc_len_2, s_wr_desc_len_1, s_wr_desc_len_0};
    wire [4*20-1:0] m_wr_status_len;
    assign {m_wr_status_len_3, m_wr_status_len_2, m_wr_status_len_1, m_wr_status_len_0} = m_wr_status_len;

    wire [15:0] mux_rd_addr;
    wire [19:0] mux_rd_len;
    wire [11:0] mux_rd_tag;
    wire [7:0]  mux_rd_id;
    wire [7:0]  mux_rd_dest;
    wire [3:0]  mux_rd_user;
    wire        mux_rd_valid;
    wire        dma_rd_ready;

    wire [11:0] dma_rd_status_tag;
    wire [3:0]  dma_rd_status_error;
    wire        dma_rd_status_valid;

    wire [15:0] mux_wr_addr;
    wire [19:0] mux_wr_len;
    wire [11:0] mux_wr_tag;
    wire        mux_wr_valid;
    wire        dma_wr_ready;

    wire [19:0] dma_wr_status_len;
    wire [11:0] dma_wr_status_tag;
    wire [7:0]  dma_wr_status_id;
    wire [7:0]  dma_wr_status_dest;
    wire [3:0]  dma_wr_status_user;
    wire [3:0]  dma_wr_status_error;
    wire        dma_wr_status_valid;

    axi_dma_desc_mux #(
        .PORTS(4),
        .AXI_ADDR_WIDTH(16),
        .AXIS_ID_ENABLE(1),
        .AXIS_ID_WIDTH(8),
        .AXIS_DEST_ENABLE(1),
        .AXIS_DEST_WIDTH(8),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH(4),
        .LEN_WIDTH(20),
        .S_TAG_WIDTH(8),
        .M_TAG_WIDTH(12)
    ) u_rd_mux (
        .clk(clk),
        .rst(rst),
        .m_axis_desc_addr(mux_rd_addr),
        .m_axis_desc_len(mux_rd_len),
        .m_axis_desc_tag(mux_rd_tag),
        .m_axis_desc_id(mux_rd_id),
        .m_axis_desc_dest(mux_rd_dest),
        .m_axis_desc_user(mux_rd_user),
        .m_axis_desc_valid(mux_rd_valid),
        .m_axis_desc_ready(dma_rd_ready && !rd_desc_stall),
        .s_axis_desc_status_len(20'd0),
        .s_axis_desc_status_tag(dma_rd_status_tag),
        .s_axis_desc_status_id(8'd0),
        .s_axis_desc_status_dest(8'd0),
        .s_axis_desc_status_user(4'd0),
        .s_axis_desc_status_error(dma_rd_status_error),
        .s_axis_desc_status_valid(dma_rd_status_valid),
        .s_axis_desc_addr(s_rd_desc_addr),
        .s_axis_desc_len(s_rd_desc_len),
        .s_axis_desc_tag(s_rd_desc_tag),
        .s_axis_desc_id(s_rd_desc_id),
        .s_axis_desc_dest(s_rd_desc_dest),
        .s_axis_desc_user(s_rd_desc_user),
        .s_axis_desc_valid(s_rd_desc_valid),
        .s_axis_desc_ready(s_rd_desc_ready),
        .m_axis_desc_status_len(),
        .m_axis_desc_status_tag(m_rd_status_tag),
        .m_axis_desc_status_id(),
        .m_axis_desc_status_dest(),
        .m_axis_desc_status_user(),
        .m_axis_desc_status_error(m_rd_status_error),
        .m_axis_desc_status_valid(m_rd_status_valid)
    );

    axi_dma_desc_mux #(
        .PORTS(4),
        .AXI_ADDR_WIDTH(16),
        .AXIS_ID_ENABLE(1),
        .AXIS_ID_WIDTH(8),
        .AXIS_DEST_ENABLE(1),
        .AXIS_DEST_WIDTH(8),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH(4),
        .LEN_WIDTH(20),
        .S_TAG_WIDTH(8),
        .M_TAG_WIDTH(12)
    ) u_wr_mux (
        .clk(clk),
        .rst(rst),
        .m_axis_desc_addr(mux_wr_addr),
        .m_axis_desc_len(mux_wr_len),
        .m_axis_desc_tag(mux_wr_tag),
        .m_axis_desc_id(),
        .m_axis_desc_dest(),
        .m_axis_desc_user(),
        .m_axis_desc_valid(mux_wr_valid),
        .m_axis_desc_ready(dma_wr_ready && !wr_desc_stall),
        .s_axis_desc_status_len(dma_wr_status_len),
        .s_axis_desc_status_tag(dma_wr_status_tag),
        .s_axis_desc_status_id(dma_wr_status_id),
        .s_axis_desc_status_dest(dma_wr_status_dest),
        .s_axis_desc_status_user(dma_wr_status_user),
        .s_axis_desc_status_error(dma_wr_status_error),
        .s_axis_desc_status_valid(dma_wr_status_valid),
        .s_axis_desc_addr(s_wr_desc_addr),
        .s_axis_desc_len(s_wr_desc_len),
        .s_axis_desc_tag(s_wr_desc_tag),
        .s_axis_desc_id(32'd0),
        .s_axis_desc_dest(32'd0),
        .s_axis_desc_user(16'd0),
        .s_axis_desc_valid(s_wr_desc_valid),
        .s_axis_desc_ready(s_wr_desc_ready),
        .m_axis_desc_status_len(m_wr_status_len),
        .m_axis_desc_status_tag(m_wr_status_tag),
        .m_axis_desc_status_id(m_wr_status_id),
        .m_axis_desc_status_dest(m_wr_status_dest),
        .m_axis_desc_status_user(m_wr_status_user),
        .m_axis_desc_status_error(m_wr_status_error),
        .m_axis_desc_status_valid(m_wr_status_valid)
    );

    axi_dma #(
        .AXI_DATA_WIDTH(64),
        .AXI_ADDR_WIDTH(16),
        .AXI_ID_WIDTH(8),
        .AXI_MAX_BURST_LEN(16),
        .AXIS_DATA_WIDTH(64),
        .AXIS_KEEP_ENABLE(1),
        .AXIS_KEEP_WIDTH(8),
        .AXIS_LAST_ENABLE(1),
        .AXIS_ID_ENABLE(1),
        .AXIS_ID_WIDTH(8),
        .AXIS_DEST_ENABLE(1),
        .AXIS_DEST_WIDTH(8),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH(4),
        .LEN_WIDTH(20),
        .TAG_WIDTH(12),
        .ENABLE_SG(0),
        .ENABLE_UNALIGNED(1)
    ) u_dma (
        .clk(clk),
        .rst(rst),
        .s_axis_read_desc_addr(mux_rd_addr),
        .s_axis_read_desc_len(mux_rd_len),
        .s_axis_read_desc_tag(mux_rd_tag),
        .s_axis_read_desc_id(mux_rd_id),
        .s_axis_read_desc_dest(mux_rd_dest),
        .s_axis_read_desc_user(mux_rd_user),
        .s_axis_read_desc_valid(mux_rd_valid && !rd_desc_stall),
        .s_axis_read_desc_ready(dma_rd_ready),
        .m_axis_read_desc_status_tag(dma_rd_status_tag),
        .m_axis_read_desc_status_error(dma_rd_status_error),
        .m_axis_read_desc_status_valid(dma_rd_status_valid),

        .m_axis_read_data_tdata(m_axis_read_data_tdata),
        .m_axis_read_data_tkeep(m_axis_read_data_tkeep),
        .m_axis_read_data_tvalid(m_axis_read_data_tvalid),
        .m_axis_read_data_tready(m_axis_read_data_tready),
        .m_axis_read_data_tlast(m_axis_read_data_tlast),
        .m_axis_read_data_tid(m_axis_read_data_tid),
        .m_axis_read_data_tdest(m_axis_read_data_tdest),
        .m_axis_read_data_tuser(m_axis_read_data_tuser),

        .s_axis_write_desc_addr(mux_wr_addr),
        .s_axis_write_desc_len(mux_wr_len),
        .s_axis_write_desc_tag(mux_wr_tag),
        .s_axis_write_desc_valid(mux_wr_valid && !wr_desc_stall),
        .s_axis_write_desc_ready(dma_wr_ready),
        .m_axis_write_desc_status_len(dma_wr_status_len),
        .m_axis_write_desc_status_tag(dma_wr_status_tag),
        .m_axis_write_desc_status_id(dma_wr_status_id),
        .m_axis_write_desc_status_dest(dma_wr_status_dest),
        .m_axis_write_desc_status_user(dma_wr_status_user),
        .m_axis_write_desc_status_error(dma_wr_status_error),
        .m_axis_write_desc_status_valid(dma_wr_status_valid),

        .s_axis_write_data_tdata(s_axis_write_data_tdata),
        .s_axis_write_data_tkeep(s_axis_write_data_tkeep),
        .s_axis_write_data_tvalid(s_axis_write_data_tvalid),
        .s_axis_write_data_tready(s_axis_write_data_tready),
        .s_axis_write_data_tlast(s_axis_write_data_tlast),
        .s_axis_write_data_tid(s_axis_write_data_tid),
        .s_axis_write_data_tdest(s_axis_write_data_tdest),
        .s_axis_write_data_tuser(s_axis_write_data_tuser),

        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),

        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),

        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),

        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),

        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),

        .read_enable(read_enable),
        .write_enable(write_enable),
        .write_abort(1'b0)
    );

endmodule
`default_nettype wire
