# case_0009: Keep HWPE Micro-Loop Multi-Op Results, Loop Metadata, and Clears Coherent Across Stalls

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/hwpe-ctrl` (`repo_33`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/hwpe_ctrl_uloop.sv`

---

## Problem Specification

# Keep micro-loop multi-operation results, loop metadata, and clears coherent across stalls

The accelerator consumes shadowed micro-loop results more slowly than the processor can prepare the next iteration. When `ctrl_i.ready` pauses computation during a multi-operation loop body or while a completed result waits for `ctrl_i.enable`, partially updated results can be published and the reported loop number (`flags_o.loop`) can drift away from the offsets and indices it describes.

Update `code/hwpe_ctrl_uloop.sv` so that when `flags_o.valid` is high, `flags_o.loop`, `flags_o.offs`, `flags_o.idx`, and `flags_o.idx_update` always describe the same completed loop-body iteration without partial mid-body updates across pauses, and so that asserting either `clear_i` or `ctrl_i.clear` discards all pending and visible state before a subsequent job. Preserve the existing microcode semantics, handshakes, offsets, and index progression across both shadowed (`SHADOWED = 1`) and unshadowed (`SHADOWED = 0`) configurations.

---

## Build, Simulation, and EDA Verification Instructions

The package and micro-loop RTL come from `pulp-platform/hwpe-ctrl` commit `558fe3db3413909878c03aed543257d94a57bae5`. Compile `code/hwpe_ctrl_package.sv` before `code/hwpe_ctrl_uloop.sv`; Verilator supports the packed types used here. The source header in `code/hwpe_ctrl_uloop.sv` documents the microcode programming model, parameters, and `ctrl_i` / `flags_o` handshake interface.

`code/hwpe_ctrl_uloop.sv` is the only editable file; `code/hwpe_ctrl_package.sv` is read-only.

For a quick syntax and elaboration check from the workspace root, run:
```bash
verilator --lint-only -Wno-fatal -DSYNTHESIS --top-module hwpe_ctrl_uloop code/hwpe_ctrl_package.sv code/hwpe_ctrl_uloop.sv
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/hwpe_ctrl_uloop.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
