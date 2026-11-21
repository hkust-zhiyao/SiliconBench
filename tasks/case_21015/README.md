# `case_21015`: Fix Streaming AXI4 DMA Unaligned 4KB/Max-Burst Splitting, Framing Drain/Flush, Zero-Length Ordering, Sticky Error Priority, and Descriptor Mux Tag Routing

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21015` |
| **Source Silicon Repository** | `alexforencich/verilog-axi` (`repo_40`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/axi_dma_wr.v`](environment/public/code/axi_dma_wr.v), [`code/axi_dma_rd.v`](environment/public/code/axi_dma_rd.v), [`code/axi_dma_desc_mux.v`](environment/public/code/axi_dma_desc_mux.v) (3 files, 1941 LOC) |
| **Public Subsystem Context** | 6 RTL files (2553 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

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

## 3. Build & Verification Instructions (`BUILD.md`)

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

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axi_dma_wr.v (Buggy Starter)
+++ b/solution/gold/code/axi_dma_wr.v (Golden Reference)
@@ -261,12 +261,18 @@
 reg [AXIS_DEST_WIDTH-1:0] status_fifo_dest[(2**STATUS_FIFO_ADDR_WIDTH)-1:0];
 reg [AXIS_USER_WIDTH-1:0] status_fifo_user[(2**STATUS_FIFO_ADDR_WIDTH)-1:0];
 reg status_fifo_last[(2**STATUS_FIFO_ADDR_WIDTH)-1:0];
+reg status_fifo_zero_len[(2**STATUS_FIFO_ADDR_WIDTH)-1:0];
 reg [LEN_WIDTH-1:0] status_fifo_wr_len;
 reg [TAG_WIDTH-1:0] status_fifo_wr_tag;
 reg [AXIS_ID_WIDTH-1:0] status_fifo_wr_id;
 reg [AXIS_DEST_WIDTH-1:0] status_fifo_wr_dest;
 reg [AXIS_USER_WIDTH-1:0] status_fifo_wr_user;
 reg status_fifo_wr_last;
+reg status_fifo_wr_zero_len;
+
+reg drop_meta_pending_reg = 1'b0, drop_meta_pending_next;
+reg [STATUS_FIFO_ADDR_WIDTH+1-1:0] drop_meta_ptr_reg = 0, drop_meta_ptr_next;
+reg drop_meta_we;
 
 reg [STATUS_FIFO_ADDR_WIDTH+1-1:0] active_count_reg = 0;
 reg active_count_av_reg = 1'b1;
@@ -422,11 +428,19 @@
     status_fifo_wr_dest = axis_dest_reg;
     status_fifo_wr_user = axis_user_reg;
     status_fifo_wr_last = 1'b0;
-
-    if (m_axi_bready && m_axi_bvalid && (m_axi_bresp == AXI_RESP_SLVERR || m_axi_bresp == AXI_RESP_DECERR)) begin
-        bresp_next = m_axi_bresp;
-    end else begin
-        bresp_next = bresp_reg;
+    status_fifo_wr_zero_len = 1'b0;
+
+    drop_meta_pending_next = drop_meta_pending_reg;
+    drop_meta_ptr_next = drop_meta_ptr_reg;
+    drop_meta_we = 1'b0;
+
+    bresp_next = bresp_reg;
+    if (m_axi_bready && m_axi_bvalid) begin
+        if (m_axi_bresp == AXI_RESP_DECERR) begin
+            bresp_next = AXI_RESP_DECERR;
+        end else if (m_axi_bresp == AXI_RESP_SLVERR && bresp_reg != AXI_RESP_DECERR) begin
+            bresp_next = AXI_RESP_SLVERR;
+        end
     end
 
     case (state_reg)
@@ -455,24 +469,43 @@
 
             if (s_axis_write_desc_ready && s_axis_write_desc_valid) begin
                 s_axis_write_desc_ready_next = 1'b0;
-                state_next = STATE_START;
+                if (s_axis_write_desc_len == 0) begin
+                    status_fifo_we = 1'b1;
+                    status_fifo_wr_len = {LEN_WIDTH{1'b0}};
+                    status_fifo_wr_tag = s_axis_write_desc_tag;
+                    status_fifo_wr_id = {AXIS_ID_WIDTH{1'b0}};
+                    status_fifo_wr_dest = {AXIS_DEST_WIDTH{1'b0}};
+                    status_fifo_wr_user = {AXIS_USER_WIDTH{1'b0}};
+                    status_fifo_wr_last = 1'b1;
+                    status_fifo_wr_zero_len = 1'b1;
+                    inc_active = 1'b1;
+                    state_next = STATE_IDLE;
+                end else begin
+                    state_next = STATE_START;
+                end
             end else begin
                 state_next = STATE_IDLE;
             end
         end
         STATE_START: begin
             // start state - initiate new AXI transfer
-            if (op_word_count_reg <= AXI_MAX_BURST_SIZE || AXI_MAX_BURST_SIZE >= 4096) begin
-                if (((addr_reg & 12'hfff) + (op_word_count_reg & 12'hfff)) >> 12 != 0) begin
+            if (op_word_count_reg <= AXI_MAX_BURST_SIZE - (ENABLE_UNALIGNED ? (addr_reg & OFFSET_MASK) : 0) || AXI_MAX_BURST_SIZE >= 4096) begin
+                // packet smaller than max burst size
+                if (((addr_reg & 12'hfff) + (op_word_count_reg & 12'hfff)) >> 12 != 0 || op_word_count_reg >> 12 != 0) begin
+                    // crosses 4k boundary
                     tr_word_count_next = 13'h1000 - (addr_reg & 12'hfff);
                 end else begin
+                    // does not cross 4k boundary
                     tr_word_count_next = op_word_count_reg;
                 end
             end else begin
-                if (((addr_reg & 12'hfff) + AXI_MAX_BURST_SIZE) >> 12 != 0) begin
+                // packet larger than max burst size
+                if (((addr_reg & 12'hfff) + AXI_MAX_BURST_SIZE - (ENABLE_UNALIGNED ? (addr_reg & OFFSET_MASK) : 0)) >> 12 != 0) begin
+                    // crosses 4k boundary
                     tr_word_count_next = 13'h1000 - (addr_reg & 12'hfff);
                 end else begin
-                    tr_word_count_next = AXI_MAX_BURST_SIZE;
+                    // does not cross 4k boundary
+                    tr_word_count_next = AXI_MAX_BURST_SIZE - (ENABLE_UNALIGNED ? (addr_reg & OFFSET_MASK) : 0);
                 end
             end
 
@@ -485,10 +518,10 @@
             end
             output_last_cycle_next = output_cycle_count_next == 0;
             last_transfer_next = tr_word_count_next == op_word_count_reg;
-            input_active_next = 1'b1;
+            input_active_next = !save_axis_tlast_reg;
 
             if (ENABLE_UNALIGNED) begin
-                if (!first_cycle_reg && last_transfer_next) begin
+                if (!first_cycle_reg && last_transfer_next && !save_axis_tlast_reg) begin
                     if (offset_reg >= last_cycle_offset_reg && last_cycle_offset_reg > 0) begin
                         // last cycle will be served by stored partial cycle
                         input_active_next = input_cycle_count_next > 0;
@@ -506,7 +539,7 @@
                     addr_next = addr_reg + tr_word_count_next;
                     op_word_count_next = op_word_count_reg - tr_word_count_next;
 
-                    s_axis_write_data_tready_next = m_axi_wready_int && input_active_next;
+                    s_axis_write_data_tready_next = m_axi_wready_int && ((AXIS_LAST_ENABLE && last_transfer_next) || input_active_next) && !save_axis_tlast_reg && shift_axis_input_tready;
 
                     inc_active = 1'b1;
 
@@ -519,9 +552,9 @@
             end
         end
         STATE_WRITE: begin
-            s_axis_write_data_tready_next = m_axi_wready_int && (last_transfer_reg || input_active_reg) && shift_axis_input_tready;
-
-            if ((s_axis_write_data_tready && shift_axis_tvalid) || (!input_active_reg && !last_transfer_reg) || !shift_axis_input_tready) begin
+            s_axis_write_data_tready_next = m_axi_wready_int && ((AXIS_LAST_ENABLE && last_transfer_reg) || input_active_reg) && !save_axis_tlast_reg && shift_axis_input_tready;
+
+            if ((s_axis_write_data_tready && shift_axis_tvalid) || (m_axi_wready_int && ((!input_active_reg && !(AXIS_LAST_ENABLE && last_transfer_reg)) || !shift_axis_input_tready))) begin
                 if (s_axis_write_data_tready && s_axis_write_data_tvalid) begin
                     transfer_in_save = 1'b1;
 
@@ -674,9 +707,16 @@
                         status_fifo_wr_last = 1'b1;
 
                         if (AXIS_LAST_ENABLE) begin
-                            // not at the end of packet; drop remainder
-                            s_axis_write_data_tready_next = shift_axis_input_tready;
-                            state_next = STATE_DROP_DATA;
+                            if (save_axis_tlast_reg || (s_axis_write_data_tready && s_axis_write_data_tvalid && s_axis_write_data_tlast)) begin
+                                s_axis_write_data_tready_next = 1'b0;
+                                s_axis_write_desc_ready_next = enable && active_count_av_reg;
+                                state_next = STATE_IDLE;
+                            end else begin
+                                drop_meta_pending_next = 1'b1;
+                                drop_meta_ptr_next = status_fifo_wr_ptr_reg;
+                                s_axis_write_data_tready_next = 1'b1;
+                                state_next = STATE_DROP_DATA;
+                            end
                         end else begin
                             // no framing; return to idle
                             s_axis_write_data_tready_next = 1'b0;
@@ -685,7 +725,7 @@
                         end
                     end
                 end else begin
-                    s_axis_write_data_tready_next = m_axi_wready_int && (last_transfer_reg || input_active_next) && shift_axis_input_tready;
+                    s_axis_write_data_tready_next = m_axi_wready_int && ((AXIS_LAST_ENABLE && last_transfer_reg) || input_active_next) && !save_axis_tlast_reg && shift_axis_input_tready;
                     state_next = STATE_WRITE;
                 end
             end else begin
@@ -694,6 +734,7 @@
         end
         STATE_FINISH_BURST: begin
             // finish current AXI burst
+            flush_save = 1'b1;
 
             if (m_axi_wready_int) begin
                 // update counters
@@ -725,15 +766,17 @@
             end
         end
         STATE_DROP_DATA: begin
-            // drop excess AXI stream data
-            s_axis_write_data_tready_next = shift_axis_input_tready;
-
-            if (shift_axis_tvalid) begin
-                if (s_axis_write_data_tready && s_axis_write_data_tvalid) begin
-                    transfer_in_save = 1'b1;
-                end
-
-                if (shift_axis_tlast) begin
+            s_axis_write_data_tready_next = 1'b1;
+
+            if (s_axis_write_data_tready && s_axis_write_data_tvalid) begin
+                axis_id_next = s_axis_write_data_tid;
+                axis_dest_next = s_axis_write_data_tdest;
+                axis_user_next = s_axis_write_data_tuser;
+
+                if (s_axis_write_data_tlast) begin
+                    drop_meta_we = 1'b1;
+                    drop_meta_pending_next = 1'b0;
+                    flush_save = 1'b1;
                     s_axis_write_data_tready_next = 1'b0;
                     s_axis_write_desc_ready_next = enable && active_count_av_reg;
                     state_next = STATE_IDLE;
@@ -747,18 +790,29 @@
     endcase
 
     if (status_fifo_rd_ptr_reg != status_fifo_wr_ptr_reg) begin
-        // status FIFO not empty
-        if (m_axi_bready && m_axi_bvalid) begin
-            // got write completion, pop and return status
+        if (status_fifo_zero_len[status_fifo_rd_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]]) begin
+            m_axis_write_desc_status_len_next = {LEN_WIDTH{1'b0}};
+            m_axis_write_desc_status_tag_next = status_fifo_tag[status_fifo_rd_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]];
+            m_axis_write_desc_status_id_next = {AXIS_ID_WIDTH{1'b0}};
+            m_axis_write_desc_status_dest_next = {AXIS_DEST_WIDTH{1'b0}};
+            m_axis_write_desc_status_user_next = {AXIS_USER_WIDTH{1'b0}};
+            m_axis_write_desc_status_error_next = DMA_ERROR_NONE;
+            m_axis_write_desc_status_valid_next = 1'b1;
+            status_fifo_rd_ptr_next = status_fifo_rd_ptr_reg + 1;
+            m_axi_bready_next = 1'b0;
+            dec_active = 1'b1;
+        end else if (drop_meta_pending_reg && (status_fifo_rd_ptr_reg == drop_meta_ptr_reg)) begin
+            m_axi_bready_next = 1'b0;
+        end else if (m_axi_bready && m_axi_bvalid) begin
             m_axis_write_desc_status_len_next = status_fifo_len[status_fifo_rd_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]];
             m_axis_write_desc_status_tag_next = status_fifo_tag[status_fifo_rd_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]];
             m_axis_write_desc_status_id_next = status_fifo_id[status_fifo_rd_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]];
             m_axis_write_desc_status_dest_next = status_fifo_dest[status_fifo_rd_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]];
             m_axis_write_desc_status_user_next = status_fifo_user[status_fifo_rd_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]];
-            if (bresp_next == AXI_RESP_SLVERR) begin
+            if (bresp_next == AXI_RESP_DECERR) begin
+                m_axis_write_desc_status_error_next = DMA_ERROR_AXI_WR_DECERR;
+            end else if (bresp_next == AXI_RESP_SLVERR) begin
                 m_axis_write_desc_status_error_next = DMA_ERROR_AXI_WR_SLVERR;
-            end else if (bresp_next == AXI_RESP_DECERR) begin
-                m_axis_write_desc_status_error_next = DMA_ERROR_AXI_WR_DECERR;
             end else begin
                 m_axis_write_desc_status_error_next = DMA_ERROR_NONE;
             end
@@ -772,7 +826,6 @@
 
             dec_active = 1'b1;
         end else begin
-            // wait for write completion
             m_axi_bready_next = 1'b1;
         end
     end
@@ -832,6 +885,9 @@
         shift_axis_extra_cycle_reg <= s_axis_write_data_tlast & ((s_axis_write_data_tkeep >> (AXIS_KEEP_WIDTH_INT-offset_reg)) != 0);
     end
 
+    drop_meta_pending_reg <= drop_meta_pending_next;
+    drop_meta_ptr_reg <= drop_meta_ptr_next;
+
     if (status_fifo_we) begin
         status_fifo_len[status_fifo_wr_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= status_fifo_wr_len;
         status_fifo_tag[status_fifo_wr_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= status_fifo_wr_tag;
@@ -839,7 +895,12 @@
         status_fifo_dest[status_fifo_wr_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= status_fifo_wr_dest;
         status_fifo_user[status_fifo_wr_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= status_fifo_wr_user;
         status_fifo_last[status_fifo_wr_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= status_fifo_wr_last;
+        status_fifo_zero_len[status_fifo_wr_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= status_fifo_wr_zero_len;
         status_fifo_wr_ptr_reg <= status_fifo_wr_ptr_reg + 1;
+    end else if (drop_meta_we) begin
+        status_fifo_id[drop_meta_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= s_axis_write_data_tid;
+        status_fifo_dest[drop_meta_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= s_axis_write_data_tdest;
+        status_fifo_user[drop_meta_ptr_reg[STATUS_FIFO_ADDR_WIDTH-1:0]] <= s_axis_write_data_tuser;
     end
     status_fifo_rd_ptr_reg <= status_fifo_rd_ptr_next;
 
@@ -869,6 +930,9 @@
         save_axis_tlast_reg <= 1'b0;
         shift_axis_extra_cycle_reg <= 1'b0;
 
+        drop_meta_pending_reg <= 1'b0;
+        drop_meta_ptr_reg <= 0;
+
         status_fifo_wr_ptr_reg <= 0;
         status_fifo_rd_ptr_reg <= 0;
 

--- a/environment/public/code/axi_dma_rd.v (Buggy Starter)
+++ b/solution/gold/code/axi_dma_rd.v (Golden Reference)
@@ -236,6 +236,7 @@
 reg [AXIS_ID_WIDTH-1:0] axis_cmd_axis_id_reg = {AXIS_ID_WIDTH{1'b0}}, axis_cmd_axis_id_next;
 reg [AXIS_DEST_WIDTH-1:0] axis_cmd_axis_dest_reg = {AXIS_DEST_WIDTH{1'b0}}, axis_cmd_axis_dest_next;
 reg [AXIS_USER_WIDTH-1:0] axis_cmd_axis_user_reg = {AXIS_USER_WIDTH{1'b0}}, axis_cmd_axis_user_next;
+reg axis_cmd_zero_len_reg = 1'b0, axis_cmd_zero_len_next;
 reg axis_cmd_valid_reg = 1'b0, axis_cmd_valid_next;
 
 reg [OFFSET_WIDTH-1:0] offset_reg = {OFFSET_WIDTH{1'b0}}, offset_next;
@@ -318,6 +319,7 @@
     axis_cmd_axis_id_next = axis_cmd_axis_id_reg;
     axis_cmd_axis_dest_next = axis_cmd_axis_dest_reg;
     axis_cmd_axis_user_next = axis_cmd_axis_user_reg;
+    axis_cmd_zero_len_next = axis_cmd_zero_len_reg;
     axis_cmd_valid_next = axis_cmd_valid_reg && !axis_cmd_ready;
 
     case (axi_state_reg)
@@ -326,35 +328,41 @@
             s_axis_read_desc_ready_next = !axis_cmd_valid_reg && enable;
 
             if (s_axis_read_desc_ready && s_axis_read_desc_valid) begin
-                if (ENABLE_UNALIGNED) begin
-                    addr_next = s_axis_read_desc_addr;
-                    axis_cmd_offset_next = AXI_STRB_WIDTH > 1 ? AXI_STRB_WIDTH - (s_axis_read_desc_addr & OFFSET_MASK) : 0;
-                    axis_cmd_bubble_cycle_next = axis_cmd_offset_next > 0;
-                    axis_cmd_last_cycle_offset_next = s_axis_read_desc_len & OFFSET_MASK;
-                end else begin
-                    addr_next = s_axis_read_desc_addr & ADDR_MASK;
-                    axis_cmd_offset_next = 0;
-                    axis_cmd_bubble_cycle_next = 1'b0;
-                    axis_cmd_last_cycle_offset_next = s_axis_read_desc_len & OFFSET_MASK;
-                end
                 axis_cmd_tag_next = s_axis_read_desc_tag;
-                op_word_count_next = s_axis_read_desc_len;
-
                 axis_cmd_axis_id_next = s_axis_read_desc_id;
                 axis_cmd_axis_dest_next = s_axis_read_desc_dest;
                 axis_cmd_axis_user_next = s_axis_read_desc_user;
-
-                if (ENABLE_UNALIGNED) begin
-                    axis_cmd_input_cycle_count_next = (op_word_count_next + (s_axis_read_desc_addr & OFFSET_MASK) - 1) >> AXI_BURST_SIZE;
+                axis_cmd_valid_next = 1'b1;
+                s_axis_read_desc_ready_next = 1'b0;
+
+                if (s_axis_read_desc_len == 0) begin
+                    axis_cmd_zero_len_next = 1'b1;
+                    op_word_count_next = 0;
+                    axi_state_next = AXI_STATE_IDLE;
                 end else begin
-                    axis_cmd_input_cycle_count_next = (op_word_count_next - 1) >> AXI_BURST_SIZE;
+                    axis_cmd_zero_len_next = 1'b0;
+                    if (ENABLE_UNALIGNED) begin
+                        addr_next = s_axis_read_desc_addr;
+                        axis_cmd_offset_next = AXI_STRB_WIDTH > 1 ? AXI_STRB_WIDTH - (s_axis_read_desc_addr & OFFSET_MASK) : 0;
+                        axis_cmd_bubble_cycle_next = axis_cmd_offset_next > 0;
+                        axis_cmd_last_cycle_offset_next = s_axis_read_desc_len & OFFSET_MASK;
+                    end else begin
+                        addr_next = s_axis_read_desc_addr & ADDR_MASK;
+                        axis_cmd_offset_next = 0;
+                        axis_cmd_bubble_cycle_next = 1'b0;
+                        axis_cmd_last_cycle_offset_next = s_axis_read_desc_len & OFFSET_MASK;
+                    end
+                    op_word_count_next = s_axis_read_desc_len;
+
+                    if (ENABLE_UNALIGNED) begin
+                        axis_cmd_input_cycle_count_next = (op_word_count_next + (s_axis_read_desc_addr & OFFSET_MASK) - 1) >> AXI_BURST_SIZE;
+                    end else begin
+                        axis_cmd_input_cycle_count_next = (op_word_count_next - 1) >> AXI_BURST_SIZE;
+                    end
+                    axis_cmd_output_cycle_count_next = (op_word_count_next - 1) >> AXI_BURST_SIZE;
+
+                    axi_state_next = AXI_STATE_START;
                 end
-                axis_cmd_output_cycle_count_next = (op_word_count_next - 1) >> AXI_BURST_SIZE;
-
-                axis_cmd_valid_next = 1'b1;
-
-                s_axis_read_desc_ready_next = 1'b0;
-                axi_state_next = AXI_STATE_START;
             end else begin
                 axi_state_next = AXI_STATE_IDLE;
             end
@@ -362,17 +370,23 @@
         AXI_STATE_START: begin
             // start state - initiate new AXI transfer
             if (!m_axi_arvalid) begin
-                if (op_word_count_reg <= AXI_MAX_BURST_SIZE || AXI_MAX_BURST_SIZE >= 4096) begin
-                    if (((addr_reg & 12'hfff) + (op_word_count_reg & 12'hfff)) >> 12 != 0) begin
+                if (op_word_count_reg <= AXI_MAX_BURST_SIZE - (ENABLE_UNALIGNED ? (addr_reg & OFFSET_MASK) : 0) || AXI_MAX_BURST_SIZE >= 4096) begin
+                    // packet smaller than max burst size
+                    if (((addr_reg & 12'hfff) + (op_word_count_reg & 12'hfff)) >> 12 != 0 || op_word_count_reg >> 12 != 0) begin
+                        // crosses 4k boundary
                         tr_word_count_next = 13'h1000 - (addr_reg & 12'hfff);
                     end else begin
+                        // does not cross 4k boundary
                         tr_word_count_next = op_word_count_reg;
                     end
                 end else begin
-                    if (((addr_reg & 12'hfff) + AXI_MAX_BURST_SIZE) >> 12 != 0) begin
+                    // packet larger than max burst size
+                    if (((addr_reg & 12'hfff) + AXI_MAX_BURST_SIZE - (ENABLE_UNALIGNED ? (addr_reg & OFFSET_MASK) : 0)) >> 12 != 0) begin
+                        // crosses 4k boundary
                         tr_word_count_next = 13'h1000 - (addr_reg & 12'hfff);
                     end else begin
-                        tr_word_count_next = AXI_MAX_BURST_SIZE;
+                        // does not cross 4k boundary
+                        tr_word_count_next = AXI_MAX_BURST_SIZE - (ENABLE_UNALIGNED ? (addr_reg & OFFSET_MASK) : 0);
                     end
                 end
 
@@ -435,10 +449,13 @@
     axis_dest_next = axis_dest_reg;
     axis_user_next = axis_user_reg;
 
-    if (m_axi_rready && m_axi_rvalid && (m_axi_rresp == AXI_RESP_SLVERR || m_axi_rresp == AXI_RESP_DECERR)) begin
-        rresp_next = m_axi_rresp;
-    end else begin
-        rresp_next = rresp_reg;
+    rresp_next = rresp_reg;
+    if (m_axi_rready && m_axi_rvalid) begin
+        if (m_axi_rresp == AXI_RESP_DECERR) begin
+            rresp_next = AXI_RESP_DECERR;
+        end else if (m_axi_rresp == AXI_RESP_SLVERR && rresp_reg != AXI_RESP_DECERR) begin
+            rresp_next = AXI_RESP_SLVERR;
+        end
     end
 
     case (axis_state_reg)
@@ -468,8 +485,16 @@
 
             if (axis_cmd_valid_reg) begin
                 axis_cmd_ready = 1'b1;
-                m_axi_rready_next = m_axis_read_data_tready_int;
-                axis_state_next = AXIS_STATE_READ;
+                if (axis_cmd_zero_len_reg) begin
+                    m_axis_read_desc_status_tag_next = axis_cmd_tag_reg;
+                    m_axis_read_desc_status_error_next = DMA_ERROR_NONE;
+                    m_axis_read_desc_status_valid_next = 1'b1;
+                    m_axi_rready_next = 1'b0;
+                    axis_state_next = AXIS_STATE_IDLE;
+                end else begin
+                    m_axi_rready_next = m_axis_read_data_tready_int;
+                    axis_state_next = AXIS_STATE_READ;
+                end
             end
         end
         AXIS_STATE_READ: begin
@@ -571,6 +596,7 @@
     axis_cmd_axis_id_reg <= axis_cmd_axis_id_next;
     axis_cmd_axis_dest_reg <= axis_cmd_axis_dest_next;
     axis_cmd_axis_user_reg <= axis_cmd_axis_user_next;
+    axis_cmd_zero_len_reg <= axis_cmd_zero_len_next;
     axis_cmd_valid_reg <= axis_cmd_valid_next;
 
     offset_reg <= offset_next;
@@ -597,6 +623,7 @@
         axi_state_reg <= AXI_STATE_IDLE;
         axis_state_reg <= AXIS_STATE_IDLE;
 
+        axis_cmd_zero_len_reg <= 1'b0;
         axis_cmd_valid_reg <= 1'b0;
 
         s_axis_read_desc_ready_reg <= 1'b0;

--- a/environment/public/code/axi_dma_desc_mux.v (Buggy Starter)
+++ b/solution/gold/code/axi_dma_desc_mux.v (Golden Reference)
@@ -33,32 +33,18 @@
  */
 module axi_dma_desc_mux #
 (
-    // Number of ports
     parameter PORTS = 2,
-    // AXI address width
     parameter AXI_ADDR_WIDTH = 16,
-    // Propagate AXI stream tid signal
     parameter AXIS_ID_ENABLE = 0,
-    // AXI stream tid signal width
     parameter AXIS_ID_WIDTH = 8,
-    // Propagate AXI stream tdest signal
     parameter AXIS_DEST_ENABLE = 0,
-    // AXI stream tdest signal width
     parameter AXIS_DEST_WIDTH = 8,
-    // Propagate AXI stream tuser signal
     parameter AXIS_USER_ENABLE = 1,
-    // AXI stream tuser signal width
     parameter AXIS_USER_WIDTH = 1,
-    // Length field width
     parameter LEN_WIDTH = 20,
-    // Input tag field width
     parameter S_TAG_WIDTH = 8,
-    // Output tag field width (towards CDMA module)
-    // Additional bits required for response routing
     parameter M_TAG_WIDTH = S_TAG_WIDTH+$clog2(PORTS),
-    // select round robin arbitration
     parameter ARB_TYPE_ROUND_ROBIN = 1,
-    // LSB priority selection
     parameter ARB_LSB_HIGH_PRIORITY = 1
 )
 (
@@ -112,24 +98,22 @@
     output wire [PORTS-1:0]                 m_axis_desc_status_valid
 );
 
-parameter CL_PORTS = $clog2(PORTS);
-
-// check configuration
+localparam CL_PORTS = PORTS > 1 ? $clog2(PORTS) : 1;
+localparam TAG_PORT_BITS = PORTS > 1 ? $clog2(PORTS) : 0;
+
 initial begin
-    if (M_TAG_WIDTH < S_TAG_WIDTH+$clog2(PORTS)) begin
+    if (M_TAG_WIDTH < S_TAG_WIDTH + TAG_PORT_BITS) begin
         $error("Error: M_TAG_WIDTH must be at least $clog2(PORTS) larger than S_TAG_WIDTH (instance %m)");
         $finish;
     end
 end
 
-// descriptor mux
 wire [PORTS-1:0] request;
 wire [PORTS-1:0] acknowledge;
 wire [PORTS-1:0] grant;
 wire grant_valid;
 wire [CL_PORTS-1:0] grant_encoded;
 
-// internal datapath
 reg  [AXI_ADDR_WIDTH-1:0]  m_axis_desc_addr_int;
 reg  [LEN_WIDTH-1:0]       m_axis_desc_len_int;
 reg  [M_TAG_WIDTH-1:0]     m_axis_desc_tag_int;
@@ -140,84 +124,102 @@
 reg                        m_axis_desc_ready_int_reg = 1'b0;
 wire                       m_axis_desc_ready_int_early;
 
-assign s_axis_desc_ready = (m_axis_desc_ready_int_reg && grant_valid) << grant_encoded;
-
-// mux for incoming packet
-wire [AXI_ADDR_WIDTH-1:0]  current_s_desc_addr   = s_axis_desc_addr[grant_encoded*AXI_ADDR_WIDTH +: AXI_ADDR_WIDTH];
-wire [LEN_WIDTH-1:0]       current_s_desc_len    = s_axis_desc_len[grant_encoded*LEN_WIDTH +: LEN_WIDTH];
-wire [S_TAG_WIDTH-1:0]     current_s_desc_tag    = s_axis_desc_tag[grant_encoded*S_TAG_WIDTH +: S_TAG_WIDTH];
-wire [AXIS_ID_WIDTH-1:0]   current_s_desc_id     = s_axis_desc_id[grant_encoded*AXIS_ID_WIDTH +: AXIS_ID_WIDTH];
-wire [AXIS_DEST_WIDTH-1:0] current_s_desc_dest   = s_axis_desc_dest[grant_encoded*AXIS_DEST_WIDTH +
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/COPYING`](environment/public/code/COPYING) *(Read-Only Context)*
- [`environment/public/code/arbiter.v`](environment/public/code/arbiter.v) *(Read-Only Context)*
- [`environment/public/code/axi_dma.v`](environment/public/code/axi_dma.v) *(Read-Only Context)*
- [`environment/public/code/axi_dma_desc_mux.v`](environment/public/code/axi_dma_desc_mux.v) **(Editable)**
- [`environment/public/code/axi_dma_rd.v`](environment/public/code/axi_dma_rd.v) **(Editable)**
- [`environment/public/code/axi_dma_wr.v`](environment/public/code/axi_dma_wr.v) **(Editable)**
- [`environment/public/code/priority_encoder.v`](environment/public/code/priority_encoder.v) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

