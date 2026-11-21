# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/wt_axi_adapter.sv`
- `code/axi_shim.sv`
- `code/cva6_fifo_v3.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/wt_axi_subsys_top.sv` (top module: `wt_axi_subsys_top`)
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
  --top-module wt_axi_subsys_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/axi_pkg.sv \
  code/wt_cache_pkg.sv \
  code/cf_math_pkg.sv \
  code/lzc.sv \
  code/rr_arb_tree.sv \
  code/cva6_fifo_v3.sv \
  code/axi_shim.sv \
  code/wt_axi_adapter.sv \
  flow/wt_axi_subsys_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p '
  read_slang --ignore-assertions --top wt_axi_subsys_top -Iinclude -DSYNTHESIS
    code/config_pkg.sv
    code/cv64a60ax_config_pkg.sv
    code/riscv_pkg.sv
    code/ariane_pkg.sv
    code/axi_pkg.sv
    code/wt_cache_pkg.sv
    code/cf_math_pkg.sv
    code/lzc.sv
    code/rr_arb_tree.sv
    code/cva6_fifo_v3.sv
    code/axi_shim.sv
    code/wt_axi_adapter.sv
    flow/wt_axi_subsys_top.sv;
  hierarchy -check -top wt_axi_subsys_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*;
  synth -top wt_axi_subsys_top -flatten;
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
create_clock -name core_clk -period 2.35 [get_ports clk_i]
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
link_design wt_axi_subsys_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `wt_axi_subsys_top`: `<= 6450.0 um^2`
