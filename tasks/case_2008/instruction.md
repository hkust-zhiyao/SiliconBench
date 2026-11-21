# case_2008: Ibex Scrambling Two-Way ICache, IF Stage, Compressed Decoder, and Transparent Channel Timing Budgets

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/ibex` (`repo_02`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Task-Specific Multi-Corner Liberty & SDC Timing Views`
> - **Editable Files (`allowed_edits`)**: `code/ibex_icache.sv`, `code/ibex_if_stage.sv`, `code/ibex_compressed_decoder.sv`, `constraints.json`

---

## Problem Specification

# Ibex Scrambling Two-Way ICache, IF Stage, Compressed Decoder, and Transparent Channel Timing Budgets

In the Ibex instruction cache and fetch front-end (`code/ibex_icache_if_subsys_top.sv`, integrating `code/ibex_icache.sv`, `code/ibex_if_stage.sv`, and `code/ibex_compressed_decoder.sv` with `ICache=1`, `ICacheECC=1`, `ICacheTweakInfection=1`, `MemECC=1`, `BranchPredictor=1`, `DummyInstructions=1`, and `BaseIsa=BaseIsaRV32IorCHERIoT`), functional verification and OpenSTA boundary timing checks currently fail:

1. **Scrambling Key Handshake, Cache Invalidation Sweep, Tweak Infection, ECC Recovery, and Unaligned Skid Faults (`code/ibex_icache.sv`)**:
   - **Scramble Key Request & Invalidation Restart**: Out of reset, if `ic_scr_key_valid_i` is low, the cache must assert `ic_scr_key_req_o` while transitioning to wait for the key. Once `ic_scr_key_valid_i` is high, it sweeps all tag indices (`0 .. 2^IC_INDEX_W - 1`). If a new `icache_inval_i` pulse arrives either during normal idle operation or while an invalidation sweep is already in progress, the cache must immediately request a new scramble key (`ic_scr_key_req_o = 1'b1`), return to wait for `ic_scr_key_valid_i`, and restart the tag sweep from index `0`.
   - **Address Tweak Infection (`TweakInfection == 1`)**: Tag writes and reads must XOR/un-XOR the replicated tag index tweak, and data writes and reads must XOR/un-XOR the replicated line-aligned address tweak. During tag invalidation sweeps or single-index ECC correction writebacks, the data address tweak must be forced to zero.
   - **28-Bit Tag & 39-Bit Data SECDED ECC Recovery (`ICacheECC == 1`)**: Tag ECC is checked across all ways on every valid lookup, whereas data ECC must be checked only when a lookup hits a valid tag way (avoiding false ECC errors on cache misses where data RAM lines are uninitialized). Any tag or data ECC error on a valid lookup must assert `ecc_error_o`, suppress the cache hit so the fill buffer fetches the line from external memory instead, and perform a one-cycle tag invalidation write (`ic_tag_write_o = 1'b1` with invalid tag) on the following cycle (invalidating all ways on a tag ECC error, or the matching way(s) on a data ECC error).
   - **Unaligned 32-Bit Instruction Skid Buffer Fault Attribution**: When a 32-bit instruction spans two 32-bit beats (`addr_o[1] == 1'b1`) via the 16-bit skid buffer, an error on the first beat must report `err_o = 1'b1, err_plus2_o = 1'b0` immediately without waiting for the second beat, whereas a clean first beat followed by an error on the second beat must report `err_o = 1'b1, err_plus2_o = 1'b1`.

2. **Memory Bus SECDED Integrity, Branch Misprediction Squash, and Zcmp Expansion (`code/ibex_if_stage.sv`, `code/ibex_compressed_decoder.sv`)**:
   - In `code/ibex_if_stage.sv`, 39-bit SECDED integrity errors on incoming `instr_rdata_i` (`MemECC == 1`) must both assert `instr_intg_err_o` (when `instr_rvalid_i` is high) and propagate as an instruction fetch error into `ibex_icache`. When `nt_branch_mispredict_i` asserts to cancel a predicted-taken branch, any instruction simultaneously presented by `ibex_icache` must be squashed rather than entering the IF/ID pipeline or branch-predictor skid buffer.
   - In `code/ibex_compressed_decoder.sv`, `cm.pop`, `cm.popret`, and `cm.popretz` must mark intermediate stack-pointer adjustment (`addi x2, x2, sp_adj`) and `addi a0, x0, 0` steps with `INSTR_EXPANDED_COMMIT` (and `INSTR_EXPANDED_LAST` on the final step), and any exception redirect (`pc_set_i && pc_mux_i == PC_EXC`) must synchronously flush the Zcmp expansion state back to idle.

3. **Declarative Boundary Timing Budgets for Monitoring Channels (`constraints.json`)**:
   - In `code/ibex_icache_if_subsys_top.sv`, the subsystem operates at `10.0 ns` and `12.0 ns` clock periods (`clk_i`), with a `3.5 ns` external input delay on all non-clock inputs and a `3.0 ns` external output delay on all outputs. Constrain the two zero-cut 8-bit combinational monitoring channels in `constraints.json` (`"max_delays"`) using the schema in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.25 ns` for `scr_mon_in` to `scr_mon_out` and `2.25 ns` for `pmp_mon_in` to `pmp_mon_out`, while preserving the existing timing requirements for all other ports.

Edit only `code/ibex_icache.sv`, `code/ibex_if_stage.sv`, `code/ibex_compressed_decoder.sv`, and `constraints.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following four files are collected and graded:
- `code/ibex_icache.sv`
- `code/ibex_if_stage.sv`
- `code/ibex_compressed_decoder.sv`
- `constraints.json`

All other files in `code/` and `lib/` (`code/ibex_icache_if_subsys_top.sv`, `code/ibex_pkg.sv`, `code/ibex_cheriot_pkg.sv`, `code/ibex_fetch_fifo.sv`, `code/ibex_prefetch_buffer.sv`, `code/ibex_dummy_instr.sv`, `code/ibex_branch_predict.sv`, `code/prim_*`, `code/dv_fcov_macros.svh`, `lib/*`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/ibex_icache_if_subsys_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Werror-LATCH -Wno-fatal -DSYNTHESIS -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/prim_util_pkg.sv code/prim_cipher_pkg.sv code/prim_secded_pkg.sv \
  code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
  code/prim_buf.sv code/prim_lfsr.sv \
  code/prim_secded_inv_28_22_dec.sv code/prim_secded_inv_28_22_enc.sv \
  code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
  code/ibex_fetch_fifo.sv code/ibex_prefetch_buffer.sv code/ibex_icache.sv \
  code/ibex_dummy_instr.sv code/ibex_branch_predict.sv \
  code/ibex_compressed_decoder.sv code/ibex_if_stage.sv \
  code/ibex_icache_if_subsys_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names:
- Input groups include `scr_mon_in` (or `scr_mon_in[0..7]`), `pmp_mon_in` (or `pmp_mon_in[0..7]`), and the functional inputs of `ibex_icache_if_subsys_top`.
- Output groups include `scr_mon_out` (or `scr_mon_out[0..7]`), `pmp_mon_out` (or `pmp_mon_out[0..7]`), and the functional outputs of `ibex_icache_if_subsys_top`.
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10.0 ns` or `12.0 ns` on `clk_i`), `3.5 ns` input delay on all non-clock inputs (`set_input_delay 3.5 -clock clk_i`), and `3.0 ns` output delay on all outputs (`set_output_delay 3.0 -clock clk_i`), using `lib/NangateOpenCellLibrary_typical.lib` and OpenROAD/OpenSTA. Zero latches are allowed.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ibex_icache.sv`
- `code/ibex_if_stage.sv`
- `code/ibex_compressed_decoder.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
