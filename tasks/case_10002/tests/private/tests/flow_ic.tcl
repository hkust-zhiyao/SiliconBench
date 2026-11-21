set_thread_count 1
read_lef $::env(TECH_LEF)
read_lef $::env(MACRO_LEF)
read_liberty $::env(LIB_FILE)
read_verilog $::env(NETLIST)
link_design dynamic_input_control
initialize_floorplan -die_area {0 0 60 60} -core_area {6 6 54 54} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk -period 0.85 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
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
