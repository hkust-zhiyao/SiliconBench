# Build & Verification Guide

## Workspace Layout
- **Editable RTL**:
  - `code/axi_vfifo.v`
  - `code/axi_vfifo_enc.v`
  - `code/axi_vfifo_dec.v`
  - `code/axi_vfifo_raw.v`
  - `code/axi_vfifo_raw_wr.v`
  - `code/axi_vfifo_raw_rd.v`
- **Read-Only Collateral** (must remain unmodified):
  - `code/COPYING`

## Toolchain Commands
1. **Icarus Verilog Compilation & Simulation**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp <your_tb.sv> \
     code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v \
     code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v
   vvp sim.vvp
   ```

2. **Verilator Lint & Simulation**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --lint-only -Wall -Wno-fatal --top-module axi_vfifo \
     code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v \
     code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v
   ```

3. **Yosys Synthesis, Loop/Latch Check & Initializer-Stripped Gate-Level Netlist**:
   ```bash
   yosys -p "
     read_verilog -defer -sv code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v;
     hierarchy -check -top axi_vfifo -chparam AXI_CH 1 -chparam AXI_DATA_WIDTH 64 -chparam AXI_STRB_WIDTH 8 -chparam AXI_ADDR_WIDTH 10 -chparam LEN_WIDTH 10 -chparam AXIS_DATA_WIDTH 32 -chparam AXIS_KEEP_WIDTH 4 -chparam MAX_SEG_WIDTH 32 -chparam WRITE_FIFO_DEPTH 16 -chparam WRITE_MAX_BURST_LEN 4 -chparam READ_FIFO_DEPTH 32 -chparam READ_MAX_BURST_LEN 4;
     proc; opt_expr; opt_clean; setattr -unset init w:*; flatten; opt_expr; opt_clean;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top axi_vfifo;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v
   "
   ```
   Simulate `netlist.v` with `/opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v` (in grading, `$error(` inside upstream `initial` parameter assertions is sanitized to `$display(` prior to Yosys elaboration).

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).
