# case_25004: Harden Caliptra P-384 ECDSA/ECDH Controller Against Degenerate Scalar Faults, PCR Signing Key Leakage, DRBG Desync, and Incomplete Zeroization

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/caliptra-rtl` (`repo_50`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 2: Logic Synthesis & Gate-Level Verification` (`stage2_synth_gate`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/ecc_dsa_ctrl.sv`, `code/ecc_scalar_blinding.sv`, `code/ecc_hmac_drbg_interface.sv`

---

## Problem Specification

# Caliptra P-384 ECDSA/ECDH Controller: Degenerate-Operand Fault Containment, `PCR_SIGN` Isolation, DRBG Handshake, & Zeroization

## Context
Caliptra's elliptic-curve subsystem (`code/ecc_top.sv`) orchestrates NIST P-384 `KEYGEN`, RFC 6979 deterministic `SIGN`, hardware quote `PCR_SIGN`, `VERIFY`, and `DH_SHAREDKEY` (ECDH) with 192-bit additive scalar blinding (`d' = d + r * GROUP_ORDER`), Coron point randomization, and KeyVault client transfers. Security and fault-injection sign-off identified coupled vulnerabilities across `code/ecc_dsa_ctrl.sv`, `code/ecc_scalar_blinding.sv`, and `code/ecc_hmac_drbg_interface.sv` where degenerate scalars/masks/outputs commit to CSRs or KeyVault, `pcr_ecc_signing_privkey` leaks across CSRs or subsequent commands, DRBG handshakes drop pulses under `hmac_drbg` stalls or retain cross-command secrets, and mid-run `zeroize` leaves residual state. Harden **only** those three RTL files while preserving all module ports and read-only files.

## Architectural & Security Requirements
1. **Scalar Blinding & 192-Bit Mask Rejection (`code/ecc_scalar_blinding.sv`, `code/ecc_hmac_drbg_interface.sv`, `code/ecc_dsa_ctrl.sv`)**:
   - For valid inputs (`1 <= data_i < GROUP_ORDER` and `rnd_i != '0`), `ecc_scalar_blinding` must output `data_o = data_i + rnd_i * GROUP_ORDER`. If enabled (`en_i`) with `data_i == '0`, `data_i >= GROUP_ORDER`, or `rnd_i == '0`, clear internal working/accumulator/output state so `data_o == '0` and return `busy_o == 1'b0` without hanging or passing an unblinded scalar.
   - Because scalar blinding consumes `scalar_rnd[191:0]` (`RND_SIZE = 192`), `ecc_hmac_drbg_interface` must reject any blinding-mask round whose lower 192 bits equal `'0` and re-request `hmac_drbg_next` until `scalar_rnd[191:0] != '0` (unless aborted by `zeroize`). If a degenerate input scalar, zero 192-bit mask slice, or zero 576-bit blinded scalar reaches the controller's blinding step, suppress writing the scalar to `ecc_arith_unit` and raise an internal error fault.
2. **Degenerate Operand/Output Fault Containment & Zero-Commit Suppression (`code/ecc_dsa_ctrl.sv`)**:
   - Trigger and latch an internal error fault (pulsing `error_internal_sts` for `error_intr` and returning idle with `ECC_STATUS.VALID == 0` and `ECC_STATUS.VERIFY_PASS == 0` until cleared by `zeroize`) whenever any operand or result is degenerate/out-of-range: `privkey == 0` or `>= GROUP_ORDER` (`SIGN`, `KEYGEN`, `DH_SHAREDKEY`); `r == 0`, `r >= GROUP_ORDER`, `s == 0`, or `s >= GROUP_ORDER` (`SIGN`, `VERIFY`); `pubkey_x >= PRIME` or `pubkey_y >= PRIME` (`KEYGEN`, `VERIFY`, `DH_SHAREDKEY`); off-curve check `pk_chk != 0` (`VERIFY`, `DH_SHAREDKEY`); or `sharedkey == 0` or `>= PRIME` (`DH_SHAREDKEY`).
   - Whenever an error fault triggers or remains latched: suppress writes and clear all output CSRs (`ECC_PRIVKEY_OUT`, `ECC_PUBKEY_X`, `ECC_PUBKEY_Y`, `ECC_SIGN_R`, `ECC_SIGN_S`, `ECC_DH_SHARED_KEY`, `ECC_VERIFY_R` — noting hardware `.we` overrides `.hwclr` in `ecc_reg.sv`) so neither faulted nor partial outputs remain readable; block KeyVault writeback (`kv_write.write_en == 0`); clear `ECC_KV_WR_PKEY_CTRL.write_en`, `ECC_KV_WR_PKEY_STATUS.VALID`, `ECC_PRIVKEY_IN`, `ECC_SEED`, and KeyVault staging/residency state; and abort active DRBG/blinding sub-operations so `ECC_STATUS.READY` returns cleanly to `1'b1`.
3. **Hardware `PCR_SIGN` Attestation Key Isolation (`code/ecc_dsa_ctrl.sv`)**:
   - Permit `ECC_CTRL.PCR_SIGN` **only** when idle with no latched error fault, launched exclusively as `SIGN` (`ECC_CTRL.CTRL == 2'b10` and `DH_SHAREDKEY == 1'b0`), and with no KeyVault read/write active, armed (`read_en`/`write_en`), or holding resident key/seed data. Any other `PCR_SIGN` assertion must immediately fault without loading `pcr_signing_data` into `ECC_PRIVKEY_IN` or `ECC_MSG`.
   - On a valid `PCR_SIGN`, lock `ECC_PRIVKEY_IN` against software writes while active, and immediately clear both `ECC_PRIVKEY_IN` and `ECC_MSG` upon `PCR_SIGN` completion, fault abort, or `zeroize` so `pcr_ecc_signing_privkey` cannot be reused by subsequent `SIGN` or `DH_SHAREDKEY` commands.
4. **Stall-Safe DRBG Handshake, Secret Freshness & Mid-Operation Sanitization (`code/ecc_hmac_drbg_interface.sv`, `code/ecc_scalar_blinding.sv`, `code/ecc_dsa_ctrl.sv`)**:
   - `ecc_hmac_drbg_interface` must assert `ready` only when idle, `!zeroize`, and `hmac_drbg_ready == 1'b1`; snapshot `counter_nonce` and `sca_entropy` only on `en && ready`; hold `hmac_drbg_init`/`hmac_drbg_next` until accepted by `hmac_drbg_ready == 1'b1` (never asserting commands during `zeroize`); and clear `lambda`, `scalar_rnd`, `masking_rnd`, and `drbg` outputs on every `en && ready` launch so commands skipping states never retain prior-command secrets.
   - Asserting `ECC_CTRL.ZEROIZE` or `debugUnlock_or_scan_mode_switch` in idle or mid-operation must wipe all internal seed/nonce/entropy/mask/scalar/staging registers across all three modules, clear all secret/output CSRs plus KeyVault `read_en`/`write_en` and `VALID` status bits, clear latched faults, and recover cleanly to `ECC_STATUS.READY == 1'b1` (`busy_o == 1'b0`). Synthesize cleanly (`yosys -m slang`) with zero inferred latches and zero combinational loops (`scc -expect 0`).

---

## Build, Simulation, and EDA Verification Instructions

# Caliptra P-384 ECDSA / ECDH Subsystem — Build & Lint Reference

## Editable RTL Modules
Only the following three files may be modified:
- `code/ecc_dsa_ctrl.sv`
- `code/ecc_scalar_blinding.sv`
- `code/ecc_hmac_drbg_interface.sv`

All other SystemVerilog packages, headers, register blocks, KeyVault clients, HMAC-DRBG cores, and P-384 arithmetic modules under `code/` are read-only reference dependencies and must remain unmodified.

## Verilator Compile / Lint Order
```bash
verilator --lint-only -Wno-fatal -DSYNTHESIS -Icode --top-module ecc_top \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_util_pkg.sv \
  code/caliptra_prim_cipher_pkg.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_sparse_fsm_flop.sv \
  code/caliptra_prim_lfsr.sv \
  code/ahb_defines_pkg.sv \
  code/kv_defines_pkg.sv \
  code/kv_fsm.sv \
  code/kv_read_rule_check.sv \
  code/kv_write_rule_check.sv \
  code/kv_read_client.sv \
  code/kv_write_client.sv \
  code/ahb_slv_sif.sv \
  code/sha512_masked_defines_pkg.sv \
  code/sha512_h_constants.v \
  code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv \
  code/sha512_masked_core.sv \
  code/hmac_param_pkg.sv \
  code/hmac_core.sv \
  code/hmac_drbg.sv \
  code/ecc_params_pkg.sv \
  code/ecc_defines_pkg.sv \
  code/ecc_dsa_uop_pkg.sv \
  code/ecc_pm_uop_pkg.sv \
  code/ecc_reg_pkg.sv \
  code/ecc_reg.sv \
  code/ecc_adder.sv \
  code/ecc_add_sub_mod_alter.sv \
  code/ecc_mult_dsp.sv \
  code/ecc_pe_first.sv \
  code/ecc_pe.sv \
  code/ecc_pe_final.sv \
  code/ecc_montgomerymultiplier.sv \
  code/ecc_fau.sv \
  code/ecc_ram_tdp_file.sv \
  code/ecc_pm_sequencer.sv \
  code/ecc_pm_ctrl.sv \
  code/ecc_arith_unit.sv \
  code/ecc_scalar_blinding.sv \
  code/ecc_hmac_drbg_interface.sv \
  code/ecc_dsa_sequencer.sv \
  code/ecc_dsa_ctrl.sv \
  code/ecc_top.sv
```

## Synthesis & Combinational-Loop Sign-Off
All three editable modules must remain cleanly synthesizable under `yosys -m slang` (`proc; opt; check -assert; scc -expect 0`) with **zero inferred latches** and **zero combinational loops**, and must preserve their exact top-level port declarations and parameters.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ecc_dsa_ctrl.sv`
- `code/ecc_scalar_blinding.sv`
- `code/ecc_hmac_drbg_interface.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
