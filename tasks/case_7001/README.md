# `case_7001`: VeeR EH2 Dual-Issue Fetch Controller, 4-Beat Instruction Aligner, and 4-Entry Decode Instruction Buffer Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_7001` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-eh2` (`repo_07`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `parameters_widths`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/eh2_ifu_ifc_ctl.sv`](environment/public/code/eh2_ifu_ifc_ctl.sv), [`code/eh2_ifu_aln_ctl.sv`](environment/public/code/eh2_ifu_aln_ctl.sv), [`code/eh2_dec_ib_ctl.sv`](environment/public/code/eh2_dec_ib_ctl.sv) (3 files, 2199 LOC) |
| **Public Subsystem Context** | 11 RTL files (5466 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR EH2 Dual-Issue Fetch Controller, 4-Beat Instruction Aligner, and 4-Entry Decode Instruction Buffer Closure

In `code/eh2_ifu_ib_top.sv`, update only `code/eh2_ifu_ifc_ctl.sv`, `code/eh2_ifu_aln_ctl.sv`, and `code/eh2_dec_ib_ctl.sv` to satisfy all boundary contracts. `eh2_ifu_ifc_ctl` must track 4-beat fetch-buffer occupancy across single-buffer (`ifu_fb_consume1`) and dual-buffer (`ifu_fb_consume2`) consumption, including cycles where two buffers are consumed simultaneously with a winning fetch (`fetch_req_f1_won & ~miss_f2`), allow `fetch_req_f1` and clear `pmu_fetch_stall` when `fb_full_f1` is high and at least one buffer is being consumed (`ifu_fb_consume1 | ifu_fb_consume2`), redirect `fetch_addr_bf` on `exu_flush_final` or predicted taken branches (`ifu_bp_kill_next_f2`), and block fetches on `ic_dma_active`, `dma_iccm_stall_any`, or `ic_write_stall`. `eh2_ifu_aln_ctl` must align up to two 16-bit/32-bit instructions (`i0`, `i1`) per cycle across the four 64-bit fetch buffers, update `f1_shift_2B`, `f1_shift_4B`, `f1_shift_6B`, halfword queue offsets, and `fb_consume1`/`fb_consume2` across 2B/4B/6B/8B alignment shifts, suppress `i1_valid` when `i1` has an access fault (`i1_icaf`) or double-bit ECC error (`i1_dbecc`), latch `error_stall` on `ifu_async_error_start` until `exu_flush_final`, and report `i0_icaf`, `i0_icaf_second`, `i0_icaf_type`, and `i0_dbecc` across split 32-bit instructions. `eh2_dec_ib_ctl` must maintain the 4-entry instruction buffer (`ib0..ib3`) across 0/1/2-instruction decode shifts, roll back `ib0..ib3`, `bp0..bp3`, and `ibval` from `ibsave`/`bpsave` when `dec_i1_cancel_e1` asserts, and synthesize halted debug GPR/CSR read/write instructions when `dbg_cmd_valid` is high and `dbg_cmd_type != 2'h2`, asserting `debug_wdata_rs1_d` on writes and `debug_fence_d` on CSR writes to `12'h7c4`.

The RTL must synthesize without latches. Under the Yosys/Slang Nangate45 flow (`BUILD.md`), `eh2_ifu_ib_top` must achieve mapped area `<= 20,250.0 um^2`, and OpenROAD STA at a `9.25 ns` clock on `clk` (`0.15 ns` I/O delays, `5.0 fF` load) must achieve worst setup slack (`WNS`) `>= 0.00 ns` and hold slack (`WHS`) `>= 0.00 ns`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/eh2_ifu_ifc_ctl.sv`
- `code/eh2_ifu_aln_ctl.sv`
- `code/eh2_dec_ib_ctl.sv`

All other files in `code/` (`common_defines.vh`, `eh2_param.vh`, `eh2_pdef.vh`, `eh2_def.sv`, `beh_lib.sv`, `eh2_lib.sv`, `eh2_ifu_compress_ctl.sv`, `eh2_ifu_ib_top.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `eh2_ifu_ib_top` with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -Icode --top-module tb \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
  code/eh2_ifu_compress_ctl.sv code/eh2_ifu_ifc_ctl.sv \
  code/eh2_ifu_aln_ctl.sv code/eh2_dec_ib_ctl.sv \
  code/eh2_ifu_ib_top.sv /tmp/tb.sv
./obj_dir/Vtb
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `eh2_ifu_ib_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top eh2_ifu_ib_top -Icode \
    code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv code/beh_lib.sv code/eh2_lib.sv \
    code/eh2_ifu_compress_ctl.sv code/eh2_ifu_ifc_ctl.sv \
    code/eh2_ifu_aln_ctl.sv code/eh2_dec_ib_ctl.sv code/eh2_ifu_ib_top.sv;
  hierarchy -check -top eh2_ifu_ib_top;
  proc; opt_clean;
  chformal -remove;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top eh2_ifu_ib_top;
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

Target mapped cell area (`Chip area for module '\eh2_ifu_ib_top'`): **`<= 20250.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `9.25 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_l` and `scan_mode`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design eh2_ifu_ib_top
create_clock -name clk -period 9.25 [get_ports clk]
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
--- a/environment/public/code/eh2_ifu_ifc_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/eh2_ifu_ifc_ctl.sv (Golden Reference)
@@ -271,7 +271,8 @@
 
    // model fb write logic to mass balance the fetch buffers
    assign fb_right = (~ifu_fb_consume1 & ~ifu_fb_consume2 & miss_f2) |  // F2 cache miss, repair mass balance
-                     ( ifu_fb_consume1 & ~ifu_fb_consume2 & ~fetch_req_f1_won & ~miss_f2);
+                     ( ifu_fb_consume1 & ~ifu_fb_consume2 & ~fetch_req_f1_won & ~miss_f2) | // Consumed and no new fetch
+                      (ifu_fb_consume2 &  fetch_req_f1_won & ~miss_f2); // Consumed 2 and new fetch
 
 
    assign fb_right2 = (ifu_fb_consume1 & ~ifu_fb_consume2 & miss_f2) | // consume 1 and miss 1
@@ -323,7 +324,7 @@
    assign fetch_req_f1 = ( fetch_req_f1_raw &
                            ~kill_fetch &
                            ~my_bp_kill_next_f2 &
-                           ~(fb_full_f1 & ~flush_fb) &
+                           ~(fb_full_f1 & ~(ifu_fb_consume2 | ifu_fb_consume1 | flush_fb)) &
                            ~dma_stall &
                            ~ic_write_stall &
                            ~flush_noredir );

--- a/environment/public/code/eh2_ifu_aln_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/eh2_ifu_aln_ctl.sv (Golden Reference)
@@ -270,7 +270,7 @@
 
    assign fetch_val[3:0] = ifu_fetch_val[3:0];
 
-   assign error_stall_in = error_stall & ~exu_flush_final;
+   assign error_stall_in = (error_stall | ifu_async_error_start) & ~exu_flush_final;
 
    rvdffie #(13) bundle1ff   (.*,
                               .din({ error_stall_in,wrptr_in[1:0],rdptr_in[1:0],q3off_in[1:0],q2off_in[1:0],q1off_in[1:0],q0off_in[1:0]}),
@@ -795,18 +795,18 @@
    assign i1_valid = ((first4B & third4B & alignval[3])  |
                       (first4B & third2B & alignval[2])  |
                       (first2B & second4B & alignval[2]) |
-                      (first2B & second2B & alignval[1])) & ~exu_flush_final;
+                      (first2B & second2B & alignval[1])) & ~exu_flush_final & ~i1_icaf & ~i1_dbecc;
 
    // inst access fault on any byte of inst results in access fault for the inst
    assign i0_icaf = ((first4B & (|alignicaf[1:0])) |
                      (first2B &   alignicaf[0])) & ~exu_flush_final;
 
    // restrict icaf and dbecc to be i0 only
-   assign i0_icaf_type[1:0] = f0ictype[1:0];
+   assign i0_icaf_type[1:0] = (first4B & ~f0val[1] & f0val[0] & ~alignicaf[0] & ~aligndbecc[0]) ? f1ictype[1:0] : f0ictype[1:0];
 
    assign icaf_eff[1:0] = alignicaf[1:0] | aligndbecc[1:0];
 
-   assign i0_icaf_second = 1'b0;
+   assign i0_icaf_second = first4B & ~icaf_eff[0] & icaf_eff[1];
 
 
    assign i1_icaf = ((first4B & third4B &  (|alignicaf[3:2])) |
@@ -1128,11 +1128,14 @@
    // 10000000
    // 00000000
 
-   assign f1_shift_2B = 1'b0;
-
-   assign f1_shift_4B = 1'b0;
-
-   assign f1_shift_6B = 1'b0;
+   assign f1_shift_2B = (f0val[2] & ~f0val[3] & shift_8B) |
+                        (f0val[1] & ~f0val[2] & shift_6B) |
+                        (f0val[0] & ~f0val[1] & shift_4B);
+
+   assign f1_shift_4B = (f0val[1] & ~f0val[2] & shift_8B) |
+                        (f0val[0] & ~f0val[1] & shift_6B);
+
+   assign f1_shift_6B = (f0val[0] & ~f0val[1] & shift_8B);
 
 
 

--- a/environment/public/code/eh2_dec_ib_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/eh2_dec_ib_ctl.sv (Golden Reference)
@@ -212,7 +212,7 @@
 
    assign ibvalid[3:0] = ibval[3:0] | i0_wen[3:0] | {i1_wen[3:1],1'b0};
 
-   assign ibval_in[3:0] = (({4{shift0}} & ibvalid[3:0]) |
+   assign ibval_in[3:0] = (({4{shift0}} & ((i1_cancel_e1) ? {ibval[2:0],1'b1} : ibvalid[3:0] )) |
                            ({4{shift1}} & {1'b0, ibvalid[3:1]}) |
                            ({4{shift2}} & {2'b0, ibvalid[3:2]})) & ~{4{flush_final}};
 
@@ -299,7 +299,7 @@
    assign ib0_debug_in[31:0] = ({32{debug_read_gpr}}  & {12'b000000000000,dreg[4:0],15'b110000000110011}) |
                                ({32{debug_write_gpr}} & {20'b00000000000000000110,dreg[4:0],7'b0110011}) |
                                ({32{debug_read_csr}}  & {dcsr[11:0],20'b00000010000001110011}) |
-                               ({32{debug_write_csr}} & {dcsr[11:0],20'b00000010000001110011});
+                               ({32{debug_write_csr}} & {dcsr[11:0],20'b00000001000001110011});
 
 
    // for MT, need to hold this until thread decodes, other thread can be running
@@ -309,7 +309,7 @@
    // special fence csr for use only in debug mode
 
 
-   assign debug_fence_in = debug_write_csr & (dcsr[11:0] == 12'h7c0);
+   assign debug_fence_in = debug_write_csr & (dcsr[11:0] == 12'h7c4);
 
    rvdffs #(1) debug_fence_ff (.*,  .clk(active_clk), .en(ibwrite[0]), .din(debug_fence_in),  .dout(debug_fence_d));
 
@@ -384,7 +384,7 @@
 
    // end timing
 
-   assign ib0_final = ib0_in;
+   assign ib0_final = (i1_cancel_e1) ? ibsave : ib0_in;
 
    assign ib0_final_in = (ibwrite[0]) ? ib0_final : ib0;
 

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/beh_lib.sv`](environment/public/code/beh_lib.sv) *(Read-Only Context)*
- [`environment/public/code/common_defines.vh`](environment/public/code/common_defines.vh) *(Read-Only Context)*
- [`environment/public/code/eh2_dec_ib_ctl.sv`](environment/public/code/eh2_dec_ib_ctl.sv) **(Editable)**
- [`environment/public/code/eh2_def.sv`](environment/public/code/eh2_def.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_ifu_aln_ctl.sv`](environment/public/code/eh2_ifu_aln_ctl.sv) **(Editable)**
- [`environment/public/code/eh2_ifu_compress_ctl.sv`](environment/public/code/eh2_ifu_compress_ctl.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_ifu_ib_top.sv`](environment/public/code/eh2_ifu_ib_top.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_ifu_ifc_ctl.sv`](environment/public/code/eh2_ifu_ifc_ctl.sv) **(Editable)**
- [`environment/public/code/eh2_lib.sv`](environment/public/code/eh2_lib.sv) *(Read-Only Context)*
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

