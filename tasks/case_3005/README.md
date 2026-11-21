# `case_3005`: CV32E40P Hardware-Loop Register File Nested-Loop End-PC Resolution, APU Dispatcher Flush Drain, and Transparent Channel Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_3005` |
| **Source Silicon Repository** | `openhwfoundation/cv32e40p` (`repo_03`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `sdc_sta` (Multi-Mode Timing Constraints (SDC), Path Exceptions, OpenSTA & Closure) |
| **Multi-Domain Tags** | `reset_rdc`, `rtl_integration`, `sdc_sta` |
| **Editable Files (`allowed_edits`)** | [`code/cv32e40p_hwloop_regs.sv`](environment/public/code/cv32e40p_hwloop_regs.sv), [`code/cv32e40p_apu_disp.sv`](environment/public/code/cv32e40p_apu_disp.sv), [`constraints.json`](environment/public/constraints.json) (3 files, 299 LOC) |
| **Public Subsystem Context** | 4 RTL files (416 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Task-Specific Multi-Corner Liberty & SDC Timing Views** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Custom characterized fast/slow/scan corner Liberty libraries for multi-mode OpenSTA closure. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# CV32E40P Hardware-Loop Register File Nested-Loop End-PC Resolution, APU Dispatcher Flush Drain, and Transparent Channel Timing Budgets

In `code/cv32e40p_hwloop_regs.sv`, `code/cv32e40p_apu_disp.sv`, and `constraints.json` (integrated in `code/top.sv`), hardware-loop setup/decrement semantics on compressed and nested loops, APU dispatcher in-flight flush draining and latency tracking, and transparent control channel timing budgets fail verification:

1. **Hardware-Loop Register File Qualification, Halfword Alignment, and Nested End-PC Decrement (`code/cv32e40p_hwloop_regs.sv`):**
   - Setup writes (`hwlp_we_i[0]` for start address, `hwlp_we_i[1]` for end address, and `hwlp_we_i[2]` for counter) must only update `hwlp_start_addr_o`, `hwlp_end_addr_o`, and `hwlp_counter_o` when `valid_i` is high, and start/end loop bounds must preserve halfword alignment (`[31:1]` with bit 0 cleared to `1'b0`) so 16-bit compressed instructions can serve as loop start or end targets.
   - When `valid_i` is high and a loop counter is not being overwritten by `hwlp_we_i[2]`, asserting `hwlp_dec_cnt_i[i]` on a counter that is already `32'd0` must saturate at `32'd0` instead of underflowing to `32'hFFFF_FFFF`.
   - When inner loop `0` and outer loop `1` share the same end address (`hwlp_dec_cnt_i == 2'b11` with `valid_i == 1'b1`): if inner loop `0` has remaining iterations after the current pass (`hwlp_counter_o[0] > 32'd1` and loop `0` is not being written by `hwlp_we_i[2]`), only loop `0` decrements while outer loop `1` holds its counter; if inner loop `0` is on its final pass (`hwlp_counter_o[0] <= 32'd1`), both loop `0` and outer loop `1` decrement (saturating at zero).

2. **APU Dispatcher Latency Preservation and Post-Flush In-Flight Drain (`code/cv32e40p_apu_disp.sv`):**
   - The stored latency class driving `apu_multicycle_o` must not be overwritten by an ungranted request (`enable_i` when `apu_gnt_i` is low) while an older operation is still active (`active_o == 1'b1`).
   - Asserting `flush_i` must immediately suppress new APU requests (`apu_req_o = 1'b0`) and writeback valid pulses (`apu_rvalid_wb_o = 1'b0`) in that cycle, and mark any already-accepted in-flight APU operations as flushed so their subsequent `apu_rvalid_i` responses drain from the two-slot tracking pipeline without asserting `apu_rvalid_wb_o` or reporting register dependencies (`read_dep_o`, `read_dep_for_jalr_o`, `write_dep_o`), while keeping `active_o` and slot-full/latency-order stall protection active until those stale responses return. New requests accepted after `flush_i` deasserts must retire normally even if an older flushed slot is still draining ahead of them.

3. **Transparent Channel Timing Budgets (`constraints.json`):**
   - In `code/top.sv`, the subsystem operates at `8 ns` and `10 ns` clock periods (`clk_i`), with a `3.25 ns` external input delay on all non-clock inputs and a `2.75 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`fpu_rm_in` to `fpu_rm_out` and `hart_ctrl_in` to `hart_ctrl_out`). Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.10 ns` for `fpu_rm_in` to `fpu_rm_out` and `1.85 ns` for `hart_ctrl_in` to `hart_ctrl_out`, while preserving the existing sequential timing requirements on all registered hardware-loop and APU dispatcher ports. Edit only `code/cv32e40p_hwloop_regs.sv`, `code/cv32e40p_apu_disp.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Guide

## Editable Files
- `code/cv32e40p_hwloop_regs.sv`
- `code/cv32e40p_apu_disp.sv`
- `constraints.json`

Do not modify `code/top.sv`, `code/LICENSE`, or any file in `lib/` (`lib/NangateOpenCellLibrary_typical.lib`, `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, `lib/LICENSE.Nangate45`).

## Simulation & Synthesis Toolchain
- **Verilator (`verilator-v5.038`)**:
  ```bash
  verilator --binary --timing -Wno-fatal --top-module top \
    code/cv32e40p_hwloop_regs.sv code/cv32e40p_apu_disp.sv code/top.sv
  ```
- **Yosys + Slang (`oss-cad-suite/bin/yosys`)**:
  ```bash
  yosys -m slang -Q -p "read_slang --top top code/cv32e40p_hwloop_regs.sv code/cv32e40p_apu_disp.sv code/top.sv; hierarchy -check -top top; proc; opt_clean; select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*; synth -top top; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; check -assert; write_verilog -noattr /tmp/mapped.v"
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
create_clock -period <8_or_10> [get_ports clk_i]
set_input_delay 3.25 -clock clk_i [get_ports {<all_non_clock_inputs>}]
set_output_delay 2.75 -clock clk_i [get_ports {<all_outputs>}]
```
with `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib` in OpenROAD (`openroad -exit`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cv32e40p_hwloop_regs.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e40p_hwloop_regs.sv (Golden Reference)
@@ -1,26 +1,5 @@
 // Copyright 2018 ETH Zurich and University of Bologna.
-// Copyright and related rights are licensed under the Solderpad Hardware
-// License, Version 0.51 (the "License"); you may not use this file except in
-// compliance with the License.  You may obtain a copy of the License at
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
-// or agreed to in writing, software, hardware and materials distributed under
-// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
-// CONDITIONS OF ANY KIND, either express or implied. See the License for the
-// specific language governing permissions and limitations under the License.
-
-////////////////////////////////////////////////////////////////////////////////
-// Engineer:       Michael Gautschi - gautschi@iis.ee.ethz.ch                 //
-//                                                                            //
-// Design Name:    hwloop regs                                                //
-// Project Name:   RI5CY                                                      //
-// Language:       SystemVerilog                                              //
-//                                                                            //
-// Description:    Hardware loop registers                                    //
-//                 a) store start/end address of N=4 hardware loops           //
-//                 b) store init value of counter for each hardware loop      //
-//                 c) decrement counter if hwloop taken                       //
-//                                                                            //
-////////////////////////////////////////////////////////////////////////////////
+// Solderpad Hardware License, Version 0.51
 
 module cv32e40p_hwloop_regs #(
     parameter N_REGS     = 2,
@@ -29,25 +8,20 @@
     input logic clk,
     input logic rst_n,
 
-    // from ex stage
     input logic [          31:0] hwlp_start_data_i,
     input logic [          31:0] hwlp_end_data_i,
     input logic [          31:0] hwlp_cnt_data_i,
     input logic [           2:0] hwlp_we_i,
-    input logic [N_REG_BITS-1:0] hwlp_regid_i,  // selects the register set
+    input logic [N_REG_BITS-1:0] hwlp_regid_i,
 
-    // from controller
     input logic valid_i,
 
-    // from hwloop controller
     input logic [N_REGS-1:0] hwlp_dec_cnt_i,
 
-    // to hwloop controller
     output logic [N_REGS-1:0][31:0] hwlp_start_addr_o,
     output logic [N_REGS-1:0][31:0] hwlp_end_addr_o,
     output logic [N_REGS-1:0][31:0] hwlp_counter_o
 );
-
 
   logic [N_REGS-1:0][31:0] hwlp_start_q;
   logic [N_REGS-1:0][31:0] hwlp_end_q;
@@ -55,63 +29,48 @@
 
   int unsigned i;
 
-
   assign hwlp_start_addr_o = hwlp_start_q;
   assign hwlp_end_addr_o   = hwlp_end_q;
   assign hwlp_counter_o    = hwlp_counter_q;
 
-
-  /////////////////////////////////////////////////////////////////////////////////
-  // HWLOOP start-address register                                               //
-  /////////////////////////////////////////////////////////////////////////////////
   always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_START
     if (rst_n == 1'b0) begin
       hwlp_start_q <= '{default: 32'b0};
-    end else if (hwlp_we_i[0] == 1'b1) begin
-      hwlp_start_q[hwlp_regid_i] <= {hwlp_start_data_i[31:2], 2'b0};
+    end else if (valid_i && (hwlp_we_i[0] == 1'b1)) begin
+      hwlp_start_q[hwlp_regid_i] <= {hwlp_start_data_i[31:1], 1'b0};
     end
   end
 
-
-  /////////////////////////////////////////////////////////////////////////////////
-  // HWLOOP end-address register                                                 //
-  /////////////////////////////////////////////////////////////////////////////////
   always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_END
     if (rst_n == 1'b0) begin
       hwlp_end_q <= '{default: 32'b0};
-    end else if (hwlp_we_i[1] == 1'b1) begin
-      hwlp_end_q[hwlp_regid_i] <= {hwlp_end_data_i[31:2], 2'b0};
+    end else if (valid_i && (hwlp_we_i[1] == 1'b1)) begin
+      hwlp_end_q[hwlp_regid_i] <= {hwlp_end_data_i[31:1], 1'b0};
     end
   end
 
-
-  /////////////////////////////////////////////////////////////////////////////////
-  // HWLOOP counter register with decrement logic                                //
-  /////////////////////////////////////////////////////////////////////////////////
   genvar k;
-  for (k = 0; k < N_REGS; k++) begin
-    assign hwlp_counter_n[k] = hwlp_counter_q[k] - 1;
+  for (k = 0; k < N_REGS; k++) begin : gen_dec
+    assign hwlp_counter_n[k] = (hwlp_counter_q[k] > 32'd0) ? (hwlp_counter_q[k] - 32'd1) : 32'd0;
   end
 
   always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_COUNTER
     if (rst_n == 1'b0) begin
       hwlp_counter_q <= '{default: 32'b0};
-    end else begin
+    end else if (valid_i) begin
       for (i = 0; i < N_REGS; i++) begin
-        if ((hwlp_we_i[2] == 1'b1) && (i == hwlp_regid_i)) begin
+        if ((hwlp_we_i[2] == 1'b1) && (i[N_REG_BITS-1:0] == hwlp_regid_i)) begin
           hwlp_counter_q[i] <= hwlp_cnt_data_i;
-        end else begin
-          if (hwlp_dec_cnt_i[i] && valid_i) hwlp_counter_q[i] <= hwlp_counter_n[i];
+        end else if (hwlp_dec_cnt_i[i]) begin
+          if ((i == 1) && hwlp_dec_cnt_i[0] && (hwlp_counter_q[0] > 32'd1) &&
+              !((hwlp_we_i[2] == 1'b1) && (hwlp_regid_i == '0))) begin
+            hwlp_counter_q[i] <= hwlp_counter_q[i];
+          end else begin
+            hwlp_counter_q[i] <= hwlp_counter_n[i];
+          end
         end
       end
     end
   end
 
-  //----------------------------------------------------------------------------
-  // Assertions
-  //----------------------------------------------------------------------------
-`ifdef CV32E40P_ASSERT_ON
-  // do not decrement more than one counter at once
-  assert property (@(posedge clk) (valid_i) |-> ($countones(hwlp_dec_cnt_i) <= 1));
-`endif
 endmodule

--- a/environment/public/code/cv32e40p_apu_disp.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e40p_apu_disp.sv (Golden Reference)
@@ -5,27 +5,20 @@
     input logic clk_i,
     input logic rst_ni,
 
-    // pipeline flush / trap kill
     input logic flush_i,
 
-    // request input
     input logic       enable_i,
     input logic [1:0] apu_lat_i,
     input logic [5:0] apu_waddr_i,
 
-    // response output
     output logic [5:0] apu_waddr_o,
     output logic       apu_multicycle_o,
     output logic       apu_singlecycle_o,
     output logic       apu_rvalid_wb_o,
 
-    // active signal
     output logic active_o,
-
-    // stall signals
     output logic stall_o,
 
-    // dependency checks
     input  logic            is_decoding_i,
     input  logic [2:0][5:0] read_regs_i,
     input  logic [2:0]      read_regs_valid_i,
@@ -36,11 +29,9 @@
     input  logic [1:0]      write_regs_valid_i,
     output logic            write_dep_o,
 
-    // perf counter stuff
     output logic perf_type_o,
     output logic perf_cont_o,
 
-    // apu-interconnect
     output logic apu_req_o,
     input  logic apu_gnt_i,
     input  logic apu_rvalid_i
@@ -50,6 +41,8 @@
   logic [5:0] addr_inflight_dn, addr_waiting_dn;
   logic valid_req, valid_inflight, valid_waiting;
   logic valid_inflight_dn, valid_waiting_dn;
+  logic kill_inflight, kill_waiting;
+  logic kill_inflight_dn, kill_waiting_dn;
   logic returned_req, returned_inflight, returned_waiting;
 
   logic       req_accepted;
@@ -63,13 +56,13 @@
 
   logic stall_full, stall_type, stall_nack;
 
-  assign valid_req    = enable_i & !(stall_full | stall_type);
+  assign valid_req    = enable_i & !flush_i & !(stall_full | stall_type);
   assign addr_req     = apu_waddr_i;
   assign req_accepted = valid_req & apu_gnt_i;
 
   assign returned_req      = valid_req & apu_rvalid_i & !valid_inflight & !valid_waiting;
-  assign returned_inflight = valid_inflight & (apu_rvalid_i) & !valid_waiting;
-  assign returned_waiting  = valid_waiting & (apu_rvalid_i);
+  assign returned_inflight = valid_inflight & apu_rvalid_i & !valid_waiting;
+  assign returned_waiting  = valid_waiting & apu_rvalid_i;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (~rst_ni) begin
@@ -77,11 +70,15 @@
       valid_waiting  <= 1'b0;
       addr_inflight  <= '0;
       addr_waiting   <= '0;
+      kill_inflight  <= 1'b0;
+      kill_waiting   <= 1'b0;
     end else begin
       valid_inflight <= valid_inflight_dn;
       valid_waiting  <= valid_waiting_dn;
       addr_inflight  <= addr_inflight_dn;
       addr_waiting   <= addr_waiting_dn;
+      kill_inflight  <= kill_inflight_dn;
+      kill_waiting   <= kill_waiting_dn;
     end
   end
 
@@ -90,26 +87,34 @@
     valid_waiting_dn  = valid_waiting;
     addr_inflight_dn  = addr_inflight;
     addr_waiting_dn   = addr_waiting;
+    kill_inflight_dn  = kill_inflight | (flush_i & valid_inflight);
+    kill_waiting_dn   = kill_waiting  | (flush_i & valid_waiting);
 
     if (req_accepted & !returned_req) begin
       valid_inflight_dn = 1'b1;
       addr_inflight_dn  = addr_req;
-      if (valid_inflight & !(returned_inflight)) begin
+      kill_inflight_dn  = 1'b0;
+      if (valid_inflight & !returned_inflight) begin
         valid_waiting_dn = 1'b1;
         addr_waiting_dn  = addr_inflight;
+        kill_waiting_dn  = kill_inflight | flush_i;
       end
       if (returned_waiting) begin
         valid_waiting_dn = 1'b1;
         addr_waiting_dn  = addr_inflight;
+        kill_waiting_dn  = kill_inflight | flush_i;
       end
     end else if (returned_inflight) begin
-      valid_inflight_dn = '0;
-      valid_waiting_dn  = '0;
+      valid_inflight_dn = 1'b0;
+      valid_waiting_dn  = 1'b0;
       addr_inflight_dn  = '0;
       addr_waiting_dn   = '0;
+      kill_inflight_dn  = 1'b0;
+      kill_waiting_dn   = 1'b0;
     end else if (returned_waiting) begin
-      valid_waiting_dn = '0;
+      valid_waiting_dn = 1'b0;
       addr_waiting_dn  = '0;
+      kill_waiting_dn  = 1'b0;
     end
   end
 
@@ -118,10 +123,8 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (~rst_ni) begin
       apu_lat <= '0;
-    end else begin
-      if (valid_req) begin
-        apu_lat <= apu_lat_i;
-      end
+    end else if (req_accepted || (valid_req && !active)) begin
+      apu_lat <= apu_lat_i;
     end
   end
 
@@ -141,22 +144,22 @@
     end
   endgenerate
 
-  assign read_dep_req      = |read_deps_req & valid_req & !returned_req;
-  assign read_dep_inflight = |read_deps_inflight & valid_inflight & !returned_inflight;
-  assign read_dep_waiting  = |read_deps_waiting & valid_waiting & !returned_waiting;
+  assign read_dep_req       = |read_deps_req & valid_req & !returned_req;
+  assign read_dep_inflight  = |read_deps_inflight & valid_inflight & !kill_inflight & !returned_inflight;
+  assign read_dep_waiting   = |read_deps_waiting & valid_waiting & !kill_waiting & !returned_waiting;
   assign write_dep_req      = |write_deps_req & valid_req & !returned_req;
-  assign write_dep_inflight = |write_deps_inflight & valid_inflight & !returned_inflight;
-  assign write_dep_waiting  = |write_deps_waiting & valid_waiting & !returned_waiting;
+  assign write_dep_inflight = |write_deps_inflight & valid_inflight & !kill_inflight & !returned_inflight;
+  assign write_dep_waiting  = |write_deps_waiting & valid_waiting & !kill_waiting & !returned_waiting;
 
   assign read_dep_o  = (read_dep_req | read_dep_inflight | read_dep_waiting) & is_decoding_i;
   assign write_dep_o = (write_dep_req | write_dep_inflight | write_dep_waiting) & is_decoding_i;
 
-  assign read_dep_for_jalr_o = is_decoding_i & ((|read_deps_req & enable_i) |
-                                                (|read_deps_inflight & valid_inflight) |
-                                                (|read_deps_waiting & valid_waiting));
+  assign read_dep_for_jalr_o = is_decoding_i & ((|read_deps_req & enable_i & !flush_i) |
+                                                (|read_deps_inflight & valid_inflight & !kill_inflight) |
+                                                (|read_deps_waiting & valid_waiting & !kill_waiting));
 
   assign stall_full = valid_inflight & valid_waiting;
-  assign stall_type = enable_i & active & ((apu_lat_i == 2'h1) | ((apu_lat_i == 2'h2) & (apu_lat == 2'h3)) | (apu_lat_i == 2'h3));
+  assign stall_type = enable_i & !flush_i & active & ((apu_lat_i == 2'h1) | ((apu_lat_i == 2'h2) & (apu_lat == 2'h3)) | (apu_lat_i == 2'h3));
   assign stall_nack = valid_req & !apu_gnt_i;
   assign stall_o    = stall_full | stall_type | stall_nack;
 
@@ -174,6 +177,8 @@
   assign perf_cont_o       = stall_nack;
   assign apu_multicycle_o  = (apu_lat == 2'h3);
   assign apu_singlecycle_o = ~(valid_inflight | valid_waiting);
-  assign apu_rvalid_wb_o   = returned_req | returned_inflight | returned_waiting;
+  assign apu_rvalid_wb_o   = !flush_i && (returned_req ||
+                             (returned_inflight && !kill_inflight) ||
+                             (returned_waiting && !kill_waiting));
 
 endmodule

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,22 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": [
+        "fpu_rm_in"
+      ],
+      "to": [
+        "fpu_rm_out"
+      ],
+      "ns": 7.1
+    },
+    {
+      "from": [
+        "hart_ctrl_in"
+      ],
+      "to": [
+        "hart_ctrl_out"
+      ],
+      "ns": 7.85
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
- [`environment/public/code/cv32e40p_apu_disp.sv`](environment/public/code/cv32e40p_apu_disp.sv) **(Editable)**
- [`environment/public/code/cv32e40p_hwloop_regs.sv`](environment/public/code/cv32e40p_hwloop_regs.sv) **(Editable)**
- [`environment/public/code/top.sv`](environment/public/code/top.sv) *(Read-Only Context)*
- [`environment/public/constraints.json`](environment/public/constraints.json) **(Editable)**
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

