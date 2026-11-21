# `case_1004`: Two-Channel OpenTitan SRAM Crossbar Stall Stability, Bounded Fairness, and Atomic Store Forwarding

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1004` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `gatelevel_physical_effects`, `protocol_control`, `rtl_integration`, `rtl_semantics` |
| **Editable Files (`allowed_edits`)** | [`code/prim_arbiter_tree.sv`](environment/public/code/prim_arbiter_tree.sv), [`code/prim_sram_arbiter.sv`](environment/public/code/prim_sram_arbiter.sv) (2 files, 259 LOC) |
| **Public Subsystem Context** | 17 RTL files (3046 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# Two-Channel OpenTitan SRAM Crossbar Stall Stability, Bounded Fairness, and Atomic Store Forwarding

In `code/ot_sram_xbar_2ch.sv`, update only `code/prim_arbiter_tree.sv` and `code/prim_sram_arbiter.sv` so that all boundary ports of `ot_sram_xbar_2ch` satisfy the following protocol and physical closure requirements:

1. **Stall Stability, Bounded Fairness, and Atomic Store Forwarding**:
   - Whenever `ot_sram_xbar_2ch` presents a valid downstream SRAM request (`sram_req_o == 1`) while stalled (`sram_gnt_i == 0`), the selected channel and requester as well as `sram_addr_o`, `sram_write_o`, `sram_amo_write_o`, `sram_wdata_o`, and `sram_wmask_o` must remain locked and invariant across rising `clk_i` edges until granted (`sram_gnt_i == 1`), even if contenders on either channel assert new requests or `arb_policy_i` changes mid-stall. All arbitration state in both modules must advance only on a granted handshake and reset to zero on `rst_ni == 0`.
   - Under `arb_policy_i[c] == 1` (`c` in `{0, 1}`), any requester on channel `c` holding `req_chc_i` must be granted by its channel tree after at most `P_c - 1` other grants on channel `c` (`P_c = 1 << $clog2(N_CHc)`), while `arb_policy_i[c] == 0` retains its `0 .. N_CHc - 1` round-robin counter.
   - `prim_sram_arbiter` must alternate channel priority away from the granted channel (`rr_flag_q <= ~sel_ch1`) after any granted channel transfer so an active channel waits at most one transfer by the other channel, and must push read-response steering entries into `u_req_fifo` only on a granted read (`sram_req_o && sram_gnt_i && !sram_write_o`).
   - When an atomic read (`!mux_write && mux_amo`) is accepted (`mux_valid && sram_gnt_i`), `prim_sram_arbiter` must issue its follow-up write (`sram_amo_write_o == 1`, `sram_write_o == 1`, `sram_req_o == 1`) driving `sram_wdata_o` with the write data (`chc_wdata_i`) sampled on the accepted atomic read cycle rather than all-ones.

2. **Latch-Free Synthesis, Nangate45 Area, and OpenROAD STA Closure**:
   - Across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}`, the RTL must be strictly latch-free. Synthesizing `ot_sram_xbar_2ch` at `N_CH0 = 8, N_CH1 = 4, SramAw = 12, SramDw = 32` with the Yosys/Slang + Nangate45 flow in `BUILD.md` must achieve mapped cell area `<= 2,850.0 um^2`, and OpenROAD placement STA at a `3.80 ns` clock must achieve worst setup slack (`WNS`) `>= 0.20 ns` and worst hold slack (`WHS`) `>= 0.00 ns`.

Edit only `code/prim_arbiter_tree.sv` and `code/prim_sram_arbiter.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable and Read-Only Files
Edit only:
- `code/prim_arbiter_tree.sv`
- `code/prim_sram_arbiter.sv`

Do not modify `code/ot_sram_xbar_2ch.sv`, `code/prim_fifo_sync*.sv*`, `code/prim_count*.sv`, `code/prim_flop*.sv`, `code/prim_mubi_pkg.sv`, `code/prim_util_pkg.sv`, `code/prim_assert*.sv*`, or `lib/*`. You may define helper submodules inside the editable files if needed.

## 2. Behavioral Simulation (`Verilator`)
Compile and simulate `ot_sram_xbar_2ch` across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}` using Verilator 5:
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -DSYNTHESIS -Icode --top-module <your_tb> \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_flop.sv code/prim_count.sv code/prim_fifo_sync_cnt.sv \
  code/prim_fifo_sync.sv code/prim_arbiter_tree.sv code/prim_sram_arbiter.sv \
  code/ot_sram_xbar_2ch.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Nangate45 Logic Synthesis (`Yosys + Slang`)
Synthesize `ot_sram_xbar_2ch` at `N_CH0=8, N_CH1=4, SramAw=12, SramDw=32`:
```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions -DSYNTHESIS --top ot_sram_xbar_2ch -G N_CH0=8 -G N_CH1=4 -G SramAw=12 -G SramDw=32 -I code \
    code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/prim_flop.sv code/prim_count.sv code/prim_fifo_sync_cnt.sv \
    code/prim_fifo_sync.sv code/prim_arbiter_tree.sv code/prim_sram_arbiter.sv \
    code/ot_sram_xbar_2ch.sv
  hierarchy -check -top ot_sram_xbar_2ch
  proc; opt_clean
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr*
  synth -top ot_sram_xbar_2ch
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```
Reported `Chip area for module '\ot_sram_xbar_2ch':` must be `<= 2850.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis
Strip ` signed ` tokens (`sed 's/ signed / /g' mapped.v > sta.v`) and run `openroad -exit flow.tcl`:
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design ot_sram_xbar_2ch
initialize_floorplan -die_area {0 0 220 220} -core_area {10 10 210 210} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 3.80 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [get_ports {arb_policy_i* req_ch* sram_gnt_i sram_rvalid_i sram_rdata_i* sram_rerror_i*}]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
Required timing closure: `WNS >= 0.20` ns and `WHS >= 0.00` ns.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/prim_arbiter_tree.sv (Buggy Starter)
+++ b/solution/gold/code/prim_arbiter_tree.sv (Golden Reference)
@@ -26,7 +26,7 @@
 );
 
   logic unused_req_chk;
-  assign unused_req_chk = req_chk_i ^ policy_i;
+  assign unused_req_chk = req_chk_i;
 
   if (N == 1) begin : gen_degenerate_case
     assign valid_o  = req_i[0];
@@ -37,10 +37,52 @@
     logic [2**(IdxW+1)-2:0]           req_tree;
     logic [2**(IdxW+1)-2:0]           prio_tree;
     logic [2**(IdxW+1)-2:0]           sel_tree;
-    logic [2**(IdxW+1)-2:0]           mask_tree;
     logic [2**(IdxW+1)-2:0][IdxW-1:0] idx_tree;
     logic [2**(IdxW+1)-2:0][DW-1:0]   data_tree;
+
     logic [IdxW-1:0]                  rr_cnt_q;
+    logic                             lock_q;
+    logic [IdxW-1:0]                  locked_idx_q;
+    logic [N-1:0]                     eff_req;
+    logic [(1<<IdxW)-2:0]             fair_next_q;
+
+    always_comb begin
+      eff_req = req_i;
+      if (lock_q) begin
+        for (int i = 0; i < N; i++) begin
+          if ((locked_idx_q == IdxW'(i)) && req_i[i]) begin
+            eff_req = (N'(1) << i);
+          end
+        end
+      end
+    end
+
+    always_ff @(posedge clk_i or negedge rst_ni) begin
+      if (!rst_ni) begin
+        lock_q       <= 1'b0;
+        locked_idx_q <= '0;
+      end else if (valid_o && !ready_i) begin
+        lock_q       <= 1'b1;
+        locked_idx_q <= idx_o;
+      end else begin
+        lock_q       <= 1'b0;
+      end
+    end
+
+    integer lv, nd;
+    always_ff @(posedge clk_i or negedge rst_ni) begin
+      if (!rst_ni) begin
+        fair_next_q <= '0;
+      end else if (valid_o && ready_i) begin
+        for (lv = 0; lv < IdxW; lv = lv + 1) begin
+          for (nd = 0; nd < (1 << lv); nd = nd + 1) begin
+            if ((idx_o >> (IdxW - lv)) == nd) begin
+              fair_next_q[(1 << lv) - 1 + nd] <= ~idx_o[IdxW - lv - 1];
+            end
+          end
+        end
+      end
+    end
 
     for (genvar level = 0; level < IdxW+1; level++) begin : gen_tree
       localparam int Base0 = (2**level)-1;
@@ -53,11 +95,11 @@
 
         if (level == IdxW) begin : gen_leafs
           if (offset < N) begin : gen_assign
-            assign req_tree[Pa]  = req_i[offset];
-            assign prio_tree[Pa] = req_i[offset] & (offset > rr_cnt_q);
+            assign req_tree[Pa]  = eff_req[offset];
+            assign prio_tree[Pa] = eff_req[offset] & (offset > rr_cnt_q);
             assign idx_tree[Pa]  = offset;
             assign data_tree[Pa] = data_i[offset];
-            assign gnt_o[offset] = req_i[offset] & sel_tree[Pa] & ready_i;
+            assign gnt_o[offset] = eff_req[offset] & sel_tree[Pa] & ready_i;
           end else begin : gen_tie_off
             assign req_tree[Pa]  = '0;
             assign prio_tree[Pa] = '0;
@@ -66,15 +108,14 @@
           end
         end else begin : gen_nodes
           logic sel;
-          assign sel = ~req_tree[C0] | (~prio_tree[C0] & prio_tree[C1]);
+          wire node_pref = policy_i ? fair_next_q[Pa] : (~prio_tree[C0] & prio_tree[C1]);
+          assign sel           = ~req_tree[C0] | (req_tree[C1] & node_pref);
           assign req_tree[Pa]  = req_tree[C0] | req_tree[C1];
           assign prio_tree[Pa] = prio_tree[C1] | prio_tree[C0];
           assign idx_tree[Pa]  = sel ? idx_tree[C1]  : idx_tree[C0];
           assign data_tree[Pa] = sel ? data_tree[C1] : data_tree[C0];
           assign sel_tree[C0]  = sel_tree[Pa] & ~sel;
           assign sel_tree[C1]  = sel_tree[Pa] &  sel;
-          assign mask_tree[C0] = mask_tree[Pa];
-          assign mask_tree[C1] = mask_tree[Pa] | sel_tree[C0];
         end
       end
     end
@@ -88,7 +129,6 @@
     assign idx_o       = idx_tree[0];
     assign valid_o     = req_tree[0];
     assign sel_tree[0] = 1'b1;
-    assign mask_tree[0] = 1'b0;
 
     always_ff @(posedge clk_i or negedge rst_ni) begin
       if (!rst_ni) begin

--- a/environment/public/code/prim_sram_arbiter.sv (Buggy Starter)
+++ b/solution/gold/code/prim_sram_arbiter.sv (Golden Reference)
@@ -49,28 +49,39 @@
   input  logic              sram_rvalid_i
 );
 
-  logic unused_n_ch0;
-  assign unused_n_ch0 = ^N_CH0_i;
-
-  // Channel arbitration (CH0 vs CH1)
-  logic rr_flag_q;
-  logic sel_ch1;
-  logic mux_valid, mux_ready;
-  logic mux_write, mux_amo;
+  // Channel arbitration (CH0 vs CH1) with stall lock and true round-robin update (~sel_ch1)
+  logic              rr_flag_q;
+  logic              lock_q;
+  logic              locked_sel_q;
+  logic              eff_v0, eff_v1;
+  logic              sel_ch1;
+  logic              mux_valid, mux_ready;
+  logic              mux_write, mux_amo;
   logic [SramAw-1:0] mux_addr;
   logic [SramDw-1:0] mux_wdata, mux_wmask;
 
-  assign mux_valid = ch0_valid_i | ch1_valid_i;
-  assign sel_ch1   = ~ch0_valid_i | (rr_flag_q & ch1_valid_i);
+  assign eff_v0 = (lock_q && (locked_sel_q ? ch1_valid_i : ch0_valid_i)) ? (~locked_sel_q & ch0_valid_i) : ch0_valid_i;
+  assign eff_v1 = (lock_q && (locked_sel_q ? ch1_valid_i : ch0_valid_i)) ? ( locked_sel_q & ch1_valid_i) : ch1_valid_i;
 
-  assign ch0_ready_o = (~sel_ch1) & mux_ready;
-  assign ch1_ready_o = ( sel_ch1) & mux_ready;
+  assign mux_valid = eff_v0 | eff_v1;
+  assign sel_ch1   = ~eff_v0 | (rr_flag_q & eff_v1);
+
+  assign ch0_ready_o = (~sel_ch1) & eff_v0 & mux_ready;
+  assign ch1_ready_o = ( sel_ch1) & eff_v1 & mux_ready;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
-      rr_flag_q <= 1'b0;
+      rr_flag_q    <= 1'b0;
+      lock_q       <= 1'b0;
+      locked_sel_q <= 1'b0;
     end else if (mux_valid && mux_ready) begin
-      rr_flag_q <= ~rr_flag_q;
+      rr_flag_q <= ~sel_ch1;
+      lock_q    <= 1'b0;
+    end else if (mux_valid && !mux_ready) begin
+      lock_q       <= 1'b1;
+      locked_sel_q <= sel_ch1;
+    end else begin
+      lock_q <= 1'b0;
     end
   end
 
@@ -80,22 +91,23 @@
   assign mux_wdata = sel_ch1 ? ch1_wdata_i : ch0_wdata_i;
   assign mux_wmask = sel_ch1 ? ch1_wmask_i : ch0_wmask_i;
 
-  // Two-cycle Atomic Read-Modify-Write (AMO) Sequencer:
-  // When a read (!mux_write) with mux_amo==1 is granted on the SRAM port,
-  // issue a follow-up write on the next cycle.
+  // Two-cycle Atomic Read-Modify-Write (AMO) Sequencer
   logic              amo_active_q;
   logic [SramAw-1:0] amo_addr_q;
+  logic [SramDw-1:0] amo_wdata_q;
   logic [SramDw-1:0] amo_wmask_q;
 
   always_ff @(posedge clk_i or negedge rst_ni) begin
     if (!rst_ni) begin
       amo_active_q <= 1'b0;
       amo_addr_q   <= '0;
+      amo_wdata_q  <= '0;
       amo_wmask_q  <= '0;
     end else if (!amo_active_q) begin
       if (mux_valid && sram_gnt_i && !mux_write && mux_amo) begin
         amo_active_q <= 1'b1;
         amo_addr_q   <= mux_addr;
+        amo_wdata_q  <= mux_wdata;
         amo_wmask_q  <= mux_wmask;
       end
     end else if (sram_gnt_i) begin
@@ -105,10 +117,10 @@
 
   assign mux_ready        = ~amo_active_q & sram_gnt_i;
   assign sram_req_o       = amo_active_q | mux_valid;
-  assign sram_write_o     = amo_active_q ? 1'b1      : mux_write;
+  assign sram_write_o     = amo_active_q ? 1'b1        : mux_write;
   assign sram_amo_write_o = amo_active_q;
-  assign sram_addr_o      = amo_active_q ? amo_addr_q : mux_addr;
-  assign sram_wdata_o     = amo_active_q ? {SramDw{1'b1}} : mux_wdata;
+  assign sram_addr_o      = amo_active_q ? amo_addr_q  : mux_addr;
+  assign sram_wdata_o     = amo_active_q ? amo_wdata_q : mux_wdata;
   assign sram_wmask_o     = EnMask ? (amo_active_q ? amo_wmask_q : mux_wmask) : {SramDw{1'b1}};
 
   // Response steering FIFO for read requests
@@ -137,16 +149,16 @@
   ) u_req_fifo (
     .clk_i,
     .rst_ni,
-    .clr_i    ( 1'b0                         ),
-    .wvalid_i ( sram_req_o & ~sram_write_o   ),
-    .wready_o (                              ),
-    .wdata_i  ( gnt_combined                 ),
-    .rvalid_o (                              ),
-    .rready_i ( sram_ack                     ),
-    .rdata_o  ( steer                        ),
-    .full_o   (                              ),
-    .depth_o  (                              ),
-    .err_o    (                              )
+    .clr_i    ( 1'b0                                   ),
+    .wvalid_i ( sram_req_o & sram_gnt_i & ~sram_write_o ),
+    .wready_o (                                        ),
+    .wdata_i  ( gnt_combined                           ),
+    .rvalid_o (                                        ),
+    .rready_i ( sram_ack                               ),
+    .rdata_o  ( steer                                  ),
+    .full_o   (                                        ),
+    .depth_o  (                                        ),
+    .err_o    (                                        )
   );
 
   assign rsp_rvalid_o = steer & {N{sram_rvalid_i}};

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ot_sram_xbar_2ch.sv`](environment/public/code/ot_sram_xbar_2ch.sv) *(Read-Only Context)*
- [`environment/public/code/prim_arbiter_tree.sv`](environment/public/code/prim_arbiter_tree.sv) **(Editable)**
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_count.sv`](environment/public/code/prim_count.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count_pkg.sv`](environment/public/code/prim_count_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_assert.svh`](environment/public/code/prim_fifo_assert.svh) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync.sv`](environment/public/code/prim_fifo_sync.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync_cnt.sv`](environment/public/code/prim_fifo_sync_cnt.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop.sv`](environment/public/code/prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sram_arbiter.sv`](environment/public/code/prim_sram_arbiter.sv) **(Editable)**
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
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

