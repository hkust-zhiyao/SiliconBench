set L [expr {[info exists ::env(SILICONBENCH_NANGATE45)] ? $::env(SILICONBENCH_NANGATE45) : ([file isdirectory "/opt/siliconbench/pdk/Nangate45"] ? "/opt/siliconbench/pdk/Nangate45" : [file normalize [file join [file dirname [info script]] ../../../../../environments/pdk/Nangate45]])}]
read_lef $L/lef/NangateOpenCellLibrary.tech.lef
read_lef $L/lef/NangateOpenCellLibrary.macro.mod.lef
read_liberty $L/lib/NangateOpenCellLibrary_typical.lib
read_verilog $::env(NETLIST)
link_design hwpe_ctrl_partial_mult
initialize_floorplan -die_area {0 0 400 400} -core_area {10 10 390 390} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 3.1 [get_ports clk_i]
set_input_delay 0.25 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.25 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.4
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
