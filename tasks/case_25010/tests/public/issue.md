# Snitch Two-Port 6-SRAM Instruction Cache Coherence & Physical Macro Co-Design

## Overview
`snitch_icache_subsys` (`code/snitch_icache_subsys.sv`) wraps PULP Snitch's two-port L0/L1 non-blocking instruction cache (`NR_FETCH_PORTS=2`, `LINE_WIDTH=128`, `LINE_COUNT=256`, `WAY_COUNT=2`, `PENDING_COUNT=2`, `FILL_DW=64`, `ISO_CROSSING=0`) backed by six `RM_IHPSG13_1P_256x64_c2_bm_bist` 1P 256x64 hard SRAM macros (`2` tag + `4` data banks). You own the RTL-to-physical co-design across:
- `code/snitch_icache.sv`, `code/snitch_icache_l0.sv`, `code/snitch_icache_lookup.sv`, `code/snitch_icache_handler.sv`, `code/snitch_icache_refill.sv`
- `plan/macro_placement.json`
- `constraints/snitch_icache.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Coherence Contract
1. **Two-Port Fetch & Cache-Line-Aligned AXI4 Refill**:
   - Serve concurrent 32-bit cacheable (`inst_cacheable_i[p]=1`) and bypass (`inst_cacheable_i[p]=0`) instruction fetches on Ports `0..1` (`inst_addr_{0,1}_i`, `inst_valid_i`, `inst_ready_o`, `inst_data_{0,1}_o`, `inst_error_o`), including optional L0 next-line prefetching (`enable_prefetching_i`).
   - All cacheable and bypass AXI4 read requests issued by the refill engine must use 16-byte line-aligned 2-beat `INCR` bursts (`axi_ar_addr_o[3:0] == 4'h0`, `axi_ar_len_o == 8'd1`, `axi_ar_size_o == 3'd3`, `axi_ar_burst_o == 2'b01`), regardless of which 32-bit word offset within the 128-bit line was requested.
2. **Per-Port & Global `FENCE.I` Flush Coherence (`flush_valid_i[1:0]` / `flush_ready_o[1:0]`)**:
   - Completing a handshake on `flush_valid_i[p]`/`flush_ready_o[p]` must invalidate Port `p`'s L0 buffer and shared L1 state, and prevent any in-flight pre-flush refill from populating L1/L0 or returning stale pre-flush instructions on subsequent fetches.
   - Single-port flushes (`2'b01` or `2'b10`) must not drop, deadlock, or corrupt concurrent in-flight requests on the un-flushed port—even when both ports coalesced onto the same L1 MSHR entry.
3. **Multi-Beat AXI4 Error Containment (`axi_r_resp_i[1] == 1'b1`)**:
   - An AXI read error (`SLVERR`/`DECERR`) on **any** beat of a cacheable refill burst (or bypass read) must retire a demand fetch with `inst_error_o[p] == 1'b1` and must never allocate/validate the errored line in L1 or L0, allowing subsequent fetches to cleanly re-issue on AXI once memory recovers.
   - Speculative L0 next-line prefetches that encounter an AXI read error must silently discard the errored refill without poisoning L1/L0 or asserting `inst_error_o` on demand fetches to valid addresses.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2400, 1600]` um, core area `[50, 50, 2350, 1550]` um. Place all six `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2.0` um core margin, `>= 8.0` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/snitch_icache.sdc`)**: Constrain `clk_i` to period `<= 11.5` ns with `>= 1.2` ns input/output delays on all non-clock ports (only `rst_ni` may carry `set_false_path`; no multicycle, clock-group, case-analysis, or max/min-delay overrides).
- **Synthesis & OpenROAD Signoff**: Zero inferred latches, all six `RM_IHPSG13_1P_256x64_c2_bm_bist` macros preserved, connected `VDD`/`VSS` PDN grids, post-GRT setup slack `>= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 10`, and total routed wirelength `<= 1,850,000` um.
