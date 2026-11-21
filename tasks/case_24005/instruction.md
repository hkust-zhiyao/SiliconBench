# case_24005: Cross-Domain Unilateral Reset Isolation, Segmented Output Gating, and Multi-Corner STA in BaseJump Async FIFO

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `bespoke-silicon-group/basejump_stl` (`repo_12`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/bsg_async_fifo.sv`, `code/bsg_async_ptr_gray.sv`, `code/bsg_mem_1r1w.sv`, `constraints/bsg_async_fifo.sdc`

---

## Problem Specification

# Cross-Domain Reset Isolation, Segmented Output Gating, and Multi-Corner Timing Closure in `bsg_async_fifo`

`bsg_async_fifo` (`code/bsg_async_fifo.sv`, `code/bsg_async_ptr_gray.sv`, `code/bsg_mem_1r1w.sv`) transfers framed control+payload words across independent write (`w_clk_i`/`w_reset_i`) and read (`r_clk_i`/`r_reset_i`) clock/reset islands. Gate-level verification and multi-corner STA signoff exposed reset-island desynchronization, empty-FIFO write-through leakage, sub-cycle flag glitches, parameter elaboration failures, and timing signoff violations.

Update the editable RTL (`code/bsg_async_fifo.sv`, `code/bsg_async_ptr_gray.sv`, `code/bsg_mem_1r1w.sv`) and timing constraints (`constraints/bsg_async_fifo.sdc`) while preserving `bsg_async_fifo`'s module/parameter/port interface and read-only primitives.

## Architectural & Signoff Contract

1. **Unilateral & Concurrent Domain Reset Recovery (`1:7` to `7:1` Clock Ratios)**:
   - Producer (`w_reset_i`) and consumer (`r_reset_i`) synchronous resets may assert either concurrently or **unilaterally** (e.g., `w_reset_i` pulsed for `>= 1` `w_clk_i` cycle while `r_reset_i == 0`, or `r_reset_i` pulsed for `>= 1` `r_clk_i` cycle while `w_reset_i == 0`) on an active or partially populated FIFO.
   - Any reset on either domain must safely isolate both interfaces (`w_full_o == 1`, `r_valid_o == 0`), coordinate cross-domain pointer/synchronizer clearing without multi-bit Gray transition hazards while the peer is live, and hold `w_full_o == 1` and `r_valid_o == 0` until both domains have released reset and flushed all synchronizer pipelines to empty (`0`), then restore full `2**lg_size_p` capacity and 1-word/cycle throughput.
   - Out-of-protocol `w_enq_i` while `w_full_o == 1` and `r_deq_i` while `r_valid_o == 0` must be safely ignored without corrupting state or firing simulation assertions.

2. **Parameter Completeness, Segmented Empty-RAM Isolation & Glitch-Free Flags**:
   - Elaborate and synthesize cleanly across all `lg_size_p >= 1` and `0 <= control_width_p <= width_p` (`0`, split control/payload, and `control_width_p == width_p`) with zero inferred latches.
   - Control MSBs (`[width_p-1 -: control_width_p]`, when `control_width_p > 0`) must always be gated to `'0` via `bsg_and` whenever `r_valid_o == 0` regardless of `and_data_with_valid_p`. Payload LSBs (`[width_p - control_width_p - 1 : 0]`, when `width_p > control_width_p`) must be gated to `'0` via `bsg_and` when `r_valid_o == 0` only if `and_data_with_valid_p != 0`, and remain un-gated when `and_data_with_valid_p == 0`.
   - Under gate-level logic and per-flop clock-to-Q skew, `r_valid_o` and `w_full_o` must transition cleanly only on active clock edges with zero sub-cycle decode glitches when local and remote pointers advance together, and gated `r_data_o` bits must never glitch while empty.

3. **Nangate45 Slow/Fast Timing Signoff (`lg_size_p=3, width_p=16, control_width_p=4, and_data_with_valid_p=1`)**:
   - Clocks: `w_clk_i` at `4.0 ns`, `r_clk_i` at `2.5 ns`; clock uncertainty `>= 0.12 ns` setup / `>= 0.03 ns` hold.
   - Synchronous I/O budgets: `w_clk_i` inputs (`w_reset_i`, `w_enq_i`, `w_data_i[*]`) `0.60 ns` max / `0.10 ns` min, output (`w_full_o`) `0.60 ns` max / `0.05 ns` min; `r_clk_i` inputs (`r_reset_i`, `r_deq_i`) `0.50 ns` max / `0.10 ns` min, outputs (`r_valid_o`, `r_data_o[*]`) `0.50 ns` max / `0.05 ns` min.
   - Cross-domain Gray pointer and control crossings must be physically delay-bounded to `<= min(T_w, T_r)` (`2.50 ns`) without blanket asynchronous clock groups or unconstrained clock-to-clock false paths, while properly constraining asynchronous FIFO storage read paths so Slow (`1.25`/`1.00`) and Fast (`1.00`/`0.75`) corners achieve zero setup/hold violations.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment

## Editable Files
- `code/bsg_async_fifo.sv`
- `code/bsg_async_ptr_gray.sv`
- `code/bsg_mem_1r1w.sv`
- `constraints/bsg_async_fifo.sdc`

All other files under `code/` and `lib/` are read-only collateral and must not be modified.

## Available Tools
- **Icarus Verilog (`iverilog -g2012` / `vvp`)**:
  ```bash
  iverilog -g2012 -I code -s tb -o sim.vvp \
    code/bsg_and.sv code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
    code/bsg_launch_sync_sync.sv code/bsg_async_ptr_gray.sv code/bsg_async_fifo.sv tb.sv
  vvp sim.vvp
  ```
- **Yosys + Slang (`yosys -p "plugin -i slang; ..."`)** with `-DSYNTHESIS -DYOSYS -I code` and `lib/NangateOpenCellLibrary_typical.lib`.
- **OpenROAD / OpenSTA (`openroad -exit`)** with `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib`.
- Note: `constraints/bsg_async_fifo.sdc` must use pure standard SDC commands only.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/bsg_async_fifo.sv`
- `code/bsg_async_ptr_gray.sv`
- `code/bsg_mem_1r1w.sv`
- `constraints/bsg_async_fifo.sdc`

All other files in the workspace are read-only reference context and must remain unmodified.
