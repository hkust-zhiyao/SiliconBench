# Build & Verification Guide

## Workspace Layout
- **Editable RTL**:
  - `code/axil_crossbar.v`
  - `code/axil_crossbar_addr.v`
  - `code/axil_crossbar_wr.v`
  - `code/axil_crossbar_rd.v`
- **Read-Only Collateral** (must remain unmodified):
  - `code/arbiter.v`
  - `code/priority_encoder.v`
  - `code/axil_register_wr.v`
  - `code/axil_register_rd.v`
  - `code/COPYING`

## Toolchain Commands
1. **Icarus Verilog Compilation & Simulation**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp <your_tb.sv> \
     code/priority_encoder.v code/arbiter.v \
     code/axil_register_wr.v code/axil_register_rd.v \
     code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v
   vvp sim.vvp
   ```

2. **Verilator Lint & Simulation**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --lint-only -Wall -Wno-fatal --top-module axil_crossbar \
     code/priority_encoder.v code/arbiter.v \
     code/axil_register_wr.v code/axil_register_rd.v \
     code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v
   ```

3. **Yosys Synthesis, Loop/Latch Check & Initializer-Stripped Gate-Level Netlist**:
   ```bash
   yosys -p "
     read_verilog code/priority_encoder.v code/arbiter.v code/axil_register_wr.v code/axil_register_rd.v code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v;
     hierarchy -check -top axil_crossbar;
     proc; setattr -unset init w:*; flatten;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top axil_crossbar;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v
   "
   ```
   Simulate `netlist.v` with `/opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v`.

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add new simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).
