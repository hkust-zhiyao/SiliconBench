# `case_2001`: Co-design Ibex Prefetch/FIFO Fault Handling, Four-Cluster SRAM Mirror Relay, and 8-Macro CTS Floorplan

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_2001` |
| **Source Silicon Repository** | `lowRISC/ibex` (`repo_02`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `floorplan_macros` (Macro Floorplanning, Orientation, Channel Geometry & Physical Hierarchy) |
| **Multi-Domain Tags** | `clocking`, `floorplan_macros`, `gatelevel_physical_effects`, `pins_routing_congestion`, `protocol_control`, `rtl_integration`, `rtl_semantics`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/ibex_prefetch_buffer.sv`](environment/public/code/ibex_prefetch_buffer.sv), [`code/ibex_fetch_fifo.sv`](environment/public/code/ibex_fetch_fifo.sv), [`code/ibex_prefetch_sram_cluster.sv`](environment/public/code/ibex_prefetch_sram_cluster.sv), [`plan/placement.json`](environment/public/plan/placement.json) (4 files, 691 LOC) |
| **Public Subsystem Context** | 11 RTL files (1661 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Co-design Ibex prefetch/FIFO fault handling, four-cluster SRAM mirror relay, and 8-macro CTS floorplan

In `code/ibex_prefetch_sram_cluster.sv`, the Ibex instruction prefetch front-end (`code/ibex_prefetch_buffer.sv` and `code/ibex_fetch_fifo.sv`) fetches 32-bit instruction words across four 256×128 single-port SRAM clusters (`cluster[0..3].mem` via `code/tc_sram.sv`, each backed by `i_cut_low` for bits `[63:0]` and `i_cut_high` for bits `[127:64]` of `RM_IHPSG13_1P_256x64_c2_bm_bist`), while a host maintenance interface performs 128-bit reads, writes, and low-to-high mirror relays. Currently, both RTL functional verification and physical implementation fail:

1. **Prefetch fault retirement, post-fault speculative freeze, and unaligned error attribution (`code/ibex_prefetch_buffer.sv`, `code/ibex_fetch_fifo.sv`)**:
   - In `ibex_prefetch_buffer.sv`, every instruction memory response (`instr_rvalid_i == 1'b1`, whether `instr_err_i` is `0` or `1`) must retire the oldest slot in the outstanding-request and branch-discard queues, and every non-discarded response (`!branch_discard_q[0]`) must be pushed into `ibex_fetch_fifo` (`in_valid_i = 1'b1`, propagating `instr_err_i` on `in_err_i`), while branch-discarded responses (`branch_discard_q[0] == 1'b1`) are retired without pushing to the FIFO.
   - Maintain a registered fault-freeze state in `ibex_prefetch_buffer.sv` (cleared on `!rst_ni` or `branch_i == 1'b1`, set on the clock edge following any non-discarded error response `instr_rvalid_i && instr_err_i && !branch_discard_q[0]` with `branch_i == 1'b0`) that blocks new sequential requests (`valid_new_req == 1'b0`) while keeping any already-asserted ungranted request (`valid_req_q == 1'b1`) stable on `instr_req_o`/`instr_addr_o` until `instr_gnt_i` asserts.
   - In `ibex_fetch_fifo.sv`, when `out_addr_o[1] == 1'b1` and the first word (`entry[0]` or bypass when `entry[0]` is empty) is valid with an error (`err == 1'b1`), assert `out_valid_o = 1'b1`, `out_err_o = 1'b1`, and `out_err_plus2_o = 1'b0` immediately without waiting for a second word; assert `out_err_plus2_o = 1'b1` if and only if `out_addr_o[1] == 1'b1`, `!unaligned_is_compressed`, `!err`, and the second word has an error.

2. **Four-cluster SRAM low-to-high mirror relay, byte-mask forwarding, and 8-macro CTS floorplan (`code/ibex_prefetch_sram_cluster.sv`, `plan/placement.json`)**:
   - In `code/ibex_prefetch_sram_cluster.sv`, for each cluster `i` (`0..3`), drive `wd[63:0] = host_wdata_i[63:0]` and drive `wd[127:64] = host_mirror_i[i] ? bank_rdata[i][63:0] : host_wdata_i[127:64]` without adding extra flip-flops or latches in the cluster loop (`__RELAY_PATHS__ 256` preserved); drive `be = host_mirror_i[i] ? {host_be_i[15:8] | host_be_i[7:0], host_be_i[7:0] & host_be_i[15:8]} : host_be_i`; and drive `cluster_xor_rdata_o[127:0]` as the full 128-bit bitwise XOR across `bank_rdata[0..3]`.
   - In `plan/placement.json` (`"macros"` with 8 integer-coordinate entries for `bank` `0..3` and `half` `"low"`/`"high"`, `"orient"` in `{"R0", "R180", "MX", "MY"}`), place all 8 macros (`784.48 × 118.78 µm`) within `65 <= x`, `x + 784.48 <= 2335`, `68 <= y`, `y + 118.78 <= 1730` with `>= 20 µm` pairwise X or Y clearance, `y(low) == y(high)` and `x(low) < x(high)` per bank, banks `0, 1` in the south bay `68 <= y` and `y + 118.78 <= 420` (`y(0) < y(1)`), and banks `2, 3` in the north bay `1340 <= y` and `y + 118.78 <= 1730` (`y(2) < y(3)`). Under `physical/synth.ys` and `physical/flow.tcl.in` (`10.0 ns` `clk_i`), achieve legal placement, connected `VDD`/`VSS` grids, `0` global-route overflow, rise-to-rise clock network latency spread `<= 0.01750 ns`, post-global-route setup slack `>= 0.60 ns`, hold slack `>= 0.05 ns`, and Metal2–Metal5 global-route wirelength `<= 1,402,000.0 µm`.

Edit only `code/ibex_prefetch_buffer.sv`, `code/ibex_fetch_fifo.sv`, `code/ibex_prefetch_sram_cluster.sv`, and `plan/placement.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Instructions

## 1. Editable Files
Only the following four files are collected and graded:
- `code/ibex_prefetch_buffer.sv`
- `code/ibex_fetch_fifo.sv`
- `code/ibex_prefetch_sram_cluster.sv`
- `plan/placement.json`

All other files (`code/tc_sram.sv`, `code/prim_assert*`, `code/prim_flop_macros.sv`, `pdk/*`, `physical/synth.ys`, `physical/flow.tcl.in`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Icarus Verilog`)
Compile and simulate `code/ibex_prefetch_buffer.sv`, `code/ibex_fetch_fifo.sv`, and `code/ibex_prefetch_sram_cluster.sv` with `code/tc_sram.sv` and the behavioral IHP 256×64 SRAM macro models (`pdk/256.v`, `pdk/core.v`):

```bash
iverilog \
  -g2012 -DSYNTHESIS -Icode -s <your_tb_top> -o sim.vvp \
  pdk/256.v pdk/core.v code/tc_sram.sv \
  code/ibex_fetch_fifo.sv code/ibex_prefetch_buffer.sv \
  code/ibex_prefetch_sram_cluster.sv <your_tb.sv>

vvp \
  sim.vvp
```

## 3. Logic Synthesis (`Yosys + Slang`)
Run synthesis using the provided `physical/synth.ys` script:

```bash
yosys \
  -m slang -s physical/synth.ys
```

This produces `mapped.v`, which must contain exactly 8 `RM_IHPSG13_1P_256x64_c2_bm_bist` macro instances and zero inferred standard-cell latches.

## 4. Physical Implementation & STA (`OpenROAD`)
`plan/placement.json` must be a JSON object with a single `"macros"` array of 8 objects, each with exact keys:
```json
{
  "bank": 0,
  "half": "low",
  "x": 100,
  "y": 120,
  "orient": "MX"
}
```
where `bank ∈ {0, 1, 2, 3}`, `half ∈ {"low", "high"}`, `x` and `y` are integers (`65 <= x`, `x + 784.48 <= 2335`, `68 <= y`, `y + 118.78 <= 1730`), and `orient ∈ {"R0", "R180", "MX", "MY"}`.

To render `flow.tcl` from `physical/flow.tcl.in` and run OpenROAD:

```bash
python3 -c '
import json, pathlib
plan = json.loads(pathlib.Path("plan/placement.json").read_text())
moves = []
for m in sorted(plan["macros"], key=lambda e: (e["bank"], e["half"])):
    name = f"cluster\\[{m[\"bank\"]}\\].mem.gen_256x128xBx1.i_cut_{m[\"half\"]}"
    moves.append(f"place_macro -macro_name {{{name}}} -location {{{m[\"x\"]} {m[\"y\"]}}} -orientation {m[\"orient\"]}")
t = (pathlib.Path("physical/flow.tcl.in").read_text()
     .replace("@PDK@", "pdk")
     .replace("@MAPPED@", "mapped.v")
     .replace("@DEF@", "placed.def")
     .replace("@GUIDE@", "route.guide")
     .replace("@PLACEMENTS@", "\n".join(moves)))
pathlib.Path("flow.tcl").write_text(t)
'
openroad -exit flow.tcl
```

## 5. Summary of Checked Physical & Timing Constraints
- **Core & Bay Geometry**:
  - Die: `2400 × 1800 µm`; Core: `(50, 50)` to `(2350, 1750) µm`; Macro size: `784.48 × 118.78 µm`.
  - Usable macro bounds: `65 <= x`, `x + 784.48 <= 2335`, `68 <= y`, `y + 118.78 <= 1730`, with `>= 20 µm` pairwise clearance in X or Y.
  - Within each bank `b`, `y(b, low) == y(b, high)` and `x(b, low) < x(b, high)`.
  - South bay (`bank` `0, 1`): `68 <= y` and `y + 118.78 <= 420`, with `y(bank 0) < y(bank 1)`.
  - North bay (`bank` `2, 3`): `1340 <= y` and `y + 118.78 <= 1730`, with `y(bank 2) < y(bank 3)`.
- **Coverage, Power Grid & Global Routing**:
  - `__PLACEMENT_OK__`, `__MACRO_COUNT__ 8`, `__CLOCK_PINS__ 8`, `__RELAY_PATHS__ 256`, and `[INFO CTS-0099]  Sinks 8`.
  - Connected `VDD` and `VSS` power grids (`All shapes on net VDD are connected`, `All shapes on net VSS are connected`).
  - Global routing (`Metal2–TopMetal1`) with `0` total overflow and route-guide net count matching `Routed nets`.
- **Clock Spread, Timing & Wirelength (`10.0 ns` clock `clk_i`)**:
  - Rise-to-rise clock network latency spread (`report_clock_latency`): `<= 0.01750 ns`.
  - Post-global-route setup slack (`max`): `>= 0.60 ns` (`MET`).
  - Post-global-route hold slack (`min`): `>= 0.05 ns` (`MET`).
  - Post-global-route Metal2–Metal5 total wirelength: `<= 1,402,000.0 µm`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ibex_prefetch_buffer.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_prefetch_buffer.sv (Golden Reference)
@@ -45,6 +45,8 @@
   logic                valid_new_req, valid_req;
   logic                valid_req_d, valid_req_q;
   logic                discard_req_d, discard_req_q;
+  logic                fault_resp;
+  logic                fault_hold_d, fault_hold_q;
   logic [NUM_REQS-1:0] rdata_outstanding_n, rdata_outstanding_s, rdata_outstanding_q;
   logic [NUM_REQS-1:0] branch_discard_n, branch_discard_s, branch_discard_q;
   logic [NUM_REQS-1:0] rdata_outstanding_rev;
@@ -114,8 +116,12 @@
   // Requests //
   //////////////
 
+  // Freeze new sequential requests after a non-discarded error response until branch_i
+  assign fault_resp   = instr_rvalid_i & instr_err_i & ~branch_discard_q[0];
+  assign fault_hold_d = (fault_hold_q | fault_resp) & ~branch_i;
+
   // Make a new request any time there is space in the FIFO, and space in the request queue
-  assign valid_new_req = req_i & (fifo_ready | branch_i) &
+  assign valid_new_req = req_i & ((fifo_ready & ~fault_hold_q) | branch_i) &
                          ~rdata_outstanding_q[NUM_REQS-1];
 
   assign valid_req = valid_req_q | valid_new_req;
@@ -217,16 +223,14 @@
     end
   end
 
-  // Shift the entries down on each instr_rvalid_i
-  assign rdata_outstanding_s = (instr_rvalid_i & ~instr_err_i) ?
-                               {1'b0,rdata_outstanding_n[NUM_REQS-1:1]} :
-                               rdata_outstanding_n;
-  assign branch_discard_s    = (instr_rvalid_i & ~instr_err_i) ?
-                               {1'b0,branch_discard_n[NUM_REQS-1:1]} :
-                               branch_discard_n;
+  // Shift the entries down on each instr_rvalid_i (including error responses)
+  assign rdata_outstanding_s = instr_rvalid_i ? {1'b0,rdata_outstanding_n[NUM_REQS-1:1]} :
+                                                rdata_outstanding_n;
+  assign branch_discard_s    = instr_rvalid_i ? {1'b0,branch_discard_n[NUM_REQS-1:1]} :
+                                                branch_discard_n;
 
   // Push a new entry to the FIFO once complete (and not cancelled by a branch)
-  assign fifo_valid = instr_rvalid_i & ~branch_discard_q[0] & ~instr_err_i;
+  assign fifo_valid = instr_rvalid_i & ~branch_discard_q[0];
 
   assign fifo_addr = addr_i;
 
@@ -238,11 +242,13 @@
     if (!rst_ni) begin
       valid_req_q          <= 1'b0;
       discard_req_q        <= 1'b0;
+      fault_hold_q         <= 1'b0;
       rdata_outstanding_q  <= 'b0;
       branch_discard_q     <= 'b0;
     end else begin
       valid_req_q          <= valid_req_d;
       discard_req_q        <= discard_req_d;
+      fault_hold_q         <= fault_hold_d;
       rdata_outstanding_q  <= rdata_outstanding_s;
       branch_discard_q     <= branch_discard_s;
     end

--- a/environment/public/code/ibex_fetch_fifo.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_fetch_fifo.sv (Golden Reference)
@@ -85,17 +85,30 @@
                                         ((valid_q[0] & err_q[0]) |
                                          (in_err_i & (~valid_q[0] | ~unaligned_is_compressed)));
 
-  // Record when an error is caused by the second half of an unaligned 32bit instruction.
-  // Only needs to be correct when unaligned and if err_unaligned is set
-  assign err_plus2       = valid_q[1] ? (err_q[1] & ~err_q[0]) :
-                                        (in_err_i & valid_q[0] & ~err_q[0]);
-
-  // An uncompressed unaligned instruction is only valid if both parts are available
+  // Record when an error is caused by the second half of an unaligned 32-bit uncompressed instruction.
+  assign err_plus2       = valid_q[1] ? (err_q[1] & ~err_q[0] & ~unaligned_is_compressed) :
+                                        (in_err_i & valid_q[0] & ~err_q[0] & ~unaligned_is_compressed);
+
+  // An uncompressed unaligned instruction is valid if both parts are available
   assign valid_unaligned = valid_q[1] ? 1'b1 :
                                         (valid_q[0] & in_valid_i);
 
+  // If there is an error, rdata is unknown
+`ifdef DII_SIM
+  logic [31:0] instr_rdata_dii;
+  logic [31:0] instr_pc;
+  logic        instr_ack;
+
+  assign unaligned_is_compressed = out_addr_o[1] & cheriot_force_uc_i
+                                 | ((instr_rdata_dii[1:0] != 2'b11) & ~err);
+  assign aligned_is_compressed   = ~out_addr_o[1] & (instr_rdata_dii[1:0] != 2'b11) & ~err;
+
+  assign instr_ack = out_ready_i & out_valid_o;
+  assign instr_pc  = out_addr_o;
+`else
   assign unaligned_is_compressed = cheriot_force_uc_i | ((rdata[17:16] != 2'b11) & ~err);
   assign aligned_is_compressed   = (rdata[ 1: 0] != 2'b11) & ~err;
+`endif
 
   ////////////////////////////////////////
   // Instruction aligner (if unaligned) //
@@ -104,18 +117,27 @@
   always_comb begin
     if (out_addr_o[1]) begin
       // unaligned case
+
+`ifdef DII_SIM
+     out_rdata_o      = instr_rdata_dii;
+`else
       out_rdata_o     = rdata_unaligned;
+`endif
       out_err_o       = err_unaligned;
       out_err_plus2_o = err_plus2;
 
-      if (unaligned_is_compressed) begin
+      if (unaligned_is_compressed || err) begin
         out_valid_o = valid;
       end else begin
         out_valid_o = valid_unaligned;
       end
     end else begin
       // aligned case
+`ifdef DII_SIM
+     out_rdata_o      = instr_rdata_dii;
+`else
       out_rdata_o     = rdata;
+`endif
       out_err_o       = err;
       out_err_plus2_o = 1'b0;
       out_valid_o     = valid;

--- a/environment/public/code/ibex_prefetch_sram_cluster.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_prefetch_sram_cluster.sv (Golden Reference)
@@ -82,12 +82,12 @@
   );
 
   for (genvar i = 0; i < 4; i = i + 1) begin : cluster
-    wire is_fetch_bank = instr_req & ~host_req_i[i] & (fetch_bank == i[1:0]);
-    wire sram_req      = host_req_i[i] | is_fetch_bank;
-    wire sram_we       = host_req_i[i] & host_we_i[i];
+    wire is_fetch_bank   = instr_req & ~host_req_i[i] & (fetch_bank == i[1:0]);
+    wire sram_req        = host_req_i[i] | is_fetch_bank;
+    wire sram_we         = host_req_i[i] & host_we_i[i];
     wire [7:0]   sram_addr = host_req_i[i] ? host_addr_i : instr_addr[11:4];
-    wire [127:0] wd        = host_mirror_i[i] ? {bank_rdata[i][127:64], host_wdata_i[63:0]} : host_wdata_i;
-    wire [15:0]  be        = host_be_i;
+    wire [127:0] wd      = host_mirror_i[i] ? {bank_rdata[i][63:0], host_wdata_i[63:0]} : host_wdata_i;
+    wire [15:0]  be      = host_mirror_i[i] ? {host_be_i[15:8] | host_be_i[7:0], host_be_i[7:0] & host_be_i[15:8]} : host_be_i;
 
     tc_sram #(
       .NumWords  ( 256 ),
@@ -106,8 +106,5 @@
     );
   end
 
-  assign cluster_xor_rdata_o = {
-    bank_rdata[0][127:64] ^ bank_rdata[1][127:64] ^ bank_rdata[2][127:64] ^ bank_rdata[3][127:64],
-    bank_rdata[0][63:0]   ^ bank_rdata[1][63:0]   ^ bank_rdata[2][63:0]
-  };
+  assign cluster_xor_rdata_o = bank_rdata[0] ^ bank_rdata[1] ^ bank_rdata[2] ^ bank_rdata[3];
 endmodule

--- a/environment/public/plan/placement.json (Buggy Starter)
+++ b/solution/gold/plan/placement.json (Golden Reference)
@@ -5,14 +5,14 @@
       "half": "low",
       "x": 100,
       "y": 120,
-      "orient": "R0"
+      "orient": "MX"
     },
     {
       "bank": 0,
       "half": "high",
       "x": 1500,
       "y": 120,
-      "orient": "R0"
+      "orient": "MX"
     },
     {
       "bank": 1,
@@ -33,14 +33,14 @@
       "half": "low",
       "x": 100,
       "y": 1360,
-      "orient": "R0"
+      "orient": "MX"
     },
     {
       "bank": 2,
       "half": "high",
       "x": 1500,
       "y": 1360,
-      "orient": "R0"
+      "orient": "MX"
     },
     {
       "bank": 3,

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/LICENSE`](environment/public/LICENSE) *(Read-Only Context)*
- [`environment/public/SOURCE.md`](environment/public/SOURCE.md) *(Read-Only Context)*
- [`environment/public/code/ibex_fetch_fifo.sv`](environment/public/code/ibex_fetch_fifo.sv) **(Editable)**
- [`environment/public/code/ibex_prefetch_buffer.sv`](environment/public/code/ibex_prefetch_buffer.sv) **(Editable)**
- [`environment/public/code/ibex_prefetch_sram_cluster.sv`](environment/public/code/ibex_prefetch_sram_cluster.sv) **(Editable)**
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/tc_sram.sv`](environment/public/code/tc_sram.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/pdk/256.lef`](environment/public/pdk/256.lef) *(Read-Only Context)*
- [`environment/public/pdk/256.lib`](environment/public/pdk/256.lib) *(Read-Only Context)*
- [`environment/public/pdk/256.v`](environment/public/pdk/256.v) *(Read-Only Context)*
- [`environment/public/pdk/256_stub.v`](environment/public/pdk/256_stub.v) *(Read-Only Context)*
- [`environment/public/pdk/LICENSE.IHP`](environment/public/pdk/LICENSE.IHP) *(Read-Only Context)*
- [`environment/public/pdk/core.v`](environment/public/pdk/core.v) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell.lef`](environment/public/pdk/sg13g2_stdcell.lef) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib`](environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_tech.lef`](environment/public/pdk/sg13g2_tech.lef) *(Read-Only Context)*
- [`environment/public/physical/flow.tcl.in`](environment/public/physical/flow.tcl.in) *(Read-Only Context)*
- [`environment/public/physical/synth.ys`](environment/public/physical/synth.ys) *(Read-Only Context)*
- [`environment/public/plan/placement.json`](environment/public/plan/placement.json) **(Editable)**

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)
The native instruction prefetch buffer and fetch FIFO are from https://github.com/lowRISC/ibex at commit `1b29dae8866e6c0f0a3cd9dead53a77b4f45e357` (`rtl/ibex_prefetch_buffer.sv`, `rtl/ibex_fetch_fifo.sv`), Apache-2.0 (`LICENSE`). The native SRAM wrapper `code/tc_sram.sv` is from https://github.com/pulp-platform/cheshire-ihp130-o at commit `560f00f1c14a7f2f22861df6bb4816eacf7f2e7e`, Solderpad Hardware License 0.51. `code/ibex_prefetch_sram_cluster.sv` is a constructed four-cluster integration around `ibex_prefetch_buffer`, `ibex_fetch_fifo`, and four `tc_sram` banks.

The macro LEF, characterized typical Liberty, behavioral model and standard-cell LEF/Liberty are from https://github.com/IHP-GmbH/IHP-Open-PDK at commit `4fdc719503662cdd21793dcc3a1506a057c5d461`, Apache-2.0 (`pdk/LICENSE.IHP`).
