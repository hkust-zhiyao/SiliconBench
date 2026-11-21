# Build & Verification Guide

## Available Tools

The workspace environment provides the following EDA tools:

- **Verilator v5.038**: `verilator`
- **Yosys (with `slang` SystemVerilog frontend)**: `yosys`

## RTL File Compilation Order

All package headers, common cells, buffers, datapath units, and subsystem RTL reside in `code/` (with macro headers in `code/include/`):

```bash
RTL_FILES=(
  code/fpnew_pkg.sv
  code/cf_math_pkg.sv
  code/hci_package.sv
  code/hwpe_ctrl_package.sv
  code/hwpe_stream_package.sv
  code/redmule_pkg.sv
  code/tc_clk.sv
  code/edge_detect.sv
  code/sync.sv
  code/sync_wedge.sv
  code/lzc.sv
  code/hwpe_stream_fifo.sv
  code/fpnew_classifier.sv
  code/fpnew_rounding.sv
  code/redmule_fma.sv
  code/redmule_row.sv
  code/redmule_engine.sv
  code/x_buffer/redmule_x_pad_scm.sv
  code/x_buffer/redmule_x_buffer_scm.sv
  code/x_buffer/redmule_x_buffer.sv
  code/w_buffer/redmule_w_buffer_scm.sv
  code/w_buffer/redmule_w_buffer.sv
  code/z_buffer/redmule_z_buffer_scm.sv
  code/z_buffer/redmule_z_buffer.sv
  code/redmule_config_fifo.sv
  code/redmule_ctrl.sv
  code/redmule_tiler.sv
  code/redmule_memory_scheduler.sv
  code/redmule_scheduler.sv
  code/redmule_subsys.sv
)
```

## Lint & Simulation with Verilator

To lint the full `redmule_subsys` hierarchy:

```bash
verilator \
  --lint-only -Wno-fatal -Wno-TIMESCALEMOD \
  -Icode/include \
  --top-module redmule_subsys \
  "${RTL_FILES[@]}"
```

To build and run your own SystemVerilog testbench (for example in `/tmp/my_tb.sv`):

```bash
verilator \
  --binary -j 4 -O1 -CFLAGS "-O0" \
  -Wno-fatal -Wno-TIMESCALEMOD \
  -Icode/include \
  --top-module my_tb \
  --Mdir /tmp/obj_dir \
  "${RTL_FILES[@]}" /tmp/my_tb.sv

/tmp/obj_dir/Vmy_tb
```

> **Note**: Keep any scratch testbenches or build directories outside `code/` (or clean them up before finishing); only `code/redmule_tiler.sv`, `code/redmule_scheduler.sv`, and `code/redmule_memory_scheduler.sv` are collected for grading.

## Synthesis & Zero-Latch Elaboration Check (`yosys -m slang`)

Verify that the subsystem elaborates cleanly with zero unintended latches (`$dlatch`):

```bash
yosys -m slang -p "
  read_slang --top redmule_subsys --keep-hierarchy --allow-use-before-declare --ignore-assertions -Wno-range-oob -I code/include ${RTL_FILES[*]};
  hierarchy -check -top redmule_subsys;
  blackbox *tc_clk_gating*;
  proc;
  opt_clean;
  check;
  select -assert-none t:\$dlatch
"
```
