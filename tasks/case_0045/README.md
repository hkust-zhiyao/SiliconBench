# `case_0045`: TCDM Variable-Latency Crossbar Stall Lock, Bounded Starvation Fairness, and Latch-Free Synthesis

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0045` |
| **Source Silicon Repository** | `pulp-platform/cluster_interconnect` (`repo_28`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 2: Logic Synthesis & Gate-Level Verification** (`stage2_synth_gate`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Yosys+Slang Standard-Cell Synthesis, Cell-Area Caps & 4-State Gate-Level X-Propagation Verification) |
| **Primary Hardware Domain** | `rtl_semantics` (SystemVerilog Semantics, Sim-Synth Mismatch, Latch Avoidance & X-Blocking) |
| **Multi-Domain Tags** | `protocol_control`, `rtl_integration`, `rtl_semantics`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/ArbitrationTree.sv`](environment/public/code/ArbitrationTree.sv), [`code/priority_Flag_Req.sv`](environment/public/code/priority_Flag_Req.sv) (2 files, 409 LOC) |
| **Public Subsystem Context** | 7 RTL files (1237 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# TCDM Variable-Latency Crossbar Stall Lock and Bounded Starvation Fairness

In the TCDM request block (`code/ArbitrationTree.sv` and `code/priority_Flag_Req.sv`), downstream memory stalls and multi-level arbitration interact to cause two protocol violations:
1. **Stalled Output Preemption & Priority Drift**: Once `ArbitrationTree` presents a valid request at its output (`data_req_o == 1`) and is stalled by `data_gnt_i == 0` (or `data_stall_i == 1` when `GNT_BASED_FC` is not defined), its selected winning master (`data_ID_o`) and request payload (`data_add_o`, `data_wen_o`, `data_wdata_o`, `data_be_o`) must remain strictly locked and stable across clock cycles until that request is accepted (`data_gnt_i == 1`), even if higher-priority or round-robin-favored masters assert new requests or `TCDM_arb_policy_i` changes during the stall. Priority state in both `priority_Flag_Req` and `ArbitrationTree` must advance only on an actual granted transfer (`data_req_o && data_gnt_i`).
2. **Policy 1 Bounded Starvation Fairness**: When `TCDM_arb_policy_i == 1`, any requester that continuously holds its request until granted must be accepted after at most `P - 1` other accepted requests, where `P = 1 << $clog2(N_CH0)` is the binary tree's padded input count. Policy 0 (`TCDM_arb_policy_i == 0`) must retain its existing round-robin counter behavior (`0` through `MAX_COUNT`).

Update `code/ArbitrationTree.sv` and `code/priority_Flag_Req.sv` while preserving work conservation, response decoding, two-cycle `TestAndSet` atomic continuation, asynchronous reset behavior, and strictly latch-free synthesizable RTL across all editable files.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Instructions

Compile the TCDM request channel integration with Verilator 5 (`verilator --binary --timing -j 1 -Wno-fatal +incdir+code`) using:
- `code/RequestBlock1CH.sv`
- `code/ArbitrationTree.sv`
- `code/FanInPrimitive_Req.sv`
- `code/priority_Flag_Req.sv`
- `code/TestAndSet.sv`
- `code/AddressDecoder_Resp.sv`

Check latch-free synthesis with Yosys (`read_verilog -sv -Icode ...; hierarchy -check -top RequestBlock1CH; proc; opt_clean; select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr*`).

The editable files are `code/ArbitrationTree.sv` and `code/priority_Flag_Req.sv`. Do not modify the other files in `code/`.

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

--- a/environment/public/code/priority_Flag_Req.sv (Buggy Starter)
+++ b/solution/gold/code/priority_Flag_Req.sv (Golden Reference)
@@ -28,7 +28,11 @@
       if(rst_n == 1'b0)
          PRIO_FLAG_o <= '0;
       else
-            if( data_req_i )
+      `ifdef GNT_BASED_FC
+            if( data_req_i  & data_gnt_i )
+      `else
+            if( data_req_i  & ~data_stall_i )
+      `endif
             begin
                   if(TCDM_arb_policy_i == 1'b0)
                   begin : RR_PRIORIY

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
- [`environment/public/code/RequestBlock1CH.sv`](environment/public/code/RequestBlock1CH.sv) *(Read-Only Context)*
- [`environment/public/code/TestAndSet.sv`](environment/public/code/TestAndSet.sv) *(Read-Only Context)*
- [`environment/public/code/parameters.v`](environment/public/code/parameters.v) *(Read-Only Context)*
- [`environment/public/code/priority_Flag_Req.sv`](environment/public/code/priority_Flag_Req.sv) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

