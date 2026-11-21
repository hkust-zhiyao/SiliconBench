# Build & Signoff Notes (`VX_cache_subsys`)

- **RTL Simulation**: Compile `pdk/core.v`, `pdk/256.v`, and the SystemVerilog collateral in `code/` (`VX_gpu_pkg.sv` first) with Verilator 5 (`-sv -DSYNTHESIS -DXLEN_32 -DFUNCTIONAL -Icode`) targeting top module `VX_cache_subsys`.
- **Logic Synthesis**: Synthesize `VX_cache_subsys` with `yosys -m slang` (`read_slang -DSYNTHESIS -DXLEN_32 -Icode pdk/256_stub.v ... --top VX_cache_subsys; synth -top VX_cache_subsys -flatten`) mapped to `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`.
- **Physical Implementation & Signoff**: Run OpenROAD on IHP SG13G2 (`pdk/sg13g2_tech.lef`, `pdk/sg13g2_stdcell.lef`, `pdk/256.lef`, `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`, `pdk/256.lib`) using `plan/macro_placement.json` and `constraints/cache_subsys.sdc`.
