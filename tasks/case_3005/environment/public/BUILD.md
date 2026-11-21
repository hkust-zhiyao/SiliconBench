# Build and Verification Guide

## Editable Files
- `code/cv32e40p_hwloop_regs.sv`
- `code/cv32e40p_apu_disp.sv`
- `constraints.json`

Do not modify `code/top.sv`, `code/LICENSE`, or any file in `lib/` (`lib/NangateOpenCellLibrary_typical.lib`, `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, `lib/LICENSE.Nangate45`).

## Simulation & Synthesis Toolchain
- **Verilator (`verilator-v5.038`)**:
  ```bash
  verilator --binary --timing -Wno-fatal --top-module top \
    code/cv32e40p_hwloop_regs.sv code/cv32e40p_apu_disp.sv code/top.sv
  ```
- **Yosys + Slang (`oss-cad-suite/bin/yosys`)**:
  ```bash
  yosys -m slang -Q -p "read_slang --top top code/cv32e40p_hwloop_regs.sv code/cv32e40p_apu_disp.sv code/top.sv; hierarchy -check -top top; proc; opt_clean; select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*; synth -top top; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; check -assert; write_verilog -noattr /tmp/mapped.v"
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
create_clock -period <8_or_10> [get_ports clk_i]
set_input_delay 3.25 -clock clk_i [get_ports {<all_non_clock_inputs>}]
set_output_delay 2.75 -clock clk_i [get_ports {<all_outputs>}]
```
with `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib` in OpenROAD (`openroad -exit`).
