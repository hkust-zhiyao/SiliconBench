`timescale 1ps/1ps

module tb_sg_dmac;
  int unsigned seed = 101;
  initial void'($value$plusargs("seed=%d", seed));

  // Four asynchronous clocks with prime-ratio periods:
  // - req_clk: configurable (default 3.4 ns, slowed in Test 3 to stress rewind CDC backpressure!)
  // - sg_clk:  2.2 ns
  // - src_clk: 1.4 ns (fast AXI-Stream source -> stresses bl_valid & early_tlast backpressure!)
  // - dst_clk: 2.6 ns
  int req_half_ps = 1700;
  logic req_clk = 1'b0, sg_clk = 1'b0, src_clk = 1'b0, dst_clk = 1'b0;
  always #(req_half_ps) req_clk = ~req_clk;
  always #1100 sg_clk  = ~sg_clk;
  always #700  src_clk = ~src_clk;
  always #1300 dst_clk = ~dst_clk;

  logic req_resetn = 1'b0;
  logic sg_resetn  = 1'b0;
  logic src_resetn = 1'b0;
  logic dst_resetn = 1'b0;

  logic req_enable = 1'b1, sg_enable = 1'b1, src_enable = 1'b1, dest_enable = 1'b1;
  logic        desc_req_valid = 1'b0;
  wire         desc_req_ready;
  logic [31:3] desc_req_address = '0;
  logic        desc_sync_start = 1'b0;

  wire         xfer_eot;
  wire [31:0]  xfer_desc_id;
  wire         xfer_eot_irq;
  wire [4:0]   xfer_measured_len;
  wire         xfer_partial;
  wire         xfer_resp_valid;
  logic        xfer_resp_ready = 1'b1;

  logic        m_sg_axi_arready = 1'b1;
  wire         m_sg_axi_arvalid;
  wire [31:0]  m_sg_axi_araddr;
  wire [7:0]   m_sg_axi_arlen;
  wire [2:0]   m_sg_axi_arsize;
  wire [1:0]   m_sg_axi_arburst;
  logic [63:0] m_sg_axi_rdata = '0;
  logic        m_sg_axi_rlast = 1'b0;
  wire         m_sg_axi_rready;
  logic        m_sg_axi_rvalid = 1'b0;
  logic [1:0]  m_sg_axi_rresp = 2'b00;

  wire         s_axis_ready;
  logic        s_axis_valid = 1'b0;
  logic [31:0] s_axis_data = '0;
  logic        s_axis_last = 1'b0;
  logic [0:0]  s_axis_user = 1'b1;
  wire         s_axis_xfer_req;

  wire [31:0]  m_axi_awaddr;
  wire [7:0]   m_axi_awlen;
  wire [2:0]   m_axi_awsize;
  wire [1:0]   m_axi_awburst;
  wire         m_axi_awvalid;
  logic        m_axi_awready = 1'b1;
  wire [63:0]  m_axi_wdata;
  wire [7:0]   m_axi_wstrb;
  logic        m_axi_wready = 1'b1;
  wire         m_axi_wvalid;
  wire         m_axi_wlast;
  logic        m_axi_bvalid = 1'b0;
  logic [1:0]  m_axi_bresp = 2'b00;
  wire         m_axi_bready;

  // Instantiate cluster with ASYMMETRIC 32-bit Stream Source -> 64-bit AXI4 MM Dest!
  // Tests resize_src + partial-beat strobe generation (8'h0F vs 8'hFF) + multi-FSM backpressure!
  dmac_sg_cluster #(
    .DMA_DATA_WIDTH_SRC (32),
    .DMA_DATA_WIDTH_DEST(64),
    .DMA_AXI_ADDR_WIDTH (32),
    .DMA_LENGTH_WIDTH   (16),
    .MAX_BYTES_PER_BURST(32),
    .BYTES_PER_BURST_WIDTH(5),
    .FIFO_SIZE          (4)
  ) dut (
    .req_clk(req_clk),
    .req_resetn(req_resetn),
    .req_enable(req_enable),
    .sg_enable(sg_enable),
    .src_enable(src_enable),
    .dest_enable(dest_enable),
    .desc_req_valid(desc_req_valid),
    .desc_req_ready(desc_req_ready),
    .desc_req_address(desc_req_address),
    .desc_sync_start(desc_sync_start),
    .xfer_eot(xfer_eot),
    .xfer_desc_id(xfer_desc_id),
    .xfer_eot_irq(xfer_eot_irq),
    .xfer_measured_len(xfer_measured_len),
    .xfer_partial(xfer_partial),
    .xfer_resp_valid(xfer_resp_valid),
    .xfer_resp_ready(xfer_resp_ready),
    .m_sg_axi_aclk(sg_clk),
    .m_sg_axi_aresetn(sg_resetn),
    .m_sg_axi_arready(m_sg_axi_arready),
    .m_sg_axi_arvalid(m_sg_axi_arvalid),
    .m_sg_axi_araddr(m_sg_axi_araddr),
    .m_sg_axi_arlen(m_sg_axi_arlen),
    .m_sg_axi_arsize(m_sg_axi_arsize),
    .m_sg_axi_arburst(m_sg_axi_arburst),
    .m_sg_axi_rdata(m_sg_axi_rdata),
    .m_sg_axi_rlast(m_sg_axi_rlast),
    .m_sg_axi_rready(m_sg_axi_rready),
    .m_sg_axi_rvalid(m_sg_axi_rvalid),
    .m_sg_axi_rresp(m_sg_axi_rresp),
    .s_axis_aclk(src_clk),
    .s_axis_aresetn(src_resetn),
    .s_axis_ready(s_axis_ready),
    .s_axis_valid(s_axis_valid),
    .s_axis_data(s_axis_data),
    .s_axis_last(s_axis_last),
    .s_axis_user(s_axis_user),
    .s_axis_xfer_req(s_axis_xfer_req),
    .m_dest_axi_aclk(dst_clk),
    .m_dest_axi_aresetn(dst_resetn),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wready(m_axi_wready),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wlast(m_axi_wlast),
    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bresp(m_axi_bresp),
    .m_axi_bready(m_axi_bready)
  );

  // Descriptor RAM: 256 x 64-bit words (indexed by word addr [10:3])
  logic [63:0] desc_mem [0:255];
  logic [1:0]  desc_rresp_inject [0:255]; // non-zero injects SLVERR on that word
  bit          inject_spurious_early_rvalid = 1'b0;

  // Destination byte-addressable RAM: 16 KB
  logic [7:0] dst_mem [0:16383];

  // Descriptor AXI4 Read Responder (supports early/unsolicited RVALID test when rready==0!)
  int sg_rd_active = 0;
  int sg_rd_idx = 0;
  int sg_rd_rem = 0;

  always @(posedge sg_clk) begin
    if (!sg_resetn) begin
      sg_rd_active   <= 0;
      m_sg_axi_rvalid <= 1'b0;
      m_sg_axi_rlast  <= 1'b0;
      m_sg_axi_rresp  <= 2'b00;
      m_sg_axi_rdata  <= 64'h0;
    end else begin
      if (!sg_rd_active) begin
        if (m_sg_axi_arvalid && m_sg_axi_arready) begin
          sg_rd_active    <= 1;
          sg_rd_idx       <= m_sg_axi_araddr[10:3];
          sg_rd_rem       <= m_sg_axi_arlen;
          m_sg_axi_rvalid <= 1'b1;
          m_sg_axi_rdata  <= desc_mem[m_sg_axi_araddr[10:3]];
          m_sg_axi_rresp  <= desc_rresp_inject[m_sg_axi_araddr[10:3]];
          m_sg_axi_rlast  <= (m_sg_axi_arlen == 0);
        end else if (inject_spurious_early_rvalid && !m_sg_axi_rready) begin
          // Drive garbage on R channel while master has m_sg_axi_rready == 0!
          // Compliant AXI master MUST ignore RVALID when RREADY == 0!
          m_sg_axi_rvalid <= 1'b1;
          m_sg_axi_rdata  <= 64'hDEAD_BEEF_CAFE_BAD0;
          m_sg_axi_rresp  <= 2'b00;
          m_sg_axi_rlast  <= 1'b0;
        end else begin
          m_sg_axi_rvalid <= 1'b0;
          m_sg_axi_rlast  <= 1'b0;
        end
      end else begin
        if (m_sg_axi_rvalid && m_sg_axi_rready) begin
          if (sg_rd_rem == 0) begin
            sg_rd_active    <= 0;
            m_sg_axi_rvalid <= 1'b0;
            m_sg_axi_rlast  <= 1'b0;
            m_sg_axi_rresp  <= 2'b00;
          end else begin
            sg_rd_idx       <= sg_rd_idx + 1;
            sg_rd_rem       <= sg_rd_rem - 1;
            m_sg_axi_rvalid <= 1'b1;
            m_sg_axi_rdata  <= desc_mem[sg_rd_idx + 1];
            m_sg_axi_rresp  <= desc_rresp_inject[sg_rd_idx + 1];
            m_sg_axi_rlast  <= (sg_rd_rem == 1);
          end
        end
      end
    end
  end

  // Destination AXI4 Write Responder (decoupled AW and W queues + configurable backpressure)
  logic [31:0] aw_addr_q[$];
  logic [7:0]  aw_len_q[$];
  int          b_pend_q[$];

  logic        w_burst_active = 1'b0;
  logic [31:0] w_cur_addr = '0;
  int          w_beats_rem = 0;
  int          total_aw_bursts = 0;
  int          total_w_bursts = 0;
  bit          stall_dest_axi = 1'b0;
  bit          throttle_dest_w = 1'b0;
  int          w_throt_cnt = 0;

  always @(posedge dst_clk) begin
    if (!dst_resetn) begin
      aw_addr_q.delete();
      aw_len_q.delete();
      b_pend_q.delete();
      w_burst_active <= 1'b0;
      m_axi_bvalid   <= 1'b0;
      m_axi_awready  <= 1'b0;
      m_axi_wready   <= 1'b0;
      w_throt_cnt    <= 0;
    end else begin
      w_throt_cnt   <= w_throt_cnt + 1;
      m_axi_awready <= stall_dest_axi ? 1'b0 : 1'b1;
      m_axi_wready  <= stall_dest_axi ? 1'b0 : (throttle_dest_w ? (w_throt_cnt[1:0] == 2'b11) : 1'b1);

      if (m_axi_awvalid && m_axi_awready) begin
        aw_addr_q.push_back(m_axi_awaddr);
        aw_len_q.push_back(m_axi_awlen);
        total_aw_bursts <= total_aw_bursts + 1;
      end

      if (m_axi_wvalid && m_axi_wready) begin
        logic [31:0] eff_addr;
        int          eff_rem;
        if (!w_burst_active) begin
          if (aw_addr_q.size() == 0) begin
            // Write data arrived slightly ahead of AW; wait or fail? No, in dest_axi_mm W can lead AW by 1 cycle if AW stalled!
            // Actually stall_dest_axi stalls BOTH awready & wready together, and when ready=1 AW is accepted on or before W!
            $display("FAIL_SG_DMAC: W beat arrived with empty AW queue!");
            $fatal(1);
          end
          eff_addr = aw_addr_q.pop_front();
          eff_rem  = aw_len_q.pop_front();
        end else begin
          eff_addr = w_cur_addr;
          eff_rem  = w_beats_rem;
        end

        for (int b = 0; b < 8; b++) begin
          if (m_axi_wstrb[b]) begin
            dst_mem[(eff_addr + b) & 16383] <= m_axi_wdata[b*8 +: 8];
          end
        end

        if (eff_rem == 0) begin
          if (!m_axi_wlast) begin
            $display("FAIL_SG_DMAC: Expected m_axi_wlast==1 at end of AWLEN burst (addr=0x%08x)", eff_addr);
            $fatal(1);
          end
          w_burst_active <= 1'b0;
          b_pend_q.push_back(1);
          total_w_bursts <= total_w_bursts + 1;
        end else begin
          if (m_axi_wlast) begin
            $display("FAIL_SG_DMAC: Premature m_axi_wlast==1 with %0d beats remaining (addr=0x%08x)", eff_rem, eff_addr);
            $fatal(1);
          end
          w_burst_active <= 1'b1;
          w_cur_addr     <= eff_addr + 8;
          w_beats_rem    <= eff_rem - 1;
        end
      end

      if (m_axi_bvalid && m_axi_bready) begin
        m_axi_bvalid <= 1'b0;
      end
      if ((!m_axi_bvalid || m_axi_bready) && b_pend_q.size() > 0) begin
        void'(b_pend_q.pop_front());
        m_axi_bvalid <= 1'b1;
        m_axi_bresp  <= 2'b00;
      end
    end
  end

  // Completion monitor in req_clk
  logic [31:0] got_desc_id_q[$];
  logic        got_eot_irq_q[$];
  logic        got_partial_q[$];
  always @(posedge req_clk) begin
    if (!req_resetn) begin
      got_desc_id_q.delete();
      got_eot_irq_q.delete();
      got_partial_q.delete();
    end else if (xfer_resp_valid && xfer_resp_ready && xfer_eot) begin
      got_desc_id_q.push_back(xfer_desc_id);
      got_eot_irq_q.push_back(xfer_eot_irq);
      got_partial_q.push_back(xfer_partial);
    end
  end

  // Helper: write a 6-word descriptor at word index `widx` (byte address `widx * 8`)
  task automatic write_desc(
    input int          widx,
    input logic [31:0] desc_id,
    input bit          is_last,
    input bit          eot_irq,
    input logic [31:0] dst_byte_addr,
    input logic [15:0] x_len_minus_1,
    input int          next_widx
  );
    desc_mem[widx + 0] = {desc_id, 30'h0, eot_irq, is_last};
    desc_mem[widx + 1] = {32'h0, dst_byte_addr}; // [31:3] used for 64-bit dest
    desc_mem[widx + 2] = 64'h0;
    desc_mem[widx + 3] = {32'h0, 32'(next_widx * 8)};
    desc_mem[widx + 4] = {16'h0, x_len_minus_1, 32'h0};
    desc_mem[widx + 5] = 64'h0;
    for (int k = 0; k < 6; k++) desc_rresp_inject[widx + k] = 2'b00;
  endtask

  task automatic issue_chain(input int first_widx, input bit sync_start);
    int guard = 0;
    @(negedge req_clk);
    desc_req_address = 29'(first_widx);
    desc_sync_start  = sync_start;
    desc_req_valid   = 1'b1;
    #1;
    while (!desc_req_ready) begin
      guard = guard + 1;
      if (guard > 2000) begin $display("FAIL_SG_DMAC: Timeout on desc_req_ready"); $fatal(1); end
      @(negedge req_clk);
      #1;
    end
    @(negedge req_clk);
    desc_req_valid = 1'b0;
  endtask

  task automatic push_stream_packet(
    input int          num_words32,
    input logic [31:0] base_tag,
    input int          pre_sync_junk_beats,
    input bit          assert_tlast_at_end
  );
    int guard;
    // Compliant AXI4-Stream master: drive at negedge (half-cycle setup & hold around posedge src_clk!)
    for (int j = 0; j < pre_sync_junk_beats; j++) begin
      @(negedge src_clk);
      s_axis_valid = 1'b1;
      s_axis_data  = 32'hBAD0_0000 | j[15:0];
      s_axis_user  = 1'b0;
      s_axis_last  = 1'b0;
      guard = 0;
      #1;
      while (!s_axis_ready) begin
        guard = guard + 1;
        if (guard > 4000) begin
          $display("FAIL_SG_DMAC: Deadlock on pre-sync AXI-Stream beat (s_axis_ready stuck low while s_axis_user==0)!");
          $fatal(1);
        end
        @(negedge src_clk);
        #1;
      end
    end

    for (int i = 0; i < num_words32; i++) begin
      @(negedge src_clk);
      s_axis_valid = 1'b1;
      s_axis_data  = base_tag + i;
      s_axis_user  = (i == 0) ? 1'b1 : 1'b0;
      s_axis_last  = (assert_tlast_at_end && (i == num_words32 - 1)) ? 1'b1 : 1'b0;
      guard = 0;
      #1;
      while (!s_axis_ready) begin
        guard = guard + 1;
        if (guard > 6000) begin
          $display("FAIL_SG_DMAC: Stream deadlock on payload word %0d/%0d", i, num_words32);
          $fatal(1);
        end
        @(negedge src_clk);
        #1;
      end
    end
    @(negedge src_clk);
    s_axis_valid = 1'b0;
    s_axis_last  = 1'b0;
    s_axis_user  = 1'b0;
  endtask

  initial begin
    for (int i = 0; i < 256; i++) begin desc_mem[i] = 64'h0; desc_rresp_inject[i] = 2'b00; end
    for (int i = 0; i < 16384; i++) dst_mem[i] = 8'hA5;

    repeat (8) @(posedge req_clk);
    req_resetn = 1'b1;
    sg_resetn  = 1'b1;
    src_resetn = 1'b1;
    dst_resetn = 1'b1;
    repeat (8) @(posedge req_clk);

    // =========================================================================
    // TEST 1: 9-Descriptor Chain + Early Unsolicited RVALID While Stalled +
    //         Completion Backpressure (`xfer_resp_ready=0` holding 9 IDs!) +
    //         Mid-Burst WREADY Throttling + Asymmetric Odd 32-bit Beats (8'h0F)!
    // =========================================================================
    stall_dest_axi = 1'b1;
    xfer_resp_ready = 1'b0;
    inject_spurious_early_rvalid = 1'b1;

    // Each transfers 3 x 32-bit words = 12 bytes (`x_len_minus_1 = 16'd11`) to 0x100 + d*64!
    // Note: 3 words * 1.4ns = 4.2ns/packet < 8.0ns CDC round-trip of ADDRESS_WIDTH(0) bl_fifo,
    // AND odd 32-bit word count tests partial 64-bit final beat strobe 8'h0F (bytes [12..15] == 8'hA5)!
    for (int d = 0; d < 8; d++) begin
      write_desc(d * 8, 32'h1000_0000 + seed + d, (d == 7), (d[0] == 1'b1), 32'h0100 + d * 64, 16'd11, (d + 1) * 8);
    end

    issue_chain(0, 1'b1);
    repeat (130) @(posedge sg_clk); // Descriptor 6 stalls in STATE_DESC_READY (`rready==0`) while spurious RVALID fires!
    inject_spurious_early_rvalid = 1'b0;
    stall_dest_axi = 1'b0;
    throttle_dest_w = 1'b1; // AWREADY=1 while WREADY=1 every 4th cycle -> exercises dest_burst_valid && !dest_burst_ready!

    for (int d = 0; d < 8; d++) begin
      push_stream_packet(3, 32'hC000_0000 + (d << 8), (d == 0) ? 3 : 0, 1'b0);
    end
    // Wait for bursts to write into dst_mem while xfer_resp_ready is still 0 (holding 9 IDs in dmac_sg.i_fifo!), then drain!
    repeat (60) @(posedge dst_clk);
    @(negedge req_clk);
    xfer_resp_ready = 1'b1;

    begin
      int guard;
      guard = 0;
      while (got_desc_id_q.size() < 8) begin
        @(posedge req_clk);
        guard = guard + 1;
        if (guard > 8000) begin
          $display("FAIL_SG_DMAC: Timeout waiting for 9-descriptor chain completions (got %0d)", got_desc_id_q.size());
          $fatal(1);
        end
      end
    end
    throttle_dest_w = 1'b0;

    for (int d = 0; d < 8; d++) begin
      logic [31:0] got_id;
      logic        got_irq;
      got_id  = got_desc_id_q.pop_front();
      got_irq = got_eot_irq_q.pop_front();
      void'(got_partial_q.pop_front());
      if (got_id !== (32'h1000_0000 + seed + d) || got_irq !== d[0]) begin
        $display("FAIL_SG_DMAC: Desc %0d completion ID/IRQ mismatch: got id=0x%08x irq=%b", d, got_id, got_irq);
        $fatal(1);
      end
      for (int w = 0; w < 3; w++) begin
        logic [31:0] got_w;
        got_w = {dst_mem[32'h100 + d*64 + w*4 + 3], dst_mem[32'h100 + d*64 + w*4 + 2],
                 dst_mem[32'h100 + d*64 + w*4 + 1], dst_mem[32'h100 + d*64 + w*4 + 0]};
        if (got_w !== (32'hC000_0000 + (d << 8) + w)) begin
          $display("FAIL_SG_DMAC: Desc %0d word %0d data mismatch: got 0x%08x", d, w, got_w);
          $fatal(1);
        end
      end
      // Verify upper 4 bytes of 2nd 64-bit beat were masked off by wstrb == 8'h0F!
      for (int b = 12; b < 16; b++) begin
        if (dst_mem[32'h100 + d*64 + b] !== 8'hA5) begin
          $display("FAIL_SG_DMAC: Tail wstrb clobbered byte %0d of desc %0d (got 0x%02x, expected 0xA5)", b, d, dst_mem[32'h100 + d*64 + b]);
          $fatal(1);
        end
      end
    end

    // =========================================================================
    // TEST 2: Mid-Burst Descriptor Read SLVERR (Beat 2 of 6) -> Must Drain Until
    //         RLAST, Suppress Corrupted Push, Return Cleanly to Idle!
    // =========================================================================
    write_desc(80, 32'hBAD0_DE5C, 1'b0, 1'b1, 32'h0600, 16'd31, 88);
    desc_rresp_inject[80 + 2] = 2'b10; // SLVERR on Beat 2 of 6!
    issue_chain(80, 1'b0);
    repeat (40) @(posedge sg_clk);
    repeat (25) @(posedge req_clk);
    if (!desc_req_ready || s_axis_xfer_req || got_desc_id_q.size() != 0) begin
      $display("FAIL_SG_DMAC: Corrupted descriptor on SLVERR was not cleanly drained/aborted (ready=%b xfer_req=%b)", desc_req_ready, s_axis_xfer_req);
      $fatal(1);
    end

    // =========================================================================
    // TEST 2B: Mid-Fetch sg_enable Pulsed Low Then Restored Before RLAST ->
    //          Sticky Fetch Abort Must Drain 6-Beat Burst to RLAST & NOT Commit!
    // =========================================================================
    write_desc(184, 32'hBAD1_56E0, 1'b0, 1'b1, 32'h0E00, 16'd15, 192);
    write_desc(192, 32'hBAD1_56E1, 1'b1, 1'b1, 32'h0E40, 16'd15, 200);
    issue_chain(184, 1'b0);
    begin
      int guard;
      guard = 0;
      while (!(sg_rd_active && (sg_rd_rem == 4))) begin
        @(negedge sg_clk);
        guard = guard + 1;
        if (guard > 2000) begin
          $display("FAIL_SG_DMAC: Timeout waiting for mid-fetch beat in TEST 2B");
          $fatal(1);
        end
      end
      // Deassert sg_enable for 1 sg_clk posedge mid-burst, then reassert well before RLAST!
      sg_enable = 1'b0;
      @(negedge sg_clk);
      sg_enable = 1'b1;
      if (!sg_rd_active || m_sg_axi_rlast) begin
        $display("FAIL_SG_DMAC: TEST 2B sg_enable pulse did not complete before RLAST!");
        $fatal(1);
      end
    end
    repeat (35) @(posedge sg_clk);
    repeat (25) @(posedge req_clk);
    if (sg_rd_active || !desc_req_ready || s_axis_xfer_req || got_desc_id_q.size() != 0) begin
      $display("FAIL_SG_DMAC: Mid-fetch pulsed sg_enable=0 committed descriptor instead of aborting (rd_act=%0d ready=%b xfer_req=%b ids=%0d)",
               sg_rd_active, desc_req_ready, s_axis_xfer_req, got_desc_id_q.size());
      $fatal(1);
    end

    // =========================================================================
    // TEST 2C: Mid-Fetch sg_enable Held Low Through RLAST -> Must Drain Burst
    //          Cleanly to RLAST, Stay Idle Without Committing!
    // =========================================================================
    write_desc(200, 32'hBAD2_56E0, 1'b0, 1'b1, 32'h0E80, 16'd15, 208);
    write_desc(208, 32'hBAD2_56E1, 1'b1, 1'b1, 32'h0EC0, 16'd15, 216);
    issue_chain(200, 1'b0);
    begin
      int guard;
      guard = 0;
      while (!(sg_rd_active && (sg_rd_rem == 3))) begin
        @(negedge sg_clk);
        guard = guard + 1;
        if (guard > 2000) begin
          $display("FAIL_SG_DMAC: Timeout waiting for mid-fetch beat in TEST 2C");
          $fatal(1);
        end
      end
      sg_enable = 1'b0;
    end
    repeat (25) @(posedge sg_clk);
    repeat (20) @(posedge req_clk);
    if (sg_rd_active || !desc_req_ready || s_axis_xfer_req || got_desc_id_q.size() != 0) begin
      $display("FAIL_SG_DMAC: Mid-fetch held sg_enable=0 failed to drain/abort cleanly (rd_act=%0d ready=%b xfer_req=%b)",
               sg_rd_active, desc_req_ready, s_axis_xfer_req);
      $fatal(1);
    end
    @(negedge sg_clk);
    sg_enable = 1'b1;
    repeat (15) @(posedge sg_clk);
    repeat (15) @(posedge req_clk);
    if (sg_rd_active || !desc_req_ready || s_axis_xfer_req || got_desc_id_q.size() != 0) begin
      $display("FAIL_SG_DMAC: Spurious activity after reasserting sg_enable=1 following aborted fetch!");
      $fatal(1);
    end

    // =========================================================================
    // TEST 2D: STATE_DESC_READY sg_enable Deassertion -> Strict 1-to-1 Descriptor
    //          vs ID/IRQ Pairing (Either Clean Cancel OR Atomic 1-Desc Commit,
    //          Never Fetching Trailing Desc B & Zero Orphaned IDs on Next Chain!)
    // =========================================================================
    write_desc(216, 32'h2D00_000A, 1'b0, 1'b1, 32'h0E00, 16'd11, 224);
    write_desc(224, 32'h2D00_000B, 1'b1, 1'b0, 32'h0E40, 16'd11, 232);
    issue_chain(216, 1'b0);
    begin
      int guard;
      bit desc_a_dispatched;
      guard = 0;
      while (!sg_rd_active) begin
        @(negedge sg_clk);
        guard = guard + 1;
        if (guard > 2000) begin
          $display("FAIL_SG_DMAC: Timeout waiting for Desc A burst start in TEST 2D");
          $fatal(1);
        end
      end
      guard = 0;
      while (sg_rd_active) begin
        @(negedge sg_clk);
        guard = guard + 1;
        if (guard > 2000) begin
          $display("FAIL_SG_DMAC: Timeout waiting for Desc A RLAST in TEST 2D");
          $fatal(1);
        end
      end
      sg_enable = 1'b0;
      desc_a_dispatched = 1'b0;
      for (int k = 0; k < 40; k++) begin
        @(posedge req_clk);
        if (s_axis_xfer_req) desc_a_dispatched = 1'b1;
      end
      if (desc_a_dispatched) begin
        push_stream_packet(3, 32'h2DA0_0000, 0, 1'b0);
        guard = 0;
        while (got_desc_id_q.size() < 1) begin
          @(posedge req_clk);
          guard = guard + 1;
          if (guard > 3000) begin
            $display("FAIL_SG_DMAC: Dispatched Desc A hung in TEST 2D!");
            $fatal(1);
          end
        end
        if (got_desc_id_q.pop_front() !== 32'h2D00_000A || got_eot_irq_q.pop_front() !== 1'b1) begin
          $display("FAIL_SG_DMAC: Dispatched Desc A completion ID/IRQ mismatch in TEST 2D!");
          $fatal(1);
        end
        void'(got_partial_q.pop_front());
        for (int w = 0; w < 3; w++) begin
          logic [31:0] dw;
          dw = {dst_mem[32'hE00 + w*4 + 3], dst_mem[32'hE00 + w*4 + 2],
                dst_mem[32'hE00 + w*4 + 1], dst_mem[32'hE00 + w*4 + 0]};
          if (dw !== (32'h2DA0_0000 + w)) begin
            $display("FAIL_SG_DMAC: Dispatched Desc A word %0d mismatch: got 0x%08x", w, dw);
            $fatal(1);
          end
        end
      end
      repeat (20) @(posedge sg_clk);
      repeat (20) @(posedge req_clk);
      if (sg_rd_active || !desc_req_ready || s_axis_xfer_req || got_desc_id_q.size() != 0 || dst_mem[32'hE40] !== 8'hA5) begin
        $display("FAIL_SG_DMAC: Trailing Desc B was falsely fetched or state stuck after sg_enable=0 in TEST 2D!");
        $fatal(1);
      end
    end
    @(negedge sg_clk);
    sg_enable = 1'b1;
    repeat (10) @(posedge sg_clk);
    // Verify zero orphaned IDs in dmac_sg.i_fifo by running fresh Desc C (0x2D00_000C)!
    write_desc(232, 32'h2D00_000C, 1'b1, 1'b0, 32'h0E40, 16'd11, 240);
    issue_chain(232, 1'b0);
    push_stream_packet(3, 32'h2DC0_0000, 0, 1'b0);
    begin
      int guard;
      logic [31:0] cid_got;
      logic cirq_got;
      guard = 0;
      while (got_desc_id_q.size() < 1) begin
        @(posedge req_clk);
        guard = guard + 1;
        if (guard > 3000) begin
          $display("FAIL_SG_DMAC: Fresh Desc C after TEST 2D re-enable hung!");
          $fatal(1);
        end
      end
      cid_got  = got_desc_id_q.pop_front();
      cirq_got = got_eot_irq_q.pop_front();
      void'(got_partial_q.pop_front());
      if (cid_got !== 32'h2D00_000C || cirq_got !== 1'b0) begin
        $display("FAIL_SG_DMAC: Orphaned ID/IRQ desynchronization after TEST 2D: got id=0x%08x irq=%b exp 0x2D00000C/0", cid_got, cirq_got);
        $fatal(1);
      end
    end

    // =========================================================================
    // TEST 3: 5 Back-to-Back Early-TLAST Short Packets Under Destination AXI Stall
    //         + Slow req_clk Rewind Backpressure + Clean xfer_req Deassertion!
    // =========================================================================
    for (int d = 0; d < 5; d++) begin
      write_desc(96 + d * 8, 32'h2000_0000 + d, (d == 4), 1'b1, 32'h0800 + d * 128, 16'd63, 96 + (d + 1) * 8);
    end
    stall_dest_axi = 1'b1;
    issue_chain(96, 1'b0);
    repeat (110) @(posedge sg_clk); // Let descriptors prefetch before rapid early-TLAST stream bursts!
    req_half_ps = 5500; // Slow req_clk (11.0ns vs 1.4ns src_clk) to force rewind_req_fifo & bl_fifo saturation!

    // Send 2 short early-TLAST frames while dest AXI is completely stalled, then release for E3..E5!
    push_stream_packet(3, 32'hE100_0000, 0, 1'b1);
    push_stream_packet(3, 32'hE200_0000, 0, 1'b1);
    stall_dest_axi = 1'b0;
    push_stream_packet(3, 32'hE300_0000, 0, 1'b1);
    push_stream_packet(3, 32'hE400_0000, 0, 1'b1);
    push_stream_packet(3, 32'hE500_0000, 0, 1'b1);

    begin
      int guard;
      guard = 0;
      while (got_desc_id_q.size() < 5) begin
        @(posedge req_clk);
        guard = guard + 1;
        if (guard > 6000) begin
          $display("FAIL_SG_DMAC: Hang/deadlock during back-to-back early_tlast + bl_valid backpressure (got %0d/5)", got_desc_id_q.size());
          $fatal(1);
        end
      end
    end
    req_half_ps = 1700;
    repeat (20) @(posedge src_clk);
    if (s_axis_xfer_req !== 1'b0) begin
      $display("FAIL_SG_DMAC: s_axis_xfer_req stuck high after early_tlast completion!");
      $fatal(1);
    end
    for (int d = 0; d < 5; d++) begin
      logic [31:0] gid;
      logic gpart;
      gid   = got_desc_id_q.pop_front();
      gpart = got_partial_q.pop_front();
      void'(got_eot_irq_q.pop_front());
      if (gid !== (32'h2000_0000 + d) || gpart !== 1'b1) begin
        $display("FAIL_SG_DMAC: Early-TLAST desc %0d completion mismatch: id=0x%08x partial=%b", d, gid, gpart);
        $fatal(1);
      end
      for (int w = 0; w < 3; w++) begin
        logic [31:0] gw;
        logic [31:0] ew;
        gw = {dst_mem[32'h800 + d*128 + w*4 + 3], dst_mem[32'h800 + d*128 + w*4 + 2],
              dst_mem[32'h800 + d*128 + w*4 + 1], dst_mem[32'h800 + d*128 + w*4 + 0]};
        ew = (32'hE100_0000 + (d * 32'h0100_0000)) + w;
        if (gw !== ew) begin
          $display("FAIL_SG_DMAC: Early-TLAST desc %0d word %0d mismatch: got 0x%08x expected 0x%08x", d, w, gw, ew);
          $fatal(1);
        end
      end
    end

    // =========================================================================
    // TEST 4: Mid-Burst Synchronous Warm Reset Pulse on Data-Plane Domains ->
    //         Verify Zero Phantom Bursts After Reset & Clean Subsequent Chain!
    // =========================================================================
    write_desc(152, 32'h3000_0001, 1'b1, 1'b1, 32'h0C00, 16'd63, 160);
    stall_dest_axi = 1'b1;
    issue_chain(152, 1'b0);
    // Push 1 burst (8 x 32-bit words = 32 bytes) into burst memory while dest is stalled
    push_stream_packet(8, 32'hDEAD_0000, 0, 1'b0);
    repeat (6) @(posedge dst_clk);

    // Assert synchronous warm reset across all domains!
    @(negedge req_clk);
    req_resetn = 1'b0;
    sg_resetn  = 1'b0;
    src_resetn = 1'b0;
    dst_resetn = 1'b0;
    repeat (2) @(negedge req_clk);
    repeat (2) @(negedge dst_clk);
    req_resetn = 1'b1;
    sg_resetn  = 1'b1;
    src_resetn = 1'b1;
    dst_resetn = 1'b1;
    stall_dest_axi = 1'b0;

    begin
      int aw_after_rst;
      repeat (2) @(posedge dst_clk);
      aw_after_rst = total_aw_bursts;
      repeat (30) @(posedge dst_clk);
      if (total_aw_bursts != aw_after_rst) begin
        $display("FAIL_SG_DMAC: Phantom AXI AW burst issued after warm reset due to stale burst-memory Gray IDs!");
        $fatal(1);
      end
    end

    // Run one final clean post-reset transfer to confirm full recovery & exact data
    write_desc(168, 32'h4000_0099, 1'b1, 1'b1, 32'h0D00, 16'd15, 176);
    issue_chain(168, 1'b0);
    push_stream_packet(4, 32'h9999_0000, 0, 1'b0);
    begin
      int guard;
      guard = 0;
      while (got_desc_id_q.size() < 1) begin
        @(posedge req_clk);
        guard = guard + 1;
        if (guard > 3000) begin
          $display("FAIL_SG_DMAC: Post-warm-reset transfer hung!");
          $fatal(1);
        end
      end
      if (got_desc_id_q.pop_front() !== 32'h4000_0099) begin
        $display("FAIL_SG_DMAC: Post-warm-reset descriptor ID mismatch!");
        $fatal(1);
      end
      for (int w = 0; w < 4; w++) begin
        logic [31:0] pw;
        pw = {dst_mem[32'hD00 + w*4 + 3], dst_mem[32'hD00 + w*4 + 2],
              dst_mem[32'hD00 + w*4 + 1], dst_mem[32'hD00 + w*4 + 0]};
        if (pw !== (32'h9999_0000 + w)) begin
          $display("FAIL_SG_DMAC: Post-warm-reset payload mismatch at word %0d: got 0x%08x", w, pw);
          $fatal(1);
        end
      end
    end

    $display("PASS_SG_DMAC seed=%0d", seed);
    $finish;
  end
endmodule
