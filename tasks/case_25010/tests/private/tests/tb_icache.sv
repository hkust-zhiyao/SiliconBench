`timescale 1ns/1ps

module tb_icache;
  localparam int unsigned MEM_WORDS = 16384; // 64 KiB (32-bit words)

  logic        clk;
  logic        rst_n;
  logic        enable_prefetching;
  logic [1:0]  flush_valid;
  logic [1:0]  flush_ready;
  logic [31:0] inst_addr_0, inst_addr_1;
  logic [31:0] inst_data_0, inst_data_1;
  logic [1:0]  inst_cacheable;
  logic [1:0]  inst_valid;
  logic [1:0]  inst_ready;
  logic [1:0]  inst_error;

  logic [31:0] axi_ar_addr;
  logic [7:0]  axi_ar_len;
  logic [2:0]  axi_ar_size;
  logic [1:0]  axi_ar_burst;
  logic [3:0]  axi_ar_cache;
  logic        axi_ar_valid;
  logic        axi_ar_ready;

  logic [63:0] axi_r_data;
  logic [1:0]  axi_r_resp;
  logic        axi_r_last;
  logic        axi_r_valid;
  logic        axi_r_ready;

  snitch_icache_subsys dut (
    .clk_i                ( clk                ),
    .rst_ni               ( rst_n              ),
    .enable_prefetching_i ( enable_prefetching ),
    .flush_valid_i        ( flush_valid        ),
    .flush_ready_o        ( flush_ready        ),
    .inst_addr_0_i        ( inst_addr_0        ),
    .inst_addr_1_i        ( inst_addr_1        ),
    .inst_data_0_o        ( inst_data_0        ),
    .inst_data_1_o        ( inst_data_1        ),
    .inst_cacheable_i     ( inst_cacheable     ),
    .inst_valid_i         ( inst_valid         ),
    .inst_ready_o         ( inst_ready         ),
    .inst_error_o         ( inst_error         ),
    .axi_ar_addr_o        ( axi_ar_addr        ),
    .axi_ar_len_o         ( axi_ar_len         ),
    .axi_ar_size_o        ( axi_ar_size        ),
    .axi_ar_burst_o       ( axi_ar_burst       ),
    .axi_ar_cache_o       ( axi_ar_cache       ),
    .axi_ar_valid_o       ( axi_ar_valid       ),
    .axi_ar_ready_i       ( axi_ar_ready       ),
    .axi_r_data_i         ( axi_r_data         ),
    .axi_r_resp_i         ( axi_r_resp         ),
    .axi_r_last_i         ( axi_r_last         ),
    .axi_r_valid_i        ( axi_r_valid        ),
    .axi_r_ready_o        ( axi_r_ready        )
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  logic [31:0] mem [0:MEM_WORDS-1];
  logic [1:0]  err_mode [0:(MEM_WORDS/4)-1]; // per 16B line: 0=OK, 1=beat0 SLVERR, 2=beat1 SLVERR, 3=both DECERR

  int unsigned rng_state;
  `ifdef TB_SEED
  localparam int unsigned INIT_SEED = `TB_SEED;
  `else
  localparam int unsigned INIT_SEED = 32'h2501_0101;
  `endif

  function automatic int unsigned next_rand();
    rng_state ^= (rng_state << 13);
    rng_state ^= (rng_state >> 17);
    rng_state ^= (rng_state << 5);
    return rng_state;
  endfunction

  // AXI slave FIFO + configurable beat delay
  typedef struct packed {
    logic [31:0] addr;
    logic [127:0] snap_line;
    logic [1:0]  emode;
  } ar_pkt_t;

  ar_pkt_t ar_q [0:15];
  int ar_wr, ar_rd, ar_cnt;
  int r_delay_cfg;
  int r_wait_cnt;
  int r_beat_idx;
  int ar_total_cnt;
  int fail_cnt;

  function automatic logic [127:0] read_line_128(input logic [31:0] aligned_addr);
    int unsigned base_w;
    base_w = (aligned_addr[15:4]) * 4;
    return {mem[base_w + 3], mem[base_w + 2], mem[base_w + 1], mem[base_w + 0]};
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_wr        <= 0;
      ar_rd        <= 0;
      ar_cnt       <= 0;
      r_wait_cnt   <= 0;
      r_beat_idx   <= 0;
      ar_total_cnt <= 0;
      axi_ar_ready <= 1'b0;
      axi_r_valid  <= 1'b0;
      axi_r_data   <= '0;
      axi_r_resp   <= 2'b00;
      axi_r_last   <= 1'b0;
    end else begin
      axi_ar_ready <= (ar_cnt < 12) && ((next_rand() % 4) != 0);

      if (axi_ar_valid && axi_ar_ready) begin
        ar_total_cnt <= ar_total_cnt + 1;
        if (axi_ar_addr[3:0] !== 4'b0000 || axi_ar_len !== 8'd1 || axi_ar_size !== 3'd3 || axi_ar_burst !== 2'b01) begin
          $display("TB_ERR: Unaligned or malformed AXI AR: addr=0x%08x len=%0d size=%0d burst=%0d",
                   axi_ar_addr, axi_ar_len, axi_ar_size, axi_ar_burst);
          fail_cnt <= fail_cnt + 1;
        end
        // Snapshot line data at AR acceptance so in-flight stale refills carry pre-flush data!
        ar_q[ar_wr].addr      <= {axi_ar_addr[31:4], 4'b0000};
        ar_q[ar_wr].snap_line <= read_line_128({axi_ar_addr[31:4], 4'b0000});
        ar_q[ar_wr].emode     <= err_mode[axi_ar_addr[15:4]];
        ar_wr <= (ar_wr + 1) % 16;
      end

      if (!axi_r_valid) begin
        if (ar_cnt > 0) begin
          if (r_wait_cnt < r_delay_cfg) begin
            r_wait_cnt <= r_wait_cnt + 1;
          end else begin
            axi_r_valid <= 1'b1;
            axi_r_data  <= (r_beat_idx == 0) ? ar_q[ar_rd].snap_line[63:0] : ar_q[ar_rd].snap_line[127:64];
            axi_r_last  <= (r_beat_idx == 1);
            case (ar_q[ar_rd].emode)
              2'd1: axi_r_resp <= (r_beat_idx == 0) ? 2'b10 : 2'b00; // Beat-0 SLVERR, Beat-1 OKAY
              2'd2: axi_r_resp <= (r_beat_idx == 1) ? 2'b10 : 2'b00; // Beat-0 OKAY, Beat-1 SLVERR
              2'd3: axi_r_resp <= 2'b11;                              // Both DECERR
              default: axi_r_resp <= 2'b00;
            endcase
          end
        end
      end else if (axi_r_ready) begin
        axi_r_valid <= 1'b0;
        r_wait_cnt  <= 0;
        if (r_beat_idx == 0) begin
          r_beat_idx <= 1;
        end else begin
          r_beat_idx <= 0;
          ar_rd      <= (ar_rd + 1) % 16;
        end
      end

      case ({axi_ar_valid && axi_ar_ready, axi_r_valid && axi_r_ready && (r_beat_idx == 1)})
        2'b10: ar_cnt <= ar_cnt + 1;
        2'b01: ar_cnt <= ar_cnt - 1;
        default: ;
      endcase
    end
  end

  task automatic fetch_port(
    input  int          port,
    input  logic [31:0] addr,
    input  logic        cacheable,
    output logic [31:0] rdata,
    output logic        rerr
  );
    int timeout_cyc;
    timeout_cyc = 0;
    if (port == 0) begin
      inst_addr_0       <= addr;
      inst_cacheable[0] <= cacheable;
      inst_valid[0]     <= 1'b1;
      @(posedge clk);
      while (!(inst_valid[0] && inst_ready[0])) begin
        timeout_cyc++;
        if (timeout_cyc > 1200) begin
          $display("TB_ERR: Timeout on port 0 addr=0x%08x", addr);
          fail_cnt++;
          break;
        end
        @(posedge clk);
      end
      rdata = inst_data_0;
      rerr  = inst_error[0];
      inst_valid[0] <= 1'b0;
    end else begin
      inst_addr_1       <= addr;
      inst_cacheable[1] <= cacheable;
      inst_valid[1]     <= 1'b1;
      @(posedge clk);
      while (!(inst_valid[1] && inst_ready[1])) begin
        timeout_cyc++;
        if (timeout_cyc > 1200) begin
          $display("TB_ERR: Timeout on port 1 addr=0x%08x", addr);
          fail_cnt++;
          break;
        end
        @(posedge clk);
      end
      rdata = inst_data_1;
      rerr  = inst_error[1];
      inst_valid[1] <= 1'b0;
    end
  endtask

  task automatic pulse_flush(input logic [1:0] mask);
    int tmo;
    tmo = 0;
    flush_valid <= mask;
    @(posedge clk);
    while ((flush_valid & ~flush_ready) != 2'b00) begin
      tmo++;
      if (tmo > 1000) begin
        $display("TB_ERR: Flush handshake timeout mask=%b", mask);
        fail_cnt++;
        break;
      end
      @(posedge clk);
    end
    flush_valid <= 2'b00;
  endtask

  task automatic check_fetch(
    input int          port,
    input logic [31:0] addr,
    input logic        cacheable,
    input logic [31:0] exp_data,
    input logic        exp_err,
    input string       tag
  );
    logic [31:0] got_d;
    logic        got_e;
    fetch_port(port, addr, cacheable, got_d, got_e);
    if (got_e !== exp_err || (!exp_err && got_d !== exp_data)) begin
      $display("TB_ERR [%s]: port=%0d addr=0x%08x got=(err=%b, data=0x%08x) exp=(err=%b, data=0x%08x)",
               tag, port, addr, got_e, got_d, exp_err, exp_data);
      fail_cnt++;
    end
  endtask

  initial begin
    logic [31:0] d0, d1;
    logic e0, e1;
    int ar_before;

    rng_state          = (INIT_SEED == 0) ? 32'h2501_0101 : INIT_SEED;
    fail_cnt           = 0;
    r_delay_cfg        = 1;
    rst_n              = 1'b0;
    enable_prefetching = 1'b0;
    flush_valid        = 2'b00;
    inst_addr_0        = 32'h0;
    inst_addr_1        = 32'h0;
    inst_cacheable     = 2'b11;
    inst_valid         = 2'b00;

    for (int i = 0; i < MEM_WORDS; i++) begin
      mem[i] = 32'h1000_0013 ^ (i * 32'h0101_0004) ^ INIT_SEED; // NOP-like distinct words
    end
    for (int l = 0; l < MEM_WORDS/4; l++) err_mode[l] = 2'd0;
    for (int l = 16'h0E00; l < 16'h0E40; l++) err_mode[l] = 2'd1; // 0xE000..0xE3FF: Beat-0 SLVERR
    for (int l = 16'h0E40; l < 16'h0E80; l++) err_mode[l] = 2'd2; // 0xE400..0xE7FF: Beat-1 SLVERR
    for (int l = 16'h0E80; l < 16'h0EC0; l++) err_mode[l] = 2'd3; // 0xE800..0xEBFF: Both DECERR

    repeat (6) @(posedge clk);
    rst_n <= 1'b1;
    repeat (270) @(posedge clk);

    // T1: Mid-line offsets (+0, +4, +8, +12), dual-port hits, L1 hits, and 2-way conflict evictions
    for (int way_iter = 0; way_iter < 4; way_iter++) begin
      logic [31:0] a;
      a = 32'h0000_0400 + (way_iter * 32'h0000_1000) + ((way_iter & 3) * 4);
      check_fetch(0, a, 1'b1, mem[a[15:2]], 1'b0, "T1_midline_p0");
      check_fetch(1, (a & 32'hFFFF_FFF0) + 32'd12, 1'b1, mem[((a & 32'hFFFF_FFF0) + 12) >> 2], 1'b0, "T1_midline_p1");
    end

    // T2a: Multi-beat error (Beat-0 SLVERR + Beat-1 OKAY) demand fetch + non-allocation proof
    check_fetch(0, 32'h0000_E008, 1'b1, 32'h0, 1'b1, "T2a_beat0_slverr");
    check_fetch(1, 32'h0000_E404, 1'b1, 32'h0, 1'b1, "T2a_beat1_slverr");
    err_mode[16'h0E00] = 2'd0; // Clear fault at 0xE000 WITHOUT flushing cache!
    ar_before = ar_total_cnt;
    check_fetch(0, 32'h0000_E008, 1'b1, mem[32'h0000_E008 >> 2], 1'b0, "T2a_no_errored_alloc");
    if (ar_total_cnt == ar_before) begin
      $display("TB_ERR [T2a_no_errored_alloc]: Errored line 0xE000 was cached without re-fetching!");
      fail_cnt++;
    end
    err_mode[16'h0E00] = 2'd1;

    // T2b: Speculative next-line prefetch into guard page 0xE000 must NOT raise inst_error_o even if core steps into 0xE000 after recovery
    enable_prefetching <= 1'b1;
    r_delay_cfg = 8;
    mem[32'h0000_DFF0 >> 2] = 32'h0000_0013; // ADDI x0, x0, 0 -> next-line prefetcher requests 0xE000!
    check_fetch(0, 32'h0000_DFF0, 1'b1, 32'h0000_0013, 1'b0, "T2b_pref_trigger_miss");
    check_fetch(0, 32'h0000_DFF4, 1'b1, mem[32'h0000_DFF4 >> 2], 1'b0, "T2b_pref_trigger_hit");
    begin
      int wp;
      wp = 0;
      while (!(axi_ar_valid && axi_ar_ready) && wp < 60) begin
        @(posedge clk);
        wp++;
      end
      @(posedge clk);
    end
    err_mode[16'h0E00] = 2'd0; // Guard page unmapped -> mapped while speculative prefetch is in flight
    check_fetch(0, 32'h0000_E000, 1'b1, mem[32'h0000_E000 >> 2], 1'b0, "T2b_demand_while_spec_err_inflight");
    r_delay_cfg = 1;

    // T3: Repeated in-flight AXI refill + fence.i flush races (tests stale suppression + zero MSHR leak)
    r_delay_cfg = 10;
    for (int round = 0; round < 6; round++) begin
      logic [31:0] base_a;
      base_a = 32'h0000_2000 + (round * 32'h0000_0040);
      // Warm another line first
      check_fetch(0, 32'h0000_1004, 1'b1, mem[32'h0000_1004 >> 2], 1'b0, "T3_warm");

      // Launch miss on Port 0 (and coalesce Port 1 on even rounds)
      inst_addr_0       <= base_a + 32'd4;
      inst_cacheable[0] <= 1'b1;
      inst_valid[0]     <= 1'b1;
      if ((round % 2) == 0) begin
        inst_addr_1       <= base_a + 32'd8;
        inst_cacheable[1] <= 1'b1;
        inst_valid[1]     <= 1'b1;
      end

      // Wait until AR is accepted on AXI (refill is now in-flight with OLD snapshot!)
      begin
        int w;
        w = 0;
        while (!(axi_ar_valid && axi_ar_ready) && w < 300) begin
          @(posedge clk);
          w++;
        end
        @(posedge clk);
      end

      // Self-modifying code updates backing memory while refill is in flight!
      for (int k = 0; k < 4; k++) begin
        mem[(base_a >> 2) + k]       = 32'hCAFE_0000 | (round << 8) | k;
        mem[(32'h0000_1000 >> 2) + k] = 32'hBEEF_0000 | (round << 8) | k;
      end

      if ((round % 2) == 1) begin
        // Single-port flush on Port 0 while Port 0 miss is in flight
        inst_valid[0] <= 1'b0;
        pulse_flush(2'b01);
      end else begin
        // Coalesced miss: Port 0 flushes, Port 1 either also flushes (round 0,4) or stays active (round 2)!
        if (round == 2) begin
          inst_valid[0] <= 1'b0;
          pulse_flush(2'b01);
          // Port 1 did NOT flush; it must still complete without deadlock!
          begin
            int w1;
            w1 = 0;
            while (!(inst_valid[1] && inst_ready[1]) && w1 < 1200) begin
              @(posedge clk);
              w1++;
            end
            if (w1 >= 1200) begin
              $display("TB_ERR [T3_coalesced_p1_live]: Port 1 deadlocked when Port 0 flushed!");
              fail_cnt++;
            end
            inst_valid[1] <= 1'b0;
          end
        end else begin
          inst_valid <= 2'b00;
          pulse_flush(2'b11);
        end
      end

      // Post-flush fetches on flushed port(s) MUST observe updated memory (never stale in-flight refill or pre-flush L1!)
      check_fetch(0, base_a + 32'd4, 1'b1, mem[(base_a + 4) >> 2], 1'b0, "T3_post_flush_inflight_line");
      check_fetch(((round % 2) == 0 && round != 2) ? 1 : 0, 32'h0000_1008, 1'b1, mem[32'h0000_1008 >> 2], 1'b0, "T3_post_flush_warm_line");
    end

    // T3b: Long-latency in-flight refill (>256 cycles) across flush: tests stale MSHR quarantine & ID non-aliasing
    enable_prefetching <= 1'b0;
    r_delay_cfg = 150;
    inst_addr_0       <= 32'h0000_2804;
    inst_cacheable[0] <= 1'b1;
    inst_valid[0]     <= 1'b1;
    begin
      int wl1;
      wl1 = 0;
      while (!(axi_ar_valid && axi_ar_ready) && wl1 < 400) begin @(posedge clk); wl1++; end
      @(posedge clk);
    end
    for (int k = 0; k < 4; k++) mem[(32'h0000_2800 >> 2) + k] = 32'hDEAD_2800 | k;
    inst_valid[0] <= 1'b0;
    pulse_flush(2'b11);
    check_fetch(0, 32'h0000_2804, 1'b1, mem[32'h0000_2804 >> 2], 1'b0, "T3b_no_stale_coalesce");

    inst_addr_0       <= 32'h0000_2904;
    inst_cacheable[0] <= 1'b1;
    inst_valid[0]     <= 1'b1;
    begin
      int wl2;
      wl2 = 0;
      while (!(axi_ar_valid && axi_ar_ready) && wl2 < 400) begin @(posedge clk); wl2++; end
      @(posedge clk);
    end
    inst_valid[0] <= 1'b0;
    pulse_flush(2'b11);
    check_fetch(0, 32'h0000_2A04, 1'b1, mem[32'h0000_2A04 >> 2], 1'b0, "T3b_no_mshr_id_alias");
    repeat (340) @(posedge clk);

    // T4: Non-cacheable bypass fetches + mid-line offset + error response
    r_delay_cfg = 2;
    check_fetch(0, 32'h0000_310C, 1'b0, mem[32'h0000_310C >> 2], 1'b0, "T4_bypass_ok");
    check_fetch(1, 32'h0000_E804, 1'b0, 32'h0,                   1'b1, "T4_bypass_err");

    if (fail_cnt == 0) begin
      $display("TEST_PASS: All Snitch ICache multi-port, coherence, and AXI error checks passed.");
      $finish;
    end else begin
      $display("TEST_FAIL: %0d errors detected.", fail_cnt);
      $fatal(1, "Simulation failed");
    end
  end

endmodule
