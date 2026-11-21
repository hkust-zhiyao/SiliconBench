# Alternate signoff constraints for cacc_sram_subsys
set clk_period 14.8
create_clock -name nvdla_clk -period $clk_period [get_ports nvdla_core_clk]
set_input_delay 1.2 -clock nvdla_clk [all_inputs -no_clocks]
set_output_delay 1.2 -clock nvdla_clk [all_outputs]
set_false_path -from [get_ports nvdla_core_rstn]
