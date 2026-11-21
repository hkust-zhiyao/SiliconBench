# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following four files are collected and graded:
- `code/el2_lsu_lsc_ctl.sv`
- `code/el2_lsu_addrcheck.sv`
- `code/el2_lsu_trigger.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/common_defines.vh`, `code/el2_param.vh`, `code/el2_pdef.vh`, `code/el2_def.sv`, `code/beh_lib.sv`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/el2_lsu_addrcheck.sv`, `code/el2_lsu_lsc_ctl.sv`, `code/el2_lsu_trigger.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/common_defines.vh code/el2_def.sv code/beh_lib.sv \
  code/el2_lsu_addrcheck.sv code/el2_lsu_lsc_ctl.sv code/el2_lsu_trigger.sv \
  code/top.sv /tmp/<your_tb.sv>
/tmp/obj_dir/V<your_tb>
```

## 3. Synthesis, Area Budget, and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
Synthesizing `top` with Yosys/Slang and Nangate45 typical Liberty must be latch-free and achieve mapped cell area `<= 3,850.0 um^2`.

The STA flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `rst_ni`, `clk_override`, `lsu_ld_data_r`, `lsu_ld_data_corr_r`, `lsu_single_ecc_error_r`, `lsu_double_ecc_error_r`, `lsu_ld_data_m`, `lsu_single_ecc_error_m`, `lsu_double_ecc_error_m`, `flush_m_up`, `flush_r`, `exu_lsu_rs1_d`, `exu_lsu_rs2_d`, `lsu_pkt_bits`, `dec_lsu_valid_raw_d`, `dec_lsu_offset_d`, `picm_mask_data_m`, `bus_read_data_m`, `dec_tlu_mrac_ff`, `dma_dccm_req`, `dma_mem_addr`, `dma_mem_sz`, `dma_mem_write`, `dma_mem_wdata`, `lsu_pmp_error_start`, `lsu_pmp_error_end`, `trigger_pkt_0`, `trigger_pkt_1`, `trigger_pkt_2`, `trigger_pkt_3`, `pmu_in`, and `fir_in` (or bit-indexed `pmu_in[0..7]`, `fir_in[0..7]`, etc.).
- Output groups are `lsu_result_m`, `lsu_result_corr_r`, `lsu_addr_d`, `lsu_addr_m`, `lsu_addr_r`, `end_addr_d`, `end_addr_m`, `end_addr_r`, `store_data_m`, `lsu_exc_m`, `is_sideeffects_m`, `lsu_commit_r`, `lsu_single_ecc_error_incr`, `lsu_error_pkt_r_bits`, `lsu_fir_addr`, `lsu_fir_error`, `addr_in_dccm_d`, `addr_in_dccm_m`, `addr_in_dccm_r`, `addr_in_pic_d`, `addr_in_pic_m`, `addr_in_pic_r`, `addr_external_m`, `lsu_trigger_match_m`, `pmu_out`, and `fir_out` (or bit-indexed `pmu_out[0..7]`, `fir_out[0..7]`, etc.).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.5 ns` input delay on all non-clock inputs (`set_input_delay 4.5 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.
