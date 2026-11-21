# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Workspace Layout and Editable Scope

- **Editable RTL files** (edit ONLY these two files):
  - `code/vmfpu.sv`: Ara per-lane multi-phase vector multiplier/divider functional unit (`module vmfpu`).
  - `code/simd_div.sv`: Ara per-lane 64-bit SIMD serial integer divider wrapper (`module simd_div`).
- **Read-only RTL and package closure** (`code/`):
  - `code/vmfpu_synth_top.sv`: Concrete lane synthesis/verification wrapper instantiating `vmfpu` with `NrLanes = 4`, `VLEN = 4096`, `FPUSupport = FPUSupportNone`, `FPExtSupport = FPExtSupportNone`, `FixPtSupport = FixedPointEnable`.
  - `code/simd_mul.sv`, `code/serdiv.sv`, `code/power_gating_generic.sv`, `code/tc_clk.sv`, `code/lzc.sv`, `code/spill_register.sv`, `code/spill_register_flushable.sv`: Read-only arithmetic and common-cell submodules.
  - `code/cf_math_pkg.sv`, `code/config_pkg.sv`, `code/cv64a6_imafdcv_sv39_config_pkg.sv`, `code/riscv_pkg.sv`, `code/ariane_pkg.sv`, `code/axi_pkg.sv`, `code/fpnew_pkg.sv`, `code/rvv_pkg.sv`, `code/ara_pkg.sv`, and `code/include/common_cells/{registers.svh,assertions.svh}`: Read-only SystemVerilog packages and headers.
- **Read-only Nangate45 PDK collateral** (`lib/`):
  - `lib/NangateOpenCellLibrary_typical.lib` (`1 ns`, `1 fF`, area in `um^2`)
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

Do not modify any file outside `code/vmfpu.sv` and `code/simd_div.sv`.

## 2. Functional & Latency Simulation (Verilator)

Compile the RTL closure in package-dependency order using Verilator (`verilator-v5.038`):

```bash
verilator \
  --binary --timing -j 4 -Wno-fatal --top-module tb \
  -Icode/include \
  code/cf_math_pkg.sv \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/lzc.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/tc_clk.sv \
  code/power_gating_generic.sv \
  code/serdiv.sv \
  code/simd_mul.sv \
  code/simd_div.sv \
  code/vmfpu.sv \
  code/vmfpu_synth_top.sv \
  tb.sv
./obj_dir/Vtb
```

## 3. Deterministic Nangate45 Logic Synthesis (Yosys + Slang)

Synthesize `vmfpu_synth_top` with Yosys (`-m slang`) and ABC mapped to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
FILES="code/cf_math_pkg.sv code/config_pkg.sv code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
  code/rvv_pkg.sv code/ara_pkg.sv code/lzc.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/tc_clk.sv code/power_gating_generic.sv \
  code/serdiv.sv code/simd_mul.sv code/simd_div.sv code/vmfpu.sv code/vmfpu_synth_top.sv"

yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode/include --top vmfpu_synth_top --ignore-assertions ${FILES};
  hierarchy -check -top vmfpu_synth_top;
  proc;
  check -assert;
  synth -top vmfpu_synth_top -noabc;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -script +strash;dc2;map;
  opt_clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr netlist.v
"
```

Sign-off requirements for synthesis:
1. `proc; check -assert;` must pass with zero combinational logic loops or undriven/multiple-driver errors.
2. Total mapped cell area reported by `Chip area for module '\vmfpu_synth_top':` must be **`<= 83600.0` `um^2`**.

## 4. Static Timing Analysis (OpenROAD)

Evaluate setup and hold timing on the synthesized `netlist.v` with OpenROAD (`sta.tcl`):

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist.v
link_design vmfpu_synth_top
create_clock -name clk_i -period 5.20 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
puts "=== SETUP ==="
report_checks -path_delay max -group_path_count 5 -digits 3
puts "=== HOLD ==="
report_checks -path_delay min -group_path_count 5 -digits 3
```

Run:

```bash
openroad -exit sta.tcl
```

Sign-off requirements for timing:
- Worst setup slack (`-path_delay max`) must be **`>= 0.000 ns`** at `clk_i` period `5.20 ns`.
- Worst hold/removal slack (`-path_delay min`) must be **`>= 0.000 ns`**.
