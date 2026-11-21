# case_0103: Coupled WB2AXIP Outstanding Credit Tracking, Wishbone Error Abort Drain, and Nangate45 Area/Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `zipcpu/wb2axip` (`repo_43`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/wbm2axisp.v`, `code/aximwr2wbsp.v`, `code/aximrd2wbsp.v`

---

## Problem Specification

In `code/wb2axip_bridge_top.v`, the editable Wishbone-to-AXI4 bridge (`code/wbm2axisp.v`) and AXI4-to-Wishbone write/read burst bridges (`code/aximwr2wbsp.v` and `code/aximrd2wbsp.v`) fail on outstanding credit accounting, Wishbone abort/error draining, AXI ID ordering, and Nangate45 area/timing closure. Repair `code/wbm2axisp.v` so it tracks up to `1 << LGFIFO` in-flight Wishbone requests without direction-switch races, shifts 32-bit read data and write strobes according to sub-word address offset, and enters a flush state upon any AXI error response (`i_axi_rresp[1]` or `i_axi_bresp[1]`, emitting a single `o_wb_err` pulse) or premature `i_wb_cyc` drop while transactions are in flight—suppressing `o_wb_ack`/`o_wb_err` and stalling new Wishbone requests until all outstanding AXI responses have drained.

Repair `code/aximwr2wbsp.v` and `code/aximrd2wbsp.v` so each bridge enforces single-ID in-flight ordering (stalling a new AXI burst whose `AWID`/`ARID` differs from an active in-flight ID until all prior Wishbone acknowledgments complete) and cleanly handles a downstream Wishbone bus error (`i_wb_err` while `o_wb_cyc` is high): immediately drop `o_wb_cyc` and `o_wb_stb`, drain any remaining beats of the faulted write burst or synthesize the remaining beats of the faulted read burst with `S_AXI_RRESP = 2'b10` and `S_AXI_RLAST` on the final beat, and return `S_AXI_BRESP = 2'b10` for the faulted write burst before accepting new bursts. Share the active transaction ID across in-flight beats so that under `flow/synth.ys` and `flow/timing.tcl` (`10.0 ns` `i_clk`, `6.0 ns` input delay on `wb_dn_ack`, `wb_dn_err`, `wb_dn_stall`), `wb2axip_bridge_top` achieves mapped Nangate45 cell area `<= 6,750.0 um^2`, worst setup slack `>= 2.48 ns`, and worst hold slack `>= 0.00 ns`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Static Timing Verification

## 1. Editable vs. Read-Only Files

Editable files (only these files are collected and graded):
- `code/wbm2axisp.v`
- `code/aximwr2wbsp.v`
- `code/aximrd2wbsp.v`

Read-only files (must remain unmodified):
- `code/skidbuffer.v`
- `code/sfifo.v`
- `code/axi_addr.v`
- `code/wbarbiter.v`
- `code/axim2wbsp.v`
- `code/wb2axip_bridge_top.v`
- `code/LICENSE`
- `lib/NangateOpenCellLibrary_typical.lib`
- `lib/LICENSE.Nangate45`
- `flow/synth.ys`
- `flow/timing.tcl`

Keep the module names and port interfaces of `wbm2axisp`, `aximwr2wbsp`, `aximrd2wbsp`, and `wb2axip_bridge_top` unchanged. All editable RTL must be pure synthesizable Verilog-2001 without simulation system tasks, delays, `initial` blocks, `force`/`release`/`bind`, synthesis/simulation conditional compilation macros, or hierarchical testbench references.

## 2. Functional Simulation (`verilator`)

You can compile and simulate `wb2axip_bridge_top` with your own testbench using Verilator:

```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  code/skidbuffer.v \
  code/sfifo.v \
  code/axi_addr.v \
  code/wbarbiter.v \
  code/axim2wbsp.v \
  code/wbm2axisp.v \
  code/aximwr2wbsp.v \
  code/aximrd2wbsp.v \
  code/wb2axip_bridge_top.v \
  tb.sv
./obj_dir/Vtb
```

Functional verification checks:
1. `wbm2axisp`: pipelined 32-bit Wishbone reads and writes mapped onto 64-bit AXI4 (`OPT_LITTLE_ENDIAN = 1`), sub-word write strobe shifting (`o_axi_wstrb`) and read data lane extraction (`o_wb_data`), read/write direction locking while `npending > 0`, and full flush recovery on AXI `SLVERR` (`i_axi_rresp[1]` / `i_axi_bresp[1]`) or mid-flight `i_wb_cyc` drop (suppressing `o_wb_ack`/`o_wb_err` and holding `o_wb_stall = 1` until all in-flight AXI responses have returned).
2. `aximwr2wbsp`: multi-beat AXI4 `INCR` write bursts converted to pipelined Wishbone writes, blocking new bursts with a different `S_AXI_AWID` while `acks_expected > 0`, and Wishbone error (`i_wb_err`) abort handling (dropping `o_wb_cyc`/`o_wb_stb`, draining remaining `W` beats of the faulted burst, and returning `S_AXI_BRESP = 2'b10` with the matching `S_AXI_BID`).
3. `aximrd2wbsp`: multi-beat AXI4 `INCR` read bursts converted to pipelined Wishbone reads, blocking new bursts with a different `S_AXI_ARID` while transactions are in flight (`!wb_empty`), and Wishbone error (`i_wb_err`) abort handling (immediately dropping `o_wb_cyc`/`o_wb_stb` and returning `S_AXI_RRESP = 2'b10` for all remaining beats of the burst through `S_AXI_RLAST = 1` with the matching `S_AXI_RID`).

## 3. Yosys Nangate45 Synthesis & Area Check

Run Yosys using `flow/synth.ys`:

```bash
yosys -Q -T -s flow/synth.ys
```

From `stat -liberty lib/NangateOpenCellLibrary_typical.lib`, verify:
- `Chip area for module '\wb2axip_bridge_top': <= 6750.0` (`um^2`).

## 4. OpenSTA Timing Closure Check

Run OpenSTA on the synthesized `mapped.v` using `flow/timing.tcl`:

```bash
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -exit flow/timing.tcl
```

Verify that:
- `check_setup -verbose` reports no unconstrained endpoints or clock errors.
- Worst setup slack (`-path_delay max`) is `>= 2.48 ns` (`MET`).
- Worst hold slack (`-path_delay min`) is `>= 0.00 ns` (`MET`).

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/wbm2axisp.v`
- `code/aximwr2wbsp.v`
- `code/aximrd2wbsp.v`

All other files in the workspace are read-only reference context and must remain unmodified.
