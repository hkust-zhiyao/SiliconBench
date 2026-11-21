# `case_6012`: VeeR-EH1 IFU 8x16-bit Instruction Aligner, RVC Decompressor, Branch Predictor, Fetch Pipe, and Sideband Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_6012` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-eh1` (`repo_06`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `parameters_widths`, `rtl_integration`, `sdc_sta` |
| **Editable Files (`allowed_edits`)** | [`code/ifu_aln_ctl.sv`](environment/public/code/ifu_aln_ctl.sv), [`code/ifu_compress_ctl.sv`](environment/public/code/ifu_compress_ctl.sv), [`code/ifu_bp_ctl.sv`](environment/public/code/ifu_bp_ctl.sv), [`code/ifu_ifc_ctl.sv`](environment/public/code/ifu_ifc_ctl.sv), [`constraints.json`](environment/public/constraints.json) (5 files, 3833 LOC) |
| **Public Subsystem Context** | 9 RTL files (5055 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Task-Specific Multi-Corner Liberty & SDC Timing Views** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Custom characterized fast/slow/scan corner Liberty libraries for multi-mode OpenSTA closure. |
| **Verifier Timeout & Seeds** | `960s` total (`480s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR-EH1 IFU 8x16-bit Instruction Aligner, RVC Decompressor, Branch Predictor, Fetch Pipe, and Sideband Timing Closure

In `code/veer_ifu_aln_bp_top.sv`, the 8x16-bit 3-entry instruction aligner (`code/ifu_aln_ctl.sv`), the RISC-V 16-bit compressed instruction decompressor (`code/ifu_compress_ctl.sv`), the BTB/BHT/RAS branch predictor (`code/ifu_bp_ctl.sv`), the F1/F2 fetch pipe controller (`code/ifu_ifc_ctl.sv`), and two transparent 8-bit sideband pass-through buses (`ghr_in` to `ghr_out` and `ras_in` to `ras_out`) are integrated together.

Update only `code/ifu_aln_ctl.sv`, `code/ifu_compress_ctl.sv`, `code/ifu_bp_ctl.sv`, `code/ifu_ifc_ctl.sv`, and `constraints.json` to satisfy all functional, synthesis, and static timing contracts:

1. **RVC 16-bit Instruction Decompression (`code/ifu_compress_ctl.sv`)**:
   - Decode and expand 16-bit RISC-V compressed instructions (`din[15:0]`) into their 32-bit equivalents (`dout[31:0]`), including `C.ADDI16SP` (`simm9_4` signed immediate bit permutation `{i[12], i[4:3], i[5], i[2], i[6]}`) and `C.LWSP` (`ulwspimm7_2` unsigned word-aligned stack offset permutation `{i[3:2], i[12], i[6:4]}`).
   - Gate `dout[31:0]` to zero whenever `legal == 1'b0` so illegal 16-bit opcodes drive `32'h0000_0000` into the decode pipe while flagging illegality.

2. **8x16-bit Instruction Aligner, Spanning Access Faults, Illegal Opcode Lockout, & Error Mutual Exclusion (`code/ifu_aln_ctl.sv`)**:
   - Align up to two instructions (`ifu_i0_instr`, `ifu_i1_instr`) per cycle from the 3-entry fetch buffer (`f0`, `f1`, `f2`), supporting arbitrary mixes of 2-byte RVC and 4-byte instructions including 4-byte instructions that straddle the boundary between `f0` and `f1`.
   - When a 4-byte instruction in slot 0 has no access fault on its first halfword (`~icaf_eff[0]`) but has an access fault on its second halfword (`icaf_eff[1]`), assert both `ifu_i0_icaf` and `ifu_i0_icaf_second`.
   - Latch the first shifted illegal 16-bit instruction into `ifu_illegal_inst[15:0]` and lock out subsequent illegal 16-bit instructions (`illegal_lockout`) from overwriting `ifu_illegal_inst` until `exu_flush_final` is asserted.
   - Maintain mutual exclusion (`$onehot0`) between `ifu_icache_error_val` and `ifu_icache_sb_error_val` when slot 0 has a single-bit ICCM ECC error (`ifu_i0_sbecc`) and slot 1 simultaneously has an I-Cache parity error (`ifu_i1_perr`).

3. **BTB, Gshare BHT, & Return Address Stack (`code/ifu_bp_ctl.sv`)**:
   - Push the return link address (`PC + 4` for 4B calls, `PC + 2` for 2B calls) onto the 4-entry return address stack on taken F2 BTB call hits, and select the top of the return address stack (`rets_out[0]`) onto `ifu_bp_btb_target_f2` while popping the stack on taken F2 BTB return hits.
   - Compute fetch-group-crossing 4-byte branch targets (`btb_sel_f2[0] & btb_rd_pc4_f2`) relative to the prior fetch group's upper halfword address `{ifc_fetch_adder_prior[31:4], 3'b111}`.

4. **Fetch Pipe Control, MRAC Cacheability, & ICCM Region Protection (`code/ifu_ifc_ctl.sv`)**:
   - Select the cacheability bit (even bit `{ifc_fetch_addr_f1[31:28], 1'b0}`) from `dec_tlu_mrac_ff` to determine `ifc_fetch_uncacheable_f1`, and assert `ifc_region_acc_fault_f1` when an F1 fetch address falls in region `0xe` (`iccm_acc_in_region_f1`) outside the valid ICCM range `[0xee000000, 0xee07ffff]` (`~iccm_acc_in_range_f1`).

5. **Synthesis, Area, & Declarative Timing Constraints (`constraints.json`)**:
   - Under `BUILD.md`, the RTL must synthesize without latches, achieve mapped Nangate45 cell area `<= 30,000.0 um^2`, and `constraints.json` must specify valid `max_delays` budgets in `(0.0, 3.0]` ns on `ghr_in -> ghr_out` and `ras_in -> ras_out` (with `10.0 ns` `clk` period and `0.2 ns` I/O delays) achieving `WNS >= 0.00 ns`, `TNS >= 0.00 ns`, and non-negative slack on all paths in OpenROAD STA.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Guide (`veer_ifu_aln_bp_top`)

## 1. Editable Files
Only the following five files are collected and graded:
- `code/ifu_aln_ctl.sv`
- `code/ifu_compress_ctl.sv`
- `code/ifu_bp_ctl.sv`
- `code/ifu_ifc_ctl.sv`
- `constraints.json`

All other files in `code/` (`veer_ifu_aln_bp_top.sv`, `beh_lib.sv`, `veer_types.sv`, `common_defines.vh`, `global.h`, `LICENSE`) and `lib/` are read-only.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary -j 2 -Wno-fatal --top-module <your_tb> -Icode \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/ifu_compress_ctl.sv code/ifu_aln_ctl.sv code/ifu_bp_ctl.sv \
  code/ifu_ifc_ctl.sv code/veer_ifu_aln_bp_top.sv <your_tb.sv> \
  --Mdir obj_dir -o sim_tb
./sim_tb
```

## 3. Synthesis & Latch Check (`Yosys/Slang`)
```bash
yosys -m slang -p "
  read_slang --single-unit --top veer_ifu_aln_bp_top -Icode \
    code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
    code/ifu_compress_ctl.sv code/ifu_aln_ctl.sv code/ifu_bp_ctl.sv \
    code/ifu_ifc_ctl.sv code/veer_ifu_aln_bp_top.sv;
  hierarchy -check -top veer_ifu_aln_bp_top;
  proc;
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr* t:\$_DLATCH* */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  opt_clean;
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr* t:\$_DLATCH* */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top veer_ifu_aln_bp_top;
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

## 4. Static Timing Analysis (`OpenROAD`) & `constraints.json` Schema
`constraints.json` must contain keys `"clocks"`, `"clock_groups"`, `"false_paths"`, `"input_delays"`, `"output_delays"`, `"max_delays"`, and `"multicycle_paths"`.
- `"clocks"`: `{"clk": {"period_ns": 10.0, "waveform_ns": [0.0, 5.0]}}`
- `"clock_groups"`, `"false_paths"`, `"multicycle_paths"`: `[]`
- `"input_delays"` / `"output_delays"`: `0.2` ns on all non-clock inputs and outputs relative to `"clk"`.
- `"max_delays"`: two entries constraining `{"from": ["ghr_in"], "to": ["ghr_out"], "delay_ns": <float>}` and `{"from": ["ras_in"], "to": ["ras_out"], "delay_ns": <float>}` with `0.0 < delay_ns <= 3.0`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/ifu_aln_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/ifu_aln_ctl.sv (Golden Reference)
@@ -896,7 +896,7 @@
 
    assign icaf_eff[3:0] = alignicaf[3:0] | aligndbecc[3:0];
 
-   assign ifu_i0_icaf_second = first4B & icaf_eff[0] & ~icaf_eff[1];
+   assign ifu_i0_icaf_second = first4B & ~icaf_eff[0] & icaf_eff[1];
 
    assign ifu_i1_icaf = ((first4B & third4B &  (|alignicaf[3:2])) |
                          (first4B & third2B &    alignicaf[2])    |
@@ -948,7 +948,7 @@
                                                             fourthpc[16:2];
 
    assign ifu_icache_error_val = (i0_shift & ifu_i0_perr) |
-                                 (i1_shift & ifu_i1_perr);
+                                 (i1_shift & ifu_i1_perr & ~ifu_i0_sbecc);
 
    assign ifu_icache_sb_error_val = (i0_shift & ifu_i0_sbecc) |
                                     (i1_shift & ifu_i1_sbecc & ~ifu_i0_perr);
@@ -1143,7 +1143,7 @@
    assign illegal_inst[15:0] =   (first2B & ~first_legal)             ? aligndata[1*16-1:0*16] :
                                 ((first2B & second2B & ~second_legal) ? aligndata[2*16-1:1*16] : aligndata[3*16-1:2*16]);
 
-   assign illegal_inst_en = shift_illegal;
+   assign illegal_inst_en = shift_illegal & ~illegal_lockout;
 
    rvdffe #(16) illegal_any_ff (.*, .en(illegal_inst_en), .din(illegal_inst[15:0]), .dout(ifu_illegal_inst[15:0]));
 

--- a/environment/public/code/ifu_compress_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/ifu_compress_ctl.sv (Golden Reference)
@@ -125,11 +125,11 @@
 
    assign uimm9d[9:2] = { i[10:7], i[12:11], i[5], i[6] };
 
-   assign simm9d[9:4] = { i[12], i[6:2] };
+   assign simm9d[9:4] = { i[12], i[4:3], i[5], i[2], i[6] };
 
    assign ulwimm6d[6:2] = { i[5], i[12:10], i[6] };
 
-   assign ulwspimm7d[7:2] = { i[12], i[6:2] };
+   assign ulwspimm7d[7:2] = { i[3:2], i[12], i[6:4] };
 
    assign uimm5d[5:0] = { i[12], i[6:2] };
 
@@ -191,7 +191,7 @@
    assign l3[6:0] = l2[6:0];
 
 
-   assign dout[31:0] = l3[31:0];
+   assign dout[31:0] = l3[31:0] & {32{legal}};
 
 
 // file "cdecode" is human readable file that has all of the compressed instruction decodes defined and is part of git repo

--- a/environment/public/code/ifu_bp_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/ifu_bp_ctl.sv (Golden Reference)
@@ -1130,14 +1130,15 @@
 
    assign ifu_bp_poffset_f2[11:0] = btb_rd_tgt_f2[11:0];
 
-   assign adder_pc_in_f2[31:4] = ifc_fetch_addr_f2[31:4];
+   assign adder_pc_in_f2[31:4] = ( ({28{ btb_fg_crossing_f2}} & ifc_fetch_adder_prior[31:4]) |
+                                   ({28{~btb_fg_crossing_f2}} & ifc_fetch_addr_f2[31:4]));
 
    rvbradder predtgt_addr (.pc({adder_pc_in_f2[31:4], bp_total_branch_offset_f2[3:1]}),
                          .offset(btb_rd_tgt_f2[11:0]),
                          .dout(bp_btb_target_adder_f2[31:1])
                          );
    // mux in the return stack address here for a predicted return
-   assign ifu_bp_btb_target_f2[31:1] = bp_btb_target_adder_f2[31:1];
+   assign ifu_bp_btb_target_f2[31:1] = btb_rd_ret_f2 & ~btb_rd_call_f2 ? rets_out[0][31:1] : bp_btb_target_adder_f2[31:1];
 
 
    // ----------------------------------------------------------------------

--- a/environment/public/code/ifu_ifc_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/ifu_ifc_ctl.sv (Golden Reference)
@@ -270,14 +270,14 @@
                                  idle ) & ~exu_flush_final) |
                               dma_iccm_stall_any_f;
 
-   assign ifc_region_acc_fault_f1 = iccm_acc_in_range_f1 & ~iccm_acc_in_region_f1 ;
+   assign ifc_region_acc_fault_f1 = ~iccm_acc_in_range_f1 & iccm_acc_in_region_f1 ;
  `else
    assign ifc_iccm_access_f1 = 1'b0 ;
    assign ifc_dma_access_ok  = 1'b0 ;
    assign ifc_region_acc_fault_f1  = 1'b0 ;
  `endif
 
-   assign cacheable_select[4:0]    =  {ifc_fetch_addr_f1[31:28] , 1'b1 } ;
+   assign cacheable_select[4:0]    =  {ifc_fetch_addr_f1[31:28] , 1'b0 } ;
    assign ifc_fetch_uncacheable_f1 =  ~dec_tlu_mrac_ff[cacheable_select]  ; // bit 0 of each region description is the cacheable bit
 
 endmodule // ifu_ifc_ctl

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -132,7 +132,7 @@
       "to": [
         "ghr_out"
       ],
-      "delay_ns": 0.15
+      "delay_ns": 2.4
     },
     {
       "from": [
@@ -141,7 +141,7 @@
       "to": [
         "ras_out"
       ],
-      "delay_ns": 0.15
+      "delay_ns": 2.4
     }
   ],
   "multicycle_paths": []

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
- [`environment/public/code/ifu_aln_ctl.sv`](environment/public/code/ifu_aln_ctl.sv) **(Editable)**
- [`environment/public/code/ifu_bp_ctl.sv`](environment/public/code/ifu_bp_ctl.sv) **(Editable)**
- [`environment/public/code/ifu_compress_ctl.sv`](environment/public/code/ifu_compress_ctl.sv) **(Editable)**
- [`environment/public/code/ifu_ifc_ctl.sv`](environment/public/code/ifu_ifc_ctl.sv) **(Editable)**
- [`environment/public/code/veer_ifu_aln_bp_top.sv`](environment/public/code/veer_ifu_aln_bp_top.sv) *(Read-Only Context)*
- [`environment/public/code/veer_types.sv`](environment/public/code/veer_types.sv) *(Read-Only Context)*
- [`environment/public/constraints.json`](environment/public/constraints.json) **(Editable)**
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

