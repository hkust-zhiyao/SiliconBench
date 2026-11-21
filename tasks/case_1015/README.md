# `case_1015`: OpenTitan OTBN Two-Round Secure Wipe, Loop-End Commit Hazard, Full-Stack Push/Pop Replacement, and Timing/Area Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1015` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `reset_rdc` (Reset Recovery, Abort Drain, Reset Domain Crossing (RDC) & Boot Sequencing) |
| **Multi-Domain Tags** | `reset_rdc`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/otbn_start_stop_control.sv`](environment/public/code/otbn_start_stop_control.sv), [`code/otbn_loop_controller.sv`](environment/public/code/otbn_loop_controller.sv), [`code/otbn_stack.sv`](environment/public/code/otbn_stack.sv) (3 files, 994 LOC) |
| **Public Subsystem Context** | 47 RTL files (12709 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# OpenTitan OTBN Two-Round Secure Wipe, Loop-End Commit Hazard, Full-Stack Push/Pop Replacement, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan OTBN Start/Stop, Loop Stack, and Call Stack Subsystem (`code/ot_otbn_ctrl_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **Start/Stop Two-Round Secure Wipe Sequencing and RMA Acknowledgement**:
   - In `otbn_start_stop_control`, when `OtbnStartStopSecureWipeAllZero` is reached with `mubi4_test_false_strict(wipe_after_urnd_refresh_q)` (first round of random wiping), the FSM transitions directly to `OtbnStartStopSecureWipeComplete` instead of setting `wipe_after_urnd_refresh_d = MuBi4True`, keeping `secure_wipe_running_d = 1'b1`, and transitioning to `OtbnStartStopStateUrndRefresh` for the second wipe round. In addition, in `OtbnStartStopSecureWipeComplete`, `rma_ack_d` fails to latch `rma_req_i`.

2. **Loop Controller At-End Loop Start Error and Commit Priority**:
   - In `otbn_loop_controller`, `loop_at_end_err` is tied low instead of detecting `at_current_loop_end_insn & loop_start_req_i`, and `loop_stack_commit` is driven by `loop_start_commit_i | loop_stack_pop` instead of giving `loop_stack_push_req` priority (`loop_stack_push_req ? loop_start_commit_i : loop_stack_pop`), causing an aborted loop-start request at the end of a finishing loop (`loop_start_commit_i == 0`) to still commit a pop/write on the loop stack.

3. **Full-Stack Combined Push and Pop Replacement**:
   - In `otbn_stack`, `stack_write` is gated by `~full_o` instead of `(~full_o | pop_i)` and `stack_wr_idx` does not select `stack_rd_idx` when `pop_i` is high, dropping the pushed element instead of replacing the top element when a combined push and pop occurs on a full or non-empty stack.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_otbn_ctrl_top`, `2.20 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_otbn_ctrl_top` exceeds the mapped cell area budget and violates setup timing across the loop/call stack read-compare-pop datapath.

## Deliverable

Update the editable RTL files (`code/otbn_start_stop_control.sv`, `code/otbn_loop_controller.sv`, and `code/otbn_stack.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_otbn_ctrl_top`: **`<= 8550.0 um^2`**
- Worst setup slack and worst hold slack at `2.20 ns` clock period: **`>= 0.0 ns`**

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/otbn_start_stop_control.sv`
- `code/otbn_loop_controller.sv`
- `code/otbn_stack.sv`

All other files in `code/` (`ot_otbn_ctrl_top.sv`, `otbn_pkg.sv`, `otbn_reg_pkg.sv`, `otp_ctrl_pkg.sv`, `keymgr_dpe_pkg.sv`, `keymgr_dpe_reg_pkg.sv`, `edn_pkg.sv`, `csrng_pkg.sv`, `csrng_reg_pkg.sv`, `entropy_src_pkg.sv`, `kmac_pkg.sv`, `kmac_reg_pkg.sv`, `sha3_pkg.sv`, `lc_ctrl_pkg.sv`, `lc_ctrl_reg_pkg.sv`, `lc_ctrl_state_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_otbn_ctrl_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_trivium_pkg.sv \
  code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv code/lc_ctrl_pkg.sv \
  code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
  code/entropy_src_pkg.sv code/csrng_reg_pkg.sv code/csrng_pkg.sv \
  code/edn_pkg.sv code/keymgr_dpe_reg_pkg.sv code/keymgr_dpe_pkg.sv \
  code/otp_ctrl_pkg.sv code/otbn_reg_pkg.sv code/otbn_pkg.sv \
  code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv \
  code/prim_buf.sv code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
  code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
  code/otbn_stack.sv code/otbn_loop_controller.sv \
  code/otbn_start_stop_control.sv code/ot_otbn_ctrl_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_otbn_ctrl_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_otbn_ctrl_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_trivium_pkg.sv \
    code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv code/lc_ctrl_pkg.sv \
    code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
    code/entropy_src_pkg.sv code/csrng_reg_pkg.sv code/csrng_pkg.sv \
    code/edn_pkg.sv code/keymgr_dpe_reg_pkg.sv code/keymgr_dpe_pkg.sv \
    code/otp_ctrl_pkg.sv code/otbn_reg_pkg.sv code/otbn_pkg.sv \
    code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv \
    code/prim_buf.sv code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
    code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
    code/otbn_stack.sv code/otbn_loop_controller.sv \
    code/otbn_start_stop_control.sv code/ot_otbn_ctrl_top.sv;
  hierarchy -check -top ot_otbn_ctrl_top;
  synth -top ot_otbn_ctrl_top;
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

Target mapped cell area (`Chip area for module '\ot_otbn_ctrl_top'`): **`<= 8550.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.20 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_otbn_ctrl_top
create_clock -name clk_i -period 2.20 [get_ports clk_i]
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
--- a/environment/public/code/otbn_start_stop_control.sv (Buggy Starter)
+++ b/solution/gold/code/otbn_start_stop_control.sv (Golden Reference)
@@ -365,13 +365,23 @@
 
         // Leave this state after a single cycle, which is sufficient to reset the CSRs and the
         // stack.
-        state_d = OtbnStartStopSecureWipeComplete;
-        secure_wipe_running_d = 1'b0;
-        secure_wipe_ack_o     = 1'b1;
+        if (mubi4_test_false_strict(wipe_after_urnd_refresh_q)) begin
+          // This is the first round of wiping with random numbers, refresh URND and do a second
+          // round.
+          state_d = OtbnStartStopStateUrndRefresh;
+          secure_wipe_running_d     = 1'b1;
+          wipe_after_urnd_refresh_d = MuBi4True;
+        end else begin
+          // This is the second round of wiping with random numbers, so the secure wipe is
+          // complete.
+          state_d = OtbnStartStopSecureWipeComplete;
+          secure_wipe_running_d = 1'b0;
+          secure_wipe_ack_o     = 1'b1;
+        end
       end
       OtbnStartStopSecureWipeComplete: begin
         urnd_advance_o = 1'b1;
-        rma_ack_d = rma_ack_q;
+        rma_ack_d = rma_req_i;
         state_d = should_lock_d ? OtbnStartStopStateLocked : OtbnStartStopStateHalt;
         wipe_after_urnd_refresh_d = MuBi4False;
       end

--- a/environment/public/code/otbn_loop_controller.sv (Buggy Starter)
+++ b/solution/gold/code/otbn_loop_controller.sv (Golden Reference)
@@ -65,6 +65,7 @@
 
   logic        at_current_loop_end_insn;
   logic        current_loop_finish;
+  logic        top_iter_is_one_q;
   logic        current_loop_counter_dec;
   logic [38:0] current_loop_addrs_padded_intg_unbuf, current_loop_addrs_padded_intg_buf;
   logic [1:0]  current_loop_intg_err;
@@ -150,8 +151,7 @@
   // The iteration decrement happens at loop end. So when execution reaches the end instruction of
   // the current loop with 1 iteration that is the end of the final iteration and the current loop
   // finishes.
-  assign current_loop_finish = at_current_loop_end_insn & (current_loop.loop_iterations == 1)
-    & ~otbn_stall_i;
+  assign current_loop_finish = at_current_loop_end_insn & top_iter_is_one_q & ~otbn_stall_i;
 
   // Jump to top of current loop when execution reaches the end instruction of the current loop it
   // isn't finished.
@@ -161,7 +161,7 @@
   assign loop_iteration_err      = (loop_iterations_i == '0) & loop_start_req_i;
   assign loop_branch_err         = at_current_loop_end_insn & jump_or_branch_i;
   assign loop_stack_overflow_err = loop_stack_push_req & loop_stack_full;
-  assign loop_at_end_err         = 1'b0;
+  assign loop_at_end_err         = at_current_loop_end_insn & loop_start_req_i;
 
   assign sw_err_o = loop_iteration_err      |
                     loop_branch_err         |
@@ -187,7 +187,7 @@
   // start takes priority otherwise when we get an push and pop request at the same time, which
   // triggers a software error, we can commit whilst requesting push and pop which we should never
   // do.
-  assign loop_stack_commit = loop_start_commit_i | loop_stack_pop;
+  assign loop_stack_commit = loop_stack_push_req ? loop_start_commit_i : loop_stack_pop;
 
   otbn_stack #(
     .StackWidth($bits(loop_addr_info_t)),
@@ -220,50 +220,39 @@
     .next_top_valid_o(next_loop_valid)
   );
 
-  for(genvar i_count = 0; i_count < LoopStackDepth; i_count = i_count + 1) begin : g_loop_counters
-    logic loop_count_set;
-    logic loop_count_dec;
-
-    assign loop_count_set = loop_stack_write & (loop_stack_wr_idx == i_count) & loop_stack_commit;
-    assign loop_count_dec = current_loop_counter_dec & (loop_stack_rd_idx == i_count);
-
-    //SEC_CM: LOOP_STACK.CTR.REDUN
-    prim_count #(
-      .Width(32),
-      .ResetValue({32{1'b1}})
-    ) u_loop_count (
-      .clk_i,
-      .rst_ni,
-      .clr_i             (state_reset_i),
-      .set_i             (loop_count_set),
-      .set_cnt_i         (new_loop.loop_iterations),
-      .incr_en_i         (1'b0),
-      .decr_en_i         (loop_count_dec), // count down
-      .step_i            (32'd1),
-      .commit_i          (1'b1),
-      .cnt_o             (loop_counters[i_count]),
-      .cnt_after_commit_o(),
-      .err_o             (loop_counter_err[i_count])
-    );
-
-    assign loop_counter_err_d[i_count] = loop_counter_err_q[i_count] | loop_counter_err[i_count];
-
-    // Cannot clear and set prim_count in the same cycle
-    `ASSERT(NoLoopCountClrAndSet_A, !(state_reset_i & loop_count_set))
+  logic [31:0] top_iter_q, top_iter_d, current_loop_iterations_dec, prev_iter_w;
+  logic [StackDepthW-1:0] loop_stack_rd_idx_dec;
+
+  assign loop_stack_rd_idx_dec       = loop_stack_rd_idx - 1'b1;
+  assign prev_iter_w                 = loop_counters[loop_stack_rd_idx_dec];
+  assign current_loop_iterations_dec = top_iter_q - 32'd1;
+
+  always_ff @(posedge clk_i) begin
+    if (loop_stack_write & loop_stack_commit & ~state_reset_i) begin
+      loop_counters[loop_stack_rd_idx] <= top_iter_q;
+    end
   end
 
-  prim_flop #(
-    .Width(LoopStackDepth),
-    .ResetValue('0)
-  ) u_loop_counter_err_flop (
-    .clk_i,
-    .rst_ni,
-
-    .d_i(loop_counter_err_d),
-    .q_o(loop_counter_err_q)
-  );
-
-  assign current_loop.loop_iterations = loop_counters[loop_stack_rd_idx];
+  assign top_iter_d =
+    (loop_stack_write & loop_stack_commit) ? new_loop.loop_iterations    :
+    (loop_stack_pop & loop_stack_commit)   ? prev_iter_w                 :
+    current_loop_counter_dec               ? current_loop_iterations_dec :
+                                             top_iter_q;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      top_iter_q        <= {32{1'b1}};
+      top_iter_is_one_q <= 1'b0;
+    end else if (state_reset_i) begin
+      top_iter_q        <= {32{1'b1}};
+      top_iter_is_one_q <= 1'b0;
+    end else if ((loop_stack_write & loop_stack_commit) | loop_stack_pop | current_loop_counter_dec) begin
+      top_iter_q        <= top_iter_d;
+      top_iter_is_one_q <= (top_iter_d == 32'd1);
+    end
+  end
+
+  assign current_loop.loop_iterations = top_iter_q;
 
   assign current_loop_addrs_padded_intg_unbuf =
     {current_loop.loop_addr_info.loop_addrs_intg,
@@ -278,7 +267,6 @@
     .out_o(current_loop_addrs_padded_intg_buf)
   );
 
-  //SEC_CM: LOOP_STACK.ADDR.INTEGRITY
   prim_secded_inv_39_32_dec u_loop_addrs_intg_dec (
     .data_i     (current_loop_addrs_padded_intg_buf),
     .data_o     (),
@@ -286,30 +274,18 @@
     .err_o      (current_loop_intg_err)
   );
 
-  assign hw_err_o = (|loop_counter_err_d) |
-                    loop_stack_cnt_err    |
-                    ((|current_loop_intg_err) & current_loop_valid);
+  assign hw_err_o = loop_stack_cnt_err | ((|current_loop_intg_err) & current_loop_valid);
 
   assign predec_err_o =
     (loop_end_addr_predec_i != new_loop_end_addr_full[ImemAddrWidth-1:0]) & loop_start_req_i;
 
-  // Forward info about loop state for next cycle to prefetch stage
   assign prefetch_loop_active_o = next_loop_valid;
 
-  // Iterations for the current loop on the next cycle depend upon a number of factors
-  // - If the loop stack is being popped the next counter on the stack provides the new iterations
-  // - If the current loop iterations are being decremented new iterations are the decremented value
-  // - If a new loop is starting it's iterations are the new iterations
-  // - Otherwise next loop iterations is just the current loop iterations
-  logic [31:0] current_loop_iterations_dec;
-  logic [StackDepthW-1:0] loop_stack_rd_idx_dec;
-  assign current_loop_iterations_dec = current_loop.loop_iterations - 32'd1;
-  assign loop_stack_rd_idx_dec = loop_stack_rd_idx - 1'b1;
   assign prefetch_loop_iterations_o =
-    loop_stack_pop           ? loop_counters[loop_stack_rd_idx_dec] :
-    current_loop_counter_dec ? current_loop_iterations_dec          :
-    loop_stack_write         ? new_loop.loop_iterations             :
-                               current_loop.loop_iterations;
+    loop_stack_pop           ? prev_iter_w                 :
+    current_loop_counter_dec ? current_loop_iterations_dec :
+    loop_stack_write         ? new_loop.loop_iterations    :
+                               top_iter_q;
 
   logic unused_next_loop_addr_info_intg;
   assign unused_next_loop_addr_info_intg = ^next_loop_addr_info.loop_addrs_intg;

--- a/environment/public/code/otbn_stack.sv (Buggy Starter)
+++ b/solution/gold/code/otbn_stack.sv (Golden Reference)
@@ -2,23 +2,6 @@
 // Licensed under the Apache License, Version 2.0, see LICENSE for details.
 // SPDX-License-Identifier: Apache-2.0
 
-/**
- * Simple stack parameterised on width and depth
- *
- * When a push and pop occur in the same cycle the pop is ordered before the push (so top_data_o
- * reflects what was on top of the stack, which is retrieved by the pop, the push then immediately
- * replaces this with a new piece of data). Internal checking is performed for full & empty
- * conditions so a push on full/pop on empty is allowable, though meaningless. For a push on full
- * the data will be dropped, for a pop no empty there is no valid data to pop. The exception is
- * a combined push & pop on full, here the top is popped off and replaced with what is pushed, no
- * data is dropped.
- *
- * The read and write pointers and read and write signals are exposed as `stack_rd_idx_i,
- * `stack_wr_idx_o`, `stack_write_o` and `stack_read_o`. `next_top_data_o` and `next_top_valid_o`
- * provide the top_data_o and top_valid_o output that will be seen in the following cycle if
- * `commit_i` is set. This is to enable users to extend the stack in case where it's not a simple
- * matter of adding extra data bits (e.g. where this is a prim_count instance per stack entry).
- */
 module otbn_stack
   import otbn_pkg::*;
 #(
@@ -30,24 +13,18 @@
   input clk_i,
   input rst_ni,
 
-  output logic                  full_o,      // Stack is full
+  output logic                  full_o,
+  output logic                  cnt_err_o,
+  input  logic                  clear_i,
 
-  output logic                  cnt_err_o,   // Stack counters are wrong
+  input  logic                  push_i,
+  input  logic [StackWidth-1:0] push_data_i,
 
-  input logic                   clear_i,     // Clear all data
+  input  logic                  pop_i,
+  output logic [StackWidth-1:0] top_data_o,
+  output logic                  top_valid_o,
 
-  input  logic                  push_i,      // Push the data
-  input  logic [StackWidth-1:0] push_data_i, // Data to push
-
-  input  logic                  pop_i,       // Pop top of the stack
-  output logic [StackWidth-1:0] top_data_o,  // Data on top of the stack
-  output logic                  top_valid_o, // Stack is non empty (`top_data_o` is valid)
-
-  input  logic                  commit_i,    // Commit the push/pop action. If commit is not
-                                             // asserted push/pop will not take effect, though
-                                             // next_top_data_o and next_top_valid_o will still
-                                             // indicate the next stack state if the action did
-                                             // occur.
+  input  logic                  commit_i,
 
   output logic [StackDepthW-1:0] stack_wr_idx_o,
   output logic                   stack_write_o,
@@ -58,83 +35,57 @@
   output logic                   next_top_valid_o
 );
   logic [StackWidth-1:0]  stack_storage [StackDepth];
-  logic [StackDepthW:0]   stack_wr_ptr;
-  logic [StackDepthW-1:0] stack_rd_idx, stack_wr_idx;
-  logic [StackDepthW:0]   next_stack_wr_ptr;
-  logic [StackDepthW-1:0] next_stack_rd_idx;
-  logic                   cnt_err, cnt_err_d, cnt_err_q;
+  logic [StackDepthW:0]   stack_wr_ptr, next_stack_wr_ptr;
+  logic [StackDepthW-1:0] stack_rd_idx_q, stack_prev_idx_q, stack_wr_idx;
+  logic [StackWidth-1:0]  top_data_q, prev_data_w;
+  logic                   stack_empty_q, stack_full_q;
+  logic                   stack_write, stack_read;
 
-  logic stack_empty;
-  logic stack_full;
+  assign stack_write = push_i & (~stack_full_q | pop_i);
+  assign stack_read  = ~stack_empty_q & pop_i;
 
-  logic stack_write;
-  logic stack_read;
+  assign next_stack_wr_ptr = clear_i                     ? '0 :
+                             (stack_write & ~stack_read) ? (stack_wr_ptr + (StackDepthW+1)'(1'b1)) :
+                             (~stack_write & stack_read) ? (stack_wr_ptr - (StackDepthW+1)'(1'b1)) :
+                                                           stack_wr_ptr;
+  assign stack_wr_idx = pop_i ? stack_rd_idx_q : stack_wr_ptr[StackDepthW-1:0];
+  assign prev_data_w  = stack_storage[stack_prev_idx_q];
 
-  logic stack_wr_ptr_commit;
-
-  assign stack_empty = stack_wr_ptr == '0;
-  assign stack_full  = stack_wr_ptr == StackDepth[StackDepthW:0];
-
-  assign stack_write = push_i & ~full_o;
-  assign stack_read  = top_valid_o & pop_i;
-
-  assign stack_rd_idx = stack_wr_ptr[StackDepthW-1:0] - 1'b1;
-  assign stack_wr_idx = stack_wr_ptr[StackDepthW-1:0];
-
-  assign stack_wr_ptr_commit = clear_i | commit_i;
-
-  // SEC_CM: STACK_WR_PTR.CTR.REDUN
-  prim_count #(
-    .Width        (StackDepthW+1)
-  ) u_stack_wr_ptr (
-    .clk_i,
-    .rst_ni,
-    .clr_i              (clear_i),
-    .set_i              (1'b0),
-    .set_cnt_i          ('0),
-    .incr_en_i          (stack_write),
-    .decr_en_i          (stack_read),
-    .step_i             ((StackDepthW+1)'(1'b1)),
-    .commit_i           (stack_wr_ptr_commit),
-    .cnt_o              (stack_wr_ptr),
-    .cnt_after_commit_o (next_stack_wr_ptr),
-    .err_o              (cnt_err)
-  );
-
-  assign cnt_err_d = cnt_err_q | cnt_err;
-
-  prim_flop #(
-    .Width(1),
-    .ResetValue('0)
-  ) u_cnt_err_flop (
-    .clk_i,
-    .rst_ni,
-
-    .d_i(cnt_err_d),
-    .q_o(cnt_err_q)
-  );
-
-  assign cnt_err_o = cnt_err_d;
-
-  always_ff @(posedge clk_i) begin
-    if (stack_write & commit_i) begin
-      stack_storage[stack_wr_idx] <= push_data_i;
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      stack_wr_ptr     <= '0;
+      stack_rd_idx_q   <= '1;
+      stack_prev_idx_q <= StackDepthW'(StackDepth - 2);
+      stack_empty_q    <= 1'b1;
+      stack_full_q     <= 1'b0;
+    end else if (clear_i | commit_i) begin
+      stack_wr_ptr     <= next_stack_wr_ptr;
+      stack_rd_idx_q   <= next_stack_wr_ptr[StackDepthW-1:0] - 1'b1;
+      stack_prev_idx_q <= next_stack_wr_ptr[StackDepthW-1:0] - 2'd2;
+      stack_empty_q    <= (next_stack_wr_ptr == '0);
+      stack_full_q     <= (next_stack_wr_ptr == StackDepth[StackDepthW:0]);
     end
   end
 
+  always_ff @(posedge clk_i) begin
+    if (stack_write & commit_i & ~clear_i) begin
+      stack_storage[stack_wr_idx] <= push_data_i;
+      top_data_q                  <= push_data_i;
+    end else if (stack_read & commit_i & ~clear_i) begin
+      top_data_q                  <= prev_data_w;
+    end
+  end
 
-  assign full_o      = stack_full;
-  assign top_data_o  = stack_storage[stack_rd_idx];
-  assign top_valid_o = ~stack_empty;
-
-  assign stack_wr_idx_o = stack_wr_idx;
-  assign stack_rd_idx_o = stack_rd_idx;
-  assign stack_write_o  = stack_write;
-  assign stack_read_o   = stack_read;
-
-  assign next_stack_rd_idx = next_stack_wr_ptr[StackDepthW-1:0] - 1'b1;
-
-  assign next_top_data_o = stack_write ? push_data_i : stack_storage[next_stack_rd_idx];
-  assign next_top_valid_o = next_stack_wr_ptr != '0;
-
+  assign full_o           = stack_full_q;
+  assign cnt_err_o        = 1'b0;
+  assign top_data_o       = top_data_q;
+  assign top_valid_o      = ~stack_empty_q;
+  assign stack_wr_idx_o   = stack_wr_idx;
+  assign stack_rd_idx_o   = stack_rd_idx_q;
+  assign stack_write_o    = stack_write;
+  assign stack_read_o     = stack_read;
+  assign next_top_data_o  = stack_write ? push_data_i :
+                            stack_read  ? prev_data_w :
+                                          top_data_q;
+  assign next_top_valid_o = (next_stack_wr_ptr != '0);
 endmodule

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/csrng_pkg.sv`](environment/public/code/csrng_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/csrng_reg_pkg.sv`](environment/public/code/csrng_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/edn_pkg.sv`](environment/public/code/edn_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/entropy_src_pkg.sv`](environment/public/code/entropy_src_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/keymgr_dpe_pkg.sv`](environment/public/code/keymgr_dpe_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/keymgr_dpe_reg_pkg.sv`](environment/public/code/keymgr_dpe_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kmac_pkg.sv`](environment/public/code/kmac_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kmac_reg_pkg.sv`](environment/public/code/kmac_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_pkg.sv`](environment/public/code/lc_ctrl_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_reg_pkg.sv`](environment/public/code/lc_ctrl_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_state_pkg.sv`](environment/public/code/lc_ctrl_state_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ot_otbn_ctrl_top.sv`](environment/public/code/ot_otbn_ctrl_top.sv) *(Read-Only Context)*
- [`environment/public/code/otbn_loop_controller.sv`](environment/public/code/otbn_loop_controller.sv) **(Editable)**
- [`environment/public/code/otbn_pkg.sv`](environment/public/code/otbn_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/otbn_reg_pkg.sv`](environment/public/code/otbn_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/otbn_stack.sv`](environment/public/code/otbn_stack.sv) **(Editable)**
- [`environment/public/code/otbn_start_stop_control.sv`](environment/public/code/otbn_start_stop_control.sv) **(Editable)**
- [`environment/public/code/otp_ctrl_pkg.sv`](environment/public/code/otp_ctrl_pkg.sv) *(Read-Only Context)*
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
- [`environment/public/code/prim_mubi4_sender.sv`](environment/public/code/prim_mubi4_sender.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_buf.sv`](environment/public/code/prim_sec_anchor_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_flop.sv`](environment/public/code/prim_sec_anchor_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inc.svh`](environment/public/code/prim_secded_inc.svh) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_dec.sv`](environment/public/code/prim_secded_inv_39_32_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_enc.sv`](environment/public/code/prim_secded_inv_39_32_enc.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_64_57_dec.sv`](environment/public/code/prim_secded_inv_64_57_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_64_57_enc.sv`](environment/public/code/prim_secded_inv_64_57_enc.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_pkg.sv`](environment/public/code/prim_secded_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sparse_fsm_flop.sv`](environment/public/code/prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_trivium_pkg.sv`](environment/public/code/prim_trivium_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
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

