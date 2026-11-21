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
