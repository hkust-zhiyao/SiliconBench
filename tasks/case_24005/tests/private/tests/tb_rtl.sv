`timescale 1ps/1ps

module tb;
  int unsigned seed = 101;
  initial begin
    void'($value$plusargs("seed=%d", seed));
  end

  int half_w_ps = 2000; // dynamically varied across 1:7 .. 7:1 clock ratios!
  int half_r_ps = 1250;
  logic w_clk = 1'b0;
  logic r_clk = 1'b0;

  initial begin
    #(110 + (seed % 70));
    forever #(half_w_ps) w_clk = ~w_clk;
  end

  initial begin
    #(260 + (seed % 90));
    forever #(half_r_ps) r_clk = ~r_clk;
  end

  logic        a_wrst = 1'b1, a_rrst = 1'b1, a_enq = 1'b0, a_deq = 1'b0, a_full, a_valid;
  logic [11:0] a_wdata = '0, a_rdata;

  bsg_async_fifo #(
    .lg_size_p(2),
    .width_p(12),
    .control_width_p(4),
    .and_data_with_valid_p(0)
  ) dut_split_nogate (
    .w_clk_i  (w_clk),
    .w_reset_i(a_wrst),
    .w_enq_i  (a_enq),
    .w_data_i (a_wdata),
    .w_full_o (a_full),
    .r_clk_i  (r_clk),
    .r_reset_i(a_rrst),
    .r_deq_i  (a_deq),
    .r_data_o (a_rdata),
    .r_valid_o(a_valid)
  );

  logic        b_wrst = 1'b1, b_rrst = 1'b1, b_enq = 1'b0, b_deq = 1'b0, b_full, b_valid;
  logic [11:0] b_wdata = '0, b_rdata;

  bsg_async_fifo #(
    .lg_size_p(2),
    .width_p(12),
    .control_width_p(4),
    .and_data_with_valid_p(1)
  ) dut_split_gate (
    .w_clk_i  (w_clk),
    .w_reset_i(b_wrst),
    .w_enq_i  (b_enq),
    .w_data_i (b_wdata),
    .w_full_o (b_full),
    .r_clk_i  (r_clk),
    .r_reset_i(b_rrst),
    .r_deq_i  (b_deq),
    .r_data_o (b_rdata),
    .r_valid_o(b_valid)
  );

  always @(a_rdata or a_valid) begin
    #1;
    if (a_valid === 1'b0 && a_rdata[11:8] !== 4'h0) begin
      $display("FAIL: dut_split_nogate leaked non-zero control MSBs %h while r_valid_o==0 at t=%0t", a_rdata[11:8], $time);
      $fatal(1);
    end
  end

  always @(b_rdata or b_valid) begin
    #1;
    if (b_valid === 1'b0 && b_rdata !== 12'h000) begin
      $display("FAIL: dut_split_gate leaked non-zero data %h while r_valid_o==0 at t=%0t", b_rdata, $time);
      $fatal(1);
    end
  end

  task automatic wait_a_ready(input string label);
    int guard = 0;
    while (a_full !== 1'b0 && guard < 120) begin
      @(posedge w_clk); #50;
      guard++;
    end
    if (a_full !== 1'b0) begin
      $display("FAIL: %s w_full_o stuck high after reset recovery", label);
      $fatal(1);
    end
  endtask

  task automatic wait_b_ready(input string label);
    int guard = 0;
    while (b_full !== 1'b0 && guard < 120) begin
      @(posedge w_clk); #50;
      guard++;
    end
    if (b_full !== 1'b0) begin
      $display("FAIL: %s w_full_o stuck high after reset recovery", label);
      $fatal(1);
    end
  endtask

  logic [11:0] sb_b[$];
  int unsigned rng_w, rng_r;

  initial begin
    rng_w = seed ^ 32'h5a3c9e71;
    rng_r = seed ^ 32'h9e3779b9;

    // Test 1: Cold reset isolation
    repeat (2) @(posedge w_clk);
    repeat (2) @(posedge r_clk);
    #50;
    if (a_full !== 1'b1 || b_full !== 1'b1 || a_valid !== 1'b0 || b_valid !== 1'b0) begin
      $display("FAIL: cold reset flags invalid (full=%b/%b valid=%b/%b)", a_full, b_full, a_valid, b_valid);
      $fatal(1);
    end

    @(negedge w_clk); a_wrst = 1'b0; b_wrst = 1'b0;
    @(negedge r_clk); a_rrst = 1'b0; b_rrst = 1'b0;
    wait_a_ready("cold_a");
    wait_b_ready("cold_b");
    repeat (6) @(posedge r_clk);

    // Test 2: Segmented empty-FIFO RAM write-through check
    @(negedge w_clk);
    a_enq = 1'b1; a_wdata = 12'hF_A5;
    b_enq = 1'b1; b_wdata = 12'hF_A5;
    @(posedge w_clk); #100;
    a_enq = 1'b0; b_enq = 1'b0;
    if (a_valid !== 1'b0 || a_rdata[11:8] !== 4'h0 || a_rdata[7:0] !== 8'hA5 || b_rdata !== 12'h000) begin
      $display("FAIL: segmented empty write-through isolation mismatch a=%b/%h b=%b/%h", a_valid, a_rdata, b_valid, b_rdata);
      $fatal(1);
    end

    repeat (6) @(posedge r_clk);
    if (a_valid !== 1'b1 || a_rdata !== 12'hF_A5 || b_valid !== 1'b1 || b_rdata !== 12'hF_A5) begin
      $display("FAIL: single-word delivery mismatch a=%b/%h b=%b/%h", a_valid, a_rdata, b_valid, b_rdata);
      $fatal(1);
    end
    @(negedge r_clk); a_deq = 1'b1; b_deq = 1'b1;
    @(posedge r_clk); #50;
    if (a_valid !== 1'b0 || b_valid !== 1'b0) begin
      $display("FAIL: r_valid_o did not drop immediately on single-word dequeue");
      $fatal(1);
    end
    @(posedge r_clk); // Illegal empty r_deq_i must be ignored!
    @(negedge r_clk); a_deq = 1'b0; b_deq = 1'b0;

    // Test 3: Exact capacity (4 entries) + 1-word/cycle burst throughput + ignored full w_enq_i
    repeat (5) @(posedge w_clk);
    for (int k = 0; k < 4; k++) begin
      @(negedge w_clk);
      if (b_full !== 1'b0) begin $display("FAIL: premature b_full at %0d", k); $fatal(1); end
      b_enq = 1'b1; b_wdata = 12'hA00 + k[11:0];
    end
    @(posedge w_clk); #50;
    if (b_full !== 1'b1) begin $display("FAIL: b_full not asserted after 4 writes"); $fatal(1); end
    @(negedge w_clk); b_wdata = 12'hEEE; // Illegal 5th write while full
    @(posedge w_clk);
    @(negedge w_clk); b_enq = 1'b0;

    repeat (5) @(posedge r_clk);
    @(negedge r_clk); b_deq = 1'b1;
    for (int k = 0; k < 4; k++) begin
      if (b_valid !== 1'b1 || b_rdata !== (12'hA00 + k[11:0])) begin
        $display("FAIL: burst read mismatch at %0d valid=%b data=%h", k, b_valid, b_rdata);
        $fatal(1);
      end
      @(posedge r_clk); #50;
    end
    if (b_valid !== 1'b0) begin $display("FAIL: b_valid stuck high after burst"); $fatal(1); end
    @(negedge r_clk); b_deq = 1'b0;

    // Test 4A: UNILATERAL writer reset (w_reset_i pulsed for 1 w_clk while r_reset_i==0, 7:1 fast w_clk vs slow r_clk!)
    half_w_ps = 500;  // 1.0 ns w_clk
    half_r_ps = 3500; // 7.0 ns r_clk (1:7 ratio!)
    repeat (6) @(posedge r_clk);
    // Populate 3 items, read 1 item -> w_ptr=8, r_ptr=6 (non-zero pointers + 2 items in FIFO!)
    for (int k = 0; k < 3; k++) begin
      @(negedge w_clk); b_enq = 1'b1; b_wdata = 12'h330 + k[11:0];
    end
    @(negedge w_clk); b_enq = 1'b0;
    repeat (4) @(posedge r_clk);
    @(negedge r_clk); b_deq = 1'b1;
    @(posedge r_clk);
    @(negedge r_clk); b_deq = 1'b0;

    // Pulse ONLY b_wrst for 1 w_clk edge (b_rrst remains 0 the entire time!)
    @(negedge w_clk); b_wrst = 1'b1;
    @(posedge w_clk); #50;
    if (b_full !== 1'b1) begin $display("FAIL: b_full not asserted immediately on unilateral w_reset_i"); $fatal(1); end
    @(negedge w_clk); b_wrst = 1'b0;

    // Wait for cross-domain RDC flush to complete and w_full_o to drop back to 0!
    wait_b_ready("unilateral_wrst");
    repeat (3) @(posedge r_clk); #50;
    if (b_valid !== 1'b0) begin
      $display("FAIL: stale b_valid==1 remained after unilateral w_reset_i recovery!");
      $fatal(1);
    end
    // Verify full 4-entry capacity restored after unilateral writer reset!
    for (int k = 0; k < 4; k++) begin
      @(negedge w_clk);
      if (b_full !== 1'b0) begin $display("FAIL: lost capacity at item %0d after unilateral w_reset_i", k); $fatal(1); end
      b_enq = 1'b1; b_wdata = 12'h710 + k[11:0];
    end
    @(posedge w_clk); #50;
    if (b_full !== 1'b1) begin $display("FAIL: not full after 4 writes post-unilateral-wrst"); $fatal(1); end
    @(negedge w_clk); b_enq = 1'b0;
    repeat (4) @(posedge r_clk);
    for (int k = 0; k < 4; k++) begin
      @(negedge r_clk);
      if (b_valid !== 1'b1 || b_rdata !== (12'h710 + k[11:0])) begin
        $display("FAIL: post-unilateral-wrst data mismatch at %0d: %b/%h", k, b_valid, b_rdata);
        $fatal(1);
      end
      b_deq = 1'b1;
      @(posedge r_clk); #50;
      b_deq = 1'b0;
    end

    // Test 4B: UNILATERAL reader reset (r_reset_i pulsed for 1 r_clk while w_reset_i==0, 7:1 fast r_clk vs slow w_clk!)
    half_w_ps = 3500; // 7.0 ns w_clk
    half_r_ps = 500;  // 1.0 ns r_clk (7:1 ratio!)
    repeat (4) @(posedge w_clk);
    for (int k = 0; k < 3; k++) begin
      @(negedge w_clk); b_enq = 1'b1; b_wdata = 12'h880 + k[11:0];
    end
    @(negedge w_clk); b_enq = 1'b0;
    repeat (5) @(posedge r_clk);

    // Pulse ONLY b_rrst for 1 r_clk edge (b_wrst remains 0!)
    @(negedge r_clk); b_rrst = 1'b1;
    @(posedge r_clk); #50;
    if (b_valid !== 1'b0) begin $display("FAIL: b_valid not cleared on unilateral r_reset_i"); $fatal(1); end
    @(negedge r_clk); b_rrst = 1'b0;

    // Wait for w_clk to observe & complete lockstep reset!
    repeat (3) @(posedge w_clk);
    wait_b_ready("unilateral_rrst");
    for (int c = 0; c < 8; c++) begin
      @(posedge r_clk); #50;
      if (b_valid !== 1'b0) begin
        $display("FAIL: phantom b_valid==1 after unilateral r_reset_i recovery at cycle %0d!", c);
        $fatal(1);
      end
    end

    // Restore nominal clocks & run 200-word randomized CDC stress test
    half_w_ps = 2000;
    half_r_ps = 1250;
    repeat (4) @(posedge w_clk);
    sb_b.delete();

    fork
      begin : writer_proc
        int sent = 0;
        while (sent < 200) begin
          @(negedge w_clk);
          rng_w = rng_w * 32'd1664525 + 32'd1013904223;
          if (!b_full && (rng_w[3:0] < 4'd11)) begin
            logic [11:0] val;
            val = {rng_w[15:12] | 4'h1, sent[7:0]};
            b_enq   = 1'b1;
            b_wdata = val;
            sb_b.push_back(val);
            sent++;
          end else begin
            b_enq   = 1'b0;
            b_wdata = rng_w[11:0];
          end
        end
        @(negedge w_clk);
        b_enq = 1'b0;
      end
      begin : reader_proc
        int rcvd = 0;
        int guard = 0;
        while (rcvd < 200 && guard < 4000) begin
          @(negedge r_clk);
          guard++;
          rng_r = rng_r * 32'd22695477 + 32'd1;
          if (b_valid && ((rng_r[5:4]) != 2'b00)) begin
            logic [11:0] exp;
            if (sb_b.size() == 0) begin
              $display("FAIL: b_valid asserted when scoreboard empty at rcvd=%0d", rcvd);
              $fatal(1);
            end
            exp = sb_b.pop_front();
            if (b_rdata !== exp) begin
              $display("FAIL: scoreboard mismatch at idx=%0d exp=%h got=%h", rcvd, exp, b_rdata);
              $fatal(1);
            end
            b_deq = 1'b1;
            rcvd++;
          end else begin
            b_deq = 1'b0;
          end
        end
        @(negedge r_clk);
        b_deq = 1'b0;
        if (rcvd != 200) begin
          $display("FAIL: timeout in CDC stress test (rcvd=%0d/200)", rcvd);
          $fatal(1);
        end
      end
    join

    repeat (6) @(posedge r_clk);
    if (b_valid !== 1'b0 || sb_b.size() != 0) begin
      $display("FAIL: residual valid/items after stress drain");
      $fatal(1);
    end

    $display("PASS_RTL seed=%0d", seed);
    $finish;
  end
endmodule
