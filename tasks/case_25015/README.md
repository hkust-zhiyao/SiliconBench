# `case_25015`: Snitch Multi-Core Isochronous Sv32 VM, Shared RV32M Hub, 4-State GLS & Multi-Corner STA Signoff

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25015` |
| **Source Silicon Repository** | `pulp-platform/snitch` (`repo_22`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `MultiCore_SoCs_and_NoC` (MultiCore_SoCs_and_NoC) |
| **Multi-Domain Tags** | `MultiCore_SoCs_and_NoC` |
| **Editable Files (`allowed_edits`)** | [`code/snitch_clkdiv2.sv`](environment/public/code/snitch_clkdiv2.sv), [`code/snitch_l0_tlb.sv`](environment/public/code/snitch_l0_tlb.sv), [`code/snitch_ptw.sv`](environment/public/code/snitch_ptw.sv), [`code/snitch_shared_muldiv.sv`](environment/public/code/snitch_shared_muldiv.sv), [`code/snitch_iso_hive.sv`](environment/public/code/snitch_iso_hive.sv), [`constraints/snitch_iso_hive.sdc`](environment/public/constraints/snitch_iso_hive.sdc) (6 files, 1109 LOC) |
| **Public Subsystem Context** | 31 RTL files (5504 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Snitch Multi-Core Isochronous Sv32 VM, Shared RV32M Hub & Multi-Corner STA Signoff

## Overview
`snitch_iso_cluster_subsys` (`code/snitch_iso_cluster_subsys.sv`, read-only) integrates `CoreCount` (`2` or `4`) dual-port L0 TLBs (`ch = 2*core + port`; port `0` = ITLB, port `1` = DTLB) bridged via synchronous 1:2 isochronous crossings (`clk_i <-> clk_d2`) into `snitch_iso_hive`, `snitch_clkdiv2`, `snitch_ptw`, and `snitch_shared_muldiv`. You own the RTL-to-STA co-design across:
- `code/snitch_clkdiv2.sv`, `code/snitch_l0_tlb.sv`, `code/snitch_ptw.sv`, `code/snitch_shared_muldiv.sv`, `code/snitch_iso_hive.sv`
- `constraints/snitch_iso_hive.sdc`

All other files under `code/` and `lib/` are read-only collateral.

## Architectural, 4-State Gate-Level & Protocol Contract
1. **Isochronous Clock Division & 4-State Reset Cleanliness**:
   - Across asynchronous active-low reset (`rst_ni == 0`) and post-reset execution, both 1:2 divided-clock operation (`clk_d2_bypass_i = 0`, `test_mode_i = 0`) and 1:1 bypass operation (`clk_d2_bypass_i = 1`) must initialize deterministically without `X`/`Z` clock or handshake lockup in 4-state gate-level simulation.
2. **Multi-Core Dual-Port Sv32 Address Translation (`AddrWidth = 34`, `NrTlbEntries = 2`)**:
   - Independently service ITLB (`port 0`) and DTLB (`port 1`) lookups across all `CoreCount` cores without cross-port or cross-core VA/PPN/PTE aliasing, supporting both `4 KiB` two-level (`lvl 0 -> lvl 1`) and `4 MiB` superpage (`lvl 0` leaf) translations, retaining `NrTlbEntries` active translations per L0 TLB via round-robin replacement without redundant PTW memory reads, and invalidating all entries upon a `tlb_req_flush_i[ch]` handshake.
   - Enforce Sv32 PTE fault semantics (`tlb_rsp_fault_o[ch] = 1`): leaf pages require `V=1`, `A=1`, `!(R==0 && W==1)`, privilege match (`U=1` in `PRIV_U`, `U=0` in `PRIV_S`), `D=1` on writes (`tlb_req_write_i`), `R=1` on data reads (`tlb_req_read_i`, so execute-only `X=1, R=0` pages permit `tlb_req_exec_i` fetches while faulting data reads), `W=1` on writes, and `X=1` on instruction fetches. non-leaf pointers (`V=1, R=W=X=0`) are valid only at level 0 (level-1 pointers fault), misaligned level-0 superpages (`pte.pa[9:0] != 0`) must fault without corrupting subsequent `4 KiB` walks in that `4 MiB` region, and PTW memory errors (`ptw_mem_perror_i = 1`) must fault the miss (`tlb_rsp_fault_o[ch] = 1`) without poisoning subsequent translations to other pages in the same `4 MiB` region.
3. **Shared RV32M Offload & Exception Retirement (`DataWidth = 32`)**:
   - Execute concurrent multi-core `MUL`, `MULH`, `MULHSU`, `MULHU`, `DIV`, `DIVU`, `REM`, and `REMU` offloads (including RISC-V divide-by-zero and signed overflow corner cases), preserving per-core `acc_qid_i -> acc_pid_o` tags under backpressure.
   - Unsupported `acc_qop_i` encodings must complete the `acc_qvalid_i`/`acc_qready_o` request handshake and retire a response beat (`acc_pvalid_o`/`acc_pready_i`) with matching `acc_pid_o` and `acc_perror_o = 1'b1` instead of stalling the shared arbiter.

## Synthesis & Multi-Corner Nangate45 STA Signoff (`CoreCount = 4`)
- **Netlist Integrity**: Synthesize cleanly to Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`) with zero inferred latches, zero combinational loops, and `snitch_clkdiv2` hierarchy preserved.
- **SDC (`constraints/snitch_iso_hive.sdc`)**:
  - Constrain `clk_i` with `create_clock` at period `<= 3.15` ns, set `set_case_analysis 0` on `test_mode_i` and `clk_d2_bypass_i`, and declare `create_generated_clock -divide_by 2 -source [get_ports clk_i]` on the `snitch_clkdiv2` divider pin (`*i_snitch_clkdiv2*`).
  - Specify `set_clock_uncertainty` `>= 0.08` ns (setup) and `>= 0.02` ns (hold) on all clocks, and constrain all synchronous data/handshake inputs and all outputs against `clk_i`'s clock with `-max >= 0.40` ns and `0.02 <= -min <= 0.10` ns.
  - Only `rst_ni` may carry `set_false_path`; `set_clock_groups`, `set_multicycle_path`, `set_max_delay`, `set_min_delay`, and `set_disable_timing` are prohibited.
- **Multi-Corner Signoff**: Must achieve `WNS >= 0.0` ns (setup) and `min slack >= 0.0` ns (hold) in OpenROAD STA across slow (`-late 1.25 -early 1.00`) and fast (`-late 1.00 -early 0.75`) derate corners in both 1:2 divided (`clk_d2_bypass_i = 0`) and 1:1 bypass (`clk_d2_bypass_i = 1`) modes.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment (`case_25015`)

## Available Tools & Collateral
- **RTL Simulation**: Verilator (`verilator --binary --timing`)
- **4-State Gate-Level Simulation**: Yosys (`yosys -m slang`) + Icarus Verilog (`iverilog -g2012` / `vvp`) with Yosys `simcells.v`
- **Technology Mapping & Multi-Corner STA**: Yosys + OpenROAD (`openroad -exit`) using Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`, `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`)

## Editable Files
- `code/snitch_clkdiv2.sv`
- `code/snitch_l0_tlb.sv`
- `code/snitch_ptw.sv`
- `code/snitch_shared_muldiv.sv`
- `code/snitch_iso_hive.sv`
- `constraints/snitch_iso_hive.sdc`

## Example Commands
```bash
# 1. Verilator Elaboration & Lint (CoreCount = 2 or 4)
verilator --lint-only -Wno-fatal -Wno-UNOPTFLAT -GCoreCount=4 -Icode \
  -top-module snitch_iso_cluster_subsys \
  code/dm_pkg.sv code/axi_pkg.sv code/cf_math_pkg.sv code/reqrsp_pkg.sv \
  code/riscv_instr.sv code/snitch_pkg.sv code/cc_onehot.sv code/lzc.sv \
  code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
  code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
  code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
  code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
  code/reqrsp_iso.sv code/snitch_clkdiv2.sv code/snitch_l0_tlb.sv \
  code/snitch_ptw.sv code/snitch_shared_muldiv.sv code/snitch_iso_hive.sv \
  code/snitch_iso_cluster_subsys.sv

# 2. Nangate45 Synthesis (CoreCount = 4, preserving snitch_clkdiv2)
yosys -m slang -p "
  read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -Icode \
    code/dm_pkg.sv code/axi_pkg.sv code/cf_math_pkg.sv code/reqrsp_pkg.sv \
    code/riscv_instr.sv code/snitch_pkg.sv code/cc_onehot.sv code/lzc.sv \
    code/onehot_to_bin.sv code/rr_arb_tree.sv code/spill_register_flushable.sv \
    code/spill_register.sv code/fall_through_register.sv code/fifo_v3.sv \
    code/isochronous_4phase_handshake.sv code/isochronous_spill_register.sv \
    code/stream_arbiter_flushable.sv code/stream_arbiter.sv code/stream_demux.sv \
    code/reqrsp_iso.sv code/snitch_clkdiv2.sv code/snitch_l0_tlb.sv \
    code/snitch_ptw.sv code/snitch_shared_muldiv.sv code/snitch_iso_hive.sv \
    code/snitch_iso_cluster_subsys.sv --top snitch_iso_cluster_subsys -G CoreCount=4;
  hierarchy -check -top snitch_iso_cluster_subsys;
  setattr -mod -set keep_hierarchy 1 snitch_clkdiv2;
  synth -noabc -top snitch_iso_cluster_subsys -flatten;
  delete t:\$scopeinfo; scc -expect 0;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -script +strash\;scorr\;dc2\;strash\;dch,-f\;map\;buffer,-N,8;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/ng45.v
"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/snitch_clkdiv2.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_clkdiv2.sv (Golden Reference)
@@ -14,8 +14,12 @@
 
   logic clk_div;
 
-  always_ff @(posedge clk_i) begin
-    clk_div <= ~clk_div;
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      clk_div <= 1'b0;
+    end else begin
+      clk_div <= ~clk_div;
+    end
   end
 
   assign clk_o = (test_mode_i | bypass_i) ? clk_i : clk_div;

--- a/environment/public/code/snitch_l0_tlb.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_l0_tlb.sv (Golden Reference)
@@ -44,50 +44,41 @@
   input  l0_pte_t pte_i,
   /// Translation is 4 mega.
   input  logic is_4mega_i
-  /// For page faults we'll just make sure that the `a` bit is cleared so that
-  /// a subsequent hit in the L0 will cause a page fault.
 );
 
   typedef struct packed {
-    /// Virtual address to match.
-    va_t va;
-    /// This is a 4 mega page entry.
+    va_t  va;
     logic is_4mega;
   } tag_t;
+
   tag_t [NrEntries-1:0] tag_d, tag_q;
-  logic [NrEntries-1:0] is_4mega_exp; //expanded version
+  logic [NrEntries-1:0] is_4mega_exp;
   logic is_4mega;
-  // Tag is valid array.
   logic [NrEntries-1:0] tag_valid_d, tag_valid_q;
   logic [$clog2(NrEntries+1)-1:0] evict_d, evict_q;
 
   l0_pte_t [NrEntries-1:0] pte_q, pte_d;
-
   l0_pte_t pte;
 
   `FFAR(tag_valid_q, tag_valid_d, '0, clk_i, rst_i)
-  `FFNR(tag_q, tag_d, clk_i)
-  `FFNR(pte_q, pte_d, clk_i)
+  `FFAR(tag_q, tag_d, '0, clk_i, rst_i)
+  `FFAR(pte_q, pte_d, '0, clk_i, rst_i)
 
   logic [NrEntries-1:0] hit;
-  logic miss_d, miss_q; // we got a miss
-  logic refill_d, refill_q; // refill request is underway
+  logic miss_d, miss_q;
+  logic refill_d, refill_q;
 
   `FFAR(miss_q, miss_d, '0, clk_i, rst_i)
   `FFAR(refill_q, refill_d, '0, clk_i, rst_i)
 
-  // Tag Comparison
   for (genvar i = 0; i < NrEntries; i++) begin : gen_tag_cmp
-    // Either VPN1 *and* VPN0 matches or this is a 4 MiB access in case only VPN1 needs to match.
     assign hit[i] = tag_valid_q[i]
       & (va_i.vpn1 == tag_q[i].va.vpn1 & (tag_q[i].is_4mega | (va_i.vpn0 == tag_q[i].va.vpn0)));
     assign is_4mega_exp[i] = tag_q[i].is_4mega & hit[i];
   end
-  // is the matching entry a 4 mega entry?
   assign is_4mega = |is_4mega_exp;
 
   localparam int unsigned L0PteSize = $bits(l0_pte_t);
-  // Reduce to generate mask
   /* verilator lint_off ALWCOMBORDER */
   always_comb begin
     pte = '0;
@@ -97,46 +88,33 @@
 
   assign ready_o = |hit;
 
-  // Determine access rights
   logic access_allowed;
-  assign access_allowed = // for execute access `x` must be set
-                           (pte.flags.x & execute_i | ~execute_i)
-                          // for write access `w` must be set
-                        &  (pte.flags.w & write_i | ~write_i)
-                          // for read access `r` must be set
-                        &  (pte.flags.r & ~read_i | read_i)
-                          // the pte must be accessible
-                        &   pte.flags.a
-                          // if written the dirty bit must be set
-                        &  (pte.flags.d & write_i | ~write_i)
-                          // if the processor is in U-mode the U bit must be set
-                        &  (pte.flags.u & priv_lvl_i == PrivLvlU | priv_lvl_i == PrivLvlS)
-                          // if the processor is in S-mode the U bit must not be set
-                        & (~pte.flags.u & priv_lvl_i == PrivLvlS | priv_lvl_i == PrivLvlU);
+  assign access_allowed = (pte.flags.x & execute_i | ~execute_i)
+                        & (pte.flags.w & write_i | ~write_i)
+                        & (pte.flags.r & read_i | ~read_i)
+                        &  pte.flags.a
+                        & (pte.flags.d & write_i | ~write_i)
+                        & (pte.flags.u & (priv_lvl_i == PrivLvlU) | (priv_lvl_i == PrivLvlS))
+                        & (~pte.flags.u & (priv_lvl_i == PrivLvlS) | (priv_lvl_i == PrivLvlU));
 
   assign page_fault_o = ~access_allowed;
 
-  // mask ppn0 in case of a 4mega page and substitute with virtual address
   assign pa_o = {pte.pa.ppn1, (pte.pa.ppn0 & {10{~is_4mega}}) | (va_i.vpn0 & {10{is_4mega}})};
 
-  assign miss_d = valid_i & ~(|hit); // valid request but no hit
-
-  assign valid_o = miss_q & refill_q; // Don't (re-)request the cycle after we got a response.
+  assign miss_d = valid_i & ~(|hit);
+  assign valid_o = miss_q & refill_q;
   assign va_o = va_i;
 
-  // A valid handshake resets, otherwise keep the request stable.
   always_comb begin
     refill_d = 1'b1;
     if (valid_o && ready_i) refill_d = 1'b0;
   end
 
-  // L0 update.
   always_comb begin
     tag_valid_d = tag_valid_q;
     tag_d = tag_q;
     pte_d = pte_q;
 
-    // A new, valid response arrived - update the content.
     if (valid_o && ready_i) begin
       pte_d[evict_q] = pte_i;
       tag_d[evict_q].va = va_i;
@@ -147,17 +125,18 @@
     if (flush_i) tag_valid_d = '0;
   end
 
-  // Eviction strategy: round-robin
   if (NrEntries > 1) begin : gen_evict_counter
     `FFAR(evict_q, evict_d, '0, clk_i, rst_i)
     always_comb begin
       evict_d = evict_q;
-      if (valid_o && ready_i) evict_d++;
-      if (evict_d == NrEntries - 1) evict_d = 0; // evict pointer wraps
+      if (valid_o && ready_i) begin
+        if (evict_q == NrEntries - 1) evict_d = '0;
+        else evict_d = evict_q + 1'b1;
+      end
     end
   end else begin : gen_no_evict_counter
-    assign evict_q = 0;
-    assign evict_d = 0;
+    assign evict_q = '0;
+    assign evict_d = '0;
   end
 
 endmodule

--- a/environment/public/code/snitch_ptw.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_ptw.sv (Golden Reference)
@@ -7,7 +7,7 @@
 `include "common_cells/registers.svh"
 `include "common_cells/assertions.svh"
 
-/// Page table walker (PTW) for RISC-V (Custom)Sv32 address translation.
+/// Page table walker (PTW) for RISC-V Sv32 address translation.
 module snitch_ptw import snitch_pkg::*; #(
   parameter int unsigned AddrWidth = 64,
   parameter int unsigned DataWidth = 64,
@@ -16,29 +16,21 @@
   parameter type pa_t = logic,
   parameter type l0_pte_t = logic,
   parameter type pte_sv32_t = logic,
-  /// Derived parameter. *Do not change*
   parameter int unsigned PPNSize = AddrWidth - PAGE_SHIFT
 ) (
   input  logic                clk_i,
   input  logic                rst_ni,
-  /// Possibly extended physical page number (base)
   input  logic [PPNSize-1:0]  ppn_i,
   input  logic                valid_i,
   output logic                ready_o,
   input  va_t                 va_i,
   output l0_pte_t             pte_o,
-  /// Is this a 4 mega page i.e,. super-page
   output logic                is_4mega_o,
-  /// Memory interface
   output dreq_t               data_req_o,
   input  drsp_t               data_rsp_i
 );
 
-  /// Page Table Entry Size in Bytes
-  /// If we need to address more than 34 bit, the PTE needs to be 8 bytes wide,
-  /// otherwise 4 bytes are sufficient.
   localparam int unsigned PTESize = AddrWidth > 34 ? 8 : 4;
-  // Address offset dependent on PTE size.
   localparam int unsigned PTEAddrOffset = $clog2(PTESize);
 
   typedef enum logic [1:0] {
@@ -55,44 +47,22 @@
 
   pte_sv32_t pte;
   l0_pte_t pte_d, pte_q;
+  logic pte_ld;
   logic is_4mega_d, is_4mega_q;
+
   assign pte = pte_sv32_t'(data_rsp_i.p.data[$size(pte_sv32_t)-1:0]);
-  `FFLNR(pte_q, pte_d, (data_rsp_i.p_valid & data_req_o.p_ready), clk_i)
-  `FFNR(is_4mega_q, is_4mega_d, clk_i)
-
-  `FFNR(lvl_q, lvl_d, clk_i)
+  `FFLARN(pte_q, pte_d, pte_ld, '0, clk_i, rst_ni)
+  `FFARN(is_4mega_q, is_4mega_d, 1'b0, clk_i, rst_ni)
+  `FFARN(lvl_q, lvl_d, '0, clk_i, rst_ni)
 
   assign pte_o = pte_q;
   assign is_4mega_o = is_4mega_q;
 
-  //-------------------
-  // Page table walker
-  //-------------------
-  // A virtual address va is translated into a physical address pa as follows:
-  // 1. Let a be sptbr.ppn x PAGESIZE, and let i = LEVELS-1.
-  ///   (For CustomSv32, PAGESIZE=2^14 and LEVELS=2.)
-  ///   (For Sv32, PAGESIZE=2^12 and LEVELS=2. )
-  // 2. Let pte be the value of the PTE at address a+va.vpn[i] x PTESIZE.
-  ///   (For CustomSv32, PTESIZE=8.)
-  ///   (For Sv32, PTESIZE=4. )
-  // 3. If pte.v = 0, or if pte.r = 0 and pte.w = 1, stop and raise a page-fault exception corresponding
-  //    to the original access type.
-  // 4. Otherwise, the PTE is valid. If pte.r = 1 or pte.x = 1, go to step 5.
-  //    Otherwise, this PTE is a pointer to the next level of the page table.
-  //    Let i=i-1. If i < 0, stop and raise an access exception. Otherwise, let
-  //    a = pte.ppn x PAGESIZE and go to step 2.
-  // 5. A leaf PTE has been found. Determine if the requested memory access is allowed by the
-  //    pte.r, pte.w, pte.x, and pte.u bits, given the current privilege mode and the value of the
-  //    SUM and MXR fields of the mstatus register. If not, stop and raise a page-fault exception
-  //    corresponding to the original access type.
-  // 6. If i > 0 and pte.ppn [i-1:0] != 0, this is a misaligned superpage; stop and raise a page-fault
-  //    exception corresponding to the original access type.
   always_comb begin
     automatic logic [PAGE_SHIFT-1:0] page_table_index;
-    // As of now this is a read only interface.
     data_req_o.q.amo = reqrsp_pkg::AMONone;
     data_req_o.q.data = '0;
-    data_req_o.q.write = 0;
+    data_req_o.q.write = 1'b0;
     data_req_o.q.strb = '0;
 
     lvl_d = lvl_q;
@@ -105,7 +75,7 @@
     data_req_o.p_ready = 1'b1;
 
     ready_o = 1'b0;
-    // unpack the PTE to the more space efficient L0 PTE.
+    pte_ld  = 1'b0;
     pte_d.pa = pte.pa;
     pte_d.flags = '{
       d: pte.d,
@@ -118,91 +88,61 @@
     is_4mega_d = is_4mega_q;
 
     unique case (state_q)
-      //  Let's accept a new incoming lookup here.
-      Idle:  begin
-        lvl_d = 0;
+      Idle: begin
+        lvl_d = '0;
         data_req_o.q_valid = valid_i;
-        // First look-up can be done here.
         if (valid_i && data_rsp_i.q_ready) begin
           state_d = WaitPTE;
         end
       end
-      // Do the lookup
+
       LookupPTE: begin
-        // Check that we are not infinitely recursing.
-        if (lvl_q < 2) begin
+        if (lvl_q < 2'd2) begin
           data_req_o.q_valid = 1'b1;
-          // Compose virtual address;
           page_table_index = $unsigned({va_i.vpn0, {{PTEAddrOffset}{1'b0}}});
           data_req_o.q.addr = $unsigned({pte_q.pa, page_table_index});
           if (data_rsp_i.q_ready) state_d = WaitPTE;
         end else begin
-          pte_d.flags.a = '0; // clear PTE.a making it invalid for downstream
+          pte_d = pte_q;
+          pte_d.flags = '0;
+          pte_ld = 1'b1;
+          is_4mega_d = 1'b0;
           state_d = ReturnPTE;
         end
       end
-      // Wait for the PTE to return from memory
+
       WaitPTE: begin
-        is_4mega_d = 1'b0;
         if (data_rsp_i.p_valid) begin
-          // increase lvl
-          lvl_d++;
-          // Something went wrong. Clear the access bit.
-          if (pte.v == 0 || (pte.r == 0 && pte.w == 1)) begin
-            pte_d.flags.a = 1'b0;
+          pte_ld = 1'b1;
+          is_4mega_d = 1'b0;
+          lvl_d = lvl_q + 2'd1;
+          if (data_rsp_i.p.error || pte.v == 1'b0 || (pte.r == 1'b0 && pte.w == 1'b1)) begin
+            pte_d.flags = '0;
+            is_4mega_d = 1'b0;
             state_d = ReturnPTE;
-          // This is a legit page.
-          end else if (pte.r == 1 || pte.x == 1) begin
-            // is this a super-page?
-            if (lvl_q < 1) begin
-              is_4mega_d = 1'b1;
-              // Check for misaligned super pages.
-              if (pte_d.pa.ppn0 != 0) pte_d.flags.a = '0;
+          end else if (pte.r == 1'b1 || pte.x == 1'b1) begin
+            if (lvl_q < 2'd1) begin
+              if (pte_d.pa.ppn0 != '0) begin
+                pte_d.flags = '0;
+                is_4mega_d = 1'b0;
+              end else begin
+                is_4mega_d = 1'b1;
+              end
             end
             state_d = ReturnPTE;
-          // This is a pointer to the next level.
-          end else state_d = LookupPTE;
-          // in case we got an access error
-          if (data_rsp_i.p.error) begin
-            pte_d.flags.a = '0;
-            state_d = ReturnPTE;
+          end else begin
+            state_d = LookupPTE;
           end
         end
       end
-      // Communicate the result.
+
       ReturnPTE: begin
         ready_o = 1'b1;
         state_d = Idle;
       end
-      default : /* default */;
+
+      default: state_d = Idle;
     endcase
   end
 
-  // check that we use the full virtual address
-  `ASSERT_INIT(SanityVirtualAddress, PAGE_SHIFT + VPN_SIZE * 2 == 32)
-  // Check that definitions are coherent
-  `ASSERT_INIT(SanityPhysicalAddress, PPNSize == $bits(pa_t))
-  // check that we can address the entire physical address space
-  `ASSERT_INIT(SanityPhysicalAddressSpace, PPNSize + PAGE_SHIFT == AddrWidth)
-  // check data width is sane
-  `ASSERT_INIT(SanityDataWidth, DataWidth >= PPNSize && DataWidth >= 32 && DataWidth == PTESize * 8)
-  // assert stability
-  // translation request
-  `ASSERT(VAReqStable, valid_i && !ready_o |=> valid_i)
-  `ASSERT(VAReqDataStable, valid_i && !ready_o |=> ($stable(va_i) && $stable(ppn_i)))
-  // data request
-  `ASSERT(RefillReqStable, data_req_o.q_valid && !data_rsp_i.q_ready |=> data_req_o.q_valid)
-  `ASSERT(RefillReqDataStable,
-      data_req_o.q_valid && !data_rsp_i.q_ready |=> $stable(data_req_o.q.addr))
-  // data response
-  `ASSERT(RefillRspStable, data_rsp_i.p_valid && !data_req_o.p_ready |=> data_rsp_i.p_valid)
-  `ASSERT(RefillRspDataStable,
-      data_rsp_i.p_valid && !data_req_o.p_ready |=>
-      $stable(data_rsp_i.p.data) && $stable(data_rsp_i.p.error))
-  // make sure that the VPN and the addressing needed for the size of the PTE
-  // fits within the page index, otherwise we can't index the entire page but
-  // only a fraction of it.
-  // TODO(zarubaf): Fix. This might not be a problem since the lookup address
-  // will be aligned to the PTE size.
-  // `ASSERT_INIT(VPNSanity, VPN_SIZE + $clog2(PTESize) <= PAGE_SHIFT)
 endmodule

--- a/environment/public/code/snitch_shared_muldiv.sv (Buggy Starter)
+++ b/solution/gold/code/snitch_shared_muldiv.sv (Golden Reference)
@@ -2,24 +2,20 @@
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
 
-/// Shared Multiply/Divide a.k.a M Extension
+/// Shared Multiply/Divide (RV32M) with pipelined multiplier, aligned serial divider,
+/// and non-blocking illegal-opcode error retirement.
 `include "common_cells/registers.svh"
-/// Based on Ariane's Multiply Divide
-/// Author: Michael Schaffner,  <schaffner@iis.ee.ethz.ch>
-/// Author: Florian Zaruba , <zarubaf@iis.ee.ethz.ch>
 
 module snitch_shared_muldiv #(
-  parameter int unsigned IdWidth = 5,
-  parameter int unsigned DataWidth = 0,
-  /// Derived parameter *Do not override*
-  parameter type data_t = logic [DataWidth-1:0]
+  parameter int unsigned IdWidth   = 5,
+  parameter int unsigned DataWidth = 32,
+  parameter type         data_t    = logic [DataWidth-1:0]
 ) (
   input  logic                clk_i,
   input  logic                rst_ni,
-  // Accelerator Interface - Slave
-  input  logic  [31:0]        acc_qaddr_i,  // unused
-  input  logic  [IdWidth-1:0] acc_qid_i,
-  input  logic  [31:0]        acc_qdata_op_i,  // RISC-V instruction
+  input  logic [31:0]         acc_qaddr_i,
+  input  logic [IdWidth-1:0]  acc_qid_i,
+  input  logic [31:0]         acc_qdata_op_i,
   input  data_t               acc_qdata_arga_i,
   input  data_t               acc_qdata_argb_i,
   input  data_t               acc_qdata_argc_i,
@@ -32,24 +28,29 @@
   input  logic                acc_pready_i
 );
   typedef struct packed {
-    logic [31:0] result;
+    logic               error;
+    logic [31:0]        result;
     logic [IdWidth-1:0] id;
   } result_t;
-  // input handshake
+
   logic div_valid_op, div_ready_op;
   logic mul_valid_op, mul_ready_op;
-  // output handshake
+  logic err_valid_op, err_ready_op;
+
   logic mul_valid, mul_ready;
   logic div_valid, div_ready;
-  result_t div, mul, oup;
-  logic illegal_instruction;
+  logic err_valid_q, err_ready;
+  logic [IdWidth-1:0] err_id_q;
+
+  result_t div_res, mul_res, err_res, oup;
+
+  assign err_ready_op = ~err_valid_q | err_ready;
 
   always_comb begin
     mul_valid_op = 1'b0;
     div_valid_op = 1'b0;
+    err_valid_op = 1'b0;
     acc_qready_o = 1'b0;
-    acc_perror_o = 1'b0;
-    illegal_instruction = 1'b0;
     unique casez (acc_qdata_op_i)
       riscv_instr::MUL, riscv_instr::MULH, riscv_instr::MULHSU, riscv_instr::MULHU: begin
         mul_valid_op = acc_qvalid_i;
@@ -59,102 +60,109 @@
         div_valid_op = acc_qvalid_i;
         acc_qready_o = div_ready_op;
       end
-      default: illegal_instruction = 1'b1;
+      default: begin
+        err_valid_op = acc_qvalid_i;
+        acc_qready_o = err_ready_op;
+      end
     endcase
   end
 
-  // Multiplication
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      err_valid_q <= 1'b0;
+      err_id_q    <= '0;
+    end else begin
+      if (err_valid_op && err_ready_op) begin
+        err_valid_q <= 1'b1;
+        err_id_q    <= acc_qid_i;
+      end else if (err_valid_q && err_ready) begin
+        err_valid_q <= 1'b0;
+      end
+    end
+  end
+
+  assign mul_res.error = 1'b0;
+  assign div_res.error = 1'b0;
+  assign err_res       = '{error: 1'b1, result: 32'b0, id: err_id_q};
+
   snitch_shared_muldiv_multiplier #(
-    .Width     (32),
-    .IdWidth   (IdWidth)
+    .Width   ( 32      ),
+    .IdWidth ( IdWidth )
   ) i_multiplier (
-    .clk_i,
-    .rst_ni,
-    .id_i       (acc_qid_i),
-    .operator_i (acc_qdata_op_i),
-    .operand_a_i(acc_qdata_arga_i[31:0]),
-    .operand_b_i(acc_qdata_argb_i[31:0]),
-    .valid_i    (mul_valid_op),
-    .ready_o    (mul_ready_op),
-    .result_o   (mul.result),
-    .valid_o    (mul_valid),
-    .ready_i    (mul_ready),
-    .id_o       (mul.id)
+    .clk_i       ( clk_i                  ),
+    .rst_ni      ( rst_ni                 ),
+    .id_i        ( acc_qid_i              ),
+    .operator_i  ( acc_qdata_op_i         ),
+    .operand_a_i ( acc_qdata_arga_i[31:0] ),
+    .operand_b_i ( acc_qdata_argb_i[31:0] ),
+    .valid_i     ( mul_valid_op           ),
+    .ready_o     ( mul_ready_op           ),
+    .result_o    ( mul_res.result         ),
+    .valid_o     ( mul_valid              ),
+    .ready_i     ( mul_ready              ),
+    .id_o        ( mul_res.id             )
   );
-  // Serial Divider
+
   snitch_shared_muldiv_serdiv #(
-    .WIDTH     (32),
-    .IdWidth   (IdWidth)
+    .WIDTH   ( 32      ),
+    .IdWidth ( IdWidth )
   ) i_div (
-    .clk_i     (clk_i),
-    .rst_ni    (rst_ni),
-    .id_i      (acc_qid_i),
-    .operator_i(acc_qdata_op_i),
-    .op_a_i    (acc_qdata_arga_i[31:0]),
-    .op_b_i    (acc_qdata_argb_i[31:0]),
-    .in_vld_i  (div_valid_op),
-    .in_rdy_o  (div_ready_op),
-    .out_vld_o (div_valid),
-    .out_rdy_i (div_ready),
-    .id_o      (div.id),
-    .res_o     (div.result)
+    .clk_i      ( clk_i                  ),
+    .rst_ni     ( rst_ni                 ),
+    .id_i       ( acc_qid_i              ),
+    .operator_i ( acc_qdata_op_i         ),
+    .op_a_i     ( acc_qdata_arga_i[31:0] ),
+    .op_b_i     ( acc_qdata_argb_i[31:0] ),
+    .in_vld_i   ( div_valid_op           ),
+    .in_rdy_o   ( div_ready_op           ),
+    .out_vld_o  ( div_valid              ),
+    .out_rdy_i  ( div_ready              ),
+    .id_o       ( div_res.id             ),
+    .res_o      ( div_res.result         )
   );
-  // Output Arbitration
+
   stream_arbiter #(
-    .DATA_T(result_t),
-    .N_INP (2)
+    .DATA_T ( result_t ),
+    .N_INP  ( 3        )
   ) i_stream_arbiter (
-    .clk_i,
-    .rst_ni     (rst_ni),
-    .inp_data_i ({div, mul}),
-    .inp_valid_i({div_valid, mul_valid}),
-    .inp_ready_o({div_ready, mul_ready}),
-    .oup_data_o (oup),
-    .oup_valid_o(acc_pvalid_o),
-    .oup_ready_i(acc_pready_i)
+    .clk_i       ( clk_i                              ),
+    .rst_ni      ( rst_ni                             ),
+    .inp_data_i  ( {err_res, div_res, mul_res}        ),
+    .inp_valid_i ( {err_valid_q, div_valid, mul_valid}),
+    .inp_ready_o ( {err_ready, div_ready, mul_ready}  ),
+    .oup_data_o  ( oup                                ),
+    .oup_valid_o ( acc_pvalid_o                       ),
+    .oup_ready_i ( acc_pready_i                       )
   );
-  assign acc_pdata_o = {32'b0, oup.result};
-  assign acc_pid_o   = oup.id;
+
+  assign acc_pdata_o  = data_t'(oup.result);
+  assign acc_pid_o    = oup.id;
+  assign acc_perror_o = oup.error;
 endmodule
 
 module snitch_shared_muldiv_multiplier #(
-  parameter int unsigned Width   = 64,
+  parameter int unsigned Width   = 32,
   parameter int unsigned IdWidth = 5
 ) (
   input  logic               clk_i,
   input  logic               rst_ni,
   input  logic [IdWidth-1:0] id_i,
-  input  logic [       31:0] operator_i,
-  input  logic [  Width-1:0] operand_a_i,
-  input  logic [  Width-1:0] operand_b_i,
+  input  logic [31:0]        operator_i,
+  input  logic [Width-1:0]   operand_a_i,
+  input  logic [Width-1:0]   operand_b_i,
   input  logic               valid_i,
   output logic               ready_o,
-  output logic [  Width-1:0] result_o,
+  output logic [Width-1:0]   result_o,
   output logic               valid_o,
   input  logic               ready_i,
   output logic [IdWidth-1:0] id_o
 );
-  // Pipeline register
-  logic [IdWidth-1:0] id_q;
-  logic valid_d, valid_q;
-  logic select_upper_q, select_upper_d;
-  logic [2*Width-1:0] result_d, result_q;
-
-  // control registers
-  logic sign_a, sign_b;
-  // control signals
-  assign ready_o = ~valid_o | ready_i;
-  // datapath
-  logic [2*Width-1:0] mult_result;
-  assign mult_result = $signed(
-      {operand_a_i[Width-1] & sign_a, operand_a_i}
-  ) * $signed(
-      {operand_b_i[Width-1] & sign_b, operand_b_i}
-  );
-  // Sign Select MUX
+  logic sign_a, sign_b, select_upper_d;
+
   always_comb begin
     sign_a = 1'b0;
     sign_b = 1'b0;
+    select_upper_d = 1'b0;
     unique casez (operator_i)
       riscv_instr::MULH: begin
         sign_a = 1'b1;
@@ -168,190 +176,179 @@
         sign_a = 1'b1;
         select_upper_d = 1'b1;
       end
-      // MUL performs an XLEN-bit × XLEN-bit multiplication and places the lower
-      // XLEN bits in the destination register
-      default: begin  // including MUL
+      default: begin
         select_upper_d = 1'b0;
       end
     endcase
   end
-  // single stage version
-  assign result_d = $signed(
-      {operand_a_i[Width-1] & sign_a, operand_a_i}
-  ) * $signed(
-      {operand_b_i[Width-1] & sign_b, operand_b_i}
-  );
-  // ressult mux
-  always_comb begin
-    result_o = result_q[Width-1:0];
-    if (select_upper_q) begin
-      result_o = result_q[2*Width-1:Width];
+
+  // 2-stage partial-product pipeline (17x17 partial multipliers in Stage 1, final sum in Stage 2)
+  logic signed [16:0] a_lo, a_hi, b_lo, b_hi;
+  assign a_lo = {1'b0, operand_a_i[15:0]};
+  assign a_hi = {operand_a_i[31] & sign_a, operand_a_i[31:16]};
+  assign b_lo = {1'b0, operand_b_i[15:0]};
+  assign b_hi = {operand_b_i[31] & sign_b, operand_b_i[31:16]};
+
+  logic signed [33:0] pp_ll_d, pp_lh_d, pp_hl_d, pp_hh_d;
+  assign pp_ll_d = a_lo * b_lo;
+  assign pp_lh_d = a_lo * b_hi;
+  assign pp_hl_d = a_hi * b_lo;
+  assign pp_hh_d = a_hi * b_hi;
+
+  logic s1_valid_q, s2_valid_q;
+  logic s1_ready, s2_ready;
+  logic s1_upper_q, s2_upper_q;
+  logic [IdWidth-1:0] s1_id_q, s2_id_q;
+  logic signed [33:0] pp_ll_q, pp_lh_q, pp_hl_q, pp_hh_q;
+  logic [63:0] s2_prod_d, s2_prod_q;
+
+  assign s2_ready = ~s2_valid_q | ready_i;
+  assign s1_ready = ~s1_valid_q | s2_ready;
+  assign ready_o  = s1_ready;
+
+  logic signed [34:0] mid_sum;
+  assign mid_sum   = $signed(pp_lh_q) + $signed(pp_hl_q);
+  assign s2_prod_d = {pp_hh_q[31:0], 32'b0}
+                   + {{13{mid_sum[34]}}, mid_sum, 16'b0}
+                   + {32'b0, pp_ll_q[31:0]};
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      s1_valid_q <= 1'b0;
+      s1_upper_q <= 1'b0;
+      s1_id_q    <= '0;
+      pp_ll_q    <= '0;
+      pp_lh_q    <= '0;
+      pp_hl_q    <= '0;
+      pp_hh_q    <= '0;
+      s2_valid_q <= 1'b0;
+      s2_upper_q <= 1'b0;
+      s2_id_q    <= '0;
+      s2_prod_q  <= '0;
+    end else begin
+      if (valid_i && s1_ready) begin
+        s1_valid_q <= 1'b1;
+        s1_upper_q <= select_upper_d;
+        s1_id_q    <= id_i;
+        pp_ll_q    <= pp_ll_d;
+        pp_lh_q    <= pp_lh_d;
+        pp_hl_q    <= pp_hl_d;
+        pp_hh_q    <= pp_hh_d;
+      end else if (s1_valid_q && s2_ready) begin
+        s1_valid_q <= 1'b0;
+      end
+
+      if
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cc_onehot.sv`](environment/public/code/cc_onehot.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/assertions.svh`](environment/public/code/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/common_cells/registers.svh`](environment/public/code/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/dm_pkg.sv`](environment/public/code/dm_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/fall_through_register.sv`](environment/public/code/fall_through_register.sv) *(Read-Only Context)*
- [`environment/public/code/fifo_v3.sv`](environment/public/code/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/isochronous_4phase_handshake.sv`](environment/public/code/isochronous_4phase_handshake.sv) *(Read-Only Context)*
- [`environment/public/code/isochronous_spill_register.sv`](environment/public/code/isochronous_spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/onehot_to_bin.sv`](environment/public/code/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/reqrsp_interface/typedef.svh`](environment/public/code/reqrsp_interface/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/reqrsp_iso.sv`](environment/public/code/reqrsp_iso.sv) *(Read-Only Context)*
- [`environment/public/code/reqrsp_pkg.sv`](environment/public/code/reqrsp_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_instr.sv`](environment/public/code/riscv_instr.sv) *(Read-Only Context)*
- [`environment/public/code/rr_arb_tree.sv`](environment/public/code/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_clkdiv2.sv`](environment/public/code/snitch_clkdiv2.sv) **(Editable)**
- [`environment/public/code/snitch_iso_cluster_subsys.sv`](environment/public/code/snitch_iso_cluster_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_iso_hive.sv`](environment/public/code/snitch_iso_hive.sv) **(Editable)**
- [`environment/public/code/snitch_l0_tlb.sv`](environment/public/code/snitch_l0_tlb.sv) **(Editable)**
- [`environment/public/code/snitch_pkg.sv`](environment/public/code/snitch_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/snitch_ptw.sv`](environment/public/code/snitch_ptw.sv) **(Editable)**
- [`environment/public/code/snitch_shared_muldiv.sv`](environment/public/code/snitch_shared_muldiv.sv) **(Editable)**
- [`environment/public/code/snitch_vm/typedef.svh`](environment/public/code/snitch_vm/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter.sv`](environment/public/code/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/stream_arbiter_flushable.sv`](environment/public/code/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/stream_demux.sv`](environment/public/code/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/constraints/snitch_iso_hive.sdc`](environment/public/constraints/snitch_iso_hive.sdc) **(Editable)**
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

