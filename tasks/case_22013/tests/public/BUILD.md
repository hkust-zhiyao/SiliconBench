# Build and Verification Guide

## Editable Files

Only the following RTL files are collected for grading:

- `code/vlsu.sv`
- `code/addrgen.sv`
- `code/vldu.sv`
- `code/vstu.sv`

All supporting packages and primitives in `code/` (`ara_pkg.sv`, `rvv_pkg.sv`, `axi_pkg.sv`, `axi_cut.sv`, `fifo_v3.sv`, `spill_register*.sv`, `stream_*.sv`, and `code/include/...`) are read-only reference dependencies.

## Available Toolchain

- **Verilator 5.038**: `verilator`
- **Yosys + slang**: `yosys` (`-m slang`)

## Compilation Order (`Verilator` & `yosys -m slang`)

Compile packages prior to RTL modules with `-Icode/include`:

```bash
verilator \
  --lint-only -Wno-fatal -DSYNTHESIS -Icode/include \
  code/cf_math_pkg.sv \
  code/riscv_pkg.sv \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/build_config_pkg.sv \
  code/lzc.sv \
  code/onehot_to_bin.sv \
  code/rr_arb_tree.sv \
  code/fifo_v3.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/fall_through_register.sv \
  code/stream_arbiter_flushable.sv \
  code/stream_arbiter.sv \
  code/stream_mux.sv \
  code/stream_demux.sv \
  code/stream_xbar.sv \
  code/counter.sv \
  code/delta_counter.sv \
  code/axi_cut.sv \
  code/addrgen.sv \
  code/vldu.sv \
  code/vstu.sv \
  code/vlsu.sv \
  --top-module vlsu
```

To check synthesis elaboration and verify zero inferred latches with `yosys -m slang` (instantiating `vlsu` with concrete `AxiAddrWidth = 64`, `AxiDataWidth = 128` or `64`, `NrLanes = 4`, `VLEN = 4096`):

```bash
yosys -m slang -p "
  read_slang --top <your_vlsu_wrapper> --ignore-assertions --ignore-timing --ignore-initial \
    -I code/include \
    code/cf_math_pkg.sv code/riscv_pkg.sv code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
    code/rvv_pkg.sv code/ara_pkg.sv code/build_config_pkg.sv \
    code/lzc.sv code/onehot_to_bin.sv code/rr_arb_tree.sv code/fifo_v3.sv \
    code/spill_register_flushable.sv code/spill_register.sv code/fall_through_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_mux.sv \
    code/stream_demux.sv code/stream_xbar.sv code/counter.sv code/delta_counter.sv \
    code/axi_cut.sv code/addrgen.sv code/vldu.sv code/vstu.sv code/vlsu.sv <your_vlsu_wrapper.sv>;
  hierarchy -check -top <your_vlsu_wrapper>;
  proc; opt_expr; opt_clean; check -assert; stat
"
```
