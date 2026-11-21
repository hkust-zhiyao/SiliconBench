# `case_20001`: Harden biRISC-V Dual-Issue Scoreboard Qualification, Post-LSU Slot-1 Serialization, and Fault/Interrupt Isolation

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_20001` |
| **Source Silicon Repository** | `ultraembedded/biriscv` (`repo_44`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `Core_RISCV_Processors` (Core_RISCV_Processors) |
| **Multi-Domain Tags** | `Core_RISCV_Processors` |
| **Editable Files (`allowed_edits`)** | [`code/biriscv_issue.v`](environment/public/code/biriscv_issue.v) (1 files, 1065 LOC) |
| **Public Subsystem Context** | 9 RTL files (3876 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Dual-Issue Dispatch, Scoreboard Qualification, and Exception/Redirect Isolation in `biriscv_issue`

`code/biriscv_issue.v` implements dual-issue instruction dispatch, register hazard scoreboarding, multi-stage operand forwarding, and branch-predictor feedback for the 32-bit superscalar `biRISC-V` processor core.

During verification of mixed dual-issue instruction streams combined with memory stalls, fetch/page faults, interrupts, and frontend bubbles, several dispatch and hazard-tracking defects were observed. Update `code/biriscv_issue.v` while preserving its module port interface and parameters (`SUPPORT_MULDIV`, `SUPPORT_DUAL_ISSUE`, `SUPPORT_LOAD_BYPASS`, `SUPPORT_MUL_BYPASS`, `SUPPORT_REGFILE_XILINX`) so that all of the following architectural requirements hold:

1. **Register Scoreboard Qualification & `x0` Immunity**:
   - Architectural register `x0` (`5'd0`) must never be marked busy in the scoreboard or stall subsequent instructions, including when an in-flight E1/E2 load or multiply has destination `x0` under both `SUPPORT_LOAD_BYPASS = 1/0` and `SUPPORT_MUL_BYPASS = 1/0`.
   - WAW hazard checks on instruction bits `[11:7]` must only block dispatch when the candidate instruction genuinely writes a non-zero destination register (`rd_valid` asserted, no fetch/page fault, and not marked invalid).
   - RAW hazard checks on `rs1` (`[19:15]`) and `rs2` (`[24:20]`) must only block dispatch when the RV32IM/Zicsr encoding actually reads that source operand (`LUI`, `AUIPC`, `JAL`, `FENCE`, `FENCE.I`, immediate CSR ops `CSRRWI`/`CSRRSI`/`CSRRCI`, and system instructions `ECALL`/`EBREAK`/`ERET`/`WFI` do not read `rs1`; only R-type ALU/mul/div instructions, stores `SB`/`SH`/`SW`, conditional branches, and `SFENCE.VMA` read `rs2`; instructions carrying fetch/page faults or marked invalid must not stall on register indices).
   - Cross-slot RAW and WAW dependencies from Slot 0 to Slot 1 in the same cycle must continue to serialize Slot 1 cleanly.

2. **Dual-Issue Legality & Post-LSU Serialization Across Both Slots**:
   - Preserve legal dual-issue concurrency (`ALU`/`LSU`/`MUL` paired with `ALU`/`BRANCH`, `ALU`/`MUL` paired with `LSU`, `ALU`/`LSU` paired with `MUL`) when `SUPPORT_DUAL_ISSUE = 1`.
   - Enforce the post-LSU single-cycle exclusion rule across **both** issue slots: in the cycle immediately following an active E1 load or store (in either pipe), `MUL`, `DIV`, `CSR`, and fetch-faulting operations must not dispatch in Slot 0 **or** Slot 1. In particular, if Slot 0 holds an eligible ALU/branch instruction and Slot 1 holds a `MUL` while an older load/store is in E1, Slot 0 must still be allowed to single-issue while Slot 1 is held back.
   - Never dual-issue Slot 1 when either Slot 0 or Slot 1 carries a fetch fault, instruction page fault, or invalid-instruction indication; furthermore, after a fetch-faulting instruction dispatches into Pipe 0, hold subsequent instructions from dispatching until the fault squashes/flushes the pipeline.

3. **Functional-Unit Valid Strobes & Interrupt/Fault Side-Effect Suppression**:
   - Assert each execution-unit valid output (`exec0_opcode_valid_o`, `exec1_opcode_valid_o`, `lsu_opcode_valid_o`, `mul_opcode_valid_o`, `div_opcode_valid_o`, `csr_opcode_valid_o`) **only** when the corresponding slot actually dispatches an operation belonging to that unit (`exec` or `branch` for `exec0`/`exec1`; `lsu` for `lsu`; `mul` for `mul`; `div` for `div`; `csr` or invalid instruction without fetch/page fault for `csr`).
   - Suppress all functional-unit valid outputs (and prevent spurious multi-cycle `div`/`csr` pending lockups) whenever `take_interrupt_i` is asserted or when the slot carries a fetch/page fault (`fault_fetch` / `fault_page`).
   - Qualify `interrupt_inhibit_o` so that incoming CSR decode flags only inhibit interrupts when the primary issue slot actually holds a valid non-faulting CSR/invalid instruction (or while an issued CSR instruction is still pending in the pipeline), never from idle/unselected fetch inputs.

4. **Misprediction Predictor Feedback (`branch_info_*_o`) Across Fetch Bubbles**:
   - When a branch or jump resolves in E1 (`pipe0` or `pipe1`), if neither `fetch0_valid_i` nor `fetch1_valid_i` is asserted on that cycle, retain the resolved branch metadata (`is_taken`, `is_not_taken`, `is_call`, `is_ret`, `is_jmp`, `source`, `pc`) until the next valid fetch parcel arrives (unless cleared earlier by reset, `branch_csr_request_i`, or a pipeline squash). If that arriving fetch parcel triggers a misprediction redirect (`branch_info_request_o`), drive `branch_info_*_o` with the retained branch attributes; once a valid fetch parcel arrives without misprediction (or after reporting the misprediction), clear the retained state so stale attributes are never replayed on a later branch.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Guide

## Source Files
- **Editable RTL**: `code/biriscv_issue.v`
- **Read-Only Context RTL**: `code/biriscv_defs.v`, `code/biriscv_pipe_ctrl.v`, `code/biriscv_regfile.v`, `code/biriscv_xilinx_2r1w.v`, `code/biriscv_exec.v`, `code/biriscv_alu.v`, `code/biriscv_decoder.v`, `code/biriscv_trace_sim.v`

## Example Compilation & Lint Commands

### Verilator Lint / Elaboration
```bash
verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS -Icode \
  code/biriscv_issue.v code/biriscv_pipe_ctrl.v code/biriscv_regfile.v \
  code/biriscv_xilinx_2r1w.v code/biriscv_trace_sim.v \
  --top-module biriscv_issue
```

### Yosys Structural & Latch Check
```bash
yosys -p "read_verilog -Icode code/biriscv_issue.v code/biriscv_pipe_ctrl.v code/biriscv_regfile.v code/biriscv_xilinx_2r1w.v; hierarchy -check -top biriscv_issue; proc; check -assert"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/biriscv_issue.v (Buggy Starter)
+++ b/solution/gold/code/biriscv_issue.v (Golden Reference)
@@ -304,30 +304,87 @@
     end
 end
 
+function [0:0] opc_uses_ra;
+    input [31:0] opc;
+    input        has_fault;
+    input        is_inv;
+begin
+    if (has_fault || is_inv)
+        opc_uses_ra = 1'b0;
+    else
+    begin
+        case (opc[6:0])
+            7'b0110011,
+            7'b0010011,
+            7'b0000011,
+            7'b0100011,
+            7'b1100011,
+            7'b1100111: opc_uses_ra = 1'b1;
+            7'b1110011: opc_uses_ra = (opc[14:12] == 3'b001) ||
+                                      (opc[14:12] == 3'b010) ||
+                                      (opc[14:12] == 3'b011) ||
+                                      ((opc & `INST_SFENCE_MASK) == `INST_SFENCE);
+            default:    opc_uses_ra = 1'b0;
+        endcase
+    end
+end
+endfunction
+
+function [0:0] opc_uses_rb;
+    input [31:0] opc;
+    input        has_fault;
+    input        is_inv;
+begin
+    if (has_fault || is_inv)
+        opc_uses_rb = 1'b0;
+    else
+    begin
+        case (opc[6:0])
+            7'b0110011,
+            7'b0100011,
+            7'b1100011: opc_uses_rb = 1'b1;
+            7'b1110011: opc_uses_rb = ((opc & `INST_SFENCE_MASK) == `INST_SFENCE);
+            default:    opc_uses_rb = 1'b0;
+        endcase
+    end
+end
+endfunction
+
+wire       issue_a_has_fault_w = |opcode_a_fault_r;
+wire       issue_b_has_fault_w = |opcode_b_fault_r;
+wire       issue_a_raw_inv_w   = opcode_a_valid_r & (slot0_valid_r ? fetch0_instr_invalid_i : fetch1_instr_invalid_i);
+wire       issue_b_raw_inv_w   = opcode_b_valid_r & fetch1_instr_invalid_i;
+wire       issue_a_clean_w     = opcode_a_valid_r & ~issue_a_has_fault_w & ~issue_a_raw_inv_w;
+wire       issue_b_clean_w     = opcode_b_valid_r & ~issue_b_has_fault_w & ~issue_b_raw_inv_w;
+
 wire [4:0] issue_a_ra_idx_w   = opcode_a_r[19:15];
 wire [4:0] issue_a_rb_idx_w   = opcode_a_r[24:20];
 wire [4:0] issue_a_rd_idx_w   = opcode_a_r[11:7];
-wire       issue_a_sb_alloc_w = (slot0_valid_r ? fetch0_instr_rd_valid_i : fetch1_instr_rd_valid_i);
-wire       issue_a_exec_w     = (slot0_valid_r ? fetch0_instr_exec_i     : fetch1_instr_exec_i);
-wire       issue_a_lsu_w      = (slot0_valid_r ? fetch0_instr_lsu_i      : fetch1_instr_lsu_i);
-wire       issue_a_branch_w   = (slot0_valid_r ? fetch0_instr_branch_i   : fetch1_instr_branch_i);
-wire       issue_a_mul_w      = (slot0_valid_r ? fetch0_instr_mul_i      : fetch1_instr_mul_i);
-wire       issue_a_div_w      = (slot0_valid_r ? fetch0_instr_div_i      : fetch1_instr_div_i);
-wire       issue_a_csr_w      = (slot0_valid_r ? fetch0_instr_csr_i      : fetch1_instr_csr_i);
-wire       issue_a_invalid_w  = (slot0_valid_r ? fetch0_instr_invalid_i  : fetch1_instr_invalid_i);
-
+wire       issue_a_sb_alloc_w = issue_a_clean_w & (slot0_valid_r ? fetch0_instr_rd_valid_i : fetch1_instr_rd_valid_i);
+wire       issue_a_exec_w     = issue_a_clean_w & (slot0_valid_r ? fetch0_instr_exec_i     : fetch1_instr_exec_i);
+wire       issue_a_lsu_w      = issue_a_clean_w & (slot0_valid_r ? fetch0_instr_lsu_i      : fetch1_instr_lsu_i);
+wire       issue_a_branch_w   = issue_a_clean_w & (slot0_valid_r ? fetch0_instr_branch_i   : fetch1_instr_branch_i);
+wire       issue_a_mul_w      = issue_a_clean_w & (slot0_valid_r ? fetch0_instr_mul_i      : fetch1_instr_mul_i);
+wire       issue_a_div_w      = issue_a_clean_w & (slot0_valid_r ? fetch0_instr_div_i      : fetch1_instr_div_i);
+wire       issue_a_csr_raw_w  = opcode_a_valid_r & (slot0_valid_r ? fetch0_instr_csr_i     : fetch1_instr_csr_i);
+wire       issue_a_csr_w      = opcode_a_valid_r & ~issue_a_has_fault_w & (issue_a_csr_raw_w | issue_a_raw_inv_w);
+wire       issue_a_invalid_w  = opcode_a_valid_r & ~issue_a_has_fault_w & issue_a_raw_inv_w;
+wire       issue_a_uses_ra_w  = opc_uses_ra(opcode_a_r, issue_a_has_fault_w, issue_a_raw_inv_w);
+wire       issue_a_uses_rb_w  = opc_uses_rb(opcode_a_r, issue_a_has_fault_w, issue_a_raw_inv_w);
 
 wire [4:0] issue_b_ra_idx_w   = opcode_b_r[19:15];
 wire [4:0] issue_b_rb_idx_w   = opcode_b_r[24:20];
 wire [4:0] issue_b_rd_idx_w   = opcode_b_r[11:7];
-wire       issue_b_sb_alloc_w = fetch1_instr_rd_valid_i;
-wire       issue_b_exec_w     = fetch1_instr_exec_i;
-wire       issue_b_lsu_w      = fetch1_instr_lsu_i;
-wire       issue_b_branch_w   = fetch1_instr_branch_i;
-wire       issue_b_mul_w      = fetch1_instr_mul_i;
-wire       issue_b_div_w      = fetch1_instr_div_i;
-wire       issue_b_csr_w      = fetch1_instr_csr_i;
-wire       issue_b_invalid_w  = fetch1_instr_invalid_i;
+wire       issue_b_sb_alloc_w = issue_b_clean_w & fetch1_instr_rd_valid_i;
+wire       issue_b_exec_w     = issue_b_clean_w & fetch1_instr_exec_i;
+wire       issue_b_lsu_w      = issue_b_clean_w & fetch1_instr_lsu_i;
+wire       issue_b_branch_w   = issue_b_clean_w & fetch1_instr_branch_i;
+wire       issue_b_mul_w      = issue_b_clean_w & fetch1_instr_mul_i;
+wire       issue_b_div_w      = issue_b_clean_w & fetch1_instr_div_i;
+wire       issue_b_csr_w      = opcode_b_valid_r & ~issue_b_has_fault_w & (fetch1_instr_csr_i | issue_b_raw_inv_w);
+wire       issue_b_invalid_w  = opcode_b_valid_r & ~issue_b_has_fault_w & issue_b_raw_inv_w;
+wire       issue_b_uses_ra_w  = opc_uses_ra(opcode_b_r, issue_b_has_fault_w, issue_b_raw_inv_w);
+wire       issue_b_uses_rb_w  = opc_uses_rb(opcode_b_r, issue_b_has_fault_w, issue_b_raw_inv_w);
 
 //-------------------------------------------------------------
 // Pipe0 - Status tracking
@@ -581,27 +638,77 @@
 assign csr_writeback_exception_addr_o = (|pipe0_exception_wb_w) ? pipe0_result_wb_w : pipe1_result_wb_w;
 
 //-------------------------------------------------------------
-// Branch predictor info
-//-------------------------------------------------------------
-// This info is used to learn future prediction, and to correct 
-// BTB, BHT, GShare, RAS indexes on mispredictions.
+// Branch predictor info (with fetch-bubble retention)
+//-------------------------------------------------------------
+wire        live_br_p1_w          = pipe1_branch_e1_w & branch_exec1_request_i;
+wire        live_br_p0_w          = pipe0_branch_e1_w & branch_exec0_request_i;
+wire        live_br_any_w         = live_br_p1_w | live_br_p0_w;
+wire        live_br_taken_w       = live_br_p1_w ? branch_exec1_is_taken_i     : branch_exec0_is_taken_i;
+wire        live_br_ntaken_w      = live_br_p1_w ? branch_exec1_is_not_taken_i : branch_exec0_is_not_taken_i;
+wire        live_br_call_w        = live_br_p1_w ? branch_exec1_is_call_i      : branch_exec0_is_call_i;
+wire        live_br_ret_w         = live_br_p1_w ? branch_exec1_is_ret_i       : branch_exec0_is_ret_i;
+wire        live_br_jmp_w         = live_br_p1_w ? branch_exec1_is_jmp_i       : branch_exec0_is_jmp_i;
+wire [31:0] live_br_source_w      = live_br_p1_w ? branch_exec1_source_i       : branch_exec0_source_i;
+wire [31:0] live_br_pc_w          = live_br_p1_w ? branch_exec1_pc_i           : branch_exec0_pc_i;
+
+reg         saved_br_valid_q;
+reg         saved_br_taken_q;
+reg         saved_br_ntaken_q;
+reg         saved_br_call_q;
+reg         saved_br_ret_q;
+reg         saved_br_jmp_q;
+reg  [31:0] saved_br_source_q;
+reg  [31:0] saved_br_pc_q;
+
+always @ (posedge clk_i or posedge rst_i)
+if (rst_i)
+begin
+    saved_br_valid_q  <= 1'b0;
+    saved_br_taken_q  <= 1'b0;
+    saved_br_ntaken_q <= 1'b0;
+    saved_br_call_q   <= 1'b0;
+    saved_br_ret_q    <= 1'b0;
+    saved_br_jmp_q    <= 1'b0;
+    saved_br_source_q <= 32'b0;
+    saved_br_pc_q     <= 32'b0;
+end
+else if (branch_csr_request_i || squash_w)
+begin
+    saved_br_valid_q  <= 1'b0;
+end
+else if (live_br_any_w && ~fetch0_valid_i && ~fetch1_valid_i)
+begin
+    saved_br_valid_q  <= 1'b1;
+    saved_br_taken_q  <= live_br_taken_w;
+    saved_br_ntaken_q <= live_br_ntaken_w;
+    saved_br_call_q   <= live_br_call_w;
+    saved_br_ret_q    <= live_br_ret_w;
+    saved_br_jmp_q    <= live_br_jmp_w;
+    saved_br_source_q <= live_br_source_w;
+    saved_br_pc_q     <= live_br_pc_w;
+end
+else if (fetch0_valid_i || fetch1_valid_i)
+begin
+    saved_br_valid_q  <= 1'b0;
+end
+
+wire use_saved_br_w               = ~live_br_any_w & mispredicted_r & saved_br_valid_q;
 assign branch_info_request_o      = mispredicted_r;
-assign branch_info_is_taken_o     = (pipe1_branch_e1_w & branch_exec1_is_taken_i)     | (pipe0_branch_e1_w & branch_exec0_is_taken_i);
-assign branch_info_is_not_taken_o = (pipe1_branch_e1_w & branch_exec1_is_not_taken_i) | (pipe0_branch_e1_w & branch_exec0_is_not_taken_i);
-assign branch_info_is_call_o      = (pipe1_branch_e1_w & branch_exec1_is_call_i)      | (pipe0_branch_e1_w & branch_exec0_is_call_i);
-assign branch_info_is_ret_o       = (pipe1_branch_e1_w & branch_exec1_is_ret_i)       | (pipe0_branch_e1_w & branch_exec0_is_ret_i);
-assign branch_info_is_jmp_o       = (pipe1_branch_e1_w & branch_exec1_is_jmp_i)       | (pipe0_branch_e1_w & branch_exec0_is_jmp_i);
-assign branch_info_source_o       = (pipe1_branch_e1_w & branch_exec1_request_i)      ? branch_exec1_source_i : branch_exec0_source_i;
-assign branch_info_pc_o           = (pipe1_branch_e1_w & branch_exec1_request_i)      ? branch_exec1_pc_i     : branch_exec0_pc_i;
-
-//-------------------------------------------------------------
-// Blocking events (division, CSR unit access)
+assign branch_info_is_taken_o     = live_br_any_w ? live_br_taken_w  : (use_saved_br_w ? saved_br_taken_q  : 1'b0);
+assign branch_info_is_not_taken_o = live_br_any_w ? live_br_ntaken_w : (use_saved_br_w ? saved_br_ntaken_q : 1'b0);
+assign branch_info_is_call_o      = live_br_any_w ? live_br_call_w   : (use_saved_br_w ? saved_br_call_q   : 1'b0);
+assign branch_info_is_ret_o       = live_br_any_w ? live_br_ret_w    : (use_saved_br_w ? saved_br_ret_q    : 1'b0);
+assign branch_info_is_jmp_o       = live_br_any_w ? live_br_jmp_w    : (use_saved_br_w ? saved_br_jmp_q    : 1'b0);
+assign branch_info_source_o       = live_br_any_w ? live_br_source_w : (use_saved_br_w ? saved_br_source_q : branch_exec0_source_i);
+assign branch_info_pc_o           = live_br_any_w ? live_br_pc_w     : (use_saved_br_w ? saved_br_pc_q     : branch_exec0_pc_i);
+
+//-------------------------------------------------------------
+// Blocking events (division, CSR unit access, fetch fault drain)
 //-------------------------------------------------------------
 reg div_pending_q;
 reg csr_pending_q;
-
-// Division operations take 2 - 34 cycles and stall
-// the pipeline (complete out-of-pipe) until completed.
+reg fault_pending_q;
+
 always @ (posedge clk_i or posedge rst_i)
 if (rst_i)
     div_pending_q <= 1'b0;
@@ -612,8 +719,6 @@
 else if (writeback_div_valid_i)
     div_pending_q <= 1'b0;
 
-// CSR operations are infrequent - avoid any complications of pipelining them.
-// These only take a 2-3 cycles anyway and may result in a pipe flush (e.g. ecall, ebreak..).
 always @ (posedge clk_i or posedge rst_i)
 if (rst_i)
     csr_pending_q <= 1'b0;
@@ -624,6 +729,14 @@
 else if (pipe0_csr_wb_w)
     csr_pending_q <= 1'b0;
 
+always @ (posedge clk_i or posedge rst_i)
+if (rst_i)
+    fault_pending_q <= 1'b0;
+else if (pipe0_squash_e1_e2_w || pipe1_squash_e1_e2_w || branch_csr_request_i)
+    fault_pending_q <= 1'b0;
+else if (opcode_a_issue_r && ~take_interrupt_i && issue_a_has_fault_w)
+    fault_pending_q <= 1'b1;
+
 assign squash_w = pipe0_squash_e1_e2_w || pipe1_squash_e1_e2_w;
 
 //-------------------------------------------------------------
@@ -632,14 +745,20 @@
 reg [31:0] scoreboard_r;
 reg        pipe1_mux_lsu_r;
 reg        pipe1_mux_mul_r;
+reg        slot0_sb_hazard_r;
+reg        slot1_sb_hazard_r;
+
+wire e1_mem_active_w = pipe0_load_e1_w || pipe0_store_e1_w || pipe1_load_e1_w || pipe1_store_e1_w;
+wire slot0_post_lsu_block_w = e1_mem_active_w && (issue_a_mul_w || issue_a_div_w || issue_a_csr_w || issue_a_has_fault_w);
+wire slot1_post_lsu_block_w = e1_mem_active_w && issue_b_mul_w;
 
 // Check instructions can be issued in the second execution unit
-wire pipe1_ok_w      = issue_b_exec_w | issue_b_branch_w | issue_b_lsu_w | issue_b_mul_w;
+wire pipe1_ok_w      = issue_b_clean_w & (issue_b_exec_w | issue_b_branch_w | issue_b_lsu_w | issue_b_mul_w);
 
 // Is this combination of instructions possible to execute concurrently.
-// This excludes result dependencies which may also block secondary execution.
-wire dual_issue_ok_w =   enable_dual_issue_w &&  // Second pipe switched on
-                         pipe1_ok_w &&           // Instruction 2 is possible on second exec unit
+wire dual_issue_ok_w =   enable_dual_issue_w &&
+                         issue_a_clean_w &&
+                         pipe1_ok_w &&
                         (((issue_a_exec_w | issue_a_lsu_w | issue_a_mul_w) && issue_b_exec_w)   ||
                          ((issue_a_exec_w | issue_a_lsu_w | issue_a_mul_w) && issue_b_branch_w) ||
                          ((issue_a_exec_w | issue_a_mul_w) && issue_b_lsu_w)                    ||
@@ -655,41 +774,42 @@
     scoreboard_r         = 32'b0;
     pipe1_mux_lsu_r      = 1'b0;
     pipe1_mux_mul_r      = 1'b0;
+    slot0_sb_hazard_r    = 1'b0;
+    slot1_sb_hazard_r    = 1'b0;
 
     // Execution units with >= 2 cycle latency
     if (SUPPORT_LOAD_BYPASS == 0)
     begin
-        if (pipe0_load_e2_w)
+        if (pipe0_load_e2_w && (|pipe0_rd_e2_w))
             scoreboard_r[pipe0_rd_e2_w] = 1'b1;
-        if (pipe1_load_e2_w)
+        if (pipe1_load_e2_w && (|pipe1_rd_e2_w))
             scoreboard_r[pipe1_rd_e2_w] = 1'b1;
     end
     if (SUPPORT_MUL_BYPASS == 0)
     begin
-        if (pipe0_mul_e2_w)
+        if (pipe0_mul_e2_w && (|pipe0_rd_e2_w))
             scoreboard_r[pipe0_rd_e2_w] = 1'b1;
-        if (pipe1_mul_e2_w)
+        if (pipe1_mul_e2_w && (|pipe1_rd_e2_w))
             scoreboard_r[pipe1_rd_e2_w] = 1'b1;
     end
 
     // Execution units with >= 1 cycle latency (loads / multiply)
-    if (pipe0_load_e1_w || pipe0_mul_e1_w)
+    if ((pipe0_load_e1_w || pipe0_mul_e1_w) && (|pipe0_rd_e1_w))
         scoreboard_r[pipe0_rd_e1_w] = 1'b1;
-    if (pipe1_load_e1_w || pipe1_mul_e1_w)
+    if ((pipe1_load_e1_w || pipe1_mul_e1_w) && (|pipe1_rd_e1_w))
         scoreboard_r[pipe1_rd_e1_w] = 1'b1;
 
-    // Do not start multiply, division or CSR operation in the cycle after a load (leaving only ALU operations and branches)
-    if ((pipe0_load_e1_w || pipe0_store_e1_w || pipe1_load_e1_w || pipe1_store_e1_w ) && (issue_a_mul_w || issue_a_div_w || issue_a_csr_w))
-        scoreboard_r = 32'hFFFFFFFF;
+    scoreboard_r[0] = 1'b0;
+
+    slot0_sb_hazard_r = (issue_a_uses_ra_w && scoreboard_r[issue_a_ra_idx_w]) ||
+                        (issue_a_uses_rb_w && scoreboard_r[issue_a_rb_idx_w]) ||
+                        (issue_a_sb_alloc_w && scoreboard_r[issue_a_rd_idx_w]);
 
     // Stall - no issues...
-    if (lsu_stall_i || stall_w || div_pending_q || csr_pending_q)
+    if (lsu_stall_i || stall_w || div_pending_q || csr_pending_q || fault_pending_q)
         ;
-    // Primary slot (lsu, branch, alu, mul, div, csr)
-    else if (opcode_a_valid_r &&
-        !(scoreboard_r[issue_a_ra_idx_w] || 
-          scoreboard_r[issue_a_rb_idx_w] ||
-          scoreboard_r[issue_a_rd_idx_w]))
+    // Primary slot (lsu, branch, alu, mul, div, csr, fault)
+    else if (opcode_a_valid_r && !slot0_post_lsu_block_w && !slot0_sb_hazard_r)
     begin
         opcode_a_issue_r  = 1'b1;
         opcode_a_accept_r = 1'b1;
@@ -698,14 +818,15 @@
             scoreboard_r[issue_a_rd_idx_w] = 1'b1;
     end
 
+    slot1_sb_hazard_r = (issue_b_uses_ra_w && scoreboard_r[issue_b_ra_idx_w]) ||
+                        (issue_b_uses_rb_w && scoreboard_r[issue_b_rb_idx_w]) ||
+                        (issue_b_sb_alloc_w && scoreboard_r[issue_b_rd_idx_w]);
+
     // Stall - no issues...
-    if (lsu_stall_i || stall_w || div_pending_q || csr_pending_q)
+    if (lsu_stall_i || stall_w || div_pending_q || csr_pending_q || fault_pending_q)
         ;
     // Secondary Slot (lsu, branch, alu, mul)
-    else if (dual_issue_ok_w && opcode_b_valid_r && opcode_a_accept_r &&
-        !(scoreboard_r[issue_b_ra_idx_w] || 
-          scoreboard_r[issue_b_rb_idx_w] ||
-          scoreboard_r[issue_b_rd_idx_w]))
+    else if (dual_issue_ok_w && opcode_b_valid_r && opcode_a_accept_r && !slot1_post_lsu_block_w && !slot1_sb_hazard_r)
     begin
         opcode_b_issue_r  = 1'b1;
         opcode_b_accept_r = 1'b1;
@@ -714,16 +835,16 @@
 
         if (opcode_b_accept_r && issue_b_sb_alloc_w && (|issue_b_rd_idx_w))
             scoreboard_r[issue_b_rd_idx_w] = 1'b1;
-    end    
-end
-
-assign lsu_opcode_valid_o   = (pipe1_mux_lsu_r ? opcode_b_issue_r : opcode_a_issue_r) & ~take_interrupt_i;
-assign exec0_opcode_valid_o = opcode_a_issue_r;
-assign mul_opcode_valid_o   = enable_muldiv_w & (pipe1_mux_mul_r ? opcode_b_issue_r : opcode_a_issue_r);
-assign div_opcode_valid_o   = enable_muldiv_w & (opcode_a_issue_r);
-assign interrupt_inhibit_o  = csr_pending_q || issue_a_csr_w;
-
-assign exec1_opcode_valid_o = opcode_b_issue_r;
+    end
+end
+
+assign lsu_opcode_valid_o   = (pipe1_mux_lsu_r ? (opcode_b_issue_r & issue_b_lsu_w) : (opcode_a_issue_r & issue_a_lsu_w)) & ~take_interrupt_i;
+assign exec0_opcode_valid_o = opcode_a_issue_r & (issue_a_exec_w | issue_a_branch_w) & ~take_interrupt_i;
+assign mul_opcode_valid_o   = enable_muldiv_w & (pipe1_mux_mul_r ? (opcode_b_issue_r & issue_b_mul_w) : (opcode_a_issue_r & issue_a_mul_w)) & ~take_interrupt_i;
+assign div_opcode_valid_o   = enable_muldiv_w & opcode_a_issue_r & issue_a_div_w & ~take_interrupt_i;
+assign interrupt_inhibit_o  = csr_pending_q || (opcode_a_valid_r && issue_a_csr_w);
+
+assign exec1_opcode_valid_o = opcode_b_issue_r & (issue_b_exec_w | issue_b_branch_w) & ~take_interrupt_i;
 
 assign dual_issue_w         = opcode_b_issue_r & opcode_b_accept_r & ~take_interrupt_i;
 assign single_issue_w       = (opcode_a_issue_r & opcode_a_accept_r) & ~dual_issue_w & ~take_interrupt_i;
@@ -921,7 +1042,7 @@
 //-------------------------------------------------------------
 // CSR unit
 //-------------------------------------------------------------
-assign csr_opcode_valid_o       = opcode_a_issue_r & ~take_interrupt_i;
+assign csr_opcode_valid_o       = opcode_a_issue_r & issue_a_csr_w & ~issue_a_has_fault_w & ~take_interrupt_i;
 assign csr_opcode_opcode_o      = opcode0_opcode_o;
 assign csr_opcode_pc_o          = opcode0_pc_o;
 assign csr_opcode_rd_idx_o      = opcode0_rd_idx_o;
@@ -929,7 +1050,7 @@
 assign csr_opcode_rb_idx_o      = opcode0_rb_idx_o;
 assign csr_opcode_ra_operand_o  = opcode0_ra_operand_o;
 assign csr_opcode_rb_operand_o  = opcode0_rb_operand_o;
-assign csr_opcode_invalid_o     = opcode_a_issue_r && issue_a_invalid_w;
+assign csr_opcode_invalid_o     = opcode_a_issue_r && issue_a_invalid_w && ~take_interrupt_i;
 
 //-------------------------------------------------------------
 // Checker Interface

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/biriscv_alu.v`](environment/public/code/biriscv_alu.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_decoder.v`](environment/public/code/biriscv_decoder.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_defs.v`](environment/public/code/biriscv_defs.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_exec.v`](environment/public/code/biriscv_exec.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_issue.v`](environment/public/code/biriscv_issue.v) **(Editable)**
- [`environment/public/code/biriscv_pipe_ctrl.v`](environment/public/code/biriscv_pipe_ctrl.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_regfile.v`](environment/public/code/biriscv_regfile.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_trace_sim.v`](environment/public/code/biriscv_trace_sim.v) *(Read-Only Context)*
- [`environment/public/code/biriscv_xilinx_2r1w.v`](environment/public/code/biriscv_xilinx_2r1w.v) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

