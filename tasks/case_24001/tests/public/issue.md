# Fix Lockstep Bidirectional Isolation and One-Sided Reset Re-Entry in `cdc_reset_ctrlr`

`cdc_reset_ctrlr` (`code/cdc_reset_ctrlr.sv`) coordinates symmetric lockstep isolation and synchronous clearing across two independent clock/reset domains (`a_clk_i`/`a_rst_ni` and `b_clk_i`/`b_rst_ni`). Under multi-ratio asynchronous clocking, overlapping clear requests, and one-sided asynchronous reset re-entry, the controller exhibits protocol violations and hangs.

## Required Behavior

Update `code/cdc_reset_ctrlr.sv` while keeping its module/port interface and `cdc_reset_ctrlr_pkg` types intact so that all of the following hold across arbitrary clock frequency ratios and phase offsets:

1. **Parameterized Synchronizer Depth (`SYNC_STAGES >= 2`)**:
   - Propagate `SYNC_STAGES` to both internal 4-phase CDC channels on Side A and Side B so cross-domain request/acknowledge paths traverse `SYNC_STAGES` synchronizer stages rather than a hardcoded depth.

2. **Strict Bidirectional Isolate-Before-Clear & Teardown Ordering**:
   - Neither `a_clear_o` nor `b_clear_o` may ever assert unless its local `isolate_o` is high, its local `isolate_ack_i` has already been observed during the current continuous `isolate_o` assertion window, and the peer domain has also asserted `isolate_o` and observed its `isolate_ack_i` (unless the peer is currently held in active-low asynchronous reset).
   - Once `clear_o` asserts on a domain, `isolate_o` on that domain must stay continuously high until after `clear_o` has deasserted for post-clear teardown (`clear_o` must never outlive or drop simultaneously with `isolate_o`).
   - Support both level-held and single-cycle pulsed `isolate_ack_i` and `clear_ack_i` handshakes without deadlock during unilateral (`a_clear_i` or `b_clear_i`) and simultaneous bidirectional (`a_clear_i` and `b_clear_i`) clear sequences.

3. **One-Sided and Mid-Handshake Asynchronous Reset Recovery**:
   - When `CLEAR_ON_ASYNC_RESET = 1`:
     - Asserting `!a_rst_ni` (or `!b_rst_ni`) must still propagate an isolation request to the running peer domain even while the resetting domain's clock is gated/stopped during reset.
     - If one domain suffers an asynchronous reset (`!rst_ni`) in the middle of an active or tearing-down sequence (for example when a prior handshake left a stale `async_ack` high or left the peer unisolated), releasing `rst_ni` must safely drain/resynchronize the 4-phase channel and confirm fresh peer isolation (`peer_isolate_o` and `peer_isolate_ack_i`) before asserting `clear_o` on either side, without deadlocking.
   - If a domain recovers from asynchronous reset (`!rst_ni -> 1` under either `CLEAR_ON_ASYNC_RESET = 1` or `0`) while its peer is already requesting the `CLEAR` phase, the recovering domain must still assert `isolate_o` and observe `isolate_ack_i` before asserting `clear_o`.

4. **No Lost Synchronous `clear_i` During Post-Clear Teardown**:
   - If a synchronous `clear_i` pulse arrives after the `CLEAR` phase has already finished (during post-clear / finish teardown before returning to idle), it must not be dropped; a follow-up full isolate-and-clear sequence must execute once teardown completes.

5. **Synthesizability**:
   - `cdc_reset_ctrlr` must remain cleanly synthesizable SystemVerilog with zero inferred latches.
