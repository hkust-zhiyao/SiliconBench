# `case_21021`: External-Memory AXI4 Virtual FIFO Write-Commit Ordering, Drain Accounting, and Soft-Flush Recovery

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21021` |
| **Source Silicon Repository** | `alexforencich/verilog-axi` (`repo_40`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/axi_vfifo.v`](environment/public/code/axi_vfifo.v), [`code/axi_vfifo_enc.v`](environment/public/code/axi_vfifo_enc.v), [`code/axi_vfifo_dec.v`](environment/public/code/axi_vfifo_dec.v), [`code/axi_vfifo_raw.v`](environment/public/code/axi_vfifo_raw.v), [`code/axi_vfifo_raw_wr.v`](environment/public/code/axi_vfifo_raw_wr.v), [`code/axi_vfifo_raw_rd.v`](environment/public/code/axi_vfifo_raw_rd.v) (6 files, 3653 LOC) |
| **Public Subsystem Context** | 6 RTL files (3653 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# External-Memory AXI4 Virtual FIFO Write-Commit Ordering, Drain Accounting, and Soft-Flush Recovery

## Problem Description
In our SmartNIC packet-buffering subsystem (`axi_vfifo` and its encoder, decoder, and raw channel engines), variable-length AXI-Stream frames (`TDATA`, `TKEEP`, `TLAST`, `TID`, `TDEST`, `TUSER`) are segmented, buffered across one or more external DRAM rings over AXI4 master channels (`m_axi_*`), and reconstructed on `m_axis_*`. Integration testing against multi-bank AXI4 memory controllers and ASIC gate-level signoff exposed four protocol and control-plane failures:

1. **AXI4 Write-Commit Visibility & Response FIFO Integrity (`m_axi_*`)**: External memory controllers buffer AXI write bursts until the write-response handshake (`m_axi_bvalid && m_axi_bready`) completes, so any `m_axi_ar*` read issued before write-response commit returns stale DRAM data. In addition, `m_axi_bvalid` asserted while `m_axi_bready` is low, single-cycle `B` responses immediately following short write bursts, or >32 outstanding write bursts under high `B`-channel latency corrupt write-completion pointer tracking and burst-length accounting.
2. **Premature `sts_fifo_empty` & Unknown `sts_fifo_occupancy`**: `sts_fifo_empty` currently reflects only external ring pointers and falsely asserts `1` while packet data is still buffered in the ingress encoder, per-channel write FIFOs (awaiting burst timeout), uncommitted/in-flight AXI bursts, per-channel read/control FIFOs, or egress decoder (`m_axis_tvalid` stalled by `m_axis_tready == 0`). Each channel's `sts_fifo_empty[n]` must assert `1` only when ingress encoding, channel `n` write/DRAM/read pipelines, and egress decoding are completely drained.
3. **Soft `cfg_reset` Pulse & Ring Reconfiguration Across Clock Ratios**: A `cfg_reset` assertion (including a single-`clk`-cycle pulse while `cfg_enable` stays high, across equal or asynchronous `clk`, `s_axis_clk`, `m_axis_clk`, and `m_axi_clk` rates) can be missed or re-enabled before in-flight AXI bursts finish draining. A `cfg_reset` request must reliably force every channel into reset, complete any in-flight AXI4 bursts cleanly without leaking pre-flush fragments onto `m_axis_*`, latch updated `cfg_fifo_base_addr` / `cfg_fifo_size_mask` values, and re-enable streaming only after reset flush completes.
4. **Segment Watermark Flow Control & ASIC Reset Cleanliness**: Under sustained AXI backpressure or compact `WRITE_FIFO_DEPTH` settings (`>= 16`) with multi-segment channels (`CH_SEG_CNT >= 2`, `AXI_CH >= 1`), internal segment flow control must never overflow channel write FIFOs or trigger spurious `sts_hdr_parity_err`. All six modules must synthesize without latches or conflicting drivers and reset deterministically with zero `X`/`Z` outputs when declaration initializers are stripped.

## Boundary Contract
Preserve the exact top-level `axi_vfifo` module name, parameters, and port interface across `code/axi_vfifo*.v`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Guide

## Workspace Layout
- **Editable RTL**:
  - `code/axi_vfifo.v`
  - `code/axi_vfifo_enc.v`
  - `code/axi_vfifo_dec.v`
  - `code/axi_vfifo_raw.v`
  - `code/axi_vfifo_raw_wr.v`
  - `code/axi_vfifo_raw_rd.v`
- **Read-Only Collateral** (must remain unmodified):
  - `code/COPYING`

## Toolchain Commands
1. **Icarus Verilog Compilation & Simulation**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp <your_tb.sv> \
     code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v \
     code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v
   vvp sim.vvp
   ```

2. **Verilator Lint & Simulation**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --lint-only -Wall -Wno-fatal --top-module axi_vfifo \
     code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v \
     code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v
   ```

3. **Yosys Synthesis, Loop/Latch Check & Initializer-Stripped Gate-Level Netlist**:
   ```bash
   yosys -p "
     read_verilog -defer -sv code/axi_vfifo_enc.v code/axi_vfifo_dec.v code/axi_vfifo_raw_wr.v code/axi_vfifo_raw_rd.v code/axi_vfifo_raw.v code/axi_vfifo.v;
     hierarchy -check -top axi_vfifo -chparam AXI_CH 1 -chparam AXI_DATA_WIDTH 64 -chparam AXI_STRB_WIDTH 8 -chparam AXI_ADDR_WIDTH 10 -chparam LEN_WIDTH 10 -chparam AXIS_DATA_WIDTH 32 -chparam AXIS_KEEP_WIDTH 4 -chparam MAX_SEG_WIDTH 32 -chparam WRITE_FIFO_DEPTH 16 -chparam WRITE_MAX_BURST_LEN 4 -chparam READ_FIFO_DEPTH 32 -chparam READ_MAX_BURST_LEN 4;
     proc; opt_expr; opt_clean; setattr -unset init w:*; flatten; opt_expr; opt_clean;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top axi_vfifo;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v
   "
   ```
   Simulate `netlist.v` with `/opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v` (in grading, `$error(` inside upstream `initial` parameter assertions is sanitized to `$display(` prior to Yosys elaboration).

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axi_vfifo.v (Buggy Starter)
+++ b/solution/gold/code/axi_vfifo.v (Golden Reference)
@@ -191,33 +191,8 @@
 wire [SEG_CNT-1:0]            ch_output_ctrl_ready;
 
 wire [AXI_CH-1:0] ch_rst_req;
-
-// config management
-reg [AXI_CH*AXI_ADDR_WIDTH-1:0] cfg_fifo_base_addr_reg = 0;
-reg [LEN_WIDTH-1:0] cfg_fifo_size_mask_reg = 0;
-reg cfg_enable_reg = 0;
-reg cfg_reset_reg = 0;
-
-always @(posedge clk) begin
-    if (cfg_enable_reg) begin
-        if (cfg_reset) begin
-            cfg_enable_reg <= 1'b0;
-        end
-    end else begin
-        if (cfg_enable) begin
-            cfg_enable_reg <= 1'b1;
-        end
-        cfg_fifo_base_addr_reg <= cfg_fifo_base_addr;
-        cfg_fifo_size_mask_reg <= cfg_fifo_size_mask;
-    end
-
-    cfg_reset_reg <= cfg_reset;
-
-    if (rst) begin
-        cfg_enable_reg <= 0;
-        cfg_reset_reg <= 0;
-    end
-end
+wire enc_empty;
+wire dec_empty;
 
 // status sync
 wire [AXI_CH*(LEN_WIDTH+1)-1:0] sts_fifo_occupancy_int;
@@ -229,24 +204,68 @@
 reg [3:0] sts_hdr_parity_err_cnt_reg = 0;
 reg sts_hdr_parity_err_reg = 1'b0;
 
-reg [2:0] sts_sync_count_reg = 0;
-reg sts_sync_flag_reg = 1'b0;
-
 (* shreg_extract = "no" *)
 reg [AXI_CH*(LEN_WIDTH+1)-1:0] sts_fifo_occupancy_sync_reg = 0;
 (* shreg_extract = "no" *)
-reg [AXI_CH-1:0] sts_fifo_empty_sync_1_reg = 0, sts_fifo_empty_sync_2_reg = 0;
+reg [AXI_CH-1:0] sts_fifo_empty_sync_1_reg = {AXI_CH{1'b1}}, sts_fifo_empty_sync_2_reg = {AXI_CH{1'b1}};
 (* shreg_extract = "no" *)
 reg [AXI_CH-1:0] sts_fifo_full_sync_1_reg = 0, sts_fifo_full_sync_2_reg = 0;
 (* shreg_extract = "no" *)
-reg [AXI_CH-1:0] sts_reset_sync_1_reg = 0, sts_reset_sync_2_reg = 0;
+reg [AXI_CH-1:0] sts_reset_sync_1_reg = {AXI_CH{1'b1}}, sts_reset_sync_2_reg = {AXI_CH{1'b1}};
 (* shreg_extract = "no" *)
 reg [AXI_CH-1:0] sts_active_sync_1_reg = 0, sts_active_sync_2_reg = 0;
 (* shreg_extract = "no" *)
 reg sts_hdr_parity_err_sync_1_reg = 0, sts_hdr_parity_err_sync_2_reg = 0;
+(* shreg_extract = "no" *)
+reg enc_empty_sync_1_reg = 1'b1, enc_empty_sync_2_reg = 1'b1;
+(* shreg_extract = "no" *)
+reg dec_empty_sync_1_reg = 1'b1, dec_empty_sync_2_reg = 1'b1;
+(* shreg_extract = "no" *)
+reg s_axis_rst_sync_1_reg = 1'b1, s_axis_rst_sync_2_reg = 1'b1;
+(* shreg_extract = "no" *)
+reg m_axis_rst_sync_1_reg = 1'b1, m_axis_rst_sync_2_reg = 1'b1;
+
+wire [AXI_CH-1:0] ch_occ_ack;
+reg [AXI_CH-1:0] occ_req_reg = 0;
+(* shreg_extract = "no" *)
+reg [AXI_CH-1:0] occ_ack_sync_1_reg = 0, occ_ack_sync_2_reg = 0;
+
+// config management
+reg [AXI_CH*AXI_ADDR_WIDTH-1:0] cfg_fifo_base_addr_reg = 0;
+reg [LEN_WIDTH-1:0] cfg_fifo_size_mask_reg = 0;
+reg cfg_enable_reg = 1'b0;
+reg cfg_reset_reg = 1'b1;
+
+wire all_in_reset = (&sts_reset_sync_2_reg) && s_axis_rst_sync_2_reg && m_axis_rst_sync_2_reg;
+wire all_out_of_reset = (|sts_reset_sync_2_reg == 1'b0) && !s_axis_rst_sync_2_reg && !m_axis_rst_sync_2_reg;
+
+always @(posedge clk) begin
+    if (cfg_reset) begin
+        cfg_reset_reg <= 1'b1;
+        cfg_enable_reg <= 1'b0;
+    end else if (cfg_reset_reg) begin
+        cfg_enable_reg <= 1'b0;
+        if (all_in_reset) begin
+            cfg_reset_reg <= 1'b0;
+        end
+    end else if (!cfg_enable_reg) begin
+        cfg_fifo_base_addr_reg <= cfg_fifo_base_addr;
+        cfg_fifo_size_mask_reg <= cfg_fifo_size_mask;
+        if (cfg_enable && all_out_of_reset) begin
+            cfg_enable_reg <= 1'b1;
+        end
+    end
+
+    if (rst) begin
+        cfg_fifo_base_addr_reg <= 0;
+        cfg_fifo_size_mask_reg <= 0;
+        cfg_enable_reg <= 1'b0;
+        cfg_reset_reg <= 1'b1;
+    end
+end
 
 assign sts_fifo_occupancy = sts_fifo_occupancy_sync_reg;
-assign sts_fifo_empty = sts_fifo_empty_sync_2_reg;
+assign sts_fifo_empty = sts_fifo_empty_sync_2_reg & {AXI_CH{enc_empty_sync_2_reg & dec_empty_sync_2_reg}};
 assign sts_fifo_full = sts_fifo_full_sync_2_reg;
 assign sts_reset = sts_reset_sync_2_reg;
 assign sts_active = sts_active_sync_2_reg;
@@ -264,18 +283,24 @@
         sts_hdr_parity_err_cnt_reg <= 4'hf;
     end
 
-    if (m_axis_rst) begin
+    if (m_axis_rst || m_axis_rst_out) begin
         sts_hdr_parity_err_cnt_reg <= 4'h0;
         sts_hdr_parity_err_reg <= 1'b0;
     end
 end
 
+integer ch_idx;
+
 always @(posedge clk) begin
-    sts_sync_count_reg <= sts_sync_count_reg + 1;
-
-    if (sts_sync_count_reg == 0) begin
-        sts_sync_flag_reg <= !sts_sync_flag_reg;
-        sts_fifo_occupancy_sync_reg <= sts_fifo_occupancy_int;
+    ch_idx = 0;
+    occ_ack_sync_1_reg <= ch_occ_ack;
+    occ_ack_sync_2_reg <= occ_ack_sync_1_reg;
+
+    for (ch_idx = 0; ch_idx < AXI_CH; ch_idx = ch_idx + 1) begin
+        if (occ_ack_sync_2_reg[ch_idx] == occ_req_reg[ch_idx]) begin
+            sts_fifo_occupancy_sync_reg[(LEN_WIDTH+1)*ch_idx +: (LEN_WIDTH+1)] <= sts_fifo_occupancy_int[(LEN_WIDTH+1)*ch_idx +: (LEN_WIDTH+1)];
+            occ_req_reg[ch_idx] <= ~occ_req_reg[ch_idx];
+        end
     end
 
     sts_fifo_empty_sync_1_reg <= sts_fifo_empty_int;
@@ -288,6 +313,39 @@
     sts_active_sync_2_reg <= sts_active_sync_1_reg;
     sts_hdr_parity_err_sync_1_reg <= sts_hdr_parity_err_reg;
     sts_hdr_parity_err_sync_2_reg <= sts_hdr_parity_err_sync_1_reg;
+    enc_empty_sync_1_reg <= enc_empty;
+    enc_empty_sync_2_reg <= enc_empty_sync_1_reg;
+    dec_empty_sync_1_reg <= dec_empty;
+    dec_empty_sync_2_reg <= dec_empty_sync_1_reg;
+    s_axis_rst_sync_1_reg <= s_axis_rst_out;
+    s_axis_rst_sync_2_reg <= s_axis_rst_sync_1_reg;
+    m_axis_rst_sync_1_reg <= m_axis_rst_out;
+    m_axis_rst_sync_2_reg <= m_axis_rst_sync_1_reg;
+
+    if (rst) begin
+        occ_req_reg <= 0;
+        occ_ack_sync_1_reg <= 0;
+        occ_ack_sync_2_reg <= 0;
+        sts_fifo_occupancy_sync_reg <= 0;
+        sts_fifo_empty_sync_1_reg <= {AXI_CH{1'b1}};
+        sts_fifo_empty_sync_2_reg <= {AXI_CH{1'b1}};
+        sts_fifo_full_sync_1_reg <= 0;
+        sts_fifo_full_sync_2_reg <= 0;
+        sts_reset_sync_1_reg <= {AXI_CH{1'b1}};
+        sts_reset_sync_2_reg <= {AXI_CH{1'b1}};
+        sts_active_sync_1_reg <= 0;
+        sts_active_sync_2_reg <= 0;
+        sts_hdr_parity_err_sync_1_reg <= 1'b0;
+        sts_hdr_parity_err_sync_2_reg <= 1'b0;
+        enc_empty_sync_1_reg <= 1'b1;
+        enc_empty_sync_2_reg <= 1'b1;
+        dec_empty_sync_1_reg <= 1'b1;
+        dec_empty_sync_2_reg <= 1'b1;
+        s_axis_rst_sync_1_reg <= 1'b1;
+        s_axis_rst_sync_2_reg <= 1'b1;
+        m_axis_rst_sync_1_reg <= 1'b1;
+        m_axis_rst_sync_2_reg <= 1'b1;
+    end
 end
 
 assign s_axis_rst_out = |ch_input_rst_out;
@@ -328,7 +386,8 @@
     .fifo_rst_in(s_axis_rst_out),
     .output_data(ch_input_data),
     .output_valid(ch_input_valid),
-    .fifo_watermark_in(|ch_input_watermark)
+    .fifo_watermark_in(|ch_input_watermark),
+    .sts_enc_empty(enc_empty)
 );
 
 generate
@@ -416,31 +475,46 @@
     (* shreg_extract = "no" *)
     reg ch_cfg_enable_sync_1_reg = 1'b0,  ch_cfg_enable_sync_2_reg = 1'b0;
     (* shreg_extract = "no" *)
-    reg ch_cfg_reset_sync_1_reg = 1'b0,  ch_cfg_reset_sync_2_reg = 1'b0;
+    reg ch_cfg_reset_sync_1_reg = 1'b1,  ch_cfg_reset_sync_2_reg = 1'b1;
 
     always @(posedge ch_clk) begin
         ch_cfg_enable_sync_1_reg <= cfg_enable_reg;
         ch_cfg_enable_sync_2_reg <= ch_cfg_enable_sync_1_reg;
         ch_cfg_reset_sync_1_reg <= cfg_reset_reg;
         ch_cfg_reset_sync_2_reg <= ch_cfg_reset_sync_1_reg;
+        if (ch_rst) begin
+            ch_cfg_enable_sync_1_reg <= 1'b0;
+            ch_cfg_enable_sync_2_reg <= 1'b0;
+            ch_cfg_reset_sync_1_reg <= 1'b1;
+            ch_cfg_reset_sync_2_reg <= 1'b1;
+        end
     end
 
     // status sync
     wire [LEN_WIDTH+1-1:0] ch_sts_fifo_occupancy;
-    reg [LEN_WIDTH+1-1:0] ch_sts_fifo_occupancy_reg;
+    reg [LEN_WIDTH+1-1:0] ch_sts_fifo_occupancy_reg = 0;
+    reg ch_occ_ack_reg = 1'b0;
 
     (* shreg_extract = "no" *)
-    reg ch_sts_flag_sync_1_reg = 1'b0,  ch_sts_flag_sync_2_reg = 1'b0,  ch_sts_flag_sync_3_reg = 1'b0;
+    reg ch_sts_flag_sync_1_reg = 1'b0,  ch_sts_flag_sync_2_reg = 1'b0;
 
     assign sts_fifo_occupancy_int[(LEN_WIDTH+1)*n +: LEN_WIDTH+1] = ch_sts_fifo_occupancy_reg;
+    assign ch_occ_ack[n] = ch_occ_ack_reg;
 
     always @(posedge ch_clk) begin
-        ch_sts_flag_sync_1_reg <= sts_sync_flag_reg;
+        ch_sts_flag_sync_1_reg <= occ_req_reg[n];
         ch_sts_flag_sync_2_reg <= ch_sts_flag_sync_1_reg;
-        ch_sts_flag_sync_3_reg <= ch_sts_flag_sync_2_reg;
-
-        if (ch_sts_flag_sync_3_reg ^ ch_sts_flag_sync_2_reg) begin
+
+        if (ch_sts_flag_sync_2_reg != ch_occ_ack_reg) begin
             ch_sts_fifo_occupancy_reg <= ch_sts_fifo_occupancy;
+            ch_occ_ack_reg <= ch_sts_flag_sync_2_reg;
+        end
+
+        if (ch_rst) begin
+            ch_sts_flag_sync_1_reg <= 1'b0;
+            ch_sts_flag_sync_2_reg <= 1'b0;
+            ch_sts_fifo_occupancy_reg <= 0;
+            ch_occ_ack_reg <= 1'b0;
         end
     end
 
@@ -550,7 +624,9 @@
         .sts_reset(sts_reset_int[n]),
         .sts_active(sts_active_int[n]),
         .sts_write_active(),
-        .sts_read_active()
+        .sts_read_active(),
+        .input_idle_in(enc_empty),
+        .output_idle_in(dec_empty)
     );
 
 end
@@ -603,7 +679,8 @@
     /*
      * Status
      */
-    .sts_hdr_parity_err(sts_hdr_parity_err_int)
+    .sts_hdr_parity_err(sts_hdr_parity_err_int),
+    .sts_dec_empty(dec_empty)
 );
 
 endmodule

--- a/environment/public/code/axi_vfifo_enc.v (Buggy Starter)
+++ b/solution/gold/code/axi_vfifo_enc.v (Golden Reference)
@@ -80,7 +80,8 @@
     input  wire                          fifo_rst_in,
     output wire [SEG_CNT*SEG_WIDTH-1:0]  output_data,
     output wire [SEG_CNT-1:0]            output_valid,
-    input  wire                          fifo_watermark_in
+    input  wire                          fifo_watermark_in,
+    output wire                          sts_enc_empty
 );
 
 parameter AXIS_KEEP_WIDTH_INT = AXIS_KEEP_ENABLE ? AXIS_KEEP_WIDTH : 1;
@@ -222,6 +223,9 @@
         if (rd_en) begin
             rd_data_reg <= seg_mem_data[rd_addr];
         end
+        if (rst || fifo_rst_in) begin
+            rd_data_reg <= 0;
+        end
     end
 
 end
@@ -257,6 +261,11 @@
         hdr_mem_rd_last_reg <= hdr_mem_last[hdr_mem_rd_addr_reg];
         hdr_mem_rd_meta_reg <= hdr_mem_meta[hdr_mem_rd_addr_reg];
     end
+    if (rst || fifo_rst_in) begin
+        hdr_mem_rd_len_reg <= 0;
+        hdr_mem_rd_last_reg <= 1'b0;
+        hdr_mem_rd_meta_reg <= 0;
+    end
 end
 
 // limits
@@ -266,7 +275,7 @@
     hdr_fifo_full_reg <= $unsigned(hdr_fifo_wr_ptr_reg - hdr_fifo_rd_ptr_reg) >= 2**HDR_FIFO_ADDR_WIDTH-4;
     hdr_fifo_half_full_reg <= $unsigned(hdr_fifo_wr_ptr_reg - hdr_fifo_rd_ptr_reg) >= 2**HDR_FIFO_ADDR_WIDTH/2;
 
-    if (rst) begin
+    if (rst || fifo_rst_in) begin
         input_fifo_full_reg <= 1'b0;
         input_fifo_half_full_reg <= 1'b0;
         hdr_fifo_full_reg <= 1'b0;
@@ -278,6 +287,7 @@
 integer si;
 
 always @* begin
+    si = 0;
     int_seg_data = s_axis_tdata;
     int_seg_valid = 0;
 
@@ -327,6 +337,7 @@
 endgenerate
 
 always @* begin
+    k = 0;
     input_fifo_wr_ptr_next = input_fifo_wr_ptr_reg;
     hdr_fifo_wr_ptr_next = hdr_fifo_wr_ptr_reg;
 
@@ -509,8 +520,18 @@
         seg_mem_wr_addr_reg <= 0;
 
         frame_reg <= 1'b0;
+        len_reg <= 0;
 
         cycle_valid_reg <= 1'b0;
+        cycle_last_reg <= 1'b0;
+        cycle_len_reg <= 0;
+        cycle_meta_reg <= 0;
+
+        hdr_len_reg <= 0;
+        hdr_meta_reg <= 0;
+        hdr_last_reg <= 1'b0;
+        hdr_commit_reg <= 1'b0;
+        hdr_commit_prev_reg <= 1'b0;
         hdr_valid_reg <= 1'b0;
     end
 end
@@ -780,14 +801,39 @@
         mem_rd_data_valid_reg <= 0;
         hdr_mem_rd_data_valid_reg <= 0;
 
+        output_data_reg <= 0;
+        output_valid_reg <= 0;
+
         out_frame_reg <= 1'b0;
         out_len_reg <= 0;
         out_split1_reg <= 0;
+        out_seg_cnt_in_reg <= 0;
+        out_seg_last_straddle_reg <= 1'b0;
         out_seg_offset_reg <= 0;
         out_seg_fifo_offset_reg <= 0;
         out_seg_count_reg <= 0;
-    end
-end
+
+        out_hdr_reg <= 0;
+        out_ctl_seg_hdr_reg <= 0;
+        out_ctl_seg_split1_reg <= 0;
+        out_ctl_seg_en_reg <= 0;
+        for (i = 0; i < SEG_CNT_INT; i = i + 1) begin
+            out_ctl_seg_idx_reg[i] <= 0;
+        end
+        out_ctl_seg_offset_reg <= 0;
+        out_shift_reg <= 0;
+        block_timeout_count_reg <= 8'hff;
+        block_timeout_reg <= 1'b0;
+    end
+end
+
+assign sts_enc_empty = !(s_axis_tvalid && s_axis_tready) &&
+                       (input_fifo_wr_ptr_reg == input_fifo_rd_ptr_reg) &&
+                       (hdr_fifo_wr_ptr_reg == hdr_fifo_rd_ptr_reg) &&
+                       !frame_reg && !cycle_valid_reg && !hdr_valid_reg &&
+                       (mem_rd_data_valid_reg == 0) && !hdr_mem_rd_data_valid_reg &&
+                       !out_frame_reg && (out_seg_offset_reg == 0) &&
+                       (out_ctl_seg_en_reg == 0) && (output_valid_reg == 0);
 
 endmodule
 

--- a/environment/public/code/axi_vfifo_dec.v (Buggy Starter)
+++ b/solution/gold/code/axi_vfifo_dec.v (Golden Reference)
@@ -88,7 +88,8 @@
     /*
      * Status
      */
-    output wire                          sts_hdr_parity_err
+    output wire                          sts_hdr_parity_err,
+    output wire                          sts_dec_empty
 );
 
 parameter AXIS_KEEP_WIDTH_INT = AXIS_KEEP_ENABLE ? AXIS_KEEP_WIDTH : 1;
@@ -312,6 +313,12 @@
             seg_wr_ptr_reg <= 0;
             seg_rd_ptr_reg <= 0;
             seg_rd_valid_reg <= 1'b0;
+            seg_half_full_reg <= 1'b0;
+            seg_rd_sop_reg <= 1'b0;
+            seg_rd_eop_reg <= 1'b0;
+            seg_rd_end_reg <= 1'b0;
+            seg_rd_last_reg <= 1'b0;
+            seg_rd_last_len_reg <= 0;
         end
     end
 
@@ -430,6 +437,7 @@
 
 // re-pack data
 integer out_seg;
+integer seg_exp;
 reg [SEG_IDX_WIDTH-1:0] out_cur_seg;
 
 always @* begin
@@ -596,10 +604,10 @@
     m_axis_tuser_int = axis_tuser_next;
 
     if (EXPAND_INPUT) begin
-        for (seg = 0; seg < SEG_CNT; seg = seg + 1) begin
-            if (input_ready[seg] && input_valid[seg]) begin
-                input_data_int_next[SEG_WIDTH*seg +: SEG_WIDTH] = input_data[SEG_WIDTH*seg +: SEG_WIDTH];
-                input_valid_int_next[seg] = 1'b1;
+        for (seg_exp = 0; seg_exp < SEG_CNT; seg_exp = seg_exp + 1) begin
+            if (input_ready[seg_exp] && input_valid[seg_exp]) begin
+                input_data_int_next[SEG_WIDTH*seg_exp +: SEG_WIDTH] = input_data[SEG_WIDTH*seg_exp +: SEG_WIDTH];
+                input_valid_int_next[seg_exp] = 1'b1;
             end
         end
     end
@@ -633,13 +641,25 @@
 
     if (rst || fifo_rst_in) begin
         frame_reg <= 1'b0;
+        last_reg <= 1'b0;
+        extra_cycle_reg <= 1'b0;
+        last_straddle_reg <= 1'b0;
+        seg_cnt_reg <= 0;
         hdr_parity_err_reg <= 1'b0;
         out_frame_reg <= 1'b0;
         out_seg_offset_reg <= 0;
         output_offset_reg <= 0;
         out_seg_consumed_reg <= 0;
-        input_valid_int_next <= 1'b0;
+        input_data_int_reg <= 0;
+        input_valid_int_reg <= 0;
         out_ctrl_en_reg <= 1'b0;
+        out_ctrl_hdr_reg <= 1'b0;
+        out_ctrl_last_reg <= 1'b0;
+        out_ctrl_last_len_reg <= 0;
+        out_ctrl_seg_offset_reg <= 0;
+        axis_tid_reg <= 0;
+        axis_tdest_reg <= 0;
+        axis_tuser_reg <= 0;
     end
 end
 
@@ -711,10 +731,23 @@
     if (rst || fifo_rst_in) begin
         out_fifo_wr_ptr_reg <= 0;
         out_fifo_rd_ptr_reg <= 0;
+        out_fifo_half_full_reg <= 1'b0;
+        m_axis_tdata_reg <= {AXIS_DATA_WIDTH{1'b0}};
+        m_axis_tkeep_reg <= {AXIS_KEEP_WIDTH{1'b0}};
         m_axis_tvalid_reg <= 1'b0;
+        m_axis_tlast_reg <= 1'b0;
+        m_axis_tid_reg <= {AXIS_ID_WIDTH{1'b0}};
+        m_axis_tdest_reg <= {AXIS_DEST_WIDTH{1'b0}};
+        m_axis_tuser_reg <= {AXIS_USER_WIDTH{1'b0}};
     end
 end
 
+assign sts_dec_empty = (&ctrl_fifo_seg_empty) && (ctrl_fifo_rd_valid == 0) &&
+                       !frame_reg && !out_frame_reg && (out_seg_consumed_reg == 0) &&
+                       !out_ctrl_en_reg && out_fifo_empty && !m_axis_tvalid_reg &&
+                       (!EXPAND_INPUT || (input_valid_int_reg == 0)) &&
+                       (input_valid == 0) && (input_ctrl_valid == 0);
+
 endmodule
 
 `resetall

--- a/environment/public/code/axi_vfifo_raw.v (Buggy Starter)
+++ b/solution/gold/code/axi_vfifo_raw.v (Golden Reference)
@@ -152,7 +152,9 @@
     output wire                          sts_reset,
     output wire                          sts_active,
     output wire                          sts_write_active,
-    output wire                          sts_read_active
+    output wire                          sts_read_active,
+    input  wire                          input_idle_in,
+    input  wire                          output_idle_in
 );
 
 localparam ADDR_MASK = {AXI_ADDR_WIDTH{1'b1}} << $clog2(AXI_STRB_WIDTH);
@@ -169,6 +171,11 @@
 wire [LEN_WIDTH+1-1:0] wr_finish_ptr;
 wire [LEN_WIDTH+1-1:0] rd_start_ptr;
 wire [LEN_WIDTH+1-1:0] rd_finish_ptr;
+wire wr_side_empty;
+wire wr_pipe_empty;
+wire rd_pipe_empty;
+
+assign sts_fifo_empty = wr_side_empty && rd_pipe_empty && (rd_start_ptr == rd_finish_ptr);
 
 axi_vfifo_raw_wr #(
     .SEG_WIDTH(SEG_WIDTH),
@@ -241,9 +248,11 @@
      * Status
      */
     .sts_fifo_occupancy(sts_fifo_occupancy),
-    .sts_fifo_empty(sts_fifo_empty),
+    .sts_fifo_empty(wr_side_empty),
     .sts_fifo_full(sts_fifo_full),
-    .sts_write_active(sts_write_active)
+    .sts_write_active(sts_write_active),
+    .sts_wr_pipe_empty(wr_pipe_empty),
+    .input_idle_in(input_idle_in)
 );
 
 axi_vfifo_raw_rd #(
@@ -315,7 +324,9 @@
     /*
      * Status
      */
-    .sts_read_active(sts_read_active)
+    .sts_read_active(sts_read_active),
+    .sts_rd_pipe_empty(rd_pipe_empty),
+    .output_idle_in(output_idle_in)
 );
 
 // reset synchronization
@@ -329,14 +340,31 @@
 always @(posedge clk or posedge rst_req_int) begin
     if (rst_req_int) begin
         rst_sync_1_reg <= 1'b1;
+        rst_sync_2_reg <= 1'b1;
+        rst_sync_3_reg <= 1'b1;
     end else begin
         rst_sync_1_reg <= 1'b0;
+        rst_sync_2_reg <= rst_sync_1_reg;
+        rst_sync_3_reg <= rst_sync_2_reg;
     end
 end
 
+(* shreg_extract = "no" *)
+reg in_rst_sync_1_reg = 1'b1, in_rst_sync_2_reg = 1'b1;
+(* shreg_extract = "no" *)
+reg out_rst_sync_1_reg = 1'b1, out_rst_sync_2_reg = 1'b1;
+
 always @(posedge clk) begin
-    rst_sync_2_reg <= rst_sync_1_reg;
-    rst_sync_3_reg <= rst_sync_2_reg;
+    in_rst_sync_1_reg <= input_rst_out;
+    in_rst_sync_2_reg <= in_rst_sync_1_reg;
+    out_rst_sync_1_reg <= output_rst_out;
+    out_rst_sync_2_reg <= out_rst_sync_1_reg;
+    if (rst) begin
+        in_rst_sync_1_reg <= 1'b1;
+        in_rst_sync_2_reg <= 1'b1;
+        out_rst_sync_1_reg <= 1'b1;
+        out_rst_sync_2_reg <= 1'b1;
+    end
 end
 
 // reset and enable logic
@@ -356,7 +384,7 @@
         if (sts_write_active || sts_read_active) begin
             fifo_reset_next = 1'b1;
         end
-    end else if (!fifo_enable_reg && cfg_enable) begin
+    end else if (!fifo_enable_reg && !in_rst_sync_2_reg && !out_rst_sync_2_reg && cfg_enable) begin
         fifo_base_addr_next = cfg_fifo_base_addr & ADDR_MASK;
         fifo_size_mask_next = cfg_fifo_size_mask | ~ADDR_MASK;
 
@@ -373,6 +401,8 @@
     if (rst) begin
         fifo_reset_reg <= 1'b1;
         fifo_enable_reg <= 1'b0;
+        fifo_base_addr_reg <= 0;
+        fifo_size_mask_reg <= 0;
     end
 end
 

--- a/environment/public/code/axi_vfifo_raw_wr.v (Buggy Starter)
+++ b/solution/gold/code/axi_vfifo_raw_wr.v (Golden Reference)
@@ -116,7 +116,9 @@
     output wire [LEN_WIDTH+1-1:0]        sts_fifo_occupancy,
     output wire                          sts_fifo_empty,
     output wire                          sts_fifo_full,
-    output wire                          sts_write_active
+    output wire                          sts_write_active,
+    output wire                          sts_wr_pipe_empty,
+    input  wire                          input_idle_in
 );
 
 localparam AXI_BYTE_LANES = AXI_STRB_WIDTH;
@@ -130,7 +132,7 @@
 localparam CYCLE_COUNT_WIDTH = LEN_WIDTH - AXI_BURST_SIZE + 1;
 
 localparam WRITE_FIFO_ADDR_WIDTH = $clog2(WRITE_FIFO_DEPTH);
-localparam RESP_FIFO_ADDR_WIDTH = 5;
+localparam RESP_FIFO_ADDR_WIDTH = 6;
 
 // mask(x) = (2**$clog2(x))-1
 // log2(min(x, y, z)) = (mask & mask & mask)+1
@@ -196,7 +198,7 @@
 assign m_axi_bready = m_axi_bready_reg;
 
 // reset synchronization
-wire rst_req_int = cfg_reset;
+wire rst_req_int = cfg_reset | rst | input_rst;
 
 (* shreg_extract = "no" *)
 reg rst_sync_1_reg = 1'b1,  rst_sync_2_reg = 1'b1, rst_sync_3_reg = 1'b1;
@@ -206,14 +208,13 @@
 always @(posedge input_clk or posedge rst_req_int) begin
     if (rst_req_int) begin
         rst_sync_1_reg <= 1'b1;
+        rst_sync_2_reg <= 1'b1;
+        rst_sync_3_reg <= 1'b1;
     end else begin
         rst_sync_1_reg <= 1'b0;
-    end
-end
-
-always @(posedge input_clk) begin
-    rst_sync_2_reg <= rst_sync_1_reg;
-    rst_sync_3_reg <= rst_sync_2_reg;
+        rst_sync_2_reg <= rst_sync_1_reg;
+        rst_sync_3_reg <= rst_sync_2_reg;
+    end
 end
 
 // input datapath logic (write data)
@@ -246,6 +247,9 @@
 wire [SEG_CNT-1:0] write_fifo_seg_full;
 wire [SEG_CNT-1:0] write_fifo_seg_empty;
 wire [SEG_CNT-1:0] write_fifo_seg_watermark;
+wire [SEG_CNT-1:0] write_fifo_seg_in_idle;
+
+localparam SAFE_WATERMARK = (WRITE_FIFO_DEPTH > 8) ? ((WATERMARK_LEVEL > WRITE_FIFO_DEPTH - 6) ? (WRITE_FIFO_DEPTH - 6) : WATERMARK_LEVEL) : (WRITE_FIFO_DEPTH / 2);
 
 wire write_fifo_full = |write_fifo_seg_full;
 wire write_fifo_empty = |write_fifo_seg_empty;
@@ -253,7 +257,7 @@
 assign input_watermark = |write_fifo_seg_watermark | input_rst_out;
 
 genvar n;
-integer k;
+integer k_in, k_clk;
 
 generate
 
@@ -271,9 +275,10 @@
 
     reg [SEG_WIDTH-1:0] seg_rd_data_reg = 0;
 
+    wire [WRITE_FIFO_ADDR_WIDTH+1-1:0] seg_occ_cur = seg_wr_ptr_reg - write_fifo_rd_ptr_sync_reg;
     wire seg_full = seg_wr_ptr_gray_reg == (write_fifo_rd_ptr_gray_sync_2_reg ^ {2'b11, {WRITE_FIFO_ADDR_WIDTH-1{1'b0}}});
     wire seg_empty = write_fifo_rd_ptr_reg == write_fifo_wr_ptr_sync_reg;
-    wire seg_watermark = seg_occupancy_reg > WATERMARK_LEVEL;
+    wire seg_watermark = (seg_occ_cur >= SAFE_WATERMARK) || (seg_occupancy_reg >= SAFE_WATERMARK);
 
     assign input_data_int[n*SEG_WIDTH +: SEG_WIDTH] = seg_rd_data_reg;
 
@@ -282,6 +287,7 @@
     assign write_fifo_seg_full[n] = seg_full;
     assign write_fifo_seg_empty[n] = seg_empty;
     assign write_fifo_seg_watermark[n] = seg_watermark;
+    assign write_fifo_seg_in_idle[n] = (seg_wr_ptr_reg == write_fifo_rd_ptr_sync_reg) && !input_valid[n];
 
     if (n == SEG_CNT-1) begin
         assign write_fifo_wr_ptr = seg_wr_ptr_reg;
@@ -298,11 +304,13 @@
             seg_wr_ptr_temp = seg_wr_ptr_reg + 1;
             seg_wr_ptr_reg <= seg_wr_ptr_temp;
             seg_wr_ptr_gray_reg <= seg_wr_ptr_temp ^ (seg_wr_ptr_temp >> 1);
+            seg_occupancy_reg <= seg_wr_ptr_temp - write_fifo_rd_ptr_sync_reg;
         end
 
         if (input_rst || input_rst_out) begin
             seg_wr_ptr_reg <= 0;
             seg_wr_ptr_gray_reg <= 0;
+            seg_occupancy_reg <= 0;
         end
     end
 
@@ -310,19 +318,33 @@
         if (!write_fifo_empty && (!input_valid_int_reg || input_read_en)) begin
             seg_rd_data_reg <= seg_mem_data[write_fifo_rd_ptr_reg[WRITE_FIFO_ADDR_WIDTH-1:0]];
         end
+        if (rst || cfg_reset) begin
+            seg_rd_data_reg <= 0;
+        end
     end
 
 end
 
 endgenerate
+
+reg wr_in_idle_reg = 1'b1;
+(* shreg_extract = "no" *)
+reg wr_in_idle_sync_1_reg = 1'b1, wr_in_idle_sync_2_reg = 1'b1;
+
+always @(posedge input_clk) begin
+    wr_in_idle_reg <= (&write_fifo_seg_in_idle) && input_idle_in;
+    if (input_rst || input_rst_out) begin
+        wr_in_idle_reg <= 1'b1;
+    end
+end
 
 // pointer synchronization
 always @(posedge input_clk) begin
     write_fifo_rd_ptr_gray_sync_1_reg <= write_fifo_rd_ptr_gray_reg;
     write_fifo_rd_ptr_gray_sync_2_reg <= write_fifo_rd_ptr_gray_sync_1_reg;
 
-    for (k = 0; k < WRITE_FIFO_ADDR_WIDTH+1; k = k + 1) begin
-        write_fifo_rd_ptr_sync_reg[k] <= ^(write_fifo_rd_ptr_gray_sync_2_reg >> k);
+    for (k_in = 0; k_in < WRITE_FIFO_ADDR_WIDTH+1; k_in = k_in + 1) begin
+        write_fifo_rd_ptr_sync_reg[k_in] <= ^(write_fifo_rd_ptr_gray_sync_2_reg >> k_in);
     end
 
     if (input_rst || input_rst_out) begin
@@ -336,14 +358,19 @@
     write_fifo_wr_ptr_gray_sync_1_reg <= write_fifo_wr_ptr_gray;
     write_fifo_wr_ptr_gray_sync_2_reg <= write_fifo_wr_ptr_gray_sync_1_reg;
 
-    for (k = 0; k < WRITE_FIFO_ADDR_WIDTH+1; k = k + 1) begin
-        write_fifo_wr_ptr_sync_reg[k] <= ^(write_fifo
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/COPYING`](environment/public/code/COPYING) *(Read-Only Context)*
- [`environment/public/code/axi_vfifo.v`](environment/public/code/axi_vfifo.v) **(Editable)**
- [`environment/public/code/axi_vfifo_dec.v`](environment/public/code/axi_vfifo_dec.v) **(Editable)**
- [`environment/public/code/axi_vfifo_enc.v`](environment/public/code/axi_vfifo_enc.v) **(Editable)**
- [`environment/public/code/axi_vfifo_raw.v`](environment/public/code/axi_vfifo_raw.v) **(Editable)**
- [`environment/public/code/axi_vfifo_raw_rd.v`](environment/public/code/axi_vfifo_raw_rd.v) **(Editable)**
- [`environment/public/code/axi_vfifo_raw_wr.v`](environment/public/code/axi_vfifo_raw_wr.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

