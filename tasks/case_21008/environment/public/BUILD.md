The parameterized AXI4 width adapter RTL in `code/` comes from `alexforencich/verilog-axi` commit `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` (`code/COPYING`, MIT License).

Editable files:
- `code/axi_adapter.v`
- `code/axi_adapter_rd.v`
- `code/axi_adapter_wr.v`

Read-only support files (must remain unmodified):
- `code/COPYING`

For quick local multi-parameter elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/adap_chk.vvp code/*.v

# Verilator lint/elaboration check (upsize & downsize)
verilator --lint-only -Wno-fatal -GS_DATA_WIDTH=32 -GM_DATA_WIDTH=128 -GFORWARD_ID=1 -GCONVERT_NARROW_BURST=1 --top-module axi_adapter code/*.v
verilator --lint-only -Wno-fatal -GS_DATA_WIDTH=128 -GM_DATA_WIDTH=32 -GFORWARD_ID=1 --top-module axi_adapter code/*.v

# Yosys elaboration and latch-free synthesis check
yosys -p "read_verilog code/*.v; chparam -set S_DATA_WIDTH 64 -set M_DATA_WIDTH 256 -set FORWARD_ID 1 -set CONVERT_NARROW_BURST 1 axi_adapter; hierarchy -check -top axi_adapter; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```
