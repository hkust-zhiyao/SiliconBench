# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/stream_to_mem.sv`
- `code/cv32e40p_obi_interface.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/stream_fifo.sv`, `code/fifo_v3.sv`, `code/spill_register.sv`, `code/include/common_cells/registers.svh`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/stream_to_mem.sv`, `code/cv32e40p_obi_interface.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode/include \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/fifo_v3.sv code/stream_fifo.sv code/spill_register.sv \
  code/stream_to_mem.sv code/cv32e40p_obi_interface.sv \
  code/top.sv /tmp/<your_tb.sv>
/tmp/obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `flush_i`, `req_addr`, `req_we`, `req_be`, `req_wdata`, `req_atop`, `req_valid`, `resp_ready`, `obi_gnt`, `obi_rdata`, `obi_rvalid`, `obi_err`, `pmp_in`, and `dbg_in` (or bit-indexed `pmp_in[0..7]`, `dbg_in[0..7]`, etc.).
- Output groups are `req_ready`, `resp_rdata`, `resp_err`, `resp_valid`, `obi_req`, `obi_addr`, `obi_we`, `obi_be`, `obi_wdata`, `obi_atop`, `pmp_out`, and `dbg_out` (or bit-indexed `pmp_out[0..7]`, `dbg_out[0..7]`, etc.).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.0 ns` input delay on all non-clock inputs (`set_input_delay 4.0 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.
