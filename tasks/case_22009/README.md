# `case_22009`: RedMulE Systolic Wave-Front Small-Tile Promotion, Leftover Boundary Synchronization, and Multi-Pass Loopback Scheduling

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22009` |
| **Source Silicon Repository** | `pulp-platform/redmule` (`repo_30`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/redmule_tiler.sv`](environment/public/code/redmule_tiler.sv), [`code/redmule_scheduler.sv`](environment/public/code/redmule_scheduler.sv), [`code/redmule_memory_scheduler.sv`](environment/public/code/redmule_memory_scheduler.sv) (3 files, 1529 LOC) |
| **Public Subsystem Context** | 32 RTL files (6783 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Systolic Tiling, Boundary Scheduling, and Multi-Job Queue Hazards in RedMulE

## Architecture & Functional Contract

`code/redmule_subsys.sv` integrates the RedMulE FP16 systolic matrix-multiplication and GEMM subsystem (`DataW = 128`, `FpFormat = FP16`, `Width = 4`, `Height = 4`, `NumPipeRegs = 1`, `PipeConfig = DISTRIBUTED`, `8` FP16 elements / `16` bytes per memory beat). Its lockstep `Width x Height` engine is coordinated by `code/redmule_tiler.sv`, `code/redmule_memory_scheduler.sv`, and `code/redmule_scheduler.sv`.

For arbitrary matrix dimensions `M >= 1` (`m_size`), `N >= 1` (`n_size`), and `K >= 1` (`k_size`), the subsystem computes row-major FP16 `MATMUL` (`Z = X * W`, `gemm_selection == 1'b0`) or `GEMM` (`Z = X * W + Y`, `gemm_selection == 1'b1`) under round-to-nearest-even (`RNE`) accumulation:
- **Memory layout** (2 bytes per FP16 element): `X` (`M x N`, row stride `2*N` at `x_addr`), `W` (`N x K`, row stride `2*K` at `w_addr`), `Y` (`M x K`, row stride `2*K` at `y_addr` when `gemm_selection == 1'b1`), and `Z` (`M x K`, row stride `2*K` at `z_addr`).
- **Two-pass weight loopback (`w_cols_offset`)**: When `w_cols_offset == 0`, all `K` columns run in a single pass. When `0 < w_cols_offset < K` (a multiple of `8`), Pass 0 computes columns `[w_cols_offset .. K - 1]` (offset by `+2 * w_cols_offset` bytes in `W`, `Y`, `Z`) and Pass 1 computes columns `[0 .. w_cols_offset - 1]` from base addresses before retiring the job.
- **Boundary & strobe safety**: Live TCDM regions sit immediately adjacent to `W` and `Z`. Padded systolic rows/columns beyond `(M, N, K)` must never corrupt accumulation with out-of-bounds memory data, `z_stream_strb_o` must enable only valid column bytes `[0 .. K - 1]`, and store transfers must never write rows `>= M` when `M % Width != 0`.
- **Stalls, queued jobs, & clear**: Under arbitrary stream/handshake backpressure and back-to-back job queuing in `i_config_fifo` (including across `loopback_w` and leftover tiles), each job must pulse `done_o` once after its final `Z` beat drains without cross-job config corruption or empty-FIFO pops. Asserting `target_clear_i` mid-job must synchronously reset control/queue state so subsequent jobs run cleanly.

## Problem Statement

Across small and non-multiple matrix dimensions (`1 <= N <= 4`, `N % Height != 0`, `M % Width != 0`, odd/leftover `K`), `GEMM` bias preloads, two-pass `w_cols_offset` loopback, back-to-back queued descriptors, and mid-job `target_clear_i` resets, the subsystem currently suffers from systolic wave-front hangs, out-of-bounds weight/output corruption, store-strobe misalignment, and configuration-queue hazards. Fix the control, tiling, and memory-scheduling logic so all single-job and back-to-back queued `MATMUL`/`GEMM` workloads pass end-to-end.

## Deliverable Constraints

- Modify **only** `code/redmule_tiler.sv`, `code/redmule_scheduler.sv`, and `code/redmule_memory_scheduler.sv`.
- Keep all module names, parameter lists, port signatures, and other files under `code/` unchanged.
- Strictly synthesizable synchronous RTL (`yosys -m slang` elaboration with zero inferred latches and no simulator-specific macro divergence).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Guide

## Available Tools

The workspace environment provides the following EDA tools:

- **Verilator v5.038**: `verilator`
- **Yosys (with `slang` SystemVerilog frontend)**: `yosys`

## RTL File Compilation Order

All package headers, common cells, buffers, datapath units, and subsystem RTL reside in `code/` (with macro headers in `code/include/`):

```bash
RTL_FILES=(
  code/fpnew_pkg.sv
  code/cf_math_pkg.sv
  code/hci_package.sv
  code/hwpe_ctrl_package.sv
  code/hwpe_stream_package.sv
  code/redmule_pkg.sv
  code/tc_clk.sv
  code/edge_detect.sv
  code/sync.sv
  code/sync_wedge.sv
  code/lzc.sv
  code/hwpe_stream_fifo.sv
  code/fpnew_classifier.sv
  code/fpnew_rounding.sv
  code/redmule_fma.sv
  code/redmule_row.sv
  code/redmule_engine.sv
  code/x_buffer/redmule_x_pad_scm.sv
  code/x_buffer/redmule_x_buffer_scm.sv
  code/x_buffer/redmule_x_buffer.sv
  code/w_buffer/redmule_w_buffer_scm.sv
  code/w_buffer/redmule_w_buffer.sv
  code/z_buffer/redmule_z_buffer_scm.sv
  code/z_buffer/redmule_z_buffer.sv
  code/redmule_config_fifo.sv
  code/redmule_ctrl.sv
  code/redmule_tiler.sv
  code/redmule_memory_scheduler.sv
  code/redmule_scheduler.sv
  code/redmule_subsys.sv
)
```

## Lint & Simulation with Verilator

To lint the full `redmule_subsys` hierarchy:

```bash
verilator \
  --lint-only -Wno-fatal -Wno-TIMESCALEMOD \
  -Icode/include \
  --top-module redmule_subsys \
  "${RTL_FILES[@]}"
```

To build and run your own SystemVerilog testbench (for example in `/tmp/my_tb.sv`):

```bash
verilator \
  --binary -j 4 -O1 -CFLAGS "-O0" \
  -Wno-fatal -Wno-TIMESCALEMOD \
  -Icode/include \
  --top-module my_tb \
  --Mdir /tmp/obj_dir \
  "${RTL_FILES[@]}" /tmp/my_tb.sv

/tmp/obj_dir/Vmy_tb
```

> **Note**: Keep any scratch testbenches or build directories outside `code/` (or clean them up before finishing); only `code/redmule_tiler.sv`, `code/redmule_scheduler.sv`, and `code/redmule_memory_scheduler.sv` are collected for grading.

## Synthesis & Zero-Latch Elaboration Check (`yosys -m slang`)

Verify that the subsystem elaborates cleanly with zero unintended latches (`$dlatch`):

```bash
yosys -m slang -p "
  read_slang --top redmule_subsys --keep-hierarchy --allow-use-before-declare --ignore-assertions -Wno-range-oob -I code/include ${RTL_FILES[*]};
  hierarchy -check -top redmule_subsys;
  blackbox *tc_clk_gating*;
  proc;
  opt_clean;
  check;
  select -assert-none t:\$dlatch
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/redmule_tiler.sv (Buggy Starter)
+++ b/solution/gold/code/redmule_tiler.sv (Golden Reference)
@@ -38,6 +38,10 @@
 redmule_config_t input_config_d, input_config_q;
 redmule_config_t config_d, config_q;
 logic loopback_active_q, loopback_active;
+logic start_new_cfg;
+
+assign loopback_active = (loopback_i || loopback_active_q);
+assign start_new_cfg   = start_cfg_i && ready_i && ~clk_en && ~loopback_active;
 
 always_ff @(posedge clk_i, negedge rst_ni) begin: clock_gate_enabler
   if (~rst_ni) begin
@@ -45,7 +49,7 @@
   end else begin
     if (clear_i || setback_i) begin
       clk_en <= 1'b0;
-    end else if ((start_cfg_i && ready_i) || loopback_i) begin
+    end else if (start_new_cfg || loopback_i) begin
       clk_en <= 1'b1;
     end
   end
@@ -60,8 +64,6 @@
 
 assign busy_o = clk_en || ~ready_i;
 
-// Store loopback
-assign loopback_active = (loopback_i || loopback_active_q);
 always_ff @(posedge clk_i, negedge rst_ni) begin: loopback_ff
   if (~rst_ni) begin
     loopback_active_q <= 1'b0;
@@ -75,12 +77,12 @@
     input_config_q <= '0;
   end else if (clear_i) begin
     input_config_q <= '0;
-  end else if (start_cfg_i && ready_i) begin
+  end else if (start_new_cfg) begin
     input_config_q <= config_i;
   end
 end
 
-assign input_config_d           = loopback_active ? input_config_q : config_i;
+assign input_config_d           = (loopback_active || clk_en) ? input_config_q : config_i;
 assign config_d.x_addr          = input_config_d.x_addr;
 assign config_d.w_addr          = loopback_active ? input_config_d.w_addr :
                                   input_config_d.w_addr + input_config_d.w_cols_offset * (FpWidth/8);
@@ -91,6 +93,10 @@
 assign config_d.m_size          = input_config_d.m_size;
 assign config_d.k_size          = input_config_d.k_size;
 assign config_d.n_size          = input_config_d.n_size;
+
+logic [15:0] n_size_eff;
+assign n_size_eff = (input_config_d.n_size <= Height) ? MinimumSizeN[15:0] : input_config_d.n_size;
+
 assign config_d.gemm_ops        = input_config_d.gemm_ops;
 assign config_d.gemm_input_fmt  = input_config_d.gemm_input_fmt;
 assign config_d.gemm_output_fmt = input_config_d.gemm_output_fmt;
@@ -102,141 +108,92 @@
 assign config_d.w_cols_offset   = loopback_active ? '0 : input_config_d.w_cols_offset;
 assign config_d.y_offs          = input_config_d.y_offs;
 
-// Calculating the number of iterations along the two dimensions of the X matrix
 logic [15:0] x_rows_iter_nolftovr;
 logic [15:0] x_cols_iter_nolftovr;
 assign x_rows_iter_nolftovr = config_d.m_size / Width;
 assign x_cols_iter_nolftovr = config_d.n_size / (Height * (PipeRegs + 1));
 
-// Calculating the number of iterations along the two dimensions of the W matrix
 logic [15:0] w_cols_iter_nolftovr;
 logic [15:0] w_rows_iter_lftovr,
              w_rows_iter_nolftovr;
 assign w_cols_iter_nolftovr = loopback_active ? (input_config_d.w_cols_offset / (Height * (PipeRegs + 1))) :
                               (config_d.k_size - input_config_d.w_cols_offset) / (Height * (PipeRegs + 1));
 assign w_rows_iter_lftovr   = w_rows_iter_nolftovr + Height - config_d.w_rows_lftovr;
-assign w_rows_iter_nolftovr = config_d.n_size;
-
-// Calculating the residuals along the input dimensions
+assign w_rows_iter_nolftovr = n_size_eff;
+
 assign config_d.x_rows_lftovr = config_d.m_size - (x_rows_iter_nolftovr * Width);
 assign config_d.x_cols_lftovr = config_d.n_size - (x_cols_iter_nolftovr * (Height * (PipeRegs + 1)));
 
-// Calculating the residuals along the weight dimensions
-assign config_d.w_rows_lftovr = config_d.n_size - (Height * (config_d.n_size / Height));
+assign config_d.w_rows_lftovr = n_size_eff - (Height * (n_size_eff / Height));
 assign config_d.w_cols_lftovr = loopback_active ? input_config_d.w_cols_offset - (w_cols_iter_nolftovr * (Height * (PipeRegs + 1))) :
                                 (config_d.k_size - input_config_d.w_cols_offset) - (w_cols_iter_nolftovr * (Height * (PipeRegs + 1)));
 
-// Calculate w_cols iterations
 assign config_d.w_cols_iter = config_d.w_cols_lftovr != '0 ? w_cols_iter_nolftovr + 1 : w_cols_iter_nolftovr;
-
-// Calculate w_rows, x_cols, x_rows iterations
 assign config_d.w_rows_iter = config_d.w_rows_lftovr != '0 ? w_rows_iter_lftovr       : w_rows_iter_nolftovr;
 assign config_d.x_cols_iter = config_d.x_cols_lftovr != '0 ? x_cols_iter_nolftovr + 1 : x_cols_iter_nolftovr;
 assign config_d.x_rows_iter = config_d.x_rows_lftovr != '0 ? x_rows_iter_nolftovr + 1 : x_rows_iter_nolftovr;
 
-// Sequential multiplier x_rows x w_cols
 logic [31:0] x_rows_by_w_cols_iter_d, x_rows_by_w_cols_iter_q;
 logic        x_rows_by_w_cols_iter_valid_d, x_rows_by_w_cols_iter_valid_q;
 
-assign x_rows_by_w_cols_iter_d = (start_cfg_i || loopback_i) ? config_d.x_rows_iter * config_d.w_cols_iter : x_rows_by_w_cols_iter_q;
+assign x_rows_by_w_cols_iter_d       = (start_new_cfg || loopback_i) ? config_d.x_rows_iter * config_d.w_cols_iter : x_rows_by_w_cols_iter_q;
+assign x_rows_by_w_cols_iter_valid_d = (start_new_cfg || loopback_i);
 
 always_ff @(posedge clk_i or negedge rst_ni) begin
   if (~rst_ni) begin
-    x_rows_by_w_cols_iter_q <= '0;
-  end else begin
-    if (clear_i | setback_i) begin
-      x_rows_by_w_cols_iter_q <= '0;
-    end else begin
-      x_rows_by_w_cols_iter_q <= x_rows_by_w_cols_iter_d;
-    end
-  end
-end
-
-assign x_rows_by_w_cols_iter_valid_d = (start_cfg_i || loopback_i);
-
-always_ff @(posedge clk_i or negedge rst_ni) begin
-  if (~rst_ni) begin
+    x_rows_by_w_cols_iter_q       <= '0;
     x_rows_by_w_cols_iter_valid_q <= '0;
-  end else begin
-    if (clear_i | setback_i) begin
-      x_rows_by_w_cols_iter_valid_q <= '0;
-    end else begin
-      x_rows_by_w_cols_iter_valid_q <= x_rows_by_w_cols_iter_valid_d;
-    end
-  end
-end
-
-// Sequential multiplier x_rows x w_cols x x_cols
+  end else if (clear_i | setback_i) begin
+    x_rows_by_w_cols_iter_q       <= '0;
+    x_rows_by_w_cols_iter_valid_q <= '0;
+  end else begin
+    x_rows_by_w_cols_iter_q       <= x_rows_by_w_cols_iter_d;
+    x_rows_by_w_cols_iter_valid_q <= x_rows_by_w_cols_iter_valid_d;
+  end
+end
+
 logic [47:0] x_rows_by_w_cols_by_x_cols_iter_d, x_rows_by_w_cols_by_x_cols_iter_q;
 logic        x_rows_by_w_cols_by_x_cols_iter_valid_d, x_rows_by_w_cols_by_x_cols_iter_valid_q;
 
-assign x_rows_by_w_cols_by_x_cols_iter_d = x_rows_by_w_cols_iter_valid_q ? config_d.x_cols_iter * x_rows_by_w_cols_iter_q : x_rows_by_w_cols_by_x_cols_iter_q;
+assign x_rows_by_w_cols_by_x_cols_iter_d       = x_rows_by_w_cols_iter_valid_q ? config_d.x_cols_iter * x_rows_by_w_cols_iter_q : x_rows_by_w_cols_by_x_cols_iter_q;
+assign x_rows_by_w_cols_by_x_cols_iter_valid_d = x_rows_by_w_cols_iter_valid_q;
 
 always_ff @(posedge clk_i or negedge rst_ni) begin
   if (~rst_ni) begin
-    x_rows_by_w_cols_by_x_cols_iter_q <= '0;
-  end else begin
-    if (clear_i | setback_i) begin
-      x_rows_by_w_cols_by_x_cols_iter_q <= '0;
-    end else begin
-      x_rows_by_w_cols_by_x_cols_iter_q <= x_rows_by_w_cols_by_x_cols_iter_d;
-    end
-  end
-end
-
-assign x_rows_by_w_cols_by_x_cols_iter_valid_d = x_rows_by_w_cols_iter_valid_q;
-
-always_ff @(posedge clk_i or negedge rst_ni) begin
-  if (~rst_ni) begin
+    x_rows_by_w_cols_by_x_cols_iter_q       <= '0;
     x_rows_by_w_cols_by_x_cols_iter_valid_q <= '0;
-  end else begin
-    if (clear_i | setback_i) begin
-      x_rows_by_w_cols_by_x_cols_iter_valid_q <= '0;
-    end else begin
-      x_rows_by_w_cols_by_x_cols_iter_valid_q <= x_rows_by_w_cols_by_x_cols_iter_valid_d;
-    end
-  end
-end
-
-// Sequential multiplier x_rows x w_cols x w_rows
+  end else if (clear_i | setback_i) begin
+    x_rows_by_w_cols_by_x_cols_iter_q       <= '0;
+    x_rows_by_w_cols_by_x_cols_iter_valid_q <= '0;
+  end else begin
+    x_rows_by_w_cols_by_x_cols_iter_q       <= x_rows_by_w_cols_by_x_cols_iter_d;
+    x_rows_by_w_cols_by_x_cols_iter_valid_q <= x_rows_by_w_cols_by_x_cols_iter_valid_d;
+  end
+end
+
 logic [47:0] x_rows_by_w_cols_by_w_rows_iter_d, x_rows_by_w_cols_by_w_rows_iter_q;
 logic        x_rows_by_w_cols_by_w_rows_iter_valid_d, x_rows_by_w_cols_by_w_rows_iter_valid_q;
 
-assign x_rows_by_w_cols_by_w_rows_iter_d = x_rows_by_w_cols_iter_valid_q ? config_d.w_rows_iter * x_rows_by_w_cols_iter_q : x_rows_by_w_cols_by_w_rows_iter_q;
+assign x_rows_by_w_cols_by_w_rows_iter_d       = x_rows_by_w_cols_iter_valid_q ? config_d.w_rows_iter * x_rows_by_w_cols_iter_q : x_rows_by_w_cols_by_w_rows_iter_q;
+assign x_rows_by_w_cols_by_w_rows_iter_valid_d = x_rows_by_w_cols_iter_valid_q;
 
 always_ff @(posedge clk_i or negedge rst_ni) begin
   if (~rst_ni) begin
-    x_rows_by_w_cols_by_w_rows_iter_q <= '0;
-  end else begin
-    if (clear_i | setback_i) begin
-      x_rows_by_w_cols_by_w_rows_iter_q <= '0;
-    end else begin
-      x_rows_by_w_cols_by_w_rows_iter_q <= x_rows_by_w_cols_by_w_rows_iter_d;
-    end
-  end
-end
-
-assign x_rows_by_w_cols_by_w_rows_iter_valid_d = x_rows_by_w_cols_iter_valid_q;
-
-always_ff @(posedge clk_i or negedge rst_ni) begin
-  if (~rst_ni) begin
+    x_rows_by_w_cols_by_w_rows_iter_q       <= '0;
     x_rows_by_w_cols_by_w_rows_iter_valid_q <= '0;
-  end else begin
-    if (clear_i | setback_i) begin
-      x_rows_by_w_cols_by_w_rows_iter_valid_q <= '0;
-    end else begin
-      x_rows_by_w_cols_by_w_rows_iter_valid_q <= x_rows_by_w_cols_by_w_rows_iter_valid_d;
-    end
+  end else if (clear_i | setback_i) begin
+    x_rows_by_w_cols_by_w_rows_iter_q       <= '0;
+    x_rows_by_w_cols_by_w_rows_iter_valid_q <= '0;
+  end else begin
+    x_rows_by_w_cols_by_w_rows_iter_q       <= x_rows_by_w_cols_by_w_rows_iter_d;
+    x_rows_by_w_cols_by_w_rows_iter_valid_q <= x_rows_by_w_cols_by_w_rows_iter_valid_d;
   end
 end
 
 logic [31:0] buffer_slots;
-
-assign buffer_slots = config_d.x_cols_lftovr / Height;
-assign config_d.x_buffer_slots = ((config_d.x_cols_lftovr % Height != '0) ? buffer_slots + 1 :
-                                                                            buffer_slots) * Height;
-
-// Calculating the number of total stores
+assign buffer_slots            = config_d.x_cols_lftovr / Height;
+assign config_d.x_buffer_slots = ((config_d.x_cols_lftovr % Height != '0) ? buffer_slots + 1 : buffer_slots) * Height;
+
 assign config_d.tot_stores = x_rows_by_w_cols_iter_q[15:0];
 
 assign config_d.stage_1_rnd_mode = config_d.gemm_ops == MATMUL ? RNE :
@@ -278,7 +235,7 @@
 assign config_d.x_rows_offs  = Width*config_d.x_d1_stride;
 assign config_d.w_tot_len    = x_rows_by_w_cols_by_w_rows_iter_q[31:0];
 assign config_d.w_d0_stride  = ((4*FpWidth)/AddrWidth)*((DataW/FpWidth) * (config_d.k_size)/(Height*(PipeRegs + 1)));
-assign config_d.yz_tot_len   = Width*x_rows_by_w_cols_iter_q[15:0];
+assign config_d.yz_tot_len   = 32'(config_d.m_size) * 32'(config_d.w_cols_iter);
 assign config_d.yz_d0_stride = config_d.w_d0_stride;
 assign config_d.yz_d2_stride = Width*config_d.w_d0_stride;
 assign config_d.tot_x_read   = x_rows_by_w_cols_by_x_cols_iter_q[31:0];
@@ -304,6 +261,4 @@
 
 assign config_o = config_q;
 
-wire unused_min_n = ^MinimumSizeN;
-
 endmodule: redmule_tiler

--- a/environment/public/code/redmule_scheduler.sv (Buggy Starter)
+++ b/solution/gold/code/redmule_scheduler.sv (Golden Reference)
@@ -66,6 +66,8 @@
   redmule_fsm_state_e current_state, next_state;
 
   logic start;
+  logic fifo_flush;
+  assign fifo_flush = clear_i | cntrl_scheduler_i.rst;
 
   logic stall_engine,
         first_load,
@@ -96,7 +98,7 @@
   ) i_x_config_fifo (
     .clk_i      ( clk_i          ),
     .rst_ni     ( rst_ni         ),
-    .flush_i    ( clear_i        ),
+    .flush_i    ( fifo_flush     ),
     .testmode_i ( '0             ),
     .full_o     ( x_config_full  ),
     .empty_o    ( x_config_empty ),
@@ -104,18 +106,16 @@
     .data_i     ( config_i       ),
     .push_i     ( config_valid_i ),
     .data_o     ( x_config       ),
-    .pop_i      ( x_done_en      )
+    .pop_i      ( x_done_en && ~x_config_empty )
   );
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : x_columns_iteration
     if(~rst_ni) begin
       x_cols_iter_q <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst) begin
-        x_cols_iter_q <= '0;
-      end else if (x_cols_iter_en && ~x_done) begin
-        x_cols_iter_q <= x_cols_iter_d;
-      end
+    end else if (clear_i || cntrl_scheduler_i.rst) begin
+      x_cols_iter_q <= '0;
+    end else if (x_cols_iter_en && ~x_done) begin
+      x_cols_iter_q <= x_cols_iter_d;
     end
   end
 
@@ -124,12 +124,11 @@
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : weight_iteration_counter
     if(~rst_ni) begin
-      x_w_iters_q <= 0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst)
-        x_w_iters_q <= '0;
-      else if (x_w_iters_en && ~x_done)
-        x_w_iters_q <= x_w_iters_d;
+      x_w_iters_q <= '0;
+    end else if (clear_i || cntrl_scheduler_i.rst) begin
+      x_w_iters_q <= '0;
+    end else if (x_w_iters_en && ~x_done) begin
+      x_w_iters_q <= x_w_iters_d;
     end
   end
 
@@ -139,12 +138,10 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin : x_rows_iteration
     if(~rst_ni) begin
       x_rows_iter_q <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst) begin
-        x_rows_iter_q <= '0;
-      end else if (x_rows_iter_en && ~x_done) begin
-        x_rows_iter_q <= x_rows_iter_d;
-      end
+    end else if (clear_i || cntrl_scheduler_i.rst) begin
+      x_rows_iter_q <= '0;
+    end else if (x_rows_iter_en && ~x_done) begin
+      x_rows_iter_q <= x_rows_iter_d;
     end
   end
 
@@ -154,19 +151,20 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin : x_done_register
     if(~rst_ni) begin
       x_done <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst || (~x_done && x_config_full || x_done && config_valid_i)) begin
-        x_done <= '0;
-      end else if (x_done_en) begin
-        x_done <= '1;
-      end
+    end else if (clear_i || cntrl_scheduler_i.rst || (~x_done && x_config_full || x_done && config_valid_i)) begin
+      x_done <= '0;
+    end else if (x_done_en) begin
+      x_done <= '1;
     end
   end
 
   assign x_done_en = x_rows_iter_en && x_rows_iter_q == x_config.x_rows_iter-1 && x_w_iters_q == x_config.w_cols_iter-1 && x_cols_iter_q == x_config.x_cols_iter-1;
 
+  logic small_n_promoted_x;
+  assign small_n_promoted_x      = (x_config.n_size <= H);
   assign cntrl_x_buffer_o.height = x_cols_iter_q == x_config.x_cols_iter-1 && x_config.x_cols_lftovr != '0 ? x_config.x_cols_lftovr[$clog2(MaxDepth)-1:0] : D[$clog2(MaxDepth)-1:0];
-  assign cntrl_x_buffer_o.slots  = x_cols_iter_q == x_config.x_cols_iter-1 && x_config.x_cols_lftovr != '0 ? x_config.x_buffer_slots[$clog2(MaxDepth)-1:0] : D[$clog2(MaxDepth)-1:0];
+  assign cntrl_x_buffer_o.slots  = small_n_promoted_x ? D[$clog2(MaxDepth)-1:0]
+                                 : (x_cols_iter_q == x_config.x_cols_iter-1 && x_config.x_cols_lftovr != '0 ? x_config.x_buffer_slots[$clog2(MaxDepth)-1:0] : D[$clog2(MaxDepth)-1:0]);
   assign cntrl_x_buffer_o.width  = x_rows_iter_q == x_config.x_rows_iter-1 && x_config.x_rows_lftovr != '0 ? x_config.x_rows_lftovr[$clog2(MaxDim)-1:0] : W[$clog2(MaxDim)-1:0];
 
   /******************************
@@ -179,18 +177,17 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin : x_shift_counter
     if(~rst_ni) begin
       x_shift_cnt_q <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst || (flgs_x_buffer_i.full && flgs_x_buffer_i.empty))
-        x_shift_cnt_q <= '0;
-      else if (x_shift_cnt_en)
-        x_shift_cnt_q <= x_shift_cnt_d;
+    end else if (clear_i || cntrl_scheduler_i.rst || (flgs_x_buffer_i.full && flgs_x_buffer_i.empty)) begin
+      x_shift_cnt_q <= '0;
+    end else if (x_shift_cnt_en) begin
+      x_shift_cnt_q <= x_shift_cnt_d;
     end
   end
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : x_shift_offset
     if(~rst_ni) begin
       x_shift_offs_q <= '0;
-    end else if(clear_i) begin
+    end else if(clear_i || cntrl_scheduler_i.rst) begin
       x_shift_offs_q <= '0;
     end else if (flgs_x_buffer_i.full && flgs_x_buffer_i.empty) begin
       x_shift_offs_q <= x_shift_cnt_q + x_shift_offs_q;
@@ -207,32 +204,29 @@
    ******************************/
   logic x_reload_q;
   logic x_reload_en, x_reload_rst;
-
   logic x_empty;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : x_reload_register
     if(~rst_ni) begin
       x_reload_q <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst || x_reload_rst)
-        x_reload_q <= '0;
-      else if (x_reload_en)
-        x_reload_q <= '1;
+    end else if (clear_i || cntrl_scheduler_i.rst || x_reload_rst) begin
+      x_reload_q <= '0;
+    end else if (x_reload_en) begin
+      x_reload_q <= '1;
     end
   end
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : x_empty_register
     if(~rst_ni) begin
       x_empty <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst || ~flgs_x_buffer_i.full)
-        x_empty <= '0;
-      else if (flgs_x_buffer_i.full && flgs_x_buffer_i.empty)
-        x_empty <= '1;
-    end
-  end
-
-  assign x_reload_en  = start || x_cols_iter_en || x_empty && ~flgs_x_buffer_i.full;
+    end else if (clear_i || cntrl_scheduler_i.rst || ~flgs_x_buffer_i.full) begin
+      x_empty <= '0;
+    end else if (flgs_x_buffer_i.full && flgs_x_buffer_i.empty) begin
+      x_empty <= '1;
+    end
+  end
+
+  assign x_reload_en  = start || x_cols_iter_en || (x_empty && ~flgs_x_buffer_i.full);
   assign x_reload_rst = flgs_x_buffer_i.full && ~x_reload_en;
 
   assign cntrl_x_buffer_o.pad_setup   = current_state == PRELOAD && next_state == LOAD_W;
@@ -251,7 +245,6 @@
                       w_mat_iters_d, w_mat_iters_q;
 
   logic               w_done;
-
   logic               w_cols_iter_en, w_rows_iter_en,
                       w_mat_iters_en, w_done_en;
 
@@ -264,7 +257,7 @@
   ) i_w_config_fifo (
     .clk_i      ( clk_i          ),
     .rst_ni     ( rst_ni         ),
-    .flush_i    ( clear_i        ),
+    .flush_i    ( fifo_flush     ),
     .testmode_i ( '0             ),
     .full_o     ( w_config_full  ),
     .empty_o    ( w_config_empty ),
@@ -272,18 +265,16 @@
     .data_i     ( config_i       ),
     .push_i     ( config_valid_i ),
     .data_o     ( w_config       ),
-    .pop_i      ( w_done_en      )
+    .pop_i      ( w_done_en && ~w_config_empty )
   );
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : w_rows_iteration
     if(~rst_ni) begin
       w_rows_iter_q <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst) begin
-        w_rows_iter_q <= '0;
-      end else if (w_rows_iter_en && ~w_done) begin
-        w_rows_iter_q <= w_rows_iter_d;
-      end
+    end else if (clear_i || cntrl_scheduler_i.rst) begin
+      w_rows_iter_q <= '0;
+    end else if (w_rows_iter_en && ~w_done) begin
+      w_rows_iter_q <= w_rows_iter_d;
     end
   end
 
@@ -293,12 +284,10 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin : w_columns_iteration
     if(~rst_ni) begin
       w_cols_iter_q <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst) begin
-        w_cols_iter_q <= '0;
-      end else if (w_cols_iter_en && ~w_done) begin
-        w_cols_iter_q <= w_cols_iter_d;
-      end
+    end else if (clear_i || cntrl_scheduler_i.rst) begin
+      w_cols_iter_q <= '0;
+    end else if (w_cols_iter_en && ~w_done) begin
+      w_cols_iter_q <= w_cols_iter_d;
     end
   end
 
@@ -308,12 +297,10 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin : w_matrix_iterations
     if(~rst_ni) begin
       w_mat_iters_q <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst) begin
-        w_mat_iters_q <= '0;
-      end else if (w_mat_iters_en && ~w_done) begin
-        w_mat_iters_q <= w_mat_iters_d;
-      end
+    end else if (clear_i || cntrl_scheduler_i.rst) begin
+      w_mat_iters_q <= '0;
+    end else if (w_mat_iters_en && ~w_done) begin
+      w_mat_iters_q <= w_mat_iters_d;
     end
   end
 
@@ -323,32 +310,31 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin : w_done_register
     if(~rst_ni) begin
       w_done <= '0;
-    end else begin
-      if (clear_i || cntrl_scheduler_i.rst || (~w_done && w_config_full || w_done && config_valid_i)) begin
-        w_done <= '0;
-      end else if (w_done_en) begin
-        w_done <= '1;
-      end
+    end else if (clear_i || cntrl_scheduler_i.rst || (~w_done && w_config_full || w_done && config_valid_i)) begin
+      w_done <= '0;
+    end else if (w_done_en) begin
+      w_done <= '1;
     end
   end
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : w_zero_counter
     if (~rst_ni) begin
       w_zero_cnt_q <= '0;
+    end else if (clear_i || cntrl_scheduler_i.rst) begin
+      w_zero_cnt_q <= '0;
     end else begin
-      if (clear_i || cntrl_scheduler_i.rst) begin
-        w_zero_cnt_q <= '0;
-      end else begin
-        w_zero_cnt_q <= w_zero_cnt_d;
-      end
+      w_zero_cnt_q <= w_zero_cnt_d;
     end
   end
 
   assign w_zero_cnt_d = w_done && current_state == LOAD_W && ~stall_engine && w_zero_cnt_q != H ? w_zero_cnt_q + 1 : w_zero_cnt_q;
-
-  assign w_done_en = w_mat_iters_en && w_mat_iters_q == w_config.x_rows_iter-1;
-
-  assign cntrl_w_buffer_o.height = (w_rows_iter_q >= w_config.w_rows_iter-(NumPipeRegs+1) && w_config.w_rows_lftovr != '0) ? w_config.w_rows_lftovr[$clog2(MaxDim)-1:0] : H[$clog2(MaxDim)-1:0];
+  assign w_done_en    = w_mat_iters_en && w_mat_iters_q == w_config.x_rows_iter-1;
+
+  logic small_n_promoted;
+  assign small_n_promoted        = (w_config.n_size <= H);
+  assign cntrl_w_buffer_o.height = small_n_promoted
+                                 ? (w_rows_iter_q < H ? w_config.n_size[$clog2(MaxDim)-1:0] : '0)
+                                 : ((w_rows_iter_q >= (w_config.w_rows_iter - H) && w_config.w_rows_lftovr != '0) ? w_config.w_rows_lftovr[$clog2(MaxDim)-1:0] : H[$clog2(MaxDim)-1:0]);
   assign cntrl_w_buffer_o.width  = w_cols_iter_q == w_config.w_cols_iter-1 && w_config.w_cols_lftovr != '0 ? w_config.w_cols_lftovr[$clog2(MaxDepth)-1:0] : D[$clog2(MaxDepth)-1:0];
 
   assign cntrl_w_buffer_o.load  = current_state == LOAD_W && ~stall_engine && ~w_done;
@@ -356,7 +342,6 @@
 
   always_comb begin
     cntrl_w_buffer_o.zero_set = '0;
-
     for (int unsigned i = 0; i < H; i++) begin
       if (w_done && w_zero_cnt_q > i) begin
         cntrl_w_buffer_o.zero_set[i] = 1'b1;
@@ -378,12 +363,12 @@
 
   logic [15:0]                    y_cols_iter_d, y_cols_iter_q,
                                   y_rows_iter_d, y_rows_iter_q;
-
   logic                           y_cols_iter_en, y_rows_iter_en;
+  logic                           y_done;
 
   logic [15:0]                    z_cols_iter_d, z_cols_iter_q,
                                   z_rows_iter_d, z_rows_iter_q;
-
+  logic                           z_store_empty;
   logic                           z_cols_iter_en, z_rows_iter_en;
 
   logic [$clog2(NumPipeRegs+1)-1:0] z_wait_counter_d, z_wait_counter_q;
@@ -391,15 +376,14 @@
                                   y_push_counter_d, y_push_counter_q;
 
   logic [15:0]                    y_loads_cnt_d, y_loads_cnt_q;
-
   logic                           y_pushed_q;
 
   logic                           z_wait_en, z_wait_clr,
                                   z_avail_en, z_avail_clr,
                                   y_push_en, y_push_clr;
 
-  logic [$clog2(W):0]             y_width, z_width, z_width_next;
-  logic [$clog2(D):0]             y_height, z_height, z_height_next;
+  logic [$clog2(W):0]             y_width, z_width;
+  logic [$clog2(D):0]             y_height, z_height;
   logic [$clog2(D):0]             y_push_height;
 
   logic y_config_pop;
@@ -411,7 +395,7 @@
   ) i_y_config_fifo (
     .clk_i      ( clk_i          ),
     .rst_ni     ( rst_ni         ),
-    .flush_i    ( clear_i        ),
+    .flush_i    ( fifo_flush     ),
     .testmode_i ( '0             ),
     .full_o     ( y_config_full  ),
     .empty_o    ( y_config_empty ),
@@ -431,7 +415,7 @@
   ) i_y_config_fast_fifo (
     .clk_i      ( clk_i               ),
     .rst_ni     ( rst_ni              ),
-    .flush_i    ( clear_i             ),
+    .flush_i    ( fifo_flush          ),
     .testmode_i ( '0                  ),
     .full_o     ( y_config_fast_full  ),
     .empty_o    ( y_config_fast_empty ),
@@ -451,7 +435,7 @@
   ) i_z_config_fast_fifo (
     .clk_i      ( clk_i               ),
     .rst_ni     ( rst_ni              ),
-    .flush_i    ( clear_i             ),
+    .flush_i    ( fifo_flush          ),
     .testmode_i ( '0                  ),
     .full_o     ( z_config_fast_full  ),
     .empty_o    ( z_config_fast_empty ),
@@ -465,110 +449,106 @@
   always_ff @(posedge clk_i or negedge rst_ni) begin : y_pushed_register
     if(~rst_ni) begin
       y_pushed_q <= '0;
-    end else begin
-      if (cle
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/edge_detect.sv`](environment/public/code/edge_detect.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_classifier.sv`](environment/public/code/fpnew_classifier.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_rounding.sv`](environment/public/code/fpnew_rounding.sv) *(Read-Only Context)*
- [`environment/public/code/hci_package.sv`](environment/public/code/hci_package.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_ctrl_package.sv`](environment/public/code/hwpe_ctrl_package.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_stream_fifo.sv`](environment/public/code/hwpe_stream_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_stream_package.sv`](environment/public/code/hwpe_stream_package.sv) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_config_fifo.sv`](environment/public/code/redmule_config_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_ctrl.sv`](environment/public/code/redmule_ctrl.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_engine.sv`](environment/public/code/redmule_engine.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_fma.sv`](environment/public/code/redmule_fma.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_memory_scheduler.sv`](environment/public/code/redmule_memory_scheduler.sv) **(Editable)**
- [`environment/public/code/redmule_pkg.sv`](environment/public/code/redmule_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_row.sv`](environment/public/code/redmule_row.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_scheduler.sv`](environment/public/code/redmule_scheduler.sv) **(Editable)**
- [`environment/public/code/redmule_subsys.sv`](environment/public/code/redmule_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_tiler.sv`](environment/public/code/redmule_tiler.sv) **(Editable)**
- [`environment/public/code/sync.sv`](environment/public/code/sync.sv) *(Read-Only Context)*
- [`environment/public/code/sync_wedge.sv`](environment/public/code/sync_wedge.sv) *(Read-Only Context)*
- [`environment/public/code/tc_clk.sv`](environment/public/code/tc_clk.sv) *(Read-Only Context)*
- [`environment/public/code/w_buffer/redmule_w_buffer.sv`](environment/public/code/w_buffer/redmule_w_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/w_buffer/redmule_w_buffer_scm.sv`](environment/public/code/w_buffer/redmule_w_buffer_scm.sv) *(Read-Only Context)*
- [`environment/public/code/x_buffer/redmule_x_buffer.sv`](environment/public/code/x_buffer/redmule_x_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/x_buffer/redmule_x_buffer_scm.sv`](environment/public/code/x_buffer/redmule_x_buffer_scm.sv) *(Read-Only Context)*
- [`environment/public/code/x_buffer/redmule_x_pad_scm.sv`](environment/public/code/x_buffer/redmule_x_pad_scm.sv) *(Read-Only Context)*
- [`environment/public/code/z_buffer/redmule_z_buffer.sv`](environment/public/code/z_buffer/redmule_z_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/z_buffer/redmule_z_buffer_scm.sv`](environment/public/code/z_buffer/redmule_z_buffer_scm.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

