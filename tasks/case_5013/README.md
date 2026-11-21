# `case_5013`: CVA6 RV32 Load-Store Unit Speculative Non-Idempotent Load Resolution, Word-Granular Store-Buffer Hazard Checking, CBO Commit-Queue Handshaking, and Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_5013` |
| **Source Silicon Repository** | `openhwfoundation/cva6` (`repo_05`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_semantics` (SystemVerilog Semantics, Sim-Synth Mismatch, Latch Avoidance & X-Blocking) |
| **Multi-Domain Tags** | `rtl_integration`, `rtl_semantics` |
| **Editable Files (`allowed_edits`)** | [`code/lsu_bypass.sv`](environment/public/code/lsu_bypass.sv), [`code/load_unit.sv`](environment/public/code/load_unit.sv), [`code/store_buffer.sv`](environment/public/code/store_buffer.sv), [`code/load_store_unit.sv`](environment/public/code/load_store_unit.sv) (4 files, 2085 LOC) |
| **Public Subsystem Context** | 19 RTL files (6548 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Task-Specific Multi-Corner Liberty & SDC Timing Views** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Custom characterized fast/slow/scan corner Liberty libraries for multi-mode OpenSTA closure. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CVA6 RV32 Load-Store Unit Speculative Non-Idempotent Load Resolution, Word-Granular Store-Buffer Hazard Checking, CBO Commit-Queue Handshaking, and Timing Closure

## Background

In the 32-bit CVA6 embedded configuration (`XLEN = 32`, `VLEN = 32`, `PLEN = 32`, `MmuPresent = 0`, `SpeculativeSb = 1`, `NonIdemPotenceEn = 1`, `RVZiCbom = 1`, `NrLoadBufEntries = 2`), the Load-Store Unit (`load_store_unit`) subsystem (`flow/lsu_subsys_top.sv`) integrates:

- `code/lsu_bypass.sv`: a 2-entry fall-through skid buffer between the Address Generation Unit (`AGU`) and `load_unit` / `store_unit` that tracks speculative loads (`is_speculative_load`, `is_speculative_load_miss`) against branch resolution (`resolved_branch_i`).
- `code/load_unit.sv`: manages up to `NrLoadBufEntries = 2` outstanding D-Cache load requests (`ldbuf_q`), stalls speculative or non-committed loads targeting non-idempotent regions (`0x1000_0000 .. 0x1FFF_FFFF` via `WAIT_SPEC_LOAD` / `stall_ni`) or conflicting store-buffer page offsets (`WAIT_PAGE_OFFSET`), suppresses flushed load responses (`ldbuf_flushed_q`), and aligns/sign-extends returning load data.
- `code/store_unit.sv` and `code/store_buffer.sv`: buffers speculative (`speculative_queue_q`) and committed (`commit_queue_q`) stores and cache-block operations (`CBO_INVAL`, `CBO_CLEAN`, `CBO_FLUSH`), checks incoming load `page_offset_i` against pending store addresses (`page_offset_matches_o`), and drains committed stores/CBOs to D-Cache port 2.
- `code/load_store_unit.sv`: top-level AGU, misaligned exception detector, non-MMU physical address bridge (`gen_no_mmu`), and load/store dispatcher.

During verification and Nangate45 synthesis/STA sign-off of `lsu_subsys_top`, several functional and timing/area closure issues were identified across `code/lsu_bypass.sv`, `code/load_unit.sv`, `code/store_buffer.sv`, and `code/load_store_unit.sv`.

## Problem Description & Architectural Requirements

1. **Same-Cycle Non-MMU PPN, Speculative Non-Idempotent Load Resolution & Killed/Exception Load-Buffer Reclamation (`code/load_store_unit.sv`, `code/lsu_bypass.sv`, `code/load_unit.sv`)**:
   - When `MmuPresent = 0` (`gen_no_mmu`), `dtlb_ppn_i` presented to `load_unit` must reflect the current request's physical page number in the **same cycle** as the request (matching the MMU's same-cycle DTLB PPN contract), rather than a 1-cycle-delayed address from the previous request. Otherwise, a speculative or non-committed load targeting a non-idempotent address evaluates `paddr_ni` in `IDLE` against the previous instruction's address and issues a memory request prematurely.
   - When a speculative load to a non-idempotent address enters `WAIT_SPEC_LOAD` and is held in `lsu_bypass` (`mem_q`) waiting for `resolved_branch_i.valid`:
     - `lsu_bypass` must update `is_speculative_load` / `is_speculative_load_miss` not only on a newly arriving `lsu_req_i`, but also on any valid speculative load entries already queued in `mem_q` when `resolved_branch_i.valid` arrives (`is_speculative_load_miss = 1'b1` on `resolved_branch_i.is_mispredict`, or `is_speculative_load = 1'b0` on a correct branch prediction), **and must combinationally forward that branch-resolution update onto `lsu_ctrl_o` in the same cycle `resolved_branch_i.valid` is asserted** (both in fall-through mode and when driving `lsu_ctrl_o` from `mem_q[read_pointer_q]`).
     - `load_unit` must remain in `WAIT_SPEC_LOAD` while `lsu_ctrl_i.is_speculative_load` is still asserted and `!lsu_ctrl_i.is_speculative_load_miss`. On the cycle `resolved_branch_i.valid` resolves as non-mispredicted (`lsu_ctrl_i.is_speculative_load` clears combinationally to `1'b0`), `load_unit` must transition from `WAIT_SPEC_LOAD` to `IDLE` at that clock edge and issue `req_port_o.data_req = 1'b1` on the immediately following cycle. On the cycle `resolved_branch_i.valid` resolves as mispredicted (`lsu_ctrl_i.is_speculative_load_miss` asserts combinationally to `1'b1` while `!req_port_i.data_rvalid`), `load_unit` must combinationally retire a dummy completion (`valid_o = 1'b1`, `ex_o.valid = 1'b0`, `pop_ld_o = 1'b1`) in that same cycle and return to `IDLE` at the clock edge.
   - When `load_unit` is in `SEND_TAG` and `ex_i.valid` is asserted (1-cycle-delayed misaligned or PMP load exception) while `!req_port_i.data_rvalid`, `load_unit` must still retire the excepting load (`valid_o = 1'b1`, `ex_o.valid = 1'b1`, `trans_id_o = ldbuf_q[ldbuf_last_id_q].trans_id`) in that `SEND_TAG` cycle rather than gating `SEND_TAG` exception retirement on `req_port_i.data_rvalid`. Furthermore, whenever a granted load request is killed in `SEND_TAG` (`ex_i.valid`), `ABORT_TRANSACTION`, or `ABORT_TRANSACTION_NI`, its allocated `ldbuf_valid_q[ldbuf_last_id_q]` entry must be reclaimed (`1'b0`) so that killed/aborted loads do not leak load-buffer entries and deadlock `ldbuf_full`.

2. **32-bit Word-Granular Store-Buffer Page-Offset Hazard Check & CBO Commit-Queue Handshake (`code/store_buffer.sv`, `code/load_unit.sv`)**:
   - In `code/store_buffer.sv`, `page_offset_matches_o` must detect address hazards at 32-bit word granularity (`[11:2]`) for 32-bit targets (`XLEN = 32`) across `commit_queue_q`, `speculative_queue_q`, and `paddr_i` (`valid_without_flush_i`), so 32-bit loads to a non-overlapping word within the same 8-byte doubleword (e.g., load at `0x8000_0104` while a store is pending at `0x8000_0100`) do not false-stall in `WAIT_PAGE_OFFSET`, whereas loads overlapping the same 32-bit word properly stall until the store drains.
   - When a committed cache-block operation (`cbo_op != ariane_pkg::CBO_NONE`) in `commit_queue_q` receives `req_port_i.data_gnt` while `!wait_rvalid`, it must transition to `wait_rvalid = 1'b1` and wait for its own subsequent `req_port_i.data_rvalid` completion cycle before evicting the entry from `commit_queue_q`, even if a coincidental `req_port_i.data_rvalid` from an earlier transaction is high on the grant cycle.
   - Ensure clean 32-bit (`XLEN = 32`) load sign-extension in `code/load_unit.sv` without zero-width replication warnings.

3. **LSU Subsystem Synthesis Quality & Timing/Area Closure (`code/lsu_bypass.sv`, `code/load_unit.sv`, `code/store_buffer.sv`, `code/load_store_unit.sv`)**:
   - All combinational logic must synthesize cleanly with zero inferred latches and zero combinational loops (`scc -expect 0` in Yosys after `proc; opt_clean`).
   - Optimize the critical AGU, control, and queue storage paths across the LSU subsystem so that under the Nangate45 synthesis and OpenROAD STA sign-off flow (`flow/lsu_subsys_top.sv` at a `1.80 ns` clock period on `clk_i` with `0.15 ns` input/output external delays and `abc -D 1000`):
     - Worst setup slack (`max`): `>= 0.00 ns`
     - Worst hold slack (`min`): `>= 0.00 ns`
     - Total cell area of `lsu_subsys_top`: `<= 8260.0 um^2`

## Deliverable

Update only the editable RTL files:
- `code/lsu_bypass.sv`
- `code/load_unit.sv`
- `code/store_buffer.sv`
- `code/load_store_unit.sv`

Do not modify module port signatures or package definitions.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/lsu_bypass.sv`
- `code/load_unit.sv`
- `code/store_buffer.sv`
- `code/load_store_unit.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/lsu_subsys_top.sv` (top module: `lsu_subsys_top`)
- Liberty library: `lib/NangateOpenCellLibrary_typical.lib`
- LEF files:
  - `lef/NangateOpenCellLibrary.tech.lef`
  - `lef/NangateOpenCellLibrary.macro.mod.lef`

## Tool Paths
- Verilator: `verilator`
- Yosys: `yosys`
- OpenROAD: `openroad`

## RTL Elaboration & Simulation (Verilator)
```bash
verilator \
  --binary --timing -Wno-fatal \
  --top-module lsu_subsys_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/cf_math_pkg.sv \
  code/lzc.sv \
  code/shift_reg.sv \
  code/cva6_fifo_v3.sv \
  code/amo_buffer.sv \
  code/pmp_entry.sv \
  code/pmp.sv \
  code/pmp_data_if.sv \
  code/lsu_bypass.sv \
  code/store_buffer.sv \
  code/store_unit.sv \
  code/load_unit.sv \
  code/load_store_unit.sv \
  flow/lsu_subsys_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p '
  read_slang --ignore-assertions --top lsu_subsys_top -Iinclude -DSYNTHESIS
    code/config_pkg.sv
    code/cv64a60ax_config_pkg.sv
    code/riscv_pkg.sv
    code/ariane_pkg.sv
    code/cf_math_pkg.sv
    code/lzc.sv
    code/shift_reg.sv
    code/cva6_fifo_v3.sv
    code/amo_buffer.sv
    code/pmp_entry.sv
    code/pmp.sv
    code/pmp_data_if.sv
    code/lsu_bypass.sv
    code/store_buffer.sv
    code/store_unit.sv
    code/load_unit.sv
    code/load_store_unit.sv
    flow/lsu_subsys_top.sv;
  hierarchy -check -top lsu_subsys_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*;
  synth -top lsu_subsys_top -flatten;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 1000;
  clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -noexpr -nohex -nodec netlist.v
'
```

## Static Timing Analysis (OpenROAD)
With `design.sdc`:
```tcl
create_clock -name core_clk -period 1.80 [get_ports clk_i]
set_input_delay 0.15 -clock core_clk [all_inputs]
set_output_delay 0.15 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_ni]
```
Run OpenROAD:
```tcl
read_lef lef/NangateOpenCellLibrary.tech.lef
read_lef lef/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist.v
link_design lsu_subsys_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `lsu_subsys_top`: `<= 8260.0 um^2`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/lsu_bypass.sv (Buggy Starter)
+++ b/solution/gold/code/lsu_bypass.sv (Golden Reference)
@@ -1,28 +1,6 @@
 // Copyright 2018 ETH Zurich and University of Bologna.
-// Copyright and related rights are licensed under the Solderpad Hardware
-// License, Version 0.51 (the "License"); you may not use this file except in
-// compliance with the License.  You may obtain a copy of the License at
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
-// or agreed to in writing, software, hardware and materials distributed under
-// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
-// CONDITIONS OF ANY KIND, either express or implied. See the License for the
-// specific language governing permissions and limitations under the License.
-//
-// Author: Florian Zaruba, ETH Zurich
-// Date: 19.04.2017
-// Description: Load Store Unit, handles address calculation and memory interface signals
+// Licensed under the Solderpad Hardware License, Version 0.51.
 
-
-// ------------------
-// LSU Control
-// ------------------
-// The LSU consists of two independent blocks which share a common address translation block.
-// One block is the load unit, the other one is the store unit. They will signal their readiness
-// with separate signals. If they are not ready the LSU control should keep the last applied signals stable.
-// Furthermore it can be the case that another request for one of the two store units arrives in which case
-// the LSU control should sample it and store it for later application to the units. It does so, by storing it in a
-// two element FIFO. This is necessary as we only know very late in the cycle whether the load/store will succeed (address check,
-// TLB hit mainly). So we better unconditionally allow another request to arrive and store this request in case we need to.
 module lsu_bypass
   import ariane_pkg::*;
 #(
@@ -30,116 +8,108 @@
     parameter type lsu_ctrl_t = logic,
     parameter type bp_resolve_t = logic
 ) (
-    // Subsystem Clock - SUBSYSTEM
-    input logic clk_i,
-    // Asynchronous reset active low - SUBSYSTEM
-    input logic rst_ni,
-    // TO_BE_COMPLETED - TO_BE_COMPLETED
-    input logic flush_i,
-
-    // TO_BE_COMPLETED - TO_BE_COMPLETED
-    input lsu_ctrl_t lsu_req_i,
-    // TO_BE_COMPLETED - TO_BE_COMPLETED
-    input logic      lsu_req_valid_i,
-    // TO_BE_COMPLETED - TO_BE_COMPLETED
-    input logic      pop_ld_i,
-    // TO_BE_COMPLETED - TO_BE_COMPLETED
-    input logic      pop_st_i,
-
-    // Result from branch unit - EX_STAGE
-    input bp_resolve_t resolved_branch_i,
-
-    // TO_BE_COMPLETED - TO_BE_COMPLETED
-    output lsu_ctrl_t lsu_ctrl_o,
-    // TO_BE_COMPLETED - TO_BE_COMPLETED
-    output logic      ready_o
+    input  logic        clk_i,
+    input  logic        rst_ni,
+    input  logic        flush_i,
+    input  lsu_ctrl_t   lsu_req_i,
+    input  logic        lsu_req_valid_i,
+    input  logic        pop_ld_i,
+    input  logic        pop_st_i,
+    input  bp_resolve_t resolved_branch_i,
+    output lsu_ctrl_t   lsu_ctrl_o,
+    output logic        ready_o
 );
 
   lsu_ctrl_t [1:0] mem_n, mem_q;
-  logic read_pointer_n, read_pointer_q;
-  logic write_pointer_n, write_pointer_q;
-  logic [1:0] status_cnt_n, status_cnt_q;
+  logic            read_pointer_n, read_pointer_q;
+  logic            write_pointer_n, write_pointer_q;
+  logic [1:0]      status_cnt_n, status_cnt_q;
+  logic            empty_q;
 
-  logic empty;
-  assign empty   = (status_cnt_q == 0);
-  assign ready_o = empty;
+  assign ready_o = empty_q;
 
   always_comb begin
     automatic logic [1:0] status_cnt;
-    automatic logic write_pointer;
-    automatic logic read_pointer;
+    automatic logic       write_pointer;
+    automatic logic       read_pointer;
 
-    status_cnt = status_cnt_q;
+    status_cnt    = status_cnt_q;
     write_pointer = write_pointer_q;
-    read_pointer = read_pointer_q;
+    read_pointer  = read_pointer_q;
+    mem_n         = mem_q;
 
-    mem_n = mem_q;
-    // we've got a valid LSU request
     if (lsu_req_valid_i) begin
       mem_n[write_pointer_q] = lsu_req_i;
-      if (lsu_req_i.is_speculative_load && resolved_branch_i.valid) begin
-        if (resolved_branch_i.is_mispredict) begin
-          // missprediction: mark speculative loads as misspredicted
-          mem_n[write_pointer_q].is_speculative_load_miss = 1'b1;
-        end else begin
-          // correct prediction: the load is no longer speculative
-          mem_n[write_pointer_q].is_speculative_load = 1'b0;
-        end
-      end
       write_pointer++;
       status_cnt++;
     end
 
-    if (pop_ld_i) begin
-      // invalidate the result
+    if (pop_ld_i || pop_st_i) begin
       mem_n[read_pointer_q].valid = 1'b0;
       read_pointer++;
       status_cnt--;
     end
 
-    if (pop_st_i) begin
-      // invalidate the result
-      mem_n[read_pointer_q].valid = 1'b0;
-      read_pointer++;
-      status_cnt--;
+    if (resolved_branch_i.valid) begin
+      for (int i = 0; i < 2; i++) begin
+        if (mem_n[i].valid && mem_n[i].is_speculative_load) begin
+          if (resolved_branch_i.is_mispredict) begin
+            mem_n[i].is_speculative_load_miss = 1'b1;
+          end else begin
+            mem_n[i].is_speculative_load = 1'b0;
+          end
+        end
+      end
     end
 
-    if (pop_st_i && pop_ld_i) mem_n = '0;
+    if (flush_i) begin
+      status_cnt       = '0;
+      write_pointer    = '0;
+      read_pointer     = '0;
+      mem_n[0].valid   = 1'b0;
+      mem_n[1].valid   = 1'b0;
+    end
 
-    if (flush_i) begin
-      status_cnt = '0;
-      write_pointer = '0;
-      read_pointer = '0;
-      mem_n = '0;
-    end
-    // default assignments
     read_pointer_n  = read_pointer;
     write_pointer_n = write_pointer;
     status_cnt_n    = status_cnt;
   end
 
-  // output assignment
   always_comb begin : output_assignments
-    if (empty) begin
+    if (empty_q) begin
       lsu_ctrl_o = lsu_req_i;
+      if (lsu_req_i.is_speculative_load && resolved_branch_i.valid) begin
+        if (resolved_branch_i.is_mispredict) begin
+          lsu_ctrl_o.is_speculative_load_miss = 1'b1;
+        end else begin
+          lsu_ctrl_o.is_speculative_load = 1'b0;
+        end
+      end
     end else begin
       lsu_ctrl_o = mem_q[read_pointer_q];
+      if (mem_q[read_pointer_q].is_speculative_load && resolved_branch_i.valid) begin
+        if (resolved_branch_i.is_mispredict) begin
+          lsu_ctrl_o.is_speculative_load_miss = 1'b1;
+        end else begin
+          lsu_ctrl_o.is_speculative_load = 1'b0;
+        end
+      end
     end
   end
 
-  // registers
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (~rst_ni) begin
       mem_q           <= '0;
       status_cnt_q    <= '0;
       write_pointer_q <= '0;
       read_pointer_q  <= '0;
+      empty_q         <= 1'b1;
     end else begin
       mem_q           <= mem_n;
       status_cnt_q    <= status_cnt_n;
       write_pointer_q <= write_pointer_n;
       read_pointer_q  <= read_pointer_n;
+      empty_q         <= (status_cnt_n == 2'd0);
     end
   end
 endmodule
-

--- a/environment/public/code/load_unit.sv (Buggy Starter)
+++ b/solution/gold/code/load_unit.sv (Golden Reference)
@@ -106,7 +106,8 @@
   typedef struct packed {
     logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;   // scoreboard identifier
     logic [CVA6Cfg.VLEN-1:0]          vaddr;      // virtual address
-    fu_op                             operation;  // type of load
+    logic                             is_signed;
+    logic [1:0]                       size;
   } ldbuf_t;
 
 
@@ -166,6 +167,9 @@
     if (ldbuf_r && (!LDBUF_FALLTHROUGH || !ldbuf_w)) begin
       ldbuf_valid_d[ldbuf_rindex] = 1'b0;
     end
+    if ((state_q == ABORT_TRANSACTION) || (state_q == ABORT_TRANSACTION_NI) || ((state_q == SEND_TAG) && ex_i.valid)) begin
+      ldbuf_valid_d[ldbuf_last_id_q] = 1'b0;
+    end
     //  Track a new outstanding operation in the load buffer
     if (ldbuf_w) begin
       ldbuf_flushed_d[ldbuf_windex] = 1'b0;
@@ -211,7 +215,9 @@
   assign req_port_o.data_wdata = '0;
   assign req_port_o.cbo_op = ariane_pkg::CBO_NONE;
   // compose the load buffer write data, control is handled in the FSM
-  assign ldbuf_wdata = {lsu_ctrl_i.trans_id, lsu_ctrl_i.vaddr, lsu_ctrl_i.operation};
+  logic w_is_signed;
+  assign w_is_signed = lsu_ctrl_i.operation inside {ariane_pkg::LW, ariane_pkg::LH, ariane_pkg::LB, ariane_pkg::HLV_W, ariane_pkg::HLV_H, ariane_pkg::HLV_B};
+  assign ldbuf_wdata = {lsu_ctrl_i.trans_id, lsu_ctrl_i.vaddr, w_is_signed, extract_transfer_size(lsu_ctrl_i.operation)};
   // output address
   // we can now output the lower 12 bit as the index to the cache
   assign req_port_o.address_index = lsu_ctrl_i.vaddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
@@ -317,22 +323,18 @@
 
         // wait here for the page offset to not match anymore
         WAIT_PAGE_OFFSET: begin
-          // we make a new request as soon as the page offset does not match anymore
           if (!page_offset_matches_i) begin
             state_d = WAIT_GNT;
           end
         end
 
         WAIT_SPEC_LOAD: begin
-          // if we have a misspredicted speculative load
           if (CVA6Cfg.SpeculativeSb && lsu_ctrl_i.is_speculative_load_miss) begin
-            // pop load - but only if we are not getting an rvalid in here - otherwise we will over-write an incoming transaction
             if (!req_port_i.data_rvalid) begin
               state_d  = IDLE;
               pop_ld_o = 1'b1;
             end
-            // if we have a correct prediction this is now a regular load
-          end else begin
+          end else if (!CVA6Cfg.SpeculativeSb || !lsu_ctrl_i.is_speculative_load) begin
             state_d = IDLE;
           end
         end
@@ -500,9 +502,6 @@
           ex_o.tval = ldbuf_rdata.vaddr;
         end
       end
-      // the output is also valid if we got an exception. An exception arrives one cycle after
-      // dtlb_hit_i is asserted, i.e. when we are in SEND_TAG. Otherwise, the exception
-      // corresponds to the next request that is already being translated (see below).
       if ((state_q == SEND_TAG) && (ex_i.valid || req_port_i.data_error)) begin
         valid_o    = 1'b1;
         ex_o.valid = 1'b1;
@@ -511,6 +510,11 @@
           ex_o.tval = ldbuf_rdata.vaddr;
         end
       end
+    end
+    if ((state_q == SEND_TAG) && ex_i.valid && !req_port_i.data_rvalid) begin
+      trans_id_o = ldbuf_q[ldbuf_last_id_q].trans_id;
+      valid_o    = 1'b1;
+      ex_o.valid = 1'b1;
     end
 
     // an exception occurred during translation
@@ -588,83 +592,36 @@
   // BIG ENDIAN CAPABLE result mux fast
   logic [CVA6Cfg.XLEN-1:0] endian_data;
 
-  // Reversing the order of the Bytes in the data loaded from memory if mbe=1 -> which comes from the CSRregfile meaning the processor is in Big Endian Mode.
-  // If mbe=1 then the processor should treat Data memory as Big Endian. The internals of CVA6 are Little endian, so we achieve this by Reversing the Byte Order to Little Endian when it enters the processor through a Load.
   always_comb begin
     endian_data = shifted_data;
     if (mbe_i) begin
-      case (ldbuf_rdata.operation)
-        LB, LBU, HLV_B, HLV_BU, FLB: begin
-          // If we are just loading a byte, then this needs not be touched
-          endian_data[7:0] = {shifted_data[7:0]};
-        end
-        LH, LHU, HLV_H, HLV_HU, HLVX_HU, FLH: begin
-          endian_data[15:0] = {<<8{shifted_data[15:0]}};
-        end
-        LW, LWU, HLV_W, HLV_WU, HLVX_WU, FLW, AMO_LRW, AMO_SCW, AMO_SWAPW, AMO_ADDW,
-        AMO_ANDW, AMO_ORW, AMO_XORW, AMO_MAXW, AMO_MAXWU, AMO_MINW, AMO_MINWU: begin
-          endian_data[31:0] = {<<8{shifted_data[31:0]}};
-        end
-        default: begin
-          endian_data[CVA6Cfg.XLEN-1:0] = {<<8{shifted_data[CVA6Cfg.XLEN-1:0]}};
-        end
+      unique case (ldbuf_rdata.size)
+        2'b00:   endian_data[7:0]  = shifted_data[7:0];
+        2'b01:   endian_data[15:0] = {<<8{shifted_data[15:0]}};
+        default: endian_data[31:0] = {<<8{shifted_data[31:0]}};
       endcase
     end
   end
 
-  // result mux fast
-  logic [        (CVA6Cfg.XLEN/8)-1:0] rdata_sign_bits;
+  logic [(CVA6Cfg.XLEN/8)-1:0]         rdata_sign_bits;
   logic [CVA6Cfg.XLEN_ALIGN_BYTES-1:0] rdata_offset;
-  logic rdata_sign_bit, rdata_is_signed, rdata_is_fp_signed;
-
-
-  // prepare these signals for faster selection in the next cycle
-  assign rdata_is_signed    =   ldbuf_rdata.operation inside {ariane_pkg::LW,  ariane_pkg::LH,  ariane_pkg::LB, ariane_pkg::HLV_W, ariane_pkg::HLV_H, ariane_pkg::HLV_B};
-  assign rdata_is_fp_signed =   ldbuf_rdata.operation inside {ariane_pkg::FLW, ariane_pkg::FLH, ariane_pkg::FLB};
-  // If we are in Big Endian Mode, we don't need to add anything to the address offset to find the byte that contains the sign bit, as it is always the lowest addressed byte that has the sign bit.
-  assign rdata_offset       = ((ldbuf_rdata.operation inside {ariane_pkg::LW,  ariane_pkg::FLW, ariane_pkg::HLV_W}) && CVA6Cfg.IS_XLEN64 && (~mbe_i)) ? ldbuf_addroff + 3 :
-                                ( ldbuf_rdata.operation inside {ariane_pkg::LH,  ariane_pkg::FLH, ariane_pkg::HLV_H} && (~mbe_i))                     ? ldbuf_addroff + 1 :
-                                                                                                                         ldbuf_addroff;
+  logic                                rdata_sign_bit;
+
+  assign rdata_offset = (ldbuf_rdata.size == 2'b10 && !mbe_i) ? ldbuf_addroff + 2'd3 :
+                        (ldbuf_rdata.size == 2'b01 && !mbe_i) ? ldbuf_addroff + 2'd1 :
+                                                                ldbuf_addroff;
 
   for (genvar i = 0; i < (CVA6Cfg.XLEN / 8); i++) begin : gen_sign_bits
     assign rdata_sign_bits[i] = req_port_i.data_rdata[(i+1)*8-1];
   end
 
-
-  // select correct sign bit in parallel to result shifter above
-  // pull to 0 if unsigned
-  assign rdata_sign_bit = (rdata_is_signed && rdata_sign_bits[rdata_offset]) || (CVA6Cfg.FpPresent && rdata_is_fp_signed);
-
-  // result mux
+  assign rdata_sign_bit = ldbuf_rdata.is_signed && rdata_sign_bits[rdata_offset];
+
   always_comb begin
-    unique case (ldbuf_rdata.operation)
-      ariane_pkg::LW, ariane_pkg::LWU, ariane_pkg::HLV_W, ariane_pkg::HLV_WU, ariane_pkg::HLVX_WU:
-      result_o = {{CVA6Cfg.XLEN - 32{rdata_sign_bit}}, endian_data[31:0]};
-      ariane_pkg::LH, ariane_pkg::LHU, ariane_pkg::HLV_H, ariane_pkg::HLV_HU, ariane_pkg::HLVX_HU:
-      result_o = {{CVA6Cfg.XLEN - 32 + 16{rdata_sign_bit}}, endian_data[15:0]};
-      ariane_pkg::LB, ariane_pkg::LBU, ariane_pkg::HLV_B, ariane_pkg::HLV_BU:
-      result_o = {{CVA6Cfg.XLEN - 32 + 24{rdata_sign_bit}}, endian_data[7:0]};
-      default: begin
-        // FLW, FLH and FLB have been defined here in default case to improve Code Coverage
-        if (CVA6Cfg.FpPresent) begin
-          unique case (ldbuf_rdata.operation)
-            ariane_pkg::FLW: begin
-              result_o = {{CVA6Cfg.XLEN - 32{rdata_sign_bit}}, endian_data[31:0]};
-            end
-            ariane_pkg::FLH: begin
-              result_o = {{CVA6Cfg.XLEN - 32 + 16{rdata_sign_bit}}, endian_data[15:0]};
-            end
-            ariane_pkg::FLB: begin
-              result_o = {{CVA6Cfg.XLEN - 32 + 24{rdata_sign_bit}}, endian_data[7:0]};
-            end
-            default: begin
-              result_o = endian_data[CVA6Cfg.XLEN-1:0];
-            end
-          endcase
-        end else begin
-          result_o = endian_data[CVA6Cfg.XLEN-1:0];
-        end
-      end
+    unique case (ldbuf_rdata.size)
+      2'b00:   result_o = {{24{rdata_sign_bit}}, endian_data[7:0]};
+      2'b01:   result_o = {{16{rdata_sign_bit}}, endian_data[15:0]};
+      default: result_o = endian_data[31:0];
     endcase
   end
   // end BIG ENDIAN CAPABLE result mux fast
@@ -680,17 +637,17 @@
   // check invalid offsets, but only issue a warning as these conditions actually trigger a load address misaligned exception
   addr_offset0 :
   assert property (@(posedge clk_i) disable iff (~rst_ni)
-        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LW, ariane_pkg::LWU})
+        ldbuf_w |->  (lsu_ctrl_i.operation inside {ariane_pkg::LW, ariane_pkg::LWU})
         |-> ldbuf_wdata.vaddr[CVA6Cfg.XLEN_ALIGN_BYTES-1:0] < 5)
   else $warning("invalid address offset used with {LW, LWU}");
   addr_offset1 :
   assert property (@(posedge clk_i) disable iff (~rst_ni)
-        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LH, ariane_pkg::LHU})
+        ldbuf_w |->  (lsu_ctrl_i.operation inside {ariane_pkg::LH, ariane_pkg::LHU})
         |-> ldbuf_wdata.vaddr[CVA6Cfg.XLEN_ALIGN_BYTES-1:0] < 7)
   else $warning("invalid address offset used with {LH, LHU}");
   addr_offset2 :
   assert property (@(posedge clk_i) disable iff (~rst_ni)
-        ldbuf_w |->  (ldbuf_wdata.operation inside {ariane_pkg::LB, ariane_pkg::LBU})
+        ldbuf_w |->  (lsu_ctrl_i.operation inside {ariane_pkg::LB, ariane_pkg::LBU})
         |-> ldbuf_wdata.vaddr[CVA6Cfg.XLEN_ALIGN_BYTES-1:0] < 8)
   else $fatal(1, "invalid address offset used with {LB, LBU}");
   //pragma translate_on

--- a/environment/public/code/store_buffer.sv (Buggy Starter)
+++ b/solution/gold/code/store_buffer.sv (Golden Reference)
@@ -1,18 +1,5 @@
 // Copyright 2018 ETH Zurich and University of Bologna.
-// Copyright and related rights are licensed under the Solderpad Hardware
-// License, Version 0.51 (the "License"); you may not use this file except in
-// compliance with the License.  You may obtain a copy of the License at
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
-// or agreed to in writing, software, hardware and materials distributed under
-// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
-// CONDITIONS OF ANY KIND, either express or implied. See the License for the
-// specific language governing permissions and limitations under the License.
-//
-// Author: Florian Zaruba, ETH Zurich
-// Date: 25.04.2017
-// Description: Store queue persists store requests and pushes them to memory
-//              if they are no longer speculative
-
+// Licensed under the Solderpad Hardware License, Version 0.51.
 
 module store_buffer
   import ariane_pkg::*;
@@ -22,139 +9,115 @@
     parameter type                   dcache_req_o_t = logic,
     parameter type                   cbo_t          = logic
 ) (
-    input logic clk_i,  // Clock
-    input logic rst_ni,  // Asynchronous reset active low
-    input logic flush_i,  // if we flush we need to pause the transactions on the memory
-                          // otherwise we will run in a deadlock with the memory arbiter
-    input logic stall_st_pending_i,  // Stall issuing non-speculative request
-    output logic         no_st_pending_o, // non-speculative queue is empty (e.g.: everything is committed to the memory hierarchy)
-    output logic         store_buffer_empty_o, // there is no store pending in neither the speculative unit or the non-speculative queue
-
-    input  logic [11:0]  page_offset_i,         // check for the page offset (the last 12 bit if the current load matches them)
-    output logic         page_offset_matches_o, // the above input page offset matches -> let the store buffer drain
-
-    input logic commit_i,  // commit the instruction which was placed there most recently
-    output logic commit_ready_o,  // commit queue is ready to accept another commit request
-    output logic ready_o,  // the store queue is ready to accept a new request
-                           // it is only ready if it can unconditionally commit the instruction, e.g.:
-                           // the commit buffer needs to be empty
-    input logic valid_i,  // this is a valid store
-    input  logic         valid_without_flush_i, // just tell if the address is valid which we are current putting and do not take any further action
-
-    input  logic [CVA6Cfg.PLEN-1:0]  paddr_i,         // physical address of store which needs to be placed in the queue
+    input  logic                    clk_i,
+    input  logic                    rst_ni,
+    input  logic                    flush_i,
+    input  logic                    stall_st_pending_i,
+    output logic                    no_st_pending_o,
+    output logic                    store_buffer_empty_o,
+    input  logic [11:0]             page_offset_i,
+    output logic                    page_offset_matches_o,
+    input  logic                    commit_i,
+    output logic                    commit_ready_o,
+    output logic                    ready_o,
+    input  logic                    valid_i,
+    input  logic                    valid_without_flush_i,
+    input  logic [CVA6Cfg.PLEN-1:0] paddr_i,
     output logic [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr_o,
-    input logic [CVA6Cfg.XLEN-1:0] data_i,  // data which is placed in the queue
-    input logic [(CVA6Cfg.XLEN/8)-1:0] be_i,  // byte enable in
-    input logic [1:0] data_size_i,  // type of request we are making (e.g.: bytes to write)
-    input cbo_t cbo_op_i,  // type of cache block operation
-
-    // D$ interface
-    input  dcache_req_o_t req_port_i,
-    output dcache_req_i_t req_port_o
+    input  logic [CVA6Cfg.XLEN-1:0] data_i,
+    input  logic [(CVA6Cfg.XLEN/8)-1:0] be_i,
+    input  logic [1:0]              data_size_i,
+    input  cbo_t                    cbo_op_i,
+    input  dcache_req_o_t           req_port_i,
+    output dcache_req_i_t           req_port_o
 );
 
-  // the store queue has two parts:
-  // 1. Speculative queue
-  // 2. Commit queue which is non-speculative, e.g.: the store will definitely happen.
+  function automatic logic [1:0] encode_cbo(input cbo_t op);
+    unique case (op)
+      ariane_pkg::CBO_INVAL: return 2'b01;
+      ariane_pkg::CBO_CLEAN: return 2'b10;
+      ariane_pkg::CBO_FLUSH: return 2'b11;
+      default:               return 2'b00;
+    endcase
+  endfunction
+
+  function automatic cbo_t decode_cbo(input logic [1:0] code);
+    unique case (code)
+      2'b01:   return ariane_pkg::CBO_INVAL;
+      2'b10:   return ariane_pkg::CBO_CLEAN;
+      2'b11:   return ariane_pkg::CBO_FLUSH;
+      default: return ariane_pkg::CBO_NONE;
+    endcase
+  endfunction
+
   struct packed {
-    logic [CVA6Cfg.PLEN-1:0] address;
-    logic [CVA6Cfg.XLEN-1:0] data;
+    logic [CVA6Cfg.PLEN-1:0]     address;
+    logic [CVA6Cfg.XLEN-1:0]     data;
     logic [(CVA6Cfg.XLEN/8)-1:0] be;
-    logic [1:0] data_size;
-    cbo_t cbo_op;
-    logic valid;  // this entry is valid, we need this for checking if the address offset matches
-    logic wait_rvalid;  // need to wait for rvalid...
+    logic [1:0]                  data_size;
+    logic [1:0]                  cbo_code;
+    logic                        valid;
   }
       speculative_queue_n[DEPTH_SPEC-1:0],
       speculative_queue_q[DEPTH_SPEC-1:0],
       commit_queue_n[DEPTH_COMMIT-1:0],
       commit_queue_q[DEPTH_COMMIT-1:0];
 
-  // keep a status count for both buffers
+  logic                        commit_wait_rvalid_n, commit_wait_rvalid_q;
   logic [$clog2(DEPTH_SPEC):0] speculative_status_cnt_n, speculative_status_cnt_q;
   logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt_n, commit_status_cnt_q;
-  // Speculative queue
   logic [$clog2(DEPTH_SPEC)-1:0] speculative_read_pointer_n, speculative_read_pointer_q;
   logic [$clog2(DEPTH_SPEC)-1:0] speculative_write_pointer_n, speculative_write_pointer_q;
-  // Commit Queue
   logic [$clog2(DEPTH_COMMIT)-1:0] commit_read_pointer_n, commit_read_pointer_q;
   logic [$clog2(DEPTH_COMMIT)-1:0] commit_write_pointer_n, commit_write_pointer_q;
 
   assign store_buffer_empty_o = (speculative_status_cnt_q == 0) & no_st_pending_o;
-  // ----------------------------------------
-  // Speculative Queue - Core Interface
-  // ----------------------------------------
+
   always_comb begin : core_if
     automatic logic [$clog2(DEPTH_SPEC):0] speculative_status_cnt;
     speculative_status_cnt      = speculative_status_cnt_q;
-
-    // default assignments
     speculative_read_pointer_n  = speculative_read_pointer_q;
     speculative_write_pointer_n = speculative_write_pointer_q;
     speculative_queue_n         = speculative_queue_q;
-    // LSU interface
-    // we are ready to accept a new entry and the input data is valid
+
     if (valid_i) begin
-      speculative_queue_n[speculative_write_pointer_q].address = paddr_i;
-      speculative_queue_n[speculative_write_pointer_q].data = data_i;
-      speculative_queue_n[speculative_write_pointer_q].be = be_i;
+      speculative_queue_n[speculative_write_pointer_q].address   = paddr_i;
+      speculative_queue_n[speculative_write_pointer_q].data      = data_i;
+      speculative_queue_n[speculative_write_pointer_q].be        = be_i;
 
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/amo_buffer.sv`](environment/public/code/amo_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a60ax_config_pkg.sv`](environment/public/code/cv64a60ax_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cva6_fifo_v3.sv`](environment/public/code/cva6_fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/load_store_unit.sv`](environment/public/code/load_store_unit.sv) **(Editable)**
- [`environment/public/code/load_unit.sv`](environment/public/code/load_unit.sv) **(Editable)**
- [`environment/public/code/lsu_bypass.sv`](environment/public/code/lsu_bypass.sv) **(Editable)**
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/pmp.sv`](environment/public/code/pmp.sv) *(Read-Only Context)*
- [`environment/public/code/pmp_data_if.sv`](environment/public/code/pmp_data_if.sv) *(Read-Only Context)*
- [`environment/public/code/pmp_entry.sv`](environment/public/code/pmp_entry.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/shift_reg.sv`](environment/public/code/shift_reg.sv) *(Read-Only Context)*
- [`environment/public/code/store_buffer.sv`](environment/public/code/store_buffer.sv) **(Editable)**
- [`environment/public/code/store_unit.sv`](environment/public/code/store_unit.sv) *(Read-Only Context)*
- [`environment/public/flow/lsu_subsys_top.sv`](environment/public/flow/lsu_subsys_top.sv) *(Read-Only Context)*
- [`environment/public/include/common_cells/LICENSE.Apache-2.0`](environment/public/include/common_cells/LICENSE.Apache-2.0) *(Read-Only Context)*
- [`environment/public/include/common_cells/assertions.svh`](environment/public/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lef/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.tech.lef`](environment/public/lef/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/LICENSE_NANGATE`](environment/public/lib/LICENSE_NANGATE) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

