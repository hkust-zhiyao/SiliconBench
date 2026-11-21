# Build & Verification Environment (`case_25015`)

## Available Tools & Collateral
- **RTL Simulation**: Verilator (`verilator --binary --timing`)
- **4-State Gate-Level Simulation**: Yosys (`yosys -m slang`) + Icarus Verilog (`iverilog -g2012` / `vvp`) with Yosys `simcells.v`
- **Technology Mapping & Multi-Corner STA**: Yosys + OpenROAD (`openroad -exit`) using Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`, `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`)

## Editable Files
- `code/snitch_clkdiv2.sv`
- `code/snitch_l0_tlb.sv`
- `code/snitch_ptw.sv`
- `code/snitch_shared_muldiv.sv`
- `code/snitch_iso_hive.sv`
- `constraints/snitch_iso_hive.sdc`

## Example Commands
```bash
# 1. Verilator Elaboration & Lint (CoreCount = 2 or 4)
verilator --lint-only -Wno-fatal -Wno-UNOPTFLAT -GCoreCount=4 -Icode \
  -top-module snitch_iso_cluster_subsys \
  code/dm_pkg.sv code/axi_pkg.sv code/cf_math_pkg.sv code/reqrsp_pkg.sv \
  code/riscv_instr.sv code/snitch_pkg.sv code/cc_onehot.sv code/lzc.sv \
  code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
  code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
  code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
  code/reqrsp_iso.sv code/snitch_clkdiv2.sv code/snitch_l0_tlb.sv \
  code/snitch_ptw.sv code/snitch_shared_muldiv.sv code/snitch_iso_hive.sv \
  code/snitch_iso_cluster_subsys.sv

# 2. Nangate45 Synthesis (CoreCount = 4, preserving snitch_clkdiv2)
yosys -m slang -p "
  read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -Icode \
    code/dm_pkg.sv code/axi_pkg.sv code/cf_math_pkg.sv code/reqrsp_pkg.sv \
    code/riscv_instr.sv code/snitch_pkg.sv code/cc_onehot.sv code/lzc.sv \
    code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
    code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
    code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
    code/reqrsp_iso.sv code/snitch_clkdiv2.sv code/snitch_l0_tlb.sv \
    code/snitch_ptw.sv code/snitch_shared_muldiv.sv code/snitch_iso_hive.sv \
    code/snitch_iso_cluster_subsys.sv --top snitch_iso_cluster_subsys -G CoreCount=4;
  hierarchy -check -top snitch_iso_cluster_subsys;
  setattr -mod -set keep_hierarchy 1 snitch_clkdiv2;
  synth -noabc -top snitch_iso_cluster_subsys -flatten;
  delete t:\$scopeinfo; scc -expect 0;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -script +strash\;scorr\;dc2\;strash\;dch,-f\;map\;buffer,-N,8;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/ng45.v
"
```
