`timescale 1ns / 1ps

module tb_gl;
    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg          rst = 1'b1;
    reg          s_hdr_v = 1'b0;
    wire         s_hdr_r;
    reg  [47:0]  s_dst = 48'd0, s_src = 48'd0;
    reg  [15:0]  s_type = 16'h0806;
    reg  [255:0] s_tdata = 256'd0;
    reg  [31:0]  s_tkeep = 32'd0;
    reg          s_tvalid = 1'b0, s_tlast = 1'b0, s_tuser = 1'b0;
    wire         s_tready;

    wire         m_hdr_v;
    reg          m_hdr_r = 1'b1;
    wire [47:0]  m_dst, m_src;
    wire [15:0]  m_type;
    wire [255:0] m_tdata;
    wire [31:0]  m_tkeep;
    wire         m_tvalid, m_tlast, m_tuser;
    reg          m_tready = 1'b1;

    reg          req_v = 1'b0;
    wire         req_r;
    reg  [31:0]  req_ip = 32'd0;
    wire         resp_v;
    reg          resp_r = 1'b1;
    wire         resp_err;
    wire [47:0]  resp_mac;

    reg  [47:0]  local_mac = 48'h02_AA_BB_CC_00_01;
    reg  [31:0]  local_ip  = 32'h0A_00_00_05;
    reg  [31:0]  gw_ip     = 32'h0A_00_00_01;
    reg  [31:0]  mask      = 32'hFF_FF_FF_00;
    reg          clr_cache = 1'b0;

    // 64-bit standalone rx ports inside gl_wrap
    reg          rx64_hdr_v = 1'b0;
    wire         rx64_hdr_r, rx64_tready, rx64_m_v, rx64_busy, rx64_err_e, rx64_err_i;
    reg  [63:0]  rx64_tdata = 64'd0;
    reg  [7:0]   rx64_tkeep = 8'd0;
    reg          rx64_tvalid = 1'b0, rx64_tlast = 1'b0, rx64_tuser = 1'b0;

    arp_gl_wrap dut (
        .clk(clk), .rst(rst),
        .s_eth_hdr_valid(s_hdr_v), .s_eth_hdr_ready(s_hdr_r),
        .s_eth_dest_mac(s_dst), .s_eth_src_mac(s_src), .s_eth_type(s_type),
        .s_eth_payload_axis_tdata(s_tdata), .s_eth_payload_axis_tkeep(s_tkeep),
        .s_eth_payload_axis_tvalid(s_tvalid), .s_eth_payload_axis_tready(s_tready),
        .s_eth_payload_axis_tlast(s_tlast), .s_eth_payload_axis_tuser(s_tuser),
        .m_eth_hdr_valid(m_hdr_v), .m_eth_hdr_ready(m_hdr_r),
        .m_eth_dest_mac(m_dst), .m_eth_src_mac(m_src), .m_eth_type(m_type),
        .m_eth_payload_axis_tdata(m_tdata), .m_eth_payload_axis_tkeep(m_tkeep),
        .m_eth_payload_axis_tvalid(m_tvalid), .m_eth_payload_axis_tready(m_tready),
        .m_eth_payload_axis_tlast(m_tlast), .m_eth_payload_axis_tuser(m_tuser),
        .arp_request_valid(req_v), .arp_request_ready(req_r), .arp_request_ip(req_ip),
        .arp_response_valid(resp_v), .arp_response_ready(resp_r),
        .arp_response_error(resp_err), .arp_response_mac(resp_mac),
        .local_mac(local_mac), .local_ip(local_ip), .gateway_ip(gw_ip),
        .subnet_mask(mask), .clear_cache(clr_cache),
        .rx64_hdr_v(rx64_hdr_v), .rx64_hdr_r(rx64_hdr_r),
        .rx64_tdata(rx64_tdata), .rx64_tkeep(rx64_tkeep),
        .rx64_tvalid(rx64_tvalid), .rx64_tready(rx64_tready),
        .rx64_tlast(rx64_tlast), .rx64_tuser(rx64_tuser),
        .rx64_m_v(rx64_m_v), .rx64_busy(rx64_busy),
        .rx64_err_e(rx64_err_e), .rx64_err_i(rx64_err_i)
    );

    reg post_rst = 1'b0;
    integer x_errs = 0;
    integer tx_pkts = 0;

    always @(posedge clk) begin
        if (post_rst && !rst) begin
            if (^ {s_hdr_r, s_tready, m_hdr_v, m_tvalid, req_r, resp_v,
                   rx64_hdr_r, rx64_tready, rx64_m_v, rx64_busy, rx64_err_e, rx64_err_i} === 1'bx) begin
                $display("FAIL_GL: X/Z on control/status outputs");
                x_errs <= x_errs + 1;
            end
            if (m_hdr_v === 1'b1 && (^{m_dst, m_src, m_type} === 1'bx)) begin
                $display("FAIL_GL: X/Z on m_eth_hdr qualifiers");
                x_errs <= x_errs + 1;
            end
            if (m_tvalid === 1'b1 && (^{m_tkeep, m_tlast, m_tuser, m_tdata[223:0]} === 1'bx)) begin
                $display("FAIL_GL: X/Z on m_eth_payload_axis qualifiers");
                x_errs <= x_errs + 1;
            end
            if (resp_v === 1'b1 && ((^resp_err === 1'bx) || (!resp_err && (^resp_mac === 1'bx)))) begin
                $display("FAIL_GL: X/Z on arp_response outputs err=%b mac=%h", resp_err, resp_mac);
                x_errs <= x_errs + 1;
            end
            if (m_tvalid === 1'b1 && m_tready && m_tlast) tx_pkts <= tx_pkts + 1;
        end
    end

    integer b, guard;
    reg [223:0] v;

    initial begin
        #25000;
        $display("FAIL_GL: watchdog timeout req_r=%b s_hdr_r=%b s_tready=%b resp_v=%b tx_pkts=%0d x_errs=%0d",
                 req_r, s_hdr_r, s_tready, resp_v, tx_pkts, x_errs);
        $finish;
    end

    initial begin
        rst = 1'b1;
        @(posedge clk);
        #1;
        if ({s_hdr_r, s_tready, m_hdr_v, m_tvalid, req_r, resp_v,
             rx64_hdr_r, rx64_tready, rx64_m_v, rx64_busy, rx64_err_e, rx64_err_i} !== 12'd0) begin
            $display("FAIL_GL: non-zero or X control outputs after 1-cycle synchronous reset: %b",
                     {s_hdr_r, s_tready, m_hdr_v, m_tvalid, req_r, resp_v,
                      rx64_hdr_r, rx64_tready, rx64_m_v, rx64_busy, rx64_err_e, rx64_err_i});
            x_errs = x_errs + 1;
        end
        rst = 1'b0;
        post_rst = 1'b1;
        repeat (10) @(posedge clk);
        #1;

        // 1) Uncached lookup for 10.0.0.22 -> broadcast request -> ARP reply -> hit!
        req_ip = 32'h0A_00_00_16;
        req_v  = 1'b1;
        guard = 0;
        while (req_r !== 1'b1) begin @(posedge clk); #1; guard = guard + 1; if (guard > 100) $finish; end
        @(posedge clk); #1; req_v = 1'b0;

        guard = 0;
        while (tx_pkts == 0) begin @(posedge clk); #1; guard = guard + 1; if (guard > 100) $finish; end

        v = {16'h0001, 16'h0800, 8'd6, 8'd4, 16'h0002,
             48'h02_DE_AD_BE_EF_16, 32'h0A_00_00_16, local_mac, local_ip};
        s_dst = local_mac; s_src = 48'h02_DE_AD_BE_EF_16; s_type = 16'h0806;
        s_hdr_v = 1'b1;
        while (s_hdr_r !== 1'b1) begin @(posedge clk); #1; end
        @(posedge clk); #1; s_hdr_v = 1'b0;

        s_tdata = 256'd0;
        for (b = 0; b < 28; b = b + 1) s_tdata[b*8 +: 8] = v[(27 - b)*8 +: 8];
        s_tkeep = 32'h0FFF_FFFF; s_tlast = 1'b1; s_tvalid = 1'b1;
        while (s_tready !== 1'b1) begin @(posedge clk); #1; end
        @(posedge clk); #1; s_tvalid = 1'b0; s_tlast = 1'b0;

        guard = 0;
        while (resp_v !== 1'b1) begin @(posedge clk); #1; guard = guard + 1; if (guard > 100) $finish; end
        if (resp_err !== 1'b0 || resp_mac !== 48'h02_DE_AD_BE_EF_16) begin
            $display("FAIL_GL: uncached lookup mismatch err=%b mac=%h", resp_err, resp_mac);
            x_errs = x_errs + 1;
        end
        @(posedge clk); #1;

        // 2) Cached lookup for 10.0.0.22 + timeout lookup for 10.0.0.99 (tests miss Zero-X!)
        req_ip = 32'h0A_00_00_16; req_v = 1'b1;
        while (req_r !== 1'b1) begin @(posedge clk); #1; end
        @(posedge clk); #1; req_v = 1'b0;
        while (resp_v !== 1'b1) begin @(posedge clk); #1; end
        if (resp_err !== 1'b0 || resp_mac !== 48'h02_DE_AD_BE_EF_16) x_errs = x_errs + 1;
        @(posedge clk); #1;

        req_ip = 32'h0A_00_00_63; req_v = 1'b1;
        while (req_r !== 1'b1) begin @(posedge clk); #1; end
        @(posedge clk); #1; req_v = 1'b0;
        guard = 0;
        while (resp_v !== 1'b1) begin @(posedge clk); #1; guard = guard + 1; if (guard > 200) $finish; end
        if (resp_err !== 1'b1) x_errs = x_errs + 1;
        repeat (6) @(posedge clk); #1;

        if (x_errs == 0)
            $display("PASS_GL: Zero-X gate-level ARP verification passed");
        else
            $display("FAIL_GL: %0d gate-level errors", x_errs);
        $finish;
    end
endmodule
