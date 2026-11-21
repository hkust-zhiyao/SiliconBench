# OpenTitan ROM Controller KMAC Error Handling, Comparator/Mux Alert Hardening, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan ROM Controller subsystem (`code/ot_rom_ctrl_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **KMAC Error Handling During `ReadingHigh` State**:
   - In `rom_ctrl_fsm`, when `kmac_done_i` asserts while `state_q == ReadingHigh` (whether `counter_done` is `1'b0` or `1'b1`), `kmac_err_i` is not checked, allowing the FSM to advance to `KmacAhead` or `Checking` instead of transitioning to `Invalid` and raising `alert_o`.

2. **Comparator Re-Start Alert Detection**:
   - In `rom_ctrl_compare`, `start_alert` is tied low instead of asserting when `start_i` is high while the comparator FSM is not in `Waiting`, suppressing `alert_o` on spurious re-start pulses during `Checking` or `Done`.

3. **ROM Multiplexer Bus-Selection Revert Alert Detection**:
   - In `rom_ctrl_mux`, `sel_reverted` is tied low instead of detecting when `sel_bus_q` is true (loose MuBi4 check) while `sel_bus_i` reverts to false (loose MuBi4 check), failing to latch `alert_o` when the bus selection signal reverts after switching to the system bus.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_rom_ctrl_top`, `1.05 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_rom_ctrl_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/rom_ctrl_fsm.sv`, `code/rom_ctrl_compare.sv`, and `code/rom_ctrl_mux.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_rom_ctrl_top`: **`<= 1020.0 um^2`**
- Worst setup slack and worst hold slack at `1.05 ns` clock period: **`>= 0.0 ns`**
