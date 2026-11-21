# `case_10012`: OpenPiton 8-Port Chipset I/O Crossbar Route Decoding, 8-Bit Payload Framing, Output Arbitration Fairness, and Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_10012` |
| **Source Silicon Repository** | `princetonuniversity/openpiton` (`repo_10`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `parameters_widths` (Parameterization, Bit-Width Upsizing/Downsizing, Deserialization & Casting) |
| **Multi-Domain Tags** | `parameters_widths`, `protocol_control`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/io_xbar_input_route_request_calc.v`](environment/public/code/rtl/io_xbar_input_route_request_calc.v), [`code/rtl/io_xbar_input_control.v`](environment/public/code/rtl/io_xbar_input_control.v), [`code/rtl/io_xbar_output_control.v`](environment/public/code/rtl/io_xbar_output_control.v) (3 files, 324 LOC) |
| **Public Subsystem Context** | 11 RTL files (792 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# OpenPiton 8-Port Chipset I/O Crossbar Route Decoding, 8-Bit Payload Framing, Output Arbitration Fairness, and Timing Closure

In the OpenPiton 8-port chipset I/O crossbar router (`code/rtl/io_xbar_output_top.v` and `code/rtl/io_xbar_input_control.v`), update `code/rtl/io_xbar_input_route_request_calc.v`, `code/rtl/io_xbar_input_control.v`, and `code/rtl/io_xbar_output_control.v` so that 8-port crossbar route decoding, 8-bit multi-flit packet framing, work-conserving round-robin output arbitration across all 8 ports, reset initialization, and static timing closure pass verification:

- **Eight-port crossbar route decoding and off-chip/unmapped fallback (`io_xbar_route_request_calc`)**: When `header_in` is high, compare `abs_chip_id` against `my_chip_id_in` (`off_chip = (abs_chip_id != my_chip_id_in)`). For on-chip device ports `k in 1..7`, assert `route_req_k` when `header_in & (!off_chip) & (abs_x == 8'd<k>)`. For port `0` (the default/off-chip gateway port), assert `route_req_0` when `header_in & (off_chip | (abs_x == 8'd0) | (abs_x >= 8'd8))` so every valid header asserts exactly one route request (`route_req_0..7` is one-hot when `header_in == 1`), with `default_ready_0..7` matching `route_req_0..7`.
- **Full 8-bit payload length tracking and synchronous reset (`io_xbar_input_control`)**: Track all `PAYLOAD_LEN` (`8`) bits of `length` across reset and packet transfers (`0` to `255` payload flits following the header), asserting `tail_out` on single-flit headers (`length == 8'd0`) and on the final payload beat of multi-flit packets, and holding `tail_out` stable across upstream NIB bubbles (`valid_in == 1'b0`) or downstream stalls (`thanks_0..7 == 8'b0`) until that final beat is granted.
- **Work-conserving 8-port round-robin output arbitration and starvation bound (`io_xbar_output_control`)**: On `reset`, initialize `current_route_f <= 3'd0`, `planned_f <= 1'b0`, and `ec_wants_to_send_but_cannot <= 1'b0`, and drive `thanks_0..7` and `tail_current_route` to `1'b0` (never `1'bx`). When `planned_f` is high, hold `current_route_f` locked across cycles until the active packet's tail flit is transferred (`valid_out && tail_current_route`). In the 8-port rotating priority encoder (`0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 0`), include the self-fallback branch on every route (`0` through `7`) so a requester that just completed a packet is immediately re-selected (`planned_temp = 1'b1`) if no other port requests, and preserve the last-completed route across idle cycles (`!planned_f`) so any continuously requesting input port is granted after at most `7` packets from other inputs even when contenders request across intermittent idle gaps.

Under the Nangate45 synthesis and OpenROAD placement-estimated STA flows in `BUILD.md`:
1. `io_xbar_input_control` must map to **`<= 195.0 um^2`** and achieve setup and hold slack **`>= 0.0 ns`** at a **`0.85 ns`** clock (`0.15 ns` I/O delays, `5.0 fF` load).
2. `io_xbar_output_top` must map to **`<= 720.0 um^2`** and achieve setup and hold slack **`>= 0.0 ns`** at a **`0.85 ns`** clock (`0.15 ns` I/O delays, `5.0 fF` load).

Edit only `code/rtl/io_xbar_input_route_request_calc.v`, `code/rtl/io_xbar_input_control.v`, and `code/rtl/io_xbar_output_control.v`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

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

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/io_xbar_input_route_request_calc.v (Buggy Starter)
+++ b/solution/gold/code/rtl/io_xbar_input_route_request_calc.v (Golden Reference)
@@ -24,7 +24,7 @@
 
 wire off_chip = (abs_chip_id != my_chip_id_in);
 
-assign route_req_0 = header_in & (!off_chip) & (abs_x == 8'd0);
+assign route_req_0 = header_in & (off_chip | (abs_x == 8'd0) | (abs_x >= 8'd8));
 assign route_req_1 = header_in & (!off_chip) & (abs_x == 8'd1);
 assign route_req_2 = header_in & (!off_chip) & (abs_x == 8'd2);
 assign route_req_3 = header_in & (!off_chip) & (abs_x == 8'd3);

--- a/environment/public/code/rtl/io_xbar_input_control.v (Buggy Starter)
+++ b/solution/gold/code/rtl/io_xbar_input_control.v (Golden Reference)
@@ -27,37 +27,15 @@
 input thanks_0, thanks_1, thanks_2, thanks_3, thanks_4, thanks_5, thanks_6, thanks_7;
 input [`PAYLOAD_LEN-1:0] length;
 
-reg [`PAYLOAD_LEN-1:0] count_f;
-reg header_last_f;
-reg thanks_all_f;
-reg count_zero_f;
-reg count_one_f;
-reg tail_last_f;
+reg [`PAYLOAD_LEN-1:0] rem_f;
 
-reg [`PAYLOAD_LEN-1:0] count_temp;
-wire header_last_temp;
-wire thanks_all_temp;
-wire count_zero_temp;
-wire count_one_temp;
-wire tail_last_temp;
+wire thanks_all_temp = thanks_0 | thanks_1 | thanks_2 | thanks_3 | thanks_4 | thanks_5 | thanks_6 | thanks_7;
+wire is_header_phase = (rem_f == `PAYLOAD_LEN'd0);
+wire header          = valid_in & is_header_phase;
+wire length_zero     = (length == `PAYLOAD_LEN'd0);
 
-wire header;
-wire [`PAYLOAD_LEN-1:0] count_minus_one;
-wire length_zero;
-wire tail;
-reg header_temp;
-
-assign thanks_all_temp = thanks_0 | thanks_1 | thanks_2 | thanks_3 | thanks_4 | thanks_5 | thanks_6 | thanks_7;
-assign header = valid_in & header_temp;
-assign count_zero_temp = count_temp == 0;
-assign count_one_temp = count_temp == 1;
 assign thanks_all_temp_out = thanks_all_temp;
-assign tail_out = tail;
-assign count_minus_one = count_f - 1;
-assign length_zero = length == 0;
-assign header_last_temp = header_temp;
-assign tail = (header & length_zero) | ((~thanks_all_f) & tail_last_f) | (thanks_all_f & count_one_f);
-assign tail_last_temp = tail;
+assign tail_out = is_header_phase ? (valid_in & length_zero) : (rem_f == `PAYLOAD_LEN'd1);
 
 io_xbar_route_request_calc tail_calc(
     .route_req_0(route_req_0_out), .route_req_1(route_req_1_out), .route_req_2(route_req_2_out), .route_req_3(route_req_3_out),
@@ -69,44 +47,11 @@
     .final_bits(final_bits), .length(length), .header_in(header)
 );
 
-always @ (header_last_f or thanks_all_f or count_zero_f) begin
-    case({header_last_f, count_zero_f, thanks_all_f})
-    3'b000: header_temp <= 1'b0;
-    3'b001: header_temp <= 1'b0;
-    3'b010: header_temp <= 1'b0;
-    3'b011: header_temp <= 1'b1;
-    3'b100: header_temp <= 1'b1;
-    3'b101: header_temp <= 1'b0;
-    3'b110: header_temp <= 1'b1;
-    3'b111: header_temp <= 1'b1;
-    default: header_temp <= 1'b1;
-    endcase
-end
-
-always @ (header or thanks_all_f or count_f or count_minus_one or length) begin
-    if(header)
-        count_temp <= length;
-    else if(thanks_all_f)
-        count_temp <= count_minus_one;
-    else
-        count_temp <= count_f;
-end
-
-always @ (posedge clk) begin
-    if(reset) begin
-        count_f <= 5'd0;
-        header_last_f <= 1'b1;
-        thanks_all_f <= 1'b0;
-        count_zero_f <= 1'b1;
-        count_one_f <= 1'b0;
-        tail_last_f <= 1'b0;
-    end else begin
-        count_f <= count_temp;
-        header_last_f <= header_last_temp;
-        thanks_all_f <= thanks_all_temp;
-        count_zero_f <= count_zero_temp;
-        count_one_f <= count_one_temp;
-        tail_last_f <= tail_last_temp;
+always @(posedge clk) begin
+    if (reset) begin
+        rem_f <= `PAYLOAD_LEN'd0;
+    end else if (thanks_all_temp) begin
+        rem_f <= is_header_phase ? length : (rem_f - `PAYLOAD_LEN'd1);
     end
 end
 endmodule

--- a/environment/public/code/rtl/io_xbar_output_control.v (Buggy Starter)
+++ b/solution/gold/code/rtl/io_xbar_output_control.v (Golden Reference)
@@ -22,6 +22,7 @@
 input valid_out_temp, default_ready, space_avail;
 
 reg [2:0] current_route_f;
+reg [2:0] last_route_f;
 reg planned_f;
 
 wire planned_or_default = planned_f | default_ready;
@@ -30,7 +31,10 @@
 assign current_route = current_route_f;
 
 always @(posedge clk) begin
-    ec_wants_to_send_but_cannot <= valid_out_temp & planned_or_default & ~space_avail;
+    if (reset)
+        ec_wants_to_send_but_cannot <= 1'b0;
+    else
+        ec_wants_to_send_but_cannot <= valid_out_temp & planned_or_default & ~space_avail;
 end
 
 reg tail_current_route;
@@ -44,7 +48,7 @@
         3'd5: tail_current_route = tail_5_in;
         3'd6: tail_current_route = tail_6_in;
         3'd7: tail_current_route = tail_7_in;
-        default: tail_current_route = 1'bx;
+        default: tail_current_route = 1'b0;
     endcase
 end
 
@@ -57,17 +61,18 @@
 assign thanks_6 = (current_route_f == 3'd6) & valid_out_internal;
 assign thanks_7 = (current_route_f == 3'd7) & valid_out_internal;
 
+wire [2:0] rr_base = planned_f ? current_route_f : last_route_f;
 reg [2:0] new_route;
 always @* begin
-    case (current_route_f)
+    case (rr_base)
         3'd0: new_route = (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : 3'd0)))))));
-        3'd1: new_route = (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : 3'd0)))))));
-        3'd2: new_route = (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : 3'd0)))))));
-        3'd3: new_route = (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : 3'd0)))))));
-        3'd4: new_route = (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : 3'd0)))))));
-        3'd5: new_route = (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : 3'd0)))))));
-        3'd6: new_route = (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : 3'd0)))))));
-        3'd7: new_route = (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : 3'd0)))))));
+        3'd1: new_route = (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : 3'd0))))))));
+        3'd2: new_route = (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : 3'd0))))))));
+        3'd3: new_route = (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : 3'd0))))))));
+        3'd4: new_route = (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : 3'd0))))))));
+        3'd5: new_route = (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : 3'd0))))))));
+        3'd6: new_route = (route_req_7_in ? 3'd7 : (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : 3'd0))))))));
+        3'd7: new_route = (route_req_0_in ? 3'd0 : (route_req_1_in ? 3'd1 : (route_req_2_in ? 3'd2 : (route_req_3_in ? 3'd3 : (route_req_4_in ? 3'd4 : (route_req_5_in ? 3'd5 : (route_req_6_in ? 3'd6 : (route_req_7_in ? 3'd7 : 3'd0))))))));
         default: new_route = 3'd0;
     endcase
 end
@@ -86,6 +91,10 @@
     (route_req_2_in & route_req_2_mask) | (route_req_3_in & route_req_3_mask) |
     (route_req_4_in & route_req_4_mask) | (route_req_5_in & route_req_5_mask) |
     (route_req_6_in & route_req_6_mask) | (route_req_7_in & route_req_7_mask);
+
+wire route_req_all_or =
+    route_req_0_in | route_req_1_in | route_req_2_in | route_req_3_in |
+    route_req_4_in | route_req_5_in | route_req_6_in | route_req_7_in;
 
 wire route_req_all_but_default =
     route_req_1_in | route_req_2_in | route_req_3_in | route_req_4_in |
@@ -124,7 +133,7 @@
         5'b00100: planned_temp = 1'b0;
         5'b00101: planned_temp = 1'b1;
         5'b00110: planned_temp = 1'b0;
-        5'b00111: planned_temp = 1'b0;
+        5'b00111: planned_temp = route_req_all_or;
         5'b01000: planned_temp = 1'b0;
         5'b01001: planned_temp = 1'b1;
         5'b01010: planned_temp = 1'b0;
@@ -132,7 +141,7 @@
         5'b01100: planned_temp = 1'b0;
         5'b01101: planned_temp = 1'b1;
         5'b01110: planned_temp = 1'b0;
-        5'b01111: planned_temp = 1'b0;
+        5'b01111: planned_temp = route_req_all_or;
         5'b10000: planned_temp = 1'b1;
         5'b10001: planned_temp = 1'b1;
         5'b10010: planned_temp = 1'b1;
@@ -158,10 +167,13 @@
 always @(posedge clk) begin
     if (reset) begin
         current_route_f <= 3'd0;
+        last_route_f    <= 3'd0;
         planned_f       <= 1'b0;
     end else begin
         current_route_f <= current_route_temp;
         planned_f       <= planned_temp;
+        if (valid_out_internal & tail_current_route)
+            last_route_f <= current_route_f;
     end
 end
 endmodule

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
- [`environment/public/code/rtl/flip_bus.v`](environment/public/code/rtl/flip_bus.v) *(Read-Only Context)*
- [`environment/public/code/rtl/io_xbar_input_control.v`](environment/public/code/rtl/io_xbar_input_control.v) **(Editable)**
- [`environment/public/code/rtl/io_xbar_input_route_request_calc.v`](environment/public/code/rtl/io_xbar_input_route_request_calc.v) **(Editable)**
- [`environment/public/code/rtl/io_xbar_output_control.v`](environment/public/code/rtl/io_xbar_output_control.v) **(Editable)**
- [`environment/public/code/rtl/io_xbar_output_datapath.v`](environment/public/code/rtl/io_xbar_output_datapath.v) *(Read-Only Context)*
- [`environment/public/code/rtl/io_xbar_output_top.v`](environment/public/code/rtl/io_xbar_output_top.v) *(Read-Only Context)*
- [`environment/public/code/rtl/net_dff.v`](environment/public/code/rtl/net_dff.v) *(Read-Only Context)*
- [`environment/public/code/rtl/one_of_eight.v`](environment/public/code/rtl/one_of_eight.v) *(Read-Only Context)*
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

