# `case_1011`: OpenTitan SPI Host Core TX Flush, RX Buffer Refill, Standard-Mode Output Enable, and Timing/Area Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1011` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `protocol_control`, `reset_rdc`, `rtl_integration`, `rtl_semantics`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/spi_host_fsm.sv`](environment/public/code/spi_host_fsm.sv), [`code/spi_host_shift_register.sv`](environment/public/code/spi_host_shift_register.sv), [`code/spi_host_byte_select.sv`](environment/public/code/spi_host_byte_select.sv) (3 files, 694 LOC) |
| **Public Subsystem Context** | 20 RTL files (3422 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# OpenTitan SPI Host Core TX Flush, RX Buffer Refill, Standard-Mode Output Enable, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan SPI Host core subsystem (`code/spi_host_core.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **TX Byte-Select Segment Flush**:
   - When a write segment finishes before consuming all enabled bytes of the current 32-bit TX word (`last_write_o` / `flush_i`), `spi_host_byte_select` does not discard the remaining bytes of that word, leaking leftover bytes into subsequent write segments.

2. **Simultaneous RX Shift-Register Refill and Downstream Pop**:
   - In `spi_host_shift_register`, when the downstream byte merger accepts a buffered RX byte (`rx_valid_o && rx_ready_i`) in the same cycle that the shift register completes and loads the next received byte (`rd_en_i && rd_ready_o`), the RX buffer valid flag clears instead of remaining asserted, dropping the newly received byte.

3. **Standard-Mode Output Enable Stretching and Software Reset Clearing**:
   - In `spi_host_fsm`, when a `Standard`-mode write segment (`speed_o == Standard`) transitions into a non-write segment or deasserts `cmd_wr_en_q` during the final bit period (`last_bit`), `sd_en_o[0]` drops half a clock cycle early instead of remaining asserted until `byte_ending`; moreover, when the FSM is idle (`is_idle`), `cmd_wr_en_last_bit` is not cleared, allowing an aborted write command to leak an active `sd_en_o[0]` into a subsequent read segment.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`spi_host_core`, `2.02 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `spi_host_core` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/spi_host_fsm.sv`, `code/spi_host_shift_register.sv`, and `code/spi_host_byte_select.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `spi_host_core`: **`<= 2035.0 um^2`**
- Worst setup slack and worst hold slack at `2.02 ns` clock period: **`>= 0.0 ns`**

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/spi_host_fsm.sv`
- `code/spi_host_shift_register.sv`
- `code/spi_host_byte_select.sv`

All other files in `code/` (`spi_host_core.sv`, `spi_host_byte_merge.sv`, `spi_host_cmd_pkg.sv`, `spi_host_reg_pkg.sv`, `prim_packer_fifo.sv`, `prim_flop.sv`, `prim_flop_en.sv`, `prim_flop_macros.sv`, `prim_count_pkg.sv`, `prim_mubi_pkg.sv`, `prim_util_pkg.sv`, `top_pkg.sv`, `prim_assert.sv`, `prim_assert_*.svh`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `spi_host_core` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv code/prim_packer_fifo.sv \
  code/spi_host_reg_pkg.sv code/spi_host_cmd_pkg.sv code/spi_host_byte_select.sv \
  code/spi_host_byte_merge.sv code/spi_host_shift_register.sv code/spi_host_fsm.sv \
  code/spi_host_core.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `spi_host_core`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top spi_host_core -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv code/prim_packer_fifo.sv \
    code/spi_host_reg_pkg.sv code/spi_host_cmd_pkg.sv code/spi_host_byte_select.sv \
    code/spi_host_byte_merge.sv code/spi_host_shift_register.sv code/spi_host_fsm.sv \
    code/spi_host_core.sv;
  hierarchy -check -top spi_host_core;
  synth -top spi_host_core;
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

Target mapped cell area (`Chip area for module '\spi_host_core'`): **`<= 2035.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.02 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design spi_host_core
create_clock -name clk_i -period 2.02 [get_ports clk_i]
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
--- a/environment/public/code/spi_host_fsm.sv (Buggy Starter)
+++ b/solution/gold/code/spi_host_fsm.sv (Golden Reference)
@@ -54,13 +54,13 @@
   logic [1:0]       cmd_speed_d, cmd_speed_q;
   logic             cmd_wr_en_d, cmd_wr_en_q;
   logic             cmd_rd_en_d, cmd_rd_en_q;
-  logic [19:0]      cmd_len_d, cmd_len_q;
+  logic [19:0]      cmd_len_d;
   logic             csaat;
   logic             csaat_q;
 
   logic [2:0]       bit_cntr_d, bit_cntr_q;
-  logic [19:0]      byte_cntr_cpha0_d, byte_cntr_cpha1_d, byte_cntr_cpha0_q, byte_cntr_cpha1_q;
-  logic [19:0]      byte_cntr_early, byte_cntr_late;
+  logic [19:0]      byte_cntr_d, byte_cntr_q;
+  logic             byte_cntr_early_zero;
   logic [3:0]       wait_cntr_d, wait_cntr_q;
   logic             last_bit, last_byte;
 
@@ -86,7 +86,6 @@
 
   assign stall = rx_stall_o | tx_stall_o;
 
-  // suppress output pulses if stalled.
   assign wr_en_o     = wr_en_internal & ~stall;
   assign rd_en_o     = rd_en_internal & ~stall;
   assign sample_en_o = sample_en_internal & ~stall;
@@ -108,7 +107,6 @@
   logic command_ready_int;
   assign command_ready_o = command_ready_int & ~stall;
 
-
   assign new_command    = command_valid_i && command_ready_int;
   assign config_changed = (command_i.configopts.cpol     != cpol_q) ||
                           (command_i.configopts.cpha     != cpha_q) ||
@@ -119,16 +117,16 @@
                           (command_i.configopts.clkdiv   != clkdiv_q);
 
   always_comb begin
-    csid      = new_command ? command_csid_i : csid_q;
-    cpol      = new_command ? command_i.configopts.cpol : cpol_q;
-    cpha      = new_command ? command_i.configopts.cpha : cpha_q;
-    full_cyc  = new_command ? command_i.configopts.full_cyc : full_cyc_q;
-    csnidle   = new_command ? command_i.configopts.csnidle : csnidle_q;
-    csnlead   = new_command ? command_i.configopts.csnlead : csnlead_q;
-    csntrail  = new_command ? command_i.configopts.csntrail : csntrail_q;
-    clkdiv    = new_command ? command_i.configopts.clkdiv : clkdiv_q;
-    csaat     = new_command ? command_i.segment.csaat : csaat_q;
-    cmd_len_d   = new_command ? command_i.segment.len : cmd_len_q;
+    csid        = new_command ? command_csid_i : csid_q;
+    cpol        = new_command ? command_i.configopts.cpol : cpol_q;
+    cpha        = new_command ? command_i.configopts.cpha : cpha_q;
+    full_cyc    = new_command ? command_i.configopts.full_cyc : full_cyc_q;
+    csnidle     = new_command ? command_i.configopts.csnidle : csnidle_q;
+    csnlead     = new_command ? command_i.configopts.csnlead : csnlead_q;
+    csntrail    = new_command ? command_i.configopts.csntrail : csntrail_q;
+    clkdiv      = new_command ? command_i.configopts.clkdiv : clkdiv_q;
+    csaat       = new_command ? command_i.segment.csaat : csaat_q;
+    cmd_len_d   = command_i.segment.len;
     cmd_wr_en_d = new_command ? command_i.segment.cmd_wr_en : cmd_wr_en_q;
     cmd_rd_en_d = new_command ? command_i.segment.cmd_rd_en : cmd_rd_en_q;
     cmd_speed_d = new_command ? command_i.segment.speed : cmd_speed_q;
@@ -148,7 +146,6 @@
       cmd_rd_en_q <= 1'b0;
       cmd_wr_en_q <= 1'b0;
       cmd_speed_q <= 2'b00;
-      cmd_len_q   <= 20'h0;
     end else begin
       csid_q      <= (new_command && !stall) ? csid : csid_q;
       cpol_q      <= (new_command && !stall) ? cpol : cpol_q;
@@ -162,15 +159,12 @@
       cmd_wr_en_q <= (new_command && !stall) ? cmd_wr_en_d : cmd_wr_en_q;
       cmd_rd_en_q <= (new_command && !stall) ? cmd_rd_en_d : cmd_rd_en_q;
       cmd_speed_q <= (new_command && !stall) ? cmd_speed_d : cmd_speed_q;
-      cmd_len_q   <= (new_command && !stall) ? cmd_len_d : cmd_len_q;
-    end
-  end
-
-  assign is_idle     = (state_q == Idle) || (state_q == IdleCSBActive);
-
-  assign active_o   = ~is_idle;
-
-  // New commands must always ensure there is the full setup time available.
+    end
+  end
+
+  assign is_idle   = (state_q == Idle) || (state_q == IdleCSBActive);
+  assign active_o  = ~is_idle;
+
   assign clk_cntr_d = sw_rst_i              ? 16'h0 :
                       !clk_cntr_en          ? clk_cntr_q :
                       new_command           ? clkdiv :
@@ -178,10 +172,10 @@
                       (clk_cntr_q == 16'h0) ? clkdiv :
                       clk_cntr_q - 1;
 
-  assign tx_stall_o = wr_en_internal & ~sr_wr_ready_i;
-  assign rx_stall_o = rd_en_internal & ~sr_rd_ready_i;
+  assign tx_stall_o  = wr_en_internal & ~sr_wr_ready_i;
+  assign rx_stall_o  = rd_en_internal & ~sr_rd_ready_i;
   assign clk_cntr_en = en_i;
-  assign fsm_en = (clk_cntr_en && ((clk_cntr_q == 0) || is_idle));
+  assign fsm_en      = (clk_cntr_en && ((clk_cntr_q == 0) || is_idle));
 
   spi_host_st_e next_state_after_idle;
   always_comb begin
@@ -308,38 +302,24 @@
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
-      segment_rd_en_cpha1   <= 1'b0;
+      segment_rd_en_cpha1 <= 1'b0;
     end else if (state_changing && !stall) begin
-      segment_rd_en_cpha1   <= segment_rd_en_cpha0;
+      segment_rd_en_cpha1 <= segment_rd_en_cpha0;
     end
   end
 
   assign byte_starting_cpha1 = ~sw_rst_i & state_changing &
-                                (state_d == InternalClkHigh & bit_cntr_q==0);
+                               (state_d == InternalClkHigh & bit_cntr_q==0);
   assign bit_shifting_cpha1  = ~sw_rst_i & state_changing &
                                (state_d == InternalClkHigh & bit_cntr_q != 0);
   assign byte_ending_cpha1   = ~sw_rst_i & state_changing &
                                (state_q == InternalClkLow & bit_cntr_q == 0);
 
-
-  assign byte_starting = (cpha == 1'b0) ? byte_starting_cpha0 :
-                                          byte_starting_cpha1;
-
-  assign byte_ending   = (cpha == 1'b0) ? byte_ending_cpha0 :
-                                          byte_ending_cpha1;
-
-  assign bit_shifting  = (cpha == 1'b0) ? bit_shifting_cpha0 :
-                                          bit_shifting_cpha1;
-
+  assign byte_starting = (cpha == 1'b0) ? byte_starting_cpha0 : byte_starting_cpha1;
+  assign byte_ending   = (cpha == 1'b0) ? byte_ending_cpha0   : byte_ending_cpha1;
+  assign bit_shifting  = (cpha == 1'b0) ? bit_shifting_cpha0  : bit_shifting_cpha1;
   assign speed_o       = cmd_speed_q;
-
-  assign segment_rd_en = (cpha == 1'b0) ? segment_rd_en_cpha0:
-                                          segment_rd_en_cpha1;
-
-  assign byte_cntr_early = (cpha == 1'b0) ? byte_cntr_cpha0_d :
-                                            byte_cntr_cpha1_d;
-  assign byte_cntr_late  = (cpha == 1'b0) ? byte_cntr_cpha0_q :
-                                            byte_cntr_cpha1_q;
+  assign segment_rd_en = (cpha == 1'b0) ? segment_rd_en_cpha0 : segment_rd_en_cpha1;
 
   logic [2:0] shift_size;
   logic [2:0] start_bit;
@@ -347,7 +327,7 @@
   always_comb begin
     if (!cmd_rd_en_d && !cmd_wr_en_d) begin
       shift_size = 0;
-      start_bit = 3'h0;
+      start_bit  = 3'h0;
     end else begin
       unique case (cmd_speed_d)
         Standard: begin
@@ -370,33 +350,29 @@
     end
   end
 
-  assign bit_cntr_d = sw_rst_i         ? 3'h0 :
-                      !fsm_en          ? bit_cntr_q :
-                      byte_starting    ? start_bit :
-                      bit_shifting     ? bit_cntr_q - shift_size :
+  assign bit_cntr_d = sw_rst_i      ? 3'h0 :
+                      !fsm_en       ? bit_cntr_q :
+                      byte_starting ? start_bit :
+                      bit_shifting  ? bit_cntr_q - shift_size :
                       bit_cntr_q;
 
   assign last_bit  = (bit_cntr_q == 3'h0);
-
-  always_comb begin
-    if (cpha_q) begin
-      last_byte = (byte_cntr_cpha1_q == 20'h0);
-    end else begin
-      last_byte = (byte_cntr_cpha0_q == 20'h0);
-    end
-  end
-
-  assign byte_cntr_cpha0_d = sw_rst_i    ? 20'h0 :
-                             !fsm_en     ? byte_cntr_cpha0_q :
-                             new_command ? cmd_len_d :
-                             byte_ending_cpha0 ? byte_cntr_cpha0_q - 1 :
-                             byte_cntr_cpha0_q;
-
-  assign byte_cntr_cpha1_d = sw_rst_i          ? 20'h0 :
-                             !fsm_en           ? byte_cntr_cpha1_q :
-                             new_command       ? cmd_len_d :
-                             byte_ending_cpha1 ? byte_cntr_cpha1_q - 1 :
-                             byte_cntr_cpha1_q;
+  assign last_byte = (byte_cntr_q == 20'h0);
+
+  logic dec_byte_cntr;
+  assign dec_byte_cntr = (cpha_q == 1'b0) ? byte_ending_cpha0 : byte_ending_cpha1;
+
+  assign byte_cntr_d = sw_rst_i      ? 20'h0 :
+                       !fsm_en       ? byte_cntr_q :
+                       new_command   ? cmd_len_d :
+                       dec_byte_cntr ? (byte_cntr_q - 20'd1) :
+                                       byte_cntr_q;
+
+  assign byte_cntr_early_zero = sw_rst_i      ? 1'b1 :
+                                !fsm_en       ? (byte_cntr_q == 20'h0) :
+                                new_command   ? (cmd_len_d == 20'h0) :
+                                dec_byte_cntr ? (byte_cntr_q == 20'd1) :
+                                                (byte_cntr_q == 20'h0);
 
   always_comb begin
     if(sw_rst_i) begin
@@ -405,21 +381,11 @@
       wait_cntr_d = wait_cntr_q;
     end else if (state_changing) begin
       unique case (state_d)
-         WaitLead: begin
-           wait_cntr_d = csnlead;
-         end
-         WaitTrail: begin
-           wait_cntr_d = csntrail;
-         end
-         WaitIdle: begin
-           wait_cntr_d = csnidle;
-         end
-         CSBSwitch: begin
-           wait_cntr_d = csnidle;
-         end
-         default: begin
-           wait_cntr_d = 4'b0;
-         end
+         WaitLead:  wait_cntr_d = csnlead;
+         WaitTrail: wait_cntr_d = csntrail;
+         WaitIdle:  wait_cntr_d = csnidle;
+         CSBSwitch: wait_cntr_d = csnidle;
+         default:   wait_cntr_d = 4'b0;
       endcase
     end else if (wait_cntr_q == 0) begin
       wait_cntr_d = 4'h0;
@@ -430,31 +396,27 @@
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
-      bit_cntr_q        <= 3'h0;
-      byte_cntr_cpha0_q <= 20'h0;
-      byte_cntr_cpha1_q <= 20'h0;
-      wait_cntr_q       <= 4'h0;
-    end else begin
-      bit_cntr_q        <= stall ? bit_cntr_q        : bit_cntr_d;
-      byte_cntr_cpha0_q <= stall ? byte_cntr_cpha0_q : byte_cntr_cpha0_d;
-      byte_cntr_cpha1_q <= stall ? byte_cntr_cpha1_q : byte_cntr_cpha1_d;
-      wait_cntr_q       <= stall ? wait_cntr_q       : wait_cntr_d;
+      bit_cntr_q  <= 3'h0;
+      byte_cntr_q <= 20'h0;
+      wait_cntr_q <= 4'h0;
+    end else begin
+      bit_cntr_q  <= stall ? bit_cntr_q  : bit_cntr_d;
+      byte_cntr_q <= stall ? byte_cntr_q : byte_cntr_d;
+      wait_cntr_q <= stall ? wait_cntr_q : wait_cntr_d;
     end
   end
 
   assign wr_en_internal    = byte_starting & cmd_wr_en_d;
   assign shift_en_internal = bit_shifting;
-
   assign rd_en_internal    = byte_ending & segment_rd_en;
   assign sample_en_d       = byte_starting | shift_en_o;
   assign full_cyc_o        = full_cyc;
-  assign last_read_o       = (byte_cntr_late == 'h0) & rd_en_o & sr_rd_ready_i;
-
-  assign last_write_o      = (byte_cntr_early == 'h0) & wr_en_o & sr_wr_ready_i;
+  assign last_read_o       = last_byte & rd_en_o & sr_rd_ready_i;
+  assign last_write_o      = byte_cntr_early_zero & wr_en_o & sr_wr_ready_i;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
-      sample_en_q <= 1'b0;
+      sample_en_q  <= 1'b0;
       sample_en_q2 <= 1'b0;
     end else begin
       sample_en_q  <= (fsm_en && !stall) ? sample_en_d : sample_en_q;
@@ -498,6 +460,17 @@
     end
   end : gen_csb_gen
 
+  logic cmd_wr_en_last_bit;
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      cmd_wr_en_last_bit <= 1'b0;
+    end else if (is_idle || byte_ending) begin
+      cmd_wr_en_last_bit <= 1'b0;
+    end else if (cmd_wr_en_q & last_bit) begin
+      cmd_wr_en_last_bit <= 1'b1;
+    end
+  end
+
   assign csb_o = csb_q;
 
   always_comb begin
@@ -506,7 +479,7 @@
     end else begin
       unique case (speed_o)
         Standard: begin
-          sd_en_o[0]   = cmd_wr_en_q;
+          sd_en_o[0]   = cmd_wr_en_q | cmd_wr_en_last_bit;
           sd_en_o[1]   = 1'b0;
           sd_en_o[3:2] = 2'b00;
         end

--- a/environment/public/code/spi_host_shift_register.sv (Buggy Starter)
+++ b/solution/gold/code/spi_host_shift_register.sv (Golden Reference)
@@ -45,9 +45,6 @@
   logic        [3:0] next_bits;
   logic        [7:0] sr_shifted;
 
-  // 9-bit buffer to hold shift register data
-  // and the last_read bit to indicate whether
-  // it is the last in a series.
   logic        [8:0] rx_buf_q;
   logic        [8:0] rx_buf_d;
   logic              rx_buf_valid_q;
@@ -66,8 +63,6 @@
                       (speed_i == Quad)     ? {sr_q[7:4]} :
                       4'h0;
 
-  // Buffer the rx_data outputs to simplify three-way flow control
-  // between fsm, shift reg and byte_merge.
   assign rd_ready_o             = ~rx_buf_valid_q | (rx_valid_o & rx_ready_i);
   assign rx_valid_o             = rx_buf_valid_q;
 
@@ -76,8 +71,8 @@
                                   rx_buf_q;
 
   assign rx_buf_valid_d         = sw_rst_i                  ? 1'b0 :
+                                  (rd_en_i && rd_ready_o)   ? 1'b1 :
                                   (rx_valid_o & rx_ready_i) ? 1'b0 :
-                                  (rd_en_i && rd_ready_o)   ? 1'b1 :
                                   rx_buf_valid_q;
 
   assign sd_i_d                 = sw_rst_i    ? 4'b0 :

--- a/environment/public/code/spi_host_byte_select.sv (Buggy Starter)
+++ b/solution/gold/code/spi_host_byte_select.sv (Golden Reference)
@@ -27,7 +27,7 @@
   logic               unused_flush;
 
   assign unused_flush = flush_i;
-  assign clr          = sw_rst_i;
+  assign clr          = flush_i | sw_rst_i;
   assign byte_valid_o = byte_valid & byte_en;
   assign do_drain     = byte_valid & ~byte_en;
   assign byte_ready   = byte_ready_i | do_drain;
@@ -38,7 +38,8 @@
 
   prim_packer_fifo #(
     .InW(36),
-    .OutW(9)
+    .OutW(9),
+    .ClearOnRead(1'b0)
   ) u_packer (
     .clk_i,
     .rst_ni,

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_count_pkg.sv`](environment/public/code/prim_count_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop.sv`](environment/public/code/prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_en.sv`](environment/public/code/prim_flop_en.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_packer_fifo.sv`](environment/public/code/prim_packer_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/spi_host_byte_merge.sv`](environment/public/code/spi_host_byte_merge.sv) *(Read-Only Context)*
- [`environment/public/code/spi_host_byte_select.sv`](environment/public/code/spi_host_byte_select.sv) **(Editable)**
- [`environment/public/code/spi_host_cmd_pkg.sv`](environment/public/code/spi_host_cmd_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/spi_host_core.sv`](environment/public/code/spi_host_core.sv) *(Read-Only Context)*
- [`environment/public/code/spi_host_fsm.sv`](environment/public/code/spi_host_fsm.sv) **(Editable)**
- [`environment/public/code/spi_host_reg_pkg.sv`](environment/public/code/spi_host_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/spi_host_shift_register.sv`](environment/public/code/spi_host_shift_register.sv) **(Editable)**
- [`environment/public/code/top_pkg.sv`](environment/public/code/top_pkg.sv) *(Read-Only Context)*
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

