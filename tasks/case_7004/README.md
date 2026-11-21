# `case_7004`: VeeR EH2 Dual-Thread LSU DCCM, SECDED ECC, Atomic RMW, and Coalescing Store-Buffer Subsystem Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_7004` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-eh2` (`repo_07`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `gatelevel_physical_effects` (Gate-Level Implementation Effects, Scrambling/ECC & Cross-Stage Mismatch) |
| **Multi-Domain Tags** | `arithmetic_datapath`, `gatelevel_physical_effects`, `rtl_integration`, `rtl_semantics` |
| **Editable Files (`allowed_edits`)** | [`code/eh2_lsu_amo.sv`](environment/public/code/eh2_lsu_amo.sv), [`code/eh2_lsu_ecc.sv`](environment/public/code/eh2_lsu_ecc.sv), [`code/eh2_lsu_dccm_ctl.sv`](environment/public/code/eh2_lsu_dccm_ctl.sv), [`code/eh2_lsu_stbuf.sv`](environment/public/code/eh2_lsu_stbuf.sv) (4 files, 1333 LOC) |
| **Public Subsystem Context** | 11 RTL files (4188 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR EH2 Dual-Thread LSU DCCM, SECDED ECC, Atomic RMW, and Coalescing Store-Buffer Subsystem Closure

In the VeeR EH2 dual-thread Load/Store Unit subsystem (`code/eh2_lsu_subsys_top.sv`), regressions across `code/eh2_lsu_amo.sv`, `code/eh2_lsu_ecc.sv`, `code/eh2_lsu_dccm_ctl.sv`, and `code/eh2_lsu_stbuf.sv` cause data corruption and false ECC errors under concurrent pipeline traffic:

1. **Atomic RMW & Store-Conditional (`SC.W`) Datapath**: Signed `AMOMIN.W` and `AMOMAX.W` comparisons produce wrong results on same-sign operands, and `SC.W` transactions fail to route store data on success or preserve ECC-corrected memory data (without upper-channel store-buffer bypass interference) when the reservation check fails.
2. **Sub-Word ECC Merge, Scrubbing & Hazard Qualification**: Odd-offset sub-word stores misalign byte enables during ECC data merge; DC3/DC5 ECC error reporting and scrub writeback mishandle single-bank accesses, faulting accesses, store-buffer RAW forwarding, younger in-flight DMA stores targeting the same word, single-bank scrub port replication, and store-buffer drain bypass into DC2 stores.
3. **Coalescing Store Buffer & Load Forwarding Priority**: DC5 store coalescing and store-buffer draining mishandle draining/DMA-killed entries and unwritten background bytes during partial-word merges, while DC2 load byte forwarding violates youngest-first pipeline priority (`DC3 -> DC4 -> DC5 -> store buffer`).

Update only `code/eh2_lsu_amo.sv`, `code/eh2_lsu_ecc.sv`, `code/eh2_lsu_dccm_ctl.sv`, and `code/eh2_lsu_stbuf.sv`. The subsystem must synthesize without latches under the Yosys/Slang Nangate45 flow (`BUILD.md`) with mapped cell area `<= 17,050.0 um^2`, and meet OpenROAD static timing at a `3.15 ns` clock period on `clk` (`0.15 ns` I/O delays, `5.0 fF` output load) with worst setup slack (`WNS`) `>= 0.00 ns` and worst hold slack (`WHS`) `>= 0.00 ns`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/eh2_lsu_amo.sv`
- `code/eh2_lsu_ecc.sv`
- `code/eh2_lsu_dccm_ctl.sv`
- `code/eh2_lsu_stbuf.sv`

All other files in `code/` (`common_defines.vh`, `eh2_param.vh`, `eh2_pdef.vh`, `eh2_def.sv`, `beh_lib.sv`, `eh2_lib.sv`, `eh2_lsu_subsys_top.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `eh2_lsu_subsys_top` with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -Icode --top-module tb \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
  code/eh2_lsu_amo.sv code/eh2_lsu_ecc.sv code/eh2_lsu_dccm_ctl.sv code/eh2_lsu_stbuf.sv \
  code/eh2_lsu_subsys_top.sv /tmp/tb.sv
./obj_dir/Vtb
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `eh2_lsu_subsys_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top eh2_lsu_subsys_top -Icode \
    code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
    code/eh2_lsu_amo.sv code/eh2_lsu_ecc.sv code/eh2_lsu_dccm_ctl.sv code/eh2_lsu_stbuf.sv \
    code/eh2_lsu_subsys_top.sv;
  hierarchy -check -top eh2_lsu_subsys_top;
  proc; opt_clean;
  chformal -remove;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top eh2_lsu_subsys_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr /tmp/mapped.v
"
```

Target mapped cell area (`Chip area for module '\eh2_lsu_subsys_top'`): **`<= 17050.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `3.15 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_l` and `scan_mode`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design eh2_lsu_subsys_top
create_clock -name clk -period 3.15 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports {rst_l scan_mode}]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```

Target worst setup slack (`WNS`) and worst hold slack (`WHS`): **`>= 0.00 ns`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/eh2_lsu_amo.sv (Buggy Starter)
+++ b/solution/gold/code/eh2_lsu_amo.sv (Golden Reference)
@@ -129,7 +129,7 @@
 
    // Min/Max/Minu/Maxu
    if (pt.XLEN == 32) begin
-      assign lsu_result_lt_storedata = (~cout & lsu_pkt_dc3.unsign) |
+      assign lsu_result_lt_storedata = (~cout & (lsu_pkt_dc3.unsign | ~(amo_operand1[31] ^amo_operand2[31]))) |    // either doing unsigned math or signed with same polarity
                                        (amo_operand1[31] & ~amo_operand2[31] & ~lsu_pkt_dc3.unsign);
 
       assign amo_minmax_dc3[31:0] = ({32{(amo_max_dc3 | amo_maxu_dc3) &  lsu_result_lt_storedata}}  & amo_operand2[31:0]) |  // MAX if store_data >  result
@@ -154,6 +154,6 @@
    assign amo_data_dc3[pt.XLEN-1:0] = ({pt.XLEN{logic_sel}}                 & logical_out[pt.XLEN-1:0])    |  // for the AND/OR/XOR
                                       ({pt.XLEN{amo_add_dc3}}               & sum_out[pt.XLEN-1:0])        |  // for ADD
                                       ({pt.XLEN{amo_minmax_sel_dc3}}        & amo_minmax_dc3[pt.XLEN-1:0]) |  // for Min/Max/Minu/Maxu
-                                      ({pt.XLEN{amo_swap_dc3}}              & amo_operand2[pt.XLEN-1:0]);     // for SWAP need to store the store data value to the location
+                                      ({pt.XLEN{amo_swap_dc3 | amo_sc_dc3}} & amo_operand2[pt.XLEN-1:0]);     // for SWAP need to store the store data value to the location
 
 endmodule // lsu_amo

--- a/environment/public/code/eh2_lsu_ecc.sv (Buggy Starter)
+++ b/solution/gold/code/eh2_lsu_ecc.sv (Golden Reference)
@@ -118,7 +118,7 @@
                                                         ({pt.DCCM_BYTE_WIDTH*2{lsu_pkt_dc3.qword}} & {pt.DCCM_BYTE_WIDTH*2{1'b1}} & (pt.XLEN == 64));
    assign store_byteen_dc3[(pt.DCCM_BYTE_WIDTH*2)-1:0] = ldst_byteen_dc3[(pt.DCCM_BYTE_WIDTH*2)-1:0] & {pt.DCCM_BYTE_WIDTH*2{~lsu_pkt_dc3.load}};
 
-   assign store_byteen_ext_dc3[(pt.DCCM_BYTE_WIDTH*2)-1:0] = store_byteen_dc3[(pt.DCCM_BYTE_WIDTH*2)-1:0] << {lsu_addr_dc3[pt.DCCM_ADDR_OFF-1], 1'b0};
+   assign store_byteen_ext_dc3[(pt.DCCM_BYTE_WIDTH*2)-1:0] = store_byteen_dc3[(pt.DCCM_BYTE_WIDTH*2)-1:0] << lsu_addr_dc3[pt.DCCM_ADDR_OFF-1:0];
    assign store_byteen_hi_dc3[pt.DCCM_BYTE_WIDTH-1:0] = store_byteen_ext_dc3[(pt.DCCM_BYTE_WIDTH*2)-1:pt.DCCM_BYTE_WIDTH];
    assign store_byteen_lo_dc3[pt.DCCM_BYTE_WIDTH-1:0] = store_byteen_ext_dc3[pt.DCCM_BYTE_WIDTH-1:0];
 
@@ -135,9 +135,9 @@
    end
 
    assign dccm_wr_data_lo[pt.DCCM_DATA_WIDTH-1:0] = dma_dccm_spec_wen ? dma_dccm_wdata_lo[pt.DCCM_DATA_WIDTH-1:0] :
-                                                    (ld_single_ecc_error_lo_dc5_ff ? sec_data_lo_dc5_ff[pt.DCCM_DATA_WIDTH-1:0] : stbuf_data_any[pt.DCCM_DATA_WIDTH-1:0]);
+                                                    (ld_single_ecc_error_dc5_ff ? (ld_single_ecc_error_lo_dc5_ff ? sec_data_lo_dc5_ff[pt.DCCM_DATA_WIDTH-1:0] : sec_data_hi_dc5_ff[pt.DCCM_DATA_WIDTH-1:0]) : stbuf_data_any[pt.DCCM_DATA_WIDTH-1:0]);
    assign dccm_wr_data_hi[pt.DCCM_DATA_WIDTH-1:0] = dma_dccm_spec_wen ? dma_dccm_wdata_hi[pt.DCCM_DATA_WIDTH-1:0] :
-                                                    (ld_single_ecc_error_hi_dc5_ff ? sec_data_hi_dc5_ff[pt.DCCM_DATA_WIDTH-1:0] : stbuf_data_any[pt.DCCM_DATA_WIDTH-1:0]);
+                                                    (ld_single_ecc_error_dc5_ff ? (ld_single_ecc_error_hi_dc5_ff ? sec_data_hi_dc5_ff[pt.DCCM_DATA_WIDTH-1:0] : sec_data_lo_dc5_ff[pt.DCCM_DATA_WIDTH-1:0]) : stbuf_data_any[pt.DCCM_DATA_WIDTH-1:0]);
 
    assign dccm_wr_data_lo[pt.DCCM_FDATA_WIDTH-1:pt.DCCM_DATA_WIDTH] = dccm_wdata_ecc_lo_any[pt.DCCM_ECC_WIDTH-1:0];
    assign dccm_wr_data_hi[pt.DCCM_FDATA_WIDTH-1:pt.DCCM_DATA_WIDTH] = dccm_wdata_ecc_hi_any[pt.DCCM_ECC_WIDTH-1:0];
@@ -231,10 +231,10 @@
          );
       end
 
-      assign single_ecc_error_hi_dc3  = single_ecc_error_hi_raw_dc3;
-      assign single_ecc_error_lo_dc3  = single_ecc_error_lo_raw_dc3;
+      assign single_ecc_error_hi_dc3  = single_ecc_error_hi_raw_dc3 & ldst_dual_dc3 & ~(misaligned_fault_dc3 | access_fault_dc3);
+      assign single_ecc_error_lo_dc3  = single_ecc_error_lo_raw_dc3 & ~(misaligned_fault_dc3 | access_fault_dc3);
       assign lsu_single_ecc_error_dc3 = single_ecc_error_hi_dc3 | single_ecc_error_lo_dc3;
-      assign lsu_double_ecc_error_dc3 = double_ecc_error_hi_dc3 | double_ecc_error_lo_dc3;
+      assign lsu_double_ecc_error_dc3 = (double_ecc_error_hi_dc3 & ldst_dual_dc3) | double_ecc_error_lo_dc3;
 
       rvdffe #(.WIDTH(pt.DCCM_DATA_WIDTH)) sec_data_hi_dc5plus1ff (.din(sec_data_hi_dc5[pt.DCCM_DATA_WIDTH-1:0]), .dout(sec_data_hi_dc5_ff[pt.DCCM_DATA_WIDTH-1:0]), .en(ld_single_ecc_error_dc5 | clk_override), .clk(clk), .*);
       rvdffe #(.WIDTH(pt.DCCM_DATA_WIDTH)) sec_data_lo_dc5plus1ff (.din(sec_data_lo_dc5[pt.DCCM_DATA_WIDTH-1:0]), .dout(sec_data_lo_dc5_ff[pt.DCCM_DATA_WIDTH-1:0]), .en(ld_single_ecc_error_dc5 | clk_override), .clk(clk), .*);

--- a/environment/public/code/eh2_lsu_dccm_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/eh2_lsu_dccm_ctl.sv (Golden Reference)
@@ -215,11 +215,18 @@
       assign lsu_rdata_corr_dc3[8*i+:8] = stbuf_fwdbyteen_dc3[i] ? stbuf_fwddata_dc3[8*i+:8] : dccm_corr_dout_dc3[8*i+:8];
    end
 
-   assign kill_ecc_corr_lo_dc5 = (lsu_addr_dc1[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2]) & lsu_pkt_dc1.valid & lsu_pkt_dc1.store & lsu_pkt_dc1.dma & addr_in_dccm_dc1;
-   assign kill_ecc_corr_hi_dc5 = (end_addr_dc1[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2]) & lsu_pkt_dc1.valid & lsu_pkt_dc1.store & lsu_pkt_dc1.dma & addr_in_dccm_dc1;
-
-   assign ld_single_ecc_error_lo_dc5 = (lsu_commit_dc5 | lsu_pkt_dc5.dma) & (lsu_pkt_dc5.load | lsu_pkt_dc5.lr) & single_ecc_error_lo_dc5;
-   assign ld_single_ecc_error_hi_dc5 = (lsu_commit_dc5 | lsu_pkt_dc5.dma) & (lsu_pkt_dc5.load | lsu_pkt_dc5.lr) & single_ecc_error_hi_dc5;
+   assign kill_ecc_corr_lo_dc5 = (((lsu_addr_dc1[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc1[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc1.valid & lsu_pkt_dc1.store & lsu_pkt_dc1.dma & addr_in_dccm_dc1) |
+                                 (((lsu_addr_dc2[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc2[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc2.valid & lsu_pkt_dc2.store & lsu_pkt_dc2.dma & addr_in_dccm_dc2) |
+                                 (((lsu_addr_dc3[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc3[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc3.valid & lsu_pkt_dc3.store & lsu_pkt_dc3.dma & addr_in_dccm_dc3) |
+                                 (((lsu_addr_dc4[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc4[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc4.valid & lsu_pkt_dc4.store & lsu_pkt_dc4.dma & addr_in_dccm_dc4);
+
+   assign kill_ecc_corr_hi_dc5 = (((lsu_addr_dc1[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc1[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc1.valid & lsu_pkt_dc1.store & lsu_pkt_dc1.dma & addr_in_dccm_dc1) |
+                                 (((lsu_addr_dc2[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc2[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc2.valid & lsu_pkt_dc2.store & lsu_pkt_dc2.dma & addr_in_dccm_dc2) |
+                                 (((lsu_addr_dc3[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc3[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc3.valid & lsu_pkt_dc3.store & lsu_pkt_dc3.dma & addr_in_dccm_dc3) |
+                                 (((lsu_addr_dc4[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2]) | (end_addr_dc4[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2])) & lsu_pkt_dc4.valid & lsu_pkt_dc4.store & lsu_pkt_dc4.dma & addr_in_dccm_dc4);
+
+   assign ld_single_ecc_error_lo_dc5 = (lsu_commit_dc5 | lsu_pkt_dc5.dma) & (lsu_pkt_dc5.load | lsu_pkt_dc5.lr) & single_ecc_error_lo_dc5 & ~lsu_raw_fwd_lo_dc5;
+   assign ld_single_ecc_error_hi_dc5 = (lsu_commit_dc5 | lsu_pkt_dc5.dma) & (lsu_pkt_dc5.load | lsu_pkt_dc5.lr) & single_ecc_error_hi_dc5 & ~lsu_raw_fwd_hi_dc5;
    assign ld_single_ecc_error_dc3    = (lsu_pkt_dc3.load | lsu_pkt_dc3.lr) & (single_ecc_error_lo_dc3 | single_ecc_error_hi_dc3);  // This is for blocking fast interrupt at decode-1
    assign ld_single_ecc_error_dc4    = (lsu_pkt_dc4.load | lsu_pkt_dc4.lr) & (single_ecc_error_lo_dc4 | single_ecc_error_hi_dc4);  // This is for blocking load/store/dma at decode
    assign ld_single_ecc_error_dc5    = (ld_single_ecc_error_lo_dc5 | ld_single_ecc_error_hi_dc5) & ~lsu_double_ecc_error_dc5;    // This doesn't have kill_ecc due to spyglass
@@ -291,17 +298,17 @@
    assign dccm_wr_bypass_c1_c2_hi   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == end_addr_dc2[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc2 & ~lsu_pkt_dc2.sc;   // SC always aligned and upper XLEN bits are used for ECC corrected data
 
    assign dccm_wr_bypass_c1_c3_lo   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == lsu_addr_dc3[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc3;
-   assign dccm_wr_bypass_c1_c3_hi   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == end_addr_dc3[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc3;   // SC always aligned and upper XLEN bits are used for ECC corrected data
+   assign dccm_wr_bypass_c1_c3_hi   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == end_addr_dc3[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc3 & ~lsu_pkt_dc3.sc;   // SC always aligned and upper XLEN bits are used for ECC corrected data
 
    assign dccm_wr_bypass_c1_c4_lo   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == lsu_addr_dc4[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc4;
-   assign dccm_wr_bypass_c1_c4_hi   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == end_addr_dc4[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc4;   // SC always aligned and upper XLEN bits are used for ECC corrected data
+   assign dccm_wr_bypass_c1_c4_hi   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == end_addr_dc4[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc4 & ~lsu_pkt_dc4.sc;   // SC always aligned and upper XLEN bits are used for ECC corrected data
 
    assign dccm_wr_bypass_c1_c5_lo   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == lsu_addr_dc5[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc5;
-   assign dccm_wr_bypass_c1_c5_hi   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc5;   // SC always aligned and upper XLEN bits are used for ECC corrected data
+   assign dccm_wr_bypass_c1_c5_hi   = (stbuf_addr_any[pt.DCCM_BITS-1:2] == end_addr_dc5[pt.DCCM_BITS-1:2]) & addr_in_dccm_dc5 & ~lsu_pkt_dc5.sc;   // SC always aligned and upper XLEN bits are used for ECC corrected data
 
    // For SC conditional, hi data is used for ecc corrected data since in case of sc fail we just need to write corrected data.
    assign store_data_lo_dc3[pt.XLEN-1:0]= (lsu_pkt_dc3.atomic & ~lsu_pkt_dc3.lr & ~lsu_pkt_dc3.sc) ? amo_data_dc3[pt.XLEN-1:0] : store_ecc_data_lo_dc3[pt.XLEN-1:0];
-   assign store_data_hi_dc3[pt.XLEN-1:0]= (lsu_pkt_dc3.atomic & ~lsu_pkt_dc3.lr & ~lsu_pkt_dc3.sc) ? amo_data_dc3[pt.XLEN-1:0] : store_ecc_data_hi_dc3[pt.XLEN-1:0];
+   assign store_data_hi_dc3[pt.XLEN-1:0]= (lsu_pkt_dc3.atomic & ~lsu_pkt_dc3.lr & ~lsu_pkt_dc3.sc) ? amo_data_dc3[pt.XLEN-1:0] : (lsu_pkt_dc3.atomic & lsu_pkt_dc3.sc) ? sec_data_lo_dc3[pt.XLEN-1:0] : store_ecc_data_hi_dc3[pt.XLEN-1:0];
 
    // Timing fix for EH2_plus1. DCCM read data comes out in 2 cycles
    if (pt.LOAD_TO_USE_PLUS1 == 1) begin: GenL2U_1
@@ -358,13 +365,14 @@
       assign dccm_data_hi_dc5_in[8*i+:8]  = (lsu_stbuf_commit_any &  dccm_wr_bypass_c1_c4_hi & ~ldst_byteen_ext_dc4[i+4]) ? stbuf_data_any[8*i+:8] : store_data_hi_dc4[8*i+:8];
 
       // This is store buffer write data
-      assign dccm_datafn_lo_dc5[8*i+:8]   = (lsu_stbuf_commit_any &  dccm_wr_bypass_c1_c5_lo & ~ldst_byteen_ext_dc5[i]) ? stbuf_data_any[8*i+:8] : store_data_lo_dc5[8*i+:8];
+      assign dccm_datafn_lo_dc5[8*i+:8]   = (lsu_stbuf_commit_any &  dccm_wr_bypass_c1_c5_lo & ~ldst_byteen_ext_dc5[i]) ? stbuf_data_any[8*i+:8] :
+                                                                                 (lsu_pkt_dc5.atomic & lsu_pkt_dc5.sc & ~lsu_sc_success_dc5) ? store_data_hi_dc5[8*i+:8] : store_data_lo_dc5[8*i+:8];
       assign dccm_datafn_hi_dc5[8*i+:8]   = (lsu_stbuf_commit_any &  dccm_wr_bypass_c1_c5_hi & ~ldst_byteen_ext_dc5[i+4]) ? stbuf_data_any[8*i+:8] : store_data_hi_dc5[8*i+:8];
    end // for (genvar i=0; i<BYTE_WIDTH; i++)
 
    // Need to disable ecc correction since data is being forwarded for store (ECC is from RAM but data from forwarding path so they are out of sync).
-   assign disable_ecc_check_lo_dc2 = 1'b0;
-   assign disable_ecc_check_hi_dc2 = 1'b0;
+   assign disable_ecc_check_lo_dc2 = lsu_stbuf_commit_any & lsu_pkt_dc2.store & dccm_wr_bypass_c1_c2_lo;
+   assign disable_ecc_check_hi_dc2 = lsu_stbuf_commit_any & lsu_pkt_dc2.store & dccm_wr_bypass_c1_c2_hi;
 
    // PIC signals. PIC ignores the lower 2 bits of address since PIC memory registers are XLEN-bits
    assign picm_wren_notdma   = (lsu_pkt_dc5.valid & lsu_pkt_dc5.store & addr_in_pic_dc5 & lsu_commit_dc5);

--- a/environment/public/code/eh2_lsu_stbuf.sv (Buggy Starter)
+++ b/solution/gold/code/eh2_lsu_stbuf.sv (Golden Reference)
@@ -216,8 +216,8 @@
 
   // Store Buffer coalescing
    for (genvar i=0; i<DEPTH; i++) begin: FindMatchEntry
-       assign store_matchvec_lo_dc5[i] = (stbuf_addr[i][pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)] == lsu_addr_dc5[pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)]) & stbuf_vld[i] & lsu_commit_dc5;
-       assign store_matchvec_hi_dc5[i] = (stbuf_addr[i][pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)] == end_addr_dc5[pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)]) & stbuf_vld[i] & lsu_commit_dc5 & ldst_dual_dc5;
+       assign store_matchvec_lo_dc5[i] = (stbuf_addr[i][pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)] == lsu_addr_dc5[pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)]) & stbuf_vld[i] & ~stbuf_dma_kill[i] & lsu_commit_dc5 & ~stbuf_reset[i];
+       assign store_matchvec_hi_dc5[i] = (stbuf_addr[i][pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)] == end_addr_dc5[pt.LSU_SB_BITS-1:$clog2(pt.DCCM_BYTE_WIDTH)]) & stbuf_vld[i] & ~stbuf_dma_kill[i] & lsu_commit_dc5 & ldst_dual_dc5 & ~stbuf_reset[i];
    end: FindMatchEntry
 
    assign store_coalesce_lo_dc5 = |store_matchvec_lo_dc5[DEPTH-1:0];
@@ -244,8 +244,8 @@
       assign stbuf_byteenin[i][pt.DCCM_BYTE_WIDTH-1:0] = sel_lo[i] ? (stbuf_byteen[i][pt.DCCM_BYTE_WIDTH-1:0] | store_byteen_lo_dc5[pt.DCCM_BYTE_WIDTH-1:0])          : (stbuf_byteen[i][pt.DCCM_BYTE_WIDTH-1:0] | store_byteen_hi_dc5[pt.DCCM_BYTE_WIDTH-1:0]);
 
       for (genvar j=0; j<pt.DCCM_BYTE_WIDTH; j++) begin
-         assign stbuf_datain[i][8*j+:8] = sel_lo[i] ? (store_byteen_lo_dc5[j] ? store_ecc_datafn_lo_dc5[8*j+:8] : stbuf_data[i][8*j+:8]) :
-                                                      (store_byteen_hi_dc5[j] ? store_ecc_datafn_hi_dc5[8*j+:8] : stbuf_data[i][8*j+:8]);
+         assign stbuf_datain[i][8*j+:8] = sel_lo[i] ? ((~stbuf_byteen[i][j] | store_byteen_lo_dc5[j]) ? store_ecc_datafn_lo_dc5[8*j+:8] : stbuf_data[i][8*j+:8]) :
+                                                      ((~stbuf_byteen[i][j] | store_byteen_hi_dc5[j]) ? store_ecc_datafn_hi_dc5[8*j+:8] : stbuf_data[i][8*j+:8]);
       end
 
       rvdffsc #(.WIDTH(1))              stbuf_vldff    (.din(1'b1),                                .dout(stbuf_vld[i]),                      .en(stbuf_wr_en[i]),       .clear(stbuf_reset[i]), .clk(lsu_free_c2_clk),  .*);
@@ -257,7 +257,7 @@
    end
    // Store Buffer drain logic
    assign stbuf_reqvld_flushed_any            = stbuf_vld[RdPtr] & stbuf_dma_kill[RdPtr];
-   assign stbuf_reqvld_any                    = stbuf_vld[RdPtr] & ~stbuf_dma_kill[RdPtr];
+   assign stbuf_reqvld_any                    = stbuf_vld[RdPtr] & ~stbuf_dma_kill[RdPtr] & ~(|stbuf_dma_kill_en[DEPTH-1:0]);  // Don't drain if some kill bit is being set this cycle
    assign stbuf_addr_any[pt.LSU_SB_BITS-1:0]  = stbuf_addr[RdPtr][pt.LSU_SB_BITS-1:0];
    assign stbuf_data_any[pt.DCCM_DATA_WIDTH-1:0]      = stbuf_data[RdPtr][pt.DCCM_DATA_WIDTH-1:0];
 
@@ -450,15 +450,15 @@
       assign stbuf_fwdbyteen_hi_fn_dc2[i] = ld_byte_hit_hi[i] | stbuf_fwdbyteen_hi_dc2[i];
       assign stbuf_fwdbyteen_lo_fn_dc2[i] = ld_byte_hit_lo[i] | stbuf_fwdbyteen_lo_dc2[i];
       // Pipe vs Store Queue priority
-      assign stbuf_fwddata_lo_fn_dc2[8*i+:8] = stbuf_fwdbyteen_lo_dc2[i] ? stbuf_fwddata_lo_dc2[8*i+:8] :
-                                               ld_byte_dc5hit_lo[i]      ? ld_fwddata_dc5pipe_lo[8*i+:8] :
-                                               ld_byte_dc4hit_lo[i]      ? ld_fwddata_dc4pipe_lo[8*i+:8] :
-                                               ld_fwddata_dc3pipe_lo[8*i+:8];
+      assign stbuf_fwddata_lo_fn_dc2[8*i+:8] = ld_byte_dc3hit_lo[i]    ? ld_fwddata_dc3pipe_lo[8*i+:8] :
+                                               ld_byte_dc4hit_lo[i]    ? ld_fwddata_dc4pipe_lo[8*i+:8] :
+                                               ld_byte_dc5hit_lo[i]    ? ld_fwddata_dc5pipe_lo[8*i+:8] :
+                                               stbuf_fwddata_lo_dc2[8*i+:8];
       // Pipe vs Store Queue priority
-      assign stbuf_fwddata_hi_fn_dc2[8*i+:8] = stbuf_fwdbyteen_hi_dc2[i] ? stbuf_fwddata_hi_dc2[8*i+:8] :
-                                               ld_byte_dc5hit_hi[i]      ? ld_fwddata_dc5pipe_hi[8*i+:8] :
-                                               ld_byte_dc4hit_hi[i]      ? ld_fwddata_dc4pipe_hi[8*i+:8] :
-                                               ld_fwddata_dc3pipe_hi[8*i+:8];
+      assign stbuf_fwddata_hi_fn_dc2[8*i+:8] = ld_byte_dc3hit_hi[i]    ? ld_fwddata_dc3pipe_hi[8*i+:8] :
+                                               ld_byte_dc4hit_hi[i]    ? ld_fwddata_dc4pipe_hi[8*i+:8] :
+                                               ld_byte_dc5hit_hi[i]    ? ld_fwddata_dc5pipe_hi[8*i+:8] :
+                                               stbuf_fwddata_hi_dc2[8*i+:8];
    end
 
    // PIC forwarding from dc3/dc4/dc5 -> dc2

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/LICENSE`](environment/public/LICENSE) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/beh_lib.sv`](environment/public/code/beh_lib.sv) *(Read-Only Context)*
- [`environment/public/code/common_defines.vh`](environment/public/code/common_defines.vh) *(Read-Only Context)*
- [`environment/public/code/eh2_def.sv`](environment/public/code/eh2_def.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_lib.sv`](environment/public/code/eh2_lib.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_lsu_amo.sv`](environment/public/code/eh2_lsu_amo.sv) **(Editable)**
- [`environment/public/code/eh2_lsu_dccm_ctl.sv`](environment/public/code/eh2_lsu_dccm_ctl.sv) **(Editable)**
- [`environment/public/code/eh2_lsu_ecc.sv`](environment/public/code/eh2_lsu_ecc.sv) **(Editable)**
- [`environment/public/code/eh2_lsu_stbuf.sv`](environment/public/code/eh2_lsu_stbuf.sv) **(Editable)**
- [`environment/public/code/eh2_lsu_subsys_top.sv`](environment/public/code/eh2_lsu_subsys_top.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_param.vh`](environment/public/code/eh2_param.vh) *(Read-Only Context)*
- [`environment/public/code/eh2_pdef.vh`](environment/public/code/eh2_pdef.vh) *(Read-Only Context)*
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

