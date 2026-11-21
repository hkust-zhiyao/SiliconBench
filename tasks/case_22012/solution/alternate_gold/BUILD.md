# Build and Verification Environment

## Editable RTL Files
Only the following files may be modified:
- `code/fixed_p_rounding.sv`
- `code/simd_alu.sv`
- `code/valu.sv`

All package definitions and support modules under `code/` (`ara_pkg.sv`, `rvv_pkg.sv`, `cf_math_pkg.sv`, `spill_register.sv`, `include/common_cells/*`) are read-only context.

## Toolchain Commands

### 1. Functional RTL Simulation (Verilator)
```bash
verilator \
  --binary -j 4 -Wno-fatal --timing -sv \
  +incdir+code/include \
  code/cf_math_pkg.sv code/riscv_pkg.sv code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv \
  code/fpnew_pkg.sv code/rvv_pkg.sv code/ara_pkg.sv \
  code/spill_register_flushable.sv code/spill_register.sv \
  code/fixed_p_rounding.sv code/simd_alu.sv code/valu.sv \
  <your_tb.sv> --top-module <top>
```

### 2. Synthesis Elaboration & Gate-Level Netlist Generation (`yosys -m slang`)
```bash
yosys -m slang -p "
  read_slang --top <syn_wrapper> -I code/include \
    code/cf_math_pkg.sv code/riscv_pkg.sv code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv \
    code/fpnew_pkg.sv code/rvv_pkg.sv code/ara_pkg.sv \
    code/spill_register_flushable.sv code/spill_register.sv \
    code/fixed_p_rounding.sv code/simd_alu.sv code/valu.sv <syn_wrapper.sv>;
  synth -top <syn_wrapper>;
  write_verilog -noattr netlist.v
"
```

### 3. 4-State Gate-Level Simulation (`iverilog -g2012`)
```bash
iverilog -g2012 \
  -o sim_gl.out \
  /opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v \
  netlist.v <gl_tb.sv>
vvp sim_gl.out
```
