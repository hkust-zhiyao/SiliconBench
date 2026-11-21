# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/eh2_ifu_ifc_ctl.sv`
- `code/eh2_ifu_aln_ctl.sv`
- `code/eh2_dec_ib_ctl.sv`

All other files in `code/` (`common_defines.vh`, `eh2_param.vh`, `eh2_pdef.vh`, `eh2_def.sv`, `beh_lib.sv`, `eh2_lib.sv`, `eh2_ifu_compress_ctl.sv`, `eh2_ifu_ib_top.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `eh2_ifu_ib_top` with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -Icode --top-module tb \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
  code/eh2_ifu_compress_ctl.sv code/eh2_ifu_ifc_ctl.sv \
  code/eh2_ifu_aln_ctl.sv code/eh2_dec_ib_ctl.sv \
  code/eh2_ifu_ib_top.sv /tmp/tb.sv
./obj_dir/Vtb
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `eh2_ifu_ib_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top eh2_ifu_ib_top -Icode \
    code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
    code/eh2_ifu_compress_ctl.sv code/eh2_ifu_ifc_ctl.sv \
    code/eh2_ifu_aln_ctl.sv code/eh2_dec_ib_ctl.sv code/eh2_ifu_ib_top.sv;
  hierarchy -check -top eh2_ifu_ib_top;
  proc; opt_clean;
  chformal -remove;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top eh2_ifu_ib_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr /tmp/mapped.v
"
```

Target mapped cell area (`Chip area for module '\eh2_ifu_ib_top'`): **`<= 20250.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `9.25 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_l` and `scan_mode`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design eh2_ifu_ib_top
create_clock -name clk -period 9.25 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports {rst_l scan_mode}]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```

Target worst setup slack (`WNS`) and worst hold slack (`WHS`): **`>= 0.00 ns`**.
