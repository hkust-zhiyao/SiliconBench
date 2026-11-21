# `case_2003`: Ibex Load-Store Unit, Writeback Stage, and Smepmp Memory Protection Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_2003` |
| **Source Silicon Repository** | `lowRISC/ibex` (`repo_02`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `rtl_integration`, `rtl_semantics`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/ibex_load_store_unit.sv`](environment/public/code/ibex_load_store_unit.sv), [`code/ibex_wb_stage.sv`](environment/public/code/ibex_wb_stage.sv), [`code/ibex_pmp.sv`](environment/public/code/ibex_pmp.sv) (3 files, 1439 LOC) |
| **Public Subsystem Context** | 19 RTL files (6475 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Ibex Load-Store Unit, Writeback Stage, and Smepmp Memory Protection Closure

In the Ibex memory-access and writeback subsystem (`code/ibex_lsu_wb_pmp_top.sv`, integrating `code/ibex_load_store_unit.sv`, `code/ibex_wb_stage.sv`, and `code/ibex_pmp.sv`), several coupled functional failures and synthesis/timing bottlenecks currently prevent signoff:

1. **Smepmp (`mseccfg.mml` / `mseccfg.mmwp`), TOR Range Matching, and Debug-Mode Access Control (`code/ibex_pmp.sv`)**:
   - Under Smepmp (`csr_pmp_mseccfg_i.mml == 1'b1`), shared regions (`read == 0, write == 1`) with `{lock, exec} == 2'b00` erroneously permit writes in S/U privilege modes instead of restricting write access to M-mode (`PRIV_LVL_M`), non-shared locked regions fail to enforce the `lock` bit requirement in M-mode, and unmatched instruction fetches (`PMP_ACC_EXEC`) in M-mode fail to default-deny when `mml` is active.
   - Top-of-Range (`PMP_MODE_TOR`) region matching both mishandles inverted bounds (`csr_pmp_addr_i[r] < region_start_addr[r]`) and introduces excessive arithmetic carry chains on the address-to-LSU critical path. All PMP modes (`OFF`, `TOR`, `NA4`, `NAPOT`), static region priority (`0` highest), `mmwp` default-deny, and Debug-Module bypass (`debug_mode_i` within `[DmBaseAddr, DmBaseAddr | DmAddrMask]`) must operate accurately across both channels.

2. **Split Misaligned Fault-Address Reporting and CHERIoT 64-bit Capability Transfers (`code/ibex_load_store_unit.sv`)**:
   - When a misaligned word (`lsu_type_i == 2'b00`, non-zero byte offset) or word-straddling halfword (`lsu_type_i == 2'b01`, byte offset `2'b11`) splits across two word-aligned OBI beats, `addr_last_o` is overwritten with the second beat's aligned address even when the first beat faulted (`data_bus_err_i` or `data_pmp_err_i`). `addr_last_o` must retain the initial unaligned address whenever the first beat faults, and update to the second word-aligned address only when the first beat succeeds.
   - For CHERIoT 64-bit capability loads (`cheriot_enable_i == IbexMuBiOn` and `lsu_is_cap_i == 1'b1`), a bus error on the first beat or a 39-bit SECDED integrity error on the second beat fails to invalidate the returned capability (`lsu_rcap_o`). Any bus error, PMP fault, CHERIoT request error, or SECDED integrity fault across the capability transfer must suppress `lsu_rdata_valid_o` and drive `lsu_rcap_o = NULL_CAP`.

3. **Writeback Stage Completion, Retirement Accounting, and PPA/STA Closure (`code/ibex_wb_stage.sv`, `code/ibex_load_store_unit.sv`, `code/ibex_pmp.sv`)**:
   - In `code/ibex_wb_stage.sv` (`WritebackStage == 1`), CHERIoT capability loads and stores (`instr_is_cheriot_i` with `cheriot_load_i` or `cheriot_store_i`) complete prematurely in a single cycle without waiting for `lsu_resp_valid_o`, and `perf_instr_ret_wb_o` erroneously counts instructions that terminate with an LSU error (`load_err_o`, `store_err_o`, `load_resp_intg_err_o`, or `store_resp_intg_err_o`).
   - Remove redundant datapath and state overhead across `code/ibex_load_store_unit.sv`, `code/ibex_wb_stage.sv`, and `code/ibex_pmp.sv` so that `ibex_lsu_wb_pmp_top` synthesizes without latches under the supplied Nangate45 flow (`BUILD.md`) with mapped cell area `<= 5,750.0 um^2`, and achieves worst setup slack (`WNS`) `>= 0.00 ns` and worst hold slack (`WHS`) `>= 0.00 ns` at a `2.05 ns` clock period on `clk_i` (`0.15 ns` I/O delays, `5.0 fF` output load).

Edit only `code/ibex_load_store_unit.sv`, `code/ibex_wb_stage.sv`, and `code/ibex_pmp.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and STA Guide

## 1. Editable Files
Only the following three RTL files are collected and graded:
- `code/ibex_load_store_unit.sv`
- `code/ibex_wb_stage.sv`
- `code/ibex_pmp.sv`

All other files in `code/` and `lib/` (`code/ibex_lsu_wb_pmp_top.sv`, `code/ibex_pkg.sv`, `code/ibex_cheriot_pkg.sv`, `code/prim_*`, `code/dv_fcov_macros.svh`, `lib/*`) are read-only and must remain unmodified.

## 2. Behavioral Simulation (`Verilator`)
Compile and simulate `code/ibex_lsu_wb_pmp_top.sv` with Verilator:

```bash
verilator \
  --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module <your_tb> --Mdir obj \
  code/prim_util_pkg.sv code/prim_secded_pkg.sv \
  code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
  code/prim_buf.sv code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
  code/ibex_pmp.sv code/ibex_load_store_unit.sv code/ibex_wb_stage.sv \
  code/ibex_lsu_wb_pmp_top.sv <your_tb.sv>
./obj/V<your_tb>
```

## 3. Logic Synthesis & Area Evaluation (`Yosys + Slang`, `Nangate45`)
Synthesize `ibex_lsu_wb_pmp_top` to `lib/NangateOpenCellLibrary_typical.lib`:

```bash
yosys \
  -m slang -Q -T -p "
    read_slang --top ibex_lsu_wb_pmp_top -Icode -DSYNTHESIS \
      code/prim_util_pkg.sv code/prim_secded_pkg.sv \
      code/ibex_pkg.sv code/ibex_cheriot_pkg.sv \
      code/prim_buf.sv code/prim_secded_inv_39_32_dec.sv code/prim_secded_inv_39_32_enc.sv \
      code/ibex_pmp.sv code/ibex_load_store_unit.sv code/ibex_wb_stage.sv \
      code/ibex_lsu_wb_pmp_top.sv;
    hierarchy -check -top ibex_lsu_wb_pmp_top;
    proc; opt_clean;
    select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
    synth -top ibex_lsu_wb_pmp_top;
    opt;
    dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
    abc -liberty lib/NangateOpenCellLibrary_typical.lib;
    clean;
    read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
    check -assert;
    stat -liberty lib/NangateOpenCellLibrary_typical.lib;
    write_verilog -noattr mapped.v
  "
```
- **Latch Check**: Zero latches allowed.
- **Mapped Cell Area Target**: `Chip area for module '\ibex_lsu_wb_pmp_top'` must be `<= 5,750.0 um^2`.

## 4. Static Timing Analysis (`OpenROAD / OpenSTA`)
Evaluate setup and hold slack on `mapped.v` under a `2.05 ns` clock on `clk_i`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog mapped.v
link_design ibex_lsu_wb_pmp_top
create_clock -name clk_i -period 2.05 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
- **Timing Targets**: `WNS >= 0.00 ns` and `WHS >= 0.00 ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ibex_load_store_unit.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_load_store_unit.sv (Golden Reference)
@@ -516,8 +516,8 @@
           rdata_update = ~data_we_q;
           // If already granted, wait for second rvalid
           ls_fsm_ns = data_gnt_i ? IDLE : WAIT_GNT;
-          // Update the address for the second part
-          addr_update = data_gnt_i;
+          // Update the address for the second part, if no error
+          addr_update = data_gnt_i & ~(data_bus_err_i | pmp_err_q);
           // clear handle_misaligned if second request is granted
           handle_misaligned_d = ~data_gnt_i;
         end else begin
@@ -536,8 +536,8 @@
         data_req_o      = 1'b1;
         if (data_gnt_i || pmp_err_q) begin
           ctrl_update         = 1'b1;
-          // Update the address
-          addr_update         = 1'b1;
+          // Update the address, unless there was an error
+          addr_update         = ~lsu_err_q;
           ls_fsm_ns           = IDLE;
           handle_misaligned_d = 1'b0;
         end
@@ -686,7 +686,8 @@
 
   logic all_resp;
   assign data_or_pmp_err    = lsu_err_q | data_bus_err_i | pmp_err_q |
-                              ((cheriot_enable_i == IbexMuBiOn) & cheriot_err_q);
+                              ((cheriot_enable_i == IbexMuBiOn) &
+                               (cheriot_err_q | (resp_is_cap_q & cap_lsw_err_q)));
 
   assign all_resp           = data_rvalid_i | pmp_err_q |
                               ((cheriot_enable_i == IbexMuBiOn) & cheriot_err_q);
@@ -702,7 +703,7 @@
                          cap_lsw_data_q : data_rdata_ext;
     assign lsu_rcap_o  = ((cheriot_enable_i == IbexMuBiOn) && resp_is_cap_q &&
                           data_rvalid_i && (cap_rx_fsm_q == CRX_WAIT_RESP2) &&
-                          (~data_or_pmp_err)) ?
+                          (~data_or_pmp_err) && (~data_intg_err)) ?
                          cheriot_mem_to_cap({data_tag_i, data_rdata_i[31:0]},
                              {cap_lsw_tag_q, cap_lsw_data_q}, resp_lc_clrperm_q) :
                          NULL_CAP;
@@ -738,23 +739,8 @@
 
   assign data_tag_o = data_wdata_tag;
 
-
-  // Redundant shadow transaction history window
-  logic [63:0] shadow_txn_hist_q [6];
-  always_ff @(posedge clk_i or negedge rst_ni) begin
-    if (!rst_ni) begin
-      for (int k = 0; k < 6; k++) shadow_txn_hist_q[k] <= 64'h0;
-    end else if (data_req_o || data_rvalid_i) begin
-      shadow_txn_hist_q[0] <= {data_addr, lsu_wdata_i} ^ {32'h0, data_rdata_i[31:0]};
-      for (int k = 1; k < 6; k++) shadow_txn_hist_q[k] <= shadow_txn_hist_q[k-1] + 64'h1;
-    end
-  end
-  logic [31:0] shadow_fold;
-  assign shadow_fold = shadow_txn_hist_q[0][31:0] + shadow_txn_hist_q[1][63:32] +
-                       shadow_txn_hist_q[2][31:0] + shadow_txn_hist_q[3][63:32] +
-                       shadow_txn_hist_q[4][31:0] + shadow_txn_hist_q[5][63:32];
-  assign addr_last_o = (shadow_fold == 32'hDEAD_BEEF && &shadow_txn_hist_q[5]) ? (addr_last_q ^ 32'h0) : addr_last_q;
-
+  // output to ID stage: mtval + AGU for misaligned transactions
+  assign addr_last_o = addr_last_q;
 
   // Signal a load or store error depending on the transaction type outstanding
   assign load_err_o  = data_or_pmp_err & ~data_we_q & lsu_resp_valid_o;

--- a/environment/public/code/ibex_wb_stage.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_wb_stage.sv (Golden Reference)
@@ -112,7 +112,8 @@
 
     // note cheriot_load/store doesn't just come from the decoder, but includes
     // bound/permission check results
-    assign wb_done = (wb_instr_type_q == WB_INSTR_OTHER) | lsu_resp_valid_i;
+    assign wb_done = (wb_instr_type_q == WB_INSTR_OTHER && ~(wb_is_cheriot_q && (wb_cheriot_load_q |
+                      wb_cheriot_store_q))) | lsu_resp_valid_i;
 
     always_ff @(posedge clk_i or negedge rst_ni) begin
       if (!rst_ni) begin
@@ -206,7 +207,8 @@
     assign perf_instr_ret_wb_spec_o            = wb_count_q & wb_valid_q & ~dummy_instr_wb_o;
     assign perf_instr_ret_compressed_wb_spec_o = perf_instr_ret_wb_spec_o & wb_compressed_q;
     assign perf_instr_ret_wb_o                 = instr_done_wb_o & wb_count_q &
-                                                 ~dummy_instr_wb_o;
+                                                 ~dummy_instr_wb_o &
+                                                 ~(lsu_resp_valid_i & lsu_resp_err_i);
     assign perf_instr_ret_compressed_wb_o      = perf_instr_ret_wb_o & wb_compressed_q;
 
     // Forward data that will be written to the RF back to ID to resolve data hazards. The flopped
@@ -300,8 +302,8 @@
 
   // RF write data can come from ID results (all RF writes that aren't because of loads will come
   // from here) or the LSU (RF writes for load data)
-  assign rf_wdata_wb_o = rf_wdata_wb_mux_we[0] ? rf_wdata_wb_mux[0] :
-                         (rf_wdata_wb_mux_we[1] ? rf_wdata_wb_mux[1] : 32'h0);
+  assign rf_wdata_wb_o = ({32{rf_wdata_wb_mux_we[0]}} & rf_wdata_wb_mux[0]) |
+                         ({32{rf_wdata_wb_mux_we[1]}} & rf_wdata_wb_mux[1]);
   assign rf_we_wb_o    = |rf_wdata_wb_mux_we;
 
   assign rf_wcap_wb_o  = rf_wdata_wb_mux_we[0] ? rf_wcap_wb :

--- a/environment/public/code/ibex_pmp.sv (Buggy Starter)
+++ b/solution/gold/code/ibex_pmp.sv (Golden Reference)
@@ -69,7 +69,7 @@
         // Read/write in M, read only in S/U
         2'b00: result =
             (pmp_req_type == PMP_ACC_READ) |
-            (pmp_req_type == PMP_ACC_WRITE);
+            ((pmp_req_type == PMP_ACC_WRITE) & (priv_mode == PRIV_LVL_M));
         // Read/write in M/S/U
         2'b01: result =
             (pmp_req_type == PMP_ACC_READ) | (pmp_req_type == PMP_ACC_WRITE);
@@ -90,7 +90,7 @@
         // Otherwise use basic permission check. Permission is always denied if in S/U mode and
         // L is set or if in M mode and L is unset.
         result = permission_check &
-                 (priv_mode == PRIV_LVL_M ? 1'b1 : ~region_csr_pmp_cfg.lock);
+                 (priv_mode == PRIV_LVL_M ? region_csr_pmp_cfg.lock : ~region_csr_pmp_cfg.lock);
       end
     end
     return result;
@@ -135,7 +135,8 @@
 
     // When MSECCFG.MMWP is set default deny always, otherwise allow for M-mode, deny for other
     // modes. Also deny unmatched for M-mode whe MSECCFG.MML is set and request type is EXEC.
-    logic access_fail = csr_pmp_mseccfg_mmwp | (priv_mode != PRIV_LVL_M);
+    logic access_fail = csr_pmp_mseccfg_mmwp | (priv_mode != PRIV_LVL_M) |
+                        (csr_pmp_mseccfg_mml && (pmp_req_type == PMP_ACC_EXEC));
     logic matched = 1'b0;
 
     // PMP entries are statically prioritized, from 0 to N-1
@@ -205,10 +206,7 @@
           PMP_MODE_NAPOT: region_match_all[c][r] = region_match_eq[c][r];
           PMP_MODE_TOR: begin
             region_match_all[c][r] = (region_match_eq[c][r] | region_match_gt[c][r]) &
-                                     ((pmp_req_addr_i[c][PMP_ADDR_MSB:PMPGranularity+PMP_ADDR_LSB] -
-                                       region_start_addr[r][PMP_ADDR_MSB:PMPGranularity+PMP_ADDR_LSB]) <
-                                      (csr_pmp_addr_i[r][PMP_ADDR_MSB:PMPGranularity+PMP_ADDR_LSB] -
-                                       region_start_addr[r][PMP_ADDR_MSB:PMPGranularity+PMP_ADDR_LSB]));
+                                     region_match_lt[c][r];
           end
           default:        region_match_all[c][r] = 1'b0;
         endcase

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/dv_fcov_macros.svh`](environment/public/code/dv_fcov_macros.svh) *(Read-Only Context)*
- [`environment/public/code/ibex_cheriot_pkg.sv`](environment/public/code/ibex_cheriot_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_load_store_unit.sv`](environment/public/code/ibex_load_store_unit.sv) **(Editable)**
- [`environment/public/code/ibex_lsu_wb_pmp_top.sv`](environment/public/code/ibex_lsu_wb_pmp_top.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_pkg.sv`](environment/public/code/ibex_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ibex_pmp.sv`](environment/public/code/ibex_pmp.sv) **(Editable)**
- [`environment/public/code/ibex_wb_stage.sv`](environment/public/code/ibex_wb_stage.sv) **(Editable)**
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_buf.sv`](environment/public/code/prim_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inc.svh`](environment/public/code/prim_secded_inc.svh) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_dec.sv`](environment/public/code/prim_secded_inv_39_32_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_enc.sv`](environment/public/code/prim_secded_inv_39_32_enc.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_pkg.sv`](environment/public/code/prim_secded_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
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

