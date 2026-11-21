# case_2003: Ibex Load-Store Unit, Writeback Stage, and Smepmp Memory Protection Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/ibex` (`repo_02`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/ibex_load_store_unit.sv`, `code/ibex_wb_stage.sv`, `code/ibex_pmp.sv`

---

## Problem Specification

# Ibex Load-Store Unit, Writeback Stage, and Smepmp Memory Protection Closure

In the Ibex memory-access and writeback subsystem (`code/ibex_lsu_wb_pmp_top.sv`, integrating `code/ibex_load_store_unit.sv`, `code/ibex_wb_stage.sv`, and `code/ibex_pmp.sv`), several coupled functional failures and synthesis/timing bottlenecks currently prevent signoff:

1. **Smepmp (`mseccfg.mml` / `mseccfg.mmwp`), TOR Range Matching, and Debug-Mode Access Control (`code/ibex_pmp.sv`)**:
   - Under Smepmp (`csr_pmp_mseccfg_i.mml == 1'b1`), shared regions (`read == 0, write == 1`) with `{lock, exec} == 2'b00` erroneously permit writes in S/U privilege modes instead of restricting write access to M-mode (`PRIV_LVL_M`), non-shared locked regions fail to enforce the `lock` bit requirement in M-mode, and unmatched instruction fetches (`PMP_ACC_EXEC`) in M-mode fail to default-deny when `mml` is active.
   - Top-of-Range (`PMP_MODE_TOR`) region matching both mishandles inverted bounds (`csr_pmp_addr_i[r] < region_start_addr[r]`) and introduces excessive arithmetic carry chains on the address-to-LSU critical path. All PMP modes (`OFF`, `TOR`, `NA4`, `NAPOT`), static region priority (`0` highest), `mmwp` default-deny, and Debug-Module bypass (`debug_mode_i` within `[DmBaseAddr, DmBaseAddr | DmAddrMask]`) must operate accurately across both channels.

2. **Split Misaligned Fault-Address Reporting and CHERIoT 64-bit Capability Transfers (`code/ibex_load_store_unit.sv`)**:
   - When a misaligned word (`lsu_type_i == 2'b00`, non-zero byte offset) or word-straddling halfword (`lsu_type_i == 2'b01`, byte offset `2'b11`) splits across two word-aligned OBI beats, `addr_last_o` is overwritten with the second beat's aligned address even when the first beat faulted (`data_bus_err_i` or `data_pmp_err_i`). `addr_last_o` must retain the initial unaligned address whenever the first beat faults, and update to the second word-aligned address only when the first beat succeeds.
   - For CHERIoT 64-bit capability loads (`cheriot_enable_i == IbexMuBiOn` and `lsu_is_cap_i == 1'b1`), a bus error on the first beat or a 39-bit SECDED integrity error on the second beat fails to invalidate the returned capability (`lsu_rcap_o`). Any bus error, PMP fault, CHERIoT request error, or SECDED integrity fault across the capability transfer must suppress `lsu_rdata_valid_o` and drive `lsu_rcap_o = NULL_CAP`.

3. **Writeback Stage Completion, Retirement Accounting, and PPA/STA Closure (`code/ibex_wb_stage.sv`, `code/ibex_load_store_unit.sv`, `code/ibex_pmp.sv`)**:
   - In `code/ibex_wb_stage.sv` (`WritebackStage == 1`), CHERIoT capability loads and stores (`instr_is_cheriot_i` with `cheriot_load_i` or `cheriot_store_i`) complete prematurely in a single cycle without waiting for `lsu_resp_valid_o`, and `perf_instr_ret_wb_o` erroneously counts instructions that terminate with an LSU error (`load_err_o`, `store_err_o`, `load_resp_intg_err_o`, or `store_resp_intg_err_o`).
   - Remove redundant datapath and state overhead across `code/ibex_load_store_unit.sv`, `code/ibex_wb_stage.sv`, and `code/ibex_pmp.sv` so that `ibex_lsu_wb_pmp_top` synthesizes without latches under the supplied Nangate45 flow (`BUILD.md`) with mapped cell area `<= 5,750.0 um^2`, and achieves worst setup slack (`WNS`) `>= 0.00 ns` and worst hold slack (`WHS`) `>= 0.00 ns` at a `2.05 ns` clock period on `clk_i` (`0.15 ns` I/O delays, `5.0 fF` output load).

Edit only `code/ibex_load_store_unit.sv`, `code/ibex_wb_stage.sv`, and `code/ibex_pmp.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and STA Guide

## 1. Editable Files
Only the following three RTL files are collected and graded:
- `code/ibex_load_store_unit.sv`
- `code/ibex_wb_stage.sv`
- `code/ibex_pmp.sv`

All other files in `code/` and `lib/` (`code/ibex_lsu_wb_pmp_top.sv`, `code/ibex_pkg.sv`, `code/ibex_cheriot_pkg.sv`, `code/prim_*`, `code/dv_fcov_macros.svh`, `lib/*`) are read-only and must remain unmodified.

## 2. Behavioral Simulation (`Verilator`)
Compile and simulate `code/ibex_lsu_wb_pmp_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module <your_tb> --Mdir obj \
  code/prim_util_pkg.sv code/prim_secded_pkg.sv \
  code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
  code/prim_buf.sv code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
  code/ibex_pmp.sv code/ibex_load_store_unit.sv code/ibex_wb_stage.sv \
  code/ibex_lsu_wb_pmp_top.sv <your_tb.sv>
./obj/V<your_tb>
```

## 3. Logic Synthesis & Area Evaluation (`Yosys + Slang`, `Nangate45`)
Synthesize `ibex_lsu_wb_pmp_top` to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
yosys \
  -m slang -Q -T -p "
    read_slang --top ibex_lsu_wb_pmp_top -Icode -DSYNTHESIS \
      code/prim_util_pkg.sv code/prim_secded_pkg.sv \
      code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
      code/prim_buf.sv code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
      code/ibex_pmp.sv code/ibex_load_store_unit.sv code/ibex_wb_stage.sv \
      code/ibex_lsu_wb_pmp_top.sv;
    hierarchy -check -top ibex_lsu_wb_pmp_top;
    proc; opt_clean;
    select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
    synth -top ibex_lsu_wb_pmp_top;
    opt;
    dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
    abc -liberty lib/NangateOpenCellLibrary_typical.lib;
    clean;
    read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
    check -assert;
    stat -liberty lib/NangateOpenCellLibrary_typical.lib;
    write_verilog -noattr mapped.v
  "
```
- **Latch Check**: Zero latches allowed.
- **Mapped Cell Area Target**: `Chip area for module '\ibex_lsu_wb_pmp_top'` must be `<= 5,750.0 um^2`.

## 4. Static Timing Analysis (`OpenROAD / OpenSTA`)
Evaluate setup and hold slack on `mapped.v` under a `2.05 ns` clock on `clk_i`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog mapped.v
link_design ibex_lsu_wb_pmp_top
create_clock -name clk_i -period 2.05 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
- **Timing Targets**: `WNS >= 0.00 ns` and `WHS >= 0.00 ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ibex_load_store_unit.sv`
- `code/ibex_wb_stage.sv`
- `code/ibex_pmp.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
