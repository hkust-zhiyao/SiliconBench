# case_22011: RVV 1.0 Unit-Stride and Strided Segmented Load/Store Support in Ara

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/ara` (`repo_19`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/ara_dispatcher.sv`, `code/segment_sequencer.sv`

---

## Problem Specification

# RVV 1.0 Unit-Stride and Strided Segmented Load/Store Support in Ara

## Architectural Context

In PULP Ara (`SegSupport = SegSupportEnable`), scalar/accelerator instructions arrive at `code/ara_dispatcher.sv`, which decodes RVV 1.0 instructions, checks architectural legality, manages per-register effective element width (`EEW`) reshuffling, and forwards vector requests through `code/segment_sequencer.sv` to `ara_sequencer` and `vlsu`.

Currently, Ara's segment offload path is incomplete across `code/ara_dispatcher.sv` and `code/segment_sequencer.sv` for RVV 1.0 unit-stride (`vlseg<nf>e<eew>.v`, `vsseg<nf>e<eew>.v`, `vlseg<nf>e<eew>ff.v`) and strided (`vlsseg<nf>e<eew>.v`, `vssseg<nf>e<eew>.v`) segmented memory operations (`2 <= NFIELDS <= 8`, encoded as `nf = NFIELDS - 1` in `1..7`).

## Functional Requirements

1. **Decoding, `EMUL * NFIELDS` Legality, & Overlap Trapping (`ara_dispatcher.sv`)**:
   - Decode unit-stride, fault-only-first, and byte-strided segmented loads and stores across `EEW` in `{EW8, EW16, EW32, EW64}` and fractional/integer `LMUL`.
   - Compute effective `EMUL = (EEW / SEW) * LMUL` and reject illegal encodings on `acc_resp_o` (`ILLEGAL_INSTR`, without issuing backend micro-ops): invalid `EEW`, `EMUL < 1/8` or `EMUL > 8`, `EMUL * NFIELDS > 8`, misaligned register-group base (`rd % max(1, EMUL) != 0`), register wrap past `v31` (`rd + NFIELDS * max(1, EMUL) > 32`), fault-only-first stores, and masked segment loads whose destination register range `[rd .. rd + NFIELDS * max(1, EMUL) - 1]` overlaps `v0` (`vm == 0`).
2. **AoS-to-SoA Micro-Op Decomposition & `EEW` Tracking (`segment_sequencer.sv` + `ara_dispatcher.sv`)**:
   - For `0 <= vstart < vl`, transpose memory segments into `NFIELDS` consecutive vector register groups `reg_group(f) = base_reg + f * max(1, EMUL)` (`0 <= f < NFIELDS`).
   - Element `i` (`vstart <= i < vl`), field `f` accesses memory address `rs1 + i * seg_stride + f * (EEW / 8)`, where `seg_stride = NFIELDS * (EEW / 8)` for unit-stride ops and `seg_stride = rs2` (signed byte stride, including zero or negative strides) for strided ops.
   - Zero-trip operations (`vl == 0` or `vstart >= vl`) retire cleanly without memory accesses or exceptions.
   - Maintain per-register `EEW` state and trigger VRF reshuffling across all `NFIELDS * max(1, EMUL)` registers of a segmented load/store whenever prior register `EEW`s differ, ensuring segmented store micro-ops carry the true `old_eew_vs1` of each field register.
3. **Completion Accounting & Memory Exceptions**:
   - Drain in-flight backend state before retiring a segmented operation, pulsing `load_complete_o` / `store_complete_o` once per retired architectural segment instruction (while passing non-segment instructions through transparently).
   - On an address/MMU exception at element `i_fault`: stop issuing subsequent micro-ops, drain in-flight operations, and report `exception_vstart = i_fault` on standard loads/stores; for fault-only-first (`vlseg*ff.v`), trap only when `i_fault == 0`, and when `i_fault > 0` suppress the trap and trim architectural `vl` to `i_fault`.

## Deliverable Constraints

- Modify **only** `code/ara_dispatcher.sv` and `code/segment_sequencer.sv`; preserve all module names, parameters, and port signatures.
- All RTL must be strictly synthesizable (`yosys -m slang` clean elaboration with zero inferred latches).

---

## Build, Simulation, and EDA Verification Instructions

# Build & Elaboration Guide

## Toolchain Paths
- **Verilator**: `verilator`
- **Yosys (+ slang)**: `yosys`

## Editable RTL
- `code/ara_dispatcher.sv`
- `code/segment_sequencer.sv`

## Compile Order (`-Icode/include`)
```bash
RTL_SRCS=(
  code/config_pkg.sv
  code/cv64a6_imafdcv_sv39_config_pkg.sv
  code/build_config_pkg.sv
  code/riscv_pkg.sv
  code/cf_math_pkg.sv
  code/axi_pkg.sv
  code/fpnew_pkg.sv
  code/rvv_pkg.sv
  code/ara_pkg.sv
  code/onehot_to_bin.sv
  code/lzc.sv
  code/popcount.sv
  code/counter.sv
  code/delta_counter.sv
  code/fall_through_register.sv
  code/spill_register_flushable.sv
  code/spill_register.sv
  code/fifo_v3.sv
  code/rr_arb_tree.sv
  code/stream_arbiter_flushable.sv
  code/stream_arbiter.sv
  code/stream_demux.sv
  code/stream_mux.sv
  code/stream_xbar.sv
  code/axi_cut.sv
  code/segment_sequencer.sv
  code/ara_dispatcher.sv
  code/ara_sequencer.sv
  code/vlsu/addrgen.sv
  code/vlsu/vldu.sv
  code/vlsu/vstu.sv
  code/vlsu/vlsu.sv
)
```

### Verilator Lint / Elaboration Check
```bash
verilator \
  --lint-only -Wno-fatal -Icode/include --top-module ara_dispatcher "${RTL_SRCS[@]}"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ara_dispatcher.sv`
- `code/segment_sequencer.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
