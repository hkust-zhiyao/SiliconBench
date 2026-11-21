# Sv32 Translation, Page-Table Walk Coherence, and Fault Ordering in `biriscv_mmu`

`code/biriscv_mmu.v` exhibits virtual-memory translation, TLB coherence, and downstream response-ordering bugs across its instruction TLB, data TLB, two-level Sv32 hardware page-table walker (PTW), and shared downstream D-cache port.

Fix `code/biriscv_mmu.v` while preserving its module interface and parameters (`MEM_CACHE_ADDR_MIN`, `MEM_CACHE_ADDR_MAX`, `SUPPORT_MMU`):

1. **RISC-V Sv32 Translation & Non-Updating PTE Semantics (`SUPPORT_MMU = 1` / `0`)**:
   - Bypass translation cleanly when `SUPPORT_MMU = 0`, in Machine mode, or when `satp` selects Bare mode (`MODE == 0`) on both instruction fetch and data accesses.
   - Enforce full RISC-V Privileged Sv32 PTE validation across both walk levels and 4 MiB superpages (including PTW bus errors, invalid/reserved PTE encodings, non-leaf entries at the final level, misaligned superpage physical frame numbers, non-updating `A`/`D` fault rules, and `U`/`S` privilege checks with `sum_i` and `mxr_i`).

2. **In-Flight PTW Address Stability & `SFENCE.VMA` (`flush_i`) Coherence**:
   - Complete an initiated PTW using the virtual address that triggered the walk even if `fetch_in_pc_i` or `lsu_in_addr_i` changes before the walk finishes, installing a valid translation in a single walk without redundant re-walks.
   - Ensure `flush_i` invalidates cached ITLB/DTLB translations and prevents any PTW already in flight across the flush from installing a stale TLB entry, without stranding or corrupting already-issued downstream PTW memory reads.

3. **Request Retention & Strictly In-Order Fault Serialization**:
   - Retain any unaccepted D-side request (load, store, or cache maintenance) until `lsu_in_accept_o` completes the handshake, even if upstream deasserts request strobes after the initial cycle.
   - Preserve strictly in-order response/fault delivery on both the I-side (`fetch_in_valid_o` / `fetch_in_fault_o`) and D-side (`lsu_in_ack_o` / `lsu_in_load_fault_o` / `lsu_in_store_fault_o`) when a younger TLB/page fault follows an older still-pending downstream cache transaction.
