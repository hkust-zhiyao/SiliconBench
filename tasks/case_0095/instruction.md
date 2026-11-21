# case_0095: CVFPU Multi-Format Cast and Non-Computational Unit Area and Critical-Path Delay Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwgroup/cvfpu` (`repo_35`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/rtl/fpnew_cast_multi.sv`, `code/rtl/fpnew_noncomp.sv`

---

## Problem Specification

# CVFPU Multi-Format Cast and Non-Computational Unit Area and Critical-Path Delay Closure

In the CVFPU multi-format conversion and non-computational subsystem (`code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv` integrated in `code/rtl/fpnew_cast_noncomp_top.sv`), wide denormalization shifting, cascaded two's-complement rounding-negation, and redundant pipeline registers cause excessive standard-cell area and critical-path arrival delay. Reduce the mapped area and critical-path delay of `code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv` while preserving exact IEEE-754 and RISC-V semantics across `F2F`, `F2I`, and `I2F` casts (`FP32`, `FP16`, `FP16ALT` and signed/unsigned `INT8`, `INT16`, `INT32`), `SGNJ`, `MINMAX`, `CMP`, and `CLASSIFY` operations, all rounding modes (`RNE`, `RTZ`, `RDN`, `RUP`, `RMM`), subnormal inputs and outputs, NaN-boxing checks (`is_boxed_i`), `status_o` flags (`NV, DZ, OF, UF, NX`), `extension_bit_o`, `in_valid_i`/`in_ready_o` and `out_valid_o`/`out_ready_i` handshakes under downstream stalls, synchronous `flush_i`, and asynchronous `rst_ni`.

Under `BUILD.md` (`NumPipeRegs=1, PipeConfig=fpnew_pkg::INSIDE`), `fpnew_cast_noncomp_top` must map to at most `3,525.0 um^2` in Nangate45, and OpenSTA must achieve nonnegative setup and hold slack under a `2.80 ns` clock (`clk_i`) with `0.20 ns` I/O delays and `3.0 fF` output load. Edit only `code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Guide

Editable files: `code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv`. All other files in `code/` and `lib/` are read-only.

## 1. Functional Simulation (Verilator)
```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  -Icode/include +define+COMMON_CELLS_ASSERTS_OFF \
  code/rtl/cf_math_pkg.sv code/rtl/lzc.sv code/rtl/fpnew_pkg.sv \
  code/rtl/fpnew_classifier.sv code/rtl/fpnew_rounding.sv \
  code/rtl/fpnew_cast_multi.sv code/rtl/fpnew_noncomp.sv \
  code/rtl/fpnew_cast_noncomp_top.sv tb.sv
./obj_dir/Vtb
```

## 2. Synthesis & Area (`Nangate45`, `<= 3525.0 um^2`)
```bash
yosys -Q -T -m slang -p "read_slang --top fpnew_cast_noncomp_top -Icode/include -DCOMMON_CELLS_ASSERTS_OFF -DSYNTHESIS code/rtl/cf_math_pkg.sv code/rtl/lzc.sv code/rtl/fpnew_pkg.sv code/rtl/fpnew_classifier.sv code/rtl/fpnew_rounding.sv code/rtl/fpnew_cast_multi.sv code/rtl/fpnew_noncomp.sv code/rtl/fpnew_cast_noncomp_top.sv; hierarchy -check -top fpnew_cast_noncomp_top; synth -top fpnew_cast_noncomp_top -flatten; opt; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; check -assert; stat -liberty lib/NangateOpenCellLibrary_typical.lib; write_verilog -noattr mapped.v"
```

## 3. OpenSTA (`2.80 ns` Clock)
Strip ` signed ` from `mapped.v` (`sed 's/ signed / /g' mapped.v > sta.v`) and run `openroad -exit sta.tcl`:
```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design fpnew_cast_noncomp_top
create_clock -name clk_i -period 2.80 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 3.0 [all_outputs]
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```
Worst setup and hold slack must be `>= 0.0 ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/rtl/fpnew_cast_multi.sv`
- `code/rtl/fpnew_noncomp.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
