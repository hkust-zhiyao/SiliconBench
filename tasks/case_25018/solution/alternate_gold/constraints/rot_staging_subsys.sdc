# Alternate Gold Signoff SDC for rot_staging_subsys
set clk_period 15.5
set io_max_dly 1.5
set io_min_dly 0.2
create_clock -name sys_clk -period $clk_period [get_ports clk]
set_input_delay -clock sys_clk -max $io_max_dly [all_inputs -no_clocks]
set_input_delay -clock sys_clk -min $io_min_dly [all_inputs -no_clocks]
set_output_delay -clock sys_clk -max $io_max_dly [all_outputs]
set_output_delay -clock sys_clk -min $io_min_dly [all_outputs]
set_false_path -from [get_ports rst_b]
set_false_path -from [get_ports cptra_pwrgood]
