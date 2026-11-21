# Baseline constraints for snitch_iso_cluster_subsys
# Incomplete: missing generated clock on snitch_clkdiv2, uncertainty, and synchronous isochronous signoff
create_clock -name clk_fast -period 2.00 [get_ports clk_i]
