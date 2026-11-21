create_clock -name clk_i -period 9.50 [get_ports clk_i]
set_clock_uncertainty -setup 0.16 [get_clocks clk_i]
set_clock_uncertainty -hold  0.08 [get_clocks clk_i]
set_clock_transition  0.11 [get_clocks clk_i]

set sync_inputs [get_ports {slv_aw_* slv_w_* slv_b_ready_i slv_ar_* slv_r_ready_i mst_aw_ready_i mst_w_ready_i mst_b_* mst_ar_ready_i mst_r_* cfg_spm_i* cfg_flush_i* commit_cfg_i}]
set all_outs    [all_outputs]

set_driving_cell -lib_cell sg13g2_buf_4 -pin X $sync_inputs
set_input_delay  -clock clk_i -max 1.85 $sync_inputs
set_input_delay  -clock clk_i -min 0.18 $sync_inputs
set_output_delay -clock clk_i -max 1.85 $all_outs
set_output_delay -clock clk_i -min 0.04 $all_outs
set_load 0.028 $all_outs

set_clock_latency -0.47 [get_pins -hierarchical *i_cut/A_CLK]
set_false_path -from [get_ports {rst_ni test_i cached_start_addr_i* cached_end_addr_i* spm_start_addr_i*}]
set_max_fanout 10 [current_design]
set_max_transition 0.32 [current_design]
