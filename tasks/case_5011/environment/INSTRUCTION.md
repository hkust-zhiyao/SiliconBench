# case_5011: CVA6 RV32 Zcmp/Zcmt ID-Stage Macro & Table-Jump Expansion, Pipeline Flush/Backpressure Control, and Synthesis/Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `openhwfoundation/cva6` (`repo_05`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Task-Specific Multi-Corner Liberty & SDC Timing Views`
> - **Editable Files (`allowed_edits`)**: `code/macro_decoder.sv`, `code/zcmt_decoder.sv`, `code/id_stage.sv`

---

## Problem Specification

# CVA6 RV32 Zcmp/Zcmt ID-Stage Macro & Table-Jump Expansion, Pipeline Flush/Backpressure Control, and Synthesis/Timing Closure

## Background

In the 32-bit CVA6 embedded configuration (`RV32IMAC` with `Zcb`, `Zcmp`, and `Zcmt` code-size reduction extensions enabled, `NrIssuePorts = 1`), the Instruction Decode (`id_stage`) subsystem integrates:

- `code/compressed_decoder.sv`: first-pass 16-bit RVC/Zcb decompression and detection of `Zcmp` (`is_macro_instr_o`) and `Zcmt` (`is_zcmt_instr_o`) instructions.
- `code/macro_decoder.sv`: multi-cycle micro-operation sequencer that expands `Zcmp` instructions (`cm.push`, `cm.pop`, `cm.popret`, `cm.popretz`, `cm.mvsa01`, `cm.mva01s`) into a sequence of 32-bit RISC-V store, load, arithmetic (`addi`/`lui`), and return (`jalr x0, x1, 0`) micro-operations.
- `code/zcmt_decoder.sv`: two-state table-jump controller (`IDLE`, `TABLE_JUMP`) that translates `cm.jt` (`index < 32`) and `cm.jalt` (`index >= 32`) into a jump-vector-table (`JVT`) data-cache read request (`{jvt_i.base, 6'b000000} + (index << 2)`) and, upon receiving `req_port_i.data_rvalid`, synthesizes a PC-relative `jal` instruction (`rd = x0` for `cm.jt`, `rd = x1` for `cm.jalt`) with `jump_address_o = ({req_port_i.data_rdata[31:1], 1'b0} - pc_i)`.
- `code/decoder.sv` and `code/id_stage.sv`: full 32-bit instruction decoding, `fetch_entry_ready_o` upstream handshaking, and the `ID <-> Issue` pipeline register (`issue_q[0]`).

During verification and Nangate45 synthesis/STA sign-off of the `id_decode_top` wrapper (`flow/id_decode_top.sv`), several functional, structural, and timing closure issues were identified across `code/macro_decoder.sv`, `code/zcmt_decoder.sv`, and `code/id_stage.sv`.

## Problem Description & Architectural Requirements

1. **Valid-Qualified & Flush-Safe Zcmp/Zcmt Activation and Pipeline Handshaking (`code/id_stage.sv`, `code/macro_decoder.sv`, `code/zcmt_decoder.sv`)**:
   - `compressed_decoder_i` decodes `fetch_entry_i[0].instruction` combinationally regardless of `fetch_entry_valid_i[0]` or `flush_i`. Neither `macro_decoder_i` nor `zcmt_decoder_i` may initiate a sequence or assert a D-Cache table read request (`dcache_req_ports_o.data_req`) when `fetch_entry_valid_i[0]` is deasserted or when `flush_i` is asserted.
   - Whenever `flush_i` is asserted, `id_stage` must not acknowledge/pop the upstream fetch entry (`fetch_entry_ready_o` must remain `'0`), must invalidate `issue_q[0].valid`, and any in-flight `macro_decoder` expansion or `zcmt_decoder` `TABLE_JUMP` lookup must abort cleanly and return to `IDLE` (with `zcmt_decoder` asserting `req_port_o.kill_req = 1'b1` when aborted in `TABLE_JUMP`) so that post-flush instructions decode without residual state corruption.

2. **Micro-Operation Sequencing Under Empty/Full ID-Issue Pipeline Register & Backpressure (`code/macro_decoder.sv`, `code/id_stage.sv`)**:
   - In `id_stage`, a decoded micro-operation at the output of `decoder_i` is latched into the `issue_q[0]` pipeline register whenever `(!issue_q[0].valid || issue_instr_ack_i[0]) && fetch_entry_valid_i[0] && !flush_i`.
   - `macro_decoder` must drive each micro-operation (`instr_o`, `is_last_macro_instr_o`, `is_double_rd_macro_instr_o`, `fetch_stall_o`) combinationally from its current state regardless of whether `issue_ack_i` is currently asserted, and advance its state machine one step per micro-operation accepted into `issue_q[0]`, releasing `fetch_stall_o` (`fetch_entry_ready_o[0] = 1'b1`) only when the final micro-operation of the `Zcmp` sequence is accepted into `issue_q[0]`.
   - Similarly, while `zcmt_decoder` is waiting in `TABLE_JUMP` for `req_port_i.data_rvalid`, it must hold `fetch_stall_o = 1'b1` so `id_stage` neither pops `fetch_entry_i[0]` nor marks `issue_q[0].valid` until the table entry arrives.

3. **Latch-Free / Combinational-Loop-Free Synthesis & Area/Timing Closure (`code/macro_decoder.sv`, `code/zcmt_decoder.sv`, `code/id_stage.sv`)**:
   - All combinational blocks in `macro_decoder`, `zcmt_decoder`, and `id_stage` must be completely specified with no inferred latches and zero combinational logic loops (`scc -expect 0` in Yosys after `proc; opt_clean`).
   - On the critical decode path through `id_decode_top`, avoid routing non-macro / non-table-jump instructions serially through the `macro_decoder` mux tree or re-evaluating chained 12-bit stack-adjustment adders across every state cycle.
   - Under the Nangate45 synthesis and OpenROAD STA sign-off flow (`flow/id_decode_top.sv` at a `1.95 ns` clock period on `clk_i` with `0.15 ns` input/output external delays and `abc -D 1000`):
     - Worst setup slack (`max`): `>= 0.00 ns`
     - Worst hold slack (`min`): `>= 0.00 ns`
     - Total cell area of `id_decode_top`: `<= 2560.0 um^2`

## Deliverable

Update only the editable RTL files:
- `code/macro_decoder.sv`
- `code/zcmt_decoder.sv`
- `code/id_stage.sv`

Do not modify module port signatures or package definitions.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, and Synthesis/STA Guide

## Editable Files
- `code/macro_decoder.sv`
- `code/zcmt_decoder.sv`
- `code/id_stage.sv`

## Top-Level Wrapper & Collateral
- Synthesis/STA and verification wrapper: `flow/id_decode_top.sv` (top module: `id_decode_top`)
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
  --top-module id_decode_top \
  -Iinclude \
  code/config_pkg.sv \
  code/cv64a60ax_config_pkg.sv \
  code/riscv_pkg.sv \
  code/ariane_pkg.sv \
  code/cva6_accel_first_pass_decoder_stub.sv \
  code/cvxif_compressed_if_driver.sv \
  code/compressed_decoder.sv \
  code/macro_decoder.sv \
  code/zcmt_decoder.sv \
  code/decoder.sv \
  code/id_stage.sv \
  flow/id_decode_top.sv
```

## Synthesis & Latch/Loop Check (Yosys + Slang)
```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top id_decode_top -Iinclude -DSYNTHESIS \
    code/config_pkg.sv \
    code/cv64a60ax_config_pkg.sv \
    code/riscv_pkg.sv \
    code/ariane_pkg.sv \
    code/cva6_accel_first_pass_decoder_stub.sv \
    code/cvxif_compressed_if_driver.sv \
    code/compressed_decoder.sv \
    code/macro_decoder.sv \
    code/zcmt_decoder.sv \
    code/decoder.sv \
    code/id_stage.sv \
    flow/id_decode_top.sv;
  hierarchy -check -top id_decode_top;
  proc; opt_clean;
  scc -expect 0;
  select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
  synth -top id_decode_top -flatten;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib -D 1000;
  clean;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -noexpr -nohex -nodec netlist.v
"
```

## Static Timing Analysis (OpenROAD)
With `design.sdc`:
```tcl
create_clock -name core_clk -period 1.95 [get_ports clk_i]
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
link_design id_decode_top
read_sdc design.sdc
report_worst_slack -max
report_worst_slack -min
```
Targets:
- Worst setup slack (`-max`): `>= 0.00 ns`
- Worst hold slack (`-min`): `>= 0.00 ns`
- Total cell area of `id_decode_top`: `<= 2560.0 um^2`

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/macro_decoder.sv`
- `code/zcmt_decoder.sv`
- `code/id_stage.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
