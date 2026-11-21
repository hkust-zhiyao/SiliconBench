# case_1015: OpenTitan OTBN Two-Round Secure Wipe, Loop-End Commit Hazard, Full-Stack Push/Pop Replacement, and Timing/Area Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/opentitan` (`repo_01`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/otbn_start_stop_control.sv`, `code/otbn_loop_controller.sv`, `code/otbn_stack.sv`

---

## Problem Specification

# OpenTitan OTBN Two-Round Secure Wipe, Loop-End Commit Hazard, Full-Stack Push/Pop Replacement, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan OTBN Start/Stop, Loop Stack, and Call Stack Subsystem (`code/ot_otbn_ctrl_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **Start/Stop Two-Round Secure Wipe Sequencing and RMA Acknowledgement**:
   - In `otbn_start_stop_control`, when `OtbnStartStopSecureWipeAllZero` is reached with `mubi4_test_false_strict(wipe_after_urnd_refresh_q)` (first round of random wiping), the FSM transitions directly to `OtbnStartStopSecureWipeComplete` instead of setting `wipe_after_urnd_refresh_d = MuBi4True`, keeping `secure_wipe_running_d = 1'b1`, and transitioning to `OtbnStartStopStateUrndRefresh` for the second wipe round. In addition, in `OtbnStartStopSecureWipeComplete`, `rma_ack_d` fails to latch `rma_req_i`.

2. **Loop Controller At-End Loop Start Error and Commit Priority**:
   - In `otbn_loop_controller`, `loop_at_end_err` is tied low instead of detecting `at_current_loop_end_insn & loop_start_req_i`, and `loop_stack_commit` is driven by `loop_start_commit_i | loop_stack_pop` instead of giving `loop_stack_push_req` priority (`loop_stack_push_req ? loop_start_commit_i : loop_stack_pop`), causing an aborted loop-start request at the end of a finishing loop (`loop_start_commit_i == 0`) to still commit a pop/write on the loop stack.

3. **Full-Stack Combined Push and Pop Replacement**:
   - In `otbn_stack`, `stack_write` is gated by `~full_o` instead of `(~full_o | pop_i)` and `stack_wr_idx` does not select `stack_rd_idx` when `pop_i` is high, dropping the pushed element instead of replacing the top element when a combined push and pop occurs on a full or non-empty stack.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_otbn_ctrl_top`, `2.20 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_otbn_ctrl_top` exceeds the mapped cell area budget and violates setup timing across the loop/call stack read-compare-pop datapath.

## Deliverable

Update the editable RTL files (`code/otbn_start_stop_control.sv`, `code/otbn_loop_controller.sv`, and `code/otbn_stack.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_otbn_ctrl_top`: **`<= 8550.0 um^2`**
- Worst setup slack and worst hold slack at `2.20 ns` clock period: **`>= 0.0 ns`**

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/otbn_start_stop_control.sv`
- `code/otbn_loop_controller.sv`
- `code/otbn_stack.sv`

All other files in `code/` (`ot_otbn_ctrl_top.sv`, `otbn_pkg.sv`, `otbn_reg_pkg.sv`, `otp_ctrl_pkg.sv`, `keymgr_dpe_pkg.sv`, `keymgr_dpe_reg_pkg.sv`, `edn_pkg.sv`, `csrng_pkg.sv`, `csrng_reg_pkg.sv`, `entropy_src_pkg.sv`, `kmac_pkg.sv`, `kmac_reg_pkg.sv`, `sha3_pkg.sv`, `lc_ctrl_pkg.sv`, `lc_ctrl_reg_pkg.sv`, `lc_ctrl_state_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_otbn_ctrl_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_trivium_pkg.sv \
  code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv code/lc_ctrl_pkg.sv \
  code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
  code/entropy_src_pkg.sv code/csrng_reg_pkg.sv code/csrng_pkg.sv \
  code/edn_pkg.sv code/keymgr_dpe_reg_pkg.sv code/keymgr_dpe_pkg.sv \
  code/otp_ctrl_pkg.sv code/otbn_reg_pkg.sv code/otbn_pkg.sv \
  code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv \
  code/prim_buf.sv code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
  code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
  code/otbn_stack.sv code/otbn_loop_controller.sv \
  code/otbn_start_stop_control.sv code/ot_otbn_ctrl_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_otbn_ctrl_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_otbn_ctrl_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/prim_secded_pkg.sv code/prim_trivium_pkg.sv \
    code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv code/lc_ctrl_pkg.sv \
    code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
    code/entropy_src_pkg.sv code/csrng_reg_pkg.sv code/csrng_pkg.sv \
    code/edn_pkg.sv code/keymgr_dpe_reg_pkg.sv code/keymgr_dpe_pkg.sv \
    code/otp_ctrl_pkg.sv code/otbn_reg_pkg.sv code/otbn_pkg.sv \
    code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv \
    code/prim_buf.sv code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
    code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/prim_secded_inv_39_32_enc.sv code/prim_secded_inv_39_32_dec.sv \
    code/otbn_stack.sv code/otbn_loop_controller.sv \
    code/otbn_start_stop_control.sv code/ot_otbn_ctrl_top.sv;
  hierarchy -check -top ot_otbn_ctrl_top;
  synth -top ot_otbn_ctrl_top;
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

Target mapped cell area (`Chip area for module '\ot_otbn_ctrl_top'`): **`<= 8550.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.20 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_otbn_ctrl_top
create_clock -name clk_i -period 2.20 [get_ports clk_i]
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

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/otbn_start_stop_control.sv`
- `code/otbn_loop_controller.sv`
- `code/otbn_stack.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
