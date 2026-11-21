# `case_22003`: Ara Lane Integer VMFPU and SIMD Divider Masked-Element Fast-Skip, Multi-Phase Descriptor Decoupling, and Nangate45 PPA/STA Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22003` |
| **Source Silicon Repository** | `pulp-platform/ara` (`repo_19`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/vmfpu.sv`](environment/public/code/vmfpu.sv), [`code/simd_div.sv`](environment/public/code/simd_div.sv) (2 files, 2800 LOC) |
| **Public Subsystem Context** | 21 RTL files (10260 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `960s` total (`480s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Optimize Ara Lane Integer VMFPU and SIMD Divider for Masked Fast-Skip, Area, and Timing Closure

## Problem Overview
In Ara's per-lane integer vector multiplier/divider unit (`code/vmfpu.sv` and `code/simd_div.sv`, synthesized via `code/vmfpu_synth_top.sv` with `NrLanes = 4`, `VLEN = 4096`, `FPUSupport = FPUSupportNone`, `FPExtSupport = FPExtSupportNone`, `FixPtSupport = FixedPointEnable`), baseline sign-off fails three checks:
1. **Synthesis Loop & Area Overflow**: `yosys` `proc; check -assert` flags combinational logic loops, and mapped Nangate45 cell area reaches **`87,565.6 um^2`**.
2. **Setup Timing Violation**: OpenROAD STA at a **`5.20 ns`** clock period reports **`-2.12 ns`** worst setup slack.
3. **Masked Division Latency Waste**: Under masked vector division/remainder (`vm = 0`), `simd_div.sv` serially iterates `serdiv` across every subword of every 64-bit lane beat even when individual subwords or entire beats are masked inactive.

## Sign-Off Requirements
Modify **only** `code/vmfpu.sv` and `code/simd_div.sv` (preserving module interfaces and read-only files) to satisfy all requirements simultaneously:

1. **RVV 1.0 & Ara Lane Architectural Equivalence**:
   - Preserve exact per-lane behavior for `VMUL`, `VMULH`, `VMULHU`, `VMULHSU`, `VMACC`, `VNMSAC`, `VMADD`, `VNMSUB`, `VSMUL`, `VDIVU`, `VDIV`, `VREMU`, and `VREM` across `EW8`, `EW16`, `EW32`, and `EW64`.
   - Support unmasked (`vm = 1`) and masked (`vm = 0`) execution, vector-vector and scalar (`use_scalar_op`) operands, `swap_vs2_vd_op` operand queue remapping, non-aligned tail `vl`, all four `mfpu_vxrm_i` fixed-point rounding modes, masked-active saturation reporting (`mfpu_vxsat_o` asserted only on active writebacks whose unmasked elements saturate), and RVV 1.0 divide-by-zero / signed-overflow (`-2^(W-1) / -1`) semantics.
   - Maintain in-order VRF result writeback (`mfpu_result_*`) and completion (`mfpu_vinsn_done_o`) across queued multi-SEW instructions under arbitrary `mfpu_operand_valid_i`, `mask_valid_i`, and `mfpu_result_gnt_i` backpressure. Ignore broadcasts with `vfu != VFU_MFpu` and keep unused FP handshakes inactive (`0`).

2. **Masked Subword Fast-Skip Latency**:
   - Skip masked-off subwords without running `serdiv` iterations on them, and bypass `serdiv` when an entire 64-bit beat is masked off, writing active subword results to their exact byte lanes.
   - With zero external stall, an 8-beat (`vl = 64`, `EW8`, `vm = 0`) instruction from issue acceptance to `mfpu_vinsn_done_o` must finish in **`<= 32` cycles** when all elements are masked off (`mask_i = 8'h00`, `VDIV`), and **`<= 76` cycles** when 1 of 8 bytes per beat is active (`VDIVU`, active `8'h18 / 8'h06`, inactive `8'hFF / 8'h01`).
   - With zero external stall, an 8-beat (`vl = 32`, `EW16`, `vm = 0`) `VREM` with 1 of 4 halfwords per beat active (active `16'h002F % 16'h0009`, inactive `16'h7FFF % 16'h0001`) must finish in **`<= 84` cycles**.

3. **Nangate45 Synthesis & STA Closure (`BUILD.md`)**:
   - Clean, loop-free synthesis (`proc; check -assert;` exits `0`) on `vmfpu_synth_top` with zero inferred latches.
   - Mapped cell area **`<= 83,600.0 um^2`**, worst setup slack **`>= 0.000 ns`**, and worst hold/removal slack **`>= 0.000 ns`** at **`5.20 ns`** `clk_i` (`0.20 ns` I/O delays, `5.0 fF` output load).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Workspace Layout and Editable Scope

- **Editable RTL files** (edit ONLY these two files):
  - `code/vmfpu.sv`: Ara per-lane multi-phase vector multiplier/divider functional unit (`module vmfpu`).
  - `code/simd_div.sv`: Ara per-lane 64-bit SIMD serial integer divider wrapper (`module simd_div`).
- **Read-only RTL and package closure** (`code/`):
  - `code/vmfpu_synth_top.sv`: Concrete lane synthesis/verification wrapper instantiating `vmfpu` with `NrLanes = 4`, `VLEN = 4096`, `FPUSupport = FPUSupportNone`, `FPExtSupport = FPExtSupportNone`, `FixPtSupport = FixedPointEnable`.
  - `code/simd_mul.sv`, `code/serdiv.sv`, `code/power_gating_generic.sv`, `code/tc_clk.sv`, `code/lzc.sv`, `code/spill_register.sv`, `code/spill_register_flushable.sv`: Read-only arithmetic and common-cell submodules.
  - `code/cf_math_pkg.sv`, `code/config_pkg.sv`, `code/cv64a6_imafdcv_sv39_config_pkg.sv`, `code/riscv_pkg.sv`, `code/ariane_pkg.sv`, `code/axi_pkg.sv`, `code/fpnew_pkg.sv`, `code/rvv_pkg.sv`, `code/ara_pkg.sv`, and `code/include/common_cells/{registers.svh,assertions.svh}`: Read-only SystemVerilog packages and headers.
- **Read-only Nangate45 PDK collateral** (`lib/`):
  - `lib/NangateOpenCellLibrary_typical.lib` (`1 ns`, `1 fF`, area in `um^2`)
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

Do not modify any file outside `code/vmfpu.sv` and `code/simd_div.sv`.

## 2. Functional & Latency Simulation (Verilator)

Compile the RTL closure in package-dependency order using Verilator (`verilator-v5.038`):

```bash
verilator \
  --binary --timing -j 4 -Wno-fatal --top-module tb \
  -Icode/include \
  code/cf_math_pkg.sv \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/lzc.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/tc_clk.sv \
  code/power_gating_generic.sv \
  code/serdiv.sv \
  code/simd_mul.sv \
  code/simd_div.sv \
  code/vmfpu.sv \
  code/vmfpu_synth_top.sv \
  tb.sv
./obj_dir/Vtb
```

## 3. Deterministic Nangate45 Logic Synthesis (Yosys + Slang)

Synthesize `vmfpu_synth_top` with Yosys (`-m slang`) and ABC mapped to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
FILES="code/cf_math_pkg.sv code/config_pkg.sv code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
  code/rvv_pkg.sv code/ara_pkg.sv code/lzc.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/tc_clk.sv code/power_gating_generic.sv \
  code/serdiv.sv code/simd_mul.sv code/simd_div.sv code/vmfpu.sv code/vmfpu_synth_top.sv"

yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode/include --top vmfpu_synth_top --ignore-assertions ${FILES};
  hierarchy -check -top vmfpu_synth_top;
  proc;
  check -assert;
  synth -top vmfpu_synth_top -noabc;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -script +strash;dc2;map;
  opt_clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr netlist.v
"
```

Sign-off requirements for synthesis:
1. `proc; check -assert;` must pass with zero combinational logic loops or undriven/multiple-driver errors.
2. Total mapped cell area reported by `Chip area for module '\vmfpu_synth_top':` must be **`<= 83600.0` `um^2`**.

## 4. Static Timing Analysis (OpenROAD)

Evaluate setup and hold timing on the synthesized `netlist.v` with OpenROAD (`sta.tcl`):

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist.v
link_design vmfpu_synth_top
create_clock -name clk_i -period 5.20 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
puts "=== SETUP ==="
report_checks -path_delay max -group_path_count 5 -digits 3
puts "=== HOLD ==="
report_checks -path_delay min -group_path_count 5 -digits 3
```

Run:

```bash
openroad -exit sta.tcl
```

Sign-off requirements for timing:
- Worst setup slack (`-path_delay max`) must be **`>= 0.000 ns`** at `clk_i` period `5.20 ns`.
- Worst hold/removal slack (`-path_delay min`) must be **`>= 0.000 ns`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/vmfpu.sv (Buggy Starter)
+++ b/solution/gold/code/vmfpu.sv (Golden Reference)
@@ -5,7 +5,9 @@
 // Authors: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
 //          Matteo Perotti <mperotti@iis.ee.ethz.ch>
 // Description:
-// Ara's integer multiplier and floating-point unit.
+// Ara's integer multiplier and division functional unit (configured with
+// phase-decoupled instruction descriptors, incremental VRF write addressing,
+// per-EW clock-gated multiplier pipelines, and masked fast-skip division).
 
 module vmfpu import ara_pkg::*; import rvv_pkg::*; import fpnew_pkg::*;
   import cf_math_pkg::idx_width; #(
@@ -69,118 +71,609 @@
     output logic                         mask_ready_o
   );
 
-  // Power gating registers
   `include "common_cells/registers.svh"
 
-  ////////////////////////////////
-  //  Vector instruction queue  //
-  ////////////////////////////////
-
-  // We store a certain number of in-flight vector instructions
-  localparam VInsnQueueDepth = MfpuInsnQueueDepth;
-
-  struct packed {
-    vfu_operation_t [VInsnQueueDepth-1:0] vinsn;
-
-    // Each instruction can be in one of the three execution phases.
-    // - Being accepted (i.e., it is being stored for future execution in this
-    //   vector functional unit).
-    // - Being processed (i.e., its micro-operations are currently being processed
-    //   by the corresponding functional units).
-    // - Being issued (i.e., its micro-operations are currently being issued
-    //   to the corresponding functional units).
-    // - Being committed (i.e., its results are being written to the vector
-    //   register file).
-    // We need pointers to index which instruction is at each execution phase
-    // between the VInsnQueueDepth instructions in memory.
-    logic [idx_width(VInsnQueueDepth)-1:0] accept_pnt;
-    logic [idx_width(VInsnQueueDepth)-1:0] issue_pnt;
-    logic [idx_width(VInsnQueueDepth)-1:0] processing_pnt;
-    logic [idx_width(VInsnQueueDepth)-1:0] commit_pnt;
-
-    // We also need to count how many instructions are queueing to be
-    // issued/committed, to avoid accepting more instructions than
-    // we can handle.
-    logic [idx_width(VInsnQueueDepth):0] issue_cnt;
-    logic [idx_width(VInsnQueueDepth):0] processing_cnt;
-    logic [idx_width(VInsnQueueDepth):0] commit_cnt;
-  } vinsn_queue_d, vinsn_queue_q;
-
-  // Is the vector instruction queue full?
+  // Tie off unused floating-point / reduction / mask-comparison ports when FPUSupport == FPUSupportNone
+  if (FPUSupport == FPUSupportNone) begin : gen_no_fpu_ties
+    wire unused_fpu_inputs = ^{lane_id_i, mfpu_red_ready_i, sldu_operand_i, sldu_mfpu_valid_i, mask_operand_ready_i};
+    assign fflags_ex_o          = '0;
+    assign fflags_ex_valid_o    = 1'b0;
+    assign fpu_red_complete_o   = 1'b0;
+    assign mfpu_red_valid_o     = 1'b0;
+    assign sldu_mfpu_ready_o    = 1'b0;
+    assign mask_operand_o       = '0;
+    assign mask_operand_valid_o = 1'b0;
+  end
+
+  ///////////////////////////////////////////////////
+  //  Phase-Decoupled Vector Instruction Descriptors
+  ///////////////////////////////////////////////////
+
+  localparam int unsigned VInsnQueueDepth = MfpuInsnQueueDepth;
+  localparam int unsigned PntWidth        = idx_width(VInsnQueueDepth);
+  localparam int unsigned CntWidth        = idx_width(VInsnQueueDepth) + 1;
+
+  // Issue-only metadata (never muxed into processing or commit stages)
+  typedef struct packed {
+    elen_t      scalar_rep;
+    logic       use_scalar_op;
+    logic [2:0] req_op_mask;
+    ara_op_e    op;
+  } issue_meta_t;
+
+  // Compact control metadata shared across issue / processing / commit phases
+  typedef struct packed {
+    vid_t   id;
+    vew_e   vsew;
+    logic   vm;
+    logic   is_div;
+    logic   is_vsmul;
+    vaddr_t base_vaddr;
+    vlen_t  vl;
+  } ctrl_meta_t;
+
+  issue_meta_t [VInsnQueueDepth-1:0] issue_tbl_d, issue_tbl_q;
+  ctrl_meta_t  [VInsnQueueDepth-1:0] ctrl_tbl_d,  ctrl_tbl_q;
+
+  logic [PntWidth-1:0] accept_pnt_d, accept_pnt_q;
+  logic [PntWidth-1:0] issue_pnt_d,  issue_pnt_q;
+  logic [PntWidth-1:0] proc_pnt_d,   proc_pnt_q;
+  logic [PntWidth-1:0] commit_pnt_d, commit_pnt_q;
+
+  logic [CntWidth-1:0] issue_insns_d,  issue_insns_q;
+  logic [CntWidth-1:0] proc_insns_d,   proc_insns_q;
+  logic [CntWidth-1:0] commit_insns_d, commit_insns_q;
+
   logic vinsn_queue_full;
-  assign vinsn_queue_full = (vinsn_queue_q.commit_cnt == VInsnQueueDepth);
-
-  // Do we have a vector instruction ready to be issued?
-  vfu_operation_t vinsn_issue_d, vinsn_issue_q;
-  logic           vinsn_issue_d_valid, vinsn_issue_q_valid;
-  assign vinsn_issue_d     = vinsn_queue_d.vinsn[vinsn_queue_d.issue_pnt];
-  assign vinsn_issue_d_valid = (vinsn_queue_d.issue_cnt != '0);
-  assign vinsn_issue_q_valid = (vinsn_queue_q.issue_cnt != '0);
-
-  // Do we have a vector instruction being processed?
-  vfu_operation_t vinsn_processing_d, vinsn_processing_q;
-  logic           vinsn_processing_d_valid, vinsn_processing_q_valid;
-  assign vinsn_processing_d       = vinsn_queue_d.vinsn[vinsn_queue_d.processing_pnt];
-  assign vinsn_processing_q       = vinsn_queue_q.vinsn[vinsn_queue_q.processing_pnt];
-  assign vinsn_processing_d_valid = (vinsn_queue_d.processing_cnt != '0);
-  assign vinsn_processing_q_valid = (vinsn_queue_q.processing_cnt != '0);
-
-  // Do we have a vector instruction with results being committed?
-  vfu_operation_t vinsn_commit;
-  logic           vinsn_commit_valid;
-  assign vinsn_commit       = vinsn_queue_q.vinsn[vinsn_queue_q.commit_pnt];
-  assign vinsn_commit_valid = (vinsn_queue_q.commit_cnt != '0);
+  assign vinsn_queue_full = (commit_insns_q == CntWidth'(VInsnQueueDepth));
+
+  // Direct registered-pointer lookups (no next-pointer combinational cascade)
+  issue_meta_t issue_meta;
+  ctrl_meta_t  issue_ctrl, proc_ctrl, commit_ctrl;
+  logic        issue_active, proc_active, commit_active;
+
+  assign issue_meta    = issue_tbl_q[issue_pnt_q];
+  assign issue_ctrl    = ctrl_tbl_q[issue_pnt_q];
+  assign proc_ctrl     = ctrl_tbl_q[proc_pnt_q];
+  assign commit_ctrl   = ctrl_tbl_q[commit_pnt_q];
+
+  assign issue_active  = (issue_insns_q  != '0);
+  assign proc_active   = (proc_insns_q   != '0);
+  assign commit_active = (commit_insns_q != '0);
+
+  // Replicate scalar operand once on accept according to SEW
+  function automatic elen_t replicate_scalar(input elen_t raw_scalar, input vew_e sew);
+    unique case (sew)
+      EW64   : replicate_scalar = raw_scalar;
+      EW32   : replicate_scalar = {2{raw_scalar[31:0]}};
+      EW16   : replicate_scalar = {4{raw_scalar[15:0]}};
+      default: replicate_scalar = {8{raw_scalar[ 7:0]}};
+    endcase
+  endfunction
+
+  // Effective pipeline depth per integer multiplier SEW for in-order hazard tracking
+  function automatic logic [2:0] mul_pipe_lat(input vew_e sew);
+    unique case (sew)
+      EW64   : mul_pipe_lat = 3'd4; // 3 internal stages + 1 output timing register
+      EW32   : mul_pipe_lat = 3'd2;
+      EW16   : mul_pipe_lat = 3'd1;
+      default: mul_pipe_lat = 3'd1; // 1 input register + combinational EW8 array
+    endcase
+  endfunction
+
+  ////////////////////
+  //  Result Queue  //
+  ////////////////////
+
+  localparam int unsigned ResultQueueDepth = 2;
+
+  typedef struct packed {
+    vid_t   id;
+    vaddr_t addr;
+    elen_t  wdata;
+    strb_t  be;
+    logic   sat;
+  } payload_t;
+
+  payload_t [ResultQueueDepth-1:0]            result_queue_d, result_queue_q;
+  logic     [ResultQueueDepth-1:0]            result_queue_valid_d, result_queue_valid_q;
+  logic     [idx_width(ResultQueueDepth)-1:0] result_queue_write_pnt_d, result_queue_write_pnt_q;
+  logic     [idx_width(ResultQueueDepth)-1:0] result_queue_read_pnt_d, result_queue_read_pnt_q;
+  logic     [idx_width(ResultQueueDepth):0]   result_queue_cnt_d, result_queue_cnt_q;
+
+  logic result_queue_full;
+  assign result_queue_full = (result_queue_cnt_q == ResultQueueDepth);
+
+  /////////////////////////////////////////////////////
+  //  Per-EW Clock-Gated SIMD Multiplier Subsystem   //
+  /////////////////////////////////////////////////////
+
+  logic [3:0] clkgate_ew_d, clkgate_ew_q;
+  logic [3:0] clk_ew;
+
+  for (genvar e = 0; e < 4; e++) begin : gen_ew_clkgate
+    tc_clk_gating i_ew_clk_gate (
+      .clk_i    (clk_i          ),
+      .en_i     (clkgate_ew_q[e]),
+      .test_en_i(1'b0           ),
+      .clk_o    (clk_ew[e]      )
+    );
+  end
+
+  elen_t  mul_op_a, mul_op_b, mul_op_c;
+  assign mul_op_a = issue_meta.use_scalar_op ? issue_meta.scalar_rep : mfpu_operand_i[0];
+  assign mul_op_b = mfpu_operand_i[1];
+  assign mul_op_c = mfpu_operand_i[2];
+
+  logic   [3:0] vmul_simd_in_valid;
+  logic   [3:0] vmul_simd_in_ready;
+  logic   [3:0] vmul_simd_out_valid;
+  logic   [3:0] vmul_simd_out_ready;
+  elen_t  [3:0] vmul_simd_result;
+  strb_t  [3:0] vmul_simd_mask;
+  vxsat_t [3:0] vmul_simd_vxsat;
+
+  // EW8: 1-stage input register (since LatMultiplierEW8 == 0) clocked by clk_ew[EW8]
+  elen_t   ew8_opa_q, ew8_opb_q, ew8_opc_q;
+  strb_t   ew8_mask_q;
+  ara_op_e ew8_op_q;
+  logic    ew8_valid_q;
+  logic    ew8_reg_ready;
+
+  assign ew8_reg_ready           = ~ew8_valid_q | vmul_simd_out_ready[EW8];
+  assign vmul_simd_in_ready[EW8] = ew8_reg_ready;
+
+  always_ff @(posedge clk_ew[EW8] or negedge rst_ni) begin
+    if (!rst_ni) begin
+      ew8_valid_q <= 1'b0;
+      ew8_opa_q   <= '0;
+      ew8_opb_q   <= '0;
+      ew8_opc_q   <= '0;
+      ew8_mask_q  <= '0;
+      ew8_op_q    <= ara_op_e'('0);
+    end else if (ew8_reg_ready) begin
+      ew8_valid_q <= vmul_simd_in_valid[EW8];
+      if (vmul_simd_in_valid[EW8]) begin
+        ew8_opa_q  <= mul_op_a;
+        ew8_opb_q  <= mul_op_b;
+        ew8_opc_q  <= mul_op_c;
+        ew8_mask_q <= mask_i;
+        ew8_op_q   <= issue_meta.op;
+      end
+    end
+  end
+
+  simd_mul #(
+    .FixPtSupport(FixPtSupport    ),
+    .NumPipeRegs (LatMultiplierEW8),
+    .ElementWidth(EW8             )
+  ) i_simd_mul_ew8 (
+    .clk_i      (clk_ew[EW8]              ),
+    .rst_ni     (rst_ni                   ),
+    .operand_a_i(ew8_opa_q                ),
+    .operand_b_i(ew8_opb_q                ),
+    .operand_c_i(ew8_opc_q                ),
+    .mask_i     (ew8_mask_q               ),
+    .op_i       (ew8_op_q                 ),
+    .result_o   (vmul_simd_result[EW8]    ),
+    .mask_o     (vmul_simd_mask[EW8]      ),
+    .vxsat_o    (vmul_simd_vxsat[EW8]     ),
+    .vxrm_i     (mfpu_vxrm_i              ),
+    .valid_i    (ew8_valid_q              ),
+    .ready_o    (/* unused: NumPipeRegs=0 */),
+    .ready_i    (vmul_simd_out_ready[EW8] ),
+    .valid_o    (vmul_simd_out_valid[EW8] )
+  );
+
+  // EW16: internal 1-stage pipeline clocked by clk_ew[EW16]
+  simd_mul #(
+    .FixPtSupport(FixPtSupport     ),
+    .NumPipeRegs (LatMultiplierEW16),
+    .ElementWidth(EW16             )
+  ) i_simd_mul_ew16 (
+    .clk_i      (clk_ew[EW16]              ),
+    .rst_ni     (rst_ni                    ),
+    .operand_a_i(mul_op_a                  ),
+    .operand_b_i(mul_op_b                  ),
+    .operand_c_i(mul_op_c                  ),
+    .mask_i     (mask_i                    ),
+    .op_i       (issue_meta.op             ),
+    .result_o   (vmul_simd_result[EW16]    ),
+    .mask_o     (vmul_simd_mask[EW16]      ),
+    .vxsat_o    (vmul_simd_vxsat[EW16]     ),
+    .vxrm_i     (mfpu_vxrm_i               ),
+    .valid_i    (vmul_simd_in_valid[EW16]  ),
+    .ready_o    (vmul_simd_in_ready[EW16]  ),
+    .ready_i    (vmul_simd_out_ready[EW16] ),
+    .valid_o    (vmul_simd_out_valid[EW16] )
+  );
+
+  // EW32: internal 2-stage pipeline clocked by clk_ew[EW32]
+  simd_mul #(
+    .FixPtSupport(FixPtSupport     ),
+    .NumPipeRegs (LatMultiplierEW32),
+    .ElementWidth(EW32             )
+  ) i_simd_mul_ew32 (
+    .clk_i      (clk_ew[EW32]              ),
+    .rst_ni     (rst_ni                    ),
+    .operand_a_i(mul_op_a                  ),
+    .operand_b_i(mul_op_b                  ),
+    .operand_c_i(mul_op_c                  ),
+    .mask_i     (mask_i                    ),
+    .op_i       (issue_meta.op             ),
+    .result_o   (vmul_simd_result[EW32]    ),
+    .mask_o     (vmul_simd_mask[EW32]      ),
+    .vxsat_o    (vmul_simd_vxsat[EW32]     ),
+    .vxrm_i     (mfpu_vxrm_i               ),
+    .valid_i    (vmul_simd_in_valid[EW32]  ),
+    .ready_o    (vmul_simd_in_ready[EW32]  ),
+    .ready_i    (vmul_simd_out_ready[EW32] ),
+    .valid_o    (vmul_simd_out_valid[EW32] )
+  );
+
+  // EW64: internal 3-stage pipeline + 1-stage output register isolating the 64x64 MAC array from result_queue muxes
+  elen_t  ew64_raw_res, ew64_res_q;
+  strb_t  ew64_raw_mask, ew64_mask_q;
+  vxsat_t ew64_raw_vxsat, ew64_vxsat_q;
+  logic   ew64_raw_valid, ew64_raw_ready, ew64_valid_q;
+
+  assign ew64_raw_ready = ~ew64_valid_q | vmul_simd_out_ready[EW64];
+
+  simd_mul #(
+    .FixPtSupport(FixPtSupport     ),
+    .NumPipeRegs (LatMultiplierEW64),
+    .ElementWidth(EW64             )
+  ) i_simd_mul_ew64 (
+    .clk_i      (clk_ew[EW64]             ),
+    .rst_ni     (rst_ni                   ),
+    .operand_a_i(mul_op_a                 ),
+    .operand_b_i(mul_op_b                 ),
+    .operand_c_i(mul_op_c                 ),
+    .mask_i     (mask_i                   ),
+    .op_i       (issue_meta.op            ),
+    .result_o   (ew64_raw_res             ),
+    .mask_o     (ew64_raw_mask            ),
+    .vxsat_o    (ew64_raw_vxsat           ),
+    .vxrm_i     (mfpu_vxrm_i              ),
+    .valid_i    (vmul_simd_in_valid[EW64] ),
+    .ready_o    (vmul_simd_in_ready[EW64] ),
+    .ready_i    (ew64_raw_ready           ),
+    .valid_o    (ew64_raw_valid           )
+  );
+
+  always_ff @(posedge clk_ew[EW64] or negedge rst_ni) begin
+    if (!rst_ni) begin
+      ew64_valid_q <= 1'b0;
+      ew64_res_q   <= '0;
+      ew64_mask_q  <= '0;
+      ew64_vxsat_q <= '0;
+    end else if (ew64_raw_ready) begin
+      ew64_valid_q <= ew64_raw_valid;
+      if (ew64_raw_valid) begin
+        ew64_res_q   <= ew64_raw_res;
+        ew64_mask_q  <= ew64_raw_mask;
+        ew64_vxsat_q <= ew64_raw_vxsat;
+      end
+    end
+  end
+
+  assign vmul_simd_result[EW64]    = ew64_res_q;
+  assign vmul_simd_mask[EW64]      = ew64_mask_q;
+  assign vmul_simd_vxsat[EW64]     = ew64_vxsat_q;
+  assign vmul_simd_out_valid[EW64] = ew64_valid_q;
+
+  logic  vmul_in_valid, vmul_in_ready, vmul_out_valid, vmul_out_ready;
+  elen_t vmul_result;
+  strb_t vmul_mask;
+  logic [7:0] vmul_vxsat_bits;
+
+  always_comb begin : p_vmul_steer
+    vmul_simd_in_valid  = '0;
+    vmul_simd_out_ready = '0;
+
+    vmul_simd_in_valid [issue_ctrl.vsew] = clkgate_ew_q[issue_ctrl.vsew] & vmul_in_valid;
+    vmul_in_ready                        = clkgate_ew_q[issue_ctrl.vsew] & vmul_simd_in_ready[issue_ctrl.vsew];
+
+    vmul_result                          = vmul_simd_result   [proc_ctrl.vsew];
+    vmul_mask                            = vmul_simd_mask     [proc_ctrl.vsew];
+    vmul_vxsat_bits                      = vmul_simd_vxsat    [proc_ctrl.vsew];
+    vmul_out_valid                       = vmul_simd_out_valid[proc_ctrl.vsew];
+    vmul_simd_out_ready[proc_ctrl.vsew]  = vmul_out_ready;
+  end
+
+  ///////////////
+  //  Divider  //
+  ///////////////
+
+  elen_t vdiv_result;
+  strb_t vdiv_mask;
+  strb_t issue_be;
+  logic  vdiv_in_valid, vdiv_in_ready, vdiv_out_valid, vdiv_out_ready;
+
+  simd_div #(
+    .CVA6Cfg(CVA6Cfg)
+  ) i_simd_div (
+    .clk_i      (clk_i                                                            ),
+    .rst_ni     (rst_ni                                                           ),
+    .operand_a_i(mfpu_operand_i[1]                                                ),
+    .operand_b_i(issue_meta.use_scalar_op ? issue_meta.scalar_rep : mfpu_operand_i[0]),
+    .mask_i     (mask_i                                                           ),
+    .op_i       (issue_meta.op                                                    ),
+    .be_i       (issue_be                                                         ),
+    .vew_i      (issue_ctrl.vsew                                                  ),
+    .result_o   (vdiv_result                                                      ),
+    .mask_o     (vdiv_mask                                                        ),
+    .valid_i    (vdiv_in_valid                                                    ),
+    .ready_o    (vdiv_in_ready                                                    ),
+    .ready_i    (vdiv_out_ready                                                   ),
+    .valid_o    (vdiv_out_valid                                                   )
+  );
+
+  //////////////////////////////////////////
+  //  Multi-Phase Control & Writeback     //
+  //////////////////////////////////////////
+
+  vlen_t  issue_cnt_d,      issue_cnt_q;
+  vlen_t  to_process_cnt_d, to_process_cnt_q;
+  vlen_t  commit_cnt_d,     commit_cnt_q;
+  vaddr_t proc_vaddr_d,     proc_vaddr_q;
+
+  logic operands_valid;
+  logic latency_stall;
+  logic unit_out_valid;
+  elen_t unit_out_result;
+  strb_t unit_out_mask;
+  logic [3:0] issue_elem_cnt;
+  logic [3:0] proc_elem_cnt;
+  logic [3:0] commit_elem_cnt;
+  strb_t      entry_be;
+  vaddr_t     new_base_vaddr;
+
+  always_comb begin : p_vmfpu
+    issue_tbl_d    = issue_tbl_q;
+    ctrl_tbl_d     = ctrl_tbl_q;
+    accept_pnt_d   = accept_pnt_q;
+    issue_pnt_d    = issue_pnt_q;
+    proc_pnt_d     = proc_pnt_q;
+    commit_pnt_d   = commit_pnt_q;
+    issue_insns_d  = issue_insns_q;
+    proc_insns_d   = proc_insns_q;
+    commit_insns_d = commit_insns_q;
+
+    issue_cnt_d      = issue_cnt_q;
+    to_process_cnt_d = to_process_cnt_q;
+    commit_cnt_d     = commit_cnt_q;
+    proc_vaddr_d     = proc_vaddr_q;
+
+    result_queue_d           = result_queue_q;
+    result_queue_valid_d     = result_queue_valid_q;
+    result_queue_read_pnt_d  = result_queue_read_pnt_q;
+    result_queue_write_pnt_d = result_queue_write_pnt_q;
+    result_queue_cnt_d       = result_queue_cnt_q;
+
+    mfpu_ready_o         = !vinsn_queue_full;
+    mfpu_vinsn_done_o    = '0;
+    mfpu_operand_ready_o = '0;
+    mask_ready_o         = 1'b0;
+
+    vmul_in_valid  = 1'b0;
+    vdiv_in_valid  = 1'b0;
+    vmul_out_ready = ~result_queue_full & proc_active & ~proc_ctrl.is_div;
+    vdiv_out_ready = ~result_queue_full & proc_active &  proc_ctrl.is_div;
+
+    issue_be        = '0;
+    issue_elem_cnt  = '0;
+    proc_elem_cnt   = '0;
+    commit_elem_cnt = '0;
+    entry_be        = '0;
+    new_base_vaddr  = '0;
+
+    // Enforce strict in-order completion across variable-latency division and differing-SEW multipliers
+    latency_stall = issue_active & proc_active & (issue_pnt_q != proc_pnt_q) &
+                    (issue_ctrl.is_div | proc_ctrl.is_div |
+                     (mul_pipe_lat(issue_ctrl.vsew) < mul_pipe_lat(proc_ctrl.vsew)));
+
+    operands_valid = ((mfpu_operand_valid_i & issue_meta.req_op_mask) == issue_meta.req_op_mask) &&
+                     (mask_valid_i || issue_ctrl.vm);
+
+    // ---------------------------------------------------
+    // 1. Issue Phase
+    // ---------------------------------------------------
+    if (issue_active && operands_valid && (issue_cnt_q != '0) && !latency_stall) begin
+      issue_elem_cnt = 4'd1 << (2'(EW64) - 2'(issue_ctrl.vsew));
+      if (vlen_t'(issue_elem_cnt) > issue_cnt_q) begin
+        issue_elem_cnt = issue_cnt_q[3:0];
+      end
+      issue_be = be(issue_elem_cnt, issue_ctrl.vsew) & (issue_ctrl.vm ? {StrbWidth{1'b1}} : mask_i);
+
+      vmul_in_valid = ~issue_ctrl.is_div;
+      vdiv_in_valid =  issue_ctrl.is_div;
+
+      if ((~issue_ctrl.is_div && vmul_in_ready) || (issue_ctrl.is_div && vdiv_in_ready)) begin
+        mfpu_operand_ready_o = issue_meta.req_op_mask;
+        mask_ready_o         = ~issue_ctrl.vm;
+
+        issue_cnt_d = issue_cnt_q - vlen_t'(issue_elem_cnt);
+        if (issue_cnt_d == '0) begin
+          issue_insns_d = issue_insns_q - 1'b1;
+          issue_pnt_d   = (issue_pnt_q == PntWidth'(VInsnQueueDepth - 1)) ? '0 : (issue_pnt_q + 1'b1);
+          if (issue_insns_d != '0) begin
+            issue_cnt_d = ctrl_tbl_q[issue_pnt_d].vl;
+          end
+        end
+      end
+    end
+
+    // ---------------------------------------------------
+    // 2. Processing Phase -> Result Queue Write
+    // ---------------------------------------------------
+    if (proc_ctrl.is_div) begin
+      unit_out_valid  = vdiv_out_valid;
+      unit_out_result = vdiv_result;
+      unit_out_mask   = vdiv_mask;
+    end else begin
+      unit_out_valid  = vmul_out_valid;
+      unit_out_result = vmul_result;
+      unit_out_mask   = vmul_mask;
+    end
+
+    if (proc_active && unit_out_valid && !result_queue_full) begin
+      proc_elem_cnt = 4'd1 << (2'(EW64) - 2'(proc_ctrl.vsew));
+      if (vlen_t'(proc_elem_cnt) > to_process_cnt_q) begin
+        proc_elem_cnt = to_process_cnt_q[3:0];
+      end
+
+      entry_be = be(proc_elem_cnt, proc_ctrl.vsew) &
+                 (proc_ctrl.vm ? {StrbWidth{1'b1}} : unit_out_mask);
+
+      result_queue_d[result_queue_write_pnt_q].id    = proc_ctrl.id;
+      result_queue_d[result_queue_write_pnt_q].addr  = proc_vaddr_q;
+      result_queue_d[result_queue_write_pnt_q].wdata = unit_out_result;
+      result_queue_d[result_queue_write_pnt_q].be    = entry_be;
+      result_queue_d[result_queue_write_pnt_q].sat   = proc_ctrl.is_vsmul & (|(vmul_vxsat_bits & entry_be));
+      result_queue_valid_d[result_queue_write_pnt_q] = 1'b1;
+
+      result_queue_cnt_d       = result_queue_cnt_q + 1'b1;
+      result_queue_write_pnt_d = (result_queue_write_pnt_q == ResultQueueDepth - 1) ? '0 : (result_queue_write_pnt_q + 1'b1);
+
+      to_process_cnt_d = to_process_cnt_q - vlen_t'(proc_elem_cnt);
+      if (to_process_cnt_d == '0) begin
+        proc_insns_d = proc_insns_q - 1'b1;
+        proc_pnt_d   = (proc_pnt_q == PntWidth'(VInsnQueueDepth - 1)) ? '0 : (proc_pnt_q + 1'b1);
+        if (proc_insns_d != '0) begin
+          to_process_cnt_d = ctrl_tbl_q[proc_pnt_d].vl;
+          proc_vaddr_d     = ctrl_tbl_q[proc_pnt_d].base_vaddr;
+        end
+      end else begin
+        proc_vaddr_d = proc_vaddr_q + 1'b1;
+      end
+    end
+
+    // ---------------------------------------------------
+    // 3. VRF Writeback & Commit Phase
+    // ---------------------------------------------------
+    mfpu_result_req_o   = result_queue_valid_q[result_queue_read_pnt_q];
+    mfpu_result_id_o    = result_queue_q[result_queue_read_pnt_q].id;
+    mfpu_result_addr_o  = result_queue_q[result_queue_read_pnt_q].addr;
+    mfpu_result_wdata_o = result_queue_q[result_queue_read_pnt_q].wdata;
+    mfpu_result_be_o    = result_queue_q[result_queue_read_pnt_q].be;
+    mfpu_vxsat_o        = result_queue_valid_q[result_queue_read_pnt_q] & result_queue_q[result_queue_read_pnt_q].sat;
+
+    if (mfpu_result_gnt_i) begin
+      commit_elem_cnt = 4'd1 << (2'(EW64) - 2'(commit_ctrl.vsew));
+
+      result_queue_valid_d[result_queue_read_pnt_q] = 1'b0;
+      result_queue_d[result_queue_read_pnt_q]       = '0;
+      result_queue_read_pnt_d = (result_queue_read_pnt_q == ResultQueueDepth - 1) ? '0 : (result_queue_read_pnt_q + 1'b1);
+      result_queue_cnt_d      = result_queue_cnt_d - 1'b1;
+
+      if (commit_cnt_q <= vlen_t'(commit_elem_cnt)) begin
+        commit_cnt_d = '0;
+      end else begin
+        commit_cnt_d = commit_cnt_q - vlen_t'(commit_elem_cnt);
+      end
+    end
+
+    if (commit_active && (commit_cnt_d == '0)) begin
+      mfpu_vinsn_done_o[commit_ctrl.id] = 1'b1;
+      commit_insns_d = commit_insns_q - 1'b1;
+      commit_pnt_d   = (commit_pnt_q == PntWidth'(VInsnQueueDepth - 1)) ? '0 : (commit_pnt_q + 1'b1);
+      if (commit_insns_d != '0) begin
+        commit_cnt_d = ctrl_tbl_q[commit_pnt_d].vl;
+      end
+    end
+
+    // ---------------------------------------------------
+    // 4. Accept New Vector Instruction
+    // ---------------------------------------------------
+    if (!vinsn_queue_full && vfu_operation_valid_i && (vfu_operation_i.vfu == VFU_MFpu)) begin
+      new_base_vaddr = vaddr_t'(vaddr(vfu_operation_i.vd, NrLanes, VLEN));
+
+      issue_tbl_d[accept_pnt_q].scalar_rep    = vfu_operation_i.use_scalar_op ?
+                                                replicate_scalar(vfu_operation_i.scalar_op, vfu_operation_i.vtype.vsew) : '0;
+      issue_tbl_d[accept_pnt_q].use_scalar_op = vfu_operation_i.use_scalar_op;
+      issue_tbl_d[accept_pnt_q].req_op_mask   = vfu_operation_i.swap_vs2_vd_op ?
+                                                {vfu_operation_i.use_vs2, vfu_operation_i.use_vd_op, vfu_operation_i.use_vs1} :
+                                                {vfu_operation_i.use_vd_op, vfu_operation_i.use_vs2, vfu_operation_i.use_vs1};

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
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv`](environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/power_gating_generic.sv`](environment/public/code/power_gating_generic.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rvv_pkg.sv`](environment/public/code/rvv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/serdiv.sv`](environment/public/code/serdiv.sv) *(Read-Only Context)*
- [`environment/public/code/simd_div.sv`](environment/public/code/simd_div.sv) **(Editable)**
- [`environment/public/code/simd_mul.sv`](environment/public/code/simd_mul.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/tc_clk.sv`](environment/public/code/tc_clk.sv) *(Read-Only Context)*
- [`environment/public/code/vmfpu.sv`](environment/public/code/vmfpu.sv) **(Editable)**
- [`environment/public/code/vmfpu_synth_top.sv`](environment/public/code/vmfpu_synth_top.sv) *(Read-Only Context)*
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

