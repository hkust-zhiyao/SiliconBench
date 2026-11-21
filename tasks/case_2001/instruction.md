# case_2001: Co-design Ibex Prefetch/FIFO Fault Handling, Four-Cluster SRAM Mirror Relay, and 8-Macro CTS Floorplan

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/ibex` (`repo_02`)
> - **Engineering Problem Type**: `RTL + Hard-SRAM Macro Physical Co-Design` (`PT5_RTL_HardSRAM_Macro_PnR`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/ibex_prefetch_buffer.sv`, `code/ibex_fetch_fifo.sv`, `code/ibex_prefetch_sram_cluster.sv`, `plan/placement.json`

---

## Problem Specification

# Co-design Ibex prefetch/FIFO fault handling, four-cluster SRAM mirror relay, and 8-macro CTS floorplan

In `code/ibex_prefetch_sram_cluster.sv`, the Ibex instruction prefetch front-end (`code/ibex_prefetch_buffer.sv` and `code/ibex_fetch_fifo.sv`) fetches 32-bit instruction words across four 256×128 single-port SRAM clusters (`cluster[0..3].mem` via `code/tc_sram.sv`, each backed by `i_cut_low` for bits `[63:0]` and `i_cut_high` for bits `[127:64]` of `RM_IHPSG13_1P_256x64_c2_bm_bist`), while a host maintenance interface performs 128-bit reads, writes, and low-to-high mirror relays. Currently, both RTL functional verification and physical implementation fail:

1. **Prefetch fault retirement, post-fault speculative freeze, and unaligned error attribution (`code/ibex_prefetch_buffer.sv`, `code/ibex_fetch_fifo.sv`)**:
   - In `ibex_prefetch_buffer.sv`, every instruction memory response (`instr_rvalid_i == 1'b1`, whether `instr_err_i` is `0` or `1`) must retire the oldest slot in the outstanding-request and branch-discard queues, and every non-discarded response (`!branch_discard_q[0]`) must be pushed into `ibex_fetch_fifo` (`in_valid_i = 1'b1`, propagating `instr_err_i` on `in_err_i`), while branch-discarded responses (`branch_discard_q[0] == 1'b1`) are retired without pushing to the FIFO.
   - Maintain a registered fault-freeze state in `ibex_prefetch_buffer.sv` (cleared on `!rst_ni` or `branch_i == 1'b1`, set on the clock edge following any non-discarded error response `instr_rvalid_i && instr_err_i && !branch_discard_q[0]` with `branch_i == 1'b0`) that blocks new sequential requests (`valid_new_req == 1'b0`) while keeping any already-asserted ungranted request (`valid_req_q == 1'b1`) stable on `instr_req_o`/`instr_addr_o` until `instr_gnt_i` asserts.
   - In `ibex_fetch_fifo.sv`, when `out_addr_o[1] == 1'b1` and the first word (`entry[0]` or bypass when `entry[0]` is empty) is valid with an error (`err == 1'b1`), assert `out_valid_o = 1'b1`, `out_err_o = 1'b1`, and `out_err_plus2_o = 1'b0` immediately without waiting for a second word; assert `out_err_plus2_o = 1'b1` if and only if `out_addr_o[1] == 1'b1`, `!unaligned_is_compressed`, `!err`, and the second word has an error.

2. **Four-cluster SRAM low-to-high mirror relay, byte-mask forwarding, and 8-macro CTS floorplan (`code/ibex_prefetch_sram_cluster.sv`, `plan/placement.json`)**:
   - In `code/ibex_prefetch_sram_cluster.sv`, for each cluster `i` (`0..3`), drive `wd[63:0] = host_wdata_i[63:0]` and drive `wd[127:64] = host_mirror_i[i] ? bank_rdata[i][63:0] : host_wdata_i[127:64]` without adding extra flip-flops or latches in the cluster loop (`__RELAY_PATHS__ 256` preserved); drive `be = host_mirror_i[i] ? {host_be_i[15:8] | host_be_i[7:0], host_be_i[7:0] & host_be_i[15:8]} : host_be_i`; and drive `cluster_xor_rdata_o[127:0]` as the full 128-bit bitwise XOR across `bank_rdata[0..3]`.
   - In `plan/placement.json` (`"macros"` with 8 integer-coordinate entries for `bank` `0..3` and `half` `"low"`/`"high"`, `"orient"` in `{"R0", "R180", "MX", "MY"}`), place all 8 macros (`784.48 × 118.78 µm`) within `65 <= x`, `x + 784.48 <= 2335`, `68 <= y`, `y + 118.78 <= 1730` with `>= 20 µm` pairwise X or Y clearance, `y(low) == y(high)` and `x(low) < x(high)` per bank, banks `0, 1` in the south bay `68 <= y` and `y + 118.78 <= 420` (`y(0) < y(1)`), and banks `2, 3` in the north bay `1340 <= y` and `y + 118.78 <= 1730` (`y(2) < y(3)`). Under `physical/synth.ys` and `physical/flow.tcl.in` (`10.0 ns` `clk_i`), achieve legal placement, connected `VDD`/`VSS` grids, `0` global-route overflow, rise-to-rise clock network latency spread `<= 0.01750 ns`, post-global-route setup slack `>= 0.60 ns`, hold slack `>= 0.05 ns`, and Metal2–Metal5 global-route wirelength `<= 1,402,000.0 µm`.

Edit only `code/ibex_prefetch_buffer.sv`, `code/ibex_fetch_fifo.sv`, `code/ibex_prefetch_sram_cluster.sv`, and `plan/placement.json`.

---

## Build, Simulation, and EDA Verification Instructions

# Build and Verification Instructions

## 1. Editable Files
Only the following four files are collected and graded:
- `code/ibex_prefetch_buffer.sv`
- `code/ibex_fetch_fifo.sv`
- `code/ibex_prefetch_sram_cluster.sv`
- `plan/placement.json`

All other files (`code/tc_sram.sv`, `code/prim_assert*`, `code/prim_flop_macros.sv`, `pdk/*`, `physical/synth.ys`, `physical/flow.tcl.in`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Icarus Verilog`)
Compile and simulate `code/ibex_prefetch_buffer.sv`, `code/ibex_fetch_fifo.sv`, and `code/ibex_prefetch_sram_cluster.sv` with `code/tc_sram.sv` and the behavioral IHP 256×64 SRAM macro models (`pdk/256.v`, `pdk/core.v`):

```bash
iverilog \
  -g2012 -DSYNTHESIS -Icode -s <your_tb_top> -o sim.vvp \
  pdk/256.v pdk/core.v code/tc_sram.sv \
  code/ibex_fetch_fifo.sv code/ibex_prefetch_buffer.sv \
  code/ibex_prefetch_sram_cluster.sv <your_tb.sv>

vvp \
  sim.vvp
```

## 3. Logic Synthesis (`Yosys + Slang`)
Run synthesis using the provided `physical/synth.ys` script:

```bash
yosys \
  -m slang -s physical/synth.ys
```

This produces `mapped.v`, which must contain exactly 8 `RM_IHPSG13_1P_256x64_c2_bm_bist` macro instances and zero inferred standard-cell latches.

## 4. Physical Implementation & STA (`OpenROAD`)
`plan/placement.json` must be a JSON object with a single `"macros"` array of 8 objects, each with exact keys:
```json
{
  "bank": 0,
  "half": "low",
  "x": 100,
  "y": 120,
  "orient": "MX"
}
```
where `bank ∈ {0, 1, 2, 3}`, `half ∈ {"low", "high"}`, `x` and `y` are integers (`65 <= x`, `x + 784.48 <= 2335`, `68 <= y`, `y + 118.78 <= 1730`), and `orient ∈ {"R0", "R180", "MX", "MY"}`.

To render `flow.tcl` from `physical/flow.tcl.in` and run OpenROAD:

```bash
python3 -c '
import json, pathlib
plan = json.loads(pathlib.Path("plan/placement.json").read_text())
moves = []
for m in sorted(plan["macros"], key=lambda e: (e["bank"], e["half"])):
    name = f"cluster\\[{m[\"bank\"]}\\].mem.gen_256x128xBx1.i_cut_{m[\"half\"]}"
    moves.append(f"place_macro -macro_name {{{name}}} -location {{{m[\"x\"]} {m[\"y\"]}}} -orientation {m[\"orient\"]}")
t = (pathlib.Path("physical/flow.tcl.in").read_text()
     .replace("@PDK@", "pdk")
     .replace("@MAPPED@", "mapped.v")
     .replace("@DEF@", "placed.def")
     .replace("@GUIDE@", "route.guide")
     .replace("@PLACEMENTS@", "\n".join(moves)))
pathlib.Path("flow.tcl").write_text(t)
'
openroad -exit flow.tcl
```

## 5. Summary of Checked Physical & Timing Constraints
- **Core & Bay Geometry**:
  - Die: `2400 × 1800 µm`; Core: `(50, 50)` to `(2350, 1750) µm`; Macro size: `784.48 × 118.78 µm`.
  - Usable macro bounds: `65 <= x`, `x + 784.48 <= 2335`, `68 <= y`, `y + 118.78 <= 1730`, with `>= 20 µm` pairwise clearance in X or Y.
  - Within each bank `b`, `y(b, low) == y(b, high)` and `x(b, low) < x(b, high)`.
  - South bay (`bank` `0, 1`): `68 <= y` and `y + 118.78 <= 420`, with `y(bank 0) < y(bank 1)`.
  - North bay (`bank` `2, 3`): `1340 <= y` and `y + 118.78 <= 1730`, with `y(bank 2) < y(bank 3)`.
- **Coverage, Power Grid & Global Routing**:
  - `__PLACEMENT_OK__`, `__MACRO_COUNT__ 8`, `__CLOCK_PINS__ 8`, `__RELAY_PATHS__ 256`, and `[INFO CTS-0099]  Sinks 8`.
  - Connected `VDD` and `VSS` power grids (`All shapes on net VDD are connected`, `All shapes on net VSS are connected`).
  - Global routing (`Metal2–TopMetal1`) with `0` total overflow and route-guide net count matching `Routed nets`.
- **Clock Spread, Timing & Wirelength (`10.0 ns` clock `clk_i`)**:
  - Rise-to-rise clock network latency spread (`report_clock_latency`): `<= 0.01750 ns`.
  - Post-global-route setup slack (`max`): `>= 0.60 ns` (`MET`).
  - Post-global-route hold slack (`min`): `>= 0.05 ns` (`MET`).
  - Post-global-route Metal2–Metal5 total wirelength: `<= 1,402,000.0 µm`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/ibex_prefetch_buffer.sv`
- `code/ibex_fetch_fifo.sv`
- `code/ibex_prefetch_sram_cluster.sv`
- `plan/placement.json`

All other files in the workspace are read-only reference context and must remain unmodified.
