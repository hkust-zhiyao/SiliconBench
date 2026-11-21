# `case_5014`: CVA6 Write-Through Cache AXI64 Adapter 32-Bit AMO Operand Alignment, Concurrent Invalidation Buffering, AXI Shim AR/W Backpressure Stability, and Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_5014` |
| **Source Silicon Repository** | `openhwfoundation/cva6` (`repo_05`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `arithmetic_datapath`, `protocol_control`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/wt_axi_adapter.sv`](environment/public/code/wt_axi_adapter.sv), [`code/axi_shim.sv`](environment/public/code/axi_shim.sv), [`code/cva6_fifo_v3.sv`](environment/public/code/cva6_fifo_v3.sv) (3 files, 1325 LOC) |
| **Public Subsystem Context** | 14 RTL files (5463 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Task-Specific Multi-Corner Liberty & SDC Timing Views** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Custom characterized fast/slow/scan corner Liberty libraries for multi-mode OpenSTA closure. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CVA6 Write-Through Cache AXI64 Adapter 32-Bit AMO Operand Alignment, Concurrent Invalidation Buffering, AXI Shim AR/W Backpressure Stability, and Timing Closure

## Background

In the 64-bit CVA6 Write-Through Cache subsystem (`XLEN = 64`, `AxiDataWidth = 64`, `ICACHE_LINE_WIDTH = 128`, `DCACHE_LINE_WIDTH = 128`, `RVA = 1`), the L1 I-Cache and L1 D-Cache connect to the 64-bit AXI4+ATOP memory bus through (`flow/wt_axi_subsys_top.sv`):

- `code/wt_axi_adapter.sv`: buffers incoming `icache_data_i` and `dcache_data_i` requests in `cva6_fifo_v3` queues, arbitrates between I-Cache fills and D-Cache loads/stores/AMOs, tracks in-flight transaction IDs in `i_rd_icache_id` / `i_rd_dcache_id` / `i_wr_dcache_id` FIFOs, generates AXI5 atomic (`aw.atop`) and LR/SC (`ar.lock`/`aw.lock`) requests, emits D-Cache invalidations (`DCACHE_INV_REQ`) on external invalidations (`inval_valid_i`) and atomic self-invalidations (`invalidate`), and assembles 128-bit returning cachelines.
- `code/axi_shim.sv`: converts adapter read (`rd_*`) and write (`wr_*`) requests into AXI4 `AR`, `AW`, `W`, `R`, and `B` channel handshakes (`IDLE`, `WRITE`, `WRITE_WAIT`, `AW_WAIT` and `READ`, `READ_HOLD`).
- `code/cva6_fifo_v3.sv`: parameterized synchronous FIFO used for request, ID-tracking, and `B`-response buffering.

During verification and Nangate45 synthesis/STA sign-off of `wt_axi_subsys_top`, several functional bugs and timing closure bottlenecks were identified across `code/wt_axi_adapter.sv`, `code/axi_shim.sv`, and `code/cva6_fifo_v3.sv`.

## Problem Description & Architectural Requirements

1. **64-Bit AXI Bus Operand Replication for 32-Bit AMOs & Concurrent External/Self-Invalidation Preservation (`code/wt_axi_adapter.sv`)**:
   - In CVA6, the store/AMO unit places 32-bit atomic operands (`AMO_*.W`, `dcache_data.size[1:0] == 2'b10`) unshifted in the lower 32 bits `dcache_data.data[31:0]` even when the target physical address is aligned to the upper 32-bit word of the 64-bit AXI bus (`dcache_data.paddr[2:0] == 3'b100`, where `axi_wr_be[0] = 8'hF0`). Because `wt_axi_adapter.sv` computes `axi_wr_data[0] = {(AxiDataWidth/XLEN){dcache_data.data}}` (`1` copy when `AxiDataWidth == XLEN == 64`), upper-word 32-bit AMOs drive `dcache_data.data[63:32]` (zeros) onto `w_data_o[63:32]` instead of the 32-bit operand `dcache_data.data[31:0]`. For 32-bit atomic requests (`dcache_data.rtype == DCACHE_ATOMIC_REQ` and `dcache_data.size[1:0] == 2'b10`), replicate `dcache_data.data[31:0]` across both 32-bit halves (`{2{dcache_data.data[31:0]}}`, and `~{2{dcache_data.data[31:0]}}` for `AMO_AND`).
   - In `p_axi_rtrn_decode`, when an external invalidation (`inval_valid_i = 1'b1`) arrives in the same cycle that an atomic request is granted (`invalidate = 1'b1`), the `if (inval_valid_i) ... else if (CVA6Cfg.RVA && invalidate)` priority branch services `inval_valid_i` and silently drops the atomic self-invalidation! Buffer any colliding atomic self-invalidation index (`dcache_data.paddr[DCACHE_INDEX_WIDTH-1:0]`) and emit its `DCACHE_INV_REQ` packet on the following cycle.

2. **AXI Shim Unacknowledged `AR` / `W` Channel Stability & Burst Counter Gating (`code/axi_shim.sv`)**:
   - In `p_read_fsm`, when a read request is not immediately accepted (`ar_ready == 1'b0`), `axi_shim` transitions to `READ_HOLD` but fails to assert `axi_req_o.ar_valid = 1'b1` in `READ_HOLD`, violating the AXI4 handshake rule that `ar_valid` and `ar` must remain asserted and stable until `ar_ready` is high.
   - In `p_write_fsm`, when `AW` is accepted before `W` (`aw_ready = 1, w_ready = 0`), `axi_shim` transitions to `WRITE_WAIT`, where `axi_req_o.w` fails to preserve `w.last = (wr_cnt_q == 0)` and `wr_cnt_d` decrements unconditionally in `WRITE`/`WRITE_WAIT` even when `w_ready == 1'b0`. Only decrement `wr_cnt_q` on a completed `w_valid && w_ready` beat and keep `w_valid`, `w.data`, `w.strb`, `w.user`, and `w.last` valid and stable in `WRITE` and `WRITE_WAIT` until `w_ready` is high.

3. **Arbiter Lock-Path & FIFO Reset Fanout Optimization for Timing Closure (`code/wt_axi_adapter.sv`, `code/cva6_fifo_v3.sv`, `code/axi_shim.sv`)**:
   - In `code/wt_axi_adapter.sv`, instantiating `rr_arb_tree` with `LockIn = 1'b1` and `gnt_i = axi_rd_gnt | axi_wr_gnt` creates a deep combinational loop-back path from the request FIFOs through `arb_idx` -> `axi_shim` -> `arb_gnt` -> `arb_ack` -> ID FIFO write enables, and in `code/cva6_fifo_v3.sv`, resetting the entire `mem_n = '0` storage array under `if (flush_i)` adds unnecessary muxing on every FIFO bit.
   - Replace the 2-input `rr_arb_tree` lock wrapper with a direct round-robin arbiter (`rr_q`) qualified by the active channel grant, and remove the redundant `mem_n = '0` array clear on `flush_i` in `cva6_fifo_v3.sv`.
   - Under the Nangate45 synthesis and OpenROAD STA sign-off flow (`flow/wt_axi_subsys_top.sv` at a `2.35 ns` clock period on `clk_i` with `0.15 ns` input/output external delays and `abc -D 1000`):
     - Worst setup slack (`max`): `>= 0.00 ns`
     - Worst hold slack (`min`): `>= 0.00 ns`
     - Total cell area of `wt_axi_subsys_top`: `<= 6450.0 um^2`

## Deliverable

Update only the editable RTL files:
- `code/wt_axi_adapter.sv`
- `code/axi_shim.sv`
- `code/cva6_fifo_v3.sv`

Do not modify module port signatures or package definitions.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/wt_axi_adapter.sv`
- `code/axi_shim.sv`
- `code/cva6_fifo_v3.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/wt_axi_subsys_top.sv` (top module: `wt_axi_subsys_top`)
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
  --top-module wt_axi_subsys_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/axi_pkg.sv \
  code/wt_cache_pkg.sv \
  code/cf_math_pkg.sv \
  code/lzc.sv \
  code/rr_arb_tree.sv \
  code/cva6_fifo_v3.sv \
  code/axi_shim.sv \
  code/wt_axi_adapter.sv \
  flow/wt_axi_subsys_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p '
  read_slang --ignore-assertions --top wt_axi_subsys_top -Iinclude -DSYNTHESIS
    code/config_pkg.sv
    code/cv64a60ax_config_pkg.sv
    code/riscv_pkg.sv
    code/ariane_pkg.sv
    code/axi_pkg.sv
    code/wt_cache_pkg.sv
    code/cf_math_pkg.sv
    code/lzc.sv
    code/rr_arb_tree.sv
    code/cva6_fifo_v3.sv
    code/axi_shim.sv
    code/wt_axi_adapter.sv
    flow/wt_axi_subsys_top.sv;
  hierarchy -check -top wt_axi_subsys_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*;
  synth -top wt_axi_subsys_top -flatten;
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
create_clock -name core_clk -period 2.35 [get_ports clk_i]
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
link_design wt_axi_subsys_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `wt_axi_subsys_top`: `<= 6450.0 um^2`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/wt_axi_adapter.sv (Buggy Starter)
+++ b/solution/gold/code/wt_axi_adapter.sv (Golden Reference)
@@ -117,32 +117,21 @@
     ~(dcache_data_empty | dcache_wr_full | dcache_rd_full), ~(icache_data_empty | icache_rd_full)
   };
 
-  assign arb_gnt = axi_rd_gnt | axi_wr_gnt;
-
-  rr_arb_tree #(
-      .NumIn    (2),
-      .DataWidth(1),
-      .AxiVldRdy(1'b1),
-      .LockIn   (1'b1)
-  ) i_rr_arb_tree (
-      .clk_i  (clk_i),
-      .rst_ni (rst_ni),
-      .flush_i('0),
-      .rr_i   ('0),
-      .req_i  (arb_req),
-      .gnt_o  (arb_ack),
-      .data_i ('0),
-      .gnt_i  (arb_gnt),
-      .req_o  (),
-      .data_o (),
-      .idx_o  (arb_idx)
-  );
+  logic rr_q;
+  logic pending_self_inv_d, pending_self_inv_q;
+  logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] pending_self_inv_idx_d, pending_self_inv_idx_q;
+
+  assign arb_idx    = arb_req[1] & (~arb_req[0] | rr_q);
+  assign arb_gnt    = arb_idx ? ((axi_rd_req & axi_rd_gnt) | (axi_wr_req & axi_wr_gnt)) : (axi_rd_req & axi_rd_gnt);
+  assign arb_ack[0] = arb_req[0] & ~arb_idx & arb_gnt;
+  assign arb_ack[1] = arb_req[1] &  arb_idx & arb_gnt;
 
   // request side
   always_comb begin : p_axi_req
     // write channel
     axi_wr_id_in = {{CVA6Cfg.AxiIdWidth-1{1'b0}}, arb_idx};
-    axi_wr_data[0]  = {(CVA6Cfg.AxiDataWidth/CVA6Cfg.XLEN){dcache_data.data}};
+    axi_wr_data[0]  = (dcache_data.rtype == wt_cache_pkg::DCACHE_ATOMIC_REQ && dcache_data.size[1:0] == 2'b10) ?
+                      {2{dcache_data.data[31:0]}} : {(CVA6Cfg.AxiDataWidth/CVA6Cfg.XLEN){dcache_data.data}};
     axi_wr_user[0]  = dcache_data.user;
     // Cast to AXI address width
     axi_wr_addr  = CVA6Cfg.AxiAddrWidth'(dcache_data.paddr);
@@ -280,7 +269,8 @@
                 end
                 AMO_AND: begin
                   // in this case we need to invert the data to get a "CLR"
-                  axi_wr_data[0] = ~{(CVA6Cfg.AxiDataWidth / CVA6Cfg.XLEN) {dcache_data.data}};
+                  axi_wr_data[0] = (dcache_data.size[1:0] == 2'b10) ?
+                                   ~{2{dcache_data.data[31:0]}} : ~{(CVA6Cfg.AxiDataWidth / CVA6Cfg.XLEN) {dcache_data.data}};
                   axi_wr_user = ~{(CVA6Cfg.AxiDataWidth / CVA6Cfg.XLEN) {dcache_data.user}};
                   if (mbe_i) begin
                     axi_wr_atop = {
@@ -610,27 +600,25 @@
 
     // External invalidation requests (from coprocessor). This is safe as
     // there are no other transactions when a coprocessor has pending stores.
-    inval_ready_o      = 1'b0;
+    pending_self_inv_d     = pending_self_inv_q;
+    pending_self_inv_idx_d = pending_self_inv_idx_q;
+    inval_ready_o          = 1'b0;
     if (inval_valid_i) begin
       inval_ready_o         = 1'b1;
       dcache_rtrn_type_d    = wt_cache_pkg::DCACHE_INV_REQ;
       dcache_rtrn_vld_d     = 1'b1;
       dcache_rtrn_inv_d.all = 1'b1;
       dcache_rtrn_inv_d.idx = inval_addr_i[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
-      //////////////////////////////////////
-      // dcache needs some special treatment
-      // for arbitration and decoding of atomics
-      //////////////////////////////////////
-      // this is safe, there is no other read tx in flight than this atomic.
-      // note that this self invalidation is handled in this way due to the
-      // write-through cache architecture, which is aligned with the openpiton
-      // cache subsystem.
-    end else if (CVA6Cfg.RVA && invalidate) begin
-      dcache_rtrn_type_d = wt_cache_pkg::DCACHE_INV_REQ;
-      dcache_rtrn_vld_d = 1'b1;
-
+      if (CVA6Cfg.RVA && invalidate) begin
+        pending_self_inv_d     = 1'b1;
+        pending_self_inv_idx_d = dcache_data.paddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
+      end
+    end else if (CVA6Cfg.RVA && (invalidate || pending_self_inv_q)) begin
+      dcache_rtrn_type_d    = wt_cache_pkg::DCACHE_INV_REQ;
+      dcache_rtrn_vld_d     = 1'b1;
       dcache_rtrn_inv_d.all = 1'b1;
-      dcache_rtrn_inv_d.idx = dcache_data.paddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
+      dcache_rtrn_inv_d.idx = invalidate ? dcache_data.paddr[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] : pending_self_inv_idx_q;
+      pending_self_inv_d    = 1'b0;
       //////////////////////////////////////
       // read responses
       // note that in case of atomics, the dcache sequentializes requests and
@@ -707,7 +695,13 @@
       dcache_rtrn_inv_q      <= '0;
       amo_off_q              <= '0;
       amo_gen_r_q            <= 1'b0;
+      rr_q                   <= 1'b0;
+      pending_self_inv_q     <= 1'b0;
+      pending_self_inv_idx_q <= '0;
     end else begin
+      if (|arb_ack) rr_q <= ~arb_idx;
+      pending_self_inv_q     <= pending_self_inv_d;
+      pending_self_inv_idx_q <= pending_self_inv_idx_d;
       icache_first_q         <= icache_first_d;
       dcache_first_q         <= dcache_first_d;
       icache_rd_shift_q      <= icache_rd_shift_d;

--- a/environment/public/code/axi_shim.sv (Buggy Starter)
+++ b/solution/gold/code/axi_shim.sv (Golden Reference)
@@ -1,310 +1,247 @@
-/* Copyright 2018 ETH Zurich and University of Bologna.
- * Copyright and related rights are licensed under the Solderpad Hardware
- * License, Version 0.51 (the “License”); you may not use this file except in
- * compliance with the License.  You may obtain a copy of the License at
- * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
- * or agreed to in writing, software, hardware and materials distributed under
- * this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
- * CONDITIONS OF ANY KIND, either express or implied. See the License for the
- * specific language governing permissions and limitations under the License.
- *
- * File:  axi_shim.sv
- * Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>
- *         Florian Zaruba <zarubaf@iis.ee.ethz.ch>
- * Date:   1.8.2018
- *
- * Description: Manages communication with the AXI Bus. Note that this unit does not
- *              buffer requests and register the signals.
- *
- */
-
+// Copyright 2018 ETH Zurich and University of Bologna.
+// Licensed under the Solderpad Hardware License, Version 0.51.
 
 module axi_shim #(
     parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
-    parameter int unsigned AxiNumWords = 4, // data width in dwords, this is also the maximum burst length, must be >=2
+    parameter int unsigned AxiNumWords = 4,
     parameter type axi_req_t = logic,
-    parameter type axi_rsp_t = logic
+    parameter type axi_rsp_t = logic,
+    parameter int unsigned AxiBlenWidth = AxiNumWords > 1 ? $clog2(AxiNumWords) : 1
 ) (
-    input logic clk_i,  // Clock
-    input logic rst_ni,  // Asynchronous reset active low
-    // read channel
-    // request
-    input logic rd_req_i,
-    output logic rd_gnt_o,
-    input logic [CVA6Cfg.AxiAddrWidth-1:0] rd_addr_i,
-    input logic [$clog2(AxiNumWords)-1:0] rd_blen_i,  // axi convention: LEN-1
-    input logic [2:0] rd_size_i,
-    input  logic [CVA6Cfg.AxiIdWidth-1:0]   rd_id_i,   // use same ID for reads, or make sure you only have one outstanding read tx
-    input logic rd_lock_i,
-    // read response (we have to unconditionally sink the response)
-    input logic rd_rdy_i,
-    output logic rd_last_o,
-    output logic rd_valid_o,
-    output logic [CVA6Cfg.AxiDataWidth-1:0] rd_data_o,
-    output logic [CVA6Cfg.AxiUserWidth-1:0] rd_user_o,
-    output logic [CVA6Cfg.AxiIdWidth-1:0] rd_id_o,
-    output logic rd_exokay_o,  // indicates whether exclusive tx succeeded
-    // write channel
-    input logic wr_req_i,
-    output logic wr_gnt_o,
-    input logic [CVA6Cfg.AxiAddrWidth-1:0] wr_addr_i,
-    input logic [AxiNumWords-1:0][CVA6Cfg.AxiDataWidth-1:0] wr_data_i,
-    input logic [AxiNumWords-1:0][CVA6Cfg.AxiUserWidth-1:0] wr_user_i,
-    input logic [AxiNumWords-1:0][(CVA6Cfg.AxiDataWidth/8)-1:0] wr_be_i,
-    input logic [$clog2(AxiNumWords)-1:0] wr_blen_i,  // axi convention: LEN-1
-    input logic [2:0] wr_size_i,
-    input logic [CVA6Cfg.AxiIdWidth-1:0] wr_id_i,
-    input logic wr_lock_i,
-    input logic [5:0] wr_atop_i,
-    // write response
-    input logic wr_rdy_i,
-    output logic wr_valid_o,
-    output logic [CVA6Cfg.AxiIdWidth-1:0] wr_id_o,
-    output logic wr_exokay_o,  // indicates whether exclusive tx succeeded
-    // AXI port
-    output axi_req_t axi_req_o,
-    input axi_rsp_t axi_resp_i
+    input  logic                                                  clk_i,
+    input  logic                                                  rst_ni,
+    input  logic                                                  rd_req_i,
+    output logic                                                  rd_gnt_o,
+    input  logic [CVA6Cfg.AxiAddrWidth-1:0]                       rd_addr_i,
+    input  logic [AxiBlenWidth-1:0]                               rd_blen_i,
+    input  logic [2:0]                                            rd_size_i,
+    input  logic [CVA6Cfg.AxiIdWidth-1:0]                         rd_id_i,
+    input  logic                                                  rd_lock_i,
+    input  logic                                                  rd_rdy_i,
+    output logic                                                  rd_last_o,
+    output logic                                                  rd_valid_o,
+    output logic [CVA6Cfg.AxiDataWidth-1:0]                       rd_data_o,
+    output logic [CVA6Cfg.AxiUserWidth-1:0]                       rd_user_o,
+    output logic [CVA6Cfg.AxiIdWidth-1:0]                         rd_id_o,
+    output logic                                                  rd_exokay_o,
+    input  logic                                                  wr_req_i,
+    output logic                                                  wr_gnt_o,
+    input  logic [CVA6Cfg.AxiAddrWidth-1:0]                       wr_addr_i,
+    input  logic [AxiNumWords-1:0][CVA6Cfg.AxiDataWidth-1:0]      wr_data_i,
+    input  logic [AxiNumWords-1:0][CVA6Cfg.AxiUserWidth-1:0]      wr_user_i,
+    input  logic [AxiNumWords-1:0][(CVA6Cfg.AxiDataWidth/8)-1:0]  wr_be_i,
+    input  logic [AxiBlenWidth-1:0]                               wr_blen_i,
+    input  logic [2:0]                                            wr_size_i,
+    input  logic [CVA6Cfg.AxiIdWidth-1:0]                         wr_id_i,
+    input  logic                                                  wr_lock_i,
+    input  logic [5:0]                                            wr_atop_i,
+    input  logic                                                  wr_rdy_i,
+    output logic                                                  wr_valid_o,
+    output logic [CVA6Cfg.AxiIdWidth-1:0]                         wr_id_o,
+    output logic                                                  wr_exokay_o,
+    output axi_req_t                                              axi_req_o,
+    input  axi_rsp_t                                              axi_resp_i
 );
-  localparam AddrIndex = ($clog2(AxiNumWords) > 0) ? $clog2(AxiNumWords) : 1;
-
-  ///////////////////////////////////////////////////////
-  // write channel
-  ///////////////////////////////////////////////////////
-
-  enum logic [3:0] {
+
+  typedef enum logic [1:0] {
     IDLE,
-    WAIT_AW_READY,
-    WAIT_LAST_W_READY,
-    WAIT_LAST_W_READY_AW_READY,
-    WAIT_AW_READY_BURST
-  }
-      wr_state_q, wr_state_d;
-
-  // AXI tx counter
-  logic [AddrIndex-1:0] wr_cnt_d, wr_cnt_q;
-  logic wr_single_req, wr_cnt_done, wr_cnt_clr, wr_cnt_en;
-
-  assign wr_single_req = (wr_blen_i == 0);
-
-  // address
-  assign axi_req_o.aw.burst = axi_pkg::BURST_INCR;  // Use BURST_INCR for AXI regular transaction
-  assign axi_req_o.aw.addr = wr_addr_i[CVA6Cfg.AxiAddrWidth-1:0];
-  assign axi_req_o.aw.size = wr_size_i;
-  assign axi_req_o.aw.len = wr_blen_i;
-  assign axi_req_o.aw.id = wr_id_i;
-  assign axi_req_o.aw.prot = 3'b0;
-  assign axi_req_o.aw.region = 4'b0;
-  assign axi_req_o.aw.lock = wr_lock_i;
-  assign axi_req_o.aw.cache = axi_pkg::CACHE_MODIFIABLE;
-  assign axi_req_o.aw.qos = 4'b0;
-  assign axi_req_o.aw.atop = wr_atop_i;
-  assign axi_req_o.aw.user = '0;
-
-  // data
-  assign axi_req_o.w.data = wr_data_i[wr_cnt_q];
-  assign axi_req_o.w.user = wr_user_i[wr_cnt_q];
-  assign axi_req_o.w.strb = wr_be_i[wr_cnt_q];
-  assign axi_req_o.w.last = wr_cnt_done;
-
-  // write response
-  assign wr_exokay_o = (axi_resp_i.b.resp == axi_pkg::RESP_EXOKAY);
+    WRITE,
+    WRITE_WAIT,
+    AW_WAIT
+  } wr_state_e;
+
+  typedef enum logic {
+    READ,
+    READ_HOLD
+  } rd_state_e;
+
+  wr_state_e wr_State_d, wr_State_q;
+  rd_state_e rd_State_d, rd_State_q;
+
+  logic [AxiBlenWidth-1:0] wr_cnt_d, wr_cnt_q;
+  logic [AxiBlenWidth-1:0] wr_ptr;
+  logic [$bits(axi_req_o.aw)-1:0] wr_aw_d, wr_aw_q;
+  logic [$bits(axi_req_o.w)-1:0]  wr_w_d, wr_w_q;
+  logic [$bits(axi_req_o.ar)-1:0] rd_ar_d, rd_ar_q;
+
+  assign wr_cnt_d = (wr_State_q == IDLE) ? wr_blen_i :
+                    (axi_req_o.w_valid & axi_resp_i.w_ready) ? (wr_cnt_q - 1'b1) : wr_cnt_q;
+  assign wr_ptr   = wr_blen_i - wr_cnt_q;
+
   assign axi_req_o.b_ready = wr_rdy_i;
-  assign wr_valid_o = axi_resp_i.b_valid;
-  assign wr_id_o = axi_resp_i.b.id;
-
-  // tx counter
-  assign wr_cnt_done = (wr_cnt_q == wr_blen_i);
-  assign wr_cnt_d            = (wr_cnt_clr) ? '0 : (wr_cnt_en && CVA6Cfg.AxiBurstWriteEn) ? wr_cnt_q + 1 : wr_cnt_q;
-
-  always_comb begin : p_axi_write_fsm
-    // default
-    wr_state_d         = wr_state_q;
-
+  assign wr_valid_o        = axi_resp_i.b_valid;
+  assign wr_id_o           = axi_resp_i.b.id;
+  assign wr_exokay_o       = (axi_resp_i.b.resp == axi_pkg::RESP_EXOKAY);
+
+  assign axi_req_o.r_ready = rd_rdy_i;
+  assign rd_valid_o        = axi_resp_i.r_valid;
+  assign rd_last_o         = axi_resp_i.r.last;
+  assign rd_data_o         = axi_resp_i.r.data;
+  assign rd_user_o         = axi_resp_i.r.user;
+  assign rd_id_o           = axi_resp_i.r.id;
+  assign rd_exokay_o       = (axi_resp_i.r.resp == axi_pkg::RESP_EXOKAY);
+
+  always_comb begin : p_write_fsm
+    wr_State_d         = wr_State_q;
+    wr_aw_d            = wr_aw_q;
+    wr_w_d             = wr_w_q;
+    wr_gnt_o           = 1'b0;
     axi_req_o.aw_valid = 1'b0;
     axi_req_o.w_valid  = 1'b0;
-    wr_gnt_o           = 1'b0;
-
-    wr_cnt_en          = 1'b0;
-    wr_cnt_clr         = 1'b0;
-
-    case (wr_state_q)
-      ///////////////////////////////////
+
+    axi_req_o.aw       = '0;
+    axi_req_o.aw.id    = wr_id_i;
+    axi_req_o.aw.addr  = wr_addr_i;
+    axi_req_o.aw.len   = 8'(wr_blen_i);
+    axi_req_o.aw.size  = wr_size_i;
+    axi_req_o.aw.burst = axi_pkg::BURST_INCR;
+    axi_req_o.aw.lock  = wr_lock_i;
+    axi_req_o.aw.atop  = wr_atop_i;
+
+    axi_req_o.w        = '0;
+    axi_req_o.w.data   = wr_data_i[0];
+    axi_req_o.w.user   = wr_user_i[0];
+    axi_req_o.w.strb   = wr_be_i[0];
+    axi_req_o.w.last   = (wr_cnt_d == '0);
+
+    unique case (wr_State_q)
       IDLE: begin
-        // we have an incoming request
+        wr_aw_d            = axi_req_o.aw;
+        wr_w_d             = axi_req_o.w;
+        axi_req_o.aw_valid = wr_req_i;
+        axi_req_o.w_valid  = wr_req_i;
         if (wr_req_i) begin
-          // is this a read or write?
-          axi_req_o.aw_valid = 1'b1;
-          axi_req_o.w_valid  = 1'b1;
-
-          if (CVA6Cfg.AxiBurstWriteEn && !wr_single_req) begin
-            wr_cnt_en = axi_resp_i.w_ready;
-
-            case ({
-              axi_resp_i.aw_ready, axi_resp_i.w_ready
-            })
-              2'b11:   wr_state_d = WAIT_LAST_W_READY;
-              2'b01:   wr_state_d = WAIT_LAST_W_READY_AW_READY;
-              2'b10:   wr_state_d = WAIT_LAST_W_READY;
-              default: ;
-            endcase
-          end else if (wr_single_req) begin  // its a single write
-            wr_cnt_clr = 1'b1;
-            // single req can be granted here
-            wr_gnt_o   = axi_resp_i.aw_ready & axi_resp_i.w_ready;
-            case ({
-              axi_resp_i.aw_ready, axi_resp_i.w_ready
-            })
-              2'b01:   wr_state_d = WAIT_AW_READY;
-              2'b10:   wr_state_d = WAIT_LAST_W_READY;
-              default: wr_state_d = IDLE;
-            endcase
-            // its a request for the whole cache line
-          end
-        end
-      end
-      ///////////////////////////////////
-      // ~> from single write
-      WAIT_AW_READY: begin
+          unique case ({axi_resp_i.aw_ready, axi_resp_i.w_ready})
+            2'b01: begin
+              if (wr_blen_i == '0) begin
+                wr_State_d = AW_WAIT;
+              end else begin
+                wr_State_d = WRITE;
+              end
+            end
+            2'b10: begin
+              wr_State_d = WRITE_WAIT;
+            end
+            2'b11: begin
+              if (wr_blen_i == '0) begin
+                wr_gnt_o = 1'b1;
+              end else begin
+                wr_State_d = WRITE_WAIT;
+              end
+            end
+            default: ;
+          endcase
+        end
+      end
+
+      WRITE: begin
+        axi_req_o.aw       = wr_aw_q;
         axi_req_o.aw_valid = 1'b1;
-
+        axi_req_o.w.data   = wr_data_i[wr_ptr];
+        axi_req_o.w.user   = wr_user_i[wr_ptr];
+        axi_req_o.w.strb   = wr_be_i[wr_ptr];
+        axi_req_o.w.last   = (wr_cnt_q == '0);
+        axi_req_o.w_valid  = 1'b1;
+        unique case ({axi_resp_i.aw_ready, axi_resp_i.w_ready})
+          2'b01: begin
+            if (wr_cnt_q == '0) begin
+              wr_State_d = AW_WAIT;
+            end
+          end
+          2'b10: begin
+            wr_State_d = WRITE_WAIT;
+          end
+          2'b11: begin
+            if (wr_cnt_q == '0) begin
+              wr_gnt_o   = 1'b1;
+              wr_State_d = IDLE;
+            end else begin
+              wr_State_d = WRITE_WAIT;
+            end
+          end
+          default: ;
+        endcase
+      end
+
+      WRITE_WAIT: begin
+        axi_req_o.aw       = wr_aw_q;
+        axi_req_o.w.data   = wr_data_i[wr_ptr];
+        axi_req_o.w.user   = wr_user_i[wr_ptr];
+        axi_req_o.w.strb   = wr_be_i[wr_ptr];
+        axi_req_o.w.last   = (wr_cnt_q == '0);
+        axi_req_o.w_valid  = 1'b1;
+        if (axi_resp_i.w_ready) begin
+          if (wr_cnt_q == '0) begin
+            wr_gnt_o   = 1'b1;
+            wr_State_d = IDLE;
+          end
+        end
+      end
+
+      AW_WAIT: begin
+        axi_req_o.aw       = wr_aw_q;
+        axi_req_o.aw_valid = 1'b1;
         if (axi_resp_i.aw_ready) begin
-          wr_state_d = IDLE;
           wr_gnt_o   = 1'b1;
-        end
-      end
-      ///////////////////////////////////
-      // ~> from write, there is an outstanding write
-      WAIT_LAST_W_READY: begin
-        axi_req_o.w_valid = 1'b1;
-
-        if (CVA6Cfg.AxiBurstWriteEn && axi_resp_i.w_ready && !wr_cnt_done) begin
-          wr_cnt_en = 1'b1;
-        end else if (wr_cnt_done) begin  // this is the last write
-          if (axi_resp_i.w_ready) begin
-            wr_state_d = IDLE;
-            wr_cnt_clr = 1'b1;
-            wr_gnt_o   = 1'b1;
-          end
-        end
-      end
-      ///////////////////////////////////
-      default: begin
-        ///////////////////////////////////
-        // ~> we need to wait for an aw_ready and there is at least one outstanding write
-        if (CVA6Cfg.AxiBurstWriteEn) begin
-          if (wr_state_q == WAIT_LAST_W_READY_AW_READY) begin
-            axi_req_o.w_valid  = 1'b1;
-            axi_req_o.aw_valid = 1'b1;
-            // we got an aw_ready
-            case ({
-              axi_resp_i.aw_ready, axi_resp_i.w_ready
-            })
-              // we got an aw ready
-              2'b01: begin
-                // are there any outstanding transactions?
-                if (wr_cnt_done) begin
-                  wr_state_d = WAIT_AW_READY_BURST;
-                  wr_cnt_clr = 1'b1;
-                end else begin
-                  // yes, so reduce the count and stay here
-                  wr_cnt_en = 1'b1;
-                end
-              end
-              2'b10:   wr_state_d = WAIT_LAST_W_READY;
-              2'b11: begin
-                // we are finished
-                if (wr_cnt_done) begin
-                  wr_state_d = IDLE;
-                  wr_gnt_o   = 1'b1;
-                  wr_cnt_clr = 1'b1;
-                  // there are outstanding transactions
-                end else begin
-                  wr_state_d = WAIT_LAST_W_READY;
-                  wr_cnt_en  = 1'b1;
-                end
-              end
-              default: ;
-            endcase
-          end  ///////////////////////////////////
-               // ~> all data has already been sent, we are only waiting for the aw_ready
-          else if (wr_state_q == WAIT_AW_READY_BURST) begin
-            axi_req_o.aw_valid = 1'b1;
-
-            if (axi_resp_i.aw_ready) begin
-              wr_state_d = IDLE;
-              wr_gnt_o   = 1'b1;
-            end
-          end
-        end else begin
-          wr_state_d = IDLE;
-        end
-      end
+          wr_State_d = IDLE;
+        end
+      end
+
+      default: wr_State_d = IDLE;
     endcase
   end
 
-
-  ///////////////////////////////////////////////////////
-  // read channel
-  ///////////////////////////////////////////////////////
-
-  // address
-  // in case of a wrapping transfer we can simply begin at the address, if we want to request a cache-line
-  // with an incremental transfer we need to output the corresponding base address of the cache line
-  assign axi_req_o.ar.burst  = axi_pkg::BURST_INCR;  // Use BURST_INCR for AXI regular transaction
-  assign axi_req_o.ar.addr   = rd_addr_i[CVA6Cfg.AxiAddrWidth-1:0];
-  assign axi_req_o.ar.size   = rd_size_i;
-  assign axi_req_o.ar.len    = rd_blen_i;
-  assign axi_req_o.ar.id     = rd_id_i;
-  assign axi_req_o.ar.prot   = 3'b0;
-  assign axi_req_o.ar.region = 4'b0;
-  assign axi_req_o.ar.lock   = rd_lock_i;
-  assign axi_req_o.ar.cache  = axi_pkg::CACHE_MODIFIABLE;
-  assign axi_req_o.ar.qos    = 4'b0;
-  assign axi_req_o.ar.user   = '0;
-
-  // make the read request
-  assign axi_req_o.ar_valid  = rd_req_i;
-  assign rd_gnt_o            = rd_req_i & axi_resp_i.ar_ready;
-
-  // return path
-  assign axi_req_o.r_ready   = rd_rdy_i;
-  assign rd_data_o           = axi_resp_i.r.data;
-  if (CVA6Cfg.AXI_USER_EN) begin
-    assign rd_user_o = axi_resp_i.r.user;
-  end else begin
-    assign rd_user_o = '0;
+  always_comb begin : p_read_fsm
+    rd_State_d        = rd_State_q;
+    rd_ar_d           = rd_ar_q;
+    rd_gnt_o          = 1'b0;
+    axi_req_o.ar      = '0;
+    axi_req_o.ar.id   = rd_id_i;
+    axi_req_o.ar.addr = rd_addr_i;
+    axi_req_o.ar.len  = 8'(rd_blen_i);
+    axi_req_o.ar.size = rd_size_i;
+    axi_req_o.ar.burst= axi_pkg::BURST_INCR;
+    axi_req_o.ar.lock = rd_lock_i;
+
+    unique case (rd_State_q)
+      READ: begin
+        rd_ar_d            = axi_req_o.ar;
+        axi_req_o.ar_valid = rd_req_i;
+        if (rd_req_i) begin
+          if (axi_resp_i.ar_ready) begin
+            rd_gnt_o = 1'b1;
+          end else begin
+            rd_State_d = READ_HOLD;
+          end
+        end
+      end
+      READ_HOLD: begin
+        axi_req_o.ar       = rd_ar_q;
+        axi_req_o.ar_valid = 1'b1;
+        if (axi_resp_i.ar_ready) begin
+          rd_gnt_o   = 1'b1;
+          rd_State_d = READ;
+        end
+      end
+      default: rd_State_d = READ;
+    endcase
   end
-  assign rd_last_o   = axi_resp_i.r.last;
-  assign rd_valid_o  = axi_resp_i.r_valid;
-  assign rd_id_o     = axi_resp_i.r.id;
-  assign rd_exokay_o = (axi_resp_i.r.resp == axi_pkg::RESP_EXOKAY);
-
-
-  // ----------------
-  // Registers
-  // ----------------
-  always_ff @(posedge clk_i or negedge rst_ni) begin
-    if (~rst_ni) begin
-      // start in flushing state and initialize the memory
-      wr_state_q <= IDLE;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
+    if (!rst_ni) begin
+      wr_State_q <= IDLE;
+      rd_State_q <= READ;
       wr_cnt_q   <= '0;
+      wr_aw_q    <= '0;
+      wr_w_q     <= '0;
+      rd_ar_q    <= '0;
     end else begin
-      wr_state_q <= wr_state_d;
+      wr_State_q <= wr_State_d;
+      rd_State_q <= rd_State_d;
       wr_cnt_q   <= wr_cnt_d;
+      wr_aw_q <= wr_aw_d;
+      wr_w_q  <= wr_w_d;
+      rd_ar_q <= rd_ar_d;
     end
   end
-
-  // ----------------
-  // Assertions
-  // ----------------
-
-  //pragma translate_off
-  initial begin
-    assert (AxiNumWords >= 1)
-    else $fatal(1, "[axi adapter] AxiNumWords must be >= 1");
-    assert (CVA6Cfg.AxiIdWidth >= 2)
-    else $fatal(1, "[axi adapter] AXI id width must be at least 2 bit wide");
-  end
-  //pragma translate_on
-
-endmodule  // axi_adapter2
+endmodule

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_shim.sv`](environment/public/code/axi_shim.sv) **(Editable)**
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a60ax_config_pkg.sv`](environment/public/code/cv64a60ax_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cva6_fifo_v3.sv`](environment/public/code/cva6_fifo_v3.sv) **(Editable)**
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/wt_axi_adapter.sv`](environment/public/code/wt_axi_adapter.sv) **(Editable)**
- [`environment/public/code/wt_cache_pkg.sv`](environment/public/code/wt_cache_pkg.sv) *(Read-Only Context)*
- [`environment/public/flow/wt_axi_subsys_top.sv`](environment/public/flow/wt_axi_subsys_top.sv) *(Read-Only Context)*
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

