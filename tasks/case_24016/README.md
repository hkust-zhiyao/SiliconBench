# `case_24016`: Dual-Channel Transceiver Data Offload Three-Clock CDC/RDC Synchronization, Asymmetric Bypass Framing, Cyclic Replay Control, and Nangate45 Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_24016` |
| **Source Silicon Repository** | `analogdevicesinc/hdl` (`repo_38`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/data_offload.v`](environment/public/code/data_offload.v), [`code/data_offload_fsm.v`](environment/public/code/data_offload_fsm.v), [`code/data_offload_regmap.v`](environment/public/code/data_offload_regmap.v), [`code/util_axis_fifo_asym.v`](environment/public/code/util_axis_fifo_asym.v) (4 files, 1540 LOC) |
| **Public Subsystem Context** | 14 RTL files (3259 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

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

## 3. Build & Verification Instructions (`BUILD.md`)

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

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/data_offload.v (Buggy Starter)
+++ b/solution/gold/code/data_offload.v (Golden Reference)
@@ -148,10 +148,12 @@
 
   // local parameters -- to make the code more readable
 
-  localparam  SRC_ADDR_WIDTH_BYPASS = (SRC_DATA_WIDTH > DST_DATA_WIDTH) ? 4 : 4 + $clog2(SRC_DATA_WIDTH/DST_DATA_WIDTH);
+  localparam  SRC_ADDR_WIDTH_BYPASS = (SRC_DATA_WIDTH >= DST_DATA_WIDTH) ? 4 : 4 + $clog2(DST_DATA_WIDTH/SRC_DATA_WIDTH);
   localparam  DST_ADDR_WIDTH_BYPASS = (SRC_DATA_WIDTH <= DST_DATA_WIDTH) ? 4 + $clog2(DST_DATA_WIDTH/SRC_DATA_WIDTH) : 4;
 
   localparam SRC_BEAT_BYTE = $clog2(SRC_DATA_WIDTH/8);
+  localparam SRC_STREAM_W = SRC_DATA_WIDTH + (SRC_DATA_WIDTH/8) + 1;
+  localparam DST_STREAM_W = DST_DATA_WIDTH + (DST_DATA_WIDTH/8) + 1;
 
   // NOTE: Clock domain prefixes
   //    src_*  - AXI4 Stream Slave interface's clock domain
@@ -171,8 +173,10 @@
 
   wire                                        src_clk;
   wire                                        src_rstn;
+  wire                                        src_resetn;
   wire                                        dst_clk;
   wire                                        dst_rstn;
+  wire                                        dst_resetn;
 
   wire                                        src_bypass_s;
   wire                                        dst_bypass_s;
@@ -181,9 +185,24 @@
   wire                                        sync_int_s;
   wire                                        valid_bypass_s;
   wire  [DST_DATA_WIDTH-1:0]                  data_bypass_s;
+  wire                                        last_bypass_s;
+  wire  [DST_DATA_WIDTH/8-1:0]                keep_bypass_s;
   wire                                        ready_bypass_s;
   wire  [ 4:0]                                src_fsm_status_s;
   wire  [ 3:0]                                dst_fsm_status_s;
+
+  wire                                        s_slice_valid_s;
+  wire                                        s_slice_ready_s;
+  wire  [SRC_DATA_WIDTH-1:0]                  s_slice_data_s;
+  wire  [SRC_DATA_WIDTH/8-1:0]                s_slice_keep_s;
+  wire                                        s_slice_last_s;
+
+  wire                                        m_mux_valid_s;
+  wire                                        m_mux_ready_s;
+  wire  [DST_DATA_WIDTH-1:0]                  m_mux_data_s;
+  wire  [DST_DATA_WIDTH/8-1:0]                m_mux_keep_s;
+  wire                                        m_mux_last_s;
+  wire  [DST_DATA_WIDTH-1:0]                  m_slice_data_s;
 
   wire  [MEM_SIZE_LOG2-1:0]                   src_transfer_length_s;
   wire  [MEM_SIZE_LOG2-1:0]                   rd_wr_response_measured_length;
@@ -192,10 +211,145 @@
   wire                                        rd_ml_ready;
   wire                                        wr_ready;
 
+  localparam [1:0] RDC_REQ      = 2'd0;
+  localparam [1:0] RDC_WAIT_REL = 2'd1;
+  localparam [1:0] RDC_RUN      = 2'd2;
+  localparam [1:0] RDC_REARM    = 2'd3;
+
+  wire                                        src_local_rst_s;
+  wire                                        dst_local_rst_s;
+  reg   [1:0]                                 src_rdc_state_q = RDC_REQ;
+  reg   [1:0]                                 src_rdc_cnt_q   = 2'd0;
+  reg                                         src_rdc_cmd_q   = 1'b1;
+  reg                                         src_rdc_rstn_q  = 1'b0;
+  wire                                        src_dst_fault_s;
+  wire                                        src_dst_ack_s;
+
+  reg                                         dst_fault_q     = 1'b1;
+  reg   [1:0]                                 dst_rdc_cnt_q   = 2'd0;
+  reg                                         dst_rdc_ack_q   = 1'b0;
+  reg                                         dst_rdc_rstn_q  = 1'b0;
+  wire                                        dst_src_cmd_s;
+
   assign src_clk = s_axis_aclk;
   assign dst_clk = m_axis_aclk;
-
-  // internal registers
+  assign src_local_rst_s = ~s_axis_aresetn | ~src_rstn;
+  assign dst_local_rst_s = ~m_axis_aresetn | ~dst_rstn;
+
+  sync_bits #(
+    .NUM_OF_BITS (1),
+    .ASYNC_CLK (ASYNC_CLK)
+  ) i_rdc_cmd_sync (
+    .in_bits (src_rdc_cmd_q),
+    .out_clk (dst_clk),
+    .out_resetn (1'b1),
+    .out_bits (dst_src_cmd_s));
+
+  sync_bits #(
+    .NUM_OF_BITS (2),
+    .ASYNC_CLK (ASYNC_CLK)
+  ) i_rdc_stat_sync (
+    .in_bits ({dst_fault_q, dst_rdc_ack_q}),
+    .out_clk (src_clk),
+    .out_resetn (1'b1),
+    .out_bits ({src_dst_fault_s, src_dst_ack_s}));
+
+  always @(posedge dst_clk) begin
+    if (dst_local_rst_s) begin
+      dst_fault_q    <= 1'b1;
+      dst_rdc_ack_q  <= 1'b0;
+      dst_rdc_rstn_q <= 1'b0;
+      if (dst_src_cmd_s) begin
+        if (dst_rdc_cnt_q != 2'd2) begin
+          dst_rdc_cnt_q <= dst_rdc_cnt_q + 2'd1;
+        end
+      end else begin
+        dst_rdc_cnt_q <= 2'd0;
+      end
+    end else if (dst_src_cmd_s) begin
+      dst_rdc_rstn_q <= 1'b0;
+      if (dst_rdc_cnt_q != 2'd2) begin
+        dst_rdc_cnt_q <= dst_rdc_cnt_q + 2'd1;
+        dst_rdc_ack_q <= 1'b0;
+      end else begin
+        dst_fault_q   <= 1'b0;
+        dst_rdc_ack_q <= 1'b1;
+      end
+    end else begin
+      dst_rdc_cnt_q  <= 2'd0;
+      dst_rdc_ack_q  <= 1'b0;
+      dst_rdc_rstn_q <= ~dst_fault_q;
+    end
+  end
+
+  always @(posedge src_clk) begin
+    case (src_rdc_state_q)
+      RDC_REQ: begin
+        src_rdc_rstn_q <= 1'b0;
+        src_rdc_cmd_q  <= 1'b1;
+        if (src_rdc_cnt_q != 2'd2) begin
+          src_rdc_cnt_q <= src_rdc_cnt_q + 2'd1;
+        end else if (!src_local_rst_s && !src_dst_fault_s && src_dst_ack_s) begin
+          src_rdc_state_q <= RDC_WAIT_REL;
+          src_rdc_cmd_q   <= 1'b0;
+        end
+      end
+      RDC_WAIT_REL: begin
+        src_rdc_rstn_q <= 1'b0;
+        src_rdc_cmd_q  <= 1'b0;
+        if (src_local_rst_s || src_dst_fault_s) begin
+          if (!src_dst_ack_s) begin
+            src_rdc_state_q <= RDC_REQ;
+            src_rdc_cmd_q   <= 1'b1;
+            src_rdc_cnt_q   <= 2'd0;
+          end else begin
+            src_rdc_state_q <= RDC_REARM;
+          end
+        end else if (!src_dst_ack_s) begin
+          src_rdc_state_q <= RDC_RUN;
+          src_rdc_rstn_q  <= 1'b1;
+        end
+      end
+      RDC_RUN: begin
+        if (src_local_rst_s || src_dst_fault_s) begin
+          src_rdc_state_q <= RDC_REQ;
+          src_rdc_rstn_q  <= 1'b0;
+          src_rdc_cmd_q   <= 1'b1;
+          src_rdc_cnt_q   <= 2'd0;
+        end else begin
+          src_rdc_rstn_q  <= 1'b1;
+          src_rdc_cmd_q   <= 1'b0;
+        end
+      end
+      default: begin
+        src_rdc_rstn_q <= 1'b0;
+        src_rdc_cmd_q  <= 1'b0;
+        if (!src_dst_ack_s) begin
+          src_rdc_state_q <= RDC_REQ;
+          src_rdc_cmd_q   <= 1'b1;
+          src_rdc_cnt_q   <= 2'd0;
+        end
+      end
+    endcase
+  end
+
+  assign src_resetn = s_axis_aresetn & src_rstn & src_rdc_rstn_q;
+  assign dst_resetn = m_axis_aresetn & dst_rstn & dst_rdc_rstn_q;
+
+  // Input AXI4-Stream register slice for s_axis timing isolation
+  axi_register_slice #(
+    .DATA_WIDTH (SRC_STREAM_W),
+    .FORWARD_REGISTERED (1),
+    .BACKWARD_REGISTERED (1)
+  ) i_s_axis_slice (
+    .clk (src_clk),
+    .resetn (src_resetn),
+    .s_axi_valid (s_axis_valid),
+    .s_axi_ready (s_axis_ready),
+    .s_axi_data ({s_axis_data, s_axis_keep, s_axis_last}),
+    .m_axi_valid (s_slice_valid_s),
+    .m_axi_ready (s_slice_ready_s),
+    .m_axi_data ({s_slice_data_s, s_slice_keep_s, s_slice_last_s}));
 
   // Offload FSM and control
   data_offload_fsm #(
@@ -204,14 +358,14 @@
   ) i_data_offload_fsm (
     .up_clk (up_clk),
     .wr_clk (src_clk),
-    .wr_resetn_in (src_rstn),
+    .wr_resetn_in (src_resetn),
     .wr_request_enable (wr_request_enable),
     .wr_request_valid (wr_request_valid),
     .wr_request_ready (wr_request_ready),
     .wr_response_eot (wr_response_eot),
     .wr_ready (wr_ready),
     .rd_clk (dst_clk),
-    .rd_resetn_in (dst_rstn),
+    .rd_resetn_in (dst_resetn),
     .rd_request_enable (rd_request_enable),
     .rd_request_valid (rd_request_valid),
     .rd_request_ready (rd_request_ready),
@@ -229,55 +383,73 @@
     .wr_fsm_state_out (src_fsm_status_s),
     .rd_fsm_state_out (dst_fsm_status_s));
 
-  assign m_axis_valid = dst_bypass_s ? valid_bypass_s : (rd_ready & s_storage_axis_valid);
-  // For DAC paths set zero as IDLE data on the axis bus, avoid repeating last
-  // sample.
-  assign m_axis_data  = TX_OR_RXN_PATH[0] & ~m_axis_valid ? {DST_DATA_WIDTH{1'b0}} :
-                        (dst_bypass_s) ? data_bypass_s  : s_storage_axis_data;
-  assign m_axis_last  = (dst_bypass_s) ? 1'b0           : s_storage_axis_last;
-  assign m_axis_keep  = (dst_bypass_s) ? {DST_DATA_WIDTH/8{1'b1}} : s_storage_axis_keep;
-  assign s_axis_ready =  src_bypass_s ? ready_bypass_s : (wr_ready & m_storage_axis_ready);
-
-  assign m_storage_axis_valid = s_axis_valid & wr_ready;
-  assign m_storage_axis_data = s_axis_data;
-  assign m_storage_axis_last = s_axis_last;
-  assign m_storage_axis_keep = s_axis_keep;
-
-  assign s_storage_axis_ready = rd_ready & m_axis_ready;
+  assign m_mux_valid_s = dst_bypass_s ? valid_bypass_s : (rd_ready & s_storage_axis_valid);
+  assign m_mux_data_s  = dst_bypass_s ? data_bypass_s  : s_storage_axis_data;
+  assign m_mux_last_s  = dst_bypass_s ? last_bypass_s  : s_storage_axis_last;
+  assign m_mux_keep_s  = dst_bypass_s ? keep_bypass_s  : s_storage_axis_keep;
+
+  axi_register_slice #(
+    .DATA_WIDTH (DST_STREAM_W),
+    .FORWARD_REGISTERED (1),
+    .BACKWARD_REGISTERED (1)
+  ) i_m_axis_slice (
+    .clk (dst_clk),
+    .resetn (dst_resetn),
+    .s_axi_valid (m_mux_valid_s),
+    .s_axi_ready (m_mux_ready_s),
+    .s_axi_data ({m_mux_data_s, m_mux_keep_s, m_mux_last_s}),
+    .m_axi_valid (m_axis_valid),
+    .m_axi_ready (m_axis_ready),
+    .m_axi_data ({m_slice_data_s, m_axis_keep, m_axis_last}));
+
+  // For DAC paths set zero as IDLE data on the axis bus, avoid repeating last sample.
+  assign m_axis_data = (TX_OR_RXN_PATH[0] & ~m_axis_valid) ? {DST_DATA_WIDTH{1'b0}} : m_slice_data_s;
+
+  assign s_slice_ready_s = src_bypass_s ? ready_bypass_s : (wr_ready & m_storage_axis_ready);
+
+  assign m_storage_axis_valid = s_slice_valid_s & wr_ready & ~src_bypass_s;
+  assign m_storage_axis_data = s_slice_data_s;
+  assign m_storage_axis_last = s_slice_last_s;
+  assign m_storage_axis_keep = s_slice_keep_s;
+
+  assign s_storage_axis_ready = ~dst_bypass_s & rd_ready & m_mux_ready_s;
 
   // Bypass module instance -- the same FIFO, just a smaller depth
-  // NOTE: Generating an overflow is making sense just in BYPASS mode, and
-  // it's supported just with the FIFO interface
   generate if (HAS_BYPASS) begin
     util_axis_fifo_asym #(
       .S_DATA_WIDTH (SRC_DATA_WIDTH),
       .ADDRESS_WIDTH (SRC_ADDR_WIDTH_BYPASS),
       .M_DATA_WIDTH (DST_DATA_WIDTH),
-      .ASYNC_CLK (ASYNC_CLK)
+      .ASYNC_CLK (ASYNC_CLK),
+      .TLAST_EN (1),
+      .TKEEP_EN (1),
+      .SRC_REG_SLICE_EN (1)
     ) i_bypass_fifo (
       .m_axis_aclk (m_axis_aclk),
-      .m_axis_aresetn (dst_rstn),
-      .m_axis_ready (m_axis_ready),
+      .m_axis_aresetn (dst_resetn),
+      .m_axis_ready (dst_bypass_s & m_mux_ready_s),
       .m_axis_valid (valid_bypass_s),
       .m_axis_data  (data_bypass_s),
-      .m_axis_tlast (),
+      .m_axis_tlast (last_bypass_s),
       .m_axis_empty (),
       .m_axis_almost_empty (),
-      .m_axis_tkeep (),
+      .m_axis_tkeep (keep_bypass_s),
       .m_axis_level (),
       .s_axis_aclk  (s_axis_aclk),
-      .s_axis_aresetn (src_rstn),
+      .s_axis_aresetn (src_resetn),
       .s_axis_ready (ready_bypass_s),
-      .s_axis_valid (s_axis_valid & src_bypass_s),
-      .s_axis_data  (s_axis_data),
-      .s_axis_tlast (),
+      .s_axis_valid (s_slice_valid_s & src_bypass_s),
+      .s_axis_data  (s_slice_data_s),
+      .s_axis_tlast (s_slice_last_s),
       .s_axis_full  (),
       .s_axis_almost_full (),
-      .s_axis_tkeep (),
+      .s_axis_tkeep (s_slice_keep_s),
       .s_axis_room ());
   end else begin
       assign valid_bypass_s = 1'b0;
       assign data_bypass_s = 'd0;
+      assign last_bypass_s = 1'b0;
+      assign keep_bypass_s = {DST_DATA_WIDTH/8{1'b0}};
       assign ready_bypass_s = 1'b0;
   end endgenerate
 
@@ -361,7 +533,7 @@
     .ASYNC_CLK(ASYNC_CLK)
   ) i_measured_length_cdc (
     .s_axis_aclk(s_axis_aclk),
-    .s_axis_aresetn(s_axis_aresetn),
+    .s_axis_aresetn(src_resetn),
     .s_axis_valid(wr_response_eot),
     .s_axis_ready(),
     .s_axis_full(),
@@ -372,7 +544,7 @@
     .s_axis_almost_full(),
 
     .m_axis_aclk(m_axis_aclk),
-    .m_axis_aresetn(m_axis_aresetn),
+    .m_axis_aresetn(dst_resetn),
     .m_axis_valid(rd_ml_valid),
     .m_axis_ready(rd_ml_ready),
     .m_axis_data(rd_wr_response_measured_length),
@@ -383,8 +555,11 @@
     .m_axis_almost_empty());
 
   always @(posedge m_axis_aclk) begin
-    if (rd_ml_valid & rd_ml_ready)
-     rd_request_length <= rd_wr_response_measured_length;
+    if (!dst_resetn) begin
+      rd_request_length <= {MEM_SIZE_LOG2{1'b0}};
+    end else if (rd_ml_valid & rd_ml_ready) begin
+      rd_request_length <= rd_wr_response_measured_length;
+    end
   end
 
 endmodule

--- a/environment/public/code/data_offload_fsm.v (Buggy Starter)
+++ b/solution/gold/code/data_offload_fsm.v (Golden Reference)
@@ -118,6 +118,7 @@
 
   // internal registers
   reg rd_cyclic_en = 1'b0;
+  reg rd_reinit_armed = 1'b0;
 
   // internal signals
   wire    wr_sync_external_s;
@@ -126,12 +127,13 @@
   wire    rd_sync_external_s;
   wire    rd_last_eot;
   wire    rd_init_req_s;
+  wire    rd_auto_cyclic_req_s;
 
   reg [4:0] wr_fsm_state = WR_STATE_IDLE;
   reg [4:0] wr_fsm_next_state;
   reg [3:0] rd_fsm_state = RD_STATE_IDLE;
   reg [3:0] rd_fsm_next_state;
-  reg [1:0] rd_outstanding = 2'd0;
+  reg [2:0] rd_outstanding = 3'd0;
 
   assign wr_fsm_state_out = wr_fsm_state;
   assign rd_fsm_state_out = rd_fsm_state;
@@ -213,7 +215,7 @@
       RD_STATE_RD:
         if (rd_last_eot) begin
           rd_fsm_next_state = (rd_cyclic_en == 1'b0)      ? RD_STATE_IDLE :
-            (TX_OR_RXN_PATH & (sync_config != AUTOMATIC)) ? RD_STATE_SYNC :
+            (TX_OR_RXN_PATH & (sync_config != AUTOMATIC)) ? RD_STATE_PRE_RD :
                                                             RD_STATE_RD;
         end
       default:
@@ -231,27 +233,41 @@
 
   always @(posedge rd_clk) begin
     if (rd_resetn_in == 1'b0)
-      rd_outstanding <= 2'b0;
-    else if (rd_request_ready & rd_request_valid & ~rd_response_eot)
-      rd_outstanding <= rd_outstanding + 2'd1;
-    else if (~(rd_request_ready & rd_request_valid) & (rd_response_eot & rd_fsm_state[RD_BIT_RD]))
-      rd_outstanding <= rd_outstanding - 2'd1;
-  end
-  assign rd_last_eot = (rd_outstanding == 1) & (rd_response_eot & rd_fsm_state[RD_BIT_RD]) & !(rd_request_ready & rd_request_valid);
-
-  always @(posedge rd_clk) begin
-    if (rd_init_req_s) begin
+      rd_outstanding <= 3'd0;
+    else if (rd_request_ready & rd_request_valid & ~(rd_response_eot & rd_fsm_state[RD_BIT_RD]))
+      rd_outstanding <= rd_outstanding + 3'd1;
+    else if (~(rd_request_ready & rd_request_valid) & (rd_response_eot & rd_fsm_state[RD_BIT_RD]) & (rd_outstanding != 3'd0))
+      rd_outstanding <= rd_outstanding - 3'd1;
+  end
+  assign rd_last_eot = (rd_outstanding == 3'd1) & (rd_response_eot & rd_fsm_state[RD_BIT_RD]) & !(rd_request_ready & rd_request_valid);
+
+  always @(posedge rd_clk) begin
+    if (rd_resetn_in == 1'b0) begin
       rd_cyclic_en <= 1'b0;
-    end else if (rd_fsm_state[RD_BIT_PRE_RD]) begin
+      rd_reinit_armed <= 1'b0;
+    end else if (rd_fsm_state[RD_BIT_IDLE] && rd_ml_valid) begin
       rd_cyclic_en <= ~rd_oneshot;
+      rd_reinit_armed <= ~rd_init_req_s;
+    end else begin
+      if (~rd_init_req_s) begin
+        rd_reinit_armed <= 1'b1;
+      end
+      if (rd_reinit_armed && rd_init_req_s) begin
+        rd_cyclic_en <= 1'b0;
+      end
     end
   end
 
   assign rd_ready = rd_fsm_state[RD_BIT_RD];
   assign wr_ready = wr_fsm_state[WR_BIT_WR];
 
+  assign rd_auto_cyclic_req_s = rd_cyclic_en &
+                                ~(TX_OR_RXN_PATH[0] & (sync_config != AUTOMATIC)) &
+                                (rd_fsm_state[RD_BIT_SYNC] | rd_fsm_state[RD_BIT_RD]) &
+                                (rd_outstanding < 3'd2);
+
   assign wr_request_valid = wr_fsm_state[WR_BIT_PRE_WR];
-  assign rd_request_valid = rd_fsm_state[RD_BIT_PRE_RD] | rd_cyclic_en;
+  assign rd_request_valid = rd_fsm_state[RD_BIT_PRE_RD] | rd_auto_cyclic_req_s;
 
   always @(posedge rd_clk) begin
     if (rd_resetn_in == 1'b0 || (~rd_init_req_s & ~TX_OR_RXN_PATH[0]))
@@ -270,14 +286,36 @@
   assign rd_ml_ready = rd_fsm_state[RD_BIT_IDLE];
 
   // CDC circuits
-  sync_event #(
-    .NUM_OF_EVENTS (1),
+  reg  rd_eot_tog_q = 1'b0;
+  wire wr_eot_tog_s;
+  reg  wr_eot_tog_d = 1'b0;
+
+  always @(posedge rd_clk) begin
+    if (rd_resetn_in == 1'b0) begin
+      rd_eot_tog_q <= 1'b0;
+    end else if (rd_last_eot && rd_fsm_state[RD_BIT_RD] && !rd_cyclic_en) begin
+      rd_eot_tog_q <= ~rd_eot_tog_q;
+    end
+  end
+
+  sync_bits #(
+    .NUM_OF_BITS (1),
     .ASYNC_CLK (1)
   ) i_wr_empty_sync (
-    .in_clk (rd_clk),
-    .in_event (rd_last_eot && rd_fsm_state[RD_BIT_RD]),
+    .in_bits (rd_eot_tog_q),
     .out_clk (wr_clk),
-    .out_event (wr_rd_response_eot));
+    .out_resetn (wr_resetn_in),
+    .out_bits (wr_eot_tog_s));
+
+  always @(posedge wr_clk) begin
+    if (wr_resetn_in == 1'b0) begin
+      wr_eot_tog_d <= 1'b0;
+    end else begin
+      wr_eot_tog_d <= wr_eot_tog_s;
+    end
+  end
+
+  assign wr_rd_response_eot = wr_eot_tog_s ^ wr_eot_tog_d;
 
   sync_bits #(
     .NUM_OF_BITS (1),
@@ -306,7 +344,7 @@
   ) i_sync_wr_sync (
     .in_bits ({ sync_external }),
     .out_clk (wr_clk),
-    .out_resetn (1'b1),
+    .out_resetn (wr_resetn_in),
     .out_bits ({wr_sync_external_s}));
 
   sync_bits #(
@@ -315,7 +353,7 @@
   ) i_sync_rd_sync (
     .in_bits ({ sync_external }),
     .out_clk (rd_clk),
-    .out_resetn (1'b1),
+    .out_resetn (rd_resetn_in),
     .out_bits ({ rd_sync_external_s }));
 
 endmodule

--- a/environment/public/code/data_offload_regmap.v (Buggy Starter)
+++ b/solution/gold/code/data_offload_regmap.v (Golden Reference)
@@ -164,7 +164,7 @@
         up_bypass <= up_wdata[0] & HAS_BYPASS;
       end
       /* SYNC Offload Register - self cleared, one pulse signal */
-      if ((up_wreq == 1'b1) && (up_waddr[13:0] == 14'h40)) begin
+      if ((up_wreq == 1'b1) && (up_waddr[13:0] == 14'h40) && up_sw_resetn) begin
         up_sync <= up_wdata[0];
       end else begin
         up_sync <= 1'b0;
@@ -294,28 +294,42 @@
   if (TX_OR_RXN_PATH) begin : sync_tx_path
 
     sync_data #(
-      .NUM_OF_BITS (3),
+      .NUM_OF_BITS (2),
       .ASYNC_CLK (1)
     ) i_sync_xfer_control (
       .in_clk (up_clk),
-      .in_data ({up_sync_config,
-                 up_sync}),
+      .in_data (up_sync_config),
       .out_clk (dst_clk),
-      .out_data ({sync_config,
-                  sync}));
+      .out_data (sync_config));
+
+    sync_event #(
+      .NUM_OF_EVENTS (1),
+      .ASYNC_CLK (1)
+    ) i_sync_trigger_event (
+      .in_clk (up_clk),
+      .in_event (up_sync),
+      .out_clk (dst_clk),
+      .out_event (sync));
 
   end else begin : sync_rx_path
 
     sync_data #(
-      .NUM_OF_BITS (3),
+      .NUM_OF_BITS (2),
       .ASYNC_CLK (1)
     ) i_sync_xfer_control (
       .in_clk (up_clk),
-      .in_data ({up_sync_config,
-                 up_sync}),
+      .in_data (up_sync_config),
       .out_clk (src_clk),
-      .out_data ({sync_config,
-                  sync}));
+      .out_data (sync_config));
+
+    sync_event #(
+      .NUM_OF_EVENTS (1),
+      .ASYNC_CLK (1)
+    ) i_sync_trigger_event (
+      .in_clk (up_clk),
+      .in_event (up_sync),
+      .out_clk (src_clk),
+      .out_event (sync));
 
   end
   endgenerate

--- a/environment/public/code/util_axis_fifo_asym.v (Buggy Starter)
+++ b/solution/gold/code/util_axis_fifo_asym.v (Golden Reference)
@@ -45,7 +45,7 @@
   parameter TLAST_EN = 0,
   parameter TKEEP_EN = 0,
   parameter REDUCED_FIFO = 1,
-  parameter SRC_REG_SLICE_EN = 0
+  parameter SRC_REG_SLICE_EN = 1
 ) (
   input m_axis_aclk,
   input m_axis_aresetn,
@@ -261,20 +261,24 @@
         assign s_axis_tlast_int_s[i] = (s_axis_counter == i) ? s_axis_tlast : 1'b0;
       end
 
+      wire [RATIO-1:0] s_tail_mask_s = {RATIO{1'b1}} << s_axis_counter;
+      wire s_tail_ready_s = &(s_axis_ready_int_s | ~s_tail_mask_s);
+      wire s_cur_ready_s = s_axis_ready_int_s[s_axis_counter];
+
       // insert invalid writes (TKEEP==0) in case if the TLAST arrives before the RATIO
       // boundary
       always @(*) begin
         case ({s_axis_valid, s_axis_tlast})
           2'b00 : s_axis_valid_int_d = {RATIO{1'b0}};
           2'b01 : s_axis_valid_int_d = {RATIO{1'b0}};
-          2'b10 : s_axis_valid_int_d = {{RATIO-1{1'b0}}, 1'b1} << s_axis_counter;
-          2'b11 : s_axis_valid_int_d = {RATIO{&(s_axis_ready_int_s)}} << s_axis_counter;
+          2'b10 : s_axis_valid_int_d = s_cur_ready_s ? ({{RATIO-1{1'b0}}, 1'b1} << s_axis_counter) : {RATIO{1'b0}};
+          2'b11 : s_axis_valid_int_d = s_tail_ready_s ? s_tail_mask_s : {RATIO{1'b0}};
         endcase
       end
       assign s_axis_valid_int_s = s_axis_valid_int_d;
 
-      // disable read enable if the TLAST arrives before address handshake occurs
-      assign s_axis_ready = (s_axis_tlast) ? &(s_axis_ready_int_s) : s_axis_ready_int_s >> s_axis_counter;
+      // only require readiness from lanes actually written on this beat
+      assign s_axis_ready = s_axis_tlast ? s_tail_ready_s : s_cur_ready_s;
 
       // FULL/ALMOST_FULL is driven by the current atomic instance
       assign s_axis_almost_full = s_axis_almost_full_int_s >> s_axis_counter;
@@ -338,14 +342,9 @@
       end
 
       assign m_axis_data = m_axis_data_int_s;
-      // if every instance has a valid data, the interface has valid data,
-      // otherwise valid is asserted only if TLAST is asserted
-      // assign m_axis_valid_int = (|(m_axis_tlast_int_s & m_axis_valid_int_s)) ? |m_axis_valid_int_s : &m_axis_valid_int_s;
-      if (TLAST_EN) begin
-        assign m_axis_valid_int = (|(m_axis_tlast_int_s & m_axis_valid_int_s)) ? |m_axis_valid_int_s : &m_axis_valid_int_s;
-      end else begin
-        assign m_axis_valid_int = &m_axis_valid_int_s;
-      end
+      // small_slave pads every early-TLAST beat across all RATIO lanes, so a complete
+      // wide word requires every atomic FIFO instance to present valid data atomically.
+      assign m_axis_valid_int = &m_axis_valid_int_s;
       assign m_axis_valid = m_axis_valid_int;
       // if one of the atomic instance is empty, m_axis_empty should be asserted
       assign m_axis_empty = |m_axis_empty_int_s;

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE_ADIBSD`](environment/public/code/LICENSE_ADIBSD) *(Read-Only Context)*
- [`environment/public/code/LICENSE_GPL2`](environment/public/code/LICENSE_GPL2) *(Read-Only Context)*
- [`environment/public/code/ad_mem.v`](environment/public/code/ad_mem.v) *(Read-Only Context)*
- [`environment/public/code/axi_register_slice.v`](environment/public/code/axi_register_slice.v) *(Read-Only Context)*
- [`environment/public/code/data_offload.v`](environment/public/code/data_offload.v) **(Editable)**
- [`environment/public/code/data_offload_fsm.v`](environment/public/code/data_offload_fsm.v) **(Editable)**
- [`environment/public/code/data_offload_regmap.v`](environment/public/code/data_offload_regmap.v) **(Editable)**
- [`environment/public/code/data_offload_subsys.v`](environment/public/code/data_offload_subsys.v) *(Read-Only Context)*
- [`environment/public/code/sync_bits.v`](environment/public/code/sync_bits.v) *(Read-Only Context)*
- [`environment/public/code/sync_data.v`](environment/public/code/sync_data.v) *(Read-Only Context)*
- [`environment/public/code/sync_event.v`](environment/public/code/sync_event.v) *(Read-Only Context)*
- [`environment/public/code/sync_gray.v`](environment/public/code/sync_gray.v) *(Read-Only Context)*
- [`environment/public/code/up_axi.v`](environment/public/code/up_axi.v) *(Read-Only Context)*
- [`environment/public/code/util_axis_fifo.v`](environment/public/code/util_axis_fifo.v) *(Read-Only Context)*
- [`environment/public/code/util_axis_fifo_address_generator.v`](environment/public/code/util_axis_fifo_address_generator.v) *(Read-Only Context)*
- [`environment/public/code/util_axis_fifo_asym.v`](environment/public/code/util_axis_fifo_asym.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/LICENSE.Nangate45`](environment/public/lib/LICENSE.Nangate45) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lib/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.tech.lef`](environment/public/lib/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

