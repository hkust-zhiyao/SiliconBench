`timescale 1ns / 1ps

module tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    integer seed = 101;
    integer err_cnt = 0;

    // =========================================================================
    // DUT A: 4x2 Crossbar, 32-bit, AGEING_LIMIT=4, HIGH_QOS_MIN=8, QOS_RESERVE=2
    //        M_AW_REG_TYPE=0, M_AR_REG_TYPE=0 (direct output stability check),
    //        M_SECURE=2'b10 (M1 secure only), M_CONNECT disables S3->M1
    // =========================================================================
    localparam SA = 4;
    localparam MA = 2;
    localparam DWA = 32;
    localparam SWA = 4;
    localparam AWA = 32;
    localparam IDSA = 4;
    localparam IDMA = IDSA + 2; // 6

    reg  [SA*IDSA-1:0]  a_s_awid;
    reg  [SA*AWA-1:0]   a_s_awaddr;
    reg  [SA*8-1:0]     a_s_awlen;
    reg  [SA*3-1:0]     a_s_awsize;
    reg  [SA*2-1:0]     a_s_awburst;
    reg  [SA-1:0]       a_s_awlock;
    reg  [SA*4-1:0]     a_s_awcache;
    reg  [SA*3-1:0]     a_s_awprot;
    reg  [SA*4-1:0]     a_s_awqos;
    reg  [SA-1:0]       a_s_awuser;
    reg  [SA-1:0]       a_s_awvalid;
    wire [SA-1:0]       a_s_awready;

    reg  [SA*DWA-1:0]   a_s_wdata;
    reg  [SA*SWA-1:0]   a_s_wstrb;
    reg  [SA-1:0]       a_s_wlast;
    reg  [SA-1:0]       a_s_wuser;
    reg  [SA-1:0]       a_s_wvalid;
    wire [SA-1:0]       a_s_wready;

    wire [SA*IDSA-1:0]  a_s_bid;
    wire [SA*2-1:0]     a_s_bresp;
    wire [SA-1:0]       a_s_buser;
    wire [SA-1:0]       a_s_bvalid;
    reg  [SA-1:0]       a_s_bready;

    reg  [SA*IDSA-1:0]  a_s_arid;
    reg  [SA*AWA-1:0]   a_s_araddr;
    reg  [SA*8-1:0]     a_s_arlen;
    reg  [SA*3-1:0]     a_s_arsize;
    reg  [SA*2-1:0]     a_s_arburst;
    reg  [SA-1:0]       a_s_arlock;
    reg  [SA*4-1:0]     a_s_arcache;
    reg  [SA*3-1:0]     a_s_arprot;
    reg  [SA*4-1:0]     a_s_arqos;
    reg  [SA-1:0]       a_s_aruser;
    reg  [SA-1:0]       a_s_arvalid;
    wire [SA-1:0]       a_s_arready;

    wire [SA*IDSA-1:0]  a_s_rid;
    wire [SA*DWA-1:0]   a_s_rdata;
    wire [SA*2-1:0]     a_s_rresp;
    wire [SA-1:0]       a_s_rlast;
    wire [SA-1:0]       a_s_ruser;
    wire [SA-1:0]       a_s_rvalid;
    reg  [SA-1:0]       a_s_rready;

    wire [MA*IDMA-1:0]  a_m_awid;
    wire [MA*AWA-1:0]   a_m_awaddr;
    wire [MA*8-1:0]     a_m_awlen;
    wire [MA*3-1:0]     a_m_awsize;
    wire [MA*2-1:0]     a_m_awburst;
    wire [MA-1:0]       a_m_awlock;
    wire [MA*4-1:0]     a_m_awcache;
    wire [MA*3-1:0]     a_m_awprot;
    wire [MA*4-1:0]     a_m_awqos;
    wire [MA*4-1:0]     a_m_awregion;
    wire [MA-1:0]       a_m_awuser;
    wire [MA-1:0]       a_m_awvalid;
    reg  [MA-1:0]       a_m_awready;

    wire [MA*DWA-1:0]   a_m_wdata;
    wire [MA*SWA-1:0]   a_m_wstrb;
    wire [MA-1:0]       a_m_wlast;
    wire [MA-1:0]       a_m_wuser;
    wire [MA-1:0]       a_m_wvalid;
    reg  [MA-1:0]       a_m_wready;

    reg  [MA*IDMA-1:0]  a_m_bid;
    reg  [MA*2-1:0]     a_m_bresp;
    reg  [MA-1:0]       a_m_buser;
    reg  [MA-1:0]       a_m_bvalid;
    wire [MA-1:0]       a_m_bready;

    wire [MA*IDMA-1:0]  a_m_arid;
    wire [MA*AWA-1:0]   a_m_araddr;
    wire [MA*8-1:0]     a_m_arlen;
    wire [MA*3-1:0]     a_m_arsize;
    wire [MA*2-1:0]     a_m_arburst;
    wire [MA-1:0]       a_m_arlock;
    wire [MA*4-1:0]     a_m_arcache;
    wire [MA*3-1:0]     a_m_arprot;
    wire [MA*4-1:0]     a_m_arqos;
    wire [MA*4-1:0]     a_m_arregion;
    wire [MA-1:0]       a_m_aruser;
    wire [MA-1:0]       a_m_arvalid;
    reg  [MA-1:0]       a_m_arready;

    reg  [MA*IDMA-1:0]  a_m_rid;
    reg  [MA*DWA-1:0]   a_m_rdata;
    reg  [MA*2-1:0]     a_m_rresp;
    reg  [MA-1:0]       a_m_rlast;
    reg  [MA-1:0]       a_m_ruser;
    reg  [MA-1:0]       a_m_rvalid;
    wire [MA-1:0]       a_m_rready;

    axi_crossbar #(
        .S_COUNT(SA),
        .M_COUNT(MA),
        .DATA_WIDTH(DWA),
        .ADDR_WIDTH(AWA),
        .STRB_WIDTH(SWA),
        .S_ID_WIDTH(IDSA),
        .M_ID_WIDTH(IDMA),
        .S_THREADS({SA{32'd2}}),
        .S_ACCEPT({SA{32'd6}}),
        .AGEING_LIMIT(32'd4),
        .HIGH_QOS_MIN(4'd8),
        .QOS_RESERVE(32'd2),
        .M_REGIONS(1),
        .M_BASE_ADDR({32'h0100_0000, 32'h0000_0000}),
        .M_ADDR_WIDTH({32'd16, 32'd16}),
        .M_CONNECT_READ(8'b0111_1111),
        .M_CONNECT_WRITE(8'b0111_1111),
        .M_ISSUE({MA{32'd16}}),
        .M_SECURE(2'b10),
        .S_AW_REG_TYPE({SA{2'd0}}),
        .S_W_REG_TYPE({SA{2'd0}}),
        .S_B_REG_TYPE({SA{2'd1}}),
        .S_AR_REG_TYPE({SA{2'd0}}),
        .S_R_REG_TYPE({SA{2'd2}}),
        .M_AW_REG_TYPE({MA{2'd0}}),
        .M_W_REG_TYPE({MA{2'd2}}),
        .M_B_REG_TYPE({MA{2'd0}}),
        .M_AR_REG_TYPE({MA{2'd0}}),
        .M_R_REG_TYPE({MA{2'd0}})
    ) dut_a (
        .clk(clk),
        .rst(rst),
        .s_axi_awid(a_s_awid),
        .s_axi_awaddr(a_s_awaddr),
        .s_axi_awlen(a_s_awlen),
        .s_axi_awsize(a_s_awsize),
        .s_axi_awburst(a_s_awburst),
        .s_axi_awlock(a_s_awlock),
        .s_axi_awcache(a_s_awcache),
        .s_axi_awprot(a_s_awprot),
        .s_axi_awqos(a_s_awqos),
        .s_axi_awuser(a_s_awuser),
        .s_axi_awvalid(a_s_awvalid),
        .s_axi_awready(a_s_awready),
        .s_axi_wdata(a_s_wdata),
        .s_axi_wstrb(a_s_wstrb),
        .s_axi_wlast(a_s_wlast),
        .s_axi_wuser(a_s_wuser),
        .s_axi_wvalid(a_s_wvalid),
        .s_axi_wready(a_s_wready),
        .s_axi_bid(a_s_bid),
        .s_axi_bresp(a_s_bresp),
        .s_axi_buser(a_s_buser),
        .s_axi_bvalid(a_s_bvalid),
        .s_axi_bready(a_s_bready),
        .s_axi_arid(a_s_arid),
        .s_axi_araddr(a_s_araddr),
        .s_axi_arlen(a_s_arlen),
        .s_axi_arsize(a_s_arsize),
        .s_axi_arburst(a_s_arburst),
        .s_axi_arlock(a_s_arlock),
        .s_axi_arcache(a_s_arcache),
        .s_axi_arprot(a_s_arprot),
        .s_axi_arqos(a_s_arqos),
        .s_axi_aruser(a_s_aruser),
        .s_axi_arvalid(a_s_arvalid),
        .s_axi_arready(a_s_arready),
        .s_axi_rid(a_s_rid),
        .s_axi_rdata(a_s_rdata),
        .s_axi_rresp(a_s_rresp),
        .s_axi_rlast(a_s_rlast),
        .s_axi_ruser(a_s_ruser),
        .s_axi_rvalid(a_s_rvalid),
        .s_axi_rready(a_s_rready),
        .m_axi_awid(a_m_awid),
        .m_axi_awaddr(a_m_awaddr),
        .m_axi_awlen(a_m_awlen),
        .m_axi_awsize(a_m_awsize),
        .m_axi_awburst(a_m_awburst),
        .m_axi_awlock(a_m_awlock),
        .m_axi_awcache(a_m_awcache),
        .m_axi_awprot(a_m_awprot),
        .m_axi_awqos(a_m_awqos),
        .m_axi_awregion(a_m_awregion),
        .m_axi_awuser(a_m_awuser),
        .m_axi_awvalid(a_m_awvalid),
        .m_axi_awready(a_m_awready),
        .m_axi_wdata(a_m_wdata),
        .m_axi_wstrb(a_m_wstrb),
        .m_axi_wlast(a_m_wlast),
        .m_axi_wuser(a_m_wuser),
        .m_axi_wvalid(a_m_wvalid),
        .m_axi_wready(a_m_wready),
        .m_axi_bid(a_m_bid),
        .m_axi_bresp(a_m_bresp),
        .m_axi_buser(a_m_buser),
        .m_axi_bvalid(a_m_bvalid),
        .m_axi_bready(a_m_bready),
        .m_axi_arid(a_m_arid),
        .m_axi_araddr(a_m_araddr),
        .m_axi_arlen(a_m_arlen),
        .m_axi_arsize(a_m_arsize),
        .m_axi_arburst(a_m_arburst),
        .m_axi_arlock(a_m_arlock),
        .m_axi_arcache(a_m_arcache),
        .m_axi_arprot(a_m_arprot),
        .m_axi_arqos(a_m_arqos),
        .m_axi_arregion(a_m_arregion),
        .m_axi_aruser(a_m_aruser),
        .m_axi_arvalid(a_m_arvalid),
        .m_axi_arready(a_m_arready),
        .m_axi_rid(a_m_rid),
        .m_axi_rdata(a_m_rdata),
        .m_axi_rresp(a_m_rresp),
        .m_axi_rlast(a_m_rlast),
        .m_axi_ruser(a_m_ruser),
        .m_axi_rvalid(a_m_rvalid),
        .m_axi_rready(a_m_rready)
    );

    // =========================================================================
    // DUT B: 4x2 Crossbar with AGEING_LIMIT=0 (Strict QoS, ageing disabled)
    //        and input skid buffers enabled (S_AR_REG_TYPE=2, M_AR_REG_TYPE=0)
    // =========================================================================
    reg  [SA*IDSA-1:0]  b_s_arid;
    reg  [SA*AWA-1:0]   b_s_araddr;
    reg  [SA*8-1:0]     b_s_arlen;
    reg  [SA*4-1:0]     b_s_arqos;
    reg  [SA-1:0]       b_s_arvalid;
    wire [SA-1:0]       b_s_arready;
    wire [SA*IDSA-1:0]  b_s_rid;
    wire [SA*DWA-1:0]   b_s_rdata;
    wire [SA*2-1:0]     b_s_rresp;
    wire [SA-1:0]       b_s_rlast;
    wire [SA-1:0]       b_s_rvalid;
    reg  [SA-1:0]       b_s_rready;

    wire [MA*IDMA-1:0]  b_m_arid;
    wire [MA*AWA-1:0]   b_m_araddr;
    wire [MA*8-1:0]     b_m_arlen;
    wire [MA*4-1:0]     b_m_arqos;
    wire [MA-1:0]       b_m_arvalid;
    reg  [MA-1:0]       b_m_arready;
    reg  [MA*IDMA-1:0]  b_m_rid;
    reg  [MA*DWA-1:0]   b_m_rdata;
    reg  [MA*2-1:0]   b_m_rresp;
    reg  [MA-1:0]       b_m_rlast;
    reg  [MA-1:0]       b_m_rvalid;
    wire [MA-1:0]       b_m_rready;

    axi_crossbar #(
        .S_COUNT(SA),
        .M_COUNT(MA),
        .DATA_WIDTH(DWA),
        .ADDR_WIDTH(AWA),
        .STRB_WIDTH(SWA),
        .S_ID_WIDTH(IDSA),
        .M_ID_WIDTH(IDMA),
        .S_THREADS({SA{32'd2}}),
        .S_ACCEPT({SA{32'd8}}),
        .AGEING_LIMIT(32'd0),
        .HIGH_QOS_MIN(4'd10),
        .QOS_RESERVE(32'd3),
        .M_REGIONS(1),
        .M_BASE_ADDR({32'h0100_0000, 32'h0000_0000}),
        .M_ADDR_WIDTH({32'd16, 32'd16}),
        .M_ISSUE({MA{32'd8}}),
        .S_AR_REG_TYPE({SA{2'd2}}),
        .M_AR_REG_TYPE({MA{2'd0}})
    ) dut_b (
        .clk(clk),
        .rst(rst),
        .s_axi_awid({SA*IDSA{1'b0}}),
        .s_axi_awaddr({SA*AWA{1'b0}}),
        .s_axi_awlen({SA*8{1'b0}}),
        .s_axi_awsize({SA{3'd2}}),
        .s_axi_awburst({SA{2'b01}}),
        .s_axi_awlock({SA{1'b0}}),
        .s_axi_awcache({SA*4{1'b0}}),
        .s_axi_awprot({SA*3{1'b0}}),
        .s_axi_awqos({SA*4{1'b0}}),
        .s_axi_awuser({SA{1'b0}}),
        .s_axi_awvalid({SA{1'b0}}),
        .s_axi_awready(),
        .s_axi_wdata({SA*DWA{1'b0}}),
        .s_axi_wstrb({SA*SWA{1'b0}}),
        .s_axi_wlast({SA{1'b0}}),
        .s_axi_wuser({SA{1'b0}}),
        .s_axi_wvalid({SA{1'b0}}),
        .s_axi_wready(),
        .s_axi_bid(),
        .s_axi_bresp(),
        .s_axi_buser(),
        .s_axi_bvalid(),
        .s_axi_bready({SA{1'b1}}),
        .s_axi_arid(b_s_arid),
        .s_axi_araddr(b_s_araddr),
        .s_axi_arlen(b_s_arlen),
        .s_axi_arsize({SA{3'd2}}),
        .s_axi_arburst({SA{2'b01}}),
        .s_axi_arlock({SA{1'b0}}),
        .s_axi_arcache({SA*4{1'b0}}),
        .s_axi_arprot({SA*3{1'b0}}),
        .s_axi_arqos(b_s_arqos),
        .s_axi_aruser({SA{1'b0}}),
        .s_axi_arvalid(b_s_arvalid),
        .s_axi_arready(b_s_arready),
        .s_axi_rid(b_s_rid),
        .s_axi_rdata(b_s_rdata),
        .s_axi_rresp(b_s_rresp),
        .s_axi_rlast(b_s_rlast),
        .s_axi_ruser(),
        .s_axi_rvalid(b_s_rvalid),
        .s_axi_rready(b_s_rready),
        .m_axi_awid(),
        .m_axi_awaddr(),
        .m_axi_awlen(),
        .m_axi_awsize(),
        .m_axi_awburst(),
        .m_axi_awlock(),
        .m_axi_awcache(),
        .m_axi_awprot(),
        .m_axi_awqos(),
        .m_axi_awregion(),
        .m_axi_awuser(),
        .m_axi_awvalid(),
        .m_axi_awready({MA{1'b1}}),
        .m_axi_wdata(),
        .m_axi_wstrb(),
        .m_axi_wlast(),
        .m_axi_wuser(),
        .m_axi_wvalid(),
        .m_axi_wready({MA{1'b1}}),
        .m_axi_bid({MA*IDMA{1'b0}}),
        .m_axi_bresp({MA*2{1'b0}}),
        .m_axi_buser({MA{1'b0}}),
        .m_axi_bvalid({MA{1'b0}}),
        .m_axi_bready(),
        .m_axi_arid(b_m_arid),
        .m_axi_araddr(b_m_araddr),
        .m_axi_arlen(b_m_arlen),
        .m_axi_arsize(),
        .m_axi_arburst(),
        .m_axi_arlock(),
        .m_axi_arcache(),
        .m_axi_arprot(),
        .m_axi_arqos(b_m_arqos),
        .m_axi_arregion(),
        .m_axi_aruser(),
        .m_axi_arvalid(b_m_arvalid),
        .m_axi_arready(b_m_arready),
        .m_axi_rid(b_m_rid),
        .m_axi_rdata(b_m_rdata),
        .m_axi_rresp(b_m_rresp),
        .m_axi_rlast(b_m_rlast),
        .m_axi_ruser({MA{1'b0}}),
        .m_axi_rvalid(b_m_rvalid),
        .m_axi_rready(b_m_rready)
    );

    // =========================================================================
    // Synchronous Posedge Sampler (100% identical across Icarus & Verilator!)
    // Procedural tasks run at @(negedge clk), inspect q_* sampled at posedge,
    // and drive next-cycle inputs via plain blocking '=' with 5ns setup/hold!
    // =========================================================================
    reg [SA-1:0]      q_a_s_awvalid, q_a_s_awready;
    reg [SA-1:0]      q_a_s_wvalid,  q_a_s_wready;
    reg [SA-1:0]      q_a_s_bvalid,  q_a_s_bready;
    reg [SA*IDSA-1:0] q_a_s_bid;
    reg [SA*2-1:0]    q_a_s_bresp;
    reg [SA-1:0]      q_a_s_arvalid, q_a_s_arready;
    reg [SA-1:0]      q_a_s_rvalid,  q_a_s_rready, q_a_s_rlast;
    reg [SA*IDSA-1:0] q_a_s_rid;
    reg [SA*DWA-1:0]  q_a_s_rdata;
    reg [SA*2-1:0]    q_a_s_rresp;

    reg [MA-1:0]      q_a_m_awvalid, q_a_m_awready;
    reg [MA*IDMA-1:0] q_a_m_awid;
    reg [MA*AWA-1:0]  q_a_m_awaddr;
    reg [MA*8-1:0]    q_a_m_awlen;
    reg [MA*4-1:0]    q_a_m_awqos;
    reg [MA-1:0]      q_a_m_wvalid,  q_a_m_wready, q_a_m_wlast;
    reg [MA*DWA-1:0]  q_a_m_wdata;
    reg [MA*SWA-1:0]  q_a_m_wstrb;
    reg [MA-1:0]      q_a_m_bvalid,  q_a_m_bready;
    reg [MA-1:0]      q_a_m_arvalid, q_a_m_arready;
    reg [MA*IDMA-1:0] q_a_m_arid;
    reg [MA*AWA-1:0]  q_a_m_araddr;
    reg [MA*8-1:0]    q_a_m_arlen;
    reg [MA*4-1:0]    q_a_m_arqos;
    reg [MA-1:0]      q_a_m_rvalid,  q_a_m_rready;

    reg [SA-1:0]      q_b_s_arvalid, q_b_s_arready;
    reg [MA-1:0]      q_b_m_arvalid, q_b_m_arready;
    reg [MA*IDMA-1:0] q_b_m_arid;
    reg [MA-1:0]      q_b_m_rvalid,  q_b_m_rready;

    integer mi;
    always @(posedge clk) begin
        if (rst) begin
            q_a_m_awvalid <= 0;
            q_a_m_wvalid  <= 0;
            q_a_m_arvalid <= 0;
        end else begin
            for (mi = 0; mi < MA; mi = mi + 1) begin
                if (q_a_m_awvalid[mi] && !q_a_m_awready[mi]) begin
                    if (!a_m_awvalid[mi] ||
                        a_m_awid[mi*IDMA +: IDMA] !== q_a_m_awid[mi*IDMA +: IDMA] ||
                        a_m_awaddr[mi*AWA +: AWA] !== q_a_m_awaddr[mi*AWA +: AWA] ||
                        a_m_awlen[mi*8 +: 8] !== q_a_m_awlen[mi*8 +: 8] ||
                        a_m_awqos[mi*4 +: 4] !== q_a_m_awqos[mi*4 +: 4]) begin
                        $display("FAIL: m_axi_aw[%0d] violated AXI4 stability while stalled!", mi);
                        err_cnt <= err_cnt + 1;
                    end
                end
                if (q_a_m_wvalid[mi] && !q_a_m_wready[mi]) begin
                    if (!a_m_wvalid[mi] ||
                        a_m_wdata[mi*DWA +: DWA] !== q_a_m_wdata[mi*DWA +: DWA] ||
                        a_m_wstrb[mi*SWA +: SWA] !== q_a_m_wstrb[mi*SWA +: SWA] ||
                        a_m_wlast[mi] !== q_a_m_wlast[mi]) begin
                        $display("FAIL: m_axi_w[%0d] violated AXI4 stability while stalled!", mi);
                        err_cnt <= err_cnt + 1;
                    end
                end
                if (q_a_m_arvalid[mi] && !q_a_m_arready[mi]) begin
                    if (!a_m_arvalid[mi] ||
                        a_m_arid[mi*IDMA +: IDMA] !== q_a_m_arid[mi*IDMA +: IDMA] ||
                        a_m_araddr[mi*AWA +: AWA] !== q_a_m_araddr[mi*AWA +: AWA] ||
                        a_m_arlen[mi*8 +: 8] !== q_a_m_arlen[mi*8 +: 8] ||
                        a_m_arqos[mi*4 +: 4] !== q_a_m_arqos[mi*4 +: 4]) begin
                        $display("FAIL: m_axi_ar[%0d] violated AXI4 stability while stalled!", mi);
                        err_cnt <= err_cnt + 1;
                    end
                end
            end
        end

        q_a_s_awvalid <= a_s_awvalid; q_a_s_awready <= a_s_awready;
        q_a_s_wvalid  <= a_s_wvalid;  q_a_s_wready  <= a_s_wready;
        q_a_s_bvalid  <= a_s_bvalid;  q_a_s_bready  <= a_s_bready;
        q_a_s_bid     <= a_s_bid;     q_a_s_bresp   <= a_s_bresp;
        q_a_s_arvalid <= a_s_arvalid; q_a_s_arready <= a_s_arready;
        q_a_s_rvalid  <= a_s_rvalid;  q_a_s_rready  <= a_s_rready;
        q_a_s_rlast   <= a_s_rlast;   q_a_s_rid     <= a_s_rid;
        q_a_s_rdata   <= a_s_rdata;   q_a_s_rresp   <= a_s_rresp;

        if (!rst) begin
            q_a_m_awvalid <= a_m_awvalid;
            q_a_m_wvalid  <= a_m_wvalid;
            q_a_m_arvalid <= a_m_arvalid;
        end
        q_a_m_awready <= a_m_awready;
        q_a_m_awid    <= a_m_awid;
        q_a_m_awaddr  <= a_m_awaddr;
        q_a_m_awlen   <= a_m_awlen;
        q_a_m_awqos   <= a_m_awqos;
        q_a_m_wready  <= a_m_wready;
        q_a_m_wdata   <= a_m_wdata;
        q_a_m_wstrb   <= a_m_wstrb;
        q_a_m_wlast   <= a_m_wlast;
        q_a_m_bvalid  <= a_m_bvalid;
        q_a_m_bready  <= a_m_bready;
        q_a_m_arready <= a_m_arready;
        q_a_m_arid    <= a_m_arid;
        q_a_m_araddr  <= a_m_araddr;
        q_a_m_arlen   <= a_m_arlen;
        q_a_m_arqos   <= a_m_arqos;
        q_a_m_rvalid  <= a_m_rvalid;
        q_a_m_rready  <= a_m_rready;

        q_b_s_arvalid <= b_s_arvalid; q_b_s_arready <= b_s_arready;
        q_b_m_arvalid <= b_m_arvalid; q_b_m_arready <= b_m_arready;
        q_b_m_arid    <= b_m_arid;
        q_b_m_rvalid  <= b_m_rvalid;  q_b_m_rready  <= b_m_rready;
    end

    integer proc_err = 0;

    task clear_inputs;
        begin
            a_s_awid = 0; a_s_awaddr = 0; a_s_awlen = 0;
            a_s_awsize = {SA{3'd2}}; a_s_awburst = {SA{2'b01}};
            a_s_awlock = 0; a_s_awcache = 0; a_s_awprot = 0;
            a_s_awqos = 0; a_s_awuser = 0; a_s_awvalid = 0;
            a_s_wdata = 0; a_s_wstrb = {SA{4'hF}}; a_s_wlast = 0;
            a_s_wuser = 0; a_s_wvalid = 0; a_s_bready = {SA{1'b1}};

            a_s_arid = 0; a_s_araddr = 0; a_s_arlen = 0;
            a_s_arsize = {SA{3'd2}}; a_s_arburst = {SA{2'b01}};
            a_s_arlock = 0; a_s_arcache = 0; a_s_arprot = 0;
            a_s_arqos = 0; a_s_aruser = 0; a_s_arvalid = 0;
            a_s_rready = {SA{1'b1}};

            a_m_awready = 0; a_m_wready = 0;
            a_m_bid = 0; a_m_bresp = 0; a_m_buser = 0; a_m_bvalid = 0;
            a_m_arready = 0;
            a_m_rid = 0; a_m_rdata = 0; a_m_rresp = 0; a_m_rlast = 0; a_m_ruser = 0; a_m_rvalid = 0;

            b_s_arid = 0; b_s_araddr = 0; b_s_arlen = 0; b_s_arqos = 0;
            b_s_arvalid = 0; b_s_rready = {SA{1'b1}};
            b_m_arready = 0; b_m_rid = 0; b_m_rdata = 0; b_m_rresp = 0; b_m_rlast = 0; b_m_rvalid = 0;
        end
    endtask

    task do_reset;
        begin
            rst = 1'b1;
            clear_inputs();
            repeat (5) @(negedge clk);
            rst = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task send_b_resp(input integer m_idx, input [IDMA-1:0] bid, input [1:0] bresp);
        integer tmo;
        begin
            a_m_bid[m_idx*IDMA +: IDMA] = bid;
            a_m_bresp[m_idx*2 +: 2] = bresp;
            a_m_bvalid[m_idx] = 1'b1;
            tmo = 0;
            @(negedge clk);
            while (!(q_a_m_bvalid[m_idx] && q_a_m_bready[m_idx]) && tmo < 80) begin
                tmo = tmo + 1;
                @(negedge clk);
            end
            if (tmo >= 80) begin
                $display("FAIL: timeout waiting for a_m_bready[%0d]", m_idx);
                proc_err = proc_err + 1;
            end
            a_m_bvalid[m_idx] = 1'b0;
        end
    endtask

    task send_r_beat(input integer m_idx, input [IDMA-1:0] rid, input [31:0] rdata, input [1:0] rresp, input rlast);
        integer tmo;
        begin
            a_m_rid[m_idx*IDMA +: IDMA] = rid;
            a_m_rdata[m_idx*32 +: 32] = rdata;
            a_m_rresp[m_idx*2 +: 2] = rresp;
            a_m_rlast[m_idx] = rlast;
            a_m_rvalid[m_idx] = 1'b1;
            tmo = 0;
            @(negedge clk);
            while (!(q_a_m_rvalid[m_idx] && q_a_m_rready[m_idx]) && tmo < 80) begin
                tmo = tmo + 1;
                @(negedge clk);
            end
            if (tmo >= 80) begin
                $display("FAIL: timeout waiting for a_m_rready[%0d]", m_idx);
                proc_err = proc_err + 1;
            end
            a_m_rvalid[m_idx] = 1'b0;
            a_m_rlast[m_idx] = 1'b0;
        end
    endtask

    // =========================================================================
    // TEST 1: Effective 4-bit QoS Priority Ordering (Read & Write) + Original QoS Forwarding
    // =========================================================================
    task test_qos_ordering;
        reg [1:0] rd_order [0:3];
        reg [3:0] rd_qos_seen [0:3];
        reg [IDMA-1:0] rd_ids [0:3];
        reg [1:0] wr_order [0:3];
        reg [3:0] wr_qos_seen [0:3];
        reg [IDMA-1:0] wr_ids [0:3];
        reg [31:0] w_seen [0:3];
        integer cnt, wcnt, cyc, p;
        begin
            do_reset();
            for (p = 0; p < 4; p = p + 1) begin
                rd_order[p] = 0; rd_qos_seen[p] = 0; rd_ids[p] = 0;
                wr_order[p] = 0; wr_qos_seen[p] = 0; wr_ids[p] = 0; w_seen[p] = 0;
            end
            // Present 4 simultaneous AR requests to Slave 0 with QoS: S0=2, S1=13, S2=7, S3=10
            a_s_araddr  = {32'h0000_0300, 32'h0000_0200, 32'h0000_0100, 32'h0000_0000};
            a_s_arid    = {4'h3, 4'h2, 4'h1, 4'h0};
            a_s_arqos   = {4'hA, 4'h7, 4'hD, 4'h2};
            a_s_arvalid = 4'b1111;
            a_m_arready = 2'b00;

            repeat (4) @(negedge clk);
            a_m_arready[0] = 1'b1;

            cnt = 0;
            cyc = 0;
            while (cnt < 4 && cyc < 60) begin
                @(negedge clk);
                cyc = cyc + 1;
                for (p = 0; p < SA; p = p + 1) begin
                    if (q_a_s_arvalid[p] && q_a_s_arready[p]) a_s_arvalid[p] = 1'b0;
                end
                if (q_a_m_arvalid[0] && q_a_m_arready[0]) begin
                    rd_ids[cnt]      = q_a_m_arid[IDMA-1:0];
                    rd_order[cnt]    = q_a_m_arid[IDSA +: 2];
                    rd_qos_seen[cnt] = q_a_m_arqos[3:0];
                    cnt = cnt + 1;
                end
            end
            a_m_arready[0] = 1'b0;
            a_s_arvalid = 4'b0000;

            if (cnt != 4 || rd_order[0] !== 2'd1 || rd_order[1] !== 2'd3 || rd_order[2] !== 2'd2 || rd_order[3] !== 2'd0) begin
                $display("FAIL Test1 AR QoS order: cnt=%0d order=%0d,%0d,%0d,%0d (expected 1,3,2,0)",
                         cnt, rd_order[0], rd_order[1], rd_order[2], rd_order[3]);
                proc_err = proc_err + 1;
            end
            if (rd_qos_seen[0] !== 4'hD || rd_qos_seen[1] !== 4'hA || rd_qos_seen[2] !== 4'h7 || rd_qos_seen[3] !== 4'h2) begin
                $display("FAIL Test1 AR QoS forwarding: seen=%h,%h,%h,%h",
                         rd_qos_seen[0], rd_qos_seen[1], rd_qos_seen[2], rd_qos_seen[3]);
                proc_err = proc_err + 1;
            end
            for (p = 0; p < cnt; p = p + 1) begin
                send_r_beat(0, rd_ids[p], 32'hA000_0000 + p, 2'b00, 1'b1);
            end
            repeat (4) @(negedge clk);

            // Now test Write AW+W QoS ordering: S0=3, S1=6, S2=14, S3=9
            a_s_awaddr  = {32'h0000_1300, 32'h0000_1200, 32'h0000_1100, 32'h0000_1000};
            a_s_awid    = {4'h3, 4'h2, 4'h1, 4'h0};
            a_s_awqos   = {4'h9, 4'hE, 4'h6, 4'h3};
            a_s_awvalid = 4'b1111;
            a_s_wdata   = {32'hDEAD_0003, 32'hDEAD_0002, 32'hDEAD_0001, 32'hDEAD_0000};
            a_s_wlast   = 4'b1111;
            a_s_wvalid  = 4'b1111;

            repeat (4) @(negedge clk);
            a_m_awready[0] = 1'b1;
            a_m_wready[0]  = 1'b1;

            cnt = 0;
            wcnt = 0;
            cyc = 0;
            while ((cnt < 4 || wcnt < 4) && cyc < 80) begin
                @(negedge clk);
                cyc = cyc + 1;
                for (p = 0; p < SA; p = p + 1) begin
                    if (q_a_s_awvalid[p] && q_a_s_awready[p]) a_s_awvalid[p] = 1'b0;
                    if (q_a_s_wvalid[p]  && q_a_s_wready[p])  a_s_wvalid[p]  = 1'b0;
                end
                if (q_a_m_awvalid[0] && q_a_m_awready[0]) begin
                    wr_ids[cnt]      = q_a_m_awid[IDMA-1:0];
                    wr_order[cnt]    = q_a_m_awid[IDSA +: 2];
                    wr_qos_seen[cnt] = q_a_m_awqos[3:0];
                    cnt = cnt + 1;
                end
                if (q_a_m_wvalid[0] && q_a_m_wready[0]) begin
                    w_seen[wcnt] = q_a_m_wdata[31:0];
                    wcnt = wcnt + 1;
                end
            end
            a_m_awready[0] = 1'b0;
            a_m_wready[0]  = 1'b0;

            if (cnt != 4 || wr_order[0] !== 2'd2 || wr_order[1] !== 2'd3 || wr_order[2] !== 2'd1 || wr_order[3] !== 2'd0) begin
                $display("FAIL Test1 AW QoS order: cnt=%0d order=%0d,%0d,%0d,%0d (expected 2,3,1,0)",
                         cnt, wr_order[0], wr_order[1], wr_order[2], wr_order[3]);
                proc_err = proc_err + 1;
            end
            if (wcnt != 4 || w_seen[0] !== 32'hDEAD_0002 || w_seen[1] !== 32'hDEAD_0003 || w_seen[2] !== 32'hDEAD_0001 || w_seen[3] !== 32'hDEAD_0000) begin
                $display("FAIL Test1 W data alignment: %h,%h,%h,%h", w_seen[0], w_seen[1], w_seen[2], w_seen[3]);
                proc_err = proc_err + 1;
            end
            for (p = 0; p < cnt; p = p + 1) begin
                send_b_resp(0, wr_ids[p], 2'b00);
            end
            repeat (4) @(negedge clk);
        end
    endtask

    // =========================================================================
    // TEST 2: Per-QoS-Level Round-Robin Independence Under Interleaved High-QoS
    //         S0 & S2 contend at QoS=4 on dut_b (AGEING_LIMIT=0);
    //         S3 injects QoS=12 in every 2-grant window! S3 must NEVER reset S0/S2 RR!
    // =========================================================================
    task test_per_level_rr_fairness;
        integer s0_wins, s2_wins, round_i, cyc;
        reg [1:0] src0, src1;
        reg [IDMA-1:0] id0, id1;
        begin
            do_reset();
            s0_wins = 0;
            s2_wins = 0;
            id0 = 0;
            id1 = 0;

            b_s_araddr[0*32 +: 32] = 32'h0000_0100;
            b_s_arid[0*4 +: 4]     = 4'h1;
            b_s_arqos[0*4 +: 4]    = 4'h4;
            b_s_arvalid[0]         = 1'b1;

            b_s_araddr[2*32 +: 32] = 32'h0000_0200;
            b_s_arid[2*4 +: 4]     = 4'h1;
            b_s_arqos[2*4 +: 4]    = 4'h4;
            b_s_arvalid[2]         = 1'b1;

            b_s_araddr[3*32 +: 32] = 32'h0000_0300;
            b_s_arid[3*4 +: 4]     = 4'h1;
            b_s_arqos[3*4 +: 4]    = 4'hC;

            // Inject round 0's single high-QoS request on S3 before starting
            b_s_arvalid[3] = 1'b1;
            b_m_arready[0] = 1'b0;
            @(negedge clk);
            while (!(q_b_s_arvalid[3] && q_b_s_arready[3])) @(negedge clk);
            b_s_arvalid[3] = 1'b0;
            repeat (6) @(negedge clk);

            for (round_i = 0; round_i < 6; round_i = round_i + 1) begin
                if (round_i < 5) begin
                    b_s_arvalid[3] = 1'b1;
                    @(negedge clk);
                    while (!(q_b_s_arvalid[3] && q_b_s_arready[3])) @(negedge clk);
                    b_s_arvalid[3] = 1'b0;
                    repeat (6) @(negedge clk);
                end

                // Beat A: Pop 1 grant (must be S3 #round_i)
                b_m_arready[0] = 1'b1;
                cyc = 0;
                @(negedge clk);
                while (!(q_b_m_arvalid[0] && q_b_m_arready[0]) && cyc < 30) begin
                    cyc = cyc + 1;
                    @(negedge clk);
                end
                id0 = q_b_m_arid[IDMA-1:0];
                b_m_arready[0] = 1'b0;
                repeat (4) @(negedge clk);

                b_m_rid[IDMA-1:0] = id0;
                b_m_rdata[31:0]   = 32'h1234_0000 + (round_i * 4);
                b_m_rresp[1:0]    = 2'b00;
                b_m_rlast[0]      = 1'b1;
                b_m_rvalid[0]     = 1'b1;
                cyc = 0;
                @(negedge clk);
                while (!(q_b_m_rvalid[0] && q_b_m_rready[0]) && cyc < 50) begin
                    cyc = cyc + 1;
                    @(negedge clk);
                end
                b_m_rvalid[0] = 1'b0;
                b_m_rlast[0]  = 1'b0;
                repeat (4) @(negedge clk);

                // Beat B: Pop 1 grant (must alternate between S0 and S2)
                b_m_arready[0] = 1'b1;
                cyc = 0;
                @(negedge clk);
                while (!(q_b_m_arvalid[0] && q_b_m_arready[0]) && cyc < 30) begin
                    cyc = cyc + 1;
                    @(negedge clk);
                end
                id1 = q_b_m_arid[IDMA-1:0];
                b_m_arready[0] = 1'b0;
                repeat (4) @(negedge clk);

                b_m_rid[IDMA-1:0] = id1;
                b_m_rdata[31:0]   = 32'h5678_0000 + (round_i * 4);
                b_m_rresp[1:0]    = 2'b00;
                b_m_rlast[0]      = 1'b1;
                b_m_rvalid[0]     = 1'b1;
                cyc = 0;
                @(negedge clk);
                while (!(q_b_m_rvalid[0] && q_b_m_rready[0]) && cyc < 50) begin
                    cyc = cyc + 1;
                    @(negedge clk);
                end
                b_m_rvalid[0] = 1'b0;
                b_m_rlast[0]  = 1'b0;
                repeat (4) @(negedge clk);

                src0 = id0[IDSA +: 2];
                src1 = id1[IDSA +: 2];
                if (src0 !== 2'd3) begin
                    $display("FAIL Test2 round %0d: expected S3 high-QoS grant first, got S%0d", round_i, src0);
                    proc_err = proc_err + 1;
                end
                if (src1 === 2'd0) s0_wins = s0_wins + 1;
                else if (src1 === 2'd2) s2_wins = s2_wins + 1;
                else begin
                    $display("FAIL Test2 round %0d: unexpected 2nd source S%0d", round_i, src1);
                    proc_err = proc_err + 1;
                end
            end

            if (s0_wins != 3 || s2_wins != 3) begin
                $display("FAIL Test2 per-QoS RR fairness broken by high-QoS preemption: s0_wins=%0d s2_wins=%0d (expected 3 and 3)", s0_wins, s2_wins);
                proc_err = proc_err + 1;
            end
        end
    endtask

    // =========================================================================
    // TEST 3: Starvation-Bounded Ageing Promotion under Continuous QoS=15 Flood
    //         3A: Multi-beat Write bursts; 3B: AGEING_LIMIT=0 check; 3C: Read Ageing
    // =========================================================================
    task test_ageing_promotion;
        integer grants_before_s0, total_grants, cyc;
        reg s0_won;
        reg [1:0] src;
        reg [IDMA-1:0] cap_id;
        reg [3:0] cap_qos;
        reg [2:0] s_wbeat;
        begin
            // 3A: Multi-beat Write Ageing on dut_a (AGEING_LIMIT = 4)
            do_reset();
            cap_id = 0;
            a_s_awaddr[0*32 +: 32] = 32'h0000_2000;
            a_s_awid[0*4 +: 4]     = 4'h2;
            a_s_awlen[0*8 +: 8]    = 8'd1;
            a_s_awqos[0*4 +: 4]    = 4'h1;
            a_s_awvalid[0]         = 1'b1;
            a_s_wdata[0*32 +: 32]  = 32'hCAFE_0001;
            a_s_wlast[0]           = 1'b0;
            a_s_wvalid[0]          = 1'b1;

            a_s_awaddr[1*32 +: 32] = 32'h0000_2100;
            a_s_awid[1*4 +: 4]     = 4'h1;
            a_s_awlen[1*8 +: 8]    = 8'd1;
            a_s_awqos[1*4 +: 4]    = 4'hF;
            a_s_awvalid[1]         = 1'b1;
            a_s_wdata[1*32 +: 32]  = 32'h1111_0000;
            a_s_wlast[1]           = 1'b0;
            a_s_wvalid[1]          = 1'b1;

            a_s_awaddr[2*32 +: 32] = 32'h0000_2200;
            a_s_awid[2*4 +: 4]     = 4'h1;
            a_s_awlen[2*8 +: 8]    = 8'd1;
            a_s_awqos[2*4 +: 4]    = 4'hF;
            a_s_awvalid[2]         = 1'b1;
            a_s_wdata[2*32 +: 32]  = 32'h2222_0000;
            a_s_wlast[2]           = 1'b0;
            a_s_wvalid[2]          = 1'b1;

            repeat (4) @(negedge clk);
            a_m_awready[0] = 1'b1;
            a_m_wready[0]  = 1'b1;

            grants_before_s0 = 0;
            total_grants = 0;
            s0_won = 1'b0;
            cyc = 0;
            s_wbeat = 3'b000;

            while (!s0_won && total_grants < 14 && cyc < 250) begin
                @(negedge clk);
                cyc = cyc + 1;

                if (q_a_s_awvalid[0] && q_a_s_awready[0]) a_s_awvalid[0] = 1'b0;
                if (q_a_s_wvalid[0] && q_a_s_wready[0]) begin
                    if (!s_wbeat[0]) begin
                        s_wbeat[0] = 1'b1;
                        a_s_wdata[0*32 +: 32] = 32'hCAFE_0002;
                        a_s_wlast[0] = 1'b1;
                    end else begin
                        a_s_wvalid[0] = 1'b0;
                        a_s_wlast[0]  = 1'b0;
                    end
                end

                if (q_a_s_wvalid[1] && q_a_s_wready[1]) begin
                    s_wbeat[1] = ~s_wbeat[1];
                    a_s_wlast[1] = s_wbeat[1];
                end
                if (q_a_s_wvalid[2] && q_a_s_wready[2]) begin
                    s_wbeat[2] = ~s_wbeat[2];
                    a_s_wlast[2] = s_wbeat[2];
                end

                if (q_a_m_awvalid[0] && q_a_m_awready[0]) begin
                    cap_id  = q_a_m_awid[IDMA-1:0];
                    cap_qos = q_a_m_awqos[3:0];
                    src     = cap_id[IDSA +: 2];
                    total_grants = total_grants + 1;
                    if (src === 2'd0) begin
                        s0_won = 1'b1;
                        if (cap_qos !== 4'h1) begin
                            $display("FAIL Test3A: S0 promoted internally but corrupted m_axi_awqos=%h (expected 4'h1)", cap_qos);
                            proc_err = proc_err + 1;
                        end
                    end else begin
                        grants_before_s0 = grants_before_s0 + 1;
                    end
                end

                if (q_a_m_wvalid[0] && q_a_m_wready[0] && q_a_m_wlast[0]) begin
                    a_m_bid[IDMA-1:0] = cap_id;
                    a_m_bresp[1:0]    = 2'b00;
                    a_m_bvalid[0]     = 1'b1;
                end else if (q_a_m_bvalid[0] && q_a_m_bready[0]) begin
                    a_m_bvalid[0] = 1'b0;
                end
            end

            if (!s0_won) begin
                $display("FAIL Test3A: S0 low-QoS write starved under multi-beat QoS=15 flood! (grants_before_s0=%0d)", grants_before_s0);
                proc_err = proc_err + 1;
            end else if (grants_before_s0 < 3 || grants_before_s0 > 8) begin
                $display("FAIL Test3A: S0 write ageing window out of spec for AGEING_LIMIT=4: grants_before_s0=%0d (expected 4..7)", grants_before_s0);
                proc_err = proc_err + 1;
            end

            // 3B: Verify AGEING_LIMIT=0 on dut_b disables ageing promotion!
            do_reset();
            b_s_araddr[0*32 +: 32] = 32'h0000_3000;
            b_s_arid[0*4 +: 4]     = 4'h0;
            b_s_arqos[0*4 +: 4]    = 4'h1;
            b_s_arvalid[0]         = 1'b1;

            b_s_araddr[1*32 +: 32] = 32'h0000_3100;
            b_s_arid[1*4 +: 4]     = 4'h1;
            b_s_arqos[1*4 +: 4]    = 4'hF;
            b_s_arvalid[1]         = 1'b1;

            b_s_araddr[2*32 +: 32] = 32'h0000_3200;
            b_s_arid[2*4 +: 4]     = 4'h1;
            b_s_arqos[2*4 +: 4]    = 4'hF;
            b_s_arvalid[2]         = 1'b1;

            repeat (5) @(negedge clk);
            s0_won = 1'b0;
            total_grants = 0;
            cyc = 0;
            while (total_grants < 10 && cyc < 160) begin
                b_m_arready[0] = ((cyc % 4) == 3);
                @(negedge clk);
                cyc = cyc + 1;
                if (q_b_m_arvalid[0] && q_b_m_arready[0]) begin
                    cap_id = q_b_m_arid[IDMA-1:0];
                    src    = cap_id[IDSA +: 2];
                    total_grants = total_grants + 1;
                    if (src === 2'd0) s0_won = 1'b1;
                    b_m_rid[IDMA-1:0] = cap_id;
                    b_m_rdata[31:0]   = 32'h9999_0000;
                    b_m_rresp[1:0]    = 2'b00;
                    b_m_rlast[0]      = 1'b1;
                    b_m_rvalid[0]     = 1'b1;
                end else if (q_b_m_rvalid[0] && q_b_m_rready[0]) begin
                    b_m_rvalid[0] = 1'b0;
                    b_m_rlast[0]  = 1'b0;
                end
            end
            b_m_arready[0] = 1'b0;
            if (s0_won) begin
                $display("FAIL Test3B: AGEING_LIMIT=0 promoted S0 ahead of continuous QoS=15!");
                proc_err = proc_err + 1;
            end

            // 3C: Read Ageing on dut_a (AGEING_LIMIT = 4) under continuous S1+S2 QoS=15 read flood
            do_reset();
            a_s_araddr[0*32 +: 32] = 32'h0000_3400;
            a_s_arid[0*4 +: 4]     = 4'h3;
            a_s_arqos[0*4 +: 4]    = 4'h2;
            a_s_arvalid[0]         = 1'b1;

            a_s_araddr[1*32 +: 32] = 32'h0000_3500;
            a_s_arid[1*4 +: 4]     = 4'h1;
            a_s_arqos[1*4 +: 4]    = 4'hF;
            a_s_arvalid[1]         = 1'b1;

            a_s_araddr[2*32 +: 32] = 32'h0000_3600;
            a_s_arid[2*4 +: 4]     = 4'h1;
            a_s_arqos[2*4 +: 4]    = 4'hF;
            a_s_arvalid[2]         = 1'b1;

            repeat (5) @(negedge clk);
            grants_before_s0 = 0;
            total_grants = 0;
            s0_won = 1'b0;
            cyc = 0;
            while (!s0_won && total_grants < 14 && cyc < 200) begin
                a_m_arready[0] = ((cyc % 4) == 3);
                @(negedge clk);
                cyc = cyc + 1;
                if (q_a_s_arvalid[0] && q_a_s_arready[0]) a_s_arvalid[0] = 1'b0;
                if (q_a_m_arvalid[0] && q_a_m_arready[0]) begin
                    cap_id  = q_a_m_arid[IDMA-1:0];
                    cap_qos = q_a_m_arqos[3:0];
                    src     = cap_id[IDSA +: 2];
                    total_grants = total_grants + 1;
                    if (src === 2'd0) begin
                        s0_won = 1'b1;
                        if (cap_qos !== 4'h2) begin
                            $display("FAIL Test3C: S0 read promoted internally but corrupted m_axi_arqos=%h", cap_qos);
                            proc_err = proc_err + 1;
                        end
                    end else begin
                        grants_before_s0 = grants_before_s0 + 1;
                    end
                    a_m_rid[IDMA-1:0] = cap_id;
                    a_m_rdata[31:0]   = 32'h7777_0000;
                    a_m_rresp[1:0]    = 2'b00;
                    a_m_rlast[0]      = 1'b1;
                    a_m_rvalid[0]     = 1'b1;
                end else if (q_a_m_rvalid[0] && q_a_m_rready[0]) begin
                    a_m_rvalid[0] = 1'b0;
                    a_m_rlast[0]  = 1'b0;
                end
            end
            a_m_arready[0] = 1'b0;
            if (!s0_won || grants_before_s0 < 3 || grants_before_s0 > 8) begin
                $display("FAIL Test3C: S0 read ageing failed (s0_won=%0d grants_before_s0=%0d)", s0_won, grants_before_s0);
                proc_err = proc_err + 1;
            end
        end
    endtask

    // =========================================================================
    // TEST 4: High-QoS Reserve Admission (S_ACCEPT=6, QOS_RESERVE=2, HIGH_QOS_MIN=8)
    //         + Same-Cycle Completion Watermark Check!
    // =========================================================================
    task test_qos_reserve_admission;
        integer i_tx, cyc;
        begin
            do_reset();
            a_m_arready[0] = 1'b1;

            // Step 1: Issue 4 normal-QoS (QoS=5 < 8) reads on S0
            for (i_tx = 0; i_tx < 4; i_tx = i_tx + 1) begin
                a_s_arid[0*4 +: 4]     = 4'h1;
                a_s_araddr[0*32 +: 32] = 32'h0000_4000 + (i_tx * 16);
                a_s_arqos[0*4 +: 4]    = 4'h5;
                a_s_arvalid[0]         = 1'b1;
                cyc = 0;
                @(negedge clk);
                while (!(q_a_s_arvalid[0] && q_a_s_arready[0]) && cyc < 30) begin
                    cyc = cyc + 1;
                    @(negedge clk);
                end
                if (cyc >= 30) begin
                    $display("FAIL Test4: Normal-QoS tx %0d (< 4) prematurely blocked!", i_tx);
                    proc_err = proc_err + 1;
                end
                a_s_arvalid[0] = 1'b0;
                @(negedge clk);
            end

            // Step 2: 5th normal-QoS (QoS=7 < 8) on S0 must block at in_flight=4!
            a_s_arid[0*4 +: 4]     = 4'h1;
            a_s_araddr[0*32 +: 32] = 32'h0000_4100;
            a_s_arqos[0*4 +: 4]    = 4'h7;
            a_s_arvalid[0]         = 1'b1;
            for (cyc = 0; cyc < 10; cyc = cyc + 1) begin
                @(negedge clk);
                if (q_a_s_arready[0] || q_a_m_arvalid[0]) begin
                    $display("FAIL Test4: 5th normal-QoS (QoS=7 < 8) admitted into reserved pool at in_flight=4!");
                    proc_err = proc_err + 1;
                end
            end

            // Step 3: On S1 (fresh port), fill 4 normal-QoS (QoS=3), then admit 2 high-QoS (QoS=8 and QoS=14) up to S_ACCEPT=6!
            for (i_tx = 0; i_tx < 6; i_tx = i_tx + 1) begin
                a_s_arid[1*4 +: 4]     = 4'h2;
                a_s_araddr[1*32 +: 32] = 32'h0000_5000 + (i_tx * 16);
                a_s_arqos[1*4 +: 4]    = (i_tx < 4) ? 4'h3 : ((i_tx == 4) ? 4'h8 : 4'hE);
                a_s_arvalid[1]         = 1'b1;
                cyc = 0;
                @(negedge clk);
                while (!(q_a_s_arvalid[1] && q_a_s_arready[1]) && cyc < 30) begin
                    cyc = cyc + 1;
                    @(negedge clk);
                end
                if (cyc >= 30) begin
                    $display("FAIL Test4: S1 tx %0d (QoS=%0d) failed to admit within S_ACCEPT=6!", i_tx, a_s_arqos[1*4 +: 4]);
                    proc_err = proc_err + 1;
                end
                a_s_arvalid[1] = 1'b0;
                @(negedge clk);
            end

            // Step 4: Verify 7th high-QoS (QoS=15) on S1 blocks at hard S_ACCEPT=6!
            a_s_arid[1*4 +: 4]     = 4'h2;
            a_s_araddr[1*32 +: 32] = 32'h0000_5200;
            a_s_arqos[1*4 +: 4]    = 4'hF;
            a_s_arvalid[1]         = 1'b1;
            for (cyc = 0; cyc < 8; cyc = cyc + 1) begin
                @(negedge clk);
                if (q_a_s_arready[1]) begin
                    $display("FAIL Test4: 7th high-QoS exceeded S_ACCEPT=6!");
                    proc_err = proc_err + 1;
                end
            end
            // Retire 1 transaction on S1 (6 -> 5) so the 7th high-QoS finishes cleanly
            send_r_beat(0, {2'd1, 4'h2}, 32'hCAFE_5000, 2'b00, 1'b1);
            cyc = 0;
            while (!(q_a_s_arvalid[1] && q_a_s_arready[1]) && cyc < 30) begin
                cyc = cyc + 1;
                @(negedge clk);
            end
            a_s_arvalid[1] = 1'b0;
            @(negedge clk);

            // Step 5: SAME-CYCLE COMPLETION WATERMARK TRAP on S1!
            // S1 currently has 6 in-flight again! Present a normal-QoS (QoS=4 < 8) request on S1.
            a_s_arid[1*4 +: 4]     = 4'h2;
            a_s_araddr[1*32 +: 32] = 32'h0000_5300;
            a_s_arqos[1*4 +: 4]    = 4'h4;
            a_s_arvalid[1]         = 1'b1;
            repeat (3) @(negedge clk);

            // Retire 1st on S1 (in_flight: 6 -> 5, STILL >= NORM_ACCEPT=4!). S1 MUST NOT admit normal-QoS!
            send_r_beat(0, {2'd1, 4'h2}, 32'hCAFE_5001, 2'b00, 1'b1);
            for (cyc = 0; cyc < 6; cyc = cyc + 1) begin
                if (q_a_s_arready[1]) begin
                    $display("FAIL Test4: Same-cycle completion trap! Normal-QoS admitted when in_flight dropped 6->5 (still >= 4)!");
                    proc_err = proc_err + 1;
                end
                @(negedge clk);
            end

            // Retire 2nd on S1 (in_flight: 5 -> 4, STILL >= NORM_ACCEPT=4!). S1 MUST STILL NOT admit normal-QoS!
            send_r_beat(0, {2'd1, 4'h2}, 32'hCAFE_5002, 2'b00, 1'b1);
            for (cyc = 0; cyc < 6; cyc = cyc + 1) begin
                if (q_a_s_arready[1]) begin
                    $display("FAIL Test4: Same-cycle completion trap! Normal-QoS admitted when in_flight dropped 5->4 (still >= 4)!");
                    proc_err = proc_err + 1;
                end
                @(negedge clk);
            end

            // Retire 3rd on S1 (in_flight: 4 -> 3 < NORM_ACCEPT=4!). NOW S1 MUST admit!
            send_r_beat(0, {2'd1, 4'h2}, 32'hCAFE_5003, 2'b00, 1'b1);
            cyc = 0;
            while (!(q_a_s_arvalid[1] && q_a_s_arready[1]) && cyc < 30) begin
                cyc = cyc + 1;
                @(negedge clk);
            end
            if (cyc >= 30) begin
                $display("FAIL Test4: Normal-QoS failed to unblock after in_flight dropped to 3 (< 4)!");
                proc_err = proc_err + 1;
            end
            a_s_arvalid[1] = 1'b0;

            // Also retire 1 on S0 (4 -> 3) and verify S0's paused 5th normal-QoS unblocks!
            send_r_beat(0, {2'd0, 4'h1}, 32'hCAFE_4000, 2'b00, 1'b1);
            cyc = 0;
            while (!(q_a_s_arvalid[0] && q_a_s_arready[0]) && cyc < 30) begin
                cyc = cyc + 1;
                @(negedge clk);
            end
            if (cyc >= 30) begin
                $display("FAIL Test4: S0 paused normal-QoS failed to unblock!");
                proc_err = proc_err + 1;
            end
            a_s_arvalid[0] = 1'b0;
        end
    endtask

    // =========================================================================
    // TEST 5: Mid-Stall AW/W Preemption Hazard (m_axi_awready=0, m_axi_wready=1)
    // =========================================================================
    task test_mid_stall_aw_w_alignment;
        integer cyc;
        reg [31:0] first_addr, second_addr, first_w, second_w;
        reg got_w1;
        begin
            do_reset();
            first_addr  = 32'd0;
            second_addr = 32'd0;
            first_w     = 32'd0;
            second_w    = 32'd0;
            a_m_awready[0] = 1'b0;
            a_m_wready[0]  = 1'b1;

            a_s_awaddr[0*32 +: 32] = 32'h0000_6000;
            a_s_awid[0*4 +: 4]     = 4'h1;
            a_s_awqos[0*4 +: 4]    = 4'h1;
            a_s_awvalid[0]         = 1'b1;
            a_s_wdata[0*32 +: 32]  = 32'hAAAA_1111;
            a_s_wlast[0]           = 1'b1;
            a_s_wvalid[0]          = 1'b1;

            got_w1 = 1'b0;
            cyc = 0;
            while (!q_a_m_awvalid[0] && cyc < 20) begin
                @(negedge clk);
                if (q_a_m_wvalid[0] && q_a_m_wready[0]) begin
                    first_w = q_a_m_wdata[31:0];
                    got_w1  = 1'b1;
                end
                if (q_a_s_wvalid[0] && q_a_s_wready[0]) a_s_wvalid[0] = 1'b0;
                cyc = cyc + 1;
            end

            // While a_m_awvalid[0] is stalled, S1 arrives with QoS=15!
            a_s_awaddr[1*32 +: 32] = 32'h0000_6100;
            a_s_awid[1*4 +: 4]     = 4'h2;
            a_s_awqos[1*4 +: 4]    = 4'hF;
            a_s_awvalid[1]         = 1'b1;
            a_s_wdata[1*32 +: 32]  = 32'hBBBB_2222;
            a_s_wlast[1]           = 1'b1;
            a_s_wvalid[1]          = 1'b1;

            for (cyc = 0; cyc < 5; cyc = cyc + 1) begin
                @(negedge clk);
                if (q_a_m_wvalid[0] && q_a_m_wready[0] && !got_w1) begin
                    first_w = q_a_m_wdata[31:0];
                    got_w1  = 1'b1;
                end
                if (q_a_s_wvalid[0] && q_a_s_wready[0]) a_s_wvalid[0] = 1'b0;
                if (q_a_s_wvalid[1] && q_a_s_wready[1]) a_s_wvalid[1] = 1'b0;
            end

            a_m_awready[0] = 1'b1;
            for (cyc = 0; cyc < 20; cyc = cyc + 1) begin
                @(negedge clk);
                if (q_a_s_awvalid[0] && q_a_s_awready[0]) a_s_awvalid[0] = 1'b0;
                if (q_a_s_awvalid[1] && q_a_s_awready[1]) a_s_awvalid[1] = 1'b0;
                if (q_a_s_wvalid[0]  && q_a_s_wready[0])  a_s_wvalid[0]  = 1'b0;
                if (q_a_s_wvalid[1]  && q_a_s_wready[1])  a_s_wvalid[1]  = 1'b0;
                if (q_a_m_awvalid[0] && q_a_m_awready[0]) begin
                    if (first_addr === 32'd0) first_addr = q_a_m_awaddr[31:0];
                    else second_addr = q_a_m_awaddr[31:0];
                end
                if (q_a_m_wvalid[0] && q_a_m_wready[0]) begin
                    if (!got_w1) begin first_w = q_a_m_wdata[31:0]; got_w1 = 1'b1; end
                    else second_w = q_a_m_wdata[31:0];
                end
            end
            if (first_addr !== 32'h0000_6000 || first_w !== 32'hAAAA_1111 ||
                second_addr !== 32'h0000_6100 || second_w !== 32'hBBBB_2222) begin
                $display("FAIL Test5 AW/W pair corruption: 1st=(%h,%h) 2nd=(%h,%h)",
                         first_addr, first_w, second_addr, second_w);
                proc_err = proc_err + 1;
            end
        end
    endtask

    // =========================================================================
    // TEST 6: DECERR Underflow Immunity + Multi-Beat Read/Write DECERR + Same-ID Ordering
    // =========================================================================
    task test_decerr_and_same_id_ordering;
        integer cyc, rbeats, i_tx, resp_cnt;
        reg [1:0] first_resp, second_resp;
        reg [IDMA-1:0] slow_id;
        begin
            do_reset();
            first_resp  = 2'b00;
            second_resp = 2'b00;
            slow_id     = 0;

            // 6A: Unmapped 3-beat write (0x8000_0000) when trans_count == 0
            a_s_awaddr[0*32 +: 32] = 32'h8000_0000;
            a_s_awid[0*4 +: 4]     = 4'h7;
            a_s_awlen[0*8 +: 8]    = 8'd2;
            a_s_awqos[0*4 +: 4]    = 4'h2;
            a_s_awvalid[0]         = 1'b1;
            a_s_wdata[0*32 +: 32]  = 32'hDEAD_BEEF;
            a_s_wlast[0]           = 1'b0;
            a_s_wvalid[0]          = 1'b1;

            cyc = 0;
            i_tx = 0;
            resp_cnt = 0;
            while (resp_cnt == 0 && cyc < 50) begin
                @(negedge clk);
                cyc = cyc + 1;
                if (q_a_s_awvalid[0] && q_a_s_awready[0]) a_s_awvalid[0] = 1'b0;
                if (q_a_s_wvalid[0] && q_a_s_wready[0]) begin
                    i_tx = i_tx + 1;
                    if (i_tx == 2) a_s_wlast[0] = 1'b1;
                    if (i_tx == 3) begin a_s_wvalid[0] = 1'b0; a_s_wlast[0] = 1'b0; end
                end
                if (q_a_m_awvalid != 0 || q_a_m_wvalid != 0) begin
                    $display("FAIL Test6A: DECERR write leaked onto m_axi!");
                    proc_err = proc_err + 1;
                end
                if (q_a_s_bvalid[0] && q_a_s_bready[0]) begin
                    if (q_a_s_bresp[1:0] !== 2'b11 || q_a_s_bid[3:0] !== 4'h7) begin
                        $display("FAIL Test6A: wrong DECERR BRESP=%b BID=%h", q_a_s_bresp[1:0], q_a_s_bid[3:0]);
                        proc_err = proc_err + 1;
                    end
                    resp_cnt = 1;
                end
            end
            if (resp_cnt == 0) begin
                $display("FAIL Test6A: timeout on DECERR write BRESP!");
                proc_err = proc_err + 1;
            end

            // Non-secure 4-beat read to M1 (M_SECURE[1]=1 -> must DECERR!)
            a_s_araddr[0*32 +: 32] = 32'h0100_0040;
            a_s_arprot[0*3 +: 3]   = 3'b010;
            a_s_arid[0*4 +: 4]     = 4'h9;
            a_s_arlen[0*8 +: 8]    = 8'd3;
            a_s_arvalid[0]         = 1'b1;
            rbeats = 0;
            cyc = 0;
            while (rbeats < 4 && cyc < 50) begin
                @(negedge clk);
                cyc = cyc + 1;
                if (q_a_s_arvalid[0] && q_a_s_arready[0]) a_s_arvalid[0] = 1'b0;
                if (q_a_s_rvalid[0] && q_a_s_rready[0]) begin
                    rbeats = rbeats + 1;
                    if (q_a_s_rresp[1:0] !== 2'b11 || q_a_s_rid[3:0] !== 4'h9 || q_a_s_rlast[0] !== (rbeats == 4)) begin
                        $display("FAIL Test6A: DECERR read beat %0d rresp=%b rid=%h rlast=%b",
                                 rbeats, q_a_s_rresp[1:0], q_a_s_rid[3:0], q_a_s_rlast[0]);
                        proc_err = proc_err + 1;
                    end
                end
            end
            a_s_arprot = 0;
            a_s_arlen  = 0;

            // Verify S0 did NOT underflow trans_count_reg by issuing a mapped read!
            a_m_arready[0] = 1'b1;
            a_s_araddr[0*32 +: 32] = 32'h0000_0010;
            a_s_arid[0*4 +: 4]     = 4'h2;
            a_s_arqos[0*4 +: 4]    = 4'h4;
            a_s_arvalid[0]         = 1'b1;
            cyc = 0;
            while (!(q_a_m_arvalid[0] && q_a_m_arready[0]) && cyc < 30) begin
                @(negedge clk);
                if (q_a_s_arvalid[0] && q_a_s_arready[0]) a_s_arvalid[0] = 1'b0;
                cyc = cyc + 1;
            end
            if (cyc >= 30) begin
                $display("FAIL Test6A: Mapped transaction hung after DECERR (trans_count_reg underflow)!");
                proc_err = proc_err + 1;
                a_s_arvalid[0] = 1'b0;
            end else begin
                slow_id = q_a_m_arid[IDMA-1:0];
                @(negedge clk);
                a_s_arvalid[0] = 1'b0;
                send_r_beat(0, slow_id, 32'h1122_3344, 2'b00, 1'b1);
            end
            repeat (4) @(negedge clk);

            // 6B: Same-ID ordering: Slow mapped read (ID=3) followed by unmapped DECERR read (ID=3)!
            a_s_araddr[0*32 +: 32] = 32'h0000_0020;
            a_s_arid[0*4 +: 4]     = 4'h3;
            a_s_arqos[0*4 +: 4]    = 4'h5;
            a_s_arvalid[0]         = 1'b1;
            cyc = 0;
            while (!(q_a_m_arvalid[0] && q_a_m_arready[0]) && cyc < 30) begin
                @(negedge clk);
                if (q_a_s_arvalid[0] && q_a_s_arready[0]) a_s_arvalid[0] = 1'b0;
                cyc = cyc + 1;
            end
            slow_id = q_a_m_arid[IDMA-1:0];
            cyc = 0;
            while (a_s_arvalid[0] && cyc < 30) begin
                @(negedge clk);
                if (q_a_s_arready[0]) a_s_arvalid[0] = 1'b0;
                cyc = cyc + 1;
            end
            a_s_arvalid[0] = 1'b0;

            @(negedge clk);
            a_s_araddr[0*32 +: 32] = 32'hF000_0000;
            a_s_arid[0*4 +: 4]     = 4'h3;
            a_s_arvalid[0]         = 1'b1;
            resp_cnt = 0;
            for (cyc = 0; cyc < 10; cyc = cyc + 1) begin
                @(negedge clk);
                if (q_a_s_arvalid[0] && q_a_s_arready[0]) a_s_arvalid[0] = 1'b0;
                if (q_a_s_rvalid[0] && q_a_s_rready[0]) begin
                    first_resp = q_a_s_rresp[1:0];
                    resp_cnt = resp_cnt + 1;
                end
            end

            a_m_rid[IDMA-1:0] = slow_id;
            a_m_rdata[31:0]   = 32'h5566_7788;
            a_m_rresp[1:0]    = 2'b00;
            a_m_rlast[0]      = 1'b1;
            a_m_rvalid[0]     = 1'b1;
            cyc = 0;
            while (resp_cnt < 2 && cyc < 40) begin
                @(negedge clk);
                cyc = cyc + 1;
                if (q_a_m_rvalid[0] && q_a_m_rready[0]) begin
                    a_m_rvalid[0] = 1'b0;
                    a_m_rlast[0]  = 1'b0;
                end
                if (q_a_s_arvalid[0] && q_a_s_arready[0]) a_s_arvalid[0] = 1'b0;
                if (q_a_s_rvalid[0] && q_a_s_rready[0]) begin
                    if (resp_cnt == 0) first_resp = q_a_s_rresp[1:0];
                    else second_resp = q_a_s_rresp[1:0];
                    resp_cnt = resp_cnt + 1;
                end
            end
            a_m_rvalid[0]  = 1'b0;
            a_m_rlast[0]   = 1'b0;
            a_s_arvalid[0] = 1'b0;
            if (resp_cnt != 2 || first_resp !== 2'b00 || second_resp !== 2'b11) begin
                $display("FAIL Test6B: Same-ID mapped->DECERR out-of-order! resp_cnt=%0d 1st=%b 2nd=%b (expected 00 then 11)",
                         resp_cnt, first_resp, second_resp);
                proc_err = proc_err + 1;
            end
        end
    endtask

    // =========================================================================
    // TEST 7: Seeded Randomized Multi-Master Read/Write Stress with Scoreboard
    // =========================================================================
    task test_random_stress;
        reg [31:0] mem [0:511];
        integer step, p, m;
        reg [31:0] rng;
        reg [IDMA-1:0] bq_id [0:1][0:31];
        integer bq_h [0:1], bq_t [0:1];
        reg [IDMA-1:0] rq_id [0:1][0:31];
        reg [31:0]     rq_addr [0:1][0:31];
        integer rq_h [0:1], rq_t [0:1];

        reg [IDMA-1:0] awq_id [0:1][0:31];
        reg [31:0]     awq_addr [0:1][0:31];
        integer awq_h [0:1], awq_t [0:1];
        reg [31:0]     wq_data [0:1][0:31];
        integer wq_h [0:1], wq_t [0:1];

        integer tx_done;
        begin
            do_reset();
            rng = seed ^ 32'h9E37_79B9;
            for (step = 0; step < 512; step = step + 1) mem[step] = 32'h1000_0000 ^ step;
            for (m = 0; m < 2; m = m + 1) begin
                bq_h[m] = 0; bq_t[m] = 0;
                rq_h[m] = 0; rq_t[m] = 0;
                awq_h[m] = 0; awq_t[m] = 0;
                wq_h[m] = 0; wq_t[m] = 0;
            end
            tx_done = 0;

            for (step = 0; step < 400; step = step + 1) begin
                rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]} + 32'h1357_9BDF;
                if (step < 260) begin
                    a_m_awready = rng[1:0] | 2'b01;
                    a_m_wready  = rng[3:2] | 2'b01;
                    a_m_arready = rng[5:4] | 2'b01;
                    a_s_bready  = (rng[9:6] == 4'h0) ? 4'b0101 : 4'b1111;
                    a_s_rready  = (rng[13:10] == 4'h0) ? 4'b1010 : 4'b1111;

                    for (p = 0; p < SA; p = p + 1) begin
                        rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
                        if (!a_s_arvalid[p] && rng[0]) begin
                            a_s_arid[p*4 +: 4]     = rng[3:2];
                            a_s_araddr[p*32 +: 32] = ((rng[4] && p != 3) ? 32'h0100_0000 : 32'h0000_0000) | ({23'd0, p[1:0], rng[10:6]} << 2);
                            a_s_arprot[p*3 +: 3]   = 3'b000;
                            a_s_arqos[p*4 +: 4]    = rng[15:12];
                            a_s_arvalid[p]         = 1'b1;
                        end
                        if (!a_s_awvalid[p] && !a_s_wvalid[p] && rng[1]) begin
                            a_s_awid[p*4 +: 4]     = rng[18:17];
                            a_s_awaddr[p*32 +: 32] = ((rng[19] && p != 3) ? 32'h0100_0000 : 32'h0000_0000) | ({23'd0, p[1:0], rng[25:21]} << 2);
                            a_s_awprot[p*3 +: 3]   = 3'b000;
                            a_s_awqos[p*4 +: 4]    = rng[30:27];
                            a_s_awvalid[p]         = 1'b1;
                            a_s_wdata[p*32 +: 32]  = 32'hA500_0000 | (p << 16) | step[15:0];
                            a_s_wstrb[p*4 +: 4]    = 4'hF;
                            a_s_wlast[p]           = 1'b1;
                            a_s_wvalid[p]          = 1'b1;
                        end
                    end
                end else begin
                    a_m_awready = 2'b11;
                    a_m_wready  = 2'b11;
                    a_m_arready = 2'b11;
                    a_s_bready  = 4'b1111;
                    a_s_rready  = 4'b1111;
                end

                @(negedge clk);

                for (p = 0; p < SA; p = p + 1) begin
                    if (q_a_s_arvalid[p] && q_a_s_arready[p]) a_s_arvalid[p] = 1'b0;
                    if (q_a_s_awvalid[p] && q_a_s_awready[p]) a_s_awvalid[p] = 1'b0;
                    if (q_a_s_wvalid[p]  && q_a_s_wready[p])  begin a_s_wvalid[p] = 1'b0; a_s_wlast[p] = 1'b0; end
                    if (q_a_s_bvalid[p]  && q_a_s_bready[p])  begin
                        if (q_a_s_bresp[p*2 +: 2] !== 2'b00) begin
                            $display("FAIL Test7: unexpected BRESP=%b on S%0d", q_a_s_bresp[p*2 +: 2], p);
                            proc_err = proc_err + 1;
                        end
                        tx_done = tx_done + 1;
                    end
                    if (q_a_s_rvalid[p] && q_a_s_rready[p]) begin
                        if (q_a_s_rresp[p*2 +: 2] !== 2'b00) begin
                            $display("FAIL Test7: unexpected RRESP=%b on S%0d", q_a_s_rresp[p*2 +: 2], p);
                            proc_err = proc_err + 1;
                        end
                        tx_done = tx_done + 1;
                    end
                end

                for (m = 0; m < 2; m = m + 1) begin
                    if (q_a_m_awvalid[m] && q_a_m_awready[m]) begin
                        awq_id[m][awq_t[m] % 32]   = q_a_m_awid[m*IDMA +: IDMA];
                        awq_addr[m][awq_t[m] % 32] = q_a_m_awaddr[m*32 +: 32];
                        awq_t[m] = awq_t[m] + 1;
                    end
                    if (q_a_m_wvalid[m] && q_a_m_wready[m]) begin
                        wq_data[m][wq_t[m] % 32] = q_a_m_wdata[m*32 +: 32];
                        wq_t[m] = wq_t[m] + 1;
                    end
                    if (awq_h[m] < awq_t[m] && wq_h[m] < wq_t[m]) begin
                        mem[(m * 256) + ((awq_addr[m][awq_h[m] % 32] >> 2) & 8'hFF)] = wq_data[m][wq_h[m] % 32];
                        bq_id[m][bq_t[m] % 32] = awq_id[m][awq_h[m] % 32];
                        bq_t[m] = bq_t[m] + 1;
                        awq_h[m] = awq_h[m] + 1;
                        wq_h[m] = wq_h[m] + 1;
                    end
                    if (q_a_m_arvalid[m] && q_a_m_arready[m]) begin
                        rq_id[m][rq_t[m] % 32]   = q_a_m_arid[m*IDMA +: IDMA];
                        rq_addr[m][rq_t[m] % 32] = q_a_m_araddr[m*32 +: 32];
                        rq_t[m] = rq_t[m] + 1;
                    end

                    if (q_a_m_bvalid[m] && q_a_m_bready[m]) begin
                        a_m_bvalid[m] = 1'b0;
                    end
                    if (!a_m_bvalid[m] && (bq_h[m] < bq_t[m])) begin
                        a_m_bid[m*IDMA +: IDMA] = bq_id[m][bq_h[m] % 32];
                        a_m_bresp[m*2 +: 2]     = 2'b00;
                        a_m_bvalid[m]           = 1'b1;
                        bq_h[m] = bq_h[m] + 1;
                    end

                    if (q_a_m_rvalid[m] && q_a_m_rready[m]) begin
                        a_m_rvalid[m] = 1'b0;
                        a_m_rlast[m]  = 1'b0;
                    end
                    if (!a_m_rvalid[m] && (rq_h[m] < rq_t[m])) begin
                        a_m_rid[m*IDMA +: IDMA] = rq_id[m][rq_h[m] % 32];
                        a_m_rdata[m*32 +: 32]   = mem[(m * 256) + ((rq_addr[m][rq_h[m] % 32] >> 2) & 8'hFF)];
                        a_m_rresp[m*2 +: 2]     = 2'b00;
                        a_m_rlast[m]            = 1'b1;
                        a_m_rvalid[m]           = 1'b1;
                        rq_h[m] = rq_h[m] + 1;
                    end
                end
            end

            if (a_s_arvalid != 0 || a_s_awvalid != 0 || a_s_wvalid != 0 || tx_done < 80) begin
                $display("FAIL Test7: stress drain incomplete! arvalid=%b awvalid=%b wvalid=%b tx_done=%0d",
                         a_s_arvalid, a_s_awvalid, a_s_wvalid, tx_done);
                proc_err = proc_err + 1;
            end
        end
    endtask

    initial begin
        #500000;
        $display("FAIL: global watchdog timeout!");
        $finish;
    end

    initial begin
        if ($value$plusargs("seed=%d", seed)) begin end
        test_qos_ordering();
        test_per_level_rr_fairness();
        test_ageing_promotion();
        test_qos_reserve_admission();
        test_mid_stall_aw_w_alignment();
        test_decerr_and_same_id_ordering();
        test_random_stress();

        if ((err_cnt + proc_err) == 0) begin
            $display("PASS seed=%0d", seed);
            $finish;
        end else begin
            $display("FAIL seed=%0d errors=%0d", seed, err_cnt + proc_err);
            $finish;
        end
    end

endmodule
