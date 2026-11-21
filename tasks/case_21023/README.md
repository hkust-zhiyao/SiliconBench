# `case_21023`: Parametric Hardware ARP/INARP Offload Wide-Bus Framing, Cache Read-During-Write Coherence, RFC 826 Selective Learning, and TX Arbitration

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21023` |
| **Source Silicon Repository** | `corundum/corundum` (`repo_39`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/arp.v`](environment/public/code/arp.v), [`code/arp_cache.v`](environment/public/code/arp_cache.v), [`code/arp_eth_rx.v`](environment/public/code/arp_eth_rx.v), [`code/arp_eth_tx.v`](environment/public/code/arp_eth_tx.v) (4 files, 1398 LOC) |
| **Public Subsystem Context** | 5 RTL files (1845 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Parametric Hardware ARP/INARP Offload Wide-Bus Framing, Cache Coherence, RFC 826 Selective Learning, and TX Arbitration

## Problem Description
In our SmartNIC IPv4 ARP/INARP offload subsystem (`arp_eth_rx`, `arp_eth_tx`, `arp_cache`, and `arp`), wide-bus synthesis (`DATA_WIDTH >= 256`), IEEE 802.3 L2-padded/malformed frame injection, concurrent lookup/reply traffic, and backpressure stress testing exposed defects across all four modules:

1. **`arp_eth_rx` & `arp_eth_tx` Wide-Bus (`DATA_WIDTH = 8..512`), Padding, `tkeep`/`tuser` & `busy` Framing**:
   - Support parametric `DATA_WIDTH` across both multi-beat (`DATA_WIDTH = 64`) and single-beat (`DATA_WIDTH = 256`, `CYCLE_COUNT == 1`) interfaces without zero-width pointer elaboration or wrap-around bugs.
   - In `arp_eth_rx`, require all 28 ARP header octets (`0..27`) to arrive in the first `CYCLE_COUNT` beats with every ARP header byte lane enabled (`s_eth_payload_axis_tkeep == {KEEP_WIDTH{1'b1}}` on beats `< CYCLE_COUNT - 1` and `s_eth_payload_axis_tkeep[(27 % BYTE_LANES):0]` all `1`s on beat `CYCLE_COUNT - 1` when `KEEP_ENABLE != 0`); ignore and drain trailing L2 pad octets beyond byte 27 (unused upper lanes on beat `CYCLE_COUNT - 1` and extra pad beats up to `s_eth_payload_axis_tlast`) without overwriting parsed header fields, and keep `busy` asserted from accepting `s_eth_hdr_valid && s_eth_hdr_ready` until accepting `s_eth_payload_axis_tlast`.
   - At `s_eth_payload_axis_tlast` in `arp_eth_rx`:
     - If fewer than 28 contiguous kept ARP header octets arrived (premature `tlast` or any `tkeep == 0` lane in offsets `0..27`), pulse `error_header_early_termination` for 1 cycle and suppress `m_frame_valid` and `error_invalid_header`.
     - Else if `m_arp_hlen != 8'd6` or `m_arp_plen != 8'd4`, pulse `error_invalid_header` for 1 cycle and suppress `m_frame_valid`.
     - Else if `s_eth_payload_axis_tuser` asserted on **any** beat of the Ethernet payload (header or trailing pad beats), suppress `m_frame_valid` without pulsing error outputs; otherwise assert `m_frame_valid`.
2. **`arp_cache` Backpressure Stability, Read-During-Write Forwarding & `clear_cache` Synchronization**:
   - Hold `query_response_valid`, `query_response_error`, and `query_response_mac` constant while `query_response_valid && !query_response_ready`, never allowing a queued query to overwrite `query_response_*` (even when `query_request_valid` deasserts).
   - Provide coherent write-to-query forwarding: a `query_request` accepted on the same cycle as (or after) an accepted `write_request` targeting the same hash bucket must observe the newly written `(write_request_ip, write_request_mac)` state (hit with the new MAC if `query_request_ip == write_request_ip`, or miss if overwritten by a colliding IP) rather than stale RAM contents.
   - Immediately deassert `query_request_ready` and `write_request_ready` when `clear_cache` asserts and throughout the `2**CACHE_ADDR_WIDTH`-entry clear sweep so no new write or query is accepted during a clear (any already-accepted stage-1 write prior to `clear_cache` is invalidated by the clear, while any already-accepted stage-1 query still completes its `query_response`).
3. **`arp` Destination Routing, RFC 826 / RFC 5227 Selective Learning, TX Arbitration & Lookup Control**:
   - **Destination classification (`arp_request`)**: Return `48'hFFFF_FFFF_FFFF` (`error = 0`) immediately for limited broadcast (`32'hFFFF_FFFF`) or subnet-directed broadcast (`subnet_mask != 32'hFFFF_FFFF`, `((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0`, and `(arp_request_ip | subnet_mask) == 32'hFFFF_FFFF`); return RFC 1112 multicast `{24'h01_00_5E, 1'b0, arp_request_ip[22:0]}` (`error = 0`) immediately for `arp_request_ip[31:28] == 4'hE`; resolve `arp_request_ip` directly when on-subnet (`((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0`); when off-subnet, return `error = 1` immediately if `gateway_ip == 32'd0`, else resolve `gateway_ip`.
   - **Incoming validation, reply & RFC 826 selective learning**: Process only valid Ethernet/IPv4 ARP/INARP frames (`eth_type == 16'h0806`, `htype == 16'h0001`, `ptype == 16'h0800`, `oper` in `{16'h0001, 16'h0002, 16'h0008, 16'h0009}`). Transmit an ARP Reply (`oper = 16'h0002`) on `oper == 16'h0001 && tpa == local_ip` and an INARP Reply (`oper = 16'h0009`) on `oper == 16'h0008 && tha == local_mac` whenever `sha` is a valid unicast MAC (`sha != 48'd0 && !sha[40]`), including RFC 5227 ARP Probes (`spa == 32'd0`). Learn `(spa, sha)` into `arp_cache` **only** when `spa` is unicast IPv4 (`spa != 32'd0`, `spa != 32'hFFFF_FFFF`, `spa[31:28] != 4'hE`) and `sha` is unicast MAC (`sha != 48'd0 && !sha[40]`): insert/update unconditionally when the frame targets this host (`tpa == local_ip` for `oper` `1`/`2`, or `tha == local_mac` for `oper` `8`/`9`) or `spa` matches the active pending lookup target IP; for non-targeted frames (e.g., Gratuitous ARP or third-party broadcasts), update `arp_cache` **only if** `spa` is already cached so unrelated ARP traffic cannot evict colliding hash buckets.
   - **TX arbitration, retries & handshakes**: Arbitrate outgoing ARP/INARP Replies vs broadcast ARP Requests without dropping either frame or mutating `arp_eth_tx` `s_frame_*` while `s_frame_valid && !s_frame_ready`, and accept incoming non-reply frames even when `arp_eth_tx` is stalled. Support `REQUEST_RETRY_COUNT >= 1` total broadcast request transmissions per uncached lookup (`1` initial request plus `REQUEST_RETRY_COUNT - 1` retries at `REQUEST_RETRY_INTERVAL`, then `REQUEST_TIMEOUT` after the final request, including `REQUEST_RETRY_COUNT == 1` waiting `REQUEST_TIMEOUT` with zero retries), give a resolved cache hit/wakeup priority over `arp_request_timer == 0` on the same cycle, honor `arp_cache` ready signals across `rst`/`clear_cache`, and hold `arp_response_mac`/`arp_response_error` stable while `arp_response_valid && !arp_response_ready`.
4. **Synthesis & Gate-Level Reset Cleanliness**: Synthesize latch-free and combinational-loop-free across `DATA_WIDTH = 64` and `256`, with `0` `X`/`Z` on valid/ready/busy/error outputs and active qualifiers after `rst` when declaration initializers and `initial` blocks are stripped.

## Boundary Contract
Preserve all existing module names, parameters, and port signatures across `code/arp.v`, `code/arp_cache.v`, `code/arp_eth_rx.v`, and `code/arp_eth_tx.v` (`code/lfsr.v` and `code/LICENSE` are read-only).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Reference

## Workspace Files
- **Editable RTL**:
  - `code/arp.v` (`arp`)
  - `code/arp_cache.v` (`arp_cache`)
  - `code/arp_eth_rx.v` (`arp_eth_rx`)
  - `code/arp_eth_tx.v` (`arp_eth_tx`)
- **Read-Only Collateral**:
  - `code/lfsr.v` (`lfsr`)
  - `code/LICENSE`

## Toolchain Commands
1. **Icarus Verilog (`iverilog` v13)**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v <your_tb.sv>
   vvp sim.vvp
   ```
2. **Verilator (`verilator` v5.038)**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --binary --timing -Wno-fatal -j 1 --top-module <your_tb> \
     code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v <your_tb.sv>
   ```
3. **Yosys Latch / Loop / Gate-Level Netlist Check**:
   ```bash
   yosys -p "
     read_verilog -defer code/arp.v code/arp_cache.v code/arp_eth_rx.v code/arp_eth_tx.v code/lfsr.v;
     hierarchy -check -top arp -chparam DATA_WIDTH 256 -chparam CACHE_ADDR_WIDTH 3;
     proc; opt_expr; opt_clean; setattr -unset init w:*; flatten; opt_expr; opt_clean;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top arp;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v"
   ```

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add new simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`, including inside `initial` parameter-check blocks — preserve or omit existing parameter checks rather than adding new `$finish`/`$stop` calls), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/arp.v (Buggy Starter)
+++ b/solution/gold/code/arp.v (Golden Reference)
@@ -33,20 +33,12 @@
  */
 module arp #
 (
-    // Width of AXI stream interfaces in bits
     parameter DATA_WIDTH = 8,
-    // Propagate tkeep signal
-    // If disabled, tkeep assumed to be 1'b1
     parameter KEEP_ENABLE = (DATA_WIDTH>8),
-    // tkeep signal width (words per cycle)
     parameter KEEP_WIDTH = (DATA_WIDTH/8),
-    // Log2 of ARP cache size
     parameter CACHE_ADDR_WIDTH = 9,
-    // ARP request retry count
     parameter REQUEST_RETRY_COUNT = 4,
-    // ARP request retry interval (in cycles)
     parameter REQUEST_RETRY_INTERVAL = 125000000*2,
-    // ARP request timeout (in cycles)
     parameter REQUEST_TIMEOUT = 125000000*30
 )
 (
@@ -110,8 +102,19 @@
     ARP_OPER_INARP_REQUEST = 16'h0008,
     ARP_OPER_INARP_REPLY = 16'h0009;
 
+localparam [1:0]
+    LKP_IDLE       = 2'd0,
+    LKP_INIT_QUERY = 2'd1,
+    LKP_INIT_WAIT  = 2'd2,
+    LKP_WAIT_REPLY = 2'd3;
+
+localparam [1:0]
+    MRG_IDLE = 2'd0,
+    MRG_REQ  = 2'd1,
+    MRG_WAIT = 2'd2;
+
 wire incoming_frame_valid;
-reg incoming_frame_ready;
+reg  incoming_frame_ready;
 wire [47:0] incoming_eth_dest_mac;
 wire [47:0] incoming_eth_src_mac;
 wire [15:0] incoming_eth_type;
@@ -125,9 +128,6 @@
 wire [47:0] incoming_arp_tha;
 wire [31:0] incoming_arp_tpa;
 
-/*
- * ARP frame processing
- */
 arp_eth_rx #(
     .DATA_WIDTH(DATA_WIDTH),
     .KEEP_ENABLE(KEEP_ENABLE),
@@ -136,7 +136,6 @@
 arp_eth_rx_inst (
     .clk(clk),
     .rst(rst),
-    // Ethernet frame input
     .s_eth_hdr_valid(s_eth_hdr_valid),
     .s_eth_hdr_ready(s_eth_hdr_ready),
     .s_eth_dest_mac(s_eth_dest_mac),
@@ -148,7 +147,6 @@
     .s_eth_payload_axis_tready(s_eth_payload_axis_tready),
     .s_eth_payload_axis_tlast(s_eth_payload_axis_tlast),
     .s_eth_payload_axis_tuser(s_eth_payload_axis_tuser),
-    // ARP frame output
     .m_frame_valid(incoming_frame_valid),
     .m_frame_ready(incoming_frame_ready),
     .m_eth_dest_mac(incoming_eth_dest_mac),
@@ -163,7 +161,6 @@
     .m_arp_spa(incoming_arp_spa),
     .m_arp_tha(incoming_arp_tha),
     .m_arp_tpa(incoming_arp_tpa),
-    // Status signals
     .busy(),
     .error_header_early_termination(),
     .error_invalid_header()
@@ -184,7 +181,6 @@
 arp_eth_tx_inst (
     .clk(clk),
     .rst(rst),
-    // ARP frame input
     .s_frame_valid(outgoing_frame_valid_reg),
     .s_frame_ready(outgoing_frame_ready),
     .s_eth_dest_mac(outgoing_eth_dest_mac_reg),
@@ -197,7 +193,6 @@
     .s_arp_spa(local_ip),
     .s_arp_tha(outgoing_arp_tha_reg),
     .s_arp_tpa(outgoing_arp_tpa_reg),
-    // Ethernet frame output
     .m_eth_hdr_valid(m_eth_hdr_valid),
     .m_eth_hdr_ready(m_eth_hdr_ready),
     .m_eth_dest_mac(m_eth_dest_mac),
@@ -209,66 +204,141 @@
     .m_eth_payload_axis_tready(m_eth_payload_axis_tready),
     .m_eth_payload_axis_tlast(m_eth_payload_axis_tlast),
     .m_eth_payload_axis_tuser(m_eth_payload_axis_tuser),
-    // Status signals
     .busy()
 );
 
-reg cache_query_request_valid_reg = 1'b0, cache_query_request_valid_next;
+reg        cache_query_request_valid_reg = 1'b0, cache_query_request_valid_next;
+wire       cache_query_request_ready;
 reg [31:0] cache_query_request_ip_reg = 32'd0, cache_query_request_ip_next;
-wire cache_query_response_valid;
-wire cache_query_response_error;
+wire       cache_query_response_valid;
+wire       cache_query_response_error;
 wire [47:0] cache_query_response_mac;
 
-reg cache_write_request_valid_reg = 1'b0, cache_write_request_valid_next;
+reg        cache_write_request_valid_reg = 1'b0, cache_write_request_valid_next;
+wire       cache_write_request_ready;
 reg [31:0] cache_write_request_ip_reg = 32'd0, cache_write_request_ip_next;
 reg [47:0] cache_write_request_mac_reg = 48'd0, cache_write_request_mac_next;
 
-/*
- * ARP cache
- */
 arp_cache #(
     .CACHE_ADDR_WIDTH(CACHE_ADDR_WIDTH)
 )
 arp_cache_inst (
     .clk(clk),
     .rst(rst),
-    // Query cache
     .query_request_valid(cache_query_request_valid_reg),
-    .query_request_ready(),
+    .query_request_ready(cache_query_request_ready),
     .query_request_ip(cache_query_request_ip_reg),
     .query_response_valid(cache_query_response_valid),
     .query_response_ready(1'b1),
     .query_response_error(cache_query_response_error),
     .query_response_mac(cache_query_response_mac),
-    // Write cache
     .write_request_valid(cache_write_request_valid_reg),
-    .write_request_ready(),
+    .write_request_ready(cache_write_request_ready),
     .write_request_ip(cache_write_request_ip_reg),
     .write_request_mac(cache_write_request_mac_reg),
-    // Configuration
     .clear_cache(clear_cache)
 );
 
-reg arp_request_operation_reg = 1'b0, arp_request_operation_next;
-
-reg arp_request_ready_reg = 1'b0, arp_request_ready_next;
+reg [1:0]  lkp_state_reg = LKP_IDLE, lkp_state_next;
+reg        arp_request_ready_reg = 1'b0, arp_request_ready_next;
 reg [31:0] arp_request_ip_reg = 32'd0, arp_request_ip_next;
 
-reg arp_response_valid_reg = 1'b0, arp_response_valid_next;
-reg arp_response_error_reg = 1'b0, arp_response_error_next;
+reg        arp_response_valid_reg = 1'b0, arp_response_valid_next;
+reg        arp_response_error_reg = 1'b0, arp_response_error_next;
 reg [47:0] arp_response_mac_reg = 48'd0, arp_response_mac_next;
 
-reg [5:0] arp_request_retry_cnt_reg = 6'd0, arp_request_retry_cnt_next;
+reg [5:0]  arp_request_retry_cnt_reg = 6'd0, arp_request_retry_cnt_next;
 reg [35:0] arp_request_timer_reg = 36'd0, arp_request_timer_next;
 
+reg        lkp_wakeup_valid_reg = 1'b0, lkp_wakeup_valid_next;
+reg [47:0] lkp_wakeup_mac_reg = 48'd0, lkp_wakeup_mac_next;
+
+reg [1:0]  mrg_state_reg = MRG_IDLE, mrg_state_next;
+reg [31:0] mrg_ip_reg = 32'd0, mrg_ip_next;
+reg [47:0] mrg_mac_reg = 48'd0, mrg_mac_next;
+
+reg [3:0]  q_tag_mem_reg = 4'd0, q_tag_mem_next;
+reg [1:0]  q_wr_ptr_reg = 2'd0, q_wr_ptr_next;
+reg [1:0]  q_rd_ptr_reg = 2'd0, q_rd_ptr_next;
+reg        cur_q_is_mrg_reg = 1'b0, cur_q_is_mrg_next;
+
+reg        reply_pending_reg = 1'b0, reply_pending_next;
+reg [47:0] reply_eth_dest_reg = 48'd0, reply_eth_dest_next;
+reg [15:0] reply_oper_reg = 16'd0, reply_oper_next;
+reg [47:0] reply_tha_reg = 48'd0, reply_tha_next;
+reg [31:0] reply_tpa_reg = 32'd0, reply_tpa_next;
+
+reg        req_tx_pending_reg = 1'b0, req_tx_pending_next;
+reg [31:0] req_tx_ip_reg = 32'd0, req_tx_ip_next;
+
 assign arp_request_ready = arp_request_ready_reg;
-
 assign arp_response_valid = arp_response_valid_reg;
 assign arp_response_error = arp_response_error_reg;
 assign arp_response_mac = arp_response_mac_reg;
 
+wire in_proto_ok = (incoming_eth_type == 16'h0806) &&
+                   (incoming_arp_htype == 16'h0001) &&
+                   (incoming_arp_ptype == 16'h0800) &&
+                   ((incoming_arp_oper == ARP_OPER_ARP_REQUEST) ||
+                    (incoming_arp_oper == ARP_OPER_ARP_REPLY) ||
+                    (incoming_arp_oper == ARP_OPER_INARP_REQUEST) ||
+                    (incoming_arp_oper == ARP_OPER_INARP_REPLY));
+
+wire in_sha_valid = (incoming_arp_sha != 48'd0) && !incoming_arp_sha[40];
+wire in_spa_valid = (incoming_arp_spa != 32'd0) &&
+                    (incoming_arp_spa != 32'hFFFF_FFFF) &&
+                    (incoming_arp_spa[31:28] != 4'hE);
+
+wire in_need_arp_reply   = in_proto_ok && in_sha_valid && (incoming_arp_oper == ARP_OPER_ARP_REQUEST) && (incoming_arp_tpa == local_ip);
+wire in_need_inarp_reply = in_proto_ok && in_sha_valid && (incoming_arp_oper == ARP_OPER_INARP_REQUEST) && (incoming_arp_tha == local_mac);
+wire in_need_reply       = in_need_arp_reply || in_need_inarp_reply;
+
+wire in_targeted = (((incoming_arp_oper == ARP_OPER_ARP_REQUEST) || (incoming_arp_oper == ARP_OPER_ARP_REPLY)) && (incoming_arp_tpa == local_ip)) ||
+                   (((incoming_arp_oper == ARP_OPER_INARP_REQUEST) || (incoming_arp_oper == ARP_OPER_INARP_REPLY)) && (incoming_arp_tha == local_mac));
+
+wire tx_port_free = !outgoing_frame_valid_reg || outgoing_frame_ready;
+wire wr_port_free = !cache_write_request_valid_reg || cache_write_request_ready;
+wire q_port_free  = !cache_query_request_valid_reg || cache_query_request_ready;
+
+wire resp_is_mrg = q_tag_mem_reg[q_rd_ptr_reg];
+
 always @* begin
-    incoming_frame_ready = 1'b0;
+    lkp_state_next = lkp_state_reg;
+    arp_request_ip_next = arp_request_ip_reg;
+    arp_request_retry_cnt_next = arp_request_retry_cnt_reg;
+    arp_request_timer_next = arp_request_timer_reg;
+
+    arp_response_valid_next = arp_response_valid_reg && !arp_response_ready;
+    arp_response_error_next = arp_response_error_reg;
+    arp_response_mac_next = arp_response_mac_reg;
+
+    lkp_wakeup_valid_next = lkp_wakeup_valid_reg;
+    lkp_wakeup_mac_next = lkp_wakeup_mac_reg;
+
+    mrg_state_next = mrg_state_reg;
+    mrg_ip_next = mrg_ip_reg;
+    mrg_mac_next = mrg_mac_reg;
+
+    cache_query_request_valid_next = cache_query_request_valid_reg && !cache_query_request_ready;
+    cache_query_request_ip_next = cache_query_request_ip_reg;
+    cur_q_is_mrg_next = cur_q_is_mrg_reg;
+
+    q_tag_mem_next = q_tag_mem_reg;
+    q_wr_ptr_next = q_wr_ptr_reg;
+    q_rd_ptr_next = q_rd_ptr_reg;
+
+    cache_write_request_valid_next = cache_write_request_valid_reg && !cache_write_request_ready;
+    cache_write_request_ip_next = cache_write_request_ip_reg;
+    cache_write_request_mac_next = cache_write_request_mac_reg;
+
+    reply_pending_next = reply_pending_reg;
+    reply_eth_dest_next = reply_eth_dest_reg;
+    reply_oper_next = reply_oper_reg;
+    reply_tha_next = reply_tha_reg;
+    reply_tpa_next = reply_tpa_reg;
+
+    req_tx_pending_next = req_tx_pending_reg;
+    req_tx_ip_next = req_tx_ip_reg;
 
     outgoing_frame_valid_next = outgoing_frame_valid_reg && !outgoing_frame_ready;
     outgoing_eth_dest_mac_next = outgoing_eth_dest_mac_reg;
@@ -276,177 +346,272 @@
     outgoing_arp_tha_next = outgoing_arp_tha_reg;
     outgoing_arp_tpa_next = outgoing_arp_tpa_reg;
 
-    cache_query_request_valid_next = 1'b0;
-    cache_query_request_ip_next = cache_query_request_ip_reg;
-
-    cache_write_request_valid_next = 1'b0;
-    cache_write_request_mac_next = cache_write_request_mac_reg;
-    cache_write_request_ip_next = cache_write_request_ip_reg;
-
-    arp_request_ready_next = 1'b0;
-    arp_request_ip_next = arp_request_ip_reg;
-    arp_request_operation_next = arp_request_operation_reg;
-    arp_request_retry_cnt_next = arp_request_retry_cnt_reg;
-    arp_request_timer_next = arp_request_timer_reg;
-    arp_response_valid_next = arp_response_valid_reg && !arp_response_ready;
-    arp_response_error_next = 1'b0;
-    arp_response_mac_next = 48'd0;
-
-    // manage incoming frames
-    incoming_frame_ready = outgoing_frame_ready;
+    if (cache_query_request_valid_reg && cache_query_request_ready) begin
+        q_tag_mem_next[q_wr_ptr_reg] = cur_q_is_mrg_reg;
+        q_wr_ptr_next = q_wr_ptr_reg + 2'd1;
+    end
+
+    if (cache_query_response_valid) begin
+        q_rd_ptr_next = q_rd_ptr_reg + 2'd1;
+        if (resp_is_mrg && (mrg_state_reg == MRG_WAIT)) begin
+            mrg_state_next = MRG_IDLE;
+            if (!cache_query_response_error) begin
+                cache_write_request_valid_next = 1'b1;
+                cache_write_request_ip_next = mrg_ip_reg;
+                cache_write_request_mac_next = mrg_mac_reg;
+            end
+        end
+    end
+
+    // Accept incoming frame when write/merge path is free and (if reply needed) reply buffer is free
+    incoming_frame_ready = (mrg_state_reg == MRG_IDLE) && !cache_write_request_valid_next &&
+                           (!in_need_reply || !reply_pending_reg || tx_port_free);
+
     if (incoming_frame_valid && incoming_frame_ready) begin
-        if (incoming_eth_type == 16'h0806 && incoming_arp_htype == 16'h0001 && incoming_arp_ptype == 16'h0800) begin
-            // store sender addresses in cache
-            cache_write_request_valid_next = 1'b1;
-            cache_write_request_ip_next = incoming_arp_spa;
-            cache_write_request_mac_next = incoming_arp_sha;
-            if (incoming_arp_oper == ARP_OPER_ARP_REQUEST) begin
-                // ARP request
-                if (incoming_arp_tpa == local_ip) begin
-                    // send reply frame to valid incoming request
-                    outgoing_frame_valid_next = 1'b1;
-                    outgoing_eth_dest_mac_next = incoming_eth_src_mac;
-                    outgoing_arp_oper_next = ARP_OPER_ARP_REPLY;
-                    outgoing_arp_tha_next = incoming_arp_sha;
-                    outgoing_arp_tpa_next = incoming_arp_spa;
-                end
-            end else if (incoming_arp_oper == ARP_OPER_INARP_REQUEST) begin
-                // INARP request
-                if (incoming_arp_tha == local_mac) begin
-                    // send reply frame to valid incoming request
-                    outgoing_frame_valid_next = 1'b1;
-                    outgoing_eth_dest_mac_next = incoming_eth_src_mac;
-                    outgoing_arp_oper_next = ARP_OPER_INARP_REPLY;
-                    outgoing_arp_tha_next = incoming_arp_sha;
-                    outgoing_arp_tpa_next = incoming_arp_spa;
-                end 
-            end
-        end
-    end
-
-    // manage ARP lookup requests
-    if (arp_request_operation_reg) begin
-        arp_request_ready_next = 1'b0;
-        cache_query_request_valid_next = 1'b1;
-        arp_request_timer_next = arp_request_timer_reg - 1;
-        // if we got a response, it will go in the cache, so when the query succeds, we're done
-        if (cache_query_response_valid && !cache_query_response_error) begin
-            arp_request_operation_next = 1'b0;
-            cache_query_request_valid_next = 1'b0;
-            arp_response_valid_next = 1'b1;
-            arp_response_error_next = 1'b0;
-            arp_response_mac_next = cache_query_response_mac;
-        end
-        // timer timeout
-        if (arp_request_timer_reg == 0) begin
-            if (arp_request_retry_cnt_reg > 0) begin
-                // have more retries
-                // send ARP request frame
-                outgoing_frame_valid_next = 1'b1;
-                outgoing_eth_dest_mac_next = 48'hffffffffffff;
-                outgoing_arp_oper_next = ARP_OPER_ARP_REQUEST;
-                outgoing_arp_tha_next = 48'h000000000000;
-                outgoing_arp_tpa_next = arp_request_ip_reg;
-                arp_request_retry_cnt_next = arp_request_retry_cnt_reg - 1;
-                if (arp_request_retry_cnt_reg > 1) begin
-                    arp_request_timer_next = REQUEST_RETRY_INTERVAL;
-                end else begin
-                    arp_request_timer_next = REQUEST_TIMEOUT;
+        if (in_need_arp_reply) begin
+            reply_pending_next = 1'b1;
+            reply_eth_dest_next = incoming_eth_src_mac;
+            reply_oper_next = ARP_OPER_ARP_REPLY;
+            reply_tha_next = incoming_arp_sha;
+            reply_tpa_next = incoming_arp_spa;
+        end else if (in_need_inarp_reply) begin
+            reply_pending_next = 1'b1;
+            reply_eth_dest_next = incoming_eth_src_mac;
+            reply_oper_next = ARP_OPER_INARP_REPLY;
+            reply_tha_next = incoming_arp_sha;
+            reply_tpa_next = incoming_arp_spa;
+        end
+
+        if (in_proto_ok && in_sha_valid && in_spa_valid) begin
+            if (in_targeted || ((lkp_state_reg != LKP_IDLE) && (incoming_arp_spa == arp_request_ip_reg))) begin
+                cache_write_request_valid_next = 1'b1;
+                cache_write_request_ip_next = incoming_arp_spa;
+                cache_write_request_mac_next = incoming_arp_sha;
+                if ((lkp_state_reg != LKP_IDLE) && (incoming_arp_spa == arp_request_ip_reg)) begin
+                    lkp_wakeup_valid_next = 1'b1;
+                    lkp_wakeup_mac_next = incoming_arp_sha;
                 end
             end else begin
-                // out of retries
-                arp_request_operation_next = 1'b0;
+                mrg_state_next = MRG_REQ;
+                mrg_ip_next = incoming_arp_spa;
+                mrg_mac_next = incoming_arp_sha;
+            end
+        end
+    end
+
+    // Issue pending cache query (MERGE probe or initial LOOKUP check)
+    if (!cache_query_request_valid_next && !cache_write_request_valid_next) begin
+        if (mrg_state_next == MRG_REQ) begin
+            cache_query_request_valid_next = 1'b1;
+            cache_query_request_ip_next = mrg_ip_next;
+            cur_q_is_mrg_next = 1'b1;
+            mrg_state_next = MRG_WAIT;
+        end else if ((lkp_state_reg == LKP_INIT_QUERY) && !lkp_wakeup_valid_next) begin
+            cache_query_request_valid_next = 1'b1;
+            cache_query_request_ip_next = arp_request_ip_reg;
+            cur_q_is_mrg_next = 1'b0;
+            lkp_state_next = LKP_INIT_WAIT;
+        end
+    end
+
+    // Lookup state machine
+    case (lkp_state_reg)
+        LKP_IDLE: begin
+            if (arp_request_valid && arp_request_ready) begin
+                lkp_wakeup_valid_next = 1'b0;
+                if ((arp_request_ip == 32'hFFFF_FFFF) ||
+                    ((subnet_mask != 32'hFFFF_FFFF) &&
+                     (((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0) &&
+                     ((arp_request_ip | subnet_mask) == 32'hFFFF_FFFF))) begin
+                    arp_response_valid_next = 1'b1;
+                    arp_response_error_next = 1'b0;
+                    arp_response_mac_next = 48'hFFFF_FFFF_FFFF;
+                end else if (arp_request_ip[31:28] == 4'hE) begin
+                    arp_response_valid_next = 1'b1;
+                    arp_response_error_next = 1'b0;
+                    arp_response_mac_next = {24'h01_00_5E, 1'b0, arp_request_ip[22:0]};
+                end else if (((arp_request_ip ^ local_ip) & subnet_mask) == 32'd0) begin
+                    arp_request_ip_next = arp_request_ip;
+                    lkp_state_next = LKP_INIT_QUERY;
+                end else if (gateway_ip == 32'd0) begin
+                    arp_response_valid_next = 1'b1;
+                    arp_response_error_next = 1'b1;
+                    arp_response_mac_next = 48'd0;
+                end else begin
+                    arp_request_ip_next = gateway_ip;
+                    lkp_state_next = LKP_INIT_QUERY;
+                end
+            end
+        end
+
+        LKP_INIT_QUERY: begin
+            // Handled above when query port is free; if woken early before query launched, resolve!
+            if (lkp_wakeup_valid_next && !arp_response_valid_next) begin
                 arp_response_valid_next = 1'b1;
-                arp_response_error_next = 1'b1;
-                cache_query_request_valid_next = 1'b0;
+                arp_response_error_next = 1'b0;
+                arp_response_mac_next = lkp_wakeup_mac_next;
+                lkp_wakeup_valid_next = 1'b0;
+                lkp_state_next = LKP_IDLE;
             end
         end
-    end else begin
-        arp_request_ready_next = !arp_response_valid_next;
-        if (cache_query_request_valid_reg) begin
-            cache_query_request_valid_next = 1'b1;
-            if (cache_query_response_valid) begin
-                if (cache_query_response_error) begin
-                    arp_request_operation_next = 1'b1;
-                    // send ARP request frame
-                    outgoing_frame_valid_next = 1'b1;
-                    outgoing_eth_dest_mac_next = 48'hffffffffffff;
-                    outgoing_arp_oper_next = ARP_OPER_ARP_REQUEST;
-                    outgoing_arp_tha_next = 48'h000000000000;
-                    outgoing_arp_tpa_next = arp_request_ip_reg;
-                    arp_request_retry_cnt_next = REQUEST_RETRY_COUNT-1;
-                    arp_request_timer_next = REQUEST_RETRY_INTERVAL;
-                end else begin
-                    cache_query_request_valid_next = 1'b0;
+
+        LKP_INIT_WAIT: begin
+            if (cache_query_response_valid && !resp_is_mrg) begin
+                if (lkp_wakeup_valid_next) begin
+                    arp_response_valid_next = 1'b1;
+                    arp_response_error_next = 1'b0;
+                    arp_response_mac_next = lkp_wakeup_mac_next;
+                    lkp_wakeup_valid_next = 1'b0;
+                    lkp_state_next = LKP_IDLE;
+                end else if (!cache_query_response_error) begin
                     arp_response_valid_next = 1'b1;
                     arp_response_error_next = 1'b0;
                     arp_response_mac_next = cache_query_response_mac;
+                    lkp_state_next = LKP_IDLE;
+                end else begin
+                    req_tx_pending_next = 1'b1;
+                    req_tx_ip_next = arp_request_ip_reg;
+                    if (REQUEST_RETRY_COUNT > 1) begin
+                        arp_request_retry_cnt_next = REQUEST_RETRY_COUNT - 1;
+                        arp_request_timer_next = REQUEST_RETRY_INTERVAL;
+                    end else begin
+                        arp_request_retry_cnt_next = 6'd0;
+                        arp_request_timer_next = REQUEST_TIMEOUT;
+                    end
+                    lkp_state_next = LKP_WAIT_REPLY;
                 end
             end
-        end else if (arp_request_valid && arp_request_ready) begin
-            if (arp_request_ip == 32'hffffffff) begin
-                // broadcast address; use broadcast MAC address
-                arp_response_valid_next = 1'b1;
-                arp_response_error_next = 1'b0;
-                arp_response_mac_next = 48'hffffffffffff;
-            end else if (((arp_request_ip ^ gateway_ip) & subnet_mask) == 0) begin
-                // within subnet
-                // (no bits differ between request IP and gateway IP where subnet mask is set)
-                if (~(arp_request_ip | subnet_mask) == 0) begin
-                    // broadcast address; use broadcast MAC address
-                    // (all bits in request IP set where subnet mask is clear)
+        end
+
+        LKP_WAIT_REPLY: begin
+            if (lkp_wakeup_valid_next) begin
+                if (!arp_response_valid_next) begin
                     arp_response_valid_next = 1'b1;
                     arp_response_error_next = 1'b0;
-                    arp_response_mac_next = 48'hffffffffffff;
-                end else begin
-                    // unicast address; look up IP directly
-                    cache_query_request_valid_next = 1'b1;
-                    cache_query_request_ip_next = arp_request_ip;
-                    arp_request_ip_next = arp_request_ip;
+                    arp_response_mac_next = lkp_wakeup_mac_next;
+                    lkp_wakeup_valid_next = 1'b0;
+                    req_tx_pending_next = 1'b0;
+                    lkp_state_next = LKP_IDLE;
+                end
+            end else if (arp_request_timer_reg == 36'd0) begin
+                if (arp_request_retry_cnt_reg > 6'd0) begin
+                    req_tx_pending_next = 1'b1;
+                    req_tx_ip_next = arp_request_ip_reg;
+                    arp_request_retry_cnt_next = arp_request_retry_cnt_reg - 6'd1;
+                    if (arp_request_retry_cnt_reg > 6'd1) begin
+                        arp_request_timer_next = REQUEST_RETRY_INTERVAL;
+                    end else begin
+                        arp_request_timer_next = REQUEST_TIMEOUT;
+                    end
+                end else if (!arp_response_valid_next) begin
+                    arp_response_valid_next = 1'b1;
+                    arp_response_error_next = 1'b1;
+                    arp_response_mac_next = 48'd0;
+                    lkp_state_next = LKP_IDLE;
                 end
             end else begin
-                // outside of subnet, so look up gateway address
-                cache_query_request_valid_next = 1'b1;
-                cache_query_request_ip_next = gateway_ip;
-                arp_request_ip_next = gateway_ip;
+                arp_request_timer_next = arp_request_timer_reg - 36'd1;
             end
         end
+    endcase
+
+    // Outgoing TX frame arbiter (strict valid/ready stability; Reply prioritized over Request)
+    if (tx_port_free) begin
+        if (reply_pending_next) begin
+            outgoing_frame_valid_next = 1'b1;
+            outgoing_eth_dest_mac_next = reply_eth_dest_next;
+            outgoing_arp_oper_next = reply_oper_next;
+            outgoing_arp_tha_next = reply_tha_next;
+            outgoing_arp_tpa_next = reply_tpa_next;
+            reply_pending_next = 1'b0;
+        end else if (req_tx_pending_next) begin
+            outgoing_frame_valid_next = 1'b1;
+            outgoing_eth_dest_mac_next = 48'hFFFF_FFFF_FFFF;
+            outgoing_arp_oper_next = ARP_OPER_ARP_REQUEST;
+            outgoing_arp_tha_next = 48'h0000_0000_0000;
+            outgoing_arp_tpa_next = req_tx_ip_nex
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/arp.v`](environment/public/code/arp.v) **(Editable)**
- [`environment/public/code/arp_cache.v`](environment/public/code/arp_cache.v) **(Editable)**
- [`environment/public/code/arp_eth_rx.v`](environment/public/code/arp_eth_rx.v) **(Editable)**
- [`environment/public/code/arp_eth_tx.v`](environment/public/code/arp_eth_tx.v) **(Editable)**
- [`environment/public/code/lfsr.v`](environment/public/code/lfsr.v) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

