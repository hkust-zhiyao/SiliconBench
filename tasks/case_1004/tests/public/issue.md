# Two-Channel OpenTitan SRAM Crossbar Stall Stability, Bounded Fairness, and Atomic Store Forwarding

In `code/ot_sram_xbar_2ch.sv`, update only `code/prim_arbiter_tree.sv` and `code/prim_sram_arbiter.sv` so that all boundary ports of `ot_sram_xbar_2ch` satisfy the following protocol and physical closure requirements:

1. **Stall Stability, Bounded Fairness, and Atomic Store Forwarding**:
   - Whenever `ot_sram_xbar_2ch` presents a valid downstream SRAM request (`sram_req_o == 1`) while stalled (`sram_gnt_i == 0`), the selected channel and requester as well as `sram_addr_o`, `sram_write_o`, `sram_amo_write_o`, `sram_wdata_o`, and `sram_wmask_o` must remain locked and invariant across rising `clk_i` edges until granted (`sram_gnt_i == 1`), even if contenders on either channel assert new requests or `arb_policy_i` changes mid-stall. All arbitration state in both modules must advance only on a granted handshake and reset to zero on `rst_ni == 0`.
   - Under `arb_policy_i[c] == 1` (`c` in `{0, 1}`), any requester on channel `c` holding `req_chc_i` must be granted by its channel tree after at most `P_c - 1` other grants on channel `c` (`P_c = 1 << $clog2(N_CHc)`), while `arb_policy_i[c] == 0` retains its `0 .. N_CHc - 1` round-robin counter.
   - `prim_sram_arbiter` must alternate channel priority away from the granted channel (`rr_flag_q <= ~sel_ch1`) after any granted channel transfer so an active channel waits at most one transfer by the other channel, and must push read-response steering entries into `u_req_fifo` only on a granted read (`sram_req_o && sram_gnt_i && !sram_write_o`).
   - When an atomic read (`!mux_write && mux_amo`) is accepted (`mux_valid && sram_gnt_i`), `prim_sram_arbiter` must issue its follow-up write (`sram_amo_write_o == 1`, `sram_write_o == 1`, `sram_req_o == 1`) driving `sram_wdata_o` with the write data (`chc_wdata_i`) sampled on the accepted atomic read cycle rather than all-ones.

2. **Latch-Free Synthesis, Nangate45 Area, and OpenROAD STA Closure**:
   - Across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}`, the RTL must be strictly latch-free. Synthesizing `ot_sram_xbar_2ch` at `N_CH0 = 8, N_CH1 = 4, SramAw = 12, SramDw = 32` with the Yosys/Slang + Nangate45 flow in `BUILD.md` must achieve mapped cell area `<= 2,850.0 um^2`, and OpenROAD placement STA at a `3.80 ns` clock must achieve worst setup slack (`WNS`) `>= 0.20 ns` and worst hold slack (`WHS`) `>= 0.00 ns`.

Edit only `code/prim_arbiter_tree.sv` and `code/prim_sram_arbiter.sv`.
