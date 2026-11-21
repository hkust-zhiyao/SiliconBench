# Build, Simulation, Synthesis, and Static Timing Guide (`veer_ifu_aln_bp_top`)

## 1. Editable Files
Only the following five files are collected and graded:
- `code/ifu_aln_ctl.sv`
- `code/ifu_compress_ctl.sv`
- `code/ifu_bp_ctl.sv`
- `code/ifu_ifc_ctl.sv`
- `constraints.json`

All other files in `code/` (`veer_ifu_aln_bp_top.sv`, `beh_lib.sv`, `veer_types.sv`, `common_defines.vh`, `global.h`, `LICENSE`) and `lib/` are read-only.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary -j 2 -Wno-fatal --top-module <your_tb> -Icode \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/ifu_compress_ctl.sv code/ifu_aln_ctl.sv code/ifu_bp_ctl.sv \
  code/ifu_ifc_ctl.sv code/veer_ifu_aln_bp_top.sv <your_tb.sv> \
  --Mdir obj_dir -o sim_tb
./sim_tb
```

## 3. Synthesis & Latch Check (`Yosys/Slang`)
```bash
yosys -m slang -p "
  read_slang --single-unit --top veer_ifu_aln_bp_top -Icode \
    code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
    code/ifu_compress_ctl.sv code/ifu_aln_ctl.sv code/ifu_bp_ctl.sv \
    code/ifu_ifc_ctl.sv code/veer_ifu_aln_bp_top.sv;
  hierarchy -check -top veer_ifu_aln_bp_top;
  proc;
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr* t:\$_DLATCH* */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  opt_clean;
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr* t:\$_DLATCH* */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top veer_ifu_aln_bp_top;
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

## 4. Static Timing Analysis (`OpenROAD`) & `constraints.json` Schema
`constraints.json` must contain keys `"clocks"`, `"clock_groups"`, `"false_paths"`, `"input_delays"`, `"output_delays"`, `"max_delays"`, and `"multicycle_paths"`.
- `"clocks"`: `{"clk": {"period_ns": 10.0, "waveform_ns": [0.0, 5.0]}}`
- `"clock_groups"`, `"false_paths"`, `"multicycle_paths"`: `[]`
- `"input_delays"` / `"output_delays"`: `0.2` ns on all non-clock inputs and outputs relative to `"clk"`.
- `"max_delays"`: two entries constraining `{"from": ["ghr_in"], "to": ["ghr_out"], "delay_ns": <float>}` and `{"from": ["ras_in"], "to": ["ras_out"], "delay_ns": <float>}` with `0.0 < delay_ns <= 3.0`.
