# `case_25010`: Snitch Two-Port 6-SRAM Instruction Cache Coherence, AXI Refill Error Containment & SG13G2 Macro PnR

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25010` |
| **Source Silicon Repository** | `pulp-platform/snitch` (`repo_22`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `MultiCore_SoCs_and_NoC` (MultiCore_SoCs_and_NoC) |
| **Multi-Domain Tags** | `MultiCore_SoCs_and_NoC` |
| **Editable Files (`allowed_edits`)** | [`code/snitch_icache.sv`](environment/public/code/snitch_icache.sv), [`code/snitch_icache_l0.sv`](environment/public/code/snitch_icache_l0.sv), [`code/snitch_icache_lookup.sv`](environment/public/code/snitch_icache_lookup.sv), [`code/snitch_icache_handler.sv`](environment/public/code/snitch_icache_handler.sv), [`code/snitch_icache_refill.sv`](environment/public/code/snitch_icache_refill.sv), [`plan/macro_placement.json`](environment/public/plan/macro_placement.json), [`constraints/snitch_icache.sdc`](environment/public/constraints/snitch_icache.sdc) (7 files, 1888 LOC) |
| **Public Subsystem Context** | 29 RTL files (5852 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1800s` total (`900s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Snitch Two-Port 6-SRAM Instruction Cache Coherence & Physical Macro Co-Design

## Overview
`snitch_icache_subsys` (`code/snitch_icache_subsys.sv`) wraps PULP Snitch's two-port L0/L1 non-blocking instruction cache (`NR_FETCH_PORTS=2`, `LINE_WIDTH=128`, `LINE_COUNT=256`, `WAY_COUNT=2`, `PENDING_COUNT=2`, `FILL_DW=64`, `ISO_CROSSING=0`) backed by six `RM_IHPSG13_1P_256x64_c2_bm_bist` 1P 256x64 hard SRAM macros (`2` tag + `4` data banks). You own the RTL-to-physical co-design across:
- `code/snitch_icache.sv`, `code/snitch_icache_l0.sv`, `code/snitch_icache_lookup.sv`, `code/snitch_icache_handler.sv`, `code/snitch_icache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_icache.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Coherence Contract
1. **Two-Port Fetch & Cache-Line-Aligned AXI4 Refill**:
   - Serve concurrent 32-bit cacheable (`inst_cacheable_i[p]=1`) and bypass (`inst_cacheable_i[p]=0`) instruction fetches on Ports `0..1` (`inst_addr_{0,1}_i`, `inst_valid_i`, `inst_ready_o`, `inst_data_{0,1}_o`, `inst_error_o`), including optional L0 next-line prefetching (`enable_prefetching_i`).
   - All cacheable and bypass AXI4 read requests issued by the refill engine must use 16-byte line-aligned 2-beat `INCR` bursts (`axi_ar_addr_o[3:0] == 4'h0`, `axi_ar_len_o == 8'd1`, `axi_ar_size_o == 3'd3`, `axi_ar_burst_o == 2'b01`), regardless of which 32-bit word offset within the 128-bit line was requested.
2. **Per-Port & Global `FENCE.I` Flush Coherence (`flush_valid_i[1:0]` / `flush_ready_o[1:0]`)**:
   - Completing a handshake on `flush_valid_i[p]`/`flush_ready_o[p]` must invalidate Port `p`'s L0 buffer and shared L1 state, and prevent any in-flight pre-flush refill from populating L1/L0 or returning stale pre-flush instructions on subsequent fetches.
   - Single-port flushes (`2'b01` or `2'b10`) must not drop, deadlock, or corrupt concurrent in-flight requests on the un-flushed port—even when both ports coalesced onto the same L1 MSHR entry.
3. **Multi-Beat AXI4 Error Containment (`axi_r_resp_i[1] == 1'b1`)**:
   - An AXI read error (`SLVERR`/`DECERR`) on **any** beat of a cacheable refill burst (or bypass read) must retire a demand fetch with `inst_error_o[p] == 1'b1` and must never allocate/validate the errored line in L1 or L0, allowing subsequent fetches to cleanly re-issue on AXI once memory recovers.
   - Speculative L0 next-line prefetches that encounter an AXI read error must silently discard the errored refill without poisoning L1/L0 or asserting `inst_error_o` on demand fetches to valid addresses.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2400, 1600]` um, core area `[50, 50, 2350, 1550]` um. Place all six `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2.0` um core margin, `>= 8.0` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/snitch_icache.sdc`)**: Constrain `clk_i` to period `<= 11.5` ns with `>= 1.2` ns input/output delays on all non-clock ports (only `rst_ni` may carry `set_false_path`; no multicycle, clock-group, case-analysis, or max/min-delay overrides).
- **Synthesis & OpenROAD Signoff**: Zero inferred latches, all six `RM_IHPSG13_1P_256x64_c2_bm_bist` macros preserved, connected `VDD`/`VSS` PDN grids, post-GRT setup slack `>= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 10`, and total routed wirelength `<= 1,850,000` um.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment (`case_25010`)

## Available Tools & Collateral
- **RTL Simulation**: Verilator (`verilator --binary --timing`) or Icarus Verilog (`iverilog -g2012`)
- **Synthesis**: Yosys with SystemVerilog Slang frontend (`yosys -m slang`)
- **Physical Implementation & STA**: OpenROAD (`openroad -exit`)
- **PDK Collateral (`pdk/`)**: IHP SG13G2 130nm standard cells (`sg13g2_tech.lef`, `sg13g2_stdcell.lef`, `sg13g2_stdcell_typ_1p20V_25C.lib`, `core.v`) and `RM_IHPSG13_1P_256x64_c2_bm_bist` hard SRAM macro views (`256.v` behavioral model, `256_stub.v` blackbox stub, `256.lef`, `256.lib`).

## Editable Files
- `code/snitch_icache.sv`
- `code/snitch_icache_l0.sv`
- `code/snitch_icache_lookup.sv`
- `code/snitch_icache_handler.sv`
- `code/snitch_icache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_icache.sdc`

## Example Commands
```bash
# 1. RTL Elaboration & Lint Check
verilator --lint-only -Wno-fatal -Wno-UNOPTFLAT -Icode -top-module snitch_icache_subsys \
  pdk/core.v pdk/256.v code/axi_pkg.sv code/cf_math_pkg.sv code/riscv_instr.sv \
  code/snitch_icache_pkg.sv code/cc_onehot.sv code/lzc.sv code/onehot_to_bin.sv \
  code/rr_arb_tree.sv code/spill_register_flushable.sv code/spill_register.sv \
  code/fall_through_register.sv code/fifo_v3.sv code/isochronous_4phase_handshake.sv \
  code/isochronous_spill_register.sv code/stream_arbiter_flushable.sv \
  code/stream_arbiter.sv code/stream_demux.sv code/tc_sram_impl.sv \
  code/snitch_icache_lfsr.sv code/snitch_icache_l0.sv code/snitch_icache_lookup.sv \
  code/snitch_icache_handler.sv code/snitch_icache_refill.sv \
  code/snitch_icache.sv code/snitch_icache_subsys.sv

# 2. Synthesis to SG13G2 Standard Cells + 6x Hard SRAM Macros
yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode pdk/256_stub.v code/axi_pkg.sv code/cf_math_pkg.sv \
    code/riscv_instr.sv code/snitch_icache_pkg.sv code/cc_onehot.sv code/lzc.sv \
    code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
    code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
    code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
    code/tc_sram_impl.sv code/snitch_icache_lfsr.sv code/snitch_icache_l0.sv \
    code/snitch_icache_lookup.sv code/snitch_icache_handler.sv \
    code/snitch_icache_refill.sv code/snitch_icache.sv code/snitch_icache_subsys.sv \
    --top snitch_icache_subsys;
  hierarchy -check -top snitch_icache_subsys;
  synth -noabc -top snitch_icache_subsys -flatten;
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
--- a/environment/public/code/snitch_icache.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_icache.sv (Golden Reference)
@@ -339,12 +339,13 @@
 
     /// Arbitrate cache port
     // 1. Request Side
-    stream_arbiter #(
+    stream_arbiter_flushable #(
         .DATA_T ( prefetch_req_t ),
         .N_INP  ( NR_FETCH_PORTS )
     ) i_stream_arbiter (
         .clk_i,
         .rst_ni,
+        .flush_i     ( |flush_valid_i            ),
         .inp_data_i  ( prefetch_req              ),
         .inp_valid_i ( prefetch_req_valid        ),
         .inp_ready_o ( prefetch_req_ready        ),
@@ -419,6 +420,7 @@
 
         .flush_valid_i (flush_valid_lookup  ),
         .flush_ready_o (flush_ready_lookup  ),
+        .flush_ports_i (flush_valid_i       ),
 
         .in_addr_i     ( prefetch_lookup_req.addr  ),
         .in_id_i       ( prefetch_lookup_req.id    ),
@@ -453,6 +455,9 @@
     snitch_icache_handler #(CFG) i_handler (
         .clk_i,
         .rst_ni,
+
+        .flush_valid_i   ( flush_valid_lookup ),
+        .flush_ports_i   ( flush_valid_i      ),
 
         .in_req_addr_i   ( lookup_addr        ),
         .in_req_id_i     ( lookup_id          ),

--- a/environment/public/code/snitch_icache_l0.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_icache_l0.sv (Golden Reference)
@@ -75,6 +75,11 @@
   // Holds the onehot signal for the line being refilled at the moment
   logic [CFG.L0_LINE_COUNT-1:0] pending_line_refill_q;
   logic pending_refill_q, pending_refill_d;
+  logic pending_is_prefetch_q, pending_is_prefetch_d;
+  logic [CFG.L0_TAG_WIDTH-1:0] pending_tag_q, pending_tag_d;
+  logic err_rsp_vld_q, err_rsp_vld_d;
+  logic [CFG.L0_TAG_WIDTH-1:0] err_rsp_tag_q, err_rsp_tag_d;
+  logic err_retire_hit;
 
   logic evict_req;
   logic last_cycle_was_miss_q;
@@ -121,7 +126,8 @@
 
   assign hit_any = |hit;
   assign hit_prefetch_any = |hit_prefetch;
-  assign miss = ~hit_any & in_valid_i & ~pending_refill_q;
+  assign err_retire_hit = err_rsp_vld_q & ~flush_valid_i & in_valid_i & (addr_tag == err_rsp_tag_q);
+  assign miss = ~hit_any & in_valid_i & ~pending_refill_q & ~flush_valid_i & ~err_rsp_vld_q;
 
   for (genvar i = 0; i < CFG.L0_LINE_COUNT; i++) begin : gen_array
     // Tag Array
@@ -156,8 +162,8 @@
   // ----
   // HIT
   // ----
-  // we hit in the cache and there was a unique hit.
-  assign in_ready_o = hit_any;
+  // we hit in the cache and there was a unique hit, or we are retiring an errored demand miss.
+  assign in_ready_o = (hit_any & ~flush_valid_i) | err_retire_hit;
 
   logic [CFG.LINE_WIDTH-1:0] ins_data;
   always_comb begin : data_muxer
@@ -224,29 +230,46 @@
 
   `FFLNR(pending_line_refill_q, evict_strb, evict_req, clk_i)
   `FF(pending_refill_q, pending_refill_d, '0)
+  `FF(pending_is_prefetch_q, pending_is_prefetch_d, '0)
+  `FF(pending_tag_q, pending_tag_d, '0)
+  `FF(err_rsp_vld_q, err_rsp_vld_d, '0)
+  `FF(err_rsp_tag_q, err_rsp_tag_d, '0)
 
   always_comb begin
-    pending_refill_d = pending_refill_q;
-    // re-set condition
-    if (pending_refill_q) begin
+    pending_refill_d      = pending_refill_q;
+    pending_is_prefetch_d = pending_is_prefetch_q;
+    pending_tag_d         = pending_tag_q;
+    err_rsp_vld_d         = 1'b0;
+    err_rsp_tag_d         = err_rsp_tag_q;
+
+    if (flush_valid_i) begin
+      pending_refill_d = 1'b0;
+    end else if (pending_refill_q) begin
       if (out_rsp_valid_i & out_rsp_ready_o) begin
         pending_refill_d = 1'b0;
-      end
-    // set condition
+        if (out_rsp_error_i && !pending_is_prefetch_q) begin
+          err_rsp_vld_d = 1'b1;
+          err_rsp_tag_d = pending_tag_q;
+        end
+      end
     end else begin
       if (refill_valid && refill_ready) begin
-        pending_refill_d = 1'b1;
-      end
-      if (latch_prefetch) begin
-        pending_refill_d = 1'b1;
-      end
-    end
-  end
-
-  assign validate_strb = out_rsp_valid_i ? pending_line_refill_q : '0;
+        pending_refill_d      = 1'b1;
+        pending_is_prefetch_d = 1'b0;
+        pending_tag_d         = addr_tag;
+      end else if (latch_prefetch) begin
+        pending_refill_d      = 1'b1;
+        pending_is_prefetch_d = 1'b1;
+        pending_tag_d         = addr_tag_prefetch;
+      end
+    end
+  end
+
+  assign validate_strb = (out_rsp_valid_i && pending_refill_q && !out_rsp_error_i && !flush_valid_i)
+                         ? pending_line_refill_q : '0;
   assign out_rsp_ready_o = 1'b1;
 
-  assign in_error_o = '0;
+  assign in_error_o = err_retire_hit;
 
   assign out_req_addr_o = out_req.addr;
   assign out_req_id_o = {L0_ID, out_req.is_prefetch};
@@ -271,7 +294,7 @@
   // -------------
   // Generate a prefetch request if the cache hits and we haven't
   // pre-fetched the line yet and there is no other refill in progress.
-  assign prefetcher_out.vld = enable_prefetching_i &
+  assign prefetcher_out.vld = enable_prefetching_i & ~flush_valid_i &
                               hit_any & ~hit_prefetch_any &
                               hit_early_is_onehot & ~pending_refill_q;
 
@@ -356,15 +379,15 @@
   // check whether cache-line we want to pre-fetch is already present
   assign addr_tag_prefetch = prefetcher_out.addr >> CFG.LINE_ALIGN;
 
-  assign latch_prefetch = prefetcher_out.vld & ~prefetch_req_vld_q;
+  assign latch_prefetch = prefetcher_out.vld & ~prefetch_req_vld_q & ~flush_valid_i;
 
   always_comb begin
       prefetch_req_vld_d = prefetch_req_vld_q;
       prefetch_req_addr_d = prefetch_req_addr_q;
 
-      if (prefetch_ready) prefetch_req_vld_d = 1'b0;
-
-      if (latch_prefetch) begin
+      if (flush_valid_i || prefetch_ready) prefetch_req_vld_d = 1'b0;
+
+      if (!flush_valid_i && latch_prefetch) begin
           prefetch_req_vld_d = 1'b1;
           prefetch_req_addr_d = prefetcher_out.addr;
       end
@@ -372,7 +395,7 @@
 
   assign prefetch.is_prefetch = 1'b1;
   assign prefetch.addr = prefetch_req_addr_q;
-  assign prefetch_valid = prefetch_req_vld_q;
+  assign prefetch_valid = prefetch_req_vld_q & ~flush_valid_i;
 
   `FF(prefetch_req_vld_q, prefetch_req_vld_d, '0)
   `FFNR(prefetch_req_addr_q, prefetch_req_addr_d, clk_i)
@@ -399,9 +422,9 @@
   `ASSERT(InstReqStable, in_valid_i && !in_ready_o |=> in_valid_i)
   `ASSERT(InstReqDataStable, in_valid_i && !in_ready_o |=> $stable(in_addr_i))
 
-  `ASSERT(RefillReqStable, out_req_valid_o && !out_req_ready_i |=> out_req_valid_o)
+  `ASSERT(RefillReqStable, out_req_valid_o && !out_req_ready_i && !flush_valid_i |=> out_req_valid_o || flush_valid_i)
   `ASSERT(RefillReqDataStable,
-    out_req_valid_o && !out_req_ready_i |=> $stable(out_req_addr_o) && $stable(out_req_id_o))
+    out_req_valid_o && !out_req_ready_i && !flush_valid_i |=> ($stable(out_req_addr_o) && $stable(out_req_id_o)) || flush_valid_i)
 
   `ASSERT(RefillRspStable, out_rsp_valid_i && !out_rsp_ready_o |=> out_rsp_valid_i)
   `ASSERT(RefillRspDataStable,

--- a/environment/public/code/snitch_icache_lookup.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_icache_lookup.sv (Golden Reference)
@@ -2,12 +2,9 @@
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
 
-// Fabian Schuiki <fschuiki@iis.ee.ethz.ch>
-
-/// An actual cache lookup.
+/// Cache tag/data SRAM lookup with timing-isolated, per-port flush-safe output register.
 module snitch_icache_lookup #(
     parameter snitch_icache_pkg::config_t CFG = '0,
-    /// Configuration input types for SRAMs used in implementation.
     parameter type sram_cfg_data_t  = logic,
     parameter type sram_cfg_tag_t   = logic
 )(
@@ -16,6 +13,7 @@
 
     input  logic flush_valid_i,
     output logic flush_ready_o,
+    input  logic [CFG.NR_FETCH_PORTS-1:0] flush_ports_i,
 
     input  logic [CFG.FETCH_AW-1:0]     in_addr_i,
     input  logic [CFG.ID_WIDTH_REQ-1:0] in_id_i,
@@ -47,159 +45,153 @@
     initial assert(CFG != '0);
     `endif
 
-    // Multiplex read and write access to the RAMs onto one port, prioritizing
-    // write accesses.
-    logic [CFG.COUNT_ALIGN-1:0] ram_addr                             ;
-    logic [CFG.SET_COUNT-1:0]   ram_enable                           ;
-    logic [CFG.LINE_WIDTH-1:0]  ram_wdata, ram_rdata [CFG.SET_COUNT] ;
-    logic [CFG.TAG_WIDTH+1:0]   ram_wtag,  ram_rtag  [CFG.SET_COUNT] ;
-    logic                       ram_write                            ;
+    logic [CFG.COUNT_ALIGN-1:0] ram_addr;
+    logic [CFG.SET_COUNT-1:0]   ram_enable;
+    logic [CFG.LINE_WIDTH-1:0]  ram_wdata, ram_rdata [CFG.SET_COUNT];
+    logic [CFG.TAG_WIDTH+1:0]   ram_wtag,  ram_rtag  [CFG.SET_COUNT];
+    logic                       ram_write;
     logic                       ram_write_q;
     logic [CFG.COUNT_ALIGN:0]   init_count_q;
 
     typedef struct packed {
-      logic [CFG.SET_ALIGN-1:0]   cset;
-      logic                       hit;
-      logic [CFG.LINE_WIDTH-1:0]  data;
-      logic                       error;
-    } out_buffer_t;
-
-    out_buffer_t data_d, data_q;
-    logic        buffer_ready;
-    logic        buffer_valid;
+        logic [CFG.FETCH_AW-1:0]     addr;
+        logic [CFG.ID_WIDTH_REQ-1:0] id;
+        logic [CFG.SET_ALIGN-1:0]    cset;
+        logic                        hit;
+        logic [CFG.LINE_WIDTH-1:0]   data;
+        logic                        error;
+    } lookup_pipe_t;
+
+    lookup_pipe_t pipe_d, pipe_q;
+    logic         pipe_valid_q;
+    logic         valid_q;
+    logic [CFG.FETCH_AW-1:0]     addr_q;
+    logic [CFG.ID_WIDTH_REQ-1:0] id_q;
+
+    // Issue SRAM read only when neither SRAM output stage nor output register is occupied,
+    // completely decoupling forward/backward timing paths and guaranteeing zero overwrite on stall.
+    wire can_issue_read = !flush_valid_i && !valid_q && !pipe_valid_q;
 
     always_comb begin : p_portmux
-        write_ready_o = 0;
-        in_ready_o = 0;
-
-        ram_addr   = in_addr_i >> CFG.LINE_ALIGN;
-        ram_wdata  = write_data_i;
-        ram_wtag   = {1'b1, write_error_i, write_tag_i};
-        ram_enable = '0;
-        ram_write  = 1'b0;
+        write_ready_o = 1'b0;
+        in_ready_o    = 1'b0;
+
+        ram_addr      = CFG.COUNT_ALIGN'(in_addr_i >> CFG.LINE_ALIGN);
+        ram_wdata     = write_data_i;
+        ram_wtag      = {1'b1, write_error_i, write_tag_i};
+        ram_enable    = '0;
+        ram_write     = 1'b0;
 
         if (init_count_q != $unsigned(CFG.LINE_COUNT)) begin
-            ram_addr   = init_count_q;
+            ram_addr   = init_count_q[CFG.COUNT_ALIGN-1:0];
             ram_enable = '1;
             ram_write  = 1'b1;
             ram_wdata  = '0;
             ram_wtag   = '0;
-        end else  if (write_valid_i) begin
-            ram_addr   = write_addr_i;
-            ram_enable = CFG.SET_COUNT > 1 ? $unsigned(1 << write_set_i) : 1'b1;
-            ram_write  = 1'b1;
+        end else if (flush_valid_i) begin
+            ram_enable = '0;
+        end else if (write_valid_i) begin
+            ram_addr      = write_addr_i;
+            ram_enable    = CFG.SET_COUNT > 1 ? CFG.SET_COUNT'(1 << write_set_i) : 1'b1;
+            ram_write     = 1'b1;
             write_ready_o = 1'b1;
-        end else if (out_ready_i) begin
+        end else if (can_issue_read) begin
             ram_enable = in_valid_i ? '1 : '0;
             in_ready_o = 1'b1;
         end
     end
 
-    // We are always ready to flush
     assign flush_ready_o = 1'b1;
 
-    always_ff @(posedge clk_i, negedge rst_ni) begin
-        if (!rst_ni)
+    always_ff @(posedge clk_i or negedge rst_ni) begin
+        if (!rst_ni) begin
             init_count_q <= '0;
-        else if (init_count_q != $unsigned(CFG.LINE_COUNT))
-            init_count_q <= init_count_q + 1;
-        else if (flush_valid_i)
+        end else if (flush_valid_i) begin
             init_count_q <= '0;
-    end
-
-    always_ff @(posedge clk_i or negedge rst_ni) begin
-        if (!rst_ni) begin
-            ram_write_q <= 0;
+        end else if (init_count_q != $unsigned(CFG.LINE_COUNT)) begin
+            init_count_q <= init_count_q + 1'b1;
+        end
+    end
+
+    always_ff @(posedge clk_i or negedge rst_ni) begin
+        if (!rst_ni) begin
+            ram_write_q <= 1'b0;
         end else begin
             ram_write_q <= ram_write;
         end
     end
 
-    // The address register keeps track of additional metadata alongside the
-    // looked up tag and data.
-    logic valid_q;
-    logic [CFG.FETCH_AW-1:0] addr_q;
-    logic [CFG.ID_WIDTH_REQ-1:0] id_q;
-
-    always_ff @(posedge clk_i or negedge rst_ni) begin
-        if (!rst_ni) begin
-            valid_q <= 0;
+    always_ff @(posedge clk_i or negedge rst_ni) begin
+        if (!rst_ni) begin
+            valid_q <= 1'b0;
+            addr_q  <= '0;
+            id_q    <= '0;
+        end else if (in_valid_i && in_ready_o && !flush_ports_i[in_id_i >> 1]) begin
+            valid_q <= 1'b1;
+            addr_q  <= in_addr_i;
+            id_q    <= in_id_i;
         end else begin
-            if (CFG.BUFFER_LOOKUP) begin
-                valid_q <= in_valid_i && in_ready_o;
-            end else if ((in_valid_i && in_ready_o) || out_ready_i) begin
-                valid_q <= in_valid_i && in_ready_o;
-            end
-        end
-    end
-
-    always_ff @(posedge clk_i, negedge rst_ni) begin
-        if (!rst_ni) begin
-            addr_q <= '0;
-            id_q   <= '0;
-        end else if (in_valid_i && in_ready_o) begin
-            addr_q <= in_addr_i;
-            id_q   <= in_id_i;
-        end
-    end
-
-    // Instantiate the RAM sets.
+            valid_q <= 1'b0;
+        end
+    end
+
     for (genvar i = 0; i < CFG.SET_COUNT; i++) begin : g_sets
         tc_sram_impl #(
-          .NumWords (CFG.LINE_COUNT),
-          .DataWidth (CFG.TAG_WIDTH+2),
-          .ByteWidth (8),
-          .NumPorts (1),
-          .Latency (1),
-          .impl_in_t (sram_cfg_tag_t)
+            .NumWords  ( CFG.LINE_COUNT  ),
+            .DataWidth ( CFG.TAG_WIDTH+2 ),
+            .ByteWidth ( 8               ),
+            .NumPorts  ( 1               ),
+            .Latency   ( 1               ),
+            .impl_in_t ( sram_cfg_tag_t  )
         ) i_tag (
-          .clk_i (clk_i),
-          .rst_ni (rst_ni),
-          .impl_i (sram_cfg_tag_i),
-          .impl_o (  ),
-          .req_i (ram_enable[i]),
-          .we_i (ram_write),
-          .addr_i (ram_addr),
-          .wdata_i (ram_wtag),
-          .be_i ('1),
-          .rdata_o (ram_rtag[i])
+            .clk_i   ( clk_i           ),
+            .rst_ni  ( rst_ni          ),
+            .impl_i  ( sram_cfg_tag_i  ),
+            .impl_o  (                 ),
+            .req_i   ( ram_enable[i]   ),
+            .we_i    ( ram_write       ),
+            .addr_i  ( ram_addr        ),
+            .wdata_i ( ram_wtag        ),
+            .be_i    ( '1              ),
+            .rdata_o ( ram_rtag[i]     )
         );
 
         tc_sram_impl #(
-          .NumWords (CFG.LINE_COUNT),
-          .DataWidth (CFG.LINE_WIDTH),
-          .ByteWidth (8),
-          .NumPorts (1),
-          .Latency (1),
-          .impl_in_t (sram_cfg_data_t)
+            .NumWords  ( CFG.LINE_COUNT  ),
+            .DataWidth ( CFG.LINE_WIDTH  ),
+            .ByteWidth ( 8               ),
+            .NumPorts  ( 1               ),
+            .Latency   ( 1               ),
+            .impl_in_t ( sram_cfg_data_t )
         ) i_data (
-          .clk_i (clk_i),
-          .rst_ni (rst_ni),
-          .impl_i (sram_cfg_data_i),
-          .impl_o (  ),
-          .req_i (ram_enable[i]),
-          .we_i (ram_write),
-          .addr_i (ram_addr),
-          .wdata_i (ram_wdata),
-          .be_i ('1),
-          .rdata_o (ram_rdata[i])
+            .clk_i   ( clk_i           ),
+            .rst_ni  ( rst_ni          ),
+            .impl_i  ( sram_cfg_data_i ),
+            .impl_o  (                 ),
+            .req_i   ( ram_enable[i]   ),
+            .we_i    ( ram_write       ),
+            .addr_i  ( ram_addr        ),
+            .wdata_i ( ram_wdata       ),
+            .be_i    ( '1              ),
+            .rdata_o ( ram_rdata[i]    )
         );
     end
 
-    // Determine which RAM line hit, and multiplex that data to the output.
     logic [CFG.TAG_WIDTH-1:0] required_tag;
     logic [CFG.SET_COUNT-1:0] line_hit;
 
     always_comb begin
         automatic logic [CFG.SET_COUNT-1:0] errors;
-        required_tag = addr_q >> (CFG.LINE_ALIGN + CFG.COUNT_ALIGN);
+        required_tag = CFG.TAG_WIDTH'(addr_q >> (CFG.LINE_ALIGN + CFG.COUNT_ALIGN));
         for (int i = 0; i < CFG.SET_COUNT; i++) begin
             line_hit[i] = ram_rtag[i][CFG.TAG_WIDTH+1] &&
-              ram_rtag[i][CFG.TAG_WIDTH-1:0] == required_tag;
-            errors[i] = ram_rtag[i][CFG.TAG_WIDTH] && line_hit[i];
-        end
-        data_d.hit = |line_hit & ~ram_write_q; // Don't let refills trigger "valid" lookups
-        data_d.error = |errors;
+                          (ram_rtag[i][CFG.TAG_WIDTH-1:0] == required_tag);
+            errors[i]   = ram_rtag[i][CFG.TAG_WIDTH] && line_hit[i];
+        end
+        pipe_d.addr  = addr_q;
+        pipe_d.id    = id_q;
+        pipe_d.hit   = (|line_hit) & ~ram_write_q & ~flush_valid_i;
+        pipe_d.error = (|errors) & ~flush_valid_i;
     end
 
     always_comb begin
@@ -207,51 +199,44 @@
             automatic logic [CFG.SET_COUNT-1:0] masked;
             for (int j = 0; j < CFG.SET_COUNT; j++)
                 masked[j] = ram_rdata[j][i] & line_hit[j];
-            data_d.data[i] = |masked;
+            pipe_d.data[i] = |masked;
         end
     end
 
     lzc #(.WIDTH(CFG.SET_COUNT)) i_lzc (
-        .in_i     ( line_hit    ),
-        .cnt_o    ( data_d.cset ),
-        .empty_o  (             )
+        .in_i    ( line_hit    ),
+        .cnt_o   ( pipe_d.cset ),
+        .empty_o (             )
     );
 
-    // Buffer response in case we are stalled
-    if (CFG.BUFFER_LOOKUP) begin : gen_buffer
-      fall_through_register #(
-          .T          ( out_buffer_t )
-      ) i_rsp_buffer (
-          .clk_i      ( clk_i        ),
-          .rst_ni     ( rst_ni       ),
-          .clr_i      ( 1'b0         ),
-          .testmode_i ( 1'b0         ),
-          // Input port
-          .valid_i    ( valid_q      ),
-          .ready_o    ( buffer_ready ),
-          .data_i     ( data_d       ),
-          // Output port
-          .valid_o    ( buffer_valid ),
-          .ready_i    ( out_ready_i  ),
-          .data_o     ( data_q       )
-      );
-    end else begin : gen_connection
-      assign data_q = data_d;
-      assign buffer_valid = valid_q;
-      assign buffer_ready = 1'b1;
-    end
-
-    // Generate the output signals.
-    assign out_addr_o  = addr_q;
-    assign out_id_o    = id_q;
-    assign out_set_o   = data_q.cset;
-    assign out_hit_o   = data_q.hit;
-    assign out_data_o  = data_q.data;
-    assign out_error_o = data_q.error;
-    assign out_valid_o = buffer_valid;
-
-    // Assertions
-    `include "common_cells/assertions.svh"
-    `ASSERT(i_rsp_buffer_ready, (valid_q |-> buffer_ready), clk_i, !rst_ni)
+    always_ff @(posedge clk_i or negedge rst_ni) begin
+        if (!rst_ni) begin
+            pipe_valid_q <= 1'b0;
+            pipe_q       <= '0;
+        end else begin
+            if (valid_q && !flush_ports_i[id_q >> 1]) begin
+                pipe_valid_q <= 1'b1;
+                pipe_q       <= pipe_d;
+            end else if (pipe_valid_q) begin
+                if (flush_ports_i[pipe_q.id >> 1] || out_ready_i) begin
+                    pipe_valid_q <= 1'b0;
+                end else if (flush_valid_i) begin
+                    // Shared L1 was invalidated while another port's lookup was stalled;
+                    // downgrade hit to miss so it re-fetches post-flush memory!
+                    pipe_q.hit   <= 1'b0;
+                    pipe_q.error <= 1'b0;
+                end
+            end
+        end
+    end
+
+    wire pipe_port_flushed = flush_ports_i[pipe_q.id >> 1];
+    assign out_addr_o  = pipe_q.addr;
+    assign out_id_o    = pipe_q.id;
+    assign out_set_o   = pipe_q.cset;
+    assign out_hit_o   = pipe_q.hit & ~flush_valid_i;
+    assign out_data_o  = pipe_q.data;
+    assign out_error_o = pipe_q.error & ~flush_valid_i;
+    assign out_valid_o = pipe_valid_q & ~pipe_port_flushed;
 
 endmodule

--- a/environment/public/code/snitch_icache_handler.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_icache_handler.sv (Golden Reference)
@@ -1,8 +1,6 @@
 // Copyright 2020 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-
-// Fabian Schuiki <fschuiki@iis.ee.ethz.ch>
 
 `include "common_cells/registers.svh"
 
@@ -11,6 +9,9 @@
 )(
     input  logic clk_i,
     input  logic rst_ni,
+
+    input  logic                         flush_valid_i,
+    input  logic [CFG.NR_FETCH_PORTS-1:0] flush_ports_i,
 
     input  logic [CFG.FETCH_AW-1:0]      in_req_addr_i,
     input  logic [CFG.ID_WIDTH_REQ-1:0]  in_req_id_i,
@@ -51,22 +52,31 @@
     initial assert(CFG != '0);
     `endif
 
-    // The table of pending refills holds the metadata of all refills that are
-    // currently in flight. The table has a push and a pop interfaces. The push
-    // interface is used to mark entries as valid and update the mask of request
-    // IDs that the refill will serve. The pop interface is used to read a value
-    // from the table and clear its valid flag.
+    wire _unused_set = ^in_req_set_i;
+
+    logic [CFG.ID_WIDTH_RESP-1:0] flush_id_mask;
+    always_comb begin
+        flush_id_mask = '0;
+        for (int p = 0; p < CFG.NR_FETCH_PORTS; p++) begin
+            if (flush_ports_i[p]) begin
+                flush_id_mask[2*p +: 2] = 2'b11;
+            end
+        end
+    end
+
     typedef struct packed {
-        logic valid;
-        logic [CFG.FETCH_AW-1:0] addr;
-        logic [CFG.ID_WIDTH_RESP-1:0] idmask; // mask of incoming ids
+        logic                         valid;
+        logic                         stale;
+        logic [CFG.FETCH_AW-1:0]      addr;
+        logic [CFG.ID_WIDTH_RESP-1:0] idmask;
     } pending_t;
+
     pending_t pending_q [CFG.PENDING_COUNT];
     logic [CFG.PENDING_COUNT-1:0] pending_clr;
     logic [CFG.PENDING_COUNT-1:0] pending_set;
 
     logic [CFG.PENDING_IW-1:0]    push_index;
-    logic                         push_init;   // reset the idmask instead of or'ing
+    logic                         push_init;
     logic [CFG.FETCH_AW-1:0]      push_addr;
     logic [CFG.ID_WIDTH_RESP-1:0] push_idmask;
     logic                         push_enable;
@@ -74,42 +84,53 @@
     logic [CFG.PENDING_IW-1:0]    pop_index;
     logic [CFG.FETCH_AW-1:0]      pop_addr;
     logic [CFG.ID_WIDTH_RESP-1:0] pop_idmask;
+    logic                         pop_stale;
     logic                         pop_enable;
 
+    wire [CFG.FETCH_AW-1:0] req_line_addr = {in_req_addr_i[CFG.FETCH_AW-1:CFG.LINE_ALIGN], {CFG.LINE_ALIGN{1'b0}}};
+
     for (genvar i = 0; i < CFG.PENDING_COUNT; i++) begin : g_pending_row
-        always_ff @(posedge clk_i, negedge rst_ni) begin
-            if (!rst_ni)
-                pending_q[i].valid <= 0;
-            else if (pending_set[i] || pending_clr[i])
-                pending_q[i].valid <= pending_set[i] && ~pending_clr[i];
-        end
-
-        always_ff @(posedge clk_i, negedge rst_ni) begin
+        always_ff @(posedge clk_i or negedge rst_ni) begin
             if (!rst_ni) begin
-                pending_q[i].addr <= '0;
+                pending_q[i].valid  <= 1'b0;
+                pending_q[i].stale  <= 1'b0;
+                pending_q[i].addr   <= '0;
                 pending_q[i].idmask <= '0;
-            end else if (pending_set[i]) begin
-                pending_q[i].addr <= push_addr;
-                pending_q[i].idmask <= push_init ? push_idmask : push_idmask | pending_q[i].idmask;
-            end
-        end
-    end
-
-    // The bypass logic ensures that if a table entry is pushed and popped at
-    // the same time, the pop is updated with the push information and the push
-    // discarded.
+            end else begin
+                if (pending_clr[i] && !pending_set[i]) begin
+                    pending_q[i].valid  <= 1'b0;
+                    pending_q[i].stale  <= 1'b0;
+                    pending_q[i].idmask <= '0;
+                end else if (pending_set[i] && !pending_clr[i]) begin
+                    pending_q[i].valid  <= 1'b1;
+                    pending_q[i].addr   <= push_addr;
+                    if (push_init) begin
+                        pending_q[i].stale  <= flush_valid_i;
+                        pending_q[i].idmask <= push_idmask & ~flush_id_mask;
+                    end else begin
+                        pending_q[i].stale  <= pending_q[i].stale | fl
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cc_onehot.sv`](environment/public/code/cc_onehot.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/assertions.svh`](environment/public/code/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/common_cells/registers.svh`](environment/public/code/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/fall_through_register.sv`](environment/public/code/fall_through_register.sv) *(Read-Only Context)*
- [`environment/public/code/fifo_v3.sv`](environment/public/code/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/isochronous_4phase_handshake.sv`](environment/public/code/isochronous_4phase_handshake.sv) *(Read-Only Context)*
- [`environment/public/code/isochronous_spill_register.sv`](environment/public/code/isochronous_spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/onehot_to_bin.sv`](environment/public/code/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_instr.sv`](environment/public/code/riscv_instr.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_icache.sv`](environment/public/code/snitch_icache.sv) **(Editable)**
- [`environment/public/code/snitch_icache_handler.sv`](environment/public/code/snitch_icache_handler.sv) **(Editable)**
- [`environment/public/code/snitch_icache_l0.sv`](environment/public/code/snitch_icache_l0.sv) **(Editable)**
- [`environment/public/code/snitch_icache_lfsr.sv`](environment/public/code/snitch_icache_lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_icache_lookup.sv`](environment/public/code/snitch_icache_lookup.sv) **(Editable)**
- [`environment/public/code/snitch_icache_pkg.sv`](environment/public/code/snitch_icache_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_icache_refill.sv`](environment/public/code/snitch_icache_refill.sv) **(Editable)**
- [`environment/public/code/snitch_icache_subsys.sv`](environment/public/code/snitch_icache_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter.sv`](environment/public/code/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter_flushable.sv`](environment/public/code/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_demux.sv`](environment/public/code/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/code/tc_sram_impl.sv`](environment/public/code/tc_sram_impl.sv) *(Read-Only Context)*
- [`environment/public/constraints/snitch_icache.sdc`](environment/public/constraints/snitch_icache.sdc) **(Editable)**
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

