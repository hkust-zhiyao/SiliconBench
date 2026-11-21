# Build, Simulation, Synthesis, and STA Guide

## 1. Editable Files
Only the following three RTL files are collected and graded:
- `code/ibex_load_store_unit.sv`
- `code/ibex_wb_stage.sv`
- `code/ibex_pmp.sv`

All other files in `code/` and `lib/` (`code/ibex_lsu_wb_pmp_top.sv`, `code/ibex_pkg.sv`, `code/ibex_cheriot_pkg.sv`, `code/prim_*`, `code/dv_fcov_macros.svh`, `lib/*`) are read-only and must remain unmodified.

## 2. Behavioral Simulation (`Verilator`)
Compile and simulate `code/ibex_lsu_wb_pmp_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module <your_tb> --Mdir obj \
  code/prim_util_pkg.sv code/prim_secded_pkg.sv \
  code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
  code/prim_buf.sv code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
  code/ibex_pmp.sv code/ibex_load_store_unit.sv code/ibex_wb_stage.sv \
  code/ibex_lsu_wb_pmp_top.sv <your_tb.sv>
./obj/V<your_tb>
```

## 3. Logic Synthesis & Area Evaluation (`Yosys + Slang`, `Nangate45`)
Synthesize `ibex_lsu_wb_pmp_top` to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
yosys \
  -m slang -Q -T -p "
    read_slang --top ibex_lsu_wb_pmp_top -Icode -DSYNTHESIS \
      code/prim_util_pkg.sv code/prim_secded_pkg.sv \
      code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
      code/prim_buf.sv code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
      code/ibex_pmp.sv code/ibex_load_store_unit.sv code/ibex_wb_stage.sv \
      code/ibex_lsu_wb_pmp_top.sv;
    hierarchy -check -top ibex_lsu_wb_pmp_top;
    proc; opt_clean;
    select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
    synth -top ibex_lsu_wb_pmp_top;
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
- **Latch Check**: Zero latches allowed.
- **Mapped Cell Area Target**: `Chip area for module '\ibex_lsu_wb_pmp_top'` must be `<= 5,750.0 um^2`.

## 4. Static Timing Analysis (`OpenROAD / OpenSTA`)
Evaluate setup and hold slack on `mapped.v` under a `2.05 ns` clock on `clk_i`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog mapped.v
link_design ibex_lsu_wb_pmp_top
create_clock -name clk_i -period 2.05 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
- **Timing Targets**: `WNS >= 0.00 ns` and `WHS >= 0.00 ns`.
