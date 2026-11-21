# case_1003: OpenTitan KMAC Message Packer, FIFO Flush Control, and Error Checker Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/opentitan` (`repo_01`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, `code/kmac_errchk.sv`

---

## Problem Specification

# OpenTitan KMAC Message Packer, FIFO Flush Control, and Error Checker Closure

In `code/kmac_msg_err_top.sv`, update `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, and `code/kmac_errchk.sv` to resolve coupled byte-packing, flush-gating, and command-blocking defects. In `prim_packer` and `kmac_msgfifo`, pack byte-granular input beats (`fifo_data_i`, `fifo_strb_i`) into `msg_data_o` and `msg_strb_o` across arbitrary leading byte offsets and simultaneous input/output handshakes while suppressing `fifo_ready_o` (when `fifo_bypass_i == 0`) and `ready_o` throughout the entire flush sequence—from the cycle `flush_i` asserts until the flush completes and is cleared by `clear_i` (`CmdDone` or `clear_after_error_i`)—and returning immediately to the idle ready state whenever `clear_i` is `MuBi4True` in any flush state; in bypass mode (`fifo_bypass_i == 1`), forward `flush_i` directly to `flush_done_o`. In `kmac_errchk`, validate mode/strength, `EncodedStringKMAC` prefix (`cfg_prefix_6B_i` when `kmac_en_i == 1`), sideload context-switch restrictions (`cfg_sideload_i`), and command sequences, and drive `sw_cmd_o <= CmdNone` on the next rising `clk_i` edge whenever `sw_cmd_i` is blocked by an error, rejected in idle or state-write because `app_active_i` is high, or preempted by `lc_escalate_en_i` (which enters a sticky terminal error state that ignores `clear_after_error_i`).

Under the Nangate45 Yosys/Slang synthesis flow (`BUILD.md`), `kmac_msg_err_top` must map to `<= 2,260.0 um^2`, and OpenROAD STA must achieve setup and hold slack `>= 0.0 ns` at a `1.50 ns` `clk_i` period (`0.20 ns` data input delay, `0.50 ns` `rst_ni` input delay, `0.35 ns` output delay, `5.0 fF` load). Edit only `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, and `code/kmac_errchk.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/prim_packer.sv`: OpenTitan byte-aligned stream packer (**editable target**).
- `code/kmac_msgfifo.sv`: OpenTitan KMAC message packer and FIFO controller (**editable target**).
- `code/kmac_errchk.sv`: OpenTitan KMAC software command and configuration checker (**editable target**).
- `code/kmac_msg_err_top.sv`: Top-level KMAC message and command front-end wrapper (read-only).
- `code/prim_*.sv`, `code/prim_*.svh`, `code/*_pkg.sv`: Upstream OpenTitan packages and primitives (read-only).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.

Edit only `code/prim_packer.sv`, `code/kmac_msgfifo.sv`, and `code/kmac_errchk.sv`.

## 2. Functional Simulation (Verilator)

```bash
verilator --binary --timing -j 1 -Wno-fatal -DSYNTHESIS -Icode --top-module tb \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/lc_ctrl_reg_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_pkg.sv \
  code/sha3_pkg.sv code/kmac_pkg.sv code/prim_flop.sv \
  code/prim_sparse_fsm_flop.sv code/prim_count.sv \
  code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
  code/prim_packer.sv code/kmac_msgfifo.sv code/kmac_errchk.sv \
  code/kmac_msg_err_top.sv tb.sv
./obj_dir/Vtb
```

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top kmac_msg_err_top -DSYNTHESIS -I code \
    code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/lc_ctrl_reg_pkg.sv code/lc_ctrl_state_pkg.sv code/lc_ctrl_pkg.sv \
    code/sha3_pkg.sv code/kmac_pkg.sv code/prim_flop.sv \
    code/prim_sparse_fsm_flop.sv code/prim_count.sv \
    code/prim_fifo_sync_cnt.sv code/prim_fifo_sync.sv \
    code/prim_packer.sv code/kmac_msgfifo.sv code/kmac_errchk.sv \
    code/kmac_msg_err_top.sv
  hierarchy -check -top kmac_msg_err_top
  synth -top kmac_msg_err_top
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```

The reported `Chip area for module '\kmac_msg_err_top':` must be `<= 2260.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD (`openroad -exit flow.tcl`) with:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design kmac_msg_err_top
initialize_floorplan -die_area {0 0 120 120} -core_area {10 10 110 110} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 1.50 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_input_delay 0.50 -clock clk_i [get_ports rst_ni]
set_output_delay 0.35 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
```

Both the worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`) must be `>= 0.0` (`ns`), with an empty `check_setup -verbose` audit block.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/prim_packer.sv`
- `code/kmac_msgfifo.sv`
- `code/kmac_errchk.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
