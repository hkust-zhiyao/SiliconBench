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
