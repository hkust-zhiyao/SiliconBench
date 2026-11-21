# `case_0091`: NEureka Normalization-Quantization Rounding-Saturation, Stall Coherence, and Area/Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0091` |
| **Source Silicon Repository** | `pulp-platform/neureka` (`repo_31`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `synthesis_qor` (Logic Synthesis, Resource Sharing, Retiming, Structuring & Area/Delay QoR) |
| **Multi-Domain Tags** | `arithmetic_datapath`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/neureka_normquant.sv`](environment/public/code/rtl/neureka_normquant.sv), [`code/rtl/neureka_normquant_shifter.sv`](environment/public/code/rtl/neureka_normquant_shifter.sv) (2 files, 294 LOC) |
| **Public Subsystem Context** | 6 RTL files (1118 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# NEureka Normalization-Quantization Rounding-Saturation, Stall Coherence, and Area/Timing Closure

In the four-lane normalization-quantization unit (`code/rtl/neureka_normquant.sv` and `code/rtl/neureka_normquant_shifter.sv`), scaling, rounding, saturation, and pipeline control fail across operating modes. In `code/rtl/neureka_normquant.sv`, `flags_o[3:0].ready` must be driven high; the pipelined multipliers must advance only when `ctrl_i.start` is high (holding products when `ctrl_i.start` is low and clearing on `clear_i` or `rst_ni`); when `ctrl_i.norm_signed` is high, the scaling factor MSB is signed on every lane in `NEUREKA_MODE_8B`, odd lanes in `NEUREKA_MODE_16B` (even lanes unsigned), and lane 3 in `NEUREKA_MODE_32B` (lanes 0 to 2 unsigned); and 40-bit lane products must be sign-extended to 48 bits before shifted 16-bit/32-bit accumulation.

In `code/rtl/neureka_normquant_shifter.sv`, when `ctrl_i.use_shifting` is high with 5-bit shift amount `shift_i[4:0]`, add half-ULP rounding (`ctrl_i.use_rounding` and non-zero shift) before arithmetic right shift, then saturate to unsigned `[0, 2^K - 1]` when `ctrl_i.relu` is high or signed `[-2^(K-1), 2^(K-1) - 1]` when `ctrl_i.relu` is low (`K` in `{8, 16, 32}`, zero-extended to 32 bits). Under `BUILD.md`, achieve mapped area at most `915.0 um^2` for `neureka_normquant_shifter` (`INT=48, OUTPUT_REGISTER=1`), at most `4,685.0 um^2` for `neureka_normquant` (`OUTPUT_REGISTER=1`, multiplier blackboxed), and nonnegative setup/hold slack at a `1.75 ns` clock (`0.25 ns` I/O delays, `5.0 fF` load). Edit only `code/rtl/neureka_normquant.sv` and `code/rtl/neureka_normquant_shifter.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Guide

Editable files: `code/rtl/neureka_normquant.sv` and `code/rtl/neureka_normquant_shifter.sv`. All other files in `code/rtl/` and `lib/` are read-only.

## 1. Functional Simulation (Verilator)
```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  code/rtl/hwpe_stream_package.sv code/rtl/hci_package.sv code/rtl/neureka_package.sv \
  code/rtl/neureka_normquant_multiplier.sv code/rtl/neureka_normquant_shifter.sv \
  code/rtl/neureka_normquant.sv tb.sv
./obj_dir/Vtb
```

## 2. Synthesis & Area (`Nangate45`)
Shifter area (`<= 915.0 um^2`):
```bash
yosys -Q -T -m slang -p "read_slang --top neureka_normquant_shifter -G INT=48 -G OUTPUT_REGISTER=1 -DSYNTHESIS code/rtl/hwpe_stream_package.sv code/rtl/hci_package.sv code/rtl/neureka_package.sv code/rtl/neureka_normquant_shifter.sv; hierarchy -check -top neureka_normquant_shifter; synth -top neureka_normquant_shifter; opt; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; check -assert; stat -liberty lib/NangateOpenCellLibrary_typical.lib; write_verilog -noattr mapped_shifter.v"
```
Normquant datapath area (`<= 4685.0 um^2`, multiplier blackboxed):
```bash
yosys -Q -T -m slang -p "read_slang --blackboxed-module neureka_normquant_multiplier --top neureka_normquant -G OUTPUT_REGISTER=1 -DSYNTHESIS code/rtl/hwpe_stream_package.sv code/rtl/hci_package.sv code/rtl/neureka_package.sv code/rtl/neureka_normquant_multiplier.sv code/rtl/neureka_normquant_shifter.sv code/rtl/neureka_normquant.sv; hierarchy -check -top neureka_normquant; synth -top neureka_normquant -flatten; opt; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; check -assert; stat -liberty lib/NangateOpenCellLibrary_typical.lib"
```

## 3. OpenSTA (`1.75 ns` Clock)
Strip ` signed ` from `mapped_shifter.v` (`sed 's/ signed / /g' mapped_shifter.v > sta.v`) and run `openroad -exit sta.tcl`:
```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design neureka_normquant_shifter
create_clock -name clk_i -period 1.75 [get_ports clk_i]
set_input_delay 0.25 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.25 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```
Worst setup and hold slack must be `>= 0.0 ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/neureka_normquant.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/neureka_normquant.sv (Golden Reference)
@@ -1,24 +1,6 @@
-/*
- * neureka_normquant.sv
- *
- * Copyright (C) 2019-2021 ETH Zurich, University of Bologna and GreenWaves Technologies
- *
- * Copyright and related rights are licensed under the Solderpad Hardware
- * License, Version 0.51 (the "License"); you may not use this file except in
- * compliance with the License.  You may obtain a copy of the License at
- * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
- * or agreed to in writing, software, hardware and materials distributed under
- * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
- * CONDITIONS OF ANY KIND, either express or implied. See the License for the
- * specific language governing permissions and limitations under the License.
- */
-
-/*
- * Authors (RBE):  Gianna Paulin <pauling@iis.ee.ethz.ch>
- *                 Francesco Conti <f.conti@unibo.it>
- * Authors (NE16): Francesco Conti <francesco.conti@greenwaves-technologies.com>
- * Authors (NEUREKA): Arpan Suravi Prasad <prasadar@iis.ee.ethz.ch>
- */
+// Copyright (C) 2019-2021 ETH Zurich, University of Bologna and GreenWaves Technologies
+// Solderpad Hardware License, Version 0.51, see LICENSE for details.
+// SPDX-License-Identifier: SHL-0.51
 
 import neureka_package::*;
 
@@ -31,99 +13,92 @@
   parameter int unsigned PIPE = 1,
   parameter int unsigned OUTPUT_REGISTER = 0
 ) (
-  // global signals
   input  logic                          clk_i,
   input  logic                          rst_ni,
   input  logic                          test_mode_i,
-  // local clear
   input  logic                          clear_i,
-  // normalization parameters
   input  logic unsigned [NMULT*NMS-1:0] norm_mult_i,
   input  logic unsigned [NMULT*8-1:0]   shift_i,
-  // accumulation
   input  logic signed   [NMULT*ACC-1:0] accumulator_i,
   output logic signed   [NMULT*ACC-1:0] accumulator_o,
-  // control channel
   input  neureka_package::ctrl_normquant_t  ctrl_i,
   output neureka_package::flags_normquant_t [NMULT-1:0] flags_o
 );
 
-  logic signed [NMULT-1  :0][NMS+ACC-1:0]  product;
-  logic signed [NMULT-1  :0][INT-1:0]  product_48b;
-  logic signed [NMULT-1  :0][INT-1:0] product_8b;
-  logic signed [NMULT/2-1:0][INT-1:0] product_16b;
-  logic signed              [INT-1:0] product_32b;
-  logic signed [NMULT-1  :0][INT-1:0] product_to_shift;
-  logic signed [NMULT-1  :0][INT-1:0] rounding;
+  logic signed [NMULT-1:0][NMS+ACC-1:0] product;
+  logic signed [NMULT-1:0][INT-1:0]     product_to_shift;
 
-  generate
-    for(genvar ii=0; ii<NMULT; ii++) begin : mult_gen
+  for (genvar ii = 0; ii < NMULT; ii++) begin : mult_gen
+    localparam int unsigned ii_div2 = ii / 2;
+    logic sign_bit;
+    logic signed [NMS:0] norm_mult_signed;
+    logic [ACC-1:0]      accumulator_selected;
 
-      localparam ii_div2 = ii / 2;
+    assign accumulator_selected = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? accumulator_i[(ii+1)*32-1:ii*32] :
+                                  (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? accumulator_i[(ii_div2+1)*32-1:ii_div2*32] :
+                                  (ctrl_i.norm_mode == NEUREKA_MODE_32B) ? accumulator_i[31:0] : '0;
 
-      logic sign_bit;
-      logic signed [NMS:0]   norm_mult_signed;
-      logic        [ACC-1:0] accumulator_selected;
+    assign sign_bit = (ctrl_i.norm_mode == NEUREKA_MODE_8B)                      ? norm_mult_i[(ii+1)*NMS-1] :
+                      ((ctrl_i.norm_mode == NEUREKA_MODE_16B) && (ii % 2 == 1))  ? norm_mult_i[(ii+1)*NMS-1] :
+                      ((ctrl_i.norm_mode == NEUREKA_MODE_32B) && (ii == 3))      ? norm_mult_i[NMULT*NMS-1]  : 1'b0;
 
-      assign accumulator_selected = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? accumulator_i [(ii+1)*32-1:ii*32] :
-                                    (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? accumulator_i [(ii_div2+1)*32-1:ii_div2*32] :
-                                    (ctrl_i.norm_mode == NEUREKA_MODE_32B) ? accumulator_i [32-1:0] : '0;
+    assign norm_mult_signed = {ctrl_i.norm_signed & sign_bit, norm_mult_i[(ii+1)*NMS-1:ii*NMS]};
+    assign flags_o[ii].ready = 1'b1;
 
-      assign sign_bit = norm_mult_i[NMULT*NMS-1]; // sign is used only in WEIGHTOFFS
+    neureka_normquant_multiplier #(
+      .NMS  ( NMS  ),
+      .ACC  ( ACC  ),
+      .PIPE ( PIPE )
+    ) i_multiplier (
+      .clk_i              ( clk_i                ),
+      .rst_ni             ( rst_ni               ),
+      .test_mode_i        ( test_mode_i          ),
+      .clear_i            ( clear_i              ),
+      .enable_i           ( ctrl_i.start         ),
+      .norm_mult_signed_i ( norm_mult_signed     ),
+      .accumulator_i      ( accumulator_selected ),
+      .product_o          ( product[ii]          )
+    );
+  end
 
-      assign norm_mult_signed = {ctrl_i.norm_signed & sign_bit, norm_mult_i[(ii+1)*NMS-1:ii*NMS]};
-      neureka_normquant_multiplier #(
-        .NMS  ( NMS  ),
-        .ACC  ( ACC  ),
-        .PIPE ( PIPE )
-      ) i_multiplier (
-        .clk_i              ( clk_i                ),
-        .rst_ni             ( rst_ni               ),
-        .test_mode_i        ( test_mode_i          ),
-        .clear_i            ( clear_i              ),
-        .enable_i           ( 1'b1                 ),
-        .norm_mult_signed_i ( norm_mult_signed     ),
-        .accumulator_i      ( accumulator_selected ),
-        .product_o          ( product [ii]         )
-      );
-    end
+  wire signed [39:0] p0_s = product[0];
+  wire signed [39:0] p1_s = product[1];
+  wire signed [39:0] p2_s = product[2];
+  wire signed [39:0] p3_s = product[3];
 
-    // FIXME hardwired params
-    assign product_48b[0] = $signed(product[0]);
-    assign product_48b[1] = $signed(product[1]);
-    assign product_48b[2] = $signed(product[2]);
-    assign product_48b[3] = $signed(product[3]);
-    assign product_32b    = $signed(product_48b[0] + (product_48b[1] <<< 8) + (product_48b[2] <<< 16) + (product_48b[3] <<< 24));
-    assign product_16b[0] = $signed(product[0] + (product[1] <<< 8));
-    assign product_16b[1] = $signed(product[2] + (product[3] <<< 8));
-    assign product_8b[0]  = $signed(product[0]);
-    assign product_8b[1]  = $signed(product[1]);
-    assign product_8b[2]  = $signed(product[2]);
-    assign product_8b[3]  = $signed(product[3]);
-    assign product_to_shift = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? product_8b :
-                              (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? { 48'b0, 48'b0, product_16b } :
-                              (ctrl_i.norm_mode == NEUREKA_MODE_32B) ? { 48'b0, 48'b0, 48'b0, product_32b } : '0;
+  wire signed [39:0] pair0_hi  = $signed({{8{p0_s[39]}}, p0_s[39:8]}) + p1_s;
+  wire signed [39:0] pair1_hi  = $signed({{8{p2_s[39]}}, p2_s[39:8]}) + p3_s;
+  wire signed [47:0] pair0_sum = {pair0_hi, p0_s[7:0]};
+  wire signed [47:0] pair1_sum = {pair1_hi, p2_s[7:0]};
+  wire signed [31:0] quad_hi   = pair0_sum[47:16] + pair1_sum[31:0];
+  wire signed [47:0] quad_sum  = {quad_hi, pair0_sum[15:0]};
 
-    for(genvar ii=0; ii<NMULT; ii++) begin : shift_sat_gen
+  assign product_to_shift[0] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p0_s[39]}}, p0_s} :
+                               (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? pair0_sum :
+                               (ctrl_i.norm_mode == NEUREKA_MODE_32B) ? quad_sum  : '0;
+  assign product_to_shift[1] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p1_s[39]}}, p1_s} :
+                               (ctrl_i.norm_mode == NEUREKA_MODE_16B) ? pair1_sum : '0;
+  assign product_to_shift[2] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p2_s[39]}}, p2_s} : '0;
+  assign product_to_shift[3] = (ctrl_i.norm_mode == NEUREKA_MODE_8B)  ? {{8{p3_s[39]}}, p3_s} : '0;
 
-      logic [31:0] accumulator_loc;
-      neureka_normquant_shifter #(
-        .ACC             ( ACC             ),
-        .INT             ( INT             ),
-        .OUTPUT_REGISTER ( OUTPUT_REGISTER )
-      ) i_shifter (
-        .clk_i         ( clk_i                    ),
-        .rst_ni        ( rst_ni                   ),
-        .test_mode_i   ( test_mode_i              ),
-        .clear_i       ( clear_i                  ),
-        .data_i        ( product_to_shift[ii]     ),
-        .shift_i       ( shift_i[(ii+1)*8-1:ii*8] ),
-        .accumulator_o ( accumulator_loc          ),
-        .ctrl_i        ( ctrl_i                   )
-      );
-      assign accumulator_o[(ii+1)*32-1:ii*32] = accumulator_loc;
+  for (genvar ii = 0; ii < NMULT; ii++) begin : shift_sat_gen
+    localparam int unsigned LANE_INT = (ii < 2) ? 48 : 40;
+    logic [31:0] accumulator_loc;
+    neureka_normquant_shifter #(
+      .ACC             ( ACC             ),
+      .INT             ( LANE_INT        ),
+      .OUTPUT_REGISTER ( OUTPUT_REGISTER )
+    ) i_shifter (
+      .clk_i         ( clk_i                              ),
+      .rst_ni        ( rst_ni                             ),
+      .test_mode_i   ( test_mode_i                        ),
+      .clear_i       ( clear_i                            ),
+      .data_i        ( product_to_shift[ii][LANE_INT-1:0] ),
+      .shift_i       ( shift_i[(ii+1)*8-1:ii*8]           ),
+      .accumulator_o ( accumulator_loc                    ),
+      .ctrl_i        ( ctrl_i                             )
+    );
+    assign accumulator_o[(ii+1)*32-1:ii*32] = accumulator_loc;
+  end
 
-    end
-  endgenerate
-
-endmodule // neureka_normquant
+endmodule

--- a/environment/public/code/rtl/neureka_normquant_shifter.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/neureka_normquant_shifter.sv (Golden Reference)
@@ -1,24 +1,6 @@
-/*
- * neureka_normquant_shifter.sv
- *
- * Copyright (C) 2019-2021 ETH Zurich, University of Bologna and GreenWaves Technologies
- *
- * Copyright and related rights are licensed under the Solderpad Hardware
- * License, Version 0.51 (the "License"); you may not use this file except in
- * compliance with the License.  You may obtain a copy of the License at
- * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
- * or agreed to in writing, software, hardware and materials distributed under
- * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
- * CONDITIONS OF ANY KIND, either express or implied. See the License for the
- * specific language governing permissions and limitations under the License.
- */
-
-/*
- * Authors (RBE):  Gianna Paulin <pauling@iis.ee.ethz.ch>
- *                 Francesco Conti <f.conti@unibo.it>
- * Authors (NE16): Francesco Conti <francesco.conti@greenwaves-technologies.com>
- * Authors (NEUREKA): Arpan Suravi Prasad <prasadar@iis.ee.ethz.ch>
- */
+// Copyright (C) 2019-2021 ETH Zurich, University of Bologna and GreenWaves Technologies
+// Solderpad Hardware License, Version 0.51, see LICENSE for details.
+// SPDX-License-Identifier: SHL-0.51
 
 import neureka_package::*;
 
@@ -37,129 +19,94 @@
   input  neureka_package::ctrl_normquant_t  ctrl_i
 );
 
-  logic [INT-1:0] shifted;
-  logic signed [INT-1:0] rounding;
+  wire [4:0] shamt = ctrl_i.use_shifting ? shift_i[4:0] : 5'd0;
+  wire signed [INT:0] data_ext = {data_i[INT-1], data_i, 1'b0};
+  wire signed [INT:0] shifted_with_half = data_ext >>> shamt;
+  wire round_inc = ctrl_i.use_shifting & ctrl_i.use_rounding & shifted_with_half[0];
+  wire [INT-1:0] pre_u = shifted_with_half[INT:1];
+
+  logic [31:0] c_chain;
+  always_comb begin
+    c_chain[0] = round_inc & pre_u[0];
+    for (int k = 1; k < 32; k++) begin
+      c_chain[k] = c_chain[k-1] & pre_u[k];
+    end
+  end
+  wire [31:0] low32 = pre_u[31:0] ^ {c_chain[30:0], round_inc};
+  wire c8  = c_chain[7];
+  wire c16 = c_chain[15];
+  wire c32 = c_chain[31];
+
+  wire is_neg = pre_u[INT-1];
+  wire is_8b  = (ctrl_i.quant_mode == NEUREKA_MODE_8B);
+  wire is_16b = (ctrl_i.quant_mode == NEUREKA_MODE_16B);
+  wire is_32b = (ctrl_i.quant_mode == NEUREKA_MODE_32B);
+
+  wire hi_nz_32 = |pre_u[INT-2:32];
+  wire hi_nz_16 = hi_nz_32 | (|pre_u[31:16]);
+  wire hi_nz_8  = hi_nz_16 | (|pre_u[15:8]);
+
+  wire hi_all1_32 = &pre_u[INT-2:32];
+  wire hi_all1_16 = hi_all1_32 & (&pre_u[31:16]);
+  wire hi_all1_8  = hi_all1_16 & (&pre_u[15:8]);
+
+  wire ovf_pos = is_8b  ? ((ctrl_i.relu ? 1'b0 : low32[7])  | hi_nz_8  | c8)  :
+                 is_16b ? ((ctrl_i.relu ? 1'b0 : low32[15]) | hi_nz_16 | c16) :
+                 is_32b ? ((ctrl_i.relu ? 1'b0 : low32[31]) | hi_nz_32 | c32) : 1'b0;
+
+  wire in_neg_range = is_8b  ? (hi_all1_8  & (low32[7]  | c8))  :
+                      is_16b ? (hi_all1_16 & (low32[15] | c16)) :
+                      is_32b ? (hi_all1_32 & (low32[31] | c32)) : 1'b1;
+
+  wire do_zero = (ctrl_i.use_shifting & ctrl_i.relu & is_neg) | (~is_8b & ~is_16b & ~is_32b);
+  wire do_sat_pos = ctrl_i.use_shifting & ~is_neg & ovf_pos;
+  wire do_sat_neg = ctrl_i.use_shifting & ~ctrl_i.relu & is_neg & ~in_neg_range;
+
   logic [ACC-1:0] accumulator, accumulator_d, accumulator_q;
-  logic [5:0] right_shift;
 
-  assign right_shift = shift_i;
-
-  assign rounding = 1 <<< (right_shift-1);
-  assign shifted = ~ctrl_i.use_shifting ? $signed(data_i) :
-                                          $signed(data_i) >>> right_shift;
-
-  logic [INT-2:0] sat_big_or_shifted;
-  logic [INT-2:0] sat_big_nand_shifted;
-
-  always_comb
-  begin
-    sat_big_or_shifted   =  shifted[INT-2:0];
-    sat_big_nand_shifted = ~shifted[INT-2:0];
-    if(ctrl_i.relu) begin
-      if(ctrl_i.quant_mode == NEUREKA_MODE_8B) begin
-        sat_big_or_shifted [7:0] = '0;
-      end
-      else if(ctrl_i.quant_mode == NEUREKA_MODE_16B) begin
-        sat_big_or_shifted [15:0] = '0;
-      end
-      else if(ctrl_i.quant_mode == NEUREKA_MODE_32B) begin
-        sat_big_or_shifted = '0;
-      end
-    end
-    else begin
-      if(ctrl_i.quant_mode == NEUREKA_MODE_8B) begin
-        sat_big_or_shifted  [6:0] = '0;
-        sat_big_nand_shifted[6:0] = '0;
-      end
-      else if(ctrl_i.quant_mode == NEUREKA_MODE_16B) begin
-        sat_big_or_shifted  [14:0] = '0;
-        sat_big_nand_shifted[14:0] = '0;
-      end
-      else if(ctrl_i.quant_mode == NEUREKA_MODE_32B) begin
-        sat_big_or_shifted  [30:0] = '0;
-        sat_big_nand_shifted[30:0] = '0;
-      end
+  always_comb begin
+    if (do_zero) begin
+      accumulator = '0;
+    end else if (do_sat_neg) begin
+      accumulator = {is_32b, 15'b0, is_16b, 7'b0, is_8b, 7'b0};
+    end else if (do_sat_pos) begin
+      accumulator = {
+        is_32b & ctrl_i.relu,
+        {15{is_32b}},
+        (is_32b | (is_16b & ctrl_i.relu)),
+        {7{is_32b | is_16b}},
+        (is_32b | is_16b | (is_8b & ctrl_i.relu)),
+        {7{is_32b | is_16b | is_8b}}
+      };
+    end else begin
+      accumulator = {
+        is_32b ? low32[31:16] : 16'b0,
+        (is_32b | is_16b) ? low32[15:8] : 8'b0,
+        low32[7:0]
+      };
     end
   end
 
-  always_comb
-  begin
-
-    accumulator = '0;
-    if(ctrl_i.quant_mode == NEUREKA_MODE_8B) begin
-      accumulator[7:0] = shifted[7:0];
-    end
-    else if(ctrl_i.quant_mode == NEUREKA_MODE_16B) begin
-      accumulator[15:0] = shifted[15:0];
-    end
-    else if(ctrl_i.quant_mode == NEUREKA_MODE_32B) begin
-      accumulator = shifted[ACC-1:0];
-    end
-
-    if(ctrl_i.use_shifting) begin
-      if(ctrl_i.relu) begin
-        if(shifted[INT-1])
-          accumulator = '0; // neg or sat- with relu active
-        else if(~shifted[INT-1] & (|(sat_big_or_shifted))) begin
-          accumulator = '1; // sat+
-        end
-      end
-      else begin
-        if (shifted[INT-1] & (|(sat_big_nand_shifted))) begin
-          accumulator = '0;
-          if(ctrl_i.quant_mode == NEUREKA_MODE_8B) begin
-            accumulator[7] = 1'b1; // sat-
-          end
-          else if(ctrl_i.quant_mode == NEUREKA_MODE_16B) begin
-            accumulator[15] = 1'b1; // sat-
-          end
-          else if(ctrl_i.quant_mode == NEUREKA_MODE_32B) begin
-            accumulator[31] = 1'b1; // sat-
-          end
-        end
-        else if(~shifted[INT-1] & (|(sat_big_or_shifted))) begin
-          accumulator = '1; // sat+
-          if(ctrl_i.quant_mode == NEUREKA_MODE_32B) begin
-            accumulator[31] = 1'b0; // sat+
-          end
-          else if(ctrl_i.quant_mode == NEUREKA_MODE_16B) begin
-            accumulator[15] = 1'b0; // sat+
-          end
-          else if(ctrl_i.quant_mode == NEUREKA_MODE_8B) begin
-            accumulator[7] = 1'b0; // sat+
-          end
-        end
+  if(OUTPUT_REGISTER) begin : output_register_gen
+    always_comb begin
+      accumulator_d = accumulator_q;
+      if(clear_i) begin
+        accumulator_d = '0;
+      end else if (ctrl_i.start) begin
+        accumulator_d = accumulator;
       end
     end
-
-  end
-
-  if(OUTPUT_REGISTER) begin : output_register_gen
-
-    always_comb begin 
-      accumulator_d = accumulator_q; 
-      if(clear_i) begin 
-        accumulator_d = '0;
-      end else if (ctrl_i.start) begin  
-        accumulator_d = accumulator;
-      end 
-    end 
-
-    always_ff @(posedge clk_i or negedge rst_ni)
-    begin
+    always_ff @(posedge clk_i or negedge rst_ni) begin
       if(~rst_ni) begin
         accumulator_q <= '0;
-      end
-      else begin
+      end else begin
         accumulator_q <= accumulator_d;
       end
     end
-
-  end
-  else begin : no_output_register_gen
+  end else begin : no_output_register_gen
     assign accumulator_q = accumulator;
   end
 
   assign accumulator_o = accumulator_q;
 
-endmodule // neureka_normquant_shifter
+endmodule

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/README.md`](environment/public/code/README.md) *(Read-Only Context)*
- [`environment/public/code/rtl/hci_package.sv`](environment/public/code/rtl/hci_package.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/hwpe_stream_package.sv`](environment/public/code/rtl/hwpe_stream_package.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/neureka_normquant.sv`](environment/public/code/rtl/neureka_normquant.sv) **(Editable)**
- [`environment/public/code/rtl/neureka_normquant_multiplier.sv`](environment/public/code/rtl/neureka_normquant_multiplier.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/neureka_normquant_shifter.sv`](environment/public/code/rtl/neureka_normquant_shifter.sv) **(Editable)**
- [`environment/public/code/rtl/neureka_package.sv`](environment/public/code/rtl/neureka_package.sv) *(Read-Only Context)*
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

