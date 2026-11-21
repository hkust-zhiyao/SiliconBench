# Semantic OpenSTA + Multi-Corner Signoff Script for case_20020 (4-way 8-macro axi_llc)
# Invoked with env vars MODE={BUFFER|AUDIT_AND_STA}, CORNER_NAME, CORNER_LIB, NETLIST_IN, NETLIST_OUT, SDC_FILE
read_lef lib/sg13g2_tech.lef
read_lef lib/sg13g2_stdcell.lef
read_lef lib/RM_IHPSG13_1P_64x64_c2_bm_bist.lef
read_lef lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lef
read_liberty $::env(CORNER_LIB)
read_liberty lib/RM_IHPSG13_1P_64x64_c2_bm_bist.lib
read_liberty lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lib
read_verilog $::env(NETLIST_IN)
link_design axi_llc_top_wrap
read_sdc $::env(SDC_FILE)
set_wire_rc -signal -layer Metal3
set_wire_rc -clock  -layer Metal4
estimate_parasitics -placement

if {$::env(MODE) eq "BUFFER"} {
  repair_design
  write_verilog $::env(NETLIST_OUT)
  exit 0
}

if {$::env(MODE) eq "HOLD_FIX"} {
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
  if {$per < 10.799 || $per > 10.801} { puts "AUDIT_FAIL bad_period_$per"; exit 1 }

  set mclks [get_pins -hierarchical *i_cut/A_CLK]
  if {[llength $mclks] != 8} { puts "AUDIT_FAIL macro_clk_count_[llength $mclks]"; exit 1 }
  foreach mp $mclks {
    set mps [find_timing_paths -from $mp -path_delay max]
    if {[llength $mps] == 0} { puts "AUDIT_FAIL macro_launch_masked_[get_full_name $mp]"; exit 1 }
  }

  set async_p [get_ports {clk_i rst_ni test_i cached_start_addr_i* cached_end_addr_i* spm_start_addr_i*}]
  foreach p $async_p {
    if {[get_name $p] ne "clk_i"} {
      set fps [find_timing_paths -from $p -path_delay max]
      if {[llength $fps] != 0} { puts "AUDIT_FAIL async_not_false_path_[get_name $p]"; exit 1 }
    }
  }
  foreach p [all_inputs] {
    if {[lsearch -exact $async_p $p] == -1} {
      set ps_max [find_timing_paths -from $p -path_delay max]
      set ps_min [find_timing_paths -from $p -path_delay min]
      if {[llength $ps_max] == 0 || [llength $ps_min] == 0} {
        puts "AUDIT_FAIL sync_in_unconstrained_[get_name $p]"; exit 1
      }
    }
  }
  foreach p [all_outputs] {
    set ps_max [find_timing_paths -to $p -path_delay max]
    set ps_min [find_timing_paths -to $p -path_delay min]
    if {[llength $ps_max] == 0 || [llength $ps_min] == 0} {
      puts "AUDIT_FAIL out_unconstrained_[get_name $p]"; exit 1
    }
  }
  puts "AUDIT_PASS"
}

puts [format "STA_RESULT_%s setup_wns=%.4f setup_tns=%.4f hold_wns=%.4f hold_tns=%.4f" \
  $::env(CORNER_NAME) \
  [sta::worst_slack -max] [sta::total_negative_slack -max] \
  [sta::worst_slack -min] [sta::total_negative_slack -min]]
exit 0
