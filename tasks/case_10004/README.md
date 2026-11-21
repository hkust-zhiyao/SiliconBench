# `case_10004`: OpenPiton NoC-to-AXI4 Memory Bridge Framing, In-Flight Slot Protection, Response Arbitration, and PPA/STA Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_10004` |
| **Source Silicon Repository** | `princetonuniversity/openpiton` (`repo_10`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `protocol_control`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/noc_axi4_bridge_deser.v`](environment/public/code/rtl/noc_axi4_bridge_deser.v), [`code/rtl/noc_axi4_bridge_ser.v`](environment/public/code/rtl/noc_axi4_bridge_ser.v), [`code/rtl/noc_axi4_bridge_buffer.v`](environment/public/code/rtl/noc_axi4_bridge_buffer.v) (3 files, 653 LOC) |
| **Public Subsystem Context** | 11 RTL files (1827 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# OpenPiton NoC-to-AXI4 Memory Bridge Framing, In-Flight Slot Protection, Response Arbitration, and PPA/STA Closure

In the OpenPiton chipset NoC-to-AXI4 memory bridge (`code/rtl/noc_axi4_bridge.v`), multi-flit NoC2 request deserialization (`code/rtl/noc_axi4_bridge_deser.v`), in-flight transaction buffering and response arbitration (`code/rtl/noc_axi4_bridge_buffer.v`), and NoC3 response serialization (`code/rtl/noc_axi4_bridge_ser.v`) fail verification and physical area/timing closure:

1. **NoC2 Request Deserialization (`code/rtl/noc_axi4_bridge_deser.v`)**:
   - Accept the 3 header flits (`pkt_w1`, `pkt_w2`, `pkt_w3`) followed by `N = pkt_w1[MSG_LENGTH] - 2` data payload beats (`N in [0, 8]`) only on qualified handshakes (`flit_in_val && flit_in_rdy`, where `flit_in_rdy` is gated by `phy_init_done` and deasserted while `out_val` is high).
   - Clear the 512-bit payload buffer at the start of each packet and place beat `k` (`0 <= k < N`) at `data_out[64*k +: 64]` so that 1-beat uncacheable stores (`MSG_LENGTH == 3`) appear on `data_out[63:0]` with `data_out[511:64] == 0`, 8-beat cacheable stores (`MSG_LENGTH == 10`) appear in order on `data_out[63:0]` through `data_out[511:448]`, and 0-beat load requests (`MSG_LENGTH == 2`) present `data_out == 512'd0`. Hold `header_out`, `data_out`, and `out_val` stable until `out_rdy` is asserted.

2. **In-Flight Slot Protection and Work-Conserving Response Arbitration (`code/rtl/noc_axi4_bridge_buffer.v`)**:
   - Protect in-flight header SRAM entries: a buffer slot `i` (`0 .. NOC_AXI4_BRIDGE_IN_FLIGHT_LIMIT-1`) must not accept a new packet from `deser` (`deser_rdy` must remain low when `fifo_in == i`) while either its request is still waiting to issue or its AXI response has not yet been accepted into the serializer path.
   - Replace the free-running response toggle with work-conserving round-robin arbitration between `read_resp_val` and `write_resp_val`: when only one response channel is valid and the serializer interface can accept a beat, grant it immediately without waiting an extra cycle; when both `read_resp_val` and `write_resp_val` are asserted simultaneously, alternate grants between read and write responses. Ensure the header read from `noc_axi4_bridge_sram_req` (`ser_header`) and the corresponding `ser_data` / `ser_val` remain aligned across single-stage registration and downstream `ser_rdy` backpressure.

3. **NoC3 Response Serialization (`code/rtl/noc_axi4_bridge_ser.v`)**:
   - Latch `header_in` and `data_in` only on a valid input handshake (`in_val && in_rdy`).
   - Encode `MSG_LENGTH` in the outgoing NoC3 response header as `0` for `MSG_TYPE_STORE_MEM_ACK`, `MSG_TYPE_NC_STORE_MEM_ACK`, and zero-byte uncacheable loads (`MSG_TYPE_NC_LOAD_REQ` with `MSG_DATA_SIZE == MSG_DATA_SIZE_0B`); `1` for uncacheable loads with `MSG_DATA_SIZE` in `1B .. 8B` (`MSG_DATA_SIZE_1B` through `MSG_DATA_SIZE_8B`), emitting 1 payload flit (`data_in[63:0]`); and `PAYLOAD_LEN` (`8`) for cacheable loads (`MSG_TYPE_LOAD_MEM`) and uncacheable loads with `MSG_DATA_SIZE > MSG_DATA_SIZE_8B`, emitting 8 payload flits (`data_in[63:0]` through `data_in[511:448]`).
   - Hold every header and payload flit stable across `flit_out_rdy == 0` stalls (including on the final payload beat) and advance only on `flit_out_val && flit_out_rdy`.

4. **Nangate45 Mapped Area and 1.08 ns OpenROAD STA Closure (`BUILD.md`)**:
   - Under the Nangate45 synthesis and OpenROAD placement-estimated STA flows in `BUILD.md` (`1.08 ns` clock period on `clk`, `0.15 ns` I/O delays, `5.0 fF` output load), achieve:
     - `noc_axi4_bridge_deser` mapped area **`<= 4,955.0 um^2`**, `noc_axi4_bridge_ser` mapped area **`<= 4,810.0 um^2`**, and `noc_axi4_bridge_buffer` mapped area **`<= 21,350.0 um^2`**;
     - Worst setup slack and worst hold slack **`>= 0.0 ns`** on both `noc_axi4_bridge_deser` and `noc_axi4_bridge_ser`.

Edit only `code/rtl/noc_axi4_bridge_deser.v`, `code/rtl/noc_axi4_bridge_ser.v`, and `code/rtl/noc_axi4_bridge_buffer.v`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Files and Read-Only Dependencies

Editable RTL files:
- `code/rtl/noc_axi4_bridge_deser.v`
- `code/rtl/noc_axi4_bridge_ser.v`
- `code/rtl/noc_axi4_bridge_buffer.v`

All other files in `code/rtl/`, `code/include/`, and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Icarus Verilog`)

Compile and simulate `noc_axi4_bridge` and its submodules:
```bash
iverilog -g2012 -s tb -I code/include -o sim.vvp \
  code/rtl/storage_addr_trans.v \
  code/rtl/noc_axi4_bridge_sram_data.v \
  code/rtl/noc_axi4_bridge_sram_req.v \
  code/rtl/noc_axi4_bridge_read.v \
  code/rtl/noc_axi4_bridge_write.v \
  code/rtl/noc_axi4_bridge_deser.v \
  code/rtl/noc_axi4_bridge_ser.v \
  code/rtl/noc_axi4_bridge_buffer.v \
  code/rtl/noc_axi4_bridge.v \
  tb.sv
vvp sim.vvp
```

## 3. Synthesis and Mapped Area (`Yosys + Slang`, Nangate45)

### 3.1 Deserializer (`noc_axi4_bridge_deser`, target area `<= 4,955.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top noc_axi4_bridge_deser -I code/include code/rtl/noc_axi4_bridge_deser.v;
  hierarchy -check -top noc_axi4_bridge_deser;
  synth -top noc_axi4_bridge_deser;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_deser.v
"
```

### 3.2 Serializer (`noc_axi4_bridge_ser`, target area `<= 4,810.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top noc_axi4_bridge_ser -I code/include code/rtl/noc_axi4_bridge_ser.v;
  hierarchy -check -top noc_axi4_bridge_ser;
  synth -top noc_axi4_bridge_ser;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_ser.v
"
```

### 3.3 Transaction Buffer (`noc_axi4_bridge_buffer`, target area `<= 21,350.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top noc_axi4_bridge_buffer -I code/include \
    code/rtl/noc_axi4_bridge_sram_data.v \
    code/rtl/noc_axi4_bridge_sram_req.v \
    code/rtl/noc_axi4_bridge_buffer.v;
  hierarchy -check -top noc_axi4_bridge_buffer;
  synth -top noc_axi4_bridge_buffer;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_buf.v
"
```

## 4. OpenROAD Placement-Estimated Static Timing Analysis (`1.08 ns` Clock)

For `TOP` in `{noc_axi4_bridge_deser, noc_axi4_bridge_ser}` with netlist `mapped_deser.v` / `mapped_ser.v`:
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog <NETLIST>
link_design <TOP>
initialize_floorplan -die_area {0 0 110 110} -core_area {10 10 100 100} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk -period 1.08 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.55
estimate_parasitics -placement
repair_design
repair_timing -setup -hold
detailed_placement
estimate_parasitics -placement
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```

Both `noc_axi4_bridge_deser` and `noc_axi4_bridge_ser` must achieve worst setup slack (`-path_delay max`) **`>= 0.0 ns`** and worst hold slack (`-path_delay min`) **`>= 0.0 ns`** at `1.08 ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/noc_axi4_bridge_deser.v (Buggy Starter)
+++ b/solution/gold/code/rtl/noc_axi4_bridge_deser.v (Golden Reference)
@@ -1,183 +1,122 @@
 // ========== Copyright Header Begin ============================================
 // Copyright (c) 2019 Princeton University
 // All rights reserved.
-//
-// Redistribution and use in source and binary forms, with or without
-// modification, are permitted provided that the following conditions are met:
-//     * Redistributions of source code must retain the above copyright
-//       notice, this list of conditions and the following disclaimer.
-//     * Redistributions in binary form must reproduce the above copyright
-//       notice, this list of conditions and the following disclaimer in the
-//       documentation and/or other materials provided with the distribution.
-//     * Neither the name of Princeton University nor the
-//       names of its contributors may be used to endorse or promote products
-//       derived from this software without specific prior written permission.
-//
-// THIS SOFTWARE IS PROVIDED BY PRINCETON UNIVERSITY "AS IS" AND
-// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-// DISCLAIMED. IN NO EVENT SHALL PRINCETON UNIVERSITY BE LIABLE FOR ANY
-// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
+// BSD-3-Clause
 // ========== Copyright Header End ============================================
 
 `include "mc_define.h"
 `include "define.tmp.h"
 `include "noc_axi4_bridge_define.vh"
 
+module noc_axi4_bridge_deser (
+  input  wire                          clk,
+  input  wire                          rst_n,
 
-module noc_axi4_bridge_deser (
-  input clk, 
-  input rst_n, 
+  input  wire [`NOC_DATA_WIDTH-1:0]    flit_in,
+  input  wire                          flit_in_val,
+  output wire                          flit_in_rdy,
+  input  wire                          phy_init_done,
 
-  input [`NOC_DATA_WIDTH-1:0] flit_in, 
-  input  flit_in_val, 
-  output flit_in_rdy, 
-  input phy_init_done,
-
-  output [`MSG_HEADER_WIDTH-1:0] header_out, 
-  output [`AXI4_DATA_WIDTH-1:0] data_out, 
-  output out_val, 
-  input  out_rdy
+  output wire [`MSG_HEADER_WIDTH-1:0]  header_out,
+  output wire [`AXI4_DATA_WIDTH-1:0]   data_out,
+  output wire                          out_val,
+  input  wire                          out_rdy
 );
 
-localparam ACCEPT_W1   = 3'd0;
-localparam ACCEPT_W2   = 3'd1;
-localparam ACCEPT_W3   = 3'd2;
-localparam ACCEPT_DATA = 3'd3;
-localparam SEND        = 3'd4;
+  localparam ACCEPT_W1   = 3'd0;
+  localparam ACCEPT_W2   = 3'd1;
+  localparam ACCEPT_W3   = 3'd2;
+  localparam ACCEPT_DATA = 3'd3;
+  localparam SEND        = 3'd4;
 
-reg [`NOC_DATA_WIDTH-1:0]           pkt_w1;
-reg [`NOC_DATA_WIDTH-1:0]           pkt_w2;
-reg [`NOC_DATA_WIDTH-1:0]           pkt_w3; 
-reg [`NOC_DATA_WIDTH-1:0]           in_data_buf[`PAYLOAD_LEN-1:0]; //buffer for incomming packets
-reg [`MSG_LENGTH_WIDTH-1:0]         remaining_flits; //flits remaining in current packet
-reg [2:0]                           state;
+  reg [`NOC_DATA_WIDTH-1:0]   pkt_w1;
+  reg [`NOC_DATA_WIDTH-1:0]   pkt_w2;
+  reg [`NOC_DATA_WIDTH-1:0]   pkt_w3;
+  reg [`NOC_DATA_WIDTH-1:0]   in_data_buf [`PAYLOAD_LEN-1:0];
+  reg [`MSG_LENGTH_WIDTH-1:0] remaining_flits;
+  reg [2:0]                   beat_idx;
+  reg [2:0]                   state;
 
-assign flit_in_rdy = (state != SEND) & phy_init_done;
-wire flit_in_go = flit_in_val & flit_in_rdy;
-assign out_val = (state == SEND);
+  assign flit_in_rdy = (state != SEND) & phy_init_done;
+  wire flit_in_go    = flit_in_val & flit_in_rdy;
+  assign out_val     = (state == SEND);
 
-always @(posedge clk) begin
-  if(~rst_n) begin
-    state <= ACCEPT_W1;
-    remaining_flits <= 0;
-    pkt_w1 <= 0;
-    pkt_w2 <= 0;
-    pkt_w3 <= 0;
-  end 
-  else begin
-    case (state)
-      ACCEPT_W1: begin
-        if (flit_in_go) begin
-          state <= ACCEPT_W2;
-          remaining_flits <= flit_in[`MSG_LENGTH]-1;
-          pkt_w1 <= flit_in;  
-        end
-        else begin
-          state <= state;
-          remaining_flits <= remaining_flits;
-          pkt_w1 <= pkt_w1;
-        end
-        pkt_w2 <= pkt_w2;
-        pkt_w3 <= pkt_w3;  
+  integer k;
+  always @(posedge clk) begin
+    if (~rst_n) begin
+      state           <= ACCEPT_W1;
+      remaining_flits <= `MSG_LENGTH_WIDTH'd0;
+      beat_idx        <= 3'd0;
+      pkt_w1          <= {`NOC_DATA_WIDTH{1'b0}};
+      pkt_w2          <= {`NOC_DATA_WIDTH{1'b0}};
+      pkt_w3          <= {`NOC_DATA_WIDTH{1'b0}};
+      for (k = 0; k < `PAYLOAD_LEN; k = k + 1) begin
+        in_data_buf[k] <= {`NOC_DATA_WIDTH{1'b0}};
       end
-      ACCEPT_W2: begin
-        if (flit_in_go) begin
-          state <= ACCEPT_W3;
-          remaining_flits <= remaining_flits - 1;
-          pkt_w2 <= flit_in;
-        end
-        else begin
-          state <= state;
-          remaining_flits <= remaining_flits;
-          pkt_w2 <= pkt_w2;
-        end
-        pkt_w1 <= pkt_w1;
-        pkt_w3 <= pkt_w3;  
-      end
-      ACCEPT_W3: begin
-        if (flit_in_go) begin
-          if (remaining_flits == 0) begin
-            state <= SEND;
-            remaining_flits <= 0;
-          end
-          else begin
-            state <= ACCEPT_DATA;
-            remaining_flits <= remaining_flits - 1;
-          end
-          pkt_w3 <= flit_in;  
-        end
-        else begin
-          state <= state;
-          remaining_flits <= remaining_flits;
-          pkt_w3 <= pkt_w3;  
-        end
-        pkt_w1 <= pkt_w1;
-        pkt_w2 <= pkt_w2;
-      end
-      ACCEPT_DATA: begin
-        if (flit_in_go) begin
-          if (remaining_flits == 0) begin
-            state <= SEND;
-            remaining_flits <= 0;
-          end
-          else begin
-            state <= ACCEPT_DATA;
-            remaining_flits <= remaining_flits - 1;
+    end else begin
+      case (state)
+        ACCEPT_W1: begin
+          if (flit_in_go) begin
+            state           <= ACCEPT_W2;
+            remaining_flits <= flit_in[`MSG_LENGTH] - `MSG_LENGTH_WIDTH'd1;
+            beat_idx        <= 3'd0;
+            pkt_w1          <= flit_in;
+            for (k = 0; k < `PAYLOAD_LEN; k = k + 1) begin
+              in_data_buf[k] <= {`NOC_DATA_WIDTH{1'b0}};
+            end
           end
         end
-        else begin
-          state <= state;
-          remaining_flits <= remaining_flits;
+        ACCEPT_W2: begin
+          if (flit_in_go) begin
+            state           <= ACCEPT_W3;
+            remaining_flits <= remaining_flits - `MSG_LENGTH_WIDTH'd1;
+            pkt_w2          <= flit_in;
+          end
         end
-        pkt_w1 <= pkt_w1;
-        pkt_w2 <= pkt_w2;
-        pkt_w3 <= pkt_w3;  
-      end
-      SEND: begin
-        if (out_rdy) begin
-          state <= ACCEPT_W1;
-          remaining_flits <= 0;
-          pkt_w1 <= 0;
-          pkt_w2 <= 0;
-          pkt_w3 <= 0;
+        ACCEPT_W3: begin
+          if (flit_in_go) begin
+            pkt_w3 <= flit_in;
+            if (remaining_flits == `MSG_LENGTH_WIDTH'd0) begin
+              state           <= SEND;
+              remaining_flits <= `MSG_LENGTH_WIDTH'd0;
+            end else begin
+              state           <= ACCEPT_DATA;
+              remaining_flits <= remaining_flits - `MSG_LENGTH_WIDTH'd1;
+              beat_idx        <= 3'd0;
+            end
+          end
         end
-        else begin
-          state <= state;
-          remaining_flits <= remaining_flits;
-          pkt_w1 <= pkt_w1;
-          pkt_w2 <= pkt_w2;
-          pkt_w3 <= pkt_w3;  
+        ACCEPT_DATA: begin
+          if (flit_in_go) begin
+            in_data_buf[3'd7 - beat_idx] <= flit_in;
+            if (remaining_flits == `MSG_LENGTH_WIDTH'd0) begin
+              state           <= SEND;
+              remaining_flits <= `MSG_LENGTH_WIDTH'd0;
+              beat_idx        <= 3'd0;
+            end else begin
+              remaining_flits <= remaining_flits - `MSG_LENGTH_WIDTH'd1;
+              beat_idx        <= beat_idx + 3'd1;
+            end
+          end
         end
-      end
-    endcase // state
-  end
-end
-
-genvar i;
-generate
-  for (i = 0; i < `PAYLOAD_LEN; i = i + 1) begin
-    always @(posedge clk) begin
-      if(~rst_n) begin
-        in_data_buf[i] <= 0;
-      end 
-      else begin
-        in_data_buf[i] <= (i == remaining_flits) & flit_in_val & (state == ACCEPT_DATA) ? flit_in 
-                        : (state == SEND) & out_rdy                                     ? 0
-                        :                                                                 in_data_buf[i];
-      end
+        SEND: begin
+          if (out_rdy) begin
+            state           <= ACCEPT_W1;
+            remaining_flits <= `MSG_LENGTH_WIDTH'd0;
+            beat_idx        <= 3'd0;
+          end
+        end
+        default: begin
+          state           <= ACCEPT_W1;
+          remaining_flits <= `MSG_LENGTH_WIDTH'd0;
+          beat_idx        <= 3'd0;
+        end
+      endcase
     end
   end
-endgenerate
 
-
-
-assign header_out = {pkt_w3, pkt_w2, pkt_w1};
-assign data_out = {in_data_buf[0], in_data_buf[1], in_data_buf[2], in_data_buf[3], in_data_buf[4], in_data_buf[5], in_data_buf[6], in_data_buf[7]};
+  assign header_out = {pkt_w3, pkt_w2, pkt_w1};
+  assign data_out   = {in_data_buf[0], in_data_buf[1], in_data_buf[2], in_data_buf[3],
+                       in_data_buf[4], in_data_buf[5], in_data_buf[6], in_data_buf[7]};
 
 endmodule

--- a/environment/public/code/rtl/noc_axi4_bridge_ser.v (Buggy Starter)
+++ b/solution/gold/code/rtl/noc_axi4_bridge_ser.v (Golden Reference)
@@ -1,200 +1,149 @@
 // ========== Copyright Header Begin ============================================
 // Copyright (c) 2019 Princeton University
 // All rights reserved.
-//
-// Redistribution and use in source and binary forms, with or without
-// modification, are permitted provided that the following conditions are met:
-//     * Redistributions of source code must retain the above copyright
-//       notice, this list of conditions and the following disclaimer.
-//     * Redistributions in binary form must reproduce the above copyright
-//       notice, this list of conditions and the following disclaimer in the
-//       documentation and/or other materials provided with the distribution.
-//     * Neither the name of Princeton University nor the
-//       names of its contributors may be used to endorse or promote products
-//       derived from this software without specific prior written permission.
-//
-// THIS SOFTWARE IS PROVIDED BY PRINCETON UNIVERSITY "AS IS" AND
-// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-// DISCLAIMED. IN NO EVENT SHALL PRINCETON UNIVERSITY BE LIABLE FOR ANY
-// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
+// BSD-3-Clause
 // ========== Copyright Header End ============================================
 
 `include "mc_define.h"
 `include "define.tmp.h"
 `include "noc_axi4_bridge_define.vh"
 
+module noc_axi4_bridge_ser (
+  input  wire                          clk,
+  input  wire                          rst_n,
 
-module noc_axi4_bridge_ser(
-  input clk, 
-  input rst_n, 
+  input  wire [`MSG_HEADER_WIDTH-1:0]  header_in,
+  input  wire [`AXI4_DATA_WIDTH-1:0]   data_in,
+  input  wire                          in_val,
+  output wire                          in_rdy,
 
-  input [`MSG_HEADER_WIDTH-1:0] header_in, 
-  input [`AXI4_DATA_WIDTH-1:0] data_in, 
-  input in_val, 
-  output in_rdy, 
-
-  output reg [`NOC_DATA_WIDTH-1:0] flit_out, 
-  output  flit_out_val, 
-  input flit_out_rdy 
+  output reg  [`NOC_DATA_WIDTH-1:0]    flit_out,
+  output wire                          flit_out_val,
+  input  wire                          flit_out_rdy
 );
 
-// states
-localparam ACCEPT = 2'd0;
-localparam SEND_HEADER = 2'd1;
-localparam SEND_DATA = 2'd2;
+  localparam ACCEPT      = 2'd0;
+  localparam SEND_HEADER = 2'd1;
+  localparam SEND_DATA   = 2'd2;
 
-reg [`AXI4_DATA_WIDTH-1:0] data_in_f;
-reg [`NOC_DATA_WIDTH-1:0] resp_header;
+  reg [`AXI4_DATA_WIDTH-1:0] data_in_f;
+  reg [`NOC_DATA_WIDTH-1:0]  resp_header;
+  reg [1:0]                  state;
+  reg [2:0]                  cur_idx;
+  reg [2:0]                  end_idx;
 
-wire in_go = in_val & in_rdy;
-wire flit_out_go = flit_out_val & flit_out_rdy;
+  wire in_go       = in_val & in_rdy;
+  wire flit_out_go = flit_out_val & flit_out_rdy;
 
-always @(posedge clk) begin 
-  if(~rst_n) begin
-    data_in_f <= {`AXI4_DATA_WIDTH{1'b0}};
-  end 
-  else if (in_go) begin
-    data_in_f <= data_in;
-  end
-  else begin
-    data_in_f <= data_in_f;
-  end
-end
+  assign flit_out_val = (state == SEND_HEADER) || (state == SEND_DATA);
+  assign in_rdy       = (state == ACCEPT);
 
-reg [1:0] state;
-reg [`MSG_LENGTH_WIDTH-1:0] remaining_flits;
-assign flit_out_val = (state == SEND_HEADER) || (state == SEND_DATA);
-assign in_rdy = (state == ACCEPT);
+  wire is_nc_small = (header_in[`MSG_TYPE] == `MSG_TYPE_NC_LOAD_REQ) &&
+                     (header_in[`MSG_DATA_SIZE] <= `MSG_DATA_SIZE_8B) &&
+                     (header_in[`MSG_DATA_SIZE] != `MSG_DATA_SIZE_0B);
+  wire is_nc_zero  = (header_in[`MSG_TYPE] == `MSG_TYPE_NC_LOAD_REQ) &&
+                     (header_in[`MSG_DATA_SIZE] == `MSG_DATA_SIZE_0B);
 
-
-always @(posedge clk) begin
-  if(~rst_n) begin
-    state <= ACCEPT;
-    remaining_flits <= `MSG_LENGTH_WIDTH'b0;
-  end 
-  else begin
-    case (state)
-      ACCEPT: begin
-        state <= in_val ? SEND_HEADER : ACCEPT;
-        remaining_flits <= `MSG_LENGTH_WIDTH'b0;
-      end
-      SEND_HEADER: begin
-        if (flit_out_rdy) begin
-          if (resp_header[`MSG_LENGTH] == 0) begin
-            state <= ACCEPT;
-            remaining_flits <= 0;
-          end
-          else begin
-            state <= SEND_DATA;
-            remaining_flits <= resp_header[`MSG_LENGTH];
+  always @(posedge clk) begin
+    if (~rst_n) begin
+      state       <= ACCEPT;
+      cur_idx     <= 3'd0;
+      end_idx     <= 3'd0;
+      data_in_f   <= {`AXI4_DATA_WIDTH{1'b0}};
+      resp_header <= {`NOC_DATA_WIDTH{1'b0}};
+    end else begin
+      case (state)
+        ACCEPT: begin
+          if (in_go) begin
+            state     <= SEND_HEADER;
+            cur_idx   <= 3'd0;
+            data_in_f <= data_in;
+            resp_header <= {`NOC_DATA_WIDTH{1'b0}};
+            resp_header[`MSG_DST_CHIPID] <= header_in[`MSG_SRC_CHIPID];
+            resp_header[`MSG_DST_X]      <= header_in[`MSG_SRC_X];
+            resp_header[`MSG_DST_Y]      <= header_in[`MSG_SRC_Y];
+            resp_header[`MSG_DST_FBITS]  <= header_in[`MSG_SRC_FBITS];
+            resp_header[`MSG_MSHRID]     <= header_in[`MSG_MSHRID];
+            resp_header[`MSG_OPTIONS_1]  <= {`MSG_OPTIONS_1_WIDTH{1'b0}};
+            case (header_in[`MSG_TYPE])
+              `MSG_TYPE_LOAD_MEM: begin
+                resp_header[`MSG_TYPE]   <= `MSG_TYPE_LOAD_MEM_ACK;
+                resp_header[`MSG_LENGTH] <= `PAYLOAD_LEN;
+                end_idx                  <= 3'd7;
+              end
+              `MSG_TYPE_STORE_MEM: begin
+                resp_header[`MSG_TYPE]   <= `MSG_TYPE_STORE_MEM_ACK;
+                resp_header[`MSG_LENGTH] <= `MSG_LENGTH_WIDTH'd0;
+                end_idx                  <= 3'd0;
+              end
+              `MSG_TYPE_NC_LOAD_REQ: begin
+                resp_header[`MSG_TYPE]   <= `MSG_TYPE_NC_LOAD_MEM_ACK;
+                resp_header[`MSG_LENGTH] <= is_nc_zero  ? `MSG_LENGTH_WIDTH'd0 :
+                                            is_nc_small ? `MSG_LENGTH_WIDTH'd1 : `PAYLOAD_LEN;
+                end_idx                  <= (is_nc_zero || is_nc_small) ? 3'd0 : 3'd7;
+              end
+              `MSG_TYPE_NC_STORE_REQ: begin
+                resp_header[`MSG_TYPE]   <= `MSG_TYPE_NC_STORE_MEM_ACK;
+                resp_header[`MSG_LENGTH] <= `MSG_LENGTH_WIDTH'd0;
+                end_idx                  <= 3'd0;
+              end
+              default: begin
+                resp_header[`MSG_TYPE]   <= `MSG_TYPE_WIDTH'd0;
+                resp_header[`MSG_LENGTH] <= `MSG_LENGTH_WIDTH'd0;
+                end_idx                  <= 3'd0;
+              end
+            endcase
           end
         end
-        else begin
-          state <= state;
-          remaining_flits <= remaining_flits;
+        SEND_HEADER: begin
+          if (flit_out_go) begin
+            if (resp_header[`MSG_LENGTH] == `MSG_LENGTH_WIDTH'd0) begin
+              state   <= ACCEPT;
+              cur_idx <= 3'd0;
+            end else begin
+              state   <= SEND_DATA;
+              cur_idx <= 3'd0;
+            end
+          end
         end
-      end
-      SEND_DATA: begin
-        if (remaining_flits == `MSG_LENGTH_WIDTH'b1) begin
-          state <= flit_out_rdy ? ACCEPT : SEND_DATA;
-          remaining_flits <= 0;
+        SEND_DATA: begin
+          if (flit_out_go) begin
+            if (cur_idx == end_idx) begin
+              state   <= ACCEPT;
+              cur_idx <= 3'd0;
+            end else begin
+              cur_idx <= cur_idx + 3'd1;
+            end
+          end
         end
-        else begin
-          state <= SEND_DATA;
-          remaining_flits <= flit_out_rdy ? remaining_flits - `MSG_LENGTH_WIDTH'b1 : remaining_flits;
+        default: begin
+          state   <= ACCEPT;
+          cur_idx <= 3'd0;
         end
-      end
-      default: begin
-        // should never end up here
-        state <= ACCEPT;
-        remaining_flits <= `MSG_LENGTH_WIDTH'b0;
-      end
-    endcase // state
+      endcase
+    end
   end
-end
 
-always @(posedge clk) begin
-  if (~rst_n) begin
-    resp_header <= `NOC_DATA_WIDTH'b0;
+  reg [`NOC_DATA_WIDTH-1:0] data_slice;
+  always @(*) begin
+    case (cur_idx)
+      3'd0: data_slice = data_in_f[ 63:  0];
+      3'd1: data_slice = data_in_f[127: 64];
+      3'd2: data_slice = data_in_f[191:128];
+      3'd3: data_slice = data_in_f[255:192];
+      3'd4: data_slice = data_in_f[319:256];
+      3'd5: data_slice = data_in_f[383:320];
+      3'd6: data_slice = data_in_f[447:384];
+      3'd7: data_slice = data_in_f[511:448];
+    endcase
   end
-  else begin
+
+  always @(*) begin
     case (state)
-      ACCEPT: begin
-        if (in_go) begin
-          resp_header[`MSG_DST_CHIPID  ]     <= header_in[`MSG_SRC_CHIPID];
-          resp_header[`MSG_DST_X       ]     <= header_in[`MSG_SRC_X     ];
-          resp_header[`MSG_DST_Y       ]     <= header_in[`MSG_SRC_Y     ];
-          resp_header[`MSG_DST_FBITS   ]     <= header_in[`MSG_SRC_FBITS ];
-          resp_header[`MSG_MSHRID      ]     <= header_in[`MSG_MSHRID    ];
-          resp_header[`MSG_OPTIONS_1   ]     <= {`MSG_OPTIONS_1_WIDTH{1'b0}};
-          case (header_in[`MSG_TYPE])
-            `MSG_TYPE_LOAD_MEM: begin
-              resp_header[`MSG_TYPE    ]     <= `MSG_TYPE_LOAD_MEM_ACK;
-              resp_header[`MSG_LENGTH  ]     <= `PAYLOAD_LEN; 
-            end
-            `MSG_TYPE_STORE_MEM: begin
-              resp_header[`MSG_TYPE    ]     <= `MSG_TYPE_STORE_MEM_ACK;
-              resp_header[`MSG_LENGTH  ]     <= 0;
-            end
-            `MSG_TYPE_NC_LOAD_REQ: begin
-              resp_header[`MSG_TYPE    ]     <= `MSG_TYPE_NC_LOAD_MEM_ACK;
-              resp_header[`MSG_LENGTH  ]     <= `PAYLOAD_LEN; 
-            end
-            `MSG_TYPE_NC_STORE_REQ: begin
-              resp_header[`MSG_TYPE    ]     <= `MSG_TYPE_NC_STORE_MEM_ACK;
-              resp_header[`MSG_LENGTH  ]     <= 0;
-            end
-            default: begin
-              // shouldn't end up herere
-              resp_header[`MSG_TYPE    ]     <= `MSG_TYPE_WIDTH'b0;
-              resp_header[`MSG_LENGTH  ]     <= 0;
-            end
-          endcase // header_in[`MSG_TYPE]
-        end
-        else begin
-          resp_header <= resp_header;
-        end
-      end
-      SEND_HEADER: begin
-        if (flit_out_go) begin
-          resp_header <= `NOC_DATA_WIDTH'b0;
-        end
-        else begin
-          resp_header <= resp_header;
-        end
-      end
-      SEND_DATA: begin
-        resp_header <= resp_header;
-      end
-      default: begin
-        //shouldnt end up here
-        resp_header <= `NOC_DATA_WIDTH'b0;
-      end
-    endcase //state
+      SEND_HEADER: flit_out = resp_header;
+      SEND_DATA:   flit_out = data_slice;
+      default:     flit_out = {`NOC_DATA_WIDTH{1'b0}};
+    endcase
   end
-end
 
-always @(*) begin
-  case (state)
-    ACCEPT: begin
-      flit_out = `NOC_DATA_WIDTH'b0;
-    end
-    SEND_HEADER: begin
-      flit_out = resp_header;
-    end
-    SEND_DATA: begin
-      flit_out = data_in_f >> (64 * (`PAYLOAD_LEN - remaining_flits));
-    end
-    default: begin
-      flit_out = `NOC_DATA_WIDTH'b0;
-    end
-  endcase // state
-
-end
 endmodule

--- a/environment/public/code/rtl/noc_axi4_bridge_buffer.v (Buggy Starter)
+++ b/solution/gold/code/rtl/noc_axi4_bridge_buffer.v (Golden Reference)
@@ -29,242 +29,200 @@
 `include "define.tmp.h"
 `include "noc_axi4_bridge_define.vh"
 
-
 module noc_axi4_bridge_buffer (
-  input clk, 
-  input rst_n, 
+  input  wire                                          clk,
+  input  wire                                          rst_n,
 
   // from deserializer
-  input [`MSG_HEADER_WIDTH-1:0] deser_header, 
-  input [`AXI4_DATA_WIDTH-1:0] deser_data, 
-  input deser_val, 
-  output  deser_rdy,
+  input  wire [`MSG_HEADER_WIDTH-1:0]                  deser_header,
+  input  wire [`AXI4_DATA_WIDTH-1:0]                   deser_data,
+  input  wire                                          deser_val,
+  output wire                                          deser_rdy,
 
   // read request out
-  output [`MSG_HEADER_WIDTH-1:0] read_req_header, 
-  output [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] read_req_id,
-  output read_req_val, 
-  input  read_req_rdy,
+  output wire [`MSG_HEADER_WIDTH-1:0]                  read_req_header,
+  output wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0]  read_req_id,
+  output wire                                          read_req_val,
+  input  wire                                          read_req_rdy,
 
   // read response in
-  input [`AXI4_DATA_WIDTH-1:0] read_resp_data, 
-  input [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] read_resp_id,
-  input read_resp_val, 
-  output  read_resp_rdy,
-
-  // read request out
-  output [`MSG_HEADER_WIDTH-1:0] write_req_header, 
-  output [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] write_req_id,
-  output [`AXI4_DATA_WIDTH-1:0] write_req_data, 
-  output write_req_val, 
-  input  write_req_rdy,
-
-  // read response in
-  input [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0] write_resp_id,
-  input write_resp_val, 
-  output  write_resp_rdy,
-
-  // in serializer
-  output [`MSG_HEADER_WIDTH-1:0] ser_header, 
-  output [`AXI4_DATA_WIDTH-1:0] ser_data, 
-  output ser_val, 
-  input  ser_rdy
+  input  wire [`AXI4_DATA_WIDTH-1:0]                   read_resp_data,
+  input  wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0]  read_resp_id,
+  input  wire                                          read_resp_val,
+  output wire                                          read_resp_rdy,
+
+  // write request out
+  output wire [`MSG_HEADER_WIDTH-1:0]                  write_req_header,
+  output wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0]  write_req_id,
+  output wire [`AXI4_DATA_WIDTH-1:0]                   write_req_data,
+  output wire                                          write_req_val,
+  input  wire                                          write_req_rdy,
+
+  // write response in
+  input  wire [`NOC_AXI4_BRIDGE_BUFFER_ADDR_SIZE-1:0]  write_resp_id,
+  input  wire                                          write_resp_val,
+  output wire                                          write_resp_rdy,
+
+  // to serializer
+  output wire [`MSG_HEADER_WIDTH-1:0]           
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/include/define.tmp.h`](environment/public/code/include/define.tmp.h) *(Read-Only Context)*
- [`environment/public/code/include/mc_define.h`](environment/public/code/include/mc_define.h) *(Read-Only Context)*
- [`environment/public/code/include/network_define.v`](environment/public/code/include/network_define.v) *(Read-Only Context)*
- [`environment/public/code/include/noc_axi4_bridge_define.vh`](environment/public/code/include/noc_axi4_bridge_define.vh) *(Read-Only Context)*
- [`environment/public/code/rtl/noc_axi4_bridge.v`](environment/public/code/rtl/noc_axi4_bridge.v) *(Read-Only Context)*
- [`environment/public/code/rtl/noc_axi4_bridge_buffer.v`](environment/public/code/rtl/noc_axi4_bridge_buffer.v) **(Editable)**
- [`environment/public/code/rtl/noc_axi4_bridge_deser.v`](environment/public/code/rtl/noc_axi4_bridge_deser.v) **(Editable)**
- [`environment/public/code/rtl/noc_axi4_bridge_read.v`](environment/public/code/rtl/noc_axi4_bridge_read.v) *(Read-Only Context)*
- [`environment/public/code/rtl/noc_axi4_bridge_ser.v`](environment/public/code/rtl/noc_axi4_bridge_ser.v) **(Editable)**
- [`environment/public/code/rtl/noc_axi4_bridge_sram_data.v`](environment/public/code/rtl/noc_axi4_bridge_sram_data.v) *(Read-Only Context)*
- [`environment/public/code/rtl/noc_axi4_bridge_sram_req.v`](environment/public/code/rtl/noc_axi4_bridge_sram_req.v) *(Read-Only Context)*
- [`environment/public/code/rtl/noc_axi4_bridge_write.v`](environment/public/code/rtl/noc_axi4_bridge_write.v) *(Read-Only Context)*
- [`environment/public/code/rtl/storage_addr_trans.v`](environment/public/code/rtl/storage_addr_trans.v) *(Read-Only Context)*
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

