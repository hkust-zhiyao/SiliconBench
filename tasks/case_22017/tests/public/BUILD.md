# Build, Simulation, Gate-Level, and Timing Signoff Guide

## 1. Workspace Layout & Editable Scope

- **Editable RTL files** (modify **only** these two files):
  - `code/sldu.sv` (`module sldu`)
  - `code/p2_stride_gen.sv` (`module p2_stride_gen`)
- **Read-only RTL & package closure** (`code/`):
  - `code/sldu_subsys_top.sv`: Parameterized verification and synthesis wrapper (`NrLanes = 2, 4, 8`, `VLEN = 1024`) instantiating `sldu` (`i_sldu`), `p2_stride_gen`, and `sldu_op_dp`.
  - `code/sldu_op_dp.sv`, `code/lzc.sv`, `code/popcount.sv`, `code/spill_register_flushable.sv`, `code/spill_register.sv`
  - `code/cf_math_pkg.sv`, `code/config_pkg.sv`, `code/cv64a6_imafdcv_sv39_config_pkg.sv`, `code/riscv_pkg.sv`, `code/ariane_pkg.sv`, `code/axi_pkg.sv`, `code/fpnew_pkg.sv`, `code/rvv_pkg.sv`, `code/ara_pkg.sv`, and `code/include/common_cells/{registers.svh,assertions.svh}`
- **Read-only Nangate45 PDK collateral** (`lib/`):
  - `lib/NangateOpenCellLibrary_typical.lib` (`1 ns`, `1 fF`, area in `um^2`)
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## 2. Multi-Parameter Functional Simulation (Verilator)

```bash
FILES="code/cf_math_pkg.sv code/config_pkg.sv code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/riscv_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
  code/rvv_pkg.sv code/ara_pkg.sv code/lzc.sv code/popcount.sv \
  code/spill_register_flushable.sv code/spill_register.sv \
  code/p2_stride_gen.sv code/sldu_op_dp.sv code/sldu.sv code/sldu_subsys_top.sv"

verilator \
  --binary --timing -j 4 -Wno-fatal --top-module tb -Icode/include ${FILES} tb.sv
./obj_dir/Vtb
```

## 3. Multi-Lane Elaboration, Zero-Latch, & 4-State Gate-Level Signoff (`yosys -m slang` + `iverilog`)

Elaborate across `NrLanes = 2, 4, 8` (`VLEN = 1024`) with zero inferred latches and run 4-state gate-level simulation on `NrLanes = 2`:

```bash
TOOLS=/opt/siliconbench/tools
$TOOLS/oss-cad-suite/bin/yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode/include -GNrLanes=2 -GVLEN=1024 --top sldu_subsys_top --ignore-assertions ${FILES};
  hierarchy -check -top sldu_subsys_top; proc; opt_clean; check -assert;
  synth -top sldu_subsys_top -noabc; opt_clean; write_verilog -noattr gl_l2.v
"
$TOOLS/iverilog-v13/bin/iverilog -g2012 -DNRLANES=2 -o gl_l2.vvp \
  $TOOLS/oss-cad-suite/share/yosys/simcells.v gl_l2.v tb_gl.sv
$TOOLS/iverilog-v13/bin/vvp gl_l2.vvp
```

## 4. Nangate45 Mapped Synthesis Signoff (`NrLanes = 4, VLEN = 1024`)

```bash
$TOOLS/oss-cad-suite/bin/yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode/include -GNrLanes=4 -GVLEN=1024 --top sldu_subsys_top --ignore-assertions ${FILES};
  hierarchy -check -top sldu_subsys_top; proc; opt_clean; check -assert;
  synth -top sldu_subsys_top -noabc;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 4800;
  opt_clean; stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr netlist_l4.v
"
```

Sign-off requirements:
1. Zero inferred latches and clean `check -assert` across all `NrLanes = {2, 4, 8}` (`VLEN = 1024`) elaborations.
2. Clean 4-state gate-level simulation (`NrLanes = 2`) with zero `X`/`Z` on control outputs.
3. Mapped Nangate45 cell area at `NrLanes = 4, VLEN = 1024` **`<= 60000.0 um^2`**.
