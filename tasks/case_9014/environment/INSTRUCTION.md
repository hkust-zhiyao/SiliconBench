# case_9014: Co-Design BlackParrot Four-Cluster 128-bit I-Cache SRAM Subword Byte-Reverse/XOR Relay and 8-Macro CTS Floorplan

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `black-parrot/black-parrot` (`repo_09`)
> - **Engineering Problem Type**: `RTL + Hard-SRAM Macro Physical Co-Design` (`PT5_RTL_HardSRAM_Macro_PnR`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/banked.sv`, `plan/placement.json`

---

## Problem Specification

# Co-Design BlackParrot Four-Cluster 128-bit I-Cache SRAM Subword Byte-Reverse/XOR Relay and 8-Macro CTS Floorplan

`code/banked.sv` instantiates four `bp_sram_256x128` (`256x128`, 1-port, `Latency=1`) instruction-cache bank clusters (`cluster[0..3].mem`), each mapped to two `RM_IHPSG13_1P_256x64_c2_bm_bist` cuts (`i_cut_low` for `[63:0]`, `i_cut_high` for `[127:64]`), alongside the BlackParrot front-end instruction cache (`code/rtl/bp_fe_icache.sv`). Repair `code/banked.sv` without extra standard-cell flip-flops or latches (`Sinks 8` and all 256 `i_cut_low/A_DOUT->i_cut_high/A_DIN` paths must remain): lower write data is `wdata_i[63:0]`; when `relay_i[i]=0`, upper write data is `wdata_i[127:64]` and byte enable is `be_i[15:0]`; when `relay_i[i]=1`, reverse the byte order within each 32-bit word of cluster `i`'s lower-cut read data (`{rdata[i][39:32], rdata[i][47:40], rdata[i][55:48], rdata[i][63:56], rdata[i][7:0], rdata[i][15:8], rdata[i][23:16], rdata[i][31:24]}`) when `swap_mode_i[0]=1`, XOR that 64-bit word with `wdata_i[127:64]` when `swap_mode_i[1]=1` for upper write data, drive upper byte enables with `be_i[15:8] | (swap_mode_i[0] ? {be_i[4],be_i[5],be_i[6],be_i[7],be_i[0],be_i[1],be_i[2],be_i[3]} : be_i[7:0])`, and drive lower byte enables with `be_i[7:0] & be_i[15:8]`. `rdata_o` is the 4-cluster 128-bit bitwise XOR.

In `plan/placement.json`, place all 8 macros (`784.48x118.78 um`, `"orient"` in `{"R0","R180","MX","MY"}`, integer `"x"` and `"y"` coordinates in um) inside `x in [65,2335]`, `y in [68,1730]` with `>=20 um` clearance, matching `y` per bank (`x(low)<x(high)`), banks `0,1` in `y in [68,420]` (`y(0)<y(1)`), and banks `2,3` in `y in [1340,1730]` (`y(2)<y(3)`), achieving rise-to-rise `A_CLK` latency spread `<=0.00400 ns`, setup slack `>=2.70 ns`, hold slack `>=0.00 ns`, and Metal2–Metal5 wirelength `<=1,110,000.0 um`. Edit only `code/banked.sv` and `plan/placement.json`.

---

## Build, Simulation, and EDA Verification Instructions

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

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/banked.sv`
- `plan/placement.json`

All other files in the workspace are read-only reference context and must remain unmodified.
