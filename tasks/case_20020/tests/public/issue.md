# 4-Way 8-KiB AXI4 Last-Level Cache Datapath, Critical-Word-First `WRAP` Coherency & 8-Macro Multi-Corner Signoff

## Problem Overview
Close functional, 4-state gate-level, and 3-corner (`SS`/`TT`/`FF`) hard-SRAM timing signoff on the 4-way set-associative AXI4 Last-Level Cache (`axi_llc_top_wrap`: `SetAssociativity=4`, `NumLines=64`, `NumBlocks=4`, 32 B cache lines, 8 KiB total data capacity, 64-bit data, 32-bit address, 4-bit slave / 5-bit master ID) in IHP SG13G2 130 nm technology.

## Scope & Editable Files
Only the following files may be modified (all other files under `code/` and `lib/` are read-only):
- `code/rtl/axi_llc_burst_cutter.sv`
- `code/rtl/axi_llc_merge_unit.sv`
- `code/rtl/axi_llc_read_unit.sv`
- `code/rtl/axi_llc_write_unit.sv`
- `code/rtl/axi_llc_ways.sv`
- `constraints/axi_llc_ways.sdc`

## Functional, Coherency & 4-State Gate-Level Contract
1. **Initialization & Address Map**: After `rst_ni` deassertion, tag BIST must complete (`bist_done_o = 1`, `bist_out_o = 4'b0000`). Slave transactions map to cached DRAM (`[cached_start_addr_i, cached_end_addr_i)`), per-way 2 KiB scratchpad regions (`spm_start_addr_i + w * 32'h800` for way `w` in `0..3` when `cfg_spm_i[w] = 1` and `flushed_o[w] = 1`), or uncached AXI4 master bypass; SPM-range accesses targeting ways still configured as cache must complete with `SLVERR` (`2'b10`) without corrupting cached state.
2. **AXI4 Burst Modes & Coherency**: Cached and SPM transactions must support `FIXED` (`2'b00`), single- and multi-line `INCR` (`2'b01`), and intra-cache-line Critical-Word-First `WRAP` (`2'b10` where `((AxLEN + 1) << AxSIZE) <= 32` bytes across narrow and 64-bit `AxSIZE`) read and write bursts without spurious cross-line splits or extra refill requests, preserving AXI4 ordering, 4-way dirty eviction writeback, and elastic `valid`/`ready` handshaking under arbitrary slave/master backpressure.
3. **4-State Partial-Strobe Hygiene**: Byte-masked writes (`slv_w_strb_i`) may carry `X` on unstrobed byte lanes (`slv_w_strb_i[b] == 0`) per AXI4; synthesized 4-state gate-level simulation (`iverilog -g2012`) must never propagate `X` onto read data or control handshakes, and must disallow latches (`$dlatch*`).

## Multi-Corner Hard-SRAM Timing Contract (`constraints/axi_llc_ways.sdc`)
1. **Clock & Boundary Budget**: Constrain single clock `clk_i` at **`10.80 ns`** (`92.59 MHz`) with `-setup >= 0.15 ns`, `-hold >= 0.08 ns` uncertainty, and `set_clock_transition >= 0.10 ns`. Every synchronous input (all inputs except `clk_i`, `rst_ni`, `test_i`, `cached_start_addr_i*`, `cached_end_addr_i*`, `spm_start_addr_i*`) requires `set_driving_cell -lib_cell sg13g2_buf_4 -pin X` and `set_input_delay` (`-max >= 1.80 ns`, `-min <= 0.20 ns`); every output requires `set_output_delay` (`-max >= 1.80 ns`, `-min <= 0.05 ns`) and `set_load >= 0.025` pF. Declare `set_false_path -from` only on `rst_ni`, `test_i`, and the three static `*_addr_i*` strap buses, with `set_max_fanout <= 16` and `set_max_transition <= 0.40 ns`.
2. **8-Macro CTS Balance & Signoff**: Preserve all **8** hard SRAM macros (`4` `RM_IHPSG13_1P_64x64_c2_bm_bist` + `4` `RM_IHPSG13_1P_256x64_c2_bm_bist`) with CTS macro clock-tree balance `set_clock_latency` in `[-0.50, -0.45]` ns on all `*i_cut/A_CLK` pins. No timing exceptions (`set_multicycle_path`, `set_max_delay`, `set_min_delay`, `set_disable_timing`, `set_case_analysis`, `set_ideal_network`, `create_generated_clock`, `group_path`) or unconstrained endpoints are allowed; post-`repair_design` (`SS`) and `repair_timing -hold` (`FF`) STA must achieve `setup_wns >= 0.0 ns`, `setup_tns >= 0.0 ns`, `hold_wns >= 0.0 ns`, and `hold_tns >= 0.0 ns` across `SS` (`1.08V, 125C`), `TT` (`1.20V, 25C`), and `FF` (`1.32V, -40C`).
