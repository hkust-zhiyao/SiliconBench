# Ara Lane Vector ALU: RVV 1.0 Fixed-Point Arithmetic, Saturation Reporting, and Gate-Level Parity

## Context
`valu` (`code/valu.sv`), `simd_alu` (`code/simd_alu.sv`), and `fixed_p_rounding` (`code/fixed_p_rounding.sv`) implement the per-lane 64-bit integer and fixed-point execution pipeline in PULP Ara (`NrLanes = 4`, `VLEN = 4096`). Regression testing across RVV 1.0 fixed-point workloads and 4-state post-synthesis gate-level netlist simulation exposed arithmetic mismatches, corrupted or dropped `vxsat` reports under pipelining/backpressure, and `X`-propagation on boundary shift amounts.

## Architectural Requirements

1. **RVV 1.0 Fixed-Point Operations & Rounding Modes (`EW8`, `EW16`, `EW32`, `EW64`)**:
   - Support single-width saturating add/subtract (`VSADDU`, `VSADD`, `VSSUBU`, `VSSUB`), single-width averaging add/subtract (`VAADDU`, `VAADD`, `VASUBU`, `VASUB`), single-width scaling shifts (`VSSRL`, `VSSRA`), and 2-cycle narrowing fixed-point clips (`VNCLIPU`, `VNCLIP`, for destination `vsew` in `{EW8, EW16, EW32}` narrowing `2*SEW` operands in `alu_operand_i[1]` / `alu_operand_i[0]` or `scalar_op`) across both vector-vector and scalar-vector (`use_scalar_op`) forms.
   - Follow Ara's operand convention (`operand_a` = `vs1`/`rs1`/`imm`, `operand_b` = `vs2`) and intra-lane shuffled subword byte layout (`ara_pkg::shuffle_index` / `be`).
   - Implement exact RVV 1.0 §12.1 fixed-point rounding (`vxrm_i`: `2'b00` `rnu`, `2'b01` `rne`, `2'b10` `rdn`, `2'b11` `rod`), including zero shift amounts (`shamt == 0` -> rounding increment `0`) and masking shift amounts to `lg2(SEW)` bits for single-width shifts or `lg2(2*SEW)` bits for narrowing clips.
   - Compute `VAADDU`/`VAADD` and `VASUBU`/`VASUB` from the full `(SEW+1)`-bit unsigned or signed sum/difference before shifting right by 1, rounding per `vxrm_i`, and wrapping to `SEW` bits without asserting saturation.
   - For `VNCLIPU` and `VNCLIP`, round the shifted `2*SEW` value per `vxrm_i` and clamp to `[0, 2^SEW - 1]` or `[-2^(SEW-1), 2^(SEW-1) - 1]` (including post-rounding boundary overflow), flagging saturation on the corresponding narrowed subword bytes.

2. **Byte-Exact `vxsat_flag_o` Tracking Under Pipelining, Narrowing, and Backpressure**:
   - In Ara, the dispatcher accumulates sticky `vxsat` via `csr_vxsat_d |= |vxsat_flag_i`. `vxsat_flag_o` must assert only for saturation occurring on **active** destination bytes (unmasked and `< vl`, matching `alu_result_be_o`) of fixed-point saturating instructions (`VSADDU`, `VSADD`, `VSSUBU`, `VSSUB`, `VNCLIPU`, `VNCLIP`).
   - Masked-off elements (`vm == 0` with `mask_i` clear), tail elements (`>= vl`), non-saturating instructions, and stalled/pipelined back-to-back micro-operations or 2-cycle narrowing halves must never drop a real active saturation event nor falsely assert `vxsat_flag_o` due to adjacent instructions in flight.
   - Existing non-fixed-point integer ALU, comparison/mask, merge, narrowing shift (`VNSRL`, `VNSRA`), and intra-/inter-lane reduction behaviors must remain intact.

3. **`FixPtSupport` Parameterization & 4-State Gate-Level Synthesis Parity**:
   - `valu` and `simd_alu` must elaborate and synthesize cleanly under `yosys -m slang` (latch-free) for both `FixPtSupport = FixedPointEnable` and `FixPtSupport = FixedPointDisable` (with fixed-point datapath disabled and `vxsat_flag_o` tied `1'b0` when `FixedPointDisable`).
   - The synthesized `FixedPointEnable` gate-level netlist must match RTL cycle-for-cycle in 4-state simulation with zero `X`/`Z` propagation on valid outputs (`alu_ready_o`, `alu_operand_ready_o`, `mask_ready_o`, `alu_result_req_o`, `alu_vinsn_done_o`, `vxsat_flag_o`, and active `alu_result_wdata_o` bytes).
