# `case_22005`: Implement Ara RVV 1.0 Multi-Lane Mask Bit-Scan, Population Count, and Prefix-Sum Engine

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22005` |
| **Source Silicon Repository** | `pulp-platform/ara` (`repo_19`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/masku.sv`](environment/public/code/masku.sv), [`code/masku_operands.sv`](environment/public/code/masku_operands.sv) (2 files, 1276 LOC) |
| **Public Subsystem Context** | 19 RTL files (7358 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# RVV 1.0 Multi-EEW Mask Bit-Scan, Popcount, and Prefix-Sum Support in Ara's Mask Unit

## Context & Architectural Contract

In PULP Ara (`NrLanes = 4`, `ELEN = 64`, `VLEN = 1024`), each vector lane stores 64-bit VRF words whose bytes are lane-shuffled by each operand's effective encoding width (`EW8`, `EW16`, `EW32`, `EW64`) according to `ara_pkg::shuffle_index` and `ara_pkg::deshuffle_index` (`32` bytes / `256` bits per 4-lane VRF beat).

Currently, `code/masku_operands.sv` forwards incoming lane words without per-operand multi-EEW byte deshuffling, and `code/masku.sv` lacks hardware support for the seven native RVV 1.0 mask bit-scan, population-count, and element-index/prefix-sum instructions (`VCPOP`, `VFIRST`, `VMSBF`, `VMSOF`, `VMSIF`, `VIOTA`, `VID`) as well as backpressure-safe scalar result retirement. Extend `code/masku_operands.sv` and `code/masku.sv` to support multi-EEW operand unpacking and all seven operations while preserving all existing Mask Unit operations (`VMANDNOT`..`VMXNOR`, `VMFEQ`..`VMSBC`, `VRGATHER`..`VCOMPRESS`) and mask distribution (`mask_o` / `mask_valid_o`).

## Operand Channels, Zero-Trip Behavior, & RVV 1.0 Semantics

1. **Independent Multi-EEW Unpacking (`masku_operands.sv`)**:
   - Channel `0` (`MaskM`, active when `!vm`): `v0.m` words encoded with `eew_vmask`, deshuffled onto `masku_operand_m_seq_o`.
   - Channel `1` (`MaskB`, active when `use_vd_op` or `VRGATHER`..`VCOMPRESS`): prior `vd` / data words encoded with `eew_vd_op`, deshuffled onto `masku_operand_vd_seq_o`.
   - Channel `2 + masku_fu_i`: source `vs2` / ALU / MFPU words encoded with `eew_vs2`, deshuffled onto `masku_operand_alu_seq_o` (active when `use_vs2`).
   - `eew_vmask`, `eew_vd_op`, `eew_vs2`, and destination `vtype.vsew` may all differ within the same instruction, and lane `valid` handshakes may arrive with arbitrary inter-lane skew.
2. **Beat Draining & Zero-Trip Instructions**:
   - When `vl == 0` or `vstart >= vl`, lanes push zero operand beats; the unit must not wait on `masku_operand_valid_i` or issue VRF writes (`VCPOP` retires `64'd0`, `VFIRST` retires `64'hFFFF_FFFF_FFFF_FFFF`, vector ops retire immediately).
   - When `vl > 0` and `vstart < vl`, every active input channel delivers `ceil(vl / 256)` beats per lane; all scheduled beats across all lanes must be drained before `pe_resp_o.vinsn_done[id]` pulses (including early `VFIRST` hits).
3. **Target Operations** (with `active(i) = vm || v0.m[i]`):
   - `VCPOP` / `VFIRST`: Scalar population count and lowest active set bit index over `i in [vstart, vl)` (`64'd0` / `64'hFFFF_FFFF_FFFF_FFFF` when none), retired on `result_scalar_o` / `result_scalar_valid_o` / `result_scalar_ready_i` (holding `valid` and data stable under `ready == 0`, pulsing `vinsn_done[id]` on handshake).
   - `VMSBF`, `VMSOF`, `VMSIF`: Write `N_out = ceil(vl / 256)` beats to `vd` (`be = 8'hFF`, shuffled by `vtype.vsew`). Bits `i < vstart` remain `vd_old[i]`; active body bits `[vstart, vl)` follow RVV 1.0 set-before / set-only / set-including-first semantics starting from `vstart` (ignoring `j < vstart` and inactive bits); inactive body bits follow `vtype.vma` (`1` = `'1`, `0` = `vd_old[i]`); tail bits `[vl, 256*N_out)` follow `vtype.vta`.
   - `VIOTA`, `VID`: With `E_beat = 32 >> vtype.vsew`, write `N_out = ceil(vl / E_beat)` beats to `vd` (shuffled by `vtype.vsew`). Active body elements write `SEW'(i)` (`VID`) or the running prefix sum `SEW'(sum_{0 <= j < i} active(j) & vs2[j])` (`VIOTA`) with element `be` strobes enabled; `i < vstart` leaves `be = 0`; inactive body and final-beat tail elements write `'1` (`be = 1`) when `vma`/`vta == 1` or suppress `be = 0` when undisturbed.
   - `vinsn_done[id]` for vector writes must wait until all queued beats issue (`req && gnt`) and every lane returns its matching `masku_result_final_gnt_i` pulse.

## Deliverable Constraints

- Modify **only** `code/masku_operands.sv` and `code/masku.sv`; keep module names, parameters, and port signatures intact.
- Synthesizable synchronous RTL (`clk_i`, `rst_ni`) with zero inferred latches and zero combinational loops.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Guide

## Source Layout

All SystemVerilog packages, common-cell modules, headers, and Mask Unit RTL sources reside under `code/`:

- **Editable RTL files**:
  - `code/masku_operands.sv`
  - `code/masku.sv`
- **Read-only packages, headers, and primitives**:
  - `code/config_pkg.sv`
  - `code/cv64a6_imafdcv_sv39_config_pkg.sv`
  - `code/riscv_pkg.sv`
  - `code/cf_math_pkg.sv`
  - `code/axi_pkg.sv`
  - `code/fpnew_pkg.sv`
  - `code/rvv_pkg.sv`
  - `code/ara_pkg.sv`
  - `code/spill_register_flushable.sv`
  - `code/spill_register.sv`
  - `code/delta_counter.sv`
  - `code/lzc.sv`
  - `code/popcount.sv`
  - `code/fifo_v3.sv`
  - `code/include/common_cells/registers.svh`
  - `code/include/common_cells/assertions.svh`
  - `code/include/ara/ara_typedef.svh`

## Compilation Order (Verilator)

To lint or simulate `masku` with your own testbench (`my_tb.sv`) using Verilator (`v5.038+`):

```bash
verilator --binary --timing -O1 -CFLAGS -O0 -Wno-fatal -DSYNTHESIS -j 1 \
  -Icode/include \
  --top-module my_tb \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv \
  code/cf_math_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/delta_counter.sv \
  code/lzc.sv \
  code/popcount.sv \
  code/fifo_v3.sv \
  code/masku_operands.sv \
  code/masku.sv \
  my_tb.sv
```

When instantiating `masku` in a custom testbench or synthesis wrapper with `NrLanes = 4` and `VLEN = 1024`, define `localparam type vlen_t = logic [$clog2(VLEN+1)-1:0];` and `localparam type vaddr_t = logic [9:0];`, then `` `include "ara/ara_typedef.svh" `` inside your wrapper module to obtain `pe_req_t` and `pe_resp_t`.

## Synthesis & Latch Check (`yosys -m slang`)

To verify clean synthesis elaboration, zero combinational loops, and zero inferred latches using Yosys with the `slang` frontend (`my_synth_top.sv` wrapping `masku` for `NrLanes = 4`, `VLEN = 1024`):

```bash
yosys -m slang -p "
  read_slang -DSYNTHESIS --ignore-assertions --unroll-limit 20000 \
    -Icode/include --top my_synth_top \
    code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv \
    code/riscv_pkg.sv \
    code/cf_math_pkg.sv \
    code/axi_pkg.sv \
    code/fpnew_pkg.sv \
    code/rvv_pkg.sv \
    code/ara_pkg.sv \
    code/spill_register_flushable.sv \
    code/spill_register.sv \
    code/delta_counter.sv \
    code/lzc.sv \
    code/popcount.sv \
    code/fifo_v3.sv \
    code/masku_operands.sv \
    code/masku.sv \
    my_synth_top.sv;
  hierarchy -check -top my_synth_top;
  proc; opt_clean; check -assert; stat
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/masku.sv (Buggy Starter)
+++ b/solution/gold/code/masku.sv (Golden Reference)
@@ -66,6 +66,7 @@
   vlen_t issue_cnt_d, issue_cnt_q;
   vlen_t processing_cnt_d, processing_cnt_q;
   vlen_t commit_cnt_d, commit_cnt_q;
+  vlen_t elm_idx_d, elm_idx_q;
 
   ////////////////
   //  Operands  //
@@ -77,6 +78,7 @@
   logic  [NrLanes-1:0]           masku_operand_alu_valid;
   logic  [NrLanes-1:0]           masku_operand_alu_ready;
   logic  [NrLanes*DataWidth-1:0] masku_operand_alu_seq;
+  logic  [NrLanes*DataWidth-1:0] masku_operand_alu_seq_m;
 
   elen_t [NrLanes-1:0]           masku_operand_vd;
   logic  [NrLanes-1:0]           masku_operand_vd_valid;
@@ -129,14 +131,37 @@
     .alu_result_compressed_seq_o   ( alu_result_compressed_seq )
   );
 
+  // Parallelism knobs for time-multiplexed RVV 1.0 mask operations
+  localparam int unsigned VcpopParallelism     = 16;
+  localparam int unsigned VfirstParallelism    = 16;
+  localparam int unsigned VmsxfParallelism     = 2;
+  localparam int unsigned ViotaParallelism     = 2;
   localparam int unsigned VrgatherParallelism  = 1;
   localparam int unsigned VmLogicalParallelism = NrLanes * DataWidth;
 
-  logic [3:0]                   elm_per_lane;
-  logic [NrLanes-1:0]           additional_elm;
-  logic [NrLanes*DataWidth/8-1:0] be_vrgat_seq_d, be_vrgat_seq_q;
+  localparam int unsigned N_SLICES_CPOP   = NrLanes * DataWidth / VcpopParallelism;
+  localparam int unsigned N_SLICES_VFIRST = NrLanes * DataWidth / VfirstParallelism;
+
+  logic [VcpopParallelism-1:0]         vcpop_slice;
+  logic [$clog2(VcpopParallelism):0]   popcount_slice_val;
+  elen_t                               popcount_d, popcount_q;
+
+  logic [VfirstParallelism-1:0]                vfirst_slice;
+  logic [idx_width(VfirstParallelism)-1:0]     vfirst_slice_tzc;
+  logic                                        vfirst_slice_empty;
+  logic                                        vfirst_found_d, vfirst_found_q;
+  elen_t                                       vfirst_idx_d, vfirst_idx_q;
+
+  logic [$clog2(RISCV_MAX_VLEN)-1:0] viota_acc_d, viota_acc_q, viota_acc_next;
+  logic [$clog2(RISCV_MAX_VLEN)-1:0] viota_res [ViotaParallelism-1:0];
+
+  logic [3:0]                     elm_per_lane;
+  logic [NrLanes-1:0]             additional_elm;
+  logic [NrLanes*DataWidth/8-1:0] be_viota_seq_d, be_viota_seq_q, be_viota_seq_comb;
+  logic [NrLanes*DataWidth/8-1:0] be_vrgat_seq_d, be_vrgat_seq_q, be_vrgat_seq_comb;
   logic [NrLanes*DataWidth/8-1:0] be_masku_alu_shuf;
 
+  logic                        found_one_d, found_one_q, found_one_next;
   logic [NrLanes*DataWidth-1:0] alu_result_vm_m, alu_result_vm_shuf;
   elen_t [NrLanes-1:0]          alu_result;
 
@@ -227,7 +252,8 @@
   logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_write_pnt_d, result_queue_write_pnt_q;
   logic     [idx_width(ResultQueueDepth)-1:0]   result_queue_read_pnt_d, result_queue_read_pnt_q;
   logic     [idx_width(ResultQueueDepth):0]     result_queue_cnt_d, result_queue_cnt_q;
-  logic     [NrLanes-1:0]                       result_final_gnt_d, result_final_gnt_q;
+  logic     [NrLanes-1:0][7:0]                  pending_final_gnt_cnt_d, pending_final_gnt_cnt_q;
+  logic                                         pending_final_gnt_zero;
 
   elen_t [NrLanes-1:0]           result_queue_background_data;
   logic  [NrLanes*DataWidth-1:0] result_queue_mask_seq;
@@ -244,12 +270,14 @@
       result_queue_write_pnt_q <= '0;
       result_queue_read_pnt_q  <= '0;
       result_queue_cnt_q       <= '0;
+      pending_final_gnt_cnt_q  <= '0;
     end else begin
       result_queue_q           <= result_queue_d;
       result_queue_valid_q     <= result_queue_valid_d;
       result_queue_write_pnt_q <= result_queue_write_pnt_d;
       result_queue_read_pnt_q  <= result_queue_read_pnt_d;
       result_queue_cnt_q       <= result_queue_cnt_d;
+      pending_final_gnt_cnt_q  <= pending_final_gnt_cnt_d;
     end
   end
 
@@ -329,13 +357,14 @@
   );
 
   localparam int unsigned MAX_NUM_VRF_WORDS = VLEN / NrLanes / 8;
+  localparam int unsigned ITER_CNT_WIDTH    = idx_width(MAX_NUM_VRF_WORDS) + 1;
   logic iteration_cnt_clr;
-  logic [idx_width(MAX_NUM_VRF_WORDS)-1:0] iteration_cnt_q, iteration_cnt_delta_q;
+  logic [ITER_CNT_WIDTH-1:0] iteration_cnt_q, iteration_cnt_delta_q;
 
   assign iteration_cnt_delta_q = 1;
 
   delta_counter #(
-    .WIDTH(idx_width(MAX_NUM_VRF_WORDS))
+    .WIDTH(ITER_CNT_WIDTH)
   ) i_iteration_cnt (
     .clk_i,
     .rst_ni,
@@ -459,6 +488,26 @@
     end
   end
 
+  //////////////////////////
+  //  Popcount & Find-1st //
+  //////////////////////////
+
+  popcount #(
+    .INPUT_WIDTH (VcpopParallelism)
+  ) i_popcount (
+    .data_i    (vcpop_slice       ),
+    .popcount_o(popcount_slice_val)
+  );
+
+  lzc #(
+    .WIDTH(VfirstParallelism),
+    .MODE (0                )
+  ) i_clz (
+    .in_i    (vfirst_slice      ),
+    .cnt_o   (vfirst_slice_tzc  ),
+    .empty_o (vfirst_slice_empty)
+  );
+
   ////////////////
   //  Mask ALU  //
   ////////////////
@@ -469,15 +518,37 @@
 
   assign masku_operand_fu = (vinsn_issue.op inside {[VMFEQ:VMFGE]}) ? MaskFUMFpu : MaskFUAlu;
 
-  // Baseline datapath: supports VMANDNOT..VMXNOR, VMFEQ..VMSBC, and VRGATHER..VCOMPRESS.
-  // RVV 1.0 mask bit-scan, population count, and prefix-sum operations
-  // (VCPOP, VFIRST, VMSBF, VMSOF, VMSIF, VIOTA, VID) are unimplemented in this baseline.
   always_comb begin : p_masku_alu_comb
-    alu_result         = '1;
-    alu_result_vm_m    = '1;
+    logic [NrLanes*DataWidth/8-1:0] be_viota_base;
+
+    alu_result        = '1;
+    alu_result_vm_m   = '1;
     alu_result_vm_shuf = '1;
-    vrgat_m_seq_bit    = 1'b0;
-    be_vrgat_seq_d     = be_vrgat_seq_q;
+    vcpop_slice       = '0;
+    vfirst_slice      = '0;
+    vrgat_m_seq_bit   = 1'b0;
+
+    masku_operand_alu_seq_m = masku_operand_alu_seq
+                            & (masku_operand_m_seq | {NrLanes*DataWidth{vinsn_issue.vm}});
+
+    found_one_next = found_one_q;
+    viota_acc_next = viota_acc_q;
+    for (int i = 0; i < ViotaParallelism; i++) viota_res[i] = '0;
+
+    // Base sequential byte-enable for VIOTA / VID on beat start vs continuation
+    if (out_valid_cnt_q == '0) begin
+      for (int b = 0; b < (NrLanes * StrbWidth); b++) begin
+        automatic int unsigned elm_of_b = b >> unsigned'(vinsn_issue.vtype.vsew);
+        automatic vlen_t       g_of_b   = vlen_t'(iteration_cnt_q) *
+                                          vlen_t'((NrLanes * StrbWidth) >> unsigned'(vinsn_issue.vtype.vsew)) +
+                                          vlen_t'(elm_of_b);
+        be_viota_base[b] = (g_of_b >= vinsn_issue.vl) ? vinsn_issue.vtype.vta : 1'b0;
+      end
+    end else begin
+      be_viota_base = be_viota_seq_q;
+    end
+    be_viota_seq_comb = be_viota_base;
+    be_vrgat_seq_comb = be_vrgat_seq_q;
 
     if (vinsn_issue_valid) begin
       unique case (vinsn_issue.op) inside
@@ -485,6 +556,139 @@
         [VMFEQ:VMSGT]:     alu_result_vm_m = alu_result_compressed_seq
                                            | ~(masku_operand_m_seq | {NrLanes*DataWidth{vinsn_issue.vm}});
         [VMADC:VMSBC]:     alu_result_vm_m = alu_result_compressed_seq;
+
+        [VMSBF:VMSIF]: begin
+          logic seen_cur;
+          seen_cur = found_one_q;
+          for (int i = 0; i < VmsxfParallelism; i++) begin
+            automatic int unsigned local_bit =
+              in_ready_cnt_q[idx_width(NrLanes*DataWidth/VmsxfParallelism)-1:0] * VmsxfParallelism + i;
+            automatic int unsigned out_bit =
+              out_valid_cnt_q[idx_width(NrLanes*DataWidth/VmsxfParallelism)-1:0] * VmsxfParallelism + i;
+            automatic vlen_t g_bit   = elm_idx_q + vlen_t'(i);
+            automatic logic  in_body = (g_bit >= vinsn_issue.vstart) && (g_bit < vinsn_issue.vl);
+            automatic logic  m_en    = vinsn_issue.vm | masku_operand_m_seq[local_bit];
+            automatic logic  s_bit   = masku_operand_alu_seq[local_bit];
+            automatic logic  act_val;
+
+            if (in_body && m_en) begin
+              unique case (vinsn_issue.op)
+                VMSBF:   act_val = ~seen_cur & ~s_bit;
+                VMSIF:   act_val = ~seen_cur;
+                default: act_val = ~seen_cur &  s_bit; // VMSOF
+              endcase
+              alu_result_vm_m[out_bit] = act_val;
+              seen_cur                 = seen_cur | s_bit;
+            end else begin
+              // Leave alu_result_vm_m[out_bit] == 1'b1 so background_data_init_shuf governs
+              // prestart, masked-off body (vma), and tail (vta) bits seamlessly.
+              alu_result_vm_m[out_bit] = 1'b1;
+            end
+          end
+          found_one_next = seen_cur;
+        end
+
+        VIOTA, VID: begin
+          logic [$clog2(RISCV_MAX_VLEN)-1:0] acc_cur;
+          acc_cur = viota_acc_q;
+
+          for (int i = 0; i < ViotaParallelism; i++) begin
+            automatic int unsigned local_bit =
+              in_ready_cnt_q[idx_width(NrLanes*DataWidth/ViotaParallelism)-1:0] * ViotaParallelism + i;
+            automatic int unsigned local_m_bit =
+              in_m_ready_cnt_q[idx_width(NrLanes*DataWidth/ViotaParallelism)-1:0] * ViotaParallelism + i;
+            automatic vlen_t g_elm  = elm_idx_q + vlen_t'(i);
+            automatic logic  m_en   = vinsn_issue.vm | masku_operand_m_seq[local_m_bit];
+            automatic logic  inc_bit;
+
+            if (vinsn_issue.op == VID) begin
+              viota_res[i] = ($clog2(RISCV_MAX_VLEN))'(g_elm);
+              inc_bit      = 1'b0;
+            end else begin
+              viota_res[i] = acc_cur;
+              inc_bit      = (g_elm < vinsn_issue.vl) ? (masku_operand_alu_seq[local_bit] & m_en) : 1'b0;
+              acc_cur      = acc_cur + {{($clog2(RISCV_MAX_VLEN)-1){1'b0}}, inc_bit};
+            end
+
+            // Populate sequential wdata and byte-enables respecting vstart, vl, vma, and vta
+            unique case (vinsn_issue.vtype.vsew)
+              EW8: begin
+                automatic int unsigned slot =
+                  out_valid_cnt_q[idx_width(NrLanes*DataWidth/8/ViotaParallelism)-1:0] * ViotaParallelism + i;
+                if (g_elm < vinsn_issue.vstart) begin
+                  be_viota_seq_comb[slot] = 1'b0;
+                end else if (g_elm < vinsn_issue.vl) begin
+                  if (m_en) begin
+                    alu_result_vm_m[slot*8 +: 8] = viota_res[i][7:0];
+                    be_viota_seq_comb[slot]      = 1'b1;
+                  end else begin
+                    alu_result_vm_m[slot*8 +: 8] = 8'hFF;
+                    be_viota_seq_comb[slot]      = vinsn_issue.vtype.vma;
+                  end
+                end else begin
+                  alu_result_vm_m[slot*8 +: 8] = 8'hFF;
+                  be_viota_seq_comb[slot]      = vinsn_issue.vtype.vta;
+                end
+              end
+              EW16: begin
+                automatic int unsigned slot =
+                  out_valid_cnt_q[idx_width(NrLanes*DataWidth/16/ViotaParallelism)-1:0] * ViotaParallelism + i;
+                if (g_elm < vinsn_issue.vstart) begin
+                  be_viota_seq_comb[slot*2 +: 2] = 2'b00;
+                end else if (g_elm < vinsn_issue.vl) begin
+                  if (m_en) begin
+                    alu_result_vm_m[slot*16 +: 16] = 16'(viota_res[i]);
+                    be_viota_seq_comb[slot*2 +: 2] = 2'b11;
+                  end else begin
+                    alu_result_vm_m[slot*16 +: 16] = 16'hFFFF;
+                    be_viota_seq_comb[slot*2 +: 2] = {2{vinsn_issue.vtype.vma}};
+                  end
+                end else begin
+                  alu_result_vm_m[slot*16 +: 16] = 16'hFFFF;
+                  be_viota_seq_comb[slot*2 +: 2] = {2{vinsn_issue.vtype.vta}};
+                end
+              end
+              EW32: begin
+                automatic int unsigned slot =
+                  out_valid_cnt_q[idx_width(NrLanes*DataWidth/32/ViotaParallelism)-1:0] * ViotaParallelism + i;
+                if (g_elm < vinsn_issue.vstart) begin
+                  be_viota_seq_comb[slot*4 +: 4] = 4'h0;
+                end else if (g_elm < vinsn_issue.vl) begin
+                  if (m_en) begin
+                    alu_result_vm_m[slot*32 +: 32] = 32'(viota_res[i]);
+                    be_viota_seq_comb[slot*4 +: 4] = 4'hF;
+                  end else begin
+                    alu_result_vm_m[slot*32 +: 32] = 32'hFFFF_FFFF;
+                    be_viota_seq_comb[slot*4 +: 4] = {4{vinsn_issue.vtype.vma}};
+                  end
+                end else begin
+                  alu_result_vm_m[slot*32 +: 32] = 32'hFFFF_FFFF;
+                  be_viota_seq_comb[slot*4 +: 4] = {4{vinsn_issue.vtype.vta}};
+                end
+              end
+              default: begin // EW64
+                automatic int unsigned slot =
+                  out_valid_cnt_q[idx_width(NrLanes*DataWidth/64/ViotaParallelism)-1:0] * ViotaParallelism + i;
+                if (g_elm < vinsn_issue.vstart) begin
+                  be_viota_seq_comb[slot*8 +: 8] = 8'h00;
+                end else if (g_elm < vinsn_issue.vl) begin
+                  if (m_en) begin
+                    alu_result_vm_m[slot*64 +: 64] = 64'(viota_res[i]);
+                    be_viota_seq_comb[slot*8 +: 8] = 8'hFF;
+                  end else begin
+                    alu_result_vm_m[slot*64 +: 64] = 64'hFFFF_FFFF_FFFF_FFFF;
+                    be_viota_seq_comb[slot*8 +: 8] = {8{vinsn_issue.vtype.vma}};
+                  end
+                end else begin
+                  alu_result_vm_m[slot*64 +: 64] = 64'hFFFF_FFFF_FFFF_FFFF;
+                  be_viota_seq_comb[slot*8 +: 8] = {8{vinsn_issue.vtype.vta}};
+                end
+              end
+            endcase
+          end
+          viota_acc_next = acc_cur;
+        end
+
         [VRGATHER:VCOMPRESS]: begin
           logic [NrLanes*DataWidth-1:0] vrgat_res;
           logic [DataWidth-1:0]         vrgat_buf;
@@ -513,52 +717,86 @@
           unique case (vinsn_issue.vtype.vsew)
             EW8: begin
               vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(NrLanes*DataWidth)-1:0]];
-              be_vrgat_seq_d[out_valid_cnt_q[idx_width(NrLanes*DataWidth/8)-1:0] * 1 +: 1] =
+              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(NrLanes*DataWidth/8)-1:0] * 1 +: 1] =
                 {1{vinsn_issue.vm}} | {1{vrgat_m_seq_bit}};
             end
             EW16: begin
               vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(NrLanes*DataWidth)-1:0]];
-              be_vrgat_seq_d[out_valid_cnt_q[idx_width(NrLanes*DataWidth/16)-1:0] * 2 +: 2] =
+              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(NrLanes*DataWidth/16)-1:0] * 2 +: 2] =
                 {2{vinsn_issue.vm}} | {2{vrgat_m_seq_bit}};
             end
             EW32: begin
               vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(NrLanes*DataWidth)-1:0]];
-              be_vrgat_seq_d[out_valid_cnt_q[idx_width(NrLanes*DataWidth/32)-1:0] * 4 +: 4] =
+              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(NrLanes*DataWidth/32)-1:0] * 4 +: 4] =
                 {4{vinsn_issue.vm}} | {4{vrgat_m_seq_bit}};
             end
             default: begin
               vrgat_m_seq_bit = masku_operand_m_seq[in_m_ready_cnt_q[idx_width(NrLanes*DataWidth)-1:0]];
-              be_vrgat_seq_d[out_valid_cnt_q[idx_width(NrLanes*DataWidth/64)-1:0] * 8 +: 8] =
+              be_vrgat_seq_comb[out_valid_cnt_q[idx_width(NrLanes*DataWidth/64)-1:0] * 8 +: 8] =
                 {8{vinsn_issue.vm}} | {8{vrgat_m_seq_bit}};
             end
           endcase
 
           alu_result_vm_m = vrgat_res;
         end
-        default: begin
-          // TODO: Implement VMSBF, VMSOF, VMSIF, VIOTA, VID, VCPOP, VFIRST
-          alu_result_vm_m = '0;
-        end
+
+        [VCPOP:VFIRST]: begin
+          for (int k = 0; k < VcpopParallelism; k++) begin
+            automatic int unsigned local_bit =
+              in_ready_cnt_q[idx_width(N_SLICES_CPOP)-1:0] * VcpopParallelism + k;
+            automatic vlen_t g_bit   = elm_idx_q + vlen_t'(k);
+            automatic logic  in_body = (g_bit >= vinsn_issue.vstart) && (g_bit < vinsn_issue.vl);
+            automatic logic  act_bit = in_body & masku_operand_alu_seq_m[local_bit];
+            vcpop_slice[k]  = act_bit;
+            vfirst_slice[k] = act_bit;
+          end
+        end
+
+        default:;
       endcase
     end
 
+    // Shuffle sequential result bytes according to vtype.vsew
     for (int b = 0; b < (NrLanes*StrbWidth); b++) begin
       automatic int shuffle_byte              = shuffle_index(b, NrLanes, vinsn_issue.vtype.vsew);
       alu_result_vm_shuf[8*shuffle_byte +: 8] = alu_result_vm_m[8*b +: 8];
     end
 
+    // Shuffle sequential byte-enable strobes according to vtype.vsew
     be_masku_alu_shuf = '0;
     for (int b = 0; b < (NrLanes*StrbWidth); b++) begin
       automatic int shuffle_byte      = shuffle_index(b, NrLanes, vinsn_issue.vtype.vsew);
-      be_masku_alu_shuf[shuffle_byte] = vinsn_issue.op inside {VRGATHER, VRGATHEREI16} ? be_vrgat_seq_d[b] : 1'b1;
+      be_masku_alu_shuf[shuffle_byte] = vinsn_issue.op inside {VRGATHER, VRGATHEREI16}
+                                      ? be_vrgat_seq_comb[b]
+                                      : be_viota_seq_comb[b];
     end
 
     alu_result = alu_result_vm_shuf;
 
+    // Prepare background data for mask-destination instructions
     result_queue_mask_seq = vinsn_issue.op inside {[VIOTA:VID], [VRGATHER:VCOMPRESS]}
                           ? '0
                           : masku_operand_m_seq | {NrLanes*DataWidth{vinsn_issue.vm}} | {NrLanes*DataWidth{vinsn_issue.op inside {[VMADC:VMSBC]}}};
-    background_data_init_seq  = masku_operand_vd_seq | result_queue_mask_seq;
+
+    if (vinsn_issue.op inside {[VMSBF:VMSIF]}) begin
+      for (int bit_i = 0; bit_i < (NrLanes * DataWidth); bit_i++) begin
+        automatic vlen_t g_bit = vlen_t'(iteration_cnt_q) * vlen_t'(NrLanes * DataWidth) + vlen_t'(bit_i);
+        if (g_bit < vinsn_issue.vstart) begin
+          background_data_init_seq[bit_i] = masku_operand_vd_seq[bit_i];
+        end else if (g_bit >= vinsn_issue.vl) begin
+          background_data_init_seq[bit_i] = vinsn_issue.vtype.vta ? 1'b1 : masku_operand_vd_seq[bit_i];
+        end else if (vinsn_issue.vm || masku_operand_m_seq[bit_i]) begin
+          background_data_init_seq[bit_i] = 1'b1;
+        end else begin
+          background_data_init_seq[bit_i] = vinsn_issue.vtype.vma ? 1'b1 : masku_operand_vd_seq[bit_i];
+        end
+      end
+    end else if (!vinsn_issue.use_vd_op && (vinsn_issue.op inside {[VMANDNOT:VMXNOR]})) begin
+      background_data_init_seq = '1;
+    end else begin
+      background_data_init_seq = masku_operand_vd_seq | result_queue_mask_seq;
+    end
+
     background_data_init_shuf = '0;
     for (int b = 0; b < (NrLanes*StrbWidth); b++) begin
       automatic int shuffle_byte                     = shuffle_index(b, NrLanes, vinsn_issue.vtype.vsew);
@@ -571,14 +809,31 @@
   /////////////////
 
   always_comb begin : p_masku_ctrl_comb
+    elen_t popcount_next;
+    logic  vfirst_found_next;
+    elen_t vfirst_idx_next;
+
     vinsn_queue_d    = vinsn_queue_q;
     read_cnt_d       = read_cnt_q;
     issue_cnt_d      = issue_cnt_q;
     processing_cnt_d = processing_cnt_q;
     commit_cnt_d     = commit_cnt_q;
+    elm_idx_d        = elm_idx_q;
 
     mask_pnt_d = mask_pnt_q;
     vrf_pnt_d  = vrf_pnt_q;
+
+    popcount_d     = popcount_q;
+    vfirst_found_d = vfirst_found_q;
+    vfirst_idx_d   = vfirst_idx_q;
+    found_one_d    = found_one_q;
+    viota_acc_d    = viota_acc_q;
+    be_viota_seq_d = be_viota_seq_q;
+    be_vrgat_seq_d = be_vrgat_seq_q;
+
+    popcount_next     = popcount_q;
+    vfirst_found_next = vfirst_found_q;
+    vfirst_idx_next   = vfirst_idx_q;
 
     mask_queue_d           = mask_queue_q;
     mask_queue_valid_d     = mask_queue_valid_q;
@@ -591,10 +846,9 @@
     result_queue_write_pnt_d = result_queue_write_pnt_q;
     result_queue_read_pnt_d  = result_queue_read_pnt_q;
     result_queue_cnt_d       = result_queue_cnt_q;
-
-    result_final_gnt_d = result_final_gnt_q;
+    pending_final_gnt_cnt_d  = pending_final_gnt_cnt_q;
+
     trimmed_stride     = pe_req_i.stride;
-
     out_vrf_word_valid = 1'b0;
     out_scalar_valid   = 1'b0;
 
@@ -816,47 +1070,71 @@
       for (int unsigned lane = 0; lane < NrLanes; lane++) begin
         result_queue_d[result_queue_write_pnt_q][lane] = '{
           wdata: result_queue_q[result_queue_write_pnt_q][lane].wdata,
-          be   : vinsn_issue.op inside {[VIOTA:VID], [VRGATHER:VCOMPRESS]}
+          be   : vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}
                  ? be(elm_per_lane + additional_elm[lane], vinsn_issue.vtype.vsew) & be_masku_alu_shuf[lane*StrbWidth +: StrbWidth]
-                 : '1,
-          addr : vaddr(vinsn_issue.vd, NrLanes, VLEN) + iteration_cnt_q,
+                 : (vinsn_issue.op inside {[VIOTA:VID]} ? be_masku_alu_shuf[lane*StrbWidth +: StrbWidth] : '1),
+          addr : vaddr(vinsn_issue.vd, NrLanes, VLEN) + vaddr_t'(iteration_cnt_q),
           id   : vinsn_issue.id
         };
       end
     end
 
-    if (vinsn_issue_valid && vinsn_issue.op inside {[VMFEQ:VMXNOR], [VRGATHER:VCOMPRESS]}) begin
-      if (!result_queue_full && (&masku_operand_alu_valid || vinsn_issue.op inside {VID, [VRGATHER:VCOMPRESS]})
-                             && (&masku_operand_vd_valid  || (!vinsn_issue.use_vd_op && !(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]})))
-                             && (&masku_operand_m_valid   || vinsn_issue.vm || vinsn_issue.op inside {[VMADC:VMSBC]})
-                             && (!vrgat_idx_fifo_empty    || !(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}))) begin
+    if (vinsn_issue_valid && vinsn_issue.op inside {[VMFEQ:VCOMPRESS]}) begin
+      if ((!result_queue_full || vd_scalar(vinsn_issue.op))
+          && (&masku_operand_alu_valid || vinsn_issue.op inside {VID, [VRGATHER:VCOMPRESS]} || !vinsn_issue.use_vs2)
+          && (&masku_operand_vd_valid  || (!vinsn_issue.use_vd_op && !(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]})))
+          && (&masku_operand_m_valid   || vinsn_issue.vm || vinsn_issue.op inside {[VMADC:VMSBC]})
+          && (!vrgat_idx_fifo_empty    || !(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}))
+          && (!result_scalar_valid_o   || !vd_scalar(vinsn_issue.op))) begin
 
         for (int unsigned lane = 0; lane < NrLanes; lane++) begin
           result_queue_background_data[lane] = (out_valid_cnt_q != '0)
                                              ? result_queue_q[result_queue_write_pnt_q][lane].wdata
-                                             : vinsn_issue.op inside {[VIOTA:VID], [VRGATHER:VCOMPRESS]} ? '1 : background_data_init_shuf[lane*DataWidth +: DataWidth];
+                                             : vinsn_issue.op inside {[VIOTA:VID], [VRGATHER:VCOMPRESS]}
+                                               ? '1
+                                               : background_data_init_shuf[lane*DataWidth +: DataWidth];
         end
         for (int unsigned lane = 0; lane < NrLanes; lane++) begin
           result_queue_d[result_queue_write_pnt_q][lane].wdata = result_queue_background_data[lane] & alu_result[lane];
         end
 
-        vrf_pnt_d = vrf_pnt_q + delta_elm_q;
+        // Update scalar accumulators
+        popcount_next = popcount_q + elen_t'(popcount_slice_val);
+        if (!vfirst_found_q && !vfirst_slice_empty) begin
+          vfirst_found_next = 1'b1;
+          vfirst_idx_next   = elen_t'(elm_idx_q) + elen_t'(vfirst_slice_tzc);
+        end
+        popcount_d     = popcount_next;
+        vfirst_found_d = vfirst_found_next;
+        vfirst_idx_d   = vfirst_idx_next;
+
+        // Advance sequential datapath state
+        found_one_d    = found_one_next;
+        viota_acc_d    = viota_acc_next;
+        be_viota_seq_d = be_viota_seq_comb;
+        be_vrgat_seq_d = be_vrgat_seq_comb;
+        vrf_pnt_d      = vrf_pnt_q + delta_elm_q;
         if (vinsn_issue.op inside {[VRGATHER:VCOMPRESS]}) vrgat_idx_fifo_pop = 1'b1;
 
-        if (!(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]})) in_ready_cnt_en = 1'b1;
+        if (!(vinsn_issue.op inside {[VRGATHER:VCOMPRESS]})) in_ready_cnt_en   = 1'b1;
         if (!(vinsn_issue.op inside {[VMADC:VMSBC]}))        in_m_ready_cnt_en = 1'b1;
-        out_valid_cnt_en = 1'b1;
-
-        issue_cnt_d = issue_cnt_q - delta_elm_q;
-        if (issue_cnt_q < delta_elm_q)
+        if (!vd_scalar(vinsn_issue.op))                      out_valid_cnt_en  = 1'b1;
+
+        issue_cnt_d = issue_cnt_q - vlen_t'(delta_elm_q);
+        if (issue_cnt_q < vlen_t'(delta_elm_q))
           issue_cnt_d = '0;
 
+        elm_idx_d = (issue_cnt_d =
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ara_pkg.sv`](environment/public/code/ara_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv`](environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/delta_counter.sv`](environment/public/code/delta_counter.sv) *(Read-Only Context)*
- [`environment/public/code/fifo_v3.sv`](environment/public/code/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/include/ara/ara_typedef.svh`](environment/public/code/include/ara/ara_typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/masku.sv`](environment/public/code/masku.sv) **(Editable)**
- [`environment/public/code/masku_operands.sv`](environment/public/code/masku_operands.sv) **(Editable)**
- [`environment/public/code/popcount.sv`](environment/public/code/popcount.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rvv_pkg.sv`](environment/public/code/rvv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

