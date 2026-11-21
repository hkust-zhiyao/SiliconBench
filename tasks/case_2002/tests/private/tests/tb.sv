`timescale 1ns/1ps

module tb;
  import ibex_cheriot_pkg::*;
  import prim_secded_pkg::*;

  logic        clk_i = 0;
  always #5 clk_i = ~clk_i;

  logic        rst_ni = 0;
  logic        flush_i = 0;
  logic [31:0] heap_base_addr_i = 32'h2000_0000;

  logic        upstream_req_i = 0;
  wire         upstream_gnt_o;
  wire         upstream_rvalid_o;
  logic        upstream_rready_i = 0;
  logic        upstream_we_i = 0;
  logic [3:0]  upstream_be_i = 0;
  logic [31:0] upstream_addr_i = 0;
  logic [31:0] upstream_wdata_i = 0;
  logic [6:0]  upstream_wdata_intg_i = 0;
  wire  [31:0] upstream_rdata_o;
  wire  [6:0]  upstream_rdata_intg_o;
  wire         upstream_err_o;
  logic        upstream_tag_i = 0;
  wire         upstream_tag_o;

  wire         downstream_req_o;
  logic        downstream_gnt_i = 0;
  logic        downstream_rvalid_i = 0;
  wire         downstream_we_o;
  wire  [3:0]  downstream_be_o;
  wire  [31:0] downstream_addr_o;
  wire  [31:0] downstream_wdata_o;
  wire  [6:0]  downstream_wdata_intg_o;
  logic [31:0] downstream_rdata_i = 0;
  logic [6:0]  downstream_rdata_intg_i = 0;
  logic        downstream_err_i = 0;
  wire         downstream_tag_o;
  logic        downstream_tag_i = 0;

  wire         revbm_req_o;
  logic        revbm_gnt_i = 0;
  logic        revbm_rvalid_i = 0;
  wire  [31:0] revbm_addr_o;
  logic [31:0] revbm_rdata_i = 0;
  logic [6:0]  revbm_rdata_intg_i = 0;
  logic        revbm_err_i = 0;

  wire         revbm_data_intg_error_o;
  wire         revbm_device_error_o;

  logic [7:0]  alert_in = 0;
  wire  [7:0]  alert_out;
  logic [7:0]  trace_in = 0;
  wire  [7:0]  trace_out;

  ibex_trvk_bridge_top #(
    .NumOutstanding     ( 32'd4         ),
    .RevBitmapAddrWidth ( 32'd11        ),
    .RevBitmapBaseAddr  ( 32'h0001_0000 ),
    .MemECC             ( 1'b1          )
  ) dut (
    .clk_i,
    .rst_ni,
    .flush_i,
    .heap_base_addr_i,
    .upstream_req_i,
    .upstream_gnt_o,
    .upstream_rvalid_o,
    .upstream_rready_i,
    .upstream_we_i,
    .upstream_be_i,
    .upstream_addr_i,
    .upstream_wdata_i,
    .upstream_wdata_intg_i,
    .upstream_rdata_o,
    .upstream_rdata_intg_o,
    .upstream_err_o,
    .upstream_tag_i,
    .upstream_tag_o,
    .downstream_req_o,
    .downstream_gnt_i,
    .downstream_rvalid_i,
    .downstream_we_o,
    .downstream_be_o,
    .downstream_addr_o,
    .downstream_wdata_o,
    .downstream_wdata_intg_o,
    .downstream_rdata_i,
    .downstream_rdata_intg_i,
    .downstream_err_i,
    .downstream_tag_o,
    .downstream_tag_i,
    .revbm_req_o,
    .revbm_gnt_i,
    .revbm_rvalid_i,
    .revbm_addr_o,
    .revbm_rdata_i,
    .revbm_rdata_intg_i,
    .revbm_err_i,
    .revbm_data_intg_error_o,
    .revbm_device_error_o,
    .alert_in,
    .alert_out,
    .trace_in,
    .trace_out
  );

  // Helper to compute valid inv-Hamming 39-32 ECC checkbits
  function automatic logic [6:0] calc_ecc32(input logic [31:0] d);
    logic [38:0] cw;
    cw[31:0] = d;
    cw[32] = ^(cw[31:0] & 32'h2606BD25);
    cw[33] = ^(cw[31:0] & 32'hDEBA8050);
    cw[34] = ^(cw[31:0] & 32'h413D89AA);
    cw[35] = ^(cw[31:0] & 32'h31234ED1);
    cw[36] = ^(cw[31:0] & 32'hC2C1323B);
    cw[37] = ^(cw[31:0] & 32'h2DCC624C);
    cw[38] = ^(cw[31:0] & 32'h98505586);
    cw[38:32] ^= 7'h2A;
    return cw[38:32];
  endfunction

  // Build a capability metadata word (word 1) with cexp=0, otype=0, cperms=6'b111111 (non-sealing),
  // top=9'h100, and given 9-bit base.
  function automatic logic [31:0] make_cap_meta(input logic [8:0] base9, input logic [3:0] cexp, input logic [5:0] cperms);
    return {1'b0, cperms, 3'b000, cexp, 9'h100, base9};
  endfunction

  int unsigned error_count = 0;
  int unsigned total_checks = 0;
  int unsigned seed = 101;

  task automatic check_cond(input bit cond, input string msg);
    begin
      total_checks++;
      if (!cond) begin
        $display("TB_FAIL [t=%0t]: %s", $time, msg);
        error_count++;
      end
    end
  endtask

  task automatic clear_inputs();
    begin
      flush_i                 = 1'b0;
      upstream_req_i          = 1'b0;
      upstream_rready_i       = 1'b0;
      upstream_we_i           = 1'b0;
      upstream_be_i           = 4'h0;
      upstream_addr_i         = 32'h0;
      upstream_wdata_i        = 32'h0;
      upstream_wdata_intg_i   = 7'h0;
      upstream_tag_i          = 1'b0;
      downstream_gnt_i        = 1'b0;
      downstream_rvalid_i     = 1'b0;
      downstream_rdata_i      = 32'h0;
      downstream_rdata_intg_i = 7'h0;
      downstream_err_i        = 1'b0;
      downstream_tag_i        = 1'b0;
      revbm_gnt_i             = 1'b0;
      revbm_rvalid_i          = 1'b0;
      revbm_rdata_i           = 32'h0;
      revbm_rdata_intg_i      = 7'h0;
      revbm_err_i             = 1'b0;
    end
  endtask

  task automatic issue_two_cap_reqs(input logic [31:0] base_addr);
    begin
      // Beat 0: addr[2] == 0
      @(posedge clk_i); #1;
      upstream_req_i   = 1'b1;
      upstream_addr_i  = {base_addr[31:3], 3'b000};
      upstream_tag_i   = 1'b1;
      downstream_gnt_i = 1'b1;
      @(negedge clk_i);
      check_cond(upstream_gnt_o === 1'b1 && downstream_req_o === 1'b1, "Beat 0 req/gnt handshake failed");
      // Beat 1: addr[2] == 1
      @(posedge clk_i); #1;
      upstream_req_i   = 1'b1;
      upstream_addr_i  = {base_addr[31:3], 3'b100};
      upstream_tag_i   = 1'b1;
      downstream_gnt_i = 1'b1;
      @(negedge clk_i);
      check_cond(upstream_gnt_o === 1'b1 && downstream_req_o === 1'b1, "Beat 1 req/gnt handshake failed");
      @(posedge clk_i); #1;
      upstream_req_i   = 1'b0;
      downstream_gnt_i = 1'b0;
    end
  endtask

  initial begin
    void'($value$plusargs("SEED=%d", seed));
    clear_inputs();
    rst_ni = 1'b0;
    repeat (3) @(posedge clk_i);
    #1; rst_ni = 1'b1;
    @(negedge clk_i);

    // Check transparent channels
    alert_in = 8'hA5;
    trace_in = 8'h3C;
    #1;
    check_cond(alert_out === 8'hA5 && trace_out === 8'h3C, "Transparent channels mismatch");

    // =========================================================================
    // TEST 1: Upstream rready_i backpressure across Beat 0 (pointer) and Beat 1 (metadata + revbm)
    // =========================================================================
    begin
      logic [31:0] ptr_word, meta_word, bm_word;
      // Capability pointer = 0x2000_0048 (base9 = 9'h048 -> cap_base = 0x2000_0048, offset from heap_base = 0x48 = 72 bytes = bit 9 -> word 0, bit 9)
      ptr_word  = 32'h2000_0048;
      meta_word = make_cap_meta(9'h048, 4'd0, 6'b111111);
      bm_word   = 32'h0000_0000; // bit 9 is 0 (not revoked)

      issue_two_cap_reqs(32'h1000_0000);

      // Return Beat 0 (pointer) while upstream_rready_i = 0 for 2 cycles!
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = ptr_word;
      downstream_rdata_intg_i = calc_ecc32(ptr_word);
      downstream_tag_i        = 1'b1;
      upstream_rready_i       = 1'b0;
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_rdata_o === ptr_word && upstream_tag_o === 1'b1,
                 "Test 1: Beat 0 bypass while rready=0 failed");

      // Next cycle: downstream_rvalid_i=0, still upstream_rready_i=0 -> must hold Beat 0 in FIFO and NOT pop align FIFO!
      @(posedge clk_i); #1;
      downstream_rvalid_i = 1'b0;
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_rdata_o === ptr_word && upstream_tag_o === 1'b1,
                 "Test 1: Beat 0 stalled stability failed");

      // Now assert upstream_rready_i=1 to handshake Beat 0!
      @(posedge clk_i); #1;
      upstream_rready_i = 1'b1;
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_rdata_o === ptr_word, "Test 1: Beat 0 accept failed");

      // Now return Beat 1 (metadata) while upstream_rready_i=0:
      // Because ptr_storage_q was latched on Beat 0's handshake and align FIFO now presents misalign_flag_out=1,
      // revbm_req_o MUST assert!
      @(posedge clk_i); #1;
      upstream_rready_i       = 1'b0;
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = meta_word;
      downstream_rdata_intg_i = calc_ecc32(meta_word);
      downstream_tag_i        = 1'b1;
      revbm_gnt_i             = 1'b1;
      @(negedge clk_i);
      check_cond(revbm_req_o === 1'b1 && revbm_addr_o === 32'h0001_0000,
                 "Test 1: revbm_req_o failed after stalled Beat 0");
      check_cond(upstream_rvalid_o === 1'b0,
                 "Test 1: upstream_rvalid_o must wait for revbm_rvalid_i");

      // Next cycle: revbm_rvalid_i=1 arrives while upstream_rready_i=0!
      // revbm_rsp_ready is 0 because upstream_rready_i is 0, so revbm_outstanding_q MUST stay 1 (no duplicate revbm_req_o!).
      @(posedge clk_i); #1;
      downstream_rvalid_i = 1'b0;
      revbm_gnt_i         = 1'b0;
      revbm_rvalid_i      = 1'b1;
      revbm_rdata_i       = bm_word;
      revbm_rdata_intg_i  = calc_ecc32(bm_word);
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_tag_o === 1'b1 && revbm_req_o === 1'b0,
                 "Test 1: revbm_rvalid_i with rready=0 must present valid tag=1 and revbm_req_o=0");

      // Next cycle: assert upstream_rready_i=1 while revbm_rvalid_i=1 to complete Beat 1 handshake!
      @(posedge clk_i); #1;
      upstream_rready_i = 1'b1;
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_tag_o === 1'b1 && revbm_req_o === 1'b0,
                 "Test 1: Beat 1 completion handshake failed");
      @(posedge clk_i); #1;
      clear_inputs();
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b0 && revbm_req_o === 1'b0, "Test 1: post-completion idle check failed");
    end

    // =========================================================================
    // TEST 2: Revoked capability (bit set in bitmap) clears upstream_tag_o
    // =========================================================================
    begin
      logic [31:0] ptr_word, meta_word, bm_word;
      ptr_word  = 32'h2000_0120; // offset 0x120 = 288 bytes -> bit 36 -> word 1 (addr 0x0001_0004), bit 4
      meta_word = make_cap_meta(9'h120, 4'd0, 6'b111111);
      bm_word   = 32'h0000_0010; // bit 4 is 1 (REVOKED!)

      issue_two_cap_reqs(32'h1000_0010);

      // Beat 0 response with rready=1
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = ptr_word;
      downstream_rdata_intg_i = calc_ecc32(ptr_word);
      downstream_tag_i        = 1'b1;
      upstream_rready_i       = 1'b1;
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_tag_o === 1'b1, "Test 2: Beat 0 tag should stay 1");

      // Beat 1 response
      @(posedge clk_i); #1;
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = meta_word;
      downstream_rdata_intg_i = calc_ecc32(meta_word);
      downstream_tag_i        = 1'b1;
      revbm_gnt_i             = 1'b1;
      @(negedge clk_i);
      check_cond(revbm_req_o === 1'b1 && revbm_addr_o === 32'h0001_0004, "Test 2: revbm word 1 address mismatch");

      @(posedge clk_i); #1;
      downstream_rvalid_i = 1'b0;
      revbm_gnt_i         = 1'b0;
      revbm_rvalid_i      = 1'b1;
      revbm_rdata_i       = bm_word;
      revbm_rdata_intg_i  = calc_ecc32(bm_word);
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_tag_o === 1'b0,
                 "Test 2: revoked capability must clear upstream_tag_o to 0");
      @(posedge clk_i); #1;
      clear_inputs();
    end

    // =========================================================================
    // TEST 3: Unsigned underflow guard (cap_base < heap_base_addr_i) & cap_base_33[32]==1
    // =========================================================================
    begin
      logic [31:0] ptr_below, meta_below, ptr_neg, meta_neg;
      // Case 3A: cap_base = 0x1FFF_FFC0 < heap_base_addr_i (0x2000_0000).
      // Notice 0x1FFF_FFC0 - 0x2000_0000 = 0xFFFF_FFC0 (non-zero upper bits),
      // Wait: what if heap_base_addr_i = 0x2000_0000 and cap_base_33 has cap_base < heap_base_addr_i?
      // Wait: in 32-bit unsigned subtraction, if cap_base < heap_base_addr_i, cap_base - heap_base_addr_i wraps around to 0xFFFF_xxxx!
      // Wait: when does cap_base < heap_base_addr_i wrap around to a SMALL 32-bit number in revbm_cap_addr?
      // Wait: in 32-bit arithmetic, (cap_base - heap_base_addr_i) mod 2^32 is >= 2^32 - heap_base_addr_i!
      // If heap_base_addr_i = 0xFFFF_F000 and cap_base = 0x0000_0020 (below heap_base_addr_i!),
      // then 32-bit (cap_base - heap_base_addr_i) = 0x0000_0020 - 0xFFFF_F000 = 0x0000_1020, which is inside the 16KB bitmap window!
      heap_base_addr_i = 32'hFFFF_F000;
      ptr_below        = 32'h0000_0020;
      meta_below       = make_cap_meta(9'h020, 4'd0, 6'b111111);

      issue_two_cap_reqs(32'h1000_0020);

      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = ptr_below;
      downstream_rdata_intg_i = calc_ecc32(ptr_below);
      downstream_tag_i        = 1'b1;
      upstream_rready_i       = 1'b1;
      @(negedge clk_i);

      @(posedge clk_i); #1;
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = meta_below;
      downstream_rdata_intg_i = calc_ecc32(meta_below);
      downstream_tag_i        = 1'b1;
      @(negedge clk_i);
      check_cond(revbm_req_o === 1'b0 && upstream_rvalid_o === 1'b1 && upstream_tag_o === 1'b1,
                 "Test 3A: cap_base < heap_base_addr_i must NOT trigger revbm_req_o");

      @(posedge clk_i); #1;
      clear_inputs();
      heap_base_addr_i = 32'h0000_1000;

      // Case 3B: cap_base_33[32] == 1 (negative base correction on address near 0: addr=0x0000_0010, base=9'h180, exp=4 -> base_cor = -1 -> cap_base_33 = 33'h1_FFFF_F800)
      // Wait: if heap_base_addr_i = 0xFFFF_F000 and cap_base_33 = 33'h1_FFFF_F800 (due to -1 base correction wrapping below 0),
      // then cap_base_33[31:0] = 0xFFFF_F800 >= heap_base_addr_i (0xFFFF_F000), so without checking cap_base_33[32], it would falsely hit the bitmap!
      heap_base_addr_i = 32'hFFFF_F000;
      ptr_neg          = 32'h0000_0010; // addr_mid = 9'h001 < base (9'h180) -> base_cor = -1!
      meta_neg         = make_cap_meta(9'h180, 4'd4, 6'b111111); // exp=4: base33 = (0 - (1<<13)) | (0x180 << 4) = 33'h1_FFFF_F800!

      issue_two_cap_reqs(32'h1000_0030);

      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = ptr_neg;
      downstream_rdata_intg_i = calc_ecc32(ptr_neg);
      downstream_tag_i        = 1'b1;
      upstream_rready_i       = 1'b1;
      @(negedge clk_i);

      @(posedge clk_i); #1;
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = meta_neg;
      downstream_rdata_intg_i = calc_ecc32(meta_neg);
      downstream_tag_i        = 1'b1;
      @(negedge clk_i);
      check_cond(revbm_req_o === 1'b0 && upstream_rvalid_o === 1'b1 && upstream_tag_o === 1'b1,
                 "Test 3B: cap_base_33[32]==1 underflow must NOT trigger revbm_req_o");

      @(posedge clk_i); #1;
      clear_inputs();
      heap_base_addr_i = 32'h2000_0000;
    end

    // =========================================================================
    // TEST 4: Synchronous flush_i clears FIFOs, pointer state, and revbm_outstanding_q
    // =========================================================================
    begin
      logic [31:0] ptr_word, meta_word;
      ptr_word  = 32'h2000_0040;
      meta_word = make_cap_meta(9'h040, 4'd0, 6'b111111);

      issue_two_cap_reqs(32'h1000_0040);

      // Beat 0 handshakes
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = ptr_word;
      downstream_rdata_intg_i = calc_ecc32(ptr_word);
      downstream_tag_i        = 1'b1;
      upstream_rready_i       = 1'b1;
      @(negedge clk_i);

      // Beat 1 arrives and issues revbm_req_o (granted), but before revbm_rvalid_i arrives, assert flush_i=1!
      @(posedge clk_i); #1;
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = meta_word;
      downstream_rdata_intg_i = calc_ecc32(meta_word);
      downstream_tag_i        = 1'b1;
      revbm_gnt_i             = 1'b1;
      @(negedge clk_i);
      check_cond(revbm_req_o === 1'b1, "Test 4: revbm_req_o before flush expected");

      // Assert flush_i=1 on the next cycle while upstream_req_i=1
      @(posedge clk_i); #1;
      downstream_rvalid_i = 1'b0;
      revbm_gnt_i         = 1'b0;
      flush_i             = 1'b1;
      upstream_req_i      = 1'b1;
      downstream_gnt_i    = 1'b1;
      @(negedge clk_i);
      check_cond(upstream_gnt_o === 1'b0 && downstream_req_o === 1'b0 &&
                 upstream_rvalid_o === 1'b0 && revbm_req_o === 1'b0,
                 "Test 4: flush_i must suppress gnt/req/rvalid/revbm_req during flush cycle");

      // Deassert flush_i=0: FIFOs and ptr_storage_valid_q and revbm_outstanding_q must all be clean!
      @(posedge clk_i); #1;
      clear_inputs();
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b0 && revbm_req_o === 1'b0,
                 "Test 4: state must be empty after flush_i");

      // Also test mid-handshake flush on stream_fork:
      // Cycle A: upstream_req_i=1, downstream_gnt_i=0 -> align_fork handshakes (ready=1), downstream does not (ready=0), so stream_fork enters WAITING!
      @(posedge clk_i); #1;
      upstream_req_i   = 1'b1;
      upstream_addr_i  = 32'h1000_0040;
      upstream_tag_i   = 1'b1;
      downstream_gnt_i = 1'b0;
      @(negedge clk_i);
      check_cond(upstream_gnt_o === 1'b0 && downstream_req_o === 1'b1,
                 "Test 4B: ungranted upstream_req_i must assert downstream_req_o=1 and upstream_gnt_o=0");
      // Cycle B: assert flush_i=1 while stream_fork is in WAITING!
      @(posedge clk_i); #1;
      flush_i = 1'b1;
      @(negedge clk_i);
      // Cycle C: deassert flush_i=0 and issue a fresh Beat 0 request with addr[2]=1, then Beat 1 with addr[2]=0:
      // If stream_fork did not reset oup_state_q[1] on clr_i, align_fork_valid would stay 0 on the fresh request!
      @(posedge clk_i); #1;
      clear_inputs();
      // Fresh capability pair after mid-handshake flush:
      issue_two_cap_reqs(32'h1000_0050);
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = ptr_word;
      downstream_rdata_intg_i = calc_ecc32(ptr_word);
      downstream_tag_i        = 1'b1;
      upstream_rready_i       = 1'b1;
      @(negedge clk_i);
      @(posedge clk_i); #1;
      downstream_rvalid_i     = 1'b1;
      downstream_rdata_i      = meta_word;
      downstream_rdata_intg_i = calc_ecc32(meta_word);
      downstream_tag_i        = 1'b1;
      revbm_gnt_i             = 1'b1;
      @(negedge clk_i);
      check_cond(revbm_req_o === 1'b1 && revbm_addr_o === 32'h0001_0000,
                 "Test 4: post-flush capability must issue revbm_req_o cleanly");
      @(posedge clk_i); #1;
      downstream_rvalid_i = 1'b0;
      revbm_gnt_i         = 1'b0;
      revbm_rvalid_i      = 1'b1;
      revbm_rdata_i       = 32'h0;
      revbm_rdata_intg_i  = calc_ecc32(32'h0);
      @(negedge clk_i);
      check_cond(upstream_rvalid_o === 1'b1 && upstream_tag_o === 1'b1,
                 "Test 4: post-flush capability completion failed");
      @(posedge clk_i); #1;
      clear_inputs();
    end

    // =========================================================================
    // TEST 5: Randomized multi-transaction stress test
    // =========================================================================
    begin
      int unsigned rng;
      rng = seed ^ 32'h9E37_79B9;
      for (int unsigned iter = 0; iter < 20; iter++) begin
        logic [8:0]  b9;
        logic [31:0] ptr_w, meta_w, bm_w;
        bit          rev_bit, stall_b0, stall_b1;
        rng      = (rng * 32'd1664525) + 32'd1013904223;
        b9       = {rng[8:3], 3'b000};
        rev_bit  = rng[9];
        stall_b0 = rng[10];
        stall_b1 = rng[11];
        ptr_w    = 32'h2000_0000 | {23'h0, b9};
        meta_w   = make_cap_meta(b9, 4'd0, 6'b111111);
        bm_w     = rev_bit ? (32'h1 << (b9[7:3])) : 32'h0;

        issue_two_cap_reqs(32'h1000_0100 + iter * 8);

        // Beat 0
        downstream_rvalid_i     = 1'b1;
        downstream_rdata_i      = ptr_w;
        downstream_rdata_intg_i = calc_ecc32(ptr_w);
        downstream_tag_i        = 1'b1;
        upstream_rready_i       = ~stall_b0;
        @(negedge clk_i);
        if (stall_b0) begin
          @(posedge clk_i); #1;
          downstream_rvalid_i = 1'b0;
          upstream_rready_i   = 1'b1;
          @(negedge clk_i);
        end
        check_cond(upstream_rvalid_o === 1'b1 && upstream_rdata_o === ptr_w && upstream_tag_o === 1'b1,
                   "Test 5: random Beat 0 mismatch");

        // Beat 1
        @(posedge clk_i); #1;
        downstream_rvalid_i     = 1'b1;
        downstream_rdata_i      = meta_w;
        downstream_rdata_intg_i = calc_ecc32(meta_w);
        downstream_tag_i        = 1'b1;
        upstream_rready_i       = ~stall_b1;
        revbm_gnt_i             = 1'b1;
        @(negedge clk_i);
        check_cond(revbm_req_o === 1'b1, "Test 5: random Beat 1 revbm_req_o missing");

        @(posedge clk_i); #1;
        downstream_rvalid_i = 1'b0;
        revbm_gnt_i         = 1'b0;
        revbm_rvalid_i      = 1'b1;
        revbm_rdata_i       = bm_w;
        revbm_rdata_intg_i  = calc_ecc32(bm_w);
        @(negedge clk_i);
        check_cond(upstream_rvalid_o === 1'b1 && upstream_tag_o === (~rev_bit),
                   "Test 5: random Beat 1 revocation tag mismatch");
        if (stall_b1) begin
          @(posedge clk_i); #1;
          upstream_rready_i = 1'b1;
          @(negedge clk_i);
          check_cond(upstream_rvalid_o === 1'b1 && upstream_tag_o === (~rev_bit) && revbm_req_o === 1'b0,
                     "Test 5: random Beat 1 stalled accept mismatch");
        end
        @(posedge clk_i); #1;
        clear_inputs();
      end
    end

    if (error_count == 0 && total_checks >= 50) begin
      $display("TB_PASS [seed=%0d checks=%0d]", seed, total_checks);
      $finish(0);
    end else begin
      $display("TB_FAIL_SUMMARY [seed=%0d errors=%0d checks=%0d]", seed, error_count, total_checks);
      $finish(1);
    end
  end
endmodule
