create_clock -name clk_i -period 8.00 [get_ports clk_i]
set_clock_uncertainty -setup 0.15 [get_clocks clk_i]
set_clock_uncertainty -hold  0.08 [get_clocks clk_i]
set_clock_transition  0.10 [get_clocks clk_i]

set async_p [get_ports {clk_i rst_i}]
set sync_in {}
foreach p [all_inputs] {
  if {[lsearch -exact $async_p $p] == -1} {
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

set_clock_latency -0.40 [get_pins -hierarchical */A_CLK]
set_false_path -from [get_ports rst_i]
set_max_fanout 16 [current_design]
set_max_transition 0.40 [current_design]
