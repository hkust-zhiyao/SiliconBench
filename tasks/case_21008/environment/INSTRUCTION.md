# case_21008: Parameterized AXI4 Width Adapter Multi-Ratio Burst Repacking, Splitting, and Synthesis Parity

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `alexforencich/verilog-axi` (`repo_40`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/axi_adapter.v`, `code/axi_adapter_rd.v`, `code/axi_adapter_wr.v`

---

## Problem Specification

# Parameterized AXI4 Width Adapter Multi-Ratio Burst Repacking, Splitting, and Synthesis Parity

`axi_adapter` (`axi_adapter_rd` and `axi_adapter_wr`) bridges an `S_DATA_WIDTH`-bit AXI4 slave interface to an `M_DATA_WIDTH`-bit AXI4 master interface across equal-width (`S_DATA_WIDTH == M_DATA_WIDTH`), upsize (`S_DATA_WIDTH < M_DATA_WIDTH`), and downsize (`S_DATA_WIDTH > M_DATA_WIDTH`) datapaths. Across multi-ratio instantiations (`32 <-> 128`, `64 <-> 256`, `64 <-> 64`), narrow/unaligned bursts, `FIXED`/`INCR`/`WRAP` burst types, and post-synthesis gate-level verification, the adapter exhibits elaboration width errors, malformed master burst headers, premature `WLAST`/`RLAST` framing, and sub-word lane corruption:

1. **Multi-Parameter Elaboration & RTL/Gate-Level Synthesis Parity (`axi_adapter`, `axi_adapter_rd`, `axi_adapter_wr`)**:
   - All `generate` branches (`S_DATA_WIDTH == M_DATA_WIDTH`, upsize, and downsize) must elaborate and synthesize cleanly without undeclared/zero-multiplier replications, out-of-bounds part-selects, width-truncation bugs, inferred latches, or combinational loops across arbitrary power-of-two width ratios, `FORWARD_ID` in `{0, 1}`, `CONVERT_BURST` in `{0, 1}`, `CONVERT_NARROW_BURST` in `{0, 1}`, and multi-bit `*USER_WIDTH >= 1` with `*USER_ENABLE` in `{0, 1}` (driving full-width zeros on disabled user ports and on `m_axi_awid`/`m_axi_arid` when `FORWARD_ID == 0`).

2. **AXI4 `FIXED`, `INCR`, and `WRAP` Slave Address Stepping & Byte-Lane Steering**:
   - Slave beat addresses must follow AXI4 rules across full-size, narrow (`size < $clog2(S_STRB_WIDTH)`), and unaligned start addresses: `FIXED` (`2'b00`) repeats the original start address on every beat, `INCR` (`2'b01`) advances to `(cur_addr + (1 << size)) & ~((1 << size) - 1)`, and `WRAP` (`2'b10`, `len` in `{1, 3, 7, 15}`) wraps within its `((len + 1) << size)` byte boundary, steering `WDATA`/`WSTRB` and `RDATA` to/from the addressed byte and sub-word lanes.

3. **Upsize Wide Burst Repacking vs. Narrow Passthrough (`S_DATA_WIDTH < M_DATA_WIDTH`)**:
   - Convert a slave request into a full-width (`M_BURST_SIZE = $clog2(M_STRB_WIDTH)`) master `INCR` (`2'b01`) burst aligned to `s_axi_a*addr & ~((1 << M_BURST_SIZE) - 1)` if and only if `CONVERT_BURST != 0`, `s_axi_a*cache[1] == 1'b1` (modifiable), `CONVERT_NARROW_BURST != 0 || s_axi_a*size == $clog2(S_STRB_WIDTH)`, and the slave burst is either `INCR` (`2'b01`) or a `WRAP` (`2'b10`) burst that starts on its wrap boundary or fits within a single master word (`m_axi_a*len = 0`). Otherwise, forward `addr`, `len`, `size`, and `burst` unchanged and steer each slave beat individually.
   - During repacked transfers, set `m_axi_a*len` to the exact number of master words spanned minus one, merge sub-word writes (`WDATA`/`WSTRB`) across master word boundaries without asserting `m_axi_wlast` before the final wide beat, and unpack each wide read beat across all covered slave beats before accepting the next master beat.

4. **Downsize Child Burst Splitting & Sticky Response Aggregation (`S_DATA_WIDTH > M_DATA_WIDTH`)**:
   - Pass narrow slave bursts with `s_axi_a*size <= $clog2(M_STRB_WIDTH)` through as a single master burst preserving `addr`, `len`, `size`, and `burst`.
   - Split wide slave bursts (`s_axi_a*size > $clog2(M_STRB_WIDTH)`) into full-width (`M_BURST_SIZE`) master `INCR` (`2'b01`) child bursts accounting for unaligned start offsets: issue one child burst per slave beat for `FIXED` (`2'b00`), split at any `WRAP` (`2'b10`) wrap boundary so master `INCR` bursts never cross it, and split long bursts so no child `m_axi_a*len` exceeds `8'hFF`.
   - Propagate the highest-severity response (`2'b11 > 2'b10 > 2'b01 > 2'b00`) across all master sub-beats forming a slave `R` beat (`s_axi_rresp`) and across all child `B` responses of a split write (`s_axi_bresp`, latching `s_axi_buser` from the first child response and updating it whenever a strictly higher-severity `m_axi_bresp` arrives), with cycle-accurate parity between RTL simulation and synthesized gate-level netlist simulation.

---

## Build, Simulation, and EDA Verification Instructions

The parameterized AXI4 width adapter RTL in `code/` comes from `alexforencich/verilog-axi` commit `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` (`code/COPYING`, MIT License).

Editable files:
- `code/axi_adapter.v`
- `code/axi_adapter_rd.v`
- `code/axi_adapter_wr.v`

Read-only support files (must remain unmodified):
- `code/COPYING`

For quick local multi-parameter elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/adap_chk.vvp code/*.v

# Verilator lint/elaboration check (upsize & downsize)
verilator --lint-only -Wno-fatal -GS_DATA_WIDTH=32 -GM_DATA_WIDTH=128 -GFORWARD_ID=1 -GCONVERT_NARROW_BURST=1 --top-module axi_adapter code/*.v
verilator --lint-only -Wno-fatal -GS_DATA_WIDTH=128 -GM_DATA_WIDTH=32 -GFORWARD_ID=1 --top-module axi_adapter code/*.v

# Yosys elaboration and latch-free synthesis check
yosys -p "read_verilog code/*.v; chparam -set S_DATA_WIDTH 64 -set M_DATA_WIDTH 256 -set FORWARD_ID 1 -set CONVERT_NARROW_BURST 1 axi_adapter; hierarchy -check -top axi_adapter; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axi_adapter.v`
- `code/axi_adapter_rd.v`
- `code/axi_adapter_wr.v`

All other files in the workspace are read-only reference context and must remain unmodified.
