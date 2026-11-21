# `case_22006`: RedMulE CORE-V-XIF Speculative Matrix ISA Offload, Split Operand Assembly, and Queued Controller Synchronization

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22006` |
| **Source Silicon Repository** | `pulp-platform/redmule` (`repo_30`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/redmule_inst_decoder.sv`](environment/public/code/redmule_inst_decoder.sv), [`code/redmule_ctrl.sv`](environment/public/code/redmule_ctrl.sv) (2 files, 694 LOC) |
| **Public Subsystem Context** | 15 RTL files (3274 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# RedMulE CORE-V-XIF Matrix Offload Frontend & Queued Controller Synchronization

## Context
In RedMulE (`redmule_xif_offload_subsys.sv`), RISC-V cores offload custom matrix instructions over the CORE-V-XIF 1.0 interface (`redmule_inst_decoder.sv`, `redmule_xif_pkg.sv`), pushing `redmule_config_t` job descriptors into a two-entry `redmule_config_fifo` (`i_config_fifo`) consumed by `redmule_ctrl.sv` (`i_cfg_tiler` and the controller FSM), with completion looped back via `evt_o -> op_done_i`. Currently, speculative CORE-V-XIF issue/commit/kill handling, split/out-of-order operand assembly (`XifIssueRegisterSplit = 1`), full `MCNFIG`/`MARITH`/`MOPCNT` decoding, multi-hart arbitration, and queued job execution across `redmule_inst_decoder.sv` and `redmule_ctrl.sv` are incomplete or broken.

## Architectural & Protocol Requirements

1. **Issue Legality & Handshake (`x_issue_*`)**:
   - Match `{instr[26:25], instr[14:12], instr[6:0]}` against `MCNFIG`, `MARITH`, and `MOPCNT` for valid harts (`hartid < XifNumHarts`):
     - `MCNFIG`: `accept = 1`, `writeback = 0`, `register_read = 3'b111`.
     - `MARITH`: `accept = 1`, `writeback = (rd != 5'd0)`, `register_read = 3'b111`.
     - `MOPCNT`: `accept = 1`, `writeback = (rd != 5'd0)`, `register_read = 3'b000` (`rd = instr[11:7]`).
     - Any unrecognized instruction (or `hartid >= XifNumHarts`): `accept = 0`, `writeback = 0`, `register_read = 3'b000`. Rejected instructions must never allocate state, consume standalone register/commit beats, or emit `x_result` packets.
   - Per hart, buffer up to `InstFifoDepth` accepted in-flight instructions (`x_issue_ready_o` reflects target hart slot availability).

2. **Operand Collection (`x_register_*`) in Non-Split (`0`) and Split (`1`) Modes**:
   - `MOPCNT` reads zero GPRs (`register_read = 3'b000`); the host CPU sends **no** `x_register` beat for `MOPCNT`, so `MOPCNT` is immediately operand-ready.
   - `MCNFIG` and `MARITH` require all three 32-bit operands `rs[2:0]`.
   - When `XifIssueRegisterSplit == 0`, `x_register` beats arrive for `MCNFIG`/`MARITH` in the same cycle as `x_issue` or in-order per hart (`rs_valid = 3'b111`), subject to `x_register_ready_o` backpressure without FIFO overflow.
   - When `XifIssueRegisterSplit == 1`, `x_register` beats for accepted `MCNFIG`/`MARITH` instructions arrive in the same cycle as `x_issue` or on later cycles matched by `(hartid, id)`, potentially out-of-order across active `id`s/harts and split across multiple partial beats where `x_register_i.rs_valid[k]` qualifies `x_register_i.rs[k]` until all three operands (`3'b111`) are assembled.

3. **Non-Speculative Commit/Kill Ordering (`x_commit_*`)**:
   - `x_commit_valid_i` (no backpressure) may arrive in the same cycle as `x_issue` or on any later cycle for any buffered `(hartid, id)`.
   - Within each hart, accepted instructions retire in issue order. An instruction must **never** update per-hart configuration state, enqueue a `MARITH` job (`config_valid_o`), advance operation ID counters, or assert `x_result_valid_o` until it has received `x_commit` with `commit_kill == 0` and its required operands.
   - If `x_commit` arrives with `commit_kill == 1` for `(hartid, id)`, discard **only** that instruction without side effects, without emitting an `x_result` transaction, and without flushing older or younger valid instructions on that hart.

4. **Descriptor Decoding, Multi-Hart Fairness, and `x_result_*` Handshake**:
   - Retiring `MCNFIG` updates only that hart's configuration: `m_size = rs[0][15:0]`, `k_size = rs[0][31:16]`, `n_size = rs[1][15:0]`, `{send_w, receive_w, send_x, receive_x} = rs[1][19:16]`, `gemm_ops = gemm_op_e'(rs[1][22:20])` (all 8 `gemm_op_e` values), `gemm_input_fmt = gemm_fmt_e'(rs[1][24:23])`, `gemm_output_fmt = gemm_fmt_e'(rs[1][26:25])`, `y_offs = rs[2][31:0]`, `w_cols_offset = 16'd0`, `loopback_w = 1'b0`, and emits `x_result` (`we = 0, data = 0`).
   - Retiring `MARITH` combines that hart's current `MCNFIG` state (preserving `gemm_ops`, `gemm_input_fmt`, `gemm_output_fmt`) with `x_addr = rs[0]`, `w_addr = rs[1]`, `z_addr = rs[2]`, performs a single `config_valid_o && config_ready_i` enqueue, emits `x_result` (`we = (rd != 0)`, `data = zero_ext(op_id_in[hart])`), and increments `op_id_in[hart]` (reset `0`, modulo `2^OpIdWidth`).
   - Retiring `MOPCNT` emits `x_result` (`we = (rd != 0)`, `data = zero_ext(op_id_out[hart])`), where `op_id_out[hart]` resets to `'1` (`{OpIdWidth{1'b1}}`) and increments modulo `2^OpIdWidth` each time an in-flight `MARITH` from `hart` completes (`op_done_i`), supporting full pipeline occupancy (`1` active + `2` queued in `i_config_fifo` + `InstFifoDepth` per hart) without tracker overflow.
   - Arbitrate across ready harts in starvation-free round-robin order (advancing priority on **every** retired instruction, including `MOPCNT`/`MCNFIG`). Maintain AXI-stream-style stability on `(x_result_valid_o, x_result_o)` across `x_result_ready_i == 0` stalls with **no combinational path** from `x_result_ready_i` to `config_valid_o`.

5. **Queued Job Isolation & Post-Drain Completion (`redmule_ctrl.sv` + `clear_i`)**:
   - While a job is active in `redmule_ctrl` (non-idle states, including two-pass `w_cols_offset != 0` loopback if driven), queued entries waiting in `i_config_fifo` must **not** trigger `i_cfg_tiler`, overwrite `config_o`, or assert `cfg_complete_o` early; start tiling the next queued job only when `redmule_ctrl` is in `REDMULE_IDLE` with `fifo_ready_i`.
   - Assert `evt_o` as a single-cycle pulse strictly when the job reaches `REDMULE_FINISHED` (after `z_stream_sink_flags.ready_start && fifo_empty_i && flgs_streamer_i.store_fifo_empty` and final pass completion), never prematurely while Z store FIFO beats remain pending.
   - `clear_i` / `target_clear_i` synchronously flushes in-flight state and resets counters/configurations cleanly; both editable modules must synthesize cleanly (`yosys -m slang`) with zero unintended latches across `XifNumHarts >= 1` and `XifIssueRegisterSplit` in `{0, 1}`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment

## Editable Files
- `code/redmule_inst_decoder.sv`
- `code/redmule_ctrl.sv`

All other files in `code/` (including `redmule_pkg.sv`, `redmule_xif_pkg.sv`, `redmule_config_fifo.sv`, `redmule_tiler.sv`, `redmule_xif_offload_subsys.sv`, and `include/common_cells/*.svh`) are read-only reference collateral. Preserve the module declarations, parameter lists, and port interfaces of `redmule_inst_decoder` and `redmule_ctrl`.

## Available Toolchain
- **Verilator (`v5.038`)**: `verilator`
- **Yosys + Slang (`yosys -m slang`)**: `yosys`

## Example Elaboration & Lint Commands

### 1. Verilator Elaboration & Lint
```bash
verilator \
  --lint-only -sv -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  +incdir+code/include \
  code/cf_math_pkg.sv code/fpnew_pkg.sv code/hci_package.sv \
  code/hwpe_ctrl_package.sv code/hwpe_stream_package.sv \
  code/redmule_pkg.sv code/redmule_xif_pkg.sv \
  code/tc_clk.sv code/redmule_config_fifo.sv code/redmule_tiler.sv \
  code/redmule_ctrl.sv code/redmule_inst_decoder.sv \
  code/redmule_xif_offload_subsys.sv \
  --top-module redmule_xif_offload_subsys
```

### 2. Yosys + Slang Synthesis Sanity Check
```bash
yosys -m slang -p "
  read_slang --top redmule_xif_offload_subsys -I code/include \
    code/cf_math_pkg.sv code/fpnew_pkg.sv code/hci_package.sv \
    code/hwpe_ctrl_package.sv code/hwpe_stream_package.sv \
    code/redmule_pkg.sv code/redmule_xif_pkg.sv \
    code/tc_clk.sv code/redmule_config_fifo.sv code/redmule_tiler.sv \
    code/redmule_ctrl.sv code/redmule_inst_decoder.sv \
    code/redmule_xif_offload_subsys.sv;
  hierarchy -check -top redmule_xif_offload_subsys;
  proc; opt; check
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/redmule_inst_decoder.sv (Buggy Starter)
+++ b/solution/gold/code/redmule_inst_decoder.sv (Golden Reference)
@@ -1,9 +1,6 @@
 // Copyright 2025 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Andrea Belano <andrea.belano2@unibo.it>
-//
 
 module redmule_inst_decoder
   import redmule_pkg::*;
@@ -49,438 +46,462 @@
   input  logic            x_result_ready_i
 );
 
-  // Calculate the width needed to represent hart IDs (minimum 1 bit)
-  localparam int unsigned HartIdWidth = XifNumHarts > 1 ? $clog2(XifNumHarts) : 1;
-
-  // Compose full instruction encoding patterns for the three custom instructions:
-  // MCNFIG: Matrix configuration (sets dimensions, data flow control)
-  // MARITH: Matrix arithmetic operation (triggers computation with addresses)
-  // MOPCNT: Matrix operation count (returns number of completed operations)
-  localparam logic [11:0] MCNFIG = {McnfigFunct2,McnfigFunct3,McnfigOpCode};
-  localparam logic [11:0] MARITH = {MarithFunct2,MarithFunct3,MarithOpCode};
-  localparam logic [11:0] MOPCNT = {MopcntFunct2,MopcntFunct3,MopcntOpCode};
-
-  // Per-hart FIFO status flags for instruction and register packets
-  logic [XifNumHarts-1:0] issue_fifo_full,  register_fifo_full,
-                          issue_fifo_empty, register_fifo_empty;
-
-  // Hart ID of the currently executing operation (tracked through pipeline)
-  logic [HartIdWidth-1:0] current_hartid_d, current_hartid_q;
-
-  // Current instruction issue request and register data at head of each hart's FIFO
-  x_issue_req_t [XifNumHarts-1:0] cur_issue;
-  x_register_t  [XifNumHarts-1:0] cur_register;
-
-  // TODO unused:
-  x_result_t                      x_result_d, x_result_q;
-
-  // Per-hart operation ID counters:
-  // op_id_counter_in_q:  Increments when operations are issued (tags for tracking)
-  // op_id_counter_out_q: Increments when operations complete (for MOPCNT instruction)
-  logic [XifNumHarts-1:0] [OpIdWidth-1:0] op_id_counter_in_q, op_id_counter_out_q;
-
-  // Round-robin arbitration state for fair scheduling across harts
-  logic [HartIdWidth-1:0]                  rr_counter_d, rr_counter_q;
-  logic [XifNumHarts-1:0][HartIdWidth-1:0] rr_priority;
-  logic [HartIdWidth-1:0]                  winner;
-
-  // Flag indicating whether the incoming instruction is a recognized RedMule custom instruction
-  logic legal_inst;
-
-  // Per-hart configuration registers holding matrix operation parameters
-  redmule_config_t [XifNumHarts-1:0] config_d, config_q;
-
-  // Control signal to enable popping from instruction FIFOs (delayed for MARITH until tiler ready)
-  logic pop_enable;
-
-  // Decode incoming instruction to determine if it's a legal RedMule custom instruction
-  // Checks funct2[26:25], funct3[14:12], and opcode[6:0] fields
-  always_comb begin : legal_inst_assignment
+  localparam int unsigned HartIdWidth   = XifNumHarts > 1 ? $clog2(XifNumHarts) : 1;
+  localparam int unsigned SlotIdxWidth  = InstFifoDepth > 1 ? $clog2(InstFifoDepth) : 1;
+  localparam int unsigned SlotCntWidth  = $clog2(InstFifoDepth + 1);
+  localparam int unsigned InflightDepth = InstFifoDepth * XifNumHarts + 8;
+
+  localparam logic [11:0] MCNFIG = {McnfigFunct2, McnfigFunct3, McnfigOpCode};
+  localparam logic [11:0] MARITH = {MarithFunct2, MarithFunct3, MarithOpCode};
+  localparam logic [11:0] MOPCNT = {MopcntFunct2, MopcntFunct3, MopcntOpCode};
+
+  // Issue legality decode
+  logic [11:0] issue_key;
+  logic        issue_hart_ok;
+  logic        legal_inst;
+
+  assign issue_key     = {x_issue_req_i.instr[26:25], x_issue_req_i.instr[14:12], x_issue_req_i.instr[6:0]};
+  assign issue_hart_ok = (32'(x_issue_req_i.hartid) < XifNumHarts);
+
+  always_comb begin : legal_inst_decode
     legal_inst = 1'b0;
-
-    unique case ({x_issue_req_i.instr[26:25],x_issue_req_i.instr[14:12],x_issue_req_i.instr[6:0]})
-      MCNFIG, MARITH, MOPCNT: legal_inst = 1'b1;
-      default: legal_inst = 1'b0;
-    endcase
-  end
-
-  // Generate XIF issue response indicating whether instruction is accepted and resource needs
-  always_comb begin : x_issue_resp_assignment
-    // Accept instruction only if it's a legal RedMule custom instruction
+    if (issue_hart_ok) begin
+      unique case (issue_key)
+        MCNFIG, MARITH, MOPCNT: legal_inst = 1'b1;
+        default:                legal_inst = 1'b0;
+      endcase
+    end
+  end
+
+  always_comb begin : issue_resp_decode
+    x_issue_resp_o = '0;
     x_issue_resp_o.accept = legal_inst;
-
-    unique case ({x_issue_req_i.instr[26:25],x_issue_req_i.instr[14:12],x_issue_req_i.instr[6:0]})
-      MCNFIG: begin
-        // MCNFIG: No writeback (configuration only), reads 3 source registers
-        x_issue_resp_o.writeback     = 'b0;
-        x_issue_resp_o.register_read = 'b111;  // Read rs1, rs2, rs3
-      end
-      MARITH: begin
-        // MARITH: Writeback if rd != x0 (returns operation ID), reads 3 source registers
-        x_issue_resp_o.writeback     = x_issue_req_i.instr[11:7] != 0;
-        x_issue_resp_o.register_read = 'b111;  // Read rs1, rs2, rs3 (addresses)
-      end
-      MOPCNT: begin
-        // MOPCNT: Writeback if rd != x0 (returns completion count), no register reads
-        x_issue_resp_o.writeback     = x_issue_req_i.instr[11:7] != 0;
-        x_issue_resp_o.register_read = 'b0;    // No source registers needed
-      end
-      default: begin
-        x_issue_resp_o.writeback     = 'b0;
-        x_issue_resp_o.register_read = 'b0;
-      end
-    endcase
-  end
-
-
-  // Construct result packet to write back to CPU register file
-  always_comb begin : x_result_assignment
-    // Result valid when both instruction and register data available for winning hart
-    x_result_valid_o  = ~issue_fifo_empty[winner] && ~register_fifo_empty[winner] && ({cur_issue[winner].instr[26:25],cur_issue[winner].instr[14:12],cur_issue[winner].instr[6:0]} == MARITH ? config_ready_i : 1'b1);
-    x_result_o.hartid = cur_issue[winner].hartid;
-    x_result_o.id     = cur_issue[winner].id;
-    x_result_o.rd     = cur_issue[winner].instr[11:7];  // Destination register
-
-    unique case ({cur_issue[winner].instr[26:25],cur_issue[winner].instr[14:12],cur_issue[winner].instr[6:0]})
-      MCNFIG: begin
-        // MCNFIG: No writeback, configuration stored internally
-        x_result_o.we   = 'b0;
-        x_result_o.data = 'b0;
-      end
-      MARITH: begin
-        // MARITH: Write operation ID to rd (for tracking/synchronization)
-        x_result_o.we   = cur_issue[winner].instr[11:7] != 0;
-        x_result_o.data = op_id_counter_in_q[winner];
-      end
-      MOPCNT: begin
-        // MOPCNT: Write completion counter to rd (number of finished operations)
-        x_result_o.we   = cur_issue[winner].instr[11:7] != 0;
-        x_result_o.data = op_id_counter_out_q[winner];
-      end
-      default: begin
-        x_result_o.we   = 'b0;
-        x_result_o.data = 'b0;
-      end
-    endcase
-  end
-
-  // Output configuration from the winning hart to the RedMule tiler/controller
-  assign config_o = config_d[winner];
-
-  // Configuration valid only for MARITH instructions when both FIFOs have data and CPU is ready
-  // (MCNFIG updates config but doesn't trigger execution)
-  assign config_valid_o = ~issue_fifo_empty[winner] && ~register_fifo_empty[winner] && x_result_ready_i && {cur_issue[winner].instr[26:25],cur_issue[winner].instr[14:12],cur_issue[winner].instr[6:0]} == MARITH;
-
-  // Signal readiness to accept new instruction issue based on target hart's FIFO availability
-  always_comb begin : x_issue_ready_assignment
+    if (issue_hart_ok) begin
+      unique case (issue_key)
+        MCNFIG: begin
+          x_issue_resp_o.writeback     = 1'b0;
+          x_issue_resp_o.register_read = 3'b111;
+        end
+        MARITH: begin
+          x_issue_resp_o.writeback     = (x_issue_req_i.instr[11:7] != 5'd0);
+          x_issue_resp_o.register_read = 3'b111;
+        end
+        MOPCNT: begin
+          x_issue_resp_o.writeback     = (x_issue_req_i.instr[11:7] != 5'd0);
+          x_issue_resp_o.register_read = 3'b000;
+        end
+        default: begin
+          x_issue_resp_o.writeback     = 1'b0;
+          x_issue_resp_o.register_read = 3'b000;
+        end
+      endcase
+    end
+  end
+
+  // Per-hart circular scoreboard state
+  logic [XifNumHarts-1:0][InstFifoDepth-1:0]               slot_valid_q,     slot_valid_d;
+  logic [XifNumHarts-1:0][InstFifoDepth-1:0][31:0]         slot_instr_q,     slot_instr_d;
+  logic [XifNumHarts-1:0][InstFifoDepth-1:0][XifIdWidth-1:0] slot_id_q,      slot_id_d;
+  logic [XifNumHarts-1:0][InstFifoDepth-1:0][2:0][31:0]    slot_rs_q,        slot_rs_d;
+  logic [XifNumHarts-1:0][InstFifoDepth-1:0][2:0]          slot_rs_valid_q,  slot_rs_valid_d;
+  logic [XifNumHarts-1:0][InstFifoDepth-1:0]               slot_committed_q, slot_committed_d;
+  logic [XifNumHarts-1:0][InstFifoDepth-1:0]               slot_killed_q,    slot_killed_d;
+
+  logic [XifNumHarts-1:0][SlotIdxWidth-1:0]                head_ptr_q, head_ptr_d;
+  logic [XifNumHarts-1:0][SlotIdxWidth-1:0]                tail_ptr_q, tail_ptr_d;
+  logic [XifNumHarts-1:0][SlotCntWidth-1:0]                slot_cnt_q, slot_cnt_d;
+
+  logic [XifNumHarts-1:0] slot_full;
+  logic [XifNumHarts-1:0] has_pending_reg_slot;
+
+  // Per-hart architectural configs & op counters
+  redmule_config_t [XifNumHarts-1:0]      config_q, config_next;
+  logic [XifNumHarts-1:0][OpIdWidth-1:0]  op_id_counter_in_q;
+  logic [XifNumHarts-1:0][OpIdWidth-1:0]  op_id_counter_out_q;
+
+  // Head-of-hart candidate decode & readiness
+  logic [XifNumHarts-1:0]       hart_head_ready;
+  logic [XifNumHarts-1:0]       hart_head_is_marith;
+  logic [XifNumHarts-1:0]       hart_head_is_mcnfig;
+  redmule_config_t [XifNumHarts-1:0] hart_head_cfg;
+  x_result_t [XifNumHarts-1:0]  hart_head_res;
+
+  // Output result FIFO (decouples x_result_ready_i from config_valid_o)
+  logic      res_fifo_full, res_fifo_empty;
+  logic      res_fifo_push, res_fifo_pop;
+  x_result_t res_fifo_din,  res_fifo_dout;
+
+  // In-flight hart ID completion FIFO
+  logic                   hartid_fifo_full, hartid_fifo_empty;
+  logic [HartIdWidth-1:0] completing_hartid;
+
+  // Round-robin state
+  logic [HartIdWidth-1:0] rr_counter_q, rr_counter_d;
+  logic [HartIdWidth-1:0] winner;
+  logic                   any_winner_valid;
+  logic                   retire_fire;
+  logic                   marith_fire;
+
+  // Ready generation on issue and register channels
+  always_comb begin : issue_ready_gen
     x_issue_ready_o = 1'b0;
-
-    // Find the hart matching the incoming request and check its issue FIFO status
-    for (int unsigned i = 0; i < XifNumHarts; i++) begin
-      if (x_issue_req_i.hartid == i) begin
-        x_issue_ready_o = ~issue_fifo_full[i];
-      end
-    end
-  end
-
-  // Signal readiness to accept new register packet based on target hart's FIFO availability
-  always_comb begin : x_register_ready_assignment
+    for (int unsigned h = 0; h < XifNumHarts; h++) begin
+      if (32'(x_issue_req_i.hartid) == h) begin
+        x_issue_ready_o = ~slot_full[h];
+      end
+    end
+  end
+
+  always_comb begin : register_ready_gen
     x_register_ready_o = 1'b0;
-
-    // Find the hart matching the incoming register data and check its register FIFO status
-    for (int unsigned i = 0; i < XifNumHarts; i++) begin
-      if (x_register_i.hartid == i) begin
-        x_register_ready_o = ~register_fifo_full[i];
-      end
-    end
-  end
-
-  // Round-robin counter for fair arbitration across multiple harts
-  // Advances each time a configuration is successfully accepted by downstream logic
-  always_ff @(posedge clk_i, negedge rst_ni) begin : round_robin_counter
-    if(~rst_ni) begin
+    for (int unsigned h = 0; h < XifNumHarts; h++) begin
+      if (32'(x_register_i.hartid) == h) begin
+        x_register_ready_o = has_pending_reg_slot[h] || ~slot_full[h];
+      end
+    end
+  end
+
+  // Per-hart head instruction evaluation
+  for (genvar h = 0; h < XifNumHarts; h++) begin : gen_hart_head_eval
+    logic [SlotIdxWidth-1:0] h_idx;
+    logic [31:0]             h_instr;
+    logic [11:0]             h_key;
+    logic                    h_valid, h_comm, h_kill, h_ops_ok;
+
+    assign slot_full[h] = (slot_cnt_q[h] == SlotCntWidth'(InstFifoDepth));
+    assign h_idx        = head_ptr_q[h];
+    assign h_valid      = (slot_cnt_q[h] != '0) && slot_valid_q[h][h_idx];
+    assign h_instr      = slot_instr_q[h][h_idx];
+    assign h_key        = {h_instr[26:25], h_instr[14:12], h_instr[6:0]};
+    assign h_comm       = slot_committed_q[h][h_idx];
+    assign h_kill       = slot_killed_q[h][h_idx];
+    assign h_ops_ok     = (slot_rs_valid_q[h][h_idx] == 3'b111);
+
+    assign hart_head_is_marith[h] = (h_key == MARITH);
+    assign hart_head_is_mcnfig[h] = (h_key == MCNFIG);
+
+    always_comb begin
+      has_pending_reg_slot[h] = 1'b0;
+      for (int unsigned s = 0; s < InstFifoDepth; s++) begin
+        if (slot_valid_q[h][s] && !slot_killed_q[h][s] && (slot_rs_valid_q[h][s] != 3'b111)) begin
+          has_pending_reg_slot[h] = 1'b1;
+        end
+      end
+    end
+
+    always_comb begin
+      hart_head_cfg[h]            = config_q[h];
+      hart_head_cfg[h].loopback_w = 1'b0;
+      unique case (h_key)
+        MCNFIG: begin
+          hart_head_cfg[h].m_size          = slot_rs_q[h][h_idx][0][15:0];
+          hart_head_cfg[h].k_size          = slot_rs_q[h][h_idx][0][31:16];
+          hart_head_cfg[h].n_size          = slot_rs_q[h][h_idx][1][15:0];
+          hart_head_cfg[h].receive_x       = slot_rs_q[h][h_idx][1][16];
+          hart_head_cfg[h].send_x          = slot_rs_q[h][h_idx][1][17];
+          hart_head_cfg[h].receive_w       = slot_rs_q[h][h_idx][1][18];
+          hart_head_cfg[h].send_w          = slot_rs_q[h][h_idx][1][19];
+          hart_head_cfg[h].gemm_ops        = gemm_op_e'(slot_rs_q[h][h_idx][1][22:20]);
+          hart_head_cfg[h].gemm_input_fmt  = gemm_fmt_e'(slot_rs_q[h][h_idx][1][24:23]);
+          hart_head_cfg[h].gemm_output_fmt = gemm_fmt_e'(slot_rs_q[h][h_idx][1][26:25]);
+          hart_head_cfg[h].y_offs          = slot_rs_q[h][h_idx][2][31:0];
+          hart_head_cfg[h].w_cols_offset   = 16'd0;
+        end
+        MARITH: begin
+          hart_head_cfg[h].x_addr          = slot_rs_q[h][h_idx][0][31:0];
+          hart_head_cfg[h].w_addr          = slot_rs_q[h][h_idx][1][31:0];
+          hart_head_cfg[h].z_addr          = slot_rs_q[h][h_idx][2][31:0];
+        end
+        default: begin
+          hart_head_cfg[h] = config_q[h];
+        end
+      endcase
+    end
+
+    always_comb begin
+      hart_head_res[h]        = '0;
+      hart_head_res[h].hartid = HartIdWidth'(h);
+      hart_head_res[h].id     = slot_id_q[h][h_idx];
+      hart_head_res[h].rd     = h_instr[11:7];
+      unique case (h_key)
+        MCNFIG: begin
+          hart_head_res[h].we   = 1'b0;
+          hart_head_res[h].data = 32'd0;
+        end
+        MARITH: begin
+          hart_head_res[h].we   = (h_instr[11:7] != 5'd0);
+          hart_head_res[h].data = 32'(op_id_counter_in_q[h]);
+        end
+        MOPCNT: begin
+          hart_head_res[h].we   = (h_instr[11:7] != 5'd0);
+          hart_head_res[h].data = 32'(op_id_counter_out_q[h]);
+        end
+        default: begin
+          hart_head_res[h].we   = 1'b0;
+          hart_head_res[h].data = 32'd0;
+        end
+      endcase
+    end
+
+    assign hart_head_ready[h] = h_valid && h_comm && !h_kill && h_ops_ok && !res_fifo_full &&
+                                ((h_key == MARITH) ? (config_ready_i && !hartid_fifo_full) : 1'b1);
+  end
+
+  // Starvation-free round-robin winner selection across ready harts
+  always_comb begin : rr_arbiter
+    winner           = rr_counter_q;
+    any_winner_valid = 1'b0;
+    for (int unsigned off = 0; off < XifNumHarts; off++) begin
+      int unsigned cand;
+      cand = (32'(rr_counter_q) + off < XifNumHarts) ?
+             (32'(rr_counter_q) + off) :
+             (32'(rr_counter_q) + off - XifNumHarts);
+      if (!any_winner_valid && hart_head_ready[cand]) begin
+        winner           = HartIdWidth'(cand);
+        any_winner_valid = 1'b1;
+      end
+    end
+  end
+
+  assign retire_fire    = any_winner_valid;
+  assign marith_fire    = retire_fire && hart_head_is_marith[winner];
+  assign config_valid_o = marith_fire;
+  assign config_o       = hart_head_cfg[winner];
+
+  assign rr_counter_d = (32'(winner) + 1 >= XifNumHarts) ? '0 : (winner + 1'b1);
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin : rr_counter_reg
+    if (!rst_ni) begin
       rr_counter_q <= '0;
-    end else begin
-      if (clear_i) begin
-        rr_counter_q <= '0;
-      end else if (config_ready_i && config_valid_o) begin
-        rr_counter_q <= rr_counter_d;
-      end
-    end
-  end
-
-  // Wrap counter to 0 after reaching the last hart
-  assign rr_counter_d = rr_counter_q == XifNumHarts-1 ? 0 : rr_counter_q + 1;
-
-  // Calculate priority order for round-robin arbitration
-  // Creates a rotated sequence starting from current counter position
-  always_comb begin : round_robin_priority
-    for(int i = 0; i < XifNumHarts; i++) begin
-      rr_priority[i] = (rr_counter_q + i < XifNumHarts) ? rr_counter_q + i : rr_counter_q + i - XifNumHarts;
-    end
-  end
-
-  // Select winning hart using round-robin priority among harts with ready instructions
-  // Scans in priority order and selects first hart with both issue and register data available
-  always_comb begin : winner_assignment
-    winner = rr_counter_q;  // Default to current counter position
-
-    // Override with first ready hart in priority order
-    for(int i = 0; i < XifNumHarts; i++) begin
-      if (~issue_fifo_empty[rr_priority[i]] && ~register_fifo_empty[rr_priority[i]]) begin
-        winner = rr_priority[i];
-      end
-    end
-  end
-
-  // FIFO tracking which hart each in-flight operation belongs to
-  // Pushed when operation starts, popped when operation completes
-  // Used to correctly increment the completion counter for MOPCNT instruction
+    end else if (clear_i) begin
+      rr_counter_q <= '0;
+    end else if (retire_fire) begin
+      rr_counter_q <= rr_counter_d;
+    end
+  end
+
+  // Registered x_result output FIFO (depth 2, zero combinational x_result_ready_i -> config_valid_o path)
+  assign res_fifo_push = retire_fire;
+  assign res_fifo_din  = hart_head_res[winner];
+  assign res_fifo_pop  = x_result_valid_o && x_result_ready_i;
+
   redmule_config_fifo #(
-    .FALL_THROUGH ( 0                           ),
-    .DEPTH        ( InstFifoDepth * XifNumHarts ),
-    .DATA_WIDTH   ( HartIdWidth                 )
+    .FALL_THROUGH ( 0          ),
+    .DEPTH        ( 2          ),
+    .dtype        ( x_result_t )
+  ) i_result_fifo (
+    .clk_i      ( clk_i          ),
+    .rst_ni     ( rst_ni         ),
+    .flush_i    ( clear_i        ),
+    .testmode_i ( 1'b0           ),
+    .full_o     ( res_fifo_full  ),
+    .empty_o    ( res_fifo_empty ),
+    .usage_o    (                ),
+    .data_i     ( res_fifo_din   ),
+    .push_i     ( res_fifo_push  ),
+    .data_o     ( res_fifo_dout  ),
+    .pop_i      ( res_fifo_pop   )
+  );
+
+  assign x_result_valid_o = ~res_fifo_empty;
+  assign x_result_o       = res_fifo_dout;
+
+  // In-flight hart completion tracker FIFO
+  redmule_config_fifo #(
+    .FALL_THROUGH ( 0             ),
+    .DEPTH        ( InflightDepth ),
+    .DATA_WIDTH   ( HartIdWidth   )
   ) i_current_hartid_fifo (
-    .clk_i      ( clk_i                            ),
-    .rst_ni     ( rst_ni                           ),
-    .flush_i    ( clear_i                          ),
-    .testmode_i ( '0                               ),
-    .full_o     (                                  ),
-    .empty_o    (                                  ),
-    .usage_o    (                                  ),
-    .data_i     ( winner                           ),          // Push winning hart ID
-    .push_i     ( config_ready_i && config_valid_o ),          // On operation issue
-    .data_o     ( current_hartid_q                 ),          // Hart of completing op
-    .pop_i      ( op_done_i                        )           // On operation completion
+    .clk_i      ( clk_i                             ),
+    .rst_ni     ( rst_ni                            ),
+    .flush_i    ( clear_i                           ),
+    .testmode_i ( 1'b0                              ),
+    .full_o     ( hartid_fifo_full                  ),
+    .empty_o    ( hartid_fifo_empty                 ),
+    .usage_o    (                                   ),
+    .data_i     ( winner                            ),
+    .push_i     ( marith_fire                       ),
+    .data_o     ( completing_hartid                 ),
+    .pop_i      ( op_done_i && !hartid_fifo_empty   )
   );
 
-  // Per-hart operation ID counters for tracking issued and completed operations
-  for (genvar i = 0; i < XifNumHarts; i++) begin : gen_op_id_counters
-    // Input counter: increments when MARITH instruction is issued to this hart
-    // Returns this value to CPU as operation ID for software tracking
-    always_ff @(posedge clk_i or negedge rst_ni) begin : op_id_counter_in
-      if (~rst_ni) begin
-        op_id_counter_in_q[i] <= 0;
+  // Per-hart scoreboard update, config registers, and op ID counters
+  for (genvar h = 0; h < XifNumHarts; h++) begin : gen_hart_state
+    always_comb begin
+      logic issue_push_h;
+      logic reg_beat_h;
+      logic commit_beat_h;
+      logic pop_head_h;
+      logic [2:0] eff_rs_valid;
+      logic reg_matched_existing;
+
+      slot_valid_d[h]     = slot_valid_q[h];
+      slot_instr_d[h]     = slot_instr_q[h];
+      slot_id_d[h]        = slot_id_q[h];
+      slot_rs_d[h]        = slot_rs_q[h];
+      slot_rs_valid_d[h]  = slot_rs_valid_q[h];
+      slot_committed_d[h] = slot_committed_q[h];
+      slot_killed_d[h]    = slot_killed_q[h];
+      head_ptr_d[h]       = head_ptr_q[h];
+      tail_ptr_d[h]       = tail_ptr_q[h];
+      slot_cnt_d[h]       = slot_cnt_q[h];
+      config_next[h]      = config_q[h];
+
+      issue_push_h  = x_issue_valid_i && x_issue_ready_o && legal_inst && (32'(x_issue_req_i.hartid) == h);
+      reg_beat_h    = x_register_valid_i && x_register_ready_o && (32'(x_register_i.hartid) == h);
+      commit_beat_h = x_commit_valid_i && (32'(x_commit_i.hartid) == h);
+
+      eff_rs_valid = (XifIssueRegisterSplit == 0) ?
+                     ((x_register_i.rs_valid == 3'b000) ? 3'b111 : x_register_i.rs_valid) :
+                     x_register_i.rs_valid;
+
+      // 1. Update existing valid slots on x_register
+      reg_matched_existing = 1'b0;
+      if (reg_beat_h) begin
+        for (int unsigned off = 0; off < InstFifoDepth; off++) begin
+          int unsigned idx;
+          idx = (32'(head_ptr_q[h]) + off < InstFifoDepth) ?
+                (32'(head_ptr_q[h]) + off) :
+                (32'(head_ptr_q[h]) + off - InstFifoDepth);
+          if (!reg_matched_existing && slot_valid_q[h][idx] && !slot_killed_q[h][idx] &&
+              (slot_rs_valid_q[h][idx] != 3'b111)) begin
+            if ((XifIssueRegisterSplit == 0) || (slot_id_q[h][idx] == x_register_i.id)) begin
+              for (int unsigned r = 0; r < 3; r++) begin
+                if (eff_rs_valid[r]) begin
+                  slot_rs_d[h][idx][r]       = x_register_i.rs[r];
+                  slot_rs_valid_d[h][idx][r] = 1'b1;
+                end
+              end
+              reg_matched_existing = 1'b1;
+            end
+          end
+        end
+      end
+
+      // 2. Update existing valid slots on x_commit
+      if (commit_beat_h) begin
+        for (int unsigned off = 0; off < InstFifoDepth; off++) begin
+          int unsigned idx;
+          idx = (32'(head_ptr_q[h]) + off < InstFifoDepth) ?
+                (32'(head_ptr_q[h]) + off) :
+                (32'(head_ptr_q[h]) + off - InstFifoDepth);
+          if (slot_valid_q[h][idx] && !slot_committed_q[h][idx] && !slot_killed_q[h][idx] &&
+              (slot_id_q[h][idx] == x_commit_i.id)) begin
+            if (x_commit_i.commit_kill) begin
+              slot_killed_d[h][idx] = 1'b1;
+            end else begin
+              slot_committed_d[h][idx] = 1'b1;
+            end
+          end
+        end
+      end
+
+      // 3. Pop head slot if retiring OR if head slot is killed
+      pop_head_h = 1'b0;
+      if ((retire_fire && (32'(winner) == h)) ||
+          ((slot_cnt_q[h] != '0) && slot_valid_q[h][head_ptr_q[h]] && slot_killed_d[h][head_ptr_q[h]])) begin
+        pop_head_h = 1'b1;
+        if (retire_fire && (32'(winner) == h)) begin
+          config_next[h] = hart_head_cfg[h];
+        end
+        slot_valid_d[h][head_ptr_q
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/hci_package.sv`](environment/public/code/hci_package.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_ctrl_package.sv`](environment/public/code/hwpe_ctrl_package.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_stream_package.sv`](environment/public/code/hwpe_stream_package.sv) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/redmule_config_fifo.sv`](environment/public/code/redmule_config_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_ctrl.sv`](environment/public/code/redmule_ctrl.sv) **(Editable)**
- [`environment/public/code/redmule_inst_decoder.sv`](environment/public/code/redmule_inst_decoder.sv) **(Editable)**
- [`environment/public/code/redmule_pkg.sv`](environment/public/code/redmule_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_tiler.sv`](environment/public/code/redmule_tiler.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_xif_offload_subsys.sv`](environment/public/code/redmule_xif_offload_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_xif_pkg.sv`](environment/public/code/redmule_xif_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/tc_clk.sv`](environment/public/code/tc_clk.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

