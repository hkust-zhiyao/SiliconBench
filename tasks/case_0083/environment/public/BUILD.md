# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/idma_nd_midend.sv`
- `code/idma_legalizer_page_splitter.sv`
- `code/idma_legalizer.sv`

All other files in `code/` (`idma_nd_legalizer_top.sv`, `idma_pkg.sv`, `axi_pkg.sv`, `cc_pkg.sv`, `cc_popcount.sv`, `include/*`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `idma_nd_legalizer_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Wno-fatal -Icode/include -DSYNTHESIS \
  --top-module tb \
  code/cc_pkg.sv code/axi_pkg.sv code/idma_pkg.sv code/cc_popcount.sv \
  code/idma_legalizer_page_splitter.sv code/idma_legalizer.sv \
  code/idma_nd_midend.sv code/idma_nd_legalizer_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `idma_nd_legalizer_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --top idma_nd_legalizer_top -Icode/include -DSYNTHESIS \
    code/cc_pkg.sv code/axi_pkg.sv code/idma_pkg.sv code/cc_popcount.sv \
    code/idma_legalizer_page_splitter.sv code/idma_legalizer.sv \
    code/idma_nd_midend.sv code/idma_nd_legalizer_top.sv;
  hierarchy -check -top idma_nd_legalizer_top;
  synth -top idma_nd_legalizer_top;
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

Target mapped cell area (`Chip area for module '\idma_nd_legalizer_top'`): **`<= 3680.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.70 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design idma_nd_legalizer_top
create_clock -name clk_i -period 2.70 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded -digits 4
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded -digits 4
```

Target worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`): **`>= 0.0 ns`**.
