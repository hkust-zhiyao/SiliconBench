# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/lsu.sv`: BSG Manycore Vanilla Bean load-store address generator and local/remote classifier (**editable target**).
- `code/network_tx.sv`: Outgoing network packet builder, EVA-to-NPA wrapper, and return packet demultiplexer (**editable target**).
- `code/bsg_manycore_endpoint_standard.sv`: Standard manycore tile endpoint controller (**editable target**).
- `code/bsg_manycore_tile_mem_if.sv`: Top-level tile memory interface integration wrapper (read-only).
- `code/bsg_*.sv`, `code/bsg_*.svh`: Upstream BSG Manycore and BaseJump STL packages and dependencies (read-only).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.

Edit only `code/lsu.sv`, `code/network_tx.sv`, and `code/bsg_manycore_endpoint_standard.sv`.

## 2. Functional Simulation (Verilator)

```bash
verilator --binary --timing -j 1 -Wno-fatal -DBSG_HIDE_FROM_SYNTHESIS -Icode --top-module tb \
  code/bsg_manycore_pkg.sv code/bsg_manycore_addr_pkg.sv code/bsg_vanilla_pkg.sv \
  code/bsg_dff_reset.sv code/bsg_circular_ptr.sv code/bsg_fifo_tracker.sv \
  code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
  code/bsg_fifo_1r1w_small_unhardened.sv code/bsg_fifo_1r1w_small.sv \
  code/bsg_two_fifo.sv code/bsg_counter_up_down.sv code/bsg_hashing_ipoly.sv \
  code/bsg_manycore_reg_id_decode.sv code/bsg_manycore_dram_hash_function.sv \
  code/bsg_manycore_eva_to_npa.sv code/bsg_manycore_endpoint.sv \
  code/bsg_manycore_endpoint_fc.sv code/bsg_manycore_endpoint_standard.sv \
  code/lsu.sv code/network_tx.sv code/bsg_manycore_tile_mem_if.sv tb.sv
./obj_dir/Vtb
```

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top bsg_manycore_tile_mem_if -DBSG_HIDE_FROM_SYNTHESIS -I code \
    code/bsg_manycore_pkg.sv code/bsg_manycore_addr_pkg.sv code/bsg_vanilla_pkg.sv \
    code/bsg_dff_reset.sv code/bsg_circular_ptr.sv code/bsg_fifo_tracker.sv \
    code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
    code/bsg_fifo_1r1w_small_unhardened.sv code/bsg_fifo_1r1w_small.sv \
    code/bsg_two_fifo.sv code/bsg_counter_up_down.sv code/bsg_hashing_ipoly.sv \
    code/bsg_manycore_reg_id_decode.sv code/bsg_manycore_dram_hash_function.sv \
    code/bsg_manycore_eva_to_npa.sv code/bsg_manycore_endpoint.sv \
    code/bsg_manycore_endpoint_fc.sv code/bsg_manycore_endpoint_standard.sv \
    code/lsu.sv code/network_tx.sv code/bsg_manycore_tile_mem_if.sv
  hierarchy -check -top bsg_manycore_tile_mem_if
  synth -top bsg_manycore_tile_mem_if
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```

The reported `Chip area for module '\bsg_manycore_tile_mem_if':` must be `<= 3665.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD (`openroad -exit flow.tcl`) with:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design bsg_manycore_tile_mem_if
initialize_floorplan -die_area {0 0 140 140} -core_area {10 10 130 130} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 2.33 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.40 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
```

Both the worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`) must be `>= 0.0` (`ns`), with an empty `check_setup -verbose` audit block.
