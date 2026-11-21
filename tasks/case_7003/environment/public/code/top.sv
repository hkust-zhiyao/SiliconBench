// SPDX-License-Identifier: Apache-2.0
module top
import eh2_pkg::*;
#(
`include "eh2_param.vh"
)
(
   input  logic        clk_i,
   input  logic        rst_ni,
   input  logic        bus_clk_en,
   input  logic        dec_tlu_force_halt,

   // Upstream AXI4 Master Interface (into axi4_to_ahb)
   input  logic        m_axi_awvalid,
   output logic        m_axi_awready,
   input  logic [0:0]  m_axi_awid,
   input  logic [31:0] m_axi_awaddr,
   input  logic [2:0]  m_axi_awsize,
   input  logic [2:0]  m_axi_awprot,

   input  logic        m_axi_wvalid,
   output logic        m_axi_wready,
   input  logic [63:0] m_axi_wdata,
   input  logic [7:0]  m_axi_wstrb,
   input  logic        m_axi_wlast,

   output logic        m_axi_bvalid,
   input  logic        m_axi_bready,
   output logic [1:0]  m_axi_bresp,
   output logic [0:0]  m_axi_bid,

   input  logic        m_axi_arvalid,
   output logic        m_axi_arready,
   input  logic [0:0]  m_axi_arid,
   input  logic [31:0] m_axi_araddr,
   input  logic [2:0]  m_axi_arsize,
   input  logic [2:0]  m_axi_arprot,

   output logic        m_axi_rvalid,
   input  logic        m_axi_rready,
   output logic [0:0]  m_axi_rid,
   output logic [63:0] m_axi_rdata,
   output logic [1:0]  m_axi_rresp,
   output logic        m_axi_rlast,

   // Downstream AXI4 Target Interface (out of ahb_to_axi4)
   output logic        s_axi_awvalid,
   input  logic        s_axi_awready,
   output logic [0:0]  s_axi_awid,
   output logic [31:0] s_axi_awaddr,
   output logic [2:0]  s_axi_awsize,
   output logic [2:0]  s_axi_awprot,
   output logic [7:0]  s_axi_awlen,
   output logic [1:0]  s_axi_awburst,

   output logic        s_axi_wvalid,
   input  logic        s_axi_wready,
   output logic [63:0] s_axi_wdata,
   output logic [7:0]  s_axi_wstrb,
   output logic        s_axi_wlast,

   input  logic        s_axi_bvalid,
   output logic        s_axi_bready,
   input  logic [1:0]  s_axi_bresp,
   input  logic [0:0]  s_axi_bid,

   output logic        s_axi_arvalid,
   input  logic        s_axi_arready,
   output logic [0:0]  s_axi_arid,
   output logic [31:0] s_axi_araddr,
   output logic [2:0]  s_axi_arsize,
   output logic [2:0]  s_axi_arprot,
   output logic [7:0]  s_axi_arlen,
   output logic [1:0]  s_axi_arburst,

   input  logic        s_axi_rvalid,
   output logic        s_axi_rready,
   input  logic [0:0]  s_axi_rid,
   input  logic [63:0] s_axi_rdata,
   input  logic [1:0]  s_axi_rresp,

   // Transparent 8-bit Zero-Cut Sideband Channels
   input  logic [7:0]  qos_in,
   output logic [7:0]  qos_out,
   input  logic [7:0]  region_in,
   output logic [7:0]  region_out
);

   logic [31:0] ahb_haddr;
   logic [2:0]  ahb_hburst;
   logic        ahb_hmastlock;
   logic [3:0]  ahb_hprot;
   logic [2:0]  ahb_hsize;
   logic [1:0]  ahb_htrans;
   logic        ahb_hwrite;
   logic [63:0] ahb_hwdata;
   logic [63:0] ahb_hrdata;
   logic        ahb_hready;
   logic        ahb_hresp;

   axi4_to_ahb #(
      .pt          ( pt ),
      .TAG         ( 1  ),
      .NUM_THREADS ( 1  ),
      .BUS_WIDTH   ( 64 )
   ) u_axi4_to_ahb (
      .clk                ( clk_i              ),
      .free_clk           ( clk_i              ),
      .rst_l              ( rst_ni             ),
      .scan_mode          ( 1'b0               ),
      .bus_clk_en         ( bus_clk_en         ),
      .clk_override       ( 1'b0               ),
      .dec_tlu_force_halt ( dec_tlu_force_halt ),

      .axi_awvalid        ( m_axi_awvalid      ),
      .axi_awready        ( m_axi_awready      ),
      .axi_awid           ( m_axi_awid         ),
      .axi_awaddr         ( m_axi_awaddr       ),
      .axi_awsize         ( m_axi_awsize       ),
      .axi_awprot         ( m_axi_awprot       ),

      .axi_wvalid         ( m_axi_wvalid       ),
      .axi_wready         ( m_axi_wready       ),
      .axi_wdata          ( m_axi_wdata        ),
      .axi_wstrb          ( m_axi_wstrb        ),
      .axi_wlast          ( m_axi_wlast        ),

      .axi_bvalid         ( m_axi_bvalid       ),
      .axi_bready         ( m_axi_bready       ),
      .axi_bresp          ( m_axi_bresp        ),
      .axi_bid            ( m_axi_bid          ),

      .axi_arvalid        ( m_axi_arvalid      ),
      .axi_arready        ( m_axi_arready      ),
      .axi_arid           ( m_axi_arid         ),
      .axi_araddr         ( m_axi_araddr       ),
      .axi_arsize         ( m_axi_arsize       ),
      .axi_arprot         ( m_axi_arprot       ),

      .axi_rvalid         ( m_axi_rvalid       ),
      .axi_rready         ( m_axi_rready       ),
      .axi_rid            ( m_axi_rid          ),
      .axi_rdata          ( m_axi_rdata        ),
      .axi_rresp          ( m_axi_rresp        ),
      .axi_rlast          ( m_axi_rlast        ),

      .ahb_haddr          ( ahb_haddr          ),
      .ahb_hburst         ( ahb_hburst         ),
      .ahb_hmastlock      ( ahb_hmastlock      ),
      .ahb_hprot          ( ahb_hprot          ),
      .ahb_hsize          ( ahb_hsize          ),
      .ahb_htrans         ( ahb_htrans         ),
      .ahb_hwrite         ( ahb_hwrite         ),
      .ahb_hwdata         ( ahb_hwdata         ),
      .ahb_hrdata         ( ahb_hrdata         ),
      .ahb_hready         ( ahb_hready         ),
      .ahb_hresp          ( ahb_hresp          )
   );

   ahb_to_axi4 #(
      .TAG       ( 1  ),
      .pt        ( pt ),
      .BUS_WIDTH ( 64 )
   ) u_ahb_to_axi4 (
      .clk           ( clk_i         ),
      .rst_l         ( rst_ni        ),
      .scan_mode     ( 1'b0          ),
      .bus_clk_en    ( bus_clk_en    ),
      .clk_override  ( 1'b0          ),

      .axi_awvalid   ( s_axi_awvalid ),
      .axi_awready   ( s_axi_awready ),
      .axi_awid      ( s_axi_awid    ),
      .axi_awaddr    ( s_axi_awaddr  ),
      .axi_awsize    ( s_axi_awsize  ),
      .axi_awprot    ( s_axi_awprot  ),
      .axi_awlen     ( s_axi_awlen   ),
      .axi_awburst   ( s_axi_awburst ),

      .axi_wvalid    ( s_axi_wvalid  ),
      .axi_wready    ( s_axi_wready  ),
      .axi_wdata     ( s_axi_wdata   ),
      .axi_wstrb     ( s_axi_wstrb   ),
      .axi_wlast     ( s_axi_wlast   ),

      .axi_bvalid    ( s_axi_bvalid  ),
      .axi_bready    ( s_axi_bready  ),
      .axi_bresp     ( s_axi_bresp   ),
      .axi_bid       ( s_axi_bid     ),

      .axi_arvalid   ( s_axi_arvalid ),
      .axi_arready   ( s_axi_arready ),
      .axi_arid      ( s_axi_arid    ),
      .axi_araddr    ( s_axi_araddr  ),
      .axi_arsize    ( s_axi_arsize  ),
      .axi_arprot    ( s_axi_arprot  ),
      .axi_arlen     ( s_axi_arlen   ),
      .axi_arburst   ( s_axi_arburst ),

      .axi_rvalid    ( s_axi_rvalid  ),
      .axi_rready    ( s_axi_rready  ),
      .axi_rid       ( s_axi_rid     ),
      .axi_rdata     ( s_axi_rdata   ),
      .axi_rresp     ( s_axi_rresp   ),

      .ahb_haddr     ( ahb_haddr     ),
      .ahb_hburst    ( ahb_hburst    ),
      .ahb_hmastlock ( ahb_hmastlock ),
      .ahb_hprot     ( ahb_hprot     ),
      .ahb_hsize     ( ahb_hsize     ),
      .ahb_htrans    ( ahb_htrans    ),
      .ahb_hwrite    ( ahb_hwrite    ),
      .ahb_hwdata    ( ahb_hwdata    ),
      .ahb_hsel      ( 1'b1          ),
      .ahb_hreadyin  ( ahb_hready    ),
      .ahb_hrdata    ( ahb_hrdata    ),
      .ahb_hreadyout ( ahb_hready    ),
      .ahb_hresp     ( ahb_hresp     )
   );

   assign qos_out    = qos_in;
   assign region_out = region_in;

endmodule
