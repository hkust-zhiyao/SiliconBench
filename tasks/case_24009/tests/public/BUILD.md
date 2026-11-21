# Build & Verification Environment

## Editable Files
- `code/util_cpack2_impl.v`
- `code/util_upack2_impl.v`
- `code/pack_shell.v`
- `code/pack_ctrl.v`
- `code/pack_network.v`

All other files under `code/` (`ad_perfect_shuffle.v`, `pack_interconnect.v`, `util_pipeline_stage.v`) and `lib/` are read-only collateral.

## Available Tools
- **Verilator (`verilator --binary --timing -Wno-fatal`)** for multi-parameter matrix verification.
- **Icarus Verilog (`iverilog -g2012` / `vvp`)** for 4-state RTL & gate-level `X`-propagation parity verification.
- **Yosys + Slang (`yosys -m slang`)** for standard-cell synthesis, latch checking, and gate-level netlist generation against `lib/NangateOpenCellLibrary_typical.lib`.
