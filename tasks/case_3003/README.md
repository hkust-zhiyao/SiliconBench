# `case_3003`: CV32E40P Stream-to-OBI Bridge Flush Drain, Registered Address-Phase Stability, and Transparent Channel Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_3003` |
| **Source Silicon Repository** | `openhwfoundation/cv32e40p` (`repo_03`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `sdc_sta` (Multi-Mode Timing Constraints (SDC), Path Exceptions, OpenSTA & Closure) |
| **Multi-Domain Tags** | `protocol_control`, `reset_rdc`, `rtl_integration`, `sdc_sta` |
| **Editable Files (`allowed_edits`)** | [`code/stream_to_mem.sv`](environment/public/code/stream_to_mem.sv), [`code/cv32e40p_obi_interface.sv`](environment/public/code/cv32e40p_obi_interface.sv), [`constraints.json`](environment/public/constraints.json) (3 files, 200 LOC) |
| **Public Subsystem Context** | 8 RTL files (883 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library (Shared Base Image)** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Uses unified Nangate45 typical Liberty and LEF from base image. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# CV32E40P Stream-to-OBI Bridge Flush Drain, Registered Address-Phase Stability, and Transparent Channel Timing Budgets

In `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, and `constraints.json` (integrated in `code/top.sv` with `code/stream_fifo.sv`, `code/fifo_v3.sv`, and `code/spill_register.sv`), synchronous flush draining, non-granted OBI address-phase stability, error forwarding, and transparent status channel timing budgets fail verification. In `stream_to_mem`, asserting `flush_i` must immediately deassert `req_ready_o`, `mem_req_valid_o`, and `resp_valid_o` for that cycle, flush any buffered responses in `i_resp_buf`, and discard any responses returning from already-accepted in-flight memory requests (`mem_resp_valid_i` on or after the `flush_i` edge) so stale responses never reach `resp_valid_o`/`resp_o` while reclaiming their outstanding buffer credits (`cnt_q`) as they drain. In `cv32e40p_obi_interface` (`TRANS_STABLE = 0`), when an OBI request is not immediately granted (`obi_req_o && !obi_gnt_i`), all address-phase outputs (`obi_addr_o`, `obi_we_o`, `obi_be_o`, `obi_wdata_o`, `obi_atop_o`) must remain stable in the `REGISTERED` state until `obi_gnt_i` asserts, and `obi_err_i` must be forwarded on `resp_err_o`.

In `code/top.sv`, the bridge operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `4.0 ns` external input delay on all non-clock inputs and a `3.5 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`pmp_in` to `pmp_out` and `dbg_in` to `dbg_out`) even with zero internal delay. Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.25 ns` for `pmp_in` to `pmp_out` and `2.25 ns` for `dbg_in` to `dbg_out`, while preserving the existing timing requirements for all registered stream and OBI ports (`flush_i`, `req_addr`, `req_we`, `req_be`, `req_wdata`, `req_atop`, `req_valid`, `resp_ready`, `obi_gnt`, `obi_rdata`, `obi_rvalid`, `obi_err`, `req_ready`, `resp_rdata`, `resp_err`, `resp_valid`, `obi_req`, `obi_addr`, `obi_we`, `obi_be`, `obi_wdata`, `obi_atop`). Edit only `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/stream_to_mem.sv`
- `code/cv32e40p_obi_interface.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/stream_fifo.sv`, `code/fifo_v3.sv`, `code/spill_register.sv`, `code/include/common_cells/registers.svh`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode/include \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/fifo_v3.sv code/stream_fifo.sv code/spill_register.sv \
  code/stream_to_mem.sv code/cv32e40p_obi_interface.sv \
  code/top.sv /tmp/<your_tb.sv>
/tmp/obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `flush_i`, `req_addr`, `req_we`, `req_be`, `req_wdata`, `req_atop`, `req_valid`, `resp_ready`, `obi_gnt`, `obi_rdata`, `obi_rvalid`, `obi_err`, `pmp_in`, and `dbg_in` (or bit-indexed `pmp_in[0..7]`, `dbg_in[0..7]`, etc.).
- Output groups are `req_ready`, `resp_rdata`, `resp_err`, `resp_valid`, `obi_req`, `obi_addr`, `obi_we`, `obi_be`, `obi_wdata`, `obi_atop`, `pmp_out`, and `dbg_out` (or bit-indexed `pmp_out[0..7]`, `dbg_out[0..7]`, etc.).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.0 ns` input delay on all non-clock inputs (`set_input_delay 4.0 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/stream_to_mem.sv (Buggy Starter)
+++ b/solution/gold/code/stream_to_mem.sv (Golden Reference)
@@ -26,24 +26,41 @@
   typedef logic [$clog2(BufDepth+1):0] cnt_t;
 
   cnt_t cnt_d, cnt_q;
+  cnt_t inflight_d, inflight_q;
+  cnt_t drop_cnt_d, drop_cnt_q;
   logic buf_ready,
-        req_ready;
+        buf_valid,
+        req_ready,
+        fifo_push_valid,
+        fifo_pop_ready;
 
   if (BufDepth > 0) begin : gen_buf
+    logic req_acc, resp_acc, stale_ret;
+    assign req_acc   = req_valid_i && req_ready_o;
+    assign resp_acc  = resp_valid_o && resp_ready_i;
+    assign stale_ret = mem_resp_valid_i && (drop_cnt_q > '0);
+
     always_comb begin
-      cnt_d = cnt_q;
-      if (req_valid_i && req_ready_o) begin
-        cnt_d++;
-      end
-      if (resp_valid_o && resp_ready_i) begin
-        cnt_d--;
+      if (flush_i) begin
+        cnt_t rem_inflight;
+        rem_inflight = (inflight_q > '0 && mem_resp_valid_i) ? (inflight_q - 1'b1) : inflight_q;
+        cnt_d        = rem_inflight;
+        inflight_d   = rem_inflight;
+        drop_cnt_d   = rem_inflight;
+      end else begin
+        cnt_d      = cnt_q + cnt_t'(req_acc) - cnt_t'(resp_acc) - cnt_t'(stale_ret);
+        inflight_d = inflight_q + cnt_t'(req_acc) - cnt_t'(mem_resp_valid_i);
+        drop_cnt_d = drop_cnt_q - cnt_t'(stale_ret);
       end
     end
 
-    assign req_ready = (cnt_q < BufDepth) | (resp_valid_o & resp_ready_i);
+    assign req_ready       = !flush_i && ((cnt_q < BufDepth) | (resp_valid_o & resp_ready_i));
+    assign req_ready_o     = mem_req_ready_i & req_ready;
+    assign mem_req_valid_o = req_valid_i & req_ready;
 
-    assign req_ready_o = mem_req_ready_i & req_ready;
-    assign mem_req_valid_o = req_valid_i & req_ready;
+    assign fifo_push_valid = mem_resp_valid_i & ~flush_i & (drop_cnt_q == '0);
+    assign resp_valid_o    = buf_valid & ~flush_i;
+    assign fifo_pop_ready  = resp_ready_i & ~flush_i;
 
     stream_fifo #(
       .FALL_THROUGH ( 1'b1       ),
@@ -52,24 +69,26 @@
     ) i_resp_buf (
       .clk_i,
       .rst_ni,
-      .flush_i    ( 1'b0             ),
-      .testmode_i ( 1'b0             ),
-      .data_i     ( mem_resp_i       ),
-      .valid_i    ( mem_resp_valid_i ),
-      .ready_o    ( buf_ready        ),
-      .data_o     ( resp_o           ),
-      .valid_o    ( resp_valid_o     ),
-      .ready_i    ( resp_ready_i     ),
-      .usage_o    ( /* unused */     )
+      .flush_i    ( flush_i         ),
+      .testmode_i ( 1'b0            ),
+      .data_i     ( mem_resp_i      ),
+      .valid_i    ( fifo_push_valid ),
+      .ready_o    ( buf_ready       ),
+      .data_o     ( resp_o          ),
+      .valid_o    ( buf_valid       ),
+      .ready_i    ( fifo_pop_ready  ),
+      .usage_o    ( /* unused */    )
     );
 
-    `FFARN(cnt_q, cnt_d, '0, clk_i, rst_ni)
+    `FFARN(cnt_q,      cnt_d,      '0, clk_i, rst_ni)
+    `FFARN(inflight_q, inflight_d, '0, clk_i, rst_ni)
+    `FFARN(drop_cnt_q, drop_cnt_d, '0, clk_i, rst_ni)
 
   end else begin : gen_no_buf
-    assign mem_req_valid_o = req_valid_i;
-    assign resp_valid_o    = mem_req_valid_o & mem_req_ready_i & mem_resp_valid_i;
+    assign mem_req_valid_o = req_valid_i & ~flush_i;
+    assign resp_valid_o    = mem_req_valid_o & mem_req_ready_i & mem_resp_valid_i & ~flush_i;
     assign req_ready_o     = resp_ready_i    & resp_valid_o;
-    assign resp_o = mem_resp_i;
+    assign resp_o          = mem_resp_i;
   end
 
   assign mem_req_o = req_i;

--- a/environment/public/code/cv32e40p_obi_interface.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e40p_obi_interface.sv (Golden Reference)
@@ -7,7 +7,6 @@
     input logic clk,
     input logic rst_n,
 
-    // Transaction request interface
     input  logic        trans_valid_i,
     output logic        trans_ready_o,
     input  logic [31:0] trans_addr_i,
@@ -16,12 +15,10 @@
     input  logic [31:0] trans_wdata_i,
     input  logic [ 5:0] trans_atop_i,
 
-    // Transaction response interface
     output logic        resp_valid_o,
     output logic [31:0] resp_rdata_o,
     output logic        resp_err_o,
 
-    // OBI interface
     output logic        obi_req_o,
     input  logic        obi_gnt_i,
     output logic [31:0] obi_addr_o,
@@ -41,7 +38,7 @@
 
   assign resp_valid_o = obi_rvalid_i;
   assign resp_rdata_o = obi_rdata_i;
-  assign resp_err_o   = 1'b0;
+  assign resp_err_o   = obi_err_i;
 
   generate
     if (TRANS_STABLE) begin : gen_trans_stable
@@ -88,7 +85,7 @@
         end else begin
           obi_req_o   = 1'b1;
           obi_addr_o  = obi_addr_q;
-          obi_we_o    = trans_we_i;
+          obi_we_o    = obi_we_q;
           obi_be_o    = obi_be_q;
           obi_wdata_o = obi_wdata_q;
           obi_atop_o  = obi_atop_q;
@@ -108,7 +105,9 @@
           if ((state_q == TRANSPARENT) && (next_state == REGISTERED)) begin
             obi_addr_q  <= obi_addr_o;
             obi_we_q    <= obi_we_o;
+            obi_be_q    <= obi_be_o;
             obi_wdata_q <= obi_wdata_o;
+            obi_atop_q  <= obi_atop_o;
           end
         end
       end

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,14 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": ["pmp_in"],
+      "to": ["pmp_out"],
+      "ns": 8.75
+    },
+    {
+      "from": ["dbg_in"],
+      "to": ["dbg_out"],
+      "ns": 9.75
+    }
+  ]
 }

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/cv32e40p_obi_interface.sv`](environment/public/code/cv32e40p_obi_interface.sv) **(Editable)**
- [`environment/public/code/fifo_v3.sv`](environment/public/code/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/stream_fifo.sv`](environment/public/code/stream_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/stream_to_mem.sv`](environment/public/code/stream_to_mem.sv) **(Editable)**
- [`environment/public/code/top.sv`](environment/public/code/top.sv) *(Read-Only Context)*
- [`environment/public/constraints.json`](environment/public/constraints.json) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

