# `case_1013`: OpenTitan ROM Controller KMAC Error Handling, Comparator/Mux Alert Hardening, and Timing/Area Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1013` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `verification_debug` (Corner-Case Verification Blind Spots, Security Alerts, Lockstep & Triggers) |
| **Multi-Domain Tags** | `rtl_integration`, `rtl_semantics`, `synthesis_qor`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/rom_ctrl_fsm.sv`](environment/public/code/rom_ctrl_fsm.sv), [`code/rom_ctrl_compare.sv`](environment/public/code/rom_ctrl_compare.sv), [`code/rom_ctrl_mux.sv`](environment/public/code/rom_ctrl_mux.sv) (3 files, 445 LOC) |
| **Public Subsystem Context** | 31 RTL files (5905 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# OpenTitan ROM Controller KMAC Error Handling, Comparator/Mux Alert Hardening, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan ROM Controller subsystem (`code/ot_rom_ctrl_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **KMAC Error Handling During `ReadingHigh` State**:
   - In `rom_ctrl_fsm`, when `kmac_done_i` asserts while `state_q == ReadingHigh` (whether `counter_done` is `1'b0` or `1'b1`), `kmac_err_i` is not checked, allowing the FSM to advance to `KmacAhead` or `Checking` instead of transitioning to `Invalid` and raising `alert_o`.

2. **Comparator Re-Start Alert Detection**:
   - In `rom_ctrl_compare`, `start_alert` is tied low instead of asserting when `start_i` is high while the comparator FSM is not in `Waiting`, suppressing `alert_o` on spurious re-start pulses during `Checking` or `Done`.

3. **ROM Multiplexer Bus-Selection Revert Alert Detection**:
   - In `rom_ctrl_mux`, `sel_reverted` is tied low instead of detecting when `sel_bus_q` is true (loose MuBi4 check) while `sel_bus_i` reverts to false (loose MuBi4 check), failing to latch `alert_o` when the bus selection signal reverts after switching to the system bus.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_rom_ctrl_top`, `1.05 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_rom_ctrl_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/rom_ctrl_fsm.sv`, `code/rom_ctrl_compare.sv`, and `code/rom_ctrl_mux.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_rom_ctrl_top`: **`<= 1020.0 um^2`**
- Worst setup slack and worst hold slack at `1.05 ns` clock period: **`>= 0.0 ns`**

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/rom_ctrl_fsm.sv`
- `code/rom_ctrl_compare.sv`
- `code/rom_ctrl_mux.sv`

All other files in `code/` (`ot_rom_ctrl_top.sv`, `rom_ctrl_counter.sv`, `rom_ctrl_pkg.sv`, `rom_ctrl_reg_pkg.sv`, `kmac_pkg.sv`, `kmac_reg_pkg.sv`, `sha3_pkg.sv`, `lc_ctrl_pkg.sv`, `lc_ctrl_reg_pkg.sv`, `lc_ctrl_state_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_rom_ctrl_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv \
  code/lc_ctrl_pkg.sv code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
  code/rom_ctrl_reg_pkg.sv code/rom_ctrl_pkg.sv code/prim_flop_macros.sv \
  code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
  code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
  code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/rom_ctrl_counter.sv code/rom_ctrl_compare.sv code/rom_ctrl_fsm.sv \
  code/rom_ctrl_mux.sv code/ot_rom_ctrl_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_rom_ctrl_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_rom_ctrl_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv \
    code/lc_ctrl_pkg.sv code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
    code/rom_ctrl_reg_pkg.sv code/rom_ctrl_pkg.sv code/prim_flop_macros.sv \
    code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
    code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
    code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/rom_ctrl_counter.sv code/rom_ctrl_compare.sv code/rom_ctrl_fsm.sv \
    code/rom_ctrl_mux.sv code/ot_rom_ctrl_top.sv;
  hierarchy -check -top ot_rom_ctrl_top;
  synth -top ot_rom_ctrl_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr /tmp/mapped.v
"
```

Target mapped cell area (`Chip area for module '\ot_rom_ctrl_top'`): **`<= 1020.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `1.05 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_rom_ctrl_top
create_clock -name clk_i -period 1.05 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded -digits 4
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded -digits 4
```

Target worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`): **`>= 0.0 ns`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rom_ctrl_fsm.sv (Buggy Starter)
+++ b/solution/gold/code/rom_ctrl_fsm.sv (Golden Reference)
@@ -3,7 +3,7 @@
 // SPDX-License-Identifier: Apache-2.0
 
 //
-// The ROM checker FSM module
+// The ROM checker FSM module (Gold)
 //
 
 `include "prim_assert.sv"
@@ -112,8 +112,8 @@
       ReadingHigh: begin
         unique case ({kmac_done_i, counter_done})
           2'b01: state_d = RomAhead;
-          2'b10: state_d = KmacAhead;
-          2'b11: state_d = Checking;
+          2'b10: state_d = kmac_err_i ? Invalid : KmacAhead;
+          2'b11: state_d = kmac_err_i ? Invalid : Checking;
           default: ;
         endcase
       end
@@ -162,15 +162,13 @@
   assign digest_vld_o = kmac_done_i;
 
   logic reading_top;
-  logic [AW-1:0] rel_addr_wide;
   logic [TAW-1:0] rel_addr;
 
   assign reading_top = (state_q == ReadingHigh || state_q == KmacAhead) & ~counter_done;
-  assign rel_addr_wide = counter_data_addr - TopStartAddr;
-  assign rel_addr = rel_addr_wide[TAW-1:0];
-
-  logic unused_top_rel_addr_wide;
-  assign unused_top_rel_addr_wide = |rel_addr_wide[AW-1:TAW];
+  assign rel_addr    = counter_data_addr[TAW-1:0] - TopStartAddr[TAW-1:0];
+
+  logic unused_top_data_addr;
+  assign unused_top_data_addr = ^counter_data_addr[AW-1:TAW];
 
   assign exp_digest_o = rom_data_i;
   assign exp_digest_vld_o = reading_top;
@@ -205,7 +203,7 @@
     if (!rst_ni) begin
       start_checker_q <= 1'b0;
     end else begin
-      start_checker_q <= (state_d == Checking);
+      start_checker_q <= (state_q != Checking) && (state_d == Checking);
     end
   end
 

--- a/environment/public/code/rom_ctrl_compare.sv (Buggy Starter)
+++ b/solution/gold/code/rom_ctrl_compare.sv (Golden Reference)
@@ -3,7 +3,7 @@
 // SPDX-License-Identifier: Apache-2.0
 
 //
-// The comparator inside the ROM checker
+// The comparator inside the ROM checker (Gold)
 //
 
 `include "prim_assert.sv"
@@ -66,7 +66,7 @@
   end
 
   logic start_alert;
-  assign start_alert = 1'b0;
+  assign start_alert = start_i && (state_q != Waiting);
 
   logic wait_addr_alert;
   assign wait_addr_alert = (state_q == Waiting) && (addr_q != '0);
@@ -76,32 +76,20 @@
 
   assign addr_incr = (state_q == Checking) && (addr_q != LastAddr);
 
-  logic addr_ctr_alert;
-  prim_count #(
-    .Width(AW),
-    .PossibleActions({prim_count_pkg::Incr})
-  ) u_prim_count_addr (
-    .clk_i,
-    .rst_ni,
-    .clr_i(1'b0),
-    .set_i(1'b0),
-    .set_cnt_i('0),
-    .incr_en_i(addr_incr),
-    .decr_en_i(1'b0),
-    .step_i(AW'(1)),
-    .commit_i(1'b1),
-    .cnt_o(addr_q),
-    .cnt_after_commit_o(),
-    .err_o(addr_ctr_alert)
-  );
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      addr_q <= '0;
+    end else if (addr_incr) begin
+      addr_q <= addr_q + AW'(1);
+    end
+  end
 
-  logic [AW+5-1:0] digest_idx;
-  logic [31:0]     digest_word, exp_digest_word;
-  assign digest_idx = {addr_q, 5'd31};
-  assign digest_word = digest_i[digest_idx -: 32];
-  assign exp_digest_word = exp_digest_i[digest_idx -: 32];
+  logic [NumWords-1:0] word_eq;
+  for (genvar w = 0; w < NumWords; w++) begin : gen_word_eq
+    assign word_eq[w] = (digest_i[w*32 +: 32] == exp_digest_i[w*32 +: 32]);
+  end
 
-  assign matches_d = matches_q && (digest_word == exp_digest_word);
+  assign matches_d = matches_q && (&word_eq);
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
       matches_q <= 1'b1;
@@ -122,6 +110,6 @@
     .mubi_o (good_o)
   );
 
-  assign alert_o = fsm_alert | start_alert | wait_addr_alert | done_addr_alert | addr_ctr_alert;
+  assign alert_o = fsm_alert | start_alert | wait_addr_alert | done_addr_alert;
 
 endmodule

--- a/environment/public/code/rom_ctrl_mux.sv (Buggy Starter)
+++ b/solution/gold/code/rom_ctrl_mux.sv (Golden Reference)
@@ -3,7 +3,7 @@
 // SPDX-License-Identifier: Apache-2.0
 
 //
-// The mux to select between ROM inputs
+// The mux to select between ROM inputs (Gold)
 //
 
 module rom_ctrl_mux
@@ -65,7 +65,7 @@
   assign sel_invalid = mubi4_test_invalid(sel_bus_i) || mubi4_test_invalid(sel_bus_q);
 
   logic sel_reverted;
-  assign sel_reverted = 1'b0;
+  assign sel_reverted = mubi4_test_true_loose(sel_bus_q) & mubi4_test_false_loose(sel_bus_i);
 
   logic sel_q_reverted;
   assign sel_q_reverted = mubi4_test_true_loose(sel_bus_qq) & mubi4_test_false_loose(sel_bus_q);

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/kmac_pkg.sv`](environment/public/code/kmac_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kmac_reg_pkg.sv`](environment/public/code/kmac_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_pkg.sv`](environment/public/code/lc_ctrl_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_reg_pkg.sv`](environment/public/code/lc_ctrl_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_state_pkg.sv`](environment/public/code/lc_ctrl_state_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ot_rom_ctrl_top.sv`](environment/public/code/ot_rom_ctrl_top.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_buf.sv`](environment/public/code/prim_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count.sv`](environment/public/code/prim_count.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count_pkg.sv`](environment/public/code/prim_count_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop.sv`](environment/public/code/prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_en.sv`](environment/public/code/prim_flop_en.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi4_sender.sv`](environment/public/code/prim_mubi4_sender.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_buf.sv`](environment/public/code/prim_sec_anchor_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_flop.sv`](environment/public/code/prim_sec_anchor_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sparse_fsm_flop.sv`](environment/public/code/prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rom_ctrl_compare.sv`](environment/public/code/rom_ctrl_compare.sv) **(Editable)**
- [`environment/public/code/rom_ctrl_counter.sv`](environment/public/code/rom_ctrl_counter.sv) *(Read-Only Context)*
- [`environment/public/code/rom_ctrl_fsm.sv`](environment/public/code/rom_ctrl_fsm.sv) **(Editable)**
- [`environment/public/code/rom_ctrl_mux.sv`](environment/public/code/rom_ctrl_mux.sv) **(Editable)**
- [`environment/public/code/rom_ctrl_pkg.sv`](environment/public/code/rom_ctrl_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rom_ctrl_reg_pkg.sv`](environment/public/code/rom_ctrl_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sha3_pkg.sv`](environment/public/code/sha3_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/top_pkg.sv`](environment/public/code/top_pkg.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/LICENSE.Nangate45`](environment/public/lib/LICENSE.Nangate45) *(Read-Only Context)*
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

