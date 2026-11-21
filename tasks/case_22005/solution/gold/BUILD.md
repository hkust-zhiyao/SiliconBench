# Build & Verification Guide

## Source Layout

All SystemVerilog packages, common-cell modules, headers, and Mask Unit RTL sources reside under `code/`:

- **Editable RTL files**:
  - `code/masku_operands.sv`
  - `code/masku.sv`
- **Read-only packages, headers, and primitives**:
  - `code/config_pkg.sv`
  - `code/cv64a6_imafdcv_sv39_config_pkg.sv`
  - `code/riscv_pkg.sv`
  - `code/cf_math_pkg.sv`
  - `code/axi_pkg.sv`
  - `code/fpnew_pkg.sv`
  - `code/rvv_pkg.sv`
  - `code/ara_pkg.sv`
  - `code/spill_register_flushable.sv`
  - `code/spill_register.sv`
  - `code/delta_counter.sv`
  - `code/lzc.sv`
  - `code/popcount.sv`
  - `code/fifo_v3.sv`
  - `code/include/common_cells/registers.svh`
  - `code/include/common_cells/assertions.svh`
  - `code/include/ara/ara_typedef.svh`

## Compilation Order (Verilator)

To lint or simulate `masku` with your own testbench (`my_tb.sv`) using Verilator (`v5.038+`):

```bash
verilator --binary --timing -O1 -CFLAGS -O0 -Wno-fatal -DSYNTHESIS -j 1 \
  -Icode/include \
  --top-module my_tb \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv \
  code/cf_math_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/delta_counter.sv \
  code/lzc.sv \
  code/popcount.sv \
  code/fifo_v3.sv \
  code/masku_operands.sv \
  code/masku.sv \
  my_tb.sv
```

When instantiating `masku` in a custom testbench or synthesis wrapper with `NrLanes = 4` and `VLEN = 1024`, define `localparam type vlen_t = logic [$clog2(VLEN+1)-1:0];` and `localparam type vaddr_t = logic [9:0];`, then `` `include "ara/ara_typedef.svh" `` inside your wrapper module to obtain `pe_req_t` and `pe_resp_t`.

## Synthesis & Latch Check (`yosys -m slang`)

To verify clean synthesis elaboration, zero combinational loops, and zero inferred latches using Yosys with the `slang` frontend (`my_synth_top.sv` wrapping `masku` for `NrLanes = 4`, `VLEN = 1024`):

```bash
yosys -m slang -p "
  read_slang -DSYNTHESIS --ignore-assertions --unroll-limit 20000 \
    -Icode/include --top my_synth_top \
    code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv \
    code/riscv_pkg.sv \
    code/cf_math_pkg.sv \
    code/axi_pkg.sv \
    code/fpnew_pkg.sv \
    code/rvv_pkg.sv \
    code/ara_pkg.sv \
    code/spill_register_flushable.sv \
    code/spill_register.sv \
    code/delta_counter.sv \
    code/lzc.sv \
    code/popcount.sv \
    code/fifo_v3.sv \
    code/masku_operands.sv \
    code/masku.sv \
    my_synth_top.sv;
  hierarchy -check -top my_synth_top;
  proc; opt_clean; check -assert; stat
"
```
