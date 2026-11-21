# `case_2008`: Ibex Scrambling Two-Way ICache, IF Stage, Compressed Decoder, and Transparent Channel Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_2008` |
| **Source Silicon Repository** | `lowRISC/ibex` (`repo_02`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `gatelevel_physical_effects` (Gate-Level Implementation Effects, Scrambling/ECC & Cross-Stage Mismatch) |
| **Multi-Domain Tags** | `gatelevel_physical_effects`, `parameters_widths`, `rtl_integration`, `rtl_semantics`, `sdc_sta` |
| **Editable Files (`allowed_edits`)** | [`code/ibex_icache.sv`](environment/public/code/ibex_icache.sv), [`code/ibex_if_stage.sv`](environment/public/code/ibex_if_stage.sv), [`code/ibex_compressed_decoder.sv`](environment/public/code/ibex_compressed_decoder.sv), [`constraints.json`](environment/public/constraints.json) (4 files, 3266 LOC) |
| **Public Subsystem Context** | 28 RTL files (10110 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Task-Specific Multi-Corner Liberty & SDC Timing Views** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Custom characterized fast/slow/scan corner Liberty libraries for multi-mode OpenSTA closure. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Ibex Scrambling Two-Way ICache, IF Stage, Compressed Decoder, and Transparent Channel Timing Budgets

In the Ibex instruction cache and fetch front-end (`code/ibex_icache_if_subsys_top.sv`, integrating `code/ibex_icache.sv`, `code/ibex_if_stage.sv`, and `code/ibex_compressed_decoder.sv` with `ICache=1`, `ICacheECC=1`, `ICacheTweakInfection=1`, `MemECC=1`, `BranchPredictor=1`, `DummyInstructions=1`, and `BaseIsa=BaseIsaRV32IorCHERIoT`), functional verification and OpenSTA boundary timing checks currently fail:

1. **Scrambling Key Handshake, Cache Invalidation Sweep, Tweak Infection, ECC Recovery, and Unaligned Skid Faults (`code/ibex_icache.sv`)**:
   - **Scramble Key Request & Invalidation Restart**: Out of reset, if `ic_scr_key_valid_i` is low, the cache must assert `ic_scr_key_req_o` while transitioning to wait for the key. Once `ic_scr_key_valid_i` is high, it sweeps all tag indices (`0 .. 2^IC_INDEX_W - 1`). If a new `icache_inval_i` pulse arrives either during normal idle operation or while an invalidation sweep is already in progress, the cache must immediately request a new scramble key (`ic_scr_key_req_o = 1'b1`), return to wait for `ic_scr_key_valid_i`, and restart the tag sweep from index `0`.
   - **Address Tweak Infection (`TweakInfection == 1`)**: Tag writes and reads must XOR/un-XOR the replicated tag index tweak, and data writes and reads must XOR/un-XOR the replicated line-aligned address tweak. During tag invalidation sweeps or single-index ECC correction writebacks, the data address tweak must be forced to zero.
   - **28-Bit Tag & 39-Bit Data SECDED ECC Recovery (`ICacheECC == 1`)**: Tag ECC is checked across all ways on every valid lookup, whereas data ECC must be checked only when a lookup hits a valid tag way (avoiding false ECC errors on cache misses where data RAM lines are uninitialized). Any tag or data ECC error on a valid lookup must assert `ecc_error_o`, suppress the cache hit so the fill buffer fetches the line from external memory instead, and perform a one-cycle tag invalidation write (`ic_tag_write_o = 1'b1` with invalid tag) on the following cycle (invalidating all ways on a tag ECC error, or the matching way(s) on a data ECC error).
   - **Unaligned 32-Bit Instruction Skid Buffer Fault Attribution**: When a 32-bit instruction spans two 32-bit beats (`addr_o[1] == 1'b1`) via the 16-bit skid buffer, an error on the first beat must report `err_o = 1'b1, err_plus2_o = 1'b0` immediately without waiting for the second beat, whereas a clean first beat followed by an error on the second beat must report `err_o = 1'b1, err_plus2_o = 1'b1`.

2. **Memory Bus SECDED Integrity, Branch Misprediction Squash, and Zcmp Expansion (`code/ibex_if_stage.sv`, `code/ibex_compressed_decoder.sv`)**:
   - In `code/ibex_if_stage.sv`, 39-bit SECDED integrity errors on incoming `instr_rdata_i` (`MemECC == 1`) must both assert `instr_intg_err_o` (when `instr_rvalid_i` is high) and propagate as an instruction fetch error into `ibex_icache`. When `nt_branch_mispredict_i` asserts to cancel a predicted-taken branch, any instruction simultaneously presented by `ibex_icache` must be squashed rather than entering the IF/ID pipeline or branch-predictor skid buffer.
   - In `code/ibex_compressed_decoder.sv`, `cm.pop`, `cm.popret`, and `cm.popretz` must mark intermediate stack-pointer adjustment (`addi x2, x2, sp_adj`) and `addi a0, x0, 0` steps with `INSTR_EXPANDED_COMMIT` (and `INSTR_EXPANDED_LAST` on the final step), and any exception redirect (`pc_set_i && pc_mux_i == PC_EXC`) must synchronously flush the Zcmp expansion state back to idle.

3. **Declarative Boundary Timing Budgets for Monitoring Channels (`constraints.json`)**:
   - In `code/ibex_icache_if_subsys_top.sv`, the subsystem operates at `10.0 ns` and `12.0 ns` clock periods (`clk_i`), with a `3.5 ns` external input delay on all non-clock inputs and a `3.0 ns` external output delay on all outputs. Constrain the two zero-cut 8-bit combinational monitoring channels in `constraints.json` (`"max_delays"`) using the schema in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.25 ns` for `scr_mon_in` to `scr_mon_out` and `2.25 ns` for `pmp_mon_in` to `pmp_mon_out`, while preserving the existing timing requirements for all other ports.

Edit only `code/ibex_icache.sv`, `code/ibex_if_stage.sv`, `code/ibex_compressed_decoder.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following four files are collected and graded:
- `code/ibex_icache.sv`
- `code/ibex_if_stage.sv`
- `code/ibex_compressed_decoder.sv`
- `constraints.json`

All other files in `code/` and `lib/` (`code/ibex_icache_if_subsys_top.sv`, `code/ibex_pkg.sv`, `code/ibex_cheriot_pkg.sv`, `code/ibex_fetch_fifo.sv`, `code/ibex_prefetch_buffer.sv`, `code/ibex_dummy_instr.sv`, `code/ibex_branch_predict.sv`, `code/prim_*`, `code/dv_fcov_macros.svh`, `lib/*`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/ibex_icache_if_subsys_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Werror-LATCH -Wno-fatal -DSYNTHESIS -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/prim_util_pkg.sv code/prim_cipher_pkg.sv code/prim_secded_pkg.sv \
  code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
  code/prim_buf.sv code/prim_lfsr.sv \
  code/prim_secded_inv_28_22_dec.sv code/prim_secded_inv_28_22_enc.sv \
  code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
  code/ibex_fetch_fifo.sv code/ibex_prefetch_buffer.sv code/ibex_icache.sv \
  code/ibex_dummy_instr.sv code/ibex_branch_predict.sv \
  code/ibex_compressed_decoder.sv code/ibex_if_stage.sv \
  code/ibex_icache_if_subsys_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names:
- Input groups include `scr_mon_in` (or `scr_mon_in[0..7]`), `pmp_mon_in` (or `pmp_mon_in[0..7]`), and the functional inputs of `ibex_icache_if_subsys_top`.
- Output groups include `scr_mon_out` (or `scr_mon_out[0..7]`), `pmp_mon_out` (or `pmp_mon_out[0..7]`), and the functional outputs of `ibex_icache_if_subsys_top`.
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10.0 ns` or `12.0 ns` on `clk_i`), `3.5 ns` input delay on all non-clock inputs (`set_input_delay 3.5 -clock clk_i`), and `3.0 ns` output delay on all outputs (`set_output_delay 3.0 -clock clk_i`), using `lib/NangateOpenCellLibrary_typical.lib` and OpenROAD/OpenSTA. Zero latches are allowed.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ibex_icache.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_icache.sv (Golden Reference)
@@ -327,7 +327,10 @@
     // when there is already an ECC error (we have already raised a minor alert).
     logic [ADDR_W-1:0]           data_address_ic0;
     logic [ADDR_W-IC_LINE_W-1:0] data_tweak_ic0;
-    assign data_address_ic0 = fill_grant_ic0 ? fill_ram_req_addr : lookup_addr_ic0;
+    assign data_address_ic0 = inval_write_req ? '0 :
+                              ecc_write_req   ? '0 :
+                              fill_grant_ic0  ? fill_ram_req_addr :
+                                                lookup_addr_ic0;
 
     // Mask the IC_LINE_W LSBs to remove the offset within a cache line.
     assign data_tweak_ic0 = data_address_ic0[ADDR_W-1:IC_LINE_W];
@@ -586,7 +589,7 @@
     // and all further tag writes produce correct ECC. For data ECC no initialisation is done on
     // reset so unused data (in particular those ways that don't have a valid tag) may have
     // incorrect ECC. We only check data ECC where tags indicate it is valid and we have hit on it.
-    assign ecc_err_ic1 = lookup_valid_ic1 & ((|data_err_ic1) | (|tag_err_ic1));
+    assign ecc_err_ic1 = lookup_valid_ic1 & (((|data_err_ic1) & tag_hit_ic1) | (|tag_err_ic1));
 
     // Error correction
     // All ways will be invalidated on a tag error to prevent X-propagation from data_err_ic1 on
@@ -749,7 +752,7 @@
                                  (fill_cache_q[fb] & fill_busy_q[fb] &
                                   icache_enable_i & ~icache_inval_i);
     // Record whether the request hit in the cache
-    assign fill_hit_ic1[fb]    = lookup_valid_ic1 & fill_in_ic1[fb] & tag_hit_ic1;
+    assign fill_hit_ic1[fb]    = lookup_valid_ic1 & fill_in_ic1[fb] & tag_hit_ic1 & ~ecc_err_ic1;
     assign fill_hit_d[fb]      = fill_hit_ic1[fb] | (fill_hit_q[fb] & fill_busy_q[fb]);
 
     ///////////////////////////////////////////
@@ -1198,7 +1201,7 @@
   assign err_o       = (skid_valid_q & skid_err_q) | (~skid_complete_instr & output_err);
   // Error caused by the second half of a misaligned uncompressed instruction
   // (only relevant when err_o is set)
-  assign err_plus2_o = skid_valid_q & skid_err_q;
+  assign err_plus2_o = skid_valid_q & ~skid_err_q;
 
   ///////////////////
   // Invalidations //
@@ -1223,7 +1226,12 @@
 
     unique case (inval_state_q)
       OUT_OF_RESET: begin
+        // Initial state, this initialises the tag RAMs out of reset before the icache can be used
         inval_state_d = AWAIT_SCRAMBLE_KEY;
+
+        if (~ic_scr_key_valid_i) begin
+          ic_scr_key_req_o = 1'b1;
+        end
       end
       AWAIT_SCRAMBLE_KEY: begin
         // When invalidating a new scrambling key is requested on all invalidation requests. Wait
@@ -1244,7 +1252,12 @@
         inval_index_d   = (inval_index_q + {{IC_INDEX_W-1{1'b0}},1'b1});
         inval_index_en  = 1'b1;
 
-        if (&inval_index_q) begin
+        if (icache_inval_i) begin
+          // If a new invalidation requests comes in go back to the beginning with a new scramble
+          // key
+          ic_scr_key_req_o = 1'b1;
+          inval_state_d = AWAIT_SCRAMBLE_KEY;
+        end else if (&inval_index_q) begin
           // When the final index is written we're done
             inval_state_d = INVAL_IDLE;
         end

--- a/environment/public/code/ibex_if_stage.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_if_stage.sv (Golden Reference)
@@ -279,7 +279,7 @@
     assign instr_intg_err            = 1'b0;
   end
 
-  assign instr_err        = instr_bus_err_i;
+  assign instr_err        = instr_intg_err | instr_bus_err_i;
   assign instr_intg_err_o = instr_intg_err & instr_rvalid_i;
 
   // There are two possible "branch please" signals that are computed in the IF stage: branch_req
@@ -290,7 +290,7 @@
 
   // The fetch_valid signal that comes out of the icache or prefetch buffer should be squashed if we
   // had a misprediction.
-  assign fetch_valid = fetch_valid_raw;
+  assign fetch_valid = fetch_valid_raw & ~nt_branch_mispredict_i;
 
   // We should never see a mispredict and an incoming branch on the same cycle. The mispredict also
   // cancels any predicted branch so overall branch_req must be low.

--- a/environment/public/code/ibex_compressed_decoder.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_compressed_decoder.sv (Golden Reference)
@@ -742,7 +742,8 @@
                       instr_o = cm_sp_addi(.rlist(instr_i[7:4]),
                                           .spimm(instr_i[3:2]),
                                           .decr(1'b0));
-                      gets_expanded = INSTR_EXPANDED;
+                      // Ensure the SP adjustment commits atomically with the subsequent micro-ops.
+                      gets_expanded = INSTR_EXPANDED_COMMIT;
                       if (id_in_ready_i) begin
                         unique case (instr_i[12:8])
                           5'b11100: cm_state_d = CmPopZeroA0; // cm.popretz
@@ -893,7 +894,7 @@
     if (!rst_ni) begin
       cm_state_q <= CmIdle;
     end else begin
-      cm_state_q <= cm_state_d;
+      cm_state_q <= flush_expanded_i ? CmIdle : cm_state_d;
     end
   end
 

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,22 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": [
+        "scr_mon_in"
+      ],
+      "to": [
+        "scr_mon_out"
+      ],
+      "ns": 7.75
+    },
+    {
+      "from": [
+        "pmp_mon_in"
+      ],
+      "to": [
+        "pmp_mon_out"
+      ],
+      "ns": 8.75
+    }
+  ]
 }

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/dv_fcov_macros.svh`](environment/public/code/dv_fcov_macros.svh) *(Read-Only Context)*
- [`environment/public/code/ibex_branch_predict.sv`](environment/public/code/ibex_branch_predict.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_cheriot_pkg.sv`](environment/public/code/ibex_cheriot_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_compressed_decoder.sv`](environment/public/code/ibex_compressed_decoder.sv) **(Editable)**
- [`environment/public/code/ibex_dummy_instr.sv`](environment/public/code/ibex_dummy_instr.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_fetch_fifo.sv`](environment/public/code/ibex_fetch_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_icache.sv`](environment/public/code/ibex_icache.sv) **(Editable)**
- [`environment/public/code/ibex_icache_if_subsys_top.sv`](environment/public/code/ibex_icache_if_subsys_top.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_if_stage.sv`](environment/public/code/ibex_if_stage.sv) **(Editable)**
- [`environment/public/code/ibex_pkg.sv`](environment/public/code/ibex_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_prefetch_buffer.sv`](environment/public/code/ibex_prefetch_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_buf.sv`](environment/public/code/prim_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_cipher_pkg.sv`](environment/public/code/prim_cipher_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_lfsr.sv`](environment/public/code/prim_lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inc.svh`](environment/public/code/prim_secded_inc.svh) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_28_22_dec.sv`](environment/public/code/prim_secded_inv_28_22_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_28_22_enc.sv`](environment/public/code/prim_secded_inv_28_22_enc.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_dec.sv`](environment/public/code/prim_secded_inv_39_32_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_enc.sv`](environment/public/code/prim_secded_inv_39_32_enc.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_pkg.sv`](environment/public/code/prim_secded_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/constraints.json`](environment/public/constraints.json) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lib/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.tech.lef`](environment/public/lib/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

