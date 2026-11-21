# case_23002: SIMT Warp Control-Flow Divergence, IPDOM Stack Unwinding, and Multi-Packet Mask Coherency

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `vortexgpgpu/vortex` (`repo_37`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/VX_wctl_unit.sv`, `code/VX_split_join.sv`, `code/VX_ipdom_stack.sv`

---

## Problem Specification

# SIMT Warp Control-Flow Divergence, IPDOM Stack Unwinding, and Multi-Packet Mask Coherency

In Vortex's SIMT warp control subsystem (`code/VX_wctl_unit.sv`, `code/VX_split_join.sv`, and `code/VX_ipdom_stack.sv`, integrated in `code/VX_wctl_ipdom_top.sv`), multi-warp SFU control instructions manage per-warp thread masks, warp spawning, barrier synchronization, and Immediate Post-Dominator (IPDOM) branch divergence and reconvergence. Currently, the subsystem exhibits multi-packet mask corruption under warp interleaving and backpressure, wrong scalar operand lane selection when lane 0 is inactive, incorrect branch serialization and reconvergence masks, stale divergence stack pointers across back-to-back splits, and stack corruption during nested or early multi-level reconvergence.

Update **only** `code/VX_wctl_unit.sv`, `code/VX_split_join.sv`, and `code/VX_ipdom_stack.sv` (preserving all module port and parameter interfaces) so the subsystem satisfies the following architectural contracts:

1. **Multi-Packet Thread-Mask Gathering & Scalar Control Extraction**:
   - Extract scalar `rs1`/`rs2` control operands from the highest-indexed active lane in the packet's `tmask` (`NUM_LANES == 1` uses lane `0`).
   - Evaluate per-lane branch/predicate conditions from `rs1[lane][0]` (inverted when `is_cond_neg` is set). Across multi-packet warps (`sop`..`eop`, `NUM_THREADS > NUM_LANES`), maintain independent per-warp `then` and `else` masks across interleaved warps and stalled cycles, committing control actions only on the final accepted sub-packet.

2. **Smaller-Branch-First Divergence & Coherent Stack-Pointer Writeback**:
   - Diverge on `SPLIT` (`split.is_dvg = 1`) only when both `then` and `else` masks are non-zero. Serialize the branch with the smaller active thread popcount first into `split.then_tmask` and the larger into `split.else_tmask` (ties execute `then` first), saving `PC + 4` as the fallthrough PC.
   - Return the warp's pre-push IPDOM stack pointer via `result_if` on non-barrier-arrive control instructions, remaining coherent across back-to-back same-warp divergent `SPLIT`s and cross-warp interleaving.

3. **Compiler-Guided IPDOM Reconvergence & Early Multi-Frame Unwinding**:
   - Each `JOIN` supplies via `sjoin.stack_ptr` (from scalar `rs1`) the pre-push stack pointer returned by its matching `SPLIT`. When no live stack frames exist above `sjoin.stack_ptr`, treat the `JOIN` as non-divergent (`join_is_dvg = 0`).
   - Otherwise, on the first `JOIN` targeting that frame, transition execution to that split's remaining untaken threads (`join_is_else = 1`) at its saved fallthrough PC while unwinding any skipped inner frames above it; on the second `JOIN` targeting that frame, restore the pre-split active thread mask (`join_is_else = 0`) and pop the frame itself.

4. **Control ISA Preservation & Multi-Configuration Signoff**:
   - Preserve `TMC`, `PRED`, `WSPAWN`, `WSYNC` drain stalling, and synchronous/arrive/`expect_tx`/asynchronous `BAR` behaviors.
   - Must pass verification under `(NUM_WARPS=4, NUM_THREADS=8, NUM_LANES=2)` and `(NUM_WARPS=8, NUM_THREADS=4, NUM_LANES=4)` and synthesize cleanly without latches or combinational loops on `VX_wctl_ipdom_top`.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment

## Editable RTL Files
- `code/VX_wctl_unit.sv`
- `code/VX_split_join.sv`
- `code/VX_ipdom_stack.sv`

## Integration Top & Read-Only Closure
- Top-level integration wrapper: `code/VX_wctl_ipdom_top.sv`
- Supporting headers, packages, interfaces, and library primitives are provided in `code/`.

## Example Synthesis & Lint Commands
```bash
# Yosys + slang latch-free synthesis check (multi-packet SIMT config)
yosys -m slang -p "
  read_slang -DASIC -DSYNTHESIS -DVX_CFG_XLEN=32 -DVX_CFG_NUM_WARPS=4 -DVX_CFG_NUM_THREADS=8 -DVX_CFG_NUM_SFU_LANES=2     -Icode code/VX_gpu_pkg.sv code/VX_execute_if.sv code/VX_txbar_bus_if.sv code/VX_warp_ctl_if.sv code/VX_result_if.sv     code/VX_dp_ram_asic.v code/VX_scan.sv code/VX_find_first.sv code/VX_lzc.sv code/VX_onehot_encoder.sv code/VX_priority_encoder.sv     code/VX_popcount.sv code/VX_pipe_register.sv code/VX_pipe_buffer.sv code/VX_stream_buffer.sv code/VX_async_ram_patch.sv     code/VX_dp_ram.sv code/VX_fifo_queue.sv code/VX_elastic_buffer.sv     code/VX_ipdom_stack.sv code/VX_split_join.sv code/VX_wctl_unit.sv code/VX_wctl_ipdom_top.sv --top VX_wctl_ipdom_top;
  hierarchy -check -top VX_wctl_ipdom_top; proc; opt_clean; check -assert; select -assert-none */t:\$dlatch*
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/VX_wctl_unit.sv`
- `code/VX_split_join.sv`
- `code/VX_ipdom_stack.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
