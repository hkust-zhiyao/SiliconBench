# `case_6006`: VeeR-EH1 IFU Branch Predictor (BTB/BHT/RAS), I-Cache/ICCM Memory Controller, and Fetch Pipe Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_6006` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-eh1` (`repo_06`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `gatelevel_physical_effects`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/ifu_ifc_ctl.sv`](environment/public/code/ifu_ifc_ctl.sv), [`code/ifu_bp_ctl.sv`](environment/public/code/ifu_bp_ctl.sv), [`code/ifu_mem_ctl.sv`](environment/public/code/ifu_mem_ctl.sv) (3 files, 3607 LOC) |
| **Public Subsystem Context** | 7 RTL files (4864 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `960s` total (`480s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR-EH1 IFU Branch Predictor (BTB/BHT/RAS), I-Cache/ICCM Memory Controller, and Fetch Pipe Closure

In `code/veer_ifu_bp_mem_top.sv`, the fetch pipeline controller (`code/ifu_ifc_ctl.sv`), the branch target buffer, gshare branch history table, and 4-entry return address stack (`code/ifu_bp_ctl.sv`), and the I-Cache/ICCM memory and miss/error controller (`code/ifu_mem_ctl.sv`) are integrated together.

Update only `code/ifu_ifc_ctl.sv`, `code/ifu_bp_ctl.sv`, and `code/ifu_mem_ctl.sv` to satisfy all functional, synthesis, and static timing contracts:

1. **Fetch Pipe Control & MRAC/ICCM Address Protection (`code/ifu_ifc_ctl.sv`)**:
   - Determine F1 fetch cacheability from the cacheability bit (even bit) of the 2-bit MRAC region descriptor in `dec_tlu_mrac_ff` for the current 256 MB region (`ifc_fetch_addr_f1[31:28]`).
   - Classify F1 accesses in region `0xe` into valid ICCM accesses (`[0xee000000, 0xee07ffff]`) versus out-of-range ICCM region access faults, and coordinate F1/F2 fetch requests across flushes, BTB taken redirects, fetch-buffer occupancy, and critical-word bypass readiness.

2. **BTB, Gshare BHT & Return Address Stack (`code/ifu_bp_ctl.sv`)**:
   - Push the sequential link address (`PC + 4` for 32-bit calls or `PC + 2` for 16-bit calls) onto the 4-entry return address stack on taken F2 BTB call hits, and drive the top of the return address stack onto `ifu_bp_btb_target_f2` while popping the stack on taken F2 BTB return hits (that are not simultaneously marked as calls).
   - When a 4-byte branch straddles two fetch groups such that its upper halfword hits in halfword lane 0 of the current F2 fetch group, compute its branch target relative to the prior fetch group's upper address (offset `3'b111`).
   - Resolve BHT bank/index writes so each source writes its own 2-bit history counter and simultaneous writes to the same bank and index obey strict priority: WB slot-0 branch update (`dec_tlu_br0_wb_pkt`) highest, WB slot-1 branch update (`dec_tlu_br1_wb_pkt`) second, and EXU mispredict update (`exu_mp_pkt`) lowest.

3. **I-Cache Miss/Critical-Word Bypass & ICCM ECC Repair Control (`code/ifu_mem_ctl.sv`) & PPA/STA Closure**:
   - Issue and complete uncacheable I-Cache misses in 2 AXI read beats (versus 8 AXI read beats for cacheable line-fill misses); assemble the two 64-bit critical-word beats and assert `ic_crit_wd_rdy` as soon as the second critical half arrives so the miss state machine can complete and return to idle.
   - Propagate F2 region/bus access faults (`ic_access_fault_f2`). On single-bit ICCM ECC errors, wait for pipeline flush and transition into the single-bit ECC correction state when `exu_flush_final` is accompanied by `dec_tlu_flush_err_wb` (or immediately on DMA single-bit ECC errors), asserting both `ic_dma_active` and `iccm_wren` to scrub the corrected word back into ICCM, while returning to idle if `exu_flush_final` occurs without `dec_tlu_flush_err_wb`.
   - The RTL must synthesize without latches. Under the `BUILD.md` Yosys/Slang Nangate45 and OpenROAD STA flow (`3.65 ns` clock on `clk`, `0.15 ns` I/O delays, `5.0 fF` load), `veer_ifu_bp_mem_top` must achieve mapped cell area `<= 27,850.0 um^2`, worst setup slack (`WNS`) `>= 0.00 ns`, and worst hold slack (`WHS`) `>= 0.00 ns`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Guide (`veer_ifu_bp_mem_top`)

## 1. Editable Files
Only the following three files in `code/` are collected and graded:
- `code/ifu_ifc_ctl.sv`
- `code/ifu_bp_ctl.sv`
- `code/ifu_mem_ctl.sv`

All other files (`code/veer_ifu_bp_mem_top.sv`, `code/common_defines.vh`, `code/global.h`, `code/veer_types.sv`, `code/beh_lib.sv`, `code/LICENSE`, and `lib/*`) are read-only.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/ifu_ifc_ctl.sv code/ifu_bp_ctl.sv code/ifu_mem_ctl.sv \
  code/veer_ifu_bp_mem_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis & Static Timing Analysis (`Yosys/Slang` + `OpenROAD`)
```bash
yosys -m slang -p "
  read_slang --single-unit --top veer_ifu_bp_mem_top -Icode \
    code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
    code/ifu_ifc_ctl.sv code/ifu_bp_ctl.sv code/ifu_mem_ctl.sv code/veer_ifu_bp_mem_top.sv;
  hierarchy -check -top veer_ifu_bp_mem_top;
  proc;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  opt_clean;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top veer_ifu_bp_mem_top;
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

OpenROAD STA constraints (`3.65 ns` clock on `clk`):
```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design veer_ifu_bp_mem_top
create_clock -name clk -period 3.65 [get_ports clk]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports {rst_l scan_mode}]
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ifu_ifc_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/ifu_ifc_ctl.sv (Golden Reference)
@@ -270,15 +270,15 @@
                                  idle ) & ~exu_flush_final) |
                               dma_iccm_stall_any_f;
 
-   assign ifc_region_acc_fault_f1 = ~iccm_acc_in_range_f1 & ~iccm_acc_in_region_f1 ;
+   assign ifc_region_acc_fault_f1 = ~iccm_acc_in_range_f1 & iccm_acc_in_region_f1 ;
  `else
    assign ifc_iccm_access_f1 = 1'b0 ;
    assign ifc_dma_access_ok  = 1'b0 ;
    assign ifc_region_acc_fault_f1  = 1'b0 ;
  `endif
 
-   assign cacheable_select[4:0]    =  {ifc_fetch_addr_f1[31:28] , 1'b1 } ;
-   assign ifc_fetch_uncacheable_f1 =  ~dec_tlu_mrac_ff[cacheable_select]  ;
+   assign cacheable_select[4:0]    =  {ifc_fetch_addr_f1[31:28] , 1'b0 } ;
+   assign ifc_fetch_uncacheable_f1 =  ~dec_tlu_mrac_ff[cacheable_select]  ; // bit 0 of each region description is the cacheable bit
 
 endmodule // ifu_ifc_ctl
 

--- a/environment/public/code/ifu_bp_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/ifu_bp_ctl.sv (Golden Reference)
@@ -1112,7 +1112,9 @@
     endcase // casex (ifc_fetch_addr_f1[3:2])
 
     end
-    assign btb_fg_crossing_f2 = btb_sel_f2[7] & btb_rd_pc4_f2;
+   // compute target
+   // Form the fetch group offset based on the btb hit location and the location of the branch within the 4 byte chunk
+    assign btb_fg_crossing_f2 = btb_sel_f2[0] & btb_rd_pc4_f2;
 
    wire [2:0] btb_sel_f2_enc, btb_sel_f2_enc_shift;
    assign btb_sel_f2_enc[2:0] = encode8_3(btb_sel_f2[7:0]);
@@ -1135,7 +1137,8 @@
                          .offset(btb_rd_tgt_f2[11:0]),
                          .dout(bp_btb_target_adder_f2[31:1])
                          );
-   assign ifu_bp_btb_target_f2[31:1] = (btb_rd_ret_f2 & ~btb_rd_call_f2) ? rets_out[1][31:1] : bp_btb_target_adder_f2[31:1];
+   // mux in the return stack address here for a predicted return
+   assign ifu_bp_btb_target_f2[31:1] = btb_rd_ret_f2 & ~btb_rd_call_f2 ? rets_out[0][31:1] : bp_btb_target_adder_f2[31:1];
 
 
    // ----------------------------------------------------------------------
@@ -1408,9 +1411,10 @@
    assign bht_wr_en1[7:0] = {8{dec_tlu_br1_v_wb}} & decode3_8({dec_tlu_br1_bank_wb[1:0], dec_tlu_br1_middle_wb});
    assign bht_wr_en2[7:0] = {8{dec_tlu_br0_v_wb}} & decode3_8({dec_tlu_br0_bank_wb[1:0], dec_tlu_br0_middle_wb});
 
-   assign bht_wr_data0[1:0] = dec_tlu_br0_hist_wb[1:0];
+   // Experiments show this is the best priority scheme for same bank/index writes at the same time.
+   assign bht_wr_data0[1:0] = exu_mp_hist[1:0]; // lowest priority
    assign bht_wr_data1[1:0] = dec_tlu_br1_hist_wb[1:0];
-   assign bht_wr_data2[1:0] = exu_mp_hist[1:0];
+   assign bht_wr_data2[1:0] = dec_tlu_br0_hist_wb[1:0]; // highest priority
 
 
 

--- a/environment/public/code/ifu_mem_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/ifu_mem_ctl.sv (Golden Reference)
@@ -403,7 +403,7 @@
    perr_state_t perr_state, perr_nxtstate;
 
 
-   assign ic_dma_active =  (perr_state == DMA_SB_ERR) | (dec_tlu_flush_err_wb & (perr_state == ECC_WFF));
+   assign ic_dma_active =  iccm_correct_ecc | (perr_state == DMA_SB_ERR) | (dec_tlu_flush_err_wb & (perr_state == ECC_WFF));
    //////////////////////////////////// Create Miss State Machine ///////////////////////
    //                                   Create Miss State Machine                      //
    //                                   Create Miss State Machine                      //
@@ -776,7 +776,8 @@
   assign ifu_byp_data_err[7:0]  =  {{4{ ifu_byp_data_error_second_half}} , {4{ifu_byp_data_error_first_half}}} ;
 
 // Critical word ready.
-   assign    ic_crit_wd_complete = (write_byp_first_data  & write_byp_second_data);
+   assign    ic_crit_wd_complete = (write_byp_first_data  & ifu_byp_data_second_half_valid) |
+                                   (write_byp_second_data & ifu_byp_data_first_half_valid)  ;
 
    assign    ic_crit_wd_rdy_in = (ic_crit_wd_complete & crit_wd_byp_ok_ff & ~exu_flush_final ) |
                                  (ic_crit_wd_rdy_ff & ~fetch_req_icache_f2 & crit_wd_byp_ok_ff & ~exu_flush_final) ;
@@ -838,7 +839,7 @@
                   perr_sel_invalidate =  (dec_tlu_flush_err_wb &  exu_flush_final);
          end
          ECC_WFF: begin : ecc_wff
-                  perr_nxtstate       =  (dec_tlu_flush_err_wb &  exu_flush_final ) ? ERR_IDLE : ECC_CORR ;
+                  perr_nxtstate       =  (~dec_tlu_flush_err_wb &  exu_flush_final ) ? ERR_IDLE : ECC_CORR ;
                   perr_state_en       =   exu_flush_final   ;
          end
          DMA_SB_ERR : begin : dma_sb_ecc
@@ -1097,7 +1098,7 @@
 
 
 
-    assign axi_last_data_beat     =  (axi_data_beat_count[2:0] == 3'b111);
+    assign axi_last_data_beat     =  uncacheable_miss_ff ? (axi_data_beat_count[2:0] == 3'b001) : (axi_data_beat_count[2:0] == 3'b111);
     assign axi_wrap_addr          =  (axi_rd_addr_count[2:0] == 3'b111);
 
    assign  axi_ifu_wr_en_new         =  ifu_axi_rvalid_ff  & miss_pending ;

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/beh_lib.sv`](environment/public/code/beh_lib.sv) *(Read-Only Context)*
- [`environment/public/code/common_defines.vh`](environment/public/code/common_defines.vh) *(Read-Only Context)*
- [`environment/public/code/global.h`](environment/public/code/global.h) *(Read-Only Context)*
- [`environment/public/code/ifu_bp_ctl.sv`](environment/public/code/ifu_bp_ctl.sv) **(Editable)**
- [`environment/public/code/ifu_ifc_ctl.sv`](environment/public/code/ifu_ifc_ctl.sv) **(Editable)**
- [`environment/public/code/ifu_mem_ctl.sv`](environment/public/code/ifu_mem_ctl.sv) **(Editable)**
- [`environment/public/code/veer_ifu_bp_mem_top.sv`](environment/public/code/veer_ifu_bp_mem_top.sv) *(Read-Only Context)*
- [`environment/public/code/veer_types.sv`](environment/public/code/veer_types.sv) *(Read-Only Context)*
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

