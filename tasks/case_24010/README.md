# `case_24010`: Scatter-Gather Descriptor Error Recovery, Stream Abort/Sync-Start Deadlocks, and Multi-Clock Timing Closure in ADI AXI DMAC

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_24010` |
| **Source Silicon Repository** | `analogdevicesinc/hdl` (`repo_38`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/dmac_sg.v`](environment/public/code/dmac_sg.v), [`code/data_mover.v`](environment/public/code/data_mover.v), [`code/request_arb.v`](environment/public/code/request_arb.v), [`code/axi_dmac_burst_memory.v`](environment/public/code/axi_dmac_burst_memory.v) (4 files, 2287 LOC) |
| **Public Subsystem Context** | 29 RTL files (6167 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

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

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Reference (`dmac_sg_cluster`)

## Editable Files
- `code/dmac_sg.v`
- `code/data_mover.v`
- `code/request_arb.v`
- `code/axi_dmac_burst_memory.v`

## Local Simulation & Nangate45 STA Commands
- **Verilator Multi-Clock Simulation**:
  ```bash
  verilator --binary --timing -Wno-fatal -Icode code/ad_mem.v code/ad_mem_asym.v \
    code/sync_bits.v code/sync_gray.v code/sync_event.v \
    code/util_axis_fifo_address_generator.v code/util_axis_fifo.v code/splitter.v \
    code/address_generator.v code/request_generator.v code/response_handler.v \
    code/axi_dmac_response_manager.v code/axi_dmac_resize_src.v code/axi_dmac_resize_dest.v \
    code/axi_register_slice.v code/axi_dmac_ext_sync.v code/data_mover.v \
    code/src_axi_stream.v code/src_axi_mm.v code/src_fifo_inf.v \
    code/dest_axi_mm.v code/dest_axi_stream.v code/dest_fifo_inf.v \
    code/axi_dmac_burst_memory.v code/request_arb.v code/dmac_sg.v code/dmac_sg_cluster.v <your_tb.sv>
  ```
- **Yosys Nangate45 Synthesis & OpenROAD OpenSTA Signoff**:
  Use `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib` with Yosys (`hierarchy -check -top dmac_sg_cluster; proc; opt; memory; opt; flatten; opt; techmap; opt; dfflibmap -liberty ...; abc -liberty ... -script "+strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf -D 800; &put; buffer -N 8; upsize -D 800; dnsize -D 800"; hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z`) and OpenROAD (`openroad -exit`) at the exact clock periods and I/O delays specified in `issue.md`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/dmac_sg.v (Buggy Starter)
+++ b/solution/gold/code/dmac_sg.v (Golden Reference)
@@ -124,6 +124,7 @@
   reg [2:0] hwdesc_counter;
   reg [1:0] hwdesc_flags;
   reg [31:0] hwdesc_id;
+  reg hwdesc_err;
 
   wire sg_in_valid;
   wire sg_in_ready;
@@ -178,9 +179,13 @@
   always @(posedge sg_clk) begin
     if (sg_resetn == 1'b0) begin
       hwdesc_counter <= 'h0;
-    end else if (m_axi_rvalid) begin
-      hwdesc_counter <= hwdesc_counter + 1'b1;
-    end else if (hwdesc_state == STATE_DESC_READY) begin
+    end else if (m_axi_rvalid && m_axi_rready) begin
+      if (m_axi_rlast) begin
+        hwdesc_counter <= 'h0;
+      end else begin
+        hwdesc_counter <= hwdesc_counter + 1'b1;
+      end
+    end else if (hwdesc_state != STATE_RECV_DESC) begin
       hwdesc_counter <= 'h0;
     end
   end
@@ -201,7 +206,7 @@
       if (sg_in_valid && sg_in_ready) begin
         next_desc_addr <= first_desc_address;
       end
-      if (m_axi_rvalid) begin
+      if (m_axi_rvalid && m_axi_rready && m_axi_rresp == 2'b00) begin
         case (hwdesc_counter)
         0: begin
           hwdesc_id <= m_axi_rdata[63:32];
@@ -223,41 +228,57 @@
     end
   end
 
-  // Descriptor FSM
+  // Descriptor FSM with RRESP / mid-fetch sg_enable abort-drain & atomic splitter completion
   always @(posedge sg_clk) begin
     if (sg_resetn == 1'b0) begin
       hwdesc_state <= STATE_IDLE;
+      hwdesc_err <= 1'b0;
     end else begin
       case (hwdesc_state)
         STATE_IDLE: begin
+          hwdesc_err <= 1'b0;
           if (sg_in_valid == 1'b1 && sg_enable == 1'b1) begin
             hwdesc_state <= STATE_SEND_ADDR;
           end
-          end
+        end
 
         STATE_SEND_ADDR: begin
+          if (sg_enable == 1'b0) begin
+            hwdesc_err <= 1'b1;
+          end
           if (m_axi_arready) begin
             hwdesc_state <= STATE_RECV_DESC;
           end
-          end
+        end
 
         STATE_RECV_DESC: begin
-          if (m_axi_rvalid == 1'b1 && m_axi_rlast == 1'b1) begin
-            hwdesc_state <= STATE_DESC_READY;
-          end
-          end
+          if (sg_enable == 1'b0) begin
+            hwdesc_err <= 1'b1;
+          end
+          if (m_axi_rvalid == 1'b1) begin
+            if (m_axi_rresp != 2'b00) begin
+              hwdesc_err <= 1'b1;
+            end
+            if (m_axi_rlast == 1'b1) begin
+              if (hwdesc_err || (m_axi_rresp != 2'b00) || (sg_enable == 1'b0)) begin
+                hwdesc_state <= STATE_IDLE;
+              end else begin
+                hwdesc_state <= STATE_DESC_READY;
+              end
+            end
+          end
+        end
 
         STATE_DESC_READY: begin
-          if (sg_enable == 1'b0) begin
-              hwdesc_state <= STATE_IDLE;
-          end else if (fetch_ready == 1'b1) begin
-            if (hwdesc_flags & MASK_LAST_HWDESC) begin
+          hwdesc_err <= 1'b0;
+          if (fetch_ready == 1'b1) begin
+            if ((hwdesc_flags & MASK_LAST_HWDESC) || (sg_enable == 1'b0)) begin
               hwdesc_state <= STATE_IDLE;
             end else begin
               hwdesc_state <= STATE_SEND_ADDR;
             end
           end
-          end
+        end
       endcase
     end
   end
@@ -318,7 +339,7 @@
   // Extract them one by one when the destination responds with an eot
   util_axis_fifo #(
     .DATA_WIDTH(33),
-    .ADDRESS_WIDTH(2),
+    .ADDRESS_WIDTH(4),
     .ASYNC_CLK(ASYNC_CLK_REQ_SG)
   ) i_fifo (
     .s_axis_aclk(sg_clk),

--- a/environment/public/code/data_mover.v (Buggy Starter)
+++ b/solution/gold/code/data_mover.v (Golden Reference)
@@ -103,6 +103,8 @@
   wire last_load;
   wire last;
   wire early_tlast;
+  wire bl_stall;
+  wire rewind_stall;
 
   assign xfer_req = active;
 
@@ -112,9 +114,12 @@
   assign last = eot ? last_eot : last_non_eot;
 
   assign has_sync = ~needs_sync | s_axi_sync;
-
-  assign s_axi_ready = (pending_burst & active) & ~transfer_abort_s & has_sync;
-  assign m_axi_valid = s_axi_valid & s_axi_ready;
+  assign bl_stall = 1'b0;
+
+  // Compliant AXI4-Stream sync-start: accept & discard pre-sync beats without
+  // combinational s_axi_sync -> s_axi_ready Mealy path!
+  assign s_axi_ready = (pending_burst & active) & ~transfer_abort_s & ~bl_stall & ~rewind_stall;
+  assign m_axi_valid = s_axi_valid & s_axi_ready & has_sync;
   assign m_axi_data = s_axi_data;
   assign m_axi_last = last || early_tlast;
   assign m_axi_partial_burst = early_tlast;
@@ -127,14 +132,10 @@
     reg transfer_abort = 1'b0;
     reg req_xlast_d = 1'b0;
     reg [1:0] transfer_id = 2'b0;
+    reg rewind_pending = 1'b0;
+    reg [ID_WIDTH+3-1:0] rewind_data_q = 'h0;
 
     assign programmed_last = (last == 1'b1 && eot == 1'b1 && req_xlast_d == 1'b1);
-    /*
-     * A 'last' on the external interface indicates the end of an packet. If such a
-     * 'last' indicator is observed before the end of the current transfer stop
-     * accepting data on the external interface until a new descriptor is
-     * received that is the first segment of a transfer.
-     */
     always @(posedge clk) begin
       if (resetn == 1'b0) begin
         transfer_abort <= 1'b0;
@@ -150,7 +151,9 @@
     end
 
     always @(posedge clk) begin
-      if (req_ready == 1'b1 && req_valid == 1'b1) begin
+      if (resetn == 1'b0) begin
+        req_xlast_d <= 1'b0;
+      end else if (req_ready == 1'b1 && req_valid == 1'b1) begin
         req_xlast_d <= req_xlast;
       end
     end
@@ -159,8 +162,21 @@
     assign early_tlast = (s_axi_ready == 1'b1) && (m_axi_valid == 1'b1) &&
                          (s_axi_last == 1'b1) && (programmed_last == 1'b0);
 
-    assign rewind_req_valid = early_tlast;
-    assign rewind_req_data = {transfer_id,req_xlast_d,id_next};
+    always @(posedge clk) begin
+      if (resetn == 1'b0) begin
+        rewind_pending <= 1'b0;
+        rewind_data_q <= 'h0;
+      end else if (early_tlast) begin
+        rewind_pending <= ~rewind_req_ready;
+        rewind_data_q <= {transfer_id, req_xlast_d, id_next};
+      end else if (rewind_req_ready) begin
+        rewind_pending <= 1'b0;
+      end
+    end
+
+    assign rewind_stall = rewind_pending;
+    assign rewind_req_valid = early_tlast | rewind_pending;
+    assign rewind_req_data = rewind_pending ? rewind_data_q : {transfer_id, req_xlast_d, id_next};
 
     // The width of the id must fit the number of transfers that can be in flight
     // in the burst memory
@@ -175,6 +191,7 @@
   end else begin
     assign transfer_abort_s = 1'b0;
     assign early_tlast = 1'b0;
+    assign rewind_stall = 1'b0;
     assign rewind_req_valid = 1'b0;
     assign rewind_req_data = 'h0;
   end endgenerate
@@ -198,9 +215,10 @@
   // In case the data mover is not active accept a new descriptor only when the
   // upstream logic incremented its id (pending_burst is set).
   assign last_load = m_axi_valid && last_eot && eot;
-  assign req_ready = (last_load && ~early_tlast) ||
+  assign req_ready = ~bl_stall && (
+                     (last_load && ~early_tlast) ||
                      ((~active && ~transfer_abort_s) && pending_burst) ||
-                     (transfer_abort_s && rewind_req_ready);
+                     (transfer_abort_s && ~rewind_stall && rewind_req_ready));
 
   always @(posedge clk) begin
     if (req_ready) begin
@@ -228,7 +246,10 @@
   end
 
   always @(posedge clk) begin
-    if (last_load || early_tlast) begin
+    if (resetn == 1'b0) begin
+      bl_valid <= 1'b0;
+      measured_last_burst_length <= 'h0;
+    end else if (last_load || early_tlast) begin
       bl_valid <= 1'b1;
       measured_last_burst_length <= beat_counter_minus_one;
     end else if (bl_ready) begin
@@ -241,7 +262,7 @@
       active <= 1'b0;
     end else if (req_valid == 1'b1 && req_ready == 1'b1) begin
       active <= 1'b1;
-    end else if (last_load == 1'b1) begin
+    end else if (last_load == 1'b1 || early_tlast == 1'b1) begin
       active <= 1'b0;
     end
   end
@@ -263,7 +284,11 @@
   end
 
   always @(posedge clk) begin
-    pending_burst <= id_next != request_id;
+    if (resetn == 1'b0) begin
+      pending_burst <= 1'b0;
+    end else begin
+      pending_burst <= id_next != request_id;
+    end
   end
 
 endmodule

--- a/environment/public/code/request_arb.v (Buggy Starter)
+++ b/solution/gold/code/request_arb.v (Golden Reference)
@@ -48,8 +48,8 @@
   parameter ASYNC_CLK_REQ_SRC = 1,
   parameter ASYNC_CLK_SRC_DEST = 1,
   parameter ASYNC_CLK_DEST_REQ = 1,
-  parameter AXI_SLICE_DEST = 0,
-  parameter AXI_SLICE_SRC = 0,
+  parameter AXI_SLICE_DEST = 1,
+  parameter AXI_SLICE_SRC = 1,
   parameter AXIS_TUSER_SYNC = 1,
   parameter MAX_BYTES_PER_BURST = 128,
   parameter BYTES_PER_BURST_WIDTH = 7,
@@ -811,7 +811,7 @@
   always @(posedge src_clk) begin
     if (src_resetn == 1'b0) begin
       src_throttler_enabled <= 'b1;
-    end else if (rewind_req_valid) begin
+    end else if (rewind_req_valid && rewind_req_ready) begin
       src_throttler_enabled <= 'b0;
     end else if (src_throttler_enable) begin
       src_throttler_enabled <= 'b1;
@@ -900,7 +900,7 @@
     .ASYNC_CLK(ASYNC_CLK_REQ_SRC)
   ) i_sync_src_request_id (
     .out_clk(src_clk),
-    .out_resetn(1'b1),
+    .out_resetn(src_resetn),
     .in_bits(request_id),
     .out_bits(src_request_id));
 
@@ -933,7 +933,7 @@
   always @(posedge src_clk) begin
     if (src_resetn == 1'b0) begin
       src_throttled_request_id <= 'h00;
-    end else if (rewind_req_valid) begin
+    end else if (rewind_req_valid && rewind_req_ready) begin
       src_throttled_request_id <= rewind_req_data[ID_WIDTH-1:0];
     end else if (src_throttled_request_id != src_request_id &&
                  compare_id(src_throttled_request_id, src_data_request_id) &&
@@ -947,7 +947,7 @@
     .ASYNC_CLK(ASYNC_CLK_DEST_REQ)
   ) i_sync_req_response_id (
     .out_clk(req_clk),
-    .out_resetn(1'b1),
+    .out_resetn(req_resetn),
     .in_bits(dest_response_id),
     .out_bits(response_id));
 

--- a/environment/public/code/axi_dmac_burst_memory.v (Buggy Starter)
+++ b/solution/gold/code/axi_dmac_burst_memory.v (Golden Reference)
@@ -320,13 +320,18 @@
   end
 
   always @(posedge dest_clk) begin
-    if (dest_burst_valid == 1'b1 && dest_burst_ready == 1'b1) begin
-      dest_burst_len_data[BYTES_PER_BURST_WIDTH:DMA_LENGTH_ALIGN] <= burst_len_mem[dest_id_reduced_next];
-    end
-  end
-
-  always @(posedge dest_clk) begin
-    if (dest_burst_ready == 1'b1) begin
+    if (dest_reset == 1'b1) begin
+      dest_burst_len_data <= {{(BYTES_PER_BURST_WIDTH+1-DMA_LENGTH_ALIGN){1'b0}}, {DMA_LENGTH_ALIGN{1'b1}}};
+    end else if (dest_burst_valid == 1'b1 && dest_burst_ready == 1'b1) begin
+      dest_burst_len_data <= {burst_len_mem[dest_id_reduced_next], {DMA_LENGTH_ALIGN{1'b1}}};
+    end
+  end
+
+  always @(posedge dest_clk) begin
+    if (dest_reset == 1'b1) begin
+      dest_id <= 'h00;
+      dest_id_reduced_msb <= 1'b0;
+    end else if (dest_burst_ready == 1'b1) begin
       dest_id <= dest_id_next;
       dest_id_reduced_msb <= dest_id_reduced_msb_next;
     end
@@ -345,7 +350,11 @@
   assign dest_burst_info_id = dest_id;
 
   always @(posedge dest_clk) begin
-    dest_burst_info_write <= (dest_burst_valid == 1'b1 && dest_burst_ready == 1'b1);
+    if (dest_reset == 1'b1) begin
+      dest_burst_info_write <= 1'b0;
+    end else begin
+      dest_burst_info_write <= (dest_burst_valid == 1'b1 && dest_burst_ready == 1'b1);
+    end
   end
 
   assign dest_burst_len = dest_burst_len_data[BYTES_PER_BURST_WIDTH-1 -: BURST_LEN_WIDTH_DEST];
@@ -416,7 +425,7 @@
   ) i_dest_sync_id (
     .in_bits (src_id),
     .out_clk (dest_clk),
-    .out_resetn (1'b1),
+    .out_resetn (~dest_reset),
     .out_bits (dest_src_id));
 
   sync_bits #(
@@ -425,7 +434,7 @@
   ) i_src_sync_id (
     .in_bits (dest_id),
     .out_clk (src_clk),
-    .out_resetn (1'b1),
+    .out_resetn (~src_reset),
     .out_bits (src_dest_id));
 
   assign dest_request_id = dest_src_id;

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE_ADIBSD`](environment/public/code/LICENSE_ADIBSD) *(Read-Only Context)*
- [`environment/public/code/LICENSE_GPL2`](environment/public/code/LICENSE_GPL2) *(Read-Only Context)*
- [`environment/public/code/ad_mem.v`](environment/public/code/ad_mem.v) *(Read-Only Context)*
- [`environment/public/code/ad_mem_asym.v`](environment/public/code/ad_mem_asym.v) *(Read-Only Context)*
- [`environment/public/code/address_generator.v`](environment/public/code/address_generator.v) *(Read-Only Context)*
- [`environment/public/code/axi_dmac_burst_memory.v`](environment/public/code/axi_dmac_burst_memory.v) **(Editable)**
- [`environment/public/code/axi_dmac_ext_sync.v`](environment/public/code/axi_dmac_ext_sync.v) *(Read-Only Context)*
- [`environment/public/code/axi_dmac_resize_dest.v`](environment/public/code/axi_dmac_resize_dest.v) *(Read-Only Context)*
- [`environment/public/code/axi_dmac_resize_src.v`](environment/public/code/axi_dmac_resize_src.v) *(Read-Only Context)*
- [`environment/public/code/axi_dmac_response_manager.v`](environment/public/code/axi_dmac_response_manager.v) *(Read-Only Context)*
- [`environment/public/code/axi_register_slice.v`](environment/public/code/axi_register_slice.v) *(Read-Only Context)*
- [`environment/public/code/data_mover.v`](environment/public/code/data_mover.v) **(Editable)**
- [`environment/public/code/dest_axi_mm.v`](environment/public/code/dest_axi_mm.v) *(Read-Only Context)*
- [`environment/public/code/dest_axi_stream.v`](environment/public/code/dest_axi_stream.v) *(Read-Only Context)*
- [`environment/public/code/dest_fifo_inf.v`](environment/public/code/dest_fifo_inf.v) *(Read-Only Context)*
- [`environment/public/code/dmac_sg.v`](environment/public/code/dmac_sg.v) **(Editable)**
- [`environment/public/code/dmac_sg_cluster.v`](environment/public/code/dmac_sg_cluster.v) *(Read-Only Context)*
- [`environment/public/code/inc_id.vh`](environment/public/code/inc_id.vh) *(Read-Only Context)*
- [`environment/public/code/request_arb.v`](environment/public/code/request_arb.v) **(Editable)**
- [`environment/public/code/request_generator.v`](environment/public/code/request_generator.v) *(Read-Only Context)*
- [`environment/public/code/resp.vh`](environment/public/code/resp.vh) *(Read-Only Context)*
- [`environment/public/code/response_handler.v`](environment/public/code/response_handler.v) *(Read-Only Context)*
- [`environment/public/code/splitter.v`](environment/public/code/splitter.v) *(Read-Only Context)*
- [`environment/public/code/src_axi_mm.v`](environment/public/code/src_axi_mm.v) *(Read-Only Context)*
- [`environment/public/code/src_axi_stream.v`](environment/public/code/src_axi_stream.v) *(Read-Only Context)*
- [`environment/public/code/src_fifo_inf.v`](environment/public/code/src_fifo_inf.v) *(Read-Only Context)*
- [`environment/public/code/sync_bits.v`](environment/public/code/sync_bits.v) *(Read-Only Context)*
- [`environment/public/code/sync_event.v`](environment/public/code/sync_event.v) *(Read-Only Context)*
- [`environment/public/code/sync_gray.v`](environment/public/code/sync_gray.v) *(Read-Only Context)*
- [`environment/public/code/util_axis_fifo.v`](environment/public/code/util_axis_fifo.v) *(Read-Only Context)*
- [`environment/public/code/util_axis_fifo_address_generator.v`](environment/public/code/util_axis_fifo_address_generator.v) *(Read-Only Context)*
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

