# case_25005: Harden Caliptra HMAC-384/512 & SP 800-90A HMAC_DRBG Prime Rejection, KeyVault Isolation, AHB Word Guards, and Zeroize/Debug Sanitization

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/caliptra-rtl` (`repo_50`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 2: Logic Synthesis & Gate-Level Verification` (`stage2_synth_gate`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/hmac.sv`, `code/hmac_ctrl.sv`, `code/hmac_drbg.sv`

---

## Problem Specification

# Caliptra HMAC-384/512 & SP 800-90A HMAC_DRBG Asset Isolation, Rejection Sampling, and Lifecycle Sanitization

## Context

In Caliptra's Root-of-Trust cryptographic subsystem, `code/hmac_ctrl.sv` bridges the 64-bit SoC/uC AHB-Lite slave port to `code/hmac.sv` (managing PeakRDL CSRs, KeyVault read/write clients, and `hmac_core`), while `code/hmac_drbg.sv` drives `hmac_core` to implement NIST SP 800-90A Rev. 1 §10.1.2 / RFC 6979 deterministic scalar generation modulo `HMAC_DRBG_PRIME` (P-384 group order).

Security bring-up across `code/hmac_drbg.sv`, `code/hmac.sv`, and `code/hmac_ctrl.sv` identified cross-module vulnerabilities in prime-order rejection state updates, KeyVault-vs-CSR asset isolation, mid-operation TOCTOU register locking, malformed AHB access handling, and debug/zeroize sanitization. Harden **only** `code/hmac_drbg.sv`, `code/hmac.sv`, and `code/hmac_ctrl.sv` without altering module port interfaces or read-only files in `code/`.

## Security & Architectural Requirements

### 1. SP 800-90A / RFC 6979 Scalar DRBG (`code/hmac_drbg.sv`)
- **Instantiation & Command Filtering**: After reset or `zeroize`, the DRBG is uninstantiated and must ignore `next_cmd` until instantiated by an accepted `init_cmd`. Simultaneous `init_cmd && next_cmd` is invalid and must be ignored without dropping `ready` or disturbing any held `valid`/`drbg` output. Snapshot `entropy`, `nonce`, and `lfsr_seed` on command acceptance so external input transitions or command glitches while busy cannot perturb multi-step derivation.
- **Prime-Order Rejection Sampling**: Every 384-bit candidate $T$ must strictly satisfy $1 \le T < \text{HMAC\_DRBG\_PRIME}$ (rejecting both $T = 0$ and $T \ge \text{HMAC\_DRBG\_PRIME}$). On rejection, update internal $V$ to the generated candidate $T$ before executing the SP 800-90A rejection update ($K \leftarrow \text{HMAC}_K(V \parallel \text{0x00})$, $V \leftarrow \text{HMAC}_K(V)$) and retrying. Keep `ready == 0`, `valid == 0`, and `drbg == '0` throughout all intermediate and rejection rounds until an in-range scalar completes.
- **Zeroization**: Asserting `zeroize` in any state must immediately abort active HMAC/rejection rounds, clear internal $K$/$V$/latched-input state and outputs (`drbg`, `valid`, `ready`), mark the DRBG uninstantiated, and restore `ready` once `zeroize` deasserts and the underlying core is ready.

### 2. KeyVault Asset Isolation & TOCTOU Protection (`code/hmac.sv`)
- **Gap-Free Busy & Control Lockout**: Assert `busy_o` (and deassert `HMAC512_STATUS.READY`) continuously without single-cycle gaps from KeyVault read initiation through KeyVault transfer completion, core hashing, and full KeyVault tag writeback; reflect pending launch cycles in KeyVault status `READY` bits. Lock `HMAC512_CTRL` mode/trigger fields and `HMAC512_KV_WR_CTRL` against software modification while busy or sanitizing.
- **Key & Block Source Isolation**: Starting a KeyVault key or block read must clear all software `HMAC512_KEY[0..15]` or `HMAC512_BLOCK[0..31]` dwords beforehand so shorter KeyVault entries never mix with stale software dwords or mask key-size/key-mode checks. Because `hmac_core` samples key and message blocks dozens of cycles after launch, keep KeyVault-populated key and block registers write-locked against software TOCTOU overwrites (and block `CSR_MODE` override whenever a KeyVault key read or KeyVault key data is active) until KeyVault asset consumption finishes or is sanitized. Suppress core launch whenever key-mode, zero-key, or lone-`LAST` errors are flagged.
- **Destination Tag Isolation**: Whenever KeyVault tag writeback is armed (`HMAC512_KV_WR_CTRL.write_en`) or in progress, immediately clear and hold `HMAC512_TAG[0..15]` at `32'h0` so KeyVault-destined derived secrets and prior CSR tag residue cannot be read via CSRs. For non-KeyVault destinations, zero-mask the lower 128 bits of `HMAC512_TAG` in HMAC-384 mode.

### 3. AHB-Lite Access Enforcement & Debug/Zeroize Sanitization (`code/hmac_ctrl.sv`, `code/hmac.sv`)
- **32-Bit Aligned Word Enforcement**: Every active AHB-Lite transfer (`hsel_i && hready_i && htrans_i[1]`) must be an aligned 32-bit word (`hsize_i == 3'b010`, `haddr_i[1:0] == 2'b00`). Reject byte, halfword, 64-bit, or unaligned transfers with a compliant 2-cycle AHB `H_ERROR` response, zeroed `hrdata_o`, and suppressed register select/write strobes.
- **Zeroize & Debug/Scan Switch**: Either `HMAC512_CTRL.ZEROIZE` or `debugUnlock_or_scan_mode_switch` must immediately abort in-flight core and KeyVault client operations and sanitize all key, block, tag, LFSR seed, `CSR_MODE`, error, and KeyVault control/status state (even if triggered while busy). While `debugUnlock_or_scan_mode_switch` is high, mask `cptra_csr_hmac_key`, block AHB writes, and return `'0` on AHB reads without stalling `hreadyout_o`.

Both `hmac_drbg` and `hmac_ctrl` must synthesize cleanly (`yosys -m slang`) with zero inferred latches and zero combinational loops.

---

## Build, Simulation, and EDA Verification Instructions

The RTL bundle in `code/` is extracted from `chipsalliance/caliptra-rtl` (`src/hmac/rtl`, `src/hmac_drbg/rtl`, `src/sha512_masked/rtl`, `src/keyvault/rtl`, `src/libs/rtl`, and `src/caliptra_prim/rtl`).

Editable files:
- `code/hmac_drbg.sv`
- `code/hmac.sv`
- `code/hmac_ctrl.sv`

All remaining `.sv`, `.v`, and `.svh` files in `code/` are read-only dependencies.

When compiling with Verilator or Slang/Yosys from the workspace root, pass `-Icode` and list package files before module files:

```bash
verilator --lint-only -sv -Wno-fatal -Icode --top-module hmac_ctrl \
  code/caliptra_prim_util_pkg.sv \
  code/caliptra_prim_mubi_pkg.sv \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_cipher_pkg.sv \
  code/ahb_defines_pkg.sv \
  code/kv_defines_pkg.sv \
  code/sha512_masked_defines_pkg.sv \
  code/hmac_param_pkg.sv \
  code/hmac_reg_pkg.sv \
  code/sha512_h_constants.v \
  code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv \
  code/sha512_masked_core.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_sparse_fsm_flop.sv \
  code/caliptra_prim_lfsr.sv \
  code/ahb_slv_sif.sv \
  code/kv_fsm.sv \
  code/kv_read_rule_check.sv \
  code/kv_write_rule_check.sv \
  code/kv_read_client.sv \
  code/kv_write_client.sv \
  code/hmac_core.sv \
  code/hmac_reg.sv \
  code/hmac.sv \
  code/hmac_ctrl.sv

verilator --lint-only -sv -Wno-fatal -Icode --top-module hmac_drbg \
  code/caliptra_prim_util_pkg.sv \
  code/caliptra_prim_mubi_pkg.sv \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_cipher_pkg.sv \
  code/sha512_masked_defines_pkg.sv \
  code/hmac_param_pkg.sv \
  code/sha512_h_constants.v \
  code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv \
  code/sha512_masked_core.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_lfsr.sv \
  code/hmac_core.sv \
  code/hmac_drbg.sv
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/hmac.sv`
- `code/hmac_ctrl.sv`
- `code/hmac_drbg.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
