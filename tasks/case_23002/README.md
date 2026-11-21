# `case_23002`: SIMT Warp Control-Flow Divergence, IPDOM Stack Unwinding, and Multi-Packet Mask Coherency

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_23002` |
| **Source Silicon Repository** | `vortexgpgpu/vortex` (`repo_37`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/VX_wctl_unit.sv`](environment/public/code/VX_wctl_unit.sv), [`code/VX_split_join.sv`](environment/public/code/VX_split_join.sv), [`code/VX_ipdom_stack.sv`](environment/public/code/VX_ipdom_stack.sv) (3 files, 421 LOC) |
| **Public Subsystem Context** | 28 RTL files (7842 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `840s` total (`420s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# SIMT Warp Control-Flow Divergence, IPDOM Stack Unwinding, and Multi-Packet Mask Coherency

In Vortex's SIMT warp control subsystem (`code/VX_wctl_unit.sv`, `code/VX_split_join.sv`, and `code/VX_ipdom_stack.sv`, integrated in `code/VX_wctl_ipdom_top.sv`), multi-warp SFU control instructions manage per-warp thread masks, warp spawning, barrier synchronization, and Immediate Post-Dominator (IPDOM) branch divergence and reconvergence. Currently, the subsystem exhibits multi-packet mask corruption under warp interleaving and backpressure, wrong scalar operand lane selection when lane 0 is inactive, incorrect branch serialization and reconvergence masks, stale divergence stack pointers across back-to-back splits, and stack corruption during nested or early multi-level reconvergence.

Update **only** `code/VX_wctl_unit.sv`, `code/VX_split_join.sv`, and `code/VX_ipdom_stack.sv` (preserving all module port and parameter interfaces) so the subsystem satisfies the following architectural contracts:

1. **Multi-Packet Thread-Mask Gathering & Scalar Control Extraction**:
   - Extract scalar `rs1`/`rs2` control operands from the highest-indexed active lane in the packet's `tmask` (`NUM_LANES == 1` uses lane `0`).
   - Evaluate per-lane branch/predicate conditions from `rs1[lane][0]` (inverted when `is_cond_neg` is set). Across multi-packet warps (`sop`..`eop`, `NUM_THREADS > NUM_LANES`), maintain independent per-warp `then` and `else` masks across interleaved warps and stalled cycles, committing control actions only on the final accepted sub-packet.

2. **Smaller-Branch-First Divergence & Coherent Stack-Pointer Writeback**:
   - Diverge on `SPLIT` (`split.is_dvg = 1`) only when both `then` and `else` masks are non-zero. Serialize the branch with the smaller active thread popcount first into `split.then_tmask` and the larger into `split.else_tmask` (ties execute `then` first), saving `PC + 4` as the fallthrough PC.
   - Return the warp's pre-push IPDOM stack pointer via `result_if` on non-barrier-arrive control instructions, remaining coherent across back-to-back same-warp divergent `SPLIT`s and cross-warp interleaving.

3. **Compiler-Guided IPDOM Reconvergence & Early Multi-Frame Unwinding**:
   - Each `JOIN` supplies via `sjoin.stack_ptr` (from scalar `rs1`) the pre-push stack pointer returned by its matching `SPLIT`. When no live stack frames exist above `sjoin.stack_ptr`, treat the `JOIN` as non-divergent (`join_is_dvg = 0`).
   - Otherwise, on the first `JOIN` targeting that frame, transition execution to that split's remaining untaken threads (`join_is_else = 1`) at its saved fallthrough PC while unwinding any skipped inner frames above it; on the second `JOIN` targeting that frame, restore the pre-split active thread mask (`join_is_else = 0`) and pop the frame itself.

4. **Control ISA Preservation & Multi-Configuration Signoff**:
   - Preserve `TMC`, `PRED`, `WSPAWN`, `WSYNC` drain stalling, and synchronous/arrive/`expect_tx`/asynchronous `BAR` behaviors.
   - Must pass verification under `(NUM_WARPS=4, NUM_THREADS=8, NUM_LANES=2)` and `(NUM_WARPS=8, NUM_THREADS=4, NUM_LANES=4)` and synthesize cleanly without latches or combinational loops on `VX_wctl_ipdom_top`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment

## Editable RTL Files
- `code/VX_wctl_unit.sv`
- `code/VX_split_join.sv`
- `code/VX_ipdom_stack.sv`

## Integration Top & Read-Only Closure
- Top-level integration wrapper: `code/VX_wctl_ipdom_top.sv`
- Supporting headers, packages, interfaces, and library primitives are provided in `code/`.

## Example Synthesis & Lint Commands
```bash
# Yosys + slang latch-free synthesis check (multi-packet SIMT config)
yosys -m slang -p "
  read_slang -DASIC -DSYNTHESIS -DVX_CFG_XLEN=32 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_SFU_LANES=2     -Icode code/VX_gpu_pkg.sv code/VX_execute_if.sv code/VX_txbar_bus_if.sv code/VX_warp_ctl_if.sv code/VX_result_if.sv     code/VX_dp_ram_asic.v code/VX_scan.sv code/VX_find_first.sv code/VX_lzc.sv code/VX_onehot_encoder.sv code/VX_priority_encoder.sv     code/VX_popcount.sv code/VX_pipe_register.sv code/VX_pipe_buffer.sv code/VX_stream_buffer.sv code/VX_async_ram_patch.sv     code/VX_dp_ram.sv code/VX_fifo_queue.sv code/VX_elastic_buffer.sv     code/VX_ipdom_stack.sv code/VX_split_join.sv code/VX_wctl_unit.sv code/VX_wctl_ipdom_top.sv --top VX_wctl_ipdom_top;
  hierarchy -check -top VX_wctl_ipdom_top; proc; opt_clean; check -assert; select -assert-none */t:\$dlatch*
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/VX_wctl_unit.sv (Buggy Starter)
+++ b/solution/gold/code/VX_wctl_unit.sv (Golden Reference)
@@ -20,15 +20,16 @@
     input wire              clk,
     input wire              reset,
 
-
+    // Inputs
     VX_execute_if.slave     execute_if,
     VX_txbar_bus_if.slave   txbar_bus_if,
 
-
+    // Outputs
     VX_warp_ctl_if.master   warp_ctl_if,
     VX_result_if.master     result_if
 );
     `UNUSED_SPARAM (INSTANCE_ID)
+    localparam LANE_BITS  = `CLOG2(NUM_LANES);
     localparam PID_BITS   = `CLOG2(`VX_CFG_NUM_THREADS / NUM_LANES);
     localparam WCTL_WIDTH = $bits(tmc_t) + $bits(wspawn_t) + $bits(split_t) + $bits(join_t) + $bits(barrier_t);
 
@@ -48,11 +49,27 @@
     wire is_bar    = (execute_if.data.op_type == INST_SFU_BAR);
     wire is_wsync  = (execute_if.data.op_type == INST_SFU_WSYNC);
 
+    wire execute_fire;
     wire wctl_valid;
     wire wspawn_valid, tmc_valid, split_valid, sjoin_valid, bar_valid, wsync_valid;
 
-    wire [`VX_CFG_XLEN-1:0] rs1_data = execute_if.data.rs1_data[0];
-    wire [`VX_CFG_XLEN-1:0] rs2_data = execute_if.data.rs2_data[0];
+    wire [`UP(LANE_BITS)-1:0] last_tid;
+    if (LANE_BITS != 0) begin : g_last_tid
+        VX_priority_encoder #(
+            .N       (NUM_LANES),
+            .REVERSE (1)
+        ) last_tid_select (
+            .data_in   (execute_if.data.header.tmask),
+            .index_out (last_tid),
+            `UNUSED_PIN (onehot_out),
+            `UNUSED_PIN (valid_out)
+        );
+    end else begin : g_no_tid
+        assign last_tid = 0;
+    end
+
+    wire [`VX_CFG_XLEN-1:0] rs1_data = execute_if.data.rs1_data[last_tid];
+    wire [`VX_CFG_XLEN-1:0] rs2_data = execute_if.data.rs2_data[last_tid];
 
     wire not_pred = execute_if.data.op_args.wctl.is_cond_neg;
 
@@ -65,21 +82,21 @@
     logic [`VX_CFG_NUM_THREADS-1:0] else_tmask;
 
     if (PID_BITS != 0) begin : g_pid
-        reg [2*`VX_CFG_NUM_THREADS-1:0] tmask_r;
+        reg [`VX_CFG_NUM_WARPS-1:0][2*`VX_CFG_NUM_THREADS-1:0] tmask_table;
+
+        wire [2*`VX_CFG_NUM_THREADS-1:0] tmask_r = tmask_table[execute_if.data.header.wid];
 
         always @(*) begin
             {else_tmask, then_tmask} = execute_if.data.header.sop ? '0 : tmask_r;
             then_tmask[execute_if.data.header.pid * NUM_LANES +: NUM_LANES] = taken & execute_if.data.header.tmask;
-            for (integer j = 0; j < NUM_LANES; ++j) begin
-                else_tmask[execute_if.data.header.pid * NUM_LANES + j] = ~execute_if.data.rs1_data[j][0] & execute_if.data.header.tmask[j];
-            end
+            else_tmask[execute_if.data.header.pid * NUM_LANES +: NUM_LANES] = ~taken & execute_if.data.header.tmask;
         end
 
         always @(posedge clk) begin
             if (reset) begin
-                tmask_r <= '0;
-            end else if (execute_if.valid) begin
-                tmask_r <= {else_tmask, then_tmask};
+                tmask_table <= '0;
+            end else if (execute_fire) begin
+                tmask_table[execute_if.data.header.wid] <= {else_tmask, then_tmask};
             end
         end
     end else begin : g_no_pid
@@ -90,24 +107,31 @@
     wire has_then = (then_tmask != 0);
     wire has_else = (else_tmask != 0);
 
-
+    // tmc / pred
     wire [`VX_CFG_NUM_THREADS-1:0] pred_mask = has_then ? then_tmask : rs2_data[`VX_CFG_NUM_THREADS-1:0];
     assign tmc_valid = wctl_valid && (is_tmc || is_pred);
     assign tmc.tmask = is_pred ? pred_mask : rs1_data[`VX_CFG_NUM_THREADS-1:0];
 
+    // split
+    wire [`CLOG2(`VX_CFG_NUM_THREADS+1)-1:0] then_tmask_cnt, else_tmask_cnt;
+    `POP_COUNT(then_tmask_cnt, then_tmask);
+    `POP_COUNT(else_tmask_cnt, else_tmask);
+    wire then_first = (then_tmask_cnt <= else_tmask_cnt);
+    wire [`VX_CFG_NUM_THREADS-1:0] taken_tmask  = then_first ? then_tmask : else_tmask;
+    wire [`VX_CFG_NUM_THREADS-1:0] ntaken_tmask = then_first ? else_tmask : then_tmask;
 
     assign split_valid      = wctl_valid && is_split;
     assign split.is_dvg     = has_then && has_else;
-    assign split.then_tmask = then_tmask;
-    assign split.else_tmask = else_tmask;
+    assign split.then_tmask = taken_tmask;
+    assign split.else_tmask = ntaken_tmask;
     assign split.next_pc    = execute_if.data.header.PC + from_fullPC(`VX_CFG_XLEN'(4));
 
-
+    // join
     assign sjoin_valid     = wctl_valid && is_join;
     assign sjoin.tmask     = then_tmask | else_tmask;
     assign sjoin.stack_ptr = rs1_data[DV_STACK_SIZEW-1:0];
 
-
+    // barrier
     wire [BAR_ADDR_W-1:0] wctl_bar_addr;
     `CONCAT(wctl_bar_addr, rs1_data[NW_BITS-1:0], rs1_data[BAR_ID_SHIFT +: NB_BITS], NW_BITS, NB_BITS)
 
@@ -127,7 +151,7 @@
 
     assign txbar_bus_if.ready = ~wctl_bar_enable;
 
-
+    // wspawn
     wire [`VX_CFG_NUM_WARPS-1:0] wspawn_wmask;
     for (genvar i = 0; i < `VX_CFG_NUM_WARPS; ++i) begin : g_wspawn_wmask
         assign wspawn_wmask[i] = (i < rs1_data[NW_BITS:0]) && (i != execute_if.data.header.wid);
@@ -136,6 +160,7 @@
     assign wspawn.wmask = wspawn_wmask;
     assign wspawn.pc    = from_fullPC(rs2_data);
 
+    // Scheduler response setup
     assign warp_ctl_if.dvstack_wid = execute_if.data.header.wid;
     assign warp_ctl_if.bar_addr    = wctl_bar_enable ? wctl_bar_addr : txbar_bus_if.data.addr;
 
@@ -145,10 +170,9 @@
 
     wire rsp_buf_ready;
     assign execute_if.ready = rsp_buf_ready && !wsync_drain && !bar_drain;
-
-    wire execute_fire = execute_if.valid && execute_if.ready;
-    assign wctl_valid = execute_fire && execute_if.data.header.eop;
-    assign wsync_valid = wctl_valid && is_wsync;
+    assign execute_fire     = execute_if.valid && execute_if.ready;
+    assign wctl_valid       = execute_fire && execute_if.data.header.eop;
+    assign wsync_valid      = wctl_valid && is_wsync;
 
     VX_pipe_register #(
         .DATAW  (6 + NW_WIDTH + WCTL_WIDTH),
@@ -187,6 +211,14 @@
         })
     );
 
+    // Forward in-flight divergent SPLIT push on the same warp across the 1-cycle wctl_reg delay
+    wire inflight_same_wid_push = warp_ctl_if.split_valid
+                               && warp_ctl_if.split.is_dvg
+                               && (warp_ctl_if.wid == execute_if.data.header.wid);
+    wire [DV_STACK_SIZEW-1:0] dvstack_ptr_eff = inflight_same_wid_push
+                                              ? (warp_ctl_if.dvstack_ptr + DV_STACK_SIZEW'(1))
+                                              : warp_ctl_if.dvstack_ptr;
+
     wire [DV_STACK_SIZEW-1:0] dvstack_ptr_r;
     wire bar_rsp_valid = is_bar && execute_if.data.op_args.wctl.is_bar_arrive;
     wire bar_rsp_valid_r;
@@ -200,8 +232,8 @@
         .reset     (reset),
         .valid_in  (execute_if.valid && !wsync_drain && !bar_drain),
         .ready_in  (rsp_buf_ready),
-        .data_in   ({execute_if.data.header, warp_ctl_if.dvstack_ptr, warp_ctl_if.bar_phase, bar_rsp_valid}),
-        .data_out  ({result_if.data.header,  dvstack_ptr_r,           bar_phase_r,           bar_rsp_valid_r}),
+        .data_in   ({execute_if.data.header, dvstack_ptr_eff, warp_ctl_if.bar_phase, bar_rsp_valid}),
+        .data_out  ({result_if.data.header,  dvstack_ptr_r,   bar_phase_r,           bar_rsp_valid_r}),
         .valid_out (result_if.valid),
         .ready_out (result_if.ready)
     );

--- a/environment/public/code/VX_split_join.sv (Buggy Starter)
+++ b/solution/gold/code/VX_split_join.sv (Golden Reference)
@@ -34,7 +34,6 @@
     output wire [DV_STACK_SIZEW-1:0] stack_ptr
 );
     `UNUSED_SPARAM (INSTANCE_ID)
-    `UNUSED_VAR (stack_wid)
 
     if (NT_BITS != 0) begin : g_enable
         wire [`VX_CFG_NUM_WARPS-1:0][DV_STACK_SIZEW-1:0] ipdom_wr_ptr;
@@ -64,7 +63,7 @@
             `UNUSED_PIN (full)
         );
 
-        wire [`VX_CFG_NUM_THREADS-1:0] join_tmask_n = ipdom_idx ? orig_tmask : sjoin.tmask;
+        wire [`VX_CFG_NUM_THREADS-1:0] join_tmask_n = ipdom_idx ? orig_tmask : (~sjoin.tmask & orig_tmask);
 
         VX_pipe_register #(
             .DATAW  (1 + NW_WIDTH + 1 +  1 + `VX_CFG_NUM_THREADS + PC_BITS),
@@ -74,14 +73,15 @@
             .clk      (clk),
             .reset    (reset),
             .enable   (1'b1),
-            .data_in  ({sjoin_valid, wid,      sjoin_is_dvg, ipdom_idx,    join_tmask_n, next_pc}),
+            .data_in  ({sjoin_valid, wid,      sjoin_is_dvg, ~ipdom_idx,   join_tmask_n, next_pc}),
             .data_out ({join_valid,  join_wid, join_is_dvg,  join_is_else, join_tmask,   join_pc})
         );
 
-        assign stack_ptr = ipdom_wr_ptr[wid];
+        assign stack_ptr = ipdom_wr_ptr[stack_wid];
 
     end else begin : g_disable
-        `UNUSED_VAR ({clk, reset, split, sjoin, split_valid})
+
+        `UNUSED_VAR ({clk, reset, split, sjoin, stack_wid, split_valid})
         assign join_valid = sjoin_valid;
         assign join_wid = wid;
         assign join_is_dvg = 0;
@@ -89,6 +89,7 @@
         assign join_tmask = 1'b1;
         assign join_pc = '0;
         assign stack_ptr = '0;
+
     end
 
 endmodule

--- a/environment/public/code/VX_ipdom_stack.sv (Buggy Starter)
+++ b/solution/gold/code/VX_ipdom_stack.sv (Golden Reference)
@@ -35,8 +35,6 @@
     localparam BRAM_SIZE  = DEPTH * `VX_CFG_NUM_WARPS;
     localparam BRAW_ADDRW = `LOG2UP(BRAM_SIZE);
 
-    `UNUSED_VAR (rd_ptr)
-
     wire [`VX_CFG_NUM_WARPS-1:0][ADDRW-1:0] wr_ptr_w;
     wire [`VX_CFG_NUM_WARPS-1:0] empty_w, full_w;
 
@@ -46,6 +44,10 @@
 
         wire push_s = push && (wid == NW_WIDTH'(i));
         wire pop_s  = pop  && (wid == NW_WIDTH'(i));
+
+        `RUNTIME_ASSERT(~(push_s && full_r), ("runtime error: writing to a full stack!"));
+        `RUNTIME_ASSERT(~(pop_s && empty_r), ("runtime error: reading an empty stack!"));
+        `RUNTIME_ASSERT(~(push_s && pop_s),  ("runtime error: push and pop in same cycle not supported!"));
 
         always @(posedge clk) begin
             if (reset) begin
@@ -57,9 +59,9 @@
                 empty_r  <= 1'b0;
                 full_r   <= (ADDRW'(DEPTH - 1) == wr_ptr_r);
             end else if (pop_s) begin
-                wr_ptr_r <= wr_ptr_r - ADDRW'(1);
-                empty_r  <= (wr_ptr_r == ADDRW'(1));
-                full_r   <= 1'b0;
+                wr_ptr_r <= q_idx ? rd_ptr : (rd_ptr + ADDRW'(1));
+                empty_r  <= (rd_ptr == '0) && q_idx;
+                full_r   <= (rd_ptr == ADDRW'(DEPTH - 1)) && ~q_idx;
             end
         end
 
@@ -68,22 +70,23 @@
         assign full_w[i]   = full_r;
     end
 
-    wire [ADDRW-1:0] tos_ptr = wr_ptr_w[wid] - ADDRW'(1);
     wire [BRAW_ADDRW-1:0] raddr, waddr;
 
     if (DEPTH > 1 && `VX_CFG_NUM_WARPS > 1) begin : g_DW
-        assign waddr = push ? {wr_ptr_w[wid], wid} : {tos_ptr, wid};
-        assign raddr = {tos_ptr, wid};
+        assign waddr = push ? {wr_ptr_w[wid], wid} : {rd_ptr, wid};
+        assign raddr = {rd_ptr, wid};
     end else if (DEPTH > 1) begin : g_D
         `UNUSED_VAR (wid)
-        assign waddr = push ? wr_ptr_w[0] : tos_ptr;
-        assign raddr = tos_ptr;
+        assign waddr = push ? wr_ptr_w[0] : rd_ptr;
+        assign raddr = rd_ptr;
     end else if (`VX_CFG_NUM_WARPS > 1) begin : g_W
-        `UNUSED_VAR (tos_ptr)
+        `UNUSED_VAR (rd_ptr)
+        `UNUSED_VAR (wr_ptr_w)
         assign waddr = wid;
         assign raddr = wid;
     end else begin : g_none
-        `UNUSED_VAR (tos_ptr)
+        `UNUSED_VAR (rd_ptr)
+        `UNUSED_VAR (wr_ptr_w)
         `UNUSED_VAR (wid)
         assign waddr = '0;
         assign raddr = '0;
@@ -93,8 +96,8 @@
         .DATAW     (BRAM_DATAW),
         .SIZE      (BRAM_SIZE),
         .LUTRAM    (1),
-        .RDW_MODE  ("R"),
-        .RADDR_REG (1)
+        .RDW_MODE  ("W"),
+        .RADDR_REG (0)
     ) ipdom_store (
         .clk   (clk),
         .reset (reset),

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/VX_async_ram_patch.sv`](environment/public/code/VX_async_ram_patch.sv) *(Read-Only Context)*
- [`environment/public/code/VX_config.vh`](environment/public/code/VX_config.vh) *(Read-Only Context)*
- [`environment/public/code/VX_define.vh`](environment/public/code/VX_define.vh) *(Read-Only Context)*
- [`environment/public/code/VX_dp_ram.sv`](environment/public/code/VX_dp_ram.sv) *(Read-Only Context)*
- [`environment/public/code/VX_dp_ram_asic.v`](environment/public/code/VX_dp_ram_asic.v) *(Read-Only Context)*
- [`environment/public/code/VX_elastic_buffer.sv`](environment/public/code/VX_elastic_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_execute_if.sv`](environment/public/code/VX_execute_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_fifo_queue.sv`](environment/public/code/VX_fifo_queue.sv) *(Read-Only Context)*
- [`environment/public/code/VX_find_first.sv`](environment/public/code/VX_find_first.sv) *(Read-Only Context)*
- [`environment/public/code/VX_gpu_pkg.sv`](environment/public/code/VX_gpu_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/VX_ipdom_stack.sv`](environment/public/code/VX_ipdom_stack.sv) **(Editable)**
- [`environment/public/code/VX_lzc.sv`](environment/public/code/VX_lzc.sv) *(Read-Only Context)*
- [`environment/public/code/VX_onehot_encoder.sv`](environment/public/code/VX_onehot_encoder.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pipe_buffer.sv`](environment/public/code/VX_pipe_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_pipe_register.sv`](environment/public/code/VX_pipe_register.sv) *(Read-Only Context)*
- [`environment/public/code/VX_platform.vh`](environment/public/code/VX_platform.vh) *(Read-Only Context)*
- [`environment/public/code/VX_popcount.sv`](environment/public/code/VX_popcount.sv) *(Read-Only Context)*
- [`environment/public/code/VX_priority_encoder.sv`](environment/public/code/VX_priority_encoder.sv) *(Read-Only Context)*
- [`environment/public/code/VX_result_if.sv`](environment/public/code/VX_result_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scan.sv`](environment/public/code/VX_scan.sv) *(Read-Only Context)*
- [`environment/public/code/VX_scope.vh`](environment/public/code/VX_scope.vh) *(Read-Only Context)*
- [`environment/public/code/VX_split_join.sv`](environment/public/code/VX_split_join.sv) **(Editable)**
- [`environment/public/code/VX_stream_buffer.sv`](environment/public/code/VX_stream_buffer.sv) *(Read-Only Context)*
- [`environment/public/code/VX_txbar_bus_if.sv`](environment/public/code/VX_txbar_bus_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_types.vh`](environment/public/code/VX_types.vh) *(Read-Only Context)*
- [`environment/public/code/VX_warp_ctl_if.sv`](environment/public/code/VX_warp_ctl_if.sv) *(Read-Only Context)*
- [`environment/public/code/VX_wctl_ipdom_top.sv`](environment/public/code/VX_wctl_ipdom_top.sv) *(Read-Only Context)*
- [`environment/public/code/VX_wctl_unit.sv`](environment/public/code/VX_wctl_unit.sv) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

