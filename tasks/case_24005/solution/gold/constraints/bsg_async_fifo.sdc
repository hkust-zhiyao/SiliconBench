# Signoff SDC for bsg_async_fifo (lg_size_p=3, width_p=16, control_width_p=4, and_data_with_valid_p=1)
create_clock -name w_clk -period 4.0 [get_ports w_clk_i]
create_clock -name r_clk -period 2.5 [get_ports r_clk_i]

set_clock_uncertainty -setup 0.12 [all_clocks]
set_clock_uncertainty -hold  0.03 [all_clocks]

set_input_delay  -clock w_clk -max 0.60 [get_ports {w_reset_i w_enq_i w_data_i[*]}]
set_input_delay  -clock w_clk -min 0.10 [get_ports {w_reset_i w_enq_i w_data_i[*]}]
set_output_delay -clock w_clk -max 0.60 [get_ports w_full_o]
set_output_delay -clock w_clk -min 0.05 [get_ports w_full_o]

set_input_delay  -clock r_clk -max 0.50 [get_ports {r_reset_i r_deq_i}]
set_input_delay  -clock r_clk -min 0.10 [get_ports {r_reset_i r_deq_i}]
set_output_delay -clock r_clk -max 0.50 [get_ports {r_valid_o r_data_o[*]}]
set_output_delay -clock r_clk -min 0.05 [get_ports {r_valid_o r_data_o[*]}]

# Bounded CDC crossings on all launch-sync-sync primitives (Gray pointers + RDC handshakes)
set_max_delay 2.00 -from [get_cells -hierarchical *blss/iclk_i_DFF*] -to [get_cells -hierarchical *blss/oclk_i_DFF*]
set_false_path -hold -from [get_cells -hierarchical *blss/iclk_i_DFF*] -to [get_cells -hierarchical *blss/oclk_i_DFF*]

# Asynchronous dual-port FIFO RAM write-clock storage to read-clock output bus crossing
set_max_delay 2.40 -from [get_cells -hierarchical *synth/*mem*DFF*] -to [get_ports r_data_o[*]]
set_false_path -hold -from [get_cells -hierarchical *synth/*mem*DFF*] -to [get_ports r_data_o[*]]
