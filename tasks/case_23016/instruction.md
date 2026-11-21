# case_23016: Vortex Hopper-Style WGMMA & 2:4 Sparse Tensor Core Tile-Buffer Coherence, FIFO Retirement & PPA/STA Signoff

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `vortexgpgpu/vortex` (`repo_37`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/VX_tcu_uops.sv`, `code/VX_tcu_abuf.sv`, `code/VX_tcu_bbuf.sv`, `code/VX_tcu_core.sv`

---

## Problem Specification

# Vortex Hopper-Style WGMMA & 2:4 Sparse Tensor Core Subsystem Coherence, Retirement & PPA Signoff

## Context
`public/code/` contains the standalone RTL closure of the Vortex GPGPU Tensor Core subsystem (`VX_tcu_subsys`), integrating micro-op expansion (`VX_uop_sequencer` + `VX_tcu_uops`), Hopper-style Warp-Group MMA shared-memory tile buffers (`VX_tcu_wgmma` + `VX_tcu_tbuf` + `VX_tcu_abuf` + `VX_tcu_bbuf` + `VX_tcu_lockstep`), warp-indexed 2:4 structured-sparsity metadata/gather logic (`VX_tcu_meta` + `VX_tcu_sp_mux`), and the pipelined dot-product execution core (`VX_tcu_core` + `VX_tcu_fedp_tfr`).

Currently, the four core WGMMA/TCU control and tile-buffer RTL modules exhibit an IEEE 1800-2017 elaboration violation, shared-memory straddling/coherency defects, an out-of-order retirement hazard under commit backpressure, 4-state gate-level reset `X`-propagation hangs, and excessive Nangate45 cell area (~`89k um^2`).

## Editable Files
You may modify **only** the following files (all other files in `code/` and `lib/` are read-only):
- `code/VX_tcu_uops.sv` (`module VX_tcu_uops`)
- `code/VX_tcu_abuf.sv` (`module VX_tcu_abuf`)
- `code/VX_tcu_bbuf.sv` (`module VX_tcu_bbuf`)
- `code/VX_tcu_core.sv` (`module VX_tcu_core`)

## Architectural, Protocol & Multi-Configuration Contract
Your implementation must preserve full functional parity across both parameterized subsystem configurations:
- **`CFG_F2K_1B`**: `-DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_FEDP2K` (`TCU_WG_FEDP_K = 4`, `TCU_WG_K_STEPS = 1`)
- **`CFG_NOF2K_2B`**: `-DVX_CFG_NUM_TCU_BLOCKS=2 -DNO_FEDP2K` (`TCU_WG_FEDP_K = 2`, `TCU_WG_K_STEPS = 2`)
(both with `-DXLEN_32 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_LMEM_NUM_BANKS=8 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE`)

1. **WMMA & Hopper WGMMA Micro-Op Expansion (`VX_tcu_uops`)**:
   - Preserve exact warp-level `WMMA` (`INST_TCU_WMMA`) and 2:4 sparse `WMMA_SP` (`INST_TCU_WMMA_SP`) expansion across `FP16`/`BF16 -> FP32` and `INT8`/`UINT8`/`INT4`/`UINT4 -> INT32`.
   - Expand dense `WGMMA` (`INST_TCU_WGMMA`) and 2:4 sparse `WGMMA_SP` (`INST_TCU_WGMMA_SP`) across `cd_nregs in {0, 1, 2}` (`8`, `16`, or `32` accumulator `f`-registers), register-sourced (`a_from_smem == 0`, `RS`) and shared-memory-sourced (`a_from_smem == 1`, `SS`) A operands, `FEDP2K` vs non-`FEDP2K` K-steps, and exact `fu_lock`/`fu_unlock` / first-compute / last-uop signaling.
2. **Shared-Memory Tile Layout, Sub-Row Offsets & Bank-Row Straddling (`VX_tcu_abuf`, `VX_tcu_bbuf`)**:
   - Decode 32-bit shared-memory descriptors in `x10` (A) and `x11` (B), where `[15:0]` is the word-aligned byte base address and `[31:16]` is the word-aligned byte leading-dimension stride (`0` selects padded 8-bank-row-aligned block-major layout; non-zero selects row-major A / K-major B strided layout).
   - Support arbitrary word-aligned sub-bank-row base offsets (`(base_bytes >> 2) % NUM_BANKS != 0`) and arbitrary word-aligned strides, accurately fetching and assembling slices that straddle two consecutive 8-word LMEM bank rows for both dense and 2:4 sparse tiles under variable LMEM request backpressure and response latency.
3. **Tile-Buffer Cache Coherency & Multi-Block Lockstep (`VX_tcu_abuf`, `VX_tcu_bbuf`)**:
   - Reuse resident A-stripes and B-tiles within a WGMMA macro-instruction burst while guaranteeing fresh LMEM refills across layout switches (`K-major <-> block-major`), in-place shared-memory updates between consecutive WGMMA macro-instructions at identical descriptor addresses, and `cta_id`/warp transitions across single- and dual-block lockstep execution.
4. **Strict Per-Block FIFO Retirement Under Backpressure (`VX_tcu_core`)**:
   - Every micro-op accepted on `uop_fire[b]`—including `wb == 0` WGMMA descriptor-setup micro-ops issued immediately after older compute micro-ops—must retire on `res_valid[b] && res_ready[b]` in strict per-block FIFO order without bypassing older in-flight or landing-buffer-parked compute results when `res_ready[b]` stalls.

## Synthesis, 4-State Gate-Level Hygiene & Nangate45 PPA/STA Targets
Evaluated on `VX_tcu_subsys` under `-DXLEN_32 -DTCU_SYNTH_BND -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=2 -DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE -DVX_CFG_TCU_FEDP2K -DVX_CFG_LMEM_NUM_BANKS=8`:
- **IEEE 1800-2017 Synthesis & 4-State Gate-Level Hygiene**: Must elaborate cleanly in `yosys -m slang` (`read_slang`, strict declare-before-use) with zero inferred latches (`$dlatch*` / `$_DLATCH_*`), zero combinational loops (`scc -expect 0`), and deterministic `X`-free post-reset handshakes and committed results in 4-state `iverilog -g2012` gate-level simulation.
- **Nangate45 Cell Area Cap** (`lib/NangateOpenCellLibrary_typical.lib`, flattened `VX_tcu_subsys` mapped with `dfflibmap -liberty` + `abc -liberty ... -D 1500 -script "+strash;dc2;dch -f;map;buffer -N 16;upsize;dnsize"`): **`<= 87,200.0 um^2`**.
- **OpenROAD Static Timing Signoff**: Under a **`6.50 ns` clock period** on `clk` (`0.20 ns` input/output delay on non-clock ports, `set_false_path -from [get_ports reset]`), setup **`WNS >= 0.0000 ns`**.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Signoff Reference

## Editable Files
- `code/VX_tcu_uops.sv`
- `code/VX_tcu_abuf.sv`
- `code/VX_tcu_bbuf.sv`
- `code/VX_tcu_core.sv`

## Read-Only Subsystem & Technology Collateral
- Subsystem top & supporting Vortex TCU/core/library RTL: `code/VX_tcu_subsys.sv`, `code/VX_tcu_pkg.sv`, `code/VX_gpu_pkg.sv`, and supporting `.sv`/`.vh` files in `code/`
- Nangate45 standard-cell collateral:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Dual-Configuration RTL Functional Verification (`Verilator v5.038`)**:
   - Compile `VX_gpu_pkg.sv`, `VX_tcu_pkg.sv`, and `VX_tcu_subsys.sv` (`-Icode -DXLEN_32 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_LMEM_NUM_BANKS=8 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE`) across:
     - `CFG_F2K_1B`: `-DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_FEDP2K`
     - `CFG_NOF2K_2B`: `-DVX_CFG_NUM_TCU_BLOCKS=2 -DNO_FEDP2K`
   - Verify dense & 2:4 sparse `WMMA`/`WGMMA` arithmetic, strided bank-row-straddling SMEM tile loads, B-tile cache coherency, dual-block lockstep, and FIFO retirement under randomized LMEM/commit backpressure.
2. **Yosys Synthesis, 4-State Gate-Level Simulation & Nangate45 PPA/STA Signoff**:
   - Elaborate `VX_tcu_subsys` in `yosys -m slang` (`read_slang --top VX_tcu_subsys -Icode -DXLEN_32 -DTCU_SYNTH_BND -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=2 -DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE -DVX_CFG_TCU_FEDP2K -DVX_CFG_LMEM_NUM_BANKS=8 code/VX_gpu_pkg.sv code/VX_tcu_pkg.sv ...`), checking zero latches (`$dlatch*`, `$_DLATCH_*`) and zero combinational loops (`scc -expect 0`).
   - Simulate the synthesized gate-level netlist in 4-state `iverilog -g2012` against `simcells.v` to verify `X`-free reset and multi-warp `WMMA`/`WGMMA`/`WGMMA_SP` retirement.
   - Flatten and map to `lib/NangateOpenCellLibrary_typical.lib` (`dfflibmap -liberty` + `abc -liberty ... -D 1500 -script "+strash;dc2;dch -f;map;buffer -N 16;upsize;dnsize"`), requiring cell area `<= 87,200.0 um^2` and OpenROAD STA setup `WNS >= 0.0000 ns` at a `6.50 ns` clock period (`0.20 ns` non-clock I/O delays, `set_false_path -from [get_ports reset]`).

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/VX_tcu_uops.sv`
- `code/VX_tcu_abuf.sv`
- `code/VX_tcu_bbuf.sv`
- `code/VX_tcu_core.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
