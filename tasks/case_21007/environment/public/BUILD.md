The AXI4 crossbar RTL in `code/` comes from `alexforencich/verilog-axi` commit `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` (`code/COPYING`, MIT License), with `AGEING_LIMIT`, `HIGH_QOS_MIN`, and `QOS_RESERVE` parameter stubs exposed on `axi_crossbar`, `axi_crossbar_wr`, `axi_crossbar_rd`, and `axi_crossbar_addr`.

Editable files:
- `code/axi_crossbar.v`
- `code/axi_crossbar_addr.v`
- `code/axi_crossbar_rd.v`
- `code/axi_crossbar_wr.v`
- `code/arbiter.v`

Read-only support files (must remain unmodified):
- `code/axi_register_rd.v`
- `code/axi_register_wr.v`
- `code/priority_encoder.v`
- `code/COPYING`

For quick local elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/xbar_chk.vvp code/*.v

# Verilator lint/elaboration check
verilator --lint-only -Wno-fatal --top-module axi_crossbar code/*.v

# Yosys elaboration and latch-free check
yosys -p "read_verilog code/*.v; chparam -set S_COUNT 4 -set M_COUNT 2 -set AGEING_LIMIT 4 -set HIGH_QOS_MIN 8 -set QOS_RESERVE 2 axi_crossbar; hierarchy -check -top axi_crossbar; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```
