# Build and Verification Instructions

## 1. Editable Files
Only the following four files are collected and graded:
- `code/cv32e41p_sleep_unit.sv`
- `code/cv32e41p_int_controller.sv`
- `code/cv32e41p_hwloop_regs.sv`
- `code/cv32e41p_controller.sv`

All other files in `code/` (`cv32e41p_pkg.sv`, `cv32e41p_ctrl_subsystem.sv`, `LICENSE`) and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and run your own testbench against `cv32e41p_ctrl_subsystem` (`PULP_CLUSTER = 1`, `PULP_XPULP = 1`, `PULP_SECURE = 1`, `N_HWLP = 2`) using Verilator:

```bash
verilator \
  --binary --timing -j 1 -Wno-fatal \
  --top-module <your_tb_top> \
  code/cv32e41p_pkg.sv \
  code/cv32e41p_sleep_unit.sv \
  code/cv32e41p_int_controller.sv \
  code/cv32e41p_hwloop_regs.sv \
  code/cv32e41p_controller.sv \
  code/cv32e41p_ctrl_subsystem.sv \
  <your_tb.sv>

./obj_dir/V<your_tb_top>
```

## 3. Logic Synthesis & Area Checks (`Yosys + Slang`)
1. Synthesize `cv32e41p_int_controller` (`PULP_SECURE = 1`) to Nangate45 and verify zero latches and mapped cell area `<= 181.5 um^2`:

```bash
yosys -m slang -p "
  read_slang --ignore-assertions --top cv32e41p_int_controller -G PULP_SECURE=1 \
    code/cv32e41p_pkg.sv \
    code/cv32e41p_int_controller.sv
  hierarchy -check -top cv32e41p_int_controller
  proc; opt_clean
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*
  synth -top cv32e41p_int_controller -flatten
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
"
```

2. Synthesize `cv32e41p_ctrl_subsystem` (default parameters `PULP_CLUSTER = 1, PULP_XPULP = 1, PULP_SECURE = 1, N_HWLP = 2`) to Nangate45 and verify zero latches and mapped cell area `<= 3,290.0 um^2`:

```bash
yosys -m slang -p "
  read_slang --ignore-assertions --top cv32e41p_ctrl_subsystem \
    code/cv32e41p_pkg.sv \
    code/cv32e41p_sleep_unit.sv \
    code/cv32e41p_int_controller.sv \
    code/cv32e41p_hwloop_regs.sv \
    code/cv32e41p_controller.sv \
    code/cv32e41p_ctrl_subsystem.sv
  hierarchy -check -top cv32e41p_ctrl_subsystem
  proc; opt_clean
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*
  synth -top cv32e41p_ctrl_subsystem -flatten
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```

## 4. Static Timing Analysis (`OpenROAD`)
Verify setup slack (`WNS >= 0.00 ns`) and hold slack (`WHS >= 0.00 ns`) on `cv32e41p_ctrl_subsystem` at a `1.95 ns` clock period:

```bash
sed 's/ signed / /g' mapped.v > sta.v
cat > sta.tcl << 'EOF'
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design cv32e41p_ctrl_subsystem
create_clock -name clk -period 1.95 [get_ports {clk clk_ungated_i}]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_n]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
EOF
openroad -exit sta.tcl
```
