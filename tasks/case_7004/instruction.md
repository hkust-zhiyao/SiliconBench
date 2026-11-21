# case_7004: VeeR EH2 Dual-Thread LSU DCCM, SECDED ECC, Atomic RMW, and Coalescing Store-Buffer Subsystem Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-eh2` (`repo_07`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/eh2_lsu_amo.sv`, `code/eh2_lsu_ecc.sv`, `code/eh2_lsu_dccm_ctl.sv`, `code/eh2_lsu_stbuf.sv`

---

## Problem Specification

# VeeR EH2 Dual-Thread LSU DCCM, SECDED ECC, Atomic RMW, and Coalescing Store-Buffer Subsystem Closure

In the VeeR EH2 dual-thread Load/Store Unit subsystem (`code/eh2_lsu_subsys_top.sv`), regressions across `code/eh2_lsu_amo.sv`, `code/eh2_lsu_ecc.sv`, `code/eh2_lsu_dccm_ctl.sv`, and `code/eh2_lsu_stbuf.sv` cause data corruption and false ECC errors under concurrent pipeline traffic:

1. **Atomic RMW & Store-Conditional (`SC.W`) Datapath**: Signed `AMOMIN.W` and `AMOMAX.W` comparisons produce wrong results on same-sign operands, and `SC.W` transactions fail to route store data on success or preserve ECC-corrected memory data (without upper-channel store-buffer bypass interference) when the reservation check fails.
2. **Sub-Word ECC Merge, Scrubbing & Hazard Qualification**: Odd-offset sub-word stores misalign byte enables during ECC data merge; DC3/DC5 ECC error reporting and scrub writeback mishandle single-bank accesses, faulting accesses, store-buffer RAW forwarding, younger in-flight DMA stores targeting the same word, single-bank scrub port replication, and store-buffer drain bypass into DC2 stores.
3. **Coalescing Store Buffer & Load Forwarding Priority**: DC5 store coalescing and store-buffer draining mishandle draining/DMA-killed entries and unwritten background bytes during partial-word merges, while DC2 load byte forwarding violates youngest-first pipeline priority (`DC3 -> DC4 -> DC5 -> store buffer`).

Update only `code/eh2_lsu_amo.sv`, `code/eh2_lsu_ecc.sv`, `code/eh2_lsu_dccm_ctl.sv`, and `code/eh2_lsu_stbuf.sv`. The subsystem must synthesize without latches under the Yosys/Slang Nangate45 flow (`BUILD.md`) with mapped cell area `<= 17,050.0 um^2`, and meet OpenROAD static timing at a `3.15 ns` clock period on `clk` (`0.15 ns` I/O delays, `5.0 fF` output load) with worst setup slack (`WNS`) `>= 0.00 ns` and worst hold slack (`WHS`) `>= 0.00 ns`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/eh2_lsu_amo.sv`
- `code/eh2_lsu_ecc.sv`
- `code/eh2_lsu_dccm_ctl.sv`
- `code/eh2_lsu_stbuf.sv`

All other files in `code/` (`common_defines.vh`, `eh2_param.vh`, `eh2_pdef.vh`, `eh2_def.sv`, `beh_lib.sv`, `eh2_lib.sv`, `eh2_lsu_subsys_top.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `eh2_lsu_subsys_top` with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -Icode --top-module tb \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
  code/eh2_lsu_amo.sv code/eh2_lsu_ecc.sv code/eh2_lsu_dccm_ctl.sv code/eh2_lsu_stbuf.sv \
  code/eh2_lsu_subsys_top.sv /tmp/tb.sv
./obj_dir/Vtb
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `eh2_lsu_subsys_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top eh2_lsu_subsys_top -Icode \
    code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
    code/eh2_lsu_amo.sv code/eh2_lsu_ecc.sv code/eh2_lsu_dccm_ctl.sv code/eh2_lsu_stbuf.sv \
    code/eh2_lsu_subsys_top.sv;
  hierarchy -check -top eh2_lsu_subsys_top;
  proc; opt_clean;
  chformal -remove;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top eh2_lsu_subsys_top;
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

Target mapped cell area (`Chip area for module '\eh2_lsu_subsys_top'`): **`<= 17050.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `3.15 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_l` and `scan_mode`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design eh2_lsu_subsys_top
create_clock -name clk -period 3.15 [get_ports clk]
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
- `code/eh2_lsu_amo.sv`
- `code/eh2_lsu_ecc.sv`
- `code/eh2_lsu_dccm_ctl.sv`
- `code/eh2_lsu_stbuf.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
