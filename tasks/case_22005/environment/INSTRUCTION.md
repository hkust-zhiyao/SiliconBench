# case_22005: Implement Ara RVV 1.0 Multi-Lane Mask Bit-Scan, Population Count, and Prefix-Sum Engine

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/ara` (`repo_19`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/masku.sv`, `code/masku_operands.sv`

---

## Problem Specification

# RVV 1.0 Multi-EEW Mask Bit-Scan, Popcount, and Prefix-Sum Support in Ara's Mask Unit

## Context & Architectural Contract

In PULP Ara (`NrLanes = 4`, `ELEN = 64`, `VLEN = 1024`), each vector lane stores 64-bit VRF words whose bytes are lane-shuffled by each operand's effective encoding width (`EW8`, `EW16`, `EW32`, `EW64`) according to `ara_pkg::shuffle_index` and `ara_pkg::deshuffle_index` (`32` bytes / `256` bits per 4-lane VRF beat).

Currently, `code/masku_operands.sv` forwards incoming lane words without per-operand multi-EEW byte deshuffling, and `code/masku.sv` lacks hardware support for the seven native RVV 1.0 mask bit-scan, population-count, and element-index/prefix-sum instructions (`VCPOP`, `VFIRST`, `VMSBF`, `VMSOF`, `VMSIF`, `VIOTA`, `VID`) as well as backpressure-safe scalar result retirement. Extend `code/masku_operands.sv` and `code/masku.sv` to support multi-EEW operand unpacking and all seven operations while preserving all existing Mask Unit operations (`VMANDNOT`..`VMXNOR`, `VMFEQ`..`VMSBC`, `VRGATHER`..`VCOMPRESS`) and mask distribution (`mask_o` / `mask_valid_o`).

## Operand Channels, Zero-Trip Behavior, & RVV 1.0 Semantics

1. **Independent Multi-EEW Unpacking (`masku_operands.sv`)**:
   - Channel `0` (`MaskM`, active when `!vm`): `v0.m` words encoded with `eew_vmask`, deshuffled onto `masku_operand_m_seq_o`.
   - Channel `1` (`MaskB`, active when `use_vd_op` or `VRGATHER`..`VCOMPRESS`): prior `vd` / data words encoded with `eew_vd_op`, deshuffled onto `masku_operand_vd_seq_o`.
   - Channel `2 + masku_fu_i`: source `vs2` / ALU / MFPU words encoded with `eew_vs2`, deshuffled onto `masku_operand_alu_seq_o` (active when `use_vs2`).
   - `eew_vmask`, `eew_vd_op`, `eew_vs2`, and destination `vtype.vsew` may all differ within the same instruction, and lane `valid` handshakes may arrive with arbitrary inter-lane skew.
2. **Beat Draining & Zero-Trip Instructions**:
   - When `vl == 0` or `vstart >= vl`, lanes push zero operand beats; the unit must not wait on `masku_operand_valid_i` or issue VRF writes (`VCPOP` retires `64'd0`, `VFIRST` retires `64'hFFFF_FFFF_FFFF_FFFF`, vector ops retire immediately).
   - When `vl > 0` and `vstart < vl`, every active input channel delivers `ceil(vl / 256)` beats per lane; all scheduled beats across all lanes must be drained before `pe_resp_o.vinsn_done[id]` pulses (including early `VFIRST` hits).
3. **Target Operations** (with `active(i) = vm || v0.m[i]`):
   - `VCPOP` / `VFIRST`: Scalar population count and lowest active set bit index over `i in [vstart, vl)` (`64'd0` / `64'hFFFF_FFFF_FFFF_FFFF` when none), retired on `result_scalar_o` / `result_scalar_valid_o` / `result_scalar_ready_i` (holding `valid` and data stable under `ready == 0`, pulsing `vinsn_done[id]` on handshake).
   - `VMSBF`, `VMSOF`, `VMSIF`: Write `N_out = ceil(vl / 256)` beats to `vd` (`be = 8'hFF`, shuffled by `vtype.vsew`). Bits `i < vstart` remain `vd_old[i]`; active body bits `[vstart, vl)` follow RVV 1.0 set-before / set-only / set-including-first semantics starting from `vstart` (ignoring `j < vstart` and inactive bits); inactive body bits follow `vtype.vma` (`1` = `'1`, `0` = `vd_old[i]`); tail bits `[vl, 256*N_out)` follow `vtype.vta`.
   - `VIOTA`, `VID`: With `E_beat = 32 >> vtype.vsew`, write `N_out = ceil(vl / E_beat)` beats to `vd` (shuffled by `vtype.vsew`). Active body elements write `SEW'(i)` (`VID`) or the running prefix sum `SEW'(sum_{0 <= j < i} active(j) & vs2[j])` (`VIOTA`) with element `be` strobes enabled; `i < vstart` leaves `be = 0`; inactive body and final-beat tail elements write `'1` (`be = 1`) when `vma`/`vta == 1` or suppress `be = 0` when undisturbed.
   - `vinsn_done[id]` for vector writes must wait until all queued beats issue (`req && gnt`) and every lane returns its matching `masku_result_final_gnt_i` pulse.

## Deliverable Constraints

- Modify **only** `code/masku_operands.sv` and `code/masku.sv`; keep module names, parameters, and port signatures intact.
- Synthesizable synchronous RTL (`clk_i`, `rst_ni`) with zero inferred latches and zero combinational loops.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Guide

## Source Layout

All SystemVerilog packages, common-cell modules, headers, and Mask Unit RTL sources reside under `code/`:

- **Editable RTL files**:
  - `code/masku_operands.sv`
  - `code/masku.sv`
- **Read-only packages, headers, and primitives**:
  - `code/config_pkg.sv`
  - `code/cv64a6_imafdcv_sv39_config_pkg.sv`
  - `code/riscv_pkg.sv`
  - `code/cf_math_pkg.sv`
  - `code/axi_pkg.sv`
  - `code/fpnew_pkg.sv`
  - `code/rvv_pkg.sv`
  - `code/ara_pkg.sv`
  - `code/spill_register_flushable.sv`
  - `code/spill_register.sv`
  - `code/delta_counter.sv`
  - `code/lzc.sv`
  - `code/popcount.sv`
  - `code/fifo_v3.sv`
  - `code/include/common_cells/registers.svh`
  - `code/include/common_cells/assertions.svh`
  - `code/include/ara/ara_typedef.svh`

## Compilation Order (Verilator)

To lint or simulate `masku` with your own testbench (`my_tb.sv`) using Verilator (`v5.038+`):

```bash
verilator --binary --timing -O1 -CFLAGS -O0 -Wno-fatal -DSYNTHESIS -j 1 \
  -Icode/include \
  --top-module my_tb \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv \
  code/cf_math_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/delta_counter.sv \
  code/lzc.sv \
  code/popcount.sv \
  code/fifo_v3.sv \
  code/masku_operands.sv \
  code/masku.sv \
  my_tb.sv
```

When instantiating `masku` in a custom testbench or synthesis wrapper with `NrLanes = 4` and `VLEN = 1024`, define `localparam type vlen_t = logic [$clog2(VLEN+1)-1:0];` and `localparam type vaddr_t = logic [9:0];`, then `` `include "ara/ara_typedef.svh" `` inside your wrapper module to obtain `pe_req_t` and `pe_resp_t`.

## Synthesis & Latch Check (`yosys -m slang`)

To verify clean synthesis elaboration, zero combinational loops, and zero inferred latches using Yosys with the `slang` frontend (`my_synth_top.sv` wrapping `masku` for `NrLanes = 4`, `VLEN = 1024`):

```bash
yosys -m slang -p "
  read_slang -DSYNTHESIS --ignore-assertions --unroll-limit 20000 \
    -Icode/include --top my_synth_top \
    code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv \
    code/riscv_pkg.sv \
    code/cf_math_pkg.sv \
    code/axi_pkg.sv \
    code/fpnew_pkg.sv \
    code/rvv_pkg.sv \
    code/ara_pkg.sv \
    code/spill_register_flushable.sv \
    code/spill_register.sv \
    code/delta_counter.sv \
    code/lzc.sv \
    code/popcount.sv \
    code/fifo_v3.sv \
    code/masku_operands.sv \
    code/masku.sv \
    my_synth_top.sv;
  hierarchy -check -top my_synth_top;
  proc; opt_clean; check -assert; stat
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/masku.sv`
- `code/masku_operands.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
