# `case_0013`: Handle external resets during DMA operation

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0013` |
| **Source Silicon Repository** | `analogdevicesinc/hdl` (`repo_38`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `reset_rdc` (Reset Recovery, Abort Drain, Reset Domain Crossing (RDC) & Boot Sequencing) |
| **Multi-Domain Tags** | `reset_rdc` |
| **Editable Files (`allowed_edits`)** | [`code/axi_dmac_reset_manager.v`](environment/public/code/axi_dmac_reset_manager.v) (1 files, 346 LOC) |
| **Public Subsystem Context** | 2 RTL files (426 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Handle external resets during DMA operation

The reset manager's external-reset inputs are currently unused. Complete their handling for source, destination, and, when enabled, scatter-gather domains. Assertion must reset the affected domain immediately; release must be synchronized to that domain's clock. An external reset aborts the active DMA operation: stop admitting new requests, allow the other domains to acknowledge shutdown, then run the existing full reset sequence before restarting. A brief external reset must not be lost, and the manager must wait for every participating external reset to be released before restarting. Ignore the scatter-gather reset when that domain is disabled.

Preserve the existing enable, pause and reset sequencing when external resets stay released. The input clocks continue running throughout this sequence. The existing reset chain and enable/acknowledge interfaces provide the integration context.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The editable source is `code/axi_dmac_reset_manager.v`; its `sync_bits` dependency is included unchanged from the same upstream HDL repository. Use a free Verilog simulator such as Icarus Verilog with SystemVerilog enabled, or Verilator.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axi_dmac_reset_manager.v (Buggy Starter)
+++ b/solution/gold/code/axi_dmac_reset_manager.v (Golden Reference)
@@ -88,18 +88,67 @@
   localparam STATE_STARTUP = 3'h3;
   localparam STATE_ENABLED = 3'h4;
   localparam STATE_SHUTDOWN = 3'h5;
+  localparam STATE_ABORT_STARTUP = 3'h6;
 
   reg [2:0] state = 3'b000;
   reg needs_reset = 1'b0;
   reg do_reset = 1'b0;
   reg do_enable = 1'b0;
 
+  // Asynchronously remember even short reset assertions until shutdown reaches reset.
+  reg src_fault = 1'b0, dest_fault = 1'b0, sg_fault = 1'b0;
+  wire src_fault_sync, dest_fault_sync, sg_fault_sync;
+  wire src_released, dest_released, sg_released;
+  wire external_fault = src_fault_sync | dest_fault_sync | (DMA_SG_TRANSFER && sg_fault_sync);
+  wire external_released = src_released & dest_released & (!DMA_SG_TRANSFER | sg_released);
+  always @(posedge clk or negedge src_ext_resetn or negedge resetn)
+    if (!src_ext_resetn) src_fault <= 1'b1;
+    else if (!resetn) src_fault <= 1'b0;
+    else if (state == STATE_RESET && external_released) src_fault <= 1'b0;
+  always @(posedge clk or negedge dest_ext_resetn or negedge resetn)
+    if (!dest_ext_resetn) dest_fault <= 1'b1;
+    else if (!resetn) dest_fault <= 1'b0;
+    else if (state == STATE_RESET && external_released) dest_fault <= 1'b0;
+  always @(posedge clk or negedge sg_ext_resetn or negedge resetn)
+    if (!sg_ext_resetn) sg_fault <= 1'b1;
+    else if (!resetn) sg_fault <= 1'b0;
+    else if (state == STATE_RESET && external_released) sg_fault <= 1'b0;
+  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) fault_src (.in_bits(src_fault), .out_clk(clk), .out_resetn(1'b1), .out_bits(src_fault_sync));
+  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) fault_dest (.in_bits(dest_fault), .out_clk(clk), .out_resetn(1'b1), .out_bits(dest_fault_sync));
+  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) fault_sg (.in_bits(sg_fault), .out_clk(clk), .out_resetn(1'b1), .out_bits(sg_fault_sync));
+  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) release_src (.in_bits(src_ext_resetn), .out_clk(clk), .out_resetn(1'b1), .out_bits(src_released));
+  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) release_dest (.in_bits(dest_ext_resetn), .out_clk(clk), .out_resetn(1'b1), .out_bits(dest_released));
+  sync_bits #(.NUM_OF_BITS(1), .ASYNC_CLK(1)) release_sg (.in_bits(sg_ext_resetn), .out_clk(clk), .out_resetn(1'b1), .out_bits(sg_released));
+  reg [1:0] src_release = 0, dest_release = 0, sg_release = 0;
+  always @(posedge src_clk or negedge src_ext_resetn or negedge resetn)
+    if (!src_ext_resetn || !resetn) src_release <= 0; else src_release <= {src_release[0],1'b1};
+  always @(posedge dest_clk or negedge dest_ext_resetn or negedge resetn)
+    if (!dest_ext_resetn || !resetn) dest_release <= 0; else dest_release <= {dest_release[0],1'b1};
+  always @(posedge sg_clk or negedge sg_ext_resetn or negedge resetn)
+    if (!sg_ext_resetn || !resetn) sg_release <= 0; else sg_release <= {sg_release[0],1'b1};
+
   wire enabled_dest;
   wire enabled_src;
   wire enabled_sg;
 
   wire enabled_all;
   wire disabled_all;
+  reg req_started=0, seen_req=0, seen_src=0, seen_dest=0, seen_sg=0;
+  always @(posedge clk) begin
+    if (!resetn || state == STATE_DISABLED || state == STATE_RESET) begin
+      req_started<=0; seen_req<=0; seen_src<=0; seen_dest<=0; seen_sg<=0;
+    end else begin
+      if (req_enable) req_started<=1;
+      if (req_enabled) seen_req<=1;
+      if (enabled_src) seen_src<=1;
+      if (enabled_dest) seen_dest<=1;
+      if (enabled_sg) seen_sg<=1;
+    end
+  end
+  wire startup_drained = (!req_started || seen_req || req_enabled)
+      && (seen_src || enabled_src || src_fault_sync)
+      && (seen_dest || enabled_dest || dest_fault_sync)
+      && (!DMA_SG_TRANSFER || !ctrl_hwdesc || seen_sg || enabled_sg || sg_fault_sync);
 
   generate if (DMA_SG_TRANSFER == 1) begin
   assign enabled_all = req_enabled & enabled_src & enabled_dest & (enabled_sg | ~ctrl_hwdesc);
@@ -109,7 +158,7 @@
   assign disabled_all = ~(req_enabled | enabled_src | enabled_dest);
   end endgenerate
 
-  assign req_enable = do_enable;
+  assign req_enable = do_enable & ~external_fault;
 
   assign dbg_status = {needs_reset,req_resetn,src_resetn,dest_resetn,sg_resetn,req_enabled,enabled_src,enabled_dest,enabled_sg,state};
 
@@ -122,7 +171,7 @@
   end
 
   always @(posedge clk) begin
-    if (state == STATE_STARTUP || state == STATE_ENABLED) begin
+    if (state == STATE_STARTUP || state == STATE_ENABLED || state == STATE_ABORT_STARTUP) begin
       do_enable <= 1'b1;
     end else begin
       do_enable <= 1'b0;
@@ -159,7 +208,7 @@
   always @(posedge clk) begin
     if (state == STATE_RESET) begin
       needs_reset <= 1'b0;
-    end else if (ctrl_enable == 1'b0) begin
+    end else if (ctrl_enable == 1'b0 || external_fault) begin
       needs_reset <= 1'b1;
     end
   end
@@ -178,12 +227,12 @@
          * ctrl_enable == 1'b0, otherwise we'd go through the reset sequence
          * again and again.
          */
-        if (ctrl_enable == 1'b1 && req_resetn == 1'b1) begin
+        if (ctrl_enable == 1'b1 && req_resetn == 1'b1 && external_released && !external_fault) begin
           state <= STATE_DISABLED;
         end
       end
       STATE_DISABLED: begin
-        if (needs_reset == 1'b1) begin
+        if (needs_reset == 1'b1 || external_fault) begin
           state <= STATE_DO_RESET;
         end else if (ctrl_pause == 1'b0) begin
           state <= STATE_STARTUP;
@@ -191,12 +240,17 @@
       end
       STATE_STARTUP: begin
         /* Wait for all domains to be ready */
-        if (enabled_all == 1'b1) begin
+        if (external_fault) begin
+          state <= STATE_ABORT_STARTUP;
+        end else if (enabled_all == 1'b1) begin
           state <= STATE_ENABLED;
         end
       end
+      STATE_ABORT_STARTUP: begin
+        if (startup_drained) state <= STATE_SHUTDOWN;
+      end
       STATE_ENABLED: begin
-        if (needs_reset == 1'b1 || ctrl_pause == 1'b1) begin
+        if (needs_reset == 1'b1 || ctrl_pause == 1'b1 || external_fault) begin
           state <= STATE_SHUTDOWN;
         end
       end
@@ -274,11 +328,11 @@
   endgenerate
 
   /* De-assertions in the opposite direction of the data flow: dest, src, request */
-  assign dest_resetn = ~reset_sync_chain[1];
-  assign src_resetn = ~reset_sync_chain[2];
+  assign dest_resetn = ~reset_sync_chain[1] & dest_release[1];
+  assign src_resetn = ~reset_sync_chain[2] & src_release[1];
   assign req_resetn = ~reset_sync_chain[3];
   generate if (DMA_SG_TRANSFER == 1) begin
-  assign sg_resetn = ~reset_sync_chain[4];
+  assign sg_resetn = ~reset_sync_chain[4] & sg_release[1];
   end else begin
   assign sg_resetn = 1'b0;
   end endgenerate

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE_ADIBSD`](environment/public/code/LICENSE_ADIBSD) *(Read-Only Context)*
- [`environment/public/code/LICENSE_GPL2`](environment/public/code/LICENSE_GPL2) *(Read-Only Context)*
- [`environment/public/code/axi_dmac_reset_manager.v`](environment/public/code/axi_dmac_reset_manager.v) **(Editable)**
- [`environment/public/code/sync_bits.v`](environment/public/code/sync_bits.v) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

