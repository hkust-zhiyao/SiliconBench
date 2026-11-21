# Build & Signoff Reference (`axi_llc_top_wrap`)

## 1. Source Compilation Order
Compile the behavioral SRAM models (`lib/SRAM_1P_behavioral_bm_bist.v`, `lib/RM_IHPSG13_1P_64x64_c2_bm_bist.v`, `lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v`) with `-DFUNCTIONAL -DSYNTHESIS`, include directories `-Icode/common_cells/include -Icode/axi/include -Icode/include`, and the SystemVerilog packages/modules in dependency order (`cb_filter_pkg.sv`, `cf_math_pkg.sv`, `axi_pkg.sv`, `axi_llc_pkg.sv`, `tc_sram.sv`, `common_cells/src/*.sv`, `axi/src/*.sv`, `rtl/*.sv`, top `axi_llc_top_wrap`).

## 2. Synthesis & 4-State Gate-Level Simulation (`yosys -m slang` + `iverilog` / `verilator`)
Synthesize `axi_llc_top_wrap` with `yosys -m slang` against the hard-SRAM blackbox stubs (`lib/RM_IHPSG13_1P_*_stub.v`) and `lib/sg13g2_stdcell_typ_1p20V_25C.lib` (`synth -top axi_llc_top_wrap -flatten`, `dfflibmap`, `abc -D 2500`, `hilomap`, `setundef -zero`, `splitnets -ports`). Simulate both the RTL and the flattened gate-level netlist (`simcells.v` + behavioral SRAM models) using `verilator --binary --timing -CFLAGS -O0` and 4-state `iverilog -g2012`.

## 3. Multi-Corner Hard-SRAM Buffering & STA (`openroad`)
Load `lib/sg13g2_tech.lef`, `lib/sg13g2_stdcell.lef`, both `RM_IHPSG13_1P_*_bm_bist.lef`/`.lib` views, and the corner standard-cell liberty (`slow_1p08V_125C.lib`, `typ_1p20V_25C.lib`, `fast_1p32V_m40C.lib`), read `constraints/axi_llc_ways.sdc`, set `Metal3`/`Metal4` wire RC (`estimate_parasitics -placement`), run `repair_design` in `SS` followed by `repair_timing -hold -hold_margin 0.02` in `FF`, and verify setup/hold WNS & TNS across `SS`, `TT`, and `FF`.
