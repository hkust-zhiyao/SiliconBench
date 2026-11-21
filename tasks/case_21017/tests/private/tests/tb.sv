`timescale 1ns / 1ps

module tb #(
    parameter int SEED = 101
);

    int errs = 0;
    int rng;

    function automatic int next_rand();
        rng = (rng * 1103515245 + 12345) & 32'h7fffffff;
        return rng;
    endfunction

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #2 clk = ~clk;

    // =========================================================================
    // DUT 1: 4x4 Hierarchical Overlapping Apertures + M_SECURE + Coupled M3
    //        + M_B_REG_TYPE / M_R_REG_TYPE forwarding check
    // =========================================================================
    // Regions (M_COUNT=4, M_REGIONS=2):
    //   M0: R0 = 0x0000_0000 / 32 (full 32-bit global fallback), R1 = inactive (0)
    //   M1: R0 = 0x4000_0000 / 16 (64KB),                        R1 = 0x4000_2000 / 12 (4KB, tie with M3 R0 -> M3 wins!)
    //   M2: R0 = 0x4000_1000 / 12 (4KB SECURE window inside M1!),R1 = 0x8000_0000 / 16 (64KB SECURE)
    //   M3: R0 = 0x4000_2000 / 12 (4KB coupled zero-slice),      R1 = 0x4000_2100 / 8  (256B longest prefix!)
    localparam [4*2*32-1:0] D1_BASE = {
        32'h4000_2100, 32'h4000_2000, // M3: R1, R0
        32'h8000_0000, 32'h4000_1000, // M2: R1, R0
        32'h4000_2000, 32'h4000_0000, // M1: R1, R0
        32'h0000_0000, 32'h0000_0000  // M0: R1, R0
    };
    localparam [4*2*32-1:0] D1_WIDTH = {
        32'd8,  32'd12, // M3
        32'd16, 32'd12, // M2
        32'd12, 32'd16, // M1
        32'd0,  32'd32  // M0 (/32 full range!)
    };
    // Disconnect S3 from M1 (so S3 @ 0x4000_0040 falls back to M0 /32, while S0..S2 hit M1 /16!)
    localparam [4*4-1:0] D1_CONN = {
        4'b1111, // M3 connected to S3..S0
        4'b1111, // M2 connected to S3..S0
        4'b0111, // M1 connected to S2..S0 only (S3 disconnected)
        4'b1111  // M0 connected to S3..S0
    };

    logic [4*32-1:0] d1_s_awaddr = '0, d1_s_araddr = '0;
    logic [4*3-1:0]  d1_s_awprot = '0, d1_s_arprot = '0;
    logic [3:0]      d1_s_awvalid = '0, d1_s_wvalid = '0, d1_s_bready = 4'hF;
    wire  [3:0]      d1_s_awready, d1_s_wready, d1_s_bvalid;
    logic [4*32-1:0] d1_s_wdata = '0;
    logic [4*4-1:0]  d1_s_wstrb = '0;
    wire  [4*2-1:0]  d1_s_bresp;
    logic [3:0]      d1_s_arvalid = '0, d1_s_rready = 4'hF;
    wire  [3:0]      d1_s_arready, d1_s_rvalid;
    wire  [4*32-1:0] d1_s_rdata;
    wire  [4*2-1:0]  d1_s_rresp;

    wire  [4*32-1:0] d1_m_awaddr, d1_m_wdata, d1_m_araddr;
    wire  [4*3-1:0]  d1_m_awprot, d1_m_arprot;
    wire  [4*4-1:0]  d1_m_wstrb;
    wire  [3:0]      d1_m_awvalid, d1_m_wvalid, d1_m_bready, d1_m_arvalid, d1_m_rready;
    logic [3:0]      d1_m_awready, d1_m_wready, d1_m_bvalid, d1_m_arready, d1_m_rvalid;
    logic [4*2-1:0]  d1_m_bresp;
    logic [4*32-1:0] d1_m_rdata;
    logic [4*2-1:0]  d1_m_rresp;

    axil_crossbar #(
        .S_COUNT(4),
        .M_COUNT(4),
        .DATA_WIDTH(32),
        .ADDR_WIDTH(32),
        .M_REGIONS(2),
        .M_BASE_ADDR(D1_BASE),
        .M_ADDR_WIDTH(D1_WIDTH),
        .M_CONNECT_READ(D1_CONN),
        .M_CONNECT_WRITE(D1_CONN),
        .M_SECURE(4'b0100), // M2 is secure
        .S_AW_REG_TYPE({4{2'd0}}),
        .S_W_REG_TYPE ({4{2'd0}}),
        .S_B_REG_TYPE ({4{2'd0}}), // bypass S_B so M_B skid forwarding is directly observable!
        .S_AR_REG_TYPE({4{2'd0}}),
        .S_R_REG_TYPE ({4{2'd0}}), // bypass S_R so M_R skid forwarding is directly observable!
        .M_AW_REG_TYPE({2'd0, 2'd1, 2'd1, 2'd1}), // M3 has zero-slice AW!
        .M_W_REG_TYPE ({2'd0, 2'd2, 2'd2, 2'd2}), // M3 has zero-slice W!
        .M_B_REG_TYPE ({4{2'd2}}),                // M_B skid buffer (depth 2)
        .M_AR_REG_TYPE({2'd0, 2'd1, 2'd1, 2'd1}),
        .M_R_REG_TYPE ({4{2'd2}})                 // M_R skid buffer (depth 2)
    ) u_dut1 (
        .clk(clk),
        .rst(rst),
        .s_axil_awaddr(d1_s_awaddr),
        .s_axil_awprot(d1_s_awprot),
        .s_axil_awvalid(d1_s_awvalid),
        .s_axil_awready(d1_s_awready),
        .s_axil_wdata(d1_s_wdata),
        .s_axil_wstrb(d1_s_wstrb),
        .s_axil_wvalid(d1_s_wvalid),
        .s_axil_wready(d1_s_wready),
        .s_axil_bresp(d1_s_bresp),
        .s_axil_bvalid(d1_s_bvalid),
        .s_axil_bready(d1_s_bready),
        .s_axil_araddr(d1_s_araddr),
        .s_axil_arprot(d1_s_arprot),
        .s_axil_arvalid(d1_s_arvalid),
        .s_axil_arready(d1_s_arready),
        .s_axil_rdata(d1_s_rdata),
        .s_axil_rresp(d1_s_rresp),
        .s_axil_rvalid(d1_s_rvalid),
        .s_axil_rready(d1_s_rready),
        .m_axil_awaddr(d1_m_awaddr),
        .m_axil_awprot(d1_m_awprot),
        .m_axil_awvalid(d1_m_awvalid),
        .m_axil_awready(d1_m_awready),
        .m_axil_wdata(d1_m_wdata),
        .m_axil_wstrb(d1_m_wstrb),
        .m_axil_wvalid(d1_m_wvalid),
        .m_axil_wready(d1_m_wready),
        .m_axil_bresp(d1_m_bresp),
        .m_axil_bvalid(d1_m_bvalid),
        .m_axil_bready(d1_m_bready),
        .m_axil_araddr(d1_m_araddr),
        .m_axil_arprot(d1_m_arprot),
        .m_axil_arvalid(d1_m_arvalid),
        .m_axil_arready(d1_m_arready),
        .m_axil_rdata(d1_m_rdata),
        .m_axil_rresp(d1_m_rresp),
        .m_axil_rvalid(d1_m_rvalid),
        .m_axil_rready(d1_m_rready)
    );

    // Simple behavioral responder models for M0..M3 on DUT1
    logic [31:0] d1_mem [0:3][0:255];
    int          d1_wr_hits [0:3];
    int          d1_rd_hits [0:3];
    logic        d1_m0_manual_b = 1'b0;
    logic        d1_m0_manual_r = 1'b0;

    // M0..M2 independent AW/W capture; M3 STRICTLY COUPLED (waits for m_awvalid && m_wvalid simultaneously!)
    logic        m_have_aw [0:2], m_have_w [0:2];
    logic [31:0] m_lat_aw  [0:2], m_lat_w  [0:2];
    logic        m_b_pend  [0:3];
    logic        m_r_pend  [0:3];
    logic [31:0] m_r_dat   [0:3];

    always @* begin
        for (int mi = 0; mi < 3; mi++) begin
            d1_m_awready[mi] = !rst && !m_have_aw[mi] && (!m_b_pend[mi] || d1_m0_manual_b);
            d1_m_wready[mi]  = !rst && !m_have_w[mi]  && (!m_b_pend[mi] || d1_m0_manual_b);
        end
        // M3 coupled zero-slice slave: ONLY ready when BOTH awvalid and wvalid are asserted together!
        d1_m_awready[3] = !rst && !m_b_pend[3] && d1_m_awvalid[3] && d1_m_wvalid[3];
        d1_m_wready[3]  = !rst && !m_b_pend[3] && d1_m_awvalid[3] && d1_m_wvalid[3];

        for (int mi = 0; mi < 4; mi++) begin
            d1_m_bvalid[mi]  = m_b_pend[mi];
            d1_m_bresp[mi*2 +: 2] = 2'b00;
            d1_m_arready[mi] = !rst && (!m_r_pend[mi] || (mi == 0 && d1_m0_manual_r));
            d1_m_rvalid[mi]  = m_r_pend[mi];
            d1_m_rdata[mi*32 +: 32] = m_r_dat[mi];
            d1_m_rresp[mi*2 +: 2]   = 2'b00;
        end
    end

    int m0_b_q = 0, m0_r_q = 0;
    logic [31:0] m0_r_fifo [0:7];
    int m0_r_wr = 0, m0_r_rd = 0;

    always @(posedge clk) begin
        if (rst) begin
            for (int mi = 0; mi < 3; mi++) begin
                m_have_aw[mi] <= 1'b0;
                m_have_w[mi]  <= 1'b0;
                m_lat_aw[mi]  <= '0;
                m_lat_w[mi]   <= '0;
            end
            for (int mi = 0; mi < 4; mi++) begin
                m_b_pend[mi]  <= 1'b0;
                m_r_pend[mi]  <= 1'b0;
                m_r_dat[mi]   <= '0;
                d1_wr_hits[mi] <= 0;
                d1_rd_hits[mi] <= 0;
                for (int a = 0; a < 256; a++)
                    d1_mem[mi][a] <= (32'hA000_0000 | (mi << 24) | a);
            end
            m0_b_q <= 0;
            m0_r_q <= 0;
            m0_r_wr <= 0;
            m0_r_rd <= 0;
        end else begin
            // Zero-X monitor on DUT1
            if ((^d1_s_awready === 1'bx) || (^d1_s_wready === 1'bx) || (^d1_s_bvalid === 1'bx) ||
                (^d1_s_arready === 1'bx) || (^d1_s_rvalid === 1'bx) ||
                (^d1_m_awvalid === 1'bx) || (^d1_m_wvalid === 1'bx) || (^d1_m_bready === 1'bx) ||
                (^d1_m_arvalid === 1'bx) || (^d1_m_rready === 1'bx)) begin
                $display("FAIL [DUT1 Zero-X]: X detected on handshake signals at t=%0t", $time);
                errs <= errs + 1;
            end

            // M0..M2 writes
            for (int mi = 0; mi < 3; mi++) begin
                logic got_aw, got_w;
                logic [31:0] use_aw, use_w;
                got_aw = m_have_aw[mi];
                got_w  = m_have_w[mi];
                use_aw = m_lat_aw[mi];
                use_w  = m_lat_w[mi];

                if (d1_m_bvalid[mi] && d1_m_bready[mi]) begin
                    if (mi == 0 && m0_b_q > 1) begin
                        m0_b_q <= m0_b_q - 1;
                        m_b_pend[0] <= 1'b1;
                    end else begin
                        if (mi == 0) m0_b_q <= 0;
                        m_b_pend[mi] <= 1'b0;
                    end
                end

                if (d1_m_awvalid[mi] && d1_m_awready[mi]) begin
                    got_aw = 1'b1;
                    use_aw = d1_m_awaddr[mi*32 +: 32];
                end
                if (d1_m_wvalid[mi] && d1_m_wready[mi]) begin
                    got_w = 1'b1;
                    use_w = d1_m_wdata[mi*32 +: 32];
                end
                if (got_aw && got_w) begin
                    d1_mem[mi][(use_aw >> 2) & 8'hFF] <= use_w;
                    d1_wr_hits[mi] <= d1_wr_hits[mi] + 1;
                    m_have_aw[mi]  <= 1'b0;
                    m_have_w[mi]   <= 1'b0;
                    m_b_pend[mi]   <= 1'b1;
                    if (mi == 0) begin
                        int cur_b;
                        cur_b = (d1_m_bvalid[0] && d1_m_bready[0]) ? (m0_b_q - 1) : m0_b_q;
                        m0_b_q <= cur_b + 1;
                    end
                end else begin
                    m_have_aw[mi] <= got_aw;
                    m_have_w[mi]  <= got_w;
                    m_lat_aw[mi]  <= use_aw;
                    m_lat_w[mi]   <= use_w;
                end
            end

            // M3 coupled write
            if (d1_m_bvalid[3] && d1_m_bready[3])
                m_b_pend[3] <= 1'b0;
            if (d1_m_awvalid[3] && d1_m_awready[3] && d1_m_wvalid[3] && d1_m_wready[3]) begin
                d1_mem[3][(d1_m_awaddr[3*32 +: 32] >> 2) & 8'hFF] <= d1_m_wdata[3*32 +: 32];
                d1_wr_hits[3] <= d1_wr_hits[3] + 1;
                m_b_pend[3]   <= 1'b1;
            end

            // M0..M3 reads
            for (int mi = 0; mi < 4; mi++) begin
                if (mi == 0 && d1_m0_manual_r) begin
                    int cnt;
                    cnt = m0_r_q;
                    if (d1_m_rvalid[0] && d1_m_rready[0] && cnt > 0) begin
                        cnt = cnt - 1;
                        m0_r_rd <= m0_r_rd + 1;
                        if (cnt > 0)
                            m_r_dat[0] <= m0_r_fifo[(m0_r_rd + 1) & 7];
                    end
                    if (d1_m_arvalid[0] && d1_m_arready[0]) begin
                        logic [31:0] rv;
                        rv = (32'hD000_0000 | (0 << 24)) ^ d1_mem[0][(d1_m_araddr[31:0] >> 2) & 8'hFF];
                        m0_r_fifo[m0_r_wr & 7] <= rv;
                        m0_r_wr <= m0_r_wr + 1;
                        if (cnt == 0) m_r_dat[0] <= rv;
                        cnt = cnt + 1;
                        d1_rd_hits[0] <= d1_rd_hits[0] + 1;
                    end
                    m0_r_q <= cnt;
                    m_r_pend[0] <= (cnt > 0);
                end else begin
                    if (d1_m_rvalid[mi] && d1_m_rready[mi])
                        m_r_pend[mi] <= 1'b0;
                    if (d1_m_arvalid[mi] && d1_m_arready[mi]) begin
                        m_r_dat[mi]  <= (32'hD000_0000 | (mi << 24)) ^ d1_mem[mi][(d1_m_araddr[mi*32 +: 32] >> 2) & 8'hFF];
                        m_r_pend[mi] <= 1'b1;
                        d1_rd_hits[mi] <= d1_rd_hits[mi] + 1;
                    end
                end
            end
        end
    end

    task automatic d1_write(
        input int          s_idx,
        input logic [31:0] addr,
        input logic [2:0]  prot,
        input logic [31:0] data,
        output logic [1:0] bresp
    );
        logic aw_done, w_done;
        int guard;
        aw_done = 1'b0;
        w_done  = 1'b0;
        guard   = 0;
        @(posedge clk); #0.2;
        d1_s_awaddr[s_idx*32 +: 32] = addr;
        d1_s_awprot[s_idx*3 +: 3]   = prot;
        d1_s_awvalid[s_idx]         = 1'b1;
        d1_s_wdata[s_idx*32 +: 32]  = data;
        d1_s_wstrb[s_idx*4 +: 4]    = 4'hF;
        d1_s_wvalid[s_idx]          = 1'b1;
        while (!(aw_done && w_done)) begin
            @(posedge clk);
            if (!aw_done && d1_s_awready[s_idx]) aw_done = 1'b1;
            if (!w_done  && d1_s_wready[s_idx])  w_done  = 1'b1;
            #0.2;
            if (aw_done) d1_s_awvalid[s_idx] = 1'b0;
            if (w_done)  d1_s_wvalid[s_idx]  = 1'b0;
            guard++;
            if (guard > 200) begin
                $display("FAIL [d1_write timeout]: S%0d addr=%h aw_done=%b w_done=%b", s_idx, addr, aw_done, w_done);
                errs++;
                d1_s_awvalid[s_idx] = 1'b0;
                d1_s_wvalid[s_idx]  = 1'b0;
                bresp = 2'bxx;
                return;
            end
        end
        guard = 0;
        while (1) begin
            @(posedge clk);
            if (d1_s_bvalid[s_idx] && d1_s_bready[s_idx]) begin
                bresp = d1_s_bresp[s_idx*2 +: 2];
                break;
            end
            guard++;
            if (guard > 200) begin
                $display("FAIL [d1_write B timeout]: S%0d addr=%h", s_idx, addr);
                errs++;
                bresp = 2'bxx;
                break;
            end
        end
        #0.2;
    endtask

    task automatic d1_read(
        input int          s_idx,
        input logic [31:0] addr,
        input logic [2:0]  prot,
        output logic [31:0] rdata,
        output logic [1:0]  rresp
    );
        int guard;
        guard = 0;
        @(posedge clk); #0.2;
        d1_s_araddr[s_idx*32 +: 32] = addr;
        d1_s_arprot[s_idx*3 +: 3]   = prot;
        d1_s_arvalid[s_idx]         = 1'b1;
        while (1) begin
            @(posedge clk);
            if (d1_s_arready[s_idx]) break;
            guard++;
            if (guard > 200) begin
                $display("FAIL [d1_read AR timeout]: S%0d addr=%h", s_idx, addr);
                errs++;
                d1_s_arvalid[s_idx] = 1'b0;
                rdata = 'x; rresp = 2'bxx;
                return;
            end
        end
        #0.2;
        d1_s_arvalid[s_idx] = 1'b0;
        guard = 0;
        while (1) begin
            @(posedge clk);
            if (d1_s_rvalid[s_idx] && d1_s_rready[s_idx]) begin
                rdata = d1_s_rdata[s_idx*32 +: 32];
                rresp = d1_s_rresp[s_idx*2 +: 2];
                break;
            end
            guard++;
            if (guard > 200) begin
                $display("FAIL [d1_read R timeout]: S%0d addr=%h", s_idx, addr);
                errs++;
                rdata = 'x; rresp = 2'bxx;
                break;
            end
        end
        #0.2;
    endtask

    // =========================================================================
    // DUT 2: 6x6 Crossbar (S_COUNT*M_COUNT = 36 > 32-bit shift width!)
    // =========================================================================
    localparam [6*32-1:0] D2_BASE = {
        32'h5000_0000, 32'h4000_0000, 32'h3000_0000,
        32'h2000_0000, 32'h1000_0000, 32'h0000_0000
    };
    localparam [6*32-1:0] D2_WIDTH = {6{32'd16}};
    // Asymmetric Read vs Write connectivity on high bits (>= bit 32):
    // M5 (bits 35:30): connected to S5 (bit 35) & S4 (bit 34) for both RD and WR; S3 (bit 33) RD-only!
    localparam [35:0] D2_CONN_RD = {
        6'b111000, // M5: S5, S4, S3
        6'b111111, // M4
        6'b111111, // M3
        6'b111111, // M2
        6'b111111, // M1
        6'b111111  // M0
    };
    localparam [35:0] D2_CONN_WR = {
        6'b110000, // M5: S5 (bit 35), S4 (bit 34) ONLY (S3 write disconnected!)
        6'b111111,
        6'b111111,
        6'b111111,
        6'b111111,
        6'b111111
    };

    logic [6*32-1:0] d2_s_awaddr = '0, d2_s_wdata = '0, d2_s_araddr = '0;
    logic [6*3-1:0]  d2_s_awprot = '0, d2_s_arprot = '0;
    logic [6*4-1:0]  d2_s_wstrb  = {6{4'hF}};
    logic [5:0]      d2_s_awvalid = '0, d2_s_wvalid = '0, d2_s_bready = 6'h3F;
    wire  [5:0]      d2_s_awready, d2_s_wready, d2_s_bvalid;
    wire  [6*2-1:0]  d2_s_bresp;
    logic [5:0]      d2_s_arvalid = '0, d2_s_rready = 6'h3F;
    wire  [5:0]      d2_s_arready, d2_s_rvalid;
    wire  [6*32-1:0] d2_s_rdata;
    wire  [6*2-1:0]  d2_s_rresp;

    wire  [6*32-1:0] d2_m_awaddr, d2_m_wdata, d2_m_araddr;
    wire  [5:0]      d2_m_awvalid, d2_m_wvalid, d2_m_bready, d2_m_arvalid, d2_m_rready;
    logic [5:0]      d2_m_bvalid = '0, d2_m_rvalid = '0;
    logic [6*32-1:0] d2_m_rdata = '0;

    axil_crossbar #(
        .S_COUNT(6),
        .M_COUNT(6),
        .DATA_WIDTH(32),
        .ADDR_WIDTH(32),
        .M_REGIONS(1),
        .M_BASE_ADDR(D2_BASE),
        .M_ADDR_WIDTH(D2_WIDTH),
        .M_CONNECT_READ(D2_CONN_RD),
        .M_CONNECT_WRITE(D2_CONN_WR)
    ) u_dut2 (
        .clk(clk), .rst(rst),
        .s_axil_awaddr(d2_s_awaddr), .s_axil_awprot(d2_s_awprot), .s_axil_awvalid(d2_s_awvalid), .s_axil_awready(d2_s_awready),
        .s_axil_wdata(d2_s_wdata), .s_axil_wstrb(d2_s_wstrb), .s_axil_wvalid(d2_s_wvalid), .s_axil_wready(d2_s_wready),
        .s_axil_bresp(d2_s_bresp), .s_axil_bvalid(d2_s_bvalid), .s_axil_bready(d2_s_bready),
        .s_axil_araddr(d2_s_araddr), .s_axil_arprot(d2_s_arprot), .s_axil_arvalid(d2_s_arvalid), .s_axil_arready(d2_s_arready),
        .s_axil_rdata(d2_s_rdata), .s_axil_rresp(d2_s_rresp), .s_axil_rvalid(d2_s_rvalid), .s_axil_rready(d2_s_rready),
        .m_axil_awaddr(d2_m_awaddr), .m_axil_awprot(), .m_axil_awvalid(d2_m_awvalid), .m_axil_awready(6'h3F),
        .m_axil_wdata(d2_m_wdata), .m_axil_wstrb(), .m_axil_wvalid(d2_m_wvalid), .m_axil_wready(6'h3F),
        .m_axil_bresp(12'd0), .m_axil_bvalid(d2_m_bvalid), .m_axil_bready(d2_m_bready),
        .m_axil_araddr(d2_m_araddr), .m_axil_arprot(), .m_axil_arvalid(d2_m_arvalid), .m_axil_arready(6'h3F),
        .m_axil_rdata(d2_m_rdata), .m_axil_rresp(12'd0), .m_axil_rvalid(d2_m_rvalid), .m_axil_rready(d2_m_rready)
    );

    logic [31:0] d2_last_wr [0:5];
    logic        d2_got_aw  [0:5], d2_got_w [0:5];
    always @(posedge clk) begin
        if (rst) begin
            d2_m_bvalid <= '0;
            d2_m_rvalid <= '0;
            for (int k = 0; k < 6; k++) begin
                d2_got_aw[k] <= 1'b0; d2_got_w[k] <= 1'b0; d2_last_wr[k] <= '0;
            end
        end else begin
            for (int k = 0; k < 6; k++) begin
                logic a, w;
                a = d2_got_aw[k] || d2_m_awvalid[k];
                w = d2_got_w[k]  || d2_m_wvalid[k];
                if (d2_m_wvalid[k]) d2_last_wr[k] <= d2_m_wdata[k*32 +: 32];
                if (d2_m_bvalid[k] && d2_m_bready[k]) d2_m_bvalid[k] <= 1'b0;
                if (a && w) begin
                    d2_m_bvalid[k] <= 1'b1;
                    d2_got_aw[k] <= 1'b0; d2_got_w[k] <= 1'b0;
                end else begin
                    d2_got_aw[k] <= a; d2_got_w[k] <= w;
                end

                if (d2_m_rvalid[k] && d2_m_rready[k]) d2_m_rvalid[k] <= 1'b0;
                if (d2_m_arvalid[k]) begin
                    d2_m_rdata[k*32 +: 32] <= d2_last_wr[k] ^ (32'h6600_0000 | (k << 16));
                    d2_m_rvalid[k] <= 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // DUT 3 (1x3 Single-Slave) & DUT 4 (3x1 Single-Master)
    // =========================================================================
    logic [31:0] d3_s_awaddr = '0, d3_s_wdata = '0, d3_s_araddr = '0;
    logic        d3_s_awvalid = 0, d3_s_wvalid = 0, d3_s_arvalid = 0;
    wire         d3_s_awready, d3_s_wready, d3_s_bvalid, d3_s_arready, d3_s_rvalid;
    wire  [1:0]  d3_s_bresp, d3_s_rresp;
    wire  [31:0] d3_s_rdata;
    wire  [2:0]  d3_m_awvalid, d3_m_wvalid, d3_m_bready, d3_m_arvalid, d3_m_rready;
    logic [2:0]  d3_m_bvalid = '0, d3_m_rvalid = '0;
    logic [3*32-1:0] d3_m_rdata = {32'h3333_0002, 32'h3333_0001, 32'h3333_0000};

    axil_crossbar #(
        .S_COUNT(1),
        .M_COUNT(3),
        .M_REGIONS(1),
        .M_BASE_ADDR({32'h2000_0000, 32'h1000_0000, 32'h0000_0000}),
        .M_ADDR_WIDTH({3{32'd16}})
    ) u_dut3 (
        .clk(clk), .rst(rst),
        .s_axil_awaddr(d3_s_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(d3_s_awvalid), .s_axil_awready(d3_s_awready),
        .s_axil_wdata(d3_s_wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(d3_s_wvalid), .s_axil_wready(d3_s_wready),
        .s_axil_bresp(d3_s_bresp), .s_axil_bvalid(d3_s_bvalid), .s_axil_bready(1'b1),
        .s_axil_araddr(d3_s_araddr), .s_axil_arprot(3'd0), .s_axil_arvalid(d3_s_arvalid), .s_axil_arready(d3_s_arready),
        .s_axil_rdata(d3_s_rdata), .s_axil_rresp(d3_s_rresp), .s_axil_rvalid(d3_s_rvalid), .s_axil_rready(1'b1),
        .m_axil_awaddr(), .m_axil_awprot(), .m_axil_awvalid(d3_m_awvalid), .m_axil_awready(3'b111),
        .m_axil_wdata(), .m_axil_wstrb(), .m_axil_wvalid(d3_m_wvalid), .m_axil_wready(3'b111),
        .m_axil_bresp(6'd0), .m_axil_bvalid(d3_m_bvalid), .m_axil_bready(d3_m_bready),
        .m_axil_araddr(), .m_axil_arprot(), .m_axil_arvalid(d3_m_arvalid), .m_axil_arready(3'b111),
        .m_axil_rdata(d3_m_rdata), .m_axil_rresp(6'd0), .m_axil_rvalid(d3_m_rvalid), .m_axil_rready(d3_m_rready)
    );

    logic [2:0] d3_aw_g, d3_w_g;
    always @(posedge clk) begin
        if (rst) begin
            d3_m_bvalid <= '0; d3_m_rvalid <= '0; d3_aw_g <= '0; d3_w_g <= '0;
        end else begin
            for (int k = 0; k < 3; k++) begin
                logic a, w;
                a = d3_aw_g[k] || d3_m_awvalid[k];
                w = d3_w_g[k]  || d3_m_wvalid[k];
                if (d3_m_bvalid[k] && d3_m_bready[k]) d3_m_bvalid[k] <= 1'b0;
                if (a && w) begin d3_m_bvalid[k] <= 1'b1; d3_aw_g[k] <= 1'b0; d3_w_g[k] <= 1'b0; end
                else begin d3_aw_g[k] <= a; d3_w_g[k] <= w; end
                if (d3_m_rvalid[k] && d3_m_rready[k]) d3_m_rvalid[k] <= 1'b0;
                if (d3_m_arvalid[k]) d3_m_rvalid[k] <= 1'b1;
            end
        end
    end

    logic [3*32-1:0] d4_s_awaddr = '0, d4_s_wdata = '0, d4_s_araddr = '0;
    logic [2:0]      d4_s_awvalid = '0, d4_s_wvalid = '0, d4_s_arvalid = '0;
    wire  [2:0]      d4_s_awready, d4_s_wready, d4_s_bvalid, d4_s_arready, d4_s_rvalid;
    wire  [3*2-1:0]  d4_s_bresp, d4_s_rresp;
    wire  [3*32-1:0] d4_s_rdata;
    wire             d4_m_awvalid, d4_m_wvalid, d4_m_bready, d4_m_arvalid, d4_m_rready;
    logic            d4_m_bvalid = 1'b0, d4_m_rvalid = 1'b0;
    logic [31:0]     d4_m_rdata = 32'h4444_5555;

    axil_crossbar #(
        .S_COUNT(3),
        .M_COUNT(1),
        .M_REGIONS(1),
        .M_BASE_ADDR(32'h1000_0000),
        .M_ADDR_WIDTH(32'd16)
    ) u_dut4 (
        .clk(clk), .rst(rst),
        .s_axil_awaddr(d4_s_awaddr), .s_axil_awprot(9'd0), .s_axil_awvalid(d4_s_awvalid), .s_axil_awready(d4_s_awready),
        .s_axil_wdata(d4_s_wdata), .s_axil_wstrb({3{4'hF}}), .s_axil_wvalid(d4_s_wvalid), .s_axil_wready(d4_s_wready),
        .s_axil_bresp(d4_s_bresp), .s_axil_bvalid(d4_s_bvalid), .s_axil_bready(3'b111),
        .s_axil_araddr(d4_s_araddr), .s_axil_arprot(9'd0), .s_axil_arvalid(d4_s_arvalid), .s_axil_arready(d4_s_arready),
        .s_axil_rdata(d4_s_rdata), .s_axil_rresp(d4_s_rresp), .s_axil_rvalid(d4_s_rvalid), .s_axil_rready(3'b111),
        .m_axil_awaddr(), .m_axil_awprot(), .m_axil_awvalid(d4_m_awvalid), .m_axil_awready(1'b1),
        .m_axil_wdata(), .m_axil_wstrb(), .m_axil_wvalid(d4_m_wvalid), .m_axil_wready(1'b1),
        .m_axil_bresp(2'd0), .m_axil_bvalid(d4_m_bvalid), .m_axil_bready(d4_m_bready),
        .m_axil_araddr(), .m_axil_arprot(), .m_axil_arvalid(d4_m_arvalid), .m_axil_arready(1'b1),
        .m_axil_rdata(d4_m_rdata), .m_axil_rresp(2'd0), .m_axil_rvalid(d4_m_rvalid), .m_axil_rready(d4_m_rready)
    );

    logic d4_aw_g, d4_w_g;
    always @(posedge clk) begin
        if (rst) begin
            d4_m_bvalid <= 1'b0; d4_m_rvalid <= 1'b0; d4_aw_g <= 1'b0; d4_w_g <= 1'b0;
        end else begin
            logic a, w;
            a = d4_aw_g || d4_m_awvalid;
            w = d4_w_g  || d4_m_wvalid;
            if (d4_m_bvalid && d4_m_bready) d4_m_bvalid <= 1'b0;
            if (a && w) begin d4_m_bvalid <= 1'b1; d4_aw_g <= 1'b0; d4_w_g <= 1'b0; end
            else begin d4_aw_g <= a; d4_w_g <= w; end
            if (d4_m_rvalid && d4_m_rready) d4_m_rvalid <= 1'b0;
            if (d4_m_arvalid) d4_m_rvalid <= 1'b1;
        end
    end

    // =========================================================================
    // Test Stimulus
    // =========================================================================
    initial begin
        logic [1:0]  resp;
        logic [31:0] rdat;
        int pre0, pre1, pre2, pre3;

        rng = SEED;
        repeat (5) @(posedge clk);
        #0.2;
        rst = 1'b0;
        repeat (3) @(posedge clk);

        // ---------------------------------------------------------------------
        // T1: Hierarchical Overlapping Longest-Prefix Decode + /32 Fallback + Tie-Break
        // ---------------------------------------------------------------------
        // 1a: 0x1234_0010 -> only matches M0 /32 global fallback!
        d1_write(0, 32'h1234_0010, 3'b000, 32'hCAFE_0000, resp);
        if (resp !== 2'b00 || d1_wr_hits[0] != 1) begin
            $display("FAIL [T1a /32 fallback wr]: resp=%b m0_hits=%0d", resp, d1_wr_hits[0]);
            errs++;
        end
        d1_read(1, 32'h1234_0010, 3'b000, rdat, resp);
        if (resp !== 2'b00 || rdat !== (32'hD000_0000 ^ 32'hCAFE_0000)) begin
            $display("FAIL [T1a /32 fallback rd]: resp=%b rdat=%h", resp, rdat);
            errs++;
        end

        // 1b: 0x4000_0040 from S0 -> matches M0(/32) and M1(/16) -> longest prefix M1!
        d1_write(0, 32'h4000_0040, 3'b000, 32'hCAFE_1111, resp);
        if (resp !== 2'b00 || d1_wr_hits[1] != 1) begin
            $display("FAIL [T1b /16 over /32]: resp=%b m1_hits=%0d", resp, d1_wr_hits[1]);
            errs++;
        end
        // 1c: 0x4000_0040 from S3 (disconnected from M1!) -> falls back to M0(/32)!
        pre0 = d1_wr_hits[0]; pre1 = d1_wr_hits[1];
        d1_write(3, 32'h4000_0040, 3'b000, 32'hCAFE_3300, resp);
        if (resp !== 2'b00 || d1_wr_hits[0] != pre0 + 1 || d1_wr_hits[1] != pre1) begin
            $display("FAIL [T1c S3 disconnected from M1]: resp=%b m0=%0d m1=%0d", resp, d1_wr_hits[0], d1_wr_hits[1]);
            errs++;
        end

        // 1d: 0x4000_2020 -> matches M0(/32), M1_R0(/16), M1_R1(/12), M3_R0(/12) -> tie on /12 picks higher master M3 (coupled zero-slice)!
        d1_write(2, 32'h4000_2020, 3'b000, 32'hCAFE_3333, resp);
        if (resp !== 2'b00 || d1_wr_hits[3] != 1) begin
            $display("FAIL [T1d tie-break M3 over M1]: resp=%b m3_hits=%0d", resp, d1_wr_hits[3]);
            errs++;
        end
        // 1e: 0x4000_2108 -> matches /32, /16, /12, and M3_R1(/8) -> longest prefix /8 on M3!
        d1_write(1, 32'h4000_2108, 3'b000, 32'hCAFE_3888, resp);
        d1_read(0, 32'h4000_2108, 3'b000, rdat, resp);
        if (resp !== 2'b00 || rdat !== (32'hD300_0000 ^ 32'hCAFE_3888)) begin
            $display("FAIL [T1e /8 longest prefix]: resp=%b rdat=%h", resp, rdat);
            errs++;
        end

        // ---------------------------------------------------------------------
        // T2: M_SECURE Window Isolation (MUST NOT leak to M1 /16 or M0 /32!)
        // ---------------------------------------------------------------------
        // Secure access (aprot[1]=0) to 0x4000_1014 -> routes to M2
        d1_write(0, 32'h4000_1014, 3'b000, 32'h5EC0_1234, resp);
        if (resp !== 2'b00 || d1_wr_hits[2] != 1) begin
            $display("FAIL [T2a secure wr to M2]: resp=%b m2_hits=%0d", resp, d1_wr_hits[2]);
            errs++;
        end
        // Non-secure access (aprot[1]=1) to 0x4000_1014 -> MUST return DECERR (2'b11) and NOT hit M2, M1, or M0!
        pre0 = d1_wr_hits[0]; pre1 = d1_wr_hits[1]; pre2 = d1_wr_hits[2]; pre3 = d1_wr_hits[3];
        d1_write(1, 32'h4000_1014, 3'b010, 32'hBAD0_DEAD, resp);
        if (resp !== 2'b11 || d1_wr_hits[0] != pre0 || d1_wr_hits[1] != pre1 || d1_wr_hits[2] != pre2 || d1_wr_hits[3] != pre3) begin
            $display("FAIL [T2b non-secure wr leaked to fallback!]: resp=%b hits=(%0d,%0d,%0d,%0d) pre=(%0d,%0d,%0d,%0d)",
                     resp, d1_wr_hits[0], d1_wr_hits[1], d1_wr_hits[2], d1_wr_hits[3], pre0, pre1, pre2, pre3);
            errs++;
        end
        pre0 = d1_rd_hits[0]; pre1 = d1_rd_hits[1]; pre2 = d1_rd_hits[2];
        d1_read(2, 32'h4000_1014, 3'b010, rdat, resp);
        if (resp !== 2'b11 || rdat !== 32'd0 || d1_rd_hits[0] != pre0 || d1_rd_hits[1] != pre1 || d1_rd_hits[2] != pre2) begin
            $display("FAIL [T2c non-secure rd leaked!]: resp=%b rdat=%h", resp, rdat);
            errs++;
        end

        // ---------------------------------------------------------------------
        // T3: Top-Level M_B_REG_TYPE=2 & M_R_REG_TYPE=2 Parameter Forwarding
        // ---------------------------------------------------------------------
        // Hold S0 bready=0 while issuing 2 writes to M0; with M_B_REG_TYPE=2 (skid), M0's B responses are buffered!
        @(posedge clk); #0.2;
        d1_s_bready[0] = 1'b0;
        d1_m0_manual_b = 1'b1;
        begin
            // Send 2 AW+W writes from S0 to M0 without waiting for B yet
            for (int k = 0; k < 2; k++) begin
                logic aw_d, w_d;
                aw_d = 0; w_d = 0;
                @(posedge clk); #0.2;
                d1_s_awaddr[31:0] = 32'h0000_0100 + k*4;
                d1_s_awprot[2:0]  = 3'b000;
                d1_s_awvalid[0]   = 1'b1;
                d1_s_wdata[31:0]  = 32'hB000_0000 + k;
                d1_s_wstrb[3:0]   = 4'hF;
                d1_s_wvalid[0]    = 1'b1;
                while (!(aw_d && w_d)) begin
                    @(posedge clk);
                    if (!aw_d && d1_s_awready[0]) aw_d = 1;
                    if (!w_d  && d1_s_wready[0])  w_d  = 1;
                    #0.2;
                    if (aw_d) d1_s_awvalid[0] = 0;
                    if (w_d)  d1_s_wvalid[0]  = 0;
                end
            end
            repeat (8) @(posedge clk);
            // With M_B_REG_TYPE=2 forwarded, M0's 2 B responses were accepted into M0's skid buffer (m0_b_q == 0)!
            // Without forwarding (default M_B_REG_TYPE=0), at most 0 or 1 B response could be accepted while s_bready=0!
            if (m0_b_q != 0) begin
                $display("FAIL [T3a M_B_REG_TYPE not forwarded]: m0_b_q=%0d (expected 0 absorbed into M_B skid buffer)", m0_b_q);
                errs++;
            end
            #0.2;
            d1_s_bready[0] = 1'b1;
            begin
                int b_got, g;
                b_got = 0; g = 0;
                while (b_got < 2 && g < 30) begin
                    @(posedge clk);
                    if (d1_s_bvalid[0] && d1_s_bready[0]) b_got++;
                    g++;
                end
                if (b_got != 2) begin
                    $display("FAIL [T3a B drain]: b_got=%0d", b_got);
                    errs++;
                end
            end
            #0.2;
            d1_m0_manual_b = 1'b0;
        end

        // Same check for M_R_REG_TYPE=2 forwarding on reads
        @(posedge clk); #0.2;
        d1_s_rready[0] = 1'b0;
        d1_m0_manual_r = 1'b1;
        begin
            for (int k = 0; k < 2; k++) begin
                @(posedge clk); #0.2;
                d1_s_araddr[31:0] = 32'h0000_0100 + k*4;
                d1_s_arprot[2:0]  = 3'b000;
                d1_s_arvalid[0]   = 1'b1;
                while (1) begin @(posedge clk); if (d1_s_arready[0]) break; end
                #0.2;
                d1_s_arvalid[0]   = 1'b0;
            end
            repeat (8) @(posedge clk);
            if (m0_r_q != 0) begin
                $display("FAIL [T3b M_R_REG_TYPE not forwarded]: m0_r_q=%0d (expected 0 absorbed into M_R skid buffer)", m0_r_q);
                errs++;
            end
            #0.2;
            d1_s_rready[0] = 1'b1;
            begin
                int r_got, g;
                r_got = 0; g = 0;
                while (r_got < 2 && g < 30) begin
                    @(posedge clk);
                    if (d1_s_rvalid[0] && d1_s_rready[0]) r_got++;
                    g++;
                end
                if (r_got != 2) begin
                    $display("FAIL [T3b R drain]: r_got=%0d", r_got);
                    errs++;
                end
            end
            #0.2;
            d1_m0_manual_r = 1'b0;
        end

        // ---------------------------------------------------------------------
        // T4: Non-Blocking Coupled Write Arbitration (AW-only S0 & W-only S1 MUST NOT block ready S2 on M3!)
        // ---------------------------------------------------------------------
        fork
            // S0 presents AW targeting coupled M3, delays W until S2 finishes 4 writes!
            begin : s0_aw_first
                logic aw_d, w_d;
                aw_d = 0; w_d = 0;
                @(posedge clk); #0.2;
                d1_s_awaddr[0 +: 32] = 32'h4000_2120;
                d1_s_awprot[0 +: 3]  = 3'b000;
                d1_s_awvalid[0]      = 1'b1;
                repeat (35) begin
                    @(posedge clk);
                    if (!aw_d && d1_s_awready[0]) begin aw_d = 1; #0.2; d1_s_awvalid[0] = 1'b0; end
                end
                #0.2;
                d1_s_wdata[0 +: 32] = 32'h5000_A0A0;
                d1_s_wstrb[0 +: 4]  = 4'hF;
                d1_s_wvalid[0]      = 1'b1;
                begin
                    int g = 0;
                    while (!(aw_d && w_d) && g < 100) begin
                        @(posedge clk);
                        if (!aw_d && d1_s_awready[0]) aw_d = 1;
                        if (!w_d  && d1_s_wready[0])  w_d  = 1;
                        #0.2;
                        if (aw_d) d1_s_awvalid[0] = 1'b0;
                        if (w_d)  d1_s_wvalid[0]  = 1'b0;
                        g++;
                    end
                    if (!(aw_d && w_d)) begin $display("FAIL [T4 S0 deadlock]"); errs++; end
                    g = 0;
                    while (g < 50) begin @(posedge clk); if (d1_s_bvalid[0]) break; g++; end
                end
            end

            // S1 presents W first, delays AW for 35 cycles!
            begin : s1_w_first
                logic aw_d, w_d;
                aw_d = 0; w_d = 0;
                @(posedge clk); #0.2;
                d1_s_wdata[32 +: 32] = 32'h5111_B1B1;
                d1_s_wstrb[4 +: 4]   = 4'hF;
                d1_s_wvalid[1]       = 1'b1;
                repeat (35) begin
                    @(posedge clk);
                    if (!w_d && d1_s_wready[1]) begin w_d = 1; #0.2; d1_s_wvalid[1] = 1'b0; end
                end
                #0.2;
                d1_s_awaddr[32 +: 32] = 32'h4000_2124;
                d1_s_awprot[3 +: 3]   = 3'b000;
                d1_s_awvalid[1]       = 1'b1;
                begin
                    int g = 0;
                    while (!(aw_d && w_d) && g < 100) begin
                        @(posedge clk);
                        if (!aw_d && d1_s_awready[1]) aw_d = 1;
                        if (!w_d  && d1_s_wready[1])  w_d  = 1;
                        #0.2;
                        if (aw_d) d1_s_awvalid[1] = 1'b0;
                        if (w_d)  d1_s_wvalid[1]  = 1'b0;
                        g++;
                    end
                    if (!(aw_d && w_d)) begin $display("FAIL [T4 S1 deadlock]"); errs++; end
                    g = 0;
                    while (g < 50) begin @(posedge clk); if (d1_s_bvalid[1]) break; g++; end
                end
            end

            // S2 waits 3 cycles (so S0's AW is already sitting at the crossbar!) and then issues 4 ready AW+W writes to M3!
            begin : s2_ready_burst
                logic [1:0] br;
                int t_start, t_elapsed;
                repeat (3) @(posedge clk);
                t_start = $time;
                for (int k = 0; k < 4; k++) begin
                    d1_write(2, 32'h4000_2130 + k*4, 3'b000, 32'h5222_0000 + k, br);
                    if (br !== 2'b00) begin
                        $display("FAIL [T4 S2 bresp]: %b", br);
                        errs++;
                    end
                end
                t_elapsed = ($time - t_start) / 4; // in cycles (4ns period)
                // Must finish WELL before cycle 35 when S0 finally asserts W!
                if (t_elapsed >= 45) begin
                    $display("FAIL [T4 S0 AW-only blocked ready S2!]: S2 took %0d cycles (>=30)", t_elapsed);
                    errs++;
                end
            end
        join

        // Verify all 6 writes (S0, S1, and S2x4) landed in M3 intact!
        d1_read(3, 32'h4000_2120, 3'b000, rdat, resp);
        if (rdat !== (32'hD300_0000 ^ 32'h5000_A0A0)) begin $display("FAIL [T4 verify S0]: %h", rdat); errs++; end
        d1_read(3, 32'h4000_2124, 3'b000, rdat, resp);
        if (rdat !== (32'hD300_0000 ^ 32'h5111_B1B1)) begin $display("FAIL [T4 verify S1]: %h", rdat); errs++; end
        d1_read(3, 32'h4000_213C, 3'b000, rdat, resp);
        if (rdat !== (32'hD300_0000 ^ 32'h5222_0003)) begin $display("FAIL [T4 verify S2]: %h", rdat); errs++; end

        // ---------------------------------------------------------------------
        // T5: DUT2 (6x6 Crossbar — M_CONNECT bit 35 & 34 > 32-bit shift!)
        // ---------------------------------------------------------------------
        // S5 -> M5 (bit 35): write & read must succeed!
        begin
            logic aw_d, w_d;
            int g;
            aw_d = 0; w_d = 0; g = 0;
            @(posedge clk); #0.2;
            d2_s_awaddr[5*32 +: 32] = 32'h5000_0010;
            d2_s_awvalid[5]         = 1'b1;
            d2_s_wdata[5*32 +: 32]  = 32'h6555_BEEF;
            d2_s_wvalid[5]          = 1'b1;
            while (!(aw_d && w_d) && g < 60) begin
                @(posedge clk);
                if (!aw_d && d2_s_awready[5]) aw_d = 1;
                if (!w_d  && d2_s_wready[5])  w_d  = 1;
                #0.2;
                if (aw_d) d2_s_awvalid[5] = 0;
                if (w_d)  d2_s_wvalid[5]  = 0;
                g++;
            end
            g = 0;
            while (!d2_s_bvalid[5] && g < 60) begin @(posedge clk); g++; end
            if (!d2_s_bvalid[5] || d2_s_bresp[5*2 +: 2] !== 2'b00) begin
                $display("FAIL [T5a 6x6 S5->M5 bit 35 wr]: bvalid=%b bresp=%b", d2_s_bvalid[5], d2_s_bresp[5*2 +: 2]);
                errs++;
            end

            // S3 -> M5 (bit 33): write disconnected -> DECERR; read connected -> OKAY!
            aw_d = 0; w_d = 0; g = 0;
            @(posedge clk); #0.2;
            d2_s_awaddr[3*32 +: 32] = 32'h5000_0010;
            d2_s_awvalid[3]         = 1'b1;
            d2_s_wdata[3*32 +: 32]  = 32'hDEAD_0033;
            d2_s_wvalid[3]          = 1'b1;
            while (!(aw_d && w_d) && g < 60) begin
                @(posedge clk);
                if (!aw_d && d2_s_awready[3]) aw_d = 1;
                if (!w_d  && d2_s_wready[3])  w_d  = 1;
                #0.2;
                if (aw_d) d2_s_awvalid[3] = 0;
                if (w_d)  d2_s_wvalid[3]  = 0;
                g++;
            end
            g = 0;
            while (!d2_s_bvalid[3] && g < 60) begin @(posedge clk); g++; end
            if (!d2_s_bvalid[3] || d2_s_bresp[3*2 +: 2] !== 2'b11) begin
                $display("FAIL [T5b 6x6 S3->M5 wr DECERR]: bresp=%b", d2_s_bresp[3*2 +: 2]);
                errs++;
            end

            // S3 -> M5 read (bit 33 connected!) -> must read S5's written value (NOT DEAD_0033)!
            @(posedge clk); #0.2;
            d2_s_araddr[3*32 +: 32] = 32'h5000_0010;
            d2_s_arvalid[3]         = 1'b1;
            g = 0;
            while (!d2_s_arready[3] && g < 60) begin @(posedge clk); g++; end
            #0.2; d2_s_arvalid[3] = 1'b0;
            g = 0;
            while (!d2_s_rvalid[3] && g < 60) begin @(posedge clk); g++; end
            if (d2_s_rresp[3*2 +: 2] !== 2'b00 || d2_s_rdata[3*32 +: 32] !== (32'h6555_BEEF ^ 32'h6605_0000)) begin
                $display("FAIL [T5c 6x6 S3->M5 rd]: rresp=%b rdata=%h", d2_s_rresp[3*2 +: 2], d2_s_rdata[3*32 +: 32]);
                errs++;
            end
        end

        // ---------------------------------------------------------------------
        // T6: DUT3 (1x3) & DUT4 (3x1) Edge Geometries + Unmapped DECERR
        // ---------------------------------------------------------------------
        begin
            logic aw_d, w_d;
            int g;
            // DUT3 1x3 read M2 (0x2000_0004) and unmapped 0x9000_0000 (DECERR)
            @(posedge clk); #0.2;
            d3_s_araddr = 32'h2000_0004; d3_s_arvalid = 1'b1;
            g = 0; while (!d3_s_arready && g < 40) begin @(posedge clk); g++; end
            #0.2; d3_s_arvalid = 1'b0;
            g = 0; while (!d3_s_rvalid && g < 40) begin @(posedge clk); g++; end
            if (d3_s_rresp !== 2'b00 || d3_s_rdata !== 32'h3333_0002) begin
                $display("FAIL [T6a 1x3 rd M2]: resp=%b rdat=%h", d3_s_rresp, d3_s_rdata); errs++;
            end

            @(posedge clk); #0.2;
            d3_s_araddr = 32'h9000_0000; d3_s_arvalid = 1'b1;
            g = 0; while (!d3_s_arready && g < 40) begin @(posedge clk); g++; end
            #0.2; d3_s_arvalid = 1'b0;
            g = 0; while (!d3_s_rvalid && g < 40) begin @(posedge clk); g++; end
            if (d3_s_rresp !== 2'b11 || d3_s_rdata !== 32'd0) begin
                $display("FAIL [T6b 1x3 DECERR]: resp=%b rdat=%h", d3_s_rresp, d3_s_rdata); errs++;
            end

            // DUT3 1x3 write M1
            aw_d = 0; w_d = 0; g = 0;
            @(posedge clk); #0.2;
            d3_s_awaddr = 32'h1000_0008; d3_s_awvalid = 1'b1;
            d3_s_wdata  = 32'h1234_5678; d3_s_wvalid  = 1'b1;
            while (!(aw_d && w_d) && g < 40) begin
                @(posedge clk);
                if (!aw_d && d3_s_awready) aw_d = 1;
                if (!w_d  && d3_s_wready)  w_d  = 1;
                #0.2;
                if (aw_d) d3_s_awvalid = 0;
                if (w_d)  d3_s_wvalid  = 0;
                g++;
            end
            g = 0; while (!d3_s_bvalid && g < 40) begin @(posedge clk); g++; end
            if (!d3_s_bvalid || d3_s_bresp !== 2'b00) begin
                $display("FAIL [T6c 1x3 wr M1]: bvalid=%b bresp=%b", d3_s_bvalid, d3_s_bresp); errs++;
            end

            // DUT4 3x1 write & read from S2
            aw_d = 0; w_d = 0; g = 0;
            @(posedge clk); #0.2;
            d4_s_awaddr[2*32 +: 32] = 32'h1000_0020; d4_s_awvalid[2] = 1'b1;
            d4_s_wdata[2*32 +: 32]  = 32'hABCD_EF01; d4_s_wvalid[2]  = 1'b1;
            while (!(aw_d && w_d) && g < 40) begin
                @(posedge clk);
                if (!aw_d && d4_s_awready[2]) aw_d = 1;
                if (!w_d  && d4_s_wready[2])  w_d  = 1;
                #0.2;
                if (aw_d) d4_s_awvalid[2] = 0;
                if (w_d)  d4_s_wvalid[2]  = 0;
                g++;
            end
            g = 0; while (!d4_s_bvalid[2] && g < 40) begin @(posedge clk); g++; end
            if (!d4_s_bvalid[2] || d4_s_bresp[2*2 +: 2] !== 2'b00) begin
                $display("FAIL [T6d 3x1 wr]: bvalid=%b bresp=%b", d4_s_bvalid[2], d4_s_bresp[2*2 +: 2]); errs++;
            end
        end

        // ---------------------------------------------------------------------
        // T7: Seeded Randomized Multi-Master Traffic Across Overlapping Regions
        // ---------------------------------------------------------------------
        for (int iter = 0; iter < 16; iter++) begin
            int s;
            int sel;
            logic [31:0] addr, wval, rval;
            logic [2:0]  prot;
            logic [1:0]  br, rr;
            s = next_rand() % 3; // S0..S2
            sel = next_rand() % 4;
            case (sel)
                0: begin addr = 32'h0100_0000 + ((next_rand() & 8'h3F) << 2); prot = 3'b000; end // M0 /32
                1: begin addr = 32'h4000_0100 + ((next_rand() & 8'h3F) << 2); prot = 3'b000; end // M1 /16
                2: begin addr = 32'h4000_1100 + ((next_rand() & 8'h3F) << 2); prot = (next_rand() & 1) ? 3'b010 : 3'b000; end // M2 SECURE
                default: begin addr = 32'h4000_2140 + ((next_rand() & 8'h1F) << 2); prot = 3'b000; end // M3 /8 coupled
            endcase
            wval = (next_rand() << 1) ^ 32'hA5A5_5A5A;
            d1_write(s, addr, prot, wval, br);
            if (sel == 2 && prot[1]) begin
                if (br !== 2'b11) begin $display("FAIL [T7 sec wr]: %b", br); errs++; end
            end else begin
                if (br !== 2'b00) begin $display("FAIL [T7 wr]: %b", br); errs++; end
                d1_read((s + 1) % 3, addr, 3'b000, rval, rr);
                if (rr !== 2'b00 || rval !== ((32'hD000_0000 | (sel << 24)) ^ wval)) begin
                    $display("FAIL [T7 rd mismatch]: sel=%0d got=%h exp=%h", sel, rval, (32'hD000_0000 | (sel << 24)) ^ wval);
                    errs++;
                end
            end
        end

        if (errs == 0) begin
            $display("PASS seed=%0d", SEED);
            $finish;
        end else begin
            $display("FAIL seed=%0d errs=%0d", SEED, errs);
            $stop;
        end
    end

endmodule
