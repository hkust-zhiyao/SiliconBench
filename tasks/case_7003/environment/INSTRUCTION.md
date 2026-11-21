# case_7003: VeeR EH2 AXI4-to-AHB and AHB-to-AXI4 Bus Bridge Force-Halt Cancellation, Error Drain, and Transparent Channel Timing Budgets

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-eh2` (`repo_07`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library (Shared Base Image)`
> - **Editable Files (`allowed_edits`)**: `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, `constraints.json`

---

## Problem Specification

# VeeR EH2 AXI4-to-AHB and AHB-to-AXI4 Bus Bridge Force-Halt Cancellation, Error Drain, and Transparent Channel Timing Budgets

In `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, and `constraints.json` (integrated in `code/top.sv`), force-halt buffer cancellation, two-cycle AHB error signaling and SLVERR propagation, and transparent sideband channel timing budgets fail verification. In `code/axi4_to_ahb.sv`, asserting `dec_tlu_force_halt` (including when `bus_clk_en` is low) must latch through `force_halt_busff` and clear both the write buffer (`wrbuf_vld`, `wrbuf_data_vld`) and `buf_state` on the active bus clock edge, and any AHB error (`ahb_hresp_q`) in `DATA_RD`, `STREAM_RD`, or `DATA_WR` must record `slvbuf_error` and return `axi_rresp = 2'b10` or `axi_bresp = 2'b10`. In `code/ahb_to_axi4.sv`, any AHB transaction outside DCCM (`[0xf0040000, 0xf005ffff]`) and ICCM (`[0xee000000, 0xee00ffff]`), any ICCM read/write or DCCM write whose size is not 32-bit (`3'h2`) or 64-bit (`3'h3`), any unaligned AHB transfer, or any downstream AXI read error (`|axi_rresp[1:0]` in `PEND`) must assert a two-cycle AHB error response (`ahb_hresp = 1'b1` with `ahb_hreadyout = 1'b0` on the first bus clock cycle and `ahb_hreadyout = 1'b1` on the second) while clearing/blocking `cmdbuf_vld` for errored reads.

In `code/top.sv`, the bridge operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `5.0 ns` external input delay on all non-clock inputs and a `4.0 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit sideband channels (`qos_in` to `qos_out` and `region_in` to `region_out`) even with zero internal delay. Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.75 ns` for `qos_in` to `qos_out` and `2.75 ns` for `region_in` to `region_out`, while preserving the existing timing requirements for all registered bridge ports. Edit only `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, and `constraints.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/common_defines.vh`, `code/eh2_param.vh`, `code/eh2_pdef.vh`, `code/eh2_def.sv`, `code/beh_lib.sv`, `code/eh2_lib.sv`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv \
  code/beh_lib.sv code/eh2_lib.sv \
  code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `rst_ni`, `bus_clk_en`, `dec_tlu_force_halt`, `m_axi_awvalid`, `m_axi_awid`, `m_axi_awaddr`, `m_axi_awsize`, `m_axi_awprot`, `m_axi_wvalid`, `m_axi_wdata`, `m_axi_wstrb`, `m_axi_wlast`, `m_axi_bready`, `m_axi_arvalid`, `m_axi_arid`, `m_axi_araddr`, `m_axi_arsize`, `m_axi_arprot`, `m_axi_rready`, `s_axi_awready`, `s_axi_wready`, `s_axi_bvalid`, `s_axi_bresp`, `s_axi_bid`, `s_axi_arready`, `s_axi_rvalid`, `s_axi_rid`, `s_axi_rdata`, `s_axi_rresp`, `qos_in`, and `region_in` (or bit-indexed `qos_in[0..7]`, `region_in[0..7]`).
- Output groups are `m_axi_awready`, `m_axi_wready`, `m_axi_bvalid`, `m_axi_bresp`, `m_axi_bid`, `m_axi_arready`, `m_axi_rvalid`, `m_axi_rid`, `m_axi_rdata`, `m_axi_rresp`, `m_axi_rlast`, `s_axi_awvalid`, `s_axi_awid`, `s_axi_awaddr`, `s_axi_awsize`, `s_axi_awprot`, `s_axi_awlen`, `s_axi_awburst`, `s_axi_wvalid`, `s_axi_wdata`, `s_axi_wstrb`, `s_axi_wlast`, `s_axi_bready`, `s_axi_arvalid`, `s_axi_arid`, `s_axi_araddr`, `s_axi_arsize`, `s_axi_arprot`, `s_axi_arlen`, `s_axi_arburst`, `s_axi_rready`, `qos_out`, and `region_out` (or bit-indexed `qos_out[0..7]`, `region_out[0..7]`).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `5.0 ns` input delay on all non-clock inputs (`set_input_delay 5.0 -clock clk_i`), and `4.0 ns` output delay on all outputs (`set_output_delay 4.0 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
