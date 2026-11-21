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
