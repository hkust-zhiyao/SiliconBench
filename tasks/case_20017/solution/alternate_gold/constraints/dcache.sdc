create_clock -name clk_i -period 8.00 [get_ports clk_i]
set_clock_uncertainty -setup 0.16 [get_clocks clk_i]
set_clock_uncertainty -hold  0.09 [get_clocks clk_i]
set_clock_transition  0.10 [get_clocks clk_i]

set data_inputs {}
foreach inp [all_inputs] {
  set nm [get_name $inp]
  if {$nm ne "clk_i" && $nm ne "rst_i"} {
    lappend data_inputs $inp
  }
}

set_driving_cell -lib_cell sg13g2_buf_4 -pin X $data_inputs
set_input_delay  -clock clk_i -max 1.85 $data_inputs
set_input_delay  -clock clk_i -min 0.18 $data_inputs
set_output_delay -clock clk_i -max 1.85 [all_outputs]
set_output_delay -clock clk_i -min 0.04 [all_outputs]
set_load 0.028 [all_outputs]

set_clock_latency -0.41 [get_pins -hierarchical */A_CLK]
set_false_path -from [get_ports rst_i]
set_max_fanout 14 [current_design]
set_max_transition 0.38 [current_design]
