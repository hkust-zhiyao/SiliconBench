# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following four files are collected and graded:
- `code/ibex_icache.sv`
- `code/ibex_if_stage.sv`
- `code/ibex_compressed_decoder.sv`
- `constraints.json`

All other files in `code/` and `lib/` (`code/ibex_icache_if_subsys_top.sv`, `code/ibex_pkg.sv`, `code/ibex_cheriot_pkg.sv`, `code/ibex_fetch_fifo.sv`, `code/ibex_prefetch_buffer.sv`, `code/ibex_dummy_instr.sv`, `code/ibex_branch_predict.sv`, `code/prim_*`, `code/dv_fcov_macros.svh`, `lib/*`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/ibex_icache_if_subsys_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Werror-LATCH -Wno-fatal -DSYNTHESIS -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/prim_util_pkg.sv code/prim_cipher_pkg.sv code/prim_secded_pkg.sv \
  code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
  code/prim_buf.sv code/prim_lfsr.sv \
  code/prim_secded_inv_28_22_dec.sv code/prim_secded_inv_28_22_enc.sv \
  code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
  code/ibex_fetch_fifo.sv code/ibex_prefetch_buffer.sv code/ibex_icache.sv \
  code/ibex_dummy_instr.sv code/ibex_branch_predict.sv \
  code/ibex_compressed_decoder.sv code/ibex_if_stage.sv \
  code/ibex_icache_if_subsys_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names:
- Input groups include `scr_mon_in` (or `scr_mon_in[0..7]`), `pmp_mon_in` (or `pmp_mon_in[0..7]`), and the functional inputs of `ibex_icache_if_subsys_top`.
- Output groups include `scr_mon_out` (or `scr_mon_out[0..7]`), `pmp_mon_out` (or `pmp_mon_out[0..7]`), and the functional outputs of `ibex_icache_if_subsys_top`.
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10.0 ns` or `12.0 ns` on `clk_i`), `3.5 ns` input delay on all non-clock inputs (`set_input_delay 3.5 -clock clk_i`), and `3.0 ns` output delay on all outputs (`set_output_delay 3.0 -clock clk_i`), using `lib/NangateOpenCellLibrary_typical.lib` and OpenROAD/OpenSTA. Zero latches are allowed.
