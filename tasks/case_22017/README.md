# `case_22017`: Resolve Ara Multi-Lane RVV 1.0 Slide Permutation, Power-of-Two Stride Decomposition, Dynamic EEW Reshuffling, and Inter-Lane Reduction Control Across NrLanes = {2, 4, 8}

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22017` |
| **Source Silicon Repository** | `pulp-platform/ara` (`repo_19`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/sldu.sv`](environment/public/code/sldu.sv), [`code/p2_stride_gen.sv`](environment/public/code/p2_stride_gen.sv) (2 files, 984 LOC) |
| **Public Subsystem Context** | 36 RTL files (27060 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Multi-Lane RVV 1.0 Slide Permutation, Stride Decomposition, and Reduction Control in Ara

## Architectural Context

In PULP Ara (`code/sldu.sv`, `code/p2_stride_gen.sv`, `code/sldu_op_dp.sv`, wrapped for verification and synthesis in `code/sldu_subsys_top.sv`), the Slide and Inter-Lane Reduction Unit (`SLDU`) executes RVV 1.0 vector slides (`VSLIDEUP`, `VSLIDEDOWN`, `VSLIDE1UP`, `VSLIDE1DOWN`) and inter-lane reductions across parameterized lane counts (`NrLanes = 2, 4, 8`, `VLEN = 1024`). `p2_stride_gen` decomposes intra-row non-power-of-two slide offsets into sequential power-of-two shifts through `sldu_op_dp`.

Across parameterized `NrLanes = {2, 4, 8}` configurations, multi-row vectors, 64-bit strides, masked slides (`vm == 0`), dynamic `EEW` mismatches (`eew_vs2 != vtype.vsew`), and per-lane backpressure, several control, boundary, and reset bugs cause non-idle post-reset outputs, VRF corruption, operand/mask stream desynchronization, premature `pe_vinsn_done_o` retirement, or pipeline deadlocks.

## Functional & Physical Requirements

1. **`p2_stride_gen` Reset & Power-of-Two Decomposition (`code/p2_stride_gen.sv`)**:
   - Immediately after reset (`!rst_ni`), when idle prior to `valid_i`, or when loaded with `stride_i == 0`, `valid_o`, `stride_p2_o`, and `popc_o` must all be `0` (4-state X-free).
   - When `valid_i` asserts (`valid_i` takes priority if `update_i` is simultaneously high), latch `stride_i` and emit each nonzero bit from least-significant power-of-two (`stride_p2_o`) to most-significant on successive `update_i` cycles, driving `popc_o` equal to the number of remaining nonzero bits (`>= 1` while `valid_o == 1`) and clearing `valid_o = 0`, `stride_p2_o = 0`, `popc_o = 0` after the final bit is updated.

2. **RVV 1.0 Slide Semantics, Exact Stream Beat Counts & `EEW` Reshuffling (`code/sldu.sv`)**:
   - **`VSLIDEUP` (`!use_scalar_op`)**: Evaluate full unsigned 64-bit `pe_req_i.stride` against `vl` without shift overflow or truncation. When `vl == 0` or `stride >= vl`, leave the VRF undisturbed, consume **0** `sldu_operand_i` beats and **0** `mask_i` beats, issue **0** VRF write requests, and retire `pe_vinsn_done_o[id]` in order. When `stride < vl`, leave prefix elements `0 <= i < stride` undisturbed (`be == 0`), write active (`vm || v0.mask[i]`) elements `stride <= i < vl` from `vs2[i - stride]`, never write tail bytes `i >= vl` on any row, consume exactly `ceil(((vl - stride)*SEW) / (8*NrLanes))` `sldu_operand_i` row beats per lane, and when `vm == 0` consume exactly one `mask_i` beat per written destination row `[floor((stride*SEW)/(8*NrLanes)) .. floor((vl*SEW - 1)/(8*NrLanes))]` (gated on `|mask_valid_i`).
   - **`VSLIDEDOWN` (`!use_scalar_op`)**: Compute `vlmax = ((VLEN/8) * LMUL) >> vsew` (`vlmax_bytes = (VLEN/8) * LMUL`) across `LMUL_1_8 .. LMUL_8`. For active elements `0 <= i < vl`, write `vs2[i + stride]` when unsigned 64-bit `i + stride < vlmax`, and write `0` when `i + stride >= vlmax`. Consume **0** `sldu_operand_i` beats when `stride >= vlmax`, and otherwise consume only the `ceil((in_off + min(vl*SEW, vlmax_bytes - stride*SEW)) / (8*NrLanes))` in-bounds source row beats (`in_off = (stride*SEW) mod (8*NrLanes)`), plus one `mask_i` beat per destination row `0 .. floor((vl*SEW - 1)/(8*NrLanes))` when `vm == 0`.
   - **`VSLIDE1UP` & `VSLIDE1DOWN` (`use_scalar_op == 1`)**: Write `scalar_op` to element `0` (`VSLIDE1UP`) or element `vl - 1` (`VSLIDE1DOWN`, including across row boundaries such as `vl*SEW = k*(8*NrLanes) + SEW`). When `vl == 1`, consume **0** `sldu_operand_i` beats (`1` `mask_i` beat if `vm == 0`); for `vl > 1`, consume `ceil(((vl - 1)*SEW)/(8*NrLanes))` (`VSLIDE1UP`) or `ceil((vl*SEW)/(8*NrLanes))` (`VSLIDE1DOWN`) source row beats per lane.
   - **Multi-Row P2/NP2 Strides & Dynamic `EEW` Reshuffling**: Support all combinations of row offset and intra-row offset (`0`, power-of-two, and non-power-of-two, regardless of `is_stride_np2`) without loopback/external operand collisions across back-to-back rows or pipelined instructions, and reshuffle incoming `vs2` data from `eew_vs2` to `vtype.vsew` whenever `eew_vs2 != vtype.vsew` across all slide directions and offsets.

3. **Inter-Lane Reductions & In-Order `final_gnt` Commit (`code/sldu.sv`)**:
   - **Unordered Tree Reductions** (`VFU_Alu` / `VFU_MFpu` non-`OSUM` ops): Perform `$clog2(NrLanes) + 1` `EW64` tree-exchange steps on `sldu_red_valid_o` / `sldu_result_gnt_i` (`sldu_result_req_o == 0`), driving `sldu_mux_sel_o` (`ALU_RED` or `MFPU_RED`).
   - **Ordered Reductions** (`VFREDOSUM`, `VFWREDOSUM`): Forward `vl` sequential `EW64` beats one lane at a time from source lane `i mod NrLanes` (`0 <= i < vl`) to target lane `(i + 1) mod NrLanes` (lane `0` on final beat `i == vl - 1`), honoring `sldu_result_gnt_i` backpressure on every beat before asserting `pe_vinsn_done_o[id]`.
   - **In-Order Commit & Skewed Lane Backpressure**: Handle pipelined instructions (`id` in `0..NrVInsn-1`) under independent per-lane `sldu_operand_valid_i`, `sldu_result_gnt_i`, and delayed `sldu_result_final_gnt_i`, asserting `pe_vinsn_done_o[id]` strictly in acceptance order only after all VRF row writes and all corresponding `sldu_result_final_gnt_i` pulses complete.

## Deliverable & Signoff Constraints

- Modify **only** `code/sldu.sv` and `code/p2_stride_gen.sv`; preserve all module names, parameters, and port signatures.
- Must elaborate and synthesize cleanly via `yosys -m slang` across `NrLanes = 2, 4, 8` (`VLEN = 1024`, top `sldu_subsys_top`) with **zero inferred latches** (`proc; opt_clean; check -assert`), pass 4-state gate-level simulation (`NrLanes = 2`), and map cleanly to Nangate45 at `NrLanes = 4, VLEN = 1024` within `60,000.0 um^2` cell area.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Gate-Level, and Timing Signoff Guide

## 1. Workspace Layout & Editable Scope

- **Editable RTL files** (modify **only** these two files):
  - `code/sldu.sv` (`module sldu`)
  - `code/p2_stride_gen.sv` (`module p2_stride_gen`)
- **Read-only RTL & package closure** (`code/`):
  - `code/sldu_subsys_top.sv`: Parameterized verification and synthesis wrapper (`NrLanes = 2, 4, 8`, `VLEN = 1024`) instantiating `sldu` (`i_sldu`), `p2_stride_gen`, and `sldu_op_dp`.
  - `code/sldu_op_dp.sv`, `code/lzc.sv`, `code/popcount.sv`, `code/spill_register_flushable.sv`, `code/spill_register.sv`
  - `code/cf_math_pkg.sv`, `code/config_pkg.sv`, `code/cv64a6_imafdcv_sv39_config_pkg.sv`, `code/riscv_pkg.sv`, `code/ariane_pkg.sv`, `code/axi_pkg.sv`, `code/fpnew_pkg.sv`, `code/rvv_pkg.sv`, `code/ara_pkg.sv`, and `code/include/common_cells/{registers.svh,assertions.svh}`
- **Read-only Nangate45 PDK collateral** (`lib/`):
  - `lib/NangateOpenCellLibrary_typical.lib` (`1 ns`, `1 fF`, area in `um^2`)
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## 2. Multi-Parameter Functional Simulation (Verilator)

```bash
FILES="code/cf_math_pkg.sv code/config_pkg.sv code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
  code/rvv_pkg.sv code/ara_pkg.sv code/lzc.sv code/popcount.sv \
  code/spill_register_flushable.sv code/spill_register.sv \
  code/p2_stride_gen.sv code/sldu_op_dp.sv code/sldu.sv code/sldu_subsys_top.sv"

verilator \
  --binary --timing -j 4 -Wno-fatal --top-module tb -Icode/include ${FILES} tb.sv
./obj_dir/Vtb
```

## 3. Multi-Lane Elaboration, Zero-Latch, & 4-State Gate-Level Signoff (`yosys -m slang` + `iverilog`)

Elaborate across `NrLanes = 2, 4, 8` (`VLEN = 1024`) with zero inferred latches and run 4-state gate-level simulation on `NrLanes = 2`:

```bash
TOOLS=/opt/siliconbench/tools
$TOOLS/oss-cad-suite/bin/yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode/include -GNrLanes=2 -GVLEN=1024 --top sldu_subsys_top --ignore-assertions ${FILES};
  hierarchy -check -top sldu_subsys_top; proc; opt_clean; check -assert;
  synth -top sldu_subsys_top -noabc; opt_clean; write_verilog -noattr gl_l2.v
"
$TOOLS/iverilog-v13/bin/iverilog -g2012 -DNRLANES=2 -o gl_l2.vvp \
  $TOOLS/oss-cad-suite/share/yosys/simcells.v gl_l2.v tb_gl.sv
$TOOLS/iverilog-v13/bin/vvp gl_l2.vvp
```

## 4. Nangate45 Mapped Synthesis Signoff (`NrLanes = 4, VLEN = 1024`)

```bash
$TOOLS/oss-cad-suite/bin/yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode/include -GNrLanes=4 -GVLEN=1024 --top sldu_subsys_top --ignore-assertions ${FILES};
  hierarchy -check -top sldu_subsys_top; proc; opt_clean; check -assert;
  synth -top sldu_subsys_top -noabc;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 4800;
  opt_clean; stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr netlist_l4.v
"
```

Sign-off requirements:
1. Zero inferred latches and clean `check -assert` across all `NrLanes = {2, 4, 8}` (`VLEN = 1024`) elaborations.
2. Clean 4-state gate-level simulation (`NrLanes = 2`) with zero `X`/`Z` on control outputs.
3. Mapped Nangate45 cell area at `NrLanes = 4, VLEN = 1024` **`<= 60000.0 um^2`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/sldu.sv (Buggy Starter)
+++ b/solution/gold/code/sldu.sv (Golden Reference)
@@ -1,22 +1,21 @@
-// Copyright 2021 ETH Zurich and University of Bologna.
+// Copyright 2021-2023 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
 //
 // Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
 // Description:
-// This is Ara's slide unit. It is responsible for running the vector slide (up/down)
-// instructions, which need access to the whole Vector Register File.
+// Ara's slide and inter-lane reduction unit (`NrLanes = 2, 4, 8`).
 
 module sldu import ara_pkg::*; import rvv_pkg::*; #(
     parameter  int  unsigned NrLanes   = 0,
     parameter  int  unsigned VLEN      = 0,
-    parameter  type          vaddr_t   = logic, // Type used to address vector register file elements,
+    parameter  type          vaddr_t   = logic,
     parameter  type          pe_req_t  = logic,
     parameter  type          pe_resp_t = logic,
     // Dependant parameters. DO NOT CHANGE!
-    localparam int  unsigned DataWidth = $bits(elen_t), // Width of the lane datapath
+    localparam int  unsigned DataWidth = $bits(elen_t),
     localparam int  unsigned StrbWidth = DataWidth/8,
-    localparam type          strb_t    = logic [StrbWidth-1:0], // Byte-strobe type
+    localparam type          strb_t    = logic [StrbWidth-1:0],
     localparam type          vlen_t    = logic[$clog2(VLEN+1)-1:0]
   ) (
     input  logic                   clk_i,
@@ -51,222 +50,167 @@
 
   import cf_math_pkg::idx_width;
 
+  localparam int unsigned RowBytes        = 8 * NrLanes;
+  localparam int unsigned RowIdxW         = $clog2(RowBytes);
+  localparam int unsigned VInsnQueueDepth = SlduInsnQueueDepth;
+  localparam int unsigned ResultQueueDepth = 2;
+  localparam int unsigned VLenBytes       = VLEN / 8;
+
+  typedef logic [$clog2(VLEN+1):0]   byte_cnt_t;
+  typedef logic [$clog2(VLEN+1):0]   commit_beats_t;
+  typedef logic [idx_width(RowBytes)-1:0] stride_t;
+
+  function automatic byte_cnt_t calc_vlmax_bytes(rvv_pkg::vlmul_e vlmul);
+    unique case (vlmul)
+      rvv_pkg::LMUL_1  : return byte_cnt_t'(VLenBytes);
+      rvv_pkg::LMUL_2  : return byte_cnt_t'(VLenBytes << 1);
+      rvv_pkg::LMUL_4  : return byte_cnt_t'(VLenBytes << 2);
+      rvv_pkg::LMUL_8  : return byte_cnt_t'(VLenBytes << 3);
+      rvv_pkg::LMUL_1_2: return byte_cnt_t'(VLenBytes >> 1);
+      rvv_pkg::LMUL_1_4: return byte_cnt_t'(VLenBytes >> 2);
+      rvv_pkg::LMUL_1_8: return byte_cnt_t'(VLenBytes >> 3);
+      default          : return byte_cnt_t'(VLenBytes);
+    endcase
+  endfunction
+
+  function automatic logic stride_ge_limit(elen_t s, byte_cnt_t lim);
+    return (|s[63:$bits(byte_cnt_t)]) || (s[$bits(byte_cnt_t)-1:0] >= lim);
+  endfunction
+
+  function automatic commit_beats_t calc_commit_beats(pe_req_t req);
+    byte_cnt_t vl_b;
+    byte_cnt_t st_b;
+    byte_cnt_t first_row;
+    byte_cnt_t last_row;
+    if (req.vfu inside {VFU_Alu, VFU_MFpu} ||
+        req.op inside {[VREDSUM:VWREDSUM], [VFREDUSUM:VFWREDOSUM]}) begin
+      if (req.op inside {VFREDOSUM, VFWREDOSUM})
+        return commit_beats_t'(req.vl);
+      else
+        return commit_beats_t'($clog2(NrLanes) + 1);
+    end
+    if (req.vl == '0) return '0;
+    vl_b = byte_cnt_t'(req.vl) << int'(req.vtype.vsew);
+    if (req.op == VSLIDEUP && !req.use_scalar_op) begin
+      if (stride_ge_limit(req.stride, byte_cnt_t'(req.vl))) return '0;
+      st_b      = byte_cnt_t'(req.stride[$bits(byte_cnt_t)-1:0]) << int'(req.vtype.vsew);
+      first_row = st_b >> RowIdxW;
+      last_row  = (vl_b - 1'b1) >> RowIdxW;
+      return commit_beats_t'(last_row - first_row + 1'b1);
+    end else begin
+      last_row = (vl_b - 1'b1) >> RowIdxW;
+      return commit_beats_t'(last_row + 1'b1);
+    end
+  endfunction
+
   ////////////////////////////////
   //  Vector instruction queue  //
   ////////////////////////////////
 
-  // We store a certain number of in-flight vector instructions
-  localparam VInsnQueueDepth = SlduInsnQueueDepth;
-
   struct packed {
-    pe_req_t [VInsnQueueDepth-1:0] vinsn;
-
-    // Each instruction can be in one of the three execution phases.
-    // - Being accepted (i.e., it is being stored for future execution in this
-    //   vector functional unit).
-    // - Being issued (i.e., its micro-operations are currently being issued
-    //   to the corresponding functional units).
-    // - Being committed (i.e., its results are being written to the vector
-    //   register file).
-    // We need pointers to index which instruction is at each execution phase
-    // between the VInsnQueueDepth instructions in memory.
+    pe_req_t       [VInsnQueueDepth-1:0] vinsn;
+    commit_beats_t [VInsnQueueDepth-1:0] beats;
     logic [idx_width(VInsnQueueDepth)-1:0] accept_pnt;
     logic [idx_width(VInsnQueueDepth)-1:0] issue_pnt;
     logic [idx_width(VInsnQueueDepth)-1:0] commit_pnt;
-
-    // We also need to count how many instructions are queueing to be
-    // issued/committed, to avoid accepting more instructions than
-    // we can handle.
-    logic [idx_width(VInsnQueueDepth):0] issue_cnt;
-    logic [idx_width(VInsnQueueDepth):0] commit_cnt;
+    logic [idx_width(VInsnQueueDepth):0]   issue_cnt;
+    logic [idx_width(VInsnQueueDepth):0]   commit_cnt;
   } vinsn_queue_d, vinsn_queue_q;
 
   pe_req_t vinsn_issue_q;
-  logic vinsn_issue_valid_q;
-  // Is the vector instruction queue full?
-  logic vinsn_queue_full;
+  logic    vinsn_issue_valid_q;
+  logic    vinsn_queue_full;
   assign vinsn_queue_full = (vinsn_queue_q.commit_cnt == VInsnQueueDepth);
 
-  // Do we have a vector instruction ready to be issued?
   `FF(vinsn_issue_q, vinsn_queue_d.vinsn[vinsn_queue_d.issue_pnt], '0)
   `FF(vinsn_issue_valid_q, vinsn_queue_d.issue_cnt != '0, 1'b0)
 
-  // Do we have a vector instruction with results being committed?
   pe_req_t vinsn_commit;
   logic    vinsn_commit_valid;
   assign vinsn_commit       = vinsn_queue_q.vinsn[vinsn_queue_q.commit_pnt];
   assign vinsn_commit_valid = (vinsn_queue_q.commit_cnt != '0);
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
-    if (!rst_ni) begin
-      vinsn_queue_q <= '0;
-    end else begin
-      vinsn_queue_q <= vinsn_queue_d;
-    end
+    if (!rst_ni) vinsn_queue_q <= '0;
+    else         vinsn_queue_q <= vinsn_queue_d;
   end
 
   /////////////////////
   //  Result queues  //
   /////////////////////
 
-  localparam int unsigned ResultQueueDepth = 2;
-
-  // There is a result queue per lane, holding the results that were not
-  // yet accepted by the corresponding lane.
   typedef struct packed {
-    vid_t id;
+    vid_t   id;
     vaddr_t addr;
-    elen_t wdata;
-    strb_t be;
+    elen_t  wdata;
+    strb_t  be;
+    logic   is_red;
   } payload_t;
 
-  // Result queue
   payload_t [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_d, result_queue_q;
   logic     [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_valid_d, result_queue_valid_q;
-  // We need two pointers in the result queue. One pointer to
-  // indicate with `payload_t` we are currently writing into (write_pnt),
-  // and one pointer to indicate which `payload_t` we are currently
-  // reading from and writing into the lanes (read_pnt).
   logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_write_pnt_d, result_queue_write_pnt_q;
   logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_read_pnt_d, result_queue_read_pnt_q;
-  // We need to count how many valid elements are there in this result queue.
   logic     [idx_width(ResultQueueDepth):0]     result_queue_cnt_d, result_queue_cnt_q;
-  // Vector to register the final grants from the operand requesters, which indicate
-  // that the result was actually written in the VRF (while the normal grant just says
-  // that the result was accepted by the operand requester stage
-  logic     [NrLanes-1:0]                       result_final_gnt_d, result_final_gnt_q;
-
-  // Is the result queue full?
-  logic result_queue_full;
-  assign result_queue_full = (result_queue_cnt_q == ResultQueueDepth);
-  // Is the result queue empty?
-  logic result_queue_empty;
+  logic     [NrLanes-1:0][2:0]                  final_gnt_pend_d, final_gnt_pend_q;
+
+  logic result_queue_full, result_queue_empty;
+  assign result_queue_full  = (result_queue_cnt_q == ResultQueueDepth);
   assign result_queue_empty = (result_queue_cnt_q == '0);
 
-  always_ff @(posedge clk_i or negedge rst_ni) begin: p_result_queue_ff
+  always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
       result_queue_q           <= '0;
       result_queue_valid_q     <= '0;
       result_queue_write_pnt_q <= '0;
       result_queue_read_pnt_q  <= '0;
       result_queue_cnt_q       <= '0;
+      final_gnt_pend_q         <= '0;
     end else begin
       result_queue_q           <= result_queue_d;
       result_queue_valid_q     <= result_queue_valid_d;
       result_queue_write_pnt_q <= result_queue_write_pnt_d;
       result_queue_read_pnt_q  <= result_queue_read_pnt_d;
       result_queue_cnt_q       <= result_queue_cnt_d;
+      final_gnt_pend_q         <= final_gnt_pend_d;
     end
   end
 
-  ////////////////////////////////
-  //  Spill-reg from the lanes  //
-  ////////////////////////////////
+  ////////////////////////////////////////////
+  //  Input operand & mask staging buffers  //
+  ////////////////////////////////////////////
 
   elen_t [NrLanes-1:0] sldu_operand;
   logic  [NrLanes-1:0] sldu_operand_valid;
   logic  [NrLanes-1:0] sldu_operand_ready;
 
-  // Don't handshake if the operands target the addrgen!
-  // Moreover, when computing NP2 slides, loop over the same data!
-  elen_t [NrLanes-1:0] sldu_operand_d;
-  logic [NrLanes-1:0]  sldu_operand_valid_d;
-  logic [NrLanes-1:0]  sldu_operand_ready_q;
-
-  typedef enum logic {
-    NP2_BUFFER_PNT,
-    NP2_RESULT_PNT
-  } np2_result_queue_pnt_e;
-
-  typedef enum logic {
-    NP2_EXT_SEL,
-    NP2_LOOP_SEL
-  } np2_loop_mux_e;
-  np2_loop_mux_e np2_loop_mux_sel_d, np2_loop_mux_sel_q;
-
-  logic slide_np2_buf_valid_d, slide_np2_buf_valid_q;
-
-  // There are multiple transmitters (TX) (OpQueue, ALU, FPU, SLDU-NP2) and receivers (RX) (SLDU, ADDRGEN).
-  // Hypotheses:
-  // - When valid is asserted on the RX, data cannot change anymore until the handshake happens.
-  // - When valid is received by RX, then DATA is targeting that RX only.
-  // Data and handshakes signals are controlled upstream (TX side) so that this Hypotheses hold.
-
-  for (genvar l = 0; l < NrLanes; l++) begin
+  for (genvar l = 0; l < NrLanes; l++) begin : gen_in_spill
     spill_register #(
       .T(elen_t)
     ) i_sldu_spill_register (
-      .clk_i  (clk_i                      ),
-      .rst_ni (rst_ni                     ),
-      .valid_i(sldu_operand_valid_d[l]    ),
-      .ready_o(sldu_operand_ready_q[l]    ),
-      .data_i (sldu_operand_d[l]          ),
-      .valid_o(sldu_operand_valid[l]      ),
-      .ready_i(sldu_operand_ready[l]      ),
-      .data_o (sldu_operand[l]            )
+      .clk_i  (clk_i                  ),
+      .rst_ni (rst_ni                 ),
+      .valid_i(sldu_operand_valid_i[l]),
+      .ready_o(sldu_operand_ready_o[l]),
+      .data_i (sldu_operand_i[l]      ),
+      .valid_o(sldu_operand_valid[l]  ),
+      .ready_i(sldu_operand_ready[l]  ),
+      .data_o (sldu_operand[l]        )
     );
-
-    assign sldu_operand_d[l] = np2_loop_mux_sel_q == NP2_EXT_SEL
-                             ? sldu_operand_i[l]
-                             : result_queue_q[NP2_BUFFER_PNT][l].wdata;
-
-    assign sldu_operand_valid_d[l] = np2_loop_mux_sel_q == NP2_EXT_SEL
-                                   ? sldu_operand_valid_i[l]
-                                   : slide_np2_buf_valid_q;
-
-    assign sldu_operand_ready_o[l] = np2_loop_mux_sel_q == NP2_EXT_SEL
-                                   ? sldu_operand_ready_q[l]
-                                   : 1'b0;
   end
 
-  //////////////////////////
-  //  Cut from the masku  //
-  //////////////////////////
-
-  strb_t [NrLanes-1:0] mask_q;
-  logic  [NrLanes-1:0] mask_valid_d, mask_valid_q;
-  logic                mask_ready_d;
-  logic  [NrLanes-1:0] mask_ready_q;
-
-  for (genvar l = 0; l < NrLanes; l++) begin
-    spill_register #(
-      .T(strb_t)
-    ) i_mask_operand_register (
-      .clk_i     (clk_i           ),
-      .rst_ni    (rst_ni          ),
-      .data_o    (mask_q[l]       ),
-      .valid_o   (mask_valid_q[l] ),
-      .ready_i   (mask_ready_d    ),
-      .data_i    (mask_i[l]       ),
-      .valid_i   (mask_valid_d[l] ),
-      .ready_o   (mask_ready_q[l] )
-    );
-
-    // Sample only SLDU mask valid
-    assign mask_valid_d[l] = mask_valid_i[l] & ~vinsn_issue_q.vm & vinsn_issue_valid_q;
-  end
-
-
-  // Don't upset the masku with a spurious ready
-  assign mask_ready_o = mask_ready_q[0] & mask_valid_i[0] & ~vinsn_issue_q.vm & vinsn_issue_valid_q & !(vinsn_issue_q.vfu inside {VFU_Alu, VFU_MFpu});
+  strb_t         [NrLanes-1:0] mask_buf_d, mask_buf_q;
+  logic                        mask_buf_valid_d, mask_buf_valid_q;
+  commit_beats_t               mask_rows_rem_d, mask_rows_rem_q;
 
   ///////////////////
   //  NP2 Support  //
   ///////////////////
 
-  // The SLDU only supports powers of two (p2) strides
-  // Decompose the non-power-of-two (np2) slide in multiple p2 slides
-
-  // We implement the np2 support here and fully process every input packet
-  // singularly to comply with the undisturbed policy. We cannot use the VRF
-  // as intermediate buffer; each VRF write is a commit.
-
-  typedef logic [idx_width(8*NrLanes)-1:0] stride_t;
-
   stride_t                                  p2_stride_gen_stride_d;
   logic                                     p2_stride_gen_valid_d;
   logic                                     p2_stride_gen_update_d;
-  logic [idx_width(idx_width(8*NrLanes)):0] p2_stride_gen_popc_q;
+  logic [idx_width(idx_width(RowBytes)):0]  p2_stride_gen_popc_q;
   stride_t                                  p2_stride_gen_stride_q;
   logic                                     p2_stride_gen_valid_q;
 
@@ -287,44 +231,113 @@
   //  Reductions  //
   //////////////////
 
-  // Inter-lane reductions are performed with a logarithmic tree, and the result is
-  // accumulated in the last Lane. Then, in the end, the result is passed to the first
-  // lane for SIMD reduction
   logic [idx_width(NrLanes)-1:0] red_stride_cnt_d, red_stride_cnt_q;
-  logic [idx_width(NrLanes):0] red_stride_cnt_d_wide;
-
-  logic is_issue_reduction, is_issue_alu_reduction, is_issue_vmfpu_reduction;
-
+  logic [idx_width(NrLanes)-1:0] osum_lane_d, osum_lane_q;
+  commit_beats_t                 red_steps_rem_d, red_steps_rem_q;
+
+  logic is_issue_alu_reduction, is_issue_vmfpu_reduction;
   assign is_issue_alu_reduction   = vinsn_issue_valid_q & (vinsn_issue_q.vfu == VFU_Alu);
   assign is_issue_vmfpu_reduction = vinsn_issue_valid_q & (vinsn_issue_q.vfu == VFU_MFpu);
-  assign is_issue_reduction       = is_issue_alu_reduction | is_issue_vmfpu_reduction;
 
   always_comb begin
     sldu_mux_sel_o = NO_RED;
-    if ((is_issue_alu_reduction && !(vinsn_commit_valid && vinsn_commit.vfu != VFU_Alu)) || (vinsn_commit_valid && vinsn_commit.vfu == VFU_Alu)) begin
+    if ((is_issue_alu_reduction && !(vinsn_commit_valid && vinsn_commit.vfu != VFU_Alu)) ||
+        (vinsn_commit_valid && vinsn_commit.vfu == VFU_Alu)) begin
       sldu_mux_sel_o = ALU_RED;
-    end else if ((is_issue_vmfpu_reduction && !(vinsn_commit_valid && vinsn_commit.vfu != VFU_MFpu)) || (vinsn_commit_valid && vinsn_commit.vfu == VFU_MFpu)) begin
+    end else if ((is_issue_vmfpu_reduction && !(vinsn_commit_valid && vinsn_commit.vfu != VFU_MFpu)) ||
+                 (vinsn_commit_valid && vinsn_commit.vfu == VFU_MFpu)) begin
       sldu_mux_sel_o = MFPU_RED;
     end
   end
 
+  ///////////////////////
+  //  State & Buffers  //
+  ///////////////////////
+
+  typedef enum logic [2:0] {
+    SLIDE_IDLE,
+    SLIDE_LOAD_ROW,
+    SLIDE_P2_LOOP,
+    SLIDE_EMIT,
+    SLIDE_RED_UNORD,
+    SLIDE_RED_OSUM
+  } slide_state_e;
+
+  slide_state_e state_d, state_q;
+
+  elen_t         [NrLanes-1:0] work_buf_d, work_buf_q;
+  elen_t         [NrLanes-1:0] row_acc_wdata_d, row_acc_wdata_q;
+  strb_t         [NrLanes-1:0] row_acc_be_d, row_acc_be_q;
+  logic          [NrVInsn-1:0] vinsn_running_d, vinsn_running_q;
+  pe_resp_t                    pe_resp;
+
+  logic [idx_width(RowBytes):0] in_pnt_d, in_pnt_q;
+  logic [idx_width(RowBytes):0] out_pnt_d, out_pnt_q;
+  vaddr_t                       vrf_pnt_d, vrf_pnt_q;
+  byte_cnt_t                    src_rem_d, src_rem_q;
+  byte_cnt_t                    dst_rem_d, dst_rem_q;
+  stride_t                      intra_slamt_d, intra_slamt_q;
+  logic                         sld_dir_d, sld_dir_q;
+  logic                         first_word_d, first_word_q;
+  commit_beats_t                commit_beats_d, commit_beats_q;
+
   /////////////////////
   //  SLDU DataPath  //
   /////////////////////
 
-  // Input/output non-flat operands
-  elen_t [NrLanes-1:0] sld_op_src;
-  elen_t [NrLanes-1:0] sld_op_dst;
-
-  // Input and output eew for reshuffling
-  rvv_pkg::vew_e sld_eew_src;
-  rvv_pkg::vew_e sld_eew_dst;
-
-  // 0: slidedown, 1: slideup
-  logic sld_dir;
-
-  // The SLDU slides by powers of two
-  logic [idx_width(4*NrLanes):0] sld_slamt;
+  elen_t                        [NrLanes-1:0] sld_op_src;
+  elen_t                        [NrLanes-1:0] sld_op_dst;
+  rvv_pkg::vew_e                              sld_eew_src;
+  rvv_pkg::vew_e                              sld_eew_dst;
+  logic                                       sld_dir;
+  logic [idx_width(4*NrLanes):0]              sld_slamt;
+
+  logic [idx_width(idx_width(RowBytes)):0]    intra_slamt_popc;
+  always_comb begin
+    intra_slamt_popc = '0;
+    for (int b = 0; b < $bits(stride_t); b++) begin
+      intra_slamt_popc += intra_slamt_q[b];
+    end
+  end
+
+  // Dedicated combinational block for sldu_op_dp control (avoids false UNOPTFLAT loop)
+  always_comb begin : p_dp_ctrl
+    sld_op_src  = sldu_operand;
+    sld_eew_src = vinsn_issue_q.vtype.vsew;
+    sld_eew_dst = vinsn_issue_q.vtype.vsew;
+    sld_dir     = 1'b0;
+    sld_slamt   = '0;
+
+    unique case (state_q)
+      SLIDE_RED_UNORD: begin
+        sld_op_src  = sldu_operand;
+        sld_eew_src = rvv_pkg::EW64;
+        sld_eew_dst = rvv_pkg::EW64;
+        sld_dir     = 1'b1;
+        sld_slamt   = {{($bits(sld_slamt)-$bits(red_stride_cnt_q)){1'b0}}, red_stride_cnt_q};
+      end
+      SLIDE_LOAD_ROW: begin
+        sld_op_src  = sldu_operand;
+        sld_eew_src = vinsn_issue_q.eew_vs2;
+        sld_eew_dst = vinsn_issue_q.vtype.vsew;
+        if ((vinsn_issue_q.eew_vs2 == vinsn_issue_q.vtype.vsew) && (intra_slamt_popc <= 1)) begin
+          sld_slamt = intra_slamt_q;
+          sld_dir   = (intra_slamt_q == '0) ? 1'b0 : sld_dir_q;
+        end else begin
+          sld_slamt = '0;
+          sld_dir   = 1'b0;
+        end
+      end
+      SLIDE_P2_LOOP: begin
+        sld_op_src  = work_buf_q;
+        sld_eew_src = vinsn_issue_q.vtype.vsew;
+        sld_eew_dst = vinsn_issue_q.vtype.vsew;
+        sld_slamt   = p2_stride_gen_stride_q;
+        sld_dir     = sld_dir_q;
+      end
+      default: ;
+    endcase
+  end
 
   sldu_op_dp #(
     .NrLanes  (NrLanes    )
@@ -341,99 +354,47 @@
   //  Slide unit  //
   //////////////////
 
-  // Vector instructions currently running
-  logic [NrVInsn-1:0] vinsn_running_d, vinsn_running_q;
-
-  // Interface with the main sequencer
-  pe_resp_t pe_resp;
-
-  // State of the slide FSM
-  typedef enum logic [3:0] {
-    SLIDE_IDLE,
-    SLIDE_RUN,
-    SLIDE_RUN_VSLIDE1UP_FIRST_WORD,
-    SLIDE_RUN_OSUM,
-    SLIDE_WAIT_OSUM,
-    SLIDE_NP2_SETUP,
-    SLIDE_NP2_RUN,
-    SLIDE_NP2_COMMIT,
-    SLIDE_NP2_WAIT
-  } slide_state_e;
-  slide_state_e state_d, state_q;
-
-  logic  [8*NrLanes-1:0] out_en_flat, out_en_seq;
-  strb_t [NrLanes-1:0]   out_en;
-
-  // Pointers in the input operand and the output result
-  logic   [idx_width(NrLanes*StrbWidth):0] in_pnt_d, in_pnt_q;
-  logic   [idx_width(NrLanes*StrbWidth):0] out_pnt_d, out_pnt_q;
-  vaddr_t                                  vrf_pnt_d, vrf_pnt_q;
-
-  // Remaining bytes of the current instruction in the issue phase
-  vlen_t issue_cnt_d, issue_cnt_q;
-  // Respected by default: input_limit_d  = 8*NrLanes + out_pnt_d - in_pnt_d;
-  // To enforce: output_limit_d = out_pnt_d + issue_cnt_d;
-  // MAXVL == VLEN (when LMUL == 8, i.e., the maximum possible)
-  logic [idx_width(VLEN+1):0] output_limit_d, output_limit_q;
-
-  // Remaining bytes of the current instruction in the commit phase
-  vlen_t commit_cnt_d, commit_cnt_q;
-
-  always_comb begin: p_sldu
-    // Maintain state
-    vinsn_queue_d = vinsn_queue_q;
-    issue_cnt_d   = issue_cnt_q;
-    commit_cnt_d  = commit_cnt_q;
-    in_pnt_d      = in_pnt_q;
-    out_pnt_d     = out_pnt_q;
-    vrf_pnt_d     = vrf_pnt_q;
-    state_d       = state_q;
+  always_comb begin : p_sldu
+    vinsn_queue_d            = vinsn_queue_q;
+    state_d                  = state_q;
+    work_buf_d               = work_buf_q;
+    row_acc_wdata_d          = row_acc_wdata_q;
+    row_acc_be_d             = row_acc_be_q;
+    vinsn_running_d          = vinsn_running_q & pe_vinsn_running_i;
+
+    in_pnt_d                 = in_pnt_q;
+    out_pnt_d                = out_pnt_q;
+    vrf_pnt_d                = vrf_pnt_q;
+    src_rem_d                = src_rem_q;
+    dst_rem_d                = dst_rem_q;
+    intra_slamt_d            = intra_slamt_q;
+    sld_dir_d                = sld_dir_q;
+    first_word_d             = first_word_q;
+    commit_beats_d           = commit_beats_q;
 
     result_queue_d           = result_queue_q;
     result_queue_valid_d     = result_queue_valid_q;
     result_queue_read_pnt_d  = result_queue_read_pnt_q;
     result_queue_write_pnt_d = result_queue_write_pnt_q;
     result_queue_cnt_d       = result_queue_cnt_q;
-
-    result_final_gnt_d = result_final_gnt_q;
-
-    // Vector instructions currently running
-    vinsn_running_d = vinsn_running_q & pe_vinsn_running_i;
-
-    out_en_flat    = '0;
-    out_en_seq     = '0;
-    out_en         = '0;
-    output_limit_d = output_limit_q;
-
-    // We are not ready, by default
-    pe_resp            = '0;
-    mask_ready_d       = 1'b0;
-    sldu_operand_ready = '0;
-
-    red_stride_cnt_d = red_stride_cnt_q;
-
-    p2_stride_gen_stride_d = '0;
-    p2_stride_gen_valid_d  = 1'b0;
-    p2_stride_gen_update_d = 1'b0;
-
-    np2_loop_mux_sel_d    = np2_loop_mux_sel_q;
-    slide_np2_buf_valid_d = slide_np2_buf_valid_q;
-
-    red_stride_cnt_d_wide = {red_stride_cnt_q, red_stride_cnt_q[idx_width(NrLanes)-1]};
-
-    // Inform the main sequencer if we are idle
-    pe_req_ready_o = !vinsn_queue_full;
-
-    // Slide Unit DP
-    sld_op_src  = sldu_operand;
-    sld_eew_src = (vinsn_issue_q.vfu inside {VFU_Alu, VFU_MFpu})
-                ? vinsn_issue_q.vtype.vsew
-                : vinsn_issue_q.eew_vs2;
-    sld_eew_dst = vinsn_issue_q.vtype.vsew;
-    sld_dir     = (vinsn_issue_q.op == VSLIDEUP) || (vinsn_issue_q.vfu inside {VFU_Alu, VFU_MFpu});
-    sld_slamt   = (vinsn_issue_q.vfu inside {VFU_Alu, VFU_MFpu})
-                ? red_stride_cnt_q
-                : stride_t'(vinsn_issue_q.stride >> vinsn_issue_q.vtype.vsew);
+    final_gnt_pend_d         = final_gnt_pend_q;
+
+    mask_buf_d               = mask_buf_q;
+    mask_buf_valid_d         = mask_buf_valid_q;
+    mask_rows_rem_d          = mask_rows_rem_q;
+    mask_ready_o             = 1'b0;
+
+    pe_resp                  = '0;
+    sldu_operand_ready       = '0;
+    pe_req_ready_o           = !vinsn_queue_full;
+
+    red_stride_cnt_d         = red_stride_cnt_q;
+    osum_lane_d              = osum_lane_q;
+    red_steps_rem_d          = red_steps_rem_q;
+
+    p2_stride_gen_stride_d   = '0;
+    p2_stride_gen_valid_d    = 1'b0;
+    p2_stride_gen_update_d   = 1'b0;
 
     /////////////////
     //  Slide FSM  //
@@ -442,405 +403,411 @@
     unique case (state_q)
       SLIDE_IDLE: begin
         if (vinsn_issue_valid_q) begin
-          state_d   = vinsn_issue_q.is_stride_np2 ? SLIDE_NP2_SETUP : SLIDE_RUN;
-          vrf_pnt_d = '0;
-
-          unique case (vinsn_issue_q.op)
-            VSLIDEUP: begin
-              // vslideup starts reading the source operand from its beginning
-              in_pnt_d  = '0;
-              // vslideup starts writing the destination vector at the slide offset
-              out_pnt_d = vinsn_issue_q.stride[idx_width(8*NrLanes)-1:0];
-
-              // Initialize counters
-              issue_cnt_d = vinsn_issue_q.vl << int'(vinsn_issue_q.vtype.vsew);
-
-              // Initialize be-enable-generation ancillary signals
-              output_limit_d = vinsn_issue_q.use_s
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ara_pkg.sv`](environment/public/code/ara_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
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
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/onehot_to_bin.sv`](environment/public/code/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/p2_stride_gen.sv`](environment/public/code/p2_stride_gen.sv) **(Editable)**
- [`environment/public/code/popcount.sv`](environment/public/code/popcount.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/rvv_pkg.sv`](environment/public/code/rvv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sldu.sv`](environment/public/code/sldu.sv) **(Editable)**
- [`environment/public/code/sldu_op_dp.sv`](environment/public/code/sldu_op_dp.sv) *(Read-Only Context)*
- [`environment/public/code/sldu_subsys_top.sv`](environment/public/code/sldu_subsys_top.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter.sv`](environment/public/code/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter_flushable.sv`](environment/public/code/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_demux.sv`](environment/public/code/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_mux.sv`](environment/public/code/stream_mux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_register.sv`](environment/public/code/stream_register.sv) *(Read-Only Context)*
- [`environment/public/code/stream_xbar.sv`](environment/public/code/stream_xbar.sv) *(Read-Only Context)*
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

