# case_5007: CVA6 Non-Blocking DCache Tag Arbiter Grant Exclusivity, Pipelined Store/Kill Control, Miss-Handler Multi-Way/32b-AMO Completion, and Area/Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cva6` (`repo_05`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/cache_ctrl.sv`, `code/miss_handler.sv`, `code/tag_cmp.sv`

---

## Problem Specification

# CVA6 Non-Blocking DCache SRAM Arbiter Exclusivity, Pipelined Store/Kill Handshake, Multi-Way Eviction/AMO Completion, and Area/Timing Closure

In the CVA6 non-blocking L1 data cache subsystem (`code/std_nbdcache.sv`, `code/cache_ctrl.sv`, `code/miss_handler.sv`, and `code/tag_cmp.sv`), concurrent port arbitration, pipelined load-to-store requests, killed cache misses, multi-way flushes/evictions, and 32-bit atomic operations fail under verification and synthesis/timing sign-off:

1. **SRAM arbiter grant exclusivity and idle behavior (`code/tag_cmp.sv`)**:
   - Across the `NR_PORTS` cache ports (`0` highest priority to `NR_PORTS-1` lowest priority), `tag_cmp` must grant at most one requesting port per cycle (`$onehot0(gnt_o)`) and select that port's tag on the following cycle. Idle higher-priority ports (`req_i[k] == '0`) must never receive `gnt_o[k] = 1'b1` when a lower-priority port requests, and when all ports are idle (`req_i == '0`) `gnt_o`, `req_o`, and `we_o` must remain deasserted with no hit reported on the next cycle.

2. **Pipelined store double-grant, flush-gated speculative reads, and ungranted killed miss cancellation (`code/cache_ctrl.sv`)**:
   - Read requests receive `req_port_o.data_gnt = 1'b1` upon SRAM read acceptance, whereas write requests (`req_port_i.data_we == 1'b1`) must only receive `req_port_o.data_gnt = 1'b1` when the write completes in the store stage or is accepted by the miss/bypass unit. Currently, when a write request is presented on `req_port_i` on the cycle a preceding load hits or receives its critical word, `cache_ctrl` asserts `req_port_o.data_gnt = 1'b1` prematurely and then grants the same write a second time when it completes.
   - While waiting for a refill critical word, speculative SRAM read requests for a new `req_port_i.data_req` must be suppressed when `flush_i` is asserted.
   - If `req_port_i.kill_req` is asserted while waiting for a refill/bypass grant and the miss unit has not yet granted or begun serving the port (`!active_serving_i && !miss_gnt_i && !bypass_gnt_i`), `cache_ctrl` must suppress `miss_req_o.valid` (`1'b0`), acknowledge the kill with `req_port_o.data_rvalid = 1'b1`, and return to idle on that cycle.

3. **2-way LFSR sizing, multi-way SRAM requests, flush/AMO priority, and same-cycle 32-bit AMO/bypass completion (`code/miss_handler.sv`)**:
   - The miss handler must elaborate cleanly for `DCACHE_SET_ASSOC = 2` as well as `4`, drive `req_o` across all ways (`'1`) during cache initialization and clean-line flush scans, and drive `req_o` for the evicted way (`evict_way_q`) when clearing status on writeback completion.
   - When `flush_i` and `amo_req_i.req` are both asserted while idle (`!busy_i`), `flush_i` takes precedence and must assert `flush_ack_o` upon completion rather than suppressing `flush_ack_o` as an AMO-internal flush.
   - When an atomic request or bypass arbiter request receives both grant and valid response on the same cycle, 32-bit AMOs (`amo_req_i.size == 2'b10`) must still extract the addressed 32-bit half (`amo_req_i.operand_a[2]`) and sign-extend it to 64 bits on `amo_resp_o.result`, and `axi_adapter_arbiter` must immediately forward the response to the requester and return to idle with zero outstanding count.

4. **Synthesis, area, and timing closure**:
   - Both `std_nbdcache` and `dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) must synthesize under Yosys + Slang with zero inferred latches.
   - When `dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) is synthesized against Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`) and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`) as documented in `BUILD.md`, mapped cell area must be **`<= 2,825.0 um^2`** and setup/hold slack must be **`>= 0.00 ns`** at a **`2.44 ns`** clock period (`0.20 ns` I/O delays, `5.0 fF` load). Edit only `code/cache_ctrl.sv`, `code/miss_handler.sv`, and `code/tag_cmp.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Synthesis/STA Environment

## Editable Files
Only the following files may be modified:
- `code/cache_ctrl.sv`
- `code/miss_handler.sv`
- `code/tag_cmp.sv`

All other files in `code/`, `include/`, `flow/`, `lib/`, and `lef/` are read-only.

## Compilation Order (`Verilator` / `Yosys -m slang`)
With `-Iinclude`:
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/axi_pkg.sv`
5. `code/ariane_pkg.sv`
6. `code/std_cache_pkg.sv`
7. `code/lfsr_8bit.sv`
8. `code/lfsr.sv`
9. `code/tc_sram.sv`
10. `code/tc_sram_wrapper.sv`
11. `code/sram.sv`
12. `code/axi_adapter.sv`
13. `code/tag_cmp.sv`
14. `code/cache_ctrl.sv`
15. `code/miss_handler.sv`
16. `code/std_nbdcache.sv`

## Synthesis, Area, and STA Target
`dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) is synthesized with `yosys -m slang`:
```
read_slang --ignore-assertions --top dcache_ctrl_top -Iinclude -DSYNTHESIS code/config_pkg.sv code/cv64a60ax_config_pkg.sv code/riscv_pkg.sv code/axi_pkg.sv code/ariane_pkg.sv code/std_cache_pkg.sv code/tag_cmp.sv code/cache_ctrl.sv flow/dcache_ctrl_top.sv
hierarchy -check -top dcache_ctrl_top
proc; opt_clean
select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top dcache_ctrl_top -flatten
opt
dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
abc -liberty lib/NangateOpenCellLibrary_typical.lib
clean
read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
check -assert
stat -liberty lib/NangateOpenCellLibrary_typical.lib
write_verilog -noattr mapped_dcache_ctrl.v
```
and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`, `lib/NangateOpenCellLibrary_typical.lib`) with:
- `create_clock -name clk_i -period 2.44 [get_ports clk_i]`
- `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
- `set_output_delay 0.20 -clock clk_i [all_outputs]`
- `set_load 5.0 [all_outputs]`
Targets:
- Zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`, `$_DLATCH`) across `std_nbdcache` and `dcache_ctrl_top`
- Mapped area `<= 2,825.0 um^2` on `dcache_ctrl_top`
- Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/cache_ctrl.sv`
- `code/miss_handler.sv`
- `code/tag_cmp.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
