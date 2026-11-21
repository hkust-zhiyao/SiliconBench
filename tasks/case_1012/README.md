# `case_1012`: OpenTitan DOE Mailbox Pointer Advancement, Abort Zeroization, Stale Response Filtering, and Timing/Area Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_1012` |
| **Source Silicon Repository** | `lowRISC/opentitan` (`repo_01`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `protocol_control`, `reset_rdc`, `rtl_integration`, `rtl_semantics`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/mbx_imbx.sv`](environment/public/code/mbx_imbx.sv), [`code/mbx_ombx.sv`](environment/public/code/mbx_ombx.sv), [`code/mbx_sramrwarb.sv`](environment/public/code/mbx_sramrwarb.sv) (3 files, 481 LOC) |
| **Public Subsystem Context** | 36 RTL files (6479 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# OpenTitan DOE Mailbox Pointer Advancement, Abort Zeroization, Stale Response Filtering, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan DOE Mailbox subsystem (`code/ot_mbx_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **Inbound Mailbox Initial Write Pointer Advancement**:
   - In `mbx_imbx`, when the initial word write of an inbound message (`mbx_empty && sysif_data_write_valid_i`) is granted on the same clock cycle (`hostif_sram_write_gnt_i = 1'b1`), `sram_write_ptr_q` reloads `hostif_base_i` instead of advancing to `hostif_base_i + LCFG_SRM_ADDRINC`, causing the second word write of the message to overwrite `hostif_base_i`.

2. **Outbound Mailbox Object-Size Zeroization on Host Abort Clear**:
   - In `mbx_ombx`, when the host acknowledges an abort (`hostif_control_abort_clear_i = 1'b1`), `hostif_ombx_object_size_update_o` asserts, but `hostif_ombx_object_size_o` drives `hostif_ombx_object_size_i - 1` instead of zero (`'0`), underflowing or corrupting the outbound object size register on abort recovery.

3. **Stale SRAM Read Response Suppression After Abort**:
   - In `mbx_sramrwarb`, when an in-flight TL-UL read response (`AccessAckData`) returns after an abort has cleared the outstanding request counter (`any_outstanding_reqs == 1'b0`), `ombx_sram_read_resp_vld_o` still pulses high, latching stale read data into `mbx_ombx` and falsely transitioning the outbound mailbox into the ready state.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_mbx_top`, `1.45 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_mbx_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/mbx_imbx.sv`, `code/mbx_ombx.sv`, and `code/mbx_sramrwarb.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_mbx_top`: **`<= 1950.0 um^2`**
- Worst setup slack and worst hold slack at `1.45 ns` clock period: **`>= 0.0 ns`**

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/mbx_imbx.sv`
- `code/mbx_ombx.sv`
- `code/mbx_sramrwarb.sv`

All other files in `code/` (`ot_mbx_top.sv`, `mbx_fsm.sv`, `tlul_adapter_host.sv`, `tlul_cmd_intg_gen.sv`, `tlul_rsp_intg_chk.sv`, `tlul_data_integ_enc.sv`, `tlul_data_integ_dec.sv`, `tlul_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_mbx_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_flop_macros.sv \
  code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
  code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv code/prim_count.sv \
  code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
  code/prim_secded_inv_64_57_enc.sv code/prim_secded_inv_64_57_dec.sv \
  code/tlul_pkg.sv code/tlul_data_integ_enc.sv code/tlul_data_integ_dec.sv \
  code/tlul_cmd_intg_gen.sv code/tlul_rsp_intg_chk.sv code/tlul_adapter_host.sv \
  code/mbx_fsm.sv code/mbx_imbx.sv code/mbx_ombx.sv code/mbx_sramrwarb.sv \
  code/ot_mbx_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_mbx_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_mbx_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_flop_macros.sv \
    code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
    code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv code/prim_count.sv \
    code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
    code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
    code/prim_secded_inv_64_57_enc.sv code/prim_secded_inv_64_57_dec.sv \
    code/tlul_pkg.sv code/tlul_data_integ_enc.sv code/tlul_data_integ_dec.sv \
    code/tlul_cmd_intg_gen.sv code/tlul_rsp_intg_chk.sv code/tlul_adapter_host.sv \
    code/mbx_fsm.sv code/mbx_imbx.sv code/mbx_ombx.sv code/mbx_sramrwarb.sv \
    code/ot_mbx_top.sv;
  hierarchy -check -top ot_mbx_top;
  synth -top ot_mbx_top;
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

Target mapped cell area (`Chip area for module '\ot_mbx_top'`): **`<= 1950.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `1.45 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_mbx_top
create_clock -name clk_i -period 1.45 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded -digits 4
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded -digits 4
```

Target worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`): **`>= 0.0 ns`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/mbx_imbx.sv (Buggy Starter)
+++ b/solution/gold/code/mbx_imbx.sv (Golden Reference)
@@ -36,7 +36,6 @@
   localparam int unsigned LCFG_SRM_ADDRINC = CfgSramDataWidth / 8;
 
   logic [CfgSramAddrWidth-1:0] sram_write_ptr_d, sram_write_ptr_q;
-
   logic mbx_empty, mbx_write, mbx_read, mbx_sys_abort;
 
   logic write_req;
@@ -67,7 +66,7 @@
 
   logic load_write_ptr, advance_write_ptr;
 
-  assign load_write_ptr = mbx_empty | host_clear_abort |
+  assign load_write_ptr = (mbx_empty & ~advance_write_ptr) | host_clear_abort |
                           (mbx_read & sys_read_all_i);
 
   assign advance_write_ptr = hostif_sram_write_req_o & hostif_sram_write_gnt_i;

--- a/environment/public/code/mbx_ombx.sv (Buggy Starter)
+++ b/solution/gold/code/mbx_ombx.sv (Golden Reference)
@@ -41,16 +41,29 @@
   localparam int unsigned LCFG_SRM_ADDRINC = CfgSramDataWidth / 8;
 
   logic [CfgSramAddrWidth-1:0] sram_read_ptr_d, sram_read_ptr_q;
-  logic [CfgSramAddrWidth-1:0] sram_read_ptr_limit_d, sram_read_ptr_limit_q;
-
   logic mbx_empty, mbx_read, mbx_sys_abort;
   logic set_first_req, clear_first_req;
+  logic rem_words_nonzero, rem_words_q;
+  logic host_write_object_size_q, ombx_object_size_update_valid_q;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      rem_words_q <= 1'b0;
+    end else if (hostif_control_abort_clear_i) begin
+      rem_words_q <= 1'b0;
+    end else if (ombx_sram_read_req_o & ombx_sram_read_gnt_i) begin
+      rem_words_q <= (hostif_ombx_object_size_i > CfgObjectSizeWidth'(1));
+    end else if (host_write_object_size_q & ~mbx_read) begin
+      rem_words_q <= (|hostif_ombx_object_size_i);
+    end
+  end
+  assign rem_words_nonzero = rem_words_q;
 
   logic read_req, first_req_q;
   assign read_req = first_req_q |
-                    (mbx_read & sysif_read_data_write_valid_i   &
-                    (sram_read_ptr_q <= hostif_limit_i)         &
-                    (sram_read_ptr_q < sram_read_ptr_limit_q));
+                    (mbx_read & sysif_read_data_write_valid_i &
+                    (sram_read_ptr_q <= hostif_limit_i)       &
+                    rem_words_nonzero);
 
   logic awaiting_gnt;
   assign awaiting_gnt = ombx_sram_read_req_o & ~ombx_sram_read_gnt_i &
@@ -72,7 +85,7 @@
 
   assign set_pending   = mbx_read & sysif_read_data_write_valid_i &
                         (sram_read_ptr_q <= hostif_limit_i)       &
-                        (sram_read_ptr_q < sram_read_ptr_limit_q);
+                        rem_words_nonzero;
   assign clear_pending = ombx_sram_read_resp_valid_i | hostif_control_abort_clear_i;
 
   prim_flop #(
@@ -87,9 +100,9 @@
   logic writer_close_mbx;
   assign writer_close_mbx = mbx_empty & ombx_sram_read_resp_valid_i;
 
-  assign sys_read_all_o = mbx_read                       &
-                          sysif_read_data_write_valid_i  &
-                          (sram_read_ptr_q == sram_read_ptr_limit_q);
+  assign sys_read_all_o = mbx_read                      &
+                          sysif_read_data_write_valid_i &
+                          ~rem_words_nonzero;
 
   logic host_clear_abort;
   assign host_clear_abort = hostif_control_abort_clear_i & mbx_sys_abort;
@@ -99,13 +112,11 @@
   logic range_valid_set;
   assign range_valid_set = hostif_range_valid_write_i & hostif_range_valid_i;
 
-  assign load_read_ptr = range_valid_set | set_first_req | sys_read_all_o | host_clear_abort;
-
+  assign load_read_ptr    = range_valid_set | set_first_req | sys_read_all_o | host_clear_abort;
   assign advance_read_ptr = ombx_sram_read_req_o & ombx_sram_read_gnt_i;
 
   always_comb begin
     sram_read_ptr_d = sram_read_ptr_q;
-
     if (load_read_ptr) begin
       sram_read_ptr_d = hostif_base_i;
     end else if (advance_read_ptr) begin
@@ -143,9 +154,6 @@
     .q_o   ( ombx_read_data_o                                             )
   );
 
-  logic host_write_object_size_q;
-  logic ombx_object_size_update_valid_q;
-
   prim_flop #(
     .Width(1)
   ) u_host_write_object_size (
@@ -159,7 +167,8 @@
   assign hostif_ombx_object_size_update_o = (ombx_sram_read_req_o & ombx_sram_read_gnt_i) |
                                              hostif_control_abort_clear_i;
   assign hostif_ob_object_size_minus_one = hostif_ombx_object_size_i - 1;
-  assign hostif_ombx_object_size_o       = hostif_ob_object_size_minus_one;
+  assign hostif_ombx_object_size_o       = {CfgObjectSizeWidth{~hostif_control_abort_clear_i}} &
+                                           hostif_ob_object_size_minus_one;
 
   prim_flop #(
     .Width(1)
@@ -168,19 +177,6 @@
     .rst_ni( rst_ni                           ),
     .d_i   ( hostif_ombx_object_size_update_o ),
     .q_o   ( ombx_object_size_update_valid_q  )
-  );
-
-  assign sram_read_ptr_limit_d = hostif_base_i +
-                                 CfgSramAddrWidth'({hostif_ombx_object_size_i, 2'b0});
-
-  prim_flop_en #(
-    .Width(CfgSramAddrWidth)
-  ) u_sram_read_ptr_limit (
-    .clk_i ( clk_i                                                    ),
-    .rst_ni( rst_ni                                                   ),
-    .en_i  ( (host_write_object_size_q & ~mbx_read) | range_valid_set ),
-    .d_i   ( sram_read_ptr_limit_d                                    ),
-    .q_o   ( sram_read_ptr_limit_q                                    )
   );
 
   assign set_first_req   = mbx_empty & host_write_object_size_q & (|hostif_ombx_object_size_i);

--- a/environment/public/code/mbx_sramrwarb.sv (Buggy Starter)
+++ b/solution/gold/code/mbx_sramrwarb.sv (Golden Reference)
@@ -102,7 +102,7 @@
 
   assign sram_err_o = sram_err & sram_valid;
 
-  assign ombx_sram_read_resp_vld_o = sram_valid &
+  assign ombx_sram_read_resp_vld_o = sram_valid & any_outstanding_reqs &
                                     (tl_host_i.d_opcode == tlul_pkg::AccessAckData);
 
 endmodule

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/mbx_fsm.sv`](environment/public/code/mbx_fsm.sv) *(Read-Only Context)*
- [`environment/public/code/mbx_imbx.sv`](environment/public/code/mbx_imbx.sv) **(Editable)**
- [`environment/public/code/mbx_ombx.sv`](environment/public/code/mbx_ombx.sv) **(Editable)**
- [`environment/public/code/mbx_sramrwarb.sv`](environment/public/code/mbx_sramrwarb.sv) **(Editable)**
- [`environment/public/code/ot_mbx_top.sv`](environment/public/code/ot_mbx_top.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert.sv`](environment/public/code/prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/prim_assert_dummy_macros.svh`](environment/public/code/prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_sec_cm.svh`](environment/public/code/prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_standard_macros.svh`](environment/public/code/prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_assert_yosys_macros.svh`](environment/public/code/prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/prim_buf.sv`](environment/public/code/prim_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count.sv`](environment/public/code/prim_count.sv) *(Read-Only Context)*
- [`environment/public/code/prim_count_pkg.sv`](environment/public/code/prim_count_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_assert.svh`](environment/public/code/prim_fifo_assert.svh) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync.sv`](environment/public/code/prim_fifo_sync.sv) *(Read-Only Context)*
- [`environment/public/code/prim_fifo_sync_cnt.sv`](environment/public/code/prim_fifo_sync_cnt.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop.sv`](environment/public/code/prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_en.sv`](environment/public/code/prim_flop_en.sv) *(Read-Only Context)*
- [`environment/public/code/prim_flop_macros.sv`](environment/public/code/prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/prim_mubi_pkg.sv`](environment/public/code/prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_buf.sv`](environment/public/code/prim_sec_anchor_buf.sv) *(Read-Only Context)*
- [`environment/public/code/prim_sec_anchor_flop.sv`](environment/public/code/prim_sec_anchor_flop.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inc.svh`](environment/public/code/prim_secded_inc.svh) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_dec.sv`](environment/public/code/prim_secded_inv_39_32_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_39_32_enc.sv`](environment/public/code/prim_secded_inv_39_32_enc.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_64_57_dec.sv`](environment/public/code/prim_secded_inv_64_57_dec.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_inv_64_57_enc.sv`](environment/public/code/prim_secded_inv_64_57_enc.sv) *(Read-Only Context)*
- [`environment/public/code/prim_secded_pkg.sv`](environment/public/code/prim_secded_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/prim_util_pkg.sv`](environment/public/code/prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/tlul_adapter_host.sv`](environment/public/code/tlul_adapter_host.sv) *(Read-Only Context)*
- [`environment/public/code/tlul_cmd_intg_gen.sv`](environment/public/code/tlul_cmd_intg_gen.sv) *(Read-Only Context)*
- [`environment/public/code/tlul_data_integ_dec.sv`](environment/public/code/tlul_data_integ_dec.sv) *(Read-Only Context)*
- [`environment/public/code/tlul_data_integ_enc.sv`](environment/public/code/tlul_data_integ_enc.sv) *(Read-Only Context)*
- [`environment/public/code/tlul_pkg.sv`](environment/public/code/tlul_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/tlul_rsp_intg_chk.sv`](environment/public/code/tlul_rsp_intg_chk.sv) *(Read-Only Context)*
- [`environment/public/code/top_pkg.sv`](environment/public/code/top_pkg.sv) *(Read-Only Context)*
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

