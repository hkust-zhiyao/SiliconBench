# case_23015: NVDLA CDP LRN Sliding-Window Sum, Dual-LUT Indexer & Piecewise-Linear Interpolator PPA/STA Signoff

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `nvdla/hw` (`repo_36`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/int_sum_block.v`, `code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v`, `code/NV_NVDLA_CDP_DP_INTP_unit.v`

---

## Problem Specification

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

## Build, Simulation, and EDA Verification Instructions

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

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/int_sum_block.v`
- `code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v`
- `code/NV_NVDLA_CDP_DP_INTP_unit.v`

All other files in the workspace are read-only reference context and must remain unmodified.
