# OpenTitan OTBN Two-Round Secure Wipe, Loop-End Commit Hazard, Full-Stack Push/Pop Replacement, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan OTBN Start/Stop, Loop Stack, and Call Stack Subsystem (`code/ot_otbn_ctrl_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **Start/Stop Two-Round Secure Wipe Sequencing and RMA Acknowledgement**:
   - In `otbn_start_stop_control`, when `OtbnStartStopSecureWipeAllZero` is reached with `mubi4_test_false_strict(wipe_after_urnd_refresh_q)` (first round of random wiping), the FSM transitions directly to `OtbnStartStopSecureWipeComplete` instead of setting `wipe_after_urnd_refresh_d = MuBi4True`, keeping `secure_wipe_running_d = 1'b1`, and transitioning to `OtbnStartStopStateUrndRefresh` for the second wipe round. In addition, in `OtbnStartStopSecureWipeComplete`, `rma_ack_d` fails to latch `rma_req_i`.

2. **Loop Controller At-End Loop Start Error and Commit Priority**:
   - In `otbn_loop_controller`, `loop_at_end_err` is tied low instead of detecting `at_current_loop_end_insn & loop_start_req_i`, and `loop_stack_commit` is driven by `loop_start_commit_i | loop_stack_pop` instead of giving `loop_stack_push_req` priority (`loop_stack_push_req ? loop_start_commit_i : loop_stack_pop`), causing an aborted loop-start request at the end of a finishing loop (`loop_start_commit_i == 0`) to still commit a pop/write on the loop stack.

3. **Full-Stack Combined Push and Pop Replacement**:
   - In `otbn_stack`, `stack_write` is gated by `~full_o` instead of `(~full_o | pop_i)` and `stack_wr_idx` does not select `stack_rd_idx` when `pop_i` is high, dropping the pushed element instead of replacing the top element when a combined push and pop occurs on a full or non-empty stack.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_otbn_ctrl_top`, `2.20 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_otbn_ctrl_top` exceeds the mapped cell area budget and violates setup timing across the loop/call stack read-compare-pop datapath.

## Deliverable

Update the editable RTL files (`code/otbn_start_stop_control.sv`, `code/otbn_loop_controller.sv`, and `code/otbn_stack.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_otbn_ctrl_top`: **`<= 8550.0 um^2`**
- Worst setup slack and worst hold slack at `2.20 ns` clock period: **`>= 0.0 ns`**
