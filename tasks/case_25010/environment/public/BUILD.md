# Build & Verification Environment (`case_25010`)

## Available Tools & Collateral
- **RTL Simulation**: Verilator (`verilator --binary --timing`) or Icarus Verilog (`iverilog -g2012`)
- **Synthesis**: Yosys with SystemVerilog Slang frontend (`yosys -m slang`)
- **Physical Implementation & STA**: OpenROAD (`openroad -exit`)
- **PDK Collateral (`pdk/`)**: IHP SG13G2 130nm standard cells (`sg13g2_tech.lef`, `sg13g2_stdcell.lef`, `sg13g2_stdcell_typ_1p20V_25C.lib`, `core.v`) and `RM_IHPSG13_1P_256x64_c2_bm_bist` hard SRAM macro views (`256.v` behavioral model, `256_stub.v` blackbox stub, `256.lef`, `256.lib`).

## Editable Files
- `code/snitch_icache.sv`
- `code/snitch_icache_l0.sv`
- `code/snitch_icache_lookup.sv`
- `code/snitch_icache_handler.sv`
- `code/snitch_icache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_icache.sdc`

## Example Commands
```bash
# 1. RTL Elaboration & Lint Check
verilator --lint-only -Wno-fatal -Wno-UNOPTFLAT -Icode -top-module snitch_icache_subsys \
  pdk/core.v pdk/256.v code/axi_pkg.sv code/cf_math_pkg.sv code/riscv_instr.sv \
  code/snitch_icache_pkg.sv code/cc_onehot.sv code/lzc.sv code/onehot_to_bin.sv \
  code/rr_arb_tree.sv code/spill_register_flushable.sv code/spill_register.sv \
  code/fall_through_register.sv code/fifo_v3.sv code/isochronous_4phase_handshake.sv \
  code/isochronous_spill_register.sv code/stream_arbiter_flushable.sv \
  code/stream_arbiter.sv code/stream_demux.sv code/tc_sram_impl.sv \
  code/snitch_icache_lfsr.sv code/snitch_icache_l0.sv code/snitch_icache_lookup.sv \
  code/snitch_icache_handler.sv code/snitch_icache_refill.sv \
  code/snitch_icache.sv code/snitch_icache_subsys.sv

# 2. Synthesis to SG13G2 Standard Cells + 6x Hard SRAM Macros
yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode pdk/256_stub.v code/axi_pkg.sv code/cf_math_pkg.sv \
    code/riscv_instr.sv code/snitch_icache_pkg.sv code/cc_onehot.sv code/lzc.sv \
    code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
    code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
    code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
    code/tc_sram_impl.sv code/snitch_icache_lfsr.sv code/snitch_icache_l0.sv \
    code/snitch_icache_lookup.sv code/snitch_icache_handler.sv \
    code/snitch_icache_refill.sv code/snitch_icache.sv code/snitch_icache_subsys.sv \
    --top snitch_icache_subsys;
  hierarchy -check -top snitch_icache_subsys;
  synth -noabc -top snitch_icache_subsys -flatten;
  delete t:\$scopeinfo;
  dfflibmap -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  abc -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/mapped.v
"
```
