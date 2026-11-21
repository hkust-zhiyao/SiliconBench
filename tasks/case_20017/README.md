# `case_20017`: 16 KiB Two-Way Write-Back AXI4 D-Cache Hard-SRAM Mapping, Coherency & Multi-Corner Signoff

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_20017` |
| **Source Silicon Repository** | `ultraembedded/biriscv` (`repo_44`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Core_RISCV_Processors` (Core_RISCV_Processors) |
| **Multi-Domain Tags** | `Core_RISCV_Processors` |
| **Editable Files (`allowed_edits`)** | [`constraints/dcache.sdc`](environment/public/constraints/dcache.sdc), [`code/dcache_core.v`](environment/public/code/dcache_core.v), [`code/dcache_core_tag_ram.v`](environment/public/code/dcache_core_tag_ram.v), [`code/dcache_core_data_ram.v`](environment/public/code/dcache_core_data_ram.v), [`code/dcache_axi_axi.v`](environment/public/code/dcache_axi_axi.v) (5 files, 1322 LOC) |
| **Public Subsystem Context** | 13 RTL files (2854 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# 16 KiB Two-Way Write-Back AXI4 D-Cache Hard-SRAM Mapping, Coherency & Multi-Corner Signoff

## Overview
`code/dcache.v` (`AXI_ID = 0`) integrates the `biriscv` 16 KiB, 2-way set-associative, 32-byte-line (256-set) write-back data cache subsystem across cached/uncached request multiplexing, cache lookup/refill/eviction control, and 32-bit AXI4 master burst bridging. In the baseline RTL and starter `constraints/dcache.sdc`, Tag and Data arrays are modeled as behavioral dual-port register memories, cached replacement and AXI4 write-eviction handshaking exhibit coherency/protocol defects under realistic traffic and channel backpressure, and the design fails `8.00 ns` (`~125.0 MHz`) multi-corner (`SS` / `TT` / `FF`) timing signoff on IHP SG13G2.

## Architectural, Hard-SRAM & Multi-Corner Signoff Contract

1. **Single-Port (1RW) Hard-SRAM Mapping (`10` `RM_IHPSG13_1P_256x64_c2_bm_bist` Macros)**:
   - Map Tag storage to **1** `RM_IHPSG13_1P_256x64_c2_bm_bist` macro per way (`2` tag macros) and 8 KiB/way Data storage to **4** `RM_IHPSG13_1P_256x64_c2_bm_bist` macros per way (`8` data macros, yielding **exactly `10`** hard SRAM macros in synthesized `dcache`, with `A_DLY = 1'b1` and `A_BIST_*` ports tied `0`).
   - Each `RM_IHPSG13_1P_256x64_c2_bm_bist` is a true synchronous single-port (1RW) macro (`A_WEN` and `A_REN` mutually exclusive when `A_MEN = 1'b1`), using `A_BM` bit-masking for byte-granular writes (`mem_wr_i[3:0]`). Synthesized `dcache` must infer zero latches and match RTL behavior in gate-level simulation.

2. **Write-Back Coherency, Set-Associative LRU Replacement & AXI4 Protocol**:
   - Preserve the top-level `dcache` request/response (`mem_accept_o`, `mem_ack_o`, `mem_data_rd_o`, `mem_resp_tag_o`, `mem_error_o`) and AXI4 master (`len = 7` `INCR` 8-beat cache-line refills/writebacks; `len = 0` single-beat uncached `mem_cacheable_i = 0` reads/writes) contracts under arbitrary independent backpressure on `axi_awready_i`, `axi_wready_i`, `axi_arready_i`, `axi_rvalid_i`, and `axi_bvalid_i` (including staggered `AW` vs `W` readiness on burst Beat 0).
   - Clear all 256 tag sets after `rst_i` before accepting requests. For each set (`mem_addr_i[12:5]`), miss allocation must fill any invalid way before evicting a valid way, and when both ways are valid, evict the least-recently-used (LRU) way updated on cached read/write hits and miss allocations.
   - Support byte-masked cached writes, dirty victim writeback prior to refill, address-targeted `mem_writeback_i` (write back a matching dirty line to AXI4 and mark it clean while retaining validity), address-targeted `mem_invalidate_i` (invalidate a matching line without writeback), and full-cache `mem_flush_i` (write back every dirty line across both ways and invalidate all 256 sets).

3. **Native Signoff Constraints (`constraints/dcache.sdc`) & Three-Corner (`SS` / `TT` / `FF`) STA**:
   - Define `clk_i` on port `clk_i` with `-period 8.00`, `-setup` uncertainty `>= 0.15` ns, `-hold` uncertainty `>= 0.08` ns, and clock transition `>= 0.10` ns. Mark `rst_i` as an asynchronous false path (`set_false_path -from [get_ports rst_i]`), excluded from `set_input_delay`.
   - Constrain **every** synchronous input port with `set_driving_cell -lib_cell sg13g2_buf_4 -pin X`, `set_input_delay -clock clk_i -max >= 1.80`, and `-min <= 0.20`; constrain **every** output port (`[all_outputs]`) with `set_output_delay -clock clk_i -max >= 1.80`, `-min <= 0.05`, and `set_load >= 0.025`.
   - Model pre-CTS early macro clock arrival on **only** the `10` hard SRAM `A_CLK` pins (`[get_pins -hierarchical */A_CLK]`) with `set_clock_latency` in `[-0.42, -0.38]` ns, set `set_max_fanout <= 16` and `set_max_transition <= 0.40` on `[current_design]`, and use no `set_multicycle_path`, `set_disable_timing`, `set_case_analysis`, `set_ideal_network`, `set_max_delay`, `set_min_delay`, or `-to`/`-through` false paths (`0` unconstrained endpoints).
   - Following Yosys synthesis (`BUILD.md`) and OpenROAD buffering (`slow_1p08V_125C` `Metal3`/`Metal4` wire RC + `estimate_parasitics -placement` + `repair_design -cap_margin 20 -slew_margin 20` + `repair_timing -setup`, followed by `fast_1p32V_m40C` `repair_timing -hold -hold_margin 0.02`), all three corners (`slow_1p08V_125C`, `typ_1p20V_25C`, `fast_1p32V_m40C` + `RM_IHPSG13_1P_256x64_c2_bm_bist.lib`) must achieve `setup WNS >= 0.0 ns`, `setup TNS == 0.0 ns`, `hold WNS >= 0.0 ns`, and `hold TNS == 0.0 ns`.
   - Editable files: `constraints/dcache.sdc`, `code/dcache_core.v`, `code/dcache_core_tag_ram.v`, `code/dcache_core_data_ram.v`, and `code/dcache_axi_axi.v`. Preserve module names and port signatures; all other files in `code/` and `lib/` are read-only.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Synthesis, Buffering & Multi-Corner STA Reference

## Editable Files
- `constraints/dcache.sdc`
- `code/dcache_core.v`
- `code/dcache_core_tag_ram.v`
- `code/dcache_core_data_ram.v`
- `code/dcache_axi_axi.v`

All other files in `code/` and `lib/` are read-only.

## Reference Signoff Commands
- **Yosys Synthesis (`build/dcache_mapped.v` + `build/dcache_gl.v`)**:
  ```bash
  mkdir -p build
  yosys -p "
    read_verilog lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v \
      code/dcache_core_tag_ram.v code/dcache_core_data_ram.v code/dcache_core.v \
      code/dcache_if_pmem.v code/dcache_mux.v code/dcache_pmem_mux.v \
      code/dcache_axi_axi.v code/dcache_axi.v code/dcache.v;
    hierarchy -check -top dcache; proc; opt; check -assert;
    select -assert-none t:\$dlatch*;
    synth -top dcache -flatten;
    design -save flat_generic; rename dcache dcache_gl; opt_clean;
    write_verilog -noattr build/dcache_gl.v;
    design -load flat_generic;
    dfflibmap -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    abc -D 2500 -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO;
    setundef -zero; splitnets -ports; opt_clean -purge;
    write_verilog -noattr -noexpr build/dcache_mapped.v"
  ```
- **OpenROAD Buffering (`SS 1.08V 125C`: `Metal3` signal / `Metal4` clock wire RC, `estimate_parasitics -placement`, `repair_design -cap_margin 20 -slew_margin 20`, `repair_timing -setup`; followed by `FF 1.32V -40C`: `repair_timing -hold -hold_margin 0.02`) & 3-Corner (`SS` / `TT` / `FF`) STA**:
  `openroad`
- **Verilator Simulation (with `lib/SRAM_1P_behavioral_bm_bist.v` + `lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v`, `-DFUNCTIONAL`)**:
  `verilator`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/constraints/dcache.sdc (Buggy Starter)
+++ b/solution/gold/constraints/dcache.sdc (Golden Reference)
@@ -1,7 +1,25 @@
-# Starter SDC for dcache (incomplete — fails hard-SRAM 3-corner signoff)
-create_clock -name clk_i -period 12.00 [get_ports clk_i]
+create_clock -name clk_i -period 8.00 [get_ports clk_i]
+set_clock_uncertainty -setup 0.15 [get_clocks clk_i]
+set_clock_uncertainty -hold  0.08 [get_clocks clk_i]
+set_clock_transition  0.10 [get_clocks clk_i]
 
-# Missing setup/hold uncertainty, clock transition, min I/O delays, driving cell, output load, and macro A_CLK latency
-set_input_delay  -clock clk_i -max 1.80 [all_inputs]
-set_output_delay -clock clk_i -max 1.80 [all_outputs]
+set async_p [get_ports {clk_i rst_i}]
+set sync_in {}
+foreach p [all_inputs] {
+  if {[lsearch -exact $async_p $p] == -1} {
+    lappend sync_in $p
+  }
+}
+set sync_out [all_outputs]
+
+set_driving_cell -lib_cell sg13g2_buf_4 -pin X $sync_in
+set_input_delay  -clock clk_i -max 1.80 $sync_in
+set_input_delay  -clock clk_i -min 0.20 $sync_in
+set_output_delay -clock clk_i -max 1.80 $sync_out
+set_output_delay -clock clk_i -min 0.05 $sync_out
+set_load 0.025 $sync_out
+
+set_clock_latency -0.40 [get_pins -hierarchical */A_CLK]
 set_false_path -from [get_ports rst_i]
+set_max_fanout 16 [current_design]
+set_max_transition 0.40 [current_design]

--- a/environment/public/code/dcache_core.v (Buggy Starter)
+++ b/solution/gold/code/dcache_core.v (Golden Reference)
@@ -1,31 +1,5 @@
-//-----------------------------------------------------------------
-//                         biRISC-V CPU
-//                            V0.6.0
-//                     Ultra-Embedded.com
-//                     Copyright 2019-2020
-//
-//                   admin@ultra-embedded.com
-//
-//                     License: Apache 2.0
-//-----------------------------------------------------------------
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
 module dcache_core
 (
-    // Inputs
      input           clk_i
     ,input           rst_i
     ,input  [ 31:0]  mem_addr_i
@@ -42,7 +16,6 @@
     ,input           outport_error_i
     ,input  [ 31:0]  outport_read_data_i
 
-    // Outputs
     ,output [ 31:0]  mem_data_rd_o
     ,output          mem_accept_o
     ,output          mem_ack_o
@@ -55,915 +28,375 @@
     ,output [ 31:0]  outport_write_data_o
 );
 
-
-
-//-----------------------------------------------------------------
-// This cache instance is 2 way set associative.
-// The total size is 16KB.
-// The replacement policy is a limited pseudo random scheme
-// (between lines, toggling on line thrashing).
-// The cache is a write back cache, with allocate on read and write.
-//-----------------------------------------------------------------
-// Number of ways
-localparam DCACHE_NUM_WAYS           = 2;
-
-// Number of cache lines
-localparam DCACHE_NUM_LINES          = 256;
-localparam DCACHE_LINE_ADDR_W        = 8;
-
-// Line size (e.g. 32-bytes)
-localparam DCACHE_LINE_SIZE_W        = 5;
-localparam DCACHE_LINE_SIZE          = 32;
-localparam DCACHE_LINE_WORDS         = 8;
-
-// Request -> tag address mapping
-localparam DCACHE_TAG_REQ_LINE_L     = 5;  // DCACHE_LINE_SIZE_W
-localparam DCACHE_TAG_REQ_LINE_H     = 12; // DCACHE_LINE_ADDR_W+DCACHE_LINE_SIZE_W-1
-localparam DCACHE_TAG_REQ_LINE_W     = 8;  // DCACHE_LINE_ADDR_W
-`define DCACHE_TAG_REQ_RNG          DCACHE_TAG_REQ_LINE_H:DCACHE_TAG_REQ_LINE_L
-
-// Tag fields
-`define CACHE_TAG_ADDR_RNG          18:0
-localparam CACHE_TAG_ADDR_BITS       = 19;
-localparam CACHE_TAG_DIRTY_BIT       = CACHE_TAG_ADDR_BITS + 0;
-localparam CACHE_TAG_VALID_BIT       = CACHE_TAG_ADDR_BITS + 1;
-localparam CACHE_TAG_DATA_W          = CACHE_TAG_ADDR_BITS + 2;
-
-// Tag compare bits
-localparam DCACHE_TAG_CMP_ADDR_L     = DCACHE_TAG_REQ_LINE_H + 1;
-localparam DCACHE_TAG_CMP_ADDR_H     = 32-1;
-localparam DCACHE_TAG_CMP_ADDR_W     = DCACHE_TAG_CMP_ADDR_H - DCACHE_TAG_CMP_ADDR_L + 1;
-`define   DCACHE_TAG_CMP_ADDR_RNG   31:13
-
-// Address mapping example:
-//  31          16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
-// |--------------|  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
-//  +--------------------+  +--------------------+   +------------+
-//  |  Tag address.      |  |   Line address     |      Address 
-//  |                    |  |                    |      within line
-//  |                    |  |                    |
-//  |                    |  |                    |- DCACHE_TAG_REQ_LINE_L
-//  |                    |  |- DCACHE_TAG_REQ_LINE_H
-//  |                    |- DCACHE_TAG_CMP_ADDR_L
-//  |- DCACHE_TAG_CMP_ADDR_H
-
-//-----------------------------------------------------------------
-// States
-//-----------------------------------------------------------------
-localparam STATE_W           = 4;
-localparam STATE_RESET       = 4'd0;
-localparam STATE_FLUSH_ADDR  = 4'd1;
-localparam STATE_FLUSH       = 4'd2;
-localparam STATE_LOOKUP      = 4'd3;
-localparam STATE_READ        = 4'd4;
-localparam STATE_WRITE       = 4'd5;
-localparam STATE_REFILL      = 4'd6;
-localparam STATE_EVICT       = 4'd7;
-localparam STATE_EVICT_WAIT  = 4'd8;
-localparam STATE_INVALIDATE  = 4'd9;
-localparam STATE_WRITEBACK   = 4'd10;
-
-// States
-reg [STATE_W-1:0]           next_state_r;
-reg [STATE_W-1:0]           state_q;
-
-//-----------------------------------------------------------------
-// Request buffer
-//-----------------------------------------------------------------
-reg [31:0] mem_addr_m_q;
-reg [31:0] mem_data_m_q;
-reg [3:0]  mem_wr_m_q;
-reg        mem_rd_m_q;
-reg [10:0] mem_tag_m_q;
-reg        mem_inval_m_q;
-reg        mem_writeback_m_q;
-reg        mem_flush_m_q;
-
-always @ (posedge clk_i or posedge rst_i)
-if (rst_i)
-begin
-    mem_addr_m_q      <= 32'b0;
-    mem_data_m_q      <= 32'b0;
-    mem_wr_m_q        <= 4'b0;
-    mem_rd_m_q        <= 1'b0;
-    mem_tag_m_q       <= 11'b0;
-    mem_inval_m_q     <= 1'b0;
-    mem_writeback_m_q <= 1'b0;
-    mem_flush_m_q     <= 1'b0;
-end
-else if (mem_accept_o)
-begin
-    mem_addr_m_q      <= mem_addr_i;
-    mem_data_m_q      <= mem_data_wr_i;
-    mem_wr_m_q        <= mem_wr_i;
-    mem_rd_m_q        <= mem_rd_i;
-    mem_tag_m_q       <= mem_req_tag_i;
-    mem_inval_m_q     <= mem_invalidate_i;
-    mem_writeback_m_q <= mem_writeback_i;
-    mem_flush_m_q     <= mem_flush_i;
-end
-else if (mem_ack_o)
-begin
-    mem_addr_m_q      <= 32'b0;
-    mem_data_m_q      <= 32'b0;
-    mem_wr_m_q        <= 4'b0;
-    mem_rd_m_q        <= 1'b0;
-    mem_tag_m_q       <= 11'b0;
-    mem_inval_m_q     <= 1'b0;
-    mem_writeback_m_q <= 1'b0;
-    mem_flush_m_q     <= 1'b0;
-end
-
-reg mem_accept_r;
-
-always @ *
-begin
-    mem_accept_r = 1'b0;
-
-    if (state_q == STATE_LOOKUP)
-    begin
-        // Previous access missed - do not accept new requests
-        if ((mem_rd_m_q || (mem_wr_m_q != 4'b0)) && !tag_hit_any_m_w)
-            mem_accept_r = 1'b0;
-        // Write followed by read - detect writes to the same line, or addresses which alias in tag lookups
-        else if ((|mem_wr_m_q) && mem_rd_i && mem_addr_i[31:2] == mem_addr_m_q[31:2])
-            mem_accept_r = 1'b0;
-        else
-            mem_accept_r = 1'b1;
+localparam S_RESET        = 4'd0;
+localparam S_IDLE         = 4'd1;
+localparam S_LOOKUP_REQ   = 4'd2;
+localparam S_LOOKUP_WAIT  = 4'd3;
+localparam S_CHECK        = 4'd4;
+localparam S_WRITE_COMMIT = 4'd5;
+localparam S_INVAL_COMMIT = 4'd6;
+localparam S_EVICT_READ   = 4'd7;
+localparam S_EVICT_SEND   = 4'd8;
+localparam S_EVICT_WAIT   = 4'd9;
+localparam S_REFILL       = 4'd10;
+localparam S_FLUSH_REQ    = 4'd11;
+localparam S_FLUSH_WAIT   = 4'd12;
+localparam S_FLUSH_CHECK  = 4'd13;
+
+reg [ 3:0] state_q;
+reg [31:0] req_addr_q;
+reg [31:0] req_wdata_q;
+reg [ 3:0] req_wr_q;
+reg        req_rd_q;
+reg [10:0] req_tag_q;
+reg        req_inval_q;
+reg        req_wb_q;
+reg        req_flush_q;
+
+reg [ 7:0] flush_addr_q;
+reg [255:0] lru_q;
+reg        sel_way_q;
+reg [18:0] evict_tag_q;
+reg [ 7:0] evict_idx_q;
+reg [ 3:0] rd_idx_q;
+reg [ 2:0] beat_q;
+reg [31:0] evict_buf_q [0:7];
+reg        pmem_rd_cmd_q;
+reg [31:0] refill_word_q;
+reg        err_acc_q;
+
+reg        ack_q;
+reg [31:0] rdata_q;
+reg [10:0] resp_tag_q;
+reg        err_q;
+
+wire       in_req_valid_w = mem_rd_i || (|mem_wr_i) || mem_invalidate_i || mem_writeback_i || mem_flush_i;
+wire [7:0] req_idx_w      = req_addr_q[12:5];
+wire [18:0] req_tag_cmp_w = req_addr_q[31:13];
+
+wire [20:0] tag0_out_w, tag1_out_w;
+wire [31:0] data0_out_w, data1_out_w;
+
+wire        tag0_val_w = tag0_out_w[20];
+wire        tag0_dit_w = tag0_out_w[19];
+wire [18:0] tag0_adr_w = tag0_out_w[18:0];
+wire        tag1_val_w = tag1_out_w[20];
+wire        tag1_dit_w = tag1_out_w[19];
+wire [18:0] tag1_adr_w = tag1_out_w[18:0];
+
+wire tag0_hit_w = tag0_val_w && (tag0_adr_w == req_tag_cmp_w);
+wire tag1_hit_w = tag1_val_w && (tag1_adr_w == req_tag_cmp_w);
+wire hit_any_w  = tag0_hit_w || tag1_hit_w;
+
+wire vic_way_w   = !tag0_val_w ? 1'b0 : (!tag1_val_w ? 1'b1 : lru_q[req_idx_w]);
+wire vic_dirty_w = vic_way_w ? (tag1_val_w && tag1_dit_w) : (tag0_val_w && tag0_dit_w);
+
+// Tag SRAM control
+wire [7:0] tag_raddr_w = (state_q == S_FLUSH_REQ || state_q == S_FLUSH_WAIT) ? flush_addr_q : req_idx_w;
+wire [7:0] tag_waddr_w = (state_q == S_RESET || req_flush_q) ? flush_addr_q : req_idx_w;
+
+reg        tag0_wr_r, tag1_wr_r;
+reg [20:0] tag_wdata_r;
+
+always @* begin
+    tag0_wr_r   = 1'b0;
+    tag1_wr_r   = 1'b0;
+    tag_wdata_r = 21'b0;
+    if (state_q == S_RESET) begin
+        tag0_wr_r   = 1'b1;
+        tag1_wr_r   = 1'b1;
+        tag_wdata_r = 21'b0;
+    end else if (state_q == S_WRITE_COMMIT) begin
+        tag0_wr_r   = ~sel_way_q;
+        tag1_wr_r   =  sel_way_q;
+        tag_wdata_r = {1'b1, 1'b1, req_tag_cmp_w};
+    end else if (state_q == S_INVAL_COMMIT) begin
+        tag0_wr_r   = ~sel_way_q;
+        tag1_wr_r   =  sel_way_q;
+        tag_wdata_r = 21'b0;
+    end else if (state_q == S_REFILL && outport_ack_i && (beat_q == 3'd7) && req_rd_q) begin
+        tag0_wr_r   = ~sel_way_q;
+        tag1_wr_r   =  sel_way_q;
+        tag_wdata_r = {1'b1, 1'b0, req_tag_cmp_w};
+    end else if (state_q == S_EVICT_WAIT && outport_ack_i) begin
+        tag0_wr_r   = ~sel_way_q;
+        tag1_wr_r   =  sel_way_q;
+        tag_wdata_r = req_wb_q ? {1'b1, 1'b0, req_tag_cmp_w} : 21'b0;
+    end else if (state_q == S_FLUSH_CHECK && !(tag0_val_w && tag0_dit_w) && !(tag1_val_w && tag1_dit_w)) begin
+        tag0_wr_r   = 1'b1;
+        tag1_wr_r   = 1'b1;
+        tag_wdata_r = 21'b0;
     end
 end
 
-assign mem_accept_o = mem_accept_r;
-
-// Tag comparison address
-wire [DCACHE_TAG_CMP_ADDR_W-1:0] req_addr_tag_cmp_m_w = mem_addr_m_q[`DCACHE_TAG_CMP_ADDR_RNG];
-
-assign mem_resp_tag_o = mem_tag_m_q;
-
-//-----------------------------------------------------------------
-// Registers / Wires
-//-----------------------------------------------------------------
-reg [0:0]  replace_way_q;
-
-wire  [  3:0]  pmem_wr_w;
-wire           pmem_rd_w;
-wire  [  7:0]  pmem_len_w;
-wire           pmem_last_w;
-wire  [ 31:0]  pmem_addr_w;
-wire  [ 31:0]  pmem_write_data_w;
-wire           pmem_accept_w;
-wire           pmem_ack_w;
-wire           pmem_error_w;
-wire [ 31:0]   pmem_read_data_w;
-
-wire           evict_way_w;
-wire           tag_dirty_any_m_w;
-wire           tag_hit_and_dirty_m_w;
-
-reg            flushing_q;
-
-//-----------------------------------------------------------------
-// TAG RAMS
-//-----------------------------------------------------------------
-reg [DCACHE_TAG_REQ_LINE_W-1:0] tag_addr_x_r;
-reg [DCACHE_TAG_REQ_LINE_W-1:0] tag_addr_m_r;
-
-// Tag RAM address
-always @ *
-begin
-    // Read Port
-    tag_addr_x_r = mem_addr_i[`DCACHE_TAG_REQ_RNG];
-
-    // Lookup
-    if (state_q == STATE_LOOKUP && (next_state_r == STATE_LOOKUP || next_state_r == STATE_WRITEBACK))
-        tag_addr_x_r = mem_addr_i[`DCACHE_TAG_REQ_RNG];
-    // Cache flush
-    else if (flushing_q)
-        tag_addr_x_r = flush_addr_q;
-    else
-        tag_addr_x_r = mem_addr_m_q[`DCACHE_TAG_REQ_RNG];        
-
-    // Write Port
-    tag_addr_m_r = flush_addr_q;
-
-    // Cache flush
-    if (flushing_q || state_q == STATE_RESET)
-        tag_addr_m_r = flush_addr_q;
-    // Line refill / write
-    else
-        tag_addr_m_r = mem_addr_m_q[`DCACHE_TAG_REQ_RNG];
-end
-
-// Tag RAM write data
-reg [CACHE_TAG_DATA_W-1:0] tag_data_in_m_r;
-always @ *
-begin
-    tag_data_in_m_r = {(CACHE_TAG_DATA_W){1'b0}};
-
-    // Cache flush
-    if (state_q == STATE_FLUSH || state_q == STATE_RESET || flushing_q)
-        tag_data_in_m_r = {(CACHE_TAG_DATA_W){1'b0}};
-    // Line refill
-    else if (state_q == STATE_REFILL)
-    begin
-        tag_data_in_m_r[CACHE_TAG_VALID_BIT] = 1'b1;
-        tag_data_in_m_r[CACHE_TAG_DIRTY_BIT] = 1'b0;
-        tag_data_in_m_r[`CACHE_TAG_ADDR_RNG] = mem_addr_m_q[`DCACHE_TAG_CMP_ADDR_RNG];
-    end
-    // Invalidate - mark entry (if matching line) not valid (even if dirty...)
-    else if (state_q == STATE_INVALIDATE)
-    begin
-        tag_data_in_m_r[CACHE_TAG_VALID_BIT] = 1'b0;
-        tag_data_in_m_r[CACHE_TAG_DIRTY_BIT] = 1'b0;
-        tag_data_in_m_r[`CACHE_TAG_ADDR_RNG] = mem_addr_m_q[`DCACHE_TAG_CMP_ADDR_RNG];
-    end
-    // Evict completion
-    else if (state_q == STATE_EVICT_WAIT)
-    begin
-        tag_data_in_m_r[CACHE_TAG_VALID_BIT] = 1'b1;
-        tag_data_in_m_r[CACHE_TAG_DIRTY_BIT] = 1'b0;
-        tag_data_in_m_r[`CACHE_TAG_ADDR_RNG] = mem_addr_m_q[`DCACHE_TAG_CMP_ADDR_RNG];
-    end
-    // Write - mark entry as dirty
-    else if (state_q == STATE_WRITE || (state_q == STATE_LOOKUP && (|mem_wr_m_q)))
-    begin
-        tag_data_in_m_r[CACHE_TAG_VALID_BIT] = 1'b1;
-        tag_data_in_m_r[CACHE_TAG_DIRTY_BIT] = 1'b1;
-        tag_data_in_m_r[`CACHE_TAG_ADDR_RNG] = mem_addr_m_q[`DCACHE_TAG_CMP_ADDR_RNG];
+dcache_core_tag_ram u_tag0 (
+    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
+    .addr0_i(tag_raddr_w), .data0_o(tag0_out_w),
+    .addr1_i(tag_waddr_w), .data1_i(tag_wdata_r), .wr1_i(tag0_wr_r)
+);
+
+dcache_core_tag_ram u_tag1 (
+    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
+    .addr0_i(tag_raddr_w), .data0_o(tag1_out_w),
+    .addr1_i(tag_waddr_w), .data1_i(tag_wdata_r), .wr1_i(tag1_wr_r)
+);
+
+// Data SRAM control
+wire [10:0] data_raddr_w = (state_q == S_EVICT_READ) ? {evict_idx_q, rd_idx_q[2:0]} : req_addr_q[12:2];
+wire [10:0] data_waddr_w = (state_q == S_REFILL)     ? {req_idx_w, beat_q}          : req_addr_q[12:2];
+wire [31:0] data_wdata_w = (state_q == S_REFILL)     ? outport_read_data_i          : req_wdata_q;
+wire [ 3:0] data0_wr_w   = (state_q == S_REFILL && outport_ack_i && !sel_way_q) ? 4'hF :
+                           (state_q == S_WRITE_COMMIT && !sel_way_q)            ? req_wr_q : 4'b0;
+wire [ 3:0] data1_wr_w   = (state_q == S_REFILL && outport_ack_i &&  sel_way_q) ? 4'hF :
+                           (state_q == S_WRITE_COMMIT &&  sel_way_q)            ? req_wr_q : 4'b0;
+
+dcache_core_data_ram u_data0 (
+    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
+    .addr0_i(data_raddr_w), .data0_i(32'b0), .wr0_i(4'b0), .data0_o(data0_out_w),
+    .addr1_i(data_waddr_w), .data1_i(data_wdata_w), .wr1_i(data0_wr_w), .data1_o()
+);
+
+dcache_core_data_ram u_data1 (
+    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
+    .addr0_i(data_raddr_w), .data0_i(32'b0), .wr0_i(4'b0), .data0_o(data1_out_w),
+    .addr1_i(data_waddr_w), .data1_i(data_wdata_w), .wr1_i(data1_wr_w), .data1_o()
+);
+integer k;
+always @(posedge clk_i or posedge rst_i) begin
+    if (rst_i) begin
+        state_q       <= S_RESET;
+        req_addr_q    <= 32'b0;
+        req_wdata_q   <= 32'b0;
+        req_wr_q      <= 4'b0;
+        req_rd_q      <= 1'b0;
+        req_tag_q     <= 11'b0;
+        req_inval_q   <= 1'b0;
+        req_wb_q      <= 1'b0;
+        req_flush_q   <= 1'b0;
+        flush_addr_q  <= 8'b0;
+        lru_q         <= 256'b0;
+        sel_way_q     <= 1'b0;
+        evict_tag_q   <= 19'b0;
+        evict_idx_q   <= 8'b0;
+        rd_idx_q      <= 4'b0;
+        beat_q        <= 3'b0;
+        for (k = 0; k < 8; k = k + 1)
+            evict_buf_q[k] <= 32'b0;
+        pmem_rd_cmd_q <= 1'b0;
+        refill_word_q <= 32'b0;
+        err_acc_q     <= 1'b0;
+        ack_q         <= 1'b0;
+        rdata_q       <= 32'b0;
+        resp_tag_q    <= 11'b0;
+        err_q         <= 1'b0;
+    end else begin
+        ack_q <= 1'b0;
+        case (state_q)
+            S_RESET: begin
+                if (flush_addr_q == 8'hFF) begin
+                    flush_addr_q <= 8'd0;
+                    state_q      <= S_IDLE;
+                end else begin
+                    flush_addr_q <= flush_addr_q + 8'd1;
+                end
+            end
+
+            S_IDLE: begin
+                if (in_req_valid_w) begin
+                    req_addr_q  <= mem_addr_i;
+                    req_wdata_q <= mem_data_wr_i;
+                    req_wr_q    <= mem_wr_i;
+                    req_rd_q    <= mem_rd_i;
+                    req_tag_q   <= mem_req_tag_i;
+                    req_inval_q <= mem_invalidate_i;
+                    req_wb_q    <= mem_writeback_i;
+                    req_flush_q <= mem_flush_i;
+                    err_acc_q   <= 1'b0;
+                    if (mem_flush_i) begin
+                        flush_addr_q <= 8'd0;
+                        state_q      <= S_FLUSH_REQ;
+                    end else begin
+                        state_q      <= S_LOOKUP_REQ;
+                    end
+                end
+            end
+
+            S_LOOKUP_REQ:  state_q <= S_LOOKUP_WAIT;
+            S_LOOKUP_WAIT: state_q <= S_CHECK;
+
+            S_CHECK: begin
+                if (req_inval_q) begin
+                    if (hit_any_w) begin
+                        sel_way_q <= tag1_hit_w;
+                        state_q   <= S_INVAL_COMMIT;
+                    end else begin
+                        ack_q      <= 1'b1;
+                        resp_tag_q <= req_tag_q;
+                        err_q      <= 1'b0;
+                        state_q    <= S_IDLE;
+                    end
+                end else if (req_wb_q) begin
+                    if ((tag0_hit_w && tag0_dit_w) || (tag1_hit_w && tag1_dit_w)) begin
+                        sel_way_q   <= tag1_hit_w;
+                        evict_tag_q <= req_tag_cmp_w;
+                        evict_idx_q <= req_idx_w;
+                        rd_idx_q    <= 4'd0;
+                        state_q     <= S_EVICT_READ;
+                    end else begin
+                        ack_q      <= 1'b1;
+                        resp_tag_q <= req_tag_q;
+                        err_q      <= 1'b0;
+                        state_q    <= S_IDLE;
+                    end
+                end else if (hit_any_w) begin
+                    if (req_rd_q) begin
+                        lru_q      <= tag1_hit_w ? (lru_q & ~(256'd1 << req_idx_w)) : (lru_q | (256'd1 << req_idx_w));
+                        rdata_q    <= tag1_hit_w ? data1_out_w : data0_out_w;
+                        resp_tag_q <= req_tag_q;
+                        err_q      <= 1'b0;
+                        ack_q      <= 1'b1;
+                        state_q    <= S_IDLE;
+                    end else begin
+                        sel_way_q  <= tag1_hit_w;
+                        state_q    <= S_WRITE_COMMIT;
+                    end
+                end else begin
+                    sel_way_q   <= vic_way_w;
+                    evict_tag_q <= vic_way_w ? tag1_adr_w : tag0_adr_w;
+                    evict_idx_q <= req_idx_w;
+                    if (vic_dirty_w) begin
+                        rd_idx_q <= 4'd0;
+                        state_q  <= S_EVICT_READ;
+                    end else begin
+                        pmem_rd_cmd_q <= 1'b1;
+                        beat_q        <= 3'd0;
+                        state_q       <= S_REFILL;
+                    end
+                end
+            end
+
+            S_WRITE_COMMIT: begin
+                lru_q      <= sel_way_q ? (lru_q & ~(256'd1 << req_idx_w)) : (lru_q | (256'd1 << req_idx_w));
+                resp_tag_q <= req_tag_q;
+                err_q      <= err_acc_q;
+                ack_q      <= 1'b1;
+                state_q    <= S_IDLE;
+            end
+
+            S_INVAL_COMMIT: begin
+                resp_tag_q <= req_tag_q;
+                err_q      <= 1'b0;
+                ack_q      <= 1'b1;
+                state_q    <= S_IDLE;
+            end
+
+            S_EVICT_READ: begin
+                if (rd_idx_q >= 4'd2)
+                    evict_buf_q[rd_idx_q[2:0] - 3'd2] <= sel_way_q ? data1_out_w : data0_out_w;
+                if (rd_idx_q == 4'd9) begin
+                    beat_q  <= 3'd0;
+                    state_q <= S_EVICT_SEND;
+                end else begin
+                    rd_idx_q <= rd_idx_q + 4'd1;
+                end
+            end
+
+            S_EVICT_SEND: begin
+                if (outport_accept_i) begin
+                    if (beat_q == 3'd7)
+                        state_q <= S_EVICT_WAIT;
+                    else
+                        beat_q  <= beat_q + 3'd1;
+                end
+            end
+
+            S_EVICT_WAIT: begin
+                if (outport_ack_i) begin
+                    if (outport_error_i)
+                        err_acc_q <= 1'b1;
+                    if (req_wb_q) begin
+                        resp_tag_q <= req_tag_q;
+                        err_q      <= err_acc_q | outport_error_i;
+                        ack_q      <= 1'b1;
+                        state_q    <= S_IDLE;
+                    end else if (req_flush_q) begin
+                        state_q    <= S_FLUSH_REQ;
+                    end else begin
+                        pmem_rd_cmd_q <= 1'b1;
+                        beat_q        <= 3'd0;
+                        state_q       <= S_REFILL;
+                    end
+                end
+            end
+
+            S_REFILL: begin
+                if (pmem_rd_cmd_q && outport_accept_i)
+                    pmem_rd_cmd_q <= 1'b0;
+                if (outport_ack_i) begin
+                    if (outport_error_i)
+                        err_acc_q <= 1'b1;
+                    if (beat_q == req_addr_q[4:2])
+                        refill_word_q <= outport_read_data_i;
+                    if (beat_q == 3'd7) begin
+                        if (req_rd_q) begin
+                            lru_q      <= sel_way_q ? (lru_q & ~(256'd1 << req_idx_w)) : (lru_q | (256'd1 << req_idx_w));
+                            rdata_q    <= (req_addr_q[4:2] == 3'd7) ? outport_read_data_i : refill_word_q;
+                            resp_tag_q <= req_tag_q;
+                            err_q      <= err_acc_q | outport_error_i;
+                            ack_q      <= 1'b1;
+                            state_q    <= S_IDLE;
+                        end else begin
+                            state_q    <= S_WRITE_COMMIT;
+                        end
+                    end else begin
+                        beat_q <= beat_q + 3'd1;
+                    end
+                end
+            end
+
+            S_FLUSH_REQ:  state_q <= S_FLUSH_WAIT;
+            S_FLUSH_WAIT: state_q <= S_FLUSH_CHECK;
+
+            S_FLUSH_CHECK: begin
+                if (tag0_val_w && tag0_dit_w) begin
+                    sel_way_q   <= 1'b0;
+                    evict_tag_q <= tag0_adr_w;
+                    evict_idx_q <= flush_addr_q;
+                    rd_idx_q    <= 4'd0;
+                    state_q     <= S_EVICT_READ;
+                end else if (tag1_val_w && tag1_dit_w) begin
+                    sel_way_q   <= 1'b1;
+                    evict_tag_q <= tag1_adr_w;
+                    evict_idx_q <= flush_addr_q;
+                    rd_idx_q    <= 4'd0;
+                    state_q     <= S_EVICT_READ;
+                end else if (flush_addr_q == 8'hFF) begin
+                    flush_addr_q <= 8'd0;
+                    resp_tag_q   <= req_tag_q;
+                    err_q        <= err_acc_q;
+                    ack_q        <= 1'b1;
+    
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/dcache.v`](environment/public/code/dcache.v) *(Read-Only Context)*
- [`environment/public/code/dcache_axi.v`](environment/public/code/dcache_axi.v) *(Read-Only Context)*
- [`environment/public/code/dcache_axi_axi.v`](environment/public/code/dcache_axi_axi.v) **(Editable)**
- [`environment/public/code/dcache_core.v`](environment/public/code/dcache_core.v) **(Editable)**
- [`environment/public/code/dcache_core_data_ram.v`](environment/public/code/dcache_core_data_ram.v) **(Editable)**
- [`environment/public/code/dcache_core_tag_ram.v`](environment/public/code/dcache_core_tag_ram.v) **(Editable)**
- [`environment/public/code/dcache_if_pmem.v`](environment/public/code/dcache_if_pmem.v) *(Read-Only Context)*
- [`environment/public/code/dcache_mux.v`](environment/public/code/dcache_mux.v) *(Read-Only Context)*
- [`environment/public/code/dcache_pmem_mux.v`](environment/public/code/dcache_pmem_mux.v) *(Read-Only Context)*
- [`environment/public/constraints/dcache.sdc`](environment/public/constraints/dcache.sdc) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lef`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lef) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lib`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lib) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v) *(Read-Only Context)*
- [`environment/public/lib/SRAM_1P_behavioral_bm_bist.v`](environment/public/lib/SRAM_1P_behavioral_bm_bist.v) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell.lef`](environment/public/lib/sg13g2_stdcell.lef) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell_fast_1p32V_m40C.lib`](environment/public/lib/sg13g2_stdcell_fast_1p32V_m40C.lib) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell_slow_1p08V_125C.lib`](environment/public/lib/sg13g2_stdcell_slow_1p08V_125C.lib) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell_typ_1p20V_25C.lib`](environment/public/lib/sg13g2_stdcell_typ_1p20V_25C.lib) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_tech.lef`](environment/public/lib/sg13g2_tech.lef) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

