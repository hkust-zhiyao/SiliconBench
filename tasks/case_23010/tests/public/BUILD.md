# Build & Verification Environment (`case_23010`)

## Available Tools & Collateral
- **RTL Simulation**: Icarus Verilog (`iverilog -g2012` / `vvp`) or Verilator (`verilator`)
- **Synthesis**: Yosys with SystemVerilog Slang frontend (`yosys -m slang`)
- **Physical Implementation & STA**: OpenROAD (`openroad -exit`)
- **PDK Collateral (`pdk/`)**: IHP SG13G2 130nm standard cells (`sg13g2_tech.lef`, `sg13g2_stdcell.lef`, `sg13g2_stdcell_typ_1p20V_25C.lib`, `core.v`) and `RM_IHPSG13_1P_256x64_c2_bm_bist` SRAM macro views (`256.v` behavioral model, `256_stub.v` blackbox stub, `256.lef`, `256.lib`).

## Editable Files
- `code/NV_NVDLA_CACC_assembly_ctrl.v`
- `code/NV_NVDLA_CACC_assembly_buffer.v`
- `code/NV_NVDLA_CACC_delivery_buffer.v`
- `plan/macro_placement.json`
- `constraints/cacc_subsys.sdc`

## Example Commands
```bash
# 1. Behavioral RTL elaboration check
iverilog -g2012 -o /tmp/cacc_sim \
  pdk/core.v pdk/256.v code/NV_DW_lsd.v \
  code/NV_NVDLA_CACC_CALC_int8.v code/NV_NVDLA_CACC_CALC_int16.v code/NV_NVDLA_CACC_CALC_fp_48b.v \
  code/NV_NVDLA_CACC_assembly_ctrl.v code/NV_NVDLA_CACC_assembly_buffer.v \
  code/NV_NVDLA_CACC_delivery_buffer.v code/cacc_sram_subsys.v

# 2. Synthesis to SG13G2 standard cells + 8x hard SRAM macros
yosys -m slang -p "
  read_slang -DSYNTHESIS pdk/256_stub.v code/NV_DW_lsd.v \
    code/NV_NVDLA_CACC_CALC_int8.v code/NV_NVDLA_CACC_CALC_int16.v code/NV_NVDLA_CACC_CALC_fp_48b.v \
    code/NV_NVDLA_CACC_assembly_ctrl.v code/NV_NVDLA_CACC_assembly_buffer.v \
    code/NV_NVDLA_CACC_delivery_buffer.v code/cacc_sram_subsys.v --top cacc_sram_subsys;
  hierarchy -check -top cacc_sram_subsys;
  synth -top cacc_sram_subsys -flatten;
  delete t:\$scopeinfo;
  dfflibmap -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  abc -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/mapped.v
"
```
