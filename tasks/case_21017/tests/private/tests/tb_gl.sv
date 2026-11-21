`timescale 1ns / 1ps

module tb_gl;

    int errs = 0;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #2 clk = ~clk;

    // Synthesized axil_crossbar_gl: S_COUNT=2, M_COUNT=3, M_REGIONS=2, M_SECURE=3'b010
    //   M0: R0 = 0x0000_0000 / 32 (global fallback), R1 = 0
    //   M1: R0 = 0x4000_1000 / 12 (SECURE),          R1 = 0
    //   M2: R0 = 0x4000_0000 / 16 (64KB),            R1 = 0x4000_2000 / 12 (coupled zero-slice)
    logic [2*32-1:0] s_awaddr = '0, s_wdata = '0, s_araddr = '0;
    logic [2*3-1:0]  s_awprot = '0, s_arprot = '0;
    logic [2*4-1:0]  s_wstrb  = {2{4'hF}};
    logic [1:0]      s_awvalid = '0, s_wvalid = '0, s_bready = 2'b11;
    wire  [1:0]      s_awready, s_wready, s_bvalid;
    wire  [2*2-1:0]  s_bresp;
    logic [1:0]      s_arvalid = '0, s_rready = 2'b11;
    wire  [1:0]      s_arready, s_rvalid;
    wire  [2*32-1:0] s_rdata;
    wire  [2*2-1:0]  s_rresp;

    wire  [3*32-1:0] m_awaddr, m_wdata, m_araddr;
    wire  [3*3-1:0]  m_awprot, m_arprot;
    wire  [3*4-1:0]  m_wstrb;
    wire  [2:0]      m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
    logic [2:0]      m_awready, m_wready, m_bvalid = '0, m_arready = 3'b111, m_rvalid = '0;
    logic [3*2-1:0]  m_bresp = '0, m_rresp = '0;
    logic [3*32-1:0] m_rdata = '0;

    axil_crossbar_gl u_dut (
        .clk(clk), .rst(rst),
        .s_axil_awaddr(s_awaddr), .s_axil_awprot(s_awprot), .s_axil_awvalid(s_awvalid), .s_axil_awready(s_awready),
        .s_axil_wdata(s_wdata), .s_axil_wstrb(s_wstrb), .s_axil_wvalid(s_wvalid), .s_axil_wready(s_wready),
        .s_axil_bresp(s_bresp), .s_axil_bvalid(s_bvalid), .s_axil_bready(s_bready),
        .s_axil_araddr(s_araddr), .s_axil_arprot(s_arprot), .s_axil_arvalid(s_arvalid), .s_axil_arready(s_arready),
        .s_axil_rdata(s_rdata), .s_axil_rresp(s_rresp), .s_axil_rvalid(s_rvalid), .s_axil_rready(s_rready),
        .m_axil_awaddr(m_awaddr), .m_axil_awprot(m_awprot), .m_axil_awvalid(m_awvalid), .m_axil_awready(m_awready),
        .m_axil_wdata(m_wdata), .m_axil_wstrb(m_wstrb), .m_axil_wvalid(m_wvalid), .m_axil_wready(m_wready),
        .m_axil_bresp(m_bresp), .m_axil_bvalid(m_bvalid), .m_axil_bready(m_bready),
        .m_axil_araddr(m_araddr), .m_axil_arprot(m_arprot), .m_axil_arvalid(m_arvalid), .m_axil_arready(m_arready),
        .m_axil_rdata(m_rdata), .m_axil_rresp(m_rresp), .m_axil_rvalid(m_rvalid), .m_axil_rready(m_rready)
    );

    logic mon_en = 1'b0;
    logic [2:0] got_aw = '0, got_w = '0;
    logic [31:0] last_val [0:2];

    always @* begin
        m_awready[0] = !rst;
        m_wready[0]  = !rst;
        m_awready[1] = !rst;
        m_wready[1]  = !rst;
        // M2 coupled zero-slice: waits for simultaneous m_awvalid[2] && m_wvalid[2]
        m_awready[2] = !rst && m_awvalid[2] && m_wvalid[2];
        m_wready[2]  = !rst && m_awvalid[2] && m_wvalid[2];
    end

    always @(posedge clk) begin
        if (mon_en) begin
            if ((^s_awready === 1'bx) || (^s_wready === 1'bx) || (^s_bvalid === 1'bx) ||
                (^s_arready === 1'bx) || (^s_rvalid === 1'bx) ||
                (^m_awvalid === 1'bx) || (^m_wvalid === 1'bx) || (^m_bready === 1'bx) ||
                (^m_arvalid === 1'bx) || (^m_rready === 1'bx)) begin
                $display("FAIL_GL [Zero-X]: s_awr=%b s_wr=%b s_bv=%b s_arr=%b s_rv=%b m_awv=%b m_wv=%b m_br=%b m_arv=%b m_rr=%b",
                         s_awready, s_wready, s_bvalid, s_arready, s_rvalid,
                         m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready);
                errs++;
            end
            for (int si = 0; si < 2; si++) begin
                if (s_bvalid[si] === 1'b1 && (^s_bresp[si*2 +: 2] === 1'bx)) begin
                    $display("FAIL_GL [bresp X]"); errs++;
                end
                if (s_rvalid[si] === 1'b1 && ((^s_rresp[si*2 +: 2] === 1'bx) || (^s_rdata[si*32 +: 32] === 1'bx))) begin
                    $display("FAIL_GL [rdata/rresp X]"); errs++;
                end
            end
        end

        if (!rst) begin
            for (int mi = 0; mi < 3; mi++) begin
                logic a, w;
                a = got_aw[mi] || (m_awvalid[mi] === 1'b1 && m_awready[mi]);
                w = got_w[mi]  || (m_wvalid[mi]  === 1'b1 && m_wready[mi]);
                if (m_wvalid[mi] === 1'b1 && m_wready[mi]) last_val[mi] <= m_wdata[mi*32 +: 32];
                if (m_bvalid[mi] && m_bready[mi] === 1'b1) m_bvalid[mi] <= 1'b0;
                if (a && w) begin
                    m_bvalid[mi] <= 1'b1;
                    got_aw[mi] <= 1'b0; got_w[mi] <= 1'b0;
                end else begin
                    got_aw[mi] <= a; got_w[mi] <= w;
                end
                if (m_rvalid[mi] && m_rready[mi] === 1'b1) m_rvalid[mi] <= 1'b0;
                if (m_arvalid[mi] === 1'b1 && m_arready[mi]) begin
                    m_rdata[mi*32 +: 32] <= last_val[mi] ^ (32'h1100_0000 * (mi + 1));
                    m_rvalid[mi] <= 1'b1;
                end
            end
        end
    end

    initial begin
        logic aw_d, w_d;
        int g;
        last_val[0] = 0; last_val[1] = 0; last_val[2] = 0;

        // Enable Zero-X check immediately after 1 synchronous reset clock edge!
        @(posedge clk); #0.2;
        mon_en = 1'b1;
        repeat (3) @(posedge clk); #0.2;
        rst = 1'b0;
        repeat (3) @(posedge clk);

        // 1. Write & read coupled M2 (0x4000_0020 -> M2 /16 over M0 /32)
        aw_d = 0; w_d = 0; g = 0;
        @(posedge clk); #0.2;
        s_awaddr[0 +: 32] = 32'h4000_0020; s_awprot[0 +: 3] = 3'b000; s_awvalid[0] = 1'b1;
        s_wdata[0 +: 32]  = 32'h7788_99AA; s_wvalid[0] = 1'b1;
        while (!(aw_d && w_d) && g < 60) begin
            @(posedge clk);
            if (!aw_d && s_awready[0] === 1'b1) aw_d = 1;
            if (!w_d  && s_wready[0]  === 1'b1) w_d  = 1;
            #0.2;
            if (aw_d) s_awvalid[0] = 0;
            if (w_d)  s_wvalid[0]  = 0;
            g++;
        end
        g = 0; while (s_bvalid[0] !== 1'b1 && g < 60) begin @(posedge clk); g++; end
        if (s_bvalid[0] !== 1'b1 || s_bresp[1:0] !== 2'b00) begin
            $display("FAIL_GL [wr M2]"); errs++;
        end

        @(posedge clk); #0.2;
        s_araddr[32 +: 32] = 32'h4000_0020; s_arprot[3 +: 3] = 3'b000; s_arvalid[1] = 1'b1;
        g = 0; while (s_arready[1] !== 1'b1 && g < 60) begin @(posedge clk); g++; end
        #0.2; s_arvalid[1] = 1'b0;
        g = 0; while (s_rvalid[1] !== 1'b1 && g < 60) begin @(posedge clk); g++; end
        if (s_rresp[3:2] !== 2'b00 || s_rdata[63:32] !== (32'h7788_99AA ^ 32'h3300_0000)) begin
            $display("FAIL_GL [rd M2]: rresp=%b rdata=%h", s_rresp[3:2], s_rdata[63:32]); errs++;
        end

        // 2. Non-secure access to M1 secure window (0x4000_1004, prot=3'b010) -> DECERR, must NOT leak to M2 or M0!
        aw_d = 0; w_d = 0; g = 0;
        @(posedge clk); #0.2;
        s_awaddr[0 +: 32] = 32'h4000_1004; s_awprot[0 +: 3] = 3'b010; s_awvalid[0] = 1'b1;
        s_wdata[0 +: 32]  = 32'hDEAD_BEEF; s_wvalid[0] = 1'b1;
        while (!(aw_d && w_d) && g < 60) begin
            @(posedge clk);
            if (!aw_d && s_awready[0] === 1'b1) aw_d = 1;
            if (!w_d  && s_wready[0]  === 1'b1) w_d  = 1;
            #0.2;
            if (aw_d) s_awvalid[0] = 0;
            if (w_d)  s_wvalid[0]  = 0;
            g++;
        end
        g = 0; while (s_bvalid[0] !== 1'b1 && g < 60) begin @(posedge clk); g++; end
        if (s_bresp[1:0] !== 2'b11 || last_val[1] !== 32'd0) begin
            $display("FAIL_GL [sec DECERR]: bresp=%b", s_bresp[1:0]); errs++;
        end

        repeat (4) @(posedge clk);
        if (errs == 0) begin
            $display("PASS_GL");
            $finish;
        end else begin
            $display("FAIL_GL errs=%0d", errs);
            $stop;
        end
    end

endmodule
