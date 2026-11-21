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
