# `case_1003`: OpenTitan KMAC Message Packer, FIFO Flush Control, and Error Checker Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1003` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `parameters_widths`, `protocol_control`, `reset_rdc`, `rtl_integration`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/prim_packer.sv`](environment/public/code/prim_packer.sv), [`code/kmac_msgfifo.sv`](environment/public/code/kmac_msgfifo.sv), [`code/kmac_errchk.sv`](environment/public/code/kmac_errchk.sv) (3 files, 1188 LOC) |
| **Public Subsystem Context** | 24 RTL files (6048 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# OpenTitan KMAC Message Packer, FIFO Flush Control, and Error Checker Closure

In `code/kmac_msg_err_top.sv`, update `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, and `code/kmac_errchk.sv` to resolve coupled byte-packing, flush-gating, and command-blocking defects. In `prim_packer` and `kmac_msgfifo`, pack byte-granular input beats (`fifo_data_i`, `fifo_strb_i`) into `msg_data_o` and `msg_strb_o` across arbitrary leading byte offsets and simultaneous input/output handshakes while suppressing `fifo_ready_o` (when `fifo_bypass_i == 0`) and `ready_o` throughout the entire flush sequence—from the cycle `flush_i` asserts until the flush completes and is cleared by `clear_i` (`CmdDone` or `clear_after_error_i`)—and returning immediately to the idle ready state whenever `clear_i` is `MuBi4True` in any flush state; in bypass mode (`fifo_bypass_i == 1`), forward `flush_i` directly to `flush_done_o`. In `kmac_errchk`, validate mode/strength, `EncodedStringKMAC` prefix (`cfg_prefix_6B_i` when `kmac_en_i == 1`), sideload context-switch restrictions (`cfg_sideload_i`), and command sequences, and drive `sw_cmd_o <= CmdNone` on the next rising `clk_i` edge whenever `sw_cmd_i` is blocked by an error, rejected in idle or state-write because `app_active_i` is high, or preempted by `lc_escalate_en_i` (which enters a sticky terminal error state that ignores `clear_after_error_i`).

Under the Nangate45 Yosys/Slang synthesis flow (`BUILD.md`), `kmac_msg_err_top` must map to `<= 2,260.0 um^2`, and OpenROAD STA must achieve setup and hold slack `>= 0.0 ns` at a `1.50 ns` `clk_i` period (`0.20 ns` data input delay, `0.50 ns` `rst_ni` input delay, `0.35 ns` output delay, `5.0 fF` load). Edit only `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, and `code/kmac_errchk.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/prim_packer.sv`: OpenTitan byte-aligned stream packer (**editable target**).
- `code/kmac_msgfifo.sv`: OpenTitan KMAC message packer and FIFO controller (**editable target**).
- `code/kmac_errchk.sv`: OpenTitan KMAC software command and configuration checker (**editable target**).
- `code/kmac_msg_err_top.sv`: Top-level KMAC message and command front-end wrapper (read-only).
- `code/prim_*.sv`, `code/prim_*.svh`, `code/*_pkg.sv`: Upstream OpenTitan packages and primitives (read-only).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.

Edit only `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, and `code/kmac_errchk.sv`.

## 2. Functional Simulation (Verilator)

```bash
verilator --binary --timing -j 1 -Wno-fatal -DSYNTHESIS -Icode --top-module tb \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/lc_ctrl_reg_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_pkg.sv \
  code/sha3_pkg.sv code/kmac_pkg.sv code/prim_flop.sv \
  code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_packer.sv code/kmac_msgfifo.sv code/kmac_errchk.sv \
  code/kmac_msg_err_top.sv tb.sv
./obj_dir/Vtb
```

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top kmac_msg_err_top -DSYNTHESIS -I code \
    code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/lc_ctrl_reg_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_pkg.sv \
    code/sha3_pkg.sv code/kmac_pkg.sv code/prim_flop.sv \
    code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
    code/prim_packer.sv code/kmac_msgfifo.sv code/kmac_errchk.sv \
    code/kmac_msg_err_top.sv
  hierarchy -check -top kmac_msg_err_top
  synth -top kmac_msg_err_top
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```

The reported `Chip area for module '\kmac_msg_err_top':` must be `<= 2260.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD (`openroad -exit flow.tcl`) with:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design kmac_msg_err_top
initialize_floorplan -die_area {0 0 120 120} -core_area {10 10 110 110} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 1.50 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_input_delay 0.50 -clock clk_i [get_ports rst_ni]
set_output_delay 0.35 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
```

Both the worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`) must be `>= 0.0` (`ns`), with an empty `check_setup -verbose` audit block.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/prim_packer.sv (Buggy Starter)
+++ b/solution/gold/code/prim_packer.sv (Golden Reference)
@@ -1,21 +1,10 @@
-// Copyright lowRISC contributors (OpenTitan project).
-// Licensed under the Apache License, Version 2.0, see LICENSE for details.
-// SPDX-License-Identifier: Apache-2.0
-//
-// Combine InW data and write to OutW data if packed to full word or stop signal
-
 `include "prim_assert.sv"
 
-// ICEBOX(#12958): Revise to send out the empty status.
 module prim_packer #(
   parameter int unsigned InW  = 32,
   parameter int unsigned OutW = 32,
-
-  // If 1, The input/output are byte granularity
   parameter int HintByteData = 0,
-
-  // Turn on protect against FI for the pos variable
-  parameter bit EnProtection = 1'b 0
+  parameter bit EnProtection = 1'b0
 ) (
   input clk_i ,
   input rst_ni,
@@ -30,201 +19,154 @@
   output logic [OutW-1:0] mask_o,
   input                   ready_i,
 
-  input                   flush_i,  // If 1, send out remnant and clear state
+  input                   flush_i,
   output logic            flush_done_o,
 
-  // When EnProtection is set, err_o raises an error case (position variable
-  // mismatch)
   output logic            err_o
 );
 
-  localparam int unsigned Width    = InW + OutW;  // storage width
-  localparam int unsigned ConcatW  = Width + InW; // Input concatenated width
-  localparam int unsigned PtrW     = $clog2(ConcatW+1);
-  localparam int unsigned IdxW     = prim_util_pkg::vbits(InW);
-  localparam int unsigned OnesCntW = $clog2(InW+1);
-
-  logic valid_next, ready_next;
-  logic [Width-1:0]   stored_data, stored_mask;
-  logic [ConcatW-1:0] concat_data, concat_mask;
-  logic [ConcatW-1:0] shiftl_data, shiftl_mask;
-  logic [InW-1:0]     shiftr_data, shiftr_mask;
-
-  logic [PtrW-1:0]     pos_q;         // Current write position
-  logic [IdxW-1:0]     lod_idx;       // result of Leading One Detector
-  logic [OnesCntW-1:0] inmask_ones;   // Counting Ones for mask_i
+  localparam int unsigned InB     = InW / 8;
+  localparam int unsigned OutB    = OutW / 8;
+  localparam int unsigned WidthB  = InB + OutB;
+  localparam int unsigned ConcatB = WidthB + InB;
+  localparam int unsigned PtrBW   = $clog2(ConcatB+1);
+  localparam int unsigned IdxBW   = prim_util_pkg::vbits(InB);
+  localparam int unsigned OnesBW  = $clog2(InB+1);
+
+  logic [InB-1:0] in_bmask;
+  logic [InW-1:0] in_data_masked;
+  for (genvar i = 0; i < InB; i++) begin : g_in_bmask
+    assign in_bmask[i] = |mask_i[8*i +: 8];
+    assign in_data_masked[8*i +: 8] = (valid_i && in_bmask[i]) ? data_i[8*i +: 8] : 8'h00;
+  end
+
+  logic [OnesBW-1:0] inmask_bytes;
+  logic [IdxBW-1:0]  lod_bidx;
+  always_comb begin
+    inmask_bytes = '0;
+    lod_bidx = '0;
+    for (int i = 0; i < InB; i++) begin
+      inmask_bytes = inmask_bytes + OnesBW'(in_bmask[i]);
+    end
+    for (int i = InB-1; i >= 0; i--) begin
+      if (in_bmask[i]) lod_bidx = IdxBW'(unsigned'(i));
+    end
+  end
+
+  logic [PtrBW-1:0] pos_b_q, pos_b_d;
+  wire  [PtrBW-1:0] pos_b_with_in = pos_b_q + PtrBW'(inmask_bytes);
 
   logic ack_in, ack_out;
-
-  logic flush_valid; // flush data out request
-  logic flush_done;
-
-  // Computing next position ==================================================
-  always_comb begin
-    // counting mask_i ones
-    inmask_ones = '0;
-    for (int i = 0 ; i < InW ; i++) begin
-      inmask_ones = inmask_ones + OnesCntW'(mask_i[i]);
-    end
-  end
-
-  logic [PtrW-1:0] pos_with_input;
-  assign pos_with_input = pos_q + PtrW'(inmask_ones);
-
-  if (EnProtection == 1'b 0) begin : g_pos_nodup
-    logic [PtrW-1:0] pos_d;
-
-    always_comb begin
-      pos_d = pos_q;
-
-      unique case ({ack_in, ack_out})
-        2'b00: pos_d = pos_q;
-        2'b01: pos_d = (int'(pos_q) <= OutW) ? '0 : pos_q - PtrW'(OutW);
-        2'b10: pos_d = pos_with_input;
-        2'b11: pos_d = (int'(pos_with_input) <= OutW) ? '0 : pos_with_input - PtrW'(OutW);
-        default: pos_d = pos_q;
-      endcase
-    end
-
+  logic flush_valid, flush_done;
+
+  always_comb begin
+    unique case ({ack_in, ack_out})
+      2'b00: pos_b_d = pos_b_q;
+      2'b01: pos_b_d = (int'(pos_b_q) <= OutB) ? '0 : pos_b_q - PtrBW'(OutB);
+      2'b10: pos_b_d = pos_b_with_in;
+      2'b11: pos_b_d = (int'(pos_b_with_in) <= OutB) ? '0 : pos_b_with_in - PtrBW'(OutB);
+      default: pos_b_d = pos_b_q;
+    endcase
+  end
+
+  logic cnt_err;
+  if (EnProtection == 1'b0) begin : g_pos_nodup
     always_ff @(posedge clk_i or negedge rst_ni) begin
       if (!rst_ni) begin
-        pos_q <= '0;
+        pos_b_q <= '0;
       end else if (flush_done) begin
-        pos_q <= '0;
+        pos_b_q <= '0;
       end else begin
-        pos_q <= pos_d;
-      end
-    end
-
-    assign err_o = 1'b 0; // No checker logic
-
-  end else begin : g_pos_dupcnt // EnProtection == 1'b 1
-    // incr_en: Increase the pos by cnt_step. ack_in && !ack_out
-    // decr_en: Decrease the pos by cnt_step. !ack_in && ack_out
-    // set_en:  Set to specific value in case of ack_in && ack_out.
-    //          This case, the value could be increased or decreased based on
-    //          the input size (inmask_ones)
-    logic            cnt_incr_en, cnt_decr_en, cnt_set_en;
-    logic [PtrW-1:0] cnt_step, cnt_set;
-
+        pos_b_q <= pos_b_d;
+      end
+    end
+    assign cnt_err = 1'b0;
+  end else begin : g_pos_dupcnt
+    logic             cnt_incr_en, cnt_decr_en, cnt_set_en;
+    logic [PtrBW-1:0] cnt_step, cnt_set;
     assign cnt_incr_en =  ack_in && !ack_out;
     assign cnt_decr_en = !ack_in &&  ack_out;
     assign cnt_set_en  =  ack_in &&  ack_out;
-
-    // counter has underflow protection.
-    assign cnt_step = (cnt_incr_en) ? PtrW'(inmask_ones) : PtrW'(OutW);
-
-    always_comb begin : cnt_set_logic
-
-      // default, consuming all data
-      cnt_set = '0;
-
-      if (pos_with_input > PtrW'(OutW)) begin
-        // pos_q + inmask_ones is bigger than Output width. Still data remained.
-        cnt_set = pos_with_input - PtrW'(OutW);
-      end
-    end : cnt_set_logic
-
+    assign cnt_step    = cnt_incr_en ? PtrBW'(inmask_bytes) : PtrBW'(OutB);
+    assign cnt_set     = (pos_b_with_in > PtrBW'(OutB)) ? (pos_b_with_in - PtrBW'(OutB)) : '0;
 
     prim_count #(
-      .Width      (PtrW),
-      .ResetValue ('0  )
+      .Width      (PtrBW),
+      .ResetValue ('0)
     ) u_pos (
       .clk_i,
       .rst_ni,
-
       .clr_i              (flush_done),
-
       .set_i              (cnt_set_en),
-      .set_cnt_i          (cnt_set   ),
-
+      .set_cnt_i          (cnt_set),
       .incr_en_i          (cnt_incr_en),
       .decr_en_i          (cnt_decr_en),
-      .step_i             (cnt_step   ),
-      .commit_i           (1'b1       ),
-
-      .cnt_o              (pos_q     ), // Current counter state
-      .cnt_after_commit_o (          ), // Next counter state
-
-      .err_o
+      .step_i             (cnt_step),
+      .commit_i           (1'b1),
+      .cnt_o              (pos_b_q),
+      .cnt_after_commit_o (),
+      .err_o              (cnt_err)
     );
-  end // g_pos_dupcnt
-
-  //---------------------------------------------------------------------------
-
-  // Leading one detector for mask_i
-  always_comb begin
-    lod_idx = 0;
-    for (int i = InW-1; i >= 0 ; i--) begin
-      if (mask_i[i] == 1'b1) begin
-        lod_idx = IdxW'(unsigned'(i));
-      end
-    end
-  end
-
-  assign ack_in  = valid_i & ready_o;
-  assign ack_out = valid_o & ready_i;
-
-  // Data process =============================================================
-  //  shiftr : Input data shifted right to put the leading one at bit zero
-  assign shiftr_data = (valid_i) ? data_i >> lod_idx : '0;
-  assign shiftr_mask = (valid_i) ? mask_i >> lod_idx : '0;
-
-  //  shiftl : Input data shifted into the current stored position
-  assign shiftl_data = ConcatW'(shiftr_data) << pos_q;
-  assign shiftl_mask = ConcatW'(shiftr_mask) << pos_q;
-
-  // concat : Merging stored and shiftl
-  assign concat_data = {{(InW){1'b0}}, stored_data & stored_mask} |
-                       (shiftl_data & shiftl_mask);
-  assign concat_mask = {{(InW){1'b0}}, stored_mask} | shiftl_mask;
-
-  logic [Width-1:0] stored_data_next, stored_mask_next;
+  end
+
+  assign err_o = cnt_err;
+
+  logic [WidthB*8-1:0] stored_data_q, stored_data_d;
+  logic [WidthB-1:0]   stored_bmask_q, stored_bmask_d;
+
+  logic [InW-1:0]       shiftr_data;
+  logic [InB-1:0]       shiftr_bmask;
+  logic [ConcatB*8-1:0] shiftl_data, concat_data;
+  logic [ConcatB-1:0]   shiftl_bmask, concat_bmask;
+
+  assign shiftr_data  = in_data_masked >> {lod_bidx, 3'b000};
+  assign shiftr_bmask = valid_i ? (in_bmask >> lod_bidx) : '0;
+
+  wire [PtrBW-1:0] eff_pos_b = (ack_out && (int'(pos_b_q) >= OutB)) ? (pos_b_q - PtrBW'(OutB)) : pos_b_q;
+  assign shiftl_data  = (ConcatB*8)'(shiftr_data) << {eff_pos_b, 3'b000};
+  assign shiftl_bmask = ConcatB'(shiftr_bmask) << eff_pos_b;
+
+  assign concat_data  = {{InW{1'b0}}, stored_data_q} | shiftl_data;
+  assign concat_bmask = {{InB{1'b0}}, stored_bmask_q} | shiftl_bmask;
 
   always_comb begin
     unique case ({ack_in, ack_out})
-      2'b 00: begin
-        stored_data_next = stored_data;
-        stored_mask_next = stored_mask;
-      end
-      2'b 01: begin
-        // ack_out : shift the amount of OutW
-        stored_data_next = {{OutW{1'b0}}, stored_data[Width-1:OutW]};
-        stored_mask_next = {{OutW{1'b0}}, stored_mask[Width-1:OutW]};
-      end
-      2'b 10: begin
-        // ack_in : Store concat data
-        stored_data_next = concat_data[0+:Width];
-        stored_mask_next = concat_mask[0+:Width];
-      end
-      2'b 11: begin
-        // both : shift the concat_data
-        stored_data_next = concat_data[ConcatW-1:OutW];
-        stored_mask_next = concat_mask[ConcatW-1:OutW];
+      2'b00: begin
+        stored_data_d  = stored_data_q;
+        stored_bmask_d = stored_bmask_q;
+      end
+      2'b01: begin
+        stored_data_d  = {{OutW{1'b0}}, stored_data_q[WidthB*8-1:OutW]};
+        stored_bmask_d = {{OutB{1'b0}}, stored_bmask_q[WidthB-1:OutB]};
+      end
+      2'b10: begin
+        stored_data_d  = concat_data[0 +: WidthB*8];
+        stored_bmask_d = concat_bmask[0 +: WidthB];
+      end
+      2'b11: begin
+        stored_data_d  = ({{OutW{1'b0}}, stored_data_q[WidthB*8-1:OutW]} | shiftl_data[0 +: WidthB*8]);
+        stored_bmask_d = ({{OutB{1'b0}}, stored_bmask_q[WidthB-1:OutB]} | shiftl_bmask[0 +: WidthB]);
       end
       default: begin
-        stored_data_next = stored_data;
-        stored_mask_next = stored_mask;
+        stored_data_d  = stored_data_q;
+        stored_bmask_d = stored_bmask_q;
       end
     endcase
   end
 
-  // Store the data temporary if it doesn't exceed OutW
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
-      stored_data <= '0;
-      stored_mask <= '0;
+      stored_data_q  <= '0;
+      stored_bmask_q <= '0;
     end else if (flush_done) begin
-      stored_data <= '0;
-      stored_mask <= '0;
+      stored_data_q  <= '0;
+      stored_bmask_q <= '0;
     end else begin
-      stored_data <= stored_data_next;
-      stored_mask <= stored_mask_next;
-    end
-  end
-  //---------------------------------------------------------------------------
-
-  // flush handling
+      stored_data_q  <= stored_data_d;
+      stored_bmask_q <= stored_bmask_d;
+    end
+  end
+
   typedef enum logic {
     FlushIdle,
     FlushSend
@@ -241,62 +183,33 @@
 
   always_comb begin
     flush_st_next = FlushIdle;
-
-    flush_valid = 1'b0;
-    flush_done  = 1'b0;
-
+    flush_valid   = 1'b0;
+    flush_done    = 1'b0;
     unique case (flush_st)
       FlushIdle: begin
-        if (flush_i) begin
-          flush_st_next = FlushSend;
-        end else begin
+        if (flush_i) flush_st_next = FlushSend;
+      end
+      FlushSend: begin
+        if (pos_b_q == '0) begin
           flush_st_next = FlushIdle;
-        end
-      end
-
-      FlushSend: begin
-        if (pos_q == '0) begin
-          flush_st_next = FlushIdle;
-
-          flush_valid = 1'b 0;
-          flush_done  = 1'b 1;
+          flush_done    = 1'b1;
         end else begin
           flush_st_next = FlushSend;
-
-          flush_valid = 1'b 1;
-          flush_done  = 1'b 0;
+          flush_valid   = 1'b1;
         end
       end
-      default: begin
-        flush_st_next = FlushIdle;
-
-        flush_valid = 1'b 0;
-        flush_done  = 1'b 0;
-      end
+      default: flush_st_next = FlushIdle;
     endcase
   end
 
   assign flush_done_o = flush_done;
-
-
-  // Output signals ===========================================================
-  assign valid_next = (int'(pos_q) >= OutW) ? 1'b 1 : flush_valid;
-
-  // storage space is InW + OutW. So technically, ready_o can be asserted even
-  // if `pos_q` is greater than OutW. But in order to do that, the logic should
-  // use `inmask_ones` value whether pos_q+inmask_ones is less than (InW+OutW)
-  // with `valid_i`. It creates a path from `valid_i` --> `ready_o`.
-  // It may create a timing loop in some modules that use `ready_o` to
-  // `valid_i` (which is not a good practice though)
-  assign ready_next = int'(pos_q) <= OutW;
-
-  // Output request
-  assign valid_o = valid_next;
-  assign data_o  = stored_data[OutW-1:0];
-  assign mask_o  = stored_mask[OutW-1:0];
-
-  // ready_o
-  assign ready_o = ready_next;
-  //---------------------------------------------------------------------------
-
-  endmodule
+  assign valid_o = (int'(pos_b_q) >= OutB) ? 1'b1 : flush_valid;
+  assign ready_o = (flush_st == FlushIdle) && !flush_i && (int'(pos_b_q) <= OutB);
+  assign data_o  = stored_data_q[OutW-1:0];
+  for (genvar i = 0; i < OutB; i++) begin : g_out_mask
+    assign mask_o[8*i +: 8] = {8{stored_bmask_q[i]}};
+  end
+  assign ack_in  = valid_i & ready_o;
+  assign ack_out = valid_o & ready_i;
+
+endmodule

--- a/environment/public/code/kmac_msgfifo.sv (Buggy Starter)
+++ b/solution/gold/code/kmac_msgfifo.sv (Golden Reference)
@@ -73,8 +73,18 @@
     end
   end
 
-  assign fifo_valid   = fifo_bypass_i ? '0              : fifo_valid_i;
-  assign fifo_ready_o = fifo_bypass_i ? msg_ready_i     : fifo_ready;
+  typedef enum logic [1:0] {
+    FlushIdle,
+    FlushPacker,
+    FlushFifo,
+    FlushClear
+  } flush_st_e;
+  flush_st_e flush_st, flush_st_d;
+
+  wire clear_true = prim_mubi_pkg::mubi4_test_true_strict(clear_i);
+  wire allow_push = (flush_st == FlushIdle) && !flush_i && !clear_true;
+  assign fifo_valid   = (fifo_bypass_i || !allow_push) ? 1'b0 : fifo_valid_i;
+  assign fifo_ready_o = fifo_bypass_i ? msg_ready_i : (allow_push && fifo_ready);
   assign msg_valid_o  = fifo_bypass_i ? fifo_valid_i    : msg_valid;
   assign msg_ready    = fifo_bypass_i ? '0              : msg_ready_i;
   assign msg_strb_o   = fifo_bypass_i ? fifo_strb_byte  : msg_strb;
@@ -99,23 +109,7 @@
     logic [OutWidth/8-1:0] strb; // one bit per byte
   } fifo_t;
 
-  typedef enum logic [1:0] {
-    // In Idle, it checks if process input received or not.
-    // If received, the signal goes to packer and flush internal pending data
-    FlushIdle,
-
-    // In Packer state, it waits the packer flush operation completes.
-    // The flush_done signal do nothing but after this, it is assumed that
-    // MSG FIFO received the request.
-    FlushPacker,
-
-    // In Fifo, it waits until MsgFifo is empty. Then asserts flush_done_o
-    FlushFifo,
-
-    // After flushing, it waits the done (clear) signal. It is assumed that
-    // no incoming messages are transmitted between `flush_i` and `clear_i`
-    FlushClear
-  } flush_st_e;
+
 
   /////////////
   // Signals //
@@ -190,7 +184,7 @@
   // MsgFIFO
   prim_fifo_sync #(
     .Width  ($bits(fifo_t)),
-    .Pass   (1'b 1),
+    .Pass   (1'b 0),
     .Depth  (MsgDepth),
     .Secure (EnMasking)
   ) u_msgfifo (
@@ -226,10 +220,12 @@
   assign fifo_empty_o = !fifo_rvalid;
 
   // Flush (process from outside) handling
-  flush_st_e flush_st, flush_st_d;
+  // moved flush_st_e above
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
+      flush_st <= FlushIdle;
+    end else if (clear_true) begin
       flush_st <= FlushIdle;
     end else begin
       flush_st <= flush_st_d;

--- a/environment/public/code/kmac_errchk.sv (Buggy Starter)
+++ b/solution/gold/code/kmac_errchk.sv (Golden Reference)
@@ -282,7 +282,8 @@
   // To reduce the command path delay, sw_cmd is latched here
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni)           sw_cmd_o <= CmdNone;
-    else if (!block_swcmd) sw_cmd_o <= sw_cmd_i;
+    else if (block_swcmd || lc_ctrl_pkg::lc_tx_test_true_loose(lc_escalate_en_i) || (st == StIdle && app_active_i && sw_cmd_i inside {CmdStart, CmdStateWrite}) || (st == StStateWrite && app_active_i)) sw_cmd_o <= CmdNone;
+    else                   sw_cmd_o <= sw_cmd_i;
   end
 
   // Mode & Strength

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/kmac_errchk.sv`](environment/public/code/kmac_errchk.sv) **(Editable)**
- [`environment/public/code/kmac_msg_err_top.sv`](environment/public/code/kmac_msg_err_top.sv) *(Read-Only Context)*
- [`environment/public/code/kmac_msgfifo.sv`](environment/public/code/kmac_msgfifo.sv) **(Editable)**
- [`environment/public/code/kmac_pkg.sv`](environment/public/code/kmac_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_pkg.sv`](environment/public/code/lc_ctrl_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_reg_pkg.sv`](environment/public/code/lc_ctrl_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lc_ctrl_state_pkg.sv`](environment/public/code/lc_ctrl_state_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_count.sv`](environment/public/code/prim_count.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count_pkg.sv`](environment/public/code/prim_count_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_assert.svh`](environment/public/code/prim_fifo_assert.svh) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync.sv`](environment/public/code/prim_fifo_sync.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync_cnt.sv`](environment/public/code/prim_fifo_sync_cnt.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop.sv`](environment/public/code/prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_packer.sv`](environment/public/code/prim_packer.sv) **(Editable)**
- [`environment/public/code/prim_sparse_fsm_flop.sv`](environment/public/code/prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sha3_pkg.sv`](environment/public/code/sha3_pkg.sv) *(Read-Only Context)*
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

