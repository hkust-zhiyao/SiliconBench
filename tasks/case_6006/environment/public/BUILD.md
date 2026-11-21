# Build, Simulation, Synthesis, and Static Timing Guide (`veer_ifu_bp_mem_top`)

## 1. Editable Files
Only the following three files in `code/` are collected and graded:
- `code/ifu_ifc_ctl.sv`
- `code/ifu_bp_ctl.sv`
- `code/ifu_mem_ctl.sv`

All other files (`code/veer_ifu_bp_mem_top.sv`, `code/common_defines.vh`, `code/global.h`, `code/veer_types.sv`, `code/beh_lib.sv`, `code/LICENSE`, and `lib/*`) are read-only.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/ifu_ifc_ctl.sv code/ifu_bp_ctl.sv code/ifu_mem_ctl.sv \
  code/veer_ifu_bp_mem_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis & Static Timing Analysis (`Yosys/Slang` + `OpenROAD`)
```bash
yosys -m slang -p "
  read_slang --single-unit --top veer_ifu_bp_mem_top -Icode \
    code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
    code/ifu_ifc_ctl.sv code/ifu_bp_ctl.sv code/ifu_mem_ctl.sv code/veer_ifu_bp_mem_top.sv;
  hierarchy -check -top veer_ifu_bp_mem_top;
  proc;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  opt_clean;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top veer_ifu_bp_mem_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped.v
"
```

OpenROAD STA constraints (`3.65 ns` clock on `clk`):
```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design veer_ifu_bp_mem_top
create_clock -name clk -period 3.65 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports {rst_l scan_mode}]
```
