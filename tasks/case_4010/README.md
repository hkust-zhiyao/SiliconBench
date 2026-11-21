# `case_4010`: CV32E41P Control and Sleep Subsystem: Sticky Fetch-Enable/ELW Sleep Gating, Secure Interrupt Qualification, Nested Hardware-Loop Priority, and Area/Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_4010` |
| **Source Silicon Repository** | `openhwfoundation/cv32e41p` (`repo_04`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `low_power` (Low-Power Clock Gating, Sleep State Retention, Isolation & Wakeup Sequencing) |
| **Multi-Domain Tags** | `clocking`, `low_power`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/cv32e41p_sleep_unit.sv`](environment/public/code/cv32e41p_sleep_unit.sv), [`code/cv32e41p_int_controller.sv`](environment/public/code/cv32e41p_int_controller.sv), [`code/cv32e41p_hwloop_regs.sv`](environment/public/code/cv32e41p_hwloop_regs.sv), [`code/cv32e41p_controller.sv`](environment/public/code/cv32e41p_controller.sv) (4 files, 1932 LOC) |
| **Public Subsystem Context** | 6 RTL files (3080 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# CV32E41P Control and Sleep Subsystem: Sticky Fetch-Enable/ELW Sleep Gating, Secure Interrupt Qualification, Nested Hardware-Loop Priority, and Area/Timing Closure

In the CV32E41P control and sleep subsystem (`code/cv32e41p_ctrl_subsystem.sv`, integrating `code/cv32e41p_sleep_unit.sv`, `code/cv32e41p_int_controller.sv`, `code/cv32e41p_hwloop_regs.sv`, and `code/cv32e41p_controller.sv` with `PULP_CLUSTER = 1`, `PULP_XPULP = 1`, `PULP_SECURE = 1`, and `N_HWLP = 2`), verification and synthesis sign-off fail in the following scenarios:

1. **Sticky fetch-enable latching, PULP cluster `p.elw` sleep gating, and debug sleep suppression (`code/cv32e41p_sleep_unit.sv`)**:
   - Once `fetch_enable_i` pulses high for one or more cycles after reset, `fetch_enable_o` must remain sticky high (`1'b1`) until reset even after `fetch_enable_i` deasserts.
   - When `PULP_CLUSTER = 1`, `p_elw_busy` must assert immediately when `p_elw_start_i` is high (taking precedence over `p_elw_finish_i` if both pulse) and clear when `p_elw_finish_i` is high; `core_busy_d` must evaluate `p_elw_busy_d ? (if_busy_i || apu_busy_i) : 1'b1`; and `core_sleep_o` must assert only when `p_elw_busy_d && !core_busy_q && !debug_p_elw_no_sleep_i`. When `PULP_CLUSTER = 0`, `clock_en` must assert when `fetch_enable_o && (wake_from_sleep_i || core_busy_q)`.
2. **Interrupt wakeup masking, U-mode secure interrupt alignment, and idle encoding (`code/cv32e41p_int_controller.sv`)**:
   - Only architectural interrupt lines permitted by `IRQ_MASK` (`[31:16]`, `11`, `7`, `3`) may assert `irq_wu_ctrl_o` (and `wake_from_sleep_o`) when enabled by `mie_bypass_i`; activity on reserved/masked-out bits (`[15:12]`, `[10:8]`, `[6:4]`, `[2:0]`) must never trigger a wakeup even if the corresponding bits in `mie_bypass_i` are high.
   - When `PULP_SECURE = 1` and `current_priv_lvl_i == PRIV_LVL_U` with `u_ie_i == 1'b0`, taking a secure interrupt (`irq_req_ctrl_o`) must be qualified by the registered security indicator (`irq_sec_ctrl_o`) aligned with the registered pending vector (`mip_o`).
   - When no locally enabled interrupt bit (`mip_o & mie_bypass_i`) is active, `irq_id_ctrl_o` must output `5'd0` while preserving the CV32E41P priority order (`31` down to `16`, then `11`, `3`, `7`) when active.
3. **Hardware-loop counter saturation, nested two-loop boundary priority, and PMP data-error fault retention (`code/cv32e41p_hwloop_regs.sv` and `code/cv32e41p_controller.sv`)**:
   - In `cv32e41p_hwloop_regs`, asserting `hwlp_dec_cnt_i[i]` with `valid_i` when loop `i`'s counter is already `32'd0` must hold the counter at `32'd0` rather than underflowing to `32'hFFFF_FFFF`.
   - In `cv32e41p_controller`, Loop 0 has higher priority than Loop 1 when both loops are active (`hwlp_counter_o > 1`):
     - In `DECODE` and `FLUSH_WB` (`csr_status_i`), when `pc_id_i` matches both `hwlp_end_addr_o[0]` and `hwlp_end_addr_o[1]` with both counters `> 1`, Loop 0 takes precedence so only `hwlp_dec_cnt_o[0]` asserts (`hwlp_dec_cnt_o == 2'b01`). In `DECODE_HWLOOP`, `hwlp_dec_cnt_o[i]` must assert at `pc_id_i == hwlp_end_addr_o[i]` only when `hwlp_counter_o[i] != 32'd0`, and `hwlp_dec_cnt_o[1]` must be suppressed whenever Loop 0 is actively looping back at the same address (`pc_id_i == hwlp_end_addr_o[0]` and `hwlp_counter_o[0] > 1`).
     - In `DECODE`, staying in `DECODE` when `pc_id_i + 4` matches a loop end address must only apply to loops with `hwlp_counter_o > 1`. In `DECODE_HWLOOP`, when `pc_id_i + 4` reaches a loop end address, `hwlp_jump_o` must pulse and `hwlp_targ_addr_o` must drive `hwlp_start_addr_o[0]` if Loop 0 triggers (`pc_id_i + 4 == hwlp_end_addr_o[0]` and `hwlp_counter_o[0] > 1`), or `hwlp_start_addr_o[1]` if Loop 0 does not trigger and Loop 1 triggers (`pc_id_i + 4 == hwlp_end_addr_o[1]` and `hwlp_counter_o[1] > 1`).
   - When `data_err_i` asserts in `DECODE`, `FLUSH_EX`, or `DBG_FLUSH`, the controller must latch `data_we_ex_i` when `data_err_ack_o` asserts, and on the subsequent `FLUSH_WB` cycle drive `exc_cause_o = EXC_CAUSE_STORE_FAULT` (for a faulted store) or `EXC_CAUSE_LOAD_FAULT` (for a faulted load) and `exc_pc_mux_o = debug_mode_o ? EXC_PC_DBE : EXC_PC_EXCEPTION`.

Under the Nangate45 synthesis and OpenROAD STA flow in `BUILD.md`, `cv32e41p_int_controller` (`PULP_SECURE = 1`) must synthesize latch-free with mapped cell area `<= 181.5 um^2`, `cv32e41p_ctrl_subsystem` (`PULP_CLUSTER = 1, PULP_XPULP = 1, PULP_SECURE = 1, N_HWLP = 2`) must synthesize latch-free with mapped cell area `<= 3,290.0 um^2`, and `cv32e41p_ctrl_subsystem` must achieve `WNS >= 0.00 ns` and `WHS >= 0.00 ns` at a `1.95 ns` clock period (`0.15 ns` I/O delays, `5.0 fF` output load, false path from `rst_n`). Edit only `code/cv32e41p_sleep_unit.sv`, `code/cv32e41p_int_controller.sv`, `code/cv32e41p_hwloop_regs.sv`, and `code/cv32e41p_controller.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Instructions

## 1. Editable Files
Only the following four files are collected and graded:
- `code/cv32e41p_sleep_unit.sv`
- `code/cv32e41p_int_controller.sv`
- `code/cv32e41p_hwloop_regs.sv`
- `code/cv32e41p_controller.sv`

All other files in `code/` (`cv32e41p_pkg.sv`, `cv32e41p_ctrl_subsystem.sv`, `LICENSE`) and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and run your own testbench against `cv32e41p_ctrl_subsystem` (`PULP_CLUSTER = 1`, `PULP_XPULP = 1`, `PULP_SECURE = 1`, `N_HWLP = 2`) using Verilator:

```bash
verilator \
  --binary --timing -j 1 -Wno-fatal \
  --top-module <your_tb_top> \
  code/cv32e41p_pkg.sv \
  code/cv32e41p_sleep_unit.sv \
  code/cv32e41p_int_controller.sv \
  code/cv32e41p_hwloop_regs.sv \
  code/cv32e41p_controller.sv \
  code/cv32e41p_ctrl_subsystem.sv \
  <your_tb.sv>

./obj_dir/V<your_tb_top>
```

## 3. Logic Synthesis & Area Checks (`Yosys + Slang`)
1. Synthesize `cv32e41p_int_controller` (`PULP_SECURE = 1`) to Nangate45 and verify zero latches and mapped cell area `<= 181.5 um^2`:

```bash
yosys -m slang -p "
  read_slang --ignore-assertions --top cv32e41p_int_controller -G PULP_SECURE=1 \
    code/cv32e41p_pkg.sv \
    code/cv32e41p_int_controller.sv
  hierarchy -check -top cv32e41p_int_controller
  proc; opt_clean
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*
  synth -top cv32e41p_int_controller -flatten
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
"
```

2. Synthesize `cv32e41p_ctrl_subsystem` (default parameters `PULP_CLUSTER = 1, PULP_XPULP = 1, PULP_SECURE = 1, N_HWLP = 2`) to Nangate45 and verify zero latches and mapped cell area `<= 3,290.0 um^2`:

```bash
yosys -m slang -p "
  read_slang --ignore-assertions --top cv32e41p_ctrl_subsystem \
    code/cv32e41p_pkg.sv \
    code/cv32e41p_sleep_unit.sv \
    code/cv32e41p_int_controller.sv \
    code/cv32e41p_hwloop_regs.sv \
    code/cv32e41p_controller.sv \
    code/cv32e41p_ctrl_subsystem.sv
  hierarchy -check -top cv32e41p_ctrl_subsystem
  proc; opt_clean
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*
  synth -top cv32e41p_ctrl_subsystem -flatten
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```

## 4. Static Timing Analysis (`OpenROAD`)
Verify setup slack (`WNS >= 0.00 ns`) and hold slack (`WHS >= 0.00 ns`) on `cv32e41p_ctrl_subsystem` at a `1.95 ns` clock period:

```bash
sed 's/ signed / /g' mapped.v > sta.v
cat > sta.tcl << 'EOF'
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design cv32e41p_ctrl_subsystem
create_clock -name clk -period 1.95 [get_ports {clk clk_ungated_i}]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_n]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
EOF
openroad -exit sta.tcl
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cv32e41p_sleep_unit.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e41p_sleep_unit.sv (Golden Reference)
@@ -4,32 +4,26 @@
 module cv32e41p_sleep_unit #(
     parameter PULP_CLUSTER = 0
 ) (
-    // Clock, reset interface
     input  logic clk_ungated_i,
     input  logic rst_n,
     output logic clk_gated_o,
     input  logic scan_cg_en_i,
 
-    // Core sleep
     output logic core_sleep_o,
 
-    // Fetch enable
     input  logic fetch_enable_i,
     output logic fetch_enable_o,
 
-    // Core status
     input  logic if_busy_i,
     input  logic ctrl_busy_i,
     input  logic lsu_busy_i,
     input  logic apu_busy_i,
 
-    // PULP Cluster interface
     input  logic pulp_clock_en_i,
     input  logic p_elw_start_i,
     input  logic p_elw_finish_i,
     input  logic debug_p_elw_no_sleep_i,
 
-    // WFI wake
     input  logic wake_from_sleep_i
 );
 
@@ -40,17 +34,17 @@
   logic p_elw_busy_q, p_elw_busy_d;
   logic clock_en;
 
-  assign fetch_enable_d = fetch_enable_i;
+  assign fetch_enable_d = fetch_enable_i ? 1'b1 : fetch_enable_q;
 
   generate
     if (PULP_CLUSTER) begin : g_pulp_sleep
-      assign core_busy_d  = p_elw_busy_q ? (if_busy_i || apu_busy_i) : 1'b1;
+      assign p_elw_busy_d = p_elw_start_i ? 1'b1 : (p_elw_finish_i ? 1'b0 : p_elw_busy_q);
+      assign core_busy_d  = p_elw_busy_d ? (if_busy_i || apu_busy_i) : 1'b1;
       assign clock_en     = fetch_enable_q && (pulp_clock_en_i || core_busy_q);
-      assign core_sleep_o = p_elw_busy_d && !core_busy_q;
-      assign p_elw_busy_d = p_elw_finish_i ? 1'b0 : (p_elw_start_i ? 1'b1 : p_elw_busy_q);
+      assign core_sleep_o = p_elw_busy_d && !core_busy_q && !debug_p_elw_no_sleep_i;
     end else begin : g_no_pulp_sleep
       assign core_busy_d  = if_busy_i || ctrl_busy_i || lsu_busy_i || apu_busy_i;
-      assign clock_en     = fetch_enable_q && core_busy_q;
+      assign clock_en     = fetch_enable_q && (wake_from_sleep_i || core_busy_q);
       assign core_sleep_o = fetch_enable_q && !clock_en;
       assign p_elw_busy_d = 1'b0;
     end

--- a/environment/public/code/cv32e41p_int_controller.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e41p_int_controller.sv (Golden Reference)
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
 
 module cv32e41p_int_controller
   import cv32e41p_pkg::*;
@@ -30,8 +10,8 @@
     input logic rst_n,
 
     // External interrupt lines
-    input logic [31:0] irq_i,     // Level-triggered interrupt inputs
-    input logic        irq_sec_i, // Interrupt secure bit from EU
+    input logic [31:0] irq_i,
+    input logic        irq_sec_i,
 
     // To cv32e41p_controller
     output logic       irq_req_ctrl_o,
@@ -40,10 +20,10 @@
     output logic       irq_wu_ctrl_o,
 
     // To/from cv32e41p_cs_registers
-    input  logic     [31:0] mie_bypass_i,       // MIE CSR (bypass)
-    output logic     [31:0] mip_o,              // MIP CSR
-    input  logic            m_ie_i,             // Interrupt enable bit from CSR (M mode)
-    input  logic            u_ie_i,             // Interrupt enable bit from CSR (U mode)
+    input  logic     [31:0] mie_bypass_i,
+    output logic     [31:0] mip_o,
+    input  logic            m_ie_i,
+    input  logic            u_ie_i,
     input  PrivLvl_t        current_priv_lvl_i
 );
 
@@ -51,10 +31,6 @@
   logic [31:0] irq_local_qual;
   logic [31:0] irq_q;
   logic        irq_sec_q;
-
-  // Register all interrupt inputs (on gated clock). The wake-up logic will
-  // observe irq_i as well, but in all other places irq_q will be used to 
-  // avoid timing paths from irq_i to instr_*_o
 
   always_ff @(posedge clk, negedge rst_n) begin
     if (rst_n == 1'b0) begin
@@ -66,87 +42,59 @@
     end
   end
 
-  // MIP CSR
-  assign mip_o = irq_q;
-
-  // Qualify registered IRQ with MIE CSR to compute locally enabled IRQs
+  assign mip_o          = irq_q;
   assign irq_local_qual = irq_q & mie_bypass_i;
 
-  // Wake-up signal based on unregistered IRQ such that wake-up can be caused if no clock is present
-  assign irq_wu_ctrl_o = |(irq_i & mie_bypass_i);
+  // Mask wakeup with IRQ_MASK so reserved interrupt bits cannot spuriously wake the core
+  assign irq_wu_ctrl_o  = |(irq_i & mie_bypass_i & IRQ_MASK);
 
-  // Global interrupt enable
   generate
     if (PULP_SECURE) begin : gen_pulp_secure
-      assign global_irq_enable = ((u_ie_i || irq_sec_i) && current_priv_lvl_i == PRIV_LVL_U) || (m_ie_i && current_priv_lvl_i == PRIV_LVL_M);
+      assign global_irq_enable = ((u_ie_i || irq_sec_q) && current_priv_lvl_i == PRIV_LVL_U) ||
+                                 (m_ie_i && current_priv_lvl_i == PRIV_LVL_M);
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
+  // Tree-structured priority encoder matching CV32E41P priority order
+  logic       hi_any, hi_top8;
+  logic [4:0] hi_id, std_id;
+
+  assign hi_top8 = |irq_local_qual[31:24];
+  assign hi_any  = |irq_local_qual[31:16];
 
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
+    if (hi_top8) begin
+      if      (irq_local_qual[31]) hi_id = 5'd31;
+      else if (irq_local_qual[30]) hi_id = 5'd30;
+      else if (irq_local_qual[29]) hi_id = 5'd29;
+      else if (irq_local_qual[28]) hi_id = 5'd28;
+      else if (irq_local_qual[27]) hi_id = 5'd27;
+      else if (irq_local_qual[26]) hi_id = 5'd26;
+      else if (irq_local_qual[25]) hi_id = 5'd25;
+      else                         hi_id = 5'd24;
+    end else begin
+      if      (irq_local_qual[23]) hi_id = 5'd23;
+      else if (irq_local_qual[22]) hi_id = 5'd22;
+      else if (irq_local_qual[21]) hi_id = 5'd21;
+      else if (irq_local_qual[20]) hi_id = 5'd20;
+      else if (irq_local_qual[19]) hi_id = 5'd19;
+      else if (irq_local_qual[18]) hi_id = 5'd18;
+      else if (irq_local_qual[17]) hi_id = 5'd17;
+      else                         hi_id = 5'd16;
+    end
 
-    else if (irq_local_qual[15])
-      irq_id_ctrl_o = 5'd15;  // Reserved  (default masked out with IRQ_MASK)
-    else if (irq_local_qual[14])
-      irq_id_ctrl_o = 5'd14;  // Reserved  (default masked out with IRQ_MASK)
-    else if (irq_local_qual[13])
-      irq_id_ctrl_o = 5'd13;  // Reserved  (default masked out with IRQ_MASK)
-    else if (irq_local_qual[12])
-      irq_id_ctrl_o = 5'd12;  // Reserved  (default masked out with IRQ_MASK)
+    if      (irq_local_qual[CSR_MEIX_BIT]) std_id = CSR_MEIX_BIT[4:0];
+    else if (irq_local_qual[CSR_MSIX_BIT]) std_id = CSR_MSIX_BIT[4:0];
+    else if (irq_local_qual[CSR_MTIX_BIT]) std_id = CSR_MTIX_BIT[4:0];
+    else                                   std_id = 5'd0;
 
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
+    irq_id_ctrl_o = hi_any ? hi_id : std_id;
   end
 
   assign irq_sec_ctrl_o = irq_sec_q;
 
-endmodule  // cv32e41p_int_controller
+endmodule

--- a/environment/public/code/cv32e41p_hwloop_regs.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e41p_hwloop_regs.sv (Golden Reference)
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
 
 module cv32e41p_hwloop_regs #(
     parameter N_REGS     = 2,
@@ -34,7 +13,7 @@
     input logic [          31:0] hwlp_end_data_i,
     input logic [          31:0] hwlp_cnt_data_i,
     input logic [           2:0] hwlp_we_i,
-    input logic [N_REG_BITS-1:0] hwlp_regid_i,       // selects the register set
+    input logic [N_REG_BITS-1:0] hwlp_regid_i,
 
     // from controller
     input logic valid_i,
@@ -48,22 +27,16 @@
     output logic [N_REGS-1:0][31:0] hwlp_counter_o
 );
 
-
   logic [N_REGS-1:0][31:0] hwlp_start_q;
   logic [N_REGS-1:0][31:0] hwlp_end_q;
   logic [N_REGS-1:0][31:0] hwlp_counter_q, hwlp_counter_n;
 
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
@@ -72,10 +45,6 @@
     end
   end
 
-
-  /////////////////////////////////////////////////////////////////////////////////
-  // HWLOOP end-address register                                                 //
-  /////////////////////////////////////////////////////////////////////////////////
   always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_END
     if (rst_n == 1'b0) begin
       hwlp_end_q <= '{default: 32'b0};
@@ -84,13 +53,9 @@
     end
   end
 
-
-  /////////////////////////////////////////////////////////////////////////////////
-  // HWLOOP counter register with decrement logic                                //
-  /////////////////////////////////////////////////////////////////////////////////
   genvar k;
-  for (k = 0; k < N_REGS; k++) begin
-    assign hwlp_counter_n[k] = hwlp_counter_q[k] - 1;
+  for (k = 0; k < N_REGS; k++) begin : gen_cnt_dec
+    assign hwlp_counter_n[k] = hwlp_counter_q[k] - 32'd1;
   end
 
   always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_COUNTER
@@ -100,18 +65,11 @@
       for (i = 0; i < N_REGS; i++) begin
         if ((hwlp_we_i[2] == 1'b1) && (i == hwlp_regid_i)) begin
           hwlp_counter_q[i] <= hwlp_cnt_data_i;
-        end else begin
-          if (hwlp_dec_cnt_i[i] && valid_i) hwlp_counter_q[i] <= hwlp_counter_n[i];
+        end else if (hwlp_dec_cnt_i[i] && valid_i && (hwlp_counter_q[i] != 32'd0)) begin
+          hwlp_counter_q[i] <= hwlp_counter_n[i];
         end
       end
     end
   end
 
-  //----------------------------------------------------------------------------
-  // Assertions
-  //----------------------------------------------------------------------------
-`ifdef CV32E41P_ASSERT_ON
-  // do not decrement more than one counter at once
-  assert property (@(posedge clk) (valid_i) |-> ($countones(hwlp_dec_cnt_i) <= 1));
-`endif
 endmodule

--- a/environment/public/code/cv32e41p_controller.sv (Buggy Starter)
+++ b/solution/gold/code/cv32e41p_controller.sv (Golden Reference)
@@ -1,32 +1,5 @@
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
-// Engineer:       Matthias Baer - baermatt@student.ethz.ch                   //
-//                                                                            //
-// Additional contributions by:                                               //
-//                 Igor Loi - igor.loi@unibo.it                               //
-//                 Andreas Traber - atraber@student.ethz.ch                   //
-//                 Sven Stucki - svstucki@student.ethz.ch                     //
-//                 Michael Gautschi - gautschi@iis.ee.ethz.ch                 //
-//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
-//                 Robert Balas - balasr@iis.ee.ethz.ch                       //
-//                 Andrea Bettati - andrea.bettati@studenti.unipr.it          //
-//                                                                            //
-// Design Name:    Main controller                                            //
-// Project Name:   RI5CY                                                      //
-// Language:       SystemVerilog                                              //
-//                                                                            //
-// Description:    Main CPU controller of the processor                       //
-//                                                                            //
-////////////////////////////////////////////////////////////////////////////////
+// Solderpad Hardware License, Version 0.51
 
 module cv32e41p_controller import cv32e41p_pkg::*;
 #(
@@ -34,87 +7,70 @@
   parameter PULP_XPULP   = 1
 )
 (
-  input  logic        clk,                        // Gated clock
-  input  logic        clk_ungated_i,              // Ungated clock
+  input  logic        clk,
+  input  logic        clk_ungated_i,
   input  logic        rst_n,
 
-  input  logic        fetch_enable_i,             // Start the decoding
-  output logic        ctrl_busy_o,                // Core is busy processing instructions
-  output logic        is_decoding_o,              // Core is in decoding state
+  input  logic        fetch_enable_i,
+  output logic        ctrl_busy_o,
+  output logic        is_decoding_o,
   input  logic        is_fetch_failed_i,
 
-  // decoder related signals
-  output logic        deassert_we_o,              // deassert write enable for next instruction
-
-  input  logic        illegal_insn_i,             // decoder encountered an invalid instruction
-  input  logic        ecall_insn_i,               // decoder encountered an ecall instruction
-  input  logic        mret_insn_i,                // decoder encountered an mret instruction
-  input  logic        uret_insn_i,                // decoder encountered an uret instruction
-
-  input  logic        dret_insn_i,                // decoder encountered an dret instruction
+  output logic        deassert_we_o,
+
+  input  logic        illegal_insn_i,
+  input  logic        ecall_insn_i,
+  input  logic        mret_insn_i,
+  input  logic        uret_insn_i,
+  input  logic        dret_insn_i,
 
   input  logic        mret_dec_i,
   input  logic        uret_dec_i,
   input  logic        dret_dec_i,
 
-  input  logic        wfi_i,                      // decoder wants to execute a WFI
-  input  logic        ebrk_insn_i,                // decoder encountered an ebreak instruction
-  input  logic        fencei_insn_i,              // decoder encountered an fence.i instruction
-  input  logic        csr_status_i,               // decoder encountered an csr status instruction
-
-  output logic        hwlp_mask_o,                // prevent writes on the hwloop instructions in case interrupt are taken
-
-  // from IF/ID pipeline
-  input  logic        instr_valid_i,              // instruction coming from IF/ID pipeline is valid
-
-  // from prefetcher
-  output logic        instr_req_o,                // Start fetching instructions
-
-  // to prefetcher
-  output logic        pc_set_o,                   // jump to address set by pc_mux
-  output logic [3:0]  pc_mux_o,                   // Selector in the Fetch stage to select the rigth PC (normal, jump ...)
-  output logic [2:0]  exc_pc_mux_o,               // Selects target PC for exception
-  output logic [1:0]  trap_addr_mux_o,            // Selects trap address base
-
-  // HWLoop signls
+  input  logic        wfi_i,
+  input  logic        ebrk_insn_i,
+  input  logic        fencei_insn_i,
+  input  logic        csr_status_i,
+
+  output logic        hwlp_mask_o,
+  input  logic        instr_valid_i,
+  output logic        instr_req_o,
+
+  output logic        pc_set_o,
+  output logic [3:0]  pc_mux_o,
+  output logic [2:0]  exc_pc_mux_o,
+  output logic [1:0]  trap_addr_mux_o,
+
   input  logic [31:0]       pc_id_i,
   input  logic              is_compressed_i,
 
-  // from hwloop_regs
   input  logic [1:0] [31:0] hwlp_start_addr_i,
   input  logic [1:0] [31:0] hwlp_end_addr_i,
   input  logic [1:0] [31:0] hwlp_counter_i,
 
-  // to hwloop_regs
   output logic [1:0]        hwlp_dec_cnt_o,
-
   output logic              hwlp_jump_o,
   output logic [31:0]       hwlp_targ_addr_o,
 
-  // LSU
-  input  logic        data_req_ex_i,              // data memory access is currently performed in EX stage
+  input  logic        data_req_ex_i,
   input  logic        data_we_ex_i,
   input  logic        data_misaligned_i,
   input  logic        data_load_event_i,
   input  logic        data_err_i,
   output logic        data_err_ack_o,
 
-  // from ALU
-  input  logic        mult_multicycle_i,          // multiplier is taken multiple cycles and uses op c as storage
-
-  // APU dependency checks
+  input  logic        mult_multicycle_i,
+
   input  logic        apu_en_i,
   input  logic        apu_read_dep_i,
   input  logic        apu_write_dep_i,
-
   output logic        apu_stall_o,
 
-  // jump/branch signals
-  input  logic        branch_taken_ex_i,          // branch taken signal from EX ALU
-  input  logic [1:0]  ctrl_transfer_insn_in_id_i,               // jump is being calculated in ALU
-  input  logic [1:0]  ctrl_transfer_insn_in_dec_i,              // jump is being calculated in ALU
-
-  // Interrupt Controller Signals
+  input  logic        branch_taken_ex_i,
+  input  logic [1:0]  ctrl_transfer_insn_in_id_i,
+  input  logic [1:0]  ctrl_transfer_insn_in_dec_i,
+
   input  logic        irq_req_ctrl_i,
   input  logic        irq_sec_ctrl_i,
   input  logic [4:0]  irq_id_ctrl_i,
@@ -123,25 +79,22 @@
 
   output logic        irq_ack_o,
   output logic [4:0]  irq_id_o,
-
   output logic [4:0]  exc_cause_o,
 
-  // Debug Signal
-  output logic         debug_mode_o,
-  output logic [2:0]   debug_cause_o,
-  output logic         debug_csr_save_o,
-  input  logic         debug_req_i,
-  input  logic         debug_single_step_i,
-  input  logic         debug_ebreakm_i,
-  input  logic         debug_ebreaku_i,
-  input  logic         trigger_match_i,
-  output logic         debug_p_elw_no_sleep_o,
-  output logic         debug_wfi_no_sleep_o,
-  output logic         debug_havereset_o,
-  output logic         debug_running_o,
-  output logic         debug_halted_o,
-
-  // Wakeup Signal
+  output logic        debug_mode_o,
+  output logic [2:0]  debug_cause_o,
+  output logic        debug_csr_save_o,
+  input  logic        debug_req_i,
+  input  logic        debug_single_step_i,
+  input  logic        debug_ebreakm_i,
+  input  logic        debug_ebreaku_i,
+  input  logic        trigger_match_i,
+  output logic        debug_p_elw_no_sleep_o,
+  output logic   
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/cv32e41p_controller.sv`](environment/public/code/cv32e41p_controller.sv) **(Editable)**
- [`environment/public/code/cv32e41p_ctrl_subsystem.sv`](environment/public/code/cv32e41p_ctrl_subsystem.sv) *(Read-Only Context)*
- [`environment/public/code/cv32e41p_hwloop_regs.sv`](environment/public/code/cv32e41p_hwloop_regs.sv) **(Editable)**
- [`environment/public/code/cv32e41p_int_controller.sv`](environment/public/code/cv32e41p_int_controller.sv) **(Editable)**
- [`environment/public/code/cv32e41p_pkg.sv`](environment/public/code/cv32e41p_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv32e41p_sleep_unit.sv`](environment/public/code/cv32e41p_sleep_unit.sv) **(Editable)**
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

