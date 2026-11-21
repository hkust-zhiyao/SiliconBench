# `case_3004`: CV32E40P Instruction Fetch Subsystem Hardware-Loop Redirects, Split-Parcel Bus-Error Attribution, and 1.25 ns Area/Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_3004` |
| **Source Silicon Repository** | `openhwfoundation/cv32e40p` (`repo_03`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `synthesis_qor` (Logic Synthesis, Resource Sharing, Retiming, Structuring & Area/Delay QoR) |
| **Multi-Domain Tags** | `parameters_widths`, `rtl_integration`, `synthesis_qor`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/cv32e40p_prefetch_controller.sv`](environment/public/code/rtl/cv32e40p_prefetch_controller.sv), [`code/rtl/cv32e40p_prefetch_buffer.sv`](environment/public/code/rtl/cv32e40p_prefetch_buffer.sv), [`code/rtl/cv32e40p_aligner.sv`](environment/public/code/rtl/cv32e40p_aligner.sv), [`code/rtl/cv32e40p_if_stage.sv`](environment/public/code/rtl/cv32e40p_if_stage.sv) (4 files, 1188 LOC) |
| **Public Subsystem Context** | 8 RTL files (2962 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CV32E40P Instruction Fetch Subsystem Hardware-Loop Redirects, Split-Parcel Bus-Error Attribution, and 1.25 ns Area/Timing Closure

In the CV32E40P instruction fetch subsystem (`code/rtl/cv32e40p_if_stage.sv`, `code/rtl/cv32e40p_aligner.sv`, `code/rtl/cv32e40p_prefetch_buffer.sv`, and `code/rtl/cv32e40p_prefetch_controller.sv` configured with `COREV_PULP = 1`, `PULP_OBI = 0`), hardware-loop redirects under downstream ID-stage stalls, compressed/misaligned loop boundaries, and instruction OBI bus-error handling fail subsystem verification and 800 MHz (`1.25 ns`) physical synthesis closure:

1. **Hardware-Loop Redirects and Speculative Response Flushing (`cv32e40p_prefetch_controller.sv`):**
   - When `hwlp_jump_i` asserts while the loop-end instruction word is already buffered at the head of the prefetch FIFO (`!fifo_empty_i`) or arrives from OBI under downstream backpressure (`!fetch_ready_i`), younger speculative OBI responses in flight after the loop-end word must be discarded without suppressing `fetch_valid_o` for a valid instruction word already held at the FIFO head, and without pushing a same-cycle younger wrong-path OBI response into a non-empty FIFO. `fifo_pop_o` must never assert on a cycle where `branch_i` is high.
   - If a hardware-loop redirect occurs when the FIFO is empty and the loop-end response has not yet returned from OBI, and a subsequent hardware-loop redirect or branch arrives before that delayed flush completes, any pending delayed flush state from the earlier redirect must be cancelled so post-redirect responses are not erroneously dropped.
   - If `hwlp_jump_i` asserts while a previous ungranted redirect is waiting for `trans_ready_i` (`!branch_i`), `trans_addr_o` must immediately switch to `{hwlp_target_i[31:2], 2'b00}`.
   - Outstanding OBI responses scheduled to be discarded will never occupy FIFO entries and must not block new instruction fetch requests (`trans_valid_o`) against the FIFO depth limit (`DEPTH`).

2. **Hardware-Loop Target PC Updates Across Compressed and Misaligned Parcels (`cv32e40p_aligner.sv`):**
   - A hardware-loop end instruction (`hwlp_update_pc_i`, asserted either on the instruction's retirement cycle or held across an upstream/downstream stall) may be a 32-bit or 16-bit compressed instruction retiring from any word-aligned, halfword-spanning, buffered upper-halfword, or halfword-branch-target alignment state.
   - When the loop-end instruction retires, `pc_o` must advance to the hardware-loop target address (`hwlp_addr_i`), and the aligner must fetch from the lower or upper halfword of the target word according to bit 1 of the target address (preventing any residual upper halfword from the loop-end word from being executed as the loop body start).

3. **End-to-End Instruction OBI Bus-Error Attribution and Post-Fault Speculative Freeze:**
   - Propagate OBI response errors (`instr_err_i` / `resp_err_o`) through `cv32e40p_prefetch_buffer` and `cv32e40p_fifo` alongside instruction data (`fetch_err_o`).
   - When a non-flushed OBI response returns with an error (`resp_err_i = 1'b1`) and no `branch_i` or `hwlp_jump_i` is active on that cycle, `cv32e40p_prefetch_controller` must halt new speculative instruction requests (`trans_valid_o = 1'b0`) until cleared by reset, `branch_i`, or `hwlp_jump_i`.
   - `cv32e40p_aligner` must attribute a bus error to the exact instruction that consumes the faulted 32-bit fetch word (`instr_err_o = 1'b1` with `instr_valid_o = 1'b1`):
     - If a complete 16-bit compressed instruction is already held in the aligner's upper-halfword buffer while the newly fetched next word carries an error, that buffered 16-bit instruction must retire normally (`instr_err_o = 1'b0`), and the error must be attributed to the subsequent instruction that consumes the faulted word.
     - Conversely, if a 32-bit instruction spans into a faulted new word, or an instruction starts in a faulted word, it must present `instr_valid_o = 1'b1` and `instr_err_o = 1'b1` without incrementing `pc_o`, and once accepted (`if_valid_i = 1'b1`), deassert `instr_valid_o`, `instr_err_o`, and `aligner_ready_o` until a `branch_i` redirect occurs.
   - In `cv32e40p_if_stage`, latch the aligner's error onto `is_fetch_failed_o` when transferring to ID (`if_valid && instr_valid`), force `illegal_c_insn_id_o` low whenever `is_fetch_failed_o` is set so bus faults take priority over illegal-instruction decoding, and clear both `instr_valid_id_o` and `is_fetch_failed_o` when `clear_instr_valid_i` asserts without a new transfer.

4. **Synthesis, Area, and Timing Closure (`BUILD.md`):**
   - Synthesize latch-free under `yosys -m slang` (`COREV_PULP = 1`, `PULP_OBI = 0`).
   - Under the Nangate45 synthesis and OpenROAD STA flow in `BUILD.md` (`1.25 ns` clock on `clk`, `0.15 ns` I/O delays, `5.0 fF` load), `cv32e40p_if_stage` must achieve mapped cell area **`<= 3,748.0 um^2`**, worst setup slack (`WNS`) **`>= 0.00 ns`**, and worst hold slack (`WHS`) **`>= 0.00 ns`**.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/rtl/cv32e40p_prefetch_controller.sv`
- `code/rtl/cv32e40p_prefetch_buffer.sv`
- `code/rtl/cv32e40p_aligner.sv`
- `code/rtl/cv32e40p_if_stage.sv`

All other files in `code/` (`code/rtl/include/cv32e40p_pkg.sv`, `code/rtl/cv32e40p_fifo.sv`, `code/rtl/cv32e40p_obi_interface.sv`, `code/rtl/cv32e40p_compressed_decoder.sv`, `code/LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only and must remain unmodified.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `cv32e40p_if_stage` (`COREV_PULP = 1`, `PULP_OBI = 0`) with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  -Icode/rtl/include --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/rtl/include/cv32e40p_pkg.sv \
  code/rtl/cv32e40p_fifo.sv \
  code/rtl/cv32e40p_obi_interface.sv \
  code/rtl/cv32e40p_prefetch_controller.sv \
  code/rtl/cv32e40p_prefetch_buffer.sv \
  code/rtl/cv32e40p_aligner.sv \
  code/rtl/cv32e40p_compressed_decoder.sv \
  code/rtl/cv32e40p_if_stage.sv \
  /tmp/<your_tb>.sv
/tmp/obj_dir/V<your_tb>
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `cv32e40p_if_stage` (`COREV_PULP = 1`, `PULP_OBI = 0`):

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top cv32e40p_if_stage -G COREV_PULP=1 -G PULP_OBI=0 -Icode/rtl/include \
    code/rtl/include/cv32e40p_pkg.sv \
    code/rtl/cv32e40p_fifo.sv \
    code/rtl/cv32e40p_obi_interface.sv \
    code/rtl/cv32e40p_prefetch_controller.sv \
    code/rtl/cv32e40p_prefetch_buffer.sv \
    code/rtl/cv32e40p_aligner.sv \
    code/rtl/cv32e40p_compressed_decoder.sv \
    code/rtl/cv32e40p_if_stage.sv;
  hierarchy -check -top cv32e40p_if_stage;
  proc; opt_clean;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top cv32e40p_if_stage;
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

Target mapped cell area (`Chip area for module '\cv32e40p_if_stage'`): **`<= 3748.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `1.25 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_n`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design cv32e40p_if_stage
create_clock -name clk -period 1.25 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_n]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```

Target worst setup slack (`WNS`) and worst hold slack (`WHS`): **`>= 0.00 ns`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/cv32e40p_prefetch_controller.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/cv32e40p_prefetch_controller.sv (Golden Reference)
@@ -1,348 +1,211 @@
 // Copyright 2020 Silicon Labs, Inc.
-//
-// This file, and derivatives thereof are licensed under the
-// Solderpad License, Version 2.0 (the "License").
-//
-// Use of this file means you agree to the terms and conditions
-// of the license and are in full compliance with the License.
-//
-// You may obtain a copy of the License at:
-//
-//     https://solderpad.org/licenses/SHL-2.0/
-//
-// Unless required by applicable law or agreed to in writing, software
-// and hardware implementations thereof distributed under the License
-// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
-// OF ANY KIND, EITHER EXPRESSED OR IMPLIED.
-//
-// See the License for the specific language governing permissions and
-// limitations under the License.
-
-////////////////////////////////////////////////////////////////////////////////
-// Engineer:       Arjan Bink - arjan.bink@silabs.com                         //
-//                                                                            //
-// Design Name:    Prefetcher Controller                                      //
-// Project Name:   CV32E40P                                                   //
-// Language:       SystemVerilog                                              //
-//                                                                            //
-// Description:    Prefetch Controller which receives control flow            //
-//                 information (req_i, branch_*) from the Fetch stage         //
-//                 and based on that performs transactions requests to the    //
-//                 bus interface adapter instructions. Prefetching based on   //
-//                 incrementing addressed is performed when no new control    //
-//                 flow change is requested. New transaction requests are     //
-//                 only performed if it can be guaranteed that the fetch FIFO //
-//                 will not overflow (resulting in a maximum of DEPTH         //
-//                 outstanding transactions.                                  //
-//                                                                            //
-////////////////////////////////////////////////////////////////////////////////
+// Solderpad Hardware License, Version 2.0
 
 module cv32e40p_prefetch_controller #(
-    parameter PULP_OBI = 0,  // Legacy PULP OBI behavior
-    parameter COREV_PULP = 1,  // PULP ISA Extension (including PULP specific CSRs and hardware loop, excluding cv.elw)
-    parameter DEPTH = 4,  // Prefetch FIFO Depth
-    parameter FIFO_ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1  // Do not override this parameter
+    parameter PULP_OBI = 0,
+    parameter COREV_PULP = 1,
+    parameter DEPTH = 4,
+    parameter FIFO_ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1
 ) (
     input logic clk,
     input logic rst_n,
 
     // Fetch stage interface
-    input  logic        req_i,  // Fetch stage requests instructions
-    input  logic        branch_i,  // Taken branch
-    input  logic [31:0] branch_addr_i,  // Taken branch address (only valid when branch_i = 1)
-    output logic        busy_o,  // Prefetcher busy
+    input  logic        req_i,
+    input  logic        branch_i,
+    input  logic [31:0] branch_addr_i,
+    output logic        busy_o,
 
     // HW loop signals
     input logic        hwlp_jump_i,
     input logic [31:0] hwlp_target_i,
 
     // Transaction request interface
-    output logic trans_valid_o,  // Transaction request valid (to bus interface adapter)
-    input  logic                     trans_ready_i,           // Transaction request ready (transaction gets accepted when trans_valid_o and trans_ready_i are both 1)
-    output logic [31:0]              trans_addr_o,            // Transaction address (only valid when trans_valid_o = 1). No stability requirements.
+    output logic        trans_valid_o,
+    input  logic        trans_ready_i,
+    output logic [31:0] trans_addr_o,
 
     // Transaction response interface
-    input logic resp_valid_i,  // Note: Consumer is assumed to be 'ready' whenever resp_valid_i = 1
+    input logic resp_valid_i,
+    input logic resp_err_i,
 
     // Fetch interface is ready/valid
     input  logic fetch_ready_i,
     output logic fetch_valid_o,
 
     // FIFO interface
-    output logic fifo_push_o,  // PUSH an instruction into the FIFO
-    output logic fifo_pop_o,  // POP an instruction from the FIFO
-    output logic fifo_flush_o,  // Flush the FIFO
-    output logic                     fifo_flush_but_first_o,  // Flush the FIFO, but keep the first instruction if present
-    input logic [FIFO_ADDR_DEPTH:0] fifo_cnt_i,  // Number of valid items/words in the prefetch FIFO
-    input logic fifo_empty_i  // FIFO is empty
+    output logic                       fifo_push_o,
+    output logic                       fifo_pop_o,
+    output logic                       fifo_flush_o,
+    output logic                       fifo_flush_but_first_o,
+    input  logic [FIFO_ADDR_DEPTH:0]   fifo_cnt_i,
+    input  logic                       fifo_empty_i
 );
 
   import cv32e40p_pkg::*;
 
   prefetch_state_e state_q, next_state;
 
-  logic [FIFO_ADDR_DEPTH:0] cnt_q;  // Transaction counter
-  logic [FIFO_ADDR_DEPTH:0] next_cnt;  // Next value for cnt_q
-  logic                          count_up;                        // Increment outstanding transaction count by 1 (can happen at same time as count_down)
-  logic                          count_down;                      // Decrement outstanding transaction count by 1 (can happen at same time as count_up)
-
-  logic  [FIFO_ADDR_DEPTH:0]     flush_cnt_q;                     // Response flush counter (to flush speculative responses after branch)
-  logic [FIFO_ADDR_DEPTH:0] next_flush_cnt;  // Next value for flush_cnt_q
-
-  // Transaction address
+  logic [FIFO_ADDR_DEPTH:0] cnt_q;
+  logic [FIFO_ADDR_DEPTH:0] next_cnt;
+  logic                     count_up;
+  logic                     count_down;
+
+  logic [FIFO_ADDR_DEPTH:0] flush_cnt_q;
+  logic [FIFO_ADDR_DEPTH:0] next_flush_cnt;
+
   logic [31:0] trans_addr_q, trans_addr_incr;
-
-  // Word-aligned branch target address
-  logic [31:0] aligned_branch_addr;  // Word aligned branch target address
-
-  // FIFO auxiliary signal
-  logic fifo_valid;  // FIFO output valid (if !fifo_empty)
-  logic [FIFO_ADDR_DEPTH:0]      fifo_cnt_masked;                 // FIFO_cnt signal, masked when we are branching to allow a new memory request in that cycle
-
-  // HW loop support signals
-  logic hwlp_wait_resp_flush;  // Trigger for the delayed flush
-  logic hwlp_flush_after_resp;  // Wait for HWLP_END and then flush the wrong granted requests
-  logic [FIFO_ADDR_DEPTH:0]      hwlp_flush_cnt_delayed_q;        // The number of outstanding requests to flush when HWLP_END is returned
-  logic hwlp_flush_resp_delayed;  // Actual delayed flush
-  logic hwlp_flush_resp;  // Response flush counter when hwlp occurs
-
-  //////////////////////////////////////////////////////////////////////////////
-  // Prefetch buffer status
-  //////////////////////////////////////////////////////////////////////////////
-
-  // Busy if there are ongoing (or potentially outstanding) transfers
-  assign busy_o = (cnt_q != 3'b000) || trans_valid_o;
-
-  //////////////////////////////////////////////////////////////////////////////
-  // IF/ID interface
-  //////////////////////////////////////////////////////////////////////////////
-
-  // Fectch valid control. Fetch never valid if jumping or flushing responses.
-  // Fetch valid if there are instructions in FIFO or there is an incoming
-  // instruction from memory.
-  assign fetch_valid_o = (fifo_valid || resp_valid_i) && !(branch_i || (flush_cnt_q > 0));
-
-  //////////////////////////////////////////////////////////////////////////////
-  // Transaction request generation
-  //
-  // Assumes that corresponding response is at least 1 cycle after request
-  //
-  // - Only request transaction when fetch stage requires fetch (req_i), and
-  // - make sure that FIFO (cv32e40p_fetch_fifo) never overflows (fifo_cnt_i + cnt_q < DEPTH)
-  //////////////////////////////////////////////////////////////////////////////
-
-  // Prefetcher will only perform word fetches
+  logic [31:0] aligned_branch_addr;
+
+  logic                     fifo_valid;
+  logic [FIFO_ADDR_DEPTH:0] fifo_cnt_masked;
+  logic [FIFO_ADDR_DEPTH:0] active_cnt;
+
+  logic                     hwlp_wait_resp_flush;
+  logic                     hwlp_flush_after_resp;
+  logic [FIFO_ADDR_DEPTH:0] hwlp_flush_cnt_delayed_q;
+  logic                     hwlp_flush_resp_delayed;
+  logic                     hwlp_flush_resp;
+
+  logic                     err_freeze_q, err_freeze_n;
+  logic                     resp_flushed;
+  logic                     valid_err_resp;
+
+  assign busy_o = (cnt_q != '0) || trans_valid_o;
+
+  assign fifo_valid = !fifo_empty_i;
+  assign resp_flushed = branch_i || (flush_cnt_q > 0);
+  assign valid_err_resp = resp_valid_i && resp_err_i && !resp_flushed && !(hwlp_jump_i && !fifo_empty_i);
+
+  // Preserve valid FIFO head across flush_cnt_q > 0; only suppress the incoming OBI bypass path
+  assign fetch_valid_o = !branch_i && (fifo_valid || (resp_valid_i && !resp_flushed));
+
   assign aligned_branch_addr = {branch_addr_i[31:2], 2'b00};
-
-  // Increment address (always word fetch)
-  assign trans_addr_incr = {trans_addr_q[31:2], 2'b00} + 32'd4;
-
-  // Transaction request generation
+  assign trans_addr_incr     = {trans_addr_q[31:2], 2'b00} + 32'd4;
+
+  assign fifo_cnt_masked = (branch_i || hwlp_jump_i) ? '0 : fifo_cnt_i;
+  assign active_cnt      = (cnt_q > flush_cnt_q) ? (cnt_q - flush_cnt_q) : '0;
+
+  logic allow_new_req;
+  assign allow_new_req = req_i && (!err_freeze_q || branch_i || hwlp_jump_i) &&
+                         ((fifo_cnt_masked + active_cnt) < DEPTH[FIFO_ADDR_DEPTH:0]);
+
   generate
     if (PULP_OBI == 0) begin : gen_no_pulp_obi
-      // OBI compatible (avoids combinatorial path from instr_rvalid_i to instr_req_o).
-      // Multiple trans_* transactions can be issued (and accepted) before a response
-      // (resp_*) is received.
-      assign trans_valid_o = req_i && (fifo_cnt_masked + cnt_q < DEPTH);
+      assign trans_valid_o = allow_new_req;
     end else begin : gen_pulp_obi
-      // Legacy PULP OBI behavior, i.e. only issue subsequent transaction if preceding transfer
-      // is about to finish (re-introducing timing critical path from instr_rvalid_i to instr_req_o)
-      assign trans_valid_o = (cnt_q == 3'b000) ? req_i && (fifo_cnt_masked + cnt_q < DEPTH) :
-                                                 req_i && (fifo_cnt_masked + cnt_q < DEPTH) && resp_valid_i;
+      assign trans_valid_o = (cnt_q == '0) ? allow_new_req : (allow_new_req && resp_valid_i);
     end
   endgenerate
 
-  // Optimization:
-  // fifo_cnt is used to understand if we can perform new memory requests
-  // When branching, we flush both the FIFO and the outstanding requests. Therefore,
-  // there is surely space for a new request.
-  // Masking fifo_cnt in this case allows for making a new request when the FIFO
-  // is not empty and we are jumping, and (fifo_cnt_i + cnt_q == DEPTH)
-  assign fifo_cnt_masked = (branch_i || hwlp_jump_i) ? '0 : fifo_cnt_i;
-
-  // FSM (state_q, next_state) to control OBI A channel signals.
   always_comb begin
     next_state   = state_q;
     trans_addr_o = trans_addr_q;
 
     case (state_q)
-      // Default state (pass on branch target address or transaction with incremented address)
       IDLE: begin
-        begin
-          if (branch_i) begin
-            // Jumps must have the highest priority (e.g. an interrupt must
-            // have higher priority than a HW-loop branch)
-            trans_addr_o = aligned_branch_addr;
-          end else if (hwlp_jump_i) begin
-            trans_addr_o = hwlp_target_i;
-          end else begin
-            trans_addr_o = trans_addr_incr;
-          end
+        if (branch_i) begin
+          trans_addr_o = aligned_branch_addr;
+        end else if (hwlp_jump_i) begin
+          trans_addr_o = {hwlp_target_i[31:2], 2'b00};
+        end else begin
+          trans_addr_o = trans_addr_incr;
         end
         if ((branch_i || hwlp_jump_i) && !(trans_valid_o && trans_ready_i)) begin
-          // Taken branch, but transaction not yet accepted by bus interface adapter.
           next_state = BRANCH_WAIT;
         end
-      end  // case: IDLE
+      end
 
       BRANCH_WAIT: begin
-        // Replay previous branch target address (trans_addr_q) or new branch address (this can
-        // occur if for example an interrupt is taken right after a taken jump which did not
-        // yet have its target address accepted by the bus interface adapter.
-        trans_addr_o = branch_i ? aligned_branch_addr : trans_addr_q;
+        if (branch_i) begin
+          trans_addr_o = aligned_branch_addr;
+        end else if (hwlp_jump_i) begin
+          trans_addr_o = {hwlp_target_i[31:2], 2'b00};
+        end else begin
+          trans_addr_o = trans_addr_q;
+        end
         if (trans_valid_o && trans_ready_i) begin
-          // Transaction with branch target address has been accepted. Start regular prefetch again.
           next_state = IDLE;
         end
-      end  // case: BRANCH_WAIT
+      end
     endcase
   end
 
-  //////////////////////////////////////////////////////////////////////////////
-  // FIFO management
-  //////////////////////////////////////////////////////////////////////////////
-
-  // Pass on response transfer directly to FIFO (which should be ready, otherwise
-  // the corresponding transfer would not have been requested via trans_valid_o).
-  // Upon a branch (branch_i) all incoming responses (resp_valid_i) are flushed
-  // until the flush count is 0 again. (The flush count is initialized with the
-  // number of outstanding transactions at the time of the branch).
-  assign fifo_valid = !fifo_empty_i;
-  assign fifo_push_o = resp_valid_i && (fifo_valid || !fetch_ready_i) && !(branch_i || (flush_cnt_q > 0));
-  assign fifo_pop_o = fifo_valid && fetch_ready_i;
-
-  //////////////////////////////////////////////////////////////////////////////
-  // Counter (cnt_q, next_cnt) to count number of outstanding OBI transactions
-  // (maximum = DEPTH)
-  //
-  // Counter overflow is prevented by limiting the number of outstanding transactions
-  // to DEPTH. Counter underflow is prevented by the assumption that resp_valid_i = 1
-  // will only occur in response to accepted transfer request (as per the OBI protocol).
-  //////////////////////////////////////////////////////////////////////////////
-
-  assign count_up = trans_valid_o && trans_ready_i;  // Increment upon accepted transfer request
-  assign count_down = resp_valid_i;  // Decrement upon accepted transfer response
-
-  always_comb begin
-    case ({
-      count_up, count_down
-    })
-      2'b00: begin
-        next_cnt = cnt_q;
-      end
-      2'b01: begin
-        next_cnt = cnt_q - 1'b1;
-      end
-      2'b10: begin
-        next_cnt = cnt_q + 1'b1;
-      end
-      2'b11: begin
-        next_cnt = cnt_q;
-      end
+  assign fifo_push_o = resp_valid_i && (fifo_valid || !fetch_ready_i) && !resp_flushed && !(hwlp_jump_i && !fifo_empty_i);
+  assign fifo_pop_o  = fifo_valid && fetch_ready_i && !branch_i;
+
+  assign count_up   = trans_valid_o && trans_ready_i;
+  assign count_down = resp_valid_i;
+
+  always_comb begin
+    case ({count_up, count_down})
+      2'b00: next_cnt = cnt_q;
+      2'b01: next_cnt = cnt_q - 1'b1;
+      2'b10: next_cnt = cnt_q + 1'b1;
+      2'b11: next_cnt = cnt_q;
     endcase
   end
 
   generate
     if (COREV_PULP) begin : gen_hwlp
-
-      // Flush the FIFO if it is not empty and we are hwlp branching.
-      // If HWLP_END is not going to ID, save it from the flush.
-      // Don't flush the FIFO if it is empty (maybe we must accept
-      // HWLP_end from the memory in this cycle)
       assign fifo_flush_o           = branch_i || (hwlp_jump_i && !fifo_empty_i && fifo_pop_o);
       assign fifo_flush_but_first_o = (hwlp_jump_i && !fifo_empty_i && !fifo_pop_o);
 
-      //////////////////////////////////////////////////////////////////////////////
-      // HWLP main resp flush controller
-      //////////////////////////////////////////////////////////////////////////////
-
-      // If HWLP_END-4 is in ID and HWLP_END is being/was returned by the memory
-      // we can flush all the eventual outstanding requests up to now
       assign hwlp_flush_resp        = hwlp_jump_i && !(fifo_empty_i && !resp_valid_i);
-
-      //////////////////////////////////////////////////////////////////////////////
-      // HWLP delayed flush controller
-      //////////////////////////////////////////////////////////////////////////////
-
-      // If HWLP_END-4 is in ID and HWLP_END has not been returned yet,
-      // save the present number of outstanding requests (subtract the HWLP_END one).
-      // Wait for HWLP_END then flush the saved number of (wrong) outstanding requests
       assign hwlp_wait_resp_flush   = hwlp_jump_i && (fifo_empty_i && !resp_valid_i);
 
       always_ff @(posedge clk or negedge rst_n) begin
         if (~rst_n) begin
           hwlp_flush_after_resp    <= 1'b0;
-          hwlp_flush_cnt_delayed_q <= 2'b00;
+          hwlp_flush_cnt_delayed_q <= '0;
         end else begin
           if (branch_i) begin
-            // Reset the flush request if an interrupt is taken
             hwlp_flush_after_resp    <= 1'b0;
-            hwlp_flush_cnt_delayed_q <= 2'b00;
-          end else begin
-            if (hwlp_wait_resp_flush) begin
-              hwlp_flush_after_resp    <= 1'b1;
-              // cnt_q > 0 checked by an assertion
-              hwlp_flush_cnt_delayed_q <= cnt_q - 1'b1;
-            end else begin
-              // Reset the delayed flush request when it's completed
-              if (hwlp_flush_resp_delayed) begin
-                hwlp_flush_after_resp    <= 1'b0;
-                hwlp_flush_cnt_delayed_q <= 2'b00;
-              end
-            end
+            hwlp_flush_cnt_delayed_q <= '0;
+          end else if (hwlp_wait_resp_flush) begin
+            hwlp_flush_after_resp    <= 1'b1;
+            hwlp_flush_cnt_delayed_q <= (cnt_q > 0) ? (cnt_q - 1'b1) : '0;
+          end else if (hwlp_flush_resp || hwlp_flush_resp_delayed) begin
+            hwlp_flush_after_resp    <= 1'b0;
+            hwlp_flush_cnt_delayed_q <= '0;
           end
         end
       end
 
-      // This signal is masked by branch_i in the flush counter process,
-      // because if an interrupt occurs during a delayed flush, the interrupt
-      // is served first so the flush should be normal (caused by branch_i)
       assign hwlp_flush_resp_delayed = hwlp_flush_after_resp && resp_valid_i;
-
     end else begin : gen_no_hwlp
-
-      // Flush the FIFO if it is not empty
       assign fifo_flush_o             = branch_i;
       assign fifo_flush_but_first_o   = 1'b0;
       assign hwlp_flush_resp          = 1'b0;
       assign hwlp_wait_resp_flush     = 1'b0;
-
       assign hwlp_flush_after_resp    = 1'b0;
-      assign hwlp_flush_cnt_delayed_q = 2'b00;
+      assign hwlp_flush_cnt_delayed_q = '0;
       assign hwlp_flush_resp_delayed  = 1'b0;
-
-
     end
   endgenerate
 
-  //////////////////////////////////////////////////////////////////////////////
-  // Counter (flush_cnt_q, next_flush_cnt) to count reseponses to be flushed.
-  //////////////////////////////////////////////////////////////////////////////
-
   always_comb begin
     next_flush_cnt = flush_cnt_q;
-
-    // Number of outstanding transfers at time of branch equals the number of
-    // responses that will need to be flushed (responses already in the FIFO will
-    // be flushed there)
     if (branch_i || hwlp_flush_resp) begin
       next_flush_cnt = cnt_q;
       if (resp_valid_i && (cnt_q > 0)) begin
         next_flush_cnt = cnt_q - 1'b1;
       end
     end else if (hwlp_flush_resp_delayed) begin
-      // Delayed flush has a lower priority than the normal flush,
-      // because HW loops branches have lower priority than
-      // taken interrupts
       next_flush_cnt = hwlp_flush_cnt_delayed_q;
     end else if (resp_valid_i && (flush_cnt_q > 0)) begin
       next_flush_cnt = flush_cnt_q - 1'b1;
     end
   end
 
-  //////////////////////////////////////////////////////////////////////////////
-  // Registers
-  //////////////////////////////////////////////////////////////////////////////
+  always_comb begin
+    err_freeze_n = err_freeze_q;
+    if (branch_i || hwlp_jump_i) begin
+      err_freeze_n = 1'b0;
+    end else if (valid_err_resp) begin
+      err_freeze_n = 1'b1;
+    end
+  end
 
   always_ff @(posedge clk, negedge rst_n) begin
     if (rst_n == 1'b0) begin
@@ -350,14 +213,16 @@
       cnt_q        <= '0;
       flush_cnt_q  <= '0;
       trans_addr_q <= '0;
+      err_freeze_q <= 1'b0;
     end else begin
-      state_q     <= next_state;
-      cnt_q       <= next_cnt;
-      flush_cnt_q <= next_flush_cnt;
+      state_q      <= next_state;
+      cnt_q        <= next_cnt;
+      flush_cnt_q  <= next_flush_cnt;
+      err_freeze_q <= err_freeze_n;
       if (branch_i || hwlp_jump_i || (trans_valid_o && trans_ready_i)) begin
         trans_addr_q <= trans_addr_o;
       end
     end
   end
 
-endmodule  // cv32e40p_prefetch_controller
+endmodule

--- a/environment/public/code/rtl/cv32e40p_prefetch_buffer.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/cv32e40p_prefetch_buffer.sv (Golden Reference)
@@ -1,32 +1,9 @@
 // Copyright 2018 ETH Zurich and University of Bologna.
-// Copyright and related rights are licensed under the Solderpad Hardware
-// License, Version 0.51 (the "License"); you may not use this file except in
-// compliance with the License.  You may obtain a copy of the License at
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
-// or agreed to in writing, software, hardware and materials distributed under
-// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
-// CONDITIONS OF ANY KIND, either express or implied. See the License for the
-// specific language governing permissions and limitations under the License.
-
-////////////////////////////////////////////////////////////////////////////////
-// Engineer:       Andreas Traber - atraber@iis.ee.ethz.ch                    //
-//                                                                            //
-// Design Name:    Prefetcher Buffer for 32 bit memory interface              //
-// Project Name:   RI5CY                                                      //
-// Language:       SystemVerilog                                              //
-//                                                                            //
-// Description:    Prefetch Buffer that caches instructions. This cuts overly //
-//                 long critical paths to the instruction cache               //
-//                                                                            //
-////////////////////////////////////////////////////////////////////////////////
-
-// input port: send address one cycle before the data
-// clear_i clears the FIFO for the following cycle. in_addr_i can be sent in
-// this cycle already
+// Solderpad Hardware License, Version 0.51
 
 module cv32e40p_prefetch_buffer #(
-    parameter PULP_OBI = 0,  // Legacy PULP OBI behavior
-    parameter COREV_PULP = 1  // PULP ISA Extension (including PULP specific CSRs and hardware loop, excluding p.elw)
+    parameter PULP_OBI = 0,
+    parameter COREV_PULP = 1
 ) (
     input logic clk,
     input logic rst_n,
@@ -41,6 +18,7 @@
     input  logic        fetch_ready_i,
     output logic        fetch_valid_o,
     output logic [31:0] fetch_rdata_o,
+    output logic        fetch_err_o,
 
     // goes to instruction memory / instruction cache
     output logic        instr_req_o,
@@ -48,40 +26,33 @@
     output logic [31:0] instr_addr_o,
     input  logic [31:0] instr_rdata_i,
     input  logic        instr_rvalid_i,
-    input  logic        instr_err_i,  // Not used yet (future addition)
-    input  logic        instr_err_pmp_i,  // Not used yet (future addition)
+    input  logic        instr_err_i,
+    input  logic        instr_err_pmp_i,
 
     // Prefetch Buffer Status
     output logic busy_o
 );
-  // FIFO_DEPTH controls also the number of outstanding memory requests
-  // FIFO_DEPTH must be greater than 1 to respect assertion in prefetch controller
-  // FIFO_DEPTH must be a power of 2 (because of the FIFO implementation)
-  localparam FIFO_DEPTH                     = 2; //must be greate
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/rtl/cv32e40p_aligner.sv`](environment/public/code/rtl/cv32e40p_aligner.sv) **(Editable)**
- [`environment/public/code/rtl/cv32e40p_compressed_decoder.sv`](environment/public/code/rtl/cv32e40p_compressed_decoder.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/cv32e40p_fifo.sv`](environment/public/code/rtl/cv32e40p_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/cv32e40p_if_stage.sv`](environment/public/code/rtl/cv32e40p_if_stage.sv) **(Editable)**
- [`environment/public/code/rtl/cv32e40p_obi_interface.sv`](environment/public/code/rtl/cv32e40p_obi_interface.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/cv32e40p_prefetch_buffer.sv`](environment/public/code/rtl/cv32e40p_prefetch_buffer.sv) **(Editable)**
- [`environment/public/code/rtl/cv32e40p_prefetch_controller.sv`](environment/public/code/rtl/cv32e40p_prefetch_controller.sv) **(Editable)**
- [`environment/public/code/rtl/include/cv32e40p_pkg.sv`](environment/public/code/rtl/include/cv32e40p_pkg.sv) *(Read-Only Context)*
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

