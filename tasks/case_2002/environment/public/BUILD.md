# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/ibex_trvk.sv`
- `code/stream_fork.sv`
- `constraints.json`

All other files in `code/` (`code/ibex_trvk_bridge_top.sv`, `code/ibex_cheriot_pkg.sv`, `code/stream_join_dynamic.sv`, `code/prim_*`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/ibex_trvk_bridge_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -DSYNTHESIS -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_secded_pkg.sv code/ibex_cheriot_pkg.sv code/prim_flop_macros.sv \
  code/prim_count.sv code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_secded_inv_39_32_dec.sv code/stream_fork.sv \
  code/stream_join_dynamic.sv code/ibex_trvk.sv \
  code/ibex_trvk_bridge_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `flush_i`, `heap_base_addr_i`, `upstream_req_i`, `upstream_rready_i`, `upstream_we_i`, `upstream_be_i`, `upstream_addr_i`, `upstream_wdata_i`, `upstream_wdata_intg_i`, `upstream_tag_i`, `downstream_gnt_i`, `downstream_rvalid_i`, `downstream_rdata_i`, `downstream_rdata_intg_i`, `downstream_err_i`, `downstream_tag_i`, `revbm_gnt_i`, `revbm_rvalid_i`, `revbm_rdata_i`, `revbm_rdata_intg_i`, `revbm_err_i`, `alert_in`, and `trace_in` (or bit-indexed `alert_in[0..7]`, `trace_in[0..7]`).
- Output groups are `upstream_gnt_o`, `upstream_rvalid_o`, `upstream_rdata_o`, `upstream_rdata_intg_o`, `upstream_err_o`, `upstream_tag_o`, `downstream_req_o`, `downstream_we_o`, `downstream_be_o`, `downstream_addr_o`, `downstream_wdata_o`, `downstream_wdata_intg_o`, `downstream_tag_o`, `revbm_req_o`, `revbm_addr_o`, `revbm_data_intg_error_o`, `revbm_device_error_o`, `alert_out`, and `trace_out` (or bit-indexed `alert_out[0..7]`, `trace_out[0..7]`).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.0 ns` input delay on all non-clock inputs (`set_input_delay 4.0 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.
