# `case_1014`: OpenTitan Entropy Complex GEN Abort Uninstantiation, Boot-Mode Uninstantiate Sequence, Endpoint Ack Immediate Pop, and Timing/Area Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1014` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `reset_rdc` (Reset Recovery, Abort Drain, Reset Domain Crossing (RDC) & Boot Sequencing) |
| **Multi-Domain Tags** | `reset_rdc`, `rtl_integration`, `rtl_semantics`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/csrng_cmd_stage.sv`](environment/public/code/csrng_cmd_stage.sv), [`code/edn_main_sm.sv`](environment/public/code/edn_main_sm.sv), [`code/edn_ack_sm.sv`](environment/public/code/edn_ack_sm.sv) (3 files, 968 LOC) |
| **Public Subsystem Context** | 29 RTL files (4881 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# OpenTitan Entropy Complex GEN Abort Uninstantiation, Boot-Mode Uninstantiate Sequence, Endpoint Ack Immediate Pop, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan Entropy Complex Command & Endpoint Subsystem (`code/ot_entropy_cmd_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **CSRNG Command Stage GEN Abort Uninstantiation and Genbits FIFO Flush**:
   - In `csrng_cmd_stage`, when an in-flight `GEN` abort completes (`state_q == CmdAck && cmd_ack_i && gen_abort_inflight_q`), `instantiated_d` is not cleared to `1'b0` and `sfifo_genbits_clr` does not include `cmd_gen_abort_ack`, leaving `instantiated_q` set (rejecting a subsequent `INS` command as `CMD_STS_INVALID_CMD_SEQ`) and leaving stale `genbits` in the output buffer.

2. **EDN Main State Machine Boot-Mode Uninstantiate Sequence and Disable Done Pulse**:
   - In `edn_main_sm`, when `boot_req_mode_i` deasserts in `BootDone`, the FSM transitions directly to `Idle` instead of `BootLoadUni` (skipping the boot-mode `UNI` command and its `BootUniAckWait` completion), and when `edn_enable_i` deasserts in an active legal state, `main_sm_done_pulse_o` is not pulsed high.

3. **EDN Endpoint Ack State Machine Immediate FIFO Pop on Ready Data**:
   - In `edn_ack_sm`, when `req_i` asserts in `Idle` while `fifo_not_empty_i` is already high, `fifo_pop_o` is not asserted, failing to pop the consumed word from the genbits FIFO.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_entropy_cmd_top`, `1.15 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_entropy_cmd_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/csrng_cmd_stage.sv`, `code/edn_main_sm.sv`, and `code/edn_ack_sm.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_entropy_cmd_top`: **`<= 2320.0 um^2`**
- Worst setup slack and worst hold slack at `1.15 ns` clock period: **`>= 0.0 ns`**

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/csrng_cmd_stage.sv`
- `code/edn_main_sm.sv`
- `code/edn_ack_sm.sv`

All other files in `code/` (`ot_entropy_cmd_top.sv`, `csrng_main_sm.sv`, `csrng_pkg.sv`, `csrng_reg_pkg.sv`, `edn_pkg.sv`, `entropy_src_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_entropy_cmd_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/entropy_src_pkg.sv code/csrng_reg_pkg.sv \
  code/csrng_pkg.sv code/edn_pkg.sv code/prim_flop_macros.sv \
  code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
  code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
  code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/csrng_cmd_stage.sv code/csrng_main_sm.sv \
  code/edn_main_sm.sv code/edn_ack_sm.sv code/ot_entropy_cmd_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_entropy_cmd_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_entropy_cmd_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/entropy_src_pkg.sv code/csrng_reg_pkg.sv \
    code/csrng_pkg.sv code/edn_pkg.sv code/prim_flop_macros.sv \
    code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
    code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
    code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
    code/csrng_cmd_stage.sv code/csrng_main_sm.sv \
    code/edn_main_sm.sv code/edn_ack_sm.sv code/ot_entropy_cmd_top.sv;
  hierarchy -check -top ot_entropy_cmd_top;
  synth -top ot_entropy_cmd_top;
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

Target mapped cell area (`Chip area for module '\ot_entropy_cmd_top'`): **`<= 2320.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `1.15 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_entropy_cmd_top
create_clock -name clk_i -period 1.15 [get_ports clk_i]
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
--- a/environment/public/code/csrng_cmd_stage.sv (Buggy Starter)
+++ b/solution/gold/code/csrng_cmd_stage.sv (Golden Reference)
@@ -199,23 +199,18 @@
          cmd_gen_flag_q;
 
   // SEC_CM: GEN_CMD.CTR.REDUN
-  prim_count #(
-    .Width(GenBitsCtrWidth),
-    .ResetValue({GenBitsCtrWidth{1'b1}})
-  ) u_prim_count_cmd_gen_cntr (
-    .clk_i,
-    .rst_ni,
-    .clr_i(!cs_enable_i),
-    .set_i(cmd_gen_1st_req),
-    .set_cnt_i(sfifo_cmd_rdata[12 +: GenBitsCtrWidth]),
-    .incr_en_i(1'b0),
-    .decr_en_i(cmd_gen_cnt_dec), // Count down.
-    .step_i(GenBitsCtrWidth'(1)),
-    .commit_i(1'b1),
-    .cnt_o(cmd_gen_cnt),
-    .cnt_after_commit_o(),
-    .err_o(cmd_gen_cnt_err_o)
-  );
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      cmd_gen_cnt <= {GenBitsCtrWidth{1'b1}};
+    end else if (!cs_enable_i) begin
+      cmd_gen_cnt <= {GenBitsCtrWidth{1'b1}};
+    end else if (cmd_gen_1st_req) begin
+      cmd_gen_cnt <= sfifo_cmd_rdata[12 +: GenBitsCtrWidth];
+    end else if (cmd_gen_cnt_dec) begin
+      cmd_gen_cnt <= cmd_gen_cnt - GenBitsCtrWidth'(1);
+    end
+  end
+  assign cmd_gen_cnt_err_o = 1'b0;
 
   // For naming consistency.
   assign local_escalate = cmd_gen_cnt_err_o;
@@ -449,6 +444,7 @@
             // receiving the ACK from the state database (from csrng_ctr_drbg_gen).
             if (gen_abort_inflight_q) begin
               // Acknowledge the aborted GEN command.
+              instantiated_d = 1'b0;
               cmd_gen_abort_ack = 1'b1;
               state_d = Idle;
             end else begin
@@ -512,28 +508,31 @@
   // Genbits FIFO.
   //---------------------------------------------------------
 
-  prim_fifo_sync #(
-    .Width(GenBitsFifoWidth),
-    .Pass(0),
-    .Depth(GenBitsFifoDepth),
-    .OutputZeroIfEmpty(0) // Set to 0, and let last data drive out.
-  ) u_prim_fifo_genbits (
-    .clk_i   (clk_i),
-    .rst_ni  (rst_ni),
-    .clr_i   (sfifo_genbits_clr),
-    .wvalid_i(sfifo_genbits_wvld),
-    .wready_o(sfifo_genbits_wrdy),
-    .wdata_i (sfifo_genbits_wdata),
-    .rvalid_o(sfifo_genbits_rvld),
-    .rready_i(sfifo_genbits_rrdy),
-    .rdata_o (sfifo_genbits_rdata),
-    .full_o  (),
-    .depth_o (), // sfifo_genbits_depth)
-    .err_o   ()
-  );
+  logic genbits_full_q;
+  logic genbits_push, genbits_pop;
+  assign sfifo_genbits_wrdy = ~genbits_full_q;
+  assign sfifo_genbits_rvld = genbits_full_q;
+  assign genbits_push = sfifo_genbits_wvld & sfifo_genbits_wrdy;
+  assign genbits_pop  = sfifo_genbits_rrdy & sfifo_genbits_rvld;
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      genbits_full_q <= 1'b0;
+    end else if (sfifo_genbits_clr) begin
+      genbits_full_q <= 1'b0;
+    end else if (genbits_push) begin
+      genbits_full_q <= 1'b1;
+    end else if (genbits_pop) begin
+      genbits_full_q <= 1'b0;
+    end
+  end
+  always_ff @(posedge clk_i) begin
+    if (genbits_push) begin
+      sfifo_genbits_rdata <= sfifo_genbits_wdata;
+    end
+  end
 
   // Clear u_prim_fifo_genbits when CSRNG is disabled or on a GEN abort.
-  assign sfifo_genbits_clr = !cs_enable_i;
+  assign sfifo_genbits_clr = !cs_enable_i || cmd_gen_abort_ack;
 
   assign sfifo_genbits_wdata = {genbits_fips_i,genbits_bus_i};
 

--- a/environment/public/code/edn_main_sm.sv (Buggy Starter)
+++ b/solution/gold/code/edn_main_sm.sv (Golden Reference)
@@ -44,6 +44,7 @@
   `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, state_e, Idle)
 
   assign main_sm_state_o = state_q;
+  assign reject_csrng_entropy_o = (state_q == RejectCsrngEntropy) & (edn_enable_i | local_escalate_i | csrng_ack_err_i);
 
   always_comb begin
     state_d                = state_q;
@@ -59,7 +60,6 @@
     send_rescmd_o          = 1'b0;
     main_sm_done_pulse_o   = 1'b0;
     main_sm_err_o          = 1'b0;
-    reject_csrng_entropy_o = 1'b0;
     sw_cmd_mode_o         = 1'b0;
     unique case (state_q)
       Idle: begin
@@ -101,7 +101,7 @@
       end
       BootDone: begin
         if (!boot_req_mode_i) begin
-          state_d = Idle;
+          state_d = BootLoadUni;
         end
       end
       BootLoadUni: begin
@@ -174,7 +174,6 @@
         sw_cmd_mode_o = 1'b1;
       end
       RejectCsrngEntropy: begin
-        reject_csrng_entropy_o = 1'b1;
       end
       Error: begin
         main_sm_err_o = 1'b1;
@@ -223,8 +222,7 @@
       capt_rescmd_fifo_cnt_o = 1'b0;
       send_rescmd_o          = 1'b0;
       sw_cmd_mode_o          = 1'b0;
-      reject_csrng_entropy_o = 1'b0;
-      main_sm_done_pulse_o   = 1'b0;
+      main_sm_done_pulse_o   = 1'b1;
     end
   end
 

--- a/environment/public/code/edn_ack_sm.sv (Buggy Starter)
+++ b/solution/gold/code/edn_ack_sm.sv (Golden Reference)
@@ -71,7 +71,12 @@
       end
       Idle: begin
         if (req_i) begin
-          state_d = DataWait;
+          if (fifo_not_empty_i) begin
+            fifo_pop_o = 1'b1;
+            state_d = AckPls;
+          end else begin
+            state_d = DataWait;
+          end
         end
       end
       DataWait: begin

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/csrng_cmd_stage.sv`](environment/public/code/csrng_cmd_stage.sv) **(Editable)**
- [`environment/public/code/csrng_main_sm.sv`](environment/public/code/csrng_main_sm.sv) *(Read-Only Context)*
- [`environment/public/code/csrng_pkg.sv`](environment/public/code/csrng_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/csrng_reg_pkg.sv`](environment/public/code/csrng_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/edn_ack_sm.sv`](environment/public/code/edn_ack_sm.sv) **(Editable)**
- [`environment/public/code/edn_main_sm.sv`](environment/public/code/edn_main_sm.sv) **(Editable)**
- [`environment/public/code/edn_pkg.sv`](environment/public/code/edn_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/entropy_src_pkg.sv`](environment/public/code/entropy_src_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ot_entropy_cmd_top.sv`](environment/public/code/ot_entropy_cmd_top.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_buf.sv`](environment/public/code/prim_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count.sv`](environment/public/code/prim_count.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count_pkg.sv`](environment/public/code/prim_count_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_assert.svh`](environment/public/code/prim_fifo_assert.svh) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync.sv`](environment/public/code/prim_fifo_sync.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync_cnt.sv`](environment/public/code/prim_fifo_sync_cnt.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop.sv`](environment/public/code/prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_en.sv`](environment/public/code/prim_flop_en.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_buf.sv`](environment/public/code/prim_sec_anchor_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_flop.sv`](environment/public/code/prim_sec_anchor_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sparse_fsm_flop.sv`](environment/public/code/prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
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

