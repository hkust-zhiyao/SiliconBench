# case_3011: CV32E40P Interrupt Controller Qualification, Dual-Mode Sleep Unit Clock Gating, and Transparent Channel Timing Budgets

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cv32e40p` (`repo_03`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library (Shared Base Image)`
> - **Editable Files (`allowed_edits`)**: `code/cv32e40p_int_controller.sv`, `code/cv32e40p_sleep_unit.sv`, `constraints.json`

---

## Problem Specification

# CV32E40P Interrupt Controller Qualification, Dual-Mode Sleep Unit Clock Gating, and Transparent Channel Timing Budgets

In `code/cv32e40p_int_controller.sv`, `code/cv32e40p_sleep_unit.sv`, and `constraints.json` (integrated in `code/top.sv`), interrupt wake-up/security qualification, runtime cluster vs. WFI sleep/clock-gate transitions, and transparent control channel timing budgets fail verification:

1. **Interrupt Controller Wake-Up Masking, Registered Security Qualification, and Idle ID (`code/cv32e40p_int_controller.sv`):**
   - Mask external interrupt wake-up qualification with `IRQ_MASK` so reserved interrupt bits outside `IRQ_MASK` never assert `irq_wu_ctrl_o`.
   - When `PULP_SECURE = 1` and `current_priv_lvl_i == PRIV_LVL_U`, qualify `irq_req_ctrl_o` using the registered security level (`irq_sec_ctrl_o` / registered `irq_sec_i`) aligned with the registered interrupt lines in `mip_o` rather than unregistered `irq_sec_i`.
   - When no locally enabled interrupt is active (`(mip_o & mie_bypass_i) == 32'h0`), drive `irq_id_ctrl_o = 5'd0` instead of `CSR_MTIX_BIT`.

2. **Runtime Dual-Mode Sleep Unit (`cluster_mode_i`) and `p.elw` / WFI Clock Gating (`code/cv32e40p_sleep_unit.sv`):**
   - Select between PULP cluster sleep mode (`cluster_mode_i == 1'b1`) and standard WFI sleep mode (`cluster_mode_i == 1'b0`) dynamically at runtime via `cluster_mode_i` (regardless of the `COREV_CLUSTER` parameter default).
   - In cluster mode (`cluster_mode_i == 1'b1`), track an active `p.elw` transaction: `p_elw_finish_i`, `debug_p_elw_no_sleep_i`, or `cluster_mode_i == 1'b0` must clear any active `p.elw` sleep state (with `p_elw_finish_i` and `debug_p_elw_no_sleep_i` taking priority over `p_elw_start_i` if asserted in the same cycle). While a `p.elw` transaction is active, any busy unit (`if_busy_i`, `lsu_busy_i`, or `apu_busy_i`) keeps the registered core busy state active for the following cycle; when no `p.elw` transaction is active in cluster mode, the registered core busy state remains `1'b1`. Enable `clk_gated_o` whenever `fetch_enable_o` is high and any of `pulp_clock_en_i`, `wake_from_sleep_i`, `debug_p_elw_no_sleep_i`, or the registered core busy state is high; assert `core_sleep_o` only when `fetch_enable_o` is high, the `p.elw` transaction state is active, the registered core busy state is low, `debug_p_elw_no_sleep_i` is low, and `wake_from_sleep_i` is low.
   - In standard WFI mode (`cluster_mode_i == 1'b0`), the registered core busy state reflects `if_busy_i || ctrl_busy_i || lsu_busy_i || apu_busy_i`; enable `clk_gated_o` when `fetch_enable_o` is high and any of `wake_from_sleep_i`, `debug_p_elw_no_sleep_i`, or the registered core busy state is high; and assert `core_sleep_o` when `fetch_enable_o` is high and the gated clock enable is low.

3. **Transparent Channel Timing Budgets (`constraints.json`):**
   - In `code/top.sv`, the subsystem operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `3.50 ns` external input delay on all non-clock inputs and a `2.75 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit channels (`clint_timer_in` to `clint_timer_out` and `eu_event_in` to `eu_event_out`). Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.25 ns` for `clint_timer_in` to `clint_timer_out` and `2.00 ns` for `eu_event_in` to `eu_event_out`, while preserving the existing sequential timing requirements on all registered interrupt controller and sleep unit ports. Edit only `code/cv32e40p_int_controller.sv`, `code/cv32e40p_sleep_unit.sv`, and `constraints.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build and Verification Guide

## Editable Files
- `code/cv32e40p_int_controller.sv`
- `code/cv32e40p_sleep_unit.sv`
- `constraints.json`

Do not modify `code/top.sv`, `code/cv32e40p_sim_clock_gate.sv`, `code/include/cv32e40p_pkg.sv`, or `code/LICENSE`.

## Simulation & Synthesis Toolchain
- **Verilator (`verilator-v5.038`)**:
  ```bash
  verilator --binary --timing -Wno-fatal --top-module top \
    code/include/cv32e40p_pkg.sv code/cv32e40p_sim_clock_gate.sv \
    code/cv32e40p_int_controller.sv code/cv32e40p_sleep_unit.sv code/top.sv
  ```
- **Yosys + Slang (`oss-cad-suite/bin/yosys`)**:
  ```bash
  yosys -m slang -Q -p "read_slang --top top --keep-hierarchy code/include/cv32e40p_pkg.sv code/cv32e40p_sim_clock_gate.sv code/cv32e40p_int_controller.sv code/cv32e40p_sleep_unit.sv code/top.sv; hierarchy -check -top top; proc; opt_clean; select -assert-none cv32e40p_int_controller*/t:\$dlatch* cv32e40p_int_controller*/t:\$adlatch* cv32e40p_int_controller*/t:\$latch* cv32e40p_int_controller*/t:\$sr* cv32e40p_sleep_unit*/t:\$dlatch* cv32e40p_sleep_unit*/t:\$adlatch* cv32e40p_sleep_unit*/t:\$latch* cv32e40p_sleep_unit*/t:\$sr*; synth -top top; read_liberty -lib /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; dfflibmap -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; abc -liberty /opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib; clean; check -assert; write_verilog -noattr mapped.v"
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
create_clock -period <10_or_12> [get_ports clk_i]
set_input_delay 3.50 -clock clk_i [get_ports {<all_non_clock_inputs>}]
set_output_delay 2.75 -clock clk_i [get_ports {<all_outputs>}]
```
in OpenROAD (`openroad -exit`).

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/cv32e40p_int_controller.sv`
- `code/cv32e40p_sleep_unit.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
