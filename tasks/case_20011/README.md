# `case_20011`: Fix Sv32 PTW Address Drift, Superpage Alignment, SFENCE Race, and In-Order Faulting in biRISC-V MMU

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_20011` |
| **Source Silicon Repository** | `ultraembedded/biriscv` (`repo_44`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Core_RISCV_Processors` (Core_RISCV_Processors) |
| **Multi-Domain Tags** | `Core_RISCV_Processors` |
| **Editable Files (`allowed_edits`)** | [`code/biriscv_mmu.v`](environment/public/code/biriscv_mmu.v) (1 files, 554 LOC) |
| **Public Subsystem Context** | 5 RTL files (2233 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Sv32 Translation, Page-Table Walk Coherence, and Fault Ordering in `biriscv_mmu`

`code/biriscv_mmu.v` exhibits virtual-memory translation, TLB coherence, and downstream response-ordering bugs across its instruction TLB, data TLB, two-level Sv32 hardware page-table walker (PTW), and shared downstream D-cache port.

Fix `code/biriscv_mmu.v` while preserving its module interface and parameters (`MEM_CACHE_ADDR_MIN`, `MEM_CACHE_ADDR_MAX`, `SUPPORT_MMU`):

1. **RISC-V Sv32 Translation & Non-Updating PTE Semantics (`SUPPORT_MMU = 1` / `0`)**:
   - Bypass translation cleanly when `SUPPORT_MMU = 0`, in Machine mode, or when `satp` selects Bare mode (`MODE == 0`) on both instruction fetch and data accesses.
   - Enforce full RISC-V Privileged Sv32 PTE validation across both walk levels and 4 MiB superpages (including PTW bus errors, invalid/reserved PTE encodings, non-leaf entries at the final level, misaligned superpage physical frame numbers, non-updating `A`/`D` fault rules, and `U`/`S` privilege checks with `sum_i` and `mxr_i`).

2. **In-Flight PTW Address Stability & `SFENCE.VMA` (`flush_i`) Coherence**:
   - Complete an initiated PTW using the virtual address that triggered the walk even if `fetch_in_pc_i` or `lsu_in_addr_i` changes before the walk finishes, installing a valid translation in a single walk without redundant re-walks.
   - Ensure `flush_i` invalidates cached ITLB/DTLB translations and prevents any PTW already in flight across the flush from installing a stale TLB entry, without stranding or corrupting already-issued downstream PTW memory reads.

3. **Request Retention & Strictly In-Order Fault Serialization**:
   - Retain any unaccepted D-side request (load, store, or cache maintenance) until `lsu_in_accept_o` completes the handshake, even if upstream deasserts request strobes after the initial cycle.
   - Preserve strictly in-order response/fault delivery on both the I-side (`fetch_in_valid_o` / `fetch_in_fault_o`) and D-side (`lsu_in_ack_o` / `lsu_in_load_fault_o` / `lsu_in_store_fault_o`) when a younger TLB/page fault follows an older still-pending downstream cache transaction.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Guide

## Workspace Files
- **Editable RTL**: `code/biriscv_mmu.v`
- **Read-Only Context RTL**: `code/biriscv_defs.v`, `code/biriscv_lsu.v`, `code/biriscv_fetch.v`, `code/biriscv_csr.v`

## Tooling Examples
```bash
# Yosys synthesis & latch/loop check
yosys -p "
  read_verilog -sv -DSYNTHESIS -Icode code/biriscv_defs.v code/biriscv_mmu.v;
  hierarchy -check -top biriscv_mmu -chparam SUPPORT_MMU 1;
  proc; opt_expr; check -assert;
  select -assert-none t:\$dlatch*
"

# Verilator lint check
verilator --lint-only -sv -Wno-fatal -Icode --top-module biriscv_mmu code/biriscv_defs.v code/biriscv_mmu.v
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/biriscv_mmu.v (Buggy Starter)
+++ b/solution/gold/code/biriscv_mmu.v (Golden Reference)
@@ -8,35 +8,13 @@
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
 module biriscv_mmu
-//-----------------------------------------------------------------
-// Params
-//-----------------------------------------------------------------
 #(
      parameter MEM_CACHE_ADDR_MIN = 0
     ,parameter MEM_CACHE_ADDR_MAX = 32'hffffffff
     ,parameter SUPPORT_MMU      = 1
 )
-//-----------------------------------------------------------------
-// Ports
-//-----------------------------------------------------------------
 (
-    // Inputs
      input           clk_i
     ,input           rst_i
     ,input  [  1:0]  priv_d_i
@@ -68,7 +46,6 @@
     ,input           lsu_out_error_i
     ,input  [ 10:0]  lsu_out_resp_tag_i
 
-    // Outputs
     ,output          fetch_in_accept_o
     ,output          fetch_in_valid_o
     ,output          fetch_in_error_o
@@ -96,36 +73,21 @@
     ,output          lsu_in_store_fault_o
 );
 
-
-
-//-----------------------------------------------------------------
-// Includes
-//-----------------------------------------------------------------
 `include "biriscv_defs.v"
 
-//-----------------------------------------------------------------
-// Local defs
-//-----------------------------------------------------------------
 localparam  STATE_W            = 2;
-localparam  STATE_IDLE         = 0;
-localparam  STATE_LEVEL_FIRST  = 1;
-localparam  STATE_LEVEL_SECOND = 2;
-localparam  STATE_UPDATE       = 3;
-
-//-----------------------------------------------------------------
-// Basic MMU support
-//-----------------------------------------------------------------
+localparam  STATE_IDLE         = 2'd0;
+localparam  STATE_LEVEL_FIRST  = 2'd1;
+localparam  STATE_LEVEL_SECOND = 2'd2;
+localparam  STATE_UPDATE       = 2'd3;
+
 generate
 if (SUPPORT_MMU)
-begin
-
-    //-----------------------------------------------------------------
-    // Registers
-    //-----------------------------------------------------------------
+begin : gen_mmu
+
     reg [STATE_W-1:0] state_q;
     wire              idle_w = (state_q == STATE_IDLE);
 
-    // Magic combo used only by MMU
     wire        resp_mmu_w   = (lsu_out_resp_tag_i[9:7] == 3'b111);
     wire        resp_valid_w = resp_mmu_w & lsu_out_ack_i;
     wire        resp_error_w = resp_mmu_w & lsu_out_error_i;
@@ -134,125 +96,197 @@
     wire        cpu_accept_w;
 
     //-----------------------------------------------------------------
-    // Load / Store
-    //-----------------------------------------------------------------
-    reg       load_q;
-    reg [3:0] store_q;
-
-    always @ (posedge clk_i or posedge rst_i)
-    if (rst_i)
-        load_q <= 1'b0;
-    else if (lsu_in_rd_i)
-        load_q <= ~lsu_in_accept_o;
-
-    always @ (posedge clk_i or posedge rst_i)
-    if (rst_i)
-        store_q <= 4'b0;
-    else if (|lsu_in_wr_i)
-        store_q <= lsu_in_accept_o ? 4'b0 : lsu_in_wr_i;
-
-    wire       load_w  = lsu_in_rd_i | load_q;
-    wire [3:0] store_w = lsu_in_wr_i | store_q;
-
-    reg [31:0] lsu_in_addr_q;
-
-    always @ (posedge clk_i or posedge rst_i)
-    if (rst_i)
-        lsu_in_addr_q <= 32'b0;
-    else if (load_w || (|store_w))
-        lsu_in_addr_q <= lsu_in_addr_i;
-
-    wire [31:0] lsu_addr_w = (load_w || (|store_w)) ? lsu_in_addr_i : lsu_in_addr_q;
-
-    //-----------------------------------------------------------------
-    // Page table walker
+    // Stalled D-Side Request Retention Buffer
+    //-----------------------------------------------------------------
+    reg         lsu_hold_q;
+    reg         hold_rd_q;
+    reg [  3:0] hold_wr_q;
+    reg [ 31:0] hold_addr_q;
+    reg [ 31:0] hold_wdata_q;
+    reg [ 10:0] hold_tag_q;
+    reg         hold_inv_q;
+    reg         hold_wb_q;
+    reg         hold_flush_q;
+
+    wire        raw_d_req_w = lsu_in_rd_i || (|lsu_in_wr_i) || lsu_in_invalidate_i || lsu_in_writeback_i || lsu_in_flush_i;
+
+    always @ (posedge clk_i or posedge rst_i)
+    if (rst_i)
+    begin
+        lsu_hold_q   <= 1'b0;
+        hold_rd_q    <= 1'b0;
+        hold_wr_q    <= 4'b0;
+        hold_addr_q  <= 32'b0;
+        hold_wdata_q <= 32'b0;
+        hold_tag_q   <= 11'b0;
+        hold_inv_q   <= 1'b0;
+        hold_wb_q    <= 1'b0;
+        hold_flush_q <= 1'b0;
+    end
+    else if (lsu_hold_q)
+    begin
+        if (lsu_in_accept_o)
+            lsu_hold_q <= 1'b0;
+    end
+    else if (raw_d_req_w && !lsu_in_accept_o)
+    begin
+        lsu_hold_q   <= 1'b1;
+        hold_rd_q    <= lsu_in_rd_i;
+        hold_wr_q    <= lsu_in_wr_i;
+        hold_addr_q  <= lsu_in_addr_i;
+        hold_wdata_q <= lsu_in_data_wr_i;
+        hold_tag_q   <= lsu_in_req_tag_i;
+        hold_inv_q   <= lsu_in_invalidate_i;
+        hold_wb_q    <= lsu_in_writeback_i;
+        hold_flush_q <= lsu_in_flush_i;
+    end
+
+    wire        load_w       = lsu_hold_q ? hold_rd_q    : lsu_in_rd_i;
+    wire [ 3:0] store_w      = lsu_hold_q ? hold_wr_q    : lsu_in_wr_i;
+    wire [31:0] lsu_addr_w   = lsu_hold_q ? hold_addr_q  : lsu_in_addr_i;
+    wire [31:0] lsu_wdata_w  = lsu_hold_q ? hold_wdata_q : lsu_in_data_wr_i;
+    wire [10:0] lsu_tag_w    = lsu_hold_q ? hold_tag_q   : lsu_in_req_tag_i;
+    wire        lsu_inv_w    = lsu_hold_q ? hold_inv_q   : lsu_in_invalidate_i;
+    wire        lsu_wb_w     = lsu_hold_q ? hold_wb_q    : lsu_in_writeback_i;
+    wire        lsu_flush_w  = lsu_hold_q ? hold_flush_q : lsu_in_flush_i;
+
+    //-----------------------------------------------------------------
+    // Downstream In-Flight Counters (Guarantee Strictly In-Order Faults)
+    //-----------------------------------------------------------------
+    reg [2:0] icache_pend_q;
+    wire      icache_push_w = fetch_out_rd_o && fetch_out_accept_i;
+    wire      icache_pop_w  = fetch_out_valid_i;
+
+    always @ (posedge clk_i or posedge rst_i)
+    if (rst_i)
+        icache_pend_q <= 3'd0;
+    else if (fetch_out_flush_o)
+        icache_pend_q <= 3'd0;
+    else if (icache_push_w && !icache_pop_w)
+        icache_pend_q <= icache_pend_q + 3'd1;
+    else if (!icache_push_w && icache_pop_w && (icache_pend_q != 3'd0))
+        icache_pend_q <= icache_pend_q - 3'd1;
+
+    reg [2:0] dcache_pend_q;
+    wire      src_mmu_w;
+    wire      dcache_push_w = !src_mmu_w && (lsu_out_rd_o || (|lsu_out_wr_o) || lsu_out_invalidate_o || lsu_out_writeback_o || lsu_out_flush_o) && lsu_out_accept_i;
+    wire      dcache_pop_w  = lsu_out_ack_i && !resp_mmu_w;
+
+    always @ (posedge clk_i or posedge rst_i)
+    if (rst_i)
+        dcache_pend_q <= 3'd0;
+    else if (dcache_push_w && !dcache_pop_w)
+        dcache_pend_q <= dcache_pend_q + 3'd1;
+    else if (!dcache_push_w && dcache_pop_w && (dcache_pend_q != 3'd0))
+        dcache_pend_q <= dcache_pend_q - 3'd1;
+
+    //-----------------------------------------------------------------
+    // Sv32 Mode & Page Table Walker
     //-----------------------------------------------------------------
     wire        itlb_hit_w;
     wire        dtlb_hit_w;
-
     reg         dtlb_req_q;
-
-    // Global enable
-    wire        vm_enable_w = satp_i[`SATP_MODE_R];
-    wire [31:0] ptbr_w      = {satp_i[`SATP_PPN_R], 12'b0};
-
-    wire        ifetch_vm_w = (fetch_in_priv_i != `PRIV_MACHINE);
-    wire        dfetch_vm_w = (priv_d_i != `PRIV_MACHINE);
+    reg         walk_flushed_q;
+
+    // Sv32 active ONLY when satp.MODE == 1 AND privilege != M-mode!
+    wire        vm_enable_w    = satp_i[`SATP_MODE_R];
+    wire [31:0] ptbr_w         = {satp_i[`SATP_PPN_R], 12'b0};
+
+    wire        ifetch_vm_w    = (fetch_in_priv_i != `PRIV_MACHINE);
+    wire        dfetch_vm_w    = (priv_d_i != `PRIV_MACHINE);
 
     wire        supervisor_i_w = (fetch_in_priv_i == `PRIV_SUPER);
     wire        supervisor_d_w = (priv_d_i == `PRIV_SUPER);
 
-    wire        vm_i_enable_w = (ifetch_vm_w);
-    wire        vm_d_enable_w = (vm_enable_w & dfetch_vm_w);
-
-    // TLB entry does not match request address
-    wire        itlb_miss_w = fetch_in_rd_i & vm_i_enable_w & ~itlb_hit_w;
-    wire        dtlb_miss_w = (load_w || (|store_w)) & vm_d_enable_w & ~dtlb_hit_w;
-
-    // Data miss is higher priority than instruction...
-    wire [31:0] request_addr_w = idle_w ? 
-                                (dtlb_miss_w ? lsu_addr_w : fetch_in_pc_i) :
-                                 dtlb_req_q ? lsu_addr_w : fetch_in_pc_i;
+    wire        vm_i_enable_w  = vm_enable_w & ifetch_vm_w;
+    wire        vm_d_enable_w  = vm_enable_w & dfetch_vm_w;
+
+    wire        itlb_miss_w    = fetch_in_rd_i & vm_i_enable_w & ~itlb_hit_w;
+    wire        dtlb_miss_w    = (load_w || (|store_w)) & vm_d_enable_w & ~dtlb_hit_w;
 
     reg [31:0]  pte_addr_q;
     reg [31:0]  pte_entry_q;
     reg [31:0]  virt_addr_q;
 
-    wire [31:0] pte_ppn_w   = {`PAGE_PFN_SHIFT'b0, resp_data_w[31:`PAGE_PFN_SHIFT]};
-    wire [9:0]  pte_flags_w = resp_data_w[9:0];
-
-    always @ (posedge clk_i or posedge rst_i)
-    if (rst_i)
-    begin
-        pte_addr_q  <= 32'b0;
-        pte_entry_q <= 32'b0;
-        virt_addr_q <= 32'b0;
-        dtlb_req_q  <= 1'b0;
-        state_q     <= STATE_IDLE;
+    // Use live address ONLY at STATE_IDLE; during walk ALWAYS use latched virt_addr_q!
+    wire [31:0] idle_req_addr_w = dtlb_miss_w ? lsu_addr_w : fetch_in_pc_i;
+
+    wire [31:0] pte_ppn_w       = {`PAGE_PFN_SHIFT'b0, resp_data_w[31:`PAGE_PFN_SHIFT]};
+    wire [9:0]  pte_flags_w     = resp_data_w[9:0];
+
+    wire        pte_v_w         = resp_data_w[`PAGE_PRESENT];
+    wire        pte_r_w         = resp_data_w[`PAGE_READ];
+    wire        pte_w_w         = resp_data_w[`PAGE_WRITE];
+    wire        pte_x_w         = resp_data_w[`PAGE_EXEC];
+    wire        pte_rwx_any_w   = pte_r_w | pte_w_w | pte_x_w;
+    wire        pte_rsvd_rw_w   = (~pte_r_w) & pte_w_w;
+    wire        superpage_misaligned_w = (resp_data_w[19:10] != 10'b0);
+
+    always @ (posedge clk_i or posedge rst_i)
+    if (rst_i)
+    begin
+        pte_addr_q     <= 32'b0;
+        pte_entry_q    <= 32'b0;
+        virt_addr_q    <= 32'b0;
+        dtlb_req_q     <= 1'b0;
+        walk_flushed_q <= 1'b0;
+        state_q        <= STATE_IDLE;
     end
     else
     begin
-        // TLB miss, walk page table
-        if (state_q == STATE_IDLE && (itlb_miss_w || dtlb_miss_w))
-        begin
-            pte_addr_q  <= ptbr_w + {20'b0, request_addr_w[31:22], 2'b0};
-            virt_addr_q <= request_addr_w;
-            dtlb_req_q  <= dtlb_miss_w;
-
-            state_q     <= STATE_LEVEL_FIRST;
-        end
-        // First level (4MB superpage)
+        if (flush_i && state_q != STATE_IDLE)
+            walk_flushed_q <= 1'b1;
+
+        if (state_q == STATE_IDLE && (itlb_miss_w || dtlb_miss_w) && !flush_i)
+        begin
+            pte_addr_q     <= ptbr_w + {20'b0, idle_req_addr_w[31:22], 2'b0};
+            virt_addr_q    <= idle_req_addr_w;
+            dtlb_req_q     <= dtlb_miss_w;
+            walk_flushed_q <= 1'b0;
+            state_q        <= STATE_LEVEL_FIRST;
+        end
         else if (state_q == STATE_LEVEL_FIRST && resp_valid_w)
         begin
-            // Error or page not present
-            if (resp_error_w || !resp_data_w[`PAGE_PRESENT])
+            // Error, V=0, or reserved R=0 & W=1 encoding -> fault
+            if (resp_error_w || !pte_v_w || pte_rsvd_rw_w)
             begin
                 pte_entry_q <= 32'b0;
                 state_q     <= STATE_UPDATE;
             end
-            // Valid entry, but another level to fetch
-            else if (!(resp_data_w[`PAGE_READ] || resp_data_w[`PAGE_WRITE] || resp_data_w[`PAGE_EXEC]))
-            begin
-                pte_addr_q  <= {resp_data_w[29:10], 12'b0} + {20'b0, request_addr_w[21:12], 2'b0};
-                state_q     <= STATE_LEVEL_SECOND;
-            end
-            // Valid entry, actual valid PTE
+            // Pointer to second-level page table (R=0, W=0, X=0)
+            else if (!pte_rwx_any_w)
+            begin
+                if (flush_i || walk_flushed_q)
+                begin
+                    pte_entry_q <= 32'b0;
+                    state_q     <= STATE_UPDATE;
+                end
+                else
+                begin
+                    pte_addr_q  <= {resp_data_w[29:10], 12'b0} + {20'b0, virt_addr_q[21:12], 2'b0};
+                    state_q     <= STATE_LEVEL_SECOND;
+                end
+            end
+            // Level-1 4 MiB superpage leaf: enforce PPN[0] == 0 alignment!
+            else if (superpage_misaligned_w)
+            begin
+                pte_entry_q <= 32'b0;
+                state_q     <= STATE_UPDATE;
+            end
             else
             begin
-                pte_entry_q <= ((pte_ppn_w | {22'b0, request_addr_w[21:12]}) << `MMU_PGSHIFT) | {22'b0, pte_flags_w};
+                pte_entry_q <= ((pte_ppn_w | {22'b0, virt_addr_q[21:12]}) << `MMU_PGSHIFT) | {22'b0, pte_flags_w};
                 state_q     <= STATE_UPDATE;
             end
         end
-        // Second level (4KB page)
         else if (state_q == STATE_LEVEL_SECOND && resp_valid_w)
         begin
-            // Valid entry, final level
-            if (resp_data_w[`PAGE_PRESENT])
+            // Level-2 4 KiB leaf: must have !resp_error_w, V=1, leaf (R|W|X)!=0, and !(W & !R)
+            if (!resp_error_w && pte_v_w && pte_rwx_any_w && !pte_rsvd_rw_w)
             begin
                 pte_entry_q <= (pte_ppn_w << `MMU_PGSHIFT) | {22'b0, pte_flags_w};
                 state_q     <= STATE_UPDATE;
             end
-            // Page fault
             else
             begin
                 pte_entry_q <= 32'b0;
@@ -261,7 +295,8 @@
         end
         else if (state_q == STATE_UPDATE)
         begin
-            state_q    <= STATE_IDLE;
+            walk_flushed_q <= 1'b0;
+            state_q        <= STATE_IDLE;
         end
     end
 
@@ -271,6 +306,7 @@
     reg         itlb_valid_q;
     reg [31:12] itlb_va_addr_q;
     reg [31:0]  itlb_entry_q;
+    reg         pc_fault_q;
 
     always @ (posedge clk_i or posedge rst_i)
     if (rst_i)
@@ -278,7 +314,7 @@
     else if (flush_i)
         itlb_valid_q <= 1'b0;
     else if (state_q == STATE_UPDATE && !dtlb_req_q)
-        itlb_valid_q <= (itlb_va_addr_q == fetch_in_pc_i[31:12]); // Fetch TLB still matches incoming request
+        itlb_valid_q <= ~walk_flushed_q;
     else if (state_q != STATE_IDLE && !dtlb_req_q)
         itlb_valid_q <= 1'b0;
 
@@ -288,52 +324,55 @@
         itlb_va_addr_q <= 20'b0;
         itlb_entry_q   <= 32'b0;
     end
-    else if (state_q == STATE_UPDATE && !dtlb_req_q)
+    else if (state_q == STATE_UPDATE && !dtlb_req_q && !walk_flushed_q && !flush_i)
     begin
         itlb_va_addr_q <= virt_addr_q[31:12];
         itlb_entry_q   <= pte_entry_q;
     end
 
-    // TLB address matched (even on page fault)
-    assign itlb_hit_w   = fetch_in_rd_i & itlb_valid_q & (itlb_va_addr_q == fetch_in_pc_i[31:12]);
-
-    reg pc_fault_r;
+    assign itlb_hit_w = fetch_in_rd_i & itlb_valid_q & (itlb_va_addr_q == fetch_in_pc_i[31:12]);
+
+    reg pc_fault_raw_r;
     always @ *
     begin
-        pc_fault_r = 1'b0;
+        pc_fault_raw_r = 1'b0;
 
         if (vm_i_enable_w && itlb_hit_w)
         begin
-            // Supervisor mode
-            if (supervisor_i_w)
-            begin
-                // User page, supervisor cannot execute
+            if (!itlb_entry_q[`PAGE_PRESENT] || !itlb_entry_q[`PAGE_ACCESSED] ||
+                (!itlb_entry_q[`PAGE_READ] && itlb_entry_q[`PAGE_WRITE]))
+                pc_fault_raw_r = 1'b1;
+            else if (supervisor_i_w)
+            begin
                 if (itlb_entry_q[`PAGE_USER])
-                    pc_fault_r = 1'b1;
-                // Check exec permissions
+                    pc_fault_raw_r = 1'b1;
                 else
-                    pc_fault_r = ~itlb_entry_q[`PAGE_EXEC];
-            end
-            // User mode
+                    pc_fault_raw_r = ~itlb_entry_q[`PAGE_EXEC];
+            end
             else
-                pc_fault_r = (~itlb_entry_q[`PAGE_EXEC]) | (~itlb_entry_q[`PAGE_USER]);
-        end
-    end
-
-    reg pc_fault_q;
-
-    always @ (posedge clk_i or posedge rst_i)
-    if (rst_i)
+                pc_fault_raw_r = (~itlb_entry_q[`PAGE_EXEC]) | (~itlb_entry_q[`PAGE_USER]);
+        end
+    end
+
+    // Accept an I-side fault ONLY when no older downstream I-cache read is still pending!
+    wire pc_fault_accept_w = pc_fault_raw_r && (icache_pend_q == 3'd0) && !pc_fault_q && !fetch_in_flush_i;
+
+    always @ (posedge clk_i or posedge rst_i)
+    if (rst_i)
+        pc_fault_q <= 1'b0;
+    else if (fetch_in_flush_i)
         pc_fault_q <= 1'b0;
     else
-        pc_fault_q <= pc_fault_r;
-
-    assign fetch_out_rd_o         = (~vm_i_enable_w & fetch_in_rd_i) || (itlb_hit_w & ~pc_fault_r);
+        pc_fault_q <= pc_fault_accept_w;
+
+    assign fetch_out_rd_o         = ~pc_fault_q && ((~vm_i_enable_w & fetch_in_rd_i) || (vm_i_enable_w & itlb_hit_w & ~pc_fault_raw_r));
     assign fetch_out_pc_o         = vm_i_enable_w ? {itlb_entry_q[31:12], fetch_in_pc_i[11:0]} : fetch_in_pc_i;
     assign fetch_out_flush_o      = fetch_in_flush_i;
-    assign fetch_out_invalidate_o = fetch_in_invalidate_i; // TODO: ...
-
-    assign fetch_in_accept_o      = (~vm_i_enable_w & fetch_out_accept_i) | (vm_i_enable_w & itlb_hit_w & fetch_out_accept_i) | pc_fault_r;
+    assign fetch_out_invalidate_o = fetch_in_invalidate_i;
+
+    assign fetch_in_accept_o      = (~pc_fault_q & ~vm_i_enable_w & fetch_out_accept_i) |
+                                    (~pc_fault_q & vm_i_enable_w & itlb_hit_w & ~pc_fault_raw_r & fetch_out_accept_i) |
+                                    pc_fault_accept_w;
     assign fetch_in_valid_o       = fetch_out_valid_i | pc_fault_q;
     assign fetch_in_error_o       = fetch_out_valid_i & fetch_out_error_i;
     assign fetch_in_fault_o       = pc_fault_q;
@@ -345,6 +384,8 @@
     reg         dtlb_valid_q;
     reg [31:12] dtlb_va_addr_q;
     reg [31:0]  dtlb_entry_q;
+    reg         store_fault_q;
+    reg         load_fault_q;
 
     always @ (posedge clk_i or posedge rst_i)
     if (rst_i)
@@ -352,7 +393,7 @@
     else if (flush_i)
         dtlb_valid_q <= 1'b0;
     else if (state_q == STATE_UPDATE && dtlb_req_q)
-        dtlb_valid_q <= 1'b1;
+        dtlb_valid_q <= ~walk_flushed_q;
 
     always @ (posedge clk_i or posedge rst_i)
     if (rst_i)
@@ -360,90 +401,91 @@
         dtlb_va_addr_q <= 20'b0;
         dtlb_entry_q   <= 32'b0;
     end
-    else if (state_q == STATE_UPDATE && dtlb_req_q)
+    else if (state_q == STATE_UPDATE && dtlb_req_q && !walk_flushed_q && !flush_i)
     begin
         dtlb_va_addr_q <= virt_addr_q[31:12];
         dtlb_entry_q   <= pte_entry_q;
     end
 
-    // TLB address matched (even on page fault)
-    assign dtlb_hit_w   = dtlb_valid_q & (dtlb_va_addr_q == lsu_addr_w[31:12]);
-
-    reg load_fault_r;
+    assign dtlb_hit_w = dtlb_valid_q & (dtlb_va_addr_q == lsu_addr_w[31:12]);
+
+    reg load_fault_raw_r;
     always @ *
     begin
-        load_fault_r = 1'b0;
+        load_fault_raw_r = 1'b0;
 
         if (vm_d_enable_w && load_w && dtlb_hit_w)
         begin
-            // Supervisor mode
-            if (supervisor_d_w)
-            begin
-                // User page, supervisor user mode not enabled
+            if (!dtlb_entry_q[`PAGE_PRESENT] || !dtlb_entry_q[`PAGE_ACCESSED] ||
+                (!dtlb_entry_q[`PAGE_READ] && dtlb_entry_q[`PAGE_WRITE]))
+                load_fault_raw_r = 1'b1;
+            else if (supervisor_d_w)
+            begin
                 if (dtlb_entry_q[`PAGE_USER] && !sum_i)
-                    load_fault_r = 1'b1;
-                // Check exec permissions
+                    load_fault_raw_r = 1'b1;
                 else
-                    load_fault_r = ~(dtlb_entry_q[`PAGE_READ] | (mxr_i & dtlb_entry_q[`PAGE_EXEC]));
-            end
-            // User mode
+                    load_fault_raw_r = ~(dtlb_entry_q[`PAGE_READ] | (mxr_i & dtlb_entry_q[`PAGE_EXEC]));
+            end
             else
-                load_fault_r = (~dtlb_entry_q[`PAGE_READ]) | (~dtlb_entry_q[`PAGE_USER]);
-        end
-    end
-
-    reg store_fault_r;
+                load_fault_raw_r = (~(dtlb_entry_q[`PAGE_READ] | (mxr_i & dtlb_entry_q[`PAGE_EXEC]))) | (~dtlb_entry_q[`PAGE_USER]);
+        end
+    end
+
+    reg store_fault_raw_r;
     always @ *
     begin
-        store_fault_r = 1'b0;
+        store_fault_raw_r = 1'b0;
 
         if (vm_d_enable_w && (|store_w) && dtlb_hit_w)
         begin
-            // Supervisor mode
-            if (supervisor_d_w)
-            begin
-                // User page, supervisor user mode not enabled
+            if (!dtlb_entry_q[`PAGE_PRESENT] || !dtlb_entry_q[`PAGE_ACCESSED] || !dtlb_entry_q[`PAGE_DIRTY] ||
+                (!dtlb_entry_q[`PAGE_READ] && dtlb_entry_q[`PAGE_WRITE]))
+                store_fault_raw_r = 1'b1;
+            else if (supervisor_d_w)
+            begin
                 if (dtlb_entry_q[`PAGE_USER] && !sum_i)
-                    store_fault_r = 1'b1;
-                // Check exec permissions
+                    store_fault_raw_r = 1'b1;
                 else
-                    store_fault_r = (~dtlb_entry_q[`PAGE_READ]) | (~dtlb_entry_q[`PAGE_WRITE]);
-            end
-            // User mode
+                    store_fault_raw_r = (~dtlb_entry_q[`PAGE_READ]) | (~dtlb_entry_q[`PAGE_WRITE]);
+            end
             else
-                store_fault_r = (~dtlb_entry_q[`PAGE_READ]) | (~dtlb_entry_q[`PAGE_WRITE]) | (~dtlb_entry_q[`PAGE_USER]);
-        end
-    end
-
-    reg store_fault_q;
-    reg load_fault_q;
+                store_fault_raw_r = (~dtlb_entry_q[`PAGE_READ]) | (~dtlb_entry_q[`PAGE_WRITE]) | (~dtlb_entry_q[`PAGE_USER]);
+        end
+    end
+
+    wire d_fault_busy_w    = (dcache_pend_q != 3'd0) || load_fault_q || store_fault_q;
+    wire load_fault_acc_w  = load_fault_raw_r  && !d_fault_busy_w;
+    wire store_fault_acc_w = store_fault_raw_r && !d_fault_busy_w;
 
     always @ (posedge clk_i or posedge rst_i)
     if (rst_i)
         store_fault_q <= 1'b0;
     else
-        store_fault_q <= store_fault_r;
+        store_fault_q <= store_fault_acc_w;
 
     always @ (posedge clk_i or posedge rst_i)
     if (rst_i)
         load_fault_q <= 1'b0;
     else
-        load_fault_q <= load_fault_r;   
-
-    wire        lsu_out_rd_w         = vm_d_enable_w ? (load_w  & dtlb_hit_w & ~load_fault_r)       : lsu_in_rd_i;
-    wire [3:0]  lsu_out_wr_w         = vm_d_enable_w ? (store_w & {4{dtlb_hit_w & ~store_fault_r}}) : lsu_in_wr_i;
-    wire [31:0] lsu_out_addr_w       = vm_d_enable_w ? {dtlb_entry_q[31:12], lsu_addr_w[11:0]}      : lsu_addr_w;
-    wire [31:0] lsu_out_data_wr_w    = lsu_in_data_wr_i;
-
-    wire        lsu_out_invalidate_w = lsu_in_invalidate_i;
-    wire        lsu_out_writeback_w  = lsu_in_writeback_i;
+        load_fault_q <= load_fault_acc_w;
+
+    wire        d_fault_active_q     = load_fault_q | store_fault_q;
+    wire        d_maint_w            = lsu_inv_w | lsu_wb_w | lsu_flush_w;
+    wire        lsu_out_rd_w         = ~d_fault_active_q & (vm_d_enable_w ? (load_w  & dtlb_hit_w & ~load_fault_raw_r)         : load_w);
+    wire [3:0]  lsu_out_wr_w         = d_fault_active_q  ? 4'b0 : (vm_d_enable_w ? (store_w & {4{dtlb_hit_w & ~store_fault_raw_r}}) : store_w);
+    wire [31:0] lsu_out_addr_w       = (vm_d_enable_w && !d_maint_w) ? {dtlb_entry_q[31:12], lsu_addr_w[11:0]} : lsu_addr_w;
+    wire [31:0] lsu_out_data_wr_w    = lsu_wdata_w;
+
+    wire        lsu_out_invalidate_w = ~d_fault_active_q & lsu_inv_w;
+    wire        lsu_out_writeback_w  = ~d_fault_active_q & lsu_wb_w;
+    wire        lsu_out_flush_w      = ~d_fault_active_q & lsu_flush_w;
 
     reg         lsu_out_cacheable_r;
     always @ *
     begin
 /* verilator lint_off UNSIGNED */
 /* verilator lint_off CMPCONST */
-        if (lsu_in_invalidate_i || lsu_in_writeback_i || lsu_in_flush_i)
+        if (lsu_inv_w || lsu_wb_w || lsu_flush_w)
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/biriscv_csr.v`](environment/public/code/biriscv_csr.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_defs.v`](environment/public/code/biriscv_defs.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_fetch.v`](environment/public/code/biriscv_fetch.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_lsu.v`](environment/public/code/biriscv_lsu.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_mmu.v`](environment/public/code/biriscv_mmu.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

