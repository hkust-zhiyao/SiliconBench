# Build & Elaboration Guide

## Toolchain Paths
- **Verilator**: `verilator`
- **Yosys (+ slang)**: `yosys`

## Editable RTL
- `code/ara_sequencer.sv`
- `code/ara_dispatcher.sv`

## Compile Order (`-Icode/include`)
```bash
RTL_SRCS=(
  code/config_pkg.sv
  code/cv64a6_imafdcv_sv39_config_pkg.sv
  code/build_config_pkg.sv
  code/riscv_pkg.sv
  code/cf_math_pkg.sv
  code/axi_pkg.sv
  code/fpnew_pkg.sv
  code/rvv_pkg.sv
  code/ara_pkg.sv
  code/onehot_to_bin.sv
  code/lzc.sv
  code/popcount.sv
  code/counter.sv
  code/delta_counter.sv
  code/fall_through_register.sv
  code/spill_register_flushable.sv
  code/spill_register.sv
  code/stream_register.sv
  code/fifo_v3.sv
  code/rr_arb_tree.sv
  code/stream_arbiter_flushable.sv
  code/stream_arbiter.sv
  code/stream_demux.sv
  code/stream_mux.sv
  code/stream_xbar.sv
  code/axi_cut.sv
  code/segment_sequencer.sv
  code/ara_dispatcher.sv
  code/ara_sequencer.sv
  code/lane/lane_sequencer.sv
  code/lane/operand_requester.sv
)
```

### Verilator Lint / Elaboration Check
```bash
verilator \
  --lint-only -Wno-fatal -Wno-ENUMVALUE -DSYNTHESIS -Icode/include --top-module ara_sequencer "${RTL_SRCS[@]}"
```
