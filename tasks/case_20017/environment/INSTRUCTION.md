# case_20017: 16 KiB Two-Way Write-Back AXI4 D-Cache Hard-SRAM Mapping, Coherency & Multi-Corner Signoff

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `ultraembedded/biriscv` (`repo_44`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `constraints/dcache.sdc`, `code/dcache_core.v`, `code/dcache_core_tag_ram.v`, `code/dcache_core_data_ram.v`, `code/dcache_axi_axi.v`

---

## Problem Specification

# 16 KiB Two-Way Write-Back AXI4 D-Cache Hard-SRAM Mapping, Coherency & Multi-Corner Signoff

## Overview
`code/dcache.v` (`AXI_ID = 0`) integrates the `biriscv` 16 KiB, 2-way set-associative, 32-byte-line (256-set) write-back data cache subsystem across cached/uncached request multiplexing, cache lookup/refill/eviction control, and 32-bit AXI4 master burst bridging. In the baseline RTL and starter `constraints/dcache.sdc`, Tag and Data arrays are modeled as behavioral dual-port register memories, cached replacement and AXI4 write-eviction handshaking exhibit coherency/protocol defects under realistic traffic and channel backpressure, and the design fails `8.00 ns` (`~125.0 MHz`) multi-corner (`SS` / `TT` / `FF`) timing signoff on IHP SG13G2.

## Architectural, Hard-SRAM & Multi-Corner Signoff Contract

1. **Single-Port (1RW) Hard-SRAM Mapping (`10` `RM_IHPSG13_1P_256x64_c2_bm_bist` Macros)**:
   - Map Tag storage to **1** `RM_IHPSG13_1P_256x64_c2_bm_bist` macro per way (`2` tag macros) and 8 KiB/way Data storage to **4** `RM_IHPSG13_1P_256x64_c2_bm_bist` macros per way (`8` data macros, yielding **exactly `10`** hard SRAM macros in synthesized `dcache`, with `A_DLY = 1'b1` and `A_BIST_*` ports tied `0`).
   - Each `RM_IHPSG13_1P_256x64_c2_bm_bist` is a true synchronous single-port (1RW) macro (`A_WEN` and `A_REN` mutually exclusive when `A_MEN = 1'b1`), using `A_BM` bit-masking for byte-granular writes (`mem_wr_i[3:0]`). Synthesized `dcache` must infer zero latches and match RTL behavior in gate-level simulation.

2. **Write-Back Coherency, Set-Associative LRU Replacement & AXI4 Protocol**:
   - Preserve the top-level `dcache` request/response (`mem_accept_o`, `mem_ack_o`, `mem_data_rd_o`, `mem_resp_tag_o`, `mem_error_o`) and AXI4 master (`len = 7` `INCR` 8-beat cache-line refills/writebacks; `len = 0` single-beat uncached `mem_cacheable_i = 0` reads/writes) contracts under arbitrary independent backpressure on `axi_awready_i`, `axi_wready_i`, `axi_arready_i`, `axi_rvalid_i`, and `axi_bvalid_i` (including staggered `AW` vs `W` readiness on burst Beat 0).
   - Clear all 256 tag sets after `rst_i` before accepting requests. For each set (`mem_addr_i[12:5]`), miss allocation must fill any invalid way before evicting a valid way, and when both ways are valid, evict the least-recently-used (LRU) way updated on cached read/write hits and miss allocations.
   - Support byte-masked cached writes, dirty victim writeback prior to refill, address-targeted `mem_writeback_i` (write back a matching dirty line to AXI4 and mark it clean while retaining validity), address-targeted `mem_invalidate_i` (invalidate a matching line without writeback), and full-cache `mem_flush_i` (write back every dirty line across both ways and invalidate all 256 sets).

3. **Native Signoff Constraints (`constraints/dcache.sdc`) & Three-Corner (`SS` / `TT` / `FF`) STA**:
   - Define `clk_i` on port `clk_i` with `-period 8.00`, `-setup` uncertainty `>= 0.15` ns, `-hold` uncertainty `>= 0.08` ns, and clock transition `>= 0.10` ns. Mark `rst_i` as an asynchronous false path (`set_false_path -from [get_ports rst_i]`), excluded from `set_input_delay`.
   - Constrain **every** synchronous input port with `set_driving_cell -lib_cell sg13g2_buf_4 -pin X`, `set_input_delay -clock clk_i -max >= 1.80`, and `-min <= 0.20`; constrain **every** output port (`[all_outputs]`) with `set_output_delay -clock clk_i -max >= 1.80`, `-min <= 0.05`, and `set_load >= 0.025`.
   - Model pre-CTS early macro clock arrival on **only** the `10` hard SRAM `A_CLK` pins (`[get_pins -hierarchical */A_CLK]`) with `set_clock_latency` in `[-0.42, -0.38]` ns, set `set_max_fanout <= 16` and `set_max_transition <= 0.40` on `[current_design]`, and use no `set_multicycle_path`, `set_disable_timing`, `set_case_analysis`, `set_ideal_network`, `set_max_delay`, `set_min_delay`, or `-to`/`-through` false paths (`0` unconstrained endpoints).
   - Following Yosys synthesis (`BUILD.md`) and OpenROAD buffering (`slow_1p08V_125C` `Metal3`/`Metal4` wire RC + `estimate_parasitics -placement` + `repair_design -cap_margin 20 -slew_margin 20` + `repair_timing -setup`, followed by `fast_1p32V_m40C` `repair_timing -hold -hold_margin 0.02`), all three corners (`slow_1p08V_125C`, `typ_1p20V_25C`, `fast_1p32V_m40C` + `RM_IHPSG13_1P_256x64_c2_bm_bist.lib`) must achieve `setup WNS >= 0.0 ns`, `setup TNS == 0.0 ns`, `hold WNS >= 0.0 ns`, and `hold TNS == 0.0 ns`.
   - Editable files: `constraints/dcache.sdc`, `code/dcache_core.v`, `code/dcache_core_tag_ram.v`, `code/dcache_core_data_ram.v`, and `code/dcache_axi_axi.v`. Preserve module names and port signatures; all other files in `code/` and `lib/` are read-only.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Synthesis, Buffering & Multi-Corner STA Reference

## Editable Files
- `constraints/dcache.sdc`
- `code/dcache_core.v`
- `code/dcache_core_tag_ram.v`
- `code/dcache_core_data_ram.v`
- `code/dcache_axi_axi.v`

All other files in `code/` and `lib/` are read-only.

## Reference Signoff Commands
- **Yosys Synthesis (`build/dcache_mapped.v` + `build/dcache_gl.v`)**:
  ```bash
  mkdir -p build
  yosys -p "
    read_verilog lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v \
      code/dcache_core_tag_ram.v code/dcache_core_data_ram.v code/dcache_core.v \
      code/dcache_if_pmem.v code/dcache_mux.v code/dcache_pmem_mux.v \
      code/dcache_axi_axi.v code/dcache_axi.v code/dcache.v;
    hierarchy -check -top dcache; proc; opt; check -assert;
    select -assert-none t:\$dlatch*;
    synth -top dcache -flatten;
    design -save flat_generic; rename dcache dcache_gl; opt_clean;
    write_verilog -noattr build/dcache_gl.v;
    design -load flat_generic;
    dfflibmap -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    abc -D 2500 -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO;
    setundef -zero; splitnets -ports; opt_clean -purge;
    write_verilog -noattr -noexpr build/dcache_mapped.v"
  ```
- **OpenROAD Buffering (`SS 1.08V 125C`: `Metal3` signal / `Metal4` clock wire RC, `estimate_parasitics -placement`, `repair_design -cap_margin 20 -slew_margin 20`, `repair_timing -setup`; followed by `FF 1.32V -40C`: `repair_timing -hold -hold_margin 0.02`) & 3-Corner (`SS` / `TT` / `FF`) STA**:
  `openroad`
- **Verilator Simulation (with `lib/SRAM_1P_behavioral_bm_bist.v` + `lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v`, `-DFUNCTIONAL`)**:
  `verilator`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `constraints/dcache.sdc`
- `code/dcache_core.v`
- `code/dcache_core_tag_ram.v`
- `code/dcache_core_data_ram.v`
- `code/dcache_axi_axi.v`

All other files in the workspace are read-only reference context and must remain unmodified.
