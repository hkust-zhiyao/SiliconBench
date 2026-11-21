`timescale 1ns / 1ps

module tb;
    parameter integer SEED = 101;

    reg clk = 1'b0;
    always #4 clk = ~clk;

    reg rst = 1'b1;
    integer fail_cnt = 0;

    reg [31:0] stim_rng;
    reg [31:0] bp_rng;

    function [31:0] lfsr_step(input [31:0] s);
        begin
            lfsr_step = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
        end
    endfunction

    // CRC-32 hash matching arp_cache lfsr (poly 0x04c11db7, reverse=1, init=0xffffffff)
    function [31:0] calc_ip_hash(input [31:0] ip);
        integer b;
        reg [31:0] crc;
        reg        fb;
        begin
            crc = 32'hFFFF_FFFF;
            // arp_cache feeds data_in[31:0] with REVERSE=1: bit 0..31 in little-endian bit order
            // Wait: we don't even need to guess bit order—Suite 2/3 can discover colliding IPs
            // empirically or via the read-only lfsr module itself!
            calc_ip_hash = crc ^ ip;
        end
    endfunction

    // Instantiate read-only lfsr helper to get exact bucket index in TB without guessing bit order
    reg  [31:0] tb_hash_ip = 32'd0;
    wire [31:0] tb_hash_out;
    lfsr #(
        .LFSR_WIDTH(32),
        .LFSR_POLY(32'h4c11db7),
        .LFSR_CONFIG("GALOIS"),
        .LFSR_FEED_FORWARD(0),
        .REVERSE(1),
        .DATA_WIDTH(32),
        .STYLE("AUTO")
    ) u_tb_hash (
        .data_in(tb_hash_ip),
        .state_in(32'hffffffff),
        .data_out(),
        .state_out(tb_hash_out)
    );

    // =========================================================================
    // DUT Set 1A: Standalone arp_eth_tx(64) & arp_eth_rx(64)
    // =========================================================================
    reg         tx64_s_valid = 1'b0;
    wire        tx64_s_ready;
    reg  [47:0] tx64_s_dst = 48'd0, tx64_s_src = 48'd0, tx64_s_sha = 48'd0, tx64_s_tha = 48'd0;
    reg  [15:0] tx64_s_type = 16'h0806, tx64_s_htype = 16'd1, tx64_s_ptype = 16'h0800, tx64_s_oper = 16'd1;
    reg  [31:0] tx64_s_spa = 32'd0, tx64_s_tpa = 32'd0;
    wire        tx64_m_hdr_valid;
    reg         tx64_m_hdr_ready = 1'b1;
    wire [47:0] tx64_m_dst, tx64_m_src;
    wire [15:0] tx64_m_type;
    wire [63:0] tx64_m_tdata;
    wire [7:0]  tx64_m_tkeep;
    wire        tx64_m_tvalid;
    reg         tx64_m_tready = 1'b1;
    wire        tx64_m_tlast, tx64_m_tuser;

    reg         rx64_mux_raw = 1'b0;
    reg         rx64_raw_hdr_v = 1'b0;
    reg  [47:0] rx64_raw_dst = 48'd0, rx64_raw_src = 48'd0;
    reg  [15:0] rx64_raw_type = 16'h0806;
    reg  [63:0] rx64_raw_tdata = 64'd0;
    reg  [7:0]  rx64_raw_tkeep = 8'd0;
    reg         rx64_raw_tvalid = 1'b0, rx64_raw_tlast = 1'b0, rx64_raw_tuser = 1'b0;

    wire        rx64_s_hdr_ready, rx64_s_tready;
    wire        rx64_m_valid;
    reg         rx64_m_ready = 1'b1;
    wire [47:0] rx64_m_dst, rx64_m_src, rx64_m_sha, rx64_m_tha;
    wire [15:0] rx64_m_type, rx64_m_htype, rx64_m_ptype, rx64_m_oper;
    wire [7:0]  rx64_m_hlen, rx64_m_plen;
    wire [31:0] rx64_m_spa, rx64_m_tpa;
    wire        rx64_busy, rx64_err_early, rx64_err_inv;

    arp_eth_tx #(.DATA_WIDTH(64)) u_tx64 (
        .clk(clk), .rst(rst),
        .s_frame_valid(tx64_s_valid), .s_frame_ready(tx64_s_ready),
        .s_eth_dest_mac(tx64_s_dst), .s_eth_src_mac(tx64_s_src), .s_eth_type(tx64_s_type),
        .s_arp_htype(tx64_s_htype), .s_arp_ptype(tx64_s_ptype), .s_arp_oper(tx64_s_oper),
        .s_arp_sha(tx64_s_sha), .s_arp_spa(tx64_s_spa), .s_arp_tha(tx64_s_tha), .s_arp_tpa(tx64_s_tpa),
        .m_eth_hdr_valid(tx64_m_hdr_valid), .m_eth_hdr_ready(rx64_mux_raw ? 1'b0 : rx64_s_hdr_ready),
        .m_eth_dest_mac(tx64_m_dst), .m_eth_src_mac(tx64_m_src), .m_eth_type(tx64_m_type),
        .m_eth_payload_axis_tdata(tx64_m_tdata), .m_eth_payload_axis_tkeep(tx64_m_tkeep),
        .m_eth_payload_axis_tvalid(tx64_m_tvalid), .m_eth_payload_axis_tready(rx64_mux_raw ? 1'b0 : rx64_s_tready),
        .m_eth_payload_axis_tlast(tx64_m_tlast), .m_eth_payload_axis_tuser(tx64_m_tuser),
        .busy()
    );

    arp_eth_rx #(.DATA_WIDTH(64)) u_rx64 (
        .clk(clk), .rst(rst),
        .s_eth_hdr_valid(rx64_mux_raw ? rx64_raw_hdr_v : tx64_m_hdr_valid),
        .s_eth_hdr_ready(rx64_s_hdr_ready),
        .s_eth_dest_mac(rx64_mux_raw ? rx64_raw_dst : tx64_m_dst),
        .s_eth_src_mac(rx64_mux_raw ? rx64_raw_src : tx64_m_src),
        .s_eth_type(rx64_mux_raw ? rx64_raw_type : tx64_m_type),
        .s_eth_payload_axis_tdata(rx64_mux_raw ? rx64_raw_tdata : tx64_m_tdata),
        .s_eth_payload_axis_tkeep(rx64_mux_raw ? rx64_raw_tkeep : tx64_m_tkeep),
        .s_eth_payload_axis_tvalid(rx64_mux_raw ? rx64_raw_tvalid : tx64_m_tvalid),
        .s_eth_payload_axis_tready(rx64_s_tready),
        .s_eth_payload_axis_tlast(rx64_mux_raw ? rx64_raw_tlast : tx64_m_tlast),
        .s_eth_payload_axis_tuser(rx64_mux_raw ? rx64_raw_tuser : tx64_m_tuser),
        .m_frame_valid(rx64_m_valid), .m_frame_ready(rx64_m_ready),
        .m_eth_dest_mac(rx64_m_dst), .m_eth_src_mac(rx64_m_src), .m_eth_type(rx64_m_type),
        .m_arp_htype(rx64_m_htype), .m_arp_ptype(rx64_m_ptype),
        .m_arp_hlen(rx64_m_hlen), .m_arp_plen(rx64_m_plen), .m_arp_oper(rx64_m_oper),
        .m_arp_sha(rx64_m_sha), .m_arp_spa(rx64_m_spa), .m_arp_tha(rx64_m_tha), .m_arp_tpa(rx64_m_tpa),
        .busy(rx64_busy),
        .error_header_early_termination(rx64_err_early),
        .error_invalid_header(rx64_err_inv)
    );

    // =========================================================================
    // DUT Set 1B: Standalone arp_eth_tx(256) & arp_eth_rx(256) (CYCLE_COUNT==1)
    // =========================================================================
    reg          tx256_s_valid = 1'b0;
    wire         tx256_s_ready;
    reg  [47:0]  tx256_s_dst = 48'd0, tx256_s_src = 48'd0, tx256_s_sha = 48'd0, tx256_s_tha = 48'd0;
    reg  [15:0]  tx256_s_type = 16'h0806, tx256_s_htype = 16'd1, tx256_s_ptype = 16'h0800, tx256_s_oper = 16'd1;
    reg  [31:0]  tx256_s_spa = 32'd0, tx256_s_tpa = 32'd0;
    wire         tx256_m_hdr_valid;
    wire [47:0]  tx256_m_dst, tx256_m_src;
    wire [15:0]  tx256_m_type;
    wire [255:0] tx256_m_tdata;
    wire [31:0]  tx256_m_tkeep;
    wire         tx256_m_tvalid, tx256_m_tlast, tx256_m_tuser;

    reg          rx256_mux_raw = 1'b0;
    reg          rx256_raw_hdr_v = 1'b0;
    reg  [47:0]  rx256_raw_dst = 48'd0, rx256_raw_src = 48'd0;
    reg  [15:0]  rx256_raw_type = 16'h0806;
    reg  [255:0] rx256_raw_tdata = 256'd0;
    reg  [31:0]  rx256_raw_tkeep = 32'd0;
    reg          rx256_raw_tvalid = 1'b0, rx256_raw_tlast = 1'b0, rx256_raw_tuser = 1'b0;

    wire         rx256_s_hdr_ready, rx256_s_tready;
    wire         rx256_m_valid;
    reg          rx256_m_ready = 1'b1;
    wire [47:0]  rx256_m_dst, rx256_m_src, rx256_m_sha, rx256_m_tha;
    wire [15:0]  rx256_m_type, rx256_m_htype, rx256_m_ptype, rx256_m_oper;
    wire [7:0]   rx256_m_hlen, rx256_m_plen;
    wire [31:0]  rx256_m_spa, rx256_m_tpa;
    wire         rx256_busy, rx256_err_early, rx256_err_inv;

    arp_eth_tx #(.DATA_WIDTH(256)) u_tx256 (
        .clk(clk), .rst(rst),
        .s_frame_valid(tx256_s_valid), .s_frame_ready(tx256_s_ready),
        .s_eth_dest_mac(tx256_s_dst), .s_eth_src_mac(tx256_s_src), .s_eth_type(tx256_s_type),
        .s_arp_htype(tx256_s_htype), .s_arp_ptype(tx256_s_ptype), .s_arp_oper(tx256_s_oper),
        .s_arp_sha(tx256_s_sha), .s_arp_spa(tx256_s_spa), .s_arp_tha(tx256_s_tha), .s_arp_tpa(tx256_s_tpa),
        .m_eth_hdr_valid(tx256_m_hdr_valid), .m_eth_hdr_ready(rx256_mux_raw ? 1'b0 : rx256_s_hdr_ready),
        .m_eth_dest_mac(tx256_m_dst), .m_eth_src_mac(tx256_m_src), .m_eth_type(tx256_m_type),
        .m_eth_payload_axis_tdata(tx256_m_tdata), .m_eth_payload_axis_tkeep(tx256_m_tkeep),
        .m_eth_payload_axis_tvalid(tx256_m_tvalid), .m_eth_payload_axis_tready(rx256_mux_raw ? 1'b0 : rx256_s_tready),
        .m_eth_payload_axis_tlast(tx256_m_tlast), .m_eth_payload_axis_tuser(tx256_m_tuser),
        .busy()
    );

    arp_eth_rx #(.DATA_WIDTH(256)) u_rx256 (
        .clk(clk), .rst(rst),
        .s_eth_hdr_valid(rx256_mux_raw ? rx256_raw_hdr_v : tx256_m_hdr_valid),
        .s_eth_hdr_ready(rx256_s_hdr_ready),
        .s_eth_dest_mac(rx256_mux_raw ? rx256_raw_dst : tx256_m_dst),
        .s_eth_src_mac(rx256_mux_raw ? rx256_raw_src : tx256_m_src),
        .s_eth_type(rx256_mux_raw ? rx256_raw_type : tx256_m_type),
        .s_eth_payload_axis_tdata(rx256_mux_raw ? rx256_raw_tdata : tx256_m_tdata),
        .s_eth_payload_axis_tkeep(rx256_mux_raw ? rx256_raw_tkeep : tx256_m_tkeep),
        .s_eth_payload_axis_tvalid(rx256_mux_raw ? rx256_raw_tvalid : tx256_m_tvalid),
        .s_eth_payload_axis_tready(rx256_s_tready),
        .s_eth_payload_axis_tlast(rx256_mux_raw ? rx256_raw_tlast : tx256_m_tlast),
        .s_eth_payload_axis_tuser(rx256_mux_raw ? rx256_raw_tuser : tx256_m_tuser),
        .m_frame_valid(rx256_m_valid), .m_frame_ready(rx256_m_ready),
        .m_eth_dest_mac(rx256_m_dst), .m_eth_src_mac(rx256_m_src), .m_eth_type(rx256_m_type),
        .m_arp_htype(rx256_m_htype), .m_arp_ptype(rx256_m_ptype),
        .m_arp_hlen(rx256_m_hlen), .m_arp_plen(rx256_m_plen), .m_arp_oper(rx256_m_oper),
        .m_arp_sha(rx256_m_sha), .m_arp_spa(rx256_m_spa), .m_arp_tha(rx256_m_tha), .m_arp_tpa(rx256_m_tpa),
        .busy(rx256_busy),
        .error_header_early_termination(rx256_err_early),
        .error_invalid_header(rx256_err_inv)
    );

    // =========================================================================
    // DUT Set 2: Standalone arp_cache (CACHE_ADDR_WIDTH=3)
    // =========================================================================
    reg         c_q_valid = 1'b0;
    wire        c_q_ready;
    reg  [31:0] c_q_ip = 32'd0;
    wire        c_r_valid;
    reg         c_r_ready = 1'b1;
    wire        c_r_error;
    wire [47:0] c_r_mac;
    reg         c_w_valid = 1'b0;
    wire        c_w_ready;
    reg  [31:0] c_w_ip = 32'd0;
    reg  [47:0] c_w_mac = 48'd0;
    reg         c_clear = 1'b0;

    arp_cache #(.CACHE_ADDR_WIDTH(3)) u_cache (
        .clk(clk), .rst(rst),
        .query_request_valid(c_q_valid), .query_request_ready(c_q_ready), .query_request_ip(c_q_ip),
        .query_response_valid(c_r_valid), .query_response_ready(c_r_ready),
        .query_response_error(c_r_error), .query_response_mac(c_r_mac),
        .write_request_valid(c_w_valid), .write_request_ready(c_w_ready),
        .write_request_ip(c_w_ip), .write_request_mac(c_w_mac),
        .clear_cache(c_clear)
    );

    // =========================================================================
    // DUT Set 3: Full arp(DATA_WIDTH=64, CACHE_ADDR_WIDTH=2, RETRY_COUNT=1)
    // =========================================================================
    reg         a64_s_hdr_v = 1'b0;
    wire        a64_s_hdr_r;
    reg  [47:0] a64_s_dst = 48'd0, a64_s_src = 48'd0;
    reg  [15:0] a64_s_type = 16'h0806;
    reg  [63:0] a64_s_tdata = 64'd0;
    reg  [7:0]  a64_s_tkeep = 8'd0;
    reg         a64_s_tvalid = 1'b0, a64_s_tlast = 1'b0, a64_s_tuser = 1'b0;
    wire        a64_s_tready;

    wire        a64_m_hdr_v;
    reg         a64_m_hdr_r = 1'b1;
    wire [47:0] a64_m_dst, a64_m_src;
    wire [15:0] a64_m_type;
    wire [63:0] a64_m_tdata;
    wire [7:0]  a64_m_tkeep;
    wire        a64_m_tvalid, a64_m_tlast, a64_m_tuser;
    reg         a64_m_tready = 1'b1;

    reg         a64_req_v = 1'b0;
    wire        a64_req_r;
    reg  [31:0] a64_req_ip = 32'd0;
    wire        a64_resp_v;
    reg         a64_resp_r = 1'b1;
    wire        a64_resp_err;
    wire [47:0] a64_resp_mac;

    reg  [47:0] a64_local_mac = 48'h02_AA_BB_CC_DD_01;
    reg  [31:0] a64_local_ip  = 32'hC0_A8_0A_05; // 192.168.10.5
    reg  [31:0] a64_gw_ip     = 32'hC0_A8_0A_01; // 192.168.10.1
    reg  [31:0] a64_mask      = 32'hFF_FF_FF_00; // /24
    reg         a64_clear     = 1'b0;

    arp #(
        .DATA_WIDTH(64),
        .CACHE_ADDR_WIDTH(2),
        .REQUEST_RETRY_COUNT(1),
        .REQUEST_RETRY_INTERVAL(12),
        .REQUEST_TIMEOUT(44)
    ) u_arp64 (
        .clk(clk), .rst(rst),
        .s_eth_hdr_valid(a64_s_hdr_v), .s_eth_hdr_ready(a64_s_hdr_r),
        .s_eth_dest_mac(a64_s_dst), .s_eth_src_mac(a64_s_src), .s_eth_type(a64_s_type),
        .s_eth_payload_axis_tdata(a64_s_tdata), .s_eth_payload_axis_tkeep(a64_s_tkeep),
        .s_eth_payload_axis_tvalid(a64_s_tvalid), .s_eth_payload_axis_tready(a64_s_tready),
        .s_eth_payload_axis_tlast(a64_s_tlast), .s_eth_payload_axis_tuser(a64_s_tuser),
        .m_eth_hdr_valid(a64_m_hdr_v), .m_eth_hdr_ready(a64_m_hdr_r),
        .m_eth_dest_mac(a64_m_dst), .m_eth_src_mac(a64_m_src), .m_eth_type(a64_m_type),
        .m_eth_payload_axis_tdata(a64_m_tdata), .m_eth_payload_axis_tkeep(a64_m_tkeep),
        .m_eth_payload_axis_tvalid(a64_m_tvalid), .m_eth_payload_axis_tready(a64_m_tready),
        .m_eth_payload_axis_tlast(a64_m_tlast), .m_eth_payload_axis_tuser(a64_m_tuser),
        .arp_request_valid(a64_req_v), .arp_request_ready(a64_req_r), .arp_request_ip(a64_req_ip),
        .arp_response_valid(a64_resp_v), .arp_response_ready(a64_resp_r),
        .arp_response_error(a64_resp_err), .arp_response_mac(a64_resp_mac),
        .local_mac(a64_local_mac), .local_ip(a64_local_ip),
        .gateway_ip(a64_gw_ip), .subnet_mask(a64_mask), .clear_cache(a64_clear)
    );

    // =========================================================================
    // DUT Set 4: Full arp(DATA_WIDTH=256, CACHE_ADDR_WIDTH=2, RETRY_COUNT=2)
    // =========================================================================
    reg          a256_s_hdr_v = 1'b0;
    wire         a256_s_hdr_r;
    reg  [47:0]  a256_s_dst = 48'd0, a256_s_src = 48'd0;
    reg  [15:0]  a256_s_type = 16'h0806;
    reg  [255:0] a256_s_tdata = 256'd0;
    reg  [31:0]  a256_s_tkeep = 32'd0;
    reg          a256_s_tvalid = 1'b0, a256_s_tlast = 1'b0, a256_s_tuser = 1'b0;
    wire         a256_s_tready;

    wire         a256_m_hdr_v;
    reg          a256_m_hdr_r = 1'b1;
    wire [47:0]  a256_m_dst, a256_m_src;
    wire [15:0]  a256_m_type;
    wire [255:0] a256_m_tdata;
    wire [31:0]  a256_m_tkeep;
    wire         a256_m_tvalid, a256_m_tlast, a256_m_tuser;
    reg          a256_m_tready = 1'b1;

    reg          a256_req_v = 1'b0;
    wire         a256_req_r;
    reg  [31:0]  a256_req_ip = 32'd0;
    wire         a256_resp_v;
    reg          a256_resp_r = 1'b1;
    wire         a256_resp_err;
    wire [47:0]  a256_resp_mac;

    reg  [47:0]  a256_local_mac = 48'h02_11_22_33_44_55;
    reg  [31:0]  a256_local_ip  = 32'h0A_00_00_05; // 10.0.0.5
    reg  [31:0]  a256_gw_ip     = 32'h0A_00_00_01; // 10.0.0.1
    reg  [31:0]  a256_mask      = 32'hFF_FF_FF_00;
    reg          a256_clear     = 1'b0;

    arp #(
        .DATA_WIDTH(256),
        .CACHE_ADDR_WIDTH(2),
        .REQUEST_RETRY_COUNT(2),
        .REQUEST_RETRY_INTERVAL(16),
        .REQUEST_TIMEOUT(32)
    ) u_arp256 (
        .clk(clk), .rst(rst),
        .s_eth_hdr_valid(a256_s_hdr_v), .s_eth_hdr_ready(a256_s_hdr_r),
        .s_eth_dest_mac(a256_s_dst), .s_eth_src_mac(a256_s_src), .s_eth_type(a256_s_type),
        .s_eth_payload_axis_tdata(a256_s_tdata), .s_eth_payload_axis_tkeep(a256_s_tkeep),
        .s_eth_payload_axis_tvalid(a256_s_tvalid), .s_eth_payload_axis_tready(a256_s_tready),
        .s_eth_payload_axis_tlast(a256_s_tlast), .s_eth_payload_axis_tuser(a256_s_tuser),
        .m_eth_hdr_valid(a256_m_hdr_v), .m_eth_hdr_ready(a256_m_hdr_r),
        .m_eth_dest_mac(a256_m_dst), .m_eth_src_mac(a256_m_src), .m_eth_type(a256_m_type),
        .m_eth_payload_axis_tdata(a256_m_tdata), .m_eth_payload_axis_tkeep(a256_m_tkeep),
        .m_eth_payload_axis_tvalid(a256_m_tvalid), .m_eth_payload_axis_tready(a256_m_tready),
        .m_eth_payload_axis_tlast(a256_m_tlast), .m_eth_payload_axis_tuser(a256_m_tuser),
        .arp_request_valid(a256_req_v), .arp_request_ready(a256_req_r), .arp_request_ip(a256_req_ip),
        .arp_response_valid(a256_resp_v), .arp_response_ready(a256_resp_r),
        .arp_response_error(a256_resp_err), .arp_response_mac(a256_resp_mac),
        .local_mac(a256_local_mac), .local_ip(a256_local_ip),
        .gateway_ip(a256_gw_ip), .subnet_mask(a256_mask), .clear_cache(a256_clear)
    );

    // =========================================================================
    // Scoreboards & Monitors (single-driver reset flags to satisfy Verilator)
    // =========================================================================
    reg  clr_rx_cnt = 1'b0;
    integer cnt_rx64_ok = 0, cnt_rx64_early = 0, cnt_rx64_inv = 0;
    integer cnt_rx256_ok = 0, cnt_rx256_early = 0, cnt_rx256_inv = 0;
    reg  [47:0] cap_rx64_sha, cap_rx256_sha;
    reg  [31:0] cap_rx64_spa, cap_rx256_spa, cap_rx64_tpa, cap_rx256_tpa;
    reg  [15:0] cap_rx64_oper, cap_rx256_oper;

    always @(posedge clk) begin
        if (rst || clr_rx_cnt) begin
            cnt_rx64_ok <= 0; cnt_rx64_early <= 0; cnt_rx64_inv <= 0;
            cnt_rx256_ok <= 0; cnt_rx256_early <= 0; cnt_rx256_inv <= 0;
        end else begin
            if (rx64_m_valid && rx64_m_ready) begin
                cnt_rx64_ok <= cnt_rx64_ok + 1;
                cap_rx64_oper <= rx64_m_oper;
                cap_rx64_sha  <= rx64_m_sha;
                cap_rx64_spa  <= rx64_m_spa;
                cap_rx64_tpa  <= rx64_m_tpa;
            end
            if (rx64_err_early) cnt_rx64_early <= cnt_rx64_early + 1;
            if (rx64_err_inv)   cnt_rx64_inv   <= cnt_rx64_inv + 1;

            if (rx256_m_valid && rx256_m_ready) begin
                cnt_rx256_ok <= cnt_rx256_ok + 1;
                cap_rx256_oper <= rx256_m_oper;
                cap_rx256_sha  <= rx256_m_sha;
                cap_rx256_spa  <= rx256_m_spa;
                cap_rx256_tpa  <= rx256_m_tpa;
            end
            if (rx256_err_early) cnt_rx256_early <= cnt_rx256_early + 1;
            if (rx256_err_inv)   cnt_rx256_inv   <= cnt_rx256_inv + 1;
        end
    end

    // Monitor TX frames emitted by u_arp64 and u_arp256
    reg  clr_a64_tx = 1'b0, clr_a256_tx = 1'b0;
    integer a64_tx_hdr_cnt = 0, a64_tx_pkt_cnt = 0, a64_beat_idx = 0;
    reg  [47:0] a64_tx_dst [0:15];
    reg  [15:0] a64_tx_oper[0:15];
    reg  [47:0] a64_tx_tha [0:15];
    reg  [31:0] a64_tx_tpa [0:15];
    integer     a64_tx_cyc [0:15];
    reg  [223:0] a64_cur_vec;

    integer a256_tx_hdr_cnt = 0, a256_tx_pkt_cnt = 0;
    reg  [47:0] a256_tx_dst [0:15];
    reg  [15:0] a256_tx_oper[0:15];
    reg  [47:0] a256_tx_tha [0:15];
    reg  [31:0] a256_tx_tpa [0:15];
    integer     a256_tx_cyc [0:15];

    integer cyc_now = 0;
    always @(posedge clk) if (rst) cyc_now <= 0; else cyc_now <= cyc_now + 1;

    always @(posedge clk) begin : mon_a64_tx
        integer b;
        if (rst || clr_a64_tx) begin
            a64_tx_hdr_cnt <= 0;
            a64_tx_pkt_cnt <= 0;
            a64_beat_idx   <= 0;
            a64_cur_vec    <= 224'd0;
        end else begin
            if (a64_m_hdr_v && a64_m_hdr_r) begin
                a64_tx_dst[a64_tx_hdr_cnt] <= a64_m_dst;
                a64_tx_hdr_cnt <= a64_tx_hdr_cnt + 1;
            end
            if (a64_m_tvalid && a64_m_tready) begin
                for (b = 0; b < 8; b = b + 1) begin
                    if (a64_m_tkeep[b] && (a64_beat_idx * 8 + b < 28)) begin
                        a64_cur_vec[(27 - (a64_beat_idx * 8 + b))*8 +: 8] = a64_m_tdata[b*8 +: 8];
                    end
                end
                if (a64_m_tlast) begin
                    a64_tx_oper[a64_tx_pkt_cnt] <= a64_cur_vec[175:160];
                    a64_tx_tha[a64_tx_pkt_cnt]  <= a64_cur_vec[79:32];
                    a64_tx_tpa[a64_tx_pkt_cnt]  <= a64_cur_vec[31:0];
                    a64_tx_cyc[a64_tx_pkt_cnt]  <= cyc_now;
                    a64_tx_pkt_cnt <= a64_tx_pkt_cnt + 1;
                    a64_beat_idx <= 0;
                end else begin
                    a64_beat_idx <= a64_beat_idx + 1;
                end
            end
        end
    end

    integer mon_fail_cnt = 0;
    always @(posedge clk) begin : mon_a256_tx
        integer b;
        reg [223:0] v256;
        if (rst || clr_a256_tx) begin
            a256_tx_hdr_cnt <= 0;
            a256_tx_pkt_cnt <= 0;
        end else begin
            if (a256_m_hdr_v && a256_m_hdr_r) begin
                a256_tx_dst[a256_tx_hdr_cnt] <= a256_m_dst;
                a256_tx_hdr_cnt <= a256_tx_hdr_cnt + 1;
            end
            if (a256_m_tvalid && a256_m_tready) begin
                v256 = 224'd0;
                for (b = 0; b < 28; b = b + 1) begin
                    v256[(27 - b)*8 +: 8] = a256_m_tdata[b*8 +: 8];
                end
                if (a256_m_tkeep != 32'h0FFF_FFFF || !a256_m_tlast || a256_m_tuser) begin
                    $display("FAIL: u_arp256 TX beat keep=%h last=%b user=%b", a256_m_tkeep, a256_m_tlast, a256_m_tuser);
                    mon_fail_cnt <= mon_fail_cnt + 1;
                end
                a256_tx_oper[a256_tx_pkt_cnt] <= v256[175:160];
                a256_tx_tha[a256_tx_pkt_cnt]  <= v256[79:32];
                a256_tx_tpa[a256_tx_pkt_cnt]  <= v256[31:0];
                a256_tx_cyc[a256_tx_pkt_cnt]  <= cyc_now;
                a256_tx_pkt_cnt <= a256_tx_pkt_cnt + 1;
            end
        end
    end

    // =========================================================================
    // BFM Helper Tasks (all driven at #1 after posedge clk for Icarus/Verilator parity)
    // =========================================================================
    task pulse_clr_rx;
        begin
            clr_rx_cnt = 1'b1;
            @(posedge clk); #1;
            clr_rx_cnt = 1'b0;
        end
    endtask

    task pulse_clr_a64_tx;
        begin
            clr_a64_tx = 1'b1;
            @(posedge clk); #1;
            clr_a64_tx = 1'b0;
        end
    endtask

    task pulse_clr_a256_tx;
        begin
            clr_a256_tx = 1'b1;
            @(posedge clk); #1;
            clr_a256_tx = 1'b0;
        end
    endtask

    function [223:0] pack_arp(
        input [15:0] htype, input [15:0] ptype,
        input [7:0]  hlen,  input [7:0]  plen,
        input [15:0] oper,
        input [47:0] sha,   input [31:0] spa,
        input [47:0] tha,   input [31:0] tpa
    );
        begin
            pack_arp = {htype, ptype, hlen, plen, oper, sha, spa, tha, tpa};
        end
    endfunction

    task send_arp64_frame(
        input [47:0] dst_mac, input [47:0] src_mac, input [15:0] etype,
        input [223:0] arp_vec,
        input integer total_bytes, // >= 28 for normal/padded
        input integer tuser_beat
    );
        integer idx, rem, b, beat_no, guard;
        begin
            a64_s_dst = dst_mac;
            a64_s_src = src_mac;
            a64_s_type = etype;
            a64_s_hdr_v = 1'b1;
            guard = 0;
            while (!a64_s_hdr_r) begin
                @(posedge clk); #1;
                guard = guard + 1;
                if (guard > 400) begin $display("FAIL: a64_s_hdr_r timeout"); $finish; end
            end
            @(posedge clk); #1;
            a64_s_hdr_v = 1'b0;

            idx = 0;
            beat_no = 0;
            while (idx < total_bytes) begin
                rem = total_bytes - idx;
                a64_s_tdata = 64'd0;
                a64_s_tkeep = 8'd0;
                for (b = 0; b < 8; b = b + 1) begin
                    if (idx + b < total_bytes) begin
                        a64_s_tkeep[b] = 1'b1;
                        if (idx + b < 28)
                            a64_s_tdata[b*8 +: 8] = arp_vec[(27 - (idx + b))*8 +: 8];
                        else
                            a64_s_tdata[b*8 +: 8] = 8'hAA ^ b[7:0];
                    end
                end
                a64_s_tlast  = (rem <= 8);
                a64_s_tuser  = (beat_no == tuser_beat);
                a64_s_tvalid = 1'b1;
                guard = 0;
                while (!a64_s_tready) begin
                    @(posedge clk); #1;
                    guard = guard + 1;
                    if (guard > 400) begin $display("FAIL: a64_s_tready timeout"); $finish; end
                end
                @(posedge clk); #1;
                idx = idx + 8;
                beat_no = beat_no + 1;
            end
            a64_s_tvalid = 1'b0;
            a64_s_tlast  = 1'b0;
            a64_s_tuser  = 1'b0;
        end
    endtask

    task send_arp256_frame(
        input [47:0] dst_mac, input [47:0] src_mac, input [15:0] etype,
        input [223:0] arp_vec,
        input integer total_bytes
    );
        integer idx, rem, b, guard;
        begin
            a256_s_dst = dst_mac;
            a256_s_src = src_mac;
            a256_s_type = etype;
            a256_s_hdr_v = 1'b1;
            guard = 0;
            while (!a256_s_hdr_r) begin
                @(posedge clk); #1;
                guard = guard + 1;
                if (guard > 400) begin $display("FAIL: a256_s_hdr_r timeout"); $finish; end
            end
            @(posedge clk); #1;
            a256_s_hdr_v = 1'b0;

            idx = 0;
            while (idx < total_bytes) begin
                rem = total_bytes - idx;
                a256_s_tdata = 256'd0;
                a256_s_tkeep = 32'd0;
                for (b = 0; b < 32; b = b + 1) begin
                    if (idx + b < total_bytes) begin
                        a256_s_tkeep[b] = 1'b1;
                        if (idx + b < 28)
                            a256_s_tdata[b*8 +: 8] = arp_vec[(27 - (idx + b))*8 +: 8];
                        else
                            a256_s_tdata[b*8 +: 8] = 8'h55 ^ b[7:0];
                    end
                end
                a256_s_tlast  = (rem <= 32);
                a256_s_tuser  = 1'b0;
                a256_s_tvalid = 1'b1;
                guard = 0;
                while (!a256_s_tready) begin
                    @(posedge clk); #1;
                    guard = guard + 1;
                    if (guard > 400) begin $display("FAIL: a256_s_tready timeout"); $finish; end
                end
                @(posedge clk); #1;
                idx = idx + 32;
            end
            a256_s_tvalid = 1'b0;
            a256_s_tlast  = 1'b0;
        end
    endtask

    task do_arp64_lookup(
        input  [31:0] req_ip,
        input  integer stall_resp_cycles,
        output        out_err,
        output [47:0] out_mac,
        output integer elapsed_cycles
    );
        integer guard, k, t0;
        reg        first_err;
        reg [47:0] first_mac;
        begin
            a64_resp_r = (stall_resp_cycles == 0);
            a64_req_ip = req_ip;
            a64_req_v  = 1'b1;
            guard = 0;
            while (!a64_req_r) begin
                @(posedge clk); #1;
                guard = guard + 1;
                if (guard > 400) begin $display("FAIL: a64_req_r timeout"); $finish; end
            end
            t0 = cyc_now;
            @(posedge clk); #1;
            a64_req_v = 1'b0;

            guard = 0;
            while (!a64_resp_v) begin
                @(posedge clk); #1;
                guard = guard + 1;
                if (guard > 600) begin $display("FAIL: a64_resp_v timeout"); $finish; end
            end
            elapsed_cycles = cyc_now - t0;
            first_err = a64_resp_err;
            first_mac = a64_resp_mac;
            for (k = 0; k < stall_resp_cycles; k = k + 1) begin
                @(posedge clk); #1;
                if (!a64_resp_v || (a64_resp_err !== first_err) || (a64_resp_mac !== first_mac)) begin
                    $display("FAIL: a64_resp mutated while ready=0: v=%b err=%b(was %b) mac=%h(was %h)",
                             a64_resp_v, a64_resp_err, first_err, a64_resp_mac, first_mac);
                    fail_cnt = fail_cnt + 1;
                end
            end
            a64_resp_r = 1'b1;
            out_err = a64_resp_err;
            out_mac = a64_resp_mac;
            @(posedge clk); #1;
        end
    endtask

    // =========================================================================
    // Main Verification Stimulus
    // =========================================================================
    integer i, j, guard, elapsed;
    reg        got_err;
    reg [47:0] got_mac;
    reg [223:0] v_pkt;
    reg [2:0]   bkt_host_a3;
    reg [1:0]   bkt_host_a2;
    reg [31:0]  coll_ip_cache, coll_ip_arp;

    initial begin
        #250000;
        $display("FAIL: Global simulation watchdog timeout at %0t", $time);
        $finish;
    end

    initial begin
        stim_rng = SEED ^ 32'hA5A5_5A5A;
        if (stim_rng == 32'd0) stim_rng = 32'h1;
        bp_rng = (SEED * 32'd1664525) ^ 32'h5A5A_A5A5;
        if (bp_rng == 32'd0) bp_rng = 32'h3;

        rst = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        rst = 1'b0;
        // Wait for post-rst cache clear sweeps (max 2**3 = 8 cycles)
        repeat (16) @(posedge clk);
        #1;

        // ---------------------------------------------------------------------
        // Suite 1: arp_eth_tx & arp_eth_rx across DATA_WIDTH=64 & DATA_WIDTH=256
        // ---------------------------------------------------------------------
        // 1A: Round-trip tx->rx at DATA_WIDTH=64 and DATA_WIDTH=256
        pulse_clr_rx();
        for (i = 0; i < 6; i = i + 1) begin
            stim_rng = lfsr_step(stim_rng);
            tx64_s_dst   = {8'h02, stim_rng, i[7:0]};
            tx64_s_src   = {8'h06, ~stim_rng, i[7:0]};
            tx64_s_oper  = (i[0]) ? 16'h0002 : 16'h0001;
            tx64_s_sha   = {8'h02, stim_rng ^ 32'h11223344, i[7:0]};
            tx64_s_spa   = 32'h0A010010 + i;
            tx64_s_tha   = {8'h0A, stim_rng ^ 32'h55667788, i[7:0]};
            tx64_s_tpa   = 32'h0A010080 + i;
            tx64_s_valid = 1'b1;
            while (!tx64_s_ready) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            tx64_s_valid = 1'b0;

            tx256_s_dst   = tx64_s_dst;
            tx256_s_src   = tx64_s_src;
            tx256_s_oper  = tx64_s_oper;
            tx256_s_sha   = tx64_s_sha;
            tx256_s_spa   = tx64_s_spa;
            tx256_s_tha   = tx64_s_tha;
            tx256_s_tpa   = tx64_s_tpa;
            tx256_s_valid = 1'b1;
            while (!tx256_s_ready) begin @(posedge clk); #1; end
            @(posedge clk); #1;
            tx256_s_valid = 1'b0;

            repeat (10) @(posedge clk); #1;
            if (cnt_rx64_ok != (i + 1) || cnt_rx256_ok != (i + 1) ||
                cap_rx64_sha != tx64_s_sha || cap_rx256_sha != tx256_s_sha ||
                cap_rx64_spa != tx64_s_spa || cap_rx256_spa != tx256_s_spa ||
                cap_rx64_tpa != tx64_s_tpa || cap_rx256_tpa != tx256_s_tpa) begin
                $display("FAIL: Suite1A roundtrip i=%0d c64=%0d c256=%0d", i, cnt_rx64_ok, cnt_rx256_ok);
                fail_cnt = fail_cnt + 1;
            end
        end

        // 1B: Raw L2-padded frames + busy holding until tlast + early tuser + tkeep hole wrap check
        rx64_mux_raw  = 1'b1;
        rx256_mux_raw = 1'b1;
        pulse_clr_rx();

        // Padded 64B payload on u_rx256 (2 beats: beat 0 full 32B, beat 1 full 32B pad) — busy must stay 1 on beat 1!
        v_pkt = pack_arp(16'h0001, 16'h0800, 8'd6, 8'd4, 16'h0002,
                         48'h02_AA_11_22_33_44, 32'hC0A80150, 48'h02_BB_55_66_77_88, 32'hC0A80151);
        rx256_raw_dst = 48'h02_BB_55_66_77_88; rx256_raw_src = 48'h02_AA_11_22_33_44; rx256_raw_type = 16'h0806;
        rx256_raw_hdr_v = 1'b1;
        while (!rx256_s_hdr_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        rx256_raw_hdr_v = 1'b0;

        rx256_raw_tdata = 256'hDEADBEEF_00000000_00000000_00000000_00000000_00000000_00000000_00000000;
        for (j = 0; j < 28; j = j + 1) rx256_raw_tdata[j*8 +: 8] = v_pkt[(27 - j)*8 +: 8];
        rx256_raw_tkeep = 32'hFFFF_FFFF; rx256_raw_tlast = 1'b0; rx256_raw_tuser = 1'b0; rx256_raw_tvalid = 1'b1;
        while (!rx256_s_tready) begin @(posedge clk); #1; end
        if (!rx256_busy) begin $display("FAIL: Suite1B rx256_busy low on beat0"); fail_cnt = fail_cnt + 1; end
        @(posedge clk); #1;
        // Beat 1 is pure L2 pad — rx256_busy MUST still be high!
        if (!rx256_busy) begin $display("FAIL: Suite1B rx256_busy dropped before pad tlast"); fail_cnt = fail_cnt + 1; end
        rx256_raw_tdata = {32{8'hEE}}; rx256_raw_tkeep = 32'hFFFF_FFFF; rx256_raw_tlast = 1'b1;
        while (!rx256_s_tready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        rx256_raw_tvalid = 1'b0; rx256_raw_tlast = 1'b0;
        repeat (3) @(posedge clk); #1;
        if (cnt_rx256_ok != 1 || cap_rx256_spa != 32'hC0A80150 || cap_rx256_tpa != 32'hC0A80151 || rx256_busy) begin
            $display("FAIL: Suite1B rx256 padded ok=%0d spa=%h busy=%b", cnt_rx256_ok, cap_rx256_spa, rx256_busy);
            fail_cnt = fail_cnt + 1;
        end

        // 1C: Early tuser on beat 0 followed by clean pad beat on u_rx256 -> must drop silently (0 ok, 0 err)
        pulse_clr_rx();
        rx256_raw_hdr_v = 1'b1;
        while (!rx256_s_hdr_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1; rx256_raw_hdr_v = 1'b0;
        for (j = 0; j < 28; j = j + 1) rx256_raw_tdata[j*8 +: 8] = v_pkt[(27 - j)*8 +: 8];
        rx256_raw_tkeep = 32'hFFFF_FFFF; rx256_raw_tlast = 1'b0; rx256_raw_tuser = 1'b1; rx256_raw_tvalid = 1'b1;
        while (!rx256_s_tready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        rx256_raw_tuser = 1'b0; rx256_raw_tlast = 1'b1;
        while (!rx256_s_tready) begin @(posedge clk); #1; end
        @(posedge clk); #1; rx256_raw_tvalid = 1'b0; rx256_raw_tlast = 1'b0;
        repeat (3) @(posedge clk); #1;
        if (cnt_rx256_ok != 0 || cnt_rx256_early != 0 || cnt_rx256_inv != 0) begin
            $display("FAIL: Suite1C early tuser ok=%0d early=%0d inv=%0d", cnt_rx256_ok, cnt_rx256_early, cnt_rx256_inv);
            fail_cnt = fail_cnt + 1;
        end

        // 1D: tkeep hole on beat 3 (tkeep=8'h07, tlast=0) followed by 4 full beats on u_rx64 -> must NOT wrap ptr_reg!
        pulse_clr_rx();
        rx64_raw_hdr_v = 1'b1;
        while (!rx64_s_hdr_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1; rx64_raw_hdr_v = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            rx64_raw_tdata = 64'd0;
            for (j = 0; j < 8; j = j + 1) begin
                if ((i % 4)*8 + j < 28)
                    rx64_raw_tdata[j*8 +: 8] = v_pkt[(27 - ((i % 4)*8 + j))*8 +: 8];
            end
            rx64_raw_tkeep  = (i == 3) ? 8'h07 : 8'hFF;
            rx64_raw_tlast  = (i == 7);
            rx64_raw_tuser  = 1'b0;
            rx64_raw_tvalid = 1'b1;
            while (!rx64_s_tready) begin @(posedge clk); #1; end
            @(posedge clk); #1;
        end
        rx64_raw_tvalid = 1'b0; rx64_raw_tlast = 1'b0;
        repeat (3) @(posedge clk); #1;
        if (cnt_rx64_ok != 0 || cnt_rx64_early != 1 || cnt_rx64_inv != 0) begin
            $display("FAIL: Suite1D rx64 tkeep hole wrap ok=%0d early=%0d inv=%0d", cnt_rx64_ok, cnt_rx64_early, cnt_rx64_inv);
            fail_cnt = fail_cnt + 1;
        end

        // 1E: Invalid HLEN/PLEN on u_rx256 -> error_invalid_header
        pulse_clr_rx();
        v_pkt = pack_arp(16'h0001, 16'h0800, 8'd8, 8'd4, 16'h0001,
                         48'h02_AA_11_22_33_44, 32'hC0A80150, 48'd0, 32'hC0A80151);
        rx256_raw_hdr_v = 1'b1;
        while (!rx256_s_hdr_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1; rx256_raw_hdr_v = 1'b0;
        for (j = 0; j < 28; j = j + 1) rx256_raw_tdata[j*8 +: 8] = v_pkt[(27 - j)*8 +: 8];
        rx256_raw_tkeep = 32'h0FFF_FFFF; rx256_raw_tlast = 1'b1; rx256_raw_tuser = 1'b0; rx256_raw_tvalid = 1'b1;
        while (!rx256_s_tready) begin @(posedge clk); #1; end
        @(posedge clk); #1; rx256_raw_tvalid = 1'b0; rx256_raw_tlast = 1'b0;
        repeat (3) @(posedge clk); #1;
        if (cnt_rx256_ok != 0 || cnt_rx256_early != 0 || cnt_rx256_inv != 1) begin
            $display("FAIL: Suite1E invalid hlen ok=%0d inv=%0d", cnt_rx256_ok, cnt_rx256_inv);
            fail_cnt = fail_cnt + 1;
        end

        // ---------------------------------------------------------------------
        // Suite 2: arp_cache Stalled Response, Same-Cycle Write->Query & Clear
        // ---------------------------------------------------------------------
        // Find a 3-bit hash collision with 32'h0A_10_00_01
        tb_hash_ip = 32'h0A_10_00_01; #1; bkt_host_a3 = tb_hash_out[2:0];
        coll_ip_cache = 32'd0;
        for (i = 2; i < 64; i = i + 1) begin
            if (coll_ip_cache == 32'd0) begin
                tb_hash_ip = 32'h0A_10_00_00 + i; #1;
                if (tb_hash_out[2:0] == bkt_host_a3) coll_ip_cache = 32'h0A_10_00_00 + i;
            end
        end

        // 2A: Same-cycle write + query to 32'h0A_10_00_01 -> must HIT with 48'h02_00_00_AA_BB_01!
        c_w_ip = 32'h0A_10_00_01; c_w_mac = 48'h02_00_00_AA_BB_01; c_w_valid = 1'b1;
        c_q_ip = 32'h0A_10_00_01; c_q_valid = 1'b1; c_r_ready = 1'b0;
        while (!(c_w_ready && c_q_ready)) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        c_w_valid = 1'b0;
        // Issue a 2nd query immediately while c_r_ready == 0, then drop c_q_valid = 0!
        c_w_ip = 32'h0A_10_00_7F; c_w_mac = 48'h02_00_00_AA_BB_7F;
        // Wait 1 cycle to ensure different bucket or miss test: query uncached 32'h0A_99_99_99
        c_q_ip = 32'h0A_99_99_99;
        while (!c_q_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        c_q_valid = 1'b0;

        // Wait for 1st response and hold c_r_ready=0 for 6 cycles: must stay error=0, mac=02_00_00_AA_BB_01!
        while (!c_r_valid) begin @(posedge clk); #1; end
        for (i = 0; i < 6; i = i + 1) begin
            if (!c_r_valid || c_r_error || (c_r_mac != 48'h02_00_00_AA_BB_01)) begin
                $display("FAIL: Suite2A stalled resp0 corrupted cyc=%0d v=%b err=%b mac=%h", i, c_r_valid, c_r_error, c_r_mac);
                fail_cnt = fail_cnt + 1;
            end
            @(posedge clk); #1;
        end
        c_r_ready = 1'b1;
        @(posedge clk); #1;
        // Now 2nd queued query (32'h0A_99_99_99) must arrive with error=1!
        guard = 0;
        while (!c_r_valid) begin @(posedge clk); #1; guard = guard + 1; if (guard > 20) $finish; end
        if (!c_r_error) begin $display("FAIL: Suite2A 2nd queued query expected miss"); fail_cnt = fail_cnt + 1; end
        @(posedge clk); #1;

        // 2B: Same-cycle colliding write (coll_ip_cache) + query for old IP (32'h0A_10_00_01) -> must MISS!
        c_w_ip = coll_ip_cache; c_w_mac = 48'h02_00_00_CC_DD_EE; c_w_valid = 1'b1;
        c_q_ip = 32'h0A_10_00_01; c_q_valid = 1'b1;
        while (!(c_w_ready && c_q_ready)) begin @(posedge clk); #1; end
        @(posedge clk); #1; c_w_valid = 1'b0; c_q_valid = 1'b0;
        while (!c_r_valid) begin @(posedge clk); #1; end
        if (!c_r_error) begin $display("FAIL: Suite2B colliding same-cycle write did not evict old IP"); fail_cnt = fail_cnt + 1; end
        @(posedge clk); #1;

        // 2C: Simultaneous clear_cache=1 + write_request_valid=1 -> ready must drop immediately!
        c_clear = 1'b1; c_w_ip = 32'h0A_10_00_01; c_w_mac = 48'h02_12_34_56_78_9A; c_w_valid = 1'b1;
        #1;
        if (c_w_ready || c_q_ready) begin
            $display("FAIL: Suite2C ready high during clear_cache assertion (w_r=%b q_r=%b)", c_w_ready, c_q_ready);
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk); #1;
        c_clear = 1'b0;
        // Hold c_w_valid until clear sweep finishes and accepts it!
        guard = 0;
        while (!c_w_ready) begin @(posedge clk); #1; guard = guard + 1; if (guard > 30) $finish; end
        @(posedge clk); #1; c_w_valid = 1'b0;
        // Verify accepted post-clear write hits, while pre-clear coll_ip_cache was cleared!
        // Hold c_r_ready = 0 while queuing back-to-back queries so Response #1 is not consumed unrecorded!
        c_r_ready = 1'b0;
        c_q_ip = 32'h0A_10_00_01; c_q_valid = 1'b1;
        while (!c_q_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1;
        c_q_ip = coll_ip_cache;
        while (!c_q_ready) begin @(posedge clk); #1; end
        @(posedge clk); #1; c_q_valid = 1'b0;
        while (!c_r_valid) begin @(posedge clk); #1; end
        if (c_r_error || c_r_mac != 48'h02_12_34_56_78_9A) begin
            $display("FAIL: Suite2C post-clear write lost err=%b mac=%h", c_r_error, c_r_mac); fail_cnt = fail_cnt + 1;
        end
        c_r_ready = 1'b1;
        @(posedge clk); #1;
        while (!c_r_valid) begin @(posedge clk); #1; end
        if (!c_r_error) begin $display("FAIL: Suite2C pre-clear entry survived clear_cache"); fail_cnt = fail_cnt + 1; end
        @(posedge clk); #1;

        // ---------------------------------------------------------------------
        // Suite 3: Full arp(64) Routing, RFC 826 Selective Learning & Probes
        // ---------------------------------------------------------------------
        // Find a 2-bit hash collision with 32'hC0_A8_0A_10 (192.168.10.16)
        tb_hash_ip = 32'hC0_A8_0A_10; #1; bkt_host_a2 = tb_hash_out[1:0];
        coll_ip_arp = 32'd0;
        for (i = 32; i < 120; i = i + 1) begin
            if (coll_ip_arp == 32'd0) begin
                tb_hash_ip = 32'hC0_A8_0A_00 + i; #1;
                if (tb_hash_out[1:0] == bkt_host_a2) coll_ip_arp = 32'hC0_A8_0A_00 + i;
            end
        end

        // 3A: Limited broadcast, directed broadcast, /32 non-broadcast, multicast, and 0-gateway off-subnet
        pulse_clr_a64_tx();
        do_arp64_lookup(32'hFF_FF_FF_FF, 3, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'hFFFF_FFFF_FFFF || a64_tx_pkt_cnt != 0) begin
            $display("FAIL: Suite3A limited bcast err=%b mac=%h tx=%0d", got_err, got_mac, a64_tx_pkt_cnt); fail_cnt = fail_cnt + 1;
        end
        do_arp64_lookup(32'hC0_A8_0A_FF, 0, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'hFFFF_FFFF_FFFF || a64_tx_pkt_cnt != 0) begin
            $display("FAIL: Suite3A directed bcast err=%b mac=%h tx=%0d", got_err, got_mac, a64_tx_pkt_cnt); fail_cnt = fail_cnt + 1;
        end
        do_arp64_lookup(32'hE0_00_01_81, 2, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'h01_00_5E_00_01_81 || a64_tx_pkt_cnt != 0) begin
            $display("FAIL: Suite3A multicast1 err=%b mac=%h", got_err, got_mac); fail_cnt = fail_cnt + 1;
        end
        do_arp64_lookup(32'hEF_FF_2A_63, 0, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'h01_00_5E_7F_2A_63 || a64_tx_pkt_cnt != 0) begin
            $display("FAIL: Suite3A multicast2 err=%b mac=%h", got_err, got_mac); fail_cnt = fail_cnt + 1;
        end

        // Off-subnet with gateway_ip == 0 -> immediate error=1, 0 TX frames!
        a64_gw_ip = 32'd0;
        do_arp64_lookup(32'h08_08_08_08, 4, got_err, got_mac, elapsed);
        if (!got_err || a64_tx_pkt_cnt != 0 || elapsed > 10) begin
            $display("FAIL: Suite3A zero-gw off-subnet err=%b tx=%0d el=%0d", got_err, a64_tx_pkt_cnt, elapsed); fail_cnt = fail_cnt + 1;
        end
        a64_gw_ip = 32'hC0_A8_0A_01;

        // /32 subnet_mask == 32'hFFFF_FFFF must NOT misclassify local_ip as directed broadcast,
        // and off-subnet 8.8.8.8 must still route via cached gateway 192.168.10.1!
        send_arp64_frame(a64_local_mac, 48'h02_00_00_10_00_01, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd2, 48'h02_00_00_10_00_01, 32'hC0_A8_0A_01, a64_local_mac, a64_local_ip),
            28, -1);
        repeat (6) @(posedge clk); #1;
        a64_mask = 32'hFF_FF_FF_FF;
        pulse_clr_a64_tx();
        do_arp64_lookup(32'h08_08_08_08, 0, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'h02_00_00_10_00_01) begin
            $display("FAIL: Suite3A /32 gw route failed! err=%b mac=%h", got_err, got_mac); fail_cnt = fail_cnt + 1;
        end
        do_arp64_lookup(a64_local_ip, 0, got_err, got_mac, elapsed);
        if (!got_err || got_mac == 48'hFFFF_FFFF_FFFF || a64_tx_pkt_cnt != 1) begin
            $display("FAIL: Suite3A /32 mask misclassified local_ip as broadcast! err=%b mac=%h tx=%0d",
                     got_err, got_mac, a64_tx_pkt_cnt);
            fail_cnt = fail_cnt + 1;
        end
        a64_mask = 32'hFF_FF_FF_00;

        // 3B: RFC 5227 ARP Probe (SPA=0.0.0.0, TPA=local_ip) -> MUST reply, MUST NOT cache 0.0.0.0!
        pulse_clr_a64_tx();
        send_arp64_frame(48'hFFFF_FFFF_FFFF, 48'h02_52_27_00_00_01, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_52_27_00_00_01, 32'd0, 48'd0, a64_local_ip),
            46, -1);
        repeat (12) @(posedge clk); #1;
        if (a64_tx_pkt_cnt != 1 || a64_tx_oper[0] != 16'd2 || a64_tx_tha[0] != 48'h02_52_27_00_00_01 || a64_tx_tpa[0] != 32'd0) begin
            $display("FAIL: Suite3B RFC5227 probe reply cnt=%0d oper=%h tpa=%h", a64_tx_pkt_cnt, a64_tx_oper[0], a64_tx_tpa[0]);
            fail_cnt = fail_cnt + 1;
        end

        // Poison frames: multicast SHA, zero SHA, multicast SPA, broadcast SPA, unknown OPER=5
        pulse_clr_a64_tx();
        send_arp64_frame(48'hFFFF_FFFF_FFFF, 48'h01_00_5E_00_00_01, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h01_00_5E_00_00_01, 32'hC0_A8_0A_10, 48'd0, a64_local_ip), 28, -1);
        send_arp64_frame(a64_local_mac, 48'h02_11_22_33_44_99, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd5, 48'h02_11_22_33_44_99, 32'hC0_A8_0A_10, a64_local_mac, a64_local_ip), 28, -1);
        repeat (10) @(posedge clk); #1;
        if (a64_tx_pkt_cnt != 0) begin $display("FAIL: Suite3B poison frame triggered TX"); fail_cnt = fail_cnt + 1; end

        // Verify 192.168.10.16 was NOT poisoned into cache, AND REQUEST_RETRY_COUNT==1 waits REQUEST_TIMEOUT(44) (not 12)!
        pulse_clr_a64_tx();
        do_arp64_lookup(32'hC0_A8_0A_10, 4, got_err, got_mac, elapsed);
        if (!got_err || a64_tx_pkt_cnt != 1 || elapsed < 40) begin
            $display("FAIL: Suite3B poison-miss / RETRY_COUNT=1 timeout err=%b tx=%0d elapsed=%0d(exp>=40)",
                     got_err, a64_tx_pkt_cnt, elapsed);
            fail_cnt = fail_cnt + 1;
        end

        // 3C: RFC 826 Selective Learning + Gratuitous Update + Anti-Collision Eviction + INARP
        // 1) Targeted ARP Request from 192.168.10.16 (MAC A1) -> caches A1 and replies!
        pulse_clr_a64_tx();
        send_arp64_frame(48'hFFFF_FFFF_FFFF, 48'h02_A1_A1_A1_A1_01, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_A1_A1_A1_A1_01, 32'hC0_A8_0A_10, 48'd0, a64_local_ip), 46, -1);
        repeat (10) @(posedge clk); #1;
        do_arp64_lookup(32'hC0_A8_0A_10, 0, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'h02_A1_A1_A1_A1_01 || a64_tx_pkt_cnt != 1) begin
            $display("FAIL: Suite3C initial learn err=%b mac=%h tx=%0d", got_err, got_mac, a64_tx_pkt_cnt); fail_cnt = fail_cnt + 1;
        end

        // 2) Gratuitous ARP from 192.168.10.16 (SPA==TPA!=local_ip, new MAC A2) -> already cached, MUST update to A2!
        send_arp64_frame(48'hFFFF_FFFF_FFFF, 48'h02_A2_A2_A2_A2_02, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_A2_A2_A2_A2_02, 32'hC0_A8_0A_10, 48'd0, 32'hC0_A8_0A_10), 28, -1);
        repeat (10) @(posedge clk); #1;
        do_arp64_lookup(32'hC0_A8_0A_10, 0, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'h02_A2_A2_A2_A2_02) begin
            $display("FAIL: Suite3C gratuitous update failed err=%b mac=%h", got_err, got_mac); fail_cnt = fail_cnt + 1;
        end

        // 3) Third-party ARP chatter from colliding IP (coll_ip_arp, TPA=192.168.10.200 != local_ip) -> MUST NOT evict 192.168.10.16!
        pulse_clr_a64_tx();
        send_arp64_frame(48'hFFFF_FFFF_FFFF, 48'h02_CC_CC_CC_CC_99, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_CC_CC_CC_CC_99, coll_ip_arp, 48'd0, 32'hC0_A8_0A_C8), 28, -1);
        repeat (10) @(posedge clk); #1;
        do_arp64_lookup(32'hC0_A8_0A_10, 0, got_err, got_mac, elapsed);
        if (got_err || got_mac != 48'h02_A2_A2_A2_A2_02 || a64_tx_pkt_cnt != 0) begin
            $display("FAIL: Suite3C third-party colliding ARP evicted cached entry! err=%b mac=%h tx=%0d",
                     got_err, got_mac, a64_tx_pkt_cnt);
            fail_cnt = fail_cnt + 1;
        end

        // 4) INARP Request targeting local_mac -> emits INARP Reply (OPER=9) and caches sender!
        pulse_clr_a64_tx();
        send_arp64_frame(a64_local_mac, 48'h02_88_88_88_88_08, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd8, 48'h02_88_88_88_88_08, 32'hC0_A8_0A_88, a64_local_mac, 32'd0), 28, -1);
        repeat (10) @(posedge clk); #1;
        if (a64_tx_pkt_cnt != 1 || a64_tx_oper[0] != 16'd9) begin
            $display("FAIL: Suite3C INARP reply cnt=%0d oper=%h", a64_tx_pkt_cnt, a64_tx_oper[0]); fail_cnt = fail_cnt + 1;
        end

        // ---------------------------------------------------------------------
        // Suite 4: u_arp256 TX Arbitration, Stalled-TX Non-Blocking RX & Timer==0 Sweep
        // ---------------------------------------------------------------------
        // 4A: Stall u_arp256 TX completely (m_hdr_r=0, m_tready=0), trigger uncached lookup + incoming ARP Request
        //     + incoming Gratuitous ARP for the pending lookup target!
        //     Even while TX is stalled holding Reply + Bcast Request, RX MUST accept the non-reply wakeup frame!
        pulse_clr_a256_tx();
        a256_m_hdr_r  = 1'b0;
        a256_m_tready = 1'b0;
        // Occupy BOTH arp_eth_tx (Reply #0) and outgoing_frame_reg (Reply #1) while TX output is stalled
        send_arp256_frame(48'hFFFF_FFFF_FFFF, 48'h02_75_00_00_00_01, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_75_00_00_00_01, 32'h0A_00_00_75, 48'd0, a256_local_ip), 28);
        send_arp256_frame(48'hFFFF_FFFF_FFFF, 48'h02_76_00_00_00_01, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_76_00_00_00_01, 32'h0A_00_00_76, 48'd0, a256_local_ip), 28);
        repeat (4) @(posedge clk); #1;

        // Trigger uncached lookup for 10.0.0.64 so req_tx_pending_reg stays 1 while tx_port_free==0
        a256_req_ip   = 32'h0A_00_00_40;
        a256_req_v    = 1'b1;
        while (!a256_req_r) begin @(posedge clk); #1; end
        @(posedge clk); #1; a256_req_v = 1'b0;
        repeat (4) @(posedge clk); #1;

        // First verify non-reply Gratuitous ARP for another cached/lookup flow? No: inject ARP Request #2 on RX,
        // and release TX backpressure while Request #2 is handshaking so reply_pending & req_tx_pending collide on tx_port_free!
        fork
            send_arp256_frame(48'hFFFF_FFFF_FFFF, 48'h02_77_00_00_00_01, 16'h0806,
                pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_77_00_00_00_01, 32'h0A_00_00_77, 48'd0, a256_local_ip), 28);
            begin
                @(posedge clk); #1;
                a256_m_hdr_r  = 1'b1;
                a256_m_tready = 1'b1;
            end
        join
        repeat (12) @(posedge clk); #1;
        begin : chk_4a_tx
            reg saw_reply0, saw_reply1, saw_reply2, saw_bcast_req;
            saw_reply0 = 1'b0; saw_reply1 = 1'b0; saw_reply2 = 1'b0; saw_bcast_req = 1'b0;
            for (i = 0; i < a256_tx_pkt_cnt; i = i + 1) begin
                if (a256_tx_oper[i] == 16'd2 && a256_tx_tpa[i] == 32'h0A_00_00_75) saw_reply0 = 1'b1;
                if (a256_tx_oper[i] == 16'd2 && a256_tx_tpa[i] == 32'h0A_00_00_76) saw_reply1 = 1'b1;
                if (a256_tx_oper[i] == 16'd2 && a256_tx_tpa[i] == 32'h0A_00_00_77 &&
                    a256_tx_tha[i] == 48'h02_77_00_00_00_01 && a256_tx_dst[i] == 48'h02_77_00_00_00_01)
                    saw_reply2 = 1'b1;
                if (a256_tx_oper[i] == 16'd1 && a256_tx_tpa[i] == 32'h0A_00_00_40 &&
                    a256_tx_dst[i] == 48'hFFFF_FFFF_FFFF)
                    saw_bcast_req = 1'b1;
            end
            if (!saw_reply0 || !saw_reply1 || !saw_reply2 || !saw_bcast_req) begin
                $display("FAIL: Suite4A TX collision dropped frame! cnt=%0d r0=%b r1=%b r2=%b breq=%b",
                         a256_tx_pkt_cnt, saw_reply0, saw_reply1, saw_reply2, saw_bcast_req);
                fail_cnt = fail_cnt + 1;
            end
        end

        // Now stall TX again (with Reply #A & Reply #B) and verify non-reply RX wakeup still resolves 10.0.0.64 without deadlock!
        a256_m_hdr_r  = 1'b0;
        a256_m_tready = 1'b0;
        send_arp256_frame(48'hFFFF_FFFF_FFFF, 48'h02_78_00_00_00_01, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd1, 48'h02_78_00_00_00_01, 32'h0A_00_00_78, 48'd0, a256_local_ip), 28);
        send_arp256_frame(48'hFFFF_FFFF_FFFF, 48'h02_40_40_40_40_40, 16'h0806,
            pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd2, 48'h02_40_40_40_40_40, 32'h0A_00_00_40, 48'd0, 32'h0A_00_00_40), 64);
        guard = 0;
        while (!a256_resp_v) begin
            @(posedge clk); #1;
            guard = guard + 1;
            if (guard > 40) begin $display("FAIL: Suite4A lookup deadlocked on stalled TX!"); $finish; end
        end
        if (a256_resp_err || a256_resp_mac != 48'h02_40_40_40_40_40) begin
            $display("FAIL: Suite4A wakeup err=%b mac=%h", a256_resp_err, a256_resp_mac); fail_cnt = fail_cnt + 1;
        end
        @(posedge clk); #1;
        a256_m_hdr_r  = 1'b1;
        a256_m_tready = 1'b1;
        repeat (10) @(posedge clk); #1;

        // 4B: Sweep reply arrival delays across retry timer expiration (dt = 8..15) & final timeout (dt = 41..48) on u_arp256
        for (i = 0; i < 8; i = i + 1) begin : sweep_blk
            reg [31:0] test_ip;
            reg [47:0] exp_m;
            integer resp_cyc;
            pulse_clr_a256_tx();
            test_ip = 32'h0A_00_00_90 + i;
            exp_m   = 48'h02_90_00_00_00_00 + i;
            a256_resp_r = 1'b0;
            a256_req_ip = test_ip;
            a256_req_v  = 1'b1;
            while (!a256_req_r) begin @(posedge clk); #1; end
            @(posedge clk); #1; a256_req_v = 1'b0;

            // Wait until initial broadcast request appears, then delay (8 + i) cycles to sweep across timer==0 boundary
            while (a256_tx_pkt_cnt == 0) begin @(posedge clk); #1; end
            repeat (8 + i) @(posedge clk); #1;

            send_arp256_frame(a256_local_mac, exp_m, 16'h0806,
                pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd2, exp_m, test_ip, a256_local_mac, a256_local_ip), 28);

            guard = 0;
            while (!a256_resp_v) begin @(posedge clk); #1; guard = guard + 1; if (guard > 100) $finish; end
            resp_cyc = cyc_now;
            if (a256_resp_err || a256_resp_mac != exp_m) begin
                $display("FAIL: Suite4B retry boundary i=%0d err=%b mac=%h", i, a256_resp_err, a256_resp_mac);
                fail_cnt = fail_cnt + 1;
            end
            a256_resp_r = 1'b1;
            @(posedge clk); #1;
            repeat (22) @(posedge clk); #1;
            // Early wakeup (dt=8, well before REQUEST_RETRY_INTERVAL=16) must cancel retry; across all i, no post-wakeup retry
            if ((i == 0 && a256_tx_pkt_cnt != 1) || (a256_tx_pkt_cnt > 2) ||
                (a256_tx_pkt_cnt > 1 && a256_tx_cyc[a256_tx_pkt_cnt - 1] >= resp_cyc + 4)) begin
                $display("FAIL: Suite4B spurious retry emitted after wakeup i=%0d cnt=%0d tx_cyc=%0d resp_cyc=%0d",
                         i, a256_tx_pkt_cnt, a256_tx_cyc[a256_tx_pkt_cnt - 1], resp_cyc);
                fail_cnt = fail_cnt + 1;
            end
        end

        // Sweep final timeout boundary (dt = 41..48 across initial(16)+timeout(32)=48 cycles) with arp_response_ready held low
        for (i = 0; i < 8; i = i + 1) begin : sweep_final_blk
            reg [31:0] test_ip2;
            reg [47:0] exp_m2;
            pulse_clr_a256_tx();
            test_ip2 = 32'h0A_00_00_B0 + i;
            exp_m2   = 48'h02_B0_00_00_00_00 + i;
            a256_resp_r = 1'b0;
            a256_req_ip = test_ip2;
            a256_req_v  = 1'b1;
            while (!a256_req_r) begin @(posedge clk); #1; end
            @(posedge clk); #1; a256_req_v = 1'b0;

            while (a256_tx_pkt_cnt == 0) begin @(posedge clk); #1; end
            repeat (41 + i) @(posedge clk); #1;
            if (!a256_resp_v) begin
                send_arp256_frame(a256_local_mac, exp_m2, 16'h0806,
                    pack_arp(16'd1, 16'h0800, 8'd6, 8'd4, 16'd2, exp_m2, test_ip2, a256_local_mac, a256_local_ip), 28);
            end
            guard = 0;
            while (!a256_resp_v) begin @(posedge clk); #1; guard = guard + 1; if (guard > 100) $finish; end
            if (i == 0 && (a256_resp_err || a256_resp_mac != exp_m2)) begin
                $display("FAIL: Suite4B pre-timeout wakeup failed! err=%b mac=%h", a256_resp_err, a256_resp_mac);
                fail_cnt = fail_cnt + 1;
            end
            // Must NEVER report error=1 together with non-zero MAC (upstream timer==0 overwrite bug sets error=1 AND mac=exp_m2!)
            if (a256_resp_err && (a256_resp_mac != 48'd0)) begin
                $display("FAIL: Suite4B timeout overwrote same-cycle cache hit! i=%0d mac=%h", i, a256_resp_mac);
                fail_cnt = fail_cnt + 1;
            end
            if (!a256_resp_err && (a256_resp_mac != exp_m2)) begin
                $display("FAIL: Suite4B wrong mac on late wakeup i=%0d mac=%h", i, a256_resp_mac);
                fail_cnt = fail_cnt + 1;
            end
            // Hold stalled response for 2 extra cycles and verify stability before consuming
            begin : chk_hold_final
                reg held_err;
                reg [47:0] held_mac;
                held_err = a256_resp_err;
                held_mac = a256_resp_mac;
                repeat (2) @(posedge clk); #1;
                if (!a256_resp_v || a256_resp_err !== held_err || a256_resp_mac !== held_mac) begin
                    $display("FAIL: Suite4B response unstable while stalled! i=%0d", i);
                    fail_cnt = fail_cnt + 1;
                end
            end
            a256_resp_r = 1'b1;
            @(posedge clk); #1;
        end

        fail_cnt = fail_cnt + mon_fail_cnt;
        if (fail_cnt == 0) begin
            $display("PASS: All ARP wide/multi-beat framing, cache coherence, RFC 826 learning, and TX arbitration checks passed (SEED=%0d)", SEED);
        end else begin
            $display("FAIL: %0d total errors (SEED=%0d)", fail_cnt, SEED);
        end
        $finish;
    end
endmodule
