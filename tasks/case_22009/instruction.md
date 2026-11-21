# case_22009: RedMulE Systolic Wave-Front Small-Tile Promotion, Leftover Boundary Synchronization, and Multi-Pass Loopback Scheduling

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/redmule` (`repo_30`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/redmule_tiler.sv`, `code/redmule_scheduler.sv`, `code/redmule_memory_scheduler.sv`

---

## Problem Specification

# Systolic Tiling, Boundary Scheduling, and Multi-Job Queue Hazards in RedMulE

## Architecture & Functional Contract

`code/redmule_subsys.sv` integrates the RedMulE FP16 systolic matrix-multiplication and GEMM subsystem (`DataW = 128`, `FpFormat = FP16`, `Width = 4`, `Height = 4`, `NumPipeRegs = 1`, `PipeConfig = DISTRIBUTED`, `8` FP16 elements / `16` bytes per memory beat). Its lockstep `Width x Height` engine is coordinated by `code/redmule_tiler.sv`, `code/redmule_memory_scheduler.sv`, and `code/redmule_scheduler.sv`.

For arbitrary matrix dimensions `M >= 1` (`m_size`), `N >= 1` (`n_size`), and `K >= 1` (`k_size`), the subsystem computes row-major FP16 `MATMUL` (`Z = X * W`, `gemm_selection == 1'b0`) or `GEMM` (`Z = X * W + Y`, `gemm_selection == 1'b1`) under round-to-nearest-even (`RNE`) accumulation:
- **Memory layout** (2 bytes per FP16 element): `X` (`M x N`, row stride `2*N` at `x_addr`), `W` (`N x K`, row stride `2*K` at `w_addr`), `Y` (`M x K`, row stride `2*K` at `y_addr` when `gemm_selection == 1'b1`), and `Z` (`M x K`, row stride `2*K` at `z_addr`).
- **Two-pass weight loopback (`w_cols_offset`)**: When `w_cols_offset == 0`, all `K` columns run in a single pass. When `0 < w_cols_offset < K` (a multiple of `8`), Pass 0 computes columns `[w_cols_offset .. K - 1]` (offset by `+2 * w_cols_offset` bytes in `W`, `Y`, `Z`) and Pass 1 computes columns `[0 .. w_cols_offset - 1]` from base addresses before retiring the job.
- **Boundary & strobe safety**: Live TCDM regions sit immediately adjacent to `W` and `Z`. Padded systolic rows/columns beyond `(M, N, K)` must never corrupt accumulation with out-of-bounds memory data, `z_stream_strb_o` must enable only valid column bytes `[0 .. K - 1]`, and store transfers must never write rows `>= M` when `M % Width != 0`.
- **Stalls, queued jobs, & clear**: Under arbitrary stream/handshake backpressure and back-to-back job queuing in `i_config_fifo` (including across `loopback_w` and leftover tiles), each job must pulse `done_o` once after its final `Z` beat drains without cross-job config corruption or empty-FIFO pops. Asserting `target_clear_i` mid-job must synchronously reset control/queue state so subsequent jobs run cleanly.

## Problem Statement

Across small and non-multiple matrix dimensions (`1 <= N <= 4`, `N % Height != 0`, `M % Width != 0`, odd/leftover `K`), `GEMM` bias preloads, two-pass `w_cols_offset` loopback, back-to-back queued descriptors, and mid-job `target_clear_i` resets, the subsystem currently suffers from systolic wave-front hangs, out-of-bounds weight/output corruption, store-strobe misalignment, and configuration-queue hazards. Fix the control, tiling, and memory-scheduling logic so all single-job and back-to-back queued `MATMUL`/`GEMM` workloads pass end-to-end.

## Deliverable Constraints

- Modify **only** `code/redmule_tiler.sv`, `code/redmule_scheduler.sv`, and `code/redmule_memory_scheduler.sv`.
- Keep all module names, parameter lists, port signatures, and other files under `code/` unchanged.
- Strictly synthesizable synchronous RTL (`yosys -m slang` elaboration with zero inferred latches and no simulator-specific macro divergence).

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Guide

## Available Tools

The workspace environment provides the following EDA tools:

- **Verilator v5.038**: `verilator`
- **Yosys (with `slang` SystemVerilog frontend)**: `yosys`

## RTL File Compilation Order

All package headers, common cells, buffers, datapath units, and subsystem RTL reside in `code/` (with macro headers in `code/include/`):

```bash
RTL_FILES=(
  code/fpnew_pkg.sv
  code/cf_math_pkg.sv
  code/hci_package.sv
  code/hwpe_ctrl_package.sv
  code/hwpe_stream_package.sv
  code/redmule_pkg.sv
  code/tc_clk.sv
  code/edge_detect.sv
  code/sync.sv
  code/sync_wedge.sv
  code/lzc.sv
  code/hwpe_stream_fifo.sv
  code/fpnew_classifier.sv
  code/fpnew_rounding.sv
  code/redmule_fma.sv
  code/redmule_row.sv
  code/redmule_engine.sv
  code/x_buffer/redmule_x_pad_scm.sv
  code/x_buffer/redmule_x_buffer_scm.sv
  code/x_buffer/redmule_x_buffer.sv
  code/w_buffer/redmule_w_buffer_scm.sv
  code/w_buffer/redmule_w_buffer.sv
  code/z_buffer/redmule_z_buffer_scm.sv
  code/z_buffer/redmule_z_buffer.sv
  code/redmule_config_fifo.sv
  code/redmule_ctrl.sv
  code/redmule_tiler.sv
  code/redmule_memory_scheduler.sv
  code/redmule_scheduler.sv
  code/redmule_subsys.sv
)
```

## Lint & Simulation with Verilator

To lint the full `redmule_subsys` hierarchy:

```bash
verilator \
  --lint-only -Wno-fatal -Wno-TIMESCALEMOD \
  -Icode/include \
  --top-module redmule_subsys \
  "${RTL_FILES[@]}"
```

To build and run your own SystemVerilog testbench (for example in `/tmp/my_tb.sv`):

```bash
verilator \
  --binary -j 4 -O1 -CFLAGS "-O0" \
  -Wno-fatal -Wno-TIMESCALEMOD \
  -Icode/include \
  --top-module my_tb \
  --Mdir /tmp/obj_dir \
  "${RTL_FILES[@]}" /tmp/my_tb.sv

/tmp/obj_dir/Vmy_tb
```

> **Note**: Keep any scratch testbenches or build directories outside `code/` (or clean them up before finishing); only `code/redmule_tiler.sv`, `code/redmule_scheduler.sv`, and `code/redmule_memory_scheduler.sv` are collected for grading.

## Synthesis & Zero-Latch Elaboration Check (`yosys -m slang`)

Verify that the subsystem elaborates cleanly with zero unintended latches (`$dlatch`):

```bash
yosys -m slang -p "
  read_slang --top redmule_subsys --keep-hierarchy --allow-use-before-declare --ignore-assertions -Wno-range-oob -I code/include ${RTL_FILES[*]};
  hierarchy -check -top redmule_subsys;
  blackbox *tc_clk_gating*;
  proc;
  opt_clean;
  check;
  select -assert-none t:\$dlatch
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/redmule_tiler.sv`
- `code/redmule_scheduler.sv`
- `code/redmule_memory_scheduler.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
