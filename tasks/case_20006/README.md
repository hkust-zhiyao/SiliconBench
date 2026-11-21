# `case_20006`: Fix Parameterized Synthesis/Simulation Parity, Miss-Counter Saturation, BIST Drain, and SPM Way Isolation in axi_llc_hit_miss

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_20006` |
| **Source Silicon Repository** | `pulp-platform/axi_llc` (`repo_26`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/axi_llc_miss_counters.sv`](environment/public/code/rtl/axi_llc_miss_counters.sv), [`code/rtl/axi_llc_tag_pattern_gen.sv`](environment/public/code/rtl/axi_llc_tag_pattern_gen.sv), [`code/rtl/axi_llc_hit_miss.sv`](environment/public/code/rtl/axi_llc_hit_miss.sv) (3 files, 779 LOC) |
| **Public Subsystem Context** | 27 RTL files (5384 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Fix Parameterized Synthesis/Simulation Parity, Miss-Counter Saturation, BIST Drain, and SPM Way Isolation in `axi_llc_hit_miss`

## Problem Summary
The PULP AXI4 Last-Level Cache hit/miss detection subsystem (`axi_llc_hit_miss.sv`, `axi_llc_miss_counters.sv`, and `axi_llc_tag_pattern_gen.sv`) exhibits elaboration failures, RTL-vs-gate-level simulation parity hazards, and architectural deadlocks/aliasing across parameterized configurations.

## Architectural & Synthesis-Parity Contract

1. **Parameterized Elaboration & Gate-Level Synthesis Parity**:
   - `axi_llc_hit_miss`, `axi_llc_miss_counters`, and `axi_llc_tag_pattern_gen` must elaborate and synthesize cleanly (`yosys -m slang` and Verilator) with zero inferred latches and zero combinational loops across `AxiIdLookupBits == 0` (single shared miss counter), `0 < AxiIdLookupBits < AxiCfg.SlvPortIdWidth` (low-bit AXI ID folding), and `AxiIdLookupBits == AxiCfg.SlvPortIdWidth` (per-ID counters).
   - Post-synthesis gate-level behavior must match RTL cycle-for-cycle.

2. **In-Flight Miss Counter Saturation, Boundary Clamping, and Steering**:
   - Each per-ID-bucket counter (capacity `2**axi_llc_pkg::MissCntWidth`) and the global write counter (capacity `2**axi_llc_pkg::MissCntMaxWWidth`) must assert `stall_o` when any counter reaches full capacity.
   - `to_miss_o` must remain asserted (`1'b1`) whenever the mapped bucket counter is non-zero—**including when saturated at `2**MissCntWidth`**—and, for write descriptors (`rw == 1'b1`), whenever the global write counter is non-zero (**including when saturated at `2**MissCntMaxWWidth`**).
   - Counters must hold steady under simultaneous matching increment/decrement handshakes, clamp without wrap-around or underflow at `0` and `2**Width` boundaries, and avoid combinational paths from `cnt_up_i.valid` / `cnt_down_i.valid` into `to_miss_o` or `stall_o`.

3. **March-X Tag BIST Multi-Cycle Drain & 4-State Qualification**:
   - Across arbitrary read latencies (`TagMacroLatency >= 1`, including `TagMacroLatency >= Cfg.NumLines`), `axi_llc_tag_pattern_gen` must check all `Cfg.NumLines` ascending and descending read responses—including trailing pipeline-drain beats—drive the expected pattern consistently throughout each read phase, qualify sticky per-way failure accumulation (`bist_res_o`) strictly with `bist_res_valid_i` so uninitialized/`X` buses never corrupt results, and reset sticky status/`eoc_o` cleanly if BIST is re-invoked.

4. **SPM / Flushed Way Isolation & Zero-Cache-Way Error Steering**:
   - Normal cache lookups (`!spm && !flush`) must never hit or allocate ways marked in `spm_lock_i` or `flushed_i`.
   - When all ways are locked as SPM or flushed (`(spm_lock_i | flushed_i) == '1`), normal cache lookups must not deadlock tag lookup/eviction; instead, they must complete in-order (`hit_valid_o` vs `miss_valid_o` governed by `to_miss`, respecting line locks and `cnt_stall`) with `x_resp = axi_pkg::RESP_SLVERR`, `evict = 1'b0`, `refill = 1'b0`, and `way_ind = way_ind_t'(1)`.

## Scope & Deliverables
- Editable files: `code/rtl/axi_llc_miss_counters.sv`, `code/rtl/axi_llc_tag_pattern_gen.sv`, and `code/rtl/axi_llc_hit_miss.sv`.
- Preserve all module names, parameter signatures, port interfaces, and read-only collateral in `code/`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment

## Editable RTL
- `code/rtl/axi_llc_miss_counters.sv`
- `code/rtl/axi_llc_tag_pattern_gen.sv`
- `code/rtl/axi_llc_hit_miss.sv`

## Read-Only Context & Dependencies
- `code/rtl/axi_llc_pkg.sv`, `code/rtl/axi_llc_tag_store.sv`, `code/rtl/axi_llc_evict_box.sv`, `code/rtl/axi_llc_lock_box_bloom.sv`, `code/rtl/tc_sram.sv`
- `code/common_cells/` and `code/axi/`

## Toolchain
- SystemVerilog Simulation: `verilator`
  ```bash
  verilator --binary --timing -Wno-fatal -j 1 \
    +incdir+code/common_cells/include +incdir+code/axi/include \
    code/common_cells/src/cb_filter_pkg.sv \
    code/common_cells/src/cf_math_pkg.sv \
    code/axi/src/axi_pkg.sv \
    code/rtl/axi_llc_pkg.sv \
    code/common_cells/src/delta_counter.sv \
    code/common_cells/src/counter.sv \
    code/common_cells/src/lzc.sv \
    code/common_cells/src/onehot_to_bin.sv \
    code/common_cells/src/fifo_v3.sv \
    code/common_cells/src/rr_arb_tree.sv \
    code/common_cells/src/shift_reg_gated.sv \
    code/common_cells/src/shift_reg.sv \
    code/common_cells/src/spill_register_flushable.sv \
    code/common_cells/src/spill_register.sv \
    code/common_cells/src/sub_per_hash.sv \
    code/common_cells/src/cb_filter.sv \
    code/rtl/tc_sram.sv \
    code/rtl/axi_llc_miss_counters.sv \
    code/rtl/axi_llc_tag_pattern_gen.sv \
    code/rtl/axi_llc_evict_box.sv \
    code/rtl/axi_llc_tag_store.sv \
    code/rtl/axi_llc_lock_box_bloom.sv \
    code/rtl/axi_llc_hit_miss.sv
  ```
- SystemVerilog Synthesis (`yosys+slang`): `yosys -m slang`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/axi_llc_miss_counters.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_miss_counters.sv (Golden Reference)
@@ -1,94 +1,99 @@
 // Copyright 2022 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Wolfgang Roenninger <wroennin@iis.ee..ethz.ch>
-// Date:   12.06.2019
 
-/// This module counts if there are any descriptors of a given transaction ID
-/// in the miss pipeline, and combinationally counts up of down the respective ID
-/// of the cnt_t struct matches. There is a counter for all id's and one for writes
-/// as all writes have to be transferred in order.
 module axi_llc_miss_counters #(
-  /// Static LLC parameter configuration.
   parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
-  /// Counter request type.
-  ///
-  /// typedef struct packed {
-  ///   axi_slv_id_t id;        // AXI ID of the descriptor operating the counter
-  ///   logic        rw;        // 0:read, 1:write
-  ///   logic        valid;     // valid, equals enable of the counter
-  /// } cnt_t;
   parameter type cnt_t  = logic,
-  /// Number of low AXI ID bits used to select a miss counter.
   parameter int unsigned AxiIdLookupBits = 32'd0
 ) (
-  /// Clock, positive edge triggered.
   input  logic clk_i,
-  /// Asynchronous reset, active low.
   input  logic rst_ni,
-  /// The descriptor gets transferred into the miss pipeline.
   input  cnt_t cnt_up_i,
-  /// The descriptor gets transferred out of the miss pipeline.
   input  cnt_t cnt_down_i,
-  /// Tells that a descriptor should go to the miss pipeline.
   output logic to_miss_o,
-  /// One of the counters is overflowing, stall descriptor!
   output logic stall_o
 );
-  localparam int unsigned NoCounters = 2**AxiIdLookupBits;
-  // stall signal for each counter (no minus 1, because the write counter is extra )
+  localparam int unsigned NoCounters = 32'd1 << AxiIdLookupBits;
+  localparam int unsigned IdWidth    = $bits(cnt_up_i.id);
+  localparam int unsigned IdxWidth   = (AxiIdLookupBits > 32'd0) ? AxiIdLookupBits : 32'd1;
+
+  logic [IdxWidth-1:0] up_idx, down_idx;
+  if (AxiIdLookupBits == 32'd0) begin : gen_zero_lookup_bits
+    assign up_idx   = 1'b0;
+    assign down_idx = 1'b0;
+  end else if (AxiIdLookupBits >= IdWidth) begin : gen_full_lookup_bits
+    assign up_idx   = IdxWidth'(cnt_up_i.id);
+    assign down_idx = IdxWidth'(cnt_down_i.id);
+  end else begin : gen_slice_lookup_bits
+    assign up_idx   = cnt_up_i.id[AxiIdLookupBits-1:0];
+    assign down_idx = cnt_down_i.id[AxiIdLookupBits-1:0];
+  end
+
   logic [NoCounters:0]   stall;
   logic [NoCounters-1:0] en;
   logic                  en_w;
   logic [NoCounters-1:0] down;
   logic                  down_w;
-  // outputs of the counters
   logic [NoCounters-1:0][axi_llc_pkg::MissCntWidth-1:0] q_miss;
   logic [axi_llc_pkg::MissCntMaxWWidth-1:0]             q_write;
 
-  // the or reduction of the overflow gives us the stall signal
   assign stall_o = |stall;
 
   always_comb begin : proc_control
     to_miss_o = 1'b0;
     for (int unsigned i = 0; i < NoCounters; i++) begin
-      // default assignments
-      en[i]     = 1'b0;
-      down[i]   = 1'b0;
-      // we should count up
-      if ((cnt_up_i.id[0+:AxiIdLookupBits] == i) && cnt_up_i.valid) begin
-        en[i]   = 1'b1;
-      end
+      logic up_hit, down_hit, bucket_nonzero, bucket_full;
+      up_hit         = (up_idx == IdxWidth'(i)) && cnt_up_i.valid;
+      down_hit       = (down_idx == IdxWidth'(i)) && cnt_down_i.valid;
+      bucket_full    = stall[i];
+      bucket_nonzero = (|q_miss[i]) || bucket_full;
 
-      // we should count down, or do nothing, if we are already counting up
-      if ((cnt_down_i.id[0+:AxiIdLookupBits] == i) && cnt_down_i.valid) begin
-        if (en[i] == 1'b1) begin
-          en[i]   = 1'b0;
-        end else begin
+      en[i]   = 1'b0;
+      down[i] = 1'b0;
+
+      if (up_hit && !down_hit) begin
+        if (!bucket_full) begin
+          en[i]   = 1'b1;
+          down[i] = 1'b0;
+        end
+      end else if (!up_hit && down_hit) begin
+        if (bucket_nonzero) begin
           en[i]   = 1'b1;
           down[i] = 1'b1;
         end
       end
-      // do we have to send the descriptor to the miss pipeline?
-      if (cnt_up_i.id[0+:AxiIdLookupBits] == i) begin
-        // first check the counter mapped to the id
-        to_miss_o = |q_miss[i];
-        // if it is a write also check if there are other writes in the miss pipeline
+
+      if (up_idx == IdxWidth'(i)) begin
+        to_miss_o = bucket_nonzero;
         if (cnt_up_i.rw) begin
-          to_miss_o = to_miss_o || (|q_write);
+          to_miss_o = to_miss_o || (|q_write) || stall[NoCounters];
         end
       end
     end
   end
-  // assignment of the inputs to the write counter
-  // this assignment was calculated using a Karnaugh map
-  assign en_w = ( ~cnt_up_i.rw     & cnt_down_i.rw  &   cnt_down_i.valid ) |
-                ( ~cnt_up_i.valid  & cnt_down_i.rw  &   cnt_down_i.valid ) |
-                (  cnt_up_i.rw     & cnt_up_i.valid &  ~cnt_down_i.rw    ) |
-                (  cnt_up_i.rw     & cnt_up_i.valid &  ~cnt_down_i.valid ) ;
 
-  assign down_w = ~cnt_up_i.rw | ~cnt_up_i.valid;
+  always_comb begin : proc_w_control
+    logic w_up, w_down, w_full, w_nonzero;
+    w_up      = cnt_up_i.valid   && cnt_up_i.rw;
+    w_down    = cnt_down_i.valid && cnt_down_i.rw;
+    w_full    = stall[NoCounters];
+    w_nonzero = (|q_write) || w_full;
+
+    en_w   = 1'b0;
+    down_w = 1'b0;
+    if (w_up && !w_down) begin
+      if (!w_full) begin
+        en_w   = 1'b1;
+        down_w = 1'b0;
+      end
+    end else if (!w_up && w_down) begin
+      if (w_nonzero) begin
+        en_w   = 1'b1;
+        down_w = 1'b1;
+      end
+    end
+  end
 
   for (genvar j = 0; unsigned'(j) < NoCounters; j++) begin : gen_cmiss_counters
     counter #(

--- a/environment/public/code/rtl/axi_llc_tag_pattern_gen.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_tag_pattern_gen.sv (Golden Reference)
@@ -1,140 +1,111 @@
 // Copyright 2022 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
-// Date:   11.06.2019
-
-/// This is the Tag generation for the LLC.
-/// Initialize the tag storage to a known value of all 0 using a march X
-/// BIST algorithm.
-//
-//              tag_t is shown, however fields do not mater as they are written with either '0 or '1
-//              typedef struct packed {
-//                logic                     val; // tag valid flag
-//                logic                     dit; // tag dirty flag
-//                logic [Cfg.TagLength-1:0] tag; // tag itself
-//              } pattern_t;
+
 module axi_llc_tag_pattern_gen #(
-  /// Stattic LLC configuration struct.
   parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
-  /// Pattern type for generation.
   parameter type pattern_t = logic,
-  /// Way indicator type. Each way is checked individually. Bit position id the index of the way.
   parameter type way_ind_t = logic,
-  /// Cache line index type (macro address).
   parameter type index_t   = logic
 ) (
-  /// Clock, positive edge triggered.
   input  logic     clk_i,
-  /// Asynchronous reset, active low.
   input  logic     rst_ni,
-  /// Valid request to start BIST.
   input  logic     valid_i,
-  /// Module is ready to start BIST.
   output logic     ready_o,
-  /// Pattern address for SRAM.
   output index_t   index_o,
-  /// Output pattern.
   output pattern_t pattern_o,
-  /// Request signal for the tag sram.
   output logic     req_o,
-  /// Write enable for tag sram.
   output logic     we_o,
-  /// Individual BIST comparison results.
   input  way_ind_t bist_res_i,
-  /// `bist_res_i` is valid.
   input  logic     bist_res_valid_i,
-  /// Aggregated output of bist. This indicates errors if there are any.
-  /// Initial SPM configuration will be this result.
   output way_ind_t bist_res_o,
-  /// End of computation.
   output logic     eoc_o
 );
   `include "common_cells/registers.svh"
-  // Define the width of the pattern for assignment of bits.
   localparam int unsigned PatternWidth = unsigned'($bits(pattern_t));
-
-  // unit status
+  localparam int unsigned RespCntWidth = Cfg.IndexLength + 32'd1;
+
   logic         busy_d, busy_q, switch_busy;
-  // BIST eoc status
   logic         eoc_d, eoc_q;
-  // BIST state implements March X
   typedef enum logic [3:0] {
     WZEROUP, RZEROUP, WONEUP, RONEDOWN, WZERODOWN, RZERODOWN, BISTEND
   } bist_e;
   bist_e                           bist_d,      bist_q;
   logic                            update_bist;
-  // counter signals (control)
   logic                            clear_cnt,   en_cnt, load_cnt, down_cnt, overflow_cnt;
   logic [Cfg.IndexLength-1:0]      data_cnt;
-  // bist result flipflop and
   logic [Cfg.SetAssociativity-1:0] bist_res_d,  bist_res_q;
-  logic                            error_bist;
-
-  // assign the bist error flag
-  assign error_bist = bist_res_valid_i & ~(&bist_res_i);
-  // bist output assignment
+  logic                            load_bist_res;
+  logic [RespCntWidth-1:0]         resp_cnt_d,  resp_cnt_q;
+  logic                            load_resp_cnt;
+
   assign bist_res_o = bist_res_q;
 
   always_comb begin
-    // default assignments
-    busy_d      = busy_q;
-    switch_busy = 1'b0;
-    bist_d      = bist_q;
-    update_bist = 1'b0;
-    ready_o     = 1'b0;
-    req_o       = 1'b0;
-    we_o        = 1'b0;
-    eoc_d       = eoc_q;
-    // counter signals
-    clear_cnt   = 1'b0;
-    en_cnt      = 1'b0;
-    load_cnt    = 1'b0; // will be used for BIST
-    data_cnt    = '0;
-    down_cnt    = 1'b0; // will be used for BIST
-    // pattern to write (for now all zeros)
-    pattern_o   = pattern_t'{default: '0};
-    // bist result
-    bist_res_d  = bist_res_q;
-
-    // count and react according to BIST status
+    busy_d        = busy_q;
+    switch_busy   = 1'b0;
+    bist_d        = bist_q;
+    update_bist   = 1'b0;
+    ready_o       = 1'b0;
+    req_o         = 1'b0;
+    we_o          = 1'b0;
+    eoc_d         = eoc_q;
+    clear_cnt     = 1'b0;
+    en_cnt        = 1'b0;
+    load_cnt      = 1'b0;
+    data_cnt      = '0;
+    down_cnt      = 1'b0;
+    pattern_o     = pattern_t'{default: '0};
+    bist_res_d    = bist_res_q;
+    load_bist_res = 1'b0;
+    resp_cnt_d    = resp_cnt_q;
+    load_resp_cnt = 1'b0;
+
     if (busy_q) begin
       case (bist_q)
-        // write all zeros counting up
-        WZEROUP   : begin
-          if (overflow_cnt) begin
-            clear_cnt   = 1'b1;
-            bist_d      = RZEROUP;
-            update_bist = 1'b1;
+        WZEROUP: begin
+          if (overflow_cnt) begin
+            clear_cnt     = 1'b1;
+            resp_cnt_d    = '0;
+            load_resp_cnt = 1'b1;
+            bist_d        = RZEROUP;
+            update_bist   = 1'b1;
           end else begin
             req_o  = 1'b1;
             we_o   = 1'b1;
             en_cnt = 1'b1;
           end
         end
-        // read out all zeros counting up
-        RZEROUP   : begin
-          if (overflow_cnt) begin
-            if (!bist_res_valid_i) begin// Wait until the last read response has been checked.
-              clear_cnt   = 1'b1;
-              bist_d      = WONEUP;
-              update_bist = 1'b1;
+
+        RZEROUP: begin
+          if (bist_res_valid_i) begin
+            bist_res_d    = bist_res_q | ~bist_res_i;
+            load_bist_res = 1'b1;
+            resp_cnt_d    = resp_cnt_q + RespCntWidth'(1);
+            load_resp_cnt = 1'b1;
+          end
+          if (overflow_cnt) begin
+            if (resp_cnt_q[Cfg.IndexLength] && !bist_res_valid_i) begin
+              clear_cnt     = 1'b1;
+              resp_cnt_d    = '0;
+              load_resp_cnt = 1'b1;
+              bist_d        = WONEUP;
+              update_bist   = 1'b1;
             end
           end else begin
             req_o  = 1'b1;
             en_cnt = 1'b1;
           end
-          // do checking of the bist result gets only saved, if one of the bist_res_i is zero
-          bist_res_d = bist_res_q | ~bist_res_i;
-        end
-        // write all ones counting up
-        WONEUP    : begin
-          if (overflow_cnt) begin
-            load_cnt    = 1'b1;
-            data_cnt    = '1;
-            bist_d      = RONEDOWN;
-            update_bist = 1'b1;
+        end
+
+        WONEUP: begin
+          if (overflow_cnt) begin
+            load_cnt      = 1'b1;
+            data_cnt      = '1;
+            resp_cnt_d    = '0;
+            load_resp_cnt = 1'b1;
+            bist_d        = RONEDOWN;
+            update_bist   = 1'b1;
           end else begin
             req_o     = 1'b1;
             we_o      = 1'b1;
@@ -142,31 +113,39 @@
             en_cnt    = 1'b1;
           end
         end
-        // read out all ones counting down
-        RONEDOWN  : begin
-          if (overflow_cnt) begin
-            if (!bist_res_valid_i) begin // Wait until the last read response has been checked.
-              load_cnt    = 1'b1;
-              data_cnt    = '1;
-              bist_d      = WZERODOWN;
-              update_bist = 1'b1;
+
+        RONEDOWN: begin
+          pattern_o = {PatternWidth{1'b1}};
+          if (bist_res_valid_i) begin
+            bist_res_d    = bist_res_q | ~bist_res_i;
+            load_bist_res = 1'b1;
+            resp_cnt_d    = resp_cnt_q + RespCntWidth'(1);
+            load_resp_cnt = 1'b1;
+          end
+          if (overflow_cnt) begin
+            if (resp_cnt_q[Cfg.IndexLength] && !bist_res_valid_i) begin
+              load_cnt      = 1'b1;
+              data_cnt      = '1;
+              resp_cnt_d    = '0;
+              load_resp_cnt = 1'b1;
+              bist_d        = WZERODOWN;
+              update_bist   = 1'b1;
             end
           end else begin
-            req_o     = 1'b1;
-            pattern_o = {PatternWidth{1'b1}};
-            en_cnt    = 1'b1;
-            down_cnt  = 1'b1;
-          // do checking of the bist result gets only saved, if one of the bist_res_i is zero
-          bist_res_d = bist_res_q | ~bist_res_i;
-          end
-        end
-        // write all zeros counting down
-        WZERODOWN : begin
-          if (overflow_cnt) begin
-            load_cnt    = 1'b1;
-            data_cnt    = '1;
-            bist_d      = RZERODOWN;
-            update_bist = 1'b1;
+            req_o    = 1'b1;
+            en_cnt   = 1'b1;
+            down_cnt = 1'b1;
+          end
+        end
+
+        WZERODOWN: begin
+          if (overflow_cnt) begin
+            load_cnt      = 1'b1;
+            data_cnt      = '1;
+            resp_cnt_d    = '0;
+            load_resp_cnt = 1'b1;
+            bist_d        = RZERODOWN;
+            update_bist   = 1'b1;
           end else begin
             req_o    = 1'b1;
             we_o     = 1'b1;
@@ -174,41 +153,49 @@
             down_cnt = 1'b1;
           end
         end
-        // read all zeros counting down
-        RZERODOWN : begin
-          if (overflow_cnt) begin
-            if (!bist_res_valid_i) begin // Wait until the last read response has been checked.
-              clear_cnt   = 1'b1;
-              bist_d      = BISTEND;
-              update_bist = 1'b1;
+
+        RZERODOWN: begin
+          if (bist_res_valid_i) begin
+            bist_res_d    = bist_res_q | ~bist_res_i;
+            load_bist_res = 1'b1;
+            resp_cnt_d    = resp_cnt_q + RespCntWidth'(1);
+            load_resp_cnt = 1'b1;
+          end
+          if (overflow_cnt) begin
+            if (resp_cnt_q[Cfg.IndexLength] && !bist_res_valid_i) begin
+              clear_cnt     = 1'b1;
+              resp_cnt_d    = '0;
+              load_resp_cnt = 1'b1;
+              bist_d        = BISTEND;
+              update_bist   = 1'b1;
             end
           end else begin
-            req_o         = 1'b1;
-            en_cnt        = 1'b1;
-            down_cnt      = 1'b1;
-          end
-          // do checking of the bist result gets only saved, if one of the bist_res_i is zero
-          bist_res_d = bist_res_q | ~bist_res_i;
-        end
-        BISTEND   : begin
+            req_o    = 1'b1;
+            en_cnt   = 1'b1;
+            down_cnt = 1'b1;
+          end
+        end
+
+        BISTEND: begin
           bist_d      = WZEROUP;
           update_bist = 1'b1;
           eoc_d       = 1'b1;
           busy_d      = 1'b0;
           switch_busy = 1'b1;
         end
-        default : ; // not possible to come here
+        default: ;
       endcase
-
-    // we are ready to get a new request
     end else begin
-      ready_o     = 1'b1;
-      // start operation
+      ready_o = 1'b1;
       if (valid_i) begin
-        // start bist
-        busy_d      = 1'b1;
-        switch_busy = 1'b1;
-        clear_cnt   = 1'b1;
+        busy_d        = 1'b1;
+        switch_busy   = 1'b1;
+        clear_cnt     = 1'b1;
+        eoc_d         = 1'b0;
+        bist_res_d    = '0;
+        load_bist_res = 1'b1;
+        resp_cnt_d    = '0;
+        load_resp_cnt = 1'b1;
       end
     end
   end
@@ -227,12 +214,11 @@
     .overflow_o( overflow_cnt )
   );
 
-  // Flip Flops
-  `FFLARN(busy_q,     busy_d,     switch_busy,      '0, clk_i, rst_ni)
-  `FFLARN(eoc_q,      eoc_d,      '1,               '0, clk_i, rst_ni)
-  `FFLARN(bist_q,     bist_d,     update_bist, WZEROUP, clk_i, rst_ni)
-  `FFLARN(bist_res_q, bist_res_d, error_bist,       '0, clk_i, rst_ni)
-
-  // assign outputs
+  `FFLARN(busy_q,     busy_d,     switch_busy,   '0,      clk_i, rst_ni)
+  `FFLARN(eoc_q,      eoc_d,      1'b1,          '0,      clk_i, rst_ni)
+  `FFLARN(bist_q,     bist_d,     update_bist,   WZEROUP, clk_i, rst_ni)
+  `FFLARN(bist_res_q, bist_res_d, load_bist_res, '0,      clk_i, rst_ni)
+  `FFLARN(resp_cnt_q, resp_cnt_d, load_resp_cnt, '0,      clk_i, rst_ni)
+
   assign eoc_o = eoc_q;
 endmodule

--- a/environment/public/code/rtl/axi_llc_hit_miss.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_hit_miss.sv (Golden Reference)
@@ -1,88 +1,37 @@
 // Copyright 2022 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
-// Date:   11.06.2019
-
-/// This module houses the hit miss detection logic and the tag storage.
-/// When a descriptor gets loaded into the unit the respective tag operation happens
-/// depending on the input descriptor.
-/// The unit starts uninitialized and starts in the first cycle after each reset
-/// the tag pattern generator to perform a march X BIST onto the macros.
-/// After the BIST is finished, the macros are initialized to all zero.
-/// During initialisation no descriptors can enter the unit.
-///
-/// This unit keeps track of which cache lines are currently in use by descriptors
-/// downstream with the help of a bloom filter. If there is a new descriptor, which
-/// will access a cache line currently in use, it will be stalled until the line is
-/// unlocked. This is to prevent data corruption.
-///
-/// There is an array of counters which keep track which IDs of descriptors
-/// are currently in the miss pipeline. All subsequent hits which normally would go
-/// through the bypass will get sent also towards the miss pipeline. However their
-/// eviction and refill fields will not be set. This is to clear the unit from
-/// descriptors, so that new ones from other IDs can use the hit bypass.
+
 module axi_llc_hit_miss #(
-  /// Static LLC configuration struct.
   parameter axi_llc_pkg::llc_cfg_t     Cfg       = axi_llc_pkg::llc_cfg_t'{default: '0},
-  /// AXI parameter configuration
   parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg    = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
-  /// LLC descriptor type
   parameter type                       desc_t    = logic,
-  /// Lock struct definition. The lock signal indicate that a cache line is unlocked.
-  ///
-  ///  typedef struct packed {
-  ///    logic [Cfg.IndexLength-1:0]      index;        // index of lock (cacheline)
-  ///    logic [Cfg.SetAssociativity-1:0] way_ind;      // way which is locked
-  ///  } lock_t;
   parameter type                       lock_t    = logic,
-  /// Expected type definition definition of the miss counting struct
-  ///
-  /// typedef struct packed {
-  ///   axi_slv_id_t id;    // Axi id of the count operation
-  ///   logic        rw;    // 0:read, 1:write
-  ///   logic        valid; // valid, equals enable
-  /// } cnt_t;
   parameter type                       cnt_t     = logic,
-  /// Way indicator, is a onehot signal with width: `Cfg.SetAssociativity`.
   parameter type                       way_ind_t = logic,
-  /// Whether to print SRAM configs
   parameter bit                        PrintSramCfg = 0,
-  /// Number of low AXI ID bits used for miss counters.
   parameter int unsigned               AxiIdLookupBits = 32'd0
 ) (
-  /// Clock, positive edge triggered.
   input  logic     clk_i,
-  /// Asynchronous reset, active low.
   input  logic     rst_ni,
-  /// Testmode enable, active high.
   input  logic     test_i,
-  /// Input descriptor payload.
   input  desc_t    desc_i,
-  /// Input descriptor is valid.
   input  logic     valid_i,
-  /// Module is ready to accept a new input descriptor.
   output logic     ready_o,
-  /// Descriptor Output TODO
   output desc_t    desc_o,
   output logic     miss_valid_o,
   input  logic     miss_ready_i,
   output logic     hit_valid_o,
   input  logic     hit_ready_i,
-  // Configuration input
   input  way_ind_t spm_lock_i,
   input  way_ind_t flushed_i,
-  // unlock inputs from the units
   input  lock_t    w_unlock_i,
   input  logic     w_unlock_req_i,
   output logic     w_unlock_gnt_o,
   input  lock_t    r_unlock_i,
   input  logic     r_unlock_req_i,
   output logic     r_unlock_gnt_o,
-  // counter inputs to count down
   input  cnt_t     cnt_down_i,
-  // bist aoutput
   output way_ind_t bist_res_o,
   output logic     bist_valid_o
 );
@@ -90,39 +39,24 @@
   localparam int unsigned IndexBase = Cfg.ByteOffsetLength + Cfg.BlockOffsetLength;
   localparam int unsigned TagBase   = Cfg.ByteOffsetLength + Cfg.BlockOffsetLength +
                                       Cfg.IndexLength;
-  // Type definitions for the requests and responses to/from the tag storage
-      // typedef logic [Cfg.SetAssociativity-1:0] way_ind_t;
-  typedef logic [Cfg.IndexLength-1:0]      index_t;
-  typedef logic [Cfg.TagLength-1:0]        tag_t;
-
-  /// Request struct to the tag storage.
+  typedef logic [Cfg.IndexLength-1:0] index_t;
+  typedef logic [Cfg.TagLength-1:0]   tag_t;
+
   typedef struct packed {
-    /// The request mode. What operation the tag storage should perform with the request.
     axi_llc_pkg::tag_mode_e mode;
-    /// The indicator encodes with a hot signal, to which ways the request should be made.
     way_ind_t               indicator;
-    /// The index points to the cache line, for which the request is made.
     index_t                 index;
-    /// The tag for which the request to the tag storage is made.
     tag_t                   tag;
-    /// The tag is dirty, comes from a write.
     logic                   dirty;
   } store_req_t;
 
-  /// The response will only come out of the tag storage, id a lookup request was made.
   typedef struct packed {
-    /// The descriptor has to operate on this way
     way_ind_t indicator;
-    /// The request has hit on a cache line.
     logic     hit;
-    /// The tag currently stored is dirty.
-    /// The tag storage wants to evict the current line stored at this position.
     logic     evict;
-    /// The tag which is evicted.
     tag_t     evict_tag;
   } store_res_t;
 
-  // Signals to/from the tag store
   store_req_t store_req;
   logic       store_req_valid;
   logic       store_req_ready;
@@ -130,89 +64,72 @@
   store_res_t store_res;
   logic       store_res_valid;
   logic       store_res_ready;
-  // lock signal
+
   lock_t lock;
   logic  lock_req, locked;
-  // up counting signal
   cnt_t  cnt_up;
   logic  cnt_stall;
   logic  to_miss;
 
-  // Flipflops
-  logic  busy_d,    busy_q, load_busy; // we have a valid descriptor in the unit
-  logic  init_d,    init_q, load_init; // is the tag storage initialized?
-  desc_t desc_d,    desc_q;            // descriptor residing in unit
+  logic  busy_d,        busy_q,        load_busy;
+  logic  init_d,        init_q,        load_init;
+  desc_t desc_d,        desc_q;
   logic  load_desc;
-
-  // control
+  logic  no_way_err_d,  no_way_err_q;
+
+  way_ind_t avail_cache_ways;
+  assign avail_cache_ways
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE.llc`](environment/public/code/LICENSE.llc) *(Read-Only Context)*
- [`environment/public/code/axi/include/axi/assign.svh`](environment/public/code/axi/include/axi/assign.svh) *(Read-Only Context)*
- [`environment/public/code/axi/include/axi/typedef.svh`](environment/public/code/axi/include/axi/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_pkg.sv`](environment/public/code/axi/src/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/include/common_cells/assertions.svh`](environment/public/code/common_cells/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/common_cells/include/common_cells/registers.svh`](environment/public/code/common_cells/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/cb_filter.sv`](environment/public/code/common_cells/src/cb_filter.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/cb_filter_pkg.sv`](environment/public/code/common_cells/src/cb_filter_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/cf_math_pkg.sv`](environment/public/code/common_cells/src/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/counter.sv`](environment/public/code/common_cells/src/counter.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/delta_counter.sv`](environment/public/code/common_cells/src/delta_counter.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/fifo_v3.sv`](environment/public/code/common_cells/src/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/lzc.sv`](environment/public/code/common_cells/src/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/onehot_to_bin.sv`](environment/public/code/common_cells/src/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/rr_arb_tree.sv`](environment/public/code/common_cells/src/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/shift_reg.sv`](environment/public/code/common_cells/src/shift_reg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/shift_reg_gated.sv`](environment/public/code/common_cells/src/shift_reg_gated.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/spill_register.sv`](environment/public/code/common_cells/src/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/spill_register_flushable.sv`](environment/public/code/common_cells/src/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/sub_per_hash.sv`](environment/public/code/common_cells/src/sub_per_hash.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_evict_box.sv`](environment/public/code/rtl/axi_llc_evict_box.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_hit_miss.sv`](environment/public/code/rtl/axi_llc_hit_miss.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_lock_box_bloom.sv`](environment/public/code/rtl/axi_llc_lock_box_bloom.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_miss_counters.sv`](environment/public/code/rtl/axi_llc_miss_counters.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_pkg.sv`](environment/public/code/rtl/axi_llc_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_tag_pattern_gen.sv`](environment/public/code/rtl/axi_llc_tag_pattern_gen.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_tag_store.sv`](environment/public/code/rtl/axi_llc_tag_store.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/tc_sram.sv`](environment/public/code/rtl/tc_sram.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

