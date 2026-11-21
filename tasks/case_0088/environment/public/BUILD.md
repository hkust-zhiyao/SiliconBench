# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable and Read-Only Files
Edit only:
- `code/ArbitrationTree.sv`
- `code/MUX2_REQ.sv`
- `code/TestAndSet.sv`

Do not modify `code/parameters.v`, `code/FanInPrimitive_Req.sv`, `code/priority_Flag_Req.sv`, `code/AddressDecoder_Resp.sv`, `code/RequestBlock2CH.sv`, or `lib/*`.

## 2. Latch-Free Check & Behavioral Simulation (`Yosys` & `Verilator`)
Verify latch-free synthesis with Yosys:
```bash
yosys -q -p "
  read_verilog -sv -Icode code/ArbitrationTree.sv code/FanInPrimitive_Req.sv code/priority_Flag_Req.sv code/MUX2_REQ.sv code/TestAndSet.sv code/AddressDecoder_Resp.sv code/RequestBlock2CH.sv;
  hierarchy -check -top RequestBlock2CH -chparam N_CH0 4 -chparam N_CH1 2;
  proc; opt_clean;
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr*
"
```

Compile and simulate `RequestBlock2CH` across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}` (`ADDR_MEM_WIDTH=8`, `DATA_WIDTH=32`, `ID_WIDTH=N_CH0+N_CH1`) using Verilator 5:
```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  +incdir+code \
  code/RequestBlock2CH.sv code/ArbitrationTree.sv code/FanInPrimitive_Req.sv \
  code/priority_Flag_Req.sv code/MUX2_REQ.sv code/TestAndSet.sv \
  code/AddressDecoder_Resp.sv tb.sv
./obj_dir/Vtb
```

## 3. Nangate45 Logic Synthesis (`Yosys + Slang`)
Synthesize `RequestBlock2CH` at `N_CH0=8, N_CH1=4, ADDR_MEM_WIDTH=32, DATA_WIDTH=32`:
```bash
yosys -Q -T -m slang -p "
  read_slang --top RequestBlock2CH -G N_CH0=8 -G N_CH1=4 -G ADDR_MEM_WIDTH=32 -G DATA_WIDTH=32 -I code \
    code/ArbitrationTree.sv code/FanInPrimitive_Req.sv code/priority_Flag_Req.sv \
    code/MUX2_REQ.sv code/TestAndSet.sv code/AddressDecoder_Resp.sv code/RequestBlock2CH.sv
  hierarchy -check -top RequestBlock2CH
  synth -top RequestBlock2CH
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
Reported `Chip area for module '\RequestBlock2CH':` must be `<= 2705.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis
Strip ` signed ` tokens (`sed 's/ signed / /g' mapped.v > sta.v`) and run `openroad -exit flow.tcl`:
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design RequestBlock2CH
initialize_floorplan -die_area {0 0 220 220} -core_area {10 10 210 210} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk -period 2.85 [get_ports clk]
set_input_delay 0.2 -clock clk [get_ports {data_req* data_add* data_wen* data_wdata* data_be* data_ID* data_gnt_i data_r_* TCDM_arb_policy_i*}]
set_output_delay 0.2 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.5
estimate_parasitics -placement
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
Required timing closure: `WNS >= 0.60` ns and `WHS >= 0.00` ns.
