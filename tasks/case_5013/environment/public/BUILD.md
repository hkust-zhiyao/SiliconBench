# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/lsu_bypass.sv`
- `code/load_unit.sv`
- `code/store_buffer.sv`
- `code/load_store_unit.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/lsu_subsys_top.sv` (top module: `lsu_subsys_top`)
- Liberty library: `lib/NangateOpenCellLibrary_typical.lib`
- LEF files:
  - `lef/NangateOpenCellLibrary.tech.lef`
  - `lef/NangateOpenCellLibrary.macro.mod.lef`

## Tool Paths
- Verilator: `verilator`
- Yosys: `yosys`
- OpenROAD: `openroad`

## RTL Elaboration & Simulation (Verilator)
```bash
verilator \
  --binary --timing -Wno-fatal \
  --top-module lsu_subsys_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/cf_math_pkg.sv \
  code/lzc.sv \
  code/shift_reg.sv \
  code/cva6_fifo_v3.sv \
  code/amo_buffer.sv \
  code/pmp_entry.sv \
  code/pmp.sv \
  code/pmp_data_if.sv \
  code/lsu_bypass.sv \
  code/store_buffer.sv \
  code/store_unit.sv \
  code/load_unit.sv \
  code/load_store_unit.sv \
  flow/lsu_subsys_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p '
  read_slang --ignore-assertions --top lsu_subsys_top -Iinclude -DSYNTHESIS
    code/config_pkg.sv
    code/cv64a60ax_config_pkg.sv
    code/riscv_pkg.sv
    code/ariane_pkg.sv
    code/cf_math_pkg.sv
    code/lzc.sv
    code/shift_reg.sv
    code/cva6_fifo_v3.sv
    code/amo_buffer.sv
    code/pmp_entry.sv
    code/pmp.sv
    code/pmp_data_if.sv
    code/lsu_bypass.sv
    code/store_buffer.sv
    code/store_unit.sv
    code/load_unit.sv
    code/load_store_unit.sv
    flow/lsu_subsys_top.sv;
  hierarchy -check -top lsu_subsys_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*;
  synth -top lsu_subsys_top -flatten;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 1000;
  clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -noexpr -nohex -nodec netlist.v
'
```

## Static Timing Analysis (OpenROAD)
With `design.sdc`:
```tcl
create_clock -name core_clk -period 1.80 [get_ports clk_i]
set_input_delay 0.15 -clock core_clk [all_inputs]
set_output_delay 0.15 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_ni]
```
Run OpenROAD:
```tcl
read_lef lef/NangateOpenCellLibrary.tech.lef
read_lef lef/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist.v
link_design lsu_subsys_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `lsu_subsys_top`: `<= 8260.0 um^2`
