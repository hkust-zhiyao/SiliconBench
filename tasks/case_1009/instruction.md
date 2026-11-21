# case_1009: OpenTitan HMAC Core and SHA-256 Padding Backpressure, Abort Recovery, and Timing/Area Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/opentitan` (`repo_01`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/hmac_core.sv`, `code/prim_sha2_pad.sv`

---

## Problem Specification

# OpenTitan HMAC Core and SHA-256 Padding Backpressure, Abort Recovery, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan HMAC and SHA-256 padding subsystem (`code/ot_hmac_pad_top.sv`), three issues were identified across functional simulation and Nangate45 synthesis/STA:

1. **HMAC Intermediate Digest Push Backpressure and Abort Recovery**:
   - When the inner SHA-256 pass completes in HMAC mode (`hmac_en_i = 1'b1`) and the controller pushes the 8-word intermediate digest back into the message FIFO (`fifo_wsel_o = 1'b1`, `fifo_wvalid_o = 1'b1`), `fifo_wdata_sel_o` advances even on cycles where the downstream FIFO stalls (`fifo_wready_i = 1'b0`), skipping digest words under backpressure.
   - When an in-flight operation is aborted (`abort_i = 1'b1`) after `reg_hash_process_i` has been pulsed, the latched process request is not cleared, causing a subsequent operation to prematurely transition to response waiting and padding before software issues a new process command.

2. **SHA-256 Padding Bit-Count and Last-Block Boundary**:
   - During message ingestion prior to `hash_process_i`, the padding bit counter advances whenever the downstream compression interface is ready (`shaf_rready_i = 1'b1`) even when the upstream message stream is not valid (`fifo_rvalid_i = 1'b0`), corrupting the accumulated message bit count under source stalls.
   - When the 1-bit (`0x80`) padding byte lands at the exact 512-bit block boundary preceding the 64-bit length field (`416` bits into the 512-bit block, i.e., `52` message bytes modulo `64`), the padding FSM fails to transition directly to emitting the 64-bit length words (`LenHi` / `LenLo`), producing an extra zero-padded block.

3. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`ot_hmac_pad_top`, `2.75 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), the subsystem exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/hmac_core.sv` and `code/prim_sha2_pad.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `ot_hmac_pad_top`: **`<= 4150.0 um^2`**
- Worst setup slack and worst hold slack at `2.75 ns` clock period: **`>= 0.0 ns`**

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/hmac_core.sv`
- `code/prim_sha2_pad.sv`

All other files in `code/` (`ot_hmac_pad_top.sv`, `prim_sha2_pkg.sv`, `prim_assert.sv`, `prim_flop_macros.sv`, `prim_assert_*.svh`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `ot_hmac_pad_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/prim_sha2_pkg.sv code/prim_sha2_pad.sv code/hmac_core.sv \
  code/ot_hmac_pad_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `ot_hmac_pad_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --ignore-assertions --top ot_hmac_pad_top -Icode -DSYNTHESIS \
    code/prim_sha2_pkg.sv code/prim_sha2_pad.sv code/hmac_core.sv code/ot_hmac_pad_top.sv;
  hierarchy -check -top ot_hmac_pad_top;
  synth -top ot_hmac_pad_top;
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

Target mapped cell area (`Chip area for module '\ot_hmac_pad_top'`): **`<= 4150.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.75 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design ot_hmac_pad_top
create_clock -name clk_i -period 2.75 [get_ports clk_i]
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
- `code/hmac_core.sv`
- `code/prim_sha2_pad.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
