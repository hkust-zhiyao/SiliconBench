# `case_25011`: Harden Caliptra Masked SHA-512 Share Non-Cancellation, Per-Round Refreshing, Masked Chaining, and Synchronous Zeroize

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25011` |
| **Source Silicon Repository** | `chipsalliance/caliptra-rtl` (`repo_50`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Security_RoT_Subsystems` (Security_RoT_Subsystems) |
| **Multi-Domain Tags** | `Security_RoT_Subsystems` |
| **Editable Files (`allowed_edits`)** | [`code/sha512_masked_defines_pkg.sv`](environment/public/code/sha512_masked_defines_pkg.sv), [`code/sha512_masked_w_mem.sv`](environment/public/code/sha512_masked_w_mem.sv), [`code/sha512_masked_core.sv`](environment/public/code/sha512_masked_core.sv) (3 files, 1133 LOC) |
| **Public Subsystem Context** | 5 RTL files (1440 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Masked SHA-512 Core: Share-Cancellation Leaks, Plaintext Chaining Exposure, Missing Round Refresh, and Handshake/Zeroize Hazards

## Context

`sha512_masked_core` (`code/sha512_masked_core.sv`, `code/sha512_masked_w_mem.sv`, and `code/sha512_masked_defines_pkg.sv`) implements Caliptra's first-order boolean/arithmetic masked SHA-512 compression and message-schedule engine used for side-channel-hardened HMAC and key derivation. Each sensitive 64-bit intermediate word $x$ is represented as a two-share `masked_reg_t` pair `(masked, random)` satisfying $x = \text{masked} \oplus \text{random}$ in the boolean domain or $x \equiv (\text{masked} - \text{random}) \pmod{2^{64}}$ in the arithmetic domain.

Pre-silicon security review and side-channel probing analysis uncovered multiple interacting functional and first-order masking defects across the package primitives, message-schedule array, chaining-state datapath, and command/zeroize control logic:

1. **Combinational share cancellation & premature unmasking (`sha512_masked_defines_pkg.sv`, `sha512_masked_core.sv`)**:
   - `masked_maj` XORs `masked_and(a, b) ^ masked_and(a, c)`, canceling `a.random ^ a.random` to zero and exposing the unmasked nonlinear term `(a & b) ^ (a & c)` on every round.
   - `masked_ch` sets its output mask to `e.random ^ g.random` without fresh mask injection; whenever `e.random` and `g.random` collide or correlate (e.g., repeated mask words), `ch.random` collapses to `64'h0` and `ch.masked` carries plaintext `Ch(e, f, g)`.
   - `A2B_conv` forms `(x.masked[j] ^ x.random[j])` and `(~x.masked[j] ^ x.random[j])`, directly canceling `x.random[j]` and leaking unmasked low-order secret bits whenever lower carry bits are zero.
   - At block completion (`CTRL_DONE`), `digest_logic` computes `H0_reg + (a_reg.masked ^ a_reg.random)` and stores `H0_reg .. H7_reg` as plaintext flip-flops, broadcasting unmasked intermediate chaining state across `digest` even while `digest_valid == 1'b0`.

2. **Missing per-round 64-bit share refreshing (`sha512_masked_core.sv`, `sha512_masked_w_mem.sv`)**:
   - During the 80 compression rounds (`CTRL_ROUNDS`), `masking_rnd` is never updated (`entropy[191:15]` is ignored), `b_reg .. d_reg` and `f_reg .. h_reg` shift unrefreshed `(masked, random)` share pairs across adjacent registers, `w_mem[0:15]` is never refreshed during rounds `0..15` and shifts unrefreshed words during rounds `16..79`, and `rnd_ctr_reg == 8` wraps `rnd_ctr_reg[2:0]` to overwrite `masking_rnd[0:2]`. Consequently, consecutive shift stages suffer direct Hamming-distance transition leakage, and if `entropy` is zero during initialization (`CTRL_RND`) before turning non-zero during `CTRL_ROUNDS`, all working and schedule registers remain completely unmasked (`random == 64'h0`) for all 80 rounds.

3. **Mode truncation, handshake input capture, & command validation defects (`sha512_masked_core.sv`, `sha512_masked_w_mem.sv`)**:
   - `digest` always outputs all 512 bits without truncating unused lower bits for `SHA-512/224` (`mode == 2'h0`), `SHA-512/256` (`mode == 2'h1`), or `SHA-384` (`mode == 2'h2`), and is not gated to zero when `digest_valid == 1'b0`.
   - `block_msg` and `mode` are not captured on the `ready` command handshake edge; instead, live `block_msg` and `mode` pins are sampled cycles later at the end of `CTRL_RND`.
   - Malformed command combinations (`init_cmd && next_cmd` simultaneously, or `next_cmd` when no completed `init_cmd` chain is active since reset or `zeroize`) are accepted instead of rejected.

## Required Behavior

### 1. Multi-Mode FIPS 180-4 Digest Accuracy, Output Gating, & Chaining Precision
- Produce bit-exact FIPS 180-4 digests across single-block (`init_cmd`) and multi-block (`init_cmd` followed by one or more `next_cmd` blocks) messages under arbitrary `entropy[191:0]` streams (including all-zero, all-ones, repeated 64-bit constant words, alternating patterns, and pseudo-random streams) for all four `mode` encodings:
  - `2'h0` (`SHA-512/224`): `digest[511:288]` holds the 224-bit digest; `digest[287:0] == 288'h0`.
  - `2'h1` (`SHA-512/256`): `digest[511:256]` holds the 256-bit digest; `digest[255:0] == 256'h0`.
  - `2'h2` (`SHA-384`): `digest[511:128]` holds the 384-bit digest; `digest[127:0] == 128'h0`.
  - `2'h3` (`SHA-512`): `digest[511:0]` holds the full 512-bit digest.
- Internal multi-block chaining state (`H0..H7`) must retain all 8 full 64-bit words across `next_cmd` continuations even in truncated modes; mode width truncation applies only to the external `digest` port.
- Whenever `digest_valid == 1'b0`, `digest` must output `512'h0`. Share recombination (`masked ^ random`) to form the plaintext digest must be gated by `digest_valid` prior to XORing so no internal net or register unmasks the chaining state while `digest_valid == 1'b0`.

### 2. Command Handshake, Masked Block Capture, & Invalid Command Rejection
- Sample commands only on rising `clk` edges where `ready == 1'b1` and `zeroize == 1'b0`:
  - **Valid initial block (`init_cmd == 1'b1 && next_cmd == 1'b0`)**: Latch `mode` for the duration of the message chain, capture `block_msg[1023:0]` on that exact clock edge directly into two-share masked storage (using mask words derived from live `entropy` and internal mask state so plaintext `block_msg` is never latched into any register), clear `digest_valid <= 1'b0`, and deassert `ready <= 1'b0`.
  - **Valid continuation block (`init_cmd == 1'b0 && next_cmd == 1'b1` after at least one completed `init_cmd` since reset or `zeroize`)**: Capture `block_msg[1023:0]` on that exact clock edge into two-share masked storage, retain the `mode` latched by the preceding `init_cmd` (ignoring changes on the `mode` input pin), clear `digest_valid <= 1'b0`, and deassert `ready <= 1'b0`.
  - **Invalid commands**: Asserting `init_cmd && next_cmd` simultaneously, or asserting `next_cmd && !init_cmd` when no prior `init_cmd` block has completed since the last `reset_n` or `zeroize`, must be ignored with zero side effects (`ready` remains `1'b1`, no round run starts, and any existing valid chaining state and `digest_valid`/`digest` remain intact).
- Transitions on `init_cmd`, `next_cmd`, `mode`, and `block_msg` while `ready == 1'b0` must be ignored. Complete each accepted 1024-bit block within 120 clock cycles.

### 3. First-Order Share Integrity, Masked Chaining State, & Per-Round Refreshing
- Maintain the boolean two-share invariant (`word == share.masked ^ share.random`) across `a_reg .. h_reg` and `w_mem[0:15]`.
- Eliminate share cancellation and unmasked intermediate nets in `Ch`, `Maj`, and `A2B_conv`:
  - Inject fresh 64-bit mask words into nonlinear `Ch` and `Maj` evaluations, folding the fresh mask in before combining cross-share partial products so no intermediate net evaluates to an unmasked secret function even when input masks are equal (`e.random == f.random == g.random` or `a.random == b.random == c.random`).
  - Implement `A2B_conv` without forming `(x.masked ^ x.random)` or `(~x.masked ^ x.random)` on any bit.
- Maintain the 8-word chaining digest (`H0..H7`) in two-share masked form across blocks, updating it at block completion (`CTRL_DONE`) via masked `B2A`/`masked_sum`/`A2B` addition and initializing `next_cmd` working registers from the masked chaining state without ever forming plaintext `H0..H7` or `(a_reg.masked ^ a_reg.random)`.
- Evolve internal mask state with `entropy[191:0]` and re-mask all 8 working-state share pairs (`a_reg .. h_reg`, including shifted registers `b_reg .. d_reg` and `f_reg .. h_reg`) and all 16 message-schedule share pairs (`w_mem[0:15]` across both rounds `0..15` and `16..79`) on every compression round without unmasking (`{share.masked ^ delta, share.random ^ delta}`). Ensure non-zero `entropy[191:0]` (including repeated constant non-zero 64-bit words such as `{R, R, R}` or all-ones) immediately produces non-zero masks across all working and schedule shares even if `entropy` was zero during `CTRL_RND`.

### 4. Immediate Synchronous `zeroize` Sanitization
- Asserting `zeroize == 1'b1` at any cycle (idle, mask pre-charge, mid-round `0..79`, completion, or simultaneously with `init_cmd`/`next_cmd`) must synchronously on the next rising `clk` edge clear all working shares (`a_reg .. h_reg`), all schedule shares (`w_mem[0:15]`) and schedule counters, all masked chaining shares, internal `masking_rnd` state, latched mode, and active-chain state, driving `ready == 1'b1`, `digest_valid == 1'b0`, and `digest == 512'h0`. After `zeroize` deasserts, a bare `next_cmd` must be rejected until a new `init_cmd` completes.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Interface Notes

## Source Layout

- **Editable RTL files**:
  - `code/sha512_masked_defines_pkg.sv` — package `sha512_masked_defines_pkg` (`masked_reg_t` and masked boolean/arithmetic conversion helpers)
  - `code/sha512_masked_w_mem.sv` — module `sha512_masked_w_mem` (16-word masked message-schedule storage and expansion)
  - `code/sha512_masked_core.sv` — module `sha512_masked_core` (top-level masked SHA-512 family compression core)
- **Read-only RTL & license files** (do not modify):
  - `code/sha512_h_constants.v` — module `sha512_h_constants`
  - `code/sha512_k_constants.v` — module `sha512_k_constants`
  - `code/LICENSE`

## Preserved Top-Level & Observable Architecture Contracts

1. Preserve the `sha512_masked_core` module name and exact top-level port list/widths:
   - Inputs: `clk`, `reset_n`, `zeroize`, `init_cmd`, `next_cmd`, `mode[1:0]`, `entropy[191:0]`, `block_msg[1023:0]`
   - Outputs: `ready`, `digest[511:0]`, `digest_valid`
2. Preserve `masked_reg_t` (`typedef struct packed { reg [63:0] masked; reg [63:0] random; }`) in `sha512_masked_defines_pkg`. Additional helper functions may be added to `sha512_masked_defines_pkg`, and internal submodule ports between `sha512_masked_core` and `sha512_masked_w_mem` may be extended as needed.
3. Preserve the following observable two-share registers (`masked_reg_t`, where `masked ^ random` equals the architectural 64-bit word):
   - Working state registers `a_reg`, `b_reg`, `c_reg`, `d_reg`, `e_reg`, `f_reg`, `g_reg`, `h_reg` in `sha512_masked_core`
   - Message-schedule instance `w_mem_inst` (`sha512_masked_w_mem`) containing `masked_reg_t w_mem [0 : 15]` in `sha512_masked_core`

## Synthesis & Simulation Checks

All RTL must be cleanly synthesizable SystemVerilog/Verilog without inferred latches, combinational loops, or simulator-only constructs:

```bash
# Synthesis, zero-latch, and zero-combinational-loop check
yosys -m slang -p "read_slang -DSYNTHESIS --top sha512_masked_core -Icode \
  code/sha512_masked_defines_pkg.sv code/sha512_h_constants.v code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv code/sha512_masked_core.sv; \
  proc; opt; check -assert; scc -expect 0"

# Verilator elaboration check
verilator --lint-only -Wno-fatal -DSYNTHESIS -Icode --top-module sha512_masked_core \
  code/sha512_masked_defines_pkg.sv code/sha512_h_constants.v code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv code/sha512_masked_core.sv
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/sha512_masked_defines_pkg.sv (Buggy Starter)
+++ b/solution/gold/code/sha512_masked_defines_pkg.sv (Golden Reference)
@@ -23,6 +23,44 @@
   } masked_reg_t;
 
   //----------------------------------------------------------------
+  // Rotation and entropy-expansion helpers.
+  //----------------------------------------------------------------
+  function automatic logic [63:0] rot64 (input logic [63:0] x, input int unsigned sh);
+    int unsigned s;
+    s = sh & 32'd63;
+    if (s == 0)
+      return x;
+    else
+      return (x >> s) | (x << (64 - s));
+  endfunction
+
+  // Odd-weight rotation mixing so constant non-zero 64-bit words (including all-ones)
+  // never self-cancel to zero while preserving full entropy across indices.
+  function automatic logic [63:0] expand_entropy_word (
+    input logic [191:0] ent,
+    input int unsigned  idx
+  );
+    logic [63:0] e0, e1, e2, t0;
+    e0 = ent[63:0];
+    e1 = ent[127:64];
+    e2 = ent[191:128];
+    t0 = rot64(e0, (idx * 7) % 64) ^
+         rot64(e0, (idx * 7 + 19) % 64) ^
+         rot64(e0, (idx * 7 + 41) % 64);
+    return t0 ^
+           rot64(e1, (idx * 11 + 5) % 64) ^
+           rot64(e2, (idx * 13 + 23) % 64);
+  endfunction
+
+  // Re-mask a boolean two-share value without ever recombining (.masked ^ .random).
+  function automatic masked_reg_t refresh_masked (
+    input masked_reg_t x,
+    input logic [63:0] delta
+  );
+    return '{masked: x.masked ^ delta, random: x.random ^ delta};
+  endfunction
+
+  //----------------------------------------------------------------
   // Function definition.
   //----------------------------------------------------------------
   function automatic masked_reg_t masked_not (input masked_reg_t x);
@@ -30,15 +68,64 @@
   endfunction
 
   function automatic reg [63:0] masked_and (input masked_reg_t x, y);
-    return ~y.masked & (~y.random & x.random | y.random & x.masked) | y.masked & (y.random & x.random | ~y.random & x.masked); //x & y;
+    logic [63:0] acc;
+    acc = x.random ^ (x.masked & y.masked);
+    acc = acc      ^ (x.masked & y.random);
+    acc = acc      ^ (x.random & y.masked);
+    acc = acc      ^ (x.random & y.random);
+    return acc;
+  endfunction
+
+  function automatic masked_reg_t masked_maj_fresh (
+    input masked_reg_t a,
+    input masked_reg_t b,
+    input masked_reg_t c,
+    input logic [63:0] z
+  );
+    logic [63:0] acc;
+    acc = z   ^ (a.masked & b.masked);
+    acc = acc ^ (a.masked & b.random);
+    acc = acc ^ (a.random & b.masked);
+    acc = acc ^ (a.random & b.random);
+    acc = acc ^ (a.masked & c.masked);
+    acc = acc ^ (a.masked & c.random);
+    acc = acc ^ (a.random & c.masked);
+    acc = acc ^ (a.random & c.random);
+    acc = acc ^ (b.masked & c.masked);
+    acc = acc ^ (b.masked & c.random);
+    acc = acc ^ (b.random & c.masked);
+    acc = acc ^ (b.random & c.random);
+    return '{masked: acc, random: z};
+  endfunction
+
+  function automatic masked_reg_t masked_ch_fresh (
+    input masked_reg_t e,
+    input masked_reg_t f,
+    input masked_reg_t g,
+    input logic [63:0] z
+  );
+    logic [63:0] acc;
+    acc = z   ^ (e.masked & f.masked);
+    acc = acc ^ (e.masked & f.random);
+    acc = acc ^ (e.random & f.masked);
+    acc = acc ^ (e.random & f.random);
+    acc = acc ^ ((~e.masked) & g.masked);
+    acc = acc ^ ((~e.masked) & g.random);
+    acc = acc ^ (e.random    & g.masked);
+    acc = acc ^ (e.random    & g.random);
+    return '{masked: acc, random: z};
   endfunction
 
   function automatic masked_reg_t masked_maj (input masked_reg_t a, b, c);
-    return {masked_and(a, b) ^ masked_and(a, c) ^ masked_and(b, c), b.random};
+    logic [63:0] z_mix;
+    z_mix = rot64(a.random, 7) ^ rot64(b.random, 23) ^ rot64(c.random, 41);
+    return masked_maj_fresh(a, b, c, z_mix);
   endfunction
 
   function automatic masked_reg_t masked_ch (input masked_reg_t e, f, g);
-    return {masked_and(e, f) ^ masked_and(g, masked_not(e)), e.random ^ g.random};
+    logic [63:0] z_mix;
+    z_mix = rot64(e.random, 11) ^ rot64(f.random, 29) ^ rot64(g.random, 47);
+    return masked_ch_fresh(e, f, g, z_mix);
   endfunction
 
   function automatic reg [63:0] sigma0 (input reg [63:0] x);
@@ -56,15 +143,15 @@
   function automatic reg [63:0] ROT1 (input reg [63:0] x);
     return {x[0],       x[63 : 1]} ^ // ROTR1
            {x[7 : 0],   x[63 : 8]} ^ // ROTR8
-           {7'b0000000, x[63 : 7]};  // SHR7           
-  endfunction
-  
+           {7'b0000000, x[63 : 7]};  // SHR7
+  endfunction
+
   function automatic reg [63:0] ROT14 (input reg [63:0] x);
     return {x[18 : 0], x[63 : 19]} ^ // ROTR19
            {x[60 : 0], x[63 : 61]} ^ // ROTR61
-           {6'b000000, x[63 : 6]};   // SHR6          
-  endfunction
-  
+           {6'b000000, x[63 : 6]};   // SHR6
+  endfunction
+
   function automatic masked_reg_t masked_sum (input masked_reg_t x, y);
     return {(x.masked + y.masked), (x.random + y.random)};
   endfunction
@@ -85,18 +172,24 @@
     return {x_prime, x.random};
   endfunction
 
-  function automatic masked_reg_t A2B_conv (input masked_reg_t x, logic q); // convert x_prime = x + rand to x_masked = x ^ rnd
-    reg [63 : 0] masked_carry;  // masked_carry[j] = c[j] ^ q
+  // Self-dual masked borrow A2B conversion: converts x_prime = (x + rand) mod 2^64
+  // to x_masked = x ^ rand without ever forming (x.masked ^ x.random).
+  function automatic masked_reg_t A2B_conv (input masked_reg_t x, logic q);
+    reg [63 : 0] masked_carry;  // masked_carry[j] = borrow_carry[j] ^ q
     reg [63 : 0] x_masked;
- 
+    logic        na_q;
+    logic        r_q;
+
     for (int j = 0; j < 64 ; j++) begin
+      na_q = (~x.masked[j]) ^ q;
+      r_q  = x.random[j] ^ q;
       if (j == 0) begin
-        masked_carry[j] = (~x.masked[0] & x.random[0]) ^ q;
-        x_masked[j] = x.masked[j];
+        masked_carry[0] = (na_q & r_q) | (na_q & q) | (r_q & q);
+        x_masked[0]     = x.masked[0];
       end
       else begin
-        masked_carry[j] = (x.masked[j] ^ x.random[j]) & (x.random[j] ^ q) | (~x.masked[j] ^ x.random[j]) & masked_carry[j-1];
-        x_masked[j] = (x.masked[j] ^ masked_carry[j-1]) ^ q;
+        masked_carry[j] = (na_q & r_q) | (na_q & masked_carry[j-1]) | (r_q & masked_carry[j-1]);
+        x_masked[j]     = (x.masked[j] ^ masked_carry[j-1]) ^ q;
       end
     end
     return {x_masked, x.random};

--- a/environment/public/code/sha512_masked_w_mem.sv (Buggy Starter)
+++ b/solution/gold/code/sha512_masked_w_mem.sv (Golden Reference)
@@ -1,10 +1,9 @@
 //======================================================================
 //
-// sha512_masked_w_mem_regs.v
+// sha512_masked_w_mem.sv
 // -------------------
-// The W memory for the SHA-512 core. This version uses 16
-// 32-bit registers as a sliding window to generate the 64 words.
-//
+// Masked W message-schedule memory for the SHA-512 core with immediate
+// masked handshake block capture and per-round share refreshing.
 //
 // Author: Joachim Strombergson
 // Copyright (c) 2014 Secworks Sweden AB
@@ -48,32 +47,17 @@
                     input wire [1023 : 0] rw_masking_rnd,
                     input wire [4 : 0]    entropy,
 
+                    input wire            capture_cmd,
                     input wire            init_cmd,
                     input wire            next_cmd,
                     output wire masked_reg_t  w_val
                    );
 
-
   //----------------------------------------------------------------
   // Registers including update variables and write enable.
   //----------------------------------------------------------------
   masked_reg_t w_mem [0 : 15];
-  masked_reg_t w_mem00_new;
-  masked_reg_t w_mem01_new;
-  masked_reg_t w_mem02_new;
-  masked_reg_t w_mem03_new;
-  masked_reg_t w_mem04_new;
-  masked_reg_t w_mem05_new;
-  masked_reg_t w_mem06_new;
-  masked_reg_t w_mem07_new;
-  masked_reg_t w_mem08_new;
-  masked_reg_t w_mem09_new;
-  masked_reg_t w_mem10_new;
-  masked_reg_t w_mem11_new;
-  masked_reg_t w_mem12_new;
-  masked_reg_t w_mem13_new;
-  masked_reg_t w_mem14_new;
-  masked_reg_t w_mem15_new;
+  masked_reg_t w_mem_new [0 : 15];
   reg          w_mem_we;
 
   reg [6 : 0] w_ctr_reg;
@@ -86,18 +70,10 @@
   masked_reg_t w_tmp;
   masked_reg_t w_new;
 
-
-  //----------------------------------------------------------------
-  // Concurrent connectivity for ports etc.
-  //----------------------------------------------------------------
   assign w_val = w_tmp;
 
-
   //----------------------------------------------------------------
   // reg_update
-  // Update functionality for all registers in the core.
-  // All registers are positive edge triggered with asynchronous
-  // active low reset. All registers have write enable.
   //----------------------------------------------------------------
   always @ (posedge clk or negedge reset_n)
     begin : reg_update
@@ -117,87 +93,54 @@
           w_ctr_reg <= 7'h0;
         end
         else begin
-          if (w_mem_we)
-            begin
-              w_mem[00] <= w_mem00_new;
-              w_mem[01] <= w_mem01_new;
-              w_mem[02] <= w_mem02_new;
-              w_mem[03] <= w_mem03_new;
-              w_mem[04] <= w_mem04_new;
-              w_mem[05] <= w_mem05_new;
-              w_mem[06] <= w_mem06_new;
-              w_mem[07] <= w_mem07_new;
-              w_mem[08] <= w_mem08_new;
-              w_mem[09] <= w_mem09_new;
-              w_mem[10] <= w_mem10_new;
-              w_mem[11] <= w_mem11_new;
-              w_mem[12] <= w_mem12_new;
-              w_mem[13] <= w_mem13_new;
-              w_mem[14] <= w_mem14_new;
-              w_mem[15] <= w_mem15_new;
-            end
+          if (w_mem_we) begin
+            for (ii = 0; ii < 16; ii = ii + 1)
+              w_mem[ii] <= w_mem_new[ii];
+          end
 
           if (w_ctr_we)
-              w_ctr_reg <= w_ctr_new;
+            w_ctr_reg <= w_ctr_new;
         end
       end
     end // reg_update
 
-
   //----------------------------------------------------------------
   // select_w
-  //
-  // Mux for the external read operation. This is where we exract
-  // the W variable.
   //----------------------------------------------------------------
   always @*
     begin : select_w
-      if (w_ctr_reg < 16)
+      if (w_ctr_reg < 7'd16)
         w_tmp = w_mem[w_ctr_reg[3 : 0]];
       else
         w_tmp = w_new;
     end // select_w
 
-
-  //----------------------------------------------------------------
-  // w_new_logic
-  //
-  // Logic that calculates the next value to be inserted into
-  // the sliding window of the memory.
-  //----------------------------------------------------------------
-      masked_reg_t w_0;
-      masked_reg_t w_1;
-      masked_reg_t w_9;
-      masked_reg_t w_14;
-      masked_reg_t d0;
-      masked_reg_t d1;
-      
-      masked_reg_t w_0_b2a;
-      masked_reg_t w_9_b2a;
-      masked_reg_t d0_b2a;
-      masked_reg_t d1_b2a;
-      
+  //----------------------------------------------------------------
+  // w_new_logic & per-round share refresh
+  //----------------------------------------------------------------
+  masked_reg_t w_0;
+  masked_reg_t w_1;
+  masked_reg_t w_9;
+  masked_reg_t w_14;
+  masked_reg_t d0;
+  masked_reg_t d1;
+
+  masked_reg_t w_0_b2a;
+  masked_reg_t w_9_b2a;
+  masked_reg_t d0_b2a;
+  masked_reg_t d1_b2a;
+
   always @*
     begin : w_mem_update_logic
-
-
-      w_mem00_new = {64'h0, 64'h0};
-      w_mem01_new = {64'h0, 64'h0};
-      w_mem02_new = {64'h0, 64'h0};
-      w_mem03_new = {64'h0, 64'h0};
-      w_mem04_new = {64'h0, 64'h0};
-      w_mem05_new = {64'h0, 64'h0};
-      w_mem06_new = {64'h0, 64'h0};
-      w_mem07_new = {64'h0, 64'h0};
-      w_mem08_new = {64'h0, 64'h0};
-      w_mem09_new = {64'h0, 64'h0};
-      w_mem10_new = {64'h0, 64'h0};
-      w_mem11_new = {64'h0, 64'h0};
-      w_mem12_new = {64'h0, 64'h0};
-      w_mem13_new = {64'h0, 64'h0};
-      w_mem14_new = {64'h0, 64'h0};
-      w_mem15_new = {64'h0, 64'h0};
-      w_mem_we    = 0;
+      integer k;
+      logic [63:0] msg_word;
+      logic [63:0] rnd_word;
+
+      for (k = 0; k < 16; k = k + 1)
+        w_mem_new[k] = {64'h0, 64'h0};
+      w_mem_we = 1'b0;
+      msg_word = 64'h0;
+      rnd_word = 64'h0;
 
       w_0  = w_mem[0];
       w_1  = w_mem[1];
@@ -205,7 +148,6 @@
       w_14 = w_mem[14];
 
       d0 = {ROT1(w_1.masked), ROT1(w_1.random)};
-
       d1 = {ROT14(w_14.masked), ROT14(w_14.random)};
 
       w_0_b2a = B2A_conv(w_0, entropy[0]);
@@ -213,78 +155,57 @@
       w_9_b2a = B2A_conv(w_9, entropy[2]);
       d1_b2a  = B2A_conv(d1,  entropy[3]);
 
-      //w_new = w_0 + d0 + w_9 + d1;
       w_new = A2B_conv(masked_sum(w_0_b2a, masked_sum(d0_b2a, masked_sum(w_9_b2a, d1_b2a))), entropy[4]);
 
-      if (init_cmd)
-        begin
-          w_mem00_new = {block_msg[1023 : 960] ^ rw_masking_rnd[1023 : 960], rw_masking_rnd[1023 : 960]};
-          w_mem01_new = {block_msg[959  : 896] ^ rw_masking_rnd[959  : 896], rw_masking_rnd[959  : 896]};
-          w_mem02_new = {block_msg[895  : 832] ^ rw_masking_rnd[895  : 832], rw_masking_rnd[895  : 832]};
-          w_mem03_new = {block_msg[831  : 768] ^ rw_masking_rnd[831  : 768], rw_masking_rnd[831  : 768]};
-          w_mem04_new = {block_msg[767  : 704] ^ rw_masking_rnd[767  : 704], rw_masking_rnd[767  : 704]};
-          w_mem05_new = {block_msg[703  : 640] ^ rw_masking_rnd[703  : 640], rw_masking_rnd[703  : 640]};
-          w_mem06_new = {block_msg[639  : 576] ^ rw_masking_rnd[639  : 576], rw_masking_rnd[639  : 576]};
-          w_mem07_new = {block_msg[575  : 512] ^ rw_masking_rnd[575  : 512], rw_masking_rnd[575  : 512]};
-          w_mem08_new = {block_msg[511  : 448] ^ rw_masking_rnd[511  : 448], rw_masking_rnd[511  : 448]};
-          w_mem09_new = {block_msg[447  : 384] ^ rw_masking_rnd[447  : 384], rw_masking_rnd[447  : 384]};
-          w_mem10_new = {block_msg[383  : 320] ^ rw_masking_rnd[383  : 320], rw_masking_rnd[383  : 320]};
-          w_mem11_new = {block_msg[319  : 256] ^ rw_masking_rnd[319  : 256], rw_masking_rnd[319  : 256]};
-          w_mem12_new = {block_msg[255  : 192] ^ rw_masking_rnd[255  : 192], rw_masking_rnd[255  : 192]};
-          w_mem13_new = {block_msg[191  : 128] ^ rw_masking_rnd[191  : 128], rw_masking_rnd[191  : 128]};
-          w_mem14_new = {block_msg[127  :  64] ^ rw_masking_rnd[127  :  64], rw_masking_rnd[127  :  64]};
-          w_mem15_new = {block_msg[63   :   0] ^ rw_masking_rnd[63   :   0], rw_masking_rnd[63   :   0]};
-          w_mem_we    = 1;
-        end
-
-      if (next_cmd && (w_ctr_reg > 15))
-        begin
-          w_mem00_new = w_mem[01];
-          w_mem01_new = w_mem[02];
-          w_mem02_new = w_mem[03];
-          w_mem03_new = w_mem[04];
-          w_mem04_new = w_mem[05];
-          w_mem05_new = w_mem[06];
-          w_mem06_new = w_mem[07];
-          w_mem07_new = w_mem[08];
-          w_mem08_new = w_mem[09];
-          w_mem09_new = w_mem[10];
-          w_mem10_new = w_mem[11];
-          w_mem11_new = w_mem[12];
-          w_mem12_new = w_mem[13];
-          w_mem13_new = w_mem[14];
-          w_mem14_new = w_mem[15];
-          w_mem15_new = w_new;
-          w_mem_we    = 1;
-        end
+      if (capture_cmd) begin
+        for (k = 0; k < 16; k = k + 1) begin
+          msg_word = block_msg[(15 - k) * 64 +: 64];
+          rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
+          w_mem_new[k] = {msg_word ^ rnd_word, rnd_word};
+        end
+        w_mem_we = 1'b1;
+      end
+      else if (init_cmd) begin
+        for (k = 0; k < 16; k = k + 1) begin
+          rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
+          w_mem_new[k] = refresh_masked(w_mem[k], rnd_word);
+        end
+        w_mem_we = 1'b1;
+      end
+      else if (next_cmd) begin
+        if (w_ctr_reg < 7'd16) begin
+          for (k = 0; k < 16; k = k + 1) begin
+            rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
+            w_mem_new[k] = refresh_masked(w_mem[k], rnd_word);
+          end
+        end
+        else begin
+          for (k = 0; k < 15; k = k + 1) begin
+            rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
+            w_mem_new[k] = refresh_masked(w_mem[k + 1], rnd_word);
+          end
+          w_mem_new[15] = refresh_masked(w_new, rw_masking_rnd[63 : 0]);
+        end
+        w_mem_we = 1'b1;
+      end
     end // w_mem_update_logic
 
-
   //----------------------------------------------------------------
   // w_ctr
-  // W schedule adress counter. Counts from 0x10 to 0x3f and
-  // is used to expand the block into words.
   //----------------------------------------------------------------
   always @*
     begin : w_ctr
       w_ctr_new = 7'h0;
       w_ctr_we  = 1'h0;
 
-      if (init_cmd)
-        begin
-          w_ctr_new = 7'h00;
-          w_ctr_we  = 1'h1;
-        end
-
-      if (next_cmd)
-        begin
-          w_ctr_new = w_ctr_reg + 7'h01;
-          w_ctr_we  = 1'h1;
-        end
+      if (capture_cmd || init_cmd) begin
+        w_ctr_new = 7'h00;
+        w_ctr_we  = 1'h1;
+      end
+      else if (next_cmd) begin
+        w_ctr_new = w_ctr_reg + 7'h01;
+        w_ctr_we  = 1'h1;
+      end
     end // w_ctr
 
-endmodule // sha512_w_mem
-
-//======================================================================
-// EOF sha512_masked_w_mem.v
-//======================================================================+endmodule

--- a/environment/public/code/sha512_masked_core.sv (Buggy Starter)
+++ b/solution/gold/code/sha512_masked_core.sv (Golden Reference)
@@ -2,9 +2,7 @@
 //
 // sha512_masked_core.sv
 // -------------
-// Verilog 2001 implementation of the SHA-512 hash function.
-// This is the internal core with wide interfaces.
-//
+// Side-channel hardened boolean/arithmetic masked SHA-512 family core.
 //
 // Author: Joachim Strombergson
 // Copyright (c) 2014 Secworks Sweden AB
@@ -36,23 +34,6 @@
 // ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 //
 //======================================================================
-//
-//  Module:
-//      sha512_masked_core.sv
-//
-// The embedded countermeasures for SHA512 is based on
-// "Differential Power Analysis of HMAC Based on SHA-2, and Countermeasures"
-// by McEvoy et. al.
-//
-// The countermeasures are added into the unmasked SHA512 implementation  
-// from Secworks. 
-// 
-// For providing the required random values to mask intermediate values,
-// we use a lightweight LFSR. Based on 
-// "Spin Me Right Round Rotational Symmetry for FPGA-specific AES" by
-// Wegener et. al., LFSR is sufficient for masking statistical randomness.
-//======================================================================
-
 
 module sha512_masked_core
                   import sha512_masked_defines_pkg::*;
@@ -65,11 +46,9 @@
                    input wire            init_cmd,
                    input wire            next_cmd,
                    input wire [1 : 0]    mode,
-                   
+
                    // Data port.
                    input wire [191 : 0]  entropy,
-                   
-
                    input wire [1023 : 0] block_msg,
 
                    output wire           ready,
@@ -77,32 +56,44 @@
                    output wire           digest_valid
                   );
 
-
   //----------------------------------------------------------------
   // Internal constant and parameter definitions.
   //----------------------------------------------------------------
-  localparam SHA512_ROUNDS = 79;
-  localparam SHA512_RNDs   = 8;
-
-  localparam CTRL_IDLE   = 2'h0;
-  localparam CTRL_RND    = 2'h1;
-  localparam CTRL_ROUNDS = 2'h2;
-  localparam CTRL_DONE   = 2'h3;
-
-
-  //----------------------------------------------------------------
-  // Registers including update variables and write enable.
+  localparam [6:0] SHA512_ROUNDS = 7'd79;
+  localparam [6:0] SHA512_RNDs   = 7'd8;
+
+  localparam [1:0] CTRL_IDLE   = 2'h0;
+  localparam [1:0] CTRL_RND    = 2'h1;
+  localparam [1:0] CTRL_ROUNDS = 2'h2;
+  localparam [1:0] CTRL_DONE   = 2'h3;
+
+  localparam [1:0] MODE_SHA512_224 = 2'h0;
+  localparam [1:0] MODE_SHA512_256 = 2'h1;
+  localparam [1:0] MODE_SHA384     = 2'h2;
+  localparam [1:0] MODE_SHA512     = 2'h3;
+
+  //----------------------------------------------------------------
+  // Registers and mask pool.
   //----------------------------------------------------------------
   logic               masking_init;
   logic               masking_update;
   logic [23:0][63:0]  masking_rnd;
+  logic [27:0][63:0]  cur_rnd;
   logic [7:0][63:0]   rh_masking_rnd;
   logic [1023:0]      rw_masking_rnd;
+  logic [4:0]         w_q_rnd;
   logic [9:0]         q_masking_rnd;
+  logic [23:0]        q_done_rnd;
 
   logic init_reg_set;
   logic init_reg_reset;
   logic init_reg;
+
+  logic       mode_we;
+  logic [1:0] mode_reg;
+
+  logic chain_valid_set;
+  logic chain_valid_reg;
 
   masked_reg_t a_reg;
   masked_reg_t a_new;
@@ -122,22 +113,9 @@
   masked_reg_t h_new;
   reg          a_h_we;
 
-  reg [63 : 0] H0_reg;
-  reg [63 : 0] H0_new;
-  reg [63 : 0] H1_reg;
-  reg [63 : 0] H1_new;
-  reg [63 : 0] H2_reg;
-  reg [63 : 0] H2_new;
-  reg [63 : 0] H3_reg;
-  reg [63 : 0] H3_new;
-  reg [63 : 0] H4_reg;
-  reg [63 : 0] H4_new;
-  reg [63 : 0] H5_reg;
-  reg [63 : 0] H5_new;
-  reg [63 : 0] H6_reg;
-  reg [63 : 0] H6_new;
-  reg [63 : 0] H7_reg;
-  reg [63 : 0] H7_new;
+  // Masked two-share chaining state (never stored in plaintext).
+  masked_reg_t H_reg [0 : 7];
+  masked_reg_t H_new [0 : 7];
   reg          H_we;
 
   reg [6 : 0]  round_ctr_reg;
@@ -163,6 +141,7 @@
   reg          rnd_ctr_we;
   reg          rnd_ctr_inc;
   reg          rnd_ctr_rst;
+
   //----------------------------------------------------------------
   // Wires.
   //----------------------------------------------------------------
@@ -181,6 +160,7 @@
 
   wire [63 : 0] k_data;
 
+  reg           w_capture;
   reg           w_init;
   reg           w_next;
   masked_reg_t  w_data;
@@ -194,19 +174,52 @@
   wire [63 : 0] H0_6;
   wire [63 : 0] H0_7;
 
-
-  //----------------------------------------------------------------
-  // Module instantiantions.
+  logic [511 : 0] digest_out;
+
+  //----------------------------------------------------------------
+  // Dynamic combinational mask derivation (zero-cycle entropy injection
+  // combined with persistent 1536-bit evolving mask pool).
+  //----------------------------------------------------------------
+  always @*
+    begin : cur_rnd_gen
+      integer m;
+      for (m = 0; m < 24; m = m + 1) begin
+        cur_rnd[m] = masking_rnd[m] ^ expand_entropy_word(entropy, m);
+      end
+      for (m = 24; m < 28; m = m + 1) begin
+        cur_rnd[m] = rot64(masking_rnd[m - 24], 17) ^
+                     rot64(masking_rnd[m - 16], 43) ^
+                     rot64(masking_rnd[m - 8],  55) ^
+                     expand_entropy_word(entropy, m);
+      end
+    end
+
+  genvar i;
+  generate
+    for (i = 0; i < 8; i = i + 1) begin : rh_masking_assign
+      assign rh_masking_rnd[i] = cur_rnd[i];
+    end
+  endgenerate
+
+  assign rw_masking_rnd = {cur_rnd[08], cur_rnd[09], cur_rnd[10], cur_rnd[11],
+                           cur_rnd[12], cur_rnd[13], cur_rnd[14], cur_rnd[15],
+                           cur_rnd[16], cur_rnd[17], cur_rnd[18], cur_rnd[19],
+                           cur_rnd[20], cur_rnd[21], cur_rnd[22], cur_rnd[23]};
+
+  assign w_q_rnd       = cur_rnd[24][4:0]  ^ entropy[4:0];
+  assign q_masking_rnd = cur_rnd[25][9:0]  ^ entropy[14:5];
+  assign q_done_rnd    = cur_rnd[26][23:0] ^ entropy[38:15];
+
+  //----------------------------------------------------------------
+  // Module instantiations.
   //----------------------------------------------------------------
   sha512_k_constants k_constants_inst(
       .addr(round_ctr_reg),
       .K_val(k_data)
       );
 
-
   sha512_h_constants h_constants_inst(
-      .mode(mode),
-
+      .mode(mode_reg),
       .H0(H0_0),
       .H1(H0_1),
       .H2(H0_2),
@@ -217,7 +230,6 @@
       .H7(H0_7)
       );
 
-
   sha512_masked_w_mem w_mem_inst(
       .clk(clk),
       .reset_n(reset_n),
@@ -225,42 +237,54 @@
 
       .block_msg(block_msg),
       .rw_masking_rnd(rw_masking_rnd),
-      .entropy(entropy[4 : 0]),      
-
+      .entropy(w_q_rnd),
+
+      .capture_cmd(w_capture),
       .init_cmd(w_init),
       .next_cmd(w_next),
       .w_val(w_data)
       );
 
   //----------------------------------------------------------------
-  // Concurrent connectivity for ports etc.
-  //----------------------------------------------------------------
-  assign ready = ready_reg;
-
-  assign digest = {H0_reg, H1_reg, H2_reg, H3_reg,
-                   H4_reg, H5_reg, H6_reg, H7_reg};
-
+  // Concurrent connectivity & gated mode-truncated digest output.
+  //----------------------------------------------
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/sha512_h_constants.v`](environment/public/code/sha512_h_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_k_constants.v`](environment/public/code/sha512_k_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_masked_core.sv`](environment/public/code/sha512_masked_core.sv) **(Editable)**
- [`environment/public/code/sha512_masked_defines_pkg.sv`](environment/public/code/sha512_masked_defines_pkg.sv) **(Editable)**
- [`environment/public/code/sha512_masked_w_mem.sv`](environment/public/code/sha512_masked_w_mem.sv) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

