# Build & Signoff Reference

## Editable Files
- `code/VX_tcu_uops.sv`
- `code/VX_tcu_abuf.sv`
- `code/VX_tcu_bbuf.sv`
- `code/VX_tcu_core.sv`

## Read-Only Subsystem & Technology Collateral
- Subsystem top & supporting Vortex TCU/core/library RTL: `code/VX_tcu_subsys.sv`, `code/VX_tcu_pkg.sv`, `code/VX_gpu_pkg.sv`, and supporting `.sv`/`.vh` files in `code/`
- Nangate45 standard-cell collateral:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Dual-Configuration RTL Functional Verification (`Verilator v5.038`)**:
   - Compile `VX_gpu_pkg.sv`, `VX_tcu_pkg.sv`, and `VX_tcu_subsys.sv` (`-Icode -DXLEN_32 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_LMEM_NUM_BANKS=8 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE`) across:
     - `CFG_F2K_1B`: `-DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_FEDP2K`
     - `CFG_NOF2K_2B`: `-DVX_CFG_NUM_TCU_BLOCKS=2 -DNO_FEDP2K`
   - Verify dense & 2:4 sparse `WMMA`/`WGMMA` arithmetic, strided bank-row-straddling SMEM tile loads, B-tile cache coherency, dual-block lockstep, and FIFO retirement under randomized LMEM/commit backpressure.
2. **Yosys Synthesis, 4-State Gate-Level Simulation & Nangate45 PPA/STA Signoff**:
   - Elaborate `VX_tcu_subsys` in `yosys -m slang` (`read_slang --top VX_tcu_subsys -Icode -DXLEN_32 -DTCU_SYNTH_BND -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=2 -DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE -DVX_CFG_TCU_FEDP2K -DVX_CFG_LMEM_NUM_BANKS=8 code/VX_gpu_pkg.sv code/VX_tcu_pkg.sv ...`), checking zero latches (`$dlatch*`, `$_DLATCH_*`) and zero combinational loops (`scc -expect 0`).
   - Simulate the synthesized gate-level netlist in 4-state `iverilog -g2012` against `simcells.v` to verify `X`-free reset and multi-warp `WMMA`/`WGMMA`/`WGMMA_SP` retirement.
   - Flatten and map to `lib/NangateOpenCellLibrary_typical.lib` (`dfflibmap -liberty` + `abc -liberty ... -D 1500 -script "+strash;dc2;dch -f;map;buffer -N 16;upsize;dnsize"`), requiring cell area `<= 87,200.0 um^2` and OpenROAD STA setup `WNS >= 0.0000 ns` at a `6.50 ns` clock period (`0.20 ns` non-clock I/O delays, `set_false_path -from [get_ports reset]`).
