# `case_2002`: Ibex TRVK Capability Revocation Bridge Backpressure, Heap-Base Underflow Guard, Flush Recovery, and Transparent Channel Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_2002` |
| **Source Silicon Repository** | `lowRISC/ibex` (`repo_02`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `protocol_control`, `reset_rdc`, `rtl_integration`, `rtl_semantics`, `sdc_sta`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/ibex_trvk.sv`](environment/public/code/ibex_trvk.sv), [`code/stream_fork.sv`](environment/public/code/stream_fork.sv), [`constraints.json`](environment/public/constraints.json) (3 files, 430 LOC) |
| **Public Subsystem Context** | 22 RTL files (6329 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library (Shared Base Image)** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Uses unified Nangate45 typical Liberty and LEF from base image. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# Ibex TRVK Capability Revocation Bridge Backpressure, Heap-Base Underflow Guard, Flush Recovery, and Transparent Channel Timing Budgets

In `code/ibex_trvk.sv`, `code/stream_fork.sv`, and `constraints.json` (integrated in `code/ibex_trvk_bridge_top.sv`), the CHERIoT temporal capability revocation bridge (`ibex_trvk`) intercepts 32-bit OBI memory transactions, tracks 64-bit capability alignment (`upstream_addr_i[2]`), latches the lower 32-bit capability pointer word (`upstream_addr_i[2] == 1'b0`), reconstructs the 33-bit capability base address on the upper 32-bit metadata word (`upstream_addr_i[2] == 1'b1`), and queries the revocation bitmap memory (`revbm_*`) before returning `upstream_tag_o`. Currently, functional verification, synthesis latch checks, and OpenSTA timing budgets fail:

1. **Synchronous flush recovery in `code/stream_fork.sv`**:
   - Add synchronous clear input `input logic clr_i` to `stream_fork` (wired to `flush_i` in `ibex_trvk.sv`) so that when `clr_i == 1'b1`, any partial split-handshake state (`inp_state_q` and `oup_state_q` across all `N_OUP` outputs) resets to `READY` on the rising edge of `clk_i`, allowing subsequent transactions after a mid-handshake flush to handshake on all outputs cleanly.

2. **Upstream response backpressure, heap-base underflow guard, and synchronous flush in `code/ibex_trvk.sv`**:
   - **Upstream response handshake (`upstream_rvalid_o && upstream_rready_i`)**: An entry in `u_prim_fifo_sync_align` may be popped (`misalign_flag_out_ready = 1'b1`), and `ptr_storage_q` / `ptr_storage_valid_q` may be updated, **only** when the upstream response actually handshakes (`upstream_rvalid_o && upstream_rready_i`). While `upstream_rvalid_o == 1'b1` and `upstream_rready_i == 1'b0`, `misalign_flag_out`, `ptr_storage_q`, `ptr_storage_valid_q`, and all upstream response outputs must remain stable.
   - **Unsigned heap-base underflow guard and 33-bit top bit check**: A capability is eligible for a revocation bitmap lookup (`revbm_req_required == 1'b1`) only when its reconstructed 33-bit base `cap_base_33` satisfies `!cap_base_33[32]`, `cap_base_33[31:0] >= heap_base_addr_i`, and `|(revbm_bit_addr[31:RevBitmapWordAddrWidth+$clog2(32)]) == 1'b0`. Capabilities with `cap_base_33[32] == 1'b1` or `cap_base_33[31:0] < heap_base_addr_i` are outside the revocable heap range and must not trigger a bitmap lookup (`revbm_req_required = 1'b0`, preserving `downstream_rsp_out.tag` on `upstream_tag_o`).
   - **Bitmap request stability under `upstream_rready_i == 1'b0`**: Once `revbm_req_o && revbm_gnt_i` has handshaked for the current second capability word, if `revbm_rvalid_i` arrives while `upstream_rready_i == 1'b0`, `ibex_trvk` must not issue a duplicate `revbm_req_o` for the same capability word before the upstream response handshakes (`upstream_rvalid_o && upstream_rready_i`).
   - **Synchronous `flush_i` recovery**: When `flush_i == 1'b1`, `ibex_trvk` must synchronously clear `u_prim_fifo_sync_align`, `u_prim_fifo_ds_rsp_store`, `ptr_storage_valid_q`, and `revbm_outstanding_q`, and suppress `upstream_rvalid_o`, `downstream_req_o`, `upstream_gnt_o`, and `revbm_req_o` during the flush cycle.

3. **Declarative timing budgets for transparent channels (`constraints.json`)**:
   - In `code/ibex_trvk_bridge_top.sv`, the bridge operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `4.0 ns` external input delay on all non-clock inputs and a `3.5 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`alert_in` to `alert_out` and `trace_in` to `trace_out`) even with zero internal delay. Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.5 ns` for `alert_in` to `alert_out` and `2.5 ns` for `trace_in` to `trace_out`, while preserving the existing timing requirements for all other ports.

Edit only `code/ibex_trvk.sv`, `code/stream_fork.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/ibex_trvk.sv`
- `code/stream_fork.sv`
- `constraints.json`

All other files in `code/` (`code/ibex_trvk_bridge_top.sv`, `code/ibex_cheriot_pkg.sv`, `code/stream_join_dynamic.sv`, `code/prim_*`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/ibex_trvk_bridge_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -DSYNTHESIS -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_secded_pkg.sv code/ibex_cheriot_pkg.sv code/prim_flop_macros.sv \
  code/prim_count.sv code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_secded_inv_39_32_dec.sv code/stream_fork.sv \
  code/stream_join_dynamic.sv code/ibex_trvk.sv \
  code/ibex_trvk_bridge_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `flush_i`, `heap_base_addr_i`, `upstream_req_i`, `upstream_rready_i`, `upstream_we_i`, `upstream_be_i`, `upstream_addr_i`, `upstream_wdata_i`, `upstream_wdata_intg_i`, `upstream_tag_i`, `downstream_gnt_i`, `downstream_rvalid_i`, `downstream_rdata_i`, `downstream_rdata_intg_i`, `downstream_err_i`, `downstream_tag_i`, `revbm_gnt_i`, `revbm_rvalid_i`, `revbm_rdata_i`, `revbm_rdata_intg_i`, `revbm_err_i`, `alert_in`, and `trace_in` (or bit-indexed `alert_in[0..7]`, `trace_in[0..7]`).
- Output groups are `upstream_gnt_o`, `upstream_rvalid_o`, `upstream_rdata_o`, `upstream_rdata_intg_o`, `upstream_err_o`, `upstream_tag_o`, `downstream_req_o`, `downstream_we_o`, `downstream_be_o`, `downstream_addr_o`, `downstream_wdata_o`, `downstream_wdata_intg_o`, `downstream_tag_o`, `revbm_req_o`, `revbm_addr_o`, `revbm_data_intg_error_o`, `revbm_device_error_o`, `alert_out`, and `trace_out` (or bit-indexed `alert_out[0..7]`, `trace_out[0..7]`).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.0 ns` input delay on all non-clock inputs (`set_input_delay 4.0 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ibex_trvk.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_trvk.sv (Golden Reference)
@@ -4,25 +4,17 @@
 
 `include "prim_assert.sv"
 
-// Assumes a tagged capability load always arrives downstream as exactly two consecutive,
-// uninterrupted 32-bit responses from a single, in-order requester.
 module ibex_trvk #(
-  // The number of outstanding transaction the IP supports
   parameter int unsigned NumOutstanding     = 32'd4,
-  // The width of the meta memory byte address space used to store the revocation bits
   parameter int unsigned RevBitmapAddrWidth = 32'd11,
-  // The base byte address of the meta SRAM holding the revocation bitmap
   parameter int unsigned RevBitmapBaseAddr  = 32'h0000_0000,
-  // Enable ECC checking on the revocation bitmap memory port
   parameter bit          MemECC             = 1'b1
 )(
   input  logic clk_i,
   input  logic rst_ni,
 
-  // Synchronous pipeline flush
   input  logic flush_i,
 
-  // The base address of the (heap) memory where to be revocable capabilities point to
   input  logic [31:0] heap_base_addr_i,
 
   // Upstream port
@@ -73,7 +65,6 @@
   import ibex_cheriot_pkg::*;
 
   localparam int unsigned RevBitmapWordAddrWidth = RevBitmapAddrWidth - 32'd2;
-
   typedef logic [RevBitmapWordAddrWidth-1:0] revbm_addr_t;
 
   typedef struct packed {
@@ -92,6 +83,9 @@
 
   logic align_fork_valid;
   logic align_fork_ready;
+  logic fork_gnt_raw;
+  logic ds_req_raw;
+  logic us_rvalid_raw;
 
   logic misalign_flag_out;
   logic misalign_flag_out_valid;
@@ -107,13 +101,12 @@
   logic    downstream_rsp_out_ready;
   logic    downstream_rsp_wready;
   logic    unused_downstream_rsp_wready;
-  logic    unused_flush_i;
 
   cap_meta_t    cap_meta;
   logic         unused_cap_meta;
   logic         is_sealing_cap;
   logic [32:0]  cap_base_33;
-  logic         unused_cap_base_33;
+  logic         cap_base_msb;
   logic [31:0]  cap_base;
   cbound_t      addr_mid;
   cap_cor_t     cap_correction;
@@ -132,18 +125,20 @@
 
   logic [1:0] revbm_rsp_data_intg_error;
 
-  assign unused_flush_i = flush_i;
-
   stream_fork #(
     .N_OUP(32'd2)
   ) u_stream_fork_us2ds (
     .clk_i,
     .rst_ni,
-    .valid_i(upstream_req_i),
-    .ready_o(upstream_gnt_o),
-    .valid_o({align_fork_valid, downstream_req_o}),
+    .valid_i(upstream_req_i & ~flush_i),
+    .clr_i  (flush_i),
+    .ready_o(fork_gnt_raw),
+    .valid_o({align_fork_valid, ds_req_raw}),
     .ready_i({align_fork_ready, downstream_gnt_i})
   );
+
+  assign upstream_gnt_o   = fork_gnt_raw & ~flush_i;
+  assign downstream_req_o = ds_req_raw   & ~flush_i;
 
   stream_join_dynamic #(
     .N_INP(32'd2)
@@ -151,9 +146,11 @@
     .inp_valid_i({revbm_rvalid_i,     downstream_rsp_out_valid}),
     .inp_ready_o({revbm_rsp_ready,    downstream_rsp_out_ready}),
     .sel_i      ({revbm_req_required, 1'b1                    }),
-    .oup_valid_o(upstream_rvalid_o),
-    .oup_ready_i(upstream_rready_i)
+    .oup_valid_o(us_rvalid_raw),
+    .oup_ready_i(upstream_rready_i & ~flush_i)
   );
+
+  assign upstream_rvalid_o = us_rvalid_raw & ~flush_i;
 
   assign downstream_we_o         = upstream_we_i;
   assign downstream_be_o         = upstream_be_i;
@@ -176,8 +173,8 @@
   ) u_prim_fifo_sync_align (
     .clk_i,
     .rst_ni,
-    .clr_i   (1'b0),
-    .wvalid_i(align_fork_valid),
+    .clr_i   (flush_i),
+    .wvalid_i(align_fork_valid & ~flush_i),
     .wready_o(align_fork_ready),
     .wdata_i (upstream_addr_i[2]),
     .rvalid_o(misalign_flag_out_valid),
@@ -188,28 +185,28 @@
     .err_o   ()
   );
 
-  assign misalign_flag_out_ready = upstream_rvalid_o;
+  assign misalign_flag_out_ready = upstream_rvalid_o & upstream_rready_i;
 
   assign ptr_storage_enable = downstream_rsp_out.tag && !misalign_flag_out &&
                               misalign_flag_out_valid;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : proc_pointer_store
-    if(!rst_ni) begin
+    if (!rst_ni) begin
       ptr_storage_q <= '0;
-    end else begin
-      if (misalign_flag_out_ready && ptr_storage_enable) begin
-        ptr_storage_q <= downstream_rsp_out.data;
-      end
+    end else if (flush_i) begin
+      ptr_storage_q <= '0;
+    end else if (misalign_flag_out_ready && ptr_storage_enable) begin
+      ptr_storage_q <= downstream_rsp_out.data;
     end
   end
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : proc_pointer_valid_store
-    if(!rst_ni) begin
+    if (!rst_ni) begin
       ptr_storage_valid_q <= 1'b0;
-    end else begin
-      if (misalign_flag_out_ready) begin
-        ptr_storage_valid_q <= ptr_storage_enable;
-      end
+    end else if (flush_i) begin
+      ptr_storage_valid_q <= 1'b0;
+    end else if (misalign_flag_out_ready) begin
+      ptr_storage_valid_q <= ptr_storage_enable;
     end
   end
 
@@ -229,8 +226,8 @@
   ) u_prim_fifo_ds_rsp_store (
     .clk_i,
     .rst_ni,
-    .clr_i   (1'b0),
-    .wvalid_i(downstream_rvalid_i),
+    .clr_i   (flush_i),
+    .wvalid_i(downstream_rvalid_i & ~flush_i),
     .wready_o(downstream_rsp_wready),
     .wdata_i (downstream_rsp_in),
     .rvalid_o(downstream_rsp_out_valid),
@@ -256,15 +253,18 @@
                                                   cheriot_get_base_correction(cap_correction),
                                                   cap_meta.exponent, ptr_storage_q);
   assign unused_cap_correction = ^cap_correction;
-  assign {unused_cap_base_33, cap_base} = cap_base_33;
+  assign {cap_base_msb, cap_base} = cap_base_33;
 
   assign revbm_cap_addr     = cap_base - heap_base_addr_i;
   assign revbm_bit_addr     = revbm_cap_addr >> $clog2(64/8);
   assign revbm_addr         = revbm_bit_addr[RevBitmapWordAddrWidth+$clog2(32)-1:$clog2(32)];
   assign revbm_bit_select   = revbm_bit_addr[$clog2(32)-1:0];
-  assign revbm_out_of_range = |(revbm_bit_addr[31:RevBitmapWordAddrWidth+$clog2(32)]);
-
-  assign revbm_req_required = !is_sealing_cap          &&
+  assign revbm_out_of_range = cap_base_msb ||
+                              (cap_base < heap_base_addr_i) ||
+                              (|(revbm_bit_addr[31:RevBitmapWordAddrWidth+$clog2(32)]));
+
+  assign revbm_req_required = !flush_i                 &&
+                              !is_sealing_cap          &&
                               ptr_storage_valid_q      &&
                               downstream_rsp_out.tag   &&
                               downstream_rsp_out_valid &&
@@ -297,14 +297,12 @@
   end
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : proc_rev_req_store
-    if(!rst_ni) begin
+    if (!rst_ni) begin
       revbm_outstanding_q <= 1'b0;
-    end else begin
-      if (revbm_rvalid_i && revbm_rsp_ready) begin
-        revbm_outstanding_q <= 1'b0;
-      end else if (revbm_req_o && revbm_gnt_i) begin
-        revbm_outstanding_q <= 1'b1;
-      end
+    end else if (flush_i || (revbm_rvalid_i && revbm_rsp_ready)) begin
+      revbm_outstanding_q <= 1'b0;
+    end else if (revbm_req_o && revbm_gnt_i) begin
+      revbm_outstanding_q <= 1'b1;
     end
   end
 

--- a/environment/public/code/stream_fork.sv (Buggy Starter)
+++ b/solution/gold/code/stream_fork.sv (Golden Reference)
@@ -12,6 +12,7 @@
     input  logic                clk_i,
     input  logic                rst_ni,
     input  logic                valid_i,
+    input  logic                clr_i,
     output logic                ready_o,
     output logic [N_OUP-1:0]    valid_o,
     input  logic [N_OUP-1:0]    ready_i
@@ -60,6 +61,8 @@
     always_ff @(posedge clk_i, negedge rst_ni) begin
         if (!rst_ni) begin
             inp_state_q <= READY;
+        end else if (clr_i) begin
+            inp_state_q <= READY;
         end else begin
             inp_state_q <= inp_state_d;
         end
@@ -101,6 +104,8 @@
         always_ff @(posedge clk_i, negedge rst_ni) begin
             if (!rst_ni) begin
                 oup_state_q <= READY;
+            end else if (clr_i) begin
+                oup_state_q <= READY;
             end else begin
                 oup_state_q <= oup_state_d;
             end

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,22 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": [
+        "alert_in"
+      ],
+      "to": [
+        "alert_out"
+      ],
+      "ns": 9.0
+    },
+    {
+      "from": [
+        "trace_in"
+      ],
+      "to": [
+        "trace_out"
+      ],
+      "ns": 10.0
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
- [`environment/public/code/ibex_cheriot_pkg.sv`](environment/public/code/ibex_cheriot_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_trvk.sv`](environment/public/code/ibex_trvk.sv) **(Editable)**
- [`environment/public/code/ibex_trvk_bridge_top.sv`](environment/public/code/ibex_trvk_bridge_top.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_count.sv`](environment/public/code/prim_count.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count_pkg.sv`](environment/public/code/prim_count_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_assert.svh`](environment/public/code/prim_fifo_assert.svh) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync.sv`](environment/public/code/prim_fifo_sync.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync_cnt.sv`](environment/public/code/prim_fifo_sync_cnt.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inc.svh`](environment/public/code/prim_secded_inc.svh) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_dec.sv`](environment/public/code/prim_secded_inv_39_32_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_pkg.sv`](environment/public/code/prim_secded_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/stream_fork.sv`](environment/public/code/stream_fork.sv) **(Editable)**
- [`environment/public/code/stream_join_dynamic.sv`](environment/public/code/stream_join_dynamic.sv) *(Read-Only Context)*
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

