# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Files and Read-Only Dependencies

Editable RTL files:
- `code/rtl/dynamic_input_route_request_calc.v`
- `code/rtl/dynamic_input_control.v`
- `code/rtl/dynamic_output_control.v`

All other files in `code/rtl/`, `code/include/`, and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Icarus Verilog`)

Compile and simulate the full 5-port router (`dynamic_node_top_wrap`) and its submodules:
```bash
iverilog -g2012 -s tb -I code/include -o sim.vvp \
  code/rtl/bus_compare_equal.v code/rtl/flip_bus.v code/rtl/net_dff.v \
  code/rtl/one_of_eight.v code/rtl/one_of_five.v \
  code/rtl/network_input_blk_multi_out.v code/rtl/space_avail_top.v \
  code/rtl/dynamic_input_route_request_calc.v code/rtl/dynamic_input_control.v \
  code/rtl/dynamic_input_top_4.v code/rtl/dynamic_input_top_16.v \
  code/rtl/dynamic_output_control.v code/rtl/dynamic_output_datapath.v \
  code/rtl/dynamic_output_top.v code/rtl/dynamic_node_top.v \
  code/rtl/dynamic_node_top_wrap.v tb.sv
vvp sim.vvp
```

## 3. Synthesis and Mapped Area (`Yosys + Slang`, Nangate45)

### 3.1 Input Control (`dynamic_input_control`, target area `<= 232.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top dynamic_input_control -I code/include \
    code/rtl/dynamic_input_route_request_calc.v \
    code/rtl/dynamic_input_control.v;
  hierarchy -check -top dynamic_input_control;
  synth -top dynamic_input_control;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_ic.v
"
```

### 3.2 Output Slice (`dynamic_output_top`, target area `<= 472.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top dynamic_output_top -I code/include \
    code/rtl/one_of_five.v code/rtl/space_avail_top.v \
    code/rtl/dynamic_output_control.v code/rtl/dynamic_output_datapath.v \
    code/rtl/dynamic_output_top.v;
  hierarchy -check -top dynamic_output_top;
  synth -top dynamic_output_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_out.v
"
```

## 4. OpenROAD Placement-Estimated Static Timing Analysis (`0.85 ns` Clock)

### 4.1 Input Control (`dynamic_input_control`)
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog mapped_ic.v
link_design dynamic_input_control
initialize_floorplan -die_area {0 0 60 60} -core_area {6 6 54 54} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk -period 0.85 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```

### 4.2 Output Slice (`dynamic_output_top`)
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog mapped_out.v
link_design dynamic_output_top
initialize_floorplan -die_area {0 0 80 80} -core_area {8 8 72 72} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk -period 0.85 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
repair_design
detailed_placement
estimate_parasitics -placement
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```

Both `dynamic_input_control` and `dynamic_output_top` must achieve worst setup slack (`-path_delay max`) **`>= 0.0 ns`** and worst hold slack (`-path_delay min`) **`>= 0.0 ns`** at `0.85 ns`.
