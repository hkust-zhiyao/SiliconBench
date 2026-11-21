# Build & Signoff Reference

## Editable Files
- `code/VX_bar_unit.sv`
- `code/VX_gbar_unit.sv`
- `code/VX_gbar_arb.sv`

## Read-Only Top-Level Subsystem & Collateral
- Top-level wrapper: `code/VX_cluster_bar_subsys.sv`
- Package & bus interface: `code/VX_gpu_pkg.sv`, `code/VX_gbar_bus_if.sv`
- Common macros/primitives: `code/VX_*.vh`, `code/VX_*.sv`, `code/VX_dp_ram_asic.v`
- Standard-cell Liberty / LEF:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Multi-Configuration Functional Verification (`Verilator v5.038`)**:
   - Compile `code/VX_*.sv` and `code/VX_dp_ram_asic.v` with `-DASIC -DSYNTHESIS -DVX_CFG_XLEN=32 -Icode` across:
     - `NUM_CORES=4, NUM_WARPS=4, NUM_BARRIERS=4`
     - `NUM_CORES=2, NUM_WARPS=8, NUM_BARRIERS=4`
2. **Nangate45 Synthesis & OpenROAD STA Signoff**:
   - Elaborate and map `VX_cluster_bar_subsys` (`-DVX_CFG_NUM_CORES=4 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_NUM_BARRIERS=4`) using `yosys -m slang` (`read_slang ... --top VX_cluster_bar_subsys`), enforcing `select -assert-none */t:$dlatch*` and mapping to `lib/NangateOpenCellLibrary_typical.lib`.
   - Run OpenROAD STA at `1.15 ns` clock period (`create_clock -name clk -period 1.15 [get_ports clk]`, `0.10 ns` input/output delays):
     - Setup `WNS >= 0.0000 ns`
     - Synthesized cell area `<= 14000.00 um^2`
