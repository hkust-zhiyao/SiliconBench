# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Files and Read-Only Dependencies

Editable RTL files:
- `code/rtl/noc_axi4_bridge_deser.v`
- `code/rtl/noc_axi4_bridge_ser.v`
- `code/rtl/noc_axi4_bridge_buffer.v`

All other files in `code/rtl/`, `code/include/`, and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Icarus Verilog`)

Compile and simulate `noc_axi4_bridge` and its submodules:
```bash
iverilog -g2012 -s tb -I code/include -o sim.vvp \
  code/rtl/storage_addr_trans.v \
  code/rtl/noc_axi4_bridge_sram_data.v \
  code/rtl/noc_axi4_bridge_sram_req.v \
  code/rtl/noc_axi4_bridge_read.v \
  code/rtl/noc_axi4_bridge_write.v \
  code/rtl/noc_axi4_bridge_deser.v \
  code/rtl/noc_axi4_bridge_ser.v \
  code/rtl/noc_axi4_bridge_buffer.v \
  code/rtl/noc_axi4_bridge.v \
  tb.sv
vvp sim.vvp
```

## 3. Synthesis and Mapped Area (`Yosys + Slang`, Nangate45)

### 3.1 Deserializer (`noc_axi4_bridge_deser`, target area `<= 4,955.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top noc_axi4_bridge_deser -I code/include code/rtl/noc_axi4_bridge_deser.v;
  hierarchy -check -top noc_axi4_bridge_deser;
  synth -top noc_axi4_bridge_deser;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_deser.v
"
```

### 3.2 Serializer (`noc_axi4_bridge_ser`, target area `<= 4,810.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top noc_axi4_bridge_ser -I code/include code/rtl/noc_axi4_bridge_ser.v;
  hierarchy -check -top noc_axi4_bridge_ser;
  synth -top noc_axi4_bridge_ser;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_ser.v
"
```

### 3.3 Transaction Buffer (`noc_axi4_bridge_buffer`, target area `<= 21,350.0 um^2`)
```bash
yosys -Q -T -m slang -p "
  read_slang --top noc_axi4_bridge_buffer -I code/include \
    code/rtl/noc_axi4_bridge_sram_data.v \
    code/rtl/noc_axi4_bridge_sram_req.v \
    code/rtl/noc_axi4_bridge_buffer.v;
  hierarchy -check -top noc_axi4_bridge_buffer;
  synth -top noc_axi4_bridge_buffer;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr mapped_buf.v
"
```

## 4. OpenROAD Placement-Estimated Static Timing Analysis (`1.08 ns` Clock)

For `TOP` in `{noc_axi4_bridge_deser, noc_axi4_bridge_ser}` with netlist `mapped_deser.v` / `mapped_ser.v`:
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog <NETLIST>
link_design <TOP>
initialize_floorplan -die_area {0 0 110 110} -core_area {10 10 100 100} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk -period 1.08 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.55
estimate_parasitics -placement
repair_design
repair_timing -setup -hold
detailed_placement
estimate_parasitics -placement
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```

Both `noc_axi4_bridge_deser` and `noc_axi4_bridge_ser` must achieve worst setup slack (`-path_delay max`) **`>= 0.0 ns`** and worst hold slack (`-path_delay min`) **`>= 0.0 ns`** at `1.08 ns`.
