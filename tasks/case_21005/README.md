# `case_21005`: TSN/TDMA Transmit Scheduler Boundary Precision, Pipeline Hazard Control & Nangate45 Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21005` |
| **Source Silicon Repository** | `corundum/corundum` (`repo_39`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/tdma_scheduler.v`](environment/public/code/tdma_scheduler.v), [`code/tx_scheduler_ctrl_tdma.v`](environment/public/code/tx_scheduler_ctrl_tdma.v), [`code/tx_scheduler_rr.v`](environment/public/code/tx_scheduler_rr.v) (3 files, 1802 LOC) |
| **Public Subsystem Context** | 5 RTL files (2456 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# TSN/TDMA Transmit Scheduler Boundary Precision, Pipeline Hazard Control & Nangate45 Timing Closure

`tdma_scheduler` (`code/tdma_scheduler.v`), `tx_scheduler_ctrl_tdma` (`code/tx_scheduler_ctrl_tdma.v`), and `tx_scheduler_rr` (`code/tx_scheduler_rr.v`) form the time-triggered TSN/TDMA transmit scheduling chain: `tdma_scheduler` tracks 96-bit PTP time (`input_ts_96[95:48]` seconds, `input_ts_96[45:16]` nanoseconds) to emit timeslot boundaries, `tx_scheduler_ctrl_tdma` scans per-queue timeslot bitmasks to issue `m_axis_sched_ctrl_*` gate updates, and `tx_scheduler_rr` arbitrates active/enabled queues onto `m_axis_tx_req_*`.

Update `code/tdma_scheduler.v`, `code/tx_scheduler_ctrl_tdma.v`, and `code/tx_scheduler_rr.v` while preserving all top-level module names, parameters, and port interfaces:

1. **PTP Boundary Precision & `tdma_scheduler` Nangate45 `2.00` ns Timing Closure**:
   - Trigger schedule period start, timeslot start, and active-period end in `tdma_scheduler` using inclusive timestamp comparisons (`current_time >= target_time` across `(seconds, nanoseconds)`, with decimal `1_000_000_000` ns rollover) rather than firing late only after strictly exceeding target timestamps, while bounding `timeslot_start` / `timeslot_end` assertion latency to at most `3` `clk` cycles from `input_ts_96` reaching the boundary in `STATE_WAIT`.
   - Retime/refactor the wide 48-bit second + 31-bit nanosecond comparator/adder paths in `tdma_scheduler` (`INDEX_WIDTH = 8`) so Nangate45 OpenSTA closes at **`clk = 2.00` ns** (`0.10` ns input/output delay on all non-clock, non-reset ports; `set_false_path -from [get_ports rst]`) with **`WNS >= 0.00` ns**, **`TNS >= 0.00` ns**, **`worst hold slack >= 0.00` ns**, and mapped cell area `<= 10,000` um².

2. **TDMA Gate Controller Event Retention & Deep-Pipeline AXI4-Lite Read Integrity (`tx_scheduler_ctrl_tdma`)**:
   - Do not drop `tdma_timeslot_start` or `tdma_timeslot_end` pulses that arrive while a previous start/stop queue burst is still draining under `m_axis_sched_ctrl_ready == 1'b0` backpressure, on the final drain beat of `STATE_START_0`/`STATE_START_N`/`STATE_STOP`, or during an AXI4-Lite `inconsistent` table rescan.
   - Propagate AXI4-Lite `queue_ram` read data/shift/valid cleanly across all `PIPELINE >= 2` stages (including `PIPELINE > 2`) without accepting new reads that overwrite valid in-flight read stages when `s_axil_rready == 1'b0`.

3. **Round-Robin TX Completion Gating & ASIC Reset Hygiene (`tx_scheduler_rr` + Full Chain)**:
   - On `s_axis_tx_req_status_valid` completion in `tx_scheduler_rr` (`SCHED_CTRL_ENABLE` in `{0, 1}`, `PIPELINE >= 2`), reschedule a queue with remaining work (`s_axis_tx_req_status_len != 0` or pending doorbell) if and only if the queue is enabled (`queue_ram` bit `0 == 1`), not already scheduled, and permitted by scheduler control (`!SCHED_CTRL_ENABLE || global_enable || sched_enable`, using the queue's stored `global_enable` bit `1`).
   - Synchronously reset all control, pointer, and pipeline valid registers across all three modules on `rst` so Yosys synthesis infers zero latches and ASIC initializer-stripped gate-level simulation exhibits zero `X` propagation after `rst` and full functional parity.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The TDMA transmit scheduler RTL in `code/` derives from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause-Views).

Editable files:
- `code/tdma_scheduler.v`
- `code/tx_scheduler_ctrl_tdma.v`
- `code/tx_scheduler_rr.v`

Read-only files:
- `code/axis_fifo.v`
- `code/priority_encoder.v`
- `code/LICENSE`
- `pdk/NangateOpenCellLibrary_typical.lib`

Editable RTL must remain pure synthesizable HDL compatible with both Icarus Verilog and Verilator across parameterized `PORTS` / `INDEX_WIDTH` instantiations (do not add simulation-control or file-I/O system tasks such as `$finish`, `$stop`, `$fatal`, or `$readmem*`, and do not use simulator/synthesis macro divergence).

Local compilation, Verilator lint, Yosys Nangate45 synthesis, and OpenSTA `2.00` ns timing check from the workspace root:
```bash
# 1. Icarus Verilog & Verilator compilation/elaboration checks
iverilog -g2012 -o /tmp/tdma_chk.vvp \
  code/tdma_scheduler.v code/tx_scheduler_ctrl_tdma.v code/tx_scheduler_rr.v code/axis_fifo.v code/priority_encoder.v
verilator --lint-only -Wno-fatal --top-module tx_scheduler_ctrl_tdma code/tx_scheduler_ctrl_tdma.v
verilator --lint-only -Wno-fatal -GQUEUE_INDEX_WIDTH=4 --top-module tx_scheduler_ctrl_tdma code/tx_scheduler_ctrl_tdma.v

# 2. Yosys Nangate45 synthesis & area report on tdma_scheduler
yosys -p "
  read_verilog code/tdma_scheduler.v;
  hierarchy -check -top tdma_scheduler -chparam INDEX_WIDTH 8;
  synth -flatten -top tdma_scheduler;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean -purge;
  stat -liberty pdk/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -simple-lhs /tmp/tdma_sched_net.v
"

# 3. OpenSTA 2.00 ns timing verification on tdma_scheduler
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -no_init -exit <<'EOF'
read_liberty pdk/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/tdma_sched_net.v
link_design tdma_scheduler
create_clock -name clk -period 2.00 [get_ports clk]
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
--- a/environment/public/code/tdma_scheduler.v (Buggy Starter)
+++ b/solution/gold/code/tdma_scheduler.v (Golden Reference)
@@ -11,41 +11,27 @@
 
 /*
  * TDMA scheduler module
+ * 16-bit carry-select timestamp datapath & 5-slice registered comparator for 1.50 ns Nangate45 closure
  */
 module tdma_scheduler #
 (
-    // Timeslot index width
     parameter INDEX_WIDTH = 8,
-    // Schedule absolute PTP start time, seconds part
     parameter SCHEDULE_START_S = 48'h0,
-    // Schedule absolute PTP start time, nanoseconds part
     parameter SCHEDULE_START_NS = 30'h0,
-    // Schedule period, seconds part
     parameter SCHEDULE_PERIOD_S = 48'd0,
-    // Schedule period, nanoseconds part
     parameter SCHEDULE_PERIOD_NS = 30'd1000000,
-    // Timeslot period, seconds part
     parameter TIMESLOT_PERIOD_S = 48'd0,
-    // Timeslot period, nanoseconds part
     parameter TIMESLOT_PERIOD_NS = 30'd100000,
-    // Timeslot active period, seconds part
     parameter ACTIVE_PERIOD_S = 48'd0,
-    // Timeslot active period, nanoseconds part
     parameter ACTIVE_PERIOD_NS = 30'd100000
 )
 (
     input  wire                   clk,
     input  wire                   rst,
 
-    /*
-     * Timestamp input from PTP clock
-     */
     input  wire [95:0]            input_ts_96,
     input  wire                   input_ts_step,
 
-    /*
-     * Control
-     */
     input  wire                   enable,
     input  wire [79:0]            input_schedule_start,
     input  wire                   input_schedule_start_valid,
@@ -56,15 +42,9 @@
     input  wire [79:0]            input_active_period,
     input  wire                   input_active_period_valid,
 
-    /*
-     * Status
-     */
     output wire                   locked,
     output wire                   error,
 
-    /*
-     * TDMA schedule outputs
-     */
     output wire                   schedule_start,
     output wire [INDEX_WIDTH-1:0] timeslot_index,
     output wire                   timeslot_start,
@@ -72,301 +52,428 @@
     output wire                   timeslot_active
 );
 
-/*
-
-      schedule
-       start
-         |
-         V
-         |<-------- schedule period -------->|
-    -----+--------+--------+--------+--------+--------+---
-         | SLOT 0 | SLOT 1 | SLOT 2 | SLOT 3 | SLOT 0 | 
-    -----+--------+--------+--------+--------+--------+---
-         |<------>|
-          timeslot
-           period
-
-
-         |<-------- timeslot period -------->|
-    -----+-----------------------------------+------------
-         | SLOT 0                            | SLOT 1   
-    -----+-----------------------------------+------------
-         |<---- active period ----->|
-
-*/
-
-localparam [2:0]
-    STATE_IDLE = 3'd0,
-    STATE_UPDATE_SCHEDULE_1 = 3'd1,
-    STATE_UPDATE_SCHEDULE_2 = 3'd2,
-    STATE_UPDATE_SLOT_1 = 3'd3,
-    STATE_UPDATE_SLOT_2 = 3'd4,
-    STATE_UPDATE_SLOT_3 = 3'd5,
-    STATE_WAIT = 3'd6;
-
-reg [2:0] state_reg = STATE_IDLE, state_next;
-
-reg [47:0] time_s_reg = 0;
-reg [30:0] time_ns_reg = 0;
-
-reg [47:0] first_slot_s_reg = 0, first_slot_s_next;
-reg [30:0] first_slot_ns_reg = 0, first_slot_ns_next;
-
-reg [47:0] next_slot_s_reg = 0, next_slot_s_next;
-reg [30:0] next_slot_ns_reg = 0, next_slot_ns_next;
-
-reg [47:0] active_end_s_reg = 0, active_end_s_next;
-reg [30:0] active_end_ns_reg = 0, active_end_ns_next;
-
-reg [47:0] schedule_start_s_reg = SCHEDULE_START_S;
+localparam [3:0]
+    STATE_IDLE       = 4'd0,
+    STATE_UPD_SCH_1  = 4'd1,
+    STATE_UPD_SCH_2  = 4'd2,
+    STATE_UPD_SCH_3  = 4'd3,
+    STATE_UPD_ACT_1  = 4'd4,
+    STATE_UPD_ACT_2  = 4'd5,
+    STATE_UPD_ACT_3  = 4'd6,
+    STATE_UPD_NXT_1  = 4'd7,
+    STATE_UPD_NXT_2  = 4'd8,
+    STATE_UPD_NXT_3  = 4'd9,
+    STATE_WAIT       = 4'd10;
+
+localparam [15:0] NS_ROLL_LO = 16'hCA00; // 1_000_000_000 = 31'h3B9A_CA00
+localparam [14:0] NS_ROLL_HI = 15'h3B9A;
+
+reg [3:0]  state_reg = STATE_IDLE, state_next;
+
+reg [47:0] time_s_reg  = 48'd0;
+reg [30:0] time_ns_reg = 31'd0;
+reg        time_valid_reg = 1'b0;
+
+reg [47:0] first_slot_s_reg  = 48'd0, first_slot_s_next;
+reg [30:0] first_slot_ns_reg = 31'd0, first_slot_ns_next;
+
+reg [47:0] next_slot_s_reg  = 48'd0, next_slot_s_next;
+reg [30:0] next_slot_ns_reg = 31'd0, next_slot_ns_next;
+
+reg [47:0] active_end_s_reg  = 48'd0, active_end_s_next;
+reg [30:0] active_end_ns_reg = 31'd0, active_end_ns_next;
+
+reg [47:0] schedule_start_s_reg  = SCHEDULE_START_S;
 reg [30:0] schedule_start_ns_reg = SCHEDULE_START_NS;
 
-reg [47:0] schedule_period_s_reg = SCHEDULE_PERIOD_S;
+reg [47:0] schedule_period_s_reg  = SCHEDULE_PERIOD_S;
 reg [30:0] schedule_period_ns_reg = SCHEDULE_PERIOD_NS;
 
-reg [47:0] timeslot_period_s_reg = TIMESLOT_PERIOD_S;
+reg [47:0] timeslot_period_s_reg  = TIMESLOT_PERIOD_S;
 reg [30:0] timeslot_period_ns_reg = TIMESLOT_PERIOD_NS;
 
-reg [47:0] active_period_s_reg = ACTIVE_PERIOD_S;
+reg [47:0] active_period_s_reg  = ACTIVE_PERIOD_S;
 reg [30:0] active_period_ns_reg = ACTIVE_PERIOD_NS;
 
-reg [29:0] ts_ns_inc_reg = 0, ts_ns_inc_next;
-reg [30:0] ts_ns_ovf_reg = 0, ts_ns_ovf_next;
-
-reg locked_reg = 1'b0, locked_next;
-reg locked_int_reg = 1'b0, locked_int_next;
-reg error_reg = 1'b0, error_next;
+// Stage 1: 16-bit carry-select partial sums
+reg [16:0] add_ns_lo_r  = 17'd0;
+reg [15:0] add_ns_hi0_r = 16'd0;
+reg [15:0] add_ns_hi1_r = 16'd0;
+reg [16:0] add_s0_lo_r  = 17'd0;
+reg [16:0] add_s1_lo_r  = 17'd0;
+reg [16:0] add_s_mid0_r = 17'd0;
+reg [16:0] add_s_mid1_r = 17'd0;
+reg [15:0] add_s_hi0_r  = 16'd0;
+reg [15:0] add_s_hi1_r  = 16'd0;
+
+// Stage 2: carry-resolved sum & 16-bit rollover subtraction
+reg [30:0] ns_sum_r   = 31'd0;
+reg [16:0] ovf_lo_r   = 17'd0;
+reg [15:0] ovf_hi0_r  = 16'd0;
+reg [15:0] ovf_hi1_r  = 16'd0;
+reg [47:0] s_sum_c0_r = 48'd0;
+reg [47:0] s_sum_c1_r = 48'd0;
+
+// Stage 2 comparator registers (5 x 16-bit slices -> combined in Stage 3)
+reg [4:0] first_gt_r = 5'd0;
+reg [3:0] first_eq_r = 4'd0;
+reg [4:0] next_gt_r  = 5'd0;
+reg [3:0] next_eq_r  = 4'd0;
+reg [4:0] act_gt_r   = 5'd0;
+reg [3:0] act_eq_r   = 4'd0;
+reg       cmp_valid_reg = 1'b0;
+
+reg locked_reg           = 1'b0, locked_next;
+reg locked_int_reg       = 1'b0, locked_int_next;
+reg error_reg            = 1'b0, error_next;
 reg schedule_running_reg = 1'b0, schedule_running_next;
 
-reg schedule_start_reg = 1'b0, schedule_start_next;
-reg [INDEX_WIDTH-1:0] timeslot_index_reg = 0, timeslot_index_next;
-reg timeslot_start_reg = 1'b0, timeslot_start_next;
-reg timeslot_end_reg = 1'b0, timeslot_end_next;
-reg timeslot_active_reg = 1'b0, timeslot_active_next;
-
-assign locked = locked_reg;
-assign error = error_reg;
-
-assign schedule_start = schedule_start_reg;
-assign timeslot_index = timeslot_index_reg;
-assign timeslot_start = timeslot_start_reg;
-assign timeslot_end = timeslot_end_reg;
+reg                   schedule_start_reg  = 1'b0, schedule_start_next;
+reg [INDEX_WIDTH-1:0] timeslot_index_reg  = {INDEX_WIDTH{1'b0}}, timeslot_index_next;
+reg                   timeslot_start_reg  = 1'b0, timeslot_start_next;
+reg                   timeslot_end_reg    = 1'b0, timeslot_end_next;
+reg                   timeslot_active_reg = 1'b0, timeslot_active_next;
+
+assign locked          = locked_reg;
+assign error           = error_reg;
+assign schedule_start  = schedule_start_reg;
+assign timeslot_index  = timeslot_index_reg;
+assign timeslot_start  = timeslot_start_reg;
+assign timeslot_end    = timeslot_end_reg;
 assign timeslot_active = timeslot_active_reg;
+
+function automatic combine_5slice_ge(
+    input [4:0] gt,
+    input [3:0] eq
+);
+    begin
+        combine_5slice_ge = gt[4]
+            || (eq[3] && gt[3])
+            || (eq[3] && eq[2] && gt[2])
+            || (eq[3] && eq[2] && eq[1] && gt[1])
+            || (eq[3] && eq[2] && eq[1] && eq[0] && gt[0]);
+    end
+endfunction
+
+wire first_ge = combine_5slice_ge(first_gt_r, first_eq_r);
+wire next_ge  = combine_5slice_ge(next_gt_r,  next_eq_r);
+wire act_ge   = combine_5slice_ge(act_gt_r,   act_eq_r);
+
+wire [14:0] ns_hi_sel  = add_ns_lo_r[16] ? add_ns_hi1_r[14:0] : add_ns_hi0_r[14:0];
+wire [16:0] c0_mid_sel = add_s0_lo_r[16] ? add_s_mid1_r : add_s_mid0_r;
+wire [16:0] c1_mid_sel = add_s1_lo_r[16] ? add_s_mid1_r : add_s_mid0_r;
+
+wire        ovf_neg     = ovf_lo_r[16] ? ovf_hi1_r[15] : ovf_hi0_r[15];
+wire [30:0] ns_resolved = (!ovf_neg) ? {(ovf_lo_r[16] ? ovf_hi1_r[14:0] : ovf_hi0_r[14:0]), ovf_lo_r[15:0]} : ns_sum_r;
+wire [47:0] s_resolved  = (!ovf_neg) ? s_sum_c1_r : s_sum_c0_r;
+
+reg [47:0] op_a_s, op_b_s;
+reg [30:0] op_a_ns, op_b_ns;
+reg        cmp_flush;
 
 always @* begin
     state_next = STATE_IDLE;
 
-    first_slot_s_next = first_slot_s_reg;
+    first_slot_s_next  = first_slot_s_reg;
     first_slot_ns_next = first_slot_ns_reg;
-
-    next_slot_s_next = next_slot_s_reg;
-    next_slot_ns_next = next_slot_ns_reg;
-
-    active_end_s_next = active_end_s_reg;
+    next_slot_s_next   = next_slot_s_reg;
+    next_slot_ns_next  = next_slot_ns_reg;
+    active_end_s_next  = active_end_s_reg;
     active_end_ns_next = active_end_ns_reg;
 
-    ts_ns_inc_next = ts_ns_inc_reg;
-
-    ts_ns_ovf_next = ts_ns_ovf_reg;
-
-    locked_next = locked_reg;
-    locked_int_next = locked_int_reg;
-    error_next = error_reg;
+    op_a_s  = first_slot_s_reg;
+    op_a_ns = first_slot_ns_reg;
+    op_b_s  = schedule_period_s_reg;
+    op_b_ns = schedule_period_ns_reg;
+
+    locked_next           = locked_reg;
+    locked_int_next       = locked_int_reg;
+    error_next            = error_reg;
     schedule_running_next = schedule_running_reg;
 
-    schedule_start_next = 1'b0;
-    timeslot_index_next = timeslot_index_reg;
-    timeslot_start_next = 1'b0;
-    timeslot_end_next = 1'b0;
+    schedule_start_next  = 1'b0;
+    timeslot_index_next  = timeslot_index_reg;
+    timeslot_start_next  = 1'b0;
+    timeslot_end_next    = 1'b0;
     timeslot_active_next = timeslot_active_reg;
+    cmp_flush            = 1'b0;
 
     if (input_schedule_start_valid || input_schedule_period_valid || input_ts_step) begin
-        timeslot_index_next = 0;
-        timeslot_start_next = 1'b0;
-        timeslot_end_next = timeslot_active_reg;
+        timeslot_index_next  = {INDEX_WIDTH{1'b0}};
+        timeslot_start_next  = 1'b0;
+        timeslot_end_next    = timeslot_active_reg;
         timeslot_active_next = 1'b0;
-        error_next = input_ts_step;
-        state_next = STATE_IDLE;
+        error_next           = input_ts_step;
+        state_next           = STATE_IDLE;
+        cmp_flush            = 1'b1;
     end else begin
         case (state_reg)
             STATE_IDLE: begin
-                // set next rise to start time
-                first_slot_s_next = schedule_start_s_reg;
-                first_slot_ns_next = schedule_start_ns_reg;
-                next_slot_s_next = schedule_start_s_reg;
-                next_slot_ns_next = schedule_start_ns_reg;
-                timeslot_index_next = 0;
-                timeslot_start_next = 1'b0;
-                timeslot_end_next = timeslot_active_reg;
-                timeslot_active_next = 1'b0;
-                locked_next = 1'b0;
-                locked_int_next = 1'b0;
+                first_slot_s_next     = schedule_start_s_reg;
+                first_slot_ns_next    = schedule_start_ns_reg;
+                next_slot_s_next      = schedule_start_s_reg;
+                next_slot_ns_next     = schedule_start_ns_reg;
+                timeslot_index_next   = {INDEX_WIDTH{1'b0}};
+                timeslot_start_next   = 1'b0;
+                timeslot_end_next     = timeslot_active_reg;
+                timeslot_active_next  = 1'b0;
+                locked_next           = 1'b0;
+                locked_int_next       = 1'b0;
                 schedule_running_next = 1'b0;
-                state_next = STATE_WAIT;
-            end
-            STATE_UPDATE_SCHEDULE_1: begin
-                // set next schedule start time to next schedule start time plus schedule period
-                ts_ns_inc_next = first_slot_ns_reg + schedule_period_ns_reg;
-                ts_ns_ovf_next = first_slot_ns_reg + schedule_period_ns_reg - 31'd1_000_000_000;
-                state_next = STATE_UPDATE_SCHEDULE_2;
-            end
-            STATE_UPDATE_SCHEDULE_2: begin
-                if (!ts_ns_ovf_reg[30]) begin
-                    // if the overflow lookahead did not borrow, one second has elapsed
-                    first_slot_s_next = first_slot_s_reg + schedule_period_s_reg + 1;
-                    first_slot_ns_next = ts_ns_ovf_reg;
+                state_next            = STATE_WAIT;
+                cmp_flush             = 1'b1;
+            end
+            STATE_UPD_SCH_1: begin
+                op_a_s     = first_slot_s_reg;
+                op_a_ns    = first_slot_ns_reg;
+                op_b_s     = schedule_period_s_reg;
+                op_b_ns    = schedule_period_ns_reg;
+                state_next = STATE_UPD_SCH_2;
+                cmp_flush  = 1'b1;
+            end
+            STATE_UPD_SCH_2: begin
+                state_next = STATE_UPD_SCH_3;
+                cmp_flush  = 1'b1;
+            end
+            STATE_UPD_SCH_3: begin
+                first_slot_s_next  = s_resolved;
+                first_slot_ns_next = ns_resolved;
+                next_slot_s_next   = first_slot_s_reg;
+                next_slot_ns_next  = first_slot_ns_reg;
+                state_next         = STATE_UPD_ACT_1;
+                cmp_flush          = 1'b1;
+            end
+            STATE_UPD_ACT_1: begin
+                op_a_s     = next_slot_s_reg;
+                op_a_ns    = next_slot_ns_reg;
+                op_b_s     = active_period_s_reg;
+                op_b_ns    = active_period_ns_reg;
+                state_next = STATE_UPD_ACT_2;
+                cmp_flush  = 1'b1;
+            end
+            STATE_UPD_ACT_2: begin
+                state_next = STATE_UPD_ACT_3;
+                cmp_flush  = 1'b1;
+            end
+            STATE_UPD_ACT_3: begin
+                active_end_s_next  = s_resolved;
+                active_end_ns_next = ns_resolved;
+                op_a_s             = next_slot_s_reg;
+                op_a_ns            = next_slot_ns_reg;
+                op_b_s             = timeslot_period_s_reg;
+                op_b_ns            = timeslot_period_ns_reg;
+                state_next         = STATE_UPD_NXT_2;
+                cmp_flush          = 1'b1;
+            end
+            STATE_UPD_NXT_1: begin
+                op_a_s     = next_slot_s_reg;
+                op_a_ns    = next_slot_ns_reg;
+                op_b_s     = timeslot_period_s_reg;
+                op_b_ns    = timeslot_period_ns_reg;
+                state_next = STATE_UPD_NXT_2;
+                cmp_flush  = 1'b1;
+            end
+            STATE_UPD_NXT_2: begin
+                state_next = STATE_UPD_NXT_3;
+                cmp_flush  = 1'b1;
+            end
+            STATE_UPD_NXT_3: begin
+                next_slot_s_next  = s_resolved;
+                next_slot_ns_next = ns_resolved;
+                state_next        = STATE_WAIT;
+                cmp_flush         = 1'b1;
+            end
+            STATE_WAIT: begin
+                if (cmp_valid_reg && first_ge) begin
+                    schedule_start_next   = enable && locked_int_reg;
+                    timeslot_index_next   = {INDEX_WIDTH{1'b0}};
+                    timeslot_start_next   = enable && locked_int_reg;
+                    timeslot_end_next     = timeslot_active_reg;
+                    timeslot_active_next  = enable && locked_int_reg;
+                    schedule_running_next = 1'b1;
+                    locked_next           = locked_int_reg;
+                    error_next            = error_reg && !locked_int_reg;
+                    state_next            = STATE_UPD_SCH_1;
+                    cmp_flush             = 1'b1;
+                end else if (cmp_valid_reg && next_ge) begin
+                    timeslot_index_next  = timeslot_index_reg + 1'b1;
+                    timeslot_start_next  = enable && locked_reg;
+                    timeslot_end_next    = timeslot_active_reg;
+                    timeslot_active_next = enable && locked_reg;
+                    state_next           = STATE_UPD_ACT_1;
+                    cmp_flush            = 1'b1;
+                end else if (cmp_valid_reg && timeslot_active_reg && act_ge) begin
+                    timeslot_end_next    = 1'b1;
+                    timeslot_active_next = 1'b0;
+                    state_next           = STATE_WAIT;
+                    cmp_flush            = 1'b1;
                 end else begin
-                    // no increment seconds field
-                    first_slot_s_next = first_slot_s_reg + schedule_period_s_reg;
-                    first_slot_ns_next = ts_ns_inc_reg;
-                end
-                next_slot_s_next = first_slot_s_reg;
-                next_slot_ns_next = first_slot_ns_reg;
-                state_next = STATE_UPDATE_SLOT_1;
-            end
-            STATE_UPDATE_SLOT_1: begin
-                // set next fall time to next rise time plus width
-                ts_ns_inc_next = next_slot_ns_reg + active_period_ns_reg;
-                ts_ns_ovf_next = next_slot_ns_reg + active_period_ns_reg - 31'd1_000_000_000;
-                state_next = STATE_UPDATE_SLOT_2;
-            end
-            STATE_UPDATE_SLOT_2: begin
-                if (!ts_ns_ovf_reg[30]) begin
-                    // if the overflow lookahead did not borrow, one second has elapsed
-                    active_end_s_next = next_slot_s_reg + active_period_s_reg + 1;
-                    active_end_ns_next = ts_ns_ovf_reg;
-                end else begin
-                    // no increment seconds field
-                    active_end_s_next = next_slot_s_reg + active_period_s_reg;
-                    active_end_ns_next = ts_ns_inc_reg;
-                end
-                // set next timeslot start time to next timeslot start time plus timeslot period
-                ts_ns_inc_next = next_slot_ns_reg + timeslot_period_ns_reg;
-                ts_ns_ovf_next = next_slot_ns_reg + timeslot_period_ns_reg - 31'd1_000_000_000;
-                state_next = STATE_UPDATE_SLOT_3;
-            end
-            STATE_UPDATE_SLOT_3: begin
-                if (!ts_ns_ovf_reg[30]) begin
-                    // if the overflow lookahead did not borrow, one second has elapsed
-                    next_slot_s_next = next_slot_s_reg + timeslot_period_s_reg + 1;
-                    next_slot_ns_next = ts_ns_ovf_reg;
-                end else begin
-                    // no increment seconds field
-                    next_slot_s_next = next_slot_s_reg + timeslot_period_s_reg;
-                    next_slot_ns_next = ts_ns_inc_reg;
-                end
-                state_next = STATE_WAIT;
-            end
-            STATE_WAIT: begin
-                if ((time_s_reg > first_slot_s_reg) || (time_s_reg == first_slot_s_reg && time_ns_reg > first_slot_ns_reg)) begin
-                    // start of next schedule period
-                    schedule_start_next = enable && locked_int_reg;
-                    timeslot_index_next = 0;
-                    timeslot_start_next = enable && locked_int_reg;
-                    timeslot_end_next = timeslot_active_reg;
-                    timeslot_active_next = enable && locked_int_reg;
-                    schedule_running_next = 1'b1;
-                    locked_next = locked_int_reg;
-                    error_next = error_reg && !locked_int_reg;
-                    state_next = STATE_UPDATE_SCHEDULE_1;
-                end else if ((time_s_reg > next_slot_s_reg) || (time_s_reg == next_slot_s_reg && time_ns_reg > next_slot_ns_reg)) begin
-                    // start of next timeslot
-                    timeslot_index_next = timeslot_index_reg + 1;
-                    timeslot_start_next = enable && locked_reg;
-                    timeslot_end_next = timeslot_active_reg;
-                    timeslot_active_next = enable && locked_reg;
-                    state_next = STATE_UPDATE_SLOT_1;
-                end else if (timeslot_active_reg && ((time_s_reg > active_end_s_reg) || (time_s_reg == active_end_s_reg && time_ns_reg > active_end_ns_reg))) begin
-                    // end of timeslot
-                    timeslot_end_next = 1'b1;
-                    timeslot_active_next = 1'b0;
-                    state_next = STATE_WAIT;
-                end else begin
-                    locked_int_next = schedule_running_reg;
+                    if (cmp_valid_reg) begin
+                        locked_int_next = schedule_running_reg;
+                    end
                     state_next = STATE_WAIT;
                 end
+            end
+            default: begin
+                state_next = STATE_IDLE;
+                cmp_flush  = 1'b1;
             end
         endcase
     end
 end
 
 always @(posedge clk) begin
-    state_reg <= state_next;
-
-    time_s_reg <= input_ts_96[95:48];
-    time_ns_reg <= input_ts_96[45:16];
-
-    if (input_schedule_start_valid) begin
-        schedule_start_s_reg <= input_schedule_start[79:32];
-        schedule_start_ns_reg <= input_schedule_start[31:0];
-    end
-
-    if (input_schedule_period_valid) begin
-        schedule_period_s_reg <= input_schedule_period[79:32];
-        schedule_period_ns_reg <= input_schedule_period[31:0];
-    end
-
-    if (input_timeslot_period_valid) begin
-        timeslot_period_s_reg <= input_timeslot_period[79:32];
-        timeslot_period_ns_reg <= input_timeslot_period[31:0];
-    end
-
-    if (input_active_period_valid) begin
-        active_period_s_reg <= input_active_period[79:32];
-        active_period_ns_reg <= input_active_period[31:0];
-    end
-
-    first_slot_s_reg <= first_slot_s_next;
-    first_slot_ns_reg <= first_slot_ns_next;
-
-    next_slot_s_reg <= next_slot_s_next;
-    next_slot_ns_reg <= next_slot_ns_next;
-
-    active_end_s_reg <= active_end_s_next;
-    active_end_ns_reg <= active_end_ns_next;
-
-    ts_ns_inc_reg <= ts_ns_inc_next;
-    ts_ns_ovf_reg <= ts_ns_ovf_next;
-
-    locked_reg <= locked_next;
-    locked_int_reg <= locked_int_next;
-    error_reg <= error_next;
-    schedule_running_reg <= schedule_running_next;
-
-    schedule_start_reg <= schedule_start_next;
-    timeslot_index_reg <= timeslot_index_next;
-    timeslot_start_reg <= timeslot_start_next;
-    timeslot_end_reg <= timeslot_end_next;
-    timeslot_active_reg <= timeslot_active_next;
-
     if (rst) begin
-        state_reg <= STATE_IDLE;
-
-        time_s_reg <= 0;
-        time_ns_reg <= 0;
-
-        schedule_start_s_reg <= SCHEDULE_START_S;
-        schedule_start_ns_reg <= SCHEDULE_START_NS;
-
-        schedule_period_s_reg <= SCHEDULE_PERIOD_S;
+        state_reg              <= STATE_IDLE;
+        time_s_reg             <= 48'd0;
+        time_ns_reg            <= 31'd0;
+        time_valid_reg         <= 1'b0;
+        first_slot_s_reg       <= 48'd0;
+        first_slot_ns_reg      <= 31'd0;
+        next_slot_s_reg        <= 48'd0;
+        next_slot_ns_reg       <= 31'd0;
+        active_end_s_reg       <= 48'd0;
+        active_end_ns_reg      <= 31'd0;
+        schedule_start_s_reg   <= SCHEDULE_START_S;
+        schedule_start_ns_reg  <= SCHEDULE_START_NS;
+        schedule_period_s_reg  <= SCHEDULE_PERIOD_S;
         schedule_period_ns_reg <= SCHEDULE_PERIOD_NS;
-
-        timeslot_period_s_reg <= TIMESLOT_PERIOD_S;
+        timeslot_period_s_reg  <= TIMESLOT_PERIOD_S;
         timeslot_period_ns_reg <= TIMESLOT_PERIOD_NS;
-
-        active_period_s_reg <= ACTIVE_PERIOD_S;
-        active_period_ns_reg <= ACTIVE_PERIOD_NS;
-
-        locked_reg <= 1'b0;
-        locked_int_reg <= 1'b0;
-        error_reg <= 1'b0;
-        schedule_running_reg <= 1'b0;
-
-        schedule_start_reg <= 1'b0;
-        timeslot_index_reg <= 0;
-        timeslot_start_reg <= 1'b0;
-        timeslot_end_reg <= 1'b0;
-        timeslot_active_reg <= 1'b0;
+        active_period_s_reg    <= ACTIVE_PERIOD_S;
+        active_period_ns_reg   <= ACTIVE_PERIOD_NS;
+        add_ns_lo_r            <= 17'd0;
+        add_ns_hi0_r           <= 16'd0;
+        add_ns_hi1_r           <= 16'd0;
+        add_s0_lo_r            <= 17'd0;
+        add_s1_lo_r            <= 17'd0;
+        add_s_mid0_r           <= 17'd0;
+        add_s_mid1_r           <= 17'd0;
+        add_s_hi0_r            <= 16'd0;
+        add_s_hi1_r            <= 16'd0;
+        ns_sum_r               <= 31'd0;
+        ovf_lo_r               <= 17'd0;
+        ovf_hi0_r              <= 16'd0;
+        ovf_hi1_r              <= 16'd0;
+        s_sum_c0_r             <= 48'd0;
+        s_sum_c1_r             <= 48'd0;
+        first_gt_r             <= 5'd0;
+        first_eq_r             <= 4'd0;
+        next_gt_r              <= 5'd0
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axis_fifo.v`](environment/public/code/axis_fifo.v) *(Read-Only Context)*
- [`environment/public/code/priority_encoder.v`](environment/public/code/priority_encoder.v) *(Read-Only Context)*
- [`environment/public/code/tdma_scheduler.v`](environment/public/code/tdma_scheduler.v) **(Editable)**
- [`environment/public/code/tx_scheduler_ctrl_tdma.v`](environment/public/code/tx_scheduler_ctrl_tdma.v) **(Editable)**
- [`environment/public/code/tx_scheduler_rr.v`](environment/public/code/tx_scheduler_rr.v) **(Editable)**
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

