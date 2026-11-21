The checksum offload RTL in `code/` derives from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause-Views).

Editable files:
- `code/tx_checksum.v`
- `code/rx_checksum.v`

Read-only files:
- `code/axis_fifo.v`
- `code/LICENSE`
- `pdk/NangateOpenCellLibrary_typical.lib`

Editable RTL must remain pure synthesizable HDL (do not add simulation-control or file-I/O system tasks such as `$finish`, `$stop`, `$fatal`, or `$readmem*`, and do not use simulator/synthesis macro divergence).

Local compilation, Yosys Nangate45 synthesis, and OpenSTA timing/area check from the workspace root:
```bash
# 1. Icarus Verilog compilation check
iverilog -g2012 -o /tmp/csum_chk.vvp \
  code/tx_checksum.v code/rx_checksum.v code/axis_fifo.v

# 2. Yosys Nangate45 synthesis & area report (example for tx_checksum; repeat for rx_checksum with -chparam DATA_WIDTH 64 -chparam START_OFFSET 14)
yosys -p "
  read_verilog code/tx_checksum.v code/axis_fifo.v;
  hierarchy -check -top tx_checksum -chparam DATA_WIDTH 64 -chparam USE_INIT_VALUE 1 -chparam DATA_FIFO_DEPTH 8 -chparam CHECKSUM_FIFO_DEPTH 4;
  synth -flatten -top tx_checksum;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean -purge;
  stat -liberty pdk/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -simple-lhs /tmp/tx_csum_net.v
"

# 3. OpenSTA timing verification (1.46 ns for tx_checksum; 1.24 ns for rx_checksum)
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -no_init -exit <<'EOF'
read_liberty pdk/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/tx_csum_net.v
link_design tx_checksum
create_clock -name clk -period 1.46 [get_ports clk]
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
