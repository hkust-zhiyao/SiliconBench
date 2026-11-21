# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/rtl/cv32e40p_prefetch_controller.sv`
- `code/rtl/cv32e40p_prefetch_buffer.sv`
- `code/rtl/cv32e40p_aligner.sv`
- `code/rtl/cv32e40p_if_stage.sv`

All other files in `code/` (`code/rtl/include/cv32e40p_pkg.sv`, `code/rtl/cv32e40p_fifo.sv`, `code/rtl/cv32e40p_obi_interface.sv`, `code/rtl/cv32e40p_compressed_decoder.sv`, `code/LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only and must remain unmodified.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `cv32e40p_if_stage` (`COREV_PULP = 1`, `PULP_OBI = 0`) with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  -Icode/rtl/include --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/rtl/include/cv32e40p_pkg.sv \
  code/rtl/cv32e40p_fifo.sv \
  code/rtl/cv32e40p_obi_interface.sv \
  code/rtl/cv32e40p_prefetch_controller.sv \
  code/rtl/cv32e40p_prefetch_buffer.sv \
  code/rtl/cv32e40p_aligner.sv \
  code/rtl/cv32e40p_compressed_decoder.sv \
  code/rtl/cv32e40p_if_stage.sv \
  /tmp/<your_tb>.sv
/tmp/obj_dir/V<your_tb>
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `cv32e40p_if_stage` (`COREV_PULP = 1`, `PULP_OBI = 0`):

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top cv32e40p_if_stage -G COREV_PULP=1 -G PULP_OBI=0 -Icode/rtl/include \
    code/rtl/include/cv32e40p_pkg.sv \
    code/rtl/cv32e40p_fifo.sv \
    code/rtl/cv32e40p_obi_interface.sv \
    code/rtl/cv32e40p_prefetch_controller.sv \
    code/rtl/cv32e40p_prefetch_buffer.sv \
    code/rtl/cv32e40p_aligner.sv \
    code/rtl/cv32e40p_compressed_decoder.sv \
    code/rtl/cv32e40p_if_stage.sv;
  hierarchy -check -top cv32e40p_if_stage;
  proc; opt_clean;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top cv32e40p_if_stage;
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

Target mapped cell area (`Chip area for module '\cv32e40p_if_stage'`): **`<= 3748.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `1.25 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_n`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design cv32e40p_if_stage
create_clock -name clk -period 1.25 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_n]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```

Target worst setup slack (`WNS`) and worst hold slack (`WHS`): **`>= 0.00 ns`**.
