# case_22003: Ara Lane Integer VMFPU and SIMD Divider Masked-Element Fast-Skip, Multi-Phase Descriptor Decoupling, and Nangate45 PPA/STA Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/ara` (`repo_19`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/vmfpu.sv`, `code/simd_div.sv`

---

## Problem Specification

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

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Workspace Layout and Editable Scope

- **Editable RTL files** (edit ONLY these two files):
  - `code/vmfpu.sv`: Ara per-lane multi-phase vector multiplier/divider functional unit (`module vmfpu`).
  - `code/simd_div.sv`: Ara per-lane 64-bit SIMD serial integer divider wrapper (`module simd_div`).
- **Read-only RTL and package closure** (`code/`):
  - `code/vmfpu_synth_top.sv`: Concrete lane synthesis/verification wrapper instantiating `vmfpu` with `NrLanes = 4`, `VLEN = 4096`, `FPUSupport = FPUSupportNone`, `FPExtSupport = FPExtSupportNone`, `FixPtSupport = FixedPointEnable`.
  - `code/simd_mul.sv`, `code/serdiv.sv`, `code/power_gating_generic.sv`, `code/tc_clk.sv`, `code/lzc.sv`, `code/spill_register.sv`, `code/spill_register_flushable.sv`: Read-only arithmetic and common-cell submodules.
  - `code/cf_math_pkg.sv`, `code/config_pkg.sv`, `code/cv64a6_imafdcv_sv39_config_pkg.sv`, `code/riscv_pkg.sv`, `code/ariane_pkg.sv`, `code/axi_pkg.sv`, `code/fpnew_pkg.sv`, `code/rvv_pkg.sv`, `code/ara_pkg.sv`, and `code/include/common_cells/{registers.svh,assertions.svh}`: Read-only SystemVerilog packages and headers.
- **Read-only Nangate45 PDK collateral** (`lib/`):
  - `lib/NangateOpenCellLibrary_typical.lib` (`1 ns`, `1 fF`, area in `um^2`)
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

Do not modify any file outside `code/vmfpu.sv` and `code/simd_div.sv`.

## 2. Functional & Latency Simulation (Verilator)

Compile the RTL closure in package-dependency order using Verilator (`verilator-v5.038`):

```bash
verilator \
  --binary --timing -j 4 -Wno-fatal --top-module tb \
  -Icode/include \
  code/cf_math_pkg.sv \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/lzc.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/tc_clk.sv \
  code/power_gating_generic.sv \
  code/serdiv.sv \
  code/simd_mul.sv \
  code/simd_div.sv \
  code/vmfpu.sv \
  code/vmfpu_synth_top.sv \
  tb.sv
./obj_dir/Vtb
```

## 3. Deterministic Nangate45 Logic Synthesis (Yosys + Slang)

Synthesize `vmfpu_synth_top` with Yosys (`-m slang`) and ABC mapped to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
FILES="code/cf_math_pkg.sv code/config_pkg.sv code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
  code/rvv_pkg.sv code/ara_pkg.sv code/lzc.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/tc_clk.sv code/power_gating_generic.sv \
  code/serdiv.sv code/simd_mul.sv code/simd_div.sv code/vmfpu.sv code/vmfpu_synth_top.sv"

yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode/include --top vmfpu_synth_top --ignore-assertions ${FILES};
  hierarchy -check -top vmfpu_synth_top;
  proc;
  check -assert;
  synth -top vmfpu_synth_top -noabc;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -script +strash;dc2;map;
  opt_clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr netlist.v
"
```

Sign-off requirements for synthesis:
1. `proc; check -assert;` must pass with zero combinational logic loops or undriven/multiple-driver errors.
2. Total mapped cell area reported by `Chip area for module '\vmfpu_synth_top':` must be **`<= 83600.0` `um^2`**.

## 4. Static Timing Analysis (OpenROAD)

Evaluate setup and hold timing on the synthesized `netlist.v` with OpenROAD (`sta.tcl`):

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist.v
link_design vmfpu_synth_top
create_clock -name clk_i -period 5.20 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
puts "=== SETUP ==="
report_checks -path_delay max -group_path_count 5 -digits 3
puts "=== HOLD ==="
report_checks -path_delay min -group_path_count 5 -digits 3
```

Run:

```bash
openroad -exit sta.tcl
```

Sign-off requirements for timing:
- Worst setup slack (`-path_delay max`) must be **`>= 0.000 ns`** at `clk_i` period `5.20 ns`.
- Worst hold/removal slack (`-path_delay min`) must be **`>= 0.000 ns`**.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/vmfpu.sv`
- `code/simd_div.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
