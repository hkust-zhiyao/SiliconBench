# case_0091: NEureka Normalization-Quantization Rounding-Saturation, Stall Coherence, and Area/Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/neureka` (`repo_31`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/rtl/neureka_normquant.sv`, `code/rtl/neureka_normquant_shifter.sv`

---

## Problem Specification

# NEureka Normalization-Quantization Rounding-Saturation, Stall Coherence, and Area/Timing Closure

In the four-lane normalization-quantization unit (`code/rtl/neureka_normquant.sv` and `code/rtl/neureka_normquant_shifter.sv`), scaling, rounding, saturation, and pipeline control fail across operating modes. In `code/rtl/neureka_normquant.sv`, `flags_o[3:0].ready` must be driven high; the pipelined multipliers must advance only when `ctrl_i.start` is high (holding products when `ctrl_i.start` is low and clearing on `clear_i` or `rst_ni`); when `ctrl_i.norm_signed` is high, the scaling factor MSB is signed on every lane in `NEUREKA_MODE_8B`, odd lanes in `NEUREKA_MODE_16B` (even lanes unsigned), and lane 3 in `NEUREKA_MODE_32B` (lanes 0 to 2 unsigned); and 40-bit lane products must be sign-extended to 48 bits before shifted 16-bit/32-bit accumulation.

In `code/rtl/neureka_normquant_shifter.sv`, when `ctrl_i.use_shifting` is high with 5-bit shift amount `shift_i[4:0]`, add half-ULP rounding (`ctrl_i.use_rounding` and non-zero shift) before arithmetic right shift, then saturate to unsigned `[0, 2^K - 1]` when `ctrl_i.relu` is high or signed `[-2^(K-1), 2^(K-1) - 1]` when `ctrl_i.relu` is low (`K` in `{8, 16, 32}`, zero-extended to 32 bits). Under `BUILD.md`, achieve mapped area at most `915.0 um^2` for `neureka_normquant_shifter` (`INT=48, OUTPUT_REGISTER=1`), at most `4,685.0 um^2` for `neureka_normquant` (`OUTPUT_REGISTER=1`, multiplier blackboxed), and nonnegative setup/hold slack at a `1.75 ns` clock (`0.25 ns` I/O delays, `5.0 fF` load). Edit only `code/rtl/neureka_normquant.sv` and `code/rtl/neureka_normquant_shifter.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Guide

Editable files: `code/rtl/neureka_normquant.sv` and `code/rtl/neureka_normquant_shifter.sv`. All other files in `code/rtl/` and `lib/` are read-only.

## 1. Functional Simulation (Verilator)
```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  code/rtl/hwpe_stream_package.sv code/rtl/hci_package.sv code/rtl/neureka_package.sv \
  code/rtl/neureka_normquant_multiplier.sv code/rtl/neureka_normquant_shifter.sv \
  code/rtl/neureka_normquant.sv tb.sv
./obj_dir/Vtb
```

## 2. Synthesis & Area (`Nangate45`)
Shifter area (`<= 915.0 um^2`):
```bash
yosys -Q -T -m slang -p "read_slang --top neureka_normquant_shifter -G INT=48 -G OUTPUT_REGISTER=1 -DSYNTHESIS code/rtl/hwpe_stream_package.sv code/rtl/hci_package.sv code/rtl/neureka_package.sv code/rtl/neureka_normquant_shifter.sv; hierarchy -check -top neureka_normquant_shifter; synth -top neureka_normquant_shifter; opt; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; check -assert; stat -liberty lib/NangateOpenCellLibrary_typical.lib; write_verilog -noattr mapped_shifter.v"
```
Normquant datapath area (`<= 4685.0 um^2`, multiplier blackboxed):
```bash
yosys -Q -T -m slang -p "read_slang --blackboxed-module neureka_normquant_multiplier --top neureka_normquant -G OUTPUT_REGISTER=1 -DSYNTHESIS code/rtl/hwpe_stream_package.sv code/rtl/hci_package.sv code/rtl/neureka_package.sv code/rtl/neureka_normquant_multiplier.sv code/rtl/neureka_normquant_shifter.sv code/rtl/neureka_normquant.sv; hierarchy -check -top neureka_normquant; synth -top neureka_normquant -flatten; opt; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; check -assert; stat -liberty lib/NangateOpenCellLibrary_typical.lib"
```

## 3. OpenSTA (`1.75 ns` Clock)
Strip ` signed ` from `mapped_shifter.v` (`sed 's/ signed / /g' mapped_shifter.v > sta.v`) and run `openroad -exit sta.tcl`:
```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design neureka_normquant_shifter
create_clock -name clk_i -period 1.75 [get_ports clk_i]
set_input_delay 0.25 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.25 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```
Worst setup and hold slack must be `>= 0.0 ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/rtl/neureka_normquant.sv`
- `code/rtl/neureka_normquant_shifter.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
