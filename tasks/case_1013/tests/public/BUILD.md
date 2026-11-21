# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/rom_ctrl_fsm.sv`
- `code/rom_ctrl_compare.sv`
- `code/rom_ctrl_mux.sv`

All other files in `code/` (`ot_rom_ctrl_top.sv`, `rom_ctrl_counter.sv`, `rom_ctrl_pkg.sv`, `rom_ctrl_reg_pkg.sv`, `kmac_pkg.sv`, `kmac_reg_pkg.sv`, `sha3_pkg.sv`, `lc_ctrl_pkg.sv`, `lc_ctrl_reg_pkg.sv`, `lc_ctrl_state_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_rom_ctrl_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv \
  code/lc_ctrl_pkg.sv code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
  code/rom_ctrl_reg_pkg.sv code/rom_ctrl_pkg.sv code/prim_flop_macros.sv \
  code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
  code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
  code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/rom_ctrl_counter.sv code/rom_ctrl_compare.sv code/rom_ctrl_fsm.sv \
  code/rom_ctrl_mux.sv code/ot_rom_ctrl_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_rom_ctrl_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_rom_ctrl_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv \
    code/lc_ctrl_pkg.sv code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
    code/rom_ctrl_reg_pkg.sv code/rom_ctrl_pkg.sv code/prim_flop_macros.sv \
    code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
    code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
    code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/rom_ctrl_counter.sv code/rom_ctrl_compare.sv code/rom_ctrl_fsm.sv \
    code/rom_ctrl_mux.sv code/ot_rom_ctrl_top.sv;
  hierarchy -check -top ot_rom_ctrl_top;
  synth -top ot_rom_ctrl_top;
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

Target mapped cell area (`Chip area for module '\ot_rom_ctrl_top'`): **`<= 1020.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `1.05 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_rom_ctrl_top
create_clock -name clk_i -period 1.05 [get_ports clk_i]
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
