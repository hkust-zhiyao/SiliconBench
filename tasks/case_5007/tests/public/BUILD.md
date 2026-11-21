# Build, Simulation, and Synthesis/STA Environment

## Editable Files
Only the following files may be modified:
- `code/cache_ctrl.sv`
- `code/miss_handler.sv`
- `code/tag_cmp.sv`

All other files in `code/`, `include/`, `flow/`, `lib/`, and `lef/` are read-only.

## Compilation Order (`Verilator` / `Yosys -m slang`)
With `-Iinclude`:
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/axi_pkg.sv`
5. `code/ariane_pkg.sv`
6. `code/std_cache_pkg.sv`
7. `code/lfsr_8bit.sv`
8. `code/lfsr.sv`
9. `code/tc_sram.sv`
10. `code/tc_sram_wrapper.sv`
11. `code/sram.sv`
12. `code/axi_adapter.sv`
13. `code/tag_cmp.sv`
14. `code/cache_ctrl.sv`
15. `code/miss_handler.sv`
16. `code/std_nbdcache.sv`

## Synthesis, Area, and STA Target
`dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) is synthesized with `yosys -m slang`:
```
read_slang --ignore-assertions --top dcache_ctrl_top -Iinclude -DSYNTHESIS code/config_pkg.sv code/cv64a60ax_config_pkg.sv code/riscv_pkg.sv code/axi_pkg.sv code/ariane_pkg.sv code/std_cache_pkg.sv code/tag_cmp.sv code/cache_ctrl.sv flow/dcache_ctrl_top.sv
hierarchy -check -top dcache_ctrl_top
proc; opt_clean
select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top dcache_ctrl_top -flatten
opt
dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
abc -liberty lib/NangateOpenCellLibrary_typical.lib
clean
read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
check -assert
stat -liberty lib/NangateOpenCellLibrary_typical.lib
write_verilog -noattr mapped_dcache_ctrl.v
```
and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`, `lib/NangateOpenCellLibrary_typical.lib`) with:
- `create_clock -name clk_i -period 2.44 [get_ports clk_i]`
- `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
- `set_output_delay 0.20 -clock clk_i [all_outputs]`
- `set_load 5.0 [all_outputs]`
Targets:
- Zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`, `$_DLATCH`) across `std_nbdcache` and `dcache_ctrl_top`
- Mapped area `<= 2,825.0 um^2` on `dcache_ctrl_top`
- Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`
