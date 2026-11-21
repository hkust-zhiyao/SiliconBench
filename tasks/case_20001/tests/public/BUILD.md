# Build & Verification Guide

## Source Files
- **Editable RTL**: `code/biriscv_issue.v`
- **Read-Only Context RTL**: `code/biriscv_defs.v`, `code/biriscv_pipe_ctrl.v`, `code/biriscv_regfile.v`, `code/biriscv_xilinx_2r1w.v`, `code/biriscv_exec.v`, `code/biriscv_alu.v`, `code/biriscv_decoder.v`, `code/biriscv_trace_sim.v`

## Example Compilation & Lint Commands

### Verilator Lint / Elaboration
```bash
verilator --lint-only -Wall -Wno-fatal -DSYNTHESIS -Icode \
  code/biriscv_issue.v code/biriscv_pipe_ctrl.v code/biriscv_regfile.v \
  code/biriscv_xilinx_2r1w.v code/biriscv_trace_sim.v \
  --top-module biriscv_issue
```

### Yosys Structural & Latch Check
```bash
yosys -p "read_verilog -Icode code/biriscv_issue.v code/biriscv_pipe_ctrl.v code/biriscv_regfile.v code/biriscv_xilinx_2r1w.v; hierarchy -check -top biriscv_issue; proc; check -assert"
```
