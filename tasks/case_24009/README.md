# `case_24009`: Odd/Non-Power-of-Two Channel Generalization, Dynamic Mask Reconfiguration, and 4-State Gate-Level Parity in ADI util_pack

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_24009` |
| **Source Silicon Repository** | `analogdevicesinc/hdl` (`repo_38`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/util_cpack2_impl.v`](environment/public/code/util_cpack2_impl.v), [`code/util_upack2_impl.v`](environment/public/code/util_upack2_impl.v), [`code/pack_shell.v`](environment/public/code/pack_shell.v), [`code/pack_ctrl.v`](environment/public/code/pack_ctrl.v), [`code/pack_network.v`](environment/public/code/pack_network.v) (5 files, 1512 LOC) |
| **Public Subsystem Context** | 8 RTL files (1866 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Task-Specific Multi-Corner Liberty & SDC Timing Views** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Custom characterized fast/slow/scan corner Liberty libraries for multi-mode OpenSTA closure. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

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

## 3. Build & Verification Instructions (`BUILD.md`)

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

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/util_cpack2_impl.v (Buggy Starter)
+++ b/solution/gold/code/util_cpack2_impl.v (Golden Reference)
@@ -1,38 +1,5 @@
-// ***************************************************************************
-// ***************************************************************************
-// Copyright (C) 2018-2026 Analog Devices, Inc. All rights reserved.
-//
-// In this HDL repository, there are many different and unique modules, consisting
-// of various HDL (Verilog or VHDL) components. The individual modules are
-// developed independently, and may be accompanied by separate and unique license
-// terms.
-//
-// The user should read each of these license terms, and understand the
-// freedoms and responsibilities that he or she has by using this source/core.
-//
-// This core is distributed in the hope that it will be useful, but WITHOUT ANY
-// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
-// A PARTICULAR PURPOSE.
-//
-// Redistribution and use of source or resulting binaries, with or without modification
-// of this file, are permitted under one of the following two license terms:
-//
-//   1. The GNU General Public License version 2 as published by the
-//      Free Software Foundation, which can be found in the top level directory
-//      of this repository (LICENSE_GPL2), and also online at:
-//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
-//
-// OR
-//
-//   2. An ADI specific BSD license, which can be found in the top level directory
-//      of this repository (LICENSE_ADIBSD), and also on-line at:
-//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
-//      This will allow to generate bit files and not release the source code,
-//      as long as it attaches to an ADI device.
-//
-// ***************************************************************************
-// ***************************************************************************
-
+// SPDX-License-Identifier: GPL-2.0-only OR ADIBSD
+// Copyright (C) 2017-2026 Analog Devices, Inc. All rights reserved.
 `timescale 1ns/100ps
 
 module util_cpack2_impl #(
@@ -61,137 +28,62 @@
   output packed_fifo_wr_en,
   input packed_fifo_wr_overflow,
   output [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] packed_fifo_wr_data,
-  output reg packed_sync = 1'b1
+  output reg packed_sync = 1'b0
 );
 
   localparam TOTAL_DATA_WIDTH = SAMPLE_DATA_WIDTH * SAMPLES_PER_CHANNEL * NUM_OF_CHANNELS;
   localparam NUM_OF_SAMPLES = NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL;
-
-  /*
-   * Pipelining is not supported with the AXI-Stream interface: m_axis_ready
-   * stalls the packer and the pipelined path then repeats and drops beats.
-   * PIPELINE_STAGES is ignored in that case.
-   */
+  localparam KEEP_WIDTH = TOTAL_DATA_WIDTH / 8 > 0 ? TOTAL_DATA_WIDTH / 8 : 1;
   localparam PIPELINE_STAGES_INT = INTERFACE_TYPE == 1 ? PIPELINE_STAGES : 0;
 
-  localparam
-    SAMPLE_ADDRESS_WIDTH = NUM_OF_SAMPLES > 512 ? 10 :
-    NUM_OF_SAMPLES > 256 ? 9 :
-    NUM_OF_SAMPLES > 128 ? 8 :
-    NUM_OF_SAMPLES > 64 ? 7 :
-    NUM_OF_SAMPLES > 32 ? 6 :
-    NUM_OF_SAMPLES > 16 ? 5 :
-    NUM_OF_SAMPLES > 8 ? 4 :
-    NUM_OF_SAMPLES > 4 ? 3 :
-    NUM_OF_SAMPLES > 2 ? 2 : 1;
-
-  localparam NETWORK0_STAGES = SAMPLE_ADDRESS_WIDTH / 2;
-  localparam NETWORK1_STAGES = SAMPLE_ADDRESS_WIDTH % 2;
-
-  // Calculate pipeline latency per network based on PIPELINE_STAGES parameter
-  function integer calc_pipeline_latency;
-    input integer num_stages;
-    begin
-      if (PIPELINE_STAGES_INT == 2)
-        calc_pipeline_latency = num_stages;
-      else if (PIPELINE_STAGES_INT == 1)
-        calc_pipeline_latency = num_stages / 2;
-      else
-        calc_pipeline_latency = 0;
-    end
-  endfunction
-
-  localparam
-    TOTAL_PIPELINE_LATENCY = (NUM_OF_CHANNELS == 1) ? 0 :
-    calc_pipeline_latency(NETWORK0_STAGES) +
-    calc_pipeline_latency(NETWORK1_STAGES);
-
-  //Internal write signal.
   wire data_wr_en;
-
-  // Control signals from the pack shell.
   wire ce;
   wire flush;
   wire ready;
   wire reset_data;
+  wire active_cfg;
 
   wire out_ready_int;
   reg out_valid_int = 1'b0;
-  reg [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] out_data_int = 'h00;
+  reg [TOTAL_DATA_WIDTH-1:0] out_data_int = {TOTAL_DATA_WIDTH{1'b0}};
 
-  // Interleaved version of `fifo_wr_data`.
   wire [TOTAL_DATA_WIDTH-1:0] interleaved_data;
-
-  // Output data and corresponding control signal from the routing network.
   wire [TOTAL_DATA_WIDTH-1:0] out_data;
   wire out_sync;
-  wire [NUM_OF_CHANNELS*SAMPLES_PER_CHANNEL-1:0] out_valid;
+  wire [NUM_OF_SAMPLES-1:0] out_valid;
+
+  reg [NUM_OF_CHANNELS-1:0] enable_d = {NUM_OF_CHANNELS{1'b0}};
+  always @(posedge clk) begin
+    if (reset == 1'b1)
+      enable_d <= {NUM_OF_CHANNELS{1'b0}};
+    else
+      enable_d <= enable;
+  end
+  assign active_cfg = (~reset) & (~reset_data) & (|enable) & (enable == enable_d);
 
   generate if (INTERFACE_TYPE == 1) begin
     assign out_ready_int = 1'b1;
     assign packed_fifo_wr_en = out_valid_int;
     assign packed_fifo_wr_data = out_data_int;
     assign m_axis_valid = 1'b0;
-    assign m_axis_data = 'h00;
-    assign m_axis_keep = 'h00;
+    assign m_axis_data = {TOTAL_DATA_WIDTH{1'b0}};
+    assign m_axis_keep = {KEEP_WIDTH{1'b0}};
     assign m_axis_last = 1'b0;
   end else begin
     assign out_ready_int = m_axis_ready;
     assign packed_fifo_wr_en = 1'b0;
-    assign packed_fifo_wr_data = 'h00;
+    assign packed_fifo_wr_data = {TOTAL_DATA_WIDTH{1'b0}};
     assign m_axis_valid = out_valid_int;
     assign m_axis_data = out_data_int;
-    assign m_axis_keep = {(NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL/8){1'b1}};
+    assign m_axis_keep = {KEEP_WIDTH{1'b1}};
     assign m_axis_last = 1'b0;
   end endgenerate
 
-  /*
-   * Only the first signal of fifo_rd_en is used. All others are ignored. The
-   * only reason why fifo_rd_en has multiple entries is to keep the interface
-   * somewhat backwards compatible to the previous upack.
-   */
-  assign data_wr_en = fifo_wr_en[0];
+  assign data_wr_en = fifo_wr_en[0] & active_cfg;
   assign ce = data_wr_en & out_ready_int;
-
-  // Downstream backpressure.
   assign flush = ~out_ready_int;
-
-  wire data_wr_en_delayed;
-
-  /*
-   * Ce-gated delay for data_wr_en to match the ce-gated data pipeline.
-   * When PIPELINE_STAGES > 0, the data pipeline is ce-gated, so this
-   * delay must also be ce-gated.
-   */
-  generate
-    if (TOTAL_PIPELINE_LATENCY == 0) begin: gen_wr_en_comb
-      assign data_wr_en_delayed = data_wr_en;
-    end else begin: gen_wr_en_pipe
-      (* shreg_extract = "no" *) reg [TOTAL_PIPELINE_LATENCY:0] wr_en_sr = 'h0;
-      integer wei;
-      always @(posedge clk) begin
-        if (data_wr_en == 1'b1) begin
-          wr_en_sr[0] <= data_wr_en;
-          for (wei = 1; wei <= TOTAL_PIPELINE_LATENCY; wei = wei + 1)
-            wr_en_sr[wei] <= wr_en_sr[wei-1];
-        end
-      end
-      assign data_wr_en_delayed = wr_en_sr[TOTAL_PIPELINE_LATENCY];
-    end
-  endgenerate
-
-  /*
-   * The cpack core itself has no backpressure. Overflows can only happen
-   * downstream.
-   */
-
   assign fifo_wr_overflow = packed_fifo_wr_overflow;
 
-  /*
-   * Data at the input of the routing network should be interleaved. The cpack
-   * core is supposed to accept deinterleaved data. This just rearrange the bits
-   * in the data vector and does not consume any FPGA resources.
-   */
   ad_perfect_shuffle #(
     .NUM_GROUPS (NUM_OF_CHANNELS),
     .WORDS_PER_GROUP (SAMPLES_PER_CHANNEL),
@@ -210,9 +102,7 @@
   ) i_pack_shell (
     .clk (clk),
     .reset (reset),
-
     .reset_data (reset_data),
-
     .enable (enable),
     .ce (ce),
     .flush (flush),
@@ -223,10 +113,10 @@
     .out_valid (out_valid));
 
   always @(posedge clk) begin
-    if (reset_data == 1'b1) begin
+    if (reset == 1'b1 || reset_data == 1'b1 || !active_cfg) begin
       out_valid_int <= 1'b0;
       packed_sync <= 1'b0;
-    end else if (ready == 1'b1 && data_wr_en == 1'b1) begin
+    end else if (ready == 1'b1 && ce == 1'b1) begin
       out_valid_int <= 1'b1;
       packed_sync <= out_sync;
     end else begin
@@ -237,9 +127,10 @@
 
   always @(posedge clk) begin: gen_packed_fifo_wr_data
     integer i;
-
-    if (data_wr_en == 1'b1) begin
-      for (i = 0; i < NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL; i = i + 1) begin
+    if (reset == 1'b1 || reset_data == 1'b1 || !active_cfg) begin
+      out_data_int <= {TOTAL_DATA_WIDTH{1'b0}};
+    end else if (ce == 1'b1) begin
+      for (i = 0; i < NUM_OF_SAMPLES; i = i + 1) begin
         if (out_valid[i] == 1'b1) begin
           out_data_int[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH] <= out_data[i*SAMPLE_DATA_WIDTH+:SAMPLE_DATA_WIDTH];
         end

--- a/environment/public/code/util_upack2_impl.v (Buggy Starter)
+++ b/solution/gold/code/util_upack2_impl.v (Golden Reference)
@@ -1,38 +1,5 @@
-// ***************************************************************************
-// ***************************************************************************
-// Copyright (C) 2018-2023, 2025-2026 Analog Devices, Inc. All rights reserved.
-//
-// In this HDL repository, there are many different and unique modules, consisting
-// of various HDL (Verilog or VHDL) components. The individual modules are
-// developed independently, and may be accompanied by separate and unique license
-// terms.
-//
-// The user should read each of these license terms, and understand the
-// freedoms and responsibilities that he or she has by using this source/core.
-//
-// This core is distributed in the hope that it will be useful, but WITHOUT ANY
-// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
-// A PARTICULAR PURPOSE.
-//
-// Redistribution and use of source or resulting binaries, with or without modification
-// of this file, are permitted under one of the following two license terms:
-//
-//   1. The GNU General Public License version 2 as published by the
-//      Free Software Foundation, which can be found in the top level directory
-//      of this repository (LICENSE_GPL2), and also online at:
-//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
-//
-// OR
-//
-//   2. An ADI specific BSD license, which can be found in the top level directory
-//      of this repository (LICENSE_ADIBSD), and also on-line at:
-//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
-//      This will allow to generate bit files and not release the source code,
-//      as long as it attaches to an ADI device.
-//
-// ***************************************************************************
-// ***************************************************************************
-
+// SPDX-License-Identifier: GPL-2.0-only OR ADIBSD
+// Copyright (C) 2017-2026 Analog Devices, Inc. All rights reserved.
 `timescale 1ns/100ps
 
 module util_upack2_impl #(
@@ -58,6 +25,7 @@
 );
 
   localparam NUM_OF_SAMPLES = NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL;
+  localparam TOTAL_DATA_WIDTH = NUM_OF_SAMPLES * SAMPLE_DATA_WIDTH;
 
   localparam
     SAMPLE_ADDRESS_WIDTH = NUM_OF_SAMPLES > 512 ? 10 :
@@ -71,12 +39,10 @@
     NUM_OF_SAMPLES > 2 ? 2 : 1;
 
   localparam NON_POWER_OF_TWO = NUM_OF_CHANNELS > 2;
-
   localparam NETWORK0_STAGES = (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) / 2;
   localparam NETWORK1_STAGES = (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) % 2;
   localparam EXT_NETWORK_STAGES = NON_POWER_OF_TWO ? 1 : 0;
 
-  // Calculate pipeline latency per network based on PIPELINE_STAGES parameter
   function integer calc_pipeline_latency;
     input integer num_stages;
     begin
@@ -95,36 +61,24 @@
     calc_pipeline_latency(NETWORK1_STAGES) +
     calc_pipeline_latency(EXT_NETWORK_STAGES);
 
-  /*
-   * Final output data of the routing network that will be written to
-   * `fifo_rd_data` after being deinterleaved.
-   */
-  wire [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] out_data;
-
-  /*
-   * Deinterleaved version of `out_data`
-   */
-  wire [NUM_OF_CHANNELS*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] deinterleaved_data;
-
-  /*
-   * Internal read signal.
-   */
+  wire [TOTAL_DATA_WIDTH-1:0] out_data;
+  wire [TOTAL_DATA_WIDTH-1:0] deinterleaved_data;
   wire data_rd_en;
-
-  /*
-   * Control signals from/to the pack shell.
-   */
   wire ce;
   wire ready;
   wire reset_data;
 
-  /*
-   * Only the first signal of fifo_rd_en is used. All others are ignored. The
-   * only reason why fifo_rd_en has multiple entries is to keep the interface
-   * somewhat backwards compatible to the previous upack.
-   */
-  assign data_rd_en = fifo_rd_en[0];
+  reg [NUM_OF_CHANNELS-1:0] enable_d = {NUM_OF_CHANNELS{1'b0}};
+  always @(posedge clk) begin
+    if (reset == 1'b1)
+      enable_d <= {NUM_OF_CHANNELS{1'b0}};
+    else
+      enable_d <= enable;
+  end
 
+  wire cfg_busy = reset | reset_data | (~(|enable)) | (enable != enable_d);
+
+  assign data_rd_en = fifo_rd_en[0] & ~cfg_busy;
   assign ce = s_axis_valid & data_rd_en;
   assign s_axis_ready = ready & ce;
 
@@ -137,7 +91,7 @@
     .WIDTH(1)
   ) i_data_rd_en_pipe (
     .clk(clk),
-    .in(data_rd_en),
+    .in(fifo_rd_en[0] & ~reset),
     .out(data_rd_en_delayed));
 
   util_pipeline_stage #(
@@ -153,7 +107,7 @@
     .WIDTH(1)
   ) i_reset_data_pipe (
     .clk(clk),
-    .in(reset_data),
+    .in(cfg_busy),
     .out(reset_data_delayed));
 
   pack_shell #(
@@ -166,24 +120,16 @@
   ) i_pack_shell (
     .clk (clk),
     .reset (reset),
-
     .reset_data (reset_data),
-
     .enable (enable),
     .ce (ce),
     .flush (1'b0),
     .ready (ready),
     .in_data (s_axis_data),
     .out_data (out_data),
-
     .out_valid (),
     .out_sync ());
 
-  /*
-   * Data at the output of the routing network is interleaved. The upack
-   * core is supposed to produce deinterleaved data. This just rearrange the
-   * bits in the data vector and does not consume any FPGA resources.
-   */
   ad_perfect_shuffle #(
     .NUM_GROUPS (SAMPLES_PER_CHANNEL),
     .WORDS_PER_GROUP (NUM_OF_CHANNELS),
@@ -192,28 +138,24 @@
     .data_in (out_data),
     .data_out (deinterleaved_data));
 
-  /*
-   * `reset_data_delayed` lags `reset_data`, so words read just before a reset
-   * (or before the first one, while `reset_data` still has its power-up value)
-   * would leave the network after the reset was released. Suppress output
-   * while either copy is asserted.
-   */
-  wire reset_out = reset_data | reset_data_delayed;
+  wire reset_out = cfg_busy | reset_data_delayed;
 
   always @(posedge clk) begin
-    /* In case of an underflow or reset the output vector should be zeroed */
-    if (reset_out == 1'b1 ||
+    if (reset == 1'b1 || reset_out == 1'b1 ||
         (data_rd_en_delayed == 1'b1 && s_axis_valid_delayed == 1'b0)) begin
-      fifo_rd_data <= 'h00;
+      fifo_rd_data <= {TOTAL_DATA_WIDTH{1'b0}};
     end else if (data_rd_en_delayed == 1'b1) begin
       fifo_rd_data <= deinterleaved_data;
     end
   end
 
   always @(posedge clk) begin
-    if (data_rd_en_delayed == 1'b1) begin
-      fifo_rd_valid <= s_axis_valid_delayed & ~reset_out;
-      fifo_rd_underflow <= ~(s_axis_valid_delayed & ~reset_out);
+    if (reset == 1'b1) begin
+      fifo_rd_valid <= 1'b0;
+      fifo_rd_underflow <= 1'b0;
+    end else if (data_rd_en_delayed == 1'b1 && reset_out == 1'b0) begin
+      fifo_rd_valid <= s_axis_valid_delayed;
+      fifo_rd_underflow <= ~s_axis_valid_delayed;
     end else begin
       fifo_rd_valid <= 1'b0;
       fifo_rd_underflow <= 1'b0;

--- a/environment/public/code/pack_shell.v (Buggy Starter)
+++ b/solution/gold/code/pack_shell.v (Golden Reference)
@@ -1,38 +1,5 @@
-// ***************************************************************************
-// ***************************************************************************
-// Copyright (C) 2017-2023, 2025-2026 Analog Devices, Inc. All rights reserved.
-//
-// In this HDL repository, there are many different and unique modules, consisting
-// of various HDL (Verilog or VHDL) components. The individual modules are
-// developed independently, and may be accompanied by separate and unique license
-// terms.
-//
-// The user should read each of these license terms, and understand the
-// freedoms and responsibilities that he or she has by using this source/core.
-//
-// This core is distributed in the hope that it will be useful, but WITHOUT ANY
-// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
-// A PARTICULAR PURPOSE.
-//
-// Redistribution and use of source or resulting binaries, with or without modification
-// of this file, are permitted under one of the following two license terms:
-//
-//   1. The GNU General Public License version 2 as published by the
-//      Free Software Foundation, which can be found in the top level directory
-//      of this repository (LICENSE_GPL2), and also online at:
-//      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
-//
-// OR
-//
-//   2. An ADI specific BSD license, which can be found in the top level directory
-//      of this repository (LICENSE_ADIBSD), and also on-line at:
-//      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
-//      This will allow to generate bit files and not release the source code,
-//      as long as it attaches to an ADI device.
-//
-// ***************************************************************************
-// ***************************************************************************
-
+// SPDX-License-Identifier: GPL-2.0-only OR ADIBSD
+// Copyright (C) 2017-2026 Analog Devices, Inc. All rights reserved.
 `timescale 1ns/100ps
 
 module pack_shell #(
@@ -46,7 +13,7 @@
   input clk,
   input reset,
 
-  output reg reset_data = 1'b0,
+  output reg reset_data = 1'b1,
 
   input [NUM_OF_CHANNELS-1:0] enable,
 
@@ -61,22 +28,13 @@
   output [NUM_OF_CHANNELS*SAMPLES_PER_CHANNEL-1:0] out_valid
 );
 
-  // If the number of active channels can be a non-power of two
   localparam NON_POWER_OF_TWO = NUM_OF_CHANNELS > 2;
-
   localparam CHANNEL_DATA_WIDTH = SAMPLES_PER_CHANNEL * SAMPLE_DATA_WIDTH;
-
   localparam TOTAL_DATA_WIDTH = CHANNEL_DATA_WIDTH * NUM_OF_CHANNELS;
   localparam NUM_OF_SAMPLES = NUM_OF_CHANNELS * SAMPLES_PER_CHANNEL;
   localparam LOG2_NUM_OF_SAMPLES = $clog2(NUM_OF_SAMPLES);
-  /*
-   * Number of copies of the routing network control registers. Two copies
-   * measurably help large configurations; four add enough control fanout to
-   * make timing worse.
-   */
   localparam CTRL_REPLICAS = NUM_OF_SAMPLES >= 32 && SAMPLE_DATA_WIDTH % 2 == 0 ? 2 : 1;
 
-  // Function to calculate pipeline latency for a given number of MUX stages.
   function integer calc_pipeline_latency;
     input integer num_stages;
     begin
@@ -89,21 +47,11 @@
     end
   endfunction
 
-  /*
-   * Reset and control signals for the state machine. Data and control have
-   * separate resets since control is pipelined and needs to be taken out of
-   * reset before data so it can compute the control signals for the first data
-   * cycle.
-   */
   reg reset_ctrl = 1'b1;
   reg startup_ctrl = 1'b0;
   reg startup_ctrl2 = 1'b0;
-  reg [NUM_OF_CHANNELS-1:0] enable_int = 'h00;
-
-  /*
-   * Internal copy of the enable signals. This is used to detect changes in the
-   * channel selection and reset the internal state when that happens.
-   */
+  reg [NUM_OF_CHANNELS-1:0] enable_int = {NUM_OF_CHANNELS{1'b0}};
+
   always @(posedge clk) begin
     if (reset == 1'b1) begin
       enable_int <= {NUM_OF_CHANNELS{1'b0}};
@@ -112,19 +60,6 @@
     end
   end
 
-  /*
-   * The internal state is reset whenever the selected channels change. The
-   * control path is pipelined and computed one clock cycle in advance. This
-   * means the control path needs to be taken out of reset one clock cycle
-   * before the data path and a special startup cycles are required to compute
-   * the first sets of control signals.
-   *
-   * In the case where there is only one channel no control signals are needed
-   * and hence no startup cycle. In the case where there are two channels the
-   * control signal pipeline is one cycle, so one startup cycle is required. For
-   * more than two channels the startup pipeline is two channels and two startup
-   * cycles are required.
-   */
   always @(posedge clk) begin
     if (reset == 1'b1 || enable == {NUM_OF_CHANNELS{1'b0}}) begin
       reset_ctrl <= 1'b1;
@@ -139,22 +74,17 @@
     end else begin
       reset_ctrl <= 1'b0;
       reset_data <= NUM_OF_CHANNELS != 1 ? startup_ctrl2 : 1'b0;
-      startup_ctrl2 <= NON_POWER_OF_TWO && PACK == 0 ? reset_ctrl : 1'b0;
+      startup_ctrl2 <= 1'b0;
       startup_ctrl <= reset_ctrl | startup_ctrl2;
     end
   end
 
   generate
     if (NUM_OF_CHANNELS == 1) begin
-      /*
-       * In the one channel case there is not much to do. Nevertheless we should
-       * support it to allow generic designs where the number of channels is
-       * selected programmatically.
-       */
       assign out_data = in_data;
       assign out_sync = 1'b1;
       assign out_valid = {NUM_OF_SAMPLES{1'b1}};
-      assign ready = ce & ~reset_data;
+      assign ready = ~reset_data;
     end else begin
       localparam
         SAMPLE_ADDRESS_WIDTH = NUM_OF_SAMPLES > 512 ? 10 :
@@ -167,16 +97,9 @@
         NUM_OF_SAMPLES > 4 ? 3 :
         NUM_OF_SAMPLES > 2 ? 2 : 1;
 
-      /*
-       * Calculate total pipeline latency from all pack_network stages.
-       * For PACK mode:
-       *   gen_network[0]: SAMPLE_ADDRESS_WIDTH / 2 stages (4:1 MUX)
-       *   gen_network[1]: SAMPLE_ADDRESS_WIDTH % 2 stages (2:1 MUX)
-       * For UNPACK mode:
-       *   i_ext_ctrl_interconnect: 1 stage (only if NON_POWER_OF_TWO)
-       *   gen_network[0]: (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) / 2 stages
-       *   gen_network[1]: (SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) % 2 stages
-       */
+      localparam NUM_PORTS_M = 2**SAMPLE_ADDRESS_WIDTH;
+      localparam NET_DATA_WIDTH = NUM_PORTS_M * SAMPLE_DATA_WIDTH;
+
       localparam
         NETWORK0_STAGES = PACK ? (SAMPLE_ADDRESS_WIDTH / 2) :
         ((SAMPLE_ADDRESS_WIDTH - NON_POWER_OF_TWO) / 2);
@@ -190,29 +113,11 @@
         calc_pipeline_latency(NETWORK1_STAGES) +
         calc_pipeline_latency(EXT_NETWORK_STAGES);
 
-      /*
-       * Internal versions of control signals before pipeline delay.
-       * These are delayed by TOTAL_PIPELINE_LATENCY clock enable cycles to match the
-       * ce-gated data path latency through the pack/unpack network.
-       *
-       * When PIPELINE_STAGES > 0, the data pipeline is ce-gated and control
-       * signal delays must also be ce-gated to maintain alignment.
-       */
       reg ready_int = 1'b0;
       wire out_sync_int;
       wire [NUM_OF_SAMPLES-1:0] out_valid_int;
-
-      /*
-       * Unpack must produce an output word a fixed number of cycles after
-       * each read, whether or not input data was available, so its routing
-       * network is a pure retiming that advances every clock; the consumer
-       * delays its read strobes by TOTAL_PIPELINE_LATENCY clocks. `ready` then
-       * refers to the unpipelined input side and must not be delayed.
-       */
       wire pipe_ce = PACK ? ce : 1'b1;
 
-      // Ce-gated pipeline delay for ready signal
-      // TOTAL_PIPELINE_LATENCY stages of ce-gated delay to match data pipeline
       if (TOTAL_PIPELINE_LATENCY == 0 || PACK == 0) begin: gen_ready_comb
         assign ready = ready_int;
       end else begin: gen_ready_pipe
@@ -230,7 +135,6 @@
         assign ready = ready_sr[TOTAL_PIPELINE_LATENCY-1];
       end
 
-      // Ce-gated pipeline delay for out_sync signal
       if (TOTAL_PIPELINE_LATENCY == 0) begin: gen_sync_comb
         assign out_sync = out_sync_int;
       end else begin: gen_sync_pipe
@@ -248,16 +152,11 @@
         assign out_sync = sync_sr[TOTAL_PIPELINE_LATENCY-1];
       end
 
-      // Ce-gated pipeline delay for out_valid signal
       if (TOTAL_PIPELINE_LATENCY == 0) begin: gen_valid_comb
         assign out_valid = out_valid_int;
       end else begin: gen_valid_pipe
         (* shreg_extract = "no" *) reg [NUM_OF_SAMPLES-1:0] valid_sr [0:TOTAL_PIPELINE_LATENCY-1];
-        integer vi, vj;
-        initial begin
-          for (vi = 0; vi < TOTAL_PIPELINE_LATENCY; vi = vi + 1)
-            valid_sr[vi] = {NUM_OF_SAMPLES{1'b0}};
-        end
+        integer vj;
         always @(posedge clk) begin
           if (reset_ctrl == 1'b1) begin
             for (vj = 0; vj < TOTAL_PIPELINE_LATENCY; vj = vj + 1)
@@ -271,88 +170,34 @@
         assign out_valid = valid_sr[TOTAL_PIPELINE_LATENCY-1];
       end
 
-      /*
-       * `rotate` is used as an offset into the input data vector. When not all
-       * samples are enabled it can take multiple cycles for the input vector to
-       * be consumed. `rotate` points to the first sample in the input vector
-
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE_ADIBSD`](environment/public/code/LICENSE_ADIBSD) *(Read-Only Context)*
- [`environment/public/code/LICENSE_GPL2`](environment/public/code/LICENSE_GPL2) *(Read-Only Context)*
- [`environment/public/code/ad_perfect_shuffle.v`](environment/public/code/ad_perfect_shuffle.v) *(Read-Only Context)*
- [`environment/public/code/pack_ctrl.v`](environment/public/code/pack_ctrl.v) **(Editable)**
- [`environment/public/code/pack_interconnect.v`](environment/public/code/pack_interconnect.v) *(Read-Only Context)*
- [`environment/public/code/pack_network.v`](environment/public/code/pack_network.v) **(Editable)**
- [`environment/public/code/pack_shell.v`](environment/public/code/pack_shell.v) **(Editable)**
- [`environment/public/code/util_cpack2_impl.v`](environment/public/code/util_cpack2_impl.v) **(Editable)**
- [`environment/public/code/util_pipeline_stage.v`](environment/public/code/util_pipeline_stage.v) *(Read-Only Context)*
- [`environment/public/code/util_upack2_impl.v`](environment/public/code/util_upack2_impl.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/LICENSE.Nangate45`](environment/public/lib/LICENSE.Nangate45) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

