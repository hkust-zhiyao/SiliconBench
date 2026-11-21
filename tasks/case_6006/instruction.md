# case_6006: VeeR-EH1 IFU Branch Predictor (BTB/BHT/RAS), I-Cache/ICCM Memory Controller, and Fetch Pipe Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-eh1` (`repo_06`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/ifu_ifc_ctl.sv`, `code/ifu_bp_ctl.sv`, `code/ifu_mem_ctl.sv`

---

## Problem Specification

# VeeR-EH1 IFU Branch Predictor (BTB/BHT/RAS), I-Cache/ICCM Memory Controller, and Fetch Pipe Closure

In `code/veer_ifu_bp_mem_top.sv`, the fetch pipeline controller (`code/ifu_ifc_ctl.sv`), the branch target buffer, gshare branch history table, and 4-entry return address stack (`code/ifu_bp_ctl.sv`), and the I-Cache/ICCM memory and miss/error controller (`code/ifu_mem_ctl.sv`) are integrated together.

Update only `code/ifu_ifc_ctl.sv`, `code/ifu_bp_ctl.sv`, and `code/ifu_mem_ctl.sv` to satisfy all functional, synthesis, and static timing contracts:

1. **Fetch Pipe Control & MRAC/ICCM Address Protection (`code/ifu_ifc_ctl.sv`)**:
   - Determine F1 fetch cacheability from the cacheability bit (even bit) of the 2-bit MRAC region descriptor in `dec_tlu_mrac_ff` for the current 256 MB region (`ifc_fetch_addr_f1[31:28]`).
   - Classify F1 accesses in region `0xe` into valid ICCM accesses (`[0xee000000, 0xee07ffff]`) versus out-of-range ICCM region access faults, and coordinate F1/F2 fetch requests across flushes, BTB taken redirects, fetch-buffer occupancy, and critical-word bypass readiness.

2. **BTB, Gshare BHT & Return Address Stack (`code/ifu_bp_ctl.sv`)**:
   - Push the sequential link address (`PC + 4` for 32-bit calls or `PC + 2` for 16-bit calls) onto the 4-entry return address stack on taken F2 BTB call hits, and drive the top of the return address stack onto `ifu_bp_btb_target_f2` while popping the stack on taken F2 BTB return hits (that are not simultaneously marked as calls).
   - When a 4-byte branch straddles two fetch groups such that its upper halfword hits in halfword lane 0 of the current F2 fetch group, compute its branch target relative to the prior fetch group's upper address (offset `3'b111`).
   - Resolve BHT bank/index writes so each source writes its own 2-bit history counter and simultaneous writes to the same bank and index obey strict priority: WB slot-0 branch update (`dec_tlu_br0_wb_pkt`) highest, WB slot-1 branch update (`dec_tlu_br1_wb_pkt`) second, and EXU mispredict update (`exu_mp_pkt`) lowest.

3. **I-Cache Miss/Critical-Word Bypass & ICCM ECC Repair Control (`code/ifu_mem_ctl.sv`) & PPA/STA Closure**:
   - Issue and complete uncacheable I-Cache misses in 2 AXI read beats (versus 8 AXI read beats for cacheable line-fill misses); assemble the two 64-bit critical-word beats and assert `ic_crit_wd_rdy` as soon as the second critical half arrives so the miss state machine can complete and return to idle.
   - Propagate F2 region/bus access faults (`ic_access_fault_f2`). On single-bit ICCM ECC errors, wait for pipeline flush and transition into the single-bit ECC correction state when `exu_flush_final` is accompanied by `dec_tlu_flush_err_wb` (or immediately on DMA single-bit ECC errors), asserting both `ic_dma_active` and `iccm_wren` to scrub the corrected word back into ICCM, while returning to idle if `exu_flush_final` occurs without `dec_tlu_flush_err_wb`.
   - The RTL must synthesize without latches. Under the `BUILD.md` Yosys/Slang Nangate45 and OpenROAD STA flow (`3.65 ns` clock on `clk`, `0.15 ns` I/O delays, `5.0 fF` load), `veer_ifu_bp_mem_top` must achieve mapped cell area `<= 27,850.0 um^2`, worst setup slack (`WNS`) `>= 0.00 ns`, and worst hold slack (`WHS`) `>= 0.00 ns`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Static Timing Guide (`veer_ifu_bp_mem_top`)

## 1. Editable Files
Only the following three files in `code/` are collected and graded:
- `code/ifu_ifc_ctl.sv`
- `code/ifu_bp_ctl.sv`
- `code/ifu_mem_ctl.sv`

All other files (`code/veer_ifu_bp_mem_top.sv`, `code/common_defines.vh`, `code/global.h`, `code/veer_types.sv`, `code/beh_lib.sv`, `code/LICENSE`, and `lib/*`) are read-only.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/ifu_ifc_ctl.sv code/ifu_bp_ctl.sv code/ifu_mem_ctl.sv \
  code/veer_ifu_bp_mem_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis & Static Timing Analysis (`Yosys/Slang` + `OpenROAD`)
```bash
yosys -m slang -p "
  read_slang --single-unit --top veer_ifu_bp_mem_top -Icode \
    code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
    code/ifu_ifc_ctl.sv code/ifu_bp_ctl.sv code/ifu_mem_ctl.sv code/veer_ifu_bp_mem_top.sv;
  hierarchy -check -top veer_ifu_bp_mem_top;
  proc;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  opt_clean;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top veer_ifu_bp_mem_top;
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

OpenROAD STA constraints (`3.65 ns` clock on `clk`):
```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design veer_ifu_bp_mem_top
create_clock -name clk -period 3.65 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports {rst_l scan_mode}]
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ifu_ifc_ctl.sv`
- `code/ifu_bp_ctl.sv`
- `code/ifu_mem_ctl.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
