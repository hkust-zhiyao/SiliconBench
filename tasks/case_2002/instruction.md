# case_2002: Ibex TRVK Capability Revocation Bridge Backpressure, Heap-Base Underflow Guard, Flush Recovery, and Transparent Channel Timing Budgets

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/ibex` (`repo_02`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library (Shared Base Image)`
> - **Editable Files (`allowed_edits`)**: `code/ibex_trvk.sv`, `code/stream_fork.sv`, `constraints.json`

---

## Problem Specification

# Ibex TRVK Capability Revocation Bridge Backpressure, Heap-Base Underflow Guard, Flush Recovery, and Transparent Channel Timing Budgets

In `code/ibex_trvk.sv`, `code/stream_fork.sv`, and `constraints.json` (integrated in `code/ibex_trvk_bridge_top.sv`), the CHERIoT temporal capability revocation bridge (`ibex_trvk`) intercepts 32-bit OBI memory transactions, tracks 64-bit capability alignment (`upstream_addr_i[2]`), latches the lower 32-bit capability pointer word (`upstream_addr_i[2] == 1'b0`), reconstructs the 33-bit capability base address on the upper 32-bit metadata word (`upstream_addr_i[2] == 1'b1`), and queries the revocation bitmap memory (`revbm_*`) before returning `upstream_tag_o`. Currently, functional verification, synthesis latch checks, and OpenSTA timing budgets fail:

1. **Synchronous flush recovery in `code/stream_fork.sv`**:
   - Add synchronous clear input `input logic clr_i` to `stream_fork` (wired to `flush_i` in `ibex_trvk.sv`) so that when `clr_i == 1'b1`, any partial split-handshake state (`inp_state_q` and `oup_state_q` across all `N_OUP` outputs) resets to `READY` on the rising edge of `clk_i`, allowing subsequent transactions after a mid-handshake flush to handshake on all outputs cleanly.

2. **Upstream response backpressure, heap-base underflow guard, and synchronous flush in `code/ibex_trvk.sv`**:
   - **Upstream response handshake (`upstream_rvalid_o && upstream_rready_i`)**: An entry in `u_prim_fifo_sync_align` may be popped (`misalign_flag_out_ready = 1'b1`), and `ptr_storage_q` / `ptr_storage_valid_q` may be updated, **only** when the upstream response actually handshakes (`upstream_rvalid_o && upstream_rready_i`). While `upstream_rvalid_o == 1'b1` and `upstream_rready_i == 1'b0`, `misalign_flag_out`, `ptr_storage_q`, `ptr_storage_valid_q`, and all upstream response outputs must remain stable.
   - **Unsigned heap-base underflow guard and 33-bit top bit check**: A capability is eligible for a revocation bitmap lookup (`revbm_req_required == 1'b1`) only when its reconstructed 33-bit base `cap_base_33` satisfies `!cap_base_33[32]`, `cap_base_33[31:0] >= heap_base_addr_i`, and `|(revbm_bit_addr[31:RevBitmapWordAddrWidth+$clog2(32)]) == 1'b0`. Capabilities with `cap_base_33[32] == 1'b1` or `cap_base_33[31:0] < heap_base_addr_i` are outside the revocable heap range and must not trigger a bitmap lookup (`revbm_req_required = 1'b0`, preserving `downstream_rsp_out.tag` on `upstream_tag_o`).
   - **Bitmap request stability under `upstream_rready_i == 1'b0`**: Once `revbm_req_o && revbm_gnt_i` has handshaked for the current second capability word, if `revbm_rvalid_i` arrives while `upstream_rready_i == 1'b0`, `ibex_trvk` must not issue a duplicate `revbm_req_o` for the same capability word before the upstream response handshakes (`upstream_rvalid_o && upstream_rready_i`).
   - **Synchronous `flush_i` recovery**: When `flush_i == 1'b1`, `ibex_trvk` must synchronously clear `u_prim_fifo_sync_align`, `u_prim_fifo_ds_rsp_store`, `ptr_storage_valid_q`, and `revbm_outstanding_q`, and suppress `upstream_rvalid_o`, `downstream_req_o`, `upstream_gnt_o`, and `revbm_req_o` during the flush cycle.

3. **Declarative timing budgets for transparent channels (`constraints.json`)**:
   - In `code/ibex_trvk_bridge_top.sv`, the bridge operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `4.0 ns` external input delay on all non-clock inputs and a `3.5 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`alert_in` to `alert_out` and `trace_in` to `trace_out`) even with zero internal delay. Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.5 ns` for `alert_in` to `alert_out` and `2.5 ns` for `trace_in` to `trace_out`, while preserving the existing timing requirements for all other ports.

Edit only `code/ibex_trvk.sv`, `code/stream_fork.sv`, and `constraints.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/ibex_trvk.sv`
- `code/stream_fork.sv`
- `constraints.json`

All other files in `code/` (`code/ibex_trvk_bridge_top.sv`, `code/ibex_cheriot_pkg.sv`, `code/stream_join_dynamic.sv`, `code/prim_*`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/ibex_trvk_bridge_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -DSYNTHESIS -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_secded_pkg.sv code/ibex_cheriot_pkg.sv code/prim_flop_macros.sv \
  code/prim_count.sv code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_secded_inv_39_32_dec.sv code/stream_fork.sv \
  code/stream_join_dynamic.sv code/ibex_trvk.sv \
  code/ibex_trvk_bridge_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `flush_i`, `heap_base_addr_i`, `upstream_req_i`, `upstream_rready_i`, `upstream_we_i`, `upstream_be_i`, `upstream_addr_i`, `upstream_wdata_i`, `upstream_wdata_intg_i`, `upstream_tag_i`, `downstream_gnt_i`, `downstream_rvalid_i`, `downstream_rdata_i`, `downstream_rdata_intg_i`, `downstream_err_i`, `downstream_tag_i`, `revbm_gnt_i`, `revbm_rvalid_i`, `revbm_rdata_i`, `revbm_rdata_intg_i`, `revbm_err_i`, `alert_in`, and `trace_in` (or bit-indexed `alert_in[0..7]`, `trace_in[0..7]`).
- Output groups are `upstream_gnt_o`, `upstream_rvalid_o`, `upstream_rdata_o`, `upstream_rdata_intg_o`, `upstream_err_o`, `upstream_tag_o`, `downstream_req_o`, `downstream_we_o`, `downstream_be_o`, `downstream_addr_o`, `downstream_wdata_o`, `downstream_wdata_intg_o`, `downstream_tag_o`, `revbm_req_o`, `revbm_addr_o`, `revbm_data_intg_error_o`, `revbm_device_error_o`, `alert_out`, and `trace_out` (or bit-indexed `alert_out[0..7]`, `trace_out[0..7]`).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.0 ns` input delay on all non-clock inputs (`set_input_delay 4.0 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ibex_trvk.sv`
- `code/stream_fork.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
