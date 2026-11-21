The TDMA transmit scheduler RTL in `code/` derives from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause-Views).

Editable files:
- `code/tdma_scheduler.v`
- `code/tx_scheduler_ctrl_tdma.v`
- `code/tx_scheduler_rr.v`

Read-only files:
- `code/axis_fifo.v`
- `code/priority_encoder.v`
- `code/LICENSE`
- `pdk/NangateOpenCellLibrary_typical.lib`

Editable RTL must remain pure synthesizable HDL compatible with both Icarus Verilog and Verilator across parameterized `PORTS` / `INDEX_WIDTH` instantiations (do not add simulation-control or file-I/O system tasks such as `$finish`, `$stop`, `$fatal`, or `$readmem*`, and do not use simulator/synthesis macro divergence).

Local compilation, Verilator lint, Yosys Nangate45 synthesis, and OpenSTA `2.00` ns timing check from the workspace root:
```bash
# 1. Icarus Verilog & Verilator compilation/elaboration checks
iverilog -g2012 -o /tmp/tdma_chk.vvp \
  code/tdma_scheduler.v code/tx_scheduler_ctrl_tdma.v code/tx_scheduler_rr.v code/axis_fifo.v code/priority_encoder.v
verilator --lint-only -Wno-fatal --top-module tx_scheduler_ctrl_tdma code/tx_scheduler_ctrl_tdma.v
verilator --lint-only -Wno-fatal -GQUEUE_INDEX_WIDTH=4 --top-module tx_scheduler_ctrl_tdma code/tx_scheduler_ctrl_tdma.v

# 2. Yosys Nangate45 synthesis & area report on tdma_scheduler
yosys -p "
  read_verilog code/tdma_scheduler.v;
  hierarchy -check -top tdma_scheduler -chparam INDEX_WIDTH 8;
  synth -flatten -top tdma_scheduler;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean -purge;
  stat -liberty pdk/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -simple-lhs /tmp/tdma_sched_net.v
"

# 3. OpenSTA 2.00 ns timing verification on tdma_scheduler
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -no_init -exit <<'EOF'
read_liberty pdk/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/tdma_sched_net.v
link_design tdma_scheduler
create_clock -name clk -period 2.00 [get_ports clk]
set_false_path -from [get_ports rst]
foreach p [get_ports *] {
    set n [get_name $p]
    if {$n != "clk" && $n != "rst"} {
        if {[get_property $p direction] == "input"} { set_input_delay 0.10 -clock clk $p } else { set_output_delay 0.10 -clock clk $p }
    }
}
report_tns
report_wns
report_checks -path_delay min_max
EOF
```
