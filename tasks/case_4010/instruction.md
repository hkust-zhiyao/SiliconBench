# case_4010: CV32E41P Control and Sleep Subsystem: Sticky Fetch-Enable/ELW Sleep Gating, Secure Interrupt Qualification, Nested Hardware-Loop Priority, and Area/Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cv32e41p` (`repo_04`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/cv32e41p_sleep_unit.sv`, `code/cv32e41p_int_controller.sv`, `code/cv32e41p_hwloop_regs.sv`, `code/cv32e41p_controller.sv`

---

## Problem Specification

# CV32E41P Control and Sleep Subsystem: Sticky Fetch-Enable/ELW Sleep Gating, Secure Interrupt Qualification, Nested Hardware-Loop Priority, and Area/Timing Closure

In the CV32E41P control and sleep subsystem (`code/cv32e41p_ctrl_subsystem.sv`, integrating `code/cv32e41p_sleep_unit.sv`, `code/cv32e41p_int_controller.sv`, `code/cv32e41p_hwloop_regs.sv`, and `code/cv32e41p_controller.sv` with `PULP_CLUSTER = 1`, `PULP_XPULP = 1`, `PULP_SECURE = 1`, and `N_HWLP = 2`), verification and synthesis sign-off fail in the following scenarios:

1. **Sticky fetch-enable latching, PULP cluster `p.elw` sleep gating, and debug sleep suppression (`code/cv32e41p_sleep_unit.sv`)**:
   - Once `fetch_enable_i` pulses high for one or more cycles after reset, `fetch_enable_o` must remain sticky high (`1'b1`) until reset even after `fetch_enable_i` deasserts.
   - When `PULP_CLUSTER = 1`, `p_elw_busy` must assert immediately when `p_elw_start_i` is high (taking precedence over `p_elw_finish_i` if both pulse) and clear when `p_elw_finish_i` is high; `core_busy_d` must evaluate `p_elw_busy_d ? (if_busy_i || apu_busy_i) : 1'b1`; and `core_sleep_o` must assert only when `p_elw_busy_d && !core_busy_q && !debug_p_elw_no_sleep_i`. When `PULP_CLUSTER = 0`, `clock_en` must assert when `fetch_enable_o && (wake_from_sleep_i || core_busy_q)`.
2. **Interrupt wakeup masking, U-mode secure interrupt alignment, and idle encoding (`code/cv32e41p_int_controller.sv`)**:
   - Only architectural interrupt lines permitted by `IRQ_MASK` (`[31:16]`, `11`, `7`, `3`) may assert `irq_wu_ctrl_o` (and `wake_from_sleep_o`) when enabled by `mie_bypass_i`; activity on reserved/masked-out bits (`[15:12]`, `[10:8]`, `[6:4]`, `[2:0]`) must never trigger a wakeup even if the corresponding bits in `mie_bypass_i` are high.
   - When `PULP_SECURE = 1` and `current_priv_lvl_i == PRIV_LVL_U` with `u_ie_i == 1'b0`, taking a secure interrupt (`irq_req_ctrl_o`) must be qualified by the registered security indicator (`irq_sec_ctrl_o`) aligned with the registered pending vector (`mip_o`).
   - When no locally enabled interrupt bit (`mip_o & mie_bypass_i`) is active, `irq_id_ctrl_o` must output `5'd0` while preserving the CV32E41P priority order (`31` down to `16`, then `11`, `3`, `7`) when active.
3. **Hardware-loop counter saturation, nested two-loop boundary priority, and PMP data-error fault retention (`code/cv32e41p_hwloop_regs.sv` and `code/cv32e41p_controller.sv`)**:
   - In `cv32e41p_hwloop_regs`, asserting `hwlp_dec_cnt_i[i]` with `valid_i` when loop `i`'s counter is already `32'd0` must hold the counter at `32'd0` rather than underflowing to `32'hFFFF_FFFF`.
   - In `cv32e41p_controller`, Loop 0 has higher priority than Loop 1 when both loops are active (`hwlp_counter_o > 1`):
     - In `DECODE` and `FLUSH_WB` (`csr_status_i`), when `pc_id_i` matches both `hwlp_end_addr_o[0]` and `hwlp_end_addr_o[1]` with both counters `> 1`, Loop 0 takes precedence so only `hwlp_dec_cnt_o[0]` asserts (`hwlp_dec_cnt_o == 2'b01`). In `DECODE_HWLOOP`, `hwlp_dec_cnt_o[i]` must assert at `pc_id_i == hwlp_end_addr_o[i]` only when `hwlp_counter_o[i] != 32'd0`, and `hwlp_dec_cnt_o[1]` must be suppressed whenever Loop 0 is actively looping back at the same address (`pc_id_i == hwlp_end_addr_o[0]` and `hwlp_counter_o[0] > 1`).
     - In `DECODE`, staying in `DECODE` when `pc_id_i + 4` matches a loop end address must only apply to loops with `hwlp_counter_o > 1`. In `DECODE_HWLOOP`, when `pc_id_i + 4` reaches a loop end address, `hwlp_jump_o` must pulse and `hwlp_targ_addr_o` must drive `hwlp_start_addr_o[0]` if Loop 0 triggers (`pc_id_i + 4 == hwlp_end_addr_o[0]` and `hwlp_counter_o[0] > 1`), or `hwlp_start_addr_o[1]` if Loop 0 does not trigger and Loop 1 triggers (`pc_id_i + 4 == hwlp_end_addr_o[1]` and `hwlp_counter_o[1] > 1`).
   - When `data_err_i` asserts in `DECODE`, `FLUSH_EX`, or `DBG_FLUSH`, the controller must latch `data_we_ex_i` when `data_err_ack_o` asserts, and on the subsequent `FLUSH_WB` cycle drive `exc_cause_o = EXC_CAUSE_STORE_FAULT` (for a faulted store) or `EXC_CAUSE_LOAD_FAULT` (for a faulted load) and `exc_pc_mux_o = debug_mode_o ? EXC_PC_DBE : EXC_PC_EXCEPTION`.

Under the Nangate45 synthesis and OpenROAD STA flow in `BUILD.md`, `cv32e41p_int_controller` (`PULP_SECURE = 1`) must synthesize latch-free with mapped cell area `<= 181.5 um^2`, `cv32e41p_ctrl_subsystem` (`PULP_CLUSTER = 1, PULP_XPULP = 1, PULP_SECURE = 1, N_HWLP = 2`) must synthesize latch-free with mapped cell area `<= 3,290.0 um^2`, and `cv32e41p_ctrl_subsystem` must achieve `WNS >= 0.00 ns` and `WHS >= 0.00 ns` at a `1.95 ns` clock period (`0.15 ns` I/O delays, `5.0 fF` output load, false path from `rst_n`). Edit only `code/cv32e41p_sleep_unit.sv`, `code/cv32e41p_int_controller.sv`, `code/cv32e41p_hwloop_regs.sv`, and `code/cv32e41p_controller.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build and Verification Instructions

## 1. Editable Files
Only the following four files are collected and graded:
- `code/cv32e41p_sleep_unit.sv`
- `code/cv32e41p_int_controller.sv`
- `code/cv32e41p_hwloop_regs.sv`
- `code/cv32e41p_controller.sv`

All other files in `code/` (`cv32e41p_pkg.sv`, `cv32e41p_ctrl_subsystem.sv`, `LICENSE`) and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and run your own testbench against `cv32e41p_ctrl_subsystem` (`PULP_CLUSTER = 1`, `PULP_XPULP = 1`, `PULP_SECURE = 1`, `N_HWLP = 2`) using Verilator:

```bash
verilator \
  --binary --timing -j 1 -Wno-fatal \
  --top-module <your_tb_top> \
  code/cv32e41p_pkg.sv \
  code/cv32e41p_sleep_unit.sv \
  code/cv32e41p_int_controller.sv \
  code/cv32e41p_hwloop_regs.sv \
  code/cv32e41p_controller.sv \
  code/cv32e41p_ctrl_subsystem.sv \
  <your_tb.sv>

./obj_dir/V<your_tb_top>
```

## 3. Logic Synthesis & Area Checks (`Yosys + Slang`)
1. Synthesize `cv32e41p_int_controller` (`PULP_SECURE = 1`) to Nangate45 and verify zero latches and mapped cell area `<= 181.5 um^2`:

```bash
yosys -m slang -p "
  read_slang --ignore-assertions --top cv32e41p_int_controller -G PULP_SECURE=1 \
    code/cv32e41p_pkg.sv \
    code/cv32e41p_int_controller.sv
  hierarchy -check -top cv32e41p_int_controller
  proc; opt_clean
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*
  synth -top cv32e41p_int_controller -flatten
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
"
```

2. Synthesize `cv32e41p_ctrl_subsystem` (default parameters `PULP_CLUSTER = 1, PULP_XPULP = 1, PULP_SECURE = 1, N_HWLP = 2`) to Nangate45 and verify zero latches and mapped cell area `<= 3,290.0 um^2`:

```bash
yosys -m slang -p "
  read_slang --ignore-assertions --top cv32e41p_ctrl_subsystem \
    code/cv32e41p_pkg.sv \
    code/cv32e41p_sleep_unit.sv \
    code/cv32e41p_int_controller.sv \
    code/cv32e41p_hwloop_regs.sv \
    code/cv32e41p_controller.sv \
    code/cv32e41p_ctrl_subsystem.sv
  hierarchy -check -top cv32e41p_ctrl_subsystem
  proc; opt_clean
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*
  synth -top cv32e41p_ctrl_subsystem -flatten
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

## 4. Static Timing Analysis (`OpenROAD`)
Verify setup slack (`WNS >= 0.00 ns`) and hold slack (`WHS >= 0.00 ns`) on `cv32e41p_ctrl_subsystem` at a `1.95 ns` clock period:

```bash
sed 's/ signed / /g' mapped.v > sta.v
cat > sta.tcl << 'EOF'
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design cv32e41p_ctrl_subsystem
create_clock -name clk -period 1.95 [get_ports {clk clk_ungated_i}]
set_input_delay 0.15 -clock clk [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_n]
report_checks -path_delay max -format full_clock_expanded -digits 4
report_checks -path_delay min -format full_clock_expanded -digits 4
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
EOF
openroad -exit sta.tcl
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/cv32e41p_sleep_unit.sv`
- `code/cv32e41p_int_controller.sv`
- `code/cv32e41p_hwloop_regs.sv`
- `code/cv32e41p_controller.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
