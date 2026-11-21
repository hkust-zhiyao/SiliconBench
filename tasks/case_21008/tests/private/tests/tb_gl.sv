`timescale 1ns / 1ps

// Post-Synthesis Gate-Level vs RTL Cycle-Accurate Parity Harness
module gl_pair_checker #(
    parameter IS_UPSIZE    = 1,
    parameter S_DATA_WIDTH = (IS_UPSIZE ? 32 : 128),
    parameter M_DATA_WIDTH = (IS_UPSIZE ? 128 : 32)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] seed_in,
    output integer     errs
);
    localparam ADDR_WIDTH   = 32;
    localparam S_STRB_WIDTH = S_DATA_WIDTH / 8;
    localparam M_STRB_WIDTH = M_DATA_WIDTH / 8;
    localparam ID_WIDTH     = 8;
    localparam AWUSER_W     = 3;
    localparam WUSER_W      = 4;
    localparam BUSER_W      = 3;
    localparam ARUSER_W     = 3;
    localparam RUSER_W      = 4;

    reg  [ID_WIDTH-1:0]     s_awid = 0, s_arid = 0;
    reg  [ADDR_WIDTH-1:0]   s_awaddr = 0, s_araddr = 0;
    reg  [7:0]              s_awlen = 0, s_arlen = 0;
    reg  [2:0]              s_awsize = 0, s_arsize = 0, s_awprot = 0, s_arprot = 0;
    reg  [1:0]              s_awburst = 0, s_arburst = 0;
    reg                     s_awlock = 0, s_arlock = 0, s_awvalid = 0, s_wlast = 0, s_wvalid = 0;
    reg                     s_bready = 1, s_arvalid = 0, s_rready = 1;
    reg  [3:0]              s_awcache = 0, s_awqos = 0, s_awregion = 0, s_arcache = 0, s_arqos = 0, s_arregion = 0;
    reg  [AWUSER_W-1:0]     s_awuser = 0;
    reg  [S_DATA_WIDTH-1:0] s_wdata = 0;
    reg  [S_STRB_WIDTH-1:0] s_wstrb = 0;
    reg  [WUSER_W-1:0]      s_wuser = 0;
    reg  [ARUSER_W-1:0]     s_aruser = 0;

    wire                    s_awready_r, s_awready_g, s_wready_r, s_wready_g;
    wire [ID_WIDTH-1:0]     s_bid_r, s_bid_g, s_rid_r, s_rid_g;
    wire [1:0]              s_bresp_r, s_bresp_g, s_rresp_r, s_rresp_g;
    wire [BUSER_W-1:0]      s_buser_r, s_buser_g;
    wire                    s_bvalid_r, s_bvalid_g, s_arready_r, s_arready_g, s_rlast_r, s_rlast_g, s_rvalid_r, s_rvalid_g;
    wire [S_DATA_WIDTH-1:0] s_rdata_r, s_rdata_g;
    wire [RUSER_W-1:0]      s_ruser_r, s_ruser_g;

    wire [ID_WIDTH-1:0]     m_awid_r, m_awid_g, m_arid_r, m_arid_g;
    wire [ADDR_WIDTH-1:0]   m_awaddr_r, m_awaddr_g, m_araddr_r, m_araddr_g;
    wire [7:0]              m_awlen_r, m_awlen_g, m_arlen_r, m_arlen_g;
    wire [2:0]              m_awsize_r, m_awsize_g, m_arsize_r, m_arsize_g;
    wire [1:0]              m_awburst_r, m_awburst_g, m_arburst_r, m_arburst_g;
    wire                    m_awlock_r, m_awlock_g, m_arlock_r, m_arlock_g;
    wire [3:0]              m_awcache_r, m_awcache_g, m_awqos_r, m_awqos_g, m_awregion_r, m_awregion_g;
    wire [3:0]              m_arcache_r, m_arcache_g, m_arqos_r, m_arqos_g, m_arregion_r, m_arregion_g;
    wire [2:0]              m_awprot_r, m_awprot_g, m_arprot_r, m_arprot_g;
    wire [AWUSER_W-1:0]     m_awuser_r, m_awuser_g;
    wire                    m_awvalid_r, m_awvalid_g, m_wlast_r, m_wlast_g, m_wvalid_r, m_wvalid_g;
    wire [M_DATA_WIDTH-1:0] m_wdata_r, m_wdata_g;
    wire [M_STRB_WIDTH-1:0] m_wstrb_r, m_wstrb_g;
    wire [WUSER_W-1:0]      m_wuser_r, m_wuser_g;
    wire                    m_bready_r, m_bready_g, m_arvalid_r, m_arvalid_g, m_rready_r, m_rready_g;
    wire [ARUSER_W-1:0]     m_aruser_r, m_aruser_g;

    wire                    m_awready, m_wready, m_bvalid, m_arready, m_rlast, m_rvalid;
    wire [ID_WIDTH-1:0]     m_bid, m_rid;
    wire [1:0]              m_bresp, m_rresp;
    wire [BUSER_W-1:0]      m_buser;
    wire [M_DATA_WIDTH-1:0] m_rdata;
    wire [RUSER_W-1:0]      m_ruser;
    integer                 mem_errs, aw_cnt, ar_cnt;

    axi_adapter #(
        .ADDR_WIDTH(ADDR_WIDTH), .S_DATA_WIDTH(S_DATA_WIDTH), .M_DATA_WIDTH(M_DATA_WIDTH), .ID_WIDTH(ID_WIDTH),
        .AWUSER_ENABLE(1), .AWUSER_WIDTH(AWUSER_W), .WUSER_ENABLE(1), .WUSER_WIDTH(WUSER_W),
        .BUSER_ENABLE(1), .BUSER_WIDTH(BUSER_W), .ARUSER_ENABLE(1), .ARUSER_WIDTH(ARUSER_W),
        .RUSER_ENABLE(1), .RUSER_WIDTH(RUSER_W), .CONVERT_BURST(1), .CONVERT_NARROW_BURST(1), .FORWARD_ID(1)
    ) u_rtl (
        .clk(clk), .rst(rst),
        .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize),
        .s_axi_awburst(s_awburst), .s_axi_awlock(s_awlock), .s_axi_awcache(s_awcache), .s_axi_awprot(s_awprot),
        .s_axi_awqos(s_awqos), .s_axi_awregion(s_awregion), .s_axi_awuser(s_awuser),
        .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready_r),
        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast), .s_axi_wuser(s_wuser),
        .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready_r),
        .s_axi_bid(s_bid_r), .s_axi_bresp(s_bresp_r), .s_axi_buser(s_buser_r),
        .s_axi_bvalid(s_bvalid_r), .s_axi_bready(s_bready),
        .s_axi_arid(s_arid), .s_axi_araddr(s_araddr), .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize),
        .s_axi_arburst(s_arburst), .s_axi_arlock(s_arlock), .s_axi_arcache(s_arcache), .s_axi_arprot(s_arprot),
        .s_axi_arqos(s_arqos), .s_axi_arregion(s_arregion), .s_axi_aruser(s_aruser),
        .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready_r),
        .s_axi_rid(s_rid_r), .s_axi_rdata(s_rdata_r), .s_axi_rresp(s_rresp_r), .s_axi_rlast(s_rlast_r),
        .s_axi_ruser(s_ruser_r), .s_axi_rvalid(s_rvalid_r), .s_axi_rready(s_rready),
        .m_axi_awid(m_awid_r), .m_axi_awaddr(m_awaddr_r), .m_axi_awlen(m_awlen_r), .m_axi_awsize(m_awsize_r),
        .m_axi_awburst(m_awburst_r), .m_axi_awlock(m_awlock_r), .m_axi_awcache(m_awcache_r), .m_axi_awprot(m_awprot_r),
        .m_axi_awqos(m_awqos_r), .m_axi_awregion(m_awregion_r), .m_axi_awuser(m_awuser_r),
        .m_axi_awvalid(m_awvalid_r), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata_r), .m_axi_wstrb(m_wstrb_r), .m_axi_wlast(m_wlast_r), .m_axi_wuser(m_wuser_r),
        .m_axi_wvalid(m_wvalid_r), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_buser(m_buser),
        .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready_r),
        .m_axi_arid(m_arid_r), .m_axi_araddr(m_araddr_r), .m_axi_arlen(m_arlen_r), .m_axi_arsize(m_arsize_r),
        .m_axi_arburst(m_arburst_r), .m_axi_arlock(m_arlock_r), .m_axi_arcache(m_arcache_r), .m_axi_arprot(m_arprot_r),
        .m_axi_arqos(m_arqos_r), .m_axi_arregion(m_arregion_r), .m_axi_aruser(m_aruser_r),
        .m_axi_arvalid(m_arvalid_r), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_ruser(m_ruser), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready_r)
    );

    generate
    if (IS_UPSIZE) begin : g_gl_up
        axi_adapter_gl_up u_gl (
            .clk(clk), .rst(rst),
            .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize),
            .s_axi_awburst(s_awburst), .s_axi_awlock(s_awlock), .s_axi_awcache(s_awcache), .s_axi_awprot(s_awprot),
            .s_axi_awqos(s_awqos), .s_axi_awregion(s_awregion), .s_axi_awuser(s_awuser),
            .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready_g),
            .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast), .s_axi_wuser(s_wuser),
            .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready_g),
            .s_axi_bid(s_bid_g), .s_axi_bresp(s_bresp_g), .s_axi_buser(s_buser_g),
            .s_axi_bvalid(s_bvalid_g), .s_axi_bready(s_bready),
            .s_axi_arid(s_arid), .s_axi_araddr(s_araddr), .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize),
            .s_axi_arburst(s_arburst), .s_axi_arlock(s_arlock), .s_axi_arcache(s_arcache), .s_axi_arprot(s_arprot),
            .s_axi_arqos(s_arqos), .s_axi_arregion(s_arregion), .s_axi_aruser(s_aruser),
            .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready_g),
            .s_axi_rid(s_rid_g), .s_axi_rdata(s_rdata_g), .s_axi_rresp(s_rresp_g), .s_axi_rlast(s_rlast_g),
            .s_axi_ruser(s_ruser_g), .s_axi_rvalid(s_rvalid_g), .s_axi_rready(s_rready),
            .m_axi_awid(m_awid_g), .m_axi_awaddr(m_awaddr_g), .m_axi_awlen(m_awlen_g), .m_axi_awsize(m_awsize_g),
            .m_axi_awburst(m_awburst_g), .m_axi_awlock(m_awlock_g), .m_axi_awcache(m_awcache_g), .m_axi_awprot(m_awprot_g),
            .m_axi_awqos(m_awqos_g), .m_axi_awregion(m_awregion_g), .m_axi_awuser(m_awuser_g),
            .m_axi_awvalid(m_awvalid_g), .m_axi_awready(m_awready),
            .m_axi_wdata(m_wdata_g), .m_axi_wstrb(m_wstrb_g), .m_axi_wlast(m_wlast_g), .m_axi_wuser(m_wuser_g),
            .m_axi_wvalid(m_wvalid_g), .m_axi_wready(m_wready),
            .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_buser(m_buser),
            .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready_g),
            .m_axi_arid(m_arid_g), .m_axi_araddr(m_araddr_g), .m_axi_arlen(m_arlen_g), .m_axi_arsize(m_arsize_g),
            .m_axi_arburst(m_arburst_g), .m_axi_arlock(m_arlock_g), .m_axi_arcache(m_arcache_g), .m_axi_arprot(m_arprot_g),
            .m_axi_arqos(m_arqos_g), .m_axi_arregion(m_arregion_g), .m_axi_aruser(m_aruser_g),
            .m_axi_arvalid(m_arvalid_g), .m_axi_arready(m_arready),
            .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
            .m_axi_ruser(m_ruser), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready_g)
        );
    end else begin : g_gl_dn
        axi_adapter_gl_dn u_gl (
            .clk(clk), .rst(rst),
            .s_axi_awid(s_awid), .s_axi_awaddr(s_awaddr), .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize),
            .s_axi_awburst(s_awburst), .s_axi_awlock(s_awlock), .s_axi_awcache(s_awcache), .s_axi_awprot(s_awprot),
            .s_axi_awqos(s_awqos), .s_axi_awregion(s_awregion), .s_axi_awuser(s_awuser),
            .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready_g),
            .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast), .s_axi_wuser(s_wuser),
            .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready_g),
            .s_axi_bid(s_bid_g), .s_axi_bresp(s_bresp_g), .s_axi_buser(s_buser_g),
            .s_axi_bvalid(s_bvalid_g), .s_axi_bready(s_bready),
            .s_axi_arid(s_arid), .s_axi_araddr(s_araddr), .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize),
            .s_axi_arburst(s_arburst), .s_axi_arlock(s_arlock), .s_axi_arcache(s_arcache), .s_axi_arprot(s_arprot),
            .s_axi_arqos(s_arqos), .s_axi_arregion(s_arregion), .s_axi_aruser(s_aruser),
            .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready_g),
            .s_axi_rid(s_rid_g), .s_axi_rdata(s_rdata_g), .s_axi_rresp(s_rresp_g), .s_axi_rlast(s_rlast_g),
            .s_axi_ruser(s_ruser_g), .s_axi_rvalid(s_rvalid_g), .s_axi_rready(s_rready),
            .m_axi_awid(m_awid_g), .m_axi_awaddr(m_awaddr_g), .m_axi_awlen(m_awlen_g), .m_axi_awsize(m_awsize_g),
            .m_axi_awburst(m_awburst_g), .m_axi_awlock(m_awlock_g), .m_axi_awcache(m_awcache_g), .m_axi_awprot(m_awprot_g),
            .m_axi_awqos(m_awqos_g), .m_axi_awregion(m_awregion_g), .m_axi_awuser(m_awuser_g),
            .m_axi_awvalid(m_awvalid_g), .m_axi_awready(m_awready),
            .m_axi_wdata(m_wdata_g), .m_axi_wstrb(m_wstrb_g), .m_axi_wlast(m_wlast_g), .m_axi_wuser(m_wuser_g),
            .m_axi_wvalid(m_wvalid_g), .m_axi_wready(m_wready),
            .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_buser(m_buser),
            .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready_g),
            .m_axi_arid(m_arid_g), .m_axi_araddr(m_araddr_g), .m_axi_arlen(m_arlen_g), .m_axi_arsize(m_arsize_g),
            .m_axi_arburst(m_arburst_g), .m_axi_arlock(m_arlock_g), .m_axi_arcache(m_arcache_g), .m_axi_arprot(m_arprot_g),
            .m_axi_arqos(m_arqos_g), .m_axi_arregion(m_arregion_g), .m_axi_aruser(m_aruser_g),
            .m_axi_arvalid(m_arvalid_g), .m_axi_arready(m_arready),
            .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
            .m_axi_ruser(m_ruser), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready_g)
        );
    end
    endgenerate

    // Simple deterministic AXI4 memory responder driven by RTL master outputs
    reg [7:0] mem [0:4095];
    reg [31:0] lfsr;
    reg wr_act = 0, rd_act = 0;
    reg [31:0] wr_a = 0, wr_o = 0, rd_a = 0, rd_o = 0;
    reg [7:0]  wr_rem = 0, wr_len = 0, rd_rem = 0, rd_len = 0, wr_id = 0, rd_id = 0;
    reg [2:0]  wr_sz = 0, rd_sz = 0;
    reg [1:0]  wr_bt = 0, rd_bt = 0;
    reg        awr = 0, wrr = 0, bv = 0, arr = 0, rv = 0, rl = 0;
    reg [M_DATA_WIDTH-1:0] rdat = 0;
    integer k;

    assign m_awready = awr;
    assign m_wready  = wrr;
    assign m_bvalid  = bv;
    assign m_bid     = wr_id;
    assign m_bresp   = ((wr_o & 32'hFF0) == 32'h800) ? 2'b10 : 2'b00;
    assign m_buser   = 3'h5;
    assign m_arready = arr;
    assign m_rvalid  = rv;
    assign m_rid     = rd_id;
    assign m_rdata   = rdat;
    assign m_rresp   = ((rd_a & 32'hFF0) == 32'h800) ? 2'b10 : 2'b00;
    assign m_rlast   = rl;
    assign m_ruser   = 4'h9;

    localparam integer M_LSB = $clog2(M_STRB_WIDTH);

    initial begin
        errs = 0;
        for (k = 0; k < 4096; k = k + 1) mem[k] = k[7:0] ^ 8'h5A;
    end

    always @(posedge clk) begin
        if (rst) begin
            lfsr   <= seed_in ^ 32'hCAFE_1234;
            awr    <= 0; wrr <= 0; bv <= 0; arr <= 0; rv <= 0; rl <= 0;
            wr_act <= 0; rd_act <= 0;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (bv && m_bready_r) bv <= 0;
            awr <= !wr_act && !bv && lfsr[0];
            wrr <= wr_act && lfsr[1];
            if (m_awvalid_r && awr) begin
                awr <= 0; wr_act <= 1; wr_id <= m_awid_r; wr_a <= m_awaddr_r; wr_o <= m_awaddr_r;
                wr_rem <= m_awlen_r; wr_len <= m_awlen_r; wr_sz <= m_awsize_r; wr_bt <= m_awburst_r;
            end
            if (wr_act && m_wvalid_r && wrr) begin
                for (k = 0; k < M_STRB_WIDTH; k = k + 1)
                    if (m_wstrb_r[k]) mem[(((wr_a >> M_LSB) << M_LSB) + k) & 4095] <= m_wdata_r[k*8 +: 8];
                if (wr_rem == 0) begin
                    wr_act <= 0; wrr <= 0; bv <= 1;
                end else begin
                    wr_rem <= wr_rem - 1;
                    wr_a   <= (wr_bt == 2'b00) ? wr_o : (((wr_a + (1 << wr_sz)) & ~((1 << wr_sz) - 1)));
                end
            end

            if (rv && m_rready_r) rv <= 0;
            arr <= !rd_act && !rv && lfsr[2];
            if (m_arvalid_r && arr) begin
                arr <= 0; rd_act <= 1; rd_id <= m_arid_r; rd_a <= m_araddr_r; rd_o <= m_araddr_r;
                rd_rem <= m_arlen_r; rd_len <= m_arlen_r; rd_sz <= m_arsize_r; rd_bt <= m_arburst_r;
            end
            if (rd_act && (!rv || m_rready_r) && lfsr[3]) begin
                for (k = 0; k < M_STRB_WIDTH; k = k + 1)
                    rdat[k*8 +: 8] <= mem[(((rd_a >> M_LSB) << M_LSB) + k) & 4095];
                rv <= 1;
                if (rd_rem == 0) begin
                    rl <= 1; rd_act <= 0;
                end else begin
                    rl <= 0; rd_rem <= rd_rem - 1;
                    rd_a <= (rd_bt == 2'b00) ? rd_o : (((rd_a + (1 << rd_sz)) & ~((1 << rd_sz) - 1)));
                end
            end
        end
    end

    // Cycle-by-cycle RTL vs Gate-Level equivalence check on @(negedge clk)
    integer b;
    always @(negedge clk) begin
        if (!rst) begin
            if ({s_awready_g, s_wready_g, s_bvalid_g, s_arready_g, s_rvalid_g, m_awvalid_g, m_wvalid_g, m_bready_g, m_arvalid_g, m_rready_g} !==
                {s_awready_r, s_wready_r, s_bvalid_r, s_arready_r, s_rvalid_r, m_awvalid_r, m_wvalid_r, m_bready_r, m_arvalid_r, m_rready_r}) begin
                $display("FAIL_GL(up=%0d): control handshake mismatch! gl=%b rtl=%b", IS_UPSIZE,
                         {s_awready_g, s_wready_g, s_bvalid_g, s_arready_g, s_rvalid_g, m_awvalid_g, m_wvalid_g, m_bready_g, m_arvalid_g, m_rready_g},
                         {s_awready_r, s_wready_r, s_bvalid_r, s_arready_r, s_rvalid_r, m_awvalid_r, m_wvalid_r, m_bready_r, m_arvalid_r, m_rready_r});
                errs = errs + 1;
            end
            if (m_awvalid_r && ({m_awid_g, m_awaddr_g, m_awlen_g, m_awsize_g, m_awburst_g, m_awuser_g} !==
                                {m_awid_r, m_awaddr_r, m_awlen_r, m_awsize_r, m_awburst_r, m_awuser_r})) begin
                $display("FAIL_GL(up=%0d): m_aw payload mismatch!", IS_UPSIZE);
                errs = errs + 1;
            end
            if (m_wvalid_r) begin
                if ({m_wstrb_g, m_wlast_g, m_wuser_g} !== {m_wstrb_r, m_wlast_r, m_wuser_r}) begin
                    $display("FAIL_GL(up=%0d): m_w strb/last/user mismatch!", IS_UPSIZE);
                    errs = errs + 1;
                end
                for (b = 0; b < M_STRB_WIDTH; b = b + 1) begin
                    if (m_wstrb_r[b] && (m_wdata_g[b*8 +: 8] !== m_wdata_r[b*8 +: 8])) begin
                        $display("FAIL_GL(up=%0d): m_wdata lane %0d mismatch!", IS_UPSIZE, b);
                        errs = errs + 1;
                    end
                end
            end
            if (s_bvalid_r && ({s_bid_g, s_bresp_g, s_buser_g} !== {s_bid_r, s_bresp_r, s_buser_r})) begin
                $display("FAIL_GL(up=%0d): s_b payload mismatch!", IS_UPSIZE);
                errs = errs + 1;
            end
            if (m_arvalid_r && ({m_arid_g, m_araddr_g, m_arlen_g, m_arsize_g, m_arburst_g, m_aruser_g} !==
                                {m_arid_r, m_araddr_r, m_arlen_r, m_arsize_r, m_arburst_r, m_aruser_r})) begin
                $display("FAIL_GL(up=%0d): m_ar payload mismatch!", IS_UPSIZE);
                errs = errs + 1;
            end
            if (s_rvalid_r && ({s_rid_g, s_rdata_g, s_rresp_g, s_rlast_g, s_ruser_g} !==
                               {s_rid_r, s_rdata_r, s_rresp_r, s_rlast_r, s_ruser_r})) begin
                $display("FAIL_GL(up=%0d): s_r payload mismatch! gl_data=%0h rtl_data=%0h", IS_UPSIZE, s_rdata_g, s_rdata_r);
                errs = errs + 1;
            end
        end
    end

    task automatic run_seq;
        integer i;
        begin
            // Burst 1: unaligned wide/repacked INCR
            @(negedge clk);
            s_awid = 8'h31; s_awaddr = 32'h0000_0104; s_awlen = 8'd4;
            s_awsize = IS_UPSIZE ? 3'd2 : 3'd4; s_awburst = 2'b01; s_awcache = 4'b0010; s_awuser = 3'h5; s_awvalid = 1'b1;
            while (!s_awready_r) @(negedge clk);
            @(negedge clk); s_awvalid = 1'b0;
            for (i = 0; i <= 4; i = i + 1) begin
                s_wdata = {S_STRB_WIDTH{8'hA0 + i[7:0]}};
                s_wstrb = {S_STRB_WIDTH{1'b1}};
                s_wlast = (i == 4); s_wuser = 4'h7; s_wvalid = 1'b1;
                while (!s_wready_r) @(negedge clk);
                @(negedge clk); s_wvalid = 1'b0; s_wlast = 1'b0;
            end
            while (!s_bvalid_r) @(negedge clk);
            @(negedge clk);

            // Burst 2: Read back + error window read
            s_arid = 8'h42; s_araddr = 32'h0000_0104; s_arlen = 8'd4;
            s_arsize = IS_UPSIZE ? 3'd2 : 3'd4; s_arburst = 2'b01; s_arcache = 4'b0010; s_aruser = 3'h3; s_arvalid = 1'b1;
            while (!s_arready_r) @(negedge clk);
            @(negedge clk); s_arvalid = 1'b0;
            for (i = 0; i <= 4; i = i + 1) begin
                while (!s_rvalid_r) @(negedge clk);
                @(negedge clk);
            end

            // Burst 3: Narrow / FIXED across error window 0x800
            s_arid = 8'h55; s_araddr = 32'h0000_0800; s_arlen = 8'd2;
            s_arsize = IS_UPSIZE ? 3'd1 : 3'd4; s_arburst = 2'b00; s_arcache = 4'b0010; s_aruser = 3'h6; s_arvalid = 1'b1;
            while (!s_arready_r) @(negedge clk);
            @(negedge clk); s_arvalid = 1'b0;
            for (i = 0; i <= 2; i = i + 1) begin
                while (!s_rvalid_r) @(negedge clk);
                @(negedge clk);
            end
        end
    endtask
endmodule


module tb_gl #(
    parameter integer SEED = 101
);
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    wire [31:0] seed_w = SEED;
    integer errs_up, errs_dn;

    gl_pair_checker #(.IS_UPSIZE(1)) chk_up (.clk(clk), .rst(rst), .seed_in(seed_w), .errs(errs_up));
    gl_pair_checker #(.IS_UPSIZE(0)) chk_dn (.clk(clk), .rst(rst), .seed_in(seed_w ^ 32'h7777), .errs(errs_dn));

    initial begin
        #200000;
        $display("FAIL: tb_gl watchdog timeout!");
        $finish;
    end

    initial begin
        repeat (6) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);
        fork
            chk_up.run_seq();
            chk_dn.run_seq();
        join
        repeat (6) @(negedge clk);
        if (errs_up + errs_dn == 0)
            $display("PASS_GL seed=%0d", SEED);
        else
            $display("FAIL_GL seed=%0d errs=%0d", SEED, errs_up + errs_dn);
        $finish;
    end
endmodule
