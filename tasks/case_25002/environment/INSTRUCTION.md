# case_25002: Harden Caliptra Deobfuscation Engine (DOE) Sparse-FSM Fault Containment, Sticky Flow Locks, and Secret Sanitization

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/caliptra-rtl` (`repo_50`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/doe_fsm.sv`, `code/doe_ctrl.sv`, `code/doe_key_mem.sv`

---

## Problem Specification

# Caliptra Deobfuscation Engine (DOE): Gate-Level Sparse-FSM Fault Hardening, Sticky Flow Locks, & Secret Sanitization

## Context
Caliptra's Deobfuscation Engine (`code/doe_ctrl.sv`, `code/doe_fsm.sv`, `code/doe_key_mem.sv`) unwraps fuse-provisioned `DOE_UDS` (512b), `DOE_FE` (256b), and `DOE_HEK` (256b) secrets via AES-256-CBC into KeyVault without exposing secret dwords on AHB-Lite. Post-synthesis fault-injection and security sign-off uncovered coupled vulnerabilities where Yosys Nangate45 synthesis prunes sparse-FSM redundancy, single-bit state upsets leak KeyVault writes or round keys, sticky flow locks and CSR lockouts can be bypassed, and AES-256 key-expansion residue survives `zeroize`. Harden the three editable RTL files so both RTL simulation and synthesized Nangate45 (`pdk/NangateOpenCellLibrary_typical.lib`) gate-level single-bit fault injection pass.

## Security & Cross-Stage Sign-Off Requirements
1. **Synthesis-Preserved Sparse FSM & 1-Cycle Fault Containment (`code/doe_fsm.sv`, `code/doe_ctrl.sv`)**:
   - Encode the 8 DOE sequencer states on `kv_doe_fsm_ps` (`>= 10` bits, pairwise Hamming distance `>= 3`) so all sparse state flip-flops and undefined-state detection logic survive standard `yosys -m slang` synthesis + `dfflibmap`/`abc` mapping to Nangate45 without state re-encoding or unreachable-branch pruning, and with zero latches and zero combinational loops (`scc -expect 0`).
   - On `DOE_ERROR` or any undefined/glitched state encoding (including any single-bit flip in the synthesized gate-level state flip-flops during idle, key expansion, decryption, or KeyVault writeback): combinationally assert `doe_fsm_error`, suppress KeyVault write enable/data/dest_valid and AES core start/step strobes, avoid setting any flow-done lock, latch stably in sticky `DOE_ERROR` until `!rst_b` (even across `zeroize` / `clear_obf_secrets`), keep `DOE_STATUS.ERROR` asserted while blocking new commands, and trigger hardware secret zeroization so all key-schedule, IV, and CBC state clears within 1 clock cycle.
2. **Pre-Dispatch Policy, Rejection & Monotonic Cold-Reset Flow Locks (`code/doe_fsm.sv`)**:
   - Authorize `DOE_UDS` and `DOE_FE` only when their respective flow lock is `0` and destination is a Standard KeyVault slot (`0 .. 15`); authorize `DOE_HEK` only when unlocked, `ocp_lock_en == 1'b1`, and destination equals `OCP_LOCK_HEK_SEED_KV_SLOT` (`5'd22`), forwarding `ocp_lock_en` into KeyVault write rule metrics.
   - Reject locked, out-of-policy, or reserved/invalid command encodings immediately in idle without starting key expansion or KeyVault writes: assert `DOE_STATUS.ERROR` and `DOE_STATUS.VALID` and auto-clear `DOE_CTRL.CMD`/`CMD_EXT` so the engine returns ready.
   - Reset UDS/FE/HEK flow locks **only** on cold power-good reset (`!cptra_pwrgood` / `!hard_rst_b`), preserving them across warm `!reset_n` resets and `DOE_CLEAR`. Set a flow lock only upon full, error-free, un-aborted unwrap completion; if KeyVault rejects any beat (`kv_wr_resp.error` or write-rule denial), abort remaining beats with `DOE_STATUS.ERROR` without locking the flow.
3. **AHB CSR Lockout & In-Flight Tamper Protection (`code/doe_ctrl.sv`, `code/doe_fsm.sv`)**:
   - Block all AHB writes to `DOE_IV[0..3]` (`0x000..0x00c`) and `DOE_CTRL` (`0x010`) whenever `doe_cmd_lock` or `doe_fsm_error` is asserted (preserving CSR reads and `0x800+` interrupt CSR writes). While `busy_o` is high, block AHB writes to `DOE_IV[0..3]` and non-`DOE_CLEAR` writes to `DOE_CTRL` (permitting emergency `DOE_CLEAR` only when unlocked and unfaulted), and latch command/destination at dispatch so mid-flight changes cannot redirect KeyVault writes.
4. **Complete AES-256 Key-Schedule Sanitization & Recovery (`code/doe_key_mem.sv`, `code/doe_fsm.sv`)**:
   - On `zeroize` in any state, clear all 15 AES-256 round keys (`0..14`), all key-expansion working/rcon/counter/ready registers, and return key expansion to idle within 1 clock cycle, while combinationally masking round-key and S-box outputs to `'0` during `zeroize` (and masking round-key reads for round indices `> 14`).
   - After `DOE_CLEAR` or `debugUnlock_or_scan_mode_switch` deasserts (when unlocked and unfaulted), recover cleanly to idle so subsequent authorized commands unwrap accurately into any requested non-zero valid slot.

## Deliverables
Modify only `code/doe_fsm.sv`, `code/doe_ctrl.sv`, and `code/doe_key_mem.sv`; keep all module port signatures and read-only `code/` and `pdk/` files unchanged.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Synthesis, & Gate-Level Fault-Injection Guide

## Workspace Layout

- `code/doe_ctrl.sv` *(editable)* — Top-level AHB-Lite DOE controller wrapping `ahb_slv_sif` and `doe_cbc`.
- `code/doe_fsm.sv` *(editable)* — Sparse-encoded DOE command/KeyVault sequencer and flow-lock controller.
- `code/doe_key_mem.sv` *(editable)* — AES-256 round-key expansion engine and 15-round key storage.
- `code/*.sv`, `code/*.svh` *(read-only)* — Caliptra DOE AES-256-CBC datapath (`doe_cbc.sv`, `doe_core_cbc.sv`, `doe_encipher_block.sv`, `doe_decipher_block.sv`, `doe_sbox.sv`, `doe_inv_sbox.sv`), PeakRDL register block (`doe_reg_pkg.sv`, `doe_reg.sv`), KeyVault rule checker (`kv_defines_pkg.sv`, `kv_write_rule_check.sv`), AHB interface (`ahb_defines_pkg.sv`, `ahb_slv_sif.sv`), and `caliptra_prim` primitives.
- `pdk/NangateOpenCellLibrary_typical.lib` *(read-only)* — Nangate 45nm standard-cell Liberty library used for gate-level synthesis and post-synthesis single-bit state-flip fault-injection verification.

Do not modify read-only files or create symlinks anywhere in the workspace.

---

## 1. RTL Compilation Order (Verilator 5.038)

Compile the subsystem packages and modules in dependency order with `-Icode`:

```bash
verilator --binary --timing -Wno-fatal -sv -Icode -CFLAGS -O0 \
  code/config_defines.svh \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_mubi_pkg.sv \
  code/ahb_defines_pkg.sv \
  code/kv_defines_pkg.sv \
  code/doe_defines_pkg.sv \
  code/doe_reg_pkg.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_sparse_fsm_flop.sv \
  code/ahb_slv_sif.sv \
  code/kv_write_rule_check.sv \
  code/doe_sbox.sv \
  code/doe_inv_sbox.sv \
  code/doe_encipher_block.sv \
  code/doe_decipher_block.sv \
  code/doe_key_mem.sv \
  code/doe_core_cbc.sv \
  code/doe_reg.sv \
  code/doe_fsm.sv \
  code/doe_cbc.sv \
  code/doe_ctrl.sv \
  /tmp/my_doe_driver.sv --top-module my_doe_driver -Mdir /tmp/obj_doe
```

---

## 2. Cross-Stage Nangate45 Gate-Level Synthesis (`yosys -m slang`)

Sign-off synthesizes the complete `doe_ctrl` hierarchy to Nangate45 standard cells (`DFF_X*`, `DFFR_X*`, `DFFS_X*`, `DFFRS_X*`, and combinational gates) and checks zero inferred latches, zero combinational loops (`scc -expect 0`), and preservation of all `>= 10` sparse state flip-flops (`kv_doe_fsm_ps`) in `doe_fsm`:

```bash
yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode \
    code/config_defines.svh \
    code/caliptra_prim_pkg.sv \
    code/caliptra_prim_mubi_pkg.sv \
    code/ahb_defines_pkg.sv \
    code/kv_defines_pkg.sv \
    code/doe_defines_pkg.sv \
    code/doe_reg_pkg.sv \
    code/caliptra_prim_generic_flop.sv \
    code/caliptra_prim_flop.sv \
    code/caliptra_prim_sparse_fsm_flop.sv \
    code/ahb_slv_sif.sv \
    code/kv_write_rule_check.sv \
    code/doe_sbox.sv \
    code/doe_inv_sbox.sv \
    code/doe_encipher_block.sv \
    code/doe_decipher_block.sv \
    code/doe_key_mem.sv \
    code/doe_core_cbc.sv \
    code/doe_reg.sv \
    code/doe_fsm.sv \
    code/doe_cbc.sv \
    code/doe_ctrl.sv --top doe_ctrl;
  synth -top doe_ctrl;
  select -assert-none t:\$dlatch*;
  check -assert;
  scc -expect 0;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean;
  write_json /tmp/doe_gate.json;
  write_verilog -noattr /tmp/doe_gate.v
"
```

---

## 3. Gate-Level Simulation & Single-Bit State-Flip Fault Injection (`iverilog`)

You can extract behavioral Verilog cell models directly from `pdk/NangateOpenCellLibrary_typical.lib` via Yosys (replacing `DFF*` sequential cells with single-register models where `Q = q_reg` and `QN = ~q_reg` so flipping `q_reg` coherently flips both `Q` and `QN`) and simulate `/tmp/doe_gate.v` using `iverilog -g2012`:

```bash
yosys -q -p "
  read_liberty -ignore_miss_func pdk/NangateOpenCellLibrary_typical.lib;
  proc;
  write_verilog -noattr /tmp/nangate45_cells.v
"
iverilog -g2012 -o /tmp/doe_gate_sim /tmp/nangate45_cells.v /tmp/doe_gate.v /tmp/my_gate_harness.sv
vvp /tmp/doe_gate_sim
```

Inspect `/tmp/doe_gate.json` to verify that all `>= 10` state `DFF*` cells driving `kv_doe_fsm_ps` survive `synth -top doe_ctrl` without FSM re-encoding or redundant-bit pruning, and verify that flipping any single state `DFF*` bit during an active unwrap immediately suppresses `kv_write`, asserts sticky `doe_fsm_error`, and zeroes `doe_key_mem` within 1 clock cycle.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/doe_fsm.sv`
- `code/doe_ctrl.sv`
- `code/doe_key_mem.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
