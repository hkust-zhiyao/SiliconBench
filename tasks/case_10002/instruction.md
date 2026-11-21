# case_10002: OpenPiton 5-Port Mesh Router Input Control, Output Arbitration Fairness, and Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `princetonuniversity/openpiton` (`repo_10`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/rtl/dynamic_input_route_request_calc.v`, `code/rtl/dynamic_input_control.v`, `code/rtl/dynamic_output_control.v`

---

## Problem Specification

# OpenPiton 5-Port Mesh Router Input Control, Output Arbitration Fairness, and Timing Closure

In the OpenPiton 5-port 2D mesh dynamic router (`code/rtl/dynamic_node_top_wrap.v` and `code/rtl/dynamic_node_top.v`), update `code/rtl/dynamic_input_route_request_calc.v`, `code/rtl/dynamic_input_control.v`, and `code/rtl/dynamic_output_control.v` so that route calculation, multi-flit packet framing, output arbitration fairness, reset initialization, and static timing closure pass verification:

- **Dimension-ordered XY routing and final-hop decoding (`dynamic_input_route_request_calc`)**: When `header_in` is high, compare the packet destination (`abs_chip_id`, `abs_x`, `abs_y`) against the local tile coordinates (`my_chip_id_in`, `my_loc_x_in`, `my_loc_y_in`); for off-chip packets (`abs_chip_id != my_chip_id_in`), route toward the off-chip gateway coordinate (`OFF_CHIP_NODE_X`, `OFF_CHIP_NODE_Y`). Route in X first (`route_req_e` if target X > local X, `route_req_w` if target X < local X), then Y (`route_req_s` if target Y > local Y, `route_req_n` if target Y < local Y). When at the target `(X, Y)`, decode `final_bits` (`FINAL_NORTH = 3'b101`, `FINAL_SOUTH = 3'b011`, `FINAL_EAST = 3'b100`, `FINAL_WEST = 3'b010`, and default to `route_req_p` for `FINAL_NONE = 3'b000` or any other `final_bits` code) so that every valid header asserts at least one route request, with `default_ready_*` matching `route_req_*`.
- **Full 8-bit payload length tracking and synchronous reset (`dynamic_input_control`)**: Track all `PAYLOAD_LEN` (`8`) bits of `length` across reset and packet transfers (`0` to `255` payload flits following the header), asserting `tail_out` on single-flit headers (`length == 8'd0`) and on the final payload beat of multi-flit packets, and holding `tail_out` stable across upstream NIB bubbles (`valid_in == 1'b0`) or downstream stalls (`thanks_* == 1'b0`) until that final beat is granted.
- **Work-conserving round-robin output arbitration and starvation bound (`dynamic_output_control`)**: On `reset`, initialize `current_route_f <= 3'd0`, `planned_f <= 1'b0`, and `ec_wants_to_send_but_cannot <= 1'b0`, and drive `thanks_a..x` and `tail_current_route` to `1'b0` (never `1'bx`) on default/unused states. When `planned_f` is high, hold `current_route_f` locked across cycles until the active packet's tail flit is transferred (`valid_out && tail_current_route`). In the rotating priority encoder (`ROUTE_A -> ROUTE_B -> ROUTE_C -> ROUTE_D -> ROUTE_X -> ROUTE_A`), include the self-fallback branch on every route (`ROUTE_A` through `ROUTE_X`) so a requester that just completed a packet is immediately re-selected (`planned_temp = 1'b1`) if no other port requests, and preserve the last-completed route across idle cycles (`!planned_f`) so any continuously requesting input port is granted after at most `4` packets from other inputs even when contenders request across intermittent idle gaps.

Under the Nangate45 synthesis and OpenROAD placement-estimated STA flows in `BUILD.md`:
1. `dynamic_input_control` must map to **`<= 232.0 um^2`** and achieve setup and hold slack **`>= 0.0 ns`** at a **`0.85 ns`** clock (`0.15 ns` I/O delays, `5.0 fF` load).
2. `dynamic_output_top` must map to **`<= 472.0 um^2`** and achieve setup and hold slack **`>= 0.0 ns`** at a **`0.85 ns`** clock (`0.15 ns` I/O delays, `5.0 fF` load).

Edit only `code/rtl/dynamic_input_route_request_calc.v`, `code/rtl/dynamic_input_control.v`, and `code/rtl/dynamic_output_control.v`.

---

## Build, Simulation, and EDA Verification Instructions

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

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/rtl/dynamic_input_route_request_calc.v`
- `code/rtl/dynamic_input_control.v`
- `code/rtl/dynamic_output_control.v`

All other files in the workspace are read-only reference context and must remain unmodified.
