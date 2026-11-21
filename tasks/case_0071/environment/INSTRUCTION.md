# case_0071: VeeR EL2 Fetch Controller, Instruction Aligner, and Decode Instruction Buffer Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-el2` (`repo_08`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/el2_ifu_ifc_ctl.sv`, `code/el2_ifu_aln_ctl.sv`, `code/el2_dec_ib_ctl.sv`

---

## Problem Specification

# VeeR EL2 Fetch Controller, Instruction Aligner, and Decode Buffer Closure

In `code/el2_ifu_ib_top.sv`, update only `code/el2_ifu_ifc_ctl.sv`, `code/el2_ifu_aln_ctl.sv`, and `code/el2_dec_ib_ctl.sv` to satisfy all boundary contracts. `el2_ifu_ifc_ctl` must track fetch-buffer occupancy across single-buffer (`ifu_fb_consume1`) and dual-buffer (`ifu_fb_consume2`) consumption, including cycles where two buffers are consumed simultaneously with a hitting fetch (`ifc_fetch_req_f && ic_hit_f`), assert `ifc_fetch_req_bf` whenever a buffer frees, redirect `ifc_fetch_addr_bf` on `exu_flush_final` or predicted taken branches (`ifu_bp_hit_taken_f`), and block fetches on `ic_dma_active`, `dma_iccm_stall_any`, or `ic_write_stall`. `el2_ifu_aln_ctl` must align 16-bit and 32-bit instructions across the three 32-bit buffers, update halfword offsets and `ifu_fb_consume1`/`ifu_fb_consume2` when a 32-bit instruction spans two buffers while `dec_i0_decode_d` is high, hold `ifu_i0_valid`, `dec_i0_instr_d`, and `dec_i0_pc_d` stable while `dec_i0_decode_d` is low or after `ifu_async_error_start` until `exu_flush_final`, and report `dec_i0_icaf_d`, `dec_i0_icaf_second_d`, `dec_i0_icaf_type_d`, and `dec_i0_dbecc_d` across split 32-bit instructions. `el2_dec_ib_ctl` must synthesize halted debug GPR/CSR read/write instructions when `dbg_cmd_valid` is high and `dbg_cmd_type != 2'h2`, asserting `dec_debug_wdata_rs1_d` on writes and `dec_debug_fence_d` on CSR writes to `12'h7c4`.

The RTL must synthesize without latches. Under the Yosys/Slang Nangate45 flow (`BUILD.md`), `el2_ifu_ib_top` must achieve mapped area `<= 5,165.0 um^2`, and OpenROAD STA at a `4.45 ns` clock on `clk` (`0.15 ns` I/O delays, `5.0 fF` load) must achieve worst setup slack (`WNS`) `>= 0.00 ns` and hold slack (`WHS`) `>= 0.00 ns`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/el2_ifu_ifc_ctl.sv`
- `code/el2_ifu_aln_ctl.sv`
- `code/el2_dec_ib_ctl.sv`

All other files in `code/` (`common_defines.vh`, `el2_param.vh`, `el2_pdef.vh`, `el2_def.sv`, `beh_lib.sv`, `el2_lib.sv`, `el2_ifu_compress_ctl.sv`, `el2_ifu_ib_top.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `el2_ifu_ib_top` with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -Icode --top-module tb \
  code/common_defines.vh code/el2_def.sv code/beh_lib.sv code/el2_lib.sv \
  code/el2_ifu_compress_ctl.sv code/el2_ifu_ifc_ctl.sv \
  code/el2_ifu_aln_ctl.sv code/el2_dec_ib_ctl.sv \
  code/el2_ifu_ib_top.sv /tmp/tb.sv
./obj_dir/Vtb
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `el2_ifu_ib_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top el2_ifu_ib_top -Icode \
    code/common_defines.vh code/el2_def.sv code/beh_lib.sv code/el2_lib.sv \
    code/el2_ifu_compress_ctl.sv code/el2_ifu_ifc_ctl.sv \
    code/el2_ifu_aln_ctl.sv code/el2_dec_ib_ctl.sv code/el2_ifu_ib_top.sv;
  hierarchy -check -top el2_ifu_ib_top;
  proc; opt_clean;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top el2_ifu_ib_top;
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

Target mapped cell area (`Chip area for module '\el2_ifu_ib_top'`): **`<= 5165.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `4.45 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_l` and `scan_mode`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design el2_ifu_ib_top
create_clock -name clk -period 4.45 [get_ports clk]
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
- `code/el2_ifu_ifc_ctl.sv`
- `code/el2_ifu_aln_ctl.sv`
- `code/el2_dec_ib_ctl.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
