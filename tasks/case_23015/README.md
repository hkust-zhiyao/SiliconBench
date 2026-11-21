# `case_23015`: NVDLA CDP LRN Sliding-Window Sum, Dual-LUT Indexer & Piecewise-Linear Interpolator PPA/STA Signoff

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23015` |
| **Source Silicon Repository** | `nvdla/hw` (`repo_36`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/int_sum_block.v`](environment/public/code/int_sum_block.v), [`code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v`](environment/public/code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v), [`code/NV_NVDLA_CDP_DP_INTP_unit.v`](environment/public/code/NV_NVDLA_CDP_DP_INTP_unit.v) (3 files, 6619 LOC) |
| **Public Subsystem Context** | 57 RTL files (77087 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# NVDLA CDP LRN Sliding-Window Sum, Dual-LUT Indexer & Piecewise-Linear Interpolator PPA/Signoff

## Context
`public/code/` contains the standalone RTL closure of the NVIDIA NVDLA Channel Data Processor datapath (`NV_NVDLA_CDP_dp`), which executes cross-channel Local Response Normalization (LRN) across `INT8`, `INT16`, and `FP16` feature maps (`rdma -> bufferin -> nan -> cvtin -> mul -> sum -> lut_ctrl -> lut -> intp -> mul -> cvtout -> wdma`).

Currently, the three core arithmetic stages—`int_sum_block`, `NV_NVDLA_CDP_DP_LUT_CTRL_unit`, and `NV_NVDLA_CDP_DP_INTP_unit`—suffer from excessive combinational logic depth, redundant adder/shifter structures, and an IEEE-754 floating-point range-clamping defect in `FP16`/`FP32` LUT index generation, failing 3.80 ns Nangate45 static timing signoff and area budgets.

## Editable Files
You may modify **only** the following files (all other files in `code/` and `lib/` are read-only):
- `code/int_sum_block.v` (`module int_sum_block`)
- `code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v` (`module NV_NVDLA_CDP_DP_LUT_CTRL_unit`)
- `code/NV_NVDLA_CDP_DP_INTP_unit.v` (`module NV_NVDLA_CDP_DP_INTP_unit`)

## Architectural, Arithmetic & Protocol Contract
1. **Cross-Channel Window Summation (`int_sum_block`)**:
   - Compute centered cross-channel window sums around lane 4 for active window lengths `L in {3, 5, 7, 9}` (`reg2dp_normalz_len` / `len5`, `len7`, `len9`, summing input lanes `[4 - (L-1)/2 .. 4 + (L-1)/2]`) in both single-lane `INT16` mode (`int16_sum[36:0]`) and dual-lane `INT8` mode (`int8_sum[41:0]`, packing `msb` in `[41:21]` and `lsb` in `[20:0]`).
   - Preserve the exact 2-stage load-enabled pipeline latency (`load_din_d` -> `load_din_2d`) required by enclosing `NV_NVDLA_CDP_DP_sum`.
2. **Dual-LUT Address & Fraction Generation (`NV_NVDLA_CDP_DP_LUT_CTRL_unit`)**:
   - Map `sum2itp_pd` into parallel `LE` (65-entry, indices `0..64`, exponential or linear via `reg2dp_lut_le_function`) and `LO` (257-entry, indices `0..256`, linear) lookup requests (`dp2lut_X_pd`, `dp2lut_X_info`, `dp2lut_Y_pd`, `dp2lut_Y_info`) under elastic `sum2itp_pvld`/`sum2itp_prdy` and `dp2lut_pvld`/`dp2lut_prdy` flow control across `INT8`, `INT16` (lower lane active; upper `msb` index/info lane is unused downstream), and `FP16` modes.
   - In `FP16` mode (`HLS_fp32_sub` offset subtraction against `reg2dp_lut_{le,lo}_start_low`), strictly uphold IEEE-754 special-value and boundary clamping: `NaN` or non-positive (`<= 0`) shifted differences must report underflow (`uflow = 1`, `oflow = 0`, index `0`), whereas `+Inf` (either on input or when finite-minus-start subtraction overflows `FP32` to `+Inf`) or above-range values must report overflow (`oflow = 1`, `uflow = 0`, clamped max index `64` for `LE` and `256` for `LO`). On table hits (`uflow == 0 && oflow == 0`), exact table indices and 16-bit interpolation fractions must be emitted (when `uflow` or `oflow` is asserted, the 16-bit fraction field in `*_info` is unused downstream).
3. **Piecewise-Linear Interpolator (`NV_NVDLA_CDP_DP_INTP_unit`) & Subsystem Parity**:
   - Under elastic `interp_in_vld`/`interp_in_rdy` -> `interp_out_vld`/`interp_out_rdy` backpressure, preserve exact `FP16` (`HLS_fp32_sub` -> `HLS_fp32_to_fp17` -> `HLS_fp17_mul` -> `HLS_fp17_add`) and signed integer (`INT8`/`INT16`) interpolation: multiply the signed input delta by signed `interp_in_scale[16:0]`, apply signed `interp_in_shift[5:0]` (right-shift with symmetric round-half-away-from-zero when positive; left-shift when negative), add signed `interp_in_pd[16:0]`, and saturate symmetrically to signed 16-bit `[-32768, +32767]` (sign-extended to `interp_out_pd[16:0]`).
   - Maintain end-to-end packet ordering, backpressure invariance, `cdp_dp2wdma_pd` outputs, and LUT hit/overflow/underflow/hybrid counters across `NV_NVDLA_CDP_dp`.

## Synthesis, 4-State Gate-Level Hygiene & Nangate45 PPA/STA Targets
- **Synthesis & 4-State Gate-Level Reset Hygiene**: Each editable unit (with its `HLS_fp*` subblocks where instantiated, compiled under `-DSYNTHESIS -DVLIB_BYPASS_POWER_CG -DNV_FPGA_FIFOGEN -DVERILINT`) must synthesize cleanly in Yosys with zero inferred latches (`$dlatch*` / `$_DLATCH_*`), zero combinational loops (`scc -expect 0`), and deterministic non-`X` post-reset control/datapath behavior in 4-state gate-level simulation even when data inputs are `X` during active-low `nvdla_core_rstn`.
- **Nangate45 Cell Area Caps** (`public/lib/NangateOpenCellLibrary_typical.lib`, `dfflibmap -liberty` + `abc -liberty ... -D 1800`):
  - `int_sum_block`: `<= 6,100.0 um^2`
  - `NV_NVDLA_CDP_DP_LUT_CTRL_unit`: `<= 27,500.0 um^2`
  - Combined 3-unit area (`int_sum_block + NV_NVDLA_CDP_DP_LUT_CTRL_unit + NV_NVDLA_CDP_DP_INTP_unit`): `<= 59,000.0 um^2`
- **OpenROAD Static Timing Signoff**: Under a **`3.80 ns` clock period** on all clock ports of each unit (`0.25 ns` input/output delay on non-clock ports, `set_false_path -from [get_ports *rst*]`), every one of the 3 units must achieve setup **`WNS >= 0.0000 ns`**.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Signoff Reference

## Editable Files
- `code/int_sum_block.v`
- `code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v`
- `code/NV_NVDLA_CDP_DP_INTP_unit.v`

## Read-Only Subsystem & Collateral
- Enclosing subsystem top: `code/NV_NVDLA_CDP_dp.v` and supporting CDP/HLS/FIFO/RAM modules in `code/`
- Standard-cell Liberty / LEF:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Unit & End-to-End Subsystem Verification (`Verilator v5.038`)**:
   - Compile `code/*.v` with `-DSYNTHESIS -DVLIB_BYPASS_POWER_CG -DNV_FPGA_FIFOGEN -DVERILINT -Icode` and verify `int_sum_block`, `NV_NVDLA_CDP_DP_LUT_CTRL_unit`, `NV_NVDLA_CDP_DP_INTP_unit`, and full `NV_NVDLA_CDP_dp` streaming across `INT8`, `INT16`, and `FP16` cubes under randomized backpressure.
2. **Yosys Synthesis, 4-State Gate-Level Hygiene & Nangate45 Area/STA Signoff**:
   - Synthesize each editable unit (`int_sum_block`, `NV_NVDLA_CDP_DP_LUT_CTRL_unit` + `HLS_fp32_sub.v`, and `NV_NVDLA_CDP_DP_INTP_unit` + `HLS_fp32_sub.v` / `HLS_fp32_to_fp17.v` / `HLS_fp17_mul.v` / `HLS_fp17_add.v`) using `yosys -m slang` (`read_slang -DSYNTHESIS -DVLIB_BYPASS_POWER_CG -DNV_FPGA_FIFOGEN -DVERILINT -Icode ...`), asserting zero inferred latches (`$dlatch*`, `$_DLATCH_*`) and zero combinational loops (`scc -expect 0`), and verify 4-state gate-level reset/functional behavior in `iverilog -g2012`.
   - Map each unit to `lib/NangateOpenCellLibrary_typical.lib` (`dfflibmap -liberty` + `abc -liberty ... -D 1800`) and check cell area (`int_sum_block <= 6100.0 um^2`, `NV_NVDLA_CDP_DP_LUT_CTRL_unit <= 27500.0 um^2`, 3-unit sum `<= 59000.0 um^2`).
   - Run OpenROAD STA (`read_lef`, `read_liberty`, `read_verilog`) at `3.80 ns` clock period (`0.25 ns` input/output delays on non-clock ports, `set_false_path -from [get_ports *rst*]`), requiring setup `WNS >= 0.0000 ns` on all 3 units.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/int_sum_block.v (Buggy Starter)
+++ b/solution/gold/code/int_sum_block.v (Golden Reference)
@@ -1,8 +1,8 @@
 // ================================================================
 // NVDLA Open Source Project
-// 
+//
 // Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
-// NVDLA Open Hardware License; Check "LICENSE" which comes with 
+// NVDLA Open Hardware License; Check "LICENSE" which comes with
 // this distribution for more information.
 // ================================================================
 
@@ -86,1200 +86,104 @@
 input  [16:0] sq_pd_int8_msb_8;
 output [36:0] int16_sum;
 output [41:0] int8_sum;
-reg    [36:0] int16_sum;
-reg    [34:0] int16_sum3;
-reg    [35:0] int16_sum5;
-reg    [35:0] int16_sum7;
-reg    [36:0] int16_sum9;
-reg    [33:0] int16_sum_0_8;
-reg    [33:0] int16_sum_1_7;
-reg    [33:0] int16_sum_2_6;
-reg    [33:0] int16_sum_3_5;
-reg    [20:0] int8_lsb_sum;
-reg    [20:0] int8_msb_sum;
-reg    [18:0] int8_msb_sum3;
-reg    [19:0] int8_msb_sum5;
-reg    [19:0] int8_msb_sum7;
-reg    [20:0] int8_msb_sum9;
-reg    [17:0] int8_msb_sum_0_8;
-reg    [17:0] int8_msb_sum_1_7;
-reg    [17:0] int8_msb_sum_2_6;
-reg    [17:0] int8_msb_sum_3_5;
-reg    [32:0] sq4_d;
-reg    [16:0] sq_pd_int8_msb_4_d;
-wire   [18:0] int8_lsb_sum3;
-wire   [19:0] int8_lsb_sum5;
-wire   [19:0] int8_lsb_sum7;
-wire   [20:0] int8_lsb_sum9;
-wire   [32:0] sq0;
-wire   [32:0] sq1;
-wire   [32:0] sq2;
-wire   [32:0] sq3;
-wire   [32:0] sq5;
-wire   [32:0] sq6;
-wire   [32:0] sq7;
-wire   [32:0] sq8;
 
-assign sq3[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_3[16:0]} :sq_pd_int16_3[32:0];
-assign sq5[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_5[16:0]} :sq_pd_int16_5[32:0];
-assign sq2[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_2[16:0]} :sq_pd_int16_2[32:0];
-assign sq6[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_6[16:0]} :sq_pd_int16_6[32:0];
-assign sq1[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_1[16:0]} :sq_pd_int16_1[32:0];
-assign sq7[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_7[16:0]} :sq_pd_int16_7[32:0];
-assign sq0[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_0[16:0]} :sq_pd_int16_0[32:0];
-assign sq8[32:0] = int8_en ? {16'd0,sq_pd_int8_lsb_8[16:0]} :sq_pd_int16_8[32:0];
+wire [32:0] sq0 = int8_en ? {16'd0, sq_pd_int8_lsb_0} : sq_pd_int16_0;
+wire [32:0] sq1 = int8_en ? {16'd0, sq_pd_int8_lsb_1} : sq_pd_int16_1;
+wire [32:0] sq2 = int8_en ? {16'd0, sq_pd_int8_lsb_2} : sq_pd_int16_2;
+wire [32:0] sq3 = int8_en ? {16'd0, sq_pd_int8_lsb_3} : sq_pd_int16_3;
+wire [32:0] sq4 = int8_en ? {16'd0, sq_pd_int8_lsb_4} : sq_pd_int16_4;
+wire [32:0] sq5 = int8_en ? {16'd0, sq_pd_int8_lsb_5} : sq_pd_int16_5;
+wire [32:0] sq6 = int8_en ? {16'd0, sq_pd_int8_lsb_6} : sq_pd_int16_6;
+wire [32:0] sq7 = int8_en ? {16'd0, sq_pd_int8_lsb_7} : sq_pd_int16_7;
+wire [32:0] sq8 = int8_en ? {16'd0, sq_pd_int8_lsb_8} : sq_pd_int16_8;
 
-//sum process
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    int8_msb_sum_3_5 <= {18{1'b0}};
-  end else begin
-  if ((load_din_d                   ) == 1'b1) begin
-    int8_msb_sum_3_5 <= (sq_pd_int8_msb_3[16:0] + sq_pd_int8_msb_5[16:0]);
-  // VCS coverage off
-  end else if ((load_din_d                   ) == 1'b0) begin
-  end else begin
-    int8_msb_sum_3_5 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
-  end
-end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_1x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d                   ))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    int8_msb_sum_2_6 <= {18{1'b0}};
-  end else begin
-  if ((load_din_d & (len5|len7|len9)) == 1'b1) begin
-    int8_msb_sum_2_6 <= (sq_pd_int8_msb_2[16:0] + sq_pd_int8_msb_6[16:0]);
-  // VCS coverage off
-  end else if ((load_din_d & (len5|len7|len9)) == 1'b0) begin
-  end else begin
-    int8_msb_sum_2_6 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
-  end
-end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_2x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d & (len5|len7|len9)))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    int8_msb_sum_1_7 <= {18{1'b0}};
-  end else begin
-  if ((load_din_d & (len7|len9)     ) == 1'b1) begin
-    int8_msb_sum_1_7 <= (sq_pd_int8_msb_1[16:0] + sq_pd_int8_msb_7[16:0]);
-  // VCS coverage off
-  end else if ((load_din_d & (len7|len9)     ) == 1'b0) begin
-  end else begin
-    int8_msb_sum_1_7 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
-  end
-end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_3x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d & (len7|len9)     ))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    int8_msb_sum_0_8 <= {18{1'b0}};
-  end else begin
-  if ((load_din_d & (len9)          ) == 1'b1) begin
-    int8_msb_sum_0_8 <= (sq_pd_int8_msb_0[16:0] + sq_pd_int8_msb_8[16:0]);
-  // VCS coverage off
-  end else if ((load_din_d & (len9)          ) == 1'b0) begin
-  end else begin
-    int8_msb_sum_0_8 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
-  end
-end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_4x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d & (len9)          ))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
+wire en_ge5 = len5 | len7 | len9;
+wire en_ge7 = len7 | len9;
+
+reg [32:0] sq4_d;
+reg [33:0] p35_16, p26_16, p17_16, p08_16;
+reg [16:0] msb4_d;
+reg [17:0] p35_m8, p26_m8, p17_m8, p08_m8;
 
 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
-    int16_sum_3_5 <= {34{1'b0}};
+    sq4_d  <= 33'd0;
+    p35_16 <= 34'd0;
+    p26_16 <= 34'd0;
+    p17_16 <= 34'd0;
+    p08_16 <= 34'd0;
+    msb4_d <= 17'd0;
+    p35_m8 <= 18'd0;
+    p26_m8 <= 18'd0;
+    p17_m8 <= 18'd0;
+    p08_m8 <= 18'd0;
   end else begin
-  if ((load_din_d                   ) == 1'b1) begin
-    int16_sum_3_5 <= (sq3[32:0] + sq5[32:0]);
-  // VCS coverage off
-  end else if ((load_din_d                   ) == 1'b0) begin
-  end else begin
-    int16_sum_3_5 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
+    if (load_din_d) begin
+      sq4_d  <= sq4;
+      p35_16 <= sq3 + sq5;
+      msb4_d <= sq_pd_int8_msb_4;
+      p35_m8 <= sq_pd_int8_msb_3 + sq_pd_int8_msb_5;
+    end
+    if (load_din_d & en_ge5) begin
+      p26_16 <= sq2 + sq6;
+      p26_m8 <= sq_pd_int8_msb_2 + sq_pd_int8_msb_6;
+    end
+    if (load_din_d & en_ge7) begin
+      p17_16 <= sq1 + sq7;
+      p17_m8 <= sq_pd_int8_msb_1 + sq_pd_int8_msb_7;
+    end
+    if (load_din_d & len9) begin
+      p08_16 <= sq0 + sq8;
+      p08_m8 <= sq_pd_int8_msb_0 + sq_pd_int8_msb_8;
+    end
   end
 end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_5x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d                   ))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    int16_sum_2_6 <= {34{1'b0}};
-  end else begin
-  if ((load_din_d & (len5|len7|len9)) == 1'b1) begin
-    int16_sum_2_6 <= (sq2[32:0] + sq6[32:0]);
-  // VCS coverage off
-  end else if ((load_din_d & (len5|len7|len9)) == 1'b0) begin
-  end else begin
-    int16_sum_2_6 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
-  end
-end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_6x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d & (len5|len7|len9)))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    int16_sum_1_7 <= {34{1'b0}};
-  end else begin
-  if ((load_din_d & (len7|len9)     ) == 1'b1) begin
-    int16_sum_1_7 <= (sq1[32:0] + sq7[32:0]);
-  // VCS coverage off
-  end else if ((load_din_d & (len7|len9)     ) == 1'b0) begin
-  end else begin
-    int16_sum_1_7 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
-  end
-end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_7x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d & (len7|len9)     ))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    int16_sum_0_8 <= {34{1'b0}};
-  end else begin
-  if ((load_din_d & (len9)          ) == 1'b1) begin
-    int16_sum_0_8 <= (sq0[32:0] + sq8[32:0]);
-  // VCS coverage off
-  end else if ((load_din_d & (len9)          ) == 1'b0) begin
-  end else begin
-    int16_sum_0_8 <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
-  end
-end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF_RESET_IS_X
-`endif // SYNTHESIS
-`endif // FV_ASSERT_ON
-`ifndef SYNTHESIS
-  // VCS coverage off 
-  nv_assert_no_x #(0,1,0,"No X's allowed on control signals")      zzz_assert_no_x_8x (nvdla_core_clk, `ASSERT_RESET, 1'd1,  (^(load_din_d & (len9)          ))); // spyglass disable W504 SelfDeterminedExpr-ML 
-  // VCS coverage on
-`endif
-`undef ASSERT_RESET
-`endif // ASSERT_ON
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass enable_block NoWidthInBasedNum-ML 
-// spyglass enable_block STARC-2.10.3.2a 
-// spyglass enable_block STARC05-2.1.3.1 
-// spyglass enable_block STARC-2.1.4.6 
-// spyglass enable_block W116 
-// spyglass enable_block W154 
-// spyglass enable_block W239 
-// spyglass enable_block W362 
-// spyglass enable_block WRN_58 
-// spyglass enable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
+
+// Length-masked 5-input 3:2 carry-save compression into a single accumulator flop
+wire use_26 = (reg2dp_normalz_len != 2'h0);
+wire use_17 = reg2dp_normalz_len[1];
+wire use_08 = (reg2dp_normalz_len == 2'h3);
+
+wire [36:0] t0_16 = {4'd0, sq4_d};
+wire [36:0] t1_16 = {3'd0, p35_16};
+wire [36:0] t2_16 = use_26 ? {3'd0, p26_16} : 37'd0;
+wire [36:0] t3_16 = use_17 ? {3'd0, p17_16} : 37'd0;
+wire [36:0] t4_16 = use_08 ? {3'd0, p08_16} : 37'd0;
+
+wire [36:0] csa1_s_16 = t0_16 ^ t1_16 ^ t2_16;
+wire [36:0] csa1_c_16 = ((t0_16 & t1_16) | (t0_16 & t2_16) | (t1_16 & t2_16)) << 1;
+wire [36:0] csa2_s_16 = csa1_s_16 ^ csa1_c_16 ^ t3_16;
+wire [36:0] csa2_c_16 = ((csa1_s_16 & csa1_c_16) | (csa1_s_16 & t3_16) | (csa1_c_16 & t3_16)) << 1;
+wire [36:0] csa3_s_16 = csa2_s_16 ^ csa2_c_16 ^ t4_16;
+wire [36:0] csa3_c_16 = ((csa2_s_16 & csa2_c_16) | (csa2_s_16 & t4_16) | (csa2_c_16 & t4_16)) << 1;
+
+wire [20:0] t0_m8 = {4'd0, msb4_d};
+wire [20:0] t1_m8 = {3'd0, p35_m8};
+wire [20:0] t2_m8 = use_26 ? {3'd0, p26_m8} : 21'd0;
+wire [20:0] t3_m8 = use_17 ? {3'd0, p17_m8} : 21'd0;
+wire [20:0] t4_m8 = use_08 ? {3'd0, p08_m8} : 21'd0;
+
+wire [20:0] csa1_s_m8 = t0_m8 ^ t1_m8 ^ t2_m8;
+wire [20:0] csa1_c_m8 = ((t0_m8 & t1_m8) | (t0_m8 & t2_m8) | (t1_m8 & t2_m8)) << 1;
+wire [20:0] csa2_s_m8 = csa1_s_m8 ^ csa1_c_m8 ^ t3_m8;
+wire [20:0] csa2_c_m8 = ((csa1_s_m8 & csa1_c_m8) | (csa1_s_m8 & t3_m8) | (csa1_c_m8 & t3_m8)) << 1;
+wire [20:0] csa3_s_m8 = csa2_s_m8 ^ csa2_c_m8 ^ t4_m8;
+wire [20:0] csa3_c_m8 = ((csa2_s_m8 & csa2_c_m8) | (csa2_s_m8 & t4_m8) | (csa2_c_m8 & t4_m8)) << 1;
+
+reg [36:0] int16_sum_r;
+reg [20:0] int8_msb_sum_r;
 
 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
-    sq4_d[32:0] <= {33{1'b0}};
-  end else begin
-  if ((load_din_d) == 1'b1) begin
-    sq4_d[32:0] <= (int8_en ? {16'd0,sq_pd_int8_lsb_4[16:0]} : sq_pd_int16_4[32:0]);
-  // VCS coverage off
-  end else if ((load_din_d) == 1'b0) begin
-  end else begin
-    sq4_d[32:0] <= 'bx;  // spyglass disable STARC-2.10.1.6 W443 NoWidthInBasedNum-ML -- (Constant containing x or z used, Based number `bx contains an X, Width specification missing for based number)
-  // VCS coverage on
-  end
+    int16_sum_r    <= 37'd0;
+    int8_msb_sum_r <= 21'd0;
+  end else if (load_din_2d) begin
+    int16_sum_r    <= csa3_s_16 + csa3_c_16;
+    int8_msb_sum_r <= csa3_s_m8 + csa3_c_m8;
   end
 end
-`ifdef SPYGLASS_ASSERT_ON
-`else
-// spyglass disable_block NoWidthInBasedNum-ML 
-// spyglass disable_block STARC-2.10.3.2a 
-// spyglass disable_block STARC05-2.1.3.1 
-// spyglass disable_block STARC-2.1.4.6 
-// spyglass disable_block W116 
-// spyglass disable_block W154 
-// spyglass disable_block W239 
-// spyglass disable_block W362 
-// spyglass disable_block WRN_58 
-// spyglass disable_block WRN_61 
-`endif // SPYGLASS_ASSERT_ON
-`ifdef ASSERT_ON
-`ifdef FV_ASSERT_ON
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef SYNTHESIS
-`define ASSERT_RESET nvdla_core_rstn
-`else
-`ifdef ASSERT_OFF_RESET_IS_X
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b0 : nvdla_core_rstn)
-`else
-`define ASSERT_RESET ((1'bx === nvdla_core_rstn) ? 1'b1 : nvdla_core_rstn)
-`endif // ASSERT_OFF
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/AN2D4PO4.v`](environment/public/code/AN2D4PO4.v) *(Read-Only Context)*
- [`environment/public/code/CKLNQD12PO4.v`](environment/public/code/CKLNQD12PO4.v) *(Read-Only Context)*
- [`environment/public/code/HLS_cdp_icvt.v`](environment/public/code/HLS_cdp_icvt.v) *(Read-Only Context)*
- [`environment/public/code/HLS_cdp_ocvt.v`](environment/public/code/HLS_cdp_ocvt.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp16_to_fp17.v`](environment/public/code/HLS_fp16_to_fp17.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp16_to_fp32.v`](environment/public/code/HLS_fp16_to_fp32.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp17_add.v`](environment/public/code/HLS_fp17_add.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp17_mul.v`](environment/public/code/HLS_fp17_mul.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp17_to_fp32.v`](environment/public/code/HLS_fp17_to_fp32.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp32_add.v`](environment/public/code/HLS_fp32_add.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp32_mul.v`](environment/public/code/HLS_fp32_mul.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp32_sub.v`](environment/public/code/HLS_fp32_sub.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp32_to_fp17.v`](environment/public/code/HLS_fp32_to_fp17.v) *(Read-Only Context)*
- [`environment/public/code/HLS_uint16_to_fp17.v`](environment/public/code/HLS_uint16_to_fp17.v) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/LNQD1PO4.v`](environment/public/code/LNQD1PO4.v) *(Read-Only Context)*
- [`environment/public/code/NV_BLKBOX_BUFFER.v`](environment/public/code/NV_BLKBOX_BUFFER.v) *(Read-Only Context)*
- [`environment/public/code/NV_BLKBOX_SINK.v`](environment/public/code/NV_BLKBOX_SINK.v) *(Read-Only Context)*
- [`environment/public/code/NV_BLKBOX_SRC0.v`](environment/public/code/NV_BLKBOX_SRC0.v) *(Read-Only Context)*
- [`environment/public/code/NV_BLKBOX_SRC0_X.v`](environment/public/code/NV_BLKBOX_SRC0_X.v) *(Read-Only Context)*
- [`environment/public/code/NV_CLK_gate_power.v`](environment/public/code/NV_CLK_gate_power.v) *(Read-Only Context)*
- [`environment/public/code/NV_HWACC_NVDLA_tick_defines.vh`](environment/public/code/NV_HWACC_NVDLA_tick_defines.vh) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_INTP_unit.v`](environment/public/code/NV_NVDLA_CDP_DP_INTP_unit.v) **(Editable)**
- [`environment/public/code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v`](environment/public/code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v) **(Editable)**
- [`environment/public/code/NV_NVDLA_CDP_DP_LUT_ctrl.v`](environment/public/code/NV_NVDLA_CDP_DP_LUT_ctrl.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_MUL_unit.v`](environment/public/code/NV_NVDLA_CDP_DP_MUL_unit.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_bufferin.v`](environment/public/code/NV_NVDLA_CDP_DP_bufferin.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_cvtin.v`](environment/public/code/NV_NVDLA_CDP_DP_cvtin.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_cvtout.v`](environment/public/code/NV_NVDLA_CDP_DP_cvtout.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_intp.v`](environment/public/code/NV_NVDLA_CDP_DP_intp.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_lut.v`](environment/public/code/NV_NVDLA_CDP_DP_lut.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_mul.v`](environment/public/code/NV_NVDLA_CDP_DP_mul.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_sum.v`](environment/public/code/NV_NVDLA_CDP_DP_sum.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_DP_syncfifo.v`](environment/public/code/NV_NVDLA_CDP_DP_syncfifo.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CDP_dp.v`](environment/public/code/NV_NVDLA_CDP_dp.v) *(Read-Only Context)*
- [`environment/public/code/RAMDP_20X80_GL_M1_E2.v`](environment/public/code/RAMDP_20X80_GL_M1_E2.v) *(Read-Only Context)*
- [`environment/public/code/RAMDP_80X15_GL_M2_E2.v`](environment/public/code/RAMDP_80X15_GL_M2_E2.v) *(Read-Only Context)*
- [`environment/public/code/RAMPDP_60X168_GL_M1_D2.v`](environment/public/code/RAMPDP_60X168_GL_M1_D2.v) *(Read-Only Context)*
- [`environment/public/code/RAMPDP_80X72_GL_M1_D2.v`](environment/public/code/RAMPDP_80X72_GL_M1_D2.v) *(Read-Only Context)*
- [`environment/public/code/SDFCNQD1.v`](environment/public/code/SDFCNQD1.v) *(Read-Only Context)*
- [`environment/public/code/SDFQD1.v`](environment/public/code/SDFQD1.v) *(Read-Only Context)*
- [`environment/public/code/SDFSNQD1.v`](environment/public/code/SDFSNQD1.v) *(Read-Only Context)*
- [`environment/public/code/ScanShareSel_JTAG_reg_ext_cg.v`](environment/public/code/ScanShareSel_JTAG_reg_ext_cg.v) *(Read-Only Context)*
- [`environment/public/code/fp_format_cvt.v`](environment/public/code/fp_format_cvt.v) *(Read-Only Context)*
- [`environment/public/code/fp_sum_block.v`](environment/public/code/fp_sum_block.v) *(Read-Only Context)*
- [`environment/public/code/int_sum_block.v`](environment/public/code/int_sum_block.v) **(Editable)**
- [`environment/public/code/nv_assert_no_x.vlib`](environment/public/code/nv_assert_no_x.vlib) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_19x80.v`](environment/public/code/nv_ram_rwsthp_19x80.v) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_19x80_logic.v`](environment/public/code/nv_ram_rwsthp_19x80_logic.v) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_60x168.v`](environment/public/code/nv_ram_rwsthp_60x168.v) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_60x168_logic.v`](environment/public/code/nv_ram_rwsthp_60x168_logic.v) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_80x15.v`](environment/public/code/nv_ram_rwsthp_80x15.v) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_80x15_logic.v`](environment/public/code/nv_ram_rwsthp_80x15_logic.v) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_80x72.v`](environment/public/code/nv_ram_rwsthp_80x72.v) *(Read-Only Context)*
- [`environment/public/code/nv_ram_rwsthp_80x72_logic.v`](environment/public/code/nv_ram_rwsthp_80x72_logic.v) *(Read-Only Context)*
- [`environment/public/code/p_SDFCNQD1PO4.v`](environment/public/code/p_SDFCNQD1PO4.v) *(Read-Only Context)*
- [`environment/public/code/p_SSYNC2DO_C_PP.v`](environment/public/code/p_SSYNC2DO_C_PP.v) *(Read-Only Context)*
- [`environment/public/code/simulate_x_tick.vh`](environment/public/code/simulate_x_tick.vh) *(Read-Only Context)*
- [`environment/public/code/sync2d_c_pp.v`](environment/public/code/sync2d_c_pp.v) *(Read-Only Context)*
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

