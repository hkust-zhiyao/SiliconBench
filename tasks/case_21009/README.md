# `case_21009`: Streaming Ones'-Complement Checksum Offload Pipeline Backpressure, Multi-Beat Offset & Nangate45 PPA Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21009` |
| **Source Silicon Repository** | `corundum/corundum` (`repo_39`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/tx_checksum.v`](environment/public/code/tx_checksum.v), [`code/rx_checksum.v`](environment/public/code/rx_checksum.v) (2 files, 710 LOC) |
| **Public Subsystem Context** | 3 RTL files (1272 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Streaming Ones'-Complement Checksum Offload Pipeline Backpressure, Multi-Beat Offset & Nangate45 PPA Closure

`tx_checksum` (`code/tx_checksum.v`) and `rx_checksum` (`code/rx_checksum.v`) implement streaming RFC 1071 16-bit ones'-complement checksum offload across parameterized AXI4-Stream datapaths (`DATA_WIDTH` in `{64, 256}`). In ASIC synthesis and system integration, both modules fail high-frequency timing closure due to cascaded single-cycle end-around carry folding and dynamic byte-offset muxing, while exhibiting packet-to-checksum desynchronization under FIFO backpressure, multi-beat offset counter truncation, and unreset accumulator state:

Update `code/tx_checksum.v` and `code/rx_checksum.v` while preserving all top-level module names, port interfaces, and parameter definitions (`DATA_WIDTH`, `KEEP_WIDTH`, `ID_ENABLE`, `ID_WIDTH`, `DEST_ENABLE`, `DEST_WIDTH`, `USER_ENABLE`, `USER_WIDTH`, `USE_INIT_VALUE`, `DATA_FIFO_DEPTH`, `CHECKSUM_FIFO_DEPTH` on `tx_checksum`; `DATA_WIDTH`, `KEEP_WIDTH`, `START_OFFSET` on `rx_checksum`):

1. **Multi-Width Checksum Accuracy, FIFO Backpressure Integrity & ASIC Reset Hygiene (`DATA_WIDTH` in `{64, 256}`)**:
   - **`tx_checksum`**: Compute big-endian 16-bit ones'-complement checksums from byte `s_axis_cmd_csum_start` through `s_axis_tlast` (supporting even and odd `s_axis_cmd_csum_start` byte swaps, single-beat and multi-beat skip offsets `>= KEEP_WIDTH`, `USE_INIT_VALUE` in `{0, 1}`, and passthrough when `s_axis_cmd_csum_enable == 1'b0`), writing the inverted 16-bit checksum at `s_axis_cmd_csum_offset` (including 2-byte split insertion across consecutive beats when `csum_offset % KEEP_WIDTH == KEEP_WIDTH - 1`). Preserve strict 1-to-1 packet/checksum alignment without dropping or shifting checksums when `csum_fifo` fills under sustained `m_axis_tready == 1'b0` backpressure.
   - **`rx_checksum`**: Compute big-endian 16-bit ones'-complement packet sums from byte `START_OFFSET` through `s_axis_tlast` across arbitrary `START_OFFSET >= 0`, including multi-beat skip offsets `START_OFFSET >= 2 * KEEP_WIDTH` (e.g., `START_OFFSET = 16` at `DATA_WIDTH = 64` and `START_OFFSET = 64` at `DATA_WIDTH = 256`) and frames shorter than `START_OFFSET` (`m_axis_csum = 16'h0000`).
   - Synchronously reset all control, pipeline valid, and accumulator state on `rst` so ASIC gate-level simulation (without FPGA power-on register initializers) and mid-frame `rst` recovery exhibit zero `X` propagation and zero cross-packet residue.

2. **Nangate45 Datapath Timing & Area Signoff (`DATA_WIDTH = 64`)**:
   - Refactor/retime the end-around carry accumulation and byte-lane insertion paths so under Nangate45 OpenSTA setup/hold signoff (`0.10` ns input/output delay on all non-clock, non-reset ports; `set_false_path -from [get_ports rst]`):
     - `rx_checksum` (`DATA_WIDTH=64, START_OFFSET=14`) closes at **`clk = 1.24` ns** with **`WNS >= 0.00` ns**, **`TNS >= 0.00` ns**, **`worst hold slack >= 0.00` ns**, and mapped cell area **`<= 1,750` um²**;
     - `tx_checksum` (`DATA_WIDTH=64, USE_INIT_VALUE=1, DATA_FIFO_DEPTH=8, CHECKSUM_FIFO_DEPTH=4`) closes at **`clk = 1.46` ns** with **`WNS >= 0.00` ns**, **`TNS >= 0.00` ns**, **`worst hold slack >= 0.00` ns**, and mapped cell area **`<= 7,200` um²**.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The checksum offload RTL in `code/` derives from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause-Views).

Editable files:
- `code/tx_checksum.v`
- `code/rx_checksum.v`

Read-only files:
- `code/axis_fifo.v`
- `code/LICENSE`
- `pdk/NangateOpenCellLibrary_typical.lib`

Editable RTL must remain pure synthesizable HDL (do not add simulation-control or file-I/O system tasks such as `$finish`, `$stop`, `$fatal`, or `$readmem*`, and do not use simulator/synthesis macro divergence).

Local compilation, Yosys Nangate45 synthesis, and OpenSTA timing/area check from the workspace root:
```bash
# 1. Icarus Verilog compilation check
iverilog -g2012 -o /tmp/csum_chk.vvp \
  code/tx_checksum.v code/rx_checksum.v code/axis_fifo.v

# 2. Yosys Nangate45 synthesis & area report (example for tx_checksum; repeat for rx_checksum with -chparam DATA_WIDTH 64 -chparam START_OFFSET 14)
yosys -p "
  read_verilog code/tx_checksum.v code/axis_fifo.v;
  hierarchy -check -top tx_checksum -chparam DATA_WIDTH 64 -chparam USE_INIT_VALUE 1 -chparam DATA_FIFO_DEPTH 8 -chparam CHECKSUM_FIFO_DEPTH 4;
  synth -flatten -top tx_checksum;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean -purge;
  stat -liberty pdk/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -simple-lhs /tmp/tx_csum_net.v
"

# 3. OpenSTA timing verification (1.46 ns for tx_checksum; 1.24 ns for rx_checksum)
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -no_init -exit <<'EOF'
read_liberty pdk/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/tx_csum_net.v
link_design tx_checksum
create_clock -name clk -period 1.46 [get_ports clk]
set_false_path -from [get_ports rst]
foreach p [get_ports *] {
    set n [get_name $p]
    if {$n != "clk" && $n != "rst"} {
        if {[get_property $p direction] == "input"} { set_input_delay 0.10 -clock clk $p } else { set_output_delay 0.10 -clock clk $p }
    }
}
report_tns
report_wns
report_checks -path_delay min_max
EOF
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/tx_checksum.v (Buggy Starter)
+++ b/solution/gold/code/tx_checksum.v (Golden Reference)
@@ -14,36 +14,22 @@
  */
 module tx_checksum #
 (
-    // Width of AXI stream interfaces in bits
     parameter DATA_WIDTH = 256,
-    // AXI stream tkeep signal width (words per cycle)
     parameter KEEP_WIDTH = (DATA_WIDTH/8),
-    // Propagate tid signal
     parameter ID_ENABLE = 0,
-    // tid signal width
     parameter ID_WIDTH = 8,
-    // Propagate tdest signal
     parameter DEST_ENABLE = 0,
-    // tdest signal width
     parameter DEST_WIDTH = 8,
-    // Propagate tuser signal
     parameter USER_ENABLE = 1,
-    // tuser signal width
     parameter USER_WIDTH = 1,
-    // Use checksum init value
     parameter USE_INIT_VALUE = 0,
-    // Depth of data FIFO in words
     parameter DATA_FIFO_DEPTH = 4096,
-    // Depth of checksum FIFO
     parameter CHECKSUM_FIFO_DEPTH = 64
 )
 (
     input  wire                   clk,
     input  wire                   rst,
 
-    /*
-     * AXI input
-     */
     input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
     input  wire [KEEP_WIDTH-1:0]  s_axis_tkeep,
     input  wire                   s_axis_tvalid,
@@ -53,9 +39,6 @@
     input  wire [DEST_WIDTH-1:0]  s_axis_tdest,
     input  wire [USER_WIDTH-1:0]  s_axis_tuser,
 
-    /*
-     * AXI output
-     */
     output wire [DATA_WIDTH-1:0]  m_axis_tdata,
     output wire [KEEP_WIDTH-1:0]  m_axis_tkeep,
     output wire                   m_axis_tvalid,
@@ -65,9 +48,6 @@
     output wire [DEST_WIDTH-1:0]  m_axis_tdest,
     output wire [USER_WIDTH-1:0]  m_axis_tuser,
 
-    /*
-     * Control
-     */
     input  wire                   s_axis_cmd_csum_enable,
     input  wire [7:0]             s_axis_cmd_csum_start,
     input  wire [7:0]             s_axis_cmd_csum_offset,
@@ -76,55 +56,58 @@
     output wire                   s_axis_cmd_ready
 );
 
-parameter LEVELS = $clog2(DATA_WIDTH/8);
-
-// bus width assertions
-initial begin
-    if (KEEP_WIDTH * 8 != DATA_WIDTH) begin
-        $error("Error: AXI stream interface requires byte (8-bit) granularity (instance %m)");
-        $finish;
-    end
-end
+localparam LEVELS = $clog2(DATA_WIDTH/8);
+localparam FINAL_SUM_W = 16 + LEVELS - 1;
+localparam CSUM_FIFO_KEEP_W = ((16 + 8 + 1) + 7) / 8;
 
 reg transfer_in_reg = 1'b0;
 
-reg [15:0] csum_in_csum_reg = 0;
-reg [7:0] csum_in_offset_reg = 0;
-reg csum_in_enable_reg = 1'b0;
-reg csum_in_valid_reg = 1'b0;
-wire csum_in_ready;
+reg        cmd_odd_reg    = 1'b0;
+reg        cmd_enable_reg = 1'b0;
+reg [7:0]  cmd_offset_reg = 8'd0;
+reg [15:0] cmd_init_reg   = 16'd0;
+
+reg [15:0] csum_in_csum_reg   = 16'd0;
+reg [7:0]  csum_in_offset_reg = 8'd0;
+reg        csum_in_enable_reg = 1'b0;
+reg        csum_in_valid_reg  = 1'b0;
+wire       csum_in_ready;
 
 wire [15:0] csum_out_csum;
-wire [7:0] csum_out_offset;
-wire csum_out_enable;
-wire csum_out_valid;
-reg csum_out_ready = 1'b0;
-
-reg [KEEP_WIDTH-1:0] mask_reg = 0;
-reg first_cycle_reg = 1'b0;
-reg [7:0] input_offset_reg = 0;
+wire [7:0]  csum_out_offset;
+wire        csum_out_enable;
+wire        csum_out_valid;
+reg         csum_out_ready = 1'b0;
+
+reg [KEEP_WIDTH-1:0] mask_reg         = {KEEP_WIDTH{1'b0}};
+reg                  first_cycle_reg  = 1'b0;
+reg [7:0]            input_offset_reg = 8'd0;
 reg [DATA_WIDTH-1:0] s_axis_tdata_masked;
 
-reg frame_reg = 1'b0, frame_next;
-
-reg [15:0] csum_reg = 16'd0, csum_next;
-reg [7:0] csum_offset_reg = 8'd0, csum_offset_next;
-reg csum_enable_reg = 1'b0, csum_enable_next;
-reg csum_split_reg = 1'b0, csum_split_next;
-
-reg [DATA_WIDTH-1:0] sum_reg[LEVELS-2:0];
-reg [LEVELS-2:0] sum_valid_reg = 0;
-reg [LEVELS-2:0] sum_odd_reg = 0;
-reg [LEVELS-2:0] sum_last_reg = 0;
-reg [LEVELS-2:0] sum_enable_reg = 0;
-reg [7:0] sum_offset_reg[LEVELS-2:0];
-reg [15:0] sum_init_reg[LEVELS-2:0];
-reg [LEVELS-2:0] sum_init_valid_reg = 0;
-
-reg [16+LEVELS-1:0] sum_acc_temp = 0;
-reg [15:0] sum_acc_reg = 0;
-
-// internal datapath
+reg                  frame_reg       = 1'b0, frame_next;
+reg [15:0]           csum_reg        = 16'd0, csum_next;
+reg [7:0]            csum_offset_reg = 8'd0, csum_offset_next;
+reg                  csum_enable_reg = 1'b0, csum_enable_next;
+reg                  csum_split_reg  = 1'b0, csum_split_next;
+reg [KEEP_WIDTH-1:0] hi_mask_reg     = {KEEP_WIDTH{1'b0}}, hi_mask_next;
+reg [KEEP_WIDTH-1:0] lo_mask_reg     = {KEEP_WIDTH{1'b0}}, lo_mask_next;
+
+reg [DATA_WIDTH-1:0] sum_reg [LEVELS-2:0];
+reg [LEVELS-2:0]     sum_valid_reg      = {LEVELS-1{1'b0}};
+reg [LEVELS-2:0]     sum_odd_reg        = {LEVELS-1{1'b0}};
+reg [LEVELS-2:0]     sum_last_reg       = {LEVELS-1{1'b0}};
+reg [LEVELS-2:0]     sum_enable_reg     = {LEVELS-1{1'b0}};
+reg [7:0]            sum_offset_reg [LEVELS-2:0];
+reg [15:0]           sum_init_reg   [LEVELS-2:0];
+reg [LEVELS-2:0]     sum_init_valid_reg = {LEVELS-1{1'b0}};
+
+reg [29:0] sum_acc_reg     = 30'd0;
+reg [29:0] fold_acc_reg    = 30'd0;
+reg        fold_valid_reg  = 1'b0;
+reg        fold_odd_reg    = 1'b0;
+reg        fold_enable_reg = 1'b0;
+reg [7:0]  fold_offset_reg = 8'd0;
+
 reg  [DATA_WIDTH-1:0] m_axis_tdata_int;
 reg  [KEEP_WIDTH-1:0] m_axis_tkeep_int;
 reg                   m_axis_tvalid_int;
@@ -135,14 +118,8 @@
 reg  [USER_WIDTH-1:0] m_axis_tuser_int;
 wire                  m_axis_tready_int_early;
 
-wire [DATA_WIDTH-1:0] data_in_axis_tdata;
-wire [KEEP_WIDTH-1:0] data_in_axis_tkeep;
 wire                  data_in_axis_tvalid;
 wire                  data_in_axis_tready;
-wire                  data_in_axis_tlast;
-wire [ID_WIDTH-1:0]   data_in_axis_tid;
-wire [DEST_WIDTH-1:0] data_in_axis_tdest;
-wire [USER_WIDTH-1:0] data_in_axis_tuser;
 
 wire [DATA_WIDTH-1:0] data_out_axis_tdata;
 wire [KEEP_WIDTH-1:0] data_out_axis_tkeep;
@@ -153,18 +130,11 @@
 wire [DEST_WIDTH-1:0] data_out_axis_tdest;
 wire [USER_WIDTH-1:0] data_out_axis_tuser;
 
-assign s_axis_tready = data_in_axis_tready && csum_in_ready && transfer_in_reg;
-
-assign s_axis_cmd_ready = csum_in_ready && !transfer_in_reg;
-
-// data FIFO
-assign data_in_axis_tdata = s_axis_tdata;
-assign data_in_axis_tkeep = s_axis_tkeep;
-assign data_in_axis_tvalid = s_axis_tvalid && csum_in_ready && transfer_in_reg;
-assign data_in_axis_tlast = s_axis_tlast;
-assign data_in_axis_tid = s_axis_tid;
-assign data_in_axis_tdest = s_axis_tdest;
-assign data_in_axis_tuser = s_axis_tuser;
+wire pipe_ready = !csum_in_valid_reg || csum_in_ready;
+
+assign s_axis_tready     = data_in_axis_tready && pipe_ready && transfer_in_reg;
+assign s_axis_cmd_ready  = pipe_ready && !transfer_in_reg;
+assign data_in_axis_tvalid = s_axis_tvalid && pipe_ready && transfer_in_reg;
 
 axis_fifo #(
     .DEPTH(DATA_FIFO_DEPTH),
@@ -183,16 +153,14 @@
 data_fifo (
     .clk(clk),
     .rst(rst),
-    // AXI input
-    .s_axis_tdata(data_in_axis_tdata),
-    .s_axis_tkeep(data_in_axis_tkeep),
+    .s_axis_tdata(s_axis_tdata),
+    .s_axis_tkeep(s_axis_tkeep),
     .s_axis_tvalid(data_in_axis_tvalid),
     .s_axis_tready(data_in_axis_tready),
-    .s_axis_tlast(data_in_axis_tlast),
-    .s_axis_tid(data_in_axis_tid),
-    .s_axis_tdest(data_in_axis_tdest),
-    .s_axis_tuser(data_in_axis_tuser),
-    // AXI output
+    .s_axis_tlast(s_axis_tlast),
+    .s_axis_tid(s_axis_tid),
+    .s_axis_tdest(s_axis_tdest),
+    .s_axis_tuser(s_axis_tuser),
     .m_axis_tdata(data_out_axis_tdata),
     .m_axis_tkeep(data_out_axis_tkeep),
     .m_axis_tvalid(data_out_axis_tvalid),
@@ -201,17 +169,20 @@
     .m_axis_tid(data_out_axis_tid),
     .m_axis_tdest(data_out_axis_tdest),
     .m_axis_tuser(data_out_axis_tuser),
-    // Status
+    .pause_req(1'b0),
+    .pause_ack(),
+    .status_depth(),
+    .status_depth_commit(),
     .status_overflow(),
     .status_bad_frame(),
     .status_good_frame()
 );
 
-// checksum FIFO
 axis_fifo #(
     .DEPTH(CHECKSUM_FIFO_DEPTH),
     .DATA_WIDTH(16+8+1),
     .KEEP_ENABLE(0),
+    .KEEP_WIDTH(CSUM_FIFO_KEEP_W),
     .LAST_ENABLE(0),
     .ID_ENABLE(0),
     .DEST_ENABLE(0),
@@ -221,16 +192,14 @@
 csum_fifo (
     .clk(clk),
     .rst(rst),
-    // AXI input
     .s_axis_tdata({csum_in_csum_reg, csum_in_offset_reg, csum_in_enable_reg}),
-    .s_axis_tkeep(0),
+    .s_axis_tkeep({CSUM_FIFO_KEEP_W{1'b0}}),
     .s_axis_tvalid(csum_in_valid_reg),
     .s_axis_tready(csum_in_ready),
-    .s_axis_tlast(0),
-    .s_axis_tid(0),
-    .s_axis_tdest(0),
-    .s_axis_tuser(0),
-    // AXI output
+    .s_axis_tlast(1'b0),
+    .s_axis_tid(8'd0),
+    .s_axis_tdest(8'd0),
+    .s_axis_tuser(1'b0),
     .m_axis_tdata({csum_out_csum, csum_out_offset, csum_out_enable}),
     .m_axis_tkeep(),
     .m_axis_tvalid(csum_out_valid),
@@ -239,151 +208,207 @@
     .m_axis_tid(),
     .m_axis_tdest(),
     .m_axis_tuser(),
-    // Status
+    .pause_req(1'b0),
+    .pause_ack(),
+    .status_depth(),
+    .status_depth_commit(),
     .status_overflow(),
     .status_bad_frame(),
     .status_good_frame()
 );
 
-// Mask input data
 integer j;
-
 always @* begin
     for (j = 0; j < KEEP_WIDTH; j = j + 1) begin
         s_axis_tdata_masked[j*8 +: 8] = (s_axis_tkeep[j] && mask_reg[j]) ? s_axis_tdata[j*8 +: 8] : 8'd0;
     end
 end
 
-// Compute checksum
 integer i;
-
 always @(posedge clk) begin
-    sum_valid_reg[0] <= sum_valid_reg[0] && !csum_in_ready;
-
-    if (s_axis_tvalid && s_axis_tready) begin
-        for (i = 0; i < DATA_WIDTH/8/4; i = i + 1) begin
-            sum_reg[0][i*17 +: 17] <= {s_axis_tdata_masked[(4*i+0)*8 +: 8], s_axis_tdata_masked[(4*i+1)*8 +: 8]} + {s_axis_tdata_masked[(4*i+2)*8 +: 8], s_axis_tdata_masked[(4*i+3)*8 +: 8]};
-        end
-        sum_valid_reg[0] <= 1'b1;
-        sum_last_reg[0] <= s_axis_tlast;
-        sum_init_valid_reg[0] <= first_cycle_reg;
-
-        first_cycle_reg <= 1'b0;
-
-        if (s_axis_tlast) begin
-            transfer_in_reg <= 1'b0;
-        end
-
-        if (input_offset_reg > 0) begin
-            if (input_offset_reg >= KEEP_WIDTH) begin
-                mask_reg <= 0;
-                input_offset_reg <= input_offset_reg - KEEP_WIDTH;
+    if (rst) begin
+        transfer_in_reg       <= 1'b0;
+        cmd_odd_reg           <= 1'b0;
+        cmd_enable_reg        <= 1'b0;
+        cmd_offset_reg        <= 8'd0;
+        cmd_init_reg          <= 16'd0;
+        mask_reg              <= {KEEP_WIDTH{1'b0}};
+        first_cycle_reg       <= 1'b0;
+        input_offset_reg      <= 8'd0;
+        sum_valid_reg[0]      <= 1'b0;
+        sum_odd_reg[0]        <= 1'b0;
+        sum_last_reg[0]       <= 1'b0;
+        sum_enable_reg[0]     <= 1'b0;
+        sum_offset_reg[0]     <= 8'd0;
+        sum_init_reg[0]       <= 16'd0;
+        sum_init_valid_reg[0] <= 1'b0;
+        for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
+            sum_reg[0][i*17 +: 17] <= 17'd0;
+        end
+    end else begin
+        if (pipe_ready) begin
+            sum_valid_reg[0] <= 1'b0;
+
+            if (s_axis_tvalid && s_axis_tready) begin
+                for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
+                    sum_reg[0][i*17 +: 17] <= {1'b0, s_axis_tdata_masked[(4*i+0)*8 +: 8], s_axis_tdata_masked[(4*i+1)*8 +: 8]} +
+                                              {1'b0, s_axis_tdata_masked[(4*i+2)*8 +: 8], s_axis_tdata_masked[(4*i+3)*8 +: 8]};
+                end
+                sum_valid_reg[0]      <= 1'b1;
+                sum_odd_reg[0]        <= cmd_odd_reg;
+                sum_last_reg[0]       <= s_axis_tlast;
+                sum_enable_reg[0]     <= cmd_enable_reg;
+                sum_offset_reg[0]     <= cmd_offset_reg;
+                sum_init_reg[0]       <= cmd_init_reg;
+                sum_init_valid_reg[0] <= first_cycle_reg;
+
+                first_cycle_reg <= 1'b0;
+
+                if (s_axis_tlast) begin
+                    transfer_in_reg <= 1'b0;
+                end
+
+                if (input_offset_reg > 8'd0) begin
+                    if (input_offset_reg >= KEEP_WIDTH) begin
+                        mask_reg         <= {KEEP_WIDTH{1'b0}};
+                        input_offset_reg <= input_offset_reg - KEEP_WIDTH[7:0];
+                    end else begin
+                        mask_reg         <= {KEEP_WIDTH{1'b1}} << input_offset_reg;
+                        input_offset_reg <= 8'd0;
+                    end
+                end else begin
+                    mask_reg <= {KEEP_WIDTH{1'b1}};
+                end
+            end
+        end
+
+        if (s_axis_cmd_valid && s_axis_cmd_ready) begin
+            transfer_in_reg <= 1'b1;
+            cmd_odd_reg     <= s_axis_cmd_csum_start[0];
+            cmd_enable_reg  <= s_axis_cmd_csum_enable;
+            cmd_offset_reg  <= s_axis_cmd_csum_offset;
+            cmd_init_reg    <= s_axis_cmd_csum_init;
+            first_cycle_reg <= 1'b1;
+
+            if (s_axis_cmd_csum_start >= KEEP_WIDTH) begin
+                mask_reg         <= {KEEP_WIDTH{1'b0}};
+                input_offset_reg <= s_axis_cmd_csum_start - KEEP_WIDTH[7:0];
             end else begin
-                mask_reg <= {KEEP_WIDTH{1'b1}} << input_offset_reg;
-                input_offset_reg <= 0;
+                mask_reg         <= {KEEP_WIDTH{1'b1}} << s_axis_cmd_csum_start;
+                input_offset_reg <= 8'd0;
             end
-        end else begin
-            mask_reg <= {KEEP_WIDTH{1'b1}};
-        end
-    end
-
-    if (s_axis_cmd_valid && s_axis_cmd_ready) begin
-        transfer_in_reg <= 1'b1;
-        sum_odd_reg[0] <= s_axis_cmd_csum_start[0];
-        sum_enable_reg[0] <= s_axis_cmd_csum_enable;
-        sum_offset_reg[0] <= s_axis_cmd_csum_offset;
-        sum_init_reg[0] <= s_axis_cmd_csum_init;
-        first_cycle_reg <= 1'b1;
-        
-        if (s_axis_cmd_csum_start >= KEEP_WIDTH) begin
-            mask_reg <= 0;
-            input_offset_reg <= s_axis_cmd_csum_start - KEEP_WIDTH;
-        end else begin
-            mask_reg <= {KEEP_WIDTH{1'b1}} << s_axis_cmd_csum_start;
-            input_offset_reg <= 0;
-        end
-    end
-
+        end
+    end
+end
+
+generate
+    genvar l;
+    for (l = 1; l < LEVELS-1; l = l + 1) begin : gen_tree
+        always @(posedge clk) begin
+            if (rst) begin
+                sum_valid_reg[l]      <= 1'b0;
+                sum_odd_reg[l]        <= 1'b0;
+                sum_last_reg[l]       <= 1'b0;
+                sum_enable_reg[l]     <= 1'b0;
+                sum_offset_reg[l]     <= 8'd0;
+                sum_init_reg[l]       <= 16'd0;
+                sum_init_valid_reg[l] <= 1'b0;
+                for (i = 0; i < (DATA_WIDTH/32)/(1 << l); i = i + 1) begin
+                    sum_reg[l][i*(17+l) +: (17+l)] <= {(17+l){1'b0}};
+                end
+            end else if (pipe_ready) begin
+                sum_valid_reg[l] <= 1'b0;
+                if (sum_valid_reg[l-1]) begin
+                    for (i = 0; i < (DATA_WIDTH/32)/(1 << l); i = i + 1) begin
+                        sum_reg[l][i*(17+l) +: (17+l)] <= sum_reg[l-1][(i*2+0)*(17+l-1) +: (17+l-1)] +
+                                                          sum_reg[l-1][(i*2+1)*(17+l-1) +: (17+l-1)];
+                    end
+                    sum_valid_reg[l]      <= 1'b1;
+                    sum_odd_reg[l]        <= sum_odd_reg[l-1];
+                    sum_last_reg[l]       <= sum_last_reg[l-1];
+                    sum_enable_reg[l]     <= sum_enable_reg[l-1];
+                    sum_offset_reg[l]     <= sum_offset_reg[l-1];
+                    sum_init_reg[l]       <= sum_init_reg[l-1];
+                    sum_init_valid_reg[l] <= sum_init_valid_reg[l-1];
+                end
+            end
+        end
+    end
+endgenerate
+
+wire [29:0] acc_base = (sum_init_valid_reg[LEVELS-2] && (USE_INIT_VALUE != 0)) ? {14'd0, sum_init_reg[LEVELS-2]} : sum_acc_reg;
+wire [29:0] next_acc = acc_base + {{(30-FINAL_SUM_W){1'b0}}, sum_reg[LEVELS-2][FINAL_SUM_W-1:0]};
+
+wire [16:0] fold_s1   = {1'b0, fold_acc_reg[15:0]} + {3'd0, fold_acc_reg[29:16]};
+wire [15:0] fold_c16  = fold_s1[15:0] + {15'd0, fold_s1[16]};
+wire [15:0] fold_inv  = ~fold_c16;
+
+always @(posedge clk) begin
     if (rst) begin
-        transfer_in_reg <= 1'b0;
-        sum_valid_reg[0] <= 1'b0;
+        sum_acc_reg        <= 30'd0;
+        fold_acc_reg       <= 30'd0;
+        fold_valid_reg     <= 1'b0;
+        fold_odd_reg       <= 1'b0;
+        fold_enable_reg    <= 1'b0;
+        fold_offset_reg    <= 8'd0;
+        csum_in_csum_reg   <= 16'd0;
+        csum_in_offset_reg <= 8'd0;
+        csum_in_enable_reg <= 1'b0;
+        csum_in_valid_reg  <= 1'b0;
+    end else begin
+        if (csum_in_valid_reg && csum_in_ready) begin
+            csum_in_valid_reg <= 1'b0;
+        end
+
+        if (pipe_ready) begin
+            fold_valid_reg <= 1'b0;
+
+            if (sum_valid_reg[LEVELS-2]) begin
+                if (sum_last_reg[LEVELS-2]) begin
+                    fold_acc_reg    <= next_acc;
+                    fold_valid_reg  <= 1'b1;
+                    fold_odd_reg    <= sum_odd_reg[LEVELS-2];
+                    fold_enable_reg <= sum_enable_reg[LEVELS-2];
+                    fold_offset_reg <= sum_offset_reg[LEVELS-2];
+                    sum_acc_reg     <= 30'd0;
+                end else begin
+                    sum_acc_reg <= next_acc;
+                end
+            end
+
+            if (fold_valid_reg) begin
+                csum_in_csum_reg   <= fold_odd_reg ? {fold_inv[7:0], fold_inv[15:8]} : fold_inv;
+                csum_in_offset_reg <= fold_offset_reg;
+                csum_in_enable_reg <= fold_enable_reg;
+                csum_in_valid_reg  <= 1'b1;
+            end
+        end
     end
 end
 
-generate
-
-    genvar l;
-
-    for (l = 1; l < LEVELS-1; l = l + 1) begin
-
-        always @(posedge clk) begin
-            sum_valid_reg[l] <= sum_valid_reg[l] && !csum_in_ready;
-
-            if (sum_valid_reg[l-1] && csum_in_ready) begin
-                for (i = 0; i < DATA_WIDTH/8/4/2**l; i = i + 1) begin
-                    sum_reg[l][i*(17+l) +: (17+l)] <= sum_reg[l-1][(i*2+0)*(17+l-1) +: (17+l-1)] + sum_reg[l-1][(i*2+1)*(17+l-1) +: (17+l-1)];
-                end
-                sum_valid_reg[l] <= 1'b1;
-                sum_odd_reg[l] <= sum_odd_reg[l-1];
-                sum_last_reg[l] <= sum_last_reg[l-1];
-                sum_enable_reg[l] <= sum_enable_reg[l-1];
-                sum_offset_reg[l] <= sum_offset_reg[l-1];
-                sum_init_reg[l] <= sum_init_reg[l-1];
-                sum_init_valid_reg[l] <= sum_init_valid_reg[l-1];
-            end
-
-            if (rst) begin
-                sum_valid_reg[l] <= 1'b0;
-            end
-        end
-
-    end
-
-endgenerate
-
-always @(posedge clk) begin
-    csum_in_valid_reg <= 1'b0;
-
-    if (sum_valid_reg[LEVELS-2] && csum_in_ready) begin
-        sum_acc_temp = sum_reg[LEVELS-2][16+LEVELS-1-1:0] + (sum_init_valid_reg[LEVELS-2] && USE_INIT_VALUE ? sum_init_reg[LEVELS-2] : sum_acc_reg);
-        sum_acc_temp = sum_acc_temp[15:0] + (sum_acc_temp >> 16);
-        sum_acc_temp = sum_acc_temp[15:0] + sum_acc_temp[16];
-
-        if (sum_last_reg[LEVELS-2]) begin
-            if (sum_odd_reg[LEVELS-2]) begin
-                csum_in_csum_reg[7:0] <= ~sum_acc_temp[15:8];
-                csum_in_csum_reg[15:8] <= ~sum_acc_temp[7:0];
-            end else begin
-                csum_in_csum_reg[7:0] <= ~sum_acc_temp[7:0];
-                csum_in_csum_reg[15:8] <= ~sum_acc_temp[15:8];
-            end
-            csum_in_offset_reg <= sum_offset_reg[LEVELS-2];
-            csum_in_enable_reg <= sum_enable_reg[LEVELS-2];
-            csum_in_valid_reg <= 1'b1;
-            sum_acc_reg <= 0;
-        end else begin
-            sum_acc_reg <= sum_acc_temp;
-        end
-    end
-
-    if (rst) begin
-        csum_in_valid_reg <= 1'b0;
-    end
-end
-
-// Insert checksum
+// Registered one-hot byte-lane checksum insertion
+integer b;
 always @* begin
     data_out_axis_tready = m_axis_tready_int_reg && frame_reg;
-    csum_out_ready = 1'b0;
-
-    frame_next = frame_reg;
-
-    csum_next = csum_reg;
+    csum_out_ready       = 1'b0;
+
+    frame_next       = frame_reg;
+    csum_next        = csum_reg;
     csum_offset_next = csum_offset_reg;
     csum_enable_next = csum_enable_reg;
-    csum_split_next = csum_split_reg;
-
-    m_axis_tdata_int  = data_out_axis_tdata;
+    csum_split_next  = csum_split_reg;
+    hi_mask_next     = hi_mask_reg;
+    lo_mask_next     = lo_mask_reg;
+
+    for (b = 0; b < KEEP_WIDTH; b = b + 1) begin
+        if (hi_mask_reg[b]) begin
+            m_axis_tdata_int[b*8 +: 8] = csum_reg[15:8];
+        end else if (lo_mask_reg[b]) begin
+            m_axis_tdata_int[b*8 +: 8] = csum_reg[7:0];
+        end else begin
+            m_axis_tdata_int[b*8 +: 8] = data_out_axis_tdata[b*8 +: 8];
+        end
+    end
     m_axis_tkeep_int  = data_out_axis_tkeep;
     m_axis_tvalid_int = data_out_axis_tvalid && data_out_axis_tready;
     m_axis_tlast_int  = data_out_axis_tlast;
@@ -394,55 +419,85 @@
     if (frame_reg) begin
         if (data_out_axis_tvalid && data_out_axis_tready) begin
             if (data_out_axis_tlast) begin
-                frame_next = 1'b0;
-            end
-
-            if (csum_enable_reg) begin
-                if (csum_offset_reg >= KEEP_WIDTH) begin
-                    csum_offset_next = csum_offset_reg - KEEP_WIDTH;
-                end else if (csum_split_reg) begin
-                    // other byte of split checksum
-                    m_axis_tdata_int[0 +: 8] = csum_reg[7:0];
+                frame_next       = 1'b0;
+                csum_enable_next = 1'b0;
+                csum_split_next  = 1'b0;
+                hi_mask_next     = {KEEP_WIDTH{1'b0}};
+                lo_mask_next     = {KEEP_WIDTH{1'b0}};
+            end else if (csum_enable_reg) begin
+                if (|hi_mask_reg) begin
+                    hi_mask_next = {KEEP_WIDTH{1'b0}};
+                    if (csum_split_reg) begin
+                        lo_mask_next    = {{(KEEP_WIDTH-1){1'b0}}, 1'b1};
+                        csum_split_next = 1'b0;
+                    end else begin
+                        lo_mask_next     = {KEEP_WIDTH{1'b0}};
+                        csum_enable_next = 1'b0;
+                    end
+                end else if (|lo_mask_reg) begin
+                    hi_mask_next     = {KEEP_WIDTH{1'b0}};
+                    lo_mask_next     = {KEEP_WIDTH{1'b0}};
                     csum_enable_next = 1'b0;
-                end else if (csum_offset_reg == KEEP_WIDTH-1) begin
-                    // split across two cycles
-                    m_axis_tdata_int[DATA_WIDTH-8 +: 8] = csum_reg[15:8];
+                end else if (csum_offset_reg >= KEEP_WIDTH) begin
+                    csum_offset_next = csum_offset_reg - KEEP_WIDTH[7:0];
+                end else if (csum_offset_reg == (KEEP_WIDTH - 1)) begin
+                    hi_mask_next    = {{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (KEEP_WIDTH - 1);
+                    lo_mask_next    = {KEEP_WIDTH{1'b0}};
                     csum_split_next = 1'b1;
                 end else begin
-                    m_axis_tdata_int[csum_offset_reg*8 +: 8] = csum_reg[15:8];
-                    m_axis_tdata_int[(csum_offset_reg+1)*8 +: 8] = csum_reg[7:0];
-
-                    csum_enable_next = 1'b0;
+                    hi_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << csum_offset_reg);
+                    lo_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (csum_offset_reg + 8'd1));
+                    csum_split_next = 1'b0;
                 end
             end
         end
     end else begin
-        csum_out_ready = 1'b1;
-        csum_next = csum_out_csum;
+        frame_next       = 1'b0;
+        csum_out_ready   = 1'b1;
+        csum_next        = csum_out_csum;
         csum_offset_next = csum_out_offset;
         csum_enable_next = csum_out_enable;
-        csum_split_next = 1'b0;
+        csum_split_next  = 1'b0;
+        hi_mask_next     = {KEEP_WIDTH{1'b0}};
+        lo_mask_next     = {KEEP_WIDTH{1'b0}};
         if (csum_out_valid) begin
             frame_next = 1'b1;
+            if (csum_out_enable) begin
+                if (csum_out_offset >= KEEP_WIDTH) begin
+                    csum_offset_next = csum_out_offset - KEEP_WIDTH[7:0];
+                end else if (csum_out_offset == (KEEP_WIDTH - 1)) begin
+                    hi_mask_next    = {{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (KEEP_WIDTH - 1);
+                    csum_split_next = 1'b1;
+                end else begin
+                    hi_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << csum_out_offset);
+                    lo_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (csum_out_offset + 8'd1));
+                end
+            end
         end
     end
 end
 
 always @(posedge clk) begin
-    frame_reg <= frame_next;
-
-    csum_reg <= csum_next;
-    csum_offset_reg <= csum_offset_next;
-    csum_enable_reg <= csum_enable_next;
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axis_fifo.v`](environment/public/code/axis_fifo.v) *(Read-Only Context)*
- [`environment/public/code/rx_checksum.v`](environment/public/code/rx_checksum.v) **(Editable)**
- [`environment/public/code/tx_checksum.v`](environment/public/code/tx_checksum.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/pdk/NangateOpenCellLibrary_typical.lib`](environment/public/pdk/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

