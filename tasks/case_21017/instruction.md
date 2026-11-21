# case_21017: Multi-Region Overlapping Aperture Decode, Coupled Write Arbitration, and Gate-Level Zero-X Parity in AXI4-Lite Crossbar

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `alexforencich/verilog-axi` (`repo_40`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/axil_crossbar.v`, `code/axil_crossbar_addr.v`, `code/axil_crossbar_wr.v`, `code/axil_crossbar_rd.v`

---

## Problem Specification

# Multi-Region Overlapping Aperture Decode, Coupled Write Arbitration, and Gate-Level Zero-X Parity in AXI4-Lite Crossbar

`axil_crossbar` (`code/axil_crossbar.v`) and its submodules `axil_crossbar_addr` (`code/axil_crossbar_addr.v`), `axil_crossbar_wr` (`code/axil_crossbar_wr.v`), and `axil_crossbar_rd` (`code/axil_crossbar_rd.v`) interconnect `S_COUNT` AXI4-Lite slave interfaces (`s_axil_*`, connected to upstream masters) with `M_COUNT` AXI4-Lite master interfaces (`m_axil_*`, connected to downstream peripherals), using read-only `code/arbiter.v`, `code/priority_encoder.v`, `code/axil_register_wr.v`, and `code/axil_register_rd.v`. Currently, the subsystem aborts or misroutes hierarchical overlapping address apertures, overflows 32-bit shifts on full-range apertures (`M_ADDR_WIDTH == ADDR_WIDTH`) and wide connectivity matrices (`S_COUNT * M_COUNT > 32`), drops top-level master register-slice parameters, fails elaboration/synthesis on `S_COUNT == 1` or `M_COUNT == 1`, stalls downstream targets when `AW` arrives without `W`, and leaks `X` onto handshake signals in initializer-stripped gate-level simulation.

Update `code/axil_crossbar.v`, `code/axil_crossbar_addr.v`, `code/axil_crossbar_wr.v`, and `code/axil_crossbar_rd.v` while preserving `axil_crossbar`'s module name, parameters, and port declarations (internal `axil_crossbar_addr`/`wr`/`rd` index widths may be guarded for `S_COUNT == 1` or `M_COUNT == 1`):

1. **Hierarchical Overlapping Aperture Decode, Wide `M_CONNECT` & Security Window Isolation (`axil_crossbar_addr`)**:
   - Support `M_REGIONS >= 1` with overlapping address apertures (removing the elaboration overlap abort while retaining alignment/range checks) and full-width apertures up to `M_ADDR_WIDTH == ADDR_WIDTH` (e.g., `32` on a `32`-bit bus); regions with `M_ADDR_WIDTH == 0` remain inactive.
   - Across all active regions `(i, j)` (`0 <= i < M_COUNT`, `0 <= j < M_REGIONS`) where `M_CONNECT[i*S_COUNT + S] == 1'b1` (supporting `S_COUNT * M_COUNT > 32` without 32-bit shift truncation) and `s_axil_aaddr` falls within region `(i, j)`, select the winning target by **longest-prefix match** (smallest matching `M_ADDR_WIDTH`; break ties in favor of higher master index `i`, then higher region index `j`).
   - Enforce security isolation **after** winning aperture selection: if no connected region matches, or if the winning aperture belongs to a secure master (`M_SECURE[i] == 1'b1`) and the transaction is non-secure (`s_axil_aprot[1] == 1'b1`), complete the transaction internally with `DECERR` (`2'b11`, returning `RDATA = 0` on reads and absorbing the `W` beat on writes without asserting downstream `m_axil_awvalid`/`m_axil_wvalid`/`m_axil_arvalid`), never falling through to a wider non-secure fallback aperture.

2. **Top-Level Slice Parameter Forwarding, `1xM` / `Sx1` Support & Deadlock-Free Write Arbitration (`axil_crossbar`, `axil_crossbar_wr`, `axil_crossbar_rd`)**:
   - Forward `M_AW_REG_TYPE`, `M_W_REG_TYPE`, `M_B_REG_TYPE`, `M_AR_REG_TYPE`, and `M_R_REG_TYPE` from `axil_crossbar` to `axil_crossbar_wr` and `axil_crossbar_rd`, and support all `S_COUNT >= 1`, `M_COUNT >= 1` geometries (including `S_COUNT == 1` and `M_COUNT == 1`) without negative/zero-width vectors or out-of-bounds indexing.
   - In `axil_crossbar_wr`, prevent a master that presents `AW` many cycles ahead of `W` (or `W` ahead of `AW`) from locking a shared downstream peripheral and blocking ready `AW+W` writers, and ensure coupled zero-slice (`M_AW_REG_TYPE = 0, M_W_REG_TYPE = 0`) downstream slaves that wait for simultaneous `m_axil_awvalid && m_axil_wvalid` complete without deadlock.

3. **Synthesis Cleanliness & Initializer-Stripped ASIC Gate-Level Zero-X Parity**:
   - Synthesize cleanly in Yosys with zero inferred latches, zero combinational loops, and strictly one-hot/zero downstream `m_axil_*valid` / `*ready` strobes per transaction.
   - Synchronously reset all control/FIFO-status/drop/select state on `rst` and guard empty response-routing FIFO outputs so 4-state RTL (`iverilog`, `verilator`) and initializer-stripped gate-level simulation exhibit zero `X`/`Z` on all `s_axil_*` and `m_axil_*` handshake/response signals after synchronous `rst` and produce identical transaction results.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Guide

## Workspace Layout
- **Editable RTL**:
  - `code/axil_crossbar.v`
  - `code/axil_crossbar_addr.v`
  - `code/axil_crossbar_wr.v`
  - `code/axil_crossbar_rd.v`
- **Read-Only Collateral** (must remain unmodified):
  - `code/arbiter.v`
  - `code/priority_encoder.v`
  - `code/axil_register_wr.v`
  - `code/axil_register_rd.v`
  - `code/COPYING`

## Toolchain Commands
1. **Icarus Verilog Compilation & Simulation**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp <your_tb.sv> \
     code/priority_encoder.v code/arbiter.v \
     code/axil_register_wr.v code/axil_register_rd.v \
     code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v
   vvp sim.vvp
   ```

2. **Verilator Lint & Simulation**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --lint-only -Wall -Wno-fatal --top-module axil_crossbar \
     code/priority_encoder.v code/arbiter.v \
     code/axil_register_wr.v code/axil_register_rd.v \
     code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v
   ```

3. **Yosys Synthesis, Loop/Latch Check & Initializer-Stripped Gate-Level Netlist**:
   ```bash
   yosys -p "
     read_verilog code/priority_encoder.v code/arbiter.v code/axil_register_wr.v code/axil_register_rd.v code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v;
     hierarchy -check -top axil_crossbar;
     proc; setattr -unset init w:*; flatten;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top axil_crossbar;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v
   "
   ```
   Simulate `netlist.v` with `/opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v`.

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add new simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axil_crossbar.v`
- `code/axil_crossbar_addr.v`
- `code/axil_crossbar_wr.v`
- `code/axil_crossbar_rd.v`

All other files in the workspace are read-only reference context and must remain unmodified.
