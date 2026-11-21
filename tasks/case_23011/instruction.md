# case_23011: Vortex Multi-Core Split-Phase CTA Barrier & Global Cluster Synchronization Subsystem

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `vortexgpgpu/vortex` (`repo_37`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/VX_bar_unit.sv`, `code/VX_gbar_unit.sv`, `code/VX_gbar_arb.sv`

---

## Problem Specification

# Vortex Multi-Core Split-Phase CTA Barrier & Global Cluster Synchronization

## Subsystem Context
In the Vortex GPGPU cluster synchronization hierarchy (`VX_cluster_bar_subsys`), each SIMT core instantiates `VX_bar_unit` to manage local per-CTA barrier slots and cluster-wide global barriers coordinated across `VX_gbar_arb` and `VX_gbar_unit` over `VX_gbar_bus_if`. Barrier requests operate on a 2-stage read-modify-write pipeline: `read_addr` presents the target barrier slot one cycle ahead of `req_valid` (returning the slot's current odd/even epoch bit combinationally on `read_phase`), followed by `req_valid` with `req_wid` and `req_data` (`barrier_t`: `id`, `is_event`, `is_global`, `is_arrive`, `is_sync`, `phase`, `size_m1`).

Under split-phase SIMT barrier execution, out-of-order asynchronous DMA/tensor-core transaction completions, multi-core subset barriers, and Nangate45 high-frequency static timing signoff (`REQ_OUT_BUF = 0, RSP_OUT_BUF = 0` at the top-level wrapper), the subsystem suffers from premature epoch flips, lost warp wakeups, back-to-back same-slot read-during-write hazards, global broadcast stalls, and setup timing violations.

## Editable Boundary
Only the following three RTL files may be modified:
- `code/VX_bar_unit.sv`
- `code/VX_gbar_unit.sv`
- `code/VX_gbar_arb.sv`

All other files in `code/` (including `VX_cluster_bar_subsys.sv`, `VX_gbar_bus_if.sv`, `VX_gpu_pkg.sv`, and common library primitives) and `lib/` are read-only.

## Architectural, Protocol & PPA/STA Signoff Requirements
1. **Split-Phase Local Barrier Epochs & Back-to-Back Same-Slot Pipelining**:
   - Support non-stalling `BAR.ARRIVE` (`is_arrive=1, is_sync=0`), stalling `BAR.SYNC` (`is_arrive=1, is_sync=1` for `size_m1 + 1` warps), and deferred `BAR.WAIT` (`is_arrive=0, is_event=0` comparing `req_data.phase` against the slot's current epoch). Early-arriving warps may advance into the next barrier epoch before straggler warps execute `BAR.WAIT` for the completed epoch without corrupting the active epoch's waiter set.
   - Sustain back-to-back 1-cycle requests targeting the same `read_addr` slot without losing state updates or returning stale `read_phase` values across consecutive cycles.
   - Never assert `unlock_valid` with an all-zero `unlock_mask` (e.g., when all participating warps used non-stalling arrivals), and never drop warp wakeups when a local slot unlock coincides on the same cycle with a global barrier broadcast unlock on the same core.
2. **Signed Out-of-Order Asynchronous Event Accounting & Multi-Core Global Barriers**:
   - Asynchronous event operations (`is_event=1`: `phase=1` adds `size_m1 + 1` expected transactions; `phase=0` records 1 completed transaction) may arrive in any order relative to one another and relative to warp arrivals—including completions arriving before `phase=1` registration (temporary negative event balance) or all events balancing to zero before any warp arrives. A barrier epoch may complete and toggle its phase only after all participating warps (`size_m1 + 1` locally, or `active_warps` globally) have arrived AND the net signed event balance is zero; asynchronous event packets must never mark `req_wid` as an arrived warp.
   - Support multi-ID and core-subset (`size_m1 + 1 <= NUM_CORES`) global barriers cleanly: duplicate per-core arrivals before completion must not double-count, back-to-back completions across distinct barrier IDs must not overwrite in-flight broadcasts, and non-participating cores executing continuous local `req_valid` traffic (or participating cores accessing unrelated local slots) must not stall global broadcast delivery.
3. **Latch-Free Synthesis & Nangate45 High-Frequency STA/Area Closure**:
   - Synthesize `VX_cluster_bar_subsys` (`NUM_CORES=4, NUM_WARPS=4, NUM_BARRIERS=4, REQ_OUT_BUF=0, RSP_OUT_BUF=0`) via `yosys -m slang` + ABC on `lib/NangateOpenCellLibrary_typical.lib` with zero inferred latches (`$dlatch`) and zero combinational loops.
   - Close post-synthesis OpenROAD static timing with `WNS >= 0.0000 ns` at `1.15 ns` clock period (`0.10 ns` input/output external delays) and total cell area `<= 14,000.00 um^2`.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Signoff Reference

## Editable Files
- `code/VX_bar_unit.sv`
- `code/VX_gbar_unit.sv`
- `code/VX_gbar_arb.sv`

## Read-Only Top-Level Subsystem & Collateral
- Top-level wrapper: `code/VX_cluster_bar_subsys.sv`
- Package & bus interface: `code/VX_gpu_pkg.sv`, `code/VX_gbar_bus_if.sv`
- Common macros/primitives: `code/VX_*.vh`, `code/VX_*.sv`, `code/VX_dp_ram_asic.v`
- Standard-cell Liberty / LEF:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Multi-Configuration Functional Verification (`Verilator v5.038`)**:
   - Compile `code/VX_*.sv` and `code/VX_dp_ram_asic.v` with `-DASIC -DSYNTHESIS -DVX_CFG_XLEN=32 -Icode` across:
     - `NUM_CORES=4, NUM_WARPS=4, NUM_BARRIERS=4`
     - `NUM_CORES=2, NUM_WARPS=8, NUM_BARRIERS=4`
2. **Nangate45 Synthesis & OpenROAD STA Signoff**:
   - Elaborate and map `VX_cluster_bar_subsys` (`-DVX_CFG_NUM_CORES=4 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_NUM_BARRIERS=4`) using `yosys -m slang` (`read_slang ... --top VX_cluster_bar_subsys`), enforcing `select -assert-none */t:$dlatch*` and mapping to `lib/NangateOpenCellLibrary_typical.lib`.
   - Run OpenROAD STA at `1.15 ns` clock period (`create_clock -name clk -period 1.15 [get_ports clk]`, `0.10 ns` input/output delays):
     - Setup `WNS >= 0.0000 ns`
     - Synthesized cell area `<= 14000.00 um^2`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/VX_bar_unit.sv`
- `code/VX_gbar_unit.sv`
- `code/VX_gbar_arb.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
