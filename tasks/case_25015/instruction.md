# case_25015: Snitch Multi-Core Isochronous Sv32 VM, Shared RV32M Hub, 4-State GLS & Multi-Corner STA Signoff

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/snitch` (`repo_22`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/snitch_clkdiv2.sv`, `code/snitch_l0_tlb.sv`, `code/snitch_ptw.sv`, `code/snitch_shared_muldiv.sv`, `code/snitch_iso_hive.sv`, `constraints/snitch_iso_hive.sdc`

---

## Problem Specification

# Snitch Multi-Core Isochronous Sv32 VM, Shared RV32M Hub & Multi-Corner STA Signoff

## Overview
`snitch_iso_cluster_subsys` (`code/snitch_iso_cluster_subsys.sv`, read-only) integrates `CoreCount` (`2` or `4`) dual-port L0 TLBs (`ch = 2*core + port`; port `0` = ITLB, port `1` = DTLB) bridged via synchronous 1:2 isochronous crossings (`clk_i <-> clk_d2`) into `snitch_iso_hive`, `snitch_clkdiv2`, `snitch_ptw`, and `snitch_shared_muldiv`. You own the RTL-to-STA co-design across:
- `code/snitch_clkdiv2.sv`, `code/snitch_l0_tlb.sv`, `code/snitch_ptw.sv`, `code/snitch_shared_muldiv.sv`, `code/snitch_iso_hive.sv`
- `constraints/snitch_iso_hive.sdc`

All other files under `code/` and `lib/` are read-only collateral.

## Architectural, 4-State Gate-Level & Protocol Contract
1. **Isochronous Clock Division & 4-State Reset Cleanliness**:
   - Across asynchronous active-low reset (`rst_ni == 0`) and post-reset execution, both 1:2 divided-clock operation (`clk_d2_bypass_i = 0`, `test_mode_i = 0`) and 1:1 bypass operation (`clk_d2_bypass_i = 1`) must initialize deterministically without `X`/`Z` clock or handshake lockup in 4-state gate-level simulation.
2. **Multi-Core Dual-Port Sv32 Address Translation (`AddrWidth = 34`, `NrTlbEntries = 2`)**:
   - Independently service ITLB (`port 0`) and DTLB (`port 1`) lookups across all `CoreCount` cores without cross-port or cross-core VA/PPN/PTE aliasing, supporting both `4 KiB` two-level (`lvl 0 -> lvl 1`) and `4 MiB` superpage (`lvl 0` leaf) translations, retaining `NrTlbEntries` active translations per L0 TLB via round-robin replacement without redundant PTW memory reads, and invalidating all entries upon a `tlb_req_flush_i[ch]` handshake.
   - Enforce Sv32 PTE fault semantics (`tlb_rsp_fault_o[ch] = 1`): leaf pages require `V=1`, `A=1`, `!(R==0 && W==1)`, privilege match (`U=1` in `PRIV_U`, `U=0` in `PRIV_S`), `D=1` on writes (`tlb_req_write_i`), `R=1` on data reads (`tlb_req_read_i`, so execute-only `X=1, R=0` pages permit `tlb_req_exec_i` fetches while faulting data reads), `W=1` on writes, and `X=1` on instruction fetches. non-leaf pointers (`V=1, R=W=X=0`) are valid only at level 0 (level-1 pointers fault), misaligned level-0 superpages (`pte.pa[9:0] != 0`) must fault without corrupting subsequent `4 KiB` walks in that `4 MiB` region, and PTW memory errors (`ptw_mem_perror_i = 1`) must fault the miss (`tlb_rsp_fault_o[ch] = 1`) without poisoning subsequent translations to other pages in the same `4 MiB` region.
3. **Shared RV32M Offload & Exception Retirement (`DataWidth = 32`)**:
   - Execute concurrent multi-core `MUL`, `MULH`, `MULHSU`, `MULHU`, `DIV`, `DIVU`, `REM`, and `REMU` offloads (including RISC-V divide-by-zero and signed overflow corner cases), preserving per-core `acc_qid_i -> acc_pid_o` tags under backpressure.
   - Unsupported `acc_qop_i` encodings must complete the `acc_qvalid_i`/`acc_qready_o` request handshake and retire a response beat (`acc_pvalid_o`/`acc_pready_i`) with matching `acc_pid_o` and `acc_perror_o = 1'b1` instead of stalling the shared arbiter.

## Synthesis & Multi-Corner Nangate45 STA Signoff (`CoreCount = 4`)
- **Netlist Integrity**: Synthesize cleanly to Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`) with zero inferred latches, zero combinational loops, and `snitch_clkdiv2` hierarchy preserved.
- **SDC (`constraints/snitch_iso_hive.sdc`)**:
  - Constrain `clk_i` with `create_clock` at period `<= 3.15` ns, set `set_case_analysis 0` on `test_mode_i` and `clk_d2_bypass_i`, and declare `create_generated_clock -divide_by 2 -source [get_ports clk_i]` on the `snitch_clkdiv2` divider pin (`*i_snitch_clkdiv2*`).
  - Specify `set_clock_uncertainty` `>= 0.08` ns (setup) and `>= 0.02` ns (hold) on all clocks, and constrain all synchronous data/handshake inputs and all outputs against `clk_i`'s clock with `-max >= 0.40` ns and `0.02 <= -min <= 0.10` ns.
  - Only `rst_ni` may carry `set_false_path`; `set_clock_groups`, `set_multicycle_path`, `set_max_delay`, `set_min_delay`, and `set_disable_timing` are prohibited.
- **Multi-Corner Signoff**: Must achieve `WNS >= 0.0` ns (setup) and `min slack >= 0.0` ns (hold) in OpenROAD STA across slow (`-late 1.25 -early 1.00`) and fast (`-late 1.00 -early 0.75`) derate corners in both 1:2 divided (`clk_d2_bypass_i = 0`) and 1:1 bypass (`clk_d2_bypass_i = 1`) modes.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment (`case_25015`)

## Available Tools & Collateral
- **RTL Simulation**: Verilator (`verilator --binary --timing`)
- **4-State Gate-Level Simulation**: Yosys (`yosys -m slang`) + Icarus Verilog (`iverilog -g2012` / `vvp`) with Yosys `simcells.v`
- **Technology Mapping & Multi-Corner STA**: Yosys + OpenROAD (`openroad -exit`) using Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`, `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`)

## Editable Files
- `code/snitch_clkdiv2.sv`
- `code/snitch_l0_tlb.sv`
- `code/snitch_ptw.sv`
- `code/snitch_shared_muldiv.sv`
- `code/snitch_iso_hive.sv`
- `constraints/snitch_iso_hive.sdc`

## Example Commands
```bash
# 1. Verilator Elaboration & Lint (CoreCount = 2 or 4)
verilator --lint-only -Wno-fatal -Wno-UNOPTFLAT -GCoreCount=4 -Icode \
  -top-module snitch_iso_cluster_subsys \
  code/dm_pkg.sv code/axi_pkg.sv code/cf_math_pkg.sv code/reqrsp_pkg.sv \
  code/riscv_instr.sv code/snitch_pkg.sv code/cc_onehot.sv code/lzc.sv \
  code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
  code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
  code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
  code/reqrsp_iso.sv code/snitch_clkdiv2.sv code/snitch_l0_tlb.sv \
  code/snitch_ptw.sv code/snitch_shared_muldiv.sv code/snitch_iso_hive.sv \
  code/snitch_iso_cluster_subsys.sv

# 2. Nangate45 Synthesis (CoreCount = 4, preserving snitch_clkdiv2)
yosys -m slang -p "
  read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -Icode \
    code/dm_pkg.sv code/axi_pkg.sv code/cf_math_pkg.sv code/reqrsp_pkg.sv \
    code/riscv_instr.sv code/snitch_pkg.sv code/cc_onehot.sv code/lzc.sv \
    code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
    code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
    code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
    code/reqrsp_iso.sv code/snitch_clkdiv2.sv code/snitch_l0_tlb.sv \
    code/snitch_ptw.sv code/snitch_shared_muldiv.sv code/snitch_iso_hive.sv \
    code/snitch_iso_cluster_subsys.sv --top snitch_iso_cluster_subsys -G CoreCount=4;
  hierarchy -check -top snitch_iso_cluster_subsys;
  setattr -mod -set keep_hierarchy 1 snitch_clkdiv2;
  synth -noabc -top snitch_iso_cluster_subsys -flatten;
  delete t:\$scopeinfo; scc -expect 0;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -script +strash\;scorr\;dc2\;strash\;dch,-f\;map\;buffer,-N,8;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/ng45.v
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/snitch_clkdiv2.sv`
- `code/snitch_l0_tlb.sv`
- `code/snitch_ptw.sv`
- `code/snitch_shared_muldiv.sv`
- `code/snitch_iso_hive.sv`
- `constraints/snitch_iso_hive.sdc`

All other files in the workspace are read-only reference context and must remain unmodified.
