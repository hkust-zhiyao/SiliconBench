# `case_0088`: Two-Channel TCDM Request Crossbar Stall Stability, Bounded Fairness, Atomic Store Forwarding, and Nangate45 PPA/STA Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0088` |
| **Source Silicon Repository** | `pulp-platform/cluster_interconnect` (`repo_28`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `protocol_control`, `rtl_integration`, `rtl_semantics`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/ArbitrationTree.sv`](environment/public/code/ArbitrationTree.sv), [`code/MUX2_REQ.sv`](environment/public/code/MUX2_REQ.sv), [`code/TestAndSet.sv`](environment/public/code/TestAndSet.sv) (3 files, 734 LOC) |
| **Public Subsystem Context** | 8 RTL files (1759 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# Two-Channel TCDM Request Crossbar Stall Stability, Bounded Fairness, and Atomic Store Forwarding

In the two-channel TCDM request crossbar (`code/RequestBlock2CH.sv`), update only `code/ArbitrationTree.sv`, `code/MUX2_REQ.sv`, and `code/TestAndSet.sv` so that all boundary ports of `RequestBlock2CH` satisfy the following protocol and physical closure requirements:
1. Whenever `RequestBlock2CH` presents a valid memory request (`data_req_o == 1`) while stalled (`data_gnt_i == 0`), the selected channel and requester (`data_ID_o`) as well as `data_add_o`, `data_wen_o`, `data_wdata_o`, and `data_be_o` must remain locked and invariant across clock edges until granted (`data_gnt_i == 1`), even if contenders on either channel assert new requests or `TCDM_arb_policy_i` changes mid-stall. All arbitration state must advance only on a granted handshake and reset to zero on `rst_n == 0`. Under `TCDM_arb_policy_i[c] == 1` (`c` in `{0, 1}`), any requester on channel `c` holding `data_req_CHc_i` must be granted by its channel tree after at most `P_c - 1` other grants on channel `c` (`P_c = 1 << $clog2(N_CHc)`), while `TCDM_arb_policy_i[c] == 0` retains its `0 .. N_CHc - 1` round-robin counter; `MUX2_REQ` must alternate channel priority after any granted channel transfer so an active channel waits at most one transfer by the other channel. When a load (`data_wen == 1`) with address bit `ADDR_MEM_WIDTH` set is accepted, `TestAndSet` must issue its second-cycle store (`data_ts_set_o == 1`, `data_wen_o == 0`) driving `data_wdata_o` with the write data (`data_wdata_CHc_i`) sampled on the accepted atomic load cycle rather than all-ones.

2. Across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}`, the RTL must be strictly latch-free. Synthesizing `RequestBlock2CH` at `N_CH0 = 8, N_CH1 = 4, ADDR_MEM_WIDTH = 32, DATA_WIDTH = 32` with the Yosys/Slang + Nangate45 flow in `BUILD.md` must achieve mapped cell area at most `2,705.0 um^2`, and the OpenROAD placement STA flow at a `2.85 ns` clock must achieve worst setup slack (`WNS`) at least `0.60 ns` and worst hold slack (`WHS`) at least `0.00 ns`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable and Read-Only Files
Edit only:
- `code/ArbitrationTree.sv`
- `code/MUX2_REQ.sv`
- `code/TestAndSet.sv`

Do not modify `code/parameters.v`, `code/FanInPrimitive_Req.sv`, `code/priority_Flag_Req.sv`, `code/AddressDecoder_Resp.sv`, `code/RequestBlock2CH.sv`, or `lib/*`.

## 2. Latch-Free Check & Behavioral Simulation (`Yosys` & `Verilator`)
Verify latch-free synthesis with Yosys:
```bash
yosys -q -p "
  read_verilog -sv -Icode code/ArbitrationTree.sv code/FanInPrimitive_Req.sv code/priority_Flag_Req.sv code/MUX2_REQ.sv code/TestAndSet.sv code/AddressDecoder_Resp.sv code/RequestBlock2CH.sv;
  hierarchy -check -top RequestBlock2CH -chparam N_CH0 4 -chparam N_CH1 2;
  proc; opt_clean;
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr*
"
```

Compile and simulate `RequestBlock2CH` across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}` (`ADDR_MEM_WIDTH=8`, `DATA_WIDTH=32`, `ID_WIDTH=N_CH0+N_CH1`) using Verilator 5:
```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  +incdir+code \
  code/RequestBlock2CH.sv code/ArbitrationTree.sv code/FanInPrimitive_Req.sv \
  code/priority_Flag_Req.sv code/MUX2_REQ.sv code/TestAndSet.sv \
  code/AddressDecoder_Resp.sv tb.sv
./obj_dir/Vtb
```

## 3. Nangate45 Logic Synthesis (`Yosys + Slang`)
Synthesize `RequestBlock2CH` at `N_CH0=8, N_CH1=4, ADDR_MEM_WIDTH=32, DATA_WIDTH=32`:
```bash
yosys -Q -T -m slang -p "
  read_slang --top RequestBlock2CH -G N_CH0=8 -G N_CH1=4 -G ADDR_MEM_WIDTH=32 -G DATA_WIDTH=32 -I code \
    code/ArbitrationTree.sv code/FanInPrimitive_Req.sv code/priority_Flag_Req.sv \
    code/MUX2_REQ.sv code/TestAndSet.sv code/AddressDecoder_Resp.sv code/RequestBlock2CH.sv
  hierarchy -check -top RequestBlock2CH
  synth -top RequestBlock2CH
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
Reported `Chip area for module '\RequestBlock2CH':` must be `<= 2705.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis
Strip ` signed ` tokens (`sed 's/ signed / /g' mapped.v > sta.v`) and run `openroad -exit flow.tcl`:
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design RequestBlock2CH
initialize_floorplan -die_area {0 0 220 220} -core_area {10 10 210 210} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk -period 2.85 [get_ports clk]
set_input_delay 0.2 -clock clk [get_ports {data_req* data_add* data_wen* data_wdata* data_be* data_ID* data_gnt_i data_r_* TCDM_arb_policy_i*}]
set_output_delay 0.2 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.5
estimate_parasitics -placement
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
Required timing closure: `WNS >= 0.60` ns and `WHS >= 0.00` ns.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ArbitrationTree.sv (Buggy Starter)
+++ b/solution/gold/code/ArbitrationTree.sv (Golden Reference)
@@ -1,51 +1,7 @@
-////////////////////////////////////////////////////////////////////////////////
-//                                                                            //
-// Copyright 2018 ETH Zurich and University of Bologna.                       //
-// Copyright and related rights are licensed under the Solderpad Hardware     //
-// License, Version 0.51 (the "License"); you may not use this file except in //
-// compliance with the License.  You may obtain a copy of the License at      //
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law  //
-// or agreed to in writing, software, hardware and materials distributed under//
-// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR     //
-// CONDITIONS OF ANY KIND, either express or implied. See the License for the //
-// specific language governing permissions and limitations under the License. //
-//                                                                            //
-// Company:        Micrel Lab @ DEIS - University of Bologna                  //  
-//                    Viale Risorgimento 2 40136                              //
-//                    Bologna - fax 0512093785 -                              //
-//                                                                            //
-// Engineer:       Igor Loi - igor.loi@unibo.it                               //
-//                                                                            //
-// Additional contributions by:                                               //
-//                                                                            //
-//                                                                            //
-//                                                                            //
-// Create Date:    06/07/2011                                                 // 
-// Design Name:    LOG_INTERCONNECT                                           // 
-// Module Name:    ArbitrationTree                                            //
-// Project Name:   MegaLEON                                                   //
-// Language:       SystemVerilog                                              //
-//                                                                            //
-// Description:    Arbitration tree: This block performs the arbitration      //
-//                 between the N_MASTER requests. The arbitration is          //
-//                 distributed in the several arbitration primitives that     //
-//                 compose this routing block. The arbistrtion is round robin //
-//                 and the round robin flag generator is embedded inside this //
-//                 block. Flag updating happens only when requests are grant  //
-//                                                                            //
-// Revision:                                                                  //
-// Revision v0.1 - File Created                                               //
-// Revision v0.2 - (19/02/2015) Restyling                                     //
-//                                                                            //
-// Additional Comments:                                                       //
-//                                                                            //
-//                                                                            //
-//                                                                            //
-//                                                                            //
-////////////////////////////////////////////////////////////////////////////////
+// Copyright 2018 ETH Zurich and University of Bologna.
+// Solderpad Hardware License, Version 0.51.
 
 `include "parameters.v"
-
 
 module ArbitrationTree 
 #(
@@ -94,13 +50,50 @@
     logic [LOG_MASTER-1:0]        s_ID;
     logic [N_MASTER-1:0][LOG_MASTER-1:0]    ID_int;
 
+    logic                         downstream_gnt;
+  `ifdef GNT_BASED_FC
+    assign downstream_gnt = data_gnt_i;
+  `else
+    assign downstream_gnt = ~data_stall_i;
+  `endif
+
+    // Stall lock state: hold selected winner stable while data_req_o && !downstream_gnt
+    logic                         lock_q;
+    logic [LOG_MASTER-1:0]        locked_id_q;
+    logic [N_MASTER-1:0]          eff_req;
+
+    assign eff_req = (lock_q && data_req_i[locked_id_q]) ? (N_MASTER'(1) << locked_id_q) : data_req_i;
+
+    always_ff @(posedge clk or negedge rst_n) begin
+      if (!rst_n) begin
+        lock_q      <= 1'b0;
+        locked_id_q <= '0;
+      end else if (data_req_o && !downstream_gnt) begin
+        lock_q      <= 1'b1;
+        locked_id_q <= s_ID;
+      end else begin
+        lock_q      <= 1'b0;
+      end
+    end
+
+    // Remember the next preference separately for each internal fan-in node.
+    logic [N_MASTER-2:0] fair_next_q;
+    integer level, node;
+    always_ff @(posedge clk or negedge rst_n) begin
+      if (!rst_n) fair_next_q <= '0;
+      else if (data_req_o && downstream_gnt) begin
+        for (level = 0; level < LOG_MASTER; level = level + 1)
+          for (node = 0; node < (1 << level); node = node + 1)
+            if ((s_ID >> (LOG_MASTER-level)) == node)
+              fair_next_q[(1 << level)-1+node] <= ~s_ID[LOG_MASTER-level-1];
+      end
+    end
+
     genvar j,k;
-
 
     generate
       if(N_MASTER == 2)
-        begin : INCR // START of  MASTER  == 2
-                    // ---------------- FAN IN PRIMITIVE  -------------------------
+        begin : INCR
                     FanInPrimitive_Req 
                     #(
                         .ADDR_WIDTH     ( ADDR_WIDTH      ), 
@@ -111,14 +104,13 @@
                     ) 
                     i_FanInPrimitive_Req
                     (
-                        .PRIO_FLAG      ( s_RR_FLAG       ),
-                        // LEFT SIDE"
+                        .PRIO_FLAG      ( TCDM_arb_policy_i ? fair_next_q[0] : s_RR_FLAG[0] ),
                         .data_wdata0_i  ( data_wdata_i[0] ),
                         .data_wdata1_i  ( data_wdata_i[1] ),
                         .data_add0_i    ( data_add_i[0]   ),
                         .data_add1_i    ( data_add_i[1]   ),
-                        .data_req0_i    ( data_req_i[0]   ),
-                        .data_req1_i    ( data_req_i[1]   ),
+                        .data_req0_i    ( eff_req[0]      ),
+                        .data_req1_i    ( eff_req[1]      ),
                         .data_wen0_i    ( data_wen_i[0]   ),
                         .data_wen1_i    ( data_wen_i[1]   ),
                         .data_ID0_i     ( data_ID_i[0]    ),
@@ -134,7 +126,6 @@
                         .data_stall0_o  ( data_stall_o[0] ),
                         .data_stall1_o  ( data_stall_o[1] ),
                 `endif
-                        // RIGTH SIDE"
                         .data_wdata_o   ( data_wdata_o    ),
                         .data_add_o     ( data_add_o      ),
                         .data_req_o     ( data_req_o      ),
@@ -148,20 +139,15 @@
                         .data_stall_i   ( data_stall_i    )
                 `endif
                         );
-        end // END OF MASTER  == 2
-      else // More than two master
+        end
+      else
         begin : BINARY_TREE
-            //// ---------------------------------------------------------------------- ////
-            //// -------               REQ ARBITRATION TREE WIRES           ----------- ////
-            //// ---------------------------------------------------------------------- ////        
             logic [N_WIRE-1:0][DATA_WIDTH-1:0]     data_wdata_LEVEL;
             logic [N_WIRE-1:0][ADDR_WIDTH-1:0]     data_add_LEVEL;
             logic [N_WIRE-1:0]                     data_req_LEVEL;
             logic [N_WIRE-1:0]                     data_wen_LEVEL;
             logic [N_WIRE-1:0][ID_WIDTH-1:0]       data_ID_LEVEL;
-            
             logic [N_WIRE-1:0][LOG_MASTER-1:0]     ID_LEVEL;
-
             logic [N_WIRE-1:0][BE_WIDTH-1:0]       data_be_LEVEL;
         `ifdef GNT_BASED_FC
             logic [N_WIRE-1:0]                     data_gnt_LEVEL;
@@ -169,13 +155,12 @@
             logic [N_WIRE-1:0]                     data_stall_LEVEL;
         `endif
 
-
-               for(j=0; j < LOG_MASTER; j++) // Iteration for the number of the stages minus one
+               for(j=0; j < LOG_MASTER; j++)
                 begin : STAGE
-                  for(k=0; k<2**j; k=k+1) // Iteration needed to create the binary tree
+                  for(k=0; k<2**j; k=k+1)
                     begin : INCR_VERT
 
-                      if (j == 0 )  // LAST NODE, drives the module outputs
+                      if (j == 0 )
                       begin : LAST_NODE
                           FanInPrimitive_Req 
                           #(
@@ -187,8 +172,7 @@
                           ) 
                           i_FanInPrimitive_Req
                           (
-                              .PRIO_FLAG      ( s_RR_FLAG[LOG_MASTER-j-1] ),
-                              // LEFT SIDE
+                              .PRIO_FLAG      ( TCDM_arb_policy_i ? fair_next_q[(1<<j)-1+k] : s_RR_FLAG[LOG_MASTER-j-1] ),
                               .data_wdata0_i  ( data_wdata_LEVEL[2*k]   ),
                               .data_wdata1_i  ( data_wdata_LEVEL[2*k+1] ),
                               .data_add0_i    ( data_add_LEVEL[2*k]     ),
@@ -199,10 +183,8 @@
                               .data_wen1_i    ( data_wen_LEVEL[2*k+1]   ),
                               .data_ID0_i     ( data_ID_LEVEL[2*k]      ),
                               .data_ID1_i     ( data_ID_LEVEL[2*k+1]    ),
-
                               .ID0_i          ( ID_LEVEL[2*k]           ),
                               .ID1_i          ( ID_LEVEL[2*k+1]         ),
-                                                           
                               .data_be0_i     ( data_be_LEVEL[2*k]      ),
                               .data_be1_i     ( data_be_LEVEL[2*k+1]    ),
                           `ifdef GNT_BASED_FC
@@ -212,7 +194,6 @@
                               .data_stall0_o  ( data_stall_LEVEL[2*k]   ),
                               .data_stall1_o  ( data_stall_LEVEL[2*k+1] ),
                           `endif
-                              // RIGTH SIDE
                               .data_wdata_o   ( data_wdata_o            ),
                               .data_add_o     ( data_add_o              ),
                               .data_req_o     ( data_req_o              ),
@@ -227,8 +208,8 @@
                           `endif
                           );
                       end 
-                      else if ( j < LOG_MASTER - 1) // Middle Nodes
-                              begin : MIDDLE_NODES // START of MIDDLE LEVELS Nodes   
+                      else if ( j < LOG_MASTER - 1)
+                              begin : MIDDLE_NODES
                                   FanInPrimitive_Req 
                                   #(
                                       .ADDR_WIDTH     ( ADDR_WIDTH                              ), 
@@ -239,8 +220,7 @@
                                   ) 
                                   i_FanInPrimitive_Req
                                   (
-                                      .PRIO_FLAG(s_RR_FLAG[LOG_MASTER-j-1]),
-                                      // LEFT SIDE
+                                      .PRIO_FLAG(TCDM_arb_policy_i ? fair_next_q[(1<<j)-1+k] : s_RR_FLAG[LOG_MASTER-j-1]),
                                       .data_wdata0_i  ( data_wdata_LEVEL[((2**j)*2-2) + 2*k]    ),
                                       .data_wdata1_i  ( data_wdata_LEVEL[((2**j)*2-2) + 2*k +1] ),
                                       .data_add0_i    ( data_add_LEVEL[((2**j)*2-2) + 2*k]      ),
@@ -249,13 +229,10 @@
                                       .data_req1_i    ( data_req_LEVEL[((2**j)*2-2) + 2*k+1]    ),
                                       .data_wen0_i    ( data_wen_LEVEL[((2**j)*2-2) + 2*k]      ),
                                       .data_wen1_i    ( data_wen_LEVEL[((2**j)*2-2) + 2*k+1]    ),
-                                      
                                       .data_ID0_i     ( data_ID_LEVEL[((2**j)*2-2) + 2*k]       ),
                                       .data_ID1_i     ( data_ID_LEVEL[((2**j)*2-2) + 2*k+1]     ),
-
                                       .ID0_i          ( ID_LEVEL[((2**j)*2-2) + 2*k]            ),
                                       .ID1_i          ( ID_LEVEL[((2**j)*2-2) + 2*k+1]          ),                                     
-
                                       .data_be0_i     ( data_be_LEVEL[((2**j)*2-2) + 2*k]       ),
                                       .data_be1_i     ( data_be_LEVEL[((2**j)*2-2) + 2*k+1]     ),
                               `ifdef GNT_BASED_FC
@@ -265,8 +242,6 @@
                                       .data_stall0_o  ( data_stall_LEVEL[((2**j)*2-2) + 2*k]    ),
                                       .data_stall1_o  ( data_stall_LEVEL[((2**j)*2-2) + 2*k+1]  ),
                               `endif
-
-                                      // RIGTH SIDE
                                       .data_wdata_o   ( data_wdata_LEVEL[((2**(j-1))*2-2) + k]  ),
                                       .data_add_o     ( data_add_LEVEL[((2**(j-1))*2-2) + k]    ),
                                       .data_req_o     ( data_req_LEVEL[((2**(j-1))*2-2) + k]    ),
@@ -280,10 +255,9 @@
                                       .data_stall_i   ( data_stall_LEVEL[((2**(j-1))*2-2) + k]  )
                               `endif
                                   );
-                              end  // END of MIDDLE LEVELS Nodes   
-                           else // First stage (connected with the Main inputs ) --> ( j == N_MASTER - 1 )
-                              begin : LEAF_NODES  // START of FIRST LEVEL Nodes (LEAF)
-
+                              end
+                           else
+                              begin : LEAF_NODES
                                   assign ID_int[2*k]   = 2*k;
                                   assign ID_int[2*k+1] = 2*k+1;
                                   
@@ -297,14 +271,13 @@
                                   ) 
                                   i_FanInPrimitive_Req
                                   (
-                                      .PRIO_FLAG(s_RR_FLAG[LOG_MASTER-j-1]),
-                                      // LEFT SIDE
+                                      .PRIO_FLAG(TCDM_arb_policy_i ? fair_next_q[(1<<j)-1+k] : s_RR_FLAG[LOG_MASTER-j-1]),
                                       .data_wdata0_i  ( data_wdata_i[2*k]  ),
                                       .data_wdata1_i  ( data_wdata_i[2*k+1]),
                                       .data_add0_i    ( data_add_i[2*k]    ),
                                       .data_add1_i    ( data_add_i[2*k+1]  ),
-                                      .data_req0_i    ( data_req_i[2*k]    ),
-                                      .data_req1_i    ( data_req_i[2*k+1]  ),
+                                      .data_req0_i    ( eff_req[2*k]       ),
+                                      .data_req1_i    ( eff_req[2*k+1]     ),
                                       .data_wen0_i    ( data_wen_i[2*k]    ),
                                       .data_wen1_i    ( data_wen_i[2*k+1]  ),
                                       .data_ID0_i     ( data_ID_i[2*k]     ),
@@ -320,8 +293,6 @@
                                       .data_stall0_o  ( data_stall_o[2*k]  ),
                                       .data_stall1_o  ( data_stall_o[2*k+1]),
                               `endif
-      
-                                      // RIGTH SIDE
                                       .data_wdata_o   ( data_wdata_LEVEL[((2**(j-1))*2-2) + k] ),
                                       .data_add_o     ( data_add_LEVEL[((2**(j-1))*2-2) + k]   ),
                                       .data_req_o     ( data_req_LEVEL[((2**(j-1))*2-2) + k]   ),
@@ -335,19 +306,17 @@
                                       .data_stall_i   ( data_stall_LEVEL[((2**(j-1))*2-2) + k] )
                               `endif
                                   );
-                              end // End of FIRST LEVEL Nodes (LEAF)
+                              end
                     end
                 end
     end
     endgenerate
 
-    //COUNTER USED TO SWITCH PERIODICALLY THE PRIORITY FLAG"
     priority_Flag_Req #( .WIDTH(LOG_MASTER), .MAX_COUNT(MAX_COUNT) )  PRIORITY_ENC_REQ
     (
         .clk               ( clk                     ),
         .rst_n             ( rst_n                   ),
         .TCDM_arb_policy_i ( TCDM_arb_policy_i       ),
-
         .PRIO_FLAG_o       ( s_RR_FLAG               ), 
         .data_req_i        ( data_req_o              ),
         .ID_i              ( s_ID                    ),
@@ -358,5 +327,4 @@
       `endif
     );
 
-
 endmodule

--- a/environment/public/code/MUX2_REQ.sv (Buggy Starter)
+++ b/solution/gold/code/MUX2_REQ.sv (Golden Reference)
@@ -1,45 +1,5 @@
-////////////////////////////////////////////////////////////////////////////////
-//                                                                            //
-// Copyright 2018 ETH Zurich and University of Bologna.                       //
-// Copyright and related rights are licensed under the Solderpad Hardware     //
-// License, Version 0.51 (the "License"); you may not use this file except in //
-// compliance with the License.  You may obtain a copy of the License at      //
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law  //
-// or agreed to in writing, software, hardware and materials distributed under//
-// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR     //
-// CONDITIONS OF ANY KIND, either express or implied. See the License for the //
-// specific language governing permissions and limitations under the License. //
-//                                                                            //
-// Company:        Micrel Lab @ DEIS - University of Bologna                  //  
-//                    Viale Risorgimento 2 40136                              //
-//                    Bologna - fax 0512093785 -                              //
-//                                                                            //
-// Engineer:       Igor Loi - igor.loi@unibo.it                               //
-//                                                                            //
-// Additional contributions by:                                               //
-//                                                                            //
-//                                                                            //
-//                                                                            //
-// Create Date:    29/06/2011                                                 // 
-// Design Name:    LOG_INTERCONNECT                                           // 
-// Module Name:    MUX2_REQ                                                   //
-// Language:       SystemVerilog                                              //
-//                                                                            //
-// Description:    two input multiplxer whith custom ports used to multiplex  //
-//                 the datapath request data. It includes an embeddedd        //
-//                 Fixed Priory arbiter with max priority to Channel 0 (CH0)  //
-//                                                                            //
-//                                                                            //
-// Revision:                                                                  //
-// Revision v0.1 - File Created                                               //
-// Revision v0.2 - (19/02/2015) Restyling                                     //
-//                                                                            //
-// Additional Comments:                                                       //
-//                                                                            //
-//                                                                            //
-//                                                                            //
-//                                                                            //
-////////////////////////////////////////////////////////////////////////////////
+// Copyright 2018 ETH Zurich and University of Bologna.
+// Solderpad Hardware License, Version 0.51.
 
 `include "parameters.v"
 
@@ -62,7 +22,6 @@
 `else
     output logic                                 data_stall_CH0_o,
 `endif
-
 
     input  logic                                 data_req_CH1_i,
     input  logic [ADDR_WIDTH-1:0]                data_add_CH1_i,
@@ -92,33 +51,55 @@
     input   logic                                rst_n
 );
 
-    logic                                         SEL; // Mux Selector
+    logic                                        SEL;
     logic                                        RR_FLAG;
+    logic                                        lock_q;
+    logic                                        locked_sel_q;
+    logic                                        eff_req0, eff_req1;
+    logic                                        hs_ok;
 
-    // Request is simply an or between indoming request
-    assign data_req_o = data_req_CH0_i | data_req_CH1_i;
-
-      // FIXED PRIORITY ENCODER
-    assign SEL                =   ~data_req_CH0_i | ( RR_FLAG & data_req_CH1_i);        // SEL FOR ROUND ROBIN MUX
 `ifdef GNT_BASED_FC
-    assign data_gnt_CH0_o     =    (( data_req_CH0_i & ~data_req_CH1_i) | ( data_req_CH0_i & ~RR_FLAG)) & data_gnt_i;
-    assign data_gnt_CH1_o     =    ((~data_req_CH0_i &  data_req_CH1_i) | ( data_req_CH1_i &  RR_FLAG)) & data_gnt_i;
+    assign hs_ok = data_gnt_i;
 `else
-    assign data_stall_CH0_o   =   (data_req_CH0_i & data_req_CH1_i & RR_FLAG)  |  ((( data_req_CH0_i & ~data_req_CH1_i) | ( data_req_CH0_i & ~RR_FLAG)) & data_stall_i);
-    assign data_stall_CH1_o   =   (data_req_CH0_i & data_req_CH1_i & ~RR_FLAG) |  (((~data_req_CH0_i &  data_req_CH1_i) | ( data_req_CH1_i &  RR_FLAG)) & data_stall_i);
+    assign hs_ok = ~data_stall_i;
 `endif
 
-    always_ff @(posedge clk, negedge rst_n)
+    assign eff_req0 = (lock_q && (locked_sel_q ? data_req_CH1_i : data_req_CH0_i)) ? (~locked_sel_q & data_req_CH0_i) : data_req_CH0_i;
+    assign eff_req1 = (lock_q && (locked_sel_q ? data_req_CH1_i : data_req_CH0_i)) ? ( locked_sel_q & data_req_CH1_i) : data_req_CH1_i;
+
+    assign data_req_o = eff_req0 | eff_req1;
+    assign SEL        = ~eff_req0 | (RR_FLAG & eff_req1);
+
+`ifdef GNT_BASED_FC
+    assign data_gnt_CH0_o     = (( eff_req0 & ~eff_req1) | ( eff_req0 & ~RR_FLAG)) & data_gnt_i;
+    assign data_gnt_CH1_o     = ((~eff_req0 &  eff_req1) | ( eff_req1 &  RR_FLAG)) & data_gnt_i;
+`else
+    assign data_stall_CH0_o   = (eff_req0 & eff_req1 & RR_FLAG)  | ((( eff_req0 & ~eff_req1) | ( eff_req0 & ~RR_FLAG)) & data_stall_i);
+    assign data_stall_CH1_o   = (eff_req0 & eff_req1 & ~RR_FLAG) | (((~eff_req0 &  eff_req1) | ( eff_req1 &  RR_FLAG)) & data_stall_i);
+`endif
+
+    always_ff @(posedge clk or negedge rst_n)
     begin
-      if(rst_n == 1'b0)
-          RR_FLAG <= 1'b0;
-      else if((data_req_o == 1'b1) && `ifdef GNT_BASED_FC (data_gnt_i == 1'b1) `else (data_stall_i == 1'b0) `endif)
-              RR_FLAG <= ~RR_FLAG;
+      if (rst_n == 1'b0) begin
+          RR_FLAG      <= 1'b0;
+          lock_q       <= 1'b0;
+          locked_sel_q <= 1'b0;
+      end else begin
+          if (data_req_o && hs_ok) begin
+              RR_FLAG <= ~SEL;
+              lock_q  <= 1'b0;
+          end else if (data_req_o && !hs_ok) begin
+              lock_q       <= 1'b1;
+              locked_sel_q <= SEL;
+          end else begin
+              lock_q <= 1'b0;
+          end
+      end
     end
 
     always_comb
     begin : MUX2_REQ_COMB
-      case(SEL) // synopsys full_case
+      case(SEL)
       1'b0: begin
             data_add_o   = data_add_CH0_i;
             data_wen_o   = data_wen_CH0_i;
@@ -126,8 +107,7 @@
             data_be_o    = data_be_CH0_i;
             data_ID_o    = data_ID_CH0_i;
           end
-      1'b1:
-          begin
+      1'b1: begin
             data_add_o   = data_add_CH1_i;
             data_wen_o   = data_wen_CH1_i;
             data_wdata_o = data_wdata_CH1_i;

--- a/environment/public/code/TestAndSet.sv (Buggy Starter)
+++ b/solution/gold/code/TestAndSet.sv (Go
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/LICENSE`](environment/public/LICENSE) *(Read-Only Context)*
- [`environment/public/code/AddressDecoder_Resp.sv`](environment/public/code/AddressDecoder_Resp.sv) *(Read-Only Context)*
- [`environment/public/code/ArbitrationTree.sv`](environment/public/code/ArbitrationTree.sv) **(Editable)**
- [`environment/public/code/FanInPrimitive_Req.sv`](environment/public/code/FanInPrimitive_Req.sv) *(Read-Only Context)*
- [`environment/public/code/MUX2_REQ.sv`](environment/public/code/MUX2_REQ.sv) **(Editable)**
- [`environment/public/code/RequestBlock2CH.sv`](environment/public/code/RequestBlock2CH.sv) *(Read-Only Context)*
- [`environment/public/code/TestAndSet.sv`](environment/public/code/TestAndSet.sv) **(Editable)**
- [`environment/public/code/parameters.v`](environment/public/code/parameters.v) *(Read-Only Context)*
- [`environment/public/code/priority_Flag_Req.sv`](environment/public/code/priority_Flag_Req.sv) *(Read-Only Context)*
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

