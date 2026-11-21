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
