# Build & Verification Environment

## Source Files (`code/`)
- Packages & clock gate cell (read-only):
  - `code/fpnew_pkg.sv`
  - `code/hci_package.sv`
  - `code/hwpe_ctrl_package.sv`
  - `code/hwpe_stream_package.sv`
  - `code/redmule_pkg.sv`
  - `code/tc_clk.sv`
- Target RTL modules (editable):
  - `code/x_buffer/redmule_x_pad_scm.sv`
  - `code/x_buffer/redmule_x_buffer_scm.sv`
  - `code/x_buffer/redmule_x_buffer.sv`

## Available Toolchain Commands
1. **SystemVerilog Lint & Functional Simulation (`verilator`)**:
   ```bash
   verilator --lint-only -Wall -Wno-fatal \
     code/fpnew_pkg.sv code/hci_package.sv code/hwpe_ctrl_package.sv \
     code/hwpe_stream_package.sv code/redmule_pkg.sv code/tc_clk.sv \
     code/x_buffer/redmule_x_pad_scm.sv code/x_buffer/redmule_x_buffer_scm.sv \
     code/x_buffer/redmule_x_buffer.sv --top-module redmule_x_buffer
   ```

2. **Elaboration & Gate-Level Synthesis (`yosys -m slang`)**:
   ```bash
   yosys -m slang -p "
     read_slang --top redmule_x_buffer -GHeight=4 -GWidth=4 -GDataW=256 -GUseLatches=1 \
       code/fpnew_pkg.sv code/hci_package.sv code/hwpe_ctrl_package.sv \
       code/hwpe_stream_package.sv code/redmule_pkg.sv code/tc_clk.sv \
       code/x_buffer/redmule_x_pad_scm.sv code/x_buffer/redmule_x_buffer_scm.sv \
       code/x_buffer/redmule_x_buffer.sv;
     synth -top redmule_x_buffer;
     check -assert;
     write_verilog -noattr netlist_lat1.v
   "
   ```

3. **4-State Gate-Level Simulation (`iverilog` + Yosys `simcells.v`)**:
   ```bash
   SIMCELLS="$(dirname "$(dirname "$(which yosys)")")/share/yosys/simcells.v"
   iverilog -g2012 -o gl_sim.vvp "$SIMCELLS" netlist_lat1.v your_gl_tb.sv
   vvp gl_sim.vvp
   ```
