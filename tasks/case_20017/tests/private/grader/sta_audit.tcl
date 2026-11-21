# Semantic OpenSTA + 10-Macro Hard-SRAM + Multi-Corner Signoff Script for case_20017
read_lef lib/sg13g2_tech.lef
read_lef lib/sg13g2_stdcell.lef
read_lef lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lef
read_liberty $::env(CORNER_LIB)
read_liberty lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lib
read_verilog $::env(NETLIST_IN)
link_design dcache
read_sdc $::env(SDC_FILE)
set_wire_rc -signal -layer Metal3
set_wire_rc -clock  -layer Metal4
estimate_parasitics -placement

if {$::env(MODE) eq "BUFFER_SS"} {
  set mclks_buf [get_pins -hierarchical */A_CLK]
  if {[llength $mclks_buf] != 10} {
    puts "AUDIT_FAIL macro_clk_count_[llength $mclks_buf]"
    exit 1
  }
  repair_design -cap_margin 20 -slew_margin 20
  repair_timing -setup
  write_verilog $::env(NETLIST_OUT)
  exit 0
}

if {$::env(MODE) eq "BUFFER_FF"} {
  repair_timing -hold -hold_margin 0.02
  write_verilog $::env(NETLIST_OUT)
  exit 0
}

if {$::env(CORNER_NAME) eq "SS"} {
  check_setup -verbose
  set clks [all_clocks]
  if {[llength $clks] != 1} { puts "AUDIT_FAIL clock_count_[llength $clks]"; exit 1 }
  set clk [get_clocks clk_i]
  if {$clk eq ""} { puts "AUDIT_FAIL missing_clk_i"; exit 1 }
  set per [get_property $clk period]
  if {$per < 7.999 || $per > 8.001} { puts "AUDIT_FAIL bad_period_$per"; exit 1 }

  set mclks [get_pins -hierarchical */A_CLK]
  if {[llength $mclks] != 10} { puts "AUDIT_FAIL macro_clk_count_[llength $mclks]"; exit 1 }
  foreach mp $mclks {
    set mps [find_timing_paths -from $mp -path_delay max]
    if {[llength $mps] == 0} { puts "AUDIT_FAIL macro_launch_masked_[get_full_name $mp]"; exit 1 }
  }

  set rst_p [get_ports rst_i]
  set fps [find_timing_paths -from $rst_p -path_delay max]
  if {[llength $fps] != 0} { puts "AUDIT_FAIL async_not_false_path_rst_i"; exit 1 }

  set sync_probe [get_ports mem_rd_i]
  if {[llength [find_timing_paths -from $sync_probe -path_delay max]] == 0 ||
      [llength [find_timing_paths -from $sync_probe -path_delay min]] == 0} {
    puts "AUDIT_FAIL sync_in_unconstrained_mem_rd_i"; exit 1
  }
  set out_probe [get_ports mem_ack_o]
  if {[llength [find_timing_paths -to $out_probe -path_delay max]] == 0 ||
      [llength [find_timing_paths -to $out_probe -path_delay min]] == 0} {
    puts "AUDIT_FAIL out_unconstrained_mem_ack_o"; exit 1
  }
  puts "AUDIT_PASS"
}

puts [format "STA_RESULT_%s setup_wns=%.4f setup_tns=%.4f hold_wns=%.4f hold_tns=%.4f" \
  $::env(CORNER_NAME) \
  [sta::worst_slack -max] [sta::total_negative_slack -max] \
  [sta::worst_slack -min] [sta::total_negative_slack -min]]
exit 0
