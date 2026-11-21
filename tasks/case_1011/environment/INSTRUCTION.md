# case_1011: OpenTitan SPI Host Core TX Flush, RX Buffer Refill, Standard-Mode Output Enable, and Timing/Area Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/opentitan` (`repo_01`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/spi_host_fsm.sv`, `code/spi_host_shift_register.sv`, `code/spi_host_byte_select.sv`

---

## Problem Specification

# OpenTitan SPI Host Core TX Flush, RX Buffer Refill, Standard-Mode Output Enable, and Timing/Area Closure

During integration and physical synthesis of the OpenTitan SPI Host core subsystem (`code/spi_host_core.sv`), four issues were identified across functional verification and Nangate45 synthesis/STA:

1. **TX Byte-Select Segment Flush**:
   - When a write segment finishes before consuming all enabled bytes of the current 32-bit TX word (`last_write_o` / `flush_i`), `spi_host_byte_select` does not discard the remaining bytes of that word, leaking leftover bytes into subsequent write segments.

2. **Simultaneous RX Shift-Register Refill and Downstream Pop**:
   - In `spi_host_shift_register`, when the downstream byte merger accepts a buffered RX byte (`rx_valid_o && rx_ready_i`) in the same cycle that the shift register completes and loads the next received byte (`rd_en_i && rd_ready_o`), the RX buffer valid flag clears instead of remaining asserted, dropping the newly received byte.

3. **Standard-Mode Output Enable Stretching and Software Reset Clearing**:
   - In `spi_host_fsm`, when a `Standard`-mode write segment (`speed_o == Standard`) transitions into a non-write segment or deasserts `cmd_wr_en_q` during the final bit period (`last_bit`), `sd_en_o[0]` drops half a clock cycle early instead of remaining asserted until `byte_ending`; moreover, when the FSM is idle (`is_idle`), `cmd_wr_en_last_bit` is not cleared, allowing an aborted write command to leak an active `sd_en_o[0]` into a subsequent read segment.

4. **Nangate45 Area and Setup Timing Closure**:
   - Under the Yosys+Slang Nangate45 synthesis and OpenROAD STA flow documented in `BUILD.md` (`spi_host_core`, `2.02 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load), `spi_host_core` exceeds the mapped cell area budget and violates setup timing.

## Deliverable

Update the editable RTL files (`code/spi_host_fsm.sv`, `code/spi_host_shift_register.sv`, and `code/spi_host_byte_select.sv`) to resolve the functional defects above and meet the physical implementation targets:
- Mapped cell area for `spi_host_core`: **`<= 2035.0 um^2`**
- Worst setup slack and worst hold slack at `2.02 ns` clock period: **`>= 0.0 ns`**

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/spi_host_fsm.sv`
- `code/spi_host_shift_register.sv`
- `code/spi_host_byte_select.sv`

All other files in `code/` (`spi_host_core.sv`, `spi_host_byte_merge.sv`, `spi_host_cmd_pkg.sv`, `spi_host_reg_pkg.sv`, `prim_packer_fifo.sv`, `prim_flop.sv`, `prim_flop_en.sv`, `prim_flop_macros.sv`, `prim_count_pkg.sv`, `prim_mubi_pkg.sv`, `prim_util_pkg.sv`, `top_pkg.sv`, `prim_assert.sv`, `prim_assert_*.svh`, `LICENSE`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `spi_host_core` with Verilator:

```bash
verilator --binary --timing -j 1 -Werror-LATCH -Wno-fatal -Icode -DSYNTHESIS \
  --top-module tb \
  code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv code/prim_packer_fifo.sv \
  code/spi_host_reg_pkg.sv code/spi_host_cmd_pkg.sv code/spi_host_byte_select.sv \
  code/spi_host_byte_merge.sv code/spi_host_shift_register.sv code/spi_host_fsm.sv \
  code/spi_host_core.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `spi_host_core`:

```bash
yosys -m slang -Q -T -p "
  read_slang --single-unit --ignore-assertions --top spi_host_core -Icode -DSYNTHESIS \
    code/top_pkg.sv code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/prim_flop_macros.sv code/prim_flop.sv code/prim_flop_en.sv code/prim_packer_fifo.sv \
    code/spi_host_reg_pkg.sv code/spi_host_cmd_pkg.sv code/spi_host_byte_select.sv \
    code/spi_host_byte_merge.sv code/spi_host_shift_register.sv code/spi_host_fsm.sv \
    code/spi_host_core.sv;
  hierarchy -check -top spi_host_core;
  synth -top spi_host_core;
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

Target mapped cell area (`Chip area for module '\spi_host_core'`): **`<= 2035.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.02 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design spi_host_core
create_clock -name clk_i -period 2.02 [get_ports clk_i]
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
- `code/spi_host_fsm.sv`
- `code/spi_host_shift_register.sv`
- `code/spi_host_byte_select.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
