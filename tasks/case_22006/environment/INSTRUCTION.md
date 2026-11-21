# case_22006: RedMulE CORE-V-XIF Speculative Matrix ISA Offload, Split Operand Assembly, and Queued Controller Synchronization

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/redmule` (`repo_30`)
> - **Engineering Problem Type**: `New ISA & Subsystem Feature Implementation` (`PT2_New_Feature_ISA_Impl`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/redmule_inst_decoder.sv`, `code/redmule_ctrl.sv`

---

## Problem Specification

# RedMulE CORE-V-XIF Matrix Offload Frontend & Queued Controller Synchronization

## Context
In RedMulE (`redmule_xif_offload_subsys.sv`), RISC-V cores offload custom matrix instructions over the CORE-V-XIF 1.0 interface (`redmule_inst_decoder.sv`, `redmule_xif_pkg.sv`), pushing `redmule_config_t` job descriptors into a two-entry `redmule_config_fifo` (`i_config_fifo`) consumed by `redmule_ctrl.sv` (`i_cfg_tiler` and the controller FSM), with completion looped back via `evt_o -> op_done_i`. Currently, speculative CORE-V-XIF issue/commit/kill handling, split/out-of-order operand assembly (`XifIssueRegisterSplit = 1`), full `MCNFIG`/`MARITH`/`MOPCNT` decoding, multi-hart arbitration, and queued job execution across `redmule_inst_decoder.sv` and `redmule_ctrl.sv` are incomplete or broken.

## Architectural & Protocol Requirements

1. **Issue Legality & Handshake (`x_issue_*`)**:
   - Match `{instr[26:25], instr[14:12], instr[6:0]}` against `MCNFIG`, `MARITH`, and `MOPCNT` for valid harts (`hartid < XifNumHarts`):
     - `MCNFIG`: `accept = 1`, `writeback = 0`, `register_read = 3'b111`.
     - `MARITH`: `accept = 1`, `writeback = (rd != 5'd0)`, `register_read = 3'b111`.
     - `MOPCNT`: `accept = 1`, `writeback = (rd != 5'd0)`, `register_read = 3'b000` (`rd = instr[11:7]`).
     - Any unrecognized instruction (or `hartid >= XifNumHarts`): `accept = 0`, `writeback = 0`, `register_read = 3'b000`. Rejected instructions must never allocate state, consume standalone register/commit beats, or emit `x_result` packets.
   - Per hart, buffer up to `InstFifoDepth` accepted in-flight instructions (`x_issue_ready_o` reflects target hart slot availability).

2. **Operand Collection (`x_register_*`) in Non-Split (`0`) and Split (`1`) Modes**:
   - `MOPCNT` reads zero GPRs (`register_read = 3'b000`); the host CPU sends **no** `x_register` beat for `MOPCNT`, so `MOPCNT` is immediately operand-ready.
   - `MCNFIG` and `MARITH` require all three 32-bit operands `rs[2:0]`.
   - When `XifIssueRegisterSplit == 0`, `x_register` beats arrive for `MCNFIG`/`MARITH` in the same cycle as `x_issue` or in-order per hart (`rs_valid = 3'b111`), subject to `x_register_ready_o` backpressure without FIFO overflow.
   - When `XifIssueRegisterSplit == 1`, `x_register` beats for accepted `MCNFIG`/`MARITH` instructions arrive in the same cycle as `x_issue` or on later cycles matched by `(hartid, id)`, potentially out-of-order across active `id`s/harts and split across multiple partial beats where `x_register_i.rs_valid[k]` qualifies `x_register_i.rs[k]` until all three operands (`3'b111`) are assembled.

3. **Non-Speculative Commit/Kill Ordering (`x_commit_*`)**:
   - `x_commit_valid_i` (no backpressure) may arrive in the same cycle as `x_issue` or on any later cycle for any buffered `(hartid, id)`.
   - Within each hart, accepted instructions retire in issue order. An instruction must **never** update per-hart configuration state, enqueue a `MARITH` job (`config_valid_o`), advance operation ID counters, or assert `x_result_valid_o` until it has received `x_commit` with `commit_kill == 0` and its required operands.
   - If `x_commit` arrives with `commit_kill == 1` for `(hartid, id)`, discard **only** that instruction without side effects, without emitting an `x_result` transaction, and without flushing older or younger valid instructions on that hart.

4. **Descriptor Decoding, Multi-Hart Fairness, and `x_result_*` Handshake**:
   - Retiring `MCNFIG` updates only that hart's configuration: `m_size = rs[0][15:0]`, `k_size = rs[0][31:16]`, `n_size = rs[1][15:0]`, `{send_w, receive_w, send_x, receive_x} = rs[1][19:16]`, `gemm_ops = gemm_op_e'(rs[1][22:20])` (all 8 `gemm_op_e` values), `gemm_input_fmt = gemm_fmt_e'(rs[1][24:23])`, `gemm_output_fmt = gemm_fmt_e'(rs[1][26:25])`, `y_offs = rs[2][31:0]`, `w_cols_offset = 16'd0`, `loopback_w = 1'b0`, and emits `x_result` (`we = 0, data = 0`).
   - Retiring `MARITH` combines that hart's current `MCNFIG` state (preserving `gemm_ops`, `gemm_input_fmt`, `gemm_output_fmt`) with `x_addr = rs[0]`, `w_addr = rs[1]`, `z_addr = rs[2]`, performs a single `config_valid_o && config_ready_i` enqueue, emits `x_result` (`we = (rd != 0)`, `data = zero_ext(op_id_in[hart])`), and increments `op_id_in[hart]` (reset `0`, modulo `2^OpIdWidth`).
   - Retiring `MOPCNT` emits `x_result` (`we = (rd != 0)`, `data = zero_ext(op_id_out[hart])`), where `op_id_out[hart]` resets to `'1` (`{OpIdWidth{1'b1}}`) and increments modulo `2^OpIdWidth` each time an in-flight `MARITH` from `hart` completes (`op_done_i`), supporting full pipeline occupancy (`1` active + `2` queued in `i_config_fifo` + `InstFifoDepth` per hart) without tracker overflow.
   - Arbitrate across ready harts in starvation-free round-robin order (advancing priority on **every** retired instruction, including `MOPCNT`/`MCNFIG`). Maintain AXI-stream-style stability on `(x_result_valid_o, x_result_o)` across `x_result_ready_i == 0` stalls with **no combinational path** from `x_result_ready_i` to `config_valid_o`.

5. **Queued Job Isolation & Post-Drain Completion (`redmule_ctrl.sv` + `clear_i`)**:
   - While a job is active in `redmule_ctrl` (non-idle states, including two-pass `w_cols_offset != 0` loopback if driven), queued entries waiting in `i_config_fifo` must **not** trigger `i_cfg_tiler`, overwrite `config_o`, or assert `cfg_complete_o` early; start tiling the next queued job only when `redmule_ctrl` is in `REDMULE_IDLE` with `fifo_ready_i`.
   - Assert `evt_o` as a single-cycle pulse strictly when the job reaches `REDMULE_FINISHED` (after `z_stream_sink_flags.ready_start && fifo_empty_i && flgs_streamer_i.store_fifo_empty` and final pass completion), never prematurely while Z store FIFO beats remain pending.
   - `clear_i` / `target_clear_i` synchronously flushes in-flight state and resets counters/configurations cleanly; both editable modules must synthesize cleanly (`yosys -m slang`) with zero unintended latches across `XifNumHarts >= 1` and `XifIssueRegisterSplit` in `{0, 1}`.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment

## Editable Files
- `code/redmule_inst_decoder.sv`
- `code/redmule_ctrl.sv`

All other files in `code/` (including `redmule_pkg.sv`, `redmule_xif_pkg.sv`, `redmule_config_fifo.sv`, `redmule_tiler.sv`, `redmule_xif_offload_subsys.sv`, and `include/common_cells/*.svh`) are read-only reference collateral. Preserve the module declarations, parameter lists, and port interfaces of `redmule_inst_decoder` and `redmule_ctrl`.

## Available Toolchain
- **Verilator (`v5.038`)**: `verilator`
- **Yosys + Slang (`yosys -m slang`)**: `yosys`

## Example Elaboration & Lint Commands

### 1. Verilator Elaboration & Lint
```bash
verilator \
  --lint-only -sv -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  +incdir+code/include \
  code/cf_math_pkg.sv code/fpnew_pkg.sv code/hci_package.sv \
  code/hwpe_ctrl_package.sv code/hwpe_stream_package.sv \
  code/redmule_pkg.sv code/redmule_xif_pkg.sv \
  code/tc_clk.sv code/redmule_config_fifo.sv code/redmule_tiler.sv \
  code/redmule_ctrl.sv code/redmule_inst_decoder.sv \
  code/redmule_xif_offload_subsys.sv \
  --top-module redmule_xif_offload_subsys
```

### 2. Yosys + Slang Synthesis Sanity Check
```bash
yosys -m slang -p "
  read_slang --top redmule_xif_offload_subsys -I code/include \
    code/cf_math_pkg.sv code/fpnew_pkg.sv code/hci_package.sv \
    code/hwpe_ctrl_package.sv code/hwpe_stream_package.sv \
    code/redmule_pkg.sv code/redmule_xif_pkg.sv \
    code/tc_clk.sv code/redmule_config_fifo.sv code/redmule_tiler.sv \
    code/redmule_ctrl.sv code/redmule_inst_decoder.sv \
    code/redmule_xif_offload_subsys.sv;
  hierarchy -check -top redmule_xif_offload_subsys;
  proc; opt; check
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/redmule_inst_decoder.sv`
- `code/redmule_ctrl.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
