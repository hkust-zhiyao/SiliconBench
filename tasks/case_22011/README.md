# `case_22011`: RVV 1.0 Unit-Stride and Strided Segmented Load/Store Support in Ara

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22011` |
| **Source Silicon Repository** | `pulp-platform/ara` (`repo_19`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/ara_dispatcher.sv`](environment/public/code/ara_dispatcher.sv), [`code/segment_sequencer.sv`](environment/public/code/segment_sequencer.sv) (2 files, 4044 LOC) |
| **Public Subsystem Context** | 38 RTL files (16013 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# RVV 1.0 Unit-Stride and Strided Segmented Load/Store Support in Ara

## Architectural Context

In PULP Ara (`SegSupport = SegSupportEnable`), scalar/accelerator instructions arrive at `code/ara_dispatcher.sv`, which decodes RVV 1.0 instructions, checks architectural legality, manages per-register effective element width (`EEW`) reshuffling, and forwards vector requests through `code/segment_sequencer.sv` to `ara_sequencer` and `vlsu`.

Currently, Ara's segment offload path is incomplete across `code/ara_dispatcher.sv` and `code/segment_sequencer.sv` for RVV 1.0 unit-stride (`vlseg<nf>e<eew>.v`, `vsseg<nf>e<eew>.v`, `vlseg<nf>e<eew>ff.v`) and strided (`vlsseg<nf>e<eew>.v`, `vssseg<nf>e<eew>.v`) segmented memory operations (`2 <= NFIELDS <= 8`, encoded as `nf = NFIELDS - 1` in `1..7`).

## Functional Requirements

1. **Decoding, `EMUL * NFIELDS` Legality, & Overlap Trapping (`ara_dispatcher.sv`)**:
   - Decode unit-stride, fault-only-first, and byte-strided segmented loads and stores across `EEW` in `{EW8, EW16, EW32, EW64}` and fractional/integer `LMUL`.
   - Compute effective `EMUL = (EEW / SEW) * LMUL` and reject illegal encodings on `acc_resp_o` (`ILLEGAL_INSTR`, without issuing backend micro-ops): invalid `EEW`, `EMUL < 1/8` or `EMUL > 8`, `EMUL * NFIELDS > 8`, misaligned register-group base (`rd % max(1, EMUL) != 0`), register wrap past `v31` (`rd + NFIELDS * max(1, EMUL) > 32`), fault-only-first stores, and masked segment loads whose destination register range `[rd .. rd + NFIELDS * max(1, EMUL) - 1]` overlaps `v0` (`vm == 0`).
2. **AoS-to-SoA Micro-Op Decomposition & `EEW` Tracking (`segment_sequencer.sv` + `ara_dispatcher.sv`)**:
   - For `0 <= vstart < vl`, transpose memory segments into `NFIELDS` consecutive vector register groups `reg_group(f) = base_reg + f * max(1, EMUL)` (`0 <= f < NFIELDS`).
   - Element `i` (`vstart <= i < vl`), field `f` accesses memory address `rs1 + i * seg_stride + f * (EEW / 8)`, where `seg_stride = NFIELDS * (EEW / 8)` for unit-stride ops and `seg_stride = rs2` (signed byte stride, including zero or negative strides) for strided ops.
   - Zero-trip operations (`vl == 0` or `vstart >= vl`) retire cleanly without memory accesses or exceptions.
   - Maintain per-register `EEW` state and trigger VRF reshuffling across all `NFIELDS * max(1, EMUL)` registers of a segmented load/store whenever prior register `EEW`s differ, ensuring segmented store micro-ops carry the true `old_eew_vs1` of each field register.
3. **Completion Accounting & Memory Exceptions**:
   - Drain in-flight backend state before retiring a segmented operation, pulsing `load_complete_o` / `store_complete_o` once per retired architectural segment instruction (while passing non-segment instructions through transparently).
   - On an address/MMU exception at element `i_fault`: stop issuing subsequent micro-ops, drain in-flight operations, and report `exception_vstart = i_fault` on standard loads/stores; for fault-only-first (`vlseg*ff.v`), trap only when `i_fault == 0`, and when `i_fault > 0` suppress the trap and trim architectural `vl` to `i_fault`.

## Deliverable Constraints

- Modify **only** `code/ara_dispatcher.sv` and `code/segment_sequencer.sv`; preserve all module names, parameters, and port signatures.
- All RTL must be strictly synthesizable (`yosys -m slang` clean elaboration with zero inferred latches).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Elaboration Guide

## Toolchain Paths
- **Verilator**: `verilator`
- **Yosys (+ slang)**: `yosys`

## Editable RTL
- `code/ara_dispatcher.sv`
- `code/segment_sequencer.sv`

## Compile Order (`-Icode/include`)
```bash
RTL_SRCS=(
  code/config_pkg.sv
  code/cv64a6_imafdcv_sv39_config_pkg.sv
  code/build_config_pkg.sv
  code/riscv_pkg.sv
  code/cf_math_pkg.sv
  code/axi_pkg.sv
  code/fpnew_pkg.sv
  code/rvv_pkg.sv
  code/ara_pkg.sv
  code/onehot_to_bin.sv
  code/lzc.sv
  code/popcount.sv
  code/counter.sv
  code/delta_counter.sv
  code/fall_through_register.sv
  code/spill_register_flushable.sv
  code/spill_register.sv
  code/fifo_v3.sv
  code/rr_arb_tree.sv
  code/stream_arbiter_flushable.sv
  code/stream_arbiter.sv
  code/stream_demux.sv
  code/stream_mux.sv
  code/stream_xbar.sv
  code/axi_cut.sv
  code/segment_sequencer.sv
  code/ara_dispatcher.sv
  code/ara_sequencer.sv
  code/vlsu/addrgen.sv
  code/vlsu/vldu.sv
  code/vlsu/vstu.sv
  code/vlsu/vlsu.sv
)
```

### Verilator Lint / Elaboration Check
```bash
verilator \
  --lint-only -Wno-fatal -Icode/include --top-module ara_dispatcher "${RTL_SRCS[@]}"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ara_dispatcher.sv (Buggy Starter)
+++ b/solution/gold/code/ara_dispatcher.sv (Golden Reference)
@@ -136,7 +136,7 @@
   //  Backend interface  //
   /////////////////////////
 
-  ara_req_t ara_req, ara_req_d;
+  ara_req_t ara_req, ara_req_seg_d, ara_req_d;
   logic     ara_req_valid, ara_req_valid_d;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
@@ -283,6 +283,7 @@
   // Decompose the segment memory operations into non-segment memory operations
   // This is a low-impact and low-performance implementation
   logic is_segment_mem_op;
+  logic is_seg_mem_candidate;
   logic illegal_insn;
 
   // The handshake signals are just passed-through if the insn is non-segment
@@ -298,7 +299,7 @@
     .rst_ni(rst_ni),
     .ara_idle_i(ara_idle_i),
     .is_segment_mem_op_i(is_segment_mem_op),
-    .illegal_insn_i(illegal_insn),
+    .illegal_insn_i(illegal_insn | illegal_insn_load | illegal_insn_store),
     .is_vload_i(is_vload),
     .seg_mem_op_end_o(seg_mem_op_end),
     .load_complete_i(load_complete_i),
@@ -306,7 +307,7 @@
     .store_complete_i(store_complete_i),
     .store_complete_o(store_complete),
     .ara_req_i(ara_req),
-    .ara_req_o(ara_req_d),
+    .ara_req_o(ara_req_seg_d),
     .ara_req_valid_i(ara_req_valid),
     .ara_req_valid_o(ara_req_valid_d),
     .ara_req_ready_i(ara_req_ready_i),
@@ -315,6 +316,13 @@
     .ara_resp_valid_i(ara_resp_valid_i),
     .ara_resp_valid_o(ara_resp_valid)
   );
+
+  always_comb begin
+    ara_req_d = ara_req_seg_d;
+    if (is_store(ara_req_seg_d.op)) begin
+      ara_req_d.old_eew_vs1 = eew_q[ara_req_seg_d.vs1];
+    end
+  end
 
   // LSU exception flush FSM
   // Upon exception, Ara should be flushed as soon as no operations older than the store are ongoing.
@@ -417,7 +425,8 @@
     is_decoding     = 1'b0;
     in_lane_op      = 1'b0;
 
-    is_segment_mem_op = 1'b0;
+    is_segment_mem_op    = 1'b0;
+    is_seg_mem_candidate = 1'b0;
 
     acc_resp_o       = '{
       trans_id      : acc_req_i.trans_id,
@@ -548,12 +557,17 @@
                 vs_buffer_d      = insn.varith_type.rs2;
               end
               3'b100: begin
-                eew_old_buffer_d = eew_q[insn.vmem_type.rs1];
+                eew_old_buffer_d = is_vstore ? eew_q[insn.vmem_type.rd] : eew_q[insn.vmem_type.rs1];
                 eew_new_buffer_d = reshuffle_eew_vs1_q;
-                vs_buffer_d      = insn.varith_type.rs1;
+                vs_buffer_d      = is_vstore ? insn.vmem_type.rd : insn.varith_type.rs1;
               end
               default:;
             endcase
+
+            if (reshuffle_req_d != 3'b0 &&
+                ((eew_new_buffer_d == eew_old_buffer_d) || !eew_valid_q[vs_buffer_d])) begin
+              rs_mask_request_d = 1'b1;
+            end
 
             if (reshuffle_req_d == 3'b0) begin
               // If LMUL_X has X > 1, Ara can inject different reshuffle ops during RESHUFFLE,
@@ -566,7 +580,7 @@
               // we just wait until the reshuffle is over.
               // The best optimization would be injecting contiguous reshuffles with X > 1 and
               // an extended vl. If we injected only one reshuffle, we can skip the wait idle.
-              if (csr_vtype_q.vlmul != LMUL_1) state_d = WAIT_IDLE;
+              if (csr_vtype_q.vlmul != LMUL_1 || rs_lmul_cnt_limit_q != '0) state_d = WAIT_IDLE;
               else state_d = NORMAL_OPERATION;
             end
           // The register is not completely reshuffled (LMUL > 1)
@@ -597,7 +611,8 @@
             endcase
 
             // Mask the next request if we don't need to reshuffle the next reg
-            if (eew_new_buffer_d == eew_old_buffer_d) rs_mask_request_d = 1'b1;
+            if ((eew_new_buffer_d == eew_old_buffer_d) || !eew_valid_q[vs_buffer_d])
+              rs_mask_request_d = 1'b1;
           end
         end
       end
@@ -2948,8 +2963,8 @@
               default: begin // Invalid. Element is too wide, or encoding is non-existant.
                 acc_resp_o.req_ready  = 1'b1;
                 acc_resp_o.resp_valid = 1'b1;
-                illegal_insn          = 1'b1;
-                ara_req_valid       = 1'b0;
+                illegal_insn_load     = 1'b1;
+                ara_req_valid         = 1'b0;
               end
             endcase
 
@@ -2966,6 +2981,10 @@
                     // We operate ceil(vl/8) bytes
                     ara_req.vl         = (csr_vl_q >> 3) + |csr_vl_q[2:0];
                     ara_req.vtype.vsew = EW8;
+                    if (ara_req.nf != 3'b000 || !ara_req.vm ||
+                        {insn.vmem_type.mew, insn.vmem_type.width} != 4'b0000) begin
+                      illegal_insn_load = 1'b1;
+                    end
                   end
                   5'b10000: begin // Unit-strided, fault-only first
                     ara_req.fault_only_first = 1'b1;
@@ -2989,28 +3008,41 @@
               default:;
             endcase
 
-            // For memory operations: EMUL = LMUL * (EEW / SEW)
-            // EEW is encoded in the instruction
-            ara_req.emul = vlmul_e'(csr_vtype_q.vlmul + (ara_req.vtype.vsew - csr_vtype_q.vsew));
-
-            // Exception if EMUL > 8 or < 1/8
-            unique case ({csr_vtype_q.vlmul[2], ara_req.emul[2]})
-              // The new emul is lower than the previous lmul
-              2'b01: begin
-                // But the new eew is greater than vsew
-                if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) > 0) begin
-                  illegal_insn_load     = 1'b1;
+            if (ara_req.op == VLE && insn.vmem_type.rs2 == 5'b01011) begin
+              ara_req.emul = LMUL_1;
+              if (csr_vtype_q.vill) illegal_insn_load = 1'b1;
+            end else begin
+              // For memory operations: EMUL = LMUL * (EEW / SEW)
+              // EEW is encoded in the instruction
+              ara_req.emul = vlmul_e'(csr_vtype_q.vlmul + (ara_req.vtype.vsew - csr_vtype_q.vsew));
+
+              // Exception if EMUL > 8 or < 1/8
+              unique case ({csr_vtype_q.vlmul[2], ara_req.emul[2]})
+                // The new emul is lower than the previous lmul
+                2'b01: begin
+                  // But the new eew is greater than vsew
+                  if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) > 0) begin
+                    illegal_insn_load     = 1'b1;
+                  end
                 end
-              end
-              // The new emul is greater than the previous lmul
-              2'b10: begin
-                // But the new eew is lower than vsew
-                if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) < 0) begin
-                  illegal_insn_load     = 1'b1;
+                // The new emul is greater than the previous lmul
+                2'b10: begin
+                  // But the new eew is lower than vsew
+                  if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) < 0) begin
+                    illegal_insn_load     = 1'b1;
+                  end
                 end
-              end
-              default:;
-            endcase
+                default:;
+              endcase
+
+              // Invalid vtype or masked destination overlap with v0
+              if (csr_vtype_q.vill) begin
+                illegal_insn_load = 1'b1;
+              end
+              if (!ara_req.vm && (ara_req.vd == 5'd0)) begin
+                illegal_insn_load = 1'b1;
+              end
+            end
 
             // Instructions with an integer LMUL have extra constraints on the registers they can
             // access.
@@ -3031,36 +3063,28 @@
             endcase
 
             // Check for segment loads
-            if (ara_req.nf != 3'b000 && insn.vmem_type.rs2 != 5'b01000) begin
-              if (pending_seg_mem_op_q) begin
-                // This is a segment load instruction
-                is_segment_mem_op = 1'b1;
-                // Remove pending segment mem op when over
-                if (seg_mem_op_end) pending_seg_mem_op_d = 1'b0;
+            if (ara_req.nf != 3'b000 &&
+                !(ara_req.op == VLE && (insn.vmem_type.rs2 == 5'b01000 || insn.vmem_type.rs2 == 5'b01011))) begin
+              if (SegSupport == SegSupportDisable || !(ara_req.op inside {VLE, VLSE})) begin
+                illegal_insn_load = 1'b1;
               end else begin
-                // Wait for idle not to mess with load/store_complete_i
-                // since the segment sequencer filters these signals
-                ara_req_valid = 1'b0;
-                pending_seg_mem_op_d = 1'b1;
-                state_d = WAIT_IDLE;
-              end
-              // Check that EMUL * NFIELDS <= 8
-              if (!ara_req.emul[2]) begin
-                // emul >= 1
-                if ((ara_req.nf << ara_req.emul[1:0]) > 8)
-                  illegal_insn = 1'b1;
-              end else begin
-                // emul < 1
-                if ((ara_req.nf >> ara_req.emul[1:0]) > 8)
-                  illegal_insn = 1'b1;
-              end
-              // Check if we will not access vector regs past 31
-              if (!ara_req.emul[2]) begin
-                if ((ara_req.vd + (ara_req.nf << ara_req.emul[1:0])) > 5'b11111)
-                  illegal_insn = 1'b1;
-              end else begin
-                if ((ara_req.vd + ara_req.nf) > 5'b11111)
-                  illegal_insn = 1'b1;
+                is_seg_mem_candidate = 1'b1;
+                // Check that EMUL * NFIELDS <= 8 (where NFIELDS = nf + 1)
+                if (!ara_req.emul[2]) begin
+                  if (((7'(ara_req.nf) + 7'd1) << ara_req.emul[1:0]) > 7'd8) begin
+                    illegal_insn_load = 1'b1;
+                  end
+                end
+                // Check if we will not access vector regs past v31
+                if (!ara_req.emul[2]) begin
+                  if ((7'(ara_req.vd) + ((7'(ara_req.nf) + 7'd1) << ara_req.emul[1:0])) > 7'd32) begin
+                    illegal_insn_load = 1'b1;
+                  end
+                end else begin
+                  if ((7'(ara_req.vd) + 7'(ara_req.nf)) > 7'd31) begin
+                    illegal_insn_load = 1'b1;
+                  end
+                end
               end
             end
 
@@ -3069,7 +3093,8 @@
               // Execute also if vl == 0
               ignore_zero_vl_check = 1'b1;
               // The LMUL value is kept in the instruction itself
-              illegal_insn_load     = 1'b0;
+              illegal_insn_load = !insn.vmem_type.vm ||
+                !({insn.vmem_type.mew, insn.vmem_type.width} inside {4'b0000, 4'b0101, 4'b0110, 4'b0111});
               ara_req_valid  = 1'b1;
 
               // Maximum vector length. VLMAX = nf * VLEN / EW8.
@@ -3082,14 +3107,17 @@
                 3'd1: begin
                   ara_req.vl = VLENB << 1;
                   ara_req.emul = LMUL_2;
+                  if ((ara_req.vd & 5'b00001) != 5'b00000) illegal_insn_load = 1'b1;
                 end
                 3'd3:  begin
                   ara_req.vl = VLENB << 2;
                   ara_req.emul = LMUL_4;
+                  if ((ara_req.vd & 5'b00011) != 5'b00000) illegal_insn_load = 1'b1;
                 end
                 3'd7:  begin
                   ara_req.vl = VLENB << 3;
                   ara_req.emul = LMUL_8;
+                  if ((ara_req.vd & 5'b00111) != 5'b00000) illegal_insn_load = 1'b1;
                 end
                 default: begin
                   // Trigger an error for the reserved simm values
@@ -3196,7 +3224,7 @@
                   end
               end
               default: begin // Invalid. Element is too wide, or encoding is non-existant.
-                illegal_insn  = 1'b1;
+                illegal_insn_store = 1'b1;
               end
             endcase
 
@@ -3213,6 +3241,10 @@
                     // We operate ceil(vl/8) bytes
                     ara_req.vl         = (csr_vl_q >> 3) + |csr_vl_q[2:0];
                     ara_req.vtype.vsew = EW8;
+                    if (ara_req.nf != 3'b000 || !ara_req.vm ||
+                        {insn.vmem_type.mew, insn.vmem_type.width} != 4'b0000) begin
+                      illegal_insn_store = 1'b1;
+                    end
                   end
                   default: begin // Reserved
                     illegal_insn_store    = 1'b1;
@@ -3233,28 +3265,37 @@
               default:;
             endcase
 
-            // For memory operations: EMUL = LMUL * (EEW / SEW)
-            // EEW is encoded in the instruction
-            ara_req.emul = vlmul_e'(csr_vtype_q.vlmul + (ara_req.vtype.vsew - csr_vtype_q.vsew));
-
-            // Exception if EMUL > 8 or < 1/8
-            unique case ({csr_vtype_q.vlmul[2], ara_req.emul[2]})
-              // The new emul is lower than the previous lmul
-              2'b01: begin
-                // But the new eew is greater than vsew
-                if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) > 0) begin
-                  illegal_insn_store    = 1'b1;
+            if (ara_req.op == VSE && insn.vmem_type.rs2 == 5'b01011) begin
+              ara_req.emul = LMUL_1;
+              if (csr_vtype_q.vill) illegal_insn_store = 1'b1;
+            end else begin
+              // For memory operations: EMUL = LMUL * (EEW / SEW)
+              // EEW is encoded in the instruction
+              ara_req.emul = vlmul_e'(csr_vtype_q.vlmul + (ara_req.vtype.vsew - csr_vtype_q.vsew));
+
+              // Exception if EMUL > 8 or < 1/8
+              unique case ({csr_vtype_q.vlmul[2], ara_req.emul[2]})
+                // The new emul is lower than the previous lmul
+                2'b01: begin
+                  // But the new eew is greater than vsew
+                  if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) > 0) begin
+                    illegal_insn_store    = 1'b1;
+                  end
                 end
-              end
-              // The new emul is greater than the previous lmul
-              2'b10: begin
-                // But the new eew is lower than vsew
-                if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) < 0) begin
-                  illegal_insn_store    = 1'b1;
+                // The new emul is greater than the previous lmul
+                2'b10: begin
+                  // But the new eew is lower than vsew
+                  if (signed'(ara_req.vtype.vsew - csr_vtype_q.vsew) < 0) begin
+                    illegal_insn_store    = 1'b1;
+                  end
                 end
-              end
-              default:;
-            endcase
+                default:;
+              endcase
+
+              if (csr_vtype_q.vill) begin
+                illegal_insn_store = 1'b1;
+              end
+            end
 
             // Instructions with an integer LMUL have extra constraints on the registers they can
             // access.
@@ -3275,36 +3316,28 @@
             endcase
 
             // Check for segment stores
-            if (ara_req.nf != 3'b000 && insn.vmem_type.rs2 != 5'b01000) begin
-              if (pending_seg_mem_op_q) begin
-                // This is a segment store instruction
-                is_segment_mem_op = 1'b1;
-                // Remove pending segment mem op when over
-                if (seg_mem_op_end) pending_seg_mem_op_d = 1'b0;
+            if (ara_req.nf != 3'b000 &&
+                !(ara_req.op == VSE && (insn.vmem_type.rs2 == 5'b01000 || insn.vmem_type.rs2 == 5'b01011))) begin
+              if (SegSupport == SegSupportDisable || !(ara_req.op inside {VSE, VSSE})) begin
+                illegal_insn_store = 1'b1;
               end else begin
-                // Wait for idle not to mess with load/store_complete_i
-                // since the segment sequencer filters these signals
-                ara_req_valid = 1'b0;
-                pending_seg_mem_op_d = 1'b1;
-                state_d = WAIT_IDLE;
-              end
-              // Check that EMUL * NFIELDS <= 8
-              if (!ara_req.emul[2]) begin
-                // emul >= 1
-                if ((ara_req.nf << ara_req.emul[1:0]) > 8)
-                  illegal_insn = 1'b1;
-              end else begin
-                // emul < 1
-                if ((ara_req.nf >> ara_req.emul[1:0]) > 8)
-                  illegal_insn = 1'b1;
-              end
-              // Check if we will not access vector regs past 31
-              if (!ara_req.emul[2]) begin
-                if ((ara_req.vd + (ara_req.nf << ara_req.emul[1:0])) > 5'b11111)
-                  illegal_insn = 1'b1;
-              end else begin
-                if ((ara_req.vd + ara_req.nf) > 5'b11111)
-                  illegal_insn = 1'b1;
+                is_seg_mem_candidate = 1'b1;
+                // Check that EMUL * NFIELDS <= 8 (where NFIELDS = nf + 1)
+                if (!ara_req.emul[2]) begin
+                  if (((7'(ara_req.nf) + 7'd1) << ara_req.emul[1:0]) > 7'd8) begin
+                    illegal_insn_store = 1'b1;
+                  end
+                end
+                // Check if we will not access source vector regs (vs3 -> ara_req.vs1) past v31
+                if (!ara_req.emul[2]) begin
+                  if ((7'(ara_req.vs1) + ((7'(ara_req.nf) + 7'd1) << ara_req.emul[1:0])) > 7'd32) begin
+                    illegal_insn_store = 1'b1;
+                  end
+                end else begin
+                  if ((7'(ara_req.vs1) + 7'(ara_req.nf)) > 7'd31) begin
+                    illegal_insn_store = 1'b1;
+                  end
+                end
               end
             end
 
@@ -3313,7 +3346,8 @@
             if (ara_req.op == VSE && insn.vmem_type.rs2 == 5'b01000) begin
               // Execute also if vl == 0
               ignore_zero_vl_check = 1'b1;
-              illegal_insn_store    = 1'b0;
+              illegal_insn_store = !insn.vmem_type.vm ||
+                !({insn.vmem_type.mew, insn.vmem_type.width} inside {4'b0000, 4'b0101, 4'b0110, 4'b0111});
 
               // Maximum vector length. VLMAX = nf * VLEN / EW8.
               ara_req.vtype.vsew = EW8;
@@ -3325,14 +3359,17 @@
                 3'd1: begin
                   ara_req.vl = VLENB << 1;
                   ara_req.emul = LMUL_2;
+                  if ((ara_req.vs1 & 5'b00001) != 5'b00000) illegal_insn_store = 1'b1;
                 end
                 3'd3:  begin
                   ara_req.vl = VLENB << 2;
                   ara_req.emul = LMUL_4;
+                  if ((ara_req.vs1 & 5'b00011) != 5'b00000) illegal_insn_store = 1'b1;
                 end
                 3'd7:  begin
                   ara_req.vl = VLENB << 3;
                   ara_req.emul = LMUL_8;
+                  if ((ara_req.vs1 & 5'b00111) != 5'b00000) illegal_insn_store = 1'b1;
                 end
                 default: begin
                   // Trigger an error for the reserved simm values
@@ -3626,8 +3663,31 @@
 
       // Check if we need to reshuffle our vector registers involved in the operation
       // This operation is costly when occurs, so avoid it if possible
-      if ( ara_req_valid && !acc_resp_o.exception.valid ) begin
+      if ( ara_req_valid && !acc_resp_o.exception.valid && !pending_seg_mem_op_q &&
+           !(csr_vstart_q >= csr_vl_q && !ignore_zero_vl_check) ) begin
         automatic rvv_instruction_t insn = rvv_instruction_t'(instr.instr);
+        automatic logic [3:0] seg_total_regs = ara_req.emul[2]
+          ? (4'(ara_req.nf) + 4'd1)
+          : ((4'(ara_req.nf) + 4'd1) << ara_req.emul[1:0]);
+        automatic logic seg_vd_reshuffle  = 1'b0;
+        automatic logic seg_vs1_reshuffle = 1'b0;
+
+        if (is_seg_mem_candidate) begin
+          automatic logic whole_group_overwritten = (csr_vstart_q == '0) && !ara_req.emul[2] &&
+            ara_req.vm && (csr_vl_q == ((VLENB << ara_req.emul[1:0]) >> ara_req.vtype.vsew));
+          for (int unsigned r = 0; r < 8; r++) begin
+            if (4'(r) < seg_total_regs) begin
+              if (is_vload && !whole_group_overwritten &&
+                  eew_valid_q[ara_req.vd + 5'(r)] && (eew_q[ara_req.vd + 5'(r)] != ara_req.vtype.vsew)) begin
+                seg_vd_reshuffle = 1'b1;
+              end
+              if (is_vstore &&
+                  eew_valid_q[ara_req.vs1 + 5'(r)] && (eew_q[ara_req.vs1 + 5'(r)] != ara_req.eew_vs1)) begin
+                seg_vs1_reshuffle = 1'b1;
+              end
+            end
+          end
+        end
 
         // Is the instruction an in-lane one and could it be subject to reshuffling?
         in_lane_op = ara_req.op inside {[VADD:VMERGE]} || ara_req.op inside {[VREDSUM:VMSBC]} ||
@@ -3638,14 +3698,18 @@
         // During a vstore, if vstart > 0, reshuffle immediately not to complicate operand fetch stage
         // During a vstore with EMUL > 1, reshuffle immediately if the register group's EEW is not the
         // same for every reg.
-        reshuffle_req_d = {ara_req.use_vs1 && (ara_req.eew_vs1    != eew_q[ara_req.vs1]) && eew_valid_q[ara_req.vs1] && (in_lane_op || (is_vstore && ((csr_vstart_q != '0) || !is_same_eew))),
-                           ara_req.use_vs2 && (ara_req.eew_vs2    != eew_q[ara_req.vs2]) && eew_valid_q[ara_req.vs2] && in_lane_op,
-                           ara_req.use_vd  && (ara_req.vtype.vsew != eew_q[ara_req.vd ]) && eew_valid_q[ara_req.vd ] && !(csr_vstart_q == 0 && (csr_vl_q == ((VLENB << ara_req.emul[1:0]) >> ara_req.vtype.vsew)))};
-        // Mask out requests if they refer to the same register!
-        reshuffle_req_d &= {
-          (insn.varith_type.rs1 != insn.varith_type.rs2) && (insn.varith_type.rs1 != insn.varith_type.rd),
-          (insn.varith_type.rs2 != insn.varith_type.rd),
-          1'b1};
+        if (is_seg_mem_candidate) begin
+          reshuffle_req_d = {seg_vs1_reshuffle, 1'b0, seg_vd_reshuffle};
+        end else begin
+          reshuffle_req_d = {ara_req.use_vs1 && (ara_req.eew_vs1    != eew_q[ara_req.vs1]) && eew_valid_q[ara_req.vs1] && (in_lane_op || (is_vstore && ((csr_vstart_q != '0) || !is_same_eew))),
+                             ara_req.use_vs2 && (ara_req.eew_vs2    != eew_q[ara_req.vs2]) && eew_valid_q[ara_req.vs2] && in_lane_op,
+                             ara_req.use_vd  && (ara_req.vtype.vsew != eew_q[ara_req.vd ]) && eew_valid_q[ara_req.vd ] && !(csr_vstart_q == 0 && (csr_vl_q == ((VLENB << ara_req.emul[1:0]) >> ara_req.vtype.vsew)))};
+          // Mask out requests if they refer to the same register!
+          reshuffle_req_d &= {
+            is_vstore || ((insn.varith_type.rs1 != insn.varith_type.rs2) && (insn.varith_type.rs1 != insn.varith_type.rd)),
+            (insn.varith_type.rs2 != insn.varith_type.rd),
+            1'b1};
+        end
 
         // Prepare the information to reshuffle the vector registers during the next cycles
         // Reshuffle in the following order: vd, v2, v1. The order is arbitrary.
@@ -3670,22 +3734,38 @@
       end
 
       // Reshuffle if at least one of the three registers needs a reshuffle
-      if (|reshuffle_req_d) begin
+      if (pending_seg_mem_op_q) begin
+        if (is_decoding && is_seg_mem_candidate) begin
+          is_segment_mem_op = 1'b1;
+          if (seg_mem_op_end) pending_seg_mem_op_d = 1'b0;
+        end
+      end else if (|reshuffle_req_d) begin
         // Instruction is of one of the RVV types
         automatic rvv_instruction_t insn = rvv_instruction_t'(instr.instr);
+        automatic logic [3:0] seg_total_regs = ara_req.emul[2]
+          ? (4'(ara_req.nf) + 4'd1)
+          : ((4'(ara_req.nf) + 4'd1) << ara_req.emul[1:0]);
 
         // Stall the interface, and inject a reshuffling instruction
         acc_resp_o.req_ready  = 1'b0;
         acc_resp_o.resp_valid = 1'b0;
         ara_req_valid  = 1'b0;
 
-        // Initialize the reshuffle counter limit to handle LMUL > 1
-        unique case (ara_req.emul)
-          LMUL_2:  rs_lmul_cnt_limit_d = 1;
-          LMUL_4:  rs_lmul_cnt_limit_d = 3;
-          LMUL_8:  rs_lmul_cnt_limit_d = 7;
-          default: rs_lmul_cnt_limit_d = 0;
-        endcase
+        // Initialize the reshuffle counter limit to handle LMUL > 1 or segment groups
+        if (is_seg_mem_candidate) begin
+          rs_lmul_cnt_limit_d = 3'(seg_total_regs - 4'd1);
+        end else begin
+          unique case (ara_req.emul)
+            LMUL_2:  rs_lmul_cnt_limit_d = 1;
+            LMUL_4:  rs_lmul_cnt_limit_d = 3;
+            LMUL_8:  rs_lmul_cnt_limit_d = 7;
+            default: rs_lmul_cnt_limit_d = 0;
+          endcase
+        end
+
+        if ((eew_new_buffer_d == eew_old_buffer_d) || !eew_valid_q[vs_buffer_d]) begin
+          rs_mask_request_d = 1'b1;
+        end
 
         // Save info for next reshuffles
         reshuffle_eew_vs1_d = ara_req.eew_vs1;
@@ -3694,40 +3774,50 @@
 
         // Reshuffle
         state_d = RESHUFFLE;
+      end else if (is_decoding && is_seg_mem_candidate &&
+                   !(illegal_insn 
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ara_dispatcher.sv`](environment/public/code/ara_dispatcher.sv) **(Editable)**
- [`environment/public/code/ara_pkg.sv`](environment/public/code/ara_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ara_sequencer.sv`](environment/public/code/ara_sequencer.sv) *(Read-Only Context)*
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
- [`environment/public/code/popcount.sv`](environment/public/code/popcount.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/rvv_pkg.sv`](environment/public/code/rvv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/segment_sequencer.sv`](environment/public/code/segment_sequencer.sv) **(Editable)**
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter.sv`](environment/public/code/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter_flushable.sv`](environment/public/code/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_demux.sv`](environment/public/code/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_mux.sv`](environment/public/code/stream_mux.sv) *(Read-Only Context)*
- [`environment/public/code/stream_xbar.sv`](environment/public/code/stream_xbar.sv) *(Read-Only Context)*
- [`environment/public/code/vlsu/addrgen.sv`](environment/public/code/vlsu/addrgen.sv) *(Read-Only Context)*
- [`environment/public/code/vlsu/vldu.sv`](environment/public/code/vlsu/vldu.sv) *(Read-Only Context)*
- [`environment/public/code/vlsu/vlsu.sv`](environment/public/code/vlsu/vlsu.sv) *(Read-Only Context)*
- [`environment/public/code/vlsu/vstu.sv`](environment/public/code/vlsu/vstu.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

