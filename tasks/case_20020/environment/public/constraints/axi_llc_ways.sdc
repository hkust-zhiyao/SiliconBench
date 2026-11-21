# Starter SDC for 4-way axi_llc_top_wrap (incomplete — fails 3-corner signoff)
create_clock -name clk_i -period 10.80 [get_ports clk_i]

# Incomplete scalar port exclusion and missing uncertainty/slew/load/8-macro clock balance
set_input_delay  -clock clk_i -max 1.80 [all_inputs]
set_output_delay -clock clk_i -max 1.80 [all_outputs]
set_false_path -from [get_ports {rst_ni test_i}]
