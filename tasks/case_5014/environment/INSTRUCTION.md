# case_5014: CVA6 Write-Through Cache AXI64 Adapter 32-Bit AMO Operand Alignment, Concurrent Invalidation Buffering, AXI Shim AR/W Backpressure Stability, and Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cva6` (`repo_05`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Task-Specific Multi-Corner Liberty & SDC Timing Views`
> - **Editable Files (`allowed_edits`)**: `code/wt_axi_adapter.sv`, `code/axi_shim.sv`, `code/cva6_fifo_v3.sv`

---

## Problem Specification

# CVA6 Write-Through Cache AXI64 Adapter 32-Bit AMO Operand Alignment, Concurrent Invalidation Buffering, AXI Shim AR/W Backpressure Stability, and Timing Closure

## Background

In the 64-bit CVA6 Write-Through Cache subsystem (`XLEN = 64`, `AxiDataWidth = 64`, `ICACHE_LINE_WIDTH = 128`, `DCACHE_LINE_WIDTH = 128`, `RVA = 1`), the L1 I-Cache and L1 D-Cache connect to the 64-bit AXI4+ATOP memory bus through (`flow/wt_axi_subsys_top.sv`):

- `code/wt_axi_adapter.sv`: buffers incoming `icache_data_i` and `dcache_data_i` requests in `cva6_fifo_v3` queues, arbitrates between I-Cache fills and D-Cache loads/stores/AMOs, tracks in-flight transaction IDs in `i_rd_icache_id` / `i_rd_dcache_id` / `i_wr_dcache_id` FIFOs, generates AXI5 atomic (`aw.atop`) and LR/SC (`ar.lock`/`aw.lock`) requests, emits D-Cache invalidations (`DCACHE_INV_REQ`) on external invalidations (`inval_valid_i`) and atomic self-invalidations (`invalidate`), and assembles 128-bit returning cachelines.
- `code/axi_shim.sv`: converts adapter read (`rd_*`) and write (`wr_*`) requests into AXI4 `AR`, `AW`, `W`, `R`, and `B` channel handshakes (`IDLE`, `WRITE`, `WRITE_WAIT`, `AW_WAIT` and `READ`, `READ_HOLD`).
- `code/cva6_fifo_v3.sv`: parameterized synchronous FIFO used for request, ID-tracking, and `B`-response buffering.

During verification and Nangate45 synthesis/STA sign-off of `wt_axi_subsys_top`, several functional bugs and timing closure bottlenecks were identified across `code/wt_axi_adapter.sv`, `code/axi_shim.sv`, and `code/cva6_fifo_v3.sv`.

## Problem Description & Architectural Requirements

1. **64-Bit AXI Bus Operand Replication for 32-Bit AMOs & Concurrent External/Self-Invalidation Preservation (`code/wt_axi_adapter.sv`)**:
   - In CVA6, the store/AMO unit places 32-bit atomic operands (`AMO_*.W`, `dcache_data.size[1:0] == 2'b10`) unshifted in the lower 32 bits `dcache_data.data[31:0]` even when the target physical address is aligned to the upper 32-bit word of the 64-bit AXI bus (`dcache_data.paddr[2:0] == 3'b100`, where `axi_wr_be[0] = 8'hF0`). Because `wt_axi_adapter.sv` computes `axi_wr_data[0] = {(AxiDataWidth/XLEN){dcache_data.data}}` (`1` copy when `AxiDataWidth == XLEN == 64`), upper-word 32-bit AMOs drive `dcache_data.data[63:32]` (zeros) onto `w_data_o[63:32]` instead of the 32-bit operand `dcache_data.data[31:0]`. For 32-bit atomic requests (`dcache_data.rtype == DCACHE_ATOMIC_REQ` and `dcache_data.size[1:0] == 2'b10`), replicate `dcache_data.data[31:0]` across both 32-bit halves (`{2{dcache_data.data[31:0]}}`, and `~{2{dcache_data.data[31:0]}}` for `AMO_AND`).
   - In `p_axi_rtrn_decode`, when an external invalidation (`inval_valid_i = 1'b1`) arrives in the same cycle that an atomic request is granted (`invalidate = 1'b1`), the `if (inval_valid_i) ... else if (CVA6Cfg.RVA && invalidate)` priority branch services `inval_valid_i` and silently drops the atomic self-invalidation! Buffer any colliding atomic self-invalidation index (`dcache_data.paddr[DCACHE_INDEX_WIDTH-1:0]`) and emit its `DCACHE_INV_REQ` packet on the following cycle.

2. **AXI Shim Unacknowledged `AR` / `W` Channel Stability & Burst Counter Gating (`code/axi_shim.sv`)**:
   - In `p_read_fsm`, when a read request is not immediately accepted (`ar_ready == 1'b0`), `axi_shim` transitions to `READ_HOLD` but fails to assert `axi_req_o.ar_valid = 1'b1` in `READ_HOLD`, violating the AXI4 handshake rule that `ar_valid` and `ar` must remain asserted and stable until `ar_ready` is high.
   - In `p_write_fsm`, when `AW` is accepted before `W` (`aw_ready = 1, w_ready = 0`), `axi_shim` transitions to `WRITE_WAIT`, where `axi_req_o.w` fails to preserve `w.last = (wr_cnt_q == 0)` and `wr_cnt_d` decrements unconditionally in `WRITE`/`WRITE_WAIT` even when `w_ready == 1'b0`. Only decrement `wr_cnt_q` on a completed `w_valid && w_ready` beat and keep `w_valid`, `w.data`, `w.strb`, `w.user`, and `w.last` valid and stable in `WRITE` and `WRITE_WAIT` until `w_ready` is high.

3. **Arbiter Lock-Path & FIFO Reset Fanout Optimization for Timing Closure (`code/wt_axi_adapter.sv`, `code/cva6_fifo_v3.sv`, `code/axi_shim.sv`)**:
   - In `code/wt_axi_adapter.sv`, instantiating `rr_arb_tree` with `LockIn = 1'b1` and `gnt_i = axi_rd_gnt | axi_wr_gnt` creates a deep combinational loop-back path from the request FIFOs through `arb_idx` -> `axi_shim` -> `arb_gnt` -> `arb_ack` -> ID FIFO write enables, and in `code/cva6_fifo_v3.sv`, resetting the entire `mem_n = '0` storage array under `if (flush_i)` adds unnecessary muxing on every FIFO bit.
   - Replace the 2-input `rr_arb_tree` lock wrapper with a direct round-robin arbiter (`rr_q`) qualified by the active channel grant, and remove the redundant `mem_n = '0` array clear on `flush_i` in `cva6_fifo_v3.sv`.
   - Under the Nangate45 synthesis and OpenROAD STA sign-off flow (`flow/wt_axi_subsys_top.sv` at a `2.35 ns` clock period on `clk_i` with `0.15 ns` input/output external delays and `abc -D 1000`):
     - Worst setup slack (`max`): `>= 0.00 ns`
     - Worst hold slack (`min`): `>= 0.00 ns`
     - Total cell area of `wt_axi_subsys_top`: `<= 6450.0 um^2`

## Deliverable

Update only the editable RTL files:
- `code/wt_axi_adapter.sv`
- `code/axi_shim.sv`
- `code/cva6_fifo_v3.sv`

Do not modify module port signatures or package definitions.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/wt_axi_adapter.sv`
- `code/axi_shim.sv`
- `code/cva6_fifo_v3.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/wt_axi_subsys_top.sv` (top module: `wt_axi_subsys_top`)
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
  --top-module wt_axi_subsys_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/axi_pkg.sv \
  code/wt_cache_pkg.sv \
  code/cf_math_pkg.sv \
  code/lzc.sv \
  code/rr_arb_tree.sv \
  code/cva6_fifo_v3.sv \
  code/axi_shim.sv \
  code/wt_axi_adapter.sv \
  flow/wt_axi_subsys_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p '
  read_slang --ignore-assertions --top wt_axi_subsys_top -Iinclude -DSYNTHESIS
    code/config_pkg.sv
    code/cv64a60ax_config_pkg.sv
    code/riscv_pkg.sv
    code/ariane_pkg.sv
    code/axi_pkg.sv
    code/wt_cache_pkg.sv
    code/cf_math_pkg.sv
    code/lzc.sv
    code/rr_arb_tree.sv
    code/cva6_fifo_v3.sv
    code/axi_shim.sv
    code/wt_axi_adapter.sv
    flow/wt_axi_subsys_top.sv;
  hierarchy -check -top wt_axi_subsys_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*;
  synth -top wt_axi_subsys_top -flatten;
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
create_clock -name core_clk -period 2.35 [get_ports clk_i]
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
link_design wt_axi_subsys_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `wt_axi_subsys_top`: `<= 6450.0 um^2`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/wt_axi_adapter.sv`
- `code/axi_shim.sv`
- `code/cva6_fifo_v3.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
