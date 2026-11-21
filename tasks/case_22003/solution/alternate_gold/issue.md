# Optimize Ara Lane Integer VMFPU and SIMD Divider for Masked Fast-Skip, Area, and Timing Closure

## Problem Overview
In Ara's per-lane integer vector multiplier/divider unit (`code/vmfpu.sv` and `code/simd_div.sv`, synthesized via `code/vmfpu_synth_top.sv` with `NrLanes = 4`, `VLEN = 4096`, `FPUSupport = FPUSupportNone`, `FPExtSupport = FPExtSupportNone`, `FixPtSupport = FixedPointEnable`), baseline sign-off fails three checks:
1. **Synthesis Loop & Area Overflow**: `yosys` `proc; check -assert` flags combinational logic loops, and mapped Nangate45 cell area reaches **`87,565.6 um^2`**.
2. **Setup Timing Violation**: OpenROAD STA at a **`5.20 ns`** clock period reports **`-2.12 ns`** worst setup slack.
3. **Masked Division Latency Waste**: Under masked vector division/remainder (`vm = 0`), `simd_div.sv` serially iterates `serdiv` across every subword of every 64-bit lane beat even when individual subwords or entire beats are masked inactive.

## Sign-Off Requirements
Modify **only** `code/vmfpu.sv` and `code/simd_div.sv` (preserving module interfaces and read-only files) to satisfy all requirements simultaneously:

1. **RVV 1.0 & Ara Lane Architectural Equivalence**:
   - Preserve exact per-lane behavior for `VMUL`, `VMULH`, `VMULHU`, `VMULHSU`, `VMACC`, `VNMSAC`, `VMADD`, `VNMSUB`, `VSMUL`, `VDIVU`, `VDIV`, `VREMU`, and `VREM` across `EW8`, `EW16`, `EW32`, and `EW64`.
   - Support unmasked (`vm = 1`) and masked (`vm = 0`) execution, vector-vector and scalar (`use_scalar_op`) operands, `swap_vs2_vd_op` operand queue remapping, non-aligned tail `vl`, all four `mfpu_vxrm_i` fixed-point rounding modes, masked-active saturation reporting (`mfpu_vxsat_o` asserted only on active writebacks whose unmasked elements saturate), and RVV 1.0 divide-by-zero / signed-overflow (`-2^(W-1) / -1`) semantics.
   - Maintain in-order VRF result writeback (`mfpu_result_*`) and completion (`mfpu_vinsn_done_o`) across queued multi-SEW instructions under arbitrary `mfpu_operand_valid_i`, `mask_valid_i`, and `mfpu_result_gnt_i` backpressure. Ignore broadcasts with `vfu != VFU_MFpu` and keep unused FP handshakes inactive (`0`).

2. **Masked Subword Fast-Skip Latency**:
   - Skip masked-off subwords without running `serdiv` iterations on them, and bypass `serdiv` when an entire 64-bit beat is masked off, writing active subword results to their exact byte lanes.
   - With zero external stall, an 8-beat (`vl = 64`, `EW8`, `vm = 0`) instruction from issue acceptance to `mfpu_vinsn_done_o` must finish in **`<= 32` cycles** when all elements are masked off (`mask_i = 8'h00`, `VDIV`), and **`<= 76` cycles** when 1 of 8 bytes per beat is active (`VDIVU`, active `8'h18 / 8'h06`, inactive `8'hFF / 8'h01`).
   - With zero external stall, an 8-beat (`vl = 32`, `EW16`, `vm = 0`) `VREM` with 1 of 4 halfwords per beat active (active `16'h002F % 16'h0009`, inactive `16'h7FFF % 16'h0001`) must finish in **`<= 84` cycles**.

3. **Nangate45 Synthesis & STA Closure (`BUILD.md`)**:
   - Clean, loop-free synthesis (`proc; check -assert;` exits `0`) on `vmfpu_synth_top` with zero inferred latches.
   - Mapped cell area **`<= 83,600.0 um^2`**, worst setup slack **`>= 0.000 ns`**, and worst hold/removal slack **`>= 0.000 ns`** at **`5.20 ns`** `clk_i` (`0.20 ns` I/O delays, `5.0 fF` output load).
