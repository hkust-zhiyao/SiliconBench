# `case_5011`: CVA6 RV32 Zcmp/Zcmt ID-Stage Macro & Table-Jump Expansion, Pipeline Flush/Backpressure Control, and Synthesis/Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_5011` |
| **Source Silicon Repository** | `openhwfoundation/cva6` (`repo_05`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `parameters_widths` (Parameterization, Bit-Width Upsizing/Downsizing, Deserialization & Casting) |
| **Multi-Domain Tags** | `parameters_widths`, `reset_rdc`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/macro_decoder.sv`](environment/public/code/macro_decoder.sv), [`code/zcmt_decoder.sv`](environment/public/code/zcmt_decoder.sv), [`code/id_stage.sv`](environment/public/code/id_stage.sv) (3 files, 1398 LOC) |
| **Public Subsystem Context** | 13 RTL files (7526 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Task-Specific Multi-Corner Liberty & SDC Timing Views** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Custom characterized fast/slow/scan corner Liberty libraries for multi-mode OpenSTA closure. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CVA6 RV32 Zcmp/Zcmt ID-Stage Macro & Table-Jump Expansion, Pipeline Flush/Backpressure Control, and Synthesis/Timing Closure

## Background

In the 32-bit CVA6 embedded configuration (`RV32IMAC` with `Zcb`, `Zcmp`, and `Zcmt` code-size reduction extensions enabled, `NrIssuePorts = 1`), the Instruction Decode (`id_stage`) subsystem integrates:

- `code/compressed_decoder.sv`: first-pass 16-bit RVC/Zcb decompression and detection of `Zcmp` (`is_macro_instr_o`) and `Zcmt` (`is_zcmt_instr_o`) instructions.
- `code/macro_decoder.sv`: multi-cycle micro-operation sequencer that expands `Zcmp` instructions (`cm.push`, `cm.pop`, `cm.popret`, `cm.popretz`, `cm.mvsa01`, `cm.mva01s`) into a sequence of 32-bit RISC-V store, load, arithmetic (`addi`/`lui`), and return (`jalr x0, x1, 0`) micro-operations.
- `code/zcmt_decoder.sv`: two-state table-jump controller (`IDLE`, `TABLE_JUMP`) that translates `cm.jt` (`index < 32`) and `cm.jalt` (`index >= 32`) into a jump-vector-table (`JVT`) data-cache read request (`{jvt_i.base, 6'b000000} + (index << 2)`) and, upon receiving `req_port_i.data_rvalid`, synthesizes a PC-relative `jal` instruction (`rd = x0` for `cm.jt`, `rd = x1` for `cm.jalt`) with `jump_address_o = ({req_port_i.data_rdata[31:1], 1'b0} - pc_i)`.
- `code/decoder.sv` and `code/id_stage.sv`: full 32-bit instruction decoding, `fetch_entry_ready_o` upstream handshaking, and the `ID <-> Issue` pipeline register (`issue_q[0]`).

During verification and Nangate45 synthesis/STA sign-off of the `id_decode_top` wrapper (`flow/id_decode_top.sv`), several functional, structural, and timing closure issues were identified across `code/macro_decoder.sv`, `code/zcmt_decoder.sv`, and `code/id_stage.sv`.

## Problem Description & Architectural Requirements

1. **Valid-Qualified & Flush-Safe Zcmp/Zcmt Activation and Pipeline Handshaking (`code/id_stage.sv`, `code/macro_decoder.sv`, `code/zcmt_decoder.sv`)**:
   - `compressed_decoder_i` decodes `fetch_entry_i[0].instruction` combinationally regardless of `fetch_entry_valid_i[0]` or `flush_i`. Neither `macro_decoder_i` nor `zcmt_decoder_i` may initiate a sequence or assert a D-Cache table read request (`dcache_req_ports_o.data_req`) when `fetch_entry_valid_i[0]` is deasserted or when `flush_i` is asserted.
   - Whenever `flush_i` is asserted, `id_stage` must not acknowledge/pop the upstream fetch entry (`fetch_entry_ready_o` must remain `'0`), must invalidate `issue_q[0].valid`, and any in-flight `macro_decoder` expansion or `zcmt_decoder` `TABLE_JUMP` lookup must abort cleanly and return to `IDLE` (with `zcmt_decoder` asserting `req_port_o.kill_req = 1'b1` when aborted in `TABLE_JUMP`) so that post-flush instructions decode without residual state corruption.

2. **Micro-Operation Sequencing Under Empty/Full ID-Issue Pipeline Register & Backpressure (`code/macro_decoder.sv`, `code/id_stage.sv`)**:
   - In `id_stage`, a decoded micro-operation at the output of `decoder_i` is latched into the `issue_q[0]` pipeline register whenever `(!issue_q[0].valid || issue_instr_ack_i[0]) && fetch_entry_valid_i[0] && !flush_i`.
   - `macro_decoder` must drive each micro-operation (`instr_o`, `is_last_macro_instr_o`, `is_double_rd_macro_instr_o`, `fetch_stall_o`) combinationally from its current state regardless of whether `issue_ack_i` is currently asserted, and advance its state machine one step per micro-operation accepted into `issue_q[0]`, releasing `fetch_stall_o` (`fetch_entry_ready_o[0] = 1'b1`) only when the final micro-operation of the `Zcmp` sequence is accepted into `issue_q[0]`.
   - Similarly, while `zcmt_decoder` is waiting in `TABLE_JUMP` for `req_port_i.data_rvalid`, it must hold `fetch_stall_o = 1'b1` so `id_stage` neither pops `fetch_entry_i[0]` nor marks `issue_q[0].valid` until the table entry arrives.

3. **Latch-Free / Combinational-Loop-Free Synthesis & Area/Timing Closure (`code/macro_decoder.sv`, `code/zcmt_decoder.sv`, `code/id_stage.sv`)**:
   - All combinational blocks in `macro_decoder`, `zcmt_decoder`, and `id_stage` must be completely specified with no inferred latches and zero combinational logic loops (`scc -expect 0` in Yosys after `proc; opt_clean`).
   - On the critical decode path through `id_decode_top`, avoid routing non-macro / non-table-jump instructions serially through the `macro_decoder` mux tree or re-evaluating chained 12-bit stack-adjustment adders across every state cycle.
   - Under the Nangate45 synthesis and OpenROAD STA sign-off flow (`flow/id_decode_top.sv` at a `1.95 ns` clock period on `clk_i` with `0.15 ns` input/output external delays and `abc -D 1000`):
     - Worst setup slack (`max`): `>= 0.00 ns`
     - Worst hold slack (`min`): `>= 0.00 ns`
     - Total cell area of `id_decode_top`: `<= 2560.0 um^2`

## Deliverable

Update only the editable RTL files:
- `code/macro_decoder.sv`
- `code/zcmt_decoder.sv`
- `code/id_stage.sv`

Do not modify module port signatures or package definitions.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/macro_decoder.sv`
- `code/zcmt_decoder.sv`
- `code/id_stage.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/id_decode_top.sv` (top module: `id_decode_top`)
- Liberty library: `lib/NangateOpenCellLibrary_typical.lib`
- LEF files:
  - `lef/NangateOpenCellLibrary.tech.lef`
  - `lef/NangateOpenCellLibrary.macro.mod.lef`

## Tool Paths
- Verilator: `verilator`
- Yosys: `yosys`
- OpenROAD: `openroad`

## RTL Elaboration & Simulation (Verilator)
```bash
verilator \
  --binary --timing -Wno-fatal \
  --top-module id_decode_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/cva6_accel_first_pass_decoder_stub.sv \
  code/cvxif_compressed_if_driver.sv \
  code/compressed_decoder.sv \
  code/macro_decoder.sv \
  code/zcmt_decoder.sv \
  code/decoder.sv \
  code/id_stage.sv \
  flow/id_decode_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top id_decode_top -Iinclude -DSYNTHESIS \
    code/config_pkg.sv \
    code/cv64a60ax_config_pkg.sv \
    code/riscv_pkg.sv \
    code/ariane_pkg.sv \
    code/cva6_accel_first_pass_decoder_stub.sv \
    code/cvxif_compressed_if_driver.sv \
    code/compressed_decoder.sv \
    code/macro_decoder.sv \
    code/zcmt_decoder.sv \
    code/decoder.sv \
    code/id_stage.sv \
    flow/id_decode_top.sv;
  hierarchy -check -top id_decode_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top id_decode_top -flatten;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 1000;
  clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -noexpr -nohex -nodec netlist.v
"
```

## Static Timing Analysis (OpenROAD)
With `design.sdc`:
```tcl
create_clock -name core_clk -period 1.95 [get_ports clk_i]
set_input_delay 0.15 -clock core_clk [all_inputs]
set_output_delay 0.15 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_ni]
```
Run OpenROAD:
```tcl
read_lef lef/NangateOpenCellLibrary.tech.lef
read_lef lef/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist.v
link_design id_decode_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `id_decode_top`: `<= 2560.0 um^2`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/macro_decoder.sv (Buggy Starter)
+++ b/solution/gold/code/macro_decoder.sv (Golden Reference)
@@ -1,280 +1,169 @@
 // Copyright 2018 ETH Zurich and University of Bologna.
-// Copyright and related rights are licensed under the Solderpad Hardware
-// License, Version 0.51 (the "License"); you may not use this file except in
-// compliance with the License.  You may obtain a copy of the License at
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
-// or agreed to in writing, software, hardware and materials distributed under
-// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
-// CONDITIONS OF ANY KIND, either express or implied. See the License for the
-// specific language governing permissions and limitations under the License.
-//
-// Author: Rohan Arshid, 10xEngineers
-// Date: 22.01.2024
-// Description: Contains the logic for decoding cm.push, cm.pop, cm.popret, 
-//              cm.popretz, cm.mvsa01, and cm.mva01s instructions of the 
-//              Zcmp Extension
+// Licensed under the Solderpad Hardware License, Version 0.51.
 
 module macro_decoder #(
     parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
 ) (
     input  logic [31:0] instr_i,
-    input  logic        clk_i,                      // Clock
-    input  logic        rst_ni,                     // Synchronous reset
-    input  logic        is_macro_instr_i,           // Instruction is of macro extension
-    input  logic        illegal_instr_i,            // From compressed decoder
+    input  logic        clk_i,
+    input  logic        rst_ni,
+    input  logic        is_macro_instr_i,
+    input  logic        illegal_instr_i,
     input  logic        is_compressed_i,
-    input  logic        issue_ack_i,                // Check if the instruction is acknowledged
+    input  logic        issue_ack_i,
     output logic [31:0] instr_o,
     output logic        illegal_instr_o,
     output logic        is_compressed_o,
-    output logic        fetch_stall_o,              // Wait while push/pop/move instructions expand
+    output logic        fetch_stall_o,
     output logic        is_last_macro_instr_o,
     output logic        is_double_rd_macro_instr_o
 );
 
-  // FSM States
-  enum logic [2:0] {
+  typedef enum logic [2:0] {
     IDLE,
     INIT,
     PUSH_ADDI,
     POPRETZ_1,
     MOVE,
     PUSH_POP_INSTR_2
-  }
-      state_d, state_q;
-
-  // Instruction Types
-  enum logic [2:0] {
+  } state_e;
+
+  typedef enum logic [2:0] {
     PUSH,
     POP,
     POPRETZ,
     POPRET,
     MVA01S,
     MVSA01
-  } macro_instr_type;
-
-  // Temporary registers
-  logic [3:0] reg_numbers, reg_numbers_q, reg_numbers_d;
-  logic [11:0] stack_adj;
-  logic [4:0] xreg1, xreg2, store_reg, store_reg_q, store_reg_d;
-  logic [1:0] popretz_inst_q, popretz_inst_d;
-  logic [11:0] offset_reg, offset_q, offset_d;
+  } macro_type_e;
+
+  state_e      state_d, state_q;
+  macro_type_e macro_instr_type, macro_type_d, macro_type_q;
+
+  logic [ 3:0] reg_numbers, reg_numbers_m1, reg_numbers_q, reg_numbers_d;
+  logic [ 4:0] xreg1, xreg2, xreg2_d, xreg2_q;
+  logic [ 4:0] store_reg, store_reg_init_next, store_reg_q, store_reg_d;
+  logic [ 1:0] popretz_inst_q, popretz_inst_d;
+  logic [11:0] stack_adj, push_sp_imm, sp_imm_d, sp_imm_q;
+  logic [11:0] pop_off_first, pop_off_second;
+  logic [11:0] offset_q, offset_d;
   logic [31:0] instr_o_reg;
 
-  riscv::itype_t itype_inst;
   assign instr_o = instr_o_reg;
+
   always_comb begin
     illegal_instr_o            = 1'b0;
     fetch_stall_o              = 1'b0;
     is_last_macro_instr_o      = 1'b0;
     is_double_rd_macro_instr_o = 1'b0;
     is_compressed_o            = is_macro_instr_i ? 1'b1 : is_compressed_i;
+    macro_instr_type           = PUSH;
     reg_numbers                = '0;
+    reg_numbers_m1             = '0;
+    xreg1                      = '0;
+    xreg2                      = '0;
+    store_reg                  = '0;
+    store_reg_init_next        = '0;
     stack_adj                  = '0;
+    push_sp_imm                = '0;
+    pop_off_first              = '0;
+    sp_imm_d                   = sp_imm_q;
+    pop_off_second             = '0;
+    instr_o_reg                = instr_i;
+
     state_d                    = state_q;
+    macro_type_d               = macro_type_q;
+    xreg2_d                    = xreg2_q;
     offset_d                   = offset_q;
     reg_numbers_d              = reg_numbers_q;
     store_reg_d                = store_reg_q;
     popretz_inst_d             = popretz_inst_q;
 
     if (is_macro_instr_i) begin
-
       unique case (instr_i[12:10])
-        // push or pop
         3'b110: begin
-          if (instr_i[7:4] < 4'b0100) begin
-            illegal_instr_o = 1'b1;
-            instr_o_reg     = instr_i;
-          end
-
+          if (instr_i[7:4] < 4'b0100) illegal_instr_o = 1'b1;
           unique case (instr_i[9:8])
-            2'b00: begin
-              macro_instr_type = PUSH;
-            end
-            2'b10: begin
-              macro_instr_type = POP;
-            end
-            default: begin
-              illegal_instr_o = 1'b1;
-              instr_o_reg     = instr_i;
-            end
-          endcase
-        end
-        // popret or popretz
+            2'b00: macro_instr_type = PUSH;
+            2'b10: macro_instr_type = POP;
+            default: illegal_instr_o = 1'b1;
+          endcase
+        end
         3'b111: begin
-          if (instr_i[7:4] < 4'b0100) begin
-            illegal_instr_o = 1'b1;
-            instr_o_reg     = instr_i;
-          end
-
+          if (instr_i[7:4] < 4'b0100) illegal_instr_o = 1'b1;
           unique case (instr_i[9:8])
-            2'b00: begin
-              macro_instr_type = POPRETZ;
-            end
-            2'b10: begin
-              macro_instr_type = POPRET;
-            end
-            default: begin
-              illegal_instr_o = 1'b1;
-              instr_o_reg     = instr_i;
-            end
-          endcase
-        end
-        // mvq01s or mvsa01
+            2'b00: macro_instr_type = POPRETZ;
+            2'b10: macro_instr_type = POPRET;
+            default: illegal_instr_o = 1'b1;
+          endcase
+        end
         3'b011: begin
           unique case (instr_i[6:5])
             2'b01: begin
               macro_instr_type = MVSA01;
-            end
-            2'b11: begin
-              macro_instr_type = MVA01S;
-            end
-            default: begin
-              illegal_instr_o = 1'b1;
-              instr_o_reg     = instr_i;
-            end
-          endcase
-        end
-        default: begin
-          illegal_instr_o = 1'b1;
-          instr_o_reg     = instr_i;
-        end
+              if (instr_i[9:7] == instr_i[4:2]) illegal_instr_o = 1'b1;
+            end
+            2'b11: macro_instr_type = MVA01S;
+            default: illegal_instr_o = 1'b1;
+          endcase
+        end
+        default: illegal_instr_o = 1'b1;
       endcase
 
-      // Calculate xreg1 & xreg2 for move instructions
-      if (macro_instr_type == MVSA01 || macro_instr_type == MVA01S) begin
-        if (macro_instr_type == MVA01S || instr_i[9:7] != instr_i[4:2]) begin
-          xreg1 = {instr_i[9:8] > 0, instr_i[9:8] == 0, instr_i[9:7]};
-          xreg2 = {instr_i[4:3] > 0, instr_i[4:3] == 0, instr_i[4:2]};
-        end else begin
-          illegal_instr_o = 1'b1;
-          instr_o_reg     = instr_i;
-        end
-      end else begin
-        xreg1 = '0;
-        xreg2 = '0;
-      end
-
-      // push/pop/popret/popretz instructions
+      xreg1 = {|instr_i[9:8], ~|instr_i[9:8], instr_i[9:7]};
+      xreg2 = {|instr_i[4:3], ~|instr_i[4:3], instr_i[4:2]};
+
       unique case (instr_i[7:4])
-        4'b0100: reg_numbers = 4'b0001;  // 4
-        4'b0101: reg_numbers = 4'b0010;  // 5
-        4'b0110: reg_numbers = 4'b0011;  // 6
-        4'b0111: reg_numbers = 4'b0100;  // 7
-        4'b1000: reg_numbers = 4'b0101;  // 8
-        4'b1001: reg_numbers = 4'b0110;  // 9
-        4'b1010: reg_numbers = 4'b0111;  // 10
-        4'b1011: reg_numbers = 4'b1000;  // 11
-        4'b1100: reg_numbers = 4'b1001;  // 12
-        4'b1101: reg_numbers = 4'b1010;  // 13
-        4'b1110: reg_numbers = 4'b1011;  // 14
-        4'b1111: reg_numbers = 4'b1100;  // 15
-        default: reg_numbers = '0;
+        4'b0100: begin reg_numbers = 4'd1;  reg_numbers_m1 = 4'd0;  store_reg = 5'd1;  store_reg_init_next = 5'd1;  end
+        4'b0101: begin reg_numbers = 4'd2;  reg_numbers_m1 = 4'd1;  store_reg = 5'd8;  store_reg_init_next = 5'd1;  end
+        4'b0110: begin reg_numbers = 4'd3;  reg_numbers_m1 = 4'd2;  store_reg = 5'd9;  store_reg_init_next = 5'd8;  end
+        4'b0111: begin reg_numbers = 4'd4;  reg_numbers_m1 = 4'd3;  store_reg = 5'd18; store_reg_init_next = 5'd17; end
+        4'b1000: begin reg_numbers = 4'd5;  reg_numbers_m1 = 4'd4;  store_reg = 5'd19; store_reg_init_next = 5'd18; end
+        4'b1001: begin reg_numbers = 4'd6;  reg_numbers_m1 = 4'd5;  store_reg = 5'd20; store_reg_init_next = 5'd19; end
+        4'b1010: begin reg_numbers = 4'd7;  reg_numbers_m1 = 4'd6;  store_reg = 5'd21; store_reg_init_next = 5'd20; end
+        4'b1011: begin reg_numbers = 4'd8;  reg_numbers_m1 = 4'd7;  store_reg = 5'd22; store_reg_init_next = 5'd21; end
+        4'b1100: begin reg_numbers = 4'd9;  reg_numbers_m1 = 4'd8;  store_reg = 5'd23; store_reg_init_next = 5'd22; end
+        4'b1101: begin reg_numbers = 4'd10; reg_numbers_m1 = 4'd9;  store_reg = 5'd24; store_reg_init_next = 5'd23; end
+        4'b1110: begin reg_numbers = 4'd11; reg_numbers_m1 = 4'd10; store_reg = 5'd25; store_reg_init_next = 5'd24; end
+        4'b1111: begin reg_numbers = 4'd12; reg_numbers_m1 = 4'd11; store_reg = 5'd27; store_reg_init_next = 5'd26; end
+        default: begin reg_numbers = 4'd0;  reg_numbers_m1 = 4'd0;  store_reg = 5'd0;  store_reg_init_next = 5'd0;  end
       endcase
 
-      if (CVA6Cfg.IS_XLEN32) begin
-        unique case (instr_i[7:4])
-          4'b0100, 4'b0101, 4'b0110, 4'b0111: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 16;
-              2'b01: stack_adj = 32;
-              2'b10: stack_adj = 48;
-              2'b11: stack_adj = 64;
-            endcase
-          end
-          4'b1000, 4'b1001, 4'b1010, 4'b1011: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 32;
-              2'b01: stack_adj = 48;
-              2'b10: stack_adj = 64;
-              2'b11: stack_adj = 80;
-            endcase
-          end
-          4'b1100, 4'b1101, 4'b1110: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 48;
-              2'b01: stack_adj = 64;
-              2'b10: stack_adj = 80;
-              2'b11: stack_adj = 96;
-            endcase
-          end
-          4'b1111: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 64;
-              2'b01: stack_adj = 80;
-              2'b10: stack_adj = 96;
-              2'b11: stack_adj = 112;
-            endcase
-          end
-          default: ;
-        endcase
-      end else begin
-        unique case (instr_i[7:4])
-          4'b0100, 4'b0101: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 16;
-              2'b01: stack_adj = 32;
-              2'b10: stack_adj = 48;
-              2'b11: stack_adj = 64;
-            endcase
-          end
-          4'b0110, 4'b0111: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 32;
-              2'b01: stack_adj = 48;
-              2'b10: stack_adj = 64;
-              2'b11: stack_adj = 80;
-            endcase
-          end
-          4'b1000, 4'b1001: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 48;
-              2'b01: stack_adj = 64;
-              2'b10: stack_adj = 80;
-              2'b11: stack_adj = 96;
-            endcase
-          end
-          4'b1010, 4'b1011: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 64;
-              2'b01: stack_adj = 80;
-              2'b10: stack_adj = 96;
-              2'b11: stack_adj = 112;
-            endcase
-          end
-          4'b1100, 4'b1101: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 80;
-              2'b01: stack_adj = 96;
-              2'b10: stack_adj = 112;
-              2'b11: stack_adj = 128;
-            endcase
-          end
-          4'b1110: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 96;
-              2'b01: stack_adj = 112;
-              2'b10: stack_adj = 128;
-              2'b11: stack_adj = 144;
-            endcase
-          end
-          4'b1111: begin
-            unique case (instr_i[3:2])
-              2'b00: stack_adj = 112;
-              2'b01: stack_adj = 128;
-              2'b10: stack_adj = 144;
-              2'b11: stack_adj = 160;
-            endcase
-          end
-        endcase
-      end
-
-      //Take 2's compliment in case of PUSH instruction
-      if (macro_instr_type == PUSH) begin
-        itype_inst.imm = ~stack_adj + 1'b1;
-      end else begin
-        itype_inst.imm = stack_adj - 12'h4;
-      end
+      unique case (instr_i[7:4])
+        4'b0100, 4'b0101, 4'b0110, 4'b0111: begin
+          unique case (instr_i[3:2])
+            2'b00: begin stack_adj = 12'd16;  push_sp_imm = 12'hFF0; pop_off_first = 12'd12;  pop_off_second = 12'd8;   end
+            2'b01: begin stack_adj = 12'd32;  push_sp_imm = 12'hFE0; pop_off_first = 12'd28;  pop_off_second = 12'd24;  end
+            2'b10: begin stack_adj = 12'd48;  push_sp_imm = 12'hFD0; pop_off_first = 12'd44;  pop_off_second = 12'd40;  end
+            2'b11: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
+          endcase
+        end
+        4'b1000, 4'b1001, 4'b1010, 4'b1011: begin
+          unique case (instr_i[3:2])
+            2'b00: begin stack_adj = 12'd32;  push_sp_imm = 12'hFE0; pop_off_first = 12'd28;  pop_off_second = 12'd24;  end
+            2'b01: begin stack_adj = 12'd48;  push_sp_imm = 12'hFD0; pop_off_first = 12'd44;  pop_off_second = 12'd40;  end
+            2'b10: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
+            2'b11: begin stack_adj = 12'd80;  push_sp_imm = 12'hFB0; pop_off_first = 12'd76;  pop_off_second = 12'd72;  end
+          endcase
+        end
+        4'b1100, 4'b1101, 4'b1110: begin
+          unique case (instr_i[3:2])
+            2'b00: begin stack_adj = 12'd48;  push_sp_imm = 12'hFD0; pop_off_first = 12'd44;  pop_off_second = 12'd40;  end
+            2'b01: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
+            2'b10: begin stack_adj = 12'd80;  push_sp_imm = 12'hFB0; pop_off_first = 12'd76;  pop_off_second = 12'd72;  end
+            2'b11: begin stack_adj = 12'd96;  push_sp_imm = 12'hFA0; pop_off_first = 12'd92;  pop_off_second = 12'd88;  end
+          endcase
+        end
+        4'b1111: begin
+          unique case (instr_i[3:2])
+            2'b00: begin stack_adj = 12'd64;  push_sp_imm = 12'hFC0; pop_off_first = 12'd60;  pop_off_second = 12'd56;  end
+            2'b01: begin stack_adj = 12'd80;  push_sp_imm = 12'hFB0; pop_off_first = 12'd76;  pop_off_second = 12'd72;  end
+            2'b10: begin stack_adj = 12'd96;  push_sp_imm = 12'hFA0; pop_off_first = 12'd92;  pop_off_second = 12'd88;  end
+            2'b11: begin stack_adj = 12'd112; push_sp_imm = 12'hF90; pop_off_first = 12'd108; pop_off_second = 12'd104; end
+          endcase
+        end
+        default: ;
+      endcase
     end else begin
       illegal_instr_o = illegal_instr_i;
       instr_o_reg     = instr_i;
@@ -283,331 +172,141 @@
     unique case (state_q)
       IDLE: begin
         if (is_macro_instr_i && !illegal_instr_o) begin
-          reg_numbers_d = reg_numbers - 1'b1;
-          state_d = issue_ack_i ? INIT : IDLE;
-          case (macro_instr_type)
+          macro_type_d  = macro_instr_type;
+          xreg2_d       = xreg2;
+          reg_numbers_d = reg_numbers_m1;
+          store_reg_d   = store_reg_init_next;
+          fetch_stall_o = 1'b1;
+
+          unique case (macro_instr_type)
+            MVSA01: begin
+              is_double_rd_macro_instr_o = 1'b1;
+              instr_o_reg = {12'h0, 5'hA, 3'h0, xreg1, riscv::OpcodeOpImm};
+              if (issue_ack_i) state_d = MOVE;
+            end
+            MVA01S: begin
+              is_double_rd_macro_instr_o = 1'b1;
+              instr_o_reg = {12'h0, xreg1, 3'h0, 5'hA, riscv::OpcodeOpImm};
+              if (issue_ack_i) state_d = MOVE;
+            end
             PUSH: begin
-              offset_d = 12'hFFC + 12'hFFC;
-            end
-            POP, POPRETZ, POPRET: begin
-              offset_d   = itype_inst.imm + 12'hFFC;
-              offset_reg = itype_inst.imm;
-              case (macro_instr_type)
-                POPRETZ: begin
-                  popretz_inst_d = 2'b11;
+              sp_imm_d    = push_sp_imm;
+              offset_d    = 12'hFF8;
+              instr_o_reg = {7'b1111111, store_reg, 5'h2, 3'h2, 5'b11100, riscv::OpcodeStore};
+              if (issue_ack_i) begin
+                if (reg_numbers == 4'd1) state_d = PUSH_ADDI;
+                else if (reg_numbers == 4'd12) state_d = PUSH_POP_INSTR_2;
+                else state_d = INIT;
+              end
+            end
+            POP, POPRET, POPRETZ: begin
+              sp_imm_d       = stack_adj;
+              offset_d       = pop_off_second;
+              popretz_inst_d = (macro_instr_type == POPRETZ) ? 2'b11 :
+                               (macro_instr_type == POPRET)  ? 2'b01 : 2'b00;
+              instr_o_reg    = {pop_off_first, 5'h2, 3'h2, store_reg, riscv::OpcodeLoad};
+              if (issue_ack_i) begin
+                if (reg_numbers == 4'd1) begin
+                  state_d = (macro_instr_type == POPRETZ) ? POPRETZ_1 : PUSH_ADDI;
+                end else if (reg_numbers == 4'd12) begin
+                  state_d = PUSH_POP_INSTR_2;
+                end else begin
+                  state_d = INIT;
                 end
-                POPRET: begin
-                  popretz_inst_d = 2'b01;
-                end
-                default: begin
-                  popretz_inst_d = 'b0;
-                end
-              endcase
+              end
             end
             default: ;
           endcase
-          // when rlist is 4, max reg is x18 i.e. 14(const) + 4
-          // when rlist is 12, max reg is x27 i.e. 15(const) + 12 
-          if (reg_numbers == 4'b1100) begin
-            store_reg_d = 4'b1110 + reg_numbers;
-            store_reg   = 4'b1111 + reg_numbers;
+        end
+      end
+
+      INIT: begin
+        fetch_stall_o = is_macro_instr_i;
+        if (is_macro_instr_i) begin
+          logic [4:0] cur_reg;
+          unique case (reg_numbers_q)
+            4'd1:    cur_reg = 5'h1;
+            4'd2:    cur_reg = 5'h8;
+            4'd3:    cur_reg = 5'h9;
+            default: cur_reg = store_reg_q;
+          endcase
+          if (macro_type_q == PUSH) begin
+            instr_o_reg = {offset_q[11:5], cur_reg, 5'h2, 3'h2, offset_q[4:0], riscv::OpcodeStore};
           end else begin
-            store_reg_d = 4'b1101 + reg_numbers;
-            store_reg   = 4'b1110 + reg_numbers;
-          end
-
-          if (macro_instr_type == MVSA01) begin
-            fetch_stall_o = 1;
-            is_double_rd_macro_instr_o = 1;
-            // addi xreg1, a0, 0
-            instr_o_reg = {12'h0, 5'hA, 3'h0, xreg1, riscv::OpcodeOpImm};
+            instr_o_reg = {offset_q[11:0], 5'h2, 3'h2, cur_reg, riscv::OpcodeLoad};
+          end
+          if (issue_ack_i) begin
+            if (reg_numbers_q == 4'd1) begin
+              state_d = (macro_type_q == POPRETZ) ? POPRETZ_1 : PUSH_ADDI;
+            end else begin
+              reg_numbers_d = reg_numbers_q - 4'd1;
+              offset_d      = offset_q + 12'hFFC;
+              if (reg_numbers_q >= 4'd4) store_reg_d = store_reg_q - 5'd1;
+            end
+          end
+        end
+      end
+
+      MOVE: begin
+        is_last_macro_instr_o      = 1'b1;
+        is_double_rd_macro_instr_o = 1'b1;
+        fetch_stall_o              = ~issue_ack_i;
+        if (macro_type_q == MVSA01) begin
+          instr_o_reg = {12'h0, 5'hB, 3'h0, xreg2_q, riscv::OpcodeOpImm};
+        end else begin
+          instr_o_reg = {12'h0, xreg2_q, 3'h0, 5'hB, riscv::OpcodeOpImm};
+        end
+        if (issue_ack_i) state_d = IDLE;
+      end
+
+      PUSH_ADDI: begin
+        instr_o_reg = {sp_imm_q, 5'h2, 3'h0, 5'h2, riscv::OpcodeOpImm};
+        if (macro_type_q == POPRETZ || macro_type_q == POPRET) begin
+          fetch_stall_o = 1'b1;
+          if (issue_ack_i) state_d = POPRETZ_1;
+        end else begin
+          is_last_macro_instr_o = 1'b1;
+          fetch_stall_o         = ~issue_ack_i;
+          if (issue_ack_i) state_d = IDLE;
+        end
+      end
+
+      PUSH_POP_INSTR_2: begin
+        fetch_stall_o = 1'b1;
+        if (macro_type_q == PUSH) begin
+          instr_o_reg = {offset_q[11:5], store_reg_q, 5'h2, 3'h2, offset_q[4:0], riscv::OpcodeStore};
+        end else begin
+          instr_o_reg = {offset_q[11:0], 5'h2, 3'h2, store_reg_q, riscv::OpcodeLoad};
+        end
+        if (issue_ack_i) begin
+          offset_d    = offset_q + 12'hFFC;
+          store_reg_d = store_reg_q - 5'd1;
+          state_d     = INIT;
+        end
+      end
+
+      POPRETZ_1: begin
+        unique case (popretz_inst_q)
+          2'b11: begin
+            instr_o_reg   = {20'h0, 5'hA, riscv::OpcodeLui};
+            fetch_stall_o = 1'b1;
+            if (issue_ack_i) popretz_inst_d = 2'b10;
+          end
+          2'b10: begin
+            instr_o_reg   = {12'h0, 5'hA, 3'h0, 5'hA, riscv::OpcodeOpImm};
+            fetch_stall_o = 1'b1;
             if (issue_ack_i) begin
-              state_d = MOVE;
-            end
-          end
-
-          if (macro_instr_type == MVA01S) begin
-            fetch_stall_o = 1;
-            is_double_rd_macro_instr_o = 1;
-            // addi a0, xreg1, 0
-            instr_o_reg = {12'h0, xreg1, 3'h0, 5'hA, riscv::OpcodeOpImm};
+              popretz_inst_d = 2'b01;
+              state_d        = PUSH_ADDI;
+            end
+          end
+          2'b01: begin
+            instr_o_reg           = {12'h0, 5'h1, 3'h0, 5'h0, riscv::OpcodeJalr};
+            is_last_macro_instr_o = 1'b1;
+            fetch_stall_o         = ~issue_ack_i;
             if (issue_ack_i) begin
-              state_d = MOVE;
-            end
-          end
-
-          if (macro_instr_type == PUSH) begin
-
-            fetch_stall_o = 1'b1;  // stall inst fetch
-
-            if (reg_numbers == 4'b0001) begin
-              if (CVA6Cfg.IS_XLEN64) begin
-                instr_o_reg = {
-                  7'b1111111, 5'h1, 5'h2, 3'h3, 5'b11000, riscv::OpcodeStore
-                };  // sd store_reg, -4(sp)
-              end else begin
-                instr_o_reg = {
-                  7'b1111111, 5'h1, 5'h2, 3'h2, 5'b11100, riscv::OpcodeStore
-                };  // sw store_reg, -4(sp)
-              end
-              if (issue_ack_i) begin
-                state_d = PUSH_ADDI;
-              end
-            end
-
-            if (reg_numbers == 4'b0010) begin
-              if (CVA6Cfg.IS_XLEN64) begin
-                instr_o_reg = {7'b1111111, 5'h8, 5'h2, 3'h3, 5'b11000, riscv::OpcodeStore};
-              end else begin
-                instr_o_reg = {7'b1111111, 5'h8, 5'h2, 3'h2, 5'b11100, riscv::OpcodeStore};
-              end
-            end
-
-            if (reg_numbers == 4'b0011) begin
-              if (CVA6Cfg.IS_XLEN64) begin
-                instr_o_reg = {7'b1111111, 5'h9, 5'h2, 3'h3, 5'b11000, riscv::OpcodeStore};
-              end else begin
-                instr_o_reg = {7'b1111111, 5'h9, 5'h2, 3'h2, 5'b11100, riscv::OpcodeStore};
-              end
-
-            end
-
-            if (reg_numbers >= 4 && reg_numbers <= 12) begin
-              if (CVA6Cfg.IS_XLEN64) begin
-                instr_o_reg = {7'b1111111, store_reg, 5'h2, 3'h3, 5'b11000, riscv::OpcodeStore};
-              end else begin
-                instr_o_reg = {7'b1111111, store_reg, 5'h2, 3'h2, 5'b11100, riscv::OpcodeStore};
-              end
-
-              if (reg_numbers == 12 && issue_ack_i) begin
-                state_d = PUSH_POP_INSTR_2;
-              end
-            end
-          end
-
-          if ((macro_instr_type == POP || macro_instr_type == POPRETZ || macro_instr_type == POPRET)) begin
-            fetch_stall_o = 1;  // stall inst fetch
-            if (reg_numbers == 1) begin
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/compressed_decoder.sv`](environment/public/code/compressed_decoder.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a60ax_config_pkg.sv`](environment/public/code/cv64a60ax_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cva6_accel_first_pass_decoder_stub.sv`](environment/public/code/cva6_accel_first_pass_decoder_stub.sv) *(Read-Only Context)*
- [`environment/public/code/cvxif_compressed_if_driver.sv`](environment/public/code/cvxif_compressed_if_driver.sv) *(Read-Only Context)*
- [`environment/public/code/decoder.sv`](environment/public/code/decoder.sv) *(Read-Only Context)*
- [`environment/public/code/id_stage.sv`](environment/public/code/id_stage.sv) **(Editable)**
- [`environment/public/code/macro_decoder.sv`](environment/public/code/macro_decoder.sv) **(Editable)**
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/zcmt_decoder.sv`](environment/public/code/zcmt_decoder.sv) **(Editable)**
- [`environment/public/flow/id_decode_top.sv`](environment/public/flow/id_decode_top.sv) *(Read-Only Context)*
- [`environment/public/include/common_cells/LICENSE.Apache-2.0`](environment/public/include/common_cells/LICENSE.Apache-2.0) *(Read-Only Context)*
- [`environment/public/include/common_cells/assertions.svh`](environment/public/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lef/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.tech.lef`](environment/public/lef/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/LICENSE_NANGATE`](environment/public/lib/LICENSE_NANGATE) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

