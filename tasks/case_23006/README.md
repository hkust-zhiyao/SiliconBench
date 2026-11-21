# `case_23006`: Implement Multi-Precision 1D Pooling, Split-Stripe Tiling, Pad Compensation, and FP16 NaN Preprocessor in NVDLA PDP

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23006` |
| **Source Silicon Repository** | `nvdla/hw` (`repo_36`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/NV_NVDLA_PDP_nan.v`](environment/public/code/NV_NVDLA_PDP_nan.v), [`code/NV_NVDLA_PDP_CORE_unit1d.v`](environment/public/code/NV_NVDLA_PDP_CORE_unit1d.v), [`code/NV_NVDLA_PDP_CORE_cal1d.v`](environment/public/code/NV_NVDLA_PDP_CORE_cal1d.v) (3 files, 3566 LOC) |
| **Public Subsystem Context** | 11 RTL files (6960 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `840s` total (`420s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Multi-Precision 1D Spatial Pooling, Split-Stripe Tiling, and FP16 NaN Preprocessor (`NV_NVDLA_PDP`)

In NVIDIA Deep Learning Accelerator (`nvdla/hw`), the Planar Data Processor horizontal (`1D`) pooling pipeline (`code/NV_NVDLA_PDP_nan.v`, `code/NV_NVDLA_PDP_CORE_unit1d.v`, and `code/NV_NVDLA_PDP_CORE_cal1d.v`) streams 32-byte feature-map surfaces from either offline `PDP_RDMA` (`reg2dp_flying_mode == 1'b1`) or on-the-fly `SDP` (`reg2dp_flying_mode == 1'b0`) and emits horizontally pooled results on `pooling1d_pvld` / `pooling1d_prdy` / `pooling1d_pd[111:0]`. Complete the RTL implementation across these three modules while preserving all module port interfaces and read-only `HLS_fp16_to_fp17` / `HLS_fp17_add` / `cal1d_fp16_pool_sum` instantiations:

1. **Stream Framing & Output Packing**:
   - Each spatial pixel is transferred over 4 consecutive 8-byte channel sub-beats (`pd[63:0]`, with `pd[66:64] = cpos` in `0..3`, `pd[71] = bsync`, `pd[72] = line_end`, `pd[73] = surf_end`, `pd[74] = split_end`, `pd[75] = cube_end`).
   - Support `reg2dp_input_data` in `2'h0` (`INT8`, 8 signed bytes/beat -> `pooling1d_pd` packs 8 x 14-bit sign-extended lanes), `2'h1` (`INT16`, 4 signed halfwords/beat -> 4 x 28-bit sign-extended lanes), and `2'h2` (`FP16` IEEE-754 binary16, 4 lanes/beat -> 4 x 28-bit sign-extended `FP16` lanes for `MAX`/`MIN`, or 4 x 28-bit zero-extended 17-bit `HLS_fp17` sums `{11'd0, fp17[16:0]}` for `AVE`).
   - Support `pooling_type_cfg` in `2'h0` (`POOL_METHOD_AVE`: sum accumulation plus pad-value compensation), `2'h1` (`POOL_METHOD_MAX`), and `2'h2` (`POOL_METHOD_MIN`) across kernel widths `1..8` (`pooling_size_h_cfg = K - 1`) and horizontal strides `1..8` (both overlapping `K >= S` and non-overlapping `S > K`).

2. **Offline RDMA Layer Gating, FP16 NaN Flush, & Ping-Pong Telemetry (`NV_NVDLA_PDP_nan.v`)**:
   - Gate `pdp_rdma2dp_ready` low out of reset, throughout flying SDP layers (`reg2dp_flying_mode == 1'b0`), and between offline layers; arm RDMA acceptance on `reg2dp_op_en` when `reg2dp_flying_mode == 1'b1` until the final beat of the cube (`cube_end && bsync`) handshakes.
   - In `FP16` mode (`2'h2`), detect per-lane IEEE-754 NaNs and Infinities; when `reg2dp_nan_to_zero == 1'b1`, replace `FP16` NaN lanes with `+0.0` (`16'h0000`) on `nan_preproc_pd` while passing `INT8`/`INT16` payloads and non-NaN `FP16` values (`+/-Inf`, subnormals, signed zeros) untouched.
   - Accumulate per-layer input `FP16` NaN and Infinity element counts across accepted beats (latching into alternating 2-entry ping-pong register banks at cube completion and resetting for the next layer) and present the corresponding completed layer's counts on `dp2reg_nan_input_num` / `dp2reg_inf_input_num` upon each `dp2reg_done` pulse.

3. **Multi-Precision Window Reduction & FP16 NaN Propagation (`NV_NVDLA_PDP_CORE_unit1d.v`, `NV_NVDLA_PDP_CORE_cal1d.v`)**:
   - Reduce horizontal windows independently per channel across all 4 `cpos` sub-beats without inter-lane bleed in dual-byte `INT8` slices, using IEEE-754 sign-magnitude ordering in `FP16` `MAX`/`MIN` with NaN propagation when un-flushed NaNs enter a window (`reg2dp_nan_to_zero == 1'b0`), and left-to-right `FP17` accumulation in `FP16` `AVE`.
   - Maintain coherent per-sub-beat window state across back-to-back pixels and immediate output reads, and drain all right-padded trailing windows in spatial order at line, stripe, and final-cube boundaries (including narrow lines where `width + pad_left < K`).

4. **Horizontal Split-Stripe (`splitw`) Tiling & `AVE` Pad Compensation (`NV_NVDLA_PDP_CORE_cal1d.v`)**:
   - Support both single-pass (`pooling_splitw_num_cfg == 0`) and multi-stripe (`pooling_splitw_num_cfg > 0`: first stripe `fwidth` with left pad only, middle stripes `mwidth` with zero pad and `|K - S|` stripe-overlap width adjustment, last stripe `lwidth` with right pad and `|K - S|` overlap adjustment) horizontal tiling.
   - In `AVE` mode (`2'h0`), compensate boundary windows containing $m \in [1, 7]$ padded positions using `reg2dp_pad_value_1x_cfg` .. `reg2dp_pad_value_7x_cfg` across `INT8`, `INT16`, and `FP16` (`HLS_fp17_add`) before packing `pooling1d_pd`. Do not apply pad-value offsets in `MAX` or `MIN` modes.

5. **Synthesis & Backpressure Signoff**:
   - Must sustain arbitrary upstream/downstream `pvld`/`prdy` stalls without dropping or duplicating beats, and elaborate cleanly in `yosys` (`NV_NVDLA_PDP_nan` and `NV_NVDLA_PDP_CORE_cal1d`) with zero inferred latches (`$dlatch*`) and zero combinational loops.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Synthesis Guide

## Workspace Layout

- **Editable RTL files**:
  - `code/NV_NVDLA_PDP_nan.v`
  - `code/NV_NVDLA_PDP_CORE_unit1d.v`
  - `code/NV_NVDLA_PDP_CORE_cal1d.v`
- **Read-only NVDLA helper & HLS arithmetic files** (do **not** modify):
  - `code/HLS_fp16_to_fp17.v` (4-stage pipelined IEEE-754 FP16 -> internal FP17 converter)
  - `code/HLS_fp17_add.v` (4-stage pipelined internal FP17 adder)
  - `code/cal1d_fp16_pool_sum.v` (4-lane synchronized `HLS_fp17_add` wrapper used by `unit1d`)
  - `code/NV_CLK_gate_power.v`, `code/CKLNQD12.v`, `code/NV_BLKBOX_SINK.v`
  - `code/NV_HWACC_NVDLA_tick_defines.vh`, `code/simulate_x_tick.vh`, `code/LICENSE`

---

## Tool Commands

### 1. Fast Compile & Simulation with Icarus Verilog (`iverilog -g2012`)

```bash
iverilog -g2012 -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -Icode \
  -s <your_tb_top> -o /tmp/pdp_sim.vvp \
  code/NV_BLKBOX_SINK.v \
  code/CKLNQD12.v \
  code/NV_CLK_gate_power.v \
  code/HLS_fp16_to_fp17.v \
  code/HLS_fp17_add.v \
  code/cal1d_fp16_pool_sum.v \
  code/NV_NVDLA_PDP_nan.v \
  code/NV_NVDLA_PDP_CORE_unit1d.v \
  code/NV_NVDLA_PDP_CORE_cal1d.v \
  <your_tb.sv>

vvp /tmp/pdp_sim.vvp
```

### 2. Verilator Lint / Binary Simulation

```bash
verilator --lint-only -Wall -Wno-fatal \
  -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -Icode \
  --top-module NV_NVDLA_PDP_CORE_cal1d \
  code/NV_BLKBOX_SINK.v \
  code/CKLNQD12.v \
  code/NV_CLK_gate_power.v \
  code/HLS_fp16_to_fp17.v \
  code/HLS_fp17_add.v \
  code/cal1d_fp16_pool_sum.v \
  code/NV_NVDLA_PDP_nan.v \
  code/NV_NVDLA_PDP_CORE_unit1d.v \
  code/NV_NVDLA_PDP_CORE_cal1d.v
```

### 3. Yosys Elaboration & Latch-Free Synthesis Check (Mandatory Signoff Gate)

Both `NV_NVDLA_PDP_nan` and `NV_NVDLA_PDP_CORE_cal1d` must elaborate with zero inferred latches (`$dlatch*`) and zero combinational loops:

```bash
for TOP in NV_NVDLA_PDP_nan NV_NVDLA_PDP_CORE_cal1d; do
  yosys -q -p "
    read_verilog -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -DVLIB_BYPASS_POWER_CG -Icode \
      code/NV_BLKBOX_SINK.v code/CKLNQD12.v code/NV_CLK_gate_power.v \
      code/HLS_fp16_to_fp17.v code/HLS_fp17_add.v code/cal1d_fp16_pool_sum.v \
      code/NV_NVDLA_PDP_nan.v code/NV_NVDLA_PDP_CORE_unit1d.v code/NV_NVDLA_PDP_CORE_cal1d.v;
    hierarchy -check -top ${TOP};
    proc; opt_clean;
    check -assert;
    select -assert-none */t:\$dlatch*
  "
done
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/NV_NVDLA_PDP_nan.v (Buggy Starter)
+++ b/solution/gold/code/NV_NVDLA_PDP_nan.v (Golden Reference)
@@ -40,17 +40,30 @@
 output [75:0] nan_preproc_pd;
 output        nan_preproc_pvld;
 output        pdp_rdma2dp_ready;
-
+reg           cube_end_d1;
 reg    [11:0] datin_info_d;
 reg           din_pvld_d1;
 reg    [31:0] dp2reg_inf_input_num;
 reg    [31:0] dp2reg_nan_input_num;
+reg    [31:0] inf_in_count;
+reg    [31:0] inf_in_num0;
+reg    [31:0] inf_in_num1;
+reg     [2:0] inf_num_in_8byte_d1;
+reg           layer_flag;
+reg           mon_inf_in_count;
+reg           mon_nan_in_count;
+reg    [31:0] nan_in_count;
+reg    [31:0] nan_in_num0;
+reg    [31:0] nan_in_num1;
+reg     [2:0] nan_num_in_8byte_d1;
 reg    [15:0] nan_preproc_pd0;
 reg    [15:0] nan_preproc_pd1;
 reg    [15:0] nan_preproc_pd2;
 reg    [15:0] nan_preproc_pd3;
+reg           op_en_d1;
 reg           waiting_for_op_en;
-
+reg           wdma_layer_flag;
+wire          cube_end;
 wire    [3:0] dat_is_inf;
 wire    [3:0] dat_is_nan;
 wire          din_prdy_d1;
@@ -59,51 +72,92 @@
 wire   [15:0] fp16_in_pd_1;
 wire   [15:0] fp16_in_pd_2;
 wire   [15:0] fp16_in_pd_3;
+wire    [2:0] inf_num_in_8byte;
+wire    [1:0] inf_num_in_8byte_0;
+wire    [1:0] inf_num_in_8byte_1;
+wire          layer_end;
 wire          load_din;
+wire          load_din_d1;
+wire    [2:0] nan_num_in_8byte;
+wire    [1:0] nan_num_in_8byte_0;
+wire    [1:0] nan_num_in_8byte_1;
 wire          onfly_en;
+wire          op_en_load;
 wire          pdp_rdma2dp_ready_f;
 wire          tozero_en;
-
+wire          wdma_done;
+
+    
 //==========================================
-// Ingress handshake & mode decode
 //==========================================
+//----------------------------------------
 assign pdp_rdma2dp_ready = pdp_rdma2dp_ready_f;
 assign pdp_rdma2dp_ready_f = (~din_pvld_d1 | din_prdy_d1) & (~waiting_for_op_en);
 assign load_din = pdp_rdma2dp_valid & pdp_rdma2dp_ready_f;
-
-assign tozero_en = (reg2dp_nan_to_zero == 1'h1);
-assign fp16_en   = (reg2dp_input_data[1:0] == 2'h2);
-assign onfly_en  = (reg2dp_flying_mode == 1'h0);
-
-assign fp16_in_pd_0 = pdp_rdma2dp_pd[15:0];
-assign fp16_in_pd_1 = pdp_rdma2dp_pd[31:16];
-assign fp16_in_pd_2 = pdp_rdma2dp_pd[47:32];
-assign fp16_in_pd_3 = pdp_rdma2dp_pd[63:48];
-
-assign dat_is_nan = 4'b0000;
-assign dat_is_inf = 4'b0000;
-
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    waiting_for_op_en <= 1'b0;
-  end else begin
-    waiting_for_op_en <= 1'b0;
-  end
-end
-
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    nan_preproc_pd0 <= 16'd0;
-    nan_preproc_pd1 <= 16'd0;
-    nan_preproc_pd2 <= 16'd0;
-    nan_preproc_pd3 <= 16'd0;
-    datin_info_d    <= 12'd0;
-  end else if (load_din) begin
-    nan_preproc_pd0 <= fp16_in_pd_0;
-    nan_preproc_pd1 <= fp16_in_pd_1;
-    nan_preproc_pd2 <= fp16_in_pd_2;
-    nan_preproc_pd3 <= fp16_in_pd_3;
-    datin_info_d    <= pdp_rdma2dp_pd[75:64];
+//----------------------------------------
+assign tozero_en = reg2dp_nan_to_zero == 1'h1 ;
+assign fp16_en = (reg2dp_input_data[1:0]== 2'h2 );
+assign onfly_en = (reg2dp_flying_mode == 1'h0 );
+//----------------------------------------
+assign fp16_in_pd_0 = pdp_rdma2dp_pd[15:0]  ;
+assign fp16_in_pd_1 = pdp_rdma2dp_pd[31:16] ;
+assign fp16_in_pd_2 = pdp_rdma2dp_pd[47:32] ;
+assign fp16_in_pd_3 = pdp_rdma2dp_pd[63:48] ;
+
+assign dat_is_nan[0] = fp16_en & (&fp16_in_pd_0[14:10]) & (|fp16_in_pd_0[9:0]);
+assign dat_is_nan[1] = fp16_en & (&fp16_in_pd_1[14:10]) & (|fp16_in_pd_1[9:0]);
+assign dat_is_nan[2] = fp16_en & (&fp16_in_pd_2[14:10]) & (|fp16_in_pd_2[9:0]);
+assign dat_is_nan[3] = fp16_en & (&fp16_in_pd_3[14:10]) & (|fp16_in_pd_3[9:0]);
+
+assign dat_is_inf[0] = fp16_en & (&fp16_in_pd_0[14:10]) & (~(|fp16_in_pd_0[9:0]));
+assign dat_is_inf[1] = fp16_en & (&fp16_in_pd_1[14:10]) & (~(|fp16_in_pd_1[9:0]));
+assign dat_is_inf[2] = fp16_en & (&fp16_in_pd_2[14:10]) & (~(|fp16_in_pd_2[9:0]));
+assign dat_is_inf[3] = fp16_en & (&fp16_in_pd_3[14:10]) & (~(|fp16_in_pd_3[9:0]));
+
+//////////////////////////////////////////////////////////////////////
+//////////////////////////////////////////////////////////////////////
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    op_en_d1 <= 1'b0;
+  end else begin
+  op_en_d1 <= reg2dp_op_en;
+  end
+end
+assign op_en_load = reg2dp_op_en & (~op_en_d1);
+assign layer_end = &{pdp_rdma2dp_pd[75],pdp_rdma2dp_pd[71]} & load_din;
+
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    waiting_for_op_en <= 1'b1;
+  end else begin
+    if(layer_end & (~onfly_en))
+        waiting_for_op_en <= 1'b1;
+    else if(op_en_load) begin
+        if(onfly_en)
+            waiting_for_op_en <= 1'b1;
+        else if(~onfly_en)
+            waiting_for_op_en <= 1'b0;
+    end
+  end
+end
+
+/////////////////////////////////////
+/////////////////////////////////////
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    nan_preproc_pd0 <= {16{1'b0}};
+    nan_preproc_pd1 <= {16{1'b0}};
+    nan_preproc_pd2 <= {16{1'b0}};
+    nan_preproc_pd3 <= {16{1'b0}};
+    datin_info_d <= {12{1'b0}};
+  end else begin
+    if(load_din) begin
+        nan_preproc_pd0 <= (dat_is_nan[0] & tozero_en) ? 16'd0 : fp16_in_pd_0;
+        nan_preproc_pd1 <= (dat_is_nan[1] & tozero_en) ? 16'd0 : fp16_in_pd_1;
+        nan_preproc_pd2 <= (dat_is_nan[2] & tozero_en) ? 16'd0 : fp16_in_pd_2;
+        nan_preproc_pd3 <= (dat_is_nan[3] & tozero_en) ? 16'd0 : fp16_in_pd_3;
+        datin_info_d    <= pdp_rdma2dp_pd[75:64];
+    end
   end
 end
 
@@ -111,25 +165,141 @@
   if (!nvdla_core_rstn) begin
     din_pvld_d1 <= 1'b0;
   end else begin
-    if (pdp_rdma2dp_valid & (~waiting_for_op_en))
-      din_pvld_d1 <= 1'b1;
-    else if (din_prdy_d1)
-      din_pvld_d1 <= 1'b0;
-  end
-end
-
-assign din_prdy_d1      = nan_preproc_prdy;
-assign nan_preproc_pd   = {datin_info_d, nan_preproc_pd3, nan_preproc_pd2, nan_preproc_pd1, nan_preproc_pd0};
+    if(pdp_rdma2dp_valid & (~waiting_for_op_en))
+        din_pvld_d1 <= 1'b1;
+    else if(din_prdy_d1)
+        din_pvld_d1 <= 1'b0;
+  end
+end
+assign din_prdy_d1 = nan_preproc_prdy;
+assign nan_preproc_pd = {datin_info_d,nan_preproc_pd3,nan_preproc_pd2,nan_preproc_pd1,nan_preproc_pd0};
 assign nan_preproc_pvld = din_pvld_d1;
 
-always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-  if (!nvdla_core_rstn) begin
-    dp2reg_nan_input_num <= 32'd0;
-    dp2reg_inf_input_num <= 32'd0;
-  end else if (dp2reg_done) begin
-    dp2reg_nan_input_num <= 32'd0;
-    dp2reg_inf_input_num <= 32'd0;
-  end
-end
-
+/////////////////////////////////////
+/////////////////////////////////////
+assign cube_end = pdp_rdma2dp_pd[75] & pdp_rdma2dp_pd[71];
+
+assign nan_num_in_8byte_0[1:0] = dat_is_nan[0] + dat_is_nan[1];
+assign nan_num_in_8byte_1[1:0] = dat_is_nan[2] + dat_is_nan[3];
+assign nan_num_in_8byte[2:0]   = nan_num_in_8byte_0 + nan_num_in_8byte_1;
+
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    cube_end_d1 <= 1'b0;
+  end else begin
+  if ((load_din) == 1'b1) begin
+    cube_end_d1 <= cube_end;
+  end else if ((load_din) == 1'b0) begin
+  end else begin
+    cube_end_d1 <= 'bx;
+  end
+  end
+end
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    nan_num_in_8byte_d1 <= {3{1'b0}};
+  end else begin
+  if ((load_din) == 1'b1) begin
+    nan_num_in_8byte_d1 <= nan_num_in_8byte[2:0];
+  end else if ((load_din) == 1'b0) begin
+  end else begin
+    nan_num_in_8byte_d1 <= 'bx;
+  end
+  end
+end
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    inf_num_in_8byte_d1 <= {3{1'b0}};
+  end else begin
+  if ((load_din) == 1'b1) begin
+    inf_num_in_8byte_d1 <= inf_num_in_8byte[2:0];
+  end else if ((load_din) == 1'b0) begin
+  end else begin
+    inf_num_in_8byte_d1 <= 'bx;
+  end
+  end
+end
+
+assign load_din_d1 = din_pvld_d1 & din_prdy_d1;
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    {mon_nan_in_count,nan_in_count[31:0]} <= {33{1'b0}};
+  end else begin
+    if(load_din_d1) begin
+        if(cube_end_d1)
+            {mon_nan_in_count,nan_in_count[31:0]} <= 33'd0;
+        else
+            {mon_nan_in_count,nan_in_count[31:0]} <= nan_in_count + nan_num_in_8byte_d1;
+    end
+  end
+end
+
+assign inf_num_in_8byte_0[1:0] = dat_is_inf[0] + dat_is_inf[1];
+assign inf_num_in_8byte_1[1:0] = dat_is_inf[2] + dat_is_inf[3];
+assign inf_num_in_8byte[2:0]   = inf_num_in_8byte_0 + inf_num_in_8byte_1;
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    {mon_inf_in_count,inf_in_count[31:0]} <= {33{1'b0}};
+  end else begin
+    if(load_din_d1) begin
+        if(cube_end_d1)
+            {mon_inf_in_count,inf_in_count[31:0]} <= 33'd0;
+        else
+            {mon_inf_in_count,inf_in_count[31:0]} <= inf_in_count + inf_num_in_8byte_d1;
+    end
+  end
+end
+
+wire [31:0] nan_in_count_total = nan_in_count + {29'd0, nan_num_in_8byte_d1};
+wire [31:0] inf_in_count_total = inf_in_count + {29'd0, inf_num_in_8byte_d1};
+
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    layer_flag <= 1'b0;
+    nan_in_num1 <= {32{1'b0}};
+    inf_in_num1 <= {32{1'b0}};
+    nan_in_num0 <= {32{1'b0}};
+    inf_in_num0 <= {32{1'b0}};
+  end else begin
+    if(load_din_d1 & cube_end_d1) begin
+        layer_flag <= ~layer_flag;
+        if(layer_flag) begin
+            nan_in_num1 <= nan_in_count_total;
+            inf_in_num1 <= inf_in_count_total;
+        end else begin
+            nan_in_num0 <= nan_in_count_total;
+            inf_in_num0 <= inf_in_count_total;
+        end
+    end
+  end
+end
+
+assign wdma_done = dp2reg_done;
+always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+  if (!nvdla_core_rstn) begin
+    wdma_layer_flag <= 1'b0;
+    dp2reg_nan_input_num <= {32{1'b0}};
+    dp2reg_inf_input_num <= {32{1'b0}};
+  end else begin
+    if(wdma_done) begin
+        wdma_layer_flag <= ~wdma_layer_flag;
+        if(wdma_layer_flag) begin
+            dp2reg_nan_input_num <= nan_in_num1;
+            dp2reg_inf_input_num <= inf_in_num1;
+        end else begin
+            dp2reg_nan_input_num <= nan_in_num0;
+            dp2reg_inf_input_num <= inf_in_num0;
+        end
+    end
+  end
+end
+
+/////////////////////////////////////
+/////////////////////////////////////
+
+//==============
+//==============
+
+//////////////////////////////////////////////////////////////////////
 endmodule // NV_NVDLA_PDP_nan
+

--- a/environment/public/code/NV_NVDLA_PDP_CORE_unit1d.v (Buggy Starter)
+++ b/solution/gold/code/NV_NVDLA_PDP_CORE_unit1d.v (Golden Reference)
@@ -51,17 +51,21 @@
 output         pdma2pdp_prdy;
 output  [91:0] pooling_out;
 output         pooling_out_pvld;
-
 wire           add_out_rdy;
 wire           add_out_vld;
 wire     [1:0] buf_sel;
 wire     [1:0] buf_sel_sync;
+wire     [1:0] buf_sel_sync_use;
+wire     [1:0] buf_sel_sync_use_d4;
 wire           cur_datin_disable_sync;
+wire           cur_datin_disable_sync_use;
+wire           cur_datin_disable_sync_use_d4;
 wire    [87:0] data_buf0;
 wire    [87:0] data_buf1;
 wire    [87:0] data_buf2;
 wire    [87:0] data_buf3;
 wire           data_buf_lc;
+wire           data_buf_lc_d4;
 wire    [87:0] datain_ext;
 wire    [87:0] datain_ext_sync;
 wire    [16:0] fp16_pool_sum_0;
@@ -76,6 +80,10 @@
 wire    [87:0] fp_datain_ext;
 wire           fp_mean_pool_cfg;
 wire    [67:0] fp_pool_sum;
+wire    [67:0] fp_pool_sum_result0;
+wire    [67:0] fp_pool_sum_result1;
+wire    [67:0] fp_pool_sum_result2;
+wire    [67:0] fp_pool_sum_result3;
 wire    [87:0] fp_pool_sum_use0;
 wire    [87:0] fp_pool_sum_use1;
 wire    [87:0] fp_pool_sum_use2;
@@ -84,10 +92,19 @@
 wire    [87:0] int_pool_datin_ext;
 wire    [87:0] int_pooling;
 wire    [87:0] int_pooling_sync;
+wire    [87:0] latch_result0;
+wire    [87:0] latch_result0_d4;
+wire    [87:0] latch_result1;
+wire    [87:0] latch_result1_d4;
+wire    [87:0] latch_result2;
+wire    [87:0] latch_result2_d4;
+wire    [87:0] latch_result3;
+wire    [87:0] latch_result3_d4;
 wire           load_din;
 wire           pdma2pdp_prdy_f;
 wire     [1:0] pdp_din_cpos;
 wire           pdp_din_lc_f_sync;
+wire     [3:0] pdp_din_wpos;
 wire   [184:0] pipe_in_pd;
 wire   [184:0] pipe_in_pd_d0;
 wire   [184:0] pipe_in_pd_d1;
@@ -112,15 +129,27 @@
 wire           pool_fun_vld;
 wire           pooling_din_1st_sync;
 wire           pooling_din_last_sync;
+wire           pooling_din_last_sync_use;
+wire           pooling_din_last_sync_use_d4;
 wire     [2:0] pooling_out_size;
 wire     [2:0] pooling_out_size_sync;
+wire     [2:0] pooling_out_size_sync_use;
+wire     [2:0] pooling_out_size_sync_use_d4;
 wire           pooling_out_vld;
 wire    [87:0] pooling_result;
 reg     [87:0] cur_pooling_dat;
+reg     [91:0] flush_out0;
+reg     [91:0] flush_out1;
+reg     [91:0] flush_out2;
+reg     [91:0] flush_out3;
 reg     [67:0] fp_pool_sum_result0_d3;
+reg     [67:0] fp_pool_sum_result0_d4;
 reg     [67:0] fp_pool_sum_result1_d3;
+reg     [67:0] fp_pool_sum_result1_d4;
 reg     [67:0] fp_pool_sum_result2_d3;
+reg     [67:0] fp_pool_sum_result2_d4;
 reg     [67:0] fp_pool_sum_result3_d3;
+reg     [67:0] fp_pool_sum_result3_d4;
 reg     [87:0] latch_result0_d3;
 reg     [87:0] latch_result1_d3;
 reg     [87:0] latch_result2_d3;
@@ -129,49 +158,226 @@
 reg     [91:0] pooling_out;
 reg      [2:0] pooling_size;
 
+    
+//=======================================================
+//-------------------------------------------------------
 assign fp_mean_pool_cfg = (reg2dp_fp16_en & average_pooling_en);
-assign pdp_din_cpos     = pdma2pdp_pd[93:92];
-assign buf_sel          = pdp_din_cpos[1:0];
-
-assign load_din         = pdma2pdp_pvld & pdma2pdp_prdy_f & (~cur_datin_disable) & pooling_unit_en;
-assign pdma2pdp_prdy_f  = fp_mean_pool_cfg ? (pipe_in_rdy & fp_addin_rdy) : pipe_in_rdy;
-assign pdma2pdp_prdy    = pdma2pdp_prdy_f;
-
-function [87:0] pooling_fun;
-  input        reg2dp_int8_en;
-  input        reg2dp_int16_en;
-  input        reg2dp_fp16_en;
-  input  [1:0] pooling_type;
-  input [87:0] data0_in;
-  input [87:0] data1_in;
+
+assign pdp_din_wpos  = pdma2pdp_pd[91:88];
+assign pdp_din_cpos  = pdma2pdp_pd[93:92];
+assign buf_sel       = pdp_din_cpos[1:0];
+
+assign load_din      = pdma2pdp_pvld & pdma2pdp_prdy_f & (~cur_datin_disable) & pooling_unit_en;
+assign pdma2pdp_prdy_f = fp_mean_pool_cfg ? (pipe_in_rdy & fp_addin_rdy) : pipe_in_rdy;
+assign pdma2pdp_prdy = pdma2pdp_prdy_f;
+
+//=========================================================
+ //=========================================================
+
+function[21:0] pooling_MIN; 
+   input       reg2dp_int8_en;
+   input       reg2dp_int16_en;
+   input       reg2dp_fp16_en;
+   input[21:0]  data0;
+   input[21:0]  data1;
+   reg[10:0]  data0_lsb;
+   reg[10:0]  data0_msb;
+   reg[10:0]  data1_lsb;
+   reg[10:0]  data1_msb;
+   reg[21:0]  min_16int;
+   reg[21:0]  min_fp16;
+   reg[10:0]  min_8int_lsb;
+   reg[10:0]  min_8int_msb;
+   reg [21:0] int16_data0;
+   reg [21:0] int16_data1;
+   reg [21:0] fp16_data0;
+   reg [21:0] fp16_data1;
+   reg        min_8int_lsb_ff;
+   reg        min_8int_msb_ff;
+   reg        min_16int_ff;
   begin
-    pooling_fun = data1_in;
+      {data0_msb,data0_lsb} = reg2dp_int8_en ? data0 : 0;
+      {data1_msb,data1_lsb} = reg2dp_int8_en ? data1 : 0;
+      int16_data0 = reg2dp_int16_en ? data0 : 0;
+      int16_data1 = reg2dp_int16_en ? data1 : 0;
+      fp16_data0  = reg2dp_fp16_en ? data0 : 0;
+      fp16_data1  = reg2dp_fp16_en ? data1 : 0;
+
+      min_8int_lsb_ff = ($signed(data1_lsb)> $signed(data0_lsb));
+      min_8int_msb_ff = ($signed(data1_msb)> $signed(data0_msb));
+      min_16int_ff    = ($signed(int16_data1)>  $signed(int16_data0))       ;
+
+      min_8int_lsb = (min_8int_lsb_ff) ? data0_lsb : data1_lsb;
+      min_8int_msb = (min_8int_msb_ff) ? data0_msb : data1_msb;
+      min_16int    = (min_16int_ff   ) ? int16_data0 : int16_data1;
+      min_fp16     = ((~fp16_data0[15]) & (~fp16_data1[15]))? ((fp16_data0[14:0]>fp16_data1[14:0])? fp16_data1 : fp16_data0) : 
+                     (((fp16_data0[15]) & (fp16_data1[15]))?  ((fp16_data0[14:0]>fp16_data1[14:0])? fp16_data0 : fp16_data1) : 
+                     (((fp16_data0[15]) & (~fp16_data1[15]))?  fp16_data0 : fp16_data1));
+
+      pooling_MIN  = reg2dp_fp16_en ? min_fp16 : 
+                    (reg2dp_int16_en ? min_16int : {min_8int_msb,min_8int_lsb});
+  end
+ endfunction
+
+ function[21:0] pooling_MAX; 
+   input       reg2dp_int8_en;
+   input       reg2dp_int16_en;
+   input       reg2dp_fp16_en;
+   input[21:0]  data0;
+   input[21:0]  data1;
+      reg[10:0]  data0_lsb;
+      reg[10:0]  data0_msb;
+      reg[10:0]  data1_lsb;
+      reg[10:0]  data1_msb;
+      reg[21:0]  max_16int;
+      reg[21:0]  max_fp16;
+      reg[10:0]  max_8int_lsb;
+      reg[10:0]  max_8int_msb;
+      reg [21:0] int16_data0;
+      reg [21:0] int16_data1;
+      reg [21:0] fp16_data0;
+      reg [21:0] fp16_data1;
+      reg        max_8int_lsb_ff;
+      reg        max_8int_msb_ff;
+      reg        max_16int_ff;
+      begin
+      {data0_msb,data0_lsb} = reg2dp_int8_en ? data0 : 0;
+      {data1_msb,data1_lsb} = reg2dp_int8_en ? data1 : 0;
+      int16_data0 = reg2dp_int16_en ? data0 : 0;
+      int16_data1 = reg2dp_int16_en ? data1 : 0;
+      fp16_data0  = reg2dp_fp16_en ? data0 : 0;
+      fp16_data1  = reg2dp_fp16_en ? data1 : 0;
+      max_8int_lsb_ff = ($signed(data0_lsb)> $signed(data1_lsb));
+      max_8int_msb_ff = ($signed(data0_msb)> $signed(data1_msb));
+      max_16int_ff    = ($signed(int16_data0)>  $signed(int16_data1))       ;
+
+      max_8int_lsb = (max_8int_lsb_ff) ? data0_lsb : data1_lsb;
+      max_8int_msb = (max_8int_msb_ff) ? data0_msb : data1_msb;
+      max_16int    = (max_16int_ff   ) ? int16_data0 : int16_data1;
+      max_fp16     = ((~fp16_data0[15]) & (~fp16_data1[15]))? ((fp16_data0[14:0]>fp16_data1[14:0])? fp16_data0 : fp16_data1) : 
+                     (((fp16_data0[15]) & (fp16_data1[15]))?  ((fp16_data0[14:0]>fp16_data1[14:0])? fp16_data1 : fp16_data0) : 
+                     (((fp16_data0[15]) & (~fp16_data1[15]))?  fp16_data1 : fp16_data0));
+      pooling_MAX  = reg2dp_fp16_en ? max_fp16 : 
+                    (reg2dp_int16_en ? max_16int : {max_8int_msb,max_8int_lsb});
+  end
+ endfunction
+
+ function[21:0] pooling_SUM; 
+   input       reg2dp_int8_en;
+   input       reg2dp_int16_en;
+   input[21:0]  data0;
+   input[21:0]  data1;
+   reg[10:0]  data0_lsb;
+   reg[10:0]  data0_msb;
+   reg[10:0]  data1_lsb;
+   reg[10:0]  data1_msb;
+   reg[21:0]  int16_data0;
+   reg[21:0]  int16_data1;
+   reg[21:0]  sum_16int;
+   reg[10:0]  sum_8int_lsb;
+   reg[10:0]  sum_8int_msb;
+   reg[10:0]  sum_8int_lsb_ff;
+   reg[10:0]  sum_8int_msb_ff;
+   reg[21:0]  sum_16int_ff;
+   begin
+      {data0_msb,data0_lsb} = reg2dp_int8_en ? data0 : 0;
+      {data1_msb,data1_lsb} = reg2dp_int8_en ? data1 : 0;
+      int16_data0 = reg2dp_int16_en ? data0 : 0;
+      int16_data1 = reg2dp_int16_en ? data1 : 0;
+      sum_8int_lsb_ff[10:0] =   $signed(data1_lsb) + $signed(data0_lsb);
+      sum_8int_msb_ff[10:0] =   $signed(data1_msb) + $signed(data0_msb);
+      sum_16int_ff[21:0]    =   $signed(int16_data1) + $signed(int16_data0); 
+      
+      sum_8int_lsb =   sum_8int_lsb_ff;
+      sum_8int_msb =   sum_8int_msb_ff;
+      sum_16int    =   sum_16int_ff   ; 
+      pooling_SUM  = reg2dp_int16_en ? sum_16int : {sum_8int_msb,sum_8int_lsb};
+  end
+ endfunction
+
+function[87:0] pooling_fun;
+  input       reg2dp_int8_en;
+  input       reg2dp_int16_en;
+  input       reg2dp_fp16_en;
+  input[1:0]  pooling_type;
+  input[87:0] data0_in;
+  input[87:0] data1_in;
+  reg    min_pooling;
+  reg    max_pooling;
+  reg    mean_pooling;
+  reg  [3:0] din0_is_nan;
+  reg  [3:0] din1_is_nan;
+  reg  [3:0] nan_in;
+  begin
+     min_pooling = (pooling_type== 2'h2 );
+     max_pooling = (pooling_type== 2'h1 );
+     mean_pooling = (pooling_type== 2'h0 );
+     din0_is_nan[0] = &data0_in[14:10] & (|data0_in[9:0]);
+     din1_is_nan[0] = &data1_in[14:10] & (|data1_in[9:0]);
+     din0_is_nan[1] = &data0_in[36:32] & (|data0_in[31:22]);
+     din1_is_nan[1] = &data1_in[36:32] & (|data1_in[31:22]);
+     din0_is_nan[2] = &data0_in[58:54] & (|data0_in[53:44]);
+     din1_is_nan[2] = &data1_in[58:54] & (|data1_in[53:44]);
+     din0_is_nan[3] = &data0_in[80:76] & (|data0_in[75:66]);
+     din1_is_nan[3] = &data1_in[80:76] & (|data1_in[75:66]);
+     nan_in = din0_is_nan | din1_is_nan;
+     pooling_fun[21:0]  = mean_pooling? pooling_SUM(reg2dp_int8_en,reg2dp_int16_en,data0_in[21:0],data1_in[21:0]) :
+         min_pooling ? (((~reg2dp_fp16_en)| (~nan_in[0] & reg2dp_fp16_en))? pooling_MIN (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[21:0],data1_in[21:0]) : (din0_is_nan[0]? data0_in[21:0] : data1_in[21:0])) :
+         max_pooling ? (((~reg2dp_fp16_en)| (~nan_in[0] & reg2dp_fp16_en))? pooling_MAX (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[21:0],data1_in[21:0]) : (din0_is_nan[0]? data0_in[21:0] : data1_in[21:0])) : 0;
+      
+     pooling_fun[43:22] = mean_pooling? pooling_SUM(reg2dp_int8_en,reg2dp_int16_en,data0_in[43:22],data1_in[43:22]) :
+         min_pooling ? (((~reg2dp_fp16_en)| (~nan_in[1] & reg2dp_fp16_en))? pooling_MIN (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[43:22],data1_in[43:22]) : (din0_is_nan[1]? data0_in[43:22] : data1_in[43:22])):
+         max_pooling ? (((~reg2dp_fp16_en)| (~nan_in[1] & reg2dp_fp16_en))? pooling_MAX (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[43:22],data1_in[43:22]) : (din0_is_nan[1]? data0_in[43:22] : data1_in[43:22])): 0;
+      
+     pooling_fun[65:44] = mean_pooling? pooling_SUM(reg2dp_int8_en,reg2dp_int16_en,data0_in[65:44],data1_in[65:44]) :
+         min_pooling ? (((~reg2dp_fp16_en)| (~nan_in[2] & reg2dp_fp16_en))? pooling_MIN (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[65:44],data1_in[65:44]) : (din0_is_nan[2]? data0_in[65:44] : data1_in[65:44])) :
+         max_pooling ? (((~reg2dp_fp16_en)| (~nan_in[2] & reg2dp_fp16_en))? pooling_MAX (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[65:44],data1_in[65:44]) : (din0_is_nan[2]? data0_in[65:44] : data1_in[65:44])) : 0;
+      
+     pooling_fun[87:66]= mean_pooling? pooling_SUM(reg2dp_int8_en,reg2dp_int16_en,data0_in[87:66],data1_in[87:66]) : 
+         min_pooling ? (((~reg2dp_fp16_en)| (~nan_in[3] & reg2dp_fp16_en))? pooling_MIN (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[87:66],data1_in[87:66]) : (din0_is_nan[3]? data0_in[87:66] : data1_in[87:66])) :
+         max_pooling ? (((~reg2dp_fp16_en)| (~nan_in[3] & reg2dp_fp16_en))? pooling_MAX (reg2dp_int8_en,reg2dp_int16_en,reg2dp_fp16_en,data0_in[87:66],data1_in[87:66]) : (din0_is_nan[3]? data0_in[87:66] : data1_in[87:66])) : 0;
   end
 endfunction
-
+ 
+//=========================================================
+//---------------------------------------------------------
 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
-    pooling_size <= 3'd0;
+    pooling_size[2:0] <= {3{1'b0}};
   end else begin
-    pooling_size <= 3'd0;
+    if(load_din & pdp_din_lc_f) begin
+        if(pooling_din_last)
+            pooling_size[2:0] <= 3'd0;
+        else
+            pooling_size[2:0] <= pooling_size + 1;
+    end
   end
 end
 assign pooling_out_size = pooling_size;
-
+////====================================================================
+////
+////--------------------------------------------------------------------
 assign datain_ext = pdma2pdp_pd[87:0];
-always @(*) begin
-  case (buf_sel)
-    2'd0:    cur_pooling_dat = data_buf0;
-    2'd1:    cur_pooling_dat = data_buf1;
-    2'd2:    cur_pooling_dat = data_buf2;
-    default: cur_pooling_dat = data_buf3;
-  endcase
-end
-
-assign fp_datain_ext      = datain_ext[87:0];
+always @(
+  buf_sel
+  or data_buf0
+  or data_buf1
+  or data_buf2
+  or data_buf3
+  ) begin
+    case(buf_sel)   
+       2'd0:    cur_pooling_dat = data_buf0[87:0];
+       2'd1:    cur_pooling_dat = data_buf1[87:0];
+       2'd2:    cur_pooling_dat = data_buf2[87:0];
+       2'd3:    cur_pooling_dat = data_buf3[87:0];
+       default: cur_pooling_dat = 88'd0;
+    endcase
+end
+//--------------------------------------------------------------------
+assign fp_datain_ext      = datain_ext[87:0] ;
 assign fp_cur_pooling_dat = cur_pooling_dat[87:0];
-assign fp_addin_vld       = pdma2pdp_pvld & pipe_in_rdy & fp_mean_pool_cfg;
-
+
+a
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/CKLNQD12.v`](environment/public/code/CKLNQD12.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp16_to_fp17.v`](environment/public/code/HLS_fp16_to_fp17.v) *(Read-Only Context)*
- [`environment/public/code/HLS_fp17_add.v`](environment/public/code/HLS_fp17_add.v) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/NV_BLKBOX_SINK.v`](environment/public/code/NV_BLKBOX_SINK.v) *(Read-Only Context)*
- [`environment/public/code/NV_CLK_gate_power.v`](environment/public/code/NV_CLK_gate_power.v) *(Read-Only Context)*
- [`environment/public/code/NV_HWACC_NVDLA_tick_defines.vh`](environment/public/code/NV_HWACC_NVDLA_tick_defines.vh) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_PDP_CORE_cal1d.v`](environment/public/code/NV_NVDLA_PDP_CORE_cal1d.v) **(Editable)**
- [`environment/public/code/NV_NVDLA_PDP_CORE_unit1d.v`](environment/public/code/NV_NVDLA_PDP_CORE_unit1d.v) **(Editable)**
- [`environment/public/code/NV_NVDLA_PDP_nan.v`](environment/public/code/NV_NVDLA_PDP_nan.v) **(Editable)**
- [`environment/public/code/cal1d_fp16_pool_sum.v`](environment/public/code/cal1d_fp16_pool_sum.v) *(Read-Only Context)*
- [`environment/public/code/simulate_x_tick.vh`](environment/public/code/simulate_x_tick.vh) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

