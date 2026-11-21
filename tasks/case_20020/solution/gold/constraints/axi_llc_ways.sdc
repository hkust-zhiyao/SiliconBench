create_clock -name clk_i -period 10.80 [get_ports clk_i]
set_clock_uncertainty -setup 0.15 [get_clocks clk_i]
set_clock_uncertainty -hold  0.08 [get_clocks clk_i]
set_clock_transition  0.10 [get_clocks clk_i]

set async_and_static [get_ports {clk_i rst_ni test_i cached_start_addr_i* cached_end_addr_i* spm_start_addr_i*}]
set sync_in {}
foreach p [all_inputs] {
  if {[lsearch -exact $async_and_static $p] == -1} {
    lappend sync_in $p
  }
}
set sync_out [all_outputs]

set_driving_cell -lib_cell sg13g2_buf_4 -pin X $sync_in
set_input_delay  -clock clk_i -max 1.80 $sync_in
set_input_delay  -clock clk_i -min 0.20 $sync_in
set_output_delay -clock clk_i -max 1.80 $sync_out
set_output_delay -clock clk_i -min 0.05 $sync_out
set_load 0.025 $sync_out

# CTS macro clock-tree balance target (-0.48 ns early arrival across all 8 hard SRAM A_CLK pins)
set_clock_latency -0.48 [get_pins -hierarchical *i_cut/A_CLK]

set_false_path -from [get_ports {rst_ni test_i cached_start_addr_i* cached_end_addr_i* spm_start_addr_i*}]

set_max_fanout 12 [current_design]
set_max_transition 0.35 [current_design]
