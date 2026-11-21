# Build & Signoff Reference

## Editable Files
- `code/int_sum_block.v`
- `code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v`
- `code/NV_NVDLA_CDP_DP_INTP_unit.v`

## Read-Only Subsystem & Collateral
- Enclosing subsystem top: `code/NV_NVDLA_CDP_dp.v` and supporting CDP/HLS/FIFO/RAM modules in `code/`
- Standard-cell Liberty / LEF:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Unit & End-to-End Subsystem Verification (`Verilator v5.038`)**:
   - Compile `code/*.v` with `-DSYNTHESIS -DVLIB_BYPASS_POWER_CG -DNV_FPGA_FIFOGEN -DVERILINT -Icode` and verify `int_sum_block`, `NV_NVDLA_CDP_DP_LUT_CTRL_unit`, `NV_NVDLA_CDP_DP_INTP_unit`, and full `NV_NVDLA_CDP_dp` streaming across `INT8`, `INT16`, and `FP16` cubes under randomized backpressure.
2. **Yosys Synthesis, 4-State Gate-Level Hygiene & Nangate45 Area/STA Signoff**:
   - Synthesize each editable unit (`int_sum_block`, `NV_NVDLA_CDP_DP_LUT_CTRL_unit` + `HLS_fp32_sub.v`, and `NV_NVDLA_CDP_DP_INTP_unit` + `HLS_fp32_sub.v` / `HLS_fp32_to_fp17.v` / `HLS_fp17_mul.v` / `HLS_fp17_add.v`) using `yosys -m slang` (`read_slang -DSYNTHESIS -DVLIB_BYPASS_POWER_CG -DNV_FPGA_FIFOGEN -DVERILINT -Icode ...`), asserting zero inferred latches (`$dlatch*`, `$_DLATCH_*`) and zero combinational loops (`scc -expect 0`), and verify 4-state gate-level reset/functional behavior in `iverilog -g2012`.
   - Map each unit to `lib/NangateOpenCellLibrary_typical.lib` (`dfflibmap -liberty` + `abc -liberty ... -D 1800`) and check cell area (`int_sum_block <= 6100.0 um^2`, `NV_NVDLA_CDP_DP_LUT_CTRL_unit <= 27500.0 um^2`, 3-unit sum `<= 59000.0 um^2`).
   - Run OpenROAD STA (`read_lef`, `read_liberty`, `read_verilog`) at `3.80 ns` clock period (`0.25 ns` input/output delays on non-clock ports, `set_false_path -from [get_ports *rst*]`), requiring setup `WNS >= 0.0000 ns` on all 3 units.
