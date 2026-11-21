# Scatter-Gather Descriptor Error Recovery, Stream Abort/Sync-Start Deadlocks, and Multi-Clock Timing Closure in `axi_dmac`

The scatter-gather DMA data-plane cluster (`dmac_sg_cluster` in `code/dmac_sg_cluster.v`, integrating `code/dmac_sg.v`, `code/request_arb.v`, `code/data_mover.v`, and `code/axi_dmac_burst_memory.v`) transfers AXI4-Stream payloads (`s_axis_aclk`) into AXI4 memory-mapped buffers (`m_dest_axi_aclk`) under linked-list hardware descriptors fetched over `m_sg_axi_aclk` and coordinated in `req_clk`. Multi-clock integration stress and Nangate45 static timing signoff exposed descriptor corruption/starvation, AXI4-Stream handshaking deadlocks, stale post-reset burst pointers, and setup timing violations on the source and destination AXI boundaries.

Modify only `code/dmac_sg.v`, `code/data_mover.v`, `code/request_arb.v`, and `code/axi_dmac_burst_memory.v` without altering external module/parameter/port interfaces or read-only collateral.

## Subsystem & Physical Signoff Contract

1. **Scatter-Gather Descriptor Fetch Integrity & Deep Chain Pipelining (`dmac_sg`)**:
   - Strictly obey AXI4 read channel handshaking on `m_sg_axi_*`: never sample `m_axi_rdata` or advance beat state when `m_axi_rready == 0` (e.g., if `m_axi_rvalid` asserts while downstream descriptor acceptance is stalled).
   - If any beat of the 6-beat (`arlen == 5`) descriptor burst returns a non-`OKAY` response (`m_axi_rresp != 2'b00`) or `sg_enable` deasserts during fetch, drain the remaining beats of the AXI read burst through `m_axi_rlast` and return cleanly to idle without pushing corrupted descriptors or desynchronizing completion IDs/IRQ flags.
   - Support chains of at least `8` descriptors concurrently in flight before `resp_in_valid` completions drain, keeping descriptor dispatch and completion ID/IRQ FIFO entries strictly 1-to-1 paired even if `sg_enable` drops mid-dispatch.

2. **AXI4-Stream Sync-Start, Early-`TLAST` Rewind, and Warm-Reset Cleanliness (`data_mover`, `request_arb`, `axi_dmac_burst_memory`)**:
   - When `req_sync_transfer_start == 1`, compliant AXI4-Stream masters hold `s_axis_data` / `s_axis_user` constant until `s_axis_ready == 1`; pre-sync beats (`s_axis_user[0] == 0`) must be accepted and discarded rather than withholding `s_axis_ready`.
   - Under arbitrary `s_axis_aclk` / `m_dest_axi_aclk` / `req_clk` frequency ratios and prolonged `m_axi_awready` / `m_axi_wready` stalls, back-to-back short or early-`s_axis_last` packets must never drop or overwrite measured burst-length or rewind handshakes, must cleanly deassert `s_axis_xfer_req` once drained, and must drive exact byte write strobes (`m_axi_wstrb`) across both symmetric (`64->64`) and asymmetric (`32->64`) source/destination widths.
   - A synchronous warm reset across `req_resetn`, `m_sg_axi_aresetn`, `s_axis_aresetn`, and `m_dest_axi_aresetn` (including mid-burst) must clear internal burst-memory Gray IDs and cross-domain ID synchronizers so zero phantom AXI bursts fire after reset release.

3. **Nangate45 Multi-Clock Timing Closure (`dmac_sg_cluster` default parameters, zero latches)**:
   - Synthesized via Yosys+ABC (`flatten; dfflibmap; abc ... buffer -N 8; upsize -D 800; dnsize -D 800; hilomap`, see `BUILD.md`) and timed in OpenROAD OpenSTA (`lib/NangateOpenCellLibrary_typical.lib`), `dmac_sg_cluster` must achieve `WNS >= 0.0 ns` and `TNS == 0.0 ns` (setup and hold) across four asynchronous clocks:
     - `req_clk`: `1.85 ns`; `sg_clk` (`m_sg_axi_aclk`): `1.85 ns` (`0.60 ns` max / `0.05 ns` min in, `0.60 ns` max / `0.00 ns` min out);
     - `src_clk` (`s_axis_aclk`): `1.40 ns` (`0.85 ns` max / `0.05 ns` min in, `0.85 ns` max / `0.00 ns` min out);
     - `dst_clk` (`m_dest_axi_aclk`): `2.15 ns` (`1.45 ns` max / `0.05 ns` min in, `1.45 ns` max / `0.00 ns` min out).
