# `case_23014`: Vortex 2-Bank Sectored Way-Folded GPU L1 Cache PLRU/AMO & 10-SRAM Macro PnR Co-Design

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23014` |
| **Source Silicon Repository** | `vortexgpgpu/vortex` (`repo_37`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/VX_cache_repl.sv`](environment/public/code/VX_cache_repl.sv), [`code/VX_cache_tags.sv`](environment/public/code/VX_cache_tags.sv), [`code/VX_cache_data.sv`](environment/public/code/VX_cache_data.sv), [`plan/macro_placement.json`](environment/public/plan/macro_placement.json), [`constraints/cache_subsys.sdc`](environment/public/constraints/cache_subsys.sdc) (5 files, 542 LOC) |
| **Public Subsystem Context** | 64 RTL files (16178 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1800s` total (`900s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Vortex 2-Bank Sectored Way-Folded GPU L1 Cache & 10-SRAM Macro PnR Co-Design

## Overview
`VX_cache_subsys` (`code/VX_cache_subsys.sv`) integrates a 16 KB, 2-bank, 4-way set-associative, sectored, write-through GPU L1 data cache (`64` sets/bank, `32 B` lines across `4 x 64`-bit word slices, `16 B` sectors, `LATENCY = 2`, non-LLC `AMO_ENABLE = 1`, `CS_REPL_PLRU`, 16-bit tags). You own the RTL-to-physical co-design across:
- `code/VX_cache_repl.sv`
- `code/VX_cache_tags.sv`
- `code/VX_cache_data.sv`
- `plan/macro_placement.json`
- `constraints/cache_subsys.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Protocol Contract
1. **Tree-PLRU Victim Selection (`VX_cache_repl`)**:
   - Initialize all per-set PLRU state across the post-reset cache initialization sweep, advance PLRU state on both cache hits and line fills so 4-way allocations utilize all associative ways without premature thrashing, and preserve coherent victim selection across back-to-back same-set hit/fill/lookup cycles and pipeline stalls.
2. **Tag Array & Sectored Coherence (`VX_cache_tags`)**:
   - Store each bank's `64`-set x `4`-way x `16`-bit tags in `RM_IHPSG13_1P_256x64_c2_bm_bist` (`u_tag_sram`) with expanded 64-bit active-high bit-write masks (`A_BM`), mutually exclusive `A_WEN`/`A_REN`, and gated `A_MEN` during stalled non-fill cycles.
   - Track per-sector valid state across cold line fills, resident-line sector refills (retaining valid sibling sectors in the same way), flushes, and non-LLC AMO passthrough hit invalidations, forwarding same-set updates/invalidations cleanly to consecutive lookups.
3. **Way-Folded Word-Sliced Data Array (`VX_cache_data`)**:
   - Map each bank's `4` ways x `64` sets (`256` rows) across four `RM_IHPSG13_1P_256x64_c2_bm_bist` word-slice macros (`u_data_slice_0`..`u_data_slice_3`) addressed by `{way, line_idx}`.
   - Expand 8-bit byte enables to 64-bit `A_BM`, write only the installed sector's word slices on 128-bit fills and only the addressed word slice on write hits, never assert `A_WEN` and `A_REN` simultaneously, and activate `A_MEN`/`A_REN` on at most the single addressed word slice during non-fill reads.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 2200]` um, core area `[50, 50, 2550, 2150]` um. Place all ten `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um: `u_cache.u_bank_{0,1}.cache_tags.u_tag_sram` and `u_cache.u_bank_{0,1}.cache_data.u_data_slice_{0..3}`) inside the core boundary (`>= 2` um core margin, `>= 8` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/cache_subsys.sdc`)**: Constrain `clk` (`core_clk`) to period `<= 17.0` ns with `>= 1.5` ns input/output delays on all non-clock ports (only `reset` may carry `set_false_path`).
- **OpenROAD Signoff**: Latch-free synthesis (`0` `$dlatch`, `10` hard SRAM macros), connected `VDD`/`VSS` PDN grids, post-GRT setup `WNS >= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 25`, and total routed wirelength `<= 6,200,000` um.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Signoff Notes (`VX_cache_subsys`)

- **RTL Simulation**: Compile `pdk/core.v`, `pdk/256.v`, and the SystemVerilog collateral in `code/` (`VX_gpu_pkg.sv` first) with Verilator 5 (`-sv -DSYNTHESIS -DXLEN_32 -DFUNCTIONAL -Icode`) targeting top module `VX_cache_subsys`.
- **Logic Synthesis**: Synthesize `VX_cache_subsys` with `yosys -m slang` (`read_slang -DSYNTHESIS -DXLEN_32 -Icode pdk/256_stub.v ... --top VX_cache_subsys; synth -top VX_cache_subsys -flatten`) mapped to `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`.
- **Physical Implementation & Signoff**: Run OpenROAD on IHP SG13G2 (`pdk/sg13g2_tech.lef`, `pdk/sg13g2_stdcell.lef`, `pdk/256.lef`, `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`, `pdk/256.lib`) using `plan/macro_placement.json` and `constraints/cache_subsys.sdc`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/VX_cache_repl.sv (Buggy Starter)
+++ b/solution/gold/code/VX_cache_repl.sv (Golden Reference)
@@ -1,20 +1,7 @@
 // Copyright © 2019-2023
-//
-// Licensed under the Apache License, Version 2.0 (the "License");
-// you may not use this file except in compliance with the License.
-// You may obtain a copy of the License at
-// http://www.apache.org/licenses/LICENSE-2.0
-//
-// Unless required by applicable law or agreed to in writing, software
-// distributed under the License is distributed on an "AS IS" BASIS,
-// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-// See the License for the specific language governing permissions and
-// limitations under the License.
+// Licensed under the Apache License, Version 2.0.
 
 `include "VX_cache_define.vh"
-
-// Fast PLRU encoder and decoder utility
-// Adapted from BaseJump STL: http://bjump.org/data_out.html
 
 module plru_decoder import VX_gpu_pkg::*; #(
     parameter NUM_WAYS      = 1,
@@ -45,7 +32,6 @@
         assign lru_data = '0;
         assign lru_mask = '0;
     end
-
 endmodule
 
 module plru_encoder #(
@@ -76,15 +62,14 @@
         `UNUSED_VAR (lru_in)
         assign way_idx = '0;
     end
-
 endmodule
 
 module VX_cache_repl #(
     parameter CACHE_SIZE = 1024,
-    parameter LINE_SIZE  = 64,                // Size of line inside a bank in bytes
-    parameter NUM_BANKS  = 1,                 // Number of banks
-    parameter NUM_WAYS   = 1,                 // Number of associative ways
-    parameter REPL_POLICY = `CS_REPL_FIFO     // replacement policy
+    parameter LINE_SIZE  = 64,
+    parameter NUM_BANKS  = 1,
+    parameter NUM_WAYS   = 1,
+    parameter REPL_POLICY = `CS_REPL_FIFO
 ) (
     input wire clk,
     input wire reset,
@@ -96,126 +81,88 @@
     input wire [`CS_WAY_SEL_WIDTH-1:0] lookup_way,
     input wire repl_valid,
     input wire [`CS_LINE_SEL_BITS-1:0] repl_line,
-    input wire [`CS_LINE_SEL_BITS-1:0] repl_line_n, // look-ahead (next) line for sync-BRAM read
+    input wire [`CS_LINE_SEL_BITS-1:0] repl_line_n,
     output wire [`CS_WAY_SEL_WIDTH-1:0] repl_way
 );
     localparam WAY_SEL_WIDTH = `CS_WAY_SEL_WIDTH;
-    `UNUSED_VAR (reset)
-    `UNUSED_VAR (init)
-    `UNUSED_VAR (stall)
+    localparam NUM_SETS      = `CS_LINES_PER_BANK;
 
     if (NUM_WAYS > 1) begin : g_enable
         if (REPL_POLICY == `CS_REPL_PLRU) begin : g_plru
-            // Pseudo Least Recently Used replacement policy
-            `UNUSED_VAR (repl_line) // read uses repl_line_n (look-ahead)
-            `UNUSED_VAR (repl_valid) // state advances on lookup hits only
             localparam LRU_WIDTH = `UP(NUM_WAYS-1);
 
-            wire [LRU_WIDTH-1:0] plru_rdata;
-            wire [LRU_WIDTH-1:0] plru_wdata;
-            wire [LRU_WIDTH-1:0] plru_wmask;
+            reg [LRU_WIDTH-1:0] plru_arr [0:NUM_SETS-1];
+            reg [LRU_WIDTH-1:0] plru_rdata_r;
 
-            // Look-ahead read advances every non-stalled cycle (same idiom as
-            // the tag store) so the data always tracks the request entering
-            // S0; gating it on repl_valid would leave the victim computed
-            // from the line captured at the previous fill.
-            VX_dp_ram #(
-                .DATAW (LRU_WIDTH),
-                .SIZE  (`CS_LINES_PER_BANK),
-                .WRENW (LRU_WIDTH),
-                .OUT_REG (1),
-                .RDW_MODE ("R")
-            ) plru_store (
-                .clk   (clk),
-                .reset (1'b0),
-                .read  (~stall),
-                .write (init || (lookup_valid && lookup_hit)),
-                .wren  (init ? '1 : plru_wmask),
-                .waddr (lookup_line),
-                .raddr (repl_line_n),
-                .wdata (init ? '0 : plru_wdata),
-                .rdata (plru_rdata)
+            wire hit_upd = lookup_valid && lookup_hit;
+            wire [LRU_WIDTH-1:0] hit_wdata, hit_wmask;
+            wire [LRU_WIDTH-1:0] fill_wdata, fill_wmask;
+            wire [WAY_SEL_WIDTH-1:0] victim_way_w;
+
+            plru_decoder #(.NUM_WAYS(NUM_WAYS)) u_hit_dec (
+                .way_idx  (lookup_way),
+                .lru_data (hit_wdata),
+                .lru_mask (hit_wmask)
             );
 
-            plru_decoder #(
-                .NUM_WAYS (NUM_WAYS)
-            ) plru_dec (
-                .way_idx  (lookup_way),
-                .lru_data (plru_wdata),
-                .lru_mask (plru_wmask)
+            plru_encoder #(.NUM_WAYS(NUM_WAYS)) u_plru_enc (
+                .lru_in  (plru_rdata_r),
+                .way_idx (victim_way_w)
             );
 
-            plru_encoder #(
-                .NUM_WAYS (NUM_WAYS)
-            ) plru_enc (
-                .lru_in  (plru_rdata),
-                .way_idx (repl_way)
+            plru_decoder #(.NUM_WAYS(NUM_WAYS)) u_fill_dec (
+                .way_idx  (victim_way_w),
+                .lru_data (fill_wdata),
+                .lru_mask (fill_wmask)
             );
 
-        end else if (REPL_POLICY == `CS_REPL_FIFO) begin : g_fifo
-            // Fifo replacement policy
-            `UNUSED_VAR (lookup_valid)
-            `UNUSED_VAR (lookup_hit)
-            `UNUSED_VAR (lookup_line)
-            `UNUSED_VAR (lookup_way)
+            // Compute next PLRU vector for any set accounting for init, hit_upd, and repl_valid
+            wire [LRU_WIDTH-1:0] cur_hit_set  = plru_arr[lookup_line];
+            wire [LRU_WIDTH-1:0] cur_fill_set = plru_arr[repl_line];
+            wire [LRU_WIDTH-1:0] cur_next_set = plru_arr[repl_line_n];
 
-            wire [WAY_SEL_WIDTH-1:0] fifo_rdata;
-            wire [WAY_SEL_WIDTH-1:0] fifo_wdata = fifo_rdata + 1;
+            wire [LRU_WIDTH-1:0] after_hit_for_fill = (hit_upd && (lookup_line == repl_line))
+                ? ((cur_fill_set & ~hit_wmask) | (hit_wdata & hit_wmask))
+                : cur_fill_set;
+            wire [LRU_WIDTH-1:0] nxt_fill_val = (after_hit_for_fill & ~fill_wmask) | (fill_wdata & fill_wmask);
+            wire [LRU_WIDTH-1:0] nxt_hit_val  = (cur_hit_set & ~hit_wmask) | (hit_wdata & hit_wmask);
 
-            // Same per-cycle look-ahead as plru_store/tag store; read-first so
-            // the fill's own increment is not bypassed into its victim read.
-            VX_dp_ram #(
-                .DATAW (WAY_SEL_WIDTH),
-                .SIZE  (`CS_LINES_PER_BANK),
-                .OUT_REG (1),
-                .RDW_MODE ("R")
-            ) fifo_store (
-                .clk   (clk),
-                .reset (1'b0),
-                .read  (~stall),
-                .write (init || repl_valid),
-                .wren  (1'b1),
-                .waddr (repl_line),
-                .raddr (repl_line_n),
-                .wdata (init ? '0 : fifo_wdata),
-                .rdata (fifo_rdata)
-            );
+            reg [LRU_WIDTH-1:0] rdata_next;
+            always @(*) begin
+                rdata_next = cur_next_set;
+                if (hit_upd && (lookup_line == repl_line_n))
+                    rdata_next = (rdata_next & ~hit_wmask) | (hit_wdata & hit_wmask);
+                if (repl_valid && (repl_line == repl_line_n))
+                    rdata_next = (rdata_next & ~fill_wmask) | (fill_wdata & fill_wmask);
+                if (init && (repl_line == repl_line_n))
+                    rdata_next = '0;
+            end
 
-            assign repl_way = fifo_rdata;
-        end else begin : g_random
-            // Random replacement policy
-            `UNUSED_VAR (lookup_valid)
-            `UNUSED_VAR (lookup_hit)
-            `UNUSED_VAR (lookup_line)
-            `UNUSED_VAR (lookup_way)
-            `UNUSED_VAR (repl_line)
-            `UNUSED_VAR (repl_line_n)
-            localparam STATE_W = 2 * WAY_SEL_WIDTH;
-            reg [STATE_W-1:0] rng_state;
-            // Maximal-period LFSR over STATE_W bits using xnor of top two bits.
-            wire rng_fb = ~(rng_state[STATE_W-1] ^ rng_state[STATE_W-2]);
             always @(posedge clk) begin
                 if (reset) begin
-                    rng_state <= {STATE_W{1'b1}};
-                end else if (repl_valid) begin
-                    rng_state <= {rng_state[STATE_W-2:0], rng_fb};
+                    for (int s = 0; s < NUM_SETS; ++s)
+                        plru_arr[s] <= '0;
+                    plru_rdata_r <= '0;
+                end else begin
+                    if (hit_upd)
+                        plru_arr[lookup_line] <= nxt_hit_val;
+                    if (repl_valid)
+                        plru_arr[repl_line] <= nxt_fill_val;
+                    if (init)
+                        plru_arr[repl_line] <= '0;
+                    if (~stall)
+                        plru_rdata_r <= rdata_next;
                 end
             end
-            // XOR-mix LFSR with line index so different lines see different
-            // victim sequences for the same RNG state.
-            assign repl_way = rng_state[WAY_SEL_WIDTH-1:0]
-                            ^ rng_state[STATE_W-1 -: WAY_SEL_WIDTH]
-                            ^ repl_line[WAY_SEL_WIDTH-1:0];
+
+            assign repl_way = victim_way_w;
+
+        end else begin : g_other
+            `UNUSED_VAR ({clk, reset, stall, init, lookup_valid, lookup_hit, lookup_line, lookup_way, repl_valid, repl_line, repl_line_n})
+            assign repl_way = '0;
         end
     end else begin : g_disable
-        `UNUSED_VAR (clk)
-        `UNUSED_VAR (lookup_valid)
-        `UNUSED_VAR (lookup_hit)
-        `UNUSED_VAR (lookup_line)
-        `UNUSED_VAR (lookup_way)
-        `UNUSED_VAR (repl_valid)
-        `UNUSED_VAR (repl_line)
-        `UNUSED_VAR (repl_line_n)
+        `UNUSED_VAR ({clk, reset, stall, init, lookup_valid, lookup_hit, lookup_line, lookup_way, repl_valid, repl_line, repl_line_n})
         assign repl_way = 1'b0;
     end
 

--- a/environment/public/code/VX_cache_tags.sv (Buggy Starter)
+++ b/solution/gold/code/VX_cache_tags.sv (Golden Reference)
@@ -42,7 +42,8 @@
     assign evict_dirty_mask = '0;
     assign evict_tag        = '0;
 
-    wire [SEC-1:0] sec_oh = SEC'(1) << sector_idx;
+    wire [SEC-1:0] sec_oh     = SEC'(1) << sector_idx;
+    wire           same_set_n = (line_idx == line_idx_n);
 
     wire [NUM_WAYS-1:0]                       line_write;
     wire [NUM_WAYS-1:0][`CS_TAG_SEL_BITS-1:0] line_wdata;
@@ -71,12 +72,16 @@
         `BUFFER_EX(rdw_set, line_idx, ~stall, $bits(rdw_set), 1);
         wire way_filled = rdw_fill_raw && (line_idx == rdw_set);
 
-        wire [`CS_TAG_SEL_BITS-1:0] read_tag_w = way_filled ? rdw_tag : tag_rdata[i];
-        wire tag_eq = (line_tag == read_tag_w);
+        wire tag_eq_bypass = (line_tag == rdw_tag);
+        wire tag_eq_sram   = (line_tag == tag_rdata[i]);
+        wire tag_eq        = way_filled ? tag_eq_bypass : tag_eq_sram;
 
+        // Forward same-set valid-bit clears (init / flush / AMO invalidate) across 1-cycle OUT_REG LUTRAM
+        wire [SEC-1:0] rdw_vclr_prev;
+        wire [SEC-1:0] rdata_valid = valid_rdata[i] & ~rdw_vclr_prev;
         wire [SEC-1:0] read_valid_w = way_filled
-            ? (rdw_refill ? (valid_rdata[i] | rdw_sec_oh) : rdw_sec_oh)
-            : valid_rdata[i];
+            ? (rdw_refill ? (rdata_valid | rdw_sec_oh) : rdw_sec_oh)
+            : rdata_valid;
 
         wire raw_hit  = read_valid_w[sector_idx] && tag_eq;
         wire do_inval = (AMO_ENABLE != 0) && invalidate && raw_hit;
@@ -89,6 +94,10 @@
                                | ((do_fill && ~fill_refill) ? ~sec_oh     : {SEC{1'b0}})
                                | (do_inval                  ? sec_oh      : {SEC{1'b0}});
 
+        wire [SEC-1:0] same_set_clear = (do_init || do_flush) ? {SEC{1'b1}}
+                                      : (do_inval             ? sec_oh : {SEC{1'b0}});
+        `BUFFER_EX(rdw_vclr_prev, (same_set_n ? same_set_clear : {SEC{1'b0}}), ~stall, SEC, 1);
+
         assign valid_wren[i]  = vset_oh | vclr_oh;
         assign valid_wdata[i] = vset_oh;
 
@@ -96,15 +105,22 @@
         assign line_present[i] = tag_eq && (| read_valid_w);
     end
 
+    // Single-port 256x64 hard SRAM macro holding 4 x 16-bit tags per set (64 sets in rows 0..63)
+    wire        tag_sram_wen  = fill;
+    wire        tag_sram_ren  = ~fill && ~stall;
+    wire        tag_sram_men  = tag_sram_wen || tag_sram_ren;
     wire [7:0]  tag_sram_addr = {2'b00, fill ? line_idx : line_idx_n};
     wire [63:0] tag_sram_din  = line_wdata;
-    wire [63:0] tag_sram_bm   = {60'd0, line_write};
+    wire [63:0] tag_sram_bm   = {
+        {16{line_write[3]}}, {16{line_write[2]}},
+        {16{line_write[1]}}, {16{line_write[0]}}
+    };
 
     RM_IHPSG13_1P_256x64_c2_bm_bist u_tag_sram (
         .A_CLK       (clk),
-        .A_MEN       (1'b1),
-        .A_WEN       (fill),
-        .A_REN       (~fill && ~stall),
+        .A_MEN       (tag_sram_men),
+        .A_WEN       (tag_sram_wen),
+        .A_REN       (tag_sram_ren),
         .A_ADDR      (tag_sram_addr),
         .A_DIN       (tag_sram_din),
         .A_DLY       (1'b1),

--- a/environment/public/code/VX_cache_data.sv (Buggy Starter)
+++ b/solution/gold/code/VX_cache_data.sv (Golden Reference)
@@ -51,6 +51,7 @@
 
     wire hit_any = (| tag_matches);
     wire [`CS_WAY_SEL_WIDTH-1:0] way_sel = fill ? evict_way : hit_way;
+
     wire [DATA_ADDR_WIDTH-1:0] data_addr = DATA_ADDR_WIDTH'({way_sel[WAY_SEL_BITS-1:0], line_idx});
     wire [7:0] sram_addr = 8'(data_addr);
 
@@ -68,16 +69,19 @@
         wire word_en     = (word_idx == s[1:0]);
         wire fill_sec_en = (sector_idx == `UP(`CS_SECTOR_SEL_BITS)'(SLICE_SECTOR));
 
-        wire s_rd = read;
+        wire s_rd = read && word_en;
         wire s_wr = WRITE_ENABLE ? ((fill && fill_sec_en) || (write && hit_any && word_en))
                                  : (fill && fill_sec_en);
         wire [7:0] s_be = fill ? 8'hFF : write_byteen;
 
         assign slice_wen[s] = s_wr;
         assign slice_ren[s] = s_rd && !s_wr;
-        assign slice_men[s] = 1'b1;
+        assign slice_men[s] = s_wr || s_rd;
         assign slice_din[s] = fill ? fill_data[s] : write_word;
-        assign slice_bm[s]  = {56'd0, s_be};
+        assign slice_bm[s]  = {
+            {8{s_be[7]}}, {8{s_be[6]}}, {8{s_be[5]}}, {8{s_be[4]}},
+            {8{s_be[3]}}, {8{s_be[2]}}, {8{s_be[1]}}, {8{s_be[0]}}
+        };
     end
 
     RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_0 (

--- a/environment/public/plan/macro_placement.json (Buggy Starter)
+++ b/solution/gold/plan/macro_placement.json (Golden Reference)
@@ -1,64 +1,64 @@
 {
   "macros": [
     {
-      "instance": "u_cache.u_bank_0.cache_tags.u_tag_sram",
-      "x": 1680.0,
-      "y": 1960.0,
-      "orientation": "R0"
-    },
-    {
       "instance": "u_cache.u_bank_0.cache_data.u_data_slice_0",
-      "x": 120.0,
-      "y": 120.0,
-      "orientation": "R0"
+      "x": 180.0,
+      "y": 220.0,
+      "orientation": "R180"
     },
     {
       "instance": "u_cache.u_bank_0.cache_data.u_data_slice_1",
-      "x": 120.0,
-      "y": 210.0,
-      "orientation": "R0"
+      "x": 180.0,
+      "y": 620.0,
+      "orientation": "MY"
+    },
+    {
+      "instance": "u_cache.u_bank_0.cache_tags.u_tag_sram",
+      "x": 180.0,
+      "y": 1040.0,
+      "orientation": "R180"
     },
     {
       "instance": "u_cache.u_bank_0.cache_data.u_data_slice_2",
-      "x": 120.0,
-      "y": 300.0,
-      "orientation": "R0"
+      "x": 180.0,
+      "y": 1460.0,
+      "orientation": "MY"
     },
     {
       "instance": "u_cache.u_bank_0.cache_data.u_data_slice_3",
-      "x": 120.0,
-      "y": 390.0,
+      "x": 180.0,
+      "y": 1860.0,
+      "orientation": "R180"
+    },
+    {
+      "instance": "u_cache.u_bank_1.cache_data.u_data_slice_0",
+      "x": 1635.0,
+      "y": 220.0,
+      "orientation": "MX"
+    },
+    {
+      "instance": "u_cache.u_bank_1.cache_data.u_data_slice_1",
+      "x": 1635.0,
+      "y": 620.0,
       "orientation": "R0"
     },
     {
       "instance": "u_cache.u_bank_1.cache_tags.u_tag_sram",
-      "x": 120.0,
-      "y": 1960.0,
-      "orientation": "R0"
-    },
-    {
-      "instance": "u_cache.u_bank_1.cache_data.u_data_slice_0",
-      "x": 1680.0,
-      "y": 120.0,
-      "orientation": "R0"
-    },
-    {
-      "instance": "u_cache.u_bank_1.cache_data.u_data_slice_1",
-      "x": 1680.0,
-      "y": 210.0,
-      "orientation": "R0"
+      "x": 1635.0,
+      "y": 1040.0,
+      "orientation": "MX"
     },
     {
       "instance": "u_cache.u_bank_1.cache_data.u_data_slice_2",
-      "x": 1680.0,
-      "y": 300.0,
+      "x": 1635.0,
+      "y": 1460.0,
       "orientation": "R0"
     },
     {
       "instance": "u_cache.u_bank_1.cache_data.u_data_slice_3",
-      "x": 1680.0,
-      "y": 390.0,
-      "orientation": "R0"
+      "x": 1635.0,
+      "y": 1860.0,
+      "orientation": "MX"
     }
   ]
 }

--- a/environment/public/constraints/cache_subsys.sdc (Buggy Starter)
+++ b/solution/gold/constraints/cache_subsys.sdc (Golden Reference)
@@ -1,4 +1,4 @@
-create_clock -name core_clk -period 25.0 [get_ports clk]
-set_input_delay 0.5 -clock core_clk [all_inputs -no_clocks]
-set_output_delay 0.5 -clock core_clk [all_outputs]
+create_clock -name core_clk -period 17.0 [get_ports clk]
+set_input_delay 1.5 -clock core_clk [all_inputs -no_clocks]
+set_output_delay 1.5 -clock core_clk [all_outputs]
 set_false_path -from [get_ports reset]

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/VX_allocator.sv`](environment/public/code/VX_allocator.sv) *(Read-Only Context)*
- [`environment/public/code/VX_amo_alu.sv`](environment/public/code/VX_amo_alu.sv) *(Read-Only Context)*
- [`environment/public/code/VX_amo_unit.sv`](environment/public/code/VX_amo_unit.sv) *(Read-Only Context)*
- [`environment/public/code/VX_async_ram_patch.sv`](environment/public/code/VX_async_ram_patch.sv) *(Read-Only Context)*
- [`environment/public/code/VX_bits_concat.sv`](environment/public/code/VX_bits_concat.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache.sv`](environment/public/code/VX_cache.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_amo.sv`](environment/public/code/VX_cache_amo.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_bank.sv`](environment/public/code/VX_cache_bank.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_data.sv`](environment/public/code/VX_cache_data.sv) **(Editable)**
- [`environment/public/code/VX_cache_define.vh`](environment/public/code/VX_cache_define.vh) *(Read-Only Context)*
- [`environment/public/code/VX_cache_flush.sv`](environment/public/code/VX_cache_flush.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_init.sv`](environment/public/code/VX_cache_init.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_mshr.sv`](environment/public/code/VX_cache_mshr.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_repl.sv`](environment/public/code/VX_cache_repl.sv) **(Editable)**
- [`environment/public/code/VX_cache_subsys.sv`](environment/public/code/VX_cache_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_tags.sv`](environment/public/code/VX_cache_tags.sv) **(Editable)**
- [`environment/public/code/VX_config.vh`](environment/public/code/VX_config.vh) *(Read-Only Context)*
- [`environment/public/code/VX_cyclic_arbiter.sv`](environment/public/code/VX_cyclic_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_define.vh`](environment/public/code/VX_define.vh) *(Read-Only Context)*
- [`environment/public/code/VX_demux.sv`](environment/public/code/VX_demux.sv) *(Read-Only Context)*
- [`environment/public/code/VX_dp_ram.sv`](environment/public/code/VX_dp_ram.sv) *(Read-Only Context)*
- [`environment/public/code/VX_dp_ram_asic.v`](environment/public/code/VX_dp_ram_asic.v) *(Read-Only Context)*
- [`environment/public/code/VX_elastic_buffer.sv`](environment/public/code/VX_elastic_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_fifo_queue.sv`](environment/public/code/VX_fifo_queue.sv) *(Read-Only Context)*
- [`environment/public/code/VX_find_first.sv`](environment/public/code/VX_find_first.sv) *(Read-Only Context)*
- [`environment/public/code/VX_generic_arbiter.sv`](environment/public/code/VX_generic_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_gpu_pkg.sv`](environment/public/code/VX_gpu_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/VX_index_buffer.sv`](environment/public/code/VX_index_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_lzc.sv`](environment/public/code/VX_lzc.sv) *(Read-Only Context)*
- [`environment/public/code/VX_matrix_arbiter.sv`](environment/public/code/VX_matrix_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_mem_bus_if.sv`](environment/public/code/VX_mem_bus_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_mux.sv`](environment/public/code/VX_mux.sv) *(Read-Only Context)*
- [`environment/public/code/VX_onehot_encoder.sv`](environment/public/code/VX_onehot_encoder.sv) *(Read-Only Context)*
- [`environment/public/code/VX_onehot_mux.sv`](environment/public/code/VX_onehot_mux.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pending_size.sv`](environment/public/code/VX_pending_size.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pipe_buffer.sv`](environment/public/code/VX_pipe_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pipe_register.sv`](environment/public/code/VX_pipe_register.sv) *(Read-Only Context)*
- [`environment/public/code/VX_platform.vh`](environment/public/code/VX_platform.vh) *(Read-Only Context)*
- [`environment/public/code/VX_popcount.sv`](environment/public/code/VX_popcount.sv) *(Read-Only Context)*
- [`environment/public/code/VX_priority_arbiter.sv`](environment/public/code/VX_priority_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_priority_encoder.sv`](environment/public/code/VX_priority_encoder.sv) *(Read-Only Context)*
- [`environment/public/code/VX_reduce_tree.sv`](environment/public/code/VX_reduce_tree.sv) *(Read-Only Context)*
- [`environment/public/code/VX_rr_arbiter.sv`](environment/public/code/VX_rr_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scan.sv`](environment/public/code/VX_scan.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scope.vh`](environment/public/code/VX_scope.vh) *(Read-Only Context)*
- [`environment/public/code/VX_shift_register.sv`](environment/public/code/VX_shift_register.sv) *(Read-Only Context)*
- [`environment/public/code/VX_skid_buffer.sv`](environment/public/code/VX_skid_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_sp_ram.sv`](environment/public/code/VX_sp_ram.sv) *(Read-Only Context)*
- [`environment/public/code/VX_sp_ram_asic.v`](environment/public/code/VX_sp_ram_asic.v) *(Read-Only Context)*
- [`environment/public/code/VX_stream_arb.sv`](environment/public/code/VX_stream_arb.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_buffer.sv`](environment/public/code/VX_stream_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_dispatch.sv`](environment/public/code/VX_stream_dispatch.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_fork.sv`](environment/public/code/VX_stream_fork.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_join.sv`](environment/public/code/VX_stream_join.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_omega.sv`](environment/public/code/VX_stream_omega.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_pack.sv`](environment/public/code/VX_stream_pack.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_switch.sv`](environment/public/code/VX_stream_switch.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_unpack.sv`](environment/public/code/VX_stream_unpack.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_xbar.sv`](environment/public/code/VX_stream_xbar.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_xpoint.sv`](environment/public/code/VX_stream_xpoint.sv) *(Read-Only Context)*
- [`environment/public/code/VX_transpose.sv`](environment/public/code/VX_transpose.sv) *(Read-Only Context)*
- [`environment/public/code/VX_types.vh`](environment/public/code/VX_types.vh) *(Read-Only Context)*
- [`environment/public/constraints/cache_subsys.sdc`](environment/public/constraints/cache_subsys.sdc) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/pdk/256.lef`](environment/public/pdk/256.lef) *(Read-Only Context)*
- [`environment/public/pdk/256.lib`](environment/public/pdk/256.lib) *(Read-Only Context)*
- [`environment/public/pdk/256.v`](environment/public/pdk/256.v) *(Read-Only Context)*
- [`environment/public/pdk/256_stub.v`](environment/public/pdk/256_stub.v) *(Read-Only Context)*
- [`environment/public/pdk/LICENSE.IHP`](environment/public/pdk/LICENSE.IHP) *(Read-Only Context)*
- [`environment/public/pdk/core.v`](environment/public/pdk/core.v) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell.lef`](environment/public/pdk/sg13g2_stdcell.lef) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib`](environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_tech.lef`](environment/public/pdk/sg13g2_tech.lef) *(Read-Only Context)*
- [`environment/public/plan/macro_placement.json`](environment/public/plan/macro_placement.json) **(Editable)**

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

