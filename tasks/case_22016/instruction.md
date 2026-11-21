# case_22016: Resolve Ara Dispatcher and Sequencer RVV 1.0 Multi-Register Group Scoreboarding, Selective Chaining Hazards, VFU Queue Backpressure, and Scalar/CSR Drain Serialization

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/ara` (`repo_19`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/ara_sequencer.sv`, `code/ara_dispatcher.sv`

---

## Problem Specification

# Multi-VFU Vector Chaining Scoreboard, Queue Accounting, and CSR Ordering in Ara

## Architectural Context

In PULP Ara, `code/ara_dispatcher.sv` decodes RVV 1.0 instructions and vector CSR operations from CVA6, injects VRF `EEW` reshuffle micro-ops when needed, and forwards vector requests to `code/ara_sequencer.sv`. `code/ara_sequencer.sv` allocates `NrVInsn` instruction slots, tracks RAW/WAR/WAW register hazards, enforces per-VFU instruction-queue capacity (`InsnQueueDepth`), coordinates scalar return handshakes, and drives `pe_req_o` and `global_hazard_table_o` to the lanes (`code/lane/lane_sequencer.sv` and `code/lane/operand_requester.sv`).

Under multi-register (`LMUL > 1` / widening / narrowing) workloads, mixed VFU latencies, masked operations, scalar moves, zero-length instructions, and back-to-back CSR accesses, several pipeline-hazard, queue-accounting, and ordering bugs cause silent VRF corruption, premature CSR reads, or VFU deadlocks.

## Functional Requirements

1. **Multi-Register (`EMUL` / `LMUL > 1`) Group Decoding & Multi-Producer Scoreboarding (`ara_dispatcher.sv`, `ara_sequencer.sv`)**:
   - In `ara_dispatcher.sv`, propagate `csr_vtype_q.vlmul` as effective `emul` for multi-register vector-destination `OPMVV` instructions (integer multiply/MAC, divide/remainder, averaging add/sub, `viota.m`, `vid.v`, `vcompress.vm`) while keeping single-register scalar/mask operands at `LMUL_1` (including reduction scalar `vs1`, mask-logical sources, `viota.m` mask `vs2`, `vcompress.vm` mask `vs1`, and `VWXUNARY0` `vmv.x.s`/`vcpop.m`/`vfirst.m` without spurious `vs1` VRF reads). Ensure `RESHUFFLE` micro-ops drive `LMUL_1` on both `emul` and `vtype.vlmul`.
   - In `ara_sequencer.sv`, track all concurrently active `NrVInsn` readers and writers across the exact RVV register-group span (`1, 2, 4, 8` registers in `v0..v31`) of every active source (`vs1`, `vs2`, `vd` source operand, and `v0` when `vm == 0`) and destination (`vd`).
2. **Safe Vector Chaining vs. Unchainable Hazard Stall Interlocks (`ara_sequencer.sv`)**:
   - Preserve concurrent element-chained execution across lanes when producer and consumer access aligned register groups at matching element widths (`base_reg` aligned, `vstart == 0`, sequential per-element VRF read/write pacing).
   - Stall issue (`ara_req_ready_o = 0`) until conflicting older instructions retire whenever lane `operand_requester` write-pulse counting cannot safely pace the dependency: instructions lacking element-rate VRF source queues (`!(use_vs1 || use_vs2 || use_vd_op)`), non-linear/cross-lane permutations, indexed memory operations, or reductions (`VSLIDEUP`, `VSLIDEDOWN`, `VRGATHER`, `VRGATHEREI16`, `VCOMPRESS`, `VLXE`, `VSXE`, reductions), mask-unit bit-packed producers, `v0` mask RAW/WAR hazards, widening/narrowing width-mismatched overlaps, or partial/offset register-group overlaps (`base_C != base_P`).
3. **VFU Instruction-Queue Capacity & Scalar Response Multiplexing (`ara_sequencer.sv`)**:
   - Never exceed `InsnQueueDepth` in-flight instructions on any target VFU (including `MaskuInsnQueueDepth = 1` shared by mask-unit operations and masked `vm == 0` instructions) or leak stale priority-pass state across subsequent instructions or `WAIT`-state handshakes.
   - At top level (`ara.sv`), `pe_scalar_resp_i`/`pe_scalar_resp_valid_i` muxes `MASKU`'s scalar output when `pe_req_o.op` is `VCPOP`/`VFIRST` and Lane-0 `MaskB` otherwise, while `pe_scalar_resp_ready_o` pops Lane-0 `MaskB`. Prevent `vmv.x.s`/`vfmv.f.s` from colliding with or sampling `MaskB` traffic of an active `MASKU` instruction (popping `MaskB` once when retiring `vmv.x.s`/`vfmv.f.s`), while retiring `vcpop.m`/`vfirst.m` cleanly without popping `MaskB` or self-deadlocking on its own mask-unit occupancy.
4. **Zero-Length No-Op Retirement & `OpcodeSystem` CSR Ordering (`ara_dispatcher.sv`)**:
   - Retire zero-trip vector instructions (`vstart >= vl`, `vl == 0`, or `vslideup` with `stride >= vl`, except whole-register moves, scalar-return `VWXUNARY0` ops, and `vset*` configuration ops) before triggering `RESHUFFLE` micro-ops or updating per-register `EEW` state.
   - Drain all buffered/in-flight vector instructions (`ara_idle_i && !ara_req_valid_o`) and final-cycle `vxsat`/`fflags` flag updates before retiring `OpcodeSystem` CSR accesses (even immediately after an earlier `WAIT_IDLE` transition), and extract architectural `vxrm` (`[1:0]` / `[2:1]`) and `vxsat` (`[0]`) bits accurately across register and immediate CSR instructions (`csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, `csrrci`) on `CSR_VXRM`, `CSR_VXSAT`, and `CSR_VCSR`.

## Deliverable Constraints

- Modify **only** `code/ara_sequencer.sv` and `code/ara_dispatcher.sv`; preserve all module names, parameters, and port signatures.
- All RTL must be strictly synthesizable (`yosys -m slang` clean elaboration with zero inferred latches).

---

## Build, Simulation, and EDA Verification Instructions

# Build & Elaboration Guide

## Toolchain Paths
- **Verilator**: `verilator`
- **Yosys (+ slang)**: `yosys`

## Editable RTL
- `code/ara_sequencer.sv`
- `code/ara_dispatcher.sv`

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
  code/stream_register.sv
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
  code/lane/lane_sequencer.sv
  code/lane/operand_requester.sv
)
```

### Verilator Lint / Elaboration Check
```bash
verilator \
  --lint-only -Wno-fatal -Wno-ENUMVALUE -DSYNTHESIS -Icode/include --top-module ara_sequencer "${RTL_SRCS[@]}"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ara_sequencer.sv`
- `code/ara_dispatcher.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
