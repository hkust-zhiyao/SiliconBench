# `case_23010`: CACC Asymmetric 8-SRAM Accumulator RMW Pipeline & Physical Macro Co-Design

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23010` |
| **Source Silicon Repository** | `nvdla/hw` (`repo_36`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/NV_NVDLA_CACC_assembly_ctrl.v`](environment/public/code/NV_NVDLA_CACC_assembly_ctrl.v), [`code/NV_NVDLA_CACC_assembly_buffer.v`](environment/public/code/NV_NVDLA_CACC_assembly_buffer.v), [`code/NV_NVDLA_CACC_delivery_buffer.v`](environment/public/code/NV_NVDLA_CACC_delivery_buffer.v), [`plan/macro_placement.json`](environment/public/plan/macro_placement.json), [`constraints/cacc_subsys.sdc`](environment/public/constraints/cacc_subsys.sdc) (5 files, 625 LOC) |
| **Public Subsystem Context** | 10 RTL files (1992 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1800s` total (`900s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CACC Asymmetric 8-SRAM Accumulator Subsystem & Physical Macro Co-Design

## Overview
`cacc_sram_subsys` (`code/cacc_sram_subsys.v`) integrates NVDLA's Convolution Accumulator control, 8-bank single-port SRAM assembly buffer, multi-precision calculators (`INT8=2'h0`, `INT16=2'h1`, `FP16=2'h2`), and downstream SDP delivery interface. You own the RTL-to-physical co-design across:
- `code/NV_NVDLA_CACC_assembly_ctrl.v`
- `code/NV_NVDLA_CACC_assembly_buffer.v`
- `code/NV_NVDLA_CACC_delivery_buffer.v`
- `plan/macro_placement.json`
- `constraints/cacc_subsys.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Protocol Contract
1. **Multi-Stripe Accumulation (`Direct` & `Winograd`)**:
   - Accumulate incoming MAC stripes bounded by `mac2accu_pd[6]` (`stripe_end`), `mac2accu_pd[7]` (`channel_end`), and `mac2accu_pd[8]` (`layer_end`) across `INT8` and `INT16` precisions in both `reg2dp_conv_mode=0` (Direct) and `reg2dp_conv_mode=1` (Winograd) modes, and `FP16` precision in `reg2dp_conv_mode=0` (Direct) mode.
   - Start each channel group clean of residual SRAM data, accumulate intermediate stripes in the assembly buffer, and deliver rounded/saturated final channel-group results to SDP on `channel_end=1`.
2. **8-Bank Single-Port SRAM Assembly Buffer**:
   - `NV_NVDLA_CACC_assembly_buffer` instantiates eight `RM_IHPSG13_1P_256x64_c2_bm_bist` single-port synchronous SRAM macros (`u_accu_abuf_0`..`u_accu_abuf_7`), maintaining the 3-cycle `abuf_rd_en -> abuf_rd_data_*` read contract across arbitrary stripe lengths and input bubble patterns.
   - Primary banks `0..3` (`48`-bit payload) operate in all precisions; extension banks `4..7` (`34`-bit payload) operate only in `INT8` mode and must hold `A_MEN == 1'b0` throughout `INT16` and `FP16` operation.
3. **Backpressured SDP Delivery & Layer Interrupts**:
   - `NV_NVDLA_CACC_delivery_buffer` must preserve lossless `cacc2sdp_valid`/`cacc2sdp_pd` handshaking under arbitrary `cacc2sdp_ready` backpressure and emit a 1-cycle completion pulse on `cacc2glb_done_intr_pd[1:0]` alternating between `2'b01` and `2'b10` when a `layer_end` (`cacc2sdp_pd[129]`) beat retires.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 1900]` um, core area `[50, 50, 2550, 1850]` um. Place all eight `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2` um core margin, `>= 8` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/cacc_subsys.sdc`)**: Constrain `nvdla_core_clk` to period `<= 15.0` ns with `>= 1.2` ns input/output delays on all non-clock ports (only `nvdla_core_rstn` may carry `set_false_path`).
- **OpenROAD Signoff**: Connected `VDD`/`VSS` PDN grids, post-GRT setup `WNS >= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 15`, and total routed wirelength `<= 2,650,000` um.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment (`case_23010`)

## Available Tools & Collateral
- **RTL Simulation**: Icarus Verilog (`iverilog -g2012` / `vvp`) or Verilator (`verilator`)
- **Synthesis**: Yosys with SystemVerilog Slang frontend (`yosys -m slang`)
- **Physical Implementation & STA**: OpenROAD (`openroad -exit`)
- **PDK Collateral (`pdk/`)**: IHP SG13G2 130nm standard cells (`sg13g2_tech.lef`, `sg13g2_stdcell.lef`, `sg13g2_stdcell_typ_1p20V_25C.lib`, `core.v`) and `RM_IHPSG13_1P_256x64_c2_bm_bist` SRAM macro views (`256.v` behavioral model, `256_stub.v` blackbox stub, `256.lef`, `256.lib`).

## Editable Files
- `code/NV_NVDLA_CACC_assembly_ctrl.v`
- `code/NV_NVDLA_CACC_assembly_buffer.v`
- `code/NV_NVDLA_CACC_delivery_buffer.v`
- `plan/macro_placement.json`
- `constraints/cacc_subsys.sdc`

## Example Commands
```bash
# 1. Behavioral RTL elaboration check
iverilog -g2012 -o /tmp/cacc_sim \
  pdk/core.v pdk/256.v code/NV_DW_lsd.v \
  code/NV_NVDLA_CACC_CALC_int8.v code/NV_NVDLA_CACC_CALC_int16.v code/NV_NVDLA_CACC_CALC_fp_48b.v \
  code/NV_NVDLA_CACC_assembly_ctrl.v code/NV_NVDLA_CACC_assembly_buffer.v \
  code/NV_NVDLA_CACC_delivery_buffer.v code/cacc_sram_subsys.v

# 2. Synthesis to SG13G2 standard cells + 8x hard SRAM macros
yosys -m slang -p "
  read_slang -DSYNTHESIS pdk/256_stub.v code/NV_DW_lsd.v \
    code/NV_NVDLA_CACC_CALC_int8.v code/NV_NVDLA_CACC_CALC_int16.v code/NV_NVDLA_CACC_CALC_fp_48b.v \
    code/NV_NVDLA_CACC_assembly_ctrl.v code/NV_NVDLA_CACC_assembly_buffer.v \
    code/NV_NVDLA_CACC_delivery_buffer.v code/cacc_sram_subsys.v --top cacc_sram_subsys;
  hierarchy -check -top cacc_sram_subsys;
  synth -top cacc_sram_subsys -flatten;
  delete t:\$scopeinfo;
  dfflibmap -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  abc -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/mapped.v
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/NV_NVDLA_CACC_assembly_ctrl.v (Buggy Starter)
+++ b/solution/gold/code/NV_NVDLA_CACC_assembly_ctrl.v (Golden Reference)
@@ -65,6 +65,11 @@
   wire       is_fp16     = (reg2dp_proc_precision == 2'h2);
   wire       is_winograd = (reg2dp_conv_mode == 1'b1);
 
+  wire       is_x1 = ~is_int8 & ~is_winograd;
+  wire       is_x2 =  is_int8 & ~is_winograd;
+  wire       is_x4 = ~is_int8 &  is_winograd;
+  wire       is_x8 =  is_int8 &  is_winograd;
+
   reg  [3:0] slcg_cell_en_d1, slcg_cell_en_d2, slcg_cell_en_d3;
   wire [3:0] slcg_cell_en_w = {
     reg2dp_op_en &  is_fp16 &  is_winograd,
@@ -87,6 +92,7 @@
   assign slcg_cell_en = slcg_cell_en_d3;
 
   reg op_en_d1;
+  wire op_en_start = reg2dp_op_en & (~op_en_d1 | wait_for_op_en) & (~dp2reg_done);
   wire wait_for_op_en_w = dp2reg_done ? 1'b1 :
                           (reg2dp_op_en & ~op_en_d1) ? 1'b0 :
                           wait_for_op_en;
@@ -122,10 +128,11 @@
 
   reg  [9:0] accu_cnt;
   wire [9:0] accu_cnt_inc = accu_cnt + 10'd1;
+  wire [9:0] accu_cnt_w   = (layer_st | (accu_valid & accu_stripe_end)) ? 10'd0 : accu_cnt_inc;
 
   reg        accu_channel_st;
   wire       accu_channel_st_w = layer_st ? 1'b1 :
-                                 (accu_valid & accu_stripe_end) ? 1'b0 :
+                                 (accu_valid & accu_stripe_end) ? accu_channel_end :
                                  accu_channel_st;
 
   always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
@@ -143,15 +150,16 @@
 
   wire [3:0] dir_sel_d0 = (4'b0001 << accu_cnt[1:0]);
   wire [3:0] wg_pair_d0 = accu_cnt[0] ? 4'b1100 : 4'b0011;
-  wire [7:0] accu_bank_mask = cfg_winograd ? {wg_pair_d0, wg_pair_d0}
-                                           : {cfg_is_int8 ? dir_sel_d0 : 4'b0000, dir_sel_d0};
-
-  wire [7:0] accu_addr_d0    = cfg_winograd ? accu_cnt[8:1] : accu_cnt[9:2];
+  wire [3:0] pri_mask_d0 = cfg_winograd ? wg_pair_d0 : dir_sel_d0;
+  wire [7:0] accu_bank_mask = {cfg_is_int8 ? pri_mask_d0 : 4'b0000, pri_mask_d0};
+
+  wire [7:0] accu_addr_d0 = cfg_winograd ? accu_cnt[8:1] : accu_cnt[9:2];
   wire [7:0] active_lanes_d0 = accu_bank_mask & accu_mask_d0;
 
   assign abuf_rd_addr = accu_addr_d0;
   assign abuf_rd_en   = (accu_valid & ~accu_channel_st) ? active_lanes_d0 : 8'd0;
 
+  // 3-stage control delay matching assembly_buffer 3-cycle read latency (d0 -> d1 -> d2 -> ctrl)
   reg        vld_d1, vld_d2;
   reg  [7:0] addr_d1, addr_d2, accu_ctrl_addr;
   reg  [7:0] bmask_d1, bmask_d2;
@@ -203,6 +211,9 @@
     end
   end
 
+  // Calculator writeback & delivery alignment:
+  // INT8 / INT16 calculators: 2-cycle latency (c1 -> c2)
+  // FP16 (CALC_fp_48b)      : 4-cycle latency (c1 -> c2 -> c3 -> c4)
   wire [7:0] wb_en_c0  = (accu_ctrl_valid & ~accu_ctrl_dlv_sel) ? accu_ctrl_lane_en : 8'd0;
   wire       dlv_v_c0  = accu_ctrl_valid & accu_ctrl_dlv_sel;
 
@@ -247,10 +258,10 @@
     end
   end
 
-  assign abuf_wr_en        = cfg_is_fp16 ? wb_en_c4   : wb_en_c2;
-  assign abuf_wr_addr      = cfg_is_fp16 ? wb_addr_c4 : wb_addr_c2;
-  assign dlv_out_valid     = cfg_is_fp16 ? dlv_v_c4   : dlv_v_c2;
-  assign dlv_out_mask      = cfg_is_fp16 ? dlv_m_c4   : dlv_m_c2;
-  assign dlv_out_layer_end = cfg_is_fp16 ? dlv_le_c4  : dlv_le_c2;
+  assign abuf_wr_en        = cfg_is_fp16 ? (wb_en_c3 & 8'h0f) : wb_en_c2;
+  assign abuf_wr_addr      = cfg_is_fp16 ? wb_addr_c3         : wb_addr_c2;
+  assign dlv_out_valid     = cfg_is_fp16 ? dlv_v_c4           : dlv_v_c2;
+  assign dlv_out_mask      = cfg_is_fp16 ? (dlv_m_c4 & 8'h0f) : dlv_m_c2;
+  assign dlv_out_layer_end = cfg_is_fp16 ? dlv_le_c4          : dlv_le_c2;
 
 endmodule

--- a/environment/public/code/NV_NVDLA_CACC_assembly_buffer.v (Buggy Starter)
+++ b/solution/gold/code/NV_NVDLA_CACC_assembly_buffer.v (Golden Reference)
@@ -46,58 +46,139 @@
   assign ext_wr_in[3] = abuf_wr_data_7;
 
   reg   [7:0] wr_d1_vld;
-  reg   [7:0] wr_d1_addr;
+  reg   [7:0] wr_d1_addr [0:7];
+  reg   [7:0] pend_vld;
+  reg   [7:0] pend_addr  [0:7];
   reg   [7:0] abuf_rd_en_d1;
   reg   [7:0] abuf_rd_en_d2;
-
-  reg  [47:0] pri_wr_d1_data [0:3];
-  reg  [47:0] pri_rd_d2      [0:3];
-  reg  [33:0] ext_wr_d1_data [0:3];
-  reg  [33:0] ext_rd_d2      [0:3];
-
+  reg   [7:0] raw_hit_d1;
+
+  reg  [47:0] pri_wr_d1_data  [0:3];
+  reg  [47:0] pri_pend_data   [0:3];
+  reg  [47:0] pri_raw_d1      [0:3];
+  reg  [47:0] pri_rd_d2       [0:3];
+
+  reg  [33:0] ext_wr_d1_data  [0:3];
+  reg  [33:0] ext_pend_data   [0:3];
+  reg  [33:0] ext_raw_d1      [0:3];
+  reg  [33:0] ext_rd_d2       [0:3];
+
+  wire  [7:0] raw_hit;
+  wire  [7:0] sram_rd_go;
+  wire  [7:0] sram_wr_go;
   wire  [7:0] sram_men;
   wire  [7:0] sram_wen;
   wire  [7:0] sram_ren;
-  wire  [7:0] sram_addr [0:7];
-  wire [63:0] sram_dout [0:7];
-
-  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
-    if (!nvdla_core_rstn) begin
-      wr_d1_vld     <= 8'd0;
-      wr_d1_addr    <= 8'd0;
-      abuf_rd_en_d1 <= 8'd0;
-      abuf_rd_en_d2 <= 8'd0;
-    end else begin
-      wr_d1_vld     <= abuf_wr_en;
-      if (|abuf_wr_en) wr_d1_addr <= abuf_wr_addr;
-      abuf_rd_en_d1 <= abuf_rd_en;
-      abuf_rd_en_d2 <= abuf_rd_en_d1;
-    end
-  end
+  wire  [7:0] sram_addr       [0:7];
+  wire [47:0] pri_sram_wdata  [0:3];
+  wire [33:0] ext_sram_wdata  [0:3];
+  wire [63:0] sram_dout       [0:7];
 
   genvar b;
   generate
     for (b = 0; b < 4; b = b + 1) begin : gen_pri_bank
-      assign sram_men[b]  = wr_d1_vld[b] | abuf_rd_en[b];
-      assign sram_wen[b]  = wr_d1_vld[b];
-      assign sram_ren[b]  = abuf_rd_en[b] & ~wr_d1_vld[b];
-      assign sram_addr[b] = wr_d1_vld[b] ? wr_d1_addr : abuf_rd_addr;
-
+      wire hit_w0   = abuf_wr_en[b] && (abuf_wr_addr  == abuf_rd_addr);
+      wire hit_wd1  = wr_d1_vld[b]  && (wr_d1_addr[b] == abuf_rd_addr);
+      wire hit_pend = pend_vld[b]   && (pend_addr[b]  == abuf_rd_addr);
+      wire [47:0] fwd_val = hit_w0 ? pri_wr_in[b] : hit_wd1 ? pri_wr_d1_data[b] : pri_pend_data[b];
+
+      assign raw_hit[b]        = abuf_rd_en[b] && (hit_w0 || hit_wd1 || hit_pend);
+      assign sram_rd_go[b]     = abuf_rd_en[b] && !raw_hit[b];
+      assign sram_wr_go[b]     = !sram_rd_go[b] && (pend_vld[b] || wr_d1_vld[b]);
+      assign sram_men[b]       = sram_rd_go[b] || sram_wr_go[b];
+      assign sram_wen[b]       = sram_wr_go[b];
+      assign sram_ren[b]       = sram_rd_go[b];
+      assign sram_addr[b]      = sram_rd_go[b] ? abuf_rd_addr : pend_vld[b] ? pend_addr[b] : wr_d1_addr[b];
+      assign pri_sram_wdata[b] = pend_vld[b] ? pri_pend_data[b] : pri_wr_d1_data[b];
+
+      always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+        if (!nvdla_core_rstn) begin
+          wr_d1_vld[b]     <= 1'b0;
+          wr_d1_addr[b]    <= 8'd0;
+          pend_vld[b]      <= 1'b0;
+          pend_addr[b]     <= 8'd0;
+          abuf_rd_en_d1[b] <= 1'b0;
+          abuf_rd_en_d2[b] <= 1'b0;
+          raw_hit_d1[b]    <= 1'b0;
+        end else begin
+          wr_d1_vld[b] <= abuf_wr_en[b];
+          if (abuf_wr_en[b]) wr_d1_addr[b] <= abuf_wr_addr;
+          if (sram_rd_go[b]) begin
+            if (wr_d1_vld[b]) begin
+              pend_vld[b]  <= 1'b1;
+              pend_addr[b] <= wr_d1_addr[b];
+            end
+          end else if (pend_vld[b] && wr_d1_vld[b]) begin
+            pend_vld[b]  <= 1'b1;
+            pend_addr[b] <= wr_d1_addr[b];
+          end else begin
+            pend_vld[b]  <= 1'b0;
+          end
+          abuf_rd_en_d1[b] <= abuf_rd_en[b];
+          abuf_rd_en_d2[b] <= abuf_rd_en_d1[b];
+          raw_hit_d1[b]    <= raw_hit[b];
+        end
+      end
       always @(posedge nvdla_core_clk) begin
-        if (abuf_wr_en[b])    pri_wr_d1_data[b] <= pri_wr_in[b];
-        if (abuf_rd_en_d1[b]) pri_rd_d2[b]      <= sram_dout[b][47:0];
+        if (abuf_wr_en[b]) pri_wr_d1_data[b] <= pri_wr_in[b];
+        if ((sram_rd_go[b] && wr_d1_vld[b]) || (!sram_rd_go[b] && pend_vld[b] && wr_d1_vld[b]))
+          pri_pend_data[b] <= pri_wr_d1_data[b];
+        if (raw_hit[b]) pri_raw_d1[b] <= fwd_val;
+        if (abuf_rd_en_d1[b])
+          pri_rd_d2[b] <= raw_hit_d1[b] ? pri_raw_d1[b] : sram_dout[b][47:0];
       end
     end
 
     for (b = 4; b < 8; b = b + 1) begin : gen_ext_bank
-      assign sram_men[b]  = wr_d1_vld[b] | abuf_rd_en[b];
-      assign sram_wen[b]  = wr_d1_vld[b];
-      assign sram_ren[b]  = abuf_rd_en[b] & ~wr_d1_vld[b];
-      assign sram_addr[b] = wr_d1_vld[b] ? wr_d1_addr : abuf_rd_addr;
-
+      wire hit_w0   = abuf_wr_en[b] && (abuf_wr_addr  == abuf_rd_addr);
+      wire hit_wd1  = wr_d1_vld[b]  && (wr_d1_addr[b] == abuf_rd_addr);
+      wire hit_pend = pend_vld[b]   && (pend_addr[b]  == abuf_rd_addr);
+      wire [33:0] fwd_val = hit_w0 ? ext_wr_in[b-4] : hit_wd1 ? ext_wr_d1_data[b-4] : ext_pend_data[b-4];
+
+      assign raw_hit[b]          = abuf_rd_en[b] && (hit_w0 || hit_wd1 || hit_pend);
+      assign sram_rd_go[b]       = abuf_rd_en[b] && !raw_hit[b];
+      assign sram_wr_go[b]       = !sram_rd_go[b] && (pend_vld[b] || wr_d1_vld[b]);
+      assign sram_men[b]         = sram_rd_go[b] || sram_wr_go[b];
+      assign sram_wen[b]         = sram_wr_go[b];
+      assign sram_ren[b]         = sram_rd_go[b];
+      assign sram_addr[b]        = sram_rd_go[b] ? abuf_rd_addr : pend_vld[b] ? pend_addr[b] : wr_d1_addr[b];
+      assign ext_sram_wdata[b-4] = pend_vld[b] ? ext_pend_data[b-4] : ext_wr_d1_data[b-4];
+
+      always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
+        if (!nvdla_core_rstn) begin
+          wr_d1_vld[b]     <= 1'b0;
+          wr_d1_addr[b]    <= 8'd0;
+          pend_vld[b]      <= 1'b0;
+          pend_addr[b]     <= 8'd0;
+          abuf_rd_en_d1[b] <= 1'b0;
+          abuf_rd_en_d2[b] <= 1'b0;
+          raw_hit_d1[b]    <= 1'b0;
+        end else begin
+          wr_d1_vld[b] <= abuf_wr_en[b];
+          if (abuf_wr_en[b]) wr_d1_addr[b] <= abuf_wr_addr;
+          if (sram_rd_go[b]) begin
+            if (wr_d1_vld[b]) begin
+              pend_vld[b]  <= 1'b1;
+              pend_addr[b] <= wr_d1_addr[b];
+            end
+          end else if (pend_vld[b] && wr_d1_vld[b]) begin
+            pend_vld[b]  <= 1'b1;
+            pend_addr[b] <= wr_d1_addr[b];
+          end else begin
+            pend_vld[b]  <= 1'b0;
+          end
+          abuf_rd_en_d1[b] <= abuf_rd_en[b];
+          abuf_rd_en_d2[b] <= abuf_rd_en_d1[b];
+          raw_hit_d1[b]    <= raw_hit[b];
+        end
+      end
       always @(posedge nvdla_core_clk) begin
-        if (abuf_wr_en[b])    ext_wr_d1_data[b-4] <= ext_wr_in[b-4];
-        if (abuf_rd_en_d1[b]) ext_rd_d2[b-4]      <= sram_dout[b][33:0];
+        if (abuf_wr_en[b]) ext_wr_d1_data[b-4] <= ext_wr_in[b-4];
+        if ((sram_rd_go[b] && wr_d1_vld[b]) || (!sram_rd_go[b] && pend_vld[b] && wr_d1_vld[b]))
+          ext_pend_data[b-4] <= ext_wr_d1_data[b-4];
+        if (raw_hit[b]) ext_raw_d1[b-4] <= fwd_val;
+        if (abuf_rd_en_d1[b])
+          ext_rd_d2[b-4] <= raw_hit_d1[b] ? ext_raw_d1[b-4] : sram_dout[b][33:0];
       end
     end
   endgenerate
@@ -115,56 +196,56 @@
 
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_0 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[0]), .A_WEN(sram_wen[0]), .A_REN(sram_ren[0]),
-    .A_ADDR(sram_addr[0]), .A_DIN({16'd0, pri_wr_d1_data[0]}), .A_DLY(1'b1), .A_DOUT(sram_dout[0]),
+    .A_ADDR(sram_addr[0]), .A_DIN({16'd0, pri_sram_wdata[0]}), .A_DLY(1'b1), .A_DOUT(sram_dout[0]),
     .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
   );
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_1 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[1]), .A_WEN(sram_wen[1]), .A_REN(sram_ren[1]),
-    .A_ADDR(sram_addr[1]), .A_DIN({16'd0, pri_wr_d1_data[1]}), .A_DLY(1'b1), .A_DOUT(sram_dout[1]),
+    .A_ADDR(sram_addr[1]), .A_DIN({16'd0, pri_sram_wdata[1]}), .A_DLY(1'b1), .A_DOUT(sram_dout[1]),
     .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
   );
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_2 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[2]), .A_WEN(sram_wen[2]), .A_REN(sram_ren[2]),
-    .A_ADDR(sram_addr[2]), .A_DIN({16'd0, pri_wr_d1_data[2]}), .A_DLY(1'b1), .A_DOUT(sram_dout[2]),
+    .A_ADDR(sram_addr[2]), .A_DIN({16'd0, pri_sram_wdata[2]}), .A_DLY(1'b1), .A_DOUT(sram_dout[2]),
     .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
   );
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_3 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[3]), .A_WEN(sram_wen[3]), .A_REN(sram_ren[3]),
-    .A_ADDR(sram_addr[3]), .A_DIN({16'd0, pri_wr_d1_data[3]}), .A_DLY(1'b1), .A_DOUT(sram_dout[3]),
+    .A_ADDR(sram_addr[3]), .A_DIN({16'd0, pri_sram_wdata[3]}), .A_DLY(1'b1), .A_DOUT(sram_dout[3]),
     .A_BM({16'd0, 48'hFFFF_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
   );
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_4 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[4]), .A_WEN(sram_wen[4]), .A_REN(sram_ren[4]),
-    .A_ADDR(sram_addr[4]), .A_DIN({30'd0, ext_wr_d1_data[0]}), .A_DLY(1'b1), .A_DOUT(sram_dout[4]),
+    .A_ADDR(sram_addr[4]), .A_DIN({30'd0, ext_sram_wdata[0]}), .A_DLY(1'b1), .A_DOUT(sram_dout[4]),
     .A_BM({30'd0, 34'h3_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
   );
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_5 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[5]), .A_WEN(sram_wen[5]), .A_REN(sram_ren[5]),
-    .A_ADDR(sram_addr[5]), .A_DIN({30'd0, ext_wr_d1_data[1]}), .A_DLY(1'b1), .A_DOUT(sram_dout[5]),
+    .A_ADDR(sram_addr[5]), .A_DIN({30'd0, ext_sram_wdata[1]}), .A_DLY(1'b1), .A_DOUT(sram_dout[5]),
     .A_BM({30'd0, 34'h3_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
   );
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_6 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[6]), .A_WEN(sram_wen[6]), .A_REN(sram_ren[6]),
-    .A_ADDR(sram_addr[6]), .A_DIN({30'd0, ext_wr_d1_data[2]}), .A_DLY(1'b1), .A_DOUT(sram_dout[6]),
+    .A_ADDR(sram_addr[6]), .A_DIN({30'd0, ext_sram_wdata[2]}), .A_DLY(1'b1), .A_DOUT(sram_dout[6]),
     .A_BM({30'd0, 34'h3_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
   );
   RM_IHPSG13_1P_256x64_c2_bm_bist u_accu_abuf_7 (
     .A_CLK(nvdla_core_clk), .A_MEN(sram_men[7]), .A_WEN(sram_wen[7]), .A_REN(sram_ren[7]),
-    .A_ADDR(sram_addr[7]), .A_DIN({30'd0, ext_wr_d1_data[3]}), .A_DLY(1'b1), .A_DOUT(sram_dout[7]),
+    .A_ADDR(sram_addr[7]), .A_DIN({30'd0, ext_sram_wdata[3]}), .A_DLY(1'b1), .A_DOUT(sram_dout[7]),
     .A_BM({30'd0, 34'h3_FFFF_FFFF}),
     .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
     .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)

--- a/environment/public/code/NV_NVDLA_CACC_delivery_buffer.v (Buggy Starter)
+++ b/solution/gold/code/NV_NVDLA_CACC_delivery_buffer.v (Golden Reference)
@@ -61,12 +61,15 @@
 
   assign dbuf_rd_ready = dbuf_rd_ready_d0;
 
+  wire  [1:0] dbuf_rd_en_in   = dbuf_rd_ready_d0 ? dbuf_rd_en   : dbuf_rd_en_d1;
+  wire        dbuf_rd_addr_in = dbuf_rd_ready_d0 ? dbuf_rd_addr : dbuf_rd_addr_d1;
+
   always @(posedge nvdla_core_clk) begin
     if (dbuf_wr_en_d1[0]) bank_mem_0[dbuf_wr_addr_d1] <= dbuf_wr_data_d1;
     if (dbuf_wr_en_d1[1]) bank_mem_1[dbuf_wr_addr_d1] <= dbuf_wr_data_d1;
 
-    if (dbuf_rd_en[0]) dbuf_rd_data_0 <= bank_mem_0[dbuf_rd_addr];
-    if (dbuf_rd_en[1]) dbuf_rd_data_1 <= bank_mem_1[dbuf_rd_addr];
+    if (dbuf_rd_en_in[0]) dbuf_rd_data_0 <= (dbuf_wr_en_d1[0] && (dbuf_wr_addr_d1 == dbuf_rd_addr_in)) ? dbuf_wr_data_d1 : bank_mem_0[dbuf_rd_addr_in];
+    if (dbuf_rd_en_in[1]) dbuf_rd_data_1 <= (dbuf_wr_en_d1[1] && (dbuf_wr_addr_d1 == dbuf_rd_addr_in)) ? dbuf_wr_data_d1 : bank_mem_1[dbuf_rd_addr_in];
   end
 
   wire dbuf_rd_d0_reg_en   = (|dbuf_rd_en) & dbuf_rd_ready_d0;
@@ -112,14 +115,14 @@
     end
   end
   always @(posedge nvdla_core_clk) begin
-    if (dbuf_rd_valid_d1)  dbuf_rd_data_ecc_d2 <= dbuf_rd_data_ecc_d2_w;
+    if (dbuf_rd_d1_reg_en) dbuf_rd_data_ecc_d2 <= dbuf_rd_data_ecc_d2_w;
     if (dbuf_rd_d2_reg_en) dbuf_rd_data_d3     <= dbuf_rd_data_ecc_d2;
   end
 
   assign cacc2sdp_valid = dbuf_rd_valid_d3;
   assign cacc2sdp_pd    = {dbuf_rd_layer_end_d3, 1'b0, dbuf_rd_data_d3};
 
-  wire       cacc_done        = dbuf_rd_valid_d3 & dbuf_rd_layer_end_d3;
+  wire       cacc_done        = dbuf_rd_valid_d3 & dbuf_rd_ready_d3 & dbuf_rd_layer_end_d3;
   reg        intr_sel;
   reg  [1:0] cacc_done_intr;
 

--- a/environment/public/plan/macro_placement.json (Buggy Starter)
+++ b/solution/gold/plan/macro_placement.json (Golden Reference)
@@ -2,50 +2,50 @@
   "macros": [
     {
       "instance": "u_assembly_buffer.u_accu_abuf_0",
-      "x": 60.0,
-      "y": 54.0,
+      "x": 100.0,
+      "y": 140.0,
+      "orientation": "R180"
+    },
+    {
+      "instance": "u_assembly_buffer.u_accu_abuf_2",
+      "x": 100.0,
+      "y": 640.0,
+      "orientation": "MY"
+    },
+    {
+      "instance": "u_assembly_buffer.u_accu_abuf_1",
+      "x": 100.0,
+      "y": 1100.0,
+      "orientation": "R180"
+    },
+    {
+      "instance": "u_assembly_buffer.u_accu_abuf_3",
+      "x": 100.0,
+      "y": 1600.0,
+      "orientation": "MY"
+    },
+    {
+      "instance": "u_assembly_buffer.u_accu_abuf_4",
+      "x": 1710.0,
+      "y": 200.0,
+      "orientation": "MX"
+    },
+    {
+      "instance": "u_assembly_buffer.u_accu_abuf_6",
+      "x": 1710.0,
+      "y": 620.0,
       "orientation": "R0"
     },
     {
-      "instance": "u_assembly_buffer.u_accu_abuf_7",
-      "x": 60.0,
-      "y": 182.0,
-      "orientation": "R0"
-    },
-    {
-      "instance": "u_assembly_buffer.u_accu_abuf_2",
-      "x": 1755.0,
-      "y": 1725.0,
+      "instance": "u_assembly_buffer.u_accu_abuf_5",
+      "x": 1710.0,
+      "y": 1120.0,
       "orientation": "MX"
     },
     {
-      "instance": "u_assembly_buffer.u_accu_abuf_5",
-      "x": 1755.0,
-      "y": 1595.0,
-      "orientation": "MX"
-    },
-    {
-      "instance": "u_assembly_buffer.u_accu_abuf_1",
-      "x": 1755.0,
-      "y": 54.0,
-      "orientation": "R0"
-    },
-    {
-      "instance": "u_assembly_buffer.u_accu_abuf_6",
-      "x": 60.0,
-      "y": 1725.0,
-      "orientation": "MX"
-    },
-    {
-      "instance": "u_assembly_buffer.u_accu_abuf_3",
-      "x": 60.0,
-      "y": 1595.0,
-      "orientation": "MX"
-    },
-    {
-      "instance": "u_assembly_buffer.u_accu_abuf_4",
-      "x": 1755.0,
-      "y": 182.0,
+      "instance": "u_assembly_buffer.u_accu_abuf_7",
+      "x": 1710.0,
+      "y": 1540.0,
       "orientation": "R0"
     }
   ]

--- a/environment/public/constraints/cacc_subsys.sdc (Buggy Starter)
+++ b/solution/gold/constraints/cacc_subsys.sdc (Golden Reference)
@@ -1,4 +1,5 @@
-# Draft bring-up constraints (needs signoff closure)
-create_clock -name core_clk -period 25.0 [get_ports nvdla_core_clk]
-set_input_delay 0.2 -clock core_clk [all_inputs -no_clocks]
-set_output_delay 0.2 -clock core_clk [all_outputs]
+# Signoff timing constraints for cacc_sram_subsys (IHP SG13G2 130nm)
+create_clock -name core_clk -period 14.5 [get_ports nvdla_core_clk]
+set_input_delay 1.2 -clock core_clk [all_inputs -no_clocks]
+set_output_delay 1.2 -clock core_clk [all_outputs]
+set_false_path -from [get_ports nvdla_core_rstn]

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/NV_DW_lsd.v`](environment/public/code/NV_DW_lsd.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CACC_CALC_fp_48b.v`](environment/public/code/NV_NVDLA_CACC_CALC_fp_48b.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CACC_CALC_int16.v`](environment/public/code/NV_NVDLA_CACC_CALC_int16.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CACC_CALC_int8.v`](environment/public/code/NV_NVDLA_CACC_CALC_int8.v) *(Read-Only Context)*
- [`environment/public/code/NV_NVDLA_CACC_assembly_buffer.v`](environment/public/code/NV_NVDLA_CACC_assembly_buffer.v) **(Editable)**
- [`environment/public/code/NV_NVDLA_CACC_assembly_ctrl.v`](environment/public/code/NV_NVDLA_CACC_assembly_ctrl.v) **(Editable)**
- [`environment/public/code/NV_NVDLA_CACC_delivery_buffer.v`](environment/public/code/NV_NVDLA_CACC_delivery_buffer.v) **(Editable)**
- [`environment/public/code/cacc_sram_subsys.v`](environment/public/code/cacc_sram_subsys.v) *(Read-Only Context)*
- [`environment/public/constraints/cacc_subsys.sdc`](environment/public/constraints/cacc_subsys.sdc) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/pdk/256.lef`](environment/public/pdk/256.lef) *(Read-Only Context)*
- [`environment/public/pdk/256.lib`](environment/public/pdk/256.lib) *(Read-Only Context)*
- [`environment/public/pdk/256.v`](environment/public/pdk/256.v) *(Read-Only Context)*
- [`environment/public/pdk/256_stub.v`](environment/public/pdk/256_stub.v) *(Read-Only Context)*
- [`environment/public/pdk/LICENSE.IHP`](environment/public/pdk/LICENSE.IHP) *(Read-Only Context)*
- [`environment/public/pdk/core.v`](environment/public/pdk/core.v) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell.lef`](environment/public/pdk/sg13g2_stdcell.lef) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib`](environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_tech.lef`](environment/public/pdk/sg13g2_tech.lef) *(Read-Only Context)*
- [`environment/public/plan/macro_placement.json`](environment/public/plan/macro_placement.json) **(Editable)**

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

