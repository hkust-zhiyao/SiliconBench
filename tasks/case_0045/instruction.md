# case_0045: TCDM Variable-Latency Crossbar Stall Lock, Bounded Starvation Fairness, and Latch-Free Synthesis

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `pulp-platform/cluster_interconnect` (`repo_28`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 2: Logic Synthesis & Gate-Level Verification` (`stage2_synth_gate`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/ArbitrationTree.sv`, `code/priority_Flag_Req.sv`

---

## Problem Specification

# TCDM Variable-Latency Crossbar Stall Lock and Bounded Starvation Fairness

In the TCDM request block (`code/ArbitrationTree.sv` and `code/priority_Flag_Req.sv`), downstream memory stalls and multi-level arbitration interact to cause two protocol violations:
1. **Stalled Output Preemption & Priority Drift**: Once `ArbitrationTree` presents a valid request at its output (`data_req_o == 1`) and is stalled by `data_gnt_i == 0` (or `data_stall_i == 1` when `GNT_BASED_FC` is not defined), its selected winning master (`data_ID_o`) and request payload (`data_add_o`, `data_wen_o`, `data_wdata_o`, `data_be_o`) must remain strictly locked and stable across clock cycles until that request is accepted (`data_gnt_i == 1`), even if higher-priority or round-robin-favored masters assert new requests or `TCDM_arb_policy_i` changes during the stall. Priority state in both `priority_Flag_Req` and `ArbitrationTree` must advance only on an actual granted transfer (`data_req_o && data_gnt_i`).
2. **Policy 1 Bounded Starvation Fairness**: When `TCDM_arb_policy_i == 1`, any requester that continuously holds its request until granted must be accepted after at most `P - 1` other accepted requests, where `P = 1 << $clog2(N_CH0)` is the binary tree's padded input count. Policy 0 (`TCDM_arb_policy_i == 0`) must retain its existing round-robin counter behavior (`0` through `MAX_COUNT`).

Update `code/ArbitrationTree.sv` and `code/priority_Flag_Req.sv` while preserving work conservation, response decoding, two-cycle `TestAndSet` atomic continuation, asynchronous reset behavior, and strictly latch-free synthesizable RTL across all editable files.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Instructions

Compile the TCDM request channel integration with Verilator 5 (`verilator --binary --timing -j 1 -Wno-fatal +incdir+code`) using:
- `code/RequestBlock1CH.sv`
- `code/ArbitrationTree.sv`
- `code/FanInPrimitive_Req.sv`
- `code/priority_Flag_Req.sv`
- `code/TestAndSet.sv`
- `code/AddressDecoder_Resp.sv`

Check latch-free synthesis with Yosys (`read_verilog -sv -Icode ...; hierarchy -check -top RequestBlock1CH; proc; opt_clean; select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr*`).

The editable files are `code/ArbitrationTree.sv` and `code/priority_Flag_Req.sv`. Do not modify the other files in `code/`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ArbitrationTree.sv`
- `code/priority_Flag_Req.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
