# Build & Signoff Notes (`VX_lmem_subsys`)

- **RTL Simulation**: Compile `pdk/core.v`, `pdk/256.v`, and the SystemVerilog collateral in `code/` with Verilator 5 (`-sv -DASIC -DSYNTHESIS -DFUNCTIONAL -Icode`) targeting top module `VX_lmem_subsys`.
- **Logic Synthesis**: Synthesize `VX_lmem_subsys` with `yosys -m slang` (`read_slang -DASIC -DSYNTHESIS -Icode pdk/256_stub.v ... --top VX_lmem_subsys; synth -top VX_lmem_subsys -flatten`) mapped to `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`.
- **Physical Implementation & Signoff**: Run OpenROAD on IHP SG13G2 (`pdk/sg13g2_tech.lef`, `pdk/sg13g2_stdcell.lef`, `pdk/256.lef`, `pdk/sg13g2_stdcell_typ_1p20V_25C.lib`, `pdk/256.lib`) using `plan/macro_placement.json` and `constraints/lmem_subsys.sdc`.
