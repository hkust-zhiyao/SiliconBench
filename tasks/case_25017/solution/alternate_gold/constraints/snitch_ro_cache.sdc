# Signoff timing constraints for snitch_ro_cache_subsys (alt_gold_1)
set clk_period 11.8
create_clock -name core_clk -period $clk_period [get_ports clk_i]
set_input_delay 1.3 -clock core_clk [all_inputs -no_clocks]
set_output_delay 1.3 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_ni]
