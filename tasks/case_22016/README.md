# `case_22016`: Resolve Ara Dispatcher and Sequencer RVV 1.0 Multi-Register Group Scoreboarding, Selective Chaining Hazards, VFU Queue Backpressure, and Scalar/CSR Drain Serialization

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22016` |
| **Source Silicon Repository** | `pulp-platform/ara` (`repo_19`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/ara_sequencer.sv`](environment/public/code/ara_sequencer.sv), [`code/ara_dispatcher.sv`](environment/public/code/ara_dispatcher.sv) (2 files, 4511 LOC) |
| **Public Subsystem Context** | 37 RTL files (14934 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Multi-VFU Vector Chaining Scoreboard, Queue Accounting, and CSR Ordering in Ara

## Architectural Context

In PULP Ara, `code/ara_dispatcher.sv` decodes RVV 1.0 instructions and vector CSR operations from CVA6, injects VRF `EEW` reshuffle micro-ops when needed, and forwards vector requests to `code/ara_sequencer.sv`. `code/ara_sequencer.sv` allocates `NrVInsn` instruction slots, tracks RAW/WAR/WAW register hazards, enforces per-VFU instruction-queue capacity (`InsnQueueDepth`), coordinates scalar return handshakes, and drives `pe_req_o` and `global_hazard_table_o` to the lanes (`code/lane/lane_sequencer.sv` and `code/lane/operand_requester.sv`).

Under multi-register (`LMUL > 1` / widening / narrowing) workloads, mixed VFU latencies, masked operations, scalar moves, zero-length instructions, and back-to-back CSR accesses, several pipeline-hazard, queue-accounting, and ordering bugs cause silent VRF corruption, premature CSR reads, or VFU deadlocks.

## Functional Requirements

1. **Multi-Register (`EMUL` / `LMUL > 1`) Group Decoding & Multi-Producer Scoreboarding (`ara_dispatcher.sv`, `ara_sequencer.sv`)**:
   - In `ara_dispatcher.sv`, propagate `csr_vtype_q.vlmul` as effective `emul` for multi-register vector-destination `OPMVV` instructions (integer multiply/MAC, divide/remainder, averaging add/sub, `viota.m`, `vid.v`, `vcompress.vm`) while keeping single-register scalar/mask operands at `LMUL_1` (including reduction scalar `vs1`, mask-logical sources, `viota.m` mask `vs2`, `vcompress.vm` mask `vs1`, and `VWXUNARY0` `vmv.x.s`/`vcpop.m`/`vfirst.m` without spurious `vs1` VRF reads). Ensure `RESHUFFLE` micro-ops drive `LMUL_1` on both `emul` and `vtype.vlmul`.
   - In `ara_sequencer.sv`, track all concurrently active `NrVInsn` readers and writers across the exact RVV register-group span (`1, 2, 4, 8` registers in `v0..v31`) of every active source (`vs1`, `vs2`, `vd` source operand, and `v0` when `vm == 0`) and destination (`vd`).
2. **Safe Vector Chaining vs. Unchainable Hazard Stall Interlocks (`ara_sequencer.sv`)**:
   - Preserve concurrent element-chained execution across lanes when producer and consumer access aligned register groups at matching element widths (`base_reg` aligned, `vstart == 0`, sequential per-element VRF read/write pacing).
   - Stall issue (`ara_req_ready_o = 0`) until conflicting older instructions retire whenever lane `operand_requester` write-pulse counting cannot safely pace the dependency: instructions lacking element-rate VRF source queues (`!(use_vs1 || use_vs2 || use_vd_op)`), non-linear/cross-lane permutations, indexed memory operations, or reductions (`VSLIDEUP`, `VSLIDEDOWN`, `VRGATHER`, `VRGATHEREI16`, `VCOMPRESS`, `VLXE`, `VSXE`, reductions), mask-unit bit-packed producers, `v0` mask RAW/WAR hazards, widening/narrowing width-mismatched overlaps, or partial/offset register-group overlaps (`base_C != base_P`).
3. **VFU Instruction-Queue Capacity & Scalar Response Multiplexing (`ara_sequencer.sv`)**:
   - Never exceed `InsnQueueDepth` in-flight instructions on any target VFU (including `MaskuInsnQueueDepth = 1` shared by mask-unit operations and masked `vm == 0` instructions) or leak stale priority-pass state across subsequent instructions or `WAIT`-state handshakes.
   - At top level (`ara.sv`), `pe_scalar_resp_i`/`pe_scalar_resp_valid_i` muxes `MASKU`'s scalar output when `pe_req_o.op` is `VCPOP`/`VFIRST` and Lane-0 `MaskB` otherwise, while `pe_scalar_resp_ready_o` pops Lane-0 `MaskB`. Prevent `vmv.x.s`/`vfmv.f.s` from colliding with or sampling `MaskB` traffic of an active `MASKU` instruction (popping `MaskB` once when retiring `vmv.x.s`/`vfmv.f.s`), while retiring `vcpop.m`/`vfirst.m` cleanly without popping `MaskB` or self-deadlocking on its own mask-unit occupancy.
4. **Zero-Length No-Op Retirement & `OpcodeSystem` CSR Ordering (`ara_dispatcher.sv`)**:
   - Retire zero-trip vector instructions (`vstart >= vl`, `vl == 0`, or `vslideup` with `stride >= vl`, except whole-register moves, scalar-return `VWXUNARY0` ops, and `vset*` configuration ops) before triggering `RESHUFFLE` micro-ops or updating per-register `EEW` state.
   - Drain all buffered/in-flight vector instructions (`ara_idle_i && !ara_req_valid_o`) and final-cycle `vxsat`/`fflags` flag updates before retiring `OpcodeSystem` CSR accesses (even immediately after an earlier `WAIT_IDLE` transition), and extract architectural `vxrm` (`[1:0]` / `[2:1]`) and `vxsat` (`[0]`) bits accurately across register and immediate CSR instructions (`csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, `csrrci`) on `CSR_VXRM`, `CSR_VXSAT`, and `CSR_VCSR`.

## Deliverable Constraints

- Modify **only** `code/ara_sequencer.sv` and `code/ara_dispatcher.sv`; preserve all module names, parameters, and port signatures.
- All RTL must be strictly synthesizable (`yosys -m slang` clean elaboration with zero inferred latches).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Elaboration Guide

## Toolchain Paths
- **Verilator**: `verilator`
- **Yosys (+ slang)**: `yosys`

## Editable RTL
- `code/ara_sequencer.sv`
- `code/ara_dispatcher.sv`

## Compile Order (`-Icode/include`)
```bash
RTL_SRCS=(
  code/config_pkg.sv
  code/cv64a6_imafdcv_sv39_config_pkg.sv
  code/build_config_pkg.sv
  code/riscv_pkg.sv
  code/cf_math_pkg.sv
  code/axi_pkg.sv
  code/fpnew_pkg.sv
  code/rvv_pkg.sv
  code/ara_pkg.sv
  code/onehot_to_bin.sv
  code/lzc.sv
  code/popcount.sv
  code/counter.sv
  code/delta_counter.sv
  code/fall_through_register.sv
  code/spill_register_flushable.sv
  code/spill_register.sv
  code/stream_register.sv
  code/fifo_v3.sv
  code/rr_arb_tree.sv
  code/stream_arbiter_flushable.sv
  code/stream_arbiter.sv
  code/stream_demux.sv
  code/stream_mux.sv
  code/stream_xbar.sv
  code/axi_cut.sv
  code/segment_sequencer.sv
  code/ara_dispatcher.sv
  code/ara_sequencer.sv
  code/lane/lane_sequencer.sv
  code/lane/operand_requester.sv
)
```

### Verilator Lint / Elaboration Check
```bash
verilator \
  --lint-only -Wno-fatal -Wno-ENUMVALUE -DSYNTHESIS -Icode/include --top-module ara_sequencer "${RTL_SRCS[@]}"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ara_sequencer.sv (Buggy Starter)
+++ b/solution/gold/code/ara_sequencer.sv (Golden Reference)
@@ -1,37 +1,26 @@
 // Copyright 2021 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
-// Description:
-// Ara's sequencer controls the ordering and the dependencies between the
-// parallel vector instructions in execution.
 
 module ara_sequencer import ara_pkg::*; import rvv_pkg::*; import cf_math_pkg::idx_width; #(
-    // RVV Parameters
-    parameter  int unsigned NrLanes     = 1,          // Number of parallel vector lanes
+    parameter  int unsigned NrLanes     = 1,
     parameter  int unsigned VLEN        = 0,
     parameter  type         ara_req_t   = logic,
     parameter  type         ara_resp_t  = logic,
     parameter  type         pe_req_t    = logic,
     parameter  type         pe_resp_t   = logic,
     parameter  type         exception_t = logic,
-    // Dependant parameters. DO NOT CHANGE!
-    // Ara has NrLanes + 3 processing elements: each one of the lanes, the vector load unit, the
-    // vector store unit, the slide unit, and the mask unit.
     localparam int unsigned NrPEs   = NrLanes + 4,
     localparam type         vlen_t  = logic[$clog2(VLEN+1)-1:0]
   ) (
     input  logic                            clk_i,
     input  logic                            rst_ni,
-    // Interface with Ara's dispatcher
     input  ara_req_t                        ara_req_i,
     input  logic                            ara_req_valid_i,
     output logic                            ara_req_ready_o,
     output ara_resp_t                       ara_resp_o,
     output logic                            ara_resp_valid_o,
     output logic                            ara_idle_o,
-    // Interface with the processing elements
     output pe_req_t                         pe_req_o,
     output logic                            pe_req_valid_o,
     output logic              [NrVInsn-1:0] pe_vinsn_running_o,
@@ -39,42 +28,27 @@
     input  pe_resp_t            [NrPEs-1:0] pe_resp_i,
     input  logic                            alu_vinsn_done_i,
     input  logic                            mfpu_vinsn_done_i,
-    // Interface with the operand requesters
     output logic [NrVInsn-1:0][NrVInsn-1:0] global_hazard_table_o,
-    // Only the slide unit can answer with a scalar response
     input  elen_t                           pe_scalar_resp_i,
     input  logic                            pe_scalar_resp_valid_i,
     output logic                            pe_scalar_resp_ready_o,
-    // Interface with the Address Generation
     input  logic                            addrgen_ack_i,
     input  exception_t                      addrgen_exception_i,
     input  vlen_t                           addrgen_exception_vstart_i,
     input  logic                            addrgen_fof_exception_i,
-    // Interface with the store unit
     input  logic                            lsu_current_burst_exception_i
   );
 
   `include "common_cells/registers.svh"
 
-  ///////////////////////////////////
-  //  Running vector instructions  //
-  ///////////////////////////////////
-
-  // A set bit indicates that the corresponding vector instruction is running at that PE.
   logic [NrPEs-1:0][NrVInsn-1:0] pe_vinsn_running_d, pe_vinsn_running_q;
-
-  // A set bit indicates that the corresponding vector instruction in running somewhere in Ara.
-  logic [NrVInsn-1:0] vinsn_running_d, vinsn_running_q;
-  vid_t               vinsn_id_n;
-  logic               vinsn_running_full;
-
-  // NrLanes bits that indicate if the sequencer must stall because of a lane desynchronization.
-  logic [NrVInsn-1:0] stall_lanes_desynch_vec;
-  logic               stall_lanes_desynch;
-  // Transpose the matrix, as vertical slices are not allowed in System Verilog
+  logic [NrVInsn-1:0]            vinsn_running_d, vinsn_running_q;
+  vid_t                          vinsn_id_n;
+  logic                          vinsn_running_full;
+  logic [NrVInsn-1:0]            stall_lanes_desynch_vec;
+  logic                          stall_lanes_desynch;
   logic [NrVInsn-1:0][NrPEs-1:0] pe_vinsn_running_q_trns;
 
-  // Ara is idle if no instruction is currently running on it.
   assign ara_idle_o = !(|vinsn_running_q);
 
   lzc #(.WIDTH(NrVInsn)) i_next_id (
@@ -86,7 +60,7 @@
   always_comb begin: p_vinsn_running
     vinsn_running_d = '0;
     for (int unsigned pe = 0; pe < NrPEs; pe++) vinsn_running_d |= pe_vinsn_running_d[pe];
-  end: p_vinsn_running
+  end
 
   always_ff @(posedge clk_i or negedge rst_ni) begin: p_vinsn_running_ff
     if (!rst_ni) begin
@@ -100,144 +74,89 @@
 
   assign pe_vinsn_running_o = vinsn_running_q;
 
-  // Transpose the matrix
   for (genvar r = 0; r < NrVInsn; r++) begin : gen_trans_mtx_r
     for (genvar c = 0; c < NrPEs; c++) begin : gen_trans_mtx_c
       assign pe_vinsn_running_q_trns[r][c] = pe_vinsn_running_q[c][r];
     end
   end
 
-  // Stall the sequencer if the lanes get de-synchronized
-  // and lane 0 is no more the last lane to finish the operation.
-  // This is because the instruction counters for ALU and MFPU refers
-  // to lane 0. If lane 0 finishes before the other lanes, the counter
-  // is not reflecting the real lane situations anymore.
   for (genvar i = 0; i < NrVInsn; i++) begin : gen_stall_lane_desynch
     assign stall_lanes_desynch_vec[i] = ~pe_vinsn_running_q[0][i] & |pe_vinsn_running_q_trns[i][NrLanes-1:1];
   end
   assign stall_lanes_desynch = |stall_lanes_desynch_vec;
 
-  /////////////////////////
-  // Global Hazard table //
-  /////////////////////////
-
-  // Global table of the dependencies between instructions
-  //
-  // The row at index N is the hazard vector belonging to instruction N
-  // It indicates all the instruction on which instruction N depends
-  //
-  // For example, with the following table, instruction 3 depends on
-  // instruction 0 and instruction 2
-  //
-  // +--------+--------+--------+--------+--------+
-  // |   -    | Insn 0 | Insn 1 | Insn 2 | Insn 3 |
-  // +--------+--------+--------+--------+--------+
-  // | Insn 0 |      0 |      0 |      0 |      0 |
-  // | Insn 1 |      1 |      0 |      0 |      0 |
-  // | Insn 2 |      0 |      0 |      0 |      0 |
-  // | Insn 3 |      1 |      0 |      1 |      0 |
-  // +--------+--------+--------+--------+--------+
-  //
-  // This information is forwarded to the operand requesters of each lane
-
   logic [NrVInsn-1:0][NrVInsn-1:0] global_hazard_table_d;
-
-  ////////////////////////
-  // Start and End lane //
-  ////////////////////////
 
   pe_req_t pe_req_d;
   logic    pe_req_valid_d;
 
-  // Some units outside the lanes, e.g., the store unit, always need
-  // to receive operands from all the lanes. For this reason,
-  // we need to know if each lane will need to fetch one operand
-  // more (mock operand) to balance the other lane true operands.
-  // With vstart != 0 and EW != 64bit, this operation is a harder to be done
-  // within the lanes without further help.
-  // Therefore, we calculate here the start and end lanes, i.e., the lanes
-  // that respectively will provide the first and last true element of
-  // the computation.
-  logic [$clog2(NrLanes)-1:0] start_lane, end_lane;
-  // Buffers to simplify the code reading
+  logic [$clog2(NrLanes)-1:0]   start_lane, end_lane;
   logic [$clog2(8*NrLanes)-1:0] buf8;
   logic [$clog2(4*NrLanes)-1:0] buf16;
   logic [$clog2(2*NrLanes)-1:0] buf32;
 
   always_comb begin
-    // start_lane and end_lane has default values in the unique case statement already
-    buf8       = '0;
-    buf16      = '0;
-    buf32      = '0;
-
-    // Start lane
-    // Number of elements in a single L*64-bit fetch: (NrLanes << (64 - pe_req_d.vtype.vsew)).
-    // vstart / (NrLanes << (64 - pe_req_d.vtype.vsew)) -> don't care.
-    // vstart % NrLanes -> our starting lane if:
-    // (vstart % (NrLanes << (64 - pe_req_d.vtype.vsew))) / NrLanes.
-    // Otherwise, the starting lane continues to be the 0th.
-
-    // End lane
-    // Number of elements in a single L*64-bit fetch: (NrLanes << (64 - pe_req_d.vtype.vsew)).
-    // vl / (NrLanes << (64 - pe_req_d.vtype.vsew)) -> don't care.
-    // (vl % NrLanes) - 1 -> our end lane if:
-    // (vl % (NrLanes << (64 - pe_req_d.vtype.vsew)) - 1) / NrLanes.
-    // With the end lane we should subtract 1 since vl represents a number of
-    // elements and NOT an index.
-    unique case (pe_req_d.vtype.vsew)
+    buf8  = '0;
+    buf16 = '0;
+    buf32 = '0;
+    unique case (ara_req_i.vtype.vsew)
       EW8: begin
-        start_lane = &pe_req_d.vstart[$clog2(8*NrLanes)-1:$clog2(NrLanes)]
-                   ? pe_req_d.vstart[$clog2(NrLanes)-1:0]
-                   : '0;
-        buf8       = pe_req_d.vl[$clog2(8*NrLanes)-1:0] - 1;
+        start_lane = &ara_req_i.vstart[$clog2(8*NrLanes)-1:$clog2(NrLanes)]
+                   ? ara_req_i.vstart[$clog2(NrLanes)-1:0] : '0;
+        buf8       = ara_req_i.vl[$clog2(8*NrLanes)-1:0] - 1;
         end_lane   = !(|buf8[$clog2(8*NrLanes)-1:$clog2(NrLanes)])
-                   ? pe_req_d.vl[$clog2(NrLanes)-1:0] - 1
-                   : '1;
+                   ? ara_req_i.vl[$clog2(NrLanes)-1:0] - 1 : '1;
       end
       EW16: begin
-        start_lane = &pe_req_d.vstart[$clog2(4*NrLanes)-1:$clog2(NrLanes)]
-                   ? pe_req_d.vstart[$clog2(NrLanes)-1:0]
-                   : '0;
-        buf16      = pe_req_d.vl[$clog2(4*NrLanes)-1:0] - 1;
+        start_lane = &ara_req_i.vstart[$clog2(4*NrLanes)-1:$clog2(NrLanes)]
+                   ? ara_req_i.vstart[$clog2(NrLanes)-1:0] : '0;
+        buf16      = ara_req_i.vl[$clog2(4*NrLanes)-1:0] - 1;
         end_lane   = !(|buf16[$clog2(4*NrLanes)-1:$clog2(NrLanes)])
-                   ? pe_req_d.vl[$clog2(NrLanes)-1:0] - 1
-                   : '1;
+                   ? ara_req_i.vl[$clog2(NrLanes)-1:0] - 1 : '1;
       end
       EW32: begin
-        start_lane = &pe_req_d.vstart[$clog2(2*NrLanes)-1:$clog2(NrLanes)]
-                   ? pe_req_d.vstart[$clog2(NrLanes)-1:0]
-                   : '0;
-        buf32      = pe_req_d.vl[$clog2(2*NrLanes)-1:0] - 1;
+        start_lane = &ara_req_i.vstart[$clog2(2*NrLanes)-1:$clog2(NrLanes)]
+                   ? ara_req_i.vstart[$clog2(NrLanes)-1:0] : '0;
+        buf32      = ara_req_i.vl[$clog2(2*NrLanes)-1:0] - 1;
         end_lane   = !(|buf32[$clog2(2*NrLanes)-1:$clog2(NrLanes)])
-                   ? pe_req_d.vl[$clog2(NrLanes)-1:0] - 1
-                   : '1;
+                   ? ara_req_i.vl[$clog2(NrLanes)-1:0] - 1 : '1;
       end
-      // EW64, default
       default: begin
-        start_lane = pe_req_d.vstart[$clog2(NrLanes)-1:0];
-        end_lane   = pe_req_d.vl[$clog2(NrLanes)-1:0] - 1;
+        start_lane = ara_req_i.vstart[$clog2(NrLanes)-1:0];
+        end_lane   = ara_req_i.vl[$clog2(NrLanes)-1:0] - 1;
       end
     endcase
   end
 
-  /////////////////
-  //  Sequencer  //
-  /////////////////
-
-  // If the instruction requires an answer to Ariane, the sequencer needs to wait.
   enum logic { IDLE, WAIT } state_d, state_q;
 
-  // For hazard detection, we need to know which vector instruction is reading/writing to each
-  // vector register
+  // Register-indexed multi-vid bitmaps + per-vid chaining metadata
+  logic [31:0][NrVInsn-1:0] vreg_write_d, vreg_write_q;
+  logic [31:0][NrVInsn-1:0] vreg_read_vs1_d, vreg_read_vs1_q;
+  logic [31:0][NrVInsn-1:0] vreg_read_vs2_d, vreg_read_vs2_q;
+  logic [31:0][NrVInsn-1:0] vreg_read_vd_d,  vreg_read_vd_q;
+  logic [NrVInsn-1:0]       vmask_read_d,    vmask_read_q;
+
   typedef struct packed {
-    vid_t vid;
-    logic valid;
-  } vreg_access_t;
-  vreg_access_t [31:0] read_list_d, read_list_q;
-  vreg_access_t [31:0] write_list_d, write_list_q;
-
-  // This function determines the VFU responsible for handling this operation.
-  function automatic vfu_e vfu(ara_op_e op`ifndef SYNTHESIS = VADD `endif);
+    logic [4:0]    base_vd;
+    logic [4:0]    base_vs1;
+    logic [4:0]    base_vs2;
+    rvv_pkg::vew_e eew_vd;
+    rvv_pkg::vew_e eew_vs1;
+    rvv_pkg::vew_e eew_vs2;
+    rvv_pkg::vew_e eew_vd_op;
+    logic          use_vd;
+    logic          use_vs1;
+    logic          use_vs2;
+    logic          use_vd_op;
+    logic          linear_wr;
+    logic          linear_rd;
+  } vinsn_meta_t;
+  vinsn_meta_t [NrVInsn-1:0] vinsn_meta_d, vinsn_meta_q;
+
+  logic [NrVInsn-1:0] masku_vfu_running_d, masku_vfu_running_q;
+
+  function automatic vfu_e vfu(ara_op_e op);
     unique case (op) inside
       [VADD:VWREDSUM]      : vfu = VFU_Alu;
       [VMUL:VFWREDOSUM]    : vfu = VFU_MFpu;
@@ -248,11 +167,8 @@
       [VMVXS:VFMVFS]       : vfu = VFU_None;
       default              : vfu = VFU_None;
     endcase
-  endfunction : vfu
-
-  // This function determines all the targets VFUs of this operation and returns
-  // a vector. Asserted bits correspond to target VFUs. Unluckily, Verilator does
-  // not support assignment patterns with enum types on the indices
+  endfunction
+
   function automatic logic [NrVFUs-1:0] target_vfus(ara_op_e op);
     target_vfus = '0;
     unique case (op) inside
@@ -289,12 +205,49 @@
       [VMVXS:VFMVFS]:
         for (int i = 0; i < NrVFUs; i++)
           if (i == VFU_None) target_vfus[i] = 1'b1;
+      default:;
     endcase
-  endfunction : target_vfus
-
-  // Determine if the request does not need source operands from the VRF
+  endfunction
+
   function automatic logic no_src_vrf(pe_req_t pe_req);
     no_src_vrf = ((pe_req.op == VLE || pe_req.op == VLSE) && pe_req.vm);
+  endfunction
+
+  function automatic int unsigned nregs_from_steps(int steps);
+    if (steps <= 0) return 1;
+    if (steps == 1) return 2;
+    if (steps == 2) return 4;
+    return 8;
+  endfunction
+
+  function automatic int unsigned calc_nregs_vd(ara_req_t req);
+    if (!req.use_vd) return 0;
+    if (req.op inside {[VMFEQ:VMSIF], [VMANDNOT:VMXNOR], [VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) return 1;
+    return nregs_from_steps(int'(signed'(req.emul)));
+  endfunction
+
+  function automatic int unsigned calc_nregs_vs1(ara_req_t req);
+    if (!req.use_vs1) return 0;
+    if (req.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMANDNOT:VMXNOR], VCOMPRESS}) return 1;
+    if (req.op inside {[VSE:VSXE]}) return nregs_from_steps(int'(signed'(req.emul)));
+    if (req.op == VRGATHEREI16) return nregs_from_steps(int'(signed'(req.vtype.vlmul)) + int'(EW16) - int'(req.vtype.vsew));
+    if (req.op inside {[VMFEQ:VMSBC]}) return nregs_from_steps(int'(signed'(req.vtype.vlmul)));
+    if (req.cvt_resize == CVT_WIDE) return nregs_from_steps(int'(signed'(req.emul)) - 1);
+    return nregs_from_steps(int'(signed'(req.emul)));
+  endfunction
+
+  function automatic int unsigned calc_nregs_vs2(ara_req_t req);
+    if (!req.use_vs2) return 0;
+    if (req.op inside {[VMSBF:VIOTA], [VMANDNOT:VMXNOR], [VMVXS:VFMVFS], VCPOP, VFIRST}) return 1;
+    if (req.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM], [VMFEQ:VMSBC]}) return nregs_from_steps(int'(signed'(req.vtype.vlmul)));
+    if (req.op inside {VLXE, VSXE}) return nregs_from_steps(int'(signed'(req.vtype.vlmul)) + int'(req.eew_vs2) - int'(req.vtype.vsew));
+    if (req.op inside {VRGATHER, VRGATHEREI16, VCOMPRESS, VSLIDEUP, VSLIDEDOWN}) return nregs_from_steps(int'(signed'(req.emul)));
+    if (req.conversion_vs2 inside {OpQueueConversionZExt8, OpQueueConversionSExt8}) return nregs_from_steps(int'(signed'(req.emul)) - 3);
+    if (req.conversion_vs2 inside {OpQueueConversionZExt4, OpQueueConversionSExt4}) return nregs_from_steps(int'(signed'(req.emul)) - 2);
+    if (req.cvt_resize == CVT_WIDE)
+      return (req.eew_vs2 == req.vtype.vsew) ? nregs_from_steps(int'(signed'(req.emul))) : nregs_from_steps(int'(signed'(req.emul)) - 1);
+    if (int'(req.eew_vs2) > int'(req.vtype.vsew)) return nregs_from_steps(int'(signed'(req.emul)) + 1);
+    return nregs_from_steps(int'(signed'(req.emul)));
   endfunction
 
   localparam int unsigned InsnQueueDepth [NrVFUs] = '{
@@ -307,131 +260,159 @@
     NoneInsnQueueDepth
   };
 
-  logic ara_req_token_d, ara_req_token_q;
-
-  // Counters keep track of how many instructions each unit is running.
-  // They have the same size only to keep the code easy.
-  logic [NrVFUs-1:0] [idx_width(MaxVInsnQueueDepth + 1)-1:0] insn_queue_cnt_q;
+  logic [NrVFUs-1:0][idx_width(MaxVInsnQueueDepth + 1)-1:0] insn_queue_cnt_q;
   logic [NrVFUs-1:0] insn_queue_done;
   logic [NrVFUs-1:0] insn_queue_cnt_en, insn_queue_cnt_down, insn_queue_cnt_up;
-  // Each FU has its own ready signal
-  logic [NrVFUs-1:0] vinsn_queue_ready;
-  // Bit [i] is 1'b1 if the respective PE is ready for the issue of this insn
   logic [NrVFUs-1:0] vinsn_queue_issue;
-  logic              accepted_insn, accepted_insn_stalled;
   logic [NrVFUs-1:0] target_vfus_vec;
-  // Gold tickets and passes
-  // Normally, instructions can be issued to the lane sequencer only if
-  // the counters have not reached their maximum capacity.
-  // When an instruction enters the main sequencer, it can happen that the
-  // counter is already at maximum capacity The instruction is
-  // registered anyway taking the counter beyond the maximum capacity.
-  // In this case, the instruction will get a gold ticket, to witness that
-  // it was already registered with the counter, so that the instruction can
-  // pass the checks when the counter returns within its limits, even if
-  // it is at its maximum capacity (the instruction was already counted!)
-  logic [NrVFUs-1:0] gold_ticket_d, gold_ticket_q;
-  logic [NrVFUs-1:0] priority_pass;
-
-  // Signal to know if there is a mask instruction being executed by the MASKU
-  // that can use the MaskB operand queue. If there is a running MASKU instruction,
-  // we cannot sample the scalar operand.
-  // Since the scalar move uses the MaskB opqueue, we need to wait to finish
-  // the MASKU insn to be sure that the forwarded value is the scalar one
-  logic running_mask_insn_d, running_mask_insn_q;
+  logic              insn_issue_fire;
 
   logic lsu_current_burst_exception_q;
   `FF(lsu_current_burst_exception_q, lsu_current_burst_exception_i, 1'b0, clk_i, rst_ni);
 
-  // pe_req_ready_i comes from all the lanes
-  // It is deasserted if the current request is stuck
-  // because the target operand requesters are not ready in that lane
   logic [NrLanes-1:0] operand_requester_ready;
   assign operand_requester_ready = pe_req_ready_i[NrLanes-1:0];
 
-  // Update the token only upon new instructions
-  assign ara_req_token_d = (ara_req_valid_i) ? ara_req_i.token : ara_req_token_q;
-
   always_comb begin: p_sequencer
-    // Default assignments
+    automatic int unsigned nr_vd, nr_vs1, nr_vs2;
+    automatic logic [NrVInsn-1:0] raw_vs1, raw_vs2, raw_vd_op, raw_vm;
+    automatic logic [NrVInsn-1:0] waw_vd, war_vs1, war_vs2, war_vd_op, war_vm;
+    automatic logic               c_linear_consumer, c_linear_writer, must_stall_hazard;
+
     state_d               = state_q;
     pe_vinsn_running_d    = pe_vinsn_running_q;
-    read_list_d           = read_list_q;
-    write_list_d          = write_list_q;
+    vreg_write_d          = vreg_write_q;
+    vreg_read_vs1_d       = vreg_read_vs1_q;
+    vreg_read_vs2_d       = vreg_read_vs2_q;
+    vreg_read_vd_d        = vreg_read_vd_q;
+    vmask_read_d          = vmask_read_q;
+    vinsn_meta_d          = vinsn_meta_q;
     global_hazard_table_d = global_hazard_table_o;
-
-    // Maintain request
-    pe_req_d       = '0;
-    pe_req_valid_d = 1'b0;
-
-    // No response
-    ara_resp_o       = '0;
-    ara_resp_valid_o = 1'b0;
-
-    // Always ready to receive a new request
-    ara_req_ready_o = 1'b1;
-
-    // Not ready by default
+    masku_vfu_running_d   = masku_vfu_running_q & ~pe_resp_i[NrLanes+OffsetMask].vinsn_done;
+
+    pe_req_d               = '0;
+    pe_req_valid_d         = 1'b0;
+    ara_resp_o             = '0;
+    ara_resp_valid_o       = 1'b0;
+    ara_req_ready_o        = 1'b1;
     pe_scalar_resp_ready_o = 1'b0;
-
-    // Update vector register's access list
+    insn_issue_fire        = 1'b0;
+
+    nr_vd  = calc_nregs_vd(ara_req_i);
+    nr_vs1 = calc_nregs_vs1(ara_req_i);
+    nr_vs2 = calc_nregs_vs2(ara_req_i);
+
+    raw_vs1           = '0;
+    raw_vs2           = '0;
+    raw_vd_op         = '0;
+    raw_vm            = '0;
+    waw_vd            = '0;
+    war_vs1           = '0;
+    war_vs2           = '0;
+    war_vd_op         = '0;
+    war_vm            = '0;
+    c_linear_consumer = 1'b0;
+    c_linear_writer   = 1'b0;
+    must_stall_hazard = 1'b0;
+
+    for (int pe = 0; pe < NrPEs; pe++) pe_vinsn_running_d[pe] &= ~pe_resp_i[pe].vinsn_done;
+
     for (int unsigned v = 0; v < 32; v++) begin
-      read_list_d[v].valid &= vinsn_running_q[read_list_q[v].vid] ;
-      write_list_d[v].valid &= vinsn_running_q[write_list_q[v].vid];
+      vreg_write_d[v]    &= vinsn_running_q;
+      vreg_read_vs1_d[v] &= vinsn_running_q;
+      vreg_read_vs2_d[v] &= vinsn_running_q;
+      vreg_read_vd_d[v]  &= vinsn_running_q;
     end
-
-    // Update the running vector instructions
-    for (int pe = 0; pe < NrPEs; pe++) pe_vinsn_running_d[pe] &= ~pe_resp_i[pe].vinsn_done;
+    vmask_read_d &= vinsn_running_q;
 
     case (state_q)
       IDLE: begin
-        // Sent a request, but the operand requesters are not ready
-        // Do not trap here the instructions that do not need any operands at all
         if (pe_req_valid_o && !(&operand_requester_ready || no_src_vrf(pe_req_o))) begin
-          // Maintain output
-          pe_req_d               = pe_req_o;
-          pe_req_valid_d         = pe_req_valid_o;
-
-          // If we are here after a faulty lsu op with VRF sources,
-          // wait until the lsu signals the exception on the current burst before aborting the request.
+          pe_req_d       = pe_req_o;
+          pe_req_valid_d = pe_req_valid_o;
           if (lsu_current_burst_exception_q)
             pe_req_valid_d = 1'b0;
-
-          // We are not ready
           ara_req_ready_o = 1'b0;
-        // Received a new request
         end else if (ara_req_valid_i) begin
-          // The target PE is ready, and we can handle another running vector instruction
-          // Let instructions with priority pass be issued
-          if (&vinsn_queue_issue && !stall_lanes_desynch && !vinsn_running_full) begin
-            ///////////////
-            //  Hazards  //
-            ///////////////
-
-            // RAW
-            if (ara_req_i.use_vs1) pe_req_d.hazard_vs1[write_list_d[ara_req_i.vs1].vid] |=
-              write_list_d[ara_req_i.vs1].valid;
-            if (ara_req_i.use_vs2) pe_req_d.hazard_vs2[write_list_d[ara_req_i.vs2].vid] |=
-              write_list_d[ara_req_i.vs2].valid;
-            if (!ara_req_i.vm) pe_req_d.hazard_vm[write_list_d[VMASK].vid] |=
-              write_list_d[VMASK].valid;
-
-            // WAR
-            if (ara_req_i.use_vd) begin
-              pe_req_d.hazard_vs1[read_list_d[ara_req_i.vd].vid] |= read_list_d[ara_req_i.vd].valid;
-              pe_req_d.hazard_vs2[read_list_d[ara_req_i.vd].vid] |= read_list_d[ara_req_i.vd].valid;
-              pe_req_d.hazard_vm[read_list_d[ara_req_i.vd].vid] |= read_list_d[ara_req_i.vd].valid;
+          if (&vinsn_queue_issue && !stall_lanes_desynch && !vinsn_running_full &&
+              !((ara_req_i.op inside {[VMVXS:VFMVFS]}) && (|masku_vfu_running_d))) begin
+
+            for (int unsigned k = 0; k < 8; k++) begin
+              if (ara_req_i.use_vs1 && (k < nr_vs1) && ((int'(ara_req_i.vs1) + k) < 32))
+                raw_vs1 |= vreg_write_d[ara_req_i.vs1 + k[4:0]];
+              if (ara_req_i.use_vs2 && (k < nr_vs2) && ((int'(ara_req_i.vs2) + k) < 32))
+                raw_vs2 |= vreg_write_d[ara_req_i.vs2 + k[4:0]];
+              if (ara_req_i.use_vd_op && (k < nr_vd) && ((int'(ara_req_i.vd) + k) < 32))
+                raw_vd_op |= vreg_write_d[ara_req_i.vd + k[4:0]];
+              if (ara_req_i.use_vd && (k < nr_vd) && ((int'(ara_req_i.vd) + k) < 32)) begin
+                waw_vd    |= vreg_write_d[ara_req_i.vd + k[4:0]];
+                war_vs1   |= vreg_read_vs1_d[ara_req_i.vd + k[4:0]];
+                war_vs2   |= vreg_read_vs2_d[ara_req_i.vd + k[4:0]];
+                war_vd_op |= vreg_read_vd_d[ara_req_i.vd + k[4:0]];
+              end
             end
-
-            // WAW
-            if (ara_req_i.use_vd) pe_req_d.hazard_vd[write_list_d[ara_req_i.vd].vid] |=
-              write_list_d[ara_req_i.vd].valid;
-
-            /////////////
-            //  Issue  //
-            /////////////
-
-            // Populate the PE request
+            if (!ara_req_i.vm)
+              raw_vm |= vreg_write_d[VMASK];
+            if (ara_req_i.use_vd && (ara_req_i.vd == VMASK))
+              wa
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ara_dispatcher.sv`](environment/public/code/ara_dispatcher.sv) **(Editable)**
- [`environment/public/code/ara_pkg.sv`](environment/public/code/ara_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ara_sequencer.sv`](environment/public/code/ara_sequencer.sv) **(Editable)**
- [`environment/public/code/axi_cut.sv`](environment/public/code/axi_cut.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/build_config_pkg.sv`](environment/public/code/build_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/counter.sv`](environment/public/code/counter.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv`](environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/delta_counter.sv`](environment/public/code/delta_counter.sv) *(Read-Only Context)*
- [`environment/public/code/fall_through_register.sv`](environment/public/code/fall_through_register.sv) *(Read-Only Context)*
- [`environment/public/code/fifo_v3.sv`](environment/public/code/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/include/ara/ara_typedef.svh`](environment/public/code/include/ara/ara_typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/ara/intf_typedef.svh`](environment/public/code/include/ara/intf_typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/axi/assign.svh`](environment/public/code/include/axi/assign.svh) *(Read-Only Context)*
- [`environment/public/code/include/axi/typedef.svh`](environment/public/code/include/axi/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/lane/lane_sequencer.sv`](environment/public/code/lane/lane_sequencer.sv) *(Read-Only Context)*
- [`environment/public/code/lane/operand_requester.sv`](environment/public/code/lane/operand_requester.sv) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/onehot_to_bin.sv`](environment/public/code/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/popcount.sv`](environment/public/code/popcount.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/rvv_pkg.sv`](environment/public/code/rvv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/segment_sequencer.sv`](environment/public/code/segment_sequencer.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter.sv`](environment/public/code/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter_flushable.sv`](environment/public/code/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_demux.sv`](environment/public/code/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_mux.sv`](environment/public/code/stream_mux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_register.sv`](environment/public/code/stream_register.sv) *(Read-Only Context)*
- [`environment/public/code/stream_xbar.sv`](environment/public/code/stream_xbar.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

