# case_23013: Vortex SIMT 8-Bank Shared Local Memory AMO/DMA Subsystem & Physical Macro Co-Design

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `vortexgpgpu/vortex` (`repo_37`)
> - **Engineering Problem Type**: `RTL + Hard-SRAM Macro Physical Co-Design` (`PT5_RTL_HardSRAM_Macro_PnR`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/VX_lmem_switch.sv`, `code/VX_local_mem.sv`, `plan/macro_placement.json`, `constraints/lmem_subsys.sdc`

---

## Problem Specification

# Vortex SIMT 8-Bank Shared Local Memory Subsystem & Physical Macro Co-Design

## Overview
`VX_lmem_subsys` (`code/VX_lmem_subsys.sv`) integrates Vortex's SIMT local/global memory request switch, per-lane LSU adapter, 512-bit (`8 x 64`-bit) wide-line DMA port, and 8-bank RV64A-capable Shared Local Memory (`16 KB`, `2` SIMD lanes, `64`-bit words). You own the RTL-to-physical co-design across:
- `code/VX_lmem_switch.sv`
- `code/VX_local_mem.sv`
- `plan/macro_placement.json`
- `constraints/lmem_subsys.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Protocol Contract
1. **Mixed Local/Global SIMD Warp Bifurcation (`VX_lmem_switch`)**:
   - Partition active request lanes (`lsu_in_if.req_data.mask`) per `MEM_ATTR_LOCAL_OFFS` across `local_out_if` (`1`) and `global_out_if` (`0`).
   - When a single warp beat contains both local and global lanes and only one downstream request port is ready, prevent duplicate pushes to the already-accepted target while stalling `lsu_in_if.req_ready` until both required subsets complete; merge returning local and global responses losslessly on `lsu_in_if`.
2. **8-Bank Shared Local Memory, RV64A Atomics & Wide-Line DMA (`VX_local_mem`)**:
   - Instantiate all eight `RM_IHPSG13_1P_256x64_c2_bm_bist` (`256 x 64`) single-port synchronous SRAM macros (`u_lmem_bank_0`..`u_lmem_bank_7`). Expand 8-bit byte write enables to the 64-bit active-high bit mask (`A_BM`), hold `A_MEN == 1'b0` on idle banks, and never assert `A_WEN` and `A_REN` simultaneously on any macro.
   - Support 2-lane 64-bit LSU loads, byte-masked stores, same-address read-after-write hazard protection, and RV64A `.W`/`.D` atomic read-modify-write and `LR`/`SC` operations (including upper/lower 32-bit `.W` lane alignment and reservation invalidation).
   - Coordinate 512-bit `dma_bus_if` line reads and byte-masked line writes so DMA transactions never corrupt or overwrite an in-flight per-bank atomic RMW sequence, and preserve stalled LSU and DMA read response data against interleaving bank reads under arbitrary `rsp_ready` backpressure.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 1900]` um, core area `[50, 50, 2550, 1850]` um. Place all eight `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2` um core margin, `>= 8` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/lmem_subsys.sdc`)**: Constrain `clk` (`core_clk`) to period `<= 20.0` ns with `>= 1.5` ns input/output delays on all non-clock ports (only `reset` may carry `set_false_path`).
- **OpenROAD Signoff**: Latch-free synthesis (`0` `$dlatch`), connected `VDD`/`VSS` PDN grids, post-GRT setup `WNS >= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 25`, and total routed wirelength `<= 7,800,000` um.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Signoff Notes (`VX_lmem_subsys`)

- **RTL Simulation**: Compile `pdk/core.v`, `pdk/256.v`, and the SystemVerilog collateral in `code/` with Verilator 5 (`-sv -DASIC -DSYNTHESIS -DFUNCTIONAL -Icode`) targeting top module `VX_lmem_subsys`.
- **Logic Synthesis**: Synthesize `VX_lmem_subsys` with `yosys -m slang` (`read_slang -DASIC -DSYNTHESIS -Icode pdk/256_stub.v ... --top VX_lmem_subsys; synth -top VX_lmem_subsys -flatten`) mapped to `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`.
- **Physical Implementation & Signoff**: Run OpenROAD on IHP SG13G2 (`pdk/sg13g2_tech.lef`, `pdk/sg13g2_stdcell.lef`, `pdk/256.lef`, `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`, `pdk/256.lib`) using `plan/macro_placement.json` and `constraints/lmem_subsys.sdc`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/VX_lmem_switch.sv`
- `code/VX_local_mem.sv`
- `plan/macro_placement.json`
- `constraints/lmem_subsys.sdc`

All other files in the workspace are read-only reference context and must remain unmodified.
