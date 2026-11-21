# Multi-Lane RVV 1.0 Slide Permutation, Stride Decomposition, and Reduction Control in Ara

## Architectural Context

In PULP Ara (`code/sldu.sv`, `code/p2_stride_gen.sv`, `code/sldu_op_dp.sv`, wrapped for verification and synthesis in `code/sldu_subsys_top.sv`), the Slide and Inter-Lane Reduction Unit (`SLDU`) executes RVV 1.0 vector slides (`VSLIDEUP`, `VSLIDEDOWN`, `VSLIDE1UP`, `VSLIDE1DOWN`) and inter-lane reductions across parameterized lane counts (`NrLanes = 2, 4, 8`, `VLEN = 1024`). `p2_stride_gen` decomposes intra-row non-power-of-two slide offsets into sequential power-of-two shifts through `sldu_op_dp`.

Across parameterized `NrLanes = {2, 4, 8}` configurations, multi-row vectors, 64-bit strides, masked slides (`vm == 0`), dynamic `EEW` mismatches (`eew_vs2 != vtype.vsew`), and per-lane backpressure, several control, boundary, and reset bugs cause non-idle post-reset outputs, VRF corruption, operand/mask stream desynchronization, premature `pe_vinsn_done_o` retirement, or pipeline deadlocks.

## Functional & Physical Requirements

1. **`p2_stride_gen` Reset & Power-of-Two Decomposition (`code/p2_stride_gen.sv`)**:
   - Immediately after reset (`!rst_ni`), when idle prior to `valid_i`, or when loaded with `stride_i == 0`, `valid_o`, `stride_p2_o`, and `popc_o` must all be `0` (4-state X-free).
   - When `valid_i` asserts (`valid_i` takes priority if `update_i` is simultaneously high), latch `stride_i` and emit each nonzero bit from least-significant power-of-two (`stride_p2_o`) to most-significant on successive `update_i` cycles, driving `popc_o` equal to the number of remaining nonzero bits (`>= 1` while `valid_o == 1`) and clearing `valid_o = 0`, `stride_p2_o = 0`, `popc_o = 0` after the final bit is updated.

2. **RVV 1.0 Slide Semantics, Exact Stream Beat Counts & `EEW` Reshuffling (`code/sldu.sv`)**:
   - **`VSLIDEUP` (`!use_scalar_op`)**: Evaluate full unsigned 64-bit `pe_req_i.stride` against `vl` without shift overflow or truncation. When `vl == 0` or `stride >= vl`, leave the VRF undisturbed, consume **0** `sldu_operand_i` beats and **0** `mask_i` beats, issue **0** VRF write requests, and retire `pe_vinsn_done_o[id]` in order. When `stride < vl`, leave prefix elements `0 <= i < stride` undisturbed (`be == 0`), write active (`vm || v0.mask[i]`) elements `stride <= i < vl` from `vs2[i - stride]`, never write tail bytes `i >= vl` on any row, consume exactly `ceil(((vl - stride)*SEW) / (8*NrLanes))` `sldu_operand_i` row beats per lane, and when `vm == 0` consume exactly one `mask_i` beat per written destination row `[floor((stride*SEW)/(8*NrLanes)) .. floor((vl*SEW - 1)/(8*NrLanes))]` (gated on `|mask_valid_i`).
   - **`VSLIDEDOWN` (`!use_scalar_op`)**: Compute `vlmax = ((VLEN/8) * LMUL) >> vsew` (`vlmax_bytes = (VLEN/8) * LMUL`) across `LMUL_1_8 .. LMUL_8`. For active elements `0 <= i < vl`, write `vs2[i + stride]` when unsigned 64-bit `i + stride < vlmax`, and write `0` when `i + stride >= vlmax`. Consume **0** `sldu_operand_i` beats when `stride >= vlmax`, and otherwise consume only the `ceil((in_off + min(vl*SEW, vlmax_bytes - stride*SEW)) / (8*NrLanes))` in-bounds source row beats (`in_off = (stride*SEW) mod (8*NrLanes)`), plus one `mask_i` beat per destination row `0 .. floor((vl*SEW - 1)/(8*NrLanes))` when `vm == 0`.
   - **`VSLIDE1UP` & `VSLIDE1DOWN` (`use_scalar_op == 1`)**: Write `scalar_op` to element `0` (`VSLIDE1UP`) or element `vl - 1` (`VSLIDE1DOWN`, including across row boundaries such as `vl*SEW = k*(8*NrLanes) + SEW`). When `vl == 1`, consume **0** `sldu_operand_i` beats (`1` `mask_i` beat if `vm == 0`); for `vl > 1`, consume `ceil(((vl - 1)*SEW)/(8*NrLanes))` (`VSLIDE1UP`) or `ceil((vl*SEW)/(8*NrLanes))` (`VSLIDE1DOWN`) source row beats per lane.
   - **Multi-Row P2/NP2 Strides & Dynamic `EEW` Reshuffling**: Support all combinations of row offset and intra-row offset (`0`, power-of-two, and non-power-of-two, regardless of `is_stride_np2`) without loopback/external operand collisions across back-to-back rows or pipelined instructions, and reshuffle incoming `vs2` data from `eew_vs2` to `vtype.vsew` whenever `eew_vs2 != vtype.vsew` across all slide directions and offsets.

3. **Inter-Lane Reductions & In-Order `final_gnt` Commit (`code/sldu.sv`)**:
   - **Unordered Tree Reductions** (`VFU_Alu` / `VFU_MFpu` non-`OSUM` ops): Perform `$clog2(NrLanes) + 1` `EW64` tree-exchange steps on `sldu_red_valid_o` / `sldu_result_gnt_i` (`sldu_result_req_o == 0`), driving `sldu_mux_sel_o` (`ALU_RED` or `MFPU_RED`).
   - **Ordered Reductions** (`VFREDOSUM`, `VFWREDOSUM`): Forward `vl` sequential `EW64` beats one lane at a time from source lane `i mod NrLanes` (`0 <= i < vl`) to target lane `(i + 1) mod NrLanes` (lane `0` on final beat `i == vl - 1`), honoring `sldu_result_gnt_i` backpressure on every beat before asserting `pe_vinsn_done_o[id]`.
   - **In-Order Commit & Skewed Lane Backpressure**: Handle pipelined instructions (`id` in `0..NrVInsn-1`) under independent per-lane `sldu_operand_valid_i`, `sldu_result_gnt_i`, and delayed `sldu_result_final_gnt_i`, asserting `pe_vinsn_done_o[id]` strictly in acceptance order only after all VRF row writes and all corresponding `sldu_result_final_gnt_i` pulses complete.

## Deliverable & Signoff Constraints

- Modify **only** `code/sldu.sv` and `code/p2_stride_gen.sv`; preserve all module names, parameters, and port signatures.
- Must elaborate and synthesize cleanly via `yosys -m slang` across `NrLanes = 2, 4, 8` (`VLEN = 1024`, top `sldu_subsys_top`) with **zero inferred latches** (`proc; opt_clean; check -assert`), pass 4-state gate-level simulation (`NrLanes = 2`), and map cleanly to Nangate45 at `NrLanes = 4, VLEN = 1024` within `60,000.0 um^2` cell area.
