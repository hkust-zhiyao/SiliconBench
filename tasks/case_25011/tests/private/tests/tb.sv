`timescale 1ns / 1ps

module tb;
  import sha512_masked_defines_pkg::*;

  logic          clk = 1'b0;
  always #5 clk = ~clk;

  logic          reset_n;
  logic          zeroize_a, zeroize_b, zeroize_c;
  logic          init_a, init_b, init_c;
  logic          next_a, next_b, next_c;
  logic [1:0]    mode_a, mode_b, mode_c;
  logic [191:0]  ent_a, ent_b, ent_c;
  logic [1023:0] msg_a, msg_b, msg_c;

  wire           ready_a, ready_b, ready_c;
  wire [511:0]   digest_a, digest_b, digest_c;
  wire           dvalid_a, dvalid_b, dvalid_c;

  sha512_masked_core u_dut_a (
    .clk          (clk),
    .reset_n      (reset_n),
    .zeroize      (zeroize_a),
    .init_cmd     (init_a),
    .next_cmd     (next_a),
    .mode         (mode_a),
    .entropy      (ent_a),
    .block_msg    (msg_a),
    .ready        (ready_a),
    .digest       (digest_a),
    .digest_valid (dvalid_a)
  );

  sha512_masked_core u_dut_b (
    .clk          (clk),
    .reset_n      (reset_n),
    .zeroize      (zeroize_b),
    .init_cmd     (init_b),
    .next_cmd     (next_b),
    .mode         (mode_b),
    .entropy      (ent_b),
    .block_msg    (msg_b),
    .ready        (ready_b),
    .digest       (digest_b),
    .digest_valid (dvalid_b)
  );

  sha512_masked_core u_dut_c (
    .clk          (clk),
    .reset_n      (reset_n),
    .zeroize      (zeroize_c),
    .init_cmd     (init_c),
    .next_cmd     (next_c),
    .mode         (mode_c),
    .entropy      (ent_c),
    .block_msg    (msg_c),
    .ready        (ready_c),
    .digest       (digest_c),
    .digest_valid (dvalid_c)
  );

  //----------------------------------------------------------------
  // FIPS 180-4 Golden Unmasked Reference Model
  //----------------------------------------------------------------
  localparam logic [63:0] K_TBL [0:79] = '{
    64'h428a2f98d728ae22, 64'h7137449123ef65cd, 64'hb5c0fbcfec4d3b2f, 64'he9b5dba58189dbbc,
    64'h3956c25bf348b538, 64'h59f111f1b605d019, 64'h923f82a4af194f9b, 64'hab1c5ed5da6d8118,
    64'hd807aa98a3030242, 64'h12835b0145706fbe, 64'h243185be4ee4b28c, 64'h550c7dc3d5ffb4e2,
    64'h72be5d74f27b896f, 64'h80deb1fe3b1696b1, 64'h9bdc06a725c71235, 64'hc19bf174cf692694,
    64'he49b69c19ef14ad2, 64'hefbe4786384f25e3, 64'h0fc19dc68b8cd5b5, 64'h240ca1cc77ac9c65,
    64'h2de92c6f592b0275, 64'h4a7484aa6ea6e483, 64'h5cb0a9dcbd41fbd4, 64'h76f988da831153b5,
    64'h983e5152ee66dfab, 64'ha831c66d2db43210, 64'hb00327c898fb213f, 64'hbf597fc7beef0ee4,
    64'hc6e00bf33da88fc2, 64'hd5a79147930aa725, 64'h06ca6351e003826f, 64'h142929670a0e6e70,
    64'h27b70a8546d22ffc, 64'h2e1b21385c26c926, 64'h4d2c6dfc5ac42aed, 64'h53380d139d95b3df,
    64'h650a73548baf63de, 64'h766a0abb3c77b2a8, 64'h81c2c92e47edaee6, 64'h92722c851482353b,
    64'ha2bfe8a14cf10364, 64'ha81a664bbc423001, 64'hc24b8b70d0f89791, 64'hc76c51a30654be30,
    64'hd192e819d6ef5218, 64'hd69906245565a910, 64'hf40e35855771202a, 64'h106aa07032bbd1b8,
    64'h19a4c116b8d2d0c8, 64'h1e376c085141ab53, 64'h2748774cdf8eeb99, 64'h34b0bcb5e19b48a8,
    64'h391c0cb3c5c95a63, 64'h4ed8aa4ae3418acb, 64'h5b9cca4f7763e373, 64'h682e6ff3d6b2b8a3,
    64'h748f82ee5defb2fc, 64'h78a5636f43172f60, 64'h84c87814a1f0ab72, 64'h8cc702081a6439ec,
    64'h90befffa23631e28, 64'ha4506cebde82bde9, 64'hbef9a3f7b2c67915, 64'hc67178f2e372532b,
    64'hca273eceea26619c, 64'hd186b8c721c0c207, 64'heada7dd6cde0eb1e, 64'hf57d4f7fee6ed178,
    64'h06f067aa72176fba, 64'h0a637dc5a2c898a6, 64'h113f9804bef90dae, 64'h1b710b35131c471b,
    64'h28db77f523047d84, 64'h32caab7b40c72493, 64'h3c9ebe0a15c9bebc, 64'h431d67c49c100d4c,
    64'h4cc5d4becb3e42b6, 64'h597f299cfc657e2a, 64'h5fcb6fab3ad6faec, 64'h6c44198c4a475817
  };

  function automatic logic [63:0] ref_rotr(input logic [63:0] x, input int n);
    return (x >> n) | (x << (64 - n));
  endfunction

  function automatic void ref_init_iv(input logic [1:0] m, output logic [63:0] h [0:7]);
    unique case (m)
      2'h0: begin
        h[0] = 64'h8c3d37c819544da2; h[1] = 64'h73e1996689dcd4d6;
        h[2] = 64'h1dfab7ae32ff9c82; h[3] = 64'h679dd514582f9fcf;
        h[4] = 64'h0f6d2b697bd44da8; h[5] = 64'h77e36f7304c48942;
        h[6] = 64'h3f9d85a86a1d36c8; h[7] = 64'h1112e6ad91d692a1;
      end
      2'h1: begin
        h[0] = 64'h22312194fc2bf72c; h[1] = 64'h9f555fa3c84c64c2;
        h[2] = 64'h2393b86b6f53b151; h[3] = 64'h963877195940eabd;
        h[4] = 64'h96283ee2a88effe3; h[5] = 64'hbe5e1e2553863992;
        h[6] = 64'h2b0199fc2c85b8aa; h[7] = 64'h0eb72ddc81c52ca2;
      end
      2'h2: begin
        h[0] = 64'hcbbb9d5dc1059ed8; h[1] = 64'h629a292a367cd507;
        h[2] = 64'h9159015a3070dd17; h[3] = 64'h152fecd8f70e5939;
        h[4] = 64'h67332667ffc00b31; h[5] = 64'h8eb44a8768581511;
        h[6] = 64'hdb0c2e0d64f98fa7; h[7] = 64'h47b5481dbefa4fa4;
      end
      default: begin
        h[0] = 64'h6a09e667f3bcc908; h[1] = 64'hbb67ae8584caa73b;
        h[2] = 64'h3c6ef372fe94f82b; h[3] = 64'ha54ff53a5f1d36f1;
        h[4] = 64'h510e527fade682d1; h[5] = 64'h9b05688c2b3e6c1f;
        h[6] = 64'h1f83d9abfb41bd6b; h[7] = 64'h5be0cd19137e2179;
      end
    endcase
  endfunction

  function automatic void ref_compress(input logic [1023:0] blk, inout logic [63:0] h [0:7]);
    logic [63:0] w [0:79];
    logic [63:0] a, b, c, d, e, f, g, hh, t1, t2, s0, s1, ch, maj;
    for (int t = 0; t < 16; t++)
      w[t] = blk[(15 - t) * 64 +: 64];
    for (int t = 16; t < 80; t++) begin
      s0 = ref_rotr(w[t - 15], 1) ^ ref_rotr(w[t - 15], 8) ^ (w[t - 15] >> 7);
      s1 = ref_rotr(w[t - 2], 19) ^ ref_rotr(w[t - 2], 61) ^ (w[t - 2] >> 6);
      w[t] = w[t - 16] + s0 + w[t - 7] + s1;
    end
    a = h[0]; b = h[1]; c = h[2]; d = h[3];
    e = h[4]; f = h[5]; g = h[6]; hh = h[7];
    for (int t = 0; t < 80; t++) begin
      s1  = ref_rotr(e, 14) ^ ref_rotr(e, 18) ^ ref_rotr(e, 41);
      ch  = (e & f) ^ ((~e) & g);
      t1  = hh + s1 + ch + K_TBL[t] + w[t];
      s0  = ref_rotr(a, 28) ^ ref_rotr(a, 34) ^ ref_rotr(a, 39);
      maj = (a & b) ^ (a & c) ^ (b & c);
      t2  = s0 + maj;
      hh = g; g = f; f = e; e = d + t1;
      d = c; c = b; b = a; a = t1 + t2;
    end
    h[0] += a; h[1] += b; h[2] += c; h[3] += d;
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  endfunction

  function automatic logic [511:0] ref_format_digest(input logic [1:0] m, input logic [63:0] h [0:7]);
    unique case (m)
      2'h0:    return {h[0], h[1], h[2], h[3][63:32], 288'h0};
      2'h1:    return {h[0], h[1], h[2], h[3], 256'h0};
      2'h2:    return {h[0], h[1], h[2], h[3], h[4], h[5], 128'h0};
      default: return {h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]};
    endcase
  endfunction

  //----------------------------------------------------------------
  // PRNG & Failure Reporting
  //----------------------------------------------------------------
  int unsigned seed = 101;
  logic [63:0] prng_state;
  int err_cnt = 0;

  function automatic logic [63:0] next_u64();
    logic [63:0] x;
    x = prng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    prng_state = x;
    return x * 64'h2545F4914F6CDD1D;
  endfunction

  function automatic logic [191:0] next_u192();
    logic [63:0] w0, w1, w2;
    w0 = next_u64();
    w1 = next_u64();
    w2 = next_u64();
    if ({w2, w1, w0} == 192'h0) w0 = 64'h1;
    return {w2, w1, w0};
  endfunction

  function automatic logic [1023:0] next_u1024();
    logic [1023:0] m;
    for (int i = 0; i < 16; i++)
      m[i * 64 +: 64] = next_u64();
    return m;
  endfunction

  task automatic fail_now(input string msg);
    $display("TB_FAIL: %s (time=%0t)", msg, $time);
    err_cnt++;
    $finish(1);
  endtask

  //----------------------------------------------------------------
  // Continuous Digest Output Gating Monitor
  //----------------------------------------------------------------
  always @(posedge clk) begin
    if (reset_n) begin
      if (!dvalid_a && (digest_a !== 512'h0))
        fail_now($sformatf("u_dut_a exposed non-zero digest while digest_valid==0: %h", digest_a));
      if (!dvalid_b && (digest_b !== 512'h0))
        fail_now($sformatf("u_dut_b exposed non-zero digest while digest_valid==0: %h", digest_b));
      if (!dvalid_c && (digest_c !== 512'h0))
        fail_now($sformatf("u_dut_c exposed non-zero digest while digest_valid==0: %h", digest_c));
    end
  end

  //----------------------------------------------------------------
  // Background Entropy Stream Control for Instance A
  //----------------------------------------------------------------
  int ent_profile_a = 4; // 0=zero, 1=all1, 2=corr_R, 3=alt, 4=prng
  logic [63:0] corr_word_a = 64'hCAFE_BABE_1357_9BDF;
  bit toggle_alt = 1'b0;

  always @(negedge clk) begin
    toggle_alt <= ~toggle_alt;
    unique case (ent_profile_a)
      0: ent_a <= 192'h0;
      1: ent_a <= {3{64'hFFFF_FFFF_FFFF_FFFF}};
      2: ent_a <= {3{corr_word_a}};
      3: ent_a <= toggle_alt ? {3{64'hAAAA_5555_AAAA_5555}} : {3{64'h5555_AAAA_5555_AAAA}};
      default: ent_a <= next_u192();
    endcase
  end

  task automatic hw_reset();
    reset_n   = 1'b0;
    zeroize_a = 1'b0; zeroize_b = 1'b0; zeroize_c = 1'b0;
    init_a    = 1'b0; init_b    = 1'b0; init_c    = 1'b0;
    next_a    = 1'b0; next_b    = 1'b0; next_c    = 1'b0;
    mode_a    = 2'h3; mode_b    = 2'h3; mode_c    = 2'h3;
    ent_b     = 192'h0; ent_c   = 192'h0;
    msg_a     = '0;   msg_b     = '0;   msg_c     = '0;
    repeat (3) @(posedge clk);
    #1;
    reset_n = 1'b1;
    @(posedge clk);
    #1;
    if (!ready_a || dvalid_a || (digest_a !== 512'h0))
      fail_now("Post-reset ready/digest_valid/digest mismatch");
  endtask

  task automatic run_block_a(
    input bit            is_init,
    input logic [1:0]    m,
    input logic [1023:0] blk,
    input bit            scramble_bus
  );
    int cyc;
    if (!ready_a)
      fail_now("Expected ready_a == 1 before issuing block command");

    @(negedge clk);
    init_a = is_init;
    next_a = ~is_init;
    mode_a = m;
    msg_a  = blk;

    @(posedge clk); // Command handshake edge!
    #1;
    if (ready_a !== 1'b0)
      fail_now("ready_a did not deassert after valid handshake");
    if (dvalid_a !== 1'b0)
      fail_now("digest_valid did not clear on valid handshake");

    @(negedge clk);
    init_a = 1'b0;
    next_a = 1'b0;
    if (scramble_bus) begin
      msg_a  = ~blk ^ {16{64'hDEAD_BEEF_CAFE_F00D}};
      mode_a = ~m;
      init_a = 1'b1; // Spurious pulses while busy must be ignored
      next_a = 1'b1;
    end

    cyc = 1;
    while (!ready_a) begin
      @(negedge clk);
      if (scramble_bus && (cyc == 3)) begin
        init_a = 1'b0;
        next_a = 1'b0;
      end
      @(posedge clk);
      #1;
      cyc++;
      if (cyc > 120)
        fail_now("Block execution exceeded 120-cycle timeout");
    end

    @(negedge clk);
    init_a = 1'b0;
    next_a = 1'b0;
    if (dvalid_a !== 1'b1)
      fail_now("digest_valid not asserted when ready_a returned high");
  endtask

  //----------------------------------------------------------------
  // Helper: Check all shares cleared to 0
  //----------------------------------------------------------------
  task automatic check_all_zeroed_a(input string tag);
    if (ready_a !== 1'b1 || dvalid_a !== 1'b0 || digest_a !== 512'h0)
      fail_now($sformatf("[%s] zeroize control outputs wrong: ready=%b dvalid=%b", tag, ready_a, dvalid_a));
    if (u_dut_a.a_reg !== 128'h0 || u_dut_a.b_reg !== 128'h0 ||
        u_dut_a.c_reg !== 128'h0 || u_dut_a.d_reg !== 128'h0 ||
        u_dut_a.e_reg !== 128'h0 || u_dut_a.f_reg !== 128'h0 ||
        u_dut_a.g_reg !== 128'h0 || u_dut_a.h_reg !== 128'h0)
      fail_now($sformatf("[%s] working state shares a_reg..h_reg not wiped on zeroize", tag));
    for (int k = 0; k < 16; k++) begin
      if (u_dut_a.w_mem_inst.w_mem[k] !== 128'h0)
        fail_now($sformatf("[%s] w_mem[%0d] not wiped on zeroize: %h", tag, k, u_dut_a.w_mem_inst.w_mem[k]));
    end
  endtask

  //----------------------------------------------------------------
  // Lockstep 3-Instance Side-Channel Share Integrity & Refresh Test
  //----------------------------------------------------------------
  task automatic run_lockstep_share_check(
    input bit zero_init_phase,
    input bit const_round_mask
  );
    logic [1023:0] m0, m1, m0_b2, m1_b2;
    logic [63:0]   h0_ref [0:7], h1_ref [0:7];
    logic [511:0]  exp0, exp1;
    masked_reg_t   prev_st_a [0:7];
    masked_reg_t   prev_w_a  [0:15];
    logic [63:0]   prev_arch_a, cur_arch_a, cur_arch_b;
    int            active_rounds;
    int            cyc;

    m0    = next_u1024();
    m1    = next_u1024();
    if (m0 == m1) m1 ^= 1024'h1;
    m0_b2 = next_u1024();
    m1_b2 = next_u1024();

    ref_init_iv(2'h3, h0_ref);
    ref_compress(m0, h0_ref);
    exp0 = ref_format_digest(2'h3, h0_ref);

    ref_init_iv(2'h3, h1_ref);
    ref_compress(m1, h1_ref);
    exp1 = ref_format_digest(2'h3, h1_ref);

    hw_reset();

    // Handshake cycle across all 3 lockstep instances:
    // A = (m0, ent_A), B = (m0, ent_B), C = (m1, ent_A)
    @(negedge clk);
    init_a = 1'b1; next_a = 1'b0; mode_a = 2'h3; msg_a = m0;
    init_b = 1'b1; next_b = 1'b0; mode_b = 2'h3; msg_b = m0;
    init_c = 1'b1; next_c = 1'b0; mode_c = 2'h3; msg_c = m1;

    if (zero_init_phase) begin
      ent_profile_a = 0;
      ent_b = 192'h0;
      ent_c = 192'h0;
    end
    else begin
      ent_profile_a = 4;
      ent_b = next_u192();
      ent_c = ent_a;
    end
    #1;
    if (!zero_init_phase) ent_c = ent_a;

    @(posedge clk); // Handshake edge
    #1;

    // Scramble block_msg immediately on all 3 instances so plaintext cannot be re-sampled!
    @(negedge clk);
    init_a = 1'b0; init_b = 1'b0; init_c = 1'b0;
    msg_a  = 1024'h0; msg_b = 1024'h0; msg_c = 1024'h0;

    if (!zero_init_phase) begin
      // Immediately 1 cycle after handshake, w_mem[0:15] must hold m0 masked with non-zero masks!
      for (int k = 0; k < 16; k++) begin
        logic [63:0] wa_plain, wb_plain;
        wa_plain = u_dut_a.w_mem_inst.w_mem[k].masked ^ u_dut_a.w_mem_inst.w_mem[k].random;
        wb_plain = u_dut_b.w_mem_inst.w_mem[k].masked ^ u_dut_b.w_mem_inst.w_mem[k].random;
        if (wa_plain !== wb_plain)
          fail_now($sformatf("Post-handshake w_mem[%0d] unmasked mismatch A vs B", k));
        if (u_dut_a.w_mem_inst.w_mem[k].random === 64'h0 || u_dut_b.w_mem_inst.w_mem[k].random === 64'h0)
          fail_now($sformatf("Post-handshake w_mem[%0d] stored unmasked (random==0)!", k));
        if (u_dut_a.w_mem_inst.w_mem[k].masked === u_dut_b.w_mem_inst.w_mem[k].masked)
          fail_now($sformatf("Post-handshake w_mem[%0d] identical across independent mask streams!", k));
      end
    end

    active_rounds = 0;
    cyc = 0;
    prev_arch_a = u_dut_a.a_reg.masked ^ u_dut_a.a_reg.random;
    prev_st_a[0] = u_dut_a.a_reg; prev_st_a[1] = u_dut_a.b_reg;
    prev_st_a[2] = u_dut_a.c_reg; prev_st_a[3] = u_dut_a.d_reg;
    prev_st_a[4] = u_dut_a.e_reg; prev_st_a[5] = u_dut_a.f_reg;
    prev_st_a[6] = u_dut_a.g_reg; prev_st_a[7] = u_dut_a.h_reg;
    for (int k = 0; k < 16; k++) prev_w_a[k] = u_dut_a.w_mem_inst.w_mem[k];

    while (!ready_a) begin
      @(negedge clk);
      if (zero_init_phase) begin
        // Keep entropy 0 until state_init has loaded H0 (detected when a_reg plain == H0_0),
        // then turn on non-zero entropy during compression rounds!
        if ((u_dut_a.a_reg.masked ^ u_dut_a.a_reg.random) == 64'h6a09e667f3bcc908 || active_rounds > 0) begin
          if (const_round_mask) begin
            logic [63:0] ra_corr, rb_corr;
            ra_corr = next_u64() | 64'h1;
            rb_corr = next_u64() | 64'h2;
            if (ra_corr == rb_corr) rb_corr ^= 64'h4;
            corr_word_a   = ra_corr;
            ent_profile_a = 2;
            ent_b         = {3{rb_corr}};
          end
          else begin
            ent_profile_a = 4;
            ent_b = next_u192();
          end
        end
        else begin
          ent_profile_a = 0;
          ent_b = 192'h0;
        end
      end
      else begin
        ent_b = next_u192();
      end
      #1;
      ent_c = ent_a;

      @(posedge clk);
      #1;
      cyc++;
      if (cyc > 120)
        fail_now("Lockstep block exceeded 120 cycles");

      cur_arch_a = u_dut_a.a_reg.masked ^ u_dut_a.a_reg.random;
      cur_arch_b = u_dut_b.a_reg.masked ^ u_dut_b.a_reg.random;
      if (cur_arch_a !== cur_arch_b)
        fail_now($sformatf("Round cycle %0d architectural a_reg diverged between mask streams A and B!", cyc));

      // Once compression rounds are running (cur_arch_a stepped past IV 6a09e667f3bcc908 while still !ready_a):
      if (!ready_a && (cur_arch_a !== 64'h0) && (cur_arch_a !== 64'h6a09e667f3bcc908)) begin
        masked_reg_t cur_st_a [0:7], cur_st_b [0:7];
        active_rounds++;
        cur_st_a[0] = u_dut_a.a_reg; cur_st_a[1] = u_dut_a.b_reg;
        cur_st_a[2] = u_dut_a.c_reg; cur_st_a[3] = u_dut_a.d_reg;
        cur_st_a[4] = u_dut_a.e_reg; cur_st_a[5] = u_dut_a.f_reg;
        cur_st_a[6] = u_dut_a.g_reg; cur_st_a[7] = u_dut_a.h_reg;

        cur_st_b[0] = u_dut_b.a_reg; cur_st_b[1] = u_dut_b.b_reg;
        cur_st_b[2] = u_dut_b.c_reg; cur_st_b[3] = u_dut_b.d_reg;
        cur_st_b[4] = u_dut_b.e_reg; cur_st_b[5] = u_dut_b.f_reg;
        cur_st_b[6] = u_dut_b.g_reg; cur_st_b[7] = u_dut_b.h_reg;

        for (int s = 0; s < 8; s++) begin
          if ((cur_st_a[s].masked ^ cur_st_a[s].random) !== (cur_st_b[s].masked ^ cur_st_b[s].random))
            fail_now($sformatf("State[%0d] share XOR mismatch at round %0d", s, active_rounds));
          if (cur_st_a[s].random === 64'h0 || cur_st_b[s].random === 64'h0)
            fail_now($sformatf("State[%0d] has zero mask (.random==0) at round %0d (zero_init=%0b const=%0b)!",
                               s, active_rounds, zero_init_phase, const_round_mask));
          if (cur_st_a[s].masked === cur_st_b[s].masked)
            fail_now($sformatf("State[%0d].masked collided across independent mask streams at round %0d!", s, active_rounds));
        end

        for (int k = 0; k < 16; k++) begin
          if (u_dut_a.w_mem_inst.w_mem[k].random === 64'h0 || u_dut_b.w_mem_inst.w_mem[k].random === 64'h0)
            fail_now($sformatf("w_mem[%0d] has zero mask (.random==0) at round %0d (zero_init=%0b const=%0b)!",
                               k, active_rounds, zero_init_phase, const_round_mask));
          if (u_dut_a.w_mem_inst.w_mem[k].masked === u_dut_b.w_mem_inst.w_mem[k].masked)
            fail_now($sformatf("w_mem[%0d].masked collided across independent mask streams at round %0d!", k, active_rounds));
        end

        if (!const_round_mask && active_rounds >= 2) begin
          // Verify shift stages refreshed masks rather than copying raw (masked, random) pairs!
          if (cur_st_a[1] === prev_st_a[0] || cur_st_a[2] === prev_st_a[1] || cur_st_a[3] === prev_st_a[2] ||
              cur_st_a[5] === prev_st_a[4] || cur_st_a[6] === prev_st_a[5] || cur_st_a[7] === prev_st_a[6])
            fail_now($sformatf("Unrefreshed working-state shift register pair detected at round %0d!", active_rounds));

          for (int k = 0; k < 16; k++) begin
            if (u_dut_a.w_mem_inst.w_mem[k] === prev_w_a[k])
              fail_now($sformatf("w_mem[%0d] was not refreshed in-place during round %0d!", k, active_rounds));
            if (k < 15 && u_dut_a.w_mem_inst.w_mem[k] === prev_w_a[k + 1])
              fail_now($sformatf("w_mem[%0d] shifted unrefreshed share pair from w_mem[%0d] at round %0d!", k, k + 1, active_rounds));
          end
        end
      end

      prev_arch_a  = cur_arch_a;
      prev_st_a[0] = u_dut_a.a_reg; prev_st_a[1] = u_dut_a.b_reg;
      prev_st_a[2] = u_dut_a.c_reg; prev_st_a[3] = u_dut_a.d_reg;
      prev_st_a[4] = u_dut_a.e_reg; prev_st_a[5] = u_dut_a.f_reg;
      prev_st_a[6] = u_dut_a.g_reg; prev_st_a[7] = u_dut_a.h_reg;
      for (int k = 0; k < 16; k++) prev_w_a[k] = u_dut_a.w_mem_inst.w_mem[k];
    end

    if (active_rounds < 78)
      fail_now($sformatf("Too few active masked rounds observed (%0d)", active_rounds));
    if (digest_a !== exp0 || digest_b !== exp0)
      fail_now($sformatf("Lockstep digest mismatch on M0: got A=%h B=%h exp=%h", digest_a, digest_b, exp0));
    if (digest_c !== exp1)
      fail_now($sformatf("Lockstep digest mismatch on M1: got C=%h exp=%h", digest_c, exp1));
  endtask

  //----------------------------------------------------------------
  // Main Verification Sequence
  //----------------------------------------------------------------
  initial begin
    logic [1023:0] abc_blk;
    logic [1023:0] two_blk0, two_blk1;
    logic [63:0]   href [0:7];
    logic [511:0]  exp_dig;

    if ($value$plusargs("SEED=%d", seed)) begin end
    prng_state = {32'h9E37_79B9 ^ seed, 32'h7F4A_7C15 ^ (seed * 32'd1664525 + 32'd1013904223)};
    if (prng_state == 64'h0) prng_state = 64'h1;

    // Construct FIPS 180-4 "abc" 1024-bit padded block
    abc_blk = {24'h616263, 1'b1, 871'h0, 128'd24};

    // Self-check reference model against NIST SHA-512("abc") and SHA-384("abc")
    ref_init_iv(2'h3, href);
    ref_compress(abc_blk, href);
    if (ref_format_digest(2'h3, href) !== 512'hddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f)
      fail_now("Internal reference model SHA-512('abc') self-check failed");

    ref_init_iv(2'h2, href);
    ref_compress(abc_blk, href);
    if (ref_format_digest(2'h2, href) !== {384'hcb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7, 128'h0})
      fail_now("Internal reference model SHA-384('abc') self-check failed");

    // NIST 2-block 152-byte message:
    // "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
    two_blk0 = {
      "abcdefgh", "bcdefghi", "cdefghij", "defghijk",
      "efghijkl", "fghijklm", "ghijklmn", "hijklmno",
      "ijklmnop", "jklmnopq", "klmnopqr", "lmnopqrs",
      "mnopqrst", "nopqrstu"
    }; // Wait: 14*8 = 112 bytes; 152 bytes = 19 * 8 bytes! Construct exact 112-byte 2-block message (len=896 bits >= 896 -> 2 blocks!):
    two_blk0 = {
      64'h6162636465666768, 64'h6263646566676869, 64'h636465666768696a, 64'h6465666768696a6b,
      64'h65666768696a6b6c, 64'h666768696a6b6c6d, 64'h6768696a6b6c6d6e, 64'h68696a6b6c6d6e6f,
      64'h696a6b6c6d6e6f70, 64'h6a6b6c6d6e6f7071, 64'h6b6c6d6e6f707172, 64'h6c6d6e6f70717273,
      64'h6d6e6f7071727374, 64'h6e6f707172737475, 64'h8000000000000000, 64'h0000000000000000
    };
    two_blk1 = {896'h0, 128'd896};

    //----------------------------------------------------------------
    // 1. KAT & Multi-Mode / Multi-Entropy / Bus-Scrubbing Suite
    //----------------------------------------------------------------
    hw_reset();
    for (int prof = 0; prof < 5; prof++) begin
      ent_profile_a = prof;
      corr_word_a   = next_u64() | 64'h1;
      for (int m = 0; m < 4; m++) begin
        // Single-block "abc" with bus scrambling
        ref_init_iv(m[1:0], href);
        ref_compress(abc_blk, href);
        exp_dig = ref_format_digest(m[1:0], href);
        run_block_a(1'b1, m[1:0], abc_blk, 1'b1);
        if (digest_a !== exp_dig)
          fail_now($sformatf("Single-block KAT mismatch prof=%0d mode=%0d: got=%h exp=%h", prof, m, digest_a, exp_dig));

        // Multi-block (2 blocks) with mode-pin flipping on block 2 & bus scrambling
        ref_init_iv(m[1:0], href);
        ref_compress(two_blk0, href);
        ref_compress(two_blk1, href);
        exp_dig = ref_format_digest(m[1:0], href);
        run_block_a(1'b1, m[1:0], two_blk0, 1'b1);
        run_block_a(1'b0, ~m[1:0], two_blk1, 1'b1); // Flip mode pin on next_cmd: must retain init mode!
        if (digest_a !== exp_dig)
          fail_now($sformatf("Two-block KAT mismatch prof=%0d mode=%0d: got=%h exp=%h", prof, m, digest_a, exp_dig));
      end
    end

    //----------------------------------------------------------------
    // 2. Seeded Random 3-Block Messages Across All 4 Modes
    //----------------------------------------------------------------
    ent_profile_a = 4;
    for (int trial = 0; trial < 8; trial++) begin
      logic [1:0]    rm;
      logic [1023:0] b0, b1, b2;
      rm = trial[1:0];
      b0 = next_u1024();
      b1 = next_u1024();
      b2 = next_u1024();
      ref_init_iv(rm, href);
      ref_compress(b0, href);
      ref_compress(b1, href);
      ref_compress(b2, href);
      exp_dig = ref_format_digest(rm, href);

      run_block_a(1'b1, rm, b0, 1'b1);
      run_block_a(1'b0, rm ^ 2'h2, b1, 1'b1);
      run_block_a(1'b0, rm ^ 2'h1, b2, 1'b1);
      if (digest_a !== exp_dig)
        fail_now($sformatf("Random 3-block mismatch trial=%0d mode=%0d: got=%h exp=%h", trial, rm, digest_a, exp_dig));
    end

    //----------------------------------------------------------------
    // 3. Malformed Command Rejection Suite
    //----------------------------------------------------------------
    hw_reset();
    // (3a) Bare next_cmd after reset (no active chain) -> must be ignored
    @(negedge clk);
    init_a = 1'b0; next_a = 1'b1; mode_a = 2'h3; msg_a = abc_blk;
    @(posedge clk); #1;
    if (ready_a !== 1'b1 || dvalid_a !== 1'b0)
      fail_now("Bare next_cmd after reset was accepted instead of rejected!");
    @(negedge clk); next_a = 1'b0;
    repeat (5) begin
      @(posedge clk); #1;
      if (ready_a !== 1'b1 || dvalid_a !== 1'b0)
        fail_now("Core became busy after rejected bare next_cmd!");
    end

    // (3b) Simultaneous init_cmd && next_cmd when idle -> must be ignored
    @(negedge clk);
    init_a = 1'b1; next_a = 1'b1; mode_a = 2'h3; msg_a = abc_blk;
    @(posedge clk); #1;
    if (ready_a !== 1'b1 || dvalid_a !== 1'b0)
      fail_now("Simultaneous init_cmd && next_cmd was accepted when idle!");
    @(negedge clk); init_a = 1'b0; next_a = 1'b0;

    // (3c) Simultaneous init_cmd && next_cmd between block 1 and block 2 -> must preserve block 1 state!
    ref_init_iv(2'h2, href);
    ref_compress(two_blk0, href);
    exp_dig = ref_format_digest(2'h2, href);
    run_block_a(1'b1, 2'h2, two_blk0, 1'b0);
    if (digest_a !== exp_dig)
      fail_now("Block 1 digest mismatch before malformed command check");

    @(negedge clk);
    init_a = 1'b1; next_a = 1'b1; mode_a = 2'h0; msg_a = ~two_blk0;
    @(posedge clk); #1;
    if (ready_a !== 1'b1 || dvalid_a !== 1'b1 || digest_a !== exp_dig)
      fail_now("Simultaneous init_cmd && next_cmd corrupted active chain or digest_valid!");
    @(negedge clk); init_a = 1'b0; next_a = 1'b0;
    @(posedge clk); #1;

    // Now finish block 2 with valid next_cmd -> must match 2-block SHA-384!
    ref_compress(two_blk1, href);
    exp_dig = ref_format_digest(2'h2, href);
    run_block_a(1'b0, 2'h2, two_blk1, 1'b1);
    if (digest_a !== exp_dig)
      fail_now("Block 2 chaining failed after rejected init_cmd && next_cmd!");

    //----------------------------------------------------------------
    // 4. Lockstep 3-Instance Share Integrity & Per-Round Refresh Suite
    //----------------------------------------------------------------
    run_lockstep_share_check(1'b0, 1'b0); // Full PRNG across handshake + CTRL_RND + CTRL_ROUNDS
    run_lockstep_share_check(1'b1, 1'b0); // Zero CTRL_RND + PRNG CTRL_ROUNDS recovery
    run_lockstep_share_check(1'b1, 1'b1); // Zero CTRL_RND + Constant all-ones/R CTRL_ROUNDS recovery

    //----------------------------------------------------------------
    // 5. Synchronous Zeroize Sanitization Across All FSM Phases
    //----------------------------------------------------------------
    ent_profile_a = 4;

    // (5a) Zeroize during CTRL_RND (cycle 3)
    hw_reset();
    @(negedge clk); init_a = 1'b1; next_a = 1'b0; mode_a = 2'h3; msg_a = abc_blk;
    @(posedge clk); #1;
    @(negedge clk); init_a = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk); zeroize_a = 1'b1;
    @(posedge clk); #1;
    check_all_zeroed_a("CTRL_RND_zeroize");
    @(negedge clk); zeroize_a = 1'b0;

    // (5b) Zeroize mid-round during CTRL_ROUNDS (cycle 35)
    @(negedge clk); init_a = 1'b1; next_a = 1'b0; mode_a = 2'h3; msg_a = two_blk0;
    @(posedge clk); #1;
    @(negedge clk); init_a = 1'b0;
    repeat (35) @(posedge clk);
    #1;
    if (ready_a !== 1'b0)
      fail_now("Expected core busy at cycle 35 before mid-round zeroize");
    @(negedge clk); zeroize_a = 1'b1;
    @(posedge clk); #1;
    check_all_zeroed_a("CTRL_ROUNDS_zeroize");
    @(negedge clk); zeroize_a = 1'b0;

    // Bare next_cmd right after mid-round zeroize must be rejected!
    @(negedge clk); init_a = 1'b0; next_a = 1'b1; msg_a = two_blk1;
    @(posedge clk); #1;
    if (ready_a !== 1'b1 || dvalid_a !== 1'b0)
      fail_now("Bare next_cmd accepted after zeroize!");
    @(negedge clk); next_a = 1'b0;

    // Recovery after mid-round zeroize: full 2-block run must succeed!
    ref_init_iv(2'h1, href);
    ref_compress(two_blk0, href);
    ref_compress(two_blk1, href);
    exp_dig = ref_format_digest(2'h1, href);
    run_block_a(1'b1, 2'h1, two_blk0, 1'b1);
    run_block_a(1'b0, 2'h1, two_blk1, 1'b1);
    if (digest_a !== exp_dig)
      fail_now("Post-zeroize 2-block SHA-512/256 recovery digest mismatch!");

    // (5c) Zeroize while digest_valid == 1 (active chain present)
    @(negedge clk); zeroize_a = 1'b1;
    @(posedge clk); #1;
    check_all_zeroed_a("POST_DONE_zeroize");
    @(negedge clk); zeroize_a = 1'b0;

    // Bare next_cmd after post-done zeroize must ALSO be rejected!
    @(negedge clk); init_a = 1'b0; next_a = 1'b1; msg_a = two_blk1;
    @(posedge clk); #1;
    if (ready_a !== 1'b1 || dvalid_a !== 1'b0)
      fail_now("Bare next_cmd accepted after post-done zeroize!");
    @(negedge clk); next_a = 1'b0;

    // (5d) Simultaneous zeroize && init_cmd -> zeroize must win!
    @(negedge clk); zeroize_a = 1'b1; init_a = 1'b1; msg_a = abc_blk;
    @(posedge clk); #1;
    check_all_zeroed_a("SIMUL_INIT_zeroize");
    @(negedge clk); zeroize_a = 1'b0; init_a = 1'b0;
    @(posedge clk); #1;
    if (ready_a !== 1'b1 || dvalid_a !== 1'b0)
      fail_now("Core started block on simultaneous zeroize && init_cmd!");

    $display("TB_RESULT: PASS (seed=%0d)", seed);
    $finish(0);
  end

endmodule
