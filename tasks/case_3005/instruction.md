# case_3005: CV32E40P Hardware-Loop Register File Nested-Loop End-PC Resolution, APU Dispatcher Flush Drain, and Transparent Channel Timing Budgets

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cv32e40p` (`repo_03`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Task-Specific Multi-Corner Liberty & SDC Timing Views`
> - **Editable Files (`allowed_edits`)**: `code/cv32e40p_hwloop_regs.sv`, `code/cv32e40p_apu_disp.sv`, `constraints.json`

---

## Problem Specification

# CV32E40P Hardware-Loop Register File Nested-Loop End-PC Resolution, APU Dispatcher Flush Drain, and Transparent Channel Timing Budgets

In `code/cv32e40p_hwloop_regs.sv`, `code/cv32e40p_apu_disp.sv`, and `constraints.json` (integrated in `code/top.sv`), hardware-loop setup/decrement semantics on compressed and nested loops, APU dispatcher in-flight flush draining and latency tracking, and transparent control channel timing budgets fail verification:

1. **Hardware-Loop Register File Qualification, Halfword Alignment, and Nested End-PC Decrement (`code/cv32e40p_hwloop_regs.sv`):**
   - Setup writes (`hwlp_we_i[0]` for start address, `hwlp_we_i[1]` for end address, and `hwlp_we_i[2]` for counter) must only update `hwlp_start_addr_o`, `hwlp_end_addr_o`, and `hwlp_counter_o` when `valid_i` is high, and start/end loop bounds must preserve halfword alignment (`[31:1]` with bit 0 cleared to `1'b0`) so 16-bit compressed instructions can serve as loop start or end targets.
   - When `valid_i` is high and a loop counter is not being overwritten by `hwlp_we_i[2]`, asserting `hwlp_dec_cnt_i[i]` on a counter that is already `32'd0` must saturate at `32'd0` instead of underflowing to `32'hFFFF_FFFF`.
   - When inner loop `0` and outer loop `1` share the same end address (`hwlp_dec_cnt_i == 2'b11` with `valid_i == 1'b1`): if inner loop `0` has remaining iterations after the current pass (`hwlp_counter_o[0] > 32'd1` and loop `0` is not being written by `hwlp_we_i[2]`), only loop `0` decrements while outer loop `1` holds its counter; if inner loop `0` is on its final pass (`hwlp_counter_o[0] <= 32'd1`), both loop `0` and outer loop `1` decrement (saturating at zero).

2. **APU Dispatcher Latency Preservation and Post-Flush In-Flight Drain (`code/cv32e40p_apu_disp.sv`):**
   - The stored latency class driving `apu_multicycle_o` must not be overwritten by an ungranted request (`enable_i` when `apu_gnt_i` is low) while an older operation is still active (`active_o == 1'b1`).
   - Asserting `flush_i` must immediately suppress new APU requests (`apu_req_o = 1'b0`) and writeback valid pulses (`apu_rvalid_wb_o = 1'b0`) in that cycle, and mark any already-accepted in-flight APU operations as flushed so their subsequent `apu_rvalid_i` responses drain from the two-slot tracking pipeline without asserting `apu_rvalid_wb_o` or reporting register dependencies (`read_dep_o`, `read_dep_for_jalr_o`, `write_dep_o`), while keeping `active_o` and slot-full/latency-order stall protection active until those stale responses return. New requests accepted after `flush_i` deasserts must retire normally even if an older flushed slot is still draining ahead of them.

3. **Transparent Channel Timing Budgets (`constraints.json`):**
   - In `code/top.sv`, the subsystem operates at `8 ns` and `10 ns` clock periods (`clk_i`), with a `3.25 ns` external input delay on all non-clock inputs and a `2.75 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`fpu_rm_in` to `fpu_rm_out` and `hart_ctrl_in` to `hart_ctrl_out`). Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.10 ns` for `fpu_rm_in` to `fpu_rm_out` and `1.85 ns` for `hart_ctrl_in` to `hart_ctrl_out`, while preserving the existing sequential timing requirements on all registered hardware-loop and APU dispatcher ports. Edit only `code/cv32e40p_hwloop_regs.sv`, `code/cv32e40p_apu_disp.sv`, and `constraints.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build and Verification Guide

## Editable Files
- `code/cv32e40p_hwloop_regs.sv`
- `code/cv32e40p_apu_disp.sv`
- `constraints.json`

Do not modify `code/top.sv`, `code/LICENSE`, or any file in `lib/` (`lib/NangateOpenCellLibrary_typical.lib`, `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, `lib/LICENSE.Nangate45`).

## Simulation & Synthesis Toolchain
- **Verilator (`verilator-v5.038`)**:
  ```bash
  verilator --binary --timing -Wno-fatal --top-module top \
    code/cv32e40p_hwloop_regs.sv code/cv32e40p_apu_disp.sv code/top.sv
  ```
- **Yosys + Slang (`oss-cad-suite/bin/yosys`)**:
  ```bash
  yosys -m slang -Q -p "read_slang --top top code/cv32e40p_hwloop_regs.sv code/cv32e40p_apu_disp.sv code/top.sv; hierarchy -check -top top; proc; opt_clean; select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*; synth -top top; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; check -assert; write_verilog -noattr /tmp/mapped.v"
  ```

## Declarative Timing Exceptions (`constraints.json`)
`constraints.json` must contain a single top-level key `"max_delays"` mapping to a list of rule objects:
```json
{
  "max_delays": [
    {
      "from": ["<input_port_or_bit>", ...],
      "to": ["<output_port_or_bit>", ...],
      "ns": <positive_float>
    }
  ]
}
```
Each rule is translated by the evaluation harness into:
```tcl
set_max_delay <ns> -from [get_ports {<from>}] -to [get_ports {<to>}]
```
after applying:
```tcl
create_clock -period <8_or_10> [get_ports clk_i]
set_input_delay 3.25 -clock clk_i [get_ports {<all_non_clock_inputs>}]
set_output_delay 2.75 -clock clk_i [get_ports {<all_outputs>}]
```
with `lib/NangateOpenCellLibrary.tech.lef`, `lib/NangateOpenCellLibrary.macro.mod.lef`, and `lib/NangateOpenCellLibrary_typical.lib` in OpenROAD (`openroad -exit`).

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/cv32e40p_hwloop_regs.sv`
- `code/cv32e40p_apu_disp.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
