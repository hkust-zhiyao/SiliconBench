# case_5013: CVA6 RV32 Load-Store Unit Speculative Non-Idempotent Load Resolution, Word-Granular Store-Buffer Hazard Checking, CBO Commit-Queue Handshaking, and Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cva6` (`repo_05`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Task-Specific Multi-Corner Liberty & SDC Timing Views`
> - **Editable Files (`allowed_edits`)**: `code/lsu_bypass.sv`, `code/load_unit.sv`, `code/store_buffer.sv`, `code/load_store_unit.sv`

---

## Problem Specification

# CVA6 RV32 Load-Store Unit Speculative Non-Idempotent Load Resolution, Word-Granular Store-Buffer Hazard Checking, CBO Commit-Queue Handshaking, and Timing Closure

## Background

In the 32-bit CVA6 embedded configuration (`XLEN = 32`, `VLEN = 32`, `PLEN = 32`, `MmuPresent = 0`, `SpeculativeSb = 1`, `NonIdemPotenceEn = 1`, `RVZiCbom = 1`, `NrLoadBufEntries = 2`), the Load-Store Unit (`load_store_unit`) subsystem (`flow/lsu_subsys_top.sv`) integrates:

- `code/lsu_bypass.sv`: a 2-entry fall-through skid buffer between the Address Generation Unit (`AGU`) and `load_unit` / `store_unit` that tracks speculative loads (`is_speculative_load`, `is_speculative_load_miss`) against branch resolution (`resolved_branch_i`).
- `code/load_unit.sv`: manages up to `NrLoadBufEntries = 2` outstanding D-Cache load requests (`ldbuf_q`), stalls speculative or non-committed loads targeting non-idempotent regions (`0x1000_0000 .. 0x1FFF_FFFF` via `WAIT_SPEC_LOAD` / `stall_ni`) or conflicting store-buffer page offsets (`WAIT_PAGE_OFFSET`), suppresses flushed load responses (`ldbuf_flushed_q`), and aligns/sign-extends returning load data.
- `code/store_unit.sv` and `code/store_buffer.sv`: buffers speculative (`speculative_queue_q`) and committed (`commit_queue_q`) stores and cache-block operations (`CBO_INVAL`, `CBO_CLEAN`, `CBO_FLUSH`), checks incoming load `page_offset_i` against pending store addresses (`page_offset_matches_o`), and drains committed stores/CBOs to D-Cache port 2.
- `code/load_store_unit.sv`: top-level AGU, misaligned exception detector, non-MMU physical address bridge (`gen_no_mmu`), and load/store dispatcher.

During verification and Nangate45 synthesis/STA sign-off of `lsu_subsys_top`, several functional and timing/area closure issues were identified across `code/lsu_bypass.sv`, `code/load_unit.sv`, `code/store_buffer.sv`, and `code/load_store_unit.sv`.

## Problem Description & Architectural Requirements

1. **Same-Cycle Non-MMU PPN, Speculative Non-Idempotent Load Resolution & Killed/Exception Load-Buffer Reclamation (`code/load_store_unit.sv`, `code/lsu_bypass.sv`, `code/load_unit.sv`)**:
   - When `MmuPresent = 0` (`gen_no_mmu`), `dtlb_ppn_i` presented to `load_unit` must reflect the current request's physical page number in the **same cycle** as the request (matching the MMU's same-cycle DTLB PPN contract), rather than a 1-cycle-delayed address from the previous request. Otherwise, a speculative or non-committed load targeting a non-idempotent address evaluates `paddr_ni` in `IDLE` against the previous instruction's address and issues a memory request prematurely.
   - When a speculative load to a non-idempotent address enters `WAIT_SPEC_LOAD` and is held in `lsu_bypass` (`mem_q`) waiting for `resolved_branch_i.valid`:
     - `lsu_bypass` must update `is_speculative_load` / `is_speculative_load_miss` not only on a newly arriving `lsu_req_i`, but also on any valid speculative load entries already queued in `mem_q` when `resolved_branch_i.valid` arrives (`is_speculative_load_miss = 1'b1` on `resolved_branch_i.is_mispredict`, or `is_speculative_load = 1'b0` on a correct branch prediction), **and must combinationally forward that branch-resolution update onto `lsu_ctrl_o` in the same cycle `resolved_branch_i.valid` is asserted** (both in fall-through mode and when driving `lsu_ctrl_o` from `mem_q[read_pointer_q]`).
     - `load_unit` must remain in `WAIT_SPEC_LOAD` while `lsu_ctrl_i.is_speculative_load` is still asserted and `!lsu_ctrl_i.is_speculative_load_miss`. On the cycle `resolved_branch_i.valid` resolves as non-mispredicted (`lsu_ctrl_i.is_speculative_load` clears combinationally to `1'b0`), `load_unit` must transition from `WAIT_SPEC_LOAD` to `IDLE` at that clock edge and issue `req_port_o.data_req = 1'b1` on the immediately following cycle. On the cycle `resolved_branch_i.valid` resolves as mispredicted (`lsu_ctrl_i.is_speculative_load_miss` asserts combinationally to `1'b1` while `!req_port_i.data_rvalid`), `load_unit` must combinationally retire a dummy completion (`valid_o = 1'b1`, `ex_o.valid = 1'b0`, `pop_ld_o = 1'b1`) in that same cycle and return to `IDLE` at the clock edge.
   - When `load_unit` is in `SEND_TAG` and `ex_i.valid` is asserted (1-cycle-delayed misaligned or PMP load exception) while `!req_port_i.data_rvalid`, `load_unit` must still retire the excepting load (`valid_o = 1'b1`, `ex_o.valid = 1'b1`, `trans_id_o = ldbuf_q[ldbuf_last_id_q].trans_id`) in that `SEND_TAG` cycle rather than gating `SEND_TAG` exception retirement on `req_port_i.data_rvalid`. Furthermore, whenever a granted load request is killed in `SEND_TAG` (`ex_i.valid`), `ABORT_TRANSACTION`, or `ABORT_TRANSACTION_NI`, its allocated `ldbuf_valid_q[ldbuf_last_id_q]` entry must be reclaimed (`1'b0`) so that killed/aborted loads do not leak load-buffer entries and deadlock `ldbuf_full`.

2. **32-bit Word-Granular Store-Buffer Page-Offset Hazard Check & CBO Commit-Queue Handshake (`code/store_buffer.sv`, `code/load_unit.sv`)**:
   - In `code/store_buffer.sv`, `page_offset_matches_o` must detect address hazards at 32-bit word granularity (`[11:2]`) for 32-bit targets (`XLEN = 32`) across `commit_queue_q`, `speculative_queue_q`, and `paddr_i` (`valid_without_flush_i`), so 32-bit loads to a non-overlapping word within the same 8-byte doubleword (e.g., load at `0x8000_0104` while a store is pending at `0x8000_0100`) do not false-stall in `WAIT_PAGE_OFFSET`, whereas loads overlapping the same 32-bit word properly stall until the store drains.
   - When a committed cache-block operation (`cbo_op != ariane_pkg::CBO_NONE`) in `commit_queue_q` receives `req_port_i.data_gnt` while `!wait_rvalid`, it must transition to `wait_rvalid = 1'b1` and wait for its own subsequent `req_port_i.data_rvalid` completion cycle before evicting the entry from `commit_queue_q`, even if a coincidental `req_port_i.data_rvalid` from an earlier transaction is high on the grant cycle.
   - Ensure clean 32-bit (`XLEN = 32`) load sign-extension in `code/load_unit.sv` without zero-width replication warnings.

3. **LSU Subsystem Synthesis Quality & Timing/Area Closure (`code/lsu_bypass.sv`, `code/load_unit.sv`, `code/store_buffer.sv`, `code/load_store_unit.sv`)**:
   - All combinational logic must synthesize cleanly with zero inferred latches and zero combinational loops (`scc -expect 0` in Yosys after `proc; opt_clean`).
   - Optimize the critical AGU, control, and queue storage paths across the LSU subsystem so that under the Nangate45 synthesis and OpenROAD STA sign-off flow (`flow/lsu_subsys_top.sv` at a `1.80 ns` clock period on `clk_i` with `0.15 ns` input/output external delays and `abc -D 1000`):
     - Worst setup slack (`max`): `>= 0.00 ns`
     - Worst hold slack (`min`): `>= 0.00 ns`
     - Total cell area of `lsu_subsys_top`: `<= 8260.0 um^2`

## Deliverable

Update only the editable RTL files:
- `code/lsu_bypass.sv`
- `code/load_unit.sv`
- `code/store_buffer.sv`
- `code/load_store_unit.sv`

Do not modify module port signatures or package definitions.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/lsu_bypass.sv`
- `code/load_unit.sv`
- `code/store_buffer.sv`
- `code/load_store_unit.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/lsu_subsys_top.sv` (top module: `lsu_subsys_top`)
- Liberty library: `lib/NangateOpenCellLibrary_typical.lib`
- LEF files:
  - `lef/NangateOpenCellLibrary.tech.lef`
  - `lef/NangateOpenCellLibrary.macro.mod.lef`

## Tool Paths
- Verilator: `verilator`
- Yosys: `yosys`
- OpenROAD: `openroad`

## RTL Elaboration & Simulation (Verilator)
```bash
verilator \
  --binary --timing -Wno-fatal \
  --top-module lsu_subsys_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/cf_math_pkg.sv \
  code/lzc.sv \
  code/shift_reg.sv \
  code/cva6_fifo_v3.sv \
  code/amo_buffer.sv \
  code/pmp_entry.sv \
  code/pmp.sv \
  code/pmp_data_if.sv \
  code/lsu_bypass.sv \
  code/store_buffer.sv \
  code/store_unit.sv \
  code/load_unit.sv \
  code/load_store_unit.sv \
  flow/lsu_subsys_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p '
  read_slang --ignore-assertions --top lsu_subsys_top -Iinclude -DSYNTHESIS
    code/config_pkg.sv
    code/cv64a60ax_config_pkg.sv
    code/riscv_pkg.sv
    code/ariane_pkg.sv
    code/cf_math_pkg.sv
    code/lzc.sv
    code/shift_reg.sv
    code/cva6_fifo_v3.sv
    code/amo_buffer.sv
    code/pmp_entry.sv
    code/pmp.sv
    code/pmp_data_if.sv
    code/lsu_bypass.sv
    code/store_buffer.sv
    code/store_unit.sv
    code/load_unit.sv
    code/load_store_unit.sv
    flow/lsu_subsys_top.sv;
  hierarchy -check -top lsu_subsys_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*;
  synth -top lsu_subsys_top -flatten;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 1000;
  clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -noexpr -nohex -nodec netlist.v
'
```

## Static Timing Analysis (OpenROAD)
With `design.sdc`:
```tcl
create_clock -name core_clk -period 1.80 [get_ports clk_i]
set_input_delay 0.15 -clock core_clk [all_inputs]
set_output_delay 0.15 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_ni]
```
Run OpenROAD:
```tcl
read_lef lef/NangateOpenCellLibrary.tech.lef
read_lef lef/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog netlist.v
link_design lsu_subsys_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `lsu_subsys_top`: `<= 8260.0 um^2`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/lsu_bypass.sv`
- `code/load_unit.sv`
- `code/store_buffer.sv`
- `code/load_store_unit.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
