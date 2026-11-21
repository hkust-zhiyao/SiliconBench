# OpenTitan HMAC Core and SHA-256 Padding Backpressure, Abort Recovery, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan HMAC and SHA-256 padding subsystem (`code/ot_hmac_pad_top.sv`), three issues were identified across functional simulation and Nangate45 synthesis/STA:

1. **HMAC Intermediate Digest Push Backpressure and Abort Recovery**:
   - When the inner SHA-256 pass completes in HMAC mode (`hmac_en_i = 1'b1`) and the controller pushes the 8-word intermediate digest back into the message FIFO (`fifo_wsel_o = 1'b1`, `fifo_wvalid_o = 1'b1`), `fifo_wdata_sel_o` advances even on cycles where the downstream FIFO stalls (`fifo_wready_i = 1'b0`), skipping digest words under backpressure.
   - When an in-flight operation is aborted (`abort_i = 1'b1`) after `reg_hash_process_i` has been pulsed, the latched process request is not cleared, causing a subsequent operation to prematurely transition to response waiting and padding before software issues a new process command.

2. **SHA-256 Padding Bit-Count and Last-Block Boundary**:
   - During message ingestion prior to `hash_process_i`, the padding bit counter advances whenever the downstream compression interface is ready (`shaf_rready_i = 1'b1`) even when the upstream message stream is not valid (`fifo_rvalid_i = 1'b0`), corrupting the accumulated message bit count under source stalls.
   - When the 1-bit (`0x80`) padding byte lands at the exact 512-bit block boundary preceding the 64-bit length field (`416` bits into the 512-bit block, i.e., `52` message bytes modulo `64`), the padding FSM fails to transition directly to emitting the 64-bit length words (`LenHi` / `LenLo`), producing an extra zero-padded block.

3. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_hmac_pad_top`, `2.75 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), the subsystem exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/hmac_core.sv` and `code/prim_sha2_pad.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_hmac_pad_top`: **`<= 4150.0 um^2`**
- Worst setup slack and worst hold slack at `2.75 ns` clock period: **`>= 0.0 ns`**
