# VeeR EH2 Dual-Thread LSU DCCM, SECDED ECC, Atomic RMW, and Coalescing Store-Buffer Subsystem Closure

In the VeeR EH2 dual-thread Load/Store Unit subsystem (`code/eh2_lsu_subsys_top.sv`), regressions across `code/eh2_lsu_amo.sv`, `code/eh2_lsu_ecc.sv`, `code/eh2_lsu_dccm_ctl.sv`, and `code/eh2_lsu_stbuf.sv` cause data corruption and false ECC errors under concurrent pipeline traffic:

1. **Atomic RMW & Store-Conditional (`SC.W`) Datapath**: Signed `AMOMIN.W` and `AMOMAX.W` comparisons produce wrong results on same-sign operands, and `SC.W` transactions fail to route store data on success or preserve ECC-corrected memory data (without upper-channel store-buffer bypass interference) when the reservation check fails.
2. **Sub-Word ECC Merge, Scrubbing & Hazard Qualification**: Odd-offset sub-word stores misalign byte enables during ECC data merge; DC3/DC5 ECC error reporting and scrub writeback mishandle single-bank accesses, faulting accesses, store-buffer RAW forwarding, younger in-flight DMA stores targeting the same word, single-bank scrub port replication, and store-buffer drain bypass into DC2 stores.
3. **Coalescing Store Buffer & Load Forwarding Priority**: DC5 store coalescing and store-buffer draining mishandle draining/DMA-killed entries and unwritten background bytes during partial-word merges, while DC2 load byte forwarding violates youngest-first pipeline priority (`DC3 -> DC4 -> DC5 -> store buffer`).

Update only `code/eh2_lsu_amo.sv`, `code/eh2_lsu_ecc.sv`, `code/eh2_lsu_dccm_ctl.sv`, and `code/eh2_lsu_stbuf.sv`. The subsystem must synthesize without latches under the Yosys/Slang Nangate45 flow (`BUILD.md`) with mapped cell area `<= 17,050.0 um^2`, and meet OpenROAD static timing at a `3.15 ns` clock period on `clk` (`0.15 ns` I/O delays, `5.0 fF` output load) with worst setup slack (`WNS`) `>= 0.00 ns` and worst hold slack (`WHS`) `>= 0.00 ns`.

