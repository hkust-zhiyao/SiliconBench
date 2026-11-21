////////////////////////////////////////////////////////////////////////////////
//
// Filename:	rtl/aximwr2wbsp.v
// {{{
// Project:	WB2AXIPSP: bus bridges and other odds and ends
//
// Purpose:	Convert the three AXI4 write channels to a single wishbone
//		channel to write the results.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2015-2025, Gisselquist Technology, LLC
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
module aximwr2wbsp #(
		// {{{
		parameter C_AXI_ID_WIDTH	= 6,
		parameter C_AXI_DATA_WIDTH	= 32,
		parameter C_AXI_ADDR_WIDTH	= 28,
		parameter [0:0] OPT_SWAP_ENDIANNESS = 1'b0,
		localparam AXI_LSBS		= $clog2(C_AXI_DATA_WIDTH)-3,
		localparam AW			= C_AXI_ADDR_WIDTH-AXI_LSBS,

		parameter LGFIFO                =  5
		// }}}
	) (
		// {{{
		input	wire			S_AXI_ACLK,	// System clock
		input	wire			S_AXI_ARESETN,
		// Incoming AXI bus connections
		// {{{
		// AXI write address channel signals
		input	wire			S_AXI_AWVALID,
		output	wire			S_AXI_AWREADY,
		input	wire	[C_AXI_ID_WIDTH-1:0]	S_AXI_AWID,
		input	wire	[C_AXI_ADDR_WIDTH-1:0]	S_AXI_AWADDR,
		input	wire	[7:0]		S_AXI_AWLEN,
		input	wire	[2:0]		S_AXI_AWSIZE,
		input	wire	[1:0]		S_AXI_AWBURST,
		input	wire	[0:0]		S_AXI_AWLOCK,
		input	wire	[3:0]		S_AXI_AWCACHE,
		input	wire	[2:0]		S_AXI_AWPROT,
		input	wire	[3:0]		S_AXI_AWQOS,

		// AXI write data channel signals
		input	wire			S_AXI_WVALID,
		output	wire			S_AXI_WREADY,
		input	wire	[C_AXI_DATA_WIDTH-1:0]	S_AXI_WDATA,
		input	wire	[C_AXI_DATA_WIDTH/8-1:0] S_AXI_WSTRB,
		input	wire			S_AXI_WLAST,

		// AXI write response channel signals
		output	wire			S_AXI_BVALID,
		input	wire			S_AXI_BREADY,
		output	wire [C_AXI_ID_WIDTH-1:0] S_AXI_BID,
		output	wire [1:0]		S_AXI_BRESP,
		// }}}
		// Downstream wishbone bus
		// {{{
		// We'll share the clock and the reset
		output	reg			o_wb_cyc,
		output	reg			o_wb_stb,
		output	reg [(AW-1):0]		o_wb_addr,
		output	reg [(C_AXI_DATA_WIDTH-1):0]	o_wb_data,
		output	reg [(C_AXI_DATA_WIDTH/8-1):0]	o_wb_sel,
		input	wire			i_wb_stall,
		input	wire			i_wb_ack,
		// input [(C_AXI_DATA_WIDTH-1):0] i_wb_data,
		input	wire			i_wb_err
		// }}}

		// }}}
	);

	// Register/net declarations
	// {{{
	localparam DW			= C_AXI_DATA_WIDTH;
	wire			w_reset;

	wire			skid_awvalid;
	reg			accept_write_burst;
	wire [C_AXI_ID_WIDTH-1:0]	skid_awid;
	wire [C_AXI_ADDR_WIDTH-1:0]	skid_awaddr;
	wire	[7:0]		skid_awlen;
	wire	[2:0]		skid_awsize;
	wire	[1:0]		skid_awburst;
	//
	wire				skid_wvalid, skid_wlast;
	reg				skid_wready;
	wire [C_AXI_DATA_WIDTH-1:0]	skid_wdata;
	wire [C_AXI_DATA_WIDTH/8-1:0]	skid_wstrb;

	reg				skid_awready;
	reg	[7:0]			axi_wlen, wlen;
	reg [C_AXI_ID_WIDTH-1:0]	axi_wid;
	reg [C_AXI_ADDR_WIDTH-1:0]	axi_waddr;
	wire [C_AXI_ADDR_WIDTH-1:0]	next_addr;
	reg	[1:0]			axi_wburst;
	reg	[2:0]			axi_wsize;

	reg	[LGFIFO+7:0]	acks_expected;
	reg	[LGFIFO:0]	writes_expected;
	reg			last_ack;
	reg			err_state;

	reg				read_ack_fifo;
	wire	[7:0]			fifo_ack_ln;
	reg	[8:0]			acklen;
	reg				ack_last, ack_err, ack_empty;

	reg	[LGFIFO:0]	total_fifo_fill;
	reg			total_fifo_full;

	wire			wb_ack_fifo_full, wb_ack_fifo_empty;
	wire	[LGFIFO:0]	wb_ack_fifo_fill;

	wire			err_fifo_full, err_fifo_empty;
	wire	[LGFIFO:0]	err_fifo_fill;
	reg			err_fifo_write;

	wire			bid_fifo_full, bid_fifo_empty;
	wire	[LGFIFO:0]	bid_fifo_fill;

	reg	[8:0]	next_acklen;
	reg	[1:0]	next_acklow;

	assign	w_reset = (S_AXI_ARESETN == 1'b0);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Skid buffers--all incoming signals go throug skid buffers
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// write address skid buffer
	// {{{
	skidbuffer #(
		.OPT_OUTREG(0),
		.DW(C_AXI_ADDR_WIDTH+C_AXI_ID_WIDTH+8+3+2))
	awskid(S_AXI_ACLK, !S_AXI_ARESETN, S_AXI_AWVALID, S_AXI_AWREADY,
		{ S_AXI_AWID, S_AXI_AWADDR, S_AXI_AWLEN,
			S_AXI_AWSIZE, S_AXI_AWBURST },
		skid_awvalid, accept_write_burst,
		{ skid_awid, skid_awaddr, skid_awlen,
			skid_awsize, skid_awburst });
	// }}}

	// write channel skid buffer
	// {{{
	skidbuffer #(

		.OPT_OUTREG(0),
		.DW(C_AXI_DATA_WIDTH + C_AXI_DATA_WIDTH/8+1))
	wskid(S_AXI_ACLK, !S_AXI_ARESETN,
		S_AXI_WVALID, S_AXI_WREADY,
		{ S_AXI_WDATA, S_AXI_WSTRB, S_AXI_WLAST },
		skid_wvalid, skid_wready,
		{ skid_wdata, skid_wstrb, skid_wlast });
	// }}}

	// accept_write_burst
	// {{{
	always @(*)
	begin
		accept_write_burst = (skid_awready)&&(!o_wb_stb || !i_wb_stall)
				&&(!err_state)&&(skid_awvalid)
				&&(!total_fifo_full);
		if (axi_wid != skid_awid && (acks_expected > 0))
			accept_write_burst = 0;
		if (!skid_wvalid)
			accept_write_burst = 0;
	end
	// }}}

	// skid_wready
	// {{{
	always @(*)
		skid_wready = (!o_wb_stb || !i_wb_stall || err_state)
			&&(!skid_awready || accept_write_burst);
	// }}}

	// skid_awready
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		skid_awready <= 1'b1;
	else if (accept_write_burst)
		skid_awready <= (skid_awlen == 0)&&(skid_wvalid)&&(skid_wlast);
	else if (skid_wvalid && skid_wready && skid_wlast)
		skid_awready <= 1'b1;
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Burst unwinding
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// axi_w*, wlen -- properties of the currently active burst
	// {{{
	always @(posedge S_AXI_ACLK)
	if (accept_write_burst)
	begin
		axi_wid   <= skid_awid;
		axi_waddr <= skid_awaddr;
		axi_wsize  <= skid_awsize;
		axi_wburst <= skid_awburst;
		axi_wlen   <= skid_awlen;
		wlen <= skid_awlen;
	end else if (skid_wvalid && skid_wready)
	begin
		axi_waddr <= next_addr;
		if (!skid_awready)
			wlen <= wlen - 1;
	end
	// }}}

	// next_addr
	// {{{
	axi_addr #(.AW(C_AXI_ADDR_WIDTH), .DW(C_AXI_DATA_WIDTH))
	next_write_addr(axi_waddr, axi_wsize, axi_wburst, axi_wlen, next_addr);
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Issue the Wishbone request
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// o_wb_cyc, o_wb_stb
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || err_state || (o_wb_cyc && i_wb_err))
	begin
		o_wb_cyc <= 1'b0;
		o_wb_stb <= 1'b0;
	end else if (accept_write_burst)
	begin
		o_wb_cyc <= 1'b1;
		o_wb_stb <= skid_wvalid && skid_wready;
	end else begin
		if (!o_wb_stb || !i_wb_stall)
			o_wb_stb <= (!skid_awready)&&(skid_wvalid&&skid_wready);
		if (o_wb_cyc && last_ack && i_wb_ack && !skid_awvalid)
			o_wb_cyc <= 0;
	end
	// }}}

	always @(*)
		o_wb_addr = axi_waddr[C_AXI_ADDR_WIDTH-1:AXI_LSBS];

	// o_wb_data, o_wb_sel
	// {{{
	generate if (OPT_SWAP_ENDIANNESS)
	begin : SWAP_ENDIANNESS
		integer	ik;

		always @(posedge S_AXI_ACLK)
		if (!o_wb_stb || !i_wb_stall)
		begin
			for(ik=0; ik<DW/8; ik=ik+1)
			begin
				o_wb_data[ik*8 +: 8]
					<= skid_wdata[(DW/8-1-ik)*8 +: 8];
				o_wb_sel[ik]  <= skid_wstrb[DW/8-1-ik];
			end
		end

	end else begin : KEEP_ENDIANNESS

		always @(posedge S_AXI_ACLK)
		if (!o_wb_stb || !i_wb_stall)
		begin
			o_wb_data <= skid_wdata;
			o_wb_sel  <= skid_wstrb;
		end

	end endgenerate
	// }}}

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// FIFO usage tracking
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// writes_expected
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
	begin
		writes_expected <= 0;
	end else case({skid_wvalid && skid_wready && skid_wlast,
			S_AXI_BVALID && S_AXI_BREADY })
	2'b01:	writes_expected <= writes_expected - 1;
	2'b10:	writes_expected <= writes_expected + 1;
	default: begin end
	endcase
	// }}}

	// acks_expected
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || i_wb_err || err_state)
	begin
		acks_expected <= 0;
	end else case({skid_awvalid && accept_write_burst, {i_wb_ack|i_wb_err}})
	2'b01:	acks_expected <= acks_expected - 1;
	2'b10:	acks_expected <= acks_expected + ({{(LGFIFO){1'b0}},skid_awlen} + 1);
	2'b11:	acks_expected <= acks_expected +  {{(LGFIFO){1'b0}},skid_awlen};
	default: begin end
	endcase
	// }}}

	// last_ack
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || i_wb_err || err_state)
	begin
		last_ack <= 1;
	end else case({skid_awvalid && accept_write_burst, i_wb_ack })
	2'b01:	last_ack <= (acks_expected <= 2);
	2'b10:	last_ack <= (acks_expected == 0)&&(skid_awlen == 0);
	2'b11:	last_ack <= last_ack && (skid_awlen == 0);
	default: begin end
	endcase

	// }}}

	// total_fifo_fill
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		total_fifo_fill <= 0;
	else case({ accept_write_burst, S_AXI_BVALID && S_AXI_BREADY })
	2'b01: total_fifo_fill <= total_fifo_fill - 1;
	2'b10: total_fifo_fill <= total_fifo_fill + 1;
	default: begin end
	endcase
	// }}}

	// total_fifo_full
	// {{{
	always @(*)
		total_fifo_full = total_fifo_fill[LGFIFO];
	// }}}
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Return channel
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// wb_ack_fifo
	// {{{
	sfifo #(.BW(8), .LGFLEN(LGFIFO),
		.OPT_ASYNC_READ(1'b1))
	wb_ack_fifo(S_AXI_ACLK, !S_AXI_ARESETN,
		accept_write_burst, skid_awlen,
		wb_ack_fifo_full, wb_ack_fifo_fill,
		read_ack_fifo, fifo_ack_ln, wb_ack_fifo_empty);
	// }}}

	// read_ack_fifo
	// {{{
	always @(*)
	begin
		read_ack_fifo = ack_last && (i_wb_ack || i_wb_err);
		if (err_state || ack_empty)
			read_ack_fifo = 1;
		if (wb_ack_fifo_empty)
			read_ack_fifo = 1'b0;
	end
	// }}}

	// next_acklen
	// {{{
	always @(*)
		next_acklen = fifo_ack_ln + ((acklen[0] ? 1:0)
				+ ((i_wb_ack|i_wb_err)? 0:1));
	// }}}

	// next_acklow
	// {{{
	always @(*)
		next_acklow = fifo_ack_ln[0] + ((acklen[0] ? 1:0)
				+ ((i_wb_ack|i_wb_err)? 0:1));
	// }}}

	// acklen, ack_last, ack_empty
	// {{{



	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN || err_state)
	begin
		acklen   <= 0;
		ack_last <= 0;
		ack_empty<= 1;
	end else if (read_ack_fifo)
	begin
		acklen   <= next_acklen;
		ack_last <= (fifo_ack_ln < 2)&&(next_acklow == 1);
		ack_empty<= (fifo_ack_ln == 0)&&(!acklen[0])
					&&(i_wb_ack || i_wb_err);
	end else if (i_wb_ack || i_wb_err)
	begin
		if (acklen > 0)
			acklen <= acklen - 1;
		ack_last <= (acklen == 2);
		ack_empty <= ack_last;
	end
	// }}}

	// ack_err
	// {{{
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		ack_err <= 1'b0;
	else if (read_ack_fifo)
	begin
		ack_err <= (!wb_ack_fifo_empty) && (err_state || i_wb_err);
	end else if (i_wb_ack || i_wb_err || err_state)
		ack_err <= ack_err || (i_wb_err || err_state);
	// }}}

	// err_state
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		err_state <= 0;
	else if (o_wb_cyc && i_wb_err)
		err_state <= 1;
	else if ((total_fifo_fill == bid_fifo_fill)
		&&(total_fifo_fill == err_fifo_fill))
		err_state <= 0;
	// }}}

	// err_fifo_write
	// {{{

	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN)
		err_fifo_write <= 0;
	else if (read_ack_fifo && !wb_ack_fifo_empty && ((fifo_ack_ln == 0 && (i_wb_ack || i_wb_err)) || err_state))
		err_fifo_write <= 1'b1;
	else if (ack_last && (i_wb_ack || i_wb_err))
		err_fifo_write <= 1'b1;
	else if (o_wb_cyc && i_wb_err && !ack_empty && !ack_last)
		err_fifo_write <= 1'b1;
	else
		err_fifo_write <= 1'b0;
	// }}}

	reg [LGFIFO:0] b_wr_ptr, b_rd_ptr;
	wire [LGFIFO:0] b_diff = b_wr_ptr - b_rd_ptr;
	always @(posedge S_AXI_ACLK)
	if (!S_AXI_ARESETN) begin
		b_wr_ptr <= 0;
		b_rd_ptr <= 0;
	end else begin
		if (skid_wvalid && skid_wready && skid_wlast && !bid_fifo_full)
			b_wr_ptr <= b_wr_ptr + 1;
		if (S_AXI_BVALID && S_AXI_BREADY && !bid_fifo_empty)
			b_rd_ptr <= b_rd_ptr + 1;
	end
	assign bid_fifo_full  = b_diff[LGFIFO];
	assign bid_fifo_fill  = b_diff;
	assign bid_fifo_empty = (b_wr_ptr == b_rd_ptr);
	assign S_AXI_BID      = axi_wid;

	// err_fifo - Keep track of error returns
	// {{{
	sfifo #(.BW(1), .LGFLEN(LGFIFO))
	err_fifo(S_AXI_ACLK, !S_AXI_ARESETN,
		err_fifo_write, { ack_err || i_wb_err || err_state },
		err_fifo_full, err_fifo_fill,
		S_AXI_BVALID & S_AXI_BREADY, S_AXI_BRESP[1], err_fifo_empty);
	// }}}

	assign	S_AXI_BVALID = !bid_fifo_empty && !err_fifo_empty;
	assign	S_AXI_BRESP[0]= 1'b0;
	// }}}

	// Make Verilator happy
	// {{{
	// verilator lint_on  UNUSED
	wire	unused;
	assign	unused = &{ 1'b0, S_AXI_AWBURST, S_AXI_AWSIZE,
			S_AXI_AWLOCK, S_AXI_AWCACHE, S_AXI_AWPROT,
			S_AXI_AWQOS, S_AXI_WLAST,
			wb_ack_fifo_full, wb_ack_fifo_fill,
			bid_fifo_full, err_fifo_full,
			w_reset
			};
	// verilator lint_off UNUSED
	// }}}
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal property section
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

// }}}
endmodule
