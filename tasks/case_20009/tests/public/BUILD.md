# Build, Synthesis, Buffering & Multi-Corner STA Reference

## Editable Files
- `constraints/axi_llc.sdc`
- `code/rtl/axi_llc_top.sv`
- `code/rtl/axi_llc_chan_splitter.sv`
- `code/rtl/axi_llc_tag_store.sv`
- `code/rtl/axi_llc_data_way.sv`

All other files in `code/` and `lib/` are read-only.

## Reference Signoff Commands
- **Yosys + Slang Synthesis (`build/llc_mapped.v`)**:
  ```bash
  mkdir -p build
  yosys -m slang -p "
    read_slang --top axi_llc_top_wrap -Icode/common_cells/include -Icode/axi/include -Icode/include -DSYNTHESIS \
      lib/RM_IHPSG13_1P_64x64_c2_bm_bist_stub.v lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v \
      code/common_cells/src/cb_filter_pkg.sv code/common_cells/src/cf_math_pkg.sv \
      code/axi/src/axi_pkg.sv code/rtl/axi_llc_pkg.sv code/rtl/tc_sram.sv \
      code/common_cells/src/*.sv code/axi/src/*.sv code/rtl/*.sv;
    hierarchy -check -top axi_llc_top_wrap; proc; opt_expr; check -assert;
    select -assert-none t:\$dlatch*;
    synth -top axi_llc_top_wrap -flatten;
    dfflibmap -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    abc -D 2500 -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO;
    setundef -zero; splitnets -ports; opt_clean -purge;
    write_verilog -noattr -noexpr build/llc_mapped.v"
  ```
- **OpenROAD `repair_design` Buffering & 3-Corner (`SS` / `TT` / `FF`) STA**:
  `openroad`
- **Verilator Simulation (with `lib/SRAM_1P_behavioral_bm_bist.v` + `lib/RM_IHPSG13_1P_*x64_c2_bm_bist.v`, `-DFUNCTIONAL`)**:
  `verilator`
