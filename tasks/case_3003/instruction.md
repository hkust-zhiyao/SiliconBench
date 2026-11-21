# case_3003: CV32E40P Stream-to-OBI Bridge Flush Drain, Registered Address-Phase Stability, and Transparent Channel Timing Budgets

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cv32e40p` (`repo_03`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library (Shared Base Image)`
> - **Editable Files (`allowed_edits`)**: `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, `constraints.json`

---

## Problem Specification

# CV32E40P Stream-to-OBI Bridge Flush Drain, Registered Address-Phase Stability, and Transparent Channel Timing Budgets

In `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, and `constraints.json` (integrated in `code/top.sv` with `code/stream_fifo.sv`, `code/fifo_v3.sv`, and `code/spill_register.sv`), synchronous flush draining, non-granted OBI address-phase stability, error forwarding, and transparent status channel timing budgets fail verification. In `stream_to_mem`, asserting `flush_i` must immediately deassert `req_ready_o`, `mem_req_valid_o`, and `resp_valid_o` for that cycle, flush any buffered responses in `i_resp_buf`, and discard any responses returning from already-accepted in-flight memory requests (`mem_resp_valid_i` on or after the `flush_i` edge) so stale responses never reach `resp_valid_o`/`resp_o` while reclaiming their outstanding buffer credits (`cnt_q`) as they drain. In `cv32e40p_obi_interface` (`TRANS_STABLE = 0`), when an OBI request is not immediately granted (`obi_req_o && !obi_gnt_i`), all address-phase outputs (`obi_addr_o`, `obi_we_o`, `obi_be_o`, `obi_wdata_o`, `obi_atop_o`) must remain stable in the `REGISTERED` state until `obi_gnt_i` asserts, and `obi_err_i` must be forwarded on `resp_err_o`.

In `code/top.sv`, the bridge operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `4.0 ns` external input delay on all non-clock inputs and a `3.5 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`pmp_in` to `pmp_out` and `dbg_in` to `dbg_out`) even with zero internal delay. Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.25 ns` for `pmp_in` to `pmp_out` and `2.25 ns` for `dbg_in` to `dbg_out`, while preserving the existing timing requirements for all registered stream and OBI ports (`flush_i`, `req_addr`, `req_we`, `req_be`, `req_wdata`, `req_atop`, `req_valid`, `resp_ready`, `obi_gnt`, `obi_rdata`, `obi_rvalid`, `obi_err`, `req_ready`, `resp_rdata`, `resp_err`, `resp_valid`, `obi_req`, `obi_addr`, `obi_we`, `obi_be`, `obi_wdata`, `obi_atop`). Edit only `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, and `constraints.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/stream_to_mem.sv`
- `code/cv32e40p_obi_interface.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/stream_fifo.sv`, `code/fifo_v3.sv`, `code/spill_register.sv`, `code/include/common_cells/registers.svh`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode/include \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/fifo_v3.sv code/stream_fifo.sv code/spill_register.sv \
  code/stream_to_mem.sv code/cv32e40p_obi_interface.sv \
  code/top.sv /tmp/<your_tb.sv>
/tmp/obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `flush_i`, `req_addr`, `req_we`, `req_be`, `req_wdata`, `req_atop`, `req_valid`, `resp_ready`, `obi_gnt`, `obi_rdata`, `obi_rvalid`, `obi_err`, `pmp_in`, and `dbg_in` (or bit-indexed `pmp_in[0..7]`, `dbg_in[0..7]`, etc.).
- Output groups are `req_ready`, `resp_rdata`, `resp_err`, `resp_valid`, `obi_req`, `obi_addr`, `obi_we`, `obi_be`, `obi_wdata`, `obi_atop`, `pmp_out`, and `dbg_out` (or bit-indexed `pmp_out[0..7]`, `dbg_out[0..7]`, etc.).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.0 ns` input delay on all non-clock inputs (`set_input_delay 4.0 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/stream_to_mem.sv`
- `code/cv32e40p_obi_interface.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
