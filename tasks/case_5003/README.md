# `case_5003`: CVA6 Sv39+Svnapot MMU Shared-TLB Arbitration, NAPOT Set Indexing, PLRU Refill, and PTW Flush Control

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_5003` |
| **Source Silicon Repository** | `openhwfoundation/cva6` (`repo_05`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `gatelevel_physical_effects`, `protocol_control`, `reset_rdc`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/cva6_tlb.sv`](environment/public/code/cva6_tlb.sv), [`code/cva6_shared_tlb.sv`](environment/public/code/cva6_shared_tlb.sv), [`code/cva6_ptw.sv`](environment/public/code/cva6_ptw.sv) (3 files, 2092 LOC) |
| **Public Subsystem Context** | 18 RTL files (7024 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library (Shared Base Image)** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Uses unified Nangate45 typical Liberty and LEF from base image. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CVA6 Sv39 + Svnapot MMU Shared-TLB Arbitration, NAPOT Set Aliasing, L1 Replacement, PTW Flush Cancellation, and Area/Timing Closure

In the 64-bit CVA6 Sv39/Sv39x4 MMU subsystem (`code/cva6_mmu.sv`, `code/cva6_tlb.sv`, `code/cva6_shared_tlb.sv`, and `code/cva6_ptw.sv`) with `UseSharedTlb = 1` and `SvnapotEn = 1`, instruction and data address translation exhibit four functional defects under concurrent L1/L2 lookups, 64KiB NAPOT translations, back-to-back L1 refills, and speculative pipeline flushes:

1. **Instruction translation starvation during data TLB hits**:
   - When instruction fetch misses in the L1 ITLB while the LSU simultaneously performs a data translation that **hits** in the L1 DTLB (or when data translation is disabled), the shared TLB fails to service the instruction TLB miss. Data accesses must only take priority over instruction accesses at the shared TLB when the data access itself misses in the L1 DTLB with data translation enabled.

2. **64KiB Svnapot set aliasing and concurrent walk stage-mode corruption in the shared TLB**:
   - Under `SvnapotEn = 1`, a 64KiB NAPOT leaf PTE (`pte.n = 1`, `pte.ppn[3:0] = 4'b1000` at the 4KiB level) covers all 16 contiguous 4KiB subpages (`vaddr[15:12] = 0..15`). Currently, installing a 64KiB NAPOT translation via one subpage and subsequently looking up a different subpage within the same 64KiB region misses in the shared TLB because the shared-TLB set index is derived from virtual address bits inside the 64KiB NAPOT subpage offset instead of VPN bits above the 64KiB boundary.
   - Furthermore, when a shared-TLB miss initiates a hardware page-table walk, if the other TLB port accesses the shared TLB while the walk is in flight (under a different virtualization or stage-enable configuration between instruction fetch and load/store), the eventual shared-TLB refill records the wrong requester's virtualization/stage-enable attributes.

3. **Repeated way-0 overwrite on consecutive L1 TLB refills**:
   - In the fully associative L1 TLB (`code/cva6_tlb.sv`), installing a valid refill (`update_i.valid` when not already hitting on `lu_hit_o`) does not advance the pseudo-LRU replacement state for the newly written way—causing consecutive refills on distinct virtual pages to repeatedly overwrite entry `0` instead of populating all ways.

4. **Spurious PTW activation and unsuppressed refill/fault pulses on `flush_i`**:
   - Asserting `flush_i` while the page-table walker (`code/cva6_ptw.sv`) is idle causes `ptw_active_o` to assert on the following cycle (and fails to suppress `shared_tlb_miss_o` if a shared-TLB miss coincides with `flush_i`).
   - Asserting `flush_i` on the cycle a leaf PTE lookup completes or an error/PMP access fault is being propagated fails to suppress `shared_tlb_update_o.valid`, `ptw_error_o`, and `ptw_access_exception_o` on that cycle.

5. **L1 TLB area and timing closure**:
   - When `cva6_tlb` (`TLB_ENTRIES = 2`, `HYP_EXT = 0`, `RVH = 0`, `SvnapotEn = 1`) is synthesized with Yosys + Slang against Nangate45 (`NangateOpenCellLibrary_typical.lib`) as documented in `BUILD.md`, the mapped cell area must not exceed **`2,260.0 um^2`** (with zero inferred latches across the MMU hierarchy), and must achieve nonnegative setup and hold slack (`>= 0.00 ns`) in OpenSTA at a **`2.42 ns`** clock period (`0.20 ns` input/output delays, `5.0 fF` output load).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Environment

## Source and Dependency Order
The MMU and PMP modules are extracted from CVA6 (`repo_05`), with open-licensed `lzc.sv`, `cf_math_pkg.sv`, and `include/common_cells/assertions.svh` from Croc `common_cells`.

Compilation order (with `-Iinclude` in the include search path):
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/ariane_pkg.sv`
5. `code/cf_math_pkg.sv`
6. `code/lzc.sv`
7. `code/lfsr.sv`
8. `code/tc_sram.sv`
9. `code/tc_sram_wrapper.sv`
10. `code/sram.sv`
11. `code/pmp_entry.sv`
12. `code/pmp.sv`
13. `code/pmp_data_if.sv`
14. `code/cva6_tlb.sv`
15. `code/cva6_shared_tlb.sv`
16. `code/cva6_ptw.sv`
17. `code/cva6_mmu.sv`

## Editable Files
Only the following files may be modified:
- `code/cva6_tlb.sv`
- `code/cva6_shared_tlb.sv`
- `code/cva6_ptw.sv`

All other files in `code/` and `include/` are read-only.

## Synthesis, Area, and STA Target
1. The full MMU hierarchy (`cva6_mmu`) must elaborate cleanly under Verilator 5 and synthesize under Yosys (`yosys -m slang`) with zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`).
2. `cva6_tlb` (`TLB_ENTRIES = 2`, `HYP_EXT = 0`, `XLEN = 64`, `VLEN = 64`, `PLEN = 56`, `GPLEN = 41`, `PPNW = 44`, `GPPNW = 29`, `PtLevels = 3`, `VpnLen = 27`, `SV = 39`, `SVX = 41`, `ASID_WIDTH = 16`, `VMID_WIDTH = 14`, `SvnapotEn = 1`, `RVH = 0`) is synthesized with `yosys -m slang`:
   ```
   synth -top tlb_top -flatten
   opt
   dfflibmap -liberty NangateOpenCellLibrary_typical.lib
   abc -liberty NangateOpenCellLibrary_typical.lib
   clean
   stat -liberty NangateOpenCellLibrary_typical.lib
   ```
   and timed in OpenROAD/OpenSTA with:
   - `create_clock -name clk_i -period 2.42 [get_ports clk_i]`
   - `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
   - `set_output_delay 0.20 -clock clk_i [all_outputs]`
   - `set_load 5.0 [all_outputs]`
   Targets:
   - Mapped area `<= 2,260.0 um^2`
   - Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cva6_tlb.sv (Buggy Starter)
+++ b/solution/gold/code/cva6_tlb.sv (Golden Reference)
@@ -434,7 +434,7 @@
     ) begin
       automatic int unsigned idx_base, shift, new_index;
       // we got a hit so update the pointer as it was least recently used
-      if (lu_hit[i] & lu_access_i) begin
+      if ((lu_hit[i] & lu_access_i) | (update_i.valid & replace_en[i] & !lu_hit_o)) begin
         // Set the nodes to the values we would expect
         for (int unsigned lvl = 0; lvl < $clog2(TLB_ENTRIES); lvl++) begin
           idx_base = $unsigned((2 ** lvl) - 1);

--- a/environment/public/code/cva6_shared_tlb.sv (Buggy Starter)
+++ b/solution/gold/code/cva6_shared_tlb.sv (Golden Reference)
@@ -189,8 +189,12 @@
   logic dtlb_req_d, dtlb_req_q;
 
   int i_req_d, i_req_q;
+  int walk_req_d, walk_req_q;
 
   logic [1:0][2:0] v_st_enbl;
+  localparam int unsigned IDX_LSB = CVA6Cfg.SvnapotEn ? 4 : 0;
+  logic dtlb_miss_req;
+  assign dtlb_miss_req = (|v_st_enbl[0][HYP_EXT:0]) & dtlb_access_i & ~dtlb_hit_i;
 
   // replacement strategy
   logic [SHARED_TLB_WAYS-1:0] way_valid;
@@ -215,7 +219,8 @@
   assign shared_tag_wr.asid = shared_tlb_update_i.asid;
   assign shared_tag_wr.vmid = shared_tlb_update_i.vmid;
   assign shared_tag_wr.is_page = shared_tlb_update_i.is_page;
-  assign shared_tag_wr.v_st_enbl = v_st_enbl[i_req_q][HYP_EXT*2:0];
+  assign walk_req_d = shared_tlb_miss_i ? i_req_q : walk_req_q;
+  assign shared_tag_wr.v_st_enbl = v_st_enbl[walk_req_q][HYP_EXT*2:0];
 
   genvar i_gen, x_gen;
   generate
@@ -248,7 +253,7 @@
   genvar w_gen;
   generate
     for (w_gen = 0; w_gen < CVA6Cfg.PtLevels; w_gen++) begin
-      assign vpn_d[w_gen]               = ((|v_st_enbl[1][HYP_EXT:0]) && itlb_access_i && ~itlb_hit_i && ~dtlb_access_i) ? //
+      assign vpn_d[w_gen]               = ((|v_st_enbl[1][HYP_EXT:0]) && itlb_access_i && ~itlb_hit_i && ~dtlb_miss_req) ? //
           itlb_vaddr_i[12+((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)*(w_gen+1))-1:12+((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)*w_gen)] :  //
           (((|v_st_enbl[0][HYP_EXT:0]) && dtlb_access_i && ~dtlb_hit_i) ?  //
           dtlb_vaddr_i[12+((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)*(w_gen+1))-1:12+((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)*w_gen)] : vpn_q[w_gen]);
@@ -256,7 +261,7 @@
   endgenerate
 
   if (CVA6Cfg.RVH)  //THIS UPDATES THE EXTRA BITS OF VPN IN SV39x4
-    assign vpn_d[CVA6Cfg.PtLevels] = ((|v_st_enbl[1][HYP_EXT:0]) && itlb_access_i && ~itlb_hit_i && ~dtlb_access_i) ? //
+    assign vpn_d[CVA6Cfg.PtLevels] = ((|v_st_enbl[1][HYP_EXT:0]) && itlb_access_i && ~itlb_hit_i && ~dtlb_miss_req) ? //
         {{(((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)-(CVA6Cfg.VpnLen%CVA6Cfg.PtLevels))){1'b0}}, itlb_vaddr_i[CVA6Cfg.VpnLen-1:CVA6Cfg.VpnLen-(CVA6Cfg.VpnLen%CVA6Cfg.PtLevels)]} :  //
         (((|v_st_enbl[0][HYP_EXT:0]) && dtlb_access_i && ~dtlb_hit_i) ?  //
         {{(((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)-(CVA6Cfg.VpnLen%CVA6Cfg.PtLevels))){1'b0}}, dtlb_vaddr_i[CVA6Cfg.VpnLen-1: CVA6Cfg.VpnLen-(CVA6Cfg.VpnLen%CVA6Cfg.PtLevels)]} : //
@@ -294,11 +299,11 @@
     end else if ((flush_state_q != IDLE) || flush_i || flush_vvma_i || flush_gvma_i) begin
       //minimal approach holding lookup quiet during flush
       // if we got an ITLB miss
-    end else if ((|v_st_enbl[1][HYP_EXT:0]) & itlb_access_i & ~itlb_hit_i & ~dtlb_access_i) begin
+    end else if ((|v_st_enbl[1][HYP_EXT:0]) & itlb_access_i & ~itlb_hit_i & ~dtlb_miss_req) begin
       tag_rd_en           = '1;
-      tag_rd_addr         = itlb_vaddr_i[12+:$clog2(CVA6Cfg.SharedTlbDepth)];
+      tag_rd_addr         = itlb_vaddr_i[12+IDX_LSB+:$clog2(CVA6Cfg.SharedTlbDepth)];
       pte_rd_en           = '1;
-      pte_rd_addr         = itlb_vaddr_i[12+:$clog2(CVA6Cfg.SharedTlbDepth)];
+      pte_rd_addr         = itlb_vaddr_i[12+IDX_LSB+:$clog2(CVA6Cfg.SharedTlbDepth)];
 
       itlb_miss_o         = shared_tlb_miss_i;
       itlb_req_d          = 1'b1;
@@ -312,9 +317,9 @@
       // we got an DTLB miss
     end else if ((|v_st_enbl[0][HYP_EXT:0]) & dtlb_access_i & ~dtlb_hit_i) begin
       tag_rd_en           = '1;
-      tag_rd_addr         = dtlb_vaddr_i[12+:$clog2(CVA6Cfg.SharedTlbDepth)];
+      tag_rd_addr         = dtlb_vaddr_i[12+IDX_LSB+:$clog2(CVA6Cfg.SharedTlbDepth)];
       pte_rd_en           = '1;
-      pte_rd_addr         = dtlb_vaddr_i[12+:$clog2(CVA6Cfg.SharedTlbDepth)];
+      pte_rd_addr         = dtlb_vaddr_i[12+IDX_LSB+:$clog2(CVA6Cfg.SharedTlbDepth)];
 
       dtlb_miss_o         = shared_tlb_miss_i;
       dtlb_req_d          = 1'b1;
@@ -425,6 +430,7 @@
       itlb_req_q <= '0;
       dtlb_req_q <= '0;
       i_req_q <= 0;
+      walk_req_q <= 0;
       shared_tag_valid <= '0;
       flush_state_q <= IDLE;
       flush_idx_q <= '0;
@@ -445,6 +451,7 @@
       itlb_req_q <= itlb_req_d;
       dtlb_req_q <= dtlb_req_d;
       i_req_q <= i_req_d;
+      walk_req_q <= walk_req_d;
       shared_tag_valid <= shared_tag_valid_q[tag_rd_addr];
       flush_state_q <= flush_state_d;
       flush_idx_q <= flush_idx_d;
@@ -747,7 +754,7 @@
   assign tag_wr_data = shared_tag_wr;
 
   // derive the set index from bits [4 +: clog2] of the (possibly masked) VPN
-  assign vpn_index = shared_tlb_update_i.vpn[$clog2(CVA6Cfg.SharedTlbDepth)-1:0];
+  assign vpn_index = shared_tlb_update_i.vpn[IDX_LSB+:$clog2(CVA6Cfg.SharedTlbDepth)];
   // write the new entry into that set
   assign tag_wr_addr = vpn_index;
   assign pte_wr_addr = vpn_index;
@@ -757,9 +764,7 @@
 
 
 
-  assign way_valid = shared_tag_valid_q[shared_tlb_update_i.vpn[$clog2(
-      CVA6Cfg.SharedTlbDepth
-  )-1:0]];
+  assign way_valid = shared_tag_valid_q[vpn_index];
   assign repl_way = (all_ways_valid) ? rnd_way : inv_way;
   assign update_lfsr = shared_tlb_update_i.valid & all_ways_valid;
   assign repl_way_oh_d = (shared_tlb_update_i.valid) ? shared_tlb_way_bin2oh(repl_way) : '0;
@@ -788,11 +793,11 @@
 
   assign tag_req  = tag_wr_en | tag_rd_en;
   assign tag_we   = tag_wr_en;
-  assign tag_addr = tag_wr_en ? tag_wr_addr : tag_rd_addr;
+  assign tag_addr = (|tag_wr_en) ? tag_wr_addr : tag_rd_addr;
 
   assign pte_req  = pte_wr_en | pte_rd_en;
   assign pte_we   = pte_wr_en;
-  assign pte_addr = pte_wr_en ? pte_wr_addr : pte_rd_addr;
+  assign pte_addr = (|pte_wr_en) ? pte_wr_addr : pte_rd_addr;
 
   for (genvar i = 0; i < SHARED_TLB_WAYS; i++) begin : gen_sram
     if (CVA6Cfg.UseSharedTlb) begin

--- a/environment/public/code/cva6_ptw.sv (Buggy Starter)
+++ b/solution/gold/code/cva6_ptw.sv (Golden Reference)
@@ -644,11 +644,12 @@
     // -------
     // should we have flushed before we got an rvalid, wait for it until going back to IDLE
     if (flush_i) begin
-      // on a flush check whether we are
-      // 1. in the PTE Lookup check whether we still need to wait for an rvalid
-      // 2. waiting for a grant, if so: wait for it
-      // if not, go back to idle
+      shared_tlb_update_valid = 1'b0;
+      ptw_error_o             = 1'b0;
+      ptw_access_exception_o  = 1'b0;
+      shared_tlb_miss_o       = 1'b0;
       if ((state_q inside {PTE_LOOKUP, WAIT_RVALID}) && !data_rvalid_q) state_d = WAIT_RVALID;
+      else if (state_q == IDLE) state_d = IDLE;
       else if (state_q != WAIT_GRANT) state_d = LATENCY;
 
       kill_req_n = (state_q == WAIT_GRANT);

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/DEPENDENCIES.md`](environment/public/DEPENDENCIES.md) *(Read-Only Context)*
- [`environment/public/UPSTREAM_README.md`](environment/public/UPSTREAM_README.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a60ax_config_pkg.sv`](environment/public/code/cv64a60ax_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cva6_mmu.sv`](environment/public/code/cva6_mmu.sv) *(Read-Only Context)*
- [`environment/public/code/cva6_ptw.sv`](environment/public/code/cva6_ptw.sv) **(Editable)**
- [`environment/public/code/cva6_shared_tlb.sv`](environment/public/code/cva6_shared_tlb.sv) **(Editable)**
- [`environment/public/code/cva6_tlb.sv`](environment/public/code/cva6_tlb.sv) **(Editable)**
- [`environment/public/code/lfsr.sv`](environment/public/code/lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/pmp.sv`](environment/public/code/pmp.sv) *(Read-Only Context)*
- [`environment/public/code/pmp_data_if.sv`](environment/public/code/pmp_data_if.sv) *(Read-Only Context)*
- [`environment/public/code/pmp_entry.sv`](environment/public/code/pmp_entry.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sram.sv`](environment/public/code/sram.sv) *(Read-Only Context)*
- [`environment/public/code/tc_sram.sv`](environment/public/code/tc_sram.sv) *(Read-Only Context)*
- [`environment/public/code/tc_sram_wrapper.sv`](environment/public/code/tc_sram_wrapper.sv) *(Read-Only Context)*
- [`environment/public/include/common_cells/LICENSE.Apache-2.0`](environment/public/include/common_cells/LICENSE.Apache-2.0) *(Read-Only Context)*
- [`environment/public/include/common_cells/assertions.svh`](environment/public/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

