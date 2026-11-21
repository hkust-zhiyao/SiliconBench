# `case_0011`: Reduce Area and Critical-Path Delay in the HWPE Chunked Stride Multiplier

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0011` |
| **Source Silicon Repository** | `pulp-platform/hwpe-ctrl` (`repo_33`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `arithmetic_datapath` (Fixed/Floating-Point Datapaths, Rounding, Saturation & Overflow) |
| **Multi-Domain Tags** | `arithmetic_datapath`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/hwpe_ctrl_partial_mult.sv`](environment/public/code/rtl/hwpe_ctrl_partial_mult.sv) (1 files, 109 LOC) |
| **Public Subsystem Context** | 3 RTL files (757 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# Reduce Area and Critical-Path Delay in the HWPE Chunked Stride Multiplier

The partially sequential stride multiplier (`code/rtl/hwpe_ctrl_partial_mult.sv`) uses excessive standard-cell area and critical-path delay on slice extraction and signed/negated accumulation. Reduce its mapped area and delay while preserving the exact completed product, optional two's-complement negation (`invert_i`), asynchronous reset (`rst_ni`), synchronous clear (`clear_i`), `ready_o`/`valid_o` handshake, and `AW_PAD / MULT_BITS` cycle latency (including back-to-back `start_i` on the `valid_o` completion cycle). `prod_o` is sampled when `valid_o` is high and must be zero after reset or clear; input operands remain stable across the operation interval.

For `AW=32`, `BW=32`, `MULT_BITS=4`, the supplied Nangate45 synthesis flow (`BUILD.md`) must map to at most `1,620.0 um^2`, and the supplied OpenROAD placement-estimated STA flow must achieve nonnegative setup and hold slack under a `3.1 ns` clock (`clk_i`) with `0.25 ns` input/output delays and `5.0 fF` output load. Preserve functional behavior across `(AW, BW, MULT_BITS)` of `(32, 32, 4)`, `(17, 11, 4)`, and `(24, 16, 4)` and closed-loop stride operation with `hwpe_ctrl_uloop`. Edit only `code/rtl/hwpe_ctrl_partial_mult.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/rtl/hwpe_ctrl_package.sv`: Upstream HWPE control package (read-only).
- `code/rtl/hwpe_ctrl_uloop.sv`: Upstream HWPE micro-loop offset processor (read-only).
- `code/rtl/hwpe_ctrl_partial_mult.sv`: Partially sequential stride multiplier (**editable target**).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.
  - Liberty units in `lib/NangateOpenCellLibrary_typical.lib`: `time_unit : "1ns"`, `capacitive_load_unit (1,ff)` (`1 fF`), area in `um^2`.

Edit only `code/rtl/hwpe_ctrl_partial_mult.sv`.

## 2. Functional Simulation (Verilator)

You can compile and simulate `hwpe_ctrl_partial_mult.sv` (and `hwpe_ctrl_uloop.sv`) with your own testbench using Verilator:

```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  code/rtl/hwpe_ctrl_package.sv \
  code/rtl/hwpe_ctrl_uloop.sv \
  code/rtl/hwpe_ctrl_partial_mult.sv \
  tb.sv
./obj_dir/Vtb
```

The evaluation checks `(AW=32, BW=32, MULT_BITS=4)`, `(AW=17, BW=11, MULT_BITS=4)`, and `(AW=24, BW=16, MULT_BITS=4)` across reset, mid-operation `clear_i`, normal and back-to-back `start_i` handshakes, both `invert_i = 0` and `invert_i = 1`, and stride accumulation into `hwpe_ctrl_uloop`.

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

Run Yosys with the Slang frontend to synthesize `hwpe_ctrl_partial_mult` at `AW=32, BW=32, MULT_BITS=4` and map to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
yosys -Q -T -m slang -p "
  read_slang --top hwpe_ctrl_partial_mult -G AW=32 -G BW=32 -G MULT_BITS=4 -DSYNTHESIS code/rtl/hwpe_ctrl_package.sv code/rtl/hwpe_ctrl_partial_mult.sv
  hierarchy -check -top hwpe_ctrl_partial_mult
  synth -top hwpe_ctrl_partial_mult
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

Check the reported `Chip area for module '\hwpe_ctrl_partial_mult':` line in the output of `stat -liberty`. It must be `<= 1620.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Before reading the mapped netlist into OpenROAD, strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD with the following script (`flow.tcl`):

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design hwpe_ctrl_partial_mult
initialize_floorplan -die_area {0 0 400 400} -core_area {10 10 390 390} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 3.1 [get_ports clk_i]
set_input_delay 0.25 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.25 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.4
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
```

Run:

```bash
openroad -exit flow.tcl
```

Both the worst setup slack (`-path_delay max`) and worst hold/removal slack (`-path_delay min`) must be `>= 0.0` (`ns`), with an empty `check_setup -verbose` audit block.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/hwpe_ctrl_partial_mult.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/hwpe_ctrl_partial_mult.sv (Golden Reference)
@@ -1,27 +1,6 @@
 // Copyright 2014-2026 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-
-/* 
- * hwpe_ctrl_partial_mult.sv
- * Francesco Conti <f.conti@unibo.it>
- *
- * Copyright (C) 2014-2026 ETH Zurich, University of Bologna
- * Copyright and related rights are licensed under the Solderpad Hardware
- * License, Version 0.51 (the "License"); you may not use this file except in
- * compliance with the License.  You may obtain a copy of the License at
- * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
- * or agreed to in writing, software, hardware and materials distributed under
- * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
- * CONDITIONS OF ANY KIND, either express or implied. See the License for the
- * specific language governing permissions and limitations under the License.
- *
- * A partially sequential unsigned multiplier. Inputs (including
- * invert_i) must be kept stable for AW/MULT_BITS-1 cycles after the
- * start strobe. When invert_i is asserted, the product is
- * -(a_i*b_i) rather than a_i*b_i.
- */
-
 
 module hwpe_ctrl_partial_mult
   import hwpe_ctrl_package::*;
@@ -43,67 +22,73 @@
   output logic [AW+BW-1:0] prod_o
 );
 
-  localparam AW_PAD = AW % MULT_BITS == 0 ? AW : AW + MULT_BITS - AW % MULT_BITS;
+  localparam int unsigned AW_PAD  = (AW % MULT_BITS == 0) ? AW : (AW + MULT_BITS - (AW % MULT_BITS));
+  localparam int unsigned N_STEPS = AW_PAD / MULT_BITS;
+  localparam int unsigned CNT_W   = $clog2(N_STEPS + 1);
 
   logic [AW_PAD-1:0] a_pad;
-  logic [$clog2(AW_PAD/MULT_BITS+1)-1:0] cnt;
-  logic [AW_PAD-1:0] chunk;
-  logic [AW_PAD+BW-1:0] prod;
-  logic [AW+BW-1:0] prod_nopad;
-  logic [AW+BW-1:0] shifted;
-  logic signed [AW+BW:0] shifted_signed;
-  logic signed [AW+BW-1:0] shifted_or_inverse;
-  logic valid_q, ready_q;
+  logic [CNT_W-1:0]  cnt;
+  logic              valid_q, ready_q;
 
-  always_ff @(posedge clk_i or negedge rst_ni)
-  begin : counter
-    if(~rst_ni) begin
-      cnt <= '0;
-      valid_q <= '0;
+  assign a_pad = {{(AW_PAD-AW){1'b0}}, a_i};
+
+  wire last_step = (cnt == CNT_W'(N_STEPS - 1));
+  wire step_en   = start_i || (cnt != '0);
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (~rst_ni) begin
+      cnt     <= '0;
+      valid_q <= 1'b0;
       ready_q <= 1'b1;
-    end
-    else if(clear_i) begin
-      cnt <= '0;
-      valid_q <= '0;
+    end else if (clear_i) begin
+      cnt     <= '0;
+      valid_q <= 1'b0;
       ready_q <= 1'b1;
-    end
-    else if(cnt == AW_PAD/MULT_BITS - 1) begin
-      cnt <= 0;
+    end else if (last_step) begin
+      cnt     <= '0;
       valid_q <= 1'b1;
       ready_q <= 1'b1;
-    end
-    else if((start_i==1'b1) || (cnt>0)) begin
-      cnt <= cnt + 1;
+    end else if (step_en) begin
+      cnt     <= cnt + 1'b1;
       valid_q <= 1'b0;
       ready_q <= 1'b0;
     end
   end
+
   assign valid_o = valid_q;
   assign ready_o = ready_q;
 
-  // pad a_i to a multiple of MULT_BITS
-  assign a_pad = {{(AW_PAD-AW){1'b0}}, a_i};
-  assign chunk = (a_pad >> cnt*MULT_BITS) & {{(AW_PAD-MULT_BITS){1'b0}}, {MULT_BITS{1'b1}}};
-  assign prod = chunk * b_i;
-  assign prod_nopad = prod[AW+BW-1:0];
-  assign shifted = cnt==AW_PAD/MULT_BITS ? 0 : (prod_nopad << (cnt * MULT_BITS));
-  assign shifted_signed = shifted * 48'sh1;
-  assign shifted_or_inverse = signed'(invert_i ? -shifted_signed : shifted_signed) * 48'sh1;
+  logic [MULT_BITS-1:0]    chunk;
+  logic [BW+MULT_BITS-1:0] prod;
+  logic [BW:0]             acc_hi_q;
+  logic [AW_PAD-1:0]       lo_shift_q;
 
-  always_ff @(posedge clk_i or negedge rst_ni)
-  begin : product
-    if(~rst_ni) begin
-      prod_o <= '0;
-    end
-    else if(clear_i) begin
-      prod_o <= '0;
-    end
-    else if (start_i) begin
-      prod_o <= shifted_or_inverse;
-    end
-    else if(cnt>0) begin
-      prod_o <= prod_o + shifted_or_inverse;
+  assign chunk = a_pad[cnt * MULT_BITS +: MULT_BITS];
+  assign prod  = chunk * b_i;
+
+  wire [BW:0]           acc_in   = start_i ? '0 : acc_hi_q;
+  wire [BW+MULT_BITS:0] acc_ext  = {{MULT_BITS{acc_in[BW]}}, acc_in};
+  wire [BW+MULT_BITS:0] prod_mod = {1'b0, prod} ^ {(BW+MULT_BITS+1){invert_i}};
+  wire [BW+MULT_BITS:0] sum      = acc_ext + prod_mod + invert_i;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (~rst_ni) begin
+      acc_hi_q   <= '0;
+      lo_shift_q <= '0;
+    end else if (clear_i) begin
+      acc_hi_q   <= '0;
+      lo_shift_q <= '0;
+    end else if (step_en) begin
+      acc_hi_q <= sum[BW+MULT_BITS:MULT_BITS];
+      if (N_STEPS == 1) begin
+        lo_shift_q <= sum[MULT_BITS-1:0];
+      end else begin
+        lo_shift_q <= {sum[MULT_BITS-1:0], lo_shift_q[AW_PAD-1:MULT_BITS]};
+      end
     end
   end
 
-endmodule /* hwpe_ctrl_partial_mult */
+  wire [AW_PAD+BW-1:0] full_res = {acc_hi_q[BW-1:0], lo_shift_q};
+  assign prod_o = full_res[AW+BW-1:0];
+
+endmodule

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/README.md`](environment/public/code/README.md) *(Read-Only Context)*
- [`environment/public/code/rtl/hwpe_ctrl_package.sv`](environment/public/code/rtl/hwpe_ctrl_package.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/hwpe_ctrl_partial_mult.sv`](environment/public/code/rtl/hwpe_ctrl_partial_mult.sv) **(Editable)**
- [`environment/public/code/rtl/hwpe_ctrl_uloop.sv`](environment/public/code/rtl/hwpe_ctrl_uloop.sv) *(Read-Only Context)*
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

