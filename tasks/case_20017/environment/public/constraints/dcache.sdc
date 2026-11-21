# Starter SDC for dcache (incomplete — fails hard-SRAM 3-corner signoff)
create_clock -name clk_i -period 12.00 [get_ports clk_i]

# Missing setup/hold uncertainty, clock transition, min I/O delays, driving cell, output load, and macro A_CLK latency
set_input_delay  -clock clk_i -max 1.80 [all_inputs]
set_output_delay -clock clk_i -max 1.80 [all_outputs]
set_false_path -from [get_ports rst_i]
