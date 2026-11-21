# `case_23013`: Vortex SIMT 8-Bank Shared Local Memory AMO/DMA Subsystem & Physical Macro Co-Design

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23013` |
| **Source Silicon Repository** | `vortexgpgpu/vortex` (`repo_37`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/VX_lmem_switch.sv`](environment/public/code/VX_lmem_switch.sv), [`code/VX_local_mem.sv`](environment/public/code/VX_local_mem.sv), [`plan/macro_placement.json`](environment/public/plan/macro_placement.json), [`constraints/lmem_subsys.sdc`](environment/public/constraints/lmem_subsys.sdc) (4 files, 1137 LOC) |
| **Public Subsystem Context** | 56 RTL files (13055 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1800s` total (`900s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Vortex SIMT 8-Bank Shared Local Memory Subsystem & Physical Macro Co-Design

## Overview
`VX_lmem_subsys` (`code/VX_lmem_subsys.sv`) integrates Vortex's SIMT local/global memory request switch, per-lane LSU adapter, 512-bit (`8 x 64`-bit) wide-line DMA port, and 8-bank RV64A-capable Shared Local Memory (`16 KB`, `2` SIMD lanes, `64`-bit words). You own the RTL-to-physical co-design across:
- `code/VX_lmem_switch.sv`
- `code/VX_local_mem.sv`
- `plan/macro_placement.json`
- `constraints/lmem_subsys.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Protocol Contract
1. **Mixed Local/Global SIMD Warp Bifurcation (`VX_lmem_switch`)**:
   - Partition active request lanes (`lsu_in_if.req_data.mask`) per `MEM_ATTR_LOCAL_OFFS` across `local_out_if` (`1`) and `global_out_if` (`0`).
   - When a single warp beat contains both local and global lanes and only one downstream request port is ready, prevent duplicate pushes to the already-accepted target while stalling `lsu_in_if.req_ready` until both required subsets complete; merge returning local and global responses losslessly on `lsu_in_if`.
2. **8-Bank Shared Local Memory, RV64A Atomics & Wide-Line DMA (`VX_local_mem`)**:
   - Instantiate all eight `RM_IHPSG13_1P_256x64_c2_bm_bist` (`256 x 64`) single-port synchronous SRAM macros (`u_lmem_bank_0`..`u_lmem_bank_7`). Expand 8-bit byte write enables to the 64-bit active-high bit mask (`A_BM`), hold `A_MEN == 1'b0` on idle banks, and never assert `A_WEN` and `A_REN` simultaneously on any macro.
   - Support 2-lane 64-bit LSU loads, byte-masked stores, same-address read-after-write hazard protection, and RV64A `.W`/`.D` atomic read-modify-write and `LR`/`SC` operations (including upper/lower 32-bit `.W` lane alignment and reservation invalidation).
   - Coordinate 512-bit `dma_bus_if` line reads and byte-masked line writes so DMA transactions never corrupt or overwrite an in-flight per-bank atomic RMW sequence, and preserve stalled LSU and DMA read response data against interleaving bank reads under arbitrary `rsp_ready` backpressure.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 1900]` um, core area `[50, 50, 2550, 1850]` um. Place all eight `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2` um core margin, `>= 8` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/lmem_subsys.sdc`)**: Constrain `clk` (`core_clk`) to period `<= 20.0` ns with `>= 1.5` ns input/output delays on all non-clock ports (only `reset` may carry `set_false_path`).
- **OpenROAD Signoff**: Latch-free synthesis (`0` `$dlatch`), connected `VDD`/`VSS` PDN grids, post-GRT setup `WNS >= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 25`, and total routed wirelength `<= 7,800,000` um.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Signoff Notes (`VX_lmem_subsys`)

- **RTL Simulation**: Compile `pdk/core.v`, `pdk/256.v`, and the SystemVerilog collateral in `code/` with Verilator 5 (`-sv -DASIC -DSYNTHESIS -DFUNCTIONAL -Icode`) targeting top module `VX_lmem_subsys`.
- **Logic Synthesis**: Synthesize `VX_lmem_subsys` with `yosys -m slang` (`read_slang -DASIC -DSYNTHESIS -Icode pdk/256_stub.v ... --top VX_lmem_subsys; synth -top VX_lmem_subsys -flatten`) mapped to `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`.
- **Physical Implementation & Signoff**: Run OpenROAD on IHP SG13G2 (`pdk/sg13g2_tech.lef`, `pdk/sg13g2_stdcell.lef`, `pdk/256.lef`, `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`, `pdk/256.lib`) using `plan/macro_placement.json` and `constraints/lmem_subsys.sdc`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/VX_lmem_switch.sv (Buggy Starter)
+++ b/solution/gold/code/VX_lmem_switch.sv (Golden Reference)
@@ -1,25 +1,7 @@
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
 
 `include "VX_define.vh"
-
-// Splits an LSU request into a global-memory part and a local-memory
-// part using each lane's is_addr_local user bit. Both subsets fire
-// independently with masked-out lanes; lsu_in_if.req_ready waits for
-// whichever subset(s) are non-empty.
-//
-// The local path carries the AMOs through to the LMEM banks, which perform the
-// read-modify-write in place and hold the LR/SC reservations.
 
 module VX_lmem_switch import VX_gpu_pkg::*; #(
     parameter GLOBAL_OUT_BUF = 0,
@@ -36,7 +18,6 @@
     localparam REQ_DATAW = `VX_CFG_NUM_LSU_LANES + 1 + `VX_CFG_NUM_LSU_LANES * (LSU_WORD_SIZE + LSU_ADDR_WIDTH + MEM_ATTR_WIDTH + LSU_WORD_SIZE * 8) + LSU_TAG_WIDTH;
     localparam RSP_DATAW = `VX_CFG_NUM_LSU_LANES + `VX_CFG_NUM_LSU_LANES * (LSU_WORD_SIZE * 8) + LSU_TAG_WIDTH;
 
-    // Per-lane is_addr_local from the user bits at the fixed offset.
     wire [`VX_CFG_NUM_LSU_LANES-1:0] is_addr_local_mask;
     for (genvar i = 0; i < `VX_CFG_NUM_LSU_LANES; ++i) begin : g_is_addr_local_mask
         assign is_addr_local_mask[i] = lsu_in_if.req_data.user[i][MEM_ATTR_LOCAL_OFFS];
@@ -51,60 +32,101 @@
     wire req_global_ready;
     wire req_local_ready;
 
-    // Both subsets must be accepted before we release the LSU input.
-    assign lsu_in_if.req_ready = (!is_addr_global || req_global_ready)
-                              && (!is_addr_local  || req_local_ready);
+    // Per-beat subset completion tracking to prevent duplicate pushes when only one path stalls
+    reg global_sent_r;
+    reg local_sent_r;
 
-    VX_elastic_buffer #(
-        .DATAW   (REQ_DATAW),
-        .SIZE    (`TO_OUT_BUF_SIZE(GLOBAL_OUT_BUF)),
-        .OUT_REG (`TO_OUT_BUF_REG(GLOBAL_OUT_BUF))
-    ) req_global_buf (
-        .clk       (clk),
-        .reset     (reset),
-        .valid_in  (lsu_in_if.req_valid && is_addr_global),
-        .data_in   ({
-            global_mask,
-            lsu_in_if.req_data.rw,
-            lsu_in_if.req_data.addr,
-            lsu_in_if.req_data.data,
-            lsu_in_if.req_data.byteen,
-            lsu_in_if.req_data.user,
-            lsu_in_if.req_data.tag
-        }),
-        .ready_in  (req_global_ready),
-        .valid_out (global_out_if.req_valid),
-        .data_out  (global_out_if.req_data),
-        .ready_out (global_out_if.req_ready)
-    );
+    wire global_need = is_addr_global && !global_sent_r;
+    wire local_need  = is_addr_local  && !local_sent_r;
+
+    wire global_done = !is_addr_global || global_sent_r || req_global_ready;
+    wire local_done  = !is_addr_local  || local_sent_r  || req_local_ready;
+
+    assign lsu_in_if.req_ready = global_done && local_done;
+
+    always @(posedge clk) begin
+        if (reset) begin
+            global_sent_r <= 1'b0;
+            local_sent_r  <= 1'b0;
+        end else if (lsu_in_if.req_valid) begin
+            if (lsu_in_if.req_ready) begin
+                global_sent_r <= 1'b0;
+                local_sent_r  <= 1'b0;
+            end else begin
+                if (global_need && req_global_ready)
+                    global_sent_r <= 1'b1;
+                if (local_need && req_local_ready)
+                    local_sent_r  <= 1'b1;
+            end
+        end
+    end
+
+    localparam NUM_SLICES = 4;
+    localparam SLICE_W    = (REQ_DATAW + NUM_SLICES - 1) / NUM_SLICES;
+    localparam PAD_W      = NUM_SLICES * SLICE_W;
 
     wire [`VX_CFG_NUM_LSU_LANES-1:0][MEM_ATTR_WIDTH-1:0] local_user;
     for (genvar i = 0; i < `VX_CFG_NUM_LSU_LANES; ++i) begin : g_local_user
         assign local_user[i] = lsu_in_if.req_data.user[i];
     end
 
-    VX_elastic_buffer #(
-        .DATAW   (REQ_DATAW),
-        .SIZE    (`TO_OUT_BUF_SIZE(LOCAL_OUT_BUF)),
-        .OUT_REG (`TO_OUT_BUF_REG(LOCAL_OUT_BUF))
-    ) req_local_buf (
-        .clk       (clk),
-        .reset     (reset),
-        .valid_in  (lsu_in_if.req_valid && is_addr_local),
-        .data_in   ({
-            local_mask,
-            lsu_in_if.req_data.rw,
-            lsu_in_if.req_data.addr,
-            lsu_in_if.req_data.data,
-            lsu_in_if.req_data.byteen,
-            local_user,
-            lsu_in_if.req_data.tag
-        }),
-        .ready_in  (req_local_ready),
-        .valid_out (local_out_if.req_valid),
-        .data_out  (local_out_if.req_data),
-        .ready_out (local_out_if.req_ready)
-    );
+    wire [REQ_DATAW-1:0] global_din_raw = {
+        global_mask, lsu_in_if.req_data.rw, lsu_in_if.req_data.addr,
+        lsu_in_if.req_data.data, lsu_in_if.req_data.byteen,
+        lsu_in_if.req_data.user, lsu_in_if.req_data.tag
+    };
+    wire [REQ_DATAW-1:0] local_din_raw = {
+        local_mask, lsu_in_if.req_data.rw, lsu_in_if.req_data.addr,
+        lsu_in_if.req_data.data, lsu_in_if.req_data.byteen,
+        local_user, lsu_in_if.req_data.tag
+    };
+
+    wire [PAD_W-1:0] global_din_pad = PAD_W'(global_din_raw);
+    wire [PAD_W-1:0] local_din_pad  = PAD_W'(local_din_raw);
+    wire [PAD_W-1:0] global_dout_pad;
+    wire [PAD_W-1:0] local_dout_pad;
+    wire [NUM_SLICES-1:0] g_rdy_in, g_vld_out, l_rdy_in, l_vld_out;
+
+    for (genvar s = 0; s < NUM_SLICES; ++s) begin : g_req_slices
+        (* keep_hierarchy = "yes" *)
+        VX_elastic_buffer #(
+            .DATAW   (SLICE_W),
+            .SIZE    (`TO_OUT_BUF_SIZE(GLOBAL_OUT_BUF)),
+            .OUT_REG (`TO_OUT_BUF_REG(GLOBAL_OUT_BUF))
+        ) req_global_slice (
+            .clk       (clk),
+            .reset     (reset),
+            .valid_in  (lsu_in_if.req_valid && global_need),
+            .data_in   (global_din_pad[s*SLICE_W +: SLICE_W]),
+            .ready_in  (g_rdy_in[s]),
+            .valid_out (g_vld_out[s]),
+            .data_out  (global_dout_pad[s*SLICE_W +: SLICE_W]),
+            .ready_out (global_out_if.req_ready)
+        );
+        (* keep_hierarchy = "yes" *)
+        VX_elastic_buffer #(
+            .DATAW   (SLICE_W),
+            .SIZE    (`TO_OUT_BUF_SIZE(LOCAL_OUT_BUF)),
+            .OUT_REG (`TO_OUT_BUF_REG(LOCAL_OUT_BUF))
+        ) req_local_slice (
+            .clk       (clk),
+            .reset     (reset),
+            .valid_in  (lsu_in_if.req_valid && local_need),
+            .data_in   (local_din_pad[s*SLICE_W +: SLICE_W]),
+            .ready_in  (l_rdy_in[s]),
+            .valid_out (l_vld_out[s]),
+            .data_out  (local_dout_pad[s*SLICE_W +: SLICE_W]),
+            .ready_out (local_out_if.req_ready)
+        );
+    end
+
+    assign req_global_ready       = g_rdy_in[0];
+    assign global_out_if.req_valid = g_vld_out[0];
+    assign global_out_if.req_data  = global_dout_pad[REQ_DATAW-1:0];
+
+    assign req_local_ready        = l_rdy_in[0];
+    assign local_out_if.req_valid  = l_vld_out[0];
+    assign local_out_if.req_data   = local_dout_pad[REQ_DATAW-1:0];
 
     VX_stream_arb #(
         .NUM_INPUTS (2),

--- a/environment/public/code/VX_local_mem.sv (Buggy Starter)
+++ b/solution/gold/code/VX_local_mem.sv (Golden Reference)
@@ -229,13 +229,21 @@
     //   DMA has priority over LSU at every bank SRAM.
 
     wire dma_rsp_buf_ready; // driven by pipe-buffer or tied 0 when disabled
+    wire [NUM_BANKS-1:0] bank_amo_nxt_busy;
+    (* keep = "true" *) reg [NUM_BANKS:0] dma_amo_blk_r;
+    always @(posedge clk) begin
+        if (reset) dma_amo_blk_r <= '0;
+        else       dma_amo_blk_r <= {(NUM_BANKS+1){|bank_amo_nxt_busy}};
+    end
+    wire dma_amo_conflict = dma_amo_blk_r[NUM_BANKS];
 
     if (DMA_ENABLE) begin : g_dma_enable
         `UNUSED_VAR (dma_bus_if.req_data.attr)
 
-        assign dma_bus_if.req_ready = dma_bus_if.req_data.rw || dma_rsp_buf_ready;
-
-        wire dma_rd_fire = dma_bus_if.req_valid && ~dma_bus_if.req_data.rw && dma_rsp_buf_ready;
+
+        assign dma_bus_if.req_ready = !dma_amo_conflict && (dma_bus_if.req_data.rw || dma_rsp_buf_ready);
+
+        wire dma_rd_fire = dma_bus_if.req_valid && ~dma_bus_if.req_data.rw && dma_rsp_buf_ready && !dma_amo_conflict;
 
         // Delay tag by 1 cycle to align with SRAM OUT_REG latency
         VX_pipe_buffer #(
@@ -260,25 +268,27 @@
         // line. Latch the whole line on the first response-valid cycle (rdata
         // is still valid then) and serve the latched copy while stalled. One
         // DMA response spans all banks, so this is a single full-line hold.
-        reg  [NUM_BANKS-1:0][WORD_WIDTH-1:0] dma_rsp_hold_data_r;
-        reg                                  dma_rsp_hold_valid_r;
         wire dma_rsp_consumed = dma_bus_if.rsp_valid && dma_bus_if.rsp_ready;
-        always @(posedge clk) begin
-            if (reset) begin
-                dma_rsp_hold_valid_r <= 1'b0;
-            end else if (dma_rsp_consumed) begin
-                dma_rsp_hold_valid_r <= 1'b0;
-            end else if (dma_bus_if.rsp_valid && ~dma_rsp_hold_valid_r) begin
-                dma_rsp_hold_data_r  <= per_bank_rsp_data;
-                dma_rsp_hold_valid_r <= 1'b1;
-            end
+        for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_dma_rsp_data
+            (* keep = "true" *) reg [WORD_WIDTH-1:0] dma_rsp_hold_b_data_r;
+            (* keep = "true" *) reg                  dma_rsp_hold_b_valid_r;
+            (* keep = "true" *) wire                 dma_rsp_cap_b = dma_bus_if.rsp_valid && ~dma_rsp_consumed && ~dma_rsp_hold_b_valid_r;
+            always @(posedge clk) begin
+                if (reset || dma_rsp_consumed) begin
+                    dma_rsp_hold_b_valid_r <= 1'b0;
+                end else if (dma_rsp_cap_b) begin
+                    dma_rsp_hold_b_valid_r <= 1'b1;
+                end
+                if (dma_rsp_cap_b) begin
+                    dma_rsp_hold_b_data_r <= per_bank_rsp_data[i];
+                end
+            end
+            assign dma_bus_if.rsp_data.data[i*WORD_WIDTH +: WORD_WIDTH] =
+                dma_rsp_hold_b_valid_r ? dma_rsp_hold_b_data_r : per_bank_rsp_data[i];
         end
-        for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_dma_rsp_data
-            assign dma_bus_if.rsp_data.data[i*WORD_WIDTH +: WORD_WIDTH] =
-                dma_rsp_hold_valid_r ? dma_rsp_hold_data_r[i] : per_bank_rsp_data[i];
-        end
 
     end else begin : g_no_dma
+        assign dma_amo_conflict     = 1'b0;
         assign dma_rsp_buf_ready    = 1'b0;
         assign dma_bus_if.req_ready = 1'b0;
         assign dma_bus_if.rsp_valid = 1'b0;
@@ -302,12 +312,14 @@
         wire dma_wr_b = DMA_ENABLE
                      && dma_bus_if.req_valid
                      && dma_bus_if.req_data.rw
+                     && !dma_amo_blk_r[i]
                      && (|dma_bus_if.req_data.byteen[i*WORD_SIZE +: WORD_SIZE]);
 
         wire dma_rd_b = DMA_ENABLE
                      && dma_bus_if.req_valid
                      && ~dma_bus_if.req_data.rw
-                     && dma_rsp_buf_ready;
+                     && dma_rsp_buf_ready
+                     && !dma_amo_blk_r[i];
 
         wire dma_active = dma_wr_b | dma_rd_b;
 
@@ -430,6 +442,7 @@
             // must not store; every other atomic writes its computed value back.
             assign amo_wb_store = amo_wb_valid_r && ~amo_wb_is_lr_r && ~amo_wb_sc_fail_r;
             assign amo_busy = amo_rd_valid_r || amo_wb_valid_r;
+            assign bank_amo_nxt_busy[i] = amo_accept || amo_rd_valid_r;
 
             always @(posedge clk) begin
                 if (reset) begin
@@ -530,6 +543,7 @@
 
         end else begin : g_no_amo
             assign amo_busy      = 1'b0;
+            assign bank_amo_nxt_busy[i] = 1'b0;
             assign amo_wb_store  = 1'b0;
             assign amo_wb_addr   = '0;
             assign amo_wb_byteen = '0;
@@ -562,12 +576,19 @@
                                : amo_wb_store ? amo_wb_byteen
                                               : per_bank_req_byteen[i];
 
-        assign bank_sram_men_arr[i]  = 1'b1;
-        assign bank_sram_wen_arr[i]  = dma_wr_b || amo_wb_store || (lsu_active && per_bank_req_rw[i]);
-        assign bank_sram_ren_arr[i]  = dma_rd_b || (lsu_active && ~per_bank_req_rw[i]);
+        wire sram_we = dma_wr_b || amo_wb_store || (lsu_active && per_bank_req_rw[i]);
+        wire sram_re = !sram_we && (dma_rd_b || (lsu_active && ~per_bank_req_rw[i]));
+        assign bank_sram_men_arr[i]  = sram_we || sram_re;
+        assign bank_sram_wen_arr[i]  = sram_we;
+        assign bank_sram_ren_arr[i]  = sram_re;
         assign bank_sram_addr_arr[i] = bank_sram_addr;
         assign bank_sram_din_arr[i]  = bank_sram_wdata;
-        assign bank_sram_bm_arr[i]   = {56'd0, bank_sram_wren};
+        assign bank_sram_bm_arr[i]   = {
+            {8{bank_sram_wren[7]}}, {8{bank_sram_wren[6]}},
+            {8{bank_sram_wren[5]}}, {8{bank_sram_wren[4]}},
+            {8{bank_sram_wren[3]}}, {8{bank_sram_wren[2]}},
+            {8{bank_sram_wren[1]}}, {8{bank_sram_wren[0]}}
+        };
 
         // Read-during-write hazard: stalls LSU reads to an address written last cycle
         // (SRAM OUT_REG + RDW_MODE="R" returns stale data on same-cycle read-after-write).

--- a/environment/public/plan/macro_placement.json (Buggy Starter)
+++ b/solution/gold/plan/macro_placement.json (Golden Reference)
@@ -2,51 +2,51 @@
   "macros": [
     {
       "instance": "u_local_mem.u_lmem_bank_0",
-      "x": 900.0,
-      "y": 500.0,
+      "x": 240.0,
+      "y": 140.0,
+      "orientation": "R180"
+    },
+    {
+      "instance": "u_local_mem.u_lmem_bank_1",
+      "x": 240.0,
+      "y": 600.0,
+      "orientation": "MY"
+    },
+    {
+      "instance": "u_local_mem.u_lmem_bank_2",
+      "x": 240.0,
+      "y": 1080.0,
+      "orientation": "R180"
+    },
+    {
+      "instance": "u_local_mem.u_lmem_bank_3",
+      "x": 240.0,
+      "y": 1540.0,
+      "orientation": "MY"
+    },
+    {
+      "instance": "u_local_mem.u_lmem_bank_4",
+      "x": 1570.0,
+      "y": 140.0,
+      "orientation": "MX"
+    },
+    {
+      "instance": "u_local_mem.u_lmem_bank_5",
+      "x": 1570.0,
+      "y": 600.0,
       "orientation": "R0"
     },
     {
-      "instance": "u_local_mem.u_lmem_bank_1",
-      "x": 900.0,
-      "y": 615.0,
-      "orientation": "R0"
-    },
-    {
-      "instance": "u_local_mem.u_lmem_bank_2",
-      "x": 900.0,
-      "y": 760.0,
-      "orientation": "R0"
-    },
-    {
-      "instance": "u_local_mem.u_lmem_bank_3",
-      "x": 900.0,
-      "y": 900.0,
-      "orientation": "R0"
-    },
-    {
-      "instance": "u_local_mem.u_lmem_bank_4",
-      "x": 900.0,
-      "y": 1040.0,
-      "orientation": "R180"
-    },
-    {
-      "instance": "u_local_mem.u_lmem_bank_5",
-      "x": 900.0,
-      "y": 1180.0,
-      "orientation": "R180"
-    },
-    {
       "instance": "u_local_mem.u_lmem_bank_6",
-      "x": 900.0,
-      "y": 1320.0,
-      "orientation": "R180"
+      "x": 1570.0,
+      "y": 1080.0,
+      "orientation": "MX"
     },
     {
       "instance": "u_local_mem.u_lmem_bank_7",
-      "x": 900.0,
-      "y": 1460.0,
-      "orientation": "R180"
+      "x": 1570.0,
+      "y": 1540.0,
+      "orientation": "R0"
     }
   ]
 }

--- a/environment/public/constraints/lmem_subsys.sdc (Buggy Starter)
+++ b/solution/gold/constraints/lmem_subsys.sdc (Golden Reference)
@@ -1,5 +1,5 @@
-# Baseline bring-up constraints (needs tightening for 20.0 ns signoff)
-create_clock -name core_clk -period 24.0 [get_ports clk]
-set_input_delay 0.5 -clock core_clk [all_inputs -no_clocks]
-set_output_delay 0.5 -clock core_clk [all_outputs]
+# Signoff timing constraints for VX_lmem_subsys (IHP SG13G2 130nm)
+create_clock -name core_clk -period 20.0 [get_ports clk]
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
- [`environment/public/code/VX_cache_define.vh`](environment/public/code/VX_cache_define.vh) *(Read-Only Context)*
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
- [`environment/public/code/VX_lmem_subsys.sv`](environment/public/code/VX_lmem_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/VX_lmem_switch.sv`](environment/public/code/VX_lmem_switch.sv) **(Editable)**
- [`environment/public/code/VX_local_mem.sv`](environment/public/code/VX_local_mem.sv) **(Editable)**
- [`environment/public/code/VX_lsu_adapter.sv`](environment/public/code/VX_lsu_adapter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_lsu_mem_if.sv`](environment/public/code/VX_lsu_mem_if.sv) *(Read-Only Context)*
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
- [`environment/public/code/VX_rr_arbiter.sv`](environment/public/code/VX_rr_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scan.sv`](environment/public/code/VX_scan.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scope.vh`](environment/public/code/VX_scope.vh) *(Read-Only Context)*
- [`environment/public/code/VX_shift_register.sv`](environment/public/code/VX_shift_register.sv) *(Read-Only Context)*
- [`environment/public/code/VX_skid_buffer.sv`](environment/public/code/VX_skid_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_sp_ram.sv`](environment/public/code/VX_sp_ram.sv) *(Read-Only Context)*
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
- [`environment/public/constraints/lmem_subsys.sdc`](environment/public/constraints/lmem_subsys.sdc) **(Editable)**
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

