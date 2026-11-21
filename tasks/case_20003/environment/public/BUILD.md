# Build & Verification Guide

## Workspace Files
- **Editable RTL**: `code/biriscv_npc.v`, `code/biriscv_fetch.v`
- **Read-Only Context RTL**: `code/biriscv_frontend.v`, `code/biriscv_decode.v`, `code/biriscv_decoder.v`, `code/biriscv_exec.v`, `code/biriscv_issue.v`, `code/biriscv_defs.v`

## Tooling Examples
```bash
# Structural / synthesis check (zero latches, zero combinational loops)
yosys -p "
  read_verilog -sv -DSYNTHESIS -Icode code/biriscv_defs.v code/biriscv_npc.v code/biriscv_fetch.v code/biriscv_decoder.v code/biriscv_decode.v code/biriscv_frontend.v;
  hierarchy -check -top biriscv_frontend -chparam SUPPORT_MMU 1 -chparam GSHARE_ENABLE 1;
  proc; opt_expr; check -assert;
  select -assert-none t:\$dlatch*
"

# Verilator elaboration & simulation
verilator --binary -sv -Wno-fatal -Icode --top-module biriscv_frontend \
  code/biriscv_defs.v code/biriscv_npc.v code/biriscv_fetch.v code/biriscv_decoder.v code/biriscv_decode.v code/biriscv_frontend.v
```
