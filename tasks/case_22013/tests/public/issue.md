# Ara VLSU Unaligned Burst Splitting, Non-Zero `vstart` Alignment, and Memory Ordering

## Context
`vlsu` (`code/vlsu.sv`, integrating `code/addrgen.sv`, `code/vldu.sv`, and `code/vstu.sv`) is the RVV 1.0 Load-Store Unit in PULP Ara (`NrLanes = 4` 64-bit lanes). It executes unit-stride (`VLE`, `VSE`), strided (`VLSE`, `VSSE`), and indexed (`VLXE`, `VSXE`) vector memory instructions across `EW8`–`EW64`, issuing AXI4 bursts (`axi_req_o` / `axi_resp_i` across parameterized `AxiDataWidth`), steering bytes between the AXI data bus and lane-interleaved VRF banks, and signaling completion (`pe_resp_o`, `load_complete_o`, `store_complete_o`, `store_pending_o`) and address exceptions (`addrgen_exception_o`, `addrgen_exception_vstart_o`).

## Observed Failures
Subsystem verification under AXI4 protocol monitoring and randomized AR/R/AW/W/B channel backpressure exposes three failure groups:

1. **Unaligned 4 KiB Page-Boundary and Max-Burst Splitting**:
   - Unit-stride transfers starting at unaligned byte addresses violate AXI4 `INCR` burst rules or miscompute split burst beat counts near 4 KiB (`0x1000`) boundaries and the 256-beat (`ARLEN` / `AWLEN <= 255`) burst limit, truncating tail bytes or deadlocking beat consumers.

2. **Non-Zero `vstart`, Unaligned Base Offset, and Masked Lane Steering**:
   - Vector loads and stores with `vstart > 0`, unaligned AXI base addresses, masked execution (`vm = 0`), short transfers wrapping across consecutive VRF words, or back-to-back pipelined instructions drop active elements, misrotate lanes, or retire before all VRF writeback grants finish. Prestart (`idx < vstart`), tail (`idx >= vl`), and masked-off (`vm = 0`) elements must remain unmodified in both VRF and memory.

3. **Multi-Burst Store Completion and Scatter/Gather RAW/WAR Ordering**:
   - Multi-burst vector stores assert `store_complete_o` / `pe_resp_o.vinsn_done` and deassert `store_pending_o` before all bursts of the instruction have been transmitted and acknowledged on `B`.
   - Back-to-back overlapping store-then-load (RAW) and load-then-store (WAR) sequences across unit-stride and indexed (`VLXE` / `VSXE`) instructions reorder across uncommitted bursts under asymmetric AXI channel delays, returning stale or overwritten data.
   - Indexed `VLXE` / `VSXE` instructions with `eew_vs2 != vtype.vsew`, back-to-back queued indexed ops under stall, or misaligned active indexed addresses (`vstart >= 0`) misalign lane offset consumption or report an incorrect faulting element index on `addrgen_exception_vstart_o`.

## Requirements
- Modify only `code/vlsu.sv`, `code/addrgen.sv`, `code/vldu.sv`, and `code/vstu.sv`, keeping all package headers, primitives, and `vlsu` top-level ports unchanged.
- Preserve clean, latch-free synthesis (`yosys -m slang`) and exact functional behavior across parameterized `AxiDataWidth` (`64` and `128`).
