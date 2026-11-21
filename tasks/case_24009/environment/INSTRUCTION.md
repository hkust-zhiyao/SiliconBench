# case_24009: Odd/Non-Power-of-Two Channel Generalization, Dynamic Mask Reconfiguration, and 4-State Gate-Level Parity in ADI util_pack

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `analogdevicesinc/hdl` (`repo_38`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Task-Specific Multi-Corner Liberty & SDC Timing Views`
> - **Editable Files (`allowed_edits`)**: `code/util_cpack2_impl.v`, `code/util_upack2_impl.v`, `code/pack_shell.v`, `code/pack_ctrl.v`, `code/pack_network.v`

---

## Problem Specification

# Odd/Non-Power-of-Two Channel Generalization, Dynamic Mask Reconfiguration, and 4-State Gate-Level Parity in `util_pack`

The ADI transceiver channel packer and unpacker (`code/util_cpack2_impl.v`, `code/util_upack2_impl.v`, `code/pack_shell.v`, `code/pack_ctrl.v`, `code/pack_network.v`) compact and expand arbitrary runtime subsets of active channels (`enable`) using an `O(N log N)` prefix-sum butterfly routing network (`pack_interconnect`). Extending transceiver deployments to odd and non-power-of-two channel counts (`3, 5, 6`), multi-sample-per-channel framing, non-byte sample widths (`12, 24` bits), and standard-cell ASIC synthesis exposed elaboration width mismatches, modulo word-wrapping corruption, `packed_sync` / `s_axis_ready` cadence drift, and 4-state gate-level `X`-propagation.

Update the editable `util_pack` RTL files while preserving all module/parameter/port interfaces, read-only collateral (`ad_perfect_shuffle.v`, `pack_interconnect.v`, `util_pipeline_stage.v`), and the `pack_network` / `pack_interconnect` butterfly architecture.

## Architectural & Synthesis Contract

1. **Arbitrary Parameter Matrix & Bit-Exact Sample Ordering**:
   - Elaborate cleanly without port-width truncation or out-of-bounds slicing across `NUM_OF_CHANNELS >= 1` (including `1, 2, 3, 4, 5, 6, 8`), `SAMPLES_PER_CHANNEL` (`1, 2, 4`), `SAMPLE_DATA_WIDTH` (`12, 16, 24`), `PARALLEL_OR_SERIAL_N` (`0, 1`), and `PIPELINE_STAGES` (`0, 1, 2`).
   - In `util_cpack2_impl` (`INTERFACE_TYPE = 1`), on every active `fifo_wr_en[0]` cycle after reset/reconfiguration startup completes, deinterleaved samples from all enabled channels (`enable[c] == 1`, `c` ascending, sample index within channel ascending) must pack contiguously without gaps or duplicates into `NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL`-sample words on `packed_fifo_wr_data` (`packed_fifo_wr_en == 1`), wrapping seamlessly across word boundaries over the full `LCM` period. `packed_sync` must assert (`1'b1`) on an emitted word if and only if sample slot `0` of `packed_fifo_wr_data` carries sample `0` of the lowest-indexed enabled channel, and `1'b0` otherwise.
   - In `util_upack2_impl`, packed `N`-sample words from `s_axis_data` must unpack bit-accurately into the corresponding enabled channel slices of `fifo_rd_data` (`fifo_rd_valid == 1` after `TOTAL_PIPELINE_LATENCY` cycles when `s_axis_valid` was high; `fifo_rd_underflow == 1` and `fifo_rd_data == '0` when `s_axis_valid == 0` or during reset drain).

2. **Exact AXI-Stream Consumption Cadence & Dynamic `enable` Reconfiguration**:
   - `util_upack2_impl` must assert `s_axis_ready` only when `s_axis_valid && fifo_rd_en[0]` and outside reset/reconfiguration startup, consuming each `s_axis_data` word on the exact beat where its `N` samples are exhausted or spanned into the next unpack cycle (including consecutive spanning beats when more than half of the channels are active, e.g., `4` of `5` channels).
   - Synchronous `reset` and runtime changes to non-zero `enable` masks must cleanly reinitialize rotation offsets, residual overflow/input buffers, and sync state without dropping post-startup beats or leaking stale pre-reconfiguration samples.

3. **4-State Standard-Cell Gate-Level Parity**:
   - Under standard-cell synthesis (where flip-flops power up to `1'bx` with no FPGA bitstream `initial` state), synchronous `reset` must deterministically initialize all control/valid state so 4-state gate-level simulation matches RTL bit-for-bit with zero `X` propagation on handshake/sync signals or valid output data and zero inferred latches.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment

## Editable Files
- `code/util_cpack2_impl.v`
- `code/util_upack2_impl.v`
- `code/pack_shell.v`
- `code/pack_ctrl.v`
- `code/pack_network.v`

All other files under `code/` (`ad_perfect_shuffle.v`, `pack_interconnect.v`, `util_pipeline_stage.v`) and `lib/` are read-only collateral.

## Available Tools
- **Verilator (`verilator --binary --timing -Wno-fatal`)** for multi-parameter matrix verification.
- **Icarus Verilog (`iverilog -g2012` / `vvp`)** for 4-state RTL & gate-level `X`-propagation parity verification.
- **Yosys + Slang (`yosys -m slang`)** for standard-cell synthesis, latch checking, and gate-level netlist generation against `lib/NangateOpenCellLibrary_typical.lib`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/util_cpack2_impl.v`
- `code/util_upack2_impl.v`
- `code/pack_shell.v`
- `code/pack_ctrl.v`
- `code/pack_network.v`

All other files in the workspace are read-only reference context and must remain unmodified.
