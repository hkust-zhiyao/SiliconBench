# `case_25002`: Harden Caliptra Deobfuscation Engine (DOE) Sparse-FSM Fault Containment, Sticky Flow Locks, and Secret Sanitization

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25002` |
| **Source Silicon Repository** | `chipsalliance/caliptra-rtl` (`repo_50`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Security_RoT_Subsystems` (Security_RoT_Subsystems) |
| **Multi-Domain Tags** | `Security_RoT_Subsystems` |
| **Editable Files (`allowed_edits`)** | [`code/doe_fsm.sv`](environment/public/code/doe_fsm.sv), [`code/doe_ctrl.sv`](environment/public/code/doe_ctrl.sv), [`code/doe_key_mem.sv`](environment/public/code/doe_key_mem.sv) (3 files, 808 LOC) |
| **Public Subsystem Context** | 31 RTL files (7163 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

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

## 3. Build & Verification Instructions (`BUILD.md`)

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

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/doe_fsm.sv (Buggy Starter)
+++ b/solution/gold/code/doe_fsm.sv (Golden Reference)
@@ -36,7 +36,7 @@
     input logic rst_b,
     input logic hard_rst_b,
 
-    // Obfuscated UDS and FE
+    // Obfuscated UDS, FE, and HEK
     input logic [FE_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_field_entropy,
     input logic [UDS_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_uds_seed,
     input logic [HEK_NUM_BLOCKS-1:0][SRC_WIDTH-1:0] obf_hek_seed,
@@ -78,6 +78,7 @@
 localparam BLOCK_OFFSET_W     = `CLP_MAX_OF(HEK_BLOCK_OFFSET_W, `CLP_MAX_OF(FE_BLOCK_OFFSET_W, UDS_BLOCK_OFFSET_W));
 localparam DEST_WR_OFFSET_W   = $clog2(512/32);
 
+// Sparse 10-bit state encoding (minimum Hamming distance = 5 >= 3)
 localparam int DoeStateWidth = 10;
 typedef enum logic [DoeStateWidth-1:0] {
     DOE_IDLE  = 10'b1010101010,
@@ -90,147 +91,205 @@
     DOE_ERROR = 10'b0111110000
 } kv_doe_fsm_state_e;
 
-logic running_uds, running_fe, running_hek;
-
-kv_write_filter_metrics_t kv_write_metrics;
-logic                     kv_write_allow;
-
-logic [KV_ENTRY_ADDR_W-1:0] dest_addr, dest_addr_nxt;
-logic dest_addr_en;
-logic [DEST_WR_OFFSET_W-1:0] dest_write_offset, dest_write_offset_nxt;
-logic dest_write_offset_en;
-logic dest_write_en;
-logic dest_write_done;
-
-logic [BLOCK_OFFSET_W-1:0] block_offset, block_offset_nxt;
-logic block_offset_en;
-logic block_done;
-logic zeroize_reg;
-
-kv_doe_fsm_state_e kv_doe_fsm_ps, kv_doe_fsm_ns;
+// Synthesis-preserved sparse state flops (prevents FSM extraction/recoding and redundant-bit pruning)
+(* keep = "true", fsm_encoding = "none" *) logic [DoeStateWidth-1:0] kv_doe_fsm_ps_raw;
+(* keep = "true" *) kv_doe_fsm_state_e kv_doe_fsm_ps;
+kv_doe_fsm_state_e kv_doe_fsm_ns;
+
+assign kv_doe_fsm_ps = kv_doe_fsm_state_e'(kv_doe_fsm_ps_raw);
+
+always_ff @(posedge clk or negedge rst_b) begin
+    if (~rst_b) begin
+        kv_doe_fsm_ps_raw <= DoeStateWidth'(DOE_IDLE);
+    end else begin
+        kv_doe_fsm_ps_raw <= DoeStateWidth'(kv_doe_fsm_ns);
+    end
+end
+
+// Pre-dispatch command & destination-slot policy checks in DOE_IDLE
+logic std_slot_ok;
+logic hek_slot_ok;
+logic uds_auth;
+logic fe_auth;
+logic hek_auth;
+logic cmd_is_nop_or_clear;
+logic cmd_rejected_in_idle;
+
+assign std_slot_ok         = (doe_cmd_reg.dest_sel <= KV_ENTRY_ADDR_W'(KV_STANDARD_SLOT_HI));
+assign hek_slot_ok         = ocp_lock_en && (doe_cmd_reg.dest_sel == KV_ENTRY_ADDR_W'(OCP_LOCK_HEK_SEED_KV_SLOT));
+assign uds_auth            = (doe_cmd_reg.cmd == DOE_UDS) && !lock_uds_flow && std_slot_ok;
+assign fe_auth             = (doe_cmd_reg.cmd == DOE_FE)  && !lock_fe_flow  && std_slot_ok;
+assign hek_auth            = (doe_cmd_reg.cmd == DOE_HEK) && !lock_hek_flow && hek_slot_ok;
+assign cmd_is_nop_or_clear = (doe_cmd_reg.cmd == DOE_NOP) || (doe_cmd_reg.cmd == DOE_CLEAR);
+
 logic arc_DOE_IDLE_DOE_INIT;
 logic arc_DOE_WAIT_DOE_BLOCK;
 logic arc_DOE_WAIT_DOE_WRITE;
 logic arc_DOE_WRITE_DOE_BLOCK;
 logic arc_DOE_WRITE_DOE_DONE;
 
-always_ff @(posedge clk or negedge rst_b) begin
-    if (~rst_b) begin
-        zeroize_reg <= 0;
-    end
-    else if (zeroize) begin
-        zeroize_reg <= 1;
-    end
-    else if (running_uds || running_fe || running_hek) begin
-        zeroize_reg <= 0;
-    end
-end
-
-always_comb running_uds = (doe_cmd_reg.cmd == DOE_UDS);
-always_comb running_fe  = (doe_cmd_reg.cmd == DOE_FE );
-always_comb running_hek = (doe_cmd_reg.cmd == DOE_HEK);
-always_comb block_done = running_uds ? (block_offset == (UDS_NUM_BLOCKS-1)) :
-                         running_hek ? (block_offset == (HEK_NUM_BLOCKS-1)) :
-                                       (block_offset == (FE_NUM_BLOCKS -1)) ;
-
-always_comb flow_in_progress = running_uds | running_fe | running_hek;
-always_comb dest_write_done = (dest_write_offset[DEST_OFFSET_W-1:0] == (DEST_NUM_DWORDS-1));
-
-always_comb arc_DOE_IDLE_DOE_INIT = (running_uds & ~lock_uds_flow) |
-                                    (running_fe  & ~lock_fe_flow ) |
-                                    (running_hek & ~lock_hek_flow);
-always_comb arc_DOE_WAIT_DOE_WRITE = init_done & dest_data_avail;
-always_comb arc_DOE_WAIT_DOE_BLOCK = init_done & ~dest_data_avail;
-always_comb arc_DOE_WRITE_DOE_BLOCK = dest_write_done & ~block_done;
-always_comb arc_DOE_WRITE_DOE_DONE = flow_error | (dest_write_done & block_done);
-
-// state combo block
+assign arc_DOE_IDLE_DOE_INIT  = uds_auth || fe_auth || hek_auth;
+assign cmd_rejected_in_idle   = !zeroize && !cmd_is_nop_or_clear && !arc_DOE_IDLE_DOE_INIT;
+
+// Latched command and error tracking across active unwrap beats
+doe_cmd_e cmd_latched_q;
+logic     flow_err_latched_q;
+
+logic running_uds, running_fe, running_hek;
+assign running_uds = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) ? uds_auth : (cmd_latched_q == DOE_UDS);
+assign running_fe  = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) ? fe_auth  : (cmd_latched_q == DOE_FE);
+assign running_hek = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) ? hek_auth : (cmd_latched_q == DOE_HEK);
+
+// Access filtering rule metrics
+kv_write_filter_metrics_t kv_write_metrics;
+logic                     kv_write_allow;
+
+logic [KV_ENTRY_ADDR_W-1:0]  dest_addr, dest_addr_nxt;
+logic                        dest_addr_en;
+logic [DEST_WR_OFFSET_W-1:0] dest_write_offset, dest_write_offset_nxt;
+logic                        dest_write_offset_en;
+logic                        dest_write_en;
+logic                        dest_write_done;
+
+logic [BLOCK_OFFSET_W-1:0]   block_offset, block_offset_nxt;
+logic                        block_offset_en;
+logic                        block_done;
+
+assign block_done = running_uds ? (block_offset == BLOCK_OFFSET_W'(UDS_NUM_BLOCKS-1)) :
+                    running_hek ? (block_offset == BLOCK_OFFSET_W'(HEK_NUM_BLOCKS-1)) :
+                                  (block_offset == BLOCK_OFFSET_W'(FE_NUM_BLOCKS -1));
+
+assign dest_write_done = (dest_write_offset[DEST_OFFSET_W-1:0] == DEST_OFFSET_W'(DEST_NUM_DWORDS-1));
+
+assign arc_DOE_WAIT_DOE_WRITE  = init_done && dest_data_avail;
+assign arc_DOE_WAIT_DOE_BLOCK  = init_done && !dest_data_avail;
+assign arc_DOE_WRITE_DOE_BLOCK = dest_write_done && !block_done;
+assign arc_DOE_WRITE_DOE_DONE  = flow_error || (dest_write_done && block_done);
+
+logic in_operational_active_state;
+assign in_operational_active_state = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_INIT))  ||
+                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_BLOCK)) ||
+                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_NEXT))  ||
+                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_WAIT))  ||
+                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_WRITE)) ||
+                                     (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_DONE));
+
+assign flow_in_progress = in_operational_active_state ||
+                          ((kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) && !zeroize && arc_DOE_IDLE_DOE_INIT);
+
+// Full-width sparse state decode (non-unique case so default catches all 1016 undefined 10-bit states)
 always_comb begin : kv_doe_fsm
-    kv_doe_fsm_ns = kv_doe_fsm_ps;
-    src_write_en = '0;
-    block_offset_nxt = block_offset;
-    block_offset_en = '0;
-    dest_addr_en = '0;
-    doe_init = '0;
-    doe_next = '0;
-    dest_write_en = '0;
-    dest_write_offset_en ='0;
+    kv_doe_fsm_ns         = DOE_ERROR;
+    src_write_en          = 1'b0;
+    block_offset_nxt      = block_offset;
+    block_offset_en       = 1'b0;
+    doe_init              = 1'b0;
+    doe_next              = 1'b0;
+    dest_write_en         = 1'b0;
+    dest_write_offset_en  = 1'b0;
     dest_write_offset_nxt = dest_write_offset;
-    flow_done = '0;
-    flow_error = '0;
-    fsm_error = '0;
-
-    unique case (kv_doe_fsm_ps)
-        DOE_IDLE: begin
-            if (zeroize) kv_doe_fsm_ns = DOE_IDLE;
-            else if (arc_DOE_IDLE_DOE_INIT) begin
+    flow_done             = 1'b0;
+    flow_error            = 1'b0;
+    fsm_error             = 1'b0;
+
+    case (kv_doe_fsm_ps_raw)
+        DoeStateWidth'(DOE_IDLE): begin
+            if (zeroize) begin
+                kv_doe_fsm_ns = DOE_IDLE;
+            end else if (arc_DOE_IDLE_DOE_INIT) begin
                 kv_doe_fsm_ns = DOE_INIT;
-                dest_addr_en  = 1'b1;
-            end
-            flow_done = (running_uds & lock_uds_flow) | (running_fe & lock_fe_flow) | (running_hek & lock_hek_flow);
-        end
-        DOE_INIT: begin
-            if (zeroize) kv_doe_fsm_ns = DOE_IDLE;
-            else kv_doe_fsm_ns = DOE_WAIT;
-            doe_init = '1;
-        end
-        DOE_BLOCK: begin
-            if (zeroize) kv_doe_fsm_ns = DOE_IDLE;
-            else kv_doe_fsm_ns = DOE_NEXT;
-            src_write_en = '1;
-        end
-        DOE_NEXT: begin
-            if (zeroize) kv_doe_fsm_ns = DOE_IDLE;
-            else kv_doe_fsm_ns = DOE_WAIT;
-            doe_next = '1;
-        end
-        DOE_WAIT: begin
-            if      (zeroize) kv_doe_fsm_ns = DOE_IDLE;
-            else if (arc_DOE_WAIT_DOE_WRITE) kv_doe_fsm_ns = DOE_WRITE;
-            else if (arc_DOE_WAIT_DOE_BLOCK) kv_doe_fsm_ns = DOE_BLOCK;
-        end
-        DOE_WRITE: begin
-            dest_write_en = kv_write_allow;
-            dest_write_offset_en = kv_write_allow;
-            dest_write_offset_nxt = dest_write_offset + 'd1;
-            flow_error = !kv_write_allow | kv_wr_resp.error;
-
-            if      (zeroize) kv_doe_fsm_ns = DOE_IDLE;
-            else if (arc_DOE_WRITE_DOE_DONE) kv_doe_fsm_ns = DOE_DONE;
-            else if (arc_DOE_WRITE_DOE_BLOCK) begin
+            end else begin
+                kv_doe_fsm_ns = DOE_IDLE;
+                if (cmd_rejected_in_idle) begin
+                    flow_done  = 1'b1;
+                    flow_error = 1'b1;
+                end
+            end
+        end
+        DoeStateWidth'(DOE_INIT): begin
+            if (zeroize) begin
+                kv_doe_fsm_ns = DOE_IDLE;
+            end else begin
+                kv_doe_fsm_ns = DOE_WAIT;
+                doe_init      = 1'b1;
+            end
+        end
+        DoeStateWidth'(DOE_BLOCK): begin
+            if (zeroize) begin
+                kv_doe_fsm_ns = DOE_IDLE;
+            end else begin
+                kv_doe_fsm_ns = DOE_NEXT;
+                src_write_en  = 1'b1;
+            end
+        end
+        DoeStateWidth'(DOE_NEXT): begin
+            if (zeroize) begin
+                kv_doe_fsm_ns = DOE_IDLE;
+            end else begin
+                kv_doe_fsm_ns = DOE_WAIT;
+                doe_next      = 1'b1;
+            end
+        end
+        DoeStateWidth'(DOE_WAIT): begin
+            if (zeroize) begin
+                kv_doe_fsm_ns = DOE_IDLE;
+            end else if (arc_DOE_WAIT_DOE_WRITE) begin
+                kv_doe_fsm_ns = DOE_WRITE;
+            end else if (arc_DOE_WAIT_DOE_BLOCK) begin
                 kv_doe_fsm_ns = DOE_BLOCK;
-                block_offset_en = '1;
-                block_offset_nxt = block_offset + 'd1;
-            end
-        end
-        DOE_DONE: begin
-            kv_doe_fsm_ns = DOE_IDLE;
-            flow_done = '1;
-            block_offset_en = '1;
-            block_offset_nxt = '0;
-            dest_write_offset_en = '1;
+            end else begin
+                kv_doe_fsm_ns = DOE_WAIT;
+            end
+        end
+        DoeStateWidth'(DOE_WRITE): begin
+            if (zeroize) begin
+                kv_doe_fsm_ns = DOE_IDLE;
+            end else begin
+                dest_write_en         = kv_write_allow;
+                dest_write_offset_en  = kv_write_allow;
+                dest_write_offset_nxt = dest_write_offset + 'd1;
+                flow_error            = !kv_write_allow || kv_wr_resp.error;
+
+                if (arc_DOE_WRITE_DOE_DONE) begin
+                    kv_doe_fsm_ns = DOE_DONE;
+                end else if (arc_DOE_WRITE_DOE_BLOCK) begin
+                    kv_doe_fsm_ns    = DOE_BLOCK;
+                    block_offset_en  = 1'b1;
+                    block_offset_nxt = block_offset + 'd1;
+                end else begin
+                    kv_doe_fsm_ns = DOE_WRITE;
+                end
+            end
+        end
+        DoeStateWidth'(DOE_DONE): begin
+            kv_doe_fsm_ns         = DOE_IDLE;
+            block_offset_en       = 1'b1;
+            block_offset_nxt      = '0;
+            dest_write_offset_en  = 1'b1;
             dest_write_offset_nxt = '0;
-        end
-        DOE_ERROR: begin
-            if (zeroize) kv_doe_fsm_ns = DOE_IDLE;
-            else kv_doe_fsm_ns = DOE_ERROR;
-            fsm_error = 1'b1;
+            if (!zeroize) begin
+                flow_done = 1'b1;
+            end
+        end
+        DoeStateWidth'(DOE_ERROR): begin
+            // Terminal sticky fault state until reset; independent of zeroize to avoid loops
+            kv_doe_fsm_ns = DOE_ERROR;
+            fsm_error     = 1'b1;
         end
         default: begin
+            // Undefined / glitched state encoding: immediate suppression & terminal transition
             kv_doe_fsm_ns = DOE_ERROR;
-            fsm_error = 1'b1;
+            fsm_error     = 1'b1;
         end
     endcase
 end
 
-always_comb dest_addr_nxt = doe_cmd_reg.dest_sel;
-
+assign dest_addr_en  = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_IDLE)) && !zeroize && arc_DOE_IDLE_DOE_INIT;
+assign dest_addr_nxt = doe_cmd_reg.dest_sel;
+
+// Check KV filtering rules using the ocp_lock_en strap unconditionally
 always_comb begin
-    `ifdef CALIPTRA_MODE_SUBSYSTEM
     kv_write_metrics.ocp_lock_in_progress = ocp_lock_en;
-    `else
-    kv_write_metrics.ocp_lock_in_progress = 1'b0;
-    `endif
     kv_write_metrics.kv_data0_present     = 1'b0;
     kv_write_metrics.kv_data0_entry       = '0;
     kv_write_metrics.kv_data1_present     = 1'b0;
@@ -249,48 +308,91 @@
     .write_allow  (kv_write_allow  )
 );
 
-always_comb kv_write.write_en = dest_write_en;
-always_comb kv_write.write_offset = dest_write_offset;
-always_comb kv_write.write_dest_valid = (dest_write_en & dest_write_done & block_done) ?
-                                        (running_hek ? OCP_LOCK_HEK_SEED_DEST_VALID : 'd3) : '0;
-always_comb kv_write.write_entry = dest_addr;
-always_comb kv_write.write_data = dest_write_en ? dest_data[(DEST_NUM_DWORDS-1) - dest_write_offset[DEST_OFFSET_W-1:0]] : '0;
-
-always_comb src_write_data = running_uds ? obf_uds_seed[block_offset[UDS_BLOCK_OFFSET_W-1:0]] :
-                             running_fe  ? obf_field_entropy[block_offset[FE_BLOCK_OFFSET_W-1:0]] :
-                             running_hek ? obf_hek_seed[block_offset[HEK_BLOCK_OFFSET_W-1:0]] : '0;
-
-`CALIPTRA_PRIM_FLOP_SPARSE_FSM(u_doe_state_regs, kv_doe_fsm_ns, kv_doe_fsm_ps, kv_doe_fsm_state_e, DOE_IDLE, clk, rst_b, 0)
-
+// Drive outputs to KeyVault (suppressed immediately on zeroize or fsm_error)
+always_comb begin
+    kv_write.write_en         = dest_write_en;
+    kv_write.write_offset     = dest_write_offset;
+    kv_write.write_dest_valid = (dest_write_en && dest_write_done && block_done) ?
+                                (running_hek ? KV_NUM_READ'(OCP_LOCK_HEK_SEED_DEST_VALID) : 9'd3) : '0;
+    kv_write.write_entry      = dest_addr;
+    kv_write.write_data       = dest_write_en ? dest_data[(DEST_NUM_DWORDS-1) - dest_write_offset[DEST_OFFSET_W-1:0]] : '0;
+end
+
+// Pick obfuscated seed block based on latched flow command
+always_comb begin
+    if (fsm_error || zeroize) begin
+        src_write_data = '0;
+    end else if (running_uds) begin
+        src_write_data = obf_uds_seed[block_offset[UDS_BLOCK_OFFSET_W-1:0]];
+    end else if (running_fe) begin
+        src_write_data = obf_field_entropy[block_offset[FE_BLOCK_OFFSET_W-1:0]];
+    end else if (running_hek) begin
+        src_write_data = obf_hek_seed[block_offset[HEK_BLOCK_OFFSET_W-1:0]];
+    end else begin
+        src_write_data = '0;
+    end
+end
+
+// Sequential state for offsets, latched command, destination slot, and error tracking
 always_ff @(posedge clk or negedge rst_b) begin
     if (~rst_b) begin
-        dest_write_offset <= '0;
-        block_offset <= '0;
-        dest_addr <= '0;
+        dest_write_offset  <= '0;
+        block_offset       <= '0;
+        dest_addr          <= '0;
+        cmd_latched_q      <= DOE_NOP;
+        flow_err_latched_q <= 1'b0;
+    end else if (zeroize || fsm_error) begin
+        dest_write_offset  <= '0;
+        block_offset       <= '0;
+        dest_addr          <= '0;
+        cmd_latched_q      <= DOE_NOP;
+        flow_err_latched_q <= 1'b0;
+    end else begin
+        if (dest_addr_en) begin
+            dest_addr          <= dest_addr_nxt;
+            cmd_latched_q      <= doe_cmd_reg.cmd;
+            dest_write_offset  <= '0;
+            block_offset       <= '0;
+            flow_err_latched_q <= 1'b0;
+        end else begin
+            if (dest_write_offset_en) begin
+                dest_write_offset <= dest_write_offset_nxt;
+            end
+            if (block_offset_en) begin
+                block_offset <= block_offset_nxt;
+            end
+            if ((kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_WRITE)) && flow_error) begin
+                flow_err_latched_q <= 1'b1;
+            end else if (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_DONE)) begin
+                cmd_latched_q      <= DOE_NOP;
+                flow_err_latched_q <= 1'b0;
+            end
+        end
     end
-    else if (zeroize_reg) begin
-        dest_write_offset <= '0;
-        block_offset <= '0;
-        dest_addr <= '0;
+end
+
+// Monotonic sticky flow locks: reset ONLY on cold power-good reset (~hard_rst_b),
+// set ONLY upon error-free completion in DOE_DONE.
+logic valid_flow_complete;
+assign valid_flow_complete = (kv_doe_fsm_ps_raw == DoeStateWidth'(DOE_DONE)) &&
+                             !zeroize && !fsm_error && !flow_err_latched_q;
+
+always_ff @(posedge clk or negedge hard_rst_b) begin
+    if (~hard_rst_b) begin
+        lock_uds_flow <= 1'b0;
+        lock_fe_flow  <= 1'b0;
+        lock_hek_flow <= 1'b0;
+    end else begin
+        if (valid_flow_complete && (cmd_latched_q == DOE_UDS)) begin
+            lock_uds_flow <= 1'b1;
+        end
+        if (valid_flow_complete && (cmd_latched_q == DOE_FE)) begin
+            lock_fe_flow <= 1'b1;
+        end
+        if (valid_flow_complete && (cmd_latched_q == DOE_HEK)) begin
+            lock_hek_flow <= 1'b1;
+        end
     end
-    else begin
-        dest_write_offset <= dest_write_offset_en ? dest_write_offset_nxt : dest_write_offset;
-        block_offset <= block_offset_en ? block_offset_nxt : block_offset;
-        dest_addr <= dest_addr_en ? dest_addr_nxt : dest_addr;
-    end
-end
-
-always_ff @(posedge clk or negedge rst_b) begin
-    if (~rst_b) begin
-        lock_uds_flow <= '0;
-        lock_fe_flow <= '0;
-        lock_hek_flow <= '0;
-    end
-    else begin
-        lock_uds_flow <= (running_uds & flow_done) ? '1 : lock_uds_flow;
-        lock_fe_flow <= (running_fe & flow_done) ? '1 : lock_fe_flow;
-        lock_hek_flow <= (running_hek & flow_done) ? '1 : lock_hek_flow;
-    end
 end
 
 endmodule

--- a/environment/public/code/doe_ctrl.sv (Buggy Starter)
+++ b/solution/gold/code/doe_ctrl.sv (Golden Reference)
@@ -38,7 +38,7 @@
 
     input logic [TOTAL_OBF_KEY_BITS-1:0] cptra_obf_key,
 
-    // Obfuscated UDS and FE
+    // Obfuscated UDS, FE, and HEK
     input logic [`CLP_OBF_FE_DWORDS-1 :0][31:0] obf_field_entropy,
     input logic [`CLP_OBF_UDS_DWORDS-1:0][31:0] obf_uds_seed,
     input logic [OCP_LOCK_HEK_NUM_DWORDS-1:0][31:0] obf_hek_seed,
@@ -72,13 +72,40 @@
 );
 
     //----------------------------------------------------------------
-    // doe
+    // AHB-Lite decoded peripheral bus signals
     //----------------------------------------------------------------
     logic doe_cs;
     logic doe_we;
+    logic doe_we_qual;
     logic [AHB_ADDR_WIDTH-1:0] doe_address;
     logic [AHB_DATA_WIDTH-1:0] doe_write_data;
     logic [AHB_DATA_WIDTH-1:0] doe_read_data;
+
+    logic [11:0] addr_offset;
+    logic        is_iv_addr;
+    logic        is_ctrl_addr;
+    doe_cmd_e    wdata_cmd;
+    logic        is_clear_write;
+    logic        block_csr_write;
+    logic        sec_wipe_req;
+
+    assign addr_offset    = doe_address[11:0];
+    assign is_iv_addr     = (addr_offset == 12'h000) ||
+                            (addr_offset == 12'h004) ||
+                            (addr_offset == 12'h008) ||
+                            (addr_offset == 12'h00c);
+    assign is_ctrl_addr   = (addr_offset == 12'h010);
+    assign wdata_cmd      = doe_cmd_e'({doe_write_data[8:7], doe_write_data[1:0]});
+    assign is_clear_write = is_ctrl_addr && (wdata_cmd == DOE_CLEAR);
+
+    // Gate CSR writes to DOE_IV / DOE_CTRL when locked, faulted, or actively unwrapping
+    // (allowing emergency DOE_CLEAR while busy if unlocked and unfaulted).
+    assign block_csr_write = ((doe_cmd_lock || doe_fsm_error) && (is_iv_addr || is_ctrl_addr)) ||
+                             (busy_o && (is_iv_addr || (is_ctrl_addr && !is_clear_write)));
+    assign doe_we_qual     = doe_we && !block_csr_write;
+
+    // Trigger immediate hardware secret zeroization on sparse-FSM fault as well as debug/scan unlock.
+    assign sec_wipe_req    = debugUnlock_or_scan_mode_switch || doe_fsm_error;
 
     doe_cbc #(
         .ADDR_WIDTH(AHB_ADDR_WIDTH),
@@ -92,7 +119,7 @@
         .obf_field_entropy(obf_field_entropy),
         .obf_hek_seed(obf_hek_seed),
         .cs(doe_cs),
-        .we(doe_we),
+        .we(doe_we_qual),
         .address(doe_address),
         .write_data(doe_write_data[31:0]),
         .read_data(doe_read_data[31:0]),
@@ -105,10 +132,10 @@
         .kv_wr_resp(kv_wr_resp),
         .ocp_lock_en(ocp_lock_en),
         .doe_cmd_lock(doe_cmd_lock),
-        .debugUnlock_or_scan_mode_switch(debugUnlock_or_scan_mode_switch)
+        .debugUnlock_or_scan_mode_switch(sec_wipe_req)
     );
 
-    // instantiate ahb lite module
+    // Instantiate AHB-Lite slave interface
     ahb_slv_sif #(
         .AHB_ADDR_WIDTH(AHB_ADDR_WIDTH),
         .AHB_DATA_WIDTH(AHB_DATA_WIDTH),

--- a/environment/public/code/doe_key_mem.sv (Buggy Starter)
+++ b/solution/gold/code/doe_key_mem.sv (Golden Reference)
@@ -2,7 +2,7 @@
 //
 // doe_key_mem.sv
 // --------------
-// The DOE key memory including round key generator.
+// The DOE key memory including round key generator and full zeroization.
 //
 // Author: Joachim Strombergson
 // Copyright (c) 2013 Secworks Sweden AB
@@ -27,6 +27,9 @@
                    input wire  [31 : 0]  new_sboxw
                   );
 
+  //----------------------------------------------------------------
+  // Parameters.
+  //----------------------------------------------------------------
   localparam DOE_128_BIT_KEY = 1'h0;
   localparam DOE_256_BIT_KEY = 1'h1;
 
@@ -38,6 +41,9 @@
   localparam CTRL_GENERATE = 3'h2;
   localparam CTRL_DONE     = 3'h3;
 
+  //----------------------------------------------------------------
+  // Registers.
+  //----------------------------------------------------------------
   reg [127 : 0] key_mem [14 : 0];
   reg [127 : 0] key_mem_new;
   reg           key_mem_we;
@@ -70,14 +76,23 @@
   reg         rcon_set;
   reg         rcon_next;
 
+  //----------------------------------------------------------------
+  // Wires.
+  //----------------------------------------------------------------
   reg [31 : 0]  tmp_sboxw;
   reg           round_key_update;
   reg [127 : 0] tmp_round_key;
 
-  assign round_key = tmp_round_key;
+  //----------------------------------------------------------------
+  // Concurrent assignments for ports (masked immediately during zeroize).
+  //----------------------------------------------------------------
+  assign round_key = zeroize ? 128'h0 : tmp_round_key;
   assign ready     = ready_reg;
-  assign sboxw     = tmp_sboxw;
-
+  assign sboxw     = zeroize ? 32'h0  : tmp_sboxw;
+
+  //----------------------------------------------------------------
+  // reg_update
+  //----------------------------------------------------------------
   always @ (posedge clk or negedge reset_n)
     begin: reg_update
       integer ii;
@@ -96,12 +111,14 @@
         end
       else if (zeroize)
         begin
-          for (ii = 0 ; ii <= DOE_128_NUM_ROUNDS ; ii = ii + 1)
+          for (ii = 0 ; ii <= DOE_256_NUM_ROUNDS ; ii = ii + 1)
             key_mem [ii] <= 128'h0;
 
           ready_reg        <= 1'b0;
           rcon_reg         <= 8'h0;
           round_ctr_reg    <= 4'h0;
+          prev_key0_reg    <= 128'h0;
+          prev_key1_reg    <= 128'h0;
           key_mem_ctrl_reg <= CTRL_IDLE;
         end
       else
@@ -112,7 +129,7 @@
           if (rcon_we)
             rcon_reg <= rcon_new;
 
-          if (key_mem_we)
+          if (key_mem_we && (round_ctr_reg <= DOE_256_NUM_ROUNDS))
         
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
- [`environment/public/code/caliptra_prim_flop.sv`](environment/public/code/caliptra_prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_flop_macros.sv`](environment/public/code/caliptra_prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_generic_flop.sv`](environment/public/code/caliptra_prim_generic_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_module_name_macros.svh`](environment/public/code/caliptra_prim_module_name_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_mubi_pkg.sv`](environment/public/code/caliptra_prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_pkg.sv`](environment/public/code/caliptra_prim_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_sparse_fsm_flop.sv`](environment/public/code/caliptra_prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_sva.svh`](environment/public/code/caliptra_sva.svh) *(Read-Only Context)*
- [`environment/public/code/config_defines.svh`](environment/public/code/config_defines.svh) *(Read-Only Context)*
- [`environment/public/code/doe_cbc.sv`](environment/public/code/doe_cbc.sv) *(Read-Only Context)*
- [`environment/public/code/doe_core_cbc.sv`](environment/public/code/doe_core_cbc.sv) *(Read-Only Context)*
- [`environment/public/code/doe_ctrl.sv`](environment/public/code/doe_ctrl.sv) **(Editable)**
- [`environment/public/code/doe_decipher_block.sv`](environment/public/code/doe_decipher_block.sv) *(Read-Only Context)*
- [`environment/public/code/doe_defines_pkg.sv`](environment/public/code/doe_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/doe_encipher_block.sv`](environment/public/code/doe_encipher_block.sv) *(Read-Only Context)*
- [`environment/public/code/doe_fsm.sv`](environment/public/code/doe_fsm.sv) **(Editable)**
- [`environment/public/code/doe_inv_sbox.sv`](environment/public/code/doe_inv_sbox.sv) *(Read-Only Context)*
- [`environment/public/code/doe_key_mem.sv`](environment/public/code/doe_key_mem.sv) **(Editable)**
- [`environment/public/code/doe_reg.sv`](environment/public/code/doe_reg.sv) *(Read-Only Context)*
- [`environment/public/code/doe_reg_pkg.sv`](environment/public/code/doe_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/doe_sbox.sv`](environment/public/code/doe_sbox.sv) *(Read-Only Context)*
- [`environment/public/code/kv_defines_pkg.sv`](environment/public/code/kv_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kv_write_rule_check.sv`](environment/public/code/kv_write_rule_check.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/pdk/NangateOpenCellLibrary_typical.lib`](environment/public/pdk/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

