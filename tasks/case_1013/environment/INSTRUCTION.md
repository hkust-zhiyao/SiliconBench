# case_1013: OpenTitan ROM Controller KMAC Error Handling, Comparator/Mux Alert Hardening, and Timing/Area Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/opentitan` (`repo_01`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/rom_ctrl_fsm.sv`, `code/rom_ctrl_compare.sv`, `code/rom_ctrl_mux.sv`

---

## Problem Specification

# OpenTitan ROM Controller KMAC Error Handling, Comparator/Mux Alert Hardening, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan ROM Controller subsystem (`code/ot_rom_ctrl_top.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **KMAC Error Handling During `ReadingHigh` State**:
   - In `rom_ctrl_fsm`, when `kmac_done_i` asserts while `state_q == ReadingHigh` (whether `counter_done` is `1'b0` or `1'b1`), `kmac_err_i` is not checked, allowing the FSM to advance to `KmacAhead` or `Checking` instead of transitioning to `Invalid` and raising `alert_o`.

2. **Comparator Re-Start Alert Detection**:
   - In `rom_ctrl_compare`, `start_alert` is tied low instead of asserting when `start_i` is high while the comparator FSM is not in `Waiting`, suppressing `alert_o` on spurious re-start pulses during `Checking` or `Done`.

3. **ROM Multiplexer Bus-Selection Revert Alert Detection**:
   - In `rom_ctrl_mux`, `sel_reverted` is tied low instead of detecting when `sel_bus_q` is true (loose MuBi4 check) while `sel_bus_i` reverts to false (loose MuBi4 check), failing to latch `alert_o` when the bus selection signal reverts after switching to the system bus.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_rom_ctrl_top`, `1.05 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `ot_rom_ctrl_top` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/rom_ctrl_fsm.sv`, `code/rom_ctrl_compare.sv`, and `code/rom_ctrl_mux.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_rom_ctrl_top`: **`<= 1020.0 um^2`**
- Worst setup slack and worst hold slack at `1.05 ns` clock period: **`>= 0.0 ns`**

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/rom_ctrl_fsm.sv`
- `code/rom_ctrl_compare.sv`
- `code/rom_ctrl_mux.sv`

All other files in `code/` (`ot_rom_ctrl_top.sv`, `rom_ctrl_counter.sv`, `rom_ctrl_pkg.sv`, `rom_ctrl_reg_pkg.sv`, `kmac_pkg.sv`, `kmac_reg_pkg.sv`, `sha3_pkg.sv`, `lc_ctrl_pkg.sv`, `lc_ctrl_reg_pkg.sv`, `lc_ctrl_state_pkg.sv`, `prim_*.sv`, `prim_*.svh`, `top_pkg.sv`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_rom_ctrl_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
  code/prim_count_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv \
  code/lc_ctrl_pkg.sv code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
  code/rom_ctrl_reg_pkg.sv code/rom_ctrl_pkg.sv code/prim_flop_macros.sv \
  code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
  code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
  code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/rom_ctrl_counter.sv code/rom_ctrl_compare.sv code/rom_ctrl_fsm.sv \
  code/rom_ctrl_mux.sv code/ot_rom_ctrl_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_rom_ctrl_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top ot_rom_ctrl_top -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv \
    code/prim_count_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_reg_pkg.sv \
    code/lc_ctrl_pkg.sv code/sha3_pkg.sv code/kmac_reg_pkg.sv code/kmac_pkg.sv \
    code/rom_ctrl_reg_pkg.sv code/rom_ctrl_pkg.sv code/prim_flop_macros.sv \
    code/prim_flop.sv code/prim_flop_en.sv code/prim_buf.sv \
    code/prim_sec_anchor_buf.sv code/prim_sec_anchor_flop.sv \
    code/prim_mubi4_sender.sv code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/rom_ctrl_counter.sv code/rom_ctrl_compare.sv code/rom_ctrl_fsm.sv \
    code/rom_ctrl_mux.sv code/ot_rom_ctrl_top.sv;
  hierarchy -check -top ot_rom_ctrl_top;
  synth -top ot_rom_ctrl_top;
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

Target mapped cell area (`Chip area for module '\ot_rom_ctrl_top'`): **`<= 1020.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `1.05 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_rom_ctrl_top
create_clock -name clk_i -period 1.05 [get_ports clk_i]
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
- `code/rom_ctrl_fsm.sv`
- `code/rom_ctrl_compare.sv`
- `code/rom_ctrl_mux.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
