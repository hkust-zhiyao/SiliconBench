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
