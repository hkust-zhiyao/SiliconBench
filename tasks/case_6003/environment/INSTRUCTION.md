# case_6003: VeeR-EH1 LSU AXI4-to-AHB Bridge, DMA AHB-to-AXI4 Slave Gasket, 4-Entry DMA/Debug Controller, and Transparent Sideband Timing Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/cores-veer-eh1` (`repo_06`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC`
> - **Editable Files (`allowed_edits`)**: `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, `code/dma_ctrl.sv`, `constraints.json`

---

## Problem Specification

# VeeR-EH1 LSU AXI4-to-AHB Bridge, DMA AHB-to-AXI4 Slave Gasket, 4-Entry DMA/Debug Controller, and Transparent Sideband Timing Closure

In `code/veer_bus_dma_top.sv`, the core LSU AXI4-to-AHB-Lite master bridge (`code/axi4_to_ahb.sv`), the external DMA AHB-Lite-to-AXI4 slave gasket (`code/ahb_to_axi4.sv`), the 4-entry DMA and abstract debug memory controller (`code/dma_ctrl.sv`), and two zero-cut transparent 8-bit sideband pass-through channels (`qos_in` to `qos_out` and `region_in` to `region_out`) are integrated together.

Update only `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, `code/dma_ctrl.sv`, and `constraints.json` to satisfy all functional, synthesis, and static timing contracts:

1. **LSU AXI4-to-AHB-Lite Master Bridge (`code/axi4_to_ahb.sv`)**:
   - Translate 64-bit AXI4 read and write requests into AHB-Lite `NONSEQ` (`2'b10`) transactions. Aligned byte, halfword, word, and contiguous sub-dword writes (`8'hff`, `8'hf0`, `8'h0f`, `8'hc0`, `8'h30`, `8'h0c`, `8'h03`) must issue as a single AHB transfer with the matching transfer size and byte offset (`0, 2, 4, 6`), while unaligned or sparse 64-bit writes must walk only the asserted byte lanes in ascending byte order (`0..7`) using single-byte (`3'h0`) AHB beats and terminate immediately after the highest asserted byte lane completes.
   - Support back-to-back streaming AXI reads without dead cycles when no write is pending. When `lsu_ahb_hresp` is asserted during a single read, a streaming read beat, or a write data phase, complete the pending AHB phase cleanly, return an AXI error response (`lsu_axi_rresp[1] == 1'b1` or `lsu_axi_bresp[1] == 1'b1`) on the corresponding response channel, and drive the last active AHB write bus address replicated across both 32-bit halves of `lsu_axi_rdata` for errored reads.

2. **DMA AHB-Lite-to-AXI4 Slave Gasket (`code/ahb_to_axi4.sv`)**:
   - Accept AHB-Lite slave transactions targeting DCCM (`[0xf0040000, 0xf004ffff]`) or ICCM (`[0xee000000, 0xee07ffff]`). Any transfer outside DCCM and ICCM, any ICCM read/write or DCCM write that is not 32-bit (`3'h2`) or 64-bit (`3'h3`), any size-unaligned address, or any downstream AXI read response error must assert the two-cycle AHB-Lite error response (`dma_ahb_hresp = 1'b1` with `dma_ahb_hreadyout = 1'b0` on the first bus-clock cycle and `dma_ahb_hreadyout = 1'b1` on the second) while clearing any pending read command in the gasket buffer.

3. **4-Entry Core DMA & Abstract Debug Memory Controller (`code/dma_ctrl.sv`)**:
   - Arbitrate between buffered AXI write and read requests with alternating priority whenever both buffers are valid. Normalize 64-bit AXI writes carrying a single 32-bit word strobe (`8'h0f` or `8'hf0`) into 32-bit word core requests (`dma_mem_sz = 3'h2`, advancing address bit `[2]` when `wstrb == 8'hf0`), and record address or size/strobe alignment errors in the FIFO without issuing a core memory request (returning `SLVERR = 2'b10` on alignment or ECC errors and `DECERR = 2'b11` on address decode errors).
   - Count consecutive cycles where a valid head FIFO memory request is not granted by `dccm_ready` / `iccm_ready`; once the count reaches `dec_tlu_dma_qos_prty`, assert and hold `dma_dccm_stall_any` / `dma_iccm_stall_any` until the request is accepted. Support abstract debug memory accesses (`dbg_cmd_valid` with `dbg_cmd_type == 2'b10` to DCCM, ICCM, or PIC `[0xf00c0000, 0xf00c7fff]`) when the FIFO is empty and `dbg_dma_bubble` is asserted, extracting the addressed byte, halfword, or word from the selected 32-bit half of the 64-bit read data (`dma_dbg_rddata`).

4. **Declarative Timing Constraints (`constraints.json`) & Synthesis QoR**:
   - In `veer_bus_dma_top`, `clk` operates at `5.60 ns` and `6.00 ns` periods with a `2.50 ns` external input delay on all non-clock inputs and a `2.00 ns` external output delay on all outputs. Keep the clock and existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the schema in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.65 ns` for `qos_in` to `qos_out` and `2.45 ns` for `region_in` to `region_out`, while preserving the registered timing constraints on all bridge and DMA ports.
   - The RTL must synthesize without latches, achieve mapped cell area `<= 12,350.0 um^2`, and meet `WNS >= 0.00 ns` and `WHS >= 0.00 ns` on all registered timing paths.

---

## Build, Simulation, and EDA Verification Instructions

# Build, Simulation, Synthesis, and Static Timing Guide (`veer_bus_dma_top`)

## 1. Editable Files
Only the following four files are collected and graded:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `code/dma_ctrl.sv`
- `constraints.json`

All other files in `code/` (`code/veer_bus_dma_top.sv`, `code/common_defines.vh`, `code/global.h`, `code/veer_types.sv`, `code/beh_lib.sv`, `code/LICENSE`) and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/dma_ctrl.sv \
  code/veer_bus_dma_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis & Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
1. **Synthesis (`Yosys/Slang`)**:
   ```bash
   yosys -m slang -p "
     read_slang --single-unit --top veer_bus_dma_top -Icode \
       code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
       code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/dma_ctrl.sv code/veer_bus_dma_top.sv;
     hierarchy -check -top veer_bus_dma_top;
     proc;
     select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
     opt_clean;
     select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
     synth -top veer_bus_dma_top;
     opt;
     dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
     abc -liberty lib/NangateOpenCellLibrary_typical.lib;
     clean;
     read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
     check -assert;
     stat -liberty lib/NangateOpenCellLibrary_typical.lib;
     write_verilog -noattr mapped.v
   "
   ```

2. **Declarative Timing Constraints (`constraints.json`) & Static Timing Analysis (`OpenROAD`)**:
   - `constraints.json` has a single top-level key `"max_delays"`, which is a list of rule objects `{"from": [...], "to": [...], "ns": <float>}`.
   - Allowed input port groups in `"from"` are the non-clock input port names of `veer_bus_dma_top` (or bit-indexed `qos_in[0..7]`, `region_in[0..7]`).
   - Allowed output port groups in `"to"` are the output port names of `veer_bus_dma_top` (or bit-indexed `qos_out[0..7]`, `region_out[0..7]`).
   - A group name without bit index selects all bits of that port. Each rule object is translated to:
     `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`
   - The STA flow retains the clock (`5.60 ns` or `6.00 ns` on `clk`), `set_input_delay 2.50 -clock clk [all_inputs -no_clocks]`, `set_output_delay 2.00 -clock clk [all_outputs]`, `set_load 5.0 [all_outputs]`, and `set_false_path -from [get_ports {rst_l scan_mode}]`. All delays are in `ns`.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `code/dma_ctrl.sv`
- `constraints.json`

All other files in the workspace are read-only reference context and must remain unmodified.
