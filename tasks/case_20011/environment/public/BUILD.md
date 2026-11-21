# Build & Verification Guide

## Workspace Files
- **Editable RTL**: `code/biriscv_mmu.v`
- **Read-Only Context RTL**: `code/biriscv_defs.v`, `code/biriscv_lsu.v`, `code/biriscv_fetch.v`, `code/biriscv_csr.v`

## Tooling Examples
```bash
# Yosys synthesis & latch/loop check
yosys -p "
  read_verilog -sv -DSYNTHESIS -Icode code/biriscv_defs.v code/biriscv_mmu.v;
  hierarchy -check -top biriscv_mmu -chparam SUPPORT_MMU 1;
  proc; opt_expr; check -assert;
  select -assert-none t:\$dlatch*
"

# Verilator lint check
verilator --lint-only -sv -Wno-fatal -Icode --top-module biriscv_mmu code/biriscv_defs.v code/biriscv_mmu.v
```
