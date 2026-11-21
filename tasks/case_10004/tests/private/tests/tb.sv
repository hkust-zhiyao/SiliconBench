`timescale 1ns/1ps
`include "mc_define.h"
`include "define.tmp.h"
`include "noc_axi4_bridge_define.vh"

module tb;
  reg clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    #200000;
    $display("TB_FAIL: Simulation watchdog timeout");
    $finish(1);
  end

  reg rst_n;
  reg uart_boot_en;
  reg phy_init_done;

  // Standalone Deserializer DUT
  reg  [`NOC_DATA_WIDTH-1:0]   d_flit_in;
  reg                          d_flit_in_val;
  wire                         d_flit_in_rdy;
  wire [`MSG_HEADER_WIDTH-1:0] d_header_out;
  wire [`AXI4_DATA_WIDTH-1:0]  d_data_out;
  wire                         d_out_val;
  reg                          d_out_rdy;

  noc_axi4_bridge_deser u_deser (
    .clk          (clk),
    .rst_n        (rst_n),
    .flit_in      (d_flit_in),
    .flit_in_val  (d_flit_in_val),
    .flit_in_rdy  (d_flit_in_rdy),
    .phy_init_done(phy_init_done),
    .header_out   (d_header_out),
    .data_out     (d_data_out),
    .out_val      (d_out_val),
    .out_rdy      (d_out_rdy)
  );

  // Standalone Serializer DUT
  reg  [`MSG_HEADER_WIDTH-1:0] s_header_in;
  reg  [`AXI4_DATA_WIDTH-1:0]  s_data_in;
  reg                          s_in_val;
  wire                         s_in_rdy;
  wire [`NOC_DATA_WIDTH-1:0]   s_flit_out;
  wire                         s_flit_out_val;
  reg                          s_flit_out_rdy;

  noc_axi4_bridge_ser u_ser (
    .clk         (clk),
    .rst_n       (rst_n),
    .header_in   (s_header_in),
    .data_in     (s_data_in),
    .in_val      (s_in_val),
    .in_rdy      (s_in_rdy),
    .flit_out    (s_flit_out),
    .flit_out_val(s_flit_out_val),
    .flit_out_rdy(s_flit_out_rdy)
  );

  // Standalone Buffer DUT
  reg  [`MSG_HEADER_WIDTH-1:0]                 b_deser_header;
  reg  [`AXI4_DATA_WIDTH-1:0]                  b_deser_data;
  reg                                          b_deser_val;
  wire                                         b_deser_rdy;
  wire [`MSG_HEADER_WIDTH-1:0]                 b_read_req_header;
  wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] b_read_req_id;
  wire                                         b_read_req_val;
  reg                                          b_read_req_rdy;
  reg  [`AXI4_DATA_WIDTH-1:0]                  b_read_resp_data;
  reg  [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] b_read_resp_id;
  reg                                          b_read_resp_val;
  wire                                         b_read_resp_rdy;
  wire [`MSG_HEADER_WIDTH-1:0]                 b_write_req_header;
  wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] b_write_req_id;
  wire [`AXI4_DATA_WIDTH-1:0]                  b_write_req_data;
  wire                                         b_write_req_val;
  reg                                          b_write_req_rdy;
  reg  [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] b_write_resp_id;
  reg                                          b_write_resp_val;
  wire                                         b_write_resp_rdy;
  wire [`MSG_HEADER_WIDTH-1:0]                 b_ser_header;
  wire [`AXI4_DATA_WIDTH-1:0]                  b_ser_data;
  wire                                         b_ser_val;
  reg                                          b_ser_rdy;

  noc_axi4_bridge_buffer u_buf (
    .clk             (clk),
    .rst_n           (rst_n),
    .deser_header    (b_deser_header),
    .deser_data      (b_deser_data),
    .deser_val       (b_deser_val),
    .deser_rdy       (b_deser_rdy),
    .read_req_header (b_read_req_header),
    .read_req_id     (b_read_req_id),
    .read_req_val    (b_read_req_val),
    .read_req_rdy    (b_read_req_rdy),
    .read_resp_data  (b_read_resp_data),
    .read_resp_id    (b_read_resp_id),
    .read_resp_val   (b_read_resp_val),
    .read_resp_rdy   (b_read_resp_rdy),
    .write_req_header(b_write_req_header),
    .write_req_id    (b_write_req_id),
    .write_req_data  (b_write_req_data),
    .write_req_val   (b_write_req_val),
    .write_req_rdy   (b_write_req_rdy),
    .write_resp_id   (b_write_resp_id),
    .write_resp_val  (b_write_resp_val),
    .write_resp_rdy  (b_write_resp_rdy),
    .ser_header      (b_ser_header),
    .ser_data        (b_ser_data),
    .ser_val         (b_ser_val),
    .ser_rdy         (b_ser_rdy)
  );

  // Full Integrated Bridge DUT
  reg                          noc2_val;
  reg  [`NOC_DATA_WIDTH-1:0]   noc2_dat;
  wire                         noc2_rdy;
  wire                         noc3_val;
  wire [`NOC_DATA_WIDTH-1:0]   noc3_dat;
  reg                          noc3_rdy;

  wire [`AXI4_ID_WIDTH-1:0]    m_axi_awid;
  wire [`AXI4_ADDR_WIDTH-1:0]  m_axi_awaddr;
  wire [`AXI4_LEN_WIDTH-1:0]   m_axi_awlen;
  wire [`AXI4_SIZE_WIDTH-1:0]  m_axi_awsize;
  wire [`AXI4_BURST_WIDTH-1:0] m_axi_awburst;
  wire                         m_axi_awlock;
  wire [`AXI4_CACHE_WIDTH-1:0] m_axi_awcache;
  wire [`AXI4_PROT_WIDTH-1:0]  m_axi_awprot;
  wire [`AXI4_QOS_WIDTH-1:0]   m_axi_awqos;
  wire [`AXI4_REGION_WIDTH-1:0]m_axi_awregion;
  wire [`AXI4_USER_WIDTH-1:0]  m_axi_awuser;
  wire                         m_axi_awvalid;
  reg                          m_axi_awready;

  wire [`AXI4_ID_WIDTH-1:0]    m_axi_wid;
  wire [`AXI4_DATA_WIDTH-1:0]  m_axi_wdata;
  wire [`AXI4_STRB_WIDTH-1:0]  m_axi_wstrb;
  wire                         m_axi_wlast;
  wire [`AXI4_USER_WIDTH-1:0]  m_axi_wuser;
  wire                         m_axi_wvalid;
  reg                          m_axi_wready;

  wire [`AXI4_ID_WIDTH-1:0]    m_axi_arid;
  wire [`AXI4_ADDR_WIDTH-1:0]  m_axi_araddr;
  wire [`AXI4_LEN_WIDTH-1:0]   m_axi_arlen;
  wire [`AXI4_SIZE_WIDTH-1:0]  m_axi_arsize;
  wire [`AXI4_BURST_WIDTH-1:0] m_axi_arburst;
  wire                         m_axi_arlock;
  wire [`AXI4_CACHE_WIDTH-1:0] m_axi_arcache;
  wire [`AXI4_PROT_WIDTH-1:0]  m_axi_arprot;
  wire [`AXI4_QOS_WIDTH-1:0]   m_axi_arqos;
  wire [`AXI4_REGION_WIDTH-1:0]m_axi_arregion;
  wire [`AXI4_USER_WIDTH-1:0]  m_axi_aruser;
  wire                         m_axi_arvalid;
  reg                          m_axi_arready;

  reg  [`AXI4_ID_WIDTH-1:0]    m_axi_rid;
  reg  [`AXI4_DATA_WIDTH-1:0]  m_axi_rdata;
  reg  [`AXI4_RESP_WIDTH-1:0]  m_axi_rresp;
  reg                          m_axi_rlast;
  reg  [`AXI4_USER_WIDTH-1:0]  m_axi_ruser;
  reg                          m_axi_rvalid;
  wire                         m_axi_rready;

  reg  [`AXI4_ID_WIDTH-1:0]    m_axi_bid;
  reg  [`AXI4_RESP_WIDTH-1:0]  m_axi_bresp;
  reg  [`AXI4_USER_WIDTH-1:0]  m_axi_buser;
  reg                          m_axi_bvalid;
  wire                         m_axi_bready;

  noc_axi4_bridge u_bridge (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .uart_boot_en          (uart_boot_en),
    .phy_init_done         (phy_init_done),
    .src_bridge_vr_noc2_val(noc2_val),
    .src_bridge_vr_noc2_dat(noc2_dat),
    .src_bridge_vr_noc2_rdy(noc2_rdy),
    .bridge_dst_vr_noc3_val(noc3_val),
    .bridge_dst_vr_noc3_dat(noc3_dat),
    .bridge_dst_vr_noc3_rdy(noc3_rdy),
    .m_axi_awid            (m_axi_awid),
    .m_axi_awaddr          (m_axi_awaddr),
    .m_axi_awlen           (m_axi_awlen),
    .m_axi_awsize          (m_axi_awsize),
    .m_axi_awburst         (m_axi_awburst),
    .m_axi_awlock          (m_axi_awlock),
    .m_axi_awcache         (m_axi_awcache),
    .m_axi_awprot          (m_axi_awprot),
    .m_axi_awqos           (m_axi_awqos),
    .m_axi_awregion        (m_axi_awregion),
    .m_axi_awuser          (m_axi_awuser),
    .m_axi_awvalid         (m_axi_awvalid),
    .m_axi_awready         (m_axi_awready),
    .m_axi_wid             (m_axi_wid),
    .m_axi_wdata           (m_axi_wdata),
    .m_axi_wstrb           (m_axi_wstrb),
    .m_axi_wlast           (m_axi_wlast),
    .m_axi_wuser           (m_axi_wuser),
    .m_axi_wvalid          (m_axi_wvalid),
    .m_axi_wready          (m_axi_wready),
    .m_axi_arid            (m_axi_arid),
    .m_axi_araddr          (m_axi_araddr),
    .m_axi_arlen           (m_axi_arlen),
    .m_axi_arsize          (m_axi_arsize),
    .m_axi_arburst         (m_axi_arburst),
    .m_axi_arlock          (m_axi_arlock),
    .m_axi_arcache         (m_axi_arcache),
    .m_axi_arprot          (m_axi_arprot),
    .m_axi_arqos           (m_axi_arqos),
    .m_axi_arregion        (m_axi_arregion),
    .m_axi_aruser          (m_axi_aruser),
    .m_axi_arvalid         (m_axi_arvalid),
    .m_axi_arready         (m_axi_arready),
    .m_axi_rid             (m_axi_rid),
    .m_axi_rdata           (m_axi_rdata),
    .m_axi_rresp           (m_axi_rresp),
    .m_axi_rlast           (m_axi_rlast),
    .m_axi_ruser           (m_axi_ruser),
    .m_axi_rvalid          (m_axi_rvalid),
    .m_axi_rready          (m_axi_rready),
    .m_axi_bid             (m_axi_bid),
    .m_axi_bresp           (m_axi_bresp),
    .m_axi_buser           (m_axi_buser),
    .m_axi_bvalid          (m_axi_bvalid),
    .m_axi_bready          (m_axi_bready)
  );

  function [63:0] make_w1(
    input [13:0] dst_chip,
    input [7:0]  dst_x,
    input [7:0]  dst_y,
    input [3:0]  dst_fbits,
    input [7:0]  msg_len,
    input [7:0]  msg_type,
    input [7:0]  mshrid
  );
    reg [63:0] w;
    begin
      w = 64'd0;
      w[`MSG_DST_CHIPID] = dst_chip;
      w[`MSG_DST_X]      = dst_x;
      w[`MSG_DST_Y]      = dst_y;
      w[`MSG_DST_FBITS]  = dst_fbits;
      w[`MSG_LENGTH]     = msg_len;
      w[`MSG_TYPE]       = msg_type;
      w[`MSG_MSHRID]     = mshrid;
      make_w1 = w;
    end
  endfunction

  function [63:0] make_w2(
    input [39:0] addr,
    input [2:0]  data_size,
    input        cache_type
  );
    reg [63:0] w;
    begin
      w = 64'd0;
      w[`MSG_ADDR_]      = addr;
      w[`MSG_DATA_SIZE_] = data_size;
      w[`MSG_CACHE_TYPE_]= cache_type;
      make_w2 = w;
    end
  endfunction

  function [63:0] make_w3(
    input [13:0] src_chip,
    input [7:0]  src_x,
    input [7:0]  src_y,
    input [3:0]  src_fbits
  );
    reg [63:0] w;
    begin
      w = 64'd0;
      w[`MSG_SRC_CHIPID_] = src_chip;
      w[`MSG_SRC_X_]      = src_x;
      w[`MSG_SRC_Y_]      = src_y;
      w[`MSG_SRC_FBITS_]  = src_fbits;
      make_w3 = w;
    end
  endfunction

  task fail(input string msg);
    begin
      $display("TB_FAIL: %s", msg);
      $finish(1);
    end
  endtask

  integer seed;
  integer i, b;
  reg [63:0] w1, w2, w3;
  reg [511:0] exp_data;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rst_n          = 1'b0;
    uart_boot_en   = 1'b0;
    phy_init_done  = 1'b1;

    d_flit_in      = 64'd0;
    d_flit_in_val  = 1'b0;
    d_out_rdy      = 1'b0;

    s_header_in    = 192'd0;
    s_data_in      = 512'd0;
    s_in_val       = 1'b0;
    s_flit_out_rdy = 1'b0;

    b_deser_header = 192'd0;
    b_deser_data   = 512'd0;
    b_deser_val    = 1'b0;
    b_read_req_rdy = 1'b0;
    b_read_resp_data = 512'd0;
    b_read_resp_id = 1'b0;
    b_read_resp_val= 1'b0;
    b_write_req_rdy= 1'b0;
    b_write_resp_id= 1'b0;
    b_write_resp_val=1'b0;
    b_ser_rdy      = 1'b0;

    noc2_val       = 1'b0;
    noc2_dat       = 64'd0;
    noc3_rdy       = 1'b0;
    m_axi_awready  = 1'b0;
    m_axi_wready   = 1'b0;
    m_axi_arready  = 1'b0;
    m_axi_rid      = 6'd0;
    m_axi_rdata    = 512'd0;
    m_axi_rresp    = 2'd0;
    m_axi_rlast    = 1'b0;
    m_axi_ruser    = 11'd0;
    m_axi_rvalid   = 1'b0;
    m_axi_bid      = 6'd0;
    m_axi_bresp    = 2'd0;
    m_axi_buser    = 11'd0;
    m_axi_bvalid   = 1'b0;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // =========================================================================
    // TEST 1: Deserializer 8-beat STORE_MEM followed by 1-beat NC_STORE_REQ
    //         and 0-beat LOAD_MEM (with phy_init_done bubbles & out_rdy stalls)
    // =========================================================================
    w1 = make_w1(14'h1, 8'h2, 8'h3, 4'h0, 8'd10, `MSG_TYPE_STORE_MEM, 8'h55);
    w2 = make_w2(40'h00_1234_5640, `MSG_DATA_SIZE_64B, 1'b0);
    w3 = make_w3(14'h0, 8'h4, 8'h5, 4'h1);

    // Send W1, W2, W3
    @(negedge clk); d_flit_in = w1; d_flit_in_val = 1'b1;
    #1; if (!d_flit_in_rdy) fail("Deser flit_in_rdy not high in ACCEPT_W1");
    @(posedge clk);
    @(negedge clk); d_flit_in = w2;
    #1; if (!d_flit_in_rdy) fail("Deser flit_in_rdy not high in ACCEPT_W2");
    @(posedge clk);
    @(negedge clk); d_flit_in = w3;
    #1; if (!d_flit_in_rdy) fail("Deser flit_in_rdy not high in ACCEPT_W3");
    @(posedge clk);

    // Send 8 data beats with an invalid bubble in between where flit_in is garbage
    for (b = 0; b < 8; b = b + 1) begin
      if (b == 3) begin
        @(negedge clk); d_flit_in_val = 1'b0; d_flit_in = 64'hDEAD_BEEF_DEAD_BEEF;
        @(posedge clk);
      end
      @(negedge clk);
      d_flit_in_val = 1'b1;
      d_flit_in     = 64'hA000_0000_0000_0000 + b;
      #1; if (!d_flit_in_rdy) fail("Deser flit_in_rdy not high in ACCEPT_DATA");
      @(posedge clk);
    end
    @(negedge clk); d_flit_in_val = 1'b0; d_flit_in = 64'hFFFF_FFFF_FFFF_FFFF;

    // Stall out_rdy for 2 cycles and verify out_val & data_out stability
    repeat (2) begin
      #1;
      if (d_out_val !== 1'b1) fail("Deser out_val not asserted after 8-beat store");
      if (d_flit_in_rdy !== 1'b0) fail("Deser flit_in_rdy must be 0 in SEND state");
      exp_data = {64'hA000_0000_0000_0007, 64'hA000_0000_0000_0006,
                  64'hA000_0000_0000_0005, 64'hA000_0000_0000_0004,
                  64'hA000_0000_0000_0003, 64'hA000_0000_0000_0002,
                  64'hA000_0000_0000_0001, 64'hA000_0000_0000_0000};
      if (d_data_out !== exp_data) fail("Deser 8-beat store data_out mismatch");
      if (d_header_out !== {w3, w2, w1}) fail("Deser 8-beat store header_out mismatch");
      @(posedge clk);
      @(negedge clk);
    end
    d_out_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk); d_out_rdy = 1'b0;

    // Now send 1-beat NC_STORE_REQ (MSG_LENGTH = 3) and ensure upper 448 bits are zeroed!
    w1 = make_w1(14'h1, 8'h2, 8'h3, 4'h0, 8'd3, `MSG_TYPE_NC_STORE_REQ, 8'h66);
    w2 = make_w2(40'h80_0000_1008, `MSG_DATA_SIZE_8B, 1'b0);
    w3 = make_w3(14'h0, 8'h6, 8'h7, 4'h2);
    d_flit_in = w1; d_flit_in_val = 1'b1;
    @(posedge clk);
    @(negedge clk); d_flit_in = w2;
    @(posedge clk);
    @(negedge clk); d_flit_in = w3;
    @(posedge clk);
    // Test phy_init_done gating during ACCEPT_DATA
    @(negedge clk); phy_init_done = 1'b0; d_flit_in = 64'hBAD0_BAD0_BAD0_BAD0;
    #1;
    if (d_flit_in_rdy !== 1'b0) fail("Deser flit_in_rdy not gated by phy_init_done");
    @(posedge clk);
    @(negedge clk); phy_init_done = 1'b1; d_flit_in = 64'h1122_3344_5566_7788;
    #1;
    if (d_flit_in_rdy !== 1'b1) fail("Deser flit_in_rdy did not recover when phy_init_done=1");
    @(posedge clk);
    @(negedge clk); d_flit_in_val = 1'b0;
    #1;
    if (d_out_val !== 1'b1) fail("Deser out_val not asserted after 1-beat NC_STORE_REQ");
    if (d_data_out[63:0] !== 64'h1122_3344_5566_7788)
      fail($sformatf("Deser 1-beat NC_STORE_REQ data_out[63:0] got %h, expected 1122334455667788", d_data_out[63:0]));
    if (d_data_out[511:64] !== 448'd0)
      fail("Deser 1-beat NC_STORE_REQ upper bits [511:64] not cleared from prior packet");
    d_out_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk); d_out_rdy = 1'b0;

    // Now send 0-beat LOAD_MEM (MSG_LENGTH = 2) and ensure all 512 bits of data_out are 0
    w1 = make_w1(14'h1, 8'h2, 8'h3, 4'h0, 8'd2, `MSG_TYPE_LOAD_MEM, 8'h77);
    w2 = make_w2(40'h00_0000_2000, `MSG_DATA_SIZE_64B, 1'b0);
    w3 = make_w3(14'h0, 8'h1, 8'h1, 4'h0);
    d_flit_in = w1; d_flit_in_val = 1'b1;
    @(posedge clk);
    @(negedge clk); d_flit_in = w2;
    @(posedge clk);
    @(negedge clk); d_flit_in = w3;
    @(posedge clk);
    @(negedge clk); d_flit_in_val = 1'b0;
    #1;
    if (d_out_val !== 1'b1) fail("Deser out_val not asserted after 0-beat LOAD_MEM");
    if (d_data_out !== 512'd0) fail("Deser 0-beat LOAD_MEM data_out not cleared to 0");
    d_out_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk); d_out_rdy = 1'b0;

    // =========================================================================
    // TEST 2: Serializer response packet length & beat ordering under stalls
    // =========================================================================
    // 2a: Cacheable LOAD_MEM (8 data flits: data_in[63:0] .. data_in[511:448])
    w1 = make_w1(14'h0, 8'h0, 8'h0, 4'h0, 8'd2, `MSG_TYPE_LOAD_MEM, 8'h12);
    w2 = make_w2(40'h00_0010_0000, `MSG_DATA_SIZE_64B, 1'b0);
    w3 = make_w3(14'h2, 8'h5, 8'h6, 4'h3);
    s_header_in = {w3, w2, w1};
    s_data_in   = {64'hF7, 64'hF6, 64'hF5, 64'hF4, 64'hF3, 64'hF2, 64'hF1, 64'hF0};
    s_in_val    = 1'b1;
    #1;
    if (s_in_rdy !== 1'b1) fail("Ser in_rdy not high in ACCEPT");
    @(posedge clk);
    @(negedge clk); s_in_val = 1'b0; s_header_in = 192'd0; s_data_in = 512'd0;

    // Check header flit under 2-cycle stall
    repeat (2) begin
      #1;
      if (s_flit_out_val !== 1'b1) fail("Ser flit_out_val not high in SEND_HEADER");
      if (s_flit_out[`MSG_TYPE] !== `MSG_TYPE_LOAD_MEM_ACK) fail("Ser LOAD_MEM_ACK type mismatch");
      if (s_flit_out[`MSG_LENGTH] !== 8'd8) fail("Ser LOAD_MEM_ACK length must be 8");
      if (s_flit_out[`MSG_DST_CHIPID] !== 14'h2 || s_flit_out[`MSG_DST_X] !== 8'h5 ||
          s_flit_out[`MSG_DST_Y] !== 8'h6 || s_flit_out[`MSG_DST_FBITS] !== 4'h3 ||
          s_flit_out[`MSG_MSHRID] !== 8'h12)
        fail("Ser LOAD_MEM_ACK routing fields mismatch");
      @(posedge clk);
      @(negedge clk);
    end
    s_flit_out_rdy = 1'b1;
    @(posedge clk);

    // Check 8 data flits with stall on beat 7 (the final beat!)
    for (b = 0; b < 8; b = b + 1) begin
      @(negedge clk);
      if (b == 7) begin
        s_flit_out_rdy = 1'b0;
        #1;
        if (s_flit_out_val !== 1'b1) fail("Ser flit_out_val dropped on final beat stall");
        if (s_flit_out !== (64'hF0 + b)) fail("Ser data flit mismatch during final beat stall");
        @(posedge clk);
        @(negedge clk);
        #1;
        if (s_flit_out_val !== 1'b1 || s_flit_out !== (64'hF0 + b))
          fail("Ser failed to hold final data beat under flit_out_rdy=0");
      end
      s_flit_out_rdy = 1'b1;
      #1;
      if (s_flit_out_val !== 1'b1) fail("Ser flit_out_val low during SEND_DATA");
      if (s_flit_out !== (64'hF0 + b))
        fail($sformatf("Ser beat %0d got %h, expected %h", b, s_flit_out, 64'hF0 + b));
      @(posedge clk);
    end
    @(negedge clk); s_flit_out_rdy = 1'b0;
    #1;
    if (s_flit_out_val !== 1'b0 || s_in_rdy !== 1'b1)
      fail("Ser did not return to ACCEPT after 8th beat");

    // 2b: NC_LOAD_REQ with MSG_DATA_SIZE_4B (<= 8B) -> MSG_LENGTH = 1 (1 data beat = data_in[63:0])
    w1 = make_w1(14'h0, 8'h0, 8'h0, 4'h0, 8'd2, `MSG_TYPE_NC_LOAD_REQ, 8'h34);
    w2 = make_w2(40'h80_0000_0004, `MSG_DATA_SIZE_4B, 1'b0);
    w3 = make_w3(14'h1, 8'h2, 8'h3, 4'h0);
    s_header_in = {w3, w2, w1};
    s_data_in   = {448'hDEAD_BEEF, 64'hCAFE_BABE_CAFE_BABE};
    s_in_val    = 1'b1;
    @(posedge clk);
    @(negedge clk); s_in_val = 1'b0;
    #1;
    if (s_flit_out_val !== 1'b1 || s_flit_out[`MSG_TYPE] !== `MSG_TYPE_NC_LOAD_MEM_ACK ||
        s_flit_out[`MSG_LENGTH] !== 8'd1)
      fail($sformatf("Ser NC_LOAD_REQ 4B header expected len=1, got len=%0d", s_flit_out[`MSG_LENGTH]));
    s_flit_out_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk);
    #1;
    if (s_flit_out_val !== 1'b1 || s_flit_out !== 64'hCAFE_BABE_CAFE_BABE)
      fail("Ser NC_LOAD_REQ 4B single data beat mismatch");
    @(posedge clk);
    @(negedge clk); s_flit_out_rdy = 1'b0;
    #1;
    if (s_flit_out_val !== 1'b0 || s_in_rdy !== 1'b1)
      fail("Ser NC_LOAD_REQ 4B did not finish after 1 data beat");

    // 2c: NC_LOAD_REQ with MSG_DATA_SIZE_0B -> MSG_LENGTH = 0 (header-only)
    w1 = make_w1(14'h0, 8'h0, 8'h0, 4'h0, 8'd2, `MSG_TYPE_NC_LOAD_REQ, 8'h39);
    w2 = make_w2(40'h80_0000_0000, `MSG_DATA_SIZE_0B, 1'b0);
    w3 = make_w3(14'h1, 8'h2, 8'h3, 4'h0);
    s_header_in = {w3, w2, w1};
    s_data_in   = 512'hFFFF_FFFF;
    s_in_val    = 1'b1;
    @(posedge clk);
    @(negedge clk); s_in_val = 1'b0;
    #1;
    if (s_flit_out_val !== 1'b1 || s_flit_out[`MSG_TYPE] !== `MSG_TYPE_NC_LOAD_MEM_ACK ||
        s_flit_out[`MSG_LENGTH] !== 8'd0)
      fail("Ser NC_LOAD_REQ 0B header expected len=0");
    s_flit_out_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk); s_flit_out_rdy = 1'b0;
    #1;
    if (s_flit_out_val !== 1'b0 || s_in_rdy !== 1'b1)
      fail("Ser NC_LOAD_REQ 0B did not finish immediately after header");

    // 2d: NC_LOAD_REQ with MSG_DATA_SIZE_16B (> 8B) -> MSG_LENGTH = 8
    w1 = make_w1(14'h0, 8'h0, 8'h0, 4'h0, 8'd2, `MSG_TYPE_NC_LOAD_REQ, 8'h3A);
    w2 = make_w2(40'h80_0000_0000, `MSG_DATA_SIZE_16B, 1'b0);
    w3 = make_w3(14'h1, 8'h2, 8'h3, 4'h0);
    s_header_in = {w3, w2, w1};
    s_data_in   = {8{64'h1234_5678_9ABC_DEF0}};
    s_in_val    = 1'b1;
    @(posedge clk);
    @(negedge clk); s_in_val = 1'b0; s_flit_out_rdy = 1'b1;
    #1;
    if (s_flit_out[`MSG_LENGTH] !== 8'd8) fail("Ser NC_LOAD_REQ 16B expected len=8");
    repeat (9) @(posedge clk);
    @(negedge clk); s_flit_out_rdy = 1'b0;
    #1;
    if (s_flit_out_val !== 1'b0) fail("Ser NC_LOAD_REQ 16B did not finish after 9 flits");

    // =========================================================================
    // TEST 3: Buffer slot protection (bram_rdy) & work-conserving round-robin
    // =========================================================================
    // Push Read slot 0 and Write slot 1 into u_buf
    w1 = make_w1(14'h0, 8'h0, 8'h0, 4'h0, 8'd2, `MSG_TYPE_LOAD_MEM, 8'hA0);
    w2 = make_w2(40'h00_0001_0000, `MSG_DATA_SIZE_64B, 1'b0);
    w3 = make_w3(14'h0, 8'h1, 8'h2, 4'h0);
    b_deser_header = {w3, w2, w1};
    b_deser_data   = 512'd0;
    b_deser_val    = 1'b1;
    @(posedge clk);

    w1 = make_w1(14'h0, 8'h0, 8'h0, 4'h0, 8'd10, `MSG_TYPE_STORE_MEM, 8'hB1);
    w2 = make_w2(40'h00_0002_0000, `MSG_DATA_SIZE_64B, 1'b0);
    w3 = make_w3(14'h0, 8'h3, 8'h4, 4'h0);
    @(negedge clk);
    b_deser_header = {w3, w2, w1};
    b_deser_data   = {8{64'h55AA_55AA_55AA_55AA}};
    b_deser_val    = 1'b1;
    @(posedge clk);
    @(negedge clk); b_deser_val = 1'b0;
    #1;

    // Issue both slot 0 (read_req) and slot 1 (write_req)
    if (b_read_req_val !== 1'b1 || b_read_req_id !== 1'b0) fail("Buffer slot 0 read_req_val not high");
    b_read_req_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk); b_read_req_rdy = 1'b0;
    #1;
    // Now slot 0 has pkt_state_buf[0]==INVALID, but bram_rdy[0]==0 because response hasn't returned!
    // Verify deser_rdy is 0 so slot 0's SRAM header isn't overwritten!
    if (b_deser_rdy !== 1'b0)
      fail("Buffer deser_rdy asserted while slot 0 response is still in-flight (bram_rdy[0]==0)");

    if (b_write_req_val !== 1'b1 || b_write_req_id !== 1'b1) fail("Buffer slot 1 write_req_val not high");
    b_write_req_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk); b_write_req_rdy = 1'b0;
    #1;

    // Now present both read_resp (slot 0) and write_resp (slot 1) simultaneously!
    // Verify work-conserving round-robin accepts one per cycle and ser_header matches ser_data!
    b_read_resp_val  = 1'b1;
    b_read_resp_id   = 1'b0;
    b_read_resp_data = {8{64'hCAFE_0000_0000_0001}};
    b_write_resp_val = 1'b1;
    b_write_resp_id  = 1'b1;
    b_ser_rdy        = 1'b1;

    repeat (2) begin
      #1;
      if ((b_read_resp_rdy ^ b_write_resp_rdy) !== 1'b1)
        fail("Buffer must grant exactly one of read_resp or write_resp when both are valid");
      @(posedge clk);
      @(negedge clk);
      #1;
      if (b_ser_val !== 1'b1) fail("Buffer ser_val must assert 1 cycle after response grant");
      if (b_ser_header[`MSG_MSHRID] == 8'hA0) begin
        if (b_ser_data !== {8{64'hCAFE_0000_0000_0001}})
          fail("Buffer ser_header (Read A0) paired with wrong ser_data!");
        b_read_resp_val = 1'b0;
      end else if (b_ser_header[`MSG_MSHRID] == 8'hB1) begin
        if (b_ser_data !== 512'd0)
          fail("Buffer ser_header (Write B1) paired with non-zero ser_data!");
        b_write_resp_val = 1'b0;
      end else begin
        fail($sformatf("Buffer ser_header had unexpected MSHRID %h", b_ser_header[`MSG_MSHRID]));
      end
    end
    @(posedge clk);
    @(negedge clk); b_ser_rdy = 1'b0;

    // =========================================================================
    // TEST 4: Full Integrated noc_axi4_bridge End-to-End Transactions
    // =========================================================================
    m_axi_awready = 1'b1;
    m_axi_wready  = 1'b1;
    m_axi_arready = 1'b1;
    noc3_rdy      = 1'b1;

    // 4a: Uncacheable 8-byte store at offset 8 -> check m_axi_wstrb and m_axi_wdata
    w1 = make_w1(14'h0, 8'h0, 8'h0, 4'h0, 8'd3, `MSG_TYPE_NC_STORE_REQ, 8'h41);
    w2 = make_w2(40'h80_0000_0008, `MSG_DATA_SIZE_8B, 1'b0);
    w3 = make_w3(14'h0, 8'h2, 8'h3, 4'h0);
    noc2_val = 1'b1; noc2_dat = w1;
    @(posedge clk);
    @(negedge clk); noc2_dat = w2;
    @(posedge clk);
    @(negedge clk); noc2_dat = w3;
    @(posedge clk);
    @(negedge clk); noc2_dat = 64'h8877_6655_4433_2211;
    @(posedge clk);
    @(negedge clk); noc2_val = 1'b0;

    // Wait for AXI write request
    for (i = 0; i < 30 && !m_axi_awvalid; i = i + 1) begin @(posedge clk); #1; end
    if (!m_axi_awvalid || !m_axi_wvalid) fail("Integrated bridge did not issue AXI write");
    if (m_axi_wstrb !== 64'h0000_0000_0000_FF00)
      fail($sformatf("Integrated bridge NC_STORE 8B @ offset 8 wstrb=%h, expected FF00", m_axi_wstrb));
    if (m_axi_wdata[127:64] !== 64'h8877_6655_4433_2211)
      fail($sformatf("Integrated bridge NC_STORE 8B @ offset 8 wdata[127:64]=%h", m_axi_wdata[127:64]));
    @(posedge clk);

    // Return AXI write response
    @(negedge clk); m_axi_bvalid = 1'b1; m_axi_bid = m_axi_awid; m_axi_bresp = 2'b00;
    @(posedge clk);
    @(negedge clk); m_axi_bvalid = 1'b0;

    // Wait for NoC3 store ack
    for (i = 0; i < 30 && !noc3_val; i = i + 1) begin @(posedge clk); #1; end
    if (!noc3_val) fail("Integrated bridge did not emit NoC3 NC_STORE_MEM_ACK");
    if (noc3_dat[`MSG_TYPE] !== `MSG_TYPE_NC_STORE_MEM_ACK ||
        noc3_dat[`MSG_LENGTH] !== 8'd0 ||
        noc3_dat[`MSG_MSHRID] !== 8'h41)
      fail("Integrated bridge NoC3 NC_STORE_MEM_ACK header mismatch");
    @(posedge clk);

    $display("TB_PASS");
    $finish(0);
  end
endmodule
