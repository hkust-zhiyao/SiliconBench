# OpenTitan SPI Host Core TX Flush, RX Buffer Refill, Standard-Mode Output Enable, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan SPI Host core subsystem (`code/spi_host_core.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **TX Byte-Select Segment Flush**:
   - When a write segment finishes before consuming all enabled bytes of the current 32-bit TX word (`last_write_o` / `flush_i`), `spi_host_byte_select` does not discard the remaining bytes of that word, leaking leftover bytes into subsequent write segments.

2. **Simultaneous RX Shift-Register Refill and Downstream Pop**:
   - In `spi_host_shift_register`, when the downstream byte merger accepts a buffered RX byte (`rx_valid_o && rx_ready_i`) in the same cycle that the shift register completes and loads the next received byte (`rd_en_i && rd_ready_o`), the RX buffer valid flag clears instead of remaining asserted, dropping the newly received byte.

3. **Standard-Mode Output Enable Stretching and Software Reset Clearing**:
   - In `spi_host_fsm`, when a `Standard`-mode write segment (`speed_o == Standard`) transitions into a non-write segment or deasserts `cmd_wr_en_q` during the final bit period (`last_bit`), `sd_en_o[0]` drops half a clock cycle early instead of remaining asserted until `byte_ending`; moreover, when the FSM is idle (`is_idle`), `cmd_wr_en_last_bit` is not cleared, allowing an aborted write command to leak an active `sd_en_o[0]` into a subsequent read segment.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`spi_host_core`, `2.02 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `spi_host_core` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/spi_host_fsm.sv`, `code/spi_host_shift_register.sv`, and `code/spi_host_byte_select.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `spi_host_core`: **`<= 2035.0 um^2`**
- Worst setup slack and worst hold slack at `2.02 ns` clock period: **`>= 0.0 ns`**
