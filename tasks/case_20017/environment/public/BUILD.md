# Build, Synthesis, Buffering & Multi-Corner STA Reference

## Editable Files
- `constraints/dcache.sdc`
- `code/dcache_core.v`
- `code/dcache_core_tag_ram.v`
- `code/dcache_core_data_ram.v`
- `code/dcache_axi_axi.v`

All other files in `code/` and `lib/` are read-only.

## Reference Signoff Commands
- **Yosys Synthesis (`build/dcache_mapped.v` + `build/dcache_gl.v`)**:
  ```bash
  mkdir -p build
  yosys -p "
    read_verilog lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v \
      code/dcache_core_tag_ram.v code/dcache_core_data_ram.v code/dcache_core.v \
      code/dcache_if_pmem.v code/dcache_mux.v code/dcache_pmem_mux.v \
      code/dcache_axi_axi.v code/dcache_axi.v code/dcache.v;
    hierarchy -check -top dcache; proc; opt; check -assert;
    select -assert-none t:\$dlatch*;
    synth -top dcache -flatten;
    design -save flat_generic; rename dcache dcache_gl; opt_clean;
    write_verilog -noattr build/dcache_gl.v;
    design -load flat_generic;
    dfflibmap -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    abc -D 2500 -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO;
    setundef -zero; splitnets -ports; opt_clean -purge;
    write_verilog -noattr -noexpr build/dcache_mapped.v"
  ```
- **OpenROAD Buffering (`SS 1.08V 125C`: `Metal3` signal / `Metal4` clock wire RC, `estimate_parasitics -placement`, `repair_design -cap_margin 20 -slew_margin 20`, `repair_timing -setup`; followed by `FF 1.32V -40C`: `repair_timing -hold -hold_margin 0.02`) & 3-Corner (`SS` / `TT` / `FF`) STA**:
  `openroad`
- **Verilator Simulation (with `lib/SRAM_1P_behavioral_bm_bist.v` + `lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v`, `-DFUNCTIONAL`)**:
  `verilator`
