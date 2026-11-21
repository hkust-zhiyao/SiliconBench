read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog mapped.v
link_design wb2axip_bridge_top
create_clock -period 10.0 -name clk [get_ports i_clk]
set_input_delay 0.5 -clock clk [all_inputs -no_clocks]
set_input_delay 6.0 -clock clk [get_ports {wb_dn_ack wb_dn_err wb_dn_stall}]
set_output_delay 0.5 -clock clk [all_outputs]
set_load 0.01 [all_outputs]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -group_path_count 1 -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -group_path_count 1 -format full_clock_expanded
exit
