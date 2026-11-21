// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb #(
  parameter int unsigned SEED = 101
);
  import prim_sha2_pkg::*;

  logic          clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  logic          rst_ni              = 1'b0;
  logic [1023:0] secret_key_i        = '0;
  logic          hmac_en_i           = 1'b0;
  digest_mode_e  digest_size_i       = SHA2_256;
  key_length_e   key_length_i        = Key_256;
  logic          sha_en_i            = 1'b1;
  logic          reg_hash_start_i    = 1'b0;
  logic          reg_hash_stop_i     = 1'b0;
  logic          reg_hash_continue_i = 1'b0;
  logic          reg_hash_process_i  = 1'b0;
  logic          abort_i             = 1'b0;
  logic          sha_hash_done_i     = 1'b0;
  logic [63:0]   message_length_i    = 64'd0;
  logic          fifo_rvalid_i       = 1'b0;
  sha_fifo32_t   fifo_rdata_i        = '0;
  wire           fifo_rready_o;
  wire           fifo_wsel_o;
  wire           fifo_wvalid_o;
  wire  [3:0]    fifo_wdata_sel_o;
  logic          fifo_wready_i       = 1'b1;
  wire           shaf_rvalid_o;
  wire  sha_word64_t shaf_rdata_o;
  logic          shaf_rready_i       = 1'b1;
  wire           sha_hash_start_o;
  wire           sha_hash_continue_o;
  wire           sha_hash_process_o;
  wire           hash_done_o;
  wire  [63:0]   sha_message_length_o;
  wire           msg_feed_complete_o;
  wire           idle_o;

  ot_hmac_pad_top dut (
    .clk_i,
    .rst_ni,
    .secret_key_i,
    .hmac_en_i,
    .digest_size_i,
    .key_length_i,
    .sha_en_i,
    .reg_hash_start_i,
    .reg_hash_stop_i,
    .reg_hash_continue_i,
    .reg_hash_process_i,
    .abort_i,
    .sha_hash_done_i,
    .message_length_i,
    .fifo_rvalid_i,
    .fifo_rdata_i,
    .fifo_rready_o,
    .fifo_wsel_o,
    .fifo_wvalid_o,
    .fifo_wdata_sel_o,
    .fifo_wready_i,
    .shaf_rvalid_o,
    .shaf_rdata_o,
    .shaf_rready_i,
    .sha_hash_start_o,
    .sha_hash_continue_o,
    .sha_hash_process_o,
    .hash_done_o,
    .sha_message_length_o,
    .msg_feed_complete_o,
    .idle_o
  );

  sha_word32_t shaf_words[$];
  logic [3:0]  push_sel_q[$];

  always @(posedge clk_i) begin
    if (rst_ni) begin
      if (shaf_rvalid_o && shaf_rready_i) begin
        if (shaf_rdata_o[63:32] !== 32'h0) begin
          $display("FAIL: upper 32 bits of shaf_rdata_o nonzero: %016h", shaf_rdata_o);
          $finish(1);
        end
        shaf_words.push_back(shaf_rdata_o[31:0]);
      end
      if (fifo_wsel_o && fifo_wvalid_o && fifo_wready_i) begin
        push_sel_q.push_back(fifo_wdata_sel_o);
      end
    end
  end

  task automatic reset_dut();
    @(negedge clk_i);
    rst_ni              = 1'b0;
    secret_key_i        = '0;
    hmac_en_i           = 1'b0;
    digest_size_i       = SHA2_256;
    key_length_i        = Key_256;
    sha_en_i            = 1'b1;
    reg_hash_start_i    = 1'b0;
    reg_hash_stop_i     = 1'b0;
    reg_hash_continue_i = 1'b0;
    reg_hash_process_i  = 1'b0;
    abort_i             = 1'b0;
    sha_hash_done_i     = 1'b0;
    message_length_i    = 64'd0;
    fifo_rvalid_i       = 1'b0;
    fifo_rdata_i        = '0;
    fifo_wready_i       = 1'b1;
    shaf_rready_i       = 1'b1;
    shaf_words.delete();
    push_sel_q.delete();
    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;
    @(posedge clk_i);
  endtask

  function automatic sha_word32_t expected_key_pad(
    input logic [1023:0] k,
    input key_length_e   klen,
    input int            w_idx,
    input logic [7:0]    pad_byte
  );
    logic [31:0] kw;
    logic        en;
    kw = k[1023 - 32*w_idx -: 32];
    case (klen)
      Key_128:  en = (w_idx < 4);
      Key_256:  en = (w_idx < 8);
      Key_384:  en = (w_idx < 12);
      Key_512:  en = (w_idx < 16);
      Key_1024: en = 1'b0;
      default:  en = 1'b0;
    endcase
    return (en ? kw : 32'h0) ^ {4{pad_byte}};
  endfunction

  task automatic build_expected_sha256_blockStream(
    input sha_fifo32_t msg_q[$],
    input logic [63:0] total_len_bits,
    output sha_word32_t exp_q[$]
  );
    logic [1:0] rem_bytes;
    sha_fifo32_t last_w;
    exp_q.delete();

    for (int i = 0; i < msg_q.size(); i++) begin
      if (msg_q[i].mask == 4'hF) begin
        exp_q.push_back(msg_q[i].data);
      end
    end

    rem_bytes = total_len_bits[4:3];
    if (rem_bytes == 2'b00) begin
      exp_q.push_back(32'h8000_0000);
    end else begin
      last_w = msg_q[msg_q.size()-1];
      case (rem_bytes)
        2'b01: exp_q.push_back({last_w.data[31:24], 24'h8000_00});
        2'b10: exp_q.push_back({last_w.data[31:16], 16'h8000});
        default: exp_q.push_back({last_w.data[31:8], 8'h80});
      endcase
    end

    while ((exp_q.size() % 16) != 14) begin
      exp_q.push_back(32'h0000_0000);
    end
    exp_q.push_back(total_len_bits[63:32]);
    exp_q.push_back(total_len_bits[31:0]);
  endtask

  task automatic run_hmac_or_sha_test(
    input logic          is_hmac,
    input key_length_e   klen,
    input int            msg_bytes,
    input int unsigned   stall_seed
  );
    sha_fifo32_t in_q[$];
    sha_fifo32_t inner_stream[$];
    sha_fifo32_t outer_stream[$];
    sha_word32_t exp_inner[$];
    sha_word32_t exp_outer[$];
    sha_word32_t exp_all[$];
    sha_word32_t fake_inner_digest[8];
    int unsigned rng;
    int full_words, rem_b;
    int cyc;
    logic inner_done_sent;

    reset_dut();
    rng = stall_seed;

    @(negedge clk_i);
    for (int w = 0; w < 32; w++) begin
      rng = rng * 32'd1664525 + 32'd1013904223;
      secret_key_i[1023 - 32*w -: 32] = rng ^ (32'hA5A5_0000 + w);
    end
    for (int d = 0; d < 8; d++) begin
      fake_inner_digest[d] = 32'hD16E_5700 + d;
    end

    hmac_en_i        = is_hmac;
    digest_size_i    = SHA2_256;
    key_length_i     = klen;
    sha_en_i         = 1'b1;
    message_length_i = 64'(msg_bytes) * 64'd8;

    full_words = msg_bytes / 4;
    rem_b      = msg_bytes % 4;
    for (int i = 0; i < full_words; i++) begin
      sha_fifo32_t it;
      rng     = rng * 32'd1664525 + 32'd1013904223;
      it.data = rng;
      it.mask = 4'hF;
      in_q.push_back(it);
    end
    if (rem_b != 0) begin
      sha_fifo32_t it;
      rng     = rng * 32'd1664525 + 32'd1013904223;
      it.data = rng;
      it.mask = (rem_b == 1) ? 4'b0001 : (rem_b == 2) ? 4'b0011 : 4'b0111;
      in_q.push_back(it);
    end

    if (is_hmac) begin
      for (int w = 0; w < 16; w++) begin
        sha_fifo32_t it;
        it.data = expected_key_pad(secret_key_i, klen, w, 8'h36);
        it.mask = 4'hF;
        inner_stream.push_back(it);
      end
      for (int i = 0; i < in_q.size(); i++) inner_stream.push_back(in_q[i]);
      build_expected_sha256_blockStream(inner_stream, message_length_i + 64'd512, exp_inner);

      for (int w = 0; w < 16; w++) begin
        sha_fifo32_t it;
        it.data = expected_key_pad(secret_key_i, klen, w, 8'h5c);
        it.mask = 4'hF;
        outer_stream.push_back(it);
      end
      for (int d = 0; d < 8; d++) begin
        sha_fifo32_t it;
        it.data = fake_inner_digest[d];
        it.mask = 4'hF;
        outer_stream.push_back(it);
      end
      build_expected_sha256_blockStream(outer_stream, 64'd768, exp_outer);

      for (int i = 0; i < exp_inner.size(); i++) exp_all.push_back(exp_inner[i]);
      for (int i = 0; i < exp_outer.size(); i++) exp_all.push_back(exp_outer[i]);
    end else begin
      for (int i = 0; i < in_q.size(); i++) inner_stream.push_back(in_q[i]);
      build_expected_sha256_blockStream(inner_stream, message_length_i, exp_inner);
      for (int i = 0; i < exp_inner.size(); i++) exp_all.push_back(exp_inner[i]);
    end

    reg_hash_start_i = 1'b1;
    @(negedge clk_i);
    reg_hash_start_i   = 1'b0;
    reg_hash_process_i = 1'b1;
    @(negedge clk_i);
    reg_hash_process_i = 1'b0;

    inner_done_sent = 1'b0;
    cyc = 0;
    while (cyc < 600) begin
      rng = rng * 32'd1664525 + 32'd1013904223;
      shaf_rready_i = (rng[1:0] != 2'b00);
      fifo_wready_i = (rng[3:2] != 2'b00);
      if (in_q.size() > 0 && (rng[5:4] != 2'b00 || in_q[0].mask != 4'hF)) begin
        fifo_rvalid_i = 1'b1;
        fifo_rdata_i  = in_q[0];
      end else begin
        fifo_rvalid_i = 1'b0;
        fifo_rdata_i  = '0;
      end

      @(posedge clk_i);
      if (fifo_rvalid_i && fifo_rready_o && in_q.size() > 0) begin
        void'(in_q.pop_front());
      end

      @(negedge clk_i);
      if (is_hmac && !inner_done_sent && shaf_words.size() == exp_inner.size() && msg_feed_complete_o) begin
        sha_hash_done_i = 1'b1;
        @(negedge clk_i);
        sha_hash_done_i = 1'b0;
        inner_done_sent = 1'b1;
        for (int d = 0; d < 8; d++) begin
          sha_fifo32_t dit;
          dit.data = fake_inner_digest[d];
          dit.mask = 4'hF;
          in_q.push_back(dit);
        end
      end

      if (shaf_words.size() == exp_all.size() && msg_feed_complete_o) begin
        sha_hash_done_i = 1'b1;
        #1;
        if (!is_hmac && hash_done_o !== 1'b1) begin
          $display("FAIL: expected hash_done_o=1 in SHA mode");
          $finish(1);
        end
        @(negedge clk_i);
        sha_hash_done_i = 1'b0;
        #1;
        if (is_hmac && hash_done_o !== 1'b1) begin
          $display("FAIL: expected hash_done_o=1 in HMAC StDone");
          $finish(1);
        end
        @(negedge clk_i);
        break;
      end
      cyc++;
    end

    fifo_rvalid_i = 1'b0;
    shaf_rready_i = 1'b1;
    fifo_wready_i = 1'b1;

    if (cyc >= 600) begin
      $display("FAIL: timeout in run_hmac_or_sha_test (hmac=%0d klen=%0d msg_bytes=%0d got=%0d exp=%0d)",
               is_hmac, klen, msg_bytes, shaf_words.size(), exp_all.size());
      $finish(1);
    end

    if (is_hmac) begin
      if (push_sel_q.size() != 8) begin
        $display("FAIL: expected 8 digest push handshakes, got %0d", push_sel_q.size());
        $finish(1);
      end
      for (int d = 0; d < 8; d++) begin
        if (push_sel_q[d] !== 4'(d)) begin
          $display("FAIL: digest push index[%0d] = %0d, expected %0d", d, push_sel_q[d], d);
          $finish(1);
        end
      end
    end

    if (shaf_words.size() != exp_all.size()) begin
      $display("FAIL: shaf_words size %0d != expected %0d", shaf_words.size(), exp_all.size());
      $finish(1);
    end
    for (int i = 0; i < exp_all.size(); i++) begin
      if (shaf_words[i] !== exp_all[i]) begin
        $display("FAIL: word[%0d] mismatch (hmac=%0d klen=%0d msg_bytes=%0d): got %08h, exp %08h",
                 i, is_hmac, klen, msg_bytes, shaf_words[i], exp_all[i]);
        $finish(1);
      end
    end
  endtask

  task automatic test_abort_clears_process_flag();
    reset_dut();
    @(negedge clk_i);
    hmac_en_i          = 1'b1;
    digest_size_i      = SHA2_256;
    key_length_i       = Key_256;
    sha_en_i           = 1'b1;
    message_length_i   = 64'd64;
    reg_hash_start_i   = 1'b1;
    reg_hash_process_i = 1'b1;
    @(negedge clk_i);
    reg_hash_start_i   = 1'b0;
    reg_hash_process_i = 1'b0;

    repeat (4) @(negedge clk_i);
    abort_i  = 1'b1;
    sha_en_i = 1'b0;
    @(negedge clk_i);
    abort_i  = 1'b0;
    sha_en_i = 1'b1;
    #1;
    if (!idle_o) begin
      $display("FAIL: expected idle_o=1 immediately after abort_i");
      $finish(1);
    end
    shaf_words.delete();

    // Also test that reg_hash_continue_i after abort_i does not see stale reg_hash_process_flag
    message_length_i    = 64'd0;
    reg_hash_continue_i = 1'b1;
    @(negedge clk_i);
    reg_hash_continue_i = 1'b0;
    message_length_i    = 64'd64;

    for (int w = 0; w < 2; w++) begin
      fifo_rvalid_i = 1'b1;
      fifo_rdata_i  = '{data: 32'hCAFE_0000 + w, mask: 4'hF};
      @(posedge clk_i);
      while (!(fifo_rvalid_i && fifo_rready_o)) @(posedge clk_i);
      @(negedge clk_i);
    end
    // Now txcount == 64 == message_length_i, but reg_hash_process_i was NOT asserted after abort_i.
    // Therefore hmac_core must still be in StMsg (not stuck in StWaitResp), so increasing message_length_i
    // and feeding a 3rd word must be accepted with fifo_rready_o == 1!
    message_length_i = 64'd96;
    fifo_rvalid_i    = 1'b1;
    fifo_rdata_i     = '{data: 32'hCAFE_0002, mask: 4'hF};
    @(negedge clk_i);
    if (!fifo_rready_o || shaf_words.size() != 3) begin
      $display("FAIL: stale reg_hash_process_flag survived abort_i and locked StWaitResp! rready=%0b size=%0d",
               fifo_rready_o, shaf_words.size());
      $finish(1);
    end
    fifo_rvalid_i = 1'b0;
  endtask

  task automatic test_stop_and_continue();
    reset_dut();
    @(negedge clk_i);
    hmac_en_i        = 1'b1;
    digest_size_i    = SHA2_256;
    key_length_i     = Key_128;
    sha_en_i         = 1'b1;
    secret_key_i     = {128'h01020304_05060708_090a0b0c_0d0e0f10, 896'b0};
    message_length_i = 64'd512;
    reg_hash_start_i = 1'b1;
    @(negedge clk_i);
    reg_hash_start_i = 1'b0;
    reg_hash_stop_i  = 1'b1;
    @(negedge clk_i);
    reg_hash_stop_i  = 1'b0;

    while (shaf_words.size() < 16) @(negedge clk_i);

    for (int w = 0; w < 16; w++) begin
      fifo_rvalid_i = 1'b1;
      fifo_rdata_i  = '{data: 32'h1111_0000 + w, mask: 4'hF};
      @(posedge clk_i);
      while (!(fifo_rvalid_i && fifo_rready_o)) @(posedge clk_i);
      @(negedge clk_i);
    end
    fifo_rvalid_i = 1'b0;

    repeat (4) @(negedge clk_i);
    if (shaf_words.size() != 32 || !msg_feed_complete_o) begin
      $display("FAIL: stop at block boundary expected 32 words and msg_feed_complete_o=1, got size=%0d complete=%0b",
               shaf_words.size(), msg_feed_complete_o);
      $finish(1);
    end
    #1;
    if (!idle_o) begin
      $display("FAIL: expected idle_o=1 at stop block boundary");
      $finish(1);
    end
    sha_hash_done_i = 1'b1;
    @(negedge clk_i);
    sha_hash_done_i = 1'b0;
    #1;
    if (!hash_done_o) begin
      $display("FAIL: expected hash_done_o=1 in StDone after stop");
      $finish(1);
    end
    @(negedge clk_i);
    #1;
    if (!idle_o) begin
      $display("FAIL: expected idle_o=1 after returning to StIdle");
      $finish(1);
    end

    shaf_words.delete();
    // On reg_hash_continue_i, message_length_i holds the already-processed message bits (512 bits)
    message_length_i    = 64'd512;
    reg_hash_continue_i = 1'b1;
    @(negedge clk_i);
    reg_hash_continue_i = 1'b0;
    // Software writes 1 more 32-bit word (32 bits -> total 544 bits) and then pulses reg_hash_process_i
    message_length_i   = 64'd544;
    fifo_rvalid_i      = 1'b1;
    fifo_rdata_i       = '{data: 32'h2222_0001, mask: 4'hF};
    begin
      int wait_c = 0;
      @(posedge clk_i);
      while (!(fifo_rvalid_i && fifo_rready_o)) begin
        wait_c++;
        if (wait_c > 50) begin
          $display("FAIL: timeout waiting for fifo_rready_o on continue");
          $finish(1);
        end
        @(posedge clk_i);
      end
    end
    @(negedge clk_i);
    fifo_rvalid_i      = 1'b0;
    reg_hash_process_i = 1'b1;
    @(negedge clk_i);
    reg_hash_process_i = 1'b0;

    begin
      int wait_c = 0;
      while (shaf_words.size() < 16 && wait_c < 80) begin
        wait_c++;
        @(negedge clk_i);
      end
    end
    if (shaf_words.size() != 16 || shaf_words[0] !== 32'h2222_0001 || shaf_words[1] !== 32'h8000_0000 || shaf_words[15] !== 32'd1056) begin
      $display("FAIL: continue padding mismatch: size=%0d w0=%08h w1=%08h w15=%08h",
               shaf_words.size(), shaf_words.size() > 0 ? shaf_words[0] : 0,
               shaf_words.size() > 1 ? shaf_words[1] : 0,
               shaf_words.size() > 15 ? shaf_words[15] : 0);
      $finish(1);
    end
  endtask

  initial begin
    run_hmac_or_sha_test(1'b0, Key_256, 0,  SEED + 1);
    run_hmac_or_sha_test(1'b0, Key_256, 1,  SEED + 2);
    run_hmac_or_sha_test(1'b0, Key_256, 2,  SEED + 3);
    run_hmac_or_sha_test(1'b0, Key_256, 3,  SEED + 4);
    run_hmac_or_sha_test(1'b0, Key_256, 52, SEED + 5);
    run_hmac_or_sha_test(1'b0, Key_256, 55, SEED + 6);
    run_hmac_or_sha_test(1'b0, Key_256, 56, SEED + 7);
    run_hmac_or_sha_test(1'b0, Key_256, 64, SEED + 8);

    run_hmac_or_sha_test(1'b1, Key_128,  0,  SEED + 11);
    run_hmac_or_sha_test(1'b1, Key_256,  3,  SEED + 12);
    run_hmac_or_sha_test(1'b1, Key_384,  52, SEED + 13);
    run_hmac_or_sha_test(1'b1, Key_512,  56, SEED + 14);
    run_hmac_or_sha_test(1'b1, Key_512,  14, SEED + 15);

    test_abort_clears_process_flag();
    test_stop_and_continue();

    $display("PASS ot_hmac_pad_top seed=%0d", SEED);
    $finish(0);
  end
endmodule
