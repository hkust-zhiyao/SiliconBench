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
