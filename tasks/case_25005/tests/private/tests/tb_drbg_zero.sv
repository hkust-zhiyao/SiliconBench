// SPDX-License-Identifier: Apache-2.0
// Dedicated unit test verifying exact HMAC_tag == 0 rejection in hmac_drbg
// using a deterministic hmac_core protocol responder (compiled without hmac_core.sv).
`timescale 1ns/1ps

module hmac_core (
  input  logic         clk,
  input  logic         reset_n,
  input  logic         zeroize,
  input  logic         init_cmd,
  input  logic         next_cmd,
  input  logic         last_cmd,
  input  logic         mode_cmd,
  output logic         ready,
  output logic         tag_valid,
  input  logic [191:0] lfsr_seed,
  input  logic [511:0] key,
  input  logic [1023:0] block_msg,
  output logic [511:0] tag
);
  int busy_cnt;
  int last_call_idx;
  logic [1023:0] k3_observed_block;
  logic          saw_k3_after_zero;

  localparam logic [383:0] VALID_SCALAR =
    384'h0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF;

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n || zeroize) begin
      busy_cnt          <= 0;
      last_call_idx     <= 0;
      ready             <= 1'b1;
      tag_valid         <= 1'b0;
      tag               <= '0;
      k3_observed_block <= '0;
      saw_k3_after_zero <= 1'b0;
    end else begin
      if (ready && (init_cmd || next_cmd)) begin
        ready     <= 1'b0;
        tag_valid <= 1'b0;
        busy_cnt  <= 3;
        if (last_cmd) begin
          last_call_idx <= last_call_idx + 1;
          // Call 1: K11, Call 2: V1, Call 3: K21, Call 4: V2, Call 5: T_ST (candidate 0 -> returns 0!),
          // Call 6: K3_ST (rejection update -> block_msg[1023:640] MUST be V_reg == 384'h0, NOT V2!)
          if (last_call_idx == 5) begin
            k3_observed_block <= block_msg;
            saw_k3_after_zero <= 1'b1;
          end
        end
      end else if (!ready) begin
        if (busy_cnt > 1) begin
          busy_cnt <= busy_cnt - 1;
        end else begin
          busy_cnt  <= 0;
          ready     <= 1'b1;
          tag_valid <= 1'b1;
          // Call 8 is second T_ST candidate after K3(6) and V3(7)
          if (last_call_idx == 5) begin
            tag <= 512'h0;
          end else if (last_call_idx == 8) begin
            if (!saw_k3_after_zero || k3_observed_block[1023:640] != 384'h0) begin
              $display("[FAIL] K3 rejection round did not hash V==0 after zero candidate! top384=%096x",
                       k3_observed_block[1023:640]);
              $fatal(1, "V not updated on zero rejection");
            end
            tag <= {VALID_SCALAR, 128'h0};
          end else begin
            tag <= {384'hA5A5A5A5_11112222_33334444 + 384'(last_call_idx), 128'h0};
          end
        end
      end
    end
  end
endmodule

module tb_drbg_zero;
  logic         clk = 1'b0;
  always #5 clk = ~clk;

  logic         reset_n;
  logic         zeroize;
  logic         init_cmd, next_cmd;
  wire          ready, valid;
  logic [191:0] lfsr_seed;
  logic [383:0] entropy, nonce;
  wire  [383:0] drbg;

  localparam logic [383:0] EXPECTED_AFTER_ZERO_REJECT =
    384'h0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF;

  hmac_drbg dut (
    .clk(clk), .reset_n(reset_n), .zeroize(zeroize),
    .init_cmd(init_cmd), .next_cmd(next_cmd),
    .ready(ready), .valid(valid),
    .lfsr_seed(lfsr_seed), .entropy(entropy), .nonce(nonce),
    .drbg(drbg)
  );

  initial begin
    int cyc = 0;
    reset_n   = 1'b0;
    zeroize   = 1'b0;
    init_cmd  = 1'b0;
    next_cmd  = 1'b0;
    lfsr_seed = 192'h1234;
    entropy   = 384'hCAFE_BABE;
    nonce     = 384'hFEED_FACE;

    repeat (4) @(posedge clk);
    reset_n = 1'b1;
    repeat (3) @(posedge clk);

    init_cmd = 1'b1;
    @(posedge clk);
    init_cmd = 1'b0;

    while (!valid && cyc < 300) begin
      if (valid && drbg == 384'h0) begin
        $display("[FAIL] DRBG accepted zero scalar candidate!");
        $fatal(1, "Zero scalar accepted");
      end
      @(posedge clk);
      cyc++;
    end

    if (!valid || drbg != EXPECTED_AFTER_ZERO_REJECT) begin
      $display("[FAIL] Zero-candidate rejection failed: valid=%0b drbg=%096x", valid, drbg);
      $fatal(1, "Zero rejection mismatch");
    end

    $display("ZERO_SCALAR_REJECTION_PASSED");
    $finish;
  end
endmodule
