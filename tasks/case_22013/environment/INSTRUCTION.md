# case_22013: Resolve Ara VLSU Unaligned 4KB/Max-Burst Splitting, Non-Zero vstart Lane Rotation, and Scatter/Gather Memory Ordering

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/ara` (`repo_19`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/vlsu.sv`, `code/addrgen.sv`, `code/vldu.sv`, `code/vstu.sv`

---

## Problem Specification

# Ara VLSU Unaligned Burst Splitting, Non-Zero `vstart` Alignment, and Memory Ordering

## Context
`vlsu` (`code/vlsu.sv`, integrating `code/addrgen.sv`, `code/vldu.sv`, and `code/vstu.sv`) is the RVV 1.0 Load-Store Unit in PULP Ara (`NrLanes = 4` 64-bit lanes). It executes unit-stride (`VLE`, `VSE`), strided (`VLSE`, `VSSE`), and indexed (`VLXE`, `VSXE`) vector memory instructions across `EW8`–`EW64`, issuing AXI4 bursts (`axi_req_o` / `axi_resp_i` across parameterized `AxiDataWidth`), steering bytes between the AXI data bus and lane-interleaved VRF banks, and signaling completion (`pe_resp_o`, `load_complete_o`, `store_complete_o`, `store_pending_o`) and address exceptions (`addrgen_exception_o`, `addrgen_exception_vstart_o`).

## Observed Failures
Subsystem verification under AXI4 protocol monitoring and randomized AR/R/AW/W/B channel backpressure exposes three failure groups:

1. **Unaligned 4 KiB Page-Boundary and Max-Burst Splitting**:
   - Unit-stride transfers starting at unaligned byte addresses violate AXI4 `INCR` burst rules or miscompute split burst beat counts near 4 KiB (`0x1000`) boundaries and the 256-beat (`ARLEN` / `AWLEN <= 255`) burst limit, truncating tail bytes or deadlocking beat consumers.

2. **Non-Zero `vstart`, Unaligned Base Offset, and Masked Lane Steering**:
   - Vector loads and stores with `vstart > 0`, unaligned AXI base addresses, masked execution (`vm = 0`), short transfers wrapping across consecutive VRF words, or back-to-back pipelined instructions drop active elements, misrotate lanes, or retire before all VRF writeback grants finish. Prestart (`idx < vstart`), tail (`idx >= vl`), and masked-off (`vm = 0`) elements must remain unmodified in both VRF and memory.

3. **Multi-Burst Store Completion and Scatter/Gather RAW/WAR Ordering**:
   - Multi-burst vector stores assert `store_complete_o` / `pe_resp_o.vinsn_done` and deassert `store_pending_o` before all bursts of the instruction have been transmitted and acknowledged on `B`.
   - Back-to-back overlapping store-then-load (RAW) and load-then-store (WAR) sequences across unit-stride and indexed (`VLXE` / `VSXE`) instructions reorder across uncommitted bursts under asymmetric AXI channel delays, returning stale or overwritten data.
   - Indexed `VLXE` / `VSXE` instructions with `eew_vs2 != vtype.vsew`, back-to-back queued indexed ops under stall, or misaligned active indexed addresses (`vstart >= 0`) misalign lane offset consumption or report an incorrect faulting element index on `addrgen_exception_vstart_o`.

## Requirements
- Modify only `code/vlsu.sv`, `code/addrgen.sv`, `code/vldu.sv`, and `code/vstu.sv`, keeping all package headers, primitives, and `vlsu` top-level ports unchanged.
- Preserve clean, latch-free synthesis (`yosys -m slang`) and exact functional behavior across parameterized `AxiDataWidth` (`64` and `128`).

---

## Build, Simulation, and EDA Verification Instructions

# Build and Verification Guide

## Editable Files

Only the following RTL files are collected for grading:

- `code/vlsu.sv`
- `code/addrgen.sv`
- `code/vldu.sv`
- `code/vstu.sv`

All supporting packages and primitives in `code/` (`ara_pkg.sv`, `rvv_pkg.sv`, `axi_pkg.sv`, `axi_cut.sv`, `fifo_v3.sv`, `spill_register*.sv`, `stream_*.sv`, and `code/include/...`) are read-only reference dependencies.

## Available Toolchain

- **Verilator 5.038**: `verilator`
- **Yosys + slang**: `yosys` (`-m slang`)

## Compilation Order (`Verilator` & `yosys -m slang`)

Compile packages prior to RTL modules with `-Icode/include`:

```bash
verilator \
  --lint-only -Wno-fatal -DSYNTHESIS -Icode/include \
  code/cf_math_pkg.sv \
  code/riscv_pkg.sv \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/build_config_pkg.sv \
  code/lzc.sv \
  code/onehot_to_bin.sv \
  code/rr_arb_tree.sv \
  code/fifo_v3.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/fall_through_register.sv \
  code/stream_arbiter_flushable.sv \
  code/stream_arbiter.sv \
  code/stream_mux.sv \
  code/stream_demux.sv \
  code/stream_xbar.sv \
  code/counter.sv \
  code/delta_counter.sv \
  code/axi_cut.sv \
  code/addrgen.sv \
  code/vldu.sv \
  code/vstu.sv \
  code/vlsu.sv \
  --top-module vlsu
```

To check synthesis elaboration and verify zero inferred latches with `yosys -m slang` (instantiating `vlsu` with concrete `AxiAddrWidth = 64`, `AxiDataWidth = 128` or `64`, `NrLanes = 4`, `VLEN = 4096`):

```bash
yosys -m slang -p "
  read_slang --top <your_vlsu_wrapper> --ignore-assertions --ignore-timing --ignore-initial \
    -I code/include \
    code/cf_math_pkg.sv code/riscv_pkg.sv code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
    code/rvv_pkg.sv code/ara_pkg.sv code/build_config_pkg.sv \
    code/lzc.sv code/onehot_to_bin.sv code/rr_arb_tree.sv code/fifo_v3.sv \
    code/spill_register_flushable.sv code/spill_register.sv code/fall_through_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_mux.sv \
    code/stream_demux.sv code/stream_xbar.sv code/counter.sv code/delta_counter.sv \
    code/axi_cut.sv code/addrgen.sv code/vldu.sv code/vstu.sv code/vlsu.sv <your_vlsu_wrapper.sv>;
  hierarchy -check -top <your_vlsu_wrapper>;
  proc; opt_expr; opt_clean; check -assert; stat
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/vlsu.sv`
- `code/addrgen.sv`
- `code/vldu.sv`
- `code/vstu.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
