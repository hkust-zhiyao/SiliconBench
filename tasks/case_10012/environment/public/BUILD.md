# Build, Simulation, and Synthesis/STA Guide

## 1. Editable Files
Only the following files are collected and graded:
- `code/rtl/io_xbar_input_route_request_calc.v`
- `code/rtl/io_xbar_input_control.v`
- `code/rtl/io_xbar_output_control.v`

All other files in `code/` (`code/rtl/io_xbar_output_top.v`, `code/rtl/io_xbar_output_datapath.v`, `code/rtl/one_of_eight.v`, `code/rtl/space_avail_top.v`, `code/rtl/bus_compare_equal.v`, `code/rtl/flip_bus.v`, `code/rtl/net_dff.v`, `code/include/*`, `code/LICENSE`, and `lib/*`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Icarus Verilog`)
```bash
iverilog -g2012 -s tb -I code/include -o sim.vvp \
  code/rtl/bus_compare_equal.v code/rtl/flip_bus.v code/rtl/net_dff.v \
  code/rtl/one_of_eight.v code/rtl/space_avail_top.v \
  code/rtl/io_xbar_input_route_request_calc.v code/rtl/io_xbar_input_control.v \
  code/rtl/io_xbar_output_control.v code/rtl/io_xbar_output_datapath.v \
  code/rtl/io_xbar_output_top.v <your_tb.sv>
vvp sim.vvp
```

## 3. Synthesis and Static Timing Analysis (`Yosys/Slang` + `OpenROAD`)
1. `io_xbar_input_control` (elaborated with `io_xbar_input_route_request_calc.v`):
   - Synthesized with `yosys -m slang` (`synth -top io_xbar_input_control; opt; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean`) -> mapped area **`<= 195.0 um^2`**;
   - Evaluated in OpenROAD (`60x60 um` die, `6..54 um` core, `0.85 ns` clock period on `clk`, `0.15 ns` I/O delays, `5.0 fF` load, `0.50` density) -> setup and hold slack **`>= 0.0 ns`**.
2. `io_xbar_output_top` (elaborated with `one_of_eight.v`, `space_avail_top.v`, `io_xbar_output_datapath.v`, `io_xbar_output_control.v`, `io_xbar_output_top.v`):
   - Synthesized with `yosys -m slang` -> mapped area **`<= 720.0 um^2`**;
   - Evaluated in OpenROAD (`90x90 um` die, `9..81 um` core, `0.85 ns` clock period on `clk`, `0.15 ns` I/O delays, `5.0 fF` load, `0.50` density, `repair_design`, `detailed_placement`) -> setup and hold slack **`>= 0.0 ns`**.
