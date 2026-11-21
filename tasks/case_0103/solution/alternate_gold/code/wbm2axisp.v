////////////////////////////////////////////////////////////////////////////////
//
// Filename:	rtl/wbm2axisp.v
// {{{
// Project:	WB2AXIPSP: bus bridges and other odds and ends
//
// Purpose:	The B4 Wishbone SPEC allows transactions at a speed as fast as
//		one per clock.  The AXI bus allows transactions at a speed of
//	one read and one write transaction per clock.  These capabilities work
//	by allowing requests to take place prior to responses, such that the
//	requests might go out at once per clock and take several clocks, and
//	the responses may start coming back several clocks later.  In other
//	words, both protocols allow multiple transactions to be "in flight" at
//	the same time.  Current wishbone to AXI converters, however, handle only
//	one transaction at a time: initiating the transaction, and then waiting
//	for the transaction to complete before initiating the next.
//
//	The purpose of this core is to maintain the speed of both buses, while
//	transiting from the Wishbone (as master) to the AXI bus (as slave) and
//	back again.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2016-2025, Gisselquist Technology, LLC
// {{{
// This file is part of the WB2AXIP project.
//
// The WB2AXIP project contains free software and gateware, licensed under the
// Apache License, Version 2.0 (the "License").  You may not use this project,
// or this file, except in compliance with the License.  You may obtain a copy
// of the License at
// }}}
//	http://www.apache.org/licenses/LICENSE-2.0
// {{{
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
// License for the specific language governing permissions and limitations
// under the License.
//
////////////////////////////////////////////////////////////////////////////////
//
`default_nettype	none
// }}}
module wbm2axisp #(
	// {{{
	parameter C_AXI_DATA_WIDTH	= 128,// Width of the AXI R&W data
	parameter C_AXI_ADDR_WIDTH	=  28,	// AXI Address width (log wordsize)
	parameter C_AXI_ID_WIDTH	=   1,
	parameter DW			=  32,	// Wishbone data width
	parameter AW			=  26,	// Wishbone address width (log wordsize)
	parameter [C_AXI_ID_WIDTH-1:0] AXI_WRITE_ID = 1'b0,
	parameter [C_AXI_ID_WIDTH-1:0] AXI_READ_ID  = 1'b1,
	//
	// OPT_LITTLE_ENDIAN controls which word has the greatest address
	// when the bus size is adjusted.  If OPT_LITTLE_ENDIAN is true,
	// the biggest address is in the most significant word(s), otherwise
	// the least significant word(s).  This parameter is ignored if
	// C_AXI_DATA_WIDTH == DW.
	parameter [0:0]			OPT_LITTLE_ENDIAN = 1'b1,
	parameter LGFIFO		=   6
	// }}}
	) (
	// {{{
	input	wire			i_clk,	// System clock
	input	wire			i_reset,// Reset signal,drives AXI rst

	// AXI write address channel signals
	output	reg			o_axi_awvalid,	// Write address valid
	input	wire			i_axi_awready, // Slave is ready to accept
	output	wire	[C_AXI_ID_WIDTH-1:0]	o_axi_awid,	// Write ID
	output	reg	[C_AXI_ADDR_WIDTH-1:0]	o_axi_awaddr,	// Write address
	output	wire	[7:0]		o_axi_awlen,	// Write Burst Length
	output	wire	[2:0]		o_axi_awsize,	// Write Burst size
	output	wire	[1:0]		o_axi_awburst,	// Write Burst type
	output	wire	[0:0]		o_axi_awlock,	// Write lock type
	output	wire	[3:0]		o_axi_awcache,	// Write Cache type
	output	wire	[2:0]		o_axi_awprot,	// Write Protection type
	output	wire	[3:0]		o_axi_awqos,	// Write Quality of Svc

// AXI write data channel signals
	output	reg			o_axi_wvalid,	// Write valid
	input	wire			i_axi_wready,  // Write data ready
	output	reg	[C_AXI_DATA_WIDTH-1:0]	o_axi_wdata,	// Write data
	output	reg	[C_AXI_DATA_WIDTH/8-1:0] o_axi_wstrb,	// Write strobes
	output	wire			o_axi_wlast,	// Last write transaction

// AXI write response channel signals
	input	wire			i_axi_bvalid,  // Write reponse valid
	output	wire			o_axi_bready,  // Response ready
	input wire [C_AXI_ID_WIDTH-1:0]	i_axi_bid,	// Response ID
	input	wire [1:0]		i_axi_bresp,	// Write response

// AXI read address channel signals
	output	reg			o_axi_arvalid,	// Read address valid
	input	wire			i_axi_arready,	// Read address ready
	output	wire	[C_AXI_ID_WIDTH-1:0]	o_axi_arid,	// Read ID
	output	reg	[C_AXI_ADDR_WIDTH-1:0]	o_axi_araddr,	// Read address
	output	wire	[7:0]		o_axi_arlen,	// Read Burst Length
	output	wire	[2:0]		o_axi_arsize,	// Read Burst size
	output	wire	[1:0]		o_axi_arburst,	// Read Burst type
	output	wire	[0:0]		o_axi_arlock,	// Read lock type
	output	wire	[3:0]		o_axi_arcache,	// Read Cache type
	output	wire	[2:0]		o_axi_arprot,	// Read Protection type
	output	wire	[3:0]		o_axi_arqos,	// Read Protection type

// AXI read data channel signals
	input	wire			i_axi_rvalid,  // Read reponse valid
	output	wire			o_axi_rready,  // Read Response ready
	input wire [C_AXI_ID_WIDTH-1:0]	i_axi_rid,     // Response ID
	input wire [C_AXI_DATA_WIDTH-1:0] i_axi_rdata,    // Read data
	input	wire	[1:0]		i_axi_rresp,   // Read response
	input	wire			i_axi_rlast,    // Read last

	// We'll share the clock and the reset
	input	wire			i_wb_cyc,
	input	wire			i_wb_stb,
	input	wire			i_wb_we,
	input	wire	[(AW-1):0]	i_wb_addr,
	input	wire	[(DW-1):0]	i_wb_data,
	input	wire	[(DW/8-1):0]	i_wb_sel,
	output	reg			o_wb_stall,
	output	reg			o_wb_ack,
	output	reg	[(DW-1):0]	o_wb_data,
	output	reg			o_wb_err
	// }}}
);
	////////////////////////////////////////////////////////////////////////
	//
	// Localparameter declarations, initial parameter consistency check
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	localparam	LG_AXI_DW	= $clog2(C_AXI_DATA_WIDTH);
	localparam	LG_WB_DW	= $clog2(DW);
	// localparam	FIFOLN = (1<<LGFIFO);
	localparam	SUBW = LG_AXI_DW-LG_WB_DW;

	// The various address widths must be properly related.  We'll insist
	// upon that relationship here.
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Internal register and wire declarations
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// Things we're not changing ...
	localparam	DWSIZE = $clog2(DW)-3;
	assign o_axi_awid    = AXI_WRITE_ID;
	assign o_axi_awlen   = 8'h0;	// Burst length is one
	assign o_axi_awsize  = DWSIZE[2:0];
	assign o_axi_wlast   = 1;
	assign o_axi_awburst = 2'b01;	// Incrementing address (ignored)
	assign o_axi_awlock  = 1'b0;	// Normal signaling
	assign o_axi_arlock  = 1'b0;	// Normal signaling
	assign o_axi_awcache = 4'h3;	// Normal: no cache, modifiable
	//
	assign o_axi_arid    = AXI_READ_ID;
	assign o_axi_arlen   = 8'h0;	// Burst length is one
	assign o_axi_arsize  = DWSIZE[2:0];
	assign o_axi_arburst = 2'b01;	// Incrementing address (ignored)
	assign o_axi_arcache = 4'h3;	// Normal: no cache, modifiable
	assign o_axi_awprot  = 3'b010;	// Unpriviledged, unsecure, data access
	assign o_axi_arprot  = 3'b010;	// Unpriviledged, unsecure, data access
	assign o_axi_awqos   = 4'h0;	// Lowest quality of service (unused)
	assign o_axi_arqos   = 4'h0;	// Lowest quality of service (unused)

	reg			direction, full, empty, flushing, nearfull;
	reg	[LGFIFO:0]	npending;
	//
	wire			skid_ready, m_valid, m_we;
	reg			m_ready;
	wire	[AW-1:0]	m_addr;
	wire	[DW-1:0]	m_data;
	wire	[DW/8-1:0]	m_sel;

	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Overarching command logic
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (i_reset)
		direction <= 1'b0;
	else if (empty)
		direction <= m_we;




	always @(posedge i_clk)
	if (i_reset)
	begin
		npending <= 0;
		empty    <= 1;
		full     <= 0;
		nearfull <= 0;
	end else case ({m_valid && m_ready, i_axi_bvalid||i_axi_rvalid})
	2'b10: begin
		npending <= npending + 1;
		empty <= 0;
		nearfull <= &(npending[LGFIFO-1:1]);
		full <= &(npending[LGFIFO-1:0]);
		end
	2'b01: begin
		nearfull <= full;
		npending <= npending - 1;
		empty <= (npending == 1);
		full <= 0;
		end
	default: begin end
	endcase

	always @(posedge i_clk)
	if (i_reset)
	begin
		flushing <= 0;
		o_wb_data <= 0;
	end
	else if ((i_axi_rvalid && i_axi_rresp[1])
		||(i_axi_bvalid && i_axi_bresp[1])
		||(!i_wb_cyc && !empty))
		flushing <= 1'b1;
	else if (empty)
		flushing <= 1'b0;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Wishbone input skidbuffer
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	skidbuffer #(
		// {{{
		.DW(1+AW+DW+(DW/8)),
		.OPT_OUTREG(1'b0)
		// }}}
	) skid (
		// {{{
		.i_clk(i_clk), .i_reset(i_reset || !i_wb_cyc),
		.i_valid(i_wb_stb), .o_ready(skid_ready),
			.i_data({ i_wb_we, i_wb_addr, i_wb_data, i_wb_sel }),
		.o_valid(m_valid), .i_ready(m_ready),
			.o_data({ m_we, m_addr, m_data, m_sel })
		// }}}
	);

	always @(*)
		o_wb_stall = !skid_ready;

	always @(*)
	begin
		m_ready = 1;

		if (flushing || nearfull || ((m_we != direction)&&(!empty)))
			m_ready = 1'b0;
		if (o_axi_awvalid && !i_axi_awready)
			m_ready = 1'b0;
		if (o_axi_wvalid && !i_axi_wready)
			m_ready = 1'b0;
		if (o_axi_arvalid && !i_axi_arready)
			m_ready = 1'b0;
	end
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// AXI Signaling
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	//
	// Write transactions
	//

	// awvalid, wvalid
	// {{{
	// Send write transactions


	always @(posedge i_clk)
	if (i_reset)
	begin
		o_axi_awvalid <= 0;
		o_axi_wvalid  <= 0;
	end else if (m_valid && m_we && m_ready)
	begin
		o_axi_awvalid <= 1;
		o_axi_wvalid  <= 1;
	end else begin
		if (i_axi_awready)
			o_axi_awvalid <= 0;
		if (i_axi_wready)
			o_axi_wvalid <= 0;
	end
	// }}}

	// wdata
	// {{{
	always @(posedge i_clk)
	if (!o_axi_wvalid || i_axi_wready)
		o_axi_wdata   <= {(C_AXI_DATA_WIDTH/DW){m_data}};
	// }}}

	// wstrb
	// {{{
	generate if (DW == C_AXI_DATA_WIDTH)
	begin : NO_WSTRB_ADJUSTMENT
		// {{{
		always @(posedge i_clk)
		if (!o_axi_wvalid || i_axi_wready)
			o_axi_wstrb   <= m_sel;
		// }}}
	end else if (OPT_LITTLE_ENDIAN)
	begin : LITTLE_ENDIAN_WSTRB
		// {{{
		always @(posedge i_clk)
		if (!o_axi_wvalid || i_axi_wready)
			// Verilator lint_off WIDTH
			o_axi_wstrb   <= m_sel << ((DW/8) * m_addr[SUBW-1:0]);
			// Verilator lint_on  WIDTH
		// }}}
	end else begin : BIG_ENDIAN_WSTRB
		// {{{
		reg	[SUBW-1:0]	neg_addr;

		always @(*)
			neg_addr = ~m_addr[SUBW-1:0];

		always @(posedge i_clk)
		if (!o_axi_wvalid || i_axi_wready)
			// Verilator lint_off WIDTH
			o_axi_wstrb   <= m_sel << ((DW/8)* neg_addr);
			// Verilator lint_on  WIDTH
		// }}}
	end endgenerate
	// }}}

	//
	// Read transactions
	//

	// arvalid
	// {{{

	always @(posedge i_clk)
	if (i_reset)
		o_axi_arvalid <= 0;
	else if (m_valid && !m_we && m_ready)
		o_axi_arvalid <= 1;
	else if (i_axi_arready)
	begin
		o_axi_arvalid <= 0;
	end
	// }}}

	// awaddr, araddr
	// {{{
	generate if (OPT_LITTLE_ENDIAN || DW == C_AXI_DATA_WIDTH)
	begin : GEN_ADDR_LSBS
		// {{{
		always @(posedge i_clk)
		if (!o_axi_awvalid || i_axi_awready)
			o_axi_awaddr  <= { m_addr, {($clog2(DW)-3){1'b0}} };

		always @(posedge i_clk)
		if (!o_axi_arvalid || i_axi_arready)
			o_axi_araddr  <= { m_addr, {($clog2(DW)-3){1'b0}} };
		// }}}
	end else begin : OPT_BIG_ENDIAN
		// {{{
		reg	[SUBW-1:0]	neg_addr;

		always @(*)
			neg_addr = ~m_addr[SUBW-1:0];

		always @(posedge i_clk)
		if (!o_axi_awvalid || i_axi_awready)
		begin
			o_axi_awaddr <= 0;
			o_axi_awaddr <= m_addr << ($clog2(DW)-3);
			o_axi_awaddr[$clog2(DW)-3 +: SUBW] <= neg_addr;
		end

		always @(posedge i_clk)
		if (!o_axi_arvalid || i_axi_arready)
		begin
			o_axi_araddr <= 0;
			o_axi_araddr <= m_addr << ($clog2(DW)-3);
			o_axi_araddr[$clog2(DW)-3 +: SUBW] <= neg_addr;
		end
		// }}}
	end endgenerate
	// }}}

	// rdata, and returned o_wb_data, o_wb_ack, o_wb_err
	// {{{
	generate if (DW == C_AXI_DATA_WIDTH)
	begin : NO_READ_DATA_SELECT_NECESSARY
		// {{{
		always @(*)
			o_wb_data = i_axi_rdata;

		always @(*)
			o_wb_ack = !flushing&&((i_axi_rvalid && !i_axi_rresp[1])
				||(i_axi_bvalid && !i_axi_bresp[1]));

		always @(*)
			o_wb_err = !flushing&&((i_axi_rvalid && i_axi_rresp[1])
				||(i_axi_bvalid && i_axi_bresp[1]));
		// }}}
	end else begin : READ_FIFO_DATA_SELECT
	// {{{

		reg	[SUBW-1:0]	addr_fifo	[0:(1<<LGFIFO)-1];
		reg	[SUBW-1:0]	fifo_value;
		reg	[LGFIFO:0]	wr_addr, rd_addr;
		wire	[C_AXI_DATA_WIDTH-1:0]	return_data;

		always @(posedge i_clk)
		if (i_reset || !i_wb_cyc || flushing)
			o_wb_ack <= 0;
		else
			o_wb_ack <= ((i_axi_rvalid && !i_axi_rresp[1])
				||(i_axi_bvalid && !i_axi_bresp[1]));

		always @(posedge i_clk)
		if (i_reset || !i_wb_cyc || flushing)
			o_wb_err <= 0;
		else
			o_wb_err <= ((i_axi_rvalid && i_axi_rresp[1])
				||(i_axi_bvalid && i_axi_bresp[1]));

		always @(posedge i_clk)
		if (i_reset)
			wr_addr <= 0;
		else if (m_valid && m_ready)
			wr_addr <= wr_addr + 1;

		always @(posedge i_clk)
		if (m_valid && m_ready)
			addr_fifo[wr_addr[LGFIFO-1:0]] <= m_addr[SUBW-1:0];

		always @(posedge i_clk)
		if (i_reset)
			rd_addr <= 0;
		else if (i_axi_bvalid || i_axi_rvalid)
			rd_addr <= rd_addr + 1;

		always @(*)
			fifo_value = addr_fifo[rd_addr[LGFIFO-1:0]];

		if (OPT_LITTLE_ENDIAN)
		begin : LITTLE_ENDIAN_RDATA

			assign	return_data = i_axi_rdata >> (fifo_value * DW);

		end else begin : BIG_ENDIAN_RDATA

			reg	[SUBW-1:0]	neg_fifo_value;

			always @(*)
				neg_fifo_value = ~fifo_value;

			assign	return_data = i_axi_rdata
						>> (neg_fifo_value * DW);

		end

		always @(posedge i_clk)
			o_wb_data <= return_data[DW-1:0];

		// Make Verilator happy here
		// verilator lint_off UNUSED
		if (C_AXI_DATA_WIDTH > DW)
		begin : UNUSED_DATA
			wire	unused_data;
			assign	unused_data = &{ 1'b0,
					return_data[C_AXI_DATA_WIDTH-1:DW] };
		end
		// verilator lint_on  UNUSED

	// }}}
	end endgenerate
	// }}}

	// Read data channel / response logic
	assign	o_axi_rready = 1'b1;
	assign	o_axi_bready = 1'b1;
	// }}}

	// Make verilator's -Wall happy
	// {{{
	// verilator lint_off UNUSED
	wire	unused;
	assign	unused = &{ 1'b0, full, i_axi_bid, i_axi_bresp[0], i_axi_rid, i_axi_rresp[0], i_axi_rlast, m_data, m_sel };
	generate if (C_AXI_DATA_WIDTH > DW)
	begin : GEN_UNUSED_DW
		wire	[C_AXI_DATA_WIDTH-1:DW] unused_data;
		assign	unused_data = i_axi_rdata[C_AXI_DATA_WIDTH-1:DW];
	end endgenerate
	// verilator lint_on  UNUSED
	// }}}

/////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////
//
// Formal methods section
// {{{
// Below are a scattering of the formal properties used.  They are not the
// complete set of properties.  Those are maintained elsewhere.
/////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////
 // FORMAL
// }}}
endmodule
