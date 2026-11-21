# CV32E40P Instruction Fetch Subsystem Hardware-Loop Redirects, Split-Parcel Bus-Error Attribution, and 1.25 ns Area/Timing Closure

In the CV32E40P instruction fetch subsystem (`code/rtl/cv32e40p_if_stage.sv`, `code/rtl/cv32e40p_aligner.sv`, `code/rtl/cv32e40p_prefetch_buffer.sv`, and `code/rtl/cv32e40p_prefetch_controller.sv` configured with `COREV_PULP = 1`, `PULP_OBI = 0`), hardware-loop redirects under downstream ID-stage stalls, compressed/misaligned loop boundaries, and instruction OBI bus-error handling fail subsystem verification and 800 MHz (`1.25 ns`) physical synthesis closure:

1. **Hardware-Loop Redirects and Speculative Response Flushing (`cv32e40p_prefetch_controller.sv`):**
   - When `hwlp_jump_i` asserts while the loop-end instruction word is already buffered at the head of the prefetch FIFO (`!fifo_empty_i`) or arrives from OBI under downstream backpressure (`!fetch_ready_i`), younger speculative OBI responses in flight after the loop-end word must be discarded without suppressing `fetch_valid_o` for a valid instruction word already held at the FIFO head, and without pushing a same-cycle younger wrong-path OBI response into a non-empty FIFO. `fifo_pop_o` must never assert on a cycle where `branch_i` is high.
   - If a hardware-loop redirect occurs when the FIFO is empty and the loop-end response has not yet returned from OBI, and a subsequent hardware-loop redirect or branch arrives before that delayed flush completes, any pending delayed flush state from the earlier redirect must be cancelled so post-redirect responses are not erroneously dropped.
   - If `hwlp_jump_i` asserts while a previous ungranted redirect is waiting for `trans_ready_i` (`!branch_i`), `trans_addr_o` must immediately switch to `{hwlp_target_i[31:2], 2'b00}`.
   - Outstanding OBI responses scheduled to be discarded will never occupy FIFO entries and must not block new instruction fetch requests (`trans_valid_o`) against the FIFO depth limit (`DEPTH`).

2. **Hardware-Loop Target PC Updates Across Compressed and Misaligned Parcels (`cv32e40p_aligner.sv`):**
   - A hardware-loop end instruction (`hwlp_update_pc_i`, asserted either on the instruction's retirement cycle or held across an upstream/downstream stall) may be a 32-bit or 16-bit compressed instruction retiring from any word-aligned, halfword-spanning, buffered upper-halfword, or halfword-branch-target alignment state.
   - When the loop-end instruction retires, `pc_o` must advance to the hardware-loop target address (`hwlp_addr_i`), and the aligner must fetch from the lower or upper halfword of the target word according to bit 1 of the target address (preventing any residual upper halfword from the loop-end word from being executed as the loop body start).

3. **End-to-End Instruction OBI Bus-Error Attribution and Post-Fault Speculative Freeze:**
   - Propagate OBI response errors (`instr_err_i` / `resp_err_o`) through `cv32e40p_prefetch_buffer` and `cv32e40p_fifo` alongside instruction data (`fetch_err_o`).
   - When a non-flushed OBI response returns with an error (`resp_err_i = 1'b1`) and no `branch_i` or `hwlp_jump_i` is active on that cycle, `cv32e40p_prefetch_controller` must halt new speculative instruction requests (`trans_valid_o = 1'b0`) until cleared by reset, `branch_i`, or `hwlp_jump_i`.
   - `cv32e40p_aligner` must attribute a bus error to the exact instruction that consumes the faulted 32-bit fetch word (`instr_err_o = 1'b1` with `instr_valid_o = 1'b1`):
     - If a complete 16-bit compressed instruction is already held in the aligner's upper-halfword buffer while the newly fetched next word carries an error, that buffered 16-bit instruction must retire normally (`instr_err_o = 1'b0`), and the error must be attributed to the subsequent instruction that consumes the faulted word.
     - Conversely, if a 32-bit instruction spans into a faulted new word, or an instruction starts in a faulted word, it must present `instr_valid_o = 1'b1` and `instr_err_o = 1'b1` without incrementing `pc_o`, and once accepted (`if_valid_i = 1'b1`), deassert `instr_valid_o`, `instr_err_o`, and `aligner_ready_o` until a `branch_i` redirect occurs.
   - In `cv32e40p_if_stage`, latch the aligner's error onto `is_fetch_failed_o` when transferring to ID (`if_valid && instr_valid`), force `illegal_c_insn_id_o` low whenever `is_fetch_failed_o` is set so bus faults take priority over illegal-instruction decoding, and clear both `instr_valid_id_o` and `is_fetch_failed_o` when `clear_instr_valid_i` asserts without a new transfer.

4. **Synthesis, Area, and Timing Closure (`BUILD.md`):**
   - Synthesize latch-free under `yosys -m slang` (`COREV_PULP = 1`, `PULP_OBI = 0`).
   - Under the Nangate45 synthesis and OpenROAD STA flow in `BUILD.md` (`1.25 ns` clock on `clk`, `0.15 ns` I/O delays, `5.0 fF` load), `cv32e40p_if_stage` must achieve mapped cell area **`<= 3,748.0 um^2`**, worst setup slack (`WNS`) **`>= 0.00 ns`**, and worst hold slack (`WHS`) **`>= 0.00 ns`**.
