# `case_25004`: Harden Caliptra P-384 ECDSA/ECDH Controller Against Degenerate Scalar Faults, PCR Signing Key Leakage, DRBG Desync, and Incomplete Zeroization

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25004` |
| **Source Silicon Repository** | `chipsalliance/caliptra-rtl` (`repo_50`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 2: Logic Synthesis & Gate-Level Verification** (`stage2_synth_gate`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Yosys+Slang Standard-Cell Synthesis, Cell-Area Caps & 4-State Gate-Level X-Propagation Verification) |
| **Primary Hardware Domain** | `Security_RoT_Subsystems` (Security_RoT_Subsystems) |
| **Multi-Domain Tags** | `Security_RoT_Subsystems` |
| **Editable Files (`allowed_edits`)** | [`code/ecc_dsa_ctrl.sv`](environment/public/code/ecc_dsa_ctrl.sv), [`code/ecc_scalar_blinding.sv`](environment/public/code/ecc_scalar_blinding.sv), [`code/ecc_hmac_drbg_interface.sv`](environment/public/code/ecc_hmac_drbg_interface.sv) (3 files, 1712 LOC) |
| **Public Subsystem Context** | 56 RTL files (15148 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

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

## 3. Build & Verification Instructions (`BUILD.md`)

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

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ecc_dsa_ctrl.sv (Buggy Starter)
+++ b/solution/gold/code/ecc_dsa_ctrl.sv (Golden Reference)
@@ -198,6 +198,13 @@
     kv_write_filter_metrics_t kv_write_metrics;
 
     logic pcr_sign_mode;
+    logic [2:0] raw_cmd_req;
+    logic kv_any_active;
+    logic pcr_sign_valid_launch;
+    logic pcr_signing_active;
+    logic pcr_sign_done;
+    logic scalar_blind_fault;
+    logic fault_active;
     
     instr_struct_t prog_instr;
     
@@ -257,7 +264,7 @@
         .addr_i(prog_instr.mem_addr),
         .wr_op_sel_i(prog_instr.opcode.op_sel),
 
-        .wr_en_i(prog_instr.opcode.wr_en),
+        .wr_en_i(prog_instr.opcode.wr_en & ~fault_active),
         .rd_reg_i(prog_instr.opcode.rd_en),
         .data_i(write_reg),
         .data_o(read_reg),
@@ -271,7 +278,7 @@
         ecc_hmac_drbg_interface_i (
         .clk(clk),
         .reset_n(reset_n),
-        .zeroize(zeroize_reg),
+        .zeroize(zeroize_reg | error_flag_reg),
         .hmac_mode(hmac_mode),
         .en(hmac_init),
         .ready(hmac_ready),
@@ -295,7 +302,7 @@
         ecc_scalar_blinding_i(
         .clk(clk),
         .reset_n(reset_n),
-        .zeroize(zeroize_reg),
+        .zeroize(zeroize_reg | error_flag_reg),
         .en_i(scalar_sca_en),
         .data_i(scalar_in_reg),
         .rnd_i(scalar_rnd_reg[RND_SIZE-1 : 0]),
@@ -326,7 +333,7 @@
             kv_seed_data_present <= '0;
             kv_key_data_present  <= '0;
         end
-        else if (zeroize_reg) begin
+        else if (zeroize_reg | fault_active) begin
             privkey_we_reg       <= '0;
             sharedkey_we_reg     <= '0;
             kv_reg               <= '0;
@@ -335,9 +342,9 @@
         end
         //Store private key here before pushing to keyvault
         else begin
-            privkey_we_reg <= hw_privkey_we;
+            privkey_we_reg   <= hw_privkey_we;
             sharedkey_we_reg <= hw_sharedkey_we;
-            if (secretkey_we & (dest_keyvault | kv_seed_data_present))            
+            if (secretkey_we & (dest_keyvault | kv_seed_data_present))
                 kv_reg <= read_reg;
 
             kv_seed_data_present <= kv_seed_data_present_set ? '1 :
@@ -347,7 +354,7 @@
         end
     end
 
-    always_comb secretkey_we = (privkey_we_reg | sharedkey_we_reg);
+    always_comb secretkey_we = (privkey_we_reg | sharedkey_we_reg) & ~zeroize_reg & ~fault_active;
 
     assign error_intr = hwif_out.intr_block_rf.error_global_intr_r.intr;
     assign notif_intr = hwif_out.intr_block_rf.notif_global_intr_r.intr;
@@ -369,29 +376,26 @@
     
     always_comb begin // ecc_reg_writing
         for (int dword=0; dword < 12; dword++)begin
-            //Key Vault has priority if enabled to drive these registers
-            //don't store the private key generated in sw accessible register if it's going to keyvault
             privkey_reg[dword] = hwif_out.ECC_PRIVKEY_IN[11-dword].PRIVKEY_IN.value;
-            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.we = (pcr_sign_mode | (kv_privkey_write_en & (kv_privkey_write_offset == dword))) & !zeroize_reg;
-            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.next = pcr_sign_mode       ? pcr_signing_data.pcr_ecc_signing_privkey[dword] : 
-                                                            kv_privkey_write_en ? kv_privkey_write_data : 
-                                                                                  read_reg[11-dword];
-            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.hwclr = zeroize_reg | kv_key_data_present_reset | (kv_privkey_error != KV_SUCCESS);
-            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.swwe = ecc_ready_reg & ~kv_key_data_present;
-        end 
-
-        for (int dword=0; dword < 12; dword++)begin
-            //If keyvault is not enabled, grab the sw value as usual
-            hwif_in.ECC_PRIVKEY_OUT[dword].PRIVKEY_OUT.we = (privkey_we_reg & ~(dest_keyvault | kv_seed_data_present)) & !zeroize_reg;
+            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.we = (pcr_sign_valid_launch | (kv_privkey_write_en & (kv_privkey_write_offset == dword))) & !zeroize_reg & !fault_active;
+            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.next = pcr_sign_valid_launch ? pcr_signing_data.pcr_ecc_signing_privkey[dword] :
+                                                            kv_privkey_write_en   ? kv_privkey_write_data :
+                                                                                    read_reg[11-dword];
+            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.hwclr = zeroize_reg | fault_active | pcr_sign_done | kv_key_data_present_reset | (kv_privkey_error != KV_SUCCESS);
+            hwif_in.ECC_PRIVKEY_IN[dword].PRIVKEY_IN.swwe = ecc_ready_reg & ~kv_key_data_present & ~pcr_signing_active;
+        end
+
+        for (int dword=0; dword < 12; dword++)begin
+            hwif_in.ECC_PRIVKEY_OUT[dword].PRIVKEY_OUT.we = (privkey_we_reg & ~(dest_keyvault | kv_seed_data_present)) & !zeroize_reg & !fault_active;
             hwif_in.ECC_PRIVKEY_OUT[dword].PRIVKEY_OUT.next = read_reg[11-dword];
-            hwif_in.ECC_PRIVKEY_OUT[dword].PRIVKEY_OUT.hwclr = zeroize_reg;
+            hwif_in.ECC_PRIVKEY_OUT[dword].PRIVKEY_OUT.hwclr = zeroize_reg | fault_active;
         end
 
         for (int dword=0; dword < 12; dword++)begin
             seed_reg[dword] = hwif_out.ECC_SEED[11-dword].SEED.value;
-            hwif_in.ECC_SEED[dword].SEED.we = (kv_seed_write_en & (kv_seed_write_offset == dword)) & !zeroize_reg;
+            hwif_in.ECC_SEED[dword].SEED.we = (kv_seed_write_en & (kv_seed_write_offset == dword)) & !zeroize_reg & !fault_active;
             hwif_in.ECC_SEED[dword].SEED.next = kv_seed_write_data;
-            hwif_in.ECC_SEED[dword].SEED.hwclr = zeroize_reg | kv_seed_data_present_reset | (kv_seed_error != KV_SUCCESS);
+            hwif_in.ECC_SEED[dword].SEED.hwclr = zeroize_reg | fault_active | kv_seed_data_present_reset | (kv_seed_error != KV_SUCCESS);
             hwif_in.ECC_SEED[dword].SEED.swwe  = ecc_ready_reg & ~kv_seed_data_present;
         end
 
@@ -402,45 +406,43 @@
 
         for (int dword=0; dword < 12; dword++)begin
             msg_reg[dword] = hwif_out.ECC_MSG[11-dword].MSG.value;
-            hwif_in.ECC_MSG[dword].MSG.we = pcr_sign_mode & !zeroize_reg;
+            hwif_in.ECC_MSG[dword].MSG.we = pcr_sign_valid_launch & !zeroize_reg & !fault_active;
             hwif_in.ECC_MSG[dword].MSG.next = pcr_signing_data.pcr_hash[dword];
-            hwif_in.ECC_MSG[dword].MSG.hwclr = zeroize_reg;
+            hwif_in.ECC_MSG[dword].MSG.hwclr = zeroize_reg | pcr_sign_done | (pcr_signing_active & fault_active);
         end
 
         for (int dword=0; dword < 12; dword++)begin
             pubkeyx_reg[dword] = hwif_out.ECC_PUBKEY_X[11-dword].PUBKEY_X.value;
-            hwif_in.ECC_PUBKEY_X[dword].PUBKEY_X.we = hw_pubkeyx_we & !zeroize_reg;
-            hwif_in.ECC_PUBKEY_X[dword].PUBKEY_X.next = read_reg[11-dword];  
-            hwif_in.ECC_PUBKEY_X[dword].PUBKEY_X.hwclr = zeroize_reg;
+            hwif_in.ECC_PUBKEY_X[dword].PUBKEY_X.we = hw_pubkeyx_we & !zeroize_reg & !fault_active;
+            hwif_in.ECC_PUBKEY_X[dword].PUBKEY_X.next = read_reg[11-dword];
+            hwif_in.ECC_PUBKEY_X[dword].PUBKEY_X.hwclr = zeroize_reg | fault_active;
         end
 
         for (int dword=0; dword < 12; dword++)begin
             pubkeyy_reg[dword] = hwif_out.ECC_PUBKEY_Y[11-dword].PUBKEY_Y.value;
-            hwif_in.ECC_PUBKEY_Y[dword].PUBKEY_Y.we = hw_pubkeyy_we & !zeroize_reg;
+            hwif_in.ECC_PUBKEY_Y[dword].PUBKEY_Y.we = hw_pubkeyy_we & !zeroize_reg & !fault_active;
             hwif_in.ECC_PUBKEY_Y[dword].PUBKEY_Y.next = read_reg[11-dword];
-            hwif_in.ECC_PUBKEY_Y[dword].PUBKEY_Y.hwclr = zeroize_reg;
+            hwif_in.ECC_PUBKEY_Y[dword].PUBKEY_Y.hwclr = zeroize_reg | fault_active;
         end
 
         for (int dword=0; dword < 12; dword++)begin
             r_reg[dword] = hwif_out.ECC_SIGN_R[11-dword].SIGN_R.value;
-            hwif_in.ECC_SIGN_R[dword].SIGN_R.we = hw_r_we & !zeroize_reg;
+            hwif_in.ECC_SIGN_R[dword].SIGN_R.we = hw_r_we & !zeroize_reg & !fault_active;
             hwif_in.ECC_SIGN_R[dword].SIGN_R.next = read_reg[11-dword];
-            hwif_in.ECC_SIGN_R[dword].SIGN_R.hwclr = zeroize_reg;
+            hwif_in.ECC_SIGN_R[dword].SIGN_R.hwclr = zeroize_reg | fault_active;
         end
 
         for (int dword=0; dword < 12; dword++)begin
             s_reg[dword] = hwif_out.ECC_SIGN_S[11-dword].SIGN_S.value;
-            hwif_in.ECC_SIGN_S[dword].SIGN_S.we = hw_s_we & !zeroize_reg;
+            hwif_in.ECC_SIGN_S[dword].SIGN_S.we = hw_s_we & !zeroize_reg & !fault_active;
             hwif_in.ECC_SIGN_S[dword].SIGN_S.next = read_reg[11-dword];
-            hwif_in.ECC_SIGN_S[dword].SIGN_S.hwclr = zeroize_reg;
-        end
-
-        for (int dword=0; dword < 12; dword++)begin 
-            //Preload with the complement of the supplied signature R at the start of a
-            //VERIFY operation so an aborted verification cannot leave a stale match
-            hwif_in.ECC_VERIFY_R[dword].VERIFY_R.we = (hw_verify_r_we | ecc_verify_start) & !zeroize_reg;
+            hwif_in.ECC_SIGN_S[dword].SIGN_S.hwclr = zeroize_reg | fault_active;
+        end
+
+        for (int dword=0; dword < 12; dword++)begin
+            hwif_in.ECC_VERIFY_R[dword].VERIFY_R.we = (hw_verify_r_we | ecc_verify_start) & !zeroize_reg & !fault_active;
             hwif_in.ECC_VERIFY_R[dword].VERIFY_R.next = ecc_verify_start ? ~r_reg[11-dword] : read_reg[11-dword];
-            hwif_in.ECC_VERIFY_R[dword].VERIFY_R.hwclr = zeroize_reg;
+            hwif_in.ECC_VERIFY_R[dword].VERIFY_R.hwclr = zeroize_reg | fault_active;
         end
 
         for (int dword=0; dword < 12; dword++)begin
@@ -449,9 +451,9 @@
         end
 
         for (int dword=0; dword < 12; dword++)begin
-            hwif_in.ECC_DH_SHARED_KEY[dword].DH_SHARED_KEY.we = (sharedkey_we_reg & ~(dest_keyvault | kv_key_data_present)) & !zeroize_reg;
-            hwif_in.ECC_DH_SHARED_KEY[dword].DH_SHARED_KEY.next = read_reg[11-dword];  
-            hwif_in.ECC_DH_SHARED_KEY[dword].DH_SHARED_KEY.hwclr = zeroize_reg;
+            hwif_in.ECC_DH_SHARED_KEY[dword].DH_SHARED_KEY.we = (sharedkey_we_reg & ~(dest_keyvault | kv_key_data_present)) & !zeroize_reg & !fault_active;
+            hwif_in.ECC_DH_SHARED_KEY[dword].DH_SHARED_KEY.next = read_reg[11-dword];
+            hwif_in.ECC_DH_SHARED_KEY[dword].DH_SHARED_KEY.hwclr = zeroize_reg | fault_active;
         end
     end
 
@@ -490,18 +492,17 @@
         hwif_in.ecc_kv_rd_seed_status.READY.next = kv_seed_ready;
         hwif_in.ecc_kv_wr_pkey_status.READY.next = kv_write_ready;
         //set valid when fsm is done
-        hwif_in.ecc_kv_rd_pkey_status.VALID.hwset = kv_privkey_done;
-        hwif_in.ecc_kv_rd_seed_status.VALID.hwset = kv_seed_done;
-        hwif_in.ecc_kv_wr_pkey_status.VALID.hwset = kv_write_done;
-        //clear valid when new request is made
-        hwif_in.ecc_kv_rd_pkey_status.VALID.hwclr = kv_privkey_read_ctrl_reg.read_en;
-        hwif_in.ecc_kv_rd_seed_status.VALID.hwclr = kv_seed_read_ctrl_reg.read_en;
-        hwif_in.ecc_kv_wr_pkey_status.VALID.hwclr = kv_write_ctrl_reg.write_en | zeroize_reg;
-        //clear enable when busy, or on zeroize so a failed operation cannot leave
-        //the KV write request armed for the next operation
-        hwif_in.ecc_kv_rd_pkey_ctrl.read_en.hwclr = ~kv_privkey_ready;
-        hwif_in.ecc_kv_rd_seed_ctrl.read_en.hwclr = ~kv_seed_ready;
-        hwif_in.ecc_kv_wr_pkey_ctrl.write_en.hwclr = ~kv_write_ready | zeroize_reg;
+        hwif_in.ecc_kv_rd_pkey_status.VALID.hwset = kv_privkey_done & ~zeroize_reg;
+        hwif_in.ecc_kv_rd_seed_status.VALID.hwset = kv_seed_done & ~zeroize_reg;
+        hwif_in.ecc_kv_wr_pkey_status.VALID.hwset = kv_write_done & ~zeroize_reg & ~fault_active;
+        //clear valid when new request is made or sanitized
+        hwif_in.ecc_kv_rd_pkey_status.VALID.hwclr = kv_privkey_read_ctrl_reg.read_en | zeroize_reg;
+        hwif_in.ecc_kv_rd_seed_status.VALID.hwclr = kv_seed_read_ctrl_reg.read_en | zeroize_reg;
+        hwif_in.ecc_kv_wr_pkey_status.VALID.hwclr = kv_write_ctrl_reg.write_en | zeroize_reg | fault_active;
+        //clear enable when busy, on zeroize, or on fault
+        hwif_in.ecc_kv_rd_pkey_ctrl.read_en.hwclr = ~kv_privkey_ready | zeroize_reg;
+        hwif_in.ecc_kv_rd_seed_ctrl.read_en.hwclr = ~kv_seed_ready | zeroize_reg;
+        hwif_in.ecc_kv_wr_pkey_ctrl.write_en.hwclr = ~kv_write_ready | zeroize_reg | fault_active;
     end
 
     // Software write-enables to prevent KV reg manipulation mid-operation
@@ -556,7 +557,7 @@
             scalar_G_reg <= '0;
             scalar_PK_reg <= '0;
         end
-        else if(zeroize_reg) begin
+        else if(zeroize_reg | fault_active) begin
             scalar_G_reg <= '0;
             scalar_PK_reg <= '0;
         end
@@ -661,7 +662,7 @@
         if(!reset_n) begin
             scalar_in_reg <= '0;
         end
-        else if(zeroize_reg) begin
+        else if(zeroize_reg | fault_active) begin
             scalar_in_reg <= '0;
         end
         else begin
@@ -685,7 +686,7 @@
         if(!reset_n) begin
             pk_chk_reg <= '0;
         end
-        else if(zeroize_reg) begin
+        else if(zeroize_reg | ecc_cmd_start) begin
             pk_chk_reg <= '0;
         end
         else begin
@@ -707,29 +708,51 @@
     
     assign error_flag_edge = error_flag & (!error_flag_reg);
 
-    assign privkey_input_outofrange = signing_process & ((privkey_reg == 0) | (privkey_reg >= GROUP_ORDER));
-    assign r_output_outofrange      = signing_process & (hw_r_we & ((read_reg == 0) | (read_reg >= GROUP_ORDER)));
-    assign s_output_outofrange      = signing_process & (hw_s_we & ((read_reg == 0) | (read_reg >= GROUP_ORDER)));
-
-    assign r_input_outofrange       = verifying_process & ((r_reg == 0) | (r_reg >= GROUP_ORDER));
-    assign s_input_outofrange       = verifying_process & ((s_reg == 0) | (s_reg >= GROUP_ORDER));
+    assign raw_cmd_req = {hwif_out.ECC_CTRL.DH_SHAREDKEY.value, hwif_out.ECC_CTRL.CTRL.value};
+    assign kv_any_active = kv_key_data_present | kv_seed_data_present |
+                           kv_privkey_read_ctrl_reg.read_en | kv_seed_read_ctrl_reg.read_en |
+                           kv_write_ctrl_reg.write_en |
+                           ~kv_privkey_ready | ~kv_seed_ready | ~kv_write_ready;
+    assign pcr_sign_valid_launch = pcr_sign_mode & (prog_cntr == ECC_NOP) & ~subcomponent_busy &
+                                   ~error_flag_reg & (raw_cmd_req == SIGN) & (cmd_reg == SIGN) & ~kv_any_active;
+    assign pcr_sign_done = pcr_signing_active & (prog_cntr == DSA_SGN_E) & ~subcomponent_busy & (cycle_cnt == 2'd3);
+
+    always_ff @(posedge clk or negedge reset_n) begin : pcr_signing_track
+        if (!reset_n)
+            pcr_signing_active <= 1'b0;
+        else if (zeroize_reg | fault_active | pcr_sign_done)
+            pcr_signing_active <= 1'b0;
+        else if (pcr_sign_valid_launch)
+            pcr_signing_active <= 1'b1;
+    end
+
+    assign privkey_input_outofrange = (signing_process | sharedkey_process) & ((privkey_reg == '0) | (privkey_reg >= GROUP_ORDER));
+    assign r_output_outofrange      = signing_process & (hw_r_we & ((read_reg == '0) | (read_reg >= GROUP_ORDER)));
+    assign s_output_outofrange      = signing_process & (hw_s_we & ((read_reg == '0) | (read_reg >= GROUP_ORDER)));
+
+    assign r_input_outofrange       = verifying_process & ((r_reg == '0) | (r_reg >= GROUP_ORDER));
+    assign s_input_outofrange       = verifying_process & ((s_reg == '0) | (s_reg >= GROUP_ORDER));
     assign pubkeyx_input_outofrange = (verifying_process | sharedkey_process) & (pubkeyx_reg >= PRIME);
     assign pubkeyy_input_outofrange = (verifying_process | sharedkey_process) & (pubkeyy_reg >= PRIME);
-    assign pubkey_input_invalid     = (verifying_process | sharedkey_process) & (pk_chk_reg != 0);
-
-    assign pcr_sign_input_invalid   = ((cmd_reg == KEYGEN) | (cmd_reg == VERIFY) | (cmd_reg == SHARED_KEY)) & pcr_sign_mode;
-
-    assign privkey_output_outofrange = keygen_process & (hw_privkey_we & ((read_reg == 0) | (read_reg >= GROUP_ORDER)));
+    assign pubkey_input_invalid     = (verifying_process | sharedkey_process) & (pk_chk_reg != '0);
+
+    assign pcr_sign_input_invalid   = pcr_sign_mode & ~pcr_sign_valid_launch;
+
+    assign privkey_output_outofrange = keygen_process & (hw_privkey_we & ((read_reg == '0) | (read_reg >= GROUP_ORDER)));
     assign pubkeyx_output_outofrange = keygen_process & (hw_pubkeyx_we & (read_reg >= PRIME));
     assign pubkeyy_output_outofrange = keygen_process & (hw_pubkeyy_we & (read_reg >= PRIME));
 
-    assign sharedkey_outofrange = sharedkey_process & (hw_sharedkey_we & (read_reg >= PRIME));
-
-    assign error_flag = privkey_input_outofrange | r_output_outofrange | s_output_outofrange | 
-                        r_input_outofrange | s_input_outofrange | pubkeyx_input_outofrange | pubkeyy_input_outofrange | 
+    assign sharedkey_outofrange = sharedkey_process & (hw_sharedkey_we & ((read_reg == '0) | (read_reg >= PRIME)));
+
+    assign scalar_blind_fault = (scalar_sca_en & ((scalar_in_reg == '0) | (scalar_in_reg >= GROUP_ORDER) | (scalar_rnd_reg[RND_SIZE-1:0] == '0))) |
+                                ((prog_instr.opcode == DSA_UOP_WR_SCALAR) & (prog_instr.reg_id == SCALAR_ID) & ~scalar_sca_busy_o & (scalar_out_reg == '0));
+
+    assign error_flag = privkey_input_outofrange | r_output_outofrange | s_output_outofrange |
+                        r_input_outofrange | s_input_outofrange | pubkeyx_input_outofrange | pubkeyy_input_outofrange |
                         pubkey_input_invalid | pcr_sign_input_invalid |
                         privkey_output_outofrange | pubkeyx_output_outofrange | pubkeyy_output_outofrange |
-                        sharedkey_outofrange;
+                        sharedkey_outofrange | scalar_blind_fault;
+    assign fault_active = error_flag | error_flag_reg;
 
     //----------------------------------------------------------------
     // Explicit hardware signature verification result
@@ -870,21 +893,25 @@
                     DSA_KG_E : begin // end of keygen
                         prog_cntr <= ECC_NOP;
                         ecc_valid_reg <= 1;
+                        keygen_process <= 0;
                     end
 
                     DSA_SGN_E : begin // end of signing
                         prog_cntr <= ECC_NOP;
                         ecc_valid_reg <= 1;
+                        signing_process <= 0;
                     end
 
                     DSA_VER_E : begin // end of verifying
                         prog_cntr <= ECC_NOP;
                         ecc_valid_reg <= 1;
+                        verifying_process <= 0;
                     end
 
                     DH_SHARED_E: begin // end of DH shared key
                         prog_cntr <= ECC_NOP;
                         ecc_valid_reg <= 1;
+                        sharedkey_process <= 0;
                     end
                     
                     ECC_RESET,

--- a/environment/public/code/ecc_scalar_blinding.sv (Buggy Starter)
+++ b/solution/gold/code/ecc_scalar_blinding.sv (Golden Reference)
@@ -16,21 +16,10 @@
 //
 // ecc_scalar_blinding.sv
 // --------
-// The scalar blinding is a SCA countermeasure described in
-// "Resistance against Differential Power Analysis for Elliptic Curve 
-// Cryptosystems" by Coron.
-// Based on "Efficient Side-Channel Attacks on Scalar Blinding on Elliptic 
-// Curves with Special Structure" by Schindler et. al., the random value size
-// should be at least half of group order length. 
-//
-// This module takes the scalar and a random value (rnd) to randomize the scalar
-// as follows:
+// Additive scalar blinding countermeasure:
 //      randomized_scalar = scalar + rnd * group_order
-// with the following contraint:
-//      scalar < group_order
-//
-// From the contraint, the output has REG_SIZE+RND_SIZE bit length:
-//      scalar + rnd*group_order < (rnd+1)*group_order < (2^RND_SIZE)*group_order
+// Hardened against degenerate zero/out-of-bounds scalar inputs and
+// all-zero blinding masks.
 //
 //======================================================================
 
@@ -57,19 +46,18 @@
     //----------------------------------------------------------------
     // Local Parameters
     //----------------------------------------------------------------
-    // Equivalent to $ceil(REG_SIZE/RADIX) + 1
     localparam  REG_DIG_NUM  = (((REG_SIZE + RADIX) - 1) / RADIX) + 1;  //13
     localparam  RND_DIG_NUM  = (((RND_SIZE + RADIX) - 1) / RADIX) + 1;  //7
-    localparam  FULL_DIG_NUM = REG_DIG_NUM + RND_DIG_NUM - 1;  //19
-    
+    localparam  FULL_DIG_NUM = REG_DIG_NUM + RND_DIG_NUM - 1;           //19
+
     localparam  FULL_REG_SIZE   = REG_DIG_NUM * RADIX;
     localparam  FULL_RND_SIZE   = RND_DIG_NUM * RADIX;
     localparam  FULL_SIZE       = FULL_DIG_NUM * RADIX;
 
-    localparam [(FULL_RND_SIZE-RND_SIZE)-1 : 0] zero_pad_rnd = '0;
-    localparam [(FULL_REG_SIZE-REG_SIZE)-1 : 0] zero_pad_reg = '0;
+    localparam [(FULL_RND_SIZE-RND_SIZE)-1 : 0] zero_pad_rnd      = '0;
+    localparam [(FULL_REG_SIZE-REG_SIZE)-1 : 0] zero_pad_reg      = '0;
     localparam [(FULL_SIZE-REG_SIZE)-1 : 0]     zero_pad_reg_full = '0;
-    localparam [RADIX-1 : 0]                    zero_pad_radix = '0;
+    localparam [RADIX-1 : 0]                    zero_pad_radix    = '0;
 
     localparam A_ARR_WIDTH      = $clog2(REG_DIG_NUM+1);   //4
     localparam B_ARR_WIDTH      = $clog2(RND_DIG_NUM+1);   //3
@@ -86,9 +74,9 @@
     logic [A_ARR_WIDTH-1 : 0]       a_idx;
     logic [B_ARR_WIDTH-1 : 0]       b_idx;
 
-    logic [FULL_REG_SIZE-1 : 0]     a_reg;        //extended with zero
-    logic [FULL_RND_SIZE-1 : 0]     b_reg;        //extended with zero
-    logic [FULL_SIZE-1 : 0]         scalar_reg;   //extended with zero
+    logic [FULL_REG_SIZE-1 : 0]     a_reg;
+    logic [FULL_RND_SIZE-1 : 0]     b_reg;
+    logic [FULL_SIZE-1 : 0]         scalar_reg;
     logic [FULL_SIZE-1 : 0]         p_internal;
 
     logic [RADIX-1      : 0]        mult_opa;
@@ -112,65 +100,73 @@
 
     logic                           shift_state;
 
-    logic [P_ARR_WIDTH-1 : 0]            product_idx;
-    logic [B_ARR_WIDTH-1 : 0]            operand_idx;
-    logic [P_ARR_WIDTH-1 : 0]            product_idx_reg;
-    logic [B_ARR_WIDTH-1 : 0]            operand_idx_reg;
-
-    logic [P_ARR_WIDTH-B_ARR_WIDTH   : 0]   carry_garbage_bits0;
-    logic                                   carry_garbage_bit1;
+    logic [P_ARR_WIDTH-1 : 0]       product_idx;
+    logic [B_ARR_WIDTH-1 : 0]       operand_idx;
+    logic [P_ARR_WIDTH-1 : 0]       product_idx_reg;
+    logic [B_ARR_WIDTH-1 : 0]       operand_idx_reg;
+
+    logic [P_ARR_WIDTH-B_ARR_WIDTH : 0] carry_garbage_bits0;
+    logic                               carry_garbage_bit1;
+    logic                               invalid_in;
+
+    assign invalid_in = (data_i == '0) || (data_i >= GROUP_ORDER) || (rnd_i == '0);
+
     //----------------------------------------------------------------
     // reg update
     //----------------------------------------------------------------
-
-    always_ff @(posedge clk or negedge reset_n) 
+    always_ff @(posedge clk or negedge reset_n)
     begin : input_reg
         if (!reset_n) begin
-            a_reg <= '0;
-            b_reg <= '0;
+            a_reg      <= '0;
+            b_reg      <= '0;
             scalar_reg <= '0;
         end
         else if (zeroize) begin
-            a_reg <= '0;
-            b_reg <= '0;
+            a_reg      <= '0;
+            b_reg      <= '0;
             scalar_reg <= '0;
         end
         else if (en_i) begin
-            a_reg       <= {zero_pad_reg, GROUP_ORDER};
-            b_reg       <= {zero_pad_rnd, rnd_i};
-            scalar_reg  <= {zero_pad_reg_full, data_i};
-        end 
-    end // input_reg
+            if (invalid_in) begin
+                a_reg      <= '0;
+                b_reg      <= '0;
+                scalar_reg <= '0;
+            end
+            else begin
+                a_reg      <= {zero_pad_reg, GROUP_ORDER};
+                b_reg      <= {zero_pad_rnd, rnd_i};
+                scalar_reg <= {zero_pad_reg_full, data_i};
+            end
+        end
+    end
 
     genvar i0;
-    generate 
+    generate
         for (i0=0; i0 < REG_DIG_NUM; i0++) begin : gen_a_array
             assign a_array[i0] = a_reg[i0*RADIX +: RADIX];
         end
-    endgenerate // gen_a_array
+    endgenerate
 
     genvar j0;
-    generate 
+    generate
         for (j0=0; j0 < RND_DIG_NUM; j0++) begin : gen_b_array
             assign b_array[j0] = b_reg[j0*RADIX +: RADIX];
         end
-    endgenerate // gen_b_array
+    endgenerate
 
     genvar k0;
-    generate 
+
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ahb_defines_pkg.sv`](environment/public/code/ahb_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ahb_slv_sif.sv`](environment/public/code/ahb_slv_sif.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_macros.svh`](environment/public/code/caliptra_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert.sv`](environment/public/code/caliptra_prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_dummy_macros.svh`](environment/public/code/caliptra_prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_sec_cm.svh`](environment/public/code/caliptra_prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_standard_macros.svh`](environment/public/code/caliptra_prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_yosys_macros.svh`](environment/public/code/caliptra_prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_cipher_pkg.sv`](environment/public/code/caliptra_prim_cipher_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_flop.sv`](environment/public/code/caliptra_prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_flop_macros.sv`](environment/public/code/caliptra_prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_generic_flop.sv`](environment/public/code/caliptra_prim_generic_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_lfsr.sv`](environment/public/code/caliptra_prim_lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_module_name_macros.svh`](environment/public/code/caliptra_prim_module_name_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_pkg.sv`](environment/public/code/caliptra_prim_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_sparse_fsm_flop.sv`](environment/public/code/caliptra_prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_util_pkg.sv`](environment/public/code/caliptra_prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_sva.svh`](environment/public/code/caliptra_sva.svh) *(Read-Only Context)*
- [`environment/public/code/ecc_add_sub_mod_alter.sv`](environment/public/code/ecc_add_sub_mod_alter.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_adder.sv`](environment/public/code/ecc_adder.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_arith_unit.sv`](environment/public/code/ecc_arith_unit.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_defines_pkg.sv`](environment/public/code/ecc_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_dsa_ctrl.sv`](environment/public/code/ecc_dsa_ctrl.sv) **(Editable)**
- [`environment/public/code/ecc_dsa_sequencer.sv`](environment/public/code/ecc_dsa_sequencer.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_dsa_uop_pkg.sv`](environment/public/code/ecc_dsa_uop_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_fau.sv`](environment/public/code/ecc_fau.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_hmac_drbg_interface.sv`](environment/public/code/ecc_hmac_drbg_interface.sv) **(Editable)**
- [`environment/public/code/ecc_montgomerymultiplier.sv`](environment/public/code/ecc_montgomerymultiplier.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_mult_dsp.sv`](environment/public/code/ecc_mult_dsp.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_params_pkg.sv`](environment/public/code/ecc_params_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_pe.sv`](environment/public/code/ecc_pe.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_pe_final.sv`](environment/public/code/ecc_pe_final.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_pe_first.sv`](environment/public/code/ecc_pe_first.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_pm_ctrl.sv`](environment/public/code/ecc_pm_ctrl.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_pm_sequencer.sv`](environment/public/code/ecc_pm_sequencer.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_pm_uop_pkg.sv`](environment/public/code/ecc_pm_uop_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_ram_tdp_file.sv`](environment/public/code/ecc_ram_tdp_file.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_reg.sv`](environment/public/code/ecc_reg.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_reg_pkg.sv`](environment/public/code/ecc_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ecc_scalar_blinding.sv`](environment/public/code/ecc_scalar_blinding.sv) **(Editable)**
- [`environment/public/code/ecc_top.sv`](environment/public/code/ecc_top.sv) *(Read-Only Context)*
- [`environment/public/code/hmac_core.sv`](environment/public/code/hmac_core.sv) *(Read-Only Context)*
- [`environment/public/code/hmac_drbg.sv`](environment/public/code/hmac_drbg.sv) *(Read-Only Context)*
- [`environment/public/code/hmac_param_pkg.sv`](environment/public/code/hmac_param_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kv_defines_pkg.sv`](environment/public/code/kv_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kv_fsm.sv`](environment/public/code/kv_fsm.sv) *(Read-Only Context)*
- [`environment/public/code/kv_macros.svh`](environment/public/code/kv_macros.svh) *(Read-Only Context)*
- [`environment/public/code/kv_read_client.sv`](environment/public/code/kv_read_client.sv) *(Read-Only Context)*
- [`environment/public/code/kv_read_rule_check.sv`](environment/public/code/kv_read_rule_check.sv) *(Read-Only Context)*
- [`environment/public/code/kv_write_client.sv`](environment/public/code/kv_write_client.sv) *(Read-Only Context)*
- [`environment/public/code/kv_write_rule_check.sv`](environment/public/code/kv_write_rule_check.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_h_constants.v`](environment/public/code/sha512_h_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_k_constants.v`](environment/public/code/sha512_k_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_masked_core.sv`](environment/public/code/sha512_masked_core.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_masked_defines_pkg.sv`](environment/public/code/sha512_masked_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_masked_w_mem.sv`](environment/public/code/sha512_masked_w_mem.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

