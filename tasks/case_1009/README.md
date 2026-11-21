# `case_1009`: OpenTitan HMAC Core and SHA-256 Padding Backpressure, Abort Recovery, and Timing/Area Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1009` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `reset_rdc` (Reset Recovery, Abort Drain, Reset Domain Crossing (RDC) & Boot Sequencing) |
| **Multi-Domain Tags** | `reset_rdc`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/hmac_core.sv`](environment/public/code/hmac_core.sv), [`code/prim_sha2_pad.sv`](environment/public/code/prim_sha2_pad.sv) (2 files, 816 LOC) |
| **Public Subsystem Context** | 10 RTL files (1761 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# OpenTitan HMAC Core and SHA-256 Padding Backpressure, Abort Recovery, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan HMAC and SHA-256 padding subsystem (`code/ot_hmac_pad_top.sv`), three issues were identified across functional simulation and Nangate45 synthesis/STA:

1. **HMAC Intermediate Digest Push Backpressure and Abort Recovery**:
   - When the inner SHA-256 pass completes in HMAC mode (`hmac_en_i = 1'b1`) and the controller pushes the 8-word intermediate digest back into the message FIFO (`fifo_wsel_o = 1'b1`, `fifo_wvalid_o = 1'b1`), `fifo_wdata_sel_o` advances even on cycles where the downstream FIFO stalls (`fifo_wready_i = 1'b0`), skipping digest words under backpressure.
   - When an in-flight operation is aborted (`abort_i = 1'b1`) after `reg_hash_process_i` has been pulsed, the latched process request is not cleared, causing a subsequent operation to prematurely transition to response waiting and padding before software issues a new process command.

2. **SHA-256 Padding Bit-Count and Last-Block Boundary**:
   - During message ingestion prior to `hash_process_i`, the padding bit counter advances whenever the downstream compression interface is ready (`shaf_rready_i = 1'b1`) even when the upstream message stream is not valid (`fifo_rvalid_i = 1'b0`), corrupting the accumulated message bit count under source stalls.
   - When the 1-bit (`0x80`) padding byte lands at the exact 512-bit block boundary preceding the 64-bit length field (`416` bits into the 512-bit block, i.e., `52` message bytes modulo `64`), the padding FSM fails to transition directly to emitting the 64-bit length words (`LenHi` / `LenLo`), producing an extra zero-padded block.

3. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_hmac_pad_top`, `2.75 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), the subsystem exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/hmac_core.sv` and `code/prim_sha2_pad.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_hmac_pad_top`: **`<= 4150.0 um^2`**
- Worst setup slack and worst hold slack at `2.75 ns` clock period: **`>= 0.0 ns`**

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/hmac_core.sv`
- `code/prim_sha2_pad.sv`

All other files in `code/` (`ot_hmac_pad_top.sv`, `prim_sha2_pkg.sv`, `prim_assert.sv`, `prim_flop_macros.sv`, `prim_assert_*.svh`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_hmac_pad_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/prim_sha2_pkg.sv code/prim_sha2_pad.sv code/hmac_core.sv \
  code/ot_hmac_pad_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_hmac_pad_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --ignore-assertions --top ot_hmac_pad_top -Icode -DSYNTHESIS \
    code/prim_sha2_pkg.sv code/prim_sha2_pad.sv code/hmac_core.sv code/ot_hmac_pad_top.sv;
  hierarchy -check -top ot_hmac_pad_top;
  synth -top ot_hmac_pad_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr /tmp/mapped.v
"
```

Target mapped cell area (`Chip area for module '\ot_hmac_pad_top'`): **`<= 4150.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.75 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_hmac_pad_top
create_clock -name clk_i -period 2.75 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded -digits 4
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded -digits 4
```

Target worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`): **`>= 0.0 ns`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/hmac_core.sv (Buggy Starter)
+++ b/solution/gold/code/hmac_core.sv (Golden Reference)
@@ -10,7 +10,7 @@
   input clk_i,
   input rst_ni,
 
-  input [1023:0]      secret_key_i, // {word0, word1, ..., word7}
+  input [1023:0]      secret_key_i,
   input               hmac_en_i,
   input digest_mode_e digest_size_i,
   input key_length_e  key_length_i,
@@ -26,7 +26,6 @@
   output logic sha_hash_process_o,
   input        sha_hash_done_i,
 
-  // fifo
   output logic        sha_rvalid_o,
   output sha_fifo32_t sha_rdata_o,
   input               sha_rready_i,
@@ -35,10 +34,8 @@
   input  sha_fifo32_t fifo_rdata_i,
   output logic        fifo_rready_o,
 
-  // fifo control (select and fifo write data)
-  output logic       fifo_wsel_o,      // 0: from reg, 1: from digest
+  output logic       fifo_wsel_o,
   output logic       fifo_wvalid_o,
-  // 0: digest[0][upper], 1:digest[0][lower] .. 14: digest[7][upper], 15: digest[7][lower]
   output logic [3:0] fifo_wdata_sel_o,
   input              fifo_wready_i,
 
@@ -50,186 +47,95 @@
 
   localparam int unsigned BlockSizeSHA256     = 512;
   localparam int unsigned BlockSizeSHA512     = 1024;
-
   localparam int unsigned BlockSizeBitsSHA256 = $clog2(BlockSizeSHA256);
   localparam int unsigned BlockSizeBitsSHA512 = $clog2(BlockSizeSHA512);
-
   localparam int unsigned HashWordBitsSHA256  = $clog2($bits(sha_word32_t));
-
-  localparam bit [63:0] BlockSizeSHA256in64  = 64'(BlockSizeSHA256);
-  localparam bit [63:0] BlockSizeSHA512in64  = 64'(BlockSizeSHA512);
-
-  logic hash_start;    // generated from internal state machine
-  logic hash_continue; // generated from internal state machine
-  logic hash_process;  // generated from internal state machine to trigger hash
-  logic hmac_hash_done;
-
-  logic [BlockSizeSHA256-1:0] i_pad_256;
-  logic [BlockSizeSHA512-1:0] i_pad_512;
-  logic [BlockSizeSHA256-1:0] o_pad_256;
-  logic [BlockSizeSHA512-1:0] o_pad_512;
-
-  logic [63:0] txcount, txcount_d; // works for both digest lengths
-
-  logic [BlockSizeBitsSHA512-HashWordBitsSHA256-1:0] pad_index_512;
-  logic [BlockSizeBitsSHA256-HashWordBitsSHA256-1:0] pad_index_256;
+  localparam bit [63:0] BlockSizeSHA256in64   = 64'(BlockSizeSHA256);
+  localparam bit [63:0] BlockSizeSHA512in64   = 64'(BlockSizeSHA512);
+
+  logic hash_start, hash_continue, hash_process, hmac_hash_done;
+  logic [63:0] txcount, txcount_d;
+  logic [4:0]  pad_index_512;
+  logic [3:0]  pad_index_256;
   logic clr_txcount, load_txcount, inc_txcount;
-
   logic hmac_sha_rvalid;
-
   logic idle_d, idle_q;
   logic reg_hash_stop_d, reg_hash_stop_q;
 
-  typedef enum logic [1:0] {
-    SelIPad,
-    SelOPad,
-    SelFifo
-  } sel_rdata_t;
-
+  typedef enum logic [1:0] { SelIPad, SelOPad, SelFifo } sel_rdata_t;
   sel_rdata_t sel_rdata;
-
-  typedef enum logic {
-    SelIPadMsg,
-    SelOPadMsg
-  } sel_msglen_t;
-
+  typedef enum logic { SelIPadMsg, SelOPadMsg } sel_msglen_t;
   sel_msglen_t sel_msglen;
-
-  typedef enum logic {
-    Inner,  // Update when state goes to StIPad
-    Outer   // Update when state enters StOPad
-  } round_t ;
-
-  logic update_round ;
+  typedef enum logic { Inner, Outer } round_t;
+  logic update_round;
   round_t round_q, round_d;
-
-  typedef enum logic [2:0] {
-    StIdle,
-    StIPad,
-    StMsg,              // Actual Msg, and Digest both
-    StPushToMsgFifo,    // Digest --> Msg Fifo
-    StWaitResp,         // Hash done( by checking processed_length? or hash_done)
-    StOPad,
-    StDone              // hmac_done
-  } st_e ;
-
+  typedef enum logic [2:0] { StIdle, StIPad, StMsg, StPushToMsgFifo, StWaitResp, StOPad, StDone } st_e;
   st_e st_q, st_d;
 
   logic clr_fifo_wdata_sel;
   logic txcnt_eq_blksz;
-
   logic reg_hash_process_flag;
 
   assign sha_hash_start_o    = (hmac_en_i) ? hash_start    : reg_hash_start_i;
   assign sha_hash_continue_o = (hmac_en_i) ? hash_continue : reg_hash_continue_i;
-
   assign sha_hash_process_o  = (hmac_en_i) ? reg_hash_process_i | hash_process : reg_hash_process_i;
   assign hash_done_o         = (hmac_en_i) ? hmac_hash_done                    : sha_hash_done_i;
 
   assign pad_index_512 = txcount[BlockSizeBitsSHA512-1:HashWordBitsSHA256];
   assign pad_index_256 = txcount[BlockSizeBitsSHA256-1:HashWordBitsSHA256];
 
-  // adjust inner and outer padding depending on key length and block size
-  always_comb begin : adjust_key_pad_length
-    // set defaults
-    i_pad_256 = '{default: '0};
-    i_pad_512 = '{default: '0};
-    o_pad_256 = '{default: '0};
-    o_pad_512 = '{default: '0};
-
+  logic [4:0]  pad_idx;
+  logic [31:0] key_word_sel, key_word_masked, pad_word;
+  logic        key_word_valid;
+  assign pad_idx = (digest_size_i == SHA2_256) ? {1'b0, pad_index_256} : pad_index_512;
+
+  always_comb begin
+    key_word_sel = '0;
+    for (int w = 0; w < 32; w++) begin
+      if (pad_idx == 5'(w)) begin
+        key_word_sel = secret_key_i[1023 - 32*w -: 32];
+      end
+    end
     unique case (key_length_i)
-      Key_128: begin
-        i_pad_256 = {secret_key_i[1023:896],
-                    {(BlockSizeSHA256-128){1'b0}}} ^ {(BlockSizeSHA256/8){8'h36}};
-        i_pad_512 = {secret_key_i[1023:896],
-                    {(BlockSizeSHA512-128){1'b0}}} ^ {(BlockSizeSHA512/8){8'h36}};
-        o_pad_256 = {secret_key_i[1023:896],
-                    {(BlockSizeSHA256-128){1'b0}}} ^ {(BlockSizeSHA256/8){8'h5c}};
-        o_pad_512 = {secret_key_i[1023:896],
-                    {(BlockSizeSHA512-128){1'b0}}} ^ {(BlockSizeSHA512/8){8'h5c}};
-      end
-      Key_256: begin
-        i_pad_256 = {secret_key_i[1023:768],
-                    {(BlockSizeSHA256-256){1'b0}}} ^ {(BlockSizeSHA256/8){8'h36}};
-        i_pad_512 = {secret_key_i[1023:768],
-                    {(BlockSizeSHA512-256){1'b0}}} ^ {(BlockSizeSHA512/8){8'h36}};
-        o_pad_256 = {secret_key_i[1023:768],
-                    {(BlockSizeSHA256-256){1'b0}}} ^ {(BlockSizeSHA256/8){8'h5c}};
-        o_pad_512 = {secret_key_i[1023:768],
-                    {(BlockSizeSHA512-256){1'b0}}} ^ {(BlockSizeSHA512/8){8'h5c}};
-      end
-      Key_384: begin
-        i_pad_256 = {secret_key_i[1023:640],
-                    {(BlockSizeSHA256-384){1'b0}}} ^ {(BlockSizeSHA256/8){8'h36}};
-        i_pad_512 = {secret_key_i[1023:640],
-                    {(BlockSizeSHA512-384){1'b0}}} ^ {(BlockSizeSHA512/8){8'h36}};
-        o_pad_256 = {secret_key_i[1023:640],
-                    {(BlockSizeSHA256-384){1'b0}}} ^ {(BlockSizeSHA256/8){8'h5c}};
-        o_pad_512 = {secret_key_i[1023:640],
-                    {(BlockSizeSHA512-384){1'b0}}} ^ {(BlockSizeSHA512/8){8'h5c}};
-      end
-      Key_512: begin
-        i_pad_256 = secret_key_i[1023:512] ^ {(BlockSizeSHA256/8){8'h36}};
-        i_pad_512 = {secret_key_i[1023:512],
-                    {(BlockSizeSHA512-512){1'b0}}} ^ {(BlockSizeSHA512/8){8'h36}};
-        o_pad_256 = secret_key_i[1023:512] ^ {(BlockSizeSHA256/8){8'h5c}};
-        o_pad_512 = {secret_key_i[1023:512],
-                    {(BlockSizeSHA512-512){1'b0}}} ^ {(BlockSizeSHA512/8){8'h5c}};
-      end
-      Key_1024: begin // not allowed to be configured for SHA-2 256
-        // zero out for SHA-2 256
-        i_pad_256 = '{default: '0};
-        i_pad_512 = secret_key_i[1023:0]   ^ {(BlockSizeSHA512/8){8'h36}};
-        // zero out for SHA-2 256
-        o_pad_256 = '{default: '0};
-        o_pad_512 = secret_key_i[1023:0]   ^ {(BlockSizeSHA512/8){8'h5c}};
-      end
-      default: begin
-      end
+      Key_128:  key_word_valid = (pad_idx[4:2] == 3'b000);
+      Key_256:  key_word_valid = (pad_idx[4:3] == 2'b00);
+      Key_384:  key_word_valid = (pad_idx[4] == 1'b0) && (pad_idx[3:2] != 2'b11);
+      Key_512:  key_word_valid = (pad_idx[4] == 1'b0);
+      Key_1024: key_word_valid = (digest_size_i == SHA2_384) || (digest_size_i == SHA2_512);
+      default:  key_word_valid = 1'b0;
     endcase
-  end
-
-  assign fifo_rready_o = (hmac_en_i) ? (st_q == StMsg) & sha_rready_i : sha_rready_i ;
-  // sha_rvalid is controlled by State Machine below.
-  assign sha_rvalid_o  = (!hmac_en_i) ? fifo_rvalid_i : hmac_sha_rvalid ;
+    key_word_masked = key_word_valid ? key_word_sel : 32'h0;
+    pad_word        = key_word_masked ^ {4{(sel_rdata == SelIPad) ? 8'h36 : 8'h5c}};
+  end
+
+  assign fifo_rready_o = (hmac_en_i) ? (st_q == StMsg) & sha_rready_i : sha_rready_i;
+  assign sha_rvalid_o  = (!hmac_en_i) ? fifo_rvalid_i : hmac_sha_rvalid;
   assign sha_rdata_o =
-    (!hmac_en_i)    ? fifo_rdata_i                                                             :
-    (sel_rdata == SelIPad && digest_size_i == SHA2_256)
-                  ? '{data: i_pad_256[(BlockSizeSHA256-1)-32*pad_index_256-:32], mask: '1} :
-    (sel_rdata == SelIPad && ((digest_size_i == SHA2_384) || (digest_size_i == SHA2_512)))
-                  ? '{data: i_pad_512[(BlockSizeSHA512-1)-32*pad_index_512-:32], mask: '1} :
-    (sel_rdata == SelOPad && digest_size_i == SHA2_256)
-                  ? '{data: o_pad_256[(BlockSizeSHA256-1)-32*pad_index_256-:32], mask: '1} :
-    (sel_rdata == SelOPad && ((digest_size_i == SHA2_384) || (digest_size_i == SHA2_512)))
-                  ? '{data: o_pad_512[(BlockSizeSHA512-1)-32*pad_index_512-:32], mask: '1} :
-    // Well-defined default case `sel_rdata == SelFifo`. `sel_rdata == 2'b11` cannot occur.
-                  fifo_rdata_i;
+    (!hmac_en_i) ? fifo_rdata_i :
+    ((sel_rdata == SelIPad || sel_rdata == SelOPad) &&
+     (digest_size_i == SHA2_256 || digest_size_i == SHA2_384 || digest_size_i == SHA2_512))
+                 ? '{data: pad_word, mask: '1} :
+                 fifo_rdata_i;
 
   logic [63:0] sha_msg_len;
-
-  always_comb begin: assign_sha_message_length
+  always_comb begin : assign_sha_message_length
     sha_msg_len = '0;
     if (!hmac_en_i) begin
       sha_msg_len = message_length_i;
-    // HASH = (o_pad || HASH_INTERMEDIATE (i_pad || msg))
-    // message length for HASH_INTERMEDIATE = block size (i_pad) + message length
     end else if (sel_msglen == SelIPadMsg) begin
       if (digest_size_i == SHA2_256) begin
-        sha_msg_len = message_length_i + BlockSizeSHA256in64;
+        sha_msg_len = {message_length_i[63:9] + 55'd1, message_length_i[8:0]};
       end else if ((digest_size_i == SHA2_384) || (digest_size_i == SHA2_512)) begin
-        sha_msg_len = message_length_i + BlockSizeSHA512in64;
-      // `SHA2_None` is a permissible value in the `SelIPadMsg` case. It can not occur for the
-      // `SelOPadMsg` message length.
+        sha_msg_len = {message_length_i[63:10] + 54'd1, message_length_i[9:0]};
       end else begin
         sha_msg_len = '0;
       end
-    end else begin // `SelOPadMsg`
-      // message length for HASH = block size (o_pad) + HASH_INTERMEDIATE digest length
+    end else begin
       if (digest_size_i == SHA2_256) begin
         sha_msg_len = BlockSizeSHA256in64 + 64'd256;
       end else if (digest_size_i == SHA2_384) begin
         sha_msg_len = BlockSizeSHA512in64 + 64'd384;
-      end else begin // SHA512
+      end else begin
         sha_msg_len = BlockSizeSHA512in64 + 64'd512;
       end
     end
@@ -239,12 +145,11 @@
 
   always_comb begin
     txcnt_eq_blksz = '0;
-
     unique case (digest_size_i)
       SHA2_256: txcnt_eq_blksz = (txcount[BlockSizeBitsSHA256-1:0] == '0) && (txcount != '0);
       SHA2_384: txcnt_eq_blksz = (txcount[BlockSizeBitsSHA512-1:0] == '0) && (txcount != '0);
       SHA2_512: txcnt_eq_blksz = (txcount[BlockSizeBitsSHA512-1:0] == '0) && (txcount != '0);
-      default;
+      default: ;
     endcase
   end
 
@@ -255,16 +160,9 @@
     if (clr_txcount) begin
       txcount_d = '0;
     end else if (load_txcount) begin
-      // When loading, add block size to the message length because the SW-visible message length
-      // does not include the block containing the key xor'ed with the inner pad.
-      unique case (digest_size_i)
-        SHA2_256: txcount_d = message_length_i + BlockSizeSHA256in64;
-        SHA2_384: txcount_d = message_length_i + BlockSizeSHA512in64;
-        SHA2_512: txcount_d = message_length_i + BlockSizeSHA512in64;
-        default : txcount_d = message_length_i + '0;
-      endcase
+      txcount_d = message_length_i;
     end else if (inc_txcount) begin
-      txcount_d[63:5] = txcount[63:5] + 1'b1; // increment by 32 (data word size)
+      txcount_d[63:5] = txcount[63:5] + 59'd1;
     end
   end
 
@@ -273,13 +171,12 @@
     else         txcount <= txcount_d;
   end
 
-  // reg_hash_process_i trigger logic. An abort clears the flag as the operation is discarded.
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
       reg_hash_process_flag <= 1'b0;
     end else if (reg_hash_process_i) begin
       reg_hash_process_flag <= 1'b1;
-    end else if (hmac_hash_done) begin
+    end else if (hmac_hash_done || reg_hash_start_i || reg_hash_continue_i || abort_i) begin
       reg_hash_process_flag <= 1'b0;
     end
   end
@@ -297,16 +194,31 @@
       fifo_wdata_sel_o <= '0;
     end else if (clr_fifo_wdata_sel) begin
       fifo_wdata_sel_o <= '0;
-    end else if (fifo_wsel_o && fifo_wvalid_o) begin
-      fifo_wdata_sel_o <= fifo_wdata_sel_o + 1'b1; // increment by 1
-    end
-  end
-
-  assign sel_msglen = (round_q == Inner) ? SelIPadMsg : SelOPadMsg ;
+    end else if (fifo_wsel_o && fifo_wvalid_o && fifo_wready_i) begin
+      fifo_wdata_sel_o <= fifo_wdata_sel_o + 1'b1;
+    end
+  end
+
+  assign sel_msglen = (round_q == Inner) ? SelIPadMsg : SelOPadMsg;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : state_ff
     if (!rst_ni) st_q <= StIdle;
     else         st_q <= st_d;
+  end
+
+  logic txcnt_ge_target;
+  always_comb begin
+    if (round_q == Outer) begin
+      if (digest_size_i == SHA2_256) begin
+        txcnt_ge_target = (txcount[63:5] >= 59'd8);
+      end else if (digest_size_i == SHA2_384) begin
+        txcnt_ge_target = (txcount[63:5] >= 59'd12);
+      end else begin
+        txcnt_ge_target = (txcount[63:5] >= 59'd16);
+      end
+    end else begin
+      txcnt_ge_target = (txcount >= message_length_i);
+    end
   end
 
   always_comb begin : next_state
@@ -316,7 +228,7 @@
     load_txcount       = 1'b0;
     update_round       = 1'b0;
     round_d            = Inner;
-    fifo_wsel_o        = 1'b0;   // from register
+    fifo_wsel_o        = 1'b0;
     fifo_wvalid_o      = 1'b0;
     clr_fifo_wdata_sel = 1'b1;
     sel_rdata          = SelFifo;
@@ -330,13 +242,11 @@
         update_round = 1'b1;
         round_d      = Inner;
         if (hmac_en_i && reg_hash_start_i) begin
-          st_d = StIPad; // start at StIPad if told to start
-
-          clr_txcount  = 1'b1;
-          hash_start   = 1'b1;
+          st_d        = StIPad;
+          clr_txcount = 1'b1;
+          hash_start  = 1'b1;
         end else if (hmac_en_i && reg_hash_continue_i) begin
-          st_d = StMsg; // skip StIPad if told to continue - assumed it finished StIPad
-
+          st_d          = StMsg;
           load_txcount  = 1'b1;
           hash_continue = 1'b1;
         end else begin
@@ -346,14 +256,12 @@
 
       StIPad: begin
         sel_rdata = SelIPad;
-
         if (txcnt_eq_blksz) begin
-          st_d = StMsg;
-
-          hmac_sha_rvalid = 1'b0; // block new read request
-        end else begin
-          st_d = StIPad;
-
+          st_d            = StMsg;
+          clr_txcount     = 1'b1;
+          hmac_sha_rvalid = 1'b0;
+        end else begin
+          st_d            = StIPad;
           hmac_sha_rvalid = 1'b1;
         end
       end
@@ -361,17 +269,12 @@
       StMsg: begin
         sel_rdata   = SelFifo;
         fifo_wsel_o = (round_q == Outer);
-
-        if ( (((round_q == Inner) && reg_hash_process_flag) || (round_q == Outer))
-            && (txcount >= sha_message_length_o)) begin
-          st_d    = StWaitResp;
-
-          hmac_sha_rvalid = 1'b0; // block reading words from MSG FIFO
+        if ((((round_q == Inner) && reg_hash_process_flag) || (round_q == Outer)) && txcnt_ge_target) begin
+          st_d            = StWaitResp;
+          hmac_sha_rvalid = 1'b0;
           hash_process    = (round_q == Outer);
-        end else if (txcnt_eq_blksz && (txcount >= sha_message_length_o)
-                     && reg_hash_stop_q && (round_q == Inner)) begin
-          st_d =  StWaitResp;
-
+        end else if (txcnt_eq_blksz && txcnt_ge_target && reg_hash_stop_q && (round_q == Inner)) begin
+          st_d            = StWaitResp;
           hmac_sha_rvalid = 1'b0;
         end else begin
           st_d            = StMsg;
@@ -381,16 +284,13 @@
 
       StWaitResp: begin
         hmac_sha_rvalid = 1'b0;
-
         if (sha_hash_done_i) begin
           if (round_q == Outer) begin
             st_d = StDone;
-          end else begin // round_q == Inner
-            if (reg_hash_stop_q) begin
-              st_d = StDone;
-            end else begin
-              st_d = StPushToMsgFifo;
-            end
+          end else if (reg_hash_stop_q) begin
+            st_d = StDone;
+          end else begin
+            st_d = StPushToMsgFifo;
           end
         end else begin
           st_d = StWaitResp;
@@ -402,53 +302,45 @@
         fifo_wsel_o        = 1'b1;
         fifo_wvalid_o      = 1'b1;
         clr_fifo_wdata_sel = 1'b0;
-
-        if (fifo_wready_i && (((fifo_wdata_sel_o == 4'd7) && (digest_size_i == SHA2_256)) ||
-                             ((fifo_wdata_sel_o == 4'd15) && (digest_size_i == SHA2_512)) ||
-                             ((fifo_wdata_sel_o == 4'd11) && (digest_size_i == SHA2_384)))) begin
-
-          st_d = StOPad;
-
+        if (fifo_wready_i && (((fifo_wdata_sel_o == 4'd7)  && (digest_size_i == SHA2_256)) ||
+                              ((fifo_wdata_sel_o == 4'd15) && (digest_size_i == SHA2_512)) ||
+                              ((fifo_wdata_sel_o == 4'd11) && (digest_size_i == SHA2_384)))) begin
+          st_d         = StOPad;
           clr_txcount  = 1'b1;
           update_round = 1'b1;
           round_d      = Outer;
           hash_start   = 1'b1;
         end else begin
           st_d = StPushToMsgFifo;
-
         end
       end
 
       StOPad: begin
         sel_rdata   = SelOPad;
-        fifo_wsel_o = 1'b1; // Remained HMAC select to indicate HMAC is in second stage
-
+        fifo_wsel_o = 1'b1;
         if (txcnt_eq_blksz) begin
-          st_d = StMsg;
-
-          hmac_sha_rvalid = 1'b0; // block new read request
-        end else begin
-          st_d = StOPad;
-
+          st_d            = StMsg;
+          clr_txcount     = 1'b1;
+          hmac_sha_rvalid = 1'b0;
+        end else begin
+          st_d            = StOPad;
           hmac_sha_rvalid = 1'b1;
         end
       end
 
       StDone: begin
-        // raise interrupt (hash_done)
-        st_d = StIdle;
-
+        st_d           = StIdle;
         hmac_hash_done = 1'b1;
       end
 
       default: begin
         st_d = StIdle;
       end
-
     endcase
 
     if (abort_i) begin
       hmac_hash_done = 1'b0;
+      st_d           = StIdle;
     end
   end
 
@@ -458,32 +350,20 @@
                                                                                   reg_hash_stop_q;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
-    if (!rst_ni) begin
-      reg_hash_stop_q <= 1'b0;
-    end else begin
-      reg_hash_stop_q <= reg_hash_stop_d;
-    end
-  end
-
-  assign idle_d =
-      (reg_hash_start_i || reg_hash_continue_i) ? 1'b0 :
-      (st_q == StIdle) ? 1'b1 :
-      (txcnt_eq_blksz && reg_hash_stop_d) ? 1'b1 :
-      idle_q;
-
+    if (!rst_ni) reg_hash_stop_q <= 1'b0;
+    else         reg_hash_stop_q <= reg_hash_stop_d;
+  end
+
+  assign idle_d = (reg_hash_start_i || reg_hash_continue_i) ? 1'b0 :
+                  (st_q == StIdle)                          ? 1'b1 :
+                  (txcnt_eq_blksz && reg_hash_stop_d)       ? 1'b1 :
+                                                              idle_q;
   assign idle_o = idle_d;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
-    if (!rst_ni) begin
-      idle_q <= 1'b1;
-    end else begin
-      idle_q <= idle_d;
-    end
-  end
-
-  ////////////////
-  // Assertions //
-  ////////////////
+    if (!rst_ni) idle_q <= 1'b1;
+    else         idle_q <= idle_d;
+  end
 
   `ASSERT(ValidSelRdata_A, hmac_en_i |-> sel_rdata inside {SelIPad, SelOPad, SelFifo})
   `ASSERT(ValidDigestSize_A, (hmac_en_i && (sel_msglen == SelOPadMsg)) |->

--- a/environment/public/code/prim_sha2_pad.sv (Buggy Starter)
+++ b/solution/gold/code/prim_sha2_pad.sv (Golden Reference)
@@ -13,11 +13,9 @@
   input clk_i,
   input rst_ni,
 
-  // to actual FIFO
   input                 fifo_rvalid_i,
   input  sha_fifo64_t   fifo_rdata_i,
   output logic          fifo_rready_o,
-  // from SHA2 compression engine
   output logic          shaf_rvalid_o,
   output sha_word64_t   shaf_rdata_o,
   input                 shaf_rready_i,
@@ -28,11 +26,11 @@
   input digest_mode_e   digest_mode_i,
   input                 hash_process_i,
   input                 hash_done_i,
-  input        [127:0]  message_length_i,   // # of bytes in bits (8 bits granularity)
-  output logic          msg_feed_complete_o // indicates all message is feeded
+  input        [127:0]  message_length_i,
+  output logic          msg_feed_complete_o
 );
 
-  logic [127:0] tx_count_d, tx_count;    // fin received data count.
+  logic [127:0] tx_count_d, tx_count;
   logic         inc_txcount;
   logic         fifo_partial;
   logic         txcnt_eq_1a0;
@@ -54,7 +52,7 @@
                                       ~&fifo_rdata_i.mask[3:0];
 
   assign txcnt_eq_1a0 = (digest_mode_flag_q == SHA2_256   || ~MultimodeEn)               ?
-                                                                        (tx_count[8:0] == 9'h1c0)  :
+                                                                        (tx_count[8:0] == 9'h1a0)  :
                         ((digest_mode_flag_q == SHA2_384) || (digest_mode_flag_q == SHA2_512)) ?
                                                                         (tx_count[9:0] == 10'h340) :
                                                                         '0;
@@ -84,11 +82,11 @@
   end
 
   typedef enum logic [2:0] {
-    FifoIn,         // fin_wdata, fin_wstrb
-    Pad80,          // {8'h80, 8'h00} , strb (calc based on len[4:3])
-    Pad00,          // 32'h0, full strb
-    LenHi,          // len[63:32], full strb
-    LenLo           // len[31:0], full strb
+    FifoIn,
+    Pad80,
+    Pad00,
+    LenHi,
+    LenLo
   } sel_data_e;
   sel_data_e sel_data;
 
@@ -104,9 +102,9 @@
             2'b 00:  shaf_rdata_o = 64'h 0000_0000_8000_0000;
             2'b 01:  shaf_rdata_o = {32'h 0000_0000, fifo_rdata_i.data[31:24], 24'h 8000_00};
             2'b 10:  shaf_rdata_o = {32'h 0000_0000, fifo_rdata_i.data[31:16], 16'h 8000};
-            default: shaf_rdata_o = {32'h 0000_0000, fifo_rdata_i.data[31: 8],  8'h 80}; // 2'b11
+            default: shaf_rdata_o = {32'h 0000_0000, fifo_rdata_i.data[31: 8],  8'h 80};
           endcase
-        end else begin // SHA384 || SHA512
+        end else begin
           unique case (message_length_i[5:3])
             3'b 000: shaf_rdata_o = 64'h 8000_0000_0000_0000;
             3'b 001: shaf_rdata_o = {fifo_rdata_i.data[63:56], 56'h 8000_0000_0000_00};
@@ -115,7 +113,7 @@
             3'b 100: shaf_rdata_o = {fifo_rdata_i.data[63:32], 32'h 8000_0000};
             3'b 101: shaf_rdata_o = {fifo_rdata_i.data[63:24], 24'h 8000_00};
             3'b 110: shaf_rdata_o = {fifo_rdata_i.data[63:16], 16'h 8000};
-            default: shaf_rdata_o = {fifo_rdata_i.data[63:8],  8'h 80}; // 3'b111
+            default: shaf_rdata_o = {fifo_rdata_i.data[63:8],  8'h 80};
           endcase
         end
       end
@@ -127,13 +125,13 @@
       LenHi: begin
         shaf_rdata_o = ((digest_mode_flag_q == SHA2_256) || ~MultimodeEn) ?
                        {32'b0, message_length_i[63:32]} :
-                       message_length_i[127:64]; // SHA384 || SHA512
+                       message_length_i[127:64];
       end
 
       LenLo: begin
         shaf_rdata_o = ((digest_mode_flag_q == SHA2_256) || ~MultimodeEn) ?
                        {32'b0, message_length_i[31:0]} :
-                       message_length_i[63:0]; // SHA384 || SHA512
+                       message_length_i[63:0];
       end
 
       default: begin
@@ -189,7 +187,7 @@
         end else if (!hash_process_flag_q) begin
           fifo_rready_o = shaf_rready_i;
           shaf_rvalid_o = fifo_rvalid_i;
-          inc_txcount   = shaf_rready_i;
+          inc_txcount   = shaf_rready_i && fifo_rvalid_i;
           st_d = StFifoReceive;
         end else if (txcnt_eq_msg_len) begin
           shaf_rvalid_o = 1'b0;
@@ -199,7 +197,7 @@
         end else begin
           shaf_rvalid_o = fifo_rvalid_i;
           fifo_rready_o = shaf_rready_i;
-          inc_txcount   = shaf_rready_i;
+     
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/hmac_core.sv`](environment/public/code/hmac_core.sv) **(Editable)**
- [`environment/public/code/ot_hmac_pad_top.sv`](environment/public/code/ot_hmac_pad_top.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sha2_pad.sv`](environment/public/code/prim_sha2_pad.sv) **(Editable)**
- [`environment/public/code/prim_sha2_pkg.sv`](environment/public/code/prim_sha2_pkg.sv) *(Read-Only Context)*
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

