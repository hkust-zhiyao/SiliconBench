// SPDX-License-Identifier: Apache-2.0
//
// Alternate reference implementation: 1-AND factored Boolean Ch/Maj and
// 64-bit gamma-masked complement-addition A2B conversion.
`ifndef CALIPTRA_SHA512_MASKED_DEFINES_PKG
`define CALIPTRA_SHA512_MASKED_DEFINES_PKG

package sha512_masked_defines_pkg;

  typedef struct packed {
    reg   [63:0]  masked;
    reg   [63:0]  random;
  } masked_reg_t;

  function automatic logic [63:0] rol64 (input logic [63:0] v, input int unsigned sh);
    int unsigned s;
    s = sh & 32'd63;
    if (s == 0)
      return v;
    else
      return (v << s) | (v >> (64 - s));
  endfunction

  function automatic logic [63:0] derive_lane_mask (
    input logic [191:0] ent,
    input int unsigned  lane
  );
    logic [63:0] w0, w1, w2;
    w0 = ent[63:0];
    w1 = ent[127:64];
    w2 = ent[191:128];
    return rol64(w0, (lane * 5 + 1) % 64) ^
           rol64(w0, (lane * 5 + 17) % 64) ^
           rol64(w0, (lane * 5 + 37) % 64) ^
           rol64(w1, (lane * 9 + 7) % 64) ^
           rol64(w2, (lane * 15 + 29) % 64);
  endfunction

  function automatic masked_reg_t remask_pair (
    input masked_reg_t s,
    input logic [63:0] m_delta
  );
    return '{masked: s.masked ^ m_delta, random: s.random ^ m_delta};
  endfunction

  function automatic masked_reg_t masked_not (input masked_reg_t x);
    return {~x.masked, x.random};
  endfunction

  function automatic masked_reg_t isw_and2 (
    input masked_reg_t x,
    input masked_reg_t y,
    input logic [63:0] z
  );
    logic [63:0] p;
    p = z ^ (x.masked & y.masked);
    p = p ^ (x.masked & y.random);
    p = p ^ (x.random & y.masked);
    p = p ^ (x.random & y.random);
    return '{masked: p, random: z};
  endfunction

  function automatic reg [63:0] masked_and (input masked_reg_t x, y);
    masked_reg_t t;
    t = isw_and2(x, y, x.random);
    return t.masked;
  endfunction

  // Factored 1-AND Maj: Maj(a,b,c) = a ^ ((a ^ b) & (a ^ c))
  function automatic masked_reg_t masked_maj_factored (
    input masked_reg_t a,
    input masked_reg_t b,
    input masked_reg_t c,
    input logic [63:0] z_ab,
    input logic [63:0] z_ac,
    input logic [63:0] z_out
  );
    masked_reg_t ab_s, ac_s, prod;
    ab_s = '{masked: (a.masked ^ z_ab) ^ b.masked, random: (a.random ^ z_ab) ^ b.random};
    ac_s = '{masked: (a.masked ^ z_ac) ^ c.masked, random: (a.random ^ z_ac) ^ c.random};
    prod = isw_and2(ab_s, ac_s, z_out);
    return '{masked: prod.masked ^ a.masked, random: prod.random ^ a.random};
  endfunction

  // Factored 1-AND Ch: Ch(e,f,g) = g ^ (e & (f ^ g))
  function automatic masked_reg_t masked_ch_factored (
    input masked_reg_t e,
    input masked_reg_t f,
    input masked_reg_t g,
    input logic [63:0] z_fg,
    input logic [63:0] z_out
  );
    masked_reg_t fg_s, prod;
    fg_s = '{masked: (f.masked ^ z_fg) ^ g.masked, random: (f.random ^ z_fg) ^ g.random};
    prod = isw_and2(e, fg_s, z_out);
    return '{masked: prod.masked ^ g.masked, random: prod.random ^ g.random};
  endfunction

  function automatic masked_reg_t masked_maj (input masked_reg_t a, b, c);
    return masked_maj_factored(
      a, b, c,
      rol64(a.random, 13) ^ rol64(b.random, 29) ^ rol64(c.random, 47),
      rol64(a.random, 3)  ^ rol64(b.random, 19) ^ rol64(c.random, 53),
      rol64(a.random, 31) ^ rol64(b.random, 41) ^ rol64(c.random, 59)
    );
  endfunction

  function automatic masked_reg_t masked_ch (input masked_reg_t e, f, g);
    return masked_ch_factored(
      e, f, g,
      rol64(e.random, 7)  ^ rol64(f.random, 23) ^ rol64(g.random, 43),
      rol64(e.random, 17) ^ rol64(f.random, 37) ^ rol64(g.random, 61)
    );
  endfunction

  function automatic reg [63:0] sigma0 (input reg [63:0] x);
    return {x[27 : 0], x[63 : 28]} ^
           {x[33 : 0], x[63 : 34]} ^
           {x[38 : 0], x[63 : 39]};
  endfunction

  function automatic reg [63:0] sigma1 (input reg [63:0] x);
    return {x[13 : 0], x[63 : 14]} ^
           {x[17 : 0], x[63 : 18]} ^
           {x[40 : 0], x[63 : 41]};
  endfunction

  function automatic reg [63:0] ROT1 (input reg [63:0] x);
    return {x[0],       x[63 : 1]} ^
           {x[7 : 0],   x[63 : 8]} ^
           {7'b0000000, x[63 : 7]};
  endfunction

  function automatic reg [63:0] ROT14 (input reg [63:0] x);
    return {x[18 : 0], x[63 : 19]} ^
           {x[60 : 0], x[63 : 61]} ^
           {6'b000000, x[63 : 6]};
  endfunction

  function automatic masked_reg_t masked_sum (input masked_reg_t x, y);
    return {(x.masked + y.masked), (x.random + y.random)};
  endfunction

  function automatic masked_reg_t B2A_conv (input masked_reg_t x, logic q);
    reg [63 : 0] masked_carry;
    reg [63 : 0] x_prime;
    for (int j = 0; j < 64 ; j++) begin
      if (j == 0) begin
        masked_carry[j] = ~x.masked[j] & (x.random[j] ^ q) | (x.masked[j] & q);
        x_prime[j]      = x.masked[j];
      end
      else begin
        masked_carry[j] = ~x.masked[j] & (x.random[j] ^ q) | x.masked[j] & masked_carry[j-1];
        x_prime[j]      = (x.masked[j] ^ masked_carry[j-1]) ^ q;
      end
    end
    return {x_prime, x.random};
  endfunction

  // Complement-addition 64-bit gamma-masked A2B conversion:
  // Uses (~x.masked + x.random) mod 2^64 == ~x identically.
  function automatic masked_reg_t a2b_gamma64 (
    input masked_reg_t x,
    input logic [63:0] gamma
  );
    logic [63:0] a_inv;
    logic [63:0] mc;
    logic [63:0] inv_xm;
    logic        t;

    a_inv = ~x.masked;
    mc[0] = gamma[0] ^ (a_inv[0] & x.random[0]);
    for (int j = 1; j < 64; j++) begin
      t = gamma[j] ^ (a_inv[j] & x.random[j]);
      t = t ^ (a_inv[j]    & mc[j - 1]);
      t = t ^ (a_inv[j]    & gamma[j - 1]);
      t = t ^ (x.random[j] & mc[j - 1]);
      t = t ^ (x.random[j] & gamma[j - 1]);
      mc[j] = t;
    end
    inv_xm = (a_inv ^ {mc[62:0], 1'b0}) ^ {gamma[62:0], 1'b0};
    return '{masked: ~inv_xm, random: x.random};
  endfunction

  function automatic masked_reg_t A2B_conv (input masked_reg_t x, logic q);
    return a2b_gamma64(x, {64{q}});
  endfunction

endpackage

`endif
