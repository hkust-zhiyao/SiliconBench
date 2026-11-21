# `case_5007`: CVA6 Non-Blocking DCache Tag Arbiter Grant Exclusivity, Pipelined Store/Kill Control, Miss-Handler Multi-Way/32b-AMO Completion, and Area/Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_5007` |
| **Source Silicon Repository** | `openhwfoundation/cva6` (`repo_05`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `arithmetic_datapath`, `gatelevel_physical_effects`, `protocol_control`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/cache_ctrl.sv`](environment/public/code/cache_ctrl.sv), [`code/miss_handler.sv`](environment/public/code/miss_handler.sv), [`code/tag_cmp.sv`](environment/public/code/tag_cmp.sv) (3 files, 1450 LOC) |
| **Public Subsystem Context** | 18 RTL files (6499 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CVA6 Non-Blocking DCache SRAM Arbiter Exclusivity, Pipelined Store/Kill Handshake, Multi-Way Eviction/AMO Completion, and Area/Timing Closure

In the CVA6 non-blocking L1 data cache subsystem (`code/std_nbdcache.sv`, `code/cache_ctrl.sv`, `code/miss_handler.sv`, and `code/tag_cmp.sv`), concurrent port arbitration, pipelined load-to-store requests, killed cache misses, multi-way flushes/evictions, and 32-bit atomic operations fail under verification and synthesis/timing sign-off:

1. **SRAM arbiter grant exclusivity and idle behavior (`code/tag_cmp.sv`)**:
   - Across the `NR_PORTS` cache ports (`0` highest priority to `NR_PORTS-1` lowest priority), `tag_cmp` must grant at most one requesting port per cycle (`$onehot0(gnt_o)`) and select that port's tag on the following cycle. Idle higher-priority ports (`req_i[k] == '0`) must never receive `gnt_o[k] = 1'b1` when a lower-priority port requests, and when all ports are idle (`req_i == '0`) `gnt_o`, `req_o`, and `we_o` must remain deasserted with no hit reported on the next cycle.

2. **Pipelined store double-grant, flush-gated speculative reads, and ungranted killed miss cancellation (`code/cache_ctrl.sv`)**:
   - Read requests receive `req_port_o.data_gnt = 1'b1` upon SRAM read acceptance, whereas write requests (`req_port_i.data_we == 1'b1`) must only receive `req_port_o.data_gnt = 1'b1` when the write completes in the store stage or is accepted by the miss/bypass unit. Currently, when a write request is presented on `req_port_i` on the cycle a preceding load hits or receives its critical word, `cache_ctrl` asserts `req_port_o.data_gnt = 1'b1` prematurely and then grants the same write a second time when it completes.
   - While waiting for a refill critical word, speculative SRAM read requests for a new `req_port_i.data_req` must be suppressed when `flush_i` is asserted.
   - If `req_port_i.kill_req` is asserted while waiting for a refill/bypass grant and the miss unit has not yet granted or begun serving the port (`!active_serving_i && !miss_gnt_i && !bypass_gnt_i`), `cache_ctrl` must suppress `miss_req_o.valid` (`1'b0`), acknowledge the kill with `req_port_o.data_rvalid = 1'b1`, and return to idle on that cycle.

3. **2-way LFSR sizing, multi-way SRAM requests, flush/AMO priority, and same-cycle 32-bit AMO/bypass completion (`code/miss_handler.sv`)**:
   - The miss handler must elaborate cleanly for `DCACHE_SET_ASSOC = 2` as well as `4`, drive `req_o` across all ways (`'1`) during cache initialization and clean-line flush scans, and drive `req_o` for the evicted way (`evict_way_q`) when clearing status on writeback completion.
   - When `flush_i` and `amo_req_i.req` are both asserted while idle (`!busy_i`), `flush_i` takes precedence and must assert `flush_ack_o` upon completion rather than suppressing `flush_ack_o` as an AMO-internal flush.
   - When an atomic request or bypass arbiter request receives both grant and valid response on the same cycle, 32-bit AMOs (`amo_req_i.size == 2'b10`) must still extract the addressed 32-bit half (`amo_req_i.operand_a[2]`) and sign-extend it to 64 bits on `amo_resp_o.result`, and `axi_adapter_arbiter` must immediately forward the response to the requester and return to idle with zero outstanding count.

4. **Synthesis, area, and timing closure**:
   - Both `std_nbdcache` and `dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) must synthesize under Yosys + Slang with zero inferred latches.
   - When `dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) is synthesized against Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`) and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`) as documented in `BUILD.md`, mapped cell area must be **`<= 2,825.0 um^2`** and setup/hold slack must be **`>= 0.00 ns`** at a **`2.44 ns`** clock period (`0.20 ns` I/O delays, `5.0 fF` load). Edit only `code/cache_ctrl.sv`, `code/miss_handler.sv`, and `code/tag_cmp.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Synthesis/STA Environment

## Editable Files
Only the following files may be modified:
- `code/cache_ctrl.sv`
- `code/miss_handler.sv`
- `code/tag_cmp.sv`

All other files in `code/`, `include/`, `flow/`, `lib/`, and `lef/` are read-only.

## Compilation Order (`Verilator` / `Yosys -m slang`)
With `-Iinclude`:
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/axi_pkg.sv`
5. `code/ariane_pkg.sv`
6. `code/std_cache_pkg.sv`
7. `code/lfsr_8bit.sv`
8. `code/lfsr.sv`
9. `code/tc_sram.sv`
10. `code/tc_sram_wrapper.sv`
11. `code/sram.sv`
12. `code/axi_adapter.sv`
13. `code/tag_cmp.sv`
14. `code/cache_ctrl.sv`
15. `code/miss_handler.sv`
16. `code/std_nbdcache.sv`

## Synthesis, Area, and STA Target
`dcache_ctrl_top` (`flow/dcache_ctrl_top.sv`) is synthesized with `yosys -m slang`:
```
read_slang --ignore-assertions --top dcache_ctrl_top -Iinclude -DSYNTHESIS code/config_pkg.sv code/cv64a60ax_config_pkg.sv code/riscv_pkg.sv code/axi_pkg.sv code/ariane_pkg.sv code/std_cache_pkg.sv code/tag_cmp.sv code/cache_ctrl.sv flow/dcache_ctrl_top.sv
hierarchy -check -top dcache_ctrl_top
proc; opt_clean
select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top dcache_ctrl_top -flatten
opt
dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
abc -liberty lib/NangateOpenCellLibrary_typical.lib
clean
read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
check -assert
stat -liberty lib/NangateOpenCellLibrary_typical.lib
write_verilog -noattr mapped_dcache_ctrl.v
```
and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`, `lib/NangateOpenCellLibrary_typical.lib`) with:
- `create_clock -name clk_i -period 2.44 [get_ports clk_i]`
- `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
- `set_output_delay 0.20 -clock clk_i [all_outputs]`
- `set_load 5.0 [all_outputs]`
Targets:
- Zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`, `$_DLATCH`) across `std_nbdcache` and `dcache_ctrl_top`
- Mapped area `<= 2,825.0 um^2` on `dcache_ctrl_top`
- Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cache_ctrl.sv (Buggy Starter)
+++ b/solution/gold/code/cache_ctrl.sv (Golden Reference)
@@ -95,7 +95,7 @@
   mem_req_t mem_req_d, mem_req_q;
 
   assign busy_o = (state_q != IDLE);
-  assign tag_o  = mem_req_d.tag;
+  assign tag_o  = (state_q == WAIT_TAG) ? req_port_i.address_tag : mem_req_q.tag;
 
   logic [CVA6Cfg.DCACHE_LINE_WIDTH-1:0] cl_i;
 
@@ -206,7 +206,7 @@
               mem_req_d.killed    = req_port_i.kill_req;
               mem_req_d.bypass    = 1'b0;
 
-              req_port_o.data_gnt = gnt_i;
+              req_port_o.data_gnt = gnt_i & ~req_port_i.data_we;
 
               if (!gnt_i) begin
                 state_d = IDLE;
@@ -317,7 +317,7 @@
           // set the correct byte enable
           be_o.data[cl_offset>>3+:CVA6Cfg.XLEN/8] = mem_req_q.be;
           data_o.data[cl_offset+:CVA6Cfg.XLEN]    = mem_req_q.wdata;
-          data_o.tag                              = mem_req_d.tag;
+          data_o.tag                              = mem_req_q.tag;
           // ~> change the state
           data_o.dirty                            = 1'b1;
           data_o.valid                            = 1'b1;
@@ -398,7 +398,7 @@
       // ~> wait for critical word to arrive
       WAIT_CRITICAL_WORD: begin
         // speculatively request another word
-        if (req_port_i.data_req) begin
+        if (req_port_i.data_req && !flush_i) begin
           // request the cache line
           req_o = '1;
         end
@@ -423,7 +423,7 @@
             if (gnt_i) begin
               state_d = WAIT_TAG;
               mem_req_d.bypass = 1'b0;
-              req_port_o.data_gnt = 1'b1;
+              if (!req_port_i.data_we) req_port_o.data_gnt = 1'b1;
             end
           end else begin
             state_d = IDLE;
@@ -446,7 +446,10 @@
 
     if (req_port_i.kill_req) begin
       req_port_o.data_rvalid = 1'b1;
-      if (!(state_q inside {WAIT_REFILL_GNT, WAIT_REFILL_VALID, WAIT_CRITICAL_WORD})) begin
+      if (state_q == WAIT_REFILL_GNT && !active_serving_i && !miss_gnt_i && !bypass_gnt_i) begin
+        miss_req_o.valid = 1'b0;
+        state_d = IDLE;
+      end else if (!(state_q inside {WAIT_REFILL_GNT, WAIT_REFILL_VALID, WAIT_CRITICAL_WORD})) begin
         state_d = IDLE;
       end
     end

--- a/environment/public/code/miss_handler.sv (Buggy Starter)
+++ b/solution/gold/code/miss_handler.sv (Golden Reference)
@@ -155,7 +155,7 @@
   // Cache Management <-> LFSR
   logic                                                               lfsr_enable;
   logic                [          CVA6Cfg.DCACHE_SET_ASSOC-1:0]       lfsr_oh;
-  logic                [$clog2(CVA6Cfg.DCACHE_SET_ASSOC-1)-1:0]       lfsr_bin;
+  logic                [$clog2(CVA6Cfg.DCACHE_SET_ASSOC)-1:0]         lfsr_bin;
   // AMOs
   ariane_pkg::amo_t                                                   amo_op;
   logic                [                                  63:0]       amo_operand_b;
@@ -241,8 +241,9 @@
         // check if we want to flush and can flush e.g.: we are not busy anymore
         // TODO: Check that the busy flag is indeed needed
         if (flush_i && !busy_i) begin
-          state_d = FLUSH_REQ_STATUS;
-          cnt_d   = '0;
+          state_d     = FLUSH_REQ_STATUS;
+          serve_amo_d = 1'b0;
+          cnt_d       = '0;
         end
 
         // check if one of the state machines missed
@@ -361,7 +362,7 @@
         if (gnt_miss_fsm) begin
           // write status array
           addr_o       = cnt_q;
-          req_o        = 1'b1;
+          req_o        = evict_way_q;
           we_o         = 1'b1;
           data_o.valid = INVALIDATE_ON_FLUSH ? 1'b0 : 1'b1;
           // invalidate
@@ -395,7 +396,7 @@
           cnt_d       = cnt_q + (1'b1 << CVA6Cfg.DCACHE_OFFSET_WIDTH);
           state_d     = FLUSH_REQ_STATUS;
           addr_o      = cnt_q;
-          req_o       = 1'b1;
+          req_o       = '1;
           be_o.vldrty = INVALIDATE_ON_FLUSH ? '1 : '0;
           we_o        = 1'b1;
           // finished with flushing operation, go back to idle
@@ -417,7 +418,7 @@
       INIT: begin
         // initialize status array
         addr_o      = cnt_q;
-        req_o       = 1'b1;
+        req_o       = '1;
         we_o        = 1'b1;
         // only write the dirty array
         be_o.vldrty = '1;
@@ -468,7 +469,12 @@
           if (amo_bypass_rsp.valid) begin
             state_d = IDLE;
             amo_resp_o.ack = 1'b1;
-            amo_resp_o.result = amo_bypass_rsp.rdata;
+            if (amo_req_i.size == 2'b10) begin
+              halfword = (amo_req_i.operand_a[2:0] == '0) ? amo_bypass_rsp.rdata[31:0] : amo_bypass_rsp.rdata[63:32];
+              amo_resp_o.result = {{32{halfword[31]}}, halfword};
+            end else begin
+              amo_resp_o.result = amo_bypass_rsp.rdata;
+            end
           end else begin
             state_d = AMO_WAIT_RESP;
           end
@@ -777,7 +783,13 @@
         // granted but response hasn't arrived yet
         if (req_o.req && rsp_i.gnt) begin
           req_d.req = 1'b0;
-          outstanding_cnt_d += 1;
+          if (rsp_i.valid) begin
+            rsp_o[sel_d].valid = 1'b1;
+            rsp_o[sel_d].rdata = rsp_i.rdata;
+            state_d = IDLE;
+          end else begin
+            outstanding_cnt_d += 1;
+          end
         end
       end
 

--- a/environment/public/code/tag_cmp.sv (Buggy Starter)
+++ b/solution/gold/code/tag_cmp.sv (Golden Reference)
@@ -70,15 +70,16 @@
     // Request Side
     // priority select
     for (int unsigned i = 0; i < NR_PORTS; i++) begin
-      req_o    = req_i[i];
-      id_d     = (1'b1 << i);
-      gnt_o[i] = 1'b1;
-      addr_o   = addr_i[i];
-      be_o     = be_i[i];
-      we_o     = we_i[i];
-      wdata_o  = wdata_i[i];
-
-      if (req_i[i]) break;
+      if (|req_i[i]) begin
+        req_o    = req_i[i];
+        id_d     = (1'b1 << i);
+        gnt_o[i] = 1'b1;
+        addr_o   = addr_i[i];
+        be_o     = be_i[i];
+        we_o     = we_i[i];
+        wdata_o  = wdata_i[i];
+        break;
+      end
     end
 
   end

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_adapter.sv`](environment/public/code/axi_adapter.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cache_ctrl.sv`](environment/public/code/cache_ctrl.sv) **(Editable)**
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a60ax_config_pkg.sv`](environment/public/code/cv64a60ax_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lfsr.sv`](environment/public/code/lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/lfsr_8bit.sv`](environment/public/code/lfsr_8bit.sv) *(Read-Only Context)*
- [`environment/public/code/miss_handler.sv`](environment/public/code/miss_handler.sv) **(Editable)**
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sram.sv`](environment/public/code/sram.sv) *(Read-Only Context)*
- [`environment/public/code/std_cache_pkg.sv`](environment/public/code/std_cache_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/std_nbdcache.sv`](environment/public/code/std_nbdcache.sv) *(Read-Only Context)*
- [`environment/public/code/tag_cmp.sv`](environment/public/code/tag_cmp.sv) **(Editable)**
- [`environment/public/code/tc_sram.sv`](environment/public/code/tc_sram.sv) *(Read-Only Context)*
- [`environment/public/code/tc_sram_wrapper.sv`](environment/public/code/tc_sram_wrapper.sv) *(Read-Only Context)*
- [`environment/public/flow/dcache_ctrl_top.sv`](environment/public/flow/dcache_ctrl_top.sv) *(Read-Only Context)*
- [`environment/public/include/common_cells/LICENSE.Apache-2.0`](environment/public/include/common_cells/LICENSE.Apache-2.0) *(Read-Only Context)*
- [`environment/public/include/common_cells/assertions.svh`](environment/public/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lef/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.tech.lef`](environment/public/lef/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/LICENSE_NANGATE`](environment/public/lib/LICENSE_NANGATE) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

