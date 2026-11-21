# Alternate sign-off SDC for snitch_iso_cluster_subsys

create_clock -name clk_fast -period 3.10 [get_ports clk_i]

set_case_analysis 0 [get_ports test_mode_i]
set_case_analysis 0 [get_ports clk_d2_bypass_i]

create_generated_clock -name clk_d2 \
  -source [get_ports clk_i] \
  -divide_by 2 \
  [get_pins *i_snitch_clkdiv2*/*/Q]

set_clock_uncertainty -setup 0.085 [all_clocks]
set_clock_uncertainty -hold  0.025 [all_clocks]

set_false_path -from [get_ports rst_ni]

set data_in_ports [get_ports {tlb_req_valid_i* tlb_req_flush_i* tlb_req_va_i* tlb_req_ppn_i* tlb_req_priv_i* tlb_req_read_i* tlb_req_write_i* tlb_req_exec_i* tlb_rsp_ready_i* acc_qvalid_i* acc_qid_i* acc_qop_i* acc_qarga_i* acc_qargb_i* acc_qargc_i* acc_pready_i* ptw_mem_qready_i ptw_mem_pvalid_i ptw_mem_pdata_i* ptw_mem_perror_i}]

set_input_delay  -clock clk_fast -max 0.42 $data_in_ports
set_input_delay  -clock clk_fast -min 0.06 $data_in_ports
set_output_delay -clock clk_fast -max 0.42 [all_outputs]
set_output_delay -clock clk_fast -min 0.06 [all_outputs]
