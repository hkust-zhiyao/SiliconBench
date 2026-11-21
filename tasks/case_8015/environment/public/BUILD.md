# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/el2_dec_pmp_ctl.sv`
- `code/el2_pmp.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/common_defines.vh`, `code/el2_param.vh`, `code/el2_pdef.vh`, `code/el2_def.sv`, `code/beh_lib.sv`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/el2_dec_pmp_ctl.sv`, `code/el2_pmp.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/common_defines.vh code/el2_def.sv code/beh_lib.sv \
  code/el2_dec_pmp_ctl.sv code/el2_pmp.sv \
  code/top.sv /tmp/<your_tb.sv>
/tmp/obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `dec_csr_wen_r_mod`, `dec_csr_wraddr_r`, `dec_csr_wrdata_r`, `dec_csr_rdaddr_d`, `csr_pmpcfg`, `csr_pmpaddr0`, `csr_pmpaddr16`, `csr_pmpaddr32`, `csr_pmpaddr48`, `mseccfg_rlb`, `mseccfg_mmwp`, `mseccfg_mml`, `priv_mode_ns`, `priv_mode_eff`, `pmp_chan_addr_0`, `pmp_chan_addr_1`, `pmp_chan_addr_2`, `pmp_chan_type_0`, `pmp_chan_type_1`, `pmp_chan_type_2`, `fault_in`, and `trace_in` (or bit-indexed `fault_in[0..7]`, `trace_in[0..7]`, etc.).
- Output groups are `dec_pmp_rddata_d`, `dec_pmp_read_d`, `pmp_chan_err_0`, `pmp_chan_err_1`, `pmp_chan_err_2`, `fault_out`, and `trace_out` (or bit-indexed `fault_out[0..7]`, `trace_out[0..7]`, etc.).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.5 ns` input delay on all non-clock inputs (`set_input_delay 4.5 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.
