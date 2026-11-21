# Vortex 2-Bank Sectored Way-Folded GPU L1 Cache & 10-SRAM Macro PnR Co-Design

## Overview
`VX_cache_subsys` (`code/VX_cache_subsys.sv`) integrates a 16 KB, 2-bank, 4-way set-associative, sectored, write-through GPU L1 data cache (`64` sets/bank, `32 B` lines across `4 x 64`-bit word slices, `16 B` sectors, `LATENCY = 2`, non-LLC `AMO_ENABLE = 1`, `CS_REPL_PLRU`, 16-bit tags). You own the RTL-to-physical co-design across:
- `code/VX_cache_repl.sv`
- `code/VX_cache_tags.sv`
- `code/VX_cache_data.sv`
- `plan/macro_placement.json`
- `constraints/cache_subsys.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Protocol Contract
1. **Tree-PLRU Victim Selection (`VX_cache_repl`)**:
   - Initialize all per-set PLRU state across the post-reset cache initialization sweep, advance PLRU state on both cache hits and line fills so 4-way allocations utilize all associative ways without premature thrashing, and preserve coherent victim selection across back-to-back same-set hit/fill/lookup cycles and pipeline stalls.
2. **Tag Array & Sectored Coherence (`VX_cache_tags`)**:
   - Store each bank's `64`-set x `4`-way x `16`-bit tags in `RM_IHPSG13_1P_256x64_c2_bm_bist` (`u_tag_sram`) with expanded 64-bit active-high bit-write masks (`A_BM`), mutually exclusive `A_WEN`/`A_REN`, and gated `A_MEN` during stalled non-fill cycles.
   - Track per-sector valid state across cold line fills, resident-line sector refills (retaining valid sibling sectors in the same way), flushes, and non-LLC AMO passthrough hit invalidations, forwarding same-set updates/invalidations cleanly to consecutive lookups.
3. **Way-Folded Word-Sliced Data Array (`VX_cache_data`)**:
   - Map each bank's `4` ways x `64` sets (`256` rows) across four `RM_IHPSG13_1P_256x64_c2_bm_bist` word-slice macros (`u_data_slice_0`..`u_data_slice_3`) addressed by `{way, line_idx}`.
   - Expand 8-bit byte enables to 64-bit `A_BM`, write only the installed sector's word slices on 128-bit fills and only the addressed word slice on write hits, never assert `A_WEN` and `A_REN` simultaneously, and activate `A_MEN`/`A_REN` on at most the single addressed word slice during non-fill reads.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 2200]` um, core area `[50, 50, 2550, 2150]` um. Place all ten `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um: `u_cache.u_bank_{0,1}.cache_tags.u_tag_sram` and `u_cache.u_bank_{0,1}.cache_data.u_data_slice_{0..3}`) inside the core boundary (`>= 2` um core margin, `>= 8` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/cache_subsys.sdc`)**: Constrain `clk` (`core_clk`) to period `<= 17.0` ns with `>= 1.5` ns input/output delays on all non-clock ports (only `reset` may carry `set_false_path`).
- **OpenROAD Signoff**: Latch-free synthesis (`0` `$dlatch`, `10` hard SRAM macros), connected `VDD`/`VSS` PDN grids, post-GRT setup `WNS >= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 25`, and total routed wirelength `<= 6,200,000` um.
