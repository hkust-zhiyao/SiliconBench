# Signoff timing constraints for snitch_ro_cache_subsys (IHP SG13G2 130nm)
create_clock -name core_clk -period 11.6 [get_ports clk_i]
set_input_delay 1.2 -clock core_clk [all_inputs -no_clocks]
set_output_delay 1.2 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_ni]
