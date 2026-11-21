# `case_3006`: CV32E40P Load-Store Unit Split-Misaligned Fault Cancellation, Post-Flush OBI Response Drain, and Transparent Channel Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_3006` |
| **Source Silicon Repository** | `openhwfoundation/cv32e40p` (`repo_03`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `reset_rdc` (Reset Recovery, Abort Drain, Reset Domain Crossing (RDC) & Boot Sequencing) |
| **Multi-Domain Tags** | `protocol_control`, `reset_rdc`, `rtl_integration`, `sdc_sta`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/cv32e40p_load_store_unit.sv`](environment/public/code/cv32e40p_load_store_unit.sv), [`code/cv32e40p_obi_interface.sv`](environment/public/code/cv32e40p_obi_interface.sv), [`constraints.json`](environment/public/constraints.json) (3 files, 456 LOC) |
| **Public Subsystem Context** | 4 RTL files (556 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library (Shared Base Image)** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Uses unified Nangate45 typical Liberty and LEF from base image. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# CV32E40P Load-Store Unit Split-Misaligned Fault Cancellation, Post-Flush OBI Response Drain, and Transparent Channel Timing Budgets

In `code/cv32e40p_load_store_unit.sv`, `code/cv32e40p_obi_interface.sv`, and `constraints.json` (integrated in `code/top.sv`), split-misaligned PMP/bus fault handling, synchronous pipeline flush draining of in-flight OBI transactions, `cv.elw` load-event pulses, and transparent control channel timing budgets fail verification:

1. **OBI Address-Phase Stability and Bus-Error Forwarding (`code/cv32e40p_obi_interface.sv`):**
   - When configured with `TRANS_STABLE = 0` and an OBI request is not immediately granted (`obi_req_o && !obi_gnt_i`), all address-phase outputs (`obi_addr_o`, `obi_we_o`, `obi_be_o`, `obi_wdata_o`, `obi_atop_o`) must hold their captured values stable until `obi_gnt_i` asserts, and `obi_err_i` must be forwarded on `resp_err_o`.

2. **Load-Store Unit Split-Misaligned Fault Cancellation, Post-Flush Drain, and `cv.elw` Handshake (`code/cv32e40p_load_store_unit.sv`):**
   - Report non-flushed external OBI bus errors (`data_rvalid_i && data_err_i`) and accepted-request PMP errors (`data_err_pmp_i` when a request is ready to issue) on `load_err_o` (for loads) and `store_err_o` (for stores), without corrupting the held read data output (`data_rdata_ex_o`) when a load response carries `data_err_i = 1'b1`. A PMP-faulted request (`data_err_pmp_i = 1'b1`) must be blocked from issuing to the OBI interface (`data_req_o = 1'b0`) and must not increment the outstanding OBI response counter, while still asserting `lsu_ready_ex_o` once any prior un-flushed response completes.
   - When the first half of a split misaligned transfer (`data_misaligned_o == 1'b1`) faults on either `data_err_pmp_i` or `data_err_i` while the pipeline presents the second half (`data_misaligned_ex_i == 1'b1`), the LSU must suppress issuing the second-half OBI request (`data_req_o = 1'b0` for that second half) while still asserting `lsu_ready_ex_o` once any prior un-flushed response completes so the pipeline can retire the faulted instruction without hanging.
   - Asserting `flush_i` must immediately block new LSU transaction requests (`lsu_ready_ex_o = 1'b0`, no new `data_req_o` transfer initiated in that cycle), clear any pending `cv.elw` load-event state, and mark any already-accepted in-flight OBI requests as flushed so their subsequent `data_rvalid_i` responses drain from the outstanding counter without asserting `load_err_o`, `store_err_o`, `p_elw_finish_o`, or updating `data_rdata_ex_o`, and without prematurely releasing `lsu_ready_wb_o` / `lsu_ready_ex_o` for a post-flush transaction.
   - `p_elw_start_o` must pulse only on the cycle a non-misaligned (`!data_misaligned_ex_i`), non-PMP-faulted (`!data_err_pmp_i`) `data_load_event_ex_i` request is accepted into the OBI interface, and `p_elw_finish_o` must pulse only when its corresponding non-flushed final `data_rvalid_i` response returns.

3. **Transparent Channel Timing Budgets (`constraints.json`):**
   - In `code/top.sv`, the subsystem operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `4.25 ns` external input delay on all non-clock inputs and a `3.25 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`mpu_region_in` to `mpu_region_out` and `hart_dbg_in` to `hart_dbg_out`). Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.35 ns` for `mpu_region_in` to `mpu_region_out` and `2.15 ns` for `hart_dbg_in` to `hart_dbg_out`, while preserving the existing sequential timing requirements on all registered LSU and OBI ports. Edit only `code/cv32e40p_load_store_unit.sv`, `code/cv32e40p_obi_interface.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Guide

## Editable Files
- `code/cv32e40p_load_store_unit.sv`
- `code/cv32e40p_obi_interface.sv`
- `constraints.json`

Do not modify `code/top.sv` or `code/LICENSE`.

## Simulation & Synthesis Toolchain
- **Verilator (`verilator-v5.038`)**:
  ```bash
  verilator --binary --timing -Wno-fatal --top-module top \
    code/cv32e40p_obi_interface.sv code/cv32e40p_load_store_unit.sv code/top.sv
  ```
- **Yosys + Slang (`oss-cad-suite/bin/yosys`)**:
  ```bash
  yosys -m slang -Q -p "read_slang --top top code/cv32e40p_obi_interface.sv code/cv32e40p_load_store_unit.sv code/top.sv; hierarchy -check -top top; proc; opt_clean; select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*; synth -top top; read_liberty -lib /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; dfflibmap -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; abc -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; clean; check -assert; write_verilog -noattr mapped.v"
  ```

## Declarative Timing Exceptions (`constraints.json`)
`constraints.json` must contain a single top-level key `"max_delays"` mapping to a list of rule objects:
```json
{
  "max_delays": [
    {
      "from": ["<input_port_or_bit>", ...],
      "to": ["<output_port_or_bit>", ...],
      "ns": <positive_float>
    }
  ]
}
```
Each rule is translated by the evaluation harness into:
```tcl
set_max_delay <ns> -from [get_ports {<from>}] -to [get_ports {<to>}]
```
after applying:
```tcl
create_clock -period <10_or_12> [get_ports clk_i]
set_input_delay 4.25 -clock clk_i [get_ports {<all_non_clock_inputs>}]
set_output_delay 3.25 -clock clk_i [get_ports {<all_outputs>}]
```
in OpenROAD (`openroad -exit`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cv32e40p_load_store_unit.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e40p_load_store_unit.sv (Golden Reference)
@@ -8,7 +8,6 @@
     input logic rst_n,
     input logic flush_i,
 
-    // output to data memory
     output logic        data_req_o,
     input  logic        data_gnt_i,
     input  logic        data_rvalid_i,
@@ -21,7 +20,6 @@
     output logic [31:0] data_wdata_o,
     input  logic [31:0] data_rdata_i,
 
-    // signals from ex stage
     input  logic        data_we_ex_i,
     input  logic [ 1:0] data_type_ex_i,
     input  logic [31:0] data_wdata_ex_i,
@@ -67,10 +65,14 @@
   logic [31:0] resp_rdata;
   logic        resp_err;
 
-  logic [ 1:0] cnt_q;
-  logic [ 1:0] next_cnt;
-  logic        count_up;
-  logic        count_down;
+  logic [ 1:0] cnt_q, next_cnt;
+  logic [ 1:0] flush_cnt_q, next_flush_cnt;
+  logic        count_up, count_down;
+  logic        resp_is_flushed;
+  logic        valid_resp;
+  logic        first_half_fault_q, first_half_fault_n;
+  logic        suppress_second_half;
+  logic        req_intent;
 
   logic        ctrl_update;
   logic [31:0] data_addr_int;
@@ -86,6 +88,11 @@
   logic [31:0] data_wdata;
   logic        misaligned_st;
   logic [31:0] rdata_q;
+
+  assign resp_is_flushed      = flush_i || (flush_cnt_q != 2'b00);
+  assign valid_resp           = resp_valid && !resp_is_flushed;
+  assign suppress_second_half = data_misaligned_ex_i &&
+                                (first_half_fault_q || (valid_resp && resp_err));
 
   always_comb begin
     case (data_type_ex_i)
@@ -146,7 +153,9 @@
       data_sign_ext_q   <= '0;
       data_we_q         <= 1'b0;
       data_load_event_q <= 1'b0;
-    end else if (ctrl_update) begin
+    end else if (flush_i) begin
+      data_load_event_q <= 1'b0;
+    end else if (ctrl_update && !suppress_second_half) begin
       data_type_q       <= data_type_ex_i;
       rdata_offset_q    <= data_addr_int[1:0];
       data_sign_ext_q   <= data_sign_ext_ex_i;
@@ -155,8 +164,8 @@
     end
   end
 
-  assign p_elw_start_o  = data_load_event_ex_i && data_req_o;
-  assign p_elw_finish_o = data_load_event_q && data_rvalid_i && !data_misaligned_ex_i;
+  assign p_elw_start_o  = data_load_event_ex_i && trans_valid && trans_ready && !data_misaligned_ex_i && !data_err_pmp_i;
+  assign p_elw_finish_o = data_load_event_q && valid_resp && !data_misaligned_ex_i;
 
   logic [31:0] data_rdata_ext;
   logic [31:0] rdata_w_ext;
@@ -234,26 +243,39 @@
     if (rst_n == 1'b0) begin
       rdata_q <= '0;
     end else begin
-      if (resp_valid && (~data_we_q)) begin
+      if (valid_resp && !resp_err && (~data_we_q)) begin
         if ((data_misaligned_ex_i == 1'b1) || (data_misaligned_o == 1'b1)) rdata_q <= resp_rdata;
         else rdata_q <= data_rdata_ext;
       end
     end
   end
 
-  assign data_rdata_ex_o = (resp_valid == 1'b1) ? data_rdata_ext : rdata_q;
+  assign data_rdata_ex_o = (valid_resp && !resp_err) ? data_rdata_ext : rdata_q;
   assign misaligned_st   = data_misaligned_ex_i;
 
-  assign load_err_o      = data_gnt_i && data_err_pmp_i && ~data_we_o;
-  assign store_err_o     = data_gnt_i && data_err_pmp_i && data_we_o;
+  assign load_err_o  = (valid_resp && resp_err && ~data_we_q) ||
+                       (req_intent && trans_ready && data_err_pmp_i && ~data_we_ex_i);
+  assign store_err_o = (valid_resp && resp_err && data_we_q) ||
+                       (req_intent && trans_ready && data_err_pmp_i && data_we_ex_i);
 
   always_comb begin
     data_misaligned_o = 1'b0;
-    if ((data_req_ex_i == 1'b1) && (data_misaligned_ex_i == 1'b0)) begin
+    if ((data_req_ex_i == 1'b1) && (data_misaligned_ex_i == 1'b0) && !flush_i) begin
       case (data_type_ex_i)
         2'b00: if (data_addr_int[1:0] != 2'b00) data_misaligned_o = 1'b1;
         2'b01: if (data_addr_int[1:0] == 2'b11) data_misaligned_o = 1'b1;
       endcase
+    end
+  end
+
+  always_comb begin
+    first_half_fault_n = first_half_fault_q;
+    if (flush_i) begin
+      first_half_fault_n = 1'b0;
+    end else if (data_misaligned_o && req_intent && trans_ready && data_err_pmp_i) begin
+      first_half_fault_n = 1'b1;
+    end else if (data_misaligned_ex_i && lsu_ready_ex_o) begin
+      first_half_fault_n = 1'b0;
     end
   end
 
@@ -266,24 +288,30 @@
   assign trans_wdata = data_wdata;
   assign trans_atop  = data_atop_ex_i;
 
+  logic [1:0] active_cnt;
+  assign active_cnt = (cnt_q >= flush_cnt_q) ? (cnt_q - flush_cnt_q) : 2'b00;
+
   generate
     if (PULP_OBI == 0) begin : gen_no_pulp_obi
-      assign trans_valid = data_req_ex_i && (cnt_q < DEPTH);
+      assign req_intent = data_req_ex_i && !flush_i && !suppress_second_half && (cnt_q < DEPTH);
     end else begin : gen_pulp_obi
-      assign trans_valid = (cnt_q == 2'b00) ? data_req_ex_i && (cnt_q < DEPTH) :
-                                              data_req_ex_i && (cnt_q < DEPTH) && resp_valid;
+      assign req_intent = (cnt_q == 2'b00) ? (data_req_ex_i && !flush_i && !suppress_second_half && (cnt_q < DEPTH)) :
+                                             (data_req_ex_i && !flush_i && !suppress_second_half && (cnt_q < DEPTH) && resp_valid);
     end
   endgenerate
-
-  assign lsu_ready_wb_o = (cnt_q == 2'b00) ? 1'b1 : resp_valid;
-  assign lsu_ready_ex_o = (data_req_ex_i == 1'b0) ? 1'b1 :
-                          (cnt_q == 2'b00) ? (trans_valid && trans_ready) :
-                          (cnt_q == 2'b01) ? (resp_valid && trans_valid && trans_ready) :
-                                              resp_valid;
+  assign trans_valid = req_intent && !data_err_pmp_i;
+
+  assign lsu_ready_wb_o = (active_cnt == 2'b00) ? 1'b1 : valid_resp;
+  assign lsu_ready_ex_o = flush_i ? 1'b0 :
+                          (data_req_ex_i == 1'b0) ? 1'b1 :
+                          (suppress_second_half || (req_intent && trans_ready && data_err_pmp_i)) ? ((active_cnt == 2'b00) ? 1'b1 : valid_resp) :
+                          (active_cnt == 2'b00) ? (trans_valid && trans_ready) :
+                          (active_cnt == 2'b01) ? (valid_resp && trans_valid && trans_ready) :
+                                                  valid_resp;
 
   assign ctrl_update = lsu_ready_ex_o && data_req_ex_i;
 
-  assign count_up   = trans_valid && trans_ready;
+  assign count_up   = trans_valid && trans_ready && !data_err_pmp_i;
   assign count_down = resp_valid;
 
   always_comb begin
@@ -295,11 +323,24 @@
     endcase
   end
 
+  always_comb begin
+    next_flush_cnt = flush_cnt_q;
+    if (flush_i) begin
+      next_flush_cnt = (resp_valid && (cnt_q != 2'b00)) ? (cnt_q - 2'b01) : cnt_q;
+    end else if (resp_valid && (flush_cnt_q != 2'b00)) begin
+      next_flush_cnt = flush_cnt_q - 2'b01;
+    end
+  end
+
   always_ff @(posedge clk, negedge rst_n) begin
     if (rst_n == 1'b0) begin
-      cnt_q <= '0;
+      cnt_q              <= '0;
+      flush_cnt_q        <= '0;
+      first_half_fault_q <= 1'b0;
     end else begin
-      cnt_q <= next_cnt;
+      cnt_q              <= next_cnt;
+      flush_cnt_q        <= next_flush_cnt;
+      first_half_fault_q <= first_half_fault_n;
     end
   end
 

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
@@ -1,3 +1,22 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": [
+        "mpu_region_in"
+      ],
+      "to": [
+        "mpu_region_out"
+      ],
+      "ns": 8.85
+    },
+    {
+      "from": [
+        "hart_dbg_in"
+      ],
+      "to": [
+        "hart_dbg_out"
+      ],
+      "ns": 9.65
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
- [`environment/public/code/cv32e40p_load_store_unit.sv`](environment/public/code/cv32e40p_load_store_unit.sv) **(Editable)**
- [`environment/public/code/cv32e40p_obi_interface.sv`](environment/public/code/cv32e40p_obi_interface.sv) **(Editable)**
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

