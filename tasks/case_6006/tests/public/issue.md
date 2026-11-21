# VeeR-EH1 IFU Branch Predictor (BTB/BHT/RAS), I-Cache/ICCM Memory Controller, and Fetch Pipe Closure

In `code/veer_ifu_bp_mem_top.sv`, the fetch pipeline controller (`code/ifu_ifc_ctl.sv`), the branch target buffer, gshare branch history table, and 4-entry return address stack (`code/ifu_bp_ctl.sv`), and the I-Cache/ICCM memory and miss/error controller (`code/ifu_mem_ctl.sv`) are integrated together.

Update only `code/ifu_ifc_ctl.sv`, `code/ifu_bp_ctl.sv`, and `code/ifu_mem_ctl.sv` to satisfy all functional, synthesis, and static timing contracts:

1. **Fetch Pipe Control & MRAC/ICCM Address Protection (`code/ifu_ifc_ctl.sv`)**:
   - Determine F1 fetch cacheability from the cacheability bit (even bit) of the 2-bit MRAC region descriptor in `dec_tlu_mrac_ff` for the current 256 MB region (`ifc_fetch_addr_f1[31:28]`).
   - Classify F1 accesses in region `0xe` into valid ICCM accesses (`[0xee000000, 0xee07ffff]`) versus out-of-range ICCM region access faults, and coordinate F1/F2 fetch requests across flushes, BTB taken redirects, fetch-buffer occupancy, and critical-word bypass readiness.

2. **BTB, Gshare BHT & Return Address Stack (`code/ifu_bp_ctl.sv`)**:
   - Push the sequential link address (`PC + 4` for 32-bit calls or `PC + 2` for 16-bit calls) onto the 4-entry return address stack on taken F2 BTB call hits, and drive the top of the return address stack onto `ifu_bp_btb_target_f2` while popping the stack on taken F2 BTB return hits (that are not simultaneously marked as calls).
   - When a 4-byte branch straddles two fetch groups such that its upper halfword hits in halfword lane 0 of the current F2 fetch group, compute its branch target relative to the prior fetch group's upper address (offset `3'b111`).
   - Resolve BHT bank/index writes so each source writes its own 2-bit history counter and simultaneous writes to the same bank and index obey strict priority: WB slot-0 branch update (`dec_tlu_br0_wb_pkt`) highest, WB slot-1 branch update (`dec_tlu_br1_wb_pkt`) second, and EXU mispredict update (`exu_mp_pkt`) lowest.

3. **I-Cache Miss/Critical-Word Bypass & ICCM ECC Repair Control (`code/ifu_mem_ctl.sv`) & PPA/STA Closure**:
   - Issue and complete uncacheable I-Cache misses in 2 AXI read beats (versus 8 AXI read beats for cacheable line-fill misses); assemble the two 64-bit critical-word beats and assert `ic_crit_wd_rdy` as soon as the second critical half arrives so the miss state machine can complete and return to idle.
   - Propagate F2 region/bus access faults (`ic_access_fault_f2`). On single-bit ICCM ECC errors, wait for pipeline flush and transition into the single-bit ECC correction state when `exu_flush_final` is accompanied by `dec_tlu_flush_err_wb` (or immediately on DMA single-bit ECC errors), asserting both `ic_dma_active` and `iccm_wren` to scrub the corrected word back into ICCM, while returning to idle if `exu_flush_final` occurs without `dec_tlu_flush_err_wb`.
   - The RTL must synthesize without latches. Under the `BUILD.md` Yosys/Slang Nangate45 and OpenROAD STA flow (`3.65 ns` clock on `clk`, `0.15 ns` I/O delays, `5.0 fF` load), `veer_ifu_bp_mem_top` must achieve mapped cell area `<= 27,850.0 um^2`, worst setup slack (`WNS`) `>= 0.00 ns`, and worst hold slack (`WHS`) `>= 0.00 ns`.
