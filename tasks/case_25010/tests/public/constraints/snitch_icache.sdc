# Draft bring-up constraints (needs signoff closure)
create_clock -name core_clk -period 25.0 [get_ports clk_i]
set_input_delay 0.2 -clock core_clk [all_inputs -no_clocks]
set_output_delay 0.2 -clock core_clk [all_outputs]
