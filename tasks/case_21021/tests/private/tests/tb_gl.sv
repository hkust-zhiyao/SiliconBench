`timescale 1ns / 1ps

module tb_gl;
    reg clk = 1'b0;
    reg rst = 1'b1;

    always #5 clk = ~clk;

    wire        s_axis_rst_out;
    reg  [31:0] s_axis_tdata  = 32'd0;
    reg  [3:0]  s_axis_tkeep  = 4'd0;
    reg         s_axis_tvalid = 1'b0;
    wire        s_axis_tready;
    reg         s_axis_tlast  = 1'b0;
    reg  [2:0]  s_axis_tid    = 3'd0;
    reg  [2:0]  s_axis_tdest  = 3'd0;
    reg  [1:0]  s_axis_tuser  = 2'd0;

    wire        m_axis_rst_out;
    wire [31:0] m_axis_tdata;
    wire [3:0]  m_axis_tkeep;
    wire        m_axis_tvalid;
    reg         m_axis_tready = 1'b0;
    wire        m_axis_tlast;
    wire [2:0]  m_axis_tid;
    wire [2:0]  m_axis_tdest;
    wire [1:0]  m_axis_tuser;

    wire [7:0]  m_axi_awid;
    wire [8:0]  m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awlock;
    wire [3:0]  m_axi_awcache;
    wire [2:0]  m_axi_awprot;
    wire        m_axi_awvalid;
    reg         m_axi_awready = 1'b1;
    wire [63:0] m_axi_wdata;
    wire [7:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    reg         m_axi_wready  = 1'b1;
    reg  [7:0]  m_axi_bid     = 8'd0;
    reg  [1:0]  m_axi_bresp   = 2'd0;
    reg         m_axi_bvalid  = 1'b0;
    wire        m_axi_bready;

    wire [7:0]  m_axi_arid;
    wire [8:0]  m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arlock;
    wire [3:0]  m_axi_arcache;
    wire [2:0]  m_axi_arprot;
    wire        m_axi_arvalid;
    reg         m_axi_arready = 1'b1;
    reg  [7:0]  m_axi_rid     = 8'd0;
    reg  [63:0] m_axi_rdata   = 64'd0;
    reg  [1:0]  m_axi_rresp   = 2'd0;
    reg         m_axi_rlast   = 1'b0;
    reg         m_axi_rvalid  = 1'b0;
    wire        m_axi_rready;

    reg  [8:0]  cfg_fifo_base_addr = 9'h000;
    reg  [8:0]  cfg_fifo_size_mask = 9'h1ff;
    reg         cfg_enable         = 1'b0;
    reg         cfg_reset          = 1'b0;

    wire [9:0]  sts_fifo_occupancy;
    wire        sts_fifo_empty;
    wire        sts_fifo_full;
    wire        sts_reset;
    wire        sts_active;
    wire        sts_hdr_parity_err;

    axi_vfifo_gl dut (
        .clk(clk),
        .rst(rst),
        .s_axis_clk(clk),
        .s_axis_rst(rst),
        .s_axis_rst_out(s_axis_rst_out),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tid(s_axis_tid),
        .s_axis_tdest(s_axis_tdest),
        .s_axis_tuser(s_axis_tuser),
        .m_axis_clk(clk),
        .m_axis_rst(rst),
        .m_axis_rst_out(m_axis_rst_out),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tid(m_axis_tid),
        .m_axis_tdest(m_axis_tdest),
        .m_axis_tuser(m_axis_tuser),
        .m_axi_clk(clk),
        .m_axi_rst(rst),
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
        .m_axi_bid(m_axi_bid),
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
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .cfg_fifo_base_addr(cfg_fifo_base_addr),
        .cfg_fifo_size_mask(cfg_fifo_size_mask),
        .cfg_enable(cfg_enable),
        .cfg_reset(cfg_reset),
        .sts_fifo_occupancy(sts_fifo_occupancy),
        .sts_fifo_empty(sts_fifo_empty),
        .sts_fifo_full(sts_fifo_full),
        .sts_reset(sts_reset),
        .sts_active(sts_active),
        .sts_hdr_parity_err(sts_hdr_parity_err)
    );

    // Simple write-commit AXI4 DRAM model (512B = 64 x 64b words)
    reg [63:0] dram [0:63];
    reg [8:0]  pend_awaddr [0:7];
    reg [7:0]  pend_awlen  [0:7];
    integer    aw_wr = 0, aw_rd = 0;

    reg [63:0] pend_wdata [0:7][0:15];
    reg [7:0]  pend_wstrb [0:7][0:15];
    integer    w_slot = 0, w_beat = 0;
    integer    b_cnt = 0;

    reg        ar_busy = 1'b0;
    reg [8:0]  ar_addr_q = 9'd0;
    reg [7:0]  ar_rem_q  = 8'd0;

    reg        chk_x_en = 1'b0;
    integer    mi, bi;

    initial begin
        for (mi = 0; mi < 64; mi = mi + 1)
            dram[mi] = 64'hDEAD_BEEF_CAFE_F00D;
    end

    always @(posedge clk) begin
        if (rst) begin
            aw_wr <= 0;
            aw_rd <= 0;
            w_slot <= 0;
            w_beat <= 0;
            b_cnt <= 0;
            m_axi_bvalid <= 1'b0;
            ar_busy <= 1'b0;
            m_axi_rvalid <= 1'b0;
            m_axi_rlast <= 1'b0;
            m_axi_arready <= 1'b1;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                pend_awaddr[aw_wr % 8] <= m_axi_awaddr;
                pend_awlen[aw_wr % 8]  <= m_axi_awlen;
                aw_wr <= aw_wr + 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                pend_wdata[w_slot % 8][w_beat] <= m_axi_wdata;
                pend_wstrb[w_slot % 8][w_beat] <= m_axi_wstrb;
                if (m_axi_wlast) begin
                    w_slot <= w_slot + 1;
                    w_beat <= 0;
                end else begin
                    w_beat <= w_beat + 1;
                end
            end

            if (m_axi_bvalid && m_axi_bready) begin
                for (bi = 0; bi <= pend_awlen[aw_rd % 8]; bi = bi + 1) begin : commit_blk
                    integer widx;
                    integer ln;
                    widx = ((pend_awaddr[aw_rd % 8] >> 3) + bi) & 63;
                    for (ln = 0; ln < 8; ln = ln + 1) begin
                        if (pend_wstrb[aw_rd % 8][bi][ln])
                            dram[widx][ln*8 +: 8] <= pend_wdata[aw_rd % 8][bi][ln*8 +: 8];
                    end
                end
                aw_rd <= aw_rd + 1;
                m_axi_bvalid <= 1'b0;
                b_cnt <= 0;
            end else if (!m_axi_bvalid && (aw_rd < aw_wr) && (aw_rd < w_slot)) begin
                if (b_cnt >= 2) begin
                    m_axi_bvalid <= 1'b1;
                end else begin
                    b_cnt <= b_cnt + 1;
                end
            end

            if (!ar_busy) begin
                if (m_axi_arvalid && m_axi_arready) begin
                    ar_busy <= 1'b1;
                    m_axi_arready <= 1'b0;
                    ar_addr_q <= m_axi_araddr + 9'd8;
                    ar_rem_q  <= m_axi_arlen;
                    m_axi_rdata  <= dram[(m_axi_araddr >> 3) & 63];
                    m_axi_rlast  <= (m_axi_arlen == 8'd0);
                    m_axi_rvalid <= 1'b1;
                end
            end else if (m_axi_rvalid && m_axi_rready) begin
                if (ar_rem_q == 8'd0) begin
                    m_axi_rvalid <= 1'b0;
                    m_axi_rlast  <= 1'b0;
                    ar_busy <= 1'b0;
                    m_axi_arready <= 1'b1;
                end else begin
                    m_axi_rdata <= dram[(ar_addr_q >> 3) & 63];
                    ar_addr_q   <= ar_addr_q + 9'd8;
                    ar_rem_q    <= ar_rem_q - 8'd1;
                    m_axi_rlast <= (ar_rem_q == 8'd1);
                end
            end
        end
    end

    // Strict continuous Zero-X monitor on gate-level outputs
    always @(negedge clk) begin
        if (chk_x_en) begin
            if (^{s_axis_rst_out, s_axis_tready, m_axis_rst_out, m_axis_tvalid,
                  m_axi_awvalid, m_axi_wvalid, m_axi_bready, m_axi_arvalid, m_axi_rready,
                  sts_fifo_occupancy, sts_fifo_empty, sts_fifo_full, sts_reset, sts_active, sts_hdr_parity_err} === 1'bx) begin
                $display("FAIL_GL: X/Z on control/status outputs at t=%0t", $time);
                $finish(1);
            end
            if (m_axis_tvalid === 1'b1) begin
                if (^{m_axis_tkeep, m_axis_tlast, m_axis_tid, m_axis_tdest, m_axis_tuser} === 1'bx) begin
                    $display("FAIL_GL: X/Z on m_axis metadata at t=%0t", $time);
                    $finish(1);
                end
                for (bi = 0; bi < 4; bi = bi + 1) begin
                    if (m_axis_tkeep[bi] && (^m_axis_tdata[bi*8 +: 8] === 1'bx)) begin
                        $display("FAIL_GL: X/Z on valid m_axis_tdata lane %0d at t=%0t", bi, $time);
                        $finish(1);
                    end
                end
            end
            if (m_axi_awvalid === 1'b1 && (^{m_axi_awaddr, m_axi_awlen, m_axi_awsize, m_axi_awburst} === 1'bx)) begin
                $display("FAIL_GL: X/Z on m_axi_aw at t=%0t", $time);
                $finish(1);
            end
            if (m_axi_wvalid === 1'b1 && (^{m_axi_wstrb, m_axi_wlast} === 1'bx)) begin
                $display("FAIL_GL: X/Z on m_axi_w control at t=%0t", $time);
                $finish(1);
            end
            if (m_axi_arvalid === 1'b1 && (^{m_axi_araddr, m_axi_arlen, m_axi_arsize, m_axi_arburst} === 1'bx)) begin
                $display("FAIL_GL: X/Z on m_axi_ar at t=%0t", $time);
                $finish(1);
            end
        end
    end

    reg [7:0] rx_bytes [0:63];
    integer   rx_len = 0;
    integer   wait_c;
    reg       gl_s_hs = 1'b0;
    reg       gl_rx_done = 1'b0;

    always @(posedge clk) begin
        gl_s_hs <= s_axis_tvalid && s_axis_tready;
        if (!rst && m_axis_tvalid && m_axis_tready) begin : gl_rx_mon
            integer ln;
            for (ln = 0; ln < 4; ln = ln + 1) begin
                if (m_axis_tkeep[ln]) begin
                    rx_bytes[rx_len] = m_axis_tdata[ln*8 +: 8];
                    rx_len = rx_len + 1;
                end
            end
            if (m_axis_tlast) begin
                if (m_axis_tid !== 3'd5 || m_axis_tdest !== 3'd3 || m_axis_tuser !== 2'h2) begin
                    $display("FAIL_GL: metadata mismatch id=%h dest=%h user=%h", m_axis_tid, m_axis_tdest, m_axis_tuser);
                    $finish(1);
                end
                gl_rx_done <= 1'b1;
            end
        end
    end

    initial begin
        rst = 1'b1;
        repeat (6) @(negedge clk);
        chk_x_en = 1'b1;
        // Verify deterministic reset values while rst == 1
        if (sts_fifo_occupancy !== 10'd0 || sts_reset !== 1'b1 || sts_active !== 1'b0) begin
            $display("FAIL_GL: bad reset state occ=%h rst=%b act=%b", sts_fifo_occupancy, sts_reset, sts_active);
            $finish(1);
        end
        rst = 1'b0;
        cfg_enable = 1'b1;

        wait_c = 0;
        while ((sts_active !== 1'b1 || s_axis_rst_out !== 1'b0 || m_axis_rst_out !== 1'b0) && wait_c < 80) begin
            @(negedge clk);
            wait_c = wait_c + 1;
        end
        if (sts_active !== 1'b1) begin
            $display("FAIL_GL: never became active");
            $finish(1);
        end
        if (sts_fifo_empty !== 1'b1 || sts_fifo_occupancy !== 10'd0) begin
            $display("FAIL_GL: post-reset empty=%b occ=%h", sts_fifo_empty, sts_fifo_occupancy);
            $finish(1);
        end

        // Send a 10-byte frame (3 beats on 32-bit AXIS: 4B + 4B + 2B) while m_axis_tready == 0
        m_axis_tready = 1'b0;
        @(negedge clk);
        s_axis_tdata  = 32'h0403_0201;
        s_axis_tkeep  = 4'hF;
        s_axis_tlast  = 1'b0;
        s_axis_tid    = 3'd5;
        s_axis_tdest  = 3'd3;
        s_axis_tuser  = 2'h2;
        s_axis_tvalid = 1'b1;
        @(negedge clk);
        while (!gl_s_hs) @(negedge clk);

        s_axis_tdata  = 32'h0807_0605;
        s_axis_tkeep  = 4'hF;
        s_axis_tlast  = 1'b0;
        @(negedge clk);
        while (!gl_s_hs) @(negedge clk);

        s_axis_tdata  = 32'h0000_0A09;
        s_axis_tkeep  = 4'h3;
        s_axis_tlast  = 1'b1;
        @(negedge clk);
        while (!gl_s_hs) @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;

        // Wait until m_axis_tvalid asserts at decoder output while m_axis_tready == 0
        wait_c = 0;
        while (!m_axis_tvalid && wait_c < 1500) begin
            @(negedge clk);
            wait_c = wait_c + 1;
        end
        if (!m_axis_tvalid) begin
            $display("FAIL_GL: timeout waiting for m_axis_tvalid");
            $finish(1);
        end
        repeat (12) @(negedge clk);
        if (sts_fifo_empty !== 1'b0) begin
            $display("FAIL_GL: sts_fifo_empty asserted while stalled in decoder");
            $finish(1);
        end

        // Drain and verify frame
        m_axis_tready = 1'b1;
        wait_c = 0;
        while (!gl_rx_done && wait_c < 100) begin
            @(negedge clk);
            wait_c = wait_c + 1;
        end

        if (rx_len != 10) begin
            $display("FAIL_GL: rx_len=%0d expected 10", rx_len);
            $finish(1);
        end
        for (bi = 0; bi < 10; bi = bi + 1) begin
            if (rx_bytes[bi] !== (bi + 1)) begin
                $display("FAIL_GL: byte[%0d]=%02x expected %02x", bi, rx_bytes[bi], bi + 1);
                $finish(1);
            end
        end

        repeat (20) @(negedge clk);
        if (sts_fifo_empty !== 1'b1 || sts_fifo_occupancy !== 10'd0 || sts_hdr_parity_err !== 1'b0) begin
            $display("FAIL_GL: post-drain status empty=%b occ=%0d perr=%b", sts_fifo_empty, sts_fifo_occupancy, sts_hdr_parity_err);
            $finish(1);
        end

        // Re-populate non-zero occupancy & decoder output, then verify synchronous rst clears all outputs
        m_axis_tready = 1'b0;
        @(negedge clk);
        s_axis_tdata  = 32'hCAFE_BEEF;
        s_axis_tkeep  = 4'hF;
        s_axis_tlast  = 1'b1;
        s_axis_tvalid = 1'b1;
        @(negedge clk);
        while (!gl_s_hs) @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        wait_c = 0;
        while (!m_axis_tvalid && wait_c < 1500) begin
            @(negedge clk);
            wait_c = wait_c + 1;
        end
        rst = 1'b1;
        repeat (6) @(negedge clk);
        if (sts_fifo_occupancy !== 10'd0 || m_axis_tvalid !== 1'b0 || sts_reset !== 1'b1 || sts_active !== 1'b0) begin
            $display("FAIL_GL: post-traffic synchronous rst failed occ=%h mvalid=%b rst=%b act=%b",
                     sts_fifo_occupancy, m_axis_tvalid, sts_reset, sts_active);
            $finish(1);
        end
        rst = 1'b0;
        wait_c = 0;
        while ((sts_active !== 1'b1 || s_axis_rst_out !== 1'b0 || m_axis_rst_out !== 1'b0) && wait_c < 80) begin
            @(negedge clk);
            wait_c = wait_c + 1;
        end
        if (sts_active !== 1'b1 || sts_fifo_empty !== 1'b1 || sts_fifo_occupancy !== 10'd0) begin
            $display("FAIL_GL: post-traffic reset recovery failed act=%b empty=%b occ=%h",
                     sts_active, sts_fifo_empty, sts_fifo_occupancy);
            $finish(1);
        end

        $display("PASS_GL");
        $finish(0);
    end
endmodule
