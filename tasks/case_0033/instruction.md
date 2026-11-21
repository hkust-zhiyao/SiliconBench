# case_0033: BSG Manycore Tile Memory Interface Stall Lock, Flush Cancellation, and PPA/STA Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `bespoke-silicon-group/bsg_manycore` (`repo_11`)
> - **Engineering Problem Type**: `Architectural & Protocol Bug Repair` (`PT1_Arch_Protocol_Bug_Repair`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/lsu.sv`, `code/network_tx.sv`, `code/bsg_manycore_endpoint_standard.sv`

---

## Problem Specification

# BSG Manycore Tile Memory Interface Stall Lock, Flush Cancellation, and PPA/STA Closure

In `code/bsg_manycore_tile_mem_if.sv`, update `code/lsu.sv`, `code/network_tx.sv`, and `code/bsg_manycore_endpoint_standard.sv` to fix address-generation, stall-lock, flush, and response-serialization defects. In `lsu`, `icache_miss_i` must issue a remote word-load fetch (`icache_fetch == 1`, `write_not_read == 0`, `is_amo_op == 0`, `is_uncached_op == 0`, `mask == 4'b1111`, `addr == (pc_plus4_i - 32'd4) | 32'h8000_0000`) while suppressing `dmem_v_o`, `dmem_w_o`, and `reserve_o`; when `exe_decode_i.is_uncached_op` is high on a load/store/AMO (including addresses with `addr[31:12] == 20'h0_0000`, e.g., `0x0000_0100`), it must route to the network (`remote_req_v_o == 1`, `remote_req_o.is_uncached_op == 1`, `load_info.part_sel == 2'b00`) and never assert `dmem_v_o` or `reserve_o`. In `network_tx`, any valid outgoing request (`remote_req_v_i && !invalid_eva_access_o && !flush_i`) stalled by `out_credit_or_ready_i == 0` must hold `out_v_o` and `out_packet_o` invariant across `clk_i` edges (keeping `remote_req_credit_o == 0` and `invalid_eva_access_o == 0` while held, including on the cycle `out_credit_or_ready_i == 1` accepts the held packet) until drained on the accepting clock edge or cleared by `reset_i` or `flush_i`; `flush_i` must immediately force `out_v_o == 0` and `invalid_eva_access_o == 0` and cancel any held request, and `returned_yumi_o` must assert only when `returned_v_i` is high. In `bsg_manycore_endpoint_standard`, after `in_v_o && in_yumi_i`, suppress `in_v_o` until `returning_v_i` asserts (allowing same-cycle handoff when `returning_v_i` is high), ignore `returning_v_i` when idle, return the prior lock bit on `e_remote_amoswap`, and advance `out_credits_used_o` only on accepted outgoing packets (`out_v_i && out_credit_or_ready_o`).

Under the Nangate45 Yosys/Slang flow (`BUILD.md`), `bsg_manycore_tile_mem_if` must map to `<= 3,665.0 um^2`, and OpenROAD STA must achieve setup and hold slack `>= 0.0 ns` at a `2.33 ns` `clk_i` period (`0.20 ns` input delay, `0.40 ns` output delay, `5.0 fF` load). Edit only `code/lsu.sv`, `code/network_tx.sv`, and `code/bsg_manycore_endpoint_standard.sv`.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/lsu.sv`: BSG Manycore Vanilla Bean load-store address generator and local/remote classifier (**editable target**).
- `code/network_tx.sv`: Outgoing network packet builder, EVA-to-NPA wrapper, and return packet demultiplexer (**editable target**).
- `code/bsg_manycore_endpoint_standard.sv`: Standard manycore tile endpoint controller (**editable target**).
- `code/bsg_manycore_tile_mem_if.sv`: Top-level tile memory interface integration wrapper (read-only).
- `code/bsg_*.sv`, `code/bsg_*.svh`: Upstream BSG Manycore and BaseJump STL packages and dependencies (read-only).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.

Edit only `code/lsu.sv`, `code/network_tx.sv`, and `code/bsg_manycore_endpoint_standard.sv`.

## 2. Functional Simulation (Verilator)

```bash
verilator --binary --timing -j 1 -Wno-fatal -DBSG_HIDE_FROM_SYNTHESIS -Icode --top-module tb \
  code/bsg_manycore_pkg.sv code/bsg_manycore_addr_pkg.sv code/bsg_vanilla_pkg.sv \
  code/bsg_dff_reset.sv code/bsg_circular_ptr.sv code/bsg_fifo_tracker.sv \
  code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
  code/bsg_fifo_1r1w_small_unhardened.sv code/bsg_fifo_1r1w_small.sv \
  code/bsg_two_fifo.sv code/bsg_counter_up_down.sv code/bsg_hashing_ipoly.sv \
  code/bsg_manycore_reg_id_decode.sv code/bsg_manycore_dram_hash_function.sv \
  code/bsg_manycore_eva_to_npa.sv code/bsg_manycore_endpoint.sv \
  code/bsg_manycore_endpoint_fc.sv code/bsg_manycore_endpoint_standard.sv \
  code/lsu.sv code/network_tx.sv code/bsg_manycore_tile_mem_if.sv tb.sv
./obj_dir/Vtb
```

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top bsg_manycore_tile_mem_if -DBSG_HIDE_FROM_SYNTHESIS -I code \
    code/bsg_manycore_pkg.sv code/bsg_manycore_addr_pkg.sv code/bsg_vanilla_pkg.sv \
    code/bsg_dff_reset.sv code/bsg_circular_ptr.sv code/bsg_fifo_tracker.sv \
    code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
    code/bsg_fifo_1r1w_small_unhardened.sv code/bsg_fifo_1r1w_small.sv \
    code/bsg_two_fifo.sv code/bsg_counter_up_down.sv code/bsg_hashing_ipoly.sv \
    code/bsg_manycore_reg_id_decode.sv code/bsg_manycore_dram_hash_function.sv \
    code/bsg_manycore_eva_to_npa.sv code/bsg_manycore_endpoint.sv \
    code/bsg_manycore_endpoint_fc.sv code/bsg_manycore_endpoint_standard.sv \
    code/lsu.sv code/network_tx.sv code/bsg_manycore_tile_mem_if.sv
  hierarchy -check -top bsg_manycore_tile_mem_if
  synth -top bsg_manycore_tile_mem_if
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

The reported `Chip area for module '\bsg_manycore_tile_mem_if':` must be `<= 3665.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD (`openroad -exit flow.tcl`) with:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design bsg_manycore_tile_mem_if
initialize_floorplan -die_area {0 0 140 140} -core_area {10 10 130 130} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 2.33 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.40 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
```

Both the worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`) must be `>= 0.0` (`ns`), with an empty `check_setup -verbose` audit block.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/lsu.sv`
- `code/network_tx.sv`
- `code/bsg_manycore_endpoint_standard.sv`

All other files in the workspace are read-only reference context and must remain unmodified.
