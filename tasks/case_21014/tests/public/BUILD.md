The AXI4-Stream COBS framing and frame-length adjuster RTL in `code/` comes from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause License).

Editable files:
- `code/axis_cobs_encode.v`
- `code/axis_cobs_decode.v`
- `code/axis_frame_length_adjust.v`

Read-only support files (must remain unmodified):
- `code/axis_fifo.v`
- `code/LICENSE`

For quick local elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/cobs_chk.vvp code/*.v

# Verilator lint/elaboration check
verilator --lint-only -Wno-fatal -GDATA_WIDTH=64 --top-module axis_frame_length_adjust code/axis_frame_length_adjust.v

# Yosys elaboration and latch-free synthesis check
yosys -p "read_verilog code/*.v; chparam -set DATA_WIDTH 64 axis_frame_length_adjust; hierarchy -check -top axis_frame_length_adjust; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```
