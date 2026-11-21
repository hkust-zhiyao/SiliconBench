# TSN/TDMA Transmit Scheduler Boundary Precision, Pipeline Hazard Control & Nangate45 Timing Closure

`tdma_scheduler` (`code/tdma_scheduler.v`), `tx_scheduler_ctrl_tdma` (`code/tx_scheduler_ctrl_tdma.v`), and `tx_scheduler_rr` (`code/tx_scheduler_rr.v`) form the time-triggered TSN/TDMA transmit scheduling chain: `tdma_scheduler` tracks 96-bit PTP time (`input_ts_96[95:48]` seconds, `input_ts_96[45:16]` nanoseconds) to emit timeslot boundaries, `tx_scheduler_ctrl_tdma` scans per-queue timeslot bitmasks to issue `m_axis_sched_ctrl_*` gate updates, and `tx_scheduler_rr` arbitrates active/enabled queues onto `m_axis_tx_req_*`.

Update `code/tdma_scheduler.v`, `code/tx_scheduler_ctrl_tdma.v`, and `code/tx_scheduler_rr.v` while preserving all top-level module names, parameters, and port interfaces:

1. **PTP Boundary Precision & `tdma_scheduler` Nangate45 `2.00` ns Timing Closure**:
   - Trigger schedule period start, timeslot start, and active-period end in `tdma_scheduler` using inclusive timestamp comparisons (`current_time >= target_time` across `(seconds, nanoseconds)`, with decimal `1_000_000_000` ns rollover) rather than firing late only after strictly exceeding target timestamps, while bounding `timeslot_start` / `timeslot_end` assertion latency to at most `3` `clk` cycles from `input_ts_96` reaching the boundary in `STATE_WAIT`.
   - Retime/refactor the wide 48-bit second + 31-bit nanosecond comparator/adder paths in `tdma_scheduler` (`INDEX_WIDTH = 8`) so Nangate45 OpenSTA closes at **`clk = 2.00` ns** (`0.10` ns input/output delay on all non-clock, non-reset ports; `set_false_path -from [get_ports rst]`) with **`WNS >= 0.00` ns**, **`TNS >= 0.00` ns**, **`worst hold slack >= 0.00` ns**, and mapped cell area `<= 10,000` um².

2. **TDMA Gate Controller Event Retention & Deep-Pipeline AXI4-Lite Read Integrity (`tx_scheduler_ctrl_tdma`)**:
   - Do not drop `tdma_timeslot_start` or `tdma_timeslot_end` pulses that arrive while a previous start/stop queue burst is still draining under `m_axis_sched_ctrl_ready == 1'b0` backpressure, on the final drain beat of `STATE_START_0`/`STATE_START_N`/`STATE_STOP`, or during an AXI4-Lite `inconsistent` table rescan.
   - Propagate AXI4-Lite `queue_ram` read data/shift/valid cleanly across all `PIPELINE >= 2` stages (including `PIPELINE > 2`) without accepting new reads that overwrite valid in-flight read stages when `s_axil_rready == 1'b0`.

3. **Round-Robin TX Completion Gating & ASIC Reset Hygiene (`tx_scheduler_rr` + Full Chain)**:
   - On `s_axis_tx_req_status_valid` completion in `tx_scheduler_rr` (`SCHED_CTRL_ENABLE` in `{0, 1}`, `PIPELINE >= 2`), reschedule a queue with remaining work (`s_axis_tx_req_status_len != 0` or pending doorbell) if and only if the queue is enabled (`queue_ram` bit `0 == 1`), not already scheduled, and permitted by scheduler control (`!SCHED_CTRL_ENABLE || global_enable || sched_enable`, using the queue's stored `global_enable` bit `1`).
   - Synchronously reset all control, pointer, and pipeline valid registers across all three modules on `rst` so Yosys synthesis infers zero latches and ASIC initializer-stripped gate-level simulation exhibits zero `X` propagation after `rst` and full functional parity.
