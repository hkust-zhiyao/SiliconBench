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
