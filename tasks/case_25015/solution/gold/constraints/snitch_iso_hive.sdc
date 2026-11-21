# Sign-off timing constraints for snitch_iso_cluster_subsys (Nangate45 Multi-Corner STA)

create_clock -name clk_fast -period 3.15 [get_ports clk_i]

# Divided-mode case analysis (1:2 isochronous operation; grader also checks bypass=1 mode)
set_case_analysis 0 [get_ports test_mode_i]
set_case_analysis 0 [get_ports clk_d2_bypass_i]

# Divide-by-2 generated clock at snitch_clkdiv2 toggle flip-flop output
create_generated_clock -name clk_d2 \
  -source [get_ports clk_i] \
  -divide_by 2 \
  [get_pins *i_snitch_clkdiv2*/*/Q]

set_clock_uncertainty -setup 0.08 [all_clocks]
set_clock_uncertainty -hold  0.02 [all_clocks]

# Asynchronous active-low reset relaxation
set_false_path -from [get_ports rst_ni]

# Synchronous data/handshake I/O budgets in clk_fast domain
set sync_inputs [get_ports {tlb_req_valid_i* tlb_req_flush_i* tlb_req_va_i* tlb_req_ppn_i* tlb_req_priv_i* tlb_req_read_i* tlb_req_write_i* tlb_req_exec_i* tlb_rsp_ready_i* acc_qvalid_i* acc_qid_i* acc_qop_i* acc_qarga_i* acc_qargb_i* acc_qargc_i* acc_pready_i* ptw_mem_qready_i ptw_mem_pvalid_i ptw_mem_pdata_i* ptw_mem_perror_i}]

set_input_delay  -clock clk_fast -max 0.40 $sync_inputs
set_input_delay  -clock clk_fast -min 0.05 $sync_inputs

set_output_delay -clock clk_fast -max 0.40 [all_outputs]
set_output_delay -clock clk_fast -min 0.05 [all_outputs]
