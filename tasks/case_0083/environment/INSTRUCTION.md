# case_0083: iDMA ND-Midend Zero-Transfer Rejection, Legalizer Page-Boundary Splitting, and Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/idma` (`repo_23`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/idma_nd_midend.sv`, `code/idma_legalizer_page_splitter.sv`, `code/idma_legalizer.sv`

---

## Problem Specification

# iDMA ND-Midend Zero-Transfer Rejection, Legalizer Page-Boundary Splitting, and Timing Closure

In the iDMA multi-dimensional transfer and burst legalization subsystem (`code/idma_nd_legalizer_top.sv`), repair `code/idma_nd_midend.sv`, `code/idma_legalizer_page_splitter.sv`, and `code/idma_legalizer.sv`. In `code/idma_nd_midend.sv`, expand multi-dimensional transfers across outer repetition counts (`req_reps_i`) and strides (`req_src_strides_i`, `req_dst_strides_i`, `req_scale_strides_i`), marking only the final 1D burst with `burst_req_o.opt.last == 1'b1` and asserting `nd_rsp_valid_o` on normal transfers only when `burst_rsp_valid_i && burst_rsp_i.last`; when all outer repetition counts are zero (`req_reps_i == '0`), suppress `burst_req_valid_o`, deassert `burst_rsp_ready_o`, and complete on `nd_rsp_valid_o && nd_rsp_ready_i` with `nd_rsp_o.error == 1'b1` and `nd_rsp_o.pld.err_type == idma_pkg::ND_MIDEND`.

In `code/idma_legalizer_page_splitter.sv` and `code/idma_legalizer.sv`, compute the remaining bytes to the active virtual page boundary (`OffsetWidth` when `not_bursting_i`, otherwise `min(12, OffsetWidth + (reduce_len_i ? max_llen_i : BurstLen))`), splitting coupled transfers (`!req_decouple_rw_i`) at the closer of the source and destination page boundaries with lockstep `r_ready_i && w_ready_i` handshaking and splitting decoupled transfers (`req_decouple_rw_i`) independently per channel, while honoring `flush_i` pause and `kill_i` abort semantics. Under the Nangate45 synthesis and OpenROAD STA flow in `BUILD.md` (`idma_nd_legalizer_top`, `2.70 ns` clock on `clk_i`, `0.15 ns` I/O delays, `5.0 fF` load), achieve mapped area `<= 3680.0 um^2` and setup/hold slack `>= 0.0 ns`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/idma_nd_midend.sv`
- `code/idma_legalizer_page_splitter.sv`
- `code/idma_legalizer.sv`

All other files in `code/` (`idma_nd_legalizer_top.sv`, `idma_pkg.sv`, `axi_pkg.sv`, `cc_pkg.sv`, `cc_popcount.sv`, `include/*`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `idma_nd_legalizer_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Wno-fatal -Icode/include -DSYNTHESIS \
  --top-module tb \
  code/cc_pkg.sv code/axi_pkg.sv code/idma_pkg.sv code/cc_popcount.sv \
  code/idma_legalizer_page_splitter.sv code/idma_legalizer.sv \
  code/idma_nd_midend.sv code/idma_nd_legalizer_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `idma_nd_legalizer_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --top idma_nd_legalizer_top -Icode/include -DSYNTHESIS \
    code/cc_pkg.sv code/axi_pkg.sv code/idma_pkg.sv code/cc_popcount.sv \
    code/idma_legalizer_page_splitter.sv code/idma_legalizer.sv \
    code/idma_nd_midend.sv code/idma_nd_legalizer_top.sv;
  hierarchy -check -top idma_nd_legalizer_top;
  synth -top idma_nd_legalizer_top;
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

Target mapped cell area (`Chip area for module '\idma_nd_legalizer_top'`): **`<= 3680.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.70 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design idma_nd_legalizer_top
create_clock -name clk_i -period 2.70 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded -digits 4
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded -digits 4
```

Target worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`): **`>= 0.0 ns`**.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/idma_nd_midend.sv`
- `code/idma_legalizer_page_splitter.sv`
- `code/idma_legalizer.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
