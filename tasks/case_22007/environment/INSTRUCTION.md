# case_22007: RedMulE Input Feature Buffer Parameterized Elaboration, Multi-Tile Padding, and 4-State Gate-Level Parity

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/redmule` (`repo_30`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/x_buffer/redmule_x_buffer.sv`, `code/x_buffer/redmule_x_buffer_scm.sv`, `code/x_buffer/redmule_x_pad_scm.sv`

---

## Problem Specification

# RedMulE Input Feature Buffer (`redmule_x_buffer`) Parameterized Synthesis, Padding, and Gate-Level Parity

## Context
`redmule_x_buffer` (`code/x_buffer/redmule_x_buffer.sv`) and its standard-cell memory (SCM) submodules (`code/x_buffer/redmule_x_pad_scm.sv` and `code/x_buffer/redmule_x_buffer_scm.sv`) buffer and transpose incoming TCDM words (`x_buffer_i`, width `DataW`) into `Width x Height` elements (`x_buffer_o`) for RedMulE's systolic array.

Each tile is loaded row-by-row (`0 .. ctrl_i.width - 1`) into the pad SCM (`Width` rows by `TOT_DEPTH = Height * D` columns, where `D = DataW / (Height * FpWidth)`) under `ctrl_i.load`, asserting `flags_o.full` once `ctrl_i.width` rows are loaded. After `ctrl_i.pad_setup` starts a job, `ctrl_i.slots` columns (a positive multiple of `Height` up to `TOT_DEPTH`) drain into the `2 * Height`-entry output buffer, which shifts one systolic lane per `ctrl_i.h_shift` cycle onto `x_buffer_o[w][h]`. When the final column of the active tile transfers out of the pad buffer, `flags_o.empty` pulses on an active `ctrl_i.h_shift` cycle so the scheduler can update `(ctrl_i.width, ctrl_i.height, ctrl_i.slots)` and preload the next tile after `ctrl_i.rst_w_index`.

## Observed Failures
Multi-configuration regression and post-synthesis 4-state gate-level simulation across `UseLatches = 0` and `UseLatches = 1` expose four issues:
1. **Parameterized Elaboration Failures**: Valid configurations with unit dimensions or single-block depth (`Width == 1`, `Height == 1`, or `D == 1`, with `1 <= Width < MaxDim` and `1 <= TOT_DEPTH < MaxDepth`) fail elaboration/synthesis.
2. **Multi-Tile Streaming & Backpressure Breakdown**: Across single-block (`D == 1`) and deep multi-block (`D >= 3`) configurations under variable `ctrl_i.h_shift`, `ctrl_i.load`, and `ctrl_i.rst_w_index` schedules (including preloaded back-to-back tiles), unread columns are overwritten or tile transitions stall / mis-pulse `flags_o.empty`.
3. **Partial-Tile Zero-Padding Leakage**: Partial tiles (`1 <= ctrl_i.width < Width` and/or `0 <= ctrl_i.height < ctrl_i.slots`) leak stale or uninitialized data onto padded rows (`w >= loaded_width`) or columns (`c >= ctrl_i.height`) across tile drains.
4. **Clear Priority & 4-State `X` Propagation**: Simultaneous `clear_i` with `ctrl_i.load` / `ctrl_i.h_shift` fails to cleanly reset state, and unwritten SCM locations or idle `X` inputs on `x_buffer_i` propagate `X`/`Z` onto `flags_o` and `x_buffer_o` in 4-state post-synthesis gate-level simulation.

## Requirements
Modify only `code/x_buffer/redmule_x_buffer.sv`, `code/x_buffer/redmule_x_buffer_scm.sv`, and `code/x_buffer/redmule_x_pad_scm.sv` (preserving all module port signatures and read-only packages) so that:
- All valid `(DataW, FpFormat, Height, Width, UseLatches)` configurations elaborate and synthesize cleanly in `verilator` and `yosys -m slang` (`check -assert`), including `Height == 1`, `Width == 1`, `D == 1`, and `D >= 3`.
- `UseLatches = 0` synthesizes completely latch-free flip-flop storage, while `UseLatches = 1` preserves `tc_clk_gating` latch-based SCM storage.
- Multi-tile jobs with arbitrary per-tile `(width, height, slots)`, random load/shift stalls, partial row/column zero-padding, asynchronous reset (`!rst_ni`), and synchronous `clear_i` match across RTL and 4-state gate-level simulation with zero `X`/`Z` on `flags_o` or `x_buffer_o`.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment

## Source Files (`code/`)
- Packages & clock gate cell (read-only):
  - `code/fpnew_pkg.sv`
  - `code/hci_package.sv`
  - `code/hwpe_ctrl_package.sv`
  - `code/hwpe_stream_package.sv`
  - `code/redmule_pkg.sv`
  - `code/tc_clk.sv`
- Target RTL modules (editable):
  - `code/x_buffer/redmule_x_pad_scm.sv`
  - `code/x_buffer/redmule_x_buffer_scm.sv`
  - `code/x_buffer/redmule_x_buffer.sv`

## Available Toolchain Commands
1. **SystemVerilog Lint & Functional Simulation (`verilator`)**:
   ```bash
   verilator --lint-only -Wall -Wno-fatal \
     code/fpnew_pkg.sv code/hci_package.sv code/hwpe_ctrl_package.sv \
     code/hwpe_stream_package.sv code/redmule_pkg.sv code/tc_clk.sv \
     code/x_buffer/redmule_x_pad_scm.sv code/x_buffer/redmule_x_buffer_scm.sv \
     code/x_buffer/redmule_x_buffer.sv --top-module redmule_x_buffer
   ```

2. **Elaboration & Gate-Level Synthesis (`yosys -m slang`)**:
   ```bash
   yosys -m slang -p "
     read_slang --top redmule_x_buffer -GHeight=4 -GWidth=4 -GDataW=256 -GUseLatches=1 \
       code/fpnew_pkg.sv code/hci_package.sv code/hwpe_ctrl_package.sv \
       code/hwpe_stream_package.sv code/redmule_pkg.sv code/tc_clk.sv \
       code/x_buffer/redmule_x_pad_scm.sv code/x_buffer/redmule_x_buffer_scm.sv \
       code/x_buffer/redmule_x_buffer.sv;
     synth -top redmule_x_buffer;
     check -assert;
     write_verilog -noattr netlist_lat1.v
   "
   ```

3. **4-State Gate-Level Simulation (`iverilog` + Yosys `simcells.v`)**:
   ```bash
   SIMCELLS="$(dirname "$(dirname "$(which yosys)")")/share/yosys/simcells.v"
   iverilog -g2012 -o gl_sim.vvp "$SIMCELLS" netlist_lat1.v your_gl_tb.sv
   vvp gl_sim.vvp
   ```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/x_buffer/redmule_x_buffer.sv`
- `code/x_buffer/redmule_x_buffer_scm.sv`
- `code/x_buffer/redmule_x_pad_scm.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
