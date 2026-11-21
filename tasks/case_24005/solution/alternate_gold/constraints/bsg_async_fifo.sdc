# Alternate signoff SDC: bounded clock-pair CDC max delay + hold relaxation
create_clock -name w_clk -period 4.0 [get_ports w_clk_i]
create_clock -name r_clk -period 2.5 [get_ports r_clk_i]

set_clock_uncertainty -setup 0.14 [all_clocks]
set_clock_uncertainty -hold  0.04 [all_clocks]

set_input_delay  -clock w_clk -max 0.65 [get_ports {w_reset_i w_enq_i w_data_i[*]}]
set_input_delay  -clock w_clk -min 0.08 [get_ports {w_reset_i w_enq_i w_data_i[*]}]
set_output_delay -clock w_clk -max 0.65 [get_ports w_full_o]
set_output_delay -clock w_clk -min 0.04 [get_ports w_full_o]

set_input_delay  -clock r_clk -max 0.55 [get_ports {r_reset_i r_deq_i}]
set_input_delay  -clock r_clk -min 0.08 [get_ports {r_reset_i r_deq_i}]
set_output_delay -clock r_clk -max 0.55 [get_ports {r_valid_o r_data_o[*]}]
set_output_delay -clock r_clk -min 0.04 [get_ports {r_valid_o r_data_o[*]}]

set_max_delay 1.90 -from [get_clocks w_clk] -to [get_clocks r_clk]
set_max_delay 1.90 -from [get_clocks r_clk] -to [get_clocks w_clk]
set_false_path -hold -from [get_clocks w_clk] -to [get_clocks r_clk]
set_false_path -hold -from [get_clocks r_clk] -to [get_clocks w_clk]
