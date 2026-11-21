// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
`ifndef CALIPTRA_SHA512_MASKED_DEFINES_PKG
`define CALIPTRA_SHA512_MASKED_DEFINES_PKG

package sha512_masked_defines_pkg;

  typedef struct packed {
    reg   [63:0]  masked;
    reg   [63:0]  random;
  } masked_reg_t;

  //----------------------------------------------------------------
  // Rotation and entropy-expansion helpers.
  //----------------------------------------------------------------
  function automatic logic [63:0] rot64 (input logic [63:0] x, input int unsigned sh);
    int unsigned s;
    s = sh & 32'd63;
    if (s == 0)
      return x;
    else
      return (x >> s) | (x << (64 - s));
  endfunction

  // Odd-weight rotation mixing so constant non-zero 64-bit words (including all-ones)
  // never self-cancel to zero while preserving full entropy across indices.
  function automatic logic [63:0] expand_entropy_word (
    input logic [191:0] ent,
    input int unsigned  idx
  );
    logic [63:0] e0, e1, e2, t0;
    e0 = ent[63:0];
    e1 = ent[127:64];
    e2 = ent[191:128];
    t0 = rot64(e0, (idx * 7) % 64) ^
         rot64(e0, (idx * 7 + 19) % 64) ^
         rot64(e0, (idx * 7 + 41) % 64);
    return t0 ^
           rot64(e1, (idx * 11 + 5) % 64) ^
           rot64(e2, (idx * 13 + 23) % 64);
  endfunction

  // Re-mask a boolean two-share value without ever recombining (.masked ^ .random).
  function automatic masked_reg_t refresh_masked (
    input masked_reg_t x,
    input logic [63:0] delta
  );
    return '{masked: x.masked ^ delta, random: x.random ^ delta};
  endfunction

  //----------------------------------------------------------------
  // Function definition.
  //----------------------------------------------------------------
  function automatic masked_reg_t masked_not (input masked_reg_t x);
    return {~x.masked, x.random};
  endfunction

  function automatic reg [63:0] masked_and (input masked_reg_t x, y);
    logic [63:0] acc;
    acc = x.random ^ (x.masked & y.masked);
    acc = acc      ^ (x.masked & y.random);
    acc = acc      ^ (x.random & y.masked);
    acc = acc      ^ (x.random & y.random);
    return acc;
  endfunction

  function automatic masked_reg_t masked_maj_fresh (
    input masked_reg_t a,
    input masked_reg_t b,
    input masked_reg_t c,
    input logic [63:0] z
  );
    logic [63:0] acc;
    acc = z   ^ (a.masked & b.masked);
    acc = acc ^ (a.masked & b.random);
    acc = acc ^ (a.random & b.masked);
    acc = acc ^ (a.random & b.random);
    acc = acc ^ (a.masked & c.masked);
    acc = acc ^ (a.masked & c.random);
    acc = acc ^ (a.random & c.masked);
    acc = acc ^ (a.random & c.random);
    acc = acc ^ (b.masked & c.masked);
    acc = acc ^ (b.masked & c.random);
    acc = acc ^ (b.random & c.masked);
    acc = acc ^ (b.random & c.random);
    return '{masked: acc, random: z};
  endfunction

  function automatic masked_reg_t masked_ch_fresh (
    input masked_reg_t e,
    input masked_reg_t f,
    input masked_reg_t g,
    input logic [63:0] z
  );
    logic [63:0] acc;
    acc = z   ^ (e.masked & f.masked);
    acc = acc ^ (e.masked & f.random);
    acc = acc ^ (e.random & f.masked);
    acc = acc ^ (e.random & f.random);
    acc = acc ^ ((~e.masked) & g.masked);
    acc = acc ^ ((~e.masked) & g.random);
    acc = acc ^ (e.random    & g.masked);
    acc = acc ^ (e.random    & g.random);
    return '{masked: acc, random: z};
  endfunction

  function automatic masked_reg_t masked_maj (input masked_reg_t a, b, c);
    logic [63:0] z_mix;
    z_mix = rot64(a.random, 7) ^ rot64(b.random, 23) ^ rot64(c.random, 41);
    return masked_maj_fresh(a, b, c, z_mix);
  endfunction

  function automatic masked_reg_t masked_ch (input masked_reg_t e, f, g);
    logic [63:0] z_mix;
    z_mix = rot64(e.random, 11) ^ rot64(f.random, 29) ^ rot64(g.random, 47);
    return masked_ch_fresh(e, f, g, z_mix);
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
    return {x[0],       x[63 : 1]} ^ // ROTR1
           {x[7 : 0],   x[63 : 8]} ^ // ROTR8
           {7'b0000000, x[63 : 7]};  // SHR7
  endfunction

  function automatic reg [63:0] ROT14 (input reg [63:0] x);
    return {x[18 : 0], x[63 : 19]} ^ // ROTR19
           {x[60 : 0], x[63 : 61]} ^ // ROTR61
           {6'b000000, x[63 : 6]};   // SHR6
  endfunction

  function automatic masked_reg_t masked_sum (input masked_reg_t x, y);
    return {(x.masked + y.masked), (x.random + y.random)};
  endfunction

  function automatic masked_reg_t B2A_conv (input masked_reg_t x, logic q); // convert x_masked = x ^ rnd to x_prime = x + rand
    reg [63 : 0] masked_carry;  // masked_carry[j] = c[j] ^ q
    reg [63 : 0] x_prime;
    for (int j = 0; j < 64 ; j++) begin
        if (j == 0) begin
          masked_carry[j] = ~x.masked[j] & (x.random[j] ^ q) | (x.masked[j] & q);
          x_prime[j] = x.masked[j];
        end
        else begin
          masked_carry[j] = ~x.masked[j] & (x.random[j] ^ q) | x.masked[j] & masked_carry[j-1];
          x_prime[j] = (x.masked[j] ^ masked_carry[j-1]) ^ q;
        end
    end
    return {x_prime, x.random};
  endfunction

  // Self-dual masked borrow A2B conversion: converts x_prime = (x + rand) mod 2^64
  // to x_masked = x ^ rand without ever forming (x.masked ^ x.random).
  function automatic masked_reg_t A2B_conv (input masked_reg_t x, logic q);
    reg [63 : 0] masked_carry;  // masked_carry[j] = borrow_carry[j] ^ q
    reg [63 : 0] x_masked;
    logic        na_q;
    logic        r_q;

    for (int j = 0; j < 64 ; j++) begin
      na_q = (~x.masked[j]) ^ q;
      r_q  = x.random[j] ^ q;
      if (j == 0) begin
        masked_carry[0] = (na_q & r_q) | (na_q & q) | (r_q & q);
        x_masked[0]     = x.masked[0];
      end
      else begin
        masked_carry[j] = (na_q & r_q) | (na_q & masked_carry[j-1]) | (r_q & masked_carry[j-1]);
        x_masked[j]     = (x.masked[j] ^ masked_carry[j-1]) ^ q;
      end
    end
    return {x_masked, x.random};
  endfunction

endpackage

`endif
