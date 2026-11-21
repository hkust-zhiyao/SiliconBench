# `case_24001`: Enforce Lockstep Bidirectional Isolation and One-Sided Reset Re-Entry in Croc CDC Reset Controller

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_24001` |
| **Source Silicon Repository** | `pulp-platform/croc` (`repo_15`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 2: Logic Synthesis & Gate-Level Verification** (`stage2_synth_gate`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Yosys+Slang Standard-Cell Synthesis, Cell-Area Caps & 4-State Gate-Level X-Propagation Verification) |
| **Primary Hardware Domain** | `MultiCore_SoCs_and_NoC` (MultiCore_SoCs_and_NoC) |
| **Multi-Domain Tags** | `MultiCore_SoCs_and_NoC` |
| **Editable Files (`allowed_edits`)** | [`code/cdc_reset_ctrlr.sv`](environment/public/code/cdc_reset_ctrlr.sv) (1 files, 529 LOC) |
| **Public Subsystem Context** | 7 RTL files (1285 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Fix Lockstep Bidirectional Isolation and One-Sided Reset Re-Entry in `cdc_reset_ctrlr`

`cdc_reset_ctrlr` (`code/cdc_reset_ctrlr.sv`) coordinates symmetric lockstep isolation and synchronous clearing across two independent clock/reset domains (`a_clk_i`/`a_rst_ni` and `b_clk_i`/`b_rst_ni`). Under multi-ratio asynchronous clocking, overlapping clear requests, and one-sided asynchronous reset re-entry, the controller exhibits protocol violations and hangs.

## Required Behavior

Update `code/cdc_reset_ctrlr.sv` while keeping its module/port interface and `cdc_reset_ctrlr_pkg` types intact so that all of the following hold across arbitrary clock frequency ratios and phase offsets:

1. **Parameterized Synchronizer Depth (`SYNC_STAGES >= 2`)**:
   - Propagate `SYNC_STAGES` to both internal 4-phase CDC channels on Side A and Side B so cross-domain request/acknowledge paths traverse `SYNC_STAGES` synchronizer stages rather than a hardcoded depth.

2. **Strict Bidirectional Isolate-Before-Clear & Teardown Ordering**:
   - Neither `a_clear_o` nor `b_clear_o` may ever assert unless its local `isolate_o` is high, its local `isolate_ack_i` has already been observed during the current continuous `isolate_o` assertion window, and the peer domain has also asserted `isolate_o` and observed its `isolate_ack_i` (unless the peer is currently held in active-low asynchronous reset).
   - Once `clear_o` asserts on a domain, `isolate_o` on that domain must stay continuously high until after `clear_o` has deasserted for post-clear teardown (`clear_o` must never outlive or drop simultaneously with `isolate_o`).
   - Support both level-held and single-cycle pulsed `isolate_ack_i` and `clear_ack_i` handshakes without deadlock during unilateral (`a_clear_i` or `b_clear_i`) and simultaneous bidirectional (`a_clear_i` and `b_clear_i`) clear sequences.

3. **One-Sided and Mid-Handshake Asynchronous Reset Recovery**:
   - When `CLEAR_ON_ASYNC_RESET = 1`:
     - Asserting `!a_rst_ni` (or `!b_rst_ni`) must still propagate an isolation request to the running peer domain even while the resetting domain's clock is gated/stopped during reset.
     - If one domain suffers an asynchronous reset (`!rst_ni`) in the middle of an active or tearing-down sequence (for example when a prior handshake left a stale `async_ack` high or left the peer unisolated), releasing `rst_ni` must safely drain/resynchronize the 4-phase channel and confirm fresh peer isolation (`peer_isolate_o` and `peer_isolate_ack_i`) before asserting `clear_o` on either side, without deadlocking.
   - If a domain recovers from asynchronous reset (`!rst_ni -> 1` under either `CLEAR_ON_ASYNC_RESET = 1` or `0`) while its peer is already requesting the `CLEAR` phase, the recovering domain must still assert `isolate_o` and observe `isolate_ack_i` before asserting `clear_o`.

4. **No Lost Synchronous `clear_i` During Post-Clear Teardown**:
   - If a synchronous `clear_i` pulse arrives after the `CLEAR` phase has already finished (during post-clear / finish teardown before returning to idle), it must not be dropped; a follow-up full isolate-and-clear sequence must execute once teardown completes.

5. **Synthesizability**:
   - `cdc_reset_ctrlr` must remain cleanly synthesizable SystemVerilog with zero inferred latches.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Guide

## Editable File
- `code/cdc_reset_ctrlr.sv`

## Read-Only Context Files
- `code/cdc_reset_ctrlr_pkg.sv`
- `code/cdc_4phase.sv`
- `code/spill_register.sv`
- `code/spill_register_flushable.sv`
- `code/sync.sv`
- `code/common_cells/assertions.svh`

## Local Compilation & Synthesis Examples

### Verilator (v5.038)
```bash
verilator --binary --timing -Wno-fatal -DCOMMON_CELLS_ASSERTS_OFF -Icode \
  --top-module your_tb \
  code/cdc_reset_ctrlr_pkg.sv \
  code/sync.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/cdc_4phase.sv \
  code/cdc_reset_ctrlr.sv \
  your_tb.sv
./obj_dir/Vyour_tb
```

### Yosys + Slang Synthesis Check
```bash
yosys -p "plugin -i slang; read_slang -DCOMMON_CELLS_ASSERTS_OFF -DSYNTHESIS -I code \
  code/cdc_reset_ctrlr_pkg.sv code/sync.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/cdc_4phase.sv code/cdc_reset_ctrlr.sv \
  --top cdc_reset_ctrlr; hierarchy -check -top cdc_reset_ctrlr; proc; opt; check"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cdc_reset_ctrlr.sv (Buggy Starter)
+++ b/solution/gold/code/cdc_reset_ctrlr.sv (Golden Reference)
@@ -1,146 +1,40 @@
 //-----------------------------------------------------------------------------
 // Title : CDC Clear Signaling Synchronization
 // -----------------------------------------------------------------------------
-// File : cdc_clear_propagator.sv Author : Manuel Eggimann
-// <meggimann@iis.ee.ethz.ch> Created : 22.12.2021
-// -----------------------------------------------------------------------------
-// Description :
-//
-// This module is mainly used internally to synchronize the clear requests
-// between both sides of a CDC module. It aims to solve the problem of
-// initiating a CDC clear, reset one-sidedly without running into
-// reset-domain-crossing issues and breaking CDC protocol assumption.
-//
-// Problem Formulation:
-//
-// CDC implementations usually face the issue that one side of the CDC must not
-// be cleared without clearing the other side. E.g. clearing the write-pointer
-// without clearing the read-pointer in a gray-counting CDC FIFO results in an
-// invalid fill-state an may cause spurious transactions of invalid data to be
-// propagated accross the CDC. A similar effect is caused in 2-phase CDC
-// implementations.
-//
-// A naive mitigation technique would be to reset both domains asynchronously
-// with the same reset signal. This will cause intra-clock domain RDC issues
-// since the asynchronous clear event (assertion of the reset signal) might
-// happen close to the active edge of the CDC's periphery and thus might induce
-// metastability. A better, but still flawed approach would be to naively
-// synchronize assertion AND deassertion (the usual rst sync only synchronize
-// deassertion) of the resets into the respective other domain. However, this
-// might cause the classic issue of fast-to-slow clock domain crossing where the
-// clear signal is not asserted long enough to be captured by the receiving
-// side. The common mitigation strategy is to use a feedback acknowledge signal
-// to handshake the reset request into the other domain. One even more peculiar
-// corner case this approach might suffer is the scenario where the synchronized
-// clear signal arrives at the other side of the CDC within or even worse after
-// the same clock cylce that the other domain crossing signals (e.g. read/write
-// pointers) are cleared. In this scenario, multiple signals change within the
-// same clock cycle and due to metastability we cannot be sure, that the other
-// side of the CDC sees the reset assertion before the first bits of e.g. the
-// write/read pointer start to switch to their reset state. Care must also be
-// taken to handle the corner cases where both sides are reset simultaneously or
-// the case where one side leaves reset earlier than the other.
-//
-// How this Module Works
-//
-// This module has two interfaces, the 'a' side and the 'b' side. Each side can
-// be triggered using the a/b_clear_i signal or (optionally) by the asynchronous
-// a/b_rst_ni. Once e.g. 'a' is triggered it will initiate a clear sequence that
-// first asserts an 'a_isolate_o' signal, waits until the external circuitry
-// acknowledges isolation using the 'a_isolate_ack_i'. Then the module asserts
-// the 'a_clear_o' signals before some cycles later, the isolate signal is
-// deasserted. This sequence ensures that no transactions can arrive to the CDC
-// while the state is cleared. Now the important part is, that those four phases
-// (asser isolate, assert clear, deassert clear, deassert isolate) are mirrored
-// on the other side ('b') in lock-step. The cdc_reset_ctrlr module uses a
-// dedicated 4-phase handshaking CDC to transmit the current phase of the clear
-// sequence to the other domain. We use a 4-phase rather than a 2-phase CDC to
-// avoid the issues of one-sided async reset that might trigger spurious
-// transactions. Furthermore, the 4-phase CDC within this module is operated in
-// a special mode: DECOUPLED=0 ensures that there are no in-flight transactions.
-// The src side only consumes the item once the destination side acknowledged
-// the receiption. This property is required to transition through the phases in
-// lock-step. Furthermore, (SEND_RESET_MSG=1) will cause the src side of the
-// 4-phase CDC to immediately initiate the isolation phase in the dst domain
-// upon asynchronous reset regardless how long the async reset stays asserted or
-// whether the source clock is gated. Both sides of this module independently
-// generate the sequence signals as an initiator (triggered by the clear_i or
-// rst_ni signal) or receiver (trigerred for the other side). The or-ed version
-// of initiator and receiver are used to generate the actual a/b_isolate_o and
-// a/b_clear_o signal. That way, it doesn't matter wheter both sides
-// simulatenously trigger a clear sequence, proper sequencing is still
-// guaranteed.
-//
-// The time it takes to complete an entire clear sequence can be bounded as follows:
-//
-// t_clear <= 20*T+16*SYNC_STAGES*T, with T=max(T_a, T_b) (clock periods of src and dst)
-//
-// How to Use the Module
-//
-// Instantiate the module within your CDC and connect a/b_clk_i, the
-// asyncrhonous a/b_rst_ni and the synchronous a/b_clear_i signals. The 'a' and
-// 'b' port are entirely symetric so it doesn't matter whether you connect src
-// to 'a' or 'b'. If you enable support for async reset
-// (CLEAR_ON_ASYNC_RESET==1), parametrize the number of synchronization stages
-// (for metastability resolution) to be strictly less than the latency of the
-// CDC. E.g. if your CDC uses 3 (the minimum) sync stages, parametrize this
-// module with SYNC_STAGES < 2! Your CDC must implement a src/dst_clear_i port
-// that SYNCHRONOUSLY clears all FFs on the respective side. Connect the CDC's
-// src/dst_clear ports to this module's a/b_clear_o port. Once the a/b_isolate_o
-// signal is asserted, the respective CDC side (src/dst) must be isolated from
-// the outside world (i.e. must no longer accept any transaction on the src side
-// and cease presenting or even withdrawing data on the dst side). Once your CDC
-// side is isolated (depending on protocol this might take several cycles),
-// assert the a/b_isolate_ack_i signal.
-//
-// -----------------------------------------------------------------------------
-// Copyright (C) 2021 ETH Zurich, University of Bologna Copyright and related
-// rights are licensed under the Solderpad Hardware License, Version 0.51 (the
-// "License"); you may not use this file except in compliance with the License.
-// You may obtain a copy of the License at
-// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law or
-// agreed to in writing, software, hardware and materials distributed under this
-// License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
-// OF ANY KIND, either express or implied. See the License for the specific
-// language governing permissions and limitations under the License.
+// Copyright (C) 2021 ETH Zurich, University of Bologna
 // SPDX-License-Identifier: SHL-0.51
 // -----------------------------------------------------------------------------
 
 module cdc_reset_ctrlr
   import cdc_reset_ctrlr_pkg::*;
  #(
-  /// The number of synchronization stages to use for the
-  /// clear signal request/acknowledge. Must be less than the
-  /// number of sync stages used in the CDC.
   parameter int unsigned SYNC_STAGES = 2,
-  /// Whether an asynchronous reset shall cause a clear
-  /// request to be sent to the other side.
   parameter logic        CLEAR_ON_ASYNC_RESET = 1'b1
 )(
   // Side A (both sides are symmetric)
-  input logic  a_clk_i,
-  input logic  a_rst_ni,
-  input logic  a_clear_i,
+  input  logic a_clk_i,
+  input  logic a_rst_ni,
+  input  logic a_clear_i,
   output logic a_clear_o,
-  input logic a_clear_ack_i,
+  input  logic a_clear_ack_i,
   output logic a_isolate_o,
-  input logic  a_isolate_ack_i,
+  input  logic a_isolate_ack_i,
   // Side B (both sides are symmetric)
-  input logic  b_clk_i,
-  input logic  b_rst_ni,
-  input logic  b_clear_i,
+  input  logic b_clk_i,
+  input  logic b_rst_ni,
+  input  logic b_clear_i,
   output logic b_clear_o,
-  input logic  b_clear_ack_i,
+  input  logic b_clear_ack_i,
   output logic b_isolate_o,
-  input logic  b_isolate_ack_i
+  input  logic b_isolate_ack_i
 );
 
   (* dont_touch = "true" *)
-  logic        async_a2b_req, async_b2a_ack;
+  logic             async_a2b_req, async_b2a_ack;
   (* dont_touch = "true" *)
   clear_seq_phase_e async_a2b_next_phase;
   (* dont_touch = "true" *)
-  logic        async_b2a_req, async_a2b_ack;
+  logic             async_b2a_req, async_a2b_ack;
   (* dont_touch = "true" *)
   clear_seq_phase_e async_b2a_next_phase;
 
@@ -163,7 +57,7 @@
     (* async *) .async_ack_o        ( async_a2b_ack        )
   );
 
-    cdc_reset_ctrlr_half #(
+  cdc_reset_ctrlr_half #(
     .SYNC_STAGES          ( SYNC_STAGES          ),
     .CLEAR_ON_ASYNC_RESET ( CLEAR_ON_ASYNC_RESET )
   ) i_cdc_reset_ctrlr_half_b (
@@ -187,80 +81,88 @@
 module cdc_reset_ctrlr_half
   import cdc_reset_ctrlr_pkg::*;
 #(
-  /// The number of synchronization stages to use for the
-  /// clear signal request/acknowledge. Must be less than
-  /// the number of sync stages used in the CDC
   parameter int unsigned SYNC_STAGES = 2,
-  /// Whether an asynchronous reset shall cause a clear
-  /// request to be sent to the other side.
   parameter logic        CLEAR_ON_ASYNC_RESET = 1'b1
 )(
   // Synchronous side
-  input logic                clk_i,
-  input logic                rst_ni,
-  input logic                clear_i,
-  output logic               isolate_o,
-  input logic                isolate_ack_i,
-  output logic               clear_o,
-  input logic                clear_ack_i,
-  // Asynchronous clear sequence hanshaking
-  output clear_seq_phase_e   async_next_phase_o,
-  output logic               async_req_o,
-  input logic                async_ack_i,
-  input clear_seq_phase_e    async_next_phase_i,
-  input logic                async_req_i,
-  output logic               async_ack_o
+  input  logic             clk_i,
+  input  logic             rst_ni,
+  input  logic             clear_i,
+  output logic             isolate_o,
+  input  logic             isolate_ack_i,
+  output logic             clear_o,
+  input  logic             clear_ack_i,
+  // Asynchronous clear sequence handshaking
+  output clear_seq_phase_e async_next_phase_o,
+  output logic             async_req_o,
+  input  logic             async_ack_i,
+  input  clear_seq_phase_e async_next_phase_i,
+  input  logic             async_req_i,
+  output logic             async_ack_o
 );
 
-
-  // How this module works:
-
-  // The module is split into two parts. The initiator part consists of an FSM
-  // that is triggered by the clear_i signal and transitions through reset
-  // sequence. During those transitions, the `initiator_isolate_out` and
-  // `initiator_clear_out` signals are asserted appropriately.
-
-  // The receiver part receives the state transitions from the other clock
-  // domain (initiator part of the `cdc_reset_ctrlr_half` instance in the other
-  // clock domain) and asserts the `receiver_isolate_out` and
-  // `receiver_clear_out` appropriately (considering the `isolate_ack_i`
-  // signal).
-
-  // In both, the initiator and the receiver part, the respective FSM
-  // transitions through 4 phases. In the ISOLATE phase, the isolate signal is
-  // asserted and the connected CDCs are expected to block all further
-  // interactions with the outside world and acknowledge the isolation with the
-  // isolate_ack_i signal. In the CLEAR phase, the clear signal is asserted
-  // which resets the internal state of the CDC while keeping the isolate signal
-  // asserted. In the POST_CLEAR phase, the clear signal is deasserted. Finally,
-  // when returning to the IDLE phase, the isolate signal is deasserted to
-  // continue normal operation. The FSM uses a dedicated 4-phase handshaking CDC
-  // to transition between the phases in lock-step and transmits the current
-  // state to the other domain to avoid issues if the other domain is reset
-  // asynchronously while a clear procedure is pending.
-
-  //---------------------- Initiator Side ----------------------
-  // Sends clear sequence state transitions to the other side.
-   typedef enum logic[3:0] {
-     IDLE,
-     ISOLATE,
-     WAIT_ISOLATE_PHASE_ACK,
-     WAIT_ISOLATE_ACK,
-     CLEAR,
-     WAIT_CLEAR_PHASE_ACK,
-     WAIT_CLEAR_ACK,
-     POST_CLEAR,
-     FINISHED
+  typedef enum logic [3:0] {
+    IDLE,
+    RESET_ISOLATE,
+    ISOLATE,
+    WAIT_ISOLATE_PHASE_ACK,
+    WAIT_ISOLATE_ACK,
+    CLEAR,
+    WAIT_CLEAR_PHASE_ACK,
+    WAIT_CLEAR_ACK,
+    POST_CLEAR,
+    FINISHED
   } initiator_state_e;
+
   initiator_state_e initiator_state_d, initiator_state_q;
 
-  // The current phase of the clear sequence, sent to the other side using a
-  // 4-phase CDC
-  clear_seq_phase_e          initiator_clear_seq_phase;
-  logic                      initiator_phase_transition_req;
-  logic                      initiator_phase_transition_ack;
-  logic                      initiator_isolate_out;
-  logic                      initiator_clear_out;
+  clear_seq_phase_e initiator_clear_seq_phase;
+  logic             initiator_phase_transition_req;
+  logic             initiator_phase_transition_ack;
+  logic             initiator_isolate_out;
+  logic             initiator_clear_out;
+
+  logic iso_ack_seen_q;
+  logic clr_ack_seen_q;
+  logic pending_clear_q;
+  logic eff_iso_ack;
+  logic eff_clr_ack;
+
+  assign eff_iso_ack = isolate_o && (isolate_ack_i || iso_ack_seen_q);
+  assign eff_clr_ack = clear_o   && (clear_ack_i   || clr_ack_seen_q);
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      iso_ack_seen_q <= 1'b0;
+      clr_ack_seen_q <= 1'b0;
+    end else begin
+      if (!isolate_o) begin
+        iso_ack_seen_q <= 1'b0;
+      end else if (isolate_ack_i) begin
+        iso_ack_seen_q <= 1'b1;
+      end
+
+      if (!clear_o) begin
+        clr_ack_seen_q <= 1'b0;
+      end else if (clear_ack_i) begin
+        clr_ack_seen_q <= 1'b1;
+      end
+    end
+  end
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      pending_clear_q <= 1'b0;
+    end else begin
+      if (initiator_state_q == CLEAR ||
+          (initiator_state_q == IDLE && (clear_i || pending_clear_q))) begin
+        pending_clear_q <= 1'b0;
+      end else if (clear_i &&
+                   (initiator_state_q == POST_CLEAR || initiator_state_q == FINISHED)) begin
+        pending_clear_q <= 1'b1;
+      end
+    end
+  end
 
   always_comb begin
     initiator_state_d              = initiator_state_q;
@@ -271,21 +173,34 @@
 
     case (initiator_state_q)
       IDLE: begin
-        if (clear_i) begin
+        if (clear_i || pending_clear_q) begin
           initiator_state_d = ISOLATE;
         end
       end
 
+      // Drain any pre-reset in-flight or stale 4-phase ACK while asserting
+      // RESET_MSG (CLEAR_PHASE_ISOLATE), then run a clean full ISOLATE phase
+      // so the peer is guaranteed isolated and acknowledged before CLEAR.
+      RESET_ISOLATE: begin
+        initiator_phase_transition_req = 1'b1;
+        initiator_clear_seq_phase      = CLEAR_PHASE_ISOLATE;
+        initiator_isolate_out          = 1'b1;
+        initiator_clear_out            = 1'b0;
+        if (initiator_phase_transition_ack) begin
+          initiator_state_d = ISOLATE;
+        end
+      end
+
       ISOLATE: begin
         initiator_phase_transition_req = 1'b1;
         initiator_clear_seq_phase      = CLEAR_PHASE_ISOLATE;
         initiator_isolate_out          = 1'b1;
         initiator_clear_out            = 1'b0;
-        if (initiator_phase_transition_ack && isolate_ack_i) begin
+        if (initiator_phase_transition_ack && eff_iso_ack) begin
           initiator_state_d = CLEAR;
         end else if (initiator_phase_transition_ack) begin
           initiator_state_d = WAIT_ISOLATE_ACK;
-        end else if (isolate_ack_i) begin
+        end else if (eff_iso_ack) begin
           initiator_state_d = WAIT_ISOLATE_PHASE_ACK;
         end
       end
@@ -294,7 +209,7 @@
         initiator_isolate_out     = 1'b1;
         initiator_clear_out       = 1'b0;
         initiator_clear_seq_phase = CLEAR_PHASE_ISOLATE;
-        if (isolate_ack_i) begin
+        if (eff_iso_ack) begin
           initiator_state_d = CLEAR;
         end
       end
@@ -314,11 +229,11 @@
         initiator_clear_out            = 1'b1;
         initiator_phase_transition_req = 1'b1;
         initiator_clear_seq_phase      = CLEAR_PHASE_CLEAR;
-        if (initiator_phase_transition_ack && clear_ack_i) begin
+        if (initiator_phase_transition_ack && eff_clr_ack) begin
           initiator_state_d = POST_CLEAR;
         end else if (initiator_phase_transition_ack) begin
           initiator_state_d = WAIT_CLEAR_ACK;
-        end else if (clear_ack_i) begin
+        end else if (eff_clr_ack) begin
           initiator_state_d = WAIT_CLEAR_PHASE_ACK;
         end
       end
@@ -327,7 +242,7 @@
         initiator_isolate_out     = 1'b1;
         initiator_clear_out       = 1'b1;
         initiator_clear_seq_phase = CLEAR_PHASE_CLEAR;
-        if (clear_ack_i) begin
+        if (eff_clr_ack) begin
           initiator_state_d = POST_CLEAR;
         end
       end
@@ -368,11 +283,10 @@
     endcase
   end
 
-  always_ff @(posedge clk_i, negedge rst_ni) begin
+  always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
       if (CLEAR_ON_ASYNC_RESET) begin
-        initiator_state_q <= ISOLATE; // Start in the ISOLATE state which is
-                                        // the first state of a clear sequence.
+        initiator_state_q <= RESET_ISOLATE;
       end else begin
         initiator_state_q <= IDLE;
       end
@@ -381,61 +295,46 @@
     end
   end
 
-  // Initiator CDC SRC
-  // We use 4 phase handshaking. That way it doesn't matter if one side is
-  // sudenly reset asynchronously. With a 2phase CDC, one-sided async resets might
-  // introduce spurios transactions.
-
   cdc_4phase_src #(
-    .T(clear_seq_phase_e),
-    .SYNC_STAGES(2),
-    .DECOUPLED(0), // Important! The CDC must not be in decoupled mode.
-                   // Otherwise we will proceed to the next state without
-                   // waiting for the new state to arrive on the other side.
-    .SEND_RESET_MSG(CLEAR_ON_ASYNC_RESET), // Send the ISOLATE phase request immediately on async
-                                           // reset if async reset synchronization is enabled.
-    .RESET_MSG(CLEAR_PHASE_ISOLATE)
-  ) i_state_transition_cdc_src(
+    .T              ( clear_seq_phase_e    ),
+    .SYNC_STAGES    ( SYNC_STAGES          ),
+    .DECOUPLED      ( 1'b0                 ),
+    .SEND_RESET_MSG ( CLEAR_ON_ASYNC_RESET ),
+    .RESET_MSG      ( CLEAR_PHASE_ISOLATE  )
+  ) i_state_transition_cdc_src (
     .clk_i,
     .rst_ni,
-    .data_i(initiator_clear_seq_phase),
-    .valid_i(initiator_phase_transition_req),
-    .ready_o(initiator_phase_transition_ack),
+    .data_i       ( initiator_clear_seq_phase      ),
+    .valid_i      ( initiator_phase_transition_req ),
+    .ready_o      ( initiator_phase_transition_ack ),
     .async_req_o,
     .async_ack_i,
-    .async_data_o(async_next_phase_o)
+    .async_data_o ( async_next_phase_o             )
   );
 
-
   //---------------------- Receiver Side ----------------------
-  // This part of the circuit receives clear sequence state transitions from the
-  // other side.
-
   clear_seq_phase_e receiver_phase_q;
   clear_seq_phase_e receiver_next_phase;
-  logic receiver_phase_req, receiver_phase_ack;
-
-  logic receiver_isolate_out;
-  logic receiver_clear_out;
+  logic             receiver_phase_req, receiver_phase_ack;
+  logic             receiver_isolate_out;
+  logic             receiver_clear_out;
 
   cdc_4phase_dst #(
-    .T(clear_seq_phase_e),
-    .SYNC_STAGES(2),
-    .DECOUPLED(0) // Important! The CDC must not be in decoupled mode. Otherwise
-                  // we will proceed to the next state without waiting for the
-                  // new state to arrive on the other side.
-  ) i_state_transition_cdc_dst(
+    .T           ( clear_seq_phase_e ),
+    .SYNC_STAGES ( SYNC_STAGES       ),
+    .DECOUPLED   ( 1'b0              )
+  ) i_state_transition_cdc_dst (
     .clk_i,
     .rst_ni,
-    .data_o(receiver_next_phase),
-    .valid_o(receiver_phase_req),
-    .ready_i(receiver_phase_ack),
+    .data_o       ( receiver_next_phase ),
+    .valid_o      ( receiver_phase_req  ),
+    .ready_i      ( receiver_phase_ack  ),
     .async_req_i,
     .async_ack_o,
-    .async_data_i(async_next_phase_i)
+    .async_data_i ( async_next_phase_i  )
   );
 
-  always_ff @(posedge clk_i, negedge rst_ni) begin
+  always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
       receiver_phase_q <= CLEAR_PHASE_IDLE;
     end else if (receiver_phase_req && receiver_phase_ack) begin
@@ -448,7 +347,6 @@
     receiver_clear_out   = 1'b0;
     receiver_phase_ack   = 1'b0;
 
-    // If there is a new phase requestd, checkout which one it is and act accordingly
     if (receiver_phase_req) begin
       case (receiver_next_phase)
         CLEAR_PHASE_IDLE: begin
@@ -460,15 +358,18 @@
         CLEAR_PHASE_ISOLATE: begin
           receiver_clear_out   = 1'b0;
           receiver_isolate_out = 1'b1;
-          // Wait for the isolate to be acknowledged before ack'ing the phase
-          receiver_phase_ack = isolate_ack_i;
+          receiver_phase_ack   = eff_iso_ack;
         end
 
         CLEAR_PHASE_CLEAR: begin
-          receiver_clear_out   = 1'b1;
-          receiver_isolate_out = 1'b1;
-          // Wait for the clear to be acknowledged before ack'ing the phase
-          receiver_phase_ack   = clear_ack_i;
+          receiver_isolate_out = 1'b1;
+          if (iso_ack_seen_q) begin
+            receiver_clear_out = 1'b1;
+            receiver_phase_ack = eff_clr_ack;
+          end else begin
+            receiver_clear_out = 1'b0;
+            receiver_phase_ack = 1'b0;
+          end
         end
 
         CLEAR_PHASE_POST_CLEAR: begin
@@ -483,10 +384,7 @@
           receiver_phase_ack   = 1'b0;
         end
       endcase
-
     end else begin
-      // No phase change is requested for the moment. Act according to the
-      // current phase signal
       case (receiver_phase_q)
         CLEAR_PHASE_IDLE: begin
           receiver_clear_out   = 1'b0;
@@ -499,8 +397,8 @@
         end
 
         CLEAR_PHASE_CLEAR: begin
-          receiver_clear_out   = 1'b1;
-          receiver_isolate_out = 1'b1;
+          receiver_isolate_out = 1'b1;
+          receiver_clear_out   = iso_ack_seen_q;
         end
 
         CLEAR_PHASE_POST_CLEAR: begin
@@ -511,19 +409,12 @@
         default: begin
           receiver_clear_out   = 1'b0;
           receiver_isolate_out = 1'b0;
-          receiver_phase_ack   = 1'b0;
         end
       endcase
     end
   end
 
-  // Output Assignment
-
-  // The clear and isolate signal are the OR combination of the receiver and
-  // initiator's clear/isolate signal. This ensures that the correct sequence is
-  // followed even if both sides are cleared independently at roughly the same
-  // time.
-  assign clear_o = initiator_clear_out || receiver_clear_out;
+  assign clear_o   = initiator_clear_out   || receiver_clear_out;
   assign isolate_o = initiator_isolate_out || receiver_isolate_out;
 
 endmodule : cdc_reset_ctrlr_half

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/cdc_4phase.sv`](environment/public/code/cdc_4phase.sv) *(Read-Only Context)*
- [`environment/public/code/cdc_reset_ctrlr.sv`](environment/public/code/cdc_reset_ctrlr.sv) **(Editable)**
- [`environment/public/code/cdc_reset_ctrlr_pkg.sv`](environment/public/code/cdc_reset_ctrlr_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/assertions.svh`](environment/public/code/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/sync.sv`](environment/public/code/sync.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

