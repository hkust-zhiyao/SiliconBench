`timescale 1ps/1ps

module tb;
  int unsigned seed = 101;

  // =========================================================================
  // Instance 1: Primary DUT (SYNC_STAGES=2, CLEAR_ON_ASYNC_RESET=1)
  // =========================================================================
  logic a_clk = 1'b0, b_clk = 1'b0;
  logic a_clk_en = 1'b1, b_clk_en = 1'b1;
  int   t_a_half = 1700; // 3.4 ns period
  int   t_b_half = 6300; // 12.6 ns period

  always #(t_a_half) if (a_clk_en) a_clk = ~a_clk;
  always #(t_b_half) if (b_clk_en) b_clk = ~b_clk;

  logic a_rst_n = 1'b0, b_rst_n = 1'b0;
  logic a_clear_i = 1'b0, b_clear_i = 1'b0;
  logic a_clear_o, b_clear_o;
  logic a_isolate_o, b_isolate_o;
  logic a_isolate_ack_i = 1'b0, b_isolate_ack_i = 1'b0;
  logic a_clear_ack_i = 1'b0, b_clear_ack_i = 1'b0;

  cdc_reset_ctrlr #(
    .SYNC_STAGES(2),
    .CLEAR_ON_ASYNC_RESET(1'b1)
  ) dut (
    .a_clk_i         ( a_clk           ),
    .a_rst_ni        ( a_rst_n         ),
    .a_clear_i       ( a_clear_i       ),
    .a_clear_o       ( a_clear_o       ),
    .a_clear_ack_i   ( a_clear_ack_i   ),
    .a_isolate_o     ( a_isolate_o     ),
    .a_isolate_ack_i ( a_isolate_ack_i ),
    .b_clk_i         ( b_clk           ),
    .b_rst_ni        ( b_rst_n         ),
    .b_clear_i       ( b_clear_i       ),
    .b_clear_o       ( b_clear_o       ),
    .b_clear_ack_i   ( b_clear_ack_i   ),
    .b_isolate_o     ( b_isolate_o     ),
    .b_isolate_ack_i ( b_isolate_ack_i )
  );

  // Configurable responder modes per side:
  // mode 0: level ack after N cycles; mode 1: 1-cycle pulse ack after N cycles
  int a_ack_mode = 0, b_ack_mode = 0;
  int a_iso_delay = 2, b_iso_delay = 2;
  int a_clr_delay = 1, b_clr_delay = 1;

  int a_iso_cnt = 0, a_clr_cnt = 0;
  bit a_iso_pulsed = 0, a_clr_pulsed = 0;
  bit a_iso_acked_win = 0, b_iso_acked_win = 0;
  bit a_clear_prev = 0, b_clear_prev = 0;
  int a_clear_pulses = 0, b_clear_pulses = 0;

  always @(posedge a_clk or negedge a_rst_n) begin
    if (!a_rst_n) begin
      a_iso_cnt       <= 0;
      a_clr_cnt       <= 0;
      a_iso_pulsed    <= 0;
      a_clr_pulsed    <= 0;
      a_isolate_ack_i <= 1'b0;
      a_clear_ack_i   <= 1'b0;
      a_iso_acked_win <= 1'b0;
      a_clear_prev    <= 1'b0;
    end else begin
      // Protocol safety monitor on Side A
      if (a_clear_o && !a_isolate_o) begin
        $display("FAIL: Side A asserted a_clear_o while a_isolate_o==0 at %0t", $time);
        $fatal(1);
      end
      if (a_clear_o && !a_iso_acked_win) begin
        $display("FAIL: Side A asserted a_clear_o before a_isolate_ack_i observed in window at %0t", $time);
        $fatal(1);
      end
      if (a_clear_prev && !a_clear_o && !a_isolate_o) begin
        $display("FAIL: Side A dropped a_isolate_o simultaneously with a_clear_o without post-clear teardown at %0t", $time);
        $fatal(1);
      end
      if (!a_clear_prev && a_clear_o) begin
        a_clear_pulses <= a_clear_pulses + 1;
        if (b_rst_n && (!b_isolate_o || !(b_iso_acked_win || b_isolate_ack_i))) begin
          $display("FAIL: Side A rose a_clear_o while peer Side B was not isolated+acked (b_iso=%0b b_acked=%0b) at %0t",
                   b_isolate_o, b_iso_acked_win, $time);
          $fatal(1);
        end
      end
      a_clear_prev <= a_clear_o;

      if (!a_isolate_o) begin
        a_iso_acked_win <= 1'b0;
      end else if (a_isolate_ack_i) begin
        a_iso_acked_win <= 1'b1;
      end

      // Responder for a_isolate_ack_i
      if (!a_isolate_o) begin
        a_iso_cnt       <= 0;
        a_iso_pulsed    <= 0;
        a_isolate_ack_i <= 1'b0;
      end else if (a_iso_cnt < a_iso_delay) begin
        a_iso_cnt       <= a_iso_cnt + 1;
        a_isolate_ack_i <= 1'b0;
      end else if (a_ack_mode == 0) begin
        a_isolate_ack_i <= 1'b1;
      end else if (!a_iso_pulsed) begin
        a_isolate_ack_i <= 1'b1;
        a_iso_pulsed    <= 1'b1;
      end else begin
        a_isolate_ack_i <= 1'b0;
      end

      // Responder for a_clear_ack_i
      if (!a_clear_o) begin
        a_clr_cnt     <= 0;
        a_clr_pulsed  <= 0;
        a_clear_ack_i <= 1'b0;
      end else if (a_clr_cnt < a_clr_delay) begin
        a_clr_cnt     <= a_clr_cnt + 1;
        a_clear_ack_i <= 1'b0;
      end else if (a_ack_mode == 0) begin
        a_clear_ack_i <= 1'b1;
      end else if (!a_clr_pulsed) begin
        a_clear_ack_i <= 1'b1;
        a_clr_pulsed  <= 1'b1;
      end else begin
        a_clear_ack_i <= 1'b0;
      end
    end
  end

  int b_iso_cnt = 0, b_clr_cnt = 0;
  bit b_iso_pulsed = 0, b_clr_pulsed = 0;

  always @(posedge b_clk or negedge b_rst_n) begin
    if (!b_rst_n) begin
      b_iso_cnt       <= 0;
      b_clr_cnt       <= 0;
      b_iso_pulsed    <= 0;
      b_clr_pulsed    <= 0;
      b_isolate_ack_i <= 1'b0;
      b_clear_ack_i   <= 1'b0;
      b_iso_acked_win <= 1'b0;
      b_clear_prev    <= 1'b0;
    end else begin
      if (b_clear_o && !b_isolate_o) begin
        $display("FAIL: Side B asserted b_clear_o while b_isolate_o==0 at %0t", $time);
        $fatal(1);
      end
      if (b_clear_o && !b_iso_acked_win) begin
        $display("FAIL: Side B asserted b_clear_o before b_isolate_ack_i observed in window at %0t", $time);
        $fatal(1);
      end
      if (b_clear_prev && !b_clear_o && !b_isolate_o) begin
        $display("FAIL: Side B dropped b_isolate_o simultaneously with b_clear_o without post-clear teardown at %0t", $time);
        $fatal(1);
      end
      if (!b_clear_prev && b_clear_o) begin
        b_clear_pulses <= b_clear_pulses + 1;
        if (a_rst_n && (!a_isolate_o || !(a_iso_acked_win || a_isolate_ack_i))) begin
          $display("FAIL: Side B rose b_clear_o while peer Side A was not isolated+acked (a_iso=%0b a_acked=%0b) at %0t",
                   a_isolate_o, a_iso_acked_win, $time);
          $fatal(1);
        end
      end
      b_clear_prev <= b_clear_o;

      if (!b_isolate_o) begin
        b_iso_acked_win <= 1'b0;
      end else if (b_isolate_ack_i) begin
        b_iso_acked_win <= 1'b1;
      end

      if (!b_isolate_o) begin
        b_iso_cnt       <= 0;
        b_iso_pulsed    <= 0;
        b_isolate_ack_i <= 1'b0;
      end else if (b_iso_cnt < b_iso_delay) begin
        b_iso_cnt       <= b_iso_cnt + 1;
        b_isolate_ack_i <= 1'b0;
      end else if (b_ack_mode == 0) begin
        b_isolate_ack_i <= 1'b1;
      end else if (!b_iso_pulsed) begin
        b_isolate_ack_i <= 1'b1;
        b_iso_pulsed    <= 1'b1;
      end else begin
        b_isolate_ack_i <= 1'b0;
      end

      if (!b_clear_o) begin
        b_clr_cnt     <= 0;
        b_clr_pulsed  <= 0;
        b_clear_ack_i <= 1'b0;
      end else if (b_clr_cnt < b_clr_delay) begin
        b_clr_cnt     <= b_clr_cnt + 1;
        b_clear_ack_i <= 1'b0;
      end else if (b_ack_mode == 0) begin
        b_clear_ack_i <= 1'b1;
      end else if (!b_clr_pulsed) begin
        b_clear_ack_i <= 1'b1;
        b_clr_pulsed  <= 1'b1;
      end else begin
        b_clear_ack_i <= 1'b0;
      end
    end
  end

  // =========================================================================
  // Instance 2: SYNC_STAGES=4, CLEAR_ON_ASYNC_RESET=0 (tests SYNC_STAGES &
  // CLEAR_ON_ASYNC_RESET=0 asymmetric reset recovery)
  // =========================================================================
  logic s4_aclk = 1'b0, s4_bclk = 1'b0;
  int   t_s4_a = 2500, t_s4_b = 3100;
  always #(t_s4_a) s4_aclk = ~s4_aclk;
  always #(t_s4_b) s4_bclk = ~s4_bclk;

  logic s4_arst_n = 1'b0, s4_brst_n = 1'b0;
  logic s4_aclr_i = 1'b0, s4_bclr_i = 1'b0;
  logic s4_aclr_o, s4_bclr_o, s4_aiso_o, s4_biso_o;
  logic s4_aiso_ack = 1'b0, s4_biso_ack = 1'b0;
  logic s4_aclr_ack = 1'b0, s4_bclr_ack = 1'b0;
  bit   s4_biso_acked_win = 0;
  int   s4_b_cnt = 0;

  cdc_reset_ctrlr #(
    .SYNC_STAGES(4),
    .CLEAR_ON_ASYNC_RESET(1'b0)
  ) dut_s4 (
    .a_clk_i         ( s4_aclk     ),
    .a_rst_ni        ( s4_arst_n   ),
    .a_clear_i       ( s4_aclr_i   ),
    .a_clear_o       ( s4_aclr_o   ),
    .a_clear_ack_i   ( s4_aclr_ack ),
    .a_isolate_o     ( s4_aiso_o   ),
    .a_isolate_ack_i ( s4_aiso_ack ),
    .b_clk_i         ( s4_bclk     ),
    .b_rst_ni        ( s4_brst_n   ),
    .b_clear_i       ( s4_bclr_i   ),
    .b_clear_o       ( s4_bclr_o   ),
    .b_clear_ack_i   ( s4_bclr_ack ),
    .b_isolate_o     ( s4_biso_o   ),
    .b_isolate_ack_i ( s4_biso_ack )
  );

  always @(posedge s4_aclk or negedge s4_arst_n) begin
    if (!s4_arst_n) begin
      s4_aiso_ack <= 1'b0;
      s4_aclr_ack <= 1'b0;
    end else begin
      s4_aiso_ack <= s4_aiso_o;
      s4_aclr_ack <= s4_aclr_o;
    end
  end

  always @(posedge s4_bclk or negedge s4_brst_n) begin
    if (!s4_brst_n) begin
      s4_b_cnt          <= 0;
      s4_biso_ack       <= 1'b0;
      s4_bclr_ack       <= 1'b0;
      s4_biso_acked_win <= 1'b0;
    end else begin
      if (s4_bclr_o && (!s4_biso_o || !s4_biso_acked_win)) begin
        $display("FAIL: dut_s4 Side B asserted b_clear_o before b_isolate_ack_i observed after reset recovery at %0t", $time);
        $fatal(1);
      end
      if (!s4_biso_o) begin
        s4_biso_acked_win <= 1'b0;
        s4_b_cnt          <= 0;
        s4_biso_ack       <= 1'b0;
      end else begin
        if (s4_biso_ack) s4_biso_acked_win <= 1'b1;
        if (s4_b_cnt < 3) begin
          s4_b_cnt    <= s4_b_cnt + 1;
          s4_biso_ack <= 1'b0;
        end else begin
          s4_biso_ack <= 1'b1;
        end
      end
      s4_bclr_ack <= s4_bclr_o;
    end
  end

  task automatic wait_both_idle(input int max_ns);
    int waited = 0;
    while ((a_isolate_o !== 1'b0 || b_isolate_o !== 1'b0 ||
            a_clear_o !== 1'b0   || b_clear_o !== 1'b0) && waited < max_ns) begin
      #1000;
      waited += 1;
    end
    if (a_isolate_o !== 1'b0 || b_isolate_o !== 1'b0 || a_clear_o !== 1'b0 || b_clear_o !== 1'b0) begin
      $display("FAIL: Timeout waiting for dut idle (a_iso=%0b b_iso=%0b a_clr=%0b b_clr=%0b) at %0t",
               a_isolate_o, b_isolate_o, a_clear_o, b_clear_o, $time);
      $fatal(1);
    end
  endtask

  task automatic wait_s4_idle(input int max_ns);
    int waited = 0;
    while ((s4_aiso_o !== 1'b0 || s4_biso_o !== 1'b0 ||
            s4_aclr_o !== 1'b0 || s4_bclr_o !== 1'b0) && waited < max_ns) begin
      #1000;
      waited += 1;
    end
    if (s4_aiso_o !== 1'b0 || s4_biso_o !== 1'b0 || s4_aclr_o !== 1'b0 || s4_bclr_o !== 1'b0) begin
      $display("FAIL: Timeout waiting for dut_s4 idle at %0t", $time);
      $fatal(1);
    end
  endtask

  // Global watchdog
  initial begin
    #40_000_000;
    $display("FAIL: Global watchdog timeout at %0t", $time);
    $fatal(1);
  end

  initial begin
    int prev_a, prev_b, b_edges, a_edges, t_wait;
    void'($value$plusargs("seed=%d", seed));

    // -----------------------------------------------------------------------
    // Test 1: Power-on reset, then stopped Side A clock async reset -> peer B isolation
    // -----------------------------------------------------------------------
    a_clk_en = 1'b1;
    b_clk_en = 1'b1;
    a_rst_n  = 1'b0;
    b_rst_n  = 1'b0;
    #25_000;
    a_rst_n  = 1'b1;
    b_rst_n  = 1'b1;
    wait_both_idle(4000);
    if (a_clear_pulses < 1 || b_clear_pulses < 1) begin
      $display("FAIL: Expected clear pulse on both sides after CLEAR_ON_ASYNC_RESET power-up");
      $fatal(1);
    end

    // Now B is completely IDLE (b_isolate_o == 0); stop Side A clock and assert !a_rst_n!
    a_clk_en = 1'b0;
    #5_000;
    a_rst_n  = 1'b0;
    t_wait   = 0;
    while (b_isolate_o !== 1'b1 && t_wait < 200) begin
      @(posedge b_clk);
      t_wait++;
    end
    if (b_isolate_o !== 1'b1) begin
      $display("FAIL: Side B failed to isolate during stopped-clock Side A async reset");
      $fatal(1);
    end
    a_clk_en = 1'b1;
    repeat (3) @(posedge a_clk);
    a_rst_n = 1'b1;
    wait_both_idle(5000);

    // Sweep a_iso_delay across 2..12 with fast Side B so initiator_phase_transition_ack
    // arrives both BEFORE and SIMULTANEOUSLY WITH a_isolate_ack_i!
    t_a_half = 4000;
    t_b_half = 900;
    a_ack_mode = 0;
    b_ack_mode = 0;
    b_iso_delay = 1;
    for (int dly = 2; dly <= 12; dly++) begin
      a_iso_delay = dly;
      @(posedge a_clk); a_clear_i <= 1'b1; @(posedge a_clk); a_clear_i <= 1'b0;
      wait_both_idle(5000);
    end
    t_a_half = 1700;
    t_b_half = 6300;

    // -----------------------------------------------------------------------
    // Test 2: Simultaneous bidirectional clear with 1-cycle pulsed ACKs
    //         across both slow-B (3.4ns : 12.6ns) and fast-B (15.4ns : 2.6ns)
    // -----------------------------------------------------------------------
    a_ack_mode = 1;
    b_ack_mode = 1;
    a_iso_delay = 1;
    b_iso_delay = 2;
    a_clr_delay = 1;
    b_clr_delay = 1;

    prev_a = a_clear_pulses;
    prev_b = b_clear_pulses;
    fork
      begin @(posedge a_clk); a_clear_i <= 1'b1; @(posedge a_clk); a_clear_i <= 1'b0; end
      begin @(posedge b_clk); b_clear_i <= 1'b1; @(posedge b_clk); b_clear_i <= 1'b0; end
    join
    wait_both_idle(5000);
    if (a_clear_pulses <= prev_a || b_clear_pulses <= prev_b) begin
      $display("FAIL: Missing clear pulse during simultaneous pulsed-ACK clear");
      $fatal(1);
    end

    // Flip clock ratio: slow A (15.4 ns), fast B (2.6 ns)
    t_a_half = 7700;
    t_b_half = 1300;
    #20_000;

    // -----------------------------------------------------------------------
    // Test 3: One-sided async reset mid-handshake (especially right as Side B
    //         drops b_isolate_o during FINISHED teardown while stale ACK=1!)
    // -----------------------------------------------------------------------
    a_ack_mode = 0;
    b_ack_mode = 0;
    a_iso_delay = 1;
    b_iso_delay = 3;
    for (int sweep = 0; sweep < 8; sweep++) begin
      prev_a = a_clear_pulses;
      prev_b = b_clear_pulses;
      @(posedge a_clk);
      a_clear_i <= 1'b1;
      @(posedge a_clk);
      a_clear_i <= 1'b0;

      if (sweep == 0) begin
        // Wait until a_clear_o finishes and Side B clocks CLEAR_PHASE_IDLE into WAIT_REQ_DEASSERT
        wait (a_clear_o == 1'b1);
        wait (a_clear_o == 1'b0);
        wait (b_isolate_o == 1'b0);
        @(posedge b_clk);
        @(posedge b_clk);
        #300;
      end else begin
        // Sweep across different phases of the handshake
        repeat (sweep * 3) @(posedge b_clk);
        #400;
      end

      // Yank Side A async reset mid-flight!
      a_rst_n = 1'b0;
      repeat (2 + (sweep % 3)) @(posedge b_clk);
      a_rst_n = 1'b1;
      wait_both_idle(6000);
    end

    // -----------------------------------------------------------------------
    // Test 4: Synchronous clear_i pulse arriving during POST_CLEAR / FINISHED
    //         teardown must NOT be dropped!
    // -----------------------------------------------------------------------
    t_a_half = 2500;
    t_b_half = 5500;
    #10_000;
    prev_a = a_clear_pulses;
    prev_b = b_clear_pulses;
    @(posedge a_clk);
    a_clear_i <= 1'b1;
    @(posedge a_clk);
    a_clear_i <= 1'b0;
    // Wait until CLEAR phase completes (a_clear_o falls while a_isolate_o is still 1 = POST_CLEAR/FINISHED)
    wait (a_clear_o == 1'b1);
    wait (a_clear_o == 1'b0 && a_isolate_o == 1'b1);
    @(posedge a_clk);
    if (a_isolate_o !== 1'b1) begin
      $display("FAIL: Expected a_isolate_o high during post-clear teardown");
      $fatal(1);
    end
    // Issue a brand new synchronous clear_i pulse AFTER the first clear ended!
    prev_a = a_clear_pulses;
    prev_b = b_clear_pulses;
    a_clear_i <= 1'b1;
    @(posedge a_clk);
    a_clear_i <= 1'b0;
    // Wait for first teardown to hit IDLE and immediately launch the queued follow-up clear
    begin
      int w_clr = 0;
      while ((a_clear_pulses < prev_a + 1 || b_clear_pulses < prev_b + 1) && w_clr < 4000) begin
        #1000;
        w_clr += 1;
      end
    end
    if (a_clear_pulses < prev_a + 1 || b_clear_pulses < prev_b + 1) begin
      $display("FAIL: Synchronous a_clear_i during POST_CLEAR/FINISHED teardown was silently dropped!");
      $fatal(1);
    end
    wait_both_idle(6000);

    // -----------------------------------------------------------------------
    // Test 5: dut_s4 (SYNC_STAGES=4, CLEAR_ON_ASYNC_RESET=0):
    //   (a) Verify >= 4 destination clock edges latency on BOTH A->B and B->A
    //   (b) Verify Receiver recovering from !b_rst_n while A holds CLEAR
    //       still isolates and waits for b_isolate_ack_i BEFORE b_clear_o!
    // -----------------------------------------------------------------------
    s4_arst_n = 1'b0;
    s4_brst_n = 1'b0;
    repeat (4) @(posedge s4_aclk);
    s4_arst_n = 1'b1;
    s4_brst_n = 1'b1;
    repeat (4) @(posedge s4_bclk);
    if (s4_aiso_o !== 1'b0 || s4_biso_o !== 1'b0) begin
      $display("FAIL: CLEAR_ON_ASYNC_RESET=0 initiated clear on async reset");
      $fatal(1);
    end

    // Check A -> B propagation requires >= 4 b_clk rising edges after a_clk samples clear_i
    @(negedge s4_aclk);
    s4_aclr_i = 1'b1;
    @(posedge s4_aclk);
    b_edges = 0;
    fork
      begin
        @(negedge s4_aclk);
        s4_aclr_i = 1'b0;
      end
      begin
        while (s4_biso_o !== 1'b1 && b_edges < 25) begin
          @(posedge s4_bclk);
          #1;
          if (s4_biso_o !== 1'b1) b_edges++;
        end
      end
    join
    // Including the edge where s4_biso_o became 1, total b_clk edges >= 4 (so b_edges >= 3)
    if (b_edges < 3) begin
      $display("FAIL: A->B CDC did not honor SYNC_STAGES=4 (b_isolate_o rose after only %0d b_clk edges)", b_edges + 1);
      $fatal(1);
    end
    wait_s4_idle(5000);

    // Check B -> A propagation requires >= 4 a_clk rising edges after b_clk samples clear_i
    @(negedge s4_bclk);
    s4_bclr_i = 1'b1;
    @(posedge s4_bclk);
    a_edges = 0;
    fork
      begin
        @(negedge s4_bclk);
        s4_bclr_i = 1'b0;
      end
      begin
        while (s4_aiso_o !== 1'b1 && a_edges < 25) begin
          @(posedge s4_aclk);
          #1;
          if (s4_aiso_o !== 1'b1) a_edges++;
        end
      end
    join
    if (a_edges < 3) begin
      $display("FAIL: B->A CDC did not honor SYNC_STAGES=4 (a_isolate_o rose after only %0d a_clk edges)", a_edges + 1);
      $fatal(1);
    end
    wait_s4_idle(5000);

    // Also check i_state_transition_cdc_src ACK synchronizer honors SYNC_STAGES=4:
    // With fast s4_bclk (0.4ns) and slower s4_aclk (6.0ns), once s4_biso_ack=1,
    // ACK assertion + deassertion must each traverse 4 s4_aclk stages (>= 8 s4_aclk edges total;
    // hardcoded SYNC_STAGES=2 completes in only 5-6 s4_aclk edges!)
    t_s4_a = 3000;
    t_s4_b = 200;
    #5000;
    @(posedge s4_aclk);
    s4_aclr_i <= 1'b1;
    @(posedge s4_aclk);
    s4_aclr_i <= 1'b0;
    wait (s4_biso_ack == 1'b1);
    @(posedge s4_bclk); // async_b2a_ack is now 1
    a_edges = 0;
    while (s4_aclr_o !== 1'b1 && a_edges < 30) begin
      @(posedge s4_aclk);
      if (s4_aclr_o !== 1'b1) a_edges++;
    end
    if (a_edges < 8) begin
      $display("FAIL: src ACK synchronizer did not honor SYNC_STAGES=4 (a_clear_o rose after only %0d a_clk edges)", a_edges);
      $fatal(1);
    end
    t_s4_a = 2500;
    t_s4_b = 3100;
    wait_s4_idle(5000);

    // Check asymmetric Receiver reset recovery while Side A is requesting CLEAR:
    @(posedge s4_aclk);
    s4_aclr_i <= 1'b1;
    @(posedge s4_aclk);
    s4_aclr_i <= 1'b0;
    wait (s4_aclr_o == 1'b1);
    // Side A is now in CLEAR phase requesting CLEAR_PHASE_CLEAR; reset Side B!
    s4_brst_n = 1'b0;
    repeat (3) @(posedge s4_bclk);
    s4_brst_n = 1'b1;
    // Monitor on s4_bclk checks that s4_biso_o asserts and waits 3 cycles for s4_biso_ack BEFORE s4_bclr_o!
    wait_s4_idle(8000);

    // -----------------------------------------------------------------------
    // Test 6: Seeded randomized multi-ratio & concurrent RDC stress
    // -----------------------------------------------------------------------
    for (int iter = 0; iter < 16; iter++) begin
      int unsigned r;
      r = $urandom(seed + iter * 37);
      t_a_half   = 1500 + (r % 5500);
      t_b_half   = 1500 + ((r >> 8) % 5500);
      a_ack_mode = (r >> 16) & 1;
      b_ack_mode = (r >> 17) & 1;
      a_iso_delay = 1 + ((r >> 18) % 3);
      b_iso_delay = 1 + ((r >> 20) % 3);
      a_clr_delay = (r >> 22) % 2;
      b_clr_delay = (r >> 24) % 2;

      case (iter % 4)
        0: begin
          @(posedge a_clk); a_clear_i <= 1'b1; @(posedge a_clk); a_clear_i <= 1'b0;
        end
        1: begin
          @(posedge b_clk); b_clear_i <= 1'b1; @(posedge b_clk); b_clear_i <= 1'b0;
        end
        2: begin
          fork
            begin @(posedge a_clk); a_clear_i <= 1'b1; @(posedge a_clk); a_clear_i <= 1'b0; end
            begin #((r % 7) * 1000); @(posedge b_clk); b_clear_i <= 1'b1; @(posedge b_clk); b_clear_i <= 1'b0; end
          join
        end
        3: begin
          @(posedge a_clk); a_clear_i <= 1'b1; @(posedge a_clk); a_clear_i <= 1'b0;
          #((2 + (r % 9)) * 2000);
          if (r[5]) begin
            b_rst_n = 1'b0; #8000; b_rst_n = 1'b1;
          end else begin
            a_rst_n = 1'b0; #8000; a_rst_n = 1'b1;
          end
        end
      endcase
      wait_both_idle(8000);
    end

    $display("PASS seed=%0d a_clears=%0d b_clears=%0d", seed, a_clear_pulses, b_clear_pulses);
    $finish;
  end
endmodule
