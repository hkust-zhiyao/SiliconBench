# case_24016: Dual-Channel Transceiver Data Offload Three-Clock CDC/RDC Synchronization, Asymmetric Bypass Framing, Cyclic Replay Control, and Nangate45 Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `analogdevicesinc/hdl` (`repo_38`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/data_offload.v`, `code/data_offload_fsm.v`, `code/data_offload_regmap.v`, `code/util_axis_fifo_asym.v`

---

## Problem Specification

# Dual-Channel Transceiver Data Offload CDC/RDC, Asymmetric Bypass & Three-Clock Timing Closure

`code/data_offload_subsys.v` (read-only top wrapper) integrates a dual-channel transceiver offload subsystem across three asynchronous clock domains (`up_clk`, `dev_clk`, `sys_clk`):
- `u_rx_offload` (`TX_OR_RXN_PATH=0`, `32-bit @ dev_clk -> 128-bit @ sys_clk`, `HAS_BYPASS=1`, `ASYNC_CLK=1`, `MEM_SIZE_LOG2=10`, `AUTO_BRINGUP=0`)
- `u_tx_offload` (`TX_OR_RXN_PATH=1`, `128-bit @ sys_clk -> 32-bit @ dev_clk`, `DST_CYCLIC_EN=1`, `HAS_BYPASS=1`, `ASYNC_CLK=1`, `MEM_SIZE_LOG2=10`, `AUTO_BRINGUP=0`)

Both channels expose ADI word-indexed registers at AXI4-Lite byte offsets (`0x001C` `TRANSFER_LENGTH`, `0x0080` `MEM_PHY_STATE`, `0x0084` `RESET_OFFLOAD[0]` active-low `RESETN`, `0x0088` `CONTROL` `{[1]: ONESHOT_EN, [0]: OFFLOAD_BYPASS}`, `0x0100` `SYNC_TRIGGER[0]`, `0x0104` `SYNC_CONFIG[1:0]` `{0: AUTOMATIC, 1: HARDWARE, 2: SOFTWARE}`, `0x0200` `FSM_DEBUG`). Modify only `code/data_offload.v`, `code/data_offload_fsm.v`, `code/data_offload_regmap.v`, and `code/util_axis_fifo_asym.v` while preserving all module/parameter/port interfaces and read-only collateral.

## Architectural & Signoff Contract

1. **Asymmetric Bypass Framing, Backpressure & TX Idle Zeroing (`OFFLOAD_BYPASS = 1`)**:
   - Both RX (`32b -> 128b`) and TX (`128b -> 32b`) bypass paths must preserve AXI4-Stream `data`, `keep`, and `last` byte ordering and packet boundaries across arbitrary packet lengths (`1` to `64` bytes, including non-multiple-of-ratio short packets and partial tail `keep` masks), back-to-back packets, and arbitrary source/sink backpressure across asynchronous clocks, without packet loss, duplication, corruption, or stall deadlocks.
   - On the TX path (`TX_OR_RXN_PATH = 1`), `tx_m_axis_data` must be driven to `'0` whenever `tx_m_axis_valid == 0`.

2. **Three-Clock Synchronization & TX Cyclic Replay (`OFFLOAD_BYPASS = 0`)**:
   - Across arbitrary asynchronous clock ratios (`up_clk`, `dev_clk`, `sys_clk`), every single AXI4-Lite write of `1` to `SYNC_TRIGGER` (`0x0100`) while the active sync barrier is armed (RX pre-write sync or TX pre-read sync with `tx_s_storage_axis_valid == 1`) must release **exactly one** transfer pass—never missing single-write triggers and never releasing multiple passes from a single write.
   - For RX capture (`rx_init_req = 1` held across capture and readback) and TX replay (`tx_init_req = 1` asserted to load a buffer into storage and deasserted to `0` after write completion): in TX cyclic mode (`ONESHOT_EN = 0`), playback repeats while `tx_init_req == 0`—continuously in `AUTOMATIC` mode, and gated at the sync barrier before each pass in `HARDWARE` (`tx_sync_ext`) or `SOFTWARE` (`0x0100`) mode without issuing extra storage read requests (`tx_rd_request_valid` / `tx_rd_request_ready`) while waiting. When `tx_init_req` reasserts (`1`) to load a replacement buffer, cyclic replay terminates after the active read pass completes (`tx_rd_response_eot`), and **only then** may the TX write FSM unlock (`FSM_DEBUG[4:0]` leaving `5'b10000`) to accept the replacement write.

3. **Reset Domain Crossing & Clean Recovery**:
   - Asserting either software reset (`RESET_OFFLOAD[0] = 0` at `0x0084`) or stream hardware reset (`dev_aresetn = 0` / `sys_aresetn = 0`) at any point during capture, storage write completion, or cyclic playback must cleanly return all offload FSMs, streams, and storage request handshakes (`*_wr_request_enable`, `*_wr_request_valid`, `*_rd_request_valid`, `*_m_axis_valid`) to idle so that releasing reset never triggers residual or phantom transfers from pre-reset activity.

4. **Nangate45 Three-Clock Synthesis & OpenSTA Signoff**:
   - Synthesized via Yosys+ABC to `lib/NangateOpenCellLibrary_typical.lib` (zero latches) and timed in OpenROAD OpenSTA (`data_offload_subsys`, see `BUILD.md`), setup and hold checks must achieve **`WNS >= 0.00 ns`** and **`TNS >= 0.00 ns`** with asynchronous clock groups `{up_clk}`, `{dev_clk}`, `{sys_clk}`:
     - `up_clk` (`2.00 ns`): `0.40 ns` max / `0.00 ns` min input & output delay on all `rx_axi_*` and `tx_axi_*` ports;
     - `dev_clk` (`3.00 ns`): `1.95 ns` max / `0.00 ns` min input delay and `1.20 ns` max / `0.00 ns` min output delay on `rx_s_axis_*`, `rx_m_storage_axis_*`, `rx_wr_*`, `tx_m_axis_*`, `tx_s_storage_axis_*`, and `tx_rd_*` ports;
     - `sys_clk` (`3.00 ns`): `1.95 ns` max / `0.00 ns` min input delay and `1.20 ns` max / `0.00 ns` min output delay on `rx_m_axis_*`, `rx_s_storage_axis_*`, `rx_rd_*`, `tx_s_axis_*`, `tx_m_storage_axis_*`, and `tx_wr_*` ports;
     - `set_false_path -from` on `up_rstn`, `dev_aresetn`, `sys_aresetn`, `*_init_req`, `*_sync_ext`, and `*_ddr_calib_done`.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Reference (`data_offload_subsys`)

## Editable Files
- `code/data_offload.v`
- `code/data_offload_fsm.v`
- `code/data_offload_regmap.v`
- `code/util_axis_fifo_asym.v`

## Local Simulation & Nangate45 STA Commands
- **Verilator Three-Clock Simulation**:
  ```bash
  verilator --binary --timing +1364-2005ext+v -Wno-fatal -Icode \
    code/ad_mem.v code/up_axi.v code/axi_register_slice.v \
    code/sync_bits.v code/sync_data.v code/sync_event.v code/sync_gray.v \
    code/util_axis_fifo_address_generator.v code/util_axis_fifo.v code/util_axis_fifo_asym.v \
    code/data_offload_fsm.v code/data_offload_regmap.v code/data_offload.v \
    code/data_offload_subsys.v <your_tb.sv>
  ```
- **Yosys Nangate45 Synthesis & OpenROAD OpenSTA Signoff**:
  Synthesize `data_offload_subsys` against `lib/NangateOpenCellLibrary_typical.lib` (`hierarchy -check -top data_offload_subsys; proc; opt; memory; opt; flatten; opt; techmap; opt; dfflibmap -liberty ...; abc -liberty ... -script "+strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf -D 800; &put; buffer -N 8; upsize -D 800; dnsize -D 800"; hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z`) and check timing in OpenROAD (`openroad -exit`) using `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib` at the exact clocks and I/O delays in `issue.md`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/data_offload.v`
- `code/data_offload_fsm.v`
- `code/data_offload_regmap.v`
- `code/util_axis_fifo_asym.v`

All other files in the workspace are read-only reference context and must remain unmodified.
