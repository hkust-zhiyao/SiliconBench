# `case_23016`: Vortex Hopper-Style WGMMA & 2:4 Sparse Tensor Core Tile-Buffer Coherence, FIFO Retirement & PPA/STA Signoff

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23016` |
| **Source Silicon Repository** | `vortexgpgpu/vortex` (`repo_37`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/VX_tcu_uops.sv`](environment/public/code/VX_tcu_uops.sv), [`code/VX_tcu_abuf.sv`](environment/public/code/VX_tcu_abuf.sv), [`code/VX_tcu_bbuf.sv`](environment/public/code/VX_tcu_bbuf.sv), [`code/VX_tcu_core.sv`](environment/public/code/VX_tcu_core.sv) (4 files, 2415 LOC) |
| **Public Subsystem Context** | 70 RTL files (17172 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Vortex Hopper-Style WGMMA & 2:4 Sparse Tensor Core Subsystem Coherence, Retirement & PPA Signoff

## Context
`public/code/` contains the standalone RTL closure of the Vortex GPGPU Tensor Core subsystem (`VX_tcu_subsys`), integrating micro-op expansion (`VX_uop_sequencer` + `VX_tcu_uops`), Hopper-style Warp-Group MMA shared-memory tile buffers (`VX_tcu_wgmma` + `VX_tcu_tbuf` + `VX_tcu_abuf` + `VX_tcu_bbuf` + `VX_tcu_lockstep`), warp-indexed 2:4 structured-sparsity metadata/gather logic (`VX_tcu_meta` + `VX_tcu_sp_mux`), and the pipelined dot-product execution core (`VX_tcu_core` + `VX_tcu_fedp_tfr`).

Currently, the four core WGMMA/TCU control and tile-buffer RTL modules exhibit an IEEE 1800-2017 elaboration violation, shared-memory straddling/coherency defects, an out-of-order retirement hazard under commit backpressure, 4-state gate-level reset `X`-propagation hangs, and excessive Nangate45 cell area (~`89k um^2`).

## Editable Files
You may modify **only** the following files (all other files in `code/` and `lib/` are read-only):
- `code/VX_tcu_uops.sv` (`module VX_tcu_uops`)
- `code/VX_tcu_abuf.sv` (`module VX_tcu_abuf`)
- `code/VX_tcu_bbuf.sv` (`module VX_tcu_bbuf`)
- `code/VX_tcu_core.sv` (`module VX_tcu_core`)

## Architectural, Protocol & Multi-Configuration Contract
Your implementation must preserve full functional parity across both parameterized subsystem configurations:
- **`CFG_F2K_1B`**: `-DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_FEDP2K` (`TCU_WG_FEDP_K = 4`, `TCU_WG_K_STEPS = 1`)
- **`CFG_NOF2K_2B`**: `-DVX_CFG_NUM_TCU_BLOCKS=2 -DNO_FEDP2K` (`TCU_WG_FEDP_K = 2`, `TCU_WG_K_STEPS = 2`)
(both with `-DXLEN_32 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_LMEM_NUM_BANKS=8 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE`)

1. **WMMA & Hopper WGMMA Micro-Op Expansion (`VX_tcu_uops`)**:
   - Preserve exact warp-level `WMMA` (`INST_TCU_WMMA`) and 2:4 sparse `WMMA_SP` (`INST_TCU_WMMA_SP`) expansion across `FP16`/`BF16 -> FP32` and `INT8`/`UINT8`/`INT4`/`UINT4 -> INT32`.
   - Expand dense `WGMMA` (`INST_TCU_WGMMA`) and 2:4 sparse `WGMMA_SP` (`INST_TCU_WGMMA_SP`) across `cd_nregs in {0, 1, 2}` (`8`, `16`, or `32` accumulator `f`-registers), register-sourced (`a_from_smem == 0`, `RS`) and shared-memory-sourced (`a_from_smem == 1`, `SS`) A operands, `FEDP2K` vs non-`FEDP2K` K-steps, and exact `fu_lock`/`fu_unlock` / first-compute / last-uop signaling.
2. **Shared-Memory Tile Layout, Sub-Row Offsets & Bank-Row Straddling (`VX_tcu_abuf`, `VX_tcu_bbuf`)**:
   - Decode 32-bit shared-memory descriptors in `x10` (A) and `x11` (B), where `[15:0]` is the word-aligned byte base address and `[31:16]` is the word-aligned byte leading-dimension stride (`0` selects padded 8-bank-row-aligned block-major layout; non-zero selects row-major A / K-major B strided layout).
   - Support arbitrary word-aligned sub-bank-row base offsets (`(base_bytes >> 2) % NUM_BANKS != 0`) and arbitrary word-aligned strides, accurately fetching and assembling slices that straddle two consecutive 8-word LMEM bank rows for both dense and 2:4 sparse tiles under variable LMEM request backpressure and response latency.
3. **Tile-Buffer Cache Coherency & Multi-Block Lockstep (`VX_tcu_abuf`, `VX_tcu_bbuf`)**:
   - Reuse resident A-stripes and B-tiles within a WGMMA macro-instruction burst while guaranteeing fresh LMEM refills across layout switches (`K-major <-> block-major`), in-place shared-memory updates between consecutive WGMMA macro-instructions at identical descriptor addresses, and `cta_id`/warp transitions across single- and dual-block lockstep execution.
4. **Strict Per-Block FIFO Retirement Under Backpressure (`VX_tcu_core`)**:
   - Every micro-op accepted on `uop_fire[b]`—including `wb == 0` WGMMA descriptor-setup micro-ops issued immediately after older compute micro-ops—must retire on `res_valid[b] && res_ready[b]` in strict per-block FIFO order without bypassing older in-flight or landing-buffer-parked compute results when `res_ready[b]` stalls.

## Synthesis, 4-State Gate-Level Hygiene & Nangate45 PPA/STA Targets
Evaluated on `VX_tcu_subsys` under `-DXLEN_32 -DTCU_SYNTH_BND -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=2 -DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE -DVX_CFG_TCU_FEDP2K -DVX_CFG_LMEM_NUM_BANKS=8`:
- **IEEE 1800-2017 Synthesis & 4-State Gate-Level Hygiene**: Must elaborate cleanly in `yosys -m slang` (`read_slang`, strict declare-before-use) with zero inferred latches (`$dlatch*` / `$_DLATCH_*`), zero combinational loops (`scc -expect 0`), and deterministic `X`-free post-reset handshakes and committed results in 4-state `iverilog -g2012` gate-level simulation.
- **Nangate45 Cell Area Cap** (`lib/NangateOpenCellLibrary_typical.lib`, flattened `VX_tcu_subsys` mapped with `dfflibmap -liberty` + `abc -liberty ... -D 1500 -script "+strash;dc2;dch -f;map;buffer -N 16;upsize;dnsize"`): **`<= 87,200.0 um^2`**.
- **OpenROAD Static Timing Signoff**: Under a **`6.50 ns` clock period** on `clk` (`0.20 ns` input/output delay on non-clock ports, `set_false_path -from [get_ports reset]`), setup **`WNS >= 0.0000 ns`**.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Signoff Reference

## Editable Files
- `code/VX_tcu_uops.sv`
- `code/VX_tcu_abuf.sv`
- `code/VX_tcu_bbuf.sv`
- `code/VX_tcu_core.sv`

## Read-Only Subsystem & Technology Collateral
- Subsystem top & supporting Vortex TCU/core/library RTL: `code/VX_tcu_subsys.sv`, `code/VX_tcu_pkg.sv`, `code/VX_gpu_pkg.sv`, and supporting `.sv`/`.vh` files in `code/`
- Nangate45 standard-cell collateral:
  - `lib/NangateOpenCellLibrary_typical.lib`
  - `lib/NangateOpenCellLibrary.tech.lef`
  - `lib/NangateOpenCellLibrary.macro.mod.lef`

## Tooling & Evaluation Flow
1. **Dual-Configuration RTL Functional Verification (`Verilator v5.038`)**:
   - Compile `VX_gpu_pkg.sv`, `VX_tcu_pkg.sv`, and `VX_tcu_subsys.sv` (`-Icode -DXLEN_32 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_LMEM_NUM_BANKS=8 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE`) across:
     - `CFG_F2K_1B`: `-DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_FEDP2K`
     - `CFG_NOF2K_2B`: `-DVX_CFG_NUM_TCU_BLOCKS=2 -DNO_FEDP2K`
   - Verify dense & 2:4 sparse `WMMA`/`WGMMA` arithmetic, strided bank-row-straddling SMEM tile loads, B-tile cache coherency, dual-block lockstep, and FIFO retirement under randomized LMEM/commit backpressure.
2. **Yosys Synthesis, 4-State Gate-Level Simulation & Nangate45 PPA/STA Signoff**:
   - Elaborate `VX_tcu_subsys` in `yosys -m slang` (`read_slang --top VX_tcu_subsys -Icode -DXLEN_32 -DTCU_SYNTH_BND -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_WARPS=2 -DVX_CFG_NUM_TCU_BLOCKS=1 -DVX_CFG_TCU_ENABLE -DVX_CFG_TCU_WGMMA_ENABLE -DVX_CFG_TCU_SPARSE_ENABLE -DVX_CFG_TCU_FEDP2K -DVX_CFG_LMEM_NUM_BANKS=8 code/VX_gpu_pkg.sv code/VX_tcu_pkg.sv ...`), checking zero latches (`$dlatch*`, `$_DLATCH_*`) and zero combinational loops (`scc -expect 0`).
   - Simulate the synthesized gate-level netlist in 4-state `iverilog -g2012` against `simcells.v` to verify `X`-free reset and multi-warp `WMMA`/`WGMMA`/`WGMMA_SP` retirement.
   - Flatten and map to `lib/NangateOpenCellLibrary_typical.lib` (`dfflibmap -liberty` + `abc -liberty ... -D 1500 -script "+strash;dc2;dch -f;map;buffer -N 16;upsize;dnsize"`), requiring cell area `<= 87,200.0 um^2` and OpenROAD STA setup `WNS >= 0.0000 ns` at a `6.50 ns` clock period (`0.20 ns` non-clock I/O delays, `set_false_path -from [get_ports reset]`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/VX_tcu_uops.sv (Buggy Starter)
+++ b/solution/gold/code/VX_tcu_uops.sv (Golden Reference)
@@ -127,26 +127,32 @@
     localparam WG_UOPS_SP_NR32 = WG_MN_NR32 * TCU_WG_K_STEPS_SP;
 `endif
 
-    // Mux uop count based on cd_nregs: 0→8, 1→16, 2→32
+    // Mux uop count & last-index directly as compile-time constants (no 12b add/sub chain)
     reg [UOP_CTR_W-1:0] wg_uop_cnt;
-    reg [UOP_CTR_W-1:0] wg_compute_uop_cnt;
+    reg [`UP(CTR_W)-1:0] wg_last_idx;
     always_comb begin
-        case (ibuf_in.op_args.tcu.cd_nregs)
-            2'd0: wg_compute_uop_cnt = UOP_CTR_W'(WG_UOPS_NR8);
-            2'd1: wg_compute_uop_cnt = UOP_CTR_W'(WG_UOPS_NR16);
-            default: wg_compute_uop_cnt = UOP_CTR_W'(WG_UOPS_NR32);
-        endcase
     `ifdef VX_CFG_TCU_SPARSE_ENABLE
         if (wg_is_sparse) begin
             case (ibuf_in.op_args.tcu.cd_nregs)
-                2'd0: wg_compute_uop_cnt = UOP_CTR_W'(WG_UOPS_SP_NR8);
-                2'd1: wg_compute_uop_cnt = UOP_CTR_W'(WG_UOPS_SP_NR16);
-                default: wg_compute_uop_cnt = UOP_CTR_W'(WG_UOPS_SP_NR32);
+                2'd0: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_SP_NR8);  wg_last_idx = `UP(CTR_W)'(WG_UOPS_SP_NR8 - 1); end
+                2'd1: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_SP_NR16); wg_last_idx = `UP(CTR_W)'(WG_UOPS_SP_NR16 - 1); end
+                default: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_SP_NR32); wg_last_idx = `UP(CTR_W)'(WG_UOPS_SP_NR32 - 1); end
             endcase
-            wg_uop_cnt = wg_compute_uop_cnt;
         end else
     `endif
-            wg_uop_cnt = wg_compute_uop_cnt + UOP_CTR_W'(wg_needs_setup);
+        if (wg_needs_setup) begin
+            case (ibuf_in.op_args.tcu.cd_nregs)
+                2'd0: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_NR8 + 1);  wg_last_idx = `UP(CTR_W)'(WG_UOPS_NR8); end
+                2'd1: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_NR16 + 1); wg_last_idx = `UP(CTR_W)'(WG_UOPS_NR16); end
+                default: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_NR32 + 1); wg_last_idx = `UP(CTR_W)'(WG_UOPS_NR32); end
+            endcase
+        end else begin
+            case (ibuf_in.op_args.tcu.cd_nregs)
+                2'd0: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_NR8);  wg_last_idx = `UP(CTR_W)'(WG_UOPS_NR8 - 1); end
+                2'd1: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_NR16); wg_last_idx = `UP(CTR_W)'(WG_UOPS_NR16 - 1); end
+                default: begin wg_uop_cnt = UOP_CTR_W'(WG_UOPS_NR32); wg_last_idx = `UP(CTR_W)'(WG_UOPS_NR32 - 1); end
+            endcase
+        end
     end
 
     // K-outer index extraction:
@@ -418,12 +424,14 @@
         end
     `ifdef VX_CFG_TCU_WGMMA_ENABLE
         if (is_wgmma) begin
-            ibuf_r.fu_lock   = (uop_idx == '0);
-            ibuf_r.fu_unlock = (uop_idx == (uop_count - UOP_CTR_W'(1)));
+            automatic logic ctr_hi_zero = (uop_idx[UOP_CTR_W-1:`UP(CTR_W)] == '0);
+            automatic logic is_wg_last  = ctr_hi_zero && (ctr == wg_last_idx);
+            ibuf_r.fu_lock   = ctr_hi_zero && (ctr == '0);
+            ibuf_r.fu_unlock = is_wg_last;
             // Expose first/last-uop predicates via op_args.tcu so downstream
             // consumers (bbuf, lockstep) read a single source of truth.
             ibuf_r.op_args.tcu.is_first_uop = is_wg_first_compute_uop;
-            ibuf_r.op_args.tcu.is_last_uop  = !is_wg_setup_uop && (uop_idx == (uop_count - UOP_CTR_W'(1)));
+            ibuf_r.op_args.tcu.is_last_uop  = !is_wg_setup_uop && is_wg_last;
         end
     `endif
         // Other TCU uops retain 11 so they cannot enter a locked WGMMA sequence.

--- a/environment/public/code/VX_tcu_abuf.sv (Buggy Starter)
+++ b/solution/gold/code/VX_tcu_abuf.sv (Golden Reference)
@@ -121,8 +121,10 @@
     // Resident slot state
     // -----------------------------------------------------------------------
 
+    localparam SUB_OFF_W = `UP(BANK_SEL_BITS);
     logic                       slot_valid_r;
     logic [BANK_ADDR_WIDTH-1:0] slot_desc_a_row_base_r;
+    logic [SUB_OFF_W-1:0]       slot_desc_a_sub_off_r;
     logic [`UP(K_STEPS_W)-1:0]  slot_step_k_r;
     logic                       slot_fetching_r;
     // Row-major mode: latched per-row stride. ldm_words=0 means block-major;
@@ -171,9 +173,7 @@
     localparam DESC_ADDR_W = BANK_ADDR_WIDTH + BANK_SEL_BITS;
     wire [DESC_ADDR_W-1:0]      desc_a_word_base = DESC_ADDR_W'(req_desc_a[15:0] >> WORD_SIZE_LOG2);
     wire [BANK_ADDR_WIDTH-1:0]  desc_a_row_base  = desc_a_word_base[BANK_SEL_BITS +: BANK_ADDR_WIDTH];
-    if (BANK_SEL_BITS > 0) begin : g_addr_lsb_unused
-        `UNUSED_VAR (desc_a_word_base[BANK_SEL_BITS-1:0])
-    end
+    wire [SUB_OFF_W-1:0]        desc_a_sub_off   = (BANK_SEL_BITS > 0) ? desc_a_word_base[SUB_OFF_W-1:0] : '0;
     // desc_a's lower 16 bits encode the smem offset; upper 16 bits carry the
     // per-row byte stride (matches WGMMA SS descriptor). Stride=0 keeps
     // the canonical block-major layout; non-zero selects the row-major path.
@@ -188,6 +188,8 @@
     // k-stripe-transition refills mid-WGMMA would compute the wrong fetch_base.
     wire [BANK_ADDR_WIDTH-1:0]  effective_desc_a_row_base =
         is_first_compute_uop ? desc_a_row_base : slot_desc_a_row_base_r;
+    wire [SUB_OFF_W-1:0]        effective_desc_a_sub_off =
+        is_first_compute_uop ? desc_a_sub_off : slot_desc_a_sub_off_r;
     wire [LDM_W-1:0]            effective_ldm_words =
         is_first_compute_uop ? desc_a_ldm_words : slot_ldm_words_r;
     wire                        effective_row_major = (effective_ldm_words != '0);
@@ -214,41 +216,47 @@
 
     logic [FETCH_CTR_W-1:0]     req_ctr_r;
     logic [FETCH_CTR_W-1:0]     rsp_ctr_r;
+    logic                       req_hi_r;
+    logic                       rsp_hi_r;
     logic                       req_inflight_r;
     logic [BANK_ADDR_WIDTH-1:0] fetch_base_r;
 
-    // Total fetches differs by mode:
-    //   block-major: A_STRIPE_LMEM_ROWS adjacent bank-row reads
-    //   row-major:   A_TOTAL_ROWS per-row reads (one per logical row)
     wire [FETCH_CTR_W-1:0] target_fetches = slot_row_major_r
         ? FETCH_CTR_W'(A_TOTAL_ROWS)
         : (slot_is_sparse_r ? FETCH_CTR_W'(A_STRIPE_LMEM_ROWS_SP)
                             : FETCH_CTR_W'(A_STRIPE_LMEM_ROWS));
 
+    localparam ROW_OFF_W = LDM_W + FETCH_CTR_W + 4;
+    wire [3:0] row_k_words = slot_is_sparse_r ? 4'(TCU_TC_K) : 4'(TCU_WG_FEDP_K);
+
+    wire [ROW_OFF_W-1:0] step_k_word_off = req_is_sparse
+        ? (ROW_OFF_W'(req_step_k_trunc) << $clog2(TCU_TC_K))
+        : (ROW_OFF_W'(req_step_k_trunc) << $clog2(TCU_WG_FEDP_K));
+    wire [ROW_OFF_W-1:0] row_word_off_init =
+        ROW_OFF_W'(effective_desc_a_sub_off) + step_k_word_off;
+
+    logic [ROW_OFF_W-1:0] row_word_off_req_r;
+    logic [ROW_OFF_W-1:0] row_word_off_rsp_r;
+
+    wire [BANK_ROW_WORDS_LOG2-1:0] req_lane_w = row_word_off_req_r[BANK_ROW_WORDS_LOG2-1:0];
+    wire [BANK_ROW_WORDS_LOG2-1:0] rsp_lane_w = row_word_off_rsp_r[BANK_ROW_WORDS_LOG2-1:0];
+    wire req_spans_two = slot_row_major_r
+                      && (({1'b0, req_lane_w} + (BANK_ROW_WORDS_LOG2+1)'(row_k_words))
+                          > (BANK_ROW_WORDS_LOG2+1)'(BANK_ROW_WORDS));
+    wire rsp_spans_two = slot_row_major_r
+                      && (({1'b0, rsp_lane_w} + (BANK_ROW_WORDS_LOG2+1)'(row_k_words))
+                          > (BANK_ROW_WORDS_LOG2+1)'(BANK_ROW_WORDS));
+
     wire all_requested = (req_ctr_r >= target_fetches);
     wire can_issue     = in_fetch && !all_requested
                       && (!req_inflight_r || tcu_lmem_if.rsp_valid);
-    wire last_rsp      = in_fetch && tcu_lmem_if.rsp_valid
+    wire row_rsp_done  = !rsp_spans_two || rsp_hi_r;
+    wire last_rsp      = in_fetch && tcu_lmem_if.rsp_valid && row_rsp_done
                       && (rsp_ctr_r == target_fetches - FETCH_CTR_W'(1));
 
-    // Per-row 32-bit-word offset (relative to fetch_base_r * BANK_ROW_WORDS).
-    // Width = LDM (row stride) + counter + a bit for step_k*TC_K headroom.
-    // The offset is linear in the fetch counter and the first issue is at
-    // least one cycle after alloc: the step_k product is registered at alloc
-    // and each request/response accumulates the row stride, keeping the
-    // multiplier off the LMEM request-address and response-lane paths.
-    localparam ROW_OFF_W = LDM_W + FETCH_CTR_W + 4;
-    wire [3:0] row_k_words = slot_is_sparse_r ? 4'(TCU_TC_K) : 4'(TCU_WG_FEDP_K);
-    wire [3:0] row_k_words_alloc = req_is_sparse ? 4'(TCU_TC_K) : 4'(TCU_WG_FEDP_K);
-
-    wire [ROW_OFF_W-1:0] row_word_off_init =
-        ROW_OFF_W'(req_step_k_trunc) * ROW_OFF_W'(row_k_words_alloc);
-
-    logic [ROW_OFF_W-1:0] row_word_off_req_r;
-    logic [ROW_OFF_W-1:0] row_word_off_rsp_r;
-
     wire [BANK_ADDR_WIDTH-1:0] row_lmem_addr =
-        fetch_base_r + BANK_ADDR_WIDTH'(row_word_off_req_r >> BANK_ROW_WORDS_LOG2);
+        fetch_base_r + BANK_ADDR_WIDTH'(row_word_off_req_r >> BANK_ROW_WORDS_LOG2)
+      + BANK_ADDR_WIDTH'(req_hi_r);
 
     // LMEM master driver
     assign tcu_lmem_if.req_valid       = can_issue;
@@ -269,12 +277,15 @@
             fsm_state_r            <= S_IDLE;
             req_ctr_r              <= '0;
             rsp_ctr_r              <= '0;
+            req_hi_r               <= 1'b0;
+            rsp_hi_r               <= 1'b0;
             row_word_off_req_r     <= '0;
             row_word_off_rsp_r     <= '0;
             req_inflight_r         <= 1'b0;
             slot_valid_r           <= 1'b0;
             slot_fetching_r        <= 1'b0;
             slot_desc_a_row_base_r <= '0;
+            slot_desc_a_sub_off_r  <= '0;
             slot_step_k_r          <= '0;
             fetch_base_r           <= '0;
             slot_row_major_r       <= 1'b0;
@@ -286,20 +297,21 @@
                 fsm_state_r      <= S_IDLE;
                 req_ctr_r        <= '0;
                 rsp_ctr_r        <= '0;
+                req_hi_r         <= 1'b0;
+                rsp_hi_r         <= 1'b0;
                 req_inflight_r   <= 1'b0;
                 slot_valid_r     <= 1'b0;
                 slot_fetching_r  <= 1'b0;
                 refetched_for_first_compute_r <= 1'b0;
             end else begin
-                // Inflight tracker (single outstanding request at a time)
                 if (tcu_lmem_if.rsp_valid)
                     req_inflight_r <= 1'b0;
                 if (tcu_lmem_if.req_valid && tcu_lmem_if.req_ready)
                     req_inflight_r <= 1'b1;
 
-                // Latch descriptor fields on the first compute uop.
                 if (req_valid && is_first_compute_uop) begin
                     slot_desc_a_row_base_r <= desc_a_row_base;
+                    slot_desc_a_sub_off_r  <= desc_a_sub_off;
                     slot_ldm_words_r       <= desc_a_ldm_words;
                     slot_row_major_r       <= (desc_a_ldm_words != '0);
                 end
@@ -312,38 +324,47 @@
                 case (fsm_state_r)
                     S_IDLE: begin
                         if (alloc_en) begin
-                            fsm_state_r      <= S_FETCH;
-                            slot_fetching_r  <= 1'b1;
-                            slot_valid_r     <= 1'b0;
-                            slot_step_k_r    <= req_step_k_trunc;
-                            slot_is_sparse_r  <= req_is_sparse;
-                            // Row-major base is the A_warp start bank-row (no
-                            // step_k offset; per-row arithmetic derives the
-                            // exact LMEM addr). Block-major base is the stripe
-                            // origin (step_k already factored in).
-                            fetch_base_r     <= effective_row_major
+                            fsm_state_r        <= S_FETCH;
+                            slot_fetching_r    <= 1'b1;
+                            slot_valid_r       <= 1'b0;
+                            slot_step_k_r      <= req_step_k_trunc;
+                            slot_is_sparse_r   <= req_is_sparse;
+                            fetch_base_r       <= effective_row_major
                                 ? effective_desc_a_row_base
                                 : stripe_base;
-                            req_ctr_r        <= '0;
-                            rsp_ctr_r        <= '0;
+                            req_ctr_r          <= '0;
+                            rsp_ctr_r          <= '0;
+                            req_hi_r           <= 1'b0;
+                            rsp_hi_r           <= 1'b0;
                             row_word_off_req_r <= row_word_off_init;
                             row_word_off_rsp_r <= row_word_off_init;
-                            req_inflight_r   <= 1'b0;
+                            req_inflight_r     <= 1'b0;
                         end
                     end
                     S_FETCH: begin
                         if (tcu_lmem_if.req_valid && tcu_lmem_if.req_ready) begin
-                            req_ctr_r <= req_ctr_r + FETCH_CTR_W'(1);
-                            row_word_off_req_r <= row_word_off_req_r + ROW_OFF_W'(slot_ldm_words_r);
+                            if (req_spans_two && !req_hi_r) begin
+                                req_hi_r <= 1'b1;
+                            end else begin
+                                req_hi_r           <= 1'b0;
+                                req_ctr_r          <= req_ctr_r + FETCH_CTR_W'(1);
+                                row_word_off_req_r <= row_word_off_req_r + ROW_OFF_W'(slot_ldm_words_r);
+                            end
                         end
                         if (last_rsp) begin
                             fsm_state_r     <= S_IDLE;
                             slot_fetching_r <= 1'b0;
                             slot_valid_r    <= 1'b1;
                             req_inflight_r  <= 1'b0;
+                            rsp_hi_r        <= 1'b0;
                         end else if (tcu_lmem_if.rsp_valid) begin
-                            rsp_ctr_r <= rsp_ctr_r + FETCH_CTR_W'(1);
-                            row_word_off_rsp_r <= row_word_off_rsp_r + ROW_OFF_W'(slot_ldm_words_r);
+                            if (rsp_spans_two && !rsp_hi_r) begin
+                                rsp_hi_r <= 1'b1;
+                            end else begin
+                                rsp_hi_r           <= 1'b0;
+                                rsp_ctr_r          <= rsp_ctr_r + FETCH_CTR_W'(1);
+                                row_word_off_rsp_r <= row_word_off_rsp_r + ROW_OFF_W'(slot_ldm_words_r);
+                            end
                         end
                     end
                     default: fsm_state_r <= S_IDLE;
@@ -352,46 +373,65 @@
         end
     end
 
-    // -----------------------------------------------------------------------
-    // Storage (LUTRAM): A_STRIPE_BANK_ROWS × NUM_BANKS 32-bit words.
-    // Each LMEM response writes one bank-row at offset rsp_ctr_r.
-    // -----------------------------------------------------------------------
-
     logic [A_STRIPE_WORDS*32-1:0] storage_wdata;
     logic [A_STRIPE_WORDS-1:0]    storage_wren;
 
-    // Row-major per-response decoding: the row being written is rsp_ctr_r,
-    // and its tcK source words start at lane = row_word_off & (BANK_ROW_WORDS-1)
-    // within the LMEM response (registered accumulator, see above).
-    wire [BANK_ROW_WORDS_LOG2:0] row_lane_rsp = (BANK_ROW_WORDS_LOG2+1)'(
-        row_word_off_rsp_r & ROW_OFF_W'(BANK_ROW_WORDS - 1));
+    // Pre-extract the current row's k_words slice ONCE from the LMEM response,
+    // avoiding 32x replicated barrel shifters and dynamic index multiplies.
+    logic [TCU_WG_FEDP_K-1:0][31:0] rm_slice_wdata;
+    logic [TCU_WG_FEDP_K-1:0]       rm_slice_wren;
+    always_comb begin
+        rm_slice_wdata = '0;
+        rm_slice_wren  = '0;
+        for (int k = 0; k < TCU_WG_FEDP_K; ++k) begin
+            automatic int raw_src = int'(rsp_lane_w) + k;
+            if (!rsp_hi_r && raw_src < BANK_ROW_WORDS) begin
+                rm_slice_wren[k]  = 1'b1;
+                rm_slice_wdata[k] = tcu_lmem_if.rsp_data.data[raw_src * 32 +: 32];
+            end else if (rsp_hi_r && raw_src >= BANK_ROW_WORDS && (raw_src - BANK_ROW_WORDS) < BANK_ROW_WORDS) begin
+                rm_slice_wren[k]  = 1'b1;
+                rm_slice_wdata[k] = tcu_lmem_if.rsp_data.data[(raw_src - BANK_ROW_WORDS) * 32 +: 32];
+            end
+        end
+    end
 
     always_comb begin
         storage_wdata = '0;
         storage_wren  = '0;
         if (in_fetch && tcu_lmem_if.rsp_valid) begin
             if (slot_row_major_r) begin
-                // Row-major: write k_words of row rsp_ctr_r into
-                // storage[rsp_ctr_r * k_words .. + k_words). Source words start
-                // at row_lane_rsp inside the LMEM response.
-                for (int k = 0; k < TCU_WG_FEDP_K; ++k) begin
-                    automatic int dst = int'(rsp_ctr_r) * int'(row_k_words) + k;
-                    automatic int src = int'(row_lane_rsp) + k;
-                    if (k < int'(row_k_words) && dst < A_STRIPE_WORDS && src < BANK_ROW_WORDS) begin
-                        storage_wren[dst] = 1'b1;
-                        storage_wdata[dst * 32 +: 32] =
-                            tcu_lmem_if.rsp_data.data[src * 32 +: 32];
+                for (int r = 0; r < A_TOTAL_ROWS; ++r) begin
+                    if (rsp_ctr_r == FETCH_CTR_W'(r)) begin
+                        if (slot_is_sparse_r) begin
+                            for (int k = 0; k < TCU_TC_K; ++k) begin
+                                automatic int dst_sp = (r / TCU_TC_M) * BLOCK_WORDS_PADDED_SP
+                                                     + (r % TCU_TC_M) * TCU_TC_K + k;
+                                if (dst_sp < A_STRIPE_WORDS && rm_slice_wren[k]) begin
+                                    storage_wren[dst_sp]             = 1'b1;
+                                    storage_wdata[dst_sp * 32 +: 32] = rm_slice_wdata[k];
+                                end
+                            end
+                        end else begin
+                            for (int k = 0; k < TCU_WG_FEDP_K; ++k) begin
+                                automatic int dst_dn = r * TCU_WG_FEDP_K + k;
+                                if (dst_dn < A_STRIPE_WORDS && rm_slice_wren[k]) begin
+                                    storage_wren[dst_dn]             = 1'b1;
+                                    storage_wdata[dst_dn * 32 +: 32] = rm_slice_wdata[k];
+                                end
+                            end
+                        end
                     end
                 end
             end else begin
-                // Block-major: one LMEM response carries BANK_ROW_WORDS
-                // 32-bit words (= NUM_BANKS * XLEN_RATIO). Store all of them
-                // starting at the current LMEM-row offset within the stripe.
-                for (int b = 0; b < BANK_ROW_WORDS; ++b) begin
-                    if (int'(rsp_ctr_r) * BANK_ROW_WORDS + b < A_STRIPE_WORDS) begin
-                        storage_wren[int'(rsp_ctr_r) * BANK_ROW_WORDS + b] = 1'b1;
-                        storage_wdata[(int'(rsp_ctr_r) * BANK_ROW_WORDS + b) * 32 +: 32] =
-                            tcu_lmem_if.rsp_data.data[b * 32 +: 32];
+                for (int rr = 0; rr < A_STRIPE_LMEM_ROWS; ++rr) begin
+                    if (rsp_ctr_r == FETCH_CTR_W'(rr)) begin
+                        for (int b = 0; b < BANK_ROW_WORDS; ++b) begin
+                            if (rr * BANK_ROW_WORDS + b < A_STRIPE_WORDS) begin
+                                storage_wren[rr * BANK_ROW_WORDS + b] = 1'b1;
+                                storage_wdata[(rr * BANK_ROW_WORDS + b) * 32 +: 32] =
+                                    tcu_lmem_if.rsp_data.data[b * 32 +: 32];
+                            end
+                        end
                     end
                 end
             end

--- a/environment/public/code/VX_tcu_bbuf.sv (Buggy Starter)
+++ b/solution/gold/code/VX_tcu_bbuf.sv (Golden Reference)
@@ -168,59 +168,41 @@
     // -----------------------------------------------------------------------
 
     localparam DESC_ADDR_W = BANK_ADDR_WIDTH + BANK_SEL_BITS;
+    localparam SUB_OFF_W   = `UP(BANK_SEL_BITS);
     wire [DESC_ADDR_W-1:0]      desc_b_word_base = DESC_ADDR_W'(req_desc_b[15:0] >> WORD_SIZE_LOG2);
     wire [BANK_ADDR_WIDTH-1:0]  desc_b_row_base  = desc_b_word_base[BANK_SEL_BITS +: BANK_ADDR_WIDTH];
-    // desc_b's upper 16 bits encode the per-row byte stride (WGMMA
-    // SS-descriptor `ldm`). Non-zero stride selects the K-major fetch path.
+    wire [SUB_OFF_W-1:0]        desc_b_sub_off   = (BANK_SEL_BITS > 0) ? desc_b_word_base[SUB_OFF_W-1:0] : '0;
     wire [LDM_W-1:0] desc_b_ldm_words = LDM_W'(req_desc_b[31:16] >> 2);
     if (`VX_CFG_XLEN > 32) begin : g_desc_b_upper_unused
         `UNUSED_VAR (req_desc_b[`VX_CFG_XLEN-1:32])
     end
-    if (BANK_SEL_BITS > 0) begin : g_addr_lsb_unused
-        `UNUSED_VAR (desc_b_word_base[BANK_SEL_BITS-1:0])
-    end
-
-    // -----------------------------------------------------------------------
-    // Resident slots
-    //   slot A: holds k_blk=0 bank-row (dense uses this exclusively)
-    //   slot B: holds k_blk=1 bank-row (sparse only)
-    // -----------------------------------------------------------------------
 
     logic                       slot_a_valid_r;
     logic [BANK_ADDR_WIDTH-1:0] slot_a_addr_r;
     logic [BANK_ADDR_WIDTH-1:0] slot_desc_b_row_base_r;
+    logic [SUB_OFF_W-1:0]       slot_desc_b_sub_off_r;
     logic                       slot_fetching_r;
-    // Dense within-physical-bank-row half (XLEN>32 only).
     logic [SUB_HALF_W-1:0]      slot_a_sub_half_r;
-    // Second slot for sparse blocks spanning two logical rows.
     logic                       slot_b_valid_r;
     logic [BANK_ADDR_WIDTH-1:0] slot_b_addr_r;
     logic [SUB_HALF_W-1:0]      slot_b_sub_half_r;
-    // Mode the slot pair was filled under (sparse vs dense). On mode
-    // transition for the same warpgroup we must refill.
     logic                       slot_is_sparse_r;
-    // K-major mode + per-WGMMA latched fields. Descriptor fields are latched
-    // on setup; per-compute step fields are latched when a fetch is allocated.
     logic                       slot_row_major_r;
     logic [LDM_W-1:0]           slot_ldm_words_r;
     logic [3:0]                 slot_step_k_r;
     logic [3:0]                 slot_step_n_r;
     logic [NCTA_WIDTH-1:0]      slot_cta_id_r;
-    // K-major descriptors can point to storage rewritten between WGMMA instructions.
     logic                       refetched_for_first_uop_r;
-    // K-major multi-fetch counters (count up to TCU_TC_N requests / responses
-    // per WGMMA uop, one per N-row of the (step_k, step_n) block).
     logic [KM_CTR_W-1:0]        km_req_ctr_r;
     logic [KM_CTR_W-1:0]        km_rsp_ctr_r;
-
-    // The WGMMA wrapper supplies the setup-latched descriptor on compute uops.
+    logic                       km_req_hi_r;
+    logic                       km_rsp_hi_r;
+
     `UNUSED_VAR (req_step_m)
     wire [BANK_ADDR_WIDTH-1:0] effective_desc_b_row_base =
         req_is_first_uop ? desc_b_row_base : slot_desc_b_row_base_r;
-    // K-major slot fields (slot_row_major_r / slot_ldm_words_r /
-    // slot_step_k_r / slot_step_n_r) are latched at alloc_en — see the
-    // always_ff below. The K-major addressing arithmetic reads them
-    // directly. desc_b_ldm_words on the bus is used only for setup.
+    wire [SUB_OFF_W-1:0]       effective_desc_b_sub_off =
+        req_is_first_uop ? desc_b_sub_off : slot_desc_b_sub_off_r;
 
     // Per-mode fetch addresses.
     wire [BANK_ADDR_WIDTH-1:0] fetch_addr_dense =
@@ -233,33 +215,31 @@
     wire [BANK_ADDR_WIDTH-1:0] fetch_addr_a =
         req_is_sparse ? fetch_addr_a_sparse : fetch_addr_dense;
 
+    wire bm_coherent = !slot_row_major_r
+                    && (!req_is_first_uop || refetched_for_first_uop_r)
+                    && (slot_cta_id_r == req_cta_id);
+
     wire bank_row_resident_dense =
-        slot_a_valid_r && !slot_is_sparse_r
+        slot_a_valid_r && !slot_is_sparse_r && bm_coherent
         && (slot_a_addr_r == fetch_addr_dense)
         && (slot_a_sub_half_r == dense_sub_half);
 
     wire bank_row_resident_sparse =
-        slot_a_valid_r && slot_is_sparse_r
+        slot_a_valid_r && slot_is_sparse_r && bm_coherent
         && (slot_a_addr_r == fetch_addr_a_sparse)
         && (slot_a_sub_half_r == sp_sub_a)
         && (!SPARSE_TWO_SLOT || (slot_b_valid_r
                                  && (slot_b_addr_r == fetch_addr_b_sparse)
                                  && (slot_b_sub_half_r == sp_sub_b)));
 
-    // K-major residency (dense + sparse): same (step_k, step_n) already in
-    // the slot pair. For sparse, 
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/VX_bits_insert.sv`](environment/public/code/VX_bits_insert.sv) *(Read-Only Context)*
- [`environment/public/code/VX_bits_remove.sv`](environment/public/code/VX_bits_remove.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cache_define.vh`](environment/public/code/VX_cache_define.vh) *(Read-Only Context)*
- [`environment/public/code/VX_config.vh`](environment/public/code/VX_config.vh) *(Read-Only Context)*
- [`environment/public/code/VX_csa_32.sv`](environment/public/code/VX_csa_32.sv) *(Read-Only Context)*
- [`environment/public/code/VX_csa_42.sv`](environment/public/code/VX_csa_42.sv) *(Read-Only Context)*
- [`environment/public/code/VX_csa_tree.sv`](environment/public/code/VX_csa_tree.sv) *(Read-Only Context)*
- [`environment/public/code/VX_cyclic_arbiter.sv`](environment/public/code/VX_cyclic_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_define.vh`](environment/public/code/VX_define.vh) *(Read-Only Context)*
- [`environment/public/code/VX_demux.sv`](environment/public/code/VX_demux.sv) *(Read-Only Context)*
- [`environment/public/code/VX_dp_ram.sv`](environment/public/code/VX_dp_ram.sv) *(Read-Only Context)*
- [`environment/public/code/VX_elastic_buffer.sv`](environment/public/code/VX_elastic_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_execute_if.sv`](environment/public/code/VX_execute_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_fifo_queue.sv`](environment/public/code/VX_fifo_queue.sv) *(Read-Only Context)*
- [`environment/public/code/VX_find_first.sv`](environment/public/code/VX_find_first.sv) *(Read-Only Context)*
- [`environment/public/code/VX_generic_arbiter.sv`](environment/public/code/VX_generic_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_gpu_pkg.sv`](environment/public/code/VX_gpu_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/VX_gto_arbiter.sv`](environment/public/code/VX_gto_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_ibuffer_if.sv`](environment/public/code/VX_ibuffer_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_ks_adder.sv`](environment/public/code/VX_ks_adder.sv) *(Read-Only Context)*
- [`environment/public/code/VX_lzc.sv`](environment/public/code/VX_lzc.sv) *(Read-Only Context)*
- [`environment/public/code/VX_matrix_arbiter.sv`](environment/public/code/VX_matrix_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_mem_bus_arb.sv`](environment/public/code/VX_mem_bus_arb.sv) *(Read-Only Context)*
- [`environment/public/code/VX_mem_bus_if.sv`](environment/public/code/VX_mem_bus_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_onehot_encoder.sv`](environment/public/code/VX_onehot_encoder.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pending_size.sv`](environment/public/code/VX_pending_size.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pipe_buffer.sv`](environment/public/code/VX_pipe_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pipe_register.sv`](environment/public/code/VX_pipe_register.sv) *(Read-Only Context)*
- [`environment/public/code/VX_platform.vh`](environment/public/code/VX_platform.vh) *(Read-Only Context)*
- [`environment/public/code/VX_popcount.sv`](environment/public/code/VX_popcount.sv) *(Read-Only Context)*
- [`environment/public/code/VX_priority_arbiter.sv`](environment/public/code/VX_priority_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_priority_encoder.sv`](environment/public/code/VX_priority_encoder.sv) *(Read-Only Context)*
- [`environment/public/code/VX_result_if.sv`](environment/public/code/VX_result_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_rr_arbiter.sv`](environment/public/code/VX_rr_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scan.sv`](environment/public/code/VX_scan.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scope.vh`](environment/public/code/VX_scope.vh) *(Read-Only Context)*
- [`environment/public/code/VX_stream_arb.sv`](environment/public/code/VX_stream_arb.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_buffer.sv`](environment/public/code/VX_stream_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_stream_switch.sv`](environment/public/code/VX_stream_switch.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_abuf.sv`](environment/public/code/VX_tcu_abuf.sv) **(Editable)**
- [`environment/public/code/VX_tcu_bbuf.sv`](environment/public/code/VX_tcu_bbuf.sv) **(Editable)**
- [`environment/public/code/VX_tcu_core.sv`](environment/public/code/VX_tcu_core.sv) **(Editable)**
- [`environment/public/code/VX_tcu_fedp_tfr.sv`](environment/public/code/VX_tcu_fedp_tfr.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_lockstep.sv`](environment/public/code/VX_tcu_lockstep.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_meta.sv`](environment/public/code/VX_tcu_meta.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_pkg.sv`](environment/public/code/VX_tcu_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_sp_mux.sv`](environment/public/code/VX_tcu_sp_mux.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_subsys.sv`](environment/public/code/VX_tcu_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tbuf.sv`](environment/public/code/VX_tcu_tbuf.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_acc.sv`](environment/public/code/VX_tcu_tfr_acc.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_align.sv`](environment/public/code/VX_tcu_tfr_align.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_classifier.sv`](environment/public/code/VX_tcu_tfr_classifier.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_exc_reduce.sv`](environment/public/code/VX_tcu_tfr_exc_reduce.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_lane_mask.sv`](environment/public/code/VX_tcu_tfr_lane_mask.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_max_exp.sv`](environment/public/code/VX_tcu_tfr_max_exp.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_mul_f16.sv`](environment/public/code/VX_tcu_tfr_mul_f16.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_mul_f8.sv`](environment/public/code/VX_tcu_tfr_mul_f8.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_mul_i4.sv`](environment/public/code/VX_tcu_tfr_mul_i4.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_mul_i8.sv`](environment/public/code/VX_tcu_tfr_mul_i8.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_mul_join.sv`](environment/public/code/VX_tcu_tfr_mul_join.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_norm_round.sv`](environment/public/code/VX_tcu_tfr_norm_round.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_pipe_register.sv`](environment/public/code/VX_tcu_tfr_pipe_register.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_shared_mul.sv`](environment/public/code/VX_tcu_tfr_shared_mul.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_tfr_wmul.sv`](environment/public/code/VX_tcu_tfr_wmul.sv) *(Read-Only Context)*
- [`environment/public/code/VX_tcu_uops.sv`](environment/public/code/VX_tcu_uops.sv) **(Editable)**
- [`environment/public/code/VX_tcu_wgmma.sv`](environment/public/code/VX_tcu_wgmma.sv) *(Read-Only Context)*
- [`environment/public/code/VX_types.vh`](environment/public/code/VX_types.vh) *(Read-Only Context)*
- [`environment/public/code/VX_uop_packld.sv`](environment/public/code/VX_uop_packld.sv) *(Read-Only Context)*
- [`environment/public/code/VX_uop_sequencer.sv`](environment/public/code/VX_uop_sequencer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_wallace_mul.sv`](environment/public/code/VX_wallace_mul.sv) *(Read-Only Context)*
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

