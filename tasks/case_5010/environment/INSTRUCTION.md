# case_5010: CVA6 I-Cache Speculative Non-Idempotent Kill Recovery, S1 Kill Gating, AXI Wrapper Unacknowledged AR Stability, Burst Write Handshake, and Area/Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cva6` (`repo_05`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/cva6_icache.sv`, `code/cva6_icache_axi_wrapper.sv`, `code/axi_shim.sv`

---

## Problem Specification

# CVA6 I-Cache Speculative Non-Idempotent Kill Recovery, S1 Kill Gating, AXI Wrapper Unacknowledged AR Stability, and Area/Timing Closure

In the CVA6 instruction cache and AXI interface subsystem (`code/cva6_icache.sv`, `code/cva6_icache_axi_wrapper.sv`, and `code/axi_shim.sv` integrated in `flow/icache_axi_top.sv`), stage-1/stage-2 request kills, speculative non-idempotent fetches, and stalled AXI read/write handshakes expose four functional and synthesis/timing issues:

1. **Stage-1 kill (`kill_s1`) state/SRAM side-effects and speculative non-idempotent `kill_s2` deadlock in `code/cva6_icache.sv`**:
   - When `dreq_i.req` and `dreq_i.kill_s1` are both asserted on a cycle where `dreq_o.ready` is high (in `IDLE` or on a hit in `READ`), `cva6_icache` currently still asserts `cache_rden = 1'b1` (triggering a spurious SRAM read) and updates `vaddr_q` and `cl_offset_q` to the killed `dreq_i.vaddr`. Whenever `dreq_i.kill_s1` is asserted, a new S1 request must not trigger `cache_rden` (`1'b0` in `IDLE`), must not transition to `READ`, and must not update `vaddr_q` or `cl_offset_q`.
   - In `READ`, when `areq_i.fetch_valid` is asserted for a speculative fetch (`dreq_i.spec == 1'b1`) targeting a non-idempotent physical address (`CVA6Cfg.NonIdemPotenceEn && addr_ni`), the cache waits for `dreq_i.spec` to deassert before issuing the non-idempotent memory access. Currently, if `dreq_i.kill_s2` or `flush_d` is asserted on that cycle while `areq_i.fetch_valid == 1'b1`, `cva6_icache` transitions to `KILL_ATRANS` (which waits for another `areq_i.fetch_valid`) instead of returning directly to `IDLE`. When `dreq_i.kill_s2 || flush_d` is asserted in `READ` and `areq_i.fetch_valid` is already high, `state_d` must transition to `IDLE` (`KILL_ATRANS` is only entered when `areq_i.fetch_valid == 1'b0`).

2. **AXI read channel payload stability under `ar_ready` backpressure in `code/cva6_icache_axi_wrapper.sv`**:
   - `cva6_icache_axi_wrapper` immediately acknowledges `icache_mem_data_req` (`icache_mem_data_ack = icache_mem_data_req`) and holds `axi_rd_req` high via `req_valid_q` until `axi_rd_gnt` (`ar_ready`) is received. However, `req_data_d = (icache_mem_data_req) ? icache_mem_data : req_data_q` unconditionally overwrites `req_data_q` whenever `icache_mem_data_req` asserts, even while an earlier unacknowledged AXI read request is still pending (`req_valid_q == 1'b1` and `ar_valid_o == 1'b1`, `ar_ready_i == 1'b0`), violating the AXI4 requirement that `ar_addr`, `ar_len`, and `ar_id` remain stable while `ar_valid && !ar_ready`. `req_data_d` must only capture `icache_mem_data` when `icache_mem_data_req && !req_valid_q`.

3. **Burst write handshake and beat counter control in `code/axi_shim.sv`**:
   - In `axi_shim`, multi-beat burst writes (`CVA6Cfg.AxiBurstWriteEn && !wr_single_req`) must advance `wr_cnt_q` on each accepted `W` beat (`axi_resp_i.w_ready`), assert `w.last` on the final beat (`wr_cnt_q == wr_blen_i`), and transition to `WAIT_LAST_W_READY_AW_READY` when neither `aw_ready` nor `w_ready` is asserted in `IDLE` (`{aw_ready, w_ready} == 2'b00`) or when only `w_ready` is asserted (`2'b01`), clearing `wr_cnt_q` and asserting `wr_gnt_o` only when both `AW` and the final `W` beat have been accepted.

4. **Synthesis, area, and timing closure**:
   - When `icache_axi_top` (`flow/icache_axi_top.sv`) is synthesized with Yosys + Slang against Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`) and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`) as documented in `BUILD.md`, the design must infer zero latches, achieve a mapped cell area **`<= 8,200.0 um^2`**, and meet setup and hold timing (`slack >= 0.00 ns`) at a **`2.10 ns`** clock period (`0.20 ns` I/O delays, `5.0 fF` load). Edit only `code/cva6_icache.sv`, `code/cva6_icache_axi_wrapper.sv`, and `code/axi_shim.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Synthesis/STA Environment

## Editable Files
Only the following files may be modified:
- `code/cva6_icache.sv`
- `code/cva6_icache_axi_wrapper.sv`
- `code/axi_shim.sv`

All other files in `code/`, `include/`, `flow/`, `lib/`, and `lef/` are read-only.
Editable RTL must remain technology-independent behavioral/structural SystemVerilog without directly instantiating library cell primitives (e.g., `BUF_X*`, `INV_X*`, `NAND*`, `DFF*`), `(* blackbox *)` modules, or introducing simulator/synthesis conditional compilation macros (`` `ifdef ``, `` `ifndef ``, `` `define ``). Each editable file must define only its own module (`cva6_icache`, `cva6_icache_axi_wrapper`, `axi_shim`), and `code/cva6_icache.sv` must preserve the `sram_cache` (`code/sram_cache.sv`) `tag_sram` and `data_sram` instantiations without replacing `sram_cache` with custom memory modules.

## Compilation Order (`Verilator` / `Yosys -m slang`)
With `-Iinclude`:
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/axi_pkg.sv`
5. `code/ariane_pkg.sv`
6. `code/wt_cache_pkg.sv`
7. `code/cf_math_pkg.sv`
8. `code/lzc.sv`
9. `code/lfsr.sv`
10. `code/sram_cache.sv`
11. `code/axi_shim.sv`
12. `code/cva6_icache.sv`
13. `code/cva6_icache_axi_wrapper.sv`

## Synthesis, Area, and STA Target
`icache_axi_top` (`flow/icache_axi_top.sv`) is synthesized with `yosys -m slang`:
```
read_slang --ignore-assertions --top icache_axi_top -Iinclude -DSYNTHESIS code/config_pkg.sv code/cv64a60ax_config_pkg.sv code/riscv_pkg.sv code/axi_pkg.sv code/ariane_pkg.sv code/wt_cache_pkg.sv code/cf_math_pkg.sv code/lzc.sv code/lfsr.sv code/sram_cache.sv code/axi_shim.sv code/cva6_icache.sv code/cva6_icache_axi_wrapper.sv flow/icache_axi_top.sv
hierarchy -check -top icache_axi_top
proc; opt_clean
select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top icache_axi_top -flatten
opt
dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
abc -liberty lib/NangateOpenCellLibrary_typical.lib
clean
read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
check -assert
stat -liberty lib/NangateOpenCellLibrary_typical.lib
write_verilog -noattr mapped_icache_axi.v
```
and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`, `lib/NangateOpenCellLibrary_typical.lib`) with:
- `create_clock -name clk_i -period 2.10 [get_ports clk_i]`
- `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
- `set_output_delay 0.20 -clock clk_i [all_outputs]`
- `set_load 5.0 [all_outputs]`
Targets:
- Zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`, `$_DLATCH`)
- Mapped area `<= 8,200.0 um^2`
- Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`
- Pure technology-independent behavioral/structural SystemVerilog preserving the `sram_cache` (`tag_sram` and `data_sram`) instances in `code/cva6_icache.sv` (no direct Nangate45 standard-cell instantiations, `blackbox` declarations, extra module definitions, or simulator/synthesis macro divergence)

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/cva6_icache.sv`
- `code/cva6_icache_axi_wrapper.sv`
- `code/axi_shim.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
