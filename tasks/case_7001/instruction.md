# case_7001: VeeR EH2 Dual-Issue Fetch Controller, 4-Beat Instruction Aligner, and 4-Entry Decode Instruction Buffer Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-eh2` (`repo_07`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/eh2_ifu_ifc_ctl.sv`, `code/eh2_ifu_aln_ctl.sv`, `code/eh2_dec_ib_ctl.sv`

---

## Problem Specification

# VeeR EH2 Dual-Issue Fetch Controller, 4-Beat Instruction Aligner, and 4-Entry Decode Instruction Buffer Closure

In `code/eh2_ifu_ib_top.sv`, update only `code/eh2_ifu_ifc_ctl.sv`, `code/eh2_ifu_aln_ctl.sv`, and `code/eh2_dec_ib_ctl.sv` to satisfy all boundary contracts. `eh2_ifu_ifc_ctl` must track 4-beat fetch-buffer occupancy across single-buffer (`ifu_fb_consume1`) and dual-buffer (`ifu_fb_consume2`) consumption, including cycles where two buffers are consumed simultaneously with a winning fetch (`fetch_req_f1_won & ~miss_f2`), allow `fetch_req_f1` and clear `pmu_fetch_stall` when `fb_full_f1` is high and at least one buffer is being consumed (`ifu_fb_consume1 | ifu_fb_consume2`), redirect `fetch_addr_bf` on `exu_flush_final` or predicted taken branches (`ifu_bp_kill_next_f2`), and block fetches on `ic_dma_active`, `dma_iccm_stall_any`, or `ic_write_stall`. `eh2_ifu_aln_ctl` must align up to two 16-bit/32-bit instructions (`i0`, `i1`) per cycle across the four 64-bit fetch buffers, update `f1_shift_2B`, `f1_shift_4B`, `f1_shift_6B`, halfword queue offsets, and `fb_consume1`/`fb_consume2` across 2B/4B/6B/8B alignment shifts, suppress `i1_valid` when `i1` has an access fault (`i1_icaf`) or double-bit ECC error (`i1_dbecc`), latch `error_stall` on `ifu_async_error_start` until `exu_flush_final`, and report `i0_icaf`, `i0_icaf_second`, `i0_icaf_type`, and `i0_dbecc` across split 32-bit instructions. `eh2_dec_ib_ctl` must maintain the 4-entry instruction buffer (`ib0..ib3`) across 0/1/2-instruction decode shifts, roll back `ib0..ib3`, `bp0..bp3`, and `ibval` from `ibsave`/`bpsave` when `dec_i1_cancel_e1` asserts, and synthesize halted debug GPR/CSR read/write instructions when `dbg_cmd_valid` is high and `dbg_cmd_type != 2'h2`, asserting `debug_wdata_rs1_d` on writes and `debug_fence_d` on CSR writes to `12'h7c4`.

The RTL must synthesize without latches. Under the Yosys/Slang Nangate45 flow (`BUILD.md`), `eh2_ifu_ib_top` must achieve mapped area `<= 20,250.0 um^2`, and OpenROAD STA at a `9.25 ns` clock on `clk` (`0.15 ns` I/O delays, `5.0 fF` load) must achieve worst setup slack (`WNS`) `>= 0.00 ns` and hold slack (`WHS`) `>= 0.00 ns`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/eh2_ifu_ifc_ctl.sv`
- `code/eh2_ifu_aln_ctl.sv`
- `code/eh2_dec_ib_ctl.sv`

All other files in `code/` (`common_defines.vh`, `eh2_param.vh`, `eh2_pdef.vh`, `eh2_def.sv`, `beh_lib.sv`, `eh2_lib.sv`, `eh2_ifu_compress_ctl.sv`, `eh2_ifu_ib_top.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `eh2_ifu_ib_top` with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -Icode --top-module tb \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
  code/eh2_ifu_compress_ctl.sv code/eh2_ifu_ifc_ctl.sv \
  code/eh2_ifu_aln_ctl.sv code/eh2_dec_ib_ctl.sv \
  code/eh2_ifu_ib_top.sv /tmp/tb.sv
./obj_dir/Vtb
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `eh2_ifu_ib_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top eh2_ifu_ib_top -Icode \
    code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
    code/eh2_ifu_compress_ctl.sv code/eh2_ifu_ifc_ctl.sv \
    code/eh2_ifu_aln_ctl.sv code/eh2_dec_ib_ctl.sv code/eh2_ifu_ib_top.sv;
  hierarchy -check -top eh2_ifu_ib_top;
  proc; opt_clean;
  chformal -remove;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top eh2_ifu_ib_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr /tmp/mapped.v
"
```

Target mapped cell area (`Chip area for module '\eh2_ifu_ib_top'`): **`<= 20250.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `9.25 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_l` and `scan_mode`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design eh2_ifu_ib_top
create_clock -name clk -period 9.25 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports {rst_l scan_mode}]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```

Target worst setup slack (`WNS`) and worst hold slack (`WHS`): **`>= 0.00 ns`**.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/eh2_ifu_ifc_ctl.sv`
- `code/eh2_ifu_aln_ctl.sv`
- `code/eh2_dec_ib_ctl.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
