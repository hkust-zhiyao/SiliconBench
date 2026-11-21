# `case_24005`: Cross-Domain Unilateral Reset Isolation, Segmented Output Gating, and Multi-Corner STA in BaseJump Async FIFO

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_24005` |
| **Source Silicon Repository** | `bespoke-silicon-group/basejump_stl` (`repo_12`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `MultiCore_SoCs_and_NoC` (MultiCore_SoCs_and_NoC) |
| **Multi-Domain Tags** | `MultiCore_SoCs_and_NoC` |
| **Editable Files (`allowed_edits`)** | [`code/bsg_async_fifo.sv`](environment/public/code/bsg_async_fifo.sv), [`code/bsg_async_ptr_gray.sv`](environment/public/code/bsg_async_ptr_gray.sv), [`code/bsg_mem_1r1w.sv`](environment/public/code/bsg_mem_1r1w.sv), [`constraints/bsg_async_fifo.sdc`](environment/public/constraints/bsg_async_fifo.sdc) (4 files, 379 LOC) |
| **Public Subsystem Context** | 8 RTL files (1025 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Cross-Domain Reset Isolation, Segmented Output Gating, and Multi-Corner Timing Closure in `bsg_async_fifo`

`bsg_async_fifo` (`code/bsg_async_fifo.sv`, `code/bsg_async_ptr_gray.sv`, `code/bsg_mem_1r1w.sv`) transfers framed control+payload words across independent write (`w_clk_i`/`w_reset_i`) and read (`r_clk_i`/`r_reset_i`) clock/reset islands. Gate-level verification and multi-corner STA signoff exposed reset-island desynchronization, empty-FIFO write-through leakage, sub-cycle flag glitches, parameter elaboration failures, and timing signoff violations.

Update the editable RTL (`code/bsg_async_fifo.sv`, `code/bsg_async_ptr_gray.sv`, `code/bsg_mem_1r1w.sv`) and timing constraints (`constraints/bsg_async_fifo.sdc`) while preserving `bsg_async_fifo`'s module/parameter/port interface and read-only primitives.

## Architectural & Signoff Contract

1. **Unilateral & Concurrent Domain Reset Recovery (`1:7` to `7:1` Clock Ratios)**:
   - Producer (`w_reset_i`) and consumer (`r_reset_i`) synchronous resets may assert either concurrently or **unilaterally** (e.g., `w_reset_i` pulsed for `>= 1` `w_clk_i` cycle while `r_reset_i == 0`, or `r_reset_i` pulsed for `>= 1` `r_clk_i` cycle while `w_reset_i == 0`) on an active or partially populated FIFO.
   - Any reset on either domain must safely isolate both interfaces (`w_full_o == 1`, `r_valid_o == 0`), coordinate cross-domain pointer/synchronizer clearing without multi-bit Gray transition hazards while the peer is live, and hold `w_full_o == 1` and `r_valid_o == 0` until both domains have released reset and flushed all synchronizer pipelines to empty (`0`), then restore full `2**lg_size_p` capacity and 1-word/cycle throughput.
   - Out-of-protocol `w_enq_i` while `w_full_o == 1` and `r_deq_i` while `r_valid_o == 0` must be safely ignored without corrupting state or firing simulation assertions.

2. **Parameter Completeness, Segmented Empty-RAM Isolation & Glitch-Free Flags**:
   - Elaborate and synthesize cleanly across all `lg_size_p >= 1` and `0 <= control_width_p <= width_p` (`0`, split control/payload, and `control_width_p == width_p`) with zero inferred latches.
   - Control MSBs (`[width_p-1 -: control_width_p]`, when `control_width_p > 0`) must always be gated to `'0` via `bsg_and` whenever `r_valid_o == 0` regardless of `and_data_with_valid_p`. Payload LSBs (`[width_p - control_width_p - 1 : 0]`, when `width_p > control_width_p`) must be gated to `'0` via `bsg_and` when `r_valid_o == 0` only if `and_data_with_valid_p != 0`, and remain un-gated when `and_data_with_valid_p == 0`.
   - Under gate-level logic and per-flop clock-to-Q skew, `r_valid_o` and `w_full_o` must transition cleanly only on active clock edges with zero sub-cycle decode glitches when local and remote pointers advance together, and gated `r_data_o` bits must never glitch while empty.

3. **Nangate45 Slow/Fast Timing Signoff (`lg_size_p=3, width_p=16, control_width_p=4, and_data_with_valid_p=1`)**:
   - Clocks: `w_clk_i` at `4.0 ns`, `r_clk_i` at `2.5 ns`; clock uncertainty `>= 0.12 ns` setup / `>= 0.03 ns` hold.
   - Synchronous I/O budgets: `w_clk_i` inputs (`w_reset_i`, `w_enq_i`, `w_data_i[*]`) `0.60 ns` max / `0.10 ns` min, output (`w_full_o`) `0.60 ns` max / `0.05 ns` min; `r_clk_i` inputs (`r_reset_i`, `r_deq_i`) `0.50 ns` max / `0.10 ns` min, outputs (`r_valid_o`, `r_data_o[*]`) `0.50 ns` max / `0.05 ns` min.
   - Cross-domain Gray pointer and control crossings must be physically delay-bounded to `<= min(T_w, T_r)` (`2.50 ns`) without blanket asynchronous clock groups or unconstrained clock-to-clock false paths, while properly constraining asynchronous FIFO storage read paths so Slow (`1.25`/`1.00`) and Fast (`1.00`/`0.75`) corners achieve zero setup/hold violations.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment

## Editable Files
- `code/bsg_async_fifo.sv`
- `code/bsg_async_ptr_gray.sv`
- `code/bsg_mem_1r1w.sv`
- `constraints/bsg_async_fifo.sdc`

All other files under `code/` and `lib/` are read-only collateral and must not be modified.

## Available Tools
- **Icarus Verilog (`iverilog -g2012` / `vvp`)**:
  ```bash
  iverilog -g2012 -I code -s tb -o sim.vvp \
    code/bsg_and.sv code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
    code/bsg_launch_sync_sync.sv code/bsg_async_ptr_gray.sv code/bsg_async_fifo.sv tb.sv
  vvp sim.vvp
  ```
- **Yosys + Slang (`yosys -p "plugin -i slang; ..."`)** with `-DSYNTHESIS -DYOSYS -I code` and `lib/NangateOpenCellLibrary_typical.lib`.
- **OpenROAD / OpenSTA (`openroad -exit`)** with `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib`.
- Note: `constraints/bsg_async_fifo.sdc` must use pure standard SDC commands only.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/bsg_async_fifo.sv (Buggy Starter)
+++ b/solution/gold/code/bsg_async_fifo.sv (Golden Reference)
@@ -1,41 +1,18 @@
-// MBT 7/24/2014
-// async fifo
-// uses synchronous reset for both sides
-//
-// note: special attention should be paid to
-// how reset is done. you cannot just tie
-// the two resets together. talk to MBT.
-//
-// talk to MBT if you intend to change this
-// it has been specially designed to cross
-// clock domains.
-//
+// Lockstep isolate-clear-drain RDC + segmented low-power gating + glitch-free flags for bsg_async_fifo
 
 `include "bsg_defines.sv"
 
 module bsg_async_fifo #(parameter `BSG_INV_PARAM(  lg_size_p )
                         , parameter `BSG_INV_PARAM(  width_p )
-                        // we allow the control bits to be separated from
-                        // the data bits to allow for better control optimization.
-                        // control_width_p is how many of the width_p bits are control bits;
-                        // these bits should be at the top of the array
                         , parameter   control_width_p = 0
-                        // When the fifo is empty, the rdata output of this fifo changes based
-                        // on wvalid, while rvalid is synchronized to the rclk. This can cause
-                        // timing violations on flops which directly latch the rdata without
-                        // considering the enable signal. This parameter zeros out data when
-                        // the fifo is empty to avoid these glitches. If receiving logic uses 
-                        // the rvalid signal, this extra hardware is unnecessary
                         , parameter   and_data_with_valid_p = 0)
    (
     input    w_clk_i
     , input  w_reset_i
-    // not legal to w_enq_i if w_full_o is not low.
     , input  w_enq_i
     , input  [width_p-1:0] w_data_i
     , output w_full_o
 
-    // not legal to r_deq_i if r_valid_o is not high.
     , input  r_clk_i
     , input  r_reset_i
     , input  r_deq_i
@@ -43,110 +20,260 @@
     , output r_valid_o
     );
 
-   localparam size_lp = 1 << lg_size_p;
-
-   // we use an extra bit for the pointers to detect wraparound
-   logic [lg_size_p:0] r_ptr_gray_r;
-
-   logic [lg_size_p:0] w_ptr_gray_r;
-   logic [lg_size_p:0] w_ptr_gray_r_rsync, r_ptr_gray_r_wsync, r_ptr_binary_r, w_ptr_binary_r;
-
-   wire               r_valid_o_tmp; // remove inout warning from Lint
-   assign r_valid_o = r_valid_o_tmp;
-
-   wire [width_p-1:0] r_data_o_tmp;
-   if (and_data_with_valid_p)
-     begin : fi
-       wire [width_p-1:0] r_valid_o_exp = { width_p { r_valid_o_tmp } };
-       bsg_and #(.width_p(width_p), .harden_p(1)) ba
-         (.a_i  (r_data_o_tmp)
-          ,.b_i (r_valid_o_exp)
-          ,.o   (r_data_o)
-          );
-     end
-   else
-     begin : fi
-       assign r_data_o = r_data_o_tmp;
-     end
-
-   bsg_mem_1r1w #(.width_p(width_p-control_width_p)
-                  ,.els_p(size_lp)
-		  ,.read_write_same_addr_p(0)
-                  ) MSYNC_1r1w
-     (.w_clk_i    (w_clk_i  )
-      ,.w_reset_i (w_reset_i)
-
-      ,.w_v_i   (w_enq_i                                  )
-      ,.w_addr_i(w_ptr_binary_r[0+:lg_size_p]             )
-      ,.w_data_i(w_data_i[0+:(width_p - control_width_p)] )
-
-      ,.r_v_i   (r_valid_o_tmp                            )
-      ,.r_addr_i(r_ptr_binary_r[0+:lg_size_p]             )
-      ,.r_data_o(r_data_o_tmp[0+:(width_p - control_width_p)] )
-      );
-
-   if (control_width_p > 0)
-     begin : ctrl
-        bsg_mem_1r1w #(.width_p(control_width_p)
-                       ,.els_p(size_lp)
-		       ,.read_write_same_addr_p(0)
-                       ) MSYNC_1r1w
-          (.w_clk_i   (w_clk_i  )
-           ,.w_reset_i(w_reset_i)
-
-           ,.w_v_i    (w_enq_i                           )
-           ,.w_addr_i (w_ptr_binary_r[0+:lg_size_p]      )
-           ,.w_data_i (w_data_i[(width_p-1)-:control_width_p])
-
-           ,.r_v_i    (r_valid_o_tmp                     )
-           ,.r_addr_i (r_ptr_binary_r[0+:lg_size_p]      )
-           ,.r_data_o (r_data_o_tmp[(width_p-1)-:control_width_p])
-           );
-     end
-
-   // pointer from writer to reader (input to output of FIFO)
+   localparam int unsigned size_lp = 1 << lg_size_p;
+   localparam int unsigned data_width_lp = width_p - control_width_p;
+
+   // Symmetric 4-phase cross-domain reset-isolation & synchronous pointer clear controller
+   typedef enum logic [1:0] {
+      RDC_RUN      = 2'd0,
+      RDC_REQ_ISO  = 2'd1,
+      RDC_CLR_WAIT = 2'd2,
+      RDC_DRAIN    = 2'd3
+   } rdc_state_e;
+
+   rdc_state_e w_state_q = RDC_REQ_ISO;
+   rdc_state_e r_state_q = RDC_REQ_ISO;
+   logic       w_retrig_q = 1'b0, r_retrig_q = 1'b0;
+   logic [1:0] w_drain_q  = 2'd2, r_drain_q  = 2'd2;
+
+   logic w_req_lnch, w_req_rsync;
+   logic r_req_lnch, r_req_wsync;
+
+   wire w_req_d = (w_state_q == RDC_REQ_ISO) ||
+                  ((w_state_q == RDC_RUN || w_state_q == RDC_DRAIN) && (w_reset_i || r_req_wsync));
+   wire r_req_d = (r_state_q == RDC_REQ_ISO) ||
+                  ((r_state_q == RDC_RUN || r_state_q == RDC_DRAIN) && (r_reset_i || w_req_rsync));
+
+   bsg_launch_sync_sync #(.width_p(1)) u_wrst_sync (
+      .iclk_i      (w_clk_i),
+      .iclk_reset_i(1'b0),
+      .oclk_i      (r_clk_i),
+      .iclk_data_i (w_req_d),
+      .iclk_data_o (w_req_lnch),
+      .oclk_data_o (w_req_rsync)
+   );
+
+   bsg_launch_sync_sync #(.width_p(1)) u_rrst_sync (
+      .iclk_i      (r_clk_i),
+      .iclk_reset_i(1'b0),
+      .oclk_i      (w_clk_i),
+      .iclk_data_i (r_req_d),
+      .iclk_data_o (r_req_lnch),
+      .oclk_data_o (r_req_wsync)
+   );
+
+   always_ff @(posedge w_clk_i) begin
+      if (w_reset_i) begin
+         if (w_state_q == RDC_CLR_WAIT) begin
+            w_retrig_q <= 1'b1;
+         end else begin
+            w_state_q  <= RDC_REQ_ISO;
+            w_retrig_q <= 1'b0;
+         end
+         w_drain_q <= 2'd2;
+      end else begin
+         unique case (w_state_q)
+            RDC_RUN: begin
+               if (r_req_wsync) begin
+                  w_state_q <= RDC_REQ_ISO;
+               end
+            end
+            RDC_REQ_ISO: begin
+               if (r_req_wsync) begin
+                  w_state_q <= RDC_CLR_WAIT;
+               end
+            end
+            RDC_CLR_WAIT: begin
+               if (!r_req_wsync) begin
+                  if (w_retrig_q) begin
+                     w_retrig_q <= 1'b0;
+                     w_state_q  <= RDC_REQ_ISO;
+                  end else begin
+                     w_drain_q <= 2'd2;
+                     w_state_q <= RDC_DRAIN;
+                  end
+               end
+            end
+            RDC_DRAIN: begin
+               if (r_req_wsync) begin
+                  w_state_q <= RDC_REQ_ISO;
+               end else if (w_drain_q != 2'd0) begin
+                  w_drain_q <= w_drain_q - 2'd1;
+               end else begin
+                  w_state_q <= RDC_RUN;
+               end
+            end
+            default: w_state_q <= RDC_REQ_ISO;
+         endcase
+      end
+   end
+
+   always_ff @(posedge r_clk_i) begin
+      if (r_reset_i) begin
+         if (r_state_q == RDC_CLR_WAIT) begin
+            r_retrig_q <= 1'b1;
+         end else begin
+            r_state_q  <= RDC_REQ_ISO;
+            r_retrig_q <= 1'b0;
+         end
+         r_drain_q <= 2'd2;
+      end else begin
+         unique case (r_state_q)
+            RDC_RUN: begin
+               if (w_req_rsync) begin
+                  r_state_q <= RDC_REQ_ISO;
+               end
+            end
+            RDC_REQ_ISO: begin
+               if (w_req_rsync) begin
+                  r_state_q <= RDC_CLR_WAIT;
+               end
+            end
+            RDC_CLR_WAIT: begin
+               if (!w_req_rsync) begin
+                  if (r_retrig_q) begin
+                     r_retrig_q <= 1'b0;
+                     r_state_q  <= RDC_REQ_ISO;
+                  end else begin
+                     r_drain_q <= 2'd2;
+                     r_state_q <= RDC_DRAIN;
+                  end
+               end
+            end
+            RDC_DRAIN: begin
+               if (w_req_rsync) begin
+                  r_state_q <= RDC_REQ_ISO;
+               end else if (r_drain_q != 2'd0) begin
+                  r_drain_q <= r_drain_q - 2'd1;
+               end else begin
+                  r_state_q <= RDC_RUN;
+               end
+            end
+            default: r_state_q <= RDC_REQ_ISO;
+         endcase
+      end
+   end
+
+   // Clear pointers ONLY while both domains are safely isolated in RDC_CLR_WAIT!
+   wire w_ptr_clr = (w_state_q == RDC_CLR_WAIT);
+   wire r_ptr_clr = (r_state_q == RDC_CLR_WAIT);
+
+   logic [lg_size_p:0] r_ptr_gray_r, w_ptr_gray_r;
+   logic [lg_size_p:0] w_ptr_gray_r_rsync, r_ptr_gray_r_wsync;
+   logic [lg_size_p:0] r_ptr_binary_r, w_ptr_binary_r;
+
+   logic w_full_r  = 1'b1;
+   logic r_valid_r = 1'b0;
+
+   wire w_isolated = w_reset_i || r_req_wsync || (w_state_q != RDC_RUN);
+   wire r_isolated = r_reset_i || w_req_rsync || (r_state_q != RDC_RUN);
+
+   wire w_enq_eff = w_enq_i & ~w_full_r & ~w_isolated;
+   wire r_deq_eff = r_deq_i & r_valid_r & ~r_isolated;
+
+   wire [lg_size_p:0] w_ptr_binary_n = w_ptr_clr ? '0 : (w_ptr_binary_r + {{lg_size_p{1'b0}}, w_enq_eff});
+   wire [lg_size_p:0] w_ptr_gray_n   = (w_ptr_binary_n >> 1) ^ w_ptr_binary_n;
+
+   wire [lg_size_p:0] r_ptr_binary_n = r_ptr_clr ? '0 : (r_ptr_binary_r + {{lg_size_p{1'b0}}, r_deq_eff});
+   wire [lg_size_p:0] r_ptr_gray_n   = (r_ptr_binary_n >> 1) ^ r_ptr_binary_n;
+
+   wire [lg_size_p:0] w_full_target_gray;
+   if (lg_size_p == 1) begin : gen_full_lg1
+      assign w_full_target_gray = ~r_ptr_gray_r_wsync[1:0];
+   end else begin : gen_full_lgN
+      assign w_full_target_gray = { ~r_ptr_gray_r_wsync[lg_size_p-:2],
+                                     r_ptr_gray_r_wsync[0+:(`BSG_SAFE_MINUS(lg_size_p, 1))] };
+   end
+
+   always_ff @(posedge w_clk_i) begin
+      if (w_reset_i || r_req_wsync || (w_state_q == RDC_REQ_ISO) || (w_state_q == RDC_CLR_WAIT) ||
+          ((w_state_q == RDC_DRAIN) && (w_drain_q != 2'd0)))
+         w_full_r <= 1'b1;
+      else
+         w_full_r <= (w_ptr_gray_n == w_full_target_gray);
+   end
+
+   always_ff @(posedge r_clk_i) begin
+      if (r_reset_i || w_req_rsync || (r_state_q == RDC_REQ_ISO) || (r_state_q == RDC_CLR_WAIT) ||
+          ((r_state_q == RDC_DRAIN) && (r_drain_q != 2'd0)))
+         r_valid_r <= 1'b0;
+      else
+         r_valid_r <= (r_ptr_gray_n != w_ptr_gray_r_rsync);
+   end
+
+   assign w_full_o  = w_full_r;
+   assign r_valid_o = r_valid_r;
+
+   if (data_width_lp > 0) begin : gen_data
+      wire [data_width_lp-1:0] r_data_lo_raw;
+      bsg_mem_1r1w #(.width_p(data_width_lp)
+                     ,.els_p(size_lp)
+                     ,.read_write_same_addr_p(0)
+                     ) MSYNC_1r1w
+        (.w_clk_i   (w_clk_i)
+         ,.w_reset_i(w_reset_i)
+         ,.w_v_i    (w_enq_eff)
+         ,.w_addr_i (w_ptr_binary_r[0+:lg_size_p])
+         ,.w_data_i (w_data_i[0+:data_width_lp])
+         ,.r_v_i    (r_valid_r)
+         ,.r_addr_i (r_ptr_binary_r[0+:lg_size_p])
+         ,.r_data_o (r_data_lo_raw)
+         );
+
+      if (and_data_with_valid_p != 0) begin : fi
+         bsg_and #(.width_p(data_width_lp), .harden_p(1)) ba_data
+           (.a_i(r_data_lo_raw)
+            ,.b_i({data_width_lp{r_valid_r}})
+            ,.o  (r_data_o[0+:data_width_lp])
+            );
+      end else begin : fi_nogate
+         assign r_data_o[0+:data_width_lp] = r_data_lo_raw;
+      end
+   end
+
+   if (control_width_p > 0) begin : ctrl
+      wire [control_width_p-1:0] r_ctrl_hi_raw;
+      bsg_mem_1r1w #(.width_p(control_width_p)
+                     ,.els_p(size_lp)
+                     ,.read_write_same_addr_p(0)
+                     ) MSYNC_1r1w
+        (.w_clk_i   (w_clk_i)
+         ,.w_reset_i(w_reset_i)
+         ,.w_v_i    (w_enq_eff)
+         ,.w_addr_i (w_ptr_binary_r[0+:lg_size_p])
+         ,.w_data_i (w_data_i[(width_p-1)-:control_width_p])
+         ,.r_v_i    (r_valid_r)
+         ,.r_addr_i (r_ptr_binary_r[0+:lg_size_p])
+         ,.r_data_o (r_ctrl_hi_raw)
+         );
+
+      bsg_and #(.width_p(control_width_p), .harden_p(1)) ba_ctrl
+        (.a_i(r_ctrl_hi_raw)
+         ,.b_i({control_width_p{r_valid_r}})
+         ,.o  (r_data_o[(width_p-1)-:control_width_p])
+         );
+   end
+
    bsg_async_ptr_gray #(.lg_size_p(lg_size_p+1)) bapg_wr
    (.w_clk_i(w_clk_i)
-    ,.w_reset_i(w_reset_i)
-    ,.w_inc_i(w_enq_i)
+    ,.w_reset_i(w_ptr_clr)
+    ,.w_inc_i(w_enq_eff)
     ,.r_clk_i(r_clk_i)
     ,.w_ptr_binary_r_o(w_ptr_binary_r)
     ,.w_ptr_gray_r_o(w_ptr_gray_r)
     ,.w_ptr_gray_r_rsync_o(w_ptr_gray_r_rsync)
     );
 
-   // pointer from reader to writer (output to input of FIFO)
-   // note this pointer travels backwards so the order is reverse
-
    bsg_async_ptr_gray #(.lg_size_p(lg_size_p+1)) bapg_rd
    (.w_clk_i(r_clk_i)
-    ,.w_reset_i(r_reset_i)
-    ,.w_inc_i(r_deq_i)
+    ,.w_reset_i(r_ptr_clr)
+    ,.w_inc_i(r_deq_eff)
     ,.r_clk_i(w_clk_i)
     ,.w_ptr_binary_r_o(r_ptr_binary_r)
-    ,.w_ptr_gray_r_o(r_ptr_gray_r)  // after launch flop
-    ,.w_ptr_gray_r_rsync_o(r_ptr_gray_r_wsync) // after sync flops
+    ,.w_ptr_gray_r_o(r_ptr_gray_r)
+    ,.w_ptr_gray_r_rsync_o(r_ptr_gray_r_wsync)
     );
 
-   // data is available if the two pointers are not equal
-   assign r_valid_o_tmp = (r_ptr_gray_r != w_ptr_gray_r_rsync);
-
-   // compare two gray code values whose binaries values differ
-   // by top bit; this corresponds to the full conditions
-
-   assign w_full_o  = (w_ptr_gray_r == { ~r_ptr_gray_r_wsync[lg_size_p-:2]
-                                         , r_ptr_gray_r_wsync[0+:lg_size_p-1] });
-
-
-`ifndef BSG_HIDE_FROM_SYNTHESIS
-   always @(negedge w_clk_i)
-     assert(!(w_full_o===1 && w_enq_i===1))   else $error("enqueing data on bsg_async_fifo when full");
-
-   always @(negedge r_clk_i)
-     assert(!(r_valid_o_tmp===0 && r_deq_i===1)) else $error("dequeing data on bsg_async_fifo when empty");
-
-`endif
-
-endmodule // bsg_async_fifo
+endmodule
 
 `BSG_ABSTRACT_MODULE(bsg_async_fifo)

--- a/environment/public/constraints/bsg_async_fifo.sdc (Buggy Starter)
+++ b/solution/gold/constraints/bsg_async_fifo.sdc (Golden Reference)
@@ -1,4 +1,24 @@
-# Baseline timing constraints for bsg_async_fifo
+# Signoff SDC for bsg_async_fifo (lg_size_p=3, width_p=16, control_width_p=4, and_data_with_valid_p=1)
 create_clock -name w_clk -period 4.0 [get_ports w_clk_i]
 create_clock -name r_clk -period 2.5 [get_ports r_clk_i]
-set_clock_groups -asynchronous -group [get_clocks w_clk] -group [get_clocks r_clk]
+
+set_clock_uncertainty -setup 0.12 [all_clocks]
+set_clock_uncertainty -hold  0.03 [all_clocks]
+
+set_input_delay  -clock w_clk -max 0.60 [get_ports {w_reset_i w_enq_i w_data_i[*]}]
+set_input_delay  -clock w_clk -min 0.10 [get_ports {w_reset_i w_enq_i w_data_i[*]}]
+set_output_delay -clock w_clk -max 0.60 [get_ports w_full_o]
+set_output_delay -clock w_clk -min 0.05 [get_ports w_full_o]
+
+set_input_delay  -clock r_clk -max 0.50 [get_ports {r_reset_i r_deq_i}]
+set_input_delay  -clock r_clk -min 0.10 [get_ports {r_reset_i r_deq_i}]
+set_output_delay -clock r_clk -max 0.50 [get_ports {r_valid_o r_data_o[*]}]
+set_output_delay -clock r_clk -min 0.05 [get_ports {r_valid_o r_data_o[*]}]
+
+# Bounded CDC crossings on all launch-sync-sync primitives (Gray pointers + RDC handshakes)
+set_max_delay 2.00 -from [get_cells -hierarchical *blss/iclk_i_DFF*] -to [get_cells -hierarchical *blss/oclk_i_DFF*]
+set_false_path -hold -from [get_cells -hierarchical *blss/iclk_i_DFF*] -to [get_cells -hierarchical *blss/oclk_i_DFF*]
+
+# Asynchronous dual-port FIFO RAM write-clock storage to read-clock output bus crossing
+set_max_delay 2.40 -from [get_cells -hierarchical *synth/*mem*DFF*] -to [get_ports r_data_o[*]]
+set_false_path -hold -from [get_cells -hierarchical *synth/*mem*DFF*] -to [get_ports r_data_o[*]]

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/bsg_and.sv`](environment/public/code/bsg_and.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_async_fifo.sv`](environment/public/code/bsg_async_fifo.sv) **(Editable)**
- [`environment/public/code/bsg_async_ptr_gray.sv`](environment/public/code/bsg_async_ptr_gray.sv) **(Editable)**
- [`environment/public/code/bsg_defines.sv`](environment/public/code/bsg_defines.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_launch_sync_sync.sv`](environment/public/code/bsg_launch_sync_sync.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_mem_1r1w.sv`](environment/public/code/bsg_mem_1r1w.sv) **(Editable)**
- [`environment/public/code/bsg_mem_1r1w_synth.sv`](environment/public/code/bsg_mem_1r1w_synth.sv) *(Read-Only Context)*
- [`environment/public/constraints/bsg_async_fifo.sdc`](environment/public/constraints/bsg_async_fifo.sdc) **(Editable)**
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

