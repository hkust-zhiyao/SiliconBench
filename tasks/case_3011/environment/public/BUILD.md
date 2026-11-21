# Build and Verification Guide

## Editable Files
- `code/cv32e40p_int_controller.sv`
- `code/cv32e40p_sleep_unit.sv`
- `constraints.json`

Do not modify `code/top.sv`, `code/cv32e40p_sim_clock_gate.sv`, `code/include/cv32e40p_pkg.sv`, or `code/LICENSE`.

## Simulation & Synthesis Toolchain
- **Verilator (`verilator-v5.038`)**:
  ```bash
  verilator --binary --timing -Wno-fatal --top-module top \
    code/include/cv32e40p_pkg.sv code/cv32e40p_sim_clock_gate.sv \
    code/cv32e40p_int_controller.sv code/cv32e40p_sleep_unit.sv code/top.sv
  ```
- **Yosys + Slang (`oss-cad-suite/bin/yosys`)**:
  ```bash
  yosys -m slang -Q -p "read_slang --top top --keep-hierarchy code/include/cv32e40p_pkg.sv code/cv32e40p_sim_clock_gate.sv code/cv32e40p_int_controller.sv code/cv32e40p_sleep_unit.sv code/top.sv; hierarchy -check -top top; proc; opt_clean; select -assert-none cv32e40p_int_controller*/t:\$dlatch* cv32e40p_int_controller*/t:\$adlatch* cv32e40p_int_controller*/t:\$latch* cv32e40p_int_controller*/t:\$sr* cv32e40p_sleep_unit*/t:\$dlatch* cv32e40p_sleep_unit*/t:\$adlatch* cv32e40p_sleep_unit*/t:\$latch* cv32e40p_sleep_unit*/t:\$sr*; synth -top top; read_liberty -lib /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; dfflibmap -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; abc -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; clean; check -assert; write_verilog -noattr mapped.v"
  ```

## Declarative Timing Exceptions (`constraints.json`)
`constraints.json` must contain a single top-level key `"max_delays"` mapping to a list of rule objects:
```json
{
  "max_delays": [
    {
      "from": ["<input_port_or_bit>", ...],
      "to": ["<output_port_or_bit>", ...],
      "ns": <positive_float>
    }
  ]
}
```
Each rule is translated by the evaluation harness into:
```tcl
set_max_delay <ns> -from [get_ports {<from>}] -to [get_ports {<to>}]
```
after applying:
```tcl
create_clock -period <10_or_12> [get_ports clk_i]
set_input_delay 3.50 -clock clk_i [get_ports {<all_non_clock_inputs>}]
set_output_delay 2.75 -clock clk_i [get_ports {<all_outputs>}]
```
in OpenROAD (`openroad -exit`).
