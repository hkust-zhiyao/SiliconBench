# case_25017: Snitch Wide-Line 10-SRAM AXI4 Read-Only Cache Coherence, Burst Splitting & Macro PnR

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/snitch` (`repo_22`)
> - **Engineering Problem Type**: `RTL + Hard-SRAM Macro Physical Co-Design` (`PT5_RTL_HardSRAM_Macro_PnR`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/snitch_read_only_cache.sv`, `code/snitch_axi_to_cache.sv`, `code/snitch_ro_cache_lookup.sv`, `code/snitch_ro_cache_refill.sv`, `plan/macro_placement.json`, `constraints/snitch_ro_cache.sdc`

---

## Problem Specification

# Snitch Wide-Line 10-SRAM AXI4 Read-Only Cache Coherence, Burst Splitting & Macro PnR

## Overview
`snitch_ro_cache_subsys` (`code/snitch_ro_cache_subsys.sv`) integrates PULP Snitch's wide-line AXI4 read-only cache (`LineWidth=256`, `LineCount=256`, `SetCount=2`, `AxiAddrWidth=32`, `AxiDataWidth=64`, `AxiIdWidth=3`, `AxiUserWidth=2`, `MaxTrans=4`, `NrAddrRules=2`) backed by ten `RM_IHPSG13_1P_256x64_c2_bm_bist` 1P 256x64 hard SRAM macros (`2` tag + `8` data banks across `2` ways). You own the RTL-to-physical co-design across:
- `code/snitch_read_only_cache.sv`, `code/snitch_axi_to_cache.sv`, `code/snitch_ro_cache_lookup.sv`, `code/snitch_ro_cache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_ro_cache.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Coherence Contract
1. **Address-Window Decoding & Non-Cacheable Bypass Routing**:
   - Each rule `r` (`0 <= r < NrAddrRules`) defines an active half-open cacheable window `[start_addr_i[r], end_addr_i[r])` whenever `start_addr_i[r] < end_addr_i[r]`.
   - Route an AXI4 `AR` burst to the cache iff `enable_i` is high, every accessed byte of the burst falls within a single active rule `r`, `slv_ar_lock_i == 1'b0`, `slv_ar_burst_i == 2'b01` (`BURST_INCR`), and (`slv_ar_len_i == 8'd0` or `slv_ar_size_i == 3'd3`). Route all `AW`/`W`/`B` writes and all other `AR` bursts (`BURST_FIXED`, `BURST_WRAP`, narrow multi-beat bursts, locked reads, disabled-cache reads, and bursts crossing outside an active window) through the bypass path without allocating or polluting cache lines.
2. **Wide-Line Burst Splitting, Multi-ID Coalescing & R-Channel Backpressure**:
   - Split cacheable `INCR` bursts across 32-byte (`256`-bit) cache lines (`mst_ar` refills must issue 32-byte-aligned 4-beat `INCR` bursts: `mst_ar_addr_o[4:0] == 5'h0`, `mst_ar_len_o == 8'd3`, `mst_ar_size_o == 3'd3`, `mst_ar_burst_o == 2'b01`).
   - Reconstruct exact 64-bit `R` beats, `slv_r_id_o`, `slv_r_last_o`, and `slv_r_user_o == '0` across unaligned multi-line splits, multi-ID MSHR coalescing, and back-to-back same-ID requests, holding all `slv_r_*` outputs and internal burst/ID tracking undisturbed while `slv_r_valid_o && !slv_r_ready_i`.
3. **Multi-Beat Refill Error Containment (`mst_r_resp_i[1] == 1'b1`)**:
   - A downstream AXI read error (`SLVERR`/`DECERR`) on **any** beat of a 4-beat cache refill must return `slv_r_resp_o == 2'b10` (`RESP_SLVERR`) on the corresponding slave `R` beat(s) and must never leave the errored line valid in SRAM, allowing subsequent reads to cleanly re-fetch from memory once the fault clears.
4. **Write-Through Cache Invalidation & Flush Handshake (`flush_valid_i` / `flush_ready_o`)**:
   - Writes (`AW`/`W`/`B`) overlapping any active `[start_addr_i[r], end_addr_i[r])` window must forward to memory and invalidate all touched cache sets across both ways—ordering concurrent/in-flight reads and refills so neither post-write reads nor concurrent refills leave stale pre-write data cached—while preserving warm cache hits on untouched sets and ignoring writes strictly outside active cacheable windows.
   - Completing a `flush_valid_i && flush_ready_o` handshake must drain in-flight cache transactions/refills and clear all cached sets across both ways so no pre-flush data survives or installs afterward.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 1800]` um, core area `[50, 50, 2550, 1750]` um. Place all ten `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2.0` um core margin, `>= 8.0` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/snitch_ro_cache.sdc`)**: Constrain `clk_i` to period `<= 11.8` ns with `>= 1.2` ns input/output delays on all non-clock ports (only `rst_ni` may carry `set_false_path`; no multicycle, clock-group, case-analysis, or max/min-delay overrides).
- **Synthesis & OpenROAD Signoff**: Zero inferred latches, all ten `RM_IHPSG13_1P_256x64_c2_bm_bist` macros preserved, connected `VDD`/`VSS` PDN grids, post-GRT setup slack `>= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 15`, and total routed wirelength `<= 2,900,000` um.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment (`case_25017`)

## Available Tools & Collateral
- **RTL Simulation**: Verilator (`verilator --binary --timing`) or Icarus Verilog (`iverilog -g2012`)
- **Synthesis**: Yosys with SystemVerilog Slang frontend (`yosys -m slang`)
- **Physical Implementation & STA**: OpenROAD (`openroad -exit`)
- **PDK Collateral (`pdk/`)**: IHP SG13G2 130nm standard cells (`sg13g2_tech.lef`, `sg13g2_stdcell.lef`, `sg13g2_stdcell_typ_1p20V_25C.lib`, `core.v`) and `RM_IHPSG13_1P_256x64_c2_bm_bist` hard SRAM macro views (`256.v` behavioral model, `256_stub.v` blackbox stub, `256.lef`, `256.lib`).

## Editable Files
- `code/snitch_read_only_cache.sv`
- `code/snitch_axi_to_cache.sv`
- `code/snitch_ro_cache_lookup.sv`
- `code/snitch_ro_cache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_ro_cache.sdc`

## Example Commands
```bash
# 1. RTL Elaboration & Lint Check
verilator --lint-only -Wno-fatal -Wno-UNOPTFLAT -Icode -top-module snitch_ro_cache_subsys \
  pdk/core.v pdk/256.v code/axi_pkg.sv code/cf_math_pkg.sv code/snitch_icache_pkg.sv \
  code/cc_onehot.sv code/lzc.sv code/onehot_to_bin.sv code/rr_arb_tree.sv \
  code/counter.sv code/delta_counter.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
  code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
  code/addr_decode.sv code/id_queue.sv code/axi_id_prepend.sv \
  code/axi_demux_simple.sv code/axi_demux.sv code/axi_mux.sv code/tc_sram_impl.sv \
  code/snitch_icache_lfsr.sv code/snitch_icache_handler.sv code/snitch_axi_to_cache.sv \
  code/snitch_ro_cache_lookup.sv code/snitch_ro_cache_refill.sv \
  code/snitch_read_only_cache.sv code/snitch_ro_cache_subsys.sv

# 2. Synthesis to SG13G2 Standard Cells + 10x Hard SRAM Macros
yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode pdk/256_stub.v code/axi_pkg.sv code/cf_math_pkg.sv \
    code/snitch_icache_pkg.sv code/cc_onehot.sv code/lzc.sv code/onehot_to_bin.sv \
    code/rr_arb_tree.sv code/counter.sv code/delta_counter.sv \
    code/spill_register_flushable.sv code/spill_register.sv code/fall_through_register.sv \
    code/fifo_v3.sv code/stream_arbiter_flushable.sv code/stream_arbiter.sv \
    code/stream_demux.sv code/addr_decode.sv code/id_queue.sv code/axi_id_prepend.sv \
    code/axi_demux_simple.sv code/axi_demux.sv code/axi_mux.sv code/tc_sram_impl.sv \
    code/snitch_icache_lfsr.sv code/snitch_icache_handler.sv code/snitch_axi_to_cache.sv \
    code/snitch_ro_cache_lookup.sv code/snitch_ro_cache_refill.sv \
    code/snitch_read_only_cache.sv code/snitch_ro_cache_subsys.sv \
    --top snitch_ro_cache_subsys;
  hierarchy -check -top snitch_ro_cache_subsys;
  synth -noabc -top snitch_ro_cache_subsys -flatten;
  delete t:\$scopeinfo;
  dfflibmap -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  abc -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/mapped.v
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/snitch_read_only_cache.sv`
- `code/snitch_axi_to_cache.sv`
- `code/snitch_ro_cache_lookup.sv`
- `code/snitch_ro_cache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_ro_cache.sdc`

All other files in the workspace are read-only reference context and must remain unmodified.
