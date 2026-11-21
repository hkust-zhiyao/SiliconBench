# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/spi_host_fsm.sv`
- `code/spi_host_shift_register.sv`
- `code/spi_host_byte_select.sv`

All other files in `code/` (`spi_host_core.sv`, `spi_host_byte_merge.sv`, `spi_host_cmd_pkg.sv`, `spi_host_reg_pkg.sv`, `prim_packer_fifo.sv`, `prim_flop.sv`, `prim_flop_en.sv`, `prim_flop_macros.sv`, `prim_count_pkg.sv`, `prim_mubi_pkg.sv`, `prim_util_pkg.sv`, `top_pkg.sv`, `prim_assert.sv`, `prim_assert_*.svh`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `spi_host_core` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv code/prim_packer_fifo.sv \
  code/spi_host_reg_pkg.sv code/spi_host_cmd_pkg.sv code/spi_host_byte_select.sv \
  code/spi_host_byte_merge.sv code/spi_host_shift_register.sv code/spi_host_fsm.sv \
  code/spi_host_core.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `spi_host_core`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top spi_host_core -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv code/prim_packer_fifo.sv \
    code/spi_host_reg_pkg.sv code/spi_host_cmd_pkg.sv code/spi_host_byte_select.sv \
    code/spi_host_byte_merge.sv code/spi_host_shift_register.sv code/spi_host_fsm.sv \
    code/spi_host_core.sv;
  hierarchy -check -top spi_host_core;
  synth -top spi_host_core;
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

Target mapped cell area (`Chip area for module '\spi_host_core'`): **`<= 2035.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.02 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design spi_host_core
create_clock -name clk_i -period 2.02 [get_ports clk_i]
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
