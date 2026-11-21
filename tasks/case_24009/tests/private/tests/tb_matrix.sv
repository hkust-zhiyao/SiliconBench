`timescale 1ns/100ps

module pack_pair_harness #(
  parameter int C = 5,
  parameter int S = 1,
  parameter int W = 12,
  parameter int PAR = 0,
  parameter int PIPE = 0
) (
  input  logic clk,
  input  logic [31:0] seed_i,
  output logic done_o,
  output logic err_o
);
  localparam int N  = C * S;
  localparam int DW = N * W;

  logic rst = 1'b1;
  logic [C-1:0] en = '0;

  // Cpack signals
  logic [C-1:0]  wr_en = '0;
  logic [DW-1:0] wr_data = '0;
  wire           p_wr_en;
  wire  [DW-1:0] p_wr_data;
  wire           p_sync;

  // Upack signals
  logic [C-1:0]  rd_en = '0;
  wire           rd_valid;
  wire           rd_uflow;
  wire  [DW-1:0] rd_data;
  logic          s_valid = 1'b0;
  wire           s_ready;
  logic [DW-1:0] s_data = '0;

  util_cpack2_impl #(
    .NUM_OF_CHANNELS(C),
    .SAMPLES_PER_CHANNEL(S),
    .SAMPLE_DATA_WIDTH(W),
    .INTERFACE_TYPE(1),
    .PARALLEL_OR_SERIAL_N(PAR),
    .PIPELINE_STAGES(PIPE)
  ) u_cpack (
    .clk(clk),
    .reset(rst),
    .enable(en),
    .fifo_wr_en(wr_en),
    .fifo_wr_overflow(),
    .fifo_wr_data(wr_data),
    .m_axis_ready(1'b1),
    .m_axis_valid(),
    .m_axis_data(),
    .m_axis_keep(),
    .m_axis_last(),
    .packed_fifo_wr_en(p_wr_en),
    .packed_fifo_wr_overflow(1'b0),
    .packed_fifo_wr_data(p_wr_data),
    .packed_sync(p_sync)
  );

  util_upack2_impl #(
    .NUM_OF_CHANNELS(C),
    .SAMPLES_PER_CHANNEL(S),
    .SAMPLE_DATA_WIDTH(W),
    .PARALLEL_OR_SERIAL_N(PAR),
    .PIPELINE_STAGES(PIPE)
  ) u_upack (
    .clk(clk),
    .reset(rst),
    .enable(en),
    .fifo_rd_en(rd_en),
    .fifo_rd_valid(rd_valid),
    .fifo_rd_underflow(rd_uflow),
    .fifo_rd_data(rd_data),
    .s_axis_valid(s_valid),
    .s_axis_ready(s_ready),
    .s_axis_data(s_data)
  );

  // Pack-to-unpack elastic FIFO + golden sample stream scoreboard!
  logic [DW-1:0] word_buf [0:511];
  int            word_wptr = 0;
  int            word_rptr = 0;
  logic [W-1:0]  exp_cpack_samples[$];
  bit            exp_cpack_first_tag[$];
  logic [W-1:0]  exp_upack_samples[$];

  // Monitor cpack outputs
  always @(posedge clk) begin
    if (!rst && p_wr_en) begin
      word_buf[word_wptr] <= p_wr_data;
      word_wptr <= word_wptr + 1;
      if (exp_cpack_samples.size() < N) begin
        $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: premature packed_fifo_wr_en (only %0d/%0d samples queued)",
                 C, S, W, PIPE, exp_cpack_samples.size(), N);
        err_o <= 1'b1;
      end else begin
        bit exp_sync;
        exp_sync = exp_cpack_first_tag.pop_front();
        for (int idx = 1; idx < N; idx++) void'(exp_cpack_first_tag.pop_front());
        if (p_sync !== exp_sync) begin
          $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: packed_sync=%b expected=%b (en=%b)",
                   C, S, W, PIPE, p_sync, exp_sync, en);
          err_o <= 1'b1;
        end
        for (int idx = 0; idx < N; idx++) begin
          logic [W-1:0] es, gs;
          es = exp_cpack_samples.pop_front();
          gs = p_wr_data[idx*W +: W];
          if (gs !== es) begin
            $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: cpack slot %0d got=%h exp=%h (en=%b)",
                     C, S, W, PIPE, idx, gs, es, en);
            err_o <= 1'b1;
          end
        end
      end
    end
  end

  // Drive s_axis from word_buf via synchronous read pointer (no Active-region pop race!)
  always @(*) begin
    if (word_rptr < word_wptr) begin
      s_valid = 1'b1;
      s_data  = word_buf[word_rptr];
    end else begin
      s_valid = 1'b0;
      s_data  = '0;
    end
  end

  always @(posedge clk) begin
    if (!rst && s_valid && s_ready) begin
      word_rptr <= word_rptr + 1;
    end
  end

  // Monitor upack outputs
  int unpacked_beats = 0;
  always @(posedge clk) begin
    if (!rst && rd_valid) begin
      unpacked_beats++;
      for (int s = 0; s < S; s++) begin
        for (int c = 0; c < C; c++) begin
          if (en[c]) begin
            if (exp_upack_samples.size() == 0) begin
              $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: unexpected rd_valid!", C, S, W, PIPE);
              err_o <= 1'b1;
            end else begin
              logic [W-1:0] eu, gu;
              eu = exp_upack_samples.pop_front();
              gu = rd_data[(c*S + s)*W +: W];
              if (gu !== eu) begin
                $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: upack ch=%0d s=%0d got=%h exp=%h (en=%b)",
                         C, S, W, PIPE, c, s, gu, eu, en);
                err_o <= 1'b1;
              end
            end
          end
        end
      end
    end
  end

  task automatic run_mask(input logic [C-1:0] mask_v, input int num_frames, input bit pulse_rst, ref int unsigned rng);
    int k_en;
    int total_in_beats;
    k_en = 0;
    for (int c = 0; c < C; c++) if (mask_v[c]) k_en++;
    // Choose an exact multiple of N beats so total enabled samples = (m * N) * (k_en * S) is a clean multiple of N!
    total_in_beats = num_frames * N;

    word_wptr = 0;
    word_rptr = 0;
    exp_cpack_samples.delete();
    exp_cpack_first_tag.delete();
    exp_upack_samples.delete();
    unpacked_beats = 0;

    @(negedge clk);
    wr_en = '0;
    rd_en = '0;
    if (pulse_rst) begin
      rst = 1'b1;
      en  = mask_v;
      repeat (6) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
    end else begin
      // Dynamic runtime mask reconfiguration WITHOUT pulsing reset!
      en = mask_v;
    end

    // Wait 6 cycles for internal prefix-sum & startup_ctrl pipeline to settle
    repeat (6) @(posedge clk);

    // Feed total_in_beats into cpack with pseudo-random gaps
    begin
      int sent = 0;
      while (sent < total_in_beats) begin
        @(negedge clk);
        rng = rng * 32'd1664525 + 32'd1013904223;
        if (rng[1:0] != 2'b00) begin
          wr_en = {C{1'b1}};
          begin
            bit first_en_ch;
            first_en_ch = 1'b1;
            // Generate deterministic sample values AND push expected interleaved order (s outer, c inner!)
            for (int c = 0; c < C; c++) begin
              for (int s = 0; s < S; s++) begin
                logic [W-1:0] val;
                rng = rng * 32'd1664525 + 32'd1013904223;
                val = rng[W-1:0] ^ W'((sent * 37) + (c * 13) + s + 1);
                wr_data[(c*S + s)*W +: W] = val;
              end
            end
            for (int s = 0; s < S; s++) begin
              for (int c = 0; c < C; c++) begin
                if (mask_v[c]) begin
                  logic [W-1:0] v_push;
                  v_push = wr_data[(c*S + s)*W +: W];
                  exp_cpack_samples.push_back(v_push);
                  exp_cpack_first_tag.push_back(first_en_ch && (s == 0));
                  exp_upack_samples.push_back(v_push);
                  first_en_ch = 1'b0;
                end
              end
            end
          end
          sent++;
        end else begin
          wr_en = '0;
        end
        @(posedge clk);
      end
      // If PIPELINE_STAGES > 0 in cpack, send PIPE*2 extra flush beats (and pop them cleanly) OR remember cpack is ce-stepped!
      // Wait: in cpack, when PIPELINE_STAGES > 0, the last `L` words sit in the ce-gated pipeline until `L` more ce pulses arrive!
      if (PIPE > 0 && C > 1) begin
        for (int f = 0; f < N; f++) begin
          @(negedge clk);
          wr_en = {C{1'b1}};
          begin
            bit first_en_ch;
            first_en_ch = 1'b1;
            for (int c = 0; c < C; c++)
              for (int s = 0; s < S; s++)
                wr_data[(c*S + s)*W +: W] = W'(16'hA500 + f*17 + c*3 + s);
            for (int s = 0; s < S; s++) begin
              for (int c = 0; c < C; c++) begin
                if (mask_v[c]) begin
                  logic [W-1:0] vp;
                  vp = wr_data[(c*S + s)*W +: W];
                  exp_cpack_samples.push_back(vp);
                  exp_cpack_first_tag.push_back(first_en_ch && (s == 0));
                  exp_upack_samples.push_back(vp);
                  first_en_ch = 1'b0;
                end
              end
            end
          end
          @(posedge clk);
        end
        // Notice: with L <= 2 ce-cycles of pipeline latency in cpack, ONLY the last L beats remain inside cpack's ce-pipeline when wr_en stops!
        // Drain all words that ALREADY exited into word_q through upack!
      end
      @(negedge clk);
      wr_en = '0;
    end

    repeat (4) @(posedge clk);

    // Now drain word_q completely through upack with intermittent rd_en gaps!
    begin
      int expected_words_emitted;
      int expected_upack_beats;
      int guard;
      expected_words_emitted = word_wptr;
      if (expected_words_emitted < num_frames * k_en * S - 2) begin
        $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: too few packed words emitted (%0d) for mask=%b",
                 C, S, W, PIPE, expected_words_emitted, mask_v);
        err_o <= 1'b1;
      end
      expected_upack_beats = (expected_words_emitted * N) / (k_en * S);
      // Trim exp_upack_samples to exact multiple of word_wptr * N if PIPE > 0 left L partial beats inside cpack
      while (exp_upack_samples.size() > expected_upack_beats * k_en * S)
        void'(exp_upack_samples.pop_back());

      guard = 0;
      while (unpacked_beats < expected_upack_beats && guard < 2000) begin
        @(negedge clk);
        guard++;
        rng = rng * 32'd1664525 + 32'd1013904223;
        if (word_rptr < word_wptr && rng[2:0] != 3'b000)
          rd_en = {C{1'b1}};
        else
          rd_en = '0;
        @(posedge clk);
      end
      @(negedge clk);
      rd_en = '0;
      repeat (8) @(posedge clk);

      if (unpacked_beats != expected_upack_beats || word_rptr != word_wptr || exp_upack_samples.size() != 0) begin
        $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: upack drain mismatch beats=%0d/%0d rem_words=%0d rem_samp=%0d (mask=%b)",
                 C, S, W, PIPE, unpacked_beats, expected_upack_beats, (word_wptr - word_rptr), exp_upack_samples.size(), mask_v);
        err_o <= 1'b1;
      end
    end

    // Also test underflow behavior on upack when word_q is empty (s_axis_valid == 0)!
    begin
      bit saw_uflow = 1'b0;
      @(negedge clk);
      rd_en = {C{1'b1}};
      @(posedge clk); #1;
      if (rd_uflow) begin
        saw_uflow = 1'b1;
        if (rd_valid !== 1'b0 || rd_data !== '0) begin
          $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: underflow failed to zero rd_data or deassert rd_valid!", C, S, W, PIPE);
          err_o <= 1'b1;
        end
      end
      @(negedge clk);
      rd_en = '0;
      for (int w = 0; w < 6; w++) begin
        @(posedge clk); #1;
        if (rd_uflow) begin
          saw_uflow = 1'b1;
          if (rd_valid !== 1'b0 || rd_data !== '0) begin
            $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: underflow failed to zero rd_data or deassert rd_valid!", C, S, W, PIPE);
            err_o <= 1'b1;
          end
        end
      end
      if (!saw_uflow) begin
        $display("FAIL_PACK[C=%0d S=%0d W=%0d P=%0d]: missing fifo_rd_underflow pulse when s_axis_valid==0!", C, S, W, PIPE);
        err_o <= 1'b1;
      end
    end
  endtask

  initial begin
    int unsigned rng;
    done_o = 1'b0;
    err_o  = 1'b0;
    rng = seed_i ^ (32'h9E37_79B9 * (C * 17 + S * 5 + W + PIPE));

    if (C == 1) begin
      run_mask(1'b1, 4, 1'b1, rng);
    end else if (C == 3) begin
      run_mask(3'b111, 4, 1'b1, rng);
      run_mask(3'b101, 5, 1'b0, rng); // dynamic mask switch without reset! (K=2 > 3/2 -> consecutive spanning!)
      run_mask(3'b010, 4, 1'b0, rng); // dynamic mask switch to single middle channel!
      run_mask(3'b110, 4, 1'b1, rng);
    end else if (C == 5) begin
      run_mask(5'b11111, 3, 1'b1, rng);
      run_mask(5'b11101, 4, 1'b0, rng); // K=4 out of 5 -> 3 CONSECUTIVE spanning beats in upack + dynamic switch!
      run_mask(5'b10101, 4, 1'b0, rng); // K=3 out of 5 -> odd active subset in odd channel count!
      run_mask(5'b01010, 4, 1'b0, rng); // K=2 out of 5!
      run_mask(5'b00100, 3, 1'b1, rng); // K=1!
    end else if (C == 6) begin
      run_mask(6'b111101, 3, 1'b1, rng); // K=5*S out of 6*S!
      run_mask(6'b101010, 3, 1'b0, rng); // K=3*S out of 6*S!
      run_mask(6'b011001, 3, 1'b0, rng);
      run_mask(6'b100001, 3, 1'b0, rng); // K=2*S!
    end else begin
      run_mask({C{1'b1}}, 3, 1'b1, rng);
      run_mask(C'('b1011), 4, 1'b0, rng);
    end

    done_o = 1'b1;
  end
endmodule

module tb_matrix;
  int unsigned seed = 101;
  initial void'($value$plusargs("seed=%d", seed));

  logic clk = 1'b0;
  always #2 clk = ~clk;

  wire [4:0] done_v, err_v;

  // 1) Odd C=3, S=1, W=12, serial prefix, PIPE=0
  pack_pair_harness #(.C(3), .S(1), .W(12), .PAR(0), .PIPE(0)) h0 (.clk(clk), .seed_i(seed), .done_o(done_v[0]), .err_o(err_v[0]));
  // 2) Odd C=5, S=1, W=24, parallel prefix, PIPE=1
  pack_pair_harness #(.C(5), .S(1), .W(24), .PAR(1), .PIPE(1)) h1 (.clk(clk), .seed_i(seed), .done_o(done_v[1]), .err_o(err_v[1]));
  // 3) Non-pow2 C=6, S=2 (N=12), W=16, parallel prefix, PIPE=2
  pack_pair_harness #(.C(6), .S(2), .W(16), .PAR(1), .PIPE(2)) h2 (.clk(clk), .seed_i(seed), .done_o(done_v[2]), .err_o(err_v[2]));
  // 4) Pow2 C=4, S=1, W=16, serial prefix, PIPE=2 (regression check on pow2!)
  pack_pair_harness #(.C(4), .S(1), .W(16), .PAR(0), .PIPE(2)) h3 (.clk(clk), .seed_i(seed), .done_o(done_v[3]), .err_o(err_v[3]));
  // 5) Degenerate C=1, S=2, W=16, PIPE=2
  pack_pair_harness #(.C(1), .S(2), .W(16), .PAR(0), .PIPE(2)) h4 (.clk(clk), .seed_i(seed), .done_o(done_v[4]), .err_o(err_v[4]));

  initial begin
    wait (&done_v);
    @(posedge clk);
    if (|err_v) begin
      $display("FAIL_MATRIX err_v=%b", err_v);
      $fatal(1);
    end
    $display("PASS_MATRIX seed=%0d", seed);
    $finish;
  end
endmodule
