# Build & Verification Reference

## Workspace Files
- **Editable RTL**:
  - `code/arp.v` (`arp`)
  - `code/arp_cache.v` (`arp_cache`)
  - `code/arp_eth_rx.v` (`arp_eth_rx`)
  - `code/arp_eth_tx.v` (`arp_eth_tx`)
- **Read-Only Collateral**:
  - `code/lfsr.v` (`lfsr`)
  - `code/LICENSE`

## Toolchain Commands
1. **Icarus Verilog (`iverilog` v13)**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v <your_tb.sv>
   vvp sim.vvp
   ```
2. **Verilator (`verilator` v5.038)**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --binary --timing -Wno-fatal -j 1 --top-module <your_tb> \
     code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v <your_tb.sv>
   ```
3. **Yosys Latch / Loop / Gate-Level Netlist Check**:
   ```bash
   yosys -p "
     read_verilog -defer code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v;
     hierarchy -check -top arp -chparam DATA_WIDTH 256 -chparam CACHE_ADDR_WIDTH 3;
     proc; opt_expr; opt_clean; setattr -unset init w:*; flatten; opt_expr; opt_clean;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top arp;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v"
   ```

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add new simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`, including inside `initial` parameter-check blocks — preserve or omit existing parameter checks rather than adding new `$finish`/`$stop` calls), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).
