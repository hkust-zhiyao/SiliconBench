# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/mbx_imbx.sv`
- `code/mbx_ombx.sv`
- `code/mbx_sramrwarb.sv`

All other files in `code/` (`ot_mbx_top.sv`, `mbx_fsm.sv`, `tlul_adapter_host.sv`, `tlul_cmd_intg_gen.sv`, `tlul_rsp_intg_chk.sv`, `tlul_data_integ_enc.sv`, `tlul_data_integ_dec.sv`, `tlul_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_mbx_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_flop_macros.sv \
  code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
  code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv code/prim_count.sv \
  code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
  code/prim_secded_inv_64_57_enc.sv code/prim_secded_inv_64_57_dec.sv \
  code/tlul_pkg.sv code/tlul_data_integ_enc.sv code/tlul_data_integ_dec.sv \
  code/tlul_cmd_intg_gen.sv code/tlul_rsp_intg_chk.sv code/tlul_adapter_host.sv \
  code/mbx_fsm.sv code/mbx_imbx.sv code/mbx_ombx.sv code/mbx_sramrwarb.sv \
  code/ot_mbx_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_mbx_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_mbx_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_flop_macros.sv \
    code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
    code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv code/prim_count.sv \
    code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
    code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
    code/prim_secded_inv_64_57_enc.sv code/prim_secded_inv_64_57_dec.sv \
    code/tlul_pkg.sv code/tlul_data_integ_enc.sv code/tlul_data_integ_dec.sv \
    code/tlul_cmd_intg_gen.sv code/tlul_rsp_intg_chk.sv code/tlul_adapter_host.sv \
    code/mbx_fsm.sv code/mbx_imbx.sv code/mbx_ombx.sv code/mbx_sramrwarb.sv \
    code/ot_mbx_top.sv;
  hierarchy -check -top ot_mbx_top;
  synth -top ot_mbx_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr /tmp/mapped.v
"
```

Target mapped cell area (`Chip area for module '\ot_mbx_top'`): **`<= 1950.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `1.45 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_mbx_top
create_clock -name clk_i -period 1.45 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded -digits 4
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded -digits 4
```

Target worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`): **`>= 0.0 ns`**.
