// SPDX-License-Identifier: Apache-2.0
module veer_bus_dma_top (
   input  logic                        clk,
   input  logic                        rst_l,
   input  logic                        scan_mode,
   input  logic                        bus_clk_en,
   input  logic                        dma_bus_clk_en,
   input  logic                        clk_override,

   // 1. Core LSU AXI4 Master -> AHB-Lite Master Bridge (axi4_to_ahb)
   input  logic                        lsu_axi_awvalid,
   output logic                        lsu_axi_awready,
   input  logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_awid,
   input  logic [31:0]                 lsu_axi_awaddr,
   input  logic [2:0]                  lsu_axi_awsize,
   input  logic [2:0]                  lsu_axi_awprot,

   input  logic                        lsu_axi_wvalid,
   output logic                        lsu_axi_wready,
   input  logic [63:0]                 lsu_axi_wdata,
   input  logic [7:0]                  lsu_axi_wstrb,
   input  logic                        lsu_axi_wlast,

   output logic                        lsu_axi_bvalid,
   input  logic                        lsu_axi_bready,
   output logic [1:0]                  lsu_axi_bresp,
   output logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_bid,

   input  logic                        lsu_axi_arvalid,
   output logic                        lsu_axi_arready,
   input  logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_arid,
   input  logic [31:0]                 lsu_axi_araddr,
   input  logic [2:0]                  lsu_axi_arsize,
   input  logic [2:0]                  lsu_axi_arprot,

   output logic                        lsu_axi_rvalid,
   input  logic                        lsu_axi_rready,
   output logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_rid,
   output logic [63:0]                 lsu_axi_rdata,
   output logic [1:0]                  lsu_axi_rresp,
   output logic                        lsu_axi_rlast,

   output logic [31:0]                 lsu_ahb_haddr,
   output logic [2:0]                  lsu_ahb_hburst,
   output logic                        lsu_ahb_hmastlock,
   output logic [3:0]                  lsu_ahb_hprot,
   output logic [2:0]                  lsu_ahb_hsize,
   output logic [1:0]                  lsu_ahb_htrans,
   output logic                        lsu_ahb_hwrite,
   output logic [63:0]                 lsu_ahb_hwdata,
   input  logic [63:0]                 lsu_ahb_hrdata,
   input  logic                        lsu_ahb_hready,
   input  logic                        lsu_ahb_hresp,

   // 2. External AHB-Lite Slave -> AXI4 Gasket (ahb_to_axi4) -> DMA Controller (dma_ctrl)
   input  logic [31:0]                 dma_ahb_haddr,
   input  logic [2:0]                  dma_ahb_hburst,
   input  logic                        dma_ahb_hmastlock,
   input  logic [3:0]                  dma_ahb_hprot,
   input  logic [2:0]                  dma_ahb_hsize,
   input  logic [1:0]                  dma_ahb_htrans,
   input  logic                        dma_ahb_hwrite,
   input  logic [63:0]                 dma_ahb_hwdata,
   input  logic                        dma_ahb_hsel,
   input  logic                        dma_ahb_hreadyin,
   output logic [63:0]                 dma_ahb_hrdata,
   output logic                        dma_ahb_hreadyout,
   output logic                        dma_ahb_hresp,

   // Optional direct AXI4 DMA ingress (when ext_dma_axi_sel=1)
   input  logic                        ext_dma_axi_sel,
   input  logic                        ext_dma_axi_awvalid,
   output logic                        ext_dma_axi_awready,
   input  logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_awid,
   input  logic [31:0]                 ext_dma_axi_awaddr,
   input  logic [2:0]                  ext_dma_axi_awsize,
   input  logic [2:0]                  ext_dma_axi_awprot,
   input  logic [7:0]                  ext_dma_axi_awlen,
   input  logic [1:0]                  ext_dma_axi_awburst,
   input  logic                        ext_dma_axi_wvalid,
   output logic                        ext_dma_axi_wready,
   input  logic [63:0]                 ext_dma_axi_wdata,
   input  logic [7:0]                  ext_dma_axi_wstrb,
   input  logic                        ext_dma_axi_wlast,
   output logic                        ext_dma_axi_bvalid,
   input  logic                        ext_dma_axi_bready,
   output logic [1:0]                  ext_dma_axi_bresp,
   output logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_bid,
   input  logic                        ext_dma_axi_arvalid,
   output logic                        ext_dma_axi_arready,
   input  logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_arid,
   input  logic [31:0]                 ext_dma_axi_araddr,
   input  logic [2:0]                  ext_dma_axi_arsize,
   input  logic [2:0]                  ext_dma_axi_arprot,
   input  logic [7:0]                  ext_dma_axi_arlen,
   input  logic [1:0]                  ext_dma_axi_arburst,
   output logic                        ext_dma_axi_rvalid,
   input  logic                        ext_dma_axi_rready,
   output logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_rid,
   output logic [63:0]                 ext_dma_axi_rdata,
   output logic [1:0]                  ext_dma_axi_rresp,
   output logic                        ext_dma_axi_rlast,

   // Debug interface to DMA Controller
   input  logic [31:0]                 dbg_cmd_addr,
   input  logic [31:0]                 dbg_cmd_wrdata,
   input  logic                        dbg_cmd_valid,
   input  logic                        dbg_cmd_write,
   input  logic [1:0]                  dbg_cmd_type,
   input  logic [1:0]                  dbg_cmd_size,
   input  logic                        dbg_dma_bubble,
   output logic                        dma_dbg_ready,
   output logic                        dma_dbg_cmd_done,
   output logic                        dma_dbg_cmd_fail,
   output logic [31:0]                 dma_dbg_rddata,

   // Core DCCM / ICCM interface from DMA Controller
   output logic                        dma_dccm_req,
   output logic                        dma_iccm_req,
   output logic [31:0]                 dma_mem_addr,
   output logic [2:0]                  dma_mem_sz,
   output logic                        dma_mem_write,
   output logic [63:0]                 dma_mem_wdata,
   input  logic                        dccm_dma_rvalid,
   input  logic                        dccm_dma_ecc_error,
   input  logic [63:0]                 dccm_dma_rdata,
   input  logic                        iccm_dma_rvalid,
   input  logic                        iccm_dma_ecc_error,
   input  logic [63:0]                 iccm_dma_rdata,
   output logic                        dma_dccm_stall_any,
   output logic                        dma_iccm_stall_any,
   input  logic                        dccm_ready,
   input  logic                        iccm_ready,
   input  logic                        dec_tlu_stall_dma,
   input  logic [2:0]                  dec_tlu_dma_qos_prty,
   output logic                        dma_mem_dccm_req,
   output logic                        dma_slv_algn_err,

   // Transparent sideband pass-through channels
   input  logic [7:0]                  qos_in,
   output logic [7:0]                  qos_out,
   input  logic [7:0]                  region_in,
   output logic [7:0]                  region_out
);

   logic free_clk;
   assign free_clk = clk;
   assign qos_out = qos_in;
   assign region_out = region_in;

   logic                        g_axi_awvalid;
   logic                        g_axi_awready;
   logic [`RV_DMA_BUS_TAG-1:0]  g_axi_awid;
   logic [31:0]                 g_axi_awaddr;
   logic [2:0]                  g_axi_awsize;
   logic [2:0]                  g_axi_awprot;
   logic [7:0]                  g_axi_awlen;
   logic [1:0]                  g_axi_awburst;

   logic                        g_axi_wvalid;
   logic                        g_axi_wready;
   logic [63:0]                 g_axi_wdata;
   logic [7:0]                  g_axi_wstrb;
   logic                        g_axi_wlast;

   logic                        g_axi_bvalid;
   logic                        g_axi_bready;
   logic [1:0]                  g_axi_bresp;
   logic [`RV_DMA_BUS_TAG-1:0]  g_axi_bid;

   logic                        g_axi_arvalid;
   logic                        g_axi_arready;
   logic [`RV_DMA_BUS_TAG-1:0]  g_axi_arid;
   logic [31:0]                 g_axi_araddr;
   logic [2:0]                  g_axi_arsize;
   logic [2:0]                  g_axi_arprot;
   logic [7:0]                  g_axi_arlen;
   logic [1:0]                  g_axi_arburst;

   logic                        g_axi_rvalid;
   logic                        g_axi_rready;
   logic [`RV_DMA_BUS_TAG-1:0]  g_axi_rid;
   logic [63:0]                 g_axi_rdata;
   logic [1:0]                  g_axi_rresp;

   logic                        dma_axi_awvalid;
   logic                        dma_axi_awready;
   logic [`RV_DMA_BUS_TAG-1:0]  dma_axi_awid;
   logic [31:0]                 dma_axi_awaddr;
   logic [2:0]                  dma_axi_awsize;
   logic [2:0]                  dma_axi_awprot;
   logic [7:0]                  dma_axi_awlen;
   logic [1:0]                  dma_axi_awburst;

   logic                        dma_axi_wvalid;
   logic                        dma_axi_wready;
   logic [63:0]                 dma_axi_wdata;
   logic [7:0]                  dma_axi_wstrb;
   logic                        dma_axi_wlast;

   logic                        dma_axi_bvalid;
   logic                        dma_axi_bready;
   logic [1:0]                  dma_axi_bresp;
   logic [`RV_DMA_BUS_TAG-1:0]  dma_axi_bid;

   logic                        dma_axi_arvalid;
   logic                        dma_axi_arready;
   logic [`RV_DMA_BUS_TAG-1:0]  dma_axi_arid;
   logic [31:0]                 dma_axi_araddr;
   logic [2:0]                  dma_axi_arsize;
   logic [2:0]                  dma_axi_arprot;
   logic [7:0]                  dma_axi_arlen;
   logic [1:0]                  dma_axi_arburst;

   logic                        dma_axi_rvalid;
   logic                        dma_axi_rready;
   logic [`RV_DMA_BUS_TAG-1:0]  dma_axi_rid;
   logic [63:0]                 dma_axi_rdata;
   logic [1:0]                  dma_axi_rresp;
   logic                        dma_axi_rlast;

   axi4_to_ahb #(.TAG(`RV_LSU_BUS_TAG)) u_lsu_axi4_to_ahb (
      .clk           (clk),
      .rst_l         (rst_l),
      .scan_mode     (scan_mode),
      .bus_clk_en    (bus_clk_en),
      .clk_override  (clk_override),
      .axi_awvalid   (lsu_axi_awvalid),
      .axi_awready   (lsu_axi_awready),
      .axi_awid      (lsu_axi_awid),
      .axi_awaddr    (lsu_axi_awaddr),
      .axi_awsize    (lsu_axi_awsize),
      .axi_awprot    (lsu_axi_awprot),
      .axi_wvalid    (lsu_axi_wvalid),
      .axi_wready    (lsu_axi_wready),
      .axi_wdata     (lsu_axi_wdata),
      .axi_wstrb     (lsu_axi_wstrb),
      .axi_wlast     (lsu_axi_wlast),
      .axi_bvalid    (lsu_axi_bvalid),
      .axi_bready    (lsu_axi_bready),
      .axi_bresp     (lsu_axi_bresp),
      .axi_bid       (lsu_axi_bid),
      .axi_arvalid   (lsu_axi_arvalid),
      .axi_arready   (lsu_axi_arready),
      .axi_arid      (lsu_axi_arid),
      .axi_araddr    (lsu_axi_araddr),
      .axi_arsize    (lsu_axi_arsize),
      .axi_arprot    (lsu_axi_arprot),
      .axi_rvalid    (lsu_axi_rvalid),
      .axi_rready    (lsu_axi_rready),
      .axi_rid       (lsu_axi_rid),
      .axi_rdata     (lsu_axi_rdata),
      .axi_rresp     (lsu_axi_rresp),
      .axi_rlast     (lsu_axi_rlast),
      .ahb_haddr     (lsu_ahb_haddr),
      .ahb_hburst    (lsu_ahb_hburst),
      .ahb_hmastlock (lsu_ahb_hmastlock),
      .ahb_hprot     (lsu_ahb_hprot),
      .ahb_hsize     (lsu_ahb_hsize),
      .ahb_htrans    (lsu_ahb_htrans),
      .ahb_hwrite    (lsu_ahb_hwrite),
      .ahb_hwdata    (lsu_ahb_hwdata),
      .ahb_hrdata    (lsu_ahb_hrdata),
      .ahb_hready    (lsu_ahb_hready),
      .ahb_hresp     (lsu_ahb_hresp)
   );

   ahb_to_axi4 #(.TAG(`RV_DMA_BUS_TAG)) u_dma_ahb_to_axi4 (
      .clk           (clk),
      .rst_l         (rst_l),
      .scan_mode     (scan_mode),
      .bus_clk_en    (dma_bus_clk_en),
      .clk_override  (clk_override),
      .axi_awvalid   (g_axi_awvalid),
      .axi_awready   (g_axi_awready),
      .axi_awid      (g_axi_awid),
      .axi_awaddr    (g_axi_awaddr),
      .axi_awsize    (g_axi_awsize),
      .axi_awprot    (g_axi_awprot),
      .axi_awlen     (g_axi_awlen),
      .axi_awburst   (g_axi_awburst),
      .axi_wvalid    (g_axi_wvalid),
      .axi_wready    (g_axi_wready),
      .axi_wdata     (g_axi_wdata),
      .axi_wstrb     (g_axi_wstrb),
      .axi_wlast     (g_axi_wlast),
      .axi_bvalid    (g_axi_bvalid),
      .axi_bready    (g_axi_bready),
      .axi_bresp     (g_axi_bresp),
      .axi_bid       (g_axi_bid),
      .axi_arvalid   (g_axi_arvalid),
      .axi_arready   (g_axi_arready),
      .axi_arid      (g_axi_arid),
      .axi_araddr    (g_axi_araddr),
      .axi_arsize    (g_axi_arsize),
      .axi_arprot    (g_axi_arprot),
      .axi_arlen     (g_axi_arlen),
      .axi_arburst   (g_axi_arburst),
      .axi_rvalid    (g_axi_rvalid),
      .axi_rready    (g_axi_rready),
      .axi_rid       (g_axi_rid),
      .axi_rdata     (g_axi_rdata),
      .axi_rresp     (g_axi_rresp),
      .ahb_haddr     (dma_ahb_haddr),
      .ahb_hburst    (dma_ahb_hburst),
      .ahb_hmastlock (dma_ahb_hmastlock),
      .ahb_hprot     (dma_ahb_hprot),
      .ahb_hsize     (dma_ahb_hsize),
      .ahb_htrans    (dma_ahb_htrans),
      .ahb_hwrite    (dma_ahb_hwrite),
      .ahb_hwdata    (dma_ahb_hwdata),
      .ahb_hsel      (dma_ahb_hsel),
      .ahb_hreadyin  (dma_ahb_hreadyin),
      .ahb_hrdata    (dma_ahb_hrdata),
      .ahb_hreadyout (dma_ahb_hreadyout),
      .ahb_hresp     (dma_ahb_hresp)
   );

   assign dma_axi_awvalid = ext_dma_axi_sel ? ext_dma_axi_awvalid : g_axi_awvalid;
   assign dma_axi_awid    = ext_dma_axi_sel ? ext_dma_axi_awid    : g_axi_awid;
   assign dma_axi_awaddr  = ext_dma_axi_sel ? ext_dma_axi_awaddr  : g_axi_awaddr;
   assign dma_axi_awsize  = ext_dma_axi_sel ? ext_dma_axi_awsize  : g_axi_awsize;
   assign dma_axi_awprot  = ext_dma_axi_sel ? ext_dma_axi_awprot  : g_axi_awprot;
   assign dma_axi_awlen   = ext_dma_axi_sel ? ext_dma_axi_awlen   : g_axi_awlen;
   assign dma_axi_awburst = ext_dma_axi_sel ? ext_dma_axi_awburst : g_axi_awburst;
   assign g_axi_awready       = ~ext_dma_axi_sel & dma_axi_awready;
   assign ext_dma_axi_awready =  ext_dma_axi_sel & dma_axi_awready;

   assign dma_axi_wvalid  = ext_dma_axi_sel ? ext_dma_axi_wvalid  : g_axi_wvalid;
   assign dma_axi_wdata   = ext_dma_axi_sel ? ext_dma_axi_wdata   : g_axi_wdata;
   assign dma_axi_wstrb   = ext_dma_axi_sel ? ext_dma_axi_wstrb   : g_axi_wstrb;
   assign dma_axi_wlast   = ext_dma_axi_sel ? ext_dma_axi_wlast   : g_axi_wlast;
   assign g_axi_wready       = ~ext_dma_axi_sel & dma_axi_wready;
   assign ext_dma_axi_wready =  ext_dma_axi_sel & dma_axi_wready;

   assign g_axi_bvalid       = ~ext_dma_axi_sel & dma_axi_bvalid;
   assign ext_dma_axi_bvalid =  ext_dma_axi_sel & dma_axi_bvalid;
   assign g_axi_bresp        = dma_axi_bresp;
   assign ext_dma_axi_bresp  = dma_axi_bresp;
   assign g_axi_bid          = dma_axi_bid;
   assign ext_dma_axi_bid    = dma_axi_bid;
   assign dma_axi_bready     = ext_dma_axi_sel ? ext_dma_axi_bready : g_axi_bready;

   assign dma_axi_arvalid = ext_dma_axi_sel ? ext_dma_axi_arvalid : g_axi_arvalid;
   assign dma_axi_arid    = ext_dma_axi_sel ? ext_dma_axi_arid    : g_axi_arid;
   assign dma_axi_araddr  = ext_dma_axi_sel ? ext_dma_axi_araddr  : g_axi_araddr;
   assign dma_axi_arsize  = ext_dma_axi_sel ? ext_dma_axi_arsize  : g_axi_arsize;
   assign dma_axi_arprot  = ext_dma_axi_sel ? ext_dma_axi_arprot  : g_axi_arprot;
   assign dma_axi_arlen   = ext_dma_axi_sel ? ext_dma_axi_arlen   : g_axi_arlen;
   assign dma_axi_arburst = ext_dma_axi_sel ? ext_dma_axi_arburst : g_axi_arburst;
   assign g_axi_arready       = ~ext_dma_axi_sel & dma_axi_arready;
   assign ext_dma_axi_arready =  ext_dma_axi_sel & dma_axi_arready;

   assign g_axi_rvalid       = ~ext_dma_axi_sel & dma_axi_rvalid;
   assign ext_dma_axi_rvalid =  ext_dma_axi_sel & dma_axi_rvalid;
   assign g_axi_rid          = dma_axi_rid;
   assign ext_dma_axi_rid    = dma_axi_rid;
   assign g_axi_rdata        = dma_axi_rdata;
   assign ext_dma_axi_rdata  = dma_axi_rdata;
   assign g_axi_rresp        = dma_axi_rresp;
   assign ext_dma_axi_rresp  = dma_axi_rresp;
   assign ext_dma_axi_rlast  = dma_axi_rlast;
   assign dma_axi_rready     = ext_dma_axi_sel ? ext_dma_axi_rready : g_axi_rready;

   dma_ctrl u_dma_ctrl (.*);

endmodule
