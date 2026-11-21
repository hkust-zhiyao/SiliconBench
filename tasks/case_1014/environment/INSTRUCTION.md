# case_1014: OpenTitan Entropy Complex GEN Abort Uninstantiation, Boot-Mode Uninstantiate Sequence, Endpoint Ack Immediate Pop, and Timing/Area Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/opentitan` (`repo_01`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/csrng_cmd_stage.sv`, `code/edn_main_sm.sv`, `code/edn_ack_sm.sv`

---

## Problem Specification

# OpenTitan Entropy Complex GEN Abort Uninstantiation, Boot-Mode Uninstantiate Sequence, Endpoint Ack Immediate Pop, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan Entropy Complex Command & Endpoint Subsystem (`code/ot_entropy_cmd_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **CSRNG Command Stage GEN Abort Uninstantiation and Genbits FIFO Flush**:
   - In `csrng_cmd_stage`, when an in-flight `GEN` abort completes (`state_q == CmdAck && cmd_ack_i && gen_abort_inflight_q`), `instantiated_d` is not cleared to `1'b0` and `sfifo_genbits_clr` does not include `cmd_gen_abort_ack`, leaving `instantiated_q` set (rejecting a subsequent `INS` command as `CMD_STS_INVALID_CMD_SEQ`) and leaving stale `genbits` in the output buffer.

2. **EDN Main State Machine Boot-Mode Uninstantiate Sequence and Disable Done Pulse**:
   - In `edn_main_sm`, when `boot_req_mode_i` deasserts in `BootDone`, the FSM transitions directly to `Idle` instead of `BootLoadUni` (skipping the boot-mode `UNI` command and its `BootUniAckWait` completion), and when `edn_enable_i` deasserts in an active legal state, `main_sm_done_pulse_o` is not pulsed high.

3. **EDN Endpoint Ack State Machine Immediate FIFO Pop on Ready Data**:
   - In `edn_ack_sm`, when `req_i` asserts in `Idle` while `fifo_not_empty_i` is already high, `fifo_pop_o` is not asserted, failing to pop the consumed word from the genbits FIFO.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_entropy_cmd_top`, `1.15 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_entropy_cmd_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/csrng_cmd_stage.sv`, `code/edn_main_sm.sv`, and `code/edn_ack_sm.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_entropy_cmd_top`: **`<= 2320.0 um^2`**
- Worst setup slack and worst hold slack at `1.15 ns` clock period: **`>= 0.0 ns`**

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/csrng_cmd_stage.sv`
- `code/edn_main_sm.sv`
- `code/edn_ack_sm.sv`

All other files in `code/` (`ot_entropy_cmd_top.sv`, `csrng_main_sm.sv`, `csrng_pkg.sv`, `csrng_reg_pkg.sv`, `edn_pkg.sv`, `entropy_src_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_entropy_cmd_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/entropy_src_pkg.sv code/csrng_reg_pkg.sv \
  code/csrng_pkg.sv code/edn_pkg.sv code/prim_flop_macros.sv \
  code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
  code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
  code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/csrng_cmd_stage.sv code/csrng_main_sm.sv \
  code/edn_main_sm.sv code/edn_ack_sm.sv code/ot_entropy_cmd_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_entropy_cmd_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_entropy_cmd_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/entropy_src_pkg.sv code/csrng_reg_pkg.sv \
    code/csrng_pkg.sv code/edn_pkg.sv code/prim_flop_macros.sv \
    code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
    code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
    code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
    code/csrng_cmd_stage.sv code/csrng_main_sm.sv \
    code/edn_main_sm.sv code/edn_ack_sm.sv code/ot_entropy_cmd_top.sv;
  hierarchy -check -top ot_entropy_cmd_top;
  synth -top ot_entropy_cmd_top;
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

Target mapped cell area (`Chip area for module '\ot_entropy_cmd_top'`): **`<= 2320.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `1.15 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_entropy_cmd_top
create_clock -name clk_i -period 1.15 [get_ports clk_i]
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
- `code/csrng_cmd_stage.sv`
- `code/edn_main_sm.sv`
- `code/edn_ack_sm.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
