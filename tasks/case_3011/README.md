# `case_3011`: CV32E40P Interrupt Controller Qualification, Dual-Mode Sleep Unit Clock Gating, and Transparent Channel Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_3011` |
| **Source Silicon Repository** | `openhwfoundation/cv32e40p` (`repo_03`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `low_power` (Low-Power Clock Gating, Sleep State Retention, Isolation & Wakeup Sequencing) |
| **Multi-Domain Tags** | `clocking`, `low_power`, `rtl_integration`, `sdc_sta` |
| **Editable Files (`allowed_edits`)** | [`code/cv32e40p_int_controller.sv`](environment/public/code/cv32e40p_int_controller.sv), [`code/cv32e40p_sleep_unit.sv`](environment/public/code/cv32e40p_sleep_unit.sv), [`constraints.json`](environment/public/constraints.json) (3 files, 233 LOC) |
| **Public Subsystem Context** | 6 RTL files (1158 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library (Shared Base Image)** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Uses unified Nangate45 typical Liberty and LEF from base image. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# CV32E40P Interrupt Controller Qualification, Dual-Mode Sleep Unit Clock Gating, and Transparent Channel Timing Budgets

In `code/cv32e40p_int_controller.sv`, `code/cv32e40p_sleep_unit.sv`, and `constraints.json` (integrated in `code/top.sv`), interrupt wake-up/security qualification, runtime cluster vs. WFI sleep/clock-gate transitions, and transparent control channel timing budgets fail verification:

1. **Interrupt Controller Wake-Up Masking, Registered Security Qualification, and Idle ID (`code/cv32e40p_int_controller.sv`):**
   - Mask external interrupt wake-up qualification with `IRQ_MASK` so reserved interrupt bits outside `IRQ_MASK` never assert `irq_wu_ctrl_o`.
   - When `PULP_SECURE = 1` and `current_priv_lvl_i == PRIV_LVL_U`, qualify `irq_req_ctrl_o` using the registered security level (`irq_sec_ctrl_o` / registered `irq_sec_i`) aligned with the registered interrupt lines in `mip_o` rather than unregistered `irq_sec_i`.
   - When no locally enabled interrupt is active (`(mip_o & mie_bypass_i) == 32'h0`), drive `irq_id_ctrl_o = 5'd0` instead of `CSR_MTIX_BIT`.

2. **Runtime Dual-Mode Sleep Unit (`cluster_mode_i`) and `p.elw` / WFI Clock Gating (`code/cv32e40p_sleep_unit.sv`):**
   - Select between PULP cluster sleep mode (`cluster_mode_i == 1'b1`) and standard WFI sleep mode (`cluster_mode_i == 1'b0`) dynamically at runtime via `cluster_mode_i` (regardless of the `COREV_CLUSTER` parameter default).
   - In cluster mode (`cluster_mode_i == 1'b1`), track an active `p.elw` transaction: `p_elw_finish_i`, `debug_p_elw_no_sleep_i`, or `cluster_mode_i == 1'b0` must clear any active `p.elw` sleep state (with `p_elw_finish_i` and `debug_p_elw_no_sleep_i` taking priority over `p_elw_start_i` if asserted in the same cycle). While a `p.elw` transaction is active, any busy unit (`if_busy_i`, `lsu_busy_i`, or `apu_busy_i`) keeps the registered core busy state active for the following cycle; when no `p.elw` transaction is active in cluster mode, the registered core busy state remains `1'b1`. Enable `clk_gated_o` whenever `fetch_enable_o` is high and any of `pulp_clock_en_i`, `wake_from_sleep_i`, `debug_p_elw_no_sleep_i`, or the registered core busy state is high; assert `core_sleep_o` only when `fetch_enable_o` is high, the `p.elw` transaction state is active, the registered core busy state is low, `debug_p_elw_no_sleep_i` is low, and `wake_from_sleep_i` is low.
   - In standard WFI mode (`cluster_mode_i == 1'b0`), the registered core busy state reflects `if_busy_i || ctrl_busy_i || lsu_busy_i || apu_busy_i`; enable `clk_gated_o` when `fetch_enable_o` is high and any of `wake_from_sleep_i`, `debug_p_elw_no_sleep_i`, or the registered core busy state is high; and assert `core_sleep_o` when `fetch_enable_o` is high and the gated clock enable is low.

3. **Transparent Channel Timing Budgets (`constraints.json`):**
   - In `code/top.sv`, the subsystem operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `3.50 ns` external input delay on all non-clock inputs and a `2.75 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`clint_timer_in` to `clint_timer_out` and `eu_event_in` to `eu_event_out`). Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.25 ns` for `clint_timer_in` to `clint_timer_out` and `2.00 ns` for `eu_event_in` to `eu_event_out`, while preserving the existing sequential timing requirements on all registered interrupt controller and sleep unit ports. Edit only `code/cv32e40p_int_controller.sv`, `code/cv32e40p_sleep_unit.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Guide

## Editable Files
- `code/cv32e40p_int_controller.sv`
- `code/cv32e40p_sleep_unit.sv`
- `constraints.json`

Do not modify `code/top.sv`, `code/cv32e40p_sim_clock_gate.sv`, `code/include/cv32e40p_pkg.sv`, or `code/LICENSE`.

## Simulation & Synthesis Toolchain
- **Verilator (`verilator-v5.038`)**:
  ```bash
  verilator --binary --timing -Wno-fatal --top-module top \
    code/include/cv32e40p_pkg.sv code/cv32e40p_sim_clock_gate.sv \
    code/cv32e40p_int_controller.sv code/cv32e40p_sleep_unit.sv code/top.sv
  ```
- **Yosys + Slang (`oss-cad-suite/bin/yosys`)**:
  ```bash
  yosys -m slang -Q -p "read_slang --top top --keep-hierarchy code/include/cv32e40p_pkg.sv code/cv32e40p_sim_clock_gate.sv code/cv32e40p_int_controller.sv code/cv32e40p_sleep_unit.sv code/top.sv; hierarchy -check -top top; proc; opt_clean; select -assert-none cv32e40p_int_controller*/t:\$dlatch* cv32e40p_int_controller*/t:\$adlatch* cv32e40p_int_controller*/t:\$latch* cv32e40p_int_controller*/t:\$sr* cv32e40p_sleep_unit*/t:\$dlatch* cv32e40p_sleep_unit*/t:\$adlatch* cv32e40p_sleep_unit*/t:\$latch* cv32e40p_sleep_unit*/t:\$sr*; synth -top top; read_liberty -lib /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; dfflibmap -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; abc -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; clean; check -assert; write_verilog -noattr mapped.v"
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
set_input_delay 3.50 -clock clk_i [get_ports {<all_non_clock_inputs>}]
set_output_delay 2.75 -clock clk_i [get_ports {<all_outputs>}]
```
in OpenROAD (`openroad -exit`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cv32e40p_int_controller.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e40p_int_controller.sv (Golden Reference)
@@ -1,25 +1,5 @@
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
-// Engineer:       Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
-//                                                                            //
-// Additional contributions by:                                               //
-//                                                                            //
-// Design Name:    Interrupt Controller                                       //
-// Project Name:   RI5CY                                                      //
-// Language:       SystemVerilog                                              //
-//                                                                            //
-// Description:    Interrupt Controller of the pipelined processor            //
-//                                                                            //
-////////////////////////////////////////////////////////////////////////////////
+// Solderpad Hardware License, Version 0.51
 
 module cv32e40p_int_controller
   import cv32e40p_pkg::*;
@@ -29,32 +9,25 @@
     input logic clk,
     input logic rst_n,
 
-    // External interrupt lines
-    input logic [31:0] irq_i,  // Level-triggered interrupt inputs
-    input logic        irq_sec_i,  // Interrupt secure bit from EU
+    input logic [31:0] irq_i,
+    input logic        irq_sec_i,
 
-    // To cv32e40p_controller
     output logic       irq_req_ctrl_o,
     output logic       irq_sec_ctrl_o,
     output logic [4:0] irq_id_ctrl_o,
     output logic       irq_wu_ctrl_o,
 
-    // To/from cv32e40p_cs_registers
-    input  logic     [31:0] mie_bypass_i,  // MIE CSR (bypass)
-    output logic     [31:0] mip_o,  // MIP CSR
-    input  logic            m_ie_i,  // Interrupt enable bit from CSR (M mode)
-    input  logic            u_ie_i,  // Interrupt enable bit from CSR (U mode)
-    input  PrivLvl_t        current_priv_lvl_i
+    input  logic [31:0] mie_bypass_i,
+    output logic [31:0] mip_o,
+    input  logic        m_ie_i,
+    input  logic        u_ie_i,
+    input  PrivLvl_t    current_priv_lvl_i
 );
 
   logic        global_irq_enable;
   logic [31:0] irq_local_qual;
   logic [31:0] irq_q;
   logic        irq_sec_q;
-
-  // Register all interrupt inputs (on gated clock). The wake-up logic will
-  // observe irq_i as well, but in all other places irq_q will be used to 
-  // avoid timing paths from irq_i to instr_*_o
 
   always_ff @(posedge clk, negedge rst_n) begin
     if (rst_n == 1'b0) begin
@@ -66,87 +39,57 @@
     end
   end
 
-  // MIP CSR
-  assign mip_o = irq_q;
+  assign mip_o          = irq_q;
+  assign irq_local_qual = irq_q & mie_bypass_i;
+  assign irq_wu_ctrl_o  = |(irq_i & mie_bypass_i & IRQ_MASK);
 
-  // Qualify registered IRQ with MIE CSR to compute locally enabled IRQs
-  assign irq_local_qual = irq_q & mie_bypass_i;
-
-  // Wake-up signal based on unregistered IRQ such that wake-up can be caused if no clock is present
-  assign irq_wu_ctrl_o = |(irq_i & mie_bypass_i);
-
-  // Global interrupt enable
   generate
     if (PULP_SECURE) begin : gen_pulp_secure
-      assign global_irq_enable = ((u_ie_i || irq_sec_i) && current_priv_lvl_i == PRIV_LVL_U) || (m_ie_i && current_priv_lvl_i == PRIV_LVL_M);
+      assign global_irq_enable = ((u_ie_i || irq_sec_q) && (current_priv_lvl_i == PRIV_LVL_U)) ||
+                                 (m_ie_i && (current_priv_lvl_i == PRIV_LVL_M));
     end else begin : gen_no_pulp_secure
       assign global_irq_enable = m_ie_i;
     end
   endgenerate
 
-  // Request to take interrupt if there is a locally enabled interrupt while interrupts are also enabled globally
   assign irq_req_ctrl_o = (|irq_local_qual) && global_irq_enable;
 
-  // Interrupt Encoder
-  //
-  // - sets correct id to request to ID
-  // - encodes priority order
-
   always_comb begin
-    if (irq_local_qual[31]) irq_id_ctrl_o = 5'd31;  // Custom irq_i[31]
-    else if (irq_local_qual[30]) irq_id_ctrl_o = 5'd30;  // Custom irq_i[30]
-    else if (irq_local_qual[29]) irq_id_ctrl_o = 5'd29;  // Custom irq_i[29]
-    else if (irq_local_qual[28]) irq_id_ctrl_o = 5'd28;  // Custom irq_i[28]
-    else if (irq_local_qual[27]) irq_id_ctrl_o = 5'd27;  // Custom irq_i[27]
-    else if (irq_local_qual[26]) irq_id_ctrl_o = 5'd26;  // Custom irq_i[26]
-    else if (irq_local_qual[25]) irq_id_ctrl_o = 5'd25;  // Custom irq_i[25]
-    else if (irq_local_qual[24]) irq_id_ctrl_o = 5'd24;  // Custom irq_i[24]
-    else if (irq_local_qual[23]) irq_id_ctrl_o = 5'd23;  // Custom irq_i[23]
-    else if (irq_local_qual[22]) irq_id_ctrl_o = 5'd22;  // Custom irq_i[22]
-    else if (irq_local_qual[21]) irq_id_ctrl_o = 5'd21;  // Custom irq_i[21]
-    else if (irq_local_qual[20]) irq_id_ctrl_o = 5'd20;  // Custom irq_i[20]
-    else if (irq_local_qual[19]) irq_id_ctrl_o = 5'd19;  // Custom irq_i[19]
-    else if (irq_local_qual[18]) irq_id_ctrl_o = 5'd18;  // Custom irq_i[18]
-    else if (irq_local_qual[17]) irq_id_ctrl_o = 5'd17;  // Custom irq_i[17]
-    else if (irq_local_qual[16]) irq_id_ctrl_o = 5'd16;  // Custom irq_i[16]
-
-    else if (irq_local_qual[15])
-      irq_id_ctrl_o = 5'd15;  // Reserved  (default masked out with IRQ_MASK)
-    else if (irq_local_qual[14])
-      irq_id_ctrl_o = 5'd14;  // Reserved  (default masked out with IRQ_MASK)
-    else if (irq_local_qual[13])
-      irq_id_ctrl_o = 5'd13;  // Reserved  (default masked out with IRQ_MASK)
-    else if (irq_local_qual[12])
-      irq_id_ctrl_o = 5'd12;  // Reserved  (default masked out with IRQ_MASK)
-
-    else if (irq_local_qual[CSR_MEIX_BIT]) irq_id_ctrl_o = CSR_MEIX_BIT;  // MEI, irq_i[11]
-    else if (irq_local_qual[CSR_MSIX_BIT]) irq_id_ctrl_o = CSR_MSIX_BIT;  // MSI, irq_i[3]
-    else if (irq_local_qual[CSR_MTIX_BIT]) irq_id_ctrl_o = CSR_MTIX_BIT;  // MTI, irq_i[7]
-
-    else if (irq_local_qual[10])
-      irq_id_ctrl_o = 5'd10;                         // Reserved (for now assuming EI, SI, TI priority) (default masked out with IRQ_MASK)
-    else if (irq_local_qual[2])
-      irq_id_ctrl_o = 5'd2;                          // Reserved (for now assuming EI, SI, TI priority) (default masked out with IRQ_MASK)
-    else if (irq_local_qual[6])
-      irq_id_ctrl_o = 5'd6;                          // Reserved (for now assuming EI, SI, TI priority) (default masked out with IRQ_MASK)
-
-    else if (irq_local_qual[9])
-      irq_id_ctrl_o = 5'd9;  // Reserved: SEI (default masked out with IRQ_MASK)
-    else if (irq_local_qual[1])
-      irq_id_ctrl_o = 5'd1;  // Reserved: SSI (default masked out with IRQ_MASK)
-    else if (irq_local_qual[5])
-      irq_id_ctrl_o = 5'd5;  // Reserved: STI (default masked out with IRQ_MASK)
-
-    else if (irq_local_qual[8])
-      irq_id_ctrl_o = 5'd8;  // Reserved: UEI (default masked out with IRQ_MASK)
-    else if (irq_local_qual[0])
-      irq_id_ctrl_o = 5'd0;  // Reserved: USI (default masked out with IRQ_MASK)
-    else if (irq_local_qual[4])
-      irq_id_ctrl_o = 5'd4;  // Reserved: UTI (default masked out with IRQ_MASK)
-
-    else irq_id_ctrl_o = CSR_MTIX_BIT;  // Value not relevant
+    if (irq_local_qual[31]) irq_id_ctrl_o = 5'd31;
+    else if (irq_local_qual[30]) irq_id_ctrl_o = 5'd30;
+    else if (irq_local_qual[29]) irq_id_ctrl_o = 5'd29;
+    else if (irq_local_qual[28]) irq_id_ctrl_o = 5'd28;
+    else if (irq_local_qual[27]) irq_id_ctrl_o = 5'd27;
+    else if (irq_local_qual[26]) irq_id_ctrl_o = 5'd26;
+    else if (irq_local_qual[25]) irq_id_ctrl_o = 5'd25;
+    else if (irq_local_qual[24]) irq_id_ctrl_o = 5'd24;
+    else if (irq_local_qual[23]) irq_id_ctrl_o = 5'd23;
+    else if (irq_local_qual[22]) irq_id_ctrl_o = 5'd22;
+    else if (irq_local_qual[21]) irq_id_ctrl_o = 5'd21;
+    else if (irq_local_qual[20]) irq_id_ctrl_o = 5'd20;
+    else if (irq_local_qual[19]) irq_id_ctrl_o = 5'd19;
+    else if (irq_local_qual[18]) irq_id_ctrl_o = 5'd18;
+    else if (irq_local_qual[17]) irq_id_ctrl_o = 5'd17;
+    else if (irq_local_qual[16]) irq_id_ctrl_o = 5'd16;
+    else if (irq_local_qual[15]) irq_id_ctrl_o = 5'd15;
+    else if (irq_local_qual[14]) irq_id_ctrl_o = 5'd14;
+    else if (irq_local_qual[13]) irq_id_ctrl_o = 5'd13;
+    else if (irq_local_qual[12]) irq_id_ctrl_o = 5'd12;
+    else if (irq_local_qual[CSR_MEIX_BIT]) irq_id_ctrl_o = CSR_MEIX_BIT;
+    else if (irq_local_qual[CSR_MSIX_BIT]) irq_id_ctrl_o = CSR_MSIX_BIT;
+    else if (irq_local_qual[CSR_MTIX_BIT]) irq_id_ctrl_o = CSR_MTIX_BIT;
+    else if (irq_local_qual[10]) irq_id_ctrl_o = 5'd10;
+    else if (irq_local_qual[2]) irq_id_ctrl_o = 5'd2;
+    else if (irq_local_qual[6]) irq_id_ctrl_o = 5'd6;
+    else if (irq_local_qual[9]) irq_id_ctrl_o = 5'd9;
+    else if (irq_local_qual[1]) irq_id_ctrl_o = 5'd1;
+    else if (irq_local_qual[5]) irq_id_ctrl_o = 5'd5;
+    else if (irq_local_qual[8]) irq_id_ctrl_o = 5'd8;
+    else if (irq_local_qual[0]) irq_id_ctrl_o = 5'd0;
+    else if (irq_local_qual[4]) irq_id_ctrl_o = 5'd4;
+    else irq_id_ctrl_o = 5'd0;
   end
 
   assign irq_sec_ctrl_o = irq_sec_q;
 
-endmodule  // cv32e40p_int_controller
+endmodule

--- a/environment/public/code/cv32e40p_sleep_unit.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e40p_sleep_unit.sv (Golden Reference)
@@ -30,29 +30,34 @@
 
   import cv32e40p_pkg::*;
 
-  logic fetch_enable_q;
-  logic fetch_enable_d;
-  logic core_busy_q;
-  logic core_busy_d;
-  logic p_elw_busy_q;
-  logic p_elw_busy_d;
+  logic fetch_enable_q, fetch_enable_d;
+  logic core_busy_q, core_busy_d;
+  logic p_elw_busy_q, p_elw_busy_d;
   logic clock_en;
 
   assign fetch_enable_d = fetch_enable_i ? 1'b1 : fetch_enable_q;
 
-  generate
-    if (COREV_CLUSTER) begin : g_pulp_sleep
-      assign core_busy_d  = p_elw_busy_d ? (if_busy_i || apu_busy_i) : 1'b1;
-      assign clock_en     = fetch_enable_q && (pulp_clock_en_i || core_busy_q);
-      assign core_sleep_o = p_elw_busy_d && !core_busy_q && !debug_p_elw_no_sleep_i;
-      assign p_elw_busy_d = p_elw_start_i ? 1'b1 : (p_elw_finish_i ? 1'b0 : p_elw_busy_q);
-    end else begin : g_no_pulp_sleep
-      assign core_busy_d  = if_busy_i || ctrl_busy_i || lsu_busy_i || apu_busy_i;
-      assign clock_en     = fetch_enable_q && (wake_from_sleep_i || core_busy_q);
-      assign core_sleep_o = fetch_enable_q && !clock_en;
-      assign p_elw_busy_d = 1'b0;
+  always_comb begin
+    if (!cluster_mode_i || debug_p_elw_no_sleep_i) begin
+      p_elw_busy_d = 1'b0;
+    end else if (p_elw_finish_i) begin
+      p_elw_busy_d = 1'b0;
+    end else if (p_elw_start_i) begin
+      p_elw_busy_d = 1'b1;
+    end else begin
+      p_elw_busy_d = p_elw_busy_q;
     end
-  endgenerate
+
+    if (cluster_mode_i) begin
+      core_busy_d  = p_elw_busy_d ? (if_busy_i || lsu_busy_i || apu_busy_i) : 1'b1;
+      clock_en     = fetch_enable_q && (pulp_clock_en_i || wake_from_sleep_i || debug_p_elw_no_sleep_i || core_busy_q);
+      core_sleep_o = fetch_enable_q && p_elw_busy_d && !core_busy_q && !debug_p_elw_no_sleep_i && !wake_from_sleep_i;
+    end else begin
+      core_busy_d  = if_busy_i || ctrl_busy_i || lsu_busy_i || apu_busy_i;
+      clock_en     = fetch_enable_q && (wake_from_sleep_i || debug_p_elw_no_sleep_i || core_busy_q);
+      core_sleep_o = fetch_enable_q && !clock_en;
+    end
+  end
 
   always_ff @(posedge clk_ungated_i, negedge rst_n) begin
     if (rst_n == 1'b0) begin

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,22 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": [
+        "clint_timer_in"
+      ],
+      "to": [
+        "clint_timer_out"
+      ],
+      "ns": 7.5
+    },
+    {
+      "from": [
+        "eu_event_in"
+      ],
+      "to": [
+        "eu_event_out"
+      ],
+      "ns": 8.25
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
- [`environment/public/code/cv32e40p_int_controller.sv`](environment/public/code/cv32e40p_int_controller.sv) **(Editable)**
- [`environment/public/code/cv32e40p_sim_clock_gate.sv`](environment/public/code/cv32e40p_sim_clock_gate.sv) *(Read-Only Context)*
- [`environment/public/code/cv32e40p_sleep_unit.sv`](environment/public/code/cv32e40p_sleep_unit.sv) **(Editable)**
- [`environment/public/code/include/cv32e40p_pkg.sv`](environment/public/code/include/cv32e40p_pkg.sv) *(Read-Only Context)*
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

