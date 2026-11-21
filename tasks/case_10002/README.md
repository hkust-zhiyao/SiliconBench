# `case_10002`: OpenPiton 5-Port Mesh Router Input Control, Output Arbitration Fairness, and Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_10002` |
| **Source Silicon Repository** | `princetonuniversity/openpiton` (`repo_10`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `protocol_control`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/dynamic_input_route_request_calc.v`](environment/public/code/rtl/dynamic_input_route_request_calc.v), [`code/rtl/dynamic_input_control.v`](environment/public/code/rtl/dynamic_input_control.v), [`code/rtl/dynamic_output_control.v`](environment/public/code/rtl/dynamic_output_control.v) (3 files, 818 LOC) |
| **Public Subsystem Context** | 17 RTL files (2555 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

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

## 3. Build & Verification Instructions (`BUILD.md`)

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

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/dynamic_input_route_request_calc.v (Buggy Starter)
+++ b/solution/gold/code/rtl/dynamic_input_route_request_calc.v (Golden Reference)
@@ -1,48 +1,10 @@
-/*
-Copyright (c) 2015 Princeton University
-All rights reserved.
-
-Redistribution and use in source and binary forms, with or without
-modification, are permitted provided that the following conditions are met:
-    * Redistributions of source code must retain the above copyright
-      notice, this list of conditions and the following disclaimer.
-    * Redistributions in binary form must reproduce the above copyright
-      notice, this list of conditions and the following disclaimer in the
-      documentation and/or other materials provided with the distribution.
-    * Neither the name of Princeton University nor the
-      names of its contributors may be used to endorse or promote products
-      derived from this software without specific prior written permission.
-
-THIS SOFTWARE IS PROVIDED BY PRINCETON UNIVERSITY "AS IS" AND
-ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-DISCLAIMED. IN NO EVENT SHALL PRINCETON UNIVERSITY BE LIABLE FOR ANY
-DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-*/
-
-//Function: This generates all of the route_request lines and the default_ready lines from
-//the absolute location of the tile, the abs address of the message, and the fbits of the message
-//
-//State: 
-//NONE
-//
-//Instantiates: 
-//
-//Note:
-//
-
 `include "network_define.v"
 
-module dynamic_input_route_request_calc(route_req_n, route_req_e, route_req_s, route_req_w, route_req_p, 
-                                        default_ready_n, default_ready_e, default_ready_s, default_ready_w, default_ready_p, 
-                                        my_loc_x_in, my_loc_y_in, my_chip_id_in, abs_x, abs_y, abs_chip_id, final_bits, length, header_in);
-
-// begin port declarations
+module dynamic_input_route_request_calc(
+    route_req_n, route_req_e, route_req_s, route_req_w, route_req_p,
+    default_ready_n, default_ready_e, default_ready_s, default_ready_w, default_ready_p,
+    my_loc_x_in, my_loc_y_in, my_chip_id_in, abs_x, abs_y, abs_chip_id, final_bits, length, header_in
+);
 
 output route_req_n;
 output route_req_e;
@@ -61,70 +23,49 @@
 input [`XY_WIDTH-1:0] abs_x;
 input [`XY_WIDTH-1:0] abs_y;
 input [`CHIP_ID_WIDTH-1:0] abs_chip_id;
-
 input [2:0] final_bits;
 input [`PAYLOAD_LEN-1:0] length;
 input header_in;
 
-// end port declarations
-   
-//fbit declarations
-`define FINAL_NONE	3'b000
-`define FINAL_WEST	3'b010
-`define FINAL_SOUTH	3'b011
-`define FINAL_EAST	3'b100
-`define FINAL_NORTH	3'b101
+`define FINAL_NONE  3'b000
+`define FINAL_WEST  3'b010
+`define FINAL_SOUTH 3'b011
+`define FINAL_EAST  3'b100
+`define FINAL_NORTH 3'b101
 
-//This is the state
-//NONE
+wire off_chip = (abs_chip_id != my_chip_id_in);
 
-//inputs to the state
-//NONE
+wire x_eq_abs = (abs_x == my_loc_x_in);
+wire x_gt_abs = (abs_x >  my_loc_x_in);
+wire x_lt_abs = (abs_x <  my_loc_x_in);
+wire x_nz_loc = |my_loc_x_in;
 
-//wires
-wire more_x;
-wire more_y;
-wire less_x;
-wire less_y;
-wire done_x;
-wire done_y;
-wire off_chip;
+wire y_eq_abs = (abs_y == my_loc_y_in);
+wire y_gt_abs = (abs_y >  my_loc_y_in);
+wire y_lt_abs = (abs_y <  my_loc_y_in);
+wire y_nz_loc = |my_loc_y_in;
 
-wire done;
+wire done_x = off_chip ? ~x_nz_loc : x_eq_abs;
+wire more_x = ~off_chip & x_gt_abs;
+wire less_x = off_chip ?  x_nz_loc : x_lt_abs;
 
-wire north;
-wire east;
-wire south;
-wire west;
-wire proc;
+wire done_y = off_chip ? ~y_nz_loc : y_eq_abs;
+wire more_y = ~off_chip & y_gt_abs;
+wire less_y = off_chip ?  y_nz_loc : y_lt_abs;
 
-wire north_calc;
-wire south_calc;
+wire done = done_x & done_y;
 
-//wire regs
+wire is_fn = (final_bits == `FINAL_NORTH);
+wire is_fs = (final_bits == `FINAL_SOUTH);
+wire is_fe = (final_bits == `FINAL_EAST);
+wire is_fw = (final_bits == `FINAL_WEST);
+wire is_fp = ~(is_fn | is_fs | is_fe | is_fw);
 
-//assigns
-
-assign off_chip = abs_chip_id != my_chip_id_in;
-assign more_x = off_chip ? `OFF_CHIP_NODE_X > my_loc_x_in : abs_x > my_loc_x_in;
-assign more_y = off_chip ? `OFF_CHIP_NODE_Y > my_loc_y_in : abs_y > my_loc_y_in;
-
-assign less_x = off_chip ? `OFF_CHIP_NODE_X < my_loc_x_in : abs_x < my_loc_x_in;
-assign less_y = off_chip ? `OFF_CHIP_NODE_Y < my_loc_y_in : abs_y < my_loc_y_in;
-
-assign done_x = off_chip ? `OFF_CHIP_NODE_X == my_loc_x_in : abs_x == my_loc_x_in;
-assign done_y = off_chip ? `OFF_CHIP_NODE_Y == my_loc_y_in : abs_y == my_loc_y_in;
-
-assign done = done_x & done_y;
-
-assign north_calc = done_x & less_y;
-assign south_calc = done_x & more_y;
-
-assign north = north_calc | ((final_bits == `FINAL_NORTH) & done);
-assign south = south_calc | ((final_bits == `FINAL_SOUTH) & done);
-assign east = more_x | ((final_bits == `FINAL_EAST) & done);
-assign west = less_x | ((final_bits == `FINAL_WEST) & done);
-assign proc = ((final_bits == `FINAL_NONE) & done);
+wire north = (done_x & less_y) | (done & is_fn);
+wire south = (done_x & more_y) | (done & is_fs);
+wire east  = more_x            | (done & is_fe);
+wire west  = less_x            | (done & is_fw);
+wire proc  = done & is_fp;
 
 assign route_req_n = header_in & north;
 assign route_req_e = header_in & east;
@@ -138,7 +79,4 @@
 assign default_ready_w = route_req_w;
 assign default_ready_p = route_req_p;
 
-//instantiations
-
 endmodule
-   

--- a/environment/public/code/rtl/dynamic_input_control.v (Buggy Starter)
+++ b/solution/gold/code/rtl/dynamic_input_control.v (Golden Reference)
@@ -1,55 +1,14 @@
-/*
-Copyright (c) 2015 Princeton University
-All rights reserved.
-
-Redistribution and use in source and binary forms, with or without
-modification, are permitted provided that the following conditions are met:
-    * Redistributions of source code must retain the above copyright
-      notice, this list of conditions and the following disclaimer.
-    * Redistributions in binary form must reproduce the above copyright
-      notice, this list of conditions and the following disclaimer in the
-      documentation and/or other materials provided with the distribution.
-    * Neither the name of Princeton University nor the
-      names of its contributors may be used to endorse or promote products
-      derived from this software without specific prior written permission.
-
-THIS SOFTWARE IS PROVIDED BY PRINCETON UNIVERSITY "AS IS" AND
-ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-DISCLAIMED. IN NO EVENT SHALL PRINCETON UNIVERSITY BE LIABLE FOR ANY
-DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-*/
-
-//Function: This maintains the control of where different signals want to go
-//and counters of how many words are left in messages
-//
-//State:
-//header_temp_f  //header_temp from the previous cycle
-//count_f       //the counter of how much more we have to go
-//tail_last_f   //what the tail bit wa the last cycle
-//count_zero_f  //whether the counter now is zero
-//count_one_f   //whether the counter now is one
-//
-//Instantiates: dynamic_input_route_request_calc
-//
-//Note:
-//
 `include "network_define.v"
-module dynamic_input_control(thanks_all_temp_out,
-                             route_req_n_out, route_req_e_out, route_req_s_out, route_req_w_out, route_req_p_out,
-                             default_ready_n, default_ready_e, default_ready_s, default_ready_w, default_ready_p,
-                             tail_out, clk, reset,
-                             my_loc_x_in, my_loc_y_in, my_chip_id_in,
-                             abs_x, abs_y, abs_chip_id, final_bits, valid_in,
-                             thanks_n, thanks_e, thanks_s, thanks_w, thanks_p,
-                             length);
-
-// begin port declarations
+module dynamic_input_control(
+    thanks_all_temp_out,
+    route_req_n_out, route_req_e_out, route_req_s_out, route_req_w_out, route_req_p_out,
+    default_ready_n, default_ready_e, default_ready_s, default_ready_w, default_ready_p,
+    tail_out, clk, reset,
+    my_loc_x_in, my_loc_y_in, my_chip_id_in,
+    abs_x, abs_y, abs_chip_id, final_bits, valid_in,
+    thanks_n, thanks_e, thanks_s, thanks_w, thanks_p,
+    length
+);
 
 output thanks_all_temp_out;
 output route_req_n_out;
@@ -82,127 +41,44 @@
 input thanks_p;
 input [`PAYLOAD_LEN-1:0] length;
 
-// end port declarations
+reg [`PAYLOAD_LEN-1:0] rem_f;
 
-//This is the state
-reg [`PAYLOAD_LEN-1:0] count_f;
-reg header_last_f;
-reg thanks_all_f;
-reg count_zero_f;
-reg count_one_f;
-reg tail_last_f;
+wire thanks_all_temp = thanks_n | thanks_e | thanks_s | thanks_w | thanks_p;
+wire is_header_phase = (rem_f == `PAYLOAD_LEN'd0);
+wire header          = valid_in & is_header_phase;
+wire length_zero     = (length == `PAYLOAD_LEN'd0);
 
-//inputs to the state
-reg [`PAYLOAD_LEN-1:0] count_temp;
-wire header_last_temp;
-wire thanks_all_temp;
-wire count_zero_temp;
-wire count_one_temp;
-wire tail_last_temp;
+assign thanks_all_temp_out = thanks_all_temp;
+assign tail_out = is_header_phase ? (valid_in & length_zero) : (rem_f == `PAYLOAD_LEN'd1);
 
+dynamic_input_route_request_calc tail_calc(
+    .route_req_n(route_req_n_out),
+    .route_req_e(route_req_e_out),
+    .route_req_s(route_req_s_out),
+    .route_req_w(route_req_w_out),
+    .route_req_p(route_req_p_out),
+    .default_ready_n(default_ready_n),
+    .default_ready_e(default_ready_e),
+    .default_ready_s(default_ready_s),
+    .default_ready_w(default_ready_w),
+    .default_ready_p(default_ready_p),
+    .my_loc_x_in(my_loc_x_in),
+    .my_loc_y_in(my_loc_y_in),
+    .my_chip_id_in(my_chip_id_in),
+    .abs_x(abs_x),
+    .abs_y(abs_y),
+    .abs_chip_id(abs_chip_id),
+    .final_bits(final_bits),
+    .length(length),
+    .header_in(header)
+);
 
-//wires
-wire header;
-wire [`PAYLOAD_LEN-1:0] count_minus_one;
-wire length_zero; //for use in calculating tail bit for
-                  //zero length messages on the default route
-wire tail;
-
-//wire regs
-reg header_temp;
-
-//assigns
-assign thanks_all_temp = thanks_n | thanks_e | thanks_s | thanks_w | thanks_p;
-assign header = valid_in & header_temp;
-assign count_zero_temp = count_temp == 0;
-assign count_one_temp = count_temp == 1;
-assign thanks_all_temp_out = thanks_all_temp;
-assign tail_out = tail;
-assign count_minus_one = count_f - 1;
-assign length_zero = length == 0;
-assign header_last_temp = header_temp;
-//nasty control logic which I really hope is correct
-assign tail = (header & length_zero) | ((~thanks_all_f) & tail_last_f) | (thanks_all_f & count_one_f);
-assign tail_last_temp = tail;
-
-//instantiations
-dynamic_input_route_request_calc tail_calc(.route_req_n(route_req_n_out),
-                                           .route_req_e(route_req_e_out),
-                                           .route_req_s(route_req_s_out),
-                                           .route_req_w(route_req_w_out),
-                                           .route_req_p(route_req_p_out),
-                                           .default_ready_n(default_ready_n),
-                                           .default_ready_e(default_ready_e),
-                                           .default_ready_s(default_ready_s),
-                                           .default_ready_w(default_ready_w),
-                                           .default_ready_p(default_ready_p),
-                                           .my_loc_x_in(my_loc_x_in),
-                                           .my_loc_y_in(my_loc_y_in),
-                                           .my_chip_id_in(my_chip_id_in),
-                                           .abs_x(abs_x),
-                                           .abs_y(abs_y),
-                                           .abs_chip_id(abs_chip_id),
-                                           .final_bits(final_bits),
-                                           .length(length),
-                                           .header_in(header));
-
-always @ (header_last_f or thanks_all_f or count_zero_f)
-begin
-        case({header_last_f, count_zero_f, thanks_all_f})
-        3'b000: header_temp <= 1'b0;
-        3'b001: header_temp <= 1'b0;
-        3'b010: header_temp <= 1'b0;
-        3'b011: header_temp <= 1'b1;
-        3'b100: header_temp <= 1'b1;
-        //yanqiz change 0->1
-        3'b101: header_temp <= 1'b0;
-        3'b110: header_temp <= 1'b1;
-        3'b111: header_temp <= 1'b1;
-        default:
-                header_temp <= 1'b1;
-        endcase
+always @(posedge clk) begin
+    if (reset) begin
+        rem_f <= `PAYLOAD_LEN'd0;
+    end else if (thanks_all_temp) begin
+        rem_f <= is_header_phase ? length : (rem_f - `PAYLOAD_LEN'd1);
+    end
 end
 
-always @ (header or thanks_all_f or count_f or count_minus_one or length)
-begin
-        if(header)
-        begin
-                count_temp <= length;
-        end
-        else
-        begin
-                if(thanks_all_f)
-                begin
-                        count_temp <= count_minus_one;
-                end
-                else
-                begin
-                        count_temp <= count_f;
-                end
-        end
-end
-
-//take care of synchronous stuff
-always @ (posedge clk)
-begin
-        if(reset)
-        begin
-                count_f <= 5'd0;
-                header_last_f <= 1'b1;
-                thanks_all_f <= 1'b0;
-                count_zero_f <= 1'b1; //I think that this must reset to 1 to work!
-                count_one_f <= 1'b0;
-                tail_last_f <= 1'b0;
-        end
-        else
-        begin
-                count_f <= count_temp;
-                header_last_f <= header_last_temp;
-                thanks_all_f <= thanks_all_temp;
-                count_zero_f <= count_zero_temp;
-                count_one_f <= count_one_temp;
-                tail_last_f <= tail_last_temp;
-        end
-end
 endmodule
-

--- a/environment/public/code/rtl/dynamic_output_control.v (Buggy Starter)
+++ b/solution/gold/code/rtl/dynamic_output_control.v (Golden Reference)
@@ -1,57 +1,22 @@
-/*
-Copyright (c) 2015 Princeton University
-All rights reserved.
-
-Redistribution and use in source and binary forms, with or without
-modification, are permitted provided that the following conditions are met:
-    * Redistributions of source code must retain the above copyright
-      notice, this list of conditions and the following disclaimer.
-    * Redistributions in binary form must reproduce the above copyright
-      notice, this list of conditions and the following disclaimer in the
-      documentation and/or other materials provided with the distribution.
-    * Neither the name of Princeton University nor the
-      names of its contributors may be used to endorse or promote products
-      derived from this software without specific prior written permission.
-
-THIS SOFTWARE IS PROVIDED BY PRINCETON UNIVERSITY "AS IS" AND
-ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-DISCLAIMED. IN NO EVENT SHALL PRINCETON UNIVERSITY BE LIABLE FOR ANY
-DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-*/
-
-//Function: This maintains the control of the output mux for a dynamic network port.
-//	This does the scheduling for the output.
-//	It takes as input what all of the other ports want to do and outputs the control
-//	for the respective crossbar mux and the validOut signal for a respective direction.
-//
-//Instantiates:
-//
-//State: current_route_f [2:0], planned_f
-//
-//Note:
-//
 `include "network_define.v"
 
-module dynamic_output_control(thanks_a, thanks_b, thanks_c, thanks_d, thanks_x, valid_out, current_route, ec_wants_to_send_but_cannot, clk, reset, route_req_a_in, route_req_b_in, route_req_c_in, route_req_d_in, route_req_x_in, tail_a_in, tail_b_in, tail_c_in, tail_d_in, tail_x_in, valid_out_temp, default_ready, space_avail);
-
-// begin port declarations
+module dynamic_output_control(
+    thanks_a, thanks_b, thanks_c, thanks_d, thanks_x,
+    valid_out, current_route, ec_wants_to_send_but_cannot,
+    clk, reset,
+    route_req_a_in, route_req_b_in, route_req_c_in, route_req_d_in, route_req_x_in,
+    tail_a_in, tail_b_in, tail_c_in, tail_d_in, tail_x_in,
+    valid_out_temp, default_ready, space_avail
+);
 
 output thanks_a;
 output thanks_b;
 output thanks_c;
 output thanks_d;
 output thanks_x;
-
 output valid_out;
-
 output [2:0] current_route;
-output    ec_wants_to_send_but_cannot;
+output ec_wants_to_send_but_cannot;
 
 input clk;
 input reset;
@@ -69,12 +34,8 @@
 input tail_x_in;
 
 input valid_out_temp;
-
 input default_ready;
-
 input space_avail;
-
-// end port declarations
 
 `define ROUTE_A 3'b000
 `define ROUTE_B 3'b001
@@ -82,385 +43,153 @@
 `define ROUTE_D 3'b011
 `define ROUTE_X 3'b100
 
-//This is the state
-reg [2:0]current_route_f;
+reg [2:0] current_route_f;
+reg [2:0] last_route_f;
 reg planned_f;
+reg ec_wants_to_send_but_cannot;
 
-//inputs to the state
-wire [2:0] current_route_temp;
+wire planned_or_default = planned_f | default_ready;
+wire valid_out_internal = valid_out_temp & planned_or_default & space_avail;
+assign valid_out = valid_out_internal;
+assign current_route = current_route_f;
 
-//wires
-wire planned_or_default;
-// wire route_req_all_or;
-wire route_req_all_or_with_planned;
-wire route_req_all_but_default;
-wire valid_out_internal;
-
-//wire regs
-reg new_route_needed;
-reg planned_temp;
-reg [2:0] new_route;
-reg tail_current_route;
-/*reg route_req_planned;*/
-reg route_req_a_mask;
-reg route_req_b_mask;
-reg route_req_c_mask;
-reg route_req_d_mask;
-reg route_req_x_mask;
-
-
-//more wire regs for the thanks lines
-reg thanks_a;
-reg thanks_b;
-reg thanks_c;
-reg thanks_d;
-reg thanks_x;
-
-reg    ec_wants_to_send_but_cannot;
-
-//assigns
-assign planned_or_default = planned_f | default_ready;
-assign valid_out_internal = valid_out_temp & planned_or_default & space_avail;
-
-// mbt: if valid_out_interal is a critical path, we can use some "bleeder" gates to decrease the load of the ec stuff
-always @(posedge clk)
-  begin
-     ec_wants_to_send_but_cannot <= valid_out_temp & planned_or_default & ~space_avail;
-  end
-
-/* assign route_req_all_or = route_req_a_in | route_req_b_in | route_req_c_in | route_req_d_in | route_req_x_in; */
-assign current_route_temp = (new_route_needed) ? new_route : current_route_f;
-assign current_route = current_route_f;
-//this is everything except the currentl planned route's request
-assign route_req_all_or_with_planned = (route_req_a_in & route_req_a_mask) | (route_req_b_in & route_req_b_mask) | (route_req_c_in & route_req_c_mask) | (route_req_d_in & route_req_d_mask) | (route_req_x_in & route_req_x_mask);
-//calculates whether the nib that we are going to has space
-assign route_req_all_but_default = route_req_b_in | route_req_c_in | route_req_d_in | route_req_x_in;
-
-assign valid_out = valid_out_internal;
-
-//instantiations
-//space_avail space(.valid(valid_out_internal), .clk(clk), .reset(reset), .yummy(yummy_in), .spc_avail(space_avail));
-//THIS HAS BEEN MOVED to dynamic_output_top
-
-//a mux for current_route_f's tail bit
-always @ (current_route_f or tail_a_in or tail_b_in or tail_c_in or tail_d_in or tail_x_in)
-begin
-	case(current_route_f) //synopsys parallel_case
-	`ROUTE_A:
-	begin
-		tail_current_route <= tail_a_in;
-	end
-	`ROUTE_B:
-	begin
-		tail_current_route <= tail_b_in;
-	end
-	`ROUTE_C:
-	begin
-		tail_current_route <= tail_c_in;
-	end
-	`ROUTE_D:
-	begin
-		tail_current_route <= tail_d_in;
-	end
-	`ROUTE_X:
-	begin
-		tail_current_route <= tail_x_in;
-	end
-	default:
-	begin
-		tail_current_route <= 1'bx; //This is probably dangerous, but I
-					    //really need the speed here and
-					    //I don't want the synthesizer to
-					    //mess me up if I put a real value
-					    //here
-	end
-	endcase
+always @(posedge clk) begin
+    if (reset)
+        ec_wants_to_send_but_cannot <= 1'b0;
+    else
+        ec_wants_to_send_but_cannot <= valid_out_temp & planned_or_default & ~space_avail;
 end
 
-always @ (current_route_f or valid_out_internal)
-begin
-	case(current_route_f)
-	`ROUTE_A:
-	begin
-		thanks_a <= valid_out_internal;
-		thanks_b <= 1'b0;
-		thanks_c <= 1'b0;
-		thanks_d <= 1'b0;
-		thanks_x <= 1'b0;
-	end
-	`ROUTE_B:
-	begin
-		thanks_a <= 1'b0;
-		thanks_b <= valid_out_internal;
-		thanks_c <= 1'b0;
-		thanks_d <= 1'b0;
-		thanks_x <= 1'b0;
-	end
-	`ROUTE_C:
-	begin
-		thanks_a <= 1'b0;
-		thanks_b <= 1'b0;
-		thanks_c <= valid_out_internal;
-		thanks_d <= 1'b0;
-		thanks_x <= 1'b0;
-	end
-	`ROUTE_D:
-	begin
-		thanks_a <= 1'b0;
-		thanks_b <= 1'b0;
-		thanks_c <= 1'b0;
-		thanks_d <= valid_out_internal;
-		thanks_x <= 1'b0;
-	end
-	`ROUTE_X:
-	begin
-		thanks_a <= 1'b0;
-		thanks_b <= 1'b0;
-		thanks_c <= 1'b0;
-		thanks_d <= 1'b0;
-		thanks_x <= valid_out_internal;
-	end
-	default:
-	begin
-		thanks_a <= 1'bx;
-		thanks_b <= 1'bx;
-		thanks_c <= 1'bx;
-		thanks_d <= 1'bx;
-		thanks_x <= 1'bx;
-					//once again this is very dangerous
-					//but I want to see the timing this
-					//way and we sould never get here
-	end
-	endcase
+reg tail_current_route;
+always @* begin
+    case (current_route_f)
+        `ROUTE_A: tail_current_route = tail_a_in;
+        `ROUTE_B: tail_current_route = tail_b_in;
+        `ROUTE_C: tail_current_route = tail_c_in;
+        `ROUTE_D: tail_current_route = tail_d_in;
+        `ROUTE_X: tail_current_route = tail_x_in;
+        default:  tail_current_route = 1'b0;
+    endcase
 end
 
-//this is the rotating priority encoder
-/*
-always @(current_route_f or route_req_a_in or route_req_b_in or route_req_c_in or route_req_d_in or route_req_x_in)
-begin
-	case(current_route_f)
-	`ROUTE_A:
-	begin
-		new_route <= (route_req_b_in)?`ROUTE_B:((route_req_c_in)?`ROUTE_C:((route_req_d_in)?`ROUTE_D:((route_req_x_in)?`ROUTE_X:`ROUTE_A)));
-	end
-	`ROUTE_B:
-	begin
-		new_route <= (route_req_c_in)?`ROUTE_C:((route_req_d_in)?`ROUTE_D:((route_req_x_in)?`ROUTE_X:((route_req_a_in)?`ROUTE_A:((route_req_b_in)?`ROUTE_B:`ROUTE_A))));
-	end
-	`ROUTE_C:
-	begin
-		new_route <= (route_req_d_in)?`ROUTE_D:((route_req_x_in)?`ROUTE_X:((route_req_a_in)?`ROUTE_A:((route_req_b_in)?`ROUTE_B:((route_req_c_in)?`ROUTE_C:`ROUTE_A))));
-	end
-	`ROUTE_D:
-	begin
-		new_route <= (route_req_c_in)?`ROUTE_C:((route_req_d_in)?`ROUTE_D:((route_req_x_in)?`ROUTE_X:((route_req_a_in)?`ROUTE_A:((route_req_b_in)?`ROUTE_B:`ROUTE_A))));
-	end
-	`ROUTE_X:
-	begin
-		new_route <= (route_req_x_in)?`ROUTE_X:((route_req_a_in)?`ROUTE_A:((route_req_b_in)?`ROUTE_B:((route_req_c_in)?`ROUTE_C:((route_req_d_in)?`ROUTE_D:`ROUTE_A))));
-	end
-	default:
-	begin
-		new_route <= `ROUTE_A;
-			//this one I am not willing to chince on
-	end
-	endcase
-end
-*/
-//end the rotating priority encoder
+assign thanks_a = (current_route_f == `ROUTE_A) & valid_out_internal;
+assign thanks_b = (current_route_f == `ROUTE_B) & valid_out_internal;
+assign thanks_c = (current_route_f == `ROUTE_C) & valid_out_internal;
+assign thanks_d = (current_route_f == `ROUTE_D) & valid_out_internal;
+assign thanks_x = (current_route_f == `ROUTE_X) & valid_out_internal;
 
-//this is the rotating priority encoder
-always @(current_route_f or route_req_a_in or route_req_b_in or route_req_c_in or route_req_d_in or route_req_x_in)
-begin
-	case(current_route_f)
-	`ROUTE_A:
-	begin
-		new_route <= (route_req_b_in)?`ROUTE_B:((route_req_c_in)?`ROUTE_C:((route_req_d_in)?`ROUTE_D:((route_req_x_in)?`ROUTE_X:`ROUTE_A)));
-	end
-	`ROUTE_B:
-	begin
-		new_route <= (route_req_c_in)?
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/include/define.tmp.h`](environment/public/code/include/define.tmp.h) *(Read-Only Context)*
- [`environment/public/code/include/network_define.v`](environment/public/code/include/network_define.v) *(Read-Only Context)*
- [`environment/public/code/rtl/bus_compare_equal.v`](environment/public/code/rtl/bus_compare_equal.v) *(Read-Only Context)*
- [`environment/public/code/rtl/dynamic_input_control.v`](environment/public/code/rtl/dynamic_input_control.v) **(Editable)**
- [`environment/public/code/rtl/dynamic_input_route_request_calc.v`](environment/public/code/rtl/dynamic_input_route_request_calc.v) **(Editable)**
- [`environment/public/code/rtl/dynamic_input_top_16.v`](environment/public/code/rtl/dynamic_input_top_16.v) *(Read-Only Context)*
- [`environment/public/code/rtl/dynamic_input_top_4.v`](environment/public/code/rtl/dynamic_input_top_4.v) *(Read-Only Context)*
- [`environment/public/code/rtl/dynamic_node_top.v`](environment/public/code/rtl/dynamic_node_top.v) *(Read-Only Context)*
- [`environment/public/code/rtl/dynamic_node_top_wrap.v`](environment/public/code/rtl/dynamic_node_top_wrap.v) *(Read-Only Context)*
- [`environment/public/code/rtl/dynamic_output_control.v`](environment/public/code/rtl/dynamic_output_control.v) **(Editable)**
- [`environment/public/code/rtl/dynamic_output_datapath.v`](environment/public/code/rtl/dynamic_output_datapath.v) *(Read-Only Context)*
- [`environment/public/code/rtl/dynamic_output_top.v`](environment/public/code/rtl/dynamic_output_top.v) *(Read-Only Context)*
- [`environment/public/code/rtl/flip_bus.v`](environment/public/code/rtl/flip_bus.v) *(Read-Only Context)*
- [`environment/public/code/rtl/net_dff.v`](environment/public/code/rtl/net_dff.v) *(Read-Only Context)*
- [`environment/public/code/rtl/network_input_blk_multi_out.v`](environment/public/code/rtl/network_input_blk_multi_out.v) *(Read-Only Context)*
- [`environment/public/code/rtl/one_of_eight.v`](environment/public/code/rtl/one_of_eight.v) *(Read-Only Context)*
- [`environment/public/code/rtl/one_of_five.v`](environment/public/code/rtl/one_of_five.v) *(Read-Only Context)*
- [`environment/public/code/rtl/space_avail_top.v`](environment/public/code/rtl/space_avail_top.v) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/LICENSE.Nangate45`](environment/public/lib/LICENSE.Nangate45) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lib/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.tech.lef`](environment/public/lib/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

