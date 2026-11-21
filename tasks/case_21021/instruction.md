# case_21021: External-Memory AXI4 Virtual FIFO Write-Commit Ordering, Drain Accounting, and Soft-Flush Recovery

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `alexforencich/verilog-axi` (`repo_40`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/axi_vfifo.v`, `code/axi_vfifo_enc.v`, `code/axi_vfifo_dec.v`, `code/axi_vfifo_raw.v`, `code/axi_vfifo_raw_wr.v`, `code/axi_vfifo_raw_rd.v`

---

## Problem Specification

# External-Memory AXI4 Virtual FIFO Write-Commit Ordering, Drain Accounting, and Soft-Flush Recovery

## Problem Description
In our SmartNIC packet-buffering subsystem (`axi_vfifo` and its encoder, decoder, and raw channel engines), variable-length AXI-Stream frames (`TDATA`, `TKEEP`, `TLAST`, `TID`, `TDEST`, `TUSER`) are segmented, buffered across one or more external DRAM rings over AXI4 master channels (`m_axi_*`), and reconstructed on `m_axis_*`. Integration testing against multi-bank AXI4 memory controllers and ASIC gate-level signoff exposed four protocol and control-plane failures:

1. **AXI4 Write-Commit Visibility & Response FIFO Integrity (`m_axi_*`)**: External memory controllers buffer AXI write bursts until the write-response handshake (`m_axi_bvalid && m_axi_bready`) completes, so any `m_axi_ar*` read issued before write-response commit returns stale DRAM data. In addition, `m_axi_bvalid` asserted while `m_axi_bready` is low, single-cycle `B` responses immediately following short write bursts, or >32 outstanding write bursts under high `B`-channel latency corrupt write-completion pointer tracking and burst-length accounting.
2. **Premature `sts_fifo_empty` & Unknown `sts_fifo_occupancy`**: `sts_fifo_empty` currently reflects only external ring pointers and falsely asserts `1` while packet data is still buffered in the ingress encoder, per-channel write FIFOs (awaiting burst timeout), uncommitted/in-flight AXI bursts, per-channel read/control FIFOs, or egress decoder (`m_axis_tvalid` stalled by `m_axis_tready == 0`). Each channel's `sts_fifo_empty[n]` must assert `1` only when ingress encoding, channel `n` write/DRAM/read pipelines, and egress decoding are completely drained.
3. **Soft `cfg_reset` Pulse & Ring Reconfiguration Across Clock Ratios**: A `cfg_reset` assertion (including a single-`clk`-cycle pulse while `cfg_enable` stays high, across equal or asynchronous `clk`, `s_axis_clk`, `m_axis_clk`, and `m_axi_clk` rates) can be missed or re-enabled before in-flight AXI bursts finish draining. A `cfg_reset` request must reliably force every channel into reset, complete any in-flight AXI4 bursts cleanly without leaking pre-flush fragments onto `m_axis_*`, latch updated `cfg_fifo_base_addr` / `cfg_fifo_size_mask` values, and re-enable streaming only after reset flush completes.
4. **Segment Watermark Flow Control & ASIC Reset Cleanliness**: Under sustained AXI backpressure or compact `WRITE_FIFO_DEPTH` settings (`>= 16`) with multi-segment channels (`CH_SEG_CNT >= 2`, `AXI_CH >= 1`), internal segment flow control must never overflow channel write FIFOs or trigger spurious `sts_hdr_parity_err`. All six modules must synthesize without latches or conflicting drivers and reset deterministically with zero `X`/`Z` outputs when declaration initializers are stripped.

## Boundary Contract
Preserve the exact top-level `axi_vfifo` module name, parameters, and port interface across `code/axi_vfifo*.v`.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Guide

## Workspace Layout
- **Editable RTL**:
  - `code/axi_vfifo.v`
  - `code/axi_vfifo_enc.v`
  - `code/axi_vfifo_dec.v`
  - `code/axi_vfifo_raw.v`
  - `code/axi_vfifo_raw_wr.v`
  - `code/axi_vfifo_raw_rd.v`
- **Read-Only Collateral** (must remain unmodified):
  - `code/COPYING`

## Toolchain Commands
1. **Icarus Verilog Compilation & Simulation**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp <your_tb.sv> \
     code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v \
     code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v
   vvp sim.vvp
   ```

2. **Verilator Lint & Simulation**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --lint-only -Wall -Wno-fatal --top-module axi_vfifo \
     code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v \
     code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v
   ```

3. **Yosys Synthesis, Loop/Latch Check & Initializer-Stripped Gate-Level Netlist**:
   ```bash
   yosys -p "
     read_verilog -defer -sv code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v;
     hierarchy -check -top axi_vfifo -chparam AXI_CH 1 -chparam AXI_DATA_WIDTH 64 -chparam AXI_STRB_WIDTH 8 -chparam AXI_ADDR_WIDTH 10 -chparam LEN_WIDTH 10 -chparam AXIS_DATA_WIDTH 32 -chparam AXIS_KEEP_WIDTH 4 -chparam MAX_SEG_WIDTH 32 -chparam WRITE_FIFO_DEPTH 16 -chparam WRITE_MAX_BURST_LEN 4 -chparam READ_FIFO_DEPTH 32 -chparam READ_MAX_BURST_LEN 4;
     proc; opt_expr; opt_clean; setattr -unset init w:*; flatten; opt_expr; opt_clean;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top axi_vfifo;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v
   "
   ```
   Simulate `netlist.v` with `/opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v` (in grading, `$error(` inside upstream `initial` parameter assertions is sanitized to `$display(` prior to Yosys elaboration).

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axi_vfifo.v`
- `code/axi_vfifo_enc.v`
- `code/axi_vfifo_dec.v`
- `code/axi_vfifo_raw.v`
- `code/axi_vfifo_raw_wr.v`
- `code/axi_vfifo_raw_rd.v`

All other files in the workspace are read-only reference context and must remain unmodified.
