# case_20009: Two-Way AXI4 Last-Level Cache Multi-Corner Native SDC & Hard-SRAM Critical-Path Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/axi_llc` (`repo_26`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `constraints/axi_llc.sdc`, `code/rtl/axi_llc_top.sv`, `code/rtl/axi_llc_chan_splitter.sv`, `code/rtl/axi_llc_tag_store.sv`, `code/rtl/axi_llc_data_way.sv`

---

## Problem Specification

# Two-Way AXI4 Last-Level Cache Multi-Corner Native SDC & Hard-SRAM Critical-Path Closure

## Overview
`code/rtl/axi_llc_top_wrap.sv` integrates the complete 2-way, 4 KiB, 64-bit PULP `axi_llc` subsystem (`SetAssociativity = 2`, `NumLines = 64`, `NumBlocks = 4`, `AxiIdWidth = 4`, `AxiAddrWidth = 32`, `AxiDataWidth = 64`) backed by two hard `RM_IHPSG13_1P_64x64_c2_bm_bist` Tag SRAMs and two hard `RM_IHPSG13_1P_256x64_c2_bm_bist` Data SRAMs on IHP SG13G2. Under a `9.50 ns` (`~105.26 MHz`) target clock across all three signoff corners (`SS 1.08V 125C`, `TT 1.20V 25C`, `FF 1.32V -40C`), the baseline RTL and starter `constraints/axi_llc.sdc` fail worst-corner setup timing across unpipelined AXI4/descriptor/SRAM boundaries, fast-corner macro hold timing, and native `.sdc` signoff completeness.

## Architectural, Constraint & Multi-Corner Signoff Contract

1. **Lossless AXI4 LLC Protocol, Coherency, BIST & SPM Behavior**:
   - Preserve full AXI4 and LLC architectural behavior across post-reset Tag BIST initialization (`bist_done_o`, `bist_out_o`), cached cold-miss refills, cached read/write hits, multi-line bursts crossing 32-byte cache-line boundaries, partial-strobe (`slv_w_strb_i`) updates, dirty victim writeback evictions, uncached address-range bypasses (`outside [cached_start_addr_i, cached_end_addr_i)`), and dynamic Scratchpad Memory way partitioning/flushing (`cfg_spm_i`, `cfg_flush_i`, `commit_cfg_i`, `flushed_o`) under arbitrary slave/master channel backpressure.
   - Internal stream/channel pipelining across the editable RTL modules is permitted (latency-elastic `valid`/`ready` AXI4 and internal descriptor/way handshakes), provided transaction ordering, `ID` tags, responses, cache coherency, and BIST pass/fail self-checking remain exact, and synthesized gate-level netlist behavior matches RTL.

2. **Native Signoff Timing Constraints (`constraints/axi_llc.sdc`)**:
   - Define primary clock `clk_i` on port `clk_i` with `-period 9.50`, `-setup` clock uncertainty `>= 0.15` ns, `-hold` clock uncertainty `>= 0.08` ns, and clock transition `>= 0.10` ns.
   - Treat `rst_ni`, `test_i`, and static address-map strap buses (`cached_start_addr_i*`, `cached_end_addr_i*`, `spm_start_addr_i*`, matching post-`splitnets -ports` scalarized bus ports) as asynchronous/static false-path inputs (`set_false_path -from`), excluded from `set_input_delay`.
   - Constrain **every** remaining synchronous input port with `set_driving_cell -lib_cell sg13g2_buf_4 -pin X`, `set_input_delay -clock clk_i -max >= 1.80`, and `set_input_delay -clock clk_i -min <= 0.20`. Constrain **every** output port (`[all_outputs]`) with `set_output_delay -clock clk_i -max >= 1.80`, `set_output_delay -clock clk_i -min <= 0.05`, and `set_load >= 0.025`.
   - Model pre-CTS early macro clock-tree balance on **only** the four hard SRAM macro `A_CLK` pins (`*i_cut/A_CLK`) with `set_clock_latency` in `[-0.50, -0.45]` ns (do not apply clock latency to standard-cell flip-flops or top ports), set electrical design limits `set_max_fanout <= 16` and `set_max_transition <= 0.40` on `[current_design]`, and do **not** use `set_multicycle_path`, `set_disable_timing`, `set_case_analysis`, `set_ideal_network`, or false paths on synchronous logic/ports (`check_setup` must report `0` unconstrained endpoints).

3. **Three-Corner (`SS` / `TT` / `FF`) OpenROAD Signoff**:
   - Following `yosys -m slang` synthesis to `sg13g2` (`synth -top axi_llc_top_wrap -flatten`) and OpenROAD `repair_design` buffering on `sg13g2_stdcell_slow_1p08V_125C.lib` (`Metal3` signal / `Metal4` clock wire RC, `estimate_parasitics -placement`), all three corners (`slow_1p08V_125C`, `typ_1p20V_25C`, `fast_1p32V_m40C` paired with `RM_IHPSG13_1P_{64,256}x64_c2_bm_bist.lib`) must achieve `setup WNS >= 0.0 ns`, `setup TNS == 0.0 ns`, `hold WNS >= 0.0 ns`, and `hold TNS == 0.0 ns`.
   - Editable files: `constraints/axi_llc.sdc`, `code/rtl/axi_llc_top.sv`, `code/rtl/axi_llc_chan_splitter.sv`, `code/rtl/axi_llc_tag_store.sv`, and `code/rtl/axi_llc_data_way.sv`. Preserve all module names, parameters, and port signatures; all other files in `code/` and `lib/` are read-only.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Synthesis, Buffering & Multi-Corner STA Reference

## Editable Files
- `constraints/axi_llc.sdc`
- `code/rtl/axi_llc_top.sv`
- `code/rtl/axi_llc_chan_splitter.sv`
- `code/rtl/axi_llc_tag_store.sv`
- `code/rtl/axi_llc_data_way.sv`

All other files in `code/` and `lib/` are read-only.

## Reference Signoff Commands
- **Yosys + Slang Synthesis (`build/llc_mapped.v`)**:
  ```bash
  mkdir -p build
  yosys -m slang -p "
    read_slang --top axi_llc_top_wrap -Icode/common_cells/include -Icode/axi/include -Icode/include -DSYNTHESIS \
      lib/RM_IHPSG13_1P_64x64_c2_bm_bist_stub.v lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v \
      code/common_cells/src/cb_filter_pkg.sv code/common_cells/src/cf_math_pkg.sv \
      code/axi/src/axi_pkg.sv code/rtl/axi_llc_pkg.sv code/rtl/tc_sram.sv \
      code/common_cells/src/*.sv code/axi/src/*.sv code/rtl/*.sv;
    hierarchy -check -top axi_llc_top_wrap; proc; opt_expr; check -assert;
    select -assert-none t:\$dlatch*;
    synth -top axi_llc_top_wrap -flatten;
    dfflibmap -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    abc -D 2500 -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO;
    setundef -zero; splitnets -ports; opt_clean -purge;
    write_verilog -noattr -noexpr build/llc_mapped.v"
  ```
- **OpenROAD `repair_design` Buffering & 3-Corner (`SS` / `TT` / `FF`) STA**:
  `openroad`
- **Verilator Simulation (with `lib/SRAM_1P_behavioral_bm_bist.v` + `lib/RM_IHPSG13_1P_*x64_c2_bm_bist.v`, `-DFUNCTIONAL`)**:
  `verilator`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `constraints/axi_llc.sdc`
- `code/rtl/axi_llc_top.sv`
- `code/rtl/axi_llc_chan_splitter.sv`
- `code/rtl/axi_llc_tag_store.sv`
- `code/rtl/axi_llc_data_way.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
