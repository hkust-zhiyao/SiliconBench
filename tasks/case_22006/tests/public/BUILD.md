# Build & Verification Environment

## Editable Files
- `code/redmule_inst_decoder.sv`
- `code/redmule_ctrl.sv`

All other files in `code/` (including `redmule_pkg.sv`, `redmule_xif_pkg.sv`, `redmule_config_fifo.sv`, `redmule_tiler.sv`, `redmule_xif_offload_subsys.sv`, and `include/common_cells/*.svh`) are read-only reference collateral. Preserve the module declarations, parameter lists, and port interfaces of `redmule_inst_decoder` and `redmule_ctrl`.

## Available Toolchain
- **Verilator (`v5.038`)**: `verilator`
- **Yosys + Slang (`yosys -m slang`)**: `yosys`

## Example Elaboration & Lint Commands

### 1. Verilator Elaboration & Lint
```bash
verilator \
  --lint-only -sv -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  +incdir+code/include \
  code/cf_math_pkg.sv code/fpnew_pkg.sv code/hci_package.sv \
  code/hwpe_ctrl_package.sv code/hwpe_stream_package.sv \
  code/redmule_pkg.sv code/redmule_xif_pkg.sv \
  code/tc_clk.sv code/redmule_config_fifo.sv code/redmule_tiler.sv \
  code/redmule_ctrl.sv code/redmule_inst_decoder.sv \
  code/redmule_xif_offload_subsys.sv \
  --top-module redmule_xif_offload_subsys
```

### 2. Yosys + Slang Synthesis Sanity Check
```bash
yosys -m slang -p "
  read_slang --top redmule_xif_offload_subsys -I code/include \
    code/cf_math_pkg.sv code/fpnew_pkg.sv code/hci_package.sv \
    code/hwpe_ctrl_package.sv code/hwpe_stream_package.sv \
    code/redmule_pkg.sv code/redmule_xif_pkg.sv \
    code/tc_clk.sv code/redmule_config_fifo.sv code/redmule_tiler.sv \
    code/redmule_ctrl.sv code/redmule_inst_decoder.sv \
    code/redmule_xif_offload_subsys.sv;
  hierarchy -check -top redmule_xif_offload_subsys;
  proc; opt; check
"
```
