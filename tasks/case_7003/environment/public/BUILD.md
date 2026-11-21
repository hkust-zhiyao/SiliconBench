# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/common_defines.vh`, `code/eh2_param.vh`, `code/eh2_pdef.vh`, `code/eh2_def.sv`, `code/beh_lib.sv`, `code/eh2_lib.sv`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv \
  code/beh_lib.sv code/eh2_lib.sv \
  code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `rst_ni`, `bus_clk_en`, `dec_tlu_force_halt`, `m_axi_awvalid`, `m_axi_awid`, `m_axi_awaddr`, `m_axi_awsize`, `m_axi_awprot`, `m_axi_wvalid`, `m_axi_wdata`, `m_axi_wstrb`, `m_axi_wlast`, `m_axi_bready`, `m_axi_arvalid`, `m_axi_arid`, `m_axi_araddr`, `m_axi_arsize`, `m_axi_arprot`, `m_axi_rready`, `s_axi_awready`, `s_axi_wready`, `s_axi_bvalid`, `s_axi_bresp`, `s_axi_bid`, `s_axi_arready`, `s_axi_rvalid`, `s_axi_rid`, `s_axi_rdata`, `s_axi_rresp`, `qos_in`, and `region_in` (or bit-indexed `qos_in[0..7]`, `region_in[0..7]`).
- Output groups are `m_axi_awready`, `m_axi_wready`, `m_axi_bvalid`, `m_axi_bresp`, `m_axi_bid`, `m_axi_arready`, `m_axi_rvalid`, `m_axi_rid`, `m_axi_rdata`, `m_axi_rresp`, `m_axi_rlast`, `s_axi_awvalid`, `s_axi_awid`, `s_axi_awaddr`, `s_axi_awsize`, `s_axi_awprot`, `s_axi_awlen`, `s_axi_awburst`, `s_axi_wvalid`, `s_axi_wdata`, `s_axi_wstrb`, `s_axi_wlast`, `s_axi_bready`, `s_axi_arvalid`, `s_axi_arid`, `s_axi_araddr`, `s_axi_arsize`, `s_axi_arprot`, `s_axi_arlen`, `s_axi_arburst`, `s_axi_rready`, `qos_out`, and `region_out` (or bit-indexed `qos_out[0..7]`, `region_out[0..7]`).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `5.0 ns` input delay on all non-clock inputs (`set_input_delay 5.0 -clock clk_i`), and `4.0 ns` output delay on all outputs (`set_output_delay 4.0 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.
