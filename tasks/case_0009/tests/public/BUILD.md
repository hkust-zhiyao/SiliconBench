The package and micro-loop RTL come from `pulp-platform/hwpe-ctrl` commit `558fe3db3413909878c03aed543257d94a57bae5`. Compile `code/hwpe_ctrl_package.sv` before `code/hwpe_ctrl_uloop.sv`; Verilator supports the packed types used here. The source header in `code/hwpe_ctrl_uloop.sv` documents the microcode programming model, parameters, and `ctrl_i` / `flags_o` handshake interface.

`code/hwpe_ctrl_uloop.sv` is the only editable file; `code/hwpe_ctrl_package.sv` is read-only.

For a quick syntax and elaboration check from the workspace root, run:
```bash
verilator --lint-only -Wno-fatal -DSYNTHESIS --top-module hwpe_ctrl_uloop code/hwpe_ctrl_package.sv code/hwpe_ctrl_uloop.sv
```
