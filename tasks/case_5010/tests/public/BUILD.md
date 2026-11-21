# Build, Simulation, and Synthesis/STA Environment

## Editable Files
Only the following files may be modified:
- `code/cva6_icache.sv`
- `code/cva6_icache_axi_wrapper.sv`
- `code/axi_shim.sv`

All other files in `code/`, `include/`, `flow/`, `lib/`, and `lef/` are read-only.
Editable RTL must remain technology-independent behavioral/structural SystemVerilog without directly instantiating library cell primitives (e.g., `BUF_X*`, `INV_X*`, `NAND*`, `DFF*`), `(* blackbox *)` modules, or introducing simulator/synthesis conditional compilation macros (`` `ifdef ``, `` `ifndef ``, `` `define ``). Each editable file must define only its own module (`cva6_icache`, `cva6_icache_axi_wrapper`, `axi_shim`), and `code/cva6_icache.sv` must preserve the `sram_cache` (`code/sram_cache.sv`) `tag_sram` and `data_sram` instantiations without replacing `sram_cache` with custom memory modules.

## Compilation Order (`Verilator` / `Yosys -m slang`)
With `-Iinclude`:
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/axi_pkg.sv`
5. `code/ariane_pkg.sv`
6. `code/wt_cache_pkg.sv`
7. `code/cf_math_pkg.sv`
8. `code/lzc.sv`
9. `code/lfsr.sv`
10. `code/sram_cache.sv`
11. `code/axi_shim.sv`
12. `code/cva6_icache.sv`
13. `code/cva6_icache_axi_wrapper.sv`

## Synthesis, Area, and STA Target
`icache_axi_top` (`flow/icache_axi_top.sv`) is synthesized with `yosys -m slang`:
```
read_slang --ignore-assertions --top icache_axi_top -Iinclude -DSYNTHESIS code/config_pkg.sv code/cv64a60ax_config_pkg.sv code/riscv_pkg.sv code/axi_pkg.sv code/ariane_pkg.sv code/wt_cache_pkg.sv code/cf_math_pkg.sv code/lzc.sv code/lfsr.sv code/sram_cache.sv code/axi_shim.sv code/cva6_icache.sv code/cva6_icache_axi_wrapper.sv flow/icache_axi_top.sv
hierarchy -check -top icache_axi_top
proc; opt_clean
select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top icache_axi_top -flatten
opt
dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
abc -liberty lib/NangateOpenCellLibrary_typical.lib
clean
read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
check -assert
stat -liberty lib/NangateOpenCellLibrary_typical.lib
write_verilog -noattr mapped_icache_axi.v
```
and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`, `lib/NangateOpenCellLibrary_typical.lib`) with:
- `create_clock -name clk_i -period 2.10 [get_ports clk_i]`
- `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
- `set_output_delay 0.20 -clock clk_i [all_outputs]`
- `set_load 5.0 [all_outputs]`
Targets:
- Zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`, `$_DLATCH`)
- Mapped area `<= 8,200.0 um^2`
- Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`
- Pure technology-independent behavioral/structural SystemVerilog preserving the `sram_cache` (`tag_sram` and `data_sram`) instances in `code/cva6_icache.sv` (no direct Nangate45 standard-cell instantiations, `blackbox` declarations, extra module definitions, or simulator/synthesis macro divergence)
