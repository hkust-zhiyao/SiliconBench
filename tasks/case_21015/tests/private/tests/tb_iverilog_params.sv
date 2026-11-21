`timescale 1ns / 1ps
`default_nettype none

module tb_iverilog_params;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    integer errors = 0;

    // =========================================================================
    // 1. axi_dma_desc_mux with PORTS = 1, S_TAG_WIDTH = 6, M_TAG_WIDTH = 8
    // =========================================================================
    wire [15:0] p1_m_addr;
    wire [19:0] p1_m_len;
    wire [7:0]  p1_m_tag;
    wire [7:0]  p1_m_id;
    wire [7:0]  p1_m_dest;
    wire [3:0]  p1_m_user;
    wire        p1_m_valid;
    reg         p1_m_ready = 1'b0;

    reg  [19:0] p1_st_in_len = 20'd0;
    reg  [7:0]  p1_st_in_tag = 8'd0;
    reg  [7:0]  p1_st_in_id = 8'd0;
    reg  [7:0]  p1_st_in_dest = 8'd0;
    reg  [3:0]  p1_st_in_user = 4'd0;
    reg  [3:0]  p1_st_in_err = 4'd0;
    reg         p1_st_in_valid = 1'b0;

    reg  [15:0] p1_s_addr = 16'd0;
    reg  [19:0] p1_s_len = 20'd0;
    reg  [5:0]  p1_s_tag = 6'd0;
    reg  [7:0]  p1_s_id = 8'd0;
    reg  [7:0]  p1_s_dest = 8'd0;
    reg  [3:0]  p1_s_user = 4'd0;
    reg         p1_s_valid = 1'b0;
    wire        p1_s_ready;

    wire [19:0] p1_st_out_len;
    wire [5:0]  p1_st_out_tag;
    wire [7:0]  p1_st_out_id;
    wire [7:0]  p1_st_out_dest;
    wire [3:0]  p1_st_out_user;
    wire [3:0]  p1_st_out_err;
    wire        p1_st_out_valid;

    axi_dma_desc_mux #(
        .PORTS(1),
        .AXI_ADDR_WIDTH(16),
        .AXIS_ID_ENABLE(1),
        .AXIS_ID_WIDTH(8),
        .AXIS_DEST_ENABLE(1),
        .AXIS_DEST_WIDTH(8),
        .AXIS_USER_ENABLE(1),
        .AXIS_USER_WIDTH(4),
        .LEN_WIDTH(20),
        .S_TAG_WIDTH(6),
        .M_TAG_WIDTH(8)
    ) u_mux_p1 (
        .clk(clk),
        .rst(rst),
        .m_axis_desc_addr(p1_m_addr),
        .m_axis_desc_len(p1_m_len),
        .m_axis_desc_tag(p1_m_tag),
        .m_axis_desc_id(p1_m_id),
        .m_axis_desc_dest(p1_m_dest),
        .m_axis_desc_user(p1_m_user),
        .m_axis_desc_valid(p1_m_valid),
        .m_axis_desc_ready(p1_m_ready),
        .s_axis_desc_status_len(p1_st_in_len),
        .s_axis_desc_status_tag(p1_st_in_tag),
        .s_axis_desc_status_id(p1_st_in_id),
        .s_axis_desc_status_dest(p1_st_in_dest),
        .s_axis_desc_status_user(p1_st_in_user),
        .s_axis_desc_status_error(p1_st_in_err),
        .s_axis_desc_status_valid(p1_st_in_valid),
        .s_axis_desc_addr(p1_s_addr),
        .s_axis_desc_len(p1_s_len),
        .s_axis_desc_tag(p1_s_tag),
        .s_axis_desc_id(p1_s_id),
        .s_axis_desc_dest(p1_s_dest),
        .s_axis_desc_user(p1_s_user),
        .s_axis_desc_valid(p1_s_valid),
        .s_axis_desc_ready(p1_s_ready),
        .m_axis_desc_status_len(p1_st_out_len),
        .m_axis_desc_status_tag(p1_st_out_tag),
        .m_axis_desc_status_id(p1_st_out_id),
        .m_axis_desc_status_dest(p1_st_out_dest),
        .m_axis_desc_status_user(p1_st_out_user),
        .m_axis_desc_status_error(p1_st_out_err),
        .m_axis_desc_status_valid(p1_st_out_valid)
    );

    // =========================================================================
    // 2. axi_dma_desc_mux with PORTS = 3 (non-power-of-2), S_TAG_WIDTH = 5, M_TAG_WIDTH = 10
    // =========================================================================
    wire [15:0] p3_m_addr;
    wire [19:0] p3_m_len;
    wire [9:0]  p3_m_tag;
    wire        p3_m_valid;
    reg         p3_m_ready = 1'b0;

    reg  [19:0] p3_st_in_len = 20'd0;
    reg  [9:0]  p3_st_in_tag = 10'd0;
    reg  [3:0]  p3_st_in_err = 4'd0;
    reg         p3_st_in_valid = 1'b0;

    reg  [3*16-1:0] p3_s_addr = {3*16{1'b0}};
    reg  [3*20-1:0] p3_s_len = {3*20{1'b0}};
    reg  [3*5-1:0]  p3_s_tag = {3*5{1'b0}};
    reg  [2:0]      p3_s_valid = 3'b000;
    wire [2:0]      p3_s_ready;

    wire [3*20-1:0] p3_st_out_len;
    wire [3*5-1:0]  p3_st_out_tag;
    wire [3*4-1:0]  p3_st_out_err;
    wire [2:0]      p3_st_out_valid;

    axi_dma_desc_mux #(
        .PORTS(3),
        .AXI_ADDR_WIDTH(16),
        .AXIS_ID_ENABLE(0),
        .AXIS_DEST_ENABLE(0),
        .AXIS_USER_ENABLE(0),
        .LEN_WIDTH(20),
        .S_TAG_WIDTH(5),
        .M_TAG_WIDTH(10)
    ) u_mux_p3 (
        .clk(clk),
        .rst(rst),
        .m_axis_desc_addr(p3_m_addr),
        .m_axis_desc_len(p3_m_len),
        .m_axis_desc_tag(p3_m_tag),
        .m_axis_desc_id(),
        .m_axis_desc_dest(),
        .m_axis_desc_user(),
        .m_axis_desc_valid(p3_m_valid),
        .m_axis_desc_ready(p3_m_ready),
        .s_axis_desc_status_len(p3_st_in_len),
        .s_axis_desc_status_tag(p3_st_in_tag),
        .s_axis_desc_status_id(8'd0),
        .s_axis_desc_status_dest(8'd0),
        .s_axis_desc_status_user(1'b0),
        .s_axis_desc_status_error(p3_st_in_err),
        .s_axis_desc_status_valid(p3_st_in_valid),
        .s_axis_desc_addr(p3_s_addr),
        .s_axis_desc_len(p3_s_len),
        .s_axis_desc_tag(p3_s_tag),
        .s_axis_desc_id(24'd0),
        .s_axis_desc_dest(24'd0),
        .s_axis_desc_user(3'd0),
        .s_axis_desc_valid(p3_s_valid),
        .s_axis_desc_ready(p3_s_ready),
        .m_axis_desc_status_len(p3_st_out_len),
        .m_axis_desc_status_tag(p3_st_out_tag),
        .m_axis_desc_status_id(),
        .m_axis_desc_status_dest(),
        .m_axis_desc_status_user(),
        .m_axis_desc_status_error(p3_st_out_err),
        .m_axis_desc_status_valid(p3_st_out_valid)
    );

    // =========================================================================
    // 3. Wide AXI DMA (AXI_DATA_WIDTH = 256, AXI_MAX_BURST_LEN = 128 => 4096B max burst!)
    //    Tests >= 4096B unaligned & aligned 4KB boundary splitting + 4-state X-hygiene
    // =========================================================================
    reg  [15:0] rd_desc_addr = 16'd0;
    reg  [19:0] rd_desc_len = 20'd0;
    reg  [7:0]  rd_desc_tag = 8'd0;
    reg         rd_desc_valid = 1'b0;
    wire        rd_desc_ready;
    wire [7:0]  rd_status_tag;
    wire [3:0]  rd_status_err;
    wire        rd_status_valid;

    reg  [15:0] wr_desc_addr = 16'd0;
    reg  [19:0] wr_desc_len = 20'd0;
    reg  [7:0]  wr_desc_tag = 8'd0;
    reg         wr_desc_valid = 1'b0;
    wire        wr_desc_ready;
    wire [19:0] wr_status_len;
    wire [7:0]  wr_status_tag;
    wire [3:0]  wr_status_err;
    wire        wr_status_valid;

    wire [255:0] axis_rd_tdata;
    wire [31:0]  axis_rd_tkeep;
    wire         axis_rd_tvalid;
    reg          axis_rd_tready = 1'b1;
    wire         axis_rd_tlast;

    reg  [255:0] axis_wr_tdata = 256'd0;
    reg  [31:0]  axis_wr_tkeep = 32'hFFFF_FFFF;
    reg          axis_wr_tvalid = 1'b0;
    wire         axis_wr_tready;
    reg          axis_wr_tlast = 1'b0;

    wire [7:0]   m_axi_awid;
    wire [15:0]  m_axi_awaddr;
    wire [7:0]   m_axi_awlen;
    wire [2:0]   m_axi_awsize;
    wire [1:0]   m_axi_awburst;
    wire         m_axi_awlock;
    wire [3:0]   m_axi_awcache;
    wire [2:0]   m_axi_awprot;
    wire         m_axi_awvalid;
    reg          m_axi_awready = 1'b1;

    wire [255:0] m_axi_wdata;
    wire [31:0]  m_axi_wstrb;
    wire         m_axi_wlast;
    wire         m_axi_wvalid;
    wire         m_axi_wready = 1'b1;

    reg  [1:0]   m_axi_bresp = 2'b00;
    reg          m_axi_bvalid = 1'b0;
    wire         m_axi_bready;

    wire [7:0]   m_axi_arid;
    wire [15:0]  m_axi_araddr;
    wire [7:0]   m_axi_arlen;
    wire [2:0]   m_axi_arsize;
    wire [1:0]   m_axi_arburst;
    wire         m_axi_arlock;
    wire [3:0]   m_axi_arcache;
    wire [2:0]   m_axi_arprot;
    wire         m_axi_arvalid;
    reg          m_axi_arready = 1'b1;

    reg  [255:0] m_axi_rdata = 256'd0;
    reg  [1:0]   m_axi_rresp = 2'b00;
    reg          m_axi_rlast = 1'b0;
    reg          m_axi_rvalid = 1'b0;
    wire         m_axi_rready;

    axi_dma #(
        .AXI_DATA_WIDTH(256),
        .AXI_ADDR_WIDTH(16),
        .AXI_ID_WIDTH(8),
        .AXI_MAX_BURST_LEN(128),
        .AXIS_LAST_ENABLE(1),
        .AXIS_ID_ENABLE(0),
        .AXIS_DEST_ENABLE(0),
        .AXIS_USER_ENABLE(0),
        .LEN_WIDTH(20),
        .TAG_WIDTH(8),
        .ENABLE_SG(0),
        .ENABLE_UNALIGNED(1)
    ) u_wide_dma (
        .clk(clk),
        .rst(rst),
        .s_axis_read_desc_addr(rd_desc_addr),
        .s_axis_read_desc_len(rd_desc_len),
        .s_axis_read_desc_tag(rd_desc_tag),
        .s_axis_read_desc_id(8'd0),
        .s_axis_read_desc_dest(8'd0),
        .s_axis_read_desc_user(1'b0),
        .s_axis_read_desc_valid(rd_desc_valid),
        .s_axis_read_desc_ready(rd_desc_ready),
        .m_axis_read_desc_status_tag(rd_status_tag),
        .m_axis_read_desc_status_error(rd_status_err),
        .m_axis_read_desc_status_valid(rd_status_valid),
        .m_axis_read_data_tdata(axis_rd_tdata),
        .m_axis_read_data_tkeep(axis_rd_tkeep),
        .m_axis_read_data_tvalid(axis_rd_tvalid),
        .m_axis_read_data_tready(axis_rd_tready),
        .m_axis_read_data_tlast(axis_rd_tlast),
        .m_axis_read_data_tid(),
        .m_axis_read_data_tdest(),
        .m_axis_read_data_tuser(),
        .s_axis_write_desc_addr(wr_desc_addr),
        .s_axis_write_desc_len(wr_desc_len),
        .s_axis_write_desc_tag(wr_desc_tag),
        .s_axis_write_desc_valid(wr_desc_valid),
        .s_axis_write_desc_ready(wr_desc_ready),
        .m_axis_write_desc_status_len(wr_status_len),
        .m_axis_write_desc_status_tag(wr_status_tag),
        .m_axis_write_desc_status_id(),
        .m_axis_write_desc_status_dest(),
        .m_axis_write_desc_status_user(),
        .m_axis_write_desc_status_error(wr_status_err),
        .m_axis_write_desc_status_valid(wr_status_valid),
        .s_axis_write_data_tdata(axis_wr_tdata),
        .s_axis_write_data_tkeep(axis_wr_tkeep),
        .s_axis_write_data_tvalid(axis_wr_tvalid),
        .s_axis_write_data_tready(axis_wr_tready),
        .s_axis_write_data_tlast(axis_wr_tlast),
        .s_axis_write_data_tid(8'd0),
        .s_axis_write_data_tdest(8'd0),
        .s_axis_write_data_tuser(1'b0),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(8'd0),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(8'd0),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .read_enable(1'b1),
        .write_enable(1'b1),
        .write_abort(1'b0)
    );

    // Simple 64KB byte memory for wide AXI DMA
    reg [7:0] mem [0:65535];
    integer b_pending = 0;

    reg [15:0] ar_q_addr [0:15];
    reg [7:0]  ar_q_len  [0:15];
    integer ar_wr = 0, ar_rd = 0;
    reg [15:0] cur_r_addr = 16'd0;
    reg [8:0]  cur_r_rem  = 9'd0;

    reg [15:0]  aw_q_addr [0:31];
    reg [7:0]   aw_q_len  [0:31];
    integer aw_wr = 0, aw_rd = 0;

    reg [255:0] w_q_data  [0:511];
    reg [31:0]  w_q_strb  [0:511];
    reg         w_q_last  [0:511];
    integer w_wr = 0, w_rd = 0;

    reg [15:0] cur_w_addr = 16'd0;
    reg [8:0]  cur_w_cnt  = 9'd0;
    reg [8:0]  cur_w_tot  = 9'd0;
    reg        w_active   = 1'b0;

    integer k;

    // 4-state X checks & AXI4 4KB / max-burst assertions on wide DMA
    always @(posedge clk) begin
        if (!rst) begin
            if (^p1_m_valid === 1'bx || ^p3_m_valid === 1'bx || ^m_axi_awvalid === 1'bx || ^m_axi_wvalid === 1'bx || ^m_axi_arvalid === 1'bx) begin
                $display("FAIL: X-state on valid control signal");
                errors = errors + 1;
            end

            // AW monitor
            if (m_axi_awvalid) begin
                if (m_axi_awlen >= 8'd128) begin
                    $display("FAIL: Wide DMA AWLEN %0d >= 128", m_axi_awlen);
                    errors = errors + 1;
                end
                if (((m_axi_awaddr & 16'hFFE0) >> 12) !== (((m_axi_awaddr & 16'hFFE0) + ({8'd0, m_axi_awlen} << 5)) >> 12)) begin
                    $display("FAIL: Wide DMA AW crossed 4KB boundary: addr=0x%04x len=%0d", m_axi_awaddr, m_axi_awlen);
                    errors = errors + 1;
                end
            end
            if (m_axi_awvalid && m_axi_awready) begin
                aw_q_addr[aw_wr % 32] = m_axi_awaddr & 16'hFFE0;
                aw_q_len[aw_wr % 32]  = m_axi_awlen;
                aw_wr = aw_wr + 1;
            end

            // W monitor (AXI4 allows W beats to handshake before AW; buffer in w_q and commit in order once AW is available)
            if (m_axi_wvalid && m_axi_wready) begin
                w_q_data[w_wr % 512] = m_axi_wdata;
                w_q_strb[w_wr % 512] = m_axi_wstrb;
                w_q_last[w_wr % 512] = m_axi_wlast;
                w_wr = w_wr + 1;
            end

            while ((w_rd < w_wr) && (w_active || (aw_rd < aw_wr))) begin
                if (!w_active) begin
                    cur_w_addr = aw_q_addr[aw_rd % 32];
                    cur_w_tot  = {1'b0, aw_q_len[aw_rd % 32]} + 9'd1;
                    cur_w_cnt  = 9'd0;
                    aw_rd      = aw_rd + 1;
                    w_active   = 1'b1;
                end
                for (k = 0; k < 32; k = k + 1) begin
                    if (w_q_strb[w_rd % 512][k]) begin
                        mem[(cur_w_addr + k) & 16'hFFFF] <= w_q_data[w_rd % 512][k*8 +: 8];
                    end
                end
                cur_w_addr = cur_w_addr + 16'd32;
                cur_w_cnt  = cur_w_cnt + 9'd1;
                if (cur_w_cnt == cur_w_tot) begin
                    if (!w_q_last[w_rd % 512]) begin
                        $display("FAIL: Missing WLAST at end of AWLEN");
                        errors = errors + 1;
                    end
                    w_active  = 1'b0;
                    b_pending = b_pending + 1;
                end else if (w_q_last[w_rd % 512]) begin
                    $display("FAIL: Early WLAST");
                    errors = errors + 1;
                    w_active = 1'b0;
                end
                w_rd = w_rd + 1;
            end

            if (m_axi_bvalid && m_axi_bready) begin
                b_pending = b_pending - 1;
            end
            m_axi_bvalid <= (b_pending > ((m_axi_bvalid && m_axi_bready) ? 1 : 0));

            // AR monitor
            if (m_axi_arvalid && m_axi_arready) begin
                if (m_axi_arlen >= 8'd128) begin
                    $display("FAIL: Wide DMA ARLEN %0d >= 128", m_axi_arlen);
                    errors = errors + 1;
                end
                if (((m_axi_araddr & 16'hFFE0) >> 12) !== (((m_axi_araddr & 16'hFFE0) + ({8'd0, m_axi_arlen} << 5)) >> 12)) begin
                    $display("FAIL: Wide DMA AR crossed 4KB boundary: addr=0x%04x len=%0d", m_axi_araddr, m_axi_arlen);
                    errors = errors + 1;
                end
                ar_q_addr[ar_wr % 16] = m_axi_araddr & 16'hFFE0;
                ar_q_len[ar_wr % 16]  = m_axi_arlen;
                ar_wr = ar_wr + 1;
            end

            // R responder
            if (m_axi_rvalid && m_axi_rready) begin
                if (cur_r_rem == 9'd1) begin
                    cur_r_rem <= 9'd0;
                    m_axi_rvalid <= 1'b0;
                    m_axi_rlast <= 1'b0;
                end else begin
                    cur_r_rem <= cur_r_rem - 9'd1;
                    cur_r_addr <= cur_r_addr + 16'd32;
                    for (k = 0; k < 32; k = k + 1) begin
                        m_axi_rdata[k*8 +: 8] <= mem[(cur_r_addr + 16'd32 + k) & 16'hFFFF];
                    end
                    m_axi_rlast <= (cur_r_rem == 9'd2);
                end
            end else if (!m_axi_rvalid && (cur_r_rem == 9'd0) && (ar_rd < ar_wr)) begin
                cur_r_addr <= ar_q_addr[ar_rd % 16];
                cur_r_rem  <= {1'b0, ar_q_len[ar_rd % 16]} + 9'd1;
                for (k = 0; k < 32; k = k + 1) begin
                    m_axi_rdata[k*8 +: 8] <= mem[(ar_q_addr[ar_rd % 16] + k) & 16'hFFFF];
                end
                m_axi_rvalid <= 1'b1;
                m_axi_rlast  <= (ar_q_len[ar_rd % 16] == 8'd0);
                ar_rd = ar_rd + 1;
            end
        end
    end

    integer idx, b_idx, timeout;
    reg [9:0] seen_tags [0:2];
    integer seen_cnt;
    integer rd_bytes_seen;

    initial begin
        for (idx = 0; idx < 65536; idx = idx + 1) begin
            mem[idx] = 8'hA5;
        end

        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);

        // -----------------------------------------------------------------
        // Test A: PORTS=1 mux forward skid + status demux with M_TAG_WIDTH=8 > S_TAG_WIDTH=6
        // -----------------------------------------------------------------
        p1_m_ready <= 1'b0;
        p1_s_addr  <= 16'h1234;
        p1_s_len   <= 20'd64;
        p1_s_tag   <= 6'h2A;
        p1_s_id    <= 8'h11;
        p1_s_dest  <= 8'h22;
        p1_s_user  <= 4'h7;
        p1_s_valid <= 1'b1;
        timeout = 0;
        @(posedge clk);
        while (!(p1_s_valid && p1_s_ready) && timeout < 40) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 40) begin
            $display("FAIL: P1 first desc timeout");
            errors = errors + 1;
        end
        p1_s_addr <= 16'h5678;
        p1_s_tag  <= 6'h15;
        timeout = 0;
        @(posedge clk);
        while (!(p1_s_valid && p1_s_ready) && timeout < 40) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        p1_s_valid <= 1'b0;
        repeat (2) @(posedge clk);
        p1_m_ready <= 1'b1;

        seen_cnt = 0;
        for (idx = 0; idx < 20 && seen_cnt < 2; idx = idx + 1) begin
            @(posedge clk);
            if (p1_m_valid && p1_m_ready) begin
                if (seen_cnt == 0 && (p1_m_tag !== 8'h2A || p1_m_addr !== 16'h1234)) begin
                    $display("FAIL: P1 desc 0 mismatch tag=0x%02x addr=0x%04x", p1_m_tag, p1_m_addr);
                    errors = errors + 1;
                end
                if (seen_cnt == 1 && (p1_m_tag !== 8'h15 || p1_m_addr !== 16'h5678)) begin
                    $display("FAIL: P1 desc 1 skid mismatch tag=0x%02x addr=0x%04x", p1_m_tag, p1_m_addr);
                    errors = errors + 1;
                end
                seen_cnt = seen_cnt + 1;
            end
        end
        if (seen_cnt != 2) begin
            $display("FAIL: P1 expected 2 descriptors, got %0d", seen_cnt);
            errors = errors + 1;
        end

        @(posedge clk);
        p1_st_in_tag   <= 8'h2A;
        p1_st_in_len   <= 20'd64;
        p1_st_in_valid <= 1'b1;
        @(posedge clk);
        p1_st_in_valid <= 1'b0;
        @(posedge clk);
        if (p1_st_out_valid !== 1'b1 || p1_st_out_tag !== 6'h2A) begin
            $display("FAIL: P1 status demux failed valid=%b tag=0x%02x", p1_st_out_valid, p1_st_out_tag);
            errors = errors + 1;
        end

        // -----------------------------------------------------------------
        // Test B: PORTS=3 mux under stall (skid buffer) + M_TAG_WIDTH=10 status demux + invalid port=3 guard
        // -----------------------------------------------------------------
        p3_m_ready <= 1'b0;
        p3_s_addr  <= {16'hC000, 16'hB000, 16'hA000};
        p3_s_len   <= {20'd30, 20'd20, 20'd10};
        p3_s_tag   <= {5'h1C, 5'h1B, 5'h1A};
        p3_s_valid <= 3'b111;

        seen_cnt = 0;
        for (idx = 0; idx < 50 && seen_cnt < 3; idx = idx + 1) begin
            @(posedge clk);
            for (b_idx = 0; b_idx < 3; b_idx = b_idx + 1) begin
                if (p3_s_valid[b_idx] && p3_s_ready[b_idx]) begin
                    p3_s_valid[b_idx] <= 1'b0;
                end
            end
            if (idx == 6) begin
                p3_m_ready <= 1'b1; // release after skid buffer is full!
            end
            if (p3_m_valid && p3_m_ready) begin
                seen_tags[seen_cnt] = p3_m_tag;
                seen_cnt = seen_cnt + 1;
            end
        end
        if (seen_cnt != 3) begin
            $display("FAIL: P3 expected 3 descriptors, got %0d", seen_cnt);
            errors = errors + 1;
        end else begin
            for (b_idx = 0; b_idx < 3; b_idx = b_idx + 1) begin
                // Check packed port index in [6:5] and upper zero bits [9:7] == 0
                if (seen_tags[b_idx][9:7] !== 3'b000) begin
                    $display("FAIL: P3 upper tag bits non-zero: 0x%03x", seen_tags[b_idx]);
                    errors = errors + 1;
                end
                if (seen_tags[b_idx][6:5] == 2'd0 && seen_tags[b_idx][4:0] !== 5'h1A) errors = errors + 1;
                if (seen_tags[b_idx][6:5] == 2'd1 && seen_tags[b_idx][4:0] !== 5'h1B) errors = errors + 1;
                if (seen_tags[b_idx][6:5] == 2'd2 && seen_tags[b_idx][4:0] !== 5'h1C) begin
                    $display("FAIL: P3 port 2 tag lost port index across skid: 0x%03x", seen_tags[b_idx]);
                    errors = errors + 1;
                end
                if (seen_tags[b_idx][6:5] == 2'd3) errors = errors + 1;
            end
        end

        // Status demux for port 2 with M_TAG_WIDTH=10 (port bits in [6:5], NOT [9:8]!)
        @(posedge clk);
        p3_st_in_tag   <= {3'b000, 2'd2, 5'h1C};
        p3_st_in_len   <= 20'd30;
        p3_st_in_valid <= 1'b1;
        @(posedge clk);
        p3_st_in_valid <= 1'b0;
        @(posedge clk);
        if (p3_st_out_valid !== 3'b100 || p3_st_out_tag[2*5 +: 5] !== 5'h1C) begin
            $display("FAIL: P3 status demux port 2 failed: valid=%b tag=0x%02x", p3_st_out_valid, p3_st_out_tag[2*5 +: 5]);
            errors = errors + 1;
        end

        // Out-of-range port index 3 on PORTS=3 must emit 3'b000
        @(posedge clk);
        p3_st_in_tag   <= {3'b000, 2'd3, 5'h0F};
        p3_st_in_valid <= 1'b1;
        @(posedge clk);
        p3_st_in_valid <= 1'b0;
        @(posedge clk);
        if (p3_st_out_valid !== 3'b000) begin
            $display("FAIL: P3 out-of-range port 3 asserted valid=%b", p3_st_out_valid);
            errors = errors + 1;
        end

        // -----------------------------------------------------------------
        // Test C: Wide DMA (256-bit, AXI_MAX_BURST_LEN=128 => 4096B)
        //         Unaligned 4500-byte write + readback crossing TWO 4KB boundaries (0x0FE5 .. 0x2178)
        // -----------------------------------------------------------------
        @(posedge clk);
        wr_desc_addr  <= 16'h0FE5;
        wr_desc_len   <= 20'd4500;
        wr_desc_tag   <= 8'h77;
        wr_desc_valid <= 1'b1;
        timeout = 0;
        while (!(wr_desc_valid && wr_desc_ready) && timeout < 50) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        wr_desc_valid <= 1'b0;

        // Stream 4500 bytes (140 full 32B beats = 4480B + 1 partial 20B beat = 4500B)
        for (idx = 0; idx < 141; idx = idx + 1) begin
            for (b_idx = 0; b_idx < 32; b_idx = b_idx + 1) begin
                if (idx * 32 + b_idx < 4500) begin
                    axis_wr_tdata[b_idx*8 +: 8] <= ((idx * 32 + b_idx) * 13 + 7) & 8'hFF;
                    axis_wr_tkeep[b_idx] <= 1'b1;
                end else begin
                    axis_wr_tdata[b_idx*8 +: 8] <= 8'hEE;
                    axis_wr_tkeep[b_idx] <= 1'b0;
                end
            end
            axis_wr_tlast  <= (idx == 140);
            axis_wr_tvalid <= 1'b1;
            @(posedge clk);
            while (!axis_wr_tready) @(posedge clk);
        end
        axis_wr_tvalid <= 1'b0;
        axis_wr_tlast  <= 1'b0;

        timeout = 0;
        while (!wr_status_valid && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!wr_status_valid || wr_status_len !== 20'd4500 || wr_status_tag !== 8'h77 || wr_status_err !== 4'd0) begin
            $display("FAIL: Wide DMA write status mismatch valid=%b len=%0d tag=0x%02x err=%0d",
                     wr_status_valid, wr_status_len, wr_status_tag, wr_status_err);
            errors = errors + 1;
        end

        // Check canary bytes & written payload
        if (mem[16'h0FE4] !== 8'hA5 || mem[16'h0FE5 + 4500] !== 8'hA5) begin
            $display("FAIL: Wide DMA canary byte overwritten! before=0x%02x after=0x%02x",
                     mem[16'h0FE4], mem[16'h0FE5 + 4500]);
            errors = errors + 1;
        end
        for (idx = 0; idx < 4500; idx = idx + 1) begin
            if (mem[16'h0FE5 + idx] !== (((idx * 13 + 7) & 8'hFF))) begin
                if (errors < 10)
                    $display("FAIL: Wide DMA mem mismatch at +%0d: got 0x%02x exp 0x%02x",
                             idx, mem[16'h0FE5 + idx], (idx * 13 + 7) & 8'hFF);
                errors = errors + 1;
            end
        end

        // Read back the same 4500 bytes from 0x0FE5
        @(posedge clk);
        rd_desc_addr  <= 16'h0FE5;
        rd_desc_len   <= 20'd4500;
        rd_desc_tag   <= 8'h88;
        rd_desc_valid <= 1'b1;
        while (!(rd_desc_valid && rd_desc_ready)) @(posedge clk);
        rd_desc_valid <= 1'b0;

        rd_bytes_seen = 0;
        timeout = 0;
        while (timeout < 1500) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (axis_rd_tvalid && axis_rd_tready) begin
                for (b_idx = 0; b_idx < 32; b_idx = b_idx + 1) begin
                    if (axis_rd_tkeep[b_idx]) begin
                        if (axis_rd_tdata[b_idx*8 +: 8] !== (((rd_bytes_seen * 13 + 7) & 8'hFF))) begin
                            if (errors < 15)
                                $display("FAIL: Wide DMA read mismatch at byte %0d: got 0x%02x exp 0x%02x",
                                         rd_bytes_seen, axis_rd_tdata[b_idx*8 +: 8], (rd_bytes_seen * 13 + 7) & 8'hFF);
                            errors = errors + 1;
                        end
                        rd_bytes_seen = rd_bytes_seen + 1;
                    end
                end
                if (axis_rd_tlast) begin
                    timeout = 2000;
                end
            end
        end
        if (rd_bytes_seen != 4500) begin
            $display("FAIL: Wide DMA read expected 4500 bytes, got %0d", rd_bytes_seen);
            errors = errors + 1;
        end

        // -----------------------------------------------------------------
        // Test D: Wide DMA bounded AWREADY=0 stall (18 cycles) with WREADY=1
        //         Unaligned 160-byte write + readback crossing 0x4000 4KB boundary (0x3FD5 .. 0x4074)
        // -----------------------------------------------------------------
        @(posedge clk);
        for (idx = 16'h3FC0; idx < 16'h40A0; idx = idx + 1) begin
            mem[idx] = 8'h5C;
        end
        m_axi_awready <= 1'b0;
        wr_desc_addr  <= 16'h3FD5;
        wr_desc_len   <= 20'd160;
        wr_desc_tag   <= 8'h99;
        wr_desc_valid <= 1'b1;
        timeout = 0;
        while (!(wr_desc_valid && wr_desc_ready) && timeout < 50) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        wr_desc_valid <= 1'b0;

        // Stream 160 bytes (5 full 32B beats) while holding m_axi_awready=0 for 18 cycles total
        seen_cnt = 0; // reuse seen_cnt as AWREADY stall cycle counter
        for (idx = 0; idx < 5; idx = idx + 1) begin
            for (b_idx = 0; b_idx < 32; b_idx = b_idx + 1) begin
                axis_wr_tdata[b_idx*8 +: 8] <= ((idx * 32 + b_idx) * 19 + 11) & 8'hFF;
                axis_wr_tkeep[b_idx] <= 1'b1;
            end
            axis_wr_tlast  <= (idx == 4);
            axis_wr_tvalid <= 1'b1;
            @(posedge clk);
            seen_cnt = seen_cnt + 1;
            if (seen_cnt >= 18) m_axi_awready <= 1'b1;
            while (!axis_wr_tready) begin
                @(posedge clk);
                seen_cnt = seen_cnt + 1;
                if (seen_cnt >= 18) m_axi_awready <= 1'b1;
            end
        end
        axis_wr_tvalid <= 1'b0;
        axis_wr_tlast  <= 1'b0;
        while (seen_cnt < 18) begin
            @(posedge clk);
            seen_cnt = seen_cnt + 1;
        end
        m_axi_awready <= 1'b1;

        timeout = 0;
        while (!wr_status_valid && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (!wr_status_valid || wr_status_len !== 20'd160 || wr_status_tag !== 8'h99 || wr_status_err !== 4'd0) begin
            $display("FAIL: Test D AWREADY-stall write status mismatch valid=%b len=%0d tag=0x%02x err=%0d",
                     wr_status_valid, wr_status_len, wr_status_tag, wr_status_err);
            errors = errors + 1;
        end
        if (mem[16'h3FD4] !== 8'h5C || mem[16'h3FD5 + 160] !== 8'h5C) begin
            $display("FAIL: Test D AWREADY-stall canary overwritten! before=0x%02x after=0x%02x",
                     mem[16'h3FD4], mem[16'h3FD5 + 160]);
            errors = errors + 1;
        end
        for (idx = 0; idx < 160; idx = idx + 1) begin
            if (mem[16'h3FD5 + idx] !== (((idx * 19 + 11) & 8'hFF))) begin
                if (errors < 15)
                    $display("FAIL: Test D AWREADY-stall mem mismatch at +%0d: got 0x%02x exp 0x%02x",
                             idx, mem[16'h3FD5 + idx], (idx * 19 + 11) & 8'hFF);
                errors = errors + 1;
            end
        end

        repeat (10) @(posedge clk);
        if (aw_rd !== aw_wr || w_rd !== w_wr || w_active !== 1'b0) begin
            $display("FAIL: Unmatched AXI write beats/bursts at end of tb_iverilog_params (aw %0d/%0d, w %0d/%0d, active=%b)",
                     aw_rd, aw_wr, w_rd, w_wr, w_active);
            errors = errors + 1;
        end
        if (errors == 0) begin
            $display("PASS: tb_iverilog_params all checks passed");
            $finish;
        end else begin
            $display("FAIL: tb_iverilog_params failed with %0d errors", errors);
            $fatal(1);
        end
    end

endmodule
`default_nettype wire
