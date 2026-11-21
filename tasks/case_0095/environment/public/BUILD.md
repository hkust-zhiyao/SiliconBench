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
