`timescale 1ns / 1ps

module tb #(
    parameter int SEED = 1
);
    logic i_clk = 1'b0;
    logic i_reset = 1'b1;
    always #5 i_clk = ~i_clk;

    // Subsystem A: wbm2axisp
    logic        wb_up_cyc = 1'b0;
    logic        wb_up_stb = 1'b0;
    logic        wb_up_we  = 1'b0;
    logic [13:0] wb_up_addr = 14'd0;
    logic [31:0] wb_up_data = 32'd0;
    logic [3:0]  wb_up_sel  = 4'hF;
    wire         wb_up_stall;
    wire         wb_up_ack;
    wire  [31:0] wb_up_rdata;
    wire         wb_up_err;

    wire         m_axi_awvalid;
    logic        m_axi_awready = 1'b1;
    wire  [5:0]  m_axi_awid;
    wire  [15:0] m_axi_awaddr;
    wire         m_axi_wvalid;
    logic        m_axi_wready = 1'b1;
    wire  [63:0] m_axi_wdata;
    wire  [7:0]  m_axi_wstrb;
    wire         m_axi_wlast;
    logic        m_axi_bvalid = 1'b0;
    wire         m_axi_bready;
    logic [5:0]  m_axi_bid = 6'h05;
    logic [1:0]  m_axi_bresp = 2'b00;
    wire         m_axi_arvalid;
    logic        m_axi_arready = 1'b1;
    wire  [5:0]  m_axi_arid;
    wire  [15:0] m_axi_araddr;
    logic        m_axi_rvalid = 1'b0;
    wire         m_axi_rready;
    logic [5:0]  m_axi_rid = 6'h1A;
    logic [63:0] m_axi_rdata = 64'd0;
    logic [1:0]  m_axi_rresp = 2'b00;
    logic        m_axi_rlast = 1'b1;

    // Subsystem B: axim2wbsp (aximwr2wbsp + aximrd2wbsp)
    logic        s_axi_awvalid = 1'b0;
    wire         s_axi_awready;
    logic [5:0]  s_axi_awid = 6'd0;
    logic [15:0] s_axi_awaddr = 16'd0;
    logic [7:0]  s_axi_awlen = 8'd0;
    logic [2:0]  s_axi_awsize = 3'd2;
    logic [1:0]  s_axi_awburst = 2'b01;
    logic        s_axi_wvalid = 1'b0;
    wire         s_axi_wready;
    logic [31:0] s_axi_wdata = 32'd0;
    logic [3:0]  s_axi_wstrb = 4'hF;
    logic        s_axi_wlast = 1'b0;
    wire         s_axi_bvalid;
    logic        s_axi_bready = 1'b1;
    wire  [5:0]  s_axi_bid;
    wire  [1:0]  s_axi_bresp;

    logic        s_axi_arvalid = 1'b0;
    wire         s_axi_arready;
    logic [5:0]  s_axi_arid = 6'd0;
    logic [15:0] s_axi_araddr = 16'd0;
    logic [7:0]  s_axi_arlen = 8'd0;
    logic [2:0]  s_axi_arsize = 3'd2;
    logic [1:0]  s_axi_arburst = 2'b01;
    wire         s_axi_rvalid;
    logic        s_axi_rready = 1'b1;
    wire  [5:0]  s_axi_rid;
    wire  [31:0] s_axi_rdata;
    wire         s_axi_rlast;
    wire  [1:0]  s_axi_rresp;

    wire         wb_dn_cyc;
    wire         wb_dn_stb;
    wire         wb_dn_we;
    wire  [13:0] wb_dn_addr;
    wire  [31:0] wb_dn_wdata;
    wire  [3:0]  wb_dn_sel;
    logic        wb_dn_stall = 1'b0;
    logic        wb_dn_ack = 1'b0;
    logic [31:0] wb_dn_rdata = 32'd0;
    logic        wb_dn_err = 1'b0;

    wb2axip_bridge_top #(
        .C_AXI_ID_WIDTH  (6),
        .C_AXI_ADDR_WIDTH(16),
        .LGFIFO          (3)
    ) dut (
        .i_clk        (i_clk),
        .i_reset      (i_reset),
        .wb_up_cyc    (wb_up_cyc),
        .wb_up_stb    (wb_up_stb),
        .wb_up_we     (wb_up_we),
        .wb_up_addr   (wb_up_addr),
        .wb_up_data   (wb_up_data),
        .wb_up_sel    (wb_up_sel),
        .wb_up_stall  (wb_up_stall),
        .wb_up_ack    (wb_up_ack),
        .wb_up_rdata  (wb_up_rdata),
        .wb_up_err    (wb_up_err),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_awid   (m_axi_awid),
        .m_axi_awaddr (m_axi_awaddr),
        .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready),
        .m_axi_wdata  (m_axi_wdata),
        .m_axi_wstrb  (m_axi_wstrb),
        .m_axi_wlast  (m_axi_wlast),
        .m_axi_bvalid (m_axi_bvalid),
        .m_axi_bready (m_axi_bready),
        .m_axi_bid    (m_axi_bid),
        .m_axi_bresp  (m_axi_bresp),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_arid   (m_axi_arid),
        .m_axi_araddr (m_axi_araddr),
        .m_axi_rvalid (m_axi_rvalid),
        .m_axi_rready (m_axi_rready),
        .m_axi_rid    (m_axi_rid),
        .m_axi_rdata  (m_axi_rdata),
        .m_axi_rresp  (m_axi_rresp),
        .m_axi_rlast  (m_axi_rlast),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_awid   (s_axi_awid),
        .s_axi_awaddr (s_axi_awaddr),
        .s_axi_awlen  (s_axi_awlen),
        .s_axi_awsize (s_axi_awsize),
        .s_axi_awburst(s_axi_awburst),
        .s_axi_wvalid (s_axi_wvalid),
        .s_axi_wready (s_axi_wready),
        .s_axi_wdata  (s_axi_wdata),
        .s_axi_wstrb  (s_axi_wstrb),
        .s_axi_wlast  (s_axi_wlast),
        .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),
        .s_axi_bid    (s_axi_bid),
        .s_axi_bresp  (s_axi_bresp),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_arid   (s_axi_arid),
        .s_axi_araddr (s_axi_araddr),
        .s_axi_arlen  (s_axi_arlen),
        .s_axi_arsize (s_axi_arsize),
        .s_axi_arburst(s_axi_arburst),
        .s_axi_rvalid (s_axi_rvalid),
        .s_axi_rready (s_axi_rready),
        .s_axi_rid    (s_axi_rid),
        .s_axi_rdata  (s_axi_rdata),
        .s_axi_rlast  (s_axi_rlast),
        .s_axi_rresp  (s_axi_rresp),
        .wb_dn_cyc    (wb_dn_cyc),
        .wb_dn_stb    (wb_dn_stb),
        .wb_dn_we     (wb_dn_we),
        .wb_dn_addr   (wb_dn_addr),
        .wb_dn_wdata  (wb_dn_wdata),
        .wb_dn_sel    (wb_dn_sel),
        .wb_dn_stall  (wb_dn_stall),
        .wb_dn_ack    (wb_dn_ack),
        .wb_dn_rdata  (wb_dn_rdata),
        .wb_dn_err    (wb_dn_err)
    );

    // Track downstream Wishbone strobe requests automatically
    int wb_wr_stb_cnt = 0;
    int wb_rd_stb_cnt = 0;
    always @(posedge i_clk) begin
        if (i_reset) begin
            wb_wr_stb_cnt <= 0;
            wb_rd_stb_cnt <= 0;
        end else if (wb_dn_cyc && wb_dn_stb && !wb_dn_stall) begin
            if (wb_dn_we) wb_wr_stb_cnt <= wb_wr_stb_cnt + 1;
            else          wb_rd_stb_cnt <= wb_rd_stb_cnt + 1;
        end
    end

    initial begin
        i_reset = 1'b1;
        repeat (5) @(negedge i_clk);
        i_reset = 1'b0;
        @(negedge i_clk);

        // =====================================================================
        // Test 1: wbm2axisp 32-to-64 write strobe shifting, read lane extraction,
        //         direction lock, and flush recovery on SLVERR & mid-flight abort
        // =====================================================================
        wb_up_cyc  = 1'b1;
        wb_up_stb  = 1'b1;
        wb_up_we   = 1'b1;
        wb_up_addr = 14'h0010;
        wb_up_data = 32'h11223344;
        wb_up_sel  = 4'b1010;
        @(posedge i_clk);
        while (wb_up_stall) @(posedge i_clk);
        #1;
        if (!m_axi_awvalid || !m_axi_wvalid || m_axi_wstrb !== 8'b0000_1010 || m_axi_wdata[31:0] !== 32'h11223344) begin
            $display("FATAL: wbm2axisp even write strobe/data mismatch: wstrb=%08b", m_axi_wstrb);
            $finish(1);
        end
        @(negedge i_clk);
        wb_up_addr = 14'h0011;
        wb_up_data = 32'hAABBCCDD;
        wb_up_sel  = 4'b0101;
        @(posedge i_clk);
        while (wb_up_stall) @(posedge i_clk);
        #1;
        if (!m_axi_awvalid || !m_axi_wvalid || m_axi_wstrb !== 8'b0101_0000 || m_axi_wdata[63:32] !== 32'hAABBCCDD) begin
            $display("FATAL: wbm2axisp odd write strobe/data mismatch: wstrb=%08b", m_axi_wstrb);
            $finish(1);
        end
        // While 2 writes are in flight (npending=2), a read request MUST be blocked!
        @(negedge i_clk);
        wb_up_we   = 1'b0;
        wb_up_addr = 14'h0020;
        @(posedge i_clk);
        @(negedge i_clk);
        if (m_axi_arvalid) begin
            $display("FATAL: wbm2axisp issued ARVALID while write responses were still pending");
            $finish(1);
        end
        wb_up_stb = 1'b0;
        // Return 2 BVALID responses: first OKAY, second SLVERR!
        m_axi_bvalid = 1'b1;
        m_axi_bresp  = 2'b00;
        @(posedge i_clk);
        #1;
        if (wb_up_ack !== 1'b1 || wb_up_err !== 1'b0) begin
            $display("FATAL: wbm2axisp did not assert wb_up_ack on first BVALID");
            $finish(1);
        end
        @(negedge i_clk);
        m_axi_bresp = 2'b10;
        @(posedge i_clk);
        #1;
        if (wb_up_err !== 1'b1 || wb_up_ack !== 1'b0) begin
            $display("FATAL: wbm2axisp did not assert wb_up_err on SLVERR BVALID");
            $finish(1);
        end
        @(negedge i_clk);
        m_axi_bvalid = 1'b0;
        wb_up_cyc    = 1'b0;
        repeat (2) @(negedge i_clk);

        // 1b. Issue 2 pipelined Wishbone reads (even and odd sub-word offset)
        wb_up_cyc  = 1'b1;
        wb_up_stb  = 1'b1;
        wb_up_we   = 1'b0;
        wb_up_addr = 14'h0030;
        @(posedge i_clk);
        while (wb_up_stall) @(posedge i_clk);
        @(negedge i_clk);
        wb_up_addr = 14'h0031;
        @(posedge i_clk);
        while (wb_up_stall) @(posedge i_clk);
        @(negedge i_clk);
        wb_up_stb  = 1'b0;

        m_axi_rvalid = 1'b1;
        m_axi_rdata  = (SEED == 1) ? 64'hCAFEBABE_12345678 : 64'h87654321_FEDCBA98;
        m_axi_rresp  = 2'b00;
        @(posedge i_clk);
        #1;
        if (wb_up_ack !== 1'b1 || wb_up_rdata !== ((SEED == 1) ? 32'h12345678 : 32'hFEDCBA98)) begin
            $display("FATAL: wbm2axisp even read data mismatch: got=%08x", wb_up_rdata);
            $finish(1);
        end
        @(posedge i_clk);
        #1;
        if (wb_up_ack !== 1'b1 || wb_up_rdata !== ((SEED == 1) ? 32'hCAFEBABE : 32'h87654321)) begin
            $display("FATAL: wbm2axisp odd read data mismatch: got=%08x", wb_up_rdata);
            $finish(1);
        end
        @(negedge i_clk);
        m_axi_rvalid = 1'b0;
        wb_up_cyc    = 1'b0;
        @(negedge i_clk);

        // 1c. Mid-flight Wishbone abort (drop wb_up_cyc while 1 read is outstanding)
        wb_up_cyc  = 1'b1;
        wb_up_stb  = 1'b1;
        wb_up_we   = 1'b0;
        wb_up_addr = 14'h0040;
        @(posedge i_clk);
        while (wb_up_stall) @(posedge i_clk);
        @(negedge i_clk);
        wb_up_cyc  = 1'b0; // Abort!
        wb_up_stb  = 1'b0;
        @(posedge i_clk); // flushing becomes 1 here
        @(negedge i_clk);
        wb_up_cyc  = 1'b1;
        wb_up_stb  = 1'b1;
        wb_up_addr = 14'h0041;
        @(posedge i_clk);
        #1;
        if (wb_up_stall !== 1'b1 || m_axi_arvalid !== 1'b0) begin
            $display("FATAL: wbm2axisp did not stall/block new request while flushing abandoned read: stall=%b arvalid=%b", wb_up_stall, m_axi_arvalid);
            $finish(1);
        end
        @(negedge i_clk);
        wb_up_cyc    = 1'b0;
        wb_up_stb    = 1'b0;
        m_axi_rvalid = 1'b1;
        m_axi_rresp  = 2'b00;
        @(posedge i_clk);
        #1;
        if (wb_up_ack !== 1'b0) begin
            $display("FATAL: wbm2axisp leaked wb_up_ack for flushed read");
            $finish(1);
        end
        @(negedge i_clk);
        m_axi_rvalid = 1'b0;
        wb_up_cyc    = 1'b0;
        repeat (2) @(negedge i_clk);

        // =====================================================================
        // Test 2: aximwr2wbsp burst write, ID ordering lock, and i_wb_err abort
        // =====================================================================
        // 2a. Start a 2-beat write burst with AWID=6'h12 (AWLEN=1)
        s_axi_awvalid = 1'b1;
        s_axi_awid    = 6'h12;
        s_axi_awaddr  = 16'h0100;
        s_axi_awlen   = 8'd1;
        s_axi_wvalid  = 1'b1;
        s_axi_wdata   = 32'hA0A0_0001;
        s_axi_wstrb   = 4'hF;
        s_axi_wlast   = 1'b0;
        begin : wait_2a
            bit aw_done, w0_done;
            aw_done = 0; w0_done = 0;
            while (!aw_done || !w0_done) begin
                @(posedge i_clk);
                if (s_axi_awvalid && s_axi_awready) aw_done = 1;
                if (s_axi_wvalid  && s_axi_wready)  w0_done = 1;
                @(negedge i_clk);
                if (aw_done) s_axi_awvalid = 1'b0;
                if (w0_done) begin
                    s_axi_wdata = 32'hA0A0_0002;
                    s_axi_wlast = 1'b1;
                end
            end
        end
        @(posedge i_clk);
        while (!s_axi_wready) @(posedge i_clk);
        @(negedge i_clk);
        s_axi_wvalid  = 1'b0;
        s_axi_wlast   = 1'b0;

        // Wait until both Wishbone write strobes have been issued on wb_dn_*
        while (wb_wr_stb_cnt < 2) @(posedge i_clk);

        // Now pulse wb_dn_ack twice for the 2-beat write burst
        repeat (2) begin
            @(negedge i_clk);
            wb_dn_ack = 1'b1;
            @(posedge i_clk);
            @(negedge i_clk);
            wb_dn_ack = 1'b0;
        end

        while (!s_axi_bvalid) begin @(posedge i_clk); #1; end
        if (s_axi_bid !== 6'h12 || s_axi_bresp !== 2'b00) begin
            $display("FATAL: aximwr2wbsp first burst BVALID mismatch: bid=%02x bresp=%02b", s_axi_bid, s_axi_bresp);
            $finish(1);
        end
        @(posedge i_clk);

        // 2b. Second write burst (2 beats, AWLEN=1) with AWID=6'h25 that faults with wb_dn_err!
        @(negedge i_clk);
        s_axi_awvalid = 1'b1;
        s_axi_awid    = 6'h25;
        s_axi_awaddr  = 16'h0200;
        s_axi_awlen   = 8'd1;
        s_axi_wvalid  = 1'b1;
        s_axi_wdata   = 32'hB0B0_0001;
        s_axi_wlast   = 1'b0;
        begin : wait_2b
            bit aw_done, w0_done;
            aw_done = 0; w0_done = 0;
            while (!aw_done || !w0_done) begin
                @(posedge i_clk);
                if (s_axi_awvalid && s_axi_awready) aw_done = 1;
                if (s_axi_wvalid  && s_axi_wready)  w0_done = 1;
                @(negedge i_clk);
                if (aw_done) s_axi_awvalid = 1'b0;
                if (w0_done) begin
                    s_axi_wdata = 32'hB0B0_0002;
                    s_axi_wlast = 1'b1;
                end
            end
        end
        @(posedge i_clk);
        while (!s_axi_wready) @(posedge i_clk);
        @(negedge i_clk);
        s_axi_wvalid  = 1'b0;
        s_axi_wlast   = 1'b0;

        while (wb_wr_stb_cnt < 4) @(posedge i_clk);
        @(negedge i_clk);
        wb_dn_err = 1'b1;
        @(posedge i_clk);
        @(negedge i_clk);
        wb_dn_err = 1'b0;
        #1;
        if (wb_dn_cyc !== 1'b0 || wb_dn_stb !== 1'b0) begin
            $display("FATAL: aximwr2wbsp did not drop wb_dn_cyc/stb after wb_dn_err");
            $finish(1);
        end
        while (!s_axi_bvalid) begin @(posedge i_clk); #1; end
        if (s_axi_bid !== 6'h25 || s_axi_bresp !== 2'b10) begin
            $display("FATAL: aximwr2wbsp faulted burst BVALID mismatch: bid=%02x bresp=%02b", s_axi_bid, s_axi_bresp);
            $finish(1);
        end
        @(posedge i_clk);

        // =====================================================================
        // Test 3: aximrd2wbsp burst read, ID ordering lock, and i_wb_err abort
        // =====================================================================
        @(negedge i_clk);
        s_axi_arvalid = 1'b1;
        s_axi_arid    = 6'h33;
        s_axi_araddr  = 16'h0400;
        s_axi_arlen   = 8'd2; // 3-beat read burst
        @(posedge i_clk);
        while (!s_axi_arready) @(posedge i_clk);
        @(negedge i_clk);
        s_axi_arvalid = 1'b0;

        s_axi_rready = 1'b0;
        // Wait until at least 2 read strobes have been issued
        while (wb_rd_stb_cnt < 2) @(posedge i_clk);

        // Beat 0: normal Wishbone ACK
        @(negedge i_clk);
        wb_dn_ack   = 1'b1;
        wb_dn_rdata = 32'hD000_0001;
        @(posedge i_clk);
        @(negedge i_clk);
        wb_dn_ack   = 1'b0;

        // Beat 1: Wishbone Bus Error (`wb_dn_err = 1`)!
        wb_dn_err   = 1'b1;
        @(posedge i_clk);
        @(negedge i_clk);
        wb_dn_err   = 1'b0;
        #1;
        if (wb_dn_cyc !== 1'b0 || wb_dn_stb !== 1'b0) begin
            $display("FATAL: aximrd2wbsp did not drop wb_dn_cyc/stb after wb_dn_err");
            $finish(1);
        end

        // Now assert s_axi_rready=1 and collect all 3 read beats on S_AXI_R*
        s_axi_rready = 1'b1;
        for (int rbeat = 0; rbeat < 3; rbeat++) begin
            #1;
            while (!s_axi_rvalid) begin @(posedge i_clk); #1; end
            if (s_axi_rid !== 6'h33 || s_axi_rlast !== (rbeat == 2)) begin
                $display("FATAL: aximrd2wbsp read beat %0d RID/RLAST mismatch: rid=%02x rlast=%b",
                         rbeat, s_axi_rid, s_axi_rlast);
                $finish(1);
            end
            if (rbeat == 0) begin
                if (s_axi_rresp !== 2'b00 || s_axi_rdata !== 32'hD000_0001) begin
                    $display("FATAL: aximrd2wbsp beat 0 data/rresp mismatch");
                    $finish(1);
                end
            end else begin
                if (s_axi_rresp !== 2'b10) begin
                    $display("FATAL: aximrd2wbsp beat %0d did not return SLVERR (2'b10) after wb_dn_err: got=%02b",
                             rbeat, s_axi_rresp);
                    $finish(1);
                end
            end
            @(posedge i_clk);
        end

        // 3b. Verify clean recovery on a subsequent 2-beat read burst with new ARID=6'h09
        @(negedge i_clk);
        s_axi_arvalid = 1'b1;
        s_axi_arid    = 6'h09;
        s_axi_araddr  = 16'h0500;
        s_axi_arlen   = 8'd1;
        @(posedge i_clk);
        while (!s_axi_arready) @(posedge i_clk);
        @(negedge i_clk);
        s_axi_arvalid = 1'b0;

        s_axi_rready = 1'b0;
        while (wb_rd_stb_cnt < 4) @(posedge i_clk);
        for (int rbeat = 0; rbeat < 2; rbeat++) begin
            @(negedge i_clk);
            wb_dn_ack   = 1'b1;
            wb_dn_rdata = 32'hE000_0010 + rbeat;
            @(posedge i_clk);
            @(negedge i_clk);
            wb_dn_ack   = 1'b0;
        end
        s_axi_rready = 1'b1;
        for (int rbeat = 0; rbeat < 2; rbeat++) begin
            #1;
            while (!s_axi_rvalid) begin @(posedge i_clk); #1; end
            if (s_axi_rid !== 6'h09 || s_axi_rresp !== 2'b00 || s_axi_rdata !== (32'hE000_0010 + rbeat) || s_axi_rlast !== (rbeat == 1)) begin
                $display("FATAL: aximrd2wbsp recovery burst beat %0d mismatch", rbeat);
                $finish(1);
            end
            @(posedge i_clk);
            #1;
        end

        $display("PASS_CASE_0103 seed=%0d", SEED);
        $finish(0);
    end

    initial begin
        #10000;
        $display("FATAL: watchdog timeout at t=%0t", $time);
        $finish(1);
    end
endmodule
