# case_23006: Implement Multi-Precision 1D Pooling, Split-Stripe Tiling, Pad Compensation, and FP16 NaN Preprocessor in NVDLA PDP

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `nvdla/hw` (`repo_36`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/NV_NVDLA_PDP_nan.v`, `code/NV_NVDLA_PDP_CORE_unit1d.v`, `code/NV_NVDLA_PDP_CORE_cal1d.v`

---

## Problem Specification

# Multi-Precision 1D Spatial Pooling, Split-Stripe Tiling, and FP16 NaN Preprocessor (`NV_NVDLA_PDP`)

In NVIDIA Deep Learning Accelerator (`nvdla/hw`), the Planar Data Processor horizontal (`1D`) pooling pipeline (`code/NV_NVDLA_PDP_nan.v`, `code/NV_NVDLA_PDP_CORE_unit1d.v`, and `code/NV_NVDLA_PDP_CORE_cal1d.v`) streams 32-byte feature-map surfaces from either offline `PDP_RDMA` (`reg2dp_flying_mode == 1'b1`) or on-the-fly `SDP` (`reg2dp_flying_mode == 1'b0`) and emits horizontally pooled results on `pooling1d_pvld` / `pooling1d_prdy` / `pooling1d_pd[111:0]`. Complete the RTL implementation across these three modules while preserving all module port interfaces and read-only `HLS_fp16_to_fp17` / `HLS_fp17_add` / `cal1d_fp16_pool_sum` instantiations:

1. **Stream Framing & Output Packing**:
   - Each spatial pixel is transferred over 4 consecutive 8-byte channel sub-beats (`pd[63:0]`, with `pd[66:64] = cpos` in `0..3`, `pd[71] = bsync`, `pd[72] = line_end`, `pd[73] = surf_end`, `pd[74] = split_end`, `pd[75] = cube_end`).
   - Support `reg2dp_input_data` in `2'h0` (`INT8`, 8 signed bytes/beat -> `pooling1d_pd` packs 8 x 14-bit sign-extended lanes), `2'h1` (`INT16`, 4 signed halfwords/beat -> 4 x 28-bit sign-extended lanes), and `2'h2` (`FP16` IEEE-754 binary16, 4 lanes/beat -> 4 x 28-bit sign-extended `FP16` lanes for `MAX`/`MIN`, or 4 x 28-bit zero-extended 17-bit `HLS_fp17` sums `{11'd0, fp17[16:0]}` for `AVE`).
   - Support `pooling_type_cfg` in `2'h0` (`POOL_METHOD_AVE`: sum accumulation plus pad-value compensation), `2'h1` (`POOL_METHOD_MAX`), and `2'h2` (`POOL_METHOD_MIN`) across kernel widths `1..8` (`pooling_size_h_cfg = K - 1`) and horizontal strides `1..8` (both overlapping `K >= S` and non-overlapping `S > K`).

2. **Offline RDMA Layer Gating, FP16 NaN Flush, & Ping-Pong Telemetry (`NV_NVDLA_PDP_nan.v`)**:
   - Gate `pdp_rdma2dp_ready` low out of reset, throughout flying SDP layers (`reg2dp_flying_mode == 1'b0`), and between offline layers; arm RDMA acceptance on `reg2dp_op_en` when `reg2dp_flying_mode == 1'b1` until the final beat of the cube (`cube_end && bsync`) handshakes.
   - In `FP16` mode (`2'h2`), detect per-lane IEEE-754 NaNs and Infinities; when `reg2dp_nan_to_zero == 1'b1`, replace `FP16` NaN lanes with `+0.0` (`16'h0000`) on `nan_preproc_pd` while passing `INT8`/`INT16` payloads and non-NaN `FP16` values (`+/-Inf`, subnormals, signed zeros) untouched.
   - Accumulate per-layer input `FP16` NaN and Infinity element counts across accepted beats (latching into alternating 2-entry ping-pong register banks at cube completion and resetting for the next layer) and present the corresponding completed layer's counts on `dp2reg_nan_input_num` / `dp2reg_inf_input_num` upon each `dp2reg_done` pulse.

3. **Multi-Precision Window Reduction & FP16 NaN Propagation (`NV_NVDLA_PDP_CORE_unit1d.v`, `NV_NVDLA_PDP_CORE_cal1d.v`)**:
   - Reduce horizontal windows independently per channel across all 4 `cpos` sub-beats without inter-lane bleed in dual-byte `INT8` slices, using IEEE-754 sign-magnitude ordering in `FP16` `MAX`/`MIN` with NaN propagation when un-flushed NaNs enter a window (`reg2dp_nan_to_zero == 1'b0`), and left-to-right `FP17` accumulation in `FP16` `AVE`.
   - Maintain coherent per-sub-beat window state across back-to-back pixels and immediate output reads, and drain all right-padded trailing windows in spatial order at line, stripe, and final-cube boundaries (including narrow lines where `width + pad_left < K`).

4. **Horizontal Split-Stripe (`splitw`) Tiling & `AVE` Pad Compensation (`NV_NVDLA_PDP_CORE_cal1d.v`)**:
   - Support both single-pass (`pooling_splitw_num_cfg == 0`) and multi-stripe (`pooling_splitw_num_cfg > 0`: first stripe `fwidth` with left pad only, middle stripes `mwidth` with zero pad and `|K - S|` stripe-overlap width adjustment, last stripe `lwidth` with right pad and `|K - S|` overlap adjustment) horizontal tiling.
   - In `AVE` mode (`2'h0`), compensate boundary windows containing $m \in [1, 7]$ padded positions using `reg2dp_pad_value_1x_cfg` .. `reg2dp_pad_value_7x_cfg` across `INT8`, `INT16`, and `FP16` (`HLS_fp17_add`) before packing `pooling1d_pd`. Do not apply pad-value offsets in `MAX` or `MIN` modes.

5. **Synthesis & Backpressure Signoff**:
   - Must sustain arbitrary upstream/downstream `pvld`/`prdy` stalls without dropping or duplicating beats, and elaborate cleanly in `yosys` (`NV_NVDLA_PDP_nan` and `NV_NVDLA_PDP_CORE_cal1d`) with zero inferred latches (`$dlatch*`) and zero combinational loops.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Synthesis Guide

## Workspace Layout

- **Editable RTL files**:
  - `code/NV_NVDLA_PDP_nan.v`
  - `code/NV_NVDLA_PDP_CORE_unit1d.v`
  - `code/NV_NVDLA_PDP_CORE_cal1d.v`
- **Read-only NVDLA helper & HLS arithmetic files** (do **not** modify):
  - `code/HLS_fp16_to_fp17.v` (4-stage pipelined IEEE-754 FP16 -> internal FP17 converter)
  - `code/HLS_fp17_add.v` (4-stage pipelined internal FP17 adder)
  - `code/cal1d_fp16_pool_sum.v` (4-lane synchronized `HLS_fp17_add` wrapper used by `unit1d`)
  - `code/NV_CLK_gate_power.v`, `code/CKLNQD12.v`, `code/NV_BLKBOX_SINK.v`
  - `code/NV_HWACC_NVDLA_tick_defines.vh`, `code/simulate_x_tick.vh`, `code/LICENSE`

---

## Tool Commands

### 1. Fast Compile & Simulation with Icarus Verilog (`iverilog -g2012`)

```bash
iverilog -g2012 -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -Icode \
  -s <your_tb_top> -o /tmp/pdp_sim.vvp \
  code/NV_BLKBOX_SINK.v \
  code/CKLNQD12.v \
  code/NV_CLK_gate_power.v \
  code/HLS_fp16_to_fp17.v \
  code/HLS_fp17_add.v \
  code/cal1d_fp16_pool_sum.v \
  code/NV_NVDLA_PDP_nan.v \
  code/NV_NVDLA_PDP_CORE_unit1d.v \
  code/NV_NVDLA_PDP_CORE_cal1d.v \
  <your_tb.sv>

vvp /tmp/pdp_sim.vvp
```

### 2. Verilator Lint / Binary Simulation

```bash
verilator --lint-only -Wall -Wno-fatal \
  -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -Icode \
  --top-module NV_NVDLA_PDP_CORE_cal1d \
  code/NV_BLKBOX_SINK.v \
  code/CKLNQD12.v \
  code/NV_CLK_gate_power.v \
  code/HLS_fp16_to_fp17.v \
  code/HLS_fp17_add.v \
  code/cal1d_fp16_pool_sum.v \
  code/NV_NVDLA_PDP_nan.v \
  code/NV_NVDLA_PDP_CORE_unit1d.v \
  code/NV_NVDLA_PDP_CORE_cal1d.v
```

### 3. Yosys Elaboration & Latch-Free Synthesis Check (Mandatory Signoff Gate)

Both `NV_NVDLA_PDP_nan` and `NV_NVDLA_PDP_CORE_cal1d` must elaborate with zero inferred latches (`$dlatch*`) and zero combinational loops:

```bash
for TOP in NV_NVDLA_PDP_nan NV_NVDLA_PDP_CORE_cal1d; do
  yosys -q -p "
    read_verilog -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -DVLIB_BYPASS_POWER_CG -Icode \
      code/NV_BLKBOX_SINK.v code/CKLNQD12.v code/NV_CLK_gate_power.v \
      code/HLS_fp16_to_fp17.v code/HLS_fp17_add.v code/cal1d_fp16_pool_sum.v \
      code/NV_NVDLA_PDP_nan.v code/NV_NVDLA_PDP_CORE_unit1d.v code/NV_NVDLA_PDP_CORE_cal1d.v;
    hierarchy -check -top ${TOP};
    proc; opt_clean;
    check -assert;
    select -assert-none */t:\$dlatch*
  "
done
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/NV_NVDLA_PDP_nan.v`
- `code/NV_NVDLA_PDP_CORE_unit1d.v`
- `code/NV_NVDLA_PDP_CORE_cal1d.v`

All other files in the workspace are read-only reference context and must remain unmodified.
