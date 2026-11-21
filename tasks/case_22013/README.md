# `case_22013`: Resolve Ara VLSU Unaligned 4KB/Max-Burst Splitting, Non-Zero vstart Lane Rotation, and Scatter/Gather Memory Ordering

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22013` |
| **Source Silicon Repository** | `pulp-platform/ara` (`repo_19`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/vlsu.sv`](environment/public/code/vlsu.sv), [`code/addrgen.sv`](environment/public/code/addrgen.sv), [`code/vldu.sv`](environment/public/code/vldu.sv), [`code/vstu.sv`](environment/public/code/vstu.sv) (4 files, 2751 LOC) |
| **Public Subsystem Context** | 34 RTL files (11227 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `900s` total (`450s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Ara VLSU Unaligned Burst Splitting, Non-Zero `vstart` Alignment, and Memory Ordering

## Context
`vlsu` (`code/vlsu.sv`, integrating `code/addrgen.sv`, `code/vldu.sv`, and `code/vstu.sv`) is the RVV 1.0 Load-Store Unit in PULP Ara (`NrLanes = 4` 64-bit lanes). It executes unit-stride (`VLE`, `VSE`), strided (`VLSE`, `VSSE`), and indexed (`VLXE`, `VSXE`) vector memory instructions across `EW8`–`EW64`, issuing AXI4 bursts (`axi_req_o` / `axi_resp_i` across parameterized `AxiDataWidth`), steering bytes between the AXI data bus and lane-interleaved VRF banks, and signaling completion (`pe_resp_o`, `load_complete_o`, `store_complete_o`, `store_pending_o`) and address exceptions (`addrgen_exception_o`, `addrgen_exception_vstart_o`).

## Observed Failures
Subsystem verification under AXI4 protocol monitoring and randomized AR/R/AW/W/B channel backpressure exposes three failure groups:

1. **Unaligned 4 KiB Page-Boundary and Max-Burst Splitting**:
   - Unit-stride transfers starting at unaligned byte addresses violate AXI4 `INCR` burst rules or miscompute split burst beat counts near 4 KiB (`0x1000`) boundaries and the 256-beat (`ARLEN` / `AWLEN <= 255`) burst limit, truncating tail bytes or deadlocking beat consumers.

2. **Non-Zero `vstart`, Unaligned Base Offset, and Masked Lane Steering**:
   - Vector loads and stores with `vstart > 0`, unaligned AXI base addresses, masked execution (`vm = 0`), short transfers wrapping across consecutive VRF words, or back-to-back pipelined instructions drop active elements, misrotate lanes, or retire before all VRF writeback grants finish. Prestart (`idx < vstart`), tail (`idx >= vl`), and masked-off (`vm = 0`) elements must remain unmodified in both VRF and memory.

3. **Multi-Burst Store Completion and Scatter/Gather RAW/WAR Ordering**:
   - Multi-burst vector stores assert `store_complete_o` / `pe_resp_o.vinsn_done` and deassert `store_pending_o` before all bursts of the instruction have been transmitted and acknowledged on `B`.
   - Back-to-back overlapping store-then-load (RAW) and load-then-store (WAR) sequences across unit-stride and indexed (`VLXE` / `VSXE`) instructions reorder across uncommitted bursts under asymmetric AXI channel delays, returning stale or overwritten data.
   - Indexed `VLXE` / `VSXE` instructions with `eew_vs2 != vtype.vsew`, back-to-back queued indexed ops under stall, or misaligned active indexed addresses (`vstart >= 0`) misalign lane offset consumption or report an incorrect faulting element index on `addrgen_exception_vstart_o`.

## Requirements
- Modify only `code/vlsu.sv`, `code/addrgen.sv`, `code/vldu.sv`, and `code/vstu.sv`, keeping all package headers, primitives, and `vlsu` top-level ports unchanged.
- Preserve clean, latch-free synthesis (`yosys -m slang`) and exact functional behavior across parameterized `AxiDataWidth` (`64` and `128`).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Guide

## Editable Files

Only the following RTL files are collected for grading:

- `code/vlsu.sv`
- `code/addrgen.sv`
- `code/vldu.sv`
- `code/vstu.sv`

All supporting packages and primitives in `code/` (`ara_pkg.sv`, `rvv_pkg.sv`, `axi_pkg.sv`, `axi_cut.sv`, `fifo_v3.sv`, `spill_register*.sv`, `stream_*.sv`, and `code/include/...`) are read-only reference dependencies.

## Available Toolchain

- **Verilator 5.038**: `verilator`
- **Yosys + slang**: `yosys` (`-m slang`)

## Compilation Order (`Verilator` & `yosys -m slang`)

Compile packages prior to RTL modules with `-Icode/include`:

```bash
verilator \
  --lint-only -Wno-fatal -DSYNTHESIS -Icode/include \
  code/cf_math_pkg.sv \
  code/riscv_pkg.sv \
  code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv \
  code/axi_pkg.sv \
  code/fpnew_pkg.sv \
  code/rvv_pkg.sv \
  code/ara_pkg.sv \
  code/build_config_pkg.sv \
  code/lzc.sv \
  code/onehot_to_bin.sv \
  code/rr_arb_tree.sv \
  code/fifo_v3.sv \
  code/spill_register_flushable.sv \
  code/spill_register.sv \
  code/fall_through_register.sv \
  code/stream_arbiter_flushable.sv \
  code/stream_arbiter.sv \
  code/stream_mux.sv \
  code/stream_demux.sv \
  code/stream_xbar.sv \
  code/counter.sv \
  code/delta_counter.sv \
  code/axi_cut.sv \
  code/addrgen.sv \
  code/vldu.sv \
  code/vstu.sv \
  code/vlsu.sv \
  --top-module vlsu
```

To check synthesis elaboration and verify zero inferred latches with `yosys -m slang` (instantiating `vlsu` with concrete `AxiAddrWidth = 64`, `AxiDataWidth = 128` or `64`, `NrLanes = 4`, `VLEN = 4096`):

```bash
yosys -m slang -p "
  read_slang --top <your_vlsu_wrapper> --ignore-assertions --ignore-timing --ignore-initial \
    -I code/include \
    code/cf_math_pkg.sv code/riscv_pkg.sv code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv code/axi_pkg.sv code/fpnew_pkg.sv \
    code/rvv_pkg.sv code/ara_pkg.sv code/build_config_pkg.sv \
    code/lzc.sv code/onehot_to_bin.sv code/rr_arb_tree.sv code/fifo_v3.sv \
    code/spill_register_flushable.sv code/spill_register.sv code/fall_through_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_mux.sv \
    code/stream_demux.sv code/stream_xbar.sv code/counter.sv code/delta_counter.sv \
    code/axi_cut.sv code/addrgen.sv code/vldu.sv code/vstu.sv code/vlsu.sv <your_vlsu_wrapper.sv>;
  hierarchy -check -top <your_vlsu_wrapper>;
  proc; opt_expr; opt_clean; check -assert; stat
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/vlsu.sv (Buggy Starter)
+++ b/solution/gold/code/vlsu.sv (Golden Reference)
@@ -142,6 +142,40 @@
     .slv_resp_o(axi_resp  )
   );
 
+  // Track outstanding AXI read (AR -> R.last) and write (AW -> B) bursts
+  // across the internal/external cut boundary to enforce RAW/WAR ordering.
+  logic [15:0] ar_inflight_cnt_d, ar_inflight_cnt_q;
+  logic [15:0] aw_inflight_cnt_d, aw_inflight_cnt_q;
+  logic        load_in_flight, store_in_flight;
+
+  always_comb begin
+    automatic logic ar_push = axi_req.ar_valid && axi_resp.ar_ready;
+    automatic logic r_pop   = axi_resp.r_valid && axi_req.r_ready && axi_resp.r.last;
+    automatic logic aw_push = axi_req.aw_valid && axi_resp.aw_ready;
+    automatic logic b_pop   = axi_resp.b_valid && axi_req.b_ready;
+
+    ar_inflight_cnt_d = ar_inflight_cnt_q;
+    if (ar_push && !r_pop)       ar_inflight_cnt_d = ar_inflight_cnt_q + 16'd1;
+    else if (!ar_push && r_pop)  ar_inflight_cnt_d = ar_inflight_cnt_q - 16'd1;
+
+    aw_inflight_cnt_d = aw_inflight_cnt_q;
+    if (aw_push && !b_pop)       aw_inflight_cnt_d = aw_inflight_cnt_q + 16'd1;
+    else if (!aw_push && b_pop)  aw_inflight_cnt_d = aw_inflight_cnt_q - 16'd1;
+  end
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      ar_inflight_cnt_q <= '0;
+      aw_inflight_cnt_q <= '0;
+    end else begin
+      ar_inflight_cnt_q <= ar_inflight_cnt_d;
+      aw_inflight_cnt_q <= aw_inflight_cnt_d;
+    end
+  end
+
+  assign load_in_flight  = (ar_inflight_cnt_q != '0);
+  assign store_in_flight = (aw_inflight_cnt_q != '0) || store_pending_o;
+
   //////////////////////////
   //  Address Generation  //
   //////////////////////////
@@ -175,6 +209,8 @@
     .axi_ar_ready_i             (axi_resp.ar_ready          ),
     // Interface with dispatcher
     .core_st_pending_i          (core_st_pending_i          ),
+    .load_in_flight_i           (load_in_flight             ),
+    .store_in_flight_i          (store_in_flight            ),
     // Interface with the sequencer
     .pe_req_i                   (pe_req_i                   ),
     .pe_req_valid_i             (pe_req_valid_i             ),

--- a/environment/public/code/addrgen.sv (Buggy Starter)
+++ b/solution/gold/code/addrgen.sv (Golden Reference)
@@ -51,6 +51,8 @@
     input  exception_t                     mmu_exception_i,  // address translation threw an exception
     // Interace with the dispatcher
     input  logic                           core_st_pending_i,
+    input  logic                           load_in_flight_i,
+    input  logic                           store_in_flight_i,
     // Interface with the main sequencer
     input  pe_req_t                        pe_req_i,
     input  logic                           pe_req_valid_i,
@@ -427,7 +429,7 @@
           // - We are left with less byte than the maximim to issue,
           //    this means that at least one lane is not going to push us any operand anymore
           // - For the lanes which index % NrLanes != 0
-          if (((idx_op_cnt_q << pe_req_q.vtype.vsew) < (NrLanes * DataWidthB))
+          if (((idx_op_cnt_q << unsigned'(pe_req_q.eew_vs2)) < (NrLanes * DataWidthB))
                && (lane < pe_req_q.vstart[idx_width(NrLanes)-1:0])) begin : vstart_lane_adjust
             addrgen_operand_valid[lane] |= 1'b1;
           end : vstart_lane_adjust
@@ -435,9 +437,7 @@
         // TODO: apply the same vstart logic also to mask_valid_i
 
         // Handle handshake and data between VRF and spill register
-        // We accept all the incoming data, without any checks
-        // since Ara stalls on an indexed memory operation
-        if (&addrgen_operand_valid) begin
+        if (&addrgen_operand_valid && (idx_op_cnt_q != '0)) begin
 
           // Valid data for the spill register
           idx_vaddr_valid_d = 1'b1;
@@ -478,8 +478,10 @@
           if (idx_vaddr_ready_q) begin
             // Consumed one element
             idx_op_cnt_d = idx_op_cnt_q - 1;
-            // Have we finished a full NrLanes*64b word?
-            if (elm_ptr_q == last_elm_subw_q) begin
+            if (idx_op_cnt_d == '0) begin
+              // Give a ready to the lanes when the final element of the instruction is consumed
+              addrgen_operand_ready_o = 1'b1;
+            end else if (elm_ptr_q == last_elm_subw_q) begin
               // Bump lane pointer
               elm_ptr_d       = '0;
               word_lane_ptr_d += 1;
@@ -491,11 +493,6 @@
               // Bump element pointer
               elm_ptr_d += 1;
             end
-          end
-
-          if (idx_op_cnt_d == '0) begin
-            // Give a ready to the lanes if this was not done before
-            addrgen_operand_ready_o = 1'b1;
           end
         end
 
@@ -653,10 +650,13 @@
   );
 
     automatic int unsigned max_burst_bytes = 256 << eff_axi_dw_log;
-
-    // The final address can be found similarly...
-    if (num_bytes >= max_burst_bytes) begin
-        aligned_next_start_addr = aligned_addr(addr + max_burst_bytes, eff_axi_dw_log);
+    automatic axi_addr_t   start_offset    = addr - aligned_start_addr;
+
+    // Account for unaligned start_offset so a burst never spans > 256 beats
+    if (num_bytes == '0) begin
+        aligned_next_start_addr = aligned_start_addr;
+    end else if ((32'(num_bytes) + 32'(start_offset[clog2_AxiStrobeWidth:0])) >= max_burst_bytes) begin
+        aligned_next_start_addr = aligned_start_addr + max_burst_bytes;
     end else begin
         aligned_next_start_addr = aligned_addr(addr + num_bytes - 1, eff_axi_dw_log) + eff_axi_dw;
     end
@@ -832,8 +832,10 @@
         // Otherwise, the ordering of the responses is not guaranteed, and with the current
         // implementation we can incur in deadlocks
         // NOTE: this might be referring to an obsolete axi_cut implementation
-        if (axi_addrgen_queue_empty || (axi_addrgen_req_o.is_load && axi_addrgen_q.is_load) ||
-             (~axi_addrgen_req_o.is_load && ~axi_addrgen_q.is_load)) begin : axi_ax_idle
+        if ((axi_addrgen_q.is_load && !store_in_flight_i &&
+             (axi_addrgen_queue_empty || axi_addrgen_req_o.is_load)) ||
+            (!axi_addrgen_q.is_load && !load_in_flight_i &&
+             (axi_addrgen_queue_empty || !axi_addrgen_req_o.is_load))) begin : axi_ax_idle
           if (!axi_addrgen_queue_full && axi_ax_ready) begin : start_req
             automatic logic [CVA6Cfg.PLEN-1:0] paddr;
 
@@ -970,7 +972,7 @@
                   // Generate an error
                   idx_op_error_d          = 1'b1;
                   // Forward next vstart info to the dispatcher
-                  addrgen_exception_vstart_d  = (addrgen_req.len - axi_addrgen_q.len) >> axi_addrgen_q.vew - 1;
+                  addrgen_exception_vstart_d  = pe_req_q.vl - (axi_addrgen_q.len >> axi_addrgen_q.vew);
                   addrgen_req_ready       = 1'b1;
                   axi_addrgen_state_d     = AXI_ADDRGEN_IDLE;
                 end : eew_misaligned_error

--- a/environment/public/code/vldu.sv (Buggy Starter)
+++ b/solution/gold/code/vldu.sv (Golden Reference)
@@ -290,6 +290,7 @@
     seq_word_wr_offset_d = seq_word_wr_offset_q;
     first_payload_byte_d = first_payload_byte_q;
     vrf_word_byte_cnt_d  = vrf_word_byte_cnt_q;
+    vrf_word_start_byte  = '0;
 
     // Vector instructions currently running
     vinsn_running_d = vinsn_running_q & pe_vinsn_running_i;
@@ -347,8 +348,8 @@
 
         // How many bytes are we committing?
         automatic logic [idx_width(DataWidth*NrLanes/8):0] valid_bytes;
-        valid_bytes = (issue_cnt_bytes_q < (NrLanes * DataWidthB)) ? vinsn_valid_bytes : vrf_valid_bytes;
-        valid_bytes = (valid_bytes       < axi_valid_bytes       ) ? valid_bytes       : axi_valid_bytes;
+        valid_bytes = (vinsn_valid_bytes < vrf_valid_bytes) ? vinsn_valid_bytes : vrf_valid_bytes;
+        valid_bytes = (valid_bytes       < axi_valid_bytes) ? valid_bytes       : axi_valid_bytes;
 
         // Bump R beat and VRF word pointers
         axi_r_byte_pnt_d    = axi_r_byte_pnt_q + valid_bytes;
@@ -469,7 +470,8 @@
                                 - vinsn_queue_q.vinsn[vinsn_queue_d.issue_pnt].vstart
                               ) << unsigned'(vinsn_queue_q.vinsn[vinsn_queue_d.issue_pnt].vtype.vsew);
           // Prepare the VRF start pointer
-          vrf_word_start_byte  = vinsn_issue_d.vstart[$clog2(8*NrLanes)-1:0] << vinsn_issue_d.vtype.vsew;
+          vrf_word_start_byte  = vinsn_queue_q.vinsn[vinsn_queue_d.issue_pnt].vstart[$clog2(8*NrLanes)-1:0] <<
+            vinsn_queue_q.vinsn[vinsn_queue_d.issue_pnt].vtype.vsew;
           vrf_word_byte_pnt_d  = {1'b0, vrf_word_start_byte[$clog2(8*NrLanes)-1:0]};
           vrf_word_byte_cnt_d  = '0;
           seq_word_wr_offset_d = '0;
@@ -507,13 +509,15 @@
     res_queue_eff_write_bytes = (NrLanes * DataWidthB);
     // If vstart > 0, the first payload can contain less than (NrLanes * DataWidthB) Bytes
     if (first_result_queue_read_q) begin
-      res_queue_eff_write_bytes = first_payload_byte_q;
+      automatic logic [$clog2(8*NrLanes)-1:0] commit_start_byte;
+      commit_start_byte         = vinsn_commit.vstart[$clog2(8*NrLanes)-1:0] << vinsn_commit.vtype.vsew;
+      res_queue_eff_write_bytes = (NrLanes * DataWidthB) - commit_start_byte;
     end
 
     // All lanes accepted the VRF request
     // Wait for all the final grants, to be sure that all the results were written back
     if (!(|result_queue_valid_d[result_queue_read_pnt_q]) &&
-      (&result_final_gnt_d || commit_cnt_bytes_q > (NrLanes * DataWidthB))) begin : wait_for_write_back
+      (&result_final_gnt_d || commit_cnt_bytes_q > res_queue_eff_write_bytes)) begin : wait_for_write_back
       // There is something waiting to be written
       if (!result_queue_empty) begin : result_available
         // Increment the read pointer
@@ -532,7 +536,7 @@
 
         // Decrement the counter of remaining vector elements waiting to be written
         commit_cnt_bytes_d = commit_cnt_bytes_q - res_queue_eff_write_bytes;
-        if (commit_cnt_bytes_q < (NrLanes * DataWidthB)) begin : commit_cnt_bytes_overflow
+        if (commit_cnt_bytes_q < res_queue_eff_write_bytes) begin : commit_cnt_bytes_overflow
           commit_cnt_bytes_d = '0;
         end : commit_cnt_bytes_overflow
       end : result_available

--- a/environment/public/code/vstu.sv (Buggy Starter)
+++ b/solution/gold/code/vstu.sv (Golden Reference)
@@ -241,6 +241,10 @@
   // Signal that the current burst is having an exception
   logic stu_current_burst_exception_d;
 
+  // Per-instruction AXI burst & W-issue completion tracking for multi-burst B responses
+  vlen_t [VInsnQueueDepth-1:0] burst_rem_d, burst_rem_q;
+  logic  [VInsnQueueDepth-1:0] w_issue_done_d, w_issue_done_q;
+
   always_comb begin: p_vstu
     // NOTE: these are out here only for debug visibility, they could go in p_vldu as automatic variables
     vrf_seq_byte = '0;
@@ -276,6 +280,8 @@
 
     vrf_cnt_d = vrf_cnt_q;
     first_lane_payload_d = first_lane_payload_q;
+    burst_rem_d = burst_rem_q;
+    w_issue_done_d = w_issue_done_q;
 
     stu_current_burst_exception_d = 1'b0;
 
@@ -315,8 +321,8 @@
       // How many bytes are valid in this AXI word
       axi_valid_bytes   = upper_byte - lower_byte + 1;
 
-      valid_bytes = (issue_cnt_bytes_q < (NrLanes * DataWidthB)) ? vinsn_valid_bytes : vrf_valid_bytes;
-      valid_bytes = (valid_bytes       < axi_valid_bytes       ) ? valid_bytes       : axi_valid_bytes;
+      valid_bytes = (vinsn_valid_bytes < vrf_valid_bytes) ? vinsn_valid_bytes : vrf_valid_bytes;
+      valid_bytes = (valid_bytes       < axi_valid_bytes) ? valid_bytes       : axi_valid_bytes;
 
       // TODO: apply the same vstart logic also to mask_valid_q
       // For now, assume (vstart % NrLanes == 0)
@@ -363,6 +369,8 @@
           axi_addrgen_req_ready_o = 1'b1;
           // Reset AXI pointers
           axi_len_d                   = '0;
+          // Track completed W burst awaiting its B response
+          burst_rem_d[vinsn_queue_q.issue_pnt] = burst_rem_d[vinsn_queue_q.issue_pnt] + 1'b1;
         end : beats_complete
 
         // We consumed a whole word from the lanes
@@ -393,6 +401,7 @@
 
     // Finished issuing W beats for this vector store
     if (vinsn_issue_valid && issue_cnt_bytes_d == 0) begin : axi_w_beat_finish
+      w_issue_done_d[vinsn_queue_q.issue_pnt] = 1'b1;
       // Bump issue counters and pointers of the vector instruction queue
       vinsn_queue_d.issue_cnt -= 1;
       if (vinsn_queue_q.issue_pnt == VInsnQueueDepth-1) begin : issue_pnt_overflow
@@ -428,12 +437,18 @@
       // Acknowledge the B beat
       axi_b_ready_o = 1'b1;
 
-      // Mark the vector instruction as being done
-      if (vinsn_queue_d.issue_cnt != vinsn_queue_d.commit_cnt) begin : instr_done
+      if (vinsn_commit_valid && (burst_rem_d[vinsn_queue_q.commit_pnt] != '0)) begin
+        burst_rem_d[vinsn_queue_q.commit_pnt] = burst_rem_d[vinsn_queue_q.commit_pnt] - 1'b1;
+      end
+
+      // Mark the vector instruction as being done only after all W bursts and B beats complete
+      if (vinsn_commit_valid && w_issue_done_d[vinsn_queue_q.commit_pnt] &&
+          (burst_rem_d[vinsn_queue_q.commit_pnt] == '0)) begin : instr_done
         // Signal complete store
         store_complete_o = 1'b1;
 
         pe_resp_d.vinsn_done[vinsn_commit.id] = 1'b1;
+        w_issue_done_d[vinsn_queue_q.commit_pnt] = 1'b0;
 
         // Update the commit counters and pointers
         vinsn_queue_d.commit_cnt -= 1;
@@ -456,6 +471,7 @@
       // Bump issue counters and pointers of the vector instruction queue
       vinsn_queue_d.issue_cnt -= 1;
       issue_cnt_bytes_d = '0;
+      w_issue_done_d[vinsn_queue_q.issue_pnt] = 1'b1;
       if (vinsn_queue_q.issue_pnt == VInsnQueueDepth-1) begin : issue_pnt_overflow
         vinsn_queue_d.issue_pnt = 0;
       end : issue_pnt_overflow
@@ -471,20 +487,20 @@
       // Abort the main sequencer -> operand-req request
       stu_current_burst_exception_d = 1'b1;
 
-      // Mark the vector instruction as being done
-      // Signal done to sequencer
-      store_complete_o = 1'b1;
-
-      pe_resp_d.vinsn_done[vinsn_commit.id] = 1'b1;
-
-      // Update the commit counters and pointers
-      vinsn_queue_d.commit_cnt -= 1;
-      if (vinsn_queue_d.commit_pnt == VInsnQueueDepth-1) begin : commit_pnt_overflow
-        vinsn_queue_d.commit_pnt = '0;
-      end : commit_pnt_overflow
-      else begin : commit_pnt_increment
-        vinsn_queue_d.commit_pnt += 1;
-      end : commit_pnt_increment
+      // Retire commit immediately only if no prior W bursts of this instruction await B responses
+      if (burst_rem_d[vinsn_queue_q.commit_pnt] == '0) begin
+        w_issue_done_d[vinsn_queue_q.commit_pnt] = 1'b0;
+        store_complete_o = 1'b1;
+        pe_resp_d.vinsn_done[vinsn_commit.id] = 1'b1;
+
+        vinsn_queue_d.commit_cnt -= 1;
+        if (vinsn_queue_d.commit_pnt == VInsnQueueDepth-1) begin : commit_pnt_overflow
+          vinsn_queue_d.commit_pnt = '0;
+        end : commit_pnt_overflow
+        else begin : commit_pnt_increment
+          vinsn_queue_d.commit_pnt += 1;
+        end : commit_pnt_increment
+      end
     end : exception
 
     //////////////////////////////
@@ -495,6 +511,8 @@
       pe_req_i.vfu == VFU_StoreUnit) begin : pe_req_valid
       vinsn_queue_d.vinsn[vinsn_queue_q.accept_pnt] = pe_req_i;
       vinsn_running_d[pe_req_i.id]                  = 1'b1;
+      burst_rem_d[vinsn_queue_q.accept_pnt]         = '0;
+      w_issue_done_d[vinsn_queue_q.accept_pnt]      = 1'b0;
 
       // Initialize counters
       if (vinsn_queue_d.issue_cnt == '0) begin : issue_cnt_bytes_init
@@ -537,6 +555,8 @@
       lsu_ex_flush_q <= 1'b0;
 
       stu_current_burst_exception_o <= 1'b0;
+      burst_rem_q                   <= '0;
+      w_issue_done_q                <= '0;
     end else begin
       vinsn_running_q   <= vinsn_running_d;
       issue_cnt_bytes_q <= issue_cnt_bytes_d;
@@ -554,6 +574,8 @@
       lsu_ex_flush_q <= lsu_ex_flush_i;
 
       stu_current_burst_exception_o <= stu_current_burst_exception_d;
+      burst_rem_q                   <= burst_rem_d;
+      w_issue_done_q                <= w_issue_done_d;
     end
   end
 

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/addrgen.sv`](environment/public/code/addrgen.sv) **(Editable)**
- [`environment/public/code/ara_pkg.sv`](environment/public/code/ara_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_cut.sv`](environment/public/code/axi_cut.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/build_config_pkg.sv`](environment/public/code/build_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/counter.sv`](environment/public/code/counter.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv`](environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/delta_counter.sv`](environment/public/code/delta_counter.sv) *(Read-Only Context)*
- [`environment/public/code/fall_through_register.sv`](environment/public/code/fall_through_register.sv) *(Read-Only Context)*
- [`environment/public/code/fifo_v3.sv`](environment/public/code/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/include/ara/ara_typedef.svh`](environment/public/code/include/ara/ara_typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/ara/intf_typedef.svh`](environment/public/code/include/ara/intf_typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/axi/assign.svh`](environment/public/code/include/axi/assign.svh) *(Read-Only Context)*
- [`environment/public/code/include/axi/typedef.svh`](environment/public/code/include/axi/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/onehot_to_bin.sv`](environment/public/code/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/rvv_pkg.sv`](environment/public/code/rvv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter.sv`](environment/public/code/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter_flushable.sv`](environment/public/code/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_demux.sv`](environment/public/code/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_mux.sv`](environment/public/code/stream_mux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_xbar.sv`](environment/public/code/stream_xbar.sv) *(Read-Only Context)*
- [`environment/public/code/vldu.sv`](environment/public/code/vldu.sv) **(Editable)**
- [`environment/public/code/vlsu.sv`](environment/public/code/vlsu.sv) **(Editable)**
- [`environment/public/code/vstu.sv`](environment/public/code/vstu.sv) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

