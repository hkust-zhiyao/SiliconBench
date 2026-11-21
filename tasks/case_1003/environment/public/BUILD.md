# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/prim_packer.sv`: OpenTitan byte-aligned stream packer (**editable target**).
- `code/kmac_msgfifo.sv`: OpenTitan KMAC message packer and FIFO controller (**editable target**).
- `code/kmac_errchk.sv`: OpenTitan KMAC software command and configuration checker (**editable target**).
- `code/kmac_msg_err_top.sv`: Top-level KMAC message and command front-end wrapper (read-only).
- `code/prim_*.sv`, `code/prim_*.svh`, `code/*_pkg.sv`: Upstream OpenTitan packages and primitives (read-only).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.

Edit only `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, and `code/kmac_errchk.sv`.

## 2. Functional Simulation (Verilator)

```bash
verilator --binary --timing -j 1 -Wno-fatal -DSYNTHESIS -Icode --top-module tb \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/lc_ctrl_reg_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_pkg.sv \
  code/sha3_pkg.sv code/kmac_pkg.sv code/prim_flop.sv \
  code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_packer.sv code/kmac_msgfifo.sv code/kmac_errchk.sv \
  code/kmac_msg_err_top.sv tb.sv
./obj_dir/Vtb
```

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top kmac_msg_err_top -DSYNTHESIS -I code \
    code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/lc_ctrl_reg_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_pkg.sv \
    code/sha3_pkg.sv code/kmac_pkg.sv code/prim_flop.sv \
    code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
    code/prim_packer.sv code/kmac_msgfifo.sv code/kmac_errchk.sv \
    code/kmac_msg_err_top.sv
  hierarchy -check -top kmac_msg_err_top
  synth -top kmac_msg_err_top
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

The reported `Chip area for module '\kmac_msg_err_top':` must be `<= 2260.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD (`openroad -exit flow.tcl`) with:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design kmac_msg_err_top
initialize_floorplan -die_area {0 0 120 120} -core_area {10 10 110 110} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 1.50 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_input_delay 0.50 -clock clk_i [get_ports rst_ni]
set_output_delay 0.35 -clock clk_i [all_outputs]
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
