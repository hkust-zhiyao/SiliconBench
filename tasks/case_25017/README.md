# `case_25017`: Snitch Wide-Line 10-SRAM AXI4 Read-Only Cache Coherence, Burst Splitting & Macro PnR

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25017` |
| **Source Silicon Repository** | `pulp-platform/snitch` (`repo_22`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `MultiCore_SoCs_and_NoC` (MultiCore_SoCs_and_NoC) |
| **Multi-Domain Tags** | `MultiCore_SoCs_and_NoC` |
| **Editable Files (`allowed_edits`)** | [`code/snitch_read_only_cache.sv`](environment/public/code/snitch_read_only_cache.sv), [`code/snitch_axi_to_cache.sv`](environment/public/code/snitch_axi_to_cache.sv), [`code/snitch_ro_cache_lookup.sv`](environment/public/code/snitch_ro_cache_lookup.sv), [`code/snitch_ro_cache_refill.sv`](environment/public/code/snitch_ro_cache_refill.sv), [`plan/macro_placement.json`](environment/public/plan/macro_placement.json), [`constraints/snitch_ro_cache.sdc`](environment/public/constraints/snitch_ro_cache.sdc) (6 files, 1384 LOC) |
| **Public Subsystem Context** | 36 RTL files (7710 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1800s` total (`900s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Snitch Wide-Line 10-SRAM AXI4 Read-Only Cache Coherence, Burst Splitting & Macro PnR

## Overview
`snitch_ro_cache_subsys` (`code/snitch_ro_cache_subsys.sv`) integrates PULP Snitch's wide-line AXI4 read-only cache (`LineWidth=256`, `LineCount=256`, `SetCount=2`, `AxiAddrWidth=32`, `AxiDataWidth=64`, `AxiIdWidth=3`, `AxiUserWidth=2`, `MaxTrans=4`, `NrAddrRules=2`) backed by ten `RM_IHPSG13_1P_256x64_c2_bm_bist` 1P 256x64 hard SRAM macros (`2` tag + `8` data banks across `2` ways). You own the RTL-to-physical co-design across:
- `code/snitch_read_only_cache.sv`, `code/snitch_axi_to_cache.sv`, `code/snitch_ro_cache_lookup.sv`, `code/snitch_ro_cache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_ro_cache.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Coherence Contract
1. **Address-Window Decoding & Non-Cacheable Bypass Routing**:
   - Each rule `r` (`0 <= r < NrAddrRules`) defines an active half-open cacheable window `[start_addr_i[r], end_addr_i[r])` whenever `start_addr_i[r] < end_addr_i[r]`.
   - Route an AXI4 `AR` burst to the cache iff `enable_i` is high, every accessed byte of the burst falls within a single active rule `r`, `slv_ar_lock_i == 1'b0`, `slv_ar_burst_i == 2'b01` (`BURST_INCR`), and (`slv_ar_len_i == 8'd0` or `slv_ar_size_i == 3'd3`). Route all `AW`/`W`/`B` writes and all other `AR` bursts (`BURST_FIXED`, `BURST_WRAP`, narrow multi-beat bursts, locked reads, disabled-cache reads, and bursts crossing outside an active window) through the bypass path without allocating or polluting cache lines.
2. **Wide-Line Burst Splitting, Multi-ID Coalescing & R-Channel Backpressure**:
   - Split cacheable `INCR` bursts across 32-byte (`256`-bit) cache lines (`mst_ar` refills must issue 32-byte-aligned 4-beat `INCR` bursts: `mst_ar_addr_o[4:0] == 5'h0`, `mst_ar_len_o == 8'd3`, `mst_ar_size_o == 3'd3`, `mst_ar_burst_o == 2'b01`).
   - Reconstruct exact 64-bit `R` beats, `slv_r_id_o`, `slv_r_last_o`, and `slv_r_user_o == '0` across unaligned multi-line splits, multi-ID MSHR coalescing, and back-to-back same-ID requests, holding all `slv_r_*` outputs and internal burst/ID tracking undisturbed while `slv_r_valid_o && !slv_r_ready_i`.
3. **Multi-Beat Refill Error Containment (`mst_r_resp_i[1] == 1'b1`)**:
   - A downstream AXI read error (`SLVERR`/`DECERR`) on **any** beat of a 4-beat cache refill must return `slv_r_resp_o == 2'b10` (`RESP_SLVERR`) on the corresponding slave `R` beat(s) and must never leave the errored line valid in SRAM, allowing subsequent reads to cleanly re-fetch from memory once the fault clears.
4. **Write-Through Cache Invalidation & Flush Handshake (`flush_valid_i` / `flush_ready_o`)**:
   - Writes (`AW`/`W`/`B`) overlapping any active `[start_addr_i[r], end_addr_i[r])` window must forward to memory and invalidate all touched cache sets across both ways—ordering concurrent/in-flight reads and refills so neither post-write reads nor concurrent refills leave stale pre-write data cached—while preserving warm cache hits on untouched sets and ignoring writes strictly outside active cacheable windows.
   - Completing a `flush_valid_i && flush_ready_o` handshake must drain in-flight cache transactions/refills and clear all cached sets across both ways so no pre-flush data survives or installs afterward.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 1800]` um, core area `[50, 50, 2550, 1750]` um. Place all ten `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2.0` um core margin, `>= 8.0` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/snitch_ro_cache.sdc`)**: Constrain `clk_i` to period `<= 11.8` ns with `>= 1.2` ns input/output delays on all non-clock ports (only `rst_ni` may carry `set_false_path`; no multicycle, clock-group, case-analysis, or max/min-delay overrides).
- **Synthesis & OpenROAD Signoff**: Zero inferred latches, all ten `RM_IHPSG13_1P_256x64_c2_bm_bist` macros preserved, connected `VDD`/`VSS` PDN grids, post-GRT setup slack `>= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 15`, and total routed wirelength `<= 2,900,000` um.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment (`case_25017`)

## Available Tools & Collateral
- **RTL Simulation**: Verilator (`verilator --binary --timing`) or Icarus Verilog (`iverilog -g2012`)
- **Synthesis**: Yosys with SystemVerilog Slang frontend (`yosys -m slang`)
- **Physical Implementation & STA**: OpenROAD (`openroad -exit`)
- **PDK Collateral (`pdk/`)**: IHP SG13G2 130nm standard cells (`sg13g2_tech.lef`, `sg13g2_stdcell.lef`, `sg13g2_stdcell_typ_1p20V_25C.lib`, `core.v`) and `RM_IHPSG13_1P_256x64_c2_bm_bist` hard SRAM macro views (`256.v` behavioral model, `256_stub.v` blackbox stub, `256.lef`, `256.lib`).

## Editable Files
- `code/snitch_read_only_cache.sv`
- `code/snitch_axi_to_cache.sv`
- `code/snitch_ro_cache_lookup.sv`
- `code/snitch_ro_cache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_ro_cache.sdc`

## Example Commands
```bash
# 1. RTL Elaboration & Lint Check
verilator --lint-only -Wno-fatal -Wno-UNOPTFLAT -Icode -top-module snitch_ro_cache_subsys \
  pdk/core.v pdk/256.v code/axi_pkg.sv code/cf_math_pkg.sv code/snitch_icache_pkg.sv \
  code/cc_onehot.sv code/lzc.sv code/onehot_to_bin.sv code/rr_arb_tree.sv \
  code/counter.sv code/delta_counter.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
  code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
  code/addr_decode.sv code/id_queue.sv code/axi_id_prepend.sv \
  code/axi_demux_simple.sv code/axi_demux.sv code/axi_mux.sv code/tc_sram_impl.sv \
  code/snitch_icache_lfsr.sv code/snitch_icache_handler.sv code/snitch_axi_to_cache.sv \
  code/snitch_ro_cache_lookup.sv code/snitch_ro_cache_refill.sv \
  code/snitch_read_only_cache.sv code/snitch_ro_cache_subsys.sv

# 2. Synthesis to SG13G2 Standard Cells + 10x Hard SRAM Macros
yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode pdk/256_stub.v code/axi_pkg.sv code/cf_math_pkg.sv \
    code/snitch_icache_pkg.sv code/cc_onehot.sv code/lzc.sv code/onehot_to_bin.sv \
    code/rr_arb_tree.sv code/counter.sv code/delta_counter.sv \
    code/spill_register_flushable.sv code/spill_register.sv code/fall_through_register.sv \
    code/fifo_v3.sv code/stream_arbiter_flushable.sv code/stream_arbiter.sv \
    code/stream_demux.sv code/addr_decode.sv code/id_queue.sv code/axi_id_prepend.sv \
    code/axi_demux_simple.sv code/axi_demux.sv code/axi_mux.sv code/tc_sram_impl.sv \
    code/snitch_icache_lfsr.sv code/snitch_icache_handler.sv code/snitch_axi_to_cache.sv \
    code/snitch_ro_cache_lookup.sv code/snitch_ro_cache_refill.sv \
    code/snitch_read_only_cache.sv code/snitch_ro_cache_subsys.sv \
    --top snitch_ro_cache_subsys;
  hierarchy -check -top snitch_ro_cache_subsys;
  synth -noabc -top snitch_ro_cache_subsys -flatten;
  delete t:\$scopeinfo;
  dfflibmap -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  abc -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/mapped.v
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/snitch_read_only_cache.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_read_only_cache.sv (Golden Reference)
@@ -2,26 +2,13 @@
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
 
-// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
-//         Samuel Riedel <sriedel@iis.ee.ethz.ch>
-
-/// Serve read memory requests from a read-only cache.
-/// The cacheable region can be runtime configured. All writes and read
-/// requests outside the configured regions will be forwarded.
 module snitch_read_only_cache #(
-  /// Cache Line Width
   parameter int unsigned LineWidth    = -1,
-  /// The number of cache lines per set. Power of two; >= 2.
   parameter int unsigned LineCount    = -1,
-  /// The set associativity of the cache. Power of two; >= 1.
   parameter int unsigned SetCount     = 1,
-  /// AXI address width
   parameter int unsigned AxiAddrWidth = 0,
-  /// AXI data width
   parameter int unsigned AxiDataWidth = 0,
-  /// AXI id width
   parameter int unsigned AxiIdWidth   = 0,
-  /// AXI user width
   parameter int unsigned AxiUserWidth = 0,
   parameter int unsigned MaxTrans     = 0,
   parameter int unsigned NrAddrRules  = 1,
@@ -29,7 +16,6 @@
   parameter type slv_rsp_t = logic,
   parameter type mst_req_t = logic,
   parameter type mst_rsp_t = logic,
-  /// Configuration input types for memory cuts used in implementation.
   parameter type sram_cfg_data_t  = logic,
   parameter type sram_cfg_tag_t   = logic
 ) (
@@ -52,46 +38,249 @@
   `include "common_cells/registers.svh"
   import cf_math_pkg::idx_width;
 
-  // Check for supported parameters
-  if (AxiDataWidth < 32)
-    $error("snitch_read_only_cache: AxiDataWidth must be larger than 32.");
-  if (AxiDataWidth > LineWidth)
-    $error("snitch_read_only_cache: LineWidth must be larger than/equal to AxiDataWidth.");
-  if (NrAddrRules < 1)
-    $error("snitch_read_only_cache: NrAddrRules must be larger than/equal to 1.");
-  if (MaxTrans < 1)
-    $error("snitch_read_only_cache: MaxTrans must be larger than/equal to 1.");
-
-  // --------------------------------------------------
-  // AXI Demux
-  // --------------------------------------------------
   localparam int unsigned NoMstPorts = 2;
-
   typedef logic [idx_width(NoMstPorts)-1:0] index_t;
   typedef enum index_t {
     Cache  = 1,
     Bypass = 0
   } index_e;
 
-  typedef logic [AxiIdWidth-1:0] id_t;
-  typedef logic [AxiIdWidth:0] mst_id_t;
-  typedef logic [AxiAddrWidth-1:0] addr_t;
-  typedef logic [AxiDataWidth-1:0] data_t;
+  typedef logic [AxiIdWidth-1:0]     id_t;
+  typedef logic [AxiIdWidth:0]       mst_id_t;
+  typedef logic [AxiAddrWidth-1:0]   addr_t;
+  typedef logic [AxiDataWidth-1:0]   data_t;
   typedef logic [AxiDataWidth/8-1:0] strb_t;
-  typedef logic [AxiUserWidth-1:0] user_t;
+  typedef logic [AxiUserWidth-1:0]   user_t;
 
   `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)
   `AXI_TYPEDEF_ALL(axi_mst, addr_t, mst_id_t, data_t, strb_t, user_t)
 
-  axi_req_t [1:0] demux_req;
+  localparam int unsigned PendingCount = MaxTrans;
+  localparam snitch_icache_pkg::config_t CFG = '{
+    LINE_WIDTH:         LineWidth,
+    LINE_COUNT:         LineCount,
+    SET_COUNT:          SetCount,
+    PENDING_COUNT:      PendingCount,
+    FETCH_AW:           AxiAddrWidth,
+    FETCH_DW:           AxiDataWidth,
+    FILL_AW:            AxiAddrWidth,
+    FILL_DW:            AxiDataWidth,
+    EARLY_LATCH:        0,
+    BUFFER_LOOKUP:      1,
+    GUARANTEE_ORDERING: 1,
+    FETCH_ALIGN:        $clog2(AxiDataWidth/8),
+    FILL_ALIGN:         $clog2(AxiDataWidth/8),
+    LINE_ALIGN:         $clog2(LineWidth/8),
+    COUNT_ALIGN:        cf_math_pkg::idx_width(LineCount),
+    SET_ALIGN:          cf_math_pkg::idx_width(SetCount),
+    TAG_WIDTH:          AxiAddrWidth - $clog2(LineWidth/8) - $clog2(LineCount) + 1,
+    ID_WIDTH_REQ:       AxiIdWidth,
+    ID_WIDTH_RESP:      2**AxiIdWidth,
+    PENDING_IW:         $clog2(PendingCount),
+    default:            0
+  };
+
+  slv_req_t  slv_req_in;
+  slv_rsp_t  slv_rsp_out;
+  axi_req_t  [1:0] demux_req;
   axi_resp_t [1:0] demux_rsp;
-
-  axi_req_t refill_req;
+  axi_req_t  refill_req;
   axi_resp_t refill_rsp;
-
-  index_t slv_aw_select;
-  index_t slv_ar_select;
-  index_t dec_ar;
+  index_t    slv_aw_select;
+  index_t    slv_ar_select;
+
+  // Coherence & drain tracking
+  logic ar_in_progress_q, aw_in_progress_q;
+  logic [7:0] wr_inflight_q, cache_ar_inflight_q, refill_inflight_q;
+  logic lookup_init_busy, lookup_flush_valid, lookup_flush_ready;
+
+  typedef struct packed {
+    logic [CFG.COUNT_ALIGN-1:0] start_idx;
+    logic [CFG.COUNT_ALIGN:0]   line_cnt;
+  } inval_cmd_t;
+
+  inval_cmd_t inval_push_cmd, inval_pop_cmd;
+  logic inval_fifo_full, inval_fifo_empty, inval_fifo_push, inval_fifo_pop;
+  logic inval_sweeping_q, inval_valid, inval_ready;
+  logic [CFG.COUNT_ALIGN-1:0] inval_idx_q;
+  logic [CFG.COUNT_ALIGN:0]   inval_rem_q;
+
+  // Address region check for AR burst [ar.addr, ar_last_addr]
+  logic ar_in_region;
+  always_comb begin
+    automatic logic [AxiAddrWidth:0] ar_bytes =
+        ((AxiAddrWidth+1)'(axi_slv_req_i.ar.len) + 1'b1) << axi_slv_req_i.ar.size;
+    automatic logic [AxiAddrWidth:0] ar_end_ext =
+        (AxiAddrWidth+1)'(axi_slv_req_i.ar.addr) + ar_bytes - 1'b1;
+    automatic logic ar_ovf = ar_end_ext[AxiAddrWidth];
+    automatic addr_t ar_last = ar_end_ext[AxiAddrWidth-1:0];
+    ar_in_region = 1'b0;
+    for (int r = 0; r < NrAddrRules; r++) begin
+      if ((start_addr_i[r] < end_addr_i[r]) && !ar_ovf &&
+          (axi_slv_req_i.ar.addr >= start_addr_i[r]) &&
+          (ar_last < end_addr_i[r])) begin
+        ar_in_region = 1'b1;
+      end
+    end
+  end
+
+  assign slv_aw_select = Bypass;
+  always_comb begin
+    slv_ar_select = Bypass;
+    if (enable_i && ar_in_region &&
+        !axi_slv_req_i.ar.lock &&
+        (axi_slv_req_i.ar.burst == axi_pkg::BURST_INCR) &&
+        ((axi_slv_req_i.ar.len == 8'd0) || (axi_slv_req_i.ar.size == $clog2(AxiDataWidth/8)))) begin
+      slv_ar_select = Cache;
+    end
+  end
+
+  // AW cache-line overlap calculation
+  logic aw_overlaps_cache;
+  always_comb begin
+    automatic logic [AxiAddrWidth:0] aw_bytes =
+        ((AxiAddrWidth+1)'(axi_slv_req_i.aw.len) + 1'b1) << axi_slv_req_i.aw.size;
+    automatic addr_t aw_lo;
+    automatic logic [AxiAddrWidth:0] aw_hi_ext;
+    automatic addr_t aw_hi;
+    automatic logic [AxiAddrWidth-CFG.LINE_ALIGN:0] first_ln, last_ln, span_ln;
+    if (axi_slv_req_i.aw.burst == axi_pkg::BURST_FIXED) begin
+      aw_lo     = axi_slv_req_i.aw.addr;
+      aw_hi_ext = (AxiAddrWidth+1)'(aw_lo) + ((AxiAddrWidth+1)'(1) << axi_slv_req_i.aw.size) - 1'b1;
+    end else if (axi_slv_req_i.aw.burst == axi_pkg::BURST_WRAP) begin
+      automatic addr_t wmask = aw_bytes[AxiAddrWidth-1:0] - 1'b1;
+      aw_lo     = axi_slv_req_i.aw.addr & ~wmask;
+      aw_hi_ext = (AxiAddrWidth+1)'(aw_lo) + aw_bytes - 1'b1;
+    end else begin
+      aw_lo     = axi_slv_req_i.aw.addr;
+      aw_hi_ext = (AxiAddrWidth+1)'(aw_lo) + aw_bytes - 1'b1;
+    end
+    aw_hi = aw_hi_ext[AxiAddrWidth] ? '1 : aw_hi_ext[AxiAddrWidth-1:0];
+
+    aw_overlaps_cache = 1'b0;
+    for (int r = 0; r < NrAddrRules; r++) begin
+      if ((start_addr_i[r] < end_addr_i[r]) &&
+          (aw_lo < end_addr_i[r]) && (aw_hi >= start_addr_i[r])) begin
+        aw_overlaps_cache = 1'b1;
+      end
+    end
+
+    first_ln = aw_lo >> CFG.LINE_ALIGN;
+    last_ln  = aw_hi >> CFG.LINE_ALIGN;
+    span_ln  = last_ln - first_ln + 1'b1;
+    inval_push_cmd.start_idx = first_ln[CFG.COUNT_ALIGN-1:0];
+    inval_push_cmd.line_cnt  = (span_ln > $unsigned(LineCount)) ?
+                               (CFG.COUNT_ALIGN+1)'(LineCount) : span_ln[CFG.COUNT_ALIGN:0];
+  end
+  // Gate new AR/AW cleanly without ever dropping a locked valid inside axi_demux
+  logic block_ar, block_aw;
+  assign block_aw = !aw_in_progress_q &&
+                    (flush_valid_i || lookup_init_busy || (aw_overlaps_cache && inval_fifo_full));
+  assign block_ar = !ar_in_progress_q &&
+                    (flush_valid_i || lookup_init_busy ||
+                     (axi_slv_req_i.aw_valid && !block_aw) ||
+                     (wr_inflight_q != '0) || !inval_fifo_empty || inval_sweeping_q);
+
+  always_comb begin
+    slv_req_in    = axi_slv_req_i;
+    axi_slv_rsp_o = slv_rsp_out;
+    if (block_aw) begin
+      slv_req_in.aw_valid    = 1'b0;
+      axi_slv_rsp_o.aw_ready = 1'b0;
+    end
+    if (block_ar) begin
+      slv_req_in.ar_valid    = 1'b0;
+      axi_slv_rsp_o.ar_ready = 1'b0;
+    end
+  end
+
+  wire aw_hs       = slv_req_in.aw_valid && slv_rsp_out.aw_ready;
+  wire b_hs        = slv_rsp_out.b_valid && slv_req_in.b_ready;
+  wire ar_hs       = slv_req_in.ar_valid && slv_rsp_out.ar_ready;
+  wire cache_ar_hs = demux_req[Cache].ar_valid && demux_rsp[Cache].ar_ready;
+  wire cache_r_end = demux_rsp[Cache].r_valid && demux_req[Cache].r_ready && demux_rsp[Cache].r.last;
+
+  logic                         handler_req_valid, handler_req_ready;
+  logic [CFG.FETCH_AW-1:0]      handler_req_addr;
+  logic [CFG.PENDING_IW-1:0]    handler_req_id;
+  logic [CFG.LINE_WIDTH-1:0]    handler_rsp_data;
+  logic                         handler_rsp_error;
+  logic [CFG.PENDING_IW-1:0]    handler_rsp_id;
+  logic                         handler_rsp_valid, handler_rsp_ready;
+
+  wire refill_ar_hs = handler_req_valid && handler_req_ready;
+  wire refill_r_end = handler_rsp_valid && handler_rsp_ready;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      ar_in_progress_q    <= 1'b0;
+      aw_in_progress_q    <= 1'b0;
+      wr_inflight_q       <= '0;
+      cache_ar_inflight_q <= '0;
+      refill_inflight_q   <= '0;
+    end else begin
+      if (ar_hs) ar_in_progress_q <= 1'b0;
+      else if (slv_req_in.ar_valid) ar_in_progress_q <= 1'b1;
+
+      if (aw_hs) aw_in_progress_q <= 1'b0;
+      else if (slv_req_in.aw_valid) aw_in_progress_q <= 1'b1;
+
+      wr_inflight_q       <= wr_inflight_q + 8'(aw_hs) - 8'(b_hs);
+      cache_ar_inflight_q <= cache_ar_inflight_q + 8'(cache_ar_hs) - 8'(cache_r_end);
+      refill_inflight_q   <= refill_inflight_q + 8'(refill_ar_hs) - 8'(refill_r_end);
+    end
+  end
+
+  assign inval_fifo_push = aw_hs && aw_overlaps_cache;
+
+  fifo_v3 #(
+    .DEPTH ( MaxTrans    ),
+    .dtype ( inval_cmd_t )
+  ) i_inval_fifo (
+    .clk_i      ( clk_i            ),
+    .rst_ni     ( rst_ni           ),
+    .flush_i    ( 1'b0             ),
+    .testmode_i ( 1'b0             ),
+    .full_o     ( inval_fifo_full  ),
+    .empty_o    ( inval_fifo_empty ),
+    .usage_o    (                  ),
+    .data_i     ( inval_push_cmd   ),
+    .push_i     ( inval_fifo_push  ),
+    .data_o     ( inval_pop_cmd    ),
+    .pop_i      ( inval_fifo_pop   )
+  );
+
+  wire cache_quiescent = (wr_inflight_q == '0) &&
+                         (cache_ar_inflight_q == '0) &&
+                         (refill_inflight_q == '0);
+
+  assign inval_fifo_pop = !inval_sweeping_q && !inval_fifo_empty && cache_quiescent && !lookup_init_busy;
+  assign inval_valid    = inval_sweeping_q;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      inval_sweeping_q <= 1'b0;
+      inval_idx_q      <= '0;
+      inval_rem_q      <= '0;
+    end else if (inval_fifo_pop) begin
+      inval_sweeping_q <= 1'b1;
+      inval_idx_q      <= inval_pop_cmd.start_idx;
+      inval_rem_q      <= inval_pop_cmd.line_cnt;
+    end else if (inval_sweeping_q && inval_ready) begin
+      if (inval_rem_q <= (CFG.COUNT_ALIGN+1)'(1)) begin
+        inval_sweeping_q <= 1'b0;
+        inval_rem_q      <= '0;
+      end else begin
+        inval_idx_q <= inval_idx_q + 1'b1;
+        inval_rem_q <= inval_rem_q - 1'b1;
+      end
+    end
+  end
+
+  wire flush_can_fire = !ar_in_progress_q && !aw_in_progress_q &&
+                        cache_quiescent && inval_fifo_empty && !inval_sweeping_q;
+  assign lookup_flush_valid = flush_valid_i && flush_can_fire;
+  assign flush_ready_o      = flush_can_fire && lookup_flush_ready;
 
   axi_demux #(
     .AxiIdWidth  ( AxiIdWidth    ),
@@ -114,140 +303,27 @@
     .clk_i,
     .rst_ni,
     .test_i          ( 1'b0          ),
-    .slv_req_i       ( axi_slv_req_i ),
+    .slv_req_i       ( slv_req_in    ),
     .slv_aw_select_i ( slv_aw_select ),
     .slv_ar_select_i ( slv_ar_select ),
-    .slv_resp_o      ( axi_slv_rsp_o ),
+    .slv_resp_o      ( slv_rsp_out   ),
     .mst_reqs_o      ( demux_req     ),
     .mst_resps_i     ( demux_rsp     )
   );
 
-  typedef struct packed {
-    int unsigned idx;
-    addr_t       start_addr;
-    addr_t       end_addr;
-  } rule_t;
-
-  rule_t [NrAddrRules-1:0] addr_map;
-
-  for (genvar i = 0; i < NrAddrRules; i++) begin : gen_addr_map
-    assign addr_map[i] = '{
-      idx: Cache,
-      start_addr: start_addr_i[i],
-      end_addr: end_addr_i[i]
-    };
-  end
-
-  addr_decode #(
-    .NoIndices ( NoMstPorts  ),
-    .NoRules   ( NrAddrRules ),
-    .addr_t    ( addr_t      ),
-    .rule_t    ( rule_t      )
-  ) i_axi_aw_decode (
-    .addr_i           ( axi_slv_req_i.ar.addr ),
-    .addr_map_i       ( addr_map              ),
-    .idx_o            ( dec_ar                ),
-    .dec_valid_o      (                       ),
-    .dec_error_o      (                       ),
-    .en_default_idx_i ( 1'b1                  ),
-    .default_idx_i    ( Bypass                )
-  );
-
-  // `AW` always bypass
-  assign slv_aw_select = Bypass;
-
-  // `AR` select logic
-  always_comb begin
-    // Select cache based on address region
-    slv_ar_select = dec_ar;
-    // Bypass all atomic requests
-    if (axi_slv_req_i.ar.lock) begin
-      slv_ar_select = Bypass;
-    end
-    // Wrapping bursts are currently not supported
-    if (axi_slv_req_i.ar.burst == axi_pkg::BURST_WRAP) begin
-      slv_ar_select = Bypass;
-    end
-    // Only accept bursts that use full AXI width
-    if (axi_slv_req_i.ar.len && (axi_slv_req_i.ar.size < $clog2(AxiDataWidth/8))) begin
-      slv_ar_select = Bypass;
-    end
-    // Bypass cache if disabled
-    if (!enable_i) begin
-      slv_ar_select = Bypass;
-    end
-  end
-
-  // --------------------------------------------------
-  // Cache Logic
-  // --------------------------------------------------
-  localparam int unsigned PendingCount = MaxTrans;
-  localparam snitch_icache_pkg::config_t CFG = '{
-    LINE_WIDTH:         LineWidth,
-    LINE_COUNT:         LineCount,
-    SET_COUNT:          SetCount,
-    PENDING_COUNT:      PendingCount,
-    FETCH_AW:           AxiAddrWidth,
-    FETCH_DW:           AxiDataWidth,
-    FILL_AW:            AxiAddrWidth,
-    FILL_DW:            AxiDataWidth,
-    EARLY_LATCH:        0, // Unused here
-    BUFFER_LOOKUP:      1, // Mandatory here
-    GUARANTEE_ORDERING: 1, // Mandatory here
-
-    FETCH_ALIGN:   $clog2(AxiDataWidth/8),
-    FILL_ALIGN:    $clog2(AxiDataWidth/8),
-    LINE_ALIGN:    $clog2(LineWidth/8),
-    COUNT_ALIGN:   cf_math_pkg::idx_width(LineCount),
-    SET_ALIGN:     cf_math_pkg::idx_width(SetCount),
-    TAG_WIDTH:     AxiAddrWidth - $clog2(LineWidth/8) - $clog2(LineCount) + 1,
-    ID_WIDTH_REQ:  AxiIdWidth,
-    ID_WIDTH_RESP: 2**AxiIdWidth,
-    PENDING_IW:    $clog2(PendingCount),
-    default:       0
-  };
-
-  logic [CFG.FETCH_AW-1:0]      in_addr;
-  logic [CFG.ID_WIDTH_REQ-1:0]  in_id;
-  logic                         in_valid;
-  logic                         in_ready;
-
-  logic [CFG.LINE_WIDTH-1:0]    in_rsp_data;
-  logic                         in_rsp_error;
+  logic [CFG.FETCH_AW-1:0]      in_addr, lookup_addr;
+  logic [CFG.ID_WIDTH_REQ-1:0]  in_id, lookup_id;
+  logic                         in_valid, in_ready;
+  logic [CFG.LINE_WIDTH-1:0]    in_rsp_data, lookup_data, write_data;
+  logic                         in_rsp_error, lookup_error, write_error;
   logic [CFG.ID_WIDTH_RESP-1:0] in_rsp_id;
-  logic                         in_rsp_valid;
-  logic                         in_rsp_ready;
-
-  logic [CFG.FETCH_AW-1:0]      lookup_addr;
-  logic [CFG.ID_WIDTH_REQ-1:0]  lookup_id;
-  logic [CFG.SET_ALIGN-1:0]     lookup_set;
-  logic                         lookup_hit;
-  logic [CFG.LINE_WIDTH-1:0]    lookup_data;
-  logic                         lookup_error;
-  logic                         lookup_valid;
-  logic                         lookup_ready;
-
-  logic                         handler_req_valid;
-  logic                         handler_req_ready;
-  logic [CFG.FETCH_AW-1:0]      handler_req_addr;
-  logic [CFG.PENDING_IW-1:0]    handler_req_id;
-
-  logic [CFG.LINE_WIDTH-1:0]    handler_rsp_data;
-  logic                         handler_rsp_error;
-  logic [CFG.PENDING_IW-1:0]    handler_rsp_id;
-  logic                         handler_rsp_valid;
-  logic                         handler_rsp_ready;
-
+  logic                         in_rsp_valid, in_rsp_ready;
+  logic [CFG.SET_ALIGN-1:0]     lookup_set, write_set;
+  logic                         lookup_hit, lookup_valid, lookup_ready;
   logic [CFG.COUNT_ALIGN-1:0]   write_addr;
-  logic [CFG.SET_ALIGN-1:0]     write_set;
-  logic [CFG.LINE_WIDTH-1:0]    write_data;
   logic [CFG.TAG_WIDTH-1:0]     write_tag;
-  logic                         write_error;
-  logic                         write_valid;
-  logic                         write_ready;
-
-  // The axi_to_cache module converts AXI requests to cache requests and
-  // reconstructs AXI responses from the cache's responses
+  logic                         write_valid, write_ready;
+
   snitch_axi_to_cache #(
     .MaxTrans ( MaxTrans   ),
     .req_t    ( axi_req_t  ),
@@ -256,68 +332,58 @@
   ) i_axi_to_cache (
     .clk_i,
     .rst_ni,
-    // Cache request
     .req_addr_o  ( in_addr          ),
     .req_id_o    ( in_id            ),
     .req_valid_o ( in_valid         ),
     .req_ready_i ( in_ready         ),
-    // Cache response
     .rsp_data_i  ( in_rsp_data      ),
     .rsp_error_i ( in_rsp_error     ),
     .rsp_id_i    ( in_rsp_id        ),
     .rsp_valid_i ( in_rsp_valid     ),
     .rsp_ready_o ( in_rsp_ready     ),
-    // AXI
     .slv_req_i   ( demux_req[Cache] ),
     .slv_rsp_o   ( demux_rsp[Cache] )
   );
 
-  // The lookup module contains the actual cache RAMs and performs lookups.
   snitch_ro_cache_lookup #(
-    .CFG              ( CFG ),
-    .sram_cfg_tag_t   ( sram_cfg_tag_t  ),
-    .sram_cfg_data_t  ( sram_cfg_data_t )
+    .CFG             ( CFG             ),
+    .sram_cfg_tag_t  ( sram_cfg_tag_t  ),
+    .sram_cfg_data_t ( sram_cfg_data_t )
   ) i_lookup (
     .clk_i,
     .rst_ni,
-
-    .flush_valid_i ( flush_valid_i ),
-    .flush_ready_o ( flush_ready_o ),
-
-    .in_addr_i     ( in_addr       ),
-    .in_id_i       ( in_id         ),
-    .in_valid_i    ( in_valid      ),
-    .in_ready_o    ( in_ready      ),
-
-    .out_addr_o    ( lookup_addr   ),
-    .out_id_o      ( lookup_id     ),
-    .out_set_o     ( lookup_set    ),
-    .out_hit_o     ( lookup_hit    ),
-    .out_data_o    ( lookup_data   ),
-    .out_error_o   ( lookup_error  ),
-    .out_valid_o   ( lookup_valid  ),
-    .out_ready_i   ( lookup_ready  ),
-
-    .write_addr_i  ( write_addr    ),
-    .write_set_i   ( write_set     ),
-    .write_data_i  ( write_data    ),
-    .write_tag_i   ( write_tag     ),
-    .write_error_i ( write_error   ),
-    .write_valid_i ( write_valid   ),
-    .write_ready_o ( write_ready   ),
-
+    .flush_valid_i ( lookup_flush_valid ),
+    .flush_ready_o ( lookup_flush_ready ),
+    .init_busy_o   ( lookup_init_busy   ),
+    .inval_valid_i ( inval_valid        ),
+    .inval_addr_i  ( inval_idx_q        ),
+    .inval_ready_o ( inval_ready        ),
+    .in_addr_i     ( in_addr            ),
+    .in_id_i       ( in_id              ),
+    .in_valid_i    ( in_valid           ),
+    .in_ready_o    ( in_ready           ),
+    .out_addr_o    ( lookup_addr        ),
+    .out_id_o      ( lookup_id          ),
+    .out_set_o     ( lookup_set         ),
+    .out_hit_o     ( lookup_hit         ),
+    .out_data_o    ( lookup_data        ),
+    .out_error_o   ( lookup_error       ),
+    .out_valid_o   ( lookup_valid       ),
+    .out_ready_i   ( lookup_ready       ),
+    .write_addr_i  ( write_addr         ),
+    .write_set_i   ( write_set          ),
+    .write_data_i  ( write_data         ),
+    .write_tag_i   ( write_tag          ),
+    .write_error_i ( write_error        ),
+    .write_valid_i ( write_valid        ),
+    .write_ready_o ( write_ready        ),
     .sram_cfg_tag_i,
     .sram_cfg_data_i
   );
 
-  // The handler module deals with the result of the lookup. It also
-  // keeps track of the pending refills and ensures that no redundant memory
-  // requests are made. Upon refill completion, it sends a new tag/data item
-  // to the lookup module and sends the final cache response.
   snitch_icache_handler #(CFG) i_handler (
     .clk_i,
     .rst_ni,
-
     .in_req_addr_i   ( lookup_addr       ),
     .in_req_id_i     ( lookup_id         ),
     .in_req_set_i    ( lookup_set        ),
@@ -326,13 +392,11 @@
     .in_req_error_i  ( lookup_error      ),
     .in_req_valid_i  ( lookup_valid      ),
     .in_req_ready_o  ( lookup_ready      ),
-
     .in_rsp_data_o   ( in_rsp_data       ),
     .in_rsp_error_o  ( in_rsp_error      ),
     .in_rsp_id_o     ( in_rsp_id         ),
     .in_rsp_valid_o  ( in_rsp_valid      ),
     .in_rsp_ready_i  ( in_rsp_ready      ),
-
     .write_addr_o    ( write_addr        ),
     .write_set_o     ( write_set         ),
     .write_data_o    ( write_data        ),
@@ -340,12 +404,10 @@
     .write_error_o   ( write_error       ),
     .write_valid_o   ( write_valid       ),
     .write_ready_i   ( write_ready       ),
-
     .out_req_addr_o  ( handler_req_addr  ),
     .out_req_id_o    ( handler_req_id    ),
     .out_req_valid_o ( handler_req_valid ),
     .out_req_ready_i ( handler_req_ready ),
-
     .out_rsp_data_i  ( handler_rsp_data  ),
     .out_rsp_error_i ( handler_rsp_error ),
     .out_rsp_id_i    ( handler_rsp_id    ),
@@ -353,7 +415,6 @@
     .out_rsp_ready_o ( handler_rsp_ready )
   );
 
-  // The cache refill module emits AXI transactions.
   snitch_ro_cache_refill #(
     .CFG       ( CFG        ),
     .axi_req_t ( axi_req_t  ),
@@ -361,27 +422,21 @@
   ) i_refill (
     .clk_i,
     .rst_ni,
-
     .in_req_addr_i   ( handler_req_addr  ),
     .in_req_id_i     ( handler_req_id    ),
     .in_req_bypass_i ( 1'b0              ),
     .in_req_valid_i  ( handler_req_valid ),
     .in_req_ready_o  ( handler_req_ready ),
-
     .in_rsp_data_o   ( handler_rsp_data  ),
     .in_rsp_error_o  ( handler_rsp_error ),
     .in_rsp_id_o     ( handler_rsp_id    ),
-    .in_rsp_bypass_o ( /* left open */   ),
+    .in_rsp_bypass_o (                   ),
     .in_rsp_valid_o  ( handler_rsp_valid ),
     .in_rsp_ready_i  ( handler_rsp_ready ),
-
     .axi_req_o       ( refill_req        ),
     .axi_rsp_i       ( refill_rsp        )
   );
 
-  // --------------------------------------------------
-  // AXI Mux
-  // --------------------------------------------------
   axi_mux #(
     .SlvAxiIDWidth ( AxiIdWidth        ),
     .slv_aw_chan_t ( axi_aw_chan_t     ),

--- a/environment/public/code/snitch_axi_to_cache.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_axi_to_cache.sv (Golden Reference)
@@ -2,47 +2,35 @@
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
 
-// Author: Samuel Riedel <sriedel@iis.ee.ethz.ch>
-//
-// Adapted from the axi_burst_splitter authored by:
-//   Andreas Kurth       <akurth@iis.ee.ethz.ch>
-//   Florian Zaruba      <zarubaf@iis.ee.ethz.ch>
-//   Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
-
 `include "common_cells/registers.svh"
 
-/// Convert from AXI to Cache requests and reconstruct response beats on the way back
-/// Adapted from axi_burst_splitter
+/// Convert from AXI to Cache requests and reconstruct response beats on the way back.
 module snitch_axi_to_cache #(
-  // Maximum number of AXI read bursts outstanding at the same time
   parameter int unsigned MaxTrans           = 32'd0,
-  // AXI Bus Types
   parameter type         req_t              = logic,
   parameter type         resp_t             = logic,
   parameter snitch_icache_pkg::config_t CFG = '0
 )(
   input  logic                         clk_i,
   input  logic                         rst_ni,
-  // Cache request
   output logic [CFG.FETCH_AW-1:0]      req_addr_o,
   output logic [CFG.ID_WIDTH_REQ-1:0]  req_id_o,
   output logic                         req_valid_o,
   input  logic                         req_ready_i,
-  // Cache response
   input  logic [CFG.LINE_WIDTH-1:0]    rsp_data_i,
   input  logic                         rsp_error_i,
   input  logic [CFG.ID_WIDTH_RESP-1:0] rsp_id_i,
   input  logic                     
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/addr_decode.sv`](environment/public/code/addr_decode.sv) *(Read-Only Context)*
- [`environment/public/code/axi/assign.svh`](environment/public/code/axi/assign.svh) *(Read-Only Context)*
- [`environment/public/code/axi/typedef.svh`](environment/public/code/axi/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/axi_demux.sv`](environment/public/code/axi_demux.sv) *(Read-Only Context)*
- [`environment/public/code/axi_demux_simple.sv`](environment/public/code/axi_demux_simple.sv) *(Read-Only Context)*
- [`environment/public/code/axi_id_prepend.sv`](environment/public/code/axi_id_prepend.sv) *(Read-Only Context)*
- [`environment/public/code/axi_mux.sv`](environment/public/code/axi_mux.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cc_onehot.sv`](environment/public/code/cc_onehot.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/assertions.svh`](environment/public/code/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/common_cells/registers.svh`](environment/public/code/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/counter.sv`](environment/public/code/counter.sv) *(Read-Only Context)*
- [`environment/public/code/delta_counter.sv`](environment/public/code/delta_counter.sv) *(Read-Only Context)*
- [`environment/public/code/fall_through_register.sv`](environment/public/code/fall_through_register.sv) *(Read-Only Context)*
- [`environment/public/code/fifo_v3.sv`](environment/public/code/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/id_queue.sv`](environment/public/code/id_queue.sv) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/onehot_to_bin.sv`](environment/public/code/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_axi_to_cache.sv`](environment/public/code/snitch_axi_to_cache.sv) **(Editable)**
- [`environment/public/code/snitch_icache_handler.sv`](environment/public/code/snitch_icache_handler.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_icache_lfsr.sv`](environment/public/code/snitch_icache_lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_icache_pkg.sv`](environment/public/code/snitch_icache_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_read_only_cache.sv`](environment/public/code/snitch_read_only_cache.sv) **(Editable)**
- [`environment/public/code/snitch_ro_cache_lookup.sv`](environment/public/code/snitch_ro_cache_lookup.sv) **(Editable)**
- [`environment/public/code/snitch_ro_cache_refill.sv`](environment/public/code/snitch_ro_cache_refill.sv) **(Editable)**
- [`environment/public/code/snitch_ro_cache_subsys.sv`](environment/public/code/snitch_ro_cache_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter.sv`](environment/public/code/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter_flushable.sv`](environment/public/code/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_demux.sv`](environment/public/code/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/code/tc_sram_impl.sv`](environment/public/code/tc_sram_impl.sv) *(Read-Only Context)*
- [`environment/public/constraints/snitch_ro_cache.sdc`](environment/public/constraints/snitch_ro_cache.sdc) **(Editable)**
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

