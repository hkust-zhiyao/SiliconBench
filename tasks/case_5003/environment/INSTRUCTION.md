# case_5003: CVA6 Sv39+Svnapot MMU Shared-TLB Arbitration, NAPOT Set Indexing, PLRU Refill, and PTW Flush Control

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cva6` (`repo_05`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library (Shared Base Image)`
> - **Editable Files (`allowed_edits`)**: `code/cva6_tlb.sv`, `code/cva6_shared_tlb.sv`, `code/cva6_ptw.sv`

---

## Problem Specification

# CVA6 Sv39 + Svnapot MMU Shared-TLB Arbitration, NAPOT Set Aliasing, L1 Replacement, PTW Flush Cancellation, and Area/Timing Closure

In the 64-bit CVA6 Sv39/Sv39x4 MMU subsystem (`code/cva6_mmu.sv`, `code/cva6_tlb.sv`, `code/cva6_shared_tlb.sv`, and `code/cva6_ptw.sv`) with `UseSharedTlb = 1` and `SvnapotEn = 1`, instruction and data address translation exhibit four functional defects under concurrent L1/L2 lookups, 64KiB NAPOT translations, back-to-back L1 refills, and speculative pipeline flushes:

1. **Instruction translation starvation during data TLB hits**:
   - When instruction fetch misses in the L1 ITLB while the LSU simultaneously performs a data translation that **hits** in the L1 DTLB (or when data translation is disabled), the shared TLB fails to service the instruction TLB miss. Data accesses must only take priority over instruction accesses at the shared TLB when the data access itself misses in the L1 DTLB with data translation enabled.

2. **64KiB Svnapot set aliasing and concurrent walk stage-mode corruption in the shared TLB**:
   - Under `SvnapotEn = 1`, a 64KiB NAPOT leaf PTE (`pte.n = 1`, `pte.ppn[3:0] = 4'b1000` at the 4KiB level) covers all 16 contiguous 4KiB subpages (`vaddr[15:12] = 0..15`). Currently, installing a 64KiB NAPOT translation via one subpage and subsequently looking up a different subpage within the same 64KiB region misses in the shared TLB because the shared-TLB set index is derived from virtual address bits inside the 64KiB NAPOT subpage offset instead of VPN bits above the 64KiB boundary.
   - Furthermore, when a shared-TLB miss initiates a hardware page-table walk, if the other TLB port accesses the shared TLB while the walk is in flight (under a different virtualization or stage-enable configuration between instruction fetch and load/store), the eventual shared-TLB refill records the wrong requester's virtualization/stage-enable attributes.

3. **Repeated way-0 overwrite on consecutive L1 TLB refills**:
   - In the fully associative L1 TLB (`code/cva6_tlb.sv`), installing a valid refill (`update_i.valid` when not already hitting on `lu_hit_o`) does not advance the pseudo-LRU replacement state for the newly written way—causing consecutive refills on distinct virtual pages to repeatedly overwrite entry `0` instead of populating all ways.

4. **Spurious PTW activation and unsuppressed refill/fault pulses on `flush_i`**:
   - Asserting `flush_i` while the page-table walker (`code/cva6_ptw.sv`) is idle causes `ptw_active_o` to assert on the following cycle (and fails to suppress `shared_tlb_miss_o` if a shared-TLB miss coincides with `flush_i`).
   - Asserting `flush_i` on the cycle a leaf PTE lookup completes or an error/PMP access fault is being propagated fails to suppress `shared_tlb_update_o.valid`, `ptw_error_o`, and `ptw_access_exception_o` on that cycle.

5. **L1 TLB area and timing closure**:
   - When `cva6_tlb` (`TLB_ENTRIES = 2`, `HYP_EXT = 0`, `RVH = 0`, `SvnapotEn = 1`) is synthesized with Yosys + Slang against Nangate45 (`NangateOpenCellLibrary_typical.lib`) as documented in `BUILD.md`, the mapped cell area must not exceed **`2,260.0 um^2`** (with zero inferred latches across the MMU hierarchy), and must achieve nonnegative setup and hold slack (`>= 0.00 ns`) in OpenSTA at a **`2.42 ns`** clock period (`0.20 ns` input/output delays, `5.0 fF` output load).

---

## Build, Simulation, and EDA Verification Instructions

# Build and Verification Environment

## Source and Dependency Order
The MMU and PMP modules are extracted from CVA6 (`repo_05`), with open-licensed `lzc.sv`, `cf_math_pkg.sv`, and `include/common_cells/assertions.svh` from Croc `common_cells`.

Compilation order (with `-Iinclude` in the include search path):
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/ariane_pkg.sv`
5. `code/cf_math_pkg.sv`
6. `code/lzc.sv`
7. `code/lfsr.sv`
8. `code/tc_sram.sv`
9. `code/tc_sram_wrapper.sv`
10. `code/sram.sv`
11. `code/pmp_entry.sv`
12. `code/pmp.sv`
13. `code/pmp_data_if.sv`
14. `code/cva6_tlb.sv`
15. `code/cva6_shared_tlb.sv`
16. `code/cva6_ptw.sv`
17. `code/cva6_mmu.sv`

## Editable Files
Only the following files may be modified:
- `code/cva6_tlb.sv`
- `code/cva6_shared_tlb.sv`
- `code/cva6_ptw.sv`

All other files in `code/` and `include/` are read-only.

## Synthesis, Area, and STA Target
1. The full MMU hierarchy (`cva6_mmu`) must elaborate cleanly under Verilator 5 and synthesize under Yosys (`yosys -m slang`) with zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`).
2. `cva6_tlb` (`TLB_ENTRIES = 2`, `HYP_EXT = 0`, `XLEN = 64`, `VLEN = 64`, `PLEN = 56`, `GPLEN = 41`, `PPNW = 44`, `GPPNW = 29`, `PtLevels = 3`, `VpnLen = 27`, `SV = 39`, `SVX = 41`, `ASID_WIDTH = 16`, `VMID_WIDTH = 14`, `SvnapotEn = 1`, `RVH = 0`) is synthesized with `yosys -m slang`:
   ```
   synth -top tlb_top -flatten
   opt
   dfflibmap -liberty NangateOpenCellLibrary_typical.lib
   abc -liberty NangateOpenCellLibrary_typical.lib
   clean
   stat -liberty NangateOpenCellLibrary_typical.lib
   ```
   and timed in OpenROAD/OpenSTA with:
   - `create_clock -name clk_i -period 2.42 [get_ports clk_i]`
   - `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
   - `set_output_delay 0.20 -clock clk_i [all_outputs]`
   - `set_load 5.0 [all_outputs]`
   Targets:
   - Mapped area `<= 2,260.0 um^2`
   - Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/cva6_tlb.sv`
- `code/cva6_shared_tlb.sv`
- `code/cva6_ptw.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
