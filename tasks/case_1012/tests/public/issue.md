# OpenTitan DOE Mailbox Pointer Advancement, Abort Zeroization, Stale Response Filtering, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan DOE Mailbox subsystem (`code/ot_mbx_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **Inbound Mailbox Initial Write Pointer Advancement**:
   - In `mbx_imbx`, when the initial word write of an inbound message (`mbx_empty && sysif_data_write_valid_i`) is granted on the same clock cycle (`hostif_sram_write_gnt_i = 1'b1`), `sram_write_ptr_q` reloads `hostif_base_i` instead of advancing to `hostif_base_i + LCFG_SRM_ADDRINC`, causing the second word write of the message to overwrite `hostif_base_i`.

2. **Outbound Mailbox Object-Size Zeroization on Host Abort Clear**:
   - In `mbx_ombx`, when the host acknowledges an abort (`hostif_control_abort_clear_i = 1'b1`), `hostif_ombx_object_size_update_o` asserts, but `hostif_ombx_object_size_o` drives `hostif_ombx_object_size_i - 1` instead of zero (`'0`), underflowing or corrupting the outbound object size register on abort recovery.

3. **Stale SRAM Read Response Suppression After Abort**:
   - In `mbx_sramrwarb`, when an in-flight TL-UL read response (`AccessAckData`) returns after an abort has cleared the outstanding request counter (`any_outstanding_reqs == 1'b0`), `ombx_sram_read_resp_vld_o` still pulses high, latching stale read data into `mbx_ombx` and falsely transitioning the outbound mailbox into the ready state.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_mbx_top`, `1.45 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_mbx_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/mbx_imbx.sv`, `code/mbx_ombx.sv`, and `code/mbx_sramrwarb.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_mbx_top`: **`<= 1950.0 um^2`**
- Worst setup slack and worst hold slack at `1.45 ns` clock period: **`>= 0.0 ns`**
