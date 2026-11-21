# `case_23011`: Vortex Multi-Core Split-Phase CTA Barrier & Global Cluster Synchronization Subsystem

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23011` |
| **Source Silicon Repository** | `vortexgpgpu/vortex` (`repo_37`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/VX_bar_unit.sv`](environment/public/code/VX_bar_unit.sv), [`code/VX_gbar_unit.sv`](environment/public/code/VX_gbar_unit.sv), [`code/VX_gbar_arb.sv`](environment/public/code/VX_gbar_arb.sv) (3 files, 542 LOC) |
| **Public Subsystem Context** | 35 RTL files (9585 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `840s` total (`420s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Vortex Multi-Core Split-Phase CTA Barrier & Global Cluster Synchronization

## Subsystem Context
In the Vortex GPGPU cluster synchronization hierarchy (`VX_cluster_bar_subsys`), each SIMT core instantiates `VX_bar_unit` to manage local per-CTA barrier slots and cluster-wide global barriers coordinated across `VX_gbar_arb` and `VX_gbar_unit` over `VX_gbar_bus_if`. Barrier requests operate on a 2-stage read-modify-write pipeline: `read_addr` presents the target barrier slot one cycle ahead of `req_valid` (returning the slot's current odd/even epoch bit combinationally on `read_phase`), followed by `req_valid` with `req_wid` and `req_data` (`barrier_t`: `id`, `is_event`, `is_global`, `is_arrive`, `is_sync`, `phase`, `size_m1`).

Under split-phase SIMT barrier execution, out-of-order asynchronous DMA/tensor-core transaction completions, multi-core subset barriers, and Nangate45 high-frequency static timing signoff (`REQ_OUT_BUF = 0, RSP_OUT_BUF = 0` at the top-level wrapper), the subsystem suffers from premature epoch flips, lost warp wakeups, back-to-back same-slot read-during-write hazards, global broadcast stalls, and setup timing violations.

## Editable Boundary
Only the following three RTL files may be modified:
- `code/VX_bar_unit.sv`
- `code/VX_gbar_unit.sv`
- `code/VX_gbar_arb.sv`

All other files in `code/` (including `VX_cluster_bar_subsys.sv`, `VX_gbar_bus_if.sv`, `VX_gpu_pkg.sv`, and common library primitives) and `lib/` are read-only.

## Architectural, Protocol & PPA/STA Signoff Requirements
1. **Split-Phase Local Barrier Epochs & Back-to-Back Same-Slot Pipelining**:
   - Support non-stalling `BAR.ARRIVE` (`is_arrive=1, is_sync=0`), stalling `BAR.SYNC` (`is_arrive=1, is_sync=1` for `size_m1 + 1` warps), and deferred `BAR.WAIT` (`is_arrive=0, is_event=0` comparing `req_data.phase` against the slot's current epoch). Early-arriving warps may advance into the next barrier epoch before straggler warps execute `BAR.WAIT` for the completed epoch without corrupting the active epoch's waiter set.
   - Sustain back-to-back 1-cycle requests targeting the same `read_addr` slot without losing state updates or returning stale `read_phase` values across consecutive cycles.
   - Never assert `unlock_valid` with an all-zero `unlock_mask` (e.g., when all participating warps used non-stalling arrivals), and never drop warp wakeups when a local slot unlock coincides on the same cycle with a global barrier broadcast unlock on the same core.
2. **Signed Out-of-Order Asynchronous Event Accounting & Multi-Core Global Barriers**:
   - Asynchronous event operations (`is_event=1`: `phase=1` adds `size_m1 + 1` expected transactions; `phase=0` records 1 completed transaction) may arrive in any order relative to one another and relative to warp arrivals—including completions arriving before `phase=1` registration (temporary negative event balance) or all events balancing to zero before any warp arrives. A barrier epoch may complete and toggle its phase only after all participating warps (`size_m1 + 1` locally, or `active_warps` globally) have arrived AND the net signed event balance is zero; asynchronous event packets must never mark `req_wid` as an arrived warp.
   - Support multi-ID and core-subset (`size_m1 + 1 <= NUM_CORES`) global barriers cleanly: duplicate per-core arrivals before completion must not double-count, back-to-back completions across distinct barrier IDs must not overwrite in-flight broadcasts, and non-participating cores executing continuous local `req_valid` traffic (or participating cores accessing unrelated local slots) must not stall global broadcast delivery.
3. **Latch-Free Synthesis & Nangate45 High-Frequency STA/Area Closure**:
   - Synthesize `VX_cluster_bar_subsys` (`NUM_CORES=4, NUM_WARPS=4, NUM_BARRIERS=4, REQ_OUT_BUF=0, RSP_OUT_BUF=0`) via `yosys -m slang` + ABC on `lib/NangateOpenCellLibrary_typical.lib` with zero inferred latches (`$dlatch`) and zero combinational loops.
   - Close post-synthesis OpenROAD static timing with `WNS >= 0.0000 ns` at `1.15 ns` clock period (`0.10 ns` input/output external delays) and total cell area `<= 14,000.00 um^2`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Signoff Reference

## Editable Files
- `code/VX_bar_unit.sv`
- `code/VX_gbar_unit.sv`
- `code/VX_gbar_arb.sv`

## Read-Only Top-Level Subsystem & Collateral
- Top-level wrapper: `code/VX_cluster_bar_subsys.sv`
- Package & bus interface: `code/VX_gpu_pkg.sv`, `code/VX_gbar_bus_if.sv`
- Common macros/primitives: `code/VX_*.vh`, `code/VX_*.sv`, `code/VX_dp_ram_asic.v`
- Standard-cell Liberty / LEF:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Multi-Configuration Functional Verification (`Verilator v5.038`)**:
   - Compile `code/VX_*.sv` and `code/VX_dp_ram_asic.v` with `-DASIC -DSYNTHESIS -DVX_CFG_XLEN=32 -Icode` across:
     - `NUM_CORES=4, NUM_WARPS=4, NUM_BARRIERS=4`
     - `NUM_CORES=2, NUM_WARPS=8, NUM_BARRIERS=4`
2. **Nangate45 Synthesis & OpenROAD STA Signoff**:
   - Elaborate and map `VX_cluster_bar_subsys` (`-DVX_CFG_NUM_CORES=4 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_NUM_BARRIERS=4`) using `yosys -m slang` (`read_slang ... --top VX_cluster_bar_subsys`), enforcing `select -assert-none */t:$dlatch*` and mapping to `lib/NangateOpenCellLibrary_typical.lib`.
   - Run OpenROAD STA at `1.15 ns` clock period (`create_clock -name clk -period 1.15 [get_ports clk]`, `0.10 ns` input/output delays):
     - Setup `WNS >= 0.0000 ns`
     - Synthesized cell area `<= 14000.00 um^2`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/VX_bar_unit.sv (Buggy Starter)
+++ b/solution/gold/code/VX_bar_unit.sv (Golden Reference)
@@ -1,15 +1,5 @@
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
+// Licensed under the Apache License, Version 2.0
 
 `include "VX_define.vh"
 
@@ -17,279 +7,255 @@
     parameter `STRING INSTANCE_ID = "",
     parameter CORE_ID = 0
 ) (
-    input wire                clk,
-    input wire                reset,
+    input  wire                          clk,
+    input  wire                          reset,
 
     // local barrier interface
-    input wire                req_valid,
-    input wire [NW_WIDTH-1:0] req_wid,
-    input barrier_t           req_data,
-    input wire [BAR_ADDR_W-1:0] read_addr, // valid one cycle before req_valid
-    output wire               read_phase,  // asynchronous phase bit return at read_addr
+    input  wire                          req_valid,
+    input  wire [NW_WIDTH-1:0]           req_wid,
+    input  barrier_t                     req_data,
+    input  wire [BAR_ADDR_W-1:0]         read_addr,
+    output wire                          read_phase,
 
     // global barrier interface
-    VX_gbar_bus_if.master gbar_bus_if,
+    VX_gbar_bus_if.master                gbar_bus_if,
 
     // scheduler interface
-    input wire [`VX_CFG_NUM_WARPS-1:0] active_warps,
-    output wire               unlock_valid, // unlock stalled warps
-    output wire [`VX_CFG_NUM_WARPS-1:0] unlock_mask // warps to unlock
+    input  wire [`VX_CFG_NUM_WARPS-1:0]  active_warps,
+    output wire                          unlock_valid,
+    output wire [`VX_CFG_NUM_WARPS-1:0]  unlock_mask
 );
     `UNUSED_SPARAM (INSTANCE_ID)
     `UNUSED_PARAM (CORE_ID)
 
-    //                    warp mask + warp count + event count
-    localparam EVENT_WIDTH = `CLOG2(`VX_CFG_MAX_BAR_EVENTS + 1);
-    localparam BAR_STATEW = `VX_CFG_NUM_WARPS + NW_WIDTH + EVENT_WIDTH;
-    localparam GBAR_REQW = NB_WIDTH + NC_WIDTH;
-    localparam USE_GBAR = (`VX_CFG_NUM_CORES > 1);
-
-    logic [`VX_CFG_NUM_WARPS-1:0] mask_r, mask_n;
-    logic [NW_WIDTH-1:0]   count_r, count_n;
-    logic [EVENT_WIDTH-1:0] events_r, events_n;
-    logic                  phase_r, phase_n;
-
-    logic                  unlock_valid_n;
-    logic [`VX_CFG_NUM_WARPS-1:0] unlock_mask_n;
-
-    // A response carries only its id after the barrier-store read port has moved on.
+    localparam NUM_SLOTS   = (1 << BAR_ADDR_BITS);
+    // +1 sign bit for signed out-of-order expect_tx / txbar event accounting
+    localparam EVENT_WIDTH = `CLOG2(`VX_CFG_MAX_BAR_EVENTS + 1) + 1;
+    localparam BAR_STATEW  = 1 + `VX_CFG_NUM_WARPS + NW_WIDTH + EVENT_WIDTH;
+    localparam GBAR_REQW   = NB_WIDTH + NC_WIDTH;
+    localparam USE_GBAR    = (`VX_CFG_NUM_CORES > 1);
+
+    logic                          warps_done_r, warps_done_n;
+    logic [`VX_CFG_NUM_WARPS-1:0]  mask_r, mask_n;
+    logic [NW_WIDTH-1:0]           count_r, count_n;
+    logic signed [EVENT_WIDTH-1:0] events_r, events_n;
+    logic                          phase_r, phase_n;
+
+    logic                          local_unlock_v, gbar_unlock_v;
+    logic [`VX_CFG_NUM_WARPS-1:0]  local_unlock_m, gbar_unlock_m;
+
     logic [`VX_CFG_NUM_BARRIERS-1:0] gbar_pending_r, gbar_pending_n;
     logic [`VX_CFG_NUM_BARRIERS-1:0] gbar_pending_phase_r, gbar_pending_phase_n;
     logic [`VX_CFG_NUM_BARRIERS-1:0][`VX_CFG_NUM_WARPS-1:0] gbar_waiters_r, gbar_waiters_n;
 
-    logic gbar_enqueue;
+    logic                gbar_enqueue;
     logic [NB_WIDTH-1:0] gbar_enqueue_id;
     logic [NC_WIDTH-1:0] gbar_enqueue_size_m1;
 
-    wire gbar_rsp_ready = ~req_valid;
-    wire gbar_rsp_fire = gbar_bus_if.rsp_valid && gbar_rsp_ready;
-    wire gbar_rsp_apply = USE_GBAR && gbar_rsp_fire && gbar_pending_r[gbar_bus_if.rsp_data.id];
-
-    wire [`VX_CFG_NUM_WARPS-1:0] wait_mask = ((`VX_CFG_NUM_WARPS)'(1) << req_wid) | mask_r;
-    wire [NW_WIDTH-1:0] next_count  = count_r + NW_WIDTH'(1);
-    wire next_phase  = ~phase_r;
+    reg [BAR_ADDR_W-1:0] store_waddr;
+    wire [BAR_ADDR_W-1:0] rsp_slot_addr = BAR_ADDR_W'(gbar_bus_if.rsp_data.id);
+    wire rsp_is_pending = USE_GBAR && gbar_pending_r[gbar_bus_if.rsp_data.id];
+    // Non-participating cores never stall global barrier broadcasts; participating cores
+    // only stall if the exact same barrier slot is simultaneously being written by req_valid.
+    wire gbar_rsp_ready = ~rsp_is_pending || ~(req_valid && (store_waddr == rsp_slot_addr));
+    wire gbar_rsp_fire  = gbar_bus_if.rsp_valid && gbar_rsp_ready;
+    wire gbar_rsp_apply = rsp_is_pending && gbar_rsp_fire;
+
+    wire [`VX_CFG_NUM_WARPS-1:0] wid_bit   = ((`VX_CFG_NUM_WARPS)'(1) << req_wid);
+    wire [`VX_CFG_NUM_WARPS-1:0] wait_mask = wid_bit | mask_r;
+    wire [NW_WIDTH-1:0]          next_count = count_r + NW_WIDTH'(1);
+    wire                         next_phase = ~phase_r;
+    wire signed [EVENT_WIDTH-1:0] ev_delta_pos = $signed({1'b0, req_data.size_m1}) + EVENT_WIDTH'(1);
 
     always @(*) begin
-        mask_n  = mask_r;
-        count_n = count_r;
-        events_n = events_r;
-        phase_n = phase_r;
-        unlock_valid_n = 0;
-        unlock_mask_n = 'x;
-        gbar_pending_n = gbar_pending_r;
+        warps_done_n         = warps_done_r;
+        mask_n               = mask_r;
+        count_n              = count_r;
+        events_n             = events_r;
+        phase_n              = phase_r;
+        local_unlock_v       = 1'b0;
+        local_unlock_m       = '0;
+        gbar_unlock_v        = 1'b0;
+        gbar_unlock_m        = '0;
+        gbar_pending_n       = gbar_pending_r;
         gbar_pending_phase_n = gbar_pending_phase_r;
-        gbar_waiters_n = gbar_waiters_r;
-        gbar_enqueue = 0;
-        gbar_enqueue_id = 'x;
-        gbar_enqueue_size_m1 = 'x;
-
-        // local barrier scheduling
+        gbar_waiters_n       = gbar_waiters_r;
+        gbar_enqueue         = 1'b0;
+        gbar_enqueue_id      = '0;
+        gbar_enqueue_size_m1 = '0;
+
         if (req_valid && ~req_data.is_global) begin
             if (req_data.is_event) begin
-                // event tracking
-                if (req_data.phase) begin
-                    // attach/expect_tx: increment by (size_m1 + 1) so that
-                    // a software expect_tx(N) adds N events, while ordinary
-                    // single-event paths (size_m1=0) add 1.
-                    events_n = events_r + EVENT_WIDTH'(req_data.size_m1) + EVENT_WIDTH'(1);
-                end else begin
-                    events_n = events_r - EVENT_WIDTH'(1);
-                end
-                // unlock warps if decrementing event to 0 and all all warps have arrived
-                if ((req_data.phase == 0) && (events_r == EVENT_WIDTH'(1)) && (count_r == 0)) begin
-                    mask_n = '0;
-                    unlock_valid_n = 1; // release waiting warps
-                    unlock_mask_n = mask_r;
-                    phase_n = next_phase; // advance phase
+                events_n = req_data.phase ? (events_r + ev_delta_pos) : (events_r - EVENT_WIDTH'(1));
+                if (warps_done_r && (events_n == '0)) begin
+                    warps_done_n   = 1'b0;
+                    count_n        = '0;
+                    mask_n         = '0;
+                    phase_n        = next_phase;
+                    local_unlock_v = (mask_r != '0);
+                    local_unlock_m = mask_r;
                 end
             end else if (req_data.is_arrive) begin
-                // barrier arrival
                 if (count_r == NW_WIDTH'(req_data.size_m1)) begin
                     count_n = '0;
-                    if (events_r == 0) begin
-                        mask_n = '0;
-                        unlock_valid_n = 1; // release waiting warps
-                        unlock_mask_n = req_data.is_sync ? wait_mask : mask_r;
-                        phase_n = next_phase; // advance phase
-                    end else if (req_data.is_sync) begin
-                        // Add arriving warp to wait mask
-                        mask_n = wait_mask;
+                    if (events_r == '0) begin
+                        logic [`VX_CFG_NUM_WARPS-1:0] rel_m;
+                        rel_m          = req_data.is_sync ? wait_mask : mask_r;
+                        warps_done_n   = 1'b0;
+                        mask_n         = '0;
+                        phase_n        = next_phase;
+                        local_unlock_v = (rel_m != '0);
+                        local_unlock_m = rel_m;
+                    end else begin
+                        warps_done_n = 1'b1;
+                        if (req_data.is_sync) mask_n = wait_mask;
                     end
                 end else begin
                     count_n = next_count;
-                    if (req_data.is_sync) begin
-                        mask_n = wait_mask;
-                    end
+                    if (req_data.is_sync) mask_n = wait_mask;
                 end
             end else begin
-                // barrier waiting
                 if (req_data.phase != phase_r) begin
-                    unlock_valid_n = 1; // release warp
-                    unlock_mask_n = (`VX_CFG_NUM_WARPS)'(1) << req_wid;
+                    local_unlock_v = 1'b1;
+                    local_unlock_m = wid_bit;
                 end else begin
-                    // add warp to wait list
                     mask_n = wait_mask;
                 end
             end
         end
+
         if (USE_GBAR) begin
-            // global barrier scheduling
             if (req_valid && req_data.is_global) begin
                 if (req_data.is_event) begin
-                    // event tracking
-                    if (req_data.phase) begin
-                        // expect_tx(N): add (size_m1 + 1)
-                        events_n = events_r + EVENT_WIDTH'(req_data.size_m1) + EVENT_WIDTH'(1);
-                    end else begin
-                        events_n = events_r - EVENT_WIDTH'(1);
-                    end
-                    // unlock warps if decrementing event to 0 and all warps have arrived
-                    if ((req_data.phase == 0) && (events_r == EVENT_WIDTH'(1)) && (wait_mask == active_warps)) begin
-                        mask_n = '0;
-                        gbar_enqueue = 1; // notify global barrier
-                        gbar_enqueue_id = req_data.id;
-                        gbar_enqueue_size_m1 = NC_WIDTH'(count_r); // was saved in barrier_arrive
+                    events_n = req_data.phase ? (events_r + ev_delta_pos) : (events_r - EVENT_WIDTH'(1));
+                    if ((events_n == '0) && (active_warps != '0) && (mask_r == active_warps)) begin
+                        mask_n               = '0;
+                        warps_done_n         = 1'b0;
+                        gbar_enqueue         = 1'b1;
+                        gbar_enqueue_id      = req_data.id;
+                        gbar_enqueue_size_m1 = NC_WIDTH'(count_r);
                     end
                 end else if (req_data.is_arrive) begin
-                    // barrier arrival
-                    count_n = NW_WIDTH'(req_data.size_m1); // store participating number of cores
+                    count_n = NW_WIDTH'(req_data.size_m1);
                     if (req_data.is_sync) begin
-                        gbar_waiters_n[req_data.id][req_wid] = 1;
-                    end
-                    if (wait_mask == active_warps && events_r == 0) begin
-                        mask_n = '0;
-                        gbar_enqueue = 1; // notify global barrier
-                        gbar_enqueue_id = req_data.id;
+                        gbar_waiters_n[req_data.id][req_wid] = 1'b1;
+                    end
+                    if ((active_warps != '0) && (wait_mask == active_warps) && (events_r == '0)) begin
+                        mask_n               = '0;
+                        warps_done_n         = 1'b0;
+                        gbar_enqueue         = 1'b1;
+                        gbar_enqueue_id      = req_data.id;
                         gbar_enqueue_size_m1 = NC_WIDTH'(req_data.size_m1);
                     end else begin
-                        // Add arriving warp to arrival mask
                         mask_n = wait_mask;
                     end
                 end else begin
-                    // barrier waiting
                     if (req_data.phase != phase_r) begin
-                        unlock_valid_n = 1; // release warp
-                        unlock_mask_n = (`VX_CFG_NUM_WARPS)'(1) << req_wid;
+                        local_unlock_v = 1'b1;
+                        local_unlock_m = wid_bit;
                     end else begin
-                        // add warp to wait list
-                        gbar_waiters_n[req_data.id][req_wid] = 1;
-                    end
-                end
-            end
-
-            // global barrier response handling
+                        gbar_waiters_n[req_data.id][req_wid] = 1'b1;
+                    end
+                end
+            end
+
             if (gbar_rsp_apply) begin
-                unlock_valid_n = (gbar_waiters_r[gbar_bus_if.rsp_data.id] != '0);
-                unlock_mask_n = gbar_waiters_r[gbar_bus_if.rsp_data.id];
+                gbar_unlock_v = (gbar_waiters_r[gbar_bus_if.rsp_data.id] != '0);
+                gbar_unlock_m = gbar_waiters_r[gbar_bus_if.rsp_data.id];
                 gbar_waiters_n[gbar_bus_if.rsp_data.id] = '0;
-                gbar_pending_n[gbar_bus_if.rsp_data.id] = 0;
+                gbar_pending_n[gbar_bus_if.rsp_data.id] = 1'b0;
             end
 
             if (gbar_enqueue) begin
-                gbar_pending_n[gbar_enqueue_id] = 1;
+                gbar_pending_n[gbar_enqueue_id]       = 1'b1;
                 gbar_pending_phase_n[gbar_enqueue_id] = phase_r;
             end
         end
     end
 
-    // Barriers store
     wire [BAR_STATEW-1:0] store_state_rdata;
-    wire                  store_phase_rdata;
-    wire [BAR_ADDR_W-1:0] store_raddr = read_addr;
-    reg [BAR_ADDR_W-1:0]  store_waddr;
-    wire [BAR_STATEW-1:0] store_state_wdata = {mask_n, count_n, events_n};
+    wire [BAR_STATEW-1:0] store_state_wdata = {warps_done_n, mask_n, count_n, events_n};
     wire                  store_state_write = req_valid;
-    wire [BAR_ADDR_W-1:0] store_phase_waddr = gbar_rsp_apply ? BAR_ADDR_W'(gbar_bus_if.rsp_data.id) : store_waddr;
-    wire                  store_phase_wdata = gbar_rsp_apply ? ~gbar_pending_phase_r[gbar_bus_if.rsp_data.id] : phase_n;
-    wire                  store_phase_write = req_valid || gbar_rsp_apply;
 
     VX_dp_ram #(
         .DATAW    (BAR_STATEW),
-        .SIZE     (1 << BAR_ADDR_BITS),
+        .SIZE     (NUM_SLOTS),
         .RDW_MODE ("W"),
-        .OUT_REG  (1)
+        .LUTRAM   (1),
+        .OUT_REG  (0)
     ) barrier_state_store (
         .clk   (clk),
         .reset (reset),
         .read  (1'b1),
         .write (store_state_write),
         .wren  (1'b1),
-        .raddr (store_raddr),
+        .raddr (read_addr),
         .waddr (store_waddr),
         .wdata (store_state_wdata),
         .rdata (store_state_rdata)
     );
 
-    VX_dp_ram #(
-        .DATAW    (1),
-        .SIZE     (1 << BAR_ADDR_BITS),
-        .RDW_MODE ("W"),
-        .RADDR_REG(1)
-    ) barrier_phase_store (
-        .clk   (clk),
-        .reset (reset),
-        .read  (1'b1),
-        .write (store_phase_write),
-        .wren  (1'b1),
-        .raddr (store_raddr),
-        .waddr (store_phase_waddr),
-        .wdata (store_phase_wdata),
-        .rdata (store_phase_rdata)
-    );
-
-    // Store reset handling
-    reg [(1 << BAR_ADDR_BITS)-1:0] store_valids;
-    wire is_phase_rdw_hazard = store_phase_write && (store_phase_waddr == store_raddr);
-
-    wire store_phase_rdata_v = store_valids[store_raddr] ? store_phase_rdata : '0;
+    reg [NUM_SLOTS-1:0]  store_valids;
+    reg [NUM_SLOTS-1:0]  phase_vec_r;
+    reg [BAR_STATEW-1:0] state_r;
+
+    wire rsp_phase_hit = gbar_rsp_apply && (rsp_slot_addr == read_addr);
+    wire req_phase_hit = req_valid && (store_waddr == read_addr);
+    wire phase_comb    = rsp_phase_hit ? ~gbar_pending_phase_r[gbar_bus_if.rsp_data.id]
+                       : (req_phase_hit ? phase_n : phase_vec_r[read_addr]);
+    wire [BAR_STATEW-1:0] state_next_rd = req_phase_hit ? store_state_wdata
+                                        : (store_valids[read_addr] ? store_state_rdata : '0);
 
     always @(posedge clk) begin
         if (reset) begin
             store_valids <= '0;
-            phase_r <= '0;
+            phase_vec_r  <= '0;
+            phase_r      <= 1'b0;
+            store_waddr  <= '0;
+            state_r      <= '0;
         end else begin
             if (store_state_write) begin
                 store_valids[store_waddr] <= 1'b1;
-            end
-            phase_r <= is_phase_rdw_hazard ? store_phase_wdata : store_phase_rdata_v;
-        end
-        store_waddr <= store_raddr;
-    end
-
-    assign {mask_r, count_r, events_r} = store_valids[store_waddr] ? store_state_rdata : '0;
-
-    wire phase_async = is_phase_rdw_hazard ? store_phase_wdata : store_phase_rdata_v;
-
-    reg unlock_valid_r;
-    reg [`VX_CFG_NUM_WARPS-1:0] unlock_mask_r;
+                phase_vec_r[store_waddr]  <= phase_n;
+            end
+            if (gbar_rsp_apply) begin
+                phase_vec_r[rsp_slot_addr] <= ~gbar_pending_phase_r[gbar_bus_if.rsp_data.id];
+            end
+            phase_r     <= phase_comb;
+            store_waddr <= read_addr;
+            state_r     <= state_next_rd;
+        end
+    end
+
+    assign {warps_done_r, mask_r, count_r, events_r} = state_r;
+
+    reg                          unlock_valid_r;
+    reg [`VX_CFG_NUM_WARPS-1:0]  unlock_mask_r;
+    wire                         unlock_valid_n = local_unlock_v || gbar_unlock_v;
+    wire [`VX_CFG_NUM_WARPS-1:0] unlock_mask_n  = (local_unlock_v ? local_unlock_m : '0)
+                                                | (gbar_unlock_v  ? gbar_unlock_m  : '0);
 
     always @(posedge clk) begin
         if (reset) begin
-            unlock_valid_r <= 0;
-        end else begin
-            unlock_valid_r <= unlock_valid_n;
-        end
-        unlock_mask_r <= unlock_mask_n;
-    end
-
-    assign read_phase   = phase_async;
-    assign unlock_valid = unlock_valid_r;
-    assign unlock_mask  = unlock_mask_r;
-
-    always @(posedge clk) begin
-        if (reset) begin
+            unlock_valid_r <= 1'b0;
+            unlock_mask_r  <= '0;
             gbar_pending_r <= '0;
             gbar_pending_phase_r <= '0;
             gbar_waiters_r <= '0;
         end else begin
+            unlock_valid_r <= unlock_valid_n;
+            unlock_mask_r  <= unlock_mask_n;
             gbar_pending_r <= gbar_pending_n;
             gbar_pending_phase_r <= gbar_pending_phase_n;
             gbar_waiters_r <= gbar_waiters_n;
         end
     end
 
+    assign read_phase   = phase_comb;
+    assign unlock_valid = unlock_valid_r;
+    assign unlock_mask  = unlock_mask_r;
+
     if (USE_GBAR) begin : g_gbar
-
         wire [GBAR_REQW-1:0] req_queue_data;
         wire req_empty, req_alm_empty;
         wire req_pop = ~req_empty && gbar_bus_if.req_ready;
@@ -299,71 +265,35 @@
             .DEPTH  (1 << NB_WIDTH),
             .LUTRAM (1)
         ) req_queue (
-            .clk     (clk),
-            .reset   (reset),
-            .push    (gbar_enqueue),
-            .pop     (req_pop),
-            .data_in ({gbar_enqueue_id, gbar_enqueue_size_m1}),
-            .data_out(req_queue_data),
-            .empty   (req_empty),
+            .clk      (clk),
+            .reset    (reset),
+            .push     (gbar_enqueue),
+            .pop      (req_pop),
+            .data_in  ({gbar_enqueue_id, gbar_enqueue_size_m1}),
+            .data_out (req_queue_data),
+            .empty    (req_empty),
             .alm_empty(req_alm_empty),
             `UNUSED_PIN (alm_full),
             `UNUSED_PIN (full),
             `UNUSED_PIN (size)
         );
 
-        // The queue's empty flag is already a register, but inverting it for the
-        // outgoing valid leaves a combinational cell on a net that crosses the
-        // core, socket and cluster boundaries. Track non-emptiness in its own
-        // flop: same next state on the same edge, so the request still leaves
-        // one cycle after the arrival that produced it.
         reg gbar_req_valid_r;
-
         always @(posedge clk) begin
-            if (reset) begin
-                gbar_req_valid_r <= 0;
-            end else begin
-                gbar_req_valid_r <= gbar_enqueue | (req_pop ? ~req_alm_empty : ~req_empty);
-            end
+            if (reset) gbar_req_valid_r <= 1'b0;
+            else       gbar_req_valid_r <= gbar_enqueue | (req_pop ? ~req_alm_empty : ~req_empty);
         end
 
         assign gbar_bus_if.req_valid        = gbar_req_valid_r;
         assign {gbar_bus_if.req_data.id, gbar_bus_if.req_data.size_m1} = req_queue_data;
         assign gbar_bus_if.req_data.core_id = NC_WIDTH'(CORE_ID % `VX_CFG_NUM_CORES);
         assign gbar_bus_if.rsp_ready        = gbar_rsp_ready;
-
-        `RUNTIME_ASSERT(~gbar_enqueue || ~gbar_pending_r[gbar_enqueue_id], ("%s duplicate global barrier generation: id=%0d", INSTANCE_ID, gbar_enqueue_id))
-        `RUNTIME_ASSERT(~gbar_enqueue || (store_waddr == BAR_ADDR_W'(gbar_enqueue_id)), ("%s invalid global barrier slot: id=%0d, slot=%0d", INSTANCE_ID, gbar_enqueue_id, store_waddr))
     end else begin : g_nogbar
-
-        assign gbar_bus_if.req_valid = 0;
-        assign gbar_bus_if.req_data  = 'x;
-        assign gbar_bus_if.rsp_ready = 0;
-
+        assign gbar_bus_if.req_valid = 1'b0;
+        assign gbar_bus_if.req_data  = '0;
+        assign gbar_bus_if.rsp_ready = 1'b0;
         `UNUSED_VAR (gbar_bus_if.req_ready)
         `UNUSED_VAR (gbar_enqueue_size_m1)
-
-    end
-
-`ifdef DBG_TRACE_PIPELINE
-    always @(posedge clk) begin
-        if (req_valid) begin
-            `TRACE(2, ("%t: %s req: wid=%0d, bar_id=%0d, is_global=%b, is_event=%b, is_arrive=%b, is_sync=%b, phase=%b, size_m1=%0d\n",
-                $time, INSTANCE_ID, req_wid, req_data.id, req_data.is_global, req_data.is_event, req_data.is_arrive, req_data.is_sync, req_data.phase, req_data.size_m1))
-        end
-        if (USE_GBAR && gbar_bus_if.req_valid && gbar_bus_if.req_ready) begin
-            `TRACE(2, ("%t: %s global-req: bar_id=%0d, size_m1=%0d\n",
-                $time, INSTANCE_ID, gbar_bus_if.req_data.id, gbar_bus_if.req_data.size_m1))
-        end
-        if (USE_GBAR && gbar_bus_if.rsp_valid && gbar_rsp_ready) begin
-            `TRACE(2, ("%t: %s global-rsp: bar_id=%0d\n",
-                $time, INSTANCE_ID, gbar_bus_if.rsp_data.id))
-        end
-        if (unlock_valid_n) begin
-            `TRACE(2, ("%t: %s unlock: mask=%b\n",
-                $time, INSTANCE_ID, unlock_mask_n))
-        end
-    end
-`endif
+    end
 
 endmodule

--- a/environment/public/code/VX_gbar_unit.sv (Buggy Starter)
+++ b/solution/gold/code/VX_gbar_unit.sv (Golden Reference)
@@ -1,80 +1,66 @@
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
+// Licensed under the Apache License, Version 2.0
 
 `include "VX_define.vh"
 
 module VX_gbar_unit import VX_gpu_pkg::*; #(
     parameter `STRING INSTANCE_ID = ""
 ) (
-    input wire clk,
-    input wire reset,
-
-    VX_gbar_bus_if.slave gbar_bus_if
+    input  wire            clk,
+    input  wire            reset,
+    VX_gbar_bus_if.slave   gbar_bus_if
 );
     `UNUSED_SPARAM (INSTANCE_ID)
 
+    localparam CORE_CNT_W = `CLOG2(`VX_CFG_NUM_CORES + 1);
+
     reg [`VX_CFG_NUM_BARRIERS-1:0][`VX_CFG_NUM_CORES-1:0] barrier_masks;
-    wire [`CLOG2(`VX_CFG_NUM_CORES+1)-1:0] active_barrier_count;
     wire [NB_
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/VX_async_ram_patch.sv`](environment/public/code/VX_async_ram_patch.sv) *(Read-Only Context)*
- [`environment/public/code/VX_bar_unit.sv`](environment/public/code/VX_bar_unit.sv) **(Editable)**
- [`environment/public/code/VX_cluster_bar_subsys.sv`](environment/public/code/VX_cluster_bar_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/VX_config.vh`](environment/public/code/VX_config.vh) *(Read-Only Context)*
- [`environment/public/code/VX_cyclic_arbiter.sv`](environment/public/code/VX_cyclic_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_define.vh`](environment/public/code/VX_define.vh) *(Read-Only Context)*
- [`environment/public/code/VX_dp_ram.sv`](environment/public/code/VX_dp_ram.sv) *(Read-Only Context)*
- [`environment/public/code/VX_dp_ram_asic.v`](environment/public/code/VX_dp_ram_asic.v) *(Read-Only Context)*
- [`environment/public/code/VX_elastic_buffer.sv`](environment/public/code/VX_elastic_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_fifo_queue.sv`](environment/public/code/VX_fifo_queue.sv) *(Read-Only Context)*
- [`environment/public/code/VX_find_first.sv`](environment/public/code/VX_find_first.sv) *(Read-Only Context)*
- [`environment/public/code/VX_gbar_arb.sv`](environment/public/code/VX_gbar_arb.sv) **(Editable)**
- [`environment/public/code/VX_gbar_bus_if.sv`](environment/public/code/VX_gbar_bus_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_gbar_unit.sv`](environment/public/code/VX_gbar_unit.sv) **(Editable)**
- [`environment/public/code/VX_generic_arbiter.sv`](environment/public/code/VX_generic_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_gpu_pkg.sv`](environment/public/code/VX_gpu_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/VX_lzc.sv`](environment/public/code/VX_lzc.sv) *(Read-Only Context)*
- [`environment/public/code/VX_matrix_arbiter.sv`](environment/public/code/VX_matrix_arbiter.sv) *(Read-Only Context)*
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
- [`environment/public/code/VX_skid_buffer.sv`](environment/public/code/VX_skid_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_arb.sv`](environment/public/code/VX_stream_arb.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_buffer.sv`](environment/public/code/VX_stream_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_fork.sv`](environment/public/code/VX_stream_fork.sv) *(Read-Only Context)*
- [`environment/public/code/VX_types.vh`](environment/public/code/VX_types.vh) *(Read-Only Context)*
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

