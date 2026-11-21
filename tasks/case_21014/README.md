# `case_21014`: AXI4-Stream COBS Framing & Frame-Length Adjuster Malformed-Frame Recovery, Status Backpressure, and Synthesis Parity

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21014` |
| **Source Silicon Repository** | `corundum/corundum` (`repo_39`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/axis_cobs_encode.v`](environment/public/code/axis_cobs_encode.v), [`code/axis_cobs_decode.v`](environment/public/code/axis_cobs_decode.v), [`code/axis_frame_length_adjust.v`](environment/public/code/axis_frame_length_adjust.v) (3 files, 1460 LOC) |
| **Public Subsystem Context** | 4 RTL files (2022 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# AXI4-Stream COBS Framing & Frame-Length Adjuster Malformed-Frame Recovery, Status Backpressure, and Synthesis Parity

An AXI4-Stream framing subsystem comprises `axis_cobs_encode`, `axis_cobs_decode`, and `axis_frame_length_adjust` (backed by read-only `axis_fifo`). Across normal 1-byte to multi-block frames, exact 254-byte COBS block boundaries, malformed/truncated frames, independent `m_axis_tready` and `status_ready` backpressure, and post-synthesis gate-level simulation, the pipeline exhibits duplicate block codes, swallowed frame boundaries, status overwrite under stall, and RTL-vs-gate-level mismatches:

1. **COBS Encoder Exact 254-Byte Tail & Error Framing (`axis_cobs_encode`, `APPEND_ZERO` in `{0, 1}`)**:
   - Encode input frames into COBS segments of up to 254 non-zero bytes (`0xFF` block code). When the final byte of an input frame (`s_axis_tlast == 1'b1`, `s_axis_tuser == 1'b0`) lands on the 254th non-zero byte of a segment, emit a single `0xFF` code byte for that segment and close the frame (`0x00` delimiter beat if `APPEND_ZERO != 0`, or `m_axis_tlast = 1'b1` on the 254th data byte if `APPEND_ZERO == 0`) without pushing a duplicate code byte.
   - When an input frame ends with `s_axis_tlast && s_axis_tuser`, emit the current segment code followed by an escape sequence (`0x02` with `m_axis_tlast = 1'b1, m_axis_tuser = 1'b1` when `APPEND_ZERO == 0`; `0x02` with `m_axis_tuser = 1'b0` followed by `0x00` with `m_axis_tlast = 1'b1, m_axis_tuser = 1'b1` when `APPEND_ZERO != 0`), keeping `m_axis_tuser == 1'b0` on all non-final beats.

2. **COBS Decoder Malformed/Truncated Frame Recovery (`axis_cobs_decode`)**:
   - Skip idle leading `0x00` bytes (`!(s_axis_tlast && s_axis_tuser)`), decode valid segments (suppressing the implicit zero after `0xFF` blocks), and close valid frames cleanly on an in-band `0x00` delimiter (forwarding `s_axis_tuser` when closing a buffered byte) or on `s_axis_tlast` at a valid frame boundary.
   - Without dropping or corrupting a still-draining final byte of the preceding frame, emit a single-beat error frame (`m_axis_tdata = 8'd0, m_axis_tlast = 1'b1, m_axis_tuser = 1'b1`) on a 1-byte truncated start frame (`s_axis_tdata != 8'd0 && s_axis_tlast` or `s_axis_tdata == 8'd0 && s_axis_tlast && s_axis_tuser` in idle), on `[0x01, 0x00]` / post-`0xFF` zero-offset escapes with no buffered output byte, and terminate mid-frame immediately with `m_axis_tlast = 1'b1, m_axis_tuser = 1'b1` (re-synchronizing to idle) upon an unexpected `0x00` data byte, premature `s_axis_tlast` mid-segment, `s_axis_tlast` with `s_axis_tuser == 1'b1`, or a truncated `0x01` tail immediately following a `0xFF` suppressed-zero block.

3. **Frame-Length Adjuster Masking, Latched Bounds, & Lossless `status_*` Handshake (`axis_frame_length_adjust`)**:
   - Zero `m_axis_tdata` byte lanes wherever effective `s_axis_tkeep` or output `m_axis_tkeep` is `0` (across both padding up to `length_min` and truncation down to `length_max`), and drive disabled `m_axis_tid`/`m_axis_tdest`/`m_axis_tuser` outputs to zero (`m_axis_tkeep` all-ones when `KEEP_ENABLE == 0`).
   - Latch `length_min` and `length_max` on the first accepted beat of each frame so mid-frame port changes only affect subsequent frames. Preserve the frame's `tid`/`tdest` on padded and truncated tail beats, hold `m_axis_tuser = 0` on intermediate pad beats while placing the input tail `tuser` on the final padded beat, and set `m_axis_tuser` on a multi-beat truncated frame's final beat to the bitwise OR of `s_axis_tuser` at the truncation-boundary beat and `s_axis_tuser` at `s_axis_tlast`.
   - Maintain AXI-Stream handshake stability on both `m_axis_*` and `status_*` (`status_valid` / `status_ready`): `status_ready` backpressure must never drop or overwrite per-frame status reports (`status_frame_pad`, `status_frame_truncate`, `status_frame_length`, `status_frame_original_length`).

4. **Synthesis & Gate-Level Netlist Parity**:
   - All three modules must synthesize cleanly with zero inferred latches and zero combinational loops, and match post-synthesis gate-level simulation cycle-for-cycle after synchronous `rst`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The AXI4-Stream COBS framing and frame-length adjuster RTL in `code/` comes from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause License).

Editable files:
- `code/axis_cobs_encode.v`
- `code/axis_cobs_decode.v`
- `code/axis_frame_length_adjust.v`

Read-only support files (must remain unmodified):
- `code/axis_fifo.v`
- `code/LICENSE`

For quick local elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/cobs_chk.vvp code/*.v

# Verilator lint/elaboration check
verilator --lint-only -Wno-fatal -GDATA_WIDTH=64 --top-module axis_frame_length_adjust code/axis_frame_length_adjust.v

# Yosys elaboration and latch-free synthesis check
yosys -p "read_verilog code/*.v; chparam -set DATA_WIDTH 64 axis_frame_length_adjust; hierarchy -check -top axis_frame_length_adjust; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axis_cobs_encode.v (Buggy Starter)
+++ b/solution/gold/code/axis_cobs_encode.v (Golden Reference)
@@ -128,12 +128,12 @@
     .rst(rst),
     // AXI input
     .s_axis_tdata(code_fifo_in_tdata),
-    .s_axis_tkeep(0),
+    .s_axis_tkeep(1'b0),
     .s_axis_tvalid(code_fifo_in_tvalid),
     .s_axis_tready(code_fifo_in_tready),
     .s_axis_tlast(code_fifo_in_tlast),
-    .s_axis_tid(0),
-    .s_axis_tdest(0),
+    .s_axis_tid(8'd0),
+    .s_axis_tdest(8'd0),
     .s_axis_tuser(code_fifo_in_tuser),
     // AXI output
     .m_axis_tdata(code_fifo_out_tdata),
@@ -144,7 +144,12 @@
     .m_axis_tid(),
     .m_axis_tdest(),
     .m_axis_tuser(code_fifo_out_tuser),
+    // Pause
+    .pause_req(1'b0),
+    .pause_ack(),
     // Status
+    .status_depth(),
+    .status_depth_commit(),
     .status_overflow(),
     .status_bad_frame(),
     .status_good_frame()
@@ -165,13 +170,13 @@
     .rst(rst),
     // AXI input
     .s_axis_tdata(data_fifo_in_tdata),
-    .s_axis_tkeep(0),
+    .s_axis_tkeep(1'b0),
     .s_axis_tvalid(data_fifo_in_tvalid),
     .s_axis_tready(data_fifo_in_tready),
     .s_axis_tlast(data_fifo_in_tlast),
-    .s_axis_tid(0),
-    .s_axis_tdest(0),
-    .s_axis_tuser(0),
+    .s_axis_tid(8'd0),
+    .s_axis_tdest(8'd0),
+    .s_axis_tuser(1'b0),
     // AXI output
     .m_axis_tdata(data_fifo_out_tdata),
     .m_axis_tkeep(),
@@ -181,7 +186,12 @@
     .m_axis_tid(),
     .m_axis_tdest(),
     .m_axis_tuser(),
+    // Pause
+    .pause_req(1'b0),
+    .pause_ack(),
     // Status
+    .status_depth(),
+    .status_depth_commit(),
     .status_overflow(),
     .status_bad_frame(),
     .status_good_frame()
@@ -273,20 +283,14 @@
                         input_state_next = INPUT_STATE_IDLE;
                     end
                 end else begin
-                    // got something other than a zero, so store it and increment the segment counter
-                    input_count_next = input_count_reg+1;
+                    // got something other than a zero, so store it and advance the segment counter
                     data_fifo_in_tdata = s_axis_tdata;
                     data_fifo_in_tvalid = 1'b1;
-                    if (input_count_reg == 8'd254) begin
-                        // 254 bytes in frame, so dump and reset counter
-                        code_fifo_in_tdata = input_count_reg+1;
+                    if (s_axis_tlast) begin
+                        // last byte (including exact 254-byte segment end -> code 255)
+                        code_fifo_in_tdata = input_count_reg + 8'd1;
                         code_fifo_in_tvalid = 1'b1;
                         input_count_next = 8'd1;
-                    end
-                    if (s_axis_tlast) begin
-                        // last byte, so store the code and close out the frame
-                        code_fifo_in_tdata = input_count_reg+1;
-                        code_fifo_in_tvalid = 1'b1;
                         if (APPEND_ZERO) begin
                             // zero frame mode, need to add a zero code to end the frame
                             input_state_next = INPUT_STATE_APPEND_ZERO;
@@ -295,8 +299,15 @@
                             data_fifo_in_tlast = 1'b1;
                             input_state_next = INPUT_STATE_IDLE;
                         end
+                    end else if (input_count_reg == 8'd254) begin
+                        // 254 bytes in segment, dump 0xFF block code and reset counter
+                        code_fifo_in_tdata = 8'd255;
+                        code_fifo_in_tvalid = 1'b1;
+                        input_count_next = 8'd1;
+                        input_state_next = INPUT_STATE_SEGMENT;
                     end else begin
                         // await more segment data
+                        input_count_next = input_count_reg + 8'd1;
                         input_state_next = INPUT_STATE_SEGMENT;
                     end
                 end
@@ -372,7 +383,7 @@
                 m_axis_tdata_int = code_fifo_out_tdata;
                 m_axis_tlast_int = code_fifo_out_tlast;
                 m_axis_tuser_int = code_fifo_out_tuser && code_fifo_out_tlast;
-                output_count_next = code_fifo_out_tdata-1;
+                output_count_next = code_fifo_out_tdata - 8'd1;
                 m_axis_tvalid_int = 1'b1;
                 code_fifo_out_tready = 1'b1;
                 if (code_fifo_out_tdata == 8'd0 || code_fifo_out_tdata == 8'd1 || code_fifo_out_tuser) begin
@@ -393,10 +404,10 @@
                 // transfer out data byte and decrement counter
                 m_axis_tdata_int = data_fifo_out_tdata;
                 m_axis_tlast_int = data_fifo_out_tlast;
-                output_count_next = output_count_reg - 1;
+                output_count_next = output_count_reg - 8'd1;
                 m_axis_tvalid_int = 1'b1;
                 data_fifo_out_tready = 1'b1;
-                if (output_count_reg == 1'b1) begin
+                if (output_count_reg == 8'd1) begin
                     // done with segment, get a code byte next
                     output_state_next = OUTPUT_STATE_IDLE;
                 end else begin
@@ -421,6 +432,9 @@
     if (rst) begin
         input_state_reg <= INPUT_STATE_IDLE;
         output_state_reg <= OUTPUT_STATE_IDLE;
+        input_count_reg <= 8'd0;
+        output_count_reg <= 8'd0;
+        fail_frame_reg <= 1'b0;
     end
 end
 
@@ -499,9 +513,15 @@
     end
 
     if (rst) begin
+        m_axis_tdata_reg <= 8'd0;
         m_axis_tvalid_reg <= 1'b0;
+        m_axis_tlast_reg <= 1'b0;
+        m_axis_tuser_reg <= 1'b0;
         m_axis_tready_int_reg <= 1'b0;
+        temp_m_axis_tdata_reg <= 8'd0;
         temp_m_axis_tvalid_reg <= 1'b0;
+        temp_m_axis_tlast_reg <= 1'b0;
+        temp_m_axis_tuser_reg <= 1'b0;
     end
 end
 

--- a/environment/public/code/axis_cobs_decode.v (Buggy Starter)
+++ b/solution/gold/code/axis_cobs_decode.v (Golden Reference)
@@ -67,6 +67,7 @@
 reg suppress_zero_reg = 1'b0, suppress_zero_next;
 
 reg [7:0] temp_tdata_reg = 8'd0, temp_tdata_next;
+reg temp_tuser_reg = 1'b0, temp_tuser_next;
 reg temp_tvalid_reg = 1'b0, temp_tvalid_next;
 
 // internal datapath
@@ -88,6 +89,7 @@
     suppress_zero_next = suppress_zero_reg;
 
     temp_tdata_next = temp_tdata_reg;
+    temp_tuser_next = temp_tuser_reg;
     temp_tvalid_next = temp_tvalid_reg;
 
     m_axis_tdata_int = 8'd0;
@@ -102,28 +104,50 @@
             // idle state
             s_axis_tready_next = m_axis_tready_int_early || !temp_tvalid_reg;
 
-            // output final word
-            m_axis_tdata_int = temp_tdata_reg;
+            // output final word (or deferred 1-byte malformed frame beat)
+            m_axis_tdata_int = temp_tvalid_reg ? temp_tdata_reg : 8'd0;
             m_axis_tvalid_int = temp_tvalid_reg;
             m_axis_tlast_int = temp_tvalid_reg;
+            m_axis_tuser_int = temp_tvalid_reg ? temp_tuser_reg : 1'b0;
             temp_tvalid_next = temp_tvalid_reg && !m_axis_tready_int_reg;
+            if (!temp_tvalid_next) begin
+                temp_tdata_next = 8'd0;
+                temp_tuser_next = 1'b0;
+            end
 
             if (s_axis_tready && s_axis_tvalid) begin
                 // valid input data
-                // skip any leading zeros
                 if (s_axis_tdata != 8'd0) begin
-                    // store count value and zero suppress
-                    count_next = s_axis_tdata-1;
-                    suppress_zero_next = (s_axis_tdata == 8'd255);
+                    if (s_axis_tlast) begin
+                        // truncated 1-byte COBS frame (code byte with immediate tlast):
+                        // queue bad-frame beat in temp so any draining prior frame byte is preserved
+                        temp_tdata_next = 8'd0;
+                        temp_tuser_next = 1'b1;
+                        temp_tvalid_next = 1'b1;
+                        s_axis_tready_next = m_axis_tready_int_early;
+                        state_next = STATE_IDLE;
+                    end else begin
+                        // store count value and zero suppress
+                        count_next = s_axis_tdata - 8'd1;
+                        suppress_zero_next = (s_axis_tdata == 8'd255);
+                        s_axis_tready_next = m_axis_tready_int_early;
+                        if (s_axis_tdata == 8'd1) begin
+                            // next byte will be count value
+                            state_next = STATE_NEXT_SEGMENT;
+                        end else begin
+                            // next byte will be data
+                            state_next = STATE_SEGMENT;
+                        end
+                    end
+                end else if (s_axis_tlast && s_axis_tuser) begin
+                    // single-byte zero frame explicitly marked bad
+                    temp_tdata_next = 8'd0;
+                    temp_tuser_next = 1'b1;
+                    temp_tvalid_next = 1'b1;
                     s_axis_tready_next = m_axis_tready_int_early;
-                    if (s_axis_tdata == 8'd1) begin
-                        // next byte will be count value
-                        state_next = STATE_NEXT_SEGMENT;
-                    end else begin
-                        // next byte will be data
-                        state_next = STATE_SEGMENT;
-                    end
+                    state_next = STATE_IDLE;
                 end else begin
+                    // skip any leading zeros
                     state_next = STATE_IDLE;
                 end
             end else begin
@@ -138,19 +162,22 @@
                 // valid input data
                 // store in temp register
                 temp_tdata_next = s_axis_tdata;
+                temp_tuser_next = 1'b0;
                 temp_tvalid_next = 1'b1;
                 // move temp to output
-                m_axis_tdata_int = temp_tdata_reg;
+                m_axis_tdata_int = temp_tvalid_reg ? temp_tdata_reg : 8'd0;
                 m_axis_tvalid_int = temp_tvalid_reg;
+                m_axis_tuser_int = temp_tvalid_reg ? temp_tuser_reg : 1'b0;
                 // decrement count
-                count_next = count_reg - 1;
+                count_next = count_reg - 8'd1;
                 if (s_axis_tdata == 8'd0) begin
                     // got a zero byte in a frame - mark it as an error and re-sync
+                    temp_tdata_next = 8'd0;
                     temp_tvalid_next = 1'b0;
                     m_axis_tvalid_int = 1'b1;
                     m_axis_tuser_int = 1'b1;
                     m_axis_tlast_int = 1'b1;
-                    s_axis_tready_next = 1'b1;
+                    s_axis_tready_next = m_axis_tready_int_early;
                     state_next = STATE_IDLE;
                 end else if (s_axis_tlast) begin
                     // end of frame
@@ -159,11 +186,12 @@
                         state_next = STATE_IDLE;
                     end else begin
                         // end of frame indication at invalid time or tuser assert, so mark as an error and re-sync
+                        temp_tdata_next = 8'd0;
                         temp_tvalid_next = 1'b0;
                         m_axis_tvalid_int = 1'b1;
                         m_axis_tuser_int = 1'b1;
                         m_axis_tlast_int = 1'b1;
-                        s_axis_tready_next = 1'b1;
+                        s_axis_tready_next = m_axis_tready_int_early;
                         state_next = STATE_IDLE;
                     end
                 end else if (count_reg == 8'd1) begin
@@ -185,33 +213,42 @@
                 // valid input data
                 // store zero in temp if not suppressed
                 temp_tdata_next = 8'd0;
+                temp_tuser_next = 1'b0;
                 temp_tvalid_next = !suppress_zero_reg;
                 // move temp to output
-                m_axis_tdata_int = temp_tdata_reg;
+                m_axis_tdata_int = temp_tvalid_reg ? temp_tdata_reg : 8'd0;
                 m_axis_tvalid_int = temp_tvalid_reg;
+                m_axis_tuser_int = temp_tvalid_reg ? temp_tuser_reg : 1'b0;
                 if (s_axis_tdata == 8'd0) begin
-                    // got a zero byte delineating the end of the frame, so mark as such and re-sync
+                    // got a zero byte delineating the end of the frame
                     temp_tvalid_next = 1'b0;
-                    m_axis_tuser_int = s_axis_tuser;
+                    if (!temp_tvalid_reg) begin
+                        // malformed zero-offset escape (e.g. [0x01, 0x00] or [0xFF, 254B, 0x01, 0x00])
+                        m_axis_tdata_int = 8'd0;
+                        m_axis_tvalid_int = 1'b1;
+                        m_axis_tuser_int = 1'b1;
+                    end else begin
+                        m_axis_tuser_int = s_axis_tuser;
+                    end
                     m_axis_tlast_int = 1'b1;
-                    s_axis_tready_next = 1'b1;
+                    s_axis_tready_next = m_axis_tready_int_early;
                     state_next = STATE_IDLE;
                 end else if (s_axis_tlast) begin
-                    if (s_axis_tdata == 8'd1 && !s_axis_tuser) begin
-                        // end of frame indication at correct time, go to idle to output final byte
-                        state_next = STATE_IDLE;
-                    end else begin
-                        // end of frame indication at invalid time or tuser assert, so mark as an error and re-sync
+                    if (s_axis_tdata == 8'd1 && !s_axis_tuser && !suppress_zero_reg) begin
+                        // end of frame indication at correct time, go to idle to output final zero byte
+                        state_next = STATE_IDLE;
+                    end else begin
+                        // end of frame indication at invalid time, suppressed-zero 0x01 tail, or tuser assert
                         temp_tvalid_next = 1'b0;
                         m_axis_tvalid_int = 1'b1;
                         m_axis_tuser_int = 1'b1;
                         m_axis_tlast_int = 1'b1;
-                        s_axis_tready_next = 1'b1;
+                        s_axis_tready_next = m_axis_tready_int_early;
                         state_next = STATE_IDLE;
                     end
                 end else begin
                     // otherwise, store count value and zero suppress
-                    count_next = s_axis_tdata-1;
+                    count_next = s_axis_tdata - 8'd1;
                     suppress_zero_next = (s_axis_tdata == 8'd255);
                     s_axis_tready_next = m_axis_tready_int_early;
                     if (s_axis_tdata == 8'd1) begin
@@ -226,6 +263,9 @@
                 state_next = STATE_NEXT_SEGMENT;
             end
         end
+        default: begin
+            state_next = STATE_IDLE;
+        end
     endcase
 end
 
@@ -236,12 +276,17 @@
     suppress_zero_reg <= suppress_zero_next;
 
     temp_tdata_reg <= temp_tdata_next;
+    temp_tuser_reg <= temp_tuser_next;
     temp_tvalid_reg <= temp_tvalid_next;
 
     s_axis_tready_reg <= s_axis_tready_next;
 
     if (rst) begin
         state_reg <= STATE_IDLE;
+        count_reg <= 8'd0;
+        suppress_zero_reg <= 1'b0;
+        temp_tdata_reg <= 8'd0;
+        temp_tuser_reg <= 1'b0;
         temp_tvalid_reg <= 1'b0;
         s_axis_tready_reg <= 1'b0;
     end
@@ -322,9 +367,15 @@
     end
 
     if (rst) begin
+        m_axis_tdata_reg <= 8'd0;
         m_axis_tvalid_reg <= 1'b0;
+        m_axis_tlast_reg <= 1'b0;
+        m_axis_tuser_reg <= 1'b0;
         m_axis_tready_int_reg <= 1'b0;
+        temp_m_axis_tdata_reg <= 8'd0;
         temp_m_axis_tvalid_reg <= 1'b0;
+        temp_m_axis_tlast_reg <= 1'b0;
+        temp_m_axis_tuser_reg <= 1'b0;
     end
 end
 

--- a/environment/public/code/axis_frame_length_adjust.v (Buggy Starter)
+++ b/solution/gold/code/axis_frame_length_adjust.v (Golden Reference)
@@ -120,14 +120,18 @@
 
 // datapath control signals
 reg store_last_word;
+reg store_last_meta;
 
 reg [15:0] frame_ptr_reg = 16'd0, frame_ptr_next;
 
+wire [KEEP_WIDTH-1:0] s_axis_tkeep_eff = KEEP_ENABLE ? s_axis_tkeep : {KEEP_WIDTH{1'b1}};
 reg [DATA_WIDTH-1:0] s_axis_tdata_masked;
 
-// frame length counters
-reg [15:0] short_counter_reg = 16'd0, short_counter_next = 16'd0;
-reg [15:0] long_counter_reg = 16'd0, long_counter_next = 16'd0;
+// frame length counters and per-frame captured limits
+reg [15:0] short_counter_reg = 16'd0, short_counter_next;
+reg [15:0] long_counter_reg = 16'd0, long_counter_next;
+reg [15:0] frame_len_min_reg = 16'd0, frame_len_min_next;
+reg [15:0] frame_len_max_reg = 16'd0, frame_len_max_next;
 
 reg [DATA_WIDTH-1:0] last_word_data_reg = {DATA_WIDTH{1'b0}};
 reg [KEEP_WIDTH-1:0] last_word_keep_reg = {KEEP_WIDTH{1'b0}};
@@ -135,11 +139,15 @@
 reg [DEST_WIDTH-1:0] last_word_dest_reg = {DEST_WIDTH{1'b0}};
 reg [USER_WIDTH-1:0] last_word_user_reg = {USER_WIDTH{1'b0}};
 
-reg status_valid_reg = 1'b0, status_valid_next;
-reg status_frame_pad_reg = 1'b0, status_frame_pad_next;
-reg status_frame_truncate_reg = 1'b0, status_frame_truncate_next;
-reg [15:0] status_frame_length_reg = 16'd0, status_frame_length_next;
-reg [15:0] status_frame_original_length_reg = 16'd0, status_frame_original_length_next;
+// internal status datapath (skid-buffered to match m_axis_*)
+reg        status_valid_int;
+reg        status_ready_int_reg = 1'b0;
+wire       status_ready_int_early;
+reg        status_frame_pad_int;
+reg        status_frame_truncate_int;
+reg [15:0] status_frame_length_int;
+reg [15:0] status_frame_original_length_int;
+reg [15:0] orig_len_reg = 16'd0, orig_len_next;
 
 // internal datapath
 reg  [DATA_WIDTH-1:0] m_axis_tdata_int;
@@ -155,23 +163,22 @@
 reg s_axis_tready_reg = 1'b0, s_axis_tready_next;
 assign s_axis_tready = s_axis_tready_reg;
 
-assign status_valid = status_valid_reg;
-assign status_frame_pad = status_frame_pad_reg;
-assign status_frame_truncate = status_frame_truncate_reg;
-assign status_frame_length = status_frame_length_reg;
-assign status_frame_original_length = status_frame_original_length_reg;
-
-integer i, word_cnt;
+integer i;
+reg [15:0] word_cnt;
 
 always @* begin
     state_next = STATE_IDLE;
 
     store_last_word = 1'b0;
+    store_last_meta = 1'b0;
 
     frame_ptr_next = frame_ptr_reg;
 
     short_counter_next = short_counter_reg;
     long_counter_next = long_counter_reg;
+    frame_len_min_next = frame_len_min_reg;
+    frame_len_max_next = frame_len_max_reg;
+    orig_len_next = orig_len_reg;
 
     m_axis_tdata_int  = {DATA_WIDTH{1'b0}};
     m_axis_tkeep_int  = {KEEP_WIDTH{1'b0}};
@@ -183,112 +190,117 @@
 
     s_axis_tready_next = 1'b0;
 
-    status_valid_next = status_valid_reg && !status_ready;
-    status_frame_pad_next = status_frame_pad_reg;
-    status_frame_truncate_next = status_frame_truncate_reg;
-    status_frame_length_next = status_frame_length_reg;
-    status_frame_original_length_next = status_frame_original_length_reg;
-
+    status_valid_int = 1'b0;
+    status_frame_pad_int = 1'b0;
+    status_frame_truncate_int = 1'b0;
+    status_frame_length_int = 16'd0;
+    status_frame_original_length_int = 16'd0;
+
+    s_axis_tdata_masked = s_axis_tdata;
     if (KEEP_ENABLE) begin
         for (i = 0; i < KEEP_WIDTH; i = i + 1) begin
-            s_axis_tdata_masked[i*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] = s_axis_tkeep[i] ? s_axis_tdata[i*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] : {DATA_WORD_WIDTH{1'b0}};
-        end
-    end else begin
-        s_axis_tdata_masked = s_axis_tdata;
+            s_axis_tdata_masked[i*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] = s_axis_tkeep_eff[i] ? s_axis_tdata[i*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] : {DATA_WORD_WIDTH{1'b0}};
+        end
+    end
+
+    word_cnt = 16'd0;
+    for (i = 0; i <= KEEP_WIDTH; i = i + 1) begin
+        if (s_axis_tkeep_eff == (({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - i))) begin
+            word_cnt = i[15:0];
+        end
     end
 
     case (state_reg)
         STATE_IDLE: begin
-            // idle state
-            // accept data next cycle if output register ready next cycle
-            s_axis_tready_next = m_axis_tready_int_early && (!status_valid_reg || status_ready);
-
-            m_axis_tdata_int = s_axis_tdata_masked;
-            m_axis_tkeep_int = s_axis_tkeep;
-            m_axis_tvalid_int = s_axis_tvalid;
-            m_axis_tlast_int = s_axis_tlast;
-            m_axis_tid_int = s_axis_tid;
-            m_axis_tdest_int = s_axis_tdest;
-            m_axis_tuser_int = s_axis_tuser;
+            // idle state: accept data next cycle only when both output data and status skid stages can accept
+            s_axis_tready_next = m_axis_tready_int_early && status_ready_int_early;
 
             short_counter_next = length_min;
             long_counter_next = length_max;
+            frame_len_min_next = length_min;
+            frame_len_max_next = length_max;
 
             if (s_axis_tready && s_axis_tvalid) begin
-                // transfer through
-                word_cnt = 0;
-                for (i = 0; i <= KEEP_WIDTH; i = i + 1) begin
-                    //bit_cnt = bit_cnt + monitor_axis_tkeep[i];
-                    if (s_axis_tkeep == ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH-i)) word_cnt = i;
-                end
-                frame_ptr_next = frame_ptr_reg+KEEP_WIDTH;
-
-                if (short_counter_reg > KEEP_WIDTH) begin
-                    short_counter_next = short_counter_reg - KEEP_WIDTH;
+                m_axis_tdata_int = s_axis_tdata_masked;
+                m_axis_tkeep_int = s_axis_tkeep_eff;
+                m_axis_tvalid_int = 1'b1;
+                m_axis_tlast_int = s_axis_tlast;
+                m_axis_tid_int = s_axis_tid;
+                m_axis_tdest_int = s_axis_tdest;
+                m_axis_tuser_int = s_axis_tuser;
+
+                frame_ptr_next = 16'd0 + KEEP_WIDTH;
+
+                if (length_min > KEEP_WIDTH) begin
+                    short_counter_next = length_min - KEEP_WIDTH;
                 end else begin
                     short_counter_next = 16'd0;
                 end
 
-                if (long_counter_reg > KEEP_WIDTH) begin
-                    long_counter_next = long_counter_reg - KEEP_WIDTH;
+                if (length_max > KEEP_WIDTH) begin
+                    long_counter_next = length_max - KEEP_WIDTH;
                 end else begin
                     long_counter_next = 16'd0;
                 end
 
-                if (long_counter_reg <= word_cnt) begin
-                    m_axis_tkeep_int = ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH-long_counter_reg);
+                if (length_max <= word_cnt) begin
+                    m_axis_tkeep_int = ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - length_max);
+                    // Re-mask padded/truncated high bytes beyond length_max
+                    if (KEEP_ENABLE) begin
+                        for (i = 0; i < KEEP_WIDTH; i = i + 1) begin
+                            m_axis_tdata_int[i*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] = m_axis_tkeep_int[i] ? s_axis_tdata_masked[i*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] : {DATA_WORD_WIDTH{1'b0}};
+                        end
+                    end
                     if (s_axis_tlast) begin
-                        status_valid_next = 1'b1;
-                        status_frame_pad_next = 1'b0;
-                        status_frame_truncate_next = word_cnt > long_counter_reg;
-                        status_frame_length_next = length_max;
-                        status_frame_original_length_next = frame_ptr_reg+word_cnt;
-                        s_axis_tready_next = m_axis_tready_int_early && status_ready;
+                        status_valid_int = 1'b1;
+                        status_frame_pad_int = 1'b0;
+                        status_frame_truncate_int = (word_cnt > length_max);
+                        status_frame_length_int = length_max;
+                        status_frame_original_length_int = word_cnt;
+                        s_axis_tready_next = m_axis_tready_int_early && status_ready_int_early;
                         frame_ptr_next = 16'd0;
-                        short_counter_next = length_min;
-                        long_counter_next = length_max;
                         state_next = STATE_IDLE;
                     end else begin
                         m_axis_tvalid_int = 1'b0;
                         store_last_word = 1'b1;
+                        store_last_meta = 1'b1;
+                        s_axis_tready_next = m_axis_tready_int_early && status_ready_int_early;
                         state_next = STATE_TRUNCATE;
                     end
                 end else begin
                     if (s_axis_tlast) begin
-                        status_frame_original_length_next = frame_ptr_reg+word_cnt;
-                        if (short_counter_reg > word_cnt) begin
-                      
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axis_cobs_decode.v`](environment/public/code/axis_cobs_decode.v) **(Editable)**
- [`environment/public/code/axis_cobs_encode.v`](environment/public/code/axis_cobs_encode.v) **(Editable)**
- [`environment/public/code/axis_fifo.v`](environment/public/code/axis_fifo.v) *(Read-Only Context)*
- [`environment/public/code/axis_frame_length_adjust.v`](environment/public/code/axis_frame_length_adjust.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

