# Build and Verification Environment

## Source and Dependency Order
The MMU and PMP modules are extracted from CVA6 (`repo_05`), with open-licensed `lzc.sv`, `cf_math_pkg.sv`, and `include/common_cells/assertions.svh` from Croc `common_cells`.

Compilation order (with `-Iinclude` in the include search path):
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/ariane_pkg.sv`
5. `code/cf_math_pkg.sv`
6. `code/lzc.sv`
7. `code/lfsr.sv`
8. `code/tc_sram.sv`
9. `code/tc_sram_wrapper.sv`
10. `code/sram.sv`
11. `code/pmp_entry.sv`
12. `code/pmp.sv`
13. `code/pmp_data_if.sv`
14. `code/cva6_tlb.sv`
15. `code/cva6_shared_tlb.sv`
16. `code/cva6_ptw.sv`
17. `code/cva6_mmu.sv`

## Editable Files
Only the following files may be modified:
- `code/cva6_tlb.sv`
- `code/cva6_shared_tlb.sv`
- `code/cva6_ptw.sv`

All other files in `code/` and `include/` are read-only.

## Synthesis, Area, and STA Target
1. The full MMU hierarchy (`cva6_mmu`) must elaborate cleanly under Verilator 5 and synthesize under Yosys (`yosys -m slang`) with zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`).
2. `cva6_tlb` (`TLB_ENTRIES = 2`, `HYP_EXT = 0`, `XLEN = 64`, `VLEN = 64`, `PLEN = 56`, `GPLEN = 41`, `PPNW = 44`, `GPPNW = 29`, `PtLevels = 3`, `VpnLen = 27`, `SV = 39`, `SVX = 41`, `ASID_WIDTH = 16`, `VMID_WIDTH = 14`, `SvnapotEn = 1`, `RVH = 0`) is synthesized with `yosys -m slang`:
   ```
   synth -top tlb_top -flatten
   opt
   dfflibmap -liberty NangateOpenCellLibrary_typical.lib
   abc -liberty NangateOpenCellLibrary_typical.lib
   clean
   stat -liberty NangateOpenCellLibrary_typical.lib
   ```
   and timed in OpenROAD/OpenSTA with:
   - `create_clock -name clk_i -period 2.42 [get_ports clk_i]`
   - `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
   - `set_output_delay 0.20 -clock clk_i [all_outputs]`
   - `set_load 5.0 [all_outputs]`
   Targets:
   - Mapped area `<= 2,260.0 um^2`
   - Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`
