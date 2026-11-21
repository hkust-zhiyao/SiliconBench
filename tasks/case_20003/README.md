# `case_20003`: Fix biRISC-V Dual-Parcel Speculative/Architectural RAS Recovery, Two-Slot BTB Evaluation, and Fetch Redirect Handshake

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_20003` |
| **Source Silicon Repository** | `ultraembedded/biriscv` (`repo_44`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Core_RISCV_Processors` (Core_RISCV_Processors) |
| **Multi-Domain Tags** | `Core_RISCV_Processors` |
| **Editable Files (`allowed_edits`)** | [`code/biriscv_npc.v`](environment/public/code/biriscv_npc.v), [`code/biriscv_fetch.v`](environment/public/code/biriscv_fetch.v) (2 files, 755 LOC) |
| **Public Subsystem Context** | 8 RTL files (3643 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Dual-Parcel Speculative Prediction, RAS Recovery, and Redirect Handshake in `biriscv_npc` + `biriscv_fetch`

`code/biriscv_npc.v` and `code/biriscv_fetch.v` form the 64-bit dual-parcel instruction fetch and branch-prediction engine inside `code/biriscv_frontend.v` (feeding `code/biriscv_decode.v`, with branch resolution metadata produced by `code/biriscv_exec.v` and `code/biriscv_issue.v`).

Under nested `JAL`/`JALR` function calls and returns, mixed lower/upper 32-bit parcel control flow, instruction-cache backpressure, and frontend redirects, speculative prediction state diverges from architectural state and wrong-path/duplicate fetch parcels occur. Update `code/biriscv_npc.v` and `code/biriscv_fetch.v` while preserving all module ports and parameters (`SUPPORT_BRANCH_PREDICTION`, `NUM_BTB_ENTRIES*`, `NUM_BHT_ENTRIES*`, `RAS_ENABLE`, `GSHARE_ENABLE`, `BHT_ENABLE`, `NUM_RAS_ENTRIES*`, `SUPPORT_MMU`) so that:

1. **Return Address Stack (RAS) Speculation & Rollback (`biriscv_npc.v`)**:
   - Unconditional calls (`JAL` and indirect `JALR` calls, regardless of `BHT_ENABLE` or BHT counter state) must predict taken once learned in the BTB and push the exact architectural link address (`call_pc + 4` for whichever 32-bit slot holds the call) onto the speculative RAS even when the current RAS top entry is still unpopulated/invalid after reset. Return predictions must only pop and redirect to the RAS top when that entry holds a valid pushed return address.
   - Maintain architectural RAS stack contents and pointer across **all** resolved taken calls and returns (both predicted and mispredicted), and on **any** `branch_request_i` redirect (including conditional-branch mispredictions or redirects after wrong-path speculative calls/returns), restore both the speculative RAS pointer and stack contents to the post-resolution architectural RAS state.

2. **64-Bit Dual-Slot BTB / BHT / GShare Evaluation & Invalidation (`biriscv_npc.v`)**:
   - Prevent false BTB matches on unallocated entries after reset (e.g. at `PC = 0x0`), and clear allocated BTB entries when `invalidate_i` asserts.
   - For aligned 64-bit fetches (`pc_f_i[2] == 0`), evaluate Slot 0 (`pc_f_i[31:3] << 3`) first; if Slot 0 is predicted taken, output `next_taken_f_o = 2'b01` so downstream decode masks off Slot 1. If Slot 0 misses in the BTB **or** hits in the BTB as a conditional branch predicted **not-taken**, fall through to evaluate Slot 1 (`(pc_f_i[31:3] << 3) | 32'd4`), outputting `next_taken_f_o = 2'b10` when Slot 1 is predicted taken so Slot 1 still executes.
   - For mid-parcel fetches (`pc_f_i[2] == 1`), ignore Slot 0 and evaluate only Slot 1 (`pc_f_i`). Keep speculative and architectural GHR indexing consistent across both slots and across non-mispredicted branch resolutions.

3. **Redirect Ordering, ICache Handshake & Flush Retention (`biriscv_fetch.v`)**:
   - On any `branch_request_i` cycle (under both `SUPPORT_MMU = 1` and `SUPPORT_MMU = 0`), immediately suppress `fetch_valid_o`, `icache_rd_o`, and `pc_accept_o`, clear any buffered skid parcel, and mark any in-flight `icache` read so its stale `icache_valid_i` response is discarded without dropping or double-fetching the subsequent post-redirect target parcel. Track `branch_priv_i` on `icache_priv_o` when `SUPPORT_MMU = 1` (`PRIV_MACHINE` when `SUPPORT_MMU = 0`).
   - Assert `pc_accept_o` if and only if an `icache_rd_o` request actually handshakes (`icache_rd_o && icache_accept_i`). Retain backpressured responses in the skid buffer across arbitrarily many `fetch_accept_i == 0` cycles until accepted or flushed by `branch_request_i`, and retain `fetch_invalidate_i` on `icache_flush_o` until accepted by `icache_accept_i` (without issuing concurrent `icache_rd_o` requests while a flush is pending).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Guide

## Workspace Files
- **Editable RTL**: `code/biriscv_npc.v`, `code/biriscv_fetch.v`
- **Read-Only Context RTL**: `code/biriscv_frontend.v`, `code/biriscv_decode.v`, `code/biriscv_decoder.v`, `code/biriscv_exec.v`, `code/biriscv_issue.v`, `code/biriscv_defs.v`

## Tooling Examples
```bash
# Structural / synthesis check (zero latches, zero combinational loops)
yosys -p "
  read_verilog -sv -DSYNTHESIS -Icode code/biriscv_defs.v code/biriscv_npc.v code/biriscv_fetch.v code/biriscv_decoder.v code/biriscv_decode.v code/biriscv_frontend.v;
  hierarchy -check -top biriscv_frontend -chparam SUPPORT_MMU 1 -chparam GSHARE_ENABLE 1;
  proc; opt_expr; check -assert;
  select -assert-none t:\$dlatch*
"

# Verilator elaboration & simulation
verilator --binary -sv -Wno-fatal -Icode --top-module biriscv_frontend \
  code/biriscv_defs.v code/biriscv_npc.v code/biriscv_fetch.v code/biriscv_decoder.v code/biriscv_decode.v code/biriscv_frontend.v
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/biriscv_npc.v (Buggy Starter)
+++ b/solution/gold/code/biriscv_npc.v (Golden Reference)
@@ -8,25 +8,7 @@
 //
 //                     License: Apache 2.0
 //-----------------------------------------------------------------
-// Copyright 2020 Ultra-Embedded.com
-// 
-// Licensed under the Apache License, Version 2.0 (the "License");
-// you may not use this file except in compliance with the License.
-// You may obtain a copy of the License at
-// 
-//     http://www.apache.org/licenses/LICENSE-2.0
-// 
-// Unless required by applicable law or agreed to in writing, software
-// distributed under the License is distributed on an "AS IS" BASIS,
-// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-// See the License for the specific language governing permissions and
-// limitations under the License.
-//-----------------------------------------------------------------
-
 module biriscv_npc
-//-----------------------------------------------------------------
-// Params
-//-----------------------------------------------------------------
 #(
      parameter SUPPORT_BRANCH_PREDICTION = 1
     ,parameter NUM_BTB_ENTRIES  = 32
@@ -39,11 +21,7 @@
     ,parameter NUM_RAS_ENTRIES  = 8
     ,parameter NUM_RAS_ENTRIES_W = 3
 )
-//-----------------------------------------------------------------
-// Ports
-//-----------------------------------------------------------------
 (
-    // Inputs
      input           clk_i
     ,input           rst_i
     ,input           invalidate_i
@@ -58,232 +36,245 @@
     ,input  [ 31:0]  pc_f_i
     ,input           pc_accept_i
 
-    // Outputs
     ,output [ 31:0]  next_pc_f_o
     ,output [  1:0]  next_taken_f_o
 );
 
-
-
 localparam RAS_INVALID = 32'h00000001;
 
-//-----------------------------------------------------------------
-// Branch prediction (BTB, BHT, RAS)
-//-----------------------------------------------------------------
 generate
 if (SUPPORT_BRANCH_PREDICTION)
 begin: BRANCH_PREDICTION
 
-wire        pred_taken_w;
-wire        pred_ntaken_w;
-
-// Info from BTB
-wire        btb_valid_w;
-wire        btb_upper_w;
-wire [31:0] btb_next_pc_w;
-wire        btb_is_call_w;
-wire        btb_is_ret_w;
-
-//-----------------------------------------------------------------
-// Return Address Stack (actual)
-//-----------------------------------------------------------------
+//-----------------------------------------------------------------
+// Architectural (committed/resolved) Return Address Stack
+//-----------------------------------------------------------------
+reg [31:0]                  ras_stack_real_q[NUM_RAS_ENTRIES-1:0];
 reg [NUM_RAS_ENTRIES_W-1:0] ras_index_real_q;
 reg [NUM_RAS_ENTRIES_W-1:0] ras_index_real_r;
 
+wire real_call_push_w = RAS_ENABLE & branch_is_taken_i & branch_is_call_i;
+wire real_ret_pop_w   = RAS_ENABLE & branch_is_taken_i & branch_is_ret_i;
+
 always @ *
 begin
     ras_index_real_r = ras_index_real_q;
-
-    if (branch_request_i & branch_is_call_i)
-        ras_index_real_r = ras_index_real_q + 1;
-    else if (branch_request_i & branch_is_ret_i)
-        ras_index_real_r = ras_index_real_q - 1;
-end
-
-always @ (posedge clk_i or posedge rst_i)
-if (rst_i)
+    if (real_call_push_w)
+        ras_index_real_r = ras_index_real_q + {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};
+    else if (real_ret_pop_w)
+        ras_index_real_r = ras_index_real_q - {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};
+end
+
+integer ir;
+always @ (posedge clk_i or posedge rst_i)
+if (rst_i)
+begin
+    for (ir = 0; ir < NUM_RAS_ENTRIES; ir = ir + 1)
+        ras_stack_real_q[ir] <= RAS_INVALID;
     ras_index_real_q <= {NUM_RAS_ENTRIES_W{1'b0}};
+end
 else
+begin
+    if (real_call_push_w)
+        ras_stack_real_q[ras_index_real_r] <= branch_source_i + 32'd4;
     ras_index_real_q <= ras_index_real_r;
-
-//-----------------------------------------------------------------
-// Return Address Stack (speculative)
-//-----------------------------------------------------------------
-reg [31:0] ras_stack_q[NUM_RAS_ENTRIES-1:0];
+end
+
+//-----------------------------------------------------------------
+// Speculative Return Address Stack
+//-----------------------------------------------------------------
+reg [31:0]                  ras_stack_q[NUM_RAS_ENTRIES-1:0];
 reg [NUM_RAS_ENTRIES_W-1:0] ras_index_q;
 
-reg [NUM_RAS_ENTRIES_W-1:0] ras_index_r;
-
-wire [31:0] ras_pc_pred_w   = ras_stack_q[ras_index_q];
-wire        ras_call_pred_w = RAS_ENABLE & (btb_valid_w & btb_is_call_w) & ~ras_pc_pred_w[0];
-wire        ras_ret_pred_w  = RAS_ENABLE & (btb_valid_w & btb_is_ret_w) & ~ras_pc_pred_w[0];
-
-always @ *
-begin
-    ras_index_r = ras_index_q;
-
-    // Mispredict - go from confirmed call stack index
-    if (branch_request_i & branch_is_call_i)
-        ras_index_r = ras_index_real_q + 1;
-    else if (branch_request_i & branch_is_ret_i)
-        ras_index_r = ras_index_real_q - 1;
-    // Speculative call / returns
-    else if (ras_call_pred_w & pc_accept_i)
-        ras_index_r = ras_index_q + 1;
-    else if (ras_ret_pred_w & pc_accept_i)
-        ras_index_r = ras_index_q - 1;
-end
-
-integer i3;
-always @ (posedge clk_i or posedge rst_i)
-if (rst_i)
-begin
-    for (i3 = 0; i3 < NUM_RAS_ENTRIES; i3 = i3 + 1) 
-    begin
-        ras_stack_q[i3] <= RAS_INVALID;
-    end
-
-    ras_index_q <= {NUM_RAS_ENTRIES_W{1'b0}};
-end
-// On a call push return address onto RAS stack (current PC + 4)
-else if (branch_request_i & branch_is_call_i)
-begin
-    ras_stack_q[ras_index_r] <= branch_source_i + 32'd4;
-    ras_index_q              <= ras_index_r;
-end
-// On a call push return address onto RAS stack (current PC + 4)
-else if (ras_call_pred_w & pc_accept_i)
-begin
-    ras_stack_q[ras_index_r] <= (btb_upper_w ? (pc_f_i | 32'd4) : pc_f_i) + 32'd4;
-    ras_index_q              <= ras_index_r;
-end
-// Return - pop item from stack
-else if ((ras_ret_pred_w & pc_accept_i) || (branch_request_i & branch_is_ret_i))
-begin
-    ras_index_q              <= ras_index_r;
-end
-
-//-----------------------------------------------------------------
-// Global history register (actual history)
+wire [31:0] ras_pc_pred_w = ras_stack_q[ras_index_q];
+wire        ras_top_ok_w  = RAS_ENABLE & ~ras_pc_pred_w[0];
+
+//-----------------------------------------------------------------
+// Global history register (actual & speculative)
 //-----------------------------------------------------------------
 reg [NUM_BHT_ENTRIES_W-1:0] global_history_real_q;
+wire                        branch_resolved_w = branch_is_taken_i | branch_is_not_taken_i;
+wire [NUM_BHT_ENTRIES_W-1:0] global_history_real_next_w = branch_resolved_w ?
+    {global_history_real_q[NUM_BHT_ENTRIES_W-2:0], branch_is_taken_i} :
+    global_history_real_q;
 
 always @ (posedge clk_i or posedge rst_i)
 if (rst_i)
     global_history_real_q <= {NUM_BHT_ENTRIES_W{1'b0}};
-else if (branch_is_taken_i || branch_is_not_taken_i)
-    global_history_real_q <= {global_history_real_q[NUM_BHT_ENTRIES_W-2:0], branch_is_taken_i};
-
-//-----------------------------------------------------------------
-// Global history register (speculative)
-//-----------------------------------------------------------------
+else if (branch_resolved_w)
+    global_history_real_q <= global_history_real_next_w;
+
 reg [NUM_BHT_ENTRIES_W-1:0] global_history_q;
 
-always @ (posedge clk_i or posedge rst_i)
-if (rst_i)
-    global_history_q <= {NUM_BHT_ENTRIES_W{1'b0}};
-// Mispredict - revert to actual branch history to flush out speculative errors
-else if (branch_request_i)
-    global_history_q <= {global_history_real_q[NUM_BHT_ENTRIES_W-2:0], branch_is_taken_i};
-// Predicted branch
-else if (pred_taken_w || pred_ntaken_w)
-    global_history_q <= {global_history_q[NUM_BHT_ENTRIES_W-2:0], pred_taken_w};
-
-wire [NUM_BHT_ENTRIES_W-1:0] gshare_wr_entry_w = (branch_request_i ? global_history_real_q : global_history_q) ^ branch_source_i[2+NUM_BHT_ENTRIES_W-1:2];
-wire [NUM_BHT_ENTRIES_W-1:0] gshare_rd_entry_w = global_history_q ^ {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3],btb_upper_w};
-
-//-----------------------------------------------------------------
-// Branch prediction bits
-//-----------------------------------------------------------------
-reg [1:0]                    bht_sat_q[NUM_BHT_ENTRIES-1:0];
-
-wire [NUM_BHT_ENTRIES_W-1:0] bht_wr_entry_w = GSHARE_ENABLE ? gshare_wr_entry_w : branch_source_i[2+NUM_BHT_ENTRIES_W-1:2];
-wire [NUM_BHT_ENTRIES_W-1:0] bht_rd_entry_w = GSHARE_ENABLE ? gshare_rd_entry_w : {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3],btb_upper_w};
+//-----------------------------------------------------------------
+// Branch History Table (2-bit saturating counters)
+//-----------------------------------------------------------------
+reg [1:0] bht_sat_q[NUM_BHT_ENTRIES-1:0];
+
+wire [NUM_BHT_ENTRIES_W-1:0] gshare_wr_entry_w = global_history_real_q ^ branch_source_i[2+NUM_BHT_ENTRIES_W-1:2];
+wire [NUM_BHT_ENTRIES_W-1:0] bht_wr_entry_w    = GSHARE_ENABLE ? gshare_wr_entry_w : branch_source_i[2+NUM_BHT_ENTRIES_W-1:2];
 
 integer i4;
 always @ (posedge clk_i or posedge rst_i)
 if (rst_i)
 begin
     for (i4 = 0; i4 < NUM_BHT_ENTRIES; i4 = i4 + 1)
-    begin
         bht_sat_q[i4] <= 2'd3;
-    end
 end
 else if (branch_is_taken_i && bht_sat_q[bht_wr_entry_w] < 2'd3)
     bht_sat_q[bht_wr_entry_w] <= bht_sat_q[bht_wr_entry_w] + 2'd1;
 else if (branch_is_not_taken_i && bht_sat_q[bht_wr_entry_w] > 2'd0)
     bht_sat_q[bht_wr_entry_w] <= bht_sat_q[bht_wr_entry_w] - 2'd1;
 
-wire bht_predict_taken_w = BHT_ENABLE && (bht_sat_q[bht_rd_entry_w] >= 2'd2);
-
-//-----------------------------------------------------------------
-// Branch target buffer
-//-----------------------------------------------------------------
-reg [31:0]  btb_pc_q[NUM_BTB_ENTRIES-1:0];
-reg [31:0]  btb_target_q[NUM_BTB_ENTRIES-1:0];
-reg         btb_is_call_q[NUM_BTB_ENTRIES-1:0];
-reg         btb_is_ret_q[NUM_BTB_ENTRIES-1:0];
-reg         btb_is_jmp_q[NUM_BTB_ENTRIES-1:0];
-
-reg         btb_valid_r;
-reg         btb_upper_r;
-reg         btb_is_call_r;
-reg         btb_is_ret_r;
-reg [31:0]  btb_next_pc_r;
-reg         btb_is_jmp_r;
-
-reg [NUM_BTB_ENTRIES_W-1:0] btb_entry_r;
+//-----------------------------------------------------------------
+// Branch Target Buffer (with explicit per-entry valid bit)
+//-----------------------------------------------------------------
+reg [NUM_BTB_ENTRIES-1:0] btb_entry_valid_q;
+reg [31:0]                btb_pc_q[NUM_BTB_ENTRIES-1:0];
+reg [31:0]                btb_target_q[NUM_BTB_ENTRIES-1:0];
+reg                       btb_is_call_q[NUM_BTB_ENTRIES-1:0];
+reg                       btb_is_ret_q[NUM_BTB_ENTRIES-1:0];
+reg                       btb_is_jmp_q[NUM_BTB_ENTRIES-1:0];
+
+wire [31:0] slot0_pc_w = {pc_f_i[31:3], 3'b000};
+wire [31:0] slot1_pc_w = {pc_f_i[31:3], 3'b100};
+
+reg        s0_hit_r;
+reg        s0_call_r;
+reg        s0_ret_r;
+reg        s0_jmp_r;
+reg [31:0] s0_target_r;
+reg [NUM_BTB_ENTRIES_W-1:0] s0_idx_r;
+
+reg        s1_hit_r;
+reg        s1_call_r;
+reg        s1_ret_r;
+reg        s1_jmp_r;
+reg [31:0] s1_target_r;
+reg [NUM_BTB_ENTRIES_W-1:0] s1_idx_r;
+
 integer i0;
-
 always @ *
 begin
-    btb_valid_r   = 1'b0;
-    btb_upper_r   = 1'b0;
-    btb_is_call_r = 1'b0;
-    btb_is_ret_r  = 1'b0;
-    btb_is_jmp_r  = 1'b0;
-    btb_next_pc_r = {pc_f_i[31:3],3'b0} + 32'd8;
-    btb_entry_r   = {NUM_BTB_ENTRIES_W{1'b0}};
+    s0_hit_r    = 1'b0;
+    s0_call_r   = 1'b0;
+    s0_ret_r    = 1'b0;
+    s0_jmp_r    = 1'b0;
+    s0_target_r = slot0_pc_w + 32'd8;
+    s0_idx_r    = {NUM_BTB_ENTRIES_W{1'b0}};
+
+    s1_hit_r    = 1'b0;
+    s1_call_r   = 1'b0;
+    s1_ret_r    = 1'b0;
+    s1_jmp_r    = 1'b0;
+    s1_target_r = slot0_pc_w + 32'd8;
+    s1_idx_r    = {NUM_BTB_ENTRIES_W{1'b0}};
 
     for (i0 = 0; i0 < NUM_BTB_ENTRIES; i0 = i0 + 1)
     begin
-        if (btb_pc_q[i0] == pc_f_i)
+        if (~pc_f_i[2] && btb_entry_valid_q[i0] && (btb_pc_q[i0] == slot0_pc_w))
         begin
-            btb_valid_r   = 1'b1;
-            btb_upper_r   = pc_f_i[2];
-            btb_is_call_r = btb_is_call_q[i0];
-            btb_is_ret_r  = btb_is_ret_q[i0];
-            btb_is_jmp_r  = btb_is_jmp_q[i0];
-            btb_next_pc_r = btb_target_q[i0];
-/* verilator lint_off WIDTH */
-            btb_entry_r   = i0;
-/* verilator lint_on WIDTH */
+            s0_hit_r    = 1'b1;
+            s0_call_r   = btb_is_call_q[i0];
+            s0_ret_r    = btb_is_ret_q[i0];
+            s0_jmp_r    = btb_is_jmp_q[i0];
+            s0_target_r = btb_target_q[i0];
+            s0_idx_r    = i0[NUM_BTB_ENTRIES_W-1:0];
+        end
+        if (btb_entry_valid_q[i0] && (btb_pc_q[i0] == slot1_pc_w))
+        begin
+            s1_hit_r    = 1'b1;
+            s1_call_r   = btb_is_call_q[i0];
+            s1_ret_r    = btb_is_ret_q[i0];
+            s1_jmp_r    = btb_is_jmp_q[i0];
+            s1_target_r = btb_target_q[i0];
+            s1_idx_r    = i0[NUM_BTB_ENTRIES_W-1:0];
         end
     end
-
-    if (~btb_valid_r && ~pc_f_i[2])
-        for (i0 = 0; i0 < NUM_BTB_ENTRIES; i0 = i0 + 1)
-        begin
-            if (btb_pc_q[i0] == (pc_f_i | 32'd4))
-            begin
-                btb_valid_r   = 1'b1;
-                btb_upper_r   = 1'b1;
-                btb_is_call_r = btb_is_call_q[i0];
-                btb_is_ret_r  = btb_is_ret_q[i0];
-                btb_is_jmp_r  = btb_is_jmp_q[i0];
-                btb_next_pc_r = btb_target_q[i0];
-/* verilator lint_off WIDTH */
-                btb_entry_r   = i0;
-/* verilator lint_on WIDTH */
-            end
-        end
-end
-
+end
+
+// Slot 0 BHT & prediction evaluation (only active when pc_f_i[2] == 0)
+wire [NUM_BHT_ENTRIES_W-1:0] s0_bht_idx_w = GSHARE_ENABLE ?
+    (global_history_q ^ {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b0}) :
+    {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b0};
+wire s0_bht_taken_w  = BHT_ENABLE && (bht_sat_q[s0_bht_idx_w] >= 2'd2);
+wire s0_cond_br_w    = ~(s0_call_r | s0_ret_r | s0_jmp_r);
+wire s0_ret_taken_w  = s0_ret_r & (RAS_ENABLE ? ras_top_ok_w : 1'b1);
+wire s0_pred_taken_w = s0_hit_r & (s0_call_r | s0_jmp_r | s0_ret_taken_w | (s0_cond_br_w & s0_bht_taken_w));
+wire [31:0] s0_pred_pc_w = (s0_ret_r & RAS_ENABLE) ? ras_pc_pred_w : s0_target_r;
+
+// If Slot 0 hit in BTB as not-taken, GHR shifts 0 before evaluating Slot 1
+wire [NUM_BHT_ENTRIES_W-1:0] ghr_after_s0_w = s0_hit_r ?
+    {global_history_q[NUM_BHT_ENTRIES_W-2:0], s0_pred_taken_w} :
+    global_history_q;
+
+// Slot 1 BHT & prediction evaluation (active when pc_f_i[2] == 1 OR Slot 0 is not predicted taken)
+wire s1_eval_w = pc_f_i[2] | ~s0_pred_taken_w;
+wire [NUM_BHT_ENTRIES_W-1:0] s1_bht_idx_w = GSHARE_ENABLE ?
+    (ghr_after_s0_w ^ {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b1}) :
+    {pc_f_i[3+NUM_BHT_ENTRIES_W-2:3], 1'b1};
+wire s1_bht_taken_w  = BHT_ENABLE && (bht_sat_q[s1_bht_idx_w] >= 2'd2);
+wire s1_cond_br_w    = ~(s1_call_r | s1_ret_r | s1_jmp_r);
+wire s1_ret_taken_w  = s1_ret_r & (RAS_ENABLE ? ras_top_ok_w : 1'b1);
+wire s1_pred_taken_w = s1_eval_w & s1_hit_r & (s1_call_r | s1_jmp_r | s1_ret_taken_w | (s1_cond_br_w & s1_bht_taken_w));
+wire [31:0] s1_pred_pc_w = (s1_ret_r & RAS_ENABLE) ? ras_pc_pred_w : s1_target_r;
+
+wire [NUM_BHT_ENTRIES_W-1:0] ghr_after_parcel_w = (s1_eval_w & s1_hit_r) ?
+    {ghr_after_s0_w[NUM_BHT_ENTRIES_W-2:0], s1_pred_taken_w} :
+    ghr_after_s0_w;
+
+// Speculative RAS push / pop on accepted fetch parcel
+wire spec_call_w = RAS_ENABLE & ((s0_pred_taken_w & s0_call_r) | (s1_pred_taken_w & s1_call_r));
+wire spec_ret_w  = RAS_ENABLE & ((s0_pred_taken_w & s0_ret_r & ras_top_ok_w) | (s1_pred_taken_w & s1_ret_r & ras_top_ok_w));
+wire [31:0] spec_call_ret_pc_w = (s0_pred_taken_w & s0_call_r) ? (slot0_pc_w + 32'd4) : (slot1_pc_w + 32'd4);
+wire [NUM_RAS_ENTRIES_W-1:0] spec_push_idx_w = ras_index_q + {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};
+
+integer i3;
+always @ (posedge clk_i or posedge rst_i)
+if (rst_i)
+begin
+    for (i3 = 0; i3 < NUM_RAS_ENTRIES; i3 = i3 + 1)
+        ras_stack_q[i3] <= RAS_INVALID;
+    ras_index_q <= {NUM_RAS_ENTRIES_W{1'b0}};
+end
+else if (branch_request_i)
+begin
+    for (i3 = 0; i3 < NUM_RAS_ENTRIES; i3 = i3 + 1)
+    begin
+        if (real_call_push_w && (i3[NUM_RAS_ENTRIES_W-1:0] == ras_index_real_r))
+            ras_stack_q[i3] <= branch_source_i + 32'd4;
+        else
+            ras_stack_q[i3] <= ras_stack_real_q[i3];
+    end
+    ras_index_q <= ras_index_real_r;
+end
+else if (pc_accept_i && spec_call_w)
+begin
+    ras_stack_q[spec_push_idx_w] <= spec_call_ret_pc_w;
+    ras_index_q                  <= spec_push_idx_w;
+end
+else if (pc_accept_i && spec_ret_w)
+begin
+    ras_index_q                  <= ras_index_q - {{(NUM_RAS_ENTRIES_W-1){1'b0}}, 1'b1};
+end
+
+// Speculative GHR update
+always @ (posedge clk_i or posedge rst_i)
+if (rst_i)
+    global_history_q <= {NUM_BHT_ENTRIES_W{1'b0}};
+else if (branch_request_i)
+    global_history_q <= global_history_real_next_w;
+else if (pc_accept_i && (s0_hit_r || (s1_eval_w && s1_hit_r)))
+    global_history_q <= ghr_after_parcel_w;
+
+// BTB update / allocation on resolved branches
 reg [NUM_BTB_ENTRIES_W-1:0]  btb_wr_entry_r;
 wire [NUM_BTB_ENTRIES_W-1:0] btb_wr_alloc_w;
-
-reg btb_hit_r;
-reg btb_miss_r;
+reg                          btb_hit_r;
+reg                          btb_miss_r;
+
+wire btb_learn_w = branch_is_taken_i | (branch_request_i & branch_is_not_taken_i);
+
 integer i1;
 always @ *
 begin
@@ -291,20 +282,17 @@
     btb_hit_r      = 1'b0;
     btb_miss_r     = 1'b0;
 
-    // Misprediction - learn / update branch details
-    if (branch_request_i)
+    if (btb_learn_w)
     begin
         for (i1 = 0; i1 < NUM_BTB_ENTRIES; i1 = i1 + 1)
         begin
-            if (btb_pc_q[i1] == branch_source_i)
+            if (btb_entry_valid_q[i1] && (btb_pc_q[i1] == branch_source_i))
             begin
                 btb_hit_r      = 1'b1;
-    /* verilator lint_off WIDTH */
-                btb_wr_entry_r = i1;
-    /* verilator lint_on WIDTH */
+                btb_wr_entry_r = i1[NUM_BTB_ENTRIES_W-1:0];
             end
         end
-        btb_miss_r = ~btb_hit_r;
+        btb_miss_r = branch_is_taken_i & ~btb_hit_r;
     end
 end
 
@@ -312,83 +300,68 @@
 always @ (posedge clk_i or posedge rst_i)
 if (rst_i)
 begin
+    btb_entry_valid_q <= {NUM_BTB_ENTRIES{1'b0}};
     for (i2 = 0; i2 < NUM_BTB_ENTRIES; i2 = i2 + 1)
     begin
-        btb_pc_q[i2]     <= 32'b0;
-        btb_target_q[i2] <= 32'b0;
-        btb_is_call_q[i2]<= 1'b0;
-        btb_is_ret_q[i2] <= 1'b0;
-        btb_is_jmp_q[i2] <= 1'b0;
+        btb_pc_q[i2]      <= 32'b0;
+        btb_target_q[i2]  <= 32'b0;
+        btb_is_call_q[i2] <= 1'b0;
+        btb_is_ret_q[i2]  <= 1'b0;
+        btb_is_jmp_q[i2]  <= 1'b0;
     end
 end
-// Hit - update entry
+else if (invalidate_i)
+begin
+    btb_entry_valid_q <= {NUM_BTB_ENTRIES{1'b0}};
+end
 else if (btb_hit_r)
 begin
-    btb_pc_q[btb_wr_entry_r]     <= branch_source_i;
+    btb_pc_q[btb_wr_entry_r]      <= branch_source_i;
     if (branch_is_taken_i)
         btb_target_q[btb_wr_entry_r] <= branch_pc_i;
-    btb_is_call_q[btb_wr_entry_r]<= branch_is_call_i;
-    btb_is_ret_q[btb_wr_entry_r] <= branch_is_ret_i;
-    btb_is_jmp_q[btb_wr_entry_r] <= branch_is_jmp_i;
-end
-// Miss - allocate entry
+    btb_is_call_q[btb_wr_entry_r] <= branch_is_call_i;
+    btb_is_ret_q[btb_wr_entry_r]  <= branch_is_ret_i;
+    btb_is_jmp_q[btb_wr_entry_r]  <= branch_is_jmp_i;
+end
 else if (btb_miss_r)
 begin
-    btb_pc_q[btb_wr_alloc_w]     <= branch_source_i;
-    btb_target_q[btb_wr_alloc_w] <= branch_pc_i;
-    btb_is_call_q[btb_wr_alloc_w]<= branch_is_call_i;
-    btb_is_ret_q[btb_wr_alloc_w] <= branch_is_ret_i;
-    btb_is_jmp_q[btb_wr_alloc_w] <= branch_is_jmp_i;
-end
-
-//-----------------------------------------------------------------
-// Replacement Selection
-//-----------------------------------------------------------------
+    btb_entry_valid_q[btb_wr_alloc_w] <= 1'b1;
+    btb_pc_q[btb_wr_alloc_w]          <= branch_source_i;
+    btb_target_q[btb_wr_alloc_w]      <= branch_pc_i;
+    btb_is_call_q[btb_wr_alloc_w]     <= branch_is_call_i;
+    btb_is_ret_q[btb_wr_alloc_w]      <= branch_is_ret_i;
+    btb_is_jmp_q[btb_wr_alloc_w]      <= branch_is_jmp_i;
+end
+
+wire lfsr_hit_w = s0_pred_taken_w | s1_pred_taken_w;
+wire [NUM_BTB_ENTRIES_W-1:0] lfsr_idx_w = s0_pred_taken_w ? s0_idx_r : s1_idx_r;
+
 biriscv_npc_lfsr
 #(
-    .DEPTH(NUM_BTB_ENTRIES)
-   ,.ADDR_W(NUM_BTB_ENTRIES_W)
+     .DEPTH(NUM_BTB_ENTRIES)
+    ,.ADDR_W(NUM_BTB_ENTRIES_W)
 )
 u_lru
 (
      .clk_i(clk_i)
     ,.rst_i(rst_i)
-
-    ,.hit_i(btb_valid_r)
-    ,.hit_entry_i(btb_entry_r)
-
+    ,.hit_i(lfsr_hit_w)
+    ,.hit_entry_i(lfsr_idx_w)
     ,.alloc_i(btb_miss_r)
     ,.alloc_entry_o(btb_wr_alloc_w)
 );
 
-//-----------------------------------------------------------------
-// Outputs
-//-----------------------------------------------------------------
-assign btb_valid_w   = btb_valid_r;
-assign btb_upper_w   = btb_upper_r;
-assign btb_is_call_w = btb_is_call_r;
-assign btb_is_ret_w  = btb_is_ret_r;
-assign next_pc_f_o   = ras_ret_pred_w      ? ras_pc_pred_w : 
-                       (bht_predict_taken_w | btb_is_jmp_r) ? btb_next_pc_r :
-                       {pc_f_i[31:3],3'b0} + 32'd8;
-
-assign next_taken_f_o = (btb_valid_w & (ras_ret_pred_w | bht_predict_taken_w | btb_is_jmp_r)) ? 
-                        pc_f_i[2] ? {btb_upper_r, 1'b0} :
-                        {btb_upper_r, ~btb_upper_r} : 2'b0;
-
-assign pred_taken_w   = btb_valid_w & (ras_ret_pred_w | bht_predict_taken_w | btb_is_jmp_r) & pc_accept_i;
-assign pred_ntaken_w  = btb_valid_w & ~pred_taken_w & pc_accept_i;
-
-
-end
-//-----------------------------------------------------------------
-// No branch prediction
-//-----------------------------------------------------------------
+assign next_pc_f_o    = s0_pred_taken_w ? s0_pred_pc_w :
+                        (s1_pred_taken_w ? s1_pred_pc_w : (slot0_pc_w + 32'd8));
+assign next_taken_f_o = s0_pred_taken_w ? 2'b01 :
+                        (s1_pred_taken_w ? 2'b10 : 2'b00);
+
+end
 else
 begin: NO_BRANCH_PREDICTION
 
-assign next_pc_f_o    = {pc_f_i[31:3],3'b0} + 32'd8;
-assign next_taken_f_o = 2'b0;
+assign next_pc_f_o    = {pc_f_i[31:3], 3'b0} + 32'd8;
+assign next_taken_f_o = 2'b00;
 
 end
 endgenerate
@@ -397,33 +370,22 @@
 
 
 module biriscv_npc_lfsr
-//-----------------------------------------------------------------
-// Params
-//-----------------------------------------------------------------
 #(
      parameter DEPTH            = 32
     ,parameter ADDR_W           = 5
     ,parameter INITIAL_VALUE    = 16'h0001
     ,parameter TAP_VALUE        = 16'hB400
 )
-//-----------------------------------------------------------------
-// Ports
-//-----------------------------------------------------------------
 (
-    // Inputs
-     input           clk_i
-    ,input           rst_i
-    ,input           hit_i
+     input                clk_i
+    ,input                rst_i
+    ,input                hit_i
     ,input  [ADDR_W-1:0]  hit_entry_i
-    ,input           alloc_i
-
-    // Outputs
+    ,input                alloc_i
+
     ,output [ADDR_W-1:0]  alloc_entry_o
 );
 
-//-----------------------------------------------------------------
-// Scheme: LFSR
-//-----------------------------------------------------------------
 reg [15:0] lfsr_q;
 
 always @ (posedge clk_i or posedge rst_i)
@@ -439,8 +401,4 @@
 
 assign alloc_entry_o = lfsr_q[ADDR_W-1:0];
 
-
-
-
-
 endmodule

--- a/environment/public/code/biriscv_fetch.v (Buggy Starter)
+++ b/solution/gold/code/biriscv_fetch.v (Golden Reference)
@@ -8,33 +8,11 @@
 //
 //                     License: Apache 2.0
 //-----------------------------------------------------------------
-// Copyright 2020 Ultra-Embedded.com
-// 
-// Licensed under the Apache License, Version 2.0 (the "License");
-// you may not use this file except in compliance with the License.
-// You may obtain a copy of the License at
-// 
-//     http://www.apache.org/licenses/LICENSE-2.0
-// 
-// Unless required by applicable law or agreed to in writing, software
-// distributed under the License is distributed on an "AS IS" BASIS,
-// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-// See the License for the specific language governing permissions and
-// limitations under the License.
-//-----------------------------------------------------------------
-
 module biriscv_fetch
-//-----------------------------------------------------------------
-// Params
-//-----------------------------------------------------------------
 #(
      parameter SUPPORT_MMU      = 1
 )
-//-----------------------------------------------------------------
-// Ports
-//-----------------------------------------------------------------
 (
-    // Inputs
      input           clk_i
     ,input           rst_
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/biriscv_decode.v`](environment/public/code/biriscv_decode.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_decoder.v`](environment/public/code/biriscv_decoder.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_defs.v`](environment/public/code/biriscv_defs.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_exec.v`](environment/public/code/biriscv_exec.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_fetch.v`](environment/public/code/biriscv_fetch.v) **(Editable)**
- [`environment/public/code/biriscv_frontend.v`](environment/public/code/biriscv_frontend.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_issue.v`](environment/public/code/biriscv_issue.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_npc.v`](environment/public/code/biriscv_npc.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

