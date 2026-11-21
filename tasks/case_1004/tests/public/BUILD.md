# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable and Read-Only Files
Edit only:
- `code/prim_arbiter_tree.sv`
- `code/prim_sram_arbiter.sv`

Do not modify `code/ot_sram_xbar_2ch.sv`, `code/prim_fifo_sync*.sv*`, `code/prim_count*.sv`, `code/prim_flop*.sv`, `code/prim_mubi_pkg.sv`, `code/prim_util_pkg.sv`, `code/prim_assert*.sv*`, or `lib/*`. You may define helper submodules inside the editable files if needed.

## 2. Behavioral Simulation (`Verilator`)
Compile and simulate `ot_sram_xbar_2ch` across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}` using Verilator 5:
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -DSYNTHESIS -Icode --top-module <your_tb> \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_flop.sv code/prim_count.sv code/prim_fifo_sync_cnt.sv \
  code/prim_fifo_sync.sv code/prim_arbiter_tree.sv code/prim_sram_arbiter.sv \
  code/ot_sram_xbar_2ch.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Nangate45 Logic Synthesis (`Yosys + Slang`)
Synthesize `ot_sram_xbar_2ch` at `N_CH0=8, N_CH1=4, SramAw=12, SramDw=32`:
```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions -DSYNTHESIS --top ot_sram_xbar_2ch -G N_CH0=8 -G N_CH1=4 -G SramAw=12 -G SramDw=32 -I code \
    code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/prim_flop.sv code/prim_count.sv code/prim_fifo_sync_cnt.sv \
    code/prim_fifo_sync.sv code/prim_arbiter_tree.sv code/prim_sram_arbiter.sv \
    code/ot_sram_xbar_2ch.sv
  hierarchy -check -top ot_sram_xbar_2ch
  proc; opt_clean
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr*
  synth -top ot_sram_xbar_2ch
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
Reported `Chip area for module '\ot_sram_xbar_2ch':` must be `<= 2850.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis
Strip ` signed ` tokens (`sed 's/ signed / /g' mapped.v > sta.v`) and run `openroad -exit flow.tcl`:
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design ot_sram_xbar_2ch
initialize_floorplan -die_area {0 0 220 220} -core_area {10 10 210 210} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 3.80 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [get_ports {arb_policy_i* req_ch* sram_gnt_i sram_rvalid_i sram_rdata_i* sram_rerror_i*}]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
Required timing closure: `WNS >= 0.20` ns and `WHS >= 0.00` ns.
