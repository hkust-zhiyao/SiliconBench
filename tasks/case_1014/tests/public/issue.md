# OpenTitan Entropy Complex GEN Abort Uninstantiation, Boot-Mode Uninstantiate Sequence, Endpoint Ack Immediate Pop, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan Entropy Complex Command & Endpoint Subsystem (`code/ot_entropy_cmd_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **CSRNG Command Stage GEN Abort Uninstantiation and Genbits FIFO Flush**:
   - In `csrng_cmd_stage`, when an in-flight `GEN` abort completes (`state_q == CmdAck && cmd_ack_i && gen_abort_inflight_q`), `instantiated_d` is not cleared to `1'b0` and `sfifo_genbits_clr` does not include `cmd_gen_abort_ack`, leaving `instantiated_q` set (rejecting a subsequent `INS` command as `CMD_STS_INVALID_CMD_SEQ`) and leaving stale `genbits` in the output buffer.

2. **EDN Main State Machine Boot-Mode Uninstantiate Sequence and Disable Done Pulse**:
   - In `edn_main_sm`, when `boot_req_mode_i` deasserts in `BootDone`, the FSM transitions directly to `Idle` instead of `BootLoadUni` (skipping the boot-mode `UNI` command and its `BootUniAckWait` completion), and when `edn_enable_i` deasserts in an active legal state, `main_sm_done_pulse_o` is not pulsed high.

3. **EDN Endpoint Ack State Machine Immediate FIFO Pop on Ready Data**:
   - In `edn_ack_sm`, when `req_i` asserts in `Idle` while `fifo_not_empty_i` is already high, `fifo_pop_o` is not asserted, failing to pop the consumed word from the genbits FIFO.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_entropy_cmd_top`, `1.15 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_entropy_cmd_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/csrng_cmd_stage.sv`, `code/edn_main_sm.sv`, and `code/edn_ack_sm.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_entropy_cmd_top`: **`<= 2320.0 um^2`**
- Worst setup slack and worst hold slack at `1.15 ns` clock period: **`>= 0.0 ns`**
