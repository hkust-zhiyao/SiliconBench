# `case_9014`: Co-Design BlackParrot Four-Cluster 128-bit I-Cache SRAM Subword Byte-Reverse/XOR Relay and 8-Macro CTS Floorplan

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_9014` |
| **Source Silicon Repository** | `black-parrot/black-parrot` (`repo_09`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `pins_routing_congestion` (Pin Alignment, Global Routing Congestion, PDN & Wirelength Closure) |
| **Multi-Domain Tags** | `clocking`, `floorplan_macros`, `gatelevel_physical_effects`, `pins_routing_congestion`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/banked.sv`](environment/public/code/banked.sv), [`plan/placement.json`](environment/public/plan/placement.json) (2 files, 96 LOC) |
| **Public Subsystem Context** | 4 RTL files (898 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Co-Design BlackParrot Four-Cluster 128-bit I-Cache SRAM Subword Byte-Reverse/XOR Relay and 8-Macro CTS Floorplan

`code/banked.sv` instantiates four `bp_sram_256x128` (`256x128`, 1-port, `Latency=1`) instruction-cache bank clusters (`cluster[0..3].mem`), each mapped to two `RM_IHPSG13_1P_256x64_c2_bm_bist` cuts (`i_cut_low` for `[63:0]`, `i_cut_high` for `[127:64]`), alongside the BlackParrot front-end instruction cache (`code/rtl/bp_fe_icache.sv`). Repair `code/banked.sv` without extra standard-cell flip-flops or latches (`Sinks 8` and all 256 `i_cut_low/A_DOUT->i_cut_high/A_DIN` paths must remain): lower write data is `wdata_i[63:0]`; when `relay_i[i]=0`, upper write data is `wdata_i[127:64]` and byte enable is `be_i[15:0]`; when `relay_i[i]=1`, reverse the byte order within each 32-bit word of cluster `i`'s lower-cut read data (`{rdata[i][39:32], rdata[i][47:40], rdata[i][55:48], rdata[i][63:56], rdata[i][7:0], rdata[i][15:8], rdata[i][23:16], rdata[i][31:24]}`) when `swap_mode_i[0]=1`, XOR that 64-bit word with `wdata_i[127:64]` when `swap_mode_i[1]=1` for upper write data, drive upper byte enables with `be_i[15:8] | (swap_mode_i[0] ? {be_i[4],be_i[5],be_i[6],be_i[7],be_i[0],be_i[1],be_i[2],be_i[3]} : be_i[7:0])`, and drive lower byte enables with `be_i[7:0] & be_i[15:8]`. `rdata_o` is the 4-cluster 128-bit bitwise XOR.

In `plan/placement.json`, place all 8 macros (`784.48x118.78 um`, `"orient"` in `{"R0","R180","MX","MY"}`, integer `"x"` and `"y"` coordinates in um) inside `x in [65,2335]`, `y in [68,1730]` with `>=20 um` clearance, matching `y` per bank (`x(low)<x(high)`), banks `0,1` in `y in [68,420]` (`y(0)<y(1)`), and banks `2,3` in `y in [1340,1730]` (`y(2)<y(3)`), achieving rise-to-rise `A_CLK` latency spread `<=0.00400 ns`, setup slack `>=2.70 ns`, hold slack `>=0.00 ns`, and Metal2–Metal5 wirelength `<=1,110,000.0 um`. Edit only `code/banked.sv` and `plan/placement.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Physical Implementation Guide

Editable: `code/banked.sv`, `plan/placement.json`. Read-only: `code/bp_sram_256x128.sv`, `code/rtl/bp_fe_icache.sv`, `pdk/**`, `physical/**`, `LICENSE`.

## 1. Functional Simulation (Icarus Verilog)
```bash
iverilog -g2012 -s tb -o sim pdk/256.v pdk/core.v code/bp_sram_256x128.sv code/banked.sv tb.sv
vvp sim
```

## 2. Logic Synthesis (Yosys + Slang)
`physical/synth.ys` synthesizes `banked` with `code/bp_sram_256x128.sv`, `pdk/256_stub.v`, and `pdk/sg13g2_stdcell_typ_1p20V_25C.lib` into `mapped.v` (8 `RM_IHPSG13_1P_256x64_c2_bm_bist` macros, zero standard-cell flip-flops or latches):
```bash
yosys -m slang -s physical/synth.ys
```

## 3. Physical Implementation & STA (OpenROAD)
Substitute `@PDK@`, `@MAPPED@`, `@DEF@`, `@GUIDE@`, and `@PLACEMENTS@` (`place_macro -macro_name {cluster\[<b>\].mem.gen_256x128xBx1.i_cut_<half>} -location {<x> <y>} -orientation <orient>`) in `physical/flow.tcl.in`, then run:
```bash
openroad -exit flow.tcl
```

Targets:
- Legal placement, connected `VDD`/`VSS`, `0` global-route overflow, `Sinks 8`, `256` relay paths.
- Rise-to-rise `A_CLK` latency spread (`report_clock_latency`): `<= 0.00400 ns`.
- Routed setup slack: `>= 2.70 ns`; hold slack: `>= 0.00 ns`.
- Metal2–Metal5 global-route wirelength: `<= 1,110,000.0 um`.

- Each macro entry in `plan/placement.json` must use integer `x` and `y` coordinates (`type(x) is int`, `type(y) is int`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/banked.sv (Buggy Starter)
+++ b/solution/gold/code/banked.sv (Golden Reference)
@@ -12,10 +12,18 @@
   output logic [127:0] rdata_o
 );
   wire [127:0] rdata [4];
+  wire [7:0]   low_be_perm = swap_mode_i[0] ? {
+    be_i[4], be_i[5], be_i[6], be_i[7],
+    be_i[0], be_i[1], be_i[2], be_i[3]
+  } : be_i[7:0];
 
   for (genvar i = 0; i < 4; i = i + 1) begin : cluster
-    wire [127:0] wd = relay_i[i] ? {rdata[i][127:64], wdata_i[63:0]} : wdata_i;
-    wire [15:0]  be = be_i;
+    wire [31:0] rev_hi32 = {rdata[i][39:32], rdata[i][47:40], rdata[i][55:48], rdata[i][63:56]};
+    wire [31:0] rev_lo32 = {rdata[i][7:0],   rdata[i][15:8],  rdata[i][23:16], rdata[i][31:24]};
+    wire [63:0] low_perm = swap_mode_i[0] ? {rev_hi32, rev_lo32} : rdata[i][63:0];
+    wire [63:0] rel_hi   = swap_mode_i[1] ? (low_perm ^ wdata_i[127:64]) : low_perm;
+    wire [127:0] wd      = relay_i[i] ? {rel_hi, wdata_i[63:0]} : wdata_i;
+    wire [15:0]  be      = relay_i[i] ? {be_i[15:8] | low_be_perm, be_i[7:0] & be_i[15:8]} : be_i;
 
     bp_sram_256x128 mem (
       .clk_i   ( clk_i     ),
@@ -29,8 +37,5 @@
     );
   end
 
-  assign rdata_o = {
-    rdata[0][127:64] ^ rdata[1][127:64] ^ rdata[2][127:64] ^ rdata[3][127:64],
-    rdata[0][63:0]   ^ rdata[1][63:0]   ^ rdata[2][63:0]
-  };
+  assign rdata_o = rdata[0] ^ rdata[1] ^ rdata[2] ^ rdata[3];
 endmodule

--- a/environment/public/plan/placement.json (Buggy Starter)
+++ b/solution/gold/plan/placement.json (Golden Reference)
@@ -3,57 +3,57 @@
     {
       "bank": 0,
       "half": "low",
-      "x": 70,
-      "y": 100,
-      "orient": "R0"
+      "x": 100,
+      "y": 120,
+      "orient": "MX"
     },
     {
       "bank": 0,
       "half": "high",
-      "x": 1530,
-      "y": 100,
-      "orient": "R0"
+      "x": 1500,
+      "y": 120,
+      "orient": "MX"
     },
     {
       "bank": 1,
       "half": "low",
-      "x": 70,
-      "y": 260,
+      "x": 100,
+      "y": 280,
       "orient": "R0"
     },
     {
       "bank": 1,
       "half": "high",
-      "x": 1530,
-      "y": 260,
+      "x": 1500,
+      "y": 280,
       "orient": "R0"
     },
     {
       "bank": 2,
       "half": "low",
-      "x": 70,
-      "y": 1380,
-      "orient": "R0"
+      "x": 100,
+      "y": 1360,
+      "orient": "MX"
     },
     {
       "bank": 2,
       "half": "high",
-      "x": 1530,
-      "y": 1380,
-      "orient": "R0"
+      "x": 1500,
+      "y": 1360,
+      "orient": "MX"
     },
     {
       "bank": 3,
       "half": "low",
-      "x": 70,
-      "y": 1540,
+      "x": 100,
+      "y": 1520,
       "orient": "R0"
     },
     {
       "bank": 3,
       "half": "high",
-      "x": 1530,
-      "y": 1540,
+      "x": 1500,
+      "y": 1520,
       "orient": "R0"
     }
   ]

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/LICENSE`](environment/public/LICENSE) *(Read-Only Context)*
- [`environment/public/code/banked.sv`](environment/public/code/banked.sv) **(Editable)**
- [`environment/public/code/bp_sram_256x128.sv`](environment/public/code/bp_sram_256x128.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/bp_fe_icache.sv`](environment/public/code/rtl/bp_fe_icache.sv) *(Read-Only Context)*
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
- [`environment/public/physical/flow.tcl.in`](environment/public/physical/flow.tcl.in) *(Read-Only Context)*
- [`environment/public/physical/synth.ys`](environment/public/physical/synth.ys) *(Read-Only Context)*
- [`environment/public/plan/placement.json`](environment/public/plan/placement.json) **(Editable)**

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

