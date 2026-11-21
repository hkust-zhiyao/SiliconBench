# Signoff timing constraints for cacc_sram_subsys (IHP SG13G2 130nm)
create_clock -name core_clk -period 14.5 [get_ports nvdla_core_clk]
set_input_delay 1.2 -clock core_clk [all_inputs -no_clocks]
set_output_delay 1.2 -clock core_clk [all_outputs]
set_false_path -from [get_ports nvdla_core_rstn]
