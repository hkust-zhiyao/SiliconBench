# Build, Simulation, Synthesis, and Static Timing Guide (`veer_bus_dma_top`)

## 1. Editable Files
Only the following four files are collected and graded:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `code/dma_ctrl.sv`
- `constraints.json`

All other files in `code/` (`code/veer_bus_dma_top.sv`, `code/common_defines.vh`, `code/global.h`, `code/veer_types.sv`, `code/beh_lib.sv`, `code/LICENSE`) and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/dma_ctrl.sv \
  code/veer_bus_dma_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis & Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
1. **Synthesis (`Yosys/Slang`)**:
   ```bash
   yosys -m slang -p "
     read_slang --single-unit --top veer_bus_dma_top -Icode \
       code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
       code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/dma_ctrl.sv code/veer_bus_dma_top.sv;
     hierarchy -check -top veer_bus_dma_top;
     proc;
     select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
     opt_clean;
     select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
     synth -top veer_bus_dma_top;
     opt;
     dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
     abc -liberty lib/NangateOpenCellLibrary_typical.lib;
     clean;
     read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
     check -assert;
     stat -liberty lib/NangateOpenCellLibrary_typical.lib;
     write_verilog -noattr mapped.v
   "
   ```

2. **Declarative Timing Constraints (`constraints.json`) & Static Timing Analysis (`OpenROAD`)**:
   - `constraints.json` has a single top-level key `"max_delays"`, which is a list of rule objects `{"from": [...], "to": [...], "ns": <float>}`.
   - Allowed input port groups in `"from"` are the non-clock input port names of `veer_bus_dma_top` (or bit-indexed `qos_in[0..7]`, `region_in[0..7]`).
   - Allowed output port groups in `"to"` are the output port names of `veer_bus_dma_top` (or bit-indexed `qos_out[0..7]`, `region_out[0..7]`).
   - A group name without bit index selects all bits of that port. Each rule object is translated to:
     `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`
   - The STA flow retains the clock (`5.60 ns` or `6.00 ns` on `clk`), `set_input_delay 2.50 -clock clk [all_inputs -no_clocks]`, `set_output_delay 2.00 -clock clk [all_outputs]`, `set_load 5.0 [all_outputs]`, and `set_false_path -from [get_ports {rst_l scan_mode}]`. All delays are in `ns`.
