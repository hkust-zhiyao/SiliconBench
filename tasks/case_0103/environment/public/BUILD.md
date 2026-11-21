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
