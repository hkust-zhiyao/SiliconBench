# `case_0071`: VeeR EL2 Fetch Controller, Instruction Aligner, and Decode Instruction Buffer Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0071` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-el2` (`repo_08`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `parameters_widths`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/el2_ifu_ifc_ctl.sv`](environment/public/code/el2_ifu_ifc_ctl.sv), [`code/el2_ifu_aln_ctl.sv`](environment/public/code/el2_ifu_aln_ctl.sv), [`code/el2_dec_ib_ctl.sv`](environment/public/code/el2_dec_ib_ctl.sv) (3 files, 1113 LOC) |
| **Public Subsystem Context** | 11 RTL files (3605 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR EL2 Fetch Controller, Instruction Aligner, and Decode Buffer Closure

In `code/el2_ifu_ib_top.sv`, update only `code/el2_ifu_ifc_ctl.sv`, `code/el2_ifu_aln_ctl.sv`, and `code/el2_dec_ib_ctl.sv` to satisfy all boundary contracts. `el2_ifu_ifc_ctl` must track fetch-buffer occupancy across single-buffer (`ifu_fb_consume1`) and dual-buffer (`ifu_fb_consume2`) consumption, including cycles where two buffers are consumed simultaneously with a hitting fetch (`ifc_fetch_req_f && ic_hit_f`), assert `ifc_fetch_req_bf` whenever a buffer frees, redirect `ifc_fetch_addr_bf` on `exu_flush_final` or predicted taken branches (`ifu_bp_hit_taken_f`), and block fetches on `ic_dma_active`, `dma_iccm_stall_any`, or `ic_write_stall`. `el2_ifu_aln_ctl` must align 16-bit and 32-bit instructions across the three 32-bit buffers, update halfword offsets and `ifu_fb_consume1`/`ifu_fb_consume2` when a 32-bit instruction spans two buffers while `dec_i0_decode_d` is high, hold `ifu_i0_valid`, `dec_i0_instr_d`, and `dec_i0_pc_d` stable while `dec_i0_decode_d` is low or after `ifu_async_error_start` until `exu_flush_final`, and report `dec_i0_icaf_d`, `dec_i0_icaf_second_d`, `dec_i0_icaf_type_d`, and `dec_i0_dbecc_d` across split 32-bit instructions. `el2_dec_ib_ctl` must synthesize halted debug GPR/CSR read/write instructions when `dbg_cmd_valid` is high and `dbg_cmd_type != 2'h2`, asserting `dec_debug_wdata_rs1_d` on writes and `dec_debug_fence_d` on CSR writes to `12'h7c4`.

The RTL must synthesize without latches. Under the Yosys/Slang Nangate45 flow (`BUILD.md`), `el2_ifu_ib_top` must achieve mapped area `<= 5,165.0 um^2`, and OpenROAD STA at a `4.45 ns` clock on `clk` (`0.15 ns` I/O delays, `5.0 fF` load) must achieve worst setup slack (`WNS`) `>= 0.00 ns` and hold slack (`WHS`) `>= 0.00 ns`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/el2_ifu_ifc_ctl.sv`
- `code/el2_ifu_aln_ctl.sv`
- `code/el2_dec_ib_ctl.sv`

All other files in `code/` (`common_defines.vh`, `el2_param.vh`, `el2_pdef.vh`, `el2_def.sv`, `beh_lib.sv`, `el2_lib.sv`, `el2_ifu_compress_ctl.sv`, `el2_ifu_ib_top.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`, `LICENSE.Nangate45`) are read-only.

## 2. Behavioral Simulation (Verilator)

Compile and simulate `el2_ifu_ib_top` with Verilator 5.038:

```bash
verilator --binary --timing -j 1 -Wno-fatal \
  -Icode --top-module tb \
  code/common_defines.vh code/el2_def.sv code/beh_lib.sv code/el2_lib.sv \
  code/el2_ifu_compress_ctl.sv code/el2_ifu_ifc_ctl.sv \
  code/el2_ifu_aln_ctl.sv code/el2_dec_ib_ctl.sv \
  code/el2_ifu_ib_top.sv /tmp/tb.sv
./obj_dir/Vtb
```

## 3. Latch-Free & Nangate45 Synthesis Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `el2_ifu_ib_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --top el2_ifu_ib_top -Icode \
    code/common_defines.vh code/el2_def.sv code/beh_lib.sv code/el2_lib.sv \
    code/el2_ifu_compress_ctl.sv code/el2_ifu_ifc_ctl.sv \
    code/el2_ifu_aln_ctl.sv code/el2_dec_ib_ctl.sv code/el2_ifu_ib_top.sv;
  hierarchy -check -top el2_ifu_ib_top;
  proc; opt_clean;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top el2_ifu_ib_top;
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

Target mapped cell area (`Chip area for module '\el2_ifu_ib_top'`): **`<= 5165.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Strip ` signed ` tokens (`sed 's/ signed / /g' /tmp/mapped.v > /tmp/sta.v`) and evaluate `/tmp/sta.v` in OpenROAD with a `4.45 ns` clock period on `clk`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from `rst_l` and `scan_mode`:

```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/sta.v
link_design el2_ifu_ib_top
create_clock -name clk -period 4.45 [get_ports clk]
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
--- a/environment/public/code/el2_ifu_ifc_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/el2_ifu_ifc_ctl.sv (Golden Reference)
@@ -137,7 +137,7 @@
    assign ifc_fetch_req_bf_raw = ~idle;
    assign ifc_fetch_req_bf =  ifc_fetch_req_bf_raw &
 
-                 ~fb_full_f_ns &
+                 ~(fb_full_f_ns & ~(ifu_fb_consume2 | ifu_fb_consume1)) &
                  ~dma_stall &
                  ~ic_write_stall &
                  ~dec_tlu_flush_noredir_wb;
@@ -180,7 +180,8 @@
    assign flush_fb = exu_flush_final;
 
    // model fb write logic to mass balance the fetch buffers
-   assign fb_right = ( ifu_fb_consume1 & ~ifu_fb_consume2 & (~ifc_fetch_req_f | miss_f));
+   assign fb_right = ( ifu_fb_consume1 & ~ifu_fb_consume2 & (~ifc_fetch_req_f | miss_f)) | // Consumed and no new fetch
+              (ifu_fb_consume2 &  ifc_fetch_req_f); // Consumed 2 and new fetch
 
 
    assign fb_right2 = (ifu_fb_consume2 & (~ifc_fetch_req_f | miss_f)); // Consumed 2 and no new fetch

--- a/environment/public/code/el2_ifu_aln_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/el2_ifu_aln_ctl.sv (Golden Reference)
@@ -203,7 +203,7 @@
 
    logic                                         error_stall_in, error_stall;
 
-   assign error_stall_in = error_stall & ~exu_flush_final;
+   assign error_stall_in = (error_stall | ifu_async_error_start) & ~exu_flush_final;
 
    rvdff #(.WIDTH(7))  bundle1ff (.*,
                                   .clk(active_clk),
@@ -557,11 +557,12 @@
    assign ifu_i0_icaf        = (first4B & (|alignicaf[1:0])) |
                                (first2B &   alignicaf[0]   );
 
-   assign ifu_i0_icaf_type[1:0] = f0ictype[1:0];
+   assign ifu_i0_icaf_type[1:0] = (first4B & ~f0val[1] & f0val[0] & ~alignicaf[0] & ~aligndbecc[0]) ? f1ictype[1:0] : f0ictype[1:0];
+
 
    assign icaf_eff[1:0] = alignicaf[1:0] | aligndbecc[1:0];
 
-   assign ifu_i0_icaf_second = 1'b0;
+   assign ifu_i0_icaf_second = first4B & ~icaf_eff[0] & icaf_eff[1];
 
    assign ifu_i0_dbecc       = (first4B & (|aligndbecc[1:0])) |
                                (first2B &   aligndbecc[0]   );
@@ -694,7 +695,7 @@
    //     10
    //     00
 
-   assign f1_shift_2B        =  1'b0;
+   assign f1_shift_2B        =  f0val[0] & ~f0val[1] & shift_4B;
 
 
 

--- a/environment/public/code/el2_dec_ib_ctl.sv (Buggy Starter)
+++ b/solution/gold/code/el2_dec_ib_ctl.sv (Golden Reference)
@@ -134,7 +134,7 @@
    assign ib0_debug_in[31:0] = ({32{debug_read_gpr}}  & {12'b000000000000,dreg[4:0],15'b110000000110011}) |
                                ({32{debug_write_gpr}} & {20'b00000000000000000110,dreg[4:0],7'b0110011}) |
                                ({32{debug_read_csr}}  & {dcsr[11:0],20'b00000010000001110011}) |
-                               ({32{debug_write_csr}} & {dcsr[11:0],20'b00000010000001110011});
+                               ({32{debug_write_csr}} & {dcsr[11:0],20'b00000001000001110011});
 
 
 
@@ -145,7 +145,7 @@
 
    // special fence csr for use only in debug mode
 
-   assign dec_debug_fence_d = debug_write_csr & (dcsr[11:0] == 12'h7c0);
+   assign dec_debug_fence_d = debug_write_csr & (dcsr[11:0] == 12'h7c4);
 
    assign ib0[31:0] = (debug_valid) ? ib0_debug_in[31:0] : ifu_i0_instr[31:0];
 

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/beh_lib.sv`](environment/public/code/beh_lib.sv) *(Read-Only Context)*
- [`environment/public/code/common_defines.vh`](environment/public/code/common_defines.vh) *(Read-Only Context)*
- [`environment/public/code/el2_dec_ib_ctl.sv`](environment/public/code/el2_dec_ib_ctl.sv) **(Editable)**
- [`environment/public/code/el2_def.sv`](environment/public/code/el2_def.sv) *(Read-Only Context)*
- [`environment/public/code/el2_ifu_aln_ctl.sv`](environment/public/code/el2_ifu_aln_ctl.sv) **(Editable)**
- [`environment/public/code/el2_ifu_compress_ctl.sv`](environment/public/code/el2_ifu_compress_ctl.sv) *(Read-Only Context)*
- [`environment/public/code/el2_ifu_ib_top.sv`](environment/public/code/el2_ifu_ib_top.sv) *(Read-Only Context)*
- [`environment/public/code/el2_ifu_ifc_ctl.sv`](environment/public/code/el2_ifu_ifc_ctl.sv) **(Editable)**
- [`environment/public/code/el2_lib.sv`](environment/public/code/el2_lib.sv) *(Read-Only Context)*
- [`environment/public/code/el2_param.vh`](environment/public/code/el2_param.vh) *(Read-Only Context)*
- [`environment/public/code/el2_pdef.vh`](environment/public/code/el2_pdef.vh) *(Read-Only Context)*
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

