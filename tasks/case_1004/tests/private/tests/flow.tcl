set_thread_count 1
read_lef $::env(TECH_LEF)
read_lef $::env(MACRO_LEF)
read_liberty $::env(LIB_FILE)
read_verilog $::env(NETLIST)
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
exit
