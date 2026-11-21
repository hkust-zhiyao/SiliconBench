# Build and Verification Guide

## Editable File
- `code/cdc_reset_ctrlr.sv`

## Read-Only Context Files
- `code/cdc_reset_ctrlr_pkg.sv`
- `code/cdc_4phase.sv`
- `code/spill_register.sv`
- `code/spill_register_flushable.sv`
- `code/sync.sv`
- `code/common_cells/assertions.svh`

## Local Compilation & Synthesis Examples

### Verilator (v5.038)
```bash
verilator --binary --timing -Wno-fatal -DCOMMON_CELLS_ASSERTS_OFF -Icode \
  --top-module your_tb \
  code/cdc_reset_ctrlr_pkg.sv \
  code/sync.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/cdc_4phase.sv \
  code/cdc_reset_ctrlr.sv \
  your_tb.sv
./obj_dir/Vyour_tb
```

### Yosys + Slang Synthesis Check
```bash
yosys -p "plugin -i slang; read_slang -DCOMMON_CELLS_ASSERTS_OFF -DSYNTHESIS -I code \
  code/cdc_reset_ctrlr_pkg.sv code/sync.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/cdc_4phase.sv code/cdc_reset_ctrlr.sv \
  --top cdc_reset_ctrlr; hierarchy -check -top cdc_reset_ctrlr; proc; opt; check"
```
