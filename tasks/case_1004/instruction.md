# case_1004: Two-Channel OpenTitan SRAM Crossbar Stall Stability, Bounded Fairness, and Atomic Store Forwarding

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `lowRISC/opentitan` (`repo_01`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/prim_arbiter_tree.sv`, `code/prim_sram_arbiter.sv`

---

## Problem Specification

# Two-Channel OpenTitan SRAM Crossbar Stall Stability, Bounded Fairness, and Atomic Store Forwarding

In `code/ot_sram_xbar_2ch.sv`, update only `code/prim_arbiter_tree.sv` and `code/prim_sram_arbiter.sv` so that all boundary ports of `ot_sram_xbar_2ch` satisfy the following protocol and physical closure requirements:

1. **Stall Stability, Bounded Fairness, and Atomic Store Forwarding**:
   - Whenever `ot_sram_xbar_2ch` presents a valid downstream SRAM request (`sram_req_o == 1`) while stalled (`sram_gnt_i == 0`), the selected channel and requester as well as `sram_addr_o`, `sram_write_o`, `sram_amo_write_o`, `sram_wdata_o`, and `sram_wmask_o` must remain locked and invariant across rising `clk_i` edges until granted (`sram_gnt_i == 1`), even if contenders on either channel assert new requests or `arb_policy_i` changes mid-stall. All arbitration state in both modules must advance only on a granted handshake and reset to zero on `rst_ni == 0`.
   - Under `arb_policy_i[c] == 1` (`c` in `{0, 1}`), any requester on channel `c` holding `req_chc_i` must be granted by its channel tree after at most `P_c - 1` other grants on channel `c` (`P_c = 1 << $clog2(N_CHc)`), while `arb_policy_i[c] == 0` retains its `0 .. N_CHc - 1` round-robin counter.
   - `prim_sram_arbiter` must alternate channel priority away from the granted channel (`rr_flag_q <= ~sel_ch1`) after any granted channel transfer so an active channel waits at most one transfer by the other channel, and must push read-response steering entries into `u_req_fifo` only on a granted read (`sram_req_o && sram_gnt_i && !sram_write_o`).
   - When an atomic read (`!mux_write && mux_amo`) is accepted (`mux_valid && sram_gnt_i`), `prim_sram_arbiter` must issue its follow-up write (`sram_amo_write_o == 1`, `sram_write_o == 1`, `sram_req_o == 1`) driving `sram_wdata_o` with the write data (`chc_wdata_i`) sampled on the accepted atomic read cycle rather than all-ones.

2. **Latch-Free Synthesis, Nangate45 Area, and OpenROAD STA Closure**:
   - Across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}`, the RTL must be strictly latch-free. Synthesizing `ot_sram_xbar_2ch` at `N_CH0 = 8, N_CH1 = 4, SramAw = 12, SramDw = 32` with the Yosys/Slang + Nangate45 flow in `BUILD.md` must achieve mapped cell area `<= 2,850.0 um^2`, and OpenROAD placement STA at a `3.80 ns` clock must achieve worst setup slack (`WNS`) `>= 0.20 ns` and worst hold slack (`WHS`) `>= 0.00 ns`.

Edit only `code/prim_arbiter_tree.sv` and `code/prim_sram_arbiter.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable and Read-Only Files
Edit only:
- `code/prim_arbiter_tree.sv`
- `code/prim_sram_arbiter.sv`

Do not modify `code/ot_sram_xbar_2ch.sv`, `code/prim_fifo_sync*.sv*`, `code/prim_count*.sv`, `code/prim_flop*.sv`, `code/prim_mubi_pkg.sv`, `code/prim_util_pkg.sv`, `code/prim_assert*.sv*`, or `lib/*`. You may define helper submodules inside the editable files if needed.

## 2. Behavioral Simulation (`Verilator`)
Compile and simulate `ot_sram_xbar_2ch` across `(N_CH0, N_CH1)` in `{(4, 2), (3, 2), (8, 4)}` using Verilator 5:
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -DSYNTHESIS -Icode --top-module <your_tb> \
  code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
  code/prim_flop.sv code/prim_count.sv code/prim_fifo_sync_cnt.sv \
  code/prim_fifo_sync.sv code/prim_arbiter_tree.sv code/prim_sram_arbiter.sv \
  code/ot_sram_xbar_2ch.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Nangate45 Logic Synthesis (`Yosys + Slang`)
Synthesize `ot_sram_xbar_2ch` at `N_CH0=8, N_CH1=4, SramAw=12, SramDw=32`:
```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions -DSYNTHESIS --top ot_sram_xbar_2ch -G N_CH0=8 -G N_CH1=4 -G SramAw=12 -G SramDw=32 -I code \
    code/prim_util_pkg.sv code/prim_mubi_pkg.sv code/prim_count_pkg.sv \
    code/prim_flop.sv code/prim_count.sv code/prim_fifo_sync_cnt.sv \
    code/prim_fifo_sync.sv code/prim_arbiter_tree.sv code/prim_sram_arbiter.sv \
    code/ot_sram_xbar_2ch.sv
  hierarchy -check -top ot_sram_xbar_2ch
  proc; opt_clean
  select -assert-none t:\$dlatch* t:\$adlatch* t:\$latch* t:\$sr*
  synth -top ot_sram_xbar_2ch
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
Reported `Chip area for module '\ot_sram_xbar_2ch':` must be `<= 2850.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis
Strip ` signed ` tokens (`sed 's/ signed / /g' mapped.v > sta.v`) and run `openroad -exit flow.tcl`:
```tcl
set_thread_count 1
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design ot_sram_xbar_2ch
initialize_floorplan -die_area {0 0 220 220} -core_area {10 10 210 210} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 3.80 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [get_ports {arb_policy_i* req_ch* sram_gnt_i sram_rvalid_i sram_rdata_i* sram_rerror_i*}]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "WNS [sta::worst_slack -max]"
puts "WHS [sta::worst_slack -min]"
```
Required timing closure: `WNS >= 0.20` ns and `WHS >= 0.00` ns.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/prim_arbiter_tree.sv`
- `code/prim_sram_arbiter.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
