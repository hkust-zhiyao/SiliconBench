create_clock -name core_clk -period 17.0 [get_ports clk]
set_input_delay 1.5 -clock core_clk [all_inputs -no_clocks]
set_output_delay 1.5 -clock core_clk [all_outputs]
set_false_path -from [get_ports reset]
