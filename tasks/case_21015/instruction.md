# case_21015: Fix Streaming AXI4 DMA Unaligned 4KB/Max-Burst Splitting, Framing Drain/Flush, Zero-Length Ordering, Sticky Error Priority, and Descriptor Mux Tag Routing

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `alexforencich/verilog-axi` (`repo_40`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/axi_dma_wr.v`, `code/axi_dma_rd.v`, `code/axi_dma_desc_mux.v`

---

## Problem Specification

# Streaming AXI4 DMA & Descriptor Mux Protocol Failures Under Unaligned Multi-Burst Framing

## Problem Summary

In our multi-queue SmartNIC data-path subsystem, multiple client rings share an `axi_dma` engine (`ENABLE_UNALIGNED=1`, `AXIS_LAST_ENABLE=1`) through `axi_dma_desc_mux` instances on both the read (`axi_dma_rd`) and write (`axi_dma_wr`) channels. System-level stress regressions with unaligned host buffer addresses, variable-length packet streams, AXI backpressure, and error injection expose several interacting protocol and data-integrity defects across `axi_dma_wr.v`, `axi_dma_rd.v`, and `axi_dma_desc_mux.v`:

1. **Unaligned 4 KB Boundary & `AXI_MAX_BURST_LEN` Burst Splitting (`axi_dma_rd`, `axi_dma_wr`)**
   When transfers begin at byte-unaligned addresses (`ENABLE_UNALIGNED=1`) or span `>= 4096` bytes (including configurations where `AXI_MAX_BURST_LEN * (AXI_DATA_WIDTH/8) >= 4096`), child burst sizing miscalculates the byte count transferable within `AXI_MAX_BURST_LEN` beats or across a 4 KB (`0x1000`) AXI4 page boundary. This produces illegal `ARLEN`/`AWLEN` values (`>= AXI_MAX_BURST_LEN` or wrapped 8-bit lengths), 4 KB boundary crossings, and misaligned continuation bursts that corrupt adjacent memory bytes.

2. **Zero-Length Descriptors (`axi_dma_rd`, `axi_dma_wr`)**
   Submitting a descriptor with `len == 0` underflows internal cycle/length arithmetic into multi-beat AXI bursts instead of completing cleanly with zero bus/stream transfers.

3. **Write Stream Framing: Short Packets, Oversized Packets, and Backpressure (`axi_dma_wr`)**
   - When an unaligned multi-burst write descriptor receives a short AXI-Stream frame (`packet_bytes < desc_len`) or ends with buffered sub-word bytes across a burst boundary, input stream readiness reasserts prematurely and consumes the opening beat of the next back-to-back packet, corrupting both descriptor status sidebands and the subsequent packet's payload.
   - When an incoming AXI-Stream frame exceeds `desc_len` (`packet_bytes > desc_len`), excess frame beats are not drained cleanly through `s_axis_write_data_tlast`, buffered sub-word state leaks across descriptors, and `m_axis_write_desc_status_valid` fires before the frame's terminal `tlast` beat is accepted — reporting mid-frame `tid`/`tdest`/`tuser` metadata instead of the terminal beat's metadata.
   - Under AXI write-data backpressure (`m_axi_wready` stalls filling internal buffering), write beats can advance while the downstream buffer is not ready.

4. **Multi-Burst AXI Error Severity Aggregation (`axi_dma_rd`, `axi_dma_wr`)**
   When a descriptor splits into multiple AXI bursts or beats and encounters `DECERR` (`2'b11`) followed by `SLVERR` (`2'b10`) on a later beat/burst of the same descriptor, the reported descriptor error status downgrades to `SLVERR` instead of preserving the highest-severity error.

5. **Descriptor Multiplexer Tag Packing, Skid Buffering, and Parameterization (`axi_dma_desc_mux`)**
   - `axi_dma_desc_mux` fails elaboration when `PORTS == 1`.
   - Under `m_axis_desc_ready` stalls that exercise the internal skid path, upper port-routing bits in `m_axis_desc_tag` are lost.
   - When `M_TAG_WIDTH > S_TAG_WIDTH + (PORTS > 1 ? $clog2(PORTS) : 0)` or `PORTS` is not a power of two (e.g., `PORTS = 3`), completion status demultiplexing misroutes `m_axis_desc_status_valid`.

## Required Contract

Update `code/axi_dma_wr.v`, `code/axi_dma_rd.v`, and `code/axi_dma_desc_mux.v` while preserving all module port signatures, parameter names/defaults, and synthesizable synchronous reset behavior:

1. **Legal AXI4 Burst Splitting & Byte Integrity (`axi_dma_rd`, `axi_dma_wr`)**
   - Every emitted AXI4 `AR` and `AW` transaction must obey `ARLEN < AXI_MAX_BURST_LEN` and `AWLEN < AXI_MAX_BURST_LEN`, and must never cross an AXI4 4 KB address boundary: the start beat address `addr & ~((1 << AXI_BURST_SIZE) - 1)` and last beat address `(addr & ~((1 << AXI_BURST_SIZE) - 1)) + (len << AXI_BURST_SIZE)` must share the same `[AXI_ADDR_WIDTH-1:12]` 4 KB page.
   - With `ENABLE_UNALIGNED=1`, `axi_dma_rd` must emit exact `desc_len` bytes on `m_axis_read_data_*` starting from `s_axis_read_desc_addr` with contiguous valid `tkeep` on full beats, proper final-beat `tkeep` and `tlast` (when `AXIS_LAST_ENABLE=1`), and sidebands `(tid, tdest, tuser)` matching the descriptor.
   - With `ENABLE_UNALIGNED=1`, `axi_dma_wr` must write only bytes within `[s_axis_write_desc_addr, s_axis_write_desc_addr + transferred_len - 1]` via accurate first/intermediate/final `m_axi_wstrb` masks, leaving all surrounding bytes untouched across arbitrary 4 KB and `AXI_MAX_BURST_LEN` splits and arbitrary `WREADY` / `AWREADY` / `BVALID` stalls.

2. **Zero-Length Descriptor Ordering (`axi_dma_rd`, `axi_dma_wr`)**
   - A descriptor with `len == 0` must issue **no** AXI4 `AR` or `AW`/`W` transactions and must neither consume `s_axis_write_data_*` beats nor emit `m_axis_read_data_*` beats.
   - It must emit its `m_axis_*_desc_status_valid` completion pulse strictly in descriptor order (after all preceding descriptors accepted on that engine have completed), preserving `status_tag = desc_tag` with `status_error = 4'd0` (`DMA_ERROR_NONE`), and on `axi_dma_wr` reporting `status_len = 0`, `status_id = 0`, `status_dest = 0`, and `status_user = 0`.

3. **Write Frame Termination, Excess-Beat Drain, and Back-to-Back Isolation (`axi_dma_wr`, `AXIS_LAST_ENABLE=1`)**
   - **Short frames (`packet_bytes < desc_len`)**: Stop accepting stream beats for the current descriptor as soon as `s_axis_write_data_tlast` is accepted, write all `packet_bytes` to memory (including any buffered sub-word tail bytes), pad any remaining beats of an already-addressed AXI `AW` burst with `m_axi_wstrb = 0` through `m_axi_wlast = 1`, report `status_len = packet_bytes` and `(status_id, status_dest, status_user)` from the frame's `tlast` beat, and never consume or corrupt the first beat of a subsequent back-to-back stream frame.
   - **Exact frames (`packet_bytes == desc_len`)**: Write all `desc_len` bytes, report `status_len = desc_len` and `(status_id, status_dest, status_user)` from the frame's `tlast` beat, and flush any internal sub-word state cleanly before the next descriptor.
   - **Oversized frames (`packet_bytes > desc_len`)**: Write exactly the first `desc_len` bytes to memory, accept and discard all remaining beats of the current stream frame until `s_axis_write_data_tlast` handshakes (`tvalid && tready && tlast`), clear any buffered sub-word state before starting the next descriptor, and hold `m_axis_write_desc_status_valid` until **both** all AXI `B` responses for the descriptor and the discarded `s_axis_write_data_tlast` beat have been accepted. The completion status must report `status_len = desc_len` and `(status_id, status_dest, status_user)` captured from that terminal `s_axis_write_data_tlast` beat.

4. **Sticky AXI Error Priority (`axi_dma_rd`, `axi_dma_wr`)**
   - Across all beats/bursts of a descriptor, preserve the highest-severity AXI response seen for that descriptor:
     - Read engine (`m_axi_rresp`): `DECERR` (`2'b11` -> `4'd5`) > `SLVERR` (`2'b10` -> `4'd4`) > `OKAY`/`EXOKAY` (`4'd0`).
     - Write engine (`m_axi_bresp`): `DECERR` (`2'b11` -> `4'd7`) > `SLVERR` (`2'b10` -> `4'd6`) > `OKAY`/`EXOKAY` (`4'd0`).
   - Reset per-descriptor error accumulation cleanly once a descriptor's final status is emitted so errors never bleed into subsequent descriptors.

5. **Descriptor Mux & Status Demux (`axi_dma_desc_mux`)**
   - Support all `PORTS >= 1` (including `PORTS == 1` and non-power-of-two port counts) and any `M_TAG_WIDTH >= S_TAG_WIDTH + (PORTS > 1 ? $clog2(PORTS) : 0)`.
   - Pack the client's `S_TAG_WIDTH`-bit tag in `m_axis_desc_tag[S_TAG_WIDTH-1:0]`, place the granted port index in `m_axis_desc_tag[S_TAG_WIDTH +: $clog2(PORTS)]` when `PORTS > 1` (zero-extending any bits above `S_TAG_WIDTH + (PORTS > 1 ? $clog2(PORTS) : 0)`), and preserve all `M_TAG_WIDTH` tag bits intact across `m_axis_desc_ready` backpressure.
   - On `s_axis_desc_status_valid`, forward `s_axis_desc_status_tag[S_TAG_WIDTH-1:0]` and status sidebands while asserting `m_axis_desc_status_valid` exclusively on the originating port decoded from `s_axis_desc_status_tag[S_TAG_WIDTH +: $clog2(PORTS)]` (or port `0` when `PORTS == 1`; drive `m_axis_desc_status_valid = 0` if the decoded port index is `>= PORTS`).

---

## Build, Simulation, and EDA Verification Instructions

# Build and Verification Guide

## Editable Files

Only the following RTL files may be modified:

- `code/axi_dma_wr.v`
- `code/axi_dma_rd.v`
- `code/axi_dma_desc_mux.v`

All other files under `code/` (`axi_dma.v`, `arbiter.v`, `priority_encoder.v`, `COPYING`) are read-only reference dependencies and must remain unchanged. Do not alter top-level port declarations or parameter names/defaults on `axi_dma`, `axi_dma_wr`, `axi_dma_rd`, or `axi_dma_desc_mux`.

## Available EDA Tools

- **Icarus Verilog**:
  - `iverilog`
  - `vvp`
- **Verilator**:
  - `verilator` (pass `-j 1`; do not set `VERILATOR_ROOT`)
- **Yosys**:
  - `yosys`

## Quick Sanity Commands

### 1. Elaboration & Lint Check

```bash
iverilog -g2012 -t null \
  code/priority_encoder.v code/arbiter.v code/axi_dma_desc_mux.v \
  code/axi_dma_rd.v code/axi_dma_wr.v code/axi_dma.v

verilator --lint-only \
  -Wno-fatal --top-module axi_dma \
  code/priority_encoder.v code/arbiter.v code/axi_dma_rd.v code/axi_dma_wr.v code/axi_dma.v

verilator --lint-only \
  -Wno-fatal --top-module axi_dma_desc_mux \
  code/priority_encoder.v code/arbiter.v code/axi_dma_desc_mux.v
```

### 2. Synthesis & Latch Check

```bash
yosys -q -p "
  read_verilog code/priority_encoder.v code/arbiter.v code/axi_dma_desc_mux.v code/axi_dma_rd.v code/axi_dma_wr.v code/axi_dma.v;
  hierarchy -check -top axi_dma;
  proc; opt_expr; opt_clean; check;
  select -assert-none t:\$dlatch* t:\$_DLATCH*
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axi_dma_wr.v`
- `code/axi_dma_rd.v`
- `code/axi_dma_desc_mux.v`

All other files in the workspace are read-only reference context and must remain unmodified.
