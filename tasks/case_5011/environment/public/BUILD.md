# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/macro_decoder.sv`
- `code/zcmt_decoder.sv`
- `code/id_stage.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/id_decode_top.sv` (top module: `id_decode_top`)
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
  --top-module id_decode_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/cva6_accel_first_pass_decoder_stub.sv \
  code/cvxif_compressed_if_driver.sv \
  code/compressed_decoder.sv \
  code/macro_decoder.sv \
  code/zcmt_decoder.sv \
  code/decoder.sv \
  code/id_stage.sv \
  flow/id_decode_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top id_decode_top -Iinclude -DSYNTHESIS \
    code/config_pkg.sv \
    code/cv64a60ax_config_pkg.sv \
    code/riscv_pkg.sv \
    code/ariane_pkg.sv \
    code/cva6_accel_first_pass_decoder_stub.sv \
    code/cvxif_compressed_if_driver.sv \
    code/compressed_decoder.sv \
    code/macro_decoder.sv \
    code/zcmt_decoder.sv \
    code/decoder.sv \
    code/id_stage.sv \
    flow/id_decode_top.sv;
  hierarchy -check -top id_decode_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top id_decode_top -flatten;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 1000;
  clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -noexpr -nohex -nodec netlist.v
"
```

## Static Timing Analysis (OpenROAD)
With `design.sdc`:
```tcl
create_clock -name core_clk -period 1.95 [get_ports clk_i]
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
link_design id_decode_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `id_decode_top`: `<= 2560.0 um^2`
