# case_6012: VeeR-EH1 IFU 8x16-bit Instruction Aligner, RVC Decompressor, Branch Predictor, Fetch Pipe, and Sideband Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-eh1` (`repo_06`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Task-Specific Multi-Corner Liberty & SDC Timing Views`
> - **Editable Files (`allowed_edits`)**: `code/ifu_aln_ctl.sv`, `code/ifu_compress_ctl.sv`, `code/ifu_bp_ctl.sv`, `code/ifu_ifc_ctl.sv`, `constraints.json`

---

## Problem Specification

# VeeR-EH1 IFU 8x16-bit Instruction Aligner, RVC Decompressor, Branch Predictor, Fetch Pipe, and Sideband Timing Closure

In `code/veer_ifu_aln_bp_top.sv`, the 8x16-bit 3-entry instruction aligner (`code/ifu_aln_ctl.sv`), the RISC-V 16-bit compressed instruction decompressor (`code/ifu_compress_ctl.sv`), the BTB/BHT/RAS branch predictor (`code/ifu_bp_ctl.sv`), the F1/F2 fetch pipe controller (`code/ifu_ifc_ctl.sv`), and two transparent 8-bit sideband pass-through buses (`ghr_in` to `ghr_out` and `ras_in` to `ras_out`) are integrated together.

Update only `code/ifu_aln_ctl.sv`, `code/ifu_compress_ctl.sv`, `code/ifu_bp_ctl.sv`, `code/ifu_ifc_ctl.sv`, and `constraints.json` to satisfy all functional, synthesis, and static timing contracts:

1. **RVC 16-bit Instruction Decompression (`code/ifu_compress_ctl.sv`)**:
   - Decode and expand 16-bit RISC-V compressed instructions (`din[15:0]`) into their 32-bit equivalents (`dout[31:0]`), including `C.ADDI16SP` (`simm9_4` signed immediate bit permutation `{i[12], i[4:3], i[5], i[2], i[6]}`) and `C.LWSP` (`ulwspimm7_2` unsigned word-aligned stack offset permutation `{i[3:2], i[12], i[6:4]}`).
   - Gate `dout[31:0]` to zero whenever `legal == 1'b0` so illegal 16-bit opcodes drive `32'h0000_0000` into the decode pipe while flagging illegality.

2. **8x16-bit Instruction Aligner, Spanning Access Faults, Illegal Opcode Lockout, & Error Mutual Exclusion (`code/ifu_aln_ctl.sv`)**:
   - Align up to two instructions (`ifu_i0_instr`, `ifu_i1_instr`) per cycle from the 3-entry fetch buffer (`f0`, `f1`, `f2`), supporting arbitrary mixes of 2-byte RVC and 4-byte instructions including 4-byte instructions that straddle the boundary between `f0` and `f1`.
   - When a 4-byte instruction in slot 0 has no access fault on its first halfword (`~icaf_eff[0]`) but has an access fault on its second halfword (`icaf_eff[1]`), assert both `ifu_i0_icaf` and `ifu_i0_icaf_second`.
   - Latch the first shifted illegal 16-bit instruction into `ifu_illegal_inst[15:0]` and lock out subsequent illegal 16-bit instructions (`illegal_lockout`) from overwriting `ifu_illegal_inst` until `exu_flush_final` is asserted.
   - Maintain mutual exclusion (`$onehot0`) between `ifu_icache_error_val` and `ifu_icache_sb_error_val` when slot 0 has a single-bit ICCM ECC error (`ifu_i0_sbecc`) and slot 1 simultaneously has an I-Cache parity error (`ifu_i1_perr`).

3. **BTB, Gshare BHT, & Return Address Stack (`code/ifu_bp_ctl.sv`)**:
   - Push the return link address (`PC + 4` for 4B calls, `PC + 2` for 2B calls) onto the 4-entry return address stack on taken F2 BTB call hits, and select the top of the return address stack (`rets_out[0]`) onto `ifu_bp_btb_target_f2` while popping the stack on taken F2 BTB return hits.
   - Compute fetch-group-crossing 4-byte branch targets (`btb_sel_f2[0] & btb_rd_pc4_f2`) relative to the prior fetch group's upper halfword address `{ifc_fetch_adder_prior[31:4], 3'b111}`.

4. **Fetch Pipe Control, MRAC Cacheability, & ICCM Region Protection (`code/ifu_ifc_ctl.sv`)**:
   - Select the cacheability bit (even bit `{ifc_fetch_addr_f1[31:28], 1'b0}`) from `dec_tlu_mrac_ff` to determine `ifc_fetch_uncacheable_f1`, and assert `ifc_region_acc_fault_f1` when an F1 fetch address falls in region `0xe` (`iccm_acc_in_region_f1`) outside the valid ICCM range `[0xee000000, 0xee07ffff]` (`~iccm_acc_in_range_f1`).

5. **Synthesis, Area, & Declarative Timing Constraints (`constraints.json`)**:
   - Under `BUILD.md`, the RTL must synthesize without latches, achieve mapped Nangate45 cell area `<= 30,000.0 um^2`, and `constraints.json` must specify valid `max_delays` budgets in `(0.0, 3.0]` ns on `ghr_in -> ghr_out` and `ras_in -> ras_out` (with `10.0 ns` `clk` period and `0.2 ns` I/O delays) achieving `WNS >= 0.00 ns`, `TNS >= 0.00 ns`, and non-negative slack on all paths in OpenROAD STA.

---

## Build, Simulation, and EDA Verification Instructions

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

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ifu_aln_ctl.sv`
- `code/ifu_compress_ctl.sv`
- `code/ifu_bp_ctl.sv`
- `code/ifu_ifc_ctl.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
