# case_8015: VeeR EL2 Smepmp CSR Lock/WARL Enforcement, TOR/NAPOT Priority Access Checker, and Transparent Sideband Timing Budgets

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-el2` (`repo_08`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library (Shared Base Image)`
> - **Editable Files (`allowed_edits`)**: `code/el2_dec_pmp_ctl.sv`, `code/el2_pmp.sv`, `constraints.json`

---

## Problem Specification

# VeeR EL2 Smepmp CSR Lock/WARL Enforcement, TOR/NAPOT Priority Access Checker, and Transparent Sideband Timing Budgets

In `code/el2_dec_pmp_ctl.sv`, `code/el2_pmp.sv`, and `constraints.json` (integrated in `code/top.sv`), Physical Memory Protection (PMP) CSR lock/WARL rules under Smepmp, multi-channel TOR/NAPOT access checking, and transparent sideband channel timing budgets currently fail verification:

1. **Smepmp CSR Write Gating, WARL Masking, and TOR Neighbor Address Locking (`code/el2_dec_pmp_ctl.sv`)**:
   - **WARL Bit Masking (`pmpcfg`)**: Bits `[6:5]` of every `pmpcfg` byte are reserved and must always be written as `2'b00`. When `mseccfg.MML == 1'b0`, the `(R=0, W=1)` combination is illegal and bit `1` (`W`) must be cleared whenever bit `0` (`R`) is `0`; when `mseccfg.MML == 1'b1`, `(R=0, W=1)` encodings are legal shared-region encodings and must be preserved.
   - **Rule Lock Bypass (`mseccfg.RLB`) and MML Executable Rule Creation Guard**: An entry with `pmpcfg[i].lock == 1'b1` is locked unless `mseccfg.RLB == 1'b1`. Furthermore, when `mseccfg.MML == 1'b1` and `mseccfg.RLB == 1'b0`, writes attempting to add a new executable rule that is either M-mode-only (`L=1` without `R=1, W=1`) or a locked Shared-Region (`L=1, R=0, W=1, X=1`) must be ignored (only writes satisfying `~L | (R & W) | (~W & ~X)` are permitted when `MML=1` and `RLB=0`).
   - **TOR Neighbor `pmpaddr` Lock**: Writing `pmpaddr[i]` must be blocked whenever entry `i` is effectively locked (`pmpcfg[i].lock & ~mseccfg.RLB`) **or** when the immediately following entry `i+1` (`i+1 < pt.PMP_ENTRIES`) is configured in `TOR` mode (`pmpcfg[i+1].mode == TOR`) and is effectively locked (`pmpcfg[i+1].lock & ~mseccfg.RLB`).

2. **Multi-Channel TOR/NAPOT Range Matching, Lowest-Entry Priority, and Smepmp Permission Evaluation (`code/el2_pmp.sv`)**:
   - **TOR and NAPOT Range Matching**: For `TOR` mode on entry `r`, the region start address is `34'h0` for `r == 0` and `{pmp_pmpaddr[r-1], 2'b00}` for `r > 0`, matching `region_start_addr[r] <= req_addr < {pmp_pmpaddr[r], 2'b00}` at word granularity. For `NAPOT` mode, the trailing-ones bitmask on `pmp_pmpaddr[r]` must mask all address bits within the programmed power-of-two granule.
   - **Lowest-Numbered Entry Priority & Default Deny**: Entries `0 .. pt.PMP_ENTRIES-1` are statically prioritized so the lowest-numbered matching entry `r` alone determines whether channel `c` faults (`pmp_chan_err[c] = ~region_perm_check[c][r]`). When no enabled entry matches, access is denied if `mseccfg.MMWP == 1'b1`, or if the effective privilege mode is User mode (`pmp_priv_mode_eff[c] == 1'b1`, where `EXEC` uses `priv_mode_ns` and `READ`/`WRITE` use `priv_mode_eff`), or if `mseccfg.MML == 1'b1` and `pmp_chan_type[c] == EXEC` in Machine mode.
   - **Smepmp (`mseccfg.MML == 1'b1`) Shared-Region & Lock-Inverted Permissions**: When `mseccfg.MML == 1'b1`, `(R=0, W=1)` defines shared regions across `{lock, execute}` (`2'b00`: M-mode R/W, U-mode R; `2'b01`: M/U-mode R/W; `2'b10`: M/U-mode X; `2'b11`: M-mode R/X, U-mode X), `(R=1, W=1, X=1, L=1)` defines a shared read-only region (`READ` only), and all other encodings enforce `permission_check & (priv_mode ? ~lock : lock)`.

3. **Declarative Timing Budgets for Transparent Sideband Channels (`constraints.json`)**:
   - In `code/top.sv`, the subsystem operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `4.5 ns` external input delay on all non-clock inputs and a `3.5 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`fault_in` to `fault_out` and `trace_in` to `trace_out`) even with zero internal delay. Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.25 ns` for `fault_in` to `fault_out` and `2.25 ns` for `trace_in` to `trace_out`, while preserving the existing timing requirements for all registered CSR and PMP ports.

Edit only `code/el2_dec_pmp_ctl.sv`, `code/el2_pmp.sv`, and `constraints.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/el2_dec_pmp_ctl.sv`
- `code/el2_pmp.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/common_defines.vh`, `code/el2_param.vh`, `code/el2_pdef.vh`, `code/el2_def.sv`, `code/beh_lib.sv`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/el2_dec_pmp_ctl.sv`, `code/el2_pmp.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/common_defines.vh code/el2_def.sv code/beh_lib.sv \
  code/el2_dec_pmp_ctl.sv code/el2_pmp.sv \
  code/top.sv /tmp/<your_tb.sv>
/tmp/obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `dec_csr_wen_r_mod`, `dec_csr_wraddr_r`, `dec_csr_wrdata_r`, `dec_csr_rdaddr_d`, `csr_pmpcfg`, `csr_pmpaddr0`, `csr_pmpaddr16`, `csr_pmpaddr32`, `csr_pmpaddr48`, `mseccfg_rlb`, `mseccfg_mmwp`, `mseccfg_mml`, `priv_mode_ns`, `priv_mode_eff`, `pmp_chan_addr_0`, `pmp_chan_addr_1`, `pmp_chan_addr_2`, `pmp_chan_type_0`, `pmp_chan_type_1`, `pmp_chan_type_2`, `fault_in`, and `trace_in` (or bit-indexed `fault_in[0..7]`, `trace_in[0..7]`, etc.).
- Output groups are `dec_pmp_rddata_d`, `dec_pmp_read_d`, `pmp_chan_err_0`, `pmp_chan_err_1`, `pmp_chan_err_2`, `fault_out`, and `trace_out` (or bit-indexed `fault_out[0..7]`, `trace_out[0..7]`, etc.).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.5 ns` input delay on all non-clock inputs (`set_input_delay 4.5 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/el2_dec_pmp_ctl.sv`
- `code/el2_pmp.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
