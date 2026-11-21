# Build & Verification Environment

## Editable Files
- `code/bsg_async_fifo.sv`
- `code/bsg_async_ptr_gray.sv`
- `code/bsg_mem_1r1w.sv`
- `constraints/bsg_async_fifo.sdc`

All other files under `code/` and `lib/` are read-only collateral and must not be modified.

## Available Tools
- **Icarus Verilog (`iverilog -g2012` / `vvp`)**:
  ```bash
  iverilog -g2012 -I code -s tb -o sim.vvp \
    code/bsg_and.sv code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
    code/bsg_launch_sync_sync.sv code/bsg_async_ptr_gray.sv code/bsg_async_fifo.sv tb.sv
  vvp sim.vvp
  ```
- **Yosys + Slang (`yosys -p "plugin -i slang; ..."`)** with `-DSYNTHESIS -DYOSYS -I code` and `lib/NangateOpenCellLibrary_typical.lib`.
- **OpenROAD / OpenSTA (`openroad -exit`)** with `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib`.
- Note: `constraints/bsg_async_fifo.sdc` must use pure standard SDC commands only.
