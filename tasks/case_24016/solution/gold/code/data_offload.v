// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2021-2026 Analog Devices, Inc. All rights reserved.
//
// In this HDL repository, there are many different and unique modules, consisting
// of various HDL (Verilog or VHDL) components. The individual modules are
// developed independently, and may be accompanied by separate and unique license
// terms.
//
// The user should read each of these license terms, and understand the
// freedoms and responsibilities that he or she has by using this source/core.
//
// This core is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE.
//
// Redistribution and use of source or resulting binaries, with or without modification
// of this file, are permitted under one of the following two license terms:
//
//   1. The GNU General Public License version 2 as published by the
//      Free Software Foundation, which can be found in the top level directory
//      of this repository (LICENSE_GPL2), and also online at:
//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
//
// OR
//
//   2. An ADI specific BSD license, which can be found in the top level directory
//      of this repository (LICENSE_ADIBSD), and also on-line at:
//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
//      This will allow to generate bit files and not release the source code,
//      as long as it attaches to an ADI device.
//
// ***************************************************************************
// ***************************************************************************
`timescale 1ns / 1ps

module data_offload #(

  parameter          ID = 0,
  parameter          MEM_TYPE = 0,                  // 1'b0 -FPGA RAM; 1'b1 - external memory
  parameter          MEM_SIZE_LOG2 = 10,            // log2 of memory size in bytes

  parameter          TX_OR_RXN_PATH = 0,            // if set IP is used in TX path, other wise in RX path

  parameter          SRC_DATA_WIDTH = 64,

  parameter          DST_DATA_WIDTH = 128,
  parameter          DST_CYCLIC_EN = 1'b0,          // 1'b1 - CYCLIC mode enabled; 1'b0 - CYCLIC mode disabled

  parameter          AUTO_BRINGUP = 1,
  parameter          SYNC_EXT_ADD_INTERNAL_CDC = 1,
  parameter          HAS_BYPASS = 1,
  parameter          ASYNC_CLK = 1
) (

  // AXI4 Slave for configuration

  input                                       s_axi_aclk,
  input                                       s_axi_aresetn,
  input                                       s_axi_awvalid,
  input       [15:0]                          s_axi_awaddr,
  input       [ 2:0]                          s_axi_awprot,
  output                                      s_axi_awready,
  input                                       s_axi_wvalid,
  input       [31:0]                          s_axi_wdata,
  input       [ 3:0]                          s_axi_wstrb,
  output                                      s_axi_wready,
  output                                      s_axi_bvalid,
  output      [ 1:0]                          s_axi_bresp,
  input                                       s_axi_bready,
  input                                       s_axi_arvalid,
  input       [15:0]                          s_axi_araddr,
  input       [ 2:0]                          s_axi_arprot,
  output                                      s_axi_arready,
  output                                      s_axi_rvalid,
  input                                       s_axi_rready,
  output      [ 1:0]                          s_axi_rresp,
  output      [31:0]                          s_axi_rdata,

  // AXI4 stream slave for source stream (TX_DMA or ADC) -- Source interface

  input                                       s_axis_aclk,
  input                                       s_axis_aresetn,

  output                                      s_axis_ready,
  input                                       s_axis_valid,
  input  [SRC_DATA_WIDTH-1:0]                 s_axis_data,
  input                                       s_axis_last,
  input  [SRC_DATA_WIDTH/8-1:0]               s_axis_keep,

  // AXI4 stream master for destination stream (RX_DMA or DAC) -- Destination
  // interface

  input                                       m_axis_aclk,
  input                                       m_axis_aresetn,

  input                                       m_axis_ready,
  output                                      m_axis_valid,
  output  [DST_DATA_WIDTH-1:0]                m_axis_data,
  output                                      m_axis_last,
  output  [DST_DATA_WIDTH/8-1:0]              m_axis_keep,

  // initialization request interface

  input                                       init_req,

  input                                       sync_ext,

  // AXIS - Memory UI to storage

  // AXI stream master for source stream to storage (BRAM/URAM/DDR/HBM)
  // runs on s_axis_aclk and s_axis_aresetn
  input                                       m_storage_axis_ready,
  output                                      m_storage_axis_valid,
  output  [SRC_DATA_WIDTH-1:0]                m_storage_axis_data,
  output                                      m_storage_axis_last,
  output  [SRC_DATA_WIDTH/8-1:0]              m_storage_axis_keep,

  // AXI stream slave for destination stream from storage (BRAM/URAM/DDR/HBM)
  // runs on m_axis_aclk and m_axis_aresetn
  output                                      s_storage_axis_ready,
  input                                       s_storage_axis_valid,
  input  [DST_DATA_WIDTH-1:0]                 s_storage_axis_data,
  input                                       s_storage_axis_last,
  input  [DST_DATA_WIDTH/8-1:0]               s_storage_axis_keep,

  // Control interface for storage for m_storage_axis interface
  output                                      wr_request_enable,
  output                                      wr_request_valid,
  input                                       wr_request_ready,
  output   [MEM_SIZE_LOG2-1:0]                wr_request_length,
  input    [MEM_SIZE_LOG2-1:0]                wr_response_measured_length,
  input                                       wr_response_eot,
  input                                       wr_overflow,

  // Control interface for storage for s_storage_axis interface
  output                                      rd_request_enable,
  output                                      rd_request_valid,
  input                                       rd_request_ready,
  output  reg  [MEM_SIZE_LOG2-1:0]            rd_request_length,
  input                                       rd_response_eot,
  input                                       rd_underflow,

  // Status and monitor

  input                                       ddr_calib_done
);

  // local parameters -- to make the code more readable

  localparam  SRC_ADDR_WIDTH_BYPASS = (SRC_DATA_WIDTH >= DST_DATA_WIDTH) ? 4 : 4 + $clog2(DST_DATA_WIDTH/SRC_DATA_WIDTH);
  localparam  DST_ADDR_WIDTH_BYPASS = (SRC_DATA_WIDTH <= DST_DATA_WIDTH) ? 4 + $clog2(DST_DATA_WIDTH/SRC_DATA_WIDTH) : 4;

  localparam SRC_BEAT_BYTE = $clog2(SRC_DATA_WIDTH/8);
  localparam SRC_STREAM_W = SRC_DATA_WIDTH + (SRC_DATA_WIDTH/8) + 1;
  localparam DST_STREAM_W = DST_DATA_WIDTH + (DST_DATA_WIDTH/8) + 1;

  // NOTE: Clock domain prefixes
  //    src_*  - AXI4 Stream Slave interface's clock domain
  //    dst_*  - AXI4 Stream Master interface's clock domain

  // internal signals
  wire                                        up_clk;
  wire                                        up_rstn;
  wire                                        up_wreq_s;
  wire  [13:0]                                up_waddr_s;
  wire  [31:0]                                up_wdata_s;
  wire                                        up_rreq_s;
  wire  [13:0]                                up_raddr_s;
  wire                                        up_wack_s;
  wire                                        up_rack_s;
  wire  [31:0]                                up_rdata_s;

  wire                                        src_clk;
  wire                                        src_rstn;
  wire                                        src_resetn;
  wire                                        dst_clk;
  wire                                        dst_rstn;
  wire                                        dst_resetn;

  wire                                        src_bypass_s;
  wire                                        dst_bypass_s;
  wire                                        oneshot_s;
  wire  [ 1:0]                                sync_config_s;
  wire                                        sync_int_s;
  wire                                        valid_bypass_s;
  wire  [DST_DATA_WIDTH-1:0]                  data_bypass_s;
  wire                                        last_bypass_s;
  wire  [DST_DATA_WIDTH/8-1:0]                keep_bypass_s;
  wire                                        ready_bypass_s;
  wire  [ 4:0]                                src_fsm_status_s;
  wire  [ 3:0]                                dst_fsm_status_s;

  wire                                        s_slice_valid_s;
  wire                                        s_slice_ready_s;
  wire  [SRC_DATA_WIDTH-1:0]                  s_slice_data_s;
  wire  [SRC_DATA_WIDTH/8-1:0]                s_slice_keep_s;
  wire                                        s_slice_last_s;

  wire                                        m_mux_valid_s;
  wire                                        m_mux_ready_s;
  wire  [DST_DATA_WIDTH-1:0]                  m_mux_data_s;
  wire  [DST_DATA_WIDTH/8-1:0]                m_mux_keep_s;
  wire                                        m_mux_last_s;
  wire  [DST_DATA_WIDTH-1:0]                  m_slice_data_s;

  wire  [MEM_SIZE_LOG2-1:0]                   src_transfer_length_s;
  wire  [MEM_SIZE_LOG2-1:0]                   rd_wr_response_measured_length;
  wire                                        rd_ml_valid;
  wire                                        rd_ready;
  wire                                        rd_ml_ready;
  wire                                        wr_ready;

  localparam [1:0] RDC_REQ      = 2'd0;
  localparam [1:0] RDC_WAIT_REL = 2'd1;
  localparam [1:0] RDC_RUN      = 2'd2;
  localparam [1:0] RDC_REARM    = 2'd3;

  wire                                        src_local_rst_s;
  wire                                        dst_local_rst_s;
  reg   [1:0]                                 src_rdc_state_q = RDC_REQ;
  reg   [1:0]                                 src_rdc_cnt_q   = 2'd0;
  reg                                         src_rdc_cmd_q   = 1'b1;
  reg                                         src_rdc_rstn_q  = 1'b0;
  wire                                        src_dst_fault_s;
  wire                                        src_dst_ack_s;

  reg                                         dst_fault_q     = 1'b1;
  reg   [1:0]                                 dst_rdc_cnt_q   = 2'd0;
  reg                                         dst_rdc_ack_q   = 1'b0;
  reg                                         dst_rdc_rstn_q  = 1'b0;
  wire                                        dst_src_cmd_s;

  assign src_clk = s_axis_aclk;
  assign dst_clk = m_axis_aclk;
  assign src_local_rst_s = ~s_axis_aresetn | ~src_rstn;
  assign dst_local_rst_s = ~m_axis_aresetn | ~dst_rstn;

  sync_bits #(
    .NUM_OF_BITS (1),
    .ASYNC_CLK (ASYNC_CLK)
  ) i_rdc_cmd_sync (
    .in_bits (src_rdc_cmd_q),
    .out_clk (dst_clk),
    .out_resetn (1'b1),
    .out_bits (dst_src_cmd_s));

  sync_bits #(
    .NUM_OF_BITS (2),
    .ASYNC_CLK (ASYNC_CLK)
  ) i_rdc_stat_sync (
    .in_bits ({dst_fault_q, dst_rdc_ack_q}),
    .out_clk (src_clk),
    .out_resetn (1'b1),
    .out_bits ({src_dst_fault_s, src_dst_ack_s}));

  always @(posedge dst_clk) begin
    if (dst_local_rst_s) begin
      dst_fault_q    <= 1'b1;
      dst_rdc_ack_q  <= 1'b0;
      dst_rdc_rstn_q <= 1'b0;
      if (dst_src_cmd_s) begin
        if (dst_rdc_cnt_q != 2'd2) begin
          dst_rdc_cnt_q <= dst_rdc_cnt_q + 2'd1;
        end
      end else begin
        dst_rdc_cnt_q <= 2'd0;
      end
    end else if (dst_src_cmd_s) begin
      dst_rdc_rstn_q <= 1'b0;
      if (dst_rdc_cnt_q != 2'd2) begin
        dst_rdc_cnt_q <= dst_rdc_cnt_q + 2'd1;
        dst_rdc_ack_q <= 1'b0;
      end else begin
        dst_fault_q   <= 1'b0;
        dst_rdc_ack_q <= 1'b1;
      end
    end else begin
      dst_rdc_cnt_q  <= 2'd0;
      dst_rdc_ack_q  <= 1'b0;
      dst_rdc_rstn_q <= ~dst_fault_q;
    end
  end

  always @(posedge src_clk) begin
    case (src_rdc_state_q)
      RDC_REQ: begin
        src_rdc_rstn_q <= 1'b0;
        src_rdc_cmd_q  <= 1'b1;
        if (src_rdc_cnt_q != 2'd2) begin
          src_rdc_cnt_q <= src_rdc_cnt_q + 2'd1;
        end else if (!src_local_rst_s && !src_dst_fault_s && src_dst_ack_s) begin
          src_rdc_state_q <= RDC_WAIT_REL;
          src_rdc_cmd_q   <= 1'b0;
        end
      end
      RDC_WAIT_REL: begin
        src_rdc_rstn_q <= 1'b0;
        src_rdc_cmd_q  <= 1'b0;
        if (src_local_rst_s || src_dst_fault_s) begin
          if (!src_dst_ack_s) begin
            src_rdc_state_q <= RDC_REQ;
            src_rdc_cmd_q   <= 1'b1;
            src_rdc_cnt_q   <= 2'd0;
          end else begin
            src_rdc_state_q <= RDC_REARM;
          end
        end else if (!src_dst_ack_s) begin
          src_rdc_state_q <= RDC_RUN;
          src_rdc_rstn_q  <= 1'b1;
        end
      end
      RDC_RUN: begin
        if (src_local_rst_s || src_dst_fault_s) begin
          src_rdc_state_q <= RDC_REQ;
          src_rdc_rstn_q  <= 1'b0;
          src_rdc_cmd_q   <= 1'b1;
          src_rdc_cnt_q   <= 2'd0;
        end else begin
          src_rdc_rstn_q  <= 1'b1;
          src_rdc_cmd_q   <= 1'b0;
        end
      end
      default: begin
        src_rdc_rstn_q <= 1'b0;
        src_rdc_cmd_q  <= 1'b0;
        if (!src_dst_ack_s) begin
          src_rdc_state_q <= RDC_REQ;
          src_rdc_cmd_q   <= 1'b1;
          src_rdc_cnt_q   <= 2'd0;
        end
      end
    endcase
  end

  assign src_resetn = s_axis_aresetn & src_rstn & src_rdc_rstn_q;
  assign dst_resetn = m_axis_aresetn & dst_rstn & dst_rdc_rstn_q;

  // Input AXI4-Stream register slice for s_axis timing isolation
  axi_register_slice #(
    .DATA_WIDTH (SRC_STREAM_W),
    .FORWARD_REGISTERED (1),
    .BACKWARD_REGISTERED (1)
  ) i_s_axis_slice (
    .clk (src_clk),
    .resetn (src_resetn),
    .s_axi_valid (s_axis_valid),
    .s_axi_ready (s_axis_ready),
    .s_axi_data ({s_axis_data, s_axis_keep, s_axis_last}),
    .m_axi_valid (s_slice_valid_s),
    .m_axi_ready (s_slice_ready_s),
    .m_axi_data ({s_slice_data_s, s_slice_keep_s, s_slice_last_s}));

  // Offload FSM and control
  data_offload_fsm #(
    .TX_OR_RXN_PATH (TX_OR_RXN_PATH),
    .SYNC_EXT_ADD_INTERNAL_CDC (SYNC_EXT_ADD_INTERNAL_CDC)
  ) i_data_offload_fsm (
    .up_clk (up_clk),
    .wr_clk (src_clk),
    .wr_resetn_in (src_resetn),
    .wr_request_enable (wr_request_enable),
    .wr_request_valid (wr_request_valid),
    .wr_request_ready (wr_request_ready),
    .wr_response_eot (wr_response_eot),
    .wr_ready (wr_ready),
    .rd_clk (dst_clk),
    .rd_resetn_in (dst_resetn),
    .rd_request_enable (rd_request_enable),
    .rd_request_valid (rd_request_valid),
    .rd_request_ready (rd_request_ready),
    .rd_response_eot (rd_response_eot),
    .rd_ready (rd_ready),
    .rd_valid (s_storage_axis_valid),
    .rd_ml_valid (rd_ml_valid),
    .rd_ml_ready (rd_ml_ready),
    .rd_oneshot (oneshot_s),
    .wr_bypass (src_bypass_s),
    .init_req (init_req),
    .sync_config (sync_config_s),
    .sync_external (sync_ext),
    .sync_internal (sync_int_s),
    .wr_fsm_state_out (src_fsm_status_s),
    .rd_fsm_state_out (dst_fsm_status_s));

  assign m_mux_valid_s = dst_bypass_s ? valid_bypass_s : (rd_ready & s_storage_axis_valid);
  assign m_mux_data_s  = dst_bypass_s ? data_bypass_s  : s_storage_axis_data;
  assign m_mux_last_s  = dst_bypass_s ? last_bypass_s  : s_storage_axis_last;
  assign m_mux_keep_s  = dst_bypass_s ? keep_bypass_s  : s_storage_axis_keep;

  axi_register_slice #(
    .DATA_WIDTH (DST_STREAM_W),
    .FORWARD_REGISTERED (1),
    .BACKWARD_REGISTERED (1)
  ) i_m_axis_slice (
    .clk (dst_clk),
    .resetn (dst_resetn),
    .s_axi_valid (m_mux_valid_s),
    .s_axi_ready (m_mux_ready_s),
    .s_axi_data ({m_mux_data_s, m_mux_keep_s, m_mux_last_s}),
    .m_axi_valid (m_axis_valid),
    .m_axi_ready (m_axis_ready),
    .m_axi_data ({m_slice_data_s, m_axis_keep, m_axis_last}));

  // For DAC paths set zero as IDLE data on the axis bus, avoid repeating last sample.
  assign m_axis_data = (TX_OR_RXN_PATH[0] & ~m_axis_valid) ? {DST_DATA_WIDTH{1'b0}} : m_slice_data_s;

  assign s_slice_ready_s = src_bypass_s ? ready_bypass_s : (wr_ready & m_storage_axis_ready);

  assign m_storage_axis_valid = s_slice_valid_s & wr_ready & ~src_bypass_s;
  assign m_storage_axis_data = s_slice_data_s;
  assign m_storage_axis_last = s_slice_last_s;
  assign m_storage_axis_keep = s_slice_keep_s;

  assign s_storage_axis_ready = ~dst_bypass_s & rd_ready & m_mux_ready_s;

  // Bypass module instance -- the same FIFO, just a smaller depth
  generate if (HAS_BYPASS) begin
    util_axis_fifo_asym #(
      .S_DATA_WIDTH (SRC_DATA_WIDTH),
      .ADDRESS_WIDTH (SRC_ADDR_WIDTH_BYPASS),
      .M_DATA_WIDTH (DST_DATA_WIDTH),
      .ASYNC_CLK (ASYNC_CLK),
      .TLAST_EN (1),
      .TKEEP_EN (1),
      .SRC_REG_SLICE_EN (1)
    ) i_bypass_fifo (
      .m_axis_aclk (m_axis_aclk),
      .m_axis_aresetn (dst_resetn),
      .m_axis_ready (dst_bypass_s & m_mux_ready_s),
      .m_axis_valid (valid_bypass_s),
      .m_axis_data  (data_bypass_s),
      .m_axis_tlast (last_bypass_s),
      .m_axis_empty (),
      .m_axis_almost_empty (),
      .m_axis_tkeep (keep_bypass_s),
      .m_axis_level (),
      .s_axis_aclk  (s_axis_aclk),
      .s_axis_aresetn (src_resetn),
      .s_axis_ready (ready_bypass_s),
      .s_axis_valid (s_slice_valid_s & src_bypass_s),
      .s_axis_data  (s_slice_data_s),
      .s_axis_tlast (s_slice_last_s),
      .s_axis_full  (),
      .s_axis_almost_full (),
      .s_axis_tkeep (s_slice_keep_s),
      .s_axis_room ());
  end else begin
      assign valid_bypass_s = 1'b0;
      assign data_bypass_s = 'd0;
      assign last_bypass_s = 1'b0;
      assign keep_bypass_s = {DST_DATA_WIDTH/8{1'b0}};
      assign ready_bypass_s = 1'b0;
  end endgenerate

  // register map

  data_offload_regmap #(
    .ID (ID),
    .MEM_TYPE (MEM_TYPE),
    .MEM_SIZE_LOG2 (MEM_SIZE_LOG2),
    .TX_OR_RXN_PATH (TX_OR_RXN_PATH),
    .AUTO_BRINGUP (AUTO_BRINGUP),
    .HAS_BYPASS (HAS_BYPASS)
  ) i_regmap (
    .up_clk (up_clk),
    .up_rstn (up_rstn),
    .up_rreq (up_rreq_s),
    .up_rack (up_rack_s),
    .up_raddr (up_raddr_s),
    .up_rdata (up_rdata_s),
    .up_wreq (up_wreq_s),
    .up_wack (up_wack_s),
    .up_waddr (up_waddr_s),
    .up_wdata (up_wdata_s),
    .src_clk (s_axis_aclk),
    .dst_clk (m_axis_aclk),
    .src_sw_resetn (src_rstn),
    .dst_sw_resetn (dst_rstn),
    .ddr_calib_done (ddr_calib_done),
    .src_bypass (src_bypass_s),
    .dst_bypass (dst_bypass_s),
    .oneshot (oneshot_s),
    .sync (sync_int_s),
    .sync_config (sync_config_s),
    .src_transfer_length (wr_request_length),
    .dst_transfer_length (),
    .src_fsm_status (src_fsm_status_s),
    .dst_fsm_status (dst_fsm_status_s),
    .src_overflow (wr_overflow),
    .dst_underflow (rd_underflow));

  // axi interface wrapper

  assign up_clk = s_axi_aclk;
  assign up_rstn = s_axi_aresetn;

  up_axi #(
    .AXI_ADDRESS_WIDTH (16)
  ) i_up_axi (
    .up_rstn (up_rstn),
    .up_clk (up_clk),
    .up_axi_awvalid (s_axi_awvalid),
    .up_axi_awaddr (s_axi_awaddr),
    .up_axi_awready (s_axi_awready),
    .up_axi_wvalid (s_axi_wvalid),
    .up_axi_wdata (s_axi_wdata),
    .up_axi_wstrb (s_axi_wstrb),
    .up_axi_wready (s_axi_wready),
    .up_axi_bvalid (s_axi_bvalid),
    .up_axi_bresp (s_axi_bresp),
    .up_axi_bready (s_axi_bready),
    .up_axi_arvalid (s_axi_arvalid),
    .up_axi_araddr (s_axi_araddr),
    .up_axi_arready (s_axi_arready),
    .up_axi_rvalid (s_axi_rvalid),
    .up_axi_rresp (s_axi_rresp),
    .up_axi_rdata (s_axi_rdata),
    .up_axi_rready (s_axi_rready),
    .up_wreq (up_wreq_s),
    .up_waddr (up_waddr_s),
    .up_wdata (up_wdata_s),
    .up_wack (up_wack_s),
    .up_rreq (up_rreq_s),
    .up_raddr (up_raddr_s),
    .up_rdata (up_rdata_s),
    .up_rack (up_rack_s));

  // Measured length handshake CDC
  util_axis_fifo #(
    .DATA_WIDTH(MEM_SIZE_LOG2),
    .ADDRESS_WIDTH(0),
    .ASYNC_CLK(ASYNC_CLK)
  ) i_measured_length_cdc (
    .s_axis_aclk(s_axis_aclk),
    .s_axis_aresetn(src_resetn),
    .s_axis_valid(wr_response_eot),
    .s_axis_ready(),
    .s_axis_full(),
    .s_axis_data(wr_response_measured_length),
    .s_axis_room(),
    .s_axis_tkeep(),
    .s_axis_tlast(),
    .s_axis_almost_full(),

    .m_axis_aclk(m_axis_aclk),
    .m_axis_aresetn(dst_resetn),
    .m_axis_valid(rd_ml_valid),
    .m_axis_ready(rd_ml_ready),
    .m_axis_data(rd_wr_response_measured_length),
    .m_axis_level(),
    .m_axis_empty(),
    .m_axis_tkeep(),
    .m_axis_tlast(),
    .m_axis_almost_empty());

  always @(posedge m_axis_aclk) begin
    if (!dst_resetn) begin
      rd_request_length <= {MEM_SIZE_LOG2{1'b0}};
    end else if (rd_ml_valid & rd_ml_ready) begin
      rd_request_length <= rd_wr_response_measured_length;
    end
  end

endmodule
