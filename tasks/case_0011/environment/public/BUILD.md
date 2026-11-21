# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/rtl/hwpe_ctrl_package.sv`: Upstream HWPE control package (read-only).
- `code/rtl/hwpe_ctrl_uloop.sv`: Upstream HWPE micro-loop offset processor (read-only).
- `code/rtl/hwpe_ctrl_partial_mult.sv`: Partially sequential stride multiplier (**editable target**).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.
  - Liberty units in `lib/NangateOpenCellLibrary_typical.lib`: `time_unit : "1ns"`, `capacitive_load_unit (1,ff)` (`1 fF`), area in `um^2`.

Edit only `code/rtl/hwpe_ctrl_partial_mult.sv`.

## 2. Functional Simulation (Verilator)

You can compile and simulate `hwpe_ctrl_partial_mult.sv` (and `hwpe_ctrl_uloop.sv`) with your own testbench using Verilator:

```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  code/rtl/hwpe_ctrl_package.sv \
  code/rtl/hwpe_ctrl_uloop.sv \
  code/rtl/hwpe_ctrl_partial_mult.sv \
  tb.sv
./obj_dir/Vtb
```

The evaluation checks `(AW=32, BW=32, MULT_BITS=4)`, `(AW=17, BW=11, MULT_BITS=4)`, and `(AW=24, BW=16, MULT_BITS=4)` across reset, mid-operation `clear_i`, normal and back-to-back `start_i` handshakes, both `invert_i = 0` and `invert_i = 1`, and stride accumulation into `hwpe_ctrl_uloop`.

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

Run Yosys with the Slang frontend to synthesize `hwpe_ctrl_partial_mult` at `AW=32, BW=32, MULT_BITS=4` and map to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
yosys -Q -T -m slang -p "
  read_slang --top hwpe_ctrl_partial_mult -G AW=32 -G BW=32 -G MULT_BITS=4 -DSYNTHESIS code/rtl/hwpe_ctrl_package.sv code/rtl/hwpe_ctrl_partial_mult.sv
  hierarchy -check -top hwpe_ctrl_partial_mult
  synth -top hwpe_ctrl_partial_mult
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```

Check the reported `Chip area for module '\hwpe_ctrl_partial_mult':` line in the output of `stat -liberty`. It must be `<= 1620.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Before reading the mapped netlist into OpenROAD, strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD with the following script (`flow.tcl`):

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design hwpe_ctrl_partial_mult
initialize_floorplan -die_area {0 0 400 400} -core_area {10 10 390 390} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 3.1 [get_ports clk_i]
set_input_delay 0.25 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.25 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.4
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
```

Run:

```bash
openroad -exit flow.tcl
```

Both the worst setup slack (`-path_delay max`) and worst hold/removal slack (`-path_delay min`) must be `>= 0.0` (`ns`), with an empty `check_setup -verbose` audit block.
