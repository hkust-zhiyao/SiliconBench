# Baseline bring-up constraints (needs tightening for 20.0 ns signoff)
create_clock -name core_clk -period 24.0 [get_ports clk]
set_input_delay 0.5 -clock core_clk [all_inputs -no_clocks]
set_output_delay 0.5 -clock core_clk [all_outputs]
set_false_path -from [get_ports reset]
