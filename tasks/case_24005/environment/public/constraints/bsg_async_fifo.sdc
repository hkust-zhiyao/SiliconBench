# Baseline timing constraints for bsg_async_fifo
create_clock -name w_clk -period 4.0 [get_ports w_clk_i]
create_clock -name r_clk -period 2.5 [get_ports r_clk_i]
set_clock_groups -asynchronous -group [get_clocks w_clk] -group [get_clocks r_clk]
