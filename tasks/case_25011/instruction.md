# case_25011: Harden Caliptra Masked SHA-512 Share Non-Cancellation, Per-Round Refreshing, Masked Chaining, and Synchronous Zeroize

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/caliptra-rtl` (`repo_50`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/sha512_masked_defines_pkg.sv`, `code/sha512_masked_w_mem.sv`, `code/sha512_masked_core.sv`

---

## Problem Specification

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

## Build, Simulation, and EDA Verification Instructions

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

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/sha512_masked_defines_pkg.sv`
- `code/sha512_masked_w_mem.sv`
- `code/sha512_masked_core.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
