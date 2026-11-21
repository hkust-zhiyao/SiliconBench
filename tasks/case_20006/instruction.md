# case_20006: Fix Parameterized Synthesis/Simulation Parity, Miss-Counter Saturation, BIST Drain, and SPM Way Isolation in axi_llc_hit_miss

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/axi_llc` (`repo_26`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/rtl/axi_llc_miss_counters.sv`, `code/rtl/axi_llc_tag_pattern_gen.sv`, `code/rtl/axi_llc_hit_miss.sv`

---

## Problem Specification

# Fix Parameterized Synthesis/Simulation Parity, Miss-Counter Saturation, BIST Drain, and SPM Way Isolation in `axi_llc_hit_miss`

## Problem Summary
The PULP AXI4 Last-Level Cache hit/miss detection subsystem (`axi_llc_hit_miss.sv`, `axi_llc_miss_counters.sv`, and `axi_llc_tag_pattern_gen.sv`) exhibits elaboration failures, RTL-vs-gate-level simulation parity hazards, and architectural deadlocks/aliasing across parameterized configurations.

## Architectural & Synthesis-Parity Contract

1. **Parameterized Elaboration & Gate-Level Synthesis Parity**:
   - `axi_llc_hit_miss`, `axi_llc_miss_counters`, and `axi_llc_tag_pattern_gen` must elaborate and synthesize cleanly (`yosys -m slang` and Verilator) with zero inferred latches and zero combinational loops across `AxiIdLookupBits == 0` (single shared miss counter), `0 < AxiIdLookupBits < AxiCfg.SlvPortIdWidth` (low-bit AXI ID folding), and `AxiIdLookupBits == AxiCfg.SlvPortIdWidth` (per-ID counters).
   - Post-synthesis gate-level behavior must match RTL cycle-for-cycle.

2. **In-Flight Miss Counter Saturation, Boundary Clamping, and Steering**:
   - Each per-ID-bucket counter (capacity `2**axi_llc_pkg::MissCntWidth`) and the global write counter (capacity `2**axi_llc_pkg::MissCntMaxWWidth`) must assert `stall_o` when any counter reaches full capacity.
   - `to_miss_o` must remain asserted (`1'b1`) whenever the mapped bucket counter is non-zero—**including when saturated at `2**MissCntWidth`**—and, for write descriptors (`rw == 1'b1`), whenever the global write counter is non-zero (**including when saturated at `2**MissCntMaxWWidth`**).
   - Counters must hold steady under simultaneous matching increment/decrement handshakes, clamp without wrap-around or underflow at `0` and `2**Width` boundaries, and avoid combinational paths from `cnt_up_i.valid` / `cnt_down_i.valid` into `to_miss_o` or `stall_o`.

3. **March-X Tag BIST Multi-Cycle Drain & 4-State Qualification**:
   - Across arbitrary read latencies (`TagMacroLatency >= 1`, including `TagMacroLatency >= Cfg.NumLines`), `axi_llc_tag_pattern_gen` must check all `Cfg.NumLines` ascending and descending read responses—including trailing pipeline-drain beats—drive the expected pattern consistently throughout each read phase, qualify sticky per-way failure accumulation (`bist_res_o`) strictly with `bist_res_valid_i` so uninitialized/`X` buses never corrupt results, and reset sticky status/`eoc_o` cleanly if BIST is re-invoked.

4. **SPM / Flushed Way Isolation & Zero-Cache-Way Error Steering**:
   - Normal cache lookups (`!spm && !flush`) must never hit or allocate ways marked in `spm_lock_i` or `flushed_i`.
   - When all ways are locked as SPM or flushed (`(spm_lock_i | flushed_i) == '1`), normal cache lookups must not deadlock tag lookup/eviction; instead, they must complete in-order (`hit_valid_o` vs `miss_valid_o` governed by `to_miss`, respecting line locks and `cnt_stall`) with `x_resp = axi_pkg::RESP_SLVERR`, `evict = 1'b0`, `refill = 1'b0`, and `way_ind = way_ind_t'(1)`.

## Scope & Deliverables
- Editable files: `code/rtl/axi_llc_miss_counters.sv`, `code/rtl/axi_llc_tag_pattern_gen.sv`, and `code/rtl/axi_llc_hit_miss.sv`.
- Preserve all module names, parameter signatures, port interfaces, and read-only collateral in `code/`.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment

## Editable RTL
- `code/rtl/axi_llc_miss_counters.sv`
- `code/rtl/axi_llc_tag_pattern_gen.sv`
- `code/rtl/axi_llc_hit_miss.sv`

## Read-Only Context & Dependencies
- `code/rtl/axi_llc_pkg.sv`, `code/rtl/axi_llc_tag_store.sv`, `code/rtl/axi_llc_evict_box.sv`, `code/rtl/axi_llc_lock_box_bloom.sv`, `code/rtl/tc_sram.sv`
- `code/common_cells/` and `code/axi/`

## Toolchain
- SystemVerilog Simulation: `verilator`
  ```bash
  verilator --binary --timing -Wno-fatal -j 1 \
    +incdir+code/common_cells/include +incdir+code/axi/include \
    code/common_cells/src/cb_filter_pkg.sv \
    code/common_cells/src/cf_math_pkg.sv \
    code/axi/src/axi_pkg.sv \
    code/rtl/axi_llc_pkg.sv \
    code/common_cells/src/delta_counter.sv \
    code/common_cells/src/counter.sv \
    code/common_cells/src/lzc.sv \
    code/common_cells/src/onehot_to_bin.sv \
    code/common_cells/src/fifo_v3.sv \
    code/common_cells/src/rr_arb_tree.sv \
    code/common_cells/src/shift_reg_gated.sv \
    code/common_cells/src/shift_reg.sv \
    code/common_cells/src/spill_register_flushable.sv \
    code/common_cells/src/spill_register.sv \
    code/common_cells/src/sub_per_hash.sv \
    code/common_cells/src/cb_filter.sv \
    code/rtl/tc_sram.sv \
    code/rtl/axi_llc_miss_counters.sv \
    code/rtl/axi_llc_tag_pattern_gen.sv \
    code/rtl/axi_llc_evict_box.sv \
    code/rtl/axi_llc_tag_store.sv \
    code/rtl/axi_llc_lock_box_bloom.sv \
    code/rtl/axi_llc_hit_miss.sv
  ```
- SystemVerilog Synthesis (`yosys+slang`): `yosys -m slang`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/rtl/axi_llc_miss_counters.sv`
- `code/rtl/axi_llc_tag_pattern_gen.sv`
- `code/rtl/axi_llc_hit_miss.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
