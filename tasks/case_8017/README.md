# `case_8017`: VeeR EL2 LSU Load/Store Control, Memory-Map Address/Exception Checker, Hardware Trigger Unit, and Transparent Sideband Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_8017` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-el2` (`repo_08`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `verification_debug` (Corner-Case Verification Blind Spots, Security Alerts, Lockstep & Triggers) |
| **Multi-Domain Tags** | `rtl_integration`, `sdc_sta`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/el2_lsu_lsc_ctl.sv`](environment/public/code/el2_lsu_lsc_ctl.sv), [`code/el2_lsu_addrcheck.sv`](environment/public/code/el2_lsu_addrcheck.sv), [`code/el2_lsu_trigger.sv`](environment/public/code/el2_lsu_trigger.sv), [`constraints.json`](environment/public/constraints.json) (4 files, 659 LOC) |
| **Public Subsystem Context** | 10 RTL files (2751 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library (Shared Base Image)** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Uses unified Nangate45 typical Liberty and LEF from base image. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR EL2 LSU Load/Store Control, Memory-Map Address/Exception Checker, Hardware Trigger Unit, and Transparent Sideband Timing Budgets

In `code/el2_lsu_lsc_ctl.sv`, `code/el2_lsu_addrcheck.sv`, `code/el2_lsu_trigger.sv`, and `constraints.json` (integrated in `code/top.sv`), LSU D/M/R pipeline control, memory-map region/exception priority checking, 4-channel hardware trigger matching, and transparent sideband channel timing budgets currently fail verification:

1. **Memory-Map Region Classification, Fault Priority, and Fast-Interrupt Error Checks (`code/el2_lsu_addrcheck.sv`)**:
   - **Region & Side-Effect Classification**: Classify `addr_in_dccm_d` (`start_addr_in_dccm_d & end_addr_in_dccm_d`), `addr_in_pic_d` (`start_addr_in_pic_d & end_addr_in_pic_d`), `addr_external_d` (`~(start_addr_in_dccm_region_d | start_addr_in_pic_region_d)`), and `is_sideeffects_d` (`dec_tlu_mrac_ff[{start_addr_d[31:28], 1'b1}] & ~(start_addr_in_dccm_region_d | start_addr_in_pic_region_d | addr_in_iccm) & lsu_pkt_d.valid & (lsu_pkt_d.store | lsu_pkt_d.load)`), registering `is_sideeffects_d` into `is_sideeffects_m`.
   - **Access Fault vs Misaligned Fault Priority & `exc_mscause_d[3:0]`**: Suppress `access_fault_d` and `misaligned_fault_d` on DMA accesses (`~lsu_pkt_d.dma`). Prioritize `access_fault_mscause_d` in order: `unmapped_access_fault_d` (`4'h2`, including start/end in region `0xf` outside valid DCCM/PIC ranges or crossing between DCCM and PIC), `mpu_access_fault_d` (`4'h3`, `lsu_pmp_error_start | lsu_pmp_error_end`), `regpred_access_fault_d` (`4'h5`, `start_addr_dccm_or_pic ^ base_reg_dccm_or_pic`), and `picm_access_fault_d` (`4'h6`, non-word-aligned or non-word-sized PIC access). Prioritize `misaligned_fault_mscause_d` as `regcross_misaligned_fault_d` (`4'h2`, `start_addr_d[31:28] != end_addr_d[31:28]`) over `sideeffect_misaligned_fault_d` (`4'h1`, `is_sideeffects_d & ~is_aligned_d` on external addresses), and drive `exc_mscause_d = misaligned_fault_d ? misaligned_fault_mscause_d : access_fault_mscause_d`.
   - **Fast-Interrupt Lookup Errors**: Assert `fir_dccm_access_error_d` when a valid `fast_int` packet has start or end address in DCCM region `0xf` outside valid DCCM bounds, and `fir_nondccm_access_error_d` when start or end address is outside DCCM region `0xf`.

2. **LSU D/M/R Pipeline Control, Bypass Forwarding, and Exception/FIR Packet Generation (`code/el2_lsu_lsc_ctl.sv`)**:
   - **Address/Data Bypass & Power-Saving End-Address Gating**: Select `rs1_d = lsu_pkt_d.load_ldst_bypass_d ? lsu_result_m : rs1_d_raw`, compute `end_addr_d` (`half: +1`, `word: +3`, `dword: +7`), gate high-order `end_addr_pre_m[31:3]` / `end_addr_pre_r[31:3]` with `ldst_dual_d` / `ldst_dual_m` (`end_addr_m[31:3] = ldst_dual_m ? end_addr_pre_m[31:3] : lsu_addr_m[31:3]`), shift DMA write data by `dma_mem_addr[2:0]`, forward `store_data_bypass_d` / `store_data_bypass_m` from `lsu_result_m`, and mask PIC store data with `picm_mask_data_m | {32{~addr_in_pic_m}}`.
   - **Flush Qualification & Exception/FIR Error Encoding**: `flush_m_up` must not kill `fast_int` in D-stage (`lsu_pkt_d.valid = (lsu_p.valid & ~(flush_m_up & ~lsu_p.fast_int)) | dma_dccm_req`) and must not kill `dma` in M/R stages. In M-stage (`LOAD_TO_USE_PLUS1 == 0`), qualify `lsu_error_pkt_m.exc_valid` with `~lsu_pkt_m.dma & ~lsu_pkt_m.fast_int & ~flush_m_up`, set `exc_type = ~misaligned_fault_m`, report `mscause = 4'h1` on pure double-bit ECC errors (`lsu_double_ecc_error_m & ~misaligned_fault_m & ~access_fault_m`), and encode `lsu_fir_error_m` (`2'b11` for `fir_nondccm_access_error_m`, `2'b10` for `fir_dccm_access_error_m`, `2'b01` for `lsu_pkt_m.fast_int & lsu_double_ecc_error_m`).

3. **Size-Masked 4-Channel LSU Hardware Trigger Unit (`code/el2_lsu_trigger.sv`)**:
   - Mask `store_data_m` by transfer size (`word` keeps `[31:0]`, `half` keeps `[15:0]`, `by` keeps `[7:0]`), select address (`select=0`) or store data (`select=1 & store=1`) into `rvmaskandmatch`, and assert `lsu_trigger_match_m[i]` only when `lsu_pkt_m.valid & ~lsu_pkt_m.dma & trigger_enable & ((trigger_pkt_any[i].store & lsu_pkt_m.store) | (trigger_pkt_any[i].load & lsu_pkt_m.load & ~trigger_pkt_any[i].select)) & lsu_trigger_data_match[i]`.

4. **Nangate45 Area Budget & Transparent Sideband Timing Budgets (`constraints.json`)**:
   - Under `BUILD.md`, `top` must synthesize latch-free with mapped cell area `<= 3,850.0 um^2`. With `10 ns` and `12 ns` clocks (`clk_i`), `4.5 ns` external input delay on all non-clock inputs, and `3.5 ns` external output delay on all outputs, update `constraints.json` (`"max_delays"`) so that the maximum internal input-to-output combinational delay is `1.25 ns` for `pmu_in` to `pmu_out` and `2.25 ns` for `fir_in` to `fir_out`, while preserving the existing timing requirements for all registered LSU ports.

Edit only `code/el2_lsu_lsc_ctl.sv`, `code/el2_lsu_addrcheck.sv`, `code/el2_lsu_trigger.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following four files are collected and graded:
- `code/el2_lsu_lsc_ctl.sv`
- `code/el2_lsu_addrcheck.sv`
- `code/el2_lsu_trigger.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/common_defines.vh`, `code/el2_param.vh`, `code/el2_pdef.vh`, `code/el2_def.sv`, `code/beh_lib.sv`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/el2_lsu_addrcheck.sv`, `code/el2_lsu_lsc_ctl.sv`, `code/el2_lsu_trigger.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode \
  -MAKEFLAGS "VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --top-module <your_tb> --Mdir /tmp/obj_dir \
  code/common_defines.vh code/el2_def.sv code/beh_lib.sv \
  code/el2_lsu_addrcheck.sv code/el2_lsu_lsc_ctl.sv code/el2_lsu_trigger.sv \
  code/top.sv /tmp/<your_tb.sv>
/tmp/obj_dir/V<your_tb>
```

## 3. Synthesis, Area Budget, and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
Synthesizing `top` with Yosys/Slang and Nangate45 typical Liberty must be latch-free and achieve mapped cell area `<= 3,850.0 um^2`.

The STA flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `rst_ni`, `clk_override`, `lsu_ld_data_r`, `lsu_ld_data_corr_r`, `lsu_single_ecc_error_r`, `lsu_double_ecc_error_r`, `lsu_ld_data_m`, `lsu_single_ecc_error_m`, `lsu_double_ecc_error_m`, `flush_m_up`, `flush_r`, `exu_lsu_rs1_d`, `exu_lsu_rs2_d`, `lsu_pkt_bits`, `dec_lsu_valid_raw_d`, `dec_lsu_offset_d`, `picm_mask_data_m`, `bus_read_data_m`, `dec_tlu_mrac_ff`, `dma_dccm_req`, `dma_mem_addr`, `dma_mem_sz`, `dma_mem_write`, `dma_mem_wdata`, `lsu_pmp_error_start`, `lsu_pmp_error_end`, `trigger_pkt_0`, `trigger_pkt_1`, `trigger_pkt_2`, `trigger_pkt_3`, `pmu_in`, and `fir_in` (or bit-indexed `pmu_in[0..7]`, `fir_in[0..7]`, etc.).
- Output groups are `lsu_result_m`, `lsu_result_corr_r`, `lsu_addr_d`, `lsu_addr_m`, `lsu_addr_r`, `end_addr_d`, `end_addr_m`, `end_addr_r`, `store_data_m`, `lsu_exc_m`, `is_sideeffects_m`, `lsu_commit_r`, `lsu_single_ecc_error_incr`, `lsu_error_pkt_r_bits`, `lsu_fir_addr`, `lsu_fir_error`, `addr_in_dccm_d`, `addr_in_dccm_m`, `addr_in_dccm_r`, `addr_in_pic_d`, `addr_in_pic_m`, `addr_in_pic_r`, `addr_external_m`, `lsu_trigger_match_m`, `pmu_out`, and `fir_out` (or bit-indexed `pmu_out[0..7]`, `fir_out[0..7]`, etc.).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `4.5 ns` input delay on all non-clock inputs (`set_input_delay 4.5 -clock clk_i`), and `3.5 ns` output delay on all outputs (`set_output_delay 3.5 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/el2_lsu_lsc_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/el2_lsu_lsc_ctl.sv (Golden Reference)
@@ -240,7 +240,7 @@
       lsu_pkt_m_in = lsu_pkt_d;
       lsu_pkt_r_in = lsu_pkt_m;
 
-      lsu_pkt_d.valid = (lsu_p.valid & ~flush_m_up) | dma_dccm_req;
+      lsu_pkt_d.valid = (lsu_p.valid & ~(flush_m_up & ~lsu_p.fast_int)) | dma_dccm_req;
       lsu_pkt_m_in.valid = lsu_pkt_d.valid & ~(flush_m_up & ~lsu_pkt_d.dma);
       lsu_pkt_r_in.valid = lsu_pkt_m.valid & ~(flush_m_up & ~lsu_pkt_m.dma) ;
    end
@@ -304,7 +304,7 @@
    // Interrupt as a flush source allows the WB to occur
    assign lsu_commit_r = lsu_pkt_r.valid & (lsu_pkt_r.store | lsu_pkt_r.load) & ~flush_r & ~lsu_pkt_r.dma;
 
-   assign dma_mem_wdata_shifted[63:0] = dma_mem_wdata[63:0];   // Shift the dma data to lower bits to make it consistent to lsu stores
+   assign dma_mem_wdata_shifted[63:0] = 64'(dma_mem_wdata[63:0] >> {dma_mem_addr[2:0], 3'b000});   // Shift the dma data to lower bits to make it consistent to lsu stores
    assign store_data_d[31:0] = dma_dccm_req ? dma_mem_wdata_shifted[31:0] : exu_lsu_rs2_d[31:0];  // Write to PIC still happens in r stage
 
    assign store_data_m_in[31:0] = (lsu_pkt_d.store_data_bypass_d) ? lsu_result_m[31:0] : store_data_d[31:0];

--- a/environment/public/code/el2_lsu_addrcheck.sv (Buggy Starter)
+++ b/solution/gold/code/el2_lsu_addrcheck.sv (Golden Reference)
@@ -193,7 +193,7 @@
    // 3. Address is not in a populated non-dccm region
    // 5. Region predication access fault: Base Address in DCCM/PIC and Final address in non-DCCM/non-PIC region or vice versa
    // 6. Ld/St access to picm are not word aligned or word size
-   assign regpred_access_fault_d  = 1'b0;                   // 5. Region predication access fault: Base Address in DCCM/PIC and Final address in non-DCCM/non-PIC region or vice versa
+   assign regpred_access_fault_d  = (start_addr_dccm_or_pic ^ base_reg_dccm_or_pic);                   // 5. Region predication access fault: Base Address in DCCM/PIC and Final address in non-DCCM/non-PIC region or vice versa
    assign picm_access_fault_d     = (addr_in_pic_d & ((start_addr_d[1:0] != 2'b0) | ~lsu_pkt_d.word));                                               // 6. Ld/St access to picm are not word aligned or word size
 
    if (pt.DCCM_ENABLE & (pt.DCCM_REGION == pt.PIC_REGION)) begin
@@ -229,7 +229,7 @@
    assign misaligned_fault_d = (regcross_misaligned_fault_d | (sideeffect_misaligned_fault_d & addr_external_d)) & lsu_pkt_d.valid & ~lsu_pkt_d.dma;
    assign misaligned_fault_mscause_d[3:0] = regcross_misaligned_fault_d ? 4'h2 : sideeffect_misaligned_fault_d ? 4'h1 : 4'h0;
 
-   assign exc_mscause_d[3:0] = access_fault_d ? access_fault_mscause_d[3:0] : misaligned_fault_mscause_d[3:0];
+   assign exc_mscause_d[3:0] = misaligned_fault_d ? misaligned_fault_mscause_d[3:0] : access_fault_mscause_d[3:0];
 
    // Fast interrupt error logic
    assign fir_dccm_access_error_d    = ((start_addr_in_dccm_region_d & ~start_addr_in_dccm_d) |

--- a/environment/public/code/el2_lsu_trigger.sv (Buggy Starter)
+++ b/solution/gold/code/el2_lsu_trigger.sv (Golden Reference)
@@ -49,7 +49,7 @@
       end
    end
 
-   assign store_data_trigger_m[31:0] = store_data_m[31:0] & {32{trigger_enable}};
+   assign store_data_trigger_m[31:0] = {({16{lsu_pkt_m.word}} & store_data_m[31:16]),({8{(lsu_pkt_m.half | lsu_pkt_m.word)}} & store_data_m[15:8]), store_data_m[7:0]} & {32{trigger_enable}};
    assign ldst_addr_trigger_m[31:0]  = lsu_addr_m[31:0] & {32{trigger_enable}};
 
 

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,14 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": ["pmu_in"],
+      "to": ["pmu_out"],
+      "ns": 9.25
+    },
+    {
+      "from": ["fir_in"],
+      "to": ["fir_out"],
+      "ns": 10.25
+    }
+  ]
 }

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/beh_lib.sv`](environment/public/code/beh_lib.sv) *(Read-Only Context)*
- [`environment/public/code/common_defines.vh`](environment/public/code/common_defines.vh) *(Read-Only Context)*
- [`environment/public/code/el2_def.sv`](environment/public/code/el2_def.sv) *(Read-Only Context)*
- [`environment/public/code/el2_lsu_addrcheck.sv`](environment/public/code/el2_lsu_addrcheck.sv) **(Editable)**
- [`environment/public/code/el2_lsu_lsc_ctl.sv`](environment/public/code/el2_lsu_lsc_ctl.sv) **(Editable)**
- [`environment/public/code/el2_lsu_trigger.sv`](environment/public/code/el2_lsu_trigger.sv) **(Editable)**
- [`environment/public/code/el2_param.vh`](environment/public/code/el2_param.vh) *(Read-Only Context)*
- [`environment/public/code/el2_pdef.vh`](environment/public/code/el2_pdef.vh) *(Read-Only Context)*
- [`environment/public/code/top.sv`](environment/public/code/top.sv) *(Read-Only Context)*
- [`environment/public/constraints.json`](environment/public/constraints.json) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

