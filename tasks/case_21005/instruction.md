# case_21005: TSN/TDMA Transmit Scheduler Boundary Precision, Pipeline Hazard Control & Nangate45 Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `corundum/corundum` (`repo_39`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/tdma_scheduler.v`, `code/tx_scheduler_ctrl_tdma.v`, `code/tx_scheduler_rr.v`

---

## Problem Specification

# TSN/TDMA Transmit Scheduler Boundary Precision, Pipeline Hazard Control & Nangate45 Timing Closure

`tdma_scheduler` (`code/tdma_scheduler.v`), `tx_scheduler_ctrl_tdma` (`code/tx_scheduler_ctrl_tdma.v`), and `tx_scheduler_rr` (`code/tx_scheduler_rr.v`) form the time-triggered TSN/TDMA transmit scheduling chain: `tdma_scheduler` tracks 96-bit PTP time (`input_ts_96[95:48]` seconds, `input_ts_96[45:16]` nanoseconds) to emit timeslot boundaries, `tx_scheduler_ctrl_tdma` scans per-queue timeslot bitmasks to issue `m_axis_sched_ctrl_*` gate updates, and `tx_scheduler_rr` arbitrates active/enabled queues onto `m_axis_tx_req_*`.

Update `code/tdma_scheduler.v`, `code/tx_scheduler_ctrl_tdma.v`, and `code/tx_scheduler_rr.v` while preserving all top-level module names, parameters, and port interfaces:

1. **PTP Boundary Precision & `tdma_scheduler` Nangate45 `2.00` ns Timing Closure**:
   - Trigger schedule period start, timeslot start, and active-period end in `tdma_scheduler` using inclusive timestamp comparisons (`current_time >= target_time` across `(seconds, nanoseconds)`, with decimal `1_000_000_000` ns rollover) rather than firing late only after strictly exceeding target timestamps, while bounding `timeslot_start` / `timeslot_end` assertion latency to at most `3` `clk` cycles from `input_ts_96` reaching the boundary in `STATE_WAIT`.
   - Retime/refactor the wide 48-bit second + 31-bit nanosecond comparator/adder paths in `tdma_scheduler` (`INDEX_WIDTH = 8`) so Nangate45 OpenSTA closes at **`clk = 2.00` ns** (`0.10` ns input/output delay on all non-clock, non-reset ports; `set_false_path -from [get_ports rst]`) with **`WNS >= 0.00` ns**, **`TNS >= 0.00` ns**, **`worst hold slack >= 0.00` ns**, and mapped cell area `<= 10,000` um².

2. **TDMA Gate Controller Event Retention & Deep-Pipeline AXI4-Lite Read Integrity (`tx_scheduler_ctrl_tdma`)**:
   - Do not drop `tdma_timeslot_start` or `tdma_timeslot_end` pulses that arrive while a previous start/stop queue burst is still draining under `m_axis_sched_ctrl_ready == 1'b0` backpressure, on the final drain beat of `STATE_START_0`/`STATE_START_N`/`STATE_STOP`, or during an AXI4-Lite `inconsistent` table rescan.
   - Propagate AXI4-Lite `queue_ram` read data/shift/valid cleanly across all `PIPELINE >= 2` stages (including `PIPELINE > 2`) without accepting new reads that overwrite valid in-flight read stages when `s_axil_rready == 1'b0`.

3. **Round-Robin TX Completion Gating & ASIC Reset Hygiene (`tx_scheduler_rr` + Full Chain)**:
   - On `s_axis_tx_req_status_valid` completion in `tx_scheduler_rr` (`SCHED_CTRL_ENABLE` in `{0, 1}`, `PIPELINE >= 2`), reschedule a queue with remaining work (`s_axis_tx_req_status_len != 0` or pending doorbell) if and only if the queue is enabled (`queue_ram` bit `0 == 1`), not already scheduled, and permitted by scheduler control (`!SCHED_CTRL_ENABLE || global_enable || sched_enable`, using the queue's stored `global_enable` bit `1`).
   - Synchronously reset all control, pointer, and pipeline valid registers across all three modules on `rst` so Yosys synthesis infers zero latches and ASIC initializer-stripped gate-level simulation exhibits zero `X` propagation after `rst` and full functional parity.

---

## Build, Simulation, and EDA Verification Instructions

The TDMA transmit scheduler RTL in `code/` derives from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause-Views).

Editable files:
- `code/tdma_scheduler.v`
- `code/tx_scheduler_ctrl_tdma.v`
- `code/tx_scheduler_rr.v`

Read-only files:
- `code/axis_fifo.v`
- `code/priority_encoder.v`
- `code/LICENSE`
- `pdk/NangateOpenCellLibrary_typical.lib`

Editable RTL must remain pure synthesizable HDL compatible with both Icarus Verilog and Verilator across parameterized `PORTS` / `INDEX_WIDTH` instantiations (do not add simulation-control or file-I/O system tasks such as `$finish`, `$stop`, `$fatal`, or `$readmem*`, and do not use simulator/synthesis macro divergence).

Local compilation, Verilator lint, Yosys Nangate45 synthesis, and OpenSTA `2.00` ns timing check from the workspace root:
```bash
# 1. Icarus Verilog & Verilator compilation/elaboration checks
iverilog -g2012 -o /tmp/tdma_chk.vvp \
  code/tdma_scheduler.v code/tx_scheduler_ctrl_tdma.v code/tx_scheduler_rr.v code/axis_fifo.v code/priority_encoder.v
verilator --lint-only -Wno-fatal --top-module tx_scheduler_ctrl_tdma code/tx_scheduler_ctrl_tdma.v
verilator --lint-only -Wno-fatal -GQUEUE_INDEX_WIDTH=4 --top-module tx_scheduler_ctrl_tdma code/tx_scheduler_ctrl_tdma.v

# 2. Yosys Nangate45 synthesis & area report on tdma_scheduler
yosys -p "
  read_verilog code/tdma_scheduler.v;
  hierarchy -check -top tdma_scheduler -chparam INDEX_WIDTH 8;
  synth -flatten -top tdma_scheduler;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean -purge;
  stat -liberty pdk/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -simple-lhs /tmp/tdma_sched_net.v
"

# 3. OpenSTA 2.00 ns timing verification on tdma_scheduler
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -no_init -exit <<'EOF'
read_liberty pdk/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/tdma_sched_net.v
link_design tdma_scheduler
create_clock -name clk -period 2.00 [get_ports clk]
set_false_path -from [get_ports rst]
foreach p [get_ports *] {
    set n [get_name $p]
    if {$n != "clk" && $n != "rst"} {
        if {[get_property $p direction] == "input"} { set_input_delay 0.10 -clock clk $p } else { set_output_delay 0.10 -clock clk $p }
    }
}
report_tns
report_wns
report_checks -path_delay min_max
EOF
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/tdma_scheduler.v`
- `code/tx_scheduler_ctrl_tdma.v`
- `code/tx_scheduler_rr.v`

All other files in the workspace are read-only reference context and must remain unmodified.
