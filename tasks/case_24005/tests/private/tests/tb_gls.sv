`timescale 1ps/1ps

module tb_gls;
  int unsigned seed = 101;
  initial begin
    void'($value$plusargs("seed=%d", seed));
  end

  logic w_clk = 1'b0;
  logic r_clk = 1'b0;
  bit   async_mode = 1'b0;

  initial begin
    forever begin
      if (!async_mode) begin
        #1250; w_clk = ~w_clk; r_clk = ~r_clk;
      end else begin
        #1250; r_clk = ~r_clk;
      end
    end
  end

  always begin
    wait (async_mode);
    while (async_mode) begin
      #1950 w_clk = ~w_clk;
    end
  end

  logic        w_rst = 1'b1, r_rst = 1'b1, w_enq = 1'b0, r_deq = 1'b0;
  logic [15:0] w_data = 16'h0000;
  wire         w_full, r_valid;
  wire  [15:0] r_data;

  bsg_async_fifo dut_gls (
    .w_clk_i(w_clk), .w_reset_i(w_rst), .w_enq_i(w_enq), .w_data_i(w_data), .w_full_o(w_full),
    .r_clk_i(r_clk), .r_reset_i(r_rst), .r_deq_i(r_deq), .r_data_o(r_data), .r_valid_o(r_valid)
  );

  bit mon_en = 1'b0;
  realtime last_rvalid_edge = -1.0;
  realtime last_wfull_edge  = -1.0;
  logic prev_rvalid = 1'b0;
  logic prev_wfull  = 1'b1;

  always @(r_valid) begin
    if (mon_en && (r_valid !== prev_rvalid)) begin
      if (r_valid === 1'bx || r_valid === 1'bz) begin
        $display("FAIL_GLS: X/Z on r_valid_o at t=%0t", $realtime);
        $fatal(1);
      end
      if (last_rvalid_edge > 0.0 && (($realtime - last_rvalid_edge) < 1600.0)) begin
        $display("FAIL_GLS: sub-cycle glitch on r_valid_o (pulse width %0.1f ps) at t=%0t",
                 ($realtime - last_rvalid_edge), $realtime);
        $fatal(1);
      end
      last_rvalid_edge = $realtime;
      prev_rvalid = r_valid;
    end else begin
      prev_rvalid = r_valid;
    end
  end

  always @(w_full) begin
    if (mon_en && (w_full !== prev_wfull)) begin
      if (w_full === 1'bx || w_full === 1'bz) begin
        $display("FAIL_GLS: X/Z on w_full_o at t=%0t", $realtime);
        $fatal(1);
      end
      if (last_wfull_edge > 0.0 && (($realtime - last_wfull_edge) < 1600.0)) begin
        $display("FAIL_GLS: sub-cycle glitch on w_full_o (pulse width %0.1f ps) at t=%0t",
                 ($realtime - last_wfull_edge), $realtime);
        $fatal(1);
      end
      last_wfull_edge = $realtime;
      prev_wfull = w_full;
    end else begin
      prev_wfull = w_full;
    end
  end

  always @(r_data) begin
    if (mon_en && (r_valid === 1'b0) && (($realtime - last_rvalid_edge) > 400.0)) begin
      if (r_data !== 16'h0000) begin
        $display("FAIL_GLS: empty-FIFO write-through glitch on r_data_o=%h while r_valid_o==0 at t=%0t", r_data, $realtime);
        $fatal(1);
      end
    end
  end

  logic [15:0] exp_q[$];

  initial begin
    repeat (4) @(posedge w_clk);
    @(negedge w_clk);
    w_rst = 1'b0;
    r_rst = 1'b0;
    while (w_full !== 1'b0 && $time < 200000) @(posedge w_clk);
    repeat (2) @(posedge w_clk);
    #400;
    prev_rvalid = r_valid;
    prev_wfull  = w_full;
    mon_en = 1'b1;

    // Phase 1A: Lockstep 1-item buffered streaming across all 16 Gray-code transitions
    for (int k = 0; k < 4; k++) begin
      @(negedge w_clk); w_enq = 1'b1; w_data = 16'hF000 + k[15:0]; exp_q.push_back(16'hF000 + k[15:0]);
    end
    for (int k = 4; k < 28; k++) begin
      @(negedge w_clk);
      w_enq  = 1'b1;
      w_data = 16'hF000 + k[15:0];
      exp_q.push_back(16'hF000 + k[15:0]);
      r_deq  = r_valid;
      if (r_valid) begin
        logic [15:0] exp_v;
        exp_v = exp_q.pop_front();
        if (r_data !== exp_v) begin
          $display("FAIL_GLS: Phase 1A data mismatch exp=%h got=%h at k=%0d", exp_v, r_data, k);
          $fatal(1);
        end
      end
    end
    @(negedge w_clk);
    w_enq = 1'b0;
    r_deq = 1'b0;
    while (exp_q.size() > 0) begin
      @(negedge r_clk);
      if (r_valid) begin
        logic [15:0] exp_v;
        exp_v = exp_q.pop_front();
        if (r_data !== exp_v) begin
          $display("FAIL_GLS: Phase 1A drain mismatch exp=%h got=%h", exp_v, r_data);
          $fatal(1);
        end
        r_deq = 1'b1;
      end else begin
        r_deq = 1'b0;
      end
    end
    @(negedge r_clk); r_deq = 1'b0;
    repeat (5) @(posedge r_clk);

    // Phase 1B: Lockstep near-full (7/8 items) streaming across 20 Gray transitions
    for (int k = 0; k < 7; k++) begin
      @(negedge w_clk); w_enq = 1'b1; w_data = 16'hC100 + k[15:0]; exp_q.push_back(16'hC100 + k[15:0]);
    end
    @(negedge w_clk); w_enq = 1'b0;
    repeat (4) @(posedge w_clk);
    for (int k = 7; k < 32; k++) begin
      @(negedge w_clk);
      r_deq = r_valid;
      if (r_valid) begin
        logic [15:0] exp_v;
        exp_v = exp_q.pop_front();
        if (r_data !== exp_v) begin
          $display("FAIL_GLS: Phase 1B data mismatch exp=%h got=%h", exp_v, r_data);
          $fatal(1);
        end
      end
      if (!w_full) begin
        w_enq  = 1'b1;
        w_data = 16'hC100 + k[15:0];
        exp_q.push_back(16'hC100 + k[15:0]);
      end else begin
        w_enq  = 1'b0;
      end
    end
    @(negedge w_clk);
    w_enq = 1'b0;
    r_deq = 1'b0;
    while (exp_q.size() > 0) begin
      @(negedge r_clk);
      if (r_valid) begin
        void'(exp_q.pop_front());
        r_deq = 1'b1;
      end else begin
        r_deq = 1'b0;
      end
    end
    @(negedge r_clk); r_deq = 1'b0;
    repeat (6) @(posedge r_clk);

    // Phase 2: Asynchronous clocks empty-write-through & streaming test
    async_mode = 1'b1;
    repeat (4) @(posedge w_clk);
    for (int k = 0; k < 20; k++) begin
      @(negedge w_clk);
      if (!w_full) begin
        w_enq  = 1'b1;
        w_data = 16'hA500 ^ (k[15:0] * 16'h1103);
        exp_q.push_back(w_data);
      end else begin
        w_enq = 1'b0;
      end
      @(negedge w_clk);
      w_enq = 1'b0;
      while (exp_q.size() > 0) begin
        @(negedge r_clk);
        if (r_valid) begin
          logic [15:0] exp_v;
          exp_v = exp_q.pop_front();
          if (r_data !== exp_v) begin
            $display("FAIL_GLS: Phase 2 async mismatch exp=%h got=%h", exp_v, r_data);
            $fatal(1);
          end
          r_deq = 1'b1;
          @(negedge r_clk);
          r_deq = 1'b0;
        end
      end
    end

    $display("PASS_GLS seed=%0d", seed);
    $finish;
  end
endmodule
